import AppKit
import AVFoundation
import Combine
import KeyboardShortcuts
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var overlayPanel: NSPanel?
    private var selectionPanel: NSPanel?
    private var selectionKeyMonitor: Any?
    private var previewPanel: NSPanel?
    /// 녹음 시작 시의 활성 화면 — 모든 패널이 이 화면에 표시
    private var activeScreen: NSScreen?
    private var quickFixPanel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    // Services
    private(set) var audioService: AudioService!
    private(set) var sttService: STTService!
    private(set) var textInsertionService: TextInsertionService!
    private(set) var modelManager: ModelManager!
    private(set) var hotkeyManager: HotkeyManager!
    private(set) var quickFixService: QuickFixService!

    /// Coordinators
    private(set) var recordingCoordinator: RecordingCoordinator!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupEditKeyboardShortcuts()
        setupServices()
        setupStatusItem()
        setupOverlayObserver()
        checkFirstLaunch()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleURL(url)
        }
    }

    private func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "whispree" else { return }
        let command = url.host?.lowercased()
            ?? url.pathComponents.filter { $0 != "/" }.first?.lowercased()

        guard let recordingCoordinator else {
            NSLog("Whispree: URL 수신 — 서비스 초기화 전, 무시: \(url.absoluteString)")
            return
        }

        switch command {
        case "toggle":
            if appState.isRecording {
                recordingCoordinator.stopRecording()
            } else {
                recordingCoordinator.startRecording()
            }
        case "push", "start":
            recordingCoordinator.startRecording()
        case "release", "stop":
            recordingCoordinator.stopRecording()
        default:
            NSLog("Whispree: 알 수 없는 URL 커맨드: \(command ?? "nil") — \(url.absoluteString)")
        }
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu (Whispree)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Whispree", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings...", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Whispree", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Whispree", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu (for text fields to work with Cmd+C/V/X)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettingsFromMenu() {
        showMainWindow()
    }

    // MARK: - Edit Keyboard Shortcuts (Copy/Paste Fix)

    /// SwiftUI의 NSHostingView에서 Edit 메뉴 키보드 단축키가 동작하지 않는 문제를 해결.
    /// NSEvent 로컬 모니터로 Cmd+C/V/X/A/Z를 가로채서 직접 first responder에 dispatch.
    private func setupEditKeyboardShortcuts() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command) else { return event }

            let action: Selector?
            let isShift = event.modifierFlags.contains(.shift)

            switch event.charactersIgnoringModifiers {
                case "v": action = #selector(NSText.paste(_:))
                case "c": action = #selector(NSText.copy(_:))
                case "x": action = #selector(NSText.cut(_:))
                case "a": action = #selector(NSText.selectAll(_:))
                case "z": action = isShift ? NSSelectorFromString("redo:") : NSSelectorFromString("undo:")
                default: action = nil
            }

            if let action, NSApp.sendAction(action, to: nil, from: nil) {
                return nil // 이벤트 소비됨
            }
            return event
        }
    }

    // MARK: - Services

    private func setupServices() {
        audioService = AudioService()
        sttService = STTService()
        textInsertionService = TextInsertionService()
        modelManager = ModelManager(appState: appState, sttService: sttService)
        hotkeyManager = HotkeyManager(appState: appState)
        quickFixService = QuickFixService()

        recordingCoordinator = RecordingCoordinator(
            appState: appState,
            audioService: audioService,
            textInsertionService: textInsertionService
        )

        hotkeyManager.onRecordingToggle = { [weak self] shouldRecord in
            guard let self else { return }
            if shouldRecord {
                recordingCoordinator.startRecording()
            } else {
                recordingCoordinator.stopRecording()
            }
        }

        hotkeyManager.onCancel = { [weak self] in
            self?.recordingCoordinator.cancel()
        }

        hotkeyManager.onEscPreview = { [weak self] in
            self?.hidePreviewPanel()
        }

        hotkeyManager.onQuickFix = { [weak self] in
            self?.handleQuickFix()
        }

        hotkeyManager.onOptionLongPress = { [weak self] in
            guard let self else { return }
            // VLM(vision) 지원 프로바이더일 때만 토글 — 아니면 의미 없음.
            guard appState.llmProvider?.supportsVision == true else { return }
            let newValue = !appState.settings.isScreenshotPasteEnabled
            appState.settings.isScreenshotPasteEnabled = newValue
            appState.flashHandoffToggle(newValue)
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Whispree")
            button.title = " FW"
            button.imagePosition = .imageLeading
            button.action = #selector(statusItemClicked)
            button.target = self
        }
    }

    @objc private func statusItemClicked() {
        showMainWindow()
    }

    // MARK: - Main Window (Unified)

    func showMainWindow() {
        if let mainWindow, mainWindow.isVisible {
            mainWindow.level = .normal
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Whispree"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.center()
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 700, height: 500)
        window.contentView = NSHostingView(
            rootView: UnifiedView()
                .environmentObject(appState)
                .environmentObject(hotkeyManager)
                .environmentObject(modelManager)
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow = window
    }

    // MARK: - Onboarding

    private func checkFirstLaunch() {
        if !appState.settings.hasCompletedOnboarding {
            showOnboarding()
        } else {
            showMainWindow()
            Task {
                await modelManager.loadModelsIfAvailable()
            }
        }
    }

    private func showOnboarding() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Whispree"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: OnboardingView { [weak self] in
                guard let self else { return }
                appState.settings.hasCompletedOnboarding = true
                DispatchQueue.main.async {
                    self.onboardingWindow?.orderOut(nil)
                    self.onboardingWindow = nil
                    self.showMainWindow()
                    Task {
                        await self.appState.switchSTTProvider(to: self.appState.settings.sttProviderType)
                        await self.appState.switchLLMProvider(to: self.appState.settings.llmProviderType)
                    }
                }
            }
            .environmentObject(appState)
            .environmentObject(hotkeyManager)
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    // MARK: - Quick Fix

    private func handleQuickFix() {
        // Capture the frontmost app (where the user selected text)
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard let targetApp = frontmost else { return }

        // Allow self-targeting during onboarding for Quick Fix demo
        if targetApp.bundleIdentifier == Bundle.main.bundleIdentifier,
           appState.settings.hasCompletedOnboarding
        {
            return
        }

        Task {
            // Simulate Cmd+C to capture selected text
            guard let selectedText = await quickFixService.captureSelectedText() else { return }

            showQuickFixPanel(originalText: selectedText, targetApp: targetApp)
        }
    }

    private func showQuickFixPanel(originalText: String, targetApp: NSRunningApplication) {
        quickFixPanel?.orderOut(nil)
        quickFixPanel = nil

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.title = "Quick Fix"
        panel.center()
        panel.isReleasedWhenClosed = false

        panel.contentView = NSHostingView(
            rootView: QuickFixPanelView(
                originalText: originalText,
                onConfirmWord: { [weak self] correctedText in
                    guard let self else { return }
                    quickFixPanel?.orderOut(nil)
                    quickFixPanel = nil

                    Task {
                        _ = await self.quickFixService.replaceText(with: correctedText, in: targetApp)
                        self.quickFixService.addWordToDictionary(correctedText, appState: self.appState)
                    }
                },
                onConfirmMapping: { [weak self] fromText, toText in
                    guard let self else { return }
                    quickFixPanel?.orderOut(nil)
                    quickFixPanel = nil

                    Task {
                        _ = await self.quickFixService.replaceText(with: toText, in: targetApp)
                        self.quickFixService.addCorrectionToDictionary(from: fromText, to: toText, appState: self.appState)
                    }
                },
                onCancel: { [weak self] in
                    self?.quickFixPanel?.orderOut(nil)
                    self?.quickFixPanel = nil
                }
            )
        )

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        quickFixPanel = panel
    }

    // MARK: - Recording Overlay

    private func setupOverlayObserver() {
        appState.$transcriptionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                    case .recording, .transcribing, .correcting:
                        self.mainWindow?.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
                        showOverlay()
                        self.hideSelectionPanelIfStateAllows()
                    case .selectingScreenshots:
                        // level은 낮게 유지 — 선택 패널은 .floating이라 정상 표시
                        self.hideOverlay()
                        self.showSelectionPanel()
                    case .idle, .inserting:
                        self.hideSelectionPanelIfStateAllows()
                        if state == .idle {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                if self.appState.transcriptionState == .idle {
                                    self.hideOverlay()
                                    self.mainWindow?.level = .normal
                                }
                            }
                        }
                }
            }
            .store(in: &cancellables)
    }

    private func showOverlay() {
        guard appState.settings.showOverlay else { return }

        if overlayPanel != nil {
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true

        // 활성 화면 캡처 — 이후 선택/미리보기 패널도 이 화면에 표시
        let screen = NSScreen.main ?? NSScreen.screens[0]
        activeScreen = screen
        // midX/midY로 글로벌 좌표 기준 중앙 배치 (멀티 디스플레이 대응)
        let x = screen.frame.midX - 160
        let y = screen.visibleFrame.maxY - 100
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        let frontApp = NSWorkspace.shared.frontmostApplication
        let wasOtherApp = frontApp?.bundleIdentifier != Bundle.main.bundleIdentifier

        panel.contentView = NSHostingView(
            rootView: TranscriptionOverlayView()
                .environmentObject(appState)
        )
        panel.orderFront(nil)
        overlayPanel = panel

        // 이전 앱으로 포커스 복원 — 메인 윈도우가 포커스되는 것 방지
        if wasOtherApp {
            frontApp?.activate()
        }
    }

    private func hideOverlay() {
        guard overlayPanel != nil else { return }
        let frontApp = NSWorkspace.shared.frontmostApplication
        if frontApp?.bundleIdentifier != Bundle.main.bundleIdentifier {
            frontApp?.activate()
        }
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
    }

    // MARK: - Screenshot Selection Panel

    /// Esc로 자동 닫히지 않는 패널 — cancelOperation을 무시하여 로컬 키 모니터가 Esc를 전담 처리
    private class ManagedPanel: NSPanel {
        override func cancelOperation(_ sender: Any?) {
            // 무시 — Esc 처리는 로컬 키 모니터에서 담당
        }
    }

    private func showSelectionPanel() {
        if selectionPanel != nil {
            selectionPanel?.makeKeyAndOrderFront(nil)
            return
        }

        let panel = ManagedPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
            styleMask: [.titled, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.title = "스크린샷 선택"
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 오버레이와 같은 화면에 표시
        let screen = activeScreen ?? NSScreen.main ?? NSScreen.screens[0]
        let x = screen.frame.midX - 170
        let y = screen.frame.midY - 210
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        panel.contentView = NSHostingView(
            rootView: ScreenshotSelectionView()
                .environmentObject(appState)
        )

        // 앱 활성화 → 패널 포커스 (첫 실행 시 백그라운드에서 올라오므로 재시도)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        selectionPanel = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.selectionPanel === panel else { return }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.selectionPanel === panel else { return }
            panel.makeKeyAndOrderFront(nil)
        }

        // 패널이 key가 되면 앱 재활성화 — 로컬 키 모니터가 동작하려면 앱이 active여야 함
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: panel,
            queue: .main
        ) { _ in
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        // 로컬 키보드 모니터 — ESC 제외 키 이벤트 소비 (ESC는 EventTap이 전담)
        selectionKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.appState.transcriptionState == .selectingScreenshots else { return event }
            // ESC는 EventTap → HotkeyManager.handleUnifiedEsc()가 처리
            if event.keyCode == 53 { return nil }
            // 미리보기 열려있으면 다른 키 무시
            if self.previewPanel != nil { return nil }
            Task { @MainActor in
                self.appState.selectionKeyEvent = event
            }
            return nil
        }

        // 미리보기 요청 감시
        appState.previewRequestCallback = { [weak self] screenshot in
            self?.showPreviewPanel(screenshot)
        }

        // 뷰에서 직접 패널 dismiss 요청 시
        appState.dismissSelectionPanel = { [weak self] in
            self?.hideSelectionPanel()
        }
    }

    /// Teardown requested by a `transcriptionState` publish. Combine delivers those values
    /// asynchronously, so `state` can already be stale by the time this runs. If the current
    /// projected state still says we are selecting screenshots, the publish predates the
    /// selection and must not tear the panel down — doing so would also resolve the pending
    /// continuation with an empty selection and make images permanently unattachable.
    private func hideSelectionPanelIfStateAllows() {
        guard appState.transcriptionState != .selectingScreenshots else { return }
        hideSelectionPanel()
    }

    private func hideSelectionPanel() {
        if let monitor = selectionKeyMonitor {
            NSEvent.removeMonitor(monitor)
            selectionKeyMonitor = nil
        }
        hidePreviewPanel()
        selectionPanel?.orderOut(nil)
        selectionPanel = nil
        appState.previewRequestCallback = nil
        appState.dismissSelectionPanel = nil

        // 대기 중인 continuation을 resume시켜 leak 방지. 패널이 실제로 내려가는 모든
        // 경로에서 반드시 실행되어야 한다 — 남겨두면 deliver()가 영원히 매달려 FIFO
        // delivery 전체가 막힌다. 명시 경로(confirmSelection/skip, cancel, 녹음 suspend)는
        // 호출 전에 callback을 이미 nil로 만들므로 이중 resume은 발생하지 않는다.
        let pendingCallback = appState.screenshotSelectionCallback
        appState.screenshotSelectionCallback = nil
        pendingCallback?([])
    }

    // MARK: - Preview Panel (Quick Look 스타일)

    private func showPreviewPanel(_ screenshot: CapturedScreenshot) {
        hidePreviewPanel()

        guard let image = screenshot.image else { return }
        let imageSize = image.size
        // 오버레이/선택 패널과 같은 화면에 표시
        let screen = activeScreen ?? NSScreen.main ?? NSScreen.screens[0]
        let maxW = screen.frame.width * 0.7
        let maxH = screen.frame.height * 0.7
        let scale = min(maxW / imageSize.width, maxH / imageSize.height, 1.0)
        let panelW = imageSize.width * scale
        let panelH = imageSize.height * scale + 30 // 타이틀바

        let panel = ManagedPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelW, height: panelH),
            styleMask: [.titled, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.title = screenshot.appName
        panel.hidesOnDeactivate = false

        let x = screen.frame.midX - panelW / 2
        let y = screen.frame.midY - panelH / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH - 30))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        panel.contentView = imageView
        panel.makeKeyAndOrderFront(nil)
        previewPanel = panel
        hotkeyManager.eventTapService.isPreviewOpen = true
    }

    private func hidePreviewPanel() {
        previewPanel?.orderOut(nil)
        previewPanel = nil
        hotkeyManager.eventTapService.isPreviewOpen = false
    }
}
