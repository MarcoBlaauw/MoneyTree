import { expect, test } from "@playwright/test";
import { randomUUID } from "node:crypto";

import { BASE_URL, SESSION_COOKIE, extractSessionToken } from "../helpers/session";

test.describe("Control panel", () => {
  test("shows profile details and notification preferences", async ({ context, page }) => {
    const email = `control-panel-${randomUUID()}@example.com`;
    const password = "PlaywrightPwd34!";

    const response = await page.request.post("/api/register", {
      data: {
        email,
        password,
        encrypted_full_name: "Control Panel User",
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

    await page.goto("/app/react/control-panel");

    await expect(page.getByRole("heading", { name: "Control panel" })).toBeVisible();
    await expect(page.getByText(/Control Panel User/i)).toBeVisible();

    const transferToggle = page.getByRole("switch", { name: /Transfer alerts/i });
    await expect(transferToggle).toBeVisible();
    await expect(transferToggle).toHaveAttribute("aria-checked", "true");

    const securityToggle = page.getByRole("switch", { name: /Security alerts/i });
    await expect(securityToggle).toBeVisible();

    await expect(page.getByRole("table", { name: /Active sessions/i })).toBeVisible();
  });
});
