import AlasRemoteKit
import SwiftUI

struct SpikeRowView: View {
    let row: SpikeRow
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch row.row {
        case .user(let text, _, _):
            Text(text)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
        case .agent(let text):
            AgentMarkdown(id: row.id, revision: row.revision, text: text)
        case .thought(let text):
            Text(text)
                .font(.callout.italic())
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 2)
                .onTapGesture(perform: toggle)
        case .toolCall(let call):
            toolCall(call)
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
            titleCaption(aid.title, "Visual")
        case .systemNotice(let text):
            Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }

    private func toolCall(_ call: ACPToolCall) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: Self.toolIcon(call.kind)).foregroundStyle(.secondary)
                Text(call.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
                Text(call.status).font(.caption).foregroundStyle(.secondary)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.tertiary)
            }
            if isExpanded {
                Text(call.content).font(.system(.footnote, design: .monospaced))
            }
        }
        .card()
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
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
            Text(Self.diffPreview(edit)).font(.system(.footnote, design: .monospaced))
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

    /// First 12 changed lines, removals then additions.
    private static func diffPreview(_ edit: ACPFileEdit) -> AttributedString {
        let removed = (edit.oldText ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { ("\u{2212} ", Color.red, $0) }
        let added = edit.newText.split(separator: "\n", omittingEmptySubsequences: false).map { ("+ ", Color.green, $0) }
        var out = AttributedString()
        for (i, (sign, color, line)) in (removed + added).prefix(12).enumerated() {
            var a = AttributedString((i > 0 ? "\n" : "") + sign + line)
            a.foregroundColor = color
            out += a
        }
        return out
    }

    private static func planIcon(_ status: String) -> String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "in_progress": "circle.dotted"
        default: "circle"
        }
    }

    private static func toolIcon(_ kind: String?) -> String {
        switch kind {
        case "execute": "terminal"
        case "read": "doc.text"
        case "edit": "pencil"
        case "search": "magnifyingglass"
        case "fetch": "network"
        default: "wrench.and.screwdriver"
        }
    }
}

private extension View {
    func card() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct AgentMarkdown: View {
    let id: String
    let revision: Int
    let text: String

    var body: some View {
        let blocks = MarkdownBlockCache.shared.blocks(id: id, revision: revision, text: text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let s): Text(s)
                case .heading(let level, let s): Text(s).font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                case .code(_, let code):
                    Text(code)
                        .font(.system(.footnote, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                case .list(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\u{2022}")
                                Text(item)
                            }
                        }
                    }
                case .quote(let s):
                    Text(s).foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
                case .table(let rows):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, cells in
                            Text(cells.joined(separator: "  |  "))
                                .font(.footnote.weight(i == 0 ? .semibold : .regular))
                        }
                    }
                }
            }
        }
    }
}
