import { fetchWithSession } from "./session-fetch";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function toStringOrNull(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function toBoolean(value: unknown, fallback = false): boolean {
  return typeof value === "boolean" ? value : fallback;
}

export type ControlPanelSession = {
  id: string;
  context: string;
  lastUsedAt: string | null;
  userAgent: string | null;
  ipAddress: string | null;
};

export type ControlPanelSettings = {
  profile: {
    displayName: string | null;
    fullName: string | null;
    email: string | null;
    role: string | null;
  };
  notifications: {
    transferAlerts: boolean;
    securityAlerts: boolean;
  };
  sessions: ControlPanelSession[];
};

function resolveSessions(value: unknown): ControlPanelSession[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value
    .map((item) => {
      if (!isRecord(item)) {
        return null;
      }

      const idValue = item.id;
      const contextValue = item.context;

      if (typeof idValue !== "string" && typeof idValue !== "number") {
        return null;
      }

      if (typeof contextValue !== "string") {
        return null;
      }

      return {
        id: String(idValue),
        context: contextValue,
        lastUsedAt: toStringOrNull(item.last_used_at),
        userAgent: toStringOrNull(item.user_agent),
        ipAddress: toStringOrNull(item.ip_address),
      } satisfies ControlPanelSession;
    })
    .filter((session): session is ControlPanelSession => Boolean(session));
}

function resolveSettings(payload: unknown): ControlPanelSettings | null {
  if (!isRecord(payload)) {
    return null;
  }

  const data = payload.data;

  if (!isRecord(data)) {
    return null;
  }

  const profile = isRecord(data.profile) ? data.profile : {};
  const notifications = isRecord(data.notifications) ? data.notifications : {};

  return {
    profile: {
      displayName: toStringOrNull(profile.display_name),
      fullName: toStringOrNull(profile.full_name),
      email: toStringOrNull(profile.email),
      role: toStringOrNull(profile.role),
    },
    notifications: {
      transferAlerts: toBoolean(notifications.transfer_alerts, true),
      securityAlerts: toBoolean(notifications.security_alerts, true),
    },
    sessions: resolveSessions(data.sessions),
  };
}

export async function getControlPanelSettings(): Promise<ControlPanelSettings | null> {
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
  return resolveSettings(payload);
}
