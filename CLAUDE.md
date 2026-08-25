# Thread

iOS 26, Swift 6, SwiftData. Scheme: Threads. Test target: ThreadsTests.
Simulator: iPhone 17 Pro. Build and test through the `xcode` MCP tools
(`BuildProject`, `RunAllTests`, `RunSomeTests`).

## Routing
`.claude/rules/DECISIONS.md` and `.claude/rules/verify.md` have no `paths`
frontmatter, so they load automatically every session — no trigger needed.
`swiftdata.md`, `ios26-apis.md`, `evals.md`, and `ui.md` are path-scoped and
load automatically when a matching file is *read*. Path-scoped rules don't
reliably load on file *write* (open Claude Code bug), so the three
non-negotiable "never do X while creating new code" rules below keep an
explicit fallback trigger:
- Before writing SwiftData code: read `.claude/rules/swiftdata.md`. Non-negotiable.
- Before using any iOS 26 framework (FoundationModels, SpeechAnalyzer,
  NLContextualEmbedding): read `.claude/rules/ios26-apis.md`, then verify
  against Apple documentation. Do not recall these APIs from memory.
- Before touching `Eval/`: read `.claude/rules/evals.md`. Never generate or
  modify the labeled eval set yourself.

Architecture decisions are locked; see `.claude/rules/DECISIONS.md` (loads
automatically, no trigger needed).

## Task completion
A task is done only when the active `CONTRACT_*.md` is satisfied.
Never edit a test to make it pass. If the contract is ambiguous, stop and ask.

## Reporting
Report all findings, including "no issues found."
Never manufacture a finding to satisfy a request.

## After compaction or /clear
Re-read this file, the active contract, and the files the contract names
before continuing.
