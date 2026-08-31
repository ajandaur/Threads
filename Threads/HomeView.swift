//
//  HomeView.swift
//  Threads
//
//  The Home screen: a voice capture bar over a list of workstream cards.
//  Colors come exclusively from `Palette` (see `.claude/rules/ui.md`); no hex
//  values live here. Recording is visual-only for now — the capture bar and
//  the empty-state mic do not record. That wiring lands in Days 7-8.
//

import SwiftUI
import SwiftData

struct HomeView: View {
    // Query by recency; pinned-first is layered on in `sortedWorkstreams`
    // because a `SortDescriptor` on the `isPinned` Bool is unreliable
    // (see `.claude/rules/swiftdata.md`).
    @Query(sort: \Workstream.updatedAt, order: .reverse) private var workstreams: [Workstream]

    /// The live orchestrator, threaded down to each workstream's Stream tab.
    /// Optional so previews and the empty state render without constructing a
    /// real model stack (`EmbeddingService.init` can throw off-device).
    var orchestrator: ThreadOrchestrator?

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()

                if sortedWorkstreams.isEmpty {
                    EmptyCaptureState()
                } else {
                    VStack(spacing: 16) {
                        VoiceCaptureBar()
                            .padding(.horizontal, 16)
                            .padding(.top, 8)

                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(sortedWorkstreams) { workstream in
                                    NavigationLink(value: workstream.id) {
                                        WorkstreamCard(workstream: workstream)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
            .navigationDestination(for: UUID.self) { workstreamID in
                WorkstreamDetailView(workstreamID: workstreamID, orchestrator: orchestrator)
            }
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
    }

    /// Pinned workstreams first, then most-recently-updated within each group.
    private var sortedWorkstreams: [Workstream] {
        workstreams.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }
}

// MARK: - Voice capture bar

/// Full-width capture bar. Visual only — long-press recording, waveform, and
/// live transcript arrive in Days 7-8.
private struct VoiceCaptureBar: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Palette.accent)
            Text("Hold to capture")
                .font(.headline)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 68)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
    }
}

// MARK: - Empty state

private struct EmptyCaptureState: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "mic.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 128, height: 128)
                .glassEffect(.regular.interactive(), in: .circle)

            Text("Hold to capture your first thought.")
                .font(.headline)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Workstream card

private struct WorkstreamCard: View {
    let workstream: Workstream

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !workstream.summary.isEmpty {
                Text(workstream.summary)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !workstream.tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(workstream.tags, id: \.self) { tag in
                        TagChip(tag)
                    }
                }
            }

            if let latest = latestNode {
                LatestNodeRow(node: latest)
            }

            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(workstream.title)
                .font(.headline)
                .foregroundStyle(Palette.textPrimary)
            Spacer(minLength: 8)
            if workstream.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.accent)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up.fill")
            Text("\(workstream.contextNodes.count) \(workstream.contextNodes.count == 1 ? "node" : "nodes")")
            Spacer(minLength: 8)
            Text(workstream.updatedAt.formatted(.relative(presentation: .named)))
        }
        .font(.caption)
        .foregroundStyle(Palette.textSecondary)
    }

    private var latestNode: ContextNode? {
        workstream.contextNodes.max { $0.createdAt < $1.createdAt }
    }
}

/// The most recent extracted node, keyed by its load-bearing semantic color.
private struct LatestNodeRow: View {
    let node: ContextNode

    private var typeColor: Color { Palette.color(for: node.nodeTypeValue) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(typeColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text("LATEST · \(displayName(node.nodeTypeValue).uppercased())")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(typeColor)
                    .tracking(0.5)
                Text(node.content)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .superseded(node.supersededByID != nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TagChip: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Palette.elevated, in: Capsule())
    }
}

// MARK: - Helpers

/// Human-readable label for a node type. Kept local to the view layer so the
/// model stays free of presentation concerns.
private func displayName(_ type: ContextNodeType) -> String {
    switch type {
    case .fact: "Fact"
    case .decision: "Decision"
    case .openQuestion: "Open Question"
    case .reference: "Reference"
    case .actionItem: "Action Item"
    case .insight: "Insight"
    }
}

/// A minimal left-to-right wrapping layout for tag chips — SwiftUI still has no
/// built-in flow container, and a single-line `HStack` would clip long tag sets.
/// Shared with `WorkstreamDetailView`'s extraction chip row, so it is
/// module-internal rather than file-private.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxRowWidth = max(maxRowWidth, x - spacing)
        }

        return CGSize(width: min(maxRowWidth, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Previews

#Preview("Home — Populated") {
    HomeView()
        .modelContainer(PreviewData.populatedContainer())
}

#Preview("Home — Empty") {
    HomeView()
        .modelContainer(PreviewData.emptyContainer())
}

