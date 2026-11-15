#if DEBUG
import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// Reads the kernel-reported `phys_footprint` for the current process. This is
/// the same number Activity Monitor displays as "Memory" and Xcode shows as
/// "Memory Use" — the most faithful single-number representation of the
/// process's memory pressure.
public enum ProcessMemoryProbe {
    /// Returns 0 if the syscall fails (rare; logged at the call site if needed).
    public static func physFootprint() -> UInt64 {
        #if !canImport(Darwin)
        // Linux: resident set size, the closest equivalent (`VmRSS`, in kB).
        guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8),
              let line = status.split(separator: "\n").first(where: { $0.hasPrefix("VmRSS:") }),
              let kilobytes = UInt64(line.split(separator: " ").dropFirst().first ?? "") else { return 0 }
        return kilobytes * 1024
        #else
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
        #endif
    }
}
#endif
