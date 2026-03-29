defmodule MoneyTree.Plaid.SyncWorker do
  @moduledoc """
  Provider worker for Plaid synchronization jobs.
  """

  use MoneyTree.SyncWorker, provider: :plaid, synchronizer: MoneyTree.Plaid.Synchronizer
end
