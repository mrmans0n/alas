import Foundation
import AlasFoundation

public enum SidebarMaterialChoice: String, CaseIterable, Codable, Equatable, Sendable {
    case none
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

    public var displayName: String {
        switch self {
        case .none: return "None — solid theme color"
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

    /// SwiftUI materials blend with the window's own content. Chat and
    /// terminal sit on the center pane's opaque background, so there they
    /// would only blur that solid color; those panes offer None and the
    /// AppKit materials, which blend with what is behind the window.
    public var showsThroughCenterPane: Bool {
        switch self {
        case .swiftUIUltraThin, .swiftUIThin, .swiftUIRegular, .swiftUIThick, .swiftUIUltraThick:
            return false
        default:
            return true
        }
    }

    public static let centerPaneChoices = allCases.filter(\.showsThroughCenterPane)

    /// A saved chat or terminal material, or `.none` when it is missing or
    /// cannot show through the center pane.
    public static func centerPaneMaterial(_ decoded: SidebarMaterialChoice?) -> SidebarMaterialChoice {
        guard let decoded, decoded.showsThroughCenterPane else { return .none }
        return decoded
    }
}
