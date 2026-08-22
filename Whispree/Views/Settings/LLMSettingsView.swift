import SwiftUI

struct LLMSettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var modelManager: ModelManager
    @State private var customPrompt: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // LLM Provider
                LiquidSection("교정 엔진") {
                    Picker("Provider", selection: Binding(
                        get: { appState.settings.llmProviderType },
                        set: { (newValue: LLMProviderType) in
                            appState.settings.llmProviderType = newValue
                            appState.settings.isLLMEnabled = (newValue != .none)
                            Task { await appState.switchLLMProvider(to: newValue) }
                        }
                    )) {
                        ForEach(LLMProviderType.allCases, id: \.self) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .labelsHidden()
                }

                // Local Model Picker
                if appState.settings.llmProviderType == .local {
                    localModelSection

                    if appState.llmProvider?.supportsVision == true {
                        screenshotSection
                    }
                }

                // OpenAI sections
                if appState.settings.llmProviderType == .openai {
                    openAIModelSection
                    screenshotSection
                    openAIAuthSection
                }

                // Groq sections
                if appState.settings.llmProviderType == .groq {
                    groqModelSection
                    if appState.settings.groqLLMModel.supportsVision {
                        screenshotSection
                    }
                    groqApiKeySection
                }

                // OpenAI-compatible sections
                if appState.settings.llmProviderType == .openaiCompatible {
                    openAICompatibleSection
                    if appState.settings.openaiCompatibleSupportsVision {
                        screenshotSection
                    }
                }

                // Model Status
                if appState.settings.llmProviderType == .local,
                   !appState.llmModelState.isReady
                {
                    modelStatusNotice
                }

                // Correction Mode + System Prompt
                if appState.settings.llmProviderType != .none {
                    correctionModeSection
                    systemPromptSection
                }
            }
            .padding(24)
        }
        .liquidBackground()
        .onAppear {
            customPrompt = appState.settings.customLLMPrompt
                ?? CorrectionPrompts.defaultSystemPrompt
        }
        .task {
            await appState.authService.checkAuthAsync()
            await appState.oauthService.checkAuthAsync()
            await modelManager.refreshAllCacheStatesAsync()
        }
    }

    // MARK: - Local Model

    private var localModelSection: some View {
        LiquidSection("로컬 모델") {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    Text("\(DeviceCapability.current.chipName) · \(DeviceCapability.current.totalRAMGB) GB")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.bottom, 8)

                let sttOverhead: Int64 = {
                    switch appState.settings.sttProviderType {
                    case .whisperKit: return 1_500_000_000
                    case .mlxAudio: return 1_000_000_000
                    case .groq: return 0
                    }
                }()

                ForEach(Array(LocalModelSpec.supported.enumerated()), id: \.element.id) { index, spec in
                    if index > 0 { Divider() }
                    localModelCard(spec, sttOverhead: sttOverhead)
                }

                if let spec = LocalModelSpec.find(appState.settings.llmModelId),
                   spec.capability == .vision
                {
                    Label("이 모델은 스크린샷 컨텍스트를 활용합니다", systemImage: "eye")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.accentPrimary)
                        .padding(.top, 8)
                }
            }
        }
    }

    private func localModelCard(_ spec: LocalModelSpec, sttOverhead: Int64) -> some View {
        let compat = spec.compatibility(otherModelSizeBytes: sttOverhead)
        let isSelected = appState.settings.llmModelId == spec.id
        let isCached = modelManager.modelCacheStates[spec.id] ?? false
        let isDownloading = modelManager.downloadingModelIds.contains(spec.id)
        let errorMsg = modelManager.modelErrors[spec.id]

        let isQueued = modelManager.queuedModelIds.contains(spec.id)

        let state: ModelState = {
            if isCached { return .ready }
            if isQueued { return .queued }
            if isDownloading {
                if let p = modelManager.downloadProgress[spec.id] {
                    return .downloading(progress: p)
                }
                return .loading
            }
            if let err = errorMsg { return .error(err) }
            return .notDownloaded
        }()

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                appState.settings.llmModelId = spec.id
                if isCached {
                    Task { await appState.switchLLMProvider(to: .local) }
                }
            } label: {
                HStack(alignment: .center) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? DesignTokens.accentPrimary : DesignTokens.textTertiary)
                        .font(.body)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(spec.displayName)
                                .font(.subheadline.weight(.medium))
                            if spec.capability == .vision {
                                Image(systemName: "eye")
                                    .font(.caption2)
                                    .foregroundStyle(DesignTokens.accentPrimary)
                            }
                            if !isCached && !isDownloading {
                                Text("다운로드 필요")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(DesignTokens.semanticColors(for: .warning).foreground)
                            }
                        }
                        Text(spec.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    ModelMetricsView(
                        sizeText: spec.sizeDescription,
                        ramPercent: compat.ramUsagePercent,
                        tokPerSec: compat.estimatedTokPerSec,
                        latencyMs: nil,
                        qualityScore: spec.qualityScore,
                        grade: compat.grade
                    )
                }
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .disabled(isDownloading || isQueued)

            if isSelected {
                modelStateControls(spec: spec, state: state, isQueued: isQueued)
            }
        }
    }

    @ViewBuilder
    private func modelStateControls(spec: LocalModelSpec, state: ModelState, isQueued: Bool = false) -> some View {
        switch state {
        case .notDownloaded:
            HStack {
                Spacer()
                Button {
                    Task {
                        await modelManager.downloadLLMModel(modelId: spec.id)
                        if modelManager.modelCacheStates[spec.id] == true {
                            await appState.switchLLMProvider(to: .local)
                        }
                    }
                } label: {
                    Label("다운로드 (\(spec.sizeDescription))", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.leading, 28)

        case .queued:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("대기 중... (다른 모델 다운로드 완료 후 시작)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("취소", role: .cancel) {
                    modelManager.cancelLLMDownload(modelId: spec.id)
                }
                .font(.caption).controlSize(.small)
            }
            .padding(.leading, 28)

        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(isQueued ? "대기 중... (다른 모델 다운로드 완료 후 시작)" : "다운로드 준비 중...")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.leading, 28)

        case let .downloading(progress):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                Text("\(Int(progress * 100))% 다운로드 중...")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.leading, 28)

        case .ready:
            HStack {
                Label("다운로드됨", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("삭제", role: .destructive) {
                    modelManager.deleteLLMModel(modelId: spec.id)
                }
                .font(.caption).controlSize(.small)
            }
            .padding(.leading, 28)

        case let .error(msg):
            HStack(spacing: 8) {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignTokens.semanticColors(for: .danger).foreground)
                    .font(.caption).lineLimit(2)
                Spacer()
                Button("재시도") {
                    Task { await modelManager.downloadLLMModel(modelId: spec.id) }
                }
                .font(.caption).controlSize(.small)
            }
            .padding(.leading, 28)
        }
    }

    // MARK: - OpenAI Model

    private var openAIModelSection: some View {
        LiquidSection("OpenAI 모델") {
            VStack(spacing: 0) {
                ForEach(Array(OpenAIModel.allCases.enumerated()), id: \.element) { index, model in
                    if index > 0 { Divider() }
                    openAIModelCard(model)
                }
            }
        }
    }

    private func openAIModelCard(_ model: OpenAIModel) -> some View {
        let isSelected = appState.settings.openaiModel == model

        return Button {
            appState.settings.openaiModel = model
        } label: {
            HStack(alignment: .center) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? DesignTokens.accentPrimary : DesignTokens.textTertiary)
                    .font(.body)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.subheadline.weight(.medium))
                    Text(model.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ModelMetricsView(
                    sizeText: "☁️",
                    ramPercent: nil,
                    tokPerSec: nil,
                    latencyMs: model.estimatedLatencyMs,
                    qualityScore: model.qualityScore,
                    grade: .runsGreat
                )
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    // MARK: - Groq Model

    private var groqModelSection: some View {
        LiquidSection("Groq 모델") {
            VStack(spacing: 0) {
                ForEach(Array(GroqLLMModel.allCases.enumerated()), id: \.element) { index, model in
                    if index > 0 { Divider() }
                    groqModelCard(model)
                }
            }
        }
    }

    private func groqModelCard(_ model: GroqLLMModel) -> some View {
        let isSelected = appState.settings.groqLLMModel == model

        return Button {
            appState.settings.groqLLMModel = model
            Task { await appState.switchLLMProvider(to: .groq) }
        } label: {
            HStack(alignment: .center) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? DesignTokens.accentPrimary : DesignTokens.textTertiary)
                    .font(.body)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(model.displayName)
                            .font(.subheadline.weight(.medium))
                        if model.supportsVision {
                            Image(systemName: "eye")
                                .font(.caption2)
                                .foregroundStyle(DesignTokens.accentPrimary)
                        }
                    }
                    Text(model.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ModelMetricsView(
                    sizeText: "☁️",
                    ramPercent: nil,
                    tokPerSec: nil,
                    latencyMs: model.estimatedLatencyMs,
                    qualityScore: model.qualityScore,
                    grade: .runsGreat
                )
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    // MARK: - Groq API Key

    private var groqApiKeySection: some View {
        LiquidSection("Groq API Key") {
            VStack(alignment: .leading, spacing: 10) {
                SecureField("API Key", text: Binding(
                    get: { appState.settings.groqApiKey },
                    set: {
                        appState.settings.groqApiKey = $0
                        Task { await appState.switchLLMProvider(to: .groq) }
                    }
                ))
                .textFieldStyle(.roundedBorder)

                if appState.settings.groqApiKey.isEmpty {
                    Label("console.groq.com에서 무료 API Key를 발급받으세요 (STT와 동일 키)", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.semanticColors(for: .warning).foreground)
                } else {
                    Label("API Key 설정됨 (STT와 공유)", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Screenshot Context

    // MARK: - OpenAI-compatible API

    private var openAICompatibleSection: some View {
        LiquidSection("OpenAI 호환 API") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Base URL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("https://api.openai.com/v1", text: Binding(
                        get: { appState.settings.openaiCompatibleBaseURL },
                        set: {
                            appState.settings.openaiCompatibleBaseURL = $0
                            Task { await appState.switchLLMProvider(to: .openaiCompatible) }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key (선택 — 로컬 서버는 비워도 됨)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("API Key", text: Binding(
                        get: { appState.settings.openaiCompatibleAPIKey },
                        set: {
                            appState.settings.openaiCompatibleAPIKey = $0
                            Task { await appState.switchLLMProvider(to: .openaiCompatible) }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("모델 ID")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("예: gpt-4o-mini, deepseek-chat", text: Binding(
                        get: { appState.settings.openaiCompatibleModelId },
                        set: {
                            appState.settings.openaiCompatibleModelId = $0
                            Task { await appState.switchLLMProvider(to: .openaiCompatible) }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                Toggle(isOn: Binding(
                    get: { appState.settings.openaiCompatibleSupportsVision },
                    set: {
                        appState.settings.openaiCompatibleSupportsVision = $0
                        if $0 { appState.settings.isScreenshotContextEnabled = true }
                        Task { await appState.switchLLMProvider(to: .openaiCompatible) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vision 지원 모델")
                            .font(.subheadline.weight(.medium))
                        Text("모델이 이미지 입력을 지원하면 스크린샷 컨텍스트를 활용합니다")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    private var screenshotSection: some View {
        LiquidSection("스크린샷 컨텍스트") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("활성화")
                            .font(.subheadline.weight(.medium))
                        Text("녹음 시 화면을 캡처하여 교정 정확도를 높입니다")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { appState.settings.isScreenshotContextEnabled },
                        set: {
                            appState.settings.isScreenshotContextEnabled = $0
                            if !$0 { appState.settings.isScreenshotPasteEnabled = false }
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }

                if appState.settings.isScreenshotContextEnabled {
                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("에이전트에 전달")
                                .font(.subheadline.weight(.medium))
                            Text("텍스트 삽입 후 캡처된 스크린샷을 대상 앱에 이미지로 붙여넣습니다")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { appState.settings.isScreenshotPasteEnabled },
                            set: { appState.settings.isScreenshotPasteEnabled = $0 }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            }
        }
    }

    // MARK: - OpenAI Auth

    private var openAIAuthSection: some View {
        LiquidSection("OpenAI 인증") {
            VStack(alignment: .leading, spacing: 8) {
                if appState.authService.isLoggedIn {
                    HStack {
                        Text("인증 방식:")
                        Spacer()
                        Label("Codex CLI", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    if let accountId = appState.authService.currentAccountId {
                        HStack {
                            Text("Account:")
                            Spacer()
                            Text(accountId)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if appState.oauthService.isLoggedIn {
                    HStack {
                        Text("인증 방식:")
                        Spacer()
                        Label("OpenAI 로그인", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    Button("로그아웃") {
                        appState.oauthService.logout()
                    }
                    .font(.caption)
                } else {
                    Label("로그인이 필요합니다", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignTokens.semanticColors(for: .warning).foreground)
                        .font(.caption)

                    Button {
                        Task { await appState.oauthService.startLogin() }
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                            Text("OpenAI 로그인")
                        }
                    }
                    .disabled(appState.oauthService.isLoggingIn)

                    if appState.oauthService.isLoggingIn {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("브라우저에서 로그인 중...")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    if let error = appState.oauthService.loginError {
                        Label(error, systemImage: "xmark.circle.fill")
                            .foregroundStyle(DesignTokens.semanticColors(for: .danger).foreground)
                            .font(.caption)
                    }

                    Text("Codex CLI가 설치되어 있으면 자동 감지됩니다")
                        .font(.caption).foregroundStyle(.secondary)

                    Button("Codex 인증 확인") {
                        appState.authService.checkAuth()
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - Model Status Notice

    private var modelStatusNotice: some View {
        HStack(spacing: 8) {
            let isCached = modelManager.modelCacheStates[appState.settings.llmModelId] ?? false
            if case let .downloading(progress) = appState.llmModelState {
                ProgressView(value: progress).controlSize(.small).frame(width: 80)
                Text(String(format: "모델 다운로드 중... %d%%", Int(progress * 100)))
                    .font(.caption).foregroundStyle(.secondary)
            } else if isCached {
                ProgressView().controlSize(.small)
                Text("모델 로딩 중...")
                    .font(.caption).foregroundStyle(.secondary)
            } else if case .loading = appState.llmModelState {
                ProgressView().controlSize(.small)
                Text("준비 중... (uv 의존성 설치 또는 모델 로딩)")
                    .font(.caption).foregroundStyle(.secondary)
            } else if case let .error(msg) = appState.llmModelState {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignTokens.semanticColors(for: .danger).foreground)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.semanticColors(for: .danger).foreground)
                    .lineLimit(2)
            } else {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(DesignTokens.accentPrimary)
                Text("다운로드 탭에서 '\(LocalModelSpec.find(appState.settings.llmModelId)?.displayName ?? "모델")' 을 다운로드하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(DesignTokens.surfaceBackgroundView(role: .card))
    }

    // MARK: - Correction Mode

    private var correctionModeSection: some View {
        LiquidSection("교정 모드") {
            VStack(spacing: 0) {
                ForEach(Array(CorrectionMode.allCases.enumerated()), id: \.element) { index, mode in
                    if index > 0 { Divider() }
                    correctionModeRow(mode)
                }
            }
        }
    }

    private func correctionModeRow(_ mode: CorrectionMode) -> some View {
        let isSelected = appState.settings.correctionMode == mode

        return Button {
            appState.settings.correctionMode = mode
            if mode == .custom {
                customPrompt = appState.settings.customLLMPrompt
                    ?? CorrectionPrompts.defaultSystemPrompt
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? DesignTokens.accentPrimary : DesignTokens.textTertiary)
                    .font(.body)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(.subheadline.weight(.medium))
                    Text(mode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    // MARK: - System Prompt

    private var systemPromptSection: some View {
        LiquidSection("시스템 프롬프트") {
            VStack(alignment: .leading, spacing: 10) {
                if appState.settings.correctionMode == .custom {
                    TextEditor(text: $customPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 140)
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .background(DesignTokens.surfaceBackgroundView(role: .inset, cornerRadius: 12))

                    HStack {
                        Spacer()
                        Button("저장") {
                            appState.settings.customLLMPrompt = customPrompt
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                } else {
                    ScrollView {
                        Text(currentPromptPreview)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(12)
                            .textSelection(.enabled)
                    }
                    .frame(height: 180)
                    .background(DesignTokens.surfaceBackgroundView(role: .inset, cornerRadius: 12))

                    Text("\"Custom\" 모드에서 직접 편집할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var currentPromptPreview: String {
        CorrectionPrompts.prompt(
            for: appState.settings.correctionMode,
            language: appState.settings.language
        )
    }
}
