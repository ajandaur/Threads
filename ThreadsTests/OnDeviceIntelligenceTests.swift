//
//  OnDeviceIntelligenceTests.swift
//  ThreadsTests
//
//  Covers the parts of `OnDeviceIntelligence.swift` that do not call a model:
//  confidence calibration, prompt construction, the generation-to-storage
//  vocabulary mapping, and `GenerationError` translation.
//
//  Nothing here exercises Foundation Models. The simulator this project builds
//  for has no Apple Intelligence, so a test that called `respond` would either
//  be skipped everywhere or would assert on a 3B model's prose. The design puts
//  the checkable logic in `nonisolated` value types precisely so these tests can
//  be real assertions instead.
//

import Foundation
import Testing
@testable import Threads

// MARK: - Confidence calibration

@Suite struct ExtractionConfidencePolicyTests {

    private func item(
        _ content: String,
        kind: ExtractedItemKind = .fact,
        confidence: Double = 0.9,
        supersedes: String = ""
    ) -> ExtractedItem {
        ExtractedItem(content: content, kind: kind, confidence: confidence, supersedes: supersedes)
    }

    @Test func reportedConfidenceSurvivesWhenNothingIsWrongWithTheItem() {
        let policy = ExtractionConfidencePolicy()
        let result = policy.calibrate(
            ExtractedContext(items: [item("The team chose Postgres for the ledger store.", confidence: 0.82)])
        )

        #expect(result.count == 1)
        #expect(result[0].confidence == 0.82)
        #expect(result[0].needsEscalation == false)
        #expect(result[0].nodeType == ContextNodeType.fact.rawValue)
    }

    @Test func confidenceBelowThresholdIsFlaggedForEscalationRatherThanDropped() {
        let policy = ExtractionConfidencePolicy(threshold: 0.6)
        let result = policy.calibrate(
            ExtractedContext(items: [item("Migration might finish in Q3, unclear.", confidence: 0.3)])
        )

        // The item survives — the orchestrator needs it in order to escalate it.
        #expect(result.count == 1)
        #expect(result[0].needsEscalation)
    }

    @Test func thresholdIsExclusiveAtTheBoundary() {
        let policy = ExtractionConfidencePolicy(threshold: 0.6)
        let onIt = policy.calibrate(ExtractedContext(items: [item("Auth ships on the 14th.", confidence: 0.6)]))
        let underIt = policy.calibrate(ExtractedContext(items: [item("Auth ships on the 14th.", confidence: 0.59)]))

        #expect(onIt[0].needsEscalation == false)
        #expect(underIt[0].needsEscalation)
    }

    @Test func reportedConfidenceOutsideZeroToOneIsClamped() {
        let policy = ExtractionConfidencePolicy()
        let result = policy.calibrate(
            ExtractedContext(items: [
                item("Rate limiting lives in the gateway.", confidence: 4.5),
                item("Retries are capped at three attempts.", confidence: -2.0),
            ])
        )

        #expect(result[0].confidence == 1.0)
        #expect(result[1].confidence == 0.0)
        #expect(result[1].needsEscalation)
    }

    @Test func itemsShorterThanTheMinimumAreDiscardedEntirely() {
        let policy = ExtractionConfidencePolicy(minimumContentLength: 8)
        let result = policy.calibrate(
            ExtractedContext(items: [
                item("yes", confidence: 1.0),
                item("   ", confidence: 1.0),
                item("The retry budget is three.", confidence: 1.0),
            ])
        )

        #expect(result.map(\.content) == ["The retry budget is three."])
    }

    @Test func overLongItemsAreDownWeightedBecauseTheyAreNotAtoms() {
        let policy = ExtractionConfidencePolicy(maximumContentLength: 40, overLongPenalty: 0.5)
        let long = String(repeating: "a decision was made and then ", count: 4)
        let result = policy.calibrate(ExtractedContext(items: [item(long, confidence: 0.9)]))

        #expect(long.count > 40)
        #expect(result.count == 1)
        #expect(abs(result[0].confidence - 0.45) < 0.0001)
        #expect(result[0].needsEscalation)
    }

    @Test func contentThatIsJustTheSourceCopiedBackIsDownWeighted() {
        let policy = ExtractionConfidencePolicy(echoPenalty: 0.5)
        let source = "We are going to move the ledger onto Postgres next sprint."
        let result = policy.calibrate(
            ExtractedContext(items: [item(source, confidence: 0.95)]),
            source: source
        )

        #expect(result.count == 1)
        #expect(abs(result[0].confidence - 0.475) < 0.0001)
        #expect(result[0].needsEscalation)
    }

