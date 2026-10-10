import Carbon
import Foundation

/// Carbon owns an opaque callback pointer. The callback reads only immutable Sendable actions;
/// registration state is accessed on the main actor and released when the service is destroyed.
final class HotKeyService: @unchecked Sendable {
    private static let signature: OSType = 0x434A6D70
    private var navigateHotKey: EventHotKeyRef?
    private var projectHotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let navigate: @MainActor @Sendable () -> Void
    private let chooseProject: @MainActor @Sendable () -> Void

    init(navigate: @escaping @MainActor @Sendable () -> Void,
         chooseProject: @escaping @MainActor @Sendable () -> Void) {
        self.navigate = navigate
        self.chooseProject = chooseProject
    }

    @MainActor
    func register(commandOption: Bool = false) -> Bool {
        unregister()
        var complete = false
        defer { if !complete { unregister() } }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                          EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotKeyService.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let service = Unmanaged<HotKeyService>.fromOpaque(context).takeUnretainedValue()
            let action: @MainActor @Sendable () -> Void
            switch hotKeyID.id {
            case 1: action = service.navigate
            case 2: action = service.chooseProject
            default: return OSStatus(eventNotHandledErr)
            }
            Task { @MainActor in action() }
            return noErr
        }, 1, &type, pointer, &handler)
        guard handlerStatus == noErr, handler != nil else { return false }

        let modifiers = UInt32(optionKey | (commandOption ? cmdKey : 0))
        let navigateStatus = RegisterEventHotKey(UInt32(kVK_ANSI_J), modifiers,
            EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(), 0, &navigateHotKey)
        guard navigateStatus == noErr, navigateHotKey != nil else { return false }
        let projectStatus = RegisterEventHotKey(UInt32(kVK_ANSI_P), modifiers,
            EventHotKeyID(signature: Self.signature, id: 2), GetApplicationEventTarget(), 0, &projectHotKey)
        guard projectStatus == noErr, projectHotKey != nil else { return false }
        complete = true
        return true
    }

    @MainActor
    func unregister() {
        if let navigateHotKey { UnregisterEventHotKey(navigateHotKey); self.navigateHotKey = nil }
        if let projectHotKey { UnregisterEventHotKey(projectHotKey); self.projectHotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }

    deinit {
        if let navigateHotKey { UnregisterEventHotKey(navigateHotKey) }
        if let projectHotKey { UnregisterEventHotKey(projectHotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
