import SwiftUI
import AppKit

enum SidebarMaterialChoice: String, CaseIterable, Codable, Equatable {
    case appKitAppearanceBased
    case appKitLight
    case appKitDark
    case appKitTitlebar
    case appKitSelection
    case appKitMenu
    case appKitPopover
    case appKitSidebar
    case appKitMediumLight
    case appKitUltraDark
    case appKitHeaderView
    case appKitSheet
    case appKitWindowBackground
    case appKitHudWindow
    case appKitFullScreenUI
    case appKitToolTip
    case appKitContentBackground
    case appKitUnderWindowBackground
    case appKitUnderPageBackground
    case swiftUIUltraThin
    case swiftUIThin
    case swiftUIRegular
    case swiftUIThick
    case swiftUIUltraThick

    var displayName: String {
        switch self {
        case .appKitAppearanceBased: return "AppKit: Appearance Based"
        case .appKitLight: return "AppKit: Light"
        case .appKitDark: return "AppKit: Dark"
        case .appKitTitlebar: return "AppKit: Titlebar"
        case .appKitSelection: return "AppKit: Selection"
        case .appKitMenu: return "AppKit: Menu"
        case .appKitPopover: return "AppKit: Popover"
        case .appKitSidebar: return "AppKit: Sidebar"
        case .appKitMediumLight: return "AppKit: Medium Light"
        case .appKitUltraDark: return "AppKit: Ultra Dark"
        case .appKitHeaderView: return "AppKit: Header View"
        case .appKitSheet: return "AppKit: Sheet"
        case .appKitWindowBackground: return "AppKit: Window Background"
        case .appKitHudWindow: return "AppKit: HUD Window"
        case .appKitFullScreenUI: return "AppKit: Full Screen UI"
        case .appKitToolTip: return "AppKit: Tool Tip"
        case .appKitContentBackground: return "AppKit: Content Background"
        case .appKitUnderWindowBackground: return "AppKit: Under Window Background"
        case .appKitUnderPageBackground: return "AppKit: Under Page Background"
        case .swiftUIUltraThin: return "SwiftUI: Ultra Thin"
        case .swiftUIThin: return "SwiftUI: Thin"
        case .swiftUIRegular: return "SwiftUI: Regular"
        case .swiftUIThick: return "SwiftUI: Thick"
        case .swiftUIUltraThick: return "SwiftUI: Ultra Thick"
        }
    }

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

    var body: some View {
        if let material = choice.appKitMaterial {
            VisualEffectView(material: material, blendingMode: .behindWindow)
        } else if let material = choice.swiftUIMaterial {
            Rectangle()
                .fill(.clear)
                .background(material)
        }
    }
}
