---
paths:
  - "Eval/**"
---
# Eval Integrity Rules

The eval is the differentiator. These rules exist to keep the headline number defensible under the first question any interviewer will ask: "who labeled this?"

- All 30 queries, all `relevant_node_ids`, and all `irrelevant_but_tempting` sets are authored by the human. The agent must never generate or modify them. If the agent labels the eval, it grades its own homework and the claim is worthless.
- Never write the eval runner and the retrieval strategy in the same session. Write the runner in a fresh context that has never seen the retrieval strategy implementation, so the runner is built against the contract, not against knowledge of how the strategy is scored to win.
- Any change to decay half-life, top-K, or scoring re-runs the full three-strategy comparison and reports deltas. No cherry-picking a single rerun that looks better.
- The labeled node set is synthetic and separate from extraction. This eval measures retrieval quality in isolation, not extraction quality. Do not let extraction results leak into or justify retrieval scores.
