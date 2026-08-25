# Decisions

No `paths` frontmatter — this loads every session like CLAUDE.md. "Don't un-decide things" applies even to sessions that never touch a `.swift` file, so this can't be conditional on a file match the way the other rules are.

These are imperative preferences. Locked. They survive compaction and no later session "improves" a choice that was deliberate.

| Decision | Rationale |
| --- | --- |
| SwiftData over Core Data | Declarative API, `#Unique`/`#Index` macros, iOS 26 native |
| NLContextualEmbedding over external vector DB | On-device, no network dependency, free, sufficient for a local corpus |
| Foundation Models for extraction | Zero cost, offline, fast enough for background processing |
| Actor isolation for services | Thread-safe by construction, no manual locking |
| `@concurrent` for CPU work | Swift 6.2 Approachable Concurrency, explicit background opt-in |
| SpeechAnalyzer over SFSpeechRecognizer | iOS 26 API, modular, offline-first, Swift Concurrency native |
| Relevance decay (14-day half-life) | Prevents stale context from dominating retrieval |
| Retrieval strategy parameterized | Enables clean eval comparison against identical data |
| Superseded-node links | Makes "topically near but wrong" a first-class retrieval case rather than an eval afterthought |
| Extraction confidence scoring | Enables escalation to Claude for low-confidence extractions; also drives UI dimming |
| Provider protocol abstraction | Swap providers, enables offline fallback and deterministic testing |
| Raw `String` storage for enums | `#Predicate` and `#Index` only work with primitive types |

## Declarative, agent's call

View composition, animation timing, internal helper structure, naming below the type level, test organization.

**Standing clause for every session:** if you find a design that better achieves the contract than the one specified, raise it as an option before implementing it.
