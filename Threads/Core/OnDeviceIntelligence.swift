//
//  OnDeviceIntelligence.swift
//  Threads
//
//  Layer 2 of the architecture: the on-device Foundation Models work — the
//  four structured-generation tasks that never touch the network.
//
//  ## Shape
//
//  Four `@Generable` result types, one per task, each with its own
//  `LanguageModelSession`:
//
//  | Task          | Result              | Model                              |
//  | ------------- | ------------------- | ---------------------------------- |
//  | extraction    | `ExtractedContext`  | `SystemLanguageModel.default`      |
//  | summarization | `WorkstreamSummary` | `SystemLanguageModel.default`      |
//  | proactive     | `ProactiveAnalysis` | `SystemLanguageModel.default`      |
//  | tagging       | `ContentTags`       | `.init(useCase: .contentTagging)`  |
//
//  The sessions are separate because their instructions are: a session is the
//  instructions plus the transcript they accumulate, and one session shared
//  across four jobs would carry an extraction transcript into a summarization
//  request.
//
//  ## Why an actor
//
//  `LanguageModelSession` throws `GenerationError.concurrentRequests` when a
//  second `respond` starts while the first is in flight. The sessions are the
//  mutable state this type owns, and actor isolation keeps every synchronous
//  access to them race-free — but `respond` itself `await`s mid-call, and
//  Swift actors are reentrant across a suspension point, so two calls for the
//  same task could otherwise interleave there. `generate` closes that gap
//  with a small per-task mutex (`acquireLock`/`releaseLock`) rather than
//  relying on isolation alone.
//
//  ## No SwiftData here
//
//  Everything crossing this file's boundary is a `Sendable` value type. The
//  orchestrator owns the `ModelContext` and does the mapping from
//  `CalibratedExtraction` to `ContextNode`, so extraction never has to reason
//  about which isolation domain a `@Model` object belongs to.
//

import Foundation
import FoundationModels

// MARK: - Generable results
//
// Explicitly `nonisolated`: the app target defaults to MainActor isolation
// (`SWIFT_DEFAULT_ACTOR_ISOLATION`), and `Generable` conformance is satisfied
// by a static `generationSchema` the framework reads from any domain.
//
// No property here is an `Optional`. `Optional` is documented as conforming to
// `ConvertibleToGeneratedContent`, not to `Generable`, so "absent" is spelled
// as an empty string or an empty array throughout and the meaning of empty is
// stated in the `@Guide` the model actually sees.

/// What the on-device model pulled out of one user/assistant exchange.
///
/// A flat item list rather than one array per node type: the model decides how
/// many of each it found, and a four-array shape pushes it toward filling every
/// array whether or not the exchange contained anything of that kind.
@Generable(description: "The durable facts, decisions, questions and tasks contained in a conversation exchange.")
nonisolated struct ExtractedContext: Sendable, Equatable {
    @Guide(
        description: "One entry per distinct piece of durable context. Empty when the exchange established nothing worth remembering.",
        .maximumCount(8)
    )
    var items: [ExtractedItem]

    init(items: [ExtractedItem] = []) {
        self.items = items
    }
}

/// One atom of the knowledge graph, before it becomes a `ContextNode`.
@Generable(description: "A single self-contained piece of context.")
nonisolated struct ExtractedItem: Sendable, Equatable {
    @Guide(description: "The context itself, as one self-contained sentence that makes sense without the conversation around it.")
    var content: String

    @Guide(description: "Which kind of context this is.")
    var kind: ExtractedItemKind

    @Guide(
        description: "How confident you are that this is accurate and worth remembering, from 0.0 to 1.0.",
        .range(0.0 ... 1.0)
    )
    var confidence: Double

    @Guide(description: "If this replaces something in the existing context list, the text of the entry it replaces. Empty string if it replaces nothing.")
    var supersedes: String

    init(content: String, kind: ExtractedItemKind, confidence: Double, supersedes: String = "") {
        self.content = content
        self.kind = kind
        self.confidence = confidence
        self.supersedes = supersedes
    }
}

