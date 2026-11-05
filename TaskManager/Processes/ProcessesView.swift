import AppKit
import SwiftUI

struct ProcessesView: View {
    let store: ProcessStore

    enum Scope: String, CaseIterable, Identifiable {
        case apps = "Apps"
        case mine = "My Processes"
        case all = "All Processes"
        var id: Self { self }
    }

    private struct PendingEnd {
        let row: ProcessRow
        let mode: ProcessStore.EndMode
    }

    @State private var scope: Scope = .mine
    @State private var search = ""
    @State private var selection: ProcessRow.ID?
    @State private var sortOrder = [KeyPathComparator(\ProcessRow.cpu, order: .reverse)]
    @State private var pendingEnd: PendingEnd?
    @State private var errorMessage: String?

    var body: some View {
        let rows = visibleRows
        VStack(spacing: 0) {
            header
            Divider()
            table(rows)
            Divider()
            footer(count: rows.count)
        }
        .confirmationDialog(
            dialogTitle,
            isPresented: Binding(get: { pendingEnd != nil }, set: { if !$0 { pendingEnd = nil } }),
            presenting: pendingEnd
        ) { pending in
            Button(pending.mode == .force ? "Force Quit" : "End Task", role: .destructive) {
                errorMessage = store.end(pending.row, mode: pending.mode)
                Task { await store.refresh() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.mode == .force
                 ? "The process is killed immediately. Unsaved work will be lost."
                 : "The process will be asked to quit.")
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

    private var header: some View {
        HStack {
            Picker("Show", selection: $scope) {
                ForEach(Scope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            TextField("Search name or PID", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
        }
        .padding(8)
    }

    private func table(_ rows: [ProcessRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    if let icon = row.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "gearshape")
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                    }
                    Text(row.name).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 280)

            TableColumn("PID", value: \.pid) { row in
                Text(String(row.pid)).monospacedDigit()
            }
            .width(min: 50, ideal: 60)

            TableColumn("User", value: \.user) { row in
                Text(row.user).lineLimit(1)
            }
            .width(min: 60, ideal: 90)

            TableColumn("CPU", value: \.cpu) { row in
                Text(row.hasStats ? Format.percent(row.cpu) : "—").monospacedDigit()
            }
            .width(min: 60, ideal: 70)

            TableColumn("Memory", value: \.memory) { row in
                Text(row.hasStats ? Format.bytes(row.memory) : "—").monospacedDigit()
            }
            .width(min: 70, ideal: 90)

            TableColumn("Disk", value: \.diskRate) { row in
                Text(row.hasStats ? Format.rate(row.diskRate) : "—").monospacedDigit()
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: ProcessRow.ID.self) { ids in
            if let row = processRow(for: ids.first) {
                if row.canEnd {
                    Button("End Task") { pendingEnd = PendingEnd(row: row, mode: .graceful) }
                    Button("Force Quit") { pendingEnd = PendingEnd(row: row, mode: .force) }
                }
                if let path = row.path {
                    if row.canEnd { Divider() }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
            }
        }
    }

    private func footer(count: Int) -> some View {
        let canEnd = processRow(for: selection)?.canEnd == true
        return HStack {
            Text("\(count) processes")
                .foregroundStyle(.secondary)
            if scope == .all {
                Text("— means macOS hides that process's usage from non-admin apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Force Quit") {
                if let row = processRow(for: selection) { pendingEnd = PendingEnd(row: row, mode: .force) }
            }
            .disabled(!canEnd)
            Button("End Task") {
                if let row = processRow(for: selection) { pendingEnd = PendingEnd(row: row, mode: .graceful) }
            }
            .disabled(!canEnd)
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(8)
    }

    private var visibleRows: [ProcessRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return store.processes
            .filter { row in
                switch scope {
                case .apps: return row.isApp
                case .mine: return row.isMine
                case .all: return true
                }
            }
            .filter { row in
                query.isEmpty
                    || row.name.localizedCaseInsensitiveContains(query)
                    || String(row.pid).hasPrefix(query)
            }
            .sorted(using: sortOrder)
    }

    private var dialogTitle: String {
        guard let pending = pendingEnd else { return "" }
        return pending.mode == .force ? "Force quit \(pending.row.name)?" : "End \(pending.row.name)?"
    }

    private func processRow(for id: ProcessRow.ID?) -> ProcessRow? {
        guard let id else { return nil }
        return store.processes.first { $0.pid == id }
    }
}
