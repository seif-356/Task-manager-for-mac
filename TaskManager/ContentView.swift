import SwiftUI

struct ContentView: View {
    @State private var processes = ProcessStore()
    @State private var system = SystemMonitor()
    @State private var startup = StartupStore()

    var body: some View {
        TabView {
            ProcessesView(store: processes)
                .tabItem { Label("Processes", systemImage: "list.bullet.rectangle") }
            PerformanceView(monitor: system)
                .tabItem { Label("Performance", systemImage: "waveform.path.ecg") }
            StartupView(store: startup)
                .tabItem { Label("Startup Items", systemImage: "power") }
        }
        .padding(.top, 8)
        .onAppear {
            processes.start()
            system.start()
        }
    }
}
