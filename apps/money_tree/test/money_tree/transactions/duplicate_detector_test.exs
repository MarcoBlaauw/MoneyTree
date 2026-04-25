defmodule MoneyTree.Transactions.DuplicateDetectorTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures

  alias Decimal
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.DuplicateDetector
  alias MoneyTree.Transactions.Fingerprints
  alias MoneyTree.Transactions.Transaction

  setup do
    user = user_fixture()
    account = account_fixture(user)

    %{account: account}
  end

  test "returns exact for source transaction ID matches", %{account: account} do
    create_transaction!(account, %{
      source: "plaid",
      source_transaction_id: "plaid-txn-1",
      source_reference: "ref-1",
      description: "Payment"
    })

    result =
      DuplicateDetector.detect(%{
        account_id: account.id,
        source: "plaid",
        source_transaction_id: "plaid-txn-1",
        posted_at: ~U[2026-04-20 10:00:00Z],
        amount: Decimal.new("-10.00"),
        description: "Payment",
        currency: "USD"
      })

    assert result.status == :exact
    assert result.candidate_transaction_id
  end

  test "returns high for same normalized fingerprint when exact IDs are absent", %{
    account: account
  } do
    posted_at = ~U[2026-04-20 10:00:00Z]

    attrs = %{
      account_id: account.id,
      source: "manual_import",
      source_transaction_id: nil,
      posted_at: posted_at,
      amount: Decimal.new("-120.00"),
      description: "ALLY TRANSFER",
      merchant_name: "Ally Transfer",
      currency: "USD"
    }

    normalized_fingerprint = Fingerprints.normalized_fingerprint(attrs)

    create_transaction!(account, %{
      source: "manual_import",
      source_transaction_id: nil,
      description: "ALLY TRANSFER",
      merchant_name: "Ally Transfer",
      posted_at: posted_at,
      amount: Decimal.new("-120.00"),
      normalized_fingerprint: normalized_fingerprint
    })

    result = DuplicateDetector.detect(attrs)

    assert result.status == :high
    assert result.candidate_transaction_id
  end

  test "returns none for unrelated transaction", %{account: account} do
    create_transaction!(account, %{
      source: "plaid",
      source_transaction_id: "other-id",
      description: "Coffee",
      posted_at: ~U[2026-04-20 10:00:00Z],
      amount: Decimal.new("-4.00")
    })

    result =
      DuplicateDetector.detect(%{
        account_id: account.id,
        source: "manual_import",
        source_transaction_id: nil,
        posted_at: ~U[2026-04-23 10:00:00Z],
        amount: Decimal.new("-200.00"),
        description: "Mortgage",
        merchant_name: "Lender",
        currency: "USD"
      })

    assert result.status == :none
    assert is_nil(result.candidate_transaction_id)
  end

  defp create_transaction!(account, attrs) do
    base = %{
      external_id: "txn-#{System.unique_integer([:positive])}",
      source: "unknown",
      amount: Decimal.new("-10.00"),
      currency: account.currency,
      posted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      description: "Txn",
      status: "posted",
      account_id: account.id
    }

    payload =
      base
      |> Map.merge(attrs)
      |> put_new_fingerprint(:source_fingerprint, &Fingerprints.source_fingerprint/1)
      |> put_new_fingerprint(:normalized_fingerprint, &Fingerprints.normalized_fingerprint/1)

    %Transaction{}
    |> Transaction.changeset(payload)
    |> Repo.insert!()
  end

  defp put_new_fingerprint(attrs, field, fun) do
    if Map.get(attrs, field) do
      attrs
    else
      Map.put(attrs, field, fun.(attrs))
    end
  end
end
