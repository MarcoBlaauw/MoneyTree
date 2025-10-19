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
      data: { token: "connect-token-9876" },
    });
  });

  test("renders Teller widget with sanitized telemetry", async ({ page }) => {
    await page.goto("/app/react/link-bank");

    await page.getByTestId("launch-teller").click();

    await expect(page.getByTestId("widget-frame")).toHaveAttribute(
      "src",
      /connect\.teller\.io\/widget\?token=/,
    );

    const payload = await page.getByTestId("event-payload").first().textContent();
    expect(payload).not.toContain("connect-token-9876");
    expect(payload).toContain("***9876");
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
