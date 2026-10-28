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
    private typealias GetFrontProcess = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias GetProcessPID = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<pid_t>) -> Int32
    private typealias SetFrontProcessWithOptions = @convention(c) (UnsafeRawPointer, UInt32, UInt32) -> Int32
    private typealias EventPostToPid = @convention(c) (pid_t, CGEvent) -> Void
    private typealias EventSetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private typealias AXUIElementGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

    /// Resolved once; C function pointers carry no state.
    private struct Symbols: @unchecked Sendable {
        var postEventRecordTo: PostEventRecordTo?
        var getProcessForPID: GetProcessForPID?
        var getFrontProcess: GetFrontProcess?
        var getProcessPID: GetProcessPID?
        var setFrontProcess: SetFrontProcessWithOptions?
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
            getFrontProcess: resolve("_SLPSGetFrontProcess", as: GetFrontProcess.self),
            // Deprecated Carbon, like GetProcessForPID.
            getProcessPID: resolve("GetProcessPID", as: GetProcessPID.self),
            setFrontProcess: resolve("_SLPSSetFrontProcessWithOptions", as: SetFrontProcessWithOptions.self),
            eventPostToPid: resolve("SLEventPostToPid", as: EventPostToPid.self),
            eventSetWindowLocation: resolve("CGEventSetWindowLocation", as: EventSetWindowLocation.self),
            axGetWindow: resolve("_AXUIElementGetWindow", as: AXUIElementGetWindow.self)
        )
    }()

    /// Whether input can go to a background window: it can be made key without activating its app,
    /// confirmed by its window id, and mouse events can carry the point inside it.
    static var isAvailable: Bool {
        symbols.postEventRecordTo != nil && symbols.getProcessForPID != nil
            && symbols.eventSetWindowLocation != nil && symbols.axGetWindow != nil
    }

    /// Whether `windowID(of:)` can name an AX window's CG window.
    static var canIdentifyWindows: Bool { symbols.axGetWindow != nil }

    /// Lets the app handle one record before the next; some apps drop a record that arrives
    /// while they are still handling the previous one (yabai waits the same). Waited out in full
    /// also in a cancelled task, so the records never go out back to back.
    private static let recordSettle: Duration = .milliseconds(40)

    /// Posts the records that make `windowID` the key window of `pid`, moving key status off
    /// `current` (the app's focused window) first. True when every record was accepted; whether
    /// the app acted on them is for the caller to confirm.
    /// Pass a nil `current` for the user's frontmost app: a defocus record there would take key
    /// status from the window the user is working in.
    static func makeKeyWithoutActivating(pid: pid_t, windowID: UInt32, current: UInt32?) async -> Bool {
        guard let psn = processSerialNumber(pid) else { return false }
        let send = { (record: [UInt8]) in self.send(record, to: psn) }
        var accepted = true
        if let current, current != windowID {
            accepted = send(focusRecord(current, focus: false)) && accepted
            await ComputerUseInputPoster.steadyPause(recordSettle)
        }
        accepted = send(focusRecord(windowID, focus: true)) && accepted
        await ComputerUseInputPoster.steadyPause(recordSettle)
        for kind: UInt8 in [0x01, 0x02] {
            accepted = send(makeKeyRecord(windowID, kind: kind)) && accepted
        }
        return accepted
    }

    /// Hands key status back after a background input: the app stops treating `windowID` as its
    /// active key window, as it did before. For an app that isn't the user's front app only.
    static func defocus(pid: pid_t, windowID: UInt32) -> Bool {
        guard let psn = processSerialNumber(pid) else { return false }
        return send(focusRecord(windowID, focus: false), to: psn)
    }

    /// Whether WindowServer has `pid` as its front process; nil when it can't tell.
    static func isFrontProcess(pid: pid_t) -> Bool? {
        guard let getFront = symbols.getFrontProcess, let psn = processSerialNumber(pid) else { return nil }
        var front = [UInt8](repeating: 0, count: 8)
        guard getFront(&front) == 0 else { return nil }
        return front == psn
    }

    /// Makes `pid` WindowServer's front process and brings its front window forward, as a click on
    /// it would (yabai's `kCPSUserGenerated`, no window named). Unlike
    /// `NSRunningApplication.activate()`, which macOS's cooperative activation ignores from an app
    /// that isn't frontmost, it works from the background. False when the symbol is missing or
    /// WindowServer refused; whether the app came forward is for the caller to confirm.
    static func setFrontProcess(pid: pid_t) -> Bool {
        guard let setFront = symbols.setFrontProcess, let psn = processSerialNumber(pid) else { return false }
        return psn.withUnsafeBytes { setFront($0.baseAddress!, 0, userGeneratedActivation) } == 0
    }

    /// `kCPSUserGenerated`.
    private static let userGeneratedActivation: UInt32 = 0x200

    /// The pid of WindowServer's front process; nil when it can't tell.
    static func frontProcessPID() -> pid_t? {
        guard let getFront = symbols.getFrontProcess, let getPID = symbols.getProcessPID else { return nil }
        var front = [UInt8](repeating: 0, count: 8)
        guard getFront(&front) == 0 else { return nil }
        var pid: pid_t = 0
        return getPID(front, &pid) == 0 && pid > 0 ? pid : nil
    }

    private static func processSerialNumber(_ pid: pid_t) -> [UInt8]? {
        guard symbols.postEventRecordTo != nil, let getProcess = symbols.getProcessForPID else { return nil }
        var psn = [UInt8](repeating: 0, count: 8)
        return getProcess(pid, &psn) == 0 ? psn : nil
    }

    private static func send(_ record: [UInt8], to psn: [UInt8]) -> Bool {
        guard let post = symbols.postEventRecordTo else { return false }
        return psn.withUnsafeBytes { psn in record.withUnsafeBytes { post(psn.baseAddress!, $0.baseAddress!) } } == 0
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
        // Marks it as Alas's, should an input monitor ever see it.
        event.setIntegerValueField(.eventSourceUserData, value: ComputerUseUserInput.postedEventMarker)
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
