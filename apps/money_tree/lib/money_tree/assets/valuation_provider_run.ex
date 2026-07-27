defmodule MoneyTree.Assets.ValuationProviderRun do
  @moduledoc """
  Persistent audit and quota record for an external asset-valuation request.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Assets.Asset
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(started ok error rate_limited skipped_budget)

  schema "valuation_provider_runs" do
    field :provider_key, :string
    field :status, :string
    field :error_message, :string
    field :requested_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :request_month, :date
    field :monthly_limit, :integer
    field :monthly_remaining, :integer
    field :request_kind, :string, default: "valuation"
    field :request_fingerprint, :string
    field :response_data, :map

    belongs_to :asset, Asset
    belongs_to :user, User

    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :asset_id,
      :provider_key,
      :status,
      :error_message,
      :requested_at,
      :completed_at,
      :duration_ms,
      :request_month,
      :monthly_limit,
      :monthly_remaining,
      :user_id,
      :request_kind,
      :request_fingerprint,
      :response_data
    ])
    |> validate_required([
      :provider_key,
      :status,
      :requested_at,
      :request_month,
      :monthly_limit,
      :monthly_remaining,
      :request_kind
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> validate_number(:monthly_limit, greater_than: 0, less_than_or_equal_to: 500)
    |> validate_number(:monthly_remaining, greater_than_or_equal_to: 0)
    |> validate_length(:provider_key, max: 80)
    |> validate_length(:request_kind, max: 80)
    |> validate_length(:request_fingerprint, max: 128)
    |> validate_length(:error_message, max: 1000)
    |> validate_subject()
    |> foreign_key_constraint(:asset_id)
    |> foreign_key_constraint(:user_id)
  end

  def statuses, do: @statuses

  defp validate_subject(changeset) do
    if get_field(changeset, :asset_id) || get_field(changeset, :user_id),
      do: changeset,
      else: add_error(changeset, :asset_id, "or user must identify the request owner")
  end
end
