"use client";

import React from "react";
import { usePathname, useRouter } from "next/navigation";

import type { OwnerUser, OwnerUsersMeta } from "../../lib/owner-users";
import { resolveOwnerUserFromResponse } from "../../lib/owner-users";

type SortKey = "email" | "role" | "suspended" | "created" | "updated";

type SortState = {
  key: SortKey;
  direction: "asc" | "desc";
};

const BASE_ROLES = ["owner", "advisor", "member"] as const;

function useOptionalRouter() {
  try {
    return useRouter();
  } catch {
    return null;
  }
}

function useOptionalPathname() {
  try {
    return usePathname();
  } catch {
    return null;
  }
}

function formatDate(value: string | null): string {
  if (!value) {
    return "—";
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "Unknown";
  }

  return new Intl.DateTimeFormat("en-US", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}

function compareStrings(a: string, b: string) {
  return a.localeCompare(b, undefined, { sensitivity: "base" });
}

function compareUsers(a: OwnerUser, b: OwnerUser, state: SortState) {
  const multiplier = state.direction === "asc" ? 1 : -1;

  switch (state.key) {
    case "email":
      return compareStrings(a.email, b.email) * multiplier;
    case "role":
      return compareStrings(a.role, b.role) * multiplier;
    case "suspended": {
      const aValue = a.suspended ? 1 : 0;
      const bValue = b.suspended ? 1 : 0;
      return (aValue - bValue) * multiplier;
    }
    case "created":
      return compareStrings(a.insertedAt ?? "", b.insertedAt ?? "") * multiplier;
    case "updated":
      return compareStrings(a.updatedAt ?? "", b.updatedAt ?? "") * multiplier;
    default:
      return 0;
  }
}

type OwnerUsersClientProps = {
  initialUsers: OwnerUser[];
  meta: OwnerUsersMeta;
  csrfToken: string;
  initialQuery: string;
};

type RowErrors = Record<string, string>;

export default function OwnerUsersClient({
  initialUsers,
  meta,
  csrfToken,
  initialQuery,
}: OwnerUsersClientProps) {
  const router = useOptionalRouter();
  const pathname = useOptionalPathname();
  const resolvedPathname = pathname ?? "/owner/users";
  const [users, setUsers] = React.useState<OwnerUser[]>(initialUsers);
  const [searchTerm, setSearchTerm] = React.useState(initialQuery);
  const [sortState, setSortState] = React.useState<SortState>({ key: "email", direction: "asc" });
  const [rowErrors, setRowErrors] = React.useState<RowErrors>({});
  const [pendingIds, setPendingIds] = React.useState<Set<string>>(new Set());
  const [isNavigating, startTransition] = React.useTransition();

  React.useEffect(() => {
    setUsers(initialUsers);
  }, [initialUsers]);

  React.useEffect(() => {
    setSearchTerm(initialQuery);
  }, [initialQuery]);

  const allRoles = React.useMemo(() => {
    const customRoles = new Set(BASE_ROLES);
    for (const user of users) {
      customRoles.add(user.role);
    }
    return Array.from(customRoles);
  }, [users]);

  const sortedUsers = React.useMemo(() => {
    return [...users].sort((a, b) => compareUsers(a, b, sortState));
  }, [users, sortState]);

  const handleSort = React.useCallback((key: SortKey) => {
    setSortState((previous) => {
      if (previous.key === key) {
        return {
          key,
          direction: previous.direction === "asc" ? "desc" : "asc",
        };
      }

      return { key, direction: "asc" };
    });
  }, []);

  const setPending = React.useCallback((id: string, pending: boolean) => {
    setPendingIds((current) => {
      const next = new Set(current);
      if (pending) {
        next.add(id);
      } else {
        next.delete(id);
      }
      return next;
    });
  }, []);

  const mutateUser = React.useCallback(
    async (
      id: string,
      optimisticChanges: Partial<OwnerUser>,
      body: Record<string, unknown>,
    ) => {
      let previousUser: OwnerUser | undefined;

      setUsers((current) => {
        previousUser = current.find((user) => user.id === id);
        if (!previousUser) {
          return current;
        }

        const updatedUser: OwnerUser = { ...previousUser, ...optimisticChanges };
        return current.map((user) => (user.id === id ? updatedUser : user));
      });

      if (!previousUser) {
        return;
      }

      setPending(id, true);
      setRowErrors((errors) => {
        const next = { ...errors };
        delete next[id];
        return next;
      });

      try {
        const response = await fetch(`/api/owner/users/${encodeURIComponent(id)}`, {
          method: "PATCH",
          credentials: "include",
          headers: {
            "content-type": "application/json",
            "x-csrf-token": csrfToken,
          },
          body: JSON.stringify(body),
        });

        if (!response.ok) {
          const errorPayload = (await response.json().catch(() => null)) as unknown;
          let message = "Unable to update this user.";

          if (
            errorPayload &&
            typeof errorPayload === "object" &&
            "error" in errorPayload &&
            typeof (errorPayload as Record<string, unknown>).error === "string"
          ) {
            message = (errorPayload as Record<string, string>).error;
          }

          throw new Error(message);
        }

        const payload = (await response.json().catch(() => null)) as unknown;
        const parsed = resolveOwnerUserFromResponse(payload);

        if (!parsed) {
          throw new Error("Received an unexpected response from the server.");
        }

        setUsers((current) => current.map((user) => (user.id === id ? parsed : user)));
      } catch (error) {
        setUsers((current) =>
          current.map((user) => (user.id === id && previousUser ? previousUser : user)),
        );

        const message =
          error instanceof Error ? error.message : "Something went wrong while saving changes.";

        setRowErrors((errors) => ({ ...errors, [id]: message }));
      } finally {
        setPending(id, false);
      }
    },
    [csrfToken, setPending],
  );

  const onRoleChange = React.useCallback(
    async (id: string, nextRole: string) => {
      await mutateUser(id, { role: nextRole }, { role: nextRole });
    },
    [mutateUser],
  );

  const onToggleSuspension = React.useCallback(
    async (id: string, suspended: boolean) => {
      await mutateUser(id, { suspended, suspendedAt: suspended ? new Date().toISOString() : null }, { suspended });
    },
    [mutateUser],
  );

  const onSearchSubmit = React.useCallback(
    (event: React.FormEvent<HTMLFormElement>) => {
      event.preventDefault();
      const params = new URLSearchParams();
      const trimmed = searchTerm.trim();
      if (trimmed) {
        params.set("q", trimmed);
      }

      startTransition(() => {
        if (!router) {
          return;
        }
        const query = params.toString();
        const destination = query ? `${resolvedPathname}?${query}` : resolvedPathname;
        router.replace(destination, { scroll: false });
      });
    },
    [resolvedPathname, router, searchTerm, startTransition],
  );

  const onReset = React.useCallback(() => {
    setSearchTerm("");
    startTransition(() => {
      if (!router) {
        return;
      }
      router.replace(resolvedPathname, { scroll: false });
    });
  }, [resolvedPathname, router, startTransition]);

  return (
    <main className="bg-background text-foreground min-h-screen">
      <section className="mx-auto flex w-full max-w-6xl flex-col gap-8 px-6 py-16">
        <header className="space-y-3">
          <p className="text-xs font-semibold uppercase tracking-wide text-primary">Owner tools</p>
          <div className="flex flex-col gap-2 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight text-foreground">User management</h1>
              <p className="text-sm text-zinc-500">
                Search, sort, and update roles for every user connected to your MoneyTree workspace.
              </p>
            </div>
            <form className="flex w-full max-w-md items-center gap-2" onSubmit={onSearchSubmit}>
              <label className="sr-only" htmlFor="owner-user-search">
                Search users by email
              </label>
              <input
                id="owner-user-search"
                name="q"
                value={searchTerm}
                onChange={(event) => setSearchTerm(event.target.value)}
                placeholder="Search by email…"
                className="flex-1 rounded-full border border-zinc-300 bg-white px-4 py-2 text-sm shadow-sm focus:border-primary focus:outline-none"
                type="search"
              />
              <button
                type="submit"
                className="rounded-full bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground shadow hover:bg-secondary transition"
                disabled={isNavigating}
              >
                Search
              </button>
              <button
                type="button"
                onClick={onReset}
                className="rounded-full border border-zinc-300 px-3 py-2 text-sm text-zinc-600 hover:border-zinc-400 hover:text-zinc-800 transition"
                disabled={isNavigating}
              >
                Reset
              </button>
            </form>
          </div>
          <div className="rounded-xl border border-primary/20 bg-primary/5 p-4 text-sm text-primary">
            <span className="font-medium">{meta.totalEntries} users in workspace.</span>{" "}
            Showing {sortedUsers.length} on this page.
          </div>
        </header>

        <div className="overflow-x-auto rounded-2xl border border-zinc-200 bg-white shadow-sm">
          <table className="w-full table-auto text-left text-sm" aria-label="Workspace users">
            <thead>
              <tr className="border-b border-zinc-200 text-xs uppercase tracking-wide text-zinc-500">
                <th className="py-3 pl-4 pr-3">
                  <button
                    type="button"
                    onClick={() => handleSort("email")}
                    className="flex items-center gap-1 font-semibold text-zinc-600 hover:text-primary"
                  >
                    Email
                    {sortState.key === "email" && <SortIndicator direction={sortState.direction} />}
                  </button>
                </th>
                <th className="py-3 px-3">
                  <button
                    type="button"
                    onClick={() => handleSort("role")}
                    className="flex items-center gap-1 font-semibold text-zinc-600 hover:text-primary"
                  >
                    Role
                    {sortState.key === "role" && <SortIndicator direction={sortState.direction} />}
                  </button>
                </th>
                <th className="py-3 px-3">
                  <button
                    type="button"
                    onClick={() => handleSort("suspended")}
                    className="flex items-center gap-1 font-semibold text-zinc-600 hover:text-primary"
                  >
                    Status
                    {sortState.key === "suspended" && <SortIndicator direction={sortState.direction} />}
                  </button>
                </th>
                <th className="py-3 px-3">
                  <button
                    type="button"
                    onClick={() => handleSort("created")}
                    className="flex items-center gap-1 font-semibold text-zinc-600 hover:text-primary"
                  >
                    Created
                    {sortState.key === "created" && <SortIndicator direction={sortState.direction} />}
                  </button>
                </th>
                <th className="py-3 px-3">
                  <button
                    type="button"
                    onClick={() => handleSort("updated")}
                    className="flex items-center gap-1 font-semibold text-zinc-600 hover:text-primary"
                  >
                    Updated
                    {sortState.key === "updated" && <SortIndicator direction={sortState.direction} />}
                  </button>
                </th>
                <th className="py-3 pr-4 text-right">Actions</th>
              </tr>
            </thead>
            <tbody>
              {sortedUsers.map((user) => {
                const pending = pendingIds.has(user.id);
                const rowError = rowErrors[user.id];
                return (
                  <tr key={user.id} className="border-b border-zinc-100 align-top">
                    <td className="whitespace-nowrap py-3 pl-4 pr-3 font-medium text-zinc-900">
                      <div className="space-y-1">
                        <p>{user.email}</p>
                        {user.suspendedAt ? (
                          <p className="text-xs text-zinc-500">Suspended at {formatDate(user.suspendedAt)}</p>
                        ) : null}
                      </div>
                    </td>
                    <td className="py-3 px-3">
                      <label className="sr-only" htmlFor={`role-${user.id}`}>
                        Role for {user.email}
                      </label>
                      <select
                        id={`role-${user.id}`}
                        className="w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-primary focus:outline-none disabled:cursor-not-allowed disabled:opacity-60"
                        value={user.role}
                        onChange={(event) => onRoleChange(user.id, event.target.value)}
                        disabled={pending}
                      >
                        {allRoles.map((role) => (
                          <option key={role} value={role}>
                            {role}
                          </option>
                        ))}
                      </select>
                    </td>
                    <td className="py-3 px-3">
                      <span
                        className={`inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold ${
                          user.suspended
                            ? "bg-rose-100 text-rose-700"
                            : "bg-emerald-100 text-emerald-700"
                        }`}
                      >
                        {user.suspended ? "Suspended" : "Active"}
                      </span>
                    </td>
                    <td className="py-3 px-3 text-zinc-600">{formatDate(user.insertedAt)}</td>
                    <td className="py-3 px-3 text-zinc-600">{formatDate(user.updatedAt)}</td>
                    <td className="py-3 pr-4">
                      <div className="flex flex-col items-end gap-2 text-sm">
                        <button
                          type="button"
                          className="rounded-full border border-zinc-300 px-3 py-1 text-xs font-semibold text-zinc-700 hover:border-primary hover:text-primary transition disabled:cursor-not-allowed disabled:opacity-60"
                          onClick={() => onToggleSuspension(user.id, !user.suspended)}
                          disabled={pending}
                        >
                          {user.suspended ? "Reactivate" : "Suspend"}
                        </button>
                        {rowError ? (
                          <p className="max-w-xs text-right text-xs text-rose-600" role="alert">
                            {rowError}
                          </p>
                        ) : null}
                        {pending ? (
                          <p className="text-xs text-zinc-400" aria-live="polite">
                            Saving…
                          </p>
                        ) : null}
                      </div>
                    </td>
                  </tr>
                );
              })}
              {sortedUsers.length === 0 ? (
                <tr>
                  <td colSpan={6} className="py-8 text-center text-sm text-zinc-500">
                    No users match your filters.
                  </td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>
      </section>
    </main>
  );
}

type SortIndicatorProps = {
  direction: "asc" | "desc";
};

function SortIndicator({ direction }: SortIndicatorProps) {
  return (
    <span aria-hidden className="text-xs text-zinc-400">
      {direction === "asc" ? "↑" : "↓"}
    </span>
  );
}
