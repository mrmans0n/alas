import Foundation
import JavaScriptCore

struct PluginLimits: Sendable, Equatable {
    /// Wall-clock limit for one call into the plugin. Enforced by JavaScriptCore's watchdog, which only
    /// fires while the JIT is off: `Alas.entitlements` must never gain `com.apple.security.cs.allow-jit`.
    var timePerCall: Duration = .milliseconds(250)
    /// For evaluating the plugin's script, once at load. Every `handle` call, `alas/activate` included,
    /// gets `timePerCall`.
    var timeForActivation: Duration = .seconds(1)
    var maxSourceBytes = 8 << 20
    var maxMessageBytes = 1 << 20
    var maxSendsPerCall = 64
    /// Calls into the plugin per delivery, counting the replies to its own requests.
    var maxRoundTripsPerDelivery = 64
    /// A request's string id is echoed back in its reply, so it has to be bounded.
    var maxRequestIDBytes = 256
    var maxFrameDimension = 1024
    var maxFrameBytes = 4 << 20
}

enum PluginRuntimeError: Error, Equatable, CustomStringConvertible {
    case instantiation(String)
    case missingHandle
    case messageTooLarge(Int)
    case tooManySends(Int)
    case badSend
    case badFrame(String)
    case timeout(milliseconds: Int)
    case exception(String)

    var description: String {
        switch self {
        case .instantiation(let reason): "could not load plugin: \(reason)"
        case .missingHandle: "plugin does not define globalThis.handle"
        case .messageTooLarge(let size): "message of \(size) bytes exceeds the size limit"
        case .tooManySends(let limit): "plugin sent more than \(limit) messages in one call"
        case .badSend: "alas.send expects one string"
        case .badFrame(let reason): "plugin presented an invalid frame: \(reason)"
        case .timeout(let milliseconds): "plugin took longer than \(milliseconds) ms"
        case .exception(let message): "plugin threw: \(message)"
        }
    }
}

/// RGBA8, non-premultiplied, row-major, top-left origin.
struct PluginFrame: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixels: Data
}

/// What one `handle` call produced.
struct PluginDelivery: Sendable {
    var messages: [Data] = []
    /// Last frame per tab index presented during the call.
    var frames: [Int: PluginFrame] = [:]
}

// Private, but exported unchanged by JavaScriptCore since 2014. The watchdog is the only way to stop a
// running script; its termination exception cannot be caught by the script.
private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
@_silgen_name("JSContextGroupSetExecutionTimeLimit")
private func JSContextGroupSetExecutionTimeLimit(
    _ group: JSContextGroupRef, _ limit: Double, _ callback: ShouldTerminate?, _ context: UnsafeMutableRawPointer?)
@_silgen_name("JSContextGroupClearExecutionTimeLimit")
private func JSContextGroupClearExecutionTimeLimit(_ group: JSContextGroupRef)

