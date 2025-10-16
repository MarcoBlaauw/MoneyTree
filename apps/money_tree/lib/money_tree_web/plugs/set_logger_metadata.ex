defmodule MoneyTreeWeb.Plugs.SetLoggerMetadata do
  @moduledoc """
  Attaches request-specific metadata to the logger for downstream log lines.
  """

  @behaviour Plug

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Logger.metadata(remote_ip: format_remote_ip(conn))
    conn
  end

  defp format_remote_ip(%Plug.Conn{remote_ip: nil}), do: nil

  defp format_remote_ip(%Plug.Conn{remote_ip: tuple}) do
    tuple
    |> :inet.ntoa()
    |> to_string()
  end
end
