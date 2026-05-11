defmodule MoneyTreeWeb.LoanDocumentControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures
  import MoneyTree.MortgagesFixtures

  alias MoneyTreeWeb.Auth

  @session_cookie Auth.session_cookie_name()

  describe "loan document API" do
    test "creates, lists, fetches, and extracts review candidates", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user)
      mortgage = mortgage_fixture(user)

      authed_conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

      create_conn =
        post(authed_conn, ~p"/api/loans/#{mortgage.id}/documents", valid_document_payload())

      assert %{
               "data" => %{
                 "id" => document_id,
                 "mortgage_id" => mortgage_id,
                 "document_type" => "loan_estimate",
                 "original_filename" => "loan-estimate.pdf",
                 "status" => "uploaded",
                 "extractions" => []
               }
             } = json_response(create_conn, 201)

      assert mortgage_id == mortgage.id

      list_conn = get(authed_conn, ~p"/api/loans/#{mortgage.id}/documents")

      assert %{"data" => [%{"id" => ^document_id, "document_type" => "loan_estimate"}]} =
               json_response(list_conn, 200)

      show_conn = get(authed_conn, ~p"/api/loan_documents/#{document_id}")

      assert %{"data" => %{"id" => ^document_id, "extractions" => []}} =
               json_response(show_conn, 200)

      extract_conn =
        post(authed_conn, ~p"/api/loan_documents/#{document_id}/extract", %{
          "extraction_method" => "ollama",
          "model_name" => "llama3.2",
          "extracted_payload" => %{
            "current_balance" => "390000.00",
            "interest_rate" => "0.0575"
          },
          "field_confidence" => %{
            "current_balance" => 0.91,
            "interest_rate" => 0.84
          },
          "source_citations" => %{
            "current_balance" => [%{"page" => 1, "text" => "Unpaid principal balance"}]
          }
        })

      assert %{
               "data" => %{
                 "loan_document_id" => ^document_id,
                 "id" => extraction_id,
                 "extraction_method" => "ollama",
                 "status" => "pending_review",
                 "extracted_payload" => %{"current_balance" => "390000.00"}
               }
             } = json_response(extract_conn, 201)

      apply_pending_conn =
        post(authed_conn, ~p"/api/loan_document_extractions/#{extraction_id}/apply", %{})

      assert json_response(apply_pending_conn, 422) == %{
               "error" => "extraction must be confirmed before applying"
             }

      confirm_conn =
        post(authed_conn, ~p"/api/loan_document_extractions/#{extraction_id}/confirm", %{})

      assert %{
               "data" => %{
                 "id" => ^extraction_id,
                 "status" => "confirmed",
                 "confirmed_at" => confirmed_at,
                 "reviewed_at" => reviewed_at
               }
             } = json_response(confirm_conn, 200)

      assert is_binary(confirmed_at)
      assert is_binary(reviewed_at)

      apply_conn =
        post(authed_conn, ~p"/api/loan_document_extractions/#{extraction_id}/apply", %{})

      assert %{
               "data" => %{
                 "mortgage_id" => ^mortgage_id,
                 "current_balance" => "390000.00",
                 "current_interest_rate" => "0.057500",
                 "source" => "document_extraction",
                 "last_reviewed_at" => last_reviewed_at
               }
             } = json_response(apply_conn, 200)

      assert is_binary(last_reviewed_at)

      reject_conn =
        post(authed_conn, ~p"/api/loan_document_extractions/#{extraction_id}/reject", %{})

      assert %{
               "data" => %{
                 "id" => ^extraction_id,
                 "status" => "rejected",
                 "confirmed_at" => nil,
                 "rejected_at" => rejected_at
               }
             } = json_response(reject_conn, 200)

      assert is_binary(rejected_at)
    end

    test "creates lender quote from confirmed extraction candidates", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user)
      mortgage = mortgage_fixture(user)

      authed_conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

      document_id =
        authed_conn
        |> post(~p"/api/loans/#{mortgage.id}/documents", valid_document_payload())
        |> json_response(201)
        |> get_in(["data", "id"])

      extraction_id =
        authed_conn
        |> post(~p"/api/loan_documents/#{document_id}/extract", %{
          "extraction_method" => "manual",
          "extracted_payload" => %{
            "lender_name" => "Example Lender",
            "term_months" => 360,
            "interest_rate" => "0.0550",
            "monthly_payment" => "2305.22",
            "closing_costs" => "6500.00",
            "cash_to_close" => "9000.00"
          }
        })
        |> json_response(201)
        |> get_in(["data", "id"])

      pending_conn =
        post(
          authed_conn,
          ~p"/api/loan_document_extractions/#{extraction_id}/create_lender_quote",
          %{}
        )

      assert json_response(pending_conn, 422) == %{
               "error" => "extraction must be confirmed before creating a lender quote"
             }

      post(authed_conn, ~p"/api/loan_document_extractions/#{extraction_id}/confirm", %{})

      quote_conn =
        post(
          authed_conn,
          ~p"/api/loan_document_extractions/#{extraction_id}/create_lender_quote",
          %{}
        )

      assert %{
               "data" => %{
                 "lender_name" => "Example Lender",
                 "quote_source" => "document",
                 "term_months" => 360,
                 "interest_rate" => "0.0550",
                 "estimated_monthly_payment_expected" => "2305.22",
                 "estimated_closing_costs_expected" => "6500.00",
                 "estimated_cash_to_close_expected" => "9000.00"
               }
             } = json_response(quote_conn, 201)
    end

    test "creates refinance scenario from confirmed extraction candidates", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user)

      mortgage =
        mortgage_fixture(user, %{
          current_balance: "400000.00",
          current_interest_rate: "0.0625",
          remaining_term_months: 360,
          monthly_payment_total: "2462.87"
        })

      authed_conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

      document_id =
        authed_conn
        |> post(~p"/api/loans/#{mortgage.id}/documents", valid_document_payload())
        |> json_response(201)
        |> get_in(["data", "id"])

      extraction_id =
        authed_conn
        |> post(~p"/api/loan_documents/#{document_id}/extract", %{
          "extraction_method" => "manual",
          "extracted_payload" => %{
            "lender_name" => "Example Lender",
            "term_months" => 360,
            "interest_rate" => "0.0550",
            "closing_costs" => "6500.00",
            "cash_to_close" => "9000.00"
          }
        })
        |> json_response(201)
        |> get_in(["data", "id"])

      pending_conn =
        post(
          authed_conn,
          ~p"/api/loan_document_extractions/#{extraction_id}/create_scenario",
          %{}
        )

      assert json_response(pending_conn, 422) == %{
               "error" => "extraction must be confirmed before creating a scenario"
             }

      post(authed_conn, ~p"/api/loan_document_extractions/#{extraction_id}/confirm", %{})

      scenario_conn =
        post(
          authed_conn,
          ~p"/api/loan_document_extractions/#{extraction_id}/create_scenario",
          %{"name" => "Uploaded estimate"}
        )

      assert %{
               "data" => %{
                 "name" => "Uploaded estimate",
                 "scenario_type" => "document_extraction",
                 "rate_source_type" => "document_extraction",
                 "new_term_months" => 360,
                 "new_interest_rate" => "0.0550",
                 "new_principal_amount" => "400000.00",
                 "fee_items" => fee_items
               }
             } = json_response(scenario_conn, 201)

      assert Enum.any?(fee_items, &(&1["name"] == "Extracted refinance costs"))
      assert Enum.any?(fee_items, &(&1["name"] == "Extracted prepaid and escrow timing costs"))
    end

    test "creates Ollama extraction candidates from raw text", %{conn: conn} do
      user = user_fixture()

      {:ok, _preference} =
        MoneyTree.AI.update_settings(user, %{
          local_ai_enabled: true,
          default_model: "test-model:latest"
        })

      %{token: token} = session_fixture(user)
      mortgage = mortgage_fixture(user)

      authed_conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

      document_id =
        authed_conn
        |> post(~p"/api/loans/#{mortgage.id}/documents", valid_document_payload())
        |> json_response(201)
        |> get_in(["data", "id"])

      extract_conn =
        post(authed_conn, ~p"/api/loan_documents/#{document_id}/extract", %{
          "raw_text" => """
          Mortgage statement
          Unpaid principal balance $390,000.00
          Interest rate 5.75%
          Remaining term 348 months
          Monthly payment $2,275.41
          """
        })

      assert %{
               "data" => %{
                 "loan_document_id" => ^document_id,
                 "extraction_method" => "ollama",
                 "model_name" => "test-model:latest",
                 "status" => "pending_review",
                 "raw_text_excerpt" => raw_text_excerpt,
                 "extracted_payload" => %{
                   "current_balance" => "390000.00",
                   "current_interest_rate" => "0.0575",
                   "remaining_term_months" => 348,
                   "monthly_payment_total" => "2275.41"
                 },
                 "field_confidence" => %{"current_balance" => 0.91},
                 "source_citations" => %{
                   "current_balance" => [
                     %{"page" => 1, "text" => "Unpaid principal balance $390,000.00"}
                   ]
                 }
               }
             } = json_response(extract_conn, 201)

      assert raw_text_excerpt =~ "Unpaid principal balance"
    end

    test "requires local AI for raw text extraction", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user)
      mortgage = mortgage_fixture(user)

      authed_conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

      document_id =
        authed_conn
        |> post(~p"/api/loans/#{mortgage.id}/documents", valid_document_payload())
        |> json_response(201)
        |> get_in(["data", "id"])

      conn =
        post(authed_conn, ~p"/api/loan_documents/#{document_id}/extract", %{
          "raw_text" => "Unpaid principal balance $390,000.00"
        })

      assert json_response(conn, 422) == %{
               "error" => "local AI must be enabled before running Ollama extraction"
             }
    end

    test "rejects access to another user's loan document", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      %{token: token} = session_fixture(user)
      mortgage = mortgage_fixture(other_user)

      authed_conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

      assert json_response(
               post(
                 authed_conn,
                 ~p"/api/loans/#{mortgage.id}/documents",
                 valid_document_payload()
               ),
               404
             ) == %{"error" => "loan not found"}

      %{token: other_token} = session_fixture(other_user)

      other_conn =
        conn
        |> recycle()
        |> put_req_header("cookie", "#{@session_cookie}=#{other_token}")

      document_id =
        other_conn
        |> post(~p"/api/loans/#{mortgage.id}/documents", valid_document_payload())
        |> json_response(201)
        |> get_in(["data", "id"])

      assert json_response(get(authed_conn, ~p"/api/loan_documents/#{document_id}"), 404) ==
               %{"error" => "loan document not found"}

      assert json_response(
               post(authed_conn, ~p"/api/loan_documents/#{document_id}/extract", %{
                 "extraction_method" => "manual",
                 "extracted_payload" => %{"current_balance" => "390000.00"}
               }),
               404
             ) == %{"error" => "loan document not found"}

      extraction_id =
        other_conn
        |> post(~p"/api/loan_documents/#{document_id}/extract", %{
          "extraction_method" => "manual",
          "extracted_payload" => %{"current_balance" => "390000.00"}
        })
        |> json_response(201)
        |> get_in(["data", "id"])

      assert json_response(
               post(
                 authed_conn,
                 ~p"/api/loan_document_extractions/#{extraction_id}/confirm",
                 %{}
               ),
               404
             ) == %{"error" => "loan document extraction not found"}
    end
  end

  defp valid_document_payload do
    %{
      "document_type" => "loan_estimate",
      "original_filename" => "loan-estimate.pdf",
      "content_type" => "application/pdf",
      "byte_size" => 123_456,
      "storage_key" => "loan-documents/#{Ecto.UUID.generate()}/loan-estimate.pdf",
      "checksum_sha256" => String.duplicate("a", 64)
    }
  end
end
