import AppKit
import SwiftUI

private let popupMaxHeight: CGFloat = 260

struct CompletionPopupRow: Identifiable, Equatable {
    let id: UUID
    let label: String
    let detail: String?
    let kind: Int?
    let source: CompletionCandidateSource
}

struct CompletionPopup: View {
    let rows: [CompletionPopupRow]
    let selection: Int
    let documentation: MarkdownRenderResult?
    let theme: Theme
    let mermaidCancellation: MermaidRenderCancellation
    let onChoose: (Int) -> Void
    let onWillPresentMermaidViewer: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            rowView(row)
                                // Data-based id, not the row position: a
                                // positional id freezes LazyVStack rows against
                                // the completion list being re-queried as you type.
                                .id(row.id)
                                .background(index == selection ? Color.accentColor.opacity(0.24) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture { onChoose(index) }
                        }
                    }
                }
                .onAppear {
                    scrollSelection(selection, proxy: proxy)
                }
                .onChange(of: selection) { _, nextSelection in
                    scrollSelection(nextSelection, proxy: proxy)
                }
                .frame(width: 320, height: popupMaxHeight, alignment: .topLeading)
            }

            if let documentation, documentation.attributedString.length > 0 {
                Divider()

                CompletionDocumentationView(
                    result: documentation,
                    theme: theme,
                    mermaidCancellation: mermaidCancellation,
                    onWillPresentMermaidViewer: onWillPresentMermaidViewer
                )
                .frame(width: 320, height: popupMaxHeight, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func scrollSelection(_ selection: Int, proxy: ScrollViewProxy) {
        guard rows.indices.contains(selection) else { return }
        let id = rows[selection].id
        DispatchQueue.main.async {
            withAnimation(nil) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func rowView(_ row: CompletionPopupRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(kindLabel(row.kind, source: row.source))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let detail = row.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CompletionDocumentationView: NSViewRepresentable {
    let result: MarkdownRenderResult
    let theme: Theme
    let mermaidCancellation: MermaidRenderCancellation
    let onWillPresentMermaidViewer: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()
        textView.isEditable = false
        textView.drawsBackground = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.linkTextAttributes = linkAttributes(theme: theme)

        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        context.coordinator.textView = textView
        context.coordinator.apply(result: result, theme: theme, to: textView)
        scrollView.backgroundColor = NSColor(theme.color("bg-1"))
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.apply(result: result, theme: theme, to: textView)
        textView.linkTextAttributes = linkAttributes(theme: theme)
        nsView.backgroundColor = NSColor(theme.color("bg-1"))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onWillPresentMermaidViewer: onWillPresentMermaidViewer,
            mermaidCancellation: mermaidCancellation
        )
    }

    static func dismantleNSView(
        _ nsView: NSScrollView,
        coordinator: Coordinator
    ) {
        coordinator.cancel()
    }

    private func linkAttributes(theme: Theme) -> [NSAttributedString.Key: Any] {
        [
            .foregroundColor: NSColor(theme.color("accent")),
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let mermaidCoordinator: MermaidAttachmentCoordinator
        var appliedRevision: UUID?

        weak var textView: NSTextView? {
            didSet { textView?.delegate = self }
        }

        init(
            onWillPresentMermaidViewer: @escaping () -> Void,
            mermaidCancellation: MermaidRenderCancellation
        ) {
            self.mermaidCoordinator = MermaidAttachmentCoordinator(
                mode: .compact,
                onWillPresentViewer: onWillPresentMermaidViewer
            )
            super.init()
            mermaidCancellation.register { [weak self] in
                self?.cancelRenders()
            }
        }

        func apply(
            result: MarkdownRenderResult,
            theme: Theme,
            to textView: NSTextView
        ) {
            mermaidCoordinator.updateViewerTheme(theme)
            guard appliedRevision != result.revision else { return }

            mermaidCoordinator.cancelAll()
            textView.textStorage?.setAttributedString(result.attributedString)
            mermaidCoordinator.apply(
                result.mermaidAttachments,
                revision: result.revision,
                to: textView,
                onTextStorageDelta: nil
            )
            appliedRevision = result.revision
        }

        func cancel() {
            cancelRenders()
            textView?.delegate = nil
            textView = nil
        }

        func cancelRenders() {
            mermaidCoordinator.cancelAll()
            appliedRevision = nil
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL {
                NSWorkspace.shared.open(url)
            } else if let string = link as? String, let url = URL(string: string) {
                NSWorkspace.shared.open(url)
            }
            return true
        }
    }
}

private func kindLabel(_ kind: Int?, source: CompletionCandidateSource) -> String {
    if source == .buffer {
        return "W"
    }

    switch kind {
    case 2:
        return "M"
    case 3:
        return "F"
    case 5:
        return "C"
    case 6:
        return "V"
    case 7:
        return "K"
    case 10:
        return "P"
    case 12:
        return "Fn"
    case 13:
        return "T"
    default:
        return "S"
    }
}
