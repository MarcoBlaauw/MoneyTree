defmodule MoneyTree.ManualImportsTest do
  use MoneyTree.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import MoneyTree.AccountsFixtures

  alias Decimal
  alias MoneyTree.ManualImports
  alias MoneyTree.ManualImports.Batch
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.TransferMatch
  alias MoneyTree.Transactions.Transaction

  setup do
    user = user_fixture()
    account = account_fixture(user)
    other_user = user_fixture()
    other_account = account_fixture(other_user)

    %{user: user, account: account, other_account: other_account}
  end

  test "create_batch/2 enforces account access", %{
    user: user,
    account: account,
    other_account: other_account
  } do
    assert {:ok, %Batch{} = batch} =
             ManualImports.create_batch(user, %{
               account_id: account.id,
               file_name: "sample.csv",
               file_sha256: "abc123"
             })

    assert batch.account_id == account.id

    assert {:error, :not_found} =
             ManualImports.create_batch(user, %{account_id: other_account.id})
  end

  test "stage_rows/3 replaces rows and updates counts", %{user: user, account: account} do
    {:ok, batch} =
      ManualImports.create_batch(user, %{account_id: account.id, file_name: "sample.csv"})

    assert {:ok, %{batch: staged_batch, inserted_rows: 2}} =
             ManualImports.stage_rows(user, batch.id, [
               %{
                 posted_at: ~U[2026-04-20 10:00:00Z],
                 description: "Coffee",
                 amount: Decimal.new("-5.00"),
                 currency: "USD",
                 review_decision: "accept"
               },
               %{
                 posted_at: ~U[2026-04-21 10:00:00Z],
                 description: "Payroll",
                 amount: Decimal.new("2000.00"),
                 currency: "USD",
                 direction: "income",
                 review_decision: "accept"
               }
             ])

    assert staged_batch.status == "parsed"
    assert staged_batch.row_count == 2
    assert length(ManualImports.list_rows(user, batch.id)) == 2
  end

  test "commit_batch/2 inserts canonical transactions and marks rows committed", %{
    user: user,
    account: account
  } do
    {:ok, batch} = ManualImports.create_batch(user, %{account_id: account.id})

    {:ok, _} =
      ManualImports.stage_rows(user, batch.id, [
        %{
          posted_at: ~U[2026-04-20 10:00:00Z],
          description: "Target",
          merchant_name: "Target",
          amount: Decimal.new("-45.22"),
          currency: "USD",
          direction: "expense",
          review_decision: "accept"
        }
      ])

    assert {:ok, committed_batch} = ManualImports.commit_batch(user, batch.id)
    assert committed_batch.status == "committed"
    assert committed_batch.committed_count == 1

    [row] = ManualImports.list_rows(user, batch.id)
    assert row.parse_status == "committed"
    assert row.committed_transaction_id

    transaction = Repo.get!(Transaction, row.committed_transaction_id)
    assert transaction.source == "manual_import"
    assert transaction.manual_import_batch_id == batch.id
    assert transaction.manual_import_row_id == row.id
  end

  test "commit_batch/2 excludes exact duplicates by source transaction id", %{
    user: user,
    account: account
  } do
    existing =
      %Transaction{}
      |> Transaction.changeset(%{
        account_id: account.id,
        external_id: "existing-1",
        source: "manual_import",
        source_transaction_id: "tx-ref-1",
        source_reference: "ref-1",
        source_fingerprint: "existing-fp",
        normalized_fingerprint: "existing-nfp",
        posted_at: ~U[2026-04-20 10:00:00Z],
        amount: Decimal.new("-12.00"),
        currency: "USD",
        description: "Existing",
        status: "posted"
      })
      |> Repo.insert!()

    {:ok, batch} = ManualImports.create_batch(user, %{account_id: account.id})

    {:ok, _} =
      ManualImports.stage_rows(user, batch.id, [
        %{
          posted_at: ~U[2026-04-20 10:00:00Z],
          description: "Existing",
          amount: Decimal.new("-12.00"),
          currency: "USD",
          external_transaction_id: "tx-ref-1",
          source_reference: "ref-1",
          review_decision: "accept"
        }
      ])

    {:ok, committed_batch} = ManualImports.commit_batch(user, batch.id)
    assert committed_batch.duplicate_count == 1
    assert committed_batch.committed_count == 0

    [row] = ManualImports.list_rows(user, batch.id)
    assert row.parse_status == "excluded"
    assert row.review_decision == "exclude"
    assert row.duplicate_candidate_transaction_id == existing.id
  end

  test "commit_batch/2 returns account_required without account on batch", %{user: user} do
    {:ok, batch} = ManualImports.create_batch(user, %{file_name: "sample.csv"})
    assert {:error, :account_required} = ManualImports.commit_batch(user, batch.id)
  end

  test "commit_batch/2 auto-confirms high-confidence transfer matches", %{
    user: user,
    account: checking_account
  } do
    credit_account =
      account_fixture(user, %{
        name: "Credit Card",
        type: "credit",
        subtype: "credit_card",
        internal_account_kind: "credit_card"
      })

    existing_card_credit =
      %Transaction{}
      |> Transaction.changeset(%{
        account_id: credit_account.id,
        external_id: "existing-cc-credit",
        source: "plaid",
        source_transaction_id: "cc-credit-1",
        source_fingerprint: "existing-cc-fp",
        normalized_fingerprint: "existing-cc-nfp",
        posted_at: ~U[2026-04-20 10:00:00Z],
        amount: Decimal.new("250.00"),
        currency: "USD",
        description: "PAYMENT - THANK YOU",
        original_description: "PAYMENT - THANK YOU",
        merchant_name: "Amex",
        status: "posted"
      })
      |> Repo.insert!()

    {:ok, batch} = ManualImports.create_batch(user, %{account_id: checking_account.id})

    {:ok, _} =
      ManualImports.stage_rows(user, batch.id, [
        %{
          posted_at: ~U[2026-04-20 12:00:00Z],
          description: "AMEX AUTOPAY PAYMENT",
          original_description: "AMEX AUTOPAY PAYMENT",
          merchant_name: "American Express",
          amount: Decimal.new("-250.00"),
          currency: "USD",
          direction: "transfer",
          review_decision: "accept"
        }
      ])

    assert {:ok, committed_batch} = ManualImports.commit_batch(user, batch.id)
    assert committed_batch.committed_count == 1

    [row] = ManualImports.list_rows(user, batch.id)
    assert row.transfer_match_status == "auto_confirmed"
    assert row.transfer_match_candidate_transaction_id == existing_card_credit.id
    assert row.transfer_match_confidence

    imported_transaction = Repo.get!(Transaction, row.committed_transaction_id)
    assert imported_transaction.excluded_from_spending
    assert imported_transaction.transaction_kind == "credit_card_payment"

    existing_after_match = Repo.get!(Transaction, existing_card_credit.id)
    assert existing_after_match.excluded_from_spending
    assert existing_after_match.transaction_kind == "internal_transfer"

    assert Repo.one!(
             from(match in TransferMatch,
               where: match.outflow_transaction_id == ^imported_transaction.id,
               where: match.inflow_transaction_id == ^existing_card_credit.id
             )
           ).status == "auto_confirmed"
  end

  test "rollback_batch/2 removes committed transactions and marks batch rolled back", %{
    user: user,
    account: account
  } do
    {:ok, batch} = ManualImports.create_batch(user, %{account_id: account.id})

    {:ok, _} =
      ManualImports.stage_rows(user, batch.id, [
        %{
          posted_at: ~U[2026-04-22 10:00:00Z],
          description: "Rollback test",
          amount: Decimal.new("-14.25"),
          currency: "USD",
          direction: "expense",
          review_decision: "accept"
        }
      ])

    {:ok, committed_batch} = ManualImports.commit_batch(user, batch.id)
    assert committed_batch.status == "committed"

    [row_before_rollback] = ManualImports.list_rows(user, batch.id)
    assert row_before_rollback.committed_transaction_id
    assert Repo.get(Transaction, row_before_rollback.committed_transaction_id)

    assert {:ok, rolled_back_batch} = ManualImports.rollback_batch(user, batch.id)
    assert rolled_back_batch.status == "rolled_back"
    assert rolled_back_batch.committed_count == 0
    assert rolled_back_batch.rolled_back_at

    [row_after_rollback] = ManualImports.list_rows(user, batch.id)
    assert is_nil(row_after_rollback.committed_transaction_id)
  end

  test "rollback_batch/2 blocks when transfer match exists with transactions outside the batch",
       %{
         user: user,
         account: account
       } do
    savings =
      account_fixture(user, %{
        name: "Savings",
        type: "depository",
        subtype: "savings",
        internal_account_kind: "savings"
      })

    external_transaction =
      %Transaction{}
      |> Transaction.changeset(%{
        account_id: savings.id,
        external_id: "external-transfer-target",
        source: "manual_import",
        source_transaction_id: nil,
        source_fingerprint: "external-transfer-fp",
        normalized_fingerprint: "external-transfer-nfp",
        posted_at: ~U[2026-04-23 10:00:00Z],
        amount: Decimal.new("80.00"),
        currency: "USD",
        description: "TRANSFER FROM CHECKING",
        status: "posted"
      })
      |> Repo.insert!()

    {:ok, batch} = ManualImports.create_batch(user, %{account_id: account.id})

    {:ok, _} =
      ManualImports.stage_rows(user, batch.id, [
        %{
          posted_at: ~U[2026-04-23 11:00:00Z],
          description: "TRANSFER TO SAVINGS",
          amount: Decimal.new("-80.00"),
          currency: "USD",
          direction: "transfer",
          review_decision: "accept"
        }
      ])

    {:ok, _committed_batch} = ManualImports.commit_batch(user, batch.id)

    assert {:error, :unsafe_transfer_matches} = ManualImports.rollback_batch(user, batch.id)

    [row] = ManualImports.list_rows(user, batch.id)
    assert row.transfer_match_status == "auto_confirmed"
    assert row.transfer_match_candidate_transaction_id == external_transaction.id
    assert row.committed_transaction_id
  end
end
