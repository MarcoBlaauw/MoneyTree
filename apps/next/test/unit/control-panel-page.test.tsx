import { afterEach, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import { cleanup, fireEvent, render, waitFor } from "@testing-library/react";

import { setupDom } from "../helpers/setup-dom";
import { renderControlPanelPage } from "../../app/control-panel/render-control-panel-page";
import type { ControlPanelObligation, FundingAccountOption } from "../../app/lib/obligations";
import type { ControlPanelSettings } from "../../app/lib/settings";

const CSRF_TOKEN = "csrf-token";

function createFetchResponse(status: number, body: Record<string, unknown>) {
  return Promise.resolve(
    new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    }),
  );
}

describe("Control panel page", () => {
  let restoreDom: (() => void) | undefined;
  const originalFetch = globalThis.fetch;

  beforeEach(() => {
    restoreDom = setupDom();
  });

  afterEach(() => {
    cleanup();
    globalThis.fetch = originalFetch;
    if (restoreDom) {
      restoreDom();
      restoreDom = undefined;
    }
  });

  it("renders profile summary and notification toggles", async () => {
    const settings: ControlPanelSettings = {
      profile: {
        displayName: "Ada Lovelace",
        fullName: "Ada Lovelace",
        email: "ada@example.com",
        role: "owner",
      },
      notifications: {
        emailEnabled: true,
        smsEnabled: false,
        pushEnabled: false,
        dashboardEnabled: false,
        upcomingEnabled: true,
        dueTodayEnabled: true,
        overdueEnabled: true,
        recoveredEnabled: true,
        upcomingLeadDays: 3,
        resendIntervalHours: 24,
        maxResends: 2,
      },
      sessions: [
        {
          id: "sess-1",
          context: "Browser",
          lastUsedAt: "2024-07-01T12:34:56Z",
          userAgent: "Playwright",
          ipAddress: "203.0.113.10",
        },
      ],
    };

    const view = render(await renderControlPanelPage(async () => settings));

    assert.ok(
      view.getByRole("heading", { name: "Control panel" }),
      "control panel heading should be visible",
    );

    assert.ok(view.getByText("Ada Lovelace"));
    assert.ok(view.getByText("ada@example.com"));

    const emailToggle = view.getByRole("switch", { name: /Email delivery/i });
    assert.equal(emailToggle.getAttribute("aria-checked"), "true");

    const dashboardToggle = view.getByRole("switch", { name: /Dashboard alerts/i });
    assert.equal(dashboardToggle.getAttribute("aria-checked"), "false");

    assert.ok(view.getByRole("table", { name: /Active sessions/i }));
  });

  it("updates notification preferences from the control panel", async () => {
    const settings: ControlPanelSettings = {
      profile: {
        displayName: "Ada Lovelace",
        fullName: "Ada Lovelace",
        email: "ada@example.com",
        role: "owner",
      },
      notifications: {
        emailEnabled: true,
        smsEnabled: false,
        pushEnabled: false,
        dashboardEnabled: false,
        upcomingEnabled: true,
        dueTodayEnabled: true,
        overdueEnabled: true,
        recoveredEnabled: true,
        upcomingLeadDays: 3,
        resendIntervalHours: 24,
        maxResends: 2,
      },
      sessions: [],
    };

    const fetchMock = async (input: RequestInfo | URL, init?: RequestInit) => {
      assert.equal(input, "/api/settings/notifications");
      assert.equal(init?.method, "PUT");
      assert.equal(init?.credentials, "include");
      assert.equal(
        init?.headers && (init.headers as Record<string, string>)["x-csrf-token"],
        CSRF_TOKEN,
      );

      const body = JSON.parse(String(init?.body ?? "{}")) as {
        notifications?: Record<string, unknown>;
      };

      assert.equal(body.notifications?.email_enabled, false);
      assert.equal(body.notifications?.dashboard_enabled, false);

      return createFetchResponse(200, {
        data: {
          notifications: {
            email_enabled: false,
            dashboard_enabled: false,
            sms_enabled: false,
            push_enabled: false,
            upcoming_enabled: true,
            due_today_enabled: true,
            overdue_enabled: true,
            recovered_enabled: true,
            upcoming_lead_days: 3,
            resend_interval_hours: 24,
            max_resends: 2,
          },
        },
      });
    };

    globalThis.fetch = fetchMock as typeof globalThis.fetch;

    const view = render(
      await renderControlPanelPage(async () => settings, { csrfToken: CSRF_TOKEN }),
    );

    const emailToggle = view.getByRole("switch", { name: /Email delivery/i });
    fireEvent.click(emailToggle);

    await waitFor(() => {
      assert.equal(emailToggle.getAttribute("aria-checked"), "false");
      assert.ok(view.getByText("Notification preferences updated."));
    });
  });

  it("creates obligations from the control panel", async () => {
    const settings: ControlPanelSettings = {
      profile: {
        displayName: "Ada Lovelace",
        fullName: "Ada Lovelace",
        email: "ada@example.com",
        role: "owner",
      },
      notifications: {
        emailEnabled: true,
        smsEnabled: false,
        pushEnabled: false,
        dashboardEnabled: true,
        upcomingEnabled: true,
        dueTodayEnabled: true,
        overdueEnabled: true,
        recoveredEnabled: true,
        upcomingLeadDays: 3,
        resendIntervalHours: 24,
        maxResends: 2,
      },
      sessions: [],
    };

    const fundingAccounts: FundingAccountOption[] = [
      {
        id: "acct-1",
        name: "Bills Checking",
        currency: "USD",
        type: "depository",
        subtype: "checking",
      },
    ];

    const obligations: ControlPanelObligation[] = [];

    let capturedInput: RequestInfo | URL | undefined;
    let capturedInit: RequestInit | undefined;

    const fetchMock = async (input: RequestInfo | URL, init?: RequestInit) => {
      capturedInput = input;
      capturedInit = init;
      return createFetchResponse(201, {
        data: {
          id: "obl-1",
          creditor_payee: "Water Utility",
          due_day: 18,
          due_rule: "calendar_day",
          minimum_due_amount: "88.45",
          currency: "USD",
          grace_period_days: 4,
          active: true,
          linked_funding_account_id: "acct-1",
          linked_funding_account: {
            id: "acct-1",
            name: "Bills Checking",
            currency: "USD",
            type: "depository",
            subtype: "checking",
          },
        },
      });
    };

    globalThis.fetch = fetchMock as typeof globalThis.fetch;

    const view = render(
      await renderControlPanelPage(async () => settings, {
        csrfToken: CSRF_TOKEN,
        fetchFundingAccounts: async () => fundingAccounts,
        fetchObligations: async () => obligations,
      }),
    );

    const creditorInput = view.getByTestId(
      "obligation-creditor-payee",
    ) as HTMLInputElement;
    const dueDayInput = view.getByTestId("obligation-due-day") as HTMLInputElement;
    const amountInput = view.getByTestId(
      "obligation-minimum-due-amount",
    ) as HTMLInputElement;
    const graceInput = view.getByTestId(
      "obligation-grace-period-days",
    ) as HTMLInputElement;
    const fundingAccountSelect = view.getByTestId(
      "obligation-funding-account",
    ) as HTMLSelectElement;

    await waitFor(() => {
      assert.equal(fundingAccountSelect.value, "acct-1");
    });

    fireEvent.change(creditorInput, {
      target: { value: "Water Utility" },
    });
    fireEvent.change(dueDayInput, {
      target: { value: "18" },
    });
    fireEvent.change(amountInput, {
      target: { value: "88.45" },
    });
    fireEvent.change(graceInput, {
      target: { value: "4" },
    });

    await waitFor(() => {
      assert.equal(creditorInput.value, "Water Utility");
      assert.equal(dueDayInput.value, "18");
      assert.equal(amountInput.value, "88.45");
      assert.equal(graceInput.value, "4");
    });

    fireEvent.click(view.getByTestId("obligation-submit"));

    await waitFor(() => {
      assert.ok(view.getByText("Water Utility"));
      assert.ok(view.getByText("Obligation created."));
      assert.ok(view.getByText(/Funding account: Bills Checking/i));
    });

    assert.equal(capturedInput, "/api/obligations");
    assert.equal(capturedInit?.method, "POST");
    assert.equal(capturedInit?.credentials, "include");
    assert.equal(
      capturedInit?.headers &&
        (capturedInit.headers as Record<string, string>)["x-csrf-token"],
      CSRF_TOKEN,
    );

    const body = JSON.parse(String(capturedInit?.body ?? "{}")) as Record<string, unknown>;
    assert.equal(body.creditor_payee, "Water Utility");
    assert.equal(body.linked_funding_account_id, "acct-1");
    assert.equal(body.minimum_due_amount, "88.45");
  });
});
