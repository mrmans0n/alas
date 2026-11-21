import AlasHighlight
import AlasRemoteKit
import UIKit

/// The review's code font: monospaced footnote, following Dynamic Type.
enum ReviewMetrics {
    static var codeFont: UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
    }
}

/// A file's pinned header: fold chevron, path, counts and the Viewed checkbox.
final class FileHeaderView: UICollectionReusableView {
    private let chevron = UIButton(type: .system)
    private let path = UILabel()
    private let counts = UILabel()
    private let viewed = UIButton(type: .system)
    private var onFold: (() -> Void)?
    private var onViewed: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        path.font = .preferredFont(forTextStyle: .subheadline)
        path.adjustsFontForContentSizeCategory = true
        path.lineBreakMode = .byTruncatingMiddle
        counts.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedDigitSystemFont(ofSize: 12, weight: .regular))
        counts.setContentCompressionResistancePriority(.required, for: .horizontal)
        counts.setContentHuggingPriority(.required, for: .horizontal)
        chevron.addAction(UIAction { [weak self] _ in self?.onFold?() }, for: .touchUpInside)
        viewed.addAction(UIAction { [weak self] _ in self?.onViewed?() }, for: .touchUpInside)
        for button in [chevron, viewed] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        let stack = UIStackView(arrangedSubviews: [chevron, path, counts, viewed])
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .header
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ entry: ReviewEntry, folded: Bool, isViewed: Bool, onFold: @escaping () -> Void, onViewed: @escaping () -> Void) {
        self.onFold = onFold
        self.onViewed = onViewed
        let config = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
        chevron.setImage(UIImage(systemName: folded ? "chevron.right" : "chevron.down", withConfiguration: config), for: .normal)
        chevron.tintColor = .secondaryLabel
        viewed.setImage(UIImage(systemName: isViewed ? "checkmark.square.fill" : "square", withConfiguration: config), for: .normal)
        viewed.tintColor = isViewed ? .tintColor : .secondaryLabel
        path.text = entry.renameFrom.map { "\($0) → \(entry.id.path)" } ?? entry.id.path
        let text = NSMutableAttributedString(string: "+\(entry.add)", attributes: [.foregroundColor: UIColor.systemGreen])
        text.append(NSAttributedString(string: " \u{2212}\(entry.del)", attributes: [.foregroundColor: UIColor.systemRed]))
        counts.attributedText = text
        counts.isHidden = entry.add + entry.del == 0
        accessibilityLabel = "\(entry.id.path), \(entry.add) added, \(entry.del) removed" + (isViewed ? ", viewed" : "")
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: folded ? "Unfold" : "Fold") { _ in
                onFold()
                return true
            },
            UIAccessibilityCustomAction(name: isViewed ? "Mark as Not Viewed" : "Mark as Viewed") { _ in
                onViewed()
                return true
            },
        ]
    }
}

/// A hunk's `@@` header, with its stage, unstage and discard menu.
final class HunkHeaderCell: UICollectionViewCell {
    private let label = UILabel()
    private let menuButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .tertiarySystemFill
        label.font = ReviewMetrics.codeFont
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingTail
        menuButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.accessibilityLabel = "Hunk actions"
        menuButton.setContentHuggingPriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [menuButton, label])
        stack.spacing = 4
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            // A finger-sized target around the small glyph.
            menuButton.widthAnchor.constraint(equalToConstant: 44),
            menuButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// `menu` is nil when the hunk offers no actions.
    func configure(header: String, menu: UIMenu?) {
        label.text = header
        menuButton.menu = menu
        menuButton.isHidden = menu == nil
    }
}

/// One diff line: old and new numbers and the sign in a fixed gutter, then the code.
final class LineCell: UICollectionViewCell {
    private let gutter = UILabel()
    /// Clips the code when it pans sideways under scroll mode.
    let codeClip = UIView()
    private let code = UILabel()
    private var wrapTrailing: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        gutter.setContentHuggingPriority(.required, for: .horizontal)
        gutter.setContentCompressionResistancePriority(.required, for: .horizontal)
        codeClip.clipsToBounds = true
        code.numberOfLines = 0
        for view in [gutter, codeClip] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        code.translatesAutoresizingMaskIntoConstraints = false
        codeClip.addSubview(code)
        wrapTrailing = code.trailingAnchor.constraint(equalTo: codeClip.trailingAnchor)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            gutter.firstBaselineAnchor.constraint(equalTo: code.firstBaselineAnchor),
            codeClip.leadingAnchor.constraint(equalTo: gutter.trailingAnchor, constant: 6),
            codeClip.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            codeClip.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 1),
            codeClip.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -1),
            code.leadingAnchor.constraint(equalTo: codeClip.leadingAnchor),
            code.topAnchor.constraint(equalTo: codeClip.topAnchor),
            code.bottomAnchor.constraint(equalTo: codeClip.bottomAnchor),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Moves the code left by `offset` points under scroll mode; the gutter stays.
    var codeOffset: CGFloat = 0 {
        didSet { code.transform = CGAffineTransform(translationX: -codeOffset, y: 0) }
    }

    /// `digits` pads both numbers, so every line of a file has the same gutter.
    func configure(_ line: RemoteDiffLine, spans: [HighlightSpan], digits: Int, wraps: Bool, offset: CGFloat, tokens: ThemeTokens) {
        let font = ReviewMetrics.codeFont
        let tint: UIColor? = line.kind == "add" ? .systemGreen : line.kind == "delete" ? .systemRed : nil
        func pad(_ n: Int?) -> String {
            let s = n.map(String.init) ?? ""
            return String(repeating: " ", count: max(0, digits - s.count)) + s
        }
        let gutterText = NSMutableAttributedString(string: pad(line.oldNumber) + " " + pad(line.newNumber) + " ",
                                                   attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
        let sign = line.kind == "add" ? "+" : line.kind == "delete" ? "\u{2212}" : " "
        gutterText.append(NSAttributedString(string: sign, attributes: [.font: font, .foregroundColor: tint ?? .secondaryLabel]))
        gutter.attributedText = gutterText
        let text = tokens.nsAttributed(line.text, spans: spans, changedLine: tint != nil, font: font)
        if line.noTrailingNewline {
            text.append(NSAttributedString(string: "\n\\ No newline at end of file",
                                           attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]))
        }
        code.attributedText = text
        // Unbounded in width under scroll mode, so each line stays one line and pans instead.
        code.lineBreakMode = wraps ? .byCharWrapping : .byClipping
        wrapTrailing.isActive = wraps
        codeOffset = wraps ? 0 : offset
        contentView.backgroundColor = tint?.withAlphaComponent(0.12)
        let state = line.kind == "add" ? "added" : line.kind == "delete" ? "removed" : "unchanged"
        let number = (line.kind == "delete" ? line.oldNumber : line.newNumber) ?? line.oldNumber ?? 0
        accessibilityLabel = "line \(number), \(state), \(line.text)"
    }
}

/// A note in place of a diff: loading, binary, truncated or failed.
final class NoteCell: UICollectionViewCell {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String) {
        label.text = text
    }
}
