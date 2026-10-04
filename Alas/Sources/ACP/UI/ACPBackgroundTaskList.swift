import SwiftUI

struct ACPBackgroundTaskList: View {
    let tasks: [ACPBackgroundTask]
    let canStop: Bool
    let stop: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(tasks) { task in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: task.state == "paused" ? "pause.circle" : "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.name).lineLimit(1)
                        Text(task.stopError ?? task.summary ?? task.description ?? task.state)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if canStop && task.canStop {
                        Button("Stop") { stop(task.id) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Stop background task \(task.name)")
                    }
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Background work")
    }
}
