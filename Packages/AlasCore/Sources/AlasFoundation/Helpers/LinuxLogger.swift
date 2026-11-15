import Foundation

// Linux has no unified logging. These stand in for the parts of `os` the core
// uses, with the same spelling, so logging code builds unchanged: messages go
// to stderr (journald collects them under systemd), `.private` values are
// redacted, and `OSAllocatedUnfairLock` is a plain lock.
#if !canImport(os)
public enum OSLogType: Sendable {
    case debug, info, `default`, error, fault
}

public struct OSLogPrivacy: Sendable, Equatable {
    let redacted: Bool

    public static let `public` = OSLogPrivacy(redacted: false)
    public static let `private` = OSLogPrivacy(redacted: true)
    public static let sensitive = OSLogPrivacy(redacted: true)
    public static let auto = OSLogPrivacy(redacted: false)
}

public enum OSLogFloatFormatting: Sendable {
    case fixed(precision: Int)
}

public struct OSLogMessage: ExpressibleByStringInterpolation, Sendable {
    let text: String

    public init(stringLiteral value: String) {
        text = value
    }

    public init(stringInterpolation: StringInterpolation) {
        text = stringInterpolation.text
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var text = ""

        public init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity)
        }

        public mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        public mutating func appendInterpolation(_ value: @autoclosure () -> some Any, privacy: OSLogPrivacy = .auto) {
            text += privacy.redacted ? "<private>" : String(describing: value())
        }

        public mutating func appendInterpolation(
            _ value: @autoclosure () -> some BinaryFloatingPoint,
            format: OSLogFloatFormatting,
            privacy: OSLogPrivacy = .auto
        ) {
            guard !privacy.redacted else {
                text += "<private>"
                return
            }
            switch format {
            case .fixed(let precision): text += String(format: "%.\(precision)f", Double(value()))
            }
        }
    }
}

public struct Logger: Sendable {
    private let label: String

    public init(subsystem: String, category: String) {
        label = category
    }

    public func log(level: OSLogType, _ message: OSLogMessage) {
        let line = "[\(label)] \(level): \(message.text)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    public func log(_ message: OSLogMessage) { log(level: .default, message) }
    public func trace(_ message: OSLogMessage) { log(level: .debug, message) }
    public func debug(_ message: OSLogMessage) { log(level: .debug, message) }
    public func info(_ message: OSLogMessage) { log(level: .info, message) }
    public func notice(_ message: OSLogMessage) { log(level: .default, message) }
    public func warning(_ message: OSLogMessage) { log(level: .error, message) }
    public func error(_ message: OSLogMessage) { log(level: .error, message) }
    public func critical(_ message: OSLogMessage) { log(level: .fault, message) }
    public func fault(_ message: OSLogMessage) { log(level: .fault, message) }
}

public final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    public init(initialState: State) {
        state = initialState
    }

    public func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}
#endif
