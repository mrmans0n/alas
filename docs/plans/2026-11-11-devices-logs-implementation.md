# Simulator logs and crash reports: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Logs center tab for a simulator, and a `device_logs` agent tool, both showing the foreground app's own logs and its crash reports.

**Architecture:** AlasCore parses `log` ndjson lines and `.ips` crash reports, builds the shared `log` predicate, and wraps `log show` and the DiagnosticReports scan behind `SimulatorLogsControl`. The vendored session and `AlasSimService` expose serve-sim's `frontmostApp`. `DeviceAgentControl` answers `device_logs` from `SimulatorLogsControl`. The tab runs `log stream` through `SimulatorLogStream`.

**Tech Stack:** Swift 6 / SwiftUI, Swift Testing, Rust (`AlasCLI`), `xcrun simctl`, XPC.

**Spec:** `docs/plans/2026-11-11-devices-logs-design.md`

## Global Constraints

- English everywhere; Conventional Commits; no agent attribution.
- Swift Testing; AGENTS.md testing policy (extend suites, parameterize, no fixed sleeps in tests, `eventually` for polling).
- AlasCore imports no AppKit/SwiftUI; app-facing API is `public`.
- Vendored serve-sim files are never edited; only `AlasSimulatorSession.swift` is Alas's.
- Defaults: foreground app, `default` level, no `com.apple.*` subsystems, 60 s, 200 lines; bounds 1–600 s, 1–1000 lines; messages cut at 2,000 characters; the tab keeps 5,000 lines.
- Error codes: `device_no_app`, `device_app_not_installed`, `device_not_booted`, `device_not_found`, `device_logs_failed`.
- Run `xcodegen` after adding app files; commit only the project lines for new files (xcodegen reshuffles two copy phases).

## Checked while planning (iOS 26.5)

- Predicates that work: `process == "Crash" AND NOT subsystem BEGINSWITH "com.apple."` (keeps lines whose subsystem is empty, such as `print` and Swift fatal errors), `(messageType == error OR messageType == fault)`.
- `log show` takes `--info` and `--debug`; `log stream` takes `--level default|info|debug`.
- ndjson lines with no subsystem have `"subsystem": ""`, not null.

## Review Focus

1. A line with an empty subsystem (a `print`, a Swift fatal error) must survive the default filter. Test in Task 1 (predicate) and Task 1 (parse maps `""` to nil).
2. A crash report from another simulator, or another app, must not be attributed to this one. Test in Task 1.
3. A crash whose frames never enter the app's own image still yields frames (from the top). Test in Task 1.
4. `device_logs` with no app in front and no `bundle_id` fails clearly, not with an empty list. Test in Task 3.
5. More matching lines than `limit`: the newest are kept, oldest first, and `truncated` is true. Test in Task 3.

---

### Task 1: Logs and crash reports in AlasCore

**Files:**
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorLog.swift`
- Modify: `Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorSettings.swift` (`SimulatorAppList.executables`)
- Modify: `Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorControl.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/SimulatorLogTests.swift`

**Interfaces:**
- Produces:

```swift
public enum SimulatorLogLevel: String, CaseIterable, Sendable { case `default`, info, debug, error }
public struct SimulatorLogQuery: Equatable, Sendable {
    public var executable: String?          // nil: all processes
    public var level: SimulatorLogLevel
    public var includeApple: Bool
    public init(executable: String?, level: SimulatorLogLevel = .default, includeApple: Bool = false)
    public var predicate: String?           // nil when nothing filters
    public var streamArguments: [String]    // for `log stream`
    public var showArguments: [String]      // for `log show`
}
public struct SimulatorLogLine: Equatable, Sendable {
    public let time: String                 // HH:mm:ss.SSS
    public let level: String                // default, info, debug, error, fault
    public let process: String
    public let pid: Int
    public let subsystem: String?
    public let category: String?
    public let message: String
    public static func parse(_ line: Data) -> SimulatorLogLine?
    public func matches(_ query: String) -> Bool
    public var json: [String: Any]
}
public struct SimulatorCrashReport: Equatable, Sendable {
    public let bundleID: String
    public let appName: String
    public let capturedAt: Date
    public let exception: String
    public let frames: [String]
    public var report: String
    public static func parse(_ data: Data, udid: String) -> SimulatorCrashReport?
    public var json: [String: Any]
}
extension SimulatorAppList { public static func executables(_ plist: Data) -> [String: String] }
extension SimulatorControl {
    public static func logShow(udid: String, query: SimulatorLogQuery, seconds: Int) async throws -> [SimulatorLogLine]
    public static func crashReports(udid: String, bundleID: String?, since: Date, directory: URL = …) -> [SimulatorCrashReport]
    public static func appExecutables(udid: String) async throws -> [String: String]
}
public protocol SimulatorLogsControl: Sendable {
    func frontmostApp(udid: String) async -> String?
    func executables(udid: String) async throws -> [String: String]
    func logShow(udid: String, query: SimulatorLogQuery, seconds: Int) async throws -> [SimulatorLogLine]
    func crashReports(udid: String, bundleID: String?, since: Date) async -> [SimulatorCrashReport]
}
public struct LiveSimulatorLogs: SimulatorLogsControl {
    public init(frontmostApp: @escaping @Sendable (String) async -> String?)
}
```

- [ ] **Step 1: Failing tests**

```swift
import Foundation
import Testing
@testable import AlasCore

struct SimulatorLogTests {
    static let udid = "8CA9B1E8-EE67-49E5-846F-293450990F76"
    static let appPath = "/Users/me/Library/Developer/CoreSimulator/Devices/\(udid)/data/Containers/Bundle/Application/X/Crash.app/Crash"

