import AppKit
import Combine
import Foundation
import KeyboardShortcuts

/// KeyboardShortcuts.Name 정의 — 마이그레이션 참조용으로만 유지.
/// 런타임 단축키 저장소는 AppSettings.toggleRecordingShortcut / quickFixShortcut.
extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", default: .init(.r, modifiers: [.control, .shift]))
    static let quickFix = Self("quickFix", default: .init(.d, modifiers: [.control, .shift]))
}

@MainActor
final class HotkeyManager: ObservableObject {
    var onRecordingToggle: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onQuickFix: (() -> Void)?
    /// 녹음 중 Option 단독 long-press 시 호출 — 스크린샷 전달 토글.
    var onOptionLongPress: (() -> Void)?

    private let appState: AppState
    let eventTapService = EventTapHotkeyService.shared
    private var eventTap: EventTapHotkeyService { eventTapService }
    private var isKeyDown = false
    private var escMonitorLocal: Any?
    private var accessibilityCancellable: AnyCancellable?

    init(appState: AppState) {
        self.appState = appState
        eventTap.start()
        setupHotkeys()
        setupEscCancel()
        setupOptionLongPress()

        accessibilityCancellable = PermissionManager.shared.$accessibility
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard status == .granted else { return }
                self?.eventTap.start()
            }
    }

    private func setupOptionLongPress() {
        eventTap.onOptionLongPress = { [weak self] in
            self?.onOptionLongPress?()
        }
        // 녹음 중일 때만 long-press 감지 활성
        appState.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                self?.eventTap.isOptionLongPressEnabled = isRecording
            }
            .store(in: &stateCancellable)
    }

    private func setupHotkeys() {
        eventTap.clearBindings()

        switch appState.settings.recordingMode {
            case .pushToTalk:
                setupPushToTalk()
            case .toggle:
                setupToggleMode()
        }
        setupQuickFixHotkey()
    }

    func updateMode(_ mode: RecordingMode) {
        appState.settings.recordingMode = mode
        setupHotkeys()
    }

    /// Re-register hotkeys after shortcut changes (called by ShortcutRecorderButton)
    func reloadHotkeys() {
        setupHotkeys()
    }

    private func setupPushToTalk() {
        let shortcut = appState.settings.toggleRecordingShortcut
        eventTap.register(
            whispreeShortcut: shortcut,
            keyDown: { [weak self] in
                guard let self, !self.isKeyDown else { return }
                isKeyDown = true
                onRecordingToggle?(true)
            },
            keyUp: { [weak self] in
                guard let self, isKeyDown else { return }
                isKeyDown = false
                onRecordingToggle?(false)
            }
        )
    }

    private func setupToggleMode() {
        let shortcut = appState.settings.toggleRecordingShortcut
        eventTap.register(
            whispreeShortcut: shortcut,
            keyDown: { [weak self] in
                guard let self else { return }
                let shouldRecord = !appState.isRecording
                onRecordingToggle?(shouldRecord)
            }
        )
    }

    private func setupQuickFixHotkey() {
        let shortcut = appState.settings.quickFixShortcut
        eventTap.register(
            whispreeShortcut: shortcut,
            keyDown: { [weak self] in
                self?.onQuickFix?()
            }
        )
    }

    // MARK: - ESC to Cancel

    private func setupEscCancel() {
        // 로컬 모니터 — Whispree가 포커스일 때 ESC 소비 (선택 패널 등)
        escMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self else { return event }
            if self.eventTap.isPreviewOpen ||
                self.appState.transcriptionState == .selectingScreenshots ||
                self.appState.isRecording {
                // EventTap의 onEscPressed와 같은 통합 핸들러 호출
                self.handleUnifiedEsc()
                return nil
            }
            return event
        }

        // CGEventTap — 통합 ESC 핸들러 (우선순위: 미리보기 → 선택 → 취소)
        eventTap.onEscPressed = { [weak self] in
            self?.handleUnifiedEsc()
        }

        // ESC scope 동기화. 전역 ESC는 명시적으로 cancel 가능한 현재 scope
        // (녹음, 스크린샷 선택/배송, overlay에 보이는 foreground queue item)에서만 소비한다.
        appState.$transcriptionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateEscScopes()
            }
            .store(in: &stateCancellable)

        appState.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateEscScopes()
            }
            .store(in: &stateCancellable)

        appState.$dictationQueueSnapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateEscScopes()
            }
            .store(in: &stateCancellable)
    }

    private func updateEscScopes() {
        let state = appState.transcriptionState
        let hasForegroundQueueItem = appState.dictationQueueSnapshot.foregroundJobSequence != nil
        let hasActiveDelivery = appState.dictationQueueSnapshot.activeDeliverySequence != nil
        let isForegroundProcessingVisible = (state == .transcribing || state == .correcting) && hasForegroundQueueItem

        eventTap.isSelectionActive = state == .selectingScreenshots
        eventTap.isPipelineActive = appState.isRecording ||
            state == .recording ||
            isForegroundProcessingVisible ||
            (state == .inserting && hasActiveDelivery)
    }

    /// 통합 ESC 핸들러 — 우선순위대로 분기
    private func handleUnifiedEsc() {
        // 1. 미리보기 열려있으면 → 미리보기만 닫기
        if eventTap.isPreviewOpen {
            onEscPreview?()
            return
        }
        // 2. 선택/배송/foreground queue item이면 → 해당 item 하나만 취소
        if appState.transcriptionState == .selectingScreenshots {
            onCancel?()
            return
        }
        // 3. 활성 녹음만 취소. 백그라운드 STT/LLM job은 명시적으로 선택된
        // foreground scope 없이 전역 ESC로 취소하지 않는다.
        if appState.isRecording {
            onCancel?()
            return
        }
        if appState.transcriptionState == .transcribing ||
            appState.transcriptionState == .correcting ||
            appState.transcriptionState == .inserting
        {
            onCancel?()
        }
    }

    /// 미리보기 닫기 콜백 — AppDelegate에서 설정
    var onEscPreview: (() -> Void)?

    private var stateCancellable = Set<AnyCancellable>()

    deinit {
        if let monitor = escMonitorLocal { NSEvent.removeMonitor(monitor) }
    }
}
