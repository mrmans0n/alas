import AlasHighlight
import AlasRemoteKit
import SwiftUI

/// What a chip's card can read and do for one session screen: the session's
/// commands and references, its shepherd, and opening a skill's file.
@MainActor
final class ChipActions {
    weak var session: TranscriptSession?
    weak var workspace: SessionWorkspace?
    let owner: UUID

    init(session: TranscriptSession, workspace: SessionWorkspace?, owner: UUID) {
        self.session = session
        self.workspace = workspace
        self.owner = owner
    }

    /// `/ship` as the composer offers it, for its card.
    static let ship = RemoteSlashCommand(
        command: "/ship", description: "Have this session open a PR for the branch, or shepherd the open one.")

    func command(_ name: String) -> RemoteSlashCommand {
        if name == Self.ship.command { return Self.ship }
        return session?.config?.availableCommands?.first { $0.command == name } ?? RemoteSlashCommand(command: name)
    }

    var codeHost: CodeHostKind? { session?.config?.codeHost?.kind }

    /// The card a chip opens, read when it opens. `draft` is the composer
    /// chip it shows, `sent` the sent mention, for the details the chip
    /// itself doesn't carry.
    func card(for chip: ChipModel, draft: RemoteDraftChip? = nil, sent: RemoteUserMention? = nil,
              onExpand: (() -> Void)? = nil) -> AnyView? {
        switch chip {
        case .command(let name, _):
            let command = command(name)
            return AnyView(CommandCard(
                command: command,
                ship: name == Self.ship.command ? ShipLine(shepherd: workspace?.shepherd,
                                                           branch: session?.summary?.worktree?.branch) : nil,
                openSkill: command.skill?.hasFile == true && workspace != nil ? { [weak self] in self?.openSkill(name) } : nil))
        case .mention(let name), .symbol(let name, _, _):
            if let symbol = sent?.symbol {
                let workspace = workspace
                return AnyView(SymbolCard(symbol: symbol, name: name,
                                          readCurrent: workspace.map { workspace in { await workspace.peekFile(symbol.path) } }))
            }
            if case .mention(let mention)? = draft {
                return AnyView(MentionCard(name: mention.name, kind: mention.kind, detail: mention.detail))
            }
            return AnyView(MentionCard(name: sent?.name ?? name, kind: sent?.kind ?? RemoteMention.file))
        case .reference(let reference, _, _):
            guard let session else { return nil }
            session.resolve([reference])
            return AnyView(ReferenceCard(reference: reference, cache: session.references))
        case .pasted(let ordinal, let text):
            return AnyView(PastedCard(ordinal: ordinal, text: text, onExpand: onExpand))
        }
    }

    func openSkill(_ command: String) {
        // The card's popover goes first, so the file pushes on the screen below it.
        UIApplication.shared.dismissPresentedPopover()
        workspace?.openSkill(command, by: owner)
    }
}

extension UIApplication {
    @MainActor func dismissPresentedPopover() {
        let root = connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first
        var top = root
        while let presented = top?.presentedViewController { top = presented }
        if top?.modalPresentationStyle == .popover { top?.dismiss(animated: true) }
    }
}

/// What `/ship` would do now: the shepherd's state, or the branch it would open a PR for.
struct ShipLine {
    let shepherd: RemoteShepherd?
    let branch: String?
}

/// Name, hint and description of a slash command, its skill line, and for
/// `/ship` the session's pull request state, as the Mac's hover card.
struct CommandCard: View {
    let command: RemoteSlashCommand
    var ship: ShipLine?
    var openSkill: (() -> Void)?

