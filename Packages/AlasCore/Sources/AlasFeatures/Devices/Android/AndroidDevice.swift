import Foundation

/// A device `adb` lists: an emulator or a connected phone.
public struct AndroidDevice: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case ready
        /// The phone hasn't allowed this Mac's USB debugging key yet.
        case unauthorized
        case offline
    }

    public let serial: String
    public let state: State
    /// `adb`'s `model:` field, underscores and all.
    public let model: String?
    /// The AVD a running emulator was started from.
    public var avdName: String?
    /// The Android version, such as "16", once read.
    public var release: String?

    public init(serial: String, state: State, model: String?, avdName: String? = nil, release: String? = nil) {
        self.serial = serial
        self.state = state
        self.model = model
        self.avdName = avdName
        self.release = release
    }

    public var isEmulator: Bool { serial.hasPrefix("emulator-") }

    /// The AVD's name, else the model, else the serial, with spaces for underscores.
    public var title: String {
        (avdName ?? model ?? serial).replacingOccurrences(of: "_", with: " ")
    }

    /// From `adb devices -l`.
    public static func parseList(_ output: String) -> [AndroidDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("*"), !line.hasPrefix("List of devices") else { return nil }
            let state: State = switch fields[1] {
            case "device": .ready
            case "unauthorized", "authorizing": .unauthorized
            default: .offline
            }
            let model = fields.dropFirst(2).first { $0.hasPrefix("model:") }.map { String($0.dropFirst("model:".count)) }
            return AndroidDevice(serial: fields[0], state: state, model: model)
        }
    }

    /// From `emulator -list-avds`, which may print log lines first.
    public static func parseAVDs(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            !line.isEmpty && line.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
        }
    }

    /// From `adb -s emulator-NNNN emu avd name`: the name, then "OK".
    public static func parseAVDName(_ output: String) -> String? {
        let first = output.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first, !first.isEmpty, first != "OK" else { return nil }
        return first
    }
}

/// The window manager's user rotation: 0 natural, 1 a quarter turn left, and so on.
public enum AndroidRotation {
    /// From `cmd window user-rotation`: "lock <n>", or "free" (taken as 0).
    public static func parse(_ output: String) -> Int {
        let words = output.split(whereSeparator: \.isWhitespace)
        guard words.count == 2, words[0] == "lock", let value = Int(words[1]), (0...3).contains(value) else { return 0 }
        return value
    }

    public static func turned(_ rotation: Int, left: Bool) -> Int {
        (rotation + (left ? 1 : 3)) % 4
    }
}

public enum AndroidAPK {
    /// From `aapt2 dump packagename <apk>`.
    public static func parsePackageName(_ output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let line, line.contains("."),
              line.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }) else { return nil }
        return line
    }
}
