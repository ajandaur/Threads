# PLAN: SwiftData Models

Implementation plan for `CONTRACT_models.md`. No Swift code was written in the
planning session that produced this file.

## Context

`CONTRACT_models.md` is the first implementation contract for Thread. Nothing in the
app persists anything yet: `Threads/Item.swift` (the Xcode template model) is deleted,
`ThreadsApp.swift` has had its `ModelContainer` stripped out, and `ContentView.swift`
is a stub. The app currently has no schema at all.

Every later contract — `CONTRACT_core_loop.md`, `CONTRACT_eval.md` — reads and writes
these four models, so a schema mistake here is expensive to unwind after data exists.
That is why the contract elevates `.claude/rules/swiftdata.md` from advisory to
contractual: the enum-as-String rule and the one-`#Index`-per-model rule are the two
constraints that, if violated, don't fail at compile time but at `#Predicate`
evaluation or at migration time.

Outcome: four `@Model` classes matching SPEC.md lines 163–206, a container wired into
the app, and a test suite that proves the two load-bearing decisions (enum-as-String,
cascade delete) actually hold rather than merely being written down.

### Decisions settled with the user during planning

| Question | Answer |
| --- | --- |
| `WorkstreamStatus` cases (SPEC never enumerates them) | `active` / `archived` / `resolved` |
| `#Unique` — SPEC line 209 says yes, contract's checkboxes are silent | Include, `#Unique<T>([\.id])` on all four |
| Contract paths (`Models/`, `App/ThreadApp.swift`, `ThreadTests/`) don't exist | New `Threads/Models/SwiftDataModels.swift`; edit `Threads/ThreadsApp.swift` in place; tests in `ThreadsTests/`. No file moves. |

The project uses `fileSystemSynchronizedGroups` (pbxproj `objectVersion = 77`), so new
files under `Threads/` and `ThreadsTests/` are picked up with **no `.xcodeproj` edit**.
Build settings are already correct: `IPHONEOS_DEPLOYMENT_TARGET = 26.4`,
`SWIFT_VERSION = 6.0`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`.

---

## Files

| File | Action |
| --- | --- |
| `Threads/Models/SwiftDataModels.swift` | **new** — 3 enums + 4 `@Model` classes |
| `Threads/ThreadsApp.swift` | **edit** — restore `ModelContainer`, container config only |
| `ThreadsTests/ModelContainerHelper.swift` | **new** — in-memory container factory |
| `ThreadsTests/SwiftDataModelTests.swift` | **new** — 7 tests |
| `ThreadsTests/ThreadsTests.swift` | **leave untouched** — see Open note at the end |
| `Threads/ContentView.swift` | **no change** — already free of `Item` references |

---

## 1. `Threads/Models/SwiftDataModels.swift`

### Enums — declared, never stored

Three plain `String`-raw-value enums. None of them appears as a stored property on any
`@Model`. Each is `String, Codable, CaseIterable, Sendable`.

```
WorkstreamStatus:  active, archived, resolved
MessageRole:       user, assistant, system
ContextNodeType:   fact, decision, openQuestion, reference, actionItem, insight
```

`ContextNodeType` cases come verbatim from SPEC line 190; `MessageRole` from line 179.

### The enum-as-String pattern (applied identically 3×)

Stored property keeps the SPEC field name (`status`, `role`, `nodeType`) and is a
`String`. The typed accessor is a **computed** property suffixed `Value`:

```swift
var status: String = WorkstreamStatus.active.rawValue

var statusValue: WorkstreamStatus {
    get { WorkstreamStatus(rawValue: status) ?? .active }
    set { status = newValue.rawValue }
}
```

The `?? default` on the getter is deliberate: it makes an unrecognized raw String
(a future migration, a hand-edited store) non-fatal. Same shape for
`Message.roleValue` (default `.user`) and `ContextNode.nodeTypeValue` (default `.fact`).

Rule: **no `@Model` in this file declares a stored property whose type is an enum.**
This is the single thing the verifier is told to grep for.

### Model definitions

Every stored property gets a default value so SwiftData's implicit initializer is
valid; each class also gets an explicit `init` taking the meaningful fields, so test
setup and later production code aren't stuck assigning field-by-field.

**`Workstream`** (SPEC 164–176)
```
#Unique<Workstream>([\.id])
#Index<Workstream>([\.updatedAt])

id: UUID = UUID()
title: String = ""
summary: String = ""
status: String = WorkstreamStatus.active.rawValue     + statusValue
isPinned: Bool = false
createdAt: Date = .now
updatedAt: Date = .now
compactContext: String = ""
tags: [String] = []

@Relationship(deleteRule: .cascade, inverse: \Message.workstream)
var messages: [Message] = []

