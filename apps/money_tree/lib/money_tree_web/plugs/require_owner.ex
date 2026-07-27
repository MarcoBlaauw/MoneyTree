defmodule MoneyTreeWeb.Plugs.RequireOwner do
  @moduledoc """
  Restricts LiveView mounts to users with the owner role.

  Must run after `MoneyTreeWeb.Plugs.RequireAuthenticatedUser` in a live_session's
  `on_mount` list so `:current_user` is already assigned.
  """

  alias Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    case socket.assigns[:current_user] do
      %{role: :owner} ->
        {:cont, socket}

      _user ->
        {:halt,
         socket
         |> LiveView.put_flash(:error, "You do not have access to that page.")
         |> LiveView.redirect(to: "/app")}
    end
  end
end
