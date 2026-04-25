# Ollama AI Finance Assistant Implementation Plan

## Purpose

This plan adds local-first AI assistance to MoneyTree using Ollama as the default LLM provider.

The primary goals are:

- LLM-powered transaction categorization suggestions
- LLM-assisted budget discovery and budget recommendations
- LLM-assisted pattern detection across transactions, accounts, obligations, transfers, and imports
- human review and confirmation before any AI-suggested change becomes durable financial data

By default, development should use the Windows Ollama desktop/runtime exposed on localhost, not a Dockerized Ollama service. This keeps local setup simple and avoids GPU/runtime friction inside Docker.

## Design Principles

1. Local-first by default.
2. No automatic financial mutations without user confirmation.
3. Deterministic rules always beat AI suggestions.
4. AI should explain its reasoning in short, reviewable terms.
5. Every suggestion should be auditable.
6. AI should work on minimized, structured financial facts rather than raw uploads whenever possible.
7. The system must still be useful when Ollama is unavailable.
8. External/cloud LLM providers should be optional future providers, not required for the MVP.

## Recommended Product Slice

Start with an AI review queue, not magical automation.

The first shippable version should:

1. Connect Phoenix to the local Ollama API.
2. Add an AI settings section where the user can enable local AI and test the connection.
3. Add a provider abstraction so Ollama is one provider behind a stable interface.
4. Add an AI suggestion persistence model.
5. Add LLM categorization suggestions for uncategorized or low-confidence transactions.
6. Add LLM budget discovery based on recent spending patterns.
7. Add a review UI where the user accepts, edits, rejects, or converts suggestions into rules.
8. Add audit logging for accepted and rejected suggestions.

Do not start by letting the LLM directly update transactions or budgets.

## Default Ollama Runtime Assumption

Default development endpoint:

- `http://localhost:11434`

Because the Phoenix backend may run in Docker or WSL while Ollama runs on Windows, the implementation should support configurable base URLs.

Recommended environment variables:

```bash
OLLAMA_ENABLED=false
OLLAMA_BASE_URL=http://localhost:11434
OLLAMA_MODEL=llama3.1:8b
OLLAMA_TIMEOUT_MS=60000
OLLAMA_KEEP_ALIVE=5m
OLLAMA_MAX_INPUT_TRANSACTIONS=200
OLLAMA_CONTEXT_WINDOW_BUDGET=12000
AI_PROVIDER=ollama
AI_SUGGESTIONS_REQUIRE_CONFIRMATION=true
```

For Docker/WSL development, document common alternatives:

```bash
# Docker Desktop host gateway pattern
OLLAMA_BASE_URL=http://host.docker.internal:11434

# WSL to Windows host may require the Windows host IP or mirrored networking behavior
OLLAMA_BASE_URL=http://<windows-host-ip>:11434
```

Implementation should not hard-code localhost. It should default to localhost but allow override.

## Model Recommendations

Model selection should be configurable because Ollama performance depends heavily on the user's hardware.

Recommended defaults:

- MVP default: `llama3.1:8b` or the closest locally available general model
- Faster fallback: `qwen2.5:7b` or similar
- Stronger local model when available: `llama3.1:70b`, `qwen2.5:14b`, or later equivalent
- Embeddings later: `nomic-embed-text` or similar local embedding model

The application should include a connection/model test that calls Ollama's model list endpoint and verifies the configured model exists. If not, show a helpful message with the needed `ollama pull <model>` command.

## Provider Abstraction

Create an AI provider boundary so the rest of MoneyTree does not know whether suggestions came from Ollama, a future OpenAI-compatible endpoint, or a deterministic local classifier.

Suggested modules:

- `MoneyTree.AI`
- `MoneyTree.AI.Provider`
- `MoneyTree.AI.Providers.Ollama`
- `MoneyTree.AI.Prompts`
- `MoneyTree.AI.Schemas`
- `MoneyTree.AI.Suggestions`
- `MoneyTree.AI.SuggestionReview`
- `MoneyTree.AI.PatternDetection`
- `MoneyTree.AI.BudgetDiscovery`
- `MoneyTree.AI.Categorization`

Provider behavior should expose:

- `health_check/0`
- `list_models/0`
- `generate_json/2`
- `generate_text/2` only for explanations or diagnostics

For financial features, prefer `generate_json/2` with strict schema validation.

