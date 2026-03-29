defmodule MoneyTree.Teller.SyncWorker do
  @moduledoc """
  Provider worker for Teller synchronization jobs.
  """

  use MoneyTree.SyncWorker, provider: :teller, synchronizer: MoneyTree.Teller.Synchronizer
end
