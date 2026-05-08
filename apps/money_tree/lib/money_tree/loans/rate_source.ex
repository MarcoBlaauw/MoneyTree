defmodule MoneyTree.Loans.RateSource do
  @moduledoc """
  Source metadata for benchmark or manually entered loan rates.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Loans.RateObservation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @source_types ~w(manual public_benchmark csv_import lender_api aggregator_api)

  schema "loan_rate_sources" do
    field :provider_key, :string
    field :name, :string
    field :source_type, :string, default: "manual"
    field :base_url, :string
    field :enabled, :boolean, default: true
    field :requires_api_key, :boolean, default: false
    field :config, :map, default: %{}
    field :last_success_at, :utc_datetime_usec
    field :last_error_at, :utc_datetime_usec
    field :last_error_message, :string

    has_many :observations, RateObservation

    timestamps()
  end

  @doc false
  def changeset(source, attrs) do
    source
    |> cast(attrs, [
      :provider_key,
      :name,
      :source_type,
      :base_url,
      :enabled,
      :requires_api_key,
      :config,
      :last_success_at,
      :last_error_at,
      :last_error_message
    ])
    |> validate_required([:provider_key, :name, :source_type, :enabled, :requires_api_key])
    |> put_default_map(:config)
    |> update_change(:provider_key, &normalize_key/1)
    |> update_change(:source_type, &normalize_downcase/1)
    |> validate_length(:provider_key, min: 1, max: 120)
    |> validate_length(:name, min: 1, max: 160)
    |> validate_length(:source_type, min: 1, max: 80)
    |> validate_length(:base_url, max: 500)
    |> validate_length(:last_error_message, max: 2_000)
    |> validate_inclusion(:source_type, @source_types)
    |> validate_map(:config)
    |> unique_constraint(:provider_key)
  end

  def source_types, do: @source_types

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
end