## Ollama API Integration

Use Ollama's local HTTP API.

Initial endpoints to support:

- `GET /api/tags` for model availability
- `POST /api/generate` for single prompt JSON responses
- optional later: `POST /api/chat` if conversational context becomes useful
- optional later: embeddings endpoint for similarity clustering

Backend requirements:

1. Use configured base URL and timeout.
2. Never log prompts containing raw transaction data.
3. Capture provider latency, model name, and response validity metadata.
4. Validate and parse JSON responses strictly.
5. Retry only for transport-level transient failures, not malformed AI responses.
6. Treat invalid JSON as a failed suggestion run, not as partial truth.
7. Store prompt/version metadata, but not full sensitive prompt bodies unless explicitly enabled for development.

## Data Minimization

The LLM does not need complete financial records.

For categorization, send only:

- transaction ID surrogate or temporary row key
- posted date or month
- amount
- direction
- account type
- normalized merchant
- description
- existing source category if any
- household member/card member when relevant and not overly sensitive
- available category list
- known user rules summary

For budget discovery, send aggregates where possible:

- category-level monthly totals
- merchant-level recurring summaries
- account type summaries
- income frequency summaries
- obligation summaries
- confirmed transfer summaries
- excluded internal transfer totals

Avoid sending:

- full account numbers
- authentication tokens
- raw uploaded files
- full user profile details
- unrelated notes
- exact street addresses
- secrets or provider credentials

## Database Model

### `ai_suggestion_runs`

Tracks each AI job/run.

Suggested fields:

- `id`
- `user_id`
- `household_id` if the app uses household scoping
- `provider` default `ollama`
- `model`
- `feature` enum-like string: `categorization`, `budget_discovery`, `pattern_detection`, `transfer_review`, `merchant_cleanup`, `obligation_detection`
- `status`: `queued`, `running`, `completed`, `completed_with_warnings`, `failed`, `cancelled`
- `input_scope` JSONB summary such as date range, account IDs, transaction count
- `prompt_version`
- `schema_version`
- `started_at`
- `completed_at`
- `duration_ms`
- `error_code`
- `error_message_safe`
- timestamps

Rules:

- Do not store raw prompt by default.
- Store enough metadata to reproduce why suggestions appeared.
- Scope all runs to the authenticated user/household.

### `ai_suggestions`

Stores individual suggestions generated by a run.

Suggested fields:

- `id`
- `ai_suggestion_run_id`
- `user_id`
- `household_id` if applicable
- `target_type`: `transaction`, `merchant`, `budget`, `category_rule`, `transfer_match`, `obligation`, `pattern`
- `target_id` nullable for new suggested objects such as a new budget
- `suggestion_type`: `set_category`, `create_budget`, `adjust_budget`, `create_rule`, `mark_transfer`, `create_obligation`, `flag_anomaly`, `merge_merchant`, `rename_merchant`
- `payload` JSONB with proposed change
- `confidence` decimal or integer score
- `reason`
- `evidence` JSONB with minimized supporting facts
- `status`: `pending`, `accepted`, `edited_and_accepted`, `rejected`, `expired`, `superseded`, `failed_to_apply`
- `reviewed_by_user_id`
- `reviewed_at`
- `applied_at`
- timestamps

Rules:

- Applying a suggestion should be a separate explicit action.
- Accepted suggestions should preserve the original AI payload and the final user-approved payload.
- Rejected suggestions are useful training signals for future deterministic rules.

### Optional `ai_user_preferences`

Stores AI settings per user or household.

Suggested fields:

- `id`
- `user_id`
- `household_id` nullable
- `local_ai_enabled`
- `provider`
- `ollama_base_url`
- `default_model`
- `allow_ai_for_import_staging`
- `allow_ai_for_budget_recommendations`
- `allow_ai_pattern_detection`
- `store_prompt_debug_data` default false
- timestamps

If app settings are already JSONB-backed, this can be folded into the existing settings model instead.

## Categorization Feature

### Goal

Suggest categories for transactions that deterministic rules cannot confidently categorize.

### Inputs

- uncategorized transactions
- low-confidence categorized transactions
- known categories
- existing category rules
- known merchants
- source institution categories
- transaction direction and account type

### Output Schema

Each suggestion should include:

- transaction key
- proposed category ID or category name
- confidence
- reason
- whether the user should create a reusable rule
- suggested rule pattern when appropriate

