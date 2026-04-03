import { fetchWithSession } from "./session-fetch";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function toStringOrNull(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function toBoolean(value: unknown, fallback = false): boolean {
  return typeof value === "boolean" ? value : fallback;
}

export type FundingAccountOption = {
  id: string;
  name: string;
  currency: string;
  type: string;
  subtype: string | null;
};

export type ControlPanelObligation = {
  id: string;
  creditorPayee: string;
  dueDay: number | null;
  dueRule: string;
  minimumDueAmount: string;
  currency: string;
  gracePeriodDays: number;
  active: boolean;
  linkedFundingAccountId: string;
  linkedFundingAccountName: string | null;
};

function resolveFundingAccounts(payload: unknown): FundingAccountOption[] {
  if (!isRecord(payload) || !Array.isArray(payload.data)) {
    return [];
  }

  return payload.data
    .map((item) => {
      if (!isRecord(item) || typeof item.id !== "string" || typeof item.name !== "string") {
        return null;
      }

      return {
        id: item.id,
        name: item.name,
        currency: typeof item.currency === "string" ? item.currency : "USD",
        type: typeof item.type === "string" ? item.type : "unknown",
        subtype: toStringOrNull(item.subtype),
      } satisfies FundingAccountOption;
    })
    .filter((account): account is FundingAccountOption => Boolean(account));
}

function resolveObligations(payload: unknown): ControlPanelObligation[] {
  if (!isRecord(payload) || !Array.isArray(payload.data)) {
    return [];
  }

  return payload.data
    .map((item) => {
      if (
        !isRecord(item) ||
        typeof item.id !== "string" ||
        typeof item.creditor_payee !== "string" ||
        typeof item.due_rule !== "string" ||
        typeof item.minimum_due_amount !== "string" ||
        typeof item.currency !== "string" ||
        typeof item.grace_period_days !== "number" ||
        typeof item.linked_funding_account_id !== "string"
      ) {
        return null;
      }

      const linkedFundingAccount = isRecord(item.linked_funding_account)
        ? item.linked_funding_account
        : null;

      return {
        id: item.id,
        creditorPayee: item.creditor_payee,
        dueDay: typeof item.due_day === "number" ? item.due_day : null,
        dueRule: item.due_rule,
        minimumDueAmount: item.minimum_due_amount,
        currency: item.currency,
        gracePeriodDays: item.grace_period_days,
        active: toBoolean(item.active, true),
        linkedFundingAccountId: item.linked_funding_account_id,
        linkedFundingAccountName: linkedFundingAccount ? toStringOrNull(linkedFundingAccount.name) : null,
      } satisfies ControlPanelObligation;
    })
    .filter((obligation): obligation is ControlPanelObligation => Boolean(obligation));
}

export async function getFundingAccountOptions(): Promise<FundingAccountOption[]> {
  const response = await fetchWithSession("/api/accounts");

  if (!response || !response.ok) {
    return [];
  }

  const payload = (await response.json().catch(() => null)) as unknown;
  return resolveFundingAccounts(payload);
}

export async function getControlPanelObligations(): Promise<ControlPanelObligation[]> {
  const response = await fetchWithSession("/api/obligations");

  if (!response || !response.ok) {
    return [];
  }

  const payload = (await response.json().catch(() => null)) as unknown;
  return resolveObligations(payload);
}
