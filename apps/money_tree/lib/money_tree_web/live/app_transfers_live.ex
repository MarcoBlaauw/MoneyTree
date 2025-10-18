defmodule MoneyTreeWeb.AppTransfersLive do
  @moduledoc """
  Placeholder LiveView for upcoming transfer management tools.
  """

  use MoneyTreeWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Transfers")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-4">
      <h1 class="text-3xl font-semibold text-zinc-900">Transfers</h1>
      <p class="text-zinc-600">
        Manage and review account transfers from this dashboard.
      </p>
    </section>
    """
  end
end
