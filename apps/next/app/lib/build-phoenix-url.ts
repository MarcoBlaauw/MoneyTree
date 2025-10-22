function normalizePath(path: string): string {
  if (!path.startsWith("/")) {
    return `/${path}`;
  }

  return path;
}

export type HeaderList = {
  get(name: string): string | null | undefined;
};

function getForwardedOrigin(headerList?: HeaderList): string | null {
  if (!headerList) {
    return null;
  }

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
}

export function buildPhoenixUrl(path: string, headerList?: HeaderList): string {
  const normalizedPath = normalizePath(path);
  const configuredOrigin = process.env.NEXT_PUBLIC_PHOENIX_ORIGIN?.trim();

  if (configuredOrigin) {
    const normalizedOrigin = configuredOrigin.endsWith("/")
      ? configuredOrigin.slice(0, -1)
      : configuredOrigin;

    return `${normalizedOrigin}${normalizedPath}`;
  }

  const forwardedOrigin = getForwardedOrigin(headerList);
  if (forwardedOrigin) {
    return `${forwardedOrigin}${normalizedPath}`;
  }

  return normalizedPath;
}

export type BuildPhoenixUrl = (path: string) => string;
