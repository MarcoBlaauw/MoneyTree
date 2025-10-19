import { headers } from "next/headers";
import Script from "next/script";
import LinkBankClient from "./link-bank-client";

export default function LinkBankPage() {
  const headerList = headers();
  const csrfToken = headerList.get("x-csrf-token") ?? "";
  const cspNonce = headerList.get("x-csp-nonce") ?? undefined;

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

      <LinkBankClient csrfToken={csrfToken} />

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
