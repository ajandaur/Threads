//
//  AudioStreamManager.swift
//  Threads
//
//  Voice capture: microphone + speech-recognition permissions, audio capture
//  via `AVAudioEngine`, and on-device live transcription through
//  `SpeechAnalyzer` + `SpeechTranscriber` (iOS 26, per the "SpeechAnalyzer over
//  SFSpeechRecognizer" decision in `.claude/rules/DECISIONS.md`).
//
//  ## Isolation
//
//  This is a `@MainActor @Observable` controller, not a service actor: it exists
//  to publish live state (transcript, waveform levels, permission/availability)
//  straight into SwiftUI, and the project's `SWIFT_DEFAULT_ACTOR_ISOLATION =
//  MainActor` already puts it there. The genuinely off-main work — audio
//  conversion on the render thread, and transcription — runs inside
//  `SpeechAnalyzer` (itself an actor) and the render-thread tap, which never
//  touch this object's isolated state directly. The tap talks to the rest of
//  the pipeline only through `Sendable` `AsyncStream` continuations.
//
//  ## Testability
//
//  Everything that can be checked without a microphone is pulled out into
//  `nonisolated` value types below — permission resolution, transcript
//  assembly, and waveform-level math — the same split `OrchestrationPrompts`
//  makes from `ThreadOrchestrator`. The live audio/Speech path (`start` /
//  `stop`) cannot run on the iPhone 17 Pro simulator (no Apple Intelligence /
//  Speech assets, the same limitation SPEC.md records for `NLContextualEmbedding`)
//  and is verified on device.
//

import Foundation
import AVFoundation
import Observation
import Speech

// MARK: - Pure, testable logic (no audio hardware, no Speech assets)

/// Resolves the two independent permission answers into a single outcome, so
/// the "which prompt was refused" branching is checkable without a device.
nonisolated enum CapturePermissionResolver {
    enum Outcome: Equatable, Sendable {
        case granted
        case microphoneDenied
        case speechDenied
    }

    /// Microphone is checked first: without it there is nothing to transcribe,
    /// so a missing mic grant is reported even if speech was also refused.
    static func resolve(microphoneGranted: Bool, speechAuthorized: Bool) -> Outcome {
        guard microphoneGranted else { return .microphoneDenied }
        guard speechAuthorized else { return .speechDenied }
        return .granted
    }
}

/// Assembles the displayed transcript from the transcriber's stream of results.
/// Volatile results for the in-flight audio range are replaced as they refine;
/// a finalized result is appended and clears the volatile tail. Kept as a value
/// type so the "volatile replaces, final appends" rule is unit-testable against
/// a scripted sequence of results.
nonisolated struct TranscriptAccumulator: Equatable, Sendable {
    private(set) var finalized: String = ""
    private(set) var volatile: String = ""

    /// Finalized text followed by the current volatile tail, single-spaced.
    var display: String {
        let tail = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.isEmpty { return finalized }
        return finalized.isEmpty ? tail : finalized + " " + tail
    }

    mutating func ingest(_ text: String, isFinal: Bool) {
        if isFinal {
            let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                finalized = finalized.isEmpty ? piece : finalized + " " + piece
            }
            volatile = ""
        } else {
            volatile = text
        }
    }

    mutating func reset() {
        finalized = ""
        volatile = ""
    }
}

/// Waveform-level math: PCM float samples → a 0...1 bar height. Split out so the
/// RMS and dB-floor normalization can be tested with plain sample arrays rather
/// than live buffers.
nonisolated enum WaveformLevel {
    /// Root-mean-square amplitude of a block of mono float samples.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }

    /// Maps an RMS amplitude to 0...1 on a decibel scale, so quiet speech still
    /// produces a visible bar. Silence (or sub-floor level) maps to 0.
    static func normalized(rms: Float, floorDB: Float = -50) -> Double {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        if db <= floorDB { return 0 }
        if db >= 0 { return 1 }
        return Double((db - floorDB) / -floorDB)
    }
}

// MARK: - AudioStreamManager

