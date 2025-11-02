defmodule MoneyTree.BudgetsTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Budgets
  alias MoneyTree.Budgets.Budget
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

  test "aggregate_totals groups spend by budget name" do
    user = user_fixture()
    account = account_fixture(user)

    {:ok, _} =
      Budgets.create_budget(user, %{
        name: "Housing",
        period: :monthly,
        allocation_amount: "2500.00",
        currency: "USD",
        entry_type: :expense,
        variability: :fixed
      })

    {:ok, _} =
      Budgets.create_budget(user, %{
        name: "Groceries",
        period: :monthly,
        allocation_amount: "600.00",
        currency: "USD",
        entry_type: :expense,
        variability: :variable
      })

    insert_transaction(account, %{
      amount: Decimal.new("3000.00"),
      category: "Housing",
      description: "Rent"
    })

    insert_transaction(account, %{
      amount: Decimal.new("150.00"),
      category: "Groceries",
      description: "Market"
    })

    budgets = Budgets.aggregate_totals(user)

    assert %{status: :over, spent: "USD 3000.00"} = Enum.find(budgets, &(&1.name == "Housing"))
    assert %{status: :under} = Enum.find(budgets, &(&1.name == "Groceries"))
  end

  describe "budget persistence" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "create_budget/2 stores records with formatting helpers", %{user: user} do
      assert {:ok, %Budget{} = budget} = Budgets.create_budget(user, valid_budget_attrs())

      reloaded = Budgets.get_budget!(user, budget.id)
      assert reloaded.currency == "USD"
      assert reloaded.period == :monthly
      assert reloaded.entry_type == :expense
      assert reloaded.variability == :fixed

      formatted = Budgets.format_budget(reloaded)
      assert formatted.period == "Monthly"
      assert formatted.entry_type == "Expense"
      assert formatted.variability == "Fixed"
      assert formatted.allocation_formatted == "USD 2500.00"
      assert formatted.allocation_masked != formatted.allocation_formatted
      assert Budgets.format_allocation(reloaded) == "USD 2500.00"
      assert Budgets.mask_allocation(reloaded) == formatted.allocation_masked
    end

    test "create_budget/2 rejects duplicate names per period", %{user: user} do
      attrs = valid_budget_attrs()
      assert {:ok, %Budget{}} = Budgets.create_budget(user, attrs)
      assert {:error, changeset} = Budgets.create_budget(user, attrs)
      assert "has already been taken" in errors_on(changeset).name
    end

    test "create_budget/2 validates positive allocation", %{user: user} do
      attrs = valid_budget_attrs(%{allocation_amount: "0"})

      assert {:error, changeset} = Budgets.create_budget(user, attrs)
      assert "must be greater than zero" in errors_on(changeset).allocation_amount

      {:ok, budget} = Budgets.create_budget(user, valid_budget_attrs())
      assert {:error, update_changeset} = Budgets.update_budget(budget, %{allocation_amount: "-10"})
      assert "must be greater than zero" in errors_on(update_changeset).allocation_amount
    end

    test "list_budgets/2 filters by classification fields", %{user: user} do
      {:ok, monthly_expense} =
        Budgets.create_budget(user, %{
          name: "Rent",
          period: :monthly,
          allocation_amount: "2000",
          currency: "USD",
          entry_type: :expense,
          variability: :fixed
        })

      {:ok, yearly_income} =
        Budgets.create_budget(user, %{
          name: "Bonus",
          period: :yearly,
          allocation_amount: "5000",
          currency: "USD",
          entry_type: :income,
          variability: :variable
        })

      {:ok, weekly_variable} =
        Budgets.create_budget(user, %{
          name: "Snacks",
          period: :weekly,
          allocation_amount: "150",
          currency: "USD",
          entry_type: :expense,
          variability: :variable
        })

      assert [^monthly_expense] = Budgets.list_budgets(user, period: :monthly)
      assert [^yearly_income] = Budgets.list_budgets(user, entry_type: :income)

      variability_ids =
        Budgets.list_budgets(user, variability: :variable)
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert Enum.sort([yearly_income.id, weekly_variable.id]) == variability_ids
    end
  end

  defp insert_transaction(%Account{} = account, attrs) do
    params = %{
      external_id: System.unique_integer([:positive]) |> Integer.to_string(),
      amount: Map.fetch!(attrs, :amount),
      currency: account.currency,
      type: "card",
      posted_at: DateTime.utc_now(),
      description: Map.get(attrs, :description, "Budget Test"),
      category: Map.get(attrs, :category),
      status: "posted",
      account_id: account.id
    }

    %Transaction{}
    |> Transaction.changeset(params)
    |> Repo.insert!()
  end

  defp valid_budget_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "Housing",
        period: :monthly,
        allocation_amount: "2500.00",
        currency: "usd",
        entry_type: :expense,
        variability: :fixed
      },
      overrides
    )
  end
end
