# App Shell and Navigation Plan

## Purpose

This plan defines the next UI/UX phase after the dashboard restyling work.

The dashboard is now in acceptable shape as a single screen, but the product is outgrowing a dashboard-first layout. The codebase already has multiple distinct workflows in both Phoenix LiveView and Next.js, and users need a predictable way to move between them without relying on ad hoc links such as `Next.js demos`.

This document covers:

- global application navigation
- desktop and mobile shell behavior
- user account and security information architecture
- placement of existing product areas into first-class destinations

This document does not redefine the dashboard visual system already covered in:

- `docs/99-ui-ux-implementation-plan.md`

## Current-State Assessment

### Existing user-facing destinations

Phoenix routes currently expose:

- `Dashboard` at `"/app/dashboard"`
- `Transfers` at `"/app/transfers"`
- `Budgets` at `"/app/budgets"`
- `Settings` at `"/app/settings"`
- `Categorization` at `"/app/categorization"`

Next.js currently exposes:

- `Home`
- `Link bank`
- `Verify identity`
- `Owner users`

### Problems with the current structure

- Navigation is fragmented across Phoenix and Next.js.
- Some pages are product-grade destinations, while others still read as demos or isolated utilities.
- There is no persistent app shell or global navigation.
- Account and security concerns are only partially represented in the current `Settings` page.
- Feature ownership is unclear for areas like institutions, obligations, and notification history.

## Product Navigation Model

The application should use a persistent shell with a stable set of primary destinations.

### Primary navigation

- `Dashboard`
- `Transactions`
- `Accounts & Institutions`
- `Budgets`
- `Obligations`
- `Assets`
- `Transfers`
- `Settings`

### Secondary navigation

- `Categorization rules`
- `Import / Export`
- `Alerts history`

### Owner-only navigation

- `Users`
- future owner/admin pages

## Navigation Behavior

### Desktop

Use a persistent left sidebar navigation.

The sidebar should:

- show the primary destinations at all times
- visually distinguish the active destination
- separate owner/admin items from general user items
- keep global actions out of the content region

### Mobile

Use a hamburger-triggered drawer navigation.

The drawer should:

- mirror the same information architecture as desktop
- support account switching or role-aware sections later if needed
- keep destructive actions such as logout visually separated

The hamburger should be a mobile adaptation only, not the primary desktop pattern.

### Top bar

Use a slim top bar for:

- page title and optional contextual actions
- global search later if introduced
- a user context menu

## User Context Menu

The top-right user menu should provide quick access to:

- `Profile`
- `Security`
- `Sessions & devices`
- `Notifications`
- `Data & privacy`
- `Log out`

This menu should not replace the full settings pages. It should act as a shortcut layer.

## Information Architecture by Product Area

### Dashboard

Purpose:

- overview only
- KPIs
- alerts
- recent activity
- short summaries and launch points

The dashboard should stop accumulating management workflows.

### Transactions

Purpose:

- full transaction list
- filtering and search
- category and merchant inspection
- drilldown into individual transactions

Related secondary tools:

- categorization rules
- anomaly and recurring review

`Categorization` should likely become a subview or child workflow under `Transactions`, not remain a disconnected top-level page.

### Accounts & Institutions

Purpose:

- list linked institutions
- list connected accounts
- refresh / reconnect / revoke institution connections
- connect new institutions
- show provider details such as Teller or Plaid

This area should absorb the current `link-bank` workflow and become the home for institution management.

### Budgets

Purpose:

- manage budgets
- review planner recommendations
- inspect budget performance
- eventually support history and comparisons

The current LiveView route already provides a good starting page.

### Obligations

Purpose:

- manage recurring payment obligations
- review due states and alert preferences
- inspect durable alert history tied to obligations

The existing control-panel obligation management should graduate into a first-class destination.

### Assets

Purpose:

- manage tangible assets
- inspect valuation history later
- connect asset records to account context

The current asset management embedded in the dashboard should move here over time.

### Transfers

Purpose:

- review and initiate transfer workflows
- track transfer state

This remains a first-class financial activity page.

