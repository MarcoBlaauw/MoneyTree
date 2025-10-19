defmodule MoneyTreeWeb.AppDashboardLive do
  @moduledoc """
  Dashboard view shown after signing in.
  """

  use MoneyTreeWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Dashboard")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-4">
      <h1 class="text-3xl font-semibold text-zinc-900">Dashboard</h1>
      <p class="text-zinc-600">Welcome back, <%= @current_user.email %>.</p>
    </section>
    """
  end
end
