import { headers } from "next/headers";
import Script from "next/script";
import LinkBankClient from "./link-bank-client";

function inferTellerEnvironment(connectHost: string | undefined): string | undefined {
  if (!connectHost) {
    return undefined;
  }

  const host = connectHost.toLowerCase();

  if (host.includes("sandbox")) {
    return "sandbox";
  }

  if (host.includes("development")) {
    return "development";
  }

  if (host.includes("production")) {
    return "production";
  }

  return undefined;
}

export default async function LinkBankPage() {
  const headerList = await headers();
  const csrfToken = headerList.get("x-csrf-token") ?? "";
  const cspNonce = headerList.get("x-csp-nonce") ?? undefined;
  const connectHost = process.env.TELLER_CONNECT_HOST;
  const hasConnectApplicationId = Boolean(process.env.TELLER_CONNECT_APPLICATION_ID);
  const hasPlaidConfig =
    Boolean(process.env.PLAID_CLIENT_ID) &&
    Boolean(process.env.PLAID_SECRET);
  const enabledProviders = (process.env.BANK_SYNC_ENABLED_PROVIDERS ?? "simplefin,manual")
    .split(",")
    .map((provider) => provider.trim().toLowerCase())
    .filter(Boolean);
  const simplefinCreateUrl =
    process.env.SIMPLEFIN_CREATE_URL ?? "https://bridge.simplefin.org/simplefin/create";
  const tellerConfig = {
    applicationId: process.env.TELLER_CONNECT_APPLICATION_ID,
    environment: process.env.TELLER_CONNECT_ENVIRONMENT ?? inferTellerEnvironment(connectHost),
  };

  return (
    <div className="min-h-screen bg-zinc-50 text-zinc-950">
      <button
        type="button"
        data-next-sidebar-open
        className="fixed left-4 top-4 z-30 hidden h-9 w-9 items-center justify-center rounded-lg border border-zinc-200 bg-white text-zinc-700 shadow-sm hover:bg-zinc-100"
        aria-label="Open sidebar"
        title="Open sidebar"
      >
        <svg
          viewBox="0 0 24 24"
          className="h-4 w-4"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <path d="M4 5h16" />
          <path d="M4 12h16" />
          <path d="M4 19h16" />
        </svg>
      </button>

      <div data-next-shell className="mx-auto flex min-h-screen w-full max-w-[96rem] flex-col lg:flex-row">
        <aside data-next-sidebar className="hidden w-72 shrink-0 border-r border-zinc-200 bg-white lg:flex lg:flex-col">
          <div className="border-b border-zinc-200 px-6 py-6">
            <div className="flex items-start justify-between gap-3">
              <div>
                <p className="text-[11px] font-semibold uppercase tracking-[0.22em] text-emerald-600">
                  MoneyTree
                </p>
                <h1 className="mt-2 text-2xl font-semibold text-zinc-900">Workspace</h1>
              </div>
              <button
                type="button"
                data-next-sidebar-close
                className="hidden h-8 w-8 shrink-0 items-center justify-center rounded-lg border border-zinc-200 text-zinc-600 hover:bg-zinc-100 lg:inline-flex"
                aria-label="Close sidebar"
                title="Close sidebar"
              >
                <svg
                  viewBox="0 0 24 24"
                  className="h-4 w-4"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  aria-hidden="true"
                >
                  <path d="M9 4v16" />
                  <path d="M4 5h16" />
                  <path d="M4 19h16" />
                </svg>
              </button>
            </div>
            <p className="mt-1 text-sm text-zinc-500">
              Budgets, transfers, alerts, and account operations in one place.
            </p>
          </div>

          <nav className="flex-1 space-y-6 px-4 py-6">
            <div className="space-y-2">
              <p className="px-2 text-[11px] font-semibold uppercase tracking-[0.2em] text-zinc-400">
                Primary
              </p>
              {[
                ["Dashboard", "/app/dashboard"],
                ["Accounts", "/app/accounts"],
                ["Transactions", "/app/transactions"],
                ["Budgets", "/app/budgets"],
                ["Obligations", "/app/obligations"],
                ["Assets", "/app/assets"],
                ["Loan Center", "/app/loans"],
                ["Transfers", "/app/transfers"],
                ["Settings", "/app/settings"],
              ].map(([label, path]) => (
                <a
                  key={path}
                  className="flex items-center justify-between rounded-xl px-3 py-2 text-sm font-medium text-zinc-700 transition-colors hover:bg-zinc-100 hover:text-zinc-900"
                  href={path}
                >
                  <span>{label}</span>
                </a>
              ))}
            </div>

            <div className="space-y-2">
              <p className="px-2 text-[11px] font-semibold uppercase tracking-[0.2em] text-zinc-400">
                Workspace
              </p>
              <a
                href="/app/react/link-bank"
                className="flex items-center justify-between rounded-xl bg-emerald-500 px-3 py-2 text-sm font-medium text-white shadow-sm"
              >
                <span>Manage institutions</span>
              </a>
              <a
                href="/app/transactions/categorization"
                className="flex items-center justify-between rounded-xl px-3 py-2 text-sm font-medium text-zinc-700 transition-colors hover:bg-zinc-100 hover:text-zinc-900"
              >
                <span>Categorization rules</span>
              </a>
              <a
                href="/app/import-export"
                className="flex items-center justify-between rounded-xl px-3 py-2 text-sm font-medium text-zinc-700 transition-colors hover:bg-zinc-100 hover:text-zinc-900"
              >
                <span>Import / Export</span>
              </a>
              <a
                href="/app/settings/security"
                className="flex items-center justify-between rounded-xl px-3 py-2 text-sm font-medium text-zinc-700 transition-colors hover:bg-zinc-100 hover:text-zinc-900"
              >
                <span>Security settings</span>
              </a>
            </div>
          </nav>
        </aside>

        <main className="flex min-w-0 flex-1 flex-col gap-6 px-5 py-8 sm:px-8 lg:px-10">
          <section className="space-y-1">
            <div>
              <p className="text-sm font-medium text-zinc-500">Accounts & institutions</p>
              <h2 className="mt-1 text-2xl font-semibold text-zinc-900">Manage institutions</h2>
              <p className="mt-1 max-w-2xl text-sm text-zinc-500">
                Manage read-only account data connections with SimpleFIN Bridge.
              </p>
            </div>
          </section>

          {(enabledProviders.includes("teller") && !hasConnectApplicationId) ||
          (enabledProviders.includes("plaid") && !hasPlaidConfig) ? (
            <section className="rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">
              {enabledProviders.includes("teller") && !hasConnectApplicationId ? (
                <p>
                  Missing <code>TELLER_CONNECT_APPLICATION_ID</code> in environment.
                </p>
              ) : null}
              {enabledProviders.includes("plaid") && !hasPlaidConfig ? (
                <p>
                  Missing <code>PLAID_CLIENT_ID</code> and <code>PLAID_SECRET</code> in environment.
                </p>
              ) : null}
            </section>
          ) : null}

          <LinkBankClient
            csrfToken={csrfToken}
            tellerConfig={tellerConfig}
            enabledProviders={enabledProviders}
            simplefinCreateUrl={simplefinCreateUrl}
          />
        </main>
      </div>

      {enabledProviders.includes("teller") ? (
        <Script
          id="teller-connect-script"
          nonce={cspNonce}
          src="https://cdn.teller.io/connect/connect.js"
          strategy="lazyOnload"
        />
      ) : null}
      {enabledProviders.includes("plaid") ? (
        <Script
          id="plaid-link-script"
          nonce={cspNonce}
          src="https://cdn.plaid.com/link/v2/stable/link-initialize.js"
          strategy="lazyOnload"
        />
      ) : null}
      <Script id="moneytree-next-sidebar" strategy="afterInteractive">
        {`
          (() => {
            const mount = () => {
              const shell = document.querySelector("[data-next-shell]");
              const sidebar = document.querySelector("[data-next-sidebar]");
              const closeButton = document.querySelector("[data-next-sidebar-close]");
              const openButton = document.querySelector("[data-next-sidebar-open]");

              if (!shell || !sidebar || !closeButton || !openButton || shell.dataset.sidebarMounted === "true") {
                return;
              }

              shell.dataset.sidebarMounted = "true";

              const positionOpenButton = () => {
                const shellLeft = shell.getBoundingClientRect().left;
                openButton.style.left = \`\${Math.max(16, shellLeft + 16)}px\`;
              };

              const setCollapsed = (collapsed) => {
                if (collapsed) {
                  positionOpenButton();
                  sidebar.style.display = "none";
                  openButton.classList.remove("hidden");
                  openButton.classList.add("lg:inline-flex");
                } else {
                  sidebar.style.display = "";
                  openButton.classList.add("hidden");
                  openButton.classList.remove("lg:inline-flex");
                }

                window.localStorage.setItem("moneytree.sidebarCollapsed", collapsed ? "true" : "false");
              };

              setCollapsed(window.localStorage.getItem("moneytree.sidebarCollapsed") === "true");
              closeButton.addEventListener("click", () => setCollapsed(true));
              openButton.addEventListener("click", () => setCollapsed(false));
              window.addEventListener("resize", positionOpenButton);
            };

            if (document.readyState === "loading") {
              document.addEventListener("DOMContentLoaded", mount);
            } else {
              mount();
            }
          })();
        `}
      </Script>
    </div>
  );
}
