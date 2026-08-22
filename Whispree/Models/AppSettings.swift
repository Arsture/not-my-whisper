import Combine
import Foundation
import KeyboardShortcuts

/// 앱 전역 설정.
///
/// 이전에는 struct + `"WhispreeSettings"` 단일 JSON blob 방식이었으나,
/// 필드별 `@UserDefault`/`@RawRepresentableUserDefault`/`@CodableUserDefault`
/// property wrapper 기반으로 재작성됨.
///
/// - **변경 전파**: wrapper의 setter가 `objectWillChange.send()`를 자동 호출 →
///   SwiftUI 뷰가 변경을 자동 감지.
/// - **저장**: wrapper가 내부적으로 UserDefaults에 set/remove를 수행하므로 `save()` 호출 불필요.
/// - **마이그레이션**: 초기화 시 주입된 store에서 `migrateLegacyBlobIfNeeded()` 호출 →
///   기존 `"WhispreeSettings"` JSON blob을 각 필드 키로 분해 저장 후 blob 삭제.
@MainActor
final class AppSettings: ObservableObject, UserDefaultsStoreProviding {

    nonisolated let userDefaultsStore: UserDefaults

    // MARK: - Recording

    @RawRepresentableUserDefault(key: "whispree.recordingMode", defaultValue: .pushToTalk)
    var recordingMode: RecordingMode

    @RawRepresentableUserDefault(key: "whispree.language", defaultValue: .korean)
    var language: SupportedLanguage

    // MARK: - LLM Toggle & Onboarding

    @UserDefault(key: "whispree.isLLMEnabled", defaultValue: true)
    var isLLMEnabled: Bool

    @UserDefault(key: "whispree.hasCompletedOnboarding", defaultValue: false)
    var hasCompletedOnboarding: Bool

    @UserDefault(key: "whispree.launchAtLogin", defaultValue: false)
    var launchAtLogin: Bool

    @UserDefault(key: "whispree.showOverlay", defaultValue: true)
    var showOverlay: Bool

    // MARK: - Correction

    @RawRepresentableUserDefault(
        key: "whispree.correctionMode",
        defaultValue: .standard,
        rawAliasMap: ["promptEngineering": "fillerRemoval"]
    )
    var correctionMode: CorrectionMode

    @UserDefault(key: "whispree.customLLMPrompt", defaultValue: nil)
    var customLLMPrompt: String?

    // MARK: - Model preferences

    @UserDefault(
        key: "whispree.whisperModelId",
        defaultValue: "openai_whisper-large-v3_turbo"
    )
    var whisperModelId: String

