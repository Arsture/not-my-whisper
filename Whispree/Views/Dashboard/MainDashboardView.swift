import SwiftUI

struct MainDashboardView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var modelManager: ModelManager
    @ObservedObject private var permissions = PermissionManager.shared
    @State private var modelDownloadError: String?
    @State private var selectedScreenshot: CapturedScreenshot?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection
                .padding(24)

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // Recording status + waveform
                    recordingSection

                    // Screenshot context strip
                    if !appState.capturedScreenshots.isEmpty {
                        screenshotStripSection
                    }

                    // Accessibility warning
                    if permissions.accessibility != .granted {
                        accessibilityWarningSection
                    }

                    // Providers
                    providersSection
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidBackground()
        .overlay {
            if let screenshot = selectedScreenshot, let image = screenshot.image {
                screenshotOverlay(screenshot: screenshot, image: image)
            }
        }
    }

    // MARK: - Screenshot Overlay

    private func screenshotOverlay(screenshot: CapturedScreenshot, image: NSImage) -> some View {
        ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()
                .onTapGesture { selectedScreenshot = nil }

            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "app.fill")
                        .foregroundStyle(DesignTokens.accentPrimary)
                    Text(screenshot.appName)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
                    Text(screenshot.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                    Button {
                        selectedScreenshot = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)

                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.5), radius: 20)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: selectedScreenshot?.id)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Image(systemName: "waveform.circle.fill")
                .font(.title)
                .foregroundStyle(DesignTokens.accentPrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Whispree")
                    .font(.title2.bold())
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            Spacer()
            statusBadge
        }
    }

    private var statusText: String {
        if appState.isRecording {
            let activeQueueCount = appState.dictationQueueSnapshot.activeCount
            if activeQueueCount > 0 {
                return "Recording... \(activeQueueCount) item(s) queued"
            }
            return "Recording..."
        }
        if appState.dictationQueueSnapshot.deliveryReadyCount > 0 {
            return "Ready to insert queued result"
        }
        if appState.transcriptionState == .transcribing {
            let count = appState.dictationQueueSnapshot.processingCount
            return count > 1 ? "Transcribing \(count) items..." : "Transcribing..."
        }
        if appState.transcriptionState == .correcting {
            let count = appState.dictationQueueSnapshot.processingCount
            return count > 1 ? "Correcting \(count) items..." : "Correcting..."
        }
        if appState.whisperModelState != .ready {
            return "Model not ready"
        }
        return "Ready - press hotkey to record"
    }

    private var statusColor: Color {
        if appState.isRecording { return DesignTokens.textColor(for: .danger) }
        if appState.transcriptionState.isActive { return DesignTokens.textColor(for: .warning) }
        if appState.whisperModelState == .ready { return DesignTokens.textColor(for: .success) }
        return DesignTokens.textColor(for: .secondary)
    }

    private var statusBadge: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
    }

    // MARK: - Recording

    private var recordingSection: some View {
        VStack(spacing: 8) {
            if appState.isRecording {
                ScrollingWaveformView()
                    .frame(height: 56)
                    .padding(.horizontal, 4)

                Text("Listening... (ESC to cancel)")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.semanticColors(for: .danger).foreground)
            } else if appState.transcriptionState == .transcribing {
                ProgressView()
                    .scaleEffect(0.8)
                Text(queueProcessingText(fallback: "Transcribing your speech..."))
                    .font(.caption)
                    .foregroundStyle(DesignTokens.semanticColors(for: .warning).foreground)
            } else if appState.transcriptionState == .correcting {
                ProgressView()
                    .scaleEffect(0.8)
                Text(queueProcessingText(fallback: "Applying LLM correction..."))
                    .font(.caption)
                    .foregroundStyle(DesignTokens.accentPrimary)
            } else {
                Image(systemName: "mic.circle")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary.opacity(0.5))
                Text("Press hotkey to start recording")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 92)
        .background(DesignTokens.surfaceBackgroundView(role: .card))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous))
    }

    private func queueProcessingText(fallback: String) -> String {
        let active = appState.dictationQueueSnapshot.activeCount
        guard active > 1 else { return fallback }
        return "\(active) dictations in queue · insertion remains FIFO"
    }

    // MARK: - Accessibility Warning

    private var accessibilityWarningSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignTokens.semanticColors(for: .warning).foreground)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility 권한 필요")
                    .font(.caption.bold())
                Text("텍스트 자동 삽입에 손쉬운 사용 권한이 필요합니다")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("허용") {
                PermissionManager.shared.requestAccessibility()
            }
            .font(.caption)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        .background(DesignTokens.surfaceBackgroundView(role: .inset, cornerRadius: 18))
    }

    // MARK: - Transcription

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last Transcription")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if !appState.finalText.isEmpty {
                    Button {
                        let text = appState.correctedText.isEmpty ? appState.finalText : appState.correctedText
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Copy to clipboard")
                }
            }

            if appState.finalText.isEmpty {
                Text("아직 녹음 없음 — 핫키를 눌러 녹음을 시작하세요")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                // Raw STT result
                VStack(alignment: .leading, spacing: 2) {
                    Text("STT Result")
                        .font(.caption2)
                        .foregroundStyle(DesignTokens.textColor(for: .tertiary))
                    Text(appState.finalText)
                        .font(.body)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }

                // LLM corrected if available
                if !appState.correctedText.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LLM Corrected")
                            .font(.caption2)
                            .foregroundStyle(DesignTokens.textColor(for: .accent))
                        Text(appState.correctedText)
                            .font(.body)
                            .textSelection(.enabled)
                            .lineLimit(4)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.surfaceBackgroundView(role: .card))
    }

    // MARK: - Screenshot Strip

    private var screenshotStripSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "camera.viewfinder")
                    .foregroundStyle(DesignTokens.accentPrimary)
                Text("스크린 컨텍스트")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(appState.capturedScreenshots.count)장")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(appState.capturedScreenshots) { screenshot in
                        screenshotThumbnail(screenshot)
                    }
                }
            }
        }
        .padding(12)
        .background(DesignTokens.surfaceBackgroundView(role: .card))
    }

    private func screenshotThumbnail(_ screenshot: CapturedScreenshot) -> some View {
        Button {
            selectedScreenshot = screenshot
        } label: {
            VStack(spacing: 4) {
                if let image = screenshot.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 120, height: 75)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.secondary.opacity(0.2), lineWidth: 1)
                        )
                }
                Text(screenshot.appName)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 120)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Provider Status

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Providers")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                // STT
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "mic.fill")
                            .frame(width: 20)
                        Text("STT")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Picker("", selection: sttProviderBinding) {
                            ForEach(STTProviderType.allCases, id: \.self) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .frame(width: 180)
                        providerStateBadge(appState.whisperModelState)
                    }

                    if appState.settings.sttProviderType == .groq, appState.settings.groqApiKey.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(DesignTokens.semanticColors(for: .warning).foreground)
                                .font(.caption2)
                            Text("STT 설정에서 Groq API Key를 입력하세요")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)

                Divider().padding(.horizontal, 14)

                // LLM
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: llmProviderIcon)
                            .frame(width: 20)
                        Text("LLM")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Picker("", selection: llmProviderBinding) {
                            ForEach(LLMProviderType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .frame(width: 180)
                        if appState.settings.llmProviderType != .none {
                            providerStateBadge(appState.llmModelState)
                        }
                    }

                    if appState.settings.llmProviderType == .openai {
                        Text(appState.settings.openaiModel.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if appState.settings.llmProviderType == .local {
                        let spec = LocalModelSpec.find(appState.settings.llmModelId)
                        HStack(spacing: 4) {
                            Text(spec?.displayName ?? appState.settings.llmModelId)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if spec?.capability == .vision {
                                Image(systemName: "eye")
                                    .font(.caption2)
                                    .foregroundStyle(DesignTokens.accentPrimary)
                            }
                        }
                    } else if appState.settings.llmProviderType == .openaiCompatible {
                        HStack(spacing: 4) {
                            Text(appState.settings.openaiCompatibleModelId)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if appState.settings.openaiCompatibleSupportsVision {
                                Image(systemName: "eye")
                                    .font(.caption2)
                                    .foregroundStyle(DesignTokens.accentPrimary)
                            }
                        }
                    } else if appState.settings.llmProviderType == .groq {
                        HStack(spacing: 4) {
                            Text(appState.settings.groqLLMModel.displayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if appState.settings.groqLLMModel.supportsVision {
                                Image(systemName: "eye")
                                    .font(.caption2)
                                    .foregroundStyle(DesignTokens.accentPrimary)
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
        .padding(16)
        .background(DesignTokens.surfaceBackgroundView(role: .card))
    }

    private var sttProviderBinding: Binding<STTProviderType> {
        Binding(
            get: { appState.settings.sttProviderType },
            set: { newType in
                appState.settings.sttProviderType = newType
                Task { await appState.switchSTTProvider(to: newType) }
            }
        )
    }

    private var llmProviderBinding: Binding<LLMProviderType> {
        Binding(
            get: { appState.settings.llmProviderType },
            set: { newType in
                appState.settings.llmProviderType = newType
                appState.settings.isLLMEnabled = (newType != .none)
                Task { await appState.switchLLMProvider(to: newType) }
            }
        )
    }

    private var llmProviderIcon: String {
        switch appState.settings.llmProviderType {
            case .none: return "xmark.circle"
            case .local:
                let spec = LocalModelSpec.find(appState.settings.llmModelId)
                return spec?.capability == .vision ? "eye" : "text.badge.checkmark"
            case .openai: return "globe"
            case .openaiCompatible:
                return appState.settings.openaiCompatibleSupportsVision ? "eye" : "globe"
            case .groq:
                return appState.settings.groqLLMModel.supportsVision ? "eye" : "bolt.horizontal.fill"
        }
    }

    @ViewBuilder
    private func providerStateBadge(_ state: ModelState) -> some View {
        switch state {
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.semanticColors(for: .success).foreground)
            case .notDownloaded, .error:
                Label("Not Ready", systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.semanticColors(for: .danger).foreground)
            case let .downloading(progress):
                if progress > 0 {
                    HStack(spacing: 4) {
                        ProgressView(value: progress)
                            .frame(width: 50)
                        Text("\(Int(progress * 100))%")
                            .font(.caption2)
                    }
                } else {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.5)
                        Text("Downloading...")
                            .font(.caption2)
                    }
                }
            case .queued, .loading:
                HStack(spacing: 4) {
                    ProgressView().scaleEffect(0.5)
                    Text("Loading...")
                        .font(.caption2)
                }
        }
    }
}
