defmodule MoneyTree.Loans.RateProviders.FredTest do
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias MoneyTree.Loans.RateProviders.Fred

  describe "configuration" do
    test "requires an API key" do
      refute Fred.configured?(%{})
      refute Fred.configured?(%{api_key: ""})
      assert Fred.configured?(%{api_key: "abc123"})
    end

    test "uses default source metadata when base URL is blank" do
      attrs = Fred.default_source_attrs(%{base_url: ""})

      assert attrs.base_url == "https://api.stlouisfed.org/fred"
      assert attrs.update_frequency == "daily"
      assert attrs.reliability_score == "0.9500"
    end
  end

  describe "normalization" do
    test "normalizes FRED mortgage observations into rate attrs" do
      assert {:ok, [rate]} =
               Fred.normalize_response("MORTGAGE30US", %{
                 "observations" => [
                   %{"date" => "2026-05-07", "value" => "6.50", "realtime_start" => "2026-05-08"}
                 ]
               })

      assert rate.series_key == "MORTGAGE30US"
      assert rate.loan_type == "mortgage"
      assert rate.product_type == "fixed"
      assert rate.term_months == 360
      assert rate.effective_date == ~D[2026-05-07]
      assert D.equal?(rate.rate, D.new("0.065"))
      assert rate.assumptions["not_personalized_offer"]
      assert rate.source_url == "https://fred.stlouisfed.org/series/MORTGAGE30US"
    end

    test "skips missing FRED values" do
      assert {:ok, []} =
               Fred.normalize_response("MORTGAGE15US", %{
                 "observations" => [%{"date" => "2026-05-07", "value" => "."}]
               })
    end
  end
end
