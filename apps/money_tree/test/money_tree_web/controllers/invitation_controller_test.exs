defmodule MoneyTreeWeb.InvitationControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures

  alias MoneyTree.Accounts
  alias MoneyTree.Accounts.AccountInvitation
  alias MoneyTree.Accounts.AccountMembership
  alias MoneyTree.Repo
  alias MoneyTree.Users.User
  alias MoneyTreeWeb.Auth
  alias Swoosh.Adapters.Test, as: SwooshTestAdapter

  @session_cookie Auth.session_cookie_name()

  setup %{conn: conn} do
    SwooshTestAdapter.reset()
    inviter = user_fixture(%{password: "InviterPass123!"})
    account = account_fixture(inviter)
    %{token: token} = session_fixture(inviter)

    authed_conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

    {:ok, conn: authed_conn, inviter: inviter, account: account}
  end

  describe "POST /api/accounts/:account_id/invitations" do
    test "creates invitation and returns token", %{conn: conn, account: account} do
      params = %{"email" => "controller@example.com"}
      conn = post(conn, ~p"/api/accounts/#{account.id}/invitations", params)

      assert %{"data" => %{"invitation" => data, "token" => token}} = json_response(conn, 201)
      assert data["email"] == "controller@example.com"
      assert data["status"] == "pending"
      assert is_binary(token)

      [sent] = SwooshTestAdapter.deliveries()
      assert Enum.any?(sent.to, fn {_name, address} -> address == "controller@example.com" end)
    end

    test "rejects duplicate invitations", %{conn: conn, account: account} do
      params = %{"email" => "duplicate@example.com"}
      _ = post(conn, ~p"/api/accounts/#{account.id}/invitations", params)
      conn = post(conn, ~p"/api/accounts/#{account.id}/invitations", params)

      assert %{"error" => "invitation already pending"} = json_response(conn, 409)
    end

    test "requires membership", %{account: account} do
      outsider = user_fixture(%{email: "other@example.com", password: "OtherPass123!"})
      %{token: token} = session_fixture(outsider)

      conn = build_conn()
      conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

      conn =
        post(conn, ~p"/api/accounts/#{account.id}/invitations", %{"email" => "target@example.com"})

      assert %{"error" => "forbidden"} = json_response(conn, 403)
    end
  end

  describe "POST /api/invitations/:token/accept" do
    test "accepts invitation with existing user", %{account: account, inviter: inviter} do
      invitee = user_fixture(%{email: "accept-existing@example.com", password: "AcceptPass123!"})

      {:ok, invitation, token} =
        Accounts.create_account_invitation(inviter, account, %{email: invitee.email})

      conn = build_conn()
      conn = post(conn, ~p"/api/invitations/#{token}/accept", %{"password" => "AcceptPass123!"})

      assert %{"data" => %{"invitation" => data, "membership" => membership}} =
               json_response(conn, 200)

      assert data["status"] == "accepted"
      assert membership["user_id"] == invitee.id

      assert Repo.get_by!(AccountMembership, account_id: account.id, user_id: invitee.id)
    end

    test "creates new user on acceptance", %{account: account, inviter: inviter} do
      email = "accept-new@example.com"

      {:ok, invitation, token} =
        Accounts.create_account_invitation(inviter, account, %{email: email})

      conn = build_conn()

      conn =
        post(conn, ~p"/api/invitations/#{token}/accept", %{
          "password" => "BrandNewPass123!",
          "encrypted_full_name" => "Controller New"
        })

      assert %{"data" => %{"invitation" => data, "membership" => membership}} =
               json_response(conn, 200)

      assert data["status"] == "accepted"

      user = Repo.get_by!(User, email: email)
      assert membership["user_id"] == user.id
    end

    test "returns gone for expired invitation", %{account: account, inviter: inviter} do
      {:ok, invitation, token} =
        Accounts.create_account_invitation(inviter, account, %{email: "gone@example.com"})

      expired_at =
        DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:microsecond)

      invitation
      |> Ecto.Changeset.change(expires_at: expired_at)
      |> Repo.update!()

      conn = build_conn()

      conn =
        post(conn, ~p"/api/invitations/#{token}/accept", %{
          "password" => "GonePass123!",
          "encrypted_full_name" => "Gone User"
        })

      assert %{"error" => "invitation expired"} = json_response(conn, 410)
    end
  end

  describe "DELETE /api/accounts/:account_id/invitations/:id" do
    test "revokes invitation", %{conn: conn, inviter: inviter, account: account} do
      %{invitation: invitation} =
        invitation_fixture(account, inviter, %{email: "revoke-controller@example.com"})

      conn = delete(conn, ~p"/api/accounts/#{account.id}/invitations/#{invitation.id}")

      assert %{"data" => %{"invitation" => %{"status" => "revoked"}}} = json_response(conn, 200)

      updated = Repo.get!(AccountInvitation, invitation.id)
      assert updated.status == :revoked
    end
  end
end
