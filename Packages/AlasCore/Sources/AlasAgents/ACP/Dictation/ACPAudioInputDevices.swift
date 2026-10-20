import CoreAudio
import Foundation

/// A device CoreAudio reports with at least one input channel.
public struct ACPAudioInputDevice: Equatable, Sendable {
    /// Valid only while the device stays connected; persist `uid` instead.
    public let id: AudioObjectID
    public let uid: String
    public let name: String

    public init(id: AudioObjectID, uid: String, name: String) {
        self.id = id
        self.uid = uid
        self.name = name
    }
}

/// Lists the input devices dictation can record from.
public enum ACPAudioInputDevices {
    /// Every connected device with an input channel, in CoreAudio's order.
    public static func current() -> [ACPAudioInputDevice] {
        var address = devicesAddress
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInputChannels(id),
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: id),
                  let name = stringProperty(kAudioObjectPropertyName, of: id)
            else { return nil }
            return ACPAudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    /// Yields the current list at once, then again whenever a device is
    /// connected or removed, until the consuming task is cancelled.
    public static func updates() -> AsyncStream<[ACPAudioInputDevice]> {
        AsyncStream { continuation in
            continuation.yield(current())
            let listener = Listener { continuation.yield(current()) }
            guard listener.register() else { return }
            continuation.onTermination = { _ in listener.unregister() }
        }
    }

    private static let devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Holds the CoreAudio listener block so the same block can be removed
    /// later, which removal requires.
    private final class Listener: @unchecked Sendable {
        private let queue = DispatchQueue(label: "io.nlopez.alas.audio-input-devices")
        private let block: AudioObjectPropertyListenerBlock

        init(onChange: @escaping @Sendable () -> Void) {
            block = { _, _ in onChange() }
        }

        func register() -> Bool {
            var address = devicesAddress
            return AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr
        }

        func unregister() {
            var address = devicesAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
    }

    private static func hasInputChannels(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
