defmodule MoneyTree.Loans.FeePredictionEngine do
  @moduledoc """
  Deterministic low/expected/high loan fee prediction.
  """

  alias Decimal, as: D
  alias MoneyTree.Loans.LoanFeeJurisdictionProfile
  alias MoneyTree.Loans.LoanFeeJurisdictionRule
  alias MoneyTree.Loans.LoanFeeType
  alias MoneyTree.Loans.RefinanceScenario
  alias MoneyTree.Mortgages.EscrowProfile

  @zero D.new("0")

  @spec predict_closing_cost_range(RefinanceScenario.t(), keyword()) :: map()
  def predict_closing_cost_range(%RefinanceScenario{} = scenario, opts) do
    fee_types = Keyword.fetch!(opts, :fee_types)
    profile = Keyword.get(opts, :profile)
    rules = Keyword.get(opts, :rules, [])
    escrow_profile = Keyword.get(opts, :escrow_profile)
    county_or_parish = Keyword.get(opts, :county_or_parish)

    rows =
      fee_types
      |> Enum.map(&prediction_row(&1, rule_for(&1, rules), scenario, escrow_profile))
      |> Enum.reject(&zero_row?/1)

    true_rows = Enum.filter(rows, &(&1.fee_type.is_true_cost and not &1.fee_type.is_timing_cost))
    timing_rows = Enum.filter(rows, & &1.fee_type.is_timing_cost)
    offset_rows = Enum.filter(rows, & &1.fee_type.is_offset)

    true_cost = sum_ranges(true_rows)
    timing_cost = sum_ranges(timing_rows)
    offsets = sum_ranges(offset_rows)
    total_closing = true_cost |> add_range(timing_cost) |> subtract_range(offsets)
    cash_to_close = total_closing

    warnings = warnings(rows, profile, escrow_profile, county_or_parish)

    %{
      total_closing_cost: total_closing,
      true_cost: subtract_range(true_cost, offset_true_cost_range(offset_rows)),
      cash_to_close: cash_to_close,
      timing_cost: timing_cost,
      offsets: offsets,
      confidence_level: confidence_level(profile, rows),
      confidence_score: confidence_score(profile, rows),
      profile: profile,
      fee_items: Enum.map(rows, &fee_item_attrs/1),
      rows: rows,
      missing_fee_codes: missing_required_fee_codes(rows, fee_types),
      warnings: warnings
    }
  end

  defp prediction_row(%LoanFeeType{} = fee_type, rule, scenario, escrow_profile) do
    effective = effective_fee(fee_type, rule)
    range = amount_range(effective, scenario, escrow_profile)

    %{
      fee_type: fee_type,
      rule: rule,
      amount_range: range,
      confidence_level: confidence_level_from(effective, fee_type),
      requires_local_verification: effective.requires_local_verification || false
    }
  end

  defp effective_fee(fee_type, nil), do: fee_type

  defp effective_fee(fee_type, %LoanFeeJurisdictionRule{} = rule) do
    overrides =
      [:amount_calculation_method, :fixed_low_amount, :fixed_expected_amount, :fixed_high_amount]
      |> Enum.concat([:percent_low, :percent_expected, :percent_high])
      |> Enum.concat([:minimum_amount, :maximum_amount, :requires_local_verification])
      |> Enum.reduce(%{}, fn key, acc ->
        case Map.get(rule, key) do
          nil -> acc
          value -> Map.put(acc, key, value)
        end
      end)

    Map.merge(fee_type, overrides)
  end

  defp amount_range(%{code: "discount_points"} = fee, %RefinanceScenario{} = scenario, _escrow) do
    points = scenario.points || @zero
    percent = D.div(points, D.new("100"))
    amount = D.mult(scenario.new_principal_amount, percent) |> D.round(2)

    if D.compare(amount, @zero) == :gt do
      range(amount, amount, amount)
    else
      default_amount_range(fee, scenario)
    end
  end

  defp amount_range(%{code: "lender_credit"}, %RefinanceScenario{} = scenario, _escrow) do
    amount = scenario.lender_credit_amount || @zero
    range(amount, amount, amount)
  end

  defp amount_range(%{code: "old_escrow_refund"}, _scenario, %EscrowProfile{} = escrow) do
    amount = escrow.expected_old_escrow_refund || @zero
    range(amount, amount, amount)
  end

  defp amount_range(%{amount_calculation_method: "computed_prepaid_interest"}, scenario, _escrow) do
    case scenario.closing_date_assumption do
      %Date{} = date ->
        days = max(1, Date.days_in_month(date) - date.day + 1)

        scenario.new_principal_amount
        |> D.mult(scenario.new_interest_rate)
        |> D.div(D.new("365"))
        |> D.mult(D.new(days))
        |> D.round(2)
        |> then(&range(&1, &1, &1))

      _value ->
        range(@zero, @zero, @zero)
    end
  end

  defp amount_range(%{amount_calculation_method: "computed_escrow_deposit"}, _scenario, escrow) do
    case escrow do
      %EscrowProfile{} ->
        monthly =
          [
            escrow.property_tax_monthly,
            escrow.homeowners_insurance_monthly,
            escrow.flood_insurance_monthly,
            escrow.other_escrow_monthly
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.reduce(@zero, &D.add/2)

        months = escrow.escrow_cushion_months || D.new("2")
        expected = monthly |> D.mult(months) |> D.round(2)
        range(@zero, expected, D.mult(expected, D.new("1.5")) |> D.round(2))

      _value ->
        range(@zero, @zero, @zero)
    end
  end

  defp amount_range(fee, scenario, _escrow), do: default_amount_range(fee, scenario)

  defp default_amount_range(%{amount_calculation_method: "fixed_amount"} = fee, _scenario) do
    range(fee.fixed_low_amount, fee.fixed_expected_amount, fee.fixed_high_amount)
    |> apply_bounds(fee)
  end

  defp default_amount_range(
         %{amount_calculation_method: "percent_of_loan_amount"} = fee,
         scenario
       ) do
    range(
      percent_amount(scenario.new_principal_amount, fee.percent_low),
      percent_amount(scenario.new_principal_amount, fee.percent_expected),
      percent_amount(scenario.new_principal_amount, fee.percent_high)
    )
    |> apply_bounds(fee)
  end

  defp default_amount_range(%{amount_calculation_method: "fixed_plus_percent"} = fee, scenario) do
    fixed = range(fee.fixed_low_amount, fee.fixed_expected_amount, fee.fixed_high_amount)

    percent =
      range(
        percent_amount(scenario.new_principal_amount, fee.percent_low),
        percent_amount(scenario.new_principal_amount, fee.percent_expected),
        percent_amount(scenario.new_principal_amount, fee.percent_high)
      )

    fixed |> add_range(percent) |> apply_bounds(fee)
  end

  defp default_amount_range(
         %{amount_calculation_method: "louisiana_title_insurance_refinance"},
         scenario
       ) do
    standard_premium = louisiana_lender_title_policy_premium(scenario.new_principal_amount)
    reissue_premium = D.mult(standard_premium, D.new("0.40")) |> D.round(2)

    range(reissue_premium, reissue_premium, standard_premium)
  end

  defp default_amount_range(_fee, _scenario), do: range(@zero, @zero, @zero)

  defp louisiana_lender_title_policy_premium(amount) do
    amount
    |> rounded_thousands()
    |> louisiana_title_premium_for_thousands()
    |> D.round(2)
  end

  defp rounded_thousands(amount) do
    amount
    |> D.div(D.new("1000"))
    |> D.round(0, :ceiling)
    |> D.to_integer()
  end

  defp louisiana_title_premium_for_thousands(thousands) when thousands <= 0, do: @zero

  defp louisiana_title_premium_for_thousands(thousands) do
    [
      {12, "100.00"},
      {50, "4.20"},
      {100, "3.60"},
      {500, "3.30"},
      {1_000, "2.70"},
      {2_000, "2.40"},
      {5_000, "2.10"},
      {10_000, "1.80"},
      {15_000, "1.50"},
      {:infinity, "1.20"}
    ]
    |> Enum.reduce_while({thousands, 0, @zero}, fn
      {_limit, _rate}, {remaining, _previous_limit, total} when remaining <= 0 ->
        {:halt, {remaining, nil, total}}

      {:infinity, rate}, {remaining, _previous_limit, total} ->
        {:halt, {0, nil, D.add(total, D.mult(D.new(remaining), D.new(rate)))}}

      {limit, rate}, {remaining, previous_limit, total} ->
        band_size = min(remaining, limit - previous_limit)
        band_total = D.mult(D.new(band_size), D.new(rate))
        {:cont, {remaining - band_size, limit, D.add(total, band_total)}}
    end)
    |> elem(2)
  end

  defp fee_item_attrs(%{
         fee_type: fee_type,
         amount_range: amount_range,
         confidence_level: confidence
       }) do
    %{
      "category" => fee_type.code,
      "code" => fee_type.code,
      "name" => fee_type.display_name,
      "low_amount" => amount_range.low,
      "expected_amount" => amount_range.expected,
      "high_amount" => amount_range.high,
      "kind" => fee_item_kind(fee_type),
      "paid_at_closing" => true,
      "financed" => false,
      "is_true_cost" => fee_type.is_true_cost,
      "is_prepaid_or_escrow" => fee_type.is_timing_cost,
      "required" => fee_type.is_required,
      "sort_order" => fee_type.sort_order,
      "notes" => "Generated #{confidence} confidence MoneyTree estimate. Editable by the user."
    }
  end

  defp fee_item_kind(%LoanFeeType{is_offset: true, code: "old_escrow_refund"}),
    do: "escrow_refund"

  defp fee_item_kind(%LoanFeeType{is_offset: true}), do: "lender_credit"
  defp fee_item_kind(%LoanFeeType{is_timing_cost: true}), do: "timing_cost"
  defp fee_item_kind(_fee_type), do: "fee"

  defp missing_required_fee_codes(rows, fee_types) do
    present_codes = MapSet.new(rows, & &1.fee_type.code)

    fee_types
    |> Enum.filter(& &1.is_required)
    |> Enum.reject(&MapSet.member?(present_codes, &1.code))
    |> Enum.map(& &1.code)
  end

  defp warnings(rows, profile, escrow_profile, county_or_parish) do
    []
    |> maybe_add(profile == nil, "Using generic national fee assumptions.")
    |> maybe_add(
      profile && profile.confidence_level in ["very_low", "low"],
      "Modeled fee range has low confidence."
    )
    |> maybe_add(escrow_profile == nil, "Escrow and prepaid timing data is incomplete.")
    |> maybe_add(
      Enum.any?(rows, & &1.requires_local_verification),
      "Some state or local fee assumptions require verification."
    )
    |> maybe_add(
      louisiana_profile?(profile) && is_nil(county_or_parish),
      "Louisiana recording and local tax assumptions can vary by parish. MoneyTree is using a statewide estimate until the parish is known."
    )
    |> maybe_add(
      louisiana_profile?(profile) && profile.county_or_parish == "Orleans",
      "Orleans Parish documentary transaction tax has been included because the property is located in Orleans Parish."
    )
    |> maybe_add(
      louisiana_profile?(profile) && county_or_parish not in [nil, "Orleans"] &&
        profile.confidence_level != "high",
      "Parish-specific recording fees should be verified."
    )
    |> maybe_add(
      louisiana_profile?(profile) &&
        Enum.any?(rows, &(&1.fee_type.code == "title_insurance_lender_policy")),
      "Louisiana title insurance is modeled from the reported filed-rate tiers. Confirm refinance/reissue eligibility with the lender or title company."
    )
    |> maybe_add(
      louisiana_profile?(profile),
      "MoneyTree did not apply a statewide percentage-based Louisiana mortgage tax. Parish-specific taxes or transaction fees may still apply."
    )
    |> Enum.reverse()
  end

  defp maybe_add(acc, true, message), do: [message | acc]
  defp maybe_add(acc, _condition, _message), do: acc

  defp louisiana_profile?(%LoanFeeJurisdictionProfile{state_code: "LA"}), do: true
  defp louisiana_profile?(_profile), do: false

  defp confidence_level(%LoanFeeJurisdictionProfile{confidence_level: level}, _rows), do: level
  defp confidence_level(_profile, _rows), do: "low"

  defp confidence_score(%LoanFeeJurisdictionProfile{confidence_score: %D{} = score}, _rows),
    do: score

  defp confidence_score(%LoanFeeJurisdictionProfile{confidence_level: "moderate"}, _rows),
    do: D.new("0.55")

  defp confidence_score(_profile, _rows), do: D.new("0.35")

  defp confidence_level_from(%{confidence_level: level}, _fee_type) when is_binary(level),
    do: level

  defp confidence_level_from(_effective, fee_type), do: fee_type.confidence_level

  defp rule_for(fee_type, rules) do
    Enum.find(rules, &(&1.loan_fee_type_id == fee_type.id))
  end

  defp zero_row?(%{
         fee_type: %{amount_calculation_method: "manual_only"},
         amount_range: amount_range
       }) do
    zero_range?(amount_range)
  end

  defp zero_row?(%{fee_type: %{is_required: false}, amount_range: amount_range}) do
    zero_range?(amount_range)
  end

  defp zero_row?(_row), do: false

  defp zero_range?(range) do
    D.compare(range.low, @zero) == :eq and D.compare(range.expected, @zero) == :eq and
      D.compare(range.high, @zero) == :eq
  end

  defp percent_amount(_amount, nil), do: @zero
  defp percent_amount(amount, percent), do: amount |> D.mult(percent) |> D.round(2)

  defp range(low, expected, high) do
    %{
      low: normalize_decimal(low),
      expected: normalize_decimal(expected),
      high: normalize_decimal(high)
    }
  end

  defp sum_ranges(rows) do
    Enum.reduce(rows, range(@zero, @zero, @zero), fn row, acc ->
      add_range(acc, row.amount_range)
    end)
  end

  defp add_range(left, right) do
    range(
      D.add(left.low, right.low),
      D.add(left.expected, right.expected),
      D.add(left.high, right.high)
    )
  end

  defp subtract_range(left, right) do
    range(
      max_decimal(D.sub(left.low, right.low), @zero),
      max_decimal(D.sub(left.expected, right.expected), @zero),
      max_decimal(D.sub(left.high, right.high), @zero)
    )
  end

  defp offset_true_cost_range(rows) do
    rows
    |> Enum.filter(& &1.fee_type.is_true_cost)
    |> sum_ranges()
  end

  defp apply_bounds(range, fee) do
    range
    |> apply_min(fee.minimum_amount)
    |> apply_max(fee.maximum_amount)
  end

  defp apply_min(range, nil), do: range

  defp apply_min(range, min),
    do: %{
      low: max_decimal(range.low, min),
      expected: max_decimal(range.expected, min),
      high: max_decimal(range.high, min)
    }

  defp apply_max(range, nil), do: range

  defp apply_max(range, max),
    do: %{
      low: min_decimal(range.low, max),
      expected: min_decimal(range.expected, max),
      high: min_decimal(range.high, max)
    }

  defp max_decimal(left, right), do: if(D.compare(left, right) == :lt, do: right, else: left)
  defp min_decimal(left, right), do: if(D.compare(left, right) == :gt, do: right, else: left)

  defp normalize_decimal(nil), do: @zero
  defp normalize_decimal(%D{} = decimal), do: D.round(decimal, 2)

  defp normalize_decimal(value) do
    case D.cast(value) do
      {:ok, decimal} -> D.round(decimal, 2)
      :error -> @zero
    end
  end
end
