defmodule MoneyTree.Notifications.Push do
  @moduledoc """
  Application-layer push delivery wrapper that resolves destinations and delegates
  to a configured provider adapter.
  """

  @behaviour MoneyTree.Notifications.Adapter

  alias MoneyTree.Notifications.NullDestinationResolver
  alias MoneyTree.Notifications.Push.DisabledAdapter
  alias MoneyTree.Notifications.Event
  alias MoneyTree.Users.User

  @impl true
  def channel, do: :push

  @impl true
  def deliver(%Event{} = event, %User{} = user, opts \\ []) do
    resolver =
      Application.get_env(
        :money_tree,
        :notification_destination_resolver,
        NullDestinationResolver
      )

    adapter = Application.get_env(:money_tree, :notification_push_adapter, DisabledAdapter)

    with {:ok, destination} <- resolver.resolve(user, :push, opts),
         {:ok, metadata} <-
           adapter.deliver(event, user, Keyword.put(opts, :destination, destination)) do
      {:ok,
       metadata
       |> Map.new()
       |> Map.put_new(:destination, destination)
       |> Map.put_new(:provider_adapter, inspect(adapter))}
    end
  end
end
