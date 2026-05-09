defmodule MoneyTree.Loans.AlertRulesTest do
  use MoneyTree.DataCase, async: true

  import Ecto.Query
  import MoneyTree.AccountsFixtures
  import MoneyTree.MortgagesFixtures

  alias MoneyTree.Loans
  alias MoneyTree.Loans.AlertRule
  alias MoneyTree.Notifications.Event
  alias MoneyTree.Repo

  describe "loan alert rules" do
    test "creates and lists alert rules for a mortgage owned by the user" do
      user = user_fixture()
      mortgage = mortgage_fixture(user)

      assert {:ok, %AlertRule{} = rule} =
               Loans.create_loan_alert_rule(user, mortgage, %{
                 name: "Payment below target",
                 kind: "monthly_payment_below_threshold",
                 threshold_value: "2300.00"
               })

      assert rule.user_id == user.id
      assert rule.mortgage_id == mortgage.id
      assert rule.threshold_config == %{"threshold" => "2300.00"}

      assert [%AlertRule{id: rule_id}] = Loans.list_loan_alert_rules(user, mortgage)
      assert rule_id == rule.id
    end

    test "rejects alert rules for another user's mortgage" do
      user = user_fixture()
      other_user = user_fixture()
      mortgage = mortgage_fixture(other_user)

      assert {:error, :not_found} =
               Loans.create_loan_alert_rule(user, mortgage, %{
                 name: "Payment below target",
                 kind: "monthly_payment_below_threshold",
                 threshold_value: "2300.00"
               })
    end

    test "evaluates scenario threshold rules through notification events" do
      user = user_fixture()

      mortgage =
        mortgage_fixture(user, %{
          current_balance: "400000.00",
          current_interest_rate: "0.0625",
          remaining_term_months: 360,
          monthly_payment_total: "2462.87"
        })

      {:ok, scenario} =
        Loans.create_refinance_scenario(user, mortgage, %{
          name: "Lower rate scenario",
          new_term_months: 360,
          new_interest_rate: "0.0550",
          new_principal_amount: "400000.00"
        })

      {:ok, rule} =
        Loans.create_loan_alert_rule(user, mortgage, %{
          name: "Savings above 100",
          kind: "monthly_savings_above_threshold",
          threshold_value: "100.00"
        })

      assert {:ok, %{triggered?: true, rule: evaluated_rule}} =
               Loans.evaluate_loan_alert_rule(user, rule)

      assert evaluated_rule.last_evaluated_at
      assert evaluated_rule.last_triggered_at

      assert %Event{} =
               event =
               Repo.one!(
                 from event in Event,
                   where:
                     event.user_id == ^user.id and event.kind == "loan_refinance_alert" and
                       event.status == "monthly_savings_above_threshold"
               )

      assert event.metadata["loan_alert_rule_id"] == rule.id
      assert event.metadata["refinance_scenario_id"] == scenario.id
    end

    test "suppresses repeated alert notifications during rule cooldown" do
      user = user_fixture()

      mortgage =
        mortgage_fixture(user, %{
          current_balance: "400000.00",
          current_interest_rate: "0.0625",
          remaining_term_months: 360,
          monthly_payment_total: "2462.87"
        })

      {:ok, _scenario} =
        Loans.create_refinance_scenario(user, mortgage, %{
          name: "Lower rate scenario",
          new_term_months: 360,
          new_interest_rate: "0.0550",
          new_principal_amount: "400000.00"
        })

      {:ok, rule} =
        Loans.create_loan_alert_rule(user, mortgage, %{
          name: "Savings above 100",
          kind: "monthly_savings_above_threshold",
          threshold_value: "100.00",
          delivery_preferences: %{"cooldown_hours" => 24}
        })

      assert {:ok, %{triggered?: true, rule: triggered_rule}} =
               Loans.evaluate_loan_alert_rule(user, rule)

      assert {:ok, %{triggered?: false, rule: cooled_down_rule}} =
               Loans.evaluate_loan_alert_rule(user, triggered_rule)

      assert cooled_down_rule.last_triggered_at == triggered_rule.last_triggered_at

      assert 1 ==
               Repo.aggregate(
                 from(event in Event,
                   where:
                     event.user_id == ^user.id and event.kind == "loan_refinance_alert" and
                       event.status == "monthly_savings_above_threshold"
                 ),
                 :count
               )
    end

    test "evaluates document review rules" do
      user = user_fixture()
      mortgage = mortgage_fixture(user)

      {:ok, _document} =
        Loans.create_loan_document(user, mortgage, %{
          document_type: "loan_estimate",
          original_filename: "loan-estimate.pdf",
          content_type: "application/pdf",
          byte_size: 123_456,
          storage_key: "loan-documents/#{Ecto.UUID.generate()}/loan-estimate.pdf",
          checksum_sha256: String.duplicate("a", 64),
          status: "pending_review"
        })

      {:ok, rule} =
        Loans.create_loan_alert_rule(user, mortgage, %{
          name: "Documents need review",
          kind: "document_review_needed"
        })

      assert {:ok, %{triggered?: true}} = Loans.evaluate_loan_alert_rule(user, rule)
    end

    test "evaluates lender quote expiration rules" do
      user = user_fixture()
      mortgage = mortgage_fixture(user)

      {:ok, quote} =
        Loans.create_lender_quote(user, mortgage, %{
          lender_name: "Expiring Lender",
          quote_source: "manual",
          loan_type: "mortgage",
          product_type: "fixed",
          term_months: 360,
          interest_rate: "0.0550",
          lock_available: false,
          quote_expires_at: DateTime.add(DateTime.utc_now(), 2 * 86_400, :second),
          raw_payload: %{},
          status: "active"
        })

      {:ok, rule} =
        Loans.create_loan_alert_rule(user, mortgage, %{
          name: "Quote expires soon",
          kind: "lender_quote_expiring",
          lead_days: "7"
        })

      assert {:ok, %{triggered?: true}} = Loans.evaluate_loan_alert_rule(user, rule)

      event =
        Repo.one!(
          from event in Event,
            where:
              event.user_id == ^user.id and event.kind == "loan_refinance_alert" and
                event.status == "lender_quote_expiring"
        )

      assert event.metadata["lender_quote_id"] == quote.id
    end

    test "scheduled alert evaluation worker evaluates all active loan alerts" do
      user = user_fixture()

      mortgage =
        mortgage_fixture(user, %{
          current_balance: "400000.00",
          current_interest_rate: "0.0625",
          remaining_term_months: 360,
          monthly_payment_total: "2462.87"
        })

      {:ok, _scenario} =
        Loans.create_refinance_scenario(user, mortgage, %{
          name: "Lower rate scenario",
          new_term_months: 360,
          new_interest_rate: "0.0550",
          new_principal_amount: "400000.00"
        })

      {:ok, active_rule} =
        Loans.create_loan_alert_rule(user, mortgage, %{
          name: "Savings above 100",
          kind: "monthly_savings_above_threshold",
          threshold_value: "100.00"
        })

      {:ok, _inactive_rule} =
        Loans.create_loan_alert_rule(user, mortgage, %{
          name: "Inactive savings alert",
          kind: "monthly_savings_above_threshold",
          threshold_value: "100.00",
          active: false
        })

      assert {:ok, _job} = Loans.enqueue_all_loan_alert_evaluations()

      assert {:ok, evaluated_rule} = Loans.fetch_loan_alert_rule(user, active_rule.id)
      assert evaluated_rule.last_evaluated_at
      assert evaluated_rule.last_triggered_at

      assert 1 ==
               Repo.aggregate(
                 from(event in Event,
                   where:
                     event.user_id == ^user.id and event.kind == "loan_refinance_alert" and
                       event.status == "monthly_savings_above_threshold"
                 ),
                 :count
               )
    end
  end
end
