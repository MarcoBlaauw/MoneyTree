"use client";

import Link from "next/link";
import { useMemo, useState } from "react";

import type { MortgageSummary } from "../lib/mortgages";

type MortgageOverviewClientProps = {
  initialMortgages: MortgageSummary[];
};

type CreateFormState = {
  propertyName: string;
  loanType: string;
  currentBalance: string;
  currentInterestRate: string;
  remainingTermMonths: string;
  monthlyPaymentTotal: string;
  hasEscrow: boolean;
  escrowIncludedInPayment: boolean;
  propertyTaxMonthly: string;
  homeownersInsuranceMonthly: string;
};

const initialFormState: CreateFormState = {
  propertyName: "",
  loanType: "conventional",
  currentBalance: "",
  currentInterestRate: "",
  remainingTermMonths: "",
  monthlyPaymentTotal: "",
  hasEscrow: false,
  escrowIncludedInPayment: false,
  propertyTaxMonthly: "",
  homeownersInsuranceMonthly: "",
};

export function MortgageOverviewClient({ initialMortgages }: MortgageOverviewClientProps) {
  const [mortgages, setMortgages] = useState(initialMortgages);
  const [form, setForm] = useState<CreateFormState>(initialFormState);
  const [status, setStatus] = useState<string>("Add your first mortgage to start Mortgage Center.");
  const [isSaving, setIsSaving] = useState(false);

  const totalPayment = useMemo(() => {
    return mortgages.reduce((total, mortgage) => {
      const parsed = Number.parseFloat(mortgage.monthlyPaymentTotal);
      if (Number.isFinite(parsed)) {
        return total + parsed;
      }

      return total;
    }, 0);
  }, [mortgages]);

  function updateField<Key extends keyof CreateFormState>(key: Key, value: CreateFormState[Key]) {
    setForm((current) => ({ ...current, [key]: value }));
  }

  async function handleCreate(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setIsSaving(true);
    setStatus("Saving mortgage...");

    try {
      const payload: Record<string, unknown> = {
        property_name: form.propertyName.trim(),
        loan_type: form.loanType.trim(),
        current_balance: form.currentBalance.trim(),
        current_interest_rate: form.currentInterestRate.trim(),
        remaining_term_months: Number.parseInt(form.remainingTermMonths, 10),
        monthly_payment_total: form.monthlyPaymentTotal.trim(),
        has_escrow: form.hasEscrow,
        escrow_included_in_payment: form.escrowIncludedInPayment,
      };

      if (form.propertyTaxMonthly.trim() || form.homeownersInsuranceMonthly.trim()) {
        payload.escrow_profile = {
          property_tax_monthly: form.propertyTaxMonthly.trim() || undefined,
          homeowners_insurance_monthly: form.homeownersInsuranceMonthly.trim() || undefined,
          source: "manual_entry",
          confidence_score: "1.0",
        };
      }

      const response = await fetch("/api/mortgages", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(payload),
      });

      if (!response.ok) {
        throw new Error("Unable to create mortgage.");
      }

      const json = (await response.json().catch(() => null)) as { data?: unknown } | null;
      const created = json?.data as Record<string, unknown> | undefined;

      if (!created || typeof created.id !== "string") {
        throw new Error("Unexpected mortgage response.");
      }

      const mortgage: MortgageSummary = {
        id: created.id,
        nickname: typeof created.nickname === "string" ? created.nickname : null,
        propertyName: typeof created.property_name === "string" ? created.property_name : form.propertyName,
        loanType: typeof created.loan_type === "string" ? created.loan_type : form.loanType,
        currentBalance:
          typeof created.current_balance === "string" ? created.current_balance : form.currentBalance,
        currentInterestRate:
          typeof created.current_interest_rate === "string"
            ? created.current_interest_rate
            : form.currentInterestRate,
        remainingTermMonths:
          typeof created.remaining_term_months === "number"
            ? created.remaining_term_months
            : Number.parseInt(form.remainingTermMonths, 10),
        monthlyPaymentTotal:
          typeof created.monthly_payment_total === "string"
            ? created.monthly_payment_total
            : form.monthlyPaymentTotal,
        hasEscrow: typeof created.has_escrow === "boolean" ? created.has_escrow : form.hasEscrow,
        escrowIncludedInPayment:
          typeof created.escrow_included_in_payment === "boolean"
            ? created.escrow_included_in_payment
            : form.escrowIncludedInPayment,
        status: typeof created.status === "string" ? created.status : "active",
        escrowProfile: null,
      };

      setMortgages((current) => [...current, mortgage]);
      setForm(initialFormState);
      setStatus("Mortgage saved.");
    } catch (error) {
      setStatus(error instanceof Error ? error.message : "Unable to create mortgage.");
    } finally {
      setIsSaving(false);
    }
  }

  return (
    <main className="bg-background text-foreground min-h-screen">
      <section className="mx-auto flex w-full max-w-5xl flex-col gap-6 px-6 py-12">
        <header className="space-y-2">
          <p className="text-xs font-semibold uppercase tracking-wide text-primary">Mortgage Center</p>
          <h1 className="text-3xl font-semibold tracking-tight text-foreground">Overview</h1>
          <p className="text-sm text-zinc-500">
            Track your current mortgages, escrow details, and prepare for refinance analysis in one place.
          </p>
        </header>

        <div className="rounded-2xl border border-primary/20 bg-primary/5 p-4 text-sm text-primary">
          <p className="font-medium">Saved mortgages: {mortgages.length}</p>
          <p>Total monthly payment baseline: ${totalPayment.toFixed(2)}</p>
        </div>

        <article className="space-y-4 rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm">
          <h2 className="text-lg font-semibold text-zinc-900">Add mortgage</h2>
          <form className="grid gap-3 md:grid-cols-2" onSubmit={handleCreate}>
            <label className="text-sm text-zinc-600">
              Property name
              <input
                className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
                value={form.propertyName}
                onChange={(event) => updateField("propertyName", event.target.value)}
                required
              />
            </label>
            <label className="text-sm text-zinc-600">
              Loan type
              <input
                className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
                value={form.loanType}
                onChange={(event) => updateField("loanType", event.target.value)}
                required
              />
            </label>
            <label className="text-sm text-zinc-600">
              Current balance
              <input
                className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
                value={form.currentBalance}
                onChange={(event) => updateField("currentBalance", event.target.value)}
                required
              />
            </label>
            <label className="text-sm text-zinc-600">
              Interest rate (decimal)
              <input
                className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
                value={form.currentInterestRate}
                onChange={(event) => updateField("currentInterestRate", event.target.value)}
                required
              />
            </label>
            <label className="text-sm text-zinc-600">
              Remaining term (months)
              <input
                className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
                value={form.remainingTermMonths}
                onChange={(event) => updateField("remainingTermMonths", event.target.value)}
                required
              />
            </label>
            <label className="text-sm text-zinc-600">
              Monthly payment total
              <input
                className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
                value={form.monthlyPaymentTotal}
                onChange={(event) => updateField("monthlyPaymentTotal", event.target.value)}
                required
              />
            </label>
            <label className="text-sm text-zinc-600">
              Escrow tax monthly (optional)
              <input
                className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
                value={form.propertyTaxMonthly}
                onChange={(event) => updateField("propertyTaxMonthly", event.target.value)}
              />
            </label>
            <label className="text-sm text-zinc-600">
              Escrow insurance monthly (optional)
              <input
                className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
                value={form.homeownersInsuranceMonthly}
                onChange={(event) => updateField("homeownersInsuranceMonthly", event.target.value)}
              />
            </label>
            <label className="flex items-center gap-2 text-sm text-zinc-700">
              <input
                type="checkbox"
                checked={form.hasEscrow}
                onChange={(event) => updateField("hasEscrow", event.target.checked)}
              />
              Has escrow
            </label>
            <label className="flex items-center gap-2 text-sm text-zinc-700">
              <input
                type="checkbox"
                checked={form.escrowIncludedInPayment}
                onChange={(event) => updateField("escrowIncludedInPayment", event.target.checked)}
              />
              Escrow included in payment
            </label>
            <div className="md:col-span-2 flex items-center gap-3">
              <button
                className="rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground disabled:opacity-60"
                disabled={isSaving}
                type="submit"
              >
                {isSaving ? "Saving..." : "Save mortgage"}
              </button>
              <p className="text-sm text-zinc-500">{status}</p>
            </div>
          </form>
        </article>

        <article className="space-y-4 rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm">
          <h2 className="text-lg font-semibold text-zinc-900">Current mortgages</h2>
          {mortgages.length === 0 ? (
            <p className="text-sm text-zinc-500">No mortgages saved yet.</p>
          ) : (
            <ul className="space-y-3">
              {mortgages.map((mortgage) => (
                <li
                  key={mortgage.id}
                  className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-zinc-200 px-4 py-3"
                >
                  <div>
                    <p className="font-medium text-zinc-900">{mortgage.propertyName}</p>
                    <p className="text-sm text-zinc-500">
                      {mortgage.loanType} · balance {mortgage.currentBalance} · payment {mortgage.monthlyPaymentTotal}
                    </p>
                  </div>
                  <Link
                    href={`/mortgages/${encodeURIComponent(mortgage.id)}`}
                    className="rounded-md border border-primary/30 px-3 py-2 text-sm font-medium text-primary hover:border-primary"
                  >
                    Open detail
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </article>
      </section>
    </main>
  );
}
