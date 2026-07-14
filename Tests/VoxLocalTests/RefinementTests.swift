import XCTest
@testable import VoxLocalCore

/// Configurable mock provider (the third provider required by the spec).
final class MockRefinementProvider: TextRefinementProvider, @unchecked Sendable {
    enum Behavior {
        case succeed(String)
        case fail(Error)
        case hang(seconds: Double, then: String)
    }
    var behavior: Behavior
    private(set) var receivedTranscripts: [String] = []
    private(set) var receivedContexts: [RefinementContext] = []

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func refine(_ transcript: String, context: RefinementContext) async throws -> String {
        receivedTranscripts.append(transcript)
        receivedContexts.append(context)
        switch behavior {
        case .succeed(let text):
            return text
        case .fail(let error):
            throw error
        case .hang(let seconds, let then):
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return then
        }
    }

    func checkAvailability() async -> RefinementAvailability { .available }
}

final class RefinementPromptTests: XCTestCase {
    private func context(_ preset: RefinementPreset, custom: String? = nil, language: String? = "ru") -> RefinementContext {
        RefinementContext(language: language, preset: preset, customInstruction: custom)
    }

    func testBaseRulesPresentInEveryPreset() {
        for preset in RefinementPreset.allCases where preset != .rawTranscript {
            let prompt = RefinementPromptBuilder.systemPrompt(for: context(preset))
            XCTAssertTrue(prompt.contains("NEVER add new facts"), "\(preset) must keep no-new-facts rule")
            XCTAssertTrue(prompt.contains("Do not translate"), "\(preset) must preserve language")
            XCTAssertTrue(prompt.contains("Preserve names, numbers"), "\(preset) must preserve entities")
            XCTAssertTrue(prompt.contains("Output ONLY the corrected text"), "\(preset) must forbid commentary")
        }
    }

    func testPresetSpecificInstructions() {
        XCTAssertTrue(RefinementPromptBuilder.systemPrompt(for: context(.concise)).contains("concise"))
        XCTAssertTrue(RefinementPromptBuilder.systemPrompt(for: context(.businessStyle)).contains("business tone"))
        XCTAssertTrue(RefinementPromptBuilder.systemPrompt(for: context(.preserveSpokenWording)).contains("exact wording"))
    }

    func testCustomInstructionIncluded() {
        let prompt = RefinementPromptBuilder.systemPrompt(for: context(.custom, custom: "Разбей на абзацы"))
        XCTAssertTrue(prompt.contains("Разбей на абзацы"))
        XCTAssertTrue(prompt.contains("must not override"))
    }

    func testLanguageHintIncluded() {
        let prompt = RefinementPromptBuilder.systemPrompt(for: context(.cleanDictation, language: "ru"))
        XCTAssertTrue(prompt.contains("\"ru\""))
    }

    func testUserPromptIsBareTranscript() {
        XCTAssertEqual(RefinementPromptBuilder.userPrompt(transcript: "привет мир"), "привет мир")
    }
}

final class RefinementSafeguardTests: XCTestCase {
    private let original = "мы договорились созвониться завтра в десять утра и обсудить бюджет проекта на следующий квартал"

    func testEmptyResultRejected() {
        XCTAssertEqual(
            RefinementSafeguard.validate(original: original, refined: "   \n "),
            .rejected(reason: "empty refinement result"))
    }

    func testGoodRefinementAccepted() {
        let refined = "Мы договорились созвониться завтра в 10 утра и обсудить бюджет проекта на следующий квартал."
        guard case .accepted(let text) = RefinementSafeguard.validate(original: original, refined: refined) else {
            return XCTFail("expected acceptance")
        }
        XCTAssertEqual(text, refined)
    }

    func testMuchLongerResultRejected() {
        let bloated = original + String(repeating: " и ещё много выдуманных подробностей", count: 20)
        guard case .rejected = RefinementSafeguard.validate(original: original, refined: bloated) else {
            return XCTFail("expected rejection of bloated output")
        }
    }

    func testDissimilarResultRejected() {
        let unrelated = "The quarterly weather report shows sunny skies across the entire region tomorrow morning"
        guard case .rejected = RefinementSafeguard.validate(original: original, refined: unrelated) else {
            return XCTFail("expected rejection of unrelated output")
        }
    }

    func testLLMMetaResponseRejected() {
        for meta in ["As an AI, I cannot edit this.", "Я не могу обработать этот текст.", "Вот исправленный текст: привет"] {
            guard case .rejected = RefinementSafeguard.validate(original: original, refined: meta) else {
                return XCTFail("expected rejection of meta response: \(meta)")
            }
        }
    }

