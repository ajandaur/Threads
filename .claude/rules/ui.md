---
paths:
  - "**/Views/**"
  - "**/*View.swift"
---
# UI Rules

Read before any UI work (Days 5-6). Dark mode default, high contrast, information-dense. A professional instrument, not a wellness app. Voice is the primary input; the screen is for reviewing and browsing, not typing prompts.

## Color system

Do not introduce colors outside this set. Color carries meaning here — it is semantic, not decorative.

| Token | Hex | Use |
| --- | --- | --- |
| Background | `#0F0F0F` | App background |
| Surface | `#1A1A1A` | Cards, sheets |
| Elevated | `#242424` | Raised surfaces above cards |
| Text primary | white 90% | Primary text |
| Text secondary | white 50% | Secondary / metadata |
| Accent | `#4A9EFF` | Interactive, focus, primary action |

### Node-type colors (semantic, load-bearing)

These are not theming. The color IS the node type — a reader identifies a node by its color, so never reassign them.

| Node type | Hex |
| --- | --- |
| Facts | `#4A9EFF` |
| Decisions | `#FFB84D` |
| Open Questions | `#FF6B6B` |
| Action Items | `#4ADE80` |

Superseded nodes render at 30% opacity with a strikethrough rule. Decayed nodes dim proportionally to their relevance score.

## Screens

**Home.** Voice capture bar at top, full-width, hold to record, live waveform and transcript. Workstream cards below: title, summary, node count, tags, latest node. Empty state: centered mic, "Hold to capture your first thought."

**Workstream Detail — three tabs:**
- **Stream** — conversation flow. User input plain. AI responses carry a blue left border. Inline cards for extracted context.
- **Context** — the knowledge graph. Nodes grouped by type, semantic color borders, relevance scores visible. Decayed and superseded nodes dimmed per the rules above.
- **Insights** — proactive feed. Stubbed this cycle. Do not build out.

## Voice capture bar

Large mic icon in a rounded rectangle. Long press to record, release to send. Waveform plus live transcript while recording. Medium haptic on start, light on stop. `.glassEffect(.regular.interactive)`.

## Debug inspector

Long-press any AI response to reveal the assembled system prompt and the live retrieval scores that produced it. This makes the intelligence layer legible and is the single most persuasive thing in the demo. Build it during the UI window so it survives a schedule slip.

## Out of scope for UI

App icon, launch screen, branding, light mode, any color outside the set above. Insights tab beyond a stub.
