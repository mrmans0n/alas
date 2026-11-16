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
