import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
test_db_username =
  System.get_env("TEST_DATABASE_USERNAME") || System.get_env("DATABASE_USERNAME") || "postgres"

test_db_password =
  System.get_env("TEST_DATABASE_PASSWORD") || System.get_env("DATABASE_PASSWORD") || "postgres"

test_db_host =
  System.get_env("TEST_DATABASE_HOST") || System.get_env("DATABASE_HOST") || "localhost"

test_db_port =
  System.get_env("TEST_DATABASE_PORT") || System.get_env("DATABASE_PORT") || "5432"

test_db_pool_size =
  System.get_env("TEST_DATABASE_POOL_SIZE") || "10"

config :money_tree, MoneyTree.Repo,
  username: test_db_username,
  password: test_db_password,
  hostname: test_db_host,
  port: String.to_integer(test_db_port),
  database: "money_tree_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: String.to_integer(test_db_pool_size)

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :money_tree, MoneyTreeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "a+qH5CcFF2vpmkEkBQQsBJtV6har/ROebKguO7t7P0U/m0OHPWwa6soxVxMbyrt6",
  server: false

# In test we don't send emails.
config :money_tree, MoneyTree.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters.
config :swoosh, :api_client, false

# Run Oban jobs inline during tests to keep assertions deterministic.
config :money_tree, Oban,
  testing: :inline,
  queues: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