    @Test func parsesALogEventAndAnEmptySubsystemIsNone() throws {
        let line = Data(#"{"eventType":"logEvent","messageType":"Default","subsystem":"","category":"","processImagePath":"\#(Self.appPath)","processID":55335,"timestamp":"2026-11-11 17:15:26.033361+0100","eventMessage":"Fatal error: Index out of range"}"#.utf8)
        #expect(SimulatorLogLine.parse(line) == SimulatorLogLine(
            time: "17:15:26.033", level: "default", process: "Crash", pid: 55335,
            subsystem: nil, category: nil, message: "Fatal error: Index out of range"
        ))
        #expect(SimulatorLogLine.parse(Data(#"{"eventType":"activityCreateEvent"}"#.utf8)) == nil)
        #expect(SimulatorLogLine.parse(Data("Filtering the log data".utf8)) == nil)
    }

    @Test(arguments: [
        (SimulatorLogQuery(executable: "Crash"), #"process == "Crash" AND NOT subsystem BEGINSWITH "com.apple.""#,
         ["--level", "default"], [String]()),
        (SimulatorLogQuery(executable: "Crash", level: .debug, includeApple: true), #"process == "Crash""#,
         ["--level", "debug"], ["--info", "--debug"]),
        (SimulatorLogQuery(executable: nil, level: .error, includeApple: true), "(messageType == error OR messageType == fault)",
         ["--level", "default"], []),
        (SimulatorLogQuery(executable: #"My "App""#, level: .info), #"process == "My \"App\"" AND NOT subsystem BEGINSWITH "com.apple.""#,
         ["--level", "info"], ["--info"]),
    ] as [(SimulatorLogQuery, String, [String], [String])])
    func queriesBuildPredicateAndLevelArguments(query: SimulatorLogQuery, predicate: String, stream: [String], show: [String]) {
        #expect(query.predicate == predicate)
        #expect(query.streamArguments == stream)
        #expect(query.showArguments == show)
    }

    @Test func allProcessesAtDefaultWithAppleHasNoPredicate() {
        #expect(SimulatorLogQuery(executable: nil, includeApple: true).predicate == nil)
    }

    static let header = #"{"app_name":"Crash","timestamp":"2026-11-12 11:59:54.00 +0100","bundleID":"com.example.crash","name":"Crash"}"#
    static func body(path: String = appPath, appFrames: Bool = true) -> String {
        let frames = appFrames
            ? #"[{"imageIndex":1,"symbol":"_assertionFailure(_:_:file:line:flags:)"},{"imageIndex":1,"symbol":"Array.subscript.getter"},{"imageIndex":0,"symbol":"AppDelegate.application(_:didFinishLaunchingWithOptions:)"},{"imageIndex":2,"symbol":"-[UIApplication _handleDelegateCallbacksWithOptions:isSuspended:restoreState:]"}]"#
            : #"[{"imageIndex":1,"symbol":"_assertionFailure(_:_:file:line:flags:)"},{"imageIndex":2,"symbol":"UIApplicationMain"}]"#
        return #"{"procPath":"\#(path)","captureTime":"2026-11-12 11:59:39.8525 +0100","exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"faultingThread":0,"threads":[{"frames":\#(frames)}],"usedImages":[{"name":"Crash"},{"name":"libswiftCore.dylib"},{"name":"UIKitCore"}]}"#
    }

    @Test func crashReportSummaryStartsAtTheAppsOwnFrames() throws {
        let report = try #require(SimulatorCrashReport.parse(Data((Self.header + "\n" + Self.body()).utf8), udid: Self.udid))
        #expect(report.bundleID == "com.example.crash")
        #expect(report.appName == "Crash")
        #expect(report.exception == "EXC_BREAKPOINT (SIGTRAP)")
        #expect(report.frames == [
            "Crash AppDelegate.application(_:didFinishLaunchingWithOptions:)",
            "UIKitCore -[UIApplication _handleDelegateCallbacksWithOptions:isSuspended:restoreState:]",
        ])
        // 2026-11-12 11:59:39 +0100; the fraction is dropped.
        #expect(report.capturedAt == Date(timeIntervalSince1970: 1_794_481_179))
    }

    @Test func crashReportWithoutAppFramesStartsAtTheTop() throws {
        let report = try #require(SimulatorCrashReport.parse(Data((Self.header + "\n" + Self.body(appFrames: false)).utf8), udid: Self.udid))
        #expect(report.frames.first == "libswiftCore.dylib _assertionFailure(_:_:file:line:flags:)")
    }

    @Test func aCrashReportFromAnotherSimulatorIsNotThisOnes() {
        let other = Self.body(path: Self.appPath.replacingOccurrences(of: Self.udid, with: "OTHER-UDID"))
        #expect(SimulatorCrashReport.parse(Data((Self.header + "\n" + other).utf8), udid: Self.udid) == nil)
    }

    @Test func appExecutablesComeFromListapps() throws {
        let plist: [String: Any] = [
            "com.apple.Preferences": ["ApplicationType": "System", "CFBundleExecutable": "Preferences"],
            "com.example.hello": ["ApplicationType": "User", "CFBundleExecutable": "Hello"],
            "com.example.broken": ["ApplicationType": "User"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(SimulatorAppList.executables(data) == ["com.apple.Preferences": "Preferences", "com.example.hello": "Hello"])
    }
}
```


Run `swift test --package-path Packages/AlasCore --filter SimulatorLogTests`: build errors.

- [ ] **Step 2: Implement `SimulatorLog.swift`**

```swift
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

    /// `frontmostApp` asks AlasSimService, which the app owns.
    public init(frontmostApp: @escaping @Sendable (String) async -> String?) {
        frontmost = frontmostApp
    }

    public func frontmostApp(udid: String) async -> String? { await frontmost(udid) }

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
```

- [ ] **Step 3: `SimulatorAppList.executables` and `SimulatorControl`**

In `SimulatorSettings.swift`, extend `SimulatorAppList`:

```swift
    /// Every app's executable in `simctl listapps` output, by bundle ID.
    public static func executables(_ plist: Data) -> [String: String] {
        guard let apps = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: [String: Any]] else {
            return [:]
        }
        return apps.compactMapValues { $0["CFBundleExecutable"] as? String }
    }
