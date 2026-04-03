defmodule MoneyTree.Notifications.NullDestinationResolver do
  @moduledoc """
  Default destination resolver used until SMS and push destinations are modeled.
  """

  @behaviour MoneyTree.Notifications.DestinationResolver

  alias MoneyTree.Users.User

  @impl true
  def resolve(%User{}, _channel, _opts), do: {:error, :destination_unavailable}
end
