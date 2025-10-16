[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["apps/*/priv/*/migrations"],
  inputs: ["{mix,.formatter}.exs", "{config,apps}/**/*.{ex,exs}", "apps/*/priv/*/seeds.exs"]
]
