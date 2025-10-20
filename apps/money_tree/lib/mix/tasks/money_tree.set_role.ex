defmodule Mix.Tasks.MoneyTree.SetRole do
  @moduledoc """
  Updates the role for an existing MoneyTree user.

      mix money_tree.set_role --email user@example.com --role owner
  """
  @shortdoc "Update a user's role"

  use Mix.Task

  alias MoneyTree.Accounts
  alias MoneyTree.Users.User

  @switches [email: :string, role: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} = OptionParser.parse(args, switches: @switches)

    email = fetch_required!(opts, :email, "--email user@example.com")
    role = fetch_required!(opts, :role, "--role owner")

    case Accounts.set_user_role(email, role) do
      {:ok, user} ->
        Mix.shell().info("✔ Updated #{user.email} role to #{user.role}.")

      {:error, :not_found} ->
        Mix.raise("No user found for email #{email}.")

      {:error, :invalid_role} ->
        Mix.raise(role_error_message(role))

      {:error, %Ecto.Changeset{} = changeset} ->
        Mix.raise("Failed to update role: #{inspect(changeset.errors)}")
    end
  end

  defp fetch_required!(opts, key, usage_hint) do
    case opts[key] do
      nil -> Mix.raise("Missing required option #{usage_hint}")
      value -> value
    end
  end

  defp role_error_message(provided) do
    valid = User.roles() |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")
    "Invalid role #{inspect(provided)}. Valid roles: #{valid}"
  end
end
