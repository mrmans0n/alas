import AlasHighlight
import AlasRemoteKit
import SwiftUI

struct TranscriptRowView: View {
    let item: TranscriptItem
    let isExpanded: Bool
    /// A user image's bytes by its uri; nil shows the image's label instead.
    var image: (String) -> UIImage? = { _ in nil }
    /// Visual aids render live only with a session to answer through.
    var session: TranscriptSession?
    /// False for a read-only transcript: visual aids show as captions and subagents do not open.
    var interactive = true
    let toggle: () -> Void
    /// A group header's "Show earlier".
    var showAll: () -> Void = {}
    /// Whether a part of this row, such as one diff, shows all its lines, and its "Show all". The
    /// transcript keeps them with its expanded rows, so the cell re-measures and survives reuse.
    var showsAll: (String) -> Bool = { _ in false }
    var showAllPart: (String) -> Void = { _ in }
    /// Pushes a subagent's transcript; offered only when the session's host serves it.
    var openSubagent: (RemoteWireMessage.Subagent) -> Void = { _ in }
    /// Opens a message's text to select part of it; `quote` offers Quote on the selection.
    var selectText: (_ text: String, _ quote: ((String) -> Void)?) -> Void = { _, _ in }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            // Inset behind a rule spanning the row, so a group's members read as one block under its header.
            .padding(.leading, item.isGroupMember ? 12 : 0)
            .overlay(alignment: .leading) {
                if item.isGroupMember { Rectangle().fill(.quaternary).frame(width: 1) }
            }
            .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var content: some View {
        if case .groupHeader(_, let summary, let expanded, let hiddenCount) = item.kind {
            ToolCallGroupRow(summary: summary, expanded: expanded, hiddenCount: hiddenCount, toggle: toggle, showAll: showAll)
        } else if case .turnChanges(let changes) = item.kind {
            TurnChangesCard(changes: changes)
        } else {
            message
        }
    }

    @ViewBuilder
    private var message: some View {
        switch item.row {
        case .user(let text, _, let images, let json, let mentions, let pastedSpans):
            let card = json.flatMap(Self.promptCard)
            VStack(alignment: .trailing, spacing: 6) {
                if !images.isEmpty {
                    HStack(spacing: 6) {
                        // The same image attached twice shares a uri.
                        ForEach(Array(images.enumerated()), id: \.offset) { index, attached in
                            if let loaded = image(attached.uri) {
                                AttachmentThumbnail(id: "\(item.id):attachment:\(index)", thumbnail: loaded, uri: attached.uri,
                                                    name: attached.name ?? "Image", session: session)
                            } else {
                                bubble("\u{1F5BC} \(attached.name ?? "Image")")
                            }
                        }
                    }
                }
                if let card {
                    // A turn Alas injected reads as a card, not as something the user typed.
                    OutcomeCard(id: item.id, card: card, instruction: text, isExpanded: isExpanded, toggle: toggle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    UserMessageBody(id: item.id, text: text, mentions: mentions, pastedSpans: pastedSpans, session: session) {
                        messageMenu(text)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, card == nil ? 48 : 0)
        case .agent(let text):
            AgentMarkdown(id: item.id, text: text, session: session)
                .contextMenu { messageMenu(text) }
        case .thought(let text):
            Text(text)
                .font(.callout.italic())
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 2)
                .onTapGesture(perform: toggle)
        case .toolCall(let call):
            if let subagent = item.message.subagent {
                SubagentCard(subagent: subagent, duration: item.toolCall?.duration,
                             open: interactive && session?.supportsSubagents == true ? { openSubagent(subagent) } : nil)
            } else if let display = item.toolCall {
                ToolCallCard(item: item, call: call, display: display, isExpanded: isExpanded, toggle: toggle,
                             session: session, showsAll: { showsAll("section:\($0)") },
                             showAll: { showAllPart("section:\($0)") })
            }
        case .fileEdit(let edit):
            fileEdit(edit)
        case .plan(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Label(item.content, systemImage: Self.planIcon(item.status))
                        .foregroundStyle(item.status == "completed" ? .secondary : .primary)
                }
            }
            .card()
        case .planDocument(let doc):
            if let display = doc.display { planDocument(display) }
        case .visualAid(let aid):
            if let session, interactive {
                // Keyed by visual, so a reused cell never hands one visual's page or state to another.
                VisualAidCard(aid: aid, session: session).id(aid.id)
            } else {
                titleCaption(aid.title, "Visual")
            }
        case .questionAnswer(let answer):
            QuestionAnswerCard(answer: answer, isExpanded: isExpanded, toggle: toggle)
        case .outcomeCard(let card):
            OutcomeCard(id: item.id, card: card)
        case .failureIncident(let incident):
            FailureIncidentCard(incident: incident)
        case .systemNotice(let text):
            notice(text)
        }
    }

    static func promptCard(_ json: String) -> RemotePromptCard? {
        try? JSONDecoder().decode(RemotePromptCard.self, from: Data(json.utf8))
    }

    /// The session a quote lands in: a live transcript, which has a composer under it.
    private var quoting: TranscriptSession? {
        guard interactive, let session, !session.hasEnded else { return nil }
        return session
    }

    /// A message's long-press menu, ordered as the Mac's peer transcript orders its own.
    @ViewBuilder
    private func messageMenu(_ text: String) -> some View {
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
        if let quoting, ACPMessageQuote.canQuote(text) {
            Button("Quote", systemImage: "text.quote") { quoting.quote(text) }
        }
        Button("Select Text", systemImage: "selection.pin.in.out") {
            selectText(text, quoting.map { session in { session.quote($0) } })
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
    }

    private func bubble(_ text: String) -> some View {
        Text(text)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 18))
    }