@MainActor
@Observable
final class AudioStreamManager {

    /// The capture lifecycle, as a single observable value the UI switches on.
    enum State: Equatable, Sendable {
        case idle
        case preparing
        case recording
        case stopping
        case denied(Denial)
        /// Transcription can't run here (unsupported locale, missing assets, or
        /// the simulator). Carries a human-readable reason for the UI.
        case unavailable(String)

        enum Denial: Equatable, Sendable { case microphone, speech }
    }

    /// Number of recent level samples retained for the waveform.
    static let waveformSampleCount = 48

    private(set) var state: State = .idle
    /// Live transcript (finalized text plus the volatile tail) for on-screen display.
    private(set) var transcript: String = ""
    /// Rolling window of recent normalized audio levels driving the waveform.
    private(set) var levels: [Double] = []

    var isRecording: Bool { state == .recording }

    // Non-observable machinery for the active session.
    @ObservationIgnored private var accumulator = TranscriptAccumulator()
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var levelBuilder: AsyncStream<Double>.Continuation?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    /// Set when the user releases while `startRecording()` is still in
    /// `.preparing`. The in-flight start checks it at its final gate and aborts
    /// rather than beginning a recording after the finger has already lifted.
    @ObservationIgnored private var pendingStop = false

    init() {}

    // MARK: Prewarm

