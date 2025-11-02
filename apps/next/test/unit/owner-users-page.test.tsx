import { afterEach, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import { cleanup, render } from "@testing-library/react";

import { setupDom } from "../helpers/setup-dom";
import { renderOwnerUsersPage } from "../../app/owner/users/render-owner-users-page";
import type { CurrentUserProfile } from "../../app/lib/current-user";
import type { OwnerUsersPayload } from "../../app/lib/owner-users";

describe("Owner users page", () => {
  let restoreDom: (() => void) | undefined;

  beforeEach(() => {
    restoreDom = setupDom();
  });

  afterEach(() => {
    cleanup();
    if (restoreDom) {
      restoreDom();
      restoreDom = undefined;
    }
  });

  it("requires authentication", async () => {
    const view = render(
      await renderOwnerUsersPage({
        fetchCurrentUser: async () => null,
        fetchUsers: async () => ({ status: "unauthorized" }),
      }),
    );

    assert.ok(
      view.getByText(/You need to sign in to manage users/i),
      "guest users should see the authentication prompt",
    );
  });

  it("limits access to owners", async () => {
    const user: CurrentUserProfile = {
      email: "member@example.com",
      name: "Member",
      role: "member",
    };

    const view = render(
      await renderOwnerUsersPage({
        fetchCurrentUser: async () => user,
        fetchUsers: async () => ({ status: "forbidden" }),
      }),
    );

    assert.ok(view.getByText(/limited to workspace owners/i));
  });

  it("renders an error state when the directory cannot load", async () => {
    const user: CurrentUserProfile = {
      email: "owner@example.com",
      name: "Owner",
      role: "owner",
    };

    const view = render(
      await renderOwnerUsersPage({
        fetchCurrentUser: async () => user,
        fetchUsers: async () => ({ status: "error" }),
      }),
    );

    assert.ok(view.getByText(/couldn't load the user directory/i));
  });

  it("renders the user table with role controls", async () => {
    const user: CurrentUserProfile = {
      email: "owner@example.com",
      name: "Owner",
      role: "owner",
    };

    const payload: OwnerUsersPayload = {
      users: [
        {
          id: "user-1",
          email: "owner@example.com",
          role: "owner",
          suspended: false,
          suspendedAt: null,
          insertedAt: "2024-06-01T12:00:00Z",
          updatedAt: "2024-06-02T12:00:00Z",
        },
      ],
      meta: {
        page: 1,
        perPage: 25,
        totalEntries: 1,
      },
    };

    const view = render(
      await renderOwnerUsersPage({
        fetchCurrentUser: async () => user,
        fetchUsers: async () => ({ status: "ok", ...payload }),
        csrfToken: "token-123",
      }),
    );

    assert.ok(view.getByRole("heading", { name: "User management" }));
    assert.ok(view.getByRole("table", { name: /Workspace users/i }));

    const select = view.getByLabelText(/Role for owner@example.com/i) as HTMLSelectElement;
    assert.equal(select.value, "owner");

    const actionButton = view.getByRole("button", { name: /Suspend/i });
    assert.ok(actionButton);
  });
});
