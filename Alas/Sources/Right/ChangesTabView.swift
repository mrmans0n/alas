import SwiftUI

struct ChangesTabView: View {
    @Bindable var rps: RightPaneState
    let onSelect: (ChangedFile) -> Void
    let onSelectCommit: (CommitInfo) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                WorkingTreeSectionView(
                    changes: rps.changes,
                    expanded: $rps.workingTreeExpanded,
                    onSelect: onSelect,
                    onToggleStage: { rps.toggleStage($0) },
                    onStageAll: { rps.stageAll($0) },
                    onUnstageAll: { rps.unstageAll($0) }
                )
                Divider().opacity(0.4)
                CommitsSectionView(
                    commits: rps.commits,
                    comparisonRef: rps.comparisonRef,
                    expanded: $rps.commitsExpanded,
                    onSelect: onSelectCommit
                )
            }
        }
    }
}
