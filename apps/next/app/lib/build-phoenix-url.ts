import { headers } from "next/headers";

function normalizePath(path: string): string {
  if (!path.startsWith("/")) {
    return `/${path}`;
  }

  return path;
}

function getForwardedOrigin(): string | null {
  try {
    const headerList = headers();
    const proto =
      headerList.get("x-forwarded-proto") ??
      headerList.get("x-forwarded-protocol") ??
      "http";
    const host =
      headerList.get("x-forwarded-host") ?? headerList.get("host");

    if (!host) {
      return null;
    }

    return `${proto}://${host}`;
  } catch {
    return null;
  }
}

export function buildPhoenixUrl(path: string): string {
  const normalizedPath = normalizePath(path);
  const configuredOrigin = process.env.NEXT_PUBLIC_PHOENIX_ORIGIN?.trim();

  if (configuredOrigin) {
    const normalizedOrigin = configuredOrigin.endsWith("/")
      ? configuredOrigin.slice(0, -1)
      : configuredOrigin;

    return `${normalizedOrigin}${normalizedPath}`;
  }

  const forwardedOrigin = getForwardedOrigin();
  if (forwardedOrigin) {
    return `${forwardedOrigin}${normalizedPath}`;
  }

  return normalizedPath;
}

export type BuildPhoenixUrl = typeof buildPhoenixUrl;
