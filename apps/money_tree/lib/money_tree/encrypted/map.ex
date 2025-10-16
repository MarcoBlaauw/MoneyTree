defmodule MoneyTree.Encrypted.Map do
  @moduledoc false

  use Cloak.Ecto.Type, vault: MoneyTree.Vault, type: :map

  @impl true
  def cast(nil), do: {:ok, nil}

  def cast(value) when is_map(value), do: {:ok, value}

  def cast(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> :error
    end
  end

  def cast(_value), do: :error

  def before_encrypt(value) when is_map(value), do: Jason.encode!(value)

  def before_encrypt(value) when is_binary(value), do: value

  def after_decrypt(nil), do: nil

  def after_decrypt(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  def after_decrypt(value), do: value
end
