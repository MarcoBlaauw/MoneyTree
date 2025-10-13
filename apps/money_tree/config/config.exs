import Config

config :money_tree,
  ecto_repos: [MoneyTree.Repo],
  generators: [binary_id: true, timestamp_type: :utc_datetime_usec]

config :money_tree, MoneyTree.Repo,
  migration_primary_key: [type: :binary_id],
  migration_foreign_key: [type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec]

config :money_tree, MoneyTreeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [json: MoneyTreeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: MoneyTree.PubSub,
  live_view: [signing_salt: "AQ0mt1V3"]

config :money_tree, Oban,
  repo: MoneyTree.Repo,
  queues: [
    default: 10,
    mailers: 5,
    reporting: 5
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 86_400},
    {Oban.Plugins.Lifeline, rescue_after: 60}
  ]

config :money_tree, :opentelemetry_exporter, []

config :req, :default_options, finch: MoneyTree.Finch

config :money_tree, MoneyTree.Mailer, adapter: Swoosh.Adapters.Local

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :opentelemetry, :resource, service: %{name: "money_tree"}

config :opentelemetry, :processors,
  [
    {:otel_batch_processor, %{exporter: {:opentelemetry_exporter, %{}}}}
  ]

import_config "#{config_env()}.exs"
