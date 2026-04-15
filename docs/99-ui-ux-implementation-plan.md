# UI/UX Implementation Plan: Dashboard Layout and Visual System

## Purpose

This plan updates the existing dashboard UI in `apps/money_tree/lib/money_tree_web/live/dashboard_live.ex` without assuming a greenfield redesign.

The current dashboard already has the right data modules and a usable card system, but the layout is over-constrained:

- the page uses an `xl:grid-cols-3` shell
- the right rail is only one grid column wide
- that same rail contains dense, table-like cards
- some cards inside the rail create another two-column grid

This is why modules such as `Budget pulse`, `Income vs. expenses`, and `Fixed vs. variable` feel too narrow even though the visual styling is otherwise functional.

## Current-State Assessment

### What is working

- Card styling, spacing, and visual hierarchy are now mostly present.
- The dashboard has clear module boundaries.
- Empty states and action buttons are already in place.
- The page has a sensible top-to-bottom information order.

### What is not working

- The right rail is being used for both lightweight alerts and dense financial analysis.
- The `Budget pulse` card is too information-dense for a sidebar column.
- Nested grids inside narrow cards cause compressed labels, awkward wrapping, and poor scanability.
- The dashboard plan in its previous form was too generic and did not account for the actual LiveView composition already in the codebase.

## Updated UX Principles

1. Keep dense analytical content in the main content region.
2. Reserve the right rail for short-form, glanceable modules.
3. Avoid nested multi-column layouts inside already narrow containers.
4. Treat responsiveness as a layout concern first, not a cosmetic concern.
5. Add charts only after card placement and sizing rules are stable.

## Dashboard Information Architecture

### Top Summary Strip

Above the fold, add or retain a compact KPI band for:

- Net worth
- Cash available
- Budget status
- Upcoming obligations
- Savings rate

These should be shallow cards with one key number, one context label, and one optional trend or status note.

### Main Content Region

The main content region should hold modules that require reading, comparison, or repeated numeric scanning:

- Accounts
- Tangible assets
- Household net worth
- Savings & investments
- Active cards
- Loans & autopay
- Budget pulse
- Recent activity
- Category rollups

### Right Rail

The right rail should only contain compact, glanceable modules:

- Notifications
- Upcoming bills or obligations
- Subscription summary
- FICO placeholder or future score summary

If a module needs multiple rows of financial comparisons, stacked metric groups, or nested grids, it does not belong in the sidebar.

## Required Layout Changes

### 1) Replace the symmetric three-column shell

The current `xl:grid-cols-3` structure is too rigid for the module mix on the page.

Recommended direction:

- use a two-region shell at large sizes
- main region: approximately 2fr to 3fr
- sidebar: approximately 1fr, with a practical minimum width

Acceptable implementations:

- CSS grid with explicit column sizing such as `xl:grid-cols-[minmax(0,2fr)_minmax(320px,1fr)]`
- CSS grid with a similar `3fr/1.15fr` split
- flex layout with a constrained sidebar width and flexible main content

### 2) Move `Budget pulse` into the main region

`Budget pulse` currently contains:

- budget cards
- recommendation items
- two rollup panels
- repeated financial line items

That is main-column content, not sidebar content.

### 3) Prevent nested two-column analytics in narrow containers

Inside compact cards:

- default to single-column metric stacks
- only promote to two columns when the parent container is known to be wide enough

For the current dashboard, this means:

- avoid `md:grid-cols-2` inside cards that may appear in the sidebar
- only use two-column analytical subgrids in full-width or main-column modules

### 4) Give bottom sections the same page rhythm

`Recent activity` and `Category rollups` are currently below the main shell and visually disconnected from the analytical cards above.

They should remain below the main shell, but spacing and grouping should reflect that they are part of the same dashboard narrative:

- summary and management modules above
- analysis modules in the main middle section
- transaction/detail lists below

## Module Placement Rules

### Sidebar-Eligible Modules

A module may live in the right rail only if most of its rows are:

- one-line status messages
- badges
- single value summaries
- very short action prompts

Examples:

- Notifications
- Upcoming obligations
- Subscription total
- Credit score summary

### Main-Column Modules

A module must move to the main column if it includes:

- more than 3 repeated financial rows
- comparison of allocated vs actual vs projected values
- nested sections
- tables or table-like lists
- multiple action controls

Examples:

- Budget pulse
- Accounts
- Loans & autopay
- Savings & investments

## Visual System Guidance

### Card Density

Introduce three card densities and use them intentionally:

- `summary`: shallow KPI cards
- `standard`: most dashboard modules
- `dense`: only for list-heavy or analytic blocks in the main column

