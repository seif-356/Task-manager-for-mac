import AppKit
import Darwin
import Observation

struct ProcessRow: Identifiable {
    let pid: pid_t
    let parentPID: pid_t
    let name: String
    let user: String
    let path: String?
    let isMine: Bool
    let icon: NSImage?
    /// PID of the app (with a Dock icon) this process belongs to; the app's own PID for its main process.
    let ownerAppPID: pid_t?
    /// Percent of the whole machine's CPU capacity (Windows-style, max 100%). Nil = unknown.
    let cpu: Double?
    /// Bytes: memory footprint for your processes, resident size for system ones. Nil = unknown.
    let memory: UInt64?
    /// Disk read + write, bytes per second. Nil = unknown (system processes).
    let diskRate: Double?
    /// Mach start time, when readable. Used to make sure a PID wasn't reused.
    let startTime: UInt64?

    var id: pid_t { pid }

    /// PID 0 is kernel_task, and kill(0, …) would signal our own process group.
    var canEnd: Bool { pid > 0 }
    var isAppMain: Bool { ownerAppPID == pid }

    // Non-optional keys so columns can sort; unknown values sort last.
    var cpuSort: Double { cpu ?? -1 }
    var memorySort: UInt64 { memory ?? 0 }
    var diskSort: Double { diskRate ?? -1 }
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
        var regularAppPIDs = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications {
            apps[app.processIdentifier] = app
            if app.activationPolicy == .regular {
                regularAppPIDs.insert(app.processIdentifier)
            }
        }
        let parents = Dictionary(raw.map { ($0.pid, $0.parentPID) }, uniquingKeysWith: { first, _ in first })

        /// Which Dock app a process belongs to: itself, the process macOS holds
        /// responsible for it, or the nearest app among its parents.
        func owner(of process: ProcessSampler.RawProcess) -> pid_t? {
            if regularAppPIDs.contains(process.pid) { return process.pid }
            if let responsible = process.responsiblePID, regularAppPIDs.contains(responsible) {
                return responsible
            }
            var ancestor = process.parentPID
            var steps = 0
            while ancestor > 1, steps < 32 {
                if regularAppPIDs.contains(ancestor) { return ancestor }
                ancestor = parents[ancestor] ?? 0
                steps += 1
            }
            return nil
        }

        var counters: [pid_t: Counters] = [:]
        var rows: [ProcessRow] = []
        rows.reserveCapacity(raw.count)

        for process in raw {
            let app = apps[process.pid]
            let name = app?.localizedName
                ?? process.path.map { ($0 as NSString).lastPathComponent }
                ?? process.command

            var cpu: Double?
            var memory: UInt64?
            var diskRate: Double?

            if let usage = process.usage {
                counters[process.pid] = Counters(
                    cpuNanos: usage.cpuNanos,
                    diskBytes: usage.diskBytes,
                    startTime: usage.startTime
                )
                memory = usage.memory
                cpu = 0
                diskRate = 0
                // Only compare against the same process, not a new one that reused the PID.
                if elapsedNanos > 0, let prev = previous[process.pid], prev.startTime == usage.startTime {
                    cpu = max(0, usage.cpuNanos - prev.cpuNanos) / elapsedNanos / cpuCount * 100
                    let diskDelta = usage.diskBytes >= prev.diskBytes ? usage.diskBytes - prev.diskBytes : 0
                    diskRate = Double(diskDelta) / (elapsedNanos / 1_000_000_000)
                }
            } else if let fallback = process.fallback {
                cpu = fallback.cpuPercentOfOneCore / cpuCount
                memory = fallback.residentBytes
            }

            rows.append(ProcessRow(
                pid: process.pid,
                parentPID: process.parentPID,
                name: name.isEmpty ? "PID \(process.pid)" : name,
                user: userName(process.uid),
                path: process.path,
                isMine: process.uid == myUID,
                icon: app?.icon,
                ownerAppPID: process.uid == myUID ? owner(of: process) : nil,
                cpu: cpu.map { min($0, 100) },
                memory: memory,
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
