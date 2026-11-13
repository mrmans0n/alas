import Foundation

extension RemoteWireMessage {
    /// A user row's wire text: the prompt, then one labelled line per image
    /// and per mention. Viewers rebuild it to recognise their own prompt in
    /// the transcript.
    public static func userRowText(
        text: String, attachmentNames: [String?], resourceNames: [String?] = []
    ) -> String {
        var parts: [String] = []
        if !text.isEmpty { parts.append(text) }
        parts.append(contentsOf: attachmentNames.map { "🖼 \($0 ?? "Image")" })
        parts.append(contentsOf: resourceNames.map { "📎 \($0 ?? "Resource")" })
        return parts.joined(separator: "\n\n")
    }

    /// `text` from `userRowText` without the labels of the images a viewer
    /// shows itself. Labels are matched from the end, so a prompt that reads
    /// like a label stays.
    public static func userRowText(_ text: String, removingImageNames names: [String?]) -> String {
        var parts = text.components(separatedBy: "\n\n")
        var next = parts.count - 1
        for name in names.reversed() {
            let label = "🖼 \(name ?? "Image")"
            while next >= 0 && parts[next] != label { next -= 1 }
            guard next >= 0 else { break }
            parts.remove(at: next)
            next -= 1
        }
        return parts.joined(separator: "\n\n")
    }
}