```

In `SimulatorControl`:

```swift
    public static func appExecutables(udid: String) async throws -> [String: String] {
        let result = try await Process.run(xcrun, args: ["simctl", "listapps", udid])
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
        return SimulatorAppList.executables(Data(result.stdout.utf8))
    }

    /// The archived log lines of the last `seconds`, oldest first.
    public static func logShow(udid: String, query: SimulatorLogQuery, seconds: Int) async throws -> [SimulatorLogLine] {
        var args = ["simctl", "spawn", udid, "log", "show", "--last", "\(seconds)s", "--style", "ndjson"] + query.showArguments
        if let predicate = query.predicate { args += ["--predicate", predicate] }
        let result = try await Process.run(xcrun, args: args, timeout: 90)
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
        return result.stdout.split(separator: "\n").compactMap { SimulatorLogLine.parse(Data($0.utf8)) }
    }

    public static let diagnosticReports = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)

    /// The simulator's app crash reports written since `since`, oldest first.
    public static func crashReports(udid: String, bundleID: String?, since: Date, directory: URL = diagnosticReports) -> [SimulatorCrashReport] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
        )) ?? []
        return files
            .filter { $0.pathExtension == "ips" }
            .filter { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) >= since }
            .compactMap { url -> SimulatorCrashReport? in
                guard let data = try? Data(contentsOf: url), var report = SimulatorCrashReport.parse(data, udid: udid),
                      bundleID == nil || report.bundleID == bundleID
                else { return nil }
                report.report = url.path
                return report
            }
            .sorted { $0.capturedAt < $1.capturedAt }
    }
```

Check `Process.run` takes `timeout:` (it does, `AlasPlatform/Git/Process+Git.swift:58`).

- [ ] **Step 4:** Run `swift test --package-path Packages/AlasCore --filter 'SimulatorLogTests|SimulatorSettingsTests'`: pass.
- [ ] **Step 5: Commit** `feat(devices): read simulator logs and crash reports`

---

### Task 2: The frontmost app through AlasSimService

**Files:**
- Modify: `ThirdParty/serve-sim-native/Sources/ServeSimCore/AlasSimulatorSession.swift`
- Modify: `Alas/Sources/Devices/SimServiceProtocol.swift`, `Alas/Sources/SimService/SimServiceHandler.swift`, `Alas/Sources/Devices/SimulatorStreamClient.swift`

**Interfaces:**
- Produces: `AlasSimulatorSession.frontmostApp(udid:) -> String?` (static); `SimServiceProtocol.frontmostApp(udid:reply: @Sendable (String?) -> Void)`; `SimulatorStreamClient.frontmostApp(udid:) async -> String?`.

No automated test (XPC and private frameworks); verified end to end in Task 5.

- [ ] **Step 1:** In `AlasSimulatorSession`, after `describeUI`:

```swift
    /// The bundle ID of the app in front on a booted simulator, or nil when
    /// SpringBoard shows none (the home screen). Doesn't walk the UI.
    public static func frontmostApp(udid: String) -> String? {
        SimFrameworks.load()
        return (try? AccessibilityBridge.shared.frontmostApp(udid: udid))?["bundleId"] as? String
    }
```

- [ ] **Step 2:** Protocol: `func frontmostApp(udid: String, reply: @escaping @Sendable (String?) -> Void)` with doc "The bundle ID of the app in front, or nil." Handler, like `describe`, off the XPC queue:

```swift
    func frontmostApp(udid: String, reply: @escaping @Sendable (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            reply(AlasSimulatorSession.frontmostApp(udid: udid))
        }
    }
```

Client, after `describe`:

```swift
    /// The bundle ID of the app in front, or nil when none is or the service can't tell.
    func frontmostApp(udid: String) async -> String? {
        let connection = self.connection ?? connect()
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = Self.proxy(connection) { _ in once.resume(returning: nil) }
            guard let proxy else {
                once.resume(returning: nil)
                return
            }
            proxy.frontmostApp(udid: udid) { once.resume(returning: $0) }
        }
    }
```

Check `ResumeOnce` works with a non-throwing continuation; if it only wraps `CheckedContinuation<_, Error>`, make it generic over the error type (`ResumeOnce<T, E: Error>`) in the same file.

- [ ] **Step 3:** Build: `xcodebuild … -quiet build`. Commit `feat(devices): ask AlasSimService which app is in front`.

---

### Task 3: `device_logs`

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasAgentKit/Harness/DeviceCommand.swift`, `Packages/AlasCore/Tests/AlasCoreTests/DeviceCommandTests.swift`
- Modify: `Packages/AlasCore/Sources/AlasACP/ACP/Session/ACPMCPPromptPreamble.swift`, `AlasTests/ACP/Session/ACPMCPPromptPreambleTests.swift`
- Modify: `Alas/Sources/Devices/DeviceAgentControl.swift`, `Alas/Sources/App/AppState.swift` (`deviceControl`), `AlasTests/DeviceAgentControlTests.swift`
- Modify: `AlasCLI/crates/alas/src/mcp.rs`, `AlasCLI/crates/alas-client/src/lib.rs`

