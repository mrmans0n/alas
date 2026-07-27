import SwiftUI

enum GGStackIconVariant: Equatable {
    case stack
    case disabled
}

struct GGStackIcon: View {
    nonisolated static let systemName = "square.stack.3d.up"

    let variant: GGStackIconVariant
    let size: CGFloat
    let color: Color

    init(
        variant: GGStackIconVariant = .stack,
        size: CGFloat,
        color: Color
    ) {
        self.variant = variant
        self.size = size
        self.color = color
    }

    var body: some View {
        ZStack {
            Image(systemName: Self.systemName)
                .resizable()
                .scaledToFit()
                .foregroundStyle(color)
            if variant == .disabled {
                Capsule()
                    .fill(color)
                    .frame(width: 1, height: size)
                    .rotationEffect(.degrees(-45))
            }
        }
        .frame(width: size, height: size)
    }
}
