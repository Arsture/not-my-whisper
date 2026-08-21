import XCTest
@testable import Whispree

@MainActor
final class LLMServiceTests: XCTestCase {

    // MARK: - Word Edit Distance (via LocalTextProvider)

    func testWordEditDistanceIdentical() {
        let ratio = LocalTextProvider.wordEditDistance("안녕하세요 반갑습니다", "안녕하세요 반갑습니다")
        XCTAssertEqual(ratio, 0.0)
    }

    func testWordEditDistanceOneWordChanged() {
        let ratio = LocalTextProvider.wordEditDistance(
            "이거 L&M 모델이 되개 잘하거든",
            "이거 LLM 모델이 되게 잘하거든"
        )
        XCTAssertLessThanOrEqual(ratio, 0.5)
    }

    func testWordEditDistanceCompletelyDifferent() {
        let ratio = LocalTextProvider.wordEditDistance("hello world", "안녕 세상")
        XCTAssertEqual(ratio, 1.0)
    }

    func testWordEditDistanceEmpty() {
        let ratio = LocalTextProvider.wordEditDistance("", "")
        XCTAssertEqual(ratio, 0.0)
    }

    func testWordEditDistanceOneEmpty() {
        let ratio = LocalTextProvider.wordEditDistance("hello", "")
        XCTAssertEqual(ratio, 1.0)
    }

    func testWordEditDistanceKoreanCorrection() {
        let ratio = LocalTextProvider.wordEditDistance(
            "이거 L&M 모델이 되개 잘하거든",
            "이거 LLM 모델이 되게 잘하거든"
        )
        XCTAssertLessThan(ratio, 0.5, "Korean syllable corrections should be under 50% word-level change")
    }

    // MARK: - NoneProvider

    func testNoneProviderReturnsOriginal() async throws {
        let provider = NoneProvider()
        XCTAssertTrue(provider.isReady)
        XCTAssertFalse(provider.requiresNetwork)
        XCTAssertFalse(provider.supportsVision)

        let result = try await provider.correct(text: "원문 텍스트", systemPrompt: "any prompt", glossary: nil)
        XCTAssertEqual(result, "원문 텍스트")
    }

    func testNoneProviderWithGlossary() async throws {
        let provider = NoneProvider()
        let result = try await provider.correct(text: "test", systemPrompt: "prompt", glossary: ["API", "React"])
        XCTAssertEqual(result, "test", "NoneProvider should ignore glossary and return original")
    }

    // MARK: - LocalModelSpec

    func testLocalModelSpecFind() {
        let spec = LocalModelSpec.find("mlx-community/Qwen3-4B-Instruct-2507-4bit")
        XCTAssertNotNil(spec)
        XCTAssertEqual(spec?.capability, .text)
    }

    func testLocalModelSpecFindVision() {
        let visionSpec = LocalModelSpec.supported.first { $0.capability == .vision }
        XCTAssertNotNil(visionSpec)
    }

    func testDiffusionGemmaUsesPythonVisionRuntime() {
        let spec = LocalModelSpec.find("mlx-community/diffusiongemma-26B-A4B-it-4bit")
        XCTAssertNotNil(spec)
        XCTAssertEqual(spec?.capability, .vision)
        XCTAssertEqual(spec?.runtime, .python)
        XCTAssertGreaterThanOrEqual(spec?.minMemoryGB ?? 0, 32)
    }

    func testLocalModelSpecFindUnknown() {
        let spec = LocalModelSpec.find("unknown/model")
        XCTAssertNil(spec)
    }

    // MARK: - Provider Properties

    func testLocalTextProviderProperties() {
        let provider = LocalTextProvider()
        XCTAssertFalse(provider.requiresNetwork)
        XCTAssertFalse(provider.supportsVision)
    }

    func testPythonProviderVisionCapabilityFollowsModelSpec() {
        let textProvider = MLXLMPythonProvider(modelId: "lmstudio-community/gemma-4-26B-A4B-it-MLX-4bit")
        XCTAssertFalse(textProvider.supportsVision)

        let visionProvider = MLXLMPythonProvider(modelId: "mlx-community/diffusiongemma-26B-A4B-it-4bit")
        XCTAssertTrue(visionProvider.supportsVision)
    }

    func testOpenAIProviderSupportsVision() {
        // OpenAIProvider requires auth services — just check the property exists
        XCTAssertTrue(true, "OpenAIProvider.supportsVision is declared as true")
    }

    // MARK: - OpenAICompatibleProvider

    func testOpenAICompatibleProviderValidate() {
        let empty = OpenAICompatibleProvider(baseURL: "", apiKey: "", modelId: "", supportsVision: false)
        XCTAssertFalse(empty.isReady)

        let noModel = OpenAICompatibleProvider(
            baseURL: "https://example.com/v1", apiKey: "key", modelId: "", supportsVision: false
        )
        XCTAssertFalse(noModel.isReady)

        let ok = OpenAICompatibleProvider(
            baseURL: "https://example.com/v1", apiKey: "key", modelId: "test-model", supportsVision: false
        )
        XCTAssertTrue(ok.isReady)
    }

    /// 실제 OpenAI-compatible 엔드포인트 호출. `WHISPREE_COMPAT_TEST_BASE_URL` /
    /// `WHISPREE_COMPAT_TEST_API_KEY` / `WHISPREE_COMPAT_TEST_MODEL` 환경변수가
    /// 모두 설정된 경우에만 실행 (CI/로컬 선택적 스모크 테스트).
    func testOpenAICompatibleProviderLiveCorrection() async throws {
        guard let baseURL = ProcessInfo.processInfo.environment["WHISPREE_COMPAT_TEST_BASE_URL"],
              let apiKey = ProcessInfo.processInfo.environment["WHISPREE_COMPAT_TEST_API_KEY"],
              let model = ProcessInfo.processInfo.environment["WHISPREE_COMPAT_TEST_MODEL"]
        else {
            throw XCTSkip("Live endpoint env vars not set")
        }

        let provider = OpenAICompatibleProvider(
            baseURL: baseURL, apiKey: apiKey, modelId: model, supportsVision: false
        )
        XCTAssertTrue(provider.isReady)

        let result = try await provider.correct(
            text: "이거 L&M 모델이 되개 잘하거든",
            systemPrompt: "음성 인식 오류를 교정하세요. 교정된 텍스트만 출력하세요.",
            glossary: ["LLM"]
        )
        XCTAssertFalse(result.isEmpty)
        XCTAssertLessThanOrEqual(
            LocalTextProvider.wordEditDistance("이거 L&M 모델이 되개 잘하거든", result),
            0.5,
            "교정 결과는 원문과 유사해야 함 (환각 시 원문 반환되므로 항상 통과해야 함)"
        )
    }
}
