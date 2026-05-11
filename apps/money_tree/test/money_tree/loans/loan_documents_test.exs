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

    test "extracts OCR text from stored image documents before Ollama review" do
      if System.find_executable("tesseract") do
        user = user_fixture()

        {:ok, _preference} =
          MoneyTree.AI.update_settings(user, %{
            local_ai_enabled: true,
            default_model: "test-model:latest"
          })

        mortgage = mortgage_fixture(user)
        storage_key = "loan-documents/#{Ecto.UUID.generate()}/statement.png"
        stored_path = Path.join([System.tmp_dir!(), "money_tree", "uploads", storage_key])

        File.mkdir_p!(Path.dirname(stored_path))
        File.write!(stored_path, sample_statement_png())

        {:ok, document} =
          Loans.create_loan_document(
            user,
            mortgage,
            valid_document_attrs()
            |> Map.merge(%{
              content_type: "image/png",
              original_filename: "statement.png",
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

  defp sample_statement_png do
    """
    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
    """
    |> String.replace(~r/\s+/, "")
    |> Base.decode64!()
  end
end
