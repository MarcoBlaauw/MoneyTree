import type { components } from "@moneytree/contracts/generated/rest";

import { fetchWithSession } from "./session-fetch";

export type EvaluationStatusSummary =
  components["schemas"]["EvaluationStatusSummary"];

export type EvaluationStatusItem =
  components["schemas"]["EvaluationStatusItem"];

type EvaluationStatusSummaryResponse = {
  data?: EvaluationStatusSummary;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isStatusCounts(value: unknown): value is EvaluationStatusSummary["counts"] {
  if (!isRecord(value)) {
    return false;
  }

  return ["incomplete", "needs_review", "stale", "expiring", "opportunity"].every(
    (key) => typeof value[key] === "number",
  );
}

function isStatusItem(value: unknown): value is EvaluationStatusItem {
  if (!isRecord(value)) {
    return false;
  }

  return (
    typeof value.id === "string" &&
    typeof value.domain === "string" &&
    typeof value.resource_id === "string" &&
    typeof value.status === "string" &&
    typeof value.severity === "string" &&
    typeof value.title === "string" &&
    typeof value.summary === "string" &&
    Array.isArray(value.reasons) &&
    value.reasons.every((reason) => typeof reason === "string") &&
    typeof value.source === "string" &&
    typeof value.target_path === "string"
  );
}

function resolveSummary(payload: unknown): EvaluationStatusSummary | null {
  if (!isRecord(payload)) {
    return null;
  }

  const response = payload as EvaluationStatusSummaryResponse;
  const data = response.data;

  if (
    !data ||
    typeof data.generated_at !== "string" ||
    !isStatusCounts(data.counts) ||
    !Array.isArray(data.items)
  ) {
    return null;
  }

  return {
    generated_at: data.generated_at,
    counts: data.counts,
    items: data.items.filter(isStatusItem),
  };
}

export async function getEvaluationStatusSummary(): Promise<EvaluationStatusSummary | null> {
  const response = await fetchWithSession("/api/evaluations/status-summary");

  if (!response || !response.ok) {
    return null;
  }

  const payload = (await response.json().catch(() => null)) as unknown;
  return resolveSummary(payload);
}