    @UserDefault(
        key: "whispree.llmModelId",
        defaultValue: "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    )
    var llmModelId: String

    @UserDefault(
        key: "whispree.mlxAudioModelId",
        defaultValue: "mlx-community/Qwen3-ASR-1.7B-8bit"
    )
    var mlxAudioModelId: String

    // MARK: - Providers

    @RawRepresentableUserDefault(
        key: "whispree.sttProviderType",
        defaultValue: .whisperKit
    )
    var sttProviderType: STTProviderType

    @RawRepresentableUserDefault(
        key: "whispree.llmProviderType",
        defaultValue: .none,
        rawAliasMap: ["로컬 LLM (Qwen3)": "로컬 MLX"]
    )
    var llmProviderType: LLMProviderType

    @RawRepresentableUserDefault(
        key: "whispree.openaiModel",
        defaultValue: .gpt56sol,
        rawAliasMap: OpenAIModel.rawAliasMap
    )
    var openaiModel: OpenAIModel

    @RawRepresentableUserDefault(
        key: "whispree.groqLLMModel",
        defaultValue: .qwen3_32b
    )
    var groqLLMModel: GroqLLMModel

    // MARK: - OpenAI-compatible API

    /// `/v1` 포함 base URL. 예: `https://api.openai.com/v1`, `http://localhost:11434/v1`
    @UserDefault(key: "whispree.openaiCompatibleBaseURL", defaultValue: "")
    var openaiCompatibleBaseURL: String

    @UserDefault(key: "whispree.openaiCompatibleAPIKey", defaultValue: "")
    var openaiCompatibleAPIKey: String

    /// 자유 문자열 모델 ID — 호환 엔드포인트마다 목록이 다름
    @UserDefault(key: "whispree.openaiCompatibleModelId", defaultValue: "")
    var openaiCompatibleModelId: String

    /// 엔드포인트의 vision 지원 여부는 자동 감지 불가 → 사용자가 지정
    @UserDefault(key: "whispree.openaiCompatibleSupportsVision", defaultValue: false)
    var openaiCompatibleSupportsVision: Bool

    // MARK: - Screenshot context

    @UserDefault(key: "whispree.isScreenshotContextEnabled", defaultValue: false)
    var isScreenshotContextEnabled: Bool

    @UserDefault(key: "whispree.isScreenshotPasteEnabled", defaultValue: true)
    var isScreenshotPasteEnabled: Bool

    // MARK: - Groq API

    @UserDefault(key: "whispree.groqApiKey", defaultValue: "")
    var groqApiKey: String

    // MARK: - Audio

    /// 오디오 입력 채널 선택.
    /// 0 = 자동 (모든 채널 평균 다운믹스, 기본값)
    /// 1~N = 특정 채널만 사용 (1-indexed)
    @UserDefault(key: "whispree.audioInputChannel", defaultValue: 0)
    var audioInputChannel: Int

    /// VAD (Voice Activity Detection) — 무음 구간 자동 제거.
    /// STT 진입 전 공통 pre-processing, 모든 프로바이더(WhisperKit/Groq/MLX Audio)에 적용.
    @UserDefault(key: "whispree.vadEnabled", defaultValue: true)
    var vadEnabled: Bool

    // MARK: - Media playback

    /// 녹음 시작 시 재생 중인 음악/영상을 자동 일시정지, 녹음 종료 시 재개.
    /// Apple Music, Spotify, YouTube 등 Now Playing 시스템에 등록된 모든 소스에 적용.
    @UserDefault(key: "whispree.pauseMediaDuringRecording", defaultValue: true)
    var pauseMediaDuringRecording: Bool

    // MARK: - Browser

    @UserDefault(key: "whispree.restoreBrowserTab", defaultValue: true)
    var restoreBrowserTab: Bool

    // MARK: - Terminal

    /// iTerm2 session(pane) + tmux window/pane 위치 복원.
    /// 녹음 전 포커스된 iTerm2 pane(+ 그 안에서 tmux 돌고 있으면 attached window/pane까지) 기억 → 붙여넣기 직전 동일 pane으로 복귀.
    @UserDefault(key: "whispree.restoreTerminalContext", defaultValue: true)
    var restoreTerminalContext: Bool

    // MARK: - Domain words

    @CodableUserDefault(key: "whispree.domainWordSets", defaultValue: [])
    var domainWordSets: [DomainWordSet]

    @UserDefault(key: "whispree.sharedDictionaryEnabled", defaultValue: false)
    var sharedDictionaryEnabled: Bool

    @UserDefault(key: "whispree.sharedDictionaryPath", defaultValue: nil)
    var sharedDictionaryPath: String?

    // MARK: - Hotkeys (WhispreeShortcut — combo + modifier-only 지원)

    @CodableUserDefault(
        key: "whispree.toggleRecordingShortcut",
        defaultValue: WhispreeShortcut.defaultToggleRecording
    )
    var toggleRecordingShortcut: WhispreeShortcut

    @CodableUserDefault(
        key: "whispree.quickFixShortcut",
        defaultValue: WhispreeShortcut.defaultQuickFix
    )
    var quickFixShortcut: WhispreeShortcut

    // MARK: - Init

    init(store: UserDefaults = .standard, migrateHotkeys: Bool = true) {
        userDefaultsStore = store
        Self.migrateLegacyBlobIfNeeded(store: store)
        if migrateHotkeys {
            migrateHotkeysIfNeeded()
        }
        runFieldMigrations()
    }

    /// KeyboardShortcuts 라이브러리 저장소 → AppSettings.toggleRecordingShortcut/quickFixShortcut로 1회성 마이그레이션.
    /// 유저가 기존에 커스텀 단축키를 설정했다면 그 값을 가져오고, 아니면 default 유지.
    private func migrateHotkeysIfNeeded() {
        let defaults = userDefaultsStore
        let flagKey = "whispree.hotkeyMigrationDone"
        guard !defaults.bool(forKey: flagKey) else { return }

        if defaults.data(forKey: "whispree.toggleRecordingShortcut") == nil,
           let stored = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
            toggleRecordingShortcut = WhispreeShortcut(combo: stored)
        }
        if defaults.data(forKey: "whispree.quickFixShortcut") == nil,
           let stored = KeyboardShortcuts.getShortcut(for: .quickFix) {
            quickFixShortcut = WhispreeShortcut(combo: stored)
        }

        // 이후엔 AppSettings만 단축키 소유. 라이브러리 저장소는 정리.
        KeyboardShortcuts.setShortcut(nil, for: .toggleRecording)
        KeyboardShortcuts.setShortcut(nil, for: .quickFix)

        defaults.set(true, forKey: flagKey)
    }

