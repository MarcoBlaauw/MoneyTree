defmodule MoneyTree.AssetsTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures
  import MoneyTree.AssetsFixtures

  alias Decimal
  alias MoneyTree.Assets
  alias MoneyTree.Assets.Asset

  describe "list_assets/2" do
    test "returns assets accessible to the user" do
      owner = user_fixture(%{email: "owner@example.com"})
      account = account_fixture(owner, %{currency: "USD"})
      asset = asset_fixture(account, %{name: "Family Home"})

      other_user = user_fixture(%{email: "other@example.com"})
      other_account = account_fixture(other_user, %{currency: "USD"})
      _hidden_asset = asset_fixture(other_account, %{name: "Hidden"})

      asset_id = asset.id

      assert [%Asset{id: ^asset_id}] = Assets.list_assets(owner)
      assert [] = Assets.list_assets(other_user)

      membership_fixture(account, other_user)
      assert [%Asset{id: ^asset_id}] = Assets.list_assets(other_user)
      assert [%Asset{id: ^asset_id}] = Assets.list_assets(owner, preload: [])
      assert [%Asset{id: ^asset_id}] = Assets.list_assets(other_user, preload: [])
      assert [%Asset{id: ^asset_id}] = Assets.list_assets(owner, account_id: account.id)
    end
  end

  describe "create_asset/3" do
    test "creates an asset with valid data" do
      user = user_fixture()
      account = account_fixture(user, %{currency: "USD"})

      params = %{
        account_id: account.id,
        name: "Primary Residence",
        asset_type: "real_estate",
        category: "home",
        valuation_amount: "450000.00",
        valuation_currency: "usd",
        ownership_type: "joint",
        ownership_details: "Shared with spouse",
        location: "123 Demo Street",
        notes: "Seed asset",
        acquired_on: ~D[2020-01-01],
        last_valued_on: ~D[2024-01-01],
        documents_text: "Deed #12345\nInsurance #67890"
      }

      assert {:ok, %Asset{} = asset} = Assets.create_asset(user, params)
      assert asset.name == "Primary Residence"
      assert asset.valuation_currency == "USD"
      assert asset.document_refs == ["Deed #12345", "Insurance #67890"]
      assert asset.account_id == account.id
    end

    test "rejects creation when account is not accessible" do
      owner = user_fixture(%{email: "owner@example.com"})
      outsider = user_fixture(%{email: "outsider@example.com"})
      account = account_fixture(owner)

      params = %{
        account_id: account.id,
        name: "Unauthorized Asset",
        asset_type: "vehicle",
        valuation_amount: "25000",
        valuation_currency: "USD",
        ownership_type: "individual"
      }

      assert {:error, :unauthorized} = Assets.create_asset(outsider, params)
    end

    test "returns changeset errors for invalid data" do
      user = user_fixture()
      account = account_fixture(user)

      params = %{
        account_id: account.id,
        name: "",
        asset_type: "",
        valuation_amount: "invalid",
        valuation_currency: "ZZZ",
        ownership_type: ""
      }

      assert {:error, %Ecto.Changeset{} = changeset} = Assets.create_asset(user, params)

      assert "can't be blank" in errors_on(changeset).name
      assert "can't be blank" in errors_on(changeset).asset_type
      assert "must be a valid decimal number" in errors_on(changeset).valuation_amount
      assert "must be a valid ISO 4217 currency code" in errors_on(changeset).valuation_currency
      assert "can't be blank" in errors_on(changeset).ownership_type
    end
  end

  describe "update_asset/4" do
    test "updates an existing asset" do
      user = user_fixture()
      account = account_fixture(user, %{currency: "USD"})
      asset = asset_fixture(account, %{name: "Vehicle", valuation_amount: Decimal.new("15000")})

      assert {:ok, %Asset{} = updated} =
               Assets.update_asset(user, asset, %{name: "Updated Vehicle", valuation_amount: "15500.50"})

      assert updated.name == "Updated Vehicle"
      assert updated.valuation_amount == Decimal.new("15500.50")
    end

    test "prevents moving an asset to an unauthorized account" do
      owner = user_fixture(%{email: "owner@example.com"})
      member = user_fixture(%{email: "member@example.com"})
      outsider = user_fixture(%{email: "outsider@example.com"})

      shared_account = account_fixture(owner)
      membership_fixture(shared_account, member)

      destination_account = account_fixture(owner, %{name: "Owner Only"})
      asset = asset_fixture(shared_account)

      assert {:error, :unauthorized} =
               Assets.update_asset(member, asset, %{account_id: destination_account.id})

      assert {:error, :unauthorized} =
               Assets.update_asset(outsider, asset, %{name: "Unauthorized"})
    end
  end

  describe "delete_asset/2" do
    test "removes the asset when authorized" do
      user = user_fixture()
      account = account_fixture(user)
      asset = asset_fixture(account)

      assert {:ok, %Asset{}} = Assets.delete_asset(user, asset)
      assert {:error, :not_found} = Assets.fetch_asset(user, asset.id)
    end

    test "prevents deletion without access" do
      owner = user_fixture(%{email: "owner@example.com"})
      outsider = user_fixture(%{email: "outsider@example.com"})
      account = account_fixture(owner)
      asset = asset_fixture(account)

      assert {:error, :unauthorized} = Assets.delete_asset(outsider, asset)
    end
  end

  describe "dashboard_summary/2" do
    test "returns formatted summaries and totals" do
      user = user_fixture()
      account = account_fixture(user, %{currency: "USD"})
      other_account = account_fixture(user, %{currency: "EUR"})

      asset_one = asset_fixture(account, %{name: "Primary Home", valuation_amount: Decimal.new("400000"), valuation_currency: "USD"})
      asset_two = asset_fixture(other_account, %{name: "Vacation Flat", valuation_amount: Decimal.new("250000"), valuation_currency: "EUR"})

      summary = Assets.dashboard_summary(user)

      assert summary.total_count == 2
      assert Enum.any?(summary.assets, &(&1.asset.id == asset_one.id))
      assert Enum.any?(summary.assets, &(&1.asset.id == asset_two.id))

      usd_total = Enum.find(summary.totals, &(&1.currency == "USD"))
      eur_total = Enum.find(summary.totals, &(&1.currency == "EUR"))

      assert usd_total.asset_count == 1
      assert usd_total.valuation == MoneyTree.Accounts.format_money(Decimal.new("400000"), "USD")
      assert eur_total.asset_count == 1
      assert eur_total.valuation == MoneyTree.Accounts.format_money(Decimal.new("250000"), "EUR")
    end
  end
end
