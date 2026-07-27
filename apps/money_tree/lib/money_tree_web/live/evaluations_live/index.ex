defmodule MoneyTreeWeb.EvaluationsLive.Index do
  @moduledoc """
  Financial evaluation status: deterministic checks across Loan Center, documents, and quotes.
  """

  use MoneyTreeWeb, :live_view

  alias MoneyTree.Evaluations

  @statuses ~w(incomplete needs_review stale expiring opportunity)

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: current_user}} = socket) do
    {:ok,
     socket
     |> assign(:page_title, "Evaluations")
     |> assign(:statuses, @statuses)
     |> load_summary(current_user)}
  end

  @impl true
  def handle_event("refresh", _params, %{assigns: %{current_user: current_user}} = socket) do
    {:noreply, load_summary(socket, current_user)}
  end

  defp load_summary(socket, current_user) do
    assign(socket, :summary, Evaluations.status_summary(current_user))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-6">
      <.header title="Evaluations" subtitle="Deterministic status checks from Loan Center, documents, and quotes.">
        <:actions>
          <button class="btn btn-outline" type="button" phx-click="refresh">Refresh</button>
        </:actions>
      </.header>

      <p class="text-sm text-zinc-500">Updated <%= format_timestamp(@summary.generated_at) %></p>

      <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-5">
        <div :for={status <- @statuses} class="rounded-2xl border border-zinc-200 bg-white p-4 shadow-sm">
          <p class="text-xs font-semibold uppercase tracking-wide text-zinc-500"><%= status_label(status) %></p>
          <p class="mt-2 text-3xl font-semibold text-zinc-950"><%= Map.get(@summary.counts, status, 0) %></p>
          <p class="mt-2 text-sm text-zinc-500"><%= status_description(status) %></p>
        </div>
      </div>

      <div class="space-y-4">
        <div class="flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <h2 class="text-xl font-semibold text-zinc-900">Current items</h2>
            <p class="text-sm text-zinc-500">Showing the highest-priority evaluation items currently available.</p>
          </div>
          <p class="text-sm text-zinc-500"><%= length(@summary.items) %> total items</p>
        </div>

        <div :if={@summary.items != []} class="grid gap-3">
          <article :for={item <- Enum.take(@summary.items, 8)} class="rounded-2xl border border-zinc-200 bg-white p-4 shadow-sm">
            <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
              <div class="min-w-0 space-y-2">
                <div class="flex flex-wrap items-center gap-2">
                  <span class={status_badge_class(item.status)}><%= status_label(item.status) %></span>
                  <span class={severity_badge_class(item.severity)}><%= item.severity %></span>
                  <span class="text-xs uppercase tracking-wide text-zinc-500"><%= String.replace(to_string(item.domain), "_", " ") %></span>
                </div>
                <h3 class="text-base font-semibold text-zinc-950"><%= item.title %></h3>
                <p class="text-sm text-zinc-600"><%= item.summary %></p>
                <p :if={item.reasons != []} class="text-xs text-zinc-500"><%= Enum.join(item.reasons, ", ") %></p>
              </div>
              <.link navigate={item.target_path} class="btn btn-outline shrink-0">Open</.link>
            </div>
          </article>
        </div>

        <div :if={@summary.items == []} class="rounded-2xl border border-zinc-200 bg-white p-6 text-sm text-zinc-600 shadow-sm">
          No actionable evaluation items are available right now.
        </div>
      </div>
    </section>
    """
  end

  defp status_label("needs_review"), do: "Needs review"
  defp status_label(status), do: status |> to_string() |> String.capitalize()

  defp status_description("incomplete"), do: "Missing facts that block evaluation."

  defp status_description("needs_review"),
    do: "Reviewable facts or drafts waiting on confirmation."

  defp status_description("stale"), do: "Reviewed facts that may be too old."

  defp status_description("expiring"),
    do: "Quotes, leases, renewals, or terms approaching expiration."

  defp status_description("opportunity"), do: "Deterministic checks that found a possible action."
  defp status_description(_status), do: nil

  defp status_badge_class(status) do
    base = "rounded-full px-2 py-1 text-xs font-semibold"

    case status do
      "needs_review" -> "#{base} bg-amber-100 text-amber-800"
      "stale" -> "#{base} bg-sky-100 text-sky-800"
      "expiring" -> "#{base} bg-red-100 text-red-800"
      "opportunity" -> "#{base} bg-emerald-100 text-emerald-800"
      _ -> "#{base} bg-zinc-100 text-zinc-700"
    end
  end

  defp severity_badge_class(severity) do
    base = "rounded-full border px-2 py-1 text-xs font-semibold"

    case severity do
      "critical" -> "#{base} border-red-200 bg-red-50 text-red-800"
      "warning" -> "#{base} border-amber-200 bg-amber-50 text-amber-800"
      _ -> "#{base} border-sky-200 bg-sky-50 text-sky-800"
    end
  end

  defp format_timestamp(%DateTime{} = datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%b %d, %Y %H:%M UTC")
  rescue
    _ -> DateTime.to_string(datetime)
  end
end
