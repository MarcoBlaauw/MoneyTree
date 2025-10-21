"use client";

import React, { useEffect, useState } from "react";

type NotificationToggleProps = {
  label: string;
  description?: string;
  initialValue: boolean;
  onToggle?: (value: boolean) => Promise<void> | void;
};

export function NotificationToggle({
  label,
  description,
  initialValue,
  onToggle,
}: NotificationToggleProps) {
  const [optimisticValue, setOptimisticValue] = useState(initialValue);

  useEffect(() => {
    setOptimisticValue(initialValue);
  }, [initialValue]);

  async function handleToggle() {
    const previousValue = optimisticValue;
    const nextValue = !previousValue;

    setOptimisticValue(nextValue);

    try {
      await onToggle?.(nextValue);
    } catch {
      setOptimisticValue(previousValue);
      // TODO: Surface an error toast once the notification preference API is connected.
    }
  }

  return (
    <button
      type="button"
      role="switch"
      aria-checked={optimisticValue}
      onClick={() => {
        void handleToggle();
      }}
      className={`flex w-full items-center justify-between rounded-xl border px-4 py-3 text-left transition focus:outline-none focus:ring-2 focus:ring-primary/60 focus:ring-offset-2 focus:ring-offset-background ${optimisticValue ? "border-emerald-400 bg-emerald-50/80" : "border-zinc-200 bg-white"}`}
    >
      <span className="flex-1">
        <span className="block text-sm font-semibold text-zinc-800">{label}</span>
        {description ? (
          <span className="mt-1 block text-xs text-zinc-500">{description}</span>
        ) : null}
      </span>
      <span
        aria-hidden
        className={`relative ml-4 inline-flex h-6 w-11 items-center rounded-full transition-colors ${optimisticValue ? "bg-emerald-500" : "bg-zinc-300"}`}
      >
        <span
          className={`inline-block h-5 w-5 transform rounded-full bg-white shadow transition-transform ${optimisticValue ? "translate-x-5" : "translate-x-1"}`}
        />
      </span>
    </button>
  );
}
