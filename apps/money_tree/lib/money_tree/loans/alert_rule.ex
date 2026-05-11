defmodule MoneyTree.Loans.AlertRule do
  @moduledoc """
  User-configured Loan Center alert rule.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Mortgages.Mortgage
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @kinds ~w(
    rate_below_threshold
    monthly_payment_below_threshold
    monthly_savings_above_threshold
    break_even_below_months
    full_term_cost_savings_above_threshold
    expected_horizon_savings_above_threshold
    lender_quote_expiring
    document_review_needed
  )

  schema "loan_alert_rules" do
    field :loan_id, :binary_id
    field :name, :string
    field :kind, :string
    field :active, :boolean, default: true
    field :threshold_config, :map, default: %{}
    field :delivery_preferences, :map, default: %{}
    field :last_evaluated_at, :utc_datetime_usec
    field :last_triggered_at, :utc_datetime_usec

    belongs_to :user, User
    belongs_to :mortgage, Mortgage

    timestamps()
  end

  @doc false
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :user_id,
      :mortgage_id,
      :loan_id,
      :name,
      :kind,
      :active,
      :threshold_config,
      :delivery_preferences,
      :last_evaluated_at,
      :last_triggered_at
    ])
    |> validate_required([:user_id, :mortgage_id, :name, :kind, :active])
    |> put_default_map(:threshold_config)
    |> put_default_map(:delivery_preferences)
    |> update_change(:kind, &normalize_downcase/1)
    |> validate_length(:name, min: 1, max: 160)
    |> validate_inclusion(:kind, @kinds)
    |> validate_map(:threshold_config)
    |> validate_map(:delivery_preferences)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:mortgage_id)
  end

  def kinds, do: @kinds

  defp put_default_map(changeset, field) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, %{})
      _value -> changeset
    end
  end

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end

  defp normalize_downcase(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_downcase(value), do: value
end
