defmodule MoneyTree.Assets.AssetValuation do
  @moduledoc """
  An immutable point-in-time valuation snapshot for a tangible asset.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.Assets.Asset
  alias MoneyTree.Currency

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @sources ~w(manual provider)
  @confidences ~w(low medium high)

  schema "asset_valuations" do
    field :amount, :decimal
    field :currency, :string
    field :source, :string
    field :provider_key, :string
    field :valued_on, :date
    field :confidence, :string
    field :manually_overridden, :boolean, default: false
    field :mileage, :integer
    field :value_low, :decimal
    field :value_high, :decimal
    field :raw_response, :map

    belongs_to :asset, Asset

    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}

  def changeset(valuation, attrs) do
    valuation
    |> cast(attrs, [
      :asset_id,
      :amount,
      :currency,
      :source,
      :provider_key,
      :valued_on,
      :confidence,
      :manually_overridden,
      :mileage,
      :value_low,
      :value_high,
      :raw_response
    ])
    |> update_change(:currency, &normalize_currency/1)
    |> update_change(:source, &normalize_downcase/1)
    |> update_change(:confidence, &normalize_downcase/1)
    |> validate_required([:asset_id, :amount, :currency, :source, :valued_on])
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:confidence, @confidences)
    |> validate_currency()
    |> validate_number(:amount, greater_than_or_equal_to: 0)
    |> validate_number(:value_low, greater_than_or_equal_to: 0)
    |> validate_number(:value_high, greater_than_or_equal_to: 0)
    |> validate_number(:mileage, greater_than_or_equal_to: 0)
    |> validate_provider_key()
    |> validate_value_range()
    |> foreign_key_constraint(:asset_id)
  end

  def sources, do: @sources
  def confidences, do: @confidences

  defp normalize_currency(value) when is_binary(value),
    do: value |> String.trim() |> String.upcase()

  defp normalize_currency(value), do: value

  defp normalize_downcase(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_downcase(value), do: value

  defp validate_currency(changeset) do
    validate_change(changeset, :currency, fn :currency, value ->
      if Currency.valid_code?(value),
        do: [],
        else: [currency: "must be a valid ISO 4217 currency code"]
    end)
  end

  defp validate_provider_key(changeset) do
    if get_field(changeset, :source) == "provider" and
         get_field(changeset, :provider_key) in [nil, ""] do
      add_error(changeset, :provider_key, "is required for provider valuations")
    else
      changeset
    end
  end

  defp validate_value_range(changeset) do
    low = get_field(changeset, :value_low)
    high = get_field(changeset, :value_high)
    amount = get_field(changeset, :amount)

    changeset
    |> maybe_validate_order(low, high)
    |> maybe_validate_amount_in_range(amount, low, high)
  end

  defp maybe_validate_order(changeset, %Decimal{} = low, %Decimal{} = high) do
    if Decimal.compare(low, high) == :gt,
      do: add_error(changeset, :value_high, "must be greater than or equal to value low"),
      else: changeset
  end

  defp maybe_validate_order(changeset, _low, _high), do: changeset

  defp maybe_validate_amount_in_range(
         changeset,
         %Decimal{} = amount,
         %Decimal{} = low,
         %Decimal{} = high
       ) do
    if Decimal.compare(amount, low) == :lt or Decimal.compare(amount, high) == :gt,
      do: add_error(changeset, :amount, "must be within the valuation range"),
      else: changeset
  end

  defp maybe_validate_amount_in_range(changeset, _amount, _low, _high), do: changeset
end
