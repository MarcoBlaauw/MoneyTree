'use client';

import React from "react";
import { Dialog, DialogBackdrop, DialogPanel, DialogTitle, Tab, TabGroup, TabList, TabPanel, TabPanels } from "@headlessui/react";
import { useCallback, useState } from "react";
import { WidgetEventLog, useWidgetEvents } from "../components/widget-flow";

type VendorId = "teller" | "plaid";

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
  frameUrl: (tokenPayload: Record<string, unknown>) => string;
  errorHint: string;
}

interface LinkBankClientProps {
  csrfToken: string;
  components?: Partial<HeadlessComponents>;
}

interface ModalState {
  open: boolean;
  vendor?: VendorConfig;
  payload?: Record<string, unknown>;
}

const VENDORS: VendorConfig[] = [
  {
    id: "teller",
    name: "Teller Connect",
    description:
      "Embeds Teller's secure OAuth experience for account aggregation. The Connect token is generated server-side.",
    cta: "Link with Teller",
    endpoint: "/api/teller/connect_token",
    requestBody: { institution: "demo" },
    frameUrl: (payload) => {
      const token = (payload?.token as string | undefined) ?? "";
      const url = new URL("https://connect.teller.io/widget");
      if (token) {
        url.searchParams.set("token", token);
      }
      return url.toString();
    },
    errorHint: "Request a new Connect token in the Teller dashboard and ensure the Phoenix proxy forwards cookies.",
  },
  {
    id: "plaid",
    name: "Plaid Link",
    description:
      "Launches Plaid Link in update mode. Link tokens are generated through the Phoenix API to keep secrets server-side.",
    cta: "Link with Plaid",
    endpoint: "/api/plaid/link_token",
    requestBody: { products: ["auth"], client_name: "MoneyTree Demo" },
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

export default function LinkBankClient({ csrfToken, components }: LinkBankClientProps) {
  const { events, logEvent } = useWidgetEvents();
  const [activeVendor, setActiveVendor] = useState<VendorId>("teller");
  const [modalState, setModalState] = useState<ModalState>({ open: false });
  const [errors, setErrors] = useState<Record<VendorId, string>>({ teller: "", plaid: "" });
  const [loadingVendor, setLoadingVendor] = useState<VendorId | null>(null);

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

  const requestWidget = useCallback(
    async (vendor: VendorConfig) => {
      setLoadingVendor(vendor.id);
      setErrors((prev) => ({ ...prev, [vendor.id]: "" }));

      logEvent(`Requesting ${vendor.name} token`, {
        level: "info",
        payload: { endpoint: vendor.endpoint, body: vendor.requestBody },
      });

      try {
        const response = await fetch(vendor.endpoint, createFetchOptions(csrfToken, vendor.requestBody));
        const payload = (await response.json()) as Record<string, unknown>;

        if (!response.ok) {
          const errorMessage = (payload?.error as string | undefined) ?? "Widget initialization failed";
          setErrors((prev) => ({ ...prev, [vendor.id]: errorMessage }));
          logEvent(`${vendor.name} failed`, { level: "error", payload });
          return;
        }

        const data = (payload?.data as Record<string, unknown> | undefined) ?? {};

        logEvent(`${vendor.name} ready`, { level: "success", payload: data });
        setModalState({ open: true, vendor, payload: data });
      } catch (error) {
        const message = error instanceof Error ? error.message : "Unknown error";
        setErrors((prev) => ({ ...prev, [vendor.id]: message }));
        logEvent(`${vendor.name} crashed`, { level: "error", payload: { message } });
      } finally {
        setLoadingVendor(null);
      }
    },
    [csrfToken, logEvent],
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
