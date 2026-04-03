defmodule MoneyTree.Notifications.DestinationResolver do
  @moduledoc """
  Behaviour for resolving non-email delivery destinations for a user.
  """

  alias MoneyTree.Users.User

  @callback resolve(User.t(), :sms | :push, keyword()) ::
              {:ok, map()} | {:error, term()}
end
