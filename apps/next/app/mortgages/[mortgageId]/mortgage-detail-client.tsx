"use client";

import { useState } from "react";

import type { MortgageSummary } from "../../lib/mortgages";

type MortgageDetailClientProps = {
  mortgage: MortgageSummary;
};

type EditState = {
  propertyName: string;
  monthlyPaymentTotal: string;
  currentBalance: string;
  currentInterestRate: string;
  remainingTermMonths: string;
  propertyTaxMonthly: string;
  homeownersInsuranceMonthly: string;
};

function toEditState(mortgage: MortgageSummary): EditState {
  return {
    propertyName: mortgage.propertyName,
    monthlyPaymentTotal: mortgage.monthlyPaymentTotal,
    currentBalance: mortgage.currentBalance,
    currentInterestRate: mortgage.currentInterestRate,
    remainingTermMonths: String(mortgage.remainingTermMonths),
    propertyTaxMonthly: mortgage.escrowProfile?.propertyTaxMonthly ?? "",
    homeownersInsuranceMonthly: mortgage.escrowProfile?.homeownersInsuranceMonthly ?? "",
  };
}

export function MortgageDetailClient({ mortgage }: MortgageDetailClientProps) {
  const [form, setForm] = useState<EditState>(() => toEditState(mortgage));
  const [status, setStatus] = useState("Edit your mortgage baseline and escrow details.");
  const [isSaving, setIsSaving] = useState(false);

  function setField<Key extends keyof EditState>(key: Key, value: EditState[Key]) {
    setForm((current) => ({ ...current, [key]: value }));
  }

  async function handleSave(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setIsSaving(true);
    setStatus("Saving updates...");

    try {
      const response = await fetch(`/api/mortgages/${encodeURIComponent(mortgage.id)}`, {
        method: "PUT",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          property_name: form.propertyName.trim(),
          monthly_payment_total: form.monthlyPaymentTotal.trim(),
          current_balance: form.currentBalance.trim(),
          current_interest_rate: form.currentInterestRate.trim(),
          remaining_term_months: Number.parseInt(form.remainingTermMonths, 10),
          escrow_profile: {
            property_tax_monthly: form.propertyTaxMonthly.trim() || undefined,
            homeowners_insurance_monthly: form.homeownersInsuranceMonthly.trim() || undefined,
            source: "manual_entry",
            confidence_score: "1.0",
          },
        }),
      });

      if (!response.ok) {
        throw new Error("Unable to save mortgage updates.");
      }

      setStatus("Mortgage updated.");
    } catch (error) {
      setStatus(error instanceof Error ? error.message : "Unable to save mortgage updates.");
    } finally {
      setIsSaving(false);
    }
  }

  return (
    <main className="bg-background text-foreground min-h-screen">
      <section className="mx-auto flex w-full max-w-4xl flex-col gap-6 px-6 py-12">
        <header className="space-y-2">
          <p className="text-xs font-semibold uppercase tracking-wide text-primary">Mortgage Center</p>
          <h1 className="text-3xl font-semibold tracking-tight text-foreground">{mortgage.propertyName}</h1>
          <p className="text-sm text-zinc-500">
            Keep your baseline accurate for upcoming refinance analysis, alerts, and import review workflows.
          </p>
        </header>

        <article className="rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm">
          <form className="grid gap-3 md:grid-cols-2" onSubmit={handleSave}>
            <label className="text-sm text-zinc-600">
              Property name
              <input
                className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
                value={form.propertyName}
                onChange={(event) => setField("propertyName", event.target.value)}
                required
              />
            </label>
            <label className="text-sm text-zinc-600">
              Current balance
              <input
                className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
                value={form.currentBalance}
                onChange={(event) => setField("currentBalance", event.target.value)}
                required
              />
            </label>
            <label className="text-sm text-zinc-600">
              Interest rate (decimal)
              <input
                className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
                value={form.currentInterestRate}
                onChange={(event) => setField("currentInterestRate", event.target.value)}
                required
              />
            </label>
            <label className="text-sm text-zinc-600">
              Remaining term (months)
              <input
                className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
                value={form.remainingTermMonths}
                onChange={(event) => setField("remainingTermMonths", event.target.value)}
                required
              />
            </label>
            <label className="text-sm text-zinc-600">
              Monthly payment total
              <input
                className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
                value={form.monthlyPaymentTotal}
                onChange={(event) => setField("monthlyPaymentTotal", event.target.value)}
                required
              />
            </label>
            <label className="text-sm text-zinc-600">
              Escrow tax monthly
              <input
                className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
                value={form.propertyTaxMonthly}
                onChange={(event) => setField("propertyTaxMonthly", event.target.value)}
              />
            </label>
            <label className="text-sm text-zinc-600">
              Escrow insurance monthly
              <input
                className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
                value={form.homeownersInsuranceMonthly}
                onChange={(event) => setField("homeownersInsuranceMonthly", event.target.value)}
              />
            </label>
            <div className="md:col-span-2 flex items-center gap-3">
              <button
                className="rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground disabled:opacity-60"
                disabled={isSaving}
                type="submit"
              >
                {isSaving ? "Saving..." : "Save changes"}
              </button>
              <p className="text-sm text-zinc-500">{status}</p>
            </div>
          </form>
        </article>
      </section>
    </main>
  );
}
