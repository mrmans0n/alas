import AppKit
import Foundation
import UniformTypeIdentifiers

/// Structured text that Alas drag sources can hand to Alas-owned input views.
/// Public pasteboard flavors remain separate so internal targets never need to
/// infer whether an arbitrary string is a path or a commit SHA.
enum AlasDropPayload: Codable, Equatable, Sendable {
    case file(relativePath: String, absolutePath: String)
    case commitSHA(String)

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> AlasDropPayload? {
        guard let payload = try? JSONDecoder().decode(Self.self, from: data), payload.isValid else {
            return nil
        }
        return payload
    }

    var agentText: String {
        switch self {
        case .file(let relativePath, _): relativePath
        case .commitSHA(let sha): sha
        }
    }

    var terminalText: String {
        switch self {
        case .file(_, let absolutePath): POSIXShellArgument.escape(absolutePath)
        case .commitSHA(let sha): sha
        }
    }

    private var isValid: Bool {
        guard case .commitSHA(let sha) = self else { return true }
        return (sha.count == 40 || sha.count == 64)
            && sha.unicodeScalars.allSatisfy { scalar in
                (48 ... 57).contains(scalar.value)
                    || (65 ... 70).contains(scalar.value)
                    || (97 ... 102).contains(scalar.value)
            }
    }
}

enum POSIXShellArgument {
    static func escape(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        if value.unicodeScalars.allSatisfy(isSafe) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isSafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48 ... 57, 65 ... 90, 97 ... 122:
            return true
        default:
            return "_@%+=:,./-".unicodeScalars.contains(scalar)
        }
    }
}

extension NSPasteboard.PasteboardType {
    static let alasDropPayload = NSPasteboard.PasteboardType("io.nlopez.alas.drop-payload")
}

extension UTType {
    static let alasDropPayload = UTType(exportedAs: NSPasteboard.PasteboardType.alasDropPayload.rawValue)
}

/// All representations available when a drag lifts. `dropPayload` is private
/// to Alas; the optional URL/text values are standard flavors for other apps.
struct DragOutPreparedItem: Equatable, Sendable {
    let dropPayload: AlasDropPayload?
    let fileURL: URL?
    let publicText: String?

    var hasExternalRepresentation: Bool {
        fileURL != nil || publicText != nil
    }
}
