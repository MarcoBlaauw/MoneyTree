Mix.Task.run("ecto.create", ["--quiet"])
Mix.Task.run("ecto.migrate", ["--quiet"])

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(MoneyTree.Repo, :manual)
