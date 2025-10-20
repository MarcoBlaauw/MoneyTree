defmodule MoneyTree.LoansTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Loans
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

  test "overview returns autopay schedule details" do
    user = user_fixture()

    loan =
      account_fixture(user, %{
        name: "Auto Loan",
        type: "loan",
        subtype: "auto",
        current_balance: Decimal.new("8000.00")
      })

    insert_transaction(loan, Decimal.new("-200.00"))

    [entry] = Loans.overview(user)

    assert entry.account.name == "Auto Loan"
    assert entry.autopay.enabled?
    assert is_binary(entry.autopay.payment_amount)
    assert %Date{} = entry.autopay.next_run_on
    assert entry.last_payment_masked =~ "••"
  end

  defp insert_transaction(%Account{} = account, amount) do
    params = %{
      external_id: System.unique_integer([:positive]) |> Integer.to_string(),
      amount: amount,
      currency: account.currency,
      type: "loan",
      posted_at: DateTime.utc_now(),
      description: "Payment",
      status: "posted",
      account_id: account.id
    }

    %Transaction{}
    |> Transaction.changeset(params)
    |> Repo.insert!()
  end
end
