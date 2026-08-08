import Foundation

@MainActor
final class OpenAIProvider: LLMProvider {
    let name = "OpenAI (GPT)"
    let requiresNetwork = true
    let supportsVision = true

    private let authService: CodexAuthService
    private let oauthService: OAuthService
    private var model: OpenAIModel

    func validate() -> ProviderValidation {
        if authService.isLoggedIn || oauthService.isLoggedIn {
            return .valid
        }
        return .invalid("OpenAI 인증이 필요합니다. Codex CLI 로그인 또는 OAuth 인증을 해주세요.")
    }

    init(model: OpenAIModel = .gpt56sol, authService: CodexAuthService, oauthService: OAuthService) {
        self.model = model
        self.authService = authService
        self.oauthService = oauthService
    }

    func setup() async throws {
        // Auth is checked at correction time, not during setup
        authService.checkAuth()
        oauthService.checkAuth()
    }

    func teardown() async {
        // 네트워크 Provider는 특별한 해제 불필요
    }

    func correct(text: String, systemPrompt: String, glossary: [String]?, screenshots: [Data] = []) async throws -> String {
        // glossary를 시스템 프롬프트에 동적 주입
        var fullPrompt = systemPrompt
        if let glossary, !glossary.isEmpty {
            fullPrompt += "\n\n용어 사전 (반드시 이 형태로 보존):\n" + glossary.joined(separator: ", ")
        }

        let (accessToken, accountId) = try getAuth()

        // ChatGPT Responses API 요청 구성
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.buildUserAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")

        // 스크린샷이 있으면 Vision 멀티모달 content, 없으면 텍스트 전용
        var userContent: [[String: Any]] = []
        // 최근 5장까지만 전송 (토큰 절약)
        let recentScreenshots = screenshots.suffix(5)
        for screenshotData in recentScreenshots {
            let base64Image = screenshotData.base64EncodedString()
            userContent.append(["type": "input_image", "image_url": "data:image/jpeg;base64,\(base64Image)"])
        }
        userContent.append(["type": "input_text", "text": text])

        let body: [String: Any] = [
            "model": model.rawValue,
            "instructions": fullPrompt,
            "input": [
                ["type": "message", "role": "user", "content": userContent]
            ],
            "tools": [] as [[String: Any]],
            "tool_choice": "auto",
            "parallel_tool_calls": false,
            "store": false,
            "stream": true,
            "include": [] as [String]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // SSE 스트리밍 파싱
        let result = try await parseSSEStream(request: request, originalText: text)

        // 안전장치: 출력이 입력보다 2.5배 이상 길면 답변 생성으로 판단
        if result == text { return result }
        let inputWords = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
        let outputWords = result.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
        if inputWords > 0, Double(outputWords) / Double(inputWords) > 2.5 { return text }

        return result
    }

    // MARK: - Auth Resolution

    /// Codex 토큰 우선, 없으면 OAuth 토큰 사용
    private func getAuth() throws -> (accessToken: String, accountId: String) {
        // 1. Codex CLI 토큰
        if let codexTokens = authService.loadTokens() {
            return (codexTokens.access_token, codexTokens.account_id)
        }

        // 2. OAuth 토큰 (JWT에서 account_id 추출)
        if let oauthTokens = oauthService.loadTokens() {
            guard let accountId = oauthService.extractAccountId(from: oauthTokens.access_token) else {
                throw AuthError.notAuthenticated
            }
            return (oauthTokens.access_token, accountId)
        }

        throw AuthError.notAuthenticated
    }

    // MARK: - SSE Streaming

    private func parseSSEStream(request: URLRequest, originalText: String) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return originalText
        }

        // 401 = 토큰 만료 → 리프레시 시도
        if httpResponse.statusCode == 401 {
            try await refreshCurrentAuth()
            throw AuthError.tokenExpired
        }

        guard httpResponse.statusCode == 200 else {
            return originalText
        }

        var result = ""

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))

            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }

            // delta 텍스트 축적
            if let delta = json["delta"] as? String {
                result += delta
            }
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = Self.removeCodeFences(trimmed)
        return cleaned.isEmpty ? originalText : cleaned
    }

    /// 현재 활성 인증 방식의 토큰을 리프레시
    private func refreshCurrentAuth() async throws {
        // Codex 토큰이 있으면 Codex 리프레시
        if let codexTokens = authService.loadTokens() {
            _ = try await authService.refreshToken(refreshToken: codexTokens.refresh_token)
            return
        }

        // OAuth 토큰이 있으면 OAuth 리프레시
        if oauthService.isLoggedIn {
            _ = try await oauthService.refreshAccessToken()
        }
    }

    // MARK: - Utilities

    /// 마크다운 코드 펜스 (```json ... ```) 제거
    private static func removeCodeFences(_ text: String) -> String {
        var result = text
        if result.hasPrefix("```") {
            if let firstNewline = result.firstIndex(of: "\n") {
                result = String(result[result.index(after: firstNewline)...])
            }
        }
        if result.hasSuffix("```") {
            result = String(result.dropLast(3))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// User-Agent 빌드 (Codex CLI 형식)
    private static func buildUserAgent() -> String {
        let osVer = ProcessInfo.processInfo.operatingSystemVersionString
        return "codex_cli_rs/0.1.2025062 (Darwin \(osVer); arm64)"
    }

    /// 모델 변경
    func updateModel(_ newModel: OpenAIModel) {
        model = newModel
    }
}