Example JSON shape:

```json
{
  "suggestions": [
    {
      "transaction_key": "tx_123",
      "category_name": "Groceries",
      "confidence": 0.86,
      "reason": "Merchant appears to be a grocery store and matches similar past spending.",
      "suggest_rule": true,
      "rule": {
        "merchant_pattern": "KROGER",
        "category_name": "Groceries"
      }
    }
  ]
}
```

### Review Behavior

The UI should allow the user to:

- accept category suggestion
- edit category before accepting
- reject suggestion
- accept and create a category rule
- bulk accept only suggestions above a configurable confidence threshold

The system should never bulk accept low-confidence suggestions by default.

## Budget Discovery Feature

### Goal

Let the LLM identify realistic budget candidates from actual financial behavior.

This should feel like: “Based on your last 3-6 months, here are the budgets MoneyTree thinks you already live by.”

### Inputs

Use monthly category aggregates and recurring merchant summaries rather than raw rows when possible.

Include:

- last 3, 6, and 12 month category totals where available
- average, median, min, max, and trend per category
- recurring obligations
- known income cycles
- confirmed savings transfers
- known debt payments
- unusual one-time expenses excluded from baseline when detected
- existing budgets and budget performance

### Output Schema

Each budget suggestion should include:

- budget name
- category/categories included
- suggested monthly amount
- confidence
- reasoning
- whether the suggestion is fixed, flexible, seasonal, or watch-only
- risk/variance note
- suggested alert threshold

Example JSON shape:

```json
{
  "budget_suggestions": [
    {
      "name": "Groceries",
      "categories": ["Groceries"],
      "monthly_amount": 850,
      "budget_type": "flexible",
      "confidence": 0.82,
      "reason": "Spending is recurring monthly with moderate variance across the last six months.",
      "alert_threshold_percent": 85
    }
  ]
}
```

### Review Behavior

The UI should allow the user to:

- accept a suggested budget
- edit amount/name/categories before accepting
- reject a suggestion
- mark a suggestion as watch-only
- compare suggestion to existing budget
- ask the system to recalculate after category cleanup

No AI-created budget should go live without user confirmation.

## Pattern Detection Suggestions

Beyond categorization and budgets, Ollama can add real value by looking for patterns that are tedious for humans to spot.

Recommended pattern features:

### Recurring merchant and obligation detection

Detect possible obligations from repeating transactions:

- subscriptions
- utilities
- insurance premiums
- car notes
- pool loan payment
- savings transfers
- kid savings transfers
- recurring medical/pharmacy expenses

Output should suggest creating or linking an obligation, not create one automatically.

### Transfer and credit-card-payment detection

Use deterministic matching first, then LLM review for ambiguous cases:

- checking to savings transfers
- checking to credit card payments
- split truck payments or other split loan payments
- payment descriptions that differ across institutions

The LLM should explain why a pair or group appears related.

### Merchant cleanup

Suggest normalizing merchants:

- `WAL-MART #1234`, `WALMART.COM`, and `WM SUPERCENTER` -> `Walmart`
- gas station variants
- subscription processor names
- app store charges

User should confirm merges/renames because merchant cleanup affects future rules and reports.

### Subscription detection

Identify repeating charges that look like subscriptions, especially small monthly or annual charges.

Suggested review actions:

- mark as subscription
- add to obligations
- ignore as normal recurring spending
- flag for cancellation review

### Anomaly detection

Flag spending that is unusual for the user:

- unusually high transaction compared with merchant/category history
- duplicate-looking charges
- category spikes
- new merchant with large spend
- recurring charge amount increase

LLM should not be the only anomaly detector. Use deterministic statistics first, and let LLM turn the numbers into useful explanations.

### Cash-flow insights

Identify practical household finance patterns:

- months with predictable cash crunches
- categories causing variance
- expenses that reliably hit before payday
- savings transfers that may be too aggressive or too low
- budget categories that should be seasonal instead of fixed

### Import assistance

For manual imports, AI can help with:

- mapping unknown CSV headers
- interpreting ambiguous debit/credit signs
- suggesting institution preset candidates
- spotting payment rows in credit card exports
- categorizing staged rows before commit

This should be optional and review-first, because import staging is where bad AI guesses could create messy financial data.

## Suggested UX

### AI Settings

