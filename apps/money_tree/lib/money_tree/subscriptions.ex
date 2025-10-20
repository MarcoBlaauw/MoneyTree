defmodule MoneyTree.Subscriptions do
  @moduledoc """
  Convenience wrapper for subscription spending queries used on the dashboard.
  """

  alias MoneyTree.Transactions
  alias MoneyTree.Users.User

  @doc """
  Returns summary metrics for subscription-related activity.
  """
  @spec spend_summary(User.t() | binary(), keyword()) :: map()
  def spend_summary(user, opts \\ []) do
    Transactions.subscription_spend(user, opts)
  end
end
