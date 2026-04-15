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

resolve_runtime_path = fn path ->
  path
  |> Path.expand(File.cwd!())
end

validate_runtime_file! = fn path, label ->
  expanded = resolve_runtime_path.(path)

  if File.regular?(expanded) do
    expanded
  else
    raise """
    #{label} is configured as #{inspect(path)}, but no readable file exists at #{expanded}.
    Update your .env to point at the correct Teller certificate/key path.
    """
  end
end

cert_file =
  case teller_env.("TELLER_CERT_FILE") || teller_env.("TELLER_CERT_PATH") do
    nil -> nil
    path -> validate_runtime_file!.(path, "TELLER_CERT_FILE")
  end

key_file =
  case teller_env.("TELLER_KEY_FILE") || teller_env.("TELLER_KEY_PATH") do
    nil -> nil
    path -> validate_runtime_file!.(path, "TELLER_KEY_FILE")
  end

cert_pem = teller_env.("TELLER_CERT_PEM")
key_pem = teller_env.("TELLER_KEY_PEM")

if config_env() == :prod do
  cert_pair_present? =
    (is_binary(cert_pem) and is_binary(key_pem)) or
      (is_binary(cert_file) and is_binary(key_file))

  if not cert_pair_present? do
    raise """
    Teller production configuration requires a client certificate and private key.
    Set either TELLER_CERT_PEM and TELLER_KEY_PEM, or TELLER_CERT_FILE and TELLER_KEY_FILE.
    """
  end
end

teller_runtime_config =
  [
    connect_application_id: teller_env.("TELLER_CONNECT_APPLICATION_ID"),
    webhook_secret: teller_env.("TELLER_WEBHOOK_SECRET"),
    api_host: teller_env.("TELLER_API_HOST"),
    connect_host: teller_env.("TELLER_CONNECT_HOST"),
    webhook_host: teller_env.("TELLER_WEBHOOK_HOST"),
    client_cert_pem: cert_pem,
    client_key_pem: key_pem,
    client_cert_file: cert_file,
    client_key_file: key_file
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

config :money_tree, MoneyTree.Teller, Keyword.merge(base_teller_config, teller_runtime_config)

base_plaid_config = Application.get_env(:money_tree, MoneyTree.Plaid, [])

parse_csv_env = fn value ->
  value
  |> String.split(",")
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
end

plaid_products =
  case teller_env.("PLAID_PRODUCTS") do
    nil -> nil
    csv -> parse_csv_env.(csv)
  end

plaid_country_codes =
  case teller_env.("PLAID_COUNTRY_CODES") do
    nil -> nil
    csv -> parse_csv_env.(csv)
  end

plaid_api_host =
  case teller_env.("PLAID_API_HOST") do
    nil ->
      case teller_env.("PLAID_ENV") do
        "production" -> "https://production.plaid.com"
        "development" -> "https://development.plaid.com"
        _ -> "https://sandbox.plaid.com"
      end

    host ->
      host
  end

plaid_runtime_config =
  [
    client_id: teller_env.("PLAID_CLIENT_ID"),
    secret: teller_env.("PLAID_SECRET"),
    environment: teller_env.("PLAID_ENV"),
    products: plaid_products,
    country_codes: plaid_country_codes,
    redirect_uri: teller_env.("PLAID_REDIRECT_URI"),
    webhook_secret: teller_env.("PLAID_WEBHOOK_SECRET"),
    client_name: teller_env.("PLAID_CLIENT_NAME"),
    language: teller_env.("PLAID_LANGUAGE"),
    api_host: plaid_api_host
  ]
  |> Enum.reject(fn
    {_key, nil} -> true
    {_key, []} -> true
    _ -> false
  end)

config :money_tree, MoneyTree.Plaid, Keyword.merge(base_plaid_config, plaid_runtime_config)

stripe_runtime_config =
  [
    connect_client_id: teller_env.("STRIPE_CONNECT_CLIENT_ID"),
    connect_redirect_uri: teller_env.("STRIPE_CONNECT_REDIRECT_URI"),
    authorize_host: teller_env.("STRIPE_CONNECT_HOST"),
    connect_scope: teller_env.("STRIPE_CONNECT_SCOPE")
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

config :money_tree, MoneyTree.Stripe, stripe_runtime_config

mailer_env = fn key ->
  case System.get_env(key) do
    nil -> nil
    "" -> nil
    value -> value
  end
end

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