    var body: some View {
        CardBody {
            Label {
                Text(command.command).font(.headline.monospaced())
            } icon: {
                Image(systemName: "wand.and.sparkles").foregroundStyle(.purple)
            }
            if let hint = command.hint, !hint.isEmpty {
                Text(hint).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let description = command.description, !description.isEmpty {
                Text(description).font(.footnote).foregroundStyle(.secondary)
            }
            if let skill = command.skill {
                Text(skill.hasFile ? "Skill" : "Skill bundled with the agent").font(.footnote).foregroundStyle(.tertiary)
            }
            if let ship {
                Divider()
                shipLine(ship)
            }
            if let openSkill {
                Button("Open SKILL.md", systemImage: "doc.text", action: openSkill).font(.footnote.weight(.medium))
            }
        }
    }

    private func shipLine(_ line: ShipLine) -> some View {
        let badge = line.shepherd?.badge ?? "noRequest"
        return HStack(spacing: 4) {
            Image(systemName: ShepherdPill.badgeSymbol(badge))
                .foregroundStyle(ShepherdPill.color(badge))
            if let number = line.shepherd?.number {
                Text(number).font(.footnote.monospaced().weight(.semibold))
                if let phase = line.shepherd?.phaseLine { Text("· \(phase)").foregroundStyle(.secondary) }
            } else if let branch = line.branch {
                Text("No PR yet for").foregroundStyle(.secondary)
                Text(branch).font(.footnote.monospaced().weight(.semibold))
            } else {
                Text("No PR yet").foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .lineLimit(1)
        .truncationMode(.middle)
    }
}

/// A file, folder or session mention: what it names.
struct MentionCard: View {
    let name: String
    var kind: String = RemoteMention.file
    var detail: String?

    var body: some View {
        CardBody {
            Label(name, systemImage: Self.icon(kind: kind, name: name)).font(.headline)
            if let detail {
                Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(4).truncationMode(.middle)
            }
        }
    }

    static func icon(kind: String, name: String) -> String {
        switch kind {
        case RemoteMention.session: "bubble.left.and.text.bubble.right"
        case RemoteMention.symbol: "curlybraces"
        default: name.hasSuffix("/") ? "folder" : "doc"
        }
    }
}

/// A PR/MR or issue: its state, title and author, as the Mac's reference card.
struct ReferenceCard: View {
    let reference: CodeHostReference
    let cache: ReferenceCache
    @Environment(\.openURL) private var openURL

    var body: some View {
        let entry = cache.entries[reference]
        CardBody {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(entry)).foregroundStyle(.secondary)
                Text(reference.spelling).font(.headline.monospaced())
                if case .loaded(let summary) = entry { StateBadge(state: summary.state) }
            }
            switch entry {
            case .loaded(let summary):
                Text(summary.title).font(.subheadline).lineLimit(3)
                if let detail = Self.detail(summary) {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Button("Open in Browser", systemImage: "safari") { openURL(summary.url) }
                    .font(.footnote.weight(.medium))
            case .failed(let failure):
                Text(Self.message(failure)).font(.footnote).foregroundStyle(.secondary)
            case .unsupported:
                Text("Can't look up references on this host.").font(.footnote).foregroundStyle(.secondary)
            case .loading, nil:
                Text("Loading…").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private static func symbol(_ entry: ReferenceCache.Entry?) -> String {
        if case .loaded(let summary) = entry, summary.kind == .issue { return "smallcircle.filled.circle" }
        return "arrow.triangle.pull"
    }

    static func detail(_ summary: CodeHostReferenceSummary) -> String? {
        let (verb, date): (String, Date?) = switch summary.state {
        case .merged: ("merged", summary.mergedAt ?? summary.updatedAt)
        case .closed: ("closed", summary.closedAt ?? summary.updatedAt)
        case .open, .draft: ("opened", summary.createdAt)
        }
        let when = date.map { "\(verb) \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: .now))" }
        let parts = [summary.author, when].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func message(_ failure: CodeHostReferenceFailure) -> String {
        switch failure {
        case .notFound(let repository): "Not found on \(repository)"
        case .unauthenticated(let executable, let host): "\(executable) isn't authenticated for \(host)"
        case .cliMissing(let executable): "\(executable) is not installed"
        case .other(let message): message
        }
    }
}

struct StateBadge: View {
    let state: CodeHostReferenceSummary.State

    var body: some View {
        let (text, color): (String, Color) = switch state {
        case .open: ("Open", .green)
        case .draft: ("Draft", .gray)
        case .merged: ("Merged", .purple)
        case .closed: ("Closed", .red)
        }
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// A collapsed paste in full, with Copy, and Expand where the composer can take it back.
struct PastedCard: View {
    let ordinal: Int
    let text: String
    var onExpand: (() -> Void)?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ACPPastedTextPolicy.label(ordinal: ordinal, content: text))
                    .font(Font(ChipStyle.labelFont))
                Spacer(minLength: 8)
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = text
                    copied = true
                }
                .font(.footnote)
                if let onExpand {
                    Button("Expand") {
                        UIApplication.shared.dismissPresentedPopover()
                        onExpand()
                    }
                    .font(.footnote)
                }
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }
            .frame(maxHeight: 340)
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
        .frame(width: 340)
    }
}

/// A sent symbol mention: the declaration and the code as it was sent, or as it is now.
struct SymbolCard: View {
    let symbol: RemoteSymbolMention
    let name: String
    let readCurrent: (() async -> String?)?
    @State private var showsCurrent = false
    @State private var current: String??

    private static let maxLines = 40

    var body: some View {
        CardBody {
            HStack(spacing: 6) {
                SymbolKindBadge(kind: SymbolKind(rawValue: symbol.kind), side: 16)
                Text(name).font(.headline.monospaced()).lineLimit(1)
            }
            Text(location).font(.caption.monospaced()).foregroundStyle(.secondary)
            if symbol.snapshot?.excerpt != nil, readCurrent != nil {
                Picker("Code", selection: $showsCurrent) {
                    Text("Sent").tag(false)
                    Text("Current").tag(true)
                }
                .pickerStyle(.segmented)
            }
            code
        }
        .task(id: showsCurrent) {
            guard showsCurrent || symbol.snapshot?.excerpt == nil, current == nil, let readCurrent else { return }
            current = .some(await readCurrent())
        }
    }

    private var location: String {
        let lines = "\(symbol.lineRange.lowerBound + 1)–\(symbol.lineRange.upperBound + 1)"
        return "\(symbol.path):\(lines)" + (symbol.includesCode ? " · code included" : "")
    }

    @ViewBuilder
    private var code: some View {
        if !showsCurrent, let excerpt = symbol.snapshot?.excerpt {
            codeBlock(excerpt)
        } else if symbol.snapshot?.found == false {
            Text("Not found when sent").font(.footnote).foregroundStyle(.secondary)
        } else {
            switch current {
            case .some(.some(let file)): codeBlock(Self.lines(symbol.lineRange, of: file))
            case .some(.none): Text("No longer found").font(.footnote).foregroundStyle(.secondary)
            case .none: ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    private func codeBlock(_ text: String) -> some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(Self.maxLines)
        return ScrollView(.horizontal) {
            CodeBlockView(language: nil, chunks: MarkdownBlock.codeChunks(lines.joined(separator: "\n"), path: symbol.path))
        }
        .frame(maxHeight: 300)
    }

    static func lines(_ range: ClosedRange<Int>, of file: String) -> String {
        let all = file.split(separator: "\n", omittingEmptySubsequences: false)
        guard range.lowerBound < all.count else { return "" }
        return all[range.lowerBound ... min(range.upperBound, all.count - 1)].joined(separator: "\n")
    }
}

/// The cards' shared frame: 340 pt wide, as on the Mac.
private struct CardBody<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(12)
            .frame(width: 340, alignment: .leading)
    }
}
