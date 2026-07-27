defmodule MoneyTreeWeb.LoanDocumentController do
  use MoneyTreeWeb, :controller

  alias Ecto.Changeset
  alias MoneyTree.Loans
  alias MoneyTree.Loans.LenderQuote
  alias MoneyTree.Loans.LoanDocument
  alias MoneyTree.Loans.LoanDocumentExtraction
  alias MoneyTree.Loans.RefinanceFeeItem
  alias MoneyTree.Loans.RefinanceScenario

  def index(%{assigns: %{current_user: current_user}} = conn, %{"loan_id" => loan_id}) do
    documents =
      current_user
      |> Loans.list_loan_documents(loan_id, preload: [:extractions])
      |> Enum.map(&serialize_document/1)

    json(conn, %{data: documents})
  end

  def show(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case Loans.fetch_loan_document(current_user, id, preload: [:extractions]) do
      {:ok, document} ->
        json(conn, %{data: serialize_document(document)})

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  def create(%{assigns: %{current_user: current_user}} = conn, %{"loan_id" => loan_id} = params) do
    attrs = Map.delete(params, "loan_id")

    case Loans.create_loan_document(current_user, loan_id, attrs, preload: [:extractions]) do
      {:ok, document} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_document(document)})

      {:error, :not_found} ->
        loan_not_found(conn)

      {:error, %Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  def extract(%{assigns: %{current_user: current_user}} = conn, %{"id" => id} = params) do
    attrs = Map.delete(params, "id")

    case create_extraction(current_user, id, attrs) do
      {:ok, extraction} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_extraction(extraction)})

      {:error, :not_found} ->
        not_found(conn)

      {:error, :disabled_for_user} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "local AI must be enabled before running Ollama extraction"})

      {:error, :empty_text} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "raw_text is required for Ollama extraction"})

      {:error, :no_extracted_fields} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Ollama did not return reviewable loan document fields"})

      {:error, %Changeset{} = changeset} ->
        validation_error(conn, changeset)

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Ollama extraction failed", reason: inspect(reason)})
    end
  end

  def confirm_extraction(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case Loans.confirm_loan_document_extraction(current_user, id) do
      {:ok, extraction} ->
        json(conn, %{data: serialize_extraction(extraction)})

      {:error, :not_found} ->
        extraction_not_found(conn)

      {:error, %Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  def reject_extraction(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case Loans.reject_loan_document_extraction(current_user, id) do
      {:ok, extraction} ->
        json(conn, %{data: serialize_extraction(extraction)})

      {:error, :not_found} ->
        extraction_not_found(conn)

      {:error, %Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  def apply_extraction(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case Loans.apply_loan_document_extraction_to_mortgage(current_user, id) do
      {:ok, mortgage} ->
        json(conn, %{data: serialize_mortgage_apply_result(mortgage)})

      {:error, :not_found} ->
        extraction_not_found(conn)

      {:error, :not_confirmed} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "extraction must be confirmed before applying"})

      {:error, :no_applicable_fields} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "extraction has no applicable mortgage fields"})

      {:error, %Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  def create_lender_quote(%{assigns: %{current_user: current_user}} = conn, %{"id" => id}) do
    case Loans.create_lender_quote_from_document_extraction(current_user, id) do
      {:ok, quote} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_quote(quote)})

      {:error, :not_found} ->
        extraction_not_found(conn)

      {:error, :not_confirmed} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "extraction must be confirmed before creating a lender quote"})

      {:error, :no_applicable_quote_fields} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "extraction has no applicable lender quote fields"})

      {:error, %Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  def create_scenario(%{assigns: %{current_user: current_user}} = conn, %{"id" => id} = params) do
    attrs = Map.delete(params, "id")

    case Loans.create_refinance_scenario_from_document_extraction(current_user, id, attrs) do
      {:ok, scenario} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_scenario(scenario)})

      {:error, :not_found} ->
        extraction_not_found(conn)

      {:error, :not_confirmed} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "extraction must be confirmed before creating a scenario"})

      {:error, :no_applicable_scenario_fields} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "extraction has no applicable refinance scenario fields"})

      {:error, %Changeset{} = changeset} ->
        validation_error(conn, changeset)
    end
  end

  defp serialize_document(%LoanDocument{} = document) do
    %{
      id: document.id,
      user_id: document.user_id,
      mortgage_id: document.mortgage_id,
      document_type: document.document_type,
      original_filename: document.original_filename,
      content_type: document.content_type,
      byte_size: document.byte_size,
      storage_key: document.storage_key,
      checksum_sha256: document.checksum_sha256,
      status: document.status,
      uploaded_at: document.uploaded_at,
      extractions: serialize_loaded_many(document.extractions, &serialize_extraction/1),
      inserted_at: document.inserted_at,
      updated_at: document.updated_at
    }
  end

  defp serialize_extraction(%LoanDocumentExtraction{} = extraction) do
    %{
      id: extraction.id,
      user_id: extraction.user_id,
      mortgage_id: extraction.mortgage_id,
      loan_document_id: extraction.loan_document_id,
      extraction_method: extraction.extraction_method,
      model_name: extraction.model_name,
      status: extraction.status,
      ocr_text_storage_key: extraction.ocr_text_storage_key,
      raw_text_excerpt: extraction.raw_text_excerpt,
      extracted_payload: extraction.extracted_payload,
      field_confidence: extraction.field_confidence,
      source_citations: extraction.source_citations,
      reviewed_at: extraction.reviewed_at,
      confirmed_at: extraction.confirmed_at,
      rejected_at: extraction.rejected_at,
      inserted_at: extraction.inserted_at,
      updated_at: extraction.updated_at
    }
  end

  defp serialize_mortgage_apply_result(mortgage) do
    %{
      id: mortgage.id,
      mortgage_id: mortgage.id,
      source: mortgage.source,
      last_reviewed_at: mortgage.last_reviewed_at,
      current_balance: mortgage.current_balance,
      current_interest_rate: mortgage.current_interest_rate,
      remaining_term_months: mortgage.remaining_term_months,
      monthly_payment_total: mortgage.monthly_payment_total
    }
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

  defp create_extraction(current_user, document_id, attrs) do
    raw_text = attrs |> Map.get("raw_text", Map.get(attrs, :raw_text)) |> blank_to_nil()

    if raw_text do
      Loans.create_ollama_loan_document_extraction(current_user, document_id, raw_text)
    else
      Loans.create_loan_document_extraction(current_user, document_id, attrs)
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp blank_to_nil(_value), do: nil

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
    |> json(%{error: "loan document not found"})
  end

  defp extraction_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "loan document extraction not found"})
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
