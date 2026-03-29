defmodule MoneyTree.Plaid.Client do
  @moduledoc """
  Default Plaid client adapter placeholder.
  """

  @spec exchange_public_token(String.t()) :: {:ok, map()} | {:error, term()}
  def exchange_public_token(_public_token), do: {:error, %{type: :unexpected, details: %{message: "not implemented"}}}

  @spec list_accounts(map()) :: {:ok, map()} | {:error, term()}
  def list_accounts(_params), do: {:ok, %{"data" => [], "next_cursor" => nil}}

  @spec list_transactions(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def list_transactions(_account_id, _params), do: {:ok, %{"data" => [], "next_cursor" => nil}}
end
