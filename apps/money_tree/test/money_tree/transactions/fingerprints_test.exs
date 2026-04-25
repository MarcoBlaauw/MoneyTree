defmodule MoneyTree.Transactions.FingerprintsTest do
  use ExUnit.Case, async: true

  alias Decimal
  alias MoneyTree.Transactions.Fingerprints

  test "source fingerprint is deterministic for equivalent inputs" do
    attrs = %{
      source: "plaid",
      account_id: "acct-1",
      source_transaction_id: "txn-1",
      source_reference: "ref-1",
      posted_at: ~U[2026-04-20 10:00:00Z],
      amount: Decimal.new("-42.50"),
      original_description: "AMEX AUTOPAYMENT",
      currency: "usd"
    }

    same_attrs =
      attrs
      |> Map.put(:currency, "USD")
      |> Map.put(:original_description, "  amex   autopayment ")

    assert Fingerprints.source_fingerprint(attrs) == Fingerprints.source_fingerprint(same_attrs)
  end

  test "normalized fingerprint changes when merchant text changes" do
    left = %{
      account_id: "acct-1",
      posted_at: ~U[2026-04-20 10:00:00Z],
      amount: Decimal.new("-42.50"),
      merchant_name: "Target Store 1234",
      description: "target store 1234",
      currency: "USD"
    }

    right = Map.put(left, :merchant_name, "Whole Foods")

    refute Fingerprints.normalized_fingerprint(left) ==
             Fingerprints.normalized_fingerprint(right)
  end
end
