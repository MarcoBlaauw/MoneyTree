import { expect, test } from "@playwright/test";

declare global {
  interface Window {
    __moneytree_last_fetch_status?: number;
  }
}

const SESSION_COOKIE = "_money_tree_session";

test.describe("Next.js secure fetch integration", () => {
  test.beforeEach(async ({ context, page }) => {
    await context.addCookies([
      {
        name: SESSION_COOKIE,
        value: "playwright-session",
        url: "http://127.0.0.1:4000",
        path: "/",
      },
    ]);

    await page.route("**/api/mock-auth", async (route) => {
      const headers = route.request().headers();

      expect(headers.cookie).toContain(`${SESSION_COOKIE}=playwright-session`);

      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ ok: true }),
      });
    });
  });

  test("scripts receive CSP nonces and credentialed fetch succeeds", async ({ page }) => {
    const response = await page.goto("/app/react/secure-fetch");

    expect(response).not.toBeNull();

    const headers = response!.headers();
    expect(headers["content-security-policy"]).toBeTruthy();
    expect(headers["x-csrf-token"]).toBeTruthy();

    const nonceHeader = headers["x-csp-nonce"];
    expect(nonceHeader).toBeTruthy();

    const scriptNonce = await page.locator("script[nonce]").first().getAttribute("nonce");
    expect(scriptNonce).toBe(nonceHeader);

    const styleNonce = await page.locator("style[nonce]").first().getAttribute("nonce");
    expect(styleNonce).toBe(nonceHeader);

    await page.locator("#trigger-secure-fetch").click();

    await expect.poll(async () => {
      return await page.evaluate(() => window.__moneytree_last_fetch_status ?? null);
    }).toBe(200);
  });
});
