defmodule MoneyTree.Encrypted.Map do
  @moduledoc false

  use Cloak.Ecto.Type, vault: MoneyTree.Vault, type: :map
end
