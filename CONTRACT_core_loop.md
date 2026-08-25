# CONTRACT: Core Loop

## Done means

The full message lifecycle works end to end, verifiable as discrete, checkable steps:

- [ ] User message is saved to SwiftData before any network call fires
- [ ] User message is embedded in the background, non-blocking — sending a message does not stall on embedding
- [ ] Relevant context is retrieved via cosine similarity against stored node embeddings before the LLM call is assembled
- [ ] Conversation history is built within token budget by walking backwards until the limit is hit, not by truncating arbitrarily
- [ ] Context payload (workstream summary + relevant nodes) is assembled as the system prompt, and is inspectable (see debug inspector, out of scope here but the payload must be capturable)
- [ ] LLM response streams via the primary provider; on failure, it falls back to the on-device provider automatically, without a user-visible error state for the fallback case itself
- [ ] Assistant message is saved to SwiftData after streaming completes
- [ ] Context nodes are extracted via Foundation Models in the background, without blocking the UI
- [ ] Extraction confidence is scored; extractions below threshold escalate to Claude rather than being stored as low-confidence facts
- [ ] Superseded nodes are marked and linked via `supersededByID` when a new decision replaces an earlier one — this must actually happen on a real superseding case, not just exist as an unused field
- [ ] New context nodes are embedded after extraction
- [ ] Workstream summary updates every 10 messages, not on every message
- [ ] Project builds clean for iPhone 17 Pro simulator
- [ ] ThreadTests passes, N tests, none edited to pass
- [ ] Screen recording exists showing: send message → Claude responds → nodes extracted → follow-up message → response shows awareness of the earlier context

## Files in scope
`ContextEngine.swift`, `OnDeviceIntelligence.swift`, `LLMProvider.swift`, `ThreadOrchestrator.swift`, `SwiftDataModels.swift`, `ThreadApp.swift`

## Out of scope
UI polish, voice capture (Days 7-8), proactive surfacing, anything in "Do not build."

## Verification
Fresh session, `.claude/rules/verify.md` rubric. Spec fidelity must score 4+. Confirm each lifecycle step above independently — don't accept "it works" without tracing each numbered step against actual code.
