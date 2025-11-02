import { headers } from "next/headers";

type HeaderList = ReturnType<typeof headers>;

export type CurrentUserProfile = {
  email: string;
  name: string | null;
};

type SettingsProfile = {
  full_name?: string | null;
  email?: string | null;
};

type ApiUser = {
  email?: string | null;
  name?: string | null;
  full_name?: string | null;
};

type SettingsResponse = {
  profile?: SettingsProfile | null;
  user?: ApiUser | null;
  email?: string | null;
  name?: string | null;
};

type MeResponse = {
  data?: ApiUser | null;
};

function resolveProfile(data: unknown): CurrentUserProfile | null {
  if (!data || typeof data !== "object") {
    return null;
  }

  const response = data as SettingsResponse & MeResponse;
  const profile = response.profile ?? undefined;
  const dataUser = response.data && typeof response.data === "object"
    ? (response.data as ApiUser)
    : undefined;

  const email =
    profile?.email ??
    response.user?.email ??
    response.email ??
    dataUser?.email ??
    undefined;

  if (!email) {
    return null;
  }

  const name =
    profile?.full_name ??
    response.user?.name ??
    response.name ??
    dataUser?.name ??
    dataUser?.full_name ??
    null;

  return {
    email,
    name: name ?? null,
  };
}

function buildBaseUrl(headerList: HeaderList): string | null {
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

export async function getCurrentUser(): Promise<CurrentUserProfile | null> {
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

  const forwardedHeaders = new Headers();
  forwardedHeaders.set("accept", "application/json");
  forwardedHeaders.set("cookie", cookie);

  if (csrfToken) {
    forwardedHeaders.set("x-csrf-token", csrfToken);
  }

  try {
    const response = await fetch(`${baseUrl}/api/me`, {
      method: "GET",
      headers: forwardedHeaders,
      cache: "no-store",
    });

    if (response.status === 401 || response.status === 403) {
      return null;
    }

    if (!response.ok) {
      return null;
    }

    const payload = (await response.json().catch(() => null)) as unknown;
    return resolveProfile(payload);
  } catch {
    return null;
  }
}
