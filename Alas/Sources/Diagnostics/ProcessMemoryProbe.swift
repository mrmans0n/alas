#if DEBUG
import Darwin
import Foundation

/// Reads the kernel-reported `phys_footprint` for the current process. This is
/// the same number Activity Monitor displays as "Memory" and Xcode shows as
/// "Memory Use" — the most faithful single-number representation of the
/// process's memory pressure.
enum ProcessMemoryProbe {
    /// Returns 0 if the syscall fails (rare; logged at the call site if needed).
    static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }
}
#endif
