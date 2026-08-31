import Carbon.HIToolbox
import Foundation

/// Registers system-wide hotkeys through the Carbon Event Manager. This needs
/// no Accessibility or Input Monitoring permission (matches the original's
/// "no system permissions" behavior).
@MainActor
final class HotKeyCenter {
    private var hotKeys: [UInt32: EventHotKeyRef?] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private static let signature = OSType(0x4544474E) // 'EDGN'
    private var installed = false

    /// Standard-shortcut ids the system refused to register — in practice
    /// another app already owns the combination. Settings reads this so a
    /// dead shortcut is not advertised as working.
    private(set) static var unavailableStandardIDs: Set<UInt32> = []

    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        guard installHandlerIfNeeded() else { return false }

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: HotKeyCenter.signature, id: id),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &ref
        )
        guard status == noErr else { return false }
        hotKeys[id] = ref
        handlers[id] = handler
        return true
    }

    func unregisterAll() {
        for ref in hotKeys.values {
            if let ref {
                UnregisterEventHotKey(ref)
            }
        }
        hotKeys.removeAll()
        handlers.removeAll()
    }

    /// Returns false when the Carbon handler could not be installed.
    ///
    /// `installed` is set only on success. Setting it before the call meant a
    /// failed install was never retried, while `register` went on returning
    /// true for every shortcut — so `unavailableStandardIDs` stayed empty and
    /// Settings advertised system-wide hotkeys that could never fire.
    private func installHandlerIfNeeded() -> Bool {
        guard !installed else { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyCallback,
            1,
            &eventType,
            userData,
            nil
        )
        guard status == noErr else { return false }
        installed = true
        return true
    }

    fileprivate func dispatch(_ id: UInt32) {
        handlers[id]?()
    }
}

private let hotKeyCallback: EventHandlerUPP = { _, event, userData in
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
    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            center.dispatch(id)
        }
    }
    return noErr
}

enum HotKeyID {
    static let newNote: UInt32 = 1
    static let allNotes: UInt32 = 2
    static let archive: UInt32 = 3
}

extension HotKeyCenter {
    /// Installs the app's standard shortcuts: ⌥⌘N new note, ⌥⌘A all notes,
    /// ⌥⌘L archive. Records the ones the system refused so Settings can say
    /// so — a shortcut another app owns fails here, once, and silently.
    @MainActor
    static func registerStandard(into center: HotKeyCenter, actions: @escaping (UInt32) -> Void) {
        let cmdOpt: UInt32 = UInt32(cmdKey | optionKey)
        var unavailable: Set<UInt32> = []
        let standard: [(id: UInt32, keyCode: Int)] = [
            (HotKeyID.newNote, kVK_ANSI_N),
            (HotKeyID.allNotes, kVK_ANSI_A),
            (HotKeyID.archive, kVK_ANSI_L),
        ]
        for shortcut in standard {
            let registered = center.register(
                id: shortcut.id,
                keyCode: UInt32(shortcut.keyCode),
                modifiers: cmdOpt
            ) {
                actions(shortcut.id)
            }
            if !registered { unavailable.insert(shortcut.id) }
        }
        unavailableStandardIDs = unavailable
    }
}