    private func fileEdit(_ edit: ACPFileEdit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(edit.path).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
                Text("+\(edit.added)").foregroundStyle(.green)
                Text("\u{2212}\(edit.removed)").foregroundStyle(.red)
            }
            .font(.caption.monospacedDigit())
            if let diff = item.fileEditDiff {
                DiffHunksView(diff: diff, spans: item.fileEditSpans, maxLines: showsAll("diff") ? .max : 40) { showAllPart("diff") }
            }
        }
        .card()
    }

    /// The plan in full, like the Mac's plan card. The host strips a file plan's path from the document
    /// and sends it only in the row's text, as "Plan file: <path>".
    private func planDocument(_ display: ACPPlanDocument.Display) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Plan", systemImage: "doc.text")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            if let markdown = display.markdown {
                AgentMarkdown(id: item.id, text: markdown, session: session)
            }
            if display.showsFile {
                let path = display.filePath
                    ?? item.message.text.map { $0.hasPrefix("Plan file: ") ? String($0.dropFirst(11)) : $0 }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan file").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(path ?? "Unavailable").font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .card()
    }

    private func titleCaption(_ title: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.medium))
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .card()
    }

    private static func planIcon(_ status: String) -> String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "in_progress": "circle.dotted"
        default: "circle"
        }
    }
}

