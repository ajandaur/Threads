//
//  LLMProvider.swift
//  Threads
//
//  Layer 3 of the architecture: streaming LLM responses behind a provider
//  protocol, with automatic fallback to the on-device model.
//
//  ## API key
//
//  No key is committed. `APIKeyStore.resolve()` looks, in order, at:
//
//  1. The `ANTHROPIC_API_KEY` environment variable — set it in the scheme's
//     Run/Test arguments (Product ▸ Scheme ▸ Edit Scheme ▸ Environment
//     Variables). This is the simulator/test path and touches no file.
//  2. `ANTHROPIC_API_KEY` in the app's Info.plist — for device builds, set it
//     to `$(ANTHROPIC_API_KEY)` in the target's Info.plist and define the real
//     value in a gitignored `.xcconfig`. An unsubstituted `$(...)` value is
//     rejected rather than sent as a key.
//  3. `ANTHROPIC_API_KEY` in a bundled `Secrets.plist` — gitignored.
//
//  With no key resolvable, `ClaudeSSEProvider.isAvailable()` returns false and
//  `LLMProviderFactory` routes every request to the on-device provider.
//

import Foundation
import FoundationModels
import Network

// MARK: - Wire types
//
// Explicitly `nonisolated`: the app target defaults to MainActor isolation
// (`SWIFT_DEFAULT_ACTOR_ISOLATION`), and providers must be callable from any
// isolation domain — background extraction, the orchestrator, tests.

nonisolated enum LLMRole: String, Sendable, Codable, CaseIterable {
    case user, assistant
}

nonisolated struct LLMMessage: Sendable, Equatable {
    let role: LLMRole
    let content: String

    init(role: LLMRole, content: String) {
        self.role = role
        self.content = content
    }
}

/// What a provider is asked to answer. The system prompt is the assembled
/// context payload (workstream summary + relevant nodes); `messages` is the
/// token-budgeted conversation history, oldest first, ending with the user's
/// current turn. Model, token ceiling, and thinking configuration belong to the
/// provider, not the request — that is what makes a request replayable against
/// any provider.
nonisolated struct LLMRequest: Sendable, Equatable {
    var systemPrompt: String
    var messages: [LLMMessage]

    init(systemPrompt: String = "", messages: [LLMMessage]) {
        self.systemPrompt = systemPrompt
        self.messages = messages
    }
}

