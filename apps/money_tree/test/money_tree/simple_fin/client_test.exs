defmodule MoneyTree.SimpleFin.ClientTest do
  use ExUnit.Case, async: true

  alias MoneyTree.SimpleFin.Client
  alias MoneyTree.SimpleFin.Redaction

  test "decodes strict Base64 setup tokens" do
    token = Base.encode64("https://bridge.simplefin.org/claim/demo")

    assert {:ok, "https://bridge.simplefin.org/claim/demo"} = Client.decode_setup_token(token)
  end

  test "rejects invalid setup tokens" do
    assert {:error, :invalid_setup_token} = Client.decode_setup_token("not base64")
    assert {:error, :invalid_setup_token} = Client.decode_setup_token(Base.encode64("not a url"))
  end

  test "requires secure claim and access URLs" do
    assert :ok = Client.validate_claim_url("https://bridge.simplefin.org/claim")

    assert {:error, :insecure_claim_url} =
             Client.validate_claim_url("http://bridge.simplefin.org/claim")

    assert {:error, :invalid_access_url} =
             Client.validate_access_url("http://user:pass@bridge.simplefin.org/simplefin")
  end

  test "rejects private, loopback, and link-local IP literals" do
    assert {:error, :insecure_claim_url} = Client.validate_claim_url("https://127.0.0.1/claim")
    assert {:error, :insecure_claim_url} = Client.validate_claim_url("https://10.0.0.5/claim")
    assert {:error, :insecure_claim_url} = Client.validate_claim_url("https://192.168.1.1/claim")

    assert {:error, :insecure_claim_url} =
             Client.validate_claim_url("https://169.254.169.254/claim")

    assert {:error, :invalid_access_url} =
             Client.validate_access_url("https://user:pass@127.0.0.1/simplefin")
  end

  test "redacts access URL credentials" do
    assert Redaction.redact("https://user:pass@bridge.simplefin.org/simplefin") ==
             "https://[redacted]@bridge.simplefin.org/simplefin"
  end

  test "returns SimpleFIN provider errors with account payload instead of failing the request" do
    adapter = fn request ->
      assert URI.parse(request.url).path == "/simplefin/accounts"
      params = URI.decode_query(URI.parse(request.url).query)
      assert params["start-date"] == "1772323200"
      assert params["end-date"] == "1772409600"

      response = %Req.Response{
        status: 200,
        body: %{
          "accounts" => [%{"id" => "acct-1"}],
          "errlist" => [%{"code" => "con.auth", "msg" => "Auth required"}]
        }
      }

      {request, response}
    end

    client = Client.new(adapter: adapter, retry: false)

    assert {:ok, response} =
             Client.get_accounts(client, "https://user:pass@bridge.simplefin.org/simplefin",
               start_date: ~D[2026-03-01],
               end_date: ~D[2026-03-02]
             )

    assert [%{"id" => "acct-1"}] = response["accounts"]
    assert [%{"code" => "con.auth", "msg" => "Auth required"}] = response["errors"]
  end
end
