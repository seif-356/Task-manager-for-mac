import Darwin
import Foundation
import Observation

enum SystemInfo {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    static func int(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    /// Cumulative received/sent bytes per physical interface (en0, en1, ...).
    /// Uses the 64-bit counters from `sysctl(NET_RT_IFLIST2)`, so they never wrap;
    /// a decrease means the interface was reset.
    static func networkCounters() -> [String: (rx: UInt64, tx: UInt64)] {
        let netRouteIfList2: Int32 = 6      // NET_RT_IFLIST2 (sys/socket.h)
        let routeMessageIfInfo2: UInt8 = 0x12 // RTM_IFINFO2 (net/route.h)

        var mib: [Int32] = [CTL_NET, AF_ROUTE, 0, 0, netRouteIfList2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: (rx: UInt64, tx: UInt64)] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                defer { offset += messageLength }

                guard header.ifm_type == routeMessageIfInfo2,
                      offset + MemoryLayout<if_msghdr2>.size <= length else { continue }
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard message.ifm_flags & IFF_LOOPBACK == 0 else { continue }

                var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                guard if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil else { continue }
                let name = String(decoding: nameBuffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                // Count only physical Ethernet/Wi-Fi so VPN tunnels aren't double-counted.
                guard name.hasPrefix("en") else { continue }
                result[name] = (message.ifm_data.ifi_ibytes, message.ifm_data.ifi_obytes)
            }
        }
        return result
    }
}

@MainActor
@Observable
final class SystemMonitor {
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    private(set) var receiveHistory: [Double] = []
    private(set) var sendHistory: [Double] = []

    private(set) var cpuUsage: Double = 0
    private(set) var memoryUsed: UInt64 = 0
    private(set) var memoryWired: UInt64 = 0
    private(set) var memoryCompressed: UInt64 = 0
    private(set) var receiveRate: Double = 0
    private(set) var sendRate: Double = 0

    let memoryTotal = ProcessInfo.processInfo.physicalMemory
    let cpuName = SystemInfo.string("machdep.cpu.brand_string") ?? "CPU"
    let performanceCores = SystemInfo.int("hw.perflevel0.physicalcpu")
    let efficiencyCores = SystemInfo.int("hw.perflevel1.physicalcpu")
    let logicalCores = ProcessInfo.processInfo.activeProcessorCount

    var memoryPercent: Double {
        memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal) * 100
    }

    private typealias CPUTicks = (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)

    private let host = mach_host_self()
    @ObservationIgnored private var pageSize: UInt64 = 16_384
    @ObservationIgnored private var previousTicks: CPUTicks?
    @ObservationIgnored private var previousNet: [String: (rx: UInt64, tx: UInt64)] = [:]
    @ObservationIgnored private var previousNetTime: UInt64 = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        var size: vm_size_t = 0
        if host_page_size(host, &size) == KERN_SUCCESS, size > 0 {
            pageSize = UInt64(size)
        }
    }

    func start() {
        guard task == nil else { return }
        task = Task {
            while !Task.isCancelled {
                self.sample()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func sample() {
        sampleCPU()
        sampleMemory()
        sampleNetwork()
    }

    private func sampleCPU() {
        guard let ticks = readCPUTicks() else { return }
        defer { previousTicks = ticks }
        guard let prev = previousTicks else { return }

        let user = Double(ticks.user &- prev.user)
        let system = Double(ticks.system &- prev.system)
        let idle = Double(ticks.idle &- prev.idle)
        let nice = Double(ticks.nice &- prev.nice)
        let total = user + system + idle + nice
        let usage = total > 0 ? (user + system + nice) / total * 100 : 0

        cpuUsage = usage
        Self.append(usage, to: &cpuHistory)
    }

    /// "Used" matches Activity Monitor: app memory + wired + compressed.
    private func sampleMemory() {
        guard let stats = readVMStats() else { return }
        let internalPages = UInt64(stats.internal_page_count)
        let purgeablePages = min(UInt64(stats.purgeable_count), internalPages)
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize

        memoryWired = wired
        memoryCompressed = compressed
        memoryUsed = (internalPages - purgeablePages) * pageSize + wired + compressed
        Self.append(memoryPercent, to: &memoryHistory)
    }

    private func sampleNetwork() {
        let now = DispatchTime.now().uptimeNanoseconds
        let current = SystemInfo.networkCounters()
        defer {
            previousNet = current
            previousNetTime = now
        }
        guard previousNetTime != 0 else { return }

        let seconds = Double(now - previousNetTime) / 1_000_000_000
        guard seconds > 0 else { return }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, value) in current {
            guard let prev = previousNet[name] else { continue }
            // 64-bit counters don't wrap; a decrease means the interface was reset.
            received += value.rx >= prev.rx ? value.rx - prev.rx : 0
            sent += value.tx >= prev.tx ? value.tx - prev.tx : 0
        }

        let rx = Double(received) / seconds
        let tx = Double(sent) / seconds
        receiveRate = rx
        sendRate = tx
        Self.append(rx, to: &receiveHistory)
        Self.append(tx, to: &sendHistory)
    }

    private func readCPUTicks() -> CPUTicks? {
        var load = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(host, HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // cpu_ticks is natural_t (UInt32): (user, system, idle, nice). Wraps are handled with &-.
        let ticks = load.cpu_ticks
        return (ticks.0, ticks.1, ticks.2, ticks.3)
    }

    private func readVMStats() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }

    private static func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > Sampling.historyLength {
            history.removeFirst(history.count - Sampling.historyLength)
        }
    }
}
