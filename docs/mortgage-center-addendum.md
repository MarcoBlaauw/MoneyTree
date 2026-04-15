# Mortgage Center addendum

This addendum refines `docs/mortgage-refinance-implementation-plan.md` and clarifies the recommended
product shell for the first implementation slices.

## Recommendation

Start with a **Mortgage Center**, not a broad **Home Owner Center**.

## Why Mortgage Center should come first

The current implementation plan already treats the mortgage as the anchor record that refinance analysis,
imports, alerts, escrow, and future rate tracking all attach to. Starting with a Mortgage Center keeps the
initial product surface aligned with that data model and avoids premature scope growth.

A broader Home Owner Center is still a good future direction, but it would likely pull in additional domains
before the mortgage workflow is stable, such as:

- homeowners insurance management
- property tax tracking
- HOA management
- maintenance scheduling
- document vault behavior beyond mortgage statements
- home value / equity monitoring
- warranty and appliance records

Those may belong in MoneyTree later, but they should not become blockers for getting mortgage tracking and
refinance analysis working well.

## Product sequencing rule

For the first several phases, treat the Mortgage Center as the dedicated home-finance workspace for mortgage
tracking and refinance analysis.

Later, if the product expands into broader property ownership workflows, the Mortgage Center can become a
subsection of a future Home Owner Center.

## Recommended IA now

Use the following top-level concept in the Next app:

- Mortgage Center
  - Overview
  - Current mortgage
  - Escrow
  - Refinance analysis
  - Statements & imports
  - Alerts
  - Rate watch

## Recommended IA later

If MoneyTree grows into broader property ownership management, evolve toward:

- Home Owner Center
  - Mortgage Center
  - Insurance
  - Property taxes
  - HOA
  - Maintenance
  - Home documents
  - Value / equity

## UX implication for the current plan

The routes proposed in `docs/mortgage-refinance-implementation-plan.md` should be treated as Mortgage Center
routes, even if the path segment remains `/app/react/mortgages` initially.

Recommended interpretation:

- `/app/react/mortgages` → Mortgage Center overview
- `/app/react/mortgages/[mortgageId]` → Mortgage Center detail
- `/app/react/mortgages/[mortgageId]/refinance` → Mortgage Center refinance workspace
- `/app/react/mortgages/[mortgageId]/imports` → Mortgage Center statements/imports workspace
- `/app/react/mortgages/[mortgageId]/alerts` → Mortgage Center alerts workspace

## Phase adjustment

This addendum changes the framing of Phase 1.

### Revised Phase 1 framing

Goal: create the Mortgage Center shell, store mortgages, and show them in the app.

Tasks:

1. add `mortgages` and `mortgage_escrow_profiles` tables
2. add backend schemas and context functions
3. add contracts for CRUD endpoints
4. add Phoenix controller endpoints
5. add a Next Mortgage Center overview page
6. add a Next mortgage detail page
7. allow manual entry and editing only

### Revised Phase 1 exit criteria

- user can create, edit, and view a mortgage
- user lands in a Mortgage Center overview instead of a disconnected calculator flow
- escrow values are stored separately but displayed together
- the product shell leaves clear room for refinance, imports, and alerts

## Guidance for Codex prompts

When asking Codex to implement Phase 1, refer to the new feature as a **Mortgage Center**.

Suggested wording:

> Build the initial Mortgage Center shell for MoneyTree using the structure described in
> `docs/mortgage-refinance-implementation-plan.md` and `docs/mortgage-center-addendum.md`.
> The initial slice should focus on mortgage CRUD, escrow storage, and a Mortgage Center overview page.
> Do not implement broader Home Owner Center features yet.

## Final stance

Mortgage Center first is the cleaner move.

It gives MoneyTree:

- a coherent entry point
- better long-term information architecture
- less scope creep
- a more natural place to plug in imports, alerts, and refinance analysis

Home Owner Center can come later, once there is enough non-mortgage homeowner functionality to justify it.
