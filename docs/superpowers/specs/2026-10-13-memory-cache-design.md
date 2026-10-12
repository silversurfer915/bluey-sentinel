# Bluey Local Memory and Context Cache Design

**Status:** Approved direction; implementation intentionally deferred to DeepSeek or another execution agent.

**Date:** 2026-10-13

## 1. Goal

Make Bluey's memory dependable, private, explainable, and conservative while making provider context-cache behavior accurate, persistent, and visible. The work must improve actual prompt construction and response accounting, not only restyle the dashboards.

The selected approach is **balanced local-first**. It uses SQLite and deterministic local ranking. It does not add embeddings, a local model, a cloud memory service, or a new dependency.

## 2. Scope

### Included

- Versioned, non-destructive migration of the existing memory database.
- Conservative memory extraction from explicit user statements only.
- Precise replacement and contradiction handling through stable replacement keys.
- Sensitive-value rejection before persistence.
- Explainable local retrieval with a strict prompt budget and recall bookkeeping.
- Separation of stable instructions from per-request memory and live context.
- Provider-aware usage normalization for Gemini, DeepSeek, Token Harbor, and custom OpenAI-compatible endpoints.
- Persistent cache telemetry and honest unknown/unreported states.
- Premium Memory and Token Caching dashboards.
- Reproducible, privacy-safe screenshots of both dashboards.

### Excluded

- Sanctra and StudyTimer changes.
- Vector databases, embeddings, semantic-model downloads, or cloud memory sync.
- Automatic inference of personality, health, finances, relationships, identity, or other sensitive traits.
- Storing full conversations, screenshots, page text, passwords, API keys, recovery phrases, one-time codes, or payment data.
- Provider cache-object lifecycle management. Gemini explicit cache resources are not justified for Bluey's short, changing conversations in this pass.
- iPhone/iPad feature changes.

## 3. Product rules

### Conservative learning

Bluey may automatically store only:

1. An explicit profile fact: “My exam is on Friday,” “I live in Coimbatore,” or “I study physics.”
2. An explicit preference: “Keep answers concise,” “Use Safari,” or “I prefer dark mode.”
3. A direct correction or durable instruction: “Never close Terminal,” or “Next time ask before submitting.”
4. A confirmed task outcome emitted by Bluey's execution state after the task reached a verified completed or explicitly unfinished state.
5. Text entered manually through the Memory dashboard.

Questions, hypotheticals, quoted text, assistant claims, screen content, ordinary small talk, and uncertain inferences must not create memories. A statement containing a sensitive-value pattern must be rejected before it reaches SQLite, even if it starts with “remember.”

### User control

- Every item remains editable and deletable.
- Users can pin a memory. Pinned items are always considered for recall, but still obey the total prompt budget.
- The dashboard shows origin, confidence label, last recall time, and the last reason it was recalled.
- “Forget Everything” removes memories and recall metadata in one transaction.
- Migration never deletes a valid existing row. Existing rows become `legacy` source items and remain visible.

### Honest cache reporting

- A missing cache field is **unknown/unreported**, not a zero-token miss.
- Provider-reported cache hits are labeled **Confirmed**.
- Bluey never invents a dollar saving from a blended hard-coded price.
- The primary value is avoided/reused input tokens, hit rate among requests with confirmed telemetry, request latency, and provider/model breakdown.
- Token Harbor and custom endpoints use only fields actually returned by their OpenAI-compatible responses. No Token Harbor-specific field is assumed without official documentation or a captured sanitized fixture.

## 4. Memory data model

Use SQLite schema version 2 with `PRAGMA user_version`. Preserve the existing `memories` table and add:

| Column | Type | Default | Meaning |
|---|---|---:|---|
| `source` | TEXT | `legacy` | `manual`, `explicit_profile`, `explicit_preference`, `correction`, `task_outcome`, or `legacy` |
| `confidence` | REAL | `0.80` | Bounded to 0...1; used for ordering and display, never presented as certainty |
| `replacement_key` | TEXT nullable | null | Stable property identity such as `profile:name` or `preference:appearance:global` |
| `is_pinned` | INTEGER | `0` | Boolean pin state |
| `recall_count` | INTEGER | `0` | Number of successful prompt inclusions |
| `last_recalled_at` | REAL nullable | null | Most recent inclusion time |
| `last_recall_reason` | TEXT nullable | null | Short safe reason, e.g. `Matched “wave optics”` |

