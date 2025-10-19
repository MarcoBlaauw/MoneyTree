defmodule MoneyTreeWeb.Plugs.RequireAuthenticatedUser do
  @moduledoc """
  Ensures browser and LiveView requests are authenticated.
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [current_path: 1, put_flash: 3, redirect: 2]

  alias Phoenix.Component
  alias Phoenix.LiveView

  alias MoneyTree.Accounts

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      nil ->
        conn
        |> maybe_store_return_path()
        |> put_flash(:error, "You must sign in to continue.")
        |> redirect(to: "/login")
        |> halt()

      _user ->
        conn
    end
  end

  def on_mount(:default, _params, session, socket) do
    case Map.get(session, "user_token") do
      nil ->
        {:halt,
         LiveView.put_flash(socket, :error, "You must sign in to continue.")
         |> LiveView.redirect(to: "/login")}

      token ->
        case Accounts.get_user_by_session_token(token) do
          {:ok, user} ->
            {:cont, Component.assign(socket, :current_user, user)}

          {:error, _reason} ->
            {:halt,
             socket
             |> LiveView.put_flash(:error, "You must sign in to continue.")
             |> LiveView.redirect(to: "/login")}
        end
    end
  end

  defp maybe_store_return_path(%Plug.Conn{method: "GET"} = conn) do
    conn
    |> put_session(:user_return_to, current_path(conn))
  end

  defp maybe_store_return_path(conn), do: conn
end