/// The `ContextNodeType` cases, restated as a `@Generable` enum.
///
/// Not `ContextNodeType` itself: that type is the SwiftData storage vocabulary
/// and carries a `String` raw value for `#Predicate`'s sake, while this one is
/// a generation vocabulary the model picks from. `nodeType` below is the single
/// point where the two are pinned together, so a case added to one and not the
/// other fails to compile rather than silently mapping to `.fact`.
@Generable(description: "The kind of context an extracted item represents.")
nonisolated enum ExtractedItemKind: Equatable, Sendable, CaseIterable {
    case fact
    case decision
    case openQuestion
    case reference
    case actionItem
    case insight

    /// The raw `String` the `ContextNode.nodeType` column stores.
    ///
    /// Raw strings rather than `ContextNodeType` at the boundary, matching
    /// `ScoredContextNode.nodeType` in `ContextEngine.swift`.
    var nodeType: String {
        switch self {
        case .fact: return ContextNodeType.fact.rawValue
        case .decision: return ContextNodeType.decision.rawValue
        case .openQuestion: return ContextNodeType.openQuestion.rawValue
        case .reference: return ContextNodeType.reference.rawValue
        case .actionItem: return ContextNodeType.actionItem.rawValue
        case .insight: return ContextNodeType.insight.rawValue
        }
    }
}

/// The compact standing description of a workstream, regenerated every tenth
/// message rather than every message.
@Generable(description: "A compact standing summary of a workstream.")
nonisolated struct WorkstreamSummary: Sendable, Equatable {
    @Guide(description: "A short title for the workstream, at most eight words, no trailing punctuation.")
    var title: String

    @Guide(description: "Two to four sentences describing where this workstream currently stands. Written to be read by an assistant that has not seen the conversation.")
    var compactContext: String

    @Guide(
        description: "The decisions currently in force, most important first. Superseded decisions are excluded.",
        .maximumCount(5)
    )
    var activeDecisions: [String]

    @Guide(
        description: "The questions still unresolved. Empty when nothing is outstanding.",
        .maximumCount(5)
    )
    var openQuestions: [String]

    init(
        title: String = "",
        compactContext: String = "",
        activeDecisions: [String] = [],
        openQuestions: [String] = []
    ) {
        self.title = title
        self.compactContext = compactContext
        self.activeDecisions = activeDecisions
        self.openQuestions = openQuestions
    }
}

/// Whether anything in a workstream is worth raising unprompted.
///
/// `shouldSurface` is a field rather than the presence of a payload because
/// "nothing to raise" is the common answer and the model has to be able to say
/// it plainly. `ProactiveSurfacing` rows are written only when it is true.
@Generable(description: "An assessment of whether a workstream contains something worth raising with the user unprompted.")
nonisolated struct ProactiveAnalysis: Sendable, Equatable {
    @Guide(description: "True only when there is something genuinely worth interrupting the user for. Prefer false.")
    var shouldSurface: Bool

    @Guide(description: "What to say to the user, as one or two sentences. Empty string when shouldSurface is false.")
    var content: String

    @Guide(description: "Why this is worth raising now. Empty string when shouldSurface is false.")
    var triggerReason: String

    @Guide(
        description: "How confident you are that this is worth raising, from 0.0 to 1.0.",
        .range(0.0 ... 1.0)
    )
    var confidence: Double

    init(
        shouldSurface: Bool = false,
        content: String = "",
        triggerReason: String = "",
        confidence: Double = 0
    ) {
        self.shouldSurface = shouldSurface
        self.content = content
        self.triggerReason = triggerReason
        self.confidence = confidence
    }
}

