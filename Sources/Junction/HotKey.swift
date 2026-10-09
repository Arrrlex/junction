import AppKit
import Carbon

/// A global keyboard shortcut via Carbon's RegisterEventHotKey, which needs no permissions.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextId: UInt32 = 1
    private static var installed = false

    /// `spec` looks like "ctrl+alt+cmd+b".
    init?(_ spec: String, handler: @escaping () -> Void) {
        var modifiers: UInt32 = 0
        var keyCode: UInt32?
        for part in spec.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "alt", "opt", "option": modifiers |= UInt32(optionKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default: keyCode = Self.keyCodes[part]
            }
        }
        guard let keyCode else { return nil }

        Self.installHandler()
        let id = Self.nextId
        Self.nextId += 1
        Self.handlers[id] = handler
        let hotKeyId = EventHotKeyID(signature: OSType(0x4A4E_4354), id: id) // 'JNCT'
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyId, GetApplicationEventTarget(), 0, &ref) == noErr else {
            return nil
        }
    }

    /// Parses "ctrl+alt+cmd+b" into a key and modifiers for an NSMenuItem, so the menu
    /// shows it the native way (⌃⌥⌘B).
    static func menuEquivalent(_ spec: String) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        var modifiers: NSEvent.ModifierFlags = []
        var key: String?
        for part in spec.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": modifiers.insert(.command)
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "opt", "option": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "space": key = " "
            default: key = part
            }
        }
        return key.map { ($0, modifiers) }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyId = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyId)
            HotKey.handlers[hotKeyId.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }

    private static let keyCodes: [String: UInt32] = {
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8),
            ("9", kVK_ANSI_9), ("space", kVK_Space), ("/", kVK_ANSI_Slash), (".", kVK_ANSI_Period),
            (",", kVK_ANSI_Comma), (";", kVK_ANSI_Semicolon), ("'", kVK_ANSI_Quote),
        ]
        return Dictionary(uniqueKeysWithValues: letters.map { ($0.0, UInt32($0.1)) })
    }()
}
