# Dashboard Overhaul Implementation Plan

## Purpose

Make `/app/dashboard` a compact financial cockpit instead of a long mixed-purpose page. The dashboard should answer these questions quickly:

- Am I okay right now?
- What needs attention?
- What changed recently?
- Where is my money going?
- What payments or obligations are coming up?

Detailed management belongs on dedicated pages such as Accounts, Transactions, Budgets, Obligations, Assets, Loan Center, and Settings.

## Current Codebase Baseline

Primary implementation file:

- `apps/money_tree/lib/money_tree_web/live/dashboard_live.ex`

Primary test file:

- `apps/money_tree/test/money_tree_web/live/dashboard_live_test.exs`

Related app shell files:

- `apps/money_tree/lib/money_tree_web/components/layouts.ex`
- `apps/money_tree/lib/money_tree_web/components/layouts/app.html.heex`

Related page/style references:

- `apps/money_tree/lib/money_tree_web/live/accounts_live/index.ex`
- `apps/money_tree/lib/money_tree_web/live/assets_live/index.ex`
- `apps/money_tree/lib/money_tree_web/live/notifications_live/index.ex`

The current dashboard already gathers most required data in `DashboardLive.build_metrics/2`:

- net worth from `MoneyTree.Accounts`
- savings/investments from `MoneyTree.Accounts`
- credit card balances from `MoneyTree.Accounts`
- loans from `MoneyTree.Loans`
- budgets, planner recommendations, and rollups from `MoneyTree.Budgets`
- subscriptions from `MoneyTree.Subscriptions`
- evaluation status from `MoneyTree.Evaluations`
- category rollups and recent transactions from `MoneyTree.Transactions`
- pending notification events from `MoneyTree.Notifications`

Existing dashboard components include:

- `dashboard_toolbar/1`
- `kpi_strip/1`
- `assets_panel/1`
- `budget_pulse_panel/1`
- `net_worth_panel/1`
- `savings_panel/1`
- `active_cards_panel/1`
- `loans_panel/1`
- `subscriptions_panel/1`
- `evaluation_status_panel/1`
- `fico_insights_panel/1`
- `recent_activity_panel/1`
- `category_rollups_panel/1`

## Non-Goals

- Do not add database schema changes for the dashboard overhaul.
- Do not add a real FICO or credit bureau integration.
- Do not move CRUD workflows from dedicated pages into the dashboard.
- Do not introduce a charting dependency unless a later implementation task proves it is necessary.
- Do not rewrite the app shell or navigation from scratch.
- Do not change financial calculations to AI-driven logic.

## Target Experience

Desktop layout:

```text
Left app shell      Main dashboard content              Sticky right rail
--------------      ----------------------              -----------------
Primary nav         Snapshot cards                      Needs attention
Workspace nav       Budget / cashflow pulse             Subscriptions
Sticky user block   Account category snapshot           Upcoming obligations
                    Recent important activity           Compact status cards
```

Mobile layout:

1. Header and compact controls
2. Snapshot cards
3. Needs attention
4. Budget / cashflow pulse
5. Account category snapshot
6. Recent important activity
7. Secondary summaries

## Implementation Rules For Codex

- Implement one slice at a time.
- Keep changes concentrated in `DashboardLive` until app shell work is explicitly needed.
- Prefer private helper functions in `DashboardLive` before extracting new modules.
- Preserve balance masking and lock behavior in every slice.
- Update or add tests with each behavioral change.
- Run `mix test apps/money_tree/test/money_tree_web/live/dashboard_live_test.exs` after every dashboard slice.
- Run `mix test apps/money_tree/test/money_tree_web/live/app_routes_test.exs apps/money_tree/test/money_tree_web/endpoint_test.exs` if layout/app shell behavior changes.

## Slice 1: Remove Immediate Dashboard Noise

Status: completed on 2026-05-22.

Goal: shorten the current dashboard without changing data models or page ownership.

Files:

- `apps/money_tree/lib/money_tree_web/live/dashboard_live.ex`
- `apps/money_tree/test/money_tree_web/live/dashboard_live_test.exs`

Tasks:

- Stop rendering `fico_insights_panel/1` by default.
- Keep the helper only if it will be gated behind real data or a feature flag later.
- Limit `recent_activity_panel/1` to 5 transactions on the dashboard.
- Add a `View all transactions` link to `/app/transactions`.
- Hide the full tangible asset manager when there are no tracked assets.
- Replace the empty asset manager with a compact link to `/app/assets`.

Acceptance criteria:

