defmodule MoneyTree.Accounts.AccountInvitationTest do
  use MoneyTree.DataCase

  import MoneyTree.AccountsFixtures

  alias MoneyTree.Accounts
  alias MoneyTree.Accounts.AccountInvitation
  alias MoneyTree.Accounts.AccountMembership
  alias MoneyTree.Repo
  alias MoneyTree.Users.User
  alias Swoosh.Adapters.Test, as: SwooshTestAdapter

  setup do
    SwooshTestAdapter.reset()
    inviter = user_fixture()
    account = account_fixture(inviter)
    {:ok, inviter: inviter, account: account}
  end

  describe "create_account_invitation/3" do
    test "creates a pending invitation and sends email", %{inviter: inviter, account: account} do
      email = "invitee@example.com"

      assert {:ok, %AccountInvitation{} = invitation, token} =
               Accounts.create_account_invitation(inviter, account, %{email: email})

      assert invitation.email == email
      assert invitation.status == :pending
      assert is_binary(token)

      [sent] = SwooshTestAdapter.deliveries()
      assert Enum.any?(sent.to, fn {_name, address} -> address == email end)
      assert String.contains?(sent.text_body, token)
    end

    test "prevents duplicate pending invitations", %{inviter: inviter, account: account} do
      email = "dup@example.com"

      assert {:ok, _invitation, _token} =
               Accounts.create_account_invitation(inviter, account, %{email: email})

      assert {:error, :already_invited} =
               Accounts.create_account_invitation(inviter, account, %{email: email})
    end

    test "rejects invitations from non-members", %{account: account} do
      outsider = user_fixture(%{email: "outsider@example.com"})

      assert {:error, :unauthorized} =
               Accounts.create_account_invitation(outsider, account, %{
                 email: "target@example.com"
               })
    end
  end

  describe "revoke_account_invitation/2" do
    test "marks a pending invitation as revoked", %{inviter: inviter, account: account} do
      %{invitation: invitation} =
        invitation_fixture(account, inviter, %{email: "revoke@example.com"})

      assert {:ok, %AccountInvitation{} = revoked} =
               Accounts.revoke_account_invitation(inviter, invitation)

      assert revoked.status == :revoked
    end
  end

  describe "accept_account_invitation/2" do
    test "accepts with existing user credentials", %{inviter: inviter, account: account} do
      invitee = user_fixture(%{email: "existing@example.com", password: "ExistingPass123!"})

      {:ok, invitation, token} =
        Accounts.create_account_invitation(inviter, account, %{email: invitee.email})

      assert {:ok, %AccountInvitation{} = accepted, %AccountMembership{} = membership} =
               Accounts.accept_account_invitation(token, %{password: "ExistingPass123!"})

      assert accepted.status == :accepted
      assert accepted.invitee_user_id == invitee.id
      assert membership.account_id == account.id
      assert membership.user_id == invitee.id
    end

    test "creates a new user when accepting", %{inviter: inviter, account: account} do
      email = "new-user@example.com"

      {:ok, invitation, token} =
        Accounts.create_account_invitation(inviter, account, %{email: email})

      params = %{password: "BrandNewPass123!", encrypted_full_name: "New User"}

      assert {:ok, %AccountInvitation{} = accepted, %AccountMembership{} = membership} =
               Accounts.accept_account_invitation(token, params)

      assert accepted.status == :accepted
      assert accepted.invitee_user_id == membership.user_id

      user = Repo.get_by!(User, email: email)
      assert membership.user_id == user.id
    end

    test "returns error for expired invitations", %{inviter: inviter, account: account} do
      {:ok, invitation, token} =
        Accounts.create_account_invitation(inviter, account, %{email: "expired@example.com"})

      expired_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

      invitation
      |> Ecto.Changeset.change(expires_at: expired_at)
      |> Repo.update!()

      assert {:error, :expired} =
               Accounts.accept_account_invitation(token, %{
                 password: "ExpiredPass123!",
                 encrypted_full_name: "Expired User"
               })

      refreshed = Repo.get!(AccountInvitation, invitation.id)
      assert refreshed.status == :expired
    end
  end
end
