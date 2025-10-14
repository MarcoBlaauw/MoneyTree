defmodule MoneyTree.Observability do
  @moduledoc """
  Centralized setup for application observability hooks.
  """

  @ecto_event_prefix [:money_tree, :repo]

  def setup do
    attach_phoenix()
    attach_ecto()
    attach_oban()
    :ok
  end

  defp attach_phoenix do
    maybe_apply(OpentelemetryPhoenix, :setup, [[adapter: :cowboy2]])
  end

  defp attach_ecto do
    maybe_apply(OpentelemetryEcto, :setup, [@ecto_event_prefix, [db_statement: :disabled]])
  end

  defp attach_oban do
    maybe_apply(OpentelemetryOban, :setup, [])
  end

  defp maybe_apply(module, function, args) do
    if Code.ensure_loaded?(module) do
      apply(module, function, args)
    end

    :ok
  rescue
    _ -> :ok
  end
end
