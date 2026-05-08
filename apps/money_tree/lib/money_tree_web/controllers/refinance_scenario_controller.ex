defmodule MoneyTreeWeb.RefinanceScenarioController do
  use MoneyTreeWeb, :controller

  alias Ecto.Changeset
  alias MoneyTree.Loans
  alias MoneyTree.Loans.RefinanceAnalysisResult
  alias MoneyTree.Loans.RefinanceFeeItem
  alias MoneyTree.Loans.RefinanceScenario

  def index(%{assigns: %{current_user: current_user}} = conn, %{"loan_id" => loan_id}) do
    scenarios =
      current_user
      |> Loans.list_refinance_scenarios(loan_id)
      |> Enum.map(&serialize_scenario/1)

    json(conn, %{data: scenarios})
  end

  def show(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case Loans.fetch_refinance_scenario(current_user, id) do
      {:ok, scenario} ->
        json(conn, %{data: serialize_scenario(scenario)})

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  def create(%{assigns: %{current_user: current_user}} = conn, %{"loan_id" => loan_id} = params) do
    attrs = Map.delete(params, "loan_id")

    case Loans.create_refinance_scenario(current_user, loan_id, attrs) do
      {:ok, scenario} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_scenario(scenario)})

      {:error, :not_found} ->
        loan_not_found(conn)

      {:error, %Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  def update(%{assigns: %{current_user: current_user}} = conn, %{"id" => id} = params) do
    attrs = Map.delete(params, "id")

    case Loans.update_refinance_scenario(current_user, id, attrs) do
      {:ok, scenario} ->
        json(conn, %{data: serialize_scenario(scenario)})

      {:error, :not_found} ->
        not_found(conn)

      {:error, %Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  def delete(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case Loans.delete_refinance_scenario(current_user, id) do
      {:ok, _scenario} ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  def create_fee_item(%{assigns: %{current_user: current_user}} = conn, %{"id" => id} = params) do
    attrs = Map.delete(params, "id")

    case Loans.create_refinance_fee_item(current_user, id, attrs) do
      {:ok, fee_item} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_fee_item(fee_item)})

      {:error, :not_found} ->
        not_found(conn)

      {:error, %Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  def analyze(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case Loans.analyze_refinance_scenario(current_user, id) do
      {:ok, result} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_analysis_result(result)})

      {:error, :not_found} ->
        not_found(conn)

      {:error, %Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  defp serialize_scenario(%RefinanceScenario{} = scenario) do
    %{
      id: scenario.id,
      user_id: scenario.user_id,
      mortgage_id: scenario.mortgage_id,
      lender_quote_id: scenario.lender_quote_id,
      name: scenario.name,
      scenario_type: scenario.scenario_type,
      product_type: scenario.product_type,
      new_term_months: scenario.new_term_months,
      new_interest_rate: scenario.new_interest_rate,
      new_apr: scenario.new_apr,
      new_principal_amount: scenario.new_principal_amount,
      cash_out_amount: scenario.cash_out_amount,
      cash_in_amount: scenario.cash_in_amount,
      roll_costs_into_loan: scenario.roll_costs_into_loan,
      points: scenario.points,
      lender_credit_amount: scenario.lender_credit_amount,
      expected_years_before_sale_or_refi: scenario.expected_years_before_sale_or_refi,
      closing_date_assumption: scenario.closing_date_assumption,
      rate_source_type: scenario.rate_source_type,
      status: scenario.status,
      fee_items: serialize_loaded_many(scenario.fee_items, &serialize_fee_item/1),
      inserted_at: scenario.inserted_at,
      updated_at: scenario.updated_at
    }
  end

  defp serialize_fee_item(%RefinanceFeeItem{} = fee_item) do
    %{
      id: fee_item.id,
      refinance_scenario_id: fee_item.refinance_scenario_id,
      category: fee_item.category,
      code: fee_item.code,
      name: fee_item.name,
      low_amount: fee_item.low_amount,
      expected_amount: fee_item.expected_amount,
      high_amount: fee_item.high_amount,
      fixed_amount: fee_item.fixed_amount,
      percentage_of_loan_amount: fee_item.percentage_of_loan_amount,
      kind: fee_item.kind,
      paid_at_closing: fee_item.paid_at_closing,
      financed: fee_item.financed,
      is_true_cost: fee_item.is_true_cost,
      is_prepaid_or_escrow: fee_item.is_prepaid_or_escrow,
      required: fee_item.required,
      sort_order: fee_item.sort_order,
      notes: fee_item.notes,
      inserted_at: fee_item.inserted_at,
      updated_at: fee_item.updated_at
    }
  end

  defp serialize_analysis_result(%RefinanceAnalysisResult{} = result) do
    %{
      id: result.id,
      user_id: result.user_id,
      mortgage_id: result.mortgage_id,
      refinance_scenario_id: result.refinance_scenario_id,
      analysis_version: result.analysis_version,
      current_monthly_payment: result.current_monthly_payment,
      new_monthly_payment_low: result.new_monthly_payment_low,
      new_monthly_payment_expected: result.new_monthly_payment_expected,
      new_monthly_payment_high: result.new_monthly_payment_high,
      monthly_savings_low: result.monthly_savings_low,
      monthly_savings_expected: result.monthly_savings_expected,
      monthly_savings_high: result.monthly_savings_high,
      true_refinance_cost_low: result.true_refinance_cost_low,
      true_refinance_cost_expected: result.true_refinance_cost_expected,
      true_refinance_cost_high: result.true_refinance_cost_high,
      cash_to_close_low: result.cash_to_close_low,
      cash_to_close_expected: result.cash_to_close_expected,
      cash_to_close_high: result.cash_to_close_high,
      break_even_months_low: result.break_even_months_low,
      break_even_months_expected: result.break_even_months_expected,
      break_even_months_high: result.break_even_months_high,
      current_full_term_total_payment: result.current_full_term_total_payment,
      current_full_term_interest_cost: result.current_full_term_interest_cost,
      new_full_term_total_payment_expected: result.new_full_term_total_payment_expected,
      new_full_term_interest_cost_expected: result.new_full_term_interest_cost_expected,
      full_term_finance_cost_delta_expected: result.full_term_finance_cost_delta_expected,
      warnings: result.warnings,
      assumptions: result.assumptions,
      computed_at: result.computed_at,
      inserted_at: result.inserted_at,
      updated_at: result.updated_at
    }
  end

  defp serialize_loaded_many(%Ecto.Association.NotLoaded{}, _serializer), do: nil

  defp serialize_loaded_many(items, serializer) when is_list(items),
    do: Enum.map(items, serializer)

  defp serialize_loaded_many(_items, _serializer), do: nil

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "refinance scenario not found"})
  end

  defp loan_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "loan not found"})
  end

  defp validation_error(conn, %Changeset{} = changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: Changeset.traverse_errors(changeset, &translate_error/1)})
  end

  defp translate_error({msg, opts}) do
    Gettext.dgettext(MoneyTreeWeb.Gettext, "errors", msg, opts)
  end

  defp translate_error(msg) when is_binary(msg), do: msg
end
