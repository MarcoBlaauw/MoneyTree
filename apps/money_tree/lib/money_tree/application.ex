defmodule MoneyTree.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    oban_config = Application.fetch_env!(:money_tree, Oban)

    :ok = MoneyTree.Observability.setup()

    children = [
      MoneyTreeWeb.Telemetry,
      MoneyTree.Vault,
      MoneyTree.Repo,
      {Oban, oban_config},
      {DNSCluster, query: Application.get_env(:money_tree, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: MoneyTree.PubSub},
      {Finch, name: MoneyTree.Finch},
      MoneyTreeWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: MoneyTree.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    MoneyTreeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
