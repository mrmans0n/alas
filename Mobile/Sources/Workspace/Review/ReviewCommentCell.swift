import SwiftUI
import UIKit

/// A comment or thread under the lines it's on: who wrote it, where, its Markdown body and its replies.
/// Its actions live in the collection view's context menu.
final class ReviewCommentCell: UICollectionViewCell {
    struct Reply {
        let author: String
        let body: String
    }

    /// `badges`: its state and "Outdated", as they apply; `dimmed` for a closed comment.
    func configure(author: String, location: String, body: String, badges: [String], replies: [Reply], dimmed: Bool) {
        contentConfiguration = UIHostingConfiguration {
            Bubble(author: author, location: location, text: body, badges: badges, replies: replies, dimmed: dimmed)
        }
        .margins(.horizontal, 12)
        .margins(.vertical, 4)
    }

    private struct Bubble: View {
        let author: String
        let location: String
        let text: String
        let badges: [String]
        let replies: [Reply]
        let dimmed: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(author).font(.caption.weight(.semibold))
                    Text(location).font(.caption.monospaced())
                    Spacer(minLength: 8)
                    ForEach(badges, id: \.self) { badge in
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .foregroundStyle(.secondary)
                Text(Self.markdown(text)).font(.subheadline).foregroundStyle(dimmed ? .secondary : .primary)
                ForEach(Array(replies.enumerated()), id: \.offset) { _, reply in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reply.author).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(Self.markdown(reply.body)).font(.subheadline)
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)
        }

        private static func markdown(_ text: String) -> AttributedString {
            (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(text)
        }
    }
}
