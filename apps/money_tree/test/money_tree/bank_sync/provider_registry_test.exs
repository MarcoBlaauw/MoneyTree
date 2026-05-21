defmodule MoneyTree.BankSync.ProviderRegistryTest do
  use ExUnit.Case, async: false

  alias MoneyTree.BankSync.ProviderRegistry

  setup do
    original = Application.get_env(:money_tree, ProviderRegistry)

    on_exit(fn ->
      if original do
        Application.put_env(:money_tree, ProviderRegistry, original)
      else
        Application.delete_env(:money_tree, ProviderRegistry)
      end
    end)

    :ok
  end

  test "defaults to SimpleFIN and manual providers" do
    Application.delete_env(:money_tree, ProviderRegistry)

    assert ProviderRegistry.enabled?("simplefin")
    assert ProviderRegistry.enabled?(:manual)
    refute ProviderRegistry.enabled?("teller")
    refute ProviderRegistry.enabled?("plaid")
    assert ProviderRegistry.primary_provider() == "simplefin"
  end

  test "normalizes configured providers" do
    Application.put_env(:money_tree, ProviderRegistry,
      enabled_providers: " SimpleFIN, Teller,unknown ",
      primary_provider: "teller"
    )

    assert ProviderRegistry.enabled?("simplefin")
    assert ProviderRegistry.enabled?("teller")
    refute ProviderRegistry.enabled?("plaid")
    assert ProviderRegistry.primary_provider() == "teller"
  end
end
