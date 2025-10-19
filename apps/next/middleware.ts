import type { NextRequest } from "next/server";
import { NextResponse } from "next/server";

const CSP_HEADER = "x-csp-nonce";
const NEXT_NONCE_HEADER = "x-nonce";
const CSRF_HEADER = "x-csrf-token";

export function middleware(request: NextRequest) {
  const requestHeaders = new Headers(request.headers);
  const nonce = requestHeaders.get(CSP_HEADER);
  const csrfToken = requestHeaders.get(CSRF_HEADER);

  if (nonce) {
    requestHeaders.set(CSP_HEADER, nonce);
    requestHeaders.set(NEXT_NONCE_HEADER, nonce);
  }

  if (csrfToken) {
    requestHeaders.set(CSRF_HEADER, csrfToken);
  }

  const response = NextResponse.next({
    request: {
      headers: requestHeaders,
    },
  });

  if (nonce) {
    response.headers.set(CSP_HEADER, nonce);
  }

  if (csrfToken) {
    response.headers.set(CSRF_HEADER, csrfToken);
  }

  return response;
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon\\.ico).*)"],
};
