defmodule MoneyTree.Notifications.Event do
  @moduledoc """
  Durable notification event shown on the dashboard and used for delivery.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Notifications.DeliveryAttempt
  alias MoneyTree.Obligations.Obligation
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @kinds ~w(payment_obligation loan_refinance_alert)
  @statuses ~w(
    upcoming
    due_today
    overdue
    recovered
    triggered
    rate_below_threshold
    monthly_payment_below_threshold
    monthly_savings_above_threshold
    break_even_below_months
    full_term_cost_savings_above_threshold
    expected_horizon_savings_above_threshold
    lender_quote_expiring
    document_review_needed
  )
  @severities ~w(info warning critical)
  @delivery_statuses ~w(pending delivered failed suppressed)

  schema "notification_events" do
    field :kind, :string
    field :status, :string
    field :severity, :string
    field :title, :string
    field :message, :string
    field :action, :string
    field :event_date, :date
    field :occurred_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    field :metadata, :map, default: %{}
    field :dedupe_key, :string
    field :delivery_status, :string, default: "pending"
    field :last_delivered_at, :utc_datetime_usec
    field :next_delivery_at, :utc_datetime_usec
    field :delivery_attempt_count, :integer, default: 0
    field :last_delivery_error, :string

    belongs_to :user, User
    belongs_to :obligation, Obligation

    has_many :delivery_attempts, DeliveryAttempt

    timestamps()
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :kind,
      :status,
      :severity,
      :title,
      :message,
      :action,
      :event_date,
      :occurred_at,
      :resolved_at,
      :metadata,
      :dedupe_key,
      :delivery_status,
      :last_delivered_at,
      :next_delivery_at,
      :delivery_attempt_count,
      :last_delivery_error,
      :user_id,
      :obligation_id
    ])
    |> validate_required([
      :kind,
      :status,
      :severity,
      :title,
      :message,
      :occurred_at,
      :dedupe_key,
      :delivery_status,
      :user_id
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:severity, @severities)
    |> validate_inclusion(:delivery_status, @delivery_statuses)
    |> validate_length(:title, min: 1, max: 160)
    |> validate_length(:message, min: 1, max: 2_000)
    |> validate_change(:metadata, fn :metadata, value ->
      if is_map(value), do: [], else: [metadata: "must be a map"]
    end)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:obligation_id)
    |> unique_constraint(:dedupe_key)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses
  def delivery_statuses, do: @delivery_statuses
end
