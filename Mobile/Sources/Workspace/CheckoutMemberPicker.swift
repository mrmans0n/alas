import AlasRemoteKit
import SwiftUI

/// A workspace checkout's member repositories as a row of chips; the selected one is the
/// repository Changes and Files read.
struct CheckoutMemberPicker: View {
    let workspace: SessionWorkspace
    let members: [RemoteSessionCheckout.Member]

    var body: some View {
        let focused = workspace.focusedMemberID
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(members) { member in
                    MemberChip(member: member, isSelected: member.id == focused) { workspace.focusMember(member.id) }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

private struct MemberChip: View {
    let member: RemoteSessionCheckout.Member
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 5) {
                Image(systemName: "folder").imageScale(.small)
                Text(member.name).fontWeight(.medium)
                if !member.worktree.branch.isEmpty {
                    Text(member.worktree.branch).foregroundStyle(isSelected ? Color.accentColor.opacity(0.8) : .secondary)
                }
            }
            .font(.footnote)
            .lineLimit(1)
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(isSelected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemFill))
                if isSelected { Capsule().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 0.5) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(member.name)
        .accessibilityValue(member.worktree.branch)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Shows `content`, a tab reading the session's repository; in a workspace checkout, under the
/// member picker, or in place of it when no member can be opened.
struct CheckoutScope<Content: View>: View {
    let workspace: SessionWorkspace
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let checkout = workspace.checkout {
            if checkout.members.isEmpty {
                ContentUnavailableView("No repositories available", systemImage: "folder.badge.questionmark",
                                       description: Text("This workspace checkout has no repository the phone can open."))
            } else {
                content().safeAreaInset(edge: .top, spacing: 0) {
                    CheckoutMemberPicker(workspace: workspace, members: checkout.members)
                }
            }
        } else {
            content()
        }
    }
}
