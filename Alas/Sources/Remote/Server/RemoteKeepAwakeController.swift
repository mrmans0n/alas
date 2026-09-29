import Foundation
import IOKit.pwr_mgt
import IOKit.ps
import OSLog

/// Holds an idle-sleep assertion only while Remote is available on external power.
@MainActor
final class RemoteKeepAwakeController {
    private let isOnExternalPower: @MainActor () -> Bool
    private let createAssertion: @MainActor () -> IOPMAssertionID?
    private let releaseAssertion: @MainActor (IOPMAssertionID) -> Void
    private let createPowerSource: @MainActor (UnsafeMutableRawPointer) -> CFRunLoopSource?
    private var assertion: IOPMAssertionID?
    private var powerSource: CFRunLoopSource?
    private var requested = false

    init(
        isOnExternalPower: @escaping @MainActor () -> Bool = RemoteKeepAwakeController.externalPowerAvailable,
        createAssertion: @escaping @MainActor () -> IOPMAssertionID? = RemoteKeepAwakeController.makeAssertion,
        releaseAssertion: @escaping @MainActor (IOPMAssertionID) -> Void = { IOPMAssertionRelease($0) },
        createPowerSource: @escaping @MainActor (UnsafeMutableRawPointer) -> CFRunLoopSource? = RemoteKeepAwakeController.makePowerSource
    ) {
        self.isOnExternalPower = isOnExternalPower
        self.createAssertion = createAssertion
        self.releaseAssertion = releaseAssertion
        self.createPowerSource = createPowerSource
    }

    isolated deinit {
        stopObservingPower()
        if let assertion { releaseAssertion(assertion) }
    }

    func update(enabled: Bool, serverRunning: Bool) {
        requested = enabled && serverRunning
        if requested, powerSource == nil {
            powerSource = createPowerSource(Unmanaged.passUnretained(self).toOpaque())
            if let powerSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes)
            }
        } else if !requested {
            stopObservingPower()
        }
        powerSourceChanged()
    }

    func powerSourceChanged() {
        // Fail closed if notifications could not be installed: we must be able
        // to release the assertion when the laptop is unplugged.
        let shouldPreventSleep = requested && powerSource != nil && isOnExternalPower()
        if shouldPreventSleep {
            if assertion == nil { assertion = createAssertion() }
        } else if let assertion {
            releaseAssertion(assertion)
            self.assertion = nil
        }
    }

    private func stopObservingPower() {
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        powerSource = nil
    }

    private static func externalPowerAvailable() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        // Desktop Macs also report AC power. Battery and UPS power do not qualify.
        return source as String == kIOPSACPowerValue
    }

    private static func makePowerSource(context: UnsafeMutableRawPointer) -> CFRunLoopSource? {
        IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            // This source is installed only on the main run loop.
            MainActor.assumeIsolated {
                Unmanaged<RemoteKeepAwakeController>.fromOpaque(context)
                    .takeUnretainedValue().powerSourceChanged()
            }
        }, context)?.takeRetainedValue()
    }

    private static func makeAssertion() -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Alas remote access" as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            Logger(subsystem: "io.nlopez.alas", category: "RemoteKeepAwake")
                .error("Could not prevent idle sleep: \(result)")
            return nil
        }
        return id
    }
}
