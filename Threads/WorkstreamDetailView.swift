//
//  WorkstreamDetailView.swift
//  Threads
//
//  Workstream Detail: a three-tab view over one workstream.
//    • Stream   — the real conversation UI, wired to `ThreadOrchestrator.send()`.
//    • Context  — the knowledge graph. Stubbed this cycle (next session).
//    • Insights — proactive feed. Stubbed this cycle (see `.claude/rules/ui.md`,
//                 "do not build out").
//
//  Colors come exclusively from `Palette`; no hex values live here. The screen
//  is addressed by `Workstream.id` rather than a passed `@Model` object so the
//  same UUID that drives navigation is the one handed to the orchestrator, and
//  nothing crosses the actor boundary — the view re-queries by id, matching the
//  multi-context pattern `ThreadOrchestrator` documents.
//

import SwiftUI
import SwiftData

// MARK: - Tabs

private enum DetailTab: Hashable {
    case stream, context, insights
}

struct WorkstreamDetailView: View {
    let workstreamID: UUID

    /// The live orchestrator. Optional so previews render an active conversation
    /// without constructing a real model stack (`EmbeddingService.init` can
    /// throw off-device); the input bar disables sending when it is absent.
    var orchestrator: ThreadOrchestrator?

    @Query private var workstreams: [Workstream]
    @State private var tab: DetailTab = .stream

    init(workstreamID: UUID, orchestrator: ThreadOrchestrator? = nil) {
        self.workstreamID = workstreamID
        self.orchestrator = orchestrator
        _workstreams = Query(filter: #Predicate<Workstream> { $0.id == workstreamID })
    }

    private var workstream: Workstream? { workstreams.first }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Stream", systemImage: "bubble.left.and.text.bubble.right.fill", value: DetailTab.stream) {
                StreamTab(workstreamID: workstreamID, orchestrator: orchestrator)
            }
            Tab("Context", systemImage: "square.stack.3d.up.fill", value: DetailTab.context) {
                ContextTab(workstreamID: workstreamID)
            }
            Tab("Insights", systemImage: "sparkles", value: DetailTab.insights) {
                StubTab(
                    systemImage: "sparkles",
                    message: "Proactive insights arrive in a later session."
                )
            }
        }
        .tint(Palette.accent)
        .navigationTitle(workstream?.title ?? "Workstream")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.background, for: .navigationBar)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Stream tab

/// The conversation flow. User input renders plain; assistant responses carry a
/// blue left border; extracted context nodes appear as a compact row of tappable
/// color-coded chips under the assistant turn that produced them, so the
/// conversation stays the dominant element. Persisted messages and nodes arrive via
/// `@Query` as `ThreadOrchestrator` saves them on its own context; the in-flight
/// assistant answer streams into `streamingText` until step 7 persists it.
private struct StreamTab: View {
    let workstreamID: UUID
    var orchestrator: ThreadOrchestrator?

    @Query private var messages: [Message]
    @Query private var nodes: [ContextNode]

    @State private var draft = ""
    @State private var streamingText = ""
    @State private var isSending = false
    @State private var errorText: String?

    init(workstreamID: UUID, orchestrator: ThreadOrchestrator?) {
        self.workstreamID = workstreamID
        self.orchestrator = orchestrator
        _messages = Query(
            filter: #Predicate<Message> { $0.workstream?.id == workstreamID },
            sort: \Message.createdAt
        )
        _nodes = Query(
            filter: #Predicate<ContextNode> { $0.workstream?.id == workstreamID },
            sort: \ContextNode.createdAt
        )
    }

    /// Extracted nodes keyed by the assistant message that produced them, so
    /// each turn's cards render directly beneath it.
    private var nodesBySource: [UUID: [ContextNode]] {
        Dictionary(grouping: nodes.filter { $0.sourceMessageID != nil }) { $0.sourceMessageID! }
    }

    private var canSend: Bool {
        orchestrator != nil
            && !isSending
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(Palette.openQuestion)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

                conversation
                inputBar
            }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { message in
                        MessageBubble(role: message.roleValue, text: message.content)
                            .id(message.id)

                        if let extracted = nodesBySource[message.id], !extracted.isEmpty {
                            ExtractionChipsRow(nodes: extracted)
                        }
                    }

