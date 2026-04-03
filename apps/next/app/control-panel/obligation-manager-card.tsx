"use client";

import React, { useEffect, useState } from "react";

import type {
  ControlPanelObligation,
  FundingAccountOption,
} from "../lib/obligations";

type ObligationManagerCardProps = {
  csrfToken: string;
  fundingAccounts: FundingAccountOption[];
  initialObligations: ControlPanelObligation[];
};

type FormState = {
  creditorPayee: string;
  dueRule: "calendar_day" | "last_day_of_month";
  dueDay: string;
  minimumDueAmount: string;
  gracePeriodDays: string;
  linkedFundingAccountId: string;
  active: boolean;
};

type SaveState =
  | { status: "idle"; message: string }
  | { status: "saving"; message: string }
  | { status: "saved"; message: string }
  | { status: "error"; message: string };

const EMPTY_FORM: FormState = {
  creditorPayee: "",
  dueRule: "calendar_day",
  dueDay: "15",
  minimumDueAmount: "75.00",
  gracePeriodDays: "2",
  linkedFundingAccountId: "",
  active: true,
};

function formatDueRule(obligation: ControlPanelObligation): string {
  if (obligation.dueRule === "last_day_of_month") {
    return "Last day of month";
  }

  return obligation.dueDay ? `Day ${obligation.dueDay}` : "Calendar day";
}

function resolveInitialForm(
  fundingAccounts: FundingAccountOption[],
  obligation?: ControlPanelObligation | null,
): FormState {
  if (obligation) {
    return {
      creditorPayee: obligation.creditorPayee,
      dueRule:
        obligation.dueRule === "last_day_of_month"
          ? "last_day_of_month"
          : "calendar_day",
      dueDay: obligation.dueDay ? String(obligation.dueDay) : "31",
      minimumDueAmount: obligation.minimumDueAmount,
      gracePeriodDays: String(obligation.gracePeriodDays),
      linkedFundingAccountId: obligation.linkedFundingAccountId,
      active: obligation.active,
    };
  }

  return {
    ...EMPTY_FORM,
    linkedFundingAccountId: fundingAccounts[0]?.id ?? "",
  };
}

function buildRequestBodyFromForm(
  formElement: HTMLFormElement,
  currentState: FormState,
) {
  const FormDataCtor =
    formElement.ownerDocument?.defaultView?.FormData ?? FormData;
  const formData = new FormDataCtor(formElement);
  const dueRule =
    formData.get("due_rule") === "last_day_of_month"
      ? "last_day_of_month"
      : "calendar_day";

  return {
    creditor_payee: String(formData.get("creditor_payee") ?? "").trim(),
    due_rule: dueRule,
    due_day:
      dueRule === "calendar_day"
        ? Number(formData.get("due_day") ?? currentState.dueDay)
        : null,
    minimum_due_amount: String(
      formData.get("minimum_due_amount") ?? currentState.minimumDueAmount,
    ),
    grace_period_days: Number(
      formData.get("grace_period_days") ?? currentState.gracePeriodDays,
    ),
    linked_funding_account_id: String(
      formData.get("linked_funding_account_id") ?? currentState.linkedFundingAccountId,
    ),
    active: formData.get("active") === "on",
  };
}

function parseObligation(payload: unknown): ControlPanelObligation | null {
  if (!payload || typeof payload !== "object") {
    return null;
  }

  const root = payload as Record<string, unknown>;
  const data =
    root.data && typeof root.data === "object"
      ? (root.data as Record<string, unknown>)
      : null;

  if (
    !data ||
    typeof data.id !== "string" ||
    typeof data.creditor_payee !== "string" ||
    typeof data.due_rule !== "string" ||
    typeof data.currency !== "string" ||
    typeof data.linked_funding_account_id !== "string"
  ) {
    return null;
  }

  const linkedFundingAccount =
    data.linked_funding_account && typeof data.linked_funding_account === "object"
      ? (data.linked_funding_account as Record<string, unknown>)
      : null;

  return {
    id: data.id,
    creditorPayee: data.creditor_payee,
    dueDay:
      typeof data.due_day === "number"
        ? data.due_day
        : typeof data.due_day === "string"
          ? Number(data.due_day)
          : null,
    dueRule: data.due_rule,
    minimumDueAmount: String(data.minimum_due_amount),
    currency: data.currency,
    gracePeriodDays:
      typeof data.grace_period_days === "number"
        ? data.grace_period_days
        : Number(data.grace_period_days),
    active: typeof data.active === "boolean" ? data.active : true,
    linkedFundingAccountId: data.linked_funding_account_id,
    linkedFundingAccountName:
      linkedFundingAccount && typeof linkedFundingAccount.name === "string"
        ? linkedFundingAccount.name
        : null,
  };
}