Add `Settings > AI & automation` or include this under `Settings > Data & privacy` initially.

Show:

- local AI enabled toggle
- provider: Ollama
- base URL
- selected model
- test connection button
- model availability state
- privacy note explaining that data is sent to local Ollama by default
- warning if base URL is not localhost/private network
- per-feature toggles

### AI Review Queue

Add a reusable review surface, possibly under:

- `Transactions > AI suggestions`
- `Budgets > AI suggestions`
- `Settings > AI & automation > Review queue`

The queue should show:

- suggestion type
- affected object
- proposed change
- confidence
- reason
- evidence summary
- accept/edit/reject controls

### Inline Suggestions

Show AI suggestions where the user is already working:

- transaction row category dropdown shows suggested category
- budget page shows suggested budgets in a review panel
- import preview grid shows suggested category/transfer hints
- obligations page shows possible recurring payment suggestions

## Prompting Strategy

Use separate prompt templates for each feature.

Each prompt should include:

1. role: local finance assistant inside MoneyTree
2. strict instruction to return JSON only
3. allowed categories/budget objects
4. minimized input records
5. rules for uncertainty
6. requirement to provide concise reasons
7. requirement to avoid inventing facts
8. explicit statement that final decisions require user confirmation

Version prompts. Store the prompt version in `ai_suggestion_runs`.

## Validation And Guardrails

All AI output must pass validation before becoming a suggestion.

Validation rules:

- JSON must parse.
- Required fields must exist.
- Category IDs/names must map to allowed categories unless suggesting a new category is explicitly allowed.
- Amounts must be numeric and within sane ranges.
- Confidence must be bounded from 0 to 1.
- Suggested target IDs must belong to the current user/household.
- Suggestions must not contain instructions, secrets, or unrelated text.
- Suggestions below a minimum confidence should either be discarded or marked low-confidence.

Never use raw AI output directly in database mutations.

## Background Jobs

AI calls can be slow, especially with local models.

Recommended approach:

- run AI suggestion generation as background jobs
- update run status in the database
- show progress/pending states in the UI
- allow cancellation where practical
- limit concurrent Ollama jobs to avoid making the local machine unusable

Suggested job types:

- `categorize_uncategorized_transactions`
- `discover_budgets`
- `detect_recurring_patterns`
- `review_import_batch`
- `normalize_merchants`

If the app does not yet have a job system, start with synchronous calls behind a small transaction limit and design the service boundary so it can move to jobs later.

## Security And Privacy

Requirements:

1. AI features are disabled by default until configured.
2. User must enable local AI intentionally.
3. Show clear warning when the Ollama base URL is not localhost or private-network-looking.
4. Do not send secrets, auth tokens, full account numbers, or raw file uploads to Ollama.
5. Do not log full prompts or raw model responses by default.
6. Add prompt debug storage only behind a development-only setting.
7. Scope all suggestions and runs by user/household.
8. Require normal app authorization for every AI endpoint.
9. Every accepted suggestion must record who accepted it and when.
10. Rejected suggestions should not repeatedly nag the user unless underlying data changed materially.

## API Design

Suggested Phoenix routes:

- `GET /api/ai/settings`
- `PUT /api/ai/settings`
- `POST /api/ai/test-connection`
- `GET /api/ai/models`
- `POST /api/ai/categorization-runs`
- `POST /api/ai/budget-discovery-runs`
- `POST /api/ai/pattern-detection-runs`
- `GET /api/ai/suggestion-runs`
- `GET /api/ai/suggestions`
- `POST /api/ai/suggestions/:id/accept`
- `POST /api/ai/suggestions/:id/reject`
- `POST /api/ai/suggestions/:id/apply-edited`

All mutation endpoints must require authenticated session/CSRF protections consistent with the rest of the app.

## Frontend Surfaces

Suggested pages/components:

- AI settings panel
- Ollama connection test card
- model selector
- AI review queue table/card list
- categorization suggestion badge
- budget recommendation panel
- pattern insight cards
- import-review AI suggestion column
- accept/edit/reject modal
- suggestion audit/history drawer

Keep the UI practical. The AI should feel like a careful assistant, not a chatbot bolted onto the side.

## Implementation Order

### Phase 1: Foundation

1. Add AI configuration/env handling.
2. Add provider behavior and Ollama provider module.
3. Add health check/model list calls.
4. Add tests for configured base URL and provider failures.
5. Add AI settings UI with connection test.

