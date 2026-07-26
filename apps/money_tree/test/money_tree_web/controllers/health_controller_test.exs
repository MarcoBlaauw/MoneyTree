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

  test "GET /api/healthz reports minimal status with no internal detail", %{conn: conn} do
    conn = get(conn, ~p"/api/healthz")

    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  test "GET /api/healthz does not require authentication", %{conn: conn} do
    conn = get(conn, ~p"/api/healthz")
    assert conn.status == 200
  end

  test "GET /api/owner/healthz requires owner authentication", %{conn: conn} do
    conn = get(conn, ~p"/api/owner/healthz")
    assert conn.status == 401
  end

  test "GET /api/owner/healthz reports detailed database connectivity for owners", %{conn: conn} do
    {:ok, %{conn: conn}} = register_and_log_in_user(%{conn: conn}, user_attrs: %{role: :owner})

    conn = get(conn, ~p"/api/owner/healthz")

    assert %{
             "status" => "ok",
             "checks" => %{
               "database" => %{"status" => "ok"},
               "oban" => [%{"queue" => "default", "status" => "testing"}]
             }
           } = json_response(conn, 200)
  end

  test "GET /api/owner/healthz calls the real Oban.check_queue/1 API correctly", %{
    conn: conn
  } do
    # The default setup runs Oban in :testing => :inline mode, which takes a
    # separate code path that never calls Oban.check_queue/1 at all. Disable
    # it here so the real check_queue/1 path (the one that had the bug) runs.
    # There's no supervised queue producer in this test process, so the
    # correct result is "unavailable" (Oban.check_queue/1 returns nil) --
    # the bug was that this always raised into the `rescue` clause instead
    # (Oban.check_queue/1 returns `nil | map()`, never a tuple, and the old
    # code only matched {:ok, _}/{:error, _}), reporting status "error"
    # unconditionally regardless of actual queue state.
    non_inline_config = Application.get_env(:money_tree, Oban) |> Keyword.delete(:testing)
    Application.put_env(:money_tree, Oban, non_inline_config)

    {:ok, %{conn: conn}} = register_and_log_in_user(%{conn: conn}, user_attrs: %{role: :owner})

    conn = get(conn, ~p"/api/owner/healthz")

    # No supervised producer for "default" here, so overall status correctly
    # degrades to 503 -- what matters for this regression test is that the
    # per-queue status is the clean "unavailable" outcome, not "error".
    assert %{
             "checks" => %{
               "oban" => [%{"queue" => "default", "status" => "unavailable"}]
             }
           } = json_response(conn, 503)
  end

  test "GET /api/owner/metrics requires owner authentication", %{conn: conn} do
    conn = get(conn, ~p"/api/owner/metrics")
    assert conn.status == 401
  end

  test "GET /api/owner/metrics includes queue job counts for owners", %{conn: conn} do
    {:ok, %{conn: conn}} = register_and_log_in_user(%{conn: conn}, user_attrs: %{role: :owner})

    :ok =
      %{}
      |> DummyWorker.new(queue: :default)
      |> Repo.insert()
      |> case do
        {:ok, _job} -> :ok
        {:error, changeset} -> flunk("Failed to insert job: #{inspect(changeset.errors)}")
      end

    conn = get(conn, ~p"/api/owner/metrics")

    assert %{"queues" => queues} = json_response(conn, 200)

    assert [%{"queue" => "default", "counts" => counts}] = queues
    assert Map.get(counts, "available", 0) >= 1
  end
end
