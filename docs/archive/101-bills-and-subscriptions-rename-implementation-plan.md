# Bills & Subscriptions rename implementation plan

Tracks: [GitHub issue #83](https://github.com/MarcoBlaauw/MoneyTree/issues/83)

## Status

Completed and archived. The sidebar/page copy now reads "Bills & Subscriptions" everywhere the old
"Obligations" label appeared, and the `obligation_type` taxonomy was replaced with the issue's
expense categories (`subscription`, `utility`, `insurance`, `housing`, `debt_payment`, `tax_or_fee`,
`membership`, `other`), including a data migration that remapped existing rows and the AI
recurring-detector's mapping. `MoneyTree.Obligations`, the `obligations` table, routes, and
API/JSON field names are unchanged, as scoped. No deferred work remains from this plan; see
[the roadmap](../roadmap.md#past-work) for the completed entry.

Sequencing (historical): shipped first, before
[102](../102-vehicle-asset-management-implementation-plan.md) and
[103](../103-investment-portfolio-implementation-plan.md).

## Purpose and scope

Rename the user-facing **Obligations** navigation item and page to **Bills & Subscriptions**, and
add the optional type-categorization field from the issue in the same pass. Keep the internal
`MoneyTree.Obligations` context, `obligations` table, routes, and API/JSON field names unchanged —
this is a product-language and UI change, not a schema rename.

## Current repo fit

The obligations domain already exists and is in active use (including by the AI recurring-payment
detector, which creates `source: "model"` obligations from transaction history — see
`MoneyTree.AI.maybe_create_recurring_obligation/3`). Relevant pieces:

- `MoneyTree.Obligations` / `MoneyTree.Obligations.Obligation` — context and schema, unchanged.
- `MoneyTreeWeb.ObligationsLive.Index` at `/app/obligations` — the page being relabeled.
- `MoneyTreeWeb.ObligationController` and `/api/obligations*` — JSON API, unchanged.
- `lib/money_tree_web/components/layouts.ex` — defines the sidebar nav item:
  `%{label: "Obligations", path: ~p"/app/obligations", page_title: "Obligations"}`.

Important, non-obvious finding: **a `Type` field already exists** on the obligation form
(`obligation.obligation_type`, `lib/money_tree_web/live/obligations_live/index.ex:325`), backed by
`Obligation.@obligation_types` = `~w(bill subscription recurring_payment loan_payment
credit_card_payment other)`. This is not the field the issue is asking for, though — it's a
different, narrower taxonomy (payment mechanism, not expense category) that the AI detector also
writes to (`recurring_obligation_type/1` in `ai.ex` maps detected transactions to one of these).
So issue #83's "optional categorization" is **not new infrastructure** — it's replacing/widening
the values of an enum that already has a working form field, dropdown, and label helper. That
significantly shrinks this piece of the work.

## Copy changes

Exact strings to change (all inside `obligations_live/index.ex` unless noted):

| Location | Current | New |
| --- | --- | --- |
| `layouts.ex` nav item `label` | `"Obligations"` | `"Bills & Subscriptions"` |
| `layouts.ex` nav item `page_title` | `"Obligations"` | `"Bills & Subscriptions"` |
| `mount/3` `page_title` assign (line ~18) | `"Obligations"` | `"Bills & Subscriptions"` |
| `<.header title=...>` (line ~191) | `"Obligations"` | `"Bills & Subscriptions"` |
| `<.header subtitle=...>` | `"Track recurring payment commitments and the alerts around them."` | keep, or tighten to mention both bills and subscriptions explicitly |
| "Add obligation" buttons (2 places) | `"Add obligation"` | `"Add bill or subscription"` |
| Empty state (line ~274) | `"No obligations configured yet. Add your first recurring payment rule."` | `"No bills or subscriptions yet. Add your first recurring payment."` |
| Edit-mode header (line ~283) | `"Edit obligation"` / `"Add obligation"` | `"Edit bill or subscription"` / `"Add bill or subscription"` |
| Helper copy (line ~293) | `"Choose "Add obligation" to create a new rule, or edit one from the list."` | update to match the new button label |
| Submit button (line ~341) | `"Save changes"` / `"Add obligation"` | `"Save changes"` / `"Add bill or subscription"` |

Do not change: `id="obligation_..."` form field IDs, `name="obligation[...]"` param keys, route
paths, `phx-click`/`phx-submit` event names, or anything under `lib/money_tree_web/controllers/` —
the issue explicitly asks to keep API/route terminology as `obligation`.

Also check (grep before merging, since sidebar/breadcrumb copy tends to be duplicated):
`endpoint_test.exs`/`dashboard_live_test.exs`-style title assertions, and any dashboard widget that
links to `/app/obligations` with an "Obligations" label (dashboard summary cards reference
`MoneyTree.Obligations` for alert counts — check for a card title there too).

## Type-field realignment

Replace the existing `@obligation_types` list in `Obligation` with the issue's categories, and
migrate existing data:

- New values: `subscription`, `utility`, `insurance`, `housing`, `debt_payment`, `tax_or_fee`,
  `membership`, `other`.
- Old → new mapping for existing rows and the AI detector's `recurring_obligation_type/1`:
  - `bill` → `other` (too generic to map confidently; user can re-categorize)
  - `subscription` → `subscription` (unchanged)
  - `recurring_payment` → `other`
  - `loan_payment` → `debt_payment`
  - `credit_card_payment` → `debt_payment`
  - `other` → `other` (unchanged)
- Migration: a data migration (`Ecto.Migration` with `execute/1` `UPDATE` statements, or a
  one-off `Repo.update_all` in a `Mix.Task`) to remap existing `obligations.obligation_type`
  values before/alongside a schema migration that widens the check semantics if one exists (there
  is currently no DB-level check constraint on this column — it's a plain `varchar` validated only
  in the changeset — so no migration is strictly required for the column itself, only for the
  existing row values and the Elixir-side enum/label functions).
- Update `obligation_type_label/1` and `obligation_type_options/0` in `obligations_live/index.ex`
  to the new label set (e.g. "Utility", "Insurance", "Housing", "Debt payment", "Tax or fee",
  "Membership", "Other recurring bill").
- Update `AI.recurring_obligation_type/1` so newly auto-detected obligations land in a sensible new
  category (e.g. loan/credit-card-pattern detections → `debt_payment`, subscription-pattern
  detections → `subscription`, everything else → `other`).
- The column's DB default is `"bill"` (`priv/repo/migrations/20260521120000_...exs`); change it to
  `"other"` in the same migration so it stays a valid value after the remap.

## Acceptance criteria (from the issue, mapped to concrete checks)

- [x] Sidebar nav and page title read "Bills & Subscriptions" everywhere the old label appeared.
- [x] `/app/obligations` route, `MoneyTree.Obligations` context, `obligations` table, and
      `/api/obligations*` routes are unchanged.
- [x] Existing obligation rows (including `source: "model"` ones) still load, edit, and delete
      correctly after the type-value remap — verified directly against the dev database (the two
      `debt_payment`-mapped rows and one `subscription` row all remapped as expected) and via the
      full test suite.
- [x] Alerts/notifications tied to obligations (`MoneyTree.Obligations.Evaluator`,
      `MoneyTree.Notifications`) are unaffected — confirmed by grep: neither module reads
      `obligation_type`.
- [x] New "Type" dropdown shows the 7 new categories. No existing test hardcoded the old enum
      values (confirmed by grep across `test/`), so no test updates were needed beyond the two
      page-copy assertions in `workspace_live_test.exs` and `app_routes_test.exs` that checked for
      the literal string "Obligations".
- [x] `mix format`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` all pass
      (496 tests; no new credo/dialyzer findings introduced).

## Out of scope (per the issue)

- Renaming the database table, Ecto module, routes, or JSON field names.
- Removing recognition of the word "obligation" from search/help text.
