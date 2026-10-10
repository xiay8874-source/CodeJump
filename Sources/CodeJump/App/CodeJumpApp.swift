import AppKit
import SwiftUI

@main struct CodeJumpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppStore.shared

    var body: some Scene {
        MenuBarExtra("CodeJump", systemImage: "arrow.up.forward.app") {
            Button("切换项目…  \(store.projectShortcutLabel)") { store.showProjectPicker() }
            Button("主页与设置…  \(store.homeShortcutLabel)") { store.showMainWindow() }
            Button("定位剪贴板中的引用") {
                store.query = NSPasteboard.general.string(forType: .string) ?? ""
                store.searchManually()
            }
            Divider()
            Text("悬停跳转  \(store.shortcutLabel)")
            Text(store.indexing ? "索引更新中" : "\(store.fileCount.formatted()) 个文件已就绪")
            Button("重新索引") { store.refreshIndex() }
            Divider()
            Button("退出 CodeJump") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppStore.shared.start()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // An explicit Finder / Spotlight reopen is a request for the home page.
        // Ordinary lookup failures and background startup never use this path.
        AppStore.shared.showMainWindow()
        return false
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { AppStore.shared.handle(url: url) }
    }
    func applicationDidBecomeActive(_ notification: Notification) { AppStore.shared.checkPermission() }
}