    // MARK: - Shared Dictionary

    var sharedDictionaryConfig: SharedDictionaryConfig {
        SharedDictionaryConfig(customURL: sharedDictionaryPath.flatMap { path in
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        })
    }

    /// domainWordSets를 공유 파일로 내보내기. 백그라운드 스레드에서 실행.
    func exportSharedDictionary() {
        guard sharedDictionaryEnabled, let url = sharedDictionaryConfig.resolvedFileURL else { return }
        let snapshot = domainWordSets
        Task.detached {
            try? SharedDictionaryStore.save(snapshot, to: url)
        }
    }

    /// 공유 파일에서 domainWordSets를 가져오기. 파일이 없거나 비어있으면 무시.
    @discardableResult
    func importSharedDictionary() -> Bool {
        guard sharedDictionaryEnabled, let url = sharedDictionaryConfig.resolvedFileURL else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let imported = try? SharedDictionaryStore.load(from: url), !imported.isEmpty else { return false }
        domainWordSets = imported
        return true
    }

    /// 필드별 후처리 마이그레이션 — 기존 default 마이그레이션 로직 보존.
    private func runFieldMigrations() {
        // 구 Qwen2.5 모델 ID → Qwen3 기본값
        if llmModelId.contains("Qwen2.5") {
            llmModelId = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        }
        // 스크린샷 활성화 OFF인데 전달만 ON인 상태 정리
        if !isScreenshotContextEnabled, isScreenshotPasteEnabled {
            isScreenshotPasteEnabled = false
        }
    }

