import AppKit
import SwiftUI

@main
struct BC768ProbeApp: App {
    @StateObject private var store = MeasurementStore()
    @StateObject private var controller = SessionController()

    init() {
        // SwiftPM 製の実行ファイルは既定でアクセサリ扱いになり、ウィンドウが前面に来ない。
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("BC-768") {
            ContentView(store: store, controller: controller)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    Self.widenWindowIfNeeded()
                }
        }
        .defaultSize(width: ContentView.preferredWindowWidth, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }

    /// macOS は前回のウィンドウ枠を復元するため、`defaultSize` は 2 回目以降に効かない。
    /// 狭い枠が残っていると表が横スクロールになるので、足りない分だけ広げる。
    /// 利用者が自分で広げた幅は縮めない。
    private static func widenWindowIfNeeded() {
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first,
                  window.frame.width < ContentView.preferredWindowWidth else { return }
            var frame = window.frame
            frame.size.width = ContentView.preferredWindowWidth
            window.setFrame(frame, display: true)
        }
    }
}
