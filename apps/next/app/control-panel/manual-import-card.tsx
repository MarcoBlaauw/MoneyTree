"use client";

import React, { useRef, useState } from "react";

import type { FundingAccountOption } from "../lib/obligations";

type ManualImportCardProps = {
  csrfToken: string;
  accounts: FundingAccountOption[];
};

type ParsedRow = {
  id: string;
  rowIndex: number;
  postedAt: string | null;
  description: string | null;
  amount: string | null;
  parseStatus: string;
  reviewDecision: string;
};

type ParseSummary = {
  batchId: string;
  rowCount: number;
  committedCount: number;
  status: string;
};

type SaveState =
  | { status: "idle"; message: string }
  | { status: "saving"; message: string }
  | { status: "saved"; message: string }
  | { status: "error"; message: string };

const DEFAULT_STATE: SaveState = {
  status: "idle",
  message: "Paste CSV, map required columns, preview parsed rows, then commit.",
};

type HeaderMapping = {
  postedAt: string;
  description: string;
  amount: string;
  debit: string;
  credit: string;
  status: string;
};

const EMPTY_MAPPING: HeaderMapping = {
  postedAt: "",
  description: "",
  amount: "",
  debit: "",
  credit: "",
  status: "",
};

function parseHeaders(csvText: string): string[] {
  const firstLine = csvText
    .split(/\r\n|\n|\r/)
    .find((line) => line.trim().length > 0);

  if (!firstLine) {
    return [];
  }

  return firstLine
    .split(",")
    .map((header) => header.trim())
    .filter((header) => header.length > 0);
}

function resolveInitialMapping(headers: string[]): HeaderMapping {
  const normalizedHeaders = new Map(headers.map((header) => [header.toLowerCase(), header]));

  const lookup = (candidates: string[]) => {
    for (const candidate of candidates) {
      const match = normalizedHeaders.get(candidate.toLowerCase());
      if (match) {
        return match;
      }
    }

    return "";
  };

  return {
    postedAt: lookup(["date", "posted_at", "posted date", "transaction date"]),
    description: lookup(["description", "name", "memo"]),
    amount: lookup(["amount", "signed amount"]),
    debit: lookup(["debit", "withdrawal"]),
    credit: lookup(["credit", "deposit"]),
    status: lookup(["status"]),
  };
}

function parseRowsFromPayload(payload: unknown): ParsedRow[] {
  if (!payload || typeof payload !== "object") {
    return [];
  }

  const root = payload as Record<string, unknown>;
  if (!Array.isArray(root.data)) {
    return [];
  }

  return root.data
    .map((row) => {
      if (!row || typeof row !== "object") {
        return null;
      }

      const item = row as Record<string, unknown>;
      if (typeof item.id !== "string" || typeof item.row_index !== "number") {
        return null;
      }

      return {
        id: item.id,
        rowIndex: item.row_index,
        postedAt: typeof item.posted_at === "string" ? item.posted_at : null,
        description: typeof item.description === "string" ? item.description : null,
        amount: typeof item.amount === "string" ? item.amount : null,
        parseStatus: typeof item.parse_status === "string" ? item.parse_status : "unknown",
        reviewDecision:
          typeof item.review_decision === "string" ? item.review_decision : "needs_review",
      } satisfies ParsedRow;
    })
    .filter((row): row is ParsedRow => Boolean(row));
}

function parseBatchFromPayload(payload: unknown): ParseSummary | null {
  if (!payload || typeof payload !== "object") {
    return null;
  }

  const root = payload as Record<string, unknown>;
  const data = root.data && typeof root.data === "object" ? (root.data as Record<string, unknown>) : null;
  const batch = data?.batch && typeof data.batch === "object" ? (data.batch as Record<string, unknown>) : null;

  if (!batch || typeof batch.id !== "string") {
    return null;
  }

  return {
    batchId: batch.id,
    rowCount: typeof batch.row_count === "number" ? batch.row_count : 0,
    committedCount: typeof batch.committed_count === "number" ? batch.committed_count : 0,
    status: typeof batch.status === "string" ? batch.status : "unknown",
  };
}

function buildMappingConfig(mapping: HeaderMapping) {
  const columns: Record<string, string> = {};

  if (mapping.postedAt) {
    columns.posted_at = mapping.postedAt;
  }
  if (mapping.description) {
    columns.description = mapping.description;
  }
  if (mapping.amount) {
    columns.amount = mapping.amount;
  }
  if (mapping.debit) {
    columns.debit = mapping.debit;
  }
  if (mapping.credit) {
    columns.credit = mapping.credit;
  }
  if (mapping.status) {
    columns.status = mapping.status;
  }

  return { columns };
}

