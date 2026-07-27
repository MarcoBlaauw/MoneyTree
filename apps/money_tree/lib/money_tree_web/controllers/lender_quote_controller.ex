defmodule MoneyTreeWeb.LenderQuoteController do
  use MoneyTreeWeb, :controller

  alias Ecto.Changeset
  alias MoneyTree.Loans
  alias MoneyTree.Loans.LenderQuote
  alias MoneyTree.Loans.RefinanceFeeItem
  alias MoneyTree.Loans.RefinanceScenario

  def index(%{assigns: %{current_user: current_user}} = conn, %{"loan_id" => loan_id}) do
    quotes =
      current_user
      |> Loans.list_lender_quotes(loan_id)
      |> Enum.map(&serialize_quote/1)

    json(conn, %{data: quotes})
  end

  def show(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case Loans.fetch_lender_quote(current_user, id) do
      {:ok, quote} ->
        json(conn, %{data: serialize_quote(quote)})

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  def create(%{assigns: %{current_user: current_user}} = conn, %{"loan_id" => loan_id} = params) do
    attrs = Map.delete(params, "loan_id")

    case Loans.create_lender_quote(current_user, loan_id, attrs) do
      {:ok, quote} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_quote(quote)})

      {:error, :not_found} ->
        loan_not_found(conn)

      {:error, %Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  def update(%{assigns: %{current_user: current_user}} = conn, %{"id" => id} = params) do
    attrs = Map.delete(params, "id")

    case Loans.update_lender_quote(current_user, id, attrs) do
      {:ok, quote} ->
        json(conn, %{data: serialize_quote(quote)})

      {:error, :not_found} ->
        not_found(conn)

      {:error, %Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  def convert(%{assigns: %{current_user: current_user}} = conn, %{"id" => id} = params) do
    attrs = Map.delete(params, "id")

    case Loans.convert_lender_quote_to_refinance_scenario(current_user, id, attrs) do
      {:ok, scenario} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_scenario(scenario)})

      {:error, :not_found} ->
        not_found(conn)

      {:error, %Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  defp serialize_quote(%LenderQuote{} = quote) do
    %{
      id: quote.id,
      user_id: quote.user_id,
      mortgage_id: quote.mortgage_id,
      lender_name: quote.lender_name,
      quote_source: quote.quote_source,
      quote_reference: quote.quote_reference,
      loan_type: quote.loan_type,
      product_type: quote.product_type,
      term_months: quote.term_months,
      interest_rate: quote.interest_rate,
      apr: quote.apr,
      points: quote.points,
      lender_credit_amount: quote.lender_credit_amount,
      estimated_closing_costs_low: quote.estimated_closing_costs_low,
      estimated_closing_costs_expected: quote.estimated_closing_costs_expected,
      estimated_closing_costs_high: quote.estimated_closing_costs_high,
      estimated_cash_to_close_low: quote.estimated_cash_to_close_low,
      estimated_cash_to_close_expected: quote.estimated_cash_to_close_expected,
      estimated_cash_to_close_high: quote.estimated_cash_to_close_high,
      estimated_monthly_payment_low: quote.estimated_monthly_payment_low,
      estimated_monthly_payment_expected: quote.estimated_monthly_payment_expected,
      estimated_monthly_payment_high: quote.estimated_monthly_payment_high,
      lock_available: quote.lock_available,
      lock_expires_at: quote.lock_expires_at,
      quote_expires_at: quote.quote_expires_at,
      raw_payload: quote.raw_payload,
      status: quote.status,
      inserted_at: quote.inserted_at,
      updated_at: quote.updated_at
    }
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
      points: scenario.points,
      lender_credit_amount: scenario.lender_credit_amount,
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
      name: fee_item.name,
      low_amount: fee_item.low_amount,
      expected_amount: fee_item.expected_amount,
      high_amount: fee_item.high_amount,
      kind: fee_item.kind,
      is_true_cost: fee_item.is_true_cost,
      is_prepaid_or_escrow: fee_item.is_prepaid_or_escrow,
      sort_order: fee_item.sort_order,
      notes: fee_item.notes
    }
  end

  defp serialize_loaded_many(%Ecto.Association.NotLoaded{}, _serializer), do: nil

  defp serialize_loaded_many(items, serializer) when is_list(items),
    do: Enum.map(items, serializer)

  defp serialize_loaded_many(_items, _serializer), do: nil

  defp loan_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "loan not found"})
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "lender quote not found"})
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
