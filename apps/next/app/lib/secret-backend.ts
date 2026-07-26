function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function toString(value: unknown, fallback = 'unknown'): string {
  return typeof value === 'string' ? value : fallback;
}

function toNumber(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0;
}

function toStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.filter((item): item is string => typeof item === 'string');
}

export type SecretBackendGroupStatus = {
  name: string;
  status: string;
  presentKeys: number;
  missingKeys: string[];
  errors: string[];
};

export type SecretBackendStatus = {
  backend: string;
  selectedBy: string;
  status: string;
  live: boolean;
  groups: SecretBackendGroupStatus[];
};

export function resolveSecretBackendPayload(payload: unknown): SecretBackendStatus | null {
  if (!isRecord(payload) || !isRecord(payload.data)) {
    return null;
  }

  const data = payload.data;
  const groups = isRecord(data.groups) ? data.groups : {};

  return {
    backend: toString(data.backend),
    selectedBy: toString(data.selected_by),
    status: toString(data.status),
    live: data.live === true,
    groups: Object.entries(groups)
      .map(([name, value]) => {
        if (!isRecord(value)) {
          return null;
        }

        return {
          name,
          status: toString(value.status),
          presentKeys: toNumber(value.present_keys),
          missingKeys: toStringArray(value.missing_keys),
          errors: toStringArray(value.errors),
        } satisfies SecretBackendGroupStatus;
      })
      .filter((group): group is SecretBackendGroupStatus => Boolean(group))
      .sort((a, b) => a.name.localeCompare(b.name)),
  };
}
