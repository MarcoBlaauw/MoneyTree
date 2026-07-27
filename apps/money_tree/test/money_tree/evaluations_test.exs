defmodule MoneyTree.EvaluationsTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures
  import MoneyTree.MortgagesFixtures

  alias MoneyTree.Evaluations
  alias MoneyTree.Loans
  alias MoneyTree.Loans.LenderQuoteFeeLine
  alias MoneyTree.Recurring.Anomaly
  alias MoneyTree.Recurring.Series
  alias MoneyTree.Repo

  @now ~U[2026-05-22 12:00:00Z]

  describe "status_summary/2" do
    test "aggregates deterministic status items for the current user's loans and mortgage workflow" do
      user = user_fixture()

      mortgage =
        mortgage_fixture(user, %{
          nickname: "Home loan",
          home_value_estimate: nil,
          last_reviewed_at: DateTime.add(@now, -120, :day)
        })

      {:ok, loan} =
        Loans.create_loan(user, %{
          loan_type: "auto",
          name: "Car loan",
          current_balance: "18500.00",
          current_interest_rate: "0.0799",
          remaining_term_months: 48,
          monthly_payment_total: "452.13"
        })

      {:ok, document} =
        Loans.create_loan_document(user, mortgage, valid_document_attrs())

      {:ok, extraction} =
        Loans.create_loan_document_extraction(user, document, %{
          extraction_method: "manual",
          extracted_payload: %{"current_balance" => "390000.00"}
        })

      {:ok, quote} =
        Loans.create_lender_quote(user, mortgage, %{
          lender_name: "Example Lender",
          quote_source: "manual",
          loan_type: "mortgage",
          term_months: 360,
          interest_rate: "0.0550",
          lock_available: true,
          quote_expires_at: DateTime.add(@now, 3, :day),
          raw_payload: %{},
          status: "active"
        })

      summary = Evaluations.status_summary(user, now: @now)

      assert summary.counts == %{
               "incomplete" => 1,
               "stale" => 1,
               "needs_review" => 2,
               "opportunity" => 0,
               "expiring" => 1
             }

      item_ids = Enum.map(summary.items, & &1.id)

      assert "mortgage:#{mortgage.id}:home_value" in item_ids
      assert "mortgage:#{mortgage.id}:stale" in item_ids
      assert "loan:#{loan.id}:review" in item_ids
      assert "loan_document_extraction:#{extraction.id}:review" in item_ids
      assert "lender_quote:#{quote.id}:expiration" in item_ids
    end

    test "includes existing review signals from documents quote fees and recurring anomalies" do
      user = user_fixture()
      account = account_fixture(user, %{name: "Bills Checking"})

      mortgage =
        mortgage_fixture(user, %{
          nickname: "Reviewed home",
          home_value_estimate: "500000.00",
          last_reviewed_at: @now
        })

      {:ok, failed_document} =
        Loans.create_loan_document(
          user,
          mortgage,
          valid_document_attrs()
          |> Map.merge(%{
            original_filename: "failed-estimate.pdf",
            status: "failed"
          })
        )

      {:ok, stuck_document} =
        Loans.create_loan_document(
          user,
          mortgage,
          valid_document_attrs()
          |> Map.merge(%{
            original_filename: "queued-estimate.pdf",
            status: "queued"
          })
        )

      stuck_document =
        stuck_document
        |> Ecto.Changeset.change(updated_at: microsecond(@now |> DateTime.add(-45, :minute)))
        |> Repo.update!()

      {:ok, quote} =
        Loans.create_lender_quote(user, mortgage, %{
          lender_name: "Fee Review Lender",
          quote_source: "manual",
          loan_type: "mortgage",
          term_months: 360,
          interest_rate: "0.0550",
          lock_available: true,
          raw_payload: %{},
          status: "active"
        })

      fee_line =
        %LenderQuoteFeeLine{}
        |> LenderQuoteFeeLine.changeset(%{
          lender_quote_id: quote.id,
          original_label: "Mystery review charge",
          amount: "999.00",
          classification: "unknown_fee_type",
          confidence_level: "low",
          required: false,
          requires_review: true,
          review_note: "No matching fee type.",
          raw_payload: %{}
        })
        |> Repo.insert!()

      series =
        %Series{}
        |> Series.changeset(%{
          user_id: user.id,
          account_id: account.id,
          fingerprint: "Power Co",
          series_key: "power-co",
          cadence: "monthly",
          status: "active"
        })
        |> Repo.insert!()

      anomaly =
        %Anomaly{}
        |> Anomaly.changeset(%{
          series_id: series.id,
          anomaly_type: "missing_cycle",
          status: "open",
          severity: "warning",
          occurred_on: ~D[2026-05-01],
          detected_at: microsecond(@now)
        })
        |> Repo.insert!()

      summary = Evaluations.status_summary(user, now: @now)
      item_ids = Enum.map(summary.items, & &1.id)

      assert summary.counts["needs_review"] == 4
      assert "loan_document:#{failed_document.id}:failed" in item_ids
      assert "loan_document:#{stuck_document.id}:queued" in item_ids
      assert "lender_quote_fee_line:#{fee_line.id}:review" in item_ids
      assert "recurring_anomaly:#{anomaly.id}:open" in item_ids
    end

    test "scopes status items to the requested user" do
      user = user_fixture()
      other_user = user_fixture()

      _other_mortgage =
        mortgage_fixture(other_user, %{
          nickname: "Other home",
          home_value_estimate: nil,
          last_reviewed_at: nil
        })

      assert Evaluations.status_summary(user, now: @now).counts == %{
               "incomplete" => 0,
               "stale" => 0,
               "needs_review" => 0,
               "opportunity" => 0,
               "expiring" => 0
             }
    end
  end

  defp valid_document_attrs do
    %{
      document_type: "loan_estimate",
      original_filename: "estimate.pdf",
      content_type: "application/pdf",
      byte_size: 1024,
      storage_key: "loan-documents/#{Ecto.UUID.generate()}/estimate.pdf",
      checksum_sha256: String.duplicate("a", 64),
      status: "uploaded"
    }
  end

  defp microsecond(%DateTime{} = datetime) do
    %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}
  end
end
