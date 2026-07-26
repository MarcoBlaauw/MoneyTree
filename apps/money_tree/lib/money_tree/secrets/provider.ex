defmodule MoneyTree.Secrets.Provider do
  @moduledoc """
  Behaviour for runtime secret providers.

  Providers return raw string values only to backend runtime configuration.
  Empty or missing values should normalize to `nil`.
  """

  @callback get(String.t()) :: String.t() | nil
  @callback get_group(atom()) :: map()
end
