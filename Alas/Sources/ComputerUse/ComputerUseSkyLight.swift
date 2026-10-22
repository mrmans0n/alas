import ApplicationServices
import CoreGraphics
import Foundation

/// Private WindowServer (SkyLight) calls that let input reach a background window: making a
/// window its app's key window without activating the app or raising the window, and posting
/// events the way WindowServer routes them to a window. Loaded with `dlopen` on first use and
/// never linked, so a macOS that drops a symbol only loses the background path; callers fall
/// back to activation.
///
/// The key-window records follow yabai (`window_manager_make_key_window`) and cua-driver
/// (`post_window_key_records`): a focus record (0x0d) moves AppKit's key window and activation
/// state inside the target process, and the make-key pair (0x01, 0x02) settles it. Every record
/// goes to the target process only; WindowServer's front process and the user's key focus stay
/// where they are. The target app does keep believing it is active afterwards.
enum ComputerUseSkyLight {
    private typealias PostEventRecordTo = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Int32
    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private typealias EventPostToPid = @convention(c) (pid_t, CGEvent) -> Void
    private typealias EventSetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private typealias AXUIElementGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

    /// Resolved once; C function pointers carry no state.
    private struct Symbols: @unchecked Sendable {
        var postEventRecordTo: PostEventRecordTo?
        var getProcessForPID: GetProcessForPID?
        var eventPostToPid: EventPostToPid?
        var eventSetWindowLocation: EventSetWindowLocation?
        var axGetWindow: AXUIElementGetWindow?
    }

    private static let symbols: Symbols = {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_GLOBAL)
        // RTLD_DEFAULT; the Darwin overlay doesn't import the macro.
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2)
        func resolve<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(everywhere, name).map { unsafeBitCast($0, to: T.self) }
        }
        return Symbols(
            postEventRecordTo: resolve("SLPSPostEventRecordTo", as: PostEventRecordTo.self),
            // Deprecated Carbon, still exported; resolving it at runtime sidesteps the deprecation.
            getProcessForPID: resolve("GetProcessForPID", as: GetProcessForPID.self),
            eventPostToPid: resolve("SLEventPostToPid", as: EventPostToPid.self),
            eventSetWindowLocation: resolve("CGEventSetWindowLocation", as: EventSetWindowLocation.self),
            axGetWindow: resolve("_AXUIElementGetWindow", as: AXUIElementGetWindow.self)
        )
    }()

    /// Whether a window can be made key without activating its app.
    static var isAvailable: Bool {
        symbols.postEventRecordTo != nil && symbols.getProcessForPID != nil
    }

    /// Lets the app handle one record before the next; some apps drop a record that arrives
    /// while they are still handling the previous one (yabai waits the same).
    private static let recordSettle: Duration = .milliseconds(40)

    /// Posts the records that make `windowID` the key window of `pid`, moving key status off
    /// `current` (the app's focused window) first. True when every record was accepted; whether
    /// the app acted on them is for the caller to confirm.
    static func makeKeyWithoutActivating(pid: pid_t, windowID: UInt32, current: UInt32?) async -> Bool {
        guard let post = symbols.postEventRecordTo, let getProcess = symbols.getProcessForPID else { return false }
        var psn = [UInt8](repeating: 0, count: 8)
        guard getProcess(pid, &psn) == 0 else { return false }
        func send(_ record: [UInt8]) -> Bool {
            psn.withUnsafeBytes { psn in record.withUnsafeBytes { post(psn.baseAddress!, $0.baseAddress!) } } == 0
        }
        var accepted = true
        if let current, current != windowID {
            accepted = send(focusRecord(current, focus: false)) && accepted
            try? await Task.sleep(for: recordSettle)
        }
        accepted = send(focusRecord(windowID, focus: true)) && accepted
        try? await Task.sleep(for: recordSettle)
        for kind: UInt8 in [0x01, 0x02] {
            accepted = send(makeKeyRecord(windowID, kind: kind)) && accepted
        }
        return accepted
    }

    /// The CG window id behind an AX window; nil when unknown.
    static func windowID(of element: AXUIElement) -> UInt32? {
        guard let getWindow = symbols.axGetWindow else { return nil }
        var id: UInt32 = 0
        return getWindow(element, &id) == .success && id != 0 ? id : nil
    }

    /// Stamps the point the event lands on inside its window (points from the window's top-left
    /// corner); a background window isn't hit-tested from the screen location. No-op without the symbol.
    static func setWindowLocation(_ event: CGEvent, _ point: CGPoint) {
        symbols.eventSetWindowLocation?(event, point)
    }

    /// Posts through WindowServer's per-process path, else the public one. Never both: an AppKit
    /// view would get the event twice.
    static func post(_ event: CGEvent, pid: pid_t) {
        if let post = symbols.eventPostToPid {
            post(pid, event)
        } else {
            event.postToPid(pid)
        }
    }

    /// 0xf8 bytes: the window id at 0x3c (little-endian), 0x8a = 1 to focus, 2 to defocus.
    private static func focusRecord(_ windowID: UInt32, focus: Bool) -> [UInt8] {
        var record = emptyRecord(kind: 0x0d, windowID: windowID)
        record[0x8a] = focus ? 0x01 : 0x02
        return record
    }

    /// yabai's make-key record: 0x3a = 0x10 and 0x20..<0x30 all 0xff.
    private static func makeKeyRecord(_ windowID: UInt32, kind: UInt8) -> [UInt8] {
        var record = emptyRecord(kind: kind, windowID: windowID)
        record[0x3a] = 0x10
        for index in 0x20 ..< 0x30 {
            record[index] = 0xff
        }
        return record
    }

    private static func emptyRecord(kind: UInt8, windowID: UInt32) -> [UInt8] {
        var record = [UInt8](repeating: 0, count: 0xf8)
        record[0x04] = 0xf8
        record[0x08] = kind
        withUnsafeBytes(of: windowID.littleEndian) { bytes in
            for (offset, byte) in bytes.enumerated() {
                record[0x3c + offset] = byte
            }
        }
        return record
    }
}
