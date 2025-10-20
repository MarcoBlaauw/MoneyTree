defmodule MoneyTree.AssetsFixtures do
  @moduledoc """
  Test helpers for creating tangible asset records.
  """

  alias Decimal
  alias MoneyTree.AccountsFixtures
  alias MoneyTree.Assets

  def valid_asset_attrs(attrs \\ %{}) do
    defaults = %{
      name: "Fixture Asset",
      type: "property",
      valuation_amount: Decimal.new("12345.67"),
      valuation_currency: "USD",
      valuation_date: Date.utc_today(),
      ownership: "Primary",
      location: "Fixture City",
      documents: ["https://example.com/doc.pdf"],
      notes: "Fixture notes",
      metadata: %{"source" => "fixture"}
    }

    Map.merge(defaults, Map.new(attrs))
  end

  def asset_fixture(user, account \\ nil, attrs \\ %{}) do
    account = account || AccountsFixtures.account_fixture(user)

    params =
      attrs
      |> valid_asset_attrs()
      |> Map.put(:account_id, account.id)

    {:ok, asset} = Assets.create_asset_for_user(user, params)
    asset
  end
end