/// Topical tags for a piece of text, produced by the content-tagging adapter
/// rather than the general model. Feeds `Workstream.tags`.
@Generable(description: "Topical tags describing a piece of text.")
nonisolated struct ContentTags: Sendable, Equatable {
    @Guide(
        description: "Topics the text is about, as lowercase noun phrases.",
        .maximumCount(6)
    )
    var topics: [String]

    @Guide(
        description: "Actions or tasks the text implies, as short lowercase verb phrases. Empty when it implies none.",
        .maximumCount(4)
    )
    var actions: [String]

    @Guide(
        description: "Words for the emotional tone, if the text carries one. Empty for neutral text.",
        .maximumCount(3)
    )
    var emotions: [String]

    init(topics: [String] = [], actions: [String] = [], emotions: [String] = []) {
        self.topics = topics
        self.actions = actions
        self.emotions = emotions
    }
}

// MARK: - Inputs

/// A context node as the on-device model sees it: no embedding, no score, no
/// identity.
///
/// Not `ScoredContextNode`: that type carries a retrieval score, and at
/// extraction and summarization time no retrieval has run, so every value
/// constructed for those calls would have to invent one.
nonisolated struct ContextFragment: Sendable, Equatable {
    let content: String
    let nodeType: String
    let isSuperseded: Bool

    init(content: String, nodeType: String, isSuperseded: Bool = false) {
        self.content = content
        self.nodeType = nodeType
        self.isSuperseded = isSuperseded
    }
}

/// One user turn and the reply it drew, which is the unit extraction runs over.
nonisolated struct ConversationExchange: Sendable, Equatable {
    let workstreamTitle: String
    let userMessage: String
    let assistantMessage: String

    /// Context already on file. Present so the model can point at an entry this
    /// exchange replaces; that pointer is what eventually sets
    /// `ContextNode.supersededByID`.
    let existingContext: [ContextFragment]

    init(
        workstreamTitle: String,
        userMessage: String,
        assistantMessage: String,
        existingContext: [ContextFragment] = []
    ) {
        self.workstreamTitle = workstreamTitle
        self.userMessage = userMessage
        self.assistantMessage = assistantMessage
        self.existingContext = existingContext
    }
}

/// Everything the summarizer and the proactive pass read about a workstream.
nonisolated struct WorkstreamDigest: Sendable, Equatable {
    let title: String
    let fragments: [ContextFragment]

    /// Reuses `ContextEngine`'s snapshot type: the orchestrator has already
    /// built these for the token-budgeted history, and nothing here needs a
    /// field that type lacks.
    let recentMessages: [MessageSnapshot]

    init(title: String, fragments: [ContextFragment] = [], recentMessages: [MessageSnapshot] = []) {
        self.title = title
        self.fragments = fragments
        self.recentMessages = recentMessages
    }
}

// MARK: - Confidence calibration

/// An extracted item after calibration, ready to become a `ContextNode`.
nonisolated struct CalibratedExtraction: Sendable, Equatable {
    let content: String
    /// Raw value of a `ContextNodeType`.
    let nodeType: String
    /// Goes into `ContextNode.extractionConfidence`.
    let confidence: Double
    /// Text of the existing entry this replaces; empty when it replaces
    /// nothing. The orchestrator resolves it to a node ID and writes
    /// `supersededByID`.
    let supersedes: String
    /// True when `confidence` fell below the policy threshold. These do not get
    /// stored as facts; they go back out to Claude to be redone.
    let needsEscalation: Bool
}