/// One plugin instance: its own JavaScriptCore VM, whose global object holds nothing from the host but
/// `alas`. Every call runs on `queue`, which is what makes the `@unchecked Sendable` hold. This type moves
/// strings only; it knows nothing about JSON-RPC or Alas.
// ponytail: no memory cap. JSC's heap statistics leave out typed-array storage and the process footprint
// is shared with Alas, so neither attributes memory to a plugin; the time limit bounds growth per call
// (about 70 MB in 250 ms). A helper process is the upgrade if a plugin needs a real cap.
final class PluginRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.nlopez.alas.plugin-runtime")
    private let limits: PluginLimits
    private let tabCount: Int
    private let group: JSContextGroupRef
    private let context: JSContext
    private var handleFunction: JSValue?
    private var outbox: [Data] = []
    private var frames: [Int: PluginFrame] = [:]
    /// Why a host function refused. Set once per call; it wins over the exception it raised, which the
    /// script may have caught.
    private var hostFailure: PluginRuntimeError?

    private init(limits: PluginLimits, tabCount: Int) {
        self.limits = limits
        self.tabCount = tabCount
        group = JSContextGroupCreate()
        let global = JSGlobalContextCreateInGroup(group, nil)
        context = JSContext(jsGlobalContextRef: global)
        JSGlobalContextRelease(global)
    }

    deinit {
        JSContextGroupRelease(group)
    }

    /// `tabCount` is the number of tabs the manifest declares; `alas.present` exists only when it is positive.
    static func load(source: Data, limits: PluginLimits, tabCount: Int = 0) async throws -> PluginRuntime {
        guard source.count <= limits.maxSourceBytes else {
            throw PluginRuntimeError.instantiation("script of \(source.count) bytes exceeds the size limit")
        }
        guard let script = String(data: source, encoding: .utf8) else {
            throw PluginRuntimeError.instantiation("script is not UTF-8")
        }
        let runtime = PluginRuntime(limits: limits, tabCount: tabCount)
        try await runtime.run { try runtime.evaluate(script) }
        return runtime
    }

    /// Calls `globalThis.handle` with one message. Returns what the plugin sent with `alas.send` during the
    /// call, in order. The caller processes them after this returns, so the plugin is never re-entered.
    func handle(_ message: Data) async throws -> PluginDelivery {
        try await run { try self.deliver(message) }
    }

    private func evaluate(_ script: String) throws {
        installHost()
        try call(limit: limits.timeForActivation) { _ = context.evaluateScript(script) }
        guard let handle = context.globalObject.forProperty("handle"),
              let object = JSValueToObject(context.jsGlobalContextRef, handle.jsValueRef, nil),
              handle.isObject, JSObjectIsFunction(context.jsGlobalContextRef, object)
        else { throw PluginRuntimeError.missingHandle }
        handleFunction = handle
    }

    private func installHost() {
        let global = context.globalObject!
        // A bare context still has `console`; the only host object a plugin gets is `alas`.
        global.deleteProperty("console")
        let alas = JSValue(newObjectIn: context)!
        let send: @convention(block) (JSValue) -> Void = { [unowned self] value in receive(value) }
        alas.setValue(send, forProperty: "send")
        if tabCount > 0 {
            let present: @convention(block) (JSValue, JSValue, JSValue) -> Void = { [unowned self] tab, pixels, width in
                self.present(tab: tab, pixels: pixels, width: width)
            }
            alas.setValue(present, forProperty: "present")
        }
        global.setValue(alas, forProperty: "alas")
    }

    private func deliver(_ message: Data) throws -> PluginDelivery {
        guard message.count <= limits.maxMessageBytes else {
            throw PluginRuntimeError.messageTooLarge(message.count)
        }
        outbox = []
        frames = [:]
        let text = String(decoding: message, as: UTF8.self)
        try call(limit: limits.timePerCall) { _ = handleFunction?.call(withArguments: [text]) }
        return PluginDelivery(messages: outbox, frames: frames)
    }

    /// Runs `body` under the watchdog and turns whatever stopped it into a `PluginRuntimeError`.
    private func call(limit: Duration, _ body: () -> Void) throws {
        hostFailure = nil
        context.exception = nil
        JSContextGroupSetExecutionTimeLimit(group, Self.seconds(limit), { _, _ in true }, nil)
        let start = ContinuousClock.now
        body()
        let elapsed = ContinuousClock.now - start
        JSContextGroupClearExecutionTimeLimit(group)
        let exception = context.exception
        context.exception = nil
        if let hostFailure { throw hostFailure }
        guard let exception else { return }
        // The watchdog's exception is an ordinary error object, so elapsed time is what tells it apart.
        if elapsed >= limit { throw PluginRuntimeError.timeout(milliseconds: Int(limit / .milliseconds(1))) }
        throw PluginRuntimeError.exception(Self.firstLine(exception.toString() ?? "exception"))
    }

    private func receive(_ value: JSValue) {
        guard hostFailure == nil else { return }
        guard value.isString, let text = value.toString() else { return refuse(.badSend) }
        guard outbox.count < limits.maxSendsPerCall else { return refuse(.tooManySends(limits.maxSendsPerCall)) }
        let data = Data(text.utf8)
        guard data.count <= limits.maxMessageBytes else { return refuse(.messageTooLarge(data.count)) }
        outbox.append(data)
    }

    private func present(tab: JSValue, pixels: JSValue, width: JSValue) {
        guard hostFailure == nil else { return }
        // Whole numbers only, so a fractional tab cannot quietly draw to another one.
        guard tab.isNumber, width.isNumber, let tab = Int(exactly: tab.toDouble()), let width = Int(exactly: width.toDouble())
        else { return refuse(.badFrame("tab and width must be whole numbers")) }
        guard (0..<tabCount).contains(tab) else { return refuse(.badFrame("tab \(tab) is not declared")) }
        guard (1...limits.maxFrameDimension).contains(width) else {
            return refuse(.badFrame("width \(width) is out of range"))
        }
        let ref = context.jsGlobalContextRef
        let type = JSValueGetTypedArrayType(ref, pixels.jsValueRef, nil)
        guard type == kJSTypedArrayTypeUint8Array || type == kJSTypedArrayTypeUint8ClampedArray,
              let object = JSValueToObject(ref, pixels.jsValueRef, nil),
              let base = JSObjectGetTypedArrayBytesPtr(ref, object, nil)
        else { return refuse(.badFrame("pixels must be a Uint8Array")) }
        let length = JSObjectGetTypedArrayByteLength(ref, object, nil)
        guard length <= limits.maxFrameBytes else {
            return refuse(.badFrame("\(length) bytes exceeds the frame size limit"))
        }
        let rowBytes = width * 4
        guard length % rowBytes == 0, (1...limits.maxFrameDimension).contains(length / rowBytes) else {
            return refuse(.badFrame("length \(length) does not fit width \(width)"))
        }
        // The pointer is the start of the whole buffer, not of this view.
        let offset = JSObjectGetTypedArrayByteOffset(ref, object, nil)
        frames[tab] = PluginFrame(width: width, height: length / rowBytes, pixels: Data(bytes: base + offset, count: length))
    }

    /// Records why a host function refused and throws into the script, which ends the call as failed.
    private func refuse(_ error: PluginRuntimeError) {
        hostFailure = error
        context.exception = JSValue(newErrorFromMessage: error.description, in: context)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init) ?? text
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: body)) }
        }
    }
}
