defmodule MoneyTree.Assets.ProviderRegistryTest do
  use ExUnit.Case, async: false

  alias MoneyTree.Assets.ProviderRegistry
  alias MoneyTree.Assets.VehicleValuationProviders.MarketCheck

  setup do
    original_registry = Application.get_env(:money_tree, ProviderRegistry)
    original_marketcheck = Application.get_env(:money_tree, MarketCheck)

    on_exit(fn ->
      restore_env(ProviderRegistry, original_registry)
      restore_env(MarketCheck, original_marketcheck)
    end)
  end

  test "requires explicit enablement and a key" do
    Application.put_env(:money_tree, ProviderRegistry,
      enabled_providers: [],
      monthly_request_limit: 450,
      refresh_interval_days: 7
    )

    Application.put_env(:money_tree, MarketCheck, api_key: "test-key")

    refute ProviderRegistry.configured?("marketcheck")

    Application.put_env(:money_tree, ProviderRegistry,
      enabled_providers: ["marketcheck"],
      monthly_request_limit: 450,
      refresh_interval_days: 7
    )

    assert ProviderRegistry.configured?(:marketcheck)
  end

  test "clamps a configured monthly budget to the 500-call hard ceiling" do
    Application.put_env(:money_tree, ProviderRegistry,
      enabled_providers: ["marketcheck"],
      monthly_request_limit: 900,
      refresh_interval_days: 7
    )

    assert ProviderRegistry.monthly_request_limit() == 500
    assert ProviderRegistry.hard_monthly_limit() == 500
  end

  defp restore_env(module, nil), do: Application.delete_env(:money_tree, module)
  defp restore_env(module, value), do: Application.put_env(:money_tree, module, value)
end