/// Turns the model's self-reported confidence into a number worth storing.
///
/// A 3B model's self-report is not calibrated — it skews high and it does not
/// notice its own failure modes. Two of those failures are detectable from the
/// text alone without a second model call, and both multiply the reported
/// confidence down rather than rejecting outright, so the threshold stays the
/// single place that decides what gets escalated:
///
/// - **Over-long content.** An "atom" that runs past `maximumContentLength` is
///   a paragraph, not a fact, and will embed badly.
/// - **Echoing.** Content that is substantially the source text copied back is
///   the extraction having not happened at all.
///
/// A pure value type on purpose: this is the part of extraction that can be
/// tested without a model, and it stays testable by never calling one.
nonisolated struct ExtractionConfidencePolicy: Sendable, Equatable {
    /// Below this, escalate rather than store. `ContextNode` defaults
    /// `extractionConfidence` to 1.0, so anything written by this path is
    /// distinguishable from a hand-made node.
    var threshold: Double
    var minimumContentLength: Int
    var maximumContentLength: Int
    var overLongPenalty: Double
    var echoPenalty: Double

    init(
        threshold: Double = 0.6,
        minimumContentLength: Int = 8,
        maximumContentLength: Int = 280,
        overLongPenalty: Double = 0.5,
        echoPenalty: Double = 0.5
    ) {
        self.threshold = threshold
        self.minimumContentLength = minimumContentLength
        self.maximumContentLength = maximumContentLength
        self.overLongPenalty = overLongPenalty
        self.echoPenalty = echoPenalty
    }

    /// Drops degenerate items, deduplicates, and scores what remains.
    ///
    /// `source` is the text the extraction ran over; pass it to enable the echo
    /// check. Order is preserved: the model puts what it considers most
    /// important first, and nothing here knows better.
    func calibrate(_ extraction: ExtractedContext, source: String = "") -> [CalibratedExtraction] {
        let normalizedSource = Self.normalize(source)
        var seen = Set<String>()
        var results: [CalibratedExtraction] = []

        for item in extraction.items {
            let content = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard content.count >= minimumContentLength else { continue }

            let key = Self.normalize(content)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }

            var confidence = min(max(item.confidence, 0), 1)
            if content.count > maximumContentLength {
                confidence *= overLongPenalty
            }
            if Self.isEcho(key, of: normalizedSource) {
                confidence *= echoPenalty
            }

            results.append(
                CalibratedExtraction(
                    content: content,
                    nodeType: item.kind.nodeType,
                    confidence: confidence,
                    supersedes: item.supersedes.trimmingCharacters(in: .whitespacesAndNewlines),
                    needsEscalation: confidence < threshold
                )
            )
        }
        return results
    }

    /// Case- and whitespace-insensitive form, used both as the dedup key and as
    /// the echo comparison basis so the two agree on what "the same text" is.
    static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .joined(separator: " ")
    }

    /// True when the "extraction" is really the source text handed back.
    ///
    /// Containment alone would flag a genuine short fact that happens to appear
    /// verbatim in a long message, which is a correct extraction. The length
    /// ratio is what separates the two: only a copy accounts for most of what
    /// it was copied from.
    static func isEcho(_ normalizedContent: String, of normalizedSource: String) -> Bool {
        guard !normalizedSource.isEmpty, !normalizedContent.isEmpty else { return false }
        guard normalizedSource.contains(normalizedContent) else { return false }
        return Double(normalizedContent.count) >= 0.6 * Double(normalizedSource.count)
    }
}

// MARK: - Errors

nonisolated enum OnDeviceIntelligenceError: Error, Equatable, LocalizedError {
    /// Apple Intelligence is off, still downloading, or unsupported here.
    case modelUnavailable(task: String, reason: String)
    /// The prompt alone did not fit the context window, so clearing the
    /// transcript and retrying could not help. The caller has to send less.
    case promptTooLarge(task: String)
    /// The model declined to answer.
    case refused(task: String, debugDescription: String)
    /// The prompt or the response tripped the safety guardrails.
    case guardrailViolation(task: String)
    case generationFailed(task: String, debugDescription: String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let task, let reason):
            return "On-device \(task) is unavailable: \(reason)."
        case .promptTooLarge(let task):
            return "The \(task) prompt exceeds the on-device model's context window."
        case .refused(let task, let debugDescription):
            return "The on-device model declined the \(task) request: \(debugDescription)"
        case .guardrailViolation(let task):
            return "The \(task) request was blocked by the on-device model's safety guardrails."
        case .generationFailed(let task, let debugDescription):
            return "On-device \(task) failed: \(debugDescription)"
        }
    }
}

