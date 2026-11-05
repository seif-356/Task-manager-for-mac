import AppKit
import Darwin
import Observation

struct ProcessRow: Identifiable {
    let pid: pid_t
    let name: String
    let user: String
    let path: String?
    let isApp: Bool
    let isMine: Bool
    let icon: NSImage?
    /// False when macOS doesn't let us read CPU/memory (processes owned by other users).
    let hasStats: Bool
    /// Percent of the whole machine's CPU capacity (Windows-style, max 100%).
    let cpu: Double
    /// Physical memory footprint in bytes (the number Activity Monitor shows).
    let memory: UInt64
    /// Disk read + write, bytes per second.
    let diskRate: Double

    var id: pid_t { pid }
}

@MainActor
@Observable
final class ProcessStore {
    enum EndMode {
        case graceful
        case force
    }

    private struct Counters {
        let cpuNanos: Double
        let diskBytes: UInt64
    }

    private(set) var processes: [ProcessRow] = []

    @ObservationIgnored private var previous: [pid_t: Counters] = [:]
    @ObservationIgnored private var previousTime: UInt64 = 0
    @ObservationIgnored private var userNames: [uid_t: String] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?

    private let myUID = getuid()
    private let cpuCount = Double(ProcessInfo.processInfo.activeProcessorCount)
    /// rusage CPU times are in Mach ticks (not nanoseconds) on Apple silicon.
    private let ticksToNanos: Double

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksToNanos = timebase.denom == 0 ? 1 : Double(timebase.numer) / Double(timebase.denom)
    }

    func start() {
        guard task == nil else { return }
        task = Task {
            while !Task.isCancelled {
                self.refresh()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    func refresh() {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedNanos = previousTime == 0 ? 0 : Double(now - previousTime)

        var apps: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            apps[app.processIdentifier] = app
        }

        var counters: [pid_t: Counters] = [:]
        var rows: [ProcessRow] = []
        rows.reserveCapacity(previous.count + 32)

        for pid in ProcessSampler.allPIDs() {
            guard let info = ProcessSampler.bsdInfo(pid) else { continue }
            let path = ProcessSampler.path(pid)
            let app = apps[pid]
            let name = app?.localizedName
                ?? path.map { ($0 as NSString).lastPathComponent }
                ?? info.command

            var hasStats = false
            var cpu = 0.0
            var memory: UInt64 = 0
            var diskRate = 0.0

            if let usage = ProcessSampler.usage(pid) {
                hasStats = true
                let cpuNanos = Double(usage.ri_user_time &+ usage.ri_system_time) * ticksToNanos
                let diskBytes = usage.ri_diskio_bytesread &+ usage.ri_diskio_byteswritten
                counters[pid] = Counters(cpuNanos: cpuNanos, diskBytes: diskBytes)
                memory = usage.ri_phys_footprint

                if elapsedNanos > 0, let prev = previous[pid] {
                    cpu = max(0, cpuNanos - prev.cpuNanos) / elapsedNanos / cpuCount * 100
                    let diskDelta = diskBytes >= prev.diskBytes ? diskBytes - prev.diskBytes : 0
                    diskRate = Double(diskDelta) / (elapsedNanos / 1_000_000_000)
                }
            }

            rows.append(ProcessRow(
                pid: pid,
                name: name.isEmpty ? "PID \(pid)" : name,
                user: userName(info.uid),
                path: path,
                isApp: app?.activationPolicy == .regular,
                isMine: info.uid == myUID,
                icon: app?.icon,
                hasStats: hasStats,
                cpu: min(cpu, 100),
                memory: memory,
                diskRate: diskRate
            ))
        }

        previous = counters
        previousTime = now
        processes = rows
    }

    /// Returns an error message, or nil on success.
    func end(_ row: ProcessRow, mode: EndMode) -> String? {
        if let app = NSRunningApplication(processIdentifier: row.pid) {
            let accepted = mode == .graceful ? app.terminate() : app.forceTerminate()
            return accepted ? nil : "macOS refused to quit \(row.name)."
        }
        let signal = mode == .graceful ? SIGTERM : SIGKILL
        if kill(row.pid, signal) == 0 {
            return nil
        }
        let reason = String(cString: strerror(errno))
        return "Couldn't end \(row.name) (PID \(row.pid)): \(reason)."
    }

    private func userName(_ uid: uid_t) -> String {
        if let cached = userNames[uid] { return cached }
        let name: String
        if let entry = getpwuid(uid), let raw = entry.pointee.pw_name {
            name = String(cString: raw)
        } else {
            name = String(uid)
        }
        userNames[uid] = name
        return name
    }
}
