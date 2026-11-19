import Foundation

/// The Devices rail: the running devices one under the other, each expanded
/// to its screen, collapsed to its header, or moved to a center tab.
public enum DevicesRail {
    public enum Placement: Equatable, Sendable {
        case expanded, collapsed
        /// A center tab shows it; the rail keeps a one-line placeholder.
        case inCenter
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public let device: DevicesTabState.Running
        public let placement: Placement
        public var id: DevicesTarget { device.id }
    }

    /// A center tab wins over collapsing. Targets that don't run are ignored.
    public static func entries(
        _ running: [DevicesTabState.Running], collapsed: Set<DevicesTarget>, inCenter: Set<DevicesTarget>
    ) -> [Entry] {
        running.map { device in
            let placement: Placement = inCenter.contains(device.id) ? .inCenter
                : collapsed.contains(device.id) ? .collapsed : .expanded
            return Entry(device: device, placement: placement)
        }
    }

    /// The running device a center device tab shows: the one it was opened
    /// for, else, for an emulator that booted again under another serial, the
    /// one from its AVD.
    public static func device(
        forTab deviceID: String, avdName: String?, in running: [DevicesTabState.Running]
    ) -> DevicesTabState.Running? {
        if let same = running.first(where: { $0.id == .simulator(deviceID) || $0.id == .android(deviceID) }) {
            return same
        }
        guard let avdName else { return nil }
        return running.first { device in
            guard case .android(let target, _) = device.screen else { return false }
            return target.avdName == avdName
        }
    }
}

/// How tall each expanded device's stage is in the Devices rail. One fills the
/// rail; two or more split it in two, and the rest scroll.
public struct DevicesRailLayout: Equatable, Sendable {
    /// A header, collapsed device or placeholder, with the gap under it.
    public static let rowHeight: Double = 36
    public static let minimumStageHeight: Double = 200

    /// The space a stage adds around its screen.
    public struct Chrome: Equatable, Sendable {
        public let horizontal: Double
        public let vertical: Double

        public init(horizontal: Double, vertical: Double) {
            self.horizontal = horizontal
            self.vertical = vertical
        }
    }

    /// The height each expanded stage may take.
    public let stageHeight: Double
    /// Two or more stages: each shrinks to its screen's fitted height.
    public let fitsScreens: Bool

    /// `visibleHeight` is the scroll view's, less its padding.
    public init(visibleHeight: Double, entries: [DevicesRail.Entry]) {
        let expanded = entries.filter { $0.placement == .expanded }.count
        let shown = Double(min(max(expanded, 1), 2))
        let rows = Double(entries.count - expanded) + shown
        stageHeight = max(Self.minimumStageHeight, ((visibleHeight - rows * Self.rowHeight) / shown).rounded(.down))
        fitsScreens = expanded > 1
    }

    /// The stage's height for a screen of `aspect` (height over width, as
    /// shown) in a rail `width` wide; the whole stage height without one.
    public func height(width: Double, aspect: Double?, chrome: Chrome) -> Double {
        guard fitsScreens, let aspect, aspect > 0 else { return stageHeight }
        return min(stageHeight, ((width - chrome.horizontal) * aspect + chrome.vertical).rounded(.up))
    }
}