### Phase 2: Persistence and Review Queue

1. Add migrations for `ai_suggestion_runs` and `ai_suggestions`.
2. Add context functions to create runs and suggestions.
3. Add review status transitions.
4. Add authorization checks.
5. Add generic review queue UI.

### Phase 3: Categorization Suggestions

1. Build transaction input minimizer.
2. Build categorization prompt template and JSON schema.
3. Add categorization run endpoint/job.
4. Store suggestions instead of applying directly.
5. Add transaction review UI actions.
6. Add accept/edit/reject flows.
7. Add optional “accept and create rule” action.

### Phase 4: Budget Discovery

1. Build monthly aggregate query service.
2. Build budget discovery prompt and schema.
3. Add budget discovery run endpoint/job.
4. Store budget suggestions.
5. Add budget page review panel.
6. Add accept/edit/reject flows.

### Phase 5: Pattern Detection

1. Add deterministic pre-analysis for recurring transactions, merchant variance, transfer candidates, and anomalies.
2. Send summarized candidates to LLM for explanation/classification.
3. Add pattern suggestion types.
4. Add review UI for obligations, subscriptions, transfers, merchant cleanup, and anomaly flags.

### Phase 6: Manual Import Integration

1. Add AI-assisted header mapping for generic CSV imports.
2. Add staged-row categorization suggestions.
3. Add ambiguous transfer/payment suggestions.
4. Keep AI output below deterministic preset/rule logic.
5. Require user review before commit.

### Phase 7: Hardening and Telemetry

1. Add rate limits/concurrency limits.
2. Add safe error reporting.
3. Add prompt/schema versioning docs.
4. Add redaction tests.
5. Add manual verification checklist.
6. Add performance guidance for local models.

## Test Strategy

### Unit Tests

Cover:

- Ollama provider URL construction
- connection failure handling
- model list parsing
- timeout handling
- invalid JSON handling
- schema validation
- prompt input minimization
- category mapping validation
- budget amount validation
- confidence threshold handling

### Context Tests

Cover:

- suggestion run lifecycle
- suggestion creation
- accept/reject/edit transitions
- authorization boundaries
- applying a category suggestion
- creating a budget from an accepted suggestion
- preventing duplicate pending suggestions for the same target
- superseding stale suggestions

### Integration Tests

Use mocked Ollama responses.

Cover:

- categorization run creates pending suggestions
- malformed model response creates failed run
- budget discovery creates reviewable suggestions
- accepting a suggestion updates the intended target only
- rejecting a suggestion does not mutate financial data

### Manual Verification

Verify:

1. Ollama disabled: app works normally.
2. Ollama enabled but not running: connection test fails gracefully.
3. Ollama running with model missing: UI shows pull command guidance.
4. Categorization suggestions appear for uncategorized transactions.
5. User can accept, edit, and reject category suggestions.
6. Budget discovery suggests realistic budgets from aggregates.
7. User can edit suggested budget amount before accepting.
8. Pattern detection identifies recurring obligations/subscriptions.
9. No suggestion is applied without confirmation.
10. Raw prompts are not logged.

## Completion Criteria

This feature is complete when:

1. Ollama can be configured from environment/settings and defaults to local development usage.
2. The app can test the Ollama connection and configured model.
3. AI suggestion runs and suggestions are persisted and auditable.
4. Categorization suggestions can be generated, reviewed, accepted, edited, or rejected.
5. Budget discovery suggestions can be generated, reviewed, accepted, edited, or rejected.
6. At least one pattern-detection flow exists beyond categorization and budgets.
7. No LLM suggestion mutates canonical financial data without explicit user confirmation.
8. Deterministic user rules override AI suggestions.
9. Sensitive financial data is minimized before being sent to Ollama.
10. Tests cover provider failures, malformed AI output, review flows, and authorization boundaries.

## Notes For Codex

- Keep the app runnable through `./scripts/dev.sh` after every phase.
- Apply every database migration to the dev instance when schema changes are introduced.
- Do not hard-code `localhost`; use configuration defaults and overrides.
- Prefer small, reviewable PRs: provider foundation, persistence, categorization, budgets, patterns, imports.
- Mock Ollama in tests. Do not require a real local model for CI.
- AI output must be treated as untrusted input.
