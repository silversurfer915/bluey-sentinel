# Bluey Local Memory and Context Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver conservative, explainable local memory and accurate persistent provider-cache telemetry, then capture privacy-safe screenshots of the rebuilt premium dashboards.

**Architecture:** Keep memory and telemetry local in separate versioned SQLite stores. Extract explicit memory candidates with a pure conservative classifier, rank them deterministically under a token budget, separate static prompt instructions from dynamic context for prefix reuse, and normalize provider usage into an honest common model before persisting it. Feed small observable dashboard models into focused SwiftUI views and a debug-only screenshot harness.

**Tech Stack:** Swift 5.9+, SwiftUI, Foundation, SQLite3, XCTest, macOS 14+, existing Swift Package/Xcode project; no new third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-10-13-memory-cache-design.md`

## Global Constraints

- Do not modify `/Users/ponhareeshn/Documents/StudyTimer` or any Sanctra behavior.
- Do not add embeddings, vector storage, cloud memory, model downloads, or third-party packages.
- Do not persist prompts, responses, screenshots, secrets, or full conversations in memory/cache databases.
- Existing `~/Library/Application Support/Googly/memory.sqlite` content must migrate non-destructively.
- Missing cache fields mean unknown/unreported, never an assumed zero hit.
- The selected session indicator remains the Dock companion; do not re-enable Bluey's dormant notch.
- Use test-first changes, exact-path staging, and one reviewable commit per task.
- Never run `git add -A`, `git clean`, or destructive reset commands.
- Before execution, confirm the working tree contains only this spec and plan or preserve any newer user work separately.

## File structure

### New production files

- `Mac/Sources/GooglyMac/MemoryModels.swift` — memory source, candidate, item metadata, recall result, and prompt-budget value types.
- `Mac/Sources/GooglyMac/ConservativeMemoryExtractor.swift` — pure explicit-signal extraction and sensitive-value rejection.
- `Mac/Sources/GooglyMac/MemoryRetrieval.swift` — tokenizer, deterministic ranking, budget selection, and recall reasons.
- `Mac/Sources/GooglyMac/PromptContextBuilder.swift` — stable versus dynamic prompt composition.
- `Mac/Sources/GooglyMac/CacheUsageNormalizer.swift` — provider-aware JSON usage parsing with evidence states.
- `Mac/Sources/GooglyMac/CacheStore.swift` — SQLite persistence, retention, reset, and aggregates.
- `Mac/Sources/GooglyMac/MemoryDashboardView.swift` — premium Memory dashboard and its observable model.
- `Mac/Sources/GooglyMac/CacheDashboardView.swift` — premium Token Caching dashboard and its observable model.
- `Mac/Sources/GooglyMac/UIPreviewFixtures.swift` — debug-only synthetic dashboard data and screenshot-mode configuration.
- `scripts/capture-premium-ui.sh` — deterministic build, launch, capture, and output validation.

### Existing production files to modify

- `Mac/Sources/GooglyMac/MemoryStore.swift` — schema migration, CRUD for new metadata, candidate persistence, recall recording, and compatibility wrappers.
- `Mac/Sources/GooglyMac/CacheTracker.swift` — thin facade over normalizer/store; remove volatile-only state and blended dollar estimate.
- `Mac/Sources/GooglyMac/RealtimeHost.swift` — conservative learning calls, stable/dynamic message construction, provider identity in telemetry, and verified task outcomes.
- `Mac/Sources/GooglyMac/BlueyWorkspace.swift` — host extracted dashboards and support debug screenshot mode.
- `Mac/Sources/GooglyMac/AppDelegate.swift` — debug-only preview launch and capture hook.
- `Package.swift` — exclude screenshot artifacts only if SwiftPM warns; normal source discovery needs no manual additions.
- `HANDOFF.md` — append new architecture, verification evidence, and remaining live-provider limitations.

### Test files

- `Tests/GooglyMacTests/MemoryMigrationTests.swift`
- `Tests/GooglyMacTests/ConservativeMemoryExtractorTests.swift`
- `Tests/GooglyMacTests/MemoryRetrievalTests.swift`
- `Tests/GooglyMacTests/PromptContextBuilderTests.swift`
- `Tests/GooglyMacTests/CacheUsageNormalizerTests.swift`
- `Tests/GooglyMacTests/CacheStoreTests.swift`
- Modify `Tests/GooglyMacTests/MemoryStoreTests.swift`
- Modify `Tests/GooglyMacTests/CacheTrackerTests.swift`
- Add lightweight view-model tests to `Tests/GooglyMacTests/PresentationTests.swift`

## Required type contracts

DeepSeek should preserve these names across tasks so later work does not invent parallel models:

```swift
public enum MemorySource: String, CaseIterable, Codable, Sendable {
    case manual, explicitProfile, explicitPreference, correction, taskOutcome, legacy
}

public struct MemoryCandidate: Equatable, Sendable {
    public let type: MemoryType
    public let content: String
    public let triggerContext: String?
    public let source: MemorySource
    public let confidence: Double
    public let replacementKey: String?
}

