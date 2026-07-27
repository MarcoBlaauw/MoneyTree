# AGENTS.md

## Purpose

This repository is a MoneyTree monorepo for a personal finance application evolving into a financial evaluation platform.

AI coding agents must extend the existing codebase conservatively and follow the actual app boundaries in this repo.

---

## Core Principles

* Do NOT redesign the application from scratch
* Prefer extending existing modules over creating new ones
* Follow existing naming, folder structure, and patterns
* Keep implementations simple and incremental
* Avoid unnecessary abstractions
* Do not introduce breaking changes unless explicitly required

---

## Planning vs Execution

* Planning tasks are handled by higher-level models
* Codex is used for execution only
* When given a task, assume it is already approved and scoped
* Do not start coding immediately if the task is clearly planning-oriented

### Planning Output Format

When asked for a plan:

* Inspect the relevant code before proposing changes
* Anchor recommendations to actual files/modules
* Break work into small, independent, executable tasks
* Note assumptions, blockers, and migration order
* Prefer incremental rollout over large rewrites
* If the plan is persisted in the repository, follow the documentation lifecycle below

---

## Documentation Planning And Lifecycle

`docs/roadmap.md` is the canonical source for delivery status, sequencing, deferred work, and future work. Do not maintain a competing status list in `README.md`, an implementation plan, or an archived document.

### Document Placement

* Keep active implementation plans directly under `docs/`
* Keep current architecture, scaffolding, technical references, research, and runbooks under `docs/architecture/`
* Move completed, superseded, or redundant plans to `docs/archive/`
* Keep `docs/architecture/README.md` and `docs/archive/README.md` current as the indexes for those folders
* Treat archived documents as historical context, not as instructions for the current system

### Creating Or Updating Plans

Before creating a plan:

1. Review `docs/roadmap.md`
2. Review the active plans under `docs/`
3. Review the architecture and archive indexes
4. Extend an existing plan when it already owns the work instead of creating a duplicate

A persisted implementation plan should include:

* status and scope
* links to the actual owning apps, modules, schemas, migrations, or routes
* dependencies, sequencing, and migration order
* small executable tasks
* acceptance criteria and validation commands
* deferred or explicitly out-of-scope work
* migration requirements when schemas change

Update `docs/roadmap.md` when work starts, pauses, changes priority, becomes blocked, is deferred, or is completed.

### Completing Or Superseding Plans

When a plan is completed or superseded:

1. Update its status and describe the outcome or replacement
2. Move it to `docs/archive/`
3. Add or update its entry in `docs/archive/README.md`
4. Update links that referenced its former location
5. Carry unresolved work into the deferred or future section of `docs/roadmap.md`
6. Confirm no active document still presents the archived plan as current

When runtime architecture changes, update the affected files under `docs/architecture/`, its index, and the contributor-facing summary in `README.md`. Historical references may remain in archived plans when their archived status is clear.

### Documentation Validation

For documentation-only changes:

* validate relative Markdown links
* run `git diff --check`
* search current documentation for removed apps, providers, routes, and paths
* verify `docs/roadmap.md` and both documentation indexes agree with the filesystem

---

## Repo Map

Before making changes, identify which app owns the behavior:

* `apps/money_tree` → primary backend application

* `apps/money_tree/lib/money_tree` → business logic, contexts, schemas, jobs, integrations

* `apps/money_tree/lib/money_tree_web` → Phoenix controllers, LiveViews, components, router, plugs

* `apps/money_tree/priv/repo/migrations` → Ecto migrations

* `apps/money_tree/test` → ExUnit tests and fixtures

* `apps/ui` → shared UI styling

* `config` → shared umbrella/runtime config

* `docs/roadmap.md` → canonical product and delivery status

* `docs/architecture` → current technical references, research, and runbooks

* `docs/archive` → completed, superseded, and redundant plans

Do not assume this is a single-app repo. Work in the smallest relevant surface area.

---

## Dev Environment Startup

Use the repository's development startup script when bringing the app up locally.

* Preferred dev entrypoint: `./scripts/dev.sh`
* This script:

  * installs Node dependencies (`pnpm install`)
  * builds shared UI (`@money-tree/ui`)
  * installs Elixir deps (`mix deps.get`)
  * applies database migrations (`mix ecto.migrate`, fallback `mix ecto.setup`)
  * starts Phoenix

Rules:

* Do NOT replace this flow with manual startup steps unless explicitly required
* If the script fails, report which step failed and why
* When a task requires the app running locally, prefer this script over manual commands

---

## Codebase Expectations

Before making changes, ALWAYS:

