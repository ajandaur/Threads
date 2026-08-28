//
//  LLMProviderTests.swift
//  ThreadsTests
//

import Foundation
import Testing
@testable import Threads

// MARK: - Test doubles

private nonisolated enum StubError: Error, Equatable {
    case boom
    case offline
}

/// Counts calls across `await` boundaries so a test can assert that something
/// was probed *once*, not merely that it answered the same way twice.
private actor CallCounter {
    private(set) var count = 0

    func record() { count += 1 }
}

/// Deterministic `LLMStreamingProvider`: emits a fixed chunk list, then either
/// finishes or throws. Replaces both the network and Foundation Models so the
/// factory's routing can be asserted without either.
private nonisolated struct StubProvider: LLMStreamingProvider {
    let identifier: String
    let available: Bool
    let chunks: [LLMStreamChunk]
    let failure: StubError?
    let availabilityProbes: CallCounter?

    init(
        identifier: String,
        available: Bool = true,
        chunks: [LLMStreamChunk] = [],
        failure: StubError? = nil,
        availabilityProbes: CallCounter? = nil
    ) {
        self.identifier = identifier
        self.available = available
        self.chunks = chunks
        self.failure = failure
        self.availabilityProbes = availabilityProbes
    }

    func isAvailable() async -> Bool {
        await availabilityProbes?.record()
        return available
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.finish()
            }
        }
    }
}

private func collect(
    _ stream: AsyncThrowingStream<LLMStreamChunk, any Error>
) async throws -> [LLMStreamChunk] {
    var chunks: [LLMStreamChunk] = []
    for try await chunk in stream {
        chunks.append(chunk)
    }
    return chunks
}

/// Drives the parser over a whole canned stream the way the provider does.
private func parse(_ lines: [String], identifier: String = "claude") throws -> [LLMStreamChunk] {
    var parser = ClaudeSSEParser(providerIdentifier: identifier)
    var chunks: [LLMStreamChunk] = []
    for line in lines {
        if let chunk = try parser.consume(line) {
            chunks.append(chunk)
        }
        if parser.didComplete { break }
    }
    try parser.finish()
    return chunks
}

private let textStreamLines = [
    "event: message_start",
    #"data: {"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","model":"claude-opus-5","usage":{"input_tokens":412,"output_tokens":1}}}"#,
    "",
    "event: content_block_start",
    #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
    "",
    "event: ping",
    #"data: {"type":"ping"}"#,
    "",
    "event: content_block_delta",
    #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"The retrieval "}}"#,
    "",
    "event: content_block_delta",
    #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"eval is frozen."}}"#,
    "",
    "event: content_block_stop",
    #"data: {"type":"content_block_stop","index":0}"#,
    "",
    "event: message_delta",
    #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":57}}"#,
    "",
    "event: message_stop",
    #"data: {"type":"message_stop"}"#,
    "",
]

// MARK: - SSE parsing

@Suite struct ClaudeSSEParserTests {