**Interfaces:**
- Consumes: Task 1's types and `SimulatorLogsControl`; Task 2's `frontmostApp`.
- Produces: `DeviceCommand.logs(udid: String, sinceSeconds: Int, bundleID: String?, level: SimulatorLogLevel, includeApple: Bool, query: String?, limit: Int)`; `DeviceAgentControl.init(..., settings:, logs: any SimulatorLogsControl, ...)`; Rust `DeviceCommand::Logs { udid, since_seconds: u64, bundle_id: Option<String>, level: String, include_apple: bool, query: Option<String>, limit: u64 }`.

- [ ] **Step 1: Swift decode tests.** In `decodesEachActionWithDefaults`:

```swift
        ("device_logs", #"{"udid":"U"}"#,
         .logs(udid: "U", sinceSeconds: 60, bundleID: nil, level: .default, includeApple: false, query: nil, limit: 200)),
        ("device_logs", #"{"udid":"U","since_seconds":600,"bundle_id":"b","level":"error","include_apple":true,"query":"fatal","limit":5}"#,
         .logs(udid: "U", sinceSeconds: 600, bundleID: "b", level: .error, includeApple: true, query: "fatal", limit: 5)),
```

In `refusesWhatAnActionDoesNotTake`:

```swift
        ("device_logs", #"{"udid":"U","since_seconds":601}"#),
        ("device_logs", #"{"udid":"U","level":"verbose"}"#),
        ("device_logs", #"{"udid":"U","limit":0}"#),
```

- [ ] **Step 2: Implement the Swift command.** Case, `toolName` `device_logs`, `udid`. `Params`: `since_seconds: Int?`, `level: String?`, `include_apple: Bool?`; `query` and `limit` exist. Allowed: `"device_logs": ["udid", "since_seconds", "bundle_id", "level", "include_apple", "query", "limit"]`. Decode:

```swift
        case "device_logs":
            let since = params.since_seconds ?? 60
            let limit = params.limit ?? 200
            let level = try params.level.map { try enumValue(SimulatorLogLevel.self, $0) } ?? .default
            guard (1...600).contains(since), (1...1000).contains(limit), (params.query?.utf8.count ?? 0) <= 256 else {
                throw AlasCLIRequestError.malformed
            }
            let bundle: String? = params.bundle_id == nil ? nil : try bundleID()
            return .logs(udid: try udid(), sinceSeconds: since, bundleID: bundle, level: level,
                         includeApple: params.include_apple ?? false, query: params.query, limit: limit)
```

Add `"device_logs"` after `"device_open_url"` in `builtInToolNames` and the preamble test inventory; in the device paragraph add `"Read the app's logs and crash reports with device_logs. "` after the settings sentence. Run `swift test --package-path Packages/AlasCore --filter DeviceCommandTests`: pass.

- [ ] **Step 3: App tests.** In `DeviceAgentControlTests` add:

```swift
    final class FakeLogs: SimulatorLogsControl, @unchecked Sendable {
        var front: String? = "com.example.hello"
        var lines: [SimulatorLogLine] = []
        var queries: [SimulatorLogQuery] = []
        func frontmostApp(udid: String) async -> String? { front }
        func executables(udid: String) async throws -> [String: String] { ["com.example.hello": "Hello"] }
        func logShow(udid: String, query: SimulatorLogQuery, seconds: Int) async throws -> [SimulatorLogLine] {
            queries.append(query)
            return lines
        }
        func crashReports(udid: String, bundleID: String?, since: Date) async -> [SimulatorCrashReport] { [] }
    }

    static func line(_ message: String) -> SimulatorLogLine {
        SimulatorLogLine(time: "12:00:00.000", level: "default", process: "Hello", pid: 1, subsystem: nil, category: nil, message: message)
    }
```

Give `control(...)` a `logs: FakeLogs = FakeLogs()` parameter passed as `logs:`, and pass `logs: FakeLogs()` in the suite's other `DeviceAgentControl(...)` calls. Tests:

```swift
    @Test func logsFollowTheForegroundAppAndAreNotHeldDuringATakeover() async throws {
        let logs = FakeLogs()
        logs.lines = [Self.line("one"), Self.line("Fatal error: two"), Self.line("three")]
        let control = control(FakeInput(), logs: logs)
        control.takeOver(udid: "on")
        let response = await control.perform(
            .logs(udid: "on", sinceSeconds: 60, bundleID: nil, level: .default, includeApple: false, query: "FATAL", limit: 200),
            sessionID: "s"
        )
        guard case .text(let text) = response else { Issue.record("\(response)"); return }
        let json = try #require(JSONSerialization.jsonObject(with: Data(text.joined().utf8)) as? [String: Any])
        #expect(json["app"] as? String == "com.example.hello")
        #expect((json["lines"] as? [[String: Any]])?.map { $0["message"] as? String } == ["Fatal error: two"])
        #expect(json["truncated"] as? Bool == false)
        #expect(logs.queries == [SimulatorLogQuery(executable: "Hello")])
    }

    @Test func logsKeepTheNewestLinesUpToTheLimit() async throws {
        let logs = FakeLogs()
        logs.lines = (1...5).map { Self.line("\($0)") }
        let response = await control(FakeInput(), logs: logs).perform(
            .logs(udid: "on", sinceSeconds: 60, bundleID: nil, level: .default, includeApple: false, query: nil, limit: 2),
            sessionID: "s"
        )
        guard case .text(let text) = response else { Issue.record("\(response)"); return }
        let json = try #require(JSONSerialization.jsonObject(with: Data(text.joined().utf8)) as? [String: Any])
        #expect((json["lines"] as? [[String: Any]])?.map { $0["message"] as? String } == ["4", "5"])
        #expect(json["truncated"] as? Bool == true)
    }

    @Test(arguments: [
        (nil as String?, nil as String?, "device_no_app: No app is in front on iPhone. Pass bundle_id."),
        ("com.example.gone", "com.example.hello", "device_app_not_installed: com.example.gone isn't installed on iPhone."),
    ])
    func logsNeedAnApp(bundleID: String?, front: String?, message: String) async {
        let logs = FakeLogs()
        logs.front = front
        let response = await control(FakeInput(), logs: logs).perform(
            .logs(udid: "on", sinceSeconds: 60, bundleID: bundleID, level: .default, includeApple: false, query: nil, limit: 200),
            sessionID: "s"
        )
        #expect(error(response) == message)
    }
```

