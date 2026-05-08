defmodule MoneyTree.Loans.LoanDocumentsTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures
  import MoneyTree.MortgagesFixtures

  alias MoneyTree.Loans
  alias MoneyTree.Loans.LoanDocument
  alias MoneyTree.Loans.LoanDocumentExtraction

  describe "loan documents" do
    test "creates and lists document metadata for a mortgage owned by the user" do
      user = user_fixture()
      mortgage = mortgage_fixture(user)

      assert {:ok, %LoanDocument{} = document} =
               Loans.create_loan_document(user, mortgage, valid_document_attrs())

      assert document.user_id == user.id
      assert document.mortgage_id == mortgage.id
      assert document.document_type == "loan_estimate"
      assert document.status == "uploaded"

      assert [%LoanDocument{id: document_id}] = Loans.list_loan_documents(user, mortgage)
      assert document_id == document.id
    end

    test "rejects document metadata for another user's mortgage" do
      user = user_fixture()
      other_user = user_fixture()
      mortgage = mortgage_fixture(other_user)

      assert {:error, :not_found} =
               Loans.create_loan_document(user, mortgage, valid_document_attrs())
    end

    test "creates reviewable extraction candidates without updating the mortgage" do
      user = user_fixture()

      mortgage =
        mortgage_fixture(user, %{
          current_balance: "400000.00",
          current_interest_rate: "0.0625"
        })

      {:ok, document} = Loans.create_loan_document(user, mortgage, valid_document_attrs())

      assert {:ok, %LoanDocumentExtraction{} = extraction} =
               Loans.create_loan_document_extraction(user, document, %{
                 extraction_method: "ollama",
                 model_name: "llama3.2",
                 extracted_payload: %{
                   "current_balance" => "390000.00",
                   "interest_rate" => "0.0575"
                 },
                 field_confidence: %{
                   "current_balance" => 0.91,
                   "interest_rate" => 0.84
                 },
                 source_citations: %{
                   "current_balance" => [%{"page" => 1, "text" => "Unpaid principal balance"}]
                 }
               })

      assert extraction.user_id == user.id
      assert extraction.mortgage_id == mortgage.id
      assert extraction.loan_document_id == document.id
      assert extraction.status == "pending_review"

      assert [%LoanDocumentExtraction{id: extraction_id}] =
               Loans.list_loan_document_extractions(user, document)

      assert extraction_id == extraction.id

      unchanged_mortgage = MoneyTree.Repo.reload!(mortgage)
      assert unchanged_mortgage.current_balance == mortgage.current_balance
      assert unchanged_mortgage.current_interest_rate == mortgage.current_interest_rate
    end

    test "creates Ollama extraction candidates from review text without updating the mortgage" do
      user = user_fixture()

      {:ok, _preference} =
        MoneyTree.AI.update_settings(user, %{
          local_ai_enabled: true,
          default_model: "test-model:latest"
        })

      mortgage =
        mortgage_fixture(user, %{
          current_balance: "400000.00",
          current_interest_rate: "0.0625",
          remaining_term_months: 360
        })

      {:ok, document} = Loans.create_loan_document(user, mortgage, valid_document_attrs())

      assert {:ok, %LoanDocumentExtraction{} = extraction} =
               Loans.create_ollama_loan_document_extraction(
                 user,
                 document,
                 """
                 Mortgage statement
                 Unpaid principal balance $390,000.00
                 Interest rate 5.75%
                 Remaining term 348 months
                 Monthly payment $2,275.41
                 """
               )

      assert extraction.extraction_method == "ollama"
      assert extraction.model_name == "test-model:latest"
      assert extraction.status == "pending_review"
      assert extraction.extracted_payload["current_balance"] == "390000.00"
      assert extraction.extracted_payload["current_interest_rate"] == "0.0575"
      assert extraction.extracted_payload["remaining_term_months"] == 348
      assert extraction.extracted_payload["monthly_payment_total"] == "2275.41"
      assert extraction.field_confidence["current_balance"] == 0.91

      assert [%{"text" => "Unpaid principal balance $390,000.00", "page" => 1}] =
               extraction.source_citations["current_balance"]

      unchanged_mortgage = MoneyTree.Repo.reload!(mortgage)
      assert unchanged_mortgage.current_balance == mortgage.current_balance
      assert unchanged_mortgage.current_interest_rate == mortgage.current_interest_rate
      assert unchanged_mortgage.remaining_term_months == mortgage.remaining_term_months
    end

    test "requires local AI to be enabled before Ollama extraction" do
      user = user_fixture()
      mortgage = mortgage_fixture(user)
      {:ok, document} = Loans.create_loan_document(user, mortgage, valid_document_attrs())

      assert {:error, :disabled_for_user} =
               Loans.create_ollama_loan_document_extraction(
                 user,
                 document,
                 "Unpaid principal balance $390,000.00"
               )
    end

    test "enqueues and processes stored readable documents into Ollama candidates" do
      user = user_fixture()

      {:ok, _preference} =
        MoneyTree.AI.update_settings(user, %{
          local_ai_enabled: true,
          default_model: "test-model:latest"
        })

      mortgage = mortgage_fixture(user)
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
        Loans.create_loan_document(
          user,
          mortgage,
          valid_document_attrs()
          |> Map.merge(%{
            content_type: "text/plain",
            original_filename: "statement.txt",
            storage_key: storage_key
          })
        )

      assert {:ok, _job} = Loans.enqueue_loan_document_extraction(user, document)

      assert [%LoanDocumentExtraction{extraction_method: "ollama"} = extraction] =
               Loans.list_loan_document_extractions(user, document)

      assert extraction.extracted_payload["current_balance"] == "390000.00"
      assert extraction.extracted_payload["current_interest_rate"] == "0.0575"
      assert extraction.ocr_text_storage_key == "loan-documents/#{document.id}/extracted-text.txt"

      extracted_text_path =
        Path.join([System.tmp_dir!(), "money_tree", "uploads", extraction.ocr_text_storage_key])

      assert File.read!(extracted_text_path) =~ "Unpaid principal balance $390,000.00"

      assert {:ok, processed_document} = Loans.fetch_loan_document(user, document.id)
      assert processed_document.status == "pending_review"
    end

    test "extracts embedded text from stored PDF documents before Ollama review" do
      if System.find_executable("pdftotext") && System.find_executable("ps2pdf") do
        user = user_fixture()

        {:ok, _preference} =
          MoneyTree.AI.update_settings(user, %{
            local_ai_enabled: true,
            default_model: "test-model:latest"
          })

        mortgage = mortgage_fixture(user)
        storage_key = "loan-documents/#{Ecto.UUID.generate()}/statement.pdf"
        stored_path = Path.join([System.tmp_dir!(), "money_tree", "uploads", storage_key])
        ps_path = Path.rootname(stored_path) <> ".ps"

        File.mkdir_p!(Path.dirname(stored_path))

        File.write!(ps_path, """
        %!PS
        /Courier findfont 12 scalefont setfont
        72 720 moveto (Mortgage statement) show
        72 700 moveto (Unpaid principal balance $390,000.00) show
        72 680 moveto (Interest rate 5.75%) show
        72 660 moveto (Remaining term 348 months) show
        72 640 moveto (Monthly payment $2,275.41) show
        showpage
        """)

        assert {_output, 0} = System.cmd("ps2pdf", [ps_path, stored_path])

        {:ok, document} =
          Loans.create_loan_document(
            user,
            mortgage,
            valid_document_attrs()
            |> Map.merge(%{
              content_type: "application/pdf",
              original_filename: "statement.pdf",
              byte_size: File.stat!(stored_path).size,
              storage_key: storage_key
            })
          )

        assert {:ok, _job} = Loans.enqueue_loan_document_extraction(user, document)

        assert [%LoanDocumentExtraction{extraction_method: "ollama"} = extraction] =
                 Loans.list_loan_document_extractions(user, document)

        assert extraction.extracted_payload["current_balance"] == "390000.00"
        assert extraction.extracted_payload["current_interest_rate"] == "0.0575"

        assert extraction.ocr_text_storage_key ==
                 "loan-documents/#{document.id}/extracted-text.txt"

        extracted_text_path =
          Path.join([System.tmp_dir!(), "money_tree", "uploads", extraction.ocr_text_storage_key])

        assert File.read!(extracted_text_path) =~ "Mortgage statement"

        assert {:ok, processed_document} = Loans.fetch_loan_document(user, document.id)
        assert processed_document.status == "pending_review"
      end
    end

    test "confirms and rejects extraction candidates without updating the mortgage" do
      user = user_fixture()

      mortgage =
        mortgage_fixture(user, %{
          current_balance: "400000.00",
          current_interest_rate: "0.0625"
        })

      {:ok, document} = Loans.create_loan_document(user, mortgage, valid_document_attrs())

      {:ok, extraction} =
        Loans.create_loan_document_extraction(user, document, %{
          extraction_method: "manual",
          extracted_payload: %{"current_balance" => "390000.00"}
        })

      assert {:ok, confirmed} = Loans.confirm_loan_document_extraction(user, extraction)
      assert confirmed.status == "confirmed"
      assert confirmed.reviewed_at
      assert confirmed.confirmed_at
      refute confirmed.rejected_at

      unchanged_mortgage = MoneyTree.Repo.reload!(mortgage)
      assert unchanged_mortgage.current_balance == mortgage.current_balance

      assert {:ok, rejected} = Loans.reject_loan_document_extraction(user, confirmed)
      assert rejected.status == "rejected"
      assert rejected.reviewed_at
      refute rejected.confirmed_at
      assert rejected.rejected_at

      unchanged_mortgage = MoneyTree.Repo.reload!(mortgage)
      assert unchanged_mortgage.current_balance == mortgage.current_balance
    end

    test "applies confirmed mortgage extraction fields explicitly" do
      user = user_fixture()

      mortgage =
        mortgage_fixture(user, %{
          current_balance: "400000.00",
          current_interest_rate: "0.0625",
          remaining_term_months: 360,
          monthly_payment_total: "2462.87"
        })

      {:ok, document} = Loans.create_loan_document(user, mortgage, valid_document_attrs())

      {:ok, extraction} =
        Loans.create_loan_document_extraction(user, document, %{
          extraction_method: "manual",
          extracted_payload: %{
            "current_balance" => "390000.00",
            "current_interest_rate" => "0.0575",
            "remaining_term_months" => 348,
            "ignored_field" => "not applied"
          }
        })

      assert {:error, :not_confirmed} =
               Loans.apply_loan_document_extraction_to_mortgage(user, extraction)

      {:ok, confirmed} = Loans.confirm_loan_document_extraction(user, extraction)

      assert {:ok, updated_mortgage} =
               Loans.apply_loan_document_extraction_to_mortgage(user, confirmed)

      assert updated_mortgage.current_balance == Decimal.new("390000.00")
      assert Decimal.equal?(updated_mortgage.current_interest_rate, Decimal.new("0.0575"))
      assert updated_mortgage.remaining_term_months == 348
      assert updated_mortgage.monthly_payment_total == Decimal.new("2462.87")
      assert updated_mortgage.source == "document_extraction"
      assert updated_mortgage.last_reviewed_at
    end

    test "creates lender quotes from confirmed extraction candidates" do
      user = user_fixture()
      mortgage = mortgage_fixture(user)
      {:ok, document} = Loans.create_loan_document(user, mortgage, valid_document_attrs())

      {:ok, extraction} =
        Loans.create_loan_document_extraction(user, document, %{
          extraction_method: "manual",
          extracted_payload: %{
            "lender_name" => "Example Lender",
            "product_type" => "fixed",
            "term_months" => 360,
            "interest_rate" => "0.0550",
            "apr" => "0.0560",
            "monthly_payment" => "2305.22",
            "closing_costs" => "6500.00",
            "cash_to_close" => "9000.00"
          },
          source_citations: %{
            "interest_rate" => [%{"text" => "Rate 5.50%"}]
          }
        })

      assert {:error, :not_confirmed} =
               Loans.create_lender_quote_from_document_extraction(user, extraction)

      {:ok, confirmed} = Loans.confirm_loan_document_extraction(user, extraction)

      assert {:ok, quote} =
               Loans.create_lender_quote_from_document_extraction(user, confirmed)

      assert quote.mortgage_id == mortgage.id
      assert quote.lender_name == "Example Lender"
      assert quote.quote_source == "document"
      assert quote.product_type == "fixed"
      assert quote.term_months == 360
      assert Decimal.equal?(quote.interest_rate, Decimal.new("0.0550"))
      assert quote.estimated_monthly_payment_expected == Decimal.new("2305.22")
      assert quote.estimated_closing_costs_expected == Decimal.new("6500.00")
      assert quote.estimated_cash_to_close_expected == Decimal.new("9000.00")
      assert quote.raw_payload["loan_document_extraction_id"] == confirmed.id
    end

    test "creates refinance scenarios from confirmed extraction candidates" do
      user = user_fixture()

      mortgage =
        mortgage_fixture(user, %{
          current_balance: "400000.00",
          current_interest_rate: "0.0625",
          remaining_term_months: 360,
          monthly_payment_total: "2462.87"
        })

      {:ok, document} = Loans.create_loan_document(user, mortgage, valid_document_attrs())

      {:ok, extraction} =
        Loans.create_loan_document_extraction(user, document, %{
          extraction_method: "manual",
          extracted_payload: %{
            "lender_name" => "Example Lender",
            "product_type" => "fixed",
            "term_months" => 360,
            "interest_rate" => "0.0550",
            "apr" => "0.0560",
            "closing_costs" => "6500.00",
            "cash_to_close" => "9000.00"
          }
        })

      assert {:error, :not_confirmed} =
               Loans.create_refinance_scenario_from_document_extraction(user, extraction)

      {:ok, confirmed} = Loans.confirm_loan_document_extraction(user, extraction)

      assert {:ok, scenario} =
               Loans.create_refinance_scenario_from_document_extraction(user, confirmed)

      assert scenario.name == "Example Lender document scenario"
      assert scenario.scenario_type == "document_extraction"
      assert scenario.rate_source_type == "document_extraction"
      assert scenario.product_type == "fixed"
      assert scenario.new_term_months == 360
      assert Decimal.equal?(scenario.new_interest_rate, Decimal.new("0.0550"))
      assert Decimal.equal?(scenario.new_apr, Decimal.new("0.0560"))
      assert scenario.new_principal_amount == Decimal.new("400000.00")

      assert [
               %{name: "Extracted refinance costs", expected_amount: closing_costs},
               %{name: "Extracted prepaid and escrow timing costs", expected_amount: timing_cost}
             ] = scenario.fee_items

      assert closing_costs == Decimal.new("6500.00")
      assert timing_cost == Decimal.new("2500.00")
    end

    test "does not apply confirmed extraction candidates with no mortgage fields" do
      user = user_fixture()
      mortgage = mortgage_fixture(user)
      {:ok, document} = Loans.create_loan_document(user, mortgage, valid_document_attrs())

      {:ok, extraction} =
        Loans.create_loan_document_extraction(user, document, %{
          extraction_method: "manual",
          extracted_payload: %{"statement_date" => "2026-05-01"}
        })

      {:ok, confirmed} = Loans.confirm_loan_document_extraction(user, extraction)

      assert {:error, :no_applicable_fields} =
               Loans.apply_loan_document_extraction_to_mortgage(user, confirmed)
    end

    test "prevents adding extraction candidates to another user's document" do
      user = user_fixture()
      other_user = user_fixture()
      mortgage = mortgage_fixture(other_user)

      {:ok, document} =
        Loans.create_loan_document(other_user, mortgage, valid_document_attrs())

      assert {:error, :not_found} =
               Loans.create_loan_document_extraction(user, document, %{
                 extraction_method: "manual",
                 extracted_payload: %{"current_balance" => "390000.00"}
               })
    end
  end

  defp valid_document_attrs do
    %{
      document_type: "loan_estimate",
      original_filename: "loan-estimate.pdf",
      content_type: "application/pdf",
      byte_size: 123_456,
      storage_key: "loan-documents/#{Ecto.UUID.generate()}/loan-estimate.pdf",
      checksum_sha256: String.duplicate("a", 64)
    }
  end
end
