import { expect, test } from "@playwright/test";
import { randomUUID } from "node:crypto";

import { BASE_URL, SESSION_COOKIE, extractSessionToken } from "../helpers/session";

declare global {
  interface Window {
    __moneytree_last_fetch_status?: number;
  }
}

test.describe("Next.js secure fetch integration", () => {
  test.beforeEach(async ({ context, page }) => {
    const email = `secure-fetch-${randomUUID()}@example.com`;
    const password = "PlaywrightPwd12!";

    const response = await page.request.post("/api/register", {
      data: {
        email,
        password,
        encrypted_full_name: "Secure Fetch Tester",
      },
    });

    expect(response.status()).toBe(201);

    const sessionToken = extractSessionToken(response.headersArray());
    expect(sessionToken).toBeTruthy();

    await context.addCookies([
      {
        name: SESSION_COOKIE,
        value: sessionToken!,
        url: BASE_URL,
        path: "/",
        httpOnly: true,
      },
    ]);
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