- [ ] **Step 4: Implement it in `DeviceAgentControl`.** Store `logs: any SimulatorLogsControl` (init parameter after `settings:`). At the top of `perform`, right after `guard let udid = command.udid …`:

```swift
        // A read that the user's driving doesn't disturb: neither held nor queued.
        if case .logs(_, let since, let bundleID, let level, let includeApple, let query, let limit) = command {
            return await readLogs(udid: udid, since: since, bundleID: bundleID, level: level,
                                  includeApple: includeApple, query: query, limit: limit)
        }
```

Add `.logs` to the `isInput` switch's `false` list, and to the main `switch command` as `case .logs: return .error("device_logs_failed: unreachable")` (it returned above). Then:

```swift
    private func readLogs(
        udid: String, since: Int, bundleID: String?, level: SimulatorLogLevel, includeApple: Bool, query: String?, limit: Int
    ) async -> AlasCLIResponse {
        let device: SimulatorDevice
        do {
            guard let found = try await devices().first(where: { $0.udid == udid }) else {
                return .error("device_not_found: No iOS simulator \(udid). Call device_list.")
            }
            device = found
        } catch {
            return .error("device_unavailable: \(error.localizedDescription)")
        }
        guard device.state == .booted else {
            return .error("device_not_booted: \(device.name) is shut down. Call device_open to boot it.")
        }
        var app = bundleID
        if app == nil { app = await logs.frontmostApp(udid: udid) }
        guard let app else { return .error("device_no_app: No app is in front on \(device.name). Pass bundle_id.") }
        do {
            guard let executable = try await logs.executables(udid: udid)[app] else { return Self.notInstalled(app, on: device) }
            let all = try await logs.logShow(
                udid: udid, query: SimulatorLogQuery(executable: executable, level: level, includeApple: includeApple), seconds: since
            )
            let matching = query.map { query in all.filter { $0.matches(query) } } ?? all
            let crashes = await logs.crashReports(udid: udid, bundleID: app, since: now().addingTimeInterval(-Double(since)))
            return .text([Self.json([
                "app": app,
                "lines": matching.suffix(limit).map(\.json),
                "truncated": matching.count > limit,
                "crashes": crashes.map(\.json),
            ])])
        } catch {
            return .error("device_logs_failed: \(error.localizedDescription)")
        }
    }
```

`AppState.deviceControl`: `logs: LiveSimulatorLogs { [simulatorStreams] udid in await simulatorStreams.frontmostApp(udid: udid) }`.

- [ ] **Step 5: Rust tests.** `mcp.rs` mapping test:

```rust
        assert_eq!(
            map("device_logs", json!({ "udid": "U" })).unwrap(),
            Command::Device(DeviceCommand::Logs {
                udid: "U".into(),
                since_seconds: 60,
                bundle_id: None,
                level: "default".into(),
                include_apple: false,
                query: None,
                limit: 200
            })
        );
```

Errors:

```rust
            ("device_logs", json!({ "udid": "U", "since_seconds": 601 }), "since_seconds must be an integer from 1 to 600"),
            ("device_logs", json!({ "udid": "U", "level": "verbose" }), "level must be one of default, info, debug, error"),
```

Add `"device_logs"` after `"device_open_url"` in the inventory, and to the read-only annotation list. `alas-client`: serialize test:

```rust
        assert_eq!(
            build(DeviceCommand::Logs {
                udid: udid(), since_seconds: 60, bundle_id: None, level: "default".into(),
                include_apple: false, query: None, limit: 200
            }).1,
            serde_json::json!({ "udid": "U-1", "since_seconds": 60, "level": "default", "include_apple": false, "limit": 200 })
        );
```

- [ ] **Step 6: Rust implementation.** `alas-client`: the variant; `includes_screenshot` false; `device_request` builds `{udid, since_seconds, level, include_apple, limit}` plus `bundle_id` and `query` when set. `mcp.rs` definition (read-only), after `device_open_url`:

