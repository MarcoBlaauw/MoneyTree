'use client';

import React from "react";
import { Dialog, DialogBackdrop, DialogPanel, DialogTitle, Tab, TabGroup, TabList, TabPanel, TabPanels } from "@headlessui/react";
import { useCallback, useEffect, useRef, useState } from "react";
import { WidgetEventLog, useWidgetEvents } from "../components/widget-flow";

type VendorId = "teller" | "plaid" | "stripe";

interface TellerConnectConfig {
  applicationId?: string;
  environment?: string;
}

type HeadlessComponents = {
  Dialog: typeof Dialog;
  DialogBackdrop: typeof DialogBackdrop;
  DialogPanel: typeof DialogPanel;
  DialogTitle: typeof DialogTitle;
  TabGroup: typeof TabGroup;
  TabList: typeof TabList;
  TabPanels: typeof TabPanels;
  TabPanel: typeof TabPanel;
  Tab: typeof Tab;
};

const DEFAULT_COMPONENTS: HeadlessComponents = {
  Dialog,
  DialogBackdrop,
  DialogPanel,
  DialogTitle,
  TabGroup,
  TabList,
  TabPanels,
  TabPanel,
  Tab,
};

interface VendorConfig {
  id: VendorId;
  name: string;
  description: string;
  cta: string;
  endpoint: string;
  requestBody: Record<string, unknown>;
  launchMode: "widget" | "redirect";
  frameUrl: (tokenPayload: Record<string, unknown>) => string;
  errorHint: string;
}

interface LinkBankClientProps {
  csrfToken: string;
  tellerConfig?: TellerConnectConfig;
  components?: Partial<HeadlessComponents>;
}

interface ModalState {
  open: boolean;
  vendor?: VendorConfig;
  payload?: Record<string, unknown>;
}

type TellerConnectSuccessEvent = Record<string, unknown>;
type TellerConnectExitEvent = Record<string, unknown> | undefined;

interface TellerConnectSetupOptions {
  applicationId?: string;
  environment?: string;
  connectToken?: string;
  products?: string[];
  onSuccess?: (event: TellerConnectSuccessEvent) => void | Promise<void>;
  onExit?: (event?: TellerConnectExitEvent) => void;
}

interface TellerConnectInstance {
  open(): void;
  destroy?(): void;
}

interface TellerConnectAPI {
  setup(options: TellerConnectSetupOptions): TellerConnectInstance;
}

interface PlaidInstitutionMetadata {
  institution_id?: string;
  name?: string;
}

interface PlaidLinkSuccessMetadata {
  institution?: PlaidInstitutionMetadata | null;
}

interface PlaidLinkExitMetadata {
  institution?: PlaidInstitutionMetadata | null;
}

interface PlaidLinkError {
  error_code?: string;
  error_message?: string;
  display_message?: string | null;
}

interface PlaidLinkCreateOptions {
  token: string;
  onSuccess?: (publicToken: string, metadata: PlaidLinkSuccessMetadata) => void | Promise<void>;
  onExit?: (error: PlaidLinkError | null, metadata: PlaidLinkExitMetadata) => void;
}

interface PlaidHandler {
  open(): void;
  destroy?(): void;
  exit?: (options?: { force?: boolean }, callback?: () => void) => void;
}

interface PlaidAPI {
  create(options: PlaidLinkCreateOptions): PlaidHandler;
}

declare global {
  interface Window {
    TellerConnect?: TellerConnectAPI;
    Plaid?: PlaidAPI;
  }
}

function asString(value: unknown): string | undefined {
  if (typeof value === "string") {
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : undefined;
  }
  return undefined;
}

function extractConnectToken(payload: Record<string, unknown> | undefined): string | undefined {
  if (!payload) {
    return undefined;
  }

  const candidates = [
    payload["connect_token"],
    payload["connectToken"],
    payload["token"],
  ];

  for (const candidate of candidates) {
    const token = asString(candidate);
    if (token) {
      return token;
    }
  }

  return undefined;
}

function maybeRecord(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" ? (value as Record<string, unknown>) : undefined;
}