@Relationship(deleteRule: .cascade, inverse: \ContextNode.workstream)
var contextNodes: [ContextNode] = []
```
`#Index` on `\.updatedAt` — the home screen sorts by recency (SPEC 218). Not on
`\.isPinned` (swiftdata.md: `SortDescriptor` fails with `Bool`; sort in a computed
property later) and not on `\.status` (one `#Index` per model, and `updatedAt` is the
hotter path).

**`Message`** (SPEC 177–185)
```
#Unique<Message>([\.id])
#Index<Message>([\.createdAt])

id: UUID = UUID()
role: String = MessageRole.user.rawValue              + roleValue
content: String = ""
createdAt: Date = .now
contentBlocksData: Data? = nil
isEmbedded: Bool = false
estimatedTokens: Int = 0
var workstream: Workstream?                            // plain, no attribute
```

**`ContextNode`** (SPEC 186–198)
```
#Unique<ContextNode>([\.id])
#Index<ContextNode>([\.createdAt])

id: UUID = UUID()
content: String = ""
nodeType: String = ContextNodeType.fact.rawValue      + nodeTypeValue
createdAt: Date = .now
lastAccessedAt: Date = .now
embeddingData: Data? = nil                             // 512 doubles = 4096 bytes
relevanceScore: Double = 1.0
sourceMessageID: UUID? = nil
supersededByID: UUID? = nil
extractionConfidence: Double = 1.0
var workstream: Workstream?                            // plain, no attribute
```
`supersededByID` and `extractionConfidence` are schema-level per the contract — they
exist, nothing writes them, and this session builds **no** behavior on them.

**`ProactiveSurfacing`** (SPEC 199–206)
```
#Unique<ProactiveSurfacing>([\.id])
#Index<ProactiveSurfacing>([\.createdAt])

id: UUID = UUID()
content: String = ""
triggerReason: String = ""
createdAt: Date = .now
wasEngaged: Bool = false
relatedWorkstreamID: UUID? = nil                       // loose UUID, NOT a relationship
```
In the schema, unused, no behavior. `relatedWorkstreamID` stays a bare `UUID?` exactly
as SPEC 206 specifies — making it a relationship would be inventing a feature.

### Relationship rules being applied

- The **inverse is declared once**, on the `Workstream` (parent) side only. Declaring
  `@Relationship` on both sides is the classic way to get a broken or duplicated
  inverse in SwiftData.
- `deleteRule: .cascade` lives on the parent's to-many arrays, which is what makes
  deleting a `Workstream` take its `messages` and `contextNodes` with it.
- Child `workstream` properties are plain optionals with no attribute.

### No conversion helpers on the models

`Data? ↔ [Double]` conversion stays **out** of `SwiftDataModels.swift` and lives as a
private helper in the test file. The contract's out-of-scope list names "any embedding
or retrieval logic," and the verifier scores scope discipline. `ContextEngine.swift`
will own that conversion when `CONTRACT_core_loop.md` is active.

---

## 2. `Threads/ThreadsApp.swift` — container configuration only

Restore the `sharedModelContainer` the template had, with the real schema:

```swift
let schema = Schema([
    Workstream.self, Message.self, ContextNode.self, ProactiveSurfacing.self,
])
let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
// try ModelContainer(...) / fatalError on throw
```
and `.modelContainer(sharedModelContainer)` on the `WindowGroup`.

Nothing else in this file changes. API key management (SPEC 216) is a later contract.

---

## 3. `ThreadsTests/ModelContainerHelper.swift` — write this first

The contract calls this out explicitly, and it is the first thing to write.

```swift
func makeInMemoryContainer() throws -> ModelContainer {
    let schema = Schema([Workstream.self, Message.self,
                         ContextNode.self, ProactiveSurfacing.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}
```

Isolation approach — belt and braces, since the contract offers "or" and both are cheap:
- **Per-test container.** Every test calls `makeInMemoryContainer()` itself and builds
  its own `ModelContext(container)`. Nothing is shared between tests.
- **`@Suite(.serialized)`** on the test suite as well, so Swift Testing's default
  parallelism can't interleave two containers even if a future test forgets rule 1.

Concurrency shape: tests are **synchronous** (`@Test func … throws`, not `async`) and
the helper is non-isolated. `ModelContext` is not `Sendable`; keeping every test body
free of `await` means no context or `@Model` instance ever crosses an isolation
boundary, which is the cleanest way to satisfy Swift 6 strict concurrency here without
sprinkling `@MainActor`.

---

## 4. `ThreadsTests/SwiftDataModelTests.swift` — 7 tests

`@Suite(.serialized) struct SwiftDataModelTests`. Maps 1:1 to the contract's checkboxes.

**Create-and-fetch, one test per model (4 tests).** Split rather than combined so a
failure names the model. Each: fresh container → context → insert one instance with
non-default field values → `save()` → fetch via `FetchDescriptor<T>` → assert count 1
and assert the round-tripped fields, including the `Value` computed accessor reading
back the right case.