/// Terminal metadata for a completed stream. Token counts are absent on the
/// on-device provider, which does not report usage.
nonisolated struct LLMCompletion: Sendable, Equatable {
    let providerIdentifier: String
    let stopReason: String?
    let inputTokens: Int?
    let outputTokens: Int?

    init(
        providerIdentifier: String,
        stopReason: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) {
        self.providerIdentifier = providerIdentifier
        self.stopReason = stopReason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// Incremental output. `.text` and `.thinking` carry *deltas*, never cumulative
/// snapshots — callers append. `.done` arrives exactly once, last, before the
/// stream finishes normally; a stream that throws emits no `.done`.
nonisolated enum LLMStreamChunk: Sendable, Equatable {
    case text(String)
    case thinking(String)
    /// The full visible answer so far, *replacing* everything `.text` has
    /// delivered for this response rather than extending it. Exists because a
    /// provider that streams cumulative snapshots (Foundation Models) can
    /// rewrite one mid-flight, and a delta-only contract can represent that
    /// only by corrupting the transcript. Rare — the network provider never
    /// emits it.
    case replace(String)
    case done(LLMCompletion)
}

// MARK: - Errors

nonisolated enum LLMProviderError: Error, Equatable, LocalizedError {
    case missingAPIKey
    case invalidRequest(String)
    /// Non-200 from the HTTP provider, with whatever body came back.
    case httpStatus(code: Int, body: String)
    /// A well-formed `error` event inside an otherwise-200 SSE stream.
    case apiError(type: String, message: String)
    case malformedEvent(String)
    /// The stream ended without a `message_stop`.
    case truncatedStream
    case networkUnavailable
    /// The provider reported itself unavailable before it was ever called —
    /// distinct from `networkUnavailable`, which is about the connection.
    case providerUnavailable(String)
    /// A safety classifier declined the request. Arrives as an HTTP 200 whose
    /// `stop_reason` is `refusal`, not as an error, so it has to be recognised
    /// rather than caught.
    case refusedByProvider(String)
    case onDeviceModelUnavailable(reason: String)
    case onDeviceGenerationFailed(String)
    /// Both the primary and the fallback failed. Carries both descriptions so
    /// the real cause isn't lost behind the fallback's.
    case allProvidersFailed(primary: String, fallback: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Anthropic API key is configured."
        case .invalidRequest(let detail):
            return "Malformed request: \(detail)"
        case .httpStatus(let code, let body):
            return "HTTP \(code): \(body)"
        case .apiError(let type, let message):
            return "\(type): \(message)"
        case .malformedEvent(let detail):
            return "Malformed stream event: \(detail)"
        case .truncatedStream:
            return "The response stream ended before completing."
        case .networkUnavailable:
            return "The network is unavailable."
        case .providerUnavailable(let identifier):
            return "The \(identifier) provider is unavailable."
        case .refusedByProvider(let identifier):
            return "The \(identifier) provider declined the request."
        case .onDeviceModelUnavailable(let reason):
            return "The on-device model is unavailable: \(reason)"
        case .onDeviceGenerationFailed(let detail):
            return "On-device generation failed: \(detail)"
        case .allProvidersFailed(let primary, let fallback):
            return "Both providers failed. Primary: \(primary). Fallback: \(fallback)."
        }
    }
}

// MARK: - LLMStreamingProvider

/// The seam that makes providers swappable: the orchestrator holds one of
/// these and never learns whether the tokens came from the network or the
/// device. Also what makes the lifecycle testable without a network.
///
/// `stream` is synchronous and non-throwing by design — a provider reports
/// setup failures *through* the returned stream, so callers have exactly one
/// error path to handle rather than two.
nonisolated protocol LLMStreamingProvider: Sendable {
    /// Stable, human-readable identity. Surfaces in `LLMCompletion` so the UI
    /// and the debug inspector can tell which provider answered.
    var identifier: String { get }

    /// Cheap pre-flight. `false` means "don't bother calling `stream`" — no
    /// key, no model assets, no network. `true` is not a promise of success.
    func isAvailable() async -> Bool

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, any Error>
}

// MARK: - API key resolution

nonisolated enum APIKeyStore {
    static let environmentKey = "ANTHROPIC_API_KEY"
    static let secretsFileName = "Secrets"

    /// Resolution when the caller supplied a key explicitly. An explicit key
    /// wins outright, *including when it is invalid* — falling through to the
    /// ambient sources here would make "pass a key explicitly" mean "pass a
    /// key, unless it's bad, in which case use whatever the process happens to
    /// have," which silently reintroduces the environment into tests that were
    /// written to exclude it.
    static func resolve(
        explicit: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> String? {
        if let explicit { return sanitize(explicit) }
        return resolve(environment: environment, bundle: bundle)
    }

    /// First non-empty source wins. Returns `nil` rather than an empty or
    /// placeholder string so callers only have to check one thing.
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> String? {
        if let key = sanitize(environment[environmentKey]) {
            return key
        }
        if let key = sanitize(bundle.object(forInfoDictionaryKey: environmentKey) as? String) {
            return key
        }
        if let url = bundle.url(forResource: secretsFileName, withExtension: "plist"),
           let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dictionary = plist as? [String: Any],
           let key = sanitize(dictionary[environmentKey] as? String) {
            return key
        }
        return nil
    }

    /// Rejects empties and unsubstituted build-setting placeholders. An
    /// Info.plist entry of `$(ANTHROPIC_API_KEY)` with no `.xcconfig` behind it
    /// reaches here verbatim; sending it as a key would produce a confusing 401
    /// instead of an honest "no key configured."
    static func sanitize(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !(trimmed.hasPrefix("$(") && trimmed.hasSuffix(")")),
              !(trimmed.hasPrefix("${") && trimmed.hasSuffix("}")) else {
            return nil
        }
        return trimmed
    }
}

// MARK: - Claude configuration

nonisolated struct ClaudeConfiguration: Sendable, Equatable {
    /// Thinking is adaptive on every current model; `budget_tokens` is rejected
    /// on Opus 5. `display` defaults to `omitted` server-side, which in a
    /// streaming UI reads as a long pause before any text — so this asks for
    /// summaries and surfaces them as `.thinking` chunks.
    enum Thinking: String, Sendable, Equatable {
        case adaptiveSummarized
        case adaptiveOmitted
        /// Sends no `thinking` parameter at all. Named for what it does on the
        /// wire, *not* "disabled": thinking is on by default on Opus 5, so
        /// omitting the parameter still yields adaptive thinking at full token
        /// cost. `{"type":"disabled"}` is rejected outright at effort `xhigh`
        /// and `max`, and at lower efforts it degrades tool and formatting
        /// behaviour — lower `effort` is the way to spend less, not this.
        case unspecified
    }

    enum Effort: String, Sendable, Equatable {
        case low, medium, high, xhigh, max
    }

    var model: String = "claude-opus-5"
    /// Streaming, so HTTP timeouts aren't the constraint — give the model room.
    var maxTokens: Int = 64_000
    var thinking: Thinking = .adaptiveSummarized
    /// `nil` sends no `output_config`, which the API treats as `high`.
    var effort: Effort?
    var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    var apiVersion = "2023-06-01"
    /// Applies to the initial response head, not the streamed body.
    var requestTimeout: TimeInterval = 30
    /// Ceiling on the whole streamed response.
    var resourceTimeout: TimeInterval = 600

    init() {}
}

// MARK: - SSE parsing

/// Line-at-a-time state machine over the Anthropic SSE stream.
///
/// Split out from `ClaudeSSEProvider` deliberately: parsing is the part that
/// can be wrong in ways a compiler won't catch, and as a synchronous `mutating`
/// consumer it is testable against canned event lines with no network, no
/// URLSession, and no async plumbing.
///
/// Only `data:` lines carry meaning — every event's JSON repeats its own type
/// in a `type` field, so the `event:` line is redundant and skipped.
nonisolated struct ClaudeSSEParser {
    private let providerIdentifier: String
    private var stopReason: String?
    private var inputTokens: Int?
    private var outputTokens: Int?
    private(set) var didComplete = false

    init(providerIdentifier: String) {
        self.providerIdentifier = providerIdentifier
    }

    /// Feeds one raw line. Returns a chunk when the line produced output,
    /// `nil` for framing (`event:`, blank lines, comments, pings, and events
    /// that only update accumulated metadata). Throws on an `error` event or
    /// undecodable payload.
    mutating func consume(_ line: String) throws -> LLMStreamChunk? {
        guard let payload = Self.dataPayload(of: line) else { return nil }
        // The API sends `data: [DONE]` on some endpoints; harmless framing here.
        guard payload != "[DONE]" else { return nil }

        guard let json = payload.data(using: .utf8) else {
            throw LLMProviderError.malformedEvent("non-UTF8 payload")
        }
        let event: SSEEvent
        do {
            event = try JSONDecoder().decode(SSEEvent.self, from: json)
        } catch {
            throw LLMProviderError.malformedEvent(payload)
        }

        switch event.type {
        case "message_start":
            inputTokens = event.message?.usage?.inputTokens
            // A resumed/fallback turn can report output tokens here too.
            outputTokens = event.message?.usage?.outputTokens ?? outputTokens
            return nil

        case "content_block_delta":
            return delta(for: event)

        case "message_delta":
            stopReason = event.delta?.stopReason ?? stopReason
            outputTokens = event.usage?.outputTokens ?? outputTokens
            return nil

        case "message_stop":
            didComplete = true
            return .done(
                LLMCompletion(
                    providerIdentifier: providerIdentifier,
                    stopReason: stopReason,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens
                )
            )

        case "error":
            throw LLMProviderError.apiError(
                type: event.error?.type ?? "api_error",
                message: event.error?.message ?? "Unknown error"
            )

        default:
            // `ping`, `content_block_start`/`_stop`, and anything the API adds
            // later. Block framing carries nothing this parser needs — deltas
            // are dispatched on their own `type`, not on the enclosing block's
            // — so tracking it would be state nothing reads. Forward
            // compatibility is the point: an unknown event must not kill a
            // live response.
            return nil
        }
    }

    /// Call once the byte stream ends. Throws if the stream stopped before
    /// `message_stop`, which is how a dropped connection presents — silently
    /// finishing there would look like a complete but truncated answer.
    func finish() throws {
        guard didComplete else { throw LLMProviderError.truncatedStream }
    }

    private func delta(for event: SSEEvent) -> LLMStreamChunk? {
        guard let delta = event.delta else { return nil }
        switch delta.type {
        case "text_delta":
            guard let text = delta.text, !text.isEmpty else { return nil }
            return .text(text)
        case "thinking_delta":
            guard let thinking = delta.thinking, !thinking.isEmpty else { return nil }
            return .thinking(thinking)
        default:
            // `signature_delta`, `input_json_delta` — nothing to render.
            return nil
        }
    }

    /// Extracts the payload of a `data:` line. SSE allows an optional single
    /// space after the colon; both forms appear in practice.
    static func dataPayload(of line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        var payload = line.dropFirst("data:".count)
        if payload.hasPrefix(" ") { payload = payload.dropFirst() }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // Decoded leniently: every field is optional because a single struct covers
    // every event type, and unknown events must decode rather than throw.
    private struct SSEEvent: Decodable {
        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }
        }

        struct Message: Decodable {
            let usage: Usage?
        }

        struct Delta: Decodable {
            let type: String?
            let text: String?
            let thinking: String?
            let stopReason: String?

            enum CodingKeys: String, CodingKey {
                case type, text, thinking
                case stopReason = "stop_reason"
            }
        }

        struct APIError: Decodable {
            let type: String?
            let message: String?
        }

        let type: String
        let message: Message?
        let delta: Delta?
        let usage: Usage?
        let error: APIError?
    }
}

// MARK: - ClaudeSSEProvider

/// The primary provider: `POST /v1/messages` with `stream: true`, consumed as
/// `URLSession.AsyncBytes`. No SDK — the Anthropic SDKs don't cover Swift, and
/// SSE over async bytes needs no dependency.
///
/// A struct rather than an actor: every stored property is an immutable value
/// (`URLSession` is `Sendable`), so there is no mutable state to protect. That
/// is the same "thread-safe by construction, no manual locking" property the
/// actor-isolation decision is after, reached without forcing callers to
/// `await` a hop that guards nothing. Providers that *do* accumulate state
/// (`LLMProviderFactory`) are actors.
nonisolated struct ClaudeSSEProvider: LLMStreamingProvider {
    let identifier = "claude"

    private let configuration: ClaudeConfiguration
    private let apiKey: String?
    private let session: URLSession

    /// - Parameter apiKey: `nil` resolves from `APIKeyStore` at init. Pass a
    ///   value explicitly only in tests or when the key comes from elsewhere.
    init(
        configuration: ClaudeConfiguration = ClaudeConfiguration(),
        apiKey: String? = nil,
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        self.apiKey = APIKeyStore.resolve(explicit: apiKey)
        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeout
            sessionConfiguration.timeoutIntervalForResource = configuration.resourceTimeout
            sessionConfiguration.waitsForConnectivity = false
            self.session = URLSession(configuration: sessionConfiguration)
        }
    }

    var hasAPIKey: Bool { apiKey != nil }

    func isAvailable() async -> Bool { hasAPIKey }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: LLMRequest,
        into continuation: AsyncThrowingStream<LLMStreamChunk, any Error>.Continuation
    ) async throws {
        guard let apiKey else { throw LLMProviderError.missingAPIKey }
        let urlRequest = try makeURLRequest(for: request, apiKey: apiKey)

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.malformedEvent("non-HTTP response")
        }
        guard http.statusCode == 200 else {
            // The error body is the useful part of a 4xx/5xx, and it arrives on
            // the same byte stream — drain it before throwing.
            throw LLMProviderError.httpStatus(
                code: http.statusCode,
                body: await Self.drain(bytes)
            )
        }

        var parser = ClaudeSSEParser(providerIdentifier: identifier)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if let chunk = try parser.consume(line) {
                continuation.yield(chunk)
            }
            if parser.didComplete { break }
        }
        try parser.finish()
    }

    /// Reads the remaining bytes as text, best-effort. Only used on the error
    /// path, where a bounded, possibly-truncated body beats no diagnosis.
    private static func drain(_ bytes: URLSession.AsyncBytes, limit: Int = 8_192) async -> String {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {
            // Body unavailable; the status code alone still gets reported.
        }
        return String(data: data, encoding: .utf8) ?? "<unreadable body>"
    }

    // MARK: Request encoding

    func makeURLRequest(for request: LLMRequest, apiKey: String) throws -> URLRequest {
        guard !request.messages.isEmpty else {
            throw LLMProviderError.invalidRequest("no messages")
        }

        var urlRequest = URLRequest(url: configuration.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(configuration.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONEncoder().encode(body(for: request))
        return urlRequest
    }

    func body(for request: LLMRequest) -> RequestBody {
        let system = request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return RequestBody(
            model: configuration.model,
            maxTokens: configuration.maxTokens,
            stream: true,
            system: system.isEmpty ? nil : system,
            messages: request.messages.map {
                RequestBody.Message(role: $0.role.rawValue, content: $0.content)
            },
            thinking: RequestBody.Thinking(configuration.thinking),
            outputConfig: configuration.effort.map { RequestBody.OutputConfig(effort: $0.rawValue) }
        )
    }

    /// Encodable mirror of the Messages API body. Internal rather than private
    /// so the request shape is assertable in tests without a network call.
    nonisolated struct RequestBody: Encodable, Equatable {
        struct Message: Encodable, Equatable {
            let role: String
            let content: String
        }

        struct Thinking: Encodable, Equatable {
            let type: String
            let display: String?

            init?(_ mode: ClaudeConfiguration.Thinking) {
                switch mode {
                case .adaptiveSummarized:
                    type = "adaptive"
                    display = "summarized"
                case .adaptiveOmitted:
                    type = "adaptive"
                    display = nil
                case .unspecified:
                    return nil
                }
            }
        }

        struct OutputConfig: Encodable, Equatable {
            let effort: String
        }

        let model: String
        let maxTokens: Int
        let stream: Bool
        let system: String?
        let messages: [Message]
        let thinking: Thinking?
        let outputConfig: OutputConfig?

        enum CodingKeys: String, CodingKey {
            case model, stream, system, messages, thinking
            case maxTokens = "max_tokens"
            case outputConfig = "output_config"
        }
    }
}

// MARK: - OnDeviceFallbackProvider

/// Foundation Models as the offline answer path. Same protocol, same chunk
/// stream, so the orchestrator cannot tell the two apart beyond
/// `LLMCompletion.providerIdentifier`.
///
/// Immutable for the same reason as `ClaudeSSEProvider`: a fresh
/// `LanguageModelSession` per request, so there is no carried state. A reused
/// session would accumulate a transcript that double-counts the history already
/// in `LLMRequest.messages`.
nonisolated struct OnDeviceFallbackProvider: LLMStreamingProvider {
    let identifier = "on-device"

    private let model: SystemLanguageModel
    private let options: GenerationOptions

    init(
        model: SystemLanguageModel = .default,
        options: GenerationOptions = GenerationOptions()
    ) {
        self.model = model
        self.options = options
    }

    func isAvailable() async -> Bool { model.isAvailable }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: LLMRequest,
        into continuation: AsyncThrowingStream<LLMStreamChunk, any Error>.Continuation
    ) async throws {
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw LLMProviderError.onDeviceModelUnavailable(reason: Self.describe(reason))
        }

        let instructions = request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = LanguageModelSession(
            model: model,
            instructions: instructions.isEmpty ? nil : instructions
        )

        // `ResponseStream` yields *cumulative* snapshots, while
        // `LLMStreamChunk.text` is a delta contract. Diff against the previous
        // snapshot rather than re-emitting the whole response every tick.
        var emitted = ""
        do {
            for try await snapshot in session.streamResponse(
                to: Self.prompt(for: request),
                options: options
            ) {
                try Task.checkCancellation()
                let content = snapshot.content
                if let chunk = Self.transition(from: emitted, to: content) {
                    continuation.yield(chunk)
                }
                emitted = content
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LLMProviderError.onDeviceGenerationFailed(String(describing: error))
        }

        continuation.yield(
            .done(LLMCompletion(providerIdentifier: identifier, stopReason: "end_turn"))
        )
    }

    /// Turns one cumulative snapshot into the chunk that carries it, given
    /// what has already been emitted. `nil` when the snapshot added nothing.
    ///
    /// The growing case is an append and yields a `.text` delta. A snapshot
    /// that is *not* an extension of what came before — guardrails or a retry
    /// rewriting the answer mid-flight — cannot be expressed as a delta at
    /// all: emitting the new content as one would leave the caller showing the
    /// abandoned prefix followed by the replacement. That case yields
    /// `.replace` instead, which is exactly why the case exists.
    static func transition(from emitted: String, to content: String) -> LLMStreamChunk? {
        guard content != emitted else { return nil }
        guard content.hasPrefix(emitted) else { return .replace(content) }
        let delta = String(content.dropFirst(emitted.count))
        return delta.isEmpty ? nil : .text(delta)
    }

    /// Flattens the conversation into a single prompt.
    ///
    /// Foundation Models seeds history through `Transcript`, not a message
    /// array, and hand-building `Transcript.Entry` values just to replay text
    /// buys nothing here — the fallback path is a single answer, not a resumed
    /// session. The system prompt goes to `instructions`, where it belongs;
    /// only prior turns are flattened.
    static func prompt(for request: LLMRequest) -> String {
        guard let current = request.messages.last else { return "" }
        let history = request.messages.dropLast()
        guard !history.isEmpty else { return current.content }

        let transcript = history
            .map { "\($0.role == .user ? "User" : "Assistant"): \($0.content)" }
            .joined(separator: "\n\n")
        return """
        Previous conversation:
        \(transcript)

        Respond to the latest message:
        \(current.content)
        """
    }

    static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "this device is not eligible for Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled"
        case .modelNotReady:
            return "the model is still downloading or preparing"
        @unknown default:
            return "unknown reason"
        }
    }
}