// MARK: - OnDeviceIntelligence

/// The four Foundation Models tasks, behind one actor.
actor OnDeviceIntelligence {

    /// One case per task, which is also one case per session and one per set of
    /// instructions. The tagging case is the only one that runs on a model
    /// other than `.default`.
    enum Task: String, CaseIterable, Sendable {
        case extraction
        case summarization
        case proactive
        case tagging
    }

    private let generalModel: SystemLanguageModel
    private let taggingModel: SystemLanguageModel
    private let policy: ExtractionConfidencePolicy

    /// Created on first use and kept. Recreated only when a transcript grows
    /// past the context window — see `generate(_:for:prompt:)`.
    private var sessions: [Task: LanguageModelSession] = [:]

    /// One mutex per task, guarding the whole `generate` critical section
    /// (including the reset-and-retry path) against actor reentrancy. See
    /// "Why an actor" above.
    private var busyTasks: Set<Task> = []
    private var lockWaiters: [Task: [CheckedContinuation<Void, Never>]] = [:]

    init(
        generalModel: SystemLanguageModel = .default,
        taggingModel: SystemLanguageModel = SystemLanguageModel(useCase: .contentTagging),
        policy: ExtractionConfidencePolicy = ExtractionConfidencePolicy()
    ) {
        self.generalModel = generalModel
        self.taggingModel = taggingModel
        self.policy = policy
    }

    // MARK: Availability

    /// Whether the general model can answer. Extraction, summarization and the
    /// proactive pass all depend on it.
    var isAvailable: Bool { generalModel.isAvailable }

    /// Checked separately: the content-tagging adapter can be missing while the
    /// general model is fine, and tagging is the only task that needs it.
    var isTaggingAvailable: Bool { taggingModel.isAvailable }

    func availability(for task: Task) -> SystemLanguageModel.Availability {
        model(for: task).availability
    }

    /// Pays the model-load cost before the user is waiting on it. Safe to call
    /// when the model is unavailable; `prewarm` is not a generation call.
    func prewarm(_ tasks: [Task] = Task.allCases) {
        for task in tasks {
            session(for: task).prewarm()
        }
    }

    // MARK: Tasks

    /// Step 8 of the lifecycle. Returns items already calibrated, so the caller
    /// gets `needsEscalation` rather than a raw self-report to threshold itself.
    func extractContext(from exchange: ConversationExchange) async throws -> [CalibratedExtraction] {
        let extraction: ExtractedContext = try await generate(
            ExtractedContext.self,
            for: .extraction,
            prompt: IntelligencePrompts.extraction(for: exchange),
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 768)
        )
        return policy.calibrate(extraction, source: IntelligencePrompts.extractionSource(for: exchange))
    }

    /// Step 12. Called every tenth message, not every message.
    func summarize(_ digest: WorkstreamDigest) async throws -> WorkstreamSummary {
        try await generate(
            WorkstreamSummary.self,
            for: .summarization,
            prompt: IntelligencePrompts.summary(for: digest),
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 512)
        )
    }

    /// Retained per SPEC as a schema-level capability; nothing calls it in this
    /// cycle. It exists here rather than in a later file because the session it
    /// needs is one of the four this type owns.
    func analyzeForSurfacing(_ digest: WorkstreamDigest, now: Date = .now) async throws -> ProactiveAnalysis {
        try await generate(
            ProactiveAnalysis.self,
            for: .proactive,
            prompt: IntelligencePrompts.proactive(for: digest, now: now),
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 256)
        )
    }

    /// Runs on the content-tagging adapter rather than the general model.
    func tags(for text: String) async throws -> ContentTags {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ContentTags() }
        return try await generate(
            ContentTags.self,
            for: .tagging,
            prompt: IntelligencePrompts.tagging(for: trimmed),
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 128)
        )
    }

    // MARK: Session plumbing

    private func model(for task: Task) -> SystemLanguageModel {
        task == .tagging ? taggingModel : generalModel
    }

    private func session(for task: Task) -> LanguageModelSession {
        if let existing = sessions[task] { return existing }
        let created = LanguageModelSession(
            model: model(for: task),
            instructions: IntelligencePrompts.instructions(for: task)
        )
        sessions[task] = created
        return created
    }

    /// Drops the session so the next call builds a fresh one. The instructions
    /// come back with it; only the accumulated transcript is lost, which is the
    /// point.
    private func resetSession(for task: Task) {
        sessions[task] = nil
    }

    // MARK: Per-task mutex
    //
    // `internal` rather than `private` so the mutex itself is directly
    // testable without a model call — see `OnDeviceIntelligenceLockingTests`.

    /// Suspends until no other call is holding `task`'s lock, then takes it.
    func acquireLock(for task: Task) async {
        if busyTasks.insert(task).inserted { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lockWaiters[task, default: []].append(continuation)
        }
    }

    /// Hands the lock straight to the next waiter, if any, so nothing else
    /// can acquire it in between.
    func releaseLock(for task: Task) {
        guard var queue = lockWaiters[task], !queue.isEmpty else {
            busyTasks.remove(task)
            return
        }
        let next = queue.removeFirst()
        lockWaiters[task] = queue.isEmpty ? nil : queue
        next.resume()
    }

    /// The single generation path.
    ///
    /// Sessions are held per task rather than made per call, so a transcript
    /// accumulates across requests and will eventually exceed the context
    /// window — `contextSize` is 4096 tokens. That is recoverable exactly once:
    /// clear the transcript and retry. If it overflows again the prompt itself
    /// is too big, which no amount of clearing fixes, so that becomes
    /// `.promptTooLarge` instead of a retry loop.
    private func generate<Content: Generable>(
        _ type: Content.Type,
        for task: Task,
        prompt: String,
        options: GenerationOptions
    ) async throws -> Content {
        switch model(for: task).availability {
        case .available:
            break
        case .unavailable(let reason):
            throw OnDeviceIntelligenceError.modelUnavailable(
                task: task.rawValue,
                reason: OnDeviceFallbackProvider.describe(reason)
            )
        }

        await acquireLock(for: task)
        defer { releaseLock(for: task) }

        do {
            return try await respond(type, for: task, prompt: prompt, options: options)
        } catch let error as LanguageModelSession.GenerationError {
            guard case .exceededContextWindowSize = error else {
                throw Self.mapped(error, task: task)
            }
            resetSession(for: task)
            do {
                return try await respond(type, for: task, prompt: prompt, options: options)
            } catch let retryError as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = retryError {
                    throw OnDeviceIntelligenceError.promptTooLarge(task: task.rawValue)
                }
                throw Self.mapped(retryError, task: task)
            }
        }
    }

    private func respond<Content: Generable>(
        _ type: Content.Type,
        for task: Task,
        prompt: String,
        options: GenerationOptions
    ) async throws -> Content {
        do {
            let response = try await session(for: task).respond(
                to: prompt,
                generating: type,
                options: options
            )
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            // Re-thrown untouched so `generate` can see the context-window case.
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OnDeviceIntelligenceError.generationFailed(
                task: task.rawValue,
                debugDescription: String(describing: error)
            )
        }
    }

    /// Every `GenerationError` case except `exceededContextWindowSize`, which
    /// `generate` handles before this is reached.
    static func mapped(
        _ error: LanguageModelSession.GenerationError,
        task: Task
    ) -> OnDeviceIntelligenceError {
        switch error {
        case .refusal(_, let context):
            // The refusal's `explanation` is itself a generation call. Not worth
            // a second round trip on a background extraction — the debug
            // description is enough to log.
            return .refused(task: task.rawValue, debugDescription: context.debugDescription)
        case .guardrailViolation:
            return .guardrailViolation(task: task.rawValue)
        case .assetsUnavailable(let context):
            return .modelUnavailable(task: task.rawValue, reason: context.debugDescription)
        default:
            return .generationFailed(task: task.rawValue, debugDescription: String(describing: error))
        }
    }
}