/// In-memory sample data so both states are viewable without real capture.
@MainActor
private enum PreviewData {
    static func emptyContainer() -> ModelContainer {
        makeContainer()
    }

    static func populatedContainer() -> ModelContainer {
        let container = makeContainer()
        seed(into: container.mainContext)
        return container
    }

    private static func makeContainer() -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(
            for: Workstream.self, Message.self, ContextNode.self, ProactiveSurfacing.self,
            configurations: config
        )
    }

    private static func seed(into context: ModelContext) {
        let now = Date.now

        // Pinned but not the most recent — proves pinned-first beats recency.
        let migration = Workstream(
            title: "iOS 26 Migration",
            summary: "Move the persistence layer to SwiftData and adopt Approachable Concurrency across the services.",
            isPinned: true,
            updatedAt: now.addingTimeInterval(-3 * 3600),
            tags: ["SwiftData", "Concurrency", "iOS 26"]
        )
        add(&migration.contextNodes, [
            (.fact, "Core Data store migrates cleanly with a lightweight mapping model.", -6 * 3600),
            (.decision, "Ship SwiftData behind a feature flag for the first internal build.", -3 * 3600),
        ])

        let auth = Workstream(
            title: "Auth Rewrite",
            summary: "Replace the token refresh path; current implementation double-refreshes under load.",
            isPinned: true,
            updatedAt: now.addingTimeInterval(-26 * 3600),
            tags: ["Security", "Backend"]
        )
        add(&auth.contextNodes, [
            (.openQuestion, "Do we rotate refresh tokens on every use or on a fixed schedule?", -30 * 3600),
            (.actionItem, "Spike an actor-isolated token store and measure contention.", -26 * 3600),
        ])

        let roadmap = Workstream(
            title: "Q3 Roadmap",
            summary: "Prioritize proactive surfacing against the offline extraction work.",
            updatedAt: now.addingTimeInterval(-40 * 60),
            tags: ["Planning"]
        )
        add(&roadmap.contextNodes, [
            (.fact, "Extraction latency is under 400ms on-device for typical notes.", -2 * 3600),
            (.openQuestion, "Is proactive surfacing valuable enough to cut the eval harness for?", -40 * 60),
        ])

        let onboarding = Workstream(
            title: "Onboarding Copy",
            summary: "Tighten the first-run voice prompt so it reads as an instrument, not a wellness app.",
            updatedAt: now.addingTimeInterval(-5 * 24 * 3600),
            tags: ["Design", "Copy"]
        )
        add(&onboarding.contextNodes, [
            (.decision, "Lead with \"Hold to capture your first thought.\" — no exclamation.", -5 * 24 * 3600),
        ])

        let vendor = Workstream(
            title: "Vendor Contract",
            updatedAt: now.addingTimeInterval(-12 * 24 * 3600),
            tags: ["Legal"]
        )
        // One node, exercising the singular "node" label.
        add(&vendor.contextNodes, [
            (.actionItem, "Send the redlined SOW back to procurement by Friday.", -12 * 24 * 3600),
        ])

        for workstream in [migration, auth, roadmap, onboarding, vendor] {
            context.insert(workstream)
        }
        try? context.save()
    }

    private static func add(
        _ nodes: inout [ContextNode],
        _ entries: [(ContextNodeType, String, TimeInterval)]
    ) {
        let now = Date.now
        for (type, content, offset) in entries {
            nodes.append(
                ContextNode(content: content, nodeType: type, createdAt: now.addingTimeInterval(offset))
            )
        }
    }
}
