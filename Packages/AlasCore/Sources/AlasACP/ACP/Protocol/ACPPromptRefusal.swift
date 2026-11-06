import Foundation

/// Why a prompt was stopped before it left Alas. It reaches both send sites as
/// an ordinary failure, and nothing about it says the agent saw the prompt.
public enum ACPPromptRefusal: LocalizedError, Equatable, Sendable {
    case pdfNotSupportedByAgent(name: String)
    case pdfMissing(name: String)
    case pdfInvalid(name: String)
    case pdfsTooLarge(name: String)
    case tooManyPDFs(count: Int)
    case promptTooLarge(encodedBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .pdfNotSupportedByAgent(let name):
            "Couldn't send \(name): this agent can't read attached PDFs. Remove it and send again."
        case .pdfMissing(let name):
            "Couldn't send \(name): the attached file is gone. Remove it, attach it again, and send."
        case .pdfInvalid(let name):
            "Couldn't send \(name): the attached file is no longer a PDF. Remove it, attach it again, and send."
        case .pdfsTooLarge(let name):
            "Couldn't send \(name): the PDFs in one message can total 20 MB at most. Remove some and send again."
        case .tooManyPDFs(let count):
            "Couldn't send \(count) PDFs: one message can hold \(ACPAttachmentStaging.maxPDFsPerMessage) at most. Remove some and send again."
        case .promptTooLarge(let encodedBytes):
            "This message is too large to send (\(encodedBytes / (1024 * 1024)) MB encoded, 31 MB at most). Remove attachments or shorten it, then send again."
        }
    }
}

/// An adapter exits without answering when a JSON-RPC line passes 32 MiB, so an
/// oversized prompt is refused here, for every adapter, leaving room for the envelope.
public enum ACPPromptSizeGuard {
    public static let maxEncodedBytes = 31 * 1024 * 1024

    public static func check(_ blocks: [ACPContentBlock]) throws {
        let size = encodedSize(of: blocks)
        if size > maxEncodedBytes { throw ACPPromptRefusal.promptTooLarge(encodedBytes: size) }
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
            bytes.reduce(into: 0) { length, byte in
                switch byte {
                case 0x22, 0x5C, 0x2F, 0x08, 0x09, 0x0A, 0x0C, 0x0D: length += 2
                case 0..<0x20: length += 6
                default: length += 1
                }
            }
        }
    }
}
