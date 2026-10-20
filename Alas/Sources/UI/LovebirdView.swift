import Lottie
import SwiftUI

/// The Alas lovebird. Each pose is a Lottie exported from the matching
/// Cavalry scene in `assets/` (`lovebird*.cv`). Reduce Motion holds a resting
/// frame; a missing resource falls back to the bird symbol.
struct LovebirdView: View {
    enum Pose: String {
        /// Sways on the twig, tilts its head, blinks.
        case idle = "lovebird"
        /// Hops with a wing flap once, then idles.
        case hello = "lovebird-hello"
        /// Hops along the twig and looks around.
        case waiting = "lovebird-waiting"
        /// Dozes with a snot bubble and drifting Z's.
        case sleeping = "lovebird-sleeping"

        /// Frames before this play once; the loop runs from here to the end.
        var loopStartFrame: AnimationFrameTime { self == .hello ? 45 : 0 }
    }

    let pose: Pose
    var size: CGFloat = 64

    @State private var introDone = false
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let animation = LottieAnimation.named(pose.rawValue) {
            LottieView(animation: animation)
                .playbackMode(playbackMode(endFrame: animation.endFrame))
                .animationDidFinish { completed in
                    if completed { introDone = true }
                }
                .resizable()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "bird.fill")
                .font(.system(size: size * 0.45))
                .foregroundStyle(theme.color("accent").gradient)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    private func playbackMode(endFrame: AnimationFrameTime) -> LottiePlaybackMode {
        let loopStart = pose.loopStartFrame
        if reduceMotion {
            return .paused(at: .frame(loopStart))
        }
        if loopStart > 0, !introDone {
            return .playing(.fromFrame(0, toFrame: loopStart, loopMode: .playOnce))
        }
        return .playing(.fromFrame(loopStart, toFrame: endFrame, loopMode: .loop))
    }
}
