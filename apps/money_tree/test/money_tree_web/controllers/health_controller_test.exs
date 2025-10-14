defmodule MoneyTreeWeb.HealthControllerTest do
  use MoneyTreeWeb.ConnCase

  alias MoneyTree.Repo

  defmodule DummyWorker do
    use Oban.Worker, queue: :default

    @impl true
    def perform(_job), do: :ok
  end

  setup do
    original = Application.get_env(:money_tree, Oban)

    new_config =
      (original || [])
      |> Keyword.put(:queues, default: 5)
      |> Keyword.put(:testing, :inline)

    Application.put_env(:money_tree, Oban, new_config)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:money_tree, Oban)
        config -> Application.put_env(:money_tree, Oban, config)
      end
    end)

    :ok
  end

  test "GET /api/healthz reports ok with database connectivity", %{conn: conn} do
    conn = get(conn, ~p"/api/healthz")

    assert %{
             "status" => "ok",
             "checks" => %{
               "database" => %{"status" => "ok"}
             }
           } = json_response(conn, 200)
  end

  test "GET /api/metrics includes queue job counts", %{conn: conn} do
    :ok =
      %{}
      |> DummyWorker.new(queue: :default)
      |> Repo.insert()
      |> case do
        {:ok, _job} -> :ok
        {:error, changeset} -> flunk("Failed to insert job: #{inspect(changeset.errors)}")
      end

    conn = get(conn, ~p"/api/metrics")

    assert %{"queues" => queues} = json_response(conn, 200)

    assert [%{"queue" => "default", "counts" => counts}] = queues
    assert Map.get(counts, "available", 0) >= 1
  end
end
