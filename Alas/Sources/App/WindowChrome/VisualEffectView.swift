import SwiftUI
import AppKit

extension SidebarMaterialChoice {
    var appKitMaterial: NSVisualEffectView.Material? {
        switch self {
        case .appKitAppearanceBased: return NSVisualEffectView.Material(rawValue: 0)
        case .appKitLight: return NSVisualEffectView.Material(rawValue: 1)
        case .appKitDark: return NSVisualEffectView.Material(rawValue: 2)
        case .appKitTitlebar: return .titlebar
        case .appKitSelection: return .selection
        case .appKitMenu: return .menu
        case .appKitPopover: return .popover
        case .appKitSidebar: return .sidebar
        case .appKitMediumLight: return NSVisualEffectView.Material(rawValue: 8)
        case .appKitUltraDark: return NSVisualEffectView.Material(rawValue: 9)
        case .appKitHeaderView: return .headerView
        case .appKitSheet: return .sheet
        case .appKitWindowBackground: return .windowBackground
        case .appKitHudWindow: return .hudWindow
        case .appKitFullScreenUI: return .fullScreenUI
        case .appKitToolTip: return .toolTip
        case .appKitContentBackground: return .contentBackground
        case .appKitUnderWindowBackground: return .underWindowBackground
        case .appKitUnderPageBackground: return .underPageBackground
        case .none:
            return nil
        case .swiftUIUltraThin, .swiftUIThin, .swiftUIRegular, .swiftUIThick, .swiftUIUltraThick:
            return nil
        }
    }

    var swiftUIMaterial: Material? {
        switch self {
        case .swiftUIUltraThin: return .ultraThin
        case .swiftUIThin: return .thin
        case .swiftUIRegular: return .regular
        case .swiftUIThick: return .thick
        case .swiftUIUltraThick: return .ultraThick
        default: return nil
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    init(material: NSVisualEffectView.Material = .sidebar,
         blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blendingMode = blendingMode
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct SidebarMaterialBackground: View {
    let choice: SidebarMaterialChoice
    /// 0…1 alpha for a theme-colored overlay painted on top of the
    /// material. Ignored when `choice == .none` (the rectangle below is
    /// already opaque). 0 = pure material (today's look).
    var backgroundOpacity: Double = 0
    @Environment(\.theme) var theme

    var body: some View {
        ZStack {
            if choice == .none {
                Rectangle().fill(theme.color("bg-0"))
            } else if let material = choice.appKitMaterial {
                VisualEffectView(material: material, blendingMode: .behindWindow)
                Rectangle()
                    .fill(theme.color("bg-0"))
                    .opacity(clamp01(backgroundOpacity))
                    .allowsHitTesting(false)
            } else if let material = choice.swiftUIMaterial {
                Rectangle().fill(.clear).background(material)
                Rectangle()
                    .fill(theme.color("bg-0"))
                    .opacity(clamp01(backgroundOpacity))
                    .allowsHitTesting(false)
            }
        }
    }

    private func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }
}
