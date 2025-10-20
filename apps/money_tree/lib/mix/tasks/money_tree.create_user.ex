defmodule Mix.Tasks.MoneyTree.CreateUser do
  @moduledoc """
  Creates a MoneyTree user via the command line.

      mix money_tree.create_user --email admin@example.com --password "StrongPass123!" \
        [--role owner] [--name "Admin User"]

  The role defaults to `owner`, which is the highest level of access in the app.
  """
  @shortdoc "Create a user with the desired role"

  use Mix.Task

  alias MoneyTree.Accounts
  alias MoneyTree.Users.User

  @switches [email: :string, password: :string, role: :string, name: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} = OptionParser.parse(args, switches: @switches)

    email = fetch_required!(opts, :email, "--email user@example.com")
    password = fetch_required!(opts, :password, "--password \"StrongPass123!\"")
    role = resolve_role(opts[:role])

    attrs =
      %{
        email: email,
        password: password,
        role: role
      }
      |> maybe_put_full_name(opts[:name])

    case Accounts.register_user(attrs) do
      {:ok, user} ->
        Mix.shell().info("✔ Created user #{user.email} with role #{user.role}.")

      {:error, changeset} ->
        Mix.raise("Failed to create user: #{inspect(changeset.errors)}")
    end
  end

  defp fetch_required!(opts, key, usage_hint) do
    case opts[key] do
      nil -> Mix.raise("Missing required option #{usage_hint}")
      value -> value
    end
  end

  defp resolve_role(nil), do: :owner

  defp resolve_role(role) when is_binary(role) do
    role
    |> String.trim()
    |> String.downcase()
    |> case do
      "" ->
        Mix.raise(role_error_message(role))

      normalized ->
        case Enum.find(User.roles(), fn candidate ->
               Atom.to_string(candidate) == normalized
             end) do
          nil -> Mix.raise(role_error_message(role))
          role_atom -> role_atom
        end
    end
  end

  defp resolve_role(role) when is_atom(role) and role in User.roles(), do: role
  defp resolve_role(role), do: Mix.raise(role_error_message(role))

  defp role_error_message(provided) do
    valid = User.roles() |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")
    "Invalid role #{inspect(provided)}. Valid roles: #{valid}"
  end

  defp maybe_put_full_name(attrs, nil), do: attrs
  defp maybe_put_full_name(attrs, name), do: Map.put(attrs, :encrypted_full_name, name)
end
