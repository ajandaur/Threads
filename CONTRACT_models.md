# CONTRACT: SwiftData Models

First implementation session. Everything downstream depends on this file, so the constraints in `.claude/rules/swiftdata.md` are not advisory here — they are the contract.

## Done means

**Four `@Model` classes exist in `SwiftDataModels.swift`:** `Workstream`, `Message`, `ContextNode`, `ProactiveSurfacing`, with the fields listed in `SPEC.md`.

- [ ] Every enum-typed concept (`WorkstreamStatus`, `MessageRole`, `ContextNodeType`) is stored as a raw `String` property with a computed typed accessor. No enum is a stored property.
- [ ] At most one `#Index` per `@Model`, on primitive keypaths only. No relationship or enum keypaths.
- [ ] `Workstream` → `messages` and `Workstream` → `contextNodes` are cascade-delete with inverses declared.
- [ ] `ContextNode.embeddingData` is `Data?`, sized to hold 512 doubles as raw bytes.
- [ ] `ContextNode.supersededByID` and `ContextNode.extractionConfidence` exist now, even though nothing writes them yet. They are schema-level decisions, not features.
- [ ] `ProactiveSurfacing` is in the schema and unused. Do not build behavior for it.

**Tests (`ThreadTests`, Swift Testing):**

- [ ] Each test gets its own in-memory `ModelContainer`, or the suite is marked `.serialized`. Swift Testing parallelizes by default and SwiftData containers are not shared-safe. Write this helper first.
- [ ] A test creates and fetches an instance of each of the four models.
- [ ] A test filters `Workstream` by status using `#Predicate` against the raw `String` property and passes. This is the trap-check: it proves the enum-as-String decision holds in practice rather than in principle.
- [ ] A test deletes a `Workstream` and asserts its `messages` and `contextNodes` are gone (cascade actually wired).
- [ ] A test round-trips a 512-double array through `embeddingData` and back without loss.

**Build:**
- [ ] Builds clean for iPhone 17 Pro simulator, iOS 26.4 deployment target, Swift 6
- [ ] ThreadTests passes, N tests, none edited to pass

## Files in scope
`Models/SwiftDataModels.swift`, `App/ThreadApp.swift` (container configuration only), `ThreadTests/` (new model tests + container helper)

## Out of scope
`ContextEngine.swift`, `OnDeviceIntelligence.swift`, `LLMProvider.swift`, `ThreadOrchestrator.swift`, any view, any embedding or retrieval logic, any `ProactiveSurfacing` behavior. Do not create these files in this session.

## Verification
Fresh session, `.claude/rules/verify.md` rubric. Spec fidelity must score 4+.

Verifier should additionally confirm: no enum stored properties anywhere, no second `#Index` on any model, and that the `#Predicate` test would actually fail if the status property were changed back to an enum.
