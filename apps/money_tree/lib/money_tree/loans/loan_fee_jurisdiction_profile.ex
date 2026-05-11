defmodule MoneyTree.Loans.LoanFeeJurisdictionProfile do
  @moduledoc """
  State or local profile that can narrow modeled loan fee ranges.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.Loans.LoanFeeJurisdictionRule

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @confidence_levels ~w(very_low low moderate high verified)

  schema "loan_fee_jurisdiction_profiles" do
    field :country_code, :string, default: "US"
    field :state_code, :string
    field :county_or_parish, :string
    field :municipality, :string
    field :loan_type, :string
    field :transaction_type, :string
    field :confidence_level, :string, default: "low"
    field :confidence_score, :decimal
    field :source_label, :string
    field :source_url, :string
    field :last_verified_at, :utc_datetime_usec
    field :notes, :string
    field :enabled, :boolean, default: true

    has_many :rules, LoanFeeJurisdictionRule, foreign_key: :jurisdiction_profile_id

    timestamps()
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :country_code,
      :state_code,
      :county_or_parish,
      :municipality,
      :loan_type,
      :transaction_type,
      :confidence_level,
      :confidence_score,
      :source_label,
      :source_url,
      :last_verified_at,
      :notes,
      :enabled
    ])
    |> validate_required([
      :country_code,
      :loan_type,
      :transaction_type,
      :confidence_level,
      :enabled
    ])
    |> update_change(:country_code, &normalize_country/1)
    |> update_change(:state_code, &normalize_upper/1)
    |> update_change(:loan_type, &normalize_key/1)
    |> update_change(:transaction_type, &normalize_key/1)
    |> update_change(:confidence_level, &normalize_key/1)
    |> validate_length(:country_code, is: 2)
    |> validate_length(:state_code, max: 80)
    |> validate_length(:county_or_parish, max: 160)
    |> validate_length(:municipality, max: 160)
    |> validate_inclusion(:confidence_level, @confidence_levels)
    |> validate_confidence_score()
  end

  defp normalize_country(value) when is_binary(value),
    do: value |> String.trim() |> String.upcase()

  defp normalize_country(value), do: value

  defp normalize_upper(nil), do: nil
  defp normalize_upper(value) when is_binary(value), do: value |> String.trim() |> String.upcase()
  defp normalize_upper(value), do: value

  defp normalize_key(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_key(value), do: value

  defp validate_confidence_score(changeset) do
    validate_change(changeset, :confidence_score, fn :confidence_score, value ->
      case Decimal.cast(value) do
        {:ok, decimal} ->
          if Decimal.compare(decimal, Decimal.new("0")) == :lt or
               Decimal.compare(decimal, Decimal.new("1")) == :gt,
             do: [confidence_score: "must be between 0 and 1"],
             else: []

        :error ->
          [confidence_score: "must be a valid decimal number"]
      end
    end)
  end
end
