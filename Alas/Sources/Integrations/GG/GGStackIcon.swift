import SwiftUI

enum GGStackIconVariant: Equatable {
    case stack
    case disabled
}

struct GGStackIcon: View {
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
            GGStackShape()
                .fill(color)
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

private struct GGStackShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let strokeHeight = min(rect.height / 9, 1)
        let strokeWidth = min(rect.width, 7)
        let x = rect.midX - strokeWidth / 2
        let yPositions = [
            rect.minY + 1,
            rect.midY - strokeHeight / 2,
            rect.maxY - strokeHeight - 1,
        ]

        for y in yPositions {
            path.addRoundedRect(
                in: CGRect(x: x, y: y, width: strokeWidth, height: strokeHeight),
                cornerSize: CGSize(width: strokeHeight / 2, height: strokeHeight / 2)
            )
        }
        return path
    }
}
