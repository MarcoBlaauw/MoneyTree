defmodule MoneyTree.Transactions.TransferMatcher do
  @moduledoc """
  Deterministic transfer matching rules for internal account movements.
  """

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Transactions.Transaction

  @default_date_window_days 5
  @credit_card_window_days 7

  @spec suggest_pair(Transaction.t(), Account.t(), Transaction.t(), Account.t(), keyword()) ::
          {:ok, map()} | :no_match
  def suggest_pair(
        %Transaction{} = outflow,
        %Account{} = outflow_account,
        %Transaction{} = inflow,
        %Account{} = inflow_account,
        opts \\ []
      ) do
    with true <- opposite_signs?(outflow.amount, inflow.amount),
         true <- different_accounts?(outflow, inflow),
         {:ok, amount_difference} <- amount_difference(outflow.amount, inflow.amount),
         {:ok, date_difference_days} <- date_difference_days(outflow.posted_at, inflow.posted_at),
         {:ok, match_type, confidence, reason} <-
           classify_match(
             outflow,
             outflow_account,
             inflow,
             inflow_account,
             amount_difference,
             date_difference_days,
             opts
           ) do
      {:ok,
       %{
         outflow_transaction_id: outflow.id,
         inflow_transaction_id: inflow.id,
         match_type: match_type,
         status: "suggested",
         confidence_score: confidence,
         matched_by: "system",
         match_reason: reason,
         amount_difference: amount_difference,
         date_difference_days: date_difference_days
       }}
    else
      _ -> :no_match
    end
  end

  defp classify_match(
         outflow,
         outflow_account,
         inflow,
         inflow_account,
         amount_difference,
         date_difference_days,
         opts
       ) do
    default_window_days = Keyword.get(opts, :date_window_days, @default_date_window_days)

    outflow_kind = account_kind(outflow_account)
    inflow_kind = account_kind(inflow_account)
    text = normalized_text(outflow, inflow)

    cond do
      outflow_kind == "checking" and inflow_kind == "savings" and
        amount_difference_zero?(amount_difference) and
        date_difference_days <= default_window_days and
          transfer_text?(text) ->
        {:ok, "checking_to_savings", Decimal.new("0.97"), "checking to savings transfer pattern"}

      outflow_kind == "checking" and inflow_kind == "credit_card" and
        amount_difference_zero?(amount_difference) and
        date_difference_days <= @credit_card_window_days and
          card_payment_text?(text) ->
        {:ok, "checking_to_credit_card", Decimal.new("0.98"),
         "checking to credit card payment pattern"}

      outflow_kind == "checking" and inflow_kind in ["loan", "mortgage"] and
        amount_difference_zero?(amount_difference) and
          date_difference_days <= @credit_card_window_days ->
        {:ok, "checking_to_loan", Decimal.new("0.90"), "checking to loan payment pattern"}

      amount_difference_zero?(amount_difference) and date_difference_days <= default_window_days and
          transfer_text?(text) ->
        {:ok, "peer_transfer", Decimal.new("0.75"), "generic transfer pattern"}

      true ->
        :no_match
    end
  end

  defp account_kind(%Account{} = account) do
    normalized(account.internal_account_kind) ||
      infer_kind_from_type(account.type, account.subtype)
  end

  defp infer_kind_from_type(type, subtype) do
    type = normalized(type) || ""
    subtype = normalized(subtype) || ""

    cond do
      type in ["credit", "card", "credit_card"] or
          subtype in ["credit", "credit_card", "charge_card"] ->
        "credit_card"

      String.contains?(type, "loan") or String.contains?(subtype, "loan") ->
        "loan"

      subtype in ["mortgage"] ->
        "mortgage"

      subtype in ["savings", "money_market"] ->
        "savings"

      subtype in ["checking"] ->
        "checking"

      type in ["depository"] ->
        "checking"

      type in ["cash"] ->
        "cash"

      type in ["investment", "brokerage", "retirement"] ->
        "investment"

      true ->
        "other"
    end
  end

  defp opposite_signs?(left, right) do
    with {:ok, left} <- cast_decimal(left),
         {:ok, right} <- cast_decimal(right) do
      Decimal.compare(left, Decimal.new("0")) == :lt and
        Decimal.compare(right, Decimal.new("0")) == :gt
    else
      _ -> false
    end
  end

  defp amount_difference(left, right) do
    with {:ok, left} <- cast_decimal(left),
         {:ok, right} <- cast_decimal(right) do
      {:ok,
       Decimal.sub(Decimal.abs(left), Decimal.abs(right)) |> Decimal.abs() |> Decimal.round(2)}
    end
  end

  defp amount_difference_zero?(%Decimal{} = amount_difference) do
    Decimal.compare(amount_difference, Decimal.new("0.00")) == :eq
  end

  defp date_difference_days(%DateTime{} = outflow_date, %DateTime{} = inflow_date) do
    outflow = DateTime.to_date(outflow_date)
    inflow = DateTime.to_date(inflow_date)
    {:ok, abs(Date.diff(outflow, inflow))}
  end

  defp date_difference_days(_, _), do: {:error, :missing_date}

  defp different_accounts?(%Transaction{account_id: left}, %Transaction{account_id: right}),
    do: is_binary(left) and is_binary(right) and left != right

  defp normalized_text(outflow, inflow) do
    [
      outflow.description,
      outflow.original_description,
      outflow.merchant_name,
      inflow.description,
      inflow.original_description,
      inflow.merchant_name
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> normalized()
    |> Kernel.||("")
  end

  defp transfer_text?(text) do
    Enum.any?(
      ~w(transfer ach external_transfer from_checking to_savings savings ally),
      &String.contains?(text, &1)
    )
  end

  defp card_payment_text?(text) do
    Enum.any?(
      ~w(payment autopay credit_card amex chase discover visa mastercard),
      &String.contains?(text, &1)
    )
  end

  defp cast_decimal(%Decimal{} = decimal), do: {:ok, decimal}

  defp cast_decimal(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> {:ok, decimal}
      :error -> {:error, :invalid_decimal}
    end
  end

  defp normalized(nil), do: nil

  defp normalized(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  defp normalized(value) when is_atom(value), do: normalized(Atom.to_string(value))
  defp normalized(_value), do: nil
end
