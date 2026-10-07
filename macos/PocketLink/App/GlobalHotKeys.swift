import AppKit
import Carbon.HIToolbox

/// System-wide hot keys registered through Carbon's RegisterEventHotKey —
/// works without accessibility permissions. Callbacks run on the main actor.
///
/// Central place for the key choices; configurability is a planned stretch.
@MainActor
final class GlobalHotKeys {
    struct HotKey {
        let id: UInt32
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// ⌥⌘M — toggle the PocketLink panel.
    static let togglePanel = HotKey(
        id: 1,
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: UInt32(optionKey | cmdKey)
    )

    /// ⌥⌘S — toggle screen mirroring.
    static let toggleMirroring = HotKey(
        id: 2,
        keyCode: UInt32(kVK_ANSI_S),
        modifiers: UInt32(optionKey | cmdKey)
    )

    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef?] = [:]
    private var eventHandler: EventHandlerRef?
    private static let signature = OSType(0x504B_4C4E) // 'PKLN'

    func register(_ hotKey: HotKey, handler: @escaping () -> Void) {
        handlers[hotKey.id] = handler
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            EventHotKeyID(signature: Self.signature, id: hotKey.id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        hotKeyRefs[hotKey.id] = ref
        if status != noErr {
            handlers[hotKey.id] = nil
        }
    }

    /// Installs the shared Carbon event handler. Carbon delivers application
    /// events on the main thread, so the callback hops with assumeIsolated.
    func install() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return noErr }
            let center = Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                center.dispatch(id: hotKeyID.id)
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, userData, &eventHandler)
    }

    private func dispatch(id: UInt32) {
        handlers[id]?()
    }
}