    /// 구 `"WhispreeSettings"` JSON blob을 1회성으로 각 필드 키에 분해 저장하고 blob 삭제.
    ///
    /// - 성공 시: blob 삭제 → 이후엔 wrapper만 동작.
    /// - 디코드 실패 시: `whispree.legacyMigrationFailed = true` 플래그 → 재시도 방지.
    /// - 부분 실패 (crash 등): 다음 부팅에서 idempotent 재실행 (blob이 남아있으므로).
    static func migrateLegacyBlobIfNeeded(store defaults: UserDefaults = .standard) {
        let legacyKey = "WhispreeSettings"
        let migrationFailedKey = "whispree.legacyMigrationFailed"

        guard !defaults.bool(forKey: migrationFailedKey),
              let data = defaults.data(forKey: legacyKey) else { return }

        guard let legacy = try? JSONDecoder().decode(LegacyAppSettings.self, from: data) else {
            defaults.set(true, forKey: migrationFailedKey)
            return
        }

        defaults.set(legacy.recordingMode.rawValue, forKey: "whispree.recordingMode")
        defaults.set(legacy.language.rawValue, forKey: "whispree.language")
        defaults.set(legacy.isLLMEnabled, forKey: "whispree.isLLMEnabled")
        defaults.set(legacy.hasCompletedOnboarding, forKey: "whispree.hasCompletedOnboarding")
        defaults.set(legacy.launchAtLogin, forKey: "whispree.launchAtLogin")
        defaults.set(legacy.showOverlay, forKey: "whispree.showOverlay")
        defaults.set(legacy.correctionMode.rawValue, forKey: "whispree.correctionMode")
        if let prompt = legacy.customLLMPrompt {
            defaults.set(prompt, forKey: "whispree.customLLMPrompt")
        }
        defaults.set(legacy.whisperModelId, forKey: "whispree.whisperModelId")
        defaults.set(legacy.llmModelId, forKey: "whispree.llmModelId")
        defaults.set(legacy.mlxAudioModelId, forKey: "whispree.mlxAudioModelId")
        defaults.set(legacy.sttProviderType.rawValue, forKey: "whispree.sttProviderType")
        defaults.set(legacy.llmProviderType.rawValue, forKey: "whispree.llmProviderType")
        defaults.set(legacy.openaiModel.rawValue, forKey: "whispree.openaiModel")
        defaults.set(legacy.isScreenshotContextEnabled, forKey: "whispree.isScreenshotContextEnabled")
        defaults.set(legacy.isScreenshotPasteEnabled, forKey: "whispree.isScreenshotPasteEnabled")
        defaults.set(legacy.groqApiKey, forKey: "whispree.groqApiKey")
        defaults.set(legacy.audioInputChannel, forKey: "whispree.audioInputChannel")
        defaults.set(legacy.vadEnabled, forKey: "whispree.vadEnabled")
        defaults.set(legacy.openaiCompatibleBaseURL, forKey: "whispree.openaiCompatibleBaseURL")
        defaults.set(legacy.openaiCompatibleAPIKey, forKey: "whispree.openaiCompatibleAPIKey")
        defaults.set(legacy.openaiCompatibleModelId, forKey: "whispree.openaiCompatibleModelId")
        defaults.set(legacy.openaiCompatibleSupportsVision, forKey: "whispree.openaiCompatibleSupportsVision")
        if let wordSetsData = try? JSONEncoder().encode(legacy.domainWordSets) {
            defaults.set(wordSetsData, forKey: "whispree.domainWordSets")
        }

        defaults.removeObject(forKey: legacyKey)
    }
}

// MARK: - LegacyAppSettings (migration 전용)

