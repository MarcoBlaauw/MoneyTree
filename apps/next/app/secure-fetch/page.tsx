import { headers } from "next/headers";
import Script from "next/script";

const SCRIPT_ID = "secure-fetch-handler";

export default async function SecureFetchPage() {
  const headerList = await headers();
  const nonce = headerList.get("x-csp-nonce") ?? undefined;
  const csrfToken = headerList.get("x-csrf-token") ?? "";
  const csrfLiteral = JSON.stringify(csrfToken);

  return (
    <main className="max-w-2xl mx-auto py-10 space-y-6">
      <h1 className="text-2xl font-semibold">Secure fetch demo</h1>
      <p>
        Use the button below to perform a credentialed fetch request. The Playwright
        integration test asserts that cookies and security headers are forwarded
        correctly through the Phoenix proxy.
      </p>
      <button
        id="trigger-secure-fetch"
        className="inline-flex items-center rounded border border-current px-4 py-2 text-sm font-medium"
        type="button"
      >
        Run secure fetch
      </button>
      <Script id={SCRIPT_ID} nonce={nonce} strategy="afterInteractive">
        {`
          (() => {
            const button = document.getElementById("trigger-secure-fetch");
            if (!button) return;

            button.addEventListener("click", async () => {
              const response = await fetch("/api/mock-auth", {
                credentials: "include",
                headers: { "x-csrf-token": ${csrfLiteral} },
              });

              window.__moneytree_last_fetch_status = response.status;
            });
          })();
        `}
      </Script>
    </main>
  );
}
