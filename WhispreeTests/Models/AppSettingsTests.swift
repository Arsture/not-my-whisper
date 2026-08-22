import XCTest
@testable import Whispree

@MainActor
final class AppSettingsTests: XCTestCase {
    private static let suiteName = "com.whispree.app.tests.AppSettings"
    private var defaults: UserDefaults?

    private var store: UserDefaults {
        guard let defaults else {
            preconditionFailure("AppSettingsTests store accessed before setUp")
        }
        return defaults
    }

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)
        store.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: Self.suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(store: store, migrateHotkeys: false)
    }

    // MARK: - Default Values

    func testDefaultSTTProvider() {
        let settings = makeSettings()
        XCTAssertEqual(settings.sttProviderType, .whisperKit)
    }

    func testDefaultLLMProvider() {
        let settings = makeSettings()
        XCTAssertEqual(settings.llmProviderType, .none)
    }

    func testDefaultOpenAIModel() {
        let settings = makeSettings()
        XCTAssertEqual(settings.openaiModel, .gpt56sol)
    }

    func testDefaultLLMEnabled() {
        let settings = makeSettings()
        // 기본값은 `true` — 사용자가 명시적으로 끄기 전까지 교정 활성화가 의도.
        XCTAssertTrue(settings.isLLMEnabled)
    }

    func testDefaultDomainWordSetsEmpty() {
        let settings = makeSettings()
        XCTAssertTrue(settings.domainWordSets.isEmpty)
    }

    // MARK: - Provider Types

    func testSTTProviderTypeCases() {
        XCTAssertEqual(STTProviderType.allCases.count, 3)
        XCTAssertEqual(STTProviderType.whisperKit.rawValue, "WhisperKit")
        XCTAssertEqual(STTProviderType.groq.rawValue, "Groq")
        XCTAssertEqual(STTProviderType.mlxAudio.rawValue, "MLX Audio")
    }

    func testLLMProviderTypeCases() {
        XCTAssertEqual(LLMProviderType.allCases.count, 5)
        XCTAssertEqual(LLMProviderType.none.rawValue, "없음 (원문 사용)")
        XCTAssertEqual(LLMProviderType.local.rawValue, "로컬 MLX")
        XCTAssertEqual(LLMProviderType.openai.rawValue, "OpenAI (GPT)")
        XCTAssertEqual(LLMProviderType.openaiCompatible.rawValue, "OpenAI 호환 API")
        XCTAssertEqual(LLMProviderType.groq.rawValue, "Groq Cloud")
    }

    func testDefaultOpenAICompatibleSettings() {
        let settings = makeSettings()
        XCTAssertEqual(settings.openaiCompatibleBaseURL, "")
        XCTAssertEqual(settings.openaiCompatibleAPIKey, "")
        XCTAssertEqual(settings.openaiCompatibleModelId, "")
        XCTAssertFalse(settings.openaiCompatibleSupportsVision)
    }

    // MARK: - OpenAI Models

    func testOpenAIModelDefaults() {
        XCTAssertEqual(OpenAIModel.gpt56sol.rawValue, "gpt-5.6-sol")
        XCTAssertEqual(OpenAIModel.gpt56terra.rawValue, "gpt-5.6-terra")
        XCTAssertEqual(OpenAIModel.gpt56luna.rawValue, "gpt-5.6-luna")
        XCTAssertEqual(OpenAIModel.gpt55.rawValue, "gpt-5.5")
        XCTAssertEqual(OpenAIModel.gpt54.rawValue, "gpt-5.4")
        XCTAssertEqual(OpenAIModel.gpt54mini.rawValue, "gpt-5.4-mini")
        XCTAssertEqual(OpenAIModel.gpt53codex.rawValue, "gpt-5.3-codex")
        XCTAssertEqual(OpenAIModel.gpt52.rawValue, "gpt-5.2")
        XCTAssertEqual(OpenAIModel.allCases.map(\.rawValue), [
            "gpt-5.6-sol",
            "gpt-5.6-terra",
            "gpt-5.6-luna",
            "gpt-5.5",
            "gpt-5.4",
            "gpt-5.4-mini",
            "gpt-5.3-codex",
            "gpt-5.2",
        ])
    }

    func testOpenAIModelDisplayNames() {
        XCTAssertTrue(OpenAIModel.gpt56sol.displayName.contains("Latest"))
        XCTAssertTrue(OpenAIModel.gpt56luna.displayName.contains("Fast"))
        XCTAssertTrue(OpenAIModel.gpt54mini.displayName.contains("Fast"))
    }

    func testOpenAIModelAliasMigration() {
        store.set("gpt-5.3-codex-spark", forKey: "whispree.openaiModel")
        XCTAssertEqual(makeSettings().openaiModel, .gpt54mini)

        store.set("gpt-5.2-codex", forKey: "whispree.openaiModel")
        XCTAssertEqual(makeSettings().openaiModel, .gpt52)

        store.set("gpt-5.6", forKey: "whispree.openaiModel")
        XCTAssertEqual(makeSettings().openaiModel, .gpt56sol)

        let decoded = try? JSONDecoder().decode(OpenAIModel.self, from: Data(#""gpt-5.2-codex""#.utf8))
        XCTAssertEqual(decoded, .gpt52)

        let decodedAlias = try? JSONDecoder().decode(OpenAIModel.self, from: Data(#""gpt-5.6""#.utf8))
        XCTAssertEqual(decodedAlias, .gpt56sol)
    }

    // MARK: - CorrectionPrompts Routing

    func testPromptRoutingAutoUsesCodeSwitch() {
        let prompt = CorrectionPrompts.prompt(for: .standard, language: .auto)
        XCTAssertTrue(prompt.contains("코드스위칭") || prompt.contains("영어 단어"),
                      "Auto mode should use code-switching prompt")
    }

    func testPromptRoutingKorean() {
        let prompt = CorrectionPrompts.prompt(for: .standard, language: .korean)
        XCTAssertTrue(prompt.contains("한국어") || prompt.contains("STT"),
                      "Korean mode should use Korean-language prompt")
    }

    func testPromptRoutingCustomUsesCodeSwitch() {
        let prompt = CorrectionPrompts.prompt(for: .custom, language: .auto)
        XCTAssertTrue(prompt.contains("코드스위칭") || prompt.contains("영어 단어"),
                      "Custom mode should default to code-switching prompt")
    }

    func testCodeSwitchPromptContainsExamples() {
        let prompt = CorrectionPrompts.codeSwitchPrompt
        XCTAssertTrue(prompt.contains("validation"))
        XCTAssertTrue(prompt.contains("React"))
        XCTAssertTrue(prompt.contains("GitHub"))
        XCTAssertTrue(prompt.contains("T-distribution"))
    }

    // MARK: - Correction Modes

    func testCorrectionModeFillerRemoval() {
        XCTAssertEqual(CorrectionMode.fillerRemoval.rawValue, "fillerRemoval")
        XCTAssertFalse(CorrectionMode.fillerRemoval.displayName.isEmpty)
        XCTAssertFalse(CorrectionMode.fillerRemoval.description.isEmpty)
    }

    func testCorrectionModeStructured() {
        XCTAssertEqual(CorrectionMode.structured.rawValue, "structured")
        XCTAssertFalse(CorrectionMode.structured.displayName.isEmpty)
        XCTAssertFalse(CorrectionMode.structured.description.isEmpty)
    }

    func testCorrectionModeCount() {
        XCTAssertEqual(CorrectionMode.allCases.count, 4,
                       "Should have standard, fillerRemoval, structured, custom")
    }

    func testPromptRoutingFillerRemoval() {
        let prompt = CorrectionPrompts.prompt(for: .fillerRemoval, language: .auto)
        XCTAssertTrue(prompt.contains("필러"),
                      "Filler removal mode should mention fillers")
        XCTAssertTrue(prompt.contains("문장 순서 변경 금지"),
                      "Filler removal should preserve sentence order")
    }

    func testPromptRoutingStructured() {
        let prompt = CorrectionPrompts.prompt(for: .structured, language: .auto)
        XCTAssertTrue(prompt.contains("구조화"),
                      "Structured mode should mention structuring")
        XCTAssertTrue(prompt.contains("절대 삭제하지 않음"),
                      "Structured mode should preserve content")
    }

    func testPromptEngineeringMigration() throws {
        // Simulate old "promptEngineering" value stored in JSON
        let json = #"{"correctionMode":"promptEngineering"}"#
        let data = json.data(using: .utf8)!

        struct TestWrapper: Codable {
            var correctionMode: CorrectionMode
        }

        let decoded = try JSONDecoder().decode(TestWrapper.self, from: data)
        XCTAssertEqual(decoded.correctionMode, .fillerRemoval,
                       "Old promptEngineering should migrate to fillerRemoval")
    }

    // MARK: - Wrapper persistence

    func testWrapperPersistenceAcrossInstances() {
        let s1 = makeSettings()
        s1.groqApiKey = "gsk_test_123"
        s1.audioInputChannel = 2
        s1.openaiModel = .gpt54mini
        s1.recordingMode = .toggle
        s1.openaiCompatibleBaseURL = "http://localhost:11434/v1"
        s1.openaiCompatibleAPIKey = "compat-key"
        s1.openaiCompatibleModelId = "local-model"
        s1.openaiCompatibleSupportsVision = true

        // 새 인스턴스는 UserDefaults에서 직접 읽어 동일한 값이어야 함 — 싱글톤 없이도 필드별 persist.
        let s2 = makeSettings()
        XCTAssertEqual(s2.groqApiKey, "gsk_test_123")
        XCTAssertEqual(s2.audioInputChannel, 2)
        XCTAssertEqual(s2.openaiModel, .gpt54mini)
        XCTAssertEqual(s2.recordingMode, .toggle)
        XCTAssertEqual(s2.openaiCompatibleBaseURL, "http://localhost:11434/v1")
        XCTAssertEqual(s2.openaiCompatibleAPIKey, "compat-key")
        XCTAssertEqual(s2.openaiCompatibleModelId, "local-model")
        XCTAssertTrue(s2.openaiCompatibleSupportsVision)
    }

    func testInjectedStoreDoesNotMutateAnotherDefaultsDomain() {
        let otherSuiteName = "com.whispree.app.tests.ProductionSurrogate"
        guard let otherStore = UserDefaults(suiteName: otherSuiteName) else {
            XCTFail("Could not create production surrogate defaults")
            return
        }
        defer { otherStore.removePersistentDomain(forName: otherSuiteName) }

        otherStore.set("production-key", forKey: "whispree.groqApiKey")
        otherStore.set(true, forKey: "whispree.hasCompletedOnboarding")

        let settings = makeSettings()
        settings.groqApiKey = "test-key"
        settings.hasCompletedOnboarding = false

        XCTAssertEqual(store.string(forKey: "whispree.groqApiKey"), "test-key")
        XCTAssertEqual(otherStore.string(forKey: "whispree.groqApiKey"), "production-key")
        XCTAssertTrue(otherStore.bool(forKey: "whispree.hasCompletedOnboarding"))
    }

    func testCustomLLMPromptOptionalNilRoundTrip() {
        let s1 = makeSettings()
        s1.customLLMPrompt = "my custom prompt"
        XCTAssertEqual(makeSettings().customLLMPrompt, "my custom prompt")

        // nil 할당 시 wrapper가 removeObject 호출 → 새 인스턴스에서 default(nil) 복구
        s1.customLLMPrompt = nil
        XCTAssertNil(makeSettings().customLLMPrompt)
    }

    func testDomainWordSetsCodablePersistence() {
        let s1 = makeSettings()
        var sets = s1.domainWordSets
        sets.append(DomainWordSet(name: "Unit Test", words: ["alpha", "beta"]))
        s1.domainWordSets = sets

        let s2 = makeSettings()
        XCTAssertEqual(s2.domainWordSets.count, 1)
        XCTAssertEqual(s2.domainWordSets.first?.name, "Unit Test")
        XCTAssertEqual(s2.domainWordSets.first?.words, ["alpha", "beta"])
    }

    // MARK: - Migration

    func testCorrectionModeAliasMigration() {
        store.set("promptEngineering", forKey: "whispree.correctionMode")
        let settings = makeSettings()
        XCTAssertEqual(settings.correctionMode, .fillerRemoval)
    }

    func testLLMProviderTypeAliasMigration() {
        store.set("로컬 LLM (Qwen3)", forKey: "whispree.llmProviderType")
        let settings = makeSettings()
        XCTAssertEqual(settings.llmProviderType, .local)
    }

    func testLegacyBlobMigration() throws {
        // Given: 기존 "WhispreeSettings" JSON blob만 존재
        let json: [String: Any] = [
            "recordingMode": "toggle",
            "language": "en",
            "isLLMEnabled": false,
            "hasCompletedOnboarding": true,
            "launchAtLogin": true,
            "showOverlay": false,
            "correctionMode": "fillerRemoval",
            "customLLMPrompt": "legacy custom",
            "whisperModelId": "legacy-whisper",
            "llmModelId": "legacy-llm",
            "mlxAudioModelId": "legacy-mlx",
            "sttProviderType": "Groq",
            "llmProviderType": "OpenAI (GPT)",
            "openaiModel": "gpt-5.4-mini",
            "isScreenshotContextEnabled": true,
            "isScreenshotPasteEnabled": false,
            "groqApiKey": "gsk_legacy",
            "openaiCompatibleBaseURL": "https://compat.example/v1",
            "openaiCompatibleAPIKey": "compat_legacy",
            "openaiCompatibleModelId": "legacy-model",
            "openaiCompatibleSupportsVision": true,
            "audioInputChannel": 3,
            "vadEnabled": false,
            "domainWordSets": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        store.set(data, forKey: "WhispreeSettings")

        // When: 격리 store를 사용하는 AppSettings 인스턴스 생성
        let settings = makeSettings()

        // Then: 모든 필드가 wrapper 키에서 읽혀야 하고, blob은 삭제돼야 함
        XCTAssertEqual(settings.recordingMode, .toggle)
        XCTAssertEqual(settings.language, .english)
        XCTAssertFalse(settings.isLLMEnabled)
        XCTAssertTrue(settings.hasCompletedOnboarding)
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertFalse(settings.showOverlay)
        XCTAssertEqual(settings.correctionMode, .fillerRemoval)
        XCTAssertEqual(settings.customLLMPrompt, "legacy custom")
        XCTAssertEqual(settings.whisperModelId, "legacy-whisper")
        // llmModelId: legacy-llm은 "Qwen2.5"를 포함하지 않으므로 runFieldMigrations 영향 없음
        XCTAssertEqual(settings.llmModelId, "legacy-llm")
        XCTAssertEqual(settings.mlxAudioModelId, "legacy-mlx")
        XCTAssertEqual(settings.sttProviderType, .groq)
        XCTAssertEqual(settings.llmProviderType, .openai)
        XCTAssertEqual(settings.openaiModel, .gpt54mini)
        XCTAssertTrue(settings.isScreenshotContextEnabled)
        // 활성화 ON + 전달 OFF → 독립 토글이므로 값 유지
        XCTAssertFalse(settings.isScreenshotPasteEnabled)
        XCTAssertEqual(settings.groqApiKey, "gsk_legacy")
        XCTAssertEqual(settings.openaiCompatibleBaseURL, "https://compat.example/v1")
        XCTAssertEqual(settings.openaiCompatibleAPIKey, "compat_legacy")
        XCTAssertEqual(settings.openaiCompatibleModelId, "legacy-model")
        XCTAssertTrue(settings.openaiCompatibleSupportsVision)
        XCTAssertEqual(settings.audioInputChannel, 3)
        XCTAssertFalse(settings.vadEnabled)

        XCTAssertNil(store.data(forKey: "WhispreeSettings"),
                     "Legacy blob should be removed after successful migration")
    }

    func testLegacyBlobQwen25Migration() throws {
        // 구 Qwen2.5 모델 ID는 runFieldMigrations에서 Qwen3 기본값으로 승격되어야 함
        let json: [String: Any] = [
            "llmModelId": "mlx-community/Qwen2.5-3B-Instruct-4bit",
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        store.set(data, forKey: "WhispreeSettings")

        let settings = makeSettings()
        XCTAssertEqual(settings.llmModelId, "mlx-community/Qwen3-4B-Instruct-2507-4bit")
    }

    func testLegacyBlobCorruptedFailsGracefully() {
        // 깨진 JSON blob → migration 실패 플래그 설정, 기본값 사용, 재시도 방지
        store.set(Data("not json".utf8), forKey: "WhispreeSettings")

        let settings = makeSettings()
        XCTAssertEqual(settings.sttProviderType, .whisperKit, "Should fall back to defaults")
        XCTAssertTrue(store.bool(forKey: "whispree.legacyMigrationFailed"),
                      "Migration failure flag should be set")
    }
}