public struct MemoryRecall: Equatable, Sendable {
    public let item: MemoryItem
    public let score: Double
    public let reason: String
    public let estimatedTokens: Int
}

public struct MemoryPromptBudget: Equatable, Sendable {
    public let maxItems: Int       // default 12
    public let maxEstimatedTokens: Int // default 1_200
}

public enum VerifiedTaskOutcome: Equatable, Sendable {
    case completed(summary: String)
    case unfinished(summary: String)
}

public struct PromptContext: Equatable, Sendable {
    public static let prefixVersion = "bluey-prompt-v2"
    public let stableSystem: String
    public let dynamicSystem: String?
}

public enum CacheEvidence: String, Codable, Sendable {
    case confirmed
    case reportedNoHit
    case usageWithoutCacheField
    case usageUnavailable
}

public struct NormalizedTokenUsage: Codable, Equatable, Sendable {
    public let totalInputTokens: Int?
    public let cachedInputTokens: Int?
    public let uncachedInputTokens: Int?
    public let outputTokens: Int?
    public let evidence: CacheEvidence
    public let warningCode: String?
}

public struct CacheRequestLog: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let provider: AIProvider
    public let model: String
    public let tier: ModelTier
    public let prefixVersion: String
    public let usage: NormalizedTokenUsage
    public let latencyMs: Int
}

public struct CacheProviderSummary: Equatable, Sendable {
    public let provider: AIProvider
    public let model: String
    public let confirmedHits: Int
    public let confirmedMisses: Int
    public let unknownRequests: Int
    public let reusedInputTokens: Int
}

public struct CacheDashboardSnapshot: Equatable, Sendable {
    public let totalRequests: Int
    public let requestsWithCacheTelemetry: Int
    public let confirmedHitRate: Double?
    public let reusedInputTokens: Int
    public let medianLatencyMs: Int?
    public let unknownTelemetryRequests: Int
    public let providerBreakdown: [CacheProviderSummary]
    public let recentLogs: [CacheRequestLog]
}
```

If Swift cannot synthesize one conformance because an existing type lacks it, add the missing conformance to the existing type rather than renaming these interfaces.

## Review Focus

1. **A user pastes a secret after saying “remember”:** extraction must reject it and logs must not contain the value; covered in Task 3 sensitive-input tests.
2. **An old database is open in WAL mode during migration:** the migration backup and transaction must preserve every row and reopen cleanly; covered in Task 2 migration/relaunch tests.
3. **A provider reports inconsistent token totals:** normalization must clamp/reject the cache count, mark the record unknown with a warning code, and never show an impossible hit rate; covered in Task 6 malformed-usage tests.
4. **An unrelated lesson has a high type weight:** it must not enter the prompt without a match or pin; covered in Task 4 relevance tests.
5. **Dynamic memory changes between two requests:** `stableSystem` must remain byte-identical and only `dynamicSystem` may change; covered in Task 5 prefix-stability tests.

---

### Task 1: Establish the execution baseline

**Files:**
- Read: `HANDOFF.md`
- Read: `docs/superpowers/specs/2026-10-13-memory-cache-design.md`
- Read: `Mac/Sources/GooglyMac/MemoryStore.swift`
- Read: `Mac/Sources/GooglyMac/CacheTracker.swift`
- Read: `Mac/Sources/GooglyMac/RealtimeHost.swift`

**Interfaces:**
- Consumes: current clean Bluey repository and the approved design.
- Produces: recorded baseline results and a safe branch/worktree choice; no product-code change.

- [ ] **Step 1: Inspect repository and attached-worktree state**

Run:

```bash
git status --short
git branch --show-current
git log --oneline -10
```

Expected: understand every pre-existing change before editing. Preserve unexpected changes; do not discard them.

- [ ] **Step 2: Create an isolated worktree if the current checkout is not clean**

Use the repository's worktree workflow and a `codex/`-prefixed branch. Do not copy uncommitted changes unless the owner explicitly wants them included.

- [ ] **Step 3: Run baseline tests and builds**

Run:

```bash
swift test
swift build
xcodebuild -project GooglyEyes.xcodeproj -scheme GooglyEyes -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Expected: record exact pass counts and any existing warning; do not attribute baseline failures to new work.

- [ ] **Step 4: Re-check official cache documentation**

Confirm current usage fields in the four official links in the spec. Token Harbor has no verified provider-specific cache contract in this plan; retain generic parsing unless official documentation proves more.

- [ ] **Step 5: Commit only if baseline documentation changed**

Do not create an empty commit.

---

### Task 2: Add versioned memory models and non-destructive migration

**Files:**
- Create: `Mac/Sources/GooglyMac/MemoryModels.swift`
- Create: `Tests/GooglyMacTests/MemoryMigrationTests.swift`
- Modify: `Mac/Sources/GooglyMac/MemoryStore.swift`
- Modify: `Tests/GooglyMacTests/MemoryStoreTests.swift`

