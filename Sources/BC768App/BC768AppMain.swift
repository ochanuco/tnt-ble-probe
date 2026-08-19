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
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1180, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