/// 구 `"WhispreeSettings"` JSON blob 디코드 전용 private 구조체.
///
/// Swift의 synthesized `init(from:)`은 struct declaration의 default value를 무시하므로,
/// 새 필드 추가 시 누락 키로 디코드가 실패하지 않도록 custom `init(from:)`에서
/// 모든 필드를 `decodeIfPresent` + default fallback으로 처리.
private struct LegacyAppSettings: Codable {
    var recordingMode: RecordingMode = .pushToTalk
    var language: SupportedLanguage = .korean
    var isLLMEnabled: Bool = true
    var hasCompletedOnboarding: Bool = false
    var launchAtLogin: Bool = false
    var showOverlay: Bool = true
    var correctionMode: CorrectionMode = .standard
    var customLLMPrompt: String?
    var whisperModelId: String = "openai_whisper-large-v3_turbo"
    var llmModelId: String = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    var mlxAudioModelId: String = "mlx-community/Qwen3-ASR-1.7B-8bit"
    var sttProviderType: STTProviderType = .whisperKit
    var llmProviderType: LLMProviderType = .none
    var openaiModel: OpenAIModel = .gpt55
    var isScreenshotContextEnabled: Bool = false
    var isScreenshotPasteEnabled: Bool = true
    var groqApiKey: String = ""
    var openaiCompatibleBaseURL: String = ""
    var openaiCompatibleAPIKey: String = ""
    var openaiCompatibleModelId: String = ""
    var openaiCompatibleSupportsVision: Bool = false
    var audioInputChannel: Int = 0
    var vadEnabled: Bool = true
    var domainWordSets: [DomainWordSet] = []

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.recordingMode = (try? c.decodeIfPresent(RecordingMode.self, forKey: .recordingMode)) ?? .pushToTalk
        self.language = (try? c.decodeIfPresent(SupportedLanguage.self, forKey: .language)) ?? .korean
        self.isLLMEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isLLMEnabled)) ?? true
        self.hasCompletedOnboarding = (try? c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)) ?? false
        self.launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? false
        self.showOverlay = (try? c.decodeIfPresent(Bool.self, forKey: .showOverlay)) ?? true
        self.correctionMode = (try? c.decodeIfPresent(CorrectionMode.self, forKey: .correctionMode)) ?? .standard
        self.customLLMPrompt = try? c.decodeIfPresent(String.self, forKey: .customLLMPrompt) ?? nil
        self.whisperModelId = (try? c.decodeIfPresent(String.self, forKey: .whisperModelId)) ?? "openai_whisper-large-v3_turbo"
        self.llmModelId = (try? c.decodeIfPresent(String.self, forKey: .llmModelId)) ?? "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        self.mlxAudioModelId = (try? c.decodeIfPresent(String.self, forKey: .mlxAudioModelId)) ?? "mlx-community/Qwen3-ASR-1.7B-8bit"
        self.sttProviderType = (try? c.decodeIfPresent(STTProviderType.self, forKey: .sttProviderType)) ?? .whisperKit
        self.llmProviderType = (try? c.decodeIfPresent(LLMProviderType.self, forKey: .llmProviderType)) ?? .none
        self.openaiModel = (try? c.decodeIfPresent(OpenAIModel.self, forKey: .openaiModel)) ?? .gpt55
        self.isScreenshotContextEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isScreenshotContextEnabled)) ?? false
        self.isScreenshotPasteEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isScreenshotPasteEnabled)) ?? true
        self.groqApiKey = (try? c.decodeIfPresent(String.self, forKey: .groqApiKey)) ?? ""
        self.openaiCompatibleBaseURL = (try? c.decodeIfPresent(String.self, forKey: .openaiCompatibleBaseURL)) ?? ""
        self.openaiCompatibleAPIKey = (try? c.decodeIfPresent(String.self, forKey: .openaiCompatibleAPIKey)) ?? ""
        self.openaiCompatibleModelId = (try? c.decodeIfPresent(String.self, forKey: .openaiCompatibleModelId)) ?? ""
        self.openaiCompatibleSupportsVision = (try? c.decodeIfPresent(Bool.self, forKey: .openaiCompatibleSupportsVision)) ?? false
        self.audioInputChannel = (try? c.decodeIfPresent(Int.self, forKey: .audioInputChannel)) ?? 0
        self.vadEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .vadEnabled)) ?? true
        self.domainWordSets = (try? c.decodeIfPresent([DomainWordSet].self, forKey: .domainWordSets)) ?? []
    }
}

// MARK: - STTProviderType / LLMProviderType

enum STTProviderType: String, Codable, CaseIterable {
    case whisperKit = "WhisperKit"
    case groq = "Groq"
    case mlxAudio = "MLX Audio"

    var displayName: String {
        switch self {
            case .whisperKit: "WhisperKit (로컬)"
            case .groq: "Groq Cloud (빠름)"
            case .mlxAudio: "MLX Audio (로컬)"
        }
    }
}

enum LLMProviderType: String, Codable, CaseIterable {
    case none = "없음 (원문 사용)"
    case local = "로컬 MLX"
    case openai = "OpenAI (GPT)"
    case openaiCompatible = "OpenAI 호환 API"
    case groq = "Groq Cloud"

    var displayName: String {
        switch self {
            case .none: "없음 (원문 사용)"
            case .local: "로컬 MLX"
            case .openai: "OpenAI (GPT)"
            case .openaiCompatible: "OpenAI 호환 API"
            case .groq: "Groq Cloud"
        }
    }

    /// 구 rawValue `"로컬 LLM (Qwen3)"`을 `.local`로 마이그레이션.
    /// Legacy blob 디코드 경로에서만 호출되며, 현재 저장 경로는 `rawAliasMap`이 담당.
    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        switch rawValue {
            case "로컬 LLM (Qwen3)": self = .local
            default:
                guard let value = LLMProviderType(rawValue: rawValue) else {
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unknown LLMProviderType: \(rawValue)"
                    ))
                }
                self = value
        }
    }
}