extension View {
    func card() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AgentMarkdown: View {
    let id: String
    let text: String
    var session: TranscriptSession?
    /// Set for a user message: its text gets the Mac's inline chips.
    var chips: UserMessageChips?
    /// Maps an image source before it loads: a file preview resolves it beside the file.
    var resolve: (String) -> String = { $0 }

    var body: some View {
        let blocks = MarkdownBlockCache.shared.blocks(id: id, text: text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .paragraph(let s): inline(s)
                case .heading(let level, let s):
                    inline(s).font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                case .code(let language, let chunks): CodeBlockView(language: language, chunks: chunks)
                case .mermaid(let source): MermaidBlockView(source: source)
                case .visual(let aid):
                    if let session {
                        // Keyed by visual, so a reused cell never hands one visual's page or height to another.
                        VisualAidCard(aid: aid, session: session).id(aid.id)
                    } else {
                        CodeBlockView(language: VisualFence.tag, chunks: [CodeChunk(text: aid.html, spans: [])])
                    }
                case .drawingVisual(let title):
                    Label(title.map { "Drawing \($0)…" } ?? "Drawing visual…", systemImage: "rectangle.on.rectangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .list(let entries):
                    let widest = entries.compactMap { if case .number(let n) = $0.marker { n } else { nil } }
                        .max { $0.count < $1.count } ?? ""
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                ListMarker(marker: entry.marker, widest: widest)
                                inline(entry.text)
                            }
                            // One element per item, so VoiceOver reads a task's state and text once.
                            .accessibilityElement(children: .combine)
                            .padding(.leading, CGFloat(entry.depth) * 16)
                        }
                    }
                case .alert(let kind, let s):
                    VStack(alignment: .leading, spacing: 4) {
                        Label(kind.title, systemImage: kind.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(kind.color)
                        if !s.characters.isEmpty { inline(s) }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(kind.color).frame(width: 3) }
                    .accessibilityElement(children: .combine)
                case .quote(let s):
                    inline(s).foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
                case .image(let source, let alt):
                    TranscriptImage(id: "\(id):block:\(index)", source: resolve(source), label: alt.isEmpty ? "Image" : alt,
                                    session: session)
                case .table(let header, let rows):
                    let table = MarkdownTable(header: header, rows: rows)
                    // Scrolls sideways only when the columns are wider than the transcript.
                    ViewThatFits(in: .horizontal) {
                        table
                        ScrollView(.horizontal) { table }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func inline(_ string: AttributedString) -> some View {
        if let chips {
            ChipText(text: string, chips: chips)
        } else {
            Text(string)
        }
    }
}

private struct ListMarker: View {
    let marker: ListEntry.Marker
    /// The longest number in the list; a hidden copy sizes the column, so it scales with Dynamic Type.
    let widest: String

    var body: some View {
        switch marker {
        case .bullet: Text("\u{2022}").frame(minWidth: 12)
        case .number(let n): Text(widest).hidden().overlay(alignment: .trailing) { Text(n) }.monospacedDigit()
        case .task(let checked):
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Color.accentColor : .secondary)
                .accessibilityLabel(checked ? "Checked" : "Unchecked")
        case .continuation(let parent): ListMarker(marker: parent, widest: widest).hidden().accessibilityHidden(true)
        }
    }
}

private struct MarkdownTable: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(header.indices, id: \.self) { Text(header[$0]).fontWeight(.semibold) }
            }
            Rectangle().fill(.separator).frame(height: 1).gridCellUnsizedAxes(.horizontal)
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(rows[r].indices, id: \.self) { Text(rows[r][$0]) }
                }
            }
        }
        .font(.footnote)
    }
}

/// A user attachment's thumbnail; tapping opens the viewer on the display-size image, with the
/// thumbnail scaled up until it lands.
private struct AttachmentThumbnail: View {
    /// Where it sits, for `transcriptImage`'s inline key.
    let id: String
    let thumbnail: UIImage
    let uri: String
    let name: String
    let session: TranscriptSession?
    @State private var viewing = false

    var body: some View {
        Image(uiImage: thumbnail)
            .resizable()
            .scaledToFill()
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel(name)
            .onTapGesture { viewing = true }
            .fullScreenCover(isPresented: $viewing) {
                TranscriptImageViewer(image: display ?? thumbnail, label: name)
            }
    }

    private var display: UIImage? {
        if case .loaded(let image) = session?.transcriptImage(id: id, source: uri) { return image }
        return nil
    }
}

private extension MarkdownAlert.Kind {
    /// GitHub's colours, as the Mac maps them onto its theme.
    var color: Color {
        switch self {
        case .note: .blue
        case .tip: .green
        case .important: .purple
        case .warning: .orange
        case .caution: .red
        }
    }
}
