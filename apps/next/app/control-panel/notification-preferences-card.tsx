"use client";

import React, { useEffect, useState } from "react";

import { NotificationToggle } from "./notification-toggle";
import type { ControlPanelSettings } from "../lib/settings";

type NotificationPreferences = ControlPanelSettings["notifications"];

type NotificationPreferencesCardProps = {
  csrfToken: string;
  initialNotifications: NotificationPreferences;
};

type SaveState =
  | { status: "idle" }
  | { status: "saving" }
  | { status: "saved"; message: string }
  | { status: "error"; message: string };

function normalizeNotifications(payload: unknown, fallback: NotificationPreferences): NotificationPreferences {
  if (!payload || typeof payload !== "object") {
    return fallback;
  }

  const notifications = payload as Record<string, unknown>;

  return {
    emailEnabled:
      typeof notifications.email_enabled === "boolean"
        ? notifications.email_enabled
        : fallback.emailEnabled,
    smsEnabled:
      typeof notifications.sms_enabled === "boolean" ? notifications.sms_enabled : fallback.smsEnabled,
    pushEnabled:
      typeof notifications.push_enabled === "boolean"
        ? notifications.push_enabled
        : fallback.pushEnabled,
    dashboardEnabled:
      typeof notifications.dashboard_enabled === "boolean"
        ? notifications.dashboard_enabled
        : fallback.dashboardEnabled,
    upcomingEnabled:
      typeof notifications.upcoming_enabled === "boolean"
        ? notifications.upcoming_enabled
        : fallback.upcomingEnabled,
    dueTodayEnabled:
      typeof notifications.due_today_enabled === "boolean"
        ? notifications.due_today_enabled
        : fallback.dueTodayEnabled,
    overdueEnabled:
      typeof notifications.overdue_enabled === "boolean"
        ? notifications.overdue_enabled
        : fallback.overdueEnabled,
    recoveredEnabled:
      typeof notifications.recovered_enabled === "boolean"
        ? notifications.recovered_enabled
        : fallback.recoveredEnabled,
    upcomingLeadDays:
      typeof notifications.upcoming_lead_days === "number"
        ? notifications.upcoming_lead_days
        : fallback.upcomingLeadDays,
    resendIntervalHours:
      typeof notifications.resend_interval_hours === "number"
        ? notifications.resend_interval_hours
        : fallback.resendIntervalHours,
    maxResends:
      typeof notifications.max_resends === "number" ? notifications.max_resends : fallback.maxResends,
  };
}

function serializeNotifications(notifications: NotificationPreferences) {
  return {
    email_enabled: notifications.emailEnabled,
    sms_enabled: notifications.smsEnabled,
    push_enabled: notifications.pushEnabled,
    dashboard_enabled: notifications.dashboardEnabled,
    upcoming_enabled: notifications.upcomingEnabled,
    due_today_enabled: notifications.dueTodayEnabled,
    overdue_enabled: notifications.overdueEnabled,
    recovered_enabled: notifications.recoveredEnabled,
    upcoming_lead_days: notifications.upcomingLeadDays,
    resend_interval_hours: notifications.resendIntervalHours,
    max_resends: notifications.maxResends,
  };
}

export function NotificationPreferencesCard({
  csrfToken,
  initialNotifications,
}: NotificationPreferencesCardProps) {
  const [notifications, setNotifications] = useState(initialNotifications);
  const [saveState, setSaveState] = useState<SaveState>({ status: "idle" });

  useEffect(() => {
    setNotifications(initialNotifications);
  }, [initialNotifications]);

  async function updateNotifications(nextNotifications: NotificationPreferences) {
    setSaveState({ status: "saving" });

    const response = await fetch("/api/settings/notifications", {
      method: "PUT",
      credentials: "include",
      headers: {
        "content-type": "application/json",
        "x-csrf-token": csrfToken,
      },
      body: JSON.stringify({
        notifications: serializeNotifications(nextNotifications),
      }),
    });

    if (!response.ok) {
      const errorPayload = (await response.json().catch(() => null)) as unknown;

      if (
        errorPayload &&
        typeof errorPayload === "object" &&
        "error" in errorPayload &&
        typeof (errorPayload as Record<string, unknown>).error === "string"
      ) {
        throw new Error((errorPayload as Record<string, string>).error);
      }

      throw new Error("We couldn't update your notification preferences.");
    }

    const payload = (await response.json().catch(() => null)) as
      | { data?: { notifications?: unknown } }
      | null;

    const resolvedNotifications = normalizeNotifications(
      payload?.data?.notifications,
      nextNotifications,
    );

    setNotifications(resolvedNotifications);
    setSaveState({ status: "saved", message: "Notification preferences updated." });
  }

  async function handleToggle(key: "emailEnabled" | "dashboardEnabled", value: boolean) {
    const previousNotifications = notifications;
    const nextNotifications = {
      ...previousNotifications,
      [key]: value,
    };

    setNotifications(nextNotifications);

    try {
      await updateNotifications(nextNotifications);
    } catch (error) {
      setNotifications(previousNotifications);
      setSaveState({
        status: "error",
        message:
          error instanceof Error
            ? error.message
            : "We couldn't update your notification preferences.",
      });
      throw error;
    }
  }

  return (
    <article className="space-y-4 rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm">
      <div className="space-y-1">
        <h2 className="text-lg font-semibold text-zinc-900">Notification preferences</h2>
        <p className="text-sm text-zinc-500">
          Choose which automated alerts MoneyTree should send you. Changes update instantly for this session.
        </p>
      </div>
      <div className="space-y-3">
        <NotificationToggle
          label="Email delivery"
          description="Send durable payment-obligation alerts to my email inbox."
          initialValue={notifications.emailEnabled}
          onToggle={async (value) => {
            await handleToggle("emailEnabled", value);
          }}
        />
        <NotificationToggle
          label="Dashboard alerts"
          description="Show durable obligation alerts inside the dashboard notification feed."
          initialValue={notifications.dashboardEnabled}
          onToggle={async (value) => {
            await handleToggle("dashboardEnabled", value);
          }}
        />
      </div>
      <p
        aria-live="polite"
        className={`text-sm ${
          saveState.status === "error"
            ? "text-rose-600"
            : saveState.status === "saved"
              ? "text-emerald-700"
              : "text-zinc-500"
        }`}
      >
        {saveState.status === "saving"
          ? "Saving notification preferences..."
          : saveState.status === "idle"
            ? "Preference changes will be saved immediately."
            : saveState.message}
      </p>
    </article>
  );
}