// MARK: - Network reachability

nonisolated protocol NetworkReachability: Sendable {
    func isNetworkAvailable() async -> Bool
}

/// `NWPathMonitor` behind an actor, which is what keeps the non-`Sendable`
/// monitor and its last-known status from escaping.
///
/// Defaults to available until the first path update lands: an optimistic
/// default costs one failed request that falls back, whereas a pessimistic one
/// would route the very first message of a session to the on-device model on a
/// perfectly good connection.
actor PathMonitorReachability: NetworkReachability {
    /// `nonisolated` so `deinit` can cancel it. `NWPathMonitor` is a reference
    /// type whose `cancel()` is safe to call from any thread, and by `deinit`
    /// no other reference to this actor survives.
    private nonisolated let monitor = NWPathMonitor()
    private var isStarted = false
    private var isSatisfied = true

    init() {}

    deinit {
        monitor.cancel()
    }

    func isNetworkAvailable() async -> Bool {
        start()
        return isSatisfied
    }

    /// Explicit teardown for callers that want the monitor released before the
    /// actor is; `deinit` covers the rest.
    func stop() {
        guard isStarted else { return }
        monitor.cancel()
        isStarted = false
    }

    private func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { await self?.update(satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "com.threads.path-monitor"))
        // Deliberately *not* seeded from `monitor.currentPath`: the first path
        // evaluation is delivered asynchronously, so reading it here races the
        // handler and usually loses, which would defeat the optimistic default
        // above. `pathUpdateHandler` is the only writer.
    }

    private func update(_ satisfied: Bool) {
        isSatisfied = satisfied
    }
}