    @Test func aShortFactAppearingVerbatimInALongSourceIsNotTreatedAsAnEcho() {
        // The distinction the echo check exists to make: containment alone would
        // punish a correct extraction from a long message.
        let policy = ExtractionConfidencePolicy()
        let source = """
        Okay so after going back and forth on this for most of the week, and \
        after the load testing came back, we settled on Postgres for the ledger. \
        I will write it up in the design doc tomorrow and circulate it to the \
        rest of the team for comment before we commit to anything further.
        """
        let result = policy.calibrate(
            ExtractedContext(items: [item("we settled on Postgres for the ledger", confidence: 0.9)]),
            source: source
        )

        #expect(result[0].confidence == 0.9)
    }

    @Test func echoCheckIsInertWhenNoSourceIsSupplied() {
        let policy = ExtractionConfidencePolicy()
        let text = "The ledger moves to Postgres."
        let result = policy.calibrate(ExtractedContext(items: [item(text, confidence: 0.9)]))

        #expect(result[0].confidence == 0.9)
    }

    @Test func penaltiesCompoundWhenAnItemIsBothOverLongAndAnEcho() {
        let policy = ExtractionConfidencePolicy(
            maximumContentLength: 40,
            overLongPenalty: 0.5,
            echoPenalty: 0.5
        )
        let source = "We decided to move the whole ledger subsystem onto Postgres."
        let result = policy.calibrate(
            ExtractedContext(items: [item(source, confidence: 0.8)]),
            source: source
        )

        #expect(source.count > 40)
        #expect(abs(result[0].confidence - 0.2) < 0.0001)
    }

    @Test func duplicatesDifferingOnlyByCaseOrPunctuationCollapseToTheFirst() {
        let policy = ExtractionConfidencePolicy()
        let result = policy.calibrate(
            ExtractedContext(items: [
                item("The ledger moves to Postgres.", confidence: 0.9),
                item("the ledger moves to postgres", confidence: 0.4),
                item("The  Ledger   moves to Postgres!", confidence: 0.2),
                item("The gateway owns rate limiting.", confidence: 0.7),
            ])
        )

        #expect(result.count == 2)
        // The first occurrence wins, keeping its own confidence.
        #expect(result[0].content == "The ledger moves to Postgres.")
        #expect(result[0].confidence == 0.9)
        #expect(result[1].content == "The gateway owns rate limiting.")
    }

    @Test func modelOrderingIsPreserved() {
        let policy = ExtractionConfidencePolicy()
        let result = policy.calibrate(
            ExtractedContext(items: [
                item("First established fact here.", confidence: 0.4),
                item("Second established fact here.", confidence: 0.95),
                item("Third established fact here.", confidence: 0.7),
            ])
        )

        #expect(result.map(\.content) == [
            "First established fact here.",
            "Second established fact here.",
            "Third established fact here.",
        ])
    }

    @Test func supersedesTextIsCarriedThroughTrimmed() {
        let policy = ExtractionConfidencePolicy()
        let result = policy.calibrate(
            ExtractedContext(items: [
                item(
                    "The ledger moves to Postgres.",
                    kind: .decision,
                    confidence: 0.9,
                    supersedes: "  The ledger stays on SQLite.\n"
                )
            ])
        )

        #expect(result[0].supersedes == "The ledger stays on SQLite.")
        #expect(result[0].nodeType == ContextNodeType.decision.rawValue)
    }

    @Test func anEmptyExtractionYieldsNothingRatherThanAPlaceholder() {
        #expect(ExtractionConfidencePolicy().calibrate(ExtractedContext()).isEmpty)
    }

    @Test func contentIsTrimmedBeforeBeingStored() {
        let policy = ExtractionConfidencePolicy()
        let result = policy.calibrate(
            ExtractedContext(items: [item("\n  The gateway owns rate limiting.  \n", confidence: 0.9)])
        )

        #expect(result[0].content == "The gateway owns rate limiting.")
    }
}

// MARK: - Generation vocabulary

@Suite struct ExtractedItemKindTests {

