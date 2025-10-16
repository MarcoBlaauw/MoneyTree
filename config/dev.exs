import Config

# Configure your database
dev_db_username =
  System.get_env("DEV_DATABASE_USERNAME") || System.get_env("DATABASE_USERNAME") || "postgres"

dev_db_password =
  System.get_env("DEV_DATABASE_PASSWORD") || System.get_env("DATABASE_PASSWORD") || "postgres"

dev_db_host =
  System.get_env("DEV_DATABASE_HOST") || System.get_env("DATABASE_HOST") || "localhost"

dev_db_port =
  System.get_env("DEV_DATABASE_PORT") || System.get_env("DATABASE_PORT") || "5432"

config :money_tree, MoneyTree.Repo,
  username: dev_db_username,
  password: dev_db_password,
  hostname: dev_db_host,
  port: String.to_integer(dev_db_port),
  database: System.get_env("DEV_DATABASE_NAME") || "money_tree_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: String.to_integer(System.get_env("DEV_DATABASE_POOL_SIZE") || "10")

config :money_tree, MoneyTreeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "phyLbEeTQE24hcZMhVv+OA9FlwwH3+wnDnQIOffpLMPHzaOjtxVT6Sa4OaVdpRwJ",
  watchers: []

config :money_tree, dev_routes: true

config :logger, :console, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :swoosh, :api_client, false

config :money_tree, Oban,
  peer: false,
  queues: [default: 5, mailers: 2, reporting: 1]
