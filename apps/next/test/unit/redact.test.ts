import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { DEFAULT_REDACTION_REPLACEMENT, redactSensitiveFields } from "../../app/lib/redact";

describe("redactSensitiveFields", () => {
  it("redacts keys that match default rules", () => {
    const payload = {
      link_token: "link-sandbox-1234567890",
      secret: "shh",
      nested: {
        account_number: "123456789",
      },
    };

    const result = redactSensitiveFields(payload);

    assert.equal(result.link_token, `${DEFAULT_REDACTION_REPLACEMENT}7890`);
    assert.equal(result.secret, DEFAULT_REDACTION_REPLACEMENT);
    assert.equal(result.nested.account_number, `${DEFAULT_REDACTION_REPLACEMENT}6789`);
    assert.equal(payload.link_token, "link-sandbox-1234567890", "original payload remains untouched");
  });

  it("preserves non-sensitive fields", () => {
    const payload = {
      status: "ok",
      counts: [1, 2, 3],
    };

    const result = redactSensitiveFields(payload);

    assert.deepEqual(result, payload);
  });
});
