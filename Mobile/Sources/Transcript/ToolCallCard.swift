import AlasRemoteKit
import SwiftUI

/// The phone's `ACPToolCallCard`: one header line (icon, label, target, duration, status, chevron)
/// that toggles, and when expanded the diff sections, the output, images, or an empty-state line.
struct ToolCallCard: View {
    let item: TranscriptItem
    let call: ACPToolCall
    let display: ToolCallDisplay
    let isExpanded: Bool
    let toggle: () -> Void
    var session: TranscriptSession?
    /// Whether section `id` shows all its lines, and its "Show all"; kept by the transcript.
    var showsAll: (Int) -> Bool = { _ in false }
    var showAll: (Int) -> Void = { _ in }

    var body: some View {
        // The header's padding sits inside its button, so the whole collapsed card is the tap target.
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) { header.padding(12) }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) { expandedBody }
                    .padding([.horizontal, .bottom], 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: display.presentation.iconSystemName).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(display.presentation.label).font(.subheadline.weight(.medium)).lineLimit(1).layoutPriority(1)
            if let target = display.target {
                Text(target)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let duration = display.duration {
                Text(duration).font(.caption).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
            }
            status
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var status: some View {
        switch call.status {
        case "in_progress":
            ProgressView().controlSize(.mini).accessibilityLabel("Running")
        case "pending":
            Circle().fill(.secondary).frame(width: 5, height: 5).accessibilityLabel("Pending")
        case "completed":
            EmptyView()
        case "failed":
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Failed")
        case "canceled", "cancelled":
            Image(systemName: "stop.circle").foregroundStyle(.secondary).accessibilityLabel("Canceled")
        default:
            Text(call.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
        }
    }

    @ViewBuilder private var expandedBody: some View {
        // Indexed before filtering, so an asset keeps its position as the key of its inline data.
        let images = Array(call.assets.enumerated()).filter { Self.isImage($0.element) }
        ForEach(display.sections) { section($0) }
        if display.showsContent {
            Text(call.content).font(.system(.footnote, design: .monospaced))
        }
        ForEach(images, id: \.offset) { index, asset in
            TranscriptImage(id: "\(item.id):asset:\(index)", source: asset.uri ?? "", data: asset.data,
                            label: Self.label(asset), session: session)
        }
        // A host that lost the terminal says so only once the call ended; until then the call is still "Working…".
        let tails = call.terminalIds.compactMap { id in
            session?.toolTerminals[id].flatMap { $0.retained || !TranscriptSession.isRunning(call) ? (id, $0) : nil }
        }
        ForEach(tails, id: \.0) { _, tail in
            if tail.retained {
                ToolTerminalTailView(tail: tail)
            } else {
                Text("Terminal output not retained.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        if display.sections.isEmpty, !display.showsContent, images.isEmpty, tails.isEmpty {
            Text(emptyLine).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var emptyLine: String {
        switch call.status {
        case "pending", "in_progress": "Working…"
        case "canceled", "cancelled": "Canceled."
        default: "No output."
        }
    }

    private func section(_ section: ACPToolCallDiffSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(section.label.rawValue) · \(section.path)").lineLimit(1).truncationMode(.middle)
                if let note = section.changeNote {
                    Text(note).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if case .hunks = section.body {
                    Text("+\(section.added)").foregroundStyle(.green)
                    Text("\u{2212}\(section.removed)").foregroundStyle(.red)
                }
            }
            .font(.caption.monospaced())
            switch section.body {
            case .hunks(let diff):
                DiffHunksView(diff: diff, spans: display.sectionSpans[section.id] ?? [], maxLines: showsAll(section.id) ? .max : 40) { showAll(section.id) }
            case .unavailable:
                Text("Change unavailable").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// As the Mac's `looksLikeImage`: the kind, an image mime type, or an image file extension.
    private static func isImage(_ asset: ACPToolCallAsset) -> Bool {
        if asset.kind == .image || asset.mimeType?.lowercased().hasPrefix("image/") == true { return true }
        let candidate = [asset.uri, asset.name].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let candidate else { return false }
        let ext = URL(fileURLWithPath: candidate).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "webp"].contains(ext)
    }

    /// The name, else the uri's last path component; never a data uri, which can run to megabytes.
    private static func label(_ asset: ACPToolCallAsset) -> String {
        if let name = asset.name, !name.isEmpty { return name }
        guard let uri = asset.uri, !uri.isEmpty, !uri.lowercased().hasPrefix("data:") else { return "Image" }
        let url = URL(string: uri).flatMap { $0.scheme == nil ? nil : $0 } ?? URL(fileURLWithPath: uri)
        return url.lastPathComponent.isEmpty ? "Image" : url.lastPathComponent
    }
}

/// The phone's `ACPTerminalTailView`: the terminal's plain-text tail, at most 300 pt tall and
/// following the bottom as it grows, then how the command ended.
private struct ToolTerminalTailView: View {
    let tail: ToolTerminalTail

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(tail.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id(Self.bottom)
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
                .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                .onChange(of: tail.text) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            Group {
                if let signal = tail.signal {
                    Text("Killed (\(signal))").foregroundStyle(.secondary)
                } else if let code = tail.exitCode {
                    Text("Exited \(code)").foregroundStyle(code == 0 ? .green : .red)
                }
            }
            .padding([.horizontal, .bottom], 8)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground).opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private static let bottom = "bottom"
}
