/// What the Device tab shows, from the latest device list and the user's choice.
public enum DevicePaneStatus: Equatable, Sendable {
    case loading
    /// simctl failed. The message is its error output.
    case unavailable(String)
    case noDevices
    /// Nothing chosen and nothing booted.
    case choose
    case shutDown(SimulatorDevice)
    case booting(SimulatorDevice)
    case streaming(SimulatorDevice)

    public var device: SimulatorDevice? {
        switch self {
        case .shutDown(let device), .booting(let device), .streaming(let device): device
        case .loading, .unavailable, .noDevices, .choose: nil
        }
    }

    /// A chosen device that no longer exists falls back to the first booted
    /// one. A chosen device that is shut down stays chosen, so the pane offers
    /// to boot it instead of jumping to another simulator.
    public static func resolve(
        devices: [SimulatorDevice]?,
        listError: String?,
        selectedUDID: String?,
        bootingUDIDs: Set<String>
    ) -> DevicePaneStatus {
        if let listError { return .unavailable(listError) }
        guard let devices else { return .loading }
        guard !devices.isEmpty else { return .noDevices }
        let chosen = selectedUDID.flatMap { udid in devices.first { $0.udid == udid } }
            ?? devices.first { $0.state == .booted }
        guard let chosen else { return .choose }
        if bootingUDIDs.contains(chosen.udid) || chosen.state == .booting { return .booting(chosen) }
        return chosen.state == .booted ? .streaming(chosen) : .shutDown(chosen)
    }
}
