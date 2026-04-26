import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum Permission: String, CaseIterable, Sendable {
    case microphone
    case accessibility
    case inputMonitoring
    case screenRecording

    public var systemSettingsURL: URL? {
        let path: String
        switch self {
        case .microphone:
            path = "Privacy_Microphone"
        case .accessibility:
            path = "Privacy_Accessibility"
        case .inputMonitoring:
            path = "Privacy_ListenEvent"
        case .screenRecording:
            path = "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(path)")
    }
}

public enum Permissions {

    public static func microphoneStatus() -> AVAuthorizationStatus {
        #if canImport(AVFoundation)
        AVCaptureDevice.authorizationStatus(for: .audio)
        #else
        .notDetermined
        #endif
    }

    public static func requestMicrophone() async -> Bool {
        #if canImport(AVFoundation)
        await AVCaptureDevice.requestAccess(for: .audio)
        #else
        false
        #endif
    }

    public static func accessibilityGranted(prompt: Bool = false) -> Bool {
        #if canImport(ApplicationServices)
        // kAXTrustedCheckOptionPrompt is the C string "AXTrustedCheckOptionPrompt".
        // We use the literal directly to avoid Swift 6 concurrency-safety
        // complaints about referencing the C global.
        let opts: CFDictionary = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
        #else
        return false
        #endif
    }

    public static func inputMonitoringGranted(prompt: Bool = false) -> Bool {
        #if canImport(CoreGraphics)
        if prompt {
            let result = CGRequestListenEventAccess()
            return result
        }
        return CGPreflightListenEventAccess()
        #else
        return false
        #endif
    }

    public static func openSystemSettings(for permission: Permission) {
        #if canImport(AppKit)
        guard let url = permission.systemSettingsURL else { return }
        NSWorkspace.shared.open(url)
        #endif
    }
}
