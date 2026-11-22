import SwiftUI

/// A person's initials on a color picked from their name, under their picture when there is one: the initials
/// show while it loads and whenever it can't.
struct AuthorAvatar: View {
    let name: String
    var initials: String? = nil
    var image: URL? = nil
    var size: CGFloat = 16
    @Environment(\.designScale) private var scale

    var body: some View {
        ZStack {
            Circle().fill(Self.color(for: name))
            Text(initials ?? CommitInfo.initials(for: name))
                .font(scale.caption.font(weight: .bold))
                .minimumScaleFactor(0.5)
                .foregroundColor(.white)
            if let image {
                AsyncImage(url: image) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    /// Deterministic hash → one of a small preset palette.
    static func color(for name: String) -> Color {
        let palette = ["5fb7c4", "c89d6f", "9789c7", "7aa86a", "cf649a", "e0a04a", "5fa7d6"]
        var hash: UInt64 = 5381
        for byte in name.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return Color(hex: palette[Int(hash % UInt64(palette.count))])
    }
}
