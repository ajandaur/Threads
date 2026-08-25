# Verification Rubric

No `paths` frontmatter — this loads every session like CLAUDE.md. "Before reviewing a diff" isn't a file-type trigger; a diff can touch any file, so there's no glob that scopes it correctly. It stays unconditional rather than being scoped to something that would silently miss reviews.

Run in a fresh session, never the same context that wrote the code. Same-context self-review produces shallow agreement.

Use neutral prompts. "Trace the logic of each component and report all findings," not "find the bug." Report all findings, including "no issues found." Never manufacture a finding to satisfy a request.

Score each dimension 0-5. Cite specific lines. Separate blocking issues from suggestions.

1. **Spec fidelity** — does this achieve the active contract? Must score 4+.
2. **Correctness and edge cases**
3. **Test quality** — would these tests fail if the behavior broke?
4. **Concurrency and actor isolation safety**
5. **Scope discipline** — no drive-by edits outside the contract

A review that doesn't clear spec fidelity at 4+ fails regardless of the other four scores.
