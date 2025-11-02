defmodule MoneyTreeWeb.Owner.UserController do
  @moduledoc """
  Owner-facing API for managing MoneyTree users.
  """

  use MoneyTreeWeb, :controller

  alias Ecto.Changeset
  alias MoneyTree.Accounts
  alias MoneyTree.Users.User

  def index(conn, params) do
    %{entries: users, metadata: metadata} = Accounts.paginate_users(params)

    conn
    |> put_status(:ok)
    |> json(%{data: Enum.map(users, &serialize_user/1), meta: metadata})
  end

  def show(conn, %{"id" => user_id}) do
    case Accounts.fetch_user(user_id) do
      {:ok, %User{} = user} -> json(conn, %{data: serialize_user(user)})
      {:error, :not_found} -> not_found(conn)
    end
  end

  def update(conn, %{"id" => user_id} = params) do
    actor = current_actor(conn)

    with {:ok, %User{} = user} <- Accounts.fetch_user(user_id),
         {:ok, %User{} = updated} <- apply_owner_update(user, params, actor) do
      json(conn, %{data: serialize_user(updated)})
    else
      {:error, :not_found} -> not_found(conn)
      {:error, :invalid_suspended} ->
        unprocessable(conn, %{error: "suspended must be a boolean"})

      {:error, :no_supported_attributes} ->
        unprocessable(conn, %{error: "no supported attributes provided"})

      {:error, :invalid_role} ->
        unprocessable(conn, %{error: "role is invalid"})

      {:error, :already_suspended} ->
        conflict(conn, %{error: "user is already suspended"})

      {:error, :not_suspended} ->
        conflict(conn, %{error: "user is not suspended"})

      {:error, %Changeset{} = changeset} ->
        unprocessable(conn, %{errors: format_changeset_errors(changeset)})
    end
  end

  def delete(conn, %{"id" => user_id}) do
    actor = current_actor(conn)

    with {:ok, %User{} = user} <- Accounts.fetch_user(user_id),
         {:ok, _updated} <- Accounts.suspend_user(user, actor: actor) do
      send_resp(conn, :no_content, "")
    else
      {:error, :not_found} -> not_found(conn)
      {:error, :already_suspended} -> conflict(conn, %{error: "user is already suspended"})
      {:error, %Changeset{} = changeset} ->
        unprocessable(conn, %{errors: format_changeset_errors(changeset)})
    end
  end

  defp apply_owner_update(user, params, actor) do
    with {:ok, operations} <- extract_operations(params) do
      operations
      |> Enum.reduce_while({:ok, user}, fn
        {:role, role}, {:ok, current} ->
          case Accounts.update_user_role(current, role, actor: actor) do
            {:ok, %User{} = updated} -> {:cont, {:ok, updated}}
            {:error, _reason} = error -> {:halt, error}
          end

        {:suspended, true}, {:ok, current} ->
          case Accounts.suspend_user(current, actor: actor) do
            {:ok, %User{} = updated} -> {:cont, {:ok, updated}}
            {:error, _reason} = error -> {:halt, error}
          end

        {:suspended, false}, {:ok, current} ->
          case Accounts.reactivate_user(current, actor: actor) do
            {:ok, %User{} = updated} -> {:cont, {:ok, updated}}
            {:error, _reason} = error -> {:halt, error}
          end
      end)
      |> case do
        {:ok, %User{} = updated} -> {:ok, updated}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp extract_operations(params) do
    with {:ok, operations} <- maybe_add_role([], params),
         {:ok, operations} <- maybe_add_suspension(operations, params) do
      case operations do
        [] -> {:error, :no_supported_attributes}
        _ -> {:ok, operations}
      end
    end
  end

  defp maybe_add_role(operations, params) do
    case fetch_param(params, :role) do
      {:ok, role} -> {:ok, operations ++ [{:role, role}]}
      :error -> {:ok, operations}
    end
  end

  defp maybe_add_suspension(operations, params) do
    case fetch_param(params, :suspended) do
      {:ok, value} ->
        case parse_boolean(value) do
          {:ok, boolean} -> {:ok, operations ++ [{:suspended, boolean}]}
          :error -> {:error, :invalid_suspended}
        end

      :error ->
        {:ok, operations}
    end
  end

  defp fetch_param(params, key) when is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(params, key) -> {:ok, Map.get(params, key)}
      Map.has_key?(params, string_key) -> {:ok, Map.get(params, string_key)}
      true -> :error
    end
  end

  defp parse_boolean(value) when value in [true, false], do: {:ok, value}
  defp parse_boolean("true"), do: {:ok, true}
  defp parse_boolean("false"), do: {:ok, false}
  defp parse_boolean("1"), do: {:ok, true}
  defp parse_boolean("0"), do: {:ok, false}
  defp parse_boolean(1), do: {:ok, true}
  defp parse_boolean(0), do: {:ok, false}
  defp parse_boolean(_), do: :error

  defp serialize_user(%User{} = user) do
    %{
      id: user.id,
      email: user.email,
      role: Atom.to_string(user.role),
      suspended: not is_nil(user.suspended_at),
      suspended_at: format_datetime(user.suspended_at),
      inserted_at: format_datetime(user.inserted_at),
      updated_at: format_datetime(user.updated_at)
    }
  end

  defp format_datetime(nil), do: nil

  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp format_datetime(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)

  defp format_changeset_errors(%Changeset{} = changeset) do
    Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp current_actor(conn), do: Map.get(conn.assigns, :current_user)

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not found"})
  end

  defp unprocessable(conn, payload) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(payload)
  end

  defp conflict(conn, payload) do
    conn
    |> put_status(:conflict)
    |> json(payload)
  end
end
