defmodule MoneyTree.MixProject do
  use Mix.Project

  def project do
    [
      app: :money_tree,
      version: "0.1.0",
      elixir: "~> 1.16",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      dialyzer: dialyzer()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {MoneyTree.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:argon2_elixir, "~> 4.0"},
      {:cloak_ecto, "~> 1.3"},
      {:dns_cluster, "~> 0.1.1"},
      {:ecto_sql, "~> 3.11"},
      {:finch, "~> 0.18"},
      {:gettext, "~> 0.20"},
      {:jason, "~> 1.2"},
      {:oban, "~> 2.17"},
      {:opentelemetry_exporter, "~> 1.6"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:opentelemetry_oban, "~> 1.0"},
      {:opentelemetry_phoenix, "~> 1.1"},
      {:phoenix, "~> 1.7.10"},
      {:phoenix_ecto, "~> 4.4"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_dashboard, "~> 0.8.2"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_view, "~> 2.0"},
      {:plug_cowboy, "~> 2.5"},
      {:postgrex, ">= 0.0.0"},
      {:req, "~> 0.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:swoosh, "~> 1.11"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      lint: ["format --check-formatted", "credo --strict"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.deploy": [
        &pnpm_assets_build/1,
        "phx.digest"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn_file, "priv/plts/money_tree.plt"},
      plt_add_apps: [:mix, :iex],
      flags: [:error_handling, :race_conditions, :underspecs]
    ]
  end

  defp releases do
    [
      money_tree: [
        steps: [&run_assets_deploy/1, :assemble]
      ]
    ]
  end

  defp run_assets_deploy(release) do
    Mix.Task.reenable("assets.deploy")
    Mix.Task.reenable("phx.digest")
    Mix.Task.run("assets.deploy")
    release
  end

  defp pnpm_assets_build(_) do
    run_pnpm_assets!("build")
  end

  defp run_pnpm_assets!(script) do
    root = Path.expand("../../", __DIR__)

    env = [{"NODE_ENV", "production"}]

    case System.cmd("pnpm", ["--filter", "money-tree-assets", "run", script],
           cd: root,
           env: env,
           into: IO.stream(:stdio, :line)
         ) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("assets #{script} failed with status #{status}")
    end
  end
end
