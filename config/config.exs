import Config

config :phoenix,
       :filter_parameters,
       ~w(password password_confirmation token secret session authorization refresh_token encrypted_full_name)

config :money_tree,
  ecto_repos: [MoneyTree.Repo],
  generators: [binary_id: true, timestamp_type: :utc_datetime_usec]

config :money_tree, MoneyTree.Repo,
  migration_primary_key: [type: :binary_id],
  migration_foreign_key: [type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec]

config :money_tree, MoneyTree.Accounts, session_ttl: 60 * 60 * 24 * 30

config :money_tree, :rate_limiter, MoneyTreeWeb.RateLimiter.Noop
config :money_tree, :secure_cookies, true

config :money_tree, MoneyTreeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [json: MoneyTreeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: MoneyTree.PubSub,
  live_view: [signing_salt: "AQ0mt1V3", csp_nonce_assign_key: :csp_nonce]

config :money_tree, MoneyTreeWeb.Plugs.NextProxy,
  upstream: [scheme: "http", host: "localhost", port: 3000, path: "/"],
  client_opts: [receive_timeout: :timer.seconds(15)]

config :money_tree, MoneyTree.Teller,
  api_host: "https://api.teller.io",
  connect_host: "https://connect.teller.io",
  timeout: :timer.seconds(10),
  finch: MoneyTree.Finch,
  telemetry_metadata: %{service: "money_tree", integration: "teller"},
  client_cert_pem: nil,
  client_key_pem: nil,
  client_cert_file: nil,
  client_key_file: nil

config :money_tree, Oban,
  repo: MoneyTree.Repo,
  queues: [
    default: 10,
    mailers: 5,
    reporting: 5
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 86_400},
    {Oban.Plugins.Lifeline, rescue_after: 60},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/30 * * * *", MoneyTree.Teller.SyncWorker, args: %{"mode" => "dispatch"}}
     ]}
  ]

config :money_tree, :opentelemetry_exporter, []

config :req, :default_options, finch: MoneyTree.Finch

config :money_tree, MoneyTree.Mailer, adapter: Swoosh.Adapters.Local

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :remote_ip, :user_id, :user_role]

config :logger, :default_metadata, %{service: "money_tree"}

config :phoenix, :json_library, Jason

config :opentelemetry, :resource, service: %{name: "money_tree"}

config :opentelemetry, :processors, [
  {:otel_batch_processor, %{exporter: {:opentelemetry_exporter, %{}}}}
]

import_config "#{config_env()}.exs"
