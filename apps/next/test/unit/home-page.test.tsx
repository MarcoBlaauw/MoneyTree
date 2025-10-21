import { afterEach, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import { cleanup, render } from "@testing-library/react";

import { setupDom } from "../helpers/setup-dom";
import { renderHomePage } from "../../app/page";

describe("Home page", () => {
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

  it("shows a login call-to-action for guests", async () => {
    const view = render(
      await renderHomePage(async () => null),
    );

    const loginLink = view.getByRole("link", { name: "Log in" });
    assert.equal(loginLink.getAttribute("href"), "/login");

    assert.equal(view.queryByText(/Welcome back/i), null);
  });

  it("greets authenticated users and surfaces quick actions", async () => {
    const view = render(
      await renderHomePage(async () => ({
        email: "sam@example.com",
        name: null,
      })),
    );

    assert.ok(
      view.getByRole("heading", { name: "Welcome back, sam@example.com!" }),
    );

    const expectedLinks: Array<{ href: string; name: RegExp }> = [
      { href: "/app/dashboard", name: /Open dashboard/i },
      { href: "/app/transfers", name: /Manage transfers/i },
      { href: "/app/settings", name: /Update settings/i },
      { href: "/control-panel", name: /Visit control panel/i },
    ];

    for (const { href, name } of expectedLinks) {
      const link = view.getByRole("link", { name });
      assert.equal(link.getAttribute("href"), href);
    }
  });
});
