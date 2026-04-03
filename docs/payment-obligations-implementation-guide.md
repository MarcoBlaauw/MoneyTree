# Payment Obligations Implementation Guide

## Purpose

This guide captures the implementation plan for payment obligations, durable alert events, delivery adapters, and dashboard/settings integration in `MoneyTree`. It is written against the current codebase so it can be used both as:

- an implementation reference for the original feature request
- a verification guide for the code that now exists
- a follow-up checklist for remaining hardening work

## Requested Scope

The original scope was:

1. Create a payment obligations model (`MoneyTree.Obligations`) with fields for creditor/payee, due day/rule, minimum due amount, linked funding account, grace period, and alert preferences.
2. Build a daily Oban check worker that compares due obligations to observed payment transactions and account state.
3. Emit obligation statuses: `upcoming`, `due_today`, `overdue`, `recovered`.
4. Create durable notification events instead of relying only on ephemeral dashboard advisories.
5. Integrate notification delivery adapters, with email first and SMS/push as optional later channels.
6. Add idempotency keys and resend policy for outbound delivery.
7. Update dashboard notifications to read from durable alert events in addition to computed advisories.
8. Add controller or settings UI support for user alert preferences.

## Status Snapshot

Based on the current codebase, the feature is partially complete and the core backend path is in place.

Completed:

- obligation schema, context, evaluator, and daily worker
- authenticated obligation CRUD API
- authenticated account-options API for obligation funding-account selection
- durable notification event persistence
- delivery-attempt persistence and idempotency keys
- email delivery adapter and Oban delivery worker
- generic SMS application layer with configurable adapter and destination resolver
- generic push application layer with configurable adapter and destination resolver
- daily cron scheduling for obligation checks
- dashboard integration for durable events plus computed advisories
- dashboard dismiss actions for durable notification events
- settings API and Phoenix LiveView form for alert preferences
- Next control-panel notification toggles wired to the settings API
- Next control-panel obligation management UI
- baseline test coverage for obligations, notifications, dashboard, and settings

Still open:

- no provider-specific SMS adapter
- no provider-specific push adapter
- no persisted SMS or push destination model
- limited tests around delivery retries, resend exhaustion, and worker scheduling
- no detailed dashboard event history or inspect view

## Current Code Locations

Core backend:

- `apps/money_tree/lib/money_tree/obligations.ex`
- `apps/money_tree/lib/money_tree/obligations/obligation.ex`
- `apps/money_tree/lib/money_tree/obligations/evaluator.ex`
- `apps/money_tree/lib/money_tree/obligations/check_worker.ex`
- `apps/money_tree/lib/money_tree/notifications.ex`
- `apps/money_tree/lib/money_tree/notifications/event.ex`
- `apps/money_tree/lib/money_tree/notifications/alert_preference.ex`
- `apps/money_tree/lib/money_tree/notifications/delivery_attempt.ex`
- `apps/money_tree/lib/money_tree/notifications/adapter.ex`
- `apps/money_tree/lib/money_tree/notifications/email_adapter.ex`
- `apps/money_tree/lib/money_tree/notifications/delivery_worker.ex`

Persistence:

- `apps/money_tree/priv/repo/migrations/20260329210000_create_obligations_and_notification_events.exs`

Web integration:

- `apps/money_tree/lib/money_tree_web/live/dashboard_live.ex`
- `apps/money_tree/lib/money_tree_web/live/settings_live.ex`
- `apps/money_tree/lib/money_tree_web/controllers/settings_controller.ex`
- `apps/money_tree/lib/money_tree_web/router.ex`
- `apps/next/app/control-panel/render-control-panel-page.tsx`

## Architecture Overview

The implementation is split into four layers:

1. Obligation definition
   - A user stores a recurring payment obligation with due-date semantics and alert overrides.
2. Daily evaluation
   - An Oban worker evaluates active obligations for a specific date.
3. Durable alert event pipeline
   - Obligation state changes create persistent `notification_events` rows with dedupe keys and delivery state.
4. Presentation and delivery
   - Dashboard notifications merge durable events with existing computed advisories.
   - Notification delivery runs through adapters, beginning with email.

## Data Model

### 1. User-level alert preferences

Table: `alert_preferences`

Purpose:

- Holds account-wide defaults for obligation alerts and delivery behavior.

Fields:

- `user_id`
- `email_enabled`
- `sms_enabled`
- `push_enabled`
- `dashboard_enabled`
- `upcoming_enabled`
- `due_today_enabled`
- `overdue_enabled`
- `recovered_enabled`
- `upcoming_lead_days`
- `resend_interval_hours`
- `max_resends`

Constraints:

- Unique index on `user_id`

