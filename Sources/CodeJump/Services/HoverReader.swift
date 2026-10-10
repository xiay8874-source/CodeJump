@preconcurrency import ApplicationServices
import Foundation

struct CaptureFragment: Sendable {
    let text: String
    let origin: String
    let precise: Bool
}

struct HoverCapture: Sendable {
    let fragments: [CaptureFragment]
    let application: String
    let elapsedMilliseconds: Double
}

enum HoverReader {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    @MainActor static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Read only after an explicit hotkey. No timer, mouse monitor, or screen recording.
    static func capture(x: Double, y: Double, application: String) -> HoverCapture {
        let started = Date()
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(x), Float(y), &hit) == .success, let hit else {
            return HoverCapture(fragments: [], application: application, elapsedMilliseconds: 0)
        }
        AXUIElementSetMessagingTimeout(hit, 0.15)
        var fragments: [CaptureFragment] = []
        var current: AXUIElement? = hit
        for depth in 0..<4 {
            guard let element = current, Date().timeIntervalSince(started) < 0.7 else { break }
            let role = string(element, kAXRoleAttribute as CFString) ?? ""
            // Selected text has a deliberate user boundary; do not synthesize copy keystrokes.
            if let selected = string(element, kAXSelectedTextAttribute as CFString), !selected.isEmpty {
                fragments.append(CaptureFragment(text: String(selected.prefix(4096)), origin: "选中文字", precise: true))
            }
            if let url = attribute(element, kAXURLAttribute as CFString) {
                let value: String?
                if CFGetTypeID(url) == CFURLGetTypeID() { value = (url as! URL).absoluteString }
                else { value = url as? String }
                if let value, !value.isEmpty {
                    fragments.append(CaptureFragment(text: String(value.prefix(4096)), origin: "引用链接", precise: depth <= 2))
                }
            }
            if depth == 0, let nearby = textAtPosition(element, point: CGPoint(x: x, y: y)) {
                fragments.append(CaptureFragment(text: nearby, origin: "鼠标附近文字", precise: false))
            }
            for name in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                guard let value = string(element, name as CFString), !value.isEmpty, value.utf16.count <= 4096 else { continue }
                let precise = depth == 0 && [kAXButtonRole, "AXLink", kAXStaticTextRole].contains(role) && value.count < 300
                fragments.append(CaptureFragment(text: value, origin: depth == 0 ? "鼠标指向文字" : "邻近上下文", precise: precise))
            }
            let parent = attribute(element, kAXParentAttribute as CFString)
            current = parent.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        }
        var seen = Set<String>()
        fragments = fragments.filter { seen.insert($0.text).inserted }
        fragments = fragments.enumerated().sorted {
            func rank(_ fragment: CaptureFragment) -> Int {
                if fragment.origin == "引用链接" { return 0 }
                if fragment.origin == "选中文字" { return 1 }
                return fragment.precise ? 2 : 3
            }
            let left = rank($0.element), right = rank($1.element)
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
        return HoverCapture(fragments: fragments, application: application,
            elapsedMilliseconds: Date().timeIntervalSince(started) * 1000)
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &result) == .success else { return nil }
        return result
    }

    private static func string(_ element: AXUIElement, _ name: CFString) -> String? {
        attribute(element, name) as? String
    }

    private static func textAtPosition(_ element: AXUIElement, point: CGPoint) -> String? {
        var point = point
        guard let parameter = AXValueCreate(.cgPoint, &point) else { return nil }
        var output: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXRangeForPositionParameterizedAttribute as CFString,
              parameter, &output) == .success, let output, CFGetTypeID(output) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(output as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        // Ask for a bounded window around the pointer, never the full document.
        let total = (attribute(element, kAXNumberOfCharactersAttribute as CFString) as? NSNumber)?.intValue
        let start = max(0, range.location - 100)
        let end = min(range.location + 120, total ?? (range.location + max(1, range.length)))
        guard end > start else { return nil }
        range = CFRange(location: start, length: end - start)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
              rangeValue, &text) == .success else { return nil }
        return text as? String
    }
}
