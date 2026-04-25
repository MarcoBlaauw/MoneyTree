defmodule MoneyTree.Transactions.DuplicateDetector do
  @moduledoc """
  Provider-agnostic duplicate detection using exact IDs and deterministic fingerprints.
  """

  import Ecto.Query, warn: false

  alias Decimal
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Fingerprints
  alias MoneyTree.Transactions.Transaction

  @type status :: :none | :exact | :high | :medium | :low
  @type result :: %{
          status: status(),
          candidate_transaction_id: binary() | nil,
          confidence_score: Decimal.t(),
          explanation: String.t()
        }

  @spec detect(map(), keyword()) :: result()
  def detect(attrs, opts \\ []) when is_map(attrs) do
    posted_window_days = Keyword.get(opts, :date_window_days, 3)

    source = get(attrs, :source) || "unknown"
    account_id = get(attrs, :account_id)
    source_transaction_id = get(attrs, :source_transaction_id)
    amount = to_decimal(get(attrs, :amount))
    posted_at = get(attrs, :posted_at)
    source_fingerprint = get(attrs, :source_fingerprint) || Fingerprints.source_fingerprint(attrs)

    normalized_fingerprint =
      get(attrs, :normalized_fingerprint) || Fingerprints.normalized_fingerprint(attrs)

    cond do
      is_nil(account_id) ->
        none("missing account ID")

      exact = find_exact_source_id_match(account_id, source, source_transaction_id) ->
        exact(exact.id, "exact source transaction ID match")

      exact = find_exact_source_fingerprint_match(account_id, source_fingerprint) ->
        exact(exact.id, "exact source fingerprint match")

      true ->
        detect_fuzzy_match(
          attrs,
          account_id,
          amount,
          posted_at,
          normalized_fingerprint,
          posted_window_days
        )
    end
  end

  defp detect_fuzzy_match(
         attrs,
         account_id,
         amount,
         posted_at,
         normalized_fingerprint,
         posted_window_days
       ) do
    target_text =
      Fingerprints.normalize_text(get(attrs, :merchant_name) || get(attrs, :description))

    candidates =
      account_id
      |> candidate_query(amount, posted_at, posted_window_days)
      |> Repo.all()

    normalized_same =
      Enum.find(candidates, fn candidate ->
        candidate.normalized_fingerprint == normalized_fingerprint and
          not is_nil(candidate.normalized_fingerprint)
      end)

    cond do
      normalized_same ->
        high(normalized_same.id, "same account/date window/amount/normalized fingerprint")

      candidate = Enum.find(candidates, &same_day_and_text?(&1, posted_at, target_text)) ->
        high(candidate.id, "same account/date/amount/merchant")

      candidate = Enum.find(candidates, &window_and_text?(&1, target_text)) ->
        medium(candidate.id, "same account/amount/date window with merchant similarity")

      candidate = low_confidence_candidate(account_id, amount, target_text) ->
        low(candidate.id, "same account/amount with weak merchant similarity")

      true ->
        none("no duplicate candidate")
    end
  end

  defp candidate_query(account_id, amount, posted_at, posted_window_days) do
    query =
      from(transaction in Transaction,
        where: transaction.account_id == ^account_id,
        select: %{
          id: transaction.id,
          normalized_fingerprint: transaction.normalized_fingerprint,
          posted_at: transaction.posted_at,
          merchant_norm:
            fragment(
              "LOWER(regexp_replace(COALESCE(?, ?), '[^a-zA-Z0-9]+', ' ', 'g'))",
              transaction.merchant_name,
              transaction.description
            )
        },
        limit: 100
      )

    query
    |> maybe_filter_amount(amount)
    |> maybe_filter_posted_window(posted_at, posted_window_days)
  end

  defp find_exact_source_id_match(_account_id, _source, nil), do: nil

  defp find_exact_source_id_match(account_id, source, source_transaction_id) do
    Repo.one(
      from(transaction in Transaction,
        where: transaction.account_id == ^account_id,
        where: transaction.source == ^source,
        where: transaction.source_transaction_id == ^source_transaction_id,
        select: %{id: transaction.id},
        limit: 1
      )
    )
  end

  defp find_exact_source_fingerprint_match(_account_id, nil), do: nil

  defp find_exact_source_fingerprint_match(account_id, source_fingerprint) do
    Repo.one(
      from(transaction in Transaction,
        where: transaction.account_id == ^account_id,
        where: transaction.source_fingerprint == ^source_fingerprint,
        select: %{id: transaction.id},
        limit: 1
      )
    )
  end

  defp maybe_filter_amount(query, nil), do: query

  defp maybe_filter_amount(query, %Decimal{} = amount) do
    where(query, [transaction], transaction.amount == ^amount)
  end

  defp maybe_filter_posted_window(query, nil, _window_days), do: query

  defp maybe_filter_posted_window(query, %DateTime{} = posted_at, window_days) do
    from_dt = posted_at |> DateTime.add(-window_days * 86_400, :second)
    to_dt = posted_at |> DateTime.add(window_days * 86_400, :second)

    where(
      query,
      [transaction],
      not is_nil(transaction.posted_at) and transaction.posted_at >= ^from_dt and
        transaction.posted_at <= ^to_dt
    )
  end

  defp low_confidence_candidate(account_id, amount, target_text) do
    account_id
    |> candidate_query(amount, nil, 0)
    |> Repo.all()
    |> Enum.find(&merchant_only?(&1, target_text))
  end

  defp same_day_and_text?(candidate, %DateTime{} = posted_at, target_text) do
    same_date?(candidate.posted_at, posted_at) and
      text_match?(candidate.merchant_norm, target_text)
  end

  defp same_day_and_text?(_candidate, _posted_at, _target_text), do: false

  defp window_and_text?(candidate, target_text),
    do: text_match?(candidate.merchant_norm, target_text)

  defp merchant_only?(candidate, target_text) do
    text = normalize_db_text(candidate.merchant_norm)

    target_text != "" and
      text != "" and
      String.length(target_text) >= 4 and
      (String.contains?(text, target_text) or String.contains?(target_text, text))
  end

  defp text_match?(text, target_text) do
    normalize_db_text(text) == target_text and target_text != ""
  end

  defp normalize_db_text(text) when is_binary(text),
    do: text |> String.trim() |> String.replace(~r/\s+/u, " ")

  defp normalize_db_text(_text), do: ""

  defp same_date?(%DateTime{} = left, %DateTime{} = right) do
    Date.compare(DateTime.to_date(left), DateTime.to_date(right)) == :eq
  end

  defp same_date?(_left, _right), do: false

  defp to_decimal(nil), do: nil
  defp to_decimal(%Decimal{} = value), do: value

  defp to_decimal(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> decimal
      :error -> nil
    end
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp exact(id, explanation), do: response(:exact, id, "1.0", explanation)
  defp high(id, explanation), do: response(:high, id, "0.95", explanation)
  defp medium(id, explanation), do: response(:medium, id, "0.70", explanation)
  defp low(id, explanation), do: response(:low, id, "0.35", explanation)
  defp none(explanation), do: response(:none, nil, "0.0", explanation)

  defp response(status, candidate_transaction_id, confidence, explanation) do
    %{
      status: status,
      candidate_transaction_id: candidate_transaction_id,
      confidence_score: Decimal.new(confidence),
      explanation: explanation
    }
  end
end