    @Test func everyGenerationCaseMapsToARealContextNodeType() {
        for kind in ExtractedItemKind.allCases {
            #expect(
                ContextNodeType(rawValue: kind.nodeType) != nil,
                "\(kind) maps to '\(kind.nodeType)', which is not a ContextNodeType case."
            )
        }
    }

    @Test func theTwoVocabulariesCoverTheSameGround() {
        // Guards the pairing in both directions: a case added to ContextNodeType
        // and not to ExtractedItemKind is a node type the model can never
        // produce, which is a silent gap rather than a compile error.
        let mapped = Set(ExtractedItemKind.allCases.map(\.nodeType))
        let stored = Set(ContextNodeType.allCases.map(\.rawValue))
        #expect(mapped == stored)
    }

    @Test func distinctCasesDoNotCollapseOntoOneNodeType() {
        #expect(Set(ExtractedItemKind.allCases.map(\.nodeType)).count == ExtractedItemKind.allCases.count)
    }
}

// MARK: - Prompt construction

@Suite struct IntelligencePromptsTests {

    private let exchange = ConversationExchange(
        workstreamTitle: "Ledger migration",
        userMessage: "Should we move the ledger to Postgres?",
        assistantMessage: "Given the write volume, yes.",
        existingContext: [
            ContextFragment(content: "The ledger stays on SQLite.", nodeType: ContextNodeType.decision.rawValue),
            ContextFragment(content: "Write volume tripled in June.", nodeType: ContextNodeType.fact.rawValue),
        ]
    )

    @Test func eachTaskGetsItsOwnInstructions() {
        let all = OnDeviceIntelligence.Task.allCases.map(IntelligencePrompts.instructions(for:))
        #expect(Set(all).count == OnDeviceIntelligence.Task.allCases.count)
        #expect(all.allSatisfy { !$0.isEmpty })
    }

    @Test func extractionPromptCarriesBothTurnsAndTheExistingContext() {
        let prompt = IntelligencePrompts.extraction(for: exchange)

        #expect(prompt.contains("Ledger migration"))
        #expect(prompt.contains("Should we move the ledger to Postgres?"))
        #expect(prompt.contains("Given the write volume, yes."))
        #expect(prompt.contains("The ledger stays on SQLite."))
        #expect(prompt.contains("[decision]"))
    }

    @Test func extractionPromptOmitsTheExistingContextSectionWhenThereIsNone() {
        let bare = ConversationExchange(
            workstreamTitle: "New workstream",
            userMessage: "Starting fresh.",
            assistantMessage: "Understood."
        )
        #expect(IntelligencePrompts.extraction(for: bare).contains("Existing context") == false)
    }

    @Test func existingContextIsCappedSoTheWindowCannotBeFlooded() {
        let many = (0 ..< 40).map {
            ContextFragment(content: "Fragment number \($0) of the context.", nodeType: ContextNodeType.fact.rawValue)
        }
        let prompt = IntelligencePrompts.extraction(
            for: ConversationExchange(
                workstreamTitle: "Big",
                userMessage: "Hi",
                assistantMessage: "Hello",
                existingContext: many
            )
        )

        #expect(prompt.contains("Fragment number 0 of the context."))
        #expect(prompt.contains("Fragment number \(IntelligencePrompts.maximumExistingFragments - 1) of the context."))
        #expect(prompt.contains("Fragment number \(IntelligencePrompts.maximumExistingFragments) of the context.") == false)
    }

    @Test func extractionSourceIsTheTurnsAloneNotTheExistingContext() {
        // The echo check compares against this. Including the existing-context
        // list would make a correct supersession — which quotes an existing
        // entry — look like a copy.
        let source = IntelligencePrompts.extractionSource(for: exchange)

        #expect(source.contains("Should we move the ledger to Postgres?"))
        #expect(source.contains("Given the write volume, yes."))
        #expect(source.contains("The ledger stays on SQLite.") == false)
    }

