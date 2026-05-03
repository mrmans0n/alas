import SwiftUI
import AppKit

struct TrafficLights: View {
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Dot(color: .red,    hovering: hovering, symbol: "xmark")     { closeWindow() }
            Dot(color: .yellow, hovering: hovering, symbol: "minus")     { miniaturizeWindow() }
            Dot(color: .green,  hovering: hovering, symbol: "arrow.up.left.and.arrow.down.right") { zoomWindow() }
        }
        .onHover { hovering = $0 }
    }

    private func currentWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.windows.first
    }
    private func closeWindow()       { currentWindow()?.performClose(nil) }
    private func miniaturizeWindow() { currentWindow()?.miniaturize(nil) }
    private func zoomWindow()        { currentWindow()?.performZoom(nil) }

    private struct Dot: View {
        let color: Color
        let hovering: Bool
        let symbol: String
        let action: () -> Void
        var body: some View {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(color)
                        .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 12, height: 12)
                    if hovering {
                        Image(systemName: symbol)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.black.opacity(0.6))
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}