// MARK: - Prompts

/// Instructions and prompt bodies, split out as pure functions.
///
/// Separate from the actor so prompt construction — which is where truncation
/// and formatting bugs live — is testable on a machine with no Apple
/// Intelligence, which includes the simulator this project builds for.
nonisolated enum IntelligencePrompts {

    /// Caps on how much of a workstream goes into a prompt. The on-device
    /// context window is 4096 tokens for instructions, prompt and response
    /// together, so these are budget, not style.
    static let maximumExistingFragments = 12
    static let maximumDigestFragments = 20
    static let maximumDigestMessages = 12
    static let maximumFieldCharacters = 600

    static func instructions(for task: OnDeviceIntelligence.Task) -> String {
        switch task {
        case .extraction:
            return """
            You extract durable context from conversations.

            Return only things that stay true after the conversation ends: facts \
            established, decisions made, questions left open, tasks assigned, \
            references cited, insights reached.

            Rules:
            - One idea per item, written as a standalone sentence. Never copy a \
            message back verbatim.
            - Skip pleasantries, restatements of the question, and anything the \
            assistant merely speculated about.
            - Return no items at all when the exchange established nothing. An \
            empty list is a correct answer and is preferred over a weak one.
            - Set `supersedes` only when an item directly replaces a listed \
            existing entry, and quote that entry's text exactly.
            - Report confidence honestly. Low confidence on a shaky item is more \
            useful than false certainty.
            """
        case .summarization:
            return """
            You write compact standing summaries of ongoing workstreams.

            The summary is read by an assistant that has not seen the \
            conversation, so it has to carry the state rather than describe the \
            discussion. Prefer the current state of things over their history. \
            Do not include superseded decisions. Be specific and use the user's \
            own terms.
            """
        case .proactive:
            return """
            You decide whether a workstream contains something worth raising \
            with the user unprompted.

            The bar is high: an unresolved commitment, a decision contradicted \
            by a later one, a deadline about to pass. Ordinary progress is not \
            worth an interruption. Answering false is the normal outcome.
            """
        case .tagging:
            return """
            You tag text with the topics it covers, the actions it implies, and \
            the emotional tone it carries. Use short lowercase phrases. Return \
            empty lists rather than guessing.
            """
        }
    }

    // MARK: Extraction

    static func extraction(for exchange: ConversationExchange) -> String {
        var sections: [String] = []
        sections.append("Workstream: \(clip(exchange.workstreamTitle, to: 120))")

        if !exchange.existingContext.isEmpty {
            let existing = exchange.existingContext
                .prefix(maximumExistingFragments)
                .map { fragment -> String in
                    let marker = fragment.isSuperseded ? " (superseded)" : ""
                    return "- [\(fragment.nodeType)\(marker)] \(clip(fragment.content, to: 200))"
                }
                .joined(separator: "\n")
            sections.append("Existing context:\n\(existing)")
        }

        sections.append("User:\n\(clip(exchange.userMessage, to: maximumFieldCharacters))")
        sections.append("Assistant:\n\(clip(exchange.assistantMessage, to: maximumFieldCharacters))")
        sections.append("Extract the durable context from this exchange.")
        return sections.joined(separator: "\n\n")
    }

    /// The text an extraction is measured against by the echo check. Only the
    /// turns themselves — the existing-context list is not something the model
    /// could be accused of copying back, since repeating it is the correct
    /// behaviour when an item supersedes one of those entries.
    static func extractionSource(for exchange: ConversationExchange) -> String {
        "\(exchange.userMessage)\n\(exchange.assistantMessage)"
    }

    // MARK: Summarization

    static func summary(for digest: WorkstreamDigest) -> String {
        var sections: [String] = []
        sections.append("Workstream: \(clip(digest.title, to: 120))")

        // Superseded fragments are labelled rather than dropped: "we moved off
        // Postgres" is only summarizable if the model can see that Postgres was
        // once the decision.
        if !digest.fragments.isEmpty {
            let fragments = digest.fragments
                .prefix(maximumDigestFragments)
                .map { fragment in
                    let marker = fragment.isSuperseded ? " (superseded)" : ""
                    return "- [\(fragment.nodeType)\(marker)] \(clip(fragment.content, to: 200))"
                }
                .joined(separator: "\n")
            sections.append("Context so far:\n\(fragments)")
        }

        if !digest.recentMessages.isEmpty {
            sections.append("Recent conversation:\n\(transcript(of: digest.recentMessages))")
        }

        sections.append("Write the standing summary of this workstream.")
        return sections.joined(separator: "\n\n")
    }

    // MARK: Proactive

    static func proactive(for digest: WorkstreamDigest, now: Date) -> String {
        var sections: [String] = []
        sections.append("Workstream: \(clip(digest.title, to: 120))")
        sections.append("Current date: \(ISO8601DateFormatter().string(from: now))")

        // Open questions and action items first: they are what an unprompted
        // interruption could legitimately be about, and the budget below may not
        // reach the rest of the list.
        let ordered = digest.fragments.sorted { lhs, rhs in
            surfacingPriority(lhs) < surfacingPriority(rhs)
        }
        if !ordered.isEmpty {
            let fragments = ordered
                .prefix(maximumDigestFragments)
                .map { fragment in
                    let marker = fragment.isSuperseded ? " (superseded)" : ""
                    return "- [\(fragment.nodeType)\(marker)] \(clip(fragment.content, to: 200))"
                }
                .joined(separator: "\n")
            sections.append("Context:\n\(fragments)")
        }

        if !digest.recentMessages.isEmpty {
            sections.append("Recent conversation:\n\(transcript(of: digest.recentMessages))")
        }

        sections.append("Is there anything here worth raising with the user unprompted?")
        return sections.joined(separator: "\n\n")
    }

    static func surfacingPriority(_ fragment: ContextFragment) -> Int {
        if fragment.isSuperseded { return 3 }
        switch fragment.nodeType {
        case ContextNodeType.actionItem.rawValue: return 0
        case ContextNodeType.openQuestion.rawValue: return 1
        default: return 2
        }
    }

    // MARK: Tagging

    static func tagging(for text: String) -> String {
        "Tag the following text.\n\n\(clip(text, to: maximumFieldCharacters))"
    }

    // MARK: Formatting

    /// `messages` arrives newest first — `ContextRetrievalEngine.assemblePayload`
    /// fills the token budget by walking recent messages from most recent
    /// backward, so that is the order its output is in. The most recent
    /// `maximumDigestMessages` are kept, then replayed oldest first so the
    /// model reads the exchange in the order it actually happened.
    static func transcript(of messages: [MessageSnapshot]) -> String {
        messages
            .prefix(maximumDigestMessages)
            .reversed()
            .map { snapshot in
                let role: String
                switch MessageRole(rawValue: snapshot.role) {
                case .user: role = "User"
                case .system: role = "System"
                case .assistant, .none: role = "Assistant"
                }
                return "\(role): \(clip(snapshot.content, to: 240))"
            }
            .joined(separator: "\n")
    }

    /// Truncates on a character count rather than a token count. The prompt
    /// budget is a guard against the 4096-token window, not an exact accounting,
    /// and `SystemLanguageModel.tokenCount(for:)` is an async call that would
    /// turn every prompt builder into an `async throws` function for the sake of
    /// a bound that is already conservative.
    static func clip(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return trimmed.prefix(limit).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
