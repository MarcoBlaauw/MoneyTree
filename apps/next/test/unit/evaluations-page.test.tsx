import { afterEach, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import { cleanup, render } from "@testing-library/react";

import { setupDom } from "../helpers/setup-dom";
import { renderEvaluationsPage } from "../../app/evaluations/render-evaluations-page";
import type { EvaluationStatusSummary } from "../../app/lib/evaluations";

describe("Evaluations page", () => {
  let restoreDom: (() => void) | undefined;

  beforeEach(() => {
    restoreDom = setupDom();
  });

  afterEach(() => {
    cleanup();
    if (restoreDom) {
      restoreDom();
      restoreDom = undefined;
    }
  });

  it("renders status counts and actionable items", async () => {
    const summary: EvaluationStatusSummary = {
      generated_at: "2026-05-22T12:00:00Z",
      counts: {
        incomplete: 1,
        needs_review: 2,
        stale: 3,
        expiring: 4,
        opportunity: 5,
      },
      items: [
        {
          id: "mortgage-1",
          domain: "mortgage",
          resource_id: "resource-1",
          status: "incomplete",
          severity: "warning",
          title: "Home loan is missing a home value estimate",
          summary: "Mortgage evaluations that depend on equity or LTV need a reviewed home value.",
          reasons: ["missing_home_value_estimate"],
          source: "deterministic",
          target_path: "/app/loans?mortgage_id=resource-1",
        },
      ],
    };

    const view = render(
      await renderEvaluationsPage({ fetchSummary: async () => summary }),
    );

    assert.ok(view.getByRole("heading", { name: "Financial evaluation status" }));
    assert.ok(view.getAllByText("Incomplete").length >= 1);
    assert.ok(view.getByText("Needs review"));
    assert.ok(view.getByText("Home loan is missing a home value estimate"));

    const link = view.getByRole("link", { name: "Open" });
    assert.equal(link.getAttribute("href"), "/app/loans?mortgage_id=resource-1");
  });

  it("renders an unauthenticated state when the summary is unavailable", async () => {
    const view = render(
      await renderEvaluationsPage({ fetchSummary: async () => null }),
    );

    assert.ok(view.getByRole("heading", { name: "Financial evaluation status" }));
    assert.ok(
      view.getByText(
        "Evaluation status is unavailable without an authenticated MoneyTree session.",
      ),
    );
  });
});
