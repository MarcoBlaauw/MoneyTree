# Dashboard Overhaul Implementation Plan

## Purpose

This plan defines the next MoneyTree dashboard redesign pass.

The current dashboard has useful data, but it is trying to serve too many roles at once: financial cockpit, account list, budget report, transaction feed, alert center, subscriptions tracker, loan overview, tangible asset manager, and future FICO placeholder. The result is a long page with too many large elements and too many equally weighted sections.

The redesigned dashboard should be a glanceable financial cockpit. It should quickly answer:

- Am I financially okay right now?
- What changed recently?
- What needs attention?
- Where is my money going?
- What payments or obligations are coming up?

Detailed exploration should move users into dedicated pages such as Accounts, Transactions, Budgets, Assets, Loan Center, and Settings.

## Design Direction

Use the stronger visual language already emerging in the Accounts & Institutions experience:

- compact cards
- grouped financial categories
- color-coded account/debt/asset rails
- clean row-based summaries
- stronger distinction between high-level totals and underlying records
- consistent status badges

The dashboard should summarize; the other pages should explain.

## Primary UX Goals

1. Reduce above-the-fold clutter.
2. Make the first screen useful without scrolling.
3. Hide unfinished or unavailable features until there is real data.
4. Replace full lists with compact grouped summaries.
5. Use color and simple visualizations to communicate status quickly.
6. Keep security/session actions easy to reach.
7. Preserve balance masking and session locking behavior.
8. Keep the implementation incremental enough for Codex to execute safely.

## Current-State Assessment

### What Works

- Balance masking and dashboard lock behavior are already useful.
- The dashboard already gathers most of the needed data through existing contexts.
- The right sticky rail is a good interaction pattern on desktop.
- The current card styling is clean enough to evolve instead of replacing everything.
- The Accounts & Institutions styling provides a better product direction for grouped financial data.

### What Does Not Work

- The dashboard is too long and requires excessive scrolling.
- Large cards compete for attention even when their content is low priority.
- The FICO placeholder looks like an unfinished product feature.
- Tangible assets waste dashboard space when no assets are tracked.
- Full card/account lists belong on the Accounts page, not the dashboard.
- The sticky right rail currently mixes useful items with placeholder and operational/debug-like content.
- Recent activity and category rollups are useful, but too large for a quick dashboard.
- User/session controls are too far down the sidebar on long pages.

## High-Level Target Layout

### Desktop Layout

Use a persistent left app shell, a main dashboard region, and an optional sticky right rail.

```text
Left sidebar      Main dashboard content              Sticky right rail
-----------       ----------------------              -----------------
Primary nav       Financial snapshot cards            Today / attention
Workspace nav     Cashflow and budget pulse           Subscriptions
Sticky user       Account category snapshot           Upcoming obligations
session block     Recent important activity           Optional compact modules
```

### Tablet Layout

Collapse the right rail into a top-level `Today` or `Needs attention` card above the main modules.

### Mobile Layout

Use single-column stacking:

1. Header and controls
2. Financial snapshot
3. Needs attention
4. Cashflow / Budget pulse
5. Account category snapshot
6. Recent activity
7. Secondary summaries

## Implementation Phases

## Phase 1: Remove Noise and Protect the Existing Experience

### 1.1 Hide FICO Until Data Exists

The current `fico_insights_panel` should not render by default.

Recommended behavior:

- Hide the FICO card entirely unless `features.credit_insights.enabled` is true or real credit score data exists.
- Do not show a placeholder card on the dashboard.
- Keep the component code only if it will be reused soon; otherwise remove it from the dashboard render path.

Suggested implementation options:

```elixir
if feature_enabled?(:credit_insights) do
  <.fico_insights_panel />
end
```

or:

```elixir
if @metrics.credit_insights.available? do
  <.credit_insights_panel insights={@metrics.credit_insights} />
end
```

Initial v1 can use a simple application config flag.

Suggested files:

- `apps/money_tree/lib/money_tree_web/live/dashboard_live.ex`
- `apps/money_tree/config/config.exs` or environment-specific config if feature flags already exist

