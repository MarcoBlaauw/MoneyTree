import React from "react";

import { NotificationToggle } from "./notification-toggle";
import type { ControlPanelSettings } from "../lib/settings";
import { getControlPanelSettings } from "../lib/settings";

function formatDateTime(value: string | null): string {
  if (!value) {
    return "Never";
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

function deriveLastLogin(sessions: ControlPanelSettings["sessions"]): string {
  const latest = sessions.reduce<Date | null>((mostRecent, session) => {
    if (!session.lastUsedAt) {
      return mostRecent;
    }

    const date = new Date(session.lastUsedAt);
    if (Number.isNaN(date.getTime())) {
      return mostRecent;
    }

    if (!mostRecent || date > mostRecent) {
      return date;
    }

    return mostRecent;
  }, null);

  if (!latest) {
    return "Never";
  }

  return new Intl.DateTimeFormat("en-US", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(latest);
}

type ControlPanelContentProps = {
  settings: ControlPanelSettings | null;
};

function ControlPanelContent({ settings }: ControlPanelContentProps) {
  if (!settings) {
    return (
      <main className="bg-background text-foreground min-h-screen">
        <section className="mx-auto flex w-full max-w-5xl flex-col gap-4 px-6 py-16">
          <header className="space-y-2">
            <p className="text-xs font-semibold uppercase tracking-wide text-primary">Owner tools</p>
            <h1 className="text-3xl font-semibold tracking-tight text-foreground">Control panel</h1>
            <p className="text-sm text-zinc-500">
              Sign in to review your profile, manage notification preferences, and audit device sessions.
            </p>
          </header>
          <div className="rounded-xl border border-dashed border-primary/30 bg-white/70 p-6 text-sm text-zinc-600">
            Access to the control panel requires an authenticated MoneyTree session.
          </div>
        </section>
      </main>
    );
  }

  const {
    profile: { displayName, fullName, email, role },
    notifications,
    sessions,
  } = settings;

  const lastLogin = deriveLastLogin(sessions);

  return (
    <main className="bg-background text-foreground min-h-screen">
      <section className="mx-auto flex w-full max-w-5xl flex-col gap-8 px-6 py-16">
        <header className="space-y-3">
          <p className="text-xs font-semibold uppercase tracking-wide text-primary">Owner tools</p>
          <div>
            <h1 className="text-3xl font-semibold tracking-tight text-foreground">Control panel</h1>
            <p className="text-sm text-zinc-500">
              Manage profile information, fine-tune notification preferences, and monitor signed-in devices.
            </p>
          </div>
          <div className="rounded-xl border border-primary/20 bg-primary/5 p-4 text-sm text-primary">
            <p className="font-medium">Signed in as {displayName ?? fullName ?? email ?? "Unknown user"}.</p>
            <p className="text-primary/80">Last login: {lastLogin}</p>
          </div>
        </header>

        <div className="grid gap-6 lg:grid-cols-2">
          <article className="space-y-4 rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm">
            <div className="space-y-1">
              <h2 className="text-lg font-semibold text-zinc-900">Profile</h2>
              <p className="text-sm text-zinc-500">Review the key details tied to your MoneyTree identity.</p>
            </div>
            <dl className="space-y-3 text-sm text-zinc-600">
              <div className="flex items-center justify-between">
                <dt className="font-medium text-zinc-700">Full name</dt>
                <dd className="text-right text-zinc-900">{fullName ?? "Not provided"}</dd>
              </div>
              <div className="flex items-center justify-between">
                <dt className="font-medium text-zinc-700">Email</dt>
                <dd className="text-right text-zinc-900">{email ?? "Unknown"}</dd>
              </div>
              <div className="flex items-center justify-between">
                <dt className="font-medium text-zinc-700">Role</dt>
                <dd className="text-right capitalize text-zinc-900">{role ?? "member"}</dd>
              </div>
            </dl>
          </article>

          <article className="space-y-4 rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm">
            <div className="space-y-1">
              <h2 className="text-lg font-semibold text-zinc-900">Notification preferences</h2>
              <p className="text-sm text-zinc-500">
                Choose which automated alerts MoneyTree should send you. Changes update instantly for this session.
              </p>
            </div>
            <div className="space-y-3">
              <NotificationToggle
                label="Transfer alerts"
                description="Notify me when a transfer is scheduled or requires approval."
                initialValue={notifications.transferAlerts}
                onToggle={async () => {
                  // TODO: Connect to control panel notification update endpoint.
                }}
              />
              <NotificationToggle
                label="Security alerts"
                description="Send alerts for suspicious logins and policy changes."
                initialValue={notifications.securityAlerts}
                onToggle={async () => {
                  // TODO: Connect to control panel notification update endpoint.
                }}
              />
            </div>
          </article>

          <article className="space-y-4 rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm lg:col-span-2">
            <div className="space-y-1">
              <h2 className="text-lg font-semibold text-zinc-900">Active sessions</h2>
              <p className="text-sm text-zinc-500">
                Track which devices are authenticated. Sign out of any unfamiliar sessions from the Phoenix app.
              </p>
            </div>
            <div className="overflow-x-auto">
              <table className="w-full table-auto text-left text-sm" aria-label="Active sessions">
                <thead>
                  <tr className="border-b border-zinc-200 text-xs uppercase tracking-wide text-zinc-500">
                    <th className="py-2 pr-4">Context</th>
                    <th className="py-2 pr-4">Last used</th>
                    <th className="py-2 pr-4">IP address</th>
                    <th className="py-2">User agent</th>
                  </tr>
                </thead>
                <tbody>
                  {sessions.map((session) => (
                    <tr key={session.id} className="border-b border-zinc-100">
                      <td className="py-2 pr-4 font-medium text-zinc-800">{session.context}</td>
                      <td className="py-2 pr-4 text-zinc-600">{formatDateTime(session.lastUsedAt)}</td>
                      <td className="py-2 pr-4 text-zinc-600">{session.ipAddress ?? "Unknown"}</td>
                      <td className="py-2 text-zinc-600">{session.userAgent ?? "Unknown"}</td>
                    </tr>
                  ))}
                  {sessions.length === 0 ? (
                    <tr>
                      <td colSpan={4} className="py-6 text-center text-zinc-500">
                        No active sessions recorded.
                      </td>
                    </tr>
                  ) : null}
                </tbody>
              </table>
            </div>
          </article>
        </div>
      </section>
    </main>
  );
}

type SettingsFetcher = () => Promise<ControlPanelSettings | null>;

export async function renderControlPanelPage(
  fetchSettings: SettingsFetcher = getControlPanelSettings,
) {
  const settings = await fetchSettings();
  return <ControlPanelContent settings={settings} />;
}

export default async function ControlPanelPage() {
  return renderControlPanelPage();
}
