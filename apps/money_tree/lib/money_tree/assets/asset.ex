defmodule MoneyTree.Assets.Asset do
  @moduledoc """
  Tangible asset tracked for household net worth reporting.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Assets.AssetValuation
  alias MoneyTree.Assets.ValuationProviderRun
  alias MoneyTree.Assets.VehicleProfile
  alias MoneyTree.Currency
  alias MoneyTree.Loans.Loan
  alias MoneyTree.Mortgages.Mortgage
  alias MoneyTree.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]
  @asset_types ~w(vehicle real_estate equipment collectible other)

  schema "assets" do
    field :name, :string
    field :asset_type, :string
    field :category, :string
    field :valuation_amount, :decimal
    field :valuation_currency, :string
    field :ownership_type, :string
    field :ownership_details, :string
    field :location, :string
    field :notes, :string
    field :acquired_on, :date
    field :last_valued_on, :date
    field :acquisition_cost, :decimal
    field :document_refs, {:array, :string}, default: []
    field :documents_text, :string, virtual: true

    belongs_to :account, Account
    belongs_to :user, User
    belongs_to :linked_loan, Loan
    belongs_to :linked_mortgage, Mortgage

    has_one :vehicle_profile, VehicleProfile
    has_many :valuations, AssetValuation
    has_many :valuation_provider_runs, ValuationProviderRun

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(asset, attrs) do
    asset
    |> maybe_seed_documents_text()
    |> cast(attrs, [
      :account_id,
      :user_id,
      :linked_loan_id,
      :linked_mortgage_id,
      :name,
      :asset_type,
      :category,
      :valuation_amount,
      :valuation_currency,
      :ownership_type,
      :ownership_details,
      :location,
      :notes,
      :acquired_on,
      :last_valued_on,
      :acquisition_cost,
      :document_refs,
      :documents_text
    ])
    |> normalize_document_refs()
    |> validate_required([
      :user_id,
      :name,
      :asset_type,
      :valuation_amount,
      :valuation_currency,
      :ownership_type
    ])
    |> update_change(:valuation_currency, &normalize_currency/1)
    |> validate_currency(:valuation_currency)
    |> validate_decimal(:valuation_amount)
    |> validate_decimal(:acquisition_cost)
    |> validate_length(:name, min: 1, max: 160)
    |> validate_asset_type(asset)
    |> validate_length(:category, max: 120)
    |> validate_length(:ownership_type, min: 1, max: 120)
    |> validate_length(:ownership_details, max: 500)
    |> validate_length(:location, max: 255)
    |> validate_length(:notes, max: 2000)
    |> validate_document_refs()
    |> validate_single_linked_debt()
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:linked_loan_id)
    |> foreign_key_constraint(:linked_mortgage_id)
  end

  def asset_types, do: @asset_types

  defp maybe_seed_documents_text(%__MODULE__{documents_text: text} = asset) when is_binary(text),
    do: asset

  defp maybe_seed_documents_text(%__MODULE__{document_refs: refs} = asset) do
    Map.put(asset, :documents_text, refs |> Enum.join("\n"))
  end

  defp normalize_currency(value) when is_binary(value),
    do: value |> String.trim() |> String.upcase()

  defp normalize_currency(value), do: value

  defp validate_currency(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if Currency.valid_code?(value) do
        []
      else
        [{field, "must be a valid ISO 4217 currency code"}]
      end
    end)
  end

  defp validate_decimal(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        is_nil(value) ->
          []

        match?(%Decimal{}, value) ->
          []

        is_binary(value) or is_number(value) ->
          case Decimal.cast(value) do
            {:ok, _} -> []
            :error -> [{field, "must be a valid decimal number"}]
          end

        true ->
          [{field, "must be a valid decimal number"}]
      end
    end)
  end

  defp normalize_document_refs(%Ecto.Changeset{} = changeset) do
    refs_from_text =
      changeset
      |> get_change(:documents_text)
      |> case do
        nil ->
          nil

        text when is_binary(text) ->
          text
          |> String.split(~r/[\r\n,]+/, trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
      end

    changeset =
      if is_list(refs_from_text) do
        put_change(changeset, :document_refs, refs_from_text)
      else
        changeset
      end

    update_change(changeset, :document_refs, fn
      refs when is_list(refs) ->
        refs
        |> Enum.map(fn
          ref when is_binary(ref) -> String.trim(ref)
          other -> other
        end)
        |> Enum.filter(&is_binary/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      _ ->
        []
    end)
  end

  defp validate_document_refs(%Ecto.Changeset{} = changeset) do
    refs = get_field(changeset, :document_refs, [])

    Enum.reduce(Enum.with_index(refs, 1), changeset, fn {ref, index}, acc ->
      if byte_size(ref) > 255 do
        add_error(acc, :document_refs, "entry #{index} is too long")
      else
        acc
      end
    end)
  end

  defp validate_asset_type(changeset, %__MODULE__{asset_type: existing_type}) do
    allowed_types =
      if existing_type in [nil, ""] or existing_type in @asset_types,
        do: @asset_types,
        else: [existing_type | @asset_types]

    validate_inclusion(changeset, :asset_type, allowed_types)
  end

  defp validate_single_linked_debt(changeset) do
    if get_field(changeset, :linked_loan_id) && get_field(changeset, :linked_mortgage_id) do
      add_error(changeset, :linked_mortgage_id, "cannot be set when a loan is already linked")
    else
      changeset
    end
  end
end