    func testShortTextsSkipSimilarityCheck() {
        // 4 words — similarity check must not reject a legitimate rewrite.
        guard case .accepted = RefinementSafeguard.validate(original: "ну привет как дела", refined: "Привет! Как дела?") else {
            return XCTFail("short text should pass")
        }
    }
}

final class RefinementPipelineTests: XCTestCase {
    private let context = RefinementContext(language: "ru", preset: .cleanDictation, timeout: 1)
    private let transcript = "ну это самое мы хотели обсудить бюджет проекта завтра утром после созвона с командой"

    func testSuccessfulRefinementUsed() async {
        let provider = MockRefinementProvider(behavior: .succeed(
            "Мы хотели обсудить бюджет проекта завтра утром после созвона с командой."))
        let outcome = await RefinementPipeline(provider: provider).refine(transcript, context: context)
        XCTAssertFalse(outcome.usedFallback)
        XCTAssertTrue(outcome.text.hasPrefix("Мы хотели"))
    }

    func testProviderErrorFallsBackToRaw() async {
        let provider = MockRefinementProvider(behavior: .fail(RefinementError.unavailable("connection refused")))
        let outcome = await RefinementPipeline(provider: provider).refine(transcript, context: context)
        XCTAssertTrue(outcome.usedFallback)
        XCTAssertEqual(outcome.text, transcript)
    }

    func testTimeoutFallsBackToRaw() async {
        let provider = MockRefinementProvider(behavior: .fail(RefinementError.timeout))
        let outcome = await RefinementPipeline(provider: provider).refine(transcript, context: context)
        XCTAssertTrue(outcome.usedFallback)
        XCTAssertEqual(outcome.text, transcript)
        XCTAssertEqual(outcome.fallbackReason, "timeout")
    }

    func testInvalidOutputFallsBackToRaw() async {
        let provider = MockRefinementProvider(behavior: .succeed(""))
        let outcome = await RefinementPipeline(provider: provider).refine(transcript, context: context)
        XCTAssertTrue(outcome.usedFallback)
        XCTAssertEqual(outcome.text, transcript)
    }

    func testRawPresetSkipsProviderEntirely() async {
        let provider = MockRefinementProvider(behavior: .fail(RefinementError.unavailable("must not be called")))
        let rawContext = RefinementContext(language: nil, preset: .rawTranscript)
        let outcome = await RefinementPipeline(provider: provider).refine(transcript, context: rawContext)
        XCTAssertFalse(outcome.usedFallback)
        XCTAssertEqual(outcome.text, transcript)
        XCTAssertTrue(provider.receivedTranscripts.isEmpty)
    }

    func testCancellationFallsBackToRaw() async {
        let provider = MockRefinementProvider(behavior: .hang(seconds: 5, then: "late"))
        let pipeline = RefinementPipeline(provider: provider)
        let task = Task {
            await pipeline.refine(transcript, context: context)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let outcome = await task.value
        XCTAssertTrue(outcome.usedFallback)
        XCTAssertEqual(outcome.text, transcript)
    }
}

final class OllamaProviderTests: XCTestCase {
    func testNonLocalEndpointRejected() {
        for endpoint in ["http://example.com:11434", "https://8.8.8.8:11434", "http://my-server.local:11434"] {
            XCTAssertThrowsError(try OllamaRefinementProvider(endpoint: endpoint, model: "m")) { error in
                guard case RefinementError.nonLocalEndpoint = error else {
                    return XCTFail("expected nonLocalEndpoint for \(endpoint)")
                }
            }
        }
    }

    func testLoopbackEndpointsAccepted() throws {
        for endpoint in ["http://127.0.0.1:11434", "http://localhost:11434", "http://[::1]:11434"] {
            XCTAssertNoThrow(try OllamaRefinementProvider(endpoint: endpoint, model: "m"), "should accept \(endpoint)")
        }
    }

    func testRequestBodyConstruction() throws {
        let context = RefinementContext(language: "ru", preset: .cleanDictation, timeout: 20)
        let body = try OllamaRefinementProvider.requestBody(model: "qwen2.5:3b", transcript: "привет мир", context: context)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]

        XCTAssertEqual(json["model"] as? String, "qwen2.5:3b")
        XCTAssertEqual(json["stream"] as? Bool, false)
        let messages = json["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertTrue((messages[0]["content"] as! String).contains("NEVER add new facts"))
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "привет мир")
        let options = json["options"] as! [String: Any]
        XCTAssertNotNil(options["temperature"])
        XCTAssertNotNil(options["num_predict"])
    }
}
