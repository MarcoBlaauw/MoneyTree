defmodule MoneyTree.AssetsTest do
  use MoneyTree.DataCase, async: true

  import MoneyTree.AccountsFixtures
  import MoneyTree.AssetsFixtures

  alias Decimal
  alias MoneyTree.Assets
  alias MoneyTree.Assets.Asset
  alias MoneyTree.Assets.ValuationProviderRun
  alias MoneyTree.Assets.VehicleProfile
  alias MoneyTree.Assets.VehicleValuationProviders.MarketCheck
  alias MoneyTree.Loans
  alias MoneyTree.Repo

  describe "list_assets/2" do
    test "returns assets accessible to the user" do
      owner = user_fixture(%{email: "owner@example.com"})
      account = account_fixture(owner, %{currency: "USD"})
      asset = asset_fixture(account, %{name: "Family Home"})

      other_user = user_fixture(%{email: "other@example.com"})
      other_account = account_fixture(other_user, %{currency: "USD"})
      _hidden_asset = asset_fixture(other_account, %{name: "Hidden"})
      hidden_asset = Assets.list_assets(other_user) |> List.first()

      asset_id = asset.id
      hidden_asset_id = hidden_asset.id

      assert [%Asset{id: ^asset_id}] = Assets.list_assets(owner)
      assert [%Asset{id: ^hidden_asset_id}] = Assets.list_assets(other_user)

      membership_fixture(account, other_user)

      other_user_asset_ids =
        Assets.list_assets(other_user)
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert other_user_asset_ids == Enum.sort([hidden_asset_id, asset_id])
      assert [%Asset{id: ^asset_id}] = Assets.list_assets(owner, preload: [])

      assert Enum.sort(Enum.map(Assets.list_assets(other_user, preload: []), & &1.id)) ==
               Enum.sort([hidden_asset_id, asset_id])

      assert [%Asset{id: ^asset_id}] = Assets.list_assets(owner, account_id: account.id)
    end

    test "keeps unlinked assets private to their direct owner" do
      owner = user_fixture(%{email: "owner@example.com"})
      outsider = user_fixture(%{email: "outsider@example.com"})
      asset = unlinked_asset_fixture(owner)

      assert Enum.map(Assets.list_assets(owner), & &1.id) == [asset.id]
      assert Assets.list_assets(outsider) == []
      assert {:error, :not_found} = Assets.fetch_asset(outsider, asset.id)
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
      assert asset.user_id == user.id

      assert {:ok, [valuation]} = Assets.list_asset_valuations(user, asset)
      assert Decimal.equal?(valuation.amount, Decimal.new("450000"))
      assert valuation.source == "manual"
      assert valuation.valued_on == ~D[2024-01-01]
    end

    test "creates an asset without a funding account" do
      user = user_fixture()

      assert {:ok, %Asset{} = asset} =
               Assets.create_asset(user, %{
                 name: "Paid-off vehicle",
                 asset_type: "vehicle",
                 valuation_amount: "18000",
                 valuation_currency: "USD",
                 ownership_type: "individual"
               })

      assert asset.account_id == nil
      assert asset.user_id == user.id
      assert asset.last_valued_on == Date.utc_today()
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
      assert "is invalid" in errors_on(changeset).valuation_amount
      assert "must be a valid ISO 4217 currency code" in errors_on(changeset).valuation_currency
      assert "can't be blank" in errors_on(changeset).ownership_type
    end

    test "rejects unsupported asset types for new records" do
      user = user_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Assets.create_asset(user, %{
                 name: "Mystery asset",
                 asset_type: "spaceship",
                 valuation_amount: "100",
                 valuation_currency: "USD",
                 ownership_type: "individual"
               })

      assert "is invalid" in errors_on(changeset).asset_type
    end
  end

  describe "update_asset/4" do
    test "updates an existing asset" do
      user = user_fixture()
      account = account_fixture(user, %{currency: "USD"})
      asset = asset_fixture(account, %{name: "Vehicle", valuation_amount: Decimal.new("15000")})

      assert {:ok, %Asset{} = updated} =
               Assets.update_asset(user, asset, %{
                 name: "Updated Vehicle",
                 valuation_amount: "15500.50"
               })

      assert updated.name == "Updated Vehicle"
      assert updated.valuation_amount == Decimal.new("15500.50")

      assert {:ok, [valuation]} = Assets.list_asset_valuations(user, updated)
      assert Decimal.equal?(valuation.amount, Decimal.new("15500.50"))
      assert valuation.source == "manual"
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

    test "allows the owner to remove an optional funding-account link" do
      user = user_fixture()
      account = account_fixture(user)
      asset = asset_fixture(account)

      assert {:ok, updated} = Assets.update_asset(user, asset, %{"account_id" => ""})
      assert updated.account_id == nil
      assert updated.user_id == user.id
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

  describe "account lifecycle" do
    test "deleting a funding account preserves the directly owned asset" do
      user = user_fixture()
      account = account_fixture(user)
      asset = asset_fixture(account)

      Repo.delete!(account)

      persisted = Repo.get!(Asset, asset.id)
      assert persisted.account_id == nil
      assert persisted.user_id == user.id
      assert Enum.any?(Assets.list_assets(user), &(&1.id == asset.id))
    end
  end

  describe "vehicle profiles" do
    test "stores a normalized encrypted VIN for a vehicle asset" do
      user = user_fixture()
      asset = unlinked_asset_fixture(user)

      assert {:ok, %VehicleProfile{} = profile} =
               Assets.upsert_vehicle_profile(user, asset, %{
                 encrypted_vin: "1hgcm82633a004352",
                 year: 2003,
                 make: "Honda",
                 model: "Accord",
                 mileage: 125_000,
                 mileage_as_of: ~D[2026-07-27],
                 condition: "GOOD",
                 market_region: "60601"
               })

      assert profile.encrypted_vin == "1HGCM82633A004352"
      assert profile.condition == "good"

      [[encrypted_vin]] =
        Repo.query!("SELECT encrypted_vin FROM vehicle_profiles WHERE id::text = $1", [profile.id]).rows

      refute encrypted_vin == profile.encrypted_vin
    end

    test "rejects invalid VINs and non-vehicle assets" do
      user = user_fixture()
      vehicle = unlinked_asset_fixture(user)
      account = account_fixture(user)
      home = asset_fixture(account)

      assert {:error, changeset} =
               Assets.upsert_vehicle_profile(user, vehicle, %{encrypted_vin: "INVALID"})

      assert "must be a 17-character VIN without I, O, or Q" in errors_on(changeset).encrypted_vin

      assert {:error, :not_vehicle} =
               Assets.upsert_vehicle_profile(user, home, %{year: 2020})
    end

    test "prevents outsiders from changing a vehicle profile" do
      owner = user_fixture(%{email: "owner@example.com"})
      outsider = user_fixture(%{email: "outsider@example.com"})
      asset = unlinked_asset_fixture(owner)

      assert {:error, :unauthorized} =
               Assets.upsert_vehicle_profile(outsider, asset, %{year: 2020})
    end
  end

  describe "record_valuation/3" do
    test "appends history and keeps the newest dated snapshot in the asset cache" do
      user = user_fixture()
      asset = unlinked_asset_fixture(user, %{valuation_amount: Decimal.new("10000")})

      assert {:ok, %{valuation: first, asset: first_cached}} =
               Assets.record_valuation(user, asset, %{
                 amount: "12000",
                 currency: "usd",
                 source: "manual",
                 valued_on: ~D[2026-06-01],
                 mileage: 120_000
               })

      assert Decimal.equal?(first_cached.valuation_amount, Decimal.new("12000"))
      assert first_cached.last_valued_on == ~D[2026-06-01]

      assert {:ok, %{valuation: second, asset: second_cached}} =
               Assets.record_valuation(user, first_cached, %{
                 amount: "11500",
                 valued_on: ~D[2026-07-01],
                 confidence: "medium"
               })

      assert Decimal.equal?(second_cached.valuation_amount, Decimal.new("11500"))
      assert second_cached.last_valued_on == ~D[2026-07-01]

      assert {:ok, %{valuation: third, asset: final_cached}} =
               Assets.record_valuation(user, second_cached, %{
                 amount: "12500",
                 valued_on: ~D[2026-05-01]
               })

      assert Decimal.equal?(final_cached.valuation_amount, Decimal.new("11500"))
      assert final_cached.last_valued_on == ~D[2026-07-01]

      assert {:ok, valuations} = Assets.list_asset_valuations(user, final_cached)
      assert Enum.map(valuations, & &1.id) == [second.id, first.id, third.id]
    end

    test "rejects invalid ranges and unauthorized writers without changing the cache" do
      owner = user_fixture(%{email: "owner@example.com"})
      outsider = user_fixture(%{email: "outsider@example.com"})
      asset = unlinked_asset_fixture(owner, %{valuation_amount: Decimal.new("10000")})

      assert {:error, changeset} =
               Assets.record_valuation(owner, asset, %{
                 amount: "15000",
                 value_low: "9000",
                 value_high: "11000",
                 valued_on: ~D[2026-07-01]
               })

      assert "must be within the valuation range" in errors_on(changeset).amount
      assert {:error, :unauthorized} = Assets.record_valuation(outsider, asset, %{amount: "1"})
      assert Decimal.equal?(Repo.get!(Asset, asset.id).valuation_amount, Decimal.new("10000"))
    end
  end

  describe "dashboard_summary/2" do
    test "returns formatted summaries and totals" do
      user = user_fixture()
      account = account_fixture(user, %{currency: "USD"})
      other_account = account_fixture(user, %{currency: "EUR"})

      asset_one =
        asset_fixture(account, %{
          name: "Primary Home",
          valuation_amount: Decimal.new("400000"),
          valuation_currency: "USD"
        })

      asset_two =
        asset_fixture(other_account, %{
          name: "Vacation Flat",
          valuation_amount: Decimal.new("250000"),
          valuation_currency: "EUR"
        })

      summary = Assets.dashboard_summary(user)

      assert summary.total_count == 2
      assert Enum.any?(summary.assets, &(&1.asset.id == asset_one.id))
      assert Enum.any?(summary.assets, &(&1.asset.id == asset_two.id))

      usd_total = Enum.find(summary.totals, &(&1.currency == "USD"))
      eur_total = Enum.find(summary.totals, &(&1.currency == "EUR"))

      assert usd_total.asset_count == 1

      assert usd_total.valuation ==
               MoneyTree.Accounts.format_money(Decimal.new("400000"), "USD", [])

      assert eur_total.asset_count == 1

      assert eur_total.valuation ==
               MoneyTree.Accounts.format_money(Decimal.new("250000"), "EUR", [])
    end

    test "distinguishes gross value, linked debt, and net equity" do
      user = user_fixture()
      account = account_fixture(user, %{currency: "USD"})

      {:ok, loan} =
        Loans.create_loan(user, %{
          loan_type: "auto",
          name: "Vehicle loan",
          current_balance: "18000",
          current_interest_rate: "0.06",
          remaining_term_months: 48,
          monthly_payment_total: "425"
        })

      asset =
        asset_fixture(account, %{
          asset_type: "vehicle",
          valuation_amount: Decimal.new("30000"),
          linked_loan_id: loan.id
        })

      summary = Assets.dashboard_summary(user)
      asset_summary = Enum.find(summary.assets, &(&1.asset.id == asset.id))
      total = Enum.find(summary.totals, &(&1.currency == "USD"))

      assert Decimal.equal?(asset_summary.gross_value_amount, Decimal.new("30000"))
      assert Decimal.equal?(asset_summary.linked_debt_amount, Decimal.new("18000"))
      assert Decimal.equal?(asset_summary.net_equity_amount, Decimal.new("12000"))
      assert Decimal.equal?(total.gross_value_amount, Decimal.new("30000"))
      assert Decimal.equal?(total.linked_debt_amount, Decimal.new("18000"))
      assert Decimal.equal?(total.net_equity_amount, Decimal.new("12000"))
    end

    test "labels current, stale, missing, and future valuation dates deterministically" do
      user = user_fixture()

      current =
        unlinked_asset_fixture(user, %{
          name: "Current vehicle",
          last_valued_on: ~D[2026-07-01]
        })

      stale =
        unlinked_asset_fixture(user, %{
          name: "Stale vehicle",
          last_valued_on: ~D[2026-03-01]
        })

      future =
        unlinked_asset_fixture(user, %{
          name: "Future vehicle",
          last_valued_on: ~D[2026-08-01]
        })

      missing =
        unlinked_asset_fixture(user, %{
          name: "Imported legacy asset",
          last_valued_on: nil
        })

      summaries =
        user
        |> Assets.dashboard_summary(today: ~D[2026-07-26])
        |> Map.fetch!(:assets)
        |> Map.new(&{&1.asset.id, &1})

      assert summaries[current.id].valuation_freshness_status == :current
      assert summaries[current.id].valuation_freshness == "Current • valued 25 days ago"
      assert summaries[stale.id].valuation_freshness_status == :stale
      assert summaries[stale.id].valuation_freshness == "Stale • valued 147 days ago"
      assert summaries[future.id].valuation_freshness_status == :future
      assert summaries[future.id].valuation_freshness == "Valuation date is in the future"
      assert summaries[missing.id].valuation_freshness_status == :missing
      assert summaries[missing.id].valuation_freshness == "Valuation date missing"
    end
  end

  describe "MarketCheck vehicle onboarding" do
    setup {Req.Test, :verify_on_exit!}

    test "previews with two quota-counted calls, caches the preview, and saves only after confirmation" do
      user = user_fixture()
      now = ~U[2026-07-01 12:00:00Z]

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/v2/decode/car/1HGCM82633A004352/specs"

        Req.Test.json(conn, %{
          "is_valid" => true,
          "year" => 2003,
          "make" => "Honda",
          "model" => "Accord",
          "trim" => "EX",
          "body_type" => "Sedan"
        })
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/v2/predict/car/us/marketcheck_price"
        Req.Test.json(conn, %{"marketcheck_price" => 12_345, "msrp" => 24_000})
      end)

      input = %{
        vin: "1HGCM82633A004352",
        mileage: 125_000,
        market_region: "60601"
      }

      opts = marketcheck_opts(now, 10)

      assert {:ok, preview} = Assets.preview_vehicle(user, input, opts)
      refute preview.cached?
      assert preview.decoded.make == "Honda"
      assert Decimal.equal?(preview.valuation.value, Decimal.new("12345"))
      assert Assets.list_assets(user) == []
      assert Assets.provider_usage("marketcheck", now: now, monthly_limit: 10).used == 2

      assert {:ok, cached_preview} =
               Assets.preview_vehicle(user, input, Keyword.put(opts, :now, DateTime.add(now, 1)))

      assert cached_preview.cached?
      assert Assets.provider_usage("marketcheck", now: now, monthly_limit: 10).used == 2

      assert {:ok, asset} =
               Assets.create_vehicle_from_preview(user, cached_preview, %{
                 name: "Daily Driver",
                 ownership_type: "individual"
               })

      assert asset.name == "Daily Driver"
      assert asset.asset_type == "vehicle"
      assert asset.vehicle_profile.year == 2003
      assert asset.vehicle_profile.make == "Honda"
      assert asset.vehicle_profile.mileage == 125_000
      assert asset.vehicle_profile.market_region == "60601"

      assert {:ok, [valuation]} = Assets.list_asset_valuations(user, asset)
      assert valuation.source == "provider"
      assert valuation.provider_key == "marketcheck"
      assert Decimal.equal?(valuation.amount, Decimal.new("12345"))
    end

    test "rejects invalid local input without spending provider quota" do
      user = user_fixture()
      now = ~U[2026-07-01 12:00:00Z]

      assert {:error, :invalid_vin} =
               Assets.preview_vehicle(
                 user,
                 %{vin: "invalid", mileage: 10_000, market_region: "60601"},
                 marketcheck_opts(now, 10)
               )

      assert Assets.provider_usage("marketcheck", now: now, monthly_limit: 10).used == 0
    end
  end

  describe "MarketCheck valuation refresh" do
    setup {Req.Test, :verify_on_exit!}

    test "records a baseline, enforces weekly cooldown, and applies a global monthly budget" do
      now = ~U[2026-07-01 12:00:00Z]
      first = provider_ready_vehicle()
      second = provider_ready_vehicle()

      Req.Test.expect(__MODULE__, 2, fn conn ->
        Req.Test.json(conn, %{"marketcheck_price" => 20_000})
      end)

      opts = marketcheck_opts(now, 2)

      assert {:ok, %{valuation: baseline}} =
               Assets.refresh_vehicle_valuation(first, opts)

      assert baseline.source == "provider"
      assert baseline.provider_key == "marketcheck"

      assert {:error, :not_due} =
               Assets.refresh_vehicle_valuation(first, opts)

      week_later = DateTime.add(now, 7, :day)

      assert {:ok, %{valuation: weekly}} =
               Assets.refresh_vehicle_valuation(
                 first,
                 Keyword.put(opts, :now, week_later)
               )

      assert Decimal.equal?(weekly.amount, Decimal.new("20000"))

      assert {:error, :monthly_budget_exhausted} =
               Assets.refresh_vehicle_valuation(
                 second,
                 Keyword.put(opts, :now, week_later)
               )

      assert Assets.provider_usage("marketcheck", now: week_later, monthly_limit: 2) == %{
               provider_key: "marketcheck",
               request_month: ~D[2026-07-01],
               used: 2,
               limit: 2,
               remaining: 0
             }
    end

    test "provider failures consume budget but never replace the last known value" do
      now = ~U[2026-07-01 12:00:00Z]
      asset = provider_ready_vehicle(%{valuation_amount: Decimal.new("15000")})

      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          500,
          Jason.encode!(%{"code" => 500, "message" => "provider error"})
        )
      end)

      assert {:error, {:http_error, 500}} =
               Assets.refresh_vehicle_valuation(asset, marketcheck_opts(now, 10))

      persisted = Repo.get!(Asset, asset.id)
      assert Decimal.equal?(persisted.valuation_amount, Decimal.new("15000"))

      run = Repo.get_by!(ValuationProviderRun, asset_id: asset.id)
      assert run.status == "error"
      assert run.monthly_remaining == 9
      assert run.error_message =~ "http_error"
    end

    test "a recent user-entered override starts the same seven-day cooldown" do
      now = ~U[2026-07-01 12:00:00Z]
      asset = provider_ready_vehicle()

      assert {:ok, %{asset: updated}} =
               Assets.record_valuation(asset.user_id, asset, %{
                 amount: "18000",
                 source: "manual",
                 valued_on: ~D[2026-07-01],
                 manually_overridden: true
               })

      assert {:error, :manual_override_recent} =
               Assets.refresh_vehicle_valuation(updated, marketcheck_opts(now, 10))

      assert Assets.provider_usage("marketcheck", now: now, monthly_limit: 10).used == 0
    end

    test "reserves no more than five provider requests in a one-second window" do
      now = ~U[2026-07-01 12:00:00Z]
      assets = Enum.map(1..6, fn _index -> provider_ready_vehicle() end)

      Req.Test.expect(__MODULE__, 5, fn conn ->
        Req.Test.json(conn, %{"marketcheck_price" => 20_000})
      end)

      opts = marketcheck_opts(now, 10)

      assets
      |> Enum.take(5)
      |> Enum.each(fn asset ->
        assert {:ok, _result} = Assets.refresh_vehicle_valuation(asset, opts)
      end)

      assert {:error, :provider_rate_window_full} =
               assets
               |> List.last()
               |> Assets.refresh_vehicle_valuation(opts)

      assert Assets.provider_usage("marketcheck", now: now, monthly_limit: 10).used == 5
    end
  end

  defp provider_ready_vehicle(attrs \\ %{}) do
    user = user_fixture()
    asset = unlinked_asset_fixture(user, attrs)

    assert {:ok, _profile} =
             Assets.upsert_vehicle_profile(user, asset, %{
               encrypted_vin: "1HGCM82633A004352",
               mileage: 125_000,
               mileage_as_of: ~D[2026-07-01],
               market_region: "60601"
             })

    Assets.get_asset!(user, asset.id)
  end

  defp marketcheck_opts(now, monthly_limit) do
    [
      provider: "marketcheck",
      provider_module: MarketCheck,
      enabled: true,
      settings: %{
        api_key: "test-key",
        base_url: "https://api.marketcheck.test",
        dealer_type: "independent",
        plug: {Req.Test, __MODULE__}
      },
      now: now,
      monthly_limit: monthly_limit,
      refresh_interval_days: 7
    ]
  end
end