Add indexes for `replacement_key`, `updated_at`, `last_recalled_at`, and `(type, is_pinned)`. Run the migration inside an immediate transaction. Before the first version-1-to-version-2 migration, create `memory.sqlite.v1-backup` beside the live database through SQLite's backup API. Do not overwrite an existing verified backup and do not copy an open WAL database with `FileManager.copyItem`.

`MemoryItem` gains typed `MemorySource`, confidence, replacement key, pin, and recall fields. `MemoryCandidate` represents an extracted but not yet persisted fact. `MemoryRecall` contains the item, numeric score, and human-readable reason.

## 5. Extraction and replacement

Move extraction into a pure `ConservativeMemoryExtractor`. Its public input is the user's raw message plus an optional verified `TaskOutcome`; assistant prose is not evidence.

Assign exact default confidence values:

- Manual entry: `1.00`
- Direct correction/durable instruction: `0.98`
- Explicit profile fact: `0.95`
- Explicit preference: `0.95`
- Verified task outcome: `0.90`
- Migrated legacy row: `0.80`

Normalize replacement keys before writing. Only rows with the same non-null replacement key may automatically replace each other. Exact normalized duplicates without keys may merge. Shared words alone must never replace a row.

When replacing, retain the original `id` and `createdAt`, update content/source/confidence/context and `updatedAt`, and preserve `isPinned`, `recallCount`, and recall timestamps. Do not delete other unrelated rows.

Sensitive rejection runs before classification. It must catch common API-key prefixes, bearer tokens, passwords expressed as assignments, private/recovery/seed phrases, OTP/verification codes, payment-card-like digit sequences, CVV/PIN phrases, and government-ID phrases. Rejected candidates are not logged verbatim.

## 6. Retrieval

Use deterministic local lexical ranking. Do not add embeddings in this iteration.

Tokenization lowercases, folds diacritics, splits on non-alphanumerics, removes a fixed English stop-word set, and retains tokens of two or more characters when they contain a digit or three or more otherwise.

Candidate eligibility:

- Include pinned items.
- Include non-pinned items only when content or trigger context has a token/phrase match, or when the item is a truly global preference identified by its replacement key.
- Do not inject every lesson merely because it is a lesson.
- Task outcomes expire from normal recall after 30 days unless pinned or directly matched.

Ranking combines exact phrase, content token overlap, trigger-context overlap, type weight, confidence, pin boost, and a capped recency boost. Use deterministic tie-breaking by score, `updatedAt`, then `id`.

Prompt inclusion has both limits:

- Maximum 12 memories.
- Maximum estimated 1,200 input tokens, using `max(1, UTF8 byte count / 4)` as the documented conservative estimate.

After the final list is chosen, update recall metadata once in a transaction. Search and dashboard browsing do not increment recall counts.

## 7. Prompt composition and cacheability

Introduce `PromptContextBuilder` returning:

```swift
struct PromptContext {
    let stableSystem: String
    let dynamicSystem: String?
}
```

`stableSystem` contains only versioned static text: personality, conversational/tool/computer guidance, and invariant safety guidance. It must be byte-for-byte stable for the same mode and tool capability set.

`dynamicSystem` contains autonomy mode, retrieved memories, StudyLearner state, live time/weather/focus context, and any per-request account context. The request message order becomes:

1. Stable system message.
2. Dynamic system message when non-empty.
3. Existing bounded session history.
4. Current user message.

Keep tool schemas in deterministic order. Add a short stable-prefix version such as `bluey-prompt-v2` to telemetry so a future prompt edit is visible as a cache reset boundary.

This design improves best-effort prefix reuse. It does not promise a hit. DeepSeek documents automatic prefix caching and exposes hit/miss tokens. Gemini supports implicit caching on eligible current models, but eligibility thresholds and fields vary by API/model; Bluey must trust returned telemetry rather than claim eligibility from a hard-coded threshold.

## 8. Cache telemetry model

Replace ambiguous prompt counters with:

```swift
struct NormalizedTokenUsage {
    let totalInputTokens: Int?
    let cachedInputTokens: Int?
    let uncachedInputTokens: Int?
    let outputTokens: Int?
    let evidence: CacheEvidence
}

enum CacheEvidence: String, Codable {
    case confirmed
    case reportedNoHit
    case usageWithoutCacheField
    case usageUnavailable
}
```

