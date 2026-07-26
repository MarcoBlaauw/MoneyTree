import Config

secret_provider = MoneyTree.Secrets.provider_from_env()

env = fn key ->
  MoneyTree.Secrets.get(key, secret_provider)
end

parse_csv_env = fn value ->
  value
  |> to_string()
  |> String.split(",")
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
end

parse_bool_env = fn
  value when value in [true, false] ->
    value

  value when is_binary(value) ->
    String.downcase(String.trim(value)) in ["true", "1", "yes", "on"]

  _value ->
    false
end

base_provider_registry_config =
  Application.get_env(:money_tree, MoneyTree.BankSync.ProviderRegistry, [])

enabled_bank_sync_providers =
  case env.("BANK_SYNC_ENABLED_PROVIDERS") do
    nil -> Keyword.get(base_provider_registry_config, :enabled_providers, ["simplefin", "manual"])
    value -> parse_csv_env.(value)
  end

bank_sync_primary_provider =
  env.("BANK_SYNC_PRIMARY_PROVIDER") ||
    Keyword.get(base_provider_registry_config, :primary_provider, "simplefin")

config :money_tree, MoneyTree.BankSync.ProviderRegistry,
  enabled_providers: enabled_bank_sync_providers,
  primary_provider: bank_sync_primary_provider

plaid_enabled? =
  "plaid" in enabled_bank_sync_providers or parse_bool_env.(env.("PLAID_ENABLED"))

