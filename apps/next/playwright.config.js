// @ts-check
const { defineConfig, devices } = require("@playwright/test");
const path = require("node:path");

const baseURL = process.env.PLAYWRIGHT_BASE_URL || "http://127.0.0.1:4000";
const repoRoot = path.resolve(__dirname, "../..");

module.exports = defineConfig({
  testDir: "./test/e2e",
  timeout: 60_000,
  expect: {
    timeout: 10_000,
  },
  retries: process.env.CI ? 2 : 0,
  use: {
    baseURL,
    trace: "on-first-retry",
    video: "retain-on-failure",
  },
  webServer: [
    {
      command: "pnpm --filter next dev",
      url: "http://127.0.0.1:3100",
      reuseExistingServer: !process.env.CI,
      cwd: repoRoot,
      env: {
        NEXT_BASE_PATH: "/app/react",
        PORT: "3100",
        HOSTNAME: "127.0.0.1",
        NEXT_PUBLIC_PHOENIX_ORIGIN: baseURL,
      },
      timeout: 120_000,
    },
    {
      command: "MIX_ENV=test PHX_SERVER=true PORT=4000 mix phx.server",
      url: "http://127.0.0.1:4000/app/react",
      reuseExistingServer: !process.env.CI,
      cwd: path.resolve(__dirname, "../money_tree"),
      timeout: 120_000,
    },
  ],
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