1. Inspect the relevant app and nearby modules
2. Identify the existing pattern for that layer before editing
3. Follow conventions for:

   * Phoenix routes, controllers, LiveViews, plugs
   * domain/business logic in contexts
   * Ecto schemas and queries
   * migrations
   * shared UI components

If unclear, make the safest assumption and proceed conservatively.

---

## Implementation Guidelines

* Make the smallest change necessary to complete the task
* Reuse existing utilities and helpers whenever possible
* Prefer editing existing files over creating new ones
* Keep functions focused and readable
* Add comments only where logic is non-obvious

---

## Task Sizing

* Prefer one focused change per task
* Avoid combining schema, backend, frontend, and refactors in one step unless required
* If a task is too large, implement the smallest coherent slice first

---

## Data Handling Rules

* Never assume extracted or imported data is correct
* Always support user confirmation flows for parsed/imported data
* Preserve metadata where applicable:

  * source
  * extraction method
  * confidence score
  * verification state
  * last-reviewed timestamp
* Do not silently overwrite user-provided data

---

## Financial Logic Rules

* All calculations must be deterministic and implemented in code
* Do NOT rely on AI-generated values for calculations
* AI may be used only for:

  * summarization
  * explanation
  * data extraction (with confirmation)

### Financial Domain Guardrail

* Do not invent financial formulas, thresholds, or assumptions
* If logic is missing, surface the gap instead of guessing
* Prefer explicit, traceable calculations over “smart” heuristics

---

## Status And Evaluation Logic

* Status and recommendation systems must be rule-based and explainable
* Avoid fake precision when data is incomplete
* Missing data should reduce confidence and be visible
* Prefer transparency over completeness

---

## UI / UX Guidelines

* Do not introduce clutter
* Prefer progressive disclosure (details on demand)
* Reuse existing UI components and patterns
* Maintain consistency with the current design system

---

## Schema And Migrations

* Prefer additive schema changes
* Avoid destructive migrations unless explicitly required
* Keep migrations narrow and reversible when possible
* Update related schemas, changesets, and tests together
* Do not introduce fields without checking existing models first

### Database Migration Discipline

Schema changes are NOT complete until they are applied to the active development database.

For this repository:

* Preferred dev startup: `./scripts/dev.sh`
* This script runs `mix ecto.migrate`
* If migration fails, it attempts `mix ecto.setup`

Rules for schema-affecting tasks:

* Do NOT stop at creating or editing migrations
* Ensure migrations have been applied to the dev database
* Ensure the running application reflects the updated schema
* If migration fails, report it as a blocker
* Do not assume migrations will be run manually later

Minimum requirement:

1. Apply all pending migrations to the dev database
2. Verify affected flows using the migrated schema
3. Confirm no stale schema state is in use

Task completion requires BOTH:

* code changes
* migrated dev database

No exceptions.

---

## API And Contract Discipline

* If backend request/response shapes change:

  * update contract source first
  * regenerate artifacts instead of editing generated code
* Prefer backward-compatible API changes
* Avoid breaking changes unless explicitly instructed

---

## Document Import Pipeline

When implementing imports:

* Use a review-first flow:
  upload → extract → classify → structure → confidence → review → confirm
* Do not auto-save extracted data as truth
* Always allow user confirmation and correction
* Keep extraction logic separate from persistence logic

---

## Generated And Build Artifacts

Do not edit generated files directly.

Instead:

* edit `assets` → rebuild compiled outputs

Never modify:

* `_build`
* `deps`
* `node_modules`
* compiled/static outputs

---

## File Changes

* Modify existing files when appropriate
* Only create new files when necessary
* Do not reorganize folders unless instructed
* Do not rename files/modules without strong justification
* Keep changes tightly scoped

---

## Validation

Run the narrowest relevant validation when feasible:

* backend tests: `mix test` or targeted tests
* backend lint: `mix lint`
* root JS lint: `pnpm lint`

Additional requirements:

* If the task requires the app running, use `./scripts/dev.sh`
* For schema changes:

  * ensure all migrations were applied
  * verify functionality against the migrated schema
  * do not rely on stale database state

Regenerate outputs when needed instead of editing generated files.

---

## Safety And Scope Control

* Do not implement features outside the task
* Do not refactor unrelated code
* Do not introduce new dependencies unless necessary
* If adding a dependency, explain why
* Do not overwrite unrelated user changes

---

## Output Expectations

When completing a task:

* Ensure code fits the existing structure
* Maintain local consistency and style
* Keep changes minimal and focused
* Do not include unrelated improvements
* Mention validation performed and any limitations
* For schema changes, explicitly confirm migrations were applied successfully

---

## When In Doubt

* Choose the simplest working solution
* Match existing repo patterns over ideal architecture
* Prefer consistency over optimization
* Avoid overengineering
