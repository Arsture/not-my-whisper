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
    }
}
