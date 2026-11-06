import Foundation

/// Why a prompt was stopped before it left Alas. It reaches both send sites as
/// an ordinary failure, and nothing about it says the agent saw the prompt.
public enum ACPPromptRefusal: LocalizedError, Equatable, Sendable {
    case pdfNotSupportedByAgent(name: String)
    case pdfFromAnotherWorktree(name: String)
    case pdfMissing(name: String)
    case pdfInvalid(name: String)
    case pdfsTooLarge(name: String)
    case tooManyPDFs(count: Int)
    case promptTooLarge(encodedBytes: Int)
    case forkContextTooLarge(encodedBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .pdfNotSupportedByAgent(let name):
            "Couldn't send \(name): this agent can't read attached PDFs. Remove it and send again."
        case .pdfFromAnotherWorktree(let name):
            "Couldn't send \(name): it was attached in another worktree. Remove it, attach it here, and send."
        case .pdfMissing(let name):
            "Couldn't send \(name): the attached file is gone. Remove it, attach it again, and send."
        case .pdfInvalid(let name):
            "Couldn't send \(name): the attached file is no longer a PDF. Remove it, attach it again, and send."
        case .pdfsTooLarge(let name):
            "Couldn't send \(name): the PDFs in one message can total \(ACPAttachmentStaging.maxPDFBytesPerMessage / Self.mebibyte) MiB at most. Remove some and send again."
        case .tooManyPDFs(let count):
            "Couldn't send \(count) PDFs: one message can hold \(ACPAttachmentStaging.maxPDFsPerMessage) at most. Remove some and send again."
        case .promptTooLarge(let encodedBytes):
            "This message is too large to send (\(Self.mebibytes(encodedBytes)) MiB encoded, \(Self.mebibytes(ACPPromptSizeGuard.maxEncodedBytes)) MiB at most). Remove attachments or shorten it, then send again."
        case .forkContextTooLarge(let encodedBytes):
            "This fork's inherited conversation is too large to send to the agent (\(Self.mebibytes(encodedBytes)) MiB encoded, \(Self.mebibytes(ACPPromptSizeGuard.maxEncodedBytes)) MiB at most), so no message can go out in this session. Start a new session instead."
        }
    }
}

extension ACPPromptRefusal {
    fileprivate static let mebibyte = 1024 * 1024

    /// Rounded up, so one byte over the limit doesn't read as being at it.
    fileprivate static func mebibytes(_ bytes: Int) -> Int {
        (bytes + mebibyte - 1) / mebibyte
    }
}

/// An adapter exits without answering when a JSON-RPC line passes 32 MiB, so an
/// oversized prompt is refused here, for every adapter, leaving room for the envelope.
public enum ACPPromptSizeGuard {
    public static let maxEncodedBytes = 31 * 1024 * 1024

    /// `forkContext` is the inherited conversation among `blocks`, if any. When
    /// it alone is over the limit, nothing the user removes can make this fit.
    public static func check(
        _ blocks: [ACPContentBlock], forkContext: String? = nil, limit: Int = maxEncodedBytes
    ) throws(ACPPromptRefusal) {
        let size = encodedSize(of: blocks)
        guard size > limit else { return }
        if let forkContext {
            let contextSize = encodedSize(of: [.text(forkContext)])
            if contextSize > limit { throw ACPPromptRefusal.forkContextTooLarge(encodedBytes: contextSize) }
        }
        throw ACPPromptRefusal.promptTooLarge(encodedBytes: size)
    }

    /// The bytes `JSONEncoder` writes for `blocks`. Payloads are measured instead
    /// of encoded, so a large prompt isn't encoded twice just to be weighed.
    public static func encodedSize(of blocks: [ACPContentBlock]) -> Int {
        let separators = max(blocks.count - 1, 0)
        return blocks.reduce(2 + separators) { total, block in
            let (payload, shell) = splitPayload(of: block)
            let shellSize = (try? JSONEncoder().encode(shell).count) ?? 0
            return total + shellSize + escapedLength(of: payload)
        }
    }

    private static func splitPayload(of block: ACPContentBlock) -> (payload: String, shell: ACPContentBlock) {
        switch block {
        case .text(let text):
            (text, .text(""))
        case .image(let data?, let uri, let mime):
            (data, .image(data: "", uri: uri, mimeType: mime))
        case .resource(let uri, let mime, let text):
            (text, .resource(uri: uri, mimeType: mime, text: ""))
        case .blobResource(let uri, let mime, let blob):
            (blob, .blobResource(uri: uri, mimeType: mime, blob: ""))
        case .image, .resourceLink:
            ("", block)
        }
    }

    /// `JSONEncoder` escapes quotes, backslashes, slashes (about 1 in 64 base64
    /// characters) and control characters, and writes everything else as raw UTF-8.
    private static func escapedLength(of string: String) -> Int {
        var string = string
        return string.withUTF8 { bytes in
            var length = bytes.count
            for byte in bytes where byte < 0x20 || byte == 0x22 || byte == 0x2F || byte == 0x5C {
                switch byte {
                case 0x22, 0x5C, 0x2F, 0x08, 0x09, 0x0A, 0x0C, 0x0D: length += 1
                default: length += 5
                }
            }
            return length
        }
    }
}
