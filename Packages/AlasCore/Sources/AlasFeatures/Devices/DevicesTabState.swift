import AlasPlatform
import Foundation

/// A device the Devices tab can show: a simulator by UDID, or one of the worktree's VMs.
public enum DevicesTarget: Hashable, Sendable {
    case simulator(String)
    case vm(VMGuestOS)
}

/// Where a worktree's VM stands, as the Devices tab lists it.
public enum VMDeviceStatus: Equatable, Sendable {
    case notCreated, stopped, starting, running, pausing
    case paused(savedAt: Date)
    /// Another Alas process runs it; its label names that process.
    case runningElsewhere(label: String)
}

/// What the Devices tab shows: the switcher's rows and the stage below the toolbar.
public struct DevicesTabState: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        /// Booted or running.
        case live
        /// An agent is driving, or it is booting, starting or pausing.
        case busy
        case idle
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public let target: DevicesTarget
        public let title: String
        public let detail: String
        public let tone: Tone
        public var id: DevicesTarget { target }
    }

    public enum SimulatorStage: Equatable, Sendable {
        case booted, booting, shutDown
    }

    public enum Stage: Equatable, Sendable {
        case loading
        /// simctl failed and there are no VMs to fall back to.
        case unavailable(String)
        case noSimulators
        case simulator(SimulatorDevice, SimulatorStage)
        case vm(VMGuestOS, VMDeviceStatus)
    }

    public let selected: DevicesTarget?
    public let simulatorRows: [Row]
    /// Shown in the switcher's Simulators section when it has no rows.
    public let simulatorsNote: String?
    public let vmRows: [Row]
    public let stage: Stage

    private static let guests: [VMGuestOS] = [.macOS, .linux]

    /// `vms` holds this worktree's VMs, empty where worktree VMs aren't
    /// supported. A selection that no longer exists falls back to: the first
    /// booted simulator, a running VM, the first simulator, the macOS VM, the
    /// Linux VM. While the simulator list loads, it stops after a running VM.
    public static func resolve(
        simulators: [SimulatorDevice]?,
        listError: String?,
        vms: [VMGuestOS: VMDeviceStatus],
        selection: DevicesTarget?,
        bootingUDIDs: Set<String>,
        agentDriving: Set<DevicesTarget>
    ) -> DevicesTabState {
        // A simctl error is a finished list with nothing in it.
        let listed = listError == nil ? simulators : []
        func simulatorStage(_ device: SimulatorDevice) -> SimulatorStage {
            if bootingUDIDs.contains(device.udid) || device.state == .booting { return .booting }
            return device.state == .booted ? .booted : .shutDown
        }

        let simulatorRows = (listed ?? []).map { device in
            let stage = simulatorStage(device)
            let tone: Tone = agentDriving.contains(.simulator(device.udid)) || stage == .booting ? .busy
                : stage == .booted ? .live : .idle
            return Row(target: .simulator(device.udid), title: device.name, detail: device.runtimeName, tone: tone)
        }
        let vmRows = guests.compactMap { guest -> Row? in
            guard let status = vms[guest] else { return nil }
            let tone: Tone = switch status {
            case .starting, .pausing: .busy
            case .running: agentDriving.contains(.vm(guest)) ? .busy : .live
            case .notCreated, .stopped, .paused, .runningElsewhere: .idle
            }
            return Row(target: .vm(guest), title: title(of: guest), detail: detail(of: status), tone: tone)
        }

        let chosen = choose(selection: selection, simulators: listed, vms: vms)
        let stage: Stage = switch chosen {
        case .simulator(let udid)?:
            listed?.first { $0.udid == udid }.map { .simulator($0, simulatorStage($0)) } ?? .loading
        case .vm(let guest)?:
            vms[guest].map { .vm(guest, $0) } ?? .loading
        case nil:
            if let listError { .unavailable(listError) } else if listed == nil { .loading } else { .noSimulators }
        }
        let note: String? = if listError != nil {
            "Install Xcode to use iOS simulators"
        } else if listed?.isEmpty == true {
            "No iOS simulators"
        } else {
            nil
        }
        return DevicesTabState(
            selected: chosen, simulatorRows: simulatorRows, simulatorsNote: note, vmRows: vmRows, stage: stage
        )
    }

    private static func choose(
        selection: DevicesTarget?, simulators: [SimulatorDevice]?, vms: [VMGuestOS: VMDeviceStatus]
    ) -> DevicesTarget? {
        switch selection {
        case .simulator(let udid)? where simulators?.contains(where: { $0.udid == udid }) == true:
            return selection
        case .vm(let guest)? where vms[guest] != nil:
            return selection
        default:
            break
        }
        if let booted = simulators?.first(where: { $0.state == .booted }) { return .simulator(booted.udid) }
        if let running = guests.first(where: { vms[$0] == .running }) { return .vm(running) }
        // Still loading: wait for the list rather than settle on a stopped VM.
        guard let simulators else { return nil }
        if let first = simulators.first { return .simulator(first.udid) }
        return guests.first { vms[$0] != nil }.map { .vm($0) }
    }

    private static func title(of guest: VMGuestOS) -> String {
        switch guest {
        case .macOS: "macOS VM"
        case .linux: "Linux VM"
        }
    }

    private static func detail(of status: VMDeviceStatus) -> String {
        switch status {
        case .notCreated: "Not created"
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .pausing: "Pausing"
        case .paused: "Paused"
        case .runningElsewhere(let label): "In \(label)"
        }
    }
}
