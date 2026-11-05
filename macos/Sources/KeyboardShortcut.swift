import Cocoa
import Carbon

final class PanelShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onOpen: (() -> Void)?
    func register() -> Bool {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context = context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<PanelShortcut>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { owner.onOpen?() }
            return noErr
        }, 1, &type, pointer, &handler)
        guard installed == noErr else { return false }
        let id = EventHotKeyID(signature: 0x42414c42, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr, let handler = handler { RemoveEventHandler(handler); self.handler = nil }
        return result == noErr
    }
    deinit {
        if let key = hotKey { UnregisterEventHotKey(key) }
        if let handler = handler { RemoveEventHandler(handler) }
    }
}
