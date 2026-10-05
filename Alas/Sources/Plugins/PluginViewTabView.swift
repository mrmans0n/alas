import SwiftUI

/// Text-field rules that decide what the host sends and keeps; the view only applies them.
enum PluginTextFieldSync {
    /// Upper bound on the text one `submit` carries, well under the host's message limit.
    static let maxSubmitBytes = 64 * 1024

    /// The plugin's `value` wins on first render and whenever it changes; otherwise the user's typing stays.
    static func apply(incoming: String, previousIncoming: String?, current: String) -> String {
        previousIncoming == nil || incoming != previousIncoming ? incoming : current
    }

    /// `text` cut to at most `maxBytes` of UTF-8, on a Unicode scalar boundary.
    static func capped(_ text: String, maxBytes: Int = maxSubmitBytes) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: maxBytes)
        while end.samePosition(in: text.unicodeScalars) == nil { text.utf8.formIndex(before: &end) }
        return String(text.unicodeScalars[..<end])
    }
}

/// Renders a plugin's validated view tree with native controls and sends its `view/event`s.
/// Renders a tab's tree or, with `panel`, a panel's.
struct PluginViewTabView: View {
    let host: PluginHost
    var tabIndex = 0
    var panel: String?

    private var root: PluginViewNode? {
        if let panel { host.panelViews[panel] } else { host.views[tabIndex] }
    }

    var body: some View {
        if let root {
            // Every node is keyed by its id, so a re-render keeps focus, scroll position and typing.
            PluginViewNodeView(
                node: root, events: PluginViewEvents(host: host, tabIndex: tabIndex, panel: panel.map { PluginPanelPlace(panel: $0) }))
                .id(root.id)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct PluginViewEvents {
    let host: PluginHost
    let tabIndex: Int
    let panel: PluginPanelPlace?

    func send(_ id: String, _ kind: String, _ value: String? = nil) {
        Task {
            if let panel {
                await host.viewEvent(place: panel, id: id, kind: kind, value: value)
            } else {
                await host.viewEvent(tab: tabIndex, id: id, kind: kind, value: value)
            }
        }
    }
}

private extension EnvironmentValues {
    @Entry var inClickableCard = false
}

struct PluginViewNodeView: View {
    let node: PluginViewNode
    let events: PluginViewEvents
    @Environment(\.theme) var theme
    @Environment(\.inClickableCard) private var inClickableCard
    @FocusState private var cardFocused: Bool

    var body: some View {
        switch node.kind {
        case .vstack:
            VStack(alignment: .leading, spacing: spacing) { children }
                .frame(width: width, alignment: .leading)
        case .hstack:
            // Baseline, not top: a caption beside a button sits level with its label, and a row's
            // leading text lines up with the first line of a stacked title.
            HStack(alignment: .firstTextBaseline, spacing: spacing) { children }
        case .scroll:
            ScrollView(node.horizontal ? .horizontal : .vertical) { children }
        case .text:
            let text = Text(node.text ?? "")
                .font(font)
                .foregroundColor(color(node.tone))
            // Selectable text takes the mouse-down, so inside a clickable card the click never
            // reaches the card's tap gesture.
            if inClickableCard {
                text
            } else {
                text.textSelection(.enabled)
            }
        case .badge:
            Text(node.text ?? "")
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundColor(color(node.tone))
                .background(Capsule().fill(color(node.tone).opacity(0.15)))
        case .button:
            AlasButton(title: node.label ?? "", icon: node.icon, style: buttonStyle) { events.send(node.id, "click") }
                .disabled(node.disabled)
                .opacity(node.disabled ? 0.5 : 1)
                .accessibilityLabel(node.label ?? "")
        case .textField:
            PluginTextFieldView(node: node) { events.send(node.id, "submit", PluginTextFieldSync.capped($0)) }
        case .menu:
            Menu(node.label ?? "") {
                ForEach(node.items, id: \.id) { item in
                    Button(item.label) { events.send(node.id, "select", item.id) }
                }
            }
            .fixedSize()
        case .card:
            card
        case .divider:
            Divider().accessibilityHidden(true)
        case .spacer:
            Spacer(minLength: 0).accessibilityHidden(true)
        case .progress:
            HStack(spacing: 6) {
                Spinner(lineWidth: 1.5, duration: 0.7).frame(width: 11, height: 11)
                if let text = node.text {
                    Text(text).font(.caption).foregroundColor(color(.dim))
                }
            }
        case .link:
            // Opened by Alas, not the plugin: no event, and always the default browser.
            AlasButton(title: node.label ?? "", icon: "arrow.up.right", style: .subtle) {
                if let url = node.url { NSWorkspace.shared.open(url) }
            }
            .accessibilityLabel(node.label ?? "")
            .help(node.url?.absoluteString ?? "")
        case .markdown:
            PluginMarkdownView(text: node.text ?? "")
        }
    }

    private var children: some View {
        ForEach(node.children, id: \.id) { PluginViewNodeView(node: $0, events: events) }
    }

    @ViewBuilder private var card: some View {
        let content = VStack(alignment: .leading) { children }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.color("bg-2")))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(node.tone.map { color($0) } ?? theme.color("line"), lineWidth: 1))
            .frame(width: width)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        if node.clickable {
            // Not a Button: that would merge the card into one accessibility element and hide its
            // inner buttons and menus. Inner controls still win the hit test over the tap gesture.
            content
                .environment(\.inClickableCard, true)
                .onTapGesture { events.send(node.id, "click") }
                // A keyboard stop like a button: Tab reaches it with keyboard navigation on, Space or Return clicks.
                .focusable(interactions: .activate)
                .focused($cardFocused)
                .onKeyPress(keys: [.space, .return]) { _ in
                    // Keys bubble up from inner controls, such as the card's menus; those are not the card's.
                    guard cardFocused else { return .ignored }
                    events.send(node.id, "click")
                    return .handled
                }
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { events.send(node.id, "click") }
        } else {
            content
        }
    }

