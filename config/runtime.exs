import Config

base_teller_config = Application.get_env(:money_tree, MoneyTree.Teller, [])

default_next_upstream = [scheme: "http", host: "localhost", port: 3000, path: "/"]

next_proxy_url = System.get_env("NEXT_PROXY_URL")

env_upstream_overrides =
  [:scheme, :host, :port, :path]
  |> Enum.reduce([], fn key, acc ->
    env_key = "NEXT_PROXY_" <> (key |> Atom.to_string() |> String.upcase())

    case System.get_env(env_key) do
      nil ->
        acc

      "" ->
        acc

      value ->
        normalized =
          case key do
            :port -> String.to_integer(value)
            _ -> value
          end

        Keyword.put(acc, key, normalized)
    end
  end)

cond do
  next_proxy_url ->
    config :money_tree, MoneyTreeWeb.Plugs.NextProxy, upstream: next_proxy_url

  env_upstream_overrides != [] ->
    config :money_tree, MoneyTreeWeb.Plugs.NextProxy,
      upstream: Keyword.merge(default_next_upstream, env_upstream_overrides)

  true ->
    :ok
end

client_timeout_overrides =
  [
    {:receive_timeout, System.get_env("NEXT_PROXY_RECEIVE_TIMEOUT_MS")},
    {:pool_timeout, System.get_env("NEXT_PROXY_POOL_TIMEOUT_MS")}
  ]
  |> Enum.reduce([], fn
    {_key, nil}, acc -> acc
    {_key, ""}, acc -> acc
    {key, value}, acc -> Keyword.put(acc, key, String.to_integer(value))
  end)

if client_timeout_overrides != [] do
  existing =
    Application.get_env(:money_tree, MoneyTreeWeb.Plugs.NextProxy, [])
    |> Keyword.get(:client_opts, [])

  merged_client_opts = Keyword.merge(existing, client_timeout_overrides)

  config :money_tree, MoneyTreeWeb.Plugs.NextProxy, client_opts: merged_client_opts
end

if config_env() == :prod do
  missing_teller_env =
    [
      "TELLER_API_KEY",
      "TELLER_CONNECT_APPLICATION_ID",
      "TELLER_WEBHOOK_SECRET"
    ]
    |> Enum.filter(fn env -> System.get_env(env) in [nil, ""] end)

  if missing_teller_env != [] do
    raise """
    environment variables #{Enum.join(missing_teller_env, ", ")} are required in production for Teller integration.
    """
  end
end

teller_env = fn key ->
  case System.get_env(key) do
    nil -> nil
    "" -> nil
    value -> value
  end
end

cert_file = teller_env.("TELLER_CERT_FILE") || teller_env.("TELLER_CERT_PATH")
key_file = teller_env.("TELLER_KEY_FILE") || teller_env.("TELLER_KEY_PATH")

teller_runtime_config =
  [
    api_key: teller_env.("TELLER_API_KEY"),
    connect_application_id: teller_env.("TELLER_CONNECT_APPLICATION_ID"),
    webhook_secret: teller_env.("TELLER_WEBHOOK_SECRET"),
    api_host: teller_env.("TELLER_API_HOST"),
    connect_host: teller_env.("TELLER_CONNECT_HOST"),
    webhook_host: teller_env.("TELLER_WEBHOOK_HOST"),
    client_cert_pem: teller_env.("TELLER_CERT_PEM"),
    client_key_pem: teller_env.("TELLER_KEY_PEM"),
    client_cert_file: cert_file,
    client_key_file: key_file
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

config :money_tree, MoneyTree.Teller, Keyword.merge(base_teller_config, teller_runtime_config)

if config_env() != :test do
  default_limit = System.get_env("OBAN_DEFAULT_LIMIT") || "10"
  mailer_limit = System.get_env("OBAN_MAILER_LIMIT") || "5"
  reporting_limit = System.get_env("OBAN_REPORTING_LIMIT") || "5"

  config :money_tree, Oban,
    queues: [
      default: String.to_integer(default_limit),
      mailers: String.to_integer(mailer_limit),
      reporting: String.to_integer(reporting_limit)
    ]

  if otlp_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
    config :opentelemetry, :exporters, otlp: [endpoint: otlp_endpoint, protocol: :http_protobuf]
  end
end

vault_key =
  System.get_env("CLOAK_VAULT_KEY") ||
    if config_env() == :prod do
      raise """
      environment variable CLOAK_VAULT_KEY is missing.
      Provide a base64-encoded 128, 192, or 256-bit key for Cloak.
      """
    else
      "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="
    end

decoded_vault_key =
  case Base.decode64(vault_key) do
    {:ok, key} when byte_size(key) in [16, 24, 32] ->
      key

    _ ->
      raise """
      environment variable CLOAK_VAULT_KEY must be valid base64 representing a 128/192/256-bit key.
      """
  end

config :money_tree, MoneyTree.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1", key: decoded_vault_key, iv_length: 12
    }
  ]

if System.get_env("PHX_SERVER") do
  config :money_tree, MoneyTreeWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_url = System.get_env("DATABASE_URL")
  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  repo_config =
    if database_url do
      [url: database_url]
    else
      [
        username:
          System.get_env("DATABASE_USERNAME") ||
            raise("environment variable DATABASE_USERNAME is missing."),
        password:
          System.get_env("DATABASE_PASSWORD") ||
            raise("environment variable DATABASE_PASSWORD is missing."),
        hostname:
          System.get_env("DATABASE_HOST") ||
            raise("environment variable DATABASE_HOST is missing."),
        database:
          System.get_env("DATABASE_NAME") ||
            raise("environment variable DATABASE_NAME is missing."),
        port: String.to_integer(System.get_env("DATABASE_PORT") || "5432")
      ]
    end

  repo_config =
    repo_config
    |> Keyword.put(:pool_size, String.to_integer(System.get_env("POOL_SIZE") || "10"))
    |> Keyword.put(:socket_options, maybe_ipv6)

  repo_config =
    if System.get_env("DATABASE_SSL", "false") in ~w(true 1) do
      Keyword.put_new(repo_config, :ssl, true)
    else
      repo_config
    end

  config :money_tree, MoneyTree.Repo, repo_config

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :money_tree, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :money_tree, MoneyTreeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base
end
