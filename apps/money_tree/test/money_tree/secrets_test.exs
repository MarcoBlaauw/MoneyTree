defmodule MoneyTree.SecretsTest do
  use ExUnit.Case, async: false

  alias MoneyTree.Secrets
  alias MoneyTree.Secrets.Env
  alias MoneyTree.Secrets.OpenBao

  setup {Req.Test, :verify_on_exit!}

  describe "env provider" do
    test "normalizes missing and empty values to nil" do
      with_env("MONEYTREE_TEST_SECRET", nil, fn ->
        assert Env.get("MONEYTREE_TEST_SECRET") == nil
      end)

      with_env("MONEYTREE_TEST_SECRET", "", fn ->
        assert Env.get("MONEYTREE_TEST_SECRET") == nil
      end)
    end

    test "returns present environment values" do
      with_env("MONEYTREE_TEST_SECRET", "secret-value", fn ->
        assert Env.get("MONEYTREE_TEST_SECRET") == "secret-value"
      end)
    end

    test "returns known secret groups with normalized values" do
      with_env("PLAID_SECRET", "plaid-secret", fn ->
        group = Env.get_group(:plaid)

        assert group["PLAID_SECRET"] == "plaid-secret"
        assert Map.has_key?(group, "PLAID_CLIENT_ID")
        assert Map.has_key?(group, "PLAID_WEBHOOK_SECRET")
      end)
    end

    test "returns the FRED API key from its dedicated group" do
      with_env("FRED_API_KEY", "fred-secret", fn ->
        assert Env.get_group(:fred) == %{"FRED_API_KEY" => "fred-secret"}
      end)
    end

    test "returns the MarketCheck API key from its dedicated group" do
      with_env("MARKETCHECK_API_KEY", "marketcheck-secret", fn ->
        assert Env.get_group(:marketcheck) == %{
                 "MARKETCHECK_API_KEY" => "marketcheck-secret"
               }
      end)
    end

    test "unknown groups are empty maps" do
      assert Env.get_group(:unknown_group) == %{}
    end
  end

  describe "provider selection" do
    test "defaults to env provider" do
      with_env("MONEYTREE_SECRET_BACKEND", nil, fn ->
        assert Secrets.provider_from_env() == Env
      end)
    end

    test "uses env provider for explicit env mode" do
      with_env("MONEYTREE_SECRET_BACKEND", "env", fn ->
        assert Secrets.provider_from_env() == Env
      end)
    end

    test "uses openbao provider for explicit openbao mode" do
      with_env("MONEYTREE_SECRET_BACKEND", "openbao", fn ->
        assert Secrets.provider_from_env() == OpenBao
      end)
    end

    test "supports SECRET_BACKEND_MODE compatibility alias" do
      with_env("MONEYTREE_SECRET_BACKEND", nil, fn ->
        with_env("SECRET_BACKEND_MODE", "openbao", fn ->
          assert Secrets.provider_from_env() == OpenBao
        end)
      end)
    end

    test "MONEYTREE_SECRET_BACKEND takes precedence over SECRET_BACKEND_MODE" do
      with_env("MONEYTREE_SECRET_BACKEND", "env", fn ->
        with_env("SECRET_BACKEND_MODE", "openbao", fn ->
          assert Secrets.provider_from_env() == Env
        end)
      end)
    end

    test "falls back to env provider for unsupported modes" do
      events = attach_provider_fallback_telemetry()

      with_env("MONEYTREE_SECRET_BACKEND", "unknown", fn ->
        assert Secrets.provider_from_env() == Env
      end)

      assert_receive {:provider_fallback_telemetry, %{count: 1},
                      %{
                        requested_mode: "unknown",
                        selected_by: "MONEYTREE_SECRET_BACKEND",
                        fallback_backend: :env
                      }}

      assert_receive {:telemetry_handler_id, ^events}
    end
  end

  describe "openbao provider config" do
    test "validates required configuration" do
      with_openbao_env(%{}, fn ->
        assert {:error, errors} = OpenBao.config()

        assert "OPENBAO_ADDR is required" in errors
        assert "OPENBAO_AUTH_METHOD is required" in errors
        assert "OPENBAO_KV_PREFIX is required" in errors
      end)
    end

    test "requires approle credentials for approle auth" do
      with_openbao_env(
        %{
          "OPENBAO_ADDR" => "https://bao.example.com",
          "OPENBAO_AUTH_METHOD" => "approle",
          "OPENBAO_KV_PREFIX" => "kv/data/moneytree/dev"
        },
        fn ->
          assert {:error, errors} = OpenBao.config()

          assert "OPENBAO_ROLE_ID is required" in errors
          assert "OPENBAO_SECRET_ID is required" in errors
        end
      )
    end

    test "normalizes valid OpenBao metadata" do
      with_openbao_env(
        %{
          "OPENBAO_ADDR" => "https://bao.example.com/",
          "OPENBAO_AUTH_METHOD" => "approle",
          "OPENBAO_ROLE_ID" => "role-id",
          "OPENBAO_SECRET_ID" => "secret-id",
          "OPENBAO_KV_PREFIX" => "/kv/data/moneytree/dev/",
          "OPENBAO_NAMESPACE" => "moneytree",
          "OPENBAO_SSL_VERIFY" => "false",
          "OPENBAO_TIMEOUT_MS" => "1234"
        },
        fn ->
          assert {:ok, config} = OpenBao.config()

          assert config.addr == "https://bao.example.com"
          assert config.auth_method == "approle"
          assert config.role_id == "role-id"
          assert config.secret_id == "secret-id"
          assert config.kv_prefix == "kv/data/moneytree/dev"
          assert config.namespace == "moneytree"
          assert config.ssl_verify == false
          assert config.timeout_ms == 1234
        end
      )
    end

    test "maps known secret groups to configured KV paths" do
      with_openbao_env(valid_openbao_env(), fn ->
        assert {:ok, config} = OpenBao.config()

        assert OpenBao.path_for_group(:database, config) ==
                 {:ok, "kv/data/moneytree/dev/database"}

        assert OpenBao.path_for_group(:cloak, config) ==
                 {:ok, "kv/data/moneytree/dev/cloak"}

        assert OpenBao.path_for_group(:fred, config) ==
                 {:ok, "kv/data/moneytree/dev/fred"}

        assert OpenBao.path_for_group(:marketcheck, config) ==
                 {:ok, "kv/data/moneytree/dev/marketcheck"}

        assert OpenBao.path_for_group(:phoenix, config) ==
                 {:ok, "kv/data/moneytree/dev/phoenix"}

        assert OpenBao.path_for_group(:plaid, config) ==
                 {:ok, "kv/data/moneytree/dev/plaid"}

        assert OpenBao.path_for_group(:smtp, config) ==
                 {:ok, "kv/data/moneytree/dev/smtp"}

        assert OpenBao.path_for_group(:unknown, config) == {:error, :unknown_group}
      end)
    end

    test "normalizes KV v2 secret payloads" do
      payload = %{
        "data" => %{
          "data" => %{
            "SECRET_KEY_BASE" => "secret",
            :CLOAK_VAULT_KEY => "vault-key",
            "EMPTY" => nil
          },
          "metadata" => %{"version" => 1}
        }
      }

      assert OpenBao.normalize_secret_payload(payload) ==
               {:ok,
                %{
                  "SECRET_KEY_BASE" => "secret",
                  "CLOAK_VAULT_KEY" => "vault-key"
                }}
    end

    test "normalizes flat KV payloads" do
      payload = %{"data" => %{"MAILER_SMTP_HOST" => "email.example.com"}}

      assert OpenBao.normalize_secret_payload(payload) ==
               {:ok, %{"MAILER_SMTP_HOST" => "email.example.com"}}
    end

    test "rejects invalid secret payloads" do
      assert OpenBao.normalize_secret_payload(%{"data" => nil}) == {:error, :invalid_payload}
      assert OpenBao.normalize_secret_payload(%{}) == {:error, :invalid_payload}
    end

    test "rejects invalid metadata values" do
      with_openbao_env(
        %{
          "OPENBAO_ADDR" => "not-a-url",
          "OPENBAO_AUTH_METHOD" => "token",
          "OPENBAO_KV_PREFIX" => "kv/data/moneytree/dev",
          "OPENBAO_SSL_VERIFY" => "maybe",
          "OPENBAO_TIMEOUT_MS" => "abc"
        },
        fn ->
          assert {:error, errors} = OpenBao.config()

          assert "OPENBAO_ADDR must be an http or https URL" in errors
          assert "OPENBAO_AUTH_METHOD must be one of approle" in errors
          assert "OPENBAO_SSL_VERIFY must be true or false" in errors
          assert "OPENBAO_TIMEOUT_MS must be a positive integer" in errors
        end
      )
    end

    test "authenticates with AppRole" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/auth/approle/login"

        assert %{"role_id" => "role-id", "secret_id" => "secret-id"} =
                 conn |> Req.Test.raw_body() |> Jason.decode!()

        Req.Test.json(conn, %{"auth" => %{"client_token" => "bao-token"}})
      end)

      with_openbao_env(valid_openbao_env(), fn ->
        assert {:ok, config} = OpenBao.config()
        assert OpenBao.authenticate(config, plug: {Req.Test, __MODULE__}) == {:ok, "bao-token"}
      end)
    end

    test "reads a KV path with vault token and namespace headers" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/kv/data/moneytree/dev/phoenix"
        assert Plug.Conn.get_req_header(conn, "x-vault-token") == ["bao-token"]
        assert Plug.Conn.get_req_header(conn, "x-vault-namespace") == ["moneytree"]

        Req.Test.json(conn, %{"data" => %{"data" => %{"SECRET_KEY_BASE" => "secret"}}})
      end)

      with_openbao_env(Map.put(valid_openbao_env(), "OPENBAO_NAMESPACE", "moneytree"), fn ->
        assert {:ok, config} = OpenBao.config()

        assert OpenBao.read_path(
                 config,
                 "kv/data/moneytree/dev/phoenix",
                 "bao-token",
                 plug: {Req.Test, __MODULE__}
               ) ==
                 {:ok, %{"data" => %{"data" => %{"SECRET_KEY_BASE" => "secret"}}}}
      end)
    end

    test "reads a configured secret group" do
      Req.Test.expect(__MODULE__, 2, fn
        %{method: "POST", request_path: "/v1/auth/approle/login"} = conn ->
          Req.Test.json(conn, %{"auth" => %{"client_token" => "bao-token"}})

        %{method: "GET", request_path: "/v1/kv/data/moneytree/dev/phoenix"} = conn ->
          Req.Test.json(conn, %{"data" => %{"data" => %{"SECRET_KEY_BASE" => "secret"}}})
      end)

      with_openbao_env(valid_openbao_env(), fn ->
        assert OpenBao.get_group(:phoenix, plug: {Req.Test, __MODULE__}) ==
                 %{"SECRET_KEY_BASE" => "secret"}
      end)
    end

    test "emits sanitized telemetry for successful auth and read" do
      events = attach_openbao_telemetry()

      Req.Test.expect(__MODULE__, 2, fn
        %{method: "POST", request_path: "/v1/auth/approle/login"} = conn ->
          Req.Test.json(conn, %{"auth" => %{"client_token" => "bao-token"}})

        %{method: "GET", request_path: "/v1/kv/data/moneytree/dev/phoenix"} = conn ->
          Req.Test.json(conn, %{"data" => %{"data" => %{"SECRET_KEY_BASE" => "secret"}}})
      end)

      with_openbao_env(valid_openbao_env(), fn ->
        assert OpenBao.get_group(:phoenix, plug: {Req.Test, __MODULE__}) ==
                 %{"SECRET_KEY_BASE" => "secret"}
      end)

      assert_receive {:openbao_telemetry, measurements,
                      %{operation: :auth, status: :ok} = metadata}

      assert is_integer(measurements.duration)
      assert metadata.backend == :openbao
      refute Map.has_key?(metadata, :secret_group)
      refute inspect(metadata) =~ "bao-token"
      refute inspect(metadata) =~ "SECRET_KEY_BASE"

      assert_receive {:openbao_telemetry, measurements,
                      %{operation: :read, status: :ok} = metadata}

      assert is_integer(measurements.duration)
      assert metadata.backend == :openbao
      assert metadata.secret_group == :phoenix
      refute inspect(metadata) =~ "bao-token"
      refute inspect(metadata) =~ "SECRET_KEY_BASE"

      assert_receive {:telemetry_handler_id, ^events}
    end

    test "reads a single known secret key" do
      Req.Test.expect(__MODULE__, 2, fn
        %{method: "POST", request_path: "/v1/auth/approle/login"} = conn ->
          Req.Test.json(conn, %{"auth" => %{"client_token" => "bao-token"}})

        %{method: "GET", request_path: "/v1/kv/data/moneytree/dev/phoenix"} = conn ->
          Req.Test.json(conn, %{"data" => %{"data" => %{"SECRET_KEY_BASE" => "secret"}}})
      end)

      with_openbao_env(valid_openbao_env(), fn ->
        assert OpenBao.get("SECRET_KEY_BASE", plug: {Req.Test, __MODULE__}) == "secret"
        assert OpenBao.get("UNKNOWN_SECRET", plug: {Req.Test, __MODULE__}) == nil
      end)
    end

    test "reads the FRED API key from its dedicated group" do
      Req.Test.expect(__MODULE__, 2, fn
        %{method: "POST", request_path: "/v1/auth/approle/login"} = conn ->
          Req.Test.json(conn, %{"auth" => %{"client_token" => "bao-token"}})

        %{method: "GET", request_path: "/v1/kv/data/moneytree/dev/fred"} = conn ->
          Req.Test.json(conn, %{"data" => %{"data" => %{"FRED_API_KEY" => "fred-secret"}}})
      end)

      with_openbao_env(valid_openbao_env(), fn ->
        assert OpenBao.get("FRED_API_KEY", plug: {Req.Test, __MODULE__}) == "fred-secret"
      end)
    end

    test "reads the MarketCheck API key from its dedicated group" do
      Req.Test.expect(__MODULE__, 2, fn
        %{method: "POST", request_path: "/v1/auth/approle/login"} = conn ->
          Req.Test.json(conn, %{"auth" => %{"client_token" => "bao-token"}})

        %{method: "GET", request_path: "/v1/kv/data/moneytree/dev/marketcheck"} = conn ->
          Req.Test.json(conn, %{
            "data" => %{"data" => %{"MARKETCHECK_API_KEY" => "marketcheck-secret"}}
          })
      end)

      with_openbao_env(valid_openbao_env(), fn ->
        assert OpenBao.get("MARKETCHECK_API_KEY", plug: {Req.Test, __MODULE__}) ==
                 "marketcheck-secret"
      end)
    end

    test "keeps non-secret runtime configuration in the environment" do
      with_env("MAILER_FROM_EMAIL", "local@example.test", fn ->
        assert OpenBao.get("MAILER_FROM_EMAIL", plug: {Req.Test, __MODULE__}) ==
                 "local@example.test"
      end)
    end

    test "raises a clear error when OpenBao read fails" do
      events = attach_openbao_telemetry()

      Req.Test.expect(__MODULE__, 2, fn
        %{method: "POST", request_path: "/v1/auth/approle/login"} = conn ->
          Req.Test.json(conn, %{"auth" => %{"client_token" => "bao-token"}})

        %{method: "GET", request_path: "/v1/kv/data/moneytree/dev/phoenix"} = conn ->
          Plug.Conn.send_resp(conn, 404, "not found")
      end)

      with_openbao_env(valid_openbao_env(), fn ->
        assert_raise RuntimeError, ~r/path not found/, fn ->
          OpenBao.get_group(:phoenix, plug: {Req.Test, __MODULE__})
        end
      end)

      assert_receive {:openbao_telemetry, _measurements, %{operation: :auth, status: :ok}}

      assert_receive {:openbao_telemetry, _measurements,
                      %{
                        operation: :read,
                        status: :error,
                        secret_group: :phoenix,
                        error: "path not found"
                      }}

      assert_receive {:telemetry_handler_id, ^events}
    end
  end

  defp attach_openbao_telemetry do
    test_pid = self()
    handler_id = "openbao-secrets-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:money_tree, :secrets, :openbao, :request],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:openbao_telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    send(test_pid, {:telemetry_handler_id, handler_id})
    handler_id
  end

  defp attach_provider_fallback_telemetry do
    test_pid = self()
    handler_id = "provider-fallback-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:money_tree, :secrets, :provider, :fallback],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:provider_fallback_telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    send(test_pid, {:telemetry_handler_id, handler_id})
    handler_id
  end

  defp valid_openbao_env do
    %{
      "OPENBAO_ADDR" => "https://bao.example.com",
      "OPENBAO_AUTH_METHOD" => "approle",
      "OPENBAO_ROLE_ID" => "role-id",
      "OPENBAO_SECRET_ID" => "secret-id",
      "OPENBAO_KV_PREFIX" => "kv/data/moneytree/dev"
    }
  end

  defp with_openbao_env(values, fun) when is_map(values) and is_function(fun, 0) do
    keys = ~w(
      OPENBAO_ADDR
      OPENBAO_NAMESPACE
      OPENBAO_AUTH_METHOD
      OPENBAO_ROLE_ID
      OPENBAO_SECRET_ID
      OPENBAO_KV_PREFIX
      OPENBAO_SSL_VERIFY
      OPENBAO_TIMEOUT_MS
    )

    with_env_values(keys, values, fun)
  end

  defp with_env_values(keys, values, fun) do
    originals = Map.new(keys, fn key -> {key, System.get_env(key)} end)

    try do
      Enum.each(keys, fn key ->
        case Map.get(values, key) do
          nil -> System.delete_env(key)
          value -> System.put_env(key, value)
        end
      end)

      fun.()
    after
      Enum.each(originals, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp with_env(key, value, fun) when is_function(fun, 0) do
    original = System.get_env(key)

    try do
      case value do
        nil -> System.delete_env(key)
        value -> System.put_env(key, value)
      end

      fun.()
    after
      case original do
        nil -> System.delete_env(key)
        value -> System.put_env(key, value)
      end
    end
  end
end
