import { afterEach, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import { cleanup, render } from "@testing-library/react";

import { setupDom } from "../helpers/setup-dom";
import { renderControlPanelPage } from "../../app/control-panel/render-control-panel-page";
import type { ControlPanelSettings } from "../../app/lib/settings";

describe("Control panel page", () => {
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

  it("renders profile summary and notification toggles", async () => {
    const settings: ControlPanelSettings = {
      profile: {
        displayName: "Ada Lovelace",
        fullName: "Ada Lovelace",
        email: "ada@example.com",
        role: "owner",
      },
      notifications: {
        transferAlerts: true,
        securityAlerts: false,
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

    const transferToggle = view.getByRole("switch", { name: /Transfer alerts/i });
    assert.equal(transferToggle.getAttribute("aria-checked"), "true");

    const securityToggle = view.getByRole("switch", { name: /Security alerts/i });
    assert.equal(securityToggle.getAttribute("aria-checked"), "false");

    assert.ok(view.getByRole("table", { name: /Active sessions/i }));
  });
});
