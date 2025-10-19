import { headers } from "next/headers";
import Script from "next/script";
import VerifyIdentityClient from "./verify-identity-client";

export default function VerifyIdentityPage() {
  const headerList = headers();
  const csrfToken = headerList.get("x-csrf-token") ?? "";
  const cspNonce = headerList.get("x-csp-nonce") ?? undefined;

  return (
    <main className="mx-auto flex w-full max-w-4xl flex-col gap-8 px-6 py-12">
      <section className="space-y-4">
        <h1 className="text-3xl font-semibold text-slate-900">Verify customer identity</h1>
        <p className="text-base text-slate-600">
          Use the Persona-hosted KYC flow without exposing API keys to the browser. The
          verification session is minted by Phoenix and hydrated into the widget iframe.
        </p>
      </section>

      <VerifyIdentityClient csrfToken={csrfToken} />

      <Script
        id="persona-sdk"
        nonce={cspNonce}
        src="https://withpersona.com/static/persona-v3.js"
        strategy="afterInteractive"
      />
    </main>
  );
}
