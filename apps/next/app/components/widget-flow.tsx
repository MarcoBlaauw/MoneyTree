'use client';

import React from "react";
import { useCallback, useMemo, useState } from "react";
import {
  DEFAULT_REDACTION_REPLACEMENT,
  DEFAULT_REDACTION_RULES,
  redactSensitiveFields,
} from "../lib/redact";

export type WidgetEventLevel = "info" | "success" | "error";

export interface WidgetEvent {
  id: string;
  level: WidgetEventLevel;
  message: string;
  payload?: unknown;
  timestamp: string;
}

export interface LogWidgetEventOptions {
  level?: WidgetEventLevel;
  payload?: unknown;
}

function generateEventId() {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }

  return Math.random().toString(36).slice(2);
}

export function useWidgetEvents(initial: WidgetEvent[] = []) {
  const [events, setEvents] = useState<WidgetEvent[]>(initial);

  const logEvent = useCallback(
    (message: string, options: LogWidgetEventOptions = {}) => {
      const { level = "info", payload } = options;
      const timestamp = new Date().toISOString();
      const id = generateEventId();
      const redactedPayload =
        payload === undefined
          ? undefined
          : redactSensitiveFields(payload, DEFAULT_REDACTION_RULES, DEFAULT_REDACTION_REPLACEMENT);

      setEvents((existing) => [
        ...existing,
        { id, message, level, payload: redactedPayload, timestamp },
      ]);
    },
    [],
  );

  const clearEvents = useCallback(() => setEvents([]), []);

  return useMemo(
    () => ({
      events,
      logEvent,
      clearEvents,
    }),
    [events, logEvent, clearEvents],
  );
}

const levelStyles: Record<WidgetEventLevel, string> = {
  info: "bg-slate-50 border-slate-200 text-slate-700",
  success: "bg-emerald-50 border-emerald-200 text-emerald-700",
  error: "bg-rose-50 border-rose-200 text-rose-700",
};

export function WidgetEventLog({ events }: { events: WidgetEvent[] }) {
  return (
    <section aria-live="polite" className="card space-y-4" data-testid="widget-event-log">
      <header className="flex items-center justify-between">
        <div>
          <h2 className="text-lg font-semibold text-slate-900">Widget events</h2>
          <p className="text-sm text-slate-500">Payloads are automatically redacted before rendering.</p>
        </div>
        <span className="rounded-full bg-slate-100 px-2 py-1 text-xs font-medium text-slate-600">
          {events.length}
        </span>
      </header>

      {events.length === 0 ? (
        <p className="text-sm text-slate-500">Interact with a widget to see activity here.</p>
      ) : (
        <ol className="space-y-3" data-testid="widget-events">
          {events.map((event) => (
            <li
              key={event.id}
              className={`rounded-md border px-3 py-2 text-sm ${levelStyles[event.level]}`}
            >
              <div className="flex items-center justify-between gap-3">
                <p className="font-medium">{event.message}</p>
                <time className="text-xs font-mono text-slate-500" dateTime={event.timestamp}>
                  {new Date(event.timestamp).toLocaleTimeString()}
                </time>
              </div>
              {event.payload !== undefined ? (
                <pre className="mt-2 overflow-x-auto rounded bg-white/60 p-2 text-xs text-slate-700" data-testid="event-payload">
                  {JSON.stringify(event.payload, null, 2)}
                </pre>
              ) : null}
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}
