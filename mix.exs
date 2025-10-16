defmodule MoneyTree.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: []
    ]
  end

  defp aliases do
    [
      lint: ["format --check-formatted", "cmd --app money_tree mix credo --strict"],
      setup: ["deps.get", "cmd --app money_tree mix ecto.setup"]
    ]
  end
end