    /// Best-effort front-loading of the on-device speech model so the first hold
    /// is responsive instead of stalling on a multi-second install. Only runs
    /// when speech recognition is already authorized, so it never triggers a
    /// permission prompt or background work on a fresh launch — a no-op in that
    /// case, and the first real `startRecording()` will do the install then.
    func prewarm() async {
        guard state == .idle,
              SpeechTranscriber.isAvailable,
              SFSpeechRecognizer.authorizationStatus() == .authorized,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            return
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try? await request.downloadAndInstall()
        }
    }

    // MARK: Start

    /// Requests permissions, brings up the audio graph, and begins live
    /// transcription. Any failure lands the manager in `.denied` or
    /// `.unavailable` with a reason rather than throwing — the caller only holds
    /// a gesture, not an error path.
    func startRecording() async {
        guard state != .recording, state != .preparing else { return }
        resetForNewSession()
        pendingStop = false
        state = .preparing

        // 1. Permissions (both prompts, resolved together).
        let micGranted = await AVAudioApplication.requestRecordPermission()
        let speechAuthorized = await Self.requestSpeechAuthorization()
        switch CapturePermissionResolver.resolve(microphoneGranted: micGranted, speechAuthorized: speechAuthorized) {
        case .granted:
            break
        case .microphoneDenied:
            state = .denied(.microphone)
            return
        case .speechDenied:
            state = .denied(.speech)
            return
        }

        // A tap (rather than a hold) has already released by now. Bail before
        // the expensive availability / model-install / engine work so a tap
        // snaps back to idle instead of stalling on "Preparing…". Nothing has
        // been built yet, so there is nothing to tear down.
        if pendingStop {
            pendingStop = false
            state = .idle
            return
        }

        // 2. Bail out cleanly where on-device transcription can't run at all
        //    (notably the simulator, which has no Speech model) rather than
        //    calling into the transcription stack and tripping an assertion.
        guard SpeechTranscriber.isAvailable else {
            state = .unavailable("On-device speech transcription isn't available here. Run on a physical device.")
            return
        }

        // A transcriber for the user's locale, reporting volatile (live) results.
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            state = .unavailable("On-device transcription isn't available for \(Locale.current.identifier).")
            return
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        // 3. Ensure the on-device model assets are installed.
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            state = .unavailable("Couldn't install the on-device speech model: \(error.localizedDescription)")
            return
        }

        // Released while the model was installing: same early bail as above,
        // still before any hardware is touched.
        if pendingStop {
            pendingStop = false
            state = .idle
            return
        }

        // 4. The analyzer does no audio conversion, so capture must arrive in a
        //    format its modules accept.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            state = .unavailable("No compatible audio format for on-device transcription.")
            return
        }

        // 5. Input plumbing: one stream of audio into the analyzer, one of levels
        //    to the waveform.
        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let (levelSequence, levelBuilder) = AsyncStream.makeStream(of: Double.self)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // 6. Audio session + engine tap. The tap runs on the render thread and
        //    only touches the Sendable processor, never `self`.
        do {
            try await configureSession()
            try startEngine(convertingTo: analyzerFormat, input: inputBuilder, levels: levelBuilder)
        } catch {
            inputBuilder.finish()
            levelBuilder.finish()
            teardownEngine()
            await deactivateSession()
            state = .unavailable("Couldn't start audio capture: \(error.localizedDescription)")
            return
        }

        // 7. Drain transcription results and level samples onto the main actor.
        let resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    self?.ingest(text, isFinal: result.isFinal)
                }
            } catch {
                self?.reportRuntimeFailure(error)
            }
        }
        let levelTask = Task { [weak self] in
            for await level in levelSequence {
                self?.appendLevel(level)
            }
        }

        // 8. Start autonomous analysis; it returns immediately.
        do {
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            resultsTask.cancel()
            levelTask.cancel()
            inputBuilder.finish()
            levelBuilder.finish()
            teardownEngine()
            await deactivateSession()
            state = .unavailable("Couldn't start transcription: \(error.localizedDescription)")
            return
        }

        self.analyzer = analyzer
        self.inputBuilder = inputBuilder
        self.levelBuilder = levelBuilder
        self.resultsTask = resultsTask
        self.levelTask = levelTask

        // The user may have released while any of the awaits above were still
        // running. If so, stop now rather than starting a recording whose start
        // the user never saw (which otherwise strands the capture UI "on" until
        // a second press/release).
        if pendingStop {
            pendingStop = false
            state = .stopping
            await teardown()
            transcript = accumulator.display
            state = .idle
            return
        }
        state = .recording
    }

    // MARK: Stop

    /// Stops capture, waits for the final results to settle, and returns the
    /// completed transcript. Safe to call in any state — a call while not
    /// recording just returns whatever transcript exists.
    @discardableResult
    func stopRecording() async -> String {
        // Released before setup finished: the graph isn't up yet, so there is
        // nothing to tear down here. Flag it and let the in-flight
        // `startRecording()` abort at its final gate.
        if state == .preparing {
            pendingStop = true
            return ""
        }
        guard state == .recording else {
            return accumulator.display
        }
        state = .stopping
        await teardown()

        let finalTranscript = accumulator.display
        transcript = finalTranscript
        state = .idle
        return finalTranscript
    }

    /// Tears down the engine, input streams, and analyzer, waiting for the final
    /// results to settle. Shared by `stopRecording()` and the
    /// release-during-setup abort path in `startRecording()`.
    private func teardown() async {
        teardownEngine()
        inputBuilder?.finish()
        levelBuilder?.finish()

        // Let the analyzer emit any remaining finalized results, then drain them.
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await resultsTask?.value
        levelTask?.cancel()
        await deactivateSession()

        analyzer = nil
        inputBuilder = nil
        levelBuilder = nil
        resultsTask = nil
        levelTask = nil
    }

    // MARK: Main-actor state updates

    private func ingest(_ text: String, isFinal: Bool) {
        accumulator.ingest(text, isFinal: isFinal)
        transcript = accumulator.display
    }

    private func appendLevel(_ level: Double) {
        levels.append(level)
        if levels.count > Self.waveformSampleCount {
            levels.removeFirst(levels.count - Self.waveformSampleCount)
        }
    }

    private func reportRuntimeFailure(_ error: any Error) {
        // Only surface a mid-recording failure; a benign end-of-stream while
        // stopping isn't an error the user needs to see.
        if state == .recording {
            state = .unavailable("Transcription stopped: \(error.localizedDescription)")
        }
    }

    private func resetForNewSession() {
        accumulator.reset()
        transcript = ""
        levels = []
    }

    // MARK: Audio graph

    // `nonisolated @concurrent` is load-bearing: `AVAudioSession`'s
    // `setCategory`/`setActive` block until CoreAudio has (de)activated the
    // session, and running them on the main actor stalls the UI — the
    // `SessionCore`/`AVAudioSession_iOS` "UI unresponsiveness … called on the
    // main thread" warnings. They touch only the shared session singleton, no
    // `self` state, so hopping to the concurrent executor is safe.
    @concurrent
    private nonisolated func configureSession() async throws {
        let session = AVAudioSession.sharedInstance()
        // `.duckOthers` is only valid on a playback-capable category, so pure
        // `.record` takes no options here.
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    @concurrent
    private nonisolated func deactivateSession() async {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startEngine(
        convertingTo analyzerFormat: AVAudioFormat,
        input inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
        levels levelBuilder: AsyncStream<Double>.Continuation
    ) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            throw CaptureError.audioConverterUnavailable
        }
        let processor = TapProcessor(
            converter: converter,
            analyzerFormat: analyzerFormat,
            input: inputBuilder,
            levels: levelBuilder
        )

        // `@Sendable` is load-bearing: AVFAudio runs the tap on its realtime
        // queue, but the project's default `MainActor` isolation would otherwise
        // make this closure main-actor-isolated and Swift 6's executor check
        // would trap when it fires off-main. `@Sendable` makes it non-isolated;
        // it only touches the `Sendable` `processor`.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable buffer, _ in
            processor.process(buffer)
        }
        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    private func teardownEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    // MARK: Permissions

    /// `nonisolated` is load-bearing: `SFSpeechRecognizer.requestAuthorization`
    /// invokes its completion on a background TCC queue, but the project's
    /// default `MainActor` isolation would otherwise make this closure
    /// main-actor-isolated, and Swift 6's executor check traps when the callback
    /// fires off-main. Resuming the `Sendable` continuation is safe from any
    /// thread, so the bridge carries no isolation.
    private nonisolated static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    enum CaptureError: Error {
        case audioConverterUnavailable
    }
}

