import SwiftUI

struct ChangesTabView: View {
    @Bindable var rps: RightPaneState
    let onSelect: (ChangedFile) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                WorkingTreeSectionView(
                    changes: rps.changes,
                    expanded: $rps.workingTreeExpanded,
                    onSelect: onSelect
                )
                Divider().opacity(0.4)
                CommitsSectionView(
                    commits: rps.commits,
                    upstreamRef: rps.upstreamRef,
                    expanded: $rps.commitsExpanded
                )
            }
        }
    }
}