function extractPublicToken(event: TellerConnectSuccessEvent): string | undefined {
  if (!event) {
    return undefined;
  }

  const record = maybeRecord(event);

  const candidates = [
    record?.["public_token"],
    record?.["publicToken"],
  ];

  for (const candidate of candidates) {
    const token = asString(candidate);
    if (token) {
      return token;
    }
  }

  return undefined;
}

function extractAccessToken(event: TellerConnectSuccessEvent): string | undefined {
  if (!event) {
    return undefined;
  }

  const record = maybeRecord(event);

  const candidates = [
    record?.["accessToken"],
    record?.["access_token"],
  ];

  for (const candidate of candidates) {
    const token = asString(candidate);
    if (token) {
      return token;
    }
  }

  return undefined;
}

function extractEnrollment(event: TellerConnectSuccessEvent): Record<string, unknown> | undefined {
  const record = maybeRecord(event);
  return maybeRecord(record?.["enrollment"]);
}

function extractEnrollmentId(event: TellerConnectSuccessEvent): string | undefined {
  return asString(extractEnrollment(event)?.["id"]);
}

function extractUserId(event: TellerConnectSuccessEvent): string | undefined {
  const record = maybeRecord(event);
  const user = maybeRecord(record?.["user"]);
  return asString(user?.["id"]);
}

function extractInstitutionName(event: TellerConnectSuccessEvent): string | undefined {
  const enrollment = extractEnrollment(event);
  const institution = maybeRecord(enrollment?.["institution"]);
  return asString(institution?.["name"]);
}

function collectTellerDiagnostics(payload: unknown): Record<string, string> {
  const root = maybeRecord(payload);
  if (!root) {
    return {};
  }

  const diagnostics: Record<string, string> = {};

  const read = (value: unknown) => asString(value);
  const enrollment = maybeRecord(root["enrollment"]);
  const account = maybeRecord(root["account"]);
  const institution = maybeRecord(enrollment?.["institution"]) ?? maybeRecord(root["institution"]);
  const error = maybeRecord(root["error"]) ?? maybeRecord(root["details"]);

  const push = (key: string, value: unknown) => {
    const normalized = read(value);
    if (normalized) {
      diagnostics[key] = normalized;
    }
  };

  push("user_id", maybeRecord(root["user"])?.["id"] ?? root["user_id"]);
  push("enrollment_id", enrollment?.["id"] ?? root["enrollment_id"]);
  push("account_id", account?.["id"] ?? root["account_id"]);
  push("institution_id", institution?.["id"] ?? root["institution_id"]);
  push("request_id", root["request_id"] ?? root["requestId"] ?? error?.["request_id"] ?? error?.["requestId"]);
  push("error_code", error?.["code"] ?? root["code"]);

  return diagnostics;
}

const VENDORS: VendorConfig[] = [
  {
    id: "teller",
    name: "Teller Connect",
    description:
      "Embeds Teller's secure OAuth experience for account aggregation and returns an access token on success.",
    cta: "Link with Teller",
    endpoint: "/api/teller/connect_token",
    requestBody: { institution: "demo" },
    launchMode: "widget",
    frameUrl: (payload) => {
      const token = (payload?.token as string | undefined) ?? "";
      const url = new URL("https://connect.teller.io/widget");
      if (token) {
        url.searchParams.set("token", token);
      }
      return url.toString();
    },
    errorHint: "Verify Teller application ID, environment, and certificate/key configuration.",
  },
  {
    id: "plaid",
    name: "Plaid Link",
    description:
      "Launches Plaid Link and exchanges the returned public token through Phoenix to keep secrets server-side.",
    cta: "Link with Plaid",
    endpoint: "/api/plaid/link_token",
    requestBody: { products: ["transactions"], client_name: "MoneyTree" },
    launchMode: "widget",
    frameUrl: (payload) => {
      const token = (payload?.link_token as string | undefined) ?? "";
      const url = new URL("https://link.plaid.com/?environment=sandbox");
      if (token) {
        url.searchParams.set("token", token);
      }
      return url.toString();
    },
    errorHint: "Verify the Plaid sandbox credentials and ensure the Phoenix session cookie is present.",
  },
  {
    id: "stripe",
    name: "Stripe Connect",
    description:
      "Starts Stripe Connect OAuth in a secure redirect flow. The session URL is generated server-side by Phoenix.",
    cta: "Link with Stripe",
    endpoint: "/api/stripe/session",
    requestBody: {},
    launchMode: "redirect",
    frameUrl: () => "",
    errorHint:
      "Verify STRIPE_CONNECT_CLIENT_ID and STRIPE_CONNECT_REDIRECT_URI are configured in the Phoenix environment.",
  },
];

