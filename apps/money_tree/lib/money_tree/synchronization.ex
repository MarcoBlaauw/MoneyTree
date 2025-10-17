defmodule MoneyTree.Synchronization do
  @moduledoc """
  Coordinates synchronization workflows triggered by Teller integrations.

  This module acts as an integration point so controllers and other contexts can
  schedule synchronization jobs without needing to know the specific worker
  implementation. Subsequent tasks can expand the underlying behaviour without
  changing the calling code.
  """

  alias MoneyTree.Institutions.Connection

  @spec schedule_initial_sync(Connection.t()) :: :ok | {:error, term()}
  def schedule_initial_sync(%Connection{}), do: :ok
end
