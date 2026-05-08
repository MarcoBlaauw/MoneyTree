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
  end
end
