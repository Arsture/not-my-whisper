import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    typealias STTProviderFactory = (STTProviderType, AppSettings) -> any STTProvider

    // MARK: - Transcription State

    @Published var transcriptionState: TranscriptionState = .idle
    @Published var partialText: String = ""
    @Published var finalText: String = ""
    @Published var correctedText: String = ""
    @Published var currentError: AppError?
    @Published var dictationQueueSnapshot: DictationQueueSnapshot = .empty

    // MARK: - Audio

    @Published var currentAudioLevel: Float = 0.0
    @Published var frequencyBands: [Float] = Array(repeating: 0, count: 64)
    @Published var isRecording: Bool = false
    /// 녹음 중 일정 시간 이상 무음이 지속되는 상태. TranscriptionOverlayView가
    /// "무음 스킵 중" 인디케이터로 전환하기 위해 사용.
    @Published var isThinkingPause: Bool = false

    /// 녹음 중 Option 길게 눌러 스크린샷 전달을 토글한 직후,
    /// 오버레이에 잠시 표시되는 플래시 인디케이터 (nil이면 표시 안함).
    /// on=true일 때 "스크린샷 전달 ON", false일 때 "OFF"로 표시.
    @Published var handoffToggleFlash: Bool?
    private var handoffFlashTask: Task<Void, Never>?

    /// 스크린샷 전달 토글 UI 피드백 — 1.2초간 플래시 표시 후 nil로 복귀.
    func flashHandoffToggle(_ enabled: Bool) {
        handoffFlashTask?.cancel()
        handoffToggleFlash = enabled
        handoffFlashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.handoffToggleFlash = nil }
        }
    }

    // MARK: - Screenshots

    @Published var capturedScreenshots: [CapturedScreenshot] = []
    /// 스크린샷 선택 완료 시 호출되는 콜백 (선택된 이미지 Data 배열 전달)
    var screenshotSelectionCallback: (([Data]) -> Void)?
    /// 글로벌 키 이벤트 → ScreenshotSelectionView로 전달
    @Published var selectionKeyEvent: NSEvent?
    /// 미리보기 요청 콜백 → AppDelegate가 Quick Look 스타일 패널 표시
    var previewRequestCallback: ((CapturedScreenshot) -> Void)?
    /// 스크린샷 선택 뷰에서 직접 패널 dismiss 요청
    var dismissSelectionPanel: (() -> Void)?

    // MARK: - Model State

    @Published var whisperModelState: ModelState = .notDownloaded
    @Published var llmModelState: ModelState = .notDownloaded
    @Published var whisperDownloadProgress: Double = 0.0
    @Published var llmDownloadProgress: Double = 0.0

    // MARK: - Provider State

    @Published var sttProvider: (any STTProvider)?
    @Published var llmProvider: (any LLMProvider)?

    // MARK: - Auth

    let authService = CodexAuthService()
    let oauthService = OAuthService()
    private var authCancellables = Set<AnyCancellable>()
    private let sttProviderFactory: STTProviderFactory
    private var activeSTTProviderConfigurationKey: String?
    private var sttProviderLoadGeneration = 0

    // MARK: - Settings

    /// `AppSettings`는 `@MainActor ObservableObject` — property wrapper가 내부적으로
    /// UserDefaults 저장과 `objectWillChange.send()`를 처리한다.
    /// `@Published`가 아닌 `let`으로 보유하고, 변경은 아래 `init()`에서 forwarding.
    let settings: AppSettings

    // MARK: - Shared Dictionary Sync

    private var lastSyncedDomainWordSetsHash: Int = 0

    private func exportDomainWordSetsIfChanged() {
        guard settings.sharedDictionaryEnabled else { return }
        let currentHash = settings.domainWordSets.hashValue
        guard currentHash != lastSyncedDomainWordSetsHash else { return }
        lastSyncedDomainWordSetsHash = currentHash
        settings.exportSharedDictionary()
    }

    // MARK: - History

    @Published var transcriptionHistory: [TranscriptionRecord] = [] {
        didSet { saveHistory() }
    }

    private static let historyKey = "WhispreeHistory"

    var isReady: Bool {
        sttProvider?.isReady ?? false
    }

    init(
        settings: AppSettings? = nil,
        sttProviderFactory: STTProviderFactory? = nil
    ) {
        let resolvedSettings = settings ?? AppSettings()
        self.settings = resolvedSettings
        self.sttProviderFactory = sttProviderFactory ?? { type, settings in
            switch type {
            case .whisperKit:
                WhisperKitProvider()
            case .groq:
                GroqSTTProvider(apiKey: settings.groqApiKey)
            case .mlxAudio:
                MLXAudioProvider(modelId: settings.mlxAudioModelId)
            }
        }

        // settings/authService/oauthService의 @Published 변경을 AppState로 전파
        // (SwiftUI가 중첩 ObservableObject 변경을 자동 감지하지 않으므로)
        resolvedSettings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &authCancellables)

        // domainWordSets 변경 시 공유 사전 자동 export (debounced, hash 비교)
        // objectWillChange는 값 변경 전에 발행되므로, UserDefaults 알림을 통해
        // 값이 실제 저장된 후 export한다.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.exportDomainWordSetsIfChanged()
            }
            .store(in: &authCancellables)

        authService.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &authCancellables)

        oauthService.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &authCancellables)

        // 공유 사전 import (앱 시작 시 1회)
        resolvedSettings.importSharedDictionary()
        lastSyncedDomainWordSetsHash = resolvedSettings.domainWordSets.hashValue

        loadHistory()
    }

    // MARK: - Provider Management

    func switchSTTProvider(to type: STTProviderType) async {
        let configurationKey = sttProviderConfigurationKey(for: type)
        if activeSTTProviderConfigurationKey == configurationKey {
            if whisperModelState == .loading {
                return
            }
            if whisperModelState == .ready, sttProvider != nil {
                return
            }
        }

        sttProviderLoadGeneration += 1
        let loadGeneration = sttProviderLoadGeneration
        activeSTTProviderConfigurationKey = configurationKey
        whisperModelState = .loading

        // Capture provider settings before the first suspension so the instance and
        // configuration key always describe the same immutable selection.
        let provider = sttProviderFactory(type, settings)
        let previousProvider = sttProvider
        sttProvider = nil
        await previousProvider?.teardown()
        guard loadGeneration == sttProviderLoadGeneration else {
            await provider.teardown()
            return
        }

        do {
            try await provider.setup()
            guard loadGeneration == sttProviderLoadGeneration else {
                await provider.teardown()
                return
            }
            let validation = provider.validate()
            sttProvider = provider
            if validation.isValid {
                whisperModelState = .ready
            } else {
                activeSTTProviderConfigurationKey = nil
                whisperModelState = .error(validation.message)
            }
        } catch {
            await provider.teardown()
            guard loadGeneration == sttProviderLoadGeneration else { return }
            activeSTTProviderConfigurationKey = nil
            whisperModelState = .error(error.localizedDescription)
        }
    }

    func sttProviderConfigurationKey(for type: STTProviderType) -> String {
        switch type {
        case .whisperKit:
            "whisperKit:\(settings.whisperModelId)"
        case .groq:
            "groq:\(settings.groqApiKey.hashValue)"
        case .mlxAudio:
            "mlxAudio:\(settings.mlxAudioModelId)"
        }
    }

    func switchLLMProvider(to type: LLMProviderType) async {
        await llmProvider?.teardown()
        if type != .local {
            MLXMemoryControl.releaseCachedBuffers()
        }
        llmModelState = .loading
        switch type {
            case .none:
                llmProvider = NoneProvider()
                llmModelState = .ready
            case .local:
                let spec = LocalModelSpec.find(settings.llmModelId)
                let provider: any LLMProvider
                if spec?.runtime == .python {
                    provider = MLXLMPythonProvider(modelId: settings.llmModelId) { [weak self] phase in
                        guard let self else { return }
                        switch phase {
                        case .uvSync:
                            self.llmModelState = .loading
                        case let .downloading(progress):
                            self.llmModelState = .downloading(progress: progress)
                        case .loading:
                            self.llmModelState = .loading
                        }
                    }
                } else if spec?.capability == .vision {
                    provider = LocalVisionProvider(modelId: settings.llmModelId)
                } else {
                    provider = LocalTextProvider(modelId: settings.llmModelId)
                }
                llmProvider = provider
                // Vision 모델은 스크린샷 자동 활성화
                if provider.supportsVision {
                    settings.isScreenshotContextEnabled = true
                }
                do {
                    try await provider.setup()
                    let validation = provider.validate()
                    llmModelState = validation.isValid ? .ready : .error(validation.message)
                } catch {
                    llmModelState = .error(error.localizedDescription)
                }
            case .openai:
                settings.isScreenshotContextEnabled = true
                let provider = OpenAIProvider(
                    model: settings.openaiModel,
                    authService: authService,
                    oauthService: oauthService
                )
                llmProvider = provider
                do {
                    try await provider.setup()
                    let validation = provider.validate()
                    llmModelState = validation.isValid ? .ready : .error(validation.message)
                } catch {
                    llmModelState = .error(error.localizedDescription)
                }
            case .groq:
                let provider = GroqLLMProvider(
                    model: settings.groqLLMModel,
                    apiKey: settings.groqApiKey
                )
                llmProvider = provider
                if provider.supportsVision {
                    settings.isScreenshotContextEnabled = true
                }
                do {
                    try await provider.setup()
                    let validation = provider.validate()
                    llmModelState = validation.isValid ? .ready : .error(validation.message)
                } catch {
                    llmModelState = .error(error.localizedDescription)
                }
            case .openaiCompatible:
                let provider = OpenAICompatibleProvider(
                    baseURL: settings.openaiCompatibleBaseURL,
                    apiKey: settings.openaiCompatibleAPIKey,
                    modelId: settings.openaiCompatibleModelId,
                    supportsVision: settings.openaiCompatibleSupportsVision
                )
                llmProvider = provider
                if provider.supportsVision {
                    settings.isScreenshotContextEnabled = true
                }
                do {
                    try await provider.setup()
                    let validation = provider.validate()
                    llmModelState = validation.isValid ? .ready : .error(validation.message)
                } catch {
                    llmModelState = .error(error.localizedDescription)
                }
        }
    }

    func addToHistory(original: String, corrected: String?) {
        let record = TranscriptionRecord(
            id: UUID(),
            timestamp: Date(),
            originalText: original,
            correctedText: corrected,
            language: nil
        )
        transcriptionHistory.insert(record, at: 0)
        // Keep last 100 entries
        if transcriptionHistory.count > 100 {
            transcriptionHistory = Array(transcriptionHistory.prefix(100))
        }
    }

    func clearError() {
        currentError = nil
    }

    // MARK: - History Persistence

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(transcriptionHistory) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: Self.historyKey),
           let history = try? JSONDecoder().decode([TranscriptionRecord].self, from: data)
        {
            transcriptionHistory = history
        }
    }
}
