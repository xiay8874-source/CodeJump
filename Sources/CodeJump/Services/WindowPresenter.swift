import AppKit
import SwiftUI

@MainActor final class WindowPresenter: NSObject, NSWindowDelegate {
    private let store: AppStore
    private var mainWindow: NSWindow?
    private var candidatePanel: NSPanel?
    private var monitor: Any?

    init(store: AppStore) { self.store = store }

    func showMain() {
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "CodeJump — 项目与设置"
            window.contentViewController = NSHostingController(rootView: ContentView(store: store))
            window.setContentSize(NSSize(width: 720, height: 780))
            window.isReleasedWhenClosed = false; window.center()
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func showCandidates() {
        dismissCandidates()
        showPanel(root: CandidateView(store: store), projectMode: false)
    }

    func showProjects() {
        dismissCandidates()
        showPanel(root: ProjectPickerView(store: store), projectMode: true)
    }

    private func showPanel<Content: View>(root: Content, projectMode: Bool) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 606, height: 350),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: root)
        panel.delegate = self
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.contentView?.fittingSize ?? NSSize(width: 606, height: 350)
        panel.setContentSize(NSSize(width: 606, height: min(max(size.height, 220), 520)))
        panel.setFrameOrigin(NSPoint(x: min(max(pointer.x + 12, area.minX), area.maxX - panel.frame.width),
            y: min(max(pointer.y - panel.frame.height - 12, area.minY), area.maxY - panel.frame.height)))
        candidatePanel = panel
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.candidatePanel?.isKeyWindow == true else { return event }
            if projectMode {
                if event.modifierFlags.contains(.command), let text = event.charactersIgnoringModifiers,
                   let number = Int(text), (1...9).contains(number) {
                    self.store.chooseProject(at: number - 1); return nil
                }
                switch event.keyCode {
                case 53: self.store.dismissCandidates(); return nil
                case 36, 76: self.store.chooseProject(at: self.store.selectedProjectIndex); return nil
                case 125: self.store.selectedProjectIndex = min(self.store.selectedProjectIndex + 1, max(0, self.store.rankedProjects.count - 1)); return nil
                case 126: self.store.selectedProjectIndex = max(self.store.selectedProjectIndex - 1, 0); return nil
                default: return event
                }
            }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               let char = event.charactersIgnoringModifiers, let number = Int(char), (1...9).contains(number) {
                self.store.choose(number - 1); return nil
            }
            switch event.keyCode {
            case 53: self.store.dismissCandidates(); return nil
            case 36, 76: self.store.choose(self.store.selectedIndex); return nil
            case 125: self.store.selectedIndex = min(self.store.selectedIndex + 1, self.store.candidates.count - 1); return nil
            case 126: self.store.selectedIndex = max(self.store.selectedIndex - 1, 0); return nil
            default: return event
            }
        }
    }

    func dismissCandidates() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        let panel = candidatePanel
        candidatePanel = nil
        panel?.orderOut(nil)
    }
    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSPanel === candidatePanel { store.dismissCandidates() }
    }
}