```rust
        json!({
            "name": "device_logs",
            "description": "Read an app's recent logs and crash reports on a booted simulator: by default the app in front, its own lines at Default level and above, without Apple's subsystems, from the last 60 seconds. Returns lines oldest first (the newest `limit`; `truncated` says when more matched) and `crashes` with each report's exception and crashing frames. Debug and Info lines are only there if the app's logging keeps them. A crash report appears about 30 seconds after the crash: if the logs end in a fatal error and `crashes` is empty, call again shortly.",
            "annotations": { "readOnlyHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "udid": udid,
                    "since_seconds": { "type": "integer", "minimum": 1, "maximum": 600, "description": "Default: 60." },
                    "bundle_id": { "type": "string", "minLength": 1, "maxLength": 255, "description": "Default: the app in front." },
                    "level": { "type": "string", "enum": ["default", "info", "debug", "error"], "description": "default: Default and above. error: errors and faults only. Default: default." },
                    "include_apple": { "type": "boolean", "description": "Keep Apple's subsystems (com.apple.*) inside the app. Default: false." },
                    "query": { "type": "string", "maxLength": 256, "description": "Only lines whose message, subsystem or category contain this text." },
                    "limit": { "type": "integer", "minimum": 1, "maximum": 1000, "description": "Default: 200." }
                },
                "required": ["udid"]
            }
        }),
```

Parsing:

```rust
        "device_logs" => {
            reject_arguments(args, name, &["udid", "since_seconds", "bundle_id", "level", "include_apple", "query", "limit"])?;
            Ok(Command::Device(alas_client::DeviceCommand::Logs {
                udid: required_limited_string(args, "udid", 64)?,
                since_seconds: optional_bounded_u64(args, "since_seconds", 1, 600)?.unwrap_or(60),
                bundle_id: optional_limited_string(args, "bundle_id", 255)?,
                level: optional_enum(args, "level", &["default", "info", "debug", "error"])?.unwrap_or("default").into(),
                include_apple: optional_bool(args, "include_apple")?.unwrap_or(false),
                query: optional_limited_string(args, "query", 256)?,
                limit: optional_bounded_u64(args, "limit", 1, 1000)?.unwrap_or(200),
            }))
        }
```

Check the exact error text `optional_bounded_u64` produces and use it in the test.

- [ ] **Step 7: Run** the AlasCore `DeviceCommandTests`, `cargo test -p alas -p alas-client`, and `DeviceAgentControlTests` + `ACPMCPPromptPreambleTests`. Commit `feat(devices): let agents read simulator logs and crash reports`.

---

### Task 4: The Logs tab

**Files:**
- Modify: `Alas/Sources/Center/Tab.swift`, `Alas/Sources/Center/TabsManager.swift`, `Alas/Sources/Center/CenterPaneView.swift`
- Create: `Alas/Sources/Devices/SimulatorLogStream.swift`, `Alas/Sources/Devices/SimulatorLogsTabView.swift`
- Modify: `Alas/Sources/Devices/DevicesSwitcher.swift` (`DevicesActions`), `Alas/Sources/Right/RightPaneView.swift` (`devicesActions`), `Alas/Sources/Devices/AppState+DevicesTab.swift` (`openSimulatorLogs`)

**Interfaces:**
- Consumes: Task 1 (`SimulatorLogQuery`, `SimulatorLogLine`, `SimulatorControl.crashReports`, `appExecutables`, `userApps`), Task 2 (`frontmostApp`).
- Produces: `Tab.simulatorLogs(SimulatorLogsTabState)`; `SimulatorLogsTabState(worktreeId:udid:deviceName:)` with `id = "simulator-logs:<udid>"`; `TabsManager.openOrFocusSimulatorLogs(worktreeId:udid:deviceName:) -> Tab`; `AppState.openSimulatorLogs(worktreeID:device:)`; `SimulatorLogStream`.

No automated test: view and process plumbing over Task 1's tested parsing.

- [ ] **Step 1: The tab kind.** In `Tab.swift`: the case `simulatorLogs(SimulatorLogsTabState)`, its `id`, `title`, icon `doc.text.magnifyingglass`, and `isRestorable` false (`if case .simulatorLogs = self { return false }`). The state:

```swift
struct SimulatorLogsTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeId: String
    let udid: String
    let deviceName: String

    var title: String { "Logs · \(deviceName)" }

    init(worktreeId: String, udid: String, deviceName: String) {
        self.worktreeId = worktreeId
        self.udid = udid
        self.deviceName = deviceName
        id = "simulator-logs:\(udid)"
    }
}
```

`TabsManager`, next to `openOrFocusRunReport`, the same shape:

```swift
    @discardableResult
    func openOrFocusSimulatorLogs(worktreeId: String, udid: String, deviceName: String) -> Tab {
        let state = SimulatorLogsTabState(worktreeId: worktreeId, udid: udid, deviceName: deviceName)
        if let existing = tabs(forWorktree: worktreeId).first(where: { $0.id == state.id }) {
            activate(worktreeId: worktreeId, tabId: state.id)
            return existing
        }
        let tab = Tab.simulatorLogs(state)
        append(tab, to: worktreeId)
        return tab
    }
```

`CenterPaneView`: `case .simulatorLogs(let s): SimulatorLogsTabView(state: state, tabState: s).id(s.id)`. `AppState+DevicesTab.swift`:

```swift
    func openSimulatorLogs(worktreeID: String, device: SimulatorDevice) {
        let tab = tabs.openOrFocusSimulatorLogs(worktreeId: worktreeID, udid: device.udid, deviceName: device.name)
        activateWorktreeCenterTab(worktreeId: worktreeID, tabId: tab.id)
    }
```

Fix any other exhaustive `switch` over `Tab` the compiler reports.

- [ ] **Step 2: `SimulatorLogStream`**

