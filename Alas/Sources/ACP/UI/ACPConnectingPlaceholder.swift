import SwiftUI

/// Skeleton transcript shown while we're spawning the agent process and
/// running `initialize` + `session/new`. Replaces the bare empty pane so
/// the user knows something's happening between tab open and the first
/// agent token.
struct ACPConnectingPlaceholder: View {
    let agentDisplayName: String
    @Environment(\.theme) private var theme
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            statusHeader
            skeletonBlock(lineCount: 3, widths: [0.78, 0.55, 0.42])
            skeletonBlock(lineCount: 2, widths: [0.62, 0.34])
            skeletonToolRow
            skeletonBlock(lineCount: 4, widths: [0.86, 0.71, 0.48, 0.30])
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            LinearGradient(
                colors: [theme.color("bg-1"), theme.color("bg-0")],
                startPoint: .top, endPoint: .bottom
            )
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            Spinner().frame(width: 14, height: 14)
            Text("Connecting to \(agentDisplayName)…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.color("fg-muted"))
        }
        .padding(.bottom, 4)
    }

    private var skeletonToolRow: some View {
        HStack(spacing: 8) {
            shimmerRect.frame(width: 18, height: 18).clipShape(RoundedRectangle(cornerRadius: 4))
            shimmerRect.frame(width: 48, height: 10).clipShape(RoundedRectangle(cornerRadius: 3))
            shimmerRect.frame(width: 140, height: 16).clipShape(RoundedRectangle(cornerRadius: 5))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(theme.color("bg-1").opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color("line"), lineWidth: 0.5))
    }

    private func skeletonBlock(lineCount: Int, widths: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<lineCount, id: \.self) { i in
                let w = i < widths.count ? widths[i] : 0.5
                GeometryReader { geo in
                    shimmerRect
                        .frame(width: geo.size.width * w, height: 11)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .frame(height: 11)
            }
        }
    }

    private var shimmerRect: some View {
        LinearGradient(
            colors: [
                theme.color("bg-3").opacity(pulse ? 0.65 : 0.35),
                theme.color("bg-2").opacity(pulse ? 0.45 : 0.30),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }
}
