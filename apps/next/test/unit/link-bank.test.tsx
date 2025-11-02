import { afterEach, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import React, { type ButtonHTMLAttributes, type HTMLAttributes } from "react";
import { render, fireEvent, waitFor } from "@testing-library/react";
import LinkBankClient from "../../app/link-bank/link-bank-client";
import { setupDom } from "../helpers/setup-dom";

const CSRF_TOKEN = "csrf-token";

function createFetchResponse(status: number, body: Record<string, unknown>) {
  return Promise.resolve(
    new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    }),
  );
}

type DivProps = HTMLAttributes<HTMLDivElement>;
type TabStubProps = {
  children?: React.ReactNode | ((args: { selected: boolean }) => React.ReactNode);
  className?: string | ((args: { selected: boolean }) => string);
} & ButtonHTMLAttributes<HTMLButtonElement>;

const headlessStubs = {
  Dialog: ({ open, children }: { open: boolean; children?: React.ReactNode }) => (open ? <div>{children}</div> : null),
  DialogBackdrop: ({ children }: { children?: React.ReactNode }) => <div>{children}</div>,
  DialogPanel: ({ children, ...rest }: DivProps) => <div {...rest}>{children}</div>,
  DialogTitle: ({ children, ...rest }: DivProps) => <div {...rest}>{children}</div>,
  TabGroup: ({ children }: { children?: React.ReactNode }) => <div>{children}</div>,
  TabList: ({ children }: { children?: React.ReactNode }) => <div>{children}</div>,
  TabPanels: ({ children }: { children?: React.ReactNode }) => <div>{children}</div>,
  TabPanel: ({ children }: { children?: React.ReactNode }) => <div>{children}</div>,
  Tab: ({ children, className, ...rest }: TabStubProps) => {
    const resolvedClassName =
      typeof className === "function" ? className({ selected: false }) : className;
    const content =
      typeof children === "function" ? children({ selected: false }) : children;
    return (
      <button className={resolvedClassName} {...rest}>
        {content}
      </button>
    );
  },
};

describe("LinkBankClient", () => {
  let restoreDom: (() => void) | undefined;
  const originalFetch = globalThis.fetch;
  const TELLER_CONFIG = { applicationId: "app-123", environment: "sandbox" } as const;
  let setupCalls: TellerConnectSetupOptions[];
  let tellerWindow: (Window & typeof globalThis) | undefined;

  beforeEach(() => {
    restoreDom = setupDom();
    tellerWindow = globalThis.window as Window & typeof globalThis;
    setupCalls = [];
    tellerWindow.TellerConnect = {
      setup: (options: TellerConnectSetupOptions) => {
        setupCalls.push(options);
        return {
          open() {
            // noop for tests
          },
          destroy() {
            // noop for tests
          },
        };
      },
    };
  });

  afterEach(() => {
    if (restoreDom) {
      restoreDom();
    }
    globalThis.fetch = originalFetch;
    if (tellerWindow) {
      delete tellerWindow.TellerConnect;
    }
  });

  it("requests Teller tokens with credentialed fetch", async () => {
    const fetchMock = async (input: RequestInfo | URL, init?: RequestInit) => {
      assert.equal(input, "/api/teller/connect_token");
      assert.equal(init?.credentials, "include");
      assert.equal(init?.headers && (init.headers as Record<string, string>)["x-csrf-token"], CSRF_TOKEN);
      return createFetchResponse(200, { data: { connect_token: "connect-token-123" } });
    };

    globalThis.fetch = fetchMock as typeof globalThis.fetch;

    const view = render(
      <LinkBankClient csrfToken={CSRF_TOKEN} tellerConfig={TELLER_CONFIG} components={headlessStubs} />,
    );

    fireEvent.click(view.getByTestId("launch-teller"));

    await waitFor(() => {
      assert.equal(setupCalls.length, 1);
      assert.equal(setupCalls[0]?.connectToken, "connect-token-123");
      assert.equal(setupCalls[0]?.applicationId, TELLER_CONFIG.applicationId);
      assert.equal(setupCalls[0]?.environment, TELLER_CONFIG.environment);
    });

    await waitFor(() => {
      const payloads = view.getAllByTestId("event-payload");
      const payloadTexts = payloads.map((node) => node.textContent ?? "");
      assert.ok(payloadTexts.some((text) => text.includes("***-123")), payloadTexts.join(" | "));
    });
  });

  it("surfaces vendor errors", async () => {
    const fetchMock = async () => createFetchResponse(400, { error: "rate limit" });
    globalThis.fetch = fetchMock as typeof globalThis.fetch;

    const view = render(
      <LinkBankClient csrfToken={CSRF_TOKEN} tellerConfig={TELLER_CONFIG} components={headlessStubs} />,
    );

    fireEvent.click(view.getByTestId("launch-plaid"));

    const error = await view.findByTestId("error-plaid");
    assert.ok(error.textContent?.includes("rate limit"));
  });
});

type TellerConnectSetupOptions = {
  applicationId?: string;
  environment?: string;
  connectToken: string;
  onSuccess?: (event: Record<string, unknown>) => void;
  onExit?: (event?: Record<string, unknown>) => void;
};

