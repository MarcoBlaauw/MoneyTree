defmodule MoneyTree.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      apps: [:money_tree],
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: []
    ]
  end

  defp aliases do
    [
      lint: ["format --check-formatted", &credo_money_tree/1],
      setup: ["deps.get", &ecto_setup_money_tree/1]
    ]
  end

  defp credo_money_tree(_) do
    run_in_money_tree(fn ->
      Mix.Task.reenable("credo")
      Mix.Task.run("credo", ["--strict"])
    end)
  end

  defp ecto_setup_money_tree(_) do
    run_in_money_tree(fn ->
      Mix.Task.reenable("ecto.setup")
      Mix.Task.run("ecto.setup")
    end)
  end

  defp run_in_money_tree(fun) do
    Mix.Project.in_project(:money_tree, "apps/money_tree", fn _ -> fun.() end)
  end
end
