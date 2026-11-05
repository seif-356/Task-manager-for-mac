import Darwin
import Foundation

/// Thin wrappers around libproc. None of these need root, but `usage(_:)`
/// only succeeds for processes owned by the current user.
enum ProcessSampler {
    struct BSDInfo {
        let parentPID: pid_t
        let uid: uid_t
        let command: String
    }

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(min(Int(count), pids.count)))
    }

    /// Works for every process, including root-owned ones.
    static func bsdInfo(_ pid: pid_t) -> BSDInfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return BSDInfo(
            parentPID: pid_t(truncatingIfNeeded: info.pbsi_ppid),
            uid: info.pbsi_uid,
            command: cString(info.pbsi_comm)
        )
    }

    static func path(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// CPU time, memory footprint and disk I/O. Fails (nil) for other users' processes.
    static func usage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        return result == 0 ? info : nil
    }

    /// Converts a fixed-size C char array (imported as a tuple) to a String.
    static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
