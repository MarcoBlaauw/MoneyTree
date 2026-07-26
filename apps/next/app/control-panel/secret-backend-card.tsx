'use client';

import React, { useState } from 'react';

import type { SecretBackendStatus } from '../lib/secret-backend';
import { resolveSecretBackendPayload } from '../lib/secret-backend';

type SecretBackendCardProps = {
  csrfToken: string;
  initialStatus: SecretBackendStatus;
};

type RefreshState =
  | { status: 'idle'; message: string }
  | { status: 'loading'; message: string }
  | { status: 'ok'; message: string }
  | { status: 'error'; message: string };

function statusClass(status: string): string {
  switch (status) {
    case 'configured':
      return 'bg-emerald-50 text-emerald-700 ring-emerald-200';
    case 'partial':
    case 'not_checked':
      return 'bg-amber-50 text-amber-700 ring-amber-200';
    case 'error':
    case 'missing':
    case 'not_configured':
      return 'bg-rose-50 text-rose-700 ring-rose-200';
    default:
      return 'bg-zinc-100 text-zinc-700 ring-zinc-200';
  }
}

function labelForStatus(status: string): string {
  return status
    .split('_')
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ');
}

export function SecretBackendCard({ csrfToken, initialStatus }: SecretBackendCardProps) {
  const [status, setStatus] = useState(initialStatus);
  const [refreshState, setRefreshState] = useState<RefreshState>({
    status: 'idle',
    message: status.live ? 'Live validation has run.' : 'Status loaded.',
  });

  async function revalidate() {
    setRefreshState({ status: 'loading', message: 'Checking backend...' });

    try {
      const response = await fetch('/api/owner/security/secret-backend/revalidate', {
        method: 'POST',
        credentials: 'include',
        headers: {
          accept: 'application/json',
          'content-type': 'application/json',
          'x-csrf-token': csrfToken,
        },
      });

      if (!response.ok) {
        throw new Error('Unable to revalidate secret backend.');
      }

      const payload = (await response.json().catch(() => null)) as unknown;
      const resolved = resolveSecretBackendPayload(payload);

      if (!resolved) {
        throw new Error('Secret backend response was invalid.');
      }

      setStatus(resolved);
      setRefreshState({ status: 'ok', message: 'Secret backend revalidated.' });
    } catch (error) {
      setRefreshState({
        status: 'error',
        message: error instanceof Error ? error.message : 'Secret backend check failed.',
      });
    }
  }

  return (
    <article className="space-y-4 rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm lg:col-span-2">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="space-y-1">
          <h2 className="text-lg font-semibold text-zinc-900">Secret backend</h2>
          <p className="text-sm text-zinc-500">
            {status.backend} mode selected by {status.selectedBy}.
          </p>
        </div>
        <div className="flex items-center gap-3">
          <span
            className={`inline-flex rounded-full px-3 py-1 text-xs font-semibold ring-1 ${statusClass(
              status.status,
            )}`}
          >
            {labelForStatus(status.status)}
          </span>
          <button
            type="button"
            onClick={revalidate}
            disabled={refreshState.status === 'loading'}
            className="rounded-full border border-primary/30 px-4 py-2 text-xs font-semibold uppercase tracking-wide text-primary transition hover:border-primary disabled:cursor-not-allowed disabled:opacity-60"
          >
            Revalidate
          </button>
        </div>
      </div>

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {status.groups.map((group) => (
          <div key={group.name} className="rounded-xl border border-zinc-100 bg-zinc-50 p-4">
            <div className="flex items-center justify-between gap-3">
              <h3 className="text-sm font-semibold capitalize text-zinc-900">{group.name}</h3>
              <span
                className={`inline-flex rounded-full px-2 py-1 text-[11px] font-semibold ring-1 ${statusClass(
                  group.status,
                )}`}
              >
                {labelForStatus(group.status)}
              </span>
            </div>
            <p className="mt-2 text-sm text-zinc-600">
              {group.presentKeys} present
              {group.missingKeys.length > 0 ? `, ${group.missingKeys.length} missing` : ''}
            </p>
            {group.missingKeys.length > 0 ? (
              <p className="mt-1 break-words text-xs text-zinc-500">
                Missing: {group.missingKeys.join(', ')}
              </p>
            ) : null}
            {group.errors.length > 0 ? (
              <p className="mt-1 break-words text-xs text-rose-600">{group.errors.join('; ')}</p>
            ) : null}
          </div>
        ))}
      </div>

      <p
        className={`text-sm ${refreshState.status === 'error' ? 'text-rose-600' : 'text-zinc-500'}`}
        role="status"
      >
        {refreshState.message}
      </p>
    </article>
  );
}
