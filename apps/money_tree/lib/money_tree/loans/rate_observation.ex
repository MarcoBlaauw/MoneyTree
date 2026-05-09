defmodule MoneyTree.Loans.RateObservation do
  @moduledoc """
  Observed benchmark loan rate that can seed, but not replace, user-confirmed scenarios.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.Loans.RateSource

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "loan_rate_observations" do
    field :provider_key, :string
    field :series_key, :string
    field :loan_type, :string
    field :product_type, :string
    field :term_months, :integer
    field :rate, :decimal
    field :apr, :decimal
    field :points, :decimal
    field :assumptions, :map, default: %{}
    field :source_url, :string
    field :geography, :string
    field :confidence_score, :decimal
    field :notes, :string
    field :effective_date, :date
    field :published_at, :utc_datetime_usec
    field :observed_at, :utc_datetime_usec
    field :imported_at, :utc_datetime_usec
    field :raw_payload, :map, default: %{}

    belongs_to :rate_source, RateSource

    timestamps()
  end

  @doc false
  def changeset(observation, attrs) do
    observation
    |> cast(attrs, [
      :rate_source_id,
      :provider_key,
      :series_key,
      :loan_type,
      :product_type,
      :term_months,
      :rate,
      :apr,
      :points,
      :assumptions,
      :source_url,
      :geography,
      :confidence_score,
      :notes,
      :effective_date,
      :published_at,
      :observed_at,
      :imported_at,
      :raw_payload
    ])
    |> validate_required([
      :rate_source_id,
      :loan_type,
      :term_months,
      :rate,
      :observed_at,
      :imported_at
    ])
    |> put_effective_date()
    |> validate_required([:effective_date])
    |> put_default_map(:assumptions)
    |> put_default_map(:raw_payload)
    |> update_change(:loan_type, &normalize_downcase/1)
    |> update_change(:provider_key, &normalize_key/1)
    |> update_change(:series_key, &normalize_key/1)
    |> validate_length(:provider_key, max: 160)
    |> validate_length(:series_key, max: 160)
    |> validate_length(:loan_type, min: 1, max: 80)
    |> validate_length(:product_type, max: 120)
    |> validate_length(:source_url, max: 500)
    |> validate_length(:geography, max: 120)
    |> validate_length(:notes, max: 2_000)
    |> validate_number(:term_months, greater_than: 0)
    |> validate_non_negative_decimal(:rate)
    |> validate_non_negative_decimal(:apr)
    |> validate_non_negative_decimal(:points)
    |> validate_non_negative_decimal(:confidence_score)
    |> validate_number(:confidence_score, less_than_or_equal_to: 1)
    |> validate_map(:assumptions)
    |> validate_map(:raw_payload)
    |> foreign_key_constraint(:rate_source_id)
    |> unique_constraint(:effective_date,
      name: :loan_rate_observations_source_series_effective_date_index
    )
  end

  defp put_default_map(changeset, field) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, %{})
      _value -> changeset
    end
  end

  defp put_effective_date(changeset) do
    case get_field(changeset, :effective_date) do
      %Date{} ->
        changeset

      _value ->
        case get_field(changeset, :observed_at) do
          %DateTime{} = observed_at ->
            put_change(changeset, :effective_date, DateTime.to_date(observed_at))

          _value ->
            changeset
        end
    end
  end

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end

  defp normalize_key(nil), do: nil

  defp normalize_key(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_key(value), do: value

  defp normalize_downcase(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_downcase(value), do: value

  defp validate_non_negative_decimal(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case cast_decimal(value) do
        {:ok, nil} ->
          []

        {:ok, decimal} ->
          if Decimal.compare(decimal, Decimal.new("0")) == :lt do
            [{field, "must be greater than or equal to 0"}]
          else
            []
          end

        :error ->
          [{field, "must be a valid decimal number"}]
      end
    end)
  end

  defp cast_decimal(nil), do: {:ok, nil}
  defp cast_decimal(%Decimal{} = decimal), do: {:ok, decimal}

  defp cast_decimal(value) when is_binary(value) or is_number(value) do
    Decimal.cast(value)
  end

  defp cast_decimal(_value), do: :error
end
