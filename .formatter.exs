[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["apps/*/priv/*/migrations"],
  inputs: [
    "{mix,.formatter}.exs",
    "{config}/**/*.{ex,exs}",
    "apps/*/{lib,test}/**/*.{ex,exs}",
    "apps/*/lib/**/*.{heex,eex}",
    "apps/*/priv/*/seeds.exs"
  ]
]
