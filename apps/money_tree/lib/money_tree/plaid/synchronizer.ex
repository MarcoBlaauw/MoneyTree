defmodule MoneyTree.Plaid.Synchronizer do
  @moduledoc """
  Synchronizes Plaid accounts and transactions while reusing shared persistence semantics.
  """

  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Teller.Synchronizer, as: SharedSynchronizer

  @spec sync(Connection.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync(%Connection{} = connection, opts \\ []) do
    client =
      Keyword.get(opts, :client, Application.get_env(:money_tree, :plaid_client, MoneyTree.Plaid.Client))

    SharedSynchronizer.sync(connection, Keyword.put(opts, :client, client))
  end
end
