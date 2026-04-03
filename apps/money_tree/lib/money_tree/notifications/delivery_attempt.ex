defmodule MoneyTree.Notifications.DeliveryAttempt do
  @moduledoc """
  Audit trail of outbound notification delivery attempts.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Notifications.Event

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(sent failed suppressed)

  schema "notification_delivery_attempts" do
    field :channel, :string
    field :adapter, :string
    field :status, :string
    field :idempotency_key, :string
    field :attempted_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec
    field :provider_reference, :string
    field :error_message, :string
    field :metadata, :map, default: %{}

    belongs_to :event, Event

    timestamps()
  end

  @doc false
  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :channel,
      :adapter,
      :status,
      :idempotency_key,
      :attempted_at,
      :delivered_at,
      :provider_reference,
      :error_message,
      :metadata,
      :event_id
    ])
    |> validate_required([
      :channel,
      :adapter,
      :status,
      :idempotency_key,
      :attempted_at,
      :metadata,
      :event_id
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_change(:metadata, fn :metadata, value ->
      if is_map(value), do: [], else: [metadata: "must be a map"]
    end)
    |> foreign_key_constraint(:event_id)
    |> unique_constraint(:idempotency_key)
  end
end
