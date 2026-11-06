import AppKit
import SwiftUI

/// One row in the grouped Processes tab: a section header, an app (with its
/// processes as children), or a single process.
struct ProcessNode: Identifiable {
    enum Kind {
        case section
        case app
        case process
    }

    let id: String
    let kind: Kind
    let name: String
    let icon: NSImage?
    /// What End Task acts on: the app's main process, or the process itself.
    let target: ProcessRow?
    let cpu: Double?
    let memory: UInt64?
    let diskRate: Double?
    let children: [ProcessNode]
    /// For apps: all of the app's processes, even when a search hides some.
    let processCount: Int
}

/// Windows-style Processes tab: Apps (expandable, usage summed over all of an
/// app's processes), Background processes, and macOS processes.
struct ProcessesView: View {
    let store: ProcessStore
    let monitor: SystemMonitor

    private struct Tree {
        var apps: [ProcessNode] = []
        var background: [ProcessNode] = []
        var system: [ProcessNode] = []
        var index: [String: ProcessNode] = [:]
        var processCount = 0
    }

    private struct PendingEnd {
        let target: ProcessRow
        let name: String
        let mode: ProcessStore.EndMode
        let processCount: Int
    }

    @State private var search = ""
    @State private var selection: ProcessNode.ID?
    @State private var sortOrder = [KeyPathComparator(\ProcessNode.cpu, comparator: NilsLastComparator<Double>(order: .reverse))]
    @State private var showApps = true
    @State private var showBackground = true
    @State private var showSystem = false
    @State private var expandedApps: Set<String> = []
    @State private var pendingEnd: PendingEnd?
    @State private var errorMessage: String?

