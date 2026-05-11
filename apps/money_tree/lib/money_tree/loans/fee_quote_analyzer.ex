defmodule MoneyTree.Loans.FeeQuoteAnalyzer do
  @moduledoc """
  Maps lender quote fee lines to modeled fee types and classifies relative cost.
  """

  alias Decimal, as: D
  alias MoneyTree.Loans.LenderQuote
  alias MoneyTree.Loans.LoanFeeType

  @zero D.new("0")

  @spec classify_quote(LenderQuote.t(), keyword()) :: map()
  def classify_quote(%LenderQuote{} = quote, opts) do
    fee_types = Keyword.fetch!(opts, :fee_types)
    prediction = Keyword.fetch!(opts, :prediction)
    fee_lines = Keyword.get(opts, :fee_lines, fee_lines_from_quote(quote))

    classified =
      fee_lines
      |> Enum.map(&classify_fee_line(&1, fee_types, prediction))
      |> flag_duplicates()

    %{
      fee_lines: classified,
      missing_required_fees: missing_required_fees(classified, fee_types),
      warnings: warnings(classified)
    }
  end

  @spec missing_required_fees([map()] | LenderQuote.t(), keyword()) :: [map()]
  def missing_required_fees(classified_lines, fee_types) when is_list(fee_types) do
    present =
      classified_lines
      |> Enum.map(& &1[:loan_fee_type_id])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    fee_types
    |> Enum.filter(& &1.is_required)
    |> Enum.reject(&MapSet.member?(present, &1.id))
    |> Enum.map(fn fee_type ->
      %{
        loan_fee_type_id: fee_type.id,
        code: fee_type.code,
        display_name: fee_type.display_name,
        classification: "missing_required_fee",
        review_note:
          "#{fee_type.display_name} is expected for this modeled quote but was not listed."
      }
    end)
  end

  def missing_required_fees(%LenderQuote{} = quote, opts) do
    quote
    |> classify_quote(opts)
    |> Map.fetch!(:missing_required_fees)
  end

  def classify_fee_line(line, fee_types, prediction) do
    label =
      Map.get(line, :original_label) || Map.get(line, "original_label") || Map.get(line, :label) ||
        Map.get(line, "label")

    amount = Map.get(line, :amount) || Map.get(line, "amount")
    fee_type = match_fee_type(label, fee_types)
    amount = decimal(amount)
    modeled_range = modeled_range(fee_type, prediction)
    classification = classification(fee_type, amount, modeled_range)

    %{
      original_label: label,
      normalized_label: normalize_label(label),
      amount: amount,
      loan_fee_type_id: fee_type && fee_type.id,
      classification: classification,
      confidence_level: confidence_level(fee_type, classification),
      confidence_score: confidence_score(fee_type, classification),
      required: (fee_type && fee_type.is_required) || false,
      requires_review:
        classification in [
          "above_expected_range",
          "extreme_outlier",
          "unknown_fee_type",
          "possible_junk_or_unusual_fee"
        ],
      review_note: review_note(fee_type, classification, modeled_range),
      raw_payload: stringify_map(line)
    }
  end

  def fee_lines_from_quote(%LenderQuote{raw_payload: %{"fee_lines" => fee_lines}})
      when is_list(fee_lines) do
    fee_lines
  end

  def fee_lines_from_quote(%LenderQuote{} = quote) do
    if quote.estimated_closing_costs_expected do
      [
        %{
          original_label: "Estimated closing costs",
          amount: quote.estimated_closing_costs_expected
        }
      ]
    else
      []
    end
  end

  defp match_fee_type(label, fee_types) do
    normalized = normalize_label(label)

    Enum.find(fee_types, fn fee_type ->
      normalized in Enum.map(
        [fee_type.code, fee_type.display_name | fee_type.aliases],
        &normalize_label/1
      )
    end)
  end

  defp modeled_range(nil, _prediction), do: nil

  defp modeled_range(%LoanFeeType{} = fee_type, prediction) do
    prediction.rows
    |> Enum.find(&(&1.fee_type.id == fee_type.id))
    |> case do
      %{amount_range: range} -> range
      _value -> nil
    end
  end

  defp classification(nil, _amount, _range), do: "unknown_fee_type"

  defp classification(%LoanFeeType{is_optional: true}, _amount, nil),
    do: "not_required_or_optional"

  defp classification(%LoanFeeType{is_required: false, is_optional: true}, _amount, _range),
    do: "not_required_or_optional"

  defp classification(_fee_type, _amount, nil), do: "unknown_fee_type"

  defp classification(fee_type, amount, range) do
    cond do
      extreme?(fee_type, amount) ->
        "extreme_outlier"

      D.compare(amount, range.low) == :lt ->
        "below_expected_range"

      D.compare(amount, range.high) == :gt ->
        "above_expected_range"

      true ->
        "within_expected_range"
    end
  end

  defp extreme?(%LoanFeeType{extreme_high_threshold_amount: %D{} = threshold}, amount) do
    D.compare(amount, threshold) == :gt
  end

  defp extreme?(%LoanFeeType{extreme_high_threshold_percent: %D{}}, _amount), do: false
  defp extreme?(_fee_type, _amount), do: false

  defp flag_duplicates(lines) do
    duplicate_ids =
      lines
      |> Enum.map(& &1.loan_fee_type_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    Enum.map(lines, fn line ->
      if line.loan_fee_type_id && MapSet.member?(duplicate_ids, line.loan_fee_type_id) do
        %{
          line
          | classification: "possible_duplicate_fee",
            requires_review: true,
            review_note: "Multiple quote lines map to the same fee type."
        }
      else
        line
      end
    end)
  end

  defp warnings(lines) do
    []
    |> maybe_add(
      Enum.any?(lines, &(&1.classification == "unknown_fee_type")),
      "Some quoted fees could not be mapped to known fee types."
    )
    |> maybe_add(
      Enum.any?(lines, &(&1.classification == "above_expected_range")),
      "Some quoted fees are high relative to the modeled range."
    )
    |> maybe_add(
      Enum.any?(lines, &(&1.classification == "extreme_outlier")),
      "Some quoted fees are extreme outliers and require review."
    )
    |> Enum.reverse()
  end

  defp review_note(nil, _classification, _range), do: "Unknown fee type. Review recommended."

  defp review_note(_fee_type, "below_expected_range", _range),
    do: "Below MoneyTree's modeled range."

  defp review_note(_fee_type, "within_expected_range", _range),
    do: "Within MoneyTree's modeled range."

  defp review_note(_fee_type, "above_expected_range", _range),
    do: "High relative to MoneyTree's modeled range."

  defp review_note(_fee_type, "extreme_outlier", _range),
    do: "Extreme outlier relative to MoneyTree's modeled range. Review recommended."

  defp review_note(_fee_type, "not_required_or_optional", _range),
    do: "May be optional or not required for this modeled scenario."

  defp review_note(_fee_type, _classification, _range), do: "Review recommended."

  defp confidence_level(nil, _classification), do: "low"

  defp confidence_level(fee_type, "within_expected_range"),
    do: fee_type.confidence_level || "moderate"

  defp confidence_level(_fee_type, _classification), do: "low"

  defp confidence_score(nil, _classification), do: D.new("0.2500")
  defp confidence_score(_fee_type, "within_expected_range"), do: D.new("0.7000")
  defp confidence_score(_fee_type, _classification), do: D.new("0.4000")

  defp maybe_add(acc, true, message), do: [message | acc]
  defp maybe_add(acc, false, _message), do: acc

  defp normalize_label(nil), do: ""

  defp normalize_label(label) do
    label
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp decimal(%D{} = value), do: value
  defp decimal(nil), do: @zero

  defp decimal(value) do
    case D.cast(value) do
      {:ok, decimal} -> decimal
      :error -> @zero
    end
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
