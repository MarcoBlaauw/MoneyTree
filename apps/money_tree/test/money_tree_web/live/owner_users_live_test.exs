defmodule MoneyTreeWeb.OwnerUsersLiveTest do
  use MoneyTreeWeb.ConnCase, async: true

  import MoneyTree.AccountsFixtures
  import Phoenix.LiveViewTest

  alias MoneyTree.Repo
  alias MoneyTree.Users.User

  test "owners can list, search, and update other users", %{conn: conn} do
    {:ok, %{conn: conn}} =
      register_and_log_in_user(%{conn: conn}, user_attrs: %{role: :owner})

    member = user_fixture(%{email: "member-owner-users-live@example.com"})

    {:ok, view, html} = live(conn, ~p"/app/owner/users")

    assert html =~ "Users"
    assert html =~ member.email

    html = render_submit(view, "search", %{"q" => "member-owner-users-live"})
    assert html =~ member.email

    render_change(view, "change-role", %{"_id" => member.id, "role" => "advisor"})
    assert Repo.get!(User, member.id).role == :advisor

    render_click(view, "toggle-suspension", %{"id" => member.id, "suspended" => "true"})
    assert Repo.get!(User, member.id).suspended_at
  end

  test "non-owners cannot access the owner users page", %{conn: conn} do
    {:ok, %{conn: conn}} = register_and_log_in_user(%{conn: conn})

    assert {:error, {:redirect, %{to: "/app"}}} = live(conn, ~p"/app/owner/users")
  end
end
