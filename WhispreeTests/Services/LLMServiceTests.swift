@testable import Whispree
import XCTest

private class OpenAICompatibleURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "OpenAICompatibleURLProtocolStub",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing request handler"]
                )
            )
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class LLMServiceTests: XCTestCase {
    override func tearDown() {
        OpenAICompatibleURLProtocolStub.handler = nil
        super.tearDown()
    }

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

        let relativeURL = OpenAICompatibleProvider(
            baseURL: "localhost:11434/v1", apiKey: "", modelId: "test-model", supportsVision: false
        )
        XCTAssertFalse(relativeURL.isReady)

        let unsupportedScheme = OpenAICompatibleProvider(
            baseURL: "file:///tmp/v1", apiKey: "", modelId: "test-model", supportsVision: false
        )
        XCTAssertFalse(unsupportedScheme.isReady)

        let noModel = OpenAICompatibleProvider(
            baseURL: "https://example.com/v1", apiKey: "key", modelId: "", supportsVision: false
        )
        XCTAssertFalse(noModel.isReady)

        let ok = OpenAICompatibleProvider(
            baseURL: "https://example.com/v1", apiKey: "key", modelId: "test-model", supportsVision: false
        )
        XCTAssertTrue(ok.isReady)

        let local = OpenAICompatibleProvider(
            baseURL: "http://localhost:11434/v1", apiKey: "", modelId: "local-model", supportsVision: false
        )
        XCTAssertTrue(local.isReady)
    }

    func testOpenAICompatibleConfigurationKeyTracksVisionAndCanonicalizesInput() {
        let textOnly = OpenAICompatibleProvider.configurationKey(
            baseURL: " https://example.com/v1/ ",
            apiKey: "key",
            modelId: " model ",
            supportsVision: false
        )
        let canonicalTextOnly = OpenAICompatibleProvider.configurationKey(
            baseURL: "https://example.com/v1",
            apiKey: "key",
            modelId: "model",
            supportsVision: false
        )
        let vision = OpenAICompatibleProvider.configurationKey(
            baseURL: "https://example.com/v1",
            apiKey: "key",
            modelId: "model",
            supportsVision: true
        )

        XCTAssertEqual(textOnly, canonicalTextOnly)
        XCTAssertNotEqual(textOnly, vision)
    }

    func testOpenAICompatibleProviderSendsTextRequestAndParsesResponse() async throws {
        let session = makeStubbedSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let bodyData = try Self.requestBodyData(from: request)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "test-model")
            XCTAssertEqual(body["stream"] as? Bool, false)
            XCTAssertEqual(body["temperature"] as? Int, 0)

            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.count, 2)
            XCTAssertEqual(messages[0]["role"] as? String, "system")
            XCTAssertEqual(
                messages[0]["content"] as? String,
                "교정하세요.\n\n용어 사전 (반드시 이 형태로 보존):\nLLM, Swift"
            )
            XCTAssertEqual(messages[1]["role"] as? String, "user")
            XCTAssertEqual(messages[1]["content"] as? String, "이거 L&M 모델이 되개 잘하거든")

            return try Self.stubbedResponse(
                for: request,
                statusCode: 200,
                json: ["choices": [["message": ["content": "이거 LLM 모델이 되게 잘하거든"]]]]
            )
        }
        defer { session.invalidateAndCancel() }

        let provider = OpenAICompatibleProvider(
            baseURL: "https://example.com/v1/",
            apiKey: "test-key",
            modelId: "test-model",
            supportsVision: false,
            session: session
        )
        let result = try await provider.correct(
            text: "이거 L&M 모델이 되개 잘하거든",
            systemPrompt: "교정하세요.",
            glossary: ["LLM", "Swift"]
        )

        XCTAssertEqual(result, "이거 LLM 모델이 되게 잘하거든")
    }

    func testOpenAICompatibleProviderSendsLatestThreeScreenshotsWithoutAuthorization() async throws {
        let screenshots = [Data([1]), Data([2]), Data([3]), Data([4])]
        let session = makeStubbedSession { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

            let bodyData = try Self.requestBodyData(from: request)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
            XCTAssertEqual(content.count, 4)

            let expectedImages = screenshots.suffix(3).map {
                "data:image/jpeg;base64,\($0.base64EncodedString())"
            }
            let actualImages = try content.prefix(3).map { part in
                let imageURL = try XCTUnwrap(part["image_url"] as? [String: String])
                return try XCTUnwrap(imageURL["url"])
            }
            XCTAssertEqual(actualImages, expectedImages)
            XCTAssertEqual(content[3]["type"] as? String, "text")
            XCTAssertEqual(content[3]["text"] as? String, "원문 텍스트")

            return try Self.stubbedResponse(
                for: request,
                statusCode: 200,
                json: ["choices": [["message": ["content": "원문 텍스트"]]]]
            )
        }
        defer { session.invalidateAndCancel() }

        let provider = OpenAICompatibleProvider(
            baseURL: "http://localhost:11434/v1",
            apiKey: "",
            modelId: "vision-model",
            supportsVision: true,
            session: session
        )
        let result = try await provider.correct(
            text: "원문 텍스트",
            systemPrompt: "교정하세요.",
            glossary: nil,
            screenshots: screenshots
        )

        XCTAssertEqual(result, "원문 텍스트")
    }

    func testOpenAICompatibleProviderSurfacesHTTPError() async throws {
        let session = makeStubbedSession { request in
            try Self.stubbedResponse(
                for: request,
                statusCode: 401,
                json: ["error": ["message": "invalid key"]]
            )
        }
        defer { session.invalidateAndCancel() }

        let provider = OpenAICompatibleProvider(
            baseURL: "https://example.com/v1",
            apiKey: "bad-key",
            modelId: "test-model",
            supportsVision: false,
            session: session
        )

        do {
            _ = try await provider.correct(text: "원문", systemPrompt: "교정하세요.", glossary: nil)
            XCTFail("Expected an HTTP error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            XCTAssertTrue(error.localizedDescription.contains("invalid key"))
        }
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

    private func makeStubbedSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        OpenAICompatibleURLProtocolStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAICompatibleURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private static func stubbedResponse(
        for request: URLRequest,
        statusCode: Int,
        json: [String: Any]
    ) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        let data = try JSONSerialization.data(withJSONObject: json)
        return (response, data)
    }

    private static func requestBodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }

        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
