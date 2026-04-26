import CoreGraphics
import Foundation

/// Synthesizes keyboard key events at the HID layer (`cghidEventTap`).
///
/// Distinct from `Dictator`, which types text via Unicode-string events:
/// `KeyboardEvents` posts proper virtual-key codes so apps see them as
/// real keystrokes — Tab moves focus, Cmd+S saves, arrow keys navigate,
/// etc. Use this for UI navigation, `Dictator` for inserting text.
public enum KeyboardEvents {

    /// Named keys with their macOS virtual-key codes (Carbon
    /// `Events.h` constants — `kVK_*`).
    public enum Key: String, Sendable, CaseIterable {
        case tab        = "tab"        //  48
        case enter      = "enter"      //  36
        case `return`   = "return"     //  36
        case escape     = "escape"     //  53
        case space      = "space"      //  49
        case delete     = "delete"     //  51 (Backspace)
        case forwardDelete = "forward_delete" // 117 (Fn+Delete)
        case up         = "up"         // 126
        case down       = "down"       // 125
        case left       = "left"       // 123
        case right      = "right"      // 124
        case home       = "home"       // 115
        case end        = "end"        // 119
        case pageUp     = "pageup"     // 116
        case pageDown   = "pagedown"   // 121
        case f1         = "f1"         // 122
        case f2         = "f2"         // 120
        case f3         = "f3"         //  99
        case f4         = "f4"         // 118
        case f5         = "f5"         //  96
        case f6         = "f6"         //  97
        case f7         = "f7"         //  98
        case f8         = "f8"         // 100
        case f9         = "f9"         // 101
        case f10        = "f10"        // 109
        case f11        = "f11"        // 103
        case f12        = "f12"        // 111

        public var code: CGKeyCode {
            switch self {
            case .tab:           return 48
            case .enter, .return: return 36
            case .escape:        return 53
            case .space:         return 49
            case .delete:        return 51
            case .forwardDelete: return 117
            case .up:            return 126
            case .down:          return 125
            case .left:          return 123
            case .right:         return 124
            case .home:          return 115
            case .end:           return 119
            case .pageUp:        return 116
            case .pageDown:      return 121
            case .f1:            return 122
            case .f2:            return 120
            case .f3:            return 99
            case .f4:            return 118
            case .f5:            return 96
            case .f6:            return 97
            case .f7:            return 98
            case .f8:            return 100
            case .f9:            return 101
            case .f10:           return 109
            case .f11:           return 103
            case .f12:           return 111
            }
        }
    }

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift   = Modifiers(rawValue: 1 << 1)
        public static let option  = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)

        var cgFlags: CGEventFlags {
            var f: CGEventFlags = []
            if contains(.command) { f.insert(.maskCommand) }
            if contains(.shift)   { f.insert(.maskShift) }
            if contains(.option)  { f.insert(.maskAlternate) }
            if contains(.control) { f.insert(.maskControl) }
            return f
        }

        /// Parse a free-form modifier string ("cmd shift" / "cmd,option" /
        /// "command+shift") into a Modifiers set. Unknown tokens are
        /// silently dropped — better to swallow them than fail the whole
        /// keystroke on a typo.
        public static func parse(_ raw: String) -> Modifiers {
            var out: Modifiers = []
            for token in raw.lowercased().split(whereSeparator: { ", +/&".contains($0) }) {
                switch token {
                case "cmd", "command", "meta":  out.insert(.command)
                case "shift":                    out.insert(.shift)
                case "opt", "option", "alt":     out.insert(.option)
                case "ctrl", "control":          out.insert(.control)
                default:                          break
                }
            }
            return out
        }
    }

    /// Press a named key once, with optional modifier flags. Posts at the
    /// HID layer so the focused app sees it as a physical keystroke.
    public static func press(_ key: Key, modifiers: Modifiers = []) {
        post(virtualKey: key.code, modifiers: modifiers)
    }

    /// Press a single ASCII letter or digit (a–z / 0–9). Useful for
    /// shortcuts like Cmd+S, Cmd+W, etc.
    public static func press(_ character: Character, modifiers: Modifiers = []) -> Bool {
        guard let code = virtualKeyCode(for: character) else { return false }
        post(virtualKey: code, modifiers: modifiers)
        return true
    }

    private static func post(virtualKey: CGKeyCode, modifiers: Modifiers) {
        let flags = modifiers.cgFlags
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    /// US-ANSI keyboard layout. Other layouts will produce different
    /// characters from these key codes (e.g. on AZERTY, kVK_ANSI_A is
    /// the Q key) — rely on `dictate` for text and `press_key` for
    /// navigation/shortcuts where layout matters less.
    private static let ansiKeyCodes: [Character: CGKeyCode] = [
        "a": 0,  "s": 1,  "d": 2,  "f": 3,  "h": 4,  "g": 5,
        "z": 6,  "x": 7,  "c": 8,  "v": 9,  "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18,
        "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25,
        "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34,
        "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    private static func virtualKeyCode(for character: Character) -> CGKeyCode? {
        let lower = Character(character.lowercased())
        return ansiKeyCodes[lower]
    }
}
