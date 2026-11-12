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

struct SimulatorForegroundTests {
    private func foreground(_ messages: [String]) -> String? {
        var state = SimulatorForeground()
        for message in messages { state.apply(message: message) }
        return state.bundleID
    }

    @Test func theAppLastBroughtForwardIsInFront() {
        #expect(foreground([
            "[app<com.example.hello>:49932] Setting process visibility to: Foreground",
            "[app<com.apple.Preferences>:50810] Setting process visibility to: Unknown",
            "[app<com.apple.Preferences>:50852] Setting process visibility to: Foreground",
            "[app<com.example.hello>:49932] Setting process visibility to: Background",
        ]) == "com.apple.Preferences")
    }

    @Test func goingToTheBackgroundLeavesNoAppInFront() {
        #expect(foreground([
            "[app<com.example.hello>:49932] Setting process visibility to: Foreground",
            "[app<com.example.hello>:49932] Setting process visibility to: Background",
        ]) == nil)
    }

    @Test func aColdLaunchCountsOnceItsProcessStarts() {
        #expect(foreground(["[app<com.example.hello>:-1] Setting process visibility to: Foreground"]) == nil)
        #expect(foreground([
            "[app<com.example.hello>:-1] Setting process visibility to: Foreground",
            "[app<com.example.hello>:4021] Bootstrap success!",
        ]) == "com.example.hello")
    }

    @Test(arguments: ["com.apple.WidgetRenderer", "com.example.app.extension", "com.apple.springboard.InCallService"])
    func helpersAreNotApps(bundleID: String) {
        #expect(foreground([
            "[app<com.example.hello>:1] Setting process visibility to: Foreground",
            "[app<\(bundleID)>:2] Setting process visibility to: Foreground",
        ]) == "com.example.hello")
    }

    @Test func anAppWhoseNameContainsServiceIsStillAnApp() {
        #expect(SimulatorForeground.isUserFacing("com.example.CustomerService"))
    }
}
