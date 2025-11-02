import { fetchWithSession } from "./session-fetch";

type UnknownRecord = Record<string, unknown>;

function isRecord(value: unknown): value is UnknownRecord {
  return typeof value === "object" && value !== null;
}

function toStringOrNull(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function toBoolean(value: unknown): boolean | null {
  if (typeof value === "boolean") {
    return value;
  }

  return null;
}

function toNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }

  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }

  return null;
}

export type OwnerUser = {
  id: string;
  email: string;
  role: string;
  suspended: boolean;
  suspendedAt: string | null;
  insertedAt: string | null;
  updatedAt: string | null;
};

export type OwnerUsersMeta = {
  page: number;
  perPage: number;
  totalEntries: number;
};

export type OwnerUsersPayload = {
  users: OwnerUser[];
  meta: OwnerUsersMeta;
};

export type OwnerUsersResult =
  | ({ status: "ok" } & OwnerUsersPayload)
  | { status: "unauthorized" }
  | { status: "forbidden" }
  | { status: "error" };

function resolveUser(value: unknown): OwnerUser | null {
  if (!isRecord(value)) {
    return null;
  }

  const idValue = value.id;
  const emailValue = value.email;
  const roleValue = value.role;
  const suspendedValue = value.suspended;

  if (typeof idValue !== "string" || typeof emailValue !== "string") {
    return null;
  }

  const role = typeof roleValue === "string" ? roleValue : "member";
  const suspended = toBoolean(suspendedValue) ?? false;

  return {
    id: idValue,
    email: emailValue,
    role,
    suspended,
    suspendedAt: toStringOrNull(value.suspended_at),
    insertedAt: toStringOrNull(value.inserted_at),
    updatedAt: toStringOrNull(value.updated_at),
  } satisfies OwnerUser;
}

function resolveMeta(value: unknown): OwnerUsersMeta | null {
  if (!isRecord(value)) {
    return null;
  }

  const page = toNumber(value["page"]);
  const perPage = toNumber(value["per_page"]);
  const totalEntries = toNumber(value["total_entries"]);

  if (page === null || perPage === null || totalEntries === null) {
    return null;
  }

  return {
    page,
    perPage,
    totalEntries,
  } satisfies OwnerUsersMeta;
}

export function resolveOwnerUsersPayload(payload: unknown): OwnerUsersPayload | null {
  if (!isRecord(payload)) {
    return null;
  }

  const data = payload.data;
  const meta = payload.meta;

  if (!Array.isArray(data)) {
    return null;
  }

  const users = data
    .map((entry) => resolveUser(entry))
    .filter((user): user is OwnerUser => Boolean(user));

  if (!meta) {
    return null;
  }

  const resolvedMeta = resolveMeta(meta);

  if (!resolvedMeta) {
    return null;
  }

  return { users, meta: resolvedMeta } satisfies OwnerUsersPayload;
}

export function resolveOwnerUserFromResponse(payload: unknown): OwnerUser | null {
  if (!isRecord(payload)) {
    return null;
  }

  const data = payload.data ?? payload.user ?? payload;
  return resolveUser(data);
}

export type FetchOwnerUsersOptions = {
  query?: string | null;
  page?: number;
  perPage?: number;
};

export async function getOwnerUsers(
  options: FetchOwnerUsersOptions = {},
): Promise<OwnerUsersResult> {
  const searchParams = new URLSearchParams();

  if (options.query?.trim()) {
    searchParams.set("q", options.query.trim());
  }

  if (options.page && Number.isFinite(options.page)) {
    searchParams.set("page", String(options.page));
  }

  if (options.perPage && Number.isFinite(options.perPage)) {
    searchParams.set("per_page", String(options.perPage));
  }

  const queryString = searchParams.toString();
  const path = queryString ? `/api/owner/users?${queryString}` : "/api/owner/users";

  const response = await fetchWithSession(path);

  if (!response) {
    return { status: "unauthorized" };
  }

  if (response.status === 401) {
    return { status: "unauthorized" };
  }

  if (response.status === 403) {
    return { status: "forbidden" };
  }

  if (!response.ok) {
    return { status: "error" };
  }

  const payload = (await response.json().catch(() => null)) as unknown;
  const resolved = resolveOwnerUsersPayload(payload);

  if (!resolved) {
    return { status: "error" };
  }

  return { status: "ok", ...resolved };
}