Acceptance criteria:

- Dashboard no longer renders `FICO & insights` by default.
- No placeholder card appears when no bureau/score data exists.
- The right rail becomes shorter immediately.

### 1.2 Hide Empty Tangible Assets on the Dashboard

The Tangible Assets panel should not consume dashboard space when there are no tracked assets.

Recommended behavior:

- If `asset_summary.total_count == 0`, show only a compact KPI or a small call-to-action.
- Better: remove the full asset manager from the dashboard and link to the Assets page.
- Keep asset CRUD on the Assets page, not the dashboard.

Acceptance criteria:

- Empty tangible asset form/card no longer appears as a large dashboard section.
- Users still have an obvious path to add assets from either the Assets page or a small dashboard CTA.

### 1.3 Limit Recent Activity

Recent activity should show only a small number of meaningful items.

Recommended behavior:

- Show 5 items by default.
- On large desktop layouts, optionally show up to 8.
- Include a `View all transactions` link.
- Prioritize meaningful activity later: large transactions, uncategorized transactions, new recurring detections, or unusual spending.

Acceptance criteria:

- Dashboard recent activity is visually compact.
- Full transaction history remains available through Transactions.

## Phase 2: Sticky Session and App Shell Adjustments

### 2.1 Make User/Session Block Sticky

The user/session block at the bottom-left of the app shell should remain accessible even on long pages.

Recommended desktop sidebar structure:

```text
MoneyTree
Workspace

Primary nav
Workspace nav

[sticky bottom]
User avatar/name/email
Settings
Security
Lock / Log out
```

Implementation notes:

- Use a flex column layout for the sidebar.
- Let navigation scroll if needed.
- Pin the user/session area with `mt-auto`, `sticky bottom-0`, or a fixed-height shell depending on current layout.
- Avoid duplicating too many session controls in both the sidebar and dashboard toolbar.

Acceptance criteria:

- User/session controls remain visible or immediately reachable on long dashboards.
- Settings, preferences, security, and lock/logout actions are not buried below the page fold.
- Mobile drawer still exposes the same actions cleanly.

### 2.2 Keep Dashboard Controls Compact

The dashboard toolbar should stay, but should be less visually dominant.

Keep:

- Show / hide balances
- Refresh activity
- Lock

Reduce:

- long explanatory text
- oversized gradient card treatment

Acceptance criteria:

- Controls remain available without taking up too much vertical space.
- Balance masking and lock behavior continue to work.

## Phase 3: New Dashboard Information Architecture

### 3.1 Replace KPI Strip With Better Snapshot Cards

The first dashboard row should be a financial snapshot, not a generic metric strip.

Recommended cards:

1. Net Worth
2. Cash Available
3. Budget Status
4. Credit Utilization
5. Due Soon
6. Needs Review

Optional additional card:

- Subscriptions, only if recurring subscriptions exist

Avoid over-weighting low-value metrics such as raw account count unless there is a sync issue or data completeness concern.

Each snapshot card should have:

- one primary value
- one short status label
- one trend or context note
- optional badge color

Example:

```text
Budget
Healthy
63% used this month
```

Status color rules:

```text
Green  = healthy / normal
Yellow = watch / approaching limit
Red    = action needed / overdue / over budget
Blue   = informational
Gray   = unavailable / neutral / no data
```

Acceptance criteria:

- First screen quickly communicates financial state.
- Cards are more meaningful than `Accounts: 22` or `Tracked assets: 0`.
- Snapshot cards are compact and responsive.

### 3.2 Add a `Today / Needs Attention` Panel

Replace the current right rail alert stack with a dashboard-friendly attention summary.

Recommended sections:

- Critical
- Needs review
- Upcoming
- Opportunity

Example content:

```text
Critical
- Recurring missing cycle: PayPal series
- Recurring missing cycle: Uber/Eats series

Needs review
- 34 transactions need categorization
- 3 possible subscriptions detected

Upcoming
- 1 loan payment due in 7 days

Opportunity
- Truck loan refinance may save money if current rates improve
```