    @Test func fullTextStreamProducesDeltasThenCompletion() throws {
        let chunks = try parse(textStreamLines)

        #expect(chunks == [
            .text("The retrieval "),
            .text("eval is frozen."),
            .done(
                LLMCompletion(
                    providerIdentifier: "claude",
                    stopReason: "end_turn",
                    inputTokens: 412,
                    outputTokens: 57
                )
            ),
        ])
    }

    @Test func thinkingDeltasAreSeparateFromText() throws {
        let chunks = try parse([
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Weighing decay."}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc123"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Use 0.25."}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}"#,
            #"data: {"type":"message_stop"}"#,
        ])

        #expect(chunks.count == 3)
        #expect(chunks[0] == .thinking("Weighing decay."))
        #expect(chunks[1] == .text("Use 0.25."))
        guard case .done(let completion) = chunks[2] else {
            Issue.record("expected a completion chunk, got \(chunks[2])")
            return
        }
        #expect(completion.stopReason == "end_turn")
        #expect(completion.outputTokens == 9)
    }

    @Test func errorEventThrowsRatherThanFinishing() {
        #expect(throws: LLMProviderError.apiError(type: "overloaded_error", message: "Overloaded")) {
            try parse([
                #"data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}"#,
                "event: error",
                #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
            ])
        }
    }

    /// A dropped connection looks exactly like a stream that stops early. It
    /// must not read as a complete-but-short answer.
    @Test func streamEndingBeforeMessageStopIsTruncated() {
        #expect(throws: LLMProviderError.truncatedStream) {
            try parse([
                #"data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}"#,
                #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#,
                #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Half a "}}"#,
            ])
        }
    }

    /// Forward compatibility: an event type this parser has never seen must not
    /// kill a response that is otherwise fine.
    @Test func unknownEventsAndFramingAreIgnored() throws {
        let chunks = try parse([
            ": this is an SSE comment",
            "",
            "event: something_new",
            #"data: {"type":"something_new","payload":{"whatever":true}}"#,
            "",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"a\":"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}"#,
            #"data: {"type":"message_stop"}"#,
        ])

        #expect(chunks.count == 2)
        #expect(chunks[0] == .text("ok"))
    }

    @Test func undecodableDataLineThrows() {
        var parser = ClaudeSSEParser(providerIdentifier: "claude")
        #expect(throws: LLMProviderError.self) {
            _ = try parser.consume("data: {not json at all")
        }
    }

    @Test func dataPayloadToleratesBothSpacingForms() {
        #expect(ClaudeSSEParser.dataPayload(of: #"data: {"type":"ping"}"#) == #"{"type":"ping"}"#)
        #expect(ClaudeSSEParser.dataPayload(of: #"data:{"type":"ping"}"#) == #"{"type":"ping"}"#)
        #expect(ClaudeSSEParser.dataPayload(of: "event: ping") == nil)
        #expect(ClaudeSSEParser.dataPayload(of: "") == nil)
        #expect(ClaudeSSEParser.dataPayload(of: "data: ") == nil)
    }

    /// Nothing follows `message_stop`, so the parser must report completion and
    /// let the provider stop reading the socket.
    @Test func completionIsFlaggedAtMessageStop() throws {
        var parser = ClaudeSSEParser(providerIdentifier: "claude")
        #expect(parser.didComplete == false)
        _ = try parser.consume(#"data: {"type":"message_stop"}"#)
        #expect(parser.didComplete == true)
        try parser.finish()
    }
}

// MARK: - Request shape

@Suite struct ClaudeRequestTests {

    private let request = LLMRequest(
        systemPrompt: "Workstream: eval tuning.",
        messages: [
            LLMMessage(role: .user, content: "What did we settle on?"),
            LLMMessage(role: .assistant, content: "decayStrength 0.25."),
            LLMMessage(role: .user, content: "Why not 0.20?"),
        ]
    )

    private func encodedBody(
        _ configuration: ClaudeConfiguration = ClaudeConfiguration(),
        request: LLMRequest
    ) throws -> [String: Any] {
        let provider = ClaudeSSEProvider(configuration: configuration, apiKey: "sk-test")
        let data = try JSONEncoder().encode(provider.body(for: request))
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    @Test func bodyCarriesModelBudgetAndStreamingFlag() throws {
        let body = try encodedBody(request: request)

        #expect(body["model"] as? String == "claude-opus-5")
        #expect(body["max_tokens"] as? Int == 64_000)
        #expect(body["stream"] as? Bool == true)
        // Sampling parameters are rejected on Opus 5 — they must not be sent.
        #expect(body["temperature"] == nil)
        #expect(body["top_p"] == nil)
    }

    @Test func systemPromptAndHistoryAreEncodedInOrder() throws {
        let body = try encodedBody(request: request)

        #expect(body["system"] as? String == "Workstream: eval tuning.")

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        #expect(messages.last?["content"] as? String == "Why not 0.20?")
    }

    @Test func emptySystemPromptIsOmittedRatherThanSentBlank() throws {
        let body = try encodedBody(
            request: LLMRequest(
                systemPrompt: "   \n ",
                messages: [LLMMessage(role: .user, content: "Hi")]
            )
        )
        #expect(body["system"] == nil)
    }

    @Test func thinkingDefaultsToAdaptiveWithSummaries() throws {
        let body = try encodedBody(request: request)
        let thinking = try #require(body["thinking"] as? [String: Any])

        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["display"] as? String == "summarized")
        // `budget_tokens` is rejected on Opus 5.
        #expect(thinking["budget_tokens"] == nil)
        // No effort configured means no `output_config`; the API defaults to high.
        #expect(body["output_config"] == nil)
    }

