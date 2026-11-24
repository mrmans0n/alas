import Foundation

/// One page of the sidebar pager: one of the user's spaces, or a paired Mac.
/// Peer pages are derived from the paired peers and never stored.
enum SidebarPage: Hashable, Identifiable {
    case space(String)
    case peer(serverId: String)

    var id: String {
        switch self {
        case .space(let id): "space:\(id)"
        case .peer(let serverId): "peer:\(serverId)"
        }
    }

    var peerServerId: String? {
        if case .peer(let serverId) = self { return serverId }
        return nil
    }
}

enum SidebarPages {
    /// The user's spaces in their order, then the peers in pairing order.
    static func pages(spaceIds: [String], peerServerIds: [String]) -> [SidebarPage] {
        spaceIds.map(SidebarPage.space) + peerServerIds.map { .peer(serverId: $0) }
    }

    /// The page on screen: the active peer while it is still paired, else
    /// the active space. A peer forgotten while its page shows falls back to
    /// the space rather than leaving the pager on nothing.
    static func active(activeSpaceId: String, activePeer: String?, in pages: [SidebarPage]) -> SidebarPage {
        if let activePeer, pages.contains(.peer(serverId: activePeer)) { return .peer(serverId: activePeer) }
        return .space(activeSpaceId)
    }

    /// ⌥⌘1 to ⌥⌘9 count across spaces and then peers.
    static func page(atOneBasedIndex index: Int, in pages: [SidebarPage]) -> SidebarPage? {
        pages.indices.contains(index - 1) ? pages[index - 1] : nil
    }

    /// One page per paired Mac is reason enough to show the pager.
    static func showsPager(spaceCount: Int, peerCount: Int, showSingleSpaceAffordance: Bool) -> Bool {
        spaceCount + peerCount > 1 || showSingleSpaceAffordance
    }
}
