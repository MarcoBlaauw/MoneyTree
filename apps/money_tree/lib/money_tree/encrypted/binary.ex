defmodule MoneyTree.Encrypted.Binary do
  @moduledoc false

  use Cloak.Ecto.Type, vault: MoneyTree.Vault
end
