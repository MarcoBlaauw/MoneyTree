defmodule MoneyTree.Audit do
  @moduledoc """
  Lightweight audit utility emitting telemetry events for security-sensitive actions.
  """

  @type event :: atom()
  @type metadata :: map()

  @doc """
  Emits a telemetry event describing an authentication or authorization decision.
  """
  @spec log(event(), metadata()) :: :ok
  def log(event, metadata \\ %{}) when is_atom(event) and is_map(metadata) do
    :telemetry.execute([:money_tree, :audit, event], %{}, metadata)
    :ok
  end
end