**Interfaces:**
- Consumes: existing `MemoryType`, `MemoryItem`, and `MemoryStore(fileURL:)` callers.
- Produces: `MemorySource`, expanded `MemoryItem`, schema version 2, and `MemoryStore.setPinned(id:isPinned:) -> Bool`.

- [ ] **Step 1: Write failing model-compatibility tests**

Add tests asserting:

- decoding an old `MemoryItem` JSON without new keys yields `.legacy`, `0.80`, unpinned, and zero recalls;
- confidence values passed to the initializer clamp into `0...1`;
- every `MemorySource` round-trips through `Codable`.

Run:

```bash
swift test --filter MemoryMigrationTests
```

Expected: FAIL because the new model types do not exist.

- [ ] **Step 2: Define the exact public types in `MemoryModels.swift`**

Create:

```swift
public enum MemorySource: String, CaseIterable, Codable, Sendable
public struct MemoryCandidate: Equatable, Sendable
public struct MemoryRecall: Equatable, Sendable
public struct MemoryPromptBudget: Equatable, Sendable
```

Move `MemoryType` and `MemoryItem` into this file without breaking existing initializers. Add backward-compatible defaults for all new fields.

- [ ] **Step 3: Write a failing version-1 migration test**

Create a real temporary SQLite version-1 database with two rows, set `PRAGMA user_version = 1`, open it through `MemoryStore`, then assert:

- both IDs/content/timestamps remain unchanged;
- new columns contain the spec defaults;
- `PRAGMA user_version` becomes `2`;
- `memory.sqlite.v1-backup` exists beside the temporary database;
- reopening the store returns the same two rows.

Expected: FAIL before migration exists.

- [ ] **Step 4: Implement `migrateSchema()` transactionally**

Use `PRAGMA table_info(memories)` to make repeated launches idempotent. Use SQLite's backup API before the first v1→v2 transaction. Add the exact columns and indexes from the spec, then set `user_version = 2` only after all statements succeed.

- [ ] **Step 5: Update every query/bind path**

Update `save`, `query`, `allMemories`, `memories(of:)`, and `search(query:)` to read/write the new fields. Preserve current sorting unless a later task changes a specific dashboard query.

- [ ] **Step 6: Add pin and forget-all coverage**

Test `setPinned` persistence across reopen. Extend `testForgetEverythingClearsDatabase` to assert recall metadata cannot survive without a memory row.

- [ ] **Step 7: Run focused and full tests**

```bash
swift test --filter MemoryMigrationTests
swift test --filter MemoryStoreTests
swift test
```

Expected: all pass with the prior total plus new tests.

- [ ] **Step 8: Commit**

```bash
git add Mac/Sources/GooglyMac/MemoryModels.swift Mac/Sources/GooglyMac/MemoryStore.swift Tests/GooglyMacTests/MemoryMigrationTests.swift Tests/GooglyMacTests/MemoryStoreTests.swift
git commit -m "feat(memory): add versioned metadata and safe migration"
```

---

### Task 3: Implement conservative extraction and secret rejection

**Files:**
- Create: `Mac/Sources/GooglyMac/ConservativeMemoryExtractor.swift`
- Create: `Tests/GooglyMacTests/ConservativeMemoryExtractorTests.swift`
- Modify: `Mac/Sources/GooglyMac/MemoryStore.swift`
- Modify: `Mac/Sources/GooglyMac/RealtimeHost.swift`
- Modify: `Tests/GooglyMacTests/MemoryStoreTests.swift`

**Interfaces:**
- Consumes: `MemoryCandidate`, `MemorySource`, and verified task completion state.
- Produces: `ConservativeMemoryExtractor.extract(userText:verifiedOutcome:) -> [MemoryCandidate]` and `MemoryStore.persist(_:) -> MemoryItem?`.

- [ ] **Step 1: Write the failing positive extraction matrix**

Cover exact examples for explicit profile, preference, correction, remember-directive, compound statements, and verified complete/unfinished outcomes. Assert type, source, confidence, replacement key, content, and trigger context.

- [ ] **Step 2: Write the failing negative extraction matrix**

Assert no candidates for:

- “Do you remember my exam?”
- “If I lived in Delhi, would the time change?”
- quoted third-party text: `The page says “I prefer Chrome”`;
- ordinary greeting/small talk;
- assistant reply containing a claimed preference;
- unverified task completion text.

- [ ] **Step 3: Write sensitive-input tests before implementation**

Include synthetic values matching API keys, bearer tokens, passwords, 12/24-word recovery phrases, six-digit OTP phrases, payment-card-like digits, CVV/PIN, and government-ID wording. Assert zero candidates and assert any diagnostic exposes only a fixed rejection code.

Run:

```bash
swift test --filter ConservativeMemoryExtractorTests
```

Expected: FAIL because the extractor does not exist.

- [ ] **Step 4: Implement `ConservativeMemoryExtractor` as a pure value type**