```swift
import AlasCore
import Foundation
import Observation

/// A running `log stream` on one simulator: its parsed lines, newest last.
@MainActor
@Observable
final class SimulatorLogStream {
    static let lineLimit = 5000

    private(set) var lines: [SimulatorLogLine] = []
    /// Lines dropped to keep `lineLimit`.
    private(set) var dropped = 0
    private(set) var isRunning = false
    /// Why the stream stopped on its own, if it did.
    private(set) var stopReason: String?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var generation = 0

    func start(udid: String, query: SimulatorLogQuery) {
        stop()
        generation += 1
        let current = generation
        stopReason = nil
        var args = ["simctl", "spawn", udid, "log", "stream", "--style", "ndjson"] + query.streamArguments
        if let predicate = query.predicate { args += ["--predicate", predicate] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = args
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let reader = LineReader()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let parsed = reader.lines(from: handle.availableData).compactMap(SimulatorLogLine.parse)
            guard !parsed.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.append(parsed)
            }
        }
        process.terminationHandler = { [weak self] finished in
            output.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.isRunning = false
                self.process = nil
                self.stopReason = "Logging stopped (simctl exited with status \(finished.terminationStatus))."
            }
        }
        do {
            try process.run()
            self.process = process
            isRunning = true
        } catch {
            stopReason = error.localizedDescription
        }
    }

    func stop() {
        generation += 1
        if let process, process.isRunning { process.terminate() }
        process = nil
        isRunning = false
    }

    func clear() {
        lines.removeAll()
        dropped = 0
    }

    private func append(_ new: [SimulatorLogLine]) {
        lines.append(contentsOf: new)
        let excess = lines.count - Self.lineLimit
        if excess > 0 {
            lines.removeFirst(excess)
            dropped += excess
        }
    }
}

/// Splits a byte stream into lines across reads.
private final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func lines(from chunk: Data) -> [Data] {
        lock.withLock {
            pending.append(chunk)
            var lines: [Data] = []
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(pending[pending.startIndex..<newline])
                pending.removeSubrange(pending.startIndex...newline)
            }
            return lines
        }
    }
}
```

- [ ] **Step 3: `SimulatorLogsTabView`**

