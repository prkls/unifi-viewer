// The keyboard shortcut that opens and closes the viewer, shared by the menu
// bar button (which registers it) and the settings window (which changes it).
// Free of AppKit and Carbon so it can be tested on its own.
//
// Stored in the app's preferences as "<keyCode> <modifiers> <key>", e.g.
// "32 6400 U". Absent means the default.

import Foundation

// Carbon's modifier bits, as RegisterEventHotKey and CopySymbolicHotKeys use
// them. Spelled out rather than imported so this file needs no Carbon.
let cmdMask: UInt32 = 0x0100
let shiftMask: UInt32 = 0x0200
let optionMask: UInt32 = 0x0800
let controlMask: UInt32 = 0x1000
let modifierMasks = cmdMask | shiftMask | optionMask | controlMask

let shortcutDefaultsKey = "shortcut"

struct Shortcut: Equatable {
    var keyCode: UInt32     // virtual key code: the key's position, not its letter
    var modifiers: UInt32   // Carbon modifier bits
    var key: String         // how the key is shown: "U", "Space", "F5"

    // Control-Option-Command-U. Checked against Apple's shortcut list, the
    // system shortcuts macOS reports, VoiceOver's commands, and the obvious
    // collisions on the other U combinations: Cmd-U underlines, Shift-Cmd-U is
    // Finder's Utilities, Option-Cmd-U is Safari's page source, Control-Cmd-U
    // is Music's lyrics, Control-Option-U is VoiceOver's rotor.
    static let standard = Shortcut(keyCode: 32, modifiers: controlMask | optionMask | cmdMask, key: "U")

    // Apple's order for modifier symbols: Control, Option, Shift, Command.
    var label: String {
        var s = ""
        if modifiers & controlMask != 0 { s += "⌃" }
        if modifiers & optionMask != 0 { s += "⌥" }
        if modifiers & shiftMask != 0 { s += "⇧" }
        if modifiers & cmdMask != 0 { s += "⌘" }
        return s + key
    }

    // A system-wide shortcut takes its keys away from every app. Without
    // Command or Control it would take ordinary typing: Option-U is the umlaut,
    // Shift-U a capital U.
    var isAllowed: Bool {
        return modifiers & (cmdMask | controlMask) != 0 && !key.isEmpty
    }

    var encoded: String {
        return "\(keyCode) \(modifiers) \(key)"
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers & modifierMasks
        self.key = key
    }

    // nil for anything unreadable or not allowed, so a damaged preference
    // falls back to the default rather than registering something odd.
    init?(encoded: String) {
        let parts = encoded.split(separator: " ", maxSplits: 2)
        guard parts.count == 3,
              let keyCode = UInt32(parts[0]),
              let modifiers = UInt32(parts[1])
        else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers, key: String(parts[2]))
        guard isAllowed else { return nil }
    }

    // The saved shortcut, or the default when nothing usable is saved.
    static func from(saved: String?) -> Shortcut {
        return saved.flatMap { Shortcut(encoded: $0) } ?? .standard
    }
}

// How a key is shown in a shortcut. Keys that type a character show it, in
// capitals as Apple's menus do; keys that type nothing visible get a name.
// `characters` is what the key types with no modifiers held.
func keyLabel(keyCode: UInt32, characters: String) -> String {
    let named: [UInt32: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 117: "⌦",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
    if let name = named[keyCode] { return name }
    return characters.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
}

// One entry from macOS's own shortcut list (CopySymbolicHotKeys).
struct SystemShortcut {
    var keyCode: UInt32
    var modifiers: UInt32
    var enabled: Bool
}

// Whether macOS itself already uses this shortcut. Only enabled entries count:
// the list includes shortcuts switched off in System Settings. The system's
// modifier values carry extra bits (such as the function key flag), so only
// the four that make up a shortcut are compared.
func clashesWithSystem(_ shortcut: Shortcut, _ system: [SystemShortcut]) -> Bool {
    return system.contains { entry in
        entry.enabled &&
        entry.keyCode == shortcut.keyCode &&
        entry.modifiers & modifierMasks == shortcut.modifiers
    }
}
