defmodule MoneyTreeWeb.BudgetLiveTest do
  use MoneyTreeWeb.ConnCase, async: true

  import MoneyTree.AccountsFixtures
  import Phoenix.LiveViewTest

  alias MoneyTree.Budgets
  alias MoneyTree.Budgets.Budget
  alias MoneyTree.Repo

  setup :register_and_log_in_user

  test "users can manage budgets", %{conn: conn, user: user} do
    {:ok, view, html} = live(conn, ~p"/app/budgets")

    assert html =~ "Budgets"
    assert html =~ "New budget"

    params = %{
      "budget" => %{
        "name" => "Housing",
        "period" => "monthly",
        "allocation_amount" => "2500.00",
        "currency" => "USD",
        "entry_type" => "expense",
        "variability" => "fixed"
      }
    }

    view |> form("#budget-form", params) |> render_submit()

    rendered = render(view)
    assert rendered =~ "Budget created successfully."
    assert rendered =~ "Housing"

    budget = Repo.get_by!(Budget, name: "Housing", user_id: user.id)

    view |> element("#budget-#{budget.id} [phx-click=\"edit-budget\"]") |> render_click()
    assert render(view) =~ "Update budget"

    update_params = %{
      "budget" => %{
        "name" => "Housing Essentials",
        "period" => "monthly",
        "allocation_amount" => "2600.00",
        "currency" => "USD",
        "entry_type" => "expense",
        "variability" => "fixed"
      }
    }

    view |> form("#budget-form", update_params) |> render_submit()

    rendered = render(view)
    assert rendered =~ "Budget updated successfully."
    assert rendered =~ "Housing Essentials"

    view |> element("#budget-#{budget.id} [phx-click=\"delete-budget\"]") |> render_click()

    rendered = render(view)
    assert rendered =~ "Budget removed successfully."
    refute rendered =~ "Housing Essentials"
  end

  test "lists only budgets owned by the user", %{conn: conn, user: user} do
    {:ok, own_budget} =
      Budgets.create_budget(user, %{
        name: "Groceries",
        period: :monthly,
        allocation_amount: "300.00",
        currency: "USD",
        entry_type: :expense,
        variability: :variable
      })

    other_user = user_fixture(%{email: "other@example.com"})

    {:ok, _} =
      Budgets.create_budget(other_user, %{
        name: "Other Budget",
        period: :monthly,
        allocation_amount: "100.00",
        currency: "USD",
        entry_type: :expense,
        variability: :fixed
      })

    {:ok, _view, html} = live(conn, ~p"/app/budgets")

    assert html =~ own_budget.name
    refute html =~ "Other Budget"
  end
end
