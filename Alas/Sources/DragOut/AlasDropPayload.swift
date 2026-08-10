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
        try? JSONDecoder().decode(Self.self, from: data)
    }

    var agentText: String {
        switch self {
        case .file(let relativePath, _): relativePath
        case .commitSHA(let sha): sha
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