Implementation notes:

- The source of truth is `MoneyTree.Notifications`.
- Defaults are defined in `@default_preference_snapshot` in `apps/money_tree/lib/money_tree/notifications.ex`.
- `preferences_for/2` merges user defaults with per-obligation overrides.

### 2. Payment obligations

Table: `obligations`

Purpose:

- Stores each recurring payment obligation that should be monitored.

Fields:

- `user_id`
- `linked_funding_account_id`
- `creditor_payee`
- `due_day`
- `due_rule`
- `minimum_due_amount`
- `currency`
- `grace_period_days`
- `alert_preferences`
- `active`

Supported due rules:

- `calendar_day`
- `last_day_of_month`

Implementation notes:

- Schema: `MoneyTree.Obligations.Obligation`
- Context: `MoneyTree.Obligations`
- `linked_funding_account_id` is validated against accounts accessible to the user.
- `alert_preferences` is a map intended for per-obligation overrides, not a replacement for user defaults.
- `currency` is normalized to uppercase ISO 4217 codes.

Validation rules:

- `creditor_payee` required, length-limited
- `minimum_due_amount >= 0.01`
- `grace_period_days >= 0`
- `due_day` required for `calendar_day`, blank for `last_day_of_month`

### 3. Durable notification events

Table: `notification_events`

Purpose:

- Stores durable obligation alert events for dashboard display and outbound delivery.

Fields:

- `user_id`
- `obligation_id`
- `kind`
- `status`
- `severity`
- `title`
- `message`
- `action`
- `event_date`
- `occurred_at`
- `resolved_at`
- `metadata`
- `dedupe_key`
- `delivery_status`
- `last_delivered_at`
- `next_delivery_at`
- `delivery_attempt_count`
- `last_delivery_error`

Constraints:

- Unique index on `dedupe_key`
- Query indexes on user/kind, obligation/status, resolution state, and delivery scheduling fields

Implementation notes:

- Schema: `MoneyTree.Notifications.Event`
- `kind` is currently `payment_obligation`
- `status` is one of `upcoming`, `due_today`, `overdue`, `recovered`
- `dedupe_key` prevents repeated inserts for the same obligation cycle/state

### 4. Delivery audit trail

Table: `notification_delivery_attempts`

Purpose:

- Records every outbound attempt and provides idempotent delivery bookkeeping.

Fields:

- `event_id`
- `channel`
- `adapter`
- `status`
- `idempotency_key`
- `attempted_at`
- `delivered_at`
- `provider_reference`
- `error_message`
- `metadata`

Constraints:

- Unique index on `idempotency_key`

Implementation notes:

- Schema: `MoneyTree.Notifications.DeliveryAttempt`
- This table is required even if email is the only active channel, because resend and dedupe behavior depends on it.

## Obligation Context

Module: `MoneyTree.Obligations`

Responsibilities:

- list obligations for a user
- build changesets
- create obligations with funding-account authorization
- enqueue daily checks
- evaluate all active obligations for a given day
- expose a summary for UI usage

Public API expected:

- `list_obligations/2`
- `change_obligation/2`
- `create_obligation/2`
- `check_all/1`
- `enqueue_check/1`
- `summary/1`

If the feature is extended later, this is the correct place to add:

- `update_obligation/2`
- `delete_obligation/1`
- `archive_obligation/1`
- `get_obligation!/2`

Current gap:

- Phoenix does not have a matching obligation management surface yet, but the Next control panel now does

## Daily Oban Worker

Module: `MoneyTree.Obligations.CheckWorker`

Responsibilities:

- receive a target date from job args
- default to `Date.utc_today/0` when no date is supplied
- invoke `MoneyTree.Obligations.check_all/1`

Recommended scheduling pattern:

- enqueue one daily job from a cron-style Oban plugin or a scheduler wrapper
- also support manual backfill by enqueuing specific dates

Current implementation:

- Queue: `:reporting`
- `max_attempts: 3`
- job uniqueness by `date` is applied in `MoneyTree.Obligations.enqueue_check/1`
- daily execution is scheduled in `config/config.exs` with `Oban.Plugins.Cron` at `0 7 * * *`

## Due-State Evaluation

Module: `MoneyTree.Obligations.Evaluator`

Responsibilities:

- compute the due date for the current cycle
- inspect recent transactions for evidence of payment
- inspect linked funding account balances for cash shortfall context
- determine state transitions
- resolve superseded events
- emit new durable events when appropriate
- emit `recovered` after an overdue event is followed by later payment activity

### Due date rules

- `calendar_day`: use the configured day, clamped to the end of the month
- `last_day_of_month`: use `Date.end_of_month/1`

