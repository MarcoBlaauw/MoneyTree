import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

const Hooks = window.MoneyTreeHooks || {};

const decodeBase64Url = (value) => {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padding = normalized.length % 4 === 0 ? "" : "=".repeat(4 - (normalized.length % 4));
  const binary = window.atob(normalized + padding);
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
};

const encodeBase64Url = (value) => {
  const bytes =
    value instanceof ArrayBuffer
      ? new Uint8Array(value)
      : value instanceof Uint8Array
        ? value
        : new Uint8Array(value.buffer || value);

  let binary = "";
  bytes.forEach((byte) => {
    binary += String.fromCharCode(byte);
  });

  return window.btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
};

const csrfHeaders = () => ({
  "content-type": "application/json",
  "x-csrf-token": csrfToken
});

const createCredentialOptions = (options) => {
  const mapped = {
    ...options,
    challenge: decodeBase64Url(options.challenge),
    user: {
      ...options.user,
      id: decodeBase64Url(options.user.id)
    },
    excludeCredentials: (options.excludeCredentials || []).map((credential) => ({
      ...credential,
      id: decodeBase64Url(credential.id)
    }))
  };

  return mapped;
};

const createAssertionOptions = (options) => ({
  ...options,
  challenge: decodeBase64Url(options.challenge),
  allowCredentials: (options.allowCredentials || []).map((credential) => ({
    ...credential,
    id: decodeBase64Url(credential.id)
  }))
});

const defaultCredentialLabel = (kind) => {
  const browser =
    /firefox/i.test(navigator.userAgent)
      ? "Firefox"
      : /edg/i.test(navigator.userAgent)
        ? "Edge"
        : /chrome|chromium|crios/i.test(navigator.userAgent)
          ? "Chrome"
          : /safari/i.test(navigator.userAgent)
            ? "Safari"
            : "Browser";

  return kind === "security_key" ? `${browser} security key` : `${browser} passkey`;
};

const serializeRegistration = (credential, challengeId, label, kind) => ({
  id: encodeBase64Url(credential.rawId),
  type: credential.type,
  challenge_id: challengeId,
  label,
  kind,
  transports: credential.response.getTransports ? credential.response.getTransports() : [],
  response: {
    attestationObject: encodeBase64Url(credential.response.attestationObject),
    clientDataJSON: encodeBase64Url(credential.response.clientDataJSON)
  }
});

const serializeAssertion = (assertion, challengeId, email) => ({
  email,
  challenge_id: challengeId,
  id: encodeBase64Url(assertion.rawId),
  type: assertion.type,
  response: {
    authenticatorData: encodeBase64Url(assertion.response.authenticatorData),
    clientDataJSON: encodeBase64Url(assertion.response.clientDataJSON),
    signature: encodeBase64Url(assertion.response.signature),
    userHandle: assertion.response.userHandle
      ? encodeBase64Url(assertion.response.userHandle)
      : null
  }
});

const mountSecurityPasskeys = (root) => {
  if (!root || root.dataset.webauthnMounted === "true") {
    return null;
  }

  root.dataset.webauthnMounted = "true";

  const statusNode = root.querySelector("[data-webauthn-status]");
  const setStatus = (message) => {
    if (statusNode) {
      statusNode.textContent = message;
    }
  };

  const registerCredential = async (kind) => {
    if (!window.PublicKeyCredential || !navigator.credentials?.create) {
      setStatus("This browser does not support passkey registration.");
      return;
    }

    setStatus(`Starting ${kind === "security_key" ? "security key" : "passkey"} registration...`);

    try {
      const optionsResponse = await fetch("/api/settings/security/webauthn/registration-options", {
        method: "POST",
        credentials: "same-origin",
        headers: csrfHeaders(),
        body: JSON.stringify({ kind })
      });

      const optionsPayload = await optionsResponse.json();

      if (!optionsResponse.ok) {
        throw new Error(optionsPayload.error || "Unable to start WebAuthn registration.");
      }

      const publicKey = createCredentialOptions(optionsPayload.data.options);
      const credential = await navigator.credentials.create({ publicKey });

      const label = defaultCredentialLabel(kind);

      const registerResponse = await fetch("/api/settings/security/webauthn/register", {
        method: "POST",
        credentials: "same-origin",
        headers: csrfHeaders(),
        body: JSON.stringify(
          serializeRegistration(credential, optionsPayload.data.challenge.id, label, kind)
        )
      });

      const registerPayload = await registerResponse.json();

      if (!registerResponse.ok) {
        throw new Error(registerPayload.error || "Unable to register credential.");
      }

      setStatus("Credential registered.");
      window.location.reload();
    } catch (error) {
      setStatus(error.message || "Unable to register credential.");
    }
  };

  const revokeCredential = async (id) => {
    setStatus("Removing credential...");

    try {
      const response = await fetch(`/api/settings/security/webauthn/credentials/${id}`, {
        method: "DELETE",
        credentials: "same-origin",
        headers: {
          "x-csrf-token": csrfToken
        }
      });

      if (!response.ok) {
        const payload = await response.json();
        throw new Error(payload.error || "Unable to remove credential.");
      }

      setStatus("Credential removed.");
      window.location.reload();
    } catch (error) {
      setStatus(error.message || "Unable to remove credential.");
    }
  };

  const handleClick = async (event) => {
    const registerButton = event.target.closest("[data-register-webauthn]");
    const revokeButton = event.target.closest("[data-revoke-webauthn]");

    if (registerButton) {
      event.preventDefault();
      await registerCredential(registerButton.dataset.registerWebauthn);
    }

    if (revokeButton) {
      event.preventDefault();
      await revokeCredential(revokeButton.dataset.revokeWebauthn);
    }
  };

  root.addEventListener("click", handleClick);

  return () => {
    root.removeEventListener("click", handleClick);
    delete root.dataset.webauthnMounted;
  };
};

