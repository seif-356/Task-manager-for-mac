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
    /// Mach start time, when readable. Used to make sure a PID wasn't reused.
    let startTime: UInt64?

    var id: pid_t { pid }

    /// PID 0 is kernel_task, and kill(0, …) would signal our own process group.
    var canEnd: Bool { pid > 0 }
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
        let startTime: UInt64
    }

    private(set) var processes: [ProcessRow] = []

    @ObservationIgnored private var previous: [pid_t: Counters] = [:]
    @ObservationIgnored private var previousTime: UInt64 = 0
    @ObservationIgnored private var userNames: [uid_t: String] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var isRefreshing = false

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
                await self.refresh()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    /// The ~3 system calls per process run off the main thread;
    /// only the cheap row assembly happens here.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let ratio = ticksToNanos
        let (raw, now) = await Task.detached(priority: .utility) {
            (ProcessSampler.snapshot(ticksToNanos: ratio), DispatchTime.now().uptimeNanoseconds)
        }.value

        let elapsedNanos = (previousTime == 0 || now <= previousTime) ? 0 : Double(now - previousTime)

        var apps: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            apps[app.processIdentifier] = app
        }

        var counters: [pid_t: Counters] = [:]
        var rows: [ProcessRow] = []
        rows.reserveCapacity(raw.count)

        for process in raw {
            let app = apps[process.pid]
            let name = app?.localizedName
                ?? process.path.map { ($0 as NSString).lastPathComponent }
                ?? process.command

            var cpu = 0.0
            var diskRate = 0.0
            if let usage = process.usage {
                counters[process.pid] = Counters(
                    cpuNanos: usage.cpuNanos,
                    diskBytes: usage.diskBytes,
                    startTime: usage.startTime
                )
                // Only compare against the same process, not a new one that reused the PID.
                if elapsedNanos > 0, let prev = previous[process.pid], prev.startTime == usage.startTime {
                    cpu = max(0, usage.cpuNanos - prev.cpuNanos) / elapsedNanos / cpuCount * 100
                    let diskDelta = usage.diskBytes >= prev.diskBytes ? usage.diskBytes - prev.diskBytes : 0
                    diskRate = Double(diskDelta) / (elapsedNanos / 1_000_000_000)
                }
            }

            rows.append(ProcessRow(
                pid: process.pid,
                name: name.isEmpty ? "PID \(process.pid)" : name,
                user: userName(process.uid),
                path: process.path,
                isApp: app?.activationPolicy == .regular,
                isMine: process.uid == myUID,
                icon: app?.icon,
                hasStats: process.usage != nil,
                cpu: min(cpu, 100),
                memory: process.usage?.memory ?? 0,
                diskRate: diskRate,
                startTime: process.usage?.startTime
            ))
        }

        previous = counters
        previousTime = now
        processes = rows
    }

    /// Returns an error message, or nil on success.
    func end(_ row: ProcessRow, mode: EndMode) -> String? {
        guard row.canEnd else {
            return "\(row.name) is part of macOS and can't be ended."
        }
        // PIDs get reused: make sure this is still the process the user picked.
        if let expected = row.startTime, ProcessSampler.resourceUsage(row.pid)?.ri_proc_start_abstime != expected {
            return "\(row.name) has already exited."
        }

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
