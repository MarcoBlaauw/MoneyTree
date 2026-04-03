defmodule MoneyTree.Notifications do
  @moduledoc """
  Durable notification context plus computed dashboard advisories.
  """

  import Ecto.Query, warn: false

  alias Decimal
  alias Ecto.Changeset
  alias MoneyTree.Accounts
  alias MoneyTree.Budgets
  alias MoneyTree.Loans
  alias MoneyTree.Notifications.AlertPreference
  alias MoneyTree.Notifications.DeliveryAttempt
  alias MoneyTree.Notifications.DeliveryWorker
  alias MoneyTree.Notifications.EmailAdapter
  alias MoneyTree.Notifications.Event
  alias MoneyTree.Notifications.Push
  alias MoneyTree.Notifications.SMS
  alias MoneyTree.Obligations.Obligation
  alias MoneyTree.Recurring
  alias MoneyTree.Repo
  alias MoneyTree.Subscriptions
  alias MoneyTree.Users.User
  alias Oban

  @type notification :: %{
          id: String.t(),
          event_id: String.t() | nil,
          severity: :info | :warning | :critical,
          message: String.t(),
          action: String.t() | nil,
          durable: boolean()
        }

  @default_preference_snapshot %{
    email_enabled: true,
    sms_enabled: false,
    push_enabled: false,
    dashboard_enabled: true,
    upcoming_enabled: true,
    due_today_enabled: true,
    overdue_enabled: true,
    recovered_enabled: true,
    upcoming_lead_days: 3,
    resend_interval_hours: 24,
    max_resends: 2
  }

  @channel_modules %{
    email: EmailAdapter,
    sms: SMS,
    push: Push
  }

  @doc """
  Returns a changeset for alert preferences.
  """
  @spec change_alert_preference(AlertPreference.t(), map()) :: Changeset.t()
  def change_alert_preference(%AlertPreference{} = preference, attrs \\ %{}) do
    AlertPreference.changeset(preference, attrs)
  end

  @doc """
  Fetches or creates the user's alert preferences.
  """
  @spec get_alert_preference(User.t() | binary()) :: AlertPreference.t()
  def get_alert_preference(user) do
    user_id = resolve_user_id(user)

    Repo.get_by(AlertPreference, user_id: user_id) ||
      %AlertPreference{}
      |> AlertPreference.changeset(Map.put(@default_preference_snapshot, :user_id, user_id))
      |> Repo.insert!()
  end

  @doc """
  Returns a stable map of alert preferences for JSON and LiveView rendering.
  """
  @spec preference_snapshot(User.t() | binary()) :: map()
  def preference_snapshot(user) do
    preference = get_alert_preference(user)

    %{
      email_enabled: preference.email_enabled,
      sms_enabled: preference.sms_enabled,
      push_enabled: preference.push_enabled,
      dashboard_enabled: preference.dashboard_enabled,
      upcoming_enabled: preference.upcoming_enabled,
      due_today_enabled: preference.due_today_enabled,
      overdue_enabled: preference.overdue_enabled,
      recovered_enabled: preference.recovered_enabled,
      upcoming_lead_days: preference.upcoming_lead_days,
      resend_interval_hours: preference.resend_interval_hours,
      max_resends: preference.max_resends
    }
  end

  @doc """
  Updates user-level alert preferences.
  """
  @spec upsert_alert_preference(User.t() | binary(), map()) ::
          {:ok, AlertPreference.t()} | {:error, Changeset.t()}
  def upsert_alert_preference(user, attrs) when is_map(attrs) do
    preference = get_alert_preference(user)
    attrs = normalize_string_key_map(attrs)

    preference
    |> AlertPreference.changeset(Map.put(attrs, "user_id", preference.user_id))
    |> Repo.insert_or_update()
  end

  @doc """
  Effective preferences for a specific obligation.
  """
  @spec preferences_for(User.t() | binary(), Obligation.t() | nil) :: map()
  def preferences_for(user, obligation \\ nil) do
    defaults = preference_snapshot(user)
    overrides = normalize_override_map(obligation && obligation.alert_preferences)

    Map.merge(defaults, overrides)
  end

  @doc """
  Lists unresolved durable events for dashboard rendering.
  """
  @spec list_dashboard_events(User.t() | binary(), keyword()) :: [notification()]
  def list_dashboard_events(user, opts \\ []) do
    limit = Keyword.get(opts, :limit, 8)
    preferences = preference_snapshot(user)

    if preferences.dashboard_enabled do
      Event
      |> where([event], event.user_id == ^resolve_user_id(user) and is_nil(event.resolved_at))
      |> order_by([event], desc: event.occurred_at, desc: event.inserted_at)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.map(&to_notification/1)
    else
      []
    end
  end

  @doc """
  Computes pending notification items for the given user.
  """
  @spec pending(User.t() | binary(), keyword()) :: [notification()]
  def pending(user, opts \\ []) do
    durable = list_dashboard_events(user)

    card_balances = Accounts.running_card_balances(user, opts)
    budgets = Budgets.aggregate_totals(user, opts)
    loans = Loans.overview(user, opts)
    subscription = Subscriptions.spend_summary(user, opts)
    recurring_anomalies = Recurring.list_open_anomalies(resolve_user_id(user))

    durable
    |> add_utilization_alerts(card_balances)
    |> add_budget_alerts(budgets)
    |> add_autopay_alerts(loans)
    |> add_subscription_digest(subscription)
    |> add_recurring_anomalies(recurring_anomalies)
    |> dedupe_notifications()
    |> ensure_fallback()
  end

  @doc """
  Idempotently records a durable event and schedules delivery if required.
  """
  @spec record_event(map()) :: {:ok, Event.t()} | {:error, Changeset.t()}
  def record_event(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:delivery_status, "pending")
      |> Map.put_new(:next_delivery_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))

    changeset = Event.changeset(%Event{}, attrs)

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: :dedupe_key,
           returning: true
         ) do
      {:ok, %Event{id: nil}} ->
        event = Repo.get_by!(Event, dedupe_key: Map.fetch!(attrs, :dedupe_key))
        {:ok, event}

      {:ok, %Event{} = event} ->
        schedule_delivery(event)
        {:ok, event}

      {:error, %Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Marks the supplied event as resolved.
  """
  @spec resolve_event(Event.t()) :: {:ok, Event.t()} | {:error, Changeset.t()}
  def resolve_event(%Event{} = event) do
    event
    |> Changeset.change(resolved_at: DateTime.utc_now() |> DateTime.truncate(:microsecond))
    |> Repo.update()
  end

  @doc """
  Resolves a dashboard event owned by the supplied user.
  """
  @spec resolve_event(User.t() | binary(), binary()) ::
          {:ok, Event.t()} | {:error, :already_resolved | :not_found | Changeset.t()}
  def resolve_event(user, event_id) when is_binary(event_id) do
    case Repo.get_by(Event, id: event_id, user_id: resolve_user_id(user)) do
      nil ->
        {:error, :not_found}

      %Event{resolved_at: %DateTime{}} ->
        {:error, :already_resolved}

      %Event{} = event ->
        resolve_event(event)
    end
  end

  @doc """
  Resolves open events for the same obligation cycle and statuses.
  """
  @spec resolve_cycle_events(binary(), Date.t(), [String.t()]) :: non_neg_integer()
  def resolve_cycle_events(_obligation_id, _event_date, []), do: 0

  def resolve_cycle_events(obligation_id, %Date{} = event_date, statuses) do
    {count, _} =
      Event
      |> where(
        [event],
        event.obligation_id == ^obligation_id and event.event_date == ^event_date and
          event.status in ^statuses and is_nil(event.resolved_at)
      )
      |> Repo.update_all(
        set: [resolved_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)]
      )

    count
  end

  @doc """
  Lists unresolved events for a specific obligation and status.
  """
  @spec list_open_events_for_obligation(binary(), String.t()) :: [Event.t()]
  def list_open_events_for_obligation(obligation_id, status) do
    Event
    |> where(
      [event],
      event.obligation_id == ^obligation_id and event.status == ^status and
        is_nil(event.resolved_at)
    )
    |> order_by([event], asc: event.event_date, asc: event.inserted_at)
    |> Repo.all()
  end

  @doc """
  Delivers an event immediately if it is due and allowed by preferences.
  """
  @spec deliver_event(binary()) ::
          :ok
          | {:error,
             :already_resolved
             | :event_not_found
             | :max_resends_exhausted
             | :not_due
             | :suppressed
             | term()}
  def deliver_event(event_id) when is_binary(event_id) do
    case Repo.get(Event, event_id) |> Repo.preload([:user, :obligation]) do
      nil ->
        {:error, :event_not_found}

      %Event{resolved_at: %DateTime{}} ->
        {:error, :already_resolved}

      %Event{} = event ->
        do_deliver_event(event)
    end
  end

  defp do_deliver_event(%Event{} = event) do
    preferences = preferences_for(event.user, event.obligation)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    cond do
      event.delivery_status == "suppressed" ->
        {:error, :suppressed}

      event.next_delivery_at && DateTime.compare(now, event.next_delivery_at) == :lt ->
        {:error, :not_due}

      event.delivery_attempt_count > preferences.max_resends ->
        suppress_event(event, "maximum resend attempts exhausted")
        {:error, :max_resends_exhausted}

      enabled_channels(preferences) == [] ->
        suppress_event(event, "all delivery channels disabled by user preferences")
        {:error, :suppressed}

      true ->
        attempt_delivery(event, preferences, now)
    end
  end

  defp attempt_delivery(event, preferences, attempted_at) do
    attempt_number = event.delivery_attempt_count + 1

    results =
      preferences
      |> enabled_channels()
      |> Enum.map(&deliver_on_channel(&1, event, attempted_at, attempt_number))

    successes = Enum.filter(results, &(elem(&1, 0) == :ok))
    retryable_failures = Enum.filter(results, &(elem(&1, 0) == :failed))
    suppressed_failures = Enum.filter(results, &(elem(&1, 0) == :suppressed))

    cond do
      successes != [] ->
        event
        |> Changeset.change(
          delivery_status: "delivered",
          last_delivered_at: attempted_at,
          next_delivery_at: nil,
          delivery_attempt_count: attempt_number,
          last_delivery_error: nil
        )
        |> Repo.update()

        :ok

      retryable_failures == [] and suppressed_failures != [] ->
        reasons =
          suppressed_failures
          |> Enum.map(fn {_status, channel, reason} -> "#{channel}: #{inspect(reason)}" end)
          |> Enum.join(", ")

        suppress_event(event, reasons)
        {:error, :suppressed}

      true ->
        next_delivery_at =
          DateTime.add(attempted_at, preferences.resend_interval_hours * 3_600, :second)

        last_error =
          retryable_failures
          |> Enum.map(fn {_status, channel, reason} -> "#{channel}: #{inspect(reason)}" end)
          |> Enum.join(", ")

        event
        |> Changeset.change(
          delivery_status: "failed",
          next_delivery_at: next_delivery_at,
          delivery_attempt_count: attempt_number,
          last_delivery_error: last_error
        )
        |> Repo.update()

        schedule_delivery(%{event | next_delivery_at: next_delivery_at})
        {:error, :delivery_failed}
    end
  end

  defp deliver_on_channel(channel, %Event{} = event, attempted_at, attempt_number) do
    adapter = Map.fetch!(@channel_modules, channel)
    idempotency_key = "#{event.dedupe_key}:#{channel}:#{attempt_number}"

    case adapter.deliver(event, event.user, idempotency_key: idempotency_key) do
      {:ok, metadata} ->
        record_delivery_attempt(event, %{
          channel: Atom.to_string(channel),
          adapter: adapter_name(adapter, metadata),
          status: "sent",
          idempotency_key: idempotency_key,
          attempted_at: attempted_at,
          delivered_at: attempted_at,
          provider_reference: Map.get(metadata, :provider_reference),
          metadata: Map.new(metadata)
        })

        {:ok, channel}

      {:error, reason} ->
        status = if permanent_failure?(reason), do: "suppressed", else: "failed"

        record_delivery_attempt(event, %{
          channel: Atom.to_string(channel),
          adapter: inspect(adapter),
          status: status,
          idempotency_key: idempotency_key,
          attempted_at: attempted_at,
          error_message: inspect(reason),
          metadata: %{}
        })

        if permanent_failure?(reason) do
          {:suppressed, channel, reason}
        else
          {:failed, channel, reason}
        end
    end
  end

  defp adapter_name(adapter, metadata) do
    metadata
    |> Map.get(:provider_adapter, inspect(adapter))
    |> to_string()
  end

  defp permanent_failure?(:destination_unavailable), do: true
  defp permanent_failure?(:sms_adapter_not_configured), do: true
  defp permanent_failure?(:push_adapter_not_configured), do: true
  defp permanent_failure?(_reason), do: false

  defp enabled_channels(preferences) do
    []
    |> maybe_enable_channel(:email, preferences.email_enabled)
    |> maybe_enable_channel(:sms, preferences.sms_enabled)
    |> maybe_enable_channel(:push, preferences.push_enabled)
  end

  defp maybe_enable_channel(channels, _channel, false), do: channels
  defp maybe_enable_channel(channels, channel, true), do: channels ++ [channel]

  defp suppress_event(event, reason) do
    event
    |> Changeset.change(
      delivery_status: "suppressed",
      next_delivery_at: nil,
      last_delivery_error: reason
    )
    |> Repo.update()
  end

  defp record_delivery_attempt(%Event{} = event, attrs) do
    %DeliveryAttempt{}
    |> DeliveryAttempt.changeset(Map.put(attrs, :event_id, event.id))
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: :idempotency_key
    )
  end

  defp schedule_delivery(%Event{} = event) do
    %{"event_id" => event.id}
    |> DeliveryWorker.new(
      scheduled_at:
        event.next_delivery_at || DateTime.utc_now() |> DateTime.truncate(:microsecond),
      unique: [keys: [:event_id], period: 300]
    )
    |> Oban.insert()

    :ok
  end

  defp to_notification(%Event{} = event) do
    %{
      id: "event-" <> event.id,
      event_id: event.id,
      severity: String.to_existing_atom(event.severity),
      message: event.message,
      action: event.action,
      durable: true
    }
  end

  defp dedupe_notifications(notifications) do
    notifications
    |> Enum.uniq_by(& &1.id)
  end

  defp add_utilization_alerts(notifications, card_balances) do
    Enum.reduce(card_balances, notifications, fn balance, acc ->
      utilization = Map.get(balance, :utilization_percent)

      identifier =
        balance.account.id ||
          balance.account.name ||
          "card"

      cond do
        is_nil(utilization) ->
          acc

        Decimal.compare(utilization, Decimal.new("95")) == :gt ->
          [
            %{
              id: "utilization-critical-" <> to_string(identifier),
              event_id: nil,
              severity: :critical,
              message: "#{balance.account.name} utilisation is above 95%.",
              action: "Review spending",
              durable: false
            }
            | acc
          ]

        Decimal.compare(utilization, Decimal.new("80")) == :gt ->
          [
            %{
              id: "utilization-" <> to_string(identifier),
              event_id: nil,
              severity: :warning,
              message:
                "#{balance.account.name} utilisation is above 80%. Consider a payment soon.",
              action: "Make a payment",
              durable: false
            }
            | acc
          ]

        true ->
          acc
      end
    end)
  end

  defp add_budget_alerts(notifications, budgets) do
    Enum.reduce(budgets, notifications, fn budget, acc ->
      case budget.status do
        :over ->
          [
            %{
              id: "budget-over-" <> budget.name,
              event_id: nil,
              severity: :warning,
              message: "#{budget.name} budget exceeded for this #{budget.period}.",
              action: "Adjust spending",
              durable: false
            }
            | acc
          ]

        :approaching ->
          [
            %{
              id: "budget-approaching-" <> budget.name,
              event_id: nil,
              severity: :info,
              message: "#{budget.name} budget is nearing its limit.",
              action: nil,
              durable: false
            }
            | acc
          ]

        _ ->
          acc
      end
    end)
  end

  defp add_autopay_alerts(notifications, loans) do
    Enum.reduce(loans, notifications, fn loan, acc ->
      autopay = loan.autopay

      identifier = loan.account.id || loan.account.name || "loan"

      if autopay.enabled? do
        acc
      else
        [
          %{
            id: "loan-autopay-" <> to_string(identifier),
            event_id: nil,
            severity: :warning,
            message: "Autopay is disabled for #{loan.account.name}.",
            action: "Enable autopay",
            durable: false
          }
          | acc
        ]
      end
    end)
  end

  defp add_subscription_digest(notifications, %{monthly_total_decimal: total} = summary) do
    if Decimal.compare(total, Decimal.new("0")) == :gt do
      [
        %{
          id: "subscription-digest",
          event_id: nil,
          severity: :info,
          message:
            "Subscription spend this month: #{summary.monthly_total} (annualised #{summary.annual_projection}).",
          action: nil,
          durable: false
        }
        | notifications
      ]
    else
      notifications
    end
  end

  defp add_subscription_digest(notifications, _summary), do: notifications

  defp add_recurring_anomalies(notifications, anomalies) do
    Enum.reduce(anomalies, notifications, fn anomaly, acc ->
      severity =
        case anomaly.severity do
          "critical" -> :critical
          "warning" -> :warning
          _ -> :info
        end

      [
        %{
          id: "recurring-#{anomaly.id}",
          event_id: nil,
          severity: severity,
          message: recurring_message(anomaly),
          action: "Review recurring spend",
          durable: false
        }
        | acc
      ]
    end)
  end

  defp recurring_message(%{anomaly_type: "missing_cycle", series: series}) do
    "Expected recurring transaction is missing for #{series.fingerprint}."
  end

  defp recurring_message(%{anomaly_type: "late_cycle", series: series}) do
    "Recurring transaction appears late for #{series.fingerprint}."
  end

  defp recurring_message(%{anomaly_type: "unusual_amount", series: series}) do
    "Recurring transaction amount is unusual for #{series.fingerprint}."
  end

  defp recurring_message(_), do: "Recurring transaction anomaly detected."

  defp normalize_override_map(nil), do: %{}

  defp normalize_override_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      case normalize_override_key(key) do
        nil -> acc
        atom_key -> Map.put(acc, atom_key, value)
      end
    end)
  end

  defp normalize_override_map(_other), do: %{}

  defp normalize_override_key(key) when is_atom(key), do: key

  defp normalize_override_key(key) when is_binary(key) do
    normalized = String.trim(key)

    cond do
      normalized == "" ->
        nil

      true ->
        try do
          String.to_existing_atom(normalized)
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp normalize_string_key_map(map) do
    Enum.into(map, %{}, fn {key, value} -> {to_string(key), value} end)
  end

  defp resolve_user_id(%{id: id}) when is_binary(id), do: id
  defp resolve_user_id(user_id) when is_binary(user_id), do: user_id

  defp ensure_fallback([]),
    do: [
      %{
        id: "all-clear",
        event_id: nil,
        severity: :info,
        message: "You're all caught up!",
        action: nil,
        durable: false
      }
    ]

  defp ensure_fallback(notifications), do: Enum.reverse(notifications)
end