Implementation notes:

- Show top 3 to 5 items only.
- Group repeated recurring-cycle anomalies instead of rendering several nearly identical cards.
- Link to the review/evaluation center for the full list.
- Keep severity badges, but reduce card repetition.

Acceptance criteria:

- The dashboard no longer displays a long list of repeated evaluation cards.
- Users can immediately see the most important actions.
- Full detail remains available through the relevant review page.

### 3.3 Use Conditional Sections

Dashboard modules should render only when useful.

Recommended rules:

```text
Show FICO only if credit insight data exists.
Show tangible assets only if assets exist, or show a tiny CTA.
Show loans/autopay only if loans exist.
Show subscriptions only if recurring merchants exist.
Show alerts only if unresolved alerts exist.
Show recent activity only if transactions exist.
Show category rollups only if there is meaningful spending data.
```

Acceptance criteria:

- Empty or future-state modules do not dominate the dashboard.
- Users with sparse data get a cleaner onboarding-oriented view.
- Users with rich data get a dense but still readable dashboard.

## Phase 4: Rebuild Core Dashboard Modules

### 4.1 Cashflow This Month

Add a compact cashflow module focused on monthly status.

Recommended content:

- income
- expenses
- projected surplus/deficit
- actual vs projected progress
- optional small trend/sparkline later

Initial visual format:

- horizontal bars for income vs expenses
- status badge for surplus/deficit
- concise month-to-date context

Acceptance criteria:

- User can quickly determine whether the month is trending positive or negative.
- Module is smaller than the current budget analysis blocks.

### 4.2 Budget Pulse

Compress budget pulse into a glanceable progress list.

Recommended format:

```text
Housing         █████████░░ 84%   Healthy
Groceries       ███████░░░░ 62%   Healthy
Transportation  ████░░░░░░░ 37%   Normal
Dining          ██░░░░░░░░░ 18%   Normal
Shopping        █░░░░░░░░░░ 11%   Normal
```

Implementation notes:

- Show top 5 budget groups by allocated amount, actual spend, or risk.
- Use status colors consistently.
- Move detailed allocated/actual/projected breakdowns to the Budgets page.

Acceptance criteria:

- Budget status is scannable in under 5 seconds.
- The dashboard does not render multiple oversized budget cards.
- Users can click through to the Budgets page for detail.

### 4.3 Account Category Snapshot

Replace full account/card lists with grouped summaries using the Accounts page visual language.

Recommended groups:

- Operating Cash
- Cash Reserves
- Revolving Debt
- Installment Debt
- Invested Assets

Example:

```text
Operating Cash
Checking        USD •••
Available       USD •••

Revolving Debt
Credit cards    USD •••
Utilization     12%

Installment Debt
Loans           USD •••
Next due        Jan 13
```

Implementation notes:

- Use the same color identity as the Accounts page category rails.
- Do not render every account on the dashboard.
- Show subtotals and top 1 to 3 representative rows only when helpful.
- Provide `View accounts` link.

Acceptance criteria:

- Dashboard account data visually matches the Accounts experience.
- Credit cards are summarized instead of listed one by one.
- Users can still navigate to full account details.

### 4.4 Debt Overview

Add a compact debt module if loans or credit card debt exist.

Recommended content:

- total revolving debt
- total installment debt
- utilization
- next payment due
- autopay status warnings

Acceptance criteria:

- Debt health is visible without requiring the full Accounts or Loan Center pages.
- Autopay disabled or payment due soon states are surfaced clearly.

### 4.5 Savings & Investments

Keep this section compact.

Recommended content:

- total saved
- invested total
- savings/investment allocation split
- trend later if historical data exists

Acceptance criteria:

- Savings and investments stay visible but do not crowd out budget and attention items.

## Phase 5: Visual System Improvements

### 5.1 Introduce Dashboard Card Densities

Define reusable card density patterns:

- `summary`: shallow KPI card
- `standard`: normal dashboard module
- `compact-list`: short list with 3 to 5 rows
- `analysis`: chart/progress module for main column only

Implementation notes:

- This can be implemented as component variants, helper class functions, or small wrapper components.
- Avoid dense analytical cards in the right rail.

Acceptance criteria:

- Dashboard modules feel intentionally sized.
- Sidebar modules are not as visually heavy as main modules.

### 5.2 Add Simple Visualizations

Start with simple CSS-based visuals before introducing a charting library.

Recommended v1 visuals:

- progress bars
- utilization bars
- donut-style asset/liability chart using CSS or SVG
- tiny sparklines only if historical data is available

Do not block the redesign on a charting library.

Possible future charting options:

- CSS/SVG components for simple internal charts
- Chart.js or ECharts if richer interactive charts become necessary

Acceptance criteria:

- Dashboard is more visual without adding unnecessary dependency weight.
- All visuals have text equivalents and accessible labels.

### 5.3 Consistent Color Map

Use a stable financial color map.

Suggested mapping:

```text
Emerald / green  = cash, positive, healthy
Lime             = savings / reserves
Pink / rose      = revolving debt / credit card risk
Orange           = installment debt / loans
Blue             = investments / long-term assets
Amber            = watch / upcoming / caution
Red              = critical / overdue / over budget
Zinc / gray      = neutral / unavailable / masked
```

Acceptance criteria:

- Same financial concepts use the same colors across Dashboard and Accounts.
- Status colors are not confused with category colors.

## Phase 6: Data and Helper Changes

### 6.1 Dashboard View Model

The current `build_metrics/2` map is useful, but the redesigned dashboard will be easier to maintain if it exposes dashboard-specific view models.

Recommended additions:

```elixir
%{
  snapshot_cards: [...],
  attention_items: [...],
  account_groups: [...],
  budget_pulse: [...],
  cashflow: %{...},
  debt_summary: %{...}
}
```

Avoid pushing too much formatting logic into the template.

Acceptance criteria:

- Render code becomes simpler and more declarative.
- Status/severity logic is centralized and testable.

### 6.2 Attention Item Aggregation

Create a helper that converts notifications/evaluation records into dashboard attention groups.

Recommended output shape:

```elixir
%{
  severity: :critical | :warning | :review | :info | :opportunity,
  title: "Recurring missing cycles",
  summary: "3 recurring series need review",
  count: 3,
  href: "/app/...",
  items: [...]
}
```

Acceptance criteria:

- Repeated anomalies are grouped.
- Right rail remains short.
- Full details are still reachable.

### 6.3 Account Grouping Helper

Create or reuse account grouping logic so Dashboard and Accounts share the same financial category language.

Suggested groups:

- `:operating_cash`
- `:cash_reserves`
- `:revolving_debt`
- `:installment_debt`
- `:invested_assets`

Acceptance criteria:

- Dashboard and Accounts do not drift into different naming/color systems.
- New account types can be mapped in one place.

## Phase 7: Suggested File-Level Work

### Dashboard LiveView

Primary file:

- `apps/money_tree/lib/money_tree_web/live/dashboard_live.ex`

Expected changes:

- Replace the current render layout with the new information architecture.
- Remove or gate `fico_insights_panel`.
- Replace full account/card panels with grouped summary panels.
- Add compact `today_attention_panel`.
- Add `cashflow_panel`.
- Compress `budget_pulse_panel`.
- Limit recent activity.
- Add conditional rendering rules.

### Accounts Components / Shared UI

Likely files to inspect or create:

- `apps/money_tree/lib/money_tree_web/live/accounts_live/index.ex`
- `apps/money_tree/lib/money_tree_web/components/core_components.ex`
- any existing layout/app shell component files

Expected changes:

- Extract reusable category rail/card styling if not already componentized.
- Share color/category helpers between Accounts and Dashboard.

### App Shell / Sidebar

Likely files to inspect:

- Phoenix layout templates/components under `apps/money_tree/lib/money_tree_web/components/`
- any app shell or navigation LiveView/layout modules

