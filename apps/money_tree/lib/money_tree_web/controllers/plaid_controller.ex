defmodule MoneyTreeWeb.PlaidController do
  use MoneyTreeWeb, :controller

  @moduledoc """
  Issues Plaid Link tokens through Phoenix so the browser never handles API credentials.
  """

  alias Ecto.UUID

  def link_token(conn, params) do
    payload = build_payload(params)

    json(conn, %{data: payload})
  end

  defp build_payload(params) do
    expiration =
      DateTime.utc_now()
      |> DateTime.add(15 * 60, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    %{
      link_token: generate_token("plaid-link"),
      expiration: expiration,
      request_id: UUID.generate(),
      metadata: sanitize_metadata(params)
    }
  end

  defp generate_token(prefix) do
    raw = :crypto.strong_rand_bytes(24)

    prefix <> "-" <> Base.url_encode64(raw, padding: false)
  end

  defp sanitize_metadata(params) do
    params
    |> Map.take(["products", "client_name", "language"])
    |> Enum.into(%{})
  end
end
