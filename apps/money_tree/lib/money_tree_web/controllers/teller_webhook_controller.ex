defmodule MoneyTreeWeb.TellerWebhookController do
  use MoneyTreeWeb, :controller

  alias MoneyTree.Audit
  alias MoneyTree.Institutions
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Synchronization
  alias MoneyTree.Teller.Webhooks
  alias MoneyTreeWeb.RateLimiter

  @signature_header "teller-signature"
  @timestamp_tolerance 300
  @nonce_retention 86_400
  @rate_limit 60
  @rate_period 60

  @doc """
  Handles Teller webhook callbacks.

  Requests are authenticated using a shared HMAC signature. Verified payloads enqueue a
  targeted synchronization job and record audit metadata so downstream systems can trace
  activity. Duplicate payloads are ignored but acknowledged to keep Teller from retrying.
  """
  def webhook(conn, _params) do
    client_ip = remote_ip(conn)
    base_metadata = audit_metadata(remote_ip: client_ip)
    bucket = {:teller_webhook, client_ip}

    with :ok <- RateLimiter.check(bucket, @rate_limit, @rate_period),
         {:ok, raw_body} <- fetch_raw_body(conn),
         {:ok, timestamp, signatures} <- parse_signature(conn),
         :ok <- ensure_fresh(timestamp),
         :ok <- verify_signature(timestamp, raw_body, signatures),
         {:ok, payload} <- decode_payload(raw_body),
         {:ok, nonce} <- fetch_nonce(payload),
         {:ok, event} <- fetch_event(payload),
         {:ok, connection_id} <- fetch_connection_id(payload),
         result <- process_event(connection_id, nonce, timestamp, event, payload, base_metadata) do
      respond(conn, result)
    else
      {:error, :rate_limited} ->
        Audit.log(:teller_webhook_rate_limited, base_metadata)

        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "rate limit exceeded"})

      {:error, :missing_body} ->
        Audit.log(:teller_webhook_invalid_payload, base_metadata)

        conn
        |> put_status(:bad_request)
        |> json(%{error: "missing request body"})

      {:error, :invalid_signature} ->
        Audit.log(:teller_webhook_signature_invalid, base_metadata)

        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid signature"})

      {:error, :stale_timestamp} ->
        Audit.log(:teller_webhook_signature_invalid, base_metadata)

        conn
        |> put_status(:bad_request)
        |> json(%{error: "stale signature"})

      {:error, :invalid_payload} ->
        Audit.log(:teller_webhook_invalid_payload, base_metadata)

        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid payload"})

      {:error, :nonce_missing} ->
        Audit.log(:teller_webhook_invalid_payload, base_metadata)

        conn
        |> put_status(:bad_request)
        |> json(%{error: "missing nonce"})

      {:error, :event_missing} ->
        Audit.log(:teller_webhook_invalid_payload, base_metadata)

        conn
        |> put_status(:bad_request)
        |> json(%{error: "missing event"})

      {:error, :connection_missing} ->
        Audit.log(:teller_webhook_invalid_payload, base_metadata)

        conn
        |> put_status(:bad_request)
        |> json(%{error: "missing connection"})
    end
  end

  defp process_event(connection_id, nonce, timestamp, event, payload, base_metadata) do
    metadata =
      base_metadata
      |> Map.put(:connection_id, connection_id)
      |> Map.put(:event, event)
      |> Map.put(:nonce, nonce)

    case Institutions.get_active_connection(connection_id) do
      {:error, :not_found} ->
        Audit.log(:teller_webhook_unknown_connection, metadata)
        {:ignored, :unknown_connection}

      {:error, :revoked} ->
        Audit.log(:teller_webhook_revoked_connection, metadata)
        {:ignored, :revoked}

      {:ok, %Connection{} = connection} ->
        Audit.log(:teller_webhook_received, metadata)

        timestamp_dt = DateTime.from_unix!(timestamp)

        if Webhooks.nonce_processed?(connection, nonce) do
          Audit.log(:teller_webhook_replayed, metadata)
          {:ignored, :duplicate}
        else
          handle_fresh_event(connection, nonce, timestamp_dt, event, payload, metadata)
        end
    end
  end

  defp handle_fresh_event(connection, nonce, timestamp, event, payload, metadata) do
    case Webhooks.record_event(connection, nonce, timestamp, %{event: event, payload: payload},
           retention: @nonce_retention
         ) do
      {:ok, connection} ->
        enqueue_sync(connection, event, metadata)

      {:error, reason} ->
        Audit.log(:teller_webhook_record_failed, Map.put(metadata, :error, inspect(reason)))
        {:error, :record_failed}
    end
  end

  defp enqueue_sync(connection, event, metadata) do
    telemetry_metadata = %{
      source: "teller_webhook",
      event: event,
      connection_id: connection.id
    }

    case Synchronization.schedule_incremental_sync(connection,
           telemetry_metadata: telemetry_metadata,
           unique_period: 60
         ) do
      :ok ->
        Audit.log(:teller_webhook_processed, metadata)
        {:ok, :enqueued}

      {:error, reason} ->
        if duplicate_job_error?(reason) do
          Audit.log(:teller_webhook_duplicate_job, metadata)
          {:ignored, :already_enqueued}
        else
          Audit.log(:teller_webhook_sync_failed, Map.put(metadata, :error, inspect(reason)))
          {:error, :enqueue_failed}
        end
    end
  end

  defp respond(conn, {:ok, _status}) do
    conn
    |> put_status(:ok)
    |> json(%{status: "ok"})
  end

  defp respond(conn, {:ignored, reason}) do
    conn
    |> put_status(:ok)
    |> json(%{status: "ignored", reason: to_string(reason)})
  end

  defp respond(conn, {:error, :enqueue_failed}) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: "failed to enqueue sync"})
  end

  defp respond(conn, {:error, :record_failed}) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: "failed to record webhook"})
  end

  defp respond(conn, {:error, _other}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "unable to process webhook"})
  end

  defp fetch_raw_body(%Plug.Conn{assigns: %{raw_body: body}}) when is_binary(body) do
    {:ok, body}
  end

  defp fetch_raw_body(_conn), do: {:error, :missing_body}

  defp parse_signature(conn) do
    case get_req_header(conn, @signature_header) do
      [header | _] ->
        parse_signature_values(String.split(header, ","))

      _ ->
        {:error, :invalid_signature}
    end
  end

  defp parse_signature_values(parts) do
    result =
      Enum.reduce_while(parts, {:ok, %{timestamp: nil, signatures: []}}, fn part, {:ok, acc} ->
        part
        |> String.trim()
        |> String.split("=", parts: 2)
        |> update_signature_acc(acc)
      end)

    case result do
      {:ok, %{timestamp: timestamp, signatures: signatures}}
      when is_integer(timestamp) and signatures != [] ->
        {:ok, timestamp, signatures}

      _ ->
        {:error, :invalid_signature}
    end
  end

  defp update_signature_acc(["t", value], acc) do
    case Integer.parse(String.trim(value)) do
      {timestamp, _} -> {:cont, {:ok, %{acc | timestamp: timestamp}}}
      :error -> {:halt, {:error, :invalid_signature}}
    end
  end

  defp update_signature_acc(["v1", value], acc) do
    signature = value |> String.trim() |> String.downcase()
    {:cont, {:ok, %{acc | signatures: [signature | acc.signatures]}}}
  end

  defp update_signature_acc(_other, acc), do: {:cont, {:ok, acc}}

  defp ensure_fresh(timestamp) do
    now = System.system_time(:second)

    if now - timestamp <= @timestamp_tolerance do
      :ok
    else
      {:error, :stale_timestamp}
    end
  end

  defp verify_signature(timestamp, raw_body, signatures) do
    secret = webhook_secret()
    signing_payload = "#{timestamp}.#{raw_body}"

    expected_signature =
      :crypto.mac(:hmac, :sha256, secret, signing_payload)
      |> Base.encode16(case: :lower)

    matches =
      Enum.any?(signatures, fn signature ->
        Plug.Crypto.secure_compare(signature, expected_signature)
      end)

    if matches do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp decode_payload(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :invalid_payload}
    end
  end

  defp fetch_nonce(payload) do
    case Map.get(payload, "nonce") do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, :nonce_missing}
    end
  end

  defp fetch_event(payload) do
    case Map.get(payload, "event") do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, :event_missing}
    end
  end

  defp fetch_connection_id(payload) do
    case Map.get(payload, "connection_id") do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, :connection_missing}
    end
  end

  defp webhook_secret do
    Application.fetch_env!(:money_tree, MoneyTree.Teller)
    |> Keyword.fetch!(:webhook_secret)
  end

  defp duplicate_job_error?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn {_field, {message, opts}} ->
      String.contains?(message, "unique") ||
        String.contains?(message, "already exists") ||
        Keyword.get(opts, :constraint) in [:unique, :unique_constraint]
    end)
  end

  defp duplicate_job_error?(_), do: false

  defp audit_metadata(extra) do
    Map.new(extra)
    |> Map.put_new(:source, "teller_webhook")
  end

  defp remote_ip(%Plug.Conn{remote_ip: nil}), do: "unknown"

  defp remote_ip(%Plug.Conn{remote_ip: ip}) do
    ip |> :inet.ntoa() |> to_string()
  end
end
