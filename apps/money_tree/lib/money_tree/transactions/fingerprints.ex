defmodule MoneyTree.Transactions.Fingerprints do
  @moduledoc """
  Deterministic fingerprint helpers for cross-source transaction identity.
  """

  alias Decimal

  @spec source_fingerprint(map()) :: String.t()
  def source_fingerprint(attrs) when is_map(attrs) do
    attrs
    |> source_components()
    |> Enum.join("|")
    |> digest()
  end

  @spec normalized_fingerprint(map()) :: String.t()
  def normalized_fingerprint(attrs) when is_map(attrs) do
    attrs
    |> normalized_components()
    |> Enum.join("|")
    |> digest()
  end

  @spec normalize_text(term()) :: String.t()
  def normalize_text(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
  end

  def normalize_text(_value), do: ""

  defp source_components(attrs) do
    [
      normalize_text(get(attrs, :source) || "unknown"),
      get(attrs, :account_id),
      get(attrs, :source_transaction_id) || get(attrs, :external_id),
      get(attrs, :source_reference),
      date_component(attrs),
      decimal_component(get(attrs, :amount)),
      normalize_text(get(attrs, :original_description) || get(attrs, :description)),
      currency_component(attrs)
    ]
    |> Enum.map(&component/1)
  end

  defp normalized_components(attrs) do
    [
      get(attrs, :account_id),
      date_component(attrs),
      decimal_component(get(attrs, :amount)),
      normalize_text(get(attrs, :merchant_name) || get(attrs, :description)),
      currency_component(attrs)
    ]
    |> Enum.map(&component/1)
  end

  defp date_component(attrs) do
    attrs
    |> get(:posted_at)
    |> case do
      %DateTime{} = datetime -> DateTime.to_date(datetime)
      %NaiveDateTime{} = naive -> NaiveDateTime.to_date(naive)
      %Date{} = date -> date
      value when is_binary(value) -> Date.from_iso8601(value) |> elem_or_nil()
      _ -> nil
    end
    |> case do
      %Date{} = date -> Date.to_iso8601(date)
      _ -> ""
    end
  end

  defp currency_component(attrs) do
    attrs
    |> get(:currency)
    |> case do
      value when is_binary(value) -> String.upcase(String.trim(value))
      _ -> ""
    end
  end

  defp decimal_component(nil), do: ""

  defp decimal_component(%Decimal{} = value) do
    value
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  defp decimal_component(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> decimal_component(decimal)
      :error -> ""
    end
  end

  defp component(nil), do: ""
  defp component(value) when is_binary(value), do: value
  defp component(value), do: to_string(value)

  defp digest(payload) do
    :sha256
    |> :crypto.hash(payload)
    |> Base.encode16(case: :lower)
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp elem_or_nil({:ok, value}), do: value
  defp elem_or_nil(_), do: nil
end