Use anchored, clause-bounded patterns. Do not pass assistant text into extraction. Run sensitive detection first. Return canonical content without applying `.capitalized`, which can corrupt names and technical identifiers.

- [ ] **Step 5: Implement exact-key replacement persistence**

Add:

```swift
@discardableResult
public func persist(_ candidate: MemoryCandidate) -> MemoryItem?
```

Replace only when `replacementKey` matches or normalized content is exactly equal. Preserve pin/recall metadata during replacement.

- [ ] **Step 6: Replace `extractMemories` call sites**

In `RealtimeHost`, create a typed verified outcome from execution state. Conversational replies pass `nil`. Agent tasks pass completed/unfinished only after their terminal state is known. Keep a deprecated compatibility wrapper only if tests or other call sites still require it.

- [ ] **Step 7: Run focused and full tests**

```bash
swift test --filter ConservativeMemoryExtractorTests
swift test --filter MemoryStoreTests
swift test
```

Expected: all pass; existing correction/preference behavior remains, with false-positive tests added.

- [ ] **Step 8: Commit**

```bash
git add Mac/Sources/GooglyMac/ConservativeMemoryExtractor.swift Mac/Sources/GooglyMac/MemoryStore.swift Mac/Sources/GooglyMac/RealtimeHost.swift Tests/GooglyMacTests/ConservativeMemoryExtractorTests.swift Tests/GooglyMacTests/MemoryStoreTests.swift
git commit -m "feat(memory): learn only explicit safe user facts"
```

---

### Task 4: Add relevant, explainable, budgeted recall

**Files:**
- Create: `Mac/Sources/GooglyMac/MemoryRetrieval.swift`
- Create: `Tests/GooglyMacTests/MemoryRetrievalTests.swift`
- Modify: `Mac/Sources/GooglyMac/MemoryStore.swift`
- Modify: `Tests/GooglyMacTests/MemoryStoreTests.swift`

**Interfaces:**
- Consumes: `[MemoryItem]`, query text, and `MemoryPromptBudget`.
- Produces: `MemoryRetriever.retrieve(query:items:budget:now:) -> [MemoryRecall]`, `MemoryStore.recall(for:budget:) -> [MemoryRecall]`, and recall metadata updates.

- [ ] **Step 1: Write failing tokenizer and deterministic-order tests**

Assert case/diacritic folding, stop-word removal, identifier retention (`iOS`, `M4`, `12`), and stable tie-breaking by score → updated time → ID.

- [ ] **Step 2: Write failing relevance tests**

Assert:

- a wave-optics correction outranks a generic response-length preference for a wave-optics query;
- an unrelated lesson is excluded despite lesson type weight;
- a global concise-answer preference is eligible;
- a 31-day-old task outcome is excluded unless matched or pinned;
- pinned items are considered but cannot exceed the prompt budget.

- [ ] **Step 3: Write failing budget tests**

Use long synthetic memories. Assert at most 12 items and at most 1,200 estimated tokens. Assert one oversized item is skipped rather than causing the final prompt to exceed the budget.

- [ ] **Step 4: Implement `MemoryTokenizer` and `MemoryRetriever`**

Keep the score weights named constants in one place. Return a short reason chosen from exact phrase, matched terms, trigger match, global preference, or pinned. Do not embed raw queries in logs beyond the matched safe terms.

- [ ] **Step 5: Add recall bookkeeping to `MemoryStore`**

`recall(for:budget:)` performs retrieval, then increments recall count and writes last recall time/reason for selected IDs in one transaction. `search` and `all` remain read-only.

- [ ] **Step 6: Rewrite `formatPromptContext(for:)` on top of recalls**

Preserve clear sections, escape/control-strip stored text, and avoid claims that every item is “verified.” Label legacy items neutrally. Do not expose confidence numbers to the model.

- [ ] **Step 7: Run focused and full tests**

```bash
swift test --filter MemoryRetrievalTests
swift test --filter MemoryStoreTests
swift test
```

- [ ] **Step 8: Commit**

```bash
git add Mac/Sources/GooglyMac/MemoryRetrieval.swift Mac/Sources/GooglyMac/MemoryStore.swift Tests/GooglyMacTests/MemoryRetrievalTests.swift Tests/GooglyMacTests/MemoryStoreTests.swift
git commit -m "feat(memory): add explainable budgeted recall"
```

---

### Task 5: Separate the stable prompt prefix from dynamic context

**Files:**
- Create: `Mac/Sources/GooglyMac/PromptContextBuilder.swift`
- Create: `Tests/GooglyMacTests/PromptContextBuilderTests.swift`
- Modify: `Mac/Sources/GooglyMac/RealtimeHost.swift`
- Modify: `Tests/GooglyMacTests/ComputerToolsTests.swift`

**Interfaces:**
- Consumes: conversation/tool mode, tool capability flag, autonomy text, memory context, StudyLearner context, live context, and optional study context.
- Produces: `PromptContextBuilder.build(_:) -> PromptContext` with prefix version `bluey-prompt-v2`.