**`filterWorkstreamByStatusUsingPredicate` (1 test).** The trap-check.
Insert three `Workstream`s — `.active`, `.archived`, `.resolved` — set via the
`statusValue` setter so the test exercises the accessor, not just the raw String.
Then fetch:
```swift
let target = WorkstreamStatus.archived.rawValue
let descriptor = FetchDescriptor<Workstream>(
    predicate: #Predicate { $0.status == target }
)
```
Assert exactly one result and that it is the archived one. Carry an inline comment
stating that this predicate compiles **only** because `status` is a stored `String` —
against an enum-typed stored property `#Predicate` does not compile. That comment is
what the verifier's third confirmation item ("would this test actually fail if status
went back to an enum?") is looking for.

Bind the raw value into a `let` outside the macro; `#Predicate` does not accept
`WorkstreamStatus.archived.rawValue` inline reliably.

**`deletingWorkstreamCascadesToChildren` (1 test).** Insert one `Workstream` plus two
`Message`s and two `ContextNode`s, wiring children by setting `child.workstream = ws`
and inserting the children. **`save()` before deleting** — cascade against unsaved
pending inserts is not reliable. Then `context.delete(ws)`, `save()`, and assert
`fetchCount` for `Workstream`, `Message`, and `ContextNode` are all 0. Asserting the
child counts specifically is what proves cascade rather than merely proving the parent
row vanished.

**`embeddingDataRoundTripsFiveHundredTwelveDoubles` (1 test).** Build 512 `Double`s
with a deterministic non-degenerate pattern, seeded with edge values (`.pi`,
`.leastNormalMagnitude`, `-0.0`, a large magnitude) so the test can't pass on a
zero-filled buffer. Encode to `Data`, store in `embeddingData`, `save()`, then read
back through a **fresh `ModelContext` on the same container** so the value genuinely
crosses the store. Assert `data.count == 4096` (512 × `MemoryLayout<Double>.size`) and
element-wise **exact** equality — raw bytes round-trip bit-for-bit, so no float
tolerance is warranted and adding one would weaken the test.

Alignment note for the decode helper: read back with
```swift
var out = [Double](repeating: 0, count: data.count / MemoryLayout<Double>.size)
_ = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
```
rather than `data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }`. `Data`
returned from the store is not guaranteed 8-byte aligned, and `bindMemory` on a
misaligned buffer is undefined behavior that happens to work most of the time — a
flaky-test source worth avoiding on day one.

Both helpers (`encode`/`decode`) are `private` in this test file.

---

## Known build risks

- **`#Unique` semantics.** It gives SwiftData upsert-on-conflict, not an insert error.
  Nothing this session writes a duplicate `id`, so it is inert here — but do not write
  a test that expects a duplicate insert to *throw*.
- **`tags: [String]`** persists as a codable attribute; it needs the `= []` default.
- **Defaults everywhere.** Any stored property without a default breaks SwiftData's
  synthesized init; the explicit `init` per model does not remove that requirement.
- **`@Model` classes are not `Sendable`.** Do not let an instance or a `ModelContext`
  escape a test body — the synchronous-test shape above prevents this structurally.

---

## Verification

Run via the `xcode` MCP tools, per CLAUDE.md.

1. `BuildProject` — scheme `Threads`, iPhone 17 Pro simulator. Must be clean: zero
   errors, and check warnings for SwiftData macro or Swift 6 concurrency complaints.
2. `RunSomeTests` on `SwiftDataModelTests` while iterating.
3. `RunAllTests` on `ThreadsTests` for the final pass. Report the exact test count.
4. Confirm no `Item` reference survives anywhere: `grep -rn "\bItem\b" Threads/ ThreadsTests/`.

Self-check against the contract before declaring done:
- [ ] Zero enum-typed stored properties across all four models
- [ ] Exactly one `#Index` macro per `@Model`, primitive keypath only
- [ ] `inverse:` declared on the `Workstream` side only, both relationships cascade
- [ ] `supersededByID`, `extractionConfidence` present; nothing reads or writes them
- [ ] `ProactiveSurfacing` in the schema; zero behavior built on it
- [ ] No file created from the out-of-scope list (`ContextEngine.swift`,
      `OnDeviceIntelligence.swift`, `LLMProvider.swift`, `ThreadOrchestrator.swift`,
      any view)
- [ ] No test edited to make it pass

Then hand off to a **fresh session** for review against `.claude/rules/verify.md`,
with the neutral prompt the rubric requires. Spec fidelity must score 4+. Tell the
verifier to additionally confirm the three items at the bottom of the contract.

---

## Open note (not blocking)

`ThreadsTests/ThreadsTests.swift` still holds the Xcode template's empty
`@Test func example()`. This plan leaves it untouched — deleting it is a drive-by edit
the verifier's scope-discipline dimension could flag — so the final count reports as
**8 tests, 7 meaningful**. Say the word and it goes in this session instead of the next.
