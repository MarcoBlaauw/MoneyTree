import { expect, test } from "@playwright/test";

const SESSION_COOKIE = "_money_tree_session";

test.describe("SimpleFIN bank linking", () => {
  test.beforeEach(async ({ context }) => {
    await context.addCookies([
      {
        name: SESSION_COOKIE,
        value: "playwright-session",
        url: "http://127.0.0.1:4000",
        path: "/",
      },
    ]);
  });

  test("renders the workspace-style SimpleFIN flow", async ({ page }) => {
    await page.route(/\/api\/simplefin\/connections/, async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ data: { connections: [] } }),
      });
    });

    await page.goto("/app/react/link-bank");

    await expect(page.getByRole("heading", { name: "Manage institutions" })).toBeVisible();
    await expect(page.getByRole("link", { name: "Back to Accounts" })).toHaveCount(0);
    await expect(page.getByRole("link", { name: "Manage institutions" })).toBeVisible();
    await expect(page.getByText("SimpleFIN Bridge")).toBeVisible();
    await expect(page.getByText("Stripe")).toHaveCount(0);
    await expect(page.getByText("Widget events")).toHaveCount(0);
  });

  test("claims setup token and renders discovered accounts", async ({ page }) => {
    await page.route(/\/api\/simplefin\/connections/, async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ data: { connections: [] } }),
      });
    });

    await page.route(/\/api\/simplefin\/claim/, async (route) => {
      const body = route.request().postDataJSON() as Record<string, unknown>;
      expect(body.setup_token).toBe("setup-token");

      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          data: {
            connection_id: "conn-123",
            institution_id: "inst-123",
            accounts: [{ id: "acct-1", name: "Checking", currency: "USD", balance: "42.00" }],
            errors: [],
          },
        }),
      });
    });

    await page.goto("/app/react/link-bank");

    await page.getByPlaceholder("Paste the one-time SimpleFIN setup token").fill("setup-token");
    await page.getByRole("button", { name: "Connect" }).click();

    await expect(page.getByText("Checking")).toBeVisible();
    await expect(page.getByText("USD · Balance 42.00")).toBeVisible();
  });
});
