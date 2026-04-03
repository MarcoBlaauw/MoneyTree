defmodule MoneyTree.Notifications.SMS.DisabledAdapter do
  @moduledoc """
  Default SMS adapter used until a provider-specific implementation is configured.
  """

  @behaviour MoneyTree.Notifications.Adapter

  alias MoneyTree.Notifications.Event
  alias MoneyTree.Users.User

  @impl true
  def channel, do: :sms

  @impl true
  def deliver(%Event{}, %User{}, _opts), do: {:error, :sms_adapter_not_configured}
end
