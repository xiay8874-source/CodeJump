import AppKit
import Darwin
import SwiftUI

@MainActor final class WindowPresenter: NSObject, NSWindowDelegate {
    private let store: AppStore
    private var mainWindow: NSWindow?
    private var instructionWindow: NSWindow?
    private var candidatePanel: NSPanel?
    private var monitor: Any?
    private var originPID: pid_t?
    private var feedbackPanel: FeedbackPanel?
    private var feedbackTask: Task<Void, Never>?

    init(store: AppStore) {
        self.store = store
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func toggleMain() {
        // A home page behind another app should come forward. Only a second
        // press while using the home page hides it and returns to the other app.
        if let mainWindow, mainWindow.isKeyWindow, NSApp.isActive, !mainWindow.isMiniaturized {
            mainWindow.orderOut(nil)
            NSApp.hide(nil)
        } else {
            showMain()
        }
    }

    func showMain() {
        store.dismissCandidates(restoreFocus: false)
        dismissFeedback()
        let isNewWindow = mainWindow == nil
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "CodeJump — 项目与设置"
            let hosting = NSHostingController(rootView: ContentView(store: store))
            // The scrollable view fills the window; its ideal content height must
            // not impose a second, larger minimum through hosting constraints.
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.isReleasedWhenClosed = false
            mainWindow = window
        }
        if let mainWindow { fitMainWindow(mainWindow, initially: isNewWindow) }
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        NSApp.unhideWithoutActivation()
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func showClaudeInstructions() {
        store.dismissCandidates(restoreFocus: false)
        dismissFeedback()
        ClaudeInstructionStore.shared.refreshIfClean()
        let isNew = instructionWindow == nil
        if instructionWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "CodeJump — Claude 全局规则"
            let host = NSHostingController(rootView: ClaudeInstructionsView())
            host.sizingOptions = []
            window.contentViewController = host
            window.isReleasedWhenClosed = false
            instructionWindow = window
        }
        if let instructionWindow { fitMainWindow(instructionWindow, initially: isNew) }
        if instructionWindow?.isMiniaturized == true { instructionWindow?.deminiaturize(nil) }
        NSApp.unhideWithoutActivation(); NSApp.activate()
        instructionWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        if let instructionWindow { fitMainWindow(instructionWindow, initially: false) }
        guard let mainWindow else { return }
        // Display disconnection, resolution and Dock changes can invalidate a
        // saved frame. Geometry repair does not reveal or activate the window.
        fitMainWindow(mainWindow, initially: false)
    }

    private func fitMainWindow(_ window: NSWindow, initially: Bool) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        let screens = NSScreen.screens.filter { $0.visibleFrame.width > 0 && $0.visibleFrame.height > 0 }
        guard !screens.isEmpty else { return }
        let original = window.frame
        let containing = initially ? nil : screens.first { $0.visibleFrame.contains(original) }
        let overlapping = screens.max { lhs, rhs in
            let left = lhs.visibleFrame.intersection(original)
            let right = rhs.visibleFrame.intersection(original)
            let leftArea = left.isNull ? 0 : left.width * left.height
            let rightArea = right.isNull ? 0 : right.width * right.height
            return leftArea < rightArea
        }
        let pointerScreen = screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        let intersectingScreen = overlapping.flatMap { $0.visibleFrame.intersects(original) ? $0 : nil }
        let screen = containing ?? (initially ? nil : intersectingScreen) ?? pointerScreen ?? NSScreen.main ?? screens[0]
        let visible = screen.visibleFrame
        let placement = visible.insetBy(dx: min(12, visible.width * 0.02),
                                        dy: min(12, visible.height * 0.02))
        // Convert frame bounds into content bounds instead of subtracting a
        // hard-coded title bar height; this also handles different window chrome.
        let minimumSpace = window.contentRect(forFrameRect: placement).size
        window.contentMinSize = NSSize(width: min(600, max(1, minimumSpace.width)),
                                       height: min(420, max(1, minimumSpace.height)))