    var body: some View {
        let tree = buildTree()
        VStack(spacing: 0) {
            header(tree)
            Divider()
            table(tree)
            Divider()
            footer(tree)
        }
        .confirmationDialog(
            dialogTitle,
            isPresented: Binding(get: { pendingEnd != nil }, set: { if !$0 { pendingEnd = nil } }),
            presenting: pendingEnd
        ) { pending in
            Button(pending.mode == .force ? "Force Quit" : "End Task", role: .destructive) {
                errorMessage = store.end(pending.target, mode: pending.mode)
                Task { await store.refresh() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(dialogMessage(pending))
        }
        .alert(
            "Couldn't End Task",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Layout

    private func header(_ tree: Tree) -> some View {
        HStack(spacing: 16) {
            Label("CPU \(Format.percent(monitor.cpuUsage))", systemImage: "cpu")
            Label("Memory \(Format.percent(monitor.memoryPercent))", systemImage: "memorychip")
            Label("\(tree.processCount) processes", systemImage: "square.stack.3d.up")
            Spacer()
            TextField("Search name or PID", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
        }
        .font(.callout)
        .monospacedDigit()
        .padding(8)
    }

    private func table(_ tree: Tree) -> some View {
        Table(of: ProcessNode.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { node in
                nameCell(node)
            }
            .width(min: 220, ideal: 340)

            TableColumn("CPU", value: \.cpu, comparator: NilsLastComparator<Double>()) { node in
                Text(value(node, node.cpu.map(Format.percent))).monospacedDigit()
            }
            .width(min: 60, ideal: 80)

            TableColumn("Memory", value: \.memory, comparator: NilsLastComparator<UInt64>()) { node in
                Text(value(node, node.memory.map(Format.bytes))).monospacedDigit()
            }
            .width(min: 70, ideal: 100)

            TableColumn("Disk", value: \.diskRate, comparator: NilsLastComparator<Double>()) { node in
                Text(value(node, node.diskRate.map(Format.rate))).monospacedDigit()
            }
            .width(min: 70, ideal: 100)
        } rows: {
            DisclosureTableRow(sectionNode("apps", "Apps", count: tree.apps.count), isExpanded: $showApps) {
                ForEach(tree.apps) { app in
                    DisclosureTableRow(app, isExpanded: expansion(for: app.id)) {
                        ForEach(app.children) { child in
                            TableRow(child)
                        }
                    }
                }
            }
            DisclosureTableRow(
                sectionNode("background", "Background processes", count: tree.background.count),
                isExpanded: $showBackground
            ) {
                ForEach(tree.background) { node in
                    TableRow(node)
                }
            }
            DisclosureTableRow(
                sectionNode("system", "macOS processes", count: tree.system.count),
                isExpanded: $showSystem
            ) {
                ForEach(tree.system) { node in
                    TableRow(node)
                }
            }
        }
        .contextMenu(forSelectionType: ProcessNode.ID.self) { ids in
            if let id = ids.first, let node = tree.index[id], let target = node.target {
                if target.canEnd {
                    Button("End Task") { requestEnd(node, mode: .graceful) }
                    Button("Force Quit") { requestEnd(node, mode: .force) }
                }
                if let path = target.path {
                    if target.canEnd { Divider() }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func nameCell(_ node: ProcessNode) -> some View {
        switch node.kind {
        case .section:
            Text(node.name).font(.headline)
        case .app, .process:
            HStack(spacing: 6) {
                if let icon = node.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                Text(node.name).lineLimit(1)
                if node.kind == .app, node.processCount > 1 {
                    Text("(\(node.processCount))").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func footer(_ tree: Tree) -> some View {
        let node = selection.flatMap { tree.index[$0] }
        let canEnd = node?.target?.canEnd == true
        return HStack {
            Text("Usage of system processes comes from macOS's ps tool; their disk activity isn't available.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Force Quit") {
                if let node { requestEnd(node, mode: .force) }
            }
            .disabled(!canEnd)
            Button("End Task") {
                if let node { requestEnd(node, mode: .graceful) }
            }
            .disabled(!canEnd)
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(8)
    }

    // MARK: Building the tree

    private func buildTree() -> Tree {
        let all = store.processes
        let byPID = Dictionary(all.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let query = search.trimmingCharacters(in: .whitespaces)

        func matches(_ row: ProcessRow) -> Bool {
            query.isEmpty
                || row.name.localizedCaseInsensitiveContains(query)
                || String(row.pid).hasPrefix(query)
        }

        // Group everything first, so app totals and counts always cover the
        // whole app; the search only decides which rows are shown.
        var grouped: [pid_t: [ProcessRow]] = [:]
        var background: [ProcessRow] = []
        var system: [ProcessRow] = []
        for row in all {
            if let owner = row.ownerAppPID {
                grouped[owner, default: []].append(row)
            } else if matches(row) {
                if row.isMine {
                    background.append(row)
                } else {
                    system.append(row)
                }
            }
        }

        var tree = Tree()
        tree.apps = grouped.compactMap { entry -> ProcessNode? in
            let main = byPID[entry.key]
            let appMatches = main.map { matches($0) } ?? false
            let members = entry.value
            let shown = appMatches ? members : members.filter { matches($0) }
            guard !shown.isEmpty else { return nil }
            let mainStart = main?.startTime ?? 0
            return ProcessNode(
                id: "app-\(entry.key)-\(mainStart)",
                kind: .app,
                name: main?.name ?? "PID \(entry.key)",
                icon: main?.icon,
                target: main,
                cpu: total(members.map(\.cpu)),
                memory: total(members.map(\.memory)),
                diskRate: total(members.map(\.diskRate)),
                children: shown.map { processNode($0) }.sorted(using: sortOrder),
                processCount: members.count
            )
        }
        .sorted(using: sortOrder)
        tree.background = background.map { processNode($0) }.sorted(using: sortOrder)
        tree.system = system.map { processNode($0) }.sorted(using: sortOrder)
        tree.processCount = tree.apps.reduce(0) { $0 + $1.children.count } + tree.background.count + tree.system.count

        for node in tree.apps + tree.background + tree.system {
            tree.index[node.id] = node
            for child in node.children {
                tree.index[child.id] = child
            }
        }
        return tree
    }

    private func processNode(_ row: ProcessRow) -> ProcessNode {
        ProcessNode(
            id: "pid-\(row.id)",
            kind: .process,
            name: row.name,
            icon: row.icon,
            target: row,
            cpu: row.cpu,
            memory: row.memory,
            diskRate: row.diskRate,
            children: [],
            processCount: 1
        )
    }

    private func sectionNode(_ id: String, _ title: String, count: Int) -> ProcessNode {
        ProcessNode(
            id: "section-\(id)",
            kind: .section,
            name: "\(title) (\(count))",
            icon: nil,
            target: nil,
            cpu: nil,
            memory: nil,
            diskRate: nil,
            children: [],
            processCount: count
        )
    }

    private func total<T: AdditiveArithmetic>(_ values: [T?]) -> T? {
        let known = values.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(T.zero, +)
    }

    // MARK: Helpers

    /// Section headers show no numbers; unknown values show "—".
    private func value(_ node: ProcessNode, _ text: String?) -> String {
        node.kind == .section ? "" : (text ?? "—")
    }

    private func expansion(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedApps.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedApps.insert(id)
                } else {
                    expandedApps.remove(id)
                }
            }
        )
    }

    private func requestEnd(_ node: ProcessNode, mode: ProcessStore.EndMode) {
        guard let target = node.target, target.canEnd else { return }
        pendingEnd = PendingEnd(
            target: target,
            name: node.name,
            mode: mode,
            processCount: node.processCount
        )
    }

    private var dialogTitle: String {
        guard let pending = pendingEnd else { return "" }
        return pending.mode == .force ? "Force quit \(pending.name)?" : "End \(pending.name)?"
    }

    private func dialogMessage(_ pending: PendingEnd) -> String {
        var message = pending.mode == .force
            ? "It is killed immediately. Unsaved work will be lost."
            : "It will be asked to quit."
        if pending.processCount > 1 {
            message += " It has \(pending.processCount) processes; its helpers normally close with it."
        }
        return message
    }
}