function buildFallbackObligation(
  payload: ReturnType<typeof buildRequestBodyFromForm>,
  fundingAccounts: FundingAccountOption[],
  id: string,
): ControlPanelObligation {
  const linkedFundingAccount = fundingAccounts.find(
    (account) => account.id === payload.linked_funding_account_id,
  );

  return {
    id,
    creditorPayee: payload.creditor_payee,
    dueDay: payload.due_day,
    dueRule: payload.due_rule,
    minimumDueAmount: payload.minimum_due_amount,
    currency: linkedFundingAccount?.currency ?? "USD",
    gracePeriodDays: payload.grace_period_days,
    active: payload.active,
    linkedFundingAccountId: payload.linked_funding_account_id,
    linkedFundingAccountName: linkedFundingAccount?.name ?? null,
  };
}

export function ObligationManagerCard({
  csrfToken,
  fundingAccounts,
  initialObligations,
}: ObligationManagerCardProps) {
  const [obligations, setObligations] = useState(initialObligations);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [form, setForm] = useState<FormState>(() =>
    resolveInitialForm(fundingAccounts, null),
  );
  const [saveState, setSaveState] = useState<SaveState>({
    status: "idle",
    message: "Create, edit, or remove obligations tied to your linked funding accounts.",
  });
  const [pendingId, setPendingId] = useState<string | null>(null);

  useEffect(() => {
    setObligations(initialObligations);
  }, [initialObligations]);

  useEffect(() => {
    if (!editingId) {
      setForm(resolveInitialForm(fundingAccounts, null));
    }
  }, [editingId, fundingAccounts]);

  function setField<K extends keyof FormState>(key: K, value: FormState[K]) {
    setForm((current) => ({ ...current, [key]: value }));
  }

  function beginEdit(obligation: ControlPanelObligation) {
    setEditingId(obligation.id);
    setForm(resolveInitialForm(fundingAccounts, obligation));
    setSaveState({ status: "idle", message: `Editing ${obligation.creditorPayee}.` });
  }

  function resetForm() {
    setEditingId(null);
    setForm(resolveInitialForm(fundingAccounts, null));
    setSaveState({
      status: "idle",
      message: "Create, edit, or remove obligations tied to your linked funding accounts.",
    });
  }

  async function submitForm(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSaveState({ status: "saving", message: "Saving obligation..." });

    const method = editingId ? "PUT" : "POST";
    const endpoint = editingId
      ? `/api/obligations/${encodeURIComponent(editingId)}`
      : "/api/obligations";
    const requestBody = buildRequestBodyFromForm(event.currentTarget, form);

    try {
      const response = await fetch(endpoint, {
        method,
        credentials: "include",
        headers: {
          "content-type": "application/json",
          "x-csrf-token": csrfToken,
        },
        body: JSON.stringify(requestBody),
      });

      if (!response.ok) {
        const payload = (await response.json().catch(() => null)) as
          | { error?: string; errors?: Record<string, string[] | string> }
          | null;

        if (payload?.error) {
          throw new Error(payload.error);
        }

        if (payload?.errors && typeof payload.errors === "object") {
          const firstMessage = Object.values(payload.errors)[0];

          if (Array.isArray(firstMessage) && typeof firstMessage[0] === "string") {
            throw new Error(firstMessage[0]);
          }

          if (typeof firstMessage === "string") {
            throw new Error(firstMessage);
          }
        }

        throw new Error("We couldn't save this obligation.");
      }

      const payload = (await response.json().catch(() => null)) as unknown;
      const obligation =
        parseObligation(payload) ??
        buildFallbackObligation(
          requestBody,
          fundingAccounts,
          editingId ?? `obligation-${Date.now()}`,
        );

      setObligations((current) => {
        if (editingId) {
          return current.map((item) => (item.id === obligation.id ? obligation : item));
        }

        return [...current, obligation].sort((a, b) =>
          a.creditorPayee.localeCompare(b.creditorPayee, undefined, {
            sensitivity: "base",
          }),
        );
      });

      setEditingId(null);
      setForm(resolveInitialForm(fundingAccounts, null));
      setSaveState({
        status: "saved",
        message: editingId
          ? "Obligation updated."
          : "Obligation created.",
      });
    } catch (error) {
      setSaveState({
        status: "error",
        message:
          error instanceof Error
            ? error.message
            : "We couldn't save this obligation.",
      });
    }
  }

  async function deleteObligation(id: string) {
    setPendingId(id);
    setSaveState({ status: "saving", message: "Deleting obligation..." });

    try {
      const response = await fetch(`/api/obligations/${encodeURIComponent(id)}`, {
        method: "DELETE",
        credentials: "include",
        headers: {
          "x-csrf-token": csrfToken,
        },
      });

      if (!response.ok) {
        throw new Error("We couldn't delete this obligation.");
      }

      setObligations((current) => current.filter((item) => item.id !== id));

      if (editingId === id) {
        resetForm();
      }

      setSaveState({ status: "saved", message: "Obligation deleted." });
    } catch (error) {
      setSaveState({
        status: "error",
        message:
          error instanceof Error
            ? error.message
            : "We couldn't delete this obligation.",
      });
    } finally {
      setPendingId(null);
    }
  }

  async function toggleActive(obligation: ControlPanelObligation) {
    setPendingId(obligation.id);
    setSaveState({ status: "saving", message: "Updating obligation..." });

    const optimistic = { ...obligation, active: !obligation.active };
    setObligations((current) =>
      current.map((item) => (item.id === obligation.id ? optimistic : item)),
    );

    try {
      const response = await fetch(`/api/obligations/${encodeURIComponent(obligation.id)}`, {
        method: "PUT",
        credentials: "include",
        headers: {
          "content-type": "application/json",
          "x-csrf-token": csrfToken,
        },
        body: JSON.stringify({ active: optimistic.active }),
      });

      if (!response.ok) {
        throw new Error("We couldn't update this obligation.");
      }

      const payload = (await response.json().catch(() => null)) as unknown;
      const updated = parseObligation(payload);

      if (!updated) {
        throw new Error("Received an unexpected obligation response.");
      }

      setObligations((current) =>
        current.map((item) => (item.id === updated.id ? updated : item)),
      );
      setSaveState({
        status: "saved",
        message: updated.active ? "Obligation activated." : "Obligation paused.",
      });
    } catch (error) {
      setObligations((current) =>
        current.map((item) => (item.id === obligation.id ? obligation : item)),
      );
      setSaveState({
        status: "error",
        message:
          error instanceof Error
            ? error.message
            : "We couldn't update this obligation.",
      });
    } finally {
      setPendingId(null);
    }
  }

  return (
    <article className="space-y-5 rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm lg:col-span-2">
      <div className="space-y-1">
        <h2 className="text-lg font-semibold text-zinc-900">Payment obligations</h2>
        <p className="text-sm text-zinc-500">
          Track recurring bills, cards, and loan payments against your linked funding accounts.
        </p>
      </div>

      <form className="grid gap-4 rounded-2xl border border-zinc-100 bg-zinc-50 p-4 md:grid-cols-2" onSubmit={(event) => void submitForm(event)}>
        <label className="space-y-1 text-sm text-zinc-700">
          <span className="font-medium">Creditor or payee</span>
          <input
            data-testid="obligation-creditor-payee"
            className="w-full rounded-xl border border-zinc-200 bg-white px-3 py-2 text-sm text-zinc-900"
            name="creditor_payee"
            value={form.creditorPayee}
            onChange={(event) => setField("creditorPayee", event.target.value)}
            placeholder="Travel Card"
            required
          />
        </label>

        <label className="space-y-1 text-sm text-zinc-700">
          <span className="font-medium">Funding account</span>
          <select
            data-testid="obligation-funding-account"
            className="w-full rounded-xl border border-zinc-200 bg-white px-3 py-2 text-sm text-zinc-900"
            name="linked_funding_account_id"
            value={form.linkedFundingAccountId}
            onChange={(event) => setField("linkedFundingAccountId", event.target.value)}
            required
          >
            {fundingAccounts.map((account) => (
              <option key={account.id} value={account.id}>
                {account.name} ({account.currency})
              </option>
            ))}
          </select>
        </label>

        <label className="space-y-1 text-sm text-zinc-700">
          <span className="font-medium">Due rule</span>
          <select
            data-testid="obligation-due-rule"
            className="w-full rounded-xl border border-zinc-200 bg-white px-3 py-2 text-sm text-zinc-900"
            name="due_rule"
            value={form.dueRule}
            onChange={(event) =>
              setField(
                "dueRule",
                event.target.value === "last_day_of_month"
                  ? "last_day_of_month"
                  : "calendar_day",
              )
            }
          >
            <option value="calendar_day">Calendar day</option>
            <option value="last_day_of_month">Last day of month</option>
          </select>
        </label>

        <label className="space-y-1 text-sm text-zinc-700">
          <span className="font-medium">Due day</span>
          <input
            data-testid="obligation-due-day"
            className="w-full rounded-xl border border-zinc-200 bg-white px-3 py-2 text-sm text-zinc-900 disabled:bg-zinc-100"
            name="due_day"
            value={form.dueDay}
            onChange={(event) => setField("dueDay", event.target.value)}
            type="number"
            min="1"
            max="31"
            disabled={form.dueRule === "last_day_of_month"}
            required={form.dueRule === "calendar_day"}
          />
        </label>

        <label className="space-y-1 text-sm text-zinc-700">
          <span className="font-medium">Minimum due amount</span>
          <input
            data-testid="obligation-minimum-due-amount"
            className="w-full rounded-xl border border-zinc-200 bg-white px-3 py-2 text-sm text-zinc-900"
            name="minimum_due_amount"
            value={form.minimumDueAmount}
            onChange={(event) => setField("minimumDueAmount", event.target.value)}
            type="number"
            min="0.01"
            step="0.01"
            required
          />
        </label>

        <label className="space-y-1 text-sm text-zinc-700">
          <span className="font-medium">Grace period (days)</span>
          <input
            data-testid="obligation-grace-period-days"
            className="w-full rounded-xl border border-zinc-200 bg-white px-3 py-2 text-sm text-zinc-900"
            name="grace_period_days"
            value={form.gracePeriodDays}
            onChange={(event) => setField("gracePeriodDays", event.target.value)}
            type="number"
            min="0"
            max="31"
            required
          />
        </label>

        <label className="flex items-center gap-3 rounded-xl border border-zinc-200 bg-white px-4 py-3 text-sm text-zinc-700">
          <input
            checked={form.active}
            name="active"
            onChange={(event) => setField("active", event.target.checked)}
            type="checkbox"
          />
          <span className="font-medium">Active reminder</span>
        </label>

        <div className="flex items-center gap-3 md:col-span-2">
          <button
            data-testid="obligation-submit"
            className="inline-flex items-center rounded-full bg-primary px-4 py-2 text-sm font-semibold text-white transition hover:bg-primary/90"
            type="submit"
          >
            {editingId ? "Save obligation" : "Create obligation"}
          </button>
          {editingId ? (
            <button
              className="inline-flex items-center rounded-full border border-zinc-300 px-4 py-2 text-sm font-semibold text-zinc-700 transition hover:border-zinc-400"
              onClick={resetForm}
              type="button"
            >
              Cancel edit
            </button>
          ) : null}
        </div>
      </form>

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
        {saveState.message}
      </p>

      <div className="space-y-3">
        {obligations.length === 0 ? (
          <div className="rounded-2xl border border-dashed border-zinc-200 bg-zinc-50 px-4 py-5 text-sm text-zinc-500">
            No payment obligations saved yet.
          </div>
        ) : (
          obligations.map((obligation) => (
            <div
              key={obligation.id}
              className="flex flex-col gap-4 rounded-2xl border border-zinc-200 bg-white px-4 py-4 md:flex-row md:items-center md:justify-between"
            >
              <div className="space-y-1">
                <div className="flex items-center gap-2">
                  <h3 className="font-semibold text-zinc-900">{obligation.creditorPayee}</h3>
                  <span
                    className={`rounded-full px-2.5 py-1 text-xs font-semibold ${
                      obligation.active
                        ? "bg-emerald-100 text-emerald-700"
                        : "bg-zinc-200 text-zinc-600"
                    }`}
                  >
                    {obligation.active ? "Active" : "Paused"}
                  </span>
                </div>
                <p className="text-sm text-zinc-600">
                  {obligation.currency} {obligation.minimumDueAmount} due on{" "}
                  {formatDueRule(obligation)}
                  {obligation.gracePeriodDays > 0
                    ? ` with ${obligation.gracePeriodDays} day grace period`
                    : ""}
                  .
                </p>
                <p className="text-sm text-zinc-500">
                  Funding account: {obligation.linkedFundingAccountName ?? "Unknown account"}
                </p>
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <button
                  className="rounded-full border border-zinc-300 px-3 py-1.5 text-sm font-semibold text-zinc-700 transition hover:border-zinc-400"
                  data-testid={`edit-obligation-${obligation.id}`}
                  onClick={() => beginEdit(obligation)}
                  type="button"
                >
                  Edit
                </button>
                <button
                  className="rounded-full border border-zinc-300 px-3 py-1.5 text-sm font-semibold text-zinc-700 transition hover:border-zinc-400"
                  data-testid={`toggle-obligation-${obligation.id}`}
                  disabled={pendingId === obligation.id}
                  onClick={() => {
                    void toggleActive(obligation);
                  }}
                  type="button"
                >
                  {obligation.active ? "Pause" : "Activate"}
                </button>
                <button
                  className="rounded-full border border-rose-200 px-3 py-1.5 text-sm font-semibold text-rose-700 transition hover:border-rose-300"
                  data-testid={`delete-obligation-${obligation.id}`}
                  disabled={pendingId === obligation.id}
                  onClick={() => {
                    void deleteObligation(obligation.id);
                  }}
                  type="button"
                >
                  Delete
                </button>
              </div>
            </div>
          ))
        )}
      </div>
    </article>
  );
}
