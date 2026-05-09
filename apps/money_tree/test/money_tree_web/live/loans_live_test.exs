defmodule MoneyTreeWeb.LoansLiveTest do
  use MoneyTreeWeb.ConnCase, async: true

  import MoneyTree.MortgagesFixtures
  import Phoenix.LiveViewTest

  alias MoneyTree.Loans

  test "renders mortgage-first overview and current mortgage records", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    mortgage_fixture(user, %{
      property_name: "Maple Residence",
      loan_type: "conventional",
      current_balance: "350000.00",
      monthly_payment_total: "2400.22",
      remaining_term_months: 300
    })

    {:ok, _view, html} = live(authed_conn, ~p"/app/loans")

    assert html =~ "Loan Center"
    assert html =~ "Mortgage loans are supported first"
    assert html =~ "Maple Residence"
    assert html =~ "$350000.00"
    assert html =~ "Payment $2400.22"
    assert html =~ "Open workspace"
    assert html =~ "Lender quotes"
    refute html =~ "Refinance analysis"
    refute html =~ "Add fee item"
  end

  test "creates a mortgage baseline from the Loan Center empty state", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    {:ok, view, html} = live(authed_conn, ~p"/app/loans")

    assert html =~ "No mortgage records yet"
    assert html =~ "Add mortgage baseline"

    view
    |> element("button", "Add mortgage baseline")
    |> render_click()

    html =
      view
      |> form("#mortgage-form",
        mortgage: %{
          "property_name" => "Primary home",
          "loan_type" => "conventional",
          "current_balance" => "315000.00",
          "current_interest_rate_percent" => "6.15",
          "remaining_term_months" => "324",
          "monthly_payment_total" => "2260.00",
          "has_escrow" => "true",
          "escrow_included_in_payment" => "true"
        }
      )
      |> render_submit()

    assert html =~ "Mortgage added to Loan Center."
    assert html =~ "Primary home"
    assert html =~ "$315000.00"

    assert [mortgage] = MoneyTree.Mortgages.list_mortgages(user)
    assert Decimal.equal?(mortgage.current_interest_rate, Decimal.new("0.0615"))
  end

  test "creates a non-mortgage auto loan baseline from Loan Center", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    {:ok, view, html} = live(authed_conn, ~p"/app/loans")

    assert html =~ "Other loans"
    assert html =~ "Add non-mortgage loan"

    view
    |> element("button", "Add non-mortgage loan")
    |> render_click()

    html =
      view
      |> form("#generic-loan-form",
        loan: %{
          "loan_type" => "auto",
          "name" => "Car loan",
          "lender_name" => "Example Credit Union",
          "current_balance" => "18500.00",
          "current_interest_rate_percent" => "7.99",
          "remaining_term_months" => "48",
          "monthly_payment_total" => "452.13",
          "collateral_description" => "2023 hatchback"
        }
      )
      |> render_submit()

    assert html =~ "Loan added to Loan Center."
    assert html =~ "Car loan"
    assert html =~ "Auto"
    assert html =~ "$18500.00"
    assert html =~ "Refinance preview"
    assert html =~ "Expected payment"
    assert html =~ "Full-term delta"
    refute html =~ "Escrow"
    refute html =~ "Property name"

    assert [loan] = Loans.list_loans(user)
    assert loan.loan_type == "auto"
    assert Decimal.equal?(loan.current_interest_rate, Decimal.new("0.0799"))
  end

  test "edits an existing loan baseline from Loan Center", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    mortgage =
      mortgage_fixture(user, %{
        property_name: "CCB809",
        loan_type: "conventional",
        current_balance: "375677.51",
        current_interest_rate: "7.125",
        monthly_payment_total: "3233.65",
        remaining_term_months: 339
      })

    {:ok, view, html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}")

    assert html =~ "712.50%"

    view
    |> element(".btn[phx-click='edit-mortgage'][phx-value-id='#{mortgage.id}']", "Edit loan")
    |> render_click()

    assert render(view) =~ ~s(value="712.5")

    html =
      view
      |> form("#mortgage-form",
        mortgage: %{
          "property_name" => "CCB809",
          "loan_type" => "conventional",
          "current_balance" => "375677.51",
          "current_interest_rate_percent" => "7.125",
          "remaining_term_months" => "339",
          "monthly_payment_total" => "3233.65",
          "has_escrow" => "false",
          "escrow_included_in_payment" => "false"
        }
      )
      |> render_submit()

    assert html =~ "Loan updated."
    assert html =~ "7.13%"
    refute html =~ "712.50%"

    assert {:ok, updated} = MoneyTree.Mortgages.fetch_mortgage(user, mortgage.id)
    assert Decimal.equal?(updated.current_interest_rate, Decimal.new("0.07125"))
  end

  test "supports mortgage compatibility route", %{conn: conn} do
    {:ok, %{conn: authed_conn}} = register_and_log_in_user(%{conn: conn})

    {:ok, _view, html} = live(authed_conn, ~p"/app/mortgages")

    assert html =~ "Loan Center"
    assert html =~ "Mortgage loans are supported first"
  end

  test "supports canonical loan detail and refinance workspace routes", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    selected_mortgage =
      mortgage_fixture(user, %{
        property_name: "Maple Residence",
        current_balance: "400000.00",
        current_interest_rate: "0.0625",
        monthly_payment_total: "2462.87",
        remaining_term_months: 360
      })

    other_mortgage =
      mortgage_fixture(user, %{
        property_name: "Pine Rental",
        current_balance: "220000.00",
        current_interest_rate: "0.0525",
        monthly_payment_total: "1410.00",
        remaining_term_months: 300
      })

    {:ok, _scenario} =
      Loans.create_refinance_scenario(user, selected_mortgage, %{
        name: "Selected refinance",
        new_term_months: 360,
        new_interest_rate: "0.0550",
        new_principal_amount: "406000.00"
      })

    {:ok, _view, detail_html} = live(authed_conn, ~p"/app/loans/#{selected_mortgage.id}")

    assert detail_html =~ "Loan Center"
    assert detail_html =~ "Browse loans"
    assert detail_html =~ "Maple Residence"
    assert detail_html =~ "Pine Rental"
    assert detail_html =~ "Mortgage details"
    refute detail_html =~ "Refinance analysis"

    {:ok, _view, refinance_html} =
      live(authed_conn, ~p"/app/loans/#{selected_mortgage.id}/refinance")

    assert refinance_html =~ "Refinance analysis"
    assert refinance_html =~ "Selected refinance"
    assert refinance_html =~ other_mortgage.property_name
    refute refinance_html =~ "Document review queue"

    {:ok, _view, mortgage_html} = live(authed_conn, ~p"/app/mortgages/#{selected_mortgage.id}")

    assert mortgage_html =~ "Maple Residence"
    assert mortgage_html =~ "Pine Rental"
  end

  test "supports document quote and alert workspace routes", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    mortgage =
      mortgage_fixture(user, %{
        property_name: "Maple Residence",
        current_balance: "400000.00",
        current_interest_rate: "0.0625",
        monthly_payment_total: "2462.87",
        remaining_term_months: 360
      })

    {:ok, _view, documents_html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/documents")

    assert documents_html =~ "Loan workspace"
    assert documents_html =~ "Documents"
    assert documents_html =~ "Document review queue"
    assert documents_html =~ "Document metadata will appear here"
    assert documents_html =~ "Maple Residence"

    {:ok, _view, quotes_html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/quotes")

    assert quotes_html =~ "Lender quotes"
    assert quotes_html =~ "Lender quote tracker"
    assert quotes_html =~ "Refinance lender quote"
    assert quotes_html =~ "Maple Residence"
    refute quotes_html =~ "Refinance analysis"

    {:ok, _view, alerts_html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/alerts")

    assert alerts_html =~ "Alerts"
    assert alerts_html =~ "Alert rules"
    assert alerts_html =~ "durable MoneyTree notifications"
    assert alerts_html =~ "Maple Residence"
  end

  test "creates and lists manual lender quotes in the quotes workspace", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    mortgage =
      mortgage_fixture(user, %{
        property_name: "Maple Residence",
        current_balance: "400000.00",
        current_interest_rate: "0.0625",
        monthly_payment_total: "2462.87",
        remaining_term_months: 360
      })

    {:ok, view, html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/quotes")

    assert html =~ "Refinance lender quotes will appear here"
    assert html =~ "Add lender quote"

    view
    |> element("button", "Add lender quote")
    |> render_click()

    html =
      view
      |> form("#lender-quote-form",
        lender_quote: %{
          "mortgage_id" => mortgage.id,
          "lender_name" => "Example Lender",
          "quote_source" => "manual",
          "quote_reference" => "quote-123",
          "product_type" => "fixed",
          "term_months" => "360",
          "interest_rate" => "0.0550",
          "apr" => "0.0560",
          "points" => "0.2500",
          "lender_credit_amount" => "1200.00",
          "estimated_monthly_payment_expected" => "2305.22",
          "estimated_closing_costs_expected" => "6500.00",
          "estimated_cash_to_close_expected" => "9000.00",
          "lock_available" => "true",
          "quote_expires_at" => "2026-06-01T00:00:00Z",
          "status" => "active",
          "source_note" => "manual quote"
        }
      )
      |> render_submit()

    assert html =~ "Lender quote saved."
    assert html =~ "Example Lender"
    assert html =~ "5.50%"
    assert html =~ "APR 5.60%"
    assert html =~ "$2305.22"
    assert html =~ "$6500.00"
    assert html =~ "Cash $9000.00"
    assert html =~ "Available"
    assert html =~ "Jun 1, 2026"
    assert html =~ "Convert to scenario"

    assert [
             %{
               id: quote_id,
               lender_name: "Example Lender",
               raw_payload: %{"source_note" => "manual quote"}
             }
           ] =
             Loans.list_lender_quotes(user, mortgage)

    html =
      view
      |> element("button[phx-click='convert-quote'][phx-value-id='#{quote_id}']")
      |> render_click()

    assert html =~ "Lender quote converted to a refinance scenario."
    assert html =~ "Converted"

    assert [%{scenario_type: "lender_quote", lender_quote_id: ^quote_id, fee_items: fee_items}] =
             Loans.list_refinance_scenarios(user, mortgage)

    assert Enum.any?(fee_items, &(&1.name == "Estimated lender quote costs"))
  end

  test "shows expired lender quote freshness in the quotes workspace", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    mortgage =
      mortgage_fixture(user, %{
        property_name: "Maple Residence",
        current_balance: "400000.00",
        current_interest_rate: "0.0625",
        monthly_payment_total: "2462.87",
        remaining_term_months: 360
      })

    {:ok, quote} =
      Loans.create_lender_quote(user, mortgage, %{
        lender_name: "Expired Lender",
        quote_source: "manual",
        loan_type: "mortgage",
        product_type: "fixed",
        term_months: 360,
        interest_rate: "0.0550",
        lock_available: false,
        quote_expires_at: ~U[2026-05-01 12:00:00Z],
        raw_payload: %{},
        status: "active"
      })

    {:ok, _view, html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/quotes")

    assert html =~ "Expired Lender"
    assert html =~ "Expired"

    assert {:ok, expired_quote} = Loans.fetch_lender_quote(user, quote.id)
    assert expired_quote.status == "expired"
  end

  test "refreshes lender quote expiration status in the quotes workspace", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    mortgage =
      mortgage_fixture(user, %{
        property_name: "Maple Residence",
        current_balance: "400000.00",
        current_interest_rate: "0.0625",
        monthly_payment_total: "2462.87",
        remaining_term_months: 360
      })

    {:ok, quote} =
      Loans.create_lender_quote(user, mortgage, %{
        lender_name: "Refresh Lender",
        quote_source: "manual",
        loan_type: "mortgage",
        product_type: "fixed",
        term_months: 360,
        interest_rate: "0.0550",
        lock_available: false,
        quote_expires_at: ~U[2026-05-01 12:00:00Z],
        raw_payload: %{},
        status: "active"
      })

    {:ok, view, html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/quotes")

    assert html =~ "Refresh expirations"
    assert html =~ "Freshness"
    assert html =~ "Expired"

    html =
      view
      |> element("button", "Refresh expirations")
      |> render_click()

    assert html =~ "Quote freshness refreshed; 0 quotes expired."

    assert {:ok, expired_quote} = Loans.fetch_lender_quote(user, quote.id)
    assert expired_quote.status == "expired"
  end

  test "creates and lists document metadata in the documents workspace", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    mortgage =
      mortgage_fixture(user, %{
        property_name: "Maple Residence",
        current_balance: "400000.00",
        current_interest_rate: "0.0625",
        monthly_payment_total: "2462.87",
        remaining_term_months: 360
      })

    {:ok, view, html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/documents")

    assert html =~ "Document review queue"
    assert html =~ "Add document"

    view
    |> element("button", "Add document")
    |> render_click()

    html =
      view
      |> form("#loan-document-form",
        loan_document: %{
          "mortgage_id" => mortgage.id,
          "document_type" => "loan_estimate",
          "original_filename" => "loan-estimate.pdf",
          "content_type" => "application/pdf",
          "byte_size" => "123456",
          "storage_key" => "loan-documents/#{Ecto.UUID.generate()}/loan-estimate.pdf",
          "checksum_sha256" => String.duplicate("a", 64)
        }
      )
      |> render_submit()

    assert html =~ "Loan document metadata saved for review."
    assert html =~ "loan-estimate.pdf"
    assert html =~ "Loan Estimate"
    assert html =~ "No extraction candidates"

    assert [%{original_filename: "loan-estimate.pdf"}] = Loans.list_loan_documents(user, mortgage)
  end

  test "uploads a document file in the documents workspace", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    mortgage =
      mortgage_fixture(user, %{
        property_name: "Maple Residence",
        current_balance: "400000.00",
        current_interest_rate: "0.0625",
        monthly_payment_total: "2462.87",
        remaining_term_months: 360
      })

    {:ok, view, _html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/documents")

    view
    |> element("button", "Add document")
    |> render_click()
    |> then(fn html ->
      assert html =~ ".csv"
      assert html =~ ".md"
    end)

    upload =
      file_input(view, "#loan-document-form", :loan_document_file, [
        %{
          name: "statement.pdf",
          content: "%PDF-1.4 sample mortgage statement",
          type: "application/pdf"
        }
      ])

    render_upload(upload, "statement.pdf")

    html =
      view
      |> form("#loan-document-form",
        loan_document: %{
          "mortgage_id" => mortgage.id,
          "document_type" => "mortgage_statement"
        }
      )
      |> render_submit()

    assert html =~ "Loan document metadata saved for review."
    assert html =~ "statement.pdf"
    assert html =~ "Mortgage Statement"

    assert [
             %{
               original_filename: "statement.pdf",
               content_type: "application/pdf",
               byte_size: 34,
               checksum_sha256: checksum,
               storage_key: storage_key
             }
           ] = Loans.list_loan_documents(user, mortgage)

    assert String.length(checksum) == 64
    assert String.contains?(storage_key, "statement.pdf")
  end

  test "runs stored document extraction from the documents workspace", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    {:ok, _preference} =
      MoneyTree.AI.update_settings(user, %{
        local_ai_enabled: true,
        default_model: "test-model:latest"
      })

    mortgage =
      mortgage_fixture(user, %{
        property_name: "Maple Residence",
        current_balance: "400000.00",
        current_interest_rate: "0.0625",
        monthly_payment_total: "2462.87",
        remaining_term_months: 360
      })

    storage_key = "loan-documents/#{Ecto.UUID.generate()}/statement.txt"
    stored_path = Path.join([System.tmp_dir!(), "money_tree", "uploads", storage_key])

    File.mkdir_p!(Path.dirname(stored_path))

    File.write!(stored_path, """
    Mortgage statement
    Unpaid principal balance $390,000.00
    Interest rate 5.75%
    Remaining term 348 months
    Monthly payment $2,275.41
    """)

    {:ok, document} =
      Loans.create_loan_document(user, mortgage, %{
        document_type: "mortgage_statement",
        original_filename: "statement.txt",
        content_type: "text/plain",
        byte_size: File.stat!(stored_path).size,
        storage_key: storage_key,
        checksum_sha256: String.duplicate("a", 64)
      })

    {:ok, view, html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/documents")

    assert html =~ "Run extraction"

    html =
      view
      |> element("button[phx-click='extract-document'][phx-value-id='#{document.id}']")
      |> render_click()

    assert html =~ "Document extraction queued for review."
    assert html =~ "Current Balance"
    assert html =~ "390000.00"
    assert html =~ "Stored text artifact"
    assert html =~ "Stored extracted text"
    assert html =~ "Extracted text excerpt"
    assert html =~ "Mortgage statement"

    assert [
             %{
               extraction_method: "ollama",
               ocr_text_storage_key: text_storage_key,
               extracted_payload: %{"current_balance" => "390000.00"}
             }
           ] = Loans.list_loan_document_extractions(user, document)

    assert text_storage_key == "loan-documents/#{document.id}/extracted-text.txt"
  end

  test "reviews extraction candidates in the documents workspace", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    mortgage =
      mortgage_fixture(user, %{
        property_name: "Maple Residence",
        current_balance: "400000.00",
        current_interest_rate: "0.0625",
        monthly_payment_total: "2462.87",
        remaining_term_months: 360
      })

    {:ok, document} =
      Loans.create_loan_document(user, mortgage, %{
        document_type: "loan_estimate",
        original_filename: "loan-estimate.pdf",
        content_type: "application/pdf",
        byte_size: 123_456,
        storage_key: "loan-documents/#{Ecto.UUID.generate()}/loan-estimate.pdf",
        checksum_sha256: String.duplicate("a", 64)
      })

    {:ok, extraction} =
      Loans.create_loan_document_extraction(user, document, %{
        extraction_method: "ollama",
        model_name: "llama3.2",
        extracted_payload: %{
          "current_balance" => "390000.00",
          "interest_rate" => "0.0575",
          "lender_name" => "Example Lender",
          "term_months" => 360,
          "monthly_payment" => "2305.22",
          "closing_costs" => "6500.00"
        },
        field_confidence: %{
          "current_balance" => 0.91
        },
        source_citations: %{
          "current_balance" => [%{"page" => 1, "text" => "Unpaid principal balance"}]
        }
      })

    {:ok, view, html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/documents")

    assert html =~ "Extraction candidates"
    assert html =~ "Pending Review"
    assert html =~ "Current Balance"
    assert html =~ "390000.00"
    assert html =~ "Interest Rate"
    assert html =~ "0.0575"
    assert html =~ "Confidence 0.91"
    assert html =~ "Source p. 1: Unpaid principal balance"
    assert html =~ ~s(phx-click="apply-extraction" phx-value-id="#{extraction.id}" disabled)

    assert html =~
             ~s(phx-click="create-quote-from-extraction" phx-value-id="#{extraction.id}" disabled)

    assert html =~
             ~s(phx-click="create-scenario-from-extraction" phx-value-id="#{extraction.id}" disabled)

    html =
      view
      |> element("button[phx-click='confirm-extraction'][phx-value-id='#{extraction.id}']")
      |> render_click()

    assert html =~ "Extraction candidate confirmed for review."
    assert html =~ "Confirmed"

    html =
      view
      |> element("button[phx-click='apply-extraction'][phx-value-id='#{extraction.id}']")
      |> render_click()

    assert html =~ "Confirmed extraction applied to mortgage baseline."
    assert html =~ "$390000.00"

    html =
      view
      |> element(
        "button[phx-click='create-quote-from-extraction'][phx-value-id='#{extraction.id}']"
      )
      |> render_click()

    assert html =~ "Confirmed extraction created a lender quote."
    assert [%{lender_name: "Example Lender"}] = Loans.list_lender_quotes(user, mortgage)

    html =
      view
      |> element(
        "button[phx-click='create-scenario-from-extraction'][phx-value-id='#{extraction.id}']"
      )
      |> render_click()

    assert html =~ "Confirmed extraction created a refinance scenario."

    assert [%{scenario_type: "document_extraction", name: "Example Lender document scenario"}] =
             Loans.list_refinance_scenarios(user, mortgage)

    html =
      view
      |> element("button[phx-click='reject-extraction'][phx-value-id='#{extraction.id}']")
      |> render_click()

    assert html =~ "Extraction candidate rejected."
    assert html =~ "Rejected"
  end

  test "generates Ollama extraction candidates in the documents workspace", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    {:ok, _preference} =
      MoneyTree.AI.update_settings(user, %{
        local_ai_enabled: true,
        default_model: "test-model:latest"
      })

    mortgage =
      mortgage_fixture(user, %{
        property_name: "Maple Residence",
        current_balance: "400000.00",
        current_interest_rate: "0.0625",
        monthly_payment_total: "2462.87",
        remaining_term_months: 360
      })

    {:ok, document} =
      Loans.create_loan_document(user, mortgage, %{
        document_type: "mortgage_statement",
        original_filename: "statement.pdf",
        content_type: "application/pdf",
        byte_size: 123_456,
        storage_key: "loan-documents/#{Ecto.UUID.generate()}/statement.pdf",
        checksum_sha256: String.duplicate("a", 64)
      })

    {:ok, view, html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/documents")

    assert html =~ "Generate with Ollama"

    view
    |> element("button", "Generate with Ollama")
    |> render_click()

    html =
      view
      |> form("#loan-document-ollama-extraction-form",
        ollama_extraction: %{
          "loan_document_id" => document.id,
          "raw_text" => """
          Mortgage statement
          Unpaid principal balance $390,000.00
          Interest rate 5.75%
          Remaining term 348 months
          Monthly payment $2,275.41
          """
        }
      )
      |> render_submit()

    assert html =~ "Ollama extraction candidate added for review."
    assert html =~ "Ollama"
    assert html =~ "Current Balance"
    assert html =~ "390000.00"
    assert html =~ "Current Interest Rate"
    assert html =~ "0.0575"
    assert html =~ "Confidence 0.91"
    assert html =~ "Source p. 1: Unpaid principal balance $390,000.00"
    assert html =~ "Extracted text excerpt"
    assert html =~ "Mortgage statement"

    assert [
             %{
               extraction_method: "ollama",
               model_name: "test-model:latest",
               extracted_payload: %{"current_balance" => "390000.00"}
             }
           ] = Loans.list_loan_document_extractions(user, document)
  end

  test "requires local AI before generating Ollama extraction candidates", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    mortgage = mortgage_fixture(user)

    {:ok, document} =
      Loans.create_loan_document(user, mortgage, %{
        document_type: "mortgage_statement",
        original_filename: "statement.pdf",
        content_type: "application/pdf",
        byte_size: 123_456,
        storage_key: "loan-documents/#{Ecto.UUID.generate()}/statement.pdf",
        checksum_sha256: String.duplicate("a", 64)
      })

    {:ok, view, _html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/documents")

    view
    |> element("button", "Generate with Ollama")
    |> render_click()

    html =
      view
      |> form("#loan-document-ollama-extraction-form",
        ollama_extraction: %{
          "loan_document_id" => document.id,
          "raw_text" => "Unpaid principal balance $390,000.00"
        }
      )
      |> render_submit()

    assert html =~ "Enable local AI in settings before running Ollama extraction."
  end

  test "creates manual extraction candidates in the documents workspace", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    mortgage =
      mortgage_fixture(user, %{
        property_name: "Maple Residence",
        current_balance: "400000.00",
        current_interest_rate: "0.0625",
        monthly_payment_total: "2462.87",
        remaining_term_months: 360
      })

    {:ok, document} =
      Loans.create_loan_document(user, mortgage, %{
        document_type: "loan_estimate",
        original_filename: "loan-estimate.pdf",
        content_type: "application/pdf",
        byte_size: 123_456,
        storage_key: "loan-documents/#{Ecto.UUID.generate()}/loan-estimate.pdf",
        checksum_sha256: String.duplicate("a", 64)
      })

    {:ok, view, html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/documents")

    assert html =~ "Add extraction candidate"

    view
    |> element("button", "Add extraction candidate")
    |> render_click()

    html =
      view
      |> form("#loan-document-extraction-form",
        extraction: %{
          "loan_document_id" => document.id,
          "field_name" => "current_balance",
          "field_value" => "390000.00",
          "confidence" => "0.91",
          "model_name" => "manual review",
          "source_note" => "Balance shown on page 1"
        }
      )
      |> render_submit()

    assert html =~ "Extraction candidate added for review."
    assert html =~ "Current Balance"
    assert html =~ "390000.00"
    assert html =~ "Pending Review"

    assert [%{extracted_payload: %{"current_balance" => "390000.00"}}] =
             Loans.list_loan_document_extractions(user, document)
  end

  test "creates and lists refinance scenarios for mortgage records", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    mortgage =
      mortgage_fixture(user, %{
        property_name: "Maple Residence",
        current_balance: "400000.00",
        current_interest_rate: "0.0625",
        monthly_payment_total: "2462.87",
        remaining_term_months: 360
      })

    {:ok, view, html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/refinance")

    assert html =~ "Refinance analysis"
    assert html =~ "Save a refinance scenario"
    refute html =~ ~s(id="refinance-scenario-form")

    html =
      view
      |> element("button", "Add scenario")
      |> render_click()

    assert html =~ ~s(id="refinance-scenario-form")
    assert html =~ "New interest rate (%)"
    assert html =~ "Example: enter 5.5 for 5.5%."
    assert html =~ ~s(value="6.25")
    assert html =~ ~s(value="400000.00")
    assert html =~ ~s(value="360")

    html =
      view
      |> form("#refinance-scenario-form",
        refinance_scenario: %{
          "mortgage_id" => mortgage.id,
          "name" => "Expected refinance",
          "product_type" => "fixed",
          "new_term_months" => "360",
          "new_interest_rate_percent" => "5.5",
          "new_apr_percent" => "5.75",
          "new_principal_amount" => "406000.00"
        }
      )
      |> render_submit()

    assert html =~ "Refinance scenario saved."
    assert html =~ "Expected refinance"
    assert html =~ "Maple Residence"
    assert html =~ "$2305.22"
    assert html =~ "Lowest expected payment"
    assert html =~ "Fastest break-even"
    assert html =~ "Lowest full-term delta"
    assert html =~ "Analysis details"
    assert html =~ "Current full-term total"

    assert [%{name: "Expected refinance"} = scenario] =
             Loans.list_refinance_scenarios(user, mortgage)

    assert Decimal.equal?(scenario.new_interest_rate, Decimal.new("0.055"))
    assert Decimal.equal?(scenario.new_apr, Decimal.new("0.0575"))
  end

  test "updates refinance what-if sandbox without saving a scenario", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    mortgage =
      mortgage_fixture(user, %{
        property_name: "Maple Residence",
        current_balance: "400000.00",
        current_interest_rate: "0.0625",
        monthly_payment_total: "2462.87",
        remaining_term_months: 360
      })

    {:ok, view, html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/refinance")

    assert html =~ "What-if sandbox"
    assert html =~ "Estimate-only sliders"
    assert html =~ ~s(name="what_if[rate_percent]")
    assert html =~ "$2462.87"

    html =
      view
      |> form("#mortgage-what-if-form",
        what_if: %{
          "rate_percent" => "5.5",
          "term_months" => "360",
          "extra_monthly_principal" => "500"
        }
      )
      |> render_change()

    assert html =~ "$2271.16"
    assert html =~ "237 months"
    assert html =~ "$656576.13"
    assert html =~ "$256576.13"
    assert html =~ "Interest saved"
    assert [] = Loans.list_refinance_scenarios(user, mortgage)

    assert {:ok, unchanged} = MoneyTree.Mortgages.fetch_mortgage(user, mortgage.id)
    assert Decimal.equal?(unchanged.current_balance, Decimal.new("400000.00"))
    assert Decimal.equal?(unchanged.current_interest_rate, Decimal.new("0.0625"))
    assert unchanged.remaining_term_months == 360
  end

  test "records benchmark rates and creates estimated scenarios in refinance workspace", %{
    conn: conn
  } do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    mortgage =
      mortgage_fixture(user, %{
        property_name: "Maple Residence",
        current_balance: "400000.00",
        current_interest_rate: "0.0625",
        monthly_payment_total: "2462.87",
        remaining_term_months: 360
      })

    {:ok, view, html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/refinance")

    assert html =~ "Market rate snapshot"
    assert html =~ "National benchmarks provide context"
    assert html =~ "No imported market benchmark rates are available."
    assert html =~ "This product uses the FRED® API"
    assert html =~ "Benchmark"
    assert html =~ "YoY"
    assert html =~ "Benchmark rates"
    assert html =~ "Rate observations are estimates"
    refute html =~ ~s(id="rate-observation-form")

    html =
      view
      |> element("button", "Add benchmark rate")
      |> render_click()

    assert html =~ ~s(id="rate-observation-form")

    html =
      view
      |> form("#rate-observation-form",
        rate_observation: %{
          "loan_type" => "mortgage",
          "product_type" => "fixed",
          "term_months" => "360",
          "rate_percent" => "6.125",
          "apr_percent" => "6.2",
          "points" => "0.25"
        }
      )
      |> render_submit()

    assert html =~ "Benchmark rate saved."
    assert html =~ "6.13%"
    assert html =~ "APR 6.20%"
    assert html =~ "Manual rate entry"

    assert [observation] =
             Loans.list_rate_observations(
               loan_type: "mortgage",
               product_type: "fixed",
               term_months: 360
             )

    assert Decimal.equal?(observation.rate, Decimal.new("0.06125"))

    html =
      view
      |> element(
        "button[phx-click='create-scenario-from-rate-observation'][phx-value-id='#{observation.id}']",
        "Create scenario"
      )
      |> render_click()

    assert html =~ "Benchmark rate scenario created."
    assert html =~ "30-year benchmark at 6.13%"

    assert [%{scenario_type: "rate_observation", rate_source_type: "manual"}] =
             Loans.list_refinance_scenarios(user, mortgage)
  end

  test "imports configured public benchmark rates in refinance workspace", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    mortgage =
      mortgage_fixture(user, %{
        property_name: "Maple Residence",
        current_balance: "400000.00",
        current_interest_rate: "0.0625",
        monthly_payment_total: "2462.87",
        remaining_term_months: 360
      })

    {:ok, source} =
      Loans.get_or_create_public_benchmark_rate_source(%{
        provider_key: "workspace-public-benchmark",
        name: "Workspace Public Benchmark",
        config: %{
          "observations" => [
            %{
              "loan_type" => "mortgage",
              "product_type" => "fixed",
              "term_months" => 360,
              "rate" => "0.0600",
              "apr" => "0.0610",
              "points" => "0.1250",
              "series_key" => "30-year-fixed"
            }
          ]
        }
      })

    {:ok, view, html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/refinance")

    assert html =~ "Benchmark sources"
    assert html =~ "Workspace Public Benchmark"
    assert html =~ "Not imported"

    html =
      view
      |> element("button[phx-click='import-rate-source'][phx-value-id='#{source.id}']")
      |> render_click()

    assert html =~ "Benchmark source imported 1 observations."
    assert html =~ "6.00%"
    assert html =~ "APR 6.10%"
    assert html =~ "Workspace Public Benchmark"

    assert [%{rate_source_type: "public_benchmark"}] =
             Loans.list_rate_observations(rate_source_id: source.id)
             |> Enum.map(fn observation ->
               {:ok, scenario} =
                 Loans.create_refinance_scenario_from_rate_observation(
                   user,
                   mortgage,
                   observation
                 )

               scenario
             end)
  end

  test "shows imported market snapshot context in refinance workspace", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    mortgage =
      mortgage_fixture(user, %{
        current_balance: "400000.00",
        current_interest_rate: "0.07125",
        monthly_payment_total: "3233.65",
        remaining_term_months: 339
      })

    {:ok, source} =
      Loans.create_rate_source(%{
        provider_key: "fred-test-live",
        name: "FRED Test Live",
        source_type: "public_benchmark",
        attribution_label: "Federal Reserve Economic Data (FRED)",
        attribution_url: "https://fred.stlouisfed.org/",
        config: %{
          "observations" => [
            %{
              "loan_type" => "mortgage",
              "product_type" => "fixed",
              "term_months" => 360,
              "rate" => "0.0600",
              "series_key" => "MORTGAGE30US",
              "effective_date" => "#{Date.utc_today()}",
              "source_url" => "https://fred.stlouisfed.org/series/MORTGAGE30US"
            },
            %{
              "loan_type" => "treasury",
              "product_type" => "10_year_treasury",
              "term_months" => 120,
              "rate" => "0.0410",
              "series_key" => "GS10",
              "effective_date" => "#{Date.utc_today()}"
            }
          ]
        }
      })

    assert {:ok, %{imported: [_mortgage, _treasury]}} = Loans.process_rate_import_job(source.id)

    {:ok, _view, html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/refinance")

    assert html =~ "Market rate snapshot"
    assert html =~ "6.00%"
    assert html =~ "4.10%"
    assert html =~ "30-year mortgage"
    assert html =~ "10-year Treasury"
    assert html =~ "Federal Reserve Economic Data"
    assert html =~ "https://fred.stlouisfed.org/series/MORTGAGE30US"
    assert html =~ "View source"
    assert html =~ "Your actual offer may vary"
  end

  test "creates and evaluates alert rules in the alerts workspace", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    mortgage =
      mortgage_fixture(user, %{
        property_name: "Maple Residence",
        current_balance: "400000.00",
        current_interest_rate: "0.0625",
        monthly_payment_total: "2462.87",
        remaining_term_months: 360
      })

    {:ok, _scenario} =
      Loans.create_refinance_scenario(user, mortgage, %{
        name: "Expected refinance",
        new_term_months: 360,
        new_interest_rate: "0.0550",
        new_principal_amount: "400000.00"
      })

    {:ok, view, html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/alerts")

    assert html =~ "Alert rules"

    view
    |> element("button", "Add alert")
    |> render_click()

    html =
      view
      |> form("#loan-alert-rule-form",
        alert_rule: %{
          "name" => "Savings above target",
          "kind" => "monthly_savings_above_threshold",
          "threshold_value" => "100.00",
          "cooldown_hours" => "12",
          "active" => "true"
        }
      )
      |> render_submit()

    assert html =~ "Loan alert rule saved."
    assert html =~ "Savings above target"
    assert html =~ "12 hours"
    assert html =~ "Durable notifications, 12h cooldown"

    html =
      view
      |> element("button", "Evaluate")
      |> render_click()

    assert html =~ "Evaluated 1 alert rules; 1 triggered."

    html =
      view
      |> element("button", "Queue evaluation")
      |> render_click()

    assert html =~ "Loan alert evaluation queued."
  end

  test "adds refinance fee assumptions and updates break-even outputs", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    mortgage =
      mortgage_fixture(user, %{
        property_name: "Maple Residence",
        current_balance: "400000.00",
        current_interest_rate: "0.0625",
        monthly_payment_total: "2462.87",
        remaining_term_months: 360
      })

    {:ok, scenario} =
      Loans.create_refinance_scenario(user, mortgage, %{
        name: "Expected refinance",
        new_term_months: 360,
        new_interest_rate: "0.0550",
        new_principal_amount: "406000.00"
      })

    {:ok, view, html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/refinance")

    assert html =~ "Cost assumptions"
    refute html =~ ~s(id="refinance-fee-item-form")

    html =
      view
      |> element("button", "Add fee item")
      |> render_click()

    assert html =~ ~s(id="refinance-fee-item-form")

    view
    |> form("#refinance-fee-item-form",
      refinance_fee_item: %{
        "refinance_scenario_id" => scenario.id,
        "name" => "Origination fee",
        "category" => "origination",
        "expected_amount" => "6000.00",
        "kind" => "fee",
        "is_true_cost" => "true",
        "is_prepaid_or_escrow" => "false",
        "sort_order" => "0"
      }
    )
    |> render_submit()

    view
    |> element("button", "Add fee item")
    |> render_click()

    html =
      view
      |> form("#refinance-fee-item-form",
        refinance_fee_item: %{
          "refinance_scenario_id" => scenario.id,
          "name" => "Initial escrow deposit",
          "category" => "escrow_deposit",
          "expected_amount" => "4200.00",
          "kind" => "timing_cost",
          "is_true_cost" => "false",
          "is_prepaid_or_escrow" => "true",
          "sort_order" => "1"
        }
      )
      |> render_submit()

    assert html =~ "Refinance fee item saved."
    assert html =~ "$6000.00"
    assert html =~ "$10200.00"
    assert html =~ "39 months"
  end

  test "shows range outputs and reset-term warnings in scenario comparison", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    mortgage =
      mortgage_fixture(user, %{
        property_name: "Maple Residence",
        current_balance: "200000.00",
        current_interest_rate: "0.0300",
        monthly_payment_total: "1931.00",
        remaining_term_months: 120
      })

    {:ok, scenario} =
      Loans.create_refinance_scenario(user, mortgage, %{
        name: "Reset term refinance",
        new_term_months: 360,
        new_interest_rate: "0.0200",
        new_principal_amount: "210000.00"
      })

    {:ok, view, html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/refinance")

    assert html =~ "Payment range"
    assert html =~ "Break-even range"
    assert html =~ "Warnings"
    assert html =~ "Analysis details"
    assert html =~ "Lowest expected payment"
    assert html =~ "Low"
    assert html =~ "Expected"
    assert html =~ "High"
    assert html =~ "$737.39"
    assert html =~ "$776.20"
    assert html =~ "$815.01"
    assert html =~ "Review needed"
    assert html =~ "Monthly payment decreases, but full-term finance cost increases."
    assert html =~ "Expected payment"
    assert html =~ "Expected break-even"
    assert html =~ "Full-term delta"
    assert html =~ "Current full-term total"
    assert html =~ "New full-term total"
    assert html =~ "Cash timing cost"

    html =
      view
      |> element("button", "Close details")
      |> render_click()

    assert html =~ "Select “View details”"

    analysis_detail_id = "analysis-detail-#{scenario.id}"

    html =
      view
      |> element("button[phx-value-id='#{scenario.id}']", "View details")
      |> render_click()

    assert_push_event(view, "scroll-into-view", %{id: ^analysis_detail_id})
    assert html =~ ~s(id="#{analysis_detail_id}")
    assert html =~ ~s(aria-controls="#{analysis_detail_id}")
  end

  test "saves deterministic analysis history from a refinance scenario", %{conn: conn} do
    {:ok, %{conn: authed_conn, user: user}} = register_and_log_in_user(%{conn: conn})

    mortgage =
      mortgage_fixture(user, %{
        property_name: "Maple Residence",
        current_balance: "400000.00",
        current_interest_rate: "0.0625",
        monthly_payment_total: "2462.87",
        remaining_term_months: 360
      })

    {:ok, scenario} =
      Loans.create_refinance_scenario(user, mortgage, %{
        name: "Expected refinance",
        new_term_months: 360,
        new_interest_rate: "0.0550",
        new_principal_amount: "406000.00"
      })

    {:ok, _fee_item} =
      Loans.create_refinance_fee_item(user, scenario, %{
        name: "Origination fee",
        category: "origination",
        expected_amount: "6000.00",
        is_true_cost: true,
        is_prepaid_or_escrow: false
      })

    {:ok, view, html} = live(authed_conn, ~p"/app/loans/#{mortgage.id}/refinance")

    assert html =~ "Analysis history"
    assert html =~ "Save an analysis"

    html =
      view
      |> element("button", "Save analysis")
      |> render_click()

    assert html =~ "Analysis snapshot saved."
    assert html =~ "Expected refinance"
    assert html =~ "$2305.22"
    assert html =~ "$6000.00"

    assert [_result] =
             Loans.list_refinance_analysis_results(user, refinance_scenario_id: scenario.id)
  end
end
