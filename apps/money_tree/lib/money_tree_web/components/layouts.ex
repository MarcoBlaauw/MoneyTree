defmodule MoneyTreeWeb.Layouts do
  @moduledoc false

  use MoneyTreeWeb, :html

  def app_nav_items do
    [
      %{label: "Dashboard", path: ~p"/app/dashboard", page_title: "Dashboard"},
      %{label: "Accounts", path: ~p"/app/accounts", page_title: "Accounts & Institutions"},
      %{label: "Transactions", path: ~p"/app/transactions", page_title: "Transactions"},
      %{label: "Budgets", path: ~p"/app/budgets", page_title: "Budgets"},
      %{label: "Obligations", path: ~p"/app/obligations", page_title: "Obligations"},
      %{label: "Assets", path: ~p"/app/assets", page_title: "Assets"},
      %{label: "Transfers", path: ~p"/app/transfers", page_title: "Transfers"},
      %{label: "Settings", path: ~p"/app/settings", page_title: "Settings"}
    ]
  end

  def workspace_nav_items do
    [
      %{label: "Connect institution", path: "/app/react/link-bank"},
      %{label: "Categorization rules", path: "/app/transactions/categorization"},
      %{label: "Import / Export", path: "/app/import-export"},
      %{label: "Security settings", path: "/app/settings/security"}
    ]
  end

  def nav_item_class(item, current_page_title) do
    base =
      "flex items-center justify-between rounded-xl px-3 py-2 text-sm font-medium transition-colors"

    if nav_item_active?(item, current_page_title) do
      base <> " bg-emerald-500 text-white shadow-sm"
    else
      base <> " text-zinc-700 hover:bg-zinc-100 hover:text-zinc-900"
    end
  end

  def nav_item_active?(%{page_title: title}, current_page_title), do: title == current_page_title
  def nav_item_active?(_, _), do: false

  def user_display_name(user) do
    cond do
      is_nil(user) ->
        "Guest"

      is_binary(Map.get(user, :full_name)) and Map.get(user, :full_name) != "" ->
        Map.get(user, :full_name)

      is_binary(Map.get(user, :encrypted_full_name)) and Map.get(user, :encrypted_full_name) != "" ->
        Map.get(user, :encrypted_full_name)

      is_binary(Map.get(user, :email)) and Map.get(user, :email) != "" ->
        Map.get(user, :email)

      true ->
        "User"
    end
  end

  def user_initials(user) do
    user
    |> user_display_name()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  embed_templates "layouts/*"
end
