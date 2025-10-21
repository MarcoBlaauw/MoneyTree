import { fetchWithSession } from "./session-fetch";

export type CurrentUserProfile = {
  email: string;
  name: string | null;
};

type SettingsProfile = {
  full_name?: string | null;
  email?: string | null;
};

type SettingsResponse = {
  profile?: SettingsProfile | null;
  user?: {
    email?: string | null;
    name?: string | null;
  } | null;
  email?: string | null;
  name?: string | null;
};

function resolveProfile(data: unknown): CurrentUserProfile | null {
  if (!data || typeof data !== "object") {
    return null;
  }

  const response = data as SettingsResponse;
  const profile = response.profile ?? undefined;

  const email =
    profile?.email ?? response.user?.email ?? response.email ?? undefined;

  if (!email) {
    return null;
  }

  const name =
    profile?.full_name ?? response.user?.name ?? response.name ?? null;

  return {
    email,
    name: name ?? null,
  };
}

export async function getCurrentUser(): Promise<CurrentUserProfile | null> {
  const response = await fetchWithSession("/api/settings");

  if (!response) {
    return null;
  }

  if (response.status === 401 || response.status === 403) {
    return null;
  }

  if (!response.ok) {
    return null;
  }

  const payload = (await response.json().catch(() => null)) as unknown;
  return resolveProfile(payload);
}
