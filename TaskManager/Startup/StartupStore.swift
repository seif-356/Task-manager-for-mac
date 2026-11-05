import Darwin
import Foundation
import Observation

struct StartupItem: Identifiable {
    enum Kind: String {
        case userAgent = "Agent (you)"
        case allUsersAgent = "Agent (all users)"
        case systemDaemon = "System daemon"
    }

    enum KeepAlive {
        case no
        case always
        /// A dictionary of conditions (network up, path exists, ...): runs only when they hold.
        case conditional
    }

    let plistPath: String
    let label: String
    let program: String?
    let kind: Kind
    /// False when the plist couldn't be read or parsed; such rows can't be toggled.
    let isReadable: Bool
    let runAtLoad: Bool
    let keepAlive: KeepAlive
    let disabledInPlist: Bool
    /// launchd's own enable/disable override, which wins over the plist's `Disabled` key.
    let overrideDisabled: Bool?
    /// PID if launchd reports it running in your login session.
    let pid: Int?

    var id: String { plistPath }
    var isEnabled: Bool { !(overrideDisabled ?? disabledInPlist) }
    /// Daemons live in the system domain and need admin rights to change.
    var canToggle: Bool { isReadable && kind != .systemDaemon }

    var statusText: String {
        guard isReadable else { return "Unreadable" }
        return isEnabled ? "Enabled" : "Disabled"
    }
    var programText: String { program ?? "—" }

    var startsText: String {
        guard isReadable else { return "—" }
        if runAtLoad || keepAlive == .always {
            return kind == .systemDaemon ? "At boot" : "At login"
        }
        return keepAlive == .conditional ? "On condition" : "On demand"
    }

    var runningText: String {
        if kind == .systemDaemon { return "Unknown" }
        return pid.map { "PID \($0)" } ?? "No"
    }
}

/// Reads launchd job definitions from the standard folders (not /System, which is Apple's).
enum StartupScanner {
    struct Result {
        let items: [StartupItem]
        /// Problems that make the list incomplete or its status unreliable.
        let warnings: [String]
    }

    static func scan() -> Result {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sources: [(directory: String, kind: StartupItem.Kind)] = [
            ("\(home)/Library/LaunchAgents", .userAgent),
            ("/Library/LaunchAgents", .allUsersAgent),
            ("/Library/LaunchDaemons", .systemDaemon),
        ]

        var warnings: [String] = []
        let userOverrides = disabledOverrides(domain: "gui/\(getuid())")
        let systemOverrides = disabledOverrides(domain: "system")
        let running = runningJobs()
        if userOverrides == nil {
            warnings.append("Couldn't read which agents are disabled, so their Status may be wrong.")
        }
        if systemOverrides == nil {
            warnings.append("Couldn't read which daemons are disabled, so their Status may be wrong.")
        }
        if running == nil {
            warnings.append("Couldn't read which agents are running.")
        }

        var items: [StartupItem] = []
        var unreadable = 0
        for source in sources {
            let files: [String]
            do {
                files = try FileManager.default.contentsOfDirectory(atPath: source.directory)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue // Folder doesn't exist on this Mac: nothing to list.
            } catch {
                warnings.append("Couldn't read \(source.directory): \(error.localizedDescription)")
                continue
            }

            for file in files where file.hasSuffix(".plist") {
                let path = (source.directory as NSString).appendingPathComponent(file)
                let plist = readPlist(path)
                if plist == nil { unreadable += 1 }
                let values = plist ?? [:]
                let label = values["Label"] as? String ?? (file as NSString).deletingPathExtension
                let program = values["Program"] as? String ?? (values["ProgramArguments"] as? [String])?.first
                let keepAlive: StartupItem.KeepAlive
                if let flag = values["KeepAlive"] as? Bool {
                    keepAlive = flag ? .always : .no
                } else if values["KeepAlive"] is [String: Any] {
                    keepAlive = .conditional
                } else {
                    keepAlive = .no
                }
                let isDaemon = source.kind == .systemDaemon

                items.append(StartupItem(
                    plistPath: path,
                    label: label,
                    program: program,
                    kind: source.kind,
                    isReadable: plist != nil,
                    runAtLoad: values["RunAtLoad"] as? Bool ?? false,
                    keepAlive: keepAlive,
                    disabledInPlist: values["Disabled"] as? Bool ?? false,
                    overrideDisabled: isDaemon ? systemOverrides?[label] : userOverrides?[label],
                    pid: isDaemon ? nil : running?[label]
                ))
            }
        }
        if unreadable > 0 {
            warnings.append("\(unreadable) startup file(s) couldn't be read and are marked Unreadable.")
        }
        return Result(items: items, warnings: warnings)
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
    /// Nil if launchctl failed (as opposed to an empty list).
    private static func disabledOverrides(domain: String) -> [String: Bool]? {
        let result = Shell.run("/bin/launchctl", ["print-disabled", domain])
        guard result.status == 0 else { return nil }

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
    /// Nil if launchctl failed (as opposed to nothing running).
    private static func runningJobs() -> [String: Int]? {
        let result = Shell.run("/bin/launchctl", ["list"])
        guard result.status == 0 else { return nil }

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
    private(set) var warnings: [String] = []
    private(set) var isLoading = false
    var errorMessage: String?

    /// Set when a reload is requested while a scan is already running,
    /// so the in-flight (possibly stale) scan is followed by a fresh one.
    @ObservationIgnored private var reloadRequested = false

    func reload() {
        guard !isLoading else {
            reloadRequested = true
            return
        }
        isLoading = true
        Task {
            repeat {
                self.reloadRequested = false
                let result = await Task.detached(priority: .userInitiated) {
                    StartupScanner.scan()
                }.value
                self.items = result.items
                self.warnings = result.warnings
            } while self.reloadRequested
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
