import Foundation

enum OpenAIModel: String, CaseIterable, Codable {
    case gpt56sol = "gpt-5.6-sol"
    case gpt56terra = "gpt-5.6-terra"
    case gpt56luna = "gpt-5.6-luna"
    case gpt55 = "gpt-5.5"
    case gpt54 = "gpt-5.4"
    case gpt54mini = "gpt-5.4-mini"
    case gpt53codex = "gpt-5.3-codex"
    case gpt52 = "gpt-5.2"

    static let rawAliasMap: [String: String] = [
        "gpt-5.6": "gpt-5.6-sol",
        "gpt-5.3-codex-spark": "gpt-5.4-mini",
        "gpt-5.2-codex": "gpt-5.2",
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        let normalized = Self.rawAliasMap[rawValue] ?? rawValue
        guard let model = Self(rawValue: normalized) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown OpenAI model: \(rawValue)"
            )
        }
        self = model
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var displayName: String {
        switch self {
            case .gpt56sol: "GPT-5.6 Sol (Latest)"
            case .gpt56terra: "GPT-5.6 Terra"
            case .gpt56luna: "GPT-5.6 Luna (Fast)"
            case .gpt55: "GPT-5.5"
            case .gpt54: "GPT-5.4"
            case .gpt54mini: "GPT-5.4 Mini (Fast)"
            case .gpt53codex: "GPT-5.3 Codex"
            case .gpt52: "GPT-5.2"
        }
    }

    var description: String {
        switch self {
            case .gpt56sol: "최고 성능 프런티어 모델. 긴 컨텍스트와 복잡한 교정에 적합"
            case .gpt56terra: "성능과 비용의 균형"
            case .gpt56luna: "대량 처리에 적합한 경량·저비용 모델"
            case .gpt55: "고품질. 긴 컨텍스트와 복잡한 교정에 적합"
            case .gpt54: "고품질. 코딩 + 추론 통합 모델"
            case .gpt54mini: "빠른 응답. 짧은 교정에 적합"
            case .gpt53codex: "코딩 특화. 기술 용어 교정에 강함"
            case .gpt52: "이전 세대. 호환성 우선"
        }
    }

    /// 교정 품질 점수 (0-100)
    var qualityScore: Int {
        switch self {
            case .gpt56sol: 100
            case .gpt56terra: 96
            case .gpt55: 93
            case .gpt54: 88
            case .gpt56luna: 85
            case .gpt53codex: 82
            case .gpt54mini: 78
            case .gpt52: 75
        }
    }

    /// 예상 레이턴시 (ms)
    var estimatedLatencyMs: Int {
        switch self {
            case .gpt56luna: 550
            case .gpt54mini: 600
            case .gpt53codex: 800
            case .gpt56terra: 900
            case .gpt52: 900
            case .gpt55: 1100
            case .gpt54: 1200
            case .gpt56sol: 1200
        }
    }
}
