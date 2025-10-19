'use client';

import React from "react";
import { Dialog, DialogBackdrop, DialogPanel, DialogTitle } from "@headlessui/react";
import { useCallback, useState } from "react";
import { WidgetEventLog, useWidgetEvents } from "../components/widget-flow";

type PersonaEnvironment = "sandbox" | "production";

type DialogComponents = {
  Dialog: typeof Dialog;
  DialogBackdrop: typeof DialogBackdrop;
  DialogPanel: typeof DialogPanel;
  DialogTitle: typeof DialogTitle;
};

const DEFAULT_DIALOG_COMPONENTS: DialogComponents = {
  Dialog,
  DialogBackdrop,
  DialogPanel,
  DialogTitle,
};

interface VerifyIdentityClientProps {
  csrfToken: string;
  components?: Partial<DialogComponents>;
}

interface SessionState {
  open: boolean;
  clientToken?: string;
  inquiryId?: string;
  environment: PersonaEnvironment;
}

const SESSION_ENDPOINT = "/api/kyc/session";

export default function VerifyIdentityClient({ csrfToken, components }: VerifyIdentityClientProps) {
  const { events, logEvent } = useWidgetEvents();
  const [session, setSession] = useState<SessionState>({ open: false, environment: "sandbox" });
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const {
    Dialog: DialogComponent,
    DialogBackdrop: DialogBackdropComponent,
    DialogPanel: DialogPanelComponent,
    DialogTitle: DialogTitleComponent,
  } = { ...DEFAULT_DIALOG_COMPONENTS, ...components } as DialogComponents;

  const startVerification = useCallback(async () => {
    setIsLoading(true);
    setError(null);

    logEvent("Requesting Persona session", {
      payload: { endpoint: SESSION_ENDPOINT },
    });

    try {
      const response = await fetch(SESSION_ENDPOINT, {
        method: "POST",
        credentials: "include",
        headers: {
          "content-type": "application/json",
          "x-csrf-token": csrfToken,
        },
        body: JSON.stringify({ environment: session.environment }),
      });
      const payload = (await response.json()) as Record<string, unknown>;

      if (!response.ok) {
        const message = (payload?.error as string | undefined) ?? "Failed to create verification session";
        setError(message);
        logEvent("Persona session error", { level: "error", payload });
        return;
      }

      const data = (payload?.data as Record<string, unknown> | undefined) ?? {};
      const clientToken = (data.client_token as string | undefined) ?? "";

      logEvent("Persona session ready", { level: "success", payload: data });
      setSession({
        open: true,
        environment: (data.environment as PersonaEnvironment | undefined) ?? "sandbox",
        inquiryId: data.inquiry_id as string | undefined,
        clientToken,
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : "Unknown error";
      setError(message);
      logEvent("Persona session crashed", { level: "error", payload: { message } });
    } finally {
      setIsLoading(false);
    }
  }, [csrfToken, logEvent, session.environment]);

  return (
    <div className="space-y-6">
      <article className="card space-y-4">
        <header className="space-y-1">
          <h2 className="text-xl font-semibold text-slate-900">Persona verification</h2>
          <p className="text-sm text-slate-600">
            The server-side endpoint mints a short lived session token and redacts sensitive
            applicant metadata before returning the payload to the client.
          </p>
        </header>
        <div className="flex flex-wrap items-center gap-4">
          <button
            type="button"
            className="btn"
            disabled={isLoading}
            onClick={startVerification}
            data-testid="launch-kyc"
          >
            {isLoading ? "Requesting session…" : "Start verification"}
          </button>
          <span className="text-xs text-slate-500">
            Phoenix automatically forwards cookies and the CSRF token header.
          </span>
        </div>
        {error ? (
          <p className="rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-700" data-testid="error-kyc">
            {error}
            <span className="block text-xs text-rose-500">
              Ensure the Phoenix endpoint can reach Persona and the CSRF token is still valid.
            </span>
          </p>
        ) : null}
      </article>

      <WidgetEventLog events={events} />

      <DialogComponent
        open={session.open}
        onClose={() => setSession((prev) => ({ ...prev, open: false }))}
        className="relative z-10"
      >
        <DialogBackdropComponent className="fixed inset-0 bg-slate-900/50" />
        <div className="fixed inset-0 overflow-y-auto">
          <div className="flex min-h-full items-center justify-center p-4">
            <DialogPanelComponent className="card w-full max-w-2xl space-y-4">
              <DialogTitleComponent className="text-xl font-semibold text-slate-900">Persona widget</DialogTitleComponent>
              <p className="text-sm text-slate-600">
                Client tokens never touch local storage. Persona receives them directly via iframe
                parameters.
              </p>
              <div className="aspect-[3/4] w-full overflow-hidden rounded-md border border-slate-200 bg-slate-50">
                {session.clientToken ? (
                  <iframe
                    title="Persona KYC"
                    className="h-full w-full"
                    src={`https://withpersona.com/embedded-inquiry?environment=${session.environment}&client-token=${encodeURIComponent(session.clientToken)}`}
                    allow="camera; microphone"
                    data-testid="kyc-frame"
                  />
                ) : null}
              </div>
              <button
                type="button"
                className="btn"
                onClick={() => setSession((prev) => ({ ...prev, open: false }))}
              >
                Close verification
              </button>
            </DialogPanelComponent>
          </div>
        </div>
      </DialogComponent>
    </div>
  );
}
