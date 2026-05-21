'use client';

import React from "react";
import { Dialog, DialogBackdrop, DialogPanel, DialogTitle, Tab, TabGroup, TabList, TabPanel, TabPanels } from "@headlessui/react";
import { useCallback, useEffect, useRef, useState } from "react";
import { useWidgetEvents } from "../components/widget-flow";

type VendorId = "teller" | "plaid";

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
const DEFAULT_ENABLED_PROVIDERS = ["simplefin", "manual"];

interface VendorConfig {
  id: VendorId;
  name: string;
  description: string;
  cta: string;
  endpoint: string;
  requestBody: Record<string, unknown>;
  launchMode: "widget";
  frameUrl: (tokenPayload: Record<string, unknown>) => string;
  errorHint: string;
}

interface LinkBankClientProps {
  csrfToken: string;
  tellerConfig?: TellerConnectConfig;
  enabledProviders?: string[];
  simplefinCreateUrl?: string;
  components?: Partial<HeadlessComponents>;
}

interface ModalState {
  open: boolean;
  vendor?: VendorConfig;
  payload?: Record<string, unknown>;
}

interface SimpleFinAccount {
  id?: string;
  name?: string;
  currency?: string;
  balance?: string;
  available_balance?: string;
}

interface SimpleFinConnection {
  id: string;
  provider?: string;
  institution_name?: string;
  account_count?: number;
  status?: string;
  last_synced_at?: string | null;
  last_sync_error?: unknown;
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

function createJsonFetchOptions(csrfToken: string, method = "GET", body?: Record<string, unknown>): RequestInit {
  const options: RequestInit = {
    method,
    credentials: "include",
    headers: {
      "content-type": "application/json",
      "x-csrf-token": csrfToken,
    },
  };

  if (body) {
    options.body = JSON.stringify(body);
  }

  return options;
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

function formatConnectionDate(value: string | null | undefined): string {
  if (!value) {
    return "Not synced yet";
  }

  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return "Unknown";
  }

  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(date);
}

export default function LinkBankClient({
  csrfToken,
  tellerConfig,
  enabledProviders = DEFAULT_ENABLED_PROVIDERS,
  simplefinCreateUrl = "https://bridge.simplefin.org/simplefin/create",
  components,
}: LinkBankClientProps) {
  const { logEvent } = useWidgetEvents();
  const legacyVendors = VENDORS.filter((vendor) => enabledProviders.includes(vendor.id));
  const [activeVendor, setActiveVendor] = useState<VendorId>(legacyVendors[0]?.id ?? "teller");
  const [modalState, setModalState] = useState<ModalState>({ open: false });
  const [errors, setErrors] = useState<Record<VendorId, string>>({
    teller: "",
    plaid: "",
  });
  const [loadingVendor, setLoadingVendor] = useState<VendorId | null>(null);
  const [setupToken, setSetupToken] = useState("");
  const [simplefinLoading, setSimplefinLoading] = useState(false);
  const [simplefinError, setSimplefinError] = useState("");
  const [simplefinProviderErrors, setSimplefinProviderErrors] = useState<string[]>([]);
  const [simplefinAccounts, setSimplefinAccounts] = useState<SimpleFinAccount[]>([]);
  const [simplefinConnections, setSimplefinConnections] = useState<SimpleFinConnection[]>([]);
  const [connectionsLoading, setConnectionsLoading] = useState(false);
  const [connectionActionId, setConnectionActionId] = useState<string | null>(null);
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

  const loadSimpleFinConnections = useCallback(async () => {
    setConnectionsLoading(true);

    try {
      const response = await fetch("/api/simplefin/connections", createJsonFetchOptions(csrfToken));
      const payload = await parseResponsePayload(response);

      if (!response.ok) {
        setSimplefinError(asString(payload.error) ?? "Unable to load existing SimpleFIN connections.");
        return;
      }

      const data = maybeRecord(payload.data) ?? {};
      const connections = Array.isArray(data.connections)
        ? (data.connections as SimpleFinConnection[])
        : [];
      setSimplefinConnections(connections);
    } catch (error) {
      setSimplefinError(error instanceof Error ? error.message : "Unable to load existing SimpleFIN connections.");
    } finally {
      setConnectionsLoading(false);
    }
  }, [csrfToken]);

  useEffect(() => {
    if (enabledProviders.includes("simplefin")) {
      void loadSimpleFinConnections();
    }
  }, [enabledProviders, loadSimpleFinConnections]);

  const refreshSimpleFinConnection = useCallback(
    async (connectionId: string) => {
      setConnectionActionId(connectionId);
      setSimplefinError("");

      try {
        const response = await fetch(
          "/api/simplefin/sync",
          createFetchOptions(csrfToken, { connection_id: connectionId }),
        );
        const payload = await parseResponsePayload(response);

        if (!response.ok) {
          setSimplefinError(asString(payload.error) ?? "Unable to refresh this connection.");
          return;
        }

        logEvent("SimpleFIN refresh scheduled", { level: "success", payload: maybeRecord(payload.data) ?? {} });
        await loadSimpleFinConnections();
      } catch (error) {
        setSimplefinError(error instanceof Error ? error.message : "Unable to refresh this connection.");
      } finally {
        setConnectionActionId(null);
      }
    },
    [csrfToken, loadSimpleFinConnections, logEvent],
  );

  const revokeSimpleFinConnection = useCallback(
    async (connectionId: string) => {
      if (!window.confirm("Disconnect this institution from MoneyTree?")) {
        return;
      }

      setConnectionActionId(connectionId);
      setSimplefinError("");

      try {
        const response = await fetch(
          `/api/simplefin/connections/${connectionId}`,
          createJsonFetchOptions(csrfToken, "DELETE"),
        );
        const payload = await parseResponsePayload(response);

        if (!response.ok) {
          setSimplefinError(asString(payload.error) ?? "Unable to revoke this connection.");
          return;
        }

        logEvent("SimpleFIN connection revoked", { level: "success", payload: maybeRecord(payload.data) ?? {} });
        await loadSimpleFinConnections();
      } catch (error) {
        setSimplefinError(error instanceof Error ? error.message : "Unable to revoke this connection.");
      } finally {
        setConnectionActionId(null);
      }
    },
    [csrfToken, loadSimpleFinConnections, logEvent],
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

  const claimSimpleFinToken = useCallback(async () => {
    setSimplefinLoading(true);
    setSimplefinError("");
    setSimplefinProviderErrors([]);
    setSimplefinAccounts([]);

    try {
      const response = await fetch("/api/simplefin/claim", createFetchOptions(csrfToken, { setup_token: setupToken }));
      const payload = await parseResponsePayload(response);

      if (!response.ok) {
        setSimplefinError(asString(payload.error) ?? "SimpleFIN setup failed.");
        logEvent("SimpleFIN claim failed", { level: "error", payload });
        return;
      }

      const data = maybeRecord(payload.data) ?? {};
      const accounts = Array.isArray(data.accounts) ? (data.accounts as SimpleFinAccount[]) : [];
      const providerErrors = Array.isArray(data.errors)
        ? data.errors
            .map((error) => maybeRecord(error)?.msg)
            .map(asString)
            .filter((message): message is string => Boolean(message))
        : [];
      setSimplefinAccounts(accounts);
      setSimplefinProviderErrors(providerErrors);
      setSetupToken("");
      logEvent("SimpleFIN connection claimed", {
        level: "success",
        payload: {
          connection_id: data.connection_id,
          institution_id: data.institution_id,
          accounts: accounts.length,
          provider_errors: providerErrors.length,
        },
      });
      await loadSimpleFinConnections();
    } catch (error) {
      const message = error instanceof Error ? error.message : "Unknown error";
      setSimplefinError(message);
      logEvent("SimpleFIN claim crashed", { level: "error", payload: { message } });
    } finally {
      setSimplefinLoading(false);
    }
  }, [csrfToken, loadSimpleFinConnections, logEvent, setupToken]);

  return (
    <>
      {enabledProviders.includes("simplefin") ? (
        <section className="space-y-4 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <header className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <h2 className="text-lg font-semibold text-zinc-900">Existing connections</h2>
              <p className="text-sm text-zinc-500">
                Active SimpleFIN Bridge connections and current sync state.
              </p>
            </div>
            <button
              type="button"
              className="btn btn-outline"
              disabled={connectionsLoading}
              onClick={() => void loadSimpleFinConnections()}
            >
              {connectionsLoading ? "Loading..." : "Reload"}
            </button>
          </header>

          {simplefinConnections.length > 0 ? (
            <div className="grid gap-3">
              {simplefinConnections.map((connection) => (
                <div
                  key={connection.id}
                  className="flex flex-col gap-3 rounded-lg border border-zinc-200 bg-zinc-50 px-4 py-3 sm:flex-row sm:items-center sm:justify-between"
                >
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <p className="font-semibold text-zinc-900">
                        {connection.institution_name ?? "SimpleFIN Bridge"}
                      </p>
                      <span
                        className={
                          connection.status === "needs_attention"
                            ? "rounded-full bg-amber-100 px-2 py-0.5 text-[11px] font-semibold uppercase tracking-wide text-amber-700"
                            : "rounded-full bg-emerald-100 px-2 py-0.5 text-[11px] font-semibold uppercase tracking-wide text-emerald-700"
                        }
                      >
                        {connection.status === "needs_attention" ? "Needs attention" : "Connected"}
                      </span>
                    </div>
                    <p className="mt-1 text-xs uppercase tracking-wide text-zinc-500">
                      {connection.provider ?? "simplefin"} connection • {connection.account_count ?? 0} accounts
                    </p>
                    <p className="mt-1 text-sm text-zinc-500">
                      Last synced {formatConnectionDate(connection.last_synced_at)}
                    </p>
                  </div>
                  <div className="flex shrink-0 flex-wrap gap-2">
                    <button
                      type="button"
                      className="btn btn-outline"
                      disabled={connectionActionId === connection.id}
                      onClick={() => void refreshSimpleFinConnection(connection.id)}
                    >
                      {connectionActionId === connection.id ? "Working..." : "Refresh"}
                    </button>
                    <button
                      type="button"
                      className="btn btn-ghost text-rose-600"
                      disabled={connectionActionId === connection.id}
                      onClick={() => void revokeSimpleFinConnection(connection.id)}
                    >
                      Revoke
                    </button>
                  </div>
                </div>
              ))}
            </div>
          ) : (
            <div className="rounded-lg border border-dashed border-zinc-200 px-4 py-6 text-center text-sm text-zinc-500">
              {connectionsLoading ? "Loading connections..." : "No SimpleFIN connections are active yet."}
            </div>
          )}
        </section>
      ) : null}

      {enabledProviders.includes("simplefin") ? (
        <section className="space-y-5 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm">
          <header className="space-y-1">
            <h2 className="text-lg font-semibold text-zinc-900">SimpleFIN Bridge</h2>
            <p className="text-sm text-zinc-500">
              SimpleFIN Bridge lets you connect read-only financial data to MoneyTree using a setup token.
              Create the token in SimpleFIN, paste it here, and MoneyTree will import balances and transactions.
            </p>
          </header>
          <div className="flex flex-wrap items-center gap-3">
            <a
              className="btn"
              href={simplefinCreateUrl}
              target="_blank"
              rel="noreferrer"
            >
              Create SimpleFIN token
            </a>
            <span className="text-xs text-zinc-500">MoneyTree never sees your bank credentials.</span>
          </div>
          <div className="grid gap-3 md:grid-cols-[1fr_auto]">
            <label className="space-y-1">
              <span className="text-sm font-medium text-zinc-700">Setup token</span>
              <textarea
                className="min-h-24 w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 shadow-sm placeholder:text-zinc-400"
                value={setupToken}
                onChange={(event) => setSetupToken(event.target.value)}
                onInput={(event) => setSetupToken(event.currentTarget.value)}
                placeholder="Paste the one-time SimpleFIN setup token"
              />
            </label>
            <button
              type="button"
              className="btn self-end"
              disabled={simplefinLoading || setupToken.trim().length === 0}
              onClick={claimSimpleFinToken}
            >
              {simplefinLoading ? "Connecting..." : "Connect"}
            </button>
          </div>
          {simplefinError ? (
            <p className="rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-700">
              {simplefinError}
            </p>
          ) : null}
          {simplefinProviderErrors.length > 0 ? (
            <div className="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900">
              <p className="font-medium">Connected, with SimpleFIN items needing attention</p>
              <ul className="mt-2 list-disc space-y-1 pl-5">
                {simplefinProviderErrors.map((message) => (
                  <li key={message}>{message}</li>
                ))}
              </ul>
            </div>
          ) : null}
          {simplefinAccounts.length > 0 ? (
            <div className="space-y-2">
              <h3 className="text-sm font-semibold text-zinc-800">Discovered accounts</h3>
              <div className="grid gap-2">
                {simplefinAccounts.map((account) => (
                  <div key={account.id ?? account.name} className="rounded-md border border-zinc-200 px-3 py-2 text-sm">
                    <div className="font-medium text-zinc-900">{account.name ?? "Account"}</div>
                    <div className="text-zinc-500">
                      {[account.currency, account.balance ? `Balance ${account.balance}` : undefined]
                        .filter(Boolean)
                        .join(" · ")}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          ) : null}
        </section>
      ) : null}

      {legacyVendors.length > 0 ? (
        <TabGroupComponent
        selectedIndex={Math.max(legacyVendors.findIndex((vendor) => vendor.id === activeVendor), 0)}
        onChange={(index) => setActiveVendor(legacyVendors[index]?.id ?? legacyVendors[0]?.id ?? "teller")}
        >
        <TabListComponent className="flex gap-2">
          {legacyVendors.map((vendor) => (
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
          {legacyVendors.map((vendor) => (
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
      ) : null}

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