Normalization rules:

- DeepSeek: `prompt_tokens` is total input. Prefer `prompt_cache_hit_tokens` and `prompt_cache_miss_tokens`; accept `prompt_tokens_details.cached_tokens` as an equivalent hit field. Never subtract cached tokens twice.
- Gemini OpenAI-compatible: treat `prompt_tokens` as total input. Accept `prompt_tokens_details.cached_tokens` and known cached-content aliases if present. If absent, record `usageWithoutCacheField`.
- Token Harbor/custom: parse standard `prompt_tokens`, `completion_tokens`, and `prompt_tokens_details.cached_tokens`. Treat missing cache fields as unknown.
- Clamp invalid negative values, reject cached counts larger than total input unless an explicit miss field provides a consistent total, and store a sanitized parse-warning code rather than response content.

Persist request logs in `~/Library/Application Support/Googly/cache.sqlite` using WAL mode. Keep the newest 500 records and delete records older than 90 days after a successful insert. Store provider, model, tier, prompt-prefix version, usage fields, evidence, latency, timestamp, and a non-sensitive warning code. Do not store prompts or responses.

Aggregate only confirmed/reported cache observations into hit rate. Requests with unknown cache telemetry remain visible but are excluded from the denominator.

## 9. Premium UI

### Memory dashboard

- Calm hero row with Total memories, Pinned, Learned this week, and Recalled this week.
- A compact “Conservative learning” banner that explains what Bluey will and will not save.
- Search and category/source filters.
- A “Recently learned” section ordered by `updatedAt`.
- Cards show source label, confidence label, pin control, updated time, last recall reason, edit, and delete.
- Use restrained material cards, BlueyTheme colors, SF Symbols, Dynamic Type-compatible text, and no glow-heavy effects.
- Empty state explains how to teach Bluey explicitly with one example.

### Token Caching dashboard

- Header status explains that caching is provider-controlled and best effort.
- Primary cards: Confirmed hit rate, Reused input tokens, Requests with telemetry, and median latency.
- Provider/model breakdown with confirmed, no-hit, and unknown counts.
- Recent requests table includes status pill, total input, reused input, output, latency, and prefix version.
- Reset requires the existing confirmation pattern and clears persisted telemetry.
- Remove the current blended dollar-savings claim.

## 10. Screenshot deliverables

Create deterministic, privacy-safe preview fixtures that never write to the user's real memory or cache databases. Add a debug-only launch mode that supplies fixture dashboard models, opens a requested page, fixes the workspace to 1100×760, disables nonessential animation, and writes a PNG through `BlueyWorkspace.snapshot(to:)`.

The capture script produces:

- `docs/previews/premium-memory.png`
- `docs/previews/premium-token-caching.png`

Both screenshots must be inspected at full size before delivery. They must show realistic synthetic entries, no personal content, no API keys, no Sanctra data, and no overlapping or clipped controls.

## 11. Acceptance criteria

- Existing version-1 databases migrate without data loss and reopen after relaunch.
- Explicit facts/preferences/corrections persist; casual, hypothetical, quoted, and sensitive text does not.
- Contradictions replace only the same replacement key.
- Retrieval is relevant, deterministic, budget-bounded, and explainable.
- Stable prompt text is identical across requests when mode/tool capability is unchanged; dynamic memory and live context do not alter it.
- DeepSeek, Gemini, generic OpenAI-compatible, malformed, missing, and inconsistent usage fixtures normalize honestly.
- Cache totals survive relaunch and reset cleanly.
- The two dashboards render correctly with empty, populated, long-text, and unknown-telemetry states.
- All tests pass, the release Mac app builds, and both screenshots are captured and visually inspected.

## 12. Primary references

- Gemini context caching: <https://ai.google.dev/gemini-api/docs/caching>
- Gemini cached content API: <https://ai.google.dev/api/caching>
- DeepSeek context caching: <https://api-docs.deepseek.com/guides/kv_cache/>
- DeepSeek chat-completion usage fields: <https://api-docs.deepseek.com/api/create-chat-completion/>

Provider behavior changes over time. The implementer must re-check these official pages before changing request formats or hard-coding model thresholds.
