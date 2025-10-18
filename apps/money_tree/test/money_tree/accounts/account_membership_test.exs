defmodule MoneyTree.Accounts.AccountMembershipTest do
  use MoneyTree.DataCase, async: true

  alias MoneyTree.Accounts.AccountMembership
  alias MoneyTree.AccountsFixtures
  alias MoneyTree.Repo

  describe "changeset/2" do
    test "requires account, user, and role" do
      changeset = AccountMembership.changeset(%AccountMembership{}, %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).account_id
      assert "can't be blank" in errors_on(changeset).user_id
      assert "can't be blank" in errors_on(changeset).role
    end

    test "validates timestamp fields" do
      user = AccountsFixtures.user_fixture()
      account = AccountsFixtures.account_fixture(user)

      attrs = %{
        account_id: account.id,
        user_id: user.id,
        role: :member,
        invited_at: "not-a-datetime"
      }

      changeset = AccountMembership.changeset(%AccountMembership{}, attrs)

      refute changeset.valid?
      assert "must be a DateTime" in errors_on(changeset).invited_at
    end

    test "enforces unique account/user pair" do
      owner = AccountsFixtures.user_fixture()
      member = AccountsFixtures.user_fixture()
      account = AccountsFixtures.account_fixture(owner)

      AccountsFixtures.membership_fixture(account, member, %{role: :viewer})

      duplicate =
        %AccountMembership{}
        |> AccountMembership.changeset(%{
          account_id: account.id,
          user_id: member.id,
          role: :viewer
        })

      assert {:error, changeset} = Repo.insert(duplicate)
      assert "has already been taken" in errors_on(changeset).account_id
    end
  end

  describe "roles/0" do
    test "returns supported role values" do
      assert :primary in AccountMembership.roles()
      assert :member in AccountMembership.roles()
      assert :viewer in AccountMembership.roles()
    end
  end
end
