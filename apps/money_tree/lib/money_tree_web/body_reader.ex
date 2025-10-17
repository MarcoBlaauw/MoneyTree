defmodule MoneyTreeWeb.BodyReader do
  @moduledoc """
  Custom body reader that preserves the raw request payload for downstream consumers.

  Phoenix' JSON parser consumes the request body which makes it unavailable for
  signature verification. By capturing the raw payload here we keep the body accessible
  through `conn.assigns[:raw_body]` without otherwise affecting parsing behaviour.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:more, chunk, conn} ->
        conn = append_raw_body(conn, chunk)
        {:more, chunk, conn}

      {:ok, body, conn} ->
        conn = append_raw_body(conn, body)
        {:ok, body, conn}
    end
  end

  defp append_raw_body(conn, chunk) do
    existing = Map.get(conn.assigns, :raw_body, "")
    Plug.Conn.assign(conn, :raw_body, existing <> chunk)
  end
end