                    if isSending {
                        MessageBubble(role: .assistant, text: streamingText, isStreaming: true)
                            .id(streamingBubbleID)
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { scrollToEnd(proxy) }
            .onChange(of: streamingText) { scrollToEnd(proxy) }
            .onChange(of: isSending) { scrollToEnd(proxy) }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .foregroundStyle(Palette.textPrimary)
                .tint(Palette.accent)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 20))
                .disabled(orchestrator == nil || isSending)
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(canSend ? Palette.accent : Palette.textSecondary)
            }
            .disabled(!canSend)
        }
        .padding(12)
        .background(Palette.surface.ignoresSafeArea(edges: .bottom))
    }

    private let streamingBubbleID = "streaming-assistant"

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if isSending {
                proxy.scrollTo(streamingBubbleID, anchor: .bottom)
            } else if let lastID = messages.last?.id {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, let orchestrator else { return }

        draft = ""
        errorText = nil
        streamingText = ""
        isSending = true

        Task {
            do {
                // The user turn is persisted immediately (step 1) and surfaces
                // through `@Query`; only the streaming assistant delta is held
                // here until step 7 saves the assistant message.
                for try await chunk in orchestrator.send(text, workstreamID: workstreamID) {
                    switch chunk {
                    case .text(let delta): streamingText += delta
                    case .replace(let full): streamingText = full
                    case .thinking, .done: break
                    }
                }
            } catch {
                errorText = error.localizedDescription
            }
            streamingText = ""
            isSending = false
        }
    }
}

// MARK: - Message bubble

/// User turns render plain; assistant turns carry a blue left border. A system
/// turn (never produced by the orchestrator today) falls through to plain.
private struct MessageBubble: View {
    let role: MessageRole
    let text: String
    var isStreaming = false

    var body: some View {
        switch role {
        case .assistant:
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Palette.accent)
                    .frame(width: 3)

                Group {
                    if text.isEmpty && isStreaming {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Palette.textSecondary)
                    } else {
                        Text(text)
                            .font(.body)
                            .foregroundStyle(Palette.textPrimary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .user, .system:
            Text(text)
                .font(.body)
                .foregroundStyle(Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Inline extraction chips

/// A compact, wrapping row of one chip per extracted node, sitting under the
/// assistant turn that produced them. Deliberately a fraction of the height of a
/// full card so the conversation stays dominant; tapping a chip expands that
/// node's full content inline.
private struct ExtractionChipsRow: View {
    let nodes: [ContextNode]
    @State private var expandedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 6) {
                ForEach(nodes) { node in
                    NodeChip(node: node, isExpanded: expandedID == node.id) {
                        withAnimation(.easeOut(duration: 0.18)) {
                            expandedID = (expandedID == node.id) ? nil : node.id
                        }
                    }
                }
            }

            if let expandedID, let node = nodes.first(where: { $0.id == expandedID }) {
                ExpandedNodeContent(node: node)
            }
        }
        .padding(.leading, 15) // align under the assistant text, past its accent bar
    }
}

/// A small pill: node-type icon plus a short label, tinted by the load-bearing
/// semantic color. Superseded nodes are struck through and dimmed.
private struct NodeChip: View {
    let node: ContextNode
    let isExpanded: Bool
    let action: () -> Void

    private var color: Color { Palette.color(for: node.nodeTypeValue) }
    private var isSuperseded: Bool { node.supersededByID != nil }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: iconName(node.nodeTypeValue))
                Text(shortLabel(node.nodeTypeValue))
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(isExpanded ? 0.28 : 0.15), in: Capsule())
            .overlay {
                Capsule().strokeBorder(color.opacity(0.5), lineWidth: isExpanded ? 1 : 0)
            }
            .strikethrough(isSuperseded)
            .opacity(isSuperseded ? 0.3 : 1)
        }
        .buttonStyle(.plain)
    }
}

/// The full text of the tapped node, revealed beneath the chip row.
private struct ExpandedNodeContent: View {
    let node: ContextNode

