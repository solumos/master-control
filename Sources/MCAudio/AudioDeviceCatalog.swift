import AudioToolbox
import CoreAudio
import Foundation

/// One row in the system audio device list. We use `uid` as the stable
/// persisted identifier — `AudioDeviceID` is a session-scoped integer
/// that changes across reboots / device replugs, while UID is a string
/// the HAL guarantees stable for a given physical/logical device.
public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let hasInput: Bool
    public let hasOutput: Bool
}

/// Read-only view of the CoreAudio HAL device list. Used by the settings
/// UI to populate input/output pickers and by `AudioCapture` to resolve
/// a persisted UID back to the live `AudioDeviceID` that the audio unit
/// API expects.
public enum AudioDeviceCatalog {

    public static func devices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBufferPointer { buf -> OSStatus in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, buf.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids.compactMap(deviceInfo(for:))
    }

    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        devices().first(where: { $0.uid == uid })?.id
    }

    public static func displayName(forUID uid: String) -> String? {
        devices().first(where: { $0.uid == uid })?.name
    }

    private static func deviceInfo(for id: AudioDeviceID) -> AudioDevice? {
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID, .global)
        else { return nil }
        let name = stringProperty(id, kAudioObjectPropertyName, .global) ?? "(unknown)"
        let hasInput = channelCount(id, .input) > 0
        let hasOutput = channelCount(id, .output) > 0
        guard hasInput || hasOutput else { return nil }
        return AudioDevice(id: id, uid: uid, name: name, hasInput: hasInput, hasOutput: hasOutput)
    }

    private enum Scope {
        case global, input, output
        var raw: AudioObjectPropertyScope {
            switch self {
            case .global: return kAudioObjectPropertyScopeGlobal
            case .input:  return kAudioObjectPropertyScopeInput
            case .output: return kAudioObjectPropertyScopeOutput
            }
        }
    }

    private static func stringProperty(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: Scope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope.raw,
            mElement: kAudioObjectPropertyElementMain
        )
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = ref?.takeRetainedValue() else { return nil }
        return cf as String
    }

    /// Sums channel counts across all streams of `scope`. Zero means the
    /// device has no streams in that direction (e.g. a pure output device
    /// returns 0 for input).
    private static func channelCount(_ id: AudioObjectID, _ scope: Scope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope.raw,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size > 0
        else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr
        else { return 0 }
        let listPtr = buffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        var channels = 0
        for buf in UnsafeMutableAudioBufferListPointer(listPtr) {
            channels += Int(buf.mNumberChannels)
        }
        return channels
    }
}