function createFetchOptions(csrfToken: string, body: Record<string, unknown>): RequestInit {
  return {
    method: "POST",
    credentials: "include",
    headers: {
      "content-type": "application/json",
      "x-csrf-token": csrfToken,
    },
    body: JSON.stringify(body),
  } satisfies RequestInit;
}

async function parseResponsePayload(response: Response): Promise<Record<string, unknown>> {
  const contentType = response.headers.get("content-type") ?? "";

  if (contentType.toLowerCase().includes("application/json")) {
    const parsed = await response.json();
    return maybeRecord(parsed) ?? {};
  }

  const text = await response.text();

  return {
    error:
      text.trim().length > 0
        ? `Request failed with HTTP ${response.status}.`
        : `Request failed with HTTP ${response.status} and an empty response body.`,
  };
}

export default function LinkBankClient({ csrfToken, tellerConfig, components }: LinkBankClientProps) {
  const { events, logEvent } = useWidgetEvents();
  const [activeVendor, setActiveVendor] = useState<VendorId>("teller");
  const [modalState, setModalState] = useState<ModalState>({ open: false });
  const [errors, setErrors] = useState<Record<VendorId, string>>({
    teller: "",
    plaid: "",
    stripe: "",
  });
  const [loadingVendor, setLoadingVendor] = useState<VendorId | null>(null);
  const tellerConnectRef = useRef<TellerConnectInstance | null>(null);
  const plaidRef = useRef<PlaidHandler | null>(null);
  const tellerApplicationId = tellerConfig?.applicationId;
  const tellerEnvironment = tellerConfig?.environment ?? "sandbox";

  const {
    Dialog: DialogComponent,
    DialogBackdrop: DialogBackdropComponent,
    DialogPanel: DialogPanelComponent,
    DialogTitle: DialogTitleComponent,
    TabGroup: TabGroupComponent,
    TabList: TabListComponent,
    TabPanels: TabPanelsComponent,
    TabPanel: TabPanelComponent,
    Tab: TabComponent,
  } = { ...DEFAULT_COMPONENTS, ...components } as HeadlessComponents;

  const handleTellerSuccess = useCallback(
    async (event: TellerConnectSuccessEvent) => {
      setErrors((prev) => ({ ...prev, teller: "" }));
      logEvent("Teller Connect completed", { level: "success", payload: event });
      const completionDiagnostics = collectTellerDiagnostics(event);
      if (Object.keys(completionDiagnostics).length > 0) {
        logEvent("Teller diagnostic identifiers", {
          level: "info",
          payload: completionDiagnostics,
        });
      }

      const publicToken = extractPublicToken(event);
      const accessToken = extractAccessToken(event);

      if (!publicToken && !accessToken) {
        setErrors((prev) => ({
          ...prev,
          teller: "Teller Connect did not return a usable token.",
        }));
        logEvent("Teller Connect response missing usable token", {
          level: "error",
          payload: event,
        });
        return;
      }

      const enrollment = maybeRecord(event["enrollment"]);
      const institution = maybeRecord(enrollment?.["institution"]);

      const exchangeBody: Record<string, unknown> = {};

      if (publicToken) {
        exchangeBody.public_token = publicToken;
      }

      if (accessToken) {
        exchangeBody.access_token = accessToken;
      }

      const enrollmentId = extractEnrollmentId(event);
      if (enrollmentId) {
        exchangeBody.enrollment_id = enrollmentId;
      }

      const userId = extractUserId(event);
      if (userId) {
        exchangeBody.user_id = userId;
      }

      const institutionId = institution ? asString(institution["id"]) : undefined;
      if (institutionId) {
        exchangeBody.institution_id = institutionId;
      }

      const institutionName = institution ? asString(institution["name"]) : undefined;
      if (institutionName) {
        exchangeBody.institution_name = institutionName;
      }

      try {
        const response = await fetch("/api/teller/exchange", createFetchOptions(csrfToken, exchangeBody));
        const payload = (await response.json()) as Record<string, unknown>;

        if (!response.ok) {
          const message = asString(payload?.["error"]) ?? "Failed to exchange Teller token.";
          setErrors((prev) => ({ ...prev, teller: message }));
          logEvent("Teller exchange failed", { level: "error", payload });
          return;
        }

        logEvent("Teller exchange succeeded", { level: "success", payload });
      } catch (error) {
        const message = error instanceof Error ? error.message : "Unknown error";
        setErrors((prev) => ({ ...prev, teller: message }));
        logEvent("Teller exchange crashed", { level: "error", payload: { message } });
      } finally {
        if (tellerConnectRef.current?.destroy) {
          try {
            tellerConnectRef.current.destroy();
          } catch {
            // ignore destroy errors
          }
        }
        tellerConnectRef.current = null;
      }
    },
    [csrfToken, logEvent],
  );

  useEffect(
    () => () => {
      if (tellerConnectRef.current?.destroy) {
        try {
          tellerConnectRef.current.destroy();
        } catch {
          // ignore destroy errors
        }
      }
      tellerConnectRef.current = null;

      if (plaidRef.current?.destroy) {
        try {
          plaidRef.current.destroy();
        } catch {
          // ignore destroy errors
        }
      }
      plaidRef.current = null;
    },
    [],
  );

  const launchTellerConnect = useCallback(
    (connectToken?: string) => {
      const api = typeof window === "undefined" ? undefined : window.TellerConnect;

      if (!api?.setup) {
        setErrors((prev) => ({
          ...prev,
          teller: "Teller Connect script is not available.",
        }));
        logEvent("Teller Connect unavailable", {
          level: "error",
          payload: { reason: "missing_script" },
        });
        return false;
      }

      if (tellerConnectRef.current?.destroy) {
        try {
          tellerConnectRef.current.destroy();
        } catch {
          // ignore stale destroy errors
        }
      }

      const normalizedConnectToken = asString(connectToken);
      const commonSetupOptions: Omit<TellerConnectSetupOptions, "connectToken"> = {
        applicationId: tellerApplicationId,
        environment: tellerEnvironment,
        products: ["verify", "balance", "transactions", "identity"],
        onSuccess: async (event) => {
          await handleTellerSuccess(event);
        },
        onExit: (event) => {
          logEvent("Teller Connect closed", { level: "info", payload: event ?? {} });
          const diagnostics = collectTellerDiagnostics(event);
          if (Object.keys(diagnostics).length > 0) {
            logEvent("Teller diagnostic identifiers", {
              level: "info",
              payload: diagnostics,
            });
          }
          tellerConnectRef.current = null;
        },
      };

      const setupOptions: TellerConnectSetupOptions = normalizedConnectToken
        ? { ...commonSetupOptions, connectToken: normalizedConnectToken }
        : commonSetupOptions;

      const instance = api.setup(setupOptions);

      tellerConnectRef.current = instance;

      logEvent("Teller Connect opening", {
        level: "info",
        payload: { hasConnectKey: "connectToken" in setupOptions, environment: tellerEnvironment },
      });

      instance.open();

      return true;
    },
    [handleTellerSuccess, logEvent, tellerApplicationId, tellerEnvironment],
  );

  const requestWidget = useCallback(
    async (vendor: VendorConfig) => {
      setLoadingVendor(vendor.id);
      setErrors((prev) => ({ ...prev, [vendor.id]: "" }));

      try {
        if (vendor.id === "teller") {
          logEvent("Opening Teller Connect", {
            level: "info",
            payload: { applicationId: tellerApplicationId, environment: tellerEnvironment },
          });
          launchTellerConnect();
          return;
        }

        logEvent(`Requesting ${vendor.name} token`, {
          level: "info",
          payload: { endpoint: vendor.endpoint, body: vendor.requestBody },
        });

        const response = await fetch(vendor.endpoint, createFetchOptions(csrfToken, vendor.requestBody));
        const payload = await parseResponsePayload(response);

        if (!response.ok) {
          const errorMessage = (payload?.error as string | undefined) ?? "Widget initialization failed";
          setErrors((prev) => ({ ...prev, [vendor.id]: errorMessage }));
          logEvent(`${vendor.name} failed`, { level: "error", payload });
          return;
        }

        const data = (payload?.data as Record<string, unknown> | undefined) ?? {};

        logEvent(`${vendor.name} ready`, { level: "success", payload: data });

        if (vendor.id === "teller") {
          const connectToken = extractConnectToken(data);

          if (!connectToken) {
            setErrors((prev) => ({
              ...prev,
              teller: "Teller Connect response did not include a token.",
            }));
            logEvent("Teller Connect missing token", { level: "error", payload: data });
            return;
          }

          setModalState({ open: false });
          launchTellerConnect(connectToken);
          return;
        }

        if (vendor.launchMode === "redirect") {
          const redirectUrl = asString(data.url);

          if (!redirectUrl) {
            setErrors((prev) => ({
              ...prev,
              [vendor.id]: "Redirect URL missing from Stripe session response.",
            }));
            logEvent("Stripe session missing redirect URL", { level: "error", payload: data });
            return;
          }

          logEvent("Redirecting to Stripe Connect", {
            level: "info",
            payload: { url: redirectUrl, state: data.state },
          });

          window.open(redirectUrl, "_self");
          return;
        }

        if (vendor.id === "plaid") {
          const linkToken = asString(data.link_token) ?? asString(data.linkToken);

          if (!linkToken) {
            setErrors((prev) => ({
              ...prev,
              plaid: "Plaid response did not include a link token.",
            }));
            logEvent("Plaid token response missing link token", { level: "error", payload: data });
            return;
          }

          const plaidApi = typeof window === "undefined" ? undefined : window.Plaid;
          if (!plaidApi?.create) {
            setErrors((prev) => ({
              ...prev,
              plaid: "Plaid Link script is not available.",
            }));
            logEvent("Plaid Link unavailable", {
              level: "error",
              payload: { reason: "missing_script" },
            });
            return;
          }

          if (plaidRef.current?.destroy) {
            try {
              plaidRef.current.destroy();
            } catch {
              // ignore stale destroy errors
            }
          }

          const handler = plaidApi.create({
            token: linkToken,
            onSuccess: async (publicToken, metadata) => {
              setErrors((prev) => ({ ...prev, plaid: "" }));
              logEvent("Plaid Link completed", { level: "success", payload: metadata ?? {} });

              const institutionName = asString(metadata?.institution?.name);
              const exchangeBody: Record<string, unknown> = { public_token: publicToken };
              if (institutionName) {
                exchangeBody.institution_name = institutionName;
              }

              try {
                const exchangeResponse = await fetch("/api/plaid/exchange", createFetchOptions(csrfToken, exchangeBody));
                const exchangePayload = await parseResponsePayload(exchangeResponse);

                if (!exchangeResponse.ok) {
                  const message =
                    asString(exchangePayload.error) ?? "Failed to exchange Plaid public token.";
                  setErrors((prev) => ({ ...prev, plaid: message }));
                  logEvent("Plaid exchange failed", { level: "error", payload: exchangePayload });
                  return;
                }

                logEvent("Plaid exchange succeeded", { level: "success", payload: exchangePayload });
              } catch (error) {
                const message = error instanceof Error ? error.message : "Unknown error";
                setErrors((prev) => ({ ...prev, plaid: message }));
                logEvent("Plaid exchange crashed", { level: "error", payload: { message } });
              }
            },
            onExit: (error, metadata) => {
              if (error?.display_message || error?.error_message) {
                const message = error.display_message ?? error.error_message ?? "Plaid Link exited with an error.";
                setErrors((prev) => ({ ...prev, plaid: message }));
              }

              logEvent("Plaid Link closed", {
                level: error ? "error" : "info",
                payload: { error: error ?? {}, metadata: metadata ?? {} },
              });
            },
          });

          plaidRef.current = handler;
          logEvent("Opening Plaid Link", { level: "info", payload: { hasLinkToken: true } });
          handler.open();
          return;
        }

        setModalState({ open: true, vendor, payload: data });
      } catch (error) {
        const message = error instanceof Error ? error.message : "Unknown error";
        setErrors((prev) => ({ ...prev, [vendor.id]: message }));
        logEvent(`${vendor.name} crashed`, { level: "error", payload: { message } });
      } finally {
        setLoadingVendor(null);
      }
    },
    [csrfToken, launchTellerConnect, logEvent, tellerApplicationId, tellerEnvironment],
  );

  return (
    <>
      <TabGroupComponent
        selectedIndex={VENDORS.findIndex((vendor) => vendor.id === activeVendor)}
        onChange={(index) => setActiveVendor(VENDORS[index]?.id ?? "teller")}
      >
        <TabListComponent className="flex gap-2">
          {VENDORS.map((vendor) => (
            <TabComponent
              key={vendor.id}
              className={({ selected }) =>
                `btn ${selected ? "bg-primary text-primary-foreground" : "btn-ghost"}`
              }
            >
              {vendor.name}
            </TabComponent>
          ))}
        </TabListComponent>
        <TabPanelsComponent className="mt-6">
          {VENDORS.map((vendor) => (
            <TabPanelComponent key={vendor.id} className="focus:outline-none">
              <article className="card space-y-4" data-testid={`vendor-${vendor.id}`}>
                <header className="space-y-1">
                  <h2 className="text-xl font-semibold text-slate-900">{vendor.name}</h2>
                  <p className="text-sm text-slate-600">{vendor.description}</p>
                </header>
                <div className="flex flex-wrap items-center gap-4">
                  <button
                    type="button"
                    className="btn"
                    disabled={loadingVendor === vendor.id}
                    onClick={() => requestWidget(vendor)}
                    data-testid={`launch-${vendor.id}`}
                  >
                    {loadingVendor === vendor.id ? "Requesting token…" : vendor.cta}
                  </button>
                  <span className="text-xs text-slate-500">
                    Phoenix forwards cookies and the CSRF header automatically.
                  </span>
                </div>
                {errors[vendor.id] ? (
                  <p className="rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-700" data-testid={`error-${vendor.id}`}>
                    {errors[vendor.id]}
                    <span className="block text-xs text-rose-500">{vendor.errorHint}</span>
                  </p>
                ) : null}
              </article>
            </TabPanelComponent>
          ))}
        </TabPanelsComponent>
      </TabGroupComponent>

      <WidgetEventLog events={events} />

      <DialogComponent
        open={modalState.open}
        onClose={() => setModalState({ open: false })}
        className="relative z-10"
      >
        <DialogBackdropComponent className="fixed inset-0 bg-slate-900/50" />
        <div className="fixed inset-0 overflow-y-auto">
          <div className="flex min-h-full items-center justify-center p-4">
            <DialogPanelComponent className="card w-full max-w-3xl space-y-4">
              <DialogTitleComponent className="text-xl font-semibold text-slate-900">
                {modalState.vendor?.name ?? "Widget"}
              </DialogTitleComponent>
              <p className="text-sm text-slate-600">
                The vendor iframe receives the server issued token. Sensitive fields in the
                captured payload are redacted before rendering in the event log.
              </p>
              <div className="aspect-[4/3] w-full overflow-hidden rounded-md border border-slate-200 bg-slate-50">
                {modalState.vendor && modalState.payload ? (
                  <iframe
                    title={`${modalState.vendor.name} iframe`}
                    src={modalState.vendor.frameUrl(modalState.payload)}
                    className="h-full w-full"
                    allow="clipboard-write; payment"
                    data-testid="widget-frame"
                  />
                ) : null}
              </div>
              <button type="button" className="btn" onClick={() => setModalState({ open: false })}>
                Close widget
              </button>
            </DialogPanelComponent>
          </div>
        </div>
      </DialogComponent>
    </>
  );
}
