defmodule MoneyTreeWeb.SettingsController do
  use MoneyTreeWeb, :controller

  alias MoneyTree.Accounts

  def show(%{assigns: %{current_user: current_user}} = conn, _params) do
    settings = Accounts.user_settings(current_user)

    profile = Map.get(settings, :profile, %{})

    data = %{
      profile: Map.put(profile, :display_name, display_name(profile)),
      notifications: Map.get(settings, :notifications, %{}),
      sessions: Map.get(settings, :sessions, [])
    }

    json(conn, %{data: data})
  end

  defp display_name(profile) when is_map(profile) do
    profile
    |> Map.get(:full_name)
    |> maybe_from_full_name(profile)
  end

  defp display_name(_), do: nil

  defp maybe_from_full_name(full_name, profile) when is_binary(full_name) do
    full_name = String.trim(full_name)

    if full_name == "" do
      email_prefix(profile)
    else
      full_name
    end
  end

  defp maybe_from_full_name(_full_name, profile) do
    email_prefix(profile)
  end

  defp email_prefix(profile) do
    profile
    |> Map.get(:email)
    |> case do
      email when is_binary(email) ->
        email
        |> String.trim()
        |> String.split("@", parts: 2)
        |> List.first()

      _ ->
        nil
    end
  end
end
