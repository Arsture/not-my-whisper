import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class RecordingCoordinator: ObservableObject {
    private let appState: AppState
    private let audioService: AudioService
    private let textInsertionService: TextInsertionService

    private let queue = DictationQueueState()
    private var processingTasks: [DictationJobID: Task<Void, Never>] = [:]
    private var deliveryTask: Task<Void, Never>?
    private var levelCancellable: AnyCancellable?
    private var bandsCancellable: AnyCancellable?
    private var thinkingPauseCancellable: AnyCancellable?
    private var workspaceObserver: AnyCancellable?
    private var activeRecordingContext: ExternalContext?
    private var chromeCaretTrackingTask: Task<Void, Never>?
    private var lastExternalApp: NSRunningApplication?
    private let continuousCapture = ContinuousScreenCaptureService()
    private let mediaPlayback = MediaPlaybackService()
    private let browserContext = BrowserContextService()
    private let terminalContext = TerminalContextService()

    init(
        appState: AppState,
        audioService: AudioService,
        textInsertionService: TextInsertionService
    ) {
        self.appState = appState
        self.audioService = audioService
        self.textInsertionService = textInsertionService

        // Pipe audio level + frequency bands to appState for UI
        levelCancellable = audioService.$currentLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak appState] level in
                appState?.currentAudioLevel = level
            }

        bandsCancellable = audioService.$frequencyBands
            .receive(on: DispatchQueue.main)
            .sink { [weak appState] bands in
                appState?.frequencyBands = bands
            }

        thinkingPauseCancellable = audioService.$isThinkingPause
            .receive(on: DispatchQueue.main)
            .sink { [weak appState] isPaused in
                guard let appState else { return }
                appState.isThinkingPause = appState.settings.vadEnabled ? isPaused : false
            }

        // Track last non-Whispree frontmost app for text insertion.
        workspaceObserver = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                Task { @MainActor [weak self] in
                    self?.lastExternalApp = app
                }
            }
    }

    func startRecording() {
        guard !audioService.isRecording else { return }
        // Text/image insertion is intentionally atomic and very short. Do not start a
        // new recording in the middle of a paste sequence because that could send text
        // to the wrong target while the microphone overlay is active.
        guard appState.transcriptionState != .inserting else { return }
        guard let sttProvider = appState.sttProvider else {
            appState.currentError = .sttError("STT 프로바이더가 설정되지 않았습니다.")
            return
        }
        let sttValidation = sttProvider.validate()
        guard sttValidation.isValid else {
            appState.currentError = .sttError(sttValidation.message)
            return
        }

        let shouldSuspendSelection = appState.transcriptionState == .selectingScreenshots
        queue.setRecordingActive(true)
        refreshProjectedState()
        if shouldSuspendSelection {
            suspendActiveScreenshotSelectionForRecording()
        }

        let previousApp = currentExternalTargetApp()
        activeRecordingContext = captureTargetContext(previousApp)
        startChromeCaretTrackingIfNeeded()

        // 연속 스크린샷 캡처 시작 (Vision 지원 프로바이더 + 토글 ON일 때)
        if appState.settings.isScreenshotContextEnabled,
           appState.llmProvider?.supportsVision == true
        {
            appState.capturedScreenshots = []
            continuousCapture.onCapture = { [weak appState] screenshot in
                appState?.capturedScreenshots.append(screenshot)
            }
            continuousCapture.startMonitoring()
        }

        do {
            try audioService.startRecording(channelSelection: appState.settings.audioInputChannel)
            appState.transcriptionState = .recording
            appState.isRecording = true
            appState.partialText = ""
            appState.finalText = ""
            appState.correctedText = ""
            refreshProjectedState()

            // 재생 중인 음악/영상 일시정지 (Apple Music, Spotify, YouTube 등)
            if appState.settings.pauseMediaDuringRecording {
                mediaPlayback.pauseIfPlaying()
            }
        } catch {
            continuousCapture.reset()
            queue.setRecordingActive(false)
            activeRecordingContext = nil
            appState.isRecording = false
            appState.currentError = .sttError("Failed to start recording: \(error.localizedDescription)")
            scheduleProcessingAndDelivery()
            refreshProjectedState()
        }
    }

    func stopRecording() {
        guard audioService.isRecording else { return }

        // 연속 캡처 중지 — 마지막 pending debounce flush
        let screenshots = continuousCapture.stopMonitoring()

        let audioBuffer = audioService.stopRecording()
        appState.isRecording = false
        queue.setRecordingActive(false)

        // 일시정지했던 음악/영상 재개 (LLM 후처리 중에 다시 들리도록 녹음 종료 즉시)
        Task { await mediaPlayback.resumeIfPaused() }

        defer {
            activeRecordingContext = nil
            scheduleProcessingAndDelivery()
            refreshProjectedState()
        }

        // Check for empty audio
        guard !audioBuffer.isEmpty else { return }

        // Check if audio has any significant content
        let maxAmplitude = audioBuffer.map { abs($0) }.max() ?? 0
        guard maxAmplitude > 0.01 else { return }

        let snapshot = makeJobSnapshot()
        let enqueued = queue.enqueue(
            snapshot: snapshot,
            audio: .memory(audioBuffer),
            targetContext: activeRecordingContext,
            screenshots: screenshots
        )
        startChromeCaretTrackingIfNeeded()
        if enqueued == nil {
            appState.currentError = .sttError("녹음된 오디오가 비어 있습니다.")
        }
    }

    func cancel() {
        if audioService.isRecording {
            cancelActiveRecordingOnly()
            return
        }

        if let jobID = queue.activeDeliveryJobID {
            cancel(jobID: jobID)
        } else if let jobID = queue.foregroundJobID {
            cancel(jobID: jobID)
        } else {
            refreshProjectedState()
        }
    }

    // MARK: - Queue scheduling

    private func scheduleProcessingAndDelivery() {
        scheduleSTTJobs()
        scheduleLLMJobs()
        scheduleDelivery()
    }

    private func scheduleSTTJobs() {
        while let jobID = queue.startNextSTT() {
            processingTasks[jobID] = Task { [weak self] in
                await self?.processSTT(jobID: jobID)
            }
        }
    }

    private func scheduleLLMJobs() {
        while let jobID = queue.startNextLLM() {
            processingTasks[jobID] = Task { [weak self] in
                await self?.processLLM(jobID: jobID)
            }
        }
    }

    private func scheduleDelivery() {
        guard deliveryTask == nil,
              let jobID = queue.startDeliveryIfPossible()
        else { return }
        // Publish the head job's screenshots synchronously. The caller projects state right
        // after this returns, so the selection panel can be shown before the delivery task
        // body has had a chance to run.
        if let job = queue.job(id: jobID), job.status == .awaitingScreenshotSelection {
            appState.capturedScreenshots = job.screenshots
        }
        deliveryTask = Task { [weak self] in
            await self?.deliver(jobID: jobID)
        }
    }

    private func processSTT(jobID: DictationJobID) async {
        defer {
            processingTasks[jobID] = nil
            scheduleProcessingAndDelivery()
            refreshProjectedState()
        }

        guard let job = queue.job(id: jobID) else { return }
        guard let audioBuffer = job.audio.samples else {
            queue.failSTT(jobID: jobID, message: "Unsupported queued audio payload")
            return
        }
        guard currentSTTProviderConfigKey() == job.snapshot.sttProviderConfigKey else {
            queue.failSTT(jobID: jobID, message: "STT provider changed before queued job started")
            return
        }
        guard let sttProvider = appState.sttProvider else {
            queue.failSTT(jobID: jobID, message: "No STT provider configured")
            return
        }

        let trimmedBuffer: [Float] = {
            guard job.snapshot.vadEnabled else { return audioBuffer }
            let original = audioBuffer.count
            let trimmed = AudioService.trimSilence(audioBuffer)
            #if DEBUG
            if trimmed.count != original {
                let ratio = Double(trimmed.count) / Double(max(1, original))
                print("[VAD] job#\(job.sequence) \(original) → \(trimmed.count) samples (\(String(format: "%.1f", ratio * 100))%)")
            }
            #endif
            return trimmed
        }()

        do {
            if let whisperProvider = sttProvider as? WhisperKitProvider {
                whisperProvider.domainWordSets = job.snapshot.domainWordSets
            }
            let result = try await sttProvider.transcribe(
                audioBuffer: trimmedBuffer,
                language: job.snapshot.language == .auto ? nil : job.snapshot.language,
                promptTokens: nil
            )
            guard !Task.isCancelled else { return }
            let requiresLLM = shouldRunLLM(for: job)
            queue.completeSTT(jobID: jobID, text: result.text, requiresLLM: requiresLLM)
            appState.finalText = result.text
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            queue.failSTT(jobID: jobID, message: error.localizedDescription)
            appState.currentError = .sttError(error.localizedDescription)
        }
    }

    private func processLLM(jobID: DictationJobID) async {
        defer {
            processingTasks[jobID] = nil
            scheduleProcessingAndDelivery()
            refreshProjectedState()
        }

        guard let job = queue.job(id: jobID) else { return }
        guard currentLLMProviderConfigKey() == job.snapshot.llmProviderConfigKey else {
            queue.failLLMFallbackToRaw(jobID: jobID)
            return
        }
        guard let llmProvider = appState.llmProvider, llmProvider.isReady,
              !(llmProvider is NoneProvider)
        else {
            queue.failLLMFallbackToRaw(jobID: jobID)
            return
        }

        do {
            let screenshotData = job.snapshot.screenshotContextEnabled && llmProvider.supportsVision
                ? job.screenshots.map(\.imageData)
                : []
            let corrected = try await llmProvider.correct(
                text: job.transcribedText,
                systemPrompt: systemPrompt(for: job, includeScreenshotPrompt: !screenshotData.isEmpty),
                glossary: job.snapshot.glossary.isEmpty ? nil : job.snapshot.glossary,
                screenshots: screenshotData
            )
            guard !Task.isCancelled else { return }
            queue.completeLLM(jobID: jobID, correctedText: corrected)
            appState.correctedText = corrected
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            // LLM failure is non-fatal - use raw transcription.
            queue.failLLMFallbackToRaw(jobID: jobID)
            appState.correctedText = ""
        }
    }

    private func deliver(jobID: DictationJobID) async {
        defer {
            deliveryTask = nil
            scheduleDelivery()
            refreshProjectedState()
        }

        guard var job = queue.job(id: jobID) else { return }

        var selectedImages: [Data] = []
        // Whether review is needed was decided by the queue when delivery was admitted;
        // re-deriving it from the snapshot here would let UI and queue truth drift apart.
        if job.status == .awaitingScreenshotSelection {
            selectedImages = await withCheckedContinuation { continuation in
                appState.screenshotSelectionCallback = { selected in
                    continuation.resume(returning: selected)
                }
            }
            appState.screenshotSelectionCallback = nil
            guard !Task.isCancelled else { return }
            queue.setSelectedImages(jobID: jobID, images: selectedImages)
            guard !queue.snapshot.isRecordingActive else {
                queue.pauseActiveDeliveryForRecording(jobID: jobID)
                return
            }
            queue.beginDeliveryAfterScreenshotSelection(jobID: jobID)
        }

        guard let latest = queue.job(id: jobID), !latest.status.isTerminal else { return }
        job = latest
        guard job.snapshot.hasCompletedOnboarding else {
            queue.completeDelivery(jobID: jobID, copiedFallback: true)
            return
        }
        guard !queue.snapshot.isRecordingActive else {
            queue.pauseActiveDeliveryForRecording(jobID: jobID)
            return
        }

        appState.transcriptionState = .inserting
        let textToInsert = job.correctedText.isEmpty ? job.transcribedText : job.correctedText
        let resolvedContext = job.targetContext
        let targetApp = resolvedContext?.app
        restoreTargetContext(resolvedContext)

        let success = await textInsertionService.insertText(textToInsert, targetApp: targetApp)
        if !success {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(textToInsert, forType: .string)
        }

        let imagesToInsert = selectedImages.isEmpty ? job.selectedImages : selectedImages
        if !imagesToInsert.isEmpty, !Task.isCancelled {
            await textInsertionService.insertImages(imagesToInsert, targetApp: targetApp)
        }

        appState.addToHistory(
            original: job.transcribedText,
            corrected: job.correctedText.isEmpty ? nil : job.correctedText
        )
        queue.completeDelivery(jobID: jobID, copiedFallback: !success)
    }

    private func cancel(jobID: DictationJobID) {
        processingTasks[jobID]?.cancel()
        processingTasks[jobID] = nil
        if queue.activeDeliveryJobID == jobID {
            deliveryTask?.cancel()
            deliveryTask = nil
            appState.screenshotSelectionCallback?([])
            appState.screenshotSelectionCallback = nil
        }
        queue.cancelJob(jobID: jobID)
        scheduleProcessingAndDelivery()
        refreshProjectedState()
    }

    private func cancelActiveRecordingOnly() {
        activeRecordingContext = nil
        continuousCapture.reset()
        _ = audioService.stopRecording()
        queue.setRecordingActive(false)
        appState.isRecording = false
        appState.isThinkingPause = false
        Task { await mediaPlayback.resumeIfPaused() }
        scheduleProcessingAndDelivery()
        refreshProjectedState()
    }

    private func startChromeCaretTrackingIfNeeded() {
        guard chromeCaretTrackingTask == nil else { return }
        guard hasTrackableChromeContext() else { return }
        chromeCaretTrackingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let shouldContinue = await self.refreshTrackedChromeCarets()
                if !shouldContinue {
                    await MainActor.run { self.chromeCaretTrackingTask = nil }
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func hasTrackableChromeContext() -> Bool {
        if activeRecordingContext?.isChromeTab == true {
            return true
        }
        return queue.nonTerminalJobs().contains { $0.targetContext?.isChromeTab == true }
    }

    private func refreshTrackedChromeCarets() -> Bool {
        var hasTrackableContext = false
        if let context = activeRecordingContext, context.isChromeTab {
            hasTrackableContext = true
            if let updated = browserContext.refreshChromeCaretIfActive(context) {
                activeRecordingContext = updated
            }
        }

        for job in queue.nonTerminalJobs() {
            guard let context = job.targetContext, context.isChromeTab else { continue }
            hasTrackableContext = true
            if let updated = browserContext.refreshChromeCaretIfActive(context) {
                queue.updateTargetContext(jobID: job.id, targetContext: updated)
            }
        }
        return hasTrackableContext
    }

    private func suspendActiveScreenshotSelectionForRecording() {
        guard let jobID = queue.activeDeliveryJobID else { return }
        deliveryTask?.cancel()
        deliveryTask = nil
        queue.pauseActiveDeliveryForRecording(jobID: jobID)
        appState.screenshotSelectionCallback?([])
        appState.screenshotSelectionCallback = nil
    }

    // MARK: - Snapshot/context helpers

    private func makeJobSnapshot() -> DictationJobSnapshot {
        let enabledSets = appState.settings.domainWordSets.filter(\.isEnabled)
        return DictationJobSnapshot(
            sttProviderType: appState.settings.sttProviderType,
            llmProviderType: appState.settings.llmProviderType,
            llmEnabled: appState.settings.isLLMEnabled,
            sttProviderConfigKey: currentSTTProviderConfigKey(),
            llmProviderConfigKey: currentLLMProviderConfigKey(),
            correctionMode: appState.settings.correctionMode,
            customPrompt: appState.settings.customLLMPrompt,
            language: appState.settings.language,
            glossary: enabledSets.flatMap(\.words),
            domainWordSets: appState.settings.domainWordSets,
            correctionMappings: enabledSets.flatMap(\.corrections),
            screenshotContextEnabled: appState.settings.isScreenshotContextEnabled,
            screenshotPasteEnabled: appState.settings.isScreenshotPasteEnabled,
            hasCompletedOnboarding: appState.settings.hasCompletedOnboarding,
            vadEnabled: appState.settings.vadEnabled
        )
    }

    private func shouldRunLLM(for job: DictationJob) -> Bool {
        let snapshot = job.snapshot
        guard snapshot.llmEnabled, snapshot.llmProviderType != .none else { return false }
        guard currentLLMProviderConfigKey() == snapshot.llmProviderConfigKey else { return false }
        guard let provider = appState.llmProvider, provider.isReady, !(provider is NoneProvider) else { return false }
        return true
    }

    private func currentSTTProviderConfigKey() -> String {
        switch appState.settings.sttProviderType {
        case .whisperKit:
            "whisperKit:\(appState.settings.whisperModelId)"
        case .groq:
            "groq:\(appState.settings.groqApiKey.hashValue)"
        case .mlxAudio:
            "mlxAudio:\(appState.settings.mlxAudioModelId)"
        }
    }

    private func currentLLMProviderConfigKey() -> String {
        switch appState.settings.llmProviderType {
        case .none:
            "none"
        case .local:
            "local:\(appState.settings.llmModelId)"
        case .openai:
            "openai:\(appState.settings.openaiModel.rawValue)"
        case .groq:
            "groq:\(appState.settings.groqLLMModel.rawValue):\(appState.settings.groqApiKey.hashValue)"
        case .openaiCompatible:
            "openaiCompatible:\(appState.settings.openaiCompatibleBaseURL):\(appState.settings.openaiCompatibleModelId):\(appState.settings.openaiCompatibleAPIKey.hashValue)"
        }
    }

    private func systemPrompt(for job: DictationJob, includeScreenshotPrompt: Bool) -> String {
        var systemPrompt: String = switch job.snapshot.correctionMode {
        case .custom:
            job.snapshot.customPrompt ?? CorrectionPrompts.codeSwitchPrompt
        case .standard, .fillerRemoval, .structured:
            CorrectionPrompts.prompt(
                for: job.snapshot.correctionMode,
                language: job.snapshot.language
            )
        }

        if !job.snapshot.correctionMappings.isEmpty {
            let mappingText = job.snapshot.correctionMappings
                .map { "\($0.from) → \($0.to)" }
                .joined(separator: "\n")
            systemPrompt += "\n\n교정 매핑 (왼쪽 표현이 텍스트에 있으면 오른쪽으로 교정):\n" + mappingText
        }

        if includeScreenshotPrompt {
            systemPrompt += CorrectionPrompts.screenshotContextPrompt
        }
        return systemPrompt
    }

    private func currentExternalTargetApp() -> NSRunningApplication? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return lastExternalApp
        }
        return frontmost
    }

    private func captureTargetContext(_ target: NSRunningApplication?) -> ExternalContext? {
        let restoreBrowser = appState.settings.restoreBrowserTab
        let restoreTerminal = appState.settings.restoreTerminalContext
        let targetBundle = target?.bundleIdentifier ?? "nil"
        let isChromeTarget = target.map(BrowserContextService.isChrome) ?? false
        let isITerm2Target = target.map(TerminalContextService.isITerm2) ?? false
        BrowserContextService.logger.info(
            "startRecording: previousApp=\(targetBundle, privacy: .public) restoreBrowser=\(restoreBrowser) isChrome=\(isChromeTarget) restoreTerminal=\(restoreTerminal) isITerm2=\(isITerm2Target)"
        )
        if let target, restoreBrowser, isChromeTarget {
            return browserContext.captureChrome(app: target)
        } else if let target, restoreTerminal, isITerm2Target {
            return terminalContext.captureITerm2(app: target)
        } else if let target {
            return .app(target)
        } else {
            return nil
        }
    }

    private func restoreTargetContext(_ context: ExternalContext?) {
        guard let context else { return }
        switch context {
        case .chromeTab:
            _ = browserContext.restoreChrome(context)
        case .iTerm2Session:
            _ = terminalContext.restoreITerm2(context)
        case .app:
            break
        }
    }

    private func refreshProjectedState() {
        appState.dictationQueueSnapshot = queue.snapshot
        if appState.isRecording {
            appState.transcriptionState = .recording
            return
        }
        if let activeID = queue.activeDeliveryJobID {
            // Project from the delivery job's status, never from the UI state itself: the
            // old self-check ran before `deliver()` could set `.selectingScreenshots` and
            // therefore published a stale `.inserting` that closed the selection panel.
            let projected: TranscriptionState = queue.job(id: activeID)?.status == .awaitingScreenshotSelection
                ? .selectingScreenshots
                : .inserting
            // Avoid republishing the same value — a redundant `.selectingScreenshots`
            // publish re-keys the selection panel and steals focus mid-selection.
            if appState.transcriptionState != projected {
                appState.transcriptionState = projected
            }
            return
        }
        if !queue.correctingJobIDs().isEmpty {
            appState.transcriptionState = .correcting
        } else if !queue.transcribingJobIDs().isEmpty {
            appState.transcriptionState = .transcribing
        } else {
            appState.transcriptionState = .idle
            appState.isThinkingPause = false
        }
    }
}
