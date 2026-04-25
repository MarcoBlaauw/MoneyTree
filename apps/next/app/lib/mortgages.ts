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

export type MortgageEscrowProfile = {
  id: string;
  propertyTaxMonthly: string | null;
  homeownersInsuranceMonthly: string | null;
  floodInsuranceMonthly: string | null;
  otherEscrowMonthly: string | null;
  escrowCushionMonths: string | null;
  expectedOldEscrowRefund: string | null;
  annualTaxGrowthRate: string | null;
  annualInsuranceGrowthRate: string | null;
  source: string | null;
  confidenceScore: string | null;
};

export type MortgageSummary = {
  id: string;
  nickname: string | null;
  propertyName: string;
  loanType: string;
  currentBalance: string;
  currentInterestRate: string;
  remainingTermMonths: number;
  monthlyPaymentTotal: string;
  hasEscrow: boolean;
  escrowIncludedInPayment: boolean;
  status: string;
  escrowProfile: MortgageEscrowProfile | null;
};

function resolveEscrowProfile(payload: unknown): MortgageEscrowProfile | null {
  if (!isRecord(payload) || typeof payload.id !== "string") {
    return null;
  }

  return {
    id: payload.id,
    propertyTaxMonthly: toStringOrNull(payload.property_tax_monthly),
    homeownersInsuranceMonthly: toStringOrNull(payload.homeowners_insurance_monthly),
    floodInsuranceMonthly: toStringOrNull(payload.flood_insurance_monthly),
    otherEscrowMonthly: toStringOrNull(payload.other_escrow_monthly),
    escrowCushionMonths: toStringOrNull(payload.escrow_cushion_months),
    expectedOldEscrowRefund: toStringOrNull(payload.expected_old_escrow_refund),
    annualTaxGrowthRate: toStringOrNull(payload.annual_tax_growth_rate),
    annualInsuranceGrowthRate: toStringOrNull(payload.annual_insurance_growth_rate),
    source: toStringOrNull(payload.source),
    confidenceScore: toStringOrNull(payload.confidence_score),
  };
}

function resolveMortgage(item: unknown): MortgageSummary | null {
  if (
    !isRecord(item) ||
    typeof item.id !== "string" ||
    typeof item.property_name !== "string" ||
    typeof item.loan_type !== "string" ||
    typeof item.current_balance !== "string" ||
    typeof item.current_interest_rate !== "string" ||
    typeof item.remaining_term_months !== "number" ||
    typeof item.monthly_payment_total !== "string" ||
    typeof item.status !== "string"
  ) {
    return null;
  }

  return {
    id: item.id,
    nickname: toStringOrNull(item.nickname),
    propertyName: item.property_name,
    loanType: item.loan_type,
    currentBalance: item.current_balance,
    currentInterestRate: item.current_interest_rate,
    remainingTermMonths: item.remaining_term_months,
    monthlyPaymentTotal: item.monthly_payment_total,
    hasEscrow: toBoolean(item.has_escrow),
    escrowIncludedInPayment: toBoolean(item.escrow_included_in_payment),
    status: item.status,
    escrowProfile: resolveEscrowProfile(item.escrow_profile),
  };
}

function resolveMortgageList(payload: unknown): MortgageSummary[] {
  if (!isRecord(payload) || !Array.isArray(payload.data)) {
    return [];
  }

  return payload.data
    .map(resolveMortgage)
    .filter((mortgage): mortgage is MortgageSummary => Boolean(mortgage));
}

function resolveMortgageItem(payload: unknown): MortgageSummary | null {
  if (!isRecord(payload)) {
    return null;
  }

  return resolveMortgage(payload.data);
}

export async function getMortgages(): Promise<MortgageSummary[]> {
  const response = await fetchWithSession("/api/mortgages");

  if (!response || !response.ok) {
    return [];
  }

  const payload = (await response.json().catch(() => null)) as unknown;
  return resolveMortgageList(payload);
}

export async function getMortgageById(mortgageId: string): Promise<MortgageSummary | null> {
  const response = await fetchWithSession(`/api/mortgages/${encodeURIComponent(mortgageId)}`);

  if (!response || !response.ok) {
    return null;
  }

  const payload = (await response.json().catch(() => null)) as unknown;
  return resolveMortgageItem(payload);
}
