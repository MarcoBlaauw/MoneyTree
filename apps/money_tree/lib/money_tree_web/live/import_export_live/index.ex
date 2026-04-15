defmodule MoneyTreeWeb.ImportExportLive.Index do
  @moduledoc """
  LiveView for import/export and user data operation entry points.
  """

  use MoneyTreeWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Import / Export")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-6">
      <.header title="Import / Export" subtitle="Manage data import, export, and privacy-oriented data operations.">
        <:actions>
          <.link navigate={~p"/app/settings/privacy"} class="btn btn-outline">
            Open data & privacy settings
          </.link>
        </:actions>
      </.header>

      <div class="grid gap-4 lg:grid-cols-2">
        <article class="rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <h2 class="text-base font-semibold text-zinc-900">Import transactions</h2>
          <p class="mt-2 text-sm text-zinc-600">
            Use review-first imports so extracted records can be validated before any persistence.
          </p>
          <p class="mt-4 rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-2 text-xs text-zinc-500">
            Planned: CSV import and manual upload review workflow.
          </p>
        </article>

        <article class="rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <h2 class="text-base font-semibold text-zinc-900">Export data</h2>
          <p class="mt-2 text-sm text-zinc-600">
            Generate user-scoped exports for portability and backups from a dedicated surface.
          </p>
          <p class="mt-4 rounded-lg border border-zinc-100 bg-zinc-50 px-3 py-2 text-xs text-zinc-500">
            Planned: transaction and budget exports with audit-friendly metadata.
          </p>
        </article>
      </div>
    </section>
    """
  end
end
