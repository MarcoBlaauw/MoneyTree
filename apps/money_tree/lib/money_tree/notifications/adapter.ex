defmodule MoneyTree.Notifications.Adapter do
  @moduledoc """
  Behaviour for durable notification delivery adapters.
  """

  alias MoneyTree.Notifications.Event
  alias MoneyTree.Users.User

  @callback channel() :: :email | :sms | :push
  @callback deliver(Event.t(), User.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
end
