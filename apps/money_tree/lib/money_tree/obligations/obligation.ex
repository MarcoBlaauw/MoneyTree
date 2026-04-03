defmodule MoneyTree.Obligations.Obligation do
  @moduledoc """
  Persisted payment obligation with due-date and alerting metadata.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Currency
  alias MoneyTree.Notifications.Event
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @due_rules ~w(calendar_day last_day_of_month)

  schema "obligations" do
    field :creditor_payee, :string
    field :due_day, :integer
    field :due_rule, :string, default: "calendar_day"
    field :minimum_due_amount, :decimal
    field :currency, :string
    field :grace_period_days, :integer, default: 0
    field :alert_preferences, :map, default: %{}
    field :active, :boolean, default: true

    belongs_to :user, User
    belongs_to :linked_funding_account, Account

    has_many :notification_events, Event

    timestamps()
  end

  @doc false
  def changeset(obligation, attrs) do
    obligation
    |> cast(attrs, [
      :creditor_payee,
      :due_day,
      :due_rule,
      :minimum_due_amount,
      :currency,
      :grace_period_days,
      :alert_preferences,
      :active,
      :user_id,
      :linked_funding_account_id
    ])
    |> validate_required([
      :creditor_payee,
      :due_rule,
      :minimum_due_amount,
      :currency,
      :grace_period_days,
      :user_id,
      :linked_funding_account_id
    ])
    |> update_change(:currency, &normalize_currency/1)
    |> validate_length(:creditor_payee, min: 1, max: 160)
    |> validate_inclusion(:due_rule, @due_rules)
    |> validate_due_day()
    |> validate_number(:grace_period_days, greater_than_or_equal_to: 0, less_than_or_equal_to: 31)
    |> validate_decimal(:minimum_due_amount, min: Decimal.new("0.01"))
    |> validate_alert_preferences()
    |> validate_currency(:currency)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:linked_funding_account_id)
    |> check_constraint(:due_day, name: :obligations_due_day_check)
    |> check_constraint(:grace_period_days, name: :obligations_grace_period_days_check)
  end

  def due_rules, do: @due_rules

  defp validate_due_day(changeset) do
    due_rule = get_field(changeset, :due_rule)
    due_day = get_field(changeset, :due_day)

    case {due_rule, due_day} do
      {"calendar_day", day} when is_integer(day) and day >= 1 and day <= 31 ->
        changeset

      {"calendar_day", _other} ->
        add_error(changeset, :due_day, "must be between 1 and 31")

      {"last_day_of_month", nil} ->
        changeset

      {"last_day_of_month", _other} ->
        add_error(changeset, :due_day, "must be blank when rule is last_day_of_month")

      _ ->
        changeset
    end
  end

  defp validate_alert_preferences(changeset) do
    validate_change(changeset, :alert_preferences, fn :alert_preferences, value ->
      if is_map(value) do
        []
      else
        [alert_preferences: "must be a map"]
      end
    end)
  end

  defp validate_currency(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if Currency.valid_code?(value) do
        []
      else
        [{field, "must be a valid ISO 4217 currency code"}]
      end
    end)
  end

  defp normalize_currency(currency) when is_binary(currency) do
    currency
    |> String.trim()
    |> String.upcase()
  end

  defp normalize_currency(other), do: other

  defp validate_decimal(changeset, field, opts) do
    validate_change(changeset, field, fn ^field, value ->
      case cast_decimal(value) do
        {:ok, decimal} ->
          validate_decimal_constraints(decimal, field, opts)

        :error ->
          [{field, "must be a valid decimal number"}]
      end
    end)
  end

  defp cast_decimal(%Decimal{} = decimal), do: {:ok, decimal}

  defp cast_decimal(value) when is_binary(value) or is_number(value) do
    Decimal.cast(value)
  end

  defp cast_decimal(_value), do: :error

  defp validate_decimal_constraints(decimal, field, opts) do
    min = Keyword.get(opts, :min)

    if min && Decimal.compare(decimal, min) == :lt do
      [{field, "must be greater than or equal to #{Decimal.to_string(min)}"}]
    else
      []
    end
  end
end
