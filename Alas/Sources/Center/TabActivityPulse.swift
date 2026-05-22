import SwiftUI

struct TabActivityPulse: ViewModifier {
    let activityState: ActivityState?
    @State private var previousState: ActivityState?
    @State private var pulseTrigger = false
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(animatedOpacity)
            .scaleEffect(pulseTrigger ? 1.2 : 1.0)
            .animation(breathingAnimation, value: animatedOpacity)
            .animation(.spring(duration: 0.3), value: pulseTrigger)
            .onAppear { appeared = true }
            .onChange(of: activityState) { newState in
                if newState != previousState && newState != nil && newState != .idle {
                    pulseTrigger = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        pulseTrigger = false
                    }
                }
                previousState = newState
            }
    }

    private var animatedOpacity: Double {
        guard appeared else { return 1.0 }
        return targetOpacity
    }

    var targetOpacity: Double {
        switch activityState {
        case .busy: return 0.7
        case .awaitingInput, .permissionRequest: return 0.8
        case .idle, nil: return 1.0
        }
    }

    private var breathingAnimation: Animation {
        switch activityState {
        case .busy:
            return .easeInOut(duration: 2.5).repeatForever(autoreverses: true)
        case .awaitingInput, .permissionRequest:
            return .easeInOut(duration: 3.0).repeatForever(autoreverses: true)
        case .idle, nil:
            return .easeOut(duration: 0.2)
        }
    }
}
