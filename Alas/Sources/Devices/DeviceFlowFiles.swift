import AlasCore
import Foundation

/// The flows a worktree keeps in `.maestro/`: listing them, saving a
/// recording, and what a run answered, in words.
enum DeviceFlowFiles {
    static func folder(in worktree: URL) -> URL {
        worktree.appendingPathComponent(".maestro", isDirectory: true)
    }

    static func flows(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// "flow-20261119-1405".
    static func defaultName(at date: Date) -> String { "flow-\(stamp.string(from: date))" }

    /// Saves `flow` as `<name>.yaml` in `folder`: why it couldn't, or nil once saved.
    static func save(_ flow: DeviceFlow, name: String, in folder: URL) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 64,
              trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return "Use letters, digits, - and _."
        }
        let file = folder.appendingPathComponent("\(trimmed).yaml")
        guard !FileManager.default.fileExists(atPath: file.path) else { return "\(trimmed).yaml already exists." }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try flow.yaml.write(to: file, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func summary(_ response: AlasCLIResponse, name: String) -> String {
        switch response {
        case .text(let parts):
            guard let reply = (try? JSONSerialization.jsonObject(with: Data(parts.joined().utf8))) as? [String: Any] else {
                return parts.joined()
            }
            if reply["passed"] as? Bool == true { return "\(name) passed: \(reply["steps"] as? Int ?? 0) steps." }
            let step = reply["failed_step"] as? Int ?? 0
            let line = reply["line"] as? Int ?? 0
            return "\(name) failed at step \(step) (line \(line)): \(reply["reason"] as? String ?? "")"
        case .error(let message):
            return message
        default:
            return "\(name) ran."
        }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()
}
