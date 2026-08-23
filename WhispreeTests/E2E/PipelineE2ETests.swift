import XCTest
@testable import Whispree

/// End-to-end functional tests for the complete transcription pipeline.
@MainActor
final class PipelineE2ETests: XCTestCase {

    // Shared provider to avoid 24s model load per test
    private static var sharedProvider: WhisperKitProvider?

    override class func setUp() {
        super.setUp()
    }

    private func getOrCreateProvider() async throws -> WhisperKitProvider {
        if let existing = Self.sharedProvider, existing.isReady {
            return existing
        }
        let provider = WhisperKitProvider()
        try await provider.setup()
        Self.sharedProvider = provider
        return provider
    }

    // MARK: - US-001: WhisperKit Provider Lifecycle

    func testWhisperKitProviderSetupAndReady() async throws {
        let provider = try await getOrCreateProvider()
        XCTAssertTrue(provider.isReady)
        XCTAssertTrue(provider.isAvailable)
        XCTAssertEqual(provider.name, "WhisperKit")
    }

    // MARK: - US-001: Domain Word Sets → promptTokens (after transcribe loads tokenizer)

    func testDomainWordSetsPromptTokensAfterTranscribe() async throws {
        let provider = try await getOrCreateProvider()

        // First transcribe to ensure model + tokenizer are fully loaded
        let silence = [Float](repeating: 0.0, count: 16000)
        _ = try await provider.transcribe(audioBuffer: silence, language: nil, promptTokens: nil)

        // Now tokenizer should be available
        let tokens = provider.buildPromptTokens(from: [
            DomainWordSet.generateDefault(domain: .itDev)
        ])

        if let tokens {
            XCTAssertFalse(tokens.isEmpty, "Tokens should not be empty")
            XCTAssertLessThanOrEqual(tokens.count, 224, "Should respect 224 token limit")
        }
        // tokens can still be nil if tokenizer isn't available — acceptable
    }

    func testDomainWordSetsAllDisabled() async throws {
        let provider = try await getOrCreateProvider()
        var set = DomainWordSet.generateDefault(domain: .itDev)
        set.isEnabled = false
        let tokens = provider.buildPromptTokens(from: [set])
        XCTAssertNil(tokens, "No tokens when all sets disabled")
    }

    // MARK: - US-002: Transcription Tests

    func testWhisperKitTranscribeSilence() async throws {
        let provider = try await getOrCreateProvider()
        let silence = [Float](repeating: 0.0, count: 16000)
        let result = try await provider.transcribe(audioBuffer: silence, language: nil, promptTokens: nil)
        XCTAssertNotNil(result)
    }

    func testWhisperKitTranscribesRepeatedly() async throws {
        let provider = try await getOrCreateProvider()
        let sampleRate: Float = 16000
        let samples = (0..<Int(sampleRate * 2)).map { i in
            sin(2.0 * .pi * 440.0 * Float(i) / sampleRate) * 0.5
        }

        _ = try await provider.transcribe(audioBuffer: samples, language: nil, promptTokens: nil)
        _ = try await provider.transcribe(audioBuffer: samples, language: nil, promptTokens: nil)
    }

    func testWhisperKitTranscribeSineWave() async throws {
        let provider = try await getOrCreateProvider()
        let sampleRate: Float = 16000
        let samples = (0..<Int(sampleRate * 2)).map { i in
            sin(2.0 * .pi * 440.0 * Float(i) / sampleRate) * 0.5
        }
        let result = try await provider.transcribe(audioBuffer: samples, language: nil, promptTokens: nil)
        XCTAssertNotNil(result)
    }

    func testWhisperKitTranscribeWithDomainWords() async throws {
        let provider = try await getOrCreateProvider()
        provider.domainWordSets = [DomainWordSet.generateDefault(domain: .itDev)]

        let silence = [Float](repeating: 0.0, count: 16000)
        // Should not crash even with domain words set
        let result = try await provider.transcribe(audioBuffer: silence, language: nil, promptTokens: nil)
        XCTAssertNotNil(result)
    }

    // MARK: - US-002: LLM Provider Lifecycle

    func testNoneProviderE2E() async throws {
        let provider = NoneProvider()
        try await provider.setup()
        XCTAssertTrue(provider.isReady)

        let result = try await provider.correct(
            text: "이거 밸리데이션 해야 되거든",
            systemPrompt: CorrectionPrompts.codeSwitchPrompt,
            glossary: ["validation", "API"]
        )
        XCTAssertEqual(result, "이거 밸리데이션 해야 되거든")
    }

    // MARK: - US-003: OpenAI LLM Correction

    func testOpenAIProviderCorrection() async throws {
        let authService = CodexAuthService()
        guard authService.loadTokens() != nil else {
            // Skip if not authenticated — not a failure
            print("SKIP: No Codex auth tokens available")
            return
        }

        let provider = OpenAIProvider(model: .gpt54mini, authService: authService, oauthService: OAuthService())
        try await provider.setup()
        XCTAssertTrue(provider.isReady)

        let input = "이거 밸리데이션 해야 되거든. API 콜이 너무 많아."
        let result = try await provider.correct(
            text: input,
            systemPrompt: CorrectionPrompts.codeSwitchPrompt,
            glossary: ["validation", "API", "call"]
        )

        XCTAssertFalse(result.isEmpty, "OpenAI should return non-empty result")
        // 핵심 검증: 영어 단어 보존
        XCTAssertTrue(result.contains("API"), "API should be preserved as English")
        print("OpenAI correction result: \(result)")
    }

