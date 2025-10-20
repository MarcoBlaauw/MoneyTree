defmodule MoneyTree.Assets.Asset do
  @moduledoc """
  Tangible asset tracked for household net worth reporting.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MoneyTree.Accounts.Account
  alias MoneyTree.Currency
  alias Decimal

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

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
    field :document_refs, {:array, :string}, default: []
    field :documents_text, :string, virtual: true

    belongs_to :account, Account

    timestamps()
  end

  @doc false
  def changeset(asset, attrs) do
    asset
    |> maybe_seed_documents_text()
    |> cast(attrs, [
      :account_id,
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
      :document_refs,
      :documents_text
    ])
    |> normalize_document_refs()
    |> validate_required([
      :account_id,
      :name,
      :asset_type,
      :valuation_amount,
      :valuation_currency,
      :ownership_type
    ])
    |> update_change(:valuation_currency, &normalize_currency/1)
    |> validate_currency(:valuation_currency)
    |> validate_decimal(:valuation_amount)
    |> validate_length(:name, min: 1, max: 160)
    |> validate_length(:asset_type, min: 1, max: 120)
    |> validate_length(:category, max: 120)
    |> validate_length(:ownership_type, min: 1, max: 120)
    |> validate_length(:ownership_details, max: 500)
    |> validate_length(:location, max: 255)
    |> validate_length(:notes, max: 2000)
    |> validate_document_refs()
    |> foreign_key_constraint(:account_id)
  end

  defp maybe_seed_documents_text(%__MODULE__{documents_text: text} = asset) when is_binary(text),
    do: asset

  defp maybe_seed_documents_text(%__MODULE__{document_refs: refs} = asset) do
    Map.put(asset, :documents_text, refs |> Enum.join("\n"))
  end

  defp normalize_currency(value) when is_binary(value), do: value |> String.trim() |> String.upcase()
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
        is_nil(value) -> []
        match?(%Decimal{}, value) -> []
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
        nil -> nil
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
      _ -> []
    end)
  end

  defp validate_document_refs(%Ecto.Changeset{} = changeset) do
    refs = get_field(changeset, :document_refs, [])

    Enum.reduce(Enum.with_index(refs, 1), changeset, fn {ref, index}, acc ->
      cond do
        byte_size(ref) > 255 -> add_error(acc, :document_refs, "entry #{index} is too long")
        true -> acc
      end
    end)
  end
end
