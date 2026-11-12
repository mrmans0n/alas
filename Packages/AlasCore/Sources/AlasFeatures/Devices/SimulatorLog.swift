import Foundation

public enum SimulatorLogLevel: String, CaseIterable, Sendable {
    /// Default and above.
    case `default`
    /// Adds Info.
    case info
    /// Adds Info and Debug.
    case debug
    /// Errors and faults only.
    case error
}

/// What the logs show: one app's process (or all), a level, and whether
/// Apple's subsystems inside it are kept. The tab and `device_logs` share it.
public struct SimulatorLogQuery: Equatable, Sendable {
    public var executable: String?
    public var level: SimulatorLogLevel
    public var includeApple: Bool

    public init(executable: String?, level: SimulatorLogLevel = .default, includeApple: Bool = false) {
        self.executable = executable
        self.level = level
        self.includeApple = includeApple
    }

    /// The `log --predicate`, or nil when nothing filters.
    public var predicate: String? {
        var parts: [String] = []
        if let executable {
            let escaped = executable.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            parts.append("process == \"\(escaped)\"")
        }
        // Lines with no subsystem (print, NSLog, Swift runtime failures) have "" and pass.
        if !includeApple { parts.append("NOT subsystem BEGINSWITH \"com.apple.\"") }
        if level == .error { parts.append("(messageType == error OR messageType == fault)") }
        return parts.isEmpty ? nil : parts.joined(separator: " AND ")
    }

    /// `log stream`'s level option.
    public var streamArguments: [String] {
        switch level {
        case .default, .error: ["--level", "default"]
        case .info: ["--level", "info"]
        case .debug: ["--level", "debug"]
        }
    }

    /// `log show`'s level flags.
    public var showArguments: [String] {
        switch level {
        case .default, .error: []
        case .info: ["--info"]
        case .debug: ["--info", "--debug"]
        }
    }
}

public struct SimulatorLogLine: Equatable, Sendable {
    public let time: String
    public let level: String
    public let process: String
    public let pid: Int
    public let subsystem: String?
    public let category: String?
    public let message: String

    public init(time: String, level: String, process: String, pid: Int, subsystem: String?, category: String?, message: String) {
        self.time = time
        self.level = level
        self.process = process
        self.pid = pid
        self.subsystem = subsystem
        self.category = category
        self.message = message
    }

    /// One `log … --style ndjson` line; nil for anything but a log event.
    public static func parse(_ line: Data) -> SimulatorLogLine? {
        guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              event["eventType"] as? String == "logEvent",
              let message = event["eventMessage"] as? String
        else { return nil }
        let timestamp = event["timestamp"] as? String ?? ""
        // "2026-11-11 17:15:26.033361+0100": the clock time, to the millisecond.
        let time = timestamp.count >= 23 ? String(timestamp.dropFirst(11).prefix(12)) : timestamp
        func nonEmpty(_ key: String) -> String? {
            (event[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return SimulatorLogLine(
            time: time,
            level: (event["messageType"] as? String ?? "default").lowercased(),
            process: ((event["processImagePath"] as? String ?? "") as NSString).lastPathComponent,
            pid: (event["processID"] as? NSNumber)?.intValue ?? 0,
            subsystem: nonEmpty("subsystem"),
            category: nonEmpty("category"),
            message: message
        )
    }

    public func matches(_ query: String) -> Bool {
        [message, subsystem ?? "", category ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
    }

    public static let messageLimit = 2000

    public var json: [String: Any] {
        [
            "time": time, "level": level, "process": process,
            "subsystem": subsystem ?? NSNull(), "category": category ?? NSNull(),
            "message": message.count > Self.messageLimit ? String(message.prefix(Self.messageLimit)) + "…" : message,
        ]
    }
}

/// The parts of a simulator app's `.ips` crash report worth reading first.
public struct SimulatorCrashReport: Equatable, Sendable {
    public let bundleID: String
    public let appName: String
    public let capturedAt: Date
    /// For example "EXC_BREAKPOINT (SIGTRAP)".
    public let exception: String
    /// Up to 10 frames of the crashing thread as "<image> <symbol>", from the
    /// first frame in the app's own executable.
    public let frames: [String]
    /// The `.ips` file's path, set by whoever read it.
    public var report: String = ""

    public init(bundleID: String, appName: String, capturedAt: Date, exception: String, frames: [String], report: String = "") {
        self.bundleID = bundleID
        self.appName = appName
        self.capturedAt = capturedAt
        self.exception = exception
        self.frames = frames
        self.report = report
    }

    /// An `.ips` file: a JSON header line, then a JSON body. Nil unless it is
    /// a crash of an app on the simulator `udid`.
    public static func parse(_ data: Data, udid: String) -> SimulatorCrashReport? {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let header = (try? JSONSerialization.jsonObject(with: data[..<newline])) as? [String: Any],
              let body = (try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...])) as? [String: Any],
              let bundleID = header["bundleID"] as? String,
              let procPath = body["procPath"] as? String,
              procPath.contains("/CoreSimulator/Devices/\(udid)/"),
              let captured = (body["captureTime"] as? String).flatMap(captureDate)
        else { return nil }
        let exception = body["exception"] as? [String: Any]
        let type = exception?["type"] as? String ?? "Crash"
        let exceptionText = (exception?["signal"] as? String).map { "\(type) (\($0))" } ?? type
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "???" }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = (body["faultingThread"] as? NSNumber)?.intValue ?? 0
        let frames = threads.indices.contains(faulting) ? (threads[faulting]["frames"] as? [[String: Any]] ?? []) : []
        let appImage = (procPath as NSString).lastPathComponent
        let named = frames.map { frame -> (image: String, text: String) in
            let index = (frame["imageIndex"] as? NSNumber)?.intValue ?? -1
            let image = images.indices.contains(index) ? images[index] : "???"
            return (image, "\(image) \(frame["symbol"] as? String ?? "???")")
        }
        let start = named.firstIndex { $0.image == appImage } ?? 0
        return SimulatorCrashReport(
            bundleID: bundleID,
            appName: header["app_name"] as? String ?? appImage,
            capturedAt: captured,
            exception: exceptionText,
            frames: named.dropFirst(start).prefix(10).map(\.text)
        )
    }

    /// "2026-11-12 11:59:39.8525 +0100", fraction dropped.
    private static func captureDate(_ text: String) -> Date? {
        let trimmed = text.replacing(/\.\d+/, with: "")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: trimmed)
    }

