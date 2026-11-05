import AppKit
import SwiftUI

@main
struct TaskManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Task Manager", id: "main") {
            ContentView()
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1000, height: 640)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Like Task Manager on Windows: closing the window quits the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
