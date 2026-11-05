import Darwin
import Foundation
import Observation

struct StartupItem: Identifiable {
    enum Kind: String {
        case userAgent = "Agent (you)"
        case allUsersAgent = "Agent (all users)"
        case systemDaemon = "System daemon"
    }

    let plistPath: String
    let label: String
    let program: String?
    let kind: Kind
    let runAtLoad: Bool
    let keepAlive: Bool
    let disabledInPlist: Bool
    /// launchd's own enable/disable override, which wins over the plist's `Disabled` key.
    let overrideDisabled: Bool?
    /// PID if launchd reports it running in your login session.
    let pid: Int?

    var id: String { plistPath }
    var isEnabled: Bool { !(overrideDisabled ?? disabledInPlist) }
    /// Daemons live in the system domain and need admin rights to change.
    var canToggle: Bool { kind != .systemDaemon }

    var statusText: String { isEnabled ? "Enabled" : "Disabled" }
    var programText: String { program ?? "—" }

    var startsText: String {
        guard runAtLoad || keepAlive else { return "On demand" }
        return kind == .systemDaemon ? "At boot" : "At login"
    }

    var runningText: String {
        if kind == .systemDaemon { return "Unknown" }
        return pid.map { "PID \($0)" } ?? "No"
    }
}

/// Reads launchd job definitions from the standard folders (not /System, which is Apple's).
enum StartupScanner {
    static func scan() -> [StartupItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sources: [(directory: String, kind: StartupItem.Kind)] = [
            ("\(home)/Library/LaunchAgents", .userAgent),
            ("/Library/LaunchAgents", .allUsersAgent),
            ("/Library/LaunchDaemons", .systemDaemon),
        ]

        let userOverrides = disabledOverrides(domain: "gui/\(getuid())")
        let systemOverrides = disabledOverrides(domain: "system")
        let running = runningJobs()

        var items: [StartupItem] = []
        for source in sources {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: source.directory) else { continue }
            for file in files where file.hasSuffix(".plist") {
                let path = (source.directory as NSString).appendingPathComponent(file)
                let plist = readPlist(path) ?? [:]
                let label = plist["Label"] as? String ?? (file as NSString).deletingPathExtension
                let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
                let keepAlive = (plist["KeepAlive"] as? Bool) ?? (plist["KeepAlive"] is [String: Any])
                let isDaemon = source.kind == .systemDaemon

                items.append(StartupItem(
                    plistPath: path,
                    label: label,
                    program: program,
                    kind: source.kind,
                    runAtLoad: plist["RunAtLoad"] as? Bool ?? false,
                    keepAlive: keepAlive,
                    disabledInPlist: plist["Disabled"] as? Bool ?? false,
                    overrideDisabled: isDaemon ? systemOverrides[label] : userOverrides[label],
                    pid: isDaemon ? nil : running[label]
                ))
            }
        }
        return items
    }

    /// Persistently enables/disables an agent for the current user. Takes effect at next login.
    /// Returns an error message, or nil on success.
    static func setEnabled(_ enabled: Bool, label: String) -> String? {
        let target = "gui/\(getuid())/\(label)"
        let result = Shell.run("/bin/launchctl", [enabled ? "enable" : "disable", target])
        if result.status == 0 { return nil }
        let message = result.error.isEmpty ? result.output : result.error
        return message.isEmpty ? "launchctl exited with status \(result.status)." : message
    }

    private static func readPlist(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Parses `launchctl print-disabled <domain>` lines like `"com.example.agent" => disabled`.
    private static func disabledOverrides(domain: String) -> [String: Bool] {
        let result = Shell.run("/bin/launchctl", ["print-disabled", domain])
        guard result.status == 0 else { return [:] }

        var overrides: [String: Bool] = [:]
        for line in result.output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("\""), let arrow = text.range(of: "\" => ") else { continue }
            let label = String(text[text.index(after: text.startIndex)..<arrow.lowerBound])
            switch String(text[arrow.upperBound...]) {
            case "disabled", "true": overrides[label] = true
            case "enabled", "false": overrides[label] = false
            default: break
            }
        }
        return overrides
    }

    /// Parses `launchctl list` (PID, status, label) for the current user's session.
    private static func runningJobs() -> [String: Int] {
        let result = Shell.run("/bin/launchctl", ["list"])
        guard result.status == 0 else { return [:] }

        var jobs: [String: Int] = [:]
        for line in result.output.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3, let pid = Int(columns[0]) else { continue }
            jobs[String(columns[2])] = pid
        }
        return jobs
    }
}

@MainActor
@Observable
final class StartupStore {
    private(set) var items: [StartupItem] = []
    private(set) var isLoading = false
    var errorMessage: String?

    func reload() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            let scanned = await Task.detached(priority: .userInitiated) {
                StartupScanner.scan()
            }.value
            self.items = scanned
            self.isLoading = false
        }
    }

    func setEnabled(_ enabled: Bool, for item: StartupItem) {
        guard item.canToggle else { return }
        let label = item.label
        Task {
            let error = await Task.detached(priority: .userInitiated) {
                StartupScanner.setEnabled(enabled, label: label)
            }.value
            if let error {
                self.errorMessage = "Couldn't change \(label): \(error)"
            }
            self.reload()
        }
    }
}
