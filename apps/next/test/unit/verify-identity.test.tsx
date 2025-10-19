import { afterEach, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import React, { type HTMLAttributes } from "react";
import { render, fireEvent, waitFor } from "@testing-library/react";
import VerifyIdentityClient from "../../app/verify-identity/verify-identity-client";
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

const dialogStubs = {
  Dialog: ({ open, children }: { open: boolean; children?: React.ReactNode }) => (open ? <div>{children}</div> : null),
  DialogBackdrop: ({ children }: { children?: React.ReactNode }) => <div>{children}</div>,
  DialogPanel: ({ children, ...rest }: DivProps) => <div {...rest}>{children}</div>,
  DialogTitle: ({ children, ...rest }: DivProps) => <div {...rest}>{children}</div>,
};

describe("VerifyIdentityClient", () => {
  let restoreDom: (() => void) | undefined;
  const originalFetch = globalThis.fetch;

  beforeEach(() => {
    restoreDom = setupDom();
  });

  afterEach(() => {
    if (restoreDom) {
      restoreDom();
    }
    globalThis.fetch = originalFetch;
  });

  it("redacts sensitive Persona payloads", async () => {
    const fetchMock = async () =>
      createFetchResponse(200, {
        data: {
          client_token: "persona-client-token-1234",
          environment: "sandbox",
          inquiry_id: "inq_123",
          applicant: { ssn: "123-45-6789", email: "test@example.com" },
        },
      });

    globalThis.fetch = fetchMock as typeof globalThis.fetch;

    const view = render(<VerifyIdentityClient csrfToken={CSRF_TOKEN} components={dialogStubs} />);

    fireEvent.click(view.getByTestId("launch-kyc"));

    await waitFor(() => {
      const payloads = view.getAllByTestId("event-payload");
      const payloadTexts = payloads.map((node) => node.textContent ?? "");
      assert.ok(payloadTexts.some((text) => text.includes("***6789")), payloadTexts.join(" | "));
      assert.ok(!payloadTexts.some((text) => text.includes("test@example.com")));
    });
  });

  it("renders Persona errors", async () => {
    const fetchMock = async () => createFetchResponse(500, { error: "persona unavailable" });
    globalThis.fetch = fetchMock as typeof globalThis.fetch;

    const view = render(<VerifyIdentityClient csrfToken={CSRF_TOKEN} components={dialogStubs} />);

    fireEvent.click(view.getByTestId("launch-kyc"));

    await waitFor(() => {
      const error = view.getByTestId("error-kyc");
      assert.ok(error.textContent?.includes("persona unavailable"));
    });
  });
});
