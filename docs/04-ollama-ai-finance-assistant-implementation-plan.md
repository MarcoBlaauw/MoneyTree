# Ollama AI Finance Assistant Implementation Plan

## Purpose

Add local-first AI assistance to MoneyTree with Ollama as the default provider, while keeping all financial mutations review-first and auditable.

This plan is optimized for the current repo:

- Phoenix backend + LiveView app shell
- Next.js sidecar frontend already present, but not required for AI MVP
- existing `SettingsLive` privacy section
- existing Oban workers and queues
- existing transaction categorization + manual import foundations from plans `00` and `02`

## Repo Fit Assessment

Current repo capabilities that should be reused:

1. Existing settings surfaces (`SettingsLive`, `SettingsController`) can host AI toggles and connection diagnostics.
2. Existing API auth/authorization patterns (`:api_auth`, scoped controllers) can secure AI endpoints.
3. Existing Oban infrastructure can run async suggestion jobs.
4. Existing categorization and transaction contexts can apply accepted suggestions without building a parallel write path.
5. Existing manual import staging/commit flow can consume AI suggestions later, after core categorization flow is stable.

Gaps to implement:

1. No AI provider abstraction exists yet.
2. No Ollama runtime config exists yet.
3. No suggestion-run persistence model exists.
4. No review queue exists for AI-generated changes.

## Non-Goals (MVP)

- chatbot UI
- automatic mutation of transactions/budgets without explicit user confirmation
- cloud LLM providers
- embeddings/vector search
- full import-time AI automation

## Configuration

Add runtime config with safe defaults and overrides:

```bash
AI_PROVIDER=ollama
AI_ENABLED=false
AI_REQUIRE_CONFIRMATION=true
OLLAMA_BASE_URL=http://localhost:11434
OLLAMA_MODEL=llama3.1:8b
OLLAMA_TIMEOUT_MS=60000
OLLAMA_MAX_INPUT_TRANSACTIONS=200
OLLAMA_MAX_CONCURRENCY=1
```

Implementation requirements:

1. Default to localhost.
2. Never hard-code localhost.
3. Show explicit warning in settings if URL is not localhost/private LAN.
4. Fail closed (AI disabled behavior) when config is missing or provider is unavailable.

## Architecture

Use a provider boundary and keep feature logic provider-agnostic.

Suggested modules:

- `MoneyTree.AI` (public context)
- `MoneyTree.AI.Provider` (behaviour)
- `MoneyTree.AI.Providers.Ollama` (HTTP adapter)
- `MoneyTree.AI.Suggestions` (run + suggestion persistence)
- `MoneyTree.AI.Categorization` (feature service)
- `MoneyTree.AI.Budgets` (phase-2 feature service)
- `MoneyTree.AI.Prompts` (versioned prompt templates)
- `MoneyTree.AI.OutputValidator` (strict schema validation)

Provider behaviour:

- `health_check/0`
- `list_models/0`
- `generate_json/2`

Prefer structured JSON output only. Freeform text is allowed only for user-facing explanations after validation.

## Data Model

Add two tables first:

### `ai_suggestion_runs`

Fields:

- `user_id`
- `provider`
- `model`
- `feature` (`categorization`, `budget_discovery`, `pattern_detection`)
- `status` (`queued`, `running`, `completed`, `failed`, `cancelled`)
- `input_scope` map
- `prompt_version`
- `schema_version`
- `started_at`
- `completed_at`
- `duration_ms`
- `error_code`
- `error_message_safe`

### `ai_suggestions`

Fields:

- `ai_suggestion_run_id`
- `user_id`
- `target_type` (`transaction`, `budget`, `pattern`)
- `target_id` nullable
- `suggestion_type` (`set_category`, `create_budget`, `adjust_budget`, `flag_pattern`)
- `payload` map
- `confidence` decimal
- `reason`
- `evidence` map
- `status` (`pending`, `accepted`, `edited_and_accepted`, `rejected`, `failed_to_apply`, `superseded`)
- `reviewed_by_user_id`
- `reviewed_at`
- `applied_at`

Rules:

1. No raw prompt persistence by default.
2. All rows are user-scoped.
3. Accept/reject/apply are explicit actions, never implied by generation.

## API Surface

Add minimal authenticated endpoints first:

