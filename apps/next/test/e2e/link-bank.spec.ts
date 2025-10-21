import { expect, test } from "@playwright/test";

const SESSION_COOKIE = "_money_tree_session";

function interceptJson(page: import("@playwright/test").Page, url: RegExp | string, body: unknown, status = 200) {
  return page.route(url, async (route) => {
    await route.fulfill({
      status,
      contentType: "application/json",
      body: JSON.stringify(body),
    });
  });
}

test.describe("Bank linking widgets", () => {
  test.beforeEach(async ({ context, page }) => {
    await context.addCookies([
      {
        name: SESSION_COOKIE,
        value: "playwright-session",
        url: "http://127.0.0.1:4000",
        path: "/",
      },
    ]);

    await interceptJson(page, /\/api\/teller\/connect_token/, {
      data: { connect_token: "connect-token-9876" },
    });

    await page.route(/\/api\/teller\/exchange/, async (route) => {
      const body = route.request().postDataJSON() as Record<string, unknown>;
      expect(body.public_token).toBe("public-token-9876");
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ data: { connection_id: "conn-123" } }),
      });
    });

    await page.addInitScript(() => {
      const globalWindow = window as typeof window & {
        __tellerConnectCalls?: unknown[];
      };

      globalWindow.__tellerConnectCalls = [];
      globalWindow.TellerConnect = {
        setup(options) {
          globalWindow.__tellerConnectCalls?.push(options);
          return {
            open() {
              if (typeof options.onSuccess === "function") {
                options.onSuccess({
                  public_token: "public-token-9876",
                  enrollment: { institution: { id: "demo-bank", name: "Demo Bank" } },
                });
              }
            },
            destroy() {
              // noop
            },
          };
        },
      };
    });
  });

  test("renders Teller widget with sanitized telemetry", async ({ page }) => {
    await page.goto("/app/react/link-bank");

    await page.getByTestId("launch-teller").click();

    const payloadLocator = page.getByTestId("event-payload").first();
    await expect(payloadLocator).toBeVisible();
    const payload = await payloadLocator.textContent();
    expect(payload).not.toContain("connect-token-9876");
    expect(payload).not.toContain("public-token-9876");
    expect(payload).toContain("***9876");

    await expect(page.getByTestId("widget-events")).toContainText("Teller exchange succeeded");
  });

  test("surfaces Plaid errors", async ({ page }) => {
    await interceptJson(
      page,
      /\/api\/plaid\/link_token/,
      { error: "sandbox limit reached" },
      429,
    );

    await page.goto("/app/react/link-bank");

    await page.getByTestId("launch-plaid").click();

    await expect(page.getByTestId("error-plaid")).toContainText("sandbox limit reached");
  });
});
