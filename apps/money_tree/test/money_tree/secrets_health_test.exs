defmodule MoneyTree.SecretsHealthTest do
  use ExUnit.Case, async: false

  alias MoneyTree.Secrets.Health

  describe "summary/1" do
    test "reports env backend status without secret values" do
      events = attach_health_telemetry()

      with_env_values(
        ["MONEYTREE_SECRET_BACKEND", "SECRET_BACKEND_MODE", "SECRET_KEY_BASE"],
        %{"SECRET_KEY_BASE" => "super-secret-value"},
        fn ->
          summary = Health.summary()

          assert summary.backend == "env"
          assert summary.selected_by == "default"
          assert summary.status == "configured"
          assert summary.groups["phoenix"].present_keys == 1
          assert summary.groups["phoenix"].missing_keys == []
          refute inspect(summary) =~ "super-secret-value"
        end
      )

      assert_receive {:health_telemetry, %{count: 1},
                      %{backend: :env, status: :configured, live: false}}

      assert_receive {:telemetry_handler_id, ^events}
    end

    test "reports OpenBao configuration errors without live checks" do
      with_env_values(
        openbao_keys(),
        %{"MONEYTREE_SECRET_BACKEND" => "openbao"},
        fn ->
          summary = Health.summary()

          assert summary.backend == "openbao"
          assert summary.selected_by == "MONEYTREE_SECRET_BACKEND"
          assert summary.status == "not_configured"
          assert summary.groups["phoenix"].status == "not_configured"
          assert "OPENBAO_ADDR is required" in summary.groups["phoenix"].errors
        end
      )
    end

    test "does not read OpenBao secrets unless live validation is requested" do
      with_env_values(openbao_keys(), valid_openbao_env(), fn ->
        summary = Health.summary()

        assert summary.backend == "openbao"
        assert summary.status == "configured"
        assert summary.live == false
        assert summary.groups["phoenix"] == %{status: "not_checked"}
      end)
    end
  end

  defp attach_health_telemetry do
    test_pid = self()
    handler_id = "secrets-health-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:money_tree, :secrets, :health, :summary],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:health_telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    send(test_pid, {:telemetry_handler_id, handler_id})
    handler_id
  end

  defp valid_openbao_env do
    %{
      "MONEYTREE_SECRET_BACKEND" => "openbao",
      "OPENBAO_ADDR" => "https://bao.example.com",
      "OPENBAO_AUTH_METHOD" => "approle",
      "OPENBAO_ROLE_ID" => "role-id",
      "OPENBAO_SECRET_ID" => "secret-id",
      "OPENBAO_KV_PREFIX" => "kv/data/moneytree/dev"
    }
  end

  defp openbao_keys do
    ~w(
      MONEYTREE_SECRET_BACKEND
      SECRET_BACKEND_MODE
      OPENBAO_ADDR
      OPENBAO_NAMESPACE
      OPENBAO_AUTH_METHOD
      OPENBAO_ROLE_ID
      OPENBAO_SECRET_ID
      OPENBAO_KV_PREFIX
      OPENBAO_SSL_VERIFY
      OPENBAO_TIMEOUT_MS
    )
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
end
