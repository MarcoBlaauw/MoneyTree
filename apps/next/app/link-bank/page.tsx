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

      <LinkBankClient csrfToken={csrfToken} tellerConfig={tellerConfig} />

      <Script
        id="teller-connect-script"
        nonce={cspNonce}
        src="https://cdn.teller.io/connect/connect.js"
        strategy="afterInteractive"
      />
      <Script
        id="plaid-link-script"
        nonce={cspNonce}
        src="https://cdn.plaid.com/link/v2/stable/link-initialize.js"
        strategy="afterInteractive"
      />
    </main>
  );
}