- [ ] **Step 1: Write failing stability tests**

Build two contexts with different memory, time, weather, focus, and autonomy values. Assert `stableSystem` is byte-identical and `dynamicSystem` changes. Assert changing conversational/tool mode changes the stable prefix intentionally.

- [ ] **Step 2: Write failing ordering and privacy tests**

Assert the final messages are stable system → dynamic system → history → user. Assert no memory or live-context phrase appears in `stableSystem`. Assert tool definitions remain in deterministic name order.

- [ ] **Step 3: Implement `PromptContextBuilder`**

Move static prompt constants out of request assembly only as needed; do not rewrite Bluey's personality. Strip empty dynamic sections and join with stable headings.

- [ ] **Step 4: Wire both conversation and AgentRunner paths**

Replace the single mutable system message in `RealtimeHost`. Keep the bounded session-history behavior. Pass the prefix version to the cache recorder in Task 7; until then compile with the existing recorder signature.

- [ ] **Step 5: Update computer-guidance tests**

Retain assertions for snapshot-first refs, stale-ref recovery, and no mouse-warp navigation, now against `stableSystem`.

- [ ] **Step 6: Run focused and full tests**

```bash
swift test --filter PromptContextBuilderTests
swift test --filter ComputerToolsTests
swift test
```

- [ ] **Step 7: Commit**

```bash
git add Mac/Sources/GooglyMac/PromptContextBuilder.swift Mac/Sources/GooglyMac/RealtimeHost.swift Tests/GooglyMacTests/PromptContextBuilderTests.swift Tests/GooglyMacTests/ComputerToolsTests.swift
git commit -m "feat(cache): isolate stable prompt prefix"
```

---

### Task 6: Normalize provider usage without inventing cache hits

**Files:**
- Create: `Mac/Sources/GooglyMac/CacheUsageNormalizer.swift`
- Create: `Tests/GooglyMacTests/CacheUsageNormalizerTests.swift`
- Modify: `Mac/Sources/GooglyMac/CacheTracker.swift`
- Modify: `Tests/GooglyMacTests/CacheTrackerTests.swift`

**Interfaces:**
- Consumes: response `Data`, `AIProvider`, and model.
- Produces: `NormalizedTokenUsage`, `CacheEvidence`, and `CacheUsageNormalizer.normalize(data:provider:model:)`.

- [ ] **Step 1: Write provider fixture tests**

Add sanitized JSON fixtures for:

- DeepSeek hit/miss fields where total equals hit + miss;
- DeepSeek `prompt_tokens_details.cached_tokens` alias;
- Gemini/OpenAI-compatible cached details;
- Gemini usage with input/output but no cache field;
- Token Harbor/generic OpenAI-compatible cached details;
- usage object absent.

Assert total, cached, uncached, output, evidence, and warning code.

- [ ] **Step 2: Write malformed/inconsistent tests**

Cover numeric `NSNumber` values, negative values, cached greater than total, hit+miss mismatch, strings instead of numbers, and enormous values near `Int.max`. Expected behavior is no crash, no negative aggregate, and unknown evidence for inconsistent cache data.

- [ ] **Step 3: Implement exact normalization precedence**

Implement the provider rules from the spec. `prompt_tokens` is total input, not uncached input. Prefer explicit hit/miss when consistent. Make every warning a fixed enum/raw code with no response body.

- [ ] **Step 4: Replace old subtraction logic in `CacheTracker`**

Delete the unconditional `promptTokens -= cachedTokens` behavior. Keep a compatibility `recordFromResponse` wrapper temporarily if Task 7 has not yet migrated.

- [ ] **Step 5: Run focused and full tests**

```bash
swift test --filter CacheUsageNormalizerTests
swift test --filter CacheTrackerTests
swift test
```

- [ ] **Step 6: Commit**

```bash
git add Mac/Sources/GooglyMac/CacheUsageNormalizer.swift Mac/Sources/GooglyMac/CacheTracker.swift Tests/GooglyMacTests/CacheUsageNormalizerTests.swift Tests/GooglyMacTests/CacheTrackerTests.swift
git commit -m "fix(cache): normalize provider usage accurately"
```

---

### Task 7: Persist telemetry and compute honest aggregates

**Files:**
- Create: `Mac/Sources/GooglyMac/CacheStore.swift`
- Create: `Tests/GooglyMacTests/CacheStoreTests.swift`
- Modify: `Mac/Sources/GooglyMac/CacheTracker.swift`
- Modify: `Tests/GooglyMacTests/CacheTrackerTests.swift`

**Interfaces:**
- Consumes: normalized usage, provider/model/tier, prefix version, latency, and timestamp.
- Produces: `CacheStore(fileURL:)`, persisted `CacheRequestLog`, `CacheDashboardSnapshot`, reset, retention, and relaunch-safe `CacheTracker`.

- [ ] **Step 1: Write a failing persistence/relaunch test**

