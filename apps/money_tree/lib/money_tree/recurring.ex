defmodule MoneyTree.Recurring do
  @moduledoc """
  Detects recurring transaction series and records anomalies for notifications.
  """

  import Ecto.Query, warn: false

  alias Decimal, as: D
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Institutions.Connection
  alias MoneyTree.Recurring.Anomaly
  alias MoneyTree.Recurring.DetectorWorker
  alias MoneyTree.Recurring.Series
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction
  alias Oban

  @lookback_days 365
  @min_series_transactions 3

  @spec schedule_detection(Connection.t()) :: :ok | {:error, term()}
  def schedule_detection(%Connection{id: connection_id}) do
    args = %{"connection_id" => connection_id}

    args
    |> DetectorWorker.new(unique: [keys: [:connection_id], period: 120])
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec detect_for_connection(binary()) :: {:ok, map()} | {:error, :connection_not_found}
  def detect_for_connection(connection_id) do
    case Repo.get(Connection, connection_id) do
      nil -> {:error, :connection_not_found}
      %Connection{} = connection -> detect_for_user(connection.user_id, connection.id)
    end
  end

  @spec detect_for_user(binary(), binary() | nil) :: {:ok, map()}
  def detect_for_user(user_id, connection_id \\ nil) do
    cutoff = DateTime.add(DateTime.utc_now(), -@lookback_days, :day)

    transactions =
      transactions_query(user_id, connection_id, cutoff)
      |> Repo.all()
      |> deduplicate_pending_posted_pairs()

    series_candidates =
      transactions
      |> Enum.group_by(&series_key/1)
      |> Enum.filter(fn {_key, txns} -> length(txns) >= @min_series_transactions end)

    touched_series_ids =
      Enum.reduce(series_candidates, [], fn {_key, txns}, acc ->
        txns = Enum.sort_by(txns, & &1.posted_at, DateTime)

        case upsert_series(user_id, txns) do
          {:ok, %Series{id: id} = series} ->
            process_anomalies(series, txns)
            [id | acc]

          _ ->
            acc
        end
      end)

    mark_unseen_series_inactive(user_id, touched_series_ids)

    {:ok, %{series_updated: length(touched_series_ids)}}
  end

  def list_open_anomalies(user_id) do
    Anomaly
    |> join(:inner, [a], s in assoc(a, :series))
    |> where([a, s], s.user_id == ^user_id and a.status == "open")
    |> preload([_a, s], series: s)
    |> order_by([a], desc: a.detected_at)
    |> Repo.all()
  end

  defp transactions_query(user_id, connection_id, cutoff) do
    Transaction
    |> join(:inner, [t], a in Account, on: t.account_id == a.id)
    |> where([t, a], a.user_id == ^user_id)
    |> maybe_filter_connection(connection_id)
    |> where([t], t.posted_at >= ^cutoff)
    |> where([t], t.status in ["posted", "pending"])
    |> select([t, a], %{t | account: a})
  end

  defp maybe_filter_connection(query, nil), do: query

  defp maybe_filter_connection(query, connection_id) do
    where(query, [_t, a], a.institution_connection_id == ^connection_id)
  end

  defp deduplicate_pending_posted_pairs(transactions) do
    grouped =
      Enum.group_by(transactions, fn tx ->
        descriptor = normalize_descriptor(tx.merchant_name || tx.description)
        amount = D.abs(tx.amount) |> D.to_string(:normal)
        {tx.account_id, descriptor, amount}
      end)

    grouped
    |> Enum.flat_map(fn {_key, txns} ->
      posted = Enum.filter(txns, &(&1.status == "posted"))
      pending = Enum.filter(txns, &(&1.status == "pending"))

      if posted != [] and pending != [] do
        posted ++ pending_without_matches(posted, pending)
      else
        txns
      end
    end)
  end

  defp pending_without_matches(posted, pending) do
    Enum.reject(pending, fn pending_tx ->
      Enum.any?(posted, fn posted_tx ->
        abs(Date.diff(DateTime.to_date(posted_tx.posted_at), DateTime.to_date(pending_tx.posted_at))) <= 3
      end)
    end)
  end

  defp upsert_series(user_id, txns) do
    descriptor = txns |> List.first() |> descriptor_for_txn()
    account_id = txns |> List.first() |> Map.fetch!(:account_id)
    category = txns |> List.first() |> Map.get(:category)
    fingerprint = [account_id, category || "uncategorized", descriptor] |> Enum.join("|")

    intervals =
      txns
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [left, right] -> Date.diff(DateTime.to_date(right.posted_at), DateTime.to_date(left.posted_at)) end)
      |> Enum.filter(&(&1 > 0))

    {cadence, cadence_days, window_days, interval_confidence} = infer_cadence(intervals)

    amounts = Enum.map(txns, fn tx -> D.abs(tx.amount) end)
    avg_amount = average_decimal(amounts)
    min_amount = expected_min(amounts, avg_amount)
    max_amount = expected_max(amounts, avg_amount)
    amount_confidence = amount_confidence(amounts, avg_amount)

    last_tx = List.last(txns)
    last_seen_at = DateTime.truncate(last_tx.posted_at, :second)
    next_expected_at = DateTime.add(last_seen_at, cadence_days * 86_400, :second)

    confidence =
      interval_confidence
      |> D.add(amount_confidence)
      |> D.div(D.new("2"))
      |> D.round(4)

    status = if D.compare(confidence, D.new("0.55")) in [:gt, :eq], do: "active", else: "tentative"

    attrs = %{
      user_id: user_id,
      account_id: account_id,
      last_transaction_id: last_tx.id,
      fingerprint: fingerprint,
      series_key: fingerprint,
      cadence: cadence,
      cadence_days: cadence_days,
      expected_window_days: window_days,
      expected_amount_min: min_amount,
      expected_amount_max: max_amount,
      confidence: confidence,
      status: status,
      last_seen_at: last_seen_at,
      next_expected_at: next_expected_at
    }

    %Series{}
    |> Series.changeset(attrs)
    |> Repo.insert(
      conflict_target: [:user_id, :series_key],
      on_conflict: [
        set: [
          account_id: account_id,
          last_transaction_id: last_tx.id,
          cadence: cadence,
          cadence_days: cadence_days,
          expected_window_days: window_days,
          expected_amount_min: min_amount,
          expected_amount_max: max_amount,
          confidence: confidence,
          status: status,
          last_seen_at: last_seen_at,
          next_expected_at: next_expected_at,
          updated_at: DateTime.utc_now()
        ]
      ],
      returning: true
    )
  end

  defp process_anomalies(%Series{} = series, txns) do
    now = DateTime.utc_now()
    window_end = DateTime.add(series.next_expected_at, series.expected_window_days * 86_400, :second)
    expense_series? =
      case List.last(txns) do
        %{amount: %D{} = amount} -> D.compare(amount, D.new("0")) == :lt
        _ -> false
      end

    active_types = []

    active_types =
      if expense_series? and DateTime.compare(now, window_end) == :gt do
        record_anomaly(series, "missing_cycle", DateTime.to_date(series.next_expected_at), %{now: now})
        ["missing_cycle" | active_types]
      else
        active_types
      end

    active_types =
      if expense_series? and
           DateTime.compare(now, series.next_expected_at) == :gt and
           DateTime.compare(now, window_end) != :gt do
        record_anomaly(series, "late_cycle", DateTime.to_date(series.next_expected_at), %{now: now})
        ["late_cycle" | active_types]
      else
        active_types
      end

    case List.last(txns) do
      nil ->
        :ok

      latest ->
        latest_abs = D.abs(latest.amount)
        historical_amounts =
          txns
          |> Enum.drop(-1)
          |> Enum.map(fn tx -> D.abs(tx.amount) end)

        {expected_min, expected_max} =
          case historical_amounts do
            [] ->
              {series.expected_amount_min, series.expected_amount_max}

            amounts ->
              average = average_decimal(amounts)
              {expected_min(amounts, average), expected_max(amounts, average)}
          end

        below_min = expected_min && D.compare(latest_abs, expected_min) == :lt
        above_max = expected_max && D.compare(latest_abs, expected_max) == :gt

        if below_min or above_max do
          record_anomaly(series, "unusual_amount", DateTime.to_date(latest.posted_at), %{
            observed_amount: latest_abs,
            expected_amount_min: expected_min,
            expected_amount_max: expected_max,
            transaction_id: latest.id
          })

          active_types = ["unusual_amount" | active_types]
          resolve_stale_anomalies(series.id, active_types)
        else
          resolve_stale_anomalies(series.id, active_types)
        end
    end
  end

  defp record_anomaly(%Series{} = series, anomaly_type, occurred_on, details) do
    attrs = %{
      series_id: series.id,
      anomaly_type: anomaly_type,
      status: "open",
      severity: severity_for(anomaly_type),
      occurred_on: occurred_on,
      details: details,
      detected_at: DateTime.utc_now(),
      resolved_at: nil
    }

    %Anomaly{}
    |> Anomaly.changeset(attrs)
    |> Repo.insert(
      conflict_target: [:series_id, :anomaly_type, :occurred_on],
      on_conflict: [
        set: [
          status: "open",
          severity: severity_for(anomaly_type),
          details: details,
          detected_at: DateTime.utc_now(),
          resolved_at: nil,
          updated_at: DateTime.utc_now()
        ]
      ]
    )
  end

  defp resolve_stale_anomalies(series_id, active_types) do
    from(a in Anomaly,
      where: a.series_id == ^series_id and a.status == "open" and a.anomaly_type not in ^active_types
    )
    |> Repo.update_all(set: [status: "resolved", resolved_at: DateTime.utc_now(), updated_at: DateTime.utc_now()])
  end

  defp mark_unseen_series_inactive(user_id, touched_series_ids) do
    from(s in Series,
      where: s.user_id == ^user_id,
      where: s.id not in ^touched_series_ids
    )
    |> Repo.update_all(set: [status: "inactive", updated_at: DateTime.utc_now()])
  end

  defp infer_cadence([]), do: {"custom", 30, 5, D.new("0.25")}

  defp infer_cadence(intervals) do
    avg = Enum.sum(intervals) / max(length(intervals), 1)
    spread = interval_spread(intervals, avg)

    {cadence, cadence_days} =
      cond do
        in_band?(avg, 7, 2) -> {"weekly", 7}
        in_band?(avg, 14, 3) -> {"biweekly", 14}
        in_band?(avg, 30, 4) -> {"monthly", 30}
        true -> {"custom", round(avg)}
      end

    window_days = max(2, min(7, round(max(spread, 2))))
    confidence = interval_confidence(avg, spread)

    {cadence, cadence_days, window_days, confidence}
  end

  defp interval_confidence(avg, spread) do
    base =
      cond do
        in_band?(avg, 7, 2) or in_band?(avg, 14, 3) or in_band?(avg, 30, 4) -> 0.9
        true -> 0.6
      end

    confidence = max(0.1, min(1.0, base - spread / max(avg, 1)))
    D.from_float(confidence) |> D.round(4)
  end

  defp in_band?(value, center, delta), do: value >= center - delta and value <= center + delta

  defp interval_spread(intervals, avg) do
    intervals
    |> Enum.map(fn day -> :math.pow(day - avg, 2) end)
    |> Enum.sum()
    |> Kernel./(max(length(intervals), 1))
    |> :math.sqrt()
  end

  defp amount_confidence(amounts, avg_amount) do
    if amounts == [] do
      D.new("0")
    else
      avg_float = decimal_to_float(avg_amount)

      spread =
        amounts
        |> Enum.map(fn amount -> :math.pow(decimal_to_float(amount) - avg_float, 2) end)
        |> Enum.sum()
        |> Kernel./(length(amounts))
        |> :math.sqrt()

      confidence = max(0.1, min(1.0, 1.0 - spread / max(avg_float, 1.0)))
      D.from_float(confidence) |> D.round(4)
    end
  end

  defp expected_min(amounts, avg_amount) do
    case amounts do
      [] -> nil
      _ -> D.min(Enum.min(amounts), D.mult(avg_amount, D.new("0.8")))
    end
  end

  defp expected_max(amounts, avg_amount) do
    case amounts do
      [] -> nil
      _ -> D.max(Enum.max(amounts), D.mult(avg_amount, D.new("1.2")))
    end
  end

  defp average_decimal([]), do: D.new("0")

  defp average_decimal(values) do
    values
    |> Enum.reduce(D.new("0"), &D.add/2)
    |> D.div(D.new(length(values)))
    |> D.round(4)
  end

  defp series_key(tx) do
    descriptor = descriptor_for_txn(tx)
    category = tx.category || "uncategorized"
    {tx.account_id, category, descriptor}
  end

  defp descriptor_for_txn(tx) do
    normalize_descriptor(tx.merchant_name || tx.description)
  end

  defp normalize_descriptor(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.trim()
    |> String.slice(0, 80)
  end

  defp normalize_descriptor(_), do: "unknown"

  defp severity_for("missing_cycle"), do: "critical"
  defp severity_for("late_cycle"), do: "warning"
  defp severity_for("unusual_amount"), do: "warning"

  defp decimal_to_float(%D{} = value) do
    value |> D.to_string(:normal) |> String.to_float()
  end
end
