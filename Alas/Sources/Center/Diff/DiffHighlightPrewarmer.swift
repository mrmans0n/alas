import AppKit

/// Warms `DiffPaneDocumentCache` (and, transitively, `HighlightSpanCache`)
/// for a diff's hunks off the scroll path.
///
/// Mounting a virtualized diff row builds its hunk's attributed documents
/// synchronously inside the scroll tick; a cold 80-line hunk costs tens of
/// milliseconds and reads as a fling hiccup. Prewarming performs the same
/// document build on a background queue when the row plan is first created
/// and keeps the result in the shared document cache, so row mounts reuse
/// the finished documents instead of rebuilding mid-fling.
enum DiffHighlightPrewarmer {
    private static let queue = DispatchQueue(label: "io.nlopez.alas.diff-highlight-prewarm", qos: .utility)

    static func prewarm(
        groups: [DiffDisplayGroup],
        expandedCollapsedRowIDs: Set<String>,
        layoutMode: DiffLayoutMode,
        fileExtension: String,
        font: NSFont,
        showWhitespace: Bool,
        theme: Theme
    ) {
        queue.async {
            warm(
                groups: groups,
                expandedCollapsedRowIDs: expandedCollapsedRowIDs,
                layoutMode: layoutMode,
                fileExtension: fileExtension,
                font: font,
                showWhitespace: showWhitespace,
                theme: theme
            )
        }
    }

    /// Same warm-up on the calling thread, for deterministic tests.
    static func prewarmSynchronously(
        groups: [DiffDisplayGroup],
        expandedCollapsedRowIDs: Set<String>,
        layoutMode: DiffLayoutMode,
        fileExtension: String,
        font: NSFont,
        showWhitespace: Bool,
        theme: Theme
    ) {
        warm(
            groups: groups,
            expandedCollapsedRowIDs: expandedCollapsedRowIDs,
            layoutMode: layoutMode,
            fileExtension: fileExtension,
            font: font,
            showWhitespace: showWhitespace,
            theme: theme
        )
    }

    /// Signature over everything that changes which sources get tokenized.
    /// Font and theme are excluded on purpose: spans depend only on source
    /// text and language.
    static func signature(
        groups: [DiffDisplayGroup],
        expandedCollapsedRowIDs: Set<String>,
        layoutMode: DiffLayoutMode,
        fileExtension: String,
        showWhitespace: Bool
    ) -> Int {
        var hasher = Hasher()
        for group in groups {
            hasher.combine(group.contentHash)
        }
        hasher.combine(expandedCollapsedRowIDs)
        hasher.combine(layoutMode)
        hasher.combine(fileExtension)
        hasher.combine(showWhitespace)
        return hasher.finalize()
    }

    private static func warm(
        groups: [DiffDisplayGroup],
        expandedCollapsedRowIDs: Set<String>,
        layoutMode: DiffLayoutMode,
        fileExtension: String,
        font: NSFont,
        showWhitespace: Bool,
        theme: Theme
    ) {
        for group in groups {
            let rows = DiffPaneRowProjection.visibleRows(
                in: group,
                expandedCollapsedRowIDs: expandedCollapsedRowIDs
            )
            switch layoutMode {
            case .split:
                _ = DiffPaneDocumentCache.shared.splitResult(
                    rows: rows,
                    fileExtension: fileExtension,
                    font: font,
                    showWhitespace: showWhitespace,
                    theme: theme
                )
            case .stacked:
                _ = DiffPaneDocumentCache.shared.stackedResult(
                    rows: rows,
                    fileExtension: fileExtension,
                    font: font,
                    showWhitespace: showWhitespace,
                    theme: theme
                )
            }
        }
    }
}