// MARK: - Render-thread tap processor

/// Runs on the audio render thread. Isolated from the manager's main-actor state
/// so it can be captured by the (`@Sendable`) tap block; it owns the non-Sendable
/// `AVAudioConverter` and talks to the rest of the pipeline only through the two
/// `Sendable` stream continuations. `@unchecked Sendable` is sound because the
/// tap invokes `process` serially on one thread.
private nonisolated final class TapProcessor: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let analyzerFormat: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let levels: AsyncStream<Double>.Continuation

    /// Holds the buffer the converter's (`@Sendable`) input block should return
    /// exactly once. Lives on the processor rather than as a captured local var
    /// so the block never captures the non-Sendable buffer directly; safe
    /// because the render tap calls `process` serially.
    private var pendingInput: AVAudioPCMBuffer?

    init(
        converter: AVAudioConverter,
        analyzerFormat: AVAudioFormat,
        input: AsyncStream<AnalyzerInput>.Continuation,
        levels: AsyncStream<Double>.Continuation
    ) {
        self.converter = converter
        self.analyzerFormat = analyzerFormat
        self.input = input
        self.levels = levels
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        levels.yield(WaveformLevel.normalized(rms: Self.rms(of: buffer)))
        if let converted = convert(buffer) {
            input.yield(AnalyzerInput(buffer: converted))
        }
    }

    /// Converts one captured buffer into the analyzer's format. The whole input
    /// buffer is offered exactly once; on the next converter callback there is
    /// no more data for this call.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
            return nil
        }

        pendingInput = buffer
        let inputBlock: AVAudioConverterInputBlock = { [self] _, statusOut in
            guard let ready = pendingInput else {
                statusOut.pointee = .noDataNow
                return nil
            }
            pendingInput = nil
            statusOut.pointee = .haveData
            return ready
        }

        var error: NSError?
        let status = converter.convert(to: output, error: &error, withInputFrom: inputBlock)
        return status == .error ? nil : output
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: frames))
        return WaveformLevel.rms(samples)
    }
}
