import AlasPlatform
import Foundation

/// A device the Devices tab can show: a simulator by UDID, or one of the worktree's VMs.
public enum DevicesTarget: Hashable, Sendable {
    case simulator(String)
    case vm(VMGuestOS)
    /// An Android device by serial, or an AVD that isn't running as "avd:<name>".
    case android(String)
}

/// Which kind of device a switcher row is.
public enum DevicesPlatform: Hashable, Sendable {
    case ios, android, vm(VMGuestOS)
}

/// Where a worktree's VM stands, as the Devices tab lists it.
public enum VMDeviceStatus: Equatable, Sendable {
    case notCreated, stopped, starting, running, pausing
    case paused(savedAt: Date)
    /// Another Alas process runs it; its label names that process.
    case runningElsewhere(label: String)
}

/// The Android devices the tab lists, or why there are none.
public struct AndroidListing: Equatable, Sendable {
    public let devices: [AndroidDevice]
    /// Every AVD, running or not.
    public let avds: [String]
    public let bootingAVDs: Set<String>
    /// Shown instead of rows: the SDK is missing, or adb failed.
    public let note: String?

    public init(devices: [AndroidDevice], avds: [String], bootingAVDs: Set<String>, note: String?) {
        self.devices = devices
        self.avds = avds
        self.bootingAVDs = bootingAVDs
        self.note = note
    }

    public static func avdID(_ name: String) -> String { "avd:" + name }
}

public enum AndroidStage: Equatable, Sendable {
    case ready, booting, shutDown, unauthorized, offline
}

public struct AndroidTarget: Equatable, Sendable {
    /// `DevicesTarget.android`'s value.
    public let id: String
    public let title: String
    /// The connected device; nil for an AVD that isn't running.
    public let device: AndroidDevice?
    public let avdName: String?

