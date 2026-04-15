defmodule MoneyTree.Recurring.Series do
  @moduledoc """
  Recurring transaction series inferred from historical transaction clusters.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Accounts.Account
  alias MoneyTree.Transactions.Transaction
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @cadences ~w(weekly biweekly monthly custom)
  @statuses ~w(active tentative inactive)

  schema "recurring_series" do
    field :fingerprint, :string
    field :series_key, :string
    field :cadence, :string, default: "custom"
    field :cadence_days, :integer
    field :expected_window_days, :integer, default: 3
    field :expected_amount_min, :decimal
    field :expected_amount_max, :decimal
    field :confidence, :decimal, default: Decimal.new("0")
    field :status, :string, default: "active"
    field :last_seen_at, :utc_datetime_usec
    field :next_expected_at, :utc_datetime_usec

    belongs_to :user, User
    belongs_to :account, Account
    belongs_to :last_transaction, Transaction

    timestamps()
  end

  def changeset(series, attrs) do
    series
    |> cast(attrs, [
      :user_id,
      :account_id,
      :last_transaction_id,
      :fingerprint,
      :series_key,
      :cadence,
      :cadence_days,
      :expected_window_days,
      :expected_amount_min,
      :expected_amount_max,
      :confidence,
      :status,
      :last_seen_at,
      :next_expected_at
    ])
    |> validate_required([:user_id, :account_id, :fingerprint, :series_key, :cadence, :status])
    |> validate_inclusion(:cadence, @cadences)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:expected_window_days,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 14
    )
    |> validate_number(:cadence_days, greater_than_or_equal_to: 1, less_than_or_equal_to: 180)
    |> validate_length(:fingerprint, max: 255)
    |> validate_length(:series_key, max: 400)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:last_transaction_id)
    |> unique_constraint(:series_key, name: :recurring_series_user_id_series_key_index)
  end
end
