defmodule MoneyTree.Loans.RateObservationsTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures
  import MoneyTree.MortgagesFixtures

  alias Decimal, as: D
  alias MoneyTree.Loans
  alias MoneyTree.Loans.RateObservation
  alias MoneyTree.Loans.RateSource
  alias MoneyTree.Loans.RefinanceScenario

  describe "loan rate sources and observations" do
    test "creates and lists manual benchmark rate observations" do
      assert {:ok, %RateSource{} = source} = Loans.get_or_create_manual_rate_source()
      assert source.provider_key == "manual"
      assert source.source_type == "manual"

      assert {:ok, %RateObservation{} = observation} =
               Loans.create_rate_observation(source, %{
                 loan_type: "mortgage",
                 product_type: "fixed",
                 term_months: 360,
                 rate: "0.06125",
                 apr: "0.06200",
                 points: "0.2500",
                 assumptions: %{"credit_score" => "740+", "down_payment" => "20%"},
                 raw_payload: %{"entered_by" => "test"}
               })

      assert observation.rate_source_id == source.id
      assert observation.loan_type == "mortgage"
      assert observation.product_type == "fixed"
      assert observation.term_months == 360
      assert D.equal?(observation.rate, D.new("0.06125"))
      assert D.equal?(observation.apr, D.new("0.06200"))
      assert observation.observed_at
      assert observation.imported_at
      assert observation.rate_source.provider_key == "manual"

      assert [%RateObservation{id: observation_id}] =
               Loans.list_rate_observations(
                 loan_type: "mortgage",
                 product_type: "fixed",
                 term_months: 360
               )

      assert observation_id == observation.id
    end

    test "normalizes source provider keys and enforces uniqueness" do
      assert {:ok, %RateSource{provider_key: "example-source"}} =
               Loans.create_rate_source(%{
                 provider_key: " Example-Source ",
                 name: "Example Source",
                 source_type: "public_benchmark"
               })

      assert {:error, changeset} =
               Loans.create_rate_source(%{
                 provider_key: "example-source",
                 name: "Duplicate Source",
                 source_type: "manual"
               })

      assert %{provider_key: ["has already been taken"]} = errors_on(changeset)
    end

    test "rejects invalid rate observation values" do
      assert {:ok, source} = Loans.get_or_create_manual_rate_source()

      assert {:error, changeset} =
               Loans.create_rate_observation(source, %{
                 loan_type: "mortgage",
                 term_months: 0,
                 rate: "-0.0100",
                 assumptions: []
               })

      assert "must be greater than 0" in errors_on(changeset).term_months
      assert "must be greater than or equal to 0" in errors_on(changeset).rate
      assert "is invalid" in errors_on(changeset).assumptions
    end

    test "creates a draft refinance scenario from a benchmark observation" do
      user = user_fixture()

      mortgage =
        mortgage_fixture(user, %{
          current_balance: "375000.00",
          current_interest_rate: "0.07125",
          remaining_term_months: 339,
          monthly_payment_total: "3233.65"
        })

      assert {:ok, source} = Loans.get_or_create_manual_rate_source()

      assert {:ok, observation} =
               Loans.create_rate_observation(source, %{
                 loan_type: "mortgage",
                 product_type: "fixed",
                 term_months: 360,
                 rate: "0.06125",
                 apr: "0.06200",
                 points: "0.2500"
               })

      assert {:ok, %RefinanceScenario{} = scenario} =
               Loans.create_refinance_scenario_from_rate_observation(
                 user,
                 mortgage,
                 observation
               )

      assert scenario.name == "30-year benchmark at 6.13%"
      assert scenario.scenario_type == "rate_observation"
      assert scenario.rate_source_type == "manual"
      assert scenario.new_term_months == 360
      assert D.equal?(scenario.new_interest_rate, D.new("0.06125"))
      assert D.equal?(scenario.new_principal_amount, D.new("375000.00"))
    end

    test "imports configured benchmark observations through the rate import worker" do
      assert {:ok, %RateSource{} = source} =
               Loans.create_rate_source(%{
                 provider_key: "configured-benchmark",
                 name: "Configured Benchmark",
                 source_type: "public_benchmark",
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
                     },
                     %{
                       "loan_type" => "mortgage",
                       "product_type" => "fixed",
                       "term_months" => 180,
                       "rate" => "0.0525",
                       "apr" => "0.0530",
                       "series_key" => "15-year-fixed"
                     }
                   ]
                 }
               })

      assert {:ok, _job} = Loans.enqueue_rate_import(source)

      assert [
               %RateObservation{term_months: 360, rate: rate_30},
               %RateObservation{term_months: 180, rate: rate_15}
             ] =
               Loans.list_rate_observations(
                 rate_source_id: source.id,
                 loan_type: "mortgage"
               )
               |> Enum.sort_by(& &1.term_months, :desc)

      assert D.equal?(rate_30, D.new("0.0600"))
      assert D.equal?(rate_15, D.new("0.0525"))

      assert {:ok, updated_source} = Loans.fetch_rate_source(source.id)
      assert updated_source.last_success_at
      refute updated_source.last_error_at
      refute updated_source.last_error_message
    end

    test "creates configured public benchmark source for deterministic imports" do
      assert {:ok, %RateSource{} = source} =
               Loans.get_or_create_public_benchmark_rate_source(%{
                 provider_key: "public-test-benchmark",
                 name: "Public Test Benchmark",
                 config: %{
                   "observations" => [
                     %{
                       "loan_type" => "mortgage",
                       "product_type" => "fixed",
                       "term_months" => 360,
                       "rate" => "0.0600"
                     }
                   ]
                 }
               })

      assert source.provider_key == "public-test-benchmark"
      assert source.name == "Public Test Benchmark"
      assert source.source_type == "public_benchmark"
      assert source.enabled
      refute source.requires_api_key

      source_id = source.id

      assert {:ok, %RateSource{id: ^source_id}} =
               Loans.get_or_create_public_benchmark_rate_source(%{
                 provider_key: "public-test-benchmark",
                 name: "Ignored Name"
               })
    end
  end
end
