import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  resolveOwnerUsersPayload,
  resolveOwnerUserFromResponse,
  type OwnerUsersPayload,
} from "../../app/lib/owner-users";

describe("resolveOwnerUsersPayload", () => {
  it("parses a well-formed payload", () => {
    const payload = {
      data: [
        {
          id: "user-1",
          email: "owner@example.com",
          role: "owner",
          suspended: false,
          suspended_at: null,
          inserted_at: "2024-07-04T15:00:00Z",
          updated_at: "2024-07-05T10:00:00Z",
        },
      ],
      meta: {
        page: 1,
        per_page: 20,
        total_entries: 1,
      },
    } satisfies Record<string, unknown>;

    const result = resolveOwnerUsersPayload(payload);
    assert.ok(result, "payload should be parsed");
    assert.deepEqual(result?.meta, {
      page: 1,
      perPage: 20,
      totalEntries: 1,
    } satisfies OwnerUsersPayload["meta"]);
    assert.equal(result?.users.length, 1);
    assert.deepEqual(result?.users[0], {
      id: "user-1",
      email: "owner@example.com",
      role: "owner",
      suspended: false,
      suspendedAt: null,
      insertedAt: "2024-07-04T15:00:00Z",
      updatedAt: "2024-07-05T10:00:00Z",
    });
  });

  it("returns null when meta is invalid", () => {
    const payload = {
      data: [],
      meta: {
        page: "one",
        per_page: "twenty",
        total_entries: null,
      },
    };

    assert.equal(resolveOwnerUsersPayload(payload), null);
  });
});

describe("resolveOwnerUserFromResponse", () => {
  it("handles nested data keys", () => {
    const payload = {
      data: {
        id: "user-2",
        email: "member@example.com",
        role: "member",
        suspended: true,
        suspended_at: "2024-06-01T12:00:00Z",
        inserted_at: null,
        updated_at: "2024-06-02T12:00:00Z",
      },
    };

    const result = resolveOwnerUserFromResponse(payload);
    assert.ok(result);
    assert.equal(result?.suspended, true);
    assert.equal(result?.suspendedAt, "2024-06-01T12:00:00Z");
  });

  it("returns null when payload cannot be parsed", () => {
    assert.equal(resolveOwnerUserFromResponse({}), null);
    assert.equal(resolveOwnerUserFromResponse(null), null);
  });
});