    /// `.unspecified` sends no `thinking` key. Note what this does *not* mean:
    /// thinking is on by default on Opus 5, so the model still thinks — the
    /// case is named for the wire, not for an effect it cannot deliver.
    @Test func unspecifiedThinkingOmitsTheParameterEntirely() throws {
        var configuration = ClaudeConfiguration()
        configuration.thinking = .unspecified
        configuration.effort = .xhigh

        let body = try encodedBody(configuration, request: request)

        #expect(body["thinking"] == nil)
        let outputConfig = try #require(body["output_config"] as? [String: Any])
        #expect(outputConfig["effort"] as? String == "xhigh")
    }

    @Test func urlRequestCarriesAuthAndVersionHeaders() throws {
        let provider = ClaudeSSEProvider(apiKey: "sk-ant-test")
        let urlRequest = try provider.makeURLRequest(for: request, apiKey: "sk-ant-test")

        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(urlRequest.httpBody?.isEmpty == false)
    }

    @Test func emptyMessageListIsRejectedBeforeAnyNetworkCall() {
        let provider = ClaudeSSEProvider(apiKey: "sk-ant-test")
        #expect(throws: LLMProviderError.invalidRequest("no messages")) {
            _ = try provider.makeURLRequest(for: LLMRequest(messages: []), apiKey: "sk-ant-test")
        }
    }
}

// MARK: - API key resolution

@Suite struct APIKeyStoreTests {

    @Test func environmentVariableIsPreferred() {
        let key = APIKeyStore.resolve(
            environment: ["ANTHROPIC_API_KEY": "  sk-from-env  "],
            bundle: .main
        )
        #expect(key == "sk-from-env")
    }

    /// An Info.plist entry of `$(ANTHROPIC_API_KEY)` with no `.xcconfig` behind
    /// it arrives verbatim. Sending it would produce a 401 that reads like a bad
    /// key rather than a missing one.
    @Test func unsubstitutedBuildSettingPlaceholdersAreRejected() {
        #expect(APIKeyStore.sanitize("$(ANTHROPIC_API_KEY)") == nil)
        #expect(APIKeyStore.sanitize("${ANTHROPIC_API_KEY}") == nil)
        #expect(APIKeyStore.sanitize("   ") == nil)
        #expect(APIKeyStore.sanitize("") == nil)
        #expect(APIKeyStore.sanitize(nil) == nil)
        #expect(APIKeyStore.sanitize(" sk-ant-real ") == "sk-ant-real")
    }

    /// An explicit key must win outright, *including when it is invalid*.
    /// Falling through to the ambient environment here would make the test
    /// below depend on whether the developer set `ANTHROPIC_API_KEY` in the
    /// scheme — which this file's own header tells them to do — and would send
    /// a real request from a unit test when they had.
    @Test func explicitPlaceholderKeyDoesNotFallThroughToTheEnvironment() {
        let resolved = APIKeyStore.resolve(
            explicit: "$(ANTHROPIC_API_KEY)",
            environment: ["ANTHROPIC_API_KEY": "sk-ant-live-key"],
            bundle: .main
        )
        #expect(resolved == nil)

        // A `nil` explicit key still resolves from the ambient sources.
        #expect(
            APIKeyStore.resolve(
                explicit: nil,
                environment: ["ANTHROPIC_API_KEY": "sk-ant-live-key"],
                bundle: .main
            ) == "sk-ant-live-key"
        )
    }

    @Test func providerWithoutAKeyReportsUnavailableAndFailsFast() async throws {
        let provider = ClaudeSSEProvider(apiKey: "$(ANTHROPIC_API_KEY)")
        #expect(provider.hasAPIKey == false)
        #expect(await provider.isAvailable() == false)

        await #expect(throws: LLMProviderError.missingAPIKey) {
            _ = try await collect(
                provider.stream(LLMRequest(messages: [LLMMessage(role: .user, content: "Hi")]))
            )
        }
    }
}

// MARK: - Factory routing and fallback

@Suite struct LLMProviderFactoryTests {

    private let request = LLMRequest(
        systemPrompt: "context",
        messages: [LLMMessage(role: .user, content: "Where did we land on decay?")]
    )

