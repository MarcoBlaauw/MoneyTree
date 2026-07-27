defmodule MoneyTree.Assets.VehicleProfile do
  @moduledoc """
  Vehicle-specific identification, condition, and mileage data for an asset.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Assets.Asset
  alias MoneyTree.Encrypted.Binary

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @conditions ~w(excellent good fair poor)
  @vin_pattern ~r/^[A-HJ-NPR-Z0-9]{17}$/

  schema "vehicle_profiles" do
    field :encrypted_vin, Binary
    field :year, :integer
    field :make, :string
    field :model, :string
    field :trim, :string
    field :body_style, :string
    field :mileage, :integer
    field :mileage_as_of, :date
    field :condition, :string
    field :market_region, :string
    field :encrypted_license_plate, Binary
    field :license_plate_state, :string

    belongs_to :asset, Asset

    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :asset_id,
      :encrypted_vin,
      :year,
      :make,
      :model,
      :trim,
      :body_style,
      :mileage,
      :mileage_as_of,
      :condition,
      :market_region,
      :encrypted_license_plate,
      :license_plate_state
    ])
    |> update_change(:encrypted_vin, &normalize_uppercase/1)
    |> update_change(:condition, &normalize_downcase/1)
    |> update_change(:license_plate_state, &normalize_uppercase/1)
    |> validate_required([:asset_id])
    |> validate_format(:encrypted_vin, @vin_pattern,
      message: "must be a 17-character VIN without I, O, or Q"
    )
    |> validate_inclusion(:condition, @conditions)
    |> validate_number(:year, greater_than_or_equal_to: 1886, less_than_or_equal_to: 2200)
    |> validate_number(:mileage, greater_than_or_equal_to: 0)
    |> validate_length(:make, max: 120)
    |> validate_length(:model, max: 120)
    |> validate_length(:trim, max: 120)
    |> validate_length(:body_style, max: 120)
    |> validate_length(:market_region, max: 120)
    |> validate_length(:encrypted_license_plate, max: 32)
    |> validate_length(:license_plate_state, max: 3)
    |> foreign_key_constraint(:asset_id)
    |> unique_constraint(:asset_id)
  end

  def conditions, do: @conditions

  defp normalize_uppercase(value) when is_binary(value),
    do: value |> String.trim() |> String.upcase()

  defp normalize_uppercase(value), do: value

  defp normalize_downcase(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_downcase(value), do: value
end
