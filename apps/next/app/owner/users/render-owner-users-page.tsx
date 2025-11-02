import React from "react";

import type { CurrentUserProfile } from "../../lib/current-user";
import { getCurrentUser } from "../../lib/current-user";
import type { FetchOwnerUsersOptions, OwnerUsersResult } from "../../lib/owner-users";
import { getOwnerUsers } from "../../lib/owner-users";
import OwnerUsersClient from "./owner-users-client";

type OwnerUsersPageOptions = {
  fetchCurrentUser?: () => Promise<CurrentUserProfile | null>;
  fetchUsers?: (options: FetchOwnerUsersOptions) => Promise<OwnerUsersResult>;
  query?: string | null;
  csrfToken?: string;
};

function AccessMessage({
  title,
  description,
}: {
  title: string;
  description: string;
}) {
  return (
    <main className="bg-background text-foreground min-h-screen">
      <section className="mx-auto flex w-full max-w-5xl flex-col gap-4 px-6 py-16">
        <header className="space-y-2">
          <p className="text-xs font-semibold uppercase tracking-wide text-primary">Owner tools</p>
          <h1 className="text-3xl font-semibold tracking-tight text-foreground">
            User management
          </h1>
          <p className="text-sm text-zinc-500">
            Review roles, audit suspension status, and keep your workspace secure.
          </p>
        </header>
        <div className="rounded-xl border border-dashed border-primary/30 bg-white/70 p-6 text-sm text-zinc-600">
          <p className="font-medium text-zinc-800">{title}</p>
          <p className="text-zinc-600">{description}</p>
        </div>
      </section>
    </main>
  );
}

function ErrorMessage({ message }: { message: string }) {
  return (
    <main className="bg-background text-foreground min-h-screen">
      <section className="mx-auto flex w-full max-w-5xl flex-col gap-4 px-6 py-16">
        <header className="space-y-2">
          <p className="text-xs font-semibold uppercase tracking-wide text-primary">Owner tools</p>
          <h1 className="text-3xl font-semibold tracking-tight text-foreground">
            User management
          </h1>
        </header>
        <div className="rounded-xl border border-rose-200 bg-rose-50/80 p-6 text-sm text-rose-700">
          {message}
        </div>
      </section>
    </main>
  );
}

export async function renderOwnerUsersPage({
  fetchCurrentUser = getCurrentUser,
  fetchUsers = getOwnerUsers,
  query = null,
  csrfToken = "",
}: OwnerUsersPageOptions = {}) {
  const currentUser = await fetchCurrentUser();

  if (!currentUser) {
    return (
      <AccessMessage
        title="You need to sign in to manage users."
        description="Authenticate with your MoneyTree owner account, then refresh this page to continue."
      />
    );
  }

  if (currentUser.role !== "owner") {
    return (
      <AccessMessage
        title="This area is limited to workspace owners."
        description="Contact an existing owner to request elevated access, or return to the control panel for member tools."
      />
    );
  }

  const result = await fetchUsers({ query: query ?? undefined });

  if (result.status === "unauthorized") {
    return (
      <AccessMessage
        title="Your session has expired."
        description="Sign in again to continue managing your workspace users."
      />
    );
  }

  if (result.status === "forbidden") {
    return (
      <AccessMessage
        title="Owner permissions required."
        description="You no longer have owner access for this workspace. Reach out to another owner if you believe this is a mistake."
      />
    );
  }

  if (result.status === "error") {
    return <ErrorMessage message="We couldn't load the user directory. Please try again in a few moments." />;
  }

  if (result.status !== "ok") {
    return <ErrorMessage message="We couldn't load the user directory. Please try again in a few moments." />;
  }

  const { users, meta } = result;

  return (
    <OwnerUsersClient
      initialUsers={users}
      meta={meta}
      csrfToken={csrfToken}
      initialQuery={query ?? ""}
    />
  );
}
