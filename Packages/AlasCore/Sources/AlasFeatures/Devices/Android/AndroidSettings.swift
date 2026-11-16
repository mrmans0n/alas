import Foundation

/// `font_scale` for each text size, one to one, so a value reads back as its size.
public enum AndroidFontScale {
    private static let table: [(SimulatorTextSize, Double)] = [
        (.extraSmall, 0.85), (.small, 0.9), (.medium, 0.95), (.large, 1.0), (.extraLarge, 1.1),
        (.extraExtraLarge, 1.2), (.extraExtraExtraLarge, 1.3), (.accessibilityMedium, 1.5),
        (.accessibilityLarge, 1.7), (.accessibilityExtraLarge, 1.8), (.accessibilityExtraExtraLarge, 1.9),
        (.accessibilityExtraExtraExtraLarge, 2.0),
    ]

    public static func scale(for size: SimulatorTextSize) -> Double {
        table.first { $0.0 == size }?.1 ?? 1.0
    }

    /// From `settings get system font_scale`; a value off the table is unknown.
    public static func textSize(for output: String) -> SimulatorReadBack<SimulatorTextSize> {
        guard let scale = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)),
              let size = table.first(where: { abs($0.1 - scale) < 0.001 })?.0 else { return .unknown }
        return .value(size)
    }
}

/// iOS's privacy services as Android runtime permissions; nil where Android has none.
public enum AndroidPermissions {
    public static func permissions(for service: SimulatorPrivacyService) -> [String]? {
        let p = "android.permission."
        switch service {
        case .location: return [p + "ACCESS_FINE_LOCATION", p + "ACCESS_COARSE_LOCATION"]
        case .locationAlways:
            return [p + "ACCESS_FINE_LOCATION", p + "ACCESS_COARSE_LOCATION", p + "ACCESS_BACKGROUND_LOCATION"]
        case .contacts: return [p + "READ_CONTACTS", p + "WRITE_CONTACTS"]
        case .calendar: return [p + "READ_CALENDAR", p + "WRITE_CALENDAR"]
        case .photos: return [p + "READ_MEDIA_IMAGES"]
        case .mediaLibrary: return [p + "READ_MEDIA_AUDIO"]
        case .microphone: return [p + "RECORD_AUDIO"]
        case .motion: return [p + "ACTIVITY_RECOGNITION"]
        case .all:
            return SimulatorPrivacyService.allCases.filter { $0 != .all }.compactMap(permissions(for:)).flatMap { $0 }
        case .contactsLimited, .photosAdd, .reminders, .siri: return nil
        }
    }
}

public enum AndroidLogcat {
    /// `logcat -v threadtime` lines: "MM-DD HH:MM:SS.mmm  PID  TID L TAG: message".
    public static func parse(_ output: String, year: Int) -> [SimulatorLogLine] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6, let pid = Int(fields[2]), fields[4].count == 1 else { return nil }
            let rest = fields[5]
            guard let colon = rest.range(of: ": ") ?? rest.range(of: ":") else { return nil }
            return SimulatorLogLine(
                time: "\(year)-\(fields[0]) \(fields[1])", level: levelName(String(fields[4])),
                process: rest[..<colon.lowerBound].trimmingCharacters(in: .whitespaces), pid: pid,
                subsystem: nil, category: nil, message: String(rest[colon.upperBound...])
            )
        }
    }

    /// The logcat priority for a level: what `*:<letter>` keeps.
    /// A `logcat -T` time `seconds` ago by the device's own clock, as a quoted
    /// shell expression for `adb shell`: the device's time zone may not be the Mac's.
    public static func since(seconds: Int) -> String {
        "\"$(date -d @$(( $(date +%s) - \(max(0, seconds)) )) '+%m-%d %H:%M:%S.000')\""
    }

    public static func filter(_ level: SimulatorLogLevel) -> String {
        switch level {
        case .debug: "D"
        case .info: "I"
        case .default: "W"
        case .error: "E"
        }
    }

    static func levelName(_ letter: String) -> String {
        switch letter {
        case "V": "Verbose"
        case "D": "Debug"
        case "I": "Info"
        case "W": "Warning"
        case "E": "Error"
        case "F", "A": "Fault"
        default: letter
        }
    }

    /// The package of `dumpsys activity activities`' top resumed activity.
    public static func frontmostPackage(_ dumpsys: String) -> String? {
        guard let line = dumpsys.split(whereSeparator: \.isNewline).first(where: { $0.contains("topResumedActivity=") }),
              let record = line.split(separator: " ").first(where: { $0.contains("/") }) else { return nil }
        return record.split(separator: "/").first.map(String.init)
    }
}

