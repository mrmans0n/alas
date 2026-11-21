import AlasRemoteKit
import SwiftUI
import UIKit

/// A chip in text: one attachment character drawn as an image of `ChipView`,
/// so a chip in the composer and one in a sent message look the same.
/// UITextView does not show attachment view providers, so the chip is a
/// picture; a reference chip redraws once its kind is looked up.
final class ChipAttachment: NSTextAttachment {
    let chip: ChipModel
    /// The composer segment it stands for; nil in a sent message.
    let draftChip: RemoteDraftChip?
    /// The sent mention it stands for, in a sent message.
    let sent: RemoteUserMention?
    /// Where a reference chip reads its kind, so it turns green or orange once looked up.
    let references: ReferenceCache?
    private var rendered: (key: RenderKey, image: UIImage)?

    private struct RenderKey: Equatable {
        var style: UIUserInterfaceStyle
        var scale: CGFloat
        var kind: CodeHostReferenceSummary.Kind?
    }

    init(chip: ChipModel, draftChip: RemoteDraftChip? = nil, sent: RemoteUserMention? = nil,
         references: ReferenceCache? = nil, font: UIFont) {
        self.chip = chip
        self.draftChip = draftChip
        self.sent = sent
        self.references = references
        super.init(data: nil, ofType: nil)
        let size = ChipStyle.size(of: chip)
        bounds = CGRect(x: 0, y: ChipStyle.baselineOffset(for: font), width: size.width, height: size.height)
    }

    required init?(coder: NSCoder) { fatalError("not coded") }

    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> UIImage? {
        render()
    }

    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> UIImage? {
        render()
    }

    /// TextKit draws on the main thread, with the text view's traits current;
    /// the image is kept until the appearance or a reference's kind changes.
    private func render() -> UIImage? {
        // TextKit only draws on the main thread, so the attachment never crosses it.
        nonisolated(unsafe) let attachment = self
        return MainActor.assumeIsolated {
            let traits = UITraitCollection.current
            var kind: CodeHostReferenceSummary.Kind?
            if case .reference(let reference, let host, let fallback) = attachment.chip {
                kind = attachment.references?.kind(of: reference, host: host) ?? fallback
            }
            let key = RenderKey(style: traits.userInterfaceStyle, scale: max(traits.displayScale, 1), kind: kind)
            if let rendered = attachment.rendered, rendered.key == key { return rendered.image }
            let renderer = ImageRenderer(content: ChipView(model: attachment.chip, references: attachment.references)
                .environment(\.colorScheme, key.style == .dark ? .dark : .light))
            renderer.scale = key.scale
            guard let image = renderer.uiImage else { return nil }
            attachment.rendered = (key, image)
            return image
        }
    }

    /// The chip as a one-character attributed string in `font`.
    static func string(_ chip: ChipModel, draftChip: RemoteDraftChip? = nil, sent: RemoteUserMention? = nil,
                       references: ReferenceCache? = nil, font: UIFont) -> NSAttributedString {
        let string = NSMutableAttributedString(attachment: ChipAttachment(
            chip: chip, draftChip: draftChip, sent: sent, references: references, font: font))
        string.addAttribute(.font, value: font, range: NSRange(location: 0, length: string.length))
        return string
    }
}

/// Finds the chip under a tap in a text view and opens its card in a popover
/// anchored on it. Taps anywhere else reach the text view as usual.
@MainActor
final class ChipTapHandler: NSObject, UIGestureRecognizerDelegate {
    private(set) weak var textView: UITextView?
    private let card: (ChipAttachment) -> AnyView?

    init(textView: UITextView, card: @escaping (ChipAttachment) -> AnyView?) {
        self.textView = textView
        self.card = card
        super.init()
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        textView.addGestureRecognizer(tap)
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        hit(at: recognizer.location(in: recognizer.view)) != nil
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let textView, let (attachment, rect) = hit(at: recognizer.location(in: textView)),
              let content = card(attachment) else { return }
        ChipPopover.present(content, from: textView, rect: rect)
    }

    /// The chip whose drawn rect holds `point`, and that rect.
    private func hit(at point: CGPoint) -> (ChipAttachment, CGRect)? {
        guard let textView, let storage = Optional(textView.textStorage), storage.length > 0,
              let position = textView.closestPosition(to: point) else { return nil }
        let offset = textView.offset(from: textView.beginningOfDocument, to: position)
        for index in [offset - 1, offset] where index >= 0 && index < storage.length {
            guard let attachment = storage.attribute(.attachment, at: index, effectiveRange: nil) as? ChipAttachment,
                  let start = textView.position(from: textView.beginningOfDocument, offset: index),
                  let end = textView.position(from: start, offset: 1),
                  let range = textView.textRange(from: start, to: end) else { continue }
            let rect = textView.firstRect(for: range)
            if rect.insetBy(dx: -2, dy: -2).contains(point) { return (attachment, rect) }
        }
        return nil
    }
}

/// Presents SwiftUI content as a popover that stays a popover on iPhone.
@MainActor
enum ChipPopover {
    static func present(_ content: AnyView, from sourceView: UIView, rect: CGRect) {
        guard let presenter = presenter(for: sourceView) else { return }
        let controller = UIHostingController(rootView: content)
        controller.modalPresentationStyle = .popover
        let fitting = controller.sizeThatFits(in: CGSize(width: 340, height: 560))
        controller.preferredContentSize = CGSize(width: min(340, fitting.width), height: min(560, fitting.height))
        if let popover = controller.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = rect
            popover.permittedArrowDirections = [.up, .down]
            popover.delegate = KeepPopover.shared
        }
        presenter.present(controller, animated: true)
    }

    private static func presenter(for view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let next = responder?.next, !(next is UIViewController) { responder = next }
        var controller = responder?.next as? UIViewController ?? view.window?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
}

@MainActor
private final class KeepPopover: NSObject, UIPopoverPresentationControllerDelegate {
    static let shared = KeepPopover()

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }
}