    private var spacing: CGFloat? { node.spacing.map { CGFloat($0) } }
    /// A fixed width lets text wrap where no width is proposed, e.g. inside a horizontal scroll.
    private var width: CGFloat? { node.width.map { CGFloat($0) } }

    private var font: Font {
        switch node.style {
        case "caption": .caption
        case "title": .title3.weight(.semibold)
        case "monospaced": .system(.body, design: .monospaced)
        default: .body
        }
    }

    private var buttonStyle: AlasButtonStyle {
        switch node.style {
        case "primary": .primary
        case "plain": .subtle
        default: .normal
        }
    }

    private func color(_ tone: PluginViewNode.Tone?) -> Color {
        theme.color((tone ?? .normal).colorKey)
    }
}

/// A markdown node (API 9), on the chat's Markdown parser. Images show only their alt text, so nothing is loaded; only
/// absolute https links open, in the default browser, and the plugin is not told.
private struct PluginMarkdownView: View {
    let text: String
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ACPMarkdownText.parse(text).enumerated()), id: \.offset) { _, block in
                self.block(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return .discarded }
            NSWorkspace.shared.open(url)
            return .handled
        })
    }

    @ViewBuilder private func block(_ block: ACPMarkdownText.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text)).font(level <= 1 ? .title2.weight(.semibold) : level == 2 ? .title3.weight(.semibold) : .headline)
        case .paragraph(let text):
            Text(Self.inline(text))
        case .quote(let text):
            Text(Self.inline(text))
                .foregroundColor(theme.color("fg-dim"))
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(theme.color("accent").opacity(0.55)).frame(width: 2) }
        case .taskList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: item.isChecked ? "checkmark.square" : "square").accessibilityLabel(item.isChecked ? "Done" : "To do")
                        Text(Self.inline(item.text))
                    }
                }
            }
        case .code(_, let body), .streamingCode(_, let body), .mermaid(let body):
            Text(body)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.color("bg-2")))
        case .table(let header, let rows):
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow { ForEach(Array(header.enumerated()), id: \.offset) { Text(Self.inline($0.element)).bold() } }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { Text(Self.inline($0.element)) } }
                }
            }
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        ACPMarkdownInlineRenderer.cleanAttributedString(text)
    }
}

/// Keeps its own editing state; the plugin's `value` only replaces it when it changes.
private struct PluginTextFieldView: View {
    let node: PluginViewNode
    let submit: (String) -> Void
    @State private var text: String
    @State private var lastIncoming: String
    @FocusState private var editorFocused: Bool
    @Environment(\.theme) var theme

    init(node: PluginViewNode, submit: @escaping (String) -> Void) {
        self.node = node
        self.submit = submit
        _text = State(initialValue: node.value ?? "")
        _lastIncoming = State(initialValue: node.value ?? "")
    }

    var body: some View {
        field.onChange(of: node.value) {
            let incoming = node.value ?? ""
            text = PluginTextFieldSync.apply(incoming: incoming, previousIncoming: lastIncoming, current: text)
            lastIncoming = incoming
        }
    }

    @ViewBuilder private var field: some View {
        if node.multiline {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(4)
                // Capped so a long prompt scrolls inside the editor instead of pushing the rest of the view down.
                .frame(minHeight: 64, maxHeight: 140)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.color("field-bg")))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.5))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty, let placeholder = node.placeholder {
                        Text(placeholder)
                            .foregroundColor(theme.color("fg-faint"))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(node.placeholder ?? "Text")
                .focused($editorFocused)
                // ⌘Return submits through a key equivalent, which the text view cannot swallow; plain
                // Return still inserts a newline. Only the focused editor installs it.
                .background {
                    if editorFocused {
                        Button("") { submit(text) }
                            .keyboardShortcut(.return, modifiers: .command)
                            .frame(width: 0, height: 0)
                            .opacity(0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        } else {
            AlasField(text: $text, placeholder: node.placeholder ?? "", onSubmit: { submit(text) })
        }
    }
}