    private var color: Color { Palette.color(for: node.nodeTypeValue) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName(node.nodeTypeValue).uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
                    .tracking(0.5)
                Text(node.content)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textPrimary)
                    .superseded(node.supersededByID != nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Context tab

/// The knowledge graph for one workstream: every extracted node, grouped by
/// type, each carrying its semantic color border and relevance score. Decayed
/// nodes dim proportionally to relevance; superseded nodes render at 30% opacity
/// with a strikethrough (see `.claude/rules/ui.md`).
private struct ContextTab: View {
    @Query private var nodes: [ContextNode]

    init(workstreamID: UUID) {
        _nodes = Query(
            filter: #Predicate<ContextNode> { $0.workstream?.id == workstreamID },
            sort: \ContextNode.createdAt,
            order: .reverse
        )
    }

    /// Fixed type order so the graph reads the same every visit and mirrors the
    /// color legend's order.
    private static let typeOrder: [ContextNodeType] = [
        .fact, .decision, .openQuestion, .actionItem, .reference, .insight,
    ]

    private var groups: [(type: ContextNodeType, nodes: [ContextNode])] {
        Self.typeOrder.compactMap { type in
            let matching = nodes
                .filter { $0.nodeTypeValue == type }
                .sorted { lhs, rhs in
                    let lhsSuperseded = lhs.supersededByID != nil
                    let rhsSuperseded = rhs.supersededByID != nil
                    if lhsSuperseded != rhsSuperseded { return !lhsSuperseded }
                    return lhs.relevanceScore > rhs.relevanceScore
                }
            return matching.isEmpty ? nil : (type, matching)
        }
    }

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            if nodes.isEmpty {
                StubTab(
                    systemImage: "square.stack.3d.up.slash",
                    message: "No context extracted yet.\nIt accumulates as the conversation grows."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(groups, id: \.type) { group in
                            ContextGroup(type: group.type, nodes: group.nodes)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

/// One type's heading and its nodes.
private struct ContextGroup: View {
    let type: ContextNodeType
    let nodes: [ContextNode]

    private var color: Color { Palette.color(for: type) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(displayName(type).uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .tracking(0.5)
                Text("\(nodes.count)")
                    .font(.caption)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
            }

            ForEach(nodes) { node in
                ContextNodeRow(node: node)
            }
        }
    }
}

/// One node: semantic color border, content, and a visible relevance meter.
/// Superseded → 30% opacity + strikethrough; otherwise dimmed proportionally to
/// relevance so decayed context recedes without disappearing.
private struct ContextNodeRow: View {
    let node: ContextNode

    private var color: Color { Palette.color(for: node.nodeTypeValue) }
    private var isSuperseded: Bool { node.supersededByID != nil }

    /// 30% for superseded; otherwise a floor of 0.35 so a low-relevance node
    /// still reads, scaling up to full opacity at relevance 1.0.
    private var rowOpacity: Double {
        if isSuperseded { return 0.3 }
        return max(0.35, min(1, node.relevanceScore))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 8) {
                Text(node.content)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textPrimary)
                    .strikethrough(isSuperseded)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    RelevanceMeter(score: node.relevanceScore, color: color)
                    if isSuperseded {
                        Text("· superseded")
                            .font(.caption2)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(color.opacity(0.4), lineWidth: 1)
        }
        .opacity(rowOpacity)
    }
}

/// A small horizontal bar plus the numeric relevance score, in the node's color.
private struct RelevanceMeter: View {
    let score: Double
    let color: Color

    private var fraction: Double { max(0, min(1, score)) }

    var body: some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(Palette.elevated)
                .frame(width: 44, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color)
                        .frame(width: 44 * fraction, height: 4)
                }
            Text(String(format: "%.2f", score))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Palette.textSecondary)
        }
    }
}

// MARK: - Stub tab

/// Placeholder for empty states and the Insights tab (built in a later session).
private struct StubTab: View {
    let systemImage: String
    let message: String

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        }
    }
}

// MARK: - Helpers

/// Human-readable label for a node type. Kept in the view layer so the model
/// stays free of presentation concerns.
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

/// Short chip label — the type name trimmed to keep chips compact.
private func shortLabel(_ type: ContextNodeType) -> String {
    switch type {
    case .fact: "Fact"
    case .decision: "Decision"
    case .openQuestion: "Question"
    case .reference: "Ref"
    case .actionItem: "Action"
    case .insight: "Insight"
    }
}

/// SF Symbol standing in for a node type on a chip.
private func iconName(_ type: ContextNodeType) -> String {
    switch type {
    case .fact: "info.circle.fill"
    case .decision: "arrow.triangle.branch"
    case .openQuestion: "questionmark.circle.fill"
    case .reference: "link"
    case .actionItem: "checkmark.circle.fill"
    case .insight: "sparkles"
    }
}