Expected changes:

- Make user/session block sticky or pinned at bottom of sidebar.
- Keep settings/security/preferences quickly accessible.
- Ensure mobile drawer still works.

### Context / Data Layer

Likely contexts:

- `MoneyTree.Accounts`
- `MoneyTree.Budgets`
- `MoneyTree.Loans`
- `MoneyTree.Notifications`
- `MoneyTree.Subscriptions`
- `MoneyTree.Transactions`
- `MoneyTree.Assets`

Expected changes:

- Add dashboard-specific aggregation helpers only where needed.
- Avoid large schema changes for this redesign.
- Keep v1 mostly presentational/aggregation-oriented.

## Phase 8: Testing Plan

### LiveView / Render Tests

Add or update tests for:

- FICO panel hidden by default.
- FICO panel renders only when enabled or when data exists.
- Tangible assets full panel does not render when empty.
- Recent activity is limited.
- Attention items group repeated alerts.
- Balance masking still masks all sensitive values.
- Locking dashboard hides balances.
- Empty dashboard data produces useful but compact empty states.

### Helper Tests

Add tests for:

- account category grouping
- dashboard snapshot card status calculation
- budget pulse status calculation
- attention item grouping
- debt summary calculation

### Responsive Smoke Checks

Manually verify:

- desktop large width
- laptop width
- tablet width
- mobile width
- long dashboard with many alerts
- sparse dashboard with minimal data
- balances visible vs masked
- locked vs unlocked

## Phase 9: Suggested Codex Execution Slices

### Slice 1: Remove placeholders and reduce immediate noise

- Gate/hide FICO.
- Limit recent activity.
- Hide full tangible assets panel when empty.
- Keep behavior otherwise unchanged.

### Slice 2: Sticky user/session block

- Update app shell/sidebar layout.
- Make session/settings actions easy to reach.
- Verify desktop and mobile behavior.

### Slice 3: Snapshot card redesign

- Replace KPI strip contents with Net Worth, Cash Available, Budget Status, Credit Utilization, Due Soon, Needs Review.
- Add status badge/color helper.

### Slice 4: Attention panel

- Build `today_attention_panel`.
- Group repeated notifications/evaluation issues.
- Move right rail toward short-form action summaries.

### Slice 5: Budget and cashflow compression

- Add compact cashflow module.
- Compress budget pulse into progress-list format.
- Move detailed budget analysis out of dashboard.

### Slice 6: Account category snapshot

- Reuse/extract Accounts page category rail visual style.
- Replace full account/card lists with grouped summaries.

### Slice 7: Polish and visual consistency

- Finalize colors.
- Add simple CSS/SVG visuals.
- Normalize card density.
- Responsive pass.

## Non-Goals for This Pass

Do not implement these as part of the dashboard overhaul unless they are already nearly complete:

- real FICO import/integration
- full credit score trend analysis
- a new charting library migration
- deep budget redesign
- full transaction intelligence/review center rewrite
- major schema changes
- new loan/refinance calculations

## Final Target Experience

The finished dashboard should feel like this:

```text
Dashboard

[Show balances] [Refresh] [Lock]

Financial snapshot
[Net worth] [Cash] [Budget] [Credit usage] [Due soon] [Needs review]

Main content
[Cashflow this month]      [Needs attention]
[Budget pulse]             [Subscriptions / upcoming]
[Account category summary]
[Debt overview]
[Recent important activity]
```

A user should be able to understand the household financial state in under 10 seconds, then click into a dedicated page only when they want details.

## Success Criteria

The overhaul is successful when:

- the first screen gives a useful financial overview without scrolling
- unfinished FICO placeholders are gone
- the sidebar user/session area is easy to access
- dashboard sections are conditional and data-aware
- accounts and debt are summarized instead of fully listed
- budget status is readable at a glance
- attention items are grouped and actionable
- the dashboard visually matches the stronger Accounts page direction
- detailed pages remain the place for full lists and management workflows