    public var json: [String: Any] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return ["time": formatter.string(from: capturedAt), "exception": exception, "frames": frames, "report": report]
    }
}

/// Logs and crash reports, behind a protocol so `DeviceAgentControl` can be tested with a fake.
public protocol SimulatorLogsControl: Sendable {
    /// The bundle ID of the app in front, or nil (the home screen).
    func frontmostApp(udid: String) async -> String?
    /// Every installed app's executable, by bundle ID.
    func executables(udid: String) async throws -> [String: String]
    func logShow(udid: String, query: SimulatorLogQuery, seconds: Int) async throws -> [SimulatorLogLine]
    func crashReports(udid: String, bundleID: String?, since: Date) async -> [SimulatorCrashReport]
}

public struct LiveSimulatorLogs: SimulatorLogsControl {
    private let frontmost: @Sendable (String) async -> String?

    /// `frontmostApp` asks AlasSimService's accessibility bridge, the fallback
    /// when SpringBoard logged nothing recently.
    public init(frontmostApp: @escaping @Sendable (String) async -> String?) {
        frontmost = frontmostApp
    }

    public func frontmostApp(udid: String) async -> String? {
        if let fromLog = await SimulatorControl.foregroundFromLog(udid: udid) { return fromLog.bundleID }
        return await reportedFrontmostApp(udid: udid)
    }

    /// The accessibility bridge's answer, for when SpringBoard's log is silent.
    public func reportedFrontmostApp(udid: String) async -> String? {
        let reported = await frontmost(udid)
        // The bridge names SpringBoard when the home screen is in front.
        return reported == "com.apple.springboard" ? nil : reported
    }

    public func executables(udid: String) async throws -> [String: String] {
        try await SimulatorControl.appExecutables(udid: udid)
    }

    public func logShow(udid: String, query: SimulatorLogQuery, seconds: Int) async throws -> [SimulatorLogLine] {
        try await SimulatorControl.logShow(udid: udid, query: query, seconds: seconds)
    }

    public func crashReports(udid: String, bundleID: String?, since: Date) async -> [SimulatorCrashReport] {
        SimulatorControl.crashReports(udid: udid, bundleID: bundleID, since: since)
    }
}

/// Which app is in front on a simulator, from SpringBoard's log: it logs
/// `[app<bundle>:pid] Setting process visibility to: Foreground` as apps come
/// and go. Ported from serve-sim's `foreground-tracker.ts` (Apache-2.0,
/// ThirdParty/serve-sim-native/LICENSE).
public struct SimulatorForeground: Equatable, Sendable {
    /// The `log --predicate` for the lines `apply` reads.
    public static let predicate =
        #"process == "SpringBoard" AND (eventMessage CONTAINS "Setting process visibility to:" OR eventMessage CONTAINS "Bootstrap success!")"#

    public private(set) var bundleID: String?
    private var pid: Int?
    /// An app shown before its process existed (pid -1), until SpringBoard logs its pid.
    private var pending: String?

    public init() {}

    /// Applies one SpringBoard log message; anything else is ignored.
    public mutating func apply(message: String) {
        if let started = message.firstMatch(of: /\[app<([^>]+)>:(\d+)\] Bootstrap success!/) {
            if String(started.1) == pending {
                bundleID = pending
                pid = Int(started.2)
                pending = nil
            }
            return
        }
        guard let change = message.firstMatch(of: /\[app<([^>]+)>:(-1|\d+)\] Setting process visibility to: (Foreground|Background|Unknown)/),
              Self.isUserFacing(String(change.1))
        else { return }
        let app = String(change.1)
        let changePID = Int(change.2) ?? -1
        let foreground = change.3 == "Foreground"
        if changePID == -1 {
            if foreground {
                bundleID = nil
                pid = nil
                pending = app
            } else if app == pending {
                pending = nil
            }
            return
        }
        if foreground {
            bundleID = app
            pid = changePID
            pending = nil
        } else if bundleID == app, pid == changePID {
            // SpringBoard may background an old process after its replacement is in front.
            bundleID = nil
            pid = nil
        }
    }

    /// False for widgets, extensions and background services, which SpringBoard
    /// also brings to the foreground.
    public static func isUserFacing(_ bundleID: String) -> Bool {
        bundleID.firstMatch(of: nonUI) == nil
    }

    nonisolated(unsafe) private static let nonUI =
        /(^|\.)(WidgetRenderer|ExtensionHost|Service|PlaceholderApp|InCallService|CallUI|InCallUI)(\.|$)|\.extension(\.|$)|com\.apple\.(?:[^.]*ViewService$|Preferences\.Cellular|purplebuddy|chrono|shuttle|usernotificationsui)/
            .ignoresCase()
}