### Payment matching

Payment detection currently uses:

- the linked funding account
- a lookback window (`@lookback_days`)
- case-insensitive pattern matching against `description` or `merchant_name`
- amount threshold of `ABS(transaction.amount) >= minimum_due_amount`

This is a pragmatic first pass. If false positives appear, tighten matching by:

- storing normalized payee aliases
- matching known merchant IDs when available
- constraining debit-only transaction direction
- introducing review tooling for disputed matches

### State rules

- `upcoming`
  - no matching payment found
  - due date is within the configured lead window
- `due_today`
  - no matching payment found
  - current date equals cycle due date
- `overdue`
  - no matching payment found
  - current date is later than due date plus grace period
- `recovered`
  - an open overdue event exists
  - payment activity is later detected for that overdue cycle
- `clear`
  - internal evaluator state used when no alert should be emitted

### Resolution rules

- A successful payment resolves open `upcoming`, `due_today`, and `overdue` events for that cycle.
- A more severe event resolves superseded lower-severity events for the same cycle.
- A `recovered` event resolves the corresponding open overdue event before emitting the new event.

## Durable Event Pipeline

Primary module: `MoneyTree.Notifications`

Responsibilities:

- manage user alert preferences
- merge global defaults with per-obligation overrides
- record durable events idempotently
- resolve events
- schedule delivery
- expose dashboard event queries
- deliver events through adapters

### Event recording requirements

Every durable event should include:

- `user_id`
- `obligation_id`
- `kind`
- `status`
- `severity`
- `title`
- `message`
- `action`
- `event_date`
- `occurred_at`
- `metadata`
- `dedupe_key`

### Dedupe strategy

The current dedupe format is:

- `obligation:<obligation_id>:<yyyy-mm-dd>:<state>`

This should remain stable. If the shape changes later, backfill code and analytics consumers must be updated together.

### Metadata recommendations

Current metadata should include:

- payee
- due date
- minimum due amount
- currency
- funding account ID and name
- observed funding balance
- funding shortfall boolean
- configured upcoming lead days

Useful future additions:

- matched transaction ID
- matched transaction posted date
- evaluated balance snapshot timestamp
- source synchronizer version

## Notification Delivery

Primary modules:

- `MoneyTree.Notifications.Adapter`
- `MoneyTree.Notifications.EmailAdapter`
- `MoneyTree.Notifications.DeliveryWorker`

### Delivery flow

1. A durable event is inserted in `notification_events`.
2. `MoneyTree.Notifications.record_event/1` schedules delivery if appropriate.
3. `MoneyTree.Notifications.DeliveryWorker` picks up the event.
4. The active adapter sends the message.
5. A `notification_delivery_attempts` row is written with the idempotency key and outcome.
6. The parent event is updated with delivery timestamps, attempt counts, next retry time, and terminal status.

### Idempotency requirements

Every outbound attempt must have a unique idempotency key that is stable for the attempt identity. At minimum it should incorporate:

- event ID
- channel
- attempt count or resend ordinal

This prevents duplicate external sends when:

- Oban retries the worker
- the provider times out after accepting the request
- the app restarts during delivery

### Resend policy

Resend behavior should come from `alert_preferences`:

- `resend_interval_hours`
- `max_resends`

Recommended rules:

- do not resend resolved events
- do not resend when the event is suppressed by preferences
- stop after `max_resends`
- write the terminal failure reason to `last_delivery_error`

### Channel strategy

Email is the first production channel.

Current implementation also includes:

- `MoneyTree.Notifications.SMS` as a generic SMS application layer
- `MoneyTree.Notifications.Push` as a generic push application layer
- a configurable destination resolver boundary for non-email channels
- disabled default adapters for SMS and push until provider-specific modules are configured

SMS and push should be added by:

- implementing new adapters behind `MoneyTree.Notifications.Adapter`
- preserving the same delivery worker and attempt bookkeeping
- extending preference validation to expose opt-in fields safely

Current gap:

- only email has a production-style provider implementation today
- SMS and push still need destination modeling plus provider-specific adapters

## Dashboard Integration

Primary module: `MoneyTreeWeb.DashboardLive`

Requirement:

- dashboard notifications should come from durable alert events in addition to existing computed advisories

Current integration path:

- `build_metrics/2` calls `Notifications.pending/2`
- `Notifications.pending/2` prepends durable dashboard events from `list_dashboard_events/2`
- existing computed budget, loan, subscription, and recurring advisories remain in the feed

Behavioral expectations:

- unresolved durable obligation events should appear first
- dashboard visibility should respect `dashboard_enabled`
- duplicate messages should be deduped before render

Future improvement:

