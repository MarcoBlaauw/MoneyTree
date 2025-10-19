import { expect, test } from "@playwright/test";

const SESSION_COOKIE = "_money_tree_session";

test.describe("KYC widget", () => {
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

  test("launches Persona iframe with sanitized event data", async ({ page }) => {
    await page.route(/\/api\/kyc\/session/, async (route) => {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          data: {
            client_token: "persona-client-token-4321",
            environment: "sandbox",
            inquiry_id: "inq_456",
            applicant: { ssn: "123-45-6789" },
          },
        }),
      });
    });

    await page.goto("/app/react/verify-identity");

    await page.getByTestId("launch-kyc").click();

    await expect(page.getByTestId("kyc-frame")).toHaveAttribute(
      "src",
      /withpersona\.com\/embedded-inquiry/,
    );

    const payload = await page.getByTestId("event-payload").first().textContent();
    expect(payload).not.toContain("persona-client-token-4321");
    expect(payload).toContain("***4321");
  });

  test("shows Persona errors", async ({ page }) => {
    await page.route(/\/api\/kyc\/session/, async (route) => {
      await route.fulfill({
        status: 502,
        contentType: "application/json",
        body: JSON.stringify({ error: "persona down" }),
      });
    });

    await page.goto("/app/react/verify-identity");

    await page.getByTestId("launch-kyc").click();

    await expect(page.getByTestId("error-kyc")).toContainText("persona down");
  });
});
