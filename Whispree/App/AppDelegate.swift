import AppKit
import AVFoundation
import Combine
import KeyboardShortcuts
import LaunchAtLogin
import Sparkle
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
    private var selectionPanelKeyObserver: NSObjectProtocol?
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

    /// Sparkle 자동 업데이트. `startingUpdater: true` 인스턴스는 앱 전체에서 **정확히 하나**여야
    /// 한다 — 둘이면 Sparkle의 스케줄러/XPC 기구가 이중 등록된다. 메뉴의 "Check for Updates..."
    /// 항목이 이 인스턴스를 target으로 잡으므로 여기(AppDelegate)가 소유한다.
    private(set) var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// 프로세스 수명 중 첫 `.regular` 승격 여부. 첫 승격은 신뢰할 수 없어 별도 우회가 필요하다
    /// (`promoteToRegular()` 주석 참조).
    private var hasActivatedOnce = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `LaunchAtLogin.wasLaunchedAtLogin`은 `NSAppleEventManager.currentAppleEvent`를 읽으므로
        // Apple event dispatch 중에만 유효하다 — 즉 이 메서드가 **동기적으로** 실행되는 동안에만.
        // 반드시 최상단에서 로컬로 캡처해 아래로 전달할 것. 호출 체인 깊은 곳에서 읽으면 나중에
        // 누군가 `await` 하나를 끼워넣는 순간 조용히 garbage(false)를 반환하게 된다.
        let wasLaunchedAtLogin = LaunchAtLogin.wasLaunchedAtLogin

        setupMainMenu()
        setupEditKeyboardShortcuts()
        setupServices()
        setupStatusItem()
        setupOverlayObserver()
        checkFirstLaunch(wasLaunchedAtLogin: wasLaunchedAtLogin)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // `flag`는 overlay/selection/preview/quickFix 패널만 떠 있어도 true가 되므로 "메인 창이
        // 보이는가"의 근거로 쓸 수 없다. Dock 가시성과 동일한 predicate로 판단한다.
        if !hasDockVisibleWindow(excluding: nil) {
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

    /// ⚠️ **이 메뉴는 실제로 화면에 표시되지 않는다.**
    ///
    /// 여기서 `NSApp.mainMenu` 를 대입하지만, SwiftUI 가 `applicationDidFinishLaunching`
    /// **이후에** 자기 메뉴를 설치하므로 이쪽이 덮인다. 근거: 실행 중인 앱의 메뉴바는
    /// Apple/Whispree/View/Window/Help 이고 Whispree 메뉴에 "Services" 가 있다 — 둘 다
    /// 이 함수가 만들지 않는 것들이다. 반대로 이 함수가 추가하는 Edit 메뉴는 메뉴바에
    /// 나타나지 않는다 (`setupEditKeyboardShortcuts()` 의 로컬 모니터 해킹이 존재하는 이유).
    ///
    /// **사용자에게 보여야 하는 메뉴 항목은 `WhispreeApp.swift` 의 `.commands` 에 넣을 것.**
    /// 여기 추가하면 조용히 사라진다 — 실제로 "Check for Updates…" 를 이쪽으로 옮겼다가
    /// 메뉴에서 없어진 회귀가 있었다. 이 함수는 SwiftUI 메뉴가 어떤 이유로든 설치되지
    /// 않을 때를 위한 폴백으로만 남겨둔다.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu (Whispree)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Whispree", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // 폴백용. 실제로 표시되는 것은 WhispreeApp 의 CheckForUpdatesView 다.
        // Sparkle이 메인 메뉴 항목 전용으로 제공하는 IBAction. target을 updaterController로 두면
        // `NSMenuItemValidation`을 통해 `canCheckForUpdates` 기반 enable/disable까지 Sparkle이
        // 알아서 처리한다 — 별도 KVO/ObservableObject 배선 불필요.
        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = updaterController
        appMenu.addItem(checkForUpdatesItem)
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

    // MARK: - Activation Policy (Dock 아이콘 / Cmd+Tab 노출)

    /// Dock 아이콘·Cmd+Tab 항목 노출 여부를 결정하는 predicate.
    ///
    /// **`mainWindow` / `onboardingWindow`만** 반영한다. overlay(녹음 HUD) · selection(스크린샷
    /// 선택) · preview · quickFix 패널은 백그라운드 dictation queue의 산출물이라, 여기에 연동하면
    /// `scheduleDelivery()`에 쿨다운이 없고 STT/LLM이 병렬로 도는 특성상 연속 받아쓰기 도중
    /// Dock 아이콘이 깜빡인다(strobe). 자세한 근거는 `Whispree/App/AGENTS.md` 참조.
    ///
    /// - Parameter closingWindow: `windowWillClose(_:)` 시점엔 창이 아직 `isVisible == true`이므로
    ///   닫히는 중인 창을 명시적으로 제외해야 한다.
    private func hasDockVisibleWindow(excluding closingWindow: NSWindow?) -> Bool {
        for window in [mainWindow, onboardingWindow] {
            guard let window, window !== closingWindow else { continue }
            if window.isVisible { return true }
        }
        return false
    }

    /// predicate를 다시 평가해 `.regular` / `.accessory`를 맞춘다.
    private func updateActivationPolicy(closingWindow: NSWindow? = nil) {
        if hasDockVisibleWindow(excluding: closingWindow) {
            promoteToRegular()
        } else {
            demoteToAccessory()
        }
    }

    /// `.regular`로 승격 — Dock 아이콘 + Cmd+Tab 항목 + 메뉴바가 나타난다.
    /// 반드시 `makeKeyAndOrderFront` **이전에** 호출할 것. 순서가 뒤바뀌면 창이 다른 앱 뒤에서
    /// 열리거나 메뉴바가 채워지지 않는다.
    ///
    /// 프로세스 수명 중 **첫 승격은 신뢰할 수 없다**. `jordanbaird/Ice`(`Ice/Main/AppState.swift`)가
    /// 같은 문제를 겪고 쓰는 우회를 그대로 따른다: Dock을 한 번 활성화시킨 뒤 짧게 지연해 다시
    /// 활성화한다. Ice와 동일하게 `setActivationPolicy`는 activate **이후에** 호출한다.
    private func promoteToRegular() {
        func activateAndPromote() {
            if let frontApp = NSWorkspace.shared.frontmostApplication {
                _ = NSRunningApplication.current.activate(from: frontApp)
            } else {
                NSApp.activate()
            }
            if !NSApp.setActivationPolicy(.regular) {
                // 조용히 실패하면 앱이 `.accessory`에 영구히 갇혀 되돌아올 방법이 없다.
                NSLog("Whispree: setActivationPolicy(.regular) 실패 — Dock 아이콘/메뉴바가 복구되지 않았을 수 있음")
            }
        }

        if hasActivatedOnce {
            activateAndPromote()
            return
        }
        hasActivatedOnce = true

        // Hack to make sure the app properly activates for the first time. (Ice)
        _ = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            activateAndPromote()
            // 지연 사이에 창이 뒤로 밀렸을 수 있으므로 한 번 더 끌어올린다.
            guard let self else { return }
            if let window = self.onboardingWindow ?? self.mainWindow, window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// `.accessory`로 강등 — 메뉴바 아이콘만 남는다.
    ///
    /// 정책만 뒤집지 말 것. 명시적으로 다음 앱에 activation을 yield하지 않으면 포커스가 정의되지
    /// 않은 곳으로 떨어지며, 그것 자체가 우리가 고치려는 focus churn의 한 축이다.
    private func demoteToAccessory() {
        // `.regular` 앱으로 한정 — 백그라운드 데몬(`.prohibited`)에 yield하는 건 무의미하다.
        let nextApp = NSWorkspace.shared.runningApplications.first {
            $0 != .current && !$0.isTerminated && $0.activationPolicy == .regular
        }
        if let nextApp {
            NSApp.yieldActivation(to: nextApp)
        } else {
            NSApp.deactivate()
        }
        if !NSApp.setActivationPolicy(.accessory) {
            NSLog("Whispree: setActivationPolicy(.accessory) 실패 — Dock 아이콘이 남아있을 수 있음")
        }
    }

    // MARK: - Main Window (Unified)

    func showMainWindow() {
        if let mainWindow, mainWindow.isVisible {
            mainWindow.level = .normal
            promoteToRegular()
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
        // 창이 닫히면 predicate를 다시 평가해 `.accessory`로 돌아가기 위한 close 감지.
        // `isReleasedWhenClosed = false` + 강한 프로퍼티 보유라 창은 nil이 되지 않으므로
        // 별도의 close 훅 없이는 강등 시점을 알 수 없다. delegate는 weak라 leak 없음.
        window.delegate = self
        mainWindow = window
        promoteToRegular()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Onboarding

    /// - Parameter wasLaunchedAtLogin: `applicationDidFinishLaunching` 최상단에서 캡처한 값.
    ///   여기서 `LaunchAtLogin.wasLaunchedAtLogin`을 직접 읽으면 안 된다 (위 주석 참조).
    private func checkFirstLaunch(wasLaunchedAtLogin: Bool) {
        if !appState.settings.hasCompletedOnboarding {
            // 온보딩은 권한 설정이 필수라 로그인 실행이어도 반드시 표시한다.
            showOnboarding()
        } else {
            // 로그인 항목으로 조용히 뜬 경우엔 창을 띄우지 않는다 — 메뉴바 전용으로 시작.
            if !wasLaunchedAtLogin {
                showMainWindow()
            }
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
        window.delegate = self
        onboardingWindow = window
        promoteToRegular()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        // activeScreen은 showOverlay 설정(on/off)과 무관하게, 녹음이 시작되는 시점(.recording
        // 진입)에 반드시 캡처해야 한다. showSelectionPanel()/showPreviewPanel()은 STT/LLM
        // 처리(수 초)가 끝난 뒤 activeScreen을 폴백으로 읽는데, 이 캡처가 아래 설정 guard
        // 뒤에 있으면 오버레이를 꺼둔 사용자는 activeScreen이 영영 채워지지 않아 결국
        // NSScreen.main이 "패널이 뜨려는 순간"에 다시 평가된다 — 멀티 디스플레이에서
        // 사용자가 그 사이 다른 화면으로 옮겨가 있으면 패널이 엉뚱한 모니터에 뜬다.
        // .recording 상태일 때만 캡처해 이후 이 함수가 .transcribing/.correcting에서
        // 다시 호출되어도 값이 덮어써지지 않게 한다 — "정리"한답시고 guard 뒤로
        // 되돌리지 말 것 (그 순간엔 오버레이 on일 때도 같은 버그가 재발한다).
        if appState.transcriptionState == .recording {
            activeScreen = NSScreen.main ?? NSScreen.screens[0]
        }

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

        // midX/midY로 글로벌 좌표 기준 중앙 배치 (멀티 디스플레이 대응)
        let screen = activeScreen ?? NSScreen.main ?? NSScreen.screens[0]
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
        // 토큰을 selectionPanelKeyObserver에 저장하고 hideSelectionPanel()에서 반드시 제거한다.
        // NotificationCenter가 제거 전까지 이 클로저를 계속 들고 있으므로 panel을 직접
        // 캡처하지 않는다 — notification.object(포스트 시점의 window)를 self.selectionPanel과
        // 비교해 8376fb0e의 asyncAfter 가드와 같은 목적(패널이 이미 내려간 뒤 뒤늦게 콜백이
        // 실행되어도 무시)을 panel을 강하게 잡지 않고 달성한다.
        selectionPanelKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.selectionPanel === (notification.object as? NSWindow) else { return }
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
        if let observer = selectionPanelKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            selectionPanelKeyObserver = nil
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

// MARK: - NSWindowDelegate (Dock 가시성 재평가)

extension AppDelegate: NSWindowDelegate {
    /// `mainWindow` / `onboardingWindow`가 닫힐 때 activation policy predicate를 다시 평가한다.
    /// 두 창 모두 `isReleasedWhenClosed = false`이고 강한 프로퍼티가 잡고 있어 nil이 되지 않으므로,
    /// 이 훅 없이는 "창이 전부 닫혔다"를 알 방법이 없다.
    ///
    /// delegate 방식을 쓰는 이유: `NotificationCenter` 옵저버는 토큰 보관/제거가 필요하고 이 파일은
    /// 직전에 같은 종류의 옵저버 leak을 고친 이력이 있다. `NSWindow.delegate`는 weak이므로 leak이
    /// 구조적으로 불가능하다.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard window === mainWindow || window === onboardingWindow else { return }

        if window === onboardingWindow {
            onboardingWindow = nil
        }
        // willClose 시점엔 `window.isVisible`이 아직 true이므로 명시적으로 제외한다.
        updateActivationPolicy(closingWindow: window)
    }
}
