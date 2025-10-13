defmodule MoneyTree.Repo do
  use Ecto.Repo,
    otp_app: :money_tree,
    adapter: Ecto.Adapters.Postgres
end
