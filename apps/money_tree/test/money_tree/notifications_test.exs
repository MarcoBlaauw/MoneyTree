defmodule MoneyTree.NotificationsTest do
  use MoneyTree.DataCase, async: false

  import MoneyTree.AccountsFixtures
  import MoneyTree.ObligationsFixtures

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Notifications.DeliveryAttempt
  alias MoneyTree.Notifications.Event
  alias MoneyTree.Notifications
  alias MoneyTree.Repo
  alias MoneyTree.Transactions.Transaction

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
