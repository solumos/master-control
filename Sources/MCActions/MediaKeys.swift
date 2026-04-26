import AppKit
import Foundation

/// Posts the system-wide media keys (play/pause, next, previous) by
/// synthesizing `NSEvent.systemDefined` events at the HID layer. These are
/// the same events the keyboard's media keys generate, so the OS routes
/// them to whatever app currently owns "now playing" — Spotify, Apple
/// Music, YouTube, Podcasts, browser HTML5 audio, anywhere.
///
/// No app-specific code, no AppleScript permission prompts.
public enum MediaKeys {

    /// macOS HID system-defined key codes (private constants in
    /// `<IOKit/hidsystem/ev_keymap.h>`).
    public enum Key: Int32, Sendable {
        case playPause = 16   // NX_KEYTYPE_PLAY
        case next = 17        // NX_KEYTYPE_NEXT
        case previous = 18    // NX_KEYTYPE_PREVIOUS
    }

    public static func post(_ key: Key) {
        post(key.rawValue, isDown: true)
        post(key.rawValue, isDown: false)
    }

    private static func post(_ keyCode: Int32, isDown: Bool) {
        // data1 packs the key code, the state (0xA = down, 0xB = up), and
        // 8 bits of flags. The system event subtype is 8
        // (kSystemDefinedEventMediaKeys).
        let state = isDown ? 0xA : 0xB
        let data1 = (Int(keyCode) << 16) | (state << 8)
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }
}
