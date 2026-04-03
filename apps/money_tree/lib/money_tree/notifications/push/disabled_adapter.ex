defmodule MoneyTree.Notifications.Push.DisabledAdapter do
  @moduledoc """
  Default push adapter used until a provider-specific implementation is configured.
  """

  @behaviour MoneyTree.Notifications.Adapter

  alias MoneyTree.Notifications.Event
  alias MoneyTree.Users.User

  @impl true
  def channel, do: :push

  @impl true
  def deliver(%Event{}, %User{}, _opts), do: {:error, :push_adapter_not_configured}
end
