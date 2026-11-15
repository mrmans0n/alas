import AlasCore
import SwiftUI

/// The screen's accessibility elements outlined over it, with the one under the
/// pointer described. Reads the tree once per `readKey` change, a second after
/// it, and on Refresh; never continuously, since a read takes up to 2 s.
struct DeviceAccessibilityOverlay: View {
    let udid: String
    let client: SimulatorStreamClient
    /// Changes after the user's input or a rotation.
    let readKey: Int
    /// The pointer, in top-left-origin view points.
    let hover: CGPoint?
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var snapshot: DeviceSnapshot?
    @State private var reading = false
    @State private var readError: String?

    var body: some View {
        GeometryReader { geometry in
            let boxes = snapshot.map { AccessibilityOverlayLayout.boxes($0, in: geometry.size) } ?? []
            let hovered = hover.flatMap { AccessibilityOverlayLayout.hovered(boxes, at: $0) }
            ZStack(alignment: .topLeading) {
                ForEach(boxes, id: \.element.ref) { box in
                    let tone = theme.color(box.unlabelled ? "warn" : "accent")
                    Rectangle()
                        .fill(tone.opacity(box == hovered ? 0.15 : 0))
                        .overlay(Rectangle().strokeBorder(tone, lineWidth: box == hovered ? 2 : 1))
                        .frame(width: box.rect.width, height: box.rect.height)
                        .offset(x: box.rect.minX, y: box.rect.minY)
                }
                .allowsHitTesting(false)
                // The card sits in the half of the screen away from the element it describes.
                VStack {
                    if let hovered, hovered.rect.midY > geometry.size.height / 2 { card(hovered) }
                    Spacer(minLength: 0)
                    if let hovered, hovered.rect.midY <= geometry.size.height / 2 { card(hovered) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(scale.space[3])
                .allowsHitTesting(false)
                refreshButton
                    .padding(scale.space[2])
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .task(id: readKey) {
            // The first read is immediate; later ones wait for the screen to settle.
            if snapshot != nil { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled else { return }
            await read()
        }
    }

    private func card(_ box: AccessibilityOverlayLayout.Box) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(box.element.role).font(scale.caption.font(weight: .semibold))
            if let label = box.element.label { Text("Label: \(label)") }
            if let value = box.element.value { Text("Value: \(value)") }
            if let id = box.element.id { Text("ID: \(id)") }
            if box.unlabelled {
                Text("No label: VoiceOver reads its type only.").foregroundStyle(theme.color("warn"))
            }
        }
        .font(scale.caption.font)
        .foregroundStyle(theme.color("fg"))
        .lineLimit(2)
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: scale.radius.medium))
        .overlay(RoundedRectangle(cornerRadius: scale.radius.medium).strokeBorder(theme.color("line"), lineWidth: 0.5))
    }

    private var refreshButton: some View {
        Button {
            Task { await read() }
        } label: {
            HStack(spacing: 4) {
                if reading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(readError == nil ? "Refresh" : "Couldn't read: retry")
            }
            .font(scale.caption.font)
            .foregroundStyle(theme.color("fg"))
            .padding(.horizontal, scale.space[2])
            .padding(.vertical, 2)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(readError ?? "Read the screen's accessibility elements again")
        .disabled(reading)
    }

    private func read() async {
        reading = true
        defer { reading = false }
        do {
            snapshot = try DeviceSnapshot.parse(try await client.describe(udid: udid), generation: 0)
            readError = nil
        } catch {
            readError = error.localizedDescription
        }
    }
}
