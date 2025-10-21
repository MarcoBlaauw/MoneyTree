import { expect, test } from "@playwright/test";
import { randomUUID } from "node:crypto";

import { BASE_URL, SESSION_COOKIE, extractSessionToken } from "../helpers/session";

test.describe("Next.js home experience", () => {
  test("shows a login button to guests", async ({ page }) => {
    await page.goto("/app/react");

    const loginLink = page.getByRole("link", { name: "Log in" });
    await expect(loginLink).toBeVisible();
    await expect(loginLink).toHaveAttribute("href", "/login");
  });

  test("greets authenticated users with quick actions", async ({ context, page }) => {
    const email = `home-${randomUUID()}@example.com`;
    const password = "PlaywrightPwd12!";

    const response = await page.request.post("/api/register", {
      data: {
        email,
        password,
        encrypted_full_name: "Home Spec User",
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

    await page.goto("/app/react");

    await expect(
      page.getByRole("heading", { name: /Welcome back, Home Spec User!/i }),
    ).toBeVisible();

    const expectedLinks: Array<{ name: RegExp; href: string }> = [
      { name: /Open dashboard/i, href: "/app/dashboard" },
      { name: /Manage transfers/i, href: "/app/transfers" },
      { name: /Update settings/i, href: "/app/settings" },
      { name: /Visit control panel/i, href: "/control-panel" },
    ];

    for (const { name, href } of expectedLinks) {
      await expect(page.getByRole("link", { name })).toHaveAttribute("href", href);
    }
  });
});
