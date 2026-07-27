defmodule MoneyTree.Assets.VehicleValuationProviders.MarketCheckTest do
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias MoneyTree.Assets.VehicleValuationProviders.MarketCheck

  setup {Req.Test, :verify_on_exit!}

  test "decodes a VIN with the basic specs endpoint" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/v2/decode/car/1HGCM82633A004352/specs"
      assert conn.query_params["api_key"] == "test-key"

      Req.Test.json(conn, %{
        "is_valid" => true,
        "year" => 2003,
        "make" => "Honda",
        "model" => "Accord",
        "trim" => "EX",
        "body_type" => "Sedan"
      })
    end)

    assert {:ok, decoded} =
             MarketCheck.decode_vin("1hgcm82633a004352", %{
               api_key: "test-key",
               base_url: "https://api.marketcheck.test",
               plug: {Req.Test, __MODULE__}
             })

    assert decoded == %{
             year: 2003,
             make: "Honda",
             model: "Accord",
             trim: "EX",
             body_style: "Sedan"
           }
  end

  test "uses one base-tier price request and normalizes the response" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/v2/predict/car/us/marketcheck_price"
      assert conn.query_params["api_key"] == "test-key"
      assert conn.query_params["vin"] == "1HGCM82633A004352"
      assert conn.query_params["miles"] == "125000"
      assert conn.query_params["zip"] == "60601"
      assert conn.query_params["dealer_type"] == "independent"

      Req.Test.json(conn, %{"marketcheck_price" => 12_345, "msrp" => 30_000})
    end)

    settings = %{
      api_key: "test-key",
      base_url: "https://api.marketcheck.test",
      dealer_type: "independent",
      plug: {Req.Test, __MODULE__}
    }

    vehicle = %{
      vin: "1HGCM82633A004352",
      mileage: 125_000,
      market_region: "60601"
    }

    assert {:ok, valuation} = MarketCheck.fetch_valuation(vehicle, settings)
    assert D.equal?(valuation.value, D.new("12345"))
    assert valuation.confidence == nil
    assert valuation.raw["msrp"] == 30_000
  end

  test "does not make a request without complete provider inputs" do
    assert {:error, :missing_api_key} =
             MarketCheck.fetch_valuation(
               %{vin: "1HGCM82633A004352", mileage: 10_000, market_region: "60601"},
               %{}
             )

    assert {:error, :invalid_vehicle} =
             MarketCheck.fetch_valuation(
               %{vin: "1HGCM82633A004352", mileage: nil, market_region: "60601"},
               %{api_key: "test-key", plug: {Req.Test, __MODULE__}}
             )
  end

  test "normalizes quota responses without retrying" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("quota-remaining", "0")
      |> Plug.Conn.send_resp(429, Jason.encode!(%{"message" => "Monthly API quota exhausted"}))
    end)

    assert {:error, :rate_limited} =
             MarketCheck.fetch_valuation(
               %{vin: "1HGCM82633A004352", mileage: 10_000, market_region: "60601"},
               %{api_key: "test-key", plug: {Req.Test, __MODULE__}}
             )
  end

  test "normalizes a timeout without retrying" do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, :timeout} =
             MarketCheck.fetch_valuation(
               %{vin: "1HGCM82633A004352", mileage: 10_000, market_region: "60601"},
               %{api_key: "test-key", plug: {Req.Test, __MODULE__}}
             )
  end

  test "rejects malformed successful responses" do
    assert {:error, :invalid_vehicle} =
             MarketCheck.normalize_decode_response(%{"is_valid" => false})

    assert {:error, :invalid_response} =
             MarketCheck.normalize_decode_response(%{"is_valid" => true, "year" => 2003})

    assert {:error, :invalid_response} = MarketCheck.normalize_response(%{"msrp" => 30_000})

    assert {:error, :invalid_response} =
             MarketCheck.normalize_response(%{"marketcheck_price" => -1})
  end
end