    private func makeFactory(
        primary: StubProvider,
        fallback: StubProvider,
        networkAvailable: Bool = true
    ) -> LLMProviderFactory {
        LLMProviderFactory(
            primary: primary,
            fallback: fallback,
            reachability: StaticReachability(available: networkAvailable)
        )
    }

    @Test func healthyPrimaryAnswersAndFallbackIsNeverTouched() async throws {
        let factory = makeFactory(
            primary: StubProvider(
                identifier: "claude",
                chunks: [
                    .text("0.25"),
                    .done(LLMCompletion(providerIdentifier: "claude", stopReason: "end_turn")),
                ]
            ),
            fallback: StubProvider(
                identifier: "on-device",
                chunks: [.text("on-device answer")]
            )
        )

        let chunks = try await collect(factory.stream(request))

        #expect(chunks.count == 2)
        #expect(chunks[0] == .text("0.25"))
        guard case .done(let completion) = chunks[1] else {
            Issue.record("expected a completion chunk, got \(chunks[1])")
            return
        }
        #expect(completion.providerIdentifier == "claude")
        #expect(await factory.activeProviderIdentifier() == "claude")
    }

    @Test func unavailablePrimaryRoutesStraightToTheFallback() async throws {
        let factory = makeFactory(
            primary: StubProvider(identifier: "claude", available: false, chunks: [.text("never")]),
            fallback: StubProvider(
                identifier: "on-device",
                chunks: [
                    .text("local answer"),
                    .done(LLMCompletion(providerIdentifier: "on-device", stopReason: "end_turn")),
                ]
            )
        )

        let chunks = try await collect(factory.stream(request))

        #expect(chunks.first == .text("local answer"))
        guard case .done(let completion) = try #require(chunks.last) else {
            Issue.record("expected a completion chunk")
            return
        }
        #expect(completion.providerIdentifier == "on-device")
        #expect(await factory.activeProviderIdentifier() == "on-device")
    }

    @Test func offlineNetworkRoutesToTheFallbackEvenWithAKey() async throws {
        let factory = makeFactory(
            primary: StubProvider(identifier: "claude", available: true, chunks: [.text("never")]),
            fallback: StubProvider(identifier: "on-device", chunks: [.text("local answer")]),
            networkAvailable: false
        )

        let chunks = try await collect(factory.stream(request))

        #expect(chunks == [.text("local answer")])
        #expect(await factory.activeProviderIdentifier() == "on-device")
    }

    /// The contract's "no user-visible error state for the fallback case
    /// itself": the primary dies before any text, and the caller sees one
    /// clean response.
    @Test func primaryFailingBeforeAnyTextFallsBackSilently() async throws {
        let factory = makeFactory(
            primary: StubProvider(identifier: "claude", failure: .boom),
            fallback: StubProvider(
                identifier: "on-device",
                chunks: [
                    .text("local answer"),
                    .done(LLMCompletion(providerIdentifier: "on-device", stopReason: "end_turn")),
                ]
            )
        )

        let chunks = try await collect(factory.stream(request))

        #expect(chunks.count == 2)
        #expect(chunks[0] == .text("local answer"))
    }

    /// Thinking is ancillary, so abandoning it costs nothing — the handoff must
    /// still be silent.
    @Test func primaryFailingAfterOnlyThinkingStillFallsBack() async throws {
        let factory = makeFactory(
            primary: StubProvider(
                identifier: "claude",
                chunks: [.thinking("considering...")],
                failure: .boom
            ),
            fallback: StubProvider(identifier: "on-device", chunks: [.text("local answer")])
        )

        let chunks = try await collect(factory.stream(request))

        #expect(chunks == [.thinking("considering..."), .text("local answer")])
    }

    /// Restarting mid-answer would either duplicate visible text or discard it.
    /// The error surfaces instead, with the partial text already delivered.
    @Test func primaryFailingAfterTextPropagatesInsteadOfRestarting() async throws {
        let factory = makeFactory(
            primary: StubProvider(
                identifier: "claude",
                chunks: [.text("We landed on ")],
                failure: .boom
            ),
            fallback: StubProvider(identifier: "on-device", chunks: [.text("local answer")])
        )

        var received: [LLMStreamChunk] = []
        var thrown: (any Error)?
        do {
            for try await chunk in factory.stream(request) {
                received.append(chunk)
            }
        } catch {
            thrown = error
        }

        #expect(received == [.text("We landed on ")])
        #expect(thrown as? StubError == .boom)
    }

    @Test func bothProvidersFailingReportsBothCauses() async throws {
        let factory = makeFactory(
            primary: StubProvider(identifier: "claude", failure: .boom),
            fallback: StubProvider(identifier: "on-device", failure: .offline)
        )

        var thrown: (any Error)?
        do {
            _ = try await collect(factory.stream(request))
        } catch {
            thrown = error
        }

        guard case .allProvidersFailed(let primary, let fallback) = try #require(
            thrown as? LLMProviderError
        ) else {
            Issue.record("expected allProvidersFailed, got \(String(describing: thrown))")
            return
        }
        #expect(primary.contains("boom"))
        #expect(fallback.contains("offline"))
    }

    @Test func fallbackAvailabilityIsProbedOnlyOnce() async {
        let probes = CallCounter()
        let factory = makeFactory(
            primary: StubProvider(identifier: "claude"),
            fallback: StubProvider(
                identifier: "on-device",
                available: true,
                availabilityProbes: probes
            )
        )

        #expect(await factory.isFallbackAvailable() == true)
        #expect(await factory.isFallbackAvailable() == true)
        // The assertion that actually pins caching: without it, both calls
        // above pass whether or not the value was cached.
        #expect(await probes.count == 1)
    }

    /// A refusal is an HTTP 200 with `stop_reason: "refusal"` and no text, not
    /// an error — so without special handling it would surface as a valid but
    /// empty answer and the fallback would never run.
    @Test func refusalWithNoTextFallsBackAndYieldsOneCompletion() async throws {
        let factory = makeFactory(
            primary: StubProvider(
                identifier: "claude",
                chunks: [
                    .done(LLMCompletion(providerIdentifier: "claude", stopReason: "refusal")),
                ]
            ),
            fallback: StubProvider(
                identifier: "on-device",
                chunks: [
                    .text("local answer"),
                    .done(LLMCompletion(providerIdentifier: "on-device", stopReason: "end_turn")),
                ]
            )
        )

        let chunks = try await collect(factory.stream(request))

        // The refused completion must not reach the caller — one response, one
        // terminal chunk.
        #expect(chunks == [
            .text("local answer"),
            .done(LLMCompletion(providerIdentifier: "on-device", stopReason: "end_turn")),
        ])
    }

    /// Once text is out, restarting would duplicate or discard it — the same
    /// rule that governs an error mid-answer.
    @Test func refusalAfterTextIsDeliveredRatherThanRetried() async throws {
        let refused = LLMCompletion(providerIdentifier: "claude", stopReason: "refusal")
        let factory = makeFactory(
            primary: StubProvider(
                identifier: "claude",
                chunks: [.text("I can help with "), .done(refused)]
            ),
            fallback: StubProvider(identifier: "on-device", chunks: [.text("never")])
        )

        let chunks = try await collect(factory.stream(request))

        #expect(chunks == [.text("I can help with "), .done(refused)])
    }

    /// Nothing is left to fall back to, so the refusal is the answer.
    @Test func refusalFromTheFallbackIsDeliveredNotConvertedToAFailure() async throws {
        let refused = LLMCompletion(providerIdentifier: "on-device", stopReason: "refusal")
        let factory = makeFactory(
            primary: StubProvider(identifier: "claude", available: false),
            fallback: StubProvider(identifier: "on-device", chunks: [.done(refused)])
        )

        let chunks = try await collect(factory.stream(request))

        #expect(chunks == [.done(refused)])
    }

    /// A missing key and a dead connection are different diagnoses, and the
    /// error type exists to preserve the real cause.
    @Test func skippedPrimaryReportsWhyItWasSkipped() async throws {
        func primaryCause(available: Bool, networkAvailable: Bool) async -> String {
            let factory = makeFactory(
                primary: StubProvider(identifier: "claude", available: available),
                fallback: StubProvider(identifier: "on-device", failure: .offline),
                networkAvailable: networkAvailable
            )
            do {
                _ = try await collect(factory.stream(request))
                return "unexpectedly succeeded"
            } catch let error as LLMProviderError {
                guard case .allProvidersFailed(let primary, _) = error else {
                    return "unexpected error \(error)"
                }
                return primary
            } catch {
                return "unexpected error \(error)"
            }
        }

        #expect(await primaryCause(available: false, networkAvailable: true)
            .contains("providerUnavailable"))
        #expect(await primaryCause(available: true, networkAvailable: false)
            .contains("networkUnavailable"))
    }
}

