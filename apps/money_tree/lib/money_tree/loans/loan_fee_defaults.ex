defmodule MoneyTree.Loans.LoanFeeDefaults do
  @moduledoc false

  def fee_types do
    mortgage_refinance_fee_types() ++ generic_loan_fee_types()
  end

  def jurisdiction_profiles do
    base_profiles = [
      %{
        country_code: "US",
        loan_type: "mortgage",
        transaction_type: "refinance",
        confidence_level: "low",
        confidence_score: "0.3500",
        source_label: "MoneyTree generic national model",
        notes: "Generic national assumptions. Not a lender quote.",
        enabled: true
      },
      %{
        country_code: "US",
        state_code: "LA",
        loan_type: "mortgage",
        transaction_type: "refinance",
        confidence_level: "moderate",
        confidence_score: "0.5500",
        source_label: "Louisiana v1 statewide fee verification",
        notes:
          "Louisiana v1 statewide profile. Uses statewide recorder fee schedule and generic title/settlement assumptions. Parish-specific fees still required.",
        enabled: true
      },
      %{
        country_code: "US",
        state_code: "LA",
        county_or_parish: "Orleans",
        loan_type: "mortgage",
        transaction_type: "refinance",
        confidence_level: "high",
        confidence_score: "0.7500",
        source_label: "Orleans Parish documentary transaction tax verification",
        notes:
          "Orleans Parish v1 profile. Uses official Orleans land-record fee schedules checked May 2026 and includes the Orleans documentary transaction tax for normal residential refinance amounts over $9,000.",
        enabled: true
      }
    ]

    base_profiles ++ louisiana_parish_profile_shells()
  end

  def jurisdiction_rules do
    [
      {"US", "LA", "mortgage", "refinance", "origination_fee",
       %{percent_low: "0.000000", percent_expected: "0.007500", percent_high: "0.015000"}},
      {"US", "LA", "mortgage", "refinance", "title_insurance_lender_policy",
       %{
         amount_calculation_method: "louisiana_title_insurance_refinance",
         requires_local_verification: true,
         source_label: "Louisiana title insurance rate manual",
         notes:
           "Louisiana lender title policy estimate uses the filed title-rate tier schedule reported effective August 2024. Low and expected assume the refinance/reissue credit; high uses the standard premium until prior title-policy eligibility is confirmed."
       }},
      {"US", "LA", "mortgage", "refinance", "recording_fee",
       %{
         fixed_low_amount: "105.00",
         fixed_expected_amount: "205.00",
         fixed_high_amount: "305.00",
         requires_local_verification: true,
         source_label: "LA R.S. 13:844 + LCRAA/parish practice",
         notes:
           "Louisiana recording estimate uses statewide recorder fee tiers plus common LCRAA/parish practice. Parish-specific recording/tax check needed."
       }},
      {"US", "LA", "mortgage", "refinance", "release_fee",
       %{
         fixed_low_amount: "55.00",
         fixed_expected_amount: "55.00",
         fixed_high_amount: "105.00",
         requires_local_verification: true,
         source_label: "LA R.S. 13:844 + LCRAA/parish practice",
         notes:
           "Louisiana mortgage cancellation/release estimate. Modeled as likely payoff/release-related government recording cost."
       }},
      {"US", "LA", "mortgage", "refinance", "attorney_or_notary_fee",
       %{
         fixed_low_amount: "250.00",
         fixed_expected_amount: "500.00",
         fixed_high_amount: "1000.00",
         notes:
           "Louisiana civil-law notary and local closing customs support a non-zero document/notary expectation."
       }},
      {la_parish_profile("St. Charles"), "recording_fee",
       %{
         fixed_low_amount: "105.00",
         fixed_expected_amount: "205.00",
         fixed_high_amount: "305.00",
         requires_local_verification: true,
         source_label: "St. Charles Parish Clerk fee schedule via deeds.com",
         notes:
           "St. Charles Parish recording schedule checked May 2026: $105 / $205 / $305 page-tier model, including standard LCRAA practice. Direct clerk verification is still recommended."
       }},
      {la_parish_profile("Jefferson"), "recording_fee",
       %{
         fixed_low_amount: "105.00",
         fixed_expected_amount: "205.00",
         fixed_high_amount: "305.00",
         requires_local_verification: true,
         source_label: "Jefferson Parish Clerk fee schedule via deeds.com",
         notes:
           "Jefferson Parish recording schedule checked May 2026: $105 / $205 / $305 page-tier model. Cancellation fee still needs direct clerk confirmation."
       }},
      {la_parish_profile("St. John the Baptist"), "recording_fee",
       %{
         fixed_low_amount: "105.00",
         fixed_expected_amount: "205.00",
         fixed_high_amount: "305.00",
         requires_local_verification: true,
         source_label: "St. John the Baptist Parish Clerk fee schedule via deeds.com",
         notes:
           "St. John the Baptist Parish recording schedule checked May 2026: $105 / $205 / $305 page-tier model."
       }},
      {la_parish_profile("St. John the Baptist"), "release_fee",
       %{
         fixed_low_amount: "15.00",
         fixed_expected_amount: "15.00",
         fixed_high_amount: "40.00",
         requires_local_verification: true,
         source_label: "St. John the Baptist Parish Clerk fee schedule via deeds.com",
         notes:
           "St. John the Baptist cancellation with original note is reported at $15; high includes related cancellation/clear-lien certificate room."
       }},
      {la_parish_profile("St. Tammany"), "recording_fee",
       %{
         fixed_low_amount: "110.00",
         fixed_expected_amount: "210.00",
         fixed_high_amount: "310.00",
         requires_local_verification: false,
         source_label: "St. Tammany Parish Clerk fee sheet",
         notes:
           "St. Tammany Parish official fee sheet checked May 2026: $110 / $210 / $310 recording tiers, including LCRAA and parish council fees."
       }},
      {la_parish_profile("St. Tammany"), "release_fee",
       %{
         fixed_low_amount: "60.00",
         fixed_expected_amount: "60.00",
         fixed_high_amount: "60.00",
         requires_local_verification: false,
         source_label: "St. Tammany Parish Clerk fee sheet",
         notes: "St. Tammany Parish single mortgage release reported at $60."
       }},
      {la_parish_profile("East Baton Rouge"), "recording_fee",
       %{
         fixed_low_amount: "135.00",
         fixed_expected_amount: "235.00",
         fixed_high_amount: "335.00",
         requires_local_verification: false,
         source_label: "East Baton Rouge Clerk fee schedule",
         notes:
           "East Baton Rouge mortgage-recording schedule checked May 2026: $135 / $235 / $335 page-tier model including judicial building fund."
       }},
      {la_parish_profile("East Baton Rouge"), "release_fee",
       %{
         fixed_low_amount: "85.00",
         fixed_expected_amount: "85.00",
         fixed_high_amount: "85.00",
         requires_local_verification: false,
         source_label: "East Baton Rouge Clerk fee schedule",
         notes: "East Baton Rouge mortgage or lien cancellation reported at $85."
       }},
      {la_parish_profile("Orleans"), "recording_fee",
       %{
         fixed_low_amount: "130.00",
         fixed_expected_amount: "230.00",
         fixed_high_amount: "330.00",
         requires_local_verification: false,
         source_label: "Orleans Civil District Court land records fee schedule",
         notes:
           "Orleans Parish recording schedule checked May 2026: $100 / $200 / $300 recording tiers plus reported $30 building fund fee."
       }},
      {la_parish_profile("Orleans"), "release_fee",
       %{
         fixed_low_amount: "50.00",
         fixed_expected_amount: "50.00",
         fixed_high_amount: "60.00",
         requires_local_verification: false,
         source_label: "Orleans Civil District Court land records fee schedule",
         notes:
           "Orleans Parish single-mortgage cancellation reported at $50, with lower original-note handling noted separately in the clerk schedule."
       }},
      {la_parish_profile("Orleans"), "orleans_documentary_transaction_tax",
       %{
         fixed_low_amount: "325.00",
         fixed_expected_amount: "325.00",
         fixed_high_amount: "325.00",
         requires_local_verification: false,
         source_label:
           "Orleans Civil Clerk / Notarial Archives documentary transaction tax guidance",
         notes:
           "Orleans Parish documentary transaction tax included for normal residential refinance amounts over $9,000."
       }}
    ]
  end

  defp mortgage_refinance_fee_types do
    [
      %{
        code: "origination_fee",
        display_name: "Origination fee",
        aliases: ["origination fee", "loan origination", "lender origination charge"],
        trid_section: "origination_charges",
        tolerance_bucket: "zero_tolerance",
        finance_charge_treatment: "included",
        apr_affecting: true,
        points_and_fees_included: true,
        is_lender_controlled: true,
        credit_score_sensitive: true,
        amount_calculation_method: "percent_of_loan_amount",
        percent_low: "0.000000",
        percent_expected: "0.005000",
        percent_high: "0.010000",
        warning_high_threshold_percent: "0.020000",
        extreme_high_threshold_percent: "0.030000",
        is_required: false,
        confidence_level: "low",
        sort_order: 10
      },
      %{
        code: "discount_points",
        display_name: "Discount points",
        aliases: ["points", "discount points"],
        trid_section: "origination_charges",
        finance_charge_treatment: "included",
        apr_affecting: true,
        points_and_fees_included: true,
        credit_score_sensitive: true,
        amount_calculation_method: "manual_only",
        is_required: false,
        confidence_level: "low",
        sort_order: 20
      },
      fixed("appraisal_fee", "Appraisal fee", ["appraisal", "appraisal fee"], 400, 650, 900, 30,
        trid_section: "services_cannot_shop_for",
        is_third_party: true,
        is_required: true
      ),
      fixed(
        "credit_report_fee",
        "Credit report fee",
        ["credit report", "credit report fee"],
        25,
        50,
        100,
        40,
        trid_section: "services_cannot_shop_for",
        is_third_party: true,
        is_required: true
      ),
      fixed(
        "flood_certification_fee",
        "Flood certification",
        ["flood certification", "flood cert"],
        10,
        20,
        40,
        50,
        trid_section: "services_cannot_shop_for",
        is_third_party: true,
        is_required: true
      ),
      fixed("title_search_fee", "Title search", ["title search", "title exam"], 150, 300, 600, 60,
        trid_section: "services_can_shop_for",
        tolerance_bucket: "ten_percent_aggregate",
        is_third_party: true,
        is_required: true
      ),
      %{
        code: "title_insurance_lender_policy",
        display_name: "Title insurance lender policy",
        aliases: ["title insurance", "lender title policy", "lenders title insurance"],
        trid_section: "services_can_shop_for",
        tolerance_bucket: "ten_percent_aggregate",
        finance_charge_treatment: "excluded",
        is_true_cost: true,
        is_third_party: true,
        is_required: true,
        is_state_localized: true,
        requires_local_verification: true,
        amount_calculation_method: "percent_of_loan_amount",
        percent_low: "0.002000",
        percent_expected: "0.004000",
        percent_high: "0.008000",
        confidence_level: "low",
        sort_order: 70
      },
      fixed(
        "settlement_or_closing_fee",
        "Settlement or closing fee",
        ["settlement fee", "closing fee", "escrow fee"],
        300,
        600,
        1200,
        80,
        trid_section: "services_can_shop_for",
        tolerance_bucket: "ten_percent_aggregate",
        is_third_party: true,
        is_required: true
      ),
      fixed(
        "recording_fee",
        "Recording fee",
        ["recording fee", "government recording"],
        50,
        150,
        400,
        90,
        trid_section: "taxes_and_government_fees",
        tolerance_bucket: "ten_percent_aggregate",
        is_government_fee: true,
        is_state_localized: true,
        requires_local_verification: true,
        is_required: true
      ),
      fixed(
        "orleans_documentary_transaction_tax",
        "Orleans documentary transaction tax",
        ["documentary transaction tax", "orleans documentary tax", "new orleans documentary tax"],
        0,
        0,
        0,
        95,
        trid_section: "taxes_and_government_fees",
        tolerance_bucket: "ten_percent_aggregate",
        is_government_fee: true,
        is_state_localized: true,
        is_required: false,
        confidence_level: "high"
      ),
      fixed(
        "attorney_or_notary_fee",
        "Attorney, notary, or document fee",
        ["attorney fee", "notary fee", "document fee", "attorney or notary or document fee"],
        0,
        250,
        900,
        100,
        trid_section: "services_can_shop_for",
        tolerance_bucket: "no_limit_best_information",
        is_state_localized: true,
        is_optional: true
      ),
      fixed(
        "release_fee",
        "Mortgage cancellation or release",
        ["release fee", "payoff release", "mortgage cancellation", "cancellation fee"],
        0,
        75,
        200,
        110,
        trid_section: "payoffs_and_payments",
        is_government_fee: true
      ),
      computed(
        "prepaid_interest",
        "Prepaid interest",
        ["prepaid interest"],
        "computed_prepaid_interest",
        120,
        trid_section: "prepaids"
      ),
      computed(
        "escrow_deposit",
        "Initial escrow deposit",
        ["escrow deposit", "initial escrow"],
        "computed_escrow_deposit",
        130,
        trid_section: "initial_escrow_payment"
      ),
      offset("lender_credit", "Lender credit", ["lender credit", "credit"], 140,
        trid_section: "lender_credits",
        is_true_cost: true
      ),
      offset("old_escrow_refund", "Old escrow refund", ["escrow refund"], 150,
        trid_section: "payoffs_and_payments",
        is_timing_cost: true,
        is_true_cost: false
      )
    ]
    |> Enum.map(&Map.merge(base("mortgage", "refinance"), &1))
  end

  defp louisiana_parish_profile_shells do
    [
      {"St. Charles", "moderate", "0.5500",
       "St. Charles Parish profile. Uses parish recording fee schedule checked May 2026 through aggregated clerk data; direct clerk verification is still recommended."},
      {"Jefferson", "moderate", "0.5500",
       "Jefferson Parish profile. Uses parish recording and mortgage-certificate schedule checked May 2026 through published clerk data; cancellation fee still needs direct confirmation."},
      {"St. John the Baptist", "moderate", "0.5500",
       "St. John the Baptist Parish profile. Uses parish recording, mortgage-certificate, and cancellation schedule checked May 2026 through published clerk data."},
      {"St. Tammany", "high", "0.7000",
       "St. Tammany Parish profile. Uses official clerk fee sheet checked May 2026, including parish council recording fee."},
      {"East Baton Rouge", "high", "0.7000",
       "East Baton Rouge Parish profile. Uses official clerk fee schedule checked May 2026, including judicial building fund."}
    ]
    |> Enum.map(fn {parish, confidence_level, confidence_score, notes} ->
      %{
        country_code: "US",
        state_code: "LA",
        county_or_parish: parish,
        loan_type: "mortgage",
        transaction_type: "refinance",
        confidence_level: confidence_level,
        confidence_score: confidence_score,
        source_label: "Louisiana parish recording fee research",
        notes: notes,
        enabled: true
      }
    end)
  end

  defp la_parish_profile(county_or_parish) do
    %{
      country_code: "US",
      state_code: "LA",
      county_or_parish: county_or_parish,
      municipality: nil,
      loan_type: "mortgage",
      transaction_type: "refinance"
    }
  end

  defp generic_loan_fee_types do
    for {loan_type, sort_order} <- [{"auto", 1000}, {"personal", 1010}, {"student", 1020}] do
      base(loan_type, "refinance")
      |> Map.merge(%{
        code: "generic_processing_fee",
        display_name: "#{String.capitalize(loan_type)} processing fee",
        aliases: ["processing fee", "administration fee"],
        trid_section: "not_applicable",
        tolerance_bucket: "unknown",
        finance_charge_treatment: "unknown",
        amount_calculation_method: "fixed_amount",
        fixed_low_amount: "0.00",
        fixed_expected_amount: "0.00",
        fixed_high_amount: "250.00",
        confidence_level: "very_low",
        is_required: false,
        sort_order: sort_order,
        notes: "Sparse low-confidence placeholder pending loan-type-specific research."
      })
    end
  end

  defp base(loan_type, transaction_type) do
    %{
      loan_type: loan_type,
      transaction_type: transaction_type,
      source_label: "MoneyTree modeled fee assumptions",
      enabled: true,
      confidence_level: "low",
      amount_calculation_method: "fixed_amount",
      trid_section: "not_applicable",
      tolerance_bucket: "unknown",
      finance_charge_treatment: "unknown"
    }
  end

  defp fixed(code, name, aliases, low, expected, high, sort_order, opts) do
    %{
      code: code,
      display_name: name,
      aliases: aliases,
      amount_calculation_method: "fixed_amount",
      fixed_low_amount: money(low),
      fixed_expected_amount: money(expected),
      fixed_high_amount: money(high),
      is_true_cost: Keyword.get(opts, :is_true_cost, true),
      is_timing_cost: Keyword.get(opts, :is_timing_cost, false),
      is_offset: false,
      trid_section: Keyword.get(opts, :trid_section, "not_applicable"),
      tolerance_bucket: Keyword.get(opts, :tolerance_bucket, "unknown"),
      finance_charge_treatment: Keyword.get(opts, :finance_charge_treatment, "excluded"),
      is_required: Keyword.get(opts, :is_required, false),
      is_optional: Keyword.get(opts, :is_optional, false),
      is_third_party: Keyword.get(opts, :is_third_party, false),
      is_government_fee: Keyword.get(opts, :is_government_fee, false),
      is_state_localized: Keyword.get(opts, :is_state_localized, false),
      requires_local_verification: Keyword.get(opts, :requires_local_verification, false),
      confidence_level: Keyword.get(opts, :confidence_level, "low"),
      sort_order: sort_order
    }
  end

  defp computed(code, name, aliases, method, sort_order, opts) do
    %{
      code: code,
      display_name: name,
      aliases: aliases,
      amount_calculation_method: method,
      is_true_cost: false,
      is_timing_cost: true,
      is_offset: false,
      trid_section: Keyword.get(opts, :trid_section, "not_applicable"),
      tolerance_bucket: "no_limit_best_information",
      finance_charge_treatment: "excluded",
      sort_order: sort_order
    }
  end

  defp offset(code, name, aliases, sort_order, opts) do
    %{
      code: code,
      display_name: name,
      aliases: aliases,
      amount_calculation_method: "manual_only",
      kind: "lender_credit",
      is_true_cost: Keyword.get(opts, :is_true_cost, false),
      is_timing_cost: Keyword.get(opts, :is_timing_cost, false),
      is_offset: true,
      trid_section: Keyword.get(opts, :trid_section, "not_applicable"),
      tolerance_bucket: "not_applicable",
      finance_charge_treatment: "excluded",
      sort_order: sort_order
    }
  end

  defp money(value), do: :erlang.float_to_binary(value / 1, decimals: 2)
end
