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
  const hasStripeConnectConfig =
    Boolean(process.env.STRIPE_CONNECT_CLIENT_ID) &&
    Boolean(process.env.STRIPE_CONNECT_REDIRECT_URI);
  const hasPlaidConfig =
    Boolean(process.env.PLAID_CLIENT_ID) &&
    Boolean(process.env.PLAID_SECRET);
  const tellerConfig = {
    applicationId: process.env.TELLER_CONNECT_APPLICATION_ID,
    environment: process.env.TELLER_CONNECT_ENVIRONMENT ?? inferTellerEnvironment(connectHost),
  };

  return (
    <main className="mx-auto flex w-full max-w-5xl flex-col gap-8 px-6 py-12">
      <section className="space-y-4">
        <h1 className="text-3xl font-semibold text-slate-900">Link a bank account</h1>
        <p className="text-base text-slate-600">
          Launch Teller Connect or Plaid Link directly from the Phoenix hosted Next.js
          experience. Tokens are requested through credentialed fetch calls that forward
          the session cookie and CSRF header.
        </p>
      </section>

      <section className="rounded-xl border border-amber-300/60 bg-amber-50/80 p-4 text-sm text-amber-900">
        <p className="font-semibold">Troubleshooting</p>
        <ul className="mt-2 list-disc space-y-1 pl-5">
          <li>If buttons do nothing, restart both Phoenix and Next, then hard-refresh this page.</li>
          <li>Confirm JS assets under <code>/app/react/_next/...</code> load with HTTP 200.</li>
          <li>
            If clicks show an inline API error, verify Teller setup; in local dev, <code>TELLER_CONNECT_APPLICATION_ID</code> and
            a valid cert/key pair are required for Teller Connect token creation.
          </li>
        </ul>
        {!hasConnectApplicationId ? (
          <p className="mt-2 font-medium text-rose-800">
            Missing <code>TELLER_CONNECT_APPLICATION_ID</code> in environment.
          </p>
        ) : null}
        {!hasStripeConnectConfig ? (
          <p className="mt-2 font-medium text-rose-800">
            Missing Stripe Connect config. Set <code>STRIPE_CONNECT_CLIENT_ID</code> and{" "}
            <code>STRIPE_CONNECT_REDIRECT_URI</code> to enable Stripe linking.
          </p>
        ) : null}
        {!hasPlaidConfig ? (
          <p className="mt-2 font-medium text-rose-800">
            Missing Plaid config. Set <code>PLAID_CLIENT_ID</code> and <code>PLAID_SECRET</code>{" "}
            to enable Plaid linking.
          </p>
        ) : null}
      </section>

      <LinkBankClient csrfToken={csrfToken} tellerConfig={tellerConfig} />

      <Script
        id="teller-connect-script"
        nonce={cspNonce}
        src="https://cdn.teller.io/connect/connect.js"
        strategy="lazyOnload"
      />
      <Script
        id="plaid-link-script"
        nonce={cspNonce}
        src="https://cdn.plaid.com/link/v2/stable/link-initialize.js"
        strategy="lazyOnload"
      />
    </main>
  );
}
