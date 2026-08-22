import Foundation

/// OpenAI-compatible Chat Completions API Provider.
///
/// vLLM, Ollama, LM Studio, OpenRouter, DeepSeek, Together 등
/// `POST {baseURL}/chat/completions` + `Authorization: Bearer <key>`를 지원하는
/// 모든 엔드포인트에서 동작한다. base URL은 `/v1` 포함 경로로 저장한다.
@MainActor
final class OpenAICompatibleProvider: LLMProvider {
    let name = "OpenAI 호환 API"
    let requiresNetwork = true
    var supportsVision: Bool {
        supportsVisionOverride
    }

    private let baseURL: String
    private let apiKey: String
    private let modelId: String
    private let supportsVisionOverride: Bool
    private let session: URLSession
    private let correctionTimeout: TimeInterval = 30.0

    init(
        baseURL: String,
        apiKey: String,
        modelId: String,
        supportsVision: Bool,
        session: URLSession = .shared
    ) {
        self.baseURL = Self.normalizeBaseURL(baseURL)
        self.apiKey = apiKey
        self.modelId = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        supportsVisionOverride = supportsVision
        self.session = session
    }

    func validate() -> ProviderValidation {
        if baseURL.isEmpty {
            return .invalid("Base URL을 입력하세요. (예: https://api.openai.com/v1)")
        }
        guard Self.chatCompletionsURL(baseURL: baseURL) != nil else {
            return .invalid("Base URL은 유효한 http(s) 주소여야 합니다. (예: http://localhost:11434/v1)")
        }
        if modelId.isEmpty {
            return .invalid("모델 ID를 입력하세요. (예: gpt-4o-mini, deepseek-chat)")
        }
        return .valid
    }

    func setup() async throws {}
    func teardown() async {}

    func correct(
        text: String,
        systemPrompt: String,
        glossary: [String]?,
        screenshots: [Data] = []
    ) async throws -> String {
        guard !modelId.isEmpty else {
            throw LLMError.correctionFailed("모델 ID가 비어있습니다.")
        }

        var fullPrompt = systemPrompt
        if let glossary, !glossary.isEmpty {
            fullPrompt += "\n\n용어 사전 (반드시 이 형태로 보존):\n" + glossary.joined(separator: ", ")
        }

        // user content 빌드 — vision 활성화 시에만 image 블록 포함
        let userContent: Any
        if supportsVision, !screenshots.isEmpty {
            let recent = screenshots.suffix(3)
            var parts: [[String: Any]] = []
            for shot in recent {
                let b64 = shot.base64EncodedString()
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:image/jpeg;base64,\(b64)"]
                ])
            }
            parts.append(["type": "text", "text": text])
            userContent = parts
        } else {
            userContent = text
        }

        let body: [String: Any] = [
            "model": modelId,
            "messages": [
                ["role": "system", "content": fullPrompt],
                ["role": "user", "content": userContent]
            ],
            "temperature": 0,
            "stream": false
        ]

        guard let url = Self.chatCompletionsURL(baseURL: baseURL) else {
            throw LLMError.correctionFailed("잘못된 Base URL: \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = correctionTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let session = session
        let correctionTimeout = correctionTimeout
        let result = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await Self.performRequest(request, session: session) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(correctionTimeout * 1_000_000_000))
                throw LLMError.timeout
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }

        let trimmed = Self.stripThinkBlock(result).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = Self.removeCodeFences(trimmed)
        if cleaned.isEmpty { return text }

        // word-edit-distance 안전장치 — LLM 환각 시 원문 반환
        let changeRatio = LocalTextProvider.wordEditDistance(text, cleaned)
        if changeRatio > 0.5 { return text }

        return cleaned
    }

    // MARK: - Networking

    private static func performRequest(_ request: URLRequest, session: URLSession) async throws -> String {
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.correctionFailed("응답 없음")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw LLMError.correctionFailed("API \(http.statusCode): \(body)")
        }

        struct ChatCompletionsResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                }

                let message: Message
            }

            let choices: [Choice]
        }

        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }

    // MARK: - Utilities

    /// trailing slash 제거. `/chat/completions` 접미사를 위한 정규화.
    private static func normalizeBaseURL(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func chatCompletionsURL(baseURL: String) -> URL? {
        guard let components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.query == nil,
              components.fragment == nil,
              let url = components.url
        else { return nil }

        return url.appending(path: "chat/completions")
    }

    static func configurationKey(
        baseURL: String,
        apiKey: String,
        modelId: String,
        supportsVision: Bool
    ) -> String {
        let normalizedURL = normalizeBaseURL(baseURL)
        let normalizedModelId = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        return "openaiCompatible:\(normalizedURL):\(normalizedModelId):\(apiKey.hashValue):vision=\(supportsVision)"
    }

    /// Qwen3 등의 `<think>...</think>` 블록 제거.
    /// 미종결 블록(길이 제한/에러로 `</think>` 없이 끝남)도 처리 — GroqLLMProvider와 동일 동작.
    private static func stripThinkBlock(_ text: String) -> String {
        if let end = text.range(of: "</think>") {
            return String(text[end.upperBound...])
        }
        if text.hasPrefix("<think>") {
            return ""
        }
        return text
    }

    /// 마크다운 코드 펜스 (```...```) 제거.
    private static func removeCodeFences(_ text: String) -> String {
        guard text.contains("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
