defmodule MoneyTree.Assets.Asset do
  @moduledoc """
  Represents a tangible asset tracked for net worth calculations.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Decimal
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Currency

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "assets" do
    field :name, :string
    field :type, :string
    field :valuation_amount, :decimal, default: Decimal.new("0")
    field :valuation_currency, :string
    field :valuation_date, :date
    field :ownership, :string
    field :location, :string
    field :documents, {:array, :string}, default: []
    field :notes, :string
    field :metadata, :map, default: %{}

    belongs_to :account, Account

    timestamps()
  end

  @doc false
  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [
      :name,
      :type,
      :valuation_amount,
      :valuation_currency,
      :valuation_date,
      :ownership,
      :location,
      :documents,
      :notes,
      :metadata,
      :account_id
    ])
    |> validate_required([
      :name,
      :type,
      :valuation_amount,
      :valuation_currency,
      :account_id
    ])
    |> validate_length(:name, min: 1, max: 160)
    |> validate_length(:type, min: 1, max: 80)
    |> validate_length(:ownership, max: 160)
    |> validate_length(:location, max: 160)
    |> validate_length(:notes, max: 1_000)
    |> normalize_currency(:valuation_currency)
    |> validate_currency(:valuation_currency)
    |> validate_decimal(:valuation_amount)
    |> validate_documents()
    |> foreign_key_constraint(:account_id)
  end

  defp normalize_currency(changeset, field) do
    update_change(changeset, field, fn
      nil -> nil
      currency -> currency |> String.trim() |> String.upcase()
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

  defp validate_documents(changeset) do
    validate_change(changeset, :documents, fn :documents, documents ->
      cond do
        is_nil(documents) -> []
        is_list(documents) and Enum.all?(documents, &is_binary/1) -> []
        true -> [documents: "must be a list of document references"]
      end
    end)
  end
end
