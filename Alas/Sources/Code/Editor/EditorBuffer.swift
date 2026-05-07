import AppKit
import Foundation
import Observation

/// Per-tab editor buffer. Owns the live `NSTextStorage` displayed by
/// `CodeTextView`, plus the original-on-disk snapshot used for dirty
/// detection, save normalization, and conflict resolution.
///
/// Buffers are stored in `TabsManager.buffers` keyed by `TabID` so they
/// outlive the SwiftUI view (which can be torn down and rebuilt). All
/// state mutations happen on the main actor; storage delegate callbacks,
/// LSP responses, and file-watch events are routed through `MainActor`
/// before touching `self`.
@Observable
@MainActor
final class EditorBuffer {
    let worktreeRoot: URL
    let relativePath: String

    /// The live AppKit text storage displayed by the text view. The
    /// reference is stable for the lifetime of the buffer; tearing down
    /// the view detaches it without releasing it.
    let storage: NSTextStorage

    private(set) var originalText: String = ""
    private(set) var originalMtime: Date = .distantPast
    private(set) var permissions: mode_t = 0o644
    private(set) var lineEnding: LineEnding = .lf
    private(set) var readOnly: Bool = false

    /// `true` while the in-memory text differs from the bytes last read
    /// from / written to disk. Computed from `storage.string` against
    /// `originalText` (cheap for files under ~1 MB).
    var dirty: Bool {
        guard !readOnly else { return false }
        return storage.string != originalText
    }

    init(worktreeRoot: URL, relativePath: String) {
        self.worktreeRoot = worktreeRoot
        self.relativePath = relativePath
        self.storage = NSTextStorage()
        loadFromDisk()
    }

    private func loadFromDisk() {
        let url = worktreeRoot.appendingPathComponent(relativePath)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            storage.setAttributedString(NSAttributedString(string: "(unable to read file)"))
            readOnly = true
            return
        }
        let detected = LineEnding.detect(in: raw)
        let canonical = LineEnding.lf.normalize(raw)
        storage.setAttributedString(NSAttributedString(string: canonical))
        originalText = canonical
        lineEnding = detected
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            originalMtime = (attrs[.modificationDate] as? Date) ?? .distantPast
            if let nsPerms = attrs[.posixPermissions] as? NSNumber {
                permissions = mode_t(nsPerms.uint16Value)
            }
        }
        readOnly = false
    }
}