simplefin_runtime_config =
  [
    create_url: env.("SIMPLEFIN_CREATE_URL"),
    protocol_version: env.("SIMPLEFIN_PROTOCOL_VERSION"),
    sync_interval_hours: env.("SIMPLEFIN_SYNC_INTERVAL_HOURS"),
    max_requests_per_connection_per_day: env.("SIMPLEFIN_MAX_REQUESTS_PER_CONNECTION_PER_DAY"),
    initial_sync_days: env.("SIMPLEFIN_INITIAL_SYNC_DAYS"),
    include_pending: env.("SIMPLEFIN_INCLUDE_PENDING")
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  |> Enum.map(fn
    {key, value}
    when key in [:sync_interval_hours, :max_requests_per_connection_per_day, :initial_sync_days] ->
      {key, String.to_integer(value)}

    {:include_pending, value} ->
      {:include_pending, parse_bool_env.(value)}

    pair ->
      pair
  end)

config :money_tree,
       MoneyTree.SimpleFin,
       Keyword.merge(
         Application.get_env(:money_tree, MoneyTree.SimpleFin, []),
         simplefin_runtime_config
       )

base_plaid_config = Application.get_env(:money_tree, MoneyTree.Plaid, [])

plaid_products =
  case env.("PLAID_PRODUCTS") do
    nil -> nil
    csv -> parse_csv_env.(csv)
  end

plaid_country_codes =
  case env.("PLAID_COUNTRY_CODES") do
    nil -> nil
    csv -> parse_csv_env.(csv)
  end

plaid_api_host =
  case env.("PLAID_API_HOST") do
    nil ->
      case env.("PLAID_ENV") do
        "production" -> "https://production.plaid.com"
        "development" -> "https://development.plaid.com"
        _ -> "https://sandbox.plaid.com"
      end

    host ->
      host
  end

plaid_runtime_config =
  [
    client_id: env.("PLAID_CLIENT_ID"),
    secret: env.("PLAID_SECRET"),
    environment: env.("PLAID_ENV"),
    products: plaid_products,
    country_codes: plaid_country_codes,
    redirect_uri: env.("PLAID_REDIRECT_URI"),
    webhook_secret: env.("PLAID_WEBHOOK_SECRET"),
    client_name: env.("PLAID_CLIENT_NAME"),
    language: env.("PLAID_LANGUAGE"),
    api_host: plaid_api_host
  ]
  |> Enum.reject(fn
    {_key, nil} -> true
    {_key, []} -> true
    _ -> false
  end)

config :money_tree, MoneyTree.Plaid, Keyword.merge(base_plaid_config, plaid_runtime_config)

if config_env() == :prod and plaid_enabled? do
  missing_plaid_env =
    ["PLAID_CLIENT_ID", "PLAID_SECRET"]
    |> Enum.filter(fn key -> env.(key) in [nil, ""] end)

  if missing_plaid_env != [] do
    raise """
    environment variables #{Enum.join(missing_plaid_env, ", ")} are required in production when Plaid is enabled.
    """
  end
end

fred_env = env

base_fred_config = Application.get_env(:money_tree, MoneyTree.Loans.RateProviders.Fred, [])

fred_runtime_config =
  [
    api_key: fred_env.("FRED_API_KEY"),
    base_url: fred_env.("FRED_BASE_URL")
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

config :money_tree,
       MoneyTree.Loans.RateProviders.Fred,
       Keyword.merge(base_fred_config, fred_runtime_config)

ai_env = env

ai_runtime_config =
  [
    enabled:
      case ai_env.("AI_ENABLED") do
        nil -> nil
        value -> parse_bool_env.(value)
      end,
    require_confirmation:
      case ai_env.("AI_REQUIRE_CONFIRMATION") do
        nil -> nil
        value -> parse_bool_env.(value)
      end,
    default_provider: ai_env.("AI_PROVIDER"),
    max_input_transactions:
      case ai_env.("OLLAMA_MAX_INPUT_TRANSACTIONS") do
        nil -> nil
        value -> String.to_integer(value)
      end
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

ollama_runtime_config =
  [
    base_url: ai_env.("OLLAMA_BASE_URL"),
    model: ai_env.("OLLAMA_MODEL"),
    timeout_ms:
      case ai_env.("OLLAMA_TIMEOUT_MS") do
        nil -> nil
        value -> String.to_integer(value)
      end
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

if ai_runtime_config != [] or ollama_runtime_config != [] do
  base_ai_config = Application.get_env(:money_tree, MoneyTree.AI, [])
  base_ollama_config = Keyword.get(base_ai_config, :ollama, [])

  merged_ai_config =
    base_ai_config
    |> Keyword.merge(ai_runtime_config)
    |> Keyword.put(:ollama, Keyword.merge(base_ollama_config, ollama_runtime_config))

  config :money_tree, MoneyTree.AI, merged_ai_config
end

mailer_env = env

mail_from_name = mailer_env.("MAILER_FROM_NAME") || "MoneyTree"
mail_from_email = mailer_env.("MAILER_FROM_EMAIL") || "no-reply@moneytree.app"

config :money_tree, :notification_sender, {mail_from_name, mail_from_email}
config :money_tree, :invitation_sender, {mail_from_name, mail_from_email}
config :money_tree, :auth_sender, {mail_from_name, mail_from_email}

if invitation_base_url = mailer_env.("INVITATION_BASE_URL") do
  config :money_tree, :invitation_base_url, invitation_base_url
end

if magic_link_base_url = mailer_env.("MAGIC_LINK_BASE_URL") do
  config :money_tree, :magic_link_base_url, magic_link_base_url
end

webauthn_runtime_config =
  [
    rp_id: mailer_env.("WEBAUTHN_RP_ID"),
    rp_name: mailer_env.("WEBAUTHN_RP_NAME"),
    origin: mailer_env.("WEBAUTHN_ORIGIN")
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

if webauthn_runtime_config != [] do
  base_accounts_config = Application.get_env(:money_tree, MoneyTree.Accounts, [])

  config :money_tree,
         MoneyTree.Accounts,
         Keyword.merge(base_accounts_config, webauthn_runtime_config)
end

smtp_enabled? =
  config_env() == :prod or
    is_binary(mailer_env.("MAILER_SMTP_HOST")) or
    is_binary(mailer_env.("MAILER_SMTP_USERNAME"))

if smtp_enabled? do
  smtp_port =
    case mailer_env.("MAILER_SMTP_PORT") do
      nil -> if config_env() == :prod, do: 587, else: 25
      value -> String.to_integer(value)
    end

  smtp_ssl? = mailer_env.("MAILER_SMTP_SSL") in ~w(true 1)

  _smtp_tls =
    mailer_env.("MAILER_SMTP_TLS") || if(config_env() == :prod, do: "if_available", else: "never")

  smtp_auth =
    case mailer_env.("MAILER_SMTP_AUTH") do
      nil ->
        :always

      "always" ->
        :always

      "never" ->
        :never

      "if_available" ->
        :if_available

      other ->
        raise "MAILER_SMTP_AUTH must be one of always, never, if_available; got: #{inspect(other)}"
    end

  relay =
    mailer_env.("MAILER_SMTP_HOST") ||
      if config_env() == :prod do
        raise """
        MAILER_SMTP_HOST is required for production email delivery.
        Use your Amazon SES SMTP endpoint in production.
        """
      else
        nil
      end

  if config_env() == :prod and
       (mailer_env.("MAILER_SMTP_USERNAME") in [nil, ""] or
          mailer_env.("MAILER_SMTP_PASSWORD") in [nil, ""]) do
    raise """
    MAILER_SMTP_USERNAME and MAILER_SMTP_PASSWORD are required for production email delivery.
    Use Amazon SES SMTP credentials in production.
    """
  end

  if relay do
    verify_mode =
      case mailer_env.("MAILER_SMTP_VERIFY") do
        nil ->
          :verify_peer

        "peer" ->
          :verify_peer

        "verify_peer" ->
          :verify_peer

        "none" ->
          :verify_none

        "verify_none" ->
          :verify_none

        other ->
          raise "MAILER_SMTP_VERIFY must be one of peer, verify_peer, none, verify_none; got: #{inspect(other)}"
      end

    ssl_options =
      case verify_mode do
        :verify_peer -> [verify: :verify_peer]
        :verify_none -> [verify: :verify_none]
      end

    auth_config =
      if smtp_auth == :never do
        nil
      else
        [
          username: mailer_env.("MAILER_SMTP_USERNAME"),
          password: mailer_env.("MAILER_SMTP_PASSWORD")
        ]
      end

    mailer_config = [
      adapter: Swoosh.Adapters.Mua,
      relay: relay,
      port: smtp_port,
      protocol: if(smtp_ssl?, do: :ssl, else: :tcp),
      auth: auth_config,
      mx: false,
      ssl: ssl_options
    ]

    config :money_tree, MoneyTree.Mailer, mailer_config
  end
end

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
  env.("CLOAK_VAULT_KEY") ||
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
  database_url = env.("DATABASE_URL")
  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  repo_config =
    if database_url do
      [url: database_url]
    else
      [
        username:
          env.("DATABASE_USERNAME") ||
            raise("environment variable DATABASE_USERNAME is missing."),
        password:
          env.("DATABASE_PASSWORD") ||
            raise("environment variable DATABASE_PASSWORD is missing."),
        hostname:
          env.("DATABASE_HOST") ||
            raise("environment variable DATABASE_HOST is missing."),
        database:
          env.("DATABASE_NAME") ||
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
    env.("SECRET_KEY_BASE") ||
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