```swift
import AlasCore
import AppKit
import SwiftUI

/// A simulator's logs in a center tab: the foreground app (or a chosen one,
/// or all processes), a level, Apple subsystems on or off, a search, and a
/// banner for each crash report written while it is open.
struct SimulatorLogsTabView: View {
    let state: AppState
    let tabState: SimulatorLogsTabState
    @Environment(\.theme) private var theme

    enum Source: Hashable {
        case foreground
        case app(String)
        case all
    }

    @State private var stream = SimulatorLogStream()
    @State private var source = Source.foreground
    @State private var level = SimulatorLogLevel.default
    @State private var includeApple = false
    @State private var search = ""
    /// While paused, how many lines the view shows.
    @State private var pausedAt: Int?
    @State private var apps: [SimulatorApp] = []
    @State private var executables: [String: String] = [:]
    /// The executable the stream follows now; nil for all processes.
    @State private var following: String?
    @State private var noAppInFront = false
    @State private var crashes: [SimulatorCrashReport] = []
    @State private var openedAt = Date()
    @State private var atBottom = true
    /// Reports the user dismissed, so polling doesn't bring them back.
    @State private var dismissed: Set<String> = []

    private var udid: String { tabState.udid }

    private var visible: ArraySlice<SimulatorLogLine> {
        let shown = pausedAt.map { stream.lines.prefix($0) } ?? stream.lines[...]
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? shown : shown.filter { $0.matches(query) }[...]
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ForEach(crashes, id: \.report) { crashBanner($0) }
            if let reason = stream.stopReason { stoppedBanner(reason) }
            if noAppInFront && source == .foreground {
                note("No app in front. Open one on the simulator, or pick an app.")
            }
            if stream.dropped > 0 {
                note("\(stream.dropped) older lines dropped.")
            }
            lineList
        }
        .task { await load() }
        .task(id: source) { await followForeground() }
        .task { await watchCrashes() }
        .onChange(of: level) { restart() }
        .onChange(of: includeApple) { restart() }
        .onDisappear { stream.stop() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("App", selection: $source) {
                Text("Foreground App").tag(Source.foreground)
                ForEach(apps) { Text($0.name).tag(Source.app($0.bundleID)) }
                Text("All Processes").tag(Source.all)
            }
            .fixedSize()
            Picker("Level", selection: $level) {
                Text("Default and Above").tag(SimulatorLogLevel.default)
                Text("Include Info").tag(SimulatorLogLevel.info)
                Text("Include Debug").tag(SimulatorLogLevel.debug)
                Text("Errors and Faults").tag(SimulatorLogLevel.error)
            }
            .fixedSize()
            Toggle("Apple subsystems", isOn: $includeApple)
                .toggleStyle(.checkbox)
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, maxWidth: 220)
            Spacer()
            ToolbarBtn(icon: pausedAt == nil ? "pause" : "play", tooltip: pausedAt == nil ? "Pause" : "Resume") {
                pausedAt = pausedAt == nil ? stream.lines.count : nil
            }
            ToolbarBtn(icon: "trash", tooltip: "Clear") {
                stream.clear()
                pausedAt = nil
            }
            ToolbarBtn(icon: "doc.on.doc", tooltip: "Copy visible lines", action: copyVisible)
        }
        .controlSize(.small)
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(theme.color("bg-2"))
    }

    private var lineList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { index, line in
                        row(line).id(index)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(8)
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    AlasButton(title: "Jump to Latest", icon: "arrow.down", compact: true) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .padding(12)
                }
            }
            .onChange(of: stream.lines.count) {
                if atBottom, pausedAt == nil { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
    }

    private func row(_ line: SimulatorLogLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.time).foregroundStyle(theme.color("fg-faint"))
            Text(line.level.prefix(1).uppercased())
                .frame(width: 10)
                .foregroundStyle(theme.color(levelTone(line.level)))
            Text("\(line.process)[\(line.pid)]").foregroundStyle(theme.color("fg-dim"))
            if let subsystem = line.subsystem {
                Text(line.category.map { "\(subsystem):\($0)" } ?? subsystem)
                    .foregroundStyle(theme.color("fg-faint"))
                    .lineLimit(1)
            }
            Text(line.message)
                .foregroundStyle(theme.color(["info", "debug"].contains(line.level) ? "fg-dim" : "fg"))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func levelTone(_ level: String) -> String {
        switch level {
        case "error", "fault": "del"
        case "info", "debug": "fg-faint"
        default: "fg-dim"
        }
    }

    private func crashBanner(_ crash: SimulatorCrashReport) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(theme.color("del"))
            Text("\(crash.appName) crashed: \(crash.exception)\(crash.frames.first.map { " in \($0)" } ?? "")")
                .lineLimit(2)
            Spacer()
            AlasButton(title: "Open Report", compact: true) {
                NSWorkspace.shared.open(URL(fileURLWithPath: crash.report))
            }
            AlasButton(title: "Dismiss", style: .subtle, compact: true) {
                crashes.removeAll { $0.report == crash.report }
                dismissed.insert(crash.report)
            }
        }
        .font(.system(size: 11.5))
        .padding(8)
        .background(theme.color("del").opacity(0.12))
    }

    private func stoppedBanner(_ reason: String) -> some View {
        HStack {
            Text(reason).foregroundStyle(theme.color("fg-dim"))
            Spacer()
            AlasButton(title: "Restart", compact: true) { restart() }
        }
        .font(.system(size: 11.5))
        .padding(8)
        .background(theme.color("bg-3"))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(theme.color("fg-faint"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }

    private func copyVisible() {
        let text = visible.map { line in
            [line.time, line.level, "\(line.process)[\(line.pid)]", line.subsystem ?? "", line.message].joined(separator: " ")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Following

    private func load() async {
        apps = (try? await SimulatorControl.userApps(udid: udid)) ?? []
        executables = (try? await SimulatorControl.appExecutables(udid: udid)) ?? [:]
    }

    /// Starts the stream for the chosen source; for the foreground app, keeps
    /// following it every 2 s.
    private func followForeground() async {
        switch source {
        case .all:
            following = nil
            restart()
        case .app(let bundleID):
            following = await executable(for: bundleID)
            restart()
        case .foreground:
            following = ""
            while !Task.isCancelled {
                let front = await state.simulatorStreams.frontmostApp(udid: udid)
                noAppInFront = front == nil
                if let front, let executable = await executable(for: front), executable != following {
                    following = executable
                    restart()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func executable(for bundleID: String) async -> String? {
        if let known = executables[bundleID] { return known }
        executables = (try? await SimulatorControl.appExecutables(udid: udid)) ?? executables
        return executables[bundleID]
    }

    private func restart() {
        // The foreground source waits until it knows the app.
        if source == .foreground, following?.isEmpty != false { return }
        pausedAt = nil
        stream.start(udid: udid, query: SimulatorLogQuery(executable: following, level: level, includeApple: includeApple))
    }

    private func watchCrashes() async {
        while !Task.isCancelled {
            let bundleID: String? = switch source {
            case .all: nil
            case .app(let id): id
            case .foreground: executables.first { $0.value == following }?.key
            }
            let found = SimulatorControl.crashReports(udid: udid, bundleID: bundleID, since: openedAt)
            for report in found where !dismissed.contains(report.report) && !crashes.contains(where: { $0.report == report.report }) {
                crashes.append(report)
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }
}
```

- [ ] **Step 4: The toolbar button.** `DevicesActions` gets `let onOpenLogs: () -> Void` and, before the settings button:

```swift
            ToolbarBtn(icon: "doc.text.magnifyingglass", tooltip: "Logs", action: onOpenLogs)
                .disabled(!booted)
```

`RightPaneView.devicesActions` passes `onOpenLogs: { state.openSimulatorLogs(worktreeID: worktree.id, device: device) }`.

- [ ] **Step 5:** `xcodegen` (commit only the new files' project lines), build, then run `RightPaneTabTests` as a smoke check that tabs still decode. Commit `feat(devices): show a simulator's logs and crashes in a tab`.

---

### Task 5: Docs and checking it end to end

- [ ] **Step 1: Through the real stack.** A throwaway app-host test (deleted after) on the booted simulator:
  - launch `com.example.crash` from `/tmp/alas-hello`;
  - `SimulatorStreamClient().frontmostApp` while Hello is in front, then on the home screen;
  - a `DeviceAgentControl` with `LiveSimulatorLogs` runs `.logs` for `com.example.crash` with `since_seconds: 120`;
  - expect the `Fatal error` line, and after about 40 s the crash in `crashes`.

  Print the responses.
- [ ] **Step 2: Docs.**
  - `docs/devices.md`:
    - a "Logs" subsection under Simulators: the button, the app picker, the filters, the crash banner;
    - `device_logs` in the agent table.
  - Design doc: tick "Device logs".
- [ ] **Step 3: Commit** `docs(devices): describe simulator logs`.
- [ ] **Step 4: Manual pass (the user):**
  1. Open Logs, launch an app, and watch its lines.
  2. Switch the level and the Apple subsystems, then search.
  3. Launch `/tmp/alas-hello/Crash.app` and watch the crash banner arrive.
  4. Ask an agent why the app crashed.