// MARK: - On-device provider

@Suite struct OnDeviceFallbackProviderTests {

    /// Foundation Models seeds history through `Transcript`, not a message
    /// array, so prior turns are flattened into the prompt. A single-turn
    /// request must stay unadorned.
    @Test func singleTurnPromptIsThePlainMessage() {
        let prompt = OnDeviceFallbackProvider.prompt(
            for: LLMRequest(
                systemPrompt: "ignored here — goes to instructions",
                messages: [LLMMessage(role: .user, content: "Why 0.25?")]
            )
        )
        #expect(prompt == "Why 0.25?")
    }

    @Test func multiTurnPromptFlattensHistoryAndIsolatesTheCurrentTurn() {
        let prompt = OnDeviceFallbackProvider.prompt(
            for: LLMRequest(
                messages: [
                    LLMMessage(role: .user, content: "What is decayStrength?"),
                    LLMMessage(role: .assistant, content: "A bound on decay's authority."),
                    LLMMessage(role: .user, content: "Why 0.25?"),
                ]
            )
        )

        #expect(prompt.contains("User: What is decayStrength?"))
        #expect(prompt.contains("Assistant: A bound on decay's authority."))
        #expect(prompt.hasSuffix("Why 0.25?"))
        // The current turn appears once, under the instruction — not also in
        // the flattened history.
        #expect(prompt.contains("User: Why 0.25?") == false)
    }