Record confirmed hit, confirmed no-hit, and unknown entries into a temporary database. Recreate the store and assert the same records and aggregates return in newest-first order.

- [ ] **Step 2: Write failing aggregate tests**

Assert:

- hit rate denominator includes only confirmed/reported observations;
- reused tokens sum only known cached tokens;
- unknown entries count separately;
- median latency is correct for odd and even counts;
- provider/model groups remain separate;
- zero confirmed telemetry renders an optional hit rate, not `0%`.

- [ ] **Step 3: Write failing retention and reset tests**

Insert 510 rows and rows older than 90 days. Assert only the newest 500 and in-window records remain after successful insertion. Assert reset clears disk and memory and survives reopen.

- [ ] **Step 4: Implement the SQLite store**

Use WAL mode, busy timeout, prepared statements, a serial queue, schema version 1, and no prompt/response columns. Use this logical schema (SQLite column spelling is fixed):

```sql
CREATE TABLE cache_requests (
    id TEXT PRIMARY KEY,
    timestamp REAL NOT NULL,
    provider TEXT NOT NULL,
    model TEXT NOT NULL,
    tier TEXT NOT NULL,
    prefix_version TEXT NOT NULL,
    total_input_tokens INTEGER,
    cached_input_tokens INTEGER,
    uncached_input_tokens INTEGER,
    output_tokens INTEGER,
    evidence TEXT NOT NULL,
    warning_code TEXT,
    latency_ms INTEGER NOT NULL
);
```

Add descending timestamp and `(provider, model, timestamp)` indexes.

- [ ] **Step 5: Make `CacheTracker` a facade**

Keep `CacheTracker.shared`, `onChange`, `snapshot`, and `reset` entry points where practical. Initialize the default database at `Application Support/Googly/cache.sqlite`. Notify UI on the main queue after a committed write.

- [ ] **Step 6: Remove blended dollar savings**

Delete `estimatedSavingsUSD` and `totalSavingsUSD`. Search the whole repository and update all callers/tests before compiling.

- [ ] **Step 7: Run focused and full tests**

```bash
swift test --filter CacheStoreTests
swift test --filter CacheTrackerTests
swift test
```

- [ ] **Step 8: Commit**

```bash
git add Mac/Sources/GooglyMac/CacheStore.swift Mac/Sources/GooglyMac/CacheTracker.swift Tests/GooglyMacTests/CacheStoreTests.swift Tests/GooglyMacTests/CacheTrackerTests.swift
git commit -m "feat(cache): persist verified cache telemetry"
```

---

### Task 8: Wire normalized telemetry into every AI request

**Files:**
- Modify: `Mac/Sources/GooglyMac/RealtimeHost.swift`
- Modify: `Mac/Sources/GooglyMac/AIClient.swift`
- Modify: `Tests/GooglyMacTests/ProviderTests.swift`
- Modify: `Tests/GooglyMacTests/CacheTrackerTests.swift`

**Interfaces:**
- Consumes: `AIConfig.ResolvedProvider.provider`, model/tier, `PromptContext.prefixVersion`, response data, latency.
- Produces: one persisted telemetry record per completed provider response, including responses without usage.

- [ ] **Step 1: Write failing request-recording tests**

Inject a temporary `CacheTracker`/store into the request path. Assert provider identity and prefix version are recorded, an unknown-usage response still creates a row, and cancelled/network-failed requests do not create fake usage rows.

- [ ] **Step 2: Add dependency injection without changing default behavior**

Add the smallest protocol/closure boundary needed to inject the recorder in tests. Avoid a global reset race across parallel tests.

- [ ] **Step 3: Update `callAI`**

Pass `ai.provider`, `ai.model`, `ai.tier`, and `bluey-prompt-v2`. Record only after an HTTP success returns. Normalize before parsing the assistant message so a malformed message shape with valid usage can still be counted.

- [ ] **Step 4: Validate multi-round tool calls**

Each provider request in an agent loop gets its own row. Confirm the stable prefix remains first and tool-call history follows it.

- [ ] **Step 5: Run tests**

```bash
swift test --filter ProviderTests
swift test --filter CacheTrackerTests
swift test
```

- [ ] **Step 6: Commit**

```bash
git add Mac/Sources/GooglyMac/RealtimeHost.swift Mac/Sources/GooglyMac/AIClient.swift Tests/GooglyMacTests/ProviderTests.swift Tests/GooglyMacTests/CacheTrackerTests.swift
git commit -m "feat(cache): record every successful provider response"
```

---

### Task 9: Build the premium Memory dashboard

**Files:**
- Create: `Mac/Sources/GooglyMac/MemoryDashboardView.swift`
- Modify: `Mac/Sources/GooglyMac/BlueyWorkspace.swift`
- Modify: `Tests/GooglyMacTests/PresentationTests.swift`

**Interfaces:**
- Consumes: `MemoryStore` query/mutation APIs and `[MemoryItem]`.
- Produces: `MemoryDashboardModel`, `MemoryDashboardView`, source/category/search filters, pin/edit/delete/add actions, and populated/empty states.

