defmodule MoneyTree.Obligations.Evaluator do
  @moduledoc """
  Computes obligation due-state transitions and emits durable notification events.
  """

  import Ecto.Query, warn: false

  alias Decimal
  alias MoneyTree.Accounts
  alias MoneyTree.Notifications
  alias MoneyTree.Notifications.Event
  alias MoneyTree.Obligations.Obligation
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

  @lookback_days 45

  @type evaluation_result :: %{
          obligation_id: binary(),
          cycle_due_date: Date.t(),
          state: :clear | :upcoming | :due_today | :overdue | :recovered
        }

  @spec evaluate(Obligation.t(), Date.t()) :: {:ok, evaluation_result()}
  def evaluate(%Obligation{} = obligation, %Date{} = today) do
    due_date = due_date_for(obligation, today)
    preferences = Notifications.preferences_for(obligation.user, obligation)

    payment = find_cycle_payment(obligation, due_date, today)
    recovered? = reconcile_recovery(obligation, today)

    state =
      cond do
        recovered? and enabled?(preferences, :recovered_enabled) -> :recovered
        payment -> :clear
        Date.compare(today, due_date) == :eq and enabled?(preferences, :due_today_enabled) -> :due_today
        overdue?(today, due_date, obligation) and enabled?(preferences, :overdue_enabled) -> :overdue
        upcoming?(today, due_date, preferences) and enabled?(preferences, :upcoming_enabled) -> :upcoming
        true -> :clear
      end

    emit_state(obligation, state, due_date, payment, preferences, today)

    {:ok, %{obligation_id: obligation.id, cycle_due_date: due_date, state: state}}
  end

  @spec due_date_for(Obligation.t(), Date.t()) :: Date.t()
  def due_date_for(%Obligation{due_rule: "last_day_of_month"} = _obligation, %Date{} = date) do
    Date.end_of_month(date)
  end

  def due_date_for(%Obligation{due_day: due_day}, %Date{} = date) do
    %{year: year, month: month} = date
    last_day = Date.days_in_month(date)
    Date.new!(year, month, min(due_day || last_day, last_day))
  end

  defp emit_state(_obligation, :clear, due_date, payment, _preferences, _today) do
    if payment do
      Notifications.resolve_cycle_events(payment.obligation_id, due_date, ~w(upcoming due_today overdue))
    end

    :ok
  end

  defp emit_state(%Obligation{} = obligation, :recovered, _due_date, _payment, _preferences, today) do
    recover_overdue_events(obligation, today)
  end

  defp emit_state(%Obligation{} = obligation, state, due_date, _payment, preferences, today) do
    metadata = event_metadata(obligation, due_date, preferences)

    Notifications.resolve_cycle_events(obligation.id, due_date, superseded_statuses(state))

    Notifications.record_event(%{
      user_id: obligation.user_id,
      obligation_id: obligation.id,
      kind: "payment_obligation",
      status: Atom.to_string(state),
      severity: severity_for(state, metadata),
      title: title_for(obligation, state),
      message: message_for(obligation, state, due_date, metadata),
      action: action_for(state, metadata),
      event_date: due_date,
      occurred_at: DateTime.new!(today, ~T[00:00:00], "Etc/UTC"),
      metadata: metadata,
      dedupe_key: dedupe_key(obligation.id, due_date, state)
    })

    :ok
  end

  defp recover_overdue_events(%Obligation{} = obligation, today) do
    obligation.id
    |> Notifications.list_open_events_for_obligation("overdue")
    |> Enum.each(fn %Event{} = overdue_event ->
      metadata =
        overdue_event.metadata
        |> Map.put("recovered_at", Date.to_iso8601(today))

      Notifications.resolve_event(overdue_event)

      Notifications.record_event(%{
        user_id: obligation.user_id,
        obligation_id: obligation.id,
        kind: "payment_obligation",
        status: "recovered",
        severity: "info",
        title: "#{obligation.creditor_payee} payment recovered",
        message:
          "#{obligation.creditor_payee} payment activity has resumed after the overdue alert.",
        action: "Confirm your balance",
        event_date: overdue_event.event_date,
        occurred_at: DateTime.new!(today, ~T[00:00:00], "Etc/UTC"),
        metadata: metadata,
        dedupe_key: dedupe_key(obligation.id, overdue_event.event_date, :recovered)
      })
    end)
  end

  defp event_metadata(%Obligation{} = obligation, due_date, preferences) do
    funding_account = obligation.linked_funding_account
    available_balance = funding_account && (funding_account.available_balance || funding_account.current_balance)
    shortfall? = available_balance && Decimal.compare(available_balance, obligation.minimum_due_amount) == :lt

    %{
      "payee" => obligation.creditor_payee,
      "due_date" => Date.to_iso8601(due_date),
      "minimum_due_amount" => Decimal.to_string(obligation.minimum_due_amount, :normal),
      "currency" => obligation.currency,
      "funding_account_id" => obligation.linked_funding_account_id,
      "funding_account_name" => funding_account && funding_account.name,
      "funding_balance" => if(available_balance, do: Decimal.to_string(available_balance, :normal), else: nil),
      "funding_shortfall" => shortfall? || false,
      "upcoming_lead_days" => preferences.upcoming_lead_days
    }
  end

  defp find_cycle_payment(%Obligation{} = obligation, due_date, today) do
    cycle_start = Date.add(due_date, -@lookback_days)
    cycle_end = Date.add(today, max(obligation.grace_period_days, 0))
    payee_pattern = "%" <> String.downcase(String.trim(obligation.creditor_payee)) <> "%"
    minimum_due_amount = obligation.minimum_due_amount

    from(transaction in Transaction,
      where: transaction.account_id == ^obligation.linked_funding_account_id,
      where:
        fragment("DATE(?)", transaction.posted_at) >= ^cycle_start and
          fragment("DATE(?)", transaction.posted_at) <= ^cycle_end,
      where:
        fragment("LOWER(COALESCE(?, '')) LIKE ?", transaction.description, ^payee_pattern) or
          fragment("LOWER(COALESCE(?, '')) LIKE ?", transaction.merchant_name, ^payee_pattern),
      where: fragment("ABS(?)", transaction.amount) >= ^minimum_due_amount,
      order_by: [desc: transaction.posted_at],
      limit: 1,
      select: %{id: transaction.id, obligation_id: ^obligation.id}
    )
    |> Repo.one()
  end

  defp reconcile_recovery(%Obligation{} = obligation, today) do
    open_overdue = Notifications.list_open_events_for_obligation(obligation.id, "overdue")

    Enum.any?(open_overdue, fn %Event{} = event ->
      find_payment_after_event(obligation, event, today)
    end)
  end

  defp find_payment_after_event(%Obligation{} = obligation, %Event{} = event, today) do
    payee_pattern = "%" <> String.downcase(String.trim(obligation.creditor_payee)) <> "%"

    from(transaction in Transaction,
      where: transaction.account_id == ^obligation.linked_funding_account_id,
      where: fragment("DATE(?)", transaction.posted_at) >= ^event.event_date,
      where: fragment("DATE(?)", transaction.posted_at) <= ^today,
      where:
        fragment("LOWER(COALESCE(?, '')) LIKE ?", transaction.description, ^payee_pattern) or
          fragment("LOWER(COALESCE(?, '')) LIKE ?", transaction.merchant_name, ^payee_pattern),
      where: fragment("ABS(?)", transaction.amount) >= ^obligation.minimum_due_amount,
      select: transaction.id,
      limit: 1
    )
    |> Repo.one()
    |> Kernel.!=(nil)
  end

  defp overdue?(today, due_date, obligation) do
    cutoff = Date.add(due_date, obligation.grace_period_days)
    Date.compare(today, cutoff) == :gt
  end

  defp upcoming?(today, due_date, preferences) do
    days_until_due = Date.diff(due_date, today)
    days_until_due > 0 and days_until_due <= preferences.upcoming_lead_days
  end

  defp enabled?(preferences, key), do: Map.get(preferences, key, false)

  defp severity_for(:overdue, %{"funding_shortfall" => true}), do: "critical"
  defp severity_for(:overdue, _metadata), do: "critical"
  defp severity_for(:due_today, %{"funding_shortfall" => true}), do: "critical"
  defp severity_for(:due_today, _metadata), do: "warning"
  defp severity_for(:upcoming, %{"funding_shortfall" => true}), do: "warning"
  defp severity_for(:upcoming, _metadata), do: "info"

  defp title_for(obligation, :upcoming), do: "#{obligation.creditor_payee} payment due soon"
  defp title_for(obligation, :due_today), do: "#{obligation.creditor_payee} payment due today"
  defp title_for(obligation, :overdue), do: "#{obligation.creditor_payee} payment overdue"

  defp message_for(obligation, state, due_date, metadata) do
    amount = Accounts.format_money(obligation.minimum_due_amount, obligation.currency, [])
    due_on = Calendar.strftime(due_date, "%b %d")
    funding = metadata["funding_account_name"] || "your funding account"

    base =
      case state do
        :upcoming -> "#{obligation.creditor_payee} requires at least #{amount} by #{due_on}."
        :due_today -> "#{obligation.creditor_payee} requires at least #{amount} today."
        :overdue -> "#{obligation.creditor_payee} is overdue for at least #{amount}."
      end

    if metadata["funding_shortfall"] do
      base <> " #{funding} may not have enough available cash."
    else
      base <> " Review #{funding} for the payment."
    end
  end

  defp action_for(:upcoming, %{"funding_shortfall" => true}), do: "Move funds"
  defp action_for(:upcoming, _metadata), do: "Schedule payment"
  defp action_for(:due_today, _metadata), do: "Pay now"
  defp action_for(:overdue, _metadata), do: "Verify payment"

  defp superseded_statuses(:upcoming), do: []
  defp superseded_statuses(:due_today), do: ["upcoming"]
  defp superseded_statuses(:overdue), do: ["upcoming", "due_today"]

  defp dedupe_key(obligation_id, due_date, state) do
    "obligation:#{obligation_id}:#{Date.to_iso8601(due_date)}:#{state}"
  end
end