    @Test func emptyRequestProducesAnEmptyPrompt() {
        #expect(OnDeviceFallbackProvider.prompt(for: LLMRequest(messages: [])).isEmpty)
    }

    // MARK: Cumulative snapshots -> delta contract

    @Test func growingSnapshotYieldsOnlyTheNewSuffix() {
        #expect(
            OnDeviceFallbackProvider.transition(from: "The answer ", to: "The answer is 0.25")
                == .text("is 0.25")
        )
    }

    @Test func unchangedSnapshotYieldsNothing() {
        #expect(OnDeviceFallbackProvider.transition(from: "same", to: "same") == nil)
        #expect(OnDeviceFallbackProvider.transition(from: "", to: "") == nil)
    }

    @Test func firstSnapshotIsAPlainDelta() {
        #expect(OnDeviceFallbackProvider.transition(from: "", to: "Hello") == .text("Hello"))
    }

    /// The case that motivates `.replace`: guardrails or a retry rewrite an
    /// in-flight snapshot so it is no longer an extension of what was shown.
    /// Emitting the new content as a *delta* would leave the caller displaying
    /// the abandoned prefix followed by the replacement.
    @Test func rewrittenSnapshotReplacesRatherThanAppends() {
        #expect(
            OnDeviceFallbackProvider.transition(from: "The answer is 0.2", to: "Actually, 0.25")
                == .replace("Actually, 0.25")
        )
    }

    /// Appending every chunk in order must reconstruct the final snapshot, for
    /// both the growing and the rewritten path.
    @Test func replayingChunksReconstructsTheFinalSnapshot() {
        func replay(_ snapshots: [String]) -> String {
            var emitted = ""
            var rendered = ""
            for snapshot in snapshots {
                switch OnDeviceFallbackProvider.transition(from: emitted, to: snapshot) {
                case .text(let delta): rendered += delta
                case .replace(let content): rendered = content
                case .none: break
                default: Issue.record("unexpected chunk kind")
                }
                emitted = snapshot
            }
            return rendered
        }

        #expect(replay(["The", "The answer", "The answer is 0.25"]) == "The answer is 0.25")
        #expect(replay(["The answer is 0.2", "Actually, 0.25"]) == "Actually, 0.25")
        #expect(replay([]) == "")
    }
}

// MARK: - Claude provider over a stubbed transport