Hooks.SecurityPasskeys = {
  mounted() {
    this.cleanup = mountSecurityPasskeys(this.el);
  },

  destroyed() {
    this.cleanup?.();
  }
};

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  params: {
    _csrf_token: csrfToken
  }
});

liveSocket.connect();

window.LiveSocket = liveSocket;
window.MoneyTreeHooks = Hooks;

const scrollIntoViewById = (id, attempt = 0) => {
  const target = document.getElementById(id);

  if (!target) {
    if (attempt < 5) {
      window.requestAnimationFrame(() => scrollIntoViewById(id, attempt + 1));
    }

    return;
  }

  target.scrollIntoView({ behavior: "smooth", block: "start" });

  try {
    target.focus({ preventScroll: true });
  } catch (_error) {
    target.focus();
  }
};

window.addEventListener("phx:scroll-into-view", (event) => {
  const id = event.detail?.id;

  if (id) {
    scrollIntoViewById(id);
  }
});

const mountLoginPasskeys = () => {
  const root = document.querySelector("[data-webauthn-login]");

  if (!root) {
    return;
  }

  const form = root.querySelector("[data-webauthn-login-form]");
  const status = root.querySelector("[data-webauthn-login-status]");

  if (!form) {
    return;
  }

  const setStatus = (message) => {
    if (status) {
      status.textContent = message;
    }
  };

  form.addEventListener("submit", async (event) => {
    event.preventDefault();

    const email = new FormData(form).get("email")?.toString().trim();

    if (!email) {
      setStatus("Email is required.");
      return;
    }

    setStatus("Starting passkey sign-in...");

    try {
      const optionsResponse = await fetch("/login/webauthn/options", {
        method: "POST",
        credentials: "same-origin",
        headers: csrfHeaders(),
        body: JSON.stringify({ webauthn: { email } })
      });

      const optionsPayload = await optionsResponse.json();

      if (!optionsResponse.ok) {
        throw new Error(optionsPayload.error || "Unable to start passkey sign-in.");
      }

      const assertion = await navigator.credentials.get({
        publicKey: createAssertionOptions(optionsPayload.data.options)
      });

      const verifyResponse = await fetch("/login/webauthn", {
        method: "POST",
        credentials: "same-origin",
        headers: csrfHeaders(),
        body: JSON.stringify({
          webauthn: serializeAssertion(assertion, optionsPayload.data.challenge.id, email)
        })
      });

      const verifyPayload = await verifyResponse.json();

      if (!verifyResponse.ok) {
        throw new Error(verifyPayload.error || "Unable to verify passkey sign-in.");
      }

      window.location.assign(verifyPayload.data.redirect_to || "/app");
    } catch (error) {
      setStatus(error.message || "Unable to verify passkey sign-in.");
    }
  });
};

const mountSecurityPasskeysFromDom = () => {
  document.querySelectorAll("#security-settings").forEach((root) => mountSecurityPasskeys(root));
};

document.addEventListener("DOMContentLoaded", mountLoginPasskeys);
document.addEventListener("DOMContentLoaded", mountSecurityPasskeysFromDom);
window.addEventListener("phx:page-loading-stop", mountSecurityPasskeysFromDom);

export { Hooks, liveSocket };