- `GET /api/ai/settings`
- `PUT /api/ai/settings`
- `POST /api/ai/test-connection`
- `GET /api/ai/models`
- `POST /api/ai/categorization-runs`
- `GET /api/ai/suggestion-runs`
- `GET /api/ai/suggestions`
- `POST /api/ai/suggestions/:id/accept`
- `POST /api/ai/suggestions/:id/reject`
- `POST /api/ai/suggestions/:id/apply-edited`

Budget and pattern endpoints should be phase-2 additions after categorization review flow is stable.

If any API response shape is exposed to `apps/next`, update `apps/contracts/specs/openapi.yaml` and regenerate contracts.

## UI Surfaces

Use existing LiveView surfaces first.

1. Add AI configuration card under `Settings -> Data & privacy` (current section already exists).
2. Add connection test and model availability display.
3. Add initial review queue in Phoenix app shell (can be under transactions or settings).
4. Add inline transaction category suggestion affordance in existing transaction views.

Do not block on a dedicated Next.js AI dashboard for MVP.

## Feature Rollout

### Phase 1: Foundation (required before any suggestion generation)

1. Runtime config + provider behaviour + Ollama adapter.
2. Connection/model checks (`/api/tags`, configured model existence).
3. Settings UI toggles + diagnostics.
4. Strict output validation utilities.

### Phase 2: Suggestion Persistence + Review Queue

1. Migrations for run/suggestion tables.
2. Context for run lifecycle and suggestion transitions.
3. Authz checks on every read/write.
4. Generic review queue UI (pending/accepted/rejected).

### Phase 3: Transaction Categorization Suggestions (MVP feature)

1. Input minimizer for uncategorized/low-confidence transactions.
2. Versioned categorization prompt with JSON-only schema.
3. Oban job to generate suggestions (with small batch limits).
4. Review actions:
   - accept category
   - edit then accept
   - reject
   - optional accept-and-create-rule (if rule API already supports it cleanly)
5. Deterministic rules remain highest priority.

### Phase 4: Budget Discovery (post-MVP but in-scope for this plan)

1. Aggregate-first input builder (monthly category summaries, not raw rows).
2. Suggestion generation + review/apply flow.
3. Budget UI panel for pending suggestions.

### Phase 5: Pattern Detection (post-MVP)

1. Deterministic pre-analysis first (recurrence, variance, anomaly candidates).
2. LLM explanation/classification on summarized candidates.
3. Review-only suggestions for obligation/subscription/merchant cleanup patterns.

### Phase 6: Manual Import AI Assist (optional after stable categorization)

1. Staged-row category hints in import review flow.
2. Optional ambiguous transfer/payment hints.
3. Never bypass existing deterministic duplicate/transfer logic.

## Security And Privacy

1. AI disabled by default.
2. No raw file uploads, account numbers, secrets, or auth tokens sent to Ollama.
3. Input minimization is mandatory.
4. Prompt/response bodies are not logged by default.
5. Non-localhost URLs show explicit user warning.
6. All suggestion actions are auditable with reviewer and timestamp.

## Observability

Track:

- run count by feature/provider/model/status
- latency and timeout rates
- validation failure rates
- accept/edit/reject ratios

Do not include sensitive payload bodies in telemetry.

## Test Strategy

### Unit

- Ollama URL/timeout handling
- tags/model parsing
- malformed JSON handling
- schema validation failures
- confidence bounds and payload validation

### Context

- run lifecycle transitions
- suggestion status transitions
- authorization boundaries
- apply accepted categorization suggestion updates only intended target

### Integration

- mocked Ollama success/failure responses
- run creation -> suggestions persisted -> review action mutates canonical data
- invalid model response marks run failed without mutating financial records

### Manual verification

1. AI off: app behavior unchanged.
2. AI on + Ollama down: graceful failure in settings and run endpoints.
3. AI on + model missing: clear pull guidance.
4. Categorization suggestions generated and reviewable.
5. No suggestion mutates data without explicit accept/apply.

## Completion Criteria

This plan is complete when all are true:

1. Ollama provider is configurable and health-checked.
2. AI runs/suggestions are persisted and auditable.
3. Categorization suggestions are generated and reviewable through accept/edit/reject.
4. Deterministic categorization/rules remain authoritative over AI.
5. Sensitive data is minimized and not logged by default.
6. Test coverage exists for provider failures, malformed output, authz, and review/apply flows.

## Notes For Execution

1. Keep rollout additive and backward-compatible.
2. Use Oban for background generation jobs.
3. Prefer LiveView-first integration to reduce moving parts.
4. Keep the app runnable with `./scripts/dev.sh` after each phase.