- The dashboard no longer shows `FICO & insights` or `Placeholder` by default.
- Empty tangible assets do not consume a large dashboard section.
- Recent activity renders at most 5 transactions.
- Users still have a visible path to Transactions and Assets.
- Balance masking still works.

Validation:

```bash
mix test apps/money_tree/test/money_tree_web/live/dashboard_live_test.exs
```

## Slice 2: Compact The Dashboard Toolbar

Status: completed on 2026-05-22.

Goal: keep useful controls while reducing visual weight.

Files:

- `apps/money_tree/lib/money_tree_web/live/dashboard_live.ex`
- `apps/money_tree/test/money_tree_web/live/dashboard_live_test.exs`

Tasks:

- Reduce `dashboard_toolbar/1` copy.
- Remove the large gradient treatment.
- Keep these controls:
  - Show / hide balances
  - Lock / unlock
  - Refresh activity
- Keep the locked-state guard that prevents revealing balances.

Acceptance criteria:

- The toolbar is a compact control row or small panel.
- Existing LiveView events still work.
- Tests still cover lock, unlock, and balance reveal behavior.

Validation:

```bash
mix test apps/money_tree/test/money_tree_web/live/dashboard_live_test.exs
```

## Slice 3: Introduce Dashboard View Helpers

Status: completed on 2026-05-22.

Goal: make later UI changes simpler without creating a new abstraction too early.

Files:

- `apps/money_tree/lib/money_tree_web/live/dashboard_live.ex`
- `apps/money_tree/test/money_tree_web/live/dashboard_live_test.exs`

Tasks:

- Add private helper functions for dashboard-specific presentation data:
  - `recent_dashboard_transactions/1`
  - `dashboard_attention_items/1`
  - `dashboard_snapshot_cards/3`
  - `dashboard_asset_summary/1`
- Keep deterministic calculations inside existing contexts where they already exist.
- Do not duplicate account, budget, or loan calculations in the LiveView.

Acceptance criteria:

- Render code becomes easier to read.
- Helpers only reshape already-loaded dashboard data.
- No behavior changes unless covered by tests.

Validation:

```bash
mix test apps/money_tree/test/money_tree_web/live/dashboard_live_test.exs
```

## Slice 4: Replace KPI Strip With Snapshot Cards

Status: completed on 2026-05-22.

Goal: make the first visible dashboard section more actionable.

Files:

- `apps/money_tree/lib/money_tree_web/live/dashboard_live.ex`
- `apps/money_tree/test/money_tree_web/live/dashboard_live_test.exs`

Target cards:

- Net worth
- Cash / savings
- Budget status
- Credit card utilization or card balance
- Due soon
- Needs review

Tasks:

- Replace `kpi_strip/1` with a snapshot card component or update `kpi_strip/1` in place.
- Remove low-value counters from the first row, such as raw account count and tracked asset count.
- Keep notification/evaluation counts, but label them as user actions instead of generic counts.
- Preserve masked values when `show_balances?` is false.

Acceptance criteria:

- The first dashboard row communicates financial status and required action.
- Snapshot cards fit in a compact grid.
- Masked state hides money values consistently.

Validation:

```bash
mix test apps/money_tree/test/money_tree_web/live/dashboard_live_test.exs
```

## Slice 5: Add A Needs Attention Panel

Status: completed on 2026-05-22.

Goal: give the right rail a clear purpose.

Files:

- `apps/money_tree/lib/money_tree_web/live/dashboard_live.ex`
- `apps/money_tree/test/money_tree_web/live/dashboard_live_test.exs`

Inputs:

- `@metrics.notifications`
- `@metrics.evaluation_summary`
- `@metrics.loans`
- `@metrics.subscription`

Tasks:

- Add a compact `needs_attention_panel/1`.
- Show at most 5 prioritized items.
- Include durable notifications first.
- Include evaluation review items next.
- Include due-soon obligation/loan/subscription items only if already available in loaded metrics.
- Provide links to the owning pages.

Acceptance criteria:

- The right rail starts with actionable items.
- Empty state is short and calm.
- No debug-like operational details appear on the dashboard.

Validation:

```bash
mix test apps/money_tree/test/money_tree_web/live/dashboard_live_test.exs
```

## Slice 6: Compress Budget And Cashflow

Status: completed on 2026-05-22.

Goal: summarize budget health instead of rendering a full budget report.

Files:

- `apps/money_tree/lib/money_tree_web/live/dashboard_live.ex`
- `apps/money_tree/test/money_tree_web/live/dashboard_live_test.exs`

