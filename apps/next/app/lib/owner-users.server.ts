import type { FetchOwnerUsersOptions, OwnerUsersResult } from "./owner-users";
import { resolveOwnerUsersPayload } from "./owner-users";
import { fetchWithSession } from "./session-fetch";

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
