defmodule MoneyTree.AssetsTest do
  use MoneyTree.DataCase, async: true

  alias Decimal
  alias MoneyTree.Assets
  alias MoneyTree.Assets.Asset

  import MoneyTree.AccountsFixtures
  import MoneyTree.AssetsFixtures

  describe "list_accessible_assets/2" do
    test "returns assets belonging to the user's accounts" do
      user = user_fixture()
      asset = asset_fixture(user)

      other_user = user_fixture(%{email: "other-#{System.unique_integer()}@example.com"})
      _other_asset = asset_fixture(other_user)

      results = Assets.list_accessible_assets(user, preload: [:account])

      assert Enum.any?(results, &(&1.id == asset.id))
      refute Enum.any?(results, &(&1.account.user_id == other_user.id))
    end

    test "includes assets for shared memberships" do
      owner = user_fixture()
      member = user_fixture(%{email: "member-#{System.unique_integer()}@example.com"})
      account = account_fixture(owner)
      membership_fixture(account, member)
      asset = asset_fixture(owner, account)

      assert [%Asset{id: id}] = Assets.list_accessible_assets(member)
      assert id == asset.id
    end
  end

  describe "fetch_accessible_asset/3" do
    test "returns an asset when user has access" do
      user = user_fixture()
      asset = asset_fixture(user)

      assert {:ok, %Asset{id: ^asset.id}} =
               Assets.fetch_accessible_asset(user, asset.id, preload: [:account])
    end

    test "returns error when asset is inaccessible" do
      owner = user_fixture()
      intruder = user_fixture(%{email: "intruder-#{System.unique_integer()}@example.com"})
      asset = asset_fixture(owner)

      assert {:error, :not_found} = Assets.fetch_accessible_asset(intruder, asset.id)
    end
  end

  describe "create_asset_for_user/2" do
    test "creates an asset for the owning user" do
      user = user_fixture()
      account = account_fixture(user)

      params =
        valid_asset_attrs(%{
          account_id: account.id,
          name: "New Asset",
          valuation_amount: "999.01"
        })

      assert {:ok, %Asset{} = asset} = Assets.create_asset_for_user(user, params)
      assert asset.name == "New Asset"
      assert asset.account_id == account.id
      assert Decimal.eq?(asset.valuation_amount, Decimal.new("999.01"))
    end

    test "prevents creation when account is not accessible" do
      owner = user_fixture()
      outsider = user_fixture(%{email: "outsider-#{System.unique_integer()}@example.com"})
      account = account_fixture(owner)

      params = valid_asset_attrs(%{account_id: account.id, name: "Restricted"})

      assert {:error, :not_found} = Assets.create_asset_for_user(outsider, params)
    end
  end

  describe "update_asset_for_user/3" do
    test "updates accessible asset attributes" do
      user = user_fixture()
      asset = asset_fixture(user)

      assert {:ok, %Asset{} = updated} =
               Assets.update_asset_for_user(user, asset, %{
                 name: "Updated Asset",
                 ownership: "Joint"
               })

      assert updated.name == "Updated Asset"
      assert updated.ownership == "Joint"
    end

    test "prevents updates for inaccessible assets" do
      owner = user_fixture()
      outsider = user_fixture(%{email: "outsider-#{System.unique_integer()}@example.com"})
      asset = asset_fixture(owner)

      assert {:error, :not_found} =
               Assets.update_asset_for_user(outsider, asset, %{name: "Hacked"})
    end
  end

  describe "delete_asset_for_user/2" do
    test "removes accessible assets" do
      user = user_fixture()
      asset = asset_fixture(user)

      assert {:ok, %Asset{}} = Assets.delete_asset_for_user(user, asset)
      assert {:error, :not_found} = Assets.fetch_accessible_asset(user, asset.id)
    end

    test "prevents deletion of inaccessible assets" do
      owner = user_fixture()
      outsider = user_fixture(%{email: "outsider-#{System.unique_integer()}@example.com"})
      asset = asset_fixture(owner)

      assert {:error, :not_found} = Assets.delete_asset_for_user(outsider, asset)
    end
  end

  describe "dashboard_summary/2" do
    test "aggregates valuations by currency" do
      user = user_fixture()
      account = account_fixture(user, %{currency: "USD"})

      asset_fixture(user, account, %{
        valuation_amount: Decimal.new("10"),
        valuation_currency: "USD"
      })

      asset_fixture(user, account, %{
        valuation_amount: Decimal.new("5.50"),
        valuation_currency: "USD"
      })

      %{assets: assets, totals: totals} = Assets.dashboard_summary(user)

      assert length(assets) == 2
      assert [%{currency: "USD", asset_count: 2, total_amount: total}] = totals
      assert total =~ "USD"
    end
  end
end