        // Respect user resizing and positioning whenever the complete frame is
        // already usable on one display, including an intentionally edge-aligned frame.
        if !initially, containing != nil { return }
        var fitted = initially
            ? window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 720, height: 680))
            : original
        fitted.size.width = min(fitted.width, placement.width)
        fitted.size.height = min(fitted.height, placement.height)
        if initially {
            fitted.origin = NSPoint(x: placement.midX - fitted.width / 2, y: placement.midY - fitted.height / 2)
        } else {
            fitted.origin = NSPoint(x: max(placement.minX, min(fitted.minX, placement.maxX - fitted.width)),
                                    y: max(placement.minY, min(fitted.minY, placement.maxY - fitted.height)))
        }
        if !window.frame.equalTo(fitted) { window.setFrame(fitted, display: window.isVisible) }
    }

    func showCandidates(originPID: pid_t? = nil) {
        showPanel(root: CandidateView(store: store), projectMode: false, originPID: originPID)
    }

    func showProjects(originPID: pid_t? = nil) {
        showPanel(root: ProjectPickerView(store: store), projectMode: true, originPID: originPID)
    }

    private func showPanel<Content: View>(root: Content, projectMode: Bool, originPID proposedPID: pid_t?) {
        // Capture before activation or hiding an existing panel. When replacing
        // our own panel, preserve its original external application.
        let sourcePID = sourceApplicationPID(proposedPID)
        dismissCandidates(restoreFocus: false)
        dismissFeedback()
        originPID = sourcePID
        // Settings are shown only by showMain(). Closing a transient picker must
        // never reveal an older settings window behind it.
        mainWindow?.orderOut(nil)
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
        panel.setContentSize(NSSize(width: 606, height: min(max(size.height, 220), min(projectMode ? 520 : 680, area.height - 40))))
        panel.setFrameOrigin(NSPoint(x: min(max(pointer.x + 12, area.minX), area.maxX - panel.frame.width),
            y: min(max(pointer.y - panel.frame.height - 12, area.minY), area.maxY - panel.frame.height)))
        candidatePanel = panel
        NSApp.activate(); panel.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.candidatePanel?.isKeyWindow == true else { return event }
            // Let the field editor finish Chinese/Japanese composition before handling navigation.
            if let input = self.candidatePanel?.firstResponder as? NSTextView, input.hasMarkedText() { return event }
            if projectMode {
                if event.modifierFlags.contains(.command), let text = event.charactersIgnoringModifiers,
                   let number = Int(text), (1...9).contains(number) {
                    self.store.chooseProject(at: number - 1); return nil
                }
                switch event.keyCode {
                case 53: self.store.dismissCandidates(restoreFocus: true); return nil
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
            case 53: self.store.dismissCandidates(restoreFocus: true); return nil
            case 36, 76: self.store.choose(self.store.selectedIndex); return nil
            case 125: self.store.selectedIndex = min(self.store.selectedIndex + 1, max(0, self.store.candidates.count - 1)); return nil
            case 126: self.store.selectedIndex = max(self.store.selectedIndex - 1, 0); return nil
            default: return event
            }
        }
    }

    func dismissCandidates(restoreFocus: Bool = false) {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        let panel = candidatePanel
        let previousPID = originPID
        candidatePanel = nil
        originPID = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        guard restoreFocus, let previousPID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
              let application = NSRunningApplication(processIdentifier: previousPID), !application.isTerminated else { return }
        // A user's switch to a different application always wins over restoration.
        _ = application.activate(options: [])
    }

    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSPanel === candidatePanel {
            store.dismissCandidates(restoreFocus: false)
        }
    }

    /// Noninteractive feedback never activates CodeJump or steals key focus.
    /// The complete lifetime is 2.5 seconds, including its final 0.25-second fade.
    func showFeedback(_ message: String) {
        dismissFeedback()
        let panel = FeedbackPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 70),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.contentViewController = NSHostingController(rootView: FeedbackView(message: message))
        let size = panel.contentView?.fittingSize ?? NSSize(width: 420, height: 70)
        panel.setContentSize(NSSize(width: 420, height: min(max(size.height, 54), 160)))
        positionNearPointer(panel)
        feedbackPanel = panel
        panel.orderFrontRegardless()
        feedbackTask = Task { [weak self, weak panel] in
            do { try await Task.sleep(for: .seconds(2.25)) } catch { return }
            guard let self, let panel, self.feedbackPanel === panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: nil)
            do { try await Task.sleep(for: .seconds(0.25)) } catch { return }
            guard self.feedbackPanel === panel else { return }
            panel.orderOut(nil)
            self.feedbackPanel = nil
            self.feedbackTask = nil
        }
    }

    private func dismissFeedback() {
        feedbackTask?.cancel()
        feedbackTask = nil
        let panel = feedbackPanel
        feedbackPanel = nil
        panel?.orderOut(nil)
    }

    private func sourceApplicationPID(_ proposedPID: pid_t?) -> pid_t? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for pid in [proposedPID, frontmostPID, originPID].compactMap({ $0 }) where pid != ownPID {
            if let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated { return pid }
        }
        return nil
    }

    private func positionNearPointer(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window.setFrameOrigin(NSPoint(
            x: max(area.minX, min(pointer.x + 12, area.maxX - window.frame.width)),
            y: max(area.minY, min(pointer.y - window.frame.height - 12, area.maxY - window.frame.height))))
    }
}

@MainActor private final class FeedbackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
