import { headers } from "next/headers";

import { renderOwnerUsersPage } from "./render-owner-users-page";

type OwnerUsersPageProps = {
  searchParams?: Record<string, string | string[] | undefined>;
};

async function readHeaders() {
  try {
    return await headers();
  } catch {
    return null;
  }
}

function resolveQuery(searchParams: OwnerUsersPageProps["searchParams"]): string | null {
  if (!searchParams) {
    return null;
  }

  const value = searchParams.q;

  if (Array.isArray(value)) {
    return value[0] ?? null;
  }

  if (typeof value === "string") {
    return value;
  }

  return null;
}

export default async function OwnerUsersPage({ searchParams }: OwnerUsersPageProps) {
  const headerList = await readHeaders();
  const csrfToken = headerList?.get("x-csrf-token") ?? "";
  const query = resolveQuery(searchParams);

  return renderOwnerUsersPage({ query, csrfToken });
}
