import AlasRemoteKit
import SwiftUI

struct TranscriptRowView: View {
    let item: TranscriptItem
    let isExpanded: Bool
    /// A user image's bytes by its uri; nil shows the image's label instead.
    var image: (String) -> UIImage? = { _ in nil }
    /// Visual aids render live only with a session to answer through.
    var session: TranscriptSession?
    let toggle: () -> Void
    /// A group header's "Show earlier".
    var showAll: () -> Void = {}
    /// Whether a part of this row, such as one diff, shows all its lines, and its "Show all". The
    /// transcript keeps them with its expanded rows, so the cell re-measures and survives reuse.
    var showsAll: (String) -> Bool = { _ in false }
    var showAllPart: (String) -> Void = { _ in }

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
        } else {
            message
        }
    }

    @ViewBuilder
    private var message: some View {
        switch item.row {
        case .user(let text, _, let images, _):
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
                if !text.isEmpty { bubble(text) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 48)
        case .agent(let text):
            AgentMarkdown(id: item.id, text: text, session: session)
        case .thought(let text):
            Text(text)
                .font(.callout.italic())
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 2)
                .onTapGesture(perform: toggle)
        case .toolCall(let call):
            if let display = item.toolCall {
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
            titleCaption("Plan", doc.markdown ?? doc.planId)
        case .visualAid(let aid):
            if let session {
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
                DiffHunksView(diff: diff, maxLines: showsAll("diff") ? .max : 40) { showAllPart("diff") }
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

    var body: some View {
        let blocks = MarkdownBlockCache.shared.blocks(id: id, text: text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .paragraph(let s): Text(s)
                case .heading(let level, let s): Text(s).font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                case .code(let language, let chunks): CodeBlockView(language: language, chunks: chunks)
                case .list(let entries):
                    let widest = entries.compactMap { if case .number(let n) = $0.marker { n } else { nil } }
                        .max { $0.count < $1.count } ?? ""
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                ListMarker(marker: entry.marker, widest: widest)
                                Text(entry.text)
                            }
                            // One element per item, so VoiceOver reads a task's state and text once.
                            .accessibilityElement(children: .combine)
                            .padding(.leading, CGFloat(entry.depth) * 16)
                        }
                    }
                case .quote(let s):
                    Text(s).foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
                case .image(let source, let alt):
                    TranscriptImage(id: "\(id):block:\(index)", source: source, label: alt.isEmpty ? "Image" : alt,
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
