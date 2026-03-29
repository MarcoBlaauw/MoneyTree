defmodule MoneyTree.Plaid.Webhooks do
  @moduledoc """
  Replay protection helpers for Plaid webhook deliveries.
  """

  alias MoneyTree.Teller.Webhooks

  @spec nonce_processed?(struct(), String.t()) :: boolean()
  def nonce_processed?(connection, nonce), do: Webhooks.nonce_processed?(connection, nonce)

  @spec record_event(struct(), String.t(), DateTime.t(), map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def record_event(connection, nonce, timestamp, payload, opts \\ []) do
    Webhooks.record_event(connection, nonce, timestamp, payload, opts)
  end
end
