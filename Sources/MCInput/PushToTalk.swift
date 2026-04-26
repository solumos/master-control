import CoreGraphics
import Foundation
import MCCore

/// Push-to-talk hotkey. Hold the configured key to start capture, release
/// to end. Built on a `CGEventTap` at the session level so it works
/// regardless of which app is frontmost. Requires Input Monitoring permission.
///
/// The tap and its CFRunLoop run on a dedicated background thread so the
/// caller's main thread is free for async/await work.
///
/// Common key codes: right-Option = 61 (`kVK_RightOption`),
/// right-Command = 54 (`kVK_RightCommand`).
public final class PushToTalk: @unchecked Sendable {
    public typealias Handler = @Sendable () -> Void

    public static let rightOptionKeyCode: Int64 = 61
    public static let rightCommandKeyCode: Int64 = 54

    public let keyCode: Int64
    public let label: String
    private let onPress: Handler
    private let onRelease: Handler
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHeld = false
    private let installSem = DispatchSemaphore(value: 0)
    private var installResult: Bool = false

    public init(
        keyCode: Int64 = PushToTalk.rightOptionKeyCode,
        label: String = "route",
        onPress: @escaping Handler,
        onRelease: @escaping Handler
    ) {
        self.keyCode = keyCode
        self.label = label
        self.onPress = onPress
        self.onRelease = onRelease
    }

    /// Returns true if the tap was installed. Returns false if Input Monitoring
    /// is not granted; the caller should surface an onboarding prompt and retry.
    public func install() -> Bool {
        guard Permissions.inputMonitoringGranted(prompt: false) else {
            return false
        }
        let thread = Thread { [weak self] in
            self?.threadMain()
        }
        thread.name = "com.solumos.MasterControl.PushToTalk"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        installSem.wait()
        return installResult
    }

    public func uninstall() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoopSource = nil
        runLoop = nil
        thread = nil
    }

    private func threadMain() {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: PushToTalk.tapCallback,
            userInfo: selfPtr
        ) else {
            installResult = false
            installSem.signal()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let cfRunLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(cfRunLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        self.runLoop = cfRunLoop
        installResult = true
        installSem.signal()

        CFRunLoopRun()
    }

    fileprivate func handle(event: CGEvent) {
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        guard kc == keyCode else { return }
        // For modifier keys, the relevant flag tells us pressed vs released.
        // We map keyCode → flag manually since `event.flags` includes
        // unrelated modifiers held simultaneously.
        let pressed: Bool
        switch keyCode {
        case Self.rightOptionKeyCode:
            pressed = event.flags.contains(.maskAlternate)
        case Self.rightCommandKeyCode:
            pressed = event.flags.contains(.maskCommand)
        default:
            // Generic fallback: presence of any modifier flag indicates press.
            pressed = !event.flags.isEmpty
        }

        if pressed && !isHeld {
            isHeld = true
            onPress()
        } else if !pressed && isHeld {
            isHeld = false
            onRelease()
        }
    }

    private static let tapCallback: CGEventTapCallBack = { _, _, event, refcon in
        if let refcon {
            let ptt = Unmanaged<PushToTalk>.fromOpaque(refcon).takeUnretainedValue()
            ptt.handle(event: event)
        }
        return Unmanaged.passUnretained(event)
    }
}