Existing inputs:

- `Budgets.aggregate_totals/2`
- `Budgets.rollup_by_entry_type/2`
- `Budgets.rollup_by_variability/2`
- `Budgets.planner_recommendations/1`

Tasks:

- Keep period switching.
- Make budget totals, income vs expenses, and fixed vs variable visually compact.
- Move detailed recommendation copy behind a smaller summary or link to `/app/budgets`.
- Keep all amount calculations deterministic.

Acceptance criteria:

- Dashboard budget section is compact but still useful.
- Existing budget test expectations are updated to the new surface.
- No budget creation or editing is added to the dashboard.

Validation:

```bash
mix test apps/money_tree/test/money_tree_web/live/dashboard_live_test.exs
```

## Slice 7: Account Category Snapshot

Status: completed on 2026-05-22.

Goal: show account composition without rendering an account list.

Files:

- `apps/money_tree/lib/money_tree_web/live/dashboard_live.ex`
- `apps/money_tree/test/money_tree_web/live/dashboard_live_test.exs`

Inputs:

- `Accounts.dashboard_summary/1`
- `Accounts.net_worth_snapshot/1`
- `Accounts.savings_and_investments_summary/1`
- `Accounts.running_card_balances/1`
- `Loans.overview/1`

Tasks:

- Add compact rows for cash, credit cards, loans, and tangible assets when present.
- Link to `/app/accounts`, `/app/loans`, and `/app/assets`.
- Do not render individual account records.

Acceptance criteria:

- Dashboard remains a summary page.
- Existing test `dashboard does not render the full accounts list` continues to pass.
- Empty categories stay hidden or use a one-line empty state.

Validation:

```bash
mix test apps/money_tree/test/money_tree_web/live/dashboard_live_test.exs
```

## Slice 8: Sticky User And Session Controls

Status: completed on 2026-05-22.

Goal: keep session controls reachable on long pages.

Files to inspect before editing:

- `apps/money_tree/lib/money_tree_web/components/layouts.ex`
- `apps/money_tree/lib/money_tree_web/components/layouts/app.html.heex`

Tasks:

- Make the app shell use a stable vertical layout.
- Keep the primary navigation scrollable when needed.
- Keep the user/session block pinned near the bottom on desktop.
- Verify mobile still exposes the same controls.
- Avoid duplicating session controls across the sidebar and dashboard more than necessary.

Acceptance criteria:

- Settings/security/session actions remain visible or immediately reachable on long dashboards.
- Existing app routes render normally.
- Dashboard lock controls still work.

Validation:

```bash
mix test apps/money_tree/test/money_tree_web/live/app_routes_test.exs apps/money_tree/test/money_tree_web/endpoint_test.exs
mix test apps/money_tree/test/money_tree_web/live/dashboard_live_test.exs
```

## Slice 9: Visual Polish Pass

Status: completed on 2026-05-22.

Goal: align dashboard styling with the stronger Accounts & Institutions direction.

Files:

- `apps/money_tree/lib/money_tree_web/live/dashboard_live.ex`
- shared components only if an existing component needs a narrow reusable improvement

Tasks:

- Use compact cards with consistent borders, spacing, badges, and row layouts.
- Use progress bars only where the underlying value is meaningful.
- Keep colors functional: status, debt, income, expense, attention, neutral.
- Avoid oversized panels, placeholder content, and decorative gradients.

Acceptance criteria:

- Dashboard is scan-friendly above the fold.
- No card contains unrelated management UI.
- No text overlaps or awkwardly wraps in common desktop/mobile widths.

Validation:

```bash
mix test apps/money_tree/test/money_tree_web/live/dashboard_live_test.exs
```

If visual verification is needed, run the app through the repository dev entrypoint:

```bash
./scripts/dev.sh
```

Then inspect `/app/dashboard` on desktop and mobile widths.

## Recommended Next Step

Dashboard overhaul slices 1 through 9 are complete.

Recommended follow-up after review:

- run the app locally and inspect `/app/dashboard` at desktop and mobile widths
- capture any remaining visual issues as targeted polish tasks
- continue with the next implementation plan only after the dashboard experience is accepted

## Completion Criteria

The dashboard overhaul is complete when:

- the first screen is useful without scrolling on a standard desktop viewport
- placeholder-only features are hidden
- management workflows live on dedicated pages
- right rail content is actionable
- recent activity and category data are compact summaries
- balance masking and session locking still work
- dashboard LiveView tests pass
- app shell tests pass if shell layout was touched
