defmodule MoneyTree.SimpleFin.SyncWorker do
  @moduledoc """
  Provider worker for SimpleFIN synchronization jobs.
  """

  use MoneyTree.SyncWorker, provider: :simplefin, synchronizer: MoneyTree.SimpleFin.Synchronizer
end