    private let digest = WorkstreamDigest(
        title: "Ledger migration",
        fragments: [
            ContextFragment(
                content: "The ledger stays on SQLite.",
                nodeType: ContextNodeType.decision.rawValue,
                isSuperseded: true
            ),
            ContextFragment(content: "Who owns the cutover?", nodeType: ContextNodeType.openQuestion.rawValue),
            ContextFragment(content: "Draft the migration plan.", nodeType: ContextNodeType.actionItem.rawValue),
        ],
        // Newest first, matching `ContextRetrievalEngine.assemblePayload`'s
        // actual output order.
        recentMessages: [
            MessageSnapshot(
                messageID: UUID(),
                role: MessageRole.assistant.rawValue,
                content: "On Postgres.",
                estimatedTokens: 4,
                createdAt: Date(timeIntervalSince1970: 2)
            ),
            MessageSnapshot(
                messageID: UUID(),
                role: MessageRole.user.rawValue,
                content: "Where did we land?",
                estimatedTokens: 5,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
        ]
    )

    @Test func summaryPromptLabelsSupersededFragmentsRatherThanHidingThem() {
        let prompt = IntelligencePrompts.summary(for: digest)

        #expect(prompt.contains("The ledger stays on SQLite."))
        #expect(prompt.contains("(superseded)"))
        #expect(prompt.contains("Who owns the cutover?"))
    }

    @Test func summaryPromptRendersHistoryOldestFirstWithRoleLabels() throws {
        let prompt = IntelligencePrompts.summary(for: digest)
        let user = try #require(prompt.range(of: "User: Where did we land?"))
        let assistant = try #require(prompt.range(of: "Assistant: On Postgres."))

        #expect(user.lowerBound < assistant.lowerBound)
    }

    @Test func summaryPromptDropsEmptySectionsInsteadOfEmittingEmptyHeaders() {
        let prompt = IntelligencePrompts.summary(for: WorkstreamDigest(title: "Empty"))

        #expect(prompt.contains("Context so far") == false)
        #expect(prompt.contains("Recent conversation") == false)
        #expect(prompt.contains("Empty"))
    }

    @Test func proactivePromptPutsActionableFragmentsAheadOfTheRest() throws {
        let prompt = IntelligencePrompts.proactive(for: digest, now: Date(timeIntervalSince1970: 0))
        let action = try #require(prompt.range(of: "Draft the migration plan."))
        let question = try #require(prompt.range(of: "Who owns the cutover?"))
        let superseded = try #require(prompt.range(of: "The ledger stays on SQLite."))

        #expect(action.lowerBound < question.lowerBound)
        #expect(question.lowerBound < superseded.lowerBound)
    }

    @Test func proactivePriorityRanksActionItemsFirstAndSupersededLast() {
        let action = ContextFragment(content: "a", nodeType: ContextNodeType.actionItem.rawValue)
        let question = ContextFragment(content: "b", nodeType: ContextNodeType.openQuestion.rawValue)
        let fact = ContextFragment(content: "c", nodeType: ContextNodeType.fact.rawValue)
        let stale = ContextFragment(content: "d", nodeType: ContextNodeType.actionItem.rawValue, isSuperseded: true)

        #expect(IntelligencePrompts.surfacingPriority(action) < IntelligencePrompts.surfacingPriority(question))
        #expect(IntelligencePrompts.surfacingPriority(question) < IntelligencePrompts.surfacingPriority(fact))
        #expect(IntelligencePrompts.surfacingPriority(fact) < IntelligencePrompts.surfacingPriority(stale))
    }

    @Test func proactivePromptStatesTheDateItIsReasoningFrom() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let prompt = IntelligencePrompts.proactive(for: digest, now: now)

        #expect(prompt.contains(ISO8601DateFormatter().string(from: now)))
    }