### Settings

Settings should be split into clear subareas rather than serving as a single catch-all screen.

Subareas:

- `Profile`
- `Security`
- `Sessions & devices`
- `Notifications`
- `Data & privacy`

## Account and Security UX

The current `Settings` page is only a starting point. It shows:

- profile summary
- basic security status
- active sessions
- notification preferences

The future security UX should cover:

- multi-factor authentication management
- passkey enrollment and removal
- hardware security key support such as YubiKeys
- recovery code generation and rotation
- active session review and revocation
- trusted device management
- recent security events

These flows should live under the `Security` and `Sessions & devices` areas, not on the dashboard.

## Import / Export and Data Operations

The product should also make room for a dedicated data-management surface.

Suggested destination:

- `Import / Export`

This can include:

- CSV or manual transaction import
- export of transactions or budgets
- data portability requests
- backup-oriented user exports later

If this work stays small, it can initially live under `Settings > Data & privacy`. If it grows, it should become its own destination.

## Recommended First Implementation Order

### Phase 1: Shell and Navigation

- add a persistent app shell
- add desktop sidebar and mobile drawer navigation
- add user context menu
- remove all demo-oriented bridge links from the authenticated product UI

Status:

- completed for shell structure and persistent navigation
- global navigation now points to canonical `/app/*` routes, including aliases for institution connect, obligations management, and identity verification
- some flows still resolve through Next bridge routes under the hood and should be normalized further in later phases

### Phase 2: Settings Information Architecture

- split `Settings` into `Profile`, `Security`, `Sessions & devices`, `Notifications`, and `Data & privacy`
- wire user-context shortcuts to those sections
- keep the security section as a real destination even before MFA/passkey/YubiKey flows are fully implemented

Status:

- completed for information architecture and section routing
- implementation of the actual MFA/passkey/security-key controls remains future work

### Phase 3: Passwordless Authentication Foundation

- make email delivery production-grade before relying on magic-link authentication
- support custom SMTP during development
- standardize production delivery on Amazon SES SMTP
- keep passwords temporarily until passkeys, hardware keys, and email login are verified in real use

Status:

- mailer runtime configuration completed
- browser magic-link flow completed
- WebAuthn credential storage and challenge APIs completed
- browser ceremony, attestation/assertion verification, and credential management UI completed
- password fallback remains in place intentionally until passkeys, security keys, and email login have been exercised in real use

### Phase 4: Normalize Destinations

- make `Accounts & Institutions` a first-class destination
- make `Obligations` a first-class destination
- define where `Assets` lives as its own page
- move `Categorization` under `Transactions`

Status:

- completed for destination availability and navigation
- `Accounts`, `Obligations`, and `Assets` are first-class LiveView destinations
- `Categorization rules` now lives under `Transactions` with compatibility redirecting from the legacy route

### Phase 5: Expand Settings

- split `Settings` into subareas
- add real security management flows
- add session and device controls

Status:

- subarea split is completed
- advanced security/session controls remain incremental follow-up work

### Phase 6: Data Management

- add `Import / Export`
- add alert history and operational data views as needed

## Plan Status

This plan is completed for the shell/navigation scope originally defined here.

Completed foundation:

- app shell and destination navigation
- settings information architecture
- passwordless authentication foundation
- canonical `/app/*` destination routing with compatibility redirects for legacy paths
- `Import / Export` destination added as a dedicated data-management surface

Remaining follow-up (outside this plan's completion bar):

- continue reducing Next bridge dependencies by migrating selected `/app/react/*` flows into canonical Phoenix destinations where product ownership is clear
- implement import/export execution flows behind the new destination (currently the destination is scaffolding and routing)

## Suggested Destination Inventory

This is the recommended near-term destination list for authenticated users:

- `Dashboard`
- `Transactions`
- `Accounts & Institutions`
- `Budgets`
- `Obligations`
- `Assets`
- `Transfers`
- `Settings`

Likely subviews or secondary tools:

- `Categorization rules`
- `Import / Export`
- `Alerts history`
- `Users` for owner roles
