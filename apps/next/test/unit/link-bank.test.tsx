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

function createTextFetchResponse(status: number, body: string) {
  return Promise.resolve(
    new Response(body, {
      status,
      headers: { "content-type": "text/html; charset=utf-8" },
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
  let plaidCreateCalls: PlaidCreateOptions[];
  let tellerWindow: (Window & typeof globalThis) | undefined;

  beforeEach(() => {
    restoreDom = setupDom();
    tellerWindow = globalThis.window as Window & typeof globalThis;
    setupCalls = [];
    plaidCreateCalls = [];
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

    tellerWindow.Plaid = {
      create: (options: PlaidCreateOptions) => {
        plaidCreateCalls.push(options);
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
      delete tellerWindow.Plaid;
    }
  });

  it("opens Teller Connect directly without prefetching a connect token", async () => {
    const fetchMock = async () => {
      throw new Error("unexpected fetch");
    };

    globalThis.fetch = fetchMock as typeof globalThis.fetch;

    const view = render(
      <LinkBankClient
        csrfToken={CSRF_TOKEN}
        tellerConfig={TELLER_CONFIG}
        enabledProviders={["teller", "plaid"]}
        components={headlessStubs}
      />,
    );

    fireEvent.click(view.getByTestId("launch-teller"));

    await waitFor(() => {
      assert.equal(setupCalls.length, 1);
      assert.equal(setupCalls[0]?.connectToken, undefined);
      assert.equal(Object.prototype.hasOwnProperty.call(setupCalls[0] ?? {}, "connectToken"), false);
      assert.equal(setupCalls[0]?.applicationId, TELLER_CONFIG.applicationId);
      assert.equal(setupCalls[0]?.environment, TELLER_CONFIG.environment);
    });

    assert.ok(view.getByTestId("vendor-teller"));
  });

  it("surfaces vendor errors", async () => {
    const fetchMock = async () => createFetchResponse(400, { error: "rate limit" });
    globalThis.fetch = fetchMock as typeof globalThis.fetch;

    const view = render(
      <LinkBankClient
        csrfToken={CSRF_TOKEN}
        tellerConfig={TELLER_CONFIG}
        enabledProviders={["teller", "plaid"]}
        components={headlessStubs}
      />,
    );

    fireEvent.click(view.getByTestId("launch-plaid"));

    const error = await view.findByTestId("error-plaid");
    assert.ok(error.textContent?.includes("rate limit"));
    assert.equal(plaidCreateCalls.length, 0);
  });

  it("launches Plaid Link and exchanges public token", async () => {
    const calls: Array<{ url: string; body: Record<string, unknown> }> = [];

    const fetchMock = async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input.toString();
      const body = init?.body ? (JSON.parse(String(init.body)) as Record<string, unknown>) : {};
      calls.push({ url, body });

      if (url === "/api/plaid/link_token") {
        return createFetchResponse(200, {
          data: { link_token: "link-token-123" },
        });
      }

      if (url === "/api/plaid/exchange") {
        assert.equal(body.public_token, "public-token-123");
        assert.equal(body.institution_name, "Demo Bank");

        return createFetchResponse(200, {
          data: { connection_id: "conn-1" },
        });
      }

      return createFetchResponse(404, { error: "not found" });
    };

    globalThis.fetch = fetchMock as typeof globalThis.fetch;

    const view = render(
      <LinkBankClient
        csrfToken={CSRF_TOKEN}
        tellerConfig={TELLER_CONFIG}
        enabledProviders={["teller", "plaid"]}
        components={headlessStubs}
      />,
    );

    fireEvent.click(view.getByTestId("launch-plaid"));

    await waitFor(() => {
      assert.equal(plaidCreateCalls.length, 1);
      assert.equal(plaidCreateCalls[0]?.token, "link-token-123");
    });

    await plaidCreateCalls[0]?.onSuccess?.("public-token-123", {
      institution: { name: "Demo Bank" },
    });

    await waitFor(() => {
      assert.ok(calls.some((call) => call.url === "/api/plaid/exchange"));
    });
  });

  it("surfaces non-JSON server failures without JSON parse errors", async () => {
    const fetchMock = async () => createTextFetchResponse(500, "<!DOCTYPE html><html>server error</html>");
    globalThis.fetch = fetchMock as typeof globalThis.fetch;

    const view = render(
      <LinkBankClient
        csrfToken={CSRF_TOKEN}
        tellerConfig={TELLER_CONFIG}
        enabledProviders={["teller", "plaid"]}
        components={headlessStubs}
      />,
    );

    fireEvent.click(view.getByTestId("launch-plaid"));

    const error = await view.findByTestId("error-plaid");
    assert.ok(error.textContent?.includes("HTTP 500"));
    assert.equal(setupCalls.length, 0);
  });

  it("claims a SimpleFIN setup token and renders discovered accounts", async () => {
    const fetchMock = async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input.toString();
      const body = init?.body ? (JSON.parse(String(init.body)) as Record<string, unknown>) : {};

      if (url === "/api/simplefin/connections") {
        return createFetchResponse(200, {
          data: {
            connections: [
              {
                id: "conn-1",
                institution_name: "SimpleFIN Bridge",
                provider: "simplefin",
                account_count: 1,
                status: "connected",
                last_synced_at: null,
              },
            ],
          },
        });
      }

      assert.equal(url, "/api/simplefin/claim");
      assert.equal(body.setup_token, "setup-token");

      return createFetchResponse(200, {
        data: {
          connection_id: "conn-1",
          institution_id: "inst-1",
          accounts: [{ id: "acct-1", name: "Checking", currency: "USD", balance: "42.00" }],
          errors: [],
        },
      });
    };

    globalThis.fetch = fetchMock as typeof globalThis.fetch;

    const view = render(
      <LinkBankClient csrfToken={CSRF_TOKEN} tellerConfig={TELLER_CONFIG} components={headlessStubs} />,
    );

    assert.ok(await view.findByText("simplefin connection • 1 accounts"));

    fireEvent.input(view.getByPlaceholderText("Paste the one-time SimpleFIN setup token"), {
      target: { value: "setup-token" },
    });
    await waitFor(() => {
      assert.equal((view.getByPlaceholderText("Paste the one-time SimpleFIN setup token") as HTMLTextAreaElement).value, "setup-token");
      assert.equal((view.getByRole("button", { name: "Connect" }) as HTMLButtonElement).disabled, false);
    });

    fireEvent.click(view.getByRole("button", { name: "Connect" }));
    assert.ok(await view.findByText("Checking"));
    assert.ok(view.getByText("USD · Balance 42.00"));
    await waitFor(() => {
      assert.ok(view.getAllByText("SimpleFIN Bridge").length >= 1);
      assert.equal((view.getByRole("button", { name: "Reload" }) as HTMLButtonElement).disabled, false);
    });
  });
});

type TellerConnectSetupOptions = {
  applicationId?: string;
  environment?: string;
  connectToken?: string;
  products?: string[];
  onSuccess?: (event: Record<string, unknown>) => void;
  onExit?: (event?: Record<string, unknown>) => void;
};

type PlaidCreateOptions = {
  token: string;
  onSuccess?: (publicToken: string, metadata: Record<string, unknown>) => void | Promise<void>;
  onExit?: (error: Record<string, unknown> | null, metadata: Record<string, unknown>) => void;
};

declare global {
  interface Window {
    Plaid?: {
      create: (options: PlaidCreateOptions) => {
        open(): void;
        destroy(): void;
      };
    };
  }
}
