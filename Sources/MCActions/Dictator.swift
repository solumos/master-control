import CoreGraphics
import Foundation
import MCCore

/// Synthesizes keystrokes that "type" arbitrary text into the focused
/// application. Uses `CGEvent.keyboardSetUnicodeString` to attach a Unicode
/// string to a synthetic key event, posted via `cghidEventTap` so any app
/// receives it as if from physical hardware.
///
/// Requires the **Accessibility** permission for posting to apps other than
/// our own. Without it, events to the focused app may be silently dropped.
///
/// Spec §7 calls out that `postToPid` is unreliable; we deliberately use
/// `cghidEventTap` (the HID-level system stream) instead.
public struct Dictator: Sendable {
    public enum Mode: Sendable {
        /// Single keystroke that contains the entire utterance as a unicode
        /// string. Fastest path (~3 ms total), but a few apps don't accept
        /// the unicode-on-virtualKey-0 form.
        case singleEvent
        /// One CGEvent per character. ~1 ms per char, more compatible.
        /// Default.
        case perCharacter
    }

    public var mode: Mode
    public var perCharDelayMicros: UInt32

    public init(mode: Mode = .perCharacter, perCharDelayMicros: UInt32 = 1_000) {
        self.mode = mode
        self.perCharDelayMicros = perCharDelayMicros
    }

    /// Type the given text into whatever app is currently focused.
    /// Returns the wall-clock duration of the synthesis loop.
    @discardableResult
    public func type(_ text: String) -> TimeInterval {
        let start = Clock.now()
        guard !text.isEmpty else { return 0 }
        switch mode {
        case .singleEvent:
            postSingleEvent(text)
        case .perCharacter:
            postPerCharacter(text)
        }
        return Clock.elapsedMs(since: start) / 1_000
    }

    private func postSingleEvent(_ text: String) {
        let utf16 = Array(text.utf16)
        utf16.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: base)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: base)
                up.post(tap: .cghidEventTap)
            }
        }
    }

    private func postPerCharacter(_ text: String) {
        for scalar in text.unicodeScalars {
            postChar(scalar)
            if perCharDelayMicros > 0 {
                usleep(perCharDelayMicros)
            }
        }
    }

    private func postChar(_ scalar: Unicode.Scalar) {
        // Encode scalar as UTF-16 (handles surrogate pairs for codepoints
        // outside the BMP — though typical English transcriptions stay in
        // BMP, the code is correct for whatever Parakeet emits).
        let codeUnits = Array(String(scalar).utf16)
        codeUnits.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: base)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: base)
                up.post(tap: .cghidEventTap)
            }
        }
    }
}
