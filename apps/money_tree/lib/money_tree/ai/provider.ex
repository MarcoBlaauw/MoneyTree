defmodule MoneyTree.AI.Provider do
  @moduledoc """
  Provider behaviour for AI suggestion generation.
  """

  @callback health_check(map()) :: {:ok, map()} | {:error, term()}
  @callback list_models(map()) :: {:ok, [String.t()]} | {:error, term()}
  @callback generate_json(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
end
