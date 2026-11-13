import SwiftUI
import UIKit

struct SpikeScreen: View {
    private enum Renderer: String, CaseIterable {
        case a = "A"
        case b = "B"
    }

    @State private var renderer = Renderer.a
    @State private var count = 5000
    @State private var model: SpikeTranscriptModel?
    @State private var meter = FrameMeter()

    var body: some View {
        VStack(spacing: 0) {
            controls
            if let model {
                scroller(model)
                    .id(ObjectIdentifier(model))
                    .safeAreaInset(edge: .bottom) { composer }
                    .overlay(alignment: .topTrailing) { HUD(meter: meter) }
            } else {
                Spacer()
            }
        }
        .navigationTitle("Transcript spike")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            meter.start()
            rebuild()
        }
        .onDisappear {
            meter.stop()
            model?.isStreaming = false
        }
        .onChange(of: renderer) { rebuild() }
        .onChange(of: count) { rebuild() }
    }

    private func rebuild() {
        model?.isStreaming = false
        // Scenario drivers, inert when absent: `-spikeWindowSize 20` puts the top of the window
        // (S4) a fling away; `-spikePreloadPages 23` opens 5,000 rows with the 2,000-line row in
        // the window (S2).
        let defaults = UserDefaults.standard
        let window = defaults.integer(forKey: "spikeWindowSize")
        let model = SpikeTranscriptModel(totalCount: count, windowSize: window > 0 ? window : 200)
        for _ in 0 ..< defaults.integer(forKey: "spikePreloadPages") { model.loadOlder() }
        // After the synthetic model is built: open time covers only the scroller.
        meter.markOpened(at: CACurrentMediaTime())
        self.model = model
    }

    @ViewBuilder
    private func scroller(_ model: SpikeTranscriptModel) -> some View {
        switch renderer {
        case .a: CollectionTranscriptView(model: model) { meter.markFirstLayout() }
        case .b: LazyStackTranscriptView(model: model) { meter.markFirstLayout() }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Renderer", selection: $renderer) {
                ForEach(Renderer.allCases, id: \.self) { Text($0.rawValue) }
            }
            Picker("Rows", selection: $count) {
                Text("500").tag(500)
                Text("5,000").tag(5000)
            }
            Toggle("Stream", isOn: Binding(
                get: { model?.isStreaming ?? false },
                set: { model?.isStreaming = $0 }))
                .fixedSize()
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Static, but glass over moving content is part of what the meter measures.
    private var composer: some View {
        HStack {
            Text("Message").foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "arrow.up.circle.fill").font(.title2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect()
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

/// Its own view so the once-a-second report re-evaluates only this, not the screen and scroller.
private struct HUD: View {
    let meter: FrameMeter

    var body: some View {
        let r = meter.report
        VStack(alignment: .trailing, spacing: 2) {
            Text(String(
                format: "%.0f fps  hitch %.1f ms/s\nworst %.1f ms  open %@",
                r.fps, r.hitchMsPerSecond, r.worstFrameMs, r.openMs.map { String(format: "%.0f ms", $0) } ?? "–"))
            Text("app-side hitches; confirm with Instruments").foregroundStyle(.white.opacity(0.7))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white)
        .padding(6)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
        .allowsHitTesting(false)
    }
}
