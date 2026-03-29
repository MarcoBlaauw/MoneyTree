defmodule MoneyTreeWeb.PlaidWebhookController do
  use MoneyTreeWeb, :controller

  alias MoneyTree.Institutions
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Plaid.Webhooks
  alias MoneyTree.Synchronization

  @signature_header "plaid-signature"
  @timestamp_header "plaid-timestamp"
  @nonce_retention 86_400

  def webhook(conn, _params) do
    with {:ok, raw_body} <- fetch_raw_body(conn),
         {:ok, timestamp} <- fetch_timestamp(conn),
         :ok <- verify_signature(conn, timestamp, raw_body),
         {:ok, payload} <- decode_payload(raw_body),
         {:ok, nonce} <- fetch_nonce(payload),
         {:ok, connection_id} <- fetch_connection_id(payload),
         {:ok, event} <- fetch_event(payload),
         result <- process_event(connection_id, nonce, timestamp, event, payload) do
      respond(conn, result)
    else
      {:error, _reason} -> conn |> put_status(:bad_request) |> json(%{error: "invalid webhook"})
    end
  end

  defp process_event(connection_id, nonce, timestamp, event, payload) do
    with {:ok, %Connection{} = connection} <- Institutions.get_active_connection(connection_id),
         false <- Webhooks.nonce_processed?(connection, nonce),
         {:ok, _connection} <-
           Webhooks.record_event(connection, nonce, DateTime.from_unix!(timestamp), %{event: event, payload: payload},
             retention: @nonce_retention
           ),
         :ok <-
           Synchronization.schedule_incremental_sync(connection,
             telemetry_metadata: %{source: "plaid_webhook", event: event, connection_id: connection.id},
             unique_period: 60
           ) do
      {:ok, :enqueued}
    else
      {:error, :not_found} -> {:ignored, :unknown_connection}
      {:error, :revoked} -> {:ignored, :revoked}
      true -> {:ignored, :duplicate}
      {:error, _} -> {:error, :processing_failed}
    end
  end

  defp verify_signature(conn, timestamp, raw_body) do
    with [signature | _] <- get_req_header(conn, @signature_header),
         expected <- expected_signature(timestamp, raw_body),
         true <- Plug.Crypto.secure_compare(String.downcase(signature), expected) do
      :ok
    else
      _ -> {:error, :invalid_signature}
    end
  end

  defp expected_signature(timestamp, raw_body) do
    :crypto.mac(:hmac, :sha256, webhook_secret(), "#{timestamp}.#{raw_body}")
    |> Base.encode16(case: :lower)
  end

  defp fetch_timestamp(conn) do
    case get_req_header(conn, @timestamp_header) do
      [value | _] ->
        case Integer.parse(value) do
          {ts, _} -> {:ok, ts}
          :error -> {:error, :invalid_timestamp}
        end

      _ ->
        {:error, :missing_timestamp}
    end
  end

  defp fetch_raw_body(%Plug.Conn{assigns: %{raw_body: body}}) when is_binary(body), do: {:ok, body}
  defp fetch_raw_body(_conn), do: {:error, :missing_body}

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
    Application.fetch_env!(:money_tree, MoneyTree.Plaid)
    |> Keyword.fetch!(:webhook_secret)
  end

  defp respond(conn, {:ok, _}) do
    conn |> put_status(:ok) |> json(%{status: "ok"})
  end

  defp respond(conn, {:ignored, reason}) do
    conn |> put_status(:ok) |> json(%{status: "ignored", reason: to_string(reason)})
  end

  defp respond(conn, {:error, _}) do
    conn |> put_status(:internal_server_error) |> json(%{error: "failed to process webhook"})
  end
end
