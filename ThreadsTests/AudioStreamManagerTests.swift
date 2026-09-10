//
//  AudioStreamManagerTests.swift
//  ThreadsTests
//
//  Covers the parts of the voice-capture path that do not need a microphone or
//  Speech assets: permission resolution, live-transcript assembly, waveform
//  level math, and workstream titling. The audio/`SpeechAnalyzer` path itself
//  cannot run on the iPhone 17 Pro simulator (no Speech assets — the same
//  limitation SPEC.md records for `NLContextualEmbedding`) and is verified on
//  device. The logic here is pulled into `nonisolated` value types precisely so
//  these can be real assertions rather than skipped hardware tests.
//

import Foundation
import Testing
@testable import Threads

// MARK: - Permission resolution

@Suite struct CapturePermissionResolverTests {

    @Test func bothGrantedProceeds() {
        #expect(CapturePermissionResolver.resolve(microphoneGranted: true, speechAuthorized: true) == .granted)
    }

    @Test func microphoneDenialReportedEvenWhenSpeechAlsoDenied() {
        // Microphone is checked first: without it there is nothing to transcribe.
        #expect(CapturePermissionResolver.resolve(microphoneGranted: false, speechAuthorized: false) == .microphoneDenied)
        #expect(CapturePermissionResolver.resolve(microphoneGranted: false, speechAuthorized: true) == .microphoneDenied)
    }

    @Test func speechDenialReportedWhenMicrophoneGranted() {
        #expect(CapturePermissionResolver.resolve(microphoneGranted: true, speechAuthorized: false) == .speechDenied)
    }
}

// MARK: - Transcript assembly

@Suite struct TranscriptAccumulatorTests {

    @Test func volatileResultsReplaceRatherThanAppend() {
        var accumulator = TranscriptAccumulator()
        accumulator.ingest("hel", isFinal: false)
        accumulator.ingest("hello wor", isFinal: false)
        accumulator.ingest("hello world", isFinal: false)

        #expect(accumulator.finalized.isEmpty)
        #expect(accumulator.display == "hello world")
    }

    @Test func finalResultAppendsAndClearsVolatile() {
        var accumulator = TranscriptAccumulator()
        accumulator.ingest("hello world", isFinal: false)
        accumulator.ingest("Hello world.", isFinal: true)

        #expect(accumulator.finalized == "Hello world.")
        #expect(accumulator.volatile.isEmpty)
        #expect(accumulator.display == "Hello world.")
    }

    @Test func finalizedPhrasesJoinWithASingleSpace() {
        var accumulator = TranscriptAccumulator()
        accumulator.ingest("First phrase.", isFinal: true)
        accumulator.ingest("Second phrase.", isFinal: true)

        #expect(accumulator.finalized == "First phrase. Second phrase.")
    }

    @Test func displayShowsFinalizedFollowedByVolatileTail() {
        var accumulator = TranscriptAccumulator()
        accumulator.ingest("Finalized part.", isFinal: true)
        accumulator.ingest("in-flight tail", isFinal: false)

        #expect(accumulator.display == "Finalized part. in-flight tail")
    }

    @Test func finalizedTextIsTrimmedBeforeAppending() {
        var accumulator = TranscriptAccumulator()
        accumulator.ingest("  spaced out  ", isFinal: true)

        #expect(accumulator.finalized == "spaced out")
    }

    @Test func emptyFinalResultDoesNotAddStrayWhitespace() {
        var accumulator = TranscriptAccumulator()
        accumulator.ingest("Kept.", isFinal: true)
        accumulator.ingest("   ", isFinal: true)

        #expect(accumulator.finalized == "Kept.")
    }

    @Test func resetClearsEverything() {
        var accumulator = TranscriptAccumulator()
        accumulator.ingest("Something.", isFinal: true)
        accumulator.ingest("tail", isFinal: false)
        accumulator.reset()

        #expect(accumulator.finalized.isEmpty)
        #expect(accumulator.volatile.isEmpty)
        #expect(accumulator.display.isEmpty)
    }
}

// MARK: - Waveform level math

@Suite struct WaveformLevelTests {

    @Test func rmsOfSilenceIsZero() {
        #expect(WaveformLevel.rms([0, 0, 0, 0]) == 0)
        #expect(WaveformLevel.rms([]) == 0)
    }

    @Test func rmsOfConstantAmplitudeIsThatAmplitude() {
        #expect(WaveformLevel.rms([1, 1, 1, 1]) == 1)
    }

    @Test func rmsMatchesRootMeanSquare() {
        // sqrt((9 + 16) / 2) == sqrt(12.5)
        #expect(abs(WaveformLevel.rms([3, 4]) - 3.5355) < 0.001)
    }

    @Test func normalizedIsZeroForSilenceAndClampsAtFloor() {
        #expect(WaveformLevel.normalized(rms: 0) == 0)
        // -50 dB is the default floor, so its RMS maps to exactly 0.
        let floorRMS = Float(pow(10.0, -50.0 / 20.0))
        #expect(WaveformLevel.normalized(rms: floorRMS) == 0)
    }

    @Test func normalizedClampsAtOneForFullScale() {
        #expect(WaveformLevel.normalized(rms: 1) == 1)
        #expect(WaveformLevel.normalized(rms: 2) == 1)
    }

    @Test func normalizedIsMidscaleAtHalfwayDown() {
        // -25 dB is halfway between the -50 dB floor and 0 dB.
        let midRMS = Float(pow(10.0, -25.0 / 20.0))
        #expect(abs(WaveformLevel.normalized(rms: midRMS) - 0.5) < 0.01)
    }
}

// MARK: - Workstream titling

@Suite struct WorkstreamNamingTests {

    @Test func firstSentenceBecomesTheTitle() {
        let title = WorkstreamNaming.title(from: "Let's serialize token refresh. It races under load.")
        #expect(title == "Let's serialize token refresh")
    }

    @Test func aTranscriptWithNoTerminatorIsUsedWhole() {
        #expect(WorkstreamNaming.title(from: "spike the actor token store") == "spike the actor token store")
    }

    @Test func longTitlesAreTruncatedWithAnEllipsis() {
        let long = "This is a very long single sentence that keeps going well past the limit"
        let title = WorkstreamNaming.title(from: long, maxLength: 20)
        #expect(title.hasSuffix("…"))
        #expect(title.count <= 21) // 20 chars + the ellipsis
    }

    @Test func blankTranscriptFallsBackToAPlaceholder() {
        #expect(WorkstreamNaming.title(from: "   \n  ") == "New Thought")
        #expect(WorkstreamNaming.title(from: "") == "New Thought")
    }
}
