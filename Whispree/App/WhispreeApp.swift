import Sparkle
import SwiftUI

@main
struct WhispreeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear {
                    // Cmd+, → 설정 윈도우 대신 메인 윈도우 표시
                    DispatchQueue.main.async {
                        NSApp.keyWindow?.close()
                        appDelegate.showMainWindow()
                    }
                }
        }
        // 메뉴바에 실제로 표시되는 것은 **이 `.commands` 로 구성된 SwiftUI 메뉴**다.
        // `AppDelegate.setupMainMenu()` 도 `NSApp.mainMenu` 를 대입하지만, SwiftUI 가
        // `applicationDidFinishLaunching` **이후에** 자기 메뉴를 설치하므로 그쪽이 덮인다.
        // (근거: 실행 중인 앱의 메뉴바는 Apple/Whispree/View/Window/Help 이고 Whispree 메뉴에
        //  "Services" 가 있다 — 둘 다 setupMainMenu() 가 만들지 않는 것들이며, 반대로
        //  setupMainMenu() 가 추가하는 Edit 메뉴는 메뉴바에 나타나지 않는다.)
        // 따라서 사용자에게 보여야 하는 메뉴 항목은 반드시 여기에 있어야 한다.
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: appDelegate.updaterController.updater)
            }
        }
    }
}

/// 앱 메뉴의 "Check for Updates…" 항목.
/// `SPUStandardUpdaterController` 인스턴스는 `AppDelegate` 가 소유한다 —
/// `startingUpdater: true` 컨트롤러가 둘이면 Sparkle 스케줄러가 이중 등록된다.
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel

    init(updater: SPUUpdater) {
        viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates...", action: viewModel.updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

final class CheckForUpdatesViewModel: ObservableObject {
    let updater: SPUUpdater
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}
