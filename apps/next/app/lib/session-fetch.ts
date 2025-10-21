import { headers } from "next/headers";

function buildBaseUrl(headerList: ReturnType<typeof headers>): string | null {
  const proto =
    headerList.get("x-forwarded-proto") ??
    headerList.get("x-forwarded-protocol") ??
    "http";
  const host = headerList.get("x-forwarded-host") ?? headerList.get("host");

  if (!host) {
    return null;
  }

  return `${proto}://${host}`;
}

/**
 * Proxies a request to the Phoenix backend using the current session cookie.
 */
export async function fetchWithSession(
  path: string,
  init: RequestInit = {},
): Promise<Response | null> {
  const headerList = headers();
  const cookie = headerList.get("cookie");

  if (!cookie) {
    return null;
  }

  const baseUrl = buildBaseUrl(headerList);
  if (!baseUrl) {
    return null;
  }

  const csrfToken = headerList.get("x-csrf-token");

  const forwardedHeaders = new Headers(init.headers ?? {});
  if (!forwardedHeaders.has("accept")) {
    forwardedHeaders.set("accept", "application/json");
  }
  forwardedHeaders.set("cookie", cookie);

  if (csrfToken && !forwardedHeaders.has("x-csrf-token")) {
    forwardedHeaders.set("x-csrf-token", csrfToken);
  }

  try {
    const response = await fetch(`${baseUrl}${path}`, {
      ...init,
      method: init.method ?? "GET",
      headers: forwardedHeaders,
      cache: init.cache ?? "no-store",
    });

    return response;
  } catch {
    return null;
  }
}