- [ ] **Step 1: Write failing dashboard-model tests**

Assert metrics for total, pinned, learned-this-week, and recalled-this-week; source/category/search filtering; newest-first “Recently learned”; and safe confidence labels (`Manual`, `Explicit`, `Correction`, `Confirmed outcome`, `Legacy`).

- [ ] **Step 2: Extract the view from `BlueyWorkspace`**

Keep navigation and page selection in the workspace. Move memory-specific state and rendering into a focused view/model. Preserve the existing destructive confirmation for Forget Everything.

- [ ] **Step 3: Implement the premium layout**

Follow the exact UI requirements in the spec. Reuse `BlueyTheme`, `GlassCard`, typography, and spacing. Use SF Symbols and accessible button labels. Do not display raw numeric confidence or expose full trigger context when it may contain a long user message; show a bounded safe summary.

- [ ] **Step 4: Check keyboard and size behavior**

Ensure search, add, edit, pin, delete, filter, and confirmation controls are reachable by keyboard. Verify 940×680 and 1100×760 layouts without horizontal clipping.

- [ ] **Step 5: Run tests and Mac build**

```bash
swift test --filter PresentationTests
swift test
swift build
```

- [ ] **Step 6: Commit**

```bash
git add Mac/Sources/GooglyMac/MemoryDashboardView.swift Mac/Sources/GooglyMac/BlueyWorkspace.swift Tests/GooglyMacTests/PresentationTests.swift
git commit -m "feat(ui): redesign explainable memory dashboard"
```

---

### Task 10: Build the premium Token Caching dashboard

**Files:**
- Create: `Mac/Sources/GooglyMac/CacheDashboardView.swift`
- Modify: `Mac/Sources/GooglyMac/BlueyWorkspace.swift`
- Modify: `Tests/GooglyMacTests/PresentationTests.swift`

**Interfaces:**
- Consumes: `CacheDashboardSnapshot` and `CacheRequestLog`.
- Produces: `CacheDashboardModel`, `CacheDashboardView`, evidence/status presentation, provider breakdown, recent-log table, and reset confirmation.

- [ ] **Step 1: Write failing dashboard-model tests**

Assert formatting for optional hit rate (`—` when unknown), reused token counts, telemetry request counts, median latency, provider breakdown, and evidence labels (`Confirmed hit`, `Confirmed miss`, `Cache not reported`, `Usage unavailable`).

- [ ] **Step 2: Extract the cache view from `BlueyWorkspace`**

Remove the volatile metric cards/table and blended savings copy. Keep navigation ownership in the workspace.

- [ ] **Step 3: Implement the premium layout**

Use the spec's header, four primary metrics, provider/model breakdown, and recent table. Use calm green only for confirmed hits, neutral gray for unknown, and no alarming red for a normal miss.

- [ ] **Step 4: Add persisted reset confirmation**

Reset must call the store-backed tracker, refresh after commit, and render the true empty state after relaunch.

- [ ] **Step 5: Run tests and Mac build**

```bash
swift test --filter PresentationTests
swift test
swift build
```

- [ ] **Step 6: Commit**

```bash
git add Mac/Sources/GooglyMac/CacheDashboardView.swift Mac/Sources/GooglyMac/BlueyWorkspace.swift Tests/GooglyMacTests/PresentationTests.swift
git commit -m "feat(ui): add honest cache telemetry dashboard"
```

---

### Task 11: Add privacy-safe screenshot fixtures and capture both screens

**Files:**
- Create: `Mac/Sources/GooglyMac/UIPreviewFixtures.swift`
- Create: `scripts/capture-premium-ui.sh`
- Modify: `Mac/Sources/GooglyMac/AppDelegate.swift`
- Modify: `Mac/Sources/GooglyMac/BlueyWorkspace.swift`
- Create: `docs/previews/premium-memory.png`
- Create: `docs/previews/premium-token-caching.png`
- Modify: `Tests/GooglyMacTests/PresentationTests.swift`

**Interfaces:**
- Consumes: dashboard model initializers and `BlueyWorkspace.snapshot(to:)`.
- Produces: debug-only `--ui-preview`, `--screenshot-path`, and `--reduce-motion` launch handling plus two deterministic PNG artifacts.

- [ ] **Step 1: Write failing fixture-isolation tests**

Assert preview fixtures construct dashboard models without calling `MemoryStore.shared`, `CacheTracker.shared`, Keychain, Sanctra, or network code. Assert fixture strings contain none of the repository's credential-prefix patterns.

- [ ] **Step 2: Implement synthetic fixtures**

Use clearly fictional examples such as Wave Optics, concise-answer preference, a Terminal correction, and Gemini/DeepSeek cache rows. Include long text and unknown telemetry to exercise layout.

- [ ] **Step 3: Implement debug-only launch arguments**