// MARK: - Previews

#Preview("Stream — Active conversation") {
    let container = DetailPreviewData.container()
    NavigationStack {
        WorkstreamDetailView(workstreamID: DetailPreviewData.workstreamID)
    }
    .modelContainer(container)
}

#Preview("Context — Grouped nodes") {
    let container = DetailPreviewData.container()
    NavigationStack {
        ContextTab(workstreamID: DetailPreviewData.workstreamID)
            .navigationTitle("Auth Rewrite")
            .navigationBarTitleDisplayMode(.inline)
    }
    .preferredColorScheme(.dark)
    .modelContainer(container)
}

/// In-memory sample data: one workstream with a user/assistant exchange and the
/// context nodes that exchange produced, so the Stream tab previews an active
/// conversation with no live orchestrator. Relevance scores vary and one node is
/// superseded, so the Context tab's decay-dimming and strikethrough are visible.
@MainActor
private enum DetailPreviewData {
    static let workstreamID = UUID()

    static func container() -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(
            for: Workstream.self, Message.self, ContextNode.self, ProactiveSurfacing.self,
            configurations: config
        )
        seed(into: container.mainContext)
        return container
    }

    private static func seed(into context: ModelContext) {
        let now = Date.now
        let workstream = Workstream(
            id: workstreamID,
            title: "Auth Rewrite",
            summary: "Replace the token refresh path; it double-refreshes under load.",
            updatedAt: now,
            tags: ["Security", "Backend"]
        )
        context.insert(workstream)

        func user(_ content: String, _ offset: TimeInterval) {
            let m = Message(role: .user, content: content, createdAt: now.addingTimeInterval(offset))
            m.workstream = workstream
            context.insert(m)
        }
        func assistant(_ content: String, _ offset: TimeInterval) -> Message {
            let m = Message(role: .assistant, content: content, createdAt: now.addingTimeInterval(offset))
            m.workstream = workstream
            context.insert(m)
            return m
        }
        func node(
            _ type: ContextNodeType,
            _ content: String,
            from source: Message,
            _ offset: TimeInterval,
            relevance: Double = 1.0,
            superseded: Bool = false
        ) {
            let n = ContextNode(
                content: content,
                nodeType: type,
                createdAt: now.addingTimeInterval(offset),
                relevanceScore: relevance,
                sourceMessageID: source.id
            )
            if superseded { n.supersededByID = UUID() }
            n.workstream = workstream
            context.insert(n)
        }

        user("The refresh endpoint fires twice when two requests race. What's the cleanest fix?", -600)
        let a1 = assistant(
            "The double-refresh is a concurrency problem, not a token problem. Serialize refreshes behind a single actor so a second caller awaits the first's result instead of starting its own. Rotating tokens on every use would compound the race, so decide that separately.",
            -580
        )
        node(.fact, "The refresh endpoint double-fires when two requests race.", from: a1, -575, relevance: 0.94)
        node(.decision, "Serialize token refresh behind a single actor so concurrent callers share one in-flight refresh.", from: a1, -574, relevance: 0.88)
        node(.openQuestion, "Do we rotate refresh tokens on every use or on a fixed schedule?", from: a1, -573, relevance: 0.62)
        // Superseded by the auth-layer decision below — shows strikethrough + 30%.
        node(.decision, "Guard the refresh call with a lock in the networking layer.", from: a1, -572, relevance: 0.45, superseded: true)
        // A decayed, low-relevance fact — dims proportionally but stays legible.
        node(.fact, "Legacy tokens were refreshed on a fixed 15-minute timer.", from: a1, -571, relevance: 0.31)

        user("Let's serialize it. Who owns the actor — networking layer or auth?", -300)
        let a2 = assistant(
            "Put it in the auth layer. Networking should stay unaware of token lifecycle; it just asks auth for a valid token and awaits. That keeps the retry-on-401 path from needing to know about refresh at all.",
            -280
        )
        node(.decision, "The serialized-refresh actor lives in the auth layer, not networking.", from: a2, -275, relevance: 0.9)
        node(.actionItem, "Spike an actor-isolated token store and measure contention under load.", from: a2, -274, relevance: 0.78)
        node(.reference, "RFC 6749 §6 — refresh token grant semantics.", from: a2, -273, relevance: 0.5)

        try? context.save()
    }
}
