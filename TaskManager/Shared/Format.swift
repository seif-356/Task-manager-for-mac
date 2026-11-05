import Foundation

/// Number of samples kept for the Performance graphs (one per second, like Windows).
enum Sampling {
    static let historyLength = 60
}

enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value.isFinite ? max(0, value) : 0)
    }

    static func bytes(_ value: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: value))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let value = bytesPerSecond.isFinite ? max(0, bytesPerSecond) : 0
        if value < 1_000_000 {
            return String(format: "%.1f KB/s", value / 1_000)
        }
        if value < 1_000_000_000 {
            return String(format: "%.1f MB/s", value / 1_000_000)
        }
        return String(format: "%.2f GB/s", value / 1_000_000_000)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        return String(format: "%ld:%02ld:%02ld:%02ld", days, hours, minutes, secs)
    }
}
