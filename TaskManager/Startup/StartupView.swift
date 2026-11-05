import AppKit
import SwiftUI

struct StartupView: View {
    let store: StartupStore

    @State private var selection: StartupItem.ID?
    @State private var sortOrder = [KeyPathComparator(\StartupItem.label, comparator: String.StandardComparator.localizedStandard)]
    @State private var pendingToggle: StartupItem?

    var body: some View {
        let rows = store.items.sorted(using: sortOrder)
        VStack(spacing: 0) {
            table(rows)
            Divider()
            footer
        }
        .onAppear { store.reload() }
        .confirmationDialog(
            pendingToggle.map { "Disable \($0.label)?" } ?? "",
            isPresented: Binding(get: { pendingToggle != nil }, set: { if !$0 { pendingToggle = nil } }),
            presenting: pendingToggle
        ) { item in
            Button("Disable", role: .destructive) { store.setEnabled(false, for: item) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It won't start at your next login. Anything already running keeps running until you log out. You can re-enable it here.")
        }
        .alert(
            "Couldn't Change Startup Item",
            isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private func table(_ rows: [StartupItem]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.label) { item in
                Text(item.label)
                    .lineLimit(1)
                    .foregroundStyle(item.isEnabled ? Color.primary : Color.secondary)
            }
            .width(min: 200, ideal: 300)

            TableColumn("Status", value: \.statusText) { item in
                Text(item.statusText)
                    .foregroundStyle(item.isEnabled ? Color.primary : Color.secondary)
            }
            .width(min: 60, ideal: 70)

            TableColumn("Starts", value: \.startsText) { item in
                Text(item.startsText)
            }
            .width(min: 70, ideal: 80)

            TableColumn("Running", value: \.runningText) { item in
                Text(item.runningText).monospacedDigit()
            }
            .width(min: 70, ideal: 90)

            TableColumn("Type", value: \.kind.rawValue) { item in
                Text(item.kind.rawValue)
            }
            .width(min: 100, ideal: 120)

            TableColumn("Program", value: \.programText) { item in
                Text(item.programText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            .width(min: 150, ideal: 300)
        }
        .contextMenu(forSelectionType: StartupItem.ID.self) { ids in
            if let item = startupItem(for: ids.first) {
                if item.canToggle {
                    if item.isEnabled {
                        Button("Disable") { pendingToggle = item }
                    } else {
                        Button("Enable") { store.setEnabled(true, for: item) }
                    }
                    Divider()
                }
                Button("Show Definition in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.plistPath)])
                }
            }
        }
    }

    private var footer: some View {
        let selected = startupItem(for: selection)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(store.items.count) startup items from LaunchAgents and LaunchDaemons.")
                    .foregroundStyle(.secondary)
                Text("Apps added in System Settings › Login Items can't be read by other apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Open Login Items…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            Spacer()
            if store.isLoading {
                ProgressView().controlSize(.small)
            }
            Button("Refresh") { store.reload() }
            Button(selected?.isEnabled == false ? "Enable" : "Disable") {
                guard let item = selected else { return }
                if item.isEnabled {
                    pendingToggle = item
                } else {
                    store.setEnabled(true, for: item)
                }
            }
            .disabled(selected?.canToggle != true)
            .help(selected?.kind == .systemDaemon ? "System daemons need administrator rights (not supported yet)." : "")
        }
        .padding(8)
    }

    private func startupItem(for id: StartupItem.ID?) -> StartupItem? {
        guard let id else { return nil }
        return store.items.first { $0.id == id }
    }
}
