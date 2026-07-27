defmodule MoneyTree.Loans.RateProviders.ProviderRegistryTest do
  use MoneyTree.DataCase, async: true

  alias Decimal, as: D
  alias MoneyTree.Loans
  alias MoneyTree.Loans.RateObservation

  describe "provider registry" do
    test "lists active providers and future placeholders" do
      statuses = Loans.rate_provider_statuses()

      assert %{active?: true, requires_api_key?: true} =
               Enum.find(statuses, &(&1.provider_key == "fred"))

      assert %{active?: true, requires_api_key?: false, source_type: "csv_import"} =
               Enum.find(statuses, &(&1.provider_key == "manual-supplemental"))

      assert %{active?: false, requires_api_key?: true} =
               Enum.find(statuses, &(&1.provider_key == "api-ninjas"))

      assert %{active?: false, requires_api_key?: true} =
               Enum.find(statuses, &(&1.provider_key == "economic-indicators"))
    end
  end

  describe "manual supplemental imports" do
    test "imports reviewed rows through the shared market-rate pipeline" do
      source_attrs = %{
        provider_key: "local-credit-union-survey",
        name: "Local Credit Union Survey",
        attribution_label: "Local CU rate sheet",
        attribution_url: "https://example.test/rates"
      }

      observations = [
        %{
          "loan_type" => "auto",
          "product_type" => "used_auto",
          "term_months" => 60,
          "rate" => "0.0725",
          "apr" => "0.0740",
          "series_key" => "local-cu-used-auto-60",
          "effective_date" => "2026-05-01",
          "source_url" => "https://example.test/rates",
          "notes" => "Reviewed promotional auto loan range"
        }
      ]

      assert {:ok, %{source: source, imported: [%RateObservation{} = observation]}} =
               Loans.import_manual_market_rates(source_attrs, observations)

      assert source.provider_key == "local-credit-union-survey"
      assert source.source_type == "csv_import"
      refute source.requires_api_key
      assert source.attribution_label == "Local CU rate sheet"

      assert observation.loan_type == "auto"
      assert observation.term_months == 60
      assert observation.effective_date == ~D[2026-05-01]
      assert D.equal?(observation.rate, D.new("0.0725"))
      assert observation.source_url == "https://example.test/rates"

      assert {:ok, %{imported: [_replacement]}} =
               Loans.import_manual_market_rates(source_attrs, observations)

      assert [%RateObservation{}] = Loans.historical_rates("local-cu-used-auto-60")
    end
  end
end