/// A Java crash from `logcat -b crash`.
public struct AndroidCrash: Equatable, Sendable {
    public let time: String
    public let exception: String
    /// The stack's first frames, without "at".
    public let frames: [String]

    public init(time: String, exception: String, frames: [String]) {
        self.time = time
        self.exception = exception
        self.frames = frames
    }

    /// Shaped like an iOS crash report in device_logs' reply.
    public var json: [String: Any] {
        ["time": time, "exception": exception, "frames": frames, "report": ""]
    }
}

extension AndroidLogcat {
    /// AndroidRuntime's FATAL EXCEPTION blocks for `package`, with up to 10 frames each.
    public static func crashes(_ lines: [SimulatorLogLine], package: String) -> [AndroidCrash] {
        let runtime = lines.filter { $0.process == "AndroidRuntime" }
        var crashes: [AndroidCrash] = []
        var index = 0
        while index < runtime.count {
            defer { index += 1 }
            guard runtime[index].message.hasPrefix("FATAL EXCEPTION"), index + 2 < runtime.count,
                  runtime[index + 1].message.hasPrefix("Process: \(package),") else { continue }
            let exception = runtime[index + 2].message
            var frames: [String] = []
            var next = index + 3
            while next < runtime.count, frames.count < 10 {
                let text = runtime[next].message.trimmingCharacters(in: .whitespaces)
                guard text.hasPrefix("at ") else { break }
                frames.append(String(text.dropFirst(3)))
                next += 1
            }
            crashes.append(AndroidCrash(time: runtime[index].time, exception: exception, frames: frames))
        }
        return crashes
    }
}

/// Wi-Fi and mobile data, as Android reports them back.
public enum AndroidNetwork {
    /// From `cmd wifi status`, whose first line says "Wifi is enabled" or "Wifi is disabled".
    public static func wifi(_ status: String) -> SimulatorReadBack<Bool> {
        let first = status.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
        switch first {
        case "Wifi is enabled": return .value(true)
        case "Wifi is disabled": return .value(false)
        default: return .unknown
        }
    }

    /// From `settings get global mobile_data`.
    public static func data(_ setting: String) -> SimulatorReadBack<Bool> {
        switch setting.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": .value(true)
        case "0": .value(false)
        default: .unknown
        }
    }
}

public struct AndroidNetworkState: Equatable, Sendable {
    public var wifi: SimulatorReadBack<Bool>
    public var data: SimulatorReadBack<Bool>

    public init(wifi: SimulatorReadBack<Bool>, data: SimulatorReadBack<Bool>) {
        self.wifi = wifi
        self.data = data
    }

    /// What `device_set_network` returns.
    public var json: [String: Any] {
        ["wifi": wifi.jsonValue, "data": data.jsonValue]
    }
}

/// What following an app's logs does when its pid is looked up again.
public enum AndroidLogFollow: Equatable, Sendable {
    case keep
    /// The app started, or restarted under a new pid.
    case restart(pid: Int)
    /// The app isn't running.
    case waitForApp

    public static func next(running: Int?, found: Int?) -> AndroidLogFollow {
        guard let found else { return .waitForApp }
        return found == running ? .keep : .restart(pid: found)
    }
}

extension AndroidCrash {
    /// The crash's time on the device's clock, read in this Mac's time zone.
    public var date: Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.date(from: time)
    }

    /// As the Logs tab shows crash reports.
    public func report(bundleID: String) -> SimulatorCrashReport {
        SimulatorCrashReport(
            bundleID: bundleID, appName: bundleID, capturedAt: date ?? Date(), exception: exception, frames: frames,
            // Its time keeps two crashes at the same stack apart: the tab tells reports apart by this text.
            report: (["\(bundleID) crashed at \(time)", exception] + frames.map { "\tat " + $0 }).joined(separator: "\n")
        )
    }
}
