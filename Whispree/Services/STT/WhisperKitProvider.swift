import Foundation
import WhisperKit

final class WhisperKitProvider: STTProvider, @unchecked Sendable {
    let name = "WhisperKit"
    var isAvailable: Bool {
        true
    }

    private var whisperKit: WhisperKit?

    func validate() -> ProviderValidation {
        guard let whisperKit else {
            return .invalid("WhisperKit 모델이 로드되지 않았습니다. 모델을 다운로드해주세요.")
        }
        return whisperKit.modelState == .loaded
            ? .valid
            : .invalid("WhisperKit 모델이 아직 로드되지 않았습니다.")
    }

    func setup() async throws {
        let config = WhisperKitConfig(
            model: "openai_whisper-large-v3_turbo",
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            ),
            load: true
        )
        whisperKit = try await WhisperKit(config)
    }

    func teardown() async {
        whisperKit = nil
    }

    /// 도메인 단어 세트 저장 (transcribe 시 promptTokens로 변환)
    var domainWordSets: [DomainWordSet] = []

    func transcribe(
        audioBuffer: [Float],
        language: SupportedLanguage?,
        promptTokens: [Int]?
    ) async throws -> TranscriptionResult {
        guard let whisperKit else { throw STTError.modelNotLoaded }

        // 세팅값 따라감: auto면 자동 감지, ko/en이면 해당 언어 고정
        let langCode: String? = (language == nil || language == .auto) ? nil : language!.rawValue

        var options = DecodingOptions(
            language: langCode,
            temperatureFallbackCount: 0,
            detectLanguage: langCode == nil,
            wordTimestamps: false,
            noSpeechThreshold: 0.5
        )

        // Prompt tokens disable WhisperKit 0.18's prefill cache, so keep interactive
        // dictation prompts bounded instead of paying the slow path for large glossaries.
        if let promptTokens, !promptTokens.isEmpty {
            options.promptTokens = Array(promptTokens.prefix(64))
        } else if let tokens = buildPromptTokens(from: domainWordSets) {
            options.promptTokens = Array(tokens.prefix(64))
        }

        let results = try await whisperKit.transcribe(audioArray: audioBuffer, decodeOptions: options)
        let segments = results.map { result in
            TranscriptionSegment(
                text: result.text,
                language: result.language,
                words: nil
            )
        }

        return TranscriptionResult(
            text: results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            segments: segments,
            language: results.first?.language
        )
    }

    func transcribeStream(
        audioBuffer: [Float],
        language: SupportedLanguage?,
        promptTokens: [Int]?
    ) -> AsyncStream<PartialTranscription> {
        AsyncStream { continuation in
            Task {
                do {
                    let result = try await self.transcribe(
                        audioBuffer: audioBuffer,
                        language: language,
                        promptTokens: promptTokens
                    )
                    continuation.yield(PartialTranscription(text: result.text, isFinal: true))
                } catch {
                    // 오류 시 빈 결과
                }
                continuation.finish()
            }
        }
    }

    /// 도메인 단어 세트에서 promptTokens 빌드
    func buildPromptTokens(from wordSets: [DomainWordSet]) -> [Int]? {
        let enabledSets = wordSets.filter(\.isEnabled)
        guard !enabledSets.isEmpty else { return nil }

        let promptText = enabledSets.map { $0.buildPromptText() }.joined(separator: " ")
        guard let tokenizer = whisperKit?.tokenizer else { return nil }

        let tokens = tokenizer.encode(text: promptText)
        return Array(tokens.prefix(64))
    }
}
