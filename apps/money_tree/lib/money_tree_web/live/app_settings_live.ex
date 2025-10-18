defmodule MoneyTreeWeb.AppSettingsLive do
  @moduledoc """
  Placeholder LiveView for user and organization settings.
  """

  use MoneyTreeWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Settings")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-4">
      <h1 class="text-3xl font-semibold text-zinc-900">Settings</h1>
      <p class="text-zinc-600">Configure your MoneyTree experience.</p>
    </section>
    """
  end
end