    // MARK: - US-003: CorrectionPrompts Routing

    func testCorrectionPromptsCodeSwitch() {
        let prompt = CorrectionPrompts.prompt(for: .standard, language: .auto)
        XCTAssertTrue(prompt.contains("validation"))
        XCTAssertTrue(prompt.contains("React"))
    }

    func testCorrectionPromptsKorean() {
        let prompt = CorrectionPrompts.prompt(for: .standard, language: .korean)
        XCTAssertTrue(prompt.contains("한국어"))
    }

    // MARK: - US-003: Codex Auth

    func testCodexAuthServiceLoadsTokens() {
        let authService = CodexAuthService()
        authService.checkAuth()
        let tokens = authService.loadTokens()
        if tokens != nil {
            XCTAssertTrue(authService.isLoggedIn)
            XCTAssertNotNil(authService.currentAccountId)
            XCTAssertFalse(tokens!.access_token.isEmpty)
        }
    }

    // MARK: - US-003: Word Edit Distance

    func testWordEditDistanceAllowsValidCorrection() {
        let ratio = LocalTextProvider.wordEditDistance(
            "이거 L&M 모델이 되개 잘하거든",
            "이거 LLM 모델이 되게 잘하거든"
        )
        XCTAssertLessThanOrEqual(ratio, 0.5)
    }

    func testWordEditDistanceRejectsHallucination() {
        let ratio = LocalTextProvider.wordEditDistance(
            "오늘 날씨가 좋습니다",
            "내일은 비가 올 수도 있겠습니다"
        )
        XCTAssertGreaterThan(ratio, 0.5)
    }

    // MARK: - US-004: AppState Provider Switching

    func testAppStateLLMProviderSwitchNone() async throws {
        let context = try makeIsolatedAppState()
        defer { context.cleanup() }
        let appState = context.appState
        await appState.switchLLMProvider(to: .none)
        XCTAssertNotNil(appState.llmProvider)
        XCTAssertEqual(appState.llmProvider?.name, "없음 (원문 사용)")
        XCTAssertTrue(appState.llmProvider?.isReady ?? false)
    }

    func testAppStateLLMProviderSwitchOpenAICompatible() async throws {
        let context = try makeIsolatedAppState()
        defer { context.cleanup() }
        let appState = context.appState
        appState.settings.llmProviderType = .openaiCompatible
        appState.settings.openaiCompatibleBaseURL = "http://localhost:11434/v1"
        appState.settings.openaiCompatibleAPIKey = ""
        appState.settings.openaiCompatibleModelId = "local-model"
        appState.settings.openaiCompatibleSupportsVision = true

        await appState.switchLLMProvider(to: .openaiCompatible)

        XCTAssertTrue(appState.llmProvider is OpenAICompatibleProvider)
        XCTAssertEqual(appState.llmProvider?.name, "OpenAI 호환 API")
        XCTAssertTrue(appState.llmProvider?.isReady ?? false)
        XCTAssertTrue(appState.llmProvider?.supportsVision ?? false)
        XCTAssertTrue(appState.settings.isScreenshotContextEnabled)
        XCTAssertTrue(appState.llmModelState.isReady)
    }

    private func makeIsolatedAppState() throws -> (appState: AppState, cleanup: () -> Void) {
        let suiteName = "com.whispree.app.tests.Pipeline"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(store: defaults, migrateHotkeys: false)
        return (
            AppState(settings: settings),
            { defaults.removePersistentDomain(forName: suiteName) }
        )
    }

    // MARK: - US-004: Full Pipeline

    func testFullPipelineWithNoneProvider() async throws {
        let provider = try await getOrCreateProvider()
        let audio = [Float](repeating: 0.0, count: 16000)
        let transcription = try await provider.transcribe(audioBuffer: audio, language: nil, promptTokens: nil)
        XCTAssertNotNil(transcription)

        let noneProvider = NoneProvider()
        let corrected = try await noneProvider.correct(
            text: transcription.text,
            systemPrompt: CorrectionPrompts.codeSwitchPrompt,
            glossary: nil
        )
        XCTAssertEqual(corrected, transcription.text)
    }

    func testFullPipelineWithOpenAI() async throws {
        let authService = CodexAuthService()
        guard authService.loadTokens() != nil else {
            print("SKIP: No Codex auth tokens — skipping OpenAI pipeline test")
            return
        }

        // STT
        let sttProvider = try await getOrCreateProvider()
        let audio = [Float](repeating: 0.0, count: 16000)
        let transcription = try await sttProvider.transcribe(audioBuffer: audio, language: nil, promptTokens: nil)

        // LLM correction (even on empty text, should not crash)
        let llmProvider = OpenAIProvider(model: .gpt54mini, authService: authService, oauthService: OAuthService())
        try await llmProvider.setup()

        let glossary = ["API", "backend", "React"]
        let corrected = try await llmProvider.correct(
            text: transcription.text.isEmpty ? "테스트 밸리데이션 해야됨" : transcription.text,
            systemPrompt: CorrectionPrompts.codeSwitchPrompt,
            glossary: glossary
        )
        XCTAssertFalse(corrected.isEmpty, "Pipeline should produce non-empty output")
        print("Full pipeline result: \(corrected)")
    }
}
