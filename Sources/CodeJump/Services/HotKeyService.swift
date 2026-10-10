import Carbon
import Foundation

final class HotKeyService: @unchecked Sendable {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor @Sendable () -> Void

    init(action: @escaping @MainActor @Sendable () -> Void) { self.action = action }

    func register(commandOption: Bool = false) -> Bool {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let pointer = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let service = Unmanaged<HotKeyService>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in service.action() }
                return noErr
            }, 1, &type, pointer, &handler)
        }
        let modifiers = UInt32(optionKey | (commandOption ? cmdKey : 0))
        return RegisterEventHotKey(UInt32(kVK_ANSI_J), modifiers,
            EventHotKeyID(signature: 0x434A6D70, id: 1), GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
