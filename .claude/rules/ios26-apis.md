---
paths:
  - "**/Core/**/*.swift"
---
# iOS 26 Framework APIs — Verified Signatures

Scoped to `Core/` because that's where SPEC.md (Core Files section) places
ContextEngine.swift, OnDeviceIntelligence.swift, LLMProvider.swift, and
ThreadOrchestrator.swift — the files that actually import FoundationModels,
SpeechAnalyzer, and NLContextualEmbedding. If one of these APIs ends up
called from a file outside `Core/`, this rule won't auto-load there; the
fallback trigger in CLAUDE.md ("before using any iOS 26 framework... read
this file") is what catches that case.

Source: iOS 26.5 SDK (`iPhoneOS26.5.sdk` → `iPhoneOS.sdk`), Xcode toolchain,
Swift 6.3.2 compiler, target `arm64e-apple-ios26.5`.

Extracted directly from:
- `FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface`
- `Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-ios.swiftinterface`
- `NaturalLanguage.framework/Headers/NLContextualEmbedding.h` (Objective-C — no
  swiftinterface exists; NaturalLanguage is not a pure-Swift module)

Do not add signatures to this file from memory. If you need an API not listed
here, re-derive it from the `.swiftinterface`/header directly and add it.
All three frameworks are `@available(iOS 26.0, ...)` unless noted; watchOS is
unavailable across all of them.

---

## FoundationModels

### `@Generable` / `@Guide` macros
```swift
@Generable(description: String? = nil)
@Generable(description: String? = nil, representNilExplicitlyInGeneratedContent: Bool)  // iOS 26.4+

@Guide<T>(description: String? = nil, _ guides: GenerationGuide<T>...) where T: Generable
@Guide<RegexOutput>(description: String? = nil, _ guides: Regex<RegexOutput>)
@Guide(description: String)
```
`@Generable` is `@attached(extension, ...)` + `@attached(member, ...)` — it
synthesizes `init(_:)` and `generatedContent` plus arbitrary members. Applies
to structs/enums; conforms the type to `Generable`.

### `Generable` protocol
```swift
public protocol Generable: ConvertibleFromGeneratedContent, ConvertibleToGeneratedContent {
    associatedtype PartiallyGenerated: ConvertibleFromGeneratedContent = Self
    static var generationSchema: GenerationSchema { get }
}
// default: func asPartiallyGenerated() -> PartiallyGenerated
```
`Bool`, `String`, `Int`, `Float`, `Double`, `Decimal`, `Array` (where
`Element: Generable`), and `Never` already conform. `Optional` conforms to
`ConvertibleToGeneratedContent`/`PromptRepresentable`/`InstructionsRepresentable`
when `Wrapped` does.

### `GeneratedContent`
```swift
public struct GeneratedContent: Sendable, Equatable, Generable, CustomDebugStringConvertible {
    public var id: GenerationID?
    public init(properties: KeyValuePairs<String, any ConvertibleToGeneratedContent>, id: GenerationID? = nil)
    public init(_ value: some ConvertibleToGeneratedContent)
    public init(_ value: some ConvertibleToGeneratedContent, id: GenerationID)
    public init(json: String) throws
    public var jsonString: String { get }
    public var isComplete: Bool { get }
    public func value<Value: ConvertibleFromGeneratedContent>(_ type: Value.Type = Value.self) throws -> Value
    public func value<Value: ConvertibleFromGeneratedContent>(_ type: Value.Type = Value.self, forProperty property: String) throws -> Value

    public enum Kind: Equatable, Sendable {
        case null, bool(Bool), number(Double), string(String)
        case array([GeneratedContent])
        case structure(properties: [String: GeneratedContent], orderedKeys: [String])
    }
    public init(kind: Kind, id: GenerationID? = nil)
    public var kind: Kind { get }
}
```

### `LanguageModelSession`
```swift
@Observable
final public class LanguageModelSession: Sendable {
    final public var transcript: Transcript { get }
    final public var isResponding: Bool { get }

    convenience init(model: SystemLanguageModel = .default, tools: [any Tool] = [], instructions: String? = nil)
    convenience init(model: SystemLanguageModel = .default, tools: [any Tool] = [], instructions: Instructions? = nil)
    convenience init(model: SystemLanguageModel = .default, tools: [any Tool] = [], transcript: Transcript)
    convenience init(model: SystemLanguageModel = .default, tools: [any Tool] = [], @InstructionsBuilder instructions: () throws -> Instructions) rethrows

    final public func prewarm(promptPrefix: Prompt? = nil)

    // respond — string, Generable, and raw-schema overloads; each also has a
    // trailing-closure @PromptBuilder variant
    @discardableResult
    func respond(to prompt: Prompt, options: GenerationOptions = .init()) async throws -> Response<String>
    @discardableResult
    func respond<Content: Generable>(to prompt: Prompt, generating type: Content.Type = Content.self, includeSchemaInPrompt: Bool = true, options: GenerationOptions = .init()) async throws -> Response<Content>
    @discardableResult
    func respond(to prompt: Prompt, schema: GenerationSchema, includeSchemaInPrompt: Bool = true, options: GenerationOptions = .init()) async throws -> Response<GeneratedContent>

    // streaming — mirrors respond, returns ResponseStream instead of Response
    func streamResponse(to prompt: Prompt, options: GenerationOptions = .init()) -> ResponseStream<String>
    func streamResponse<Content: Generable>(to prompt: Prompt, generating type: Content.Type = Content.self, includeSchemaInPrompt: Bool = true, options: GenerationOptions = .init()) -> ResponseStream<Content>
    func streamResponse(to prompt: Prompt, schema: GenerationSchema, includeSchemaInPrompt: Bool = true, options: GenerationOptions = .init()) -> ResponseStream<GeneratedContent>

    struct Response<Content: Generable> {
        let content: Content
        let rawContent: GeneratedContent
        let transcriptEntries: ArraySlice<Transcript.Entry>
    }

    struct ResponseStream<Content: Generable>: AsyncSequence {
        struct Snapshot { var content: Content.PartiallyGenerated; var rawContent: GeneratedContent }
        func collect() async throws -> Response<Content>
    }
}
```
All `respond`/`streamResponse` calls also have `to: String` overloads
(`@_disfavoredOverload`) and prompt-builder-closure overloads that omit `to:`.
There is no plain non-throwing `respond`; every generation call is `async throws`.

`GenerationError` (nested in `LanguageModelSession`):
```swift
enum GenerationError: Error, LocalizedError {
    case exceededContextWindowSize(Context)
    case assetsUnavailable(Context)
    case guardrailViolation(Context)
    case unsupportedGuide(Context)
    case unsupportedLanguageOrLocale(Context)
    case decodingFailure(Context)
    case rateLimited(Context)
    case concurrentRequests(Context)
    case refusal(Refusal, Context)
    struct Context: Sendable { let debugDescription: String }
    struct Refusal: Sendable {
        var explanation: Response<String> { get async throws }
        var explanationStream: ResponseStream<String> { get }
    }
}
struct ToolCallError: Error, LocalizedError { var tool: any Tool; var underlyingError: any Error }
```

Feedback logging (attach to bug reports / TestFlight):
```swift
func logFeedbackAttachment(sentiment: LanguageModelFeedback.Sentiment?, issues: [LanguageModelFeedback.Issue] = [], desiredOutput: Transcript.Entry? = nil) -> Data
func logFeedbackAttachment(sentiment:issues:desiredResponseText: String?) -> Data       // backdeployed convenience
func logFeedbackAttachment(sentiment:issues:desiredResponseContent: (any ConvertibleToGeneratedContent)?) -> Data  // backdeployed convenience
```

### `SystemLanguageModel`
```swift
@Observable
final public class SystemLanguageModel: Sendable {
    public static var `default`: SystemLanguageModel { get }
    final public var availability: Availability { get }
    final public var isAvailable: Bool { get }
    final public var contextSize: Int { get }   // 4096 (backdeployed constant before iOS 26.4)
    final public var supportedLanguages: Set<Locale.Language> { get }
    final public func supportsLocale(_ locale: Locale = .current) -> Bool

    convenience init(useCase: UseCase = .general, guardrails: Guardrails = .default)
    convenience init(adapter: Adapter, guardrails: Guardrails = .default)

    struct UseCase: Sendable, Equatable { static let general, contentTagging: UseCase }
    struct Guardrails: Sendable { static let `default`, permissiveContentTransformations: Guardrails }

    @frozen enum Availability: Equatable, Sendable {
        case available
        case unavailable(UnavailableReason)
        enum UnavailableReason: Equatable, Sendable {
            case deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady
        }
    }

    // iOS 26.4+
    func tokenCount(for prompt: some PromptRepresentable) async throws -> Int
    func tokenCount(for instructions: Instructions) async throws -> Int
    func tokenCount(for tools: [any Tool]) async throws -> Int
    func tokenCount(for schema: GenerationSchema) async throws -> Int
    func tokenCount(for transcriptEntries: some Collection<Transcript.Entry>) async throws -> Int

    struct Adapter {
        var creatorDefinedMetadata: [String: Any] { get }
        init(fileURL: URL) throws
        init(name: String) throws
        func compile() async throws
        static func compatibleAdapterIdentifiers(name: String) -> [String]
        static func removeObsoleteAdapters() throws
        enum AssetError: Error, LocalizedError {
            case invalidAsset(Context), invalidAdapterName(Context), compatibleAdapterNotFound(Context)
        }
    }
}
```
Check `session.isAvailable`/`SystemLanguageModel.default.availability` before
calling `respond` — there is no synchronous "will this throw" check beyond this.

### Prompts, instructions, tools
```swift
struct Instructions: Sendable { init(_ content: some InstructionsRepresentable) }
protocol InstructionsRepresentable { @InstructionsBuilder var instructionsRepresentation: Instructions { get } }
@resultBuilder struct InstructionsBuilder { /* buildBlock/buildEither/buildOptional/buildArray */ }

struct Prompt: Sendable { init(_ content: some PromptRepresentable) }
protocol PromptRepresentable { @PromptBuilder var promptRepresentation: Prompt { get } }
@resultBuilder struct PromptBuilder { /* same shape as InstructionsBuilder */ }

protocol Tool<Arguments, Output>: Sendable {
    associatedtype Output: PromptRepresentable
    associatedtype Arguments: ConvertibleFromGeneratedContent
    var name: String { get }               // default: derived from type name
    var description: String { get }
    var parameters: GenerationSchema { get } // auto-derived when Arguments: Generable
    var includesSchemaInInstructions: Bool { get }  // default true
    func call(arguments: Arguments) async throws -> Output
}
```
`Tool.Arguments` **must** be a `@Generable` struct — `String`/`Int`/`Double`/
`Float`/`Decimal`/`Bool` as `Arguments` are explicitly `unavailable` on the
`parameters` accessor ("Use `@Generable` struct instead").

### Schemas & guides
```swift
struct GenerationSchema: Sendable, Codable, CustomDebugStringConvertible {
    init(type: any Generable.Type, description: String? = nil, properties: [Property])
    init(type: any Generable.Type, description: String? = nil, anyOf choices: [String])
    init(type: any Generable.Type, description: String? = nil, anyOf types: [any Generable.Type])
    init(root: DynamicGenerationSchema, dependencies: [DynamicGenerationSchema]) throws
    struct Property {
        init<Value: Generable>(name: String, description: String? = nil, type: Value.Type, guides: [GenerationGuide<Value>] = [])
        init<Value: Generable>(name: String, description: String? = nil, type: Value?.Type, guides: [GenerationGuide<Value>] = [])
    }
    enum SchemaError: Error, LocalizedError {
        case duplicateType, duplicateProperty, emptyTypeChoices, undefinedReferences  // each carries schema/type/context
    }
}

struct DynamicGenerationSchema: Sendable {
    init(name: String, description: String? = nil, properties: [Property])
    init(name: String, description: String? = nil, anyOf choices: [DynamicGenerationSchema])
    init(name: String, description: String? = nil, anyOf choices: [String])
    init(arrayOf itemSchema: DynamicGenerationSchema, minimumElements: Int? = nil, maximumElements: Int? = nil)
    init<Value: Generable>(type: Value.Type, guides: [GenerationGuide<Value>] = [])
    init(referenceTo name: String)
    struct Property { init(name: String, description: String? = nil, schema: DynamicGenerationSchema, isOptional: Bool = false) }
}

struct GenerationGuide<Value> {
    // String
    static func constant(_ value: String) -> GenerationGuide<String>
    static func anyOf(_ values: [String]) -> GenerationGuide<String>
    static func pattern<Output>(_ regex: Regex<Output>) -> GenerationGuide<String>
    // Int / Float / Double / Decimal
    static func minimum(_ value: Value) -> GenerationGuide<Value>
    static func maximum(_ value: Value) -> GenerationGuide<Value>
    static func range(_ range: ClosedRange<Value>) -> GenerationGuide<Value>
    // Array<Element>
    static func minimumCount<Element>(_ count: Int) -> GenerationGuide<[Element]>
    static func maximumCount<Element>(_ count: Int) -> GenerationGuide<[Element]>
    static func count<Element>(_ range: ClosedRange<Int>) -> GenerationGuide<[Element]>
    static func count<Element>(_ count: Int) -> GenerationGuide<[Element]>
    static func element<Element>(_ guide: GenerationGuide<Element>) -> GenerationGuide<[Element]>
}

struct GenerationOptions: Sendable, Equatable {
    var sampling: SamplingMode?
    var temperature: Double?
    var maximumResponseTokens: Int?
    init(sampling: SamplingMode? = nil, temperature: Double? = nil, maximumResponseTokens: Int? = nil)
    struct SamplingMode: Sendable, Equatable {
        static var greedy: SamplingMode { get }
        static func random(top k: Int, seed: UInt64? = nil) -> SamplingMode
        static func random(probabilityThreshold: Double, seed: UInt64? = nil) -> SamplingMode
    }
}
```

### `Transcript`
`RandomAccessCollection` of `Entry`. Entry cases: `.instructions`, `.prompt`,
`.toolCalls`, `.toolOutput`, `.response` — each wraps a matching struct
(`Transcript.Instructions`, `Transcript.Prompt`, `Transcript.ToolCalls`,
`Transcript.ToolOutput`, `Transcript.Response`). `Segment` is `.text(TextSegment)`
or `.structure(StructuredSegment)`. `Transcript` is `Codable`.

---

## Speech

### `SpeechAnalyzer`
```swift
final actor SpeechAnalyzer: Sendable {
    init(modules: [any SpeechModule], options: Options? = nil)
    init<InputSequence: Sendable & AsyncSequence>(
        inputSequence: InputSequence, modules: [any SpeechModule], options: Options? = nil,
        analysisContext: AnalysisContext = .init(),
        volatileRangeChangedHandler: sending ((CMTimeRange, Bool, Bool) -> Void)? = nil
    ) where InputSequence.Element == AnalyzerInput
    init(inputAudioFile: AVAudioFile, modules: [any SpeechModule], options: Options? = nil,
         analysisContext: AnalysisContext = .init(), finishAfterFile: Bool = false,
         volatileRangeChangedHandler: sending ((CMTimeRange, Bool, Bool) -> Void)? = nil) async throws

    func prepareToAnalyze(in audioFormat: AVAudioFormat?) async throws
    func setModules(_ newModules: [any SpeechModule]) async throws
    var modules: [any SpeechModule] { get }

    func start<InputSequence>(inputSequence: InputSequence) async throws
    func start(inputAudioFile: AVAudioFile, finishAfterFile: Bool = false) async throws
    func analyzeSequence<InputSequence>(_ inputSequence: InputSequence) async throws -> CMTime?
    func analyzeSequence(from audioFile: AVAudioFile) async throws -> CMTime?

    func finalize(through: CMTime?) async throws
    func finalizeAndFinishThroughEndOfInput() async throws
    func finalizeAndFinish(through: CMTime) async throws
    func finish(after: CMTime) async throws
    func cancelAnalysis(before: CMTime)
    func cancelAndFinishNow() async

    var volatileRange: CMTimeRange? { get }
    var context: AnalysisContext { get async }
    func setContext(_ newContext: AnalysisContext) async throws

    static func bestAvailableAudioFormat(compatibleWith modules: [any SpeechModule]) async -> AVAudioFormat?
    static func bestAvailableAudioFormat(compatibleWith modules: [any SpeechModule], considering naturalFormat: AVAudioFormat?) async -> AVAudioFormat?

    struct Options: Sendable, Equatable {
        let priority: TaskPriority
        let modelRetention: ModelRetention  // .whileInUse / .lingering / .processLifetime
    }
}
```
`SpeechAnalyzer` is an **actor**, not a class — calls from outside its
isolation domain must `await`.

### `SpeechTranscriber` (live/streaming transcription)
```swift
final class SpeechTranscriber: SpeechModule, LocaleDependentSpeechModule {
    convenience init(locale: Locale, preset: Preset)
    convenience init(locale: Locale, transcriptionOptions: Set<TranscriptionOption>, reportingOptions: Set<ReportingOption>, attributeOptions: Set<ResultAttributeOption>)

    static var isAvailable: Bool { get }
    static var supportedLocales: [Locale] { get async }
    static var installedLocales: [Locale] { get async }
    static func supportedLocale(equivalentTo locale: Locale) async -> Locale?
    var selectedLocales: [Locale] { get }
    var availableCompatibleAudioFormats: [AVAudioFormat] { get async }
    var results: some Sendable & AsyncSequence<Result, any Error> { get }

    struct Preset: Sendable, Equatable, Hashable {
        static let transcription, transcriptionWithAlternatives,
                   timeIndexedTranscriptionWithAlternatives, progressiveTranscription,
                   timeIndexedProgressiveTranscription: Preset
    }
    enum TranscriptionOption: CaseIterable { case etiquetteReplacements }
    enum ReportingOption: CaseIterable { case volatileResults, alternativeTranscriptions, fastResults }
    enum ResultAttributeOption: CaseIterable { case audioTimeRange, transcriptionConfidence }

    struct Result: SpeechModuleResult, Sendable, CustomStringConvertible, Equatable, Hashable {
        let range: CMTimeRange
        let resultsFinalizationTime: CMTime
        var text: AttributedString { get }
        let alternatives: [AttributedString]
    }
}
```

### `DictationTranscriber` (dictation-tuned, on-device only)
Same shape as `SpeechTranscriber` but with `Preset`s `.phrase`,
`.shortDictation`, `.progressiveShortDictation`, `.longDictation`,
`.progressiveLongDictation`, `.timeIndexedLongDictation`; `ContentHint`
(`.shortForm`, `.farField`, `.atypicalSpeech`,
`.customizedLanguage(modelConfiguration:)`); `TranscriptionOption` adds
`.punctuation`, `.emoji`, `.etiquetteReplacements`; `ReportingOption` adds
`.frequentFinalization`.
```swift
convenience init(locale: Locale, preset: Preset)
convenience init(locale: Locale, contentHints: Set<ContentHint>, transcriptionOptions: Set<TranscriptionOption>, reportingOptions: Set<ReportingOption>, attributeOptions: Set<ResultAttributeOption>)
```

### `SpeechDetector` (voice activity detection)
```swift
final class SpeechDetector: SpeechModule {
    init(detectionOptions: DetectionOptions, reportResults: Bool)
    convenience init()   // defaults
    struct DetectionOptions: Sendable, Equatable, Hashable { let sensitivityLevel: SensitivityLevel }
    enum SensitivityLevel: Int, CaseIterable { case low, medium, high }
    var results: some Sendable & AsyncSequence<Result, any Error> { get }
    struct Result: SpeechModuleResult, Sendable, CustomStringConvertible {
        let range: CMTimeRange
        let resultsFinalizationTime: CMTime
        let speechDetected: Bool
    }
}
```

### `AssetInventory`
```swift
enum AssetInventory {  // final class in interface, but only static members
    static var maximumReservedLocales: Int { get }
    static var reservedLocales: [Locale] { get async }
    static func reserve(locale: Locale) async throws -> Bool
    static func release(reservedLocale: Locale) async -> Bool
    static func status(forModules modules: [any SpeechModule]) async -> Status  // .unsupported/.supported/.downloading/.installed
    static func assetInstallationRequest(supporting modules: [any SpeechModule]) async throws -> AssetInstallationRequest?
}
final class AssetInstallationRequest: NSObject, ProgressReporting, Sendable {
    var progress: Progress { get }
    func downloadAndInstall() async throws
}
```

### Input plumbing
```swift
struct AnalyzerInput: @unchecked Sendable {
    init(buffer: AVAudioPCMBuffer)
    init(buffer: AVAudioPCMBuffer, bufferStartTime: CMTime?)
}
final class AnalysisContext: Sendable {
    init()
    var contextualStrings: [ContextualStringsTag: [String]] { get set }
    var userData: [UserDataTag: any Sendable] { get set }
}
```
`AttributedString` results carry `.transcriptionConfidence` and
`.audioTimeRange` custom attributes via `AttributeScopes.SpeechAttributes`
(access with `attrString[range].transcriptionConfidence` style dynamic
member lookup once you `import Speech`).

---

## NaturalLanguage — `NLContextualEmbedding`

**This framework is Objective-C**, imported into Swift via the standard
factory-method-to-initializer convention. There is no `.swiftinterface`; the
signatures below are the Swift-side shape the Clang importer produces from
`NLContextualEmbedding.h`. `-init` itself is `NS_UNAVAILABLE`.

```swift
class NLContextualEmbedding: NSObject {
    // + contextualEmbeddingWithModelIdentifier: → failable init
    convenience init?(modelIdentifier: String)
    // + contextualEmbeddingWithLanguage: → failable init
    convenience init?(language: NLLanguage)
    // + contextualEmbeddingWithScript: → failable init
    convenience init?(script: NLScript)
    static func contextualEmbeddings(for values: [NLContextualEmbeddingKey: Any]) -> [NLContextualEmbedding]

    var modelIdentifier: String { get }
    var languages: [NLLanguage] { get }
    var scripts: [NLScript] { get }
    var revision: Int { get }         // NSUInteger
    var dimension: Int { get }        // NSUInteger — length of each token vector
    var maximumSequenceLength: Int { get }  // NSUInteger — token limit; longer input is truncated

    func load() throws               // -loadWithError:
    func unload()

    func embeddingResult(for string: String, language: NLLanguage?) throws -> NLContextualEmbeddingResult

    var hasAvailableAssets: Bool { get }
    // -requestEmbeddingAssetsWithCompletionHandler: has an async overlay:
    func requestAssets() async throws -> AssetsResult
    enum AssetsResult: Int { case available, notAvailable, error }
}

class NLContextualEmbeddingResult: NSObject {
    var string: String { get }
    var language: NLLanguage { get }
    var sequenceLength: Int { get }   // number of subword-token vectors produced
    // both are NS_REFINED_FOR_SWIFT in the header — the exact overlay
    // signature isn't visible from the header alone; verify against current
    // Apple documentation before relying on parameter order/types:
    //   enumerateTokenVectorsInRange:usingBlock:  (NSRange, block)
    //   tokenVectorAtIndex:tokenRange:            (NSUInteger, NSRangePointer)
}
```
Supported languages/scripts as of iOS 17/18 SDKs (per header doc comments):
Latin, Cyrillic, CJK, Arabic, Indic, Thai script families — check
`.languages`/`.scripts` on the concrete instance rather than assuming
coverage. `NLContextualEmbedding` embeds at the **subword-token** level, not
whole words — pool/aggregate vectors yourself if you need word- or
sentence-level representations.
