import React from "react";
import Link from "next/link";

import type {
  EvaluationStatusItem,
  EvaluationStatusSummary,
} from "../lib/evaluations";
import { getEvaluationStatusSummary } from "../lib/evaluations";

type RenderEvaluationsPageOptions = {
  fetchSummary?: () => Promise<EvaluationStatusSummary | null>;
};

const statusLabels: Record<keyof EvaluationStatusSummary["counts"], string> = {
  incomplete: "Incomplete",
  needs_review: "Needs review",
  stale: "Stale",
  expiring: "Expiring",
  opportunity: "Opportunity",
};

const statusDescriptions: Record<keyof EvaluationStatusSummary["counts"], string> = {
  incomplete: "Missing facts that block evaluation.",
  needs_review: "Reviewable facts or drafts waiting on confirmation.",
  stale: "Reviewed facts that may be too old.",
  expiring: "Quotes, leases, renewals, or terms approaching expiration.",
  opportunity: "Deterministic checks that found a possible action.",
};

const severityClasses: Record<EvaluationStatusItem["severity"], string> = {
  critical: "border-red-200 bg-red-50 text-red-800",
  warning: "border-amber-200 bg-amber-50 text-amber-800",
  info: "border-sky-200 bg-sky-50 text-sky-800",
};

const statusClasses: Record<EvaluationStatusItem["status"], string> = {
  incomplete: "bg-zinc-100 text-zinc-700",
  needs_review: "bg-amber-100 text-amber-800",
  stale: "bg-sky-100 text-sky-800",
  expiring: "bg-red-100 text-red-800",
  opportunity: "bg-emerald-100 text-emerald-800",
};

function formatGeneratedAt(value: string): string {
  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return "Unknown";
  }

  return new Intl.DateTimeFormat("en-US", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}

function topItems(summary: EvaluationStatusSummary): EvaluationStatusItem[] {
  return summary.items.slice(0, 8);
}

function EvaluationStatusCard({
  status,
  count,
}: {
  status: keyof EvaluationStatusSummary["counts"];
  count: number;
}) {
  return (
    <article className="rounded-lg border border-zinc-200 bg-white p-4 shadow-sm">
      <p className="text-xs font-semibold uppercase tracking-wide text-zinc-500">
        {statusLabels[status]}
      </p>
      <p className="mt-2 text-3xl font-semibold text-zinc-950">{count}</p>
      <p className="mt-2 text-sm text-zinc-500">{statusDescriptions[status]}</p>
    </article>
  );
}

function EvaluationItem({ item }: { item: EvaluationStatusItem }) {
  return (
    <article className="rounded-lg border border-zinc-200 bg-white p-4 shadow-sm">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0 space-y-2">
          <div className="flex flex-wrap items-center gap-2">
            <span
              className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClasses[item.status]}`}
            >
              {statusLabels[item.status]}
            </span>
            <span
              className={`rounded-full border px-2 py-1 text-xs font-semibold ${severityClasses[item.severity]}`}
            >
              {item.severity}
            </span>
            <span className="text-xs uppercase tracking-wide text-zinc-500">
              {item.domain.replaceAll("_", " ")}
            </span>
          </div>
          <h2 className="text-base font-semibold text-zinc-950">{item.title}</h2>
          <p className="text-sm text-zinc-600">{item.summary}</p>
          {item.reasons.length > 0 ? (
            <p className="text-xs text-zinc-500">{item.reasons.join(", ")}</p>
          ) : null}
        </div>
        <Link
          className="inline-flex shrink-0 items-center justify-center rounded-md border border-primary/30 px-3 py-2 text-sm font-semibold text-primary transition hover:border-primary"
          href={item.target_path}
        >
          Open
        </Link>
      </div>
    </article>
  );
}

export async function renderEvaluationsPage({
  fetchSummary = getEvaluationStatusSummary,
}: RenderEvaluationsPageOptions = {}) {
  const summary = await fetchSummary();

  if (!summary) {
    return (
      <main className="bg-background text-foreground min-h-screen">
        <section className="mx-auto flex w-full max-w-5xl flex-col gap-5 px-6 py-16">
          <header className="space-y-2">
            <p className="text-xs font-semibold uppercase tracking-wide text-primary">
              Evaluations
            </p>
            <h1 className="text-3xl font-semibold tracking-tight text-foreground">
              Financial evaluation status
            </h1>
            <p className="text-sm text-zinc-500">
              Sign in to review evaluation status, stale data, expiring items, and opportunities.
            </p>
          </header>
          <div className="rounded-lg border border-dashed border-primary/30 bg-white p-6 text-sm text-zinc-600">
            Evaluation status is unavailable without an authenticated MoneyTree session.
          </div>
        </section>
      </main>
    );
  }

  const statuses = Object.keys(statusLabels) as Array<
    keyof EvaluationStatusSummary["counts"]
  >;
  const actionableItems = topItems(summary);

  return (
    <main className="bg-background text-foreground min-h-screen">
      <section className="mx-auto flex w-full max-w-6xl flex-col gap-8 px-6 py-12">
        <header className="space-y-3">
          <p className="text-xs font-semibold uppercase tracking-wide text-primary">
            Evaluations
          </p>
          <div className="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div className="space-y-2">
              <h1 className="text-3xl font-semibold tracking-tight text-foreground">
                Financial evaluation status
              </h1>
              <p className="max-w-3xl text-sm text-zinc-500">
                Review deterministic status checks from Loan Center, documents, quotes, and future evaluation domains.
              </p>
            </div>
            <p className="text-sm text-zinc-500">
              Updated {formatGeneratedAt(summary.generated_at)}
            </p>
          </div>
        </header>

        <section
          aria-label="Evaluation status counts"
          className="grid gap-4 sm:grid-cols-2 lg:grid-cols-5"
        >
          {statuses.map((status) => (
            <EvaluationStatusCard
              key={status}
              status={status}
              count={summary.counts[status]}
            />
          ))}
        </section>

        <section className="space-y-4">
          <div className="flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h2 className="text-xl font-semibold text-zinc-950">Current items</h2>
              <p className="text-sm text-zinc-500">
                Showing the highest-priority evaluation items currently available.
              </p>
            </div>
            <p className="text-sm text-zinc-500">{summary.items.length} total items</p>
          </div>

          {actionableItems.length > 0 ? (
            <div className="grid gap-3">
              {actionableItems.map((item) => (
                <EvaluationItem key={item.id} item={item} />
              ))}
            </div>
          ) : (
            <div className="rounded-lg border border-zinc-200 bg-white p-6 text-sm text-zinc-600 shadow-sm">
              No actionable evaluation items are available right now.
            </div>
          )}
        </section>
      </section>
    </main>
  );
}