export function ManualImportCard({ csrfToken, accounts }: ManualImportCardProps) {
  const [selectedAccountId, setSelectedAccountId] = useState(accounts[0]?.id ?? "");
  const [csvText, setCsvText] = useState("");
  const [mapping, setMapping] = useState<HeaderMapping>(EMPTY_MAPPING);
  const [rows, setRows] = useState<ParsedRow[]>([]);
  const [summary, setSummary] = useState<ParseSummary | null>(null);
  const [saveState, setSaveState] = useState<SaveState>(DEFAULT_STATE);
  const [isBusy, setIsBusy] = useState(false);
  const csvInputRef = useRef<HTMLTextAreaElement | null>(null);

  const headers = parseHeaders(csvText);

  function updateMapping<Key extends keyof HeaderMapping>(key: Key, value: HeaderMapping[Key]) {
    setMapping((current) => ({ ...current, [key]: value }));
  }

  function applyHeaderGuess() {
    setMapping(resolveInitialMapping(headers));
  }

  async function createBatch(): Promise<string> {
    const response = await fetch("/api/manual-imports", {
      method: "POST",
      credentials: "include",
      headers: {
        "content-type": "application/json",
        "x-csrf-token": csrfToken,
      },
      body: JSON.stringify({
        account_id: selectedAccountId,
        source_institution: "generic_csv",
        file_name: "manual-paste.csv",
      }),
    });

    if (!response.ok) {
      throw new Error("Unable to create import batch.");
    }

    const payload = (await response.json().catch(() => null)) as
      | { data?: { id?: string } }
      | null;
    const batchId = payload?.data?.id;

    if (!batchId || typeof batchId !== "string") {
      throw new Error("Batch response was invalid.");
    }

    return batchId;
  }

  async function parseBatch(
    batchId: string,
    csvContent: string,
    resolvedMapping: HeaderMapping,
  ): Promise<ParseSummary> {
    const response = await fetch(`/api/manual-imports/${encodeURIComponent(batchId)}/parse`, {
      method: "POST",
      credentials: "include",
      headers: {
        "content-type": "application/json",
        "x-csrf-token": csrfToken,
      },
      body: JSON.stringify({
        csv_content: csvContent,
        mapping_config: buildMappingConfig(resolvedMapping),
      }),
    });

    if (!response.ok) {
      const payload = (await response.json().catch(() => null)) as { error?: string } | null;
      throw new Error(payload?.error ?? "Unable to parse CSV.");
    }

    const payload = (await response.json().catch(() => null)) as unknown;
    const parsed = parseBatchFromPayload(payload);

    if (!parsed) {
      throw new Error("Parse response was invalid.");
    }

    return parsed;
  }

  async function fetchRows(batchId: string): Promise<ParsedRow[]> {
    const response = await fetch(`/api/manual-imports/${encodeURIComponent(batchId)}/rows`, {
      method: "GET",
      credentials: "include",
      headers: {
        accept: "application/json",
      },
    });

    if (!response.ok) {
      throw new Error("Unable to load parsed rows.");
    }

    const payload = (await response.json().catch(() => null)) as unknown;
    return parseRowsFromPayload(payload);
  }

  async function handleParse() {
    const csvContent = csvText || csvInputRef.current?.value || "";
    const availableHeaders = parseHeaders(csvContent);
    const guessedMapping = resolveInitialMapping(availableHeaders);
    const resolvedMapping: HeaderMapping = {
      postedAt: mapping.postedAt || guessedMapping.postedAt,
      description: mapping.description || guessedMapping.description,
      amount: mapping.amount || guessedMapping.amount,
      debit: mapping.debit || guessedMapping.debit,
      credit: mapping.credit || guessedMapping.credit,
      status: mapping.status || guessedMapping.status,
    };

    if (!selectedAccountId) {
      setSaveState({ status: "error", message: "Select an account first." });
      return;
    }

    if (!csvContent.trim()) {
      setSaveState({ status: "error", message: "Paste CSV content first." });
      return;
    }

    if (
      !resolvedMapping.postedAt ||
      !resolvedMapping.description ||
      (!resolvedMapping.amount && !resolvedMapping.debit && !resolvedMapping.credit)
    ) {
      setSaveState({
        status: "error",
        message: "Map posted date, description, and amount (or debit/credit).",
      });
      return;
    }

    setIsBusy(true);
    setSaveState({ status: "saving", message: "Creating import batch and parsing rows..." });

    try {
      setMapping(resolvedMapping);
      const batchId = await createBatch();
      const parsedSummary = await parseBatch(batchId, csvContent, resolvedMapping);
      const parsedRows = await fetchRows(batchId);

      setSummary(parsedSummary);
      setRows(parsedRows);
      setSaveState({
        status: "saved",
        message: `Parsed ${parsedSummary.rowCount} rows. Review then commit when ready.`,
      });
    } catch (error) {
      setSaveState({
        status: "error",
        message: error instanceof Error ? error.message : "Unable to parse manual import CSV.",
      });
    } finally {
      setIsBusy(false);
    }
  }

  async function handleCommit() {
    if (!summary) {
      setSaveState({ status: "error", message: "Parse rows before committing." });
      return;
    }

    setIsBusy(true);
    setSaveState({ status: "saving", message: "Committing parsed rows..." });

    try {
      const response = await fetch(
        `/api/manual-imports/${encodeURIComponent(summary.batchId)}/commit`,
        {
          method: "POST",
          credentials: "include",
          headers: {
            "content-type": "application/json",
            "x-csrf-token": csrfToken,
          },
        },
      );

      if (!response.ok) {
        const payload = (await response.json().catch(() => null)) as { error?: string } | null;
        throw new Error(payload?.error ?? "Unable to commit batch.");
      }

      const payload = (await response.json().catch(() => null)) as
        | { data?: { committed_count?: number; status?: string } }
        | null;

      const committedCount =
        typeof payload?.data?.committed_count === "number" ? payload.data.committed_count : 0;
      const status = typeof payload?.data?.status === "string" ? payload.data.status : "committed";

      setSummary((current) =>
        current
          ? { ...current, committedCount, status }
          : { batchId: "", rowCount: rows.length, committedCount, status },
      );
      setSaveState({
        status: "saved",
        message: `Committed ${committedCount} rows to transactions.`,
      });
    } catch (error) {
      setSaveState({
        status: "error",
        message: error instanceof Error ? error.message : "Unable to commit batch.",
      });
    } finally {
      setIsBusy(false);
    }
  }

  return (
    <article className="space-y-4 rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm lg:col-span-2">
      <div className="space-y-1">
        <h2 className="text-lg font-semibold text-zinc-900">Manual transaction import</h2>
        <p className="text-sm text-zinc-500">
          Import real CSV data into a staged batch, preview parse output, then commit accepted rows.
        </p>
      </div>

      <div className="grid gap-3 md:grid-cols-2">
        <label className="text-sm text-zinc-600">
          Account
          <select
            className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
            data-testid="manual-import-account"
            value={selectedAccountId}
            onChange={(event) => setSelectedAccountId(event.target.value)}
          >
            {accounts.length === 0 ? <option value="">No accessible accounts</option> : null}
            {accounts.map((account) => (
              <option key={account.id} value={account.id}>
                {account.name} ({account.currency})
              </option>
            ))}
          </select>
        </label>

        <div className="flex items-end">
          <button
            type="button"
            className="rounded-md border border-zinc-300 px-4 py-2 text-sm font-semibold text-zinc-700 hover:border-zinc-400"
            onClick={applyHeaderGuess}
            disabled={headers.length === 0 || isBusy}
            data-testid="manual-import-guess-mapping"
          >
            Auto-detect mapping
          </button>
        </div>
      </div>

      <label className="block text-sm text-zinc-600">
        CSV content
        <textarea
          ref={csvInputRef}
          className="mt-1 h-40 w-full rounded-md border border-zinc-300 px-3 py-2 font-mono text-xs"
          placeholder="Date,Description,Amount&#10;2026-04-20,Coffee,-4.25"
          value={csvText}
          onChange={(event) => setCsvText(event.target.value)}
          data-testid="manual-import-csv"
        />
      </label>

      <div className="grid gap-3 md:grid-cols-3">
        <label className="text-sm text-zinc-600">
          Posted date column
          <select
            className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
            value={mapping.postedAt}
            onChange={(event) => updateMapping("postedAt", event.target.value)}
            data-testid="manual-import-map-posted-at"
          >
            <option value="">Select column</option>
            {headers.map((header) => (
              <option key={`posted-${header}`} value={header}>
                {header}
              </option>
            ))}
          </select>
        </label>

        <label className="text-sm text-zinc-600">
          Description column
          <select
            className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
            value={mapping.description}
            onChange={(event) => updateMapping("description", event.target.value)}
            data-testid="manual-import-map-description"
          >
            <option value="">Select column</option>
            {headers.map((header) => (
              <option key={`description-${header}`} value={header}>
                {header}
              </option>
            ))}
          </select>
        </label>

        <label className="text-sm text-zinc-600">
          Amount column
          <select
            className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
            value={mapping.amount}
            onChange={(event) => updateMapping("amount", event.target.value)}
            data-testid="manual-import-map-amount"
          >
            <option value="">Select column</option>
            {headers.map((header) => (
              <option key={`amount-${header}`} value={header}>
                {header}
              </option>
            ))}
          </select>
        </label>

        <label className="text-sm text-zinc-600">
          Debit column (optional)
          <select
            className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
            value={mapping.debit}
            onChange={(event) => updateMapping("debit", event.target.value)}
            data-testid="manual-import-map-debit"
          >
            <option value="">Select column</option>
            {headers.map((header) => (
              <option key={`debit-${header}`} value={header}>
                {header}
              </option>
            ))}
          </select>
        </label>

        <label className="text-sm text-zinc-600">
          Credit column (optional)
          <select
            className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
            value={mapping.credit}
            onChange={(event) => updateMapping("credit", event.target.value)}
            data-testid="manual-import-map-credit"
          >
            <option value="">Select column</option>
            {headers.map((header) => (
              <option key={`credit-${header}`} value={header}>
                {header}
              </option>
            ))}
          </select>
        </label>

        <label className="text-sm text-zinc-600">
          Status column (optional)
          <select
            className="mt-1 w-full rounded-md border border-zinc-300 px-3 py-2"
            value={mapping.status}
            onChange={(event) => updateMapping("status", event.target.value)}
            data-testid="manual-import-map-status"
          >
            <option value="">Select column</option>
            {headers.map((header) => (
              <option key={`status-${header}`} value={header}>
                {header}
              </option>
            ))}
          </select>
        </label>
      </div>

      <div className="flex flex-wrap gap-3">
        <button
          type="button"
          className="rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground disabled:opacity-60"
          onClick={() => {
            void handleParse();
          }}
          disabled={isBusy || accounts.length === 0}
          data-testid="manual-import-parse"
        >
          {isBusy ? "Processing..." : "Parse and stage rows"}
        </button>

        <button
          type="button"
          className="rounded-md border border-primary/40 px-4 py-2 text-sm font-semibold text-primary disabled:opacity-60"
          onClick={() => {
            void handleCommit();
          }}
          disabled={isBusy || !summary}
          data-testid="manual-import-commit"
        >
          Commit staged rows
        </button>
      </div>

      <p
        className={`text-sm ${
          saveState.status === "error"
            ? "text-rose-600"
            : saveState.status === "saved"
              ? "text-emerald-700"
              : "text-zinc-500"
        }`}
        aria-live="polite"
      >
        {saveState.message}
      </p>

      {summary ? (
        <div className="rounded-xl border border-zinc-200 bg-zinc-50 p-3 text-sm text-zinc-700">
          <p>Batch ID: {summary.batchId}</p>
          <p>
            Status: {summary.status} · Parsed rows: {summary.rowCount} · Committed:{" "}
            {summary.committedCount}
          </p>
        </div>
      ) : null}

      {rows.length > 0 ? (
        <div className="overflow-x-auto">
          <table className="w-full table-auto text-left text-sm" aria-label="Manual import staged rows">
            <thead>
              <tr className="border-b border-zinc-200 text-xs uppercase tracking-wide text-zinc-500">
                <th className="py-2 pr-3">Row</th>
                <th className="py-2 pr-3">Date</th>
                <th className="py-2 pr-3">Description</th>
                <th className="py-2 pr-3">Amount</th>
                <th className="py-2 pr-3">Parse</th>
                <th className="py-2">Decision</th>
              </tr>
            </thead>
            <tbody>
              {rows.slice(0, 20).map((row) => (
                <tr key={row.id} className="border-b border-zinc-100">
                  <td className="py-2 pr-3 text-zinc-700">{row.rowIndex}</td>
                  <td className="py-2 pr-3 text-zinc-700">{row.postedAt ?? "—"}</td>
                  <td className="py-2 pr-3 text-zinc-900">{row.description ?? "—"}</td>
                  <td className="py-2 pr-3 text-zinc-700">{row.amount ?? "—"}</td>
                  <td className="py-2 pr-3 text-zinc-700">{row.parseStatus}</td>
                  <td className="py-2 text-zinc-700">{row.reviewDecision}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {rows.length > 20 ? (
            <p className="mt-2 text-xs text-zinc-500">Showing first 20 rows of {rows.length} staged rows.</p>
          ) : null}
        </div>
      ) : null}
    </article>
  );
}
