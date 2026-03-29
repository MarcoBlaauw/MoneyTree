defmodule MoneyTree.Recurring.Anomaly do
  @moduledoc """
  Detectable deviations from expected recurring transaction behavior.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Recurring.Series

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @anomaly_types ~w(missing_cycle late_cycle unusual_amount)
  @statuses ~w(open resolved)
  @severities ~w(info warning critical)

  schema "recurring_anomalies" do
    field :anomaly_type, :string
    field :status, :string, default: "open"
    field :severity, :string, default: "warning"
    field :occurred_on, :date
    field :details, :map, default: %{}
    field :detected_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec

    belongs_to :series, Series

    timestamps()
  end

  def changeset(anomaly, attrs) do
    anomaly
    |> cast(attrs, [
      :series_id,
      :anomaly_type,
      :status,
      :severity,
      :occurred_on,
      :details,
      :detected_at,
      :resolved_at
    ])
    |> validate_required([:series_id, :anomaly_type, :status, :severity, :occurred_on, :detected_at])
    |> validate_inclusion(:anomaly_type, @anomaly_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:severity, @severities)
    |> foreign_key_constraint(:series_id)
    |> unique_constraint(:occurred_on,
      name: :recurring_anomalies_series_type_occurred_on_index,
      message: "already recorded"
    )
  end
end
