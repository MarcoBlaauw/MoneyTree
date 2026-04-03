defmodule MoneyTreeWeb.SettingsController do
  use MoneyTreeWeb, :controller

  alias MoneyTree.Accounts
  alias MoneyTree.Notifications
  require Logger

  def show(%{assigns: %{current_user: current_user}} = conn, _params) do
    settings = Accounts.user_settings(current_user)

    profile = Map.get(settings, :profile, %{})

    data = %{
      profile: Map.put(profile, :display_name, display_name(profile)),
      security: Map.get(settings, :security, %{}),
      notifications: Map.get(settings, :notifications, %{}),
      sessions: Map.get(settings, :sessions, [])
    }

    json(conn, %{data: data})
  end

  def update_profile(%{assigns: %{current_user: current_user}} = conn, %{"profile" => params}) do
    case Accounts.update_user_profile(current_user, params) do
      {:ok, updated_user} ->
        settings = Accounts.user_settings(updated_user)
        profile = Map.get(settings, :profile, %{})

        json(conn, %{data: %{profile: Map.put(profile, :display_name, display_name(profile))}})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def create_webauthn_registration_options(
        %{assigns: %{current_user: current_user}} = conn,
        params
      ) do
    case Accounts.create_webauthn_registration_options(
           current_user,
           Map.merge(params, webauthn_request_context(conn))
         ) do
      {:ok, challenge, options} ->
        json(conn, %{data: %{challenge: challenge_payload(challenge), options: options}})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def create_webauthn_authentication_options(
        %{assigns: %{current_user: current_user}} = conn,
        params
      ) do
    case Accounts.create_webauthn_authentication_options(
           current_user,
           Map.merge(params, webauthn_request_context(conn))
         ) do
      {:ok, challenge, options} ->
        json(conn, %{data: %{challenge: challenge_payload(challenge), options: options}})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def complete_webauthn_registration(
        %{assigns: %{current_user: current_user}} = conn,
        %{"challenge_id" => challenge_id} = params
      ) do
    case Accounts.complete_webauthn_registration(current_user, challenge_id, params) do
      {:ok, credential} ->
        json(conn, %{data: %{credential: credential_payload(credential)}})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: error_message(reason)})
    end
  end

  def revoke_webauthn_credential(
        %{assigns: %{current_user: current_user}} = conn,
        %{"id" => id}
      ) do
    case Accounts.revoke_webauthn_credential(current_user, id) do
      {:ok, _credential} ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "credential not found"})
    end
  end

  def update_notifications(%{assigns: %{current_user: current_user}} = conn, %{
        "notifications" => params
      }) do
    case Notifications.upsert_alert_preference(current_user, params) do
      {:ok, _preference} ->
        settings = Accounts.user_settings(current_user)
        json(conn, %{data: %{notifications: Map.get(settings, :notifications, %{})}})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  defp display_name(profile) when is_map(profile) do
    profile
    |> Map.get(:full_name)
    |> maybe_from_full_name(profile)
  end

  defp display_name(_), do: nil

  defp maybe_from_full_name(full_name, profile) when is_binary(full_name) do
    full_name = String.trim(full_name)

    if full_name == "" do
      email_prefix(profile)
    else
      full_name
    end
  end

  defp maybe_from_full_name(_full_name, profile) do
    email_prefix(profile)
  end

  defp email_prefix(profile) do
    profile
    |> Map.get(:email)
    |> case do
      email when is_binary(email) ->
        email
        |> String.trim()
        |> String.split("@", parts: 2)
        |> List.first()

      _ ->
        nil
    end
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp challenge_payload(challenge) do
    %{
      id: challenge.id,
      purpose: challenge.purpose,
      expires_at: challenge.expires_at,
      rp_id: challenge.rp_id,
      origin: challenge.origin
    }
  end

  defp credential_payload(credential) do
    %{
      id: credential.id,
      label: credential.label,
      kind: credential.kind,
      attachment: credential.attachment,
      inserted_at: credential.inserted_at
    }
  end

  defp error_message(:not_found), do: "challenge not found"
  defp error_message(:expired), do: "challenge expired"
  defp error_message(:already_used), do: "challenge already used"
  defp error_message(:invalid_response), do: "invalid webauthn response"
  defp error_message(:invalid_credentials), do: "credential not recognized"
  defp error_message(%_{} = error), do: Exception.message(error)
  defp error_message(_), do: "unable to verify webauthn response"

  defp webauthn_request_context(conn) do
    origin = request_origin(conn)
    rp_id = URI.parse(origin).host || conn.host

    Logger.debug(
      "WebAuthn request context (settings): origin_header=#{inspect(List.first(get_req_header(conn, "origin")))} host=#{inspect(conn.host)} port=#{inspect(conn.port)} computed_origin=#{inspect(origin)} rp_id=#{inspect(rp_id)}"
    )

    %{
      "origin" => origin,
      "rp_id" => rp_id
    }
  end

  defp request_origin(conn) do
    case List.first(get_req_header(conn, "origin")) do
      origin when is_binary(origin) and origin != "" ->
        origin

      _ ->
        scheme = Atom.to_string(conn.scheme)
        port = conn.port
        host = conn.host

        case {scheme, port} do
          {"http", 80} -> "#{scheme}://#{host}"
          {"https", 443} -> "#{scheme}://#{host}"
          _ -> "#{scheme}://#{host}:#{port}"
        end
    end
  end
end
