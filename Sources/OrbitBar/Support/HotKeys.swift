import Carbon.HIToolbox
import Foundation

/// System-wide shortcuts through Carbon's `RegisterEventHotKey`: they need no Accessibility permission.
final class HotKeys {
    private var refs: [EventHotKeyRef?] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKeys.actions[id.id]?() }
            return noErr
        }, 1, &spec, me, &handler)
    }

    /// `keyCode` is a `kVK_…` constant; `modifiers` uses Carbon's `cmdKey`, `optionKey` …
    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x4F524254), id: id), GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    deinit {
        refs.forEach { if let ref = $0 { UnregisterEventHotKey(ref) } }
        if let handler { RemoveEventHandler(handler) }
    }
}
