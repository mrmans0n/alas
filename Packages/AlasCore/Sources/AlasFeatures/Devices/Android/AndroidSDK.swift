import Foundation

/// Where the user's Android SDK tools are. Alas never installs them.
public struct AndroidSDK: Equatable, Sendable {
    /// The SDK directory; nil when only `adb` on the PATH was found.
    public let root: String?
    public let adb: String
    public let emulator: String?

    public init(root: String?, adb: String, emulator: String?) {
        self.root = root
        self.adb = adb
        self.emulator = emulator
    }

    /// `$ANDROID_HOME`, then `$ANDROID_SDK_ROOT`, then `~/Library/Android/sdk`,
    /// the first holding `platform-tools/adb`; else `adb` and `emulator` on the PATH.
    public static func locate(environment: [String: String], home: String, isExecutable: (String) -> Bool) -> AndroidSDK? {
        let roots = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"], home + "/Library/Android/sdk"]
            .compactMap { $0 }.filter { !$0.isEmpty }
        for root in roots where isExecutable(root + "/platform-tools/adb") {
            let emulator = root + "/emulator/emulator"
            return AndroidSDK(root: root, adb: root + "/platform-tools/adb", emulator: isExecutable(emulator) ? emulator : nil)
        }
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        guard let adb = path.map({ $0 + "/adb" }).first(where: isExecutable) else { return nil }
        return AndroidSDK(root: nil, adb: adb, emulator: path.map { $0 + "/emulator" }.first(where: isExecutable))
    }

    /// The live process's SDK.
    public static func locate() -> AndroidSDK? {
        locate(
            environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory(),
            isExecutable: FileManager.default.isExecutableFile(atPath:)
        )
    }

    /// The highest build-tools version, compared number by number.
    public static func newestBuildTools(_ versions: [String]) -> String? {
        versions.max { lhs, rhs in
            let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
            let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
            return l.lexicographicallyPrecedes(r)
        }
    }

    /// `aapt2` from the newest build-tools, when the SDK has any.
    public var aapt2: String? {
        guard let root else { return nil }
        let dir = root + "/build-tools"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        guard let newest = Self.newestBuildTools(versions) else { return nil }
        let tool = "\(dir)/\(newest)/aapt2"
        return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil
    }
}
