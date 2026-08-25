---
paths:
  - "**/*.swift"
---
# SwiftData Constraints

Hard-won. Apply everywhere.

- `#Predicate` only works with primitive stored types (String, Int, Bool, Date, UUID, Double). Never use enums directly. Filter in memory.
- `#Index` can appear only once per `@Model`. Only primitive keypaths. No relationship or enum keypaths.
- `@Query` `SortDescriptor` fails with Bool. Sort in a computed property.
- Enum properties used in predicates must be stored as raw Strings with computed typed accessors.
- `NLContextualEmbedding` uses `init(script:)` or `init(language:)`, not static factory methods.
- `@MainActor` classes cannot reference isolated properties in `deinit`. Use explicit cleanup methods.