The sidebar should not use `dense` cards.

### Typography

- Reduce reliance on equal-size text rows in financial cards.
- Promote primary values more aggressively.
- De-emphasize labels and helper text.
- Prevent small uppercase metadata from competing with primary content.

### Status Colors

Keep the current semantic direction, but use it more sparingly:

- green for healthy or positive
- amber for caution
- red for negative or urgent
- neutral tones for supporting text

Do not use semantic colors as a substitute for spacing or hierarchy.

## Charts and Visualizations

Charts are still a valid direction, but they should come after layout correction.

### Phase-in rule

1. Fix shell layout and widget placement.
2. Normalize card density and metric hierarchy.
3. Add lightweight visuals such as progress bars or sparkline trends.
4. Add richer charts only where the underlying region has enough width.

### Good first visuals for the existing UI

- budget progress bars in `Budget pulse`
- utilization bars for active cards
- mini trend indicators for net worth and savings
- category spend bars in `Category rollups`

### Charts that should wait

- large donut or treemap visualizations in the sidebar
- dense multi-series charts inside narrow cards
- interactions that require new drilldown patterns before layout is stable

## Accessibility and Readability Rules

- Do not rely on color alone for budget or variance status.
- Keep text wrapping predictable in narrow layouts.
- Ensure button labels stay readable without truncation.
- Preserve keyboard and screen-reader access for dismissible notifications and dashboard actions.
- Maintain readable numeric alignment for currency values.

## Implementation Plan

### Phase 1: Layout Correction

- Replace the current three-column shell with a `main + aside` layout.
- Move `Budget pulse` to the main content region.
- Keep only compact modules in the right rail.
- Remove or reduce nested two-column subgrids inside compact cards.

Status:
- Completed in `dashboard_live.ex`.
- The dashboard now uses a wider main-content region with a constrained sidebar.
- Dense analytical modules were moved out of the sidebar.

### Phase 2: Density and Hierarchy

- Introduce explicit summary/standard/dense card variants.
- Rebalance font sizes, spacing, and row treatments.
- Tighten metadata and helper text styling.

Status:
- Largely completed in `dashboard_live.ex`.
- KPI cards, analytical panels, notifications, activity rows, and management cards now follow a clearer visual hierarchy.
- The top dashboard toolbar now uses a dedicated control surface instead of loose standalone buttons.

### Phase 3: Lightweight Visuals

- Add progress bars and trend indicators to main-column analytical modules.
- Add minimal visual summaries to sidebar cards without increasing density.

Status:
- Completed for the current implementation scope.
- Progress meters, utilization bars, comparison bars, and category share bars are now in place.
- Sidebar cards remain compact and use light summary treatments rather than dense charts.

### Phase 4: Richer Visual Dashboard Modules

- Add charts only where the container width supports them.
- Add drilldowns after layout and module ownership are stable.

Status:
- Partially completed.
- Main-column composition visuals now exist for net worth and savings allocation.
- The sidebar intentionally avoids dense chart modules.
- Additional drilldowns remain optional future work, not a blocker for the current dashboard restyling plan.

## Codebase Mapping

This plan should be implemented primarily in:

- `apps/money_tree/lib/money_tree_web/live/dashboard_live.ex`
- shared UI classes in `apps/ui/index.css`
- any future dashboard-specific helpers extracted from the LiveView template

If the dashboard is later split into component partials, preserve this layout rule:

- analytics-heavy components belong in the main region
- status-heavy components belong in the sidebar

## Success Criteria

The plan should be considered successful when:

- the sidebar no longer contains cards that feel cramped or table-like
- `Budget pulse` reads comfortably without forced wrapping or compressed metric blocks
- the dashboard can scale to more data without collapsing visually
- future chart work can be added without redesigning the shell again

Current assessment:
- These criteria are now substantially met by the current implementation.
- The remaining work is refinement, not structural correction.

## Remaining Dashboard Work

The following items are still reasonable future dashboard enhancements, but they are no longer required to complete the current restyling plan:

- extract the internal function components from `dashboard_live.ex` into dedicated dashboard component modules if the file becomes harder to maintain
- add historical trend charts only after reliable time-series aggregates are exposed by the backend
- add deeper drilldowns only when the interaction model for transactions, accounts, and budgets is defined at the product level

## Plan Status

This dashboard implementation plan should now be treated as completed for the current scope.

What this plan does not cover:

- multi-page app navigation
- hamburger or drawer navigation
- user context menus
- account management information architecture
- security UX for 2FA, passkeys, security keys, recovery methods, and device management

Those belong in a separate app-shell and account/security UX plan rather than extending this dashboard-specific document.