/// Fixed answer, for tests and for callers that want the factory to skip the
/// reachability pre-check entirely.
nonisolated struct StaticReachability: NetworkReachability {
    let available: Bool

    init(available: Bool) {
        self.available = available
    }

    func isNetworkAvailable() async -> Bool { available }
}

// MARK: - LLMProviderFactory

/// Picks a provider per request and fails over transparently.
///
/// An actor, unlike the providers themselves: it caches the on-device
/// availability probe, which is genuine mutable state shared across concurrent
/// requests. That cache serves `isFallbackAvailable()` — the debug inspector's
/// pre-flight — and deliberately does *not* gate routing: the on-device
/// provider re-checks `model.availability` itself and reports a specific
/// reason, which short-circuiting here would throw away.
///
/// **Fallback rule.** The primary is skipped outright when the network is down
/// or it reports itself unavailable. If it is tried and fails *before yielding
/// any visible output*, the fallback takes over silently — the user sees one
/// uninterrupted response and no error, which is what the contract asks for.
/// Once text has been emitted, a failure propagates instead: restarting there
/// would either duplicate the visible answer or silently discard it, and both
/// are worse than an honest error the caller can attach to a partial message.
/// `.thinking` alone does not count as emitted output; it is ancillary and
/// safe to abandon.
///
/// A refusal counts as a failure for this purpose. It arrives as a successful
/// HTTP 200 whose `stop_reason` is `refusal`, typically with no text, so
/// without this it would surface as a valid but empty answer and the fallback
/// would never run.
///
/// Cancellation is never a fallback trigger — a cancelled request is the
/// caller's decision, not a provider failure.
actor LLMProviderFactory {
    private let primary: any LLMStreamingProvider
    private let fallback: any LLMStreamingProvider
    private let reachability: any NetworkReachability
    private var cachedFallbackAvailability: Bool?

    init(
        primary: any LLMStreamingProvider,
        fallback: any LLMStreamingProvider,
        reachability: any NetworkReachability = PathMonitorReachability()
    ) {
        self.primary = primary
        self.fallback = fallback
        self.reachability = reachability
    }

    /// The app's wiring: Claude over SSE, Foundation Models behind it.
    static func makeDefault(
        configuration: ClaudeConfiguration = ClaudeConfiguration()
    ) -> LLMProviderFactory {
        LLMProviderFactory(
            primary: ClaudeSSEProvider(configuration: configuration),
            fallback: OnDeviceFallbackProvider()
        )
    }

    /// Which provider a request would go to right now. Exposed for the debug
    /// inspector and for tests; `stream` does not depend on it having been
    /// called.
    func activeProviderIdentifier() async -> String {
        if case .attempt = await primaryDecision() { return primary.identifier }
        return fallback.identifier
    }

    nonisolated func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await run(request, into: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: LLMRequest,
        into continuation: AsyncThrowingStream<LLMStreamChunk, any Error>.Continuation
    ) async {
        var primaryFailure: (any Error)?

        switch await primaryDecision() {
        case .attempt:
            switch await forward(primary.stream(request), to: continuation) {
            case .finished:
                continuation.finish()
                return
            case .cancelled:
                continuation.finish(throwing: CancellationError())
                return
            case .failedAfterOutput(let error):
                continuation.finish(throwing: error)
                return
            case .failedBeforeOutput(let error):
                primaryFailure = error
            case .refusedBeforeOutput:
                primaryFailure = LLMProviderError.refusedByProvider(primary.identifier)
            }
        case .skip(let reason):
            primaryFailure = reason
        }

        switch await forward(fallback.stream(request), to: continuation) {
        case .finished:
            continuation.finish()
        case .cancelled:
            continuation.finish(throwing: CancellationError())
        case .refusedBeforeOutput(let completion):
            // Nothing left to fall back to, so deliver the refusal as the
            // answer rather than inventing a failure the caller can't act on.
            continuation.yield(.done(completion))
            continuation.finish()
        case .failedAfterOutput(let error), .failedBeforeOutput(let error):
            continuation.finish(
                throwing: LLMProviderError.allProvidersFailed(
                    primary: primaryFailure.map { String(describing: $0) } ?? "not attempted",
                    fallback: String(describing: error)
                )
            )
        }
    }

    /// Whether the primary is worth attempting, and if not, *why* — the reason
    /// is the one reported as the primary's cause when the fallback also
    /// fails, so "no API key" must not present as "no network."
    private enum PrimaryDecision {
        case attempt
        case skip(LLMProviderError)
    }

    private func primaryDecision() async -> PrimaryDecision {
        guard await primary.isAvailable() else {
            return .skip(.providerUnavailable(primary.identifier))
        }
        guard await reachability.isNetworkAvailable() else {
            return .skip(.networkUnavailable)
        }
        return .attempt
    }

    private enum ForwardResult {
        /// Completed. Any `.done` the provider produced has been forwarded.
        case finished
        /// Ended in a refusal with no visible output. The completion is
        /// withheld rather than forwarded, so that a caller who falls back
        /// doesn't receive two terminal chunks for one response.
        case refusedBeforeOutput(LLMCompletion)
        case cancelled
        case failedBeforeOutput(any Error)
        case failedAfterOutput(any Error)
    }

    /// Pipes one provider's chunks into the caller's stream, tracking whether
    /// any visible output made it out before the stream ended.
    private func forward(
        _ source: AsyncThrowingStream<LLMStreamChunk, any Error>,
        to continuation: AsyncThrowingStream<LLMStreamChunk, any Error>.Continuation
    ) async -> ForwardResult {
        var didEmitText = false
        var completion: LLMCompletion?
        do {
            for try await chunk in source {
                try Task.checkCancellation()
                switch chunk {
                case .text, .replace:
                    didEmitText = true
                    continuation.yield(chunk)
                case .thinking:
                    continuation.yield(chunk)
                case .done(let received):
                    // Buffered, not forwarded: whether this is the caller's
                    // terminal chunk depends on what the refusal check below
                    // decides.
                    completion = received
                }
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            if Task.isCancelled { return .cancelled }
            return didEmitText ? .failedAfterOutput(error) : .failedBeforeOutput(error)
        }

        if let completion {
            if completion.stopReason == Self.refusalStopReason, !didEmitText {
                return .refusedBeforeOutput(completion)
            }
            continuation.yield(.done(completion))
        }
        return .finished
    }

    /// `stop_reason` on a declined request. HTTP 200, not an error.
    private static let refusalStopReason = "refusal"

    /// Cached: on-device availability is a device capability, not a per-request
    /// condition, and the probe is the only thing here worth not repeating.
    func isFallbackAvailable() async -> Bool {
        if let cachedFallbackAvailability { return cachedFallbackAvailability }
        let available = await fallback.isAvailable()
        cachedFallbackAvailability = available
        return available
    }
}
