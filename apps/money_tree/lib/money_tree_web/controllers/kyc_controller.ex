defmodule MoneyTreeWeb.KycController do
  use MoneyTreeWeb, :controller

  @moduledoc """
  Generates vendor agnostic KYC sessions while redacting sensitive applicant data.
  """

  alias Ecto.UUID

  @default_environment "sandbox"

  def create_session(conn, params) do
    payload = build_session(params)

    json(conn, %{data: payload})
  end

  defp build_session(params) do
    environment = Map.get(params, "environment", @default_environment)

    %{
      session_id: UUID.generate(),
      client_token: generate_token("persona-session"),
      environment: environment,
      expires_at: expires_at(),
      applicant: redact_applicant(params["applicant"] || %{})
    }
  end

  defp expires_at do
    DateTime.utc_now()
    |> DateTime.add(10 * 60, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp generate_token(prefix) do
    raw = :crypto.strong_rand_bytes(24)
    prefix <> "-" <> Base.url_encode64(raw, padding: false)
  end

  defp redact_applicant(applicant) when is_map(applicant) do
    applicant
    |> Enum.map(fn {key, value} ->
      sanitized_value =
        case String.downcase(to_string(key)) do
          "ssn" -> mask(value)
          "email" -> mask_email(value)
          "document_number" -> mask(value)
          _ -> value
        end

      {key, sanitized_value}
    end)
    |> Enum.into(%{})
  end

  defp redact_applicant(_), do: %{}

  defp mask(value) when is_binary(value) do
    suffix = String.slice(value, -4, 4)
    "***" <> suffix
  end

  defp mask(_), do: "***"

  defp mask_email(value) when is_binary(value) do
    case String.split(value, "@", parts: 2) do
      [local, domain] ->
        visible = String.slice(local, -1, 1)
        masked_local = "***" <> (visible || "")
        masked_local <> "@" <> domain

      _ -> mask(value)
    end
  end

  defp mask_email(other), do: mask(other)
end
