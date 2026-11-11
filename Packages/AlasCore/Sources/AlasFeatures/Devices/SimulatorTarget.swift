/// Which simulator a run script's app goes to.
public enum SimulatorTarget {
    /// The selected simulator, else the first booted one, else the first one;
    /// nil when there are none.
    public static func choose(selection: DevicesTarget?, simulators: [SimulatorDevice]) -> SimulatorDevice? {
        if case .simulator(let udid)? = selection, let selected = simulators.first(where: { $0.udid == udid }) {
            return selected
        }
        return simulators.first { $0.state == .booted } ?? simulators.first
    }
}