Compile launch handling only under `#if DEBUG`. Open the requested page, set 1100×760, disable nonessential animation, render fixtures, wait for one main-run-loop presentation cycle, snapshot, then terminate. A normal launch must never see fixture data.

- [ ] **Step 4: Write `scripts/capture-premium-ui.sh`**

The script must:

1. build a debug app;
2. remove only the two target preview PNGs;
3. launch memory preview and wait for the expected file;
4. launch cache preview and wait for the expected file;
5. use `sips`/`file` to assert each PNG is 1100×760 and non-empty;
6. exit nonzero on timeout or wrong dimensions.

- [ ] **Step 5: Capture the screenshots**

```bash
./scripts/capture-premium-ui.sh
```

Expected: both PNGs exist with exact dimensions and the script exits 0.

- [ ] **Step 6: Inspect both images at original resolution**

Use the workspace image viewer. Check clipping, overlapping, truncation, contrast, empty spacing, realistic status labels, and absence of personal/secrets/Sanctra content. Fix visual defects and recapture until clean.

- [ ] **Step 7: Run tests and commit**

```bash
swift test --filter PresentationTests
swift test
git diff --check
git add Mac/Sources/GooglyMac/UIPreviewFixtures.swift Mac/Sources/GooglyMac/AppDelegate.swift Mac/Sources/GooglyMac/BlueyWorkspace.swift scripts/capture-premium-ui.sh docs/previews/premium-memory.png docs/previews/premium-token-caching.png Tests/GooglyMacTests/PresentationTests.swift
git commit -m "test(ui): capture premium memory and cache previews"
```

---

### Task 12: Complete release verification and handoff

**Files:**
- Modify: `HANDOFF.md`
- Modify: `README.md` only if its memory/cache claims or test counts are now false.

**Interfaces:**
- Consumes: all previous task deliverables.
- Produces: a clean, built, reviewable branch with exact verification evidence and limitations.

- [ ] **Step 1: Run the complete automated suite**

```bash
swift test 2>&1 | tee /tmp/bluey-memory-cache-swift-test.log
swift build 2>&1 | tee /tmp/bluey-memory-cache-swift-build.log
./scripts/build-mac.sh 2>&1 | tee /tmp/bluey-memory-cache-release-build.log
xcodebuild -project GooglyEyes.xcodeproj -scheme GooglyEyes -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build 2>&1 | tee /tmp/bluey-memory-cache-ios-build.log
./scripts/capture-premium-ui.sh
git diff --check
```

Expected: every command exits 0. Record the exact test count; do not copy the old `99 tests` claim.

- [ ] **Step 2: Perform a temporary-database relaunch test**

Using a harness or debug launch arguments, add explicit memories and telemetry, close all store instances, recreate them, and verify the same state. Do not modify the owner's live database for this test.

- [ ] **Step 3: Perform a real-app smoke test without credentials**

Launch `build/Bluey.app`, open Memory and Token Caching, exercise search/filter/pin/edit cancellation and cache empty/unknown states. Do not invoke provider requests or expose real memory content in deliverable screenshots.

- [ ] **Step 4: If owner-provided provider keys are already configured, run bounded live telemetry checks**

Send two harmless repeated-prefix requests per configured provider and inspect the returned usage. Do not print or copy keys. Report cache results as provider observations, not guarantees. If keys are unavailable, mark live telemetry unverified.

- [ ] **Step 5: Update handoff documentation honestly**

Document schema versions, database locations, prompt prefix version, test/build logs, screenshot paths, live-provider checks performed, and every remaining limitation. Keep Sanctra parked.

- [ ] **Step 6: Commit documentation**

```bash
git add HANDOFF.md README.md
git commit -m "docs: hand off memory and cache improvements"
```

Omit `README.md` from staging if it did not change.

- [ ] **Step 7: Request whole-branch review**

Review the complete diff against the spec, with special attention to migration safety, sensitive-value rejection, cache arithmetic, main-thread UI updates, and debug fixture isolation. Fix validated findings in separate commits and rerun affected checks.

- [ ] **Step 8: Final report**

Report commits, exact tests/builds, migration behavior, screenshots, and live-provider limitations. Link both screenshots and the handoff document. State whether the branch was pushed; never imply a push or deployment occurred if it did not.

## Recommended execution method

Use **native sequential execution by DeepSeek**, one task and one commit at a time, followed by one strong whole-branch review. The tasks share schema and model interfaces, so parallel agents editing `MemoryStore.swift`, `RealtimeHost.swift`, or `BlueyWorkspace.swift` would create unnecessary conflicts. If multiple agents are used, restrict parallel work to read-only review or to tasks whose file sets do not overlap.

## Executor stop conditions

Stop and report instead of guessing if:

- an existing memory database fails migration or backup;
- official provider fields conflict with this plan;
- Token Harbor returns a cache format not covered by sanitized fixtures;
- a change would require Sanctra or StudyTimer edits;
- screenshot mode can reach real memory/cache stores;
- any test exposes a credential or real private memory;
- signed-device/App Group changes become necessary.
