import { afterEach, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import { cleanup, render } from "@testing-library/react";

import { setupDom } from "../helpers/setup-dom";
import { renderHomePage } from "../../app/render-home-page";

describe("Home page", () => {
  let restoreDom: (() => void) | undefined;
  const originalPhoenixOrigin = process.env.NEXT_PUBLIC_PHOENIX_ORIGIN;
  const phoenixOrigin = "http://127.0.0.1:4000";

  beforeEach(() => {
    restoreDom = setupDom();
    process.env.NEXT_PUBLIC_PHOENIX_ORIGIN = phoenixOrigin;
  });

  afterEach(() => {
    cleanup();
    if (restoreDom) {
      restoreDom();
      restoreDom = undefined;
    }
    if (originalPhoenixOrigin === undefined) {
      delete process.env.NEXT_PUBLIC_PHOENIX_ORIGIN;
    } else {
      process.env.NEXT_PUBLIC_PHOENIX_ORIGIN = originalPhoenixOrigin;
    }
  });

  it("shows a login call-to-action for guests", async () => {
    const view = render(
      await renderHomePage({ fetchCurrentUser: async () => null }),
    );

    const loginLink = view.getByRole("link", { name: "Log in" });
    assert.equal(loginLink.getAttribute("href"), `${phoenixOrigin}/login`);

    assert.equal(view.queryByText(/Welcome back/i), null);
  });

  it("greets authenticated users and surfaces quick actions", async () => {
    const view = render(
      await renderHomePage({
        fetchCurrentUser: async () => ({
          email: "sam@example.com",
          name: null,
        }),
        forwardedPrefix: "/app/react",
      }),
    );

    assert.ok(
      view.getByRole("heading", { name: "Welcome back, sam@example.com!" }),
    );

    const expectedLinks: Array<{ href: string; name: RegExp }> = [
      { href: `${phoenixOrigin}/app/dashboard`, name: /Open dashboard/i },
      { href: `${phoenixOrigin}/app/transfers`, name: /Manage transfers/i },
      { href: "/app/react/control-panel", name: /Visit control panel/i },
    ];

    for (const { href, name } of expectedLinks) {
      const link = view.getByRole("link", { name });
      assert.equal(link.getAttribute("href"), href);
    }
  });
});