    public init(id: String, title: String, device: AndroidDevice?, avdName: String?) {
        self.id = id
        self.title = title
        self.device = device
        self.avdName = avdName
    }
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
        public let platform: DevicesPlatform
        /// The state in words: "Booted", "Claude driving", "Stopped".
        public let status: String
        /// A simulator or AVD that is shut down and can be started from the row.
        public let canBoot: Bool
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
        case android(AndroidTarget, AndroidStage)
    }

    /// What a running device's entry in the Devices rail shows.
    public enum Screen: Equatable, Sendable {
        /// Booted or booting.
        case simulator(SimulatorDevice, SimulatorStage)
        /// Connected (ready, booting, unauthorized or offline), or an AVD booting.
        case android(AndroidTarget, AndroidStage)
        /// Running, starting or pausing.
        case vm(VMGuestOS, VMDeviceStatus)
    }

    /// A device that is up or coming up, as the Devices rail stacks it.
    public struct Running: Equatable, Sendable, Identifiable {
        public let row: Row
        public let screen: Screen
        public var id: DevicesTarget { row.target }
    }

    /// What the rail shows when nothing runs.
    public enum Empty: Equatable, Sendable {
        case loading
        /// simctl failed, and there are no Android devices or VMs to list.
        case unavailable(String)
        /// No simulators, Android devices or VMs at all.
        case noSimulators
        /// Devices exist, but none runs; `suggested` is the one to offer.
        case nothingRunning(suggested: Row?)
    }

    public let selected: DevicesTarget?
    public let simulatorRows: [Row]
    /// Shown in the switcher's Simulators section when it has no rows.
    public let simulatorsNote: String?
    public let androidRows: [Row]
    /// Shown in the switcher's Android section instead of rows.
    public let androidNote: String?
    public let vmRows: [Row]
    public let stage: Stage
    /// iOS simulators, then Android devices, then VMs; by name within each.
    public let running: [Running]
    /// Nil while something runs.
    public let empty: Empty?

    /// The row for `selected`, as the switcher's chip shows it.
    public var selectedRow: Row? {
        (simulatorRows + androidRows + vmRows).first { $0.target == selected }
    }

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
        agentDriving: Set<DevicesTarget>,
        android: AndroidListing? = nil,
        agentNames: [DevicesTarget: String] = [:]
    ) -> DevicesTabState {
        func agentStatus(_ target: DevicesTarget) -> String? {
            guard agentDriving.contains(target) else { return nil }
            return agentNames[target].map { "\($0) driving" } ?? "Agent driving"
        }
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
            let target = DevicesTarget.simulator(device.udid)
            let driven = agentStatus(target)
            let stageText: String = switch stage {
            case .booted: "Booted"
            case .booting: "Booting"
            case .shutDown: "Shut down"
            }
            let status = driven ?? stageText
            return Row(
                target: target, title: device.name, detail: device.runtimeName, tone: tone,
                platform: .ios, status: status, canBoot: driven == nil && stage == .shutDown
            )
        }
        let vmRows = guests.compactMap { guest -> Row? in
            guard let status = vms[guest] else { return nil }
            let tone: Tone = switch status {
            case .starting, .pausing: .busy
            case .running: agentDriving.contains(.vm(guest)) ? .busy : .live
            case .notCreated, .stopped, .paused, .runningElsewhere: .idle
            }
            return Row(
                target: .vm(guest), title: title(of: guest), detail: detail(of: status), tone: tone,
                platform: .vm(guest), status: agentStatus(.vm(guest)) ?? detail(of: status), canBoot: false
            )
        }

        let androidEntries = Self.androidEntries(android)
        let androidRows = androidEntries.map { entry in
            let target = DevicesTarget.android(entry.target.id)
            let driven = agentStatus(target)
            let detail = Self.detail(of: entry.stage, device: entry.target.device)
            return Row(
                target: target, title: entry.target.title, detail: detail,
                tone: agentDriving.contains(target) || entry.stage == .booting ? .busy
                    : entry.stage == .ready ? .live : .idle,
                platform: .android,
                status: driven ?? (entry.stage == .ready ? "Booted" : detail),
                canBoot: driven == nil && entry.stage == .shutDown
            )
        }
        let chosen = choose(selection: selection, simulators: listed, vms: vms, android: androidEntries)
        let stage: Stage = switch chosen {
        case .simulator(let udid)?:
            listed?.first { $0.udid == udid }.map { .simulator($0, simulatorStage($0)) } ?? .loading
        case .vm(let guest)?:
            vms[guest].map { .vm(guest, $0) } ?? .loading
        case .android(let id)?:
            androidEntries.first { $0.target.id == id }.map { .android($0.target, $0.stage) } ?? .loading
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
        func byName(_ lhs: Running, _ rhs: Running) -> Bool {
            let byTitle = lhs.row.title.localizedStandardCompare(rhs.row.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            return "\(lhs.row.detail) \(lhs.id)" < "\(rhs.row.detail) \(rhs.id)"
        }
        let runningSimulators = zip(listed ?? [], simulatorRows).compactMap { device, row -> Running? in
            let stage = simulatorStage(device)
            return stage == .shutDown ? nil : Running(row: row, screen: .simulator(device, stage))
        }
        let runningAndroid = zip(androidEntries, androidRows).compactMap { entry, row -> Running? in
            entry.stage == .shutDown ? nil : Running(row: row, screen: .android(entry.target, entry.stage))
        }
        let runningVMs = vmRows.compactMap { row -> Running? in
            guard case .vm(let guest) = row.target, let status = vms[guest] else { return nil }
            switch status {
            case .running, .starting, .pausing: return Running(row: row, screen: .vm(guest, status))
            case .notCreated, .stopped, .paused, .runningElsewhere: return nil
            }
        }
        let running = runningSimulators.sorted(by: byName) + runningAndroid.sorted(by: byName) + runningVMs

        let offerable = simulatorRows.filter(\.canBoot) + androidRows.filter(\.canBoot) + vmRows
        let suggested = offerable.first { $0.target == selection } ?? offerable.first
        let empty: Empty? = if !running.isEmpty {
            nil
        } else if listed == nil {
            .loading
        } else if let listError, androidRows.isEmpty, vmRows.isEmpty {
            .unavailable(listError)
        } else if simulatorRows.isEmpty, androidRows.isEmpty, vmRows.isEmpty {
            .noSimulators
        } else {
            .nothingRunning(suggested: suggested)
        }
        return DevicesTabState(
            selected: chosen, simulatorRows: simulatorRows, simulatorsNote: note,
            androidRows: androidRows, androidNote: android?.note, vmRows: vmRows, stage: stage,
            running: running, empty: empty
        )
    }

    private static func choose(
        selection: DevicesTarget?, simulators: [SimulatorDevice]?, vms: [VMGuestOS: VMDeviceStatus],
        android: [(target: AndroidTarget, stage: AndroidStage)]
    ) -> DevicesTarget? {
        switch selection {
        case .simulator(let udid)? where simulators?.contains(where: { $0.udid == udid }) == true:
            return selection
        case .vm(let guest)? where vms[guest] != nil:
            return selection
        case .android(let id)? where android.contains(where: { $0.target.id == id }):
            return selection
        case .android(let id)? where id.hasPrefix("avd:"):
            // The AVD booted: follow it to its emulator.
            let name = String(id.dropFirst(4))
            if let running = android.first(where: { $0.target.avdName == name && $0.target.device != nil }) {
                return .android(running.target.id)
            }
        default:
            break
        }
        if let booted = simulators?.first(where: { $0.state == .booted }) { return .simulator(booted.udid) }
        if let ready = android.first(where: { $0.stage == .ready }) { return .android(ready.target.id) }
        if let running = guests.first(where: { vms[$0] == .running }) { return .vm(running) }
        // Still loading: wait for the list rather than settle on a stopped VM.
        guard let simulators else { return nil }
        if let first = simulators.first { return .simulator(first.udid) }
        if let first = android.first { return .android(first.target.id) }
        return guests.first { vms[$0] != nil }.map { .vm($0) }
    }

    /// Connected devices first (emulators still coming up are left out), then
    /// the AVDs that aren't running.
    private static func androidEntries(_ listing: AndroidListing?) -> [(target: AndroidTarget, stage: AndroidStage)] {
        guard let listing, listing.note == nil else { return [] }
        let devices = listing.devices.filter { !($0.isEmulator && $0.state == .offline) }
        var entries = devices.map { device -> (target: AndroidTarget, stage: AndroidStage) in
            let stage: AndroidStage = switch device.state {
            case .ready: device.avdName.map(listing.bootingAVDs.contains) == true ? .booting : .ready
            case .unauthorized: .unauthorized
            case .offline: .offline
            }
            return (AndroidTarget(id: device.serial, title: device.title, device: device, avdName: device.avdName), stage)
        }
        let running = Set(devices.compactMap(\.avdName))
        entries += listing.avds.filter { !running.contains($0) }.map { name in
            (
                AndroidTarget(
                    id: AndroidListing.avdID(name), title: name.replacingOccurrences(of: "_", with: " "),
                    device: nil, avdName: name
                ),
                listing.bootingAVDs.contains(name) ? .booting : .shutDown
            )
        }
        return entries
    }

    private static func detail(of stage: AndroidStage, device: AndroidDevice?) -> String {
        switch stage {
        case .ready: device?.release.map { "Android \($0)" } ?? "Android"
        case .booting: "Booting"
        case .shutDown: "Shut down"
        case .unauthorized: "Allow USB debugging"
        case .offline: "Offline"
        }
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