/// Replays a canned SSE body through `URLSession` so the provider's HTTP and
/// byte-stream handling is exercised without a network.
///
/// The canned response travels in the session's additional headers rather than
/// in static state, which keeps the stub safe under parallel test execution.
private final class StubSSEProtocol: URLProtocol {
    static let bodyHeader = "X-Stub-Body"
    static let statusHeader = "X-Stub-Status"

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: bodyHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let status = request.value(forHTTPHeaderField: Self.statusHeader).flatMap(Int.init) ?? 200
        let body = request.value(forHTTPHeaderField: Self.bodyHeader)
            .flatMap { Data(base64Encoded: $0) } ?? Data()
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubbedProvider(status: Int = 200, body: String) -> ClaudeSSEProvider {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubSSEProtocol.self]
    configuration.httpAdditionalHeaders = [
        StubSSEProtocol.bodyHeader: Data(body.utf8).base64EncodedString(),
        StubSSEProtocol.statusHeader: String(status),
    ]
    return ClaudeSSEProvider(
        apiKey: "sk-ant-test",
        session: URLSession(configuration: configuration)
    )
}

@Suite struct ClaudeSSEProviderTransportTests {

    private let request = LLMRequest(
        systemPrompt: "context",
        messages: [LLMMessage(role: .user, content: "Where did we land on decay?")]
    )

    @Test func streamsDeltasAndCompletionOverHTTP() async throws {
        let provider = stubbedProvider(body: textStreamLines.joined(separator: "\n"))

        let chunks = try await collect(provider.stream(request))

        #expect(chunks == [
            .text("The retrieval "),
            .text("eval is frozen."),
            .done(
                LLMCompletion(
                    providerIdentifier: "claude",
                    stopReason: "end_turn",
                    inputTokens: 412,
                    outputTokens: 57
                )
            ),
        ])
    }

    /// The error body is the useful part of a 4xx — it must survive into the
    /// thrown error rather than being dropped with the byte stream.
    @Test func nonSuccessStatusCarriesTheResponseBody() async throws {
        let provider = stubbedProvider(
            status: 429,
            body: #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#
        )

        var thrown: (any Error)?
        do {
            _ = try await collect(provider.stream(request))
        } catch {
            thrown = error
        }

        guard case .httpStatus(let code, let body) = try #require(thrown as? LLMProviderError) else {
            Issue.record("expected httpStatus, got \(String(describing: thrown))")
            return
        }
        #expect(code == 429)
        #expect(body.contains("rate_limit_error"))
        #expect(body.contains("slow down"))
    }

    /// A dropped connection reaches the provider as a byte stream that simply
    /// stops. It must not read as a complete-but-short answer.
    @Test func streamCutShortOfMessageStopThrows() async throws {
        let provider = stubbedProvider(
            body: [
                #"data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}"#,
                #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Half a "}}"#,
            ].joined(separator: "\n")
        )

        var received: [LLMStreamChunk] = []
        var thrown: (any Error)?
        do {
            for try await chunk in provider.stream(request) {
                received.append(chunk)
            }
        } catch {
            thrown = error
        }

        // The partial text still reaches the caller; the error follows it.
        #expect(received == [.text("Half a ")])
        #expect(thrown as? LLMProviderError == .truncatedStream)
    }

    @Test func errorEventInATwoHundredStreamSurfacesAsAPIError() async throws {
        let provider = stubbedProvider(
            body: [
                #"data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}"#,
                #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
            ].joined(separator: "\n")
        )

        await #expect(throws: LLMProviderError.apiError(type: "overloaded_error", message: "Overloaded")) {
            _ = try await collect(provider.stream(request))
        }
    }

    /// A refusal is a *successful* stream. The provider passes it through
    /// unchanged; deciding what it means is the factory's job.
    @Test func refusalIsReportedAsACompletionNotAnError() async throws {
        let provider = stubbedProvider(
            body: [
                #"data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}"#,
                #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":3}}"#,
                #"data: {"type":"message_stop"}"#,
            ].joined(separator: "\n")
        )

        let chunks = try await collect(provider.stream(request))

        #expect(chunks == [
            .done(
                LLMCompletion(
                    providerIdentifier: "claude",
                    stopReason: "refusal",
                    inputTokens: 10,
                    outputTokens: 3
                )
            ),
        ])
    }
}