- visually distinguish durable alerts from advisory-only items
- allow users to mark a durable event as resolved from the dashboard

## Settings and API Integration

Primary modules:

- `MoneyTreeWeb.SettingsLive`
- `MoneyTreeWeb.SettingsController`
- `MoneyTreeWeb.Router`

Requirements:

- user can review and save alert preferences in the UI
- API consumers can fetch and update notification settings

Current implementation:

- LiveView form supports:
  - `email_enabled`
  - `dashboard_enabled`
  - `upcoming_enabled`
  - `due_today_enabled`
  - `overdue_enabled`
  - `recovered_enabled`
  - `upcoming_lead_days`
  - `resend_interval_hours`
  - `max_resends`
- controller endpoint supports `PUT /settings/notifications`

Also present:

- Next.js control-panel copy for notification preferences exists in `apps/next/app/control-panel/render-control-panel-page.tsx`

Current gaps:

- no Phoenix-native UI currently exists for creating, editing, or archiving obligations themselves

Recommended next UI step:

- add obligation management UI so users can create and edit `MoneyTree.Obligations.Obligation` records without direct data seeding or console usage

## Implementation Sequence

If rebuilding or extending this feature from scratch, follow this order:

1. Add migration for `alert_preferences`, `obligations`, `notification_events`, and `notification_delivery_attempts`.
2. Add Ecto schemas and validations.
3. Add `MoneyTree.Obligations` context with account-authorization checks.
4. Add evaluator logic and due-date helpers.
5. Add daily Oban worker and enqueue helper.
6. Add durable event recording and event resolution logic.
7. Add delivery adapter behavior, email adapter, and delivery worker.
8. Update dashboard aggregation to include durable events.
9. Add settings API and LiveView preference controls.
10. Add tests for evaluator transitions, dedupe behavior, resend logic, and UI integration.

## Testing Checklist

### Schema and migration tests

- obligation changesets reject invalid due rules
- `calendar_day` requires a valid day
- `last_day_of_month` rejects a populated `due_day`
- invalid currencies are rejected
- user alert preferences remain unique per user
- event and delivery attempt dedupe constraints hold

### Evaluator tests

- emits `upcoming` inside lead window
- emits `due_today` on due date
- emits `overdue` after grace period
- does not emit alerts when payment is already found
- resolves lower-priority events when state escalates
- emits `recovered` after overdue followed by later payment
- includes funding shortfall metadata when the linked account balance is insufficient

### Delivery tests

- event insert schedules delivery
- email adapter writes successful attempt rows
- failures update `last_delivery_error`
- resend timing honors `next_delivery_at`
- `max_resends` is enforced
- repeated worker execution does not produce duplicate provider sends

### Web tests

- settings page renders alert preference form
- settings update persists through LiveView
- settings API returns and updates notification preferences
- dashboard includes unresolved durable events
- dashboard respects `dashboard_enabled`

## Operational Checklist

- run migrations in all environments
- confirm Oban queues include `:reporting` and `:mailers`
- configure sender identity for the email adapter
- verify a production scheduler is enqueueing the daily obligation check
- seed at least one obligation in non-production environments for smoke testing
- monitor event volume, delivery failures, and unresolved overdue counts

## Known Gaps and Recommended Follow-ups

The current implementation covers the original backend alerting scope, but these items are still worth scheduling:

- add a Phoenix-native obligation management surface if the product should support it outside Next
- tighten payment matching beyond payee substring plus minimum amount
- support multiple funding accounts or autopay source ambiguity when needed
- add provider-specific SMS/push adapters once delivery requirements are finalized
- add persisted phone-number and push-token destination models or resolvers
- add durable event history and detail views in the dashboard
- add analytics around alert open rate, resend rate, and recovery rate

## Recommended Next Steps

The highest-value remaining work is:

1. Expand tests for:
   - delivery worker retry and suppression paths
   - resend exhaustion
   - cron-backed scheduling assumptions
   - evaluator edge cases around payee matching and grace periods
2. Add durable event history/detail views in the dashboard.
3. Add persisted destination modeling plus provider-specific SMS/push adapters.

## Suggested Validation Commands

Run these locally after changes:

```bash
mix format
mix test
mix ecto.migrate
docker compose build
```

If the frontend has separate checks:

```bash
pnpm install
pnpm lint
pnpm test
```

## Summary

The implementation should treat payment obligations as first-class persisted records, evaluate them daily with Oban, emit durable status events, and deliver those events through idempotent adapters with resend controls. In this repository, the core backend pieces, durable notification pipeline, dashboard integration, and alert-preference settings surface are already mapped to concrete modules, and the next logical expansion is obligation CRUD plus additional delivery channels.
