defmodule MoneyTree.NotificationsTest do
  use MoneyTree.DataCase, async: false

  import MoneyTree.AccountsFixtures
  import MoneyTree.ObligationsFixtures

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Notifications.DeliveryAttempt
  alias MoneyTree.Notifications.Event
  alias MoneyTree.Notifications.DeliveryWorker
  alias MoneyTree.Notifications
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction
  alias Oban.Job

  defmodule TestDestinationResolver do
    @behaviour MoneyTree.Notifications.DestinationResolver

    alias MoneyTree.Users.User

    @impl true
    def resolve(%User{}, :sms, _opts), do: {:ok, %{phone_number: "+15551234567"}}

    def resolve(%User{}, :push, _opts), do: {:ok, %{device_token: "push-device-token"}}
  end

  defmodule TestSMSAdapter do
    @behaviour MoneyTree.Notifications.Adapter

    alias MoneyTree.Notifications.Event
    alias MoneyTree.Users.User

    @impl true
    def channel, do: :sms

    @impl true
    def deliver(%Event{}, %User{}, opts) do
      {:ok,
       %{
         provider_reference: "sms-message-123",
         provider_adapter: inspect(__MODULE__),
         destination: Keyword.fetch!(opts, :destination)
       }}
    end
  end

  defmodule TestPushAdapter do
    @behaviour MoneyTree.Notifications.Adapter

    alias MoneyTree.Notifications.Event
    alias MoneyTree.Users.User

    @impl true
    def channel, do: :push

    @impl true
    def deliver(%Event{}, %User{}, opts) do
      {:ok,
       %{
         provider_reference: "push-message-123",
         provider_adapter: inspect(__MODULE__),
         destination: Keyword.fetch!(opts, :destination)
       }}
    end
  end

  defmodule TestRetryableSMSAdapter do
    @behaviour MoneyTree.Notifications.Adapter

    alias MoneyTree.Notifications.Event
    alias MoneyTree.Users.User

    @impl true
    def channel, do: :sms

    @impl true
    def deliver(%Event{}, %User{}, _opts), do: {:error, :timeout}
  end

  defmodule TestSuppressedSMSAdapter do
    @behaviour MoneyTree.Notifications.Adapter

    alias MoneyTree.Notifications.Event
    alias MoneyTree.Users.User

    @impl true
    def channel, do: :sms

    @impl true
    def deliver(%Event{}, %User{}, _opts), do: {:error, :destination_unavailable}
  end

  test "pending returns fallback when no alerts" do
    user = user_fixture()
    assert [%{message: "You're all caught up!"}] = Notifications.pending(user)
  end

  test "pending includes credit utilization warnings" do
    user = user_fixture()

    card =
      account_fixture(user, %{
        name: "Travel Card",
        type: "credit",
        current_balance: Decimal.new("900.00"),
        available_balance: Decimal.new("50.00"),
        limit: Decimal.new("950.00")
      })

    insert_transaction(card, Decimal.new("100.00"))

    notifications = Notifications.pending(user)
    assert Enum.any?(notifications, &String.contains?(&1.message, "utilisation"))
  end

  test "pending includes durable obligation events" do
    user = user_fixture()
    obligation = obligation_fixture(user, %{creditor_payee: "Travel Card"})

    {:ok, _event} =
      Notifications.record_event(%{
        user_id: user.id,
        obligation_id: obligation.id,
        kind: "payment_obligation",
        status: "overdue",
        severity: "critical",
        title: "Travel Card overdue",
        message: "Travel Card is overdue.",
        action: "Verify payment",
        event_date: ~D[2026-03-15],
        occurred_at: ~U[2026-03-18 00:00:00Z],
        metadata: %{},
        dedupe_key: "test-overdue-event"
      })

    notifications = Notifications.pending(user)
    assert Enum.any?(notifications, &(&1.message == "Travel Card is overdue."))
  end

  test "deliver_event can use the sms application layer with a configured adapter" do
    user = user_fixture()
    obligation = obligation_fixture(user)

    original_resolver = Application.get_env(:money_tree, :notification_destination_resolver)
    original_sms_adapter = Application.get_env(:money_tree, :notification_sms_adapter)

    Application.put_env(
      :money_tree,
      :notification_destination_resolver,
      TestDestinationResolver
    )

    Application.put_env(:money_tree, :notification_sms_adapter, TestSMSAdapter)

    on_exit(fn ->
      Application.put_env(
        :money_tree,
        :notification_destination_resolver,
        original_resolver
      )

      Application.put_env(:money_tree, :notification_sms_adapter, original_sms_adapter)
    end)

    {:ok, _preference} =
      Notifications.upsert_alert_preference(user, %{
        "email_enabled" => false,
        "sms_enabled" => true,
        "push_enabled" => false
      })

    event =
      %Event{}
      |> Event.changeset(%{
        user_id: user.id,
        obligation_id: obligation.id,
        kind: "payment_obligation",
        status: "due_today",
        severity: "warning",
        title: "Travel Card due today",
        message: "Travel Card requires payment today.",
        action: "Pay now",
        event_date: ~D[2026-03-29],
        occurred_at: ~U[2026-03-29 00:00:00Z],
        metadata: %{},
        dedupe_key: "sms-delivery-test"
      })
      |> Repo.insert!()

    assert :ok = Notifications.deliver_event(event.id)

    delivered_event = Repo.get!(Event, event.id)
    assert delivered_event.delivery_status == "delivered"
    assert delivered_event.delivery_attempt_count == 1
    assert delivered_event.last_delivered_at

    attempt = Repo.get_by!(DeliveryAttempt, event_id: event.id, channel: "sms")
    assert attempt.status == "sent"
    assert attempt.provider_reference == "sms-message-123"
  end

  test "deliver_event can use the push application layer with a configured adapter" do
    user = user_fixture()
    obligation = obligation_fixture(user)

    original_resolver = Application.get_env(:money_tree, :notification_destination_resolver)
    original_push_adapter = Application.get_env(:money_tree, :notification_push_adapter)

    Application.put_env(
      :money_tree,
      :notification_destination_resolver,
      TestDestinationResolver
    )

    Application.put_env(:money_tree, :notification_push_adapter, TestPushAdapter)

    on_exit(fn ->
      Application.put_env(
        :money_tree,
        :notification_destination_resolver,
        original_resolver
      )

      Application.put_env(:money_tree, :notification_push_adapter, original_push_adapter)
    end)

    {:ok, _preference} =
      Notifications.upsert_alert_preference(user, %{
        "email_enabled" => false,
        "sms_enabled" => false,
        "push_enabled" => true
      })

    event =
      %Event{}
      |> Event.changeset(%{
        user_id: user.id,
        obligation_id: obligation.id,
        kind: "payment_obligation",
        status: "upcoming",
        severity: "info",
        title: "Travel Card due soon",
        message: "Travel Card is due soon.",
        action: "Schedule payment",
        event_date: ~D[2026-03-31],
        occurred_at: ~U[2026-03-29 00:00:00Z],
        metadata: %{},
        dedupe_key: "push-delivery-test"
      })
      |> Repo.insert!()

    assert :ok = Notifications.deliver_event(event.id)

    delivered_event = Repo.get!(Event, event.id)
    assert delivered_event.delivery_status == "delivered"

    attempt = Repo.get_by!(DeliveryAttempt, event_id: event.id, channel: "push")
    assert attempt.status == "sent"
    assert attempt.provider_reference == "push-message-123"
  end

  test "deliver_event marks retryable failures for later delivery attempts" do
    user = user_fixture()
    obligation = obligation_fixture(user)

    original_resolver = Application.get_env(:money_tree, :notification_destination_resolver)
    original_sms_adapter = Application.get_env(:money_tree, :notification_sms_adapter)

    Application.put_env(
      :money_tree,
      :notification_destination_resolver,
      TestDestinationResolver
    )

    Application.put_env(:money_tree, :notification_sms_adapter, TestRetryableSMSAdapter)

    on_exit(fn ->
      Application.put_env(
        :money_tree,
        :notification_destination_resolver,
        original_resolver
      )

      Application.put_env(:money_tree, :notification_sms_adapter, original_sms_adapter)
    end)

    {:ok, _preference} =
      Notifications.upsert_alert_preference(user, %{
        "email_enabled" => false,
        "sms_enabled" => true,
        "push_enabled" => false,
        "resend_interval_hours" => 1,
        "max_resends" => 2
      })

    event =
      %Event{}
      |> Event.changeset(%{
        user_id: user.id,
        obligation_id: obligation.id,
        kind: "payment_obligation",
        status: "overdue",
        severity: "critical",
        title: "Retryable delivery event",
        message: "Retry needed for outbound notification.",
        event_date: ~D[2026-04-03],
        occurred_at: ~U[2026-04-03 12:00:00Z],
        metadata: %{},
        dedupe_key: "retryable-delivery-test"
      })
      |> Repo.insert!()

    assert {:error, :delivery_failed} = Notifications.deliver_event(event.id)

    failed_event = Repo.get!(Event, event.id)
    assert failed_event.delivery_status == "failed"
    assert failed_event.delivery_attempt_count == 1
    assert failed_event.next_delivery_at
    assert failed_event.last_delivery_error =~ ":timeout"

    attempt = Repo.get_by!(DeliveryAttempt, event_id: event.id, channel: "sms")
    assert attempt.status == "failed"
    assert attempt.error_message =~ ":timeout"

    assert :discard = DeliveryWorker.perform(%Job{args: %{"event_id" => event.id}})
  end

  test "deliver_event suppresses permanent failures without retry scheduling" do
    user = user_fixture()
    obligation = obligation_fixture(user)

    original_resolver = Application.get_env(:money_tree, :notification_destination_resolver)
    original_sms_adapter = Application.get_env(:money_tree, :notification_sms_adapter)

    Application.put_env(
      :money_tree,
      :notification_destination_resolver,
      TestDestinationResolver
    )

    Application.put_env(:money_tree, :notification_sms_adapter, TestSuppressedSMSAdapter)

    on_exit(fn ->
      Application.put_env(
        :money_tree,
        :notification_destination_resolver,
        original_resolver
      )

      Application.put_env(:money_tree, :notification_sms_adapter, original_sms_adapter)
    end)

    {:ok, _preference} =
      Notifications.upsert_alert_preference(user, %{
        "email_enabled" => false,
        "sms_enabled" => true,
        "push_enabled" => false
      })

    event =
      %Event{}
      |> Event.changeset(%{
        user_id: user.id,
        obligation_id: obligation.id,
        kind: "payment_obligation",
        status: "due_today",
        severity: "warning",
        title: "Permanent failure event",
        message: "Destination is permanently unavailable.",
        event_date: ~D[2026-04-03],
        occurred_at: ~U[2026-04-03 12:30:00Z],
        metadata: %{},
        dedupe_key: "suppressed-delivery-test"
      })
      |> Repo.insert!()

    assert {:error, :suppressed} = Notifications.deliver_event(event.id)

    suppressed_event = Repo.get!(Event, event.id)
    assert suppressed_event.delivery_status == "suppressed"
    assert is_nil(suppressed_event.next_delivery_at)

    attempt = Repo.get_by!(DeliveryAttempt, event_id: event.id, channel: "sms")
    assert attempt.status == "suppressed"
    assert attempt.error_message =~ ":destination_unavailable"
  end

  test "deliver_event suppresses when max resends are exhausted" do
    user = user_fixture()
    obligation = obligation_fixture(user)

    {:ok, _preference} =
      Notifications.upsert_alert_preference(user, %{
        "email_enabled" => false,
        "sms_enabled" => true,
        "push_enabled" => false,
        "max_resends" => 0
      })

    event =
      %Event{}
      |> Event.changeset(%{
        user_id: user.id,
        obligation_id: obligation.id,
        kind: "payment_obligation",
        status: "overdue",
        severity: "critical",
        title: "Exhausted retries event",
        message: "No retry attempts should remain.",
        event_date: ~D[2026-04-03],
        occurred_at: ~U[2026-04-03 13:00:00Z],
        metadata: %{},
        dedupe_key: "resend-exhaustion-test",
        delivery_attempt_count: 1
      })
      |> Repo.insert!()

    assert {:error, :max_resends_exhausted} = Notifications.deliver_event(event.id)

    exhausted_event = Repo.get!(Event, event.id)
    assert exhausted_event.delivery_status == "suppressed"
    assert exhausted_event.last_delivery_error =~ "maximum resend attempts exhausted"
    assert is_nil(exhausted_event.next_delivery_at)
  end

  test "delivery worker discards not-due and max-resend events" do
    user = user_fixture()
    obligation = obligation_fixture(user)

    {:ok, _preference} =
      Notifications.upsert_alert_preference(user, %{
        "email_enabled" => false,
        "sms_enabled" => true,
        "push_enabled" => false,
        "max_resends" => 0
      })

    future_event =
      %Event{}
      |> Event.changeset(%{
        user_id: user.id,
        obligation_id: obligation.id,
        kind: "payment_obligation",
        status: "upcoming",
        severity: "info",
        title: "Future event",
        message: "Scheduled for later delivery.",
        event_date: ~D[2026-04-04],
        occurred_at: ~U[2026-04-03 14:00:00Z],
        metadata: %{},
        dedupe_key: "worker-not-due-test",
        next_delivery_at:
          DateTime.add(DateTime.utc_now() |> DateTime.truncate(:microsecond), 600, :second)
      })
      |> Repo.insert!()

    exhausted_event =
      %Event{}
      |> Event.changeset(%{
        user_id: user.id,
        obligation_id: obligation.id,
        kind: "payment_obligation",
        status: "overdue",
        severity: "critical",
        title: "Already exhausted event",
        message: "Retry limit was already exceeded.",
        event_date: ~D[2026-04-03],
        occurred_at: ~U[2026-04-03 14:05:00Z],
        metadata: %{},
        dedupe_key: "worker-max-resend-test",
        delivery_attempt_count: 1
      })
      |> Repo.insert!()

    assert :discard = DeliveryWorker.perform(%Job{args: %{"event_id" => future_event.id}})
    assert :discard = DeliveryWorker.perform(%Job{args: %{"event_id" => exhausted_event.id}})

    future_state = Repo.get!(Event, future_event.id)
    assert future_state.delivery_status == "pending"
    assert future_state.delivery_attempt_count == 0
    assert future_state.next_delivery_at

    exhausted_state = Repo.get!(Event, exhausted_event.id)
    assert exhausted_state.delivery_status == "suppressed"
    assert exhausted_state.delivery_attempt_count == 1
    assert exhausted_state.last_delivery_error =~ "maximum resend attempts exhausted"
  end

  defp insert_transaction(%Account{} = account, amount) do
    params = %{
      external_id: System.unique_integer([:positive]) |> Integer.to_string(),
      amount: amount,
      currency: account.currency,
      type: "card",
      posted_at: DateTime.utc_now(),
      description: "Spend",
      status: "posted",
      account_id: account.id
    }

    %Transaction{}
    |> Transaction.changeset(params)
    |> Repo.insert!()
  end
end
