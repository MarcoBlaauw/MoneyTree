import { resolveSecretBackendPayload, type SecretBackendStatus } from './secret-backend';
import { fetchWithSession } from './session-fetch';

export async function getSecretBackendStatus(): Promise<SecretBackendStatus | null> {
  const response = await fetchWithSession('/api/owner/security/secret-backend');

  if (!response || response.status === 401 || response.status === 403 || !response.ok) {
    return null;
  }

  const payload = (await response.json().catch(() => null)) as unknown;
  return resolveSecretBackendPayload(payload);
}
