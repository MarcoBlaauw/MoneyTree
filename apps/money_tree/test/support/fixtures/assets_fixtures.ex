defmodule MoneyTree.AssetsFixtures do
  @moduledoc """
  Helpers for creating asset records during tests.
  """

  alias Decimal
  alias MoneyTree.Assets.Asset
  alias MoneyTree.Repo

  import MoneyTree.AccountsFixtures

  def unique_asset_name do
    "Asset-#{System.unique_integer([:positive])}"
  end

  def asset_fixture(account, attrs \\ %{}) do
    attrs = Map.new(attrs)

    params =
      %{
        account_id: Map.get(attrs, :account_id, account.id),
        name: Map.get(attrs, :name, unique_asset_name()),
        asset_type: Map.get(attrs, :asset_type, "real_estate"),
        category: Map.get(attrs, :category, "property"),
        valuation_amount: Map.get(attrs, :valuation_amount, Decimal.new("100000.00")),
        valuation_currency: Map.get(attrs, :valuation_currency, account.currency || "USD"),
        ownership_type: Map.get(attrs, :ownership_type, "primary"),
        ownership_details: Map.get(attrs, :ownership_details, "Joint ownership"),
        location: Map.get(attrs, :location, "123 Test Street"),
        notes: Map.get(attrs, :notes, "Fixture asset"),
        acquired_on: Map.get(attrs, :acquired_on, ~D[2015-01-01]),
        last_valued_on: Map.get(attrs, :last_valued_on, Date.utc_today()),
        document_refs: Map.get(attrs, :document_refs, ["Deed ##{System.unique_integer([:positive])}"])
      }

    %Asset{}
    |> Asset.changeset(params)
    |> Repo.insert!()
  end
end
