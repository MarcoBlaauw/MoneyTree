defmodule MoneyTree.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      apps: [:money_tree],
      listeners: [Phoenix.CodeReloader],
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: []
    ]
  end

  defp aliases do
    [
      lint: ["format --check-formatted", "cmd mix credo --strict"],
      setup: ["deps.get", "cmd mix ecto.setup"]
    ]
  end
end
