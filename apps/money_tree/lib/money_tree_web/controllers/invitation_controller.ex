defmodule MoneyTreeWeb.InvitationController do
  use MoneyTreeWeb, :controller

  alias MoneyTree.Accounts
  alias MoneyTree.Accounts.Account
  alias MoneyTree.Accounts.AccountInvitation
  alias MoneyTree.Repo

  @doc """
  Creates an invitation for the specified account.
  """
  def create(conn, %{"account_id" => account_id} = params) do
    current_user = conn.assigns.current_user

    case Repo.get(Account, account_id) do
      nil ->
        render_error(conn, :not_found, "account not found")

      %Account{} = account ->
        attrs = Map.take(params, ["email", "expires_at"])

        case Accounts.create_account_invitation(current_user, account, attrs) do
          {:ok, invitation, token} ->
            conn
            |> put_status(:created)
            |> json(%{data: %{invitation: serialize_invitation(invitation), token: token}})

          {:error, reason} ->
            handle_creation_error(conn, reason)
        end
    end
  end

  @doc """
  Revokes a pending invitation for the given account.
  """
  def revoke(conn, %{"account_id" => account_id, "id" => id}) do
    current_user = conn.assigns.current_user

    with %AccountInvitation{} = invitation <- Repo.get(AccountInvitation, id),
         true <- invitation.account_id == account_id do
      case Accounts.revoke_account_invitation(current_user, invitation) do
        {:ok, invitation} ->
          json(conn, %{data: %{invitation: serialize_invitation(invitation)}})

        {:error, reason} ->
          handle_creation_error(conn, reason)
      end
    else
      nil -> render_error(conn, :not_found, "invitation not found")
      false -> render_error(conn, :not_found, "invitation not found")
    end
  end

  @doc """
  Accepts an invitation token, authenticating or registering the invitee.
  """
  def accept(conn, %{"token" => token} = params) do
    case Accounts.accept_account_invitation(token, params) do
      {:ok, invitation, membership} ->
        json(conn, %{
          data: %{
            invitation: serialize_invitation(invitation),
            membership: serialize_membership(membership)
          }
        })

      {:error, reason} ->
        handle_acceptance_error(conn, reason)
    end
  end

  defp handle_creation_error(conn, %Ecto.Changeset{} = changeset) do
    errors = Ecto.Changeset.traverse_errors(changeset, &translate_error/1)
    render_error(conn, :unprocessable_entity, errors)
  end

  defp handle_creation_error(conn, :unauthorized), do: render_error(conn, :forbidden, "forbidden")

  defp handle_creation_error(conn, :already_member),
    do: render_error(conn, :conflict, "user already a member")

  defp handle_creation_error(conn, :already_invited),
    do: render_error(conn, :conflict, "invitation already pending")

  defp handle_creation_error(conn, :email_required),
    do: render_error(conn, :unprocessable_entity, "email is required")

  defp handle_creation_error(conn, :invalid_expiration),
    do: render_error(conn, :unprocessable_entity, "expiration is invalid")

  defp handle_creation_error(conn, :revoked), do: render_error(conn, :gone, "invitation revoked")
  defp handle_creation_error(conn, :expired), do: render_error(conn, :gone, "invitation expired")

  defp handle_creation_error(conn, :already_accepted),
    do: render_error(conn, :conflict, "invitation already accepted")

  defp handle_creation_error(conn, other), do: render_error(conn, :bad_request, to_string(other))

  defp handle_acceptance_error(conn, %Ecto.Changeset{} = changeset) do
    errors = Ecto.Changeset.traverse_errors(changeset, &translate_error/1)
    render_error(conn, :unprocessable_entity, errors)
  end

  defp handle_acceptance_error(conn, :not_found),
    do: render_error(conn, :not_found, "invitation not found")

  defp handle_acceptance_error(conn, :unauthorized),
    do: render_error(conn, :forbidden, "forbidden")

  defp handle_acceptance_error(conn, :expired),
    do: render_error(conn, :gone, "invitation expired")

  defp handle_acceptance_error(conn, :revoked),
    do: render_error(conn, :gone, "invitation revoked")

  defp handle_acceptance_error(conn, :already_accepted),
    do: render_error(conn, :conflict, "invitation already accepted")

  defp handle_acceptance_error(conn, :already_member),
    do: render_error(conn, :conflict, "user already a member")

  defp handle_acceptance_error(conn, :invalid_credentials),
    do: render_error(conn, :unauthorized, "invalid credentials")

  defp handle_acceptance_error(conn, :password_required),
    do: render_error(conn, :unprocessable_entity, "password is required")

  defp handle_acceptance_error(conn, :full_name_required),
    do: render_error(conn, :unprocessable_entity, "encrypted_full_name is required")

  defp handle_acceptance_error(conn, other),
    do: render_error(conn, :bad_request, to_string(other))

  defp render_error(conn, status, message) when is_map(message) do
    conn
    |> put_status(status)
    |> json(%{errors: message})
  end

  defp render_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  defp serialize_invitation(%AccountInvitation{} = invitation) do
    %{
      id: invitation.id,
      account_id: invitation.account_id,
      email: invitation.email,
      status: invitation.status,
      expires_at: maybe_iso8601(invitation.expires_at),
      invitee_user_id: invitation.invitee_user_id
    }
  end

  defp serialize_membership(membership) do
    %{
      id: membership.id,
      account_id: membership.account_id,
      user_id: membership.user_id,
      role: membership.role,
      invited_at: maybe_iso8601(membership.invited_at),
      accepted_at: maybe_iso8601(membership.accepted_at)
    }
  end

  defp maybe_iso8601(nil), do: nil

  defp maybe_iso8601(%DateTime{} = datetime) do
    DateTime.to_iso8601(datetime)
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