    @Test func historyIsCappedToTheMostRecentMessagesNotTheOldest() {
        // Newest first, matching `ContextRetrievalEngine.assemblePayload`'s
        // actual output order: "Message number 29." is the most recent.
        let messages = Array((0 ..< 30).map { index in
            MessageSnapshot(
                messageID: UUID(),
                role: MessageRole.user.rawValue,
                content: "Message number \(index).",
                estimatedTokens: 4,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }.reversed())
        let transcript = IntelligencePrompts.transcript(of: messages)

        #expect(transcript.contains("Message number 29."))
        #expect(transcript.contains("Message number \(30 - IntelligencePrompts.maximumDigestMessages)."))
        #expect(transcript.contains("Message number \(30 - IntelligencePrompts.maximumDigestMessages - 1).") == false)
    }

    @Test func transcriptReplaysTheKeptMessagesOldestFirst() {
        // Input newest first; output should read chronologically.
        let messages = [
            MessageSnapshot(
                messageID: UUID(),
                role: MessageRole.assistant.rawValue,
                content: "Second.",
                estimatedTokens: 4,
                createdAt: Date(timeIntervalSince1970: 2)
            ),
            MessageSnapshot(
                messageID: UUID(),
                role: MessageRole.user.rawValue,
                content: "First.",
                estimatedTokens: 4,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
        ]
        let transcript = IntelligencePrompts.transcript(of: messages)

        let first = try? #require(transcript.range(of: "First."))
        let second = try? #require(transcript.range(of: "Second."))
        #expect(first != nil && second != nil)
        if let first, let second {
            #expect(first.lowerBound < second.lowerBound)
        }
    }

    @Test func systemMessagesAreLabeledDistinctlyFromAssistantMessages() {
        let messages = [
            MessageSnapshot(
                messageID: UUID(),
                role: MessageRole.system.rawValue,
                content: "Background note.",
                estimatedTokens: 3,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
        ]
        let transcript = IntelligencePrompts.transcript(of: messages)

        #expect(transcript.contains("System: Background note."))
        #expect(transcript.contains("Assistant: Background note.") == false)
    }

    @Test func extractionPromptLabelsSupersededExistingContext() {
        let exchange = ConversationExchange(
            workstreamTitle: "Ledger migration",
            userMessage: "Should we move the ledger to Postgres?",
            assistantMessage: "Given the write volume, yes.",
            existingContext: [
                ContextFragment(
                    content: "The ledger stays on SQLite.",
                    nodeType: ContextNodeType.decision.rawValue,
                    isSuperseded: true
                ),
            ]
        )
        let prompt = IntelligencePrompts.extraction(for: exchange)

        #expect(prompt.contains("(superseded)"))
    }

    @Test func taggingPromptCarriesTheTextVerbatim() {
        #expect(IntelligencePrompts.tagging(for: "Ship the migration by Friday.").contains("Ship the migration by Friday."))
    }

    @Test func clipTruncatesWithAnEllipsisOnlyWhenOverTheLimit() {
        #expect(IntelligencePrompts.clip("short", to: 20) == "short")
        #expect(IntelligencePrompts.clip("  padded  ", to: 20) == "padded")

        let clipped = IntelligencePrompts.clip(String(repeating: "x", count: 50), to: 10)
        #expect(clipped == String(repeating: "x", count: 10) + "…")
    }

    @Test func longFieldsAreClippedBeforeReachingThePrompt() {
        let essay = String(repeating: "context ", count: 500)
        let prompt = IntelligencePrompts.extraction(
            for: ConversationExchange(
                workstreamTitle: "Long",
                userMessage: essay,
                assistantMessage: essay
            )
        )

        #expect(essay.count > IntelligencePrompts.maximumFieldCharacters)
        #expect(prompt.count < essay.count)
        #expect(prompt.contains("…"))
    }
}

// MARK: - Per-task mutex
//
// Exercises `acquireLock`/`releaseLock` directly rather than through
// `extractContext` et al., since those need a model the simulator does not
// have. This is the primitive `generate` relies on to stay correct under
// actor reentrancy, so it is testable without one.

@Suite struct OnDeviceIntelligenceLockingTests {

    private actor Recorder {
        private var current = 0
        private(set) var maxConcurrent = 0

        func enter() {
            current += 1
            maxConcurrent = max(maxConcurrent, current)
        }

        func exit() {
            current -= 1
        }
    }

    @Test func concurrentCallsForTheSameTaskNeverOverlap() async {
        let intelligence = OnDeviceIntelligence()
        let recorder = Recorder()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    await intelligence.acquireLock(for: .extraction)
                    await recorder.enter()
                    try? await Task.sleep(nanoseconds: 2_000_000)
                    await recorder.exit()
                    await intelligence.releaseLock(for: .extraction)
                }
            }
        }

        #expect(await recorder.maxConcurrent == 1)
    }

    @Test func locksForDifferentTasksAreIndependent() async {
        let intelligence = OnDeviceIntelligence()
        let recorder = Recorder()

        await withTaskGroup(of: Void.self) { group in
            for task in OnDeviceIntelligence.Task.allCases {
                group.addTask {
                    await intelligence.acquireLock(for: task)
                    await recorder.enter()
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    await recorder.exit()
                    await intelligence.releaseLock(for: task)
                }
            }
        }

        #expect(await recorder.maxConcurrent == OnDeviceIntelligence.Task.allCases.count)
    }
}

// MARK: - Generable defaults

@Suite struct GenerableResultDefaultsTests {

    @Test func proactiveAnalysisDefaultsToNotSurfacing() {
        let analysis = ProactiveAnalysis()

        #expect(analysis.shouldSurface == false)
        #expect(analysis.content.isEmpty)
        #expect(analysis.confidence == 0)
    }

    @Test func emptyResultsAreRepresentableWithoutOptionals() {
        // "Nothing found" is spelled as an empty collection throughout, because
        // Optional is not a Generable property type.
        #expect(ExtractedContext().items.isEmpty)
        #expect(ContentTags().topics.isEmpty)
        #expect(WorkstreamSummary().activeDecisions.isEmpty)
    }
}
