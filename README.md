# Task Manager for Mac

A Windows-style Task Manager for macOS, written in SwiftUI.

## Features

**Processes**
- Every running process with CPU, memory and disk usage, refreshed every 1.5 seconds.
- Filter by Apps, My Processes or All Processes, and search by name or PID.
- Sort by any column.
- End Task (asks the process to quit) and Force Quit (kills it immediately), from the buttons or the right-click menu.

**Performance**
- 60-second live graphs for CPU, memory and network.
- CPU model, core layout (performance + efficiency) and up time.
- Memory in use, available, wired and compressed.

**Startup Items**
- Background jobs that start at login or boot, read from `~/Library/LaunchAgents`, `/Library/LaunchAgents` and `/Library/LaunchDaemons`.
- Disable or enable your user's agents (uses `launchctl disable/enable`, takes effect at next login).
- Shortcut to System Settings › Login Items.

## Build and run

Requirements: macOS 14 or later, Xcode 16 or later.

1. Clone the repo.
2. Open `TaskManager.xcodeproj`.
3. Press ⌘R.

No Apple Developer account is needed to run it on your own Mac (it is signed to run locally).

## Known limitations

- **No usage stats for other users' processes.** macOS only lets a normal app read CPU and memory for processes you own. Root and system processes show `—`. Activity Monitor gets around this with Apple-only privileges; this app would need an admin helper tool.
- **System daemons are read-only.** Changing them needs administrator rights.
- **Login items added through System Settings aren't listed.** macOS doesn't expose that list to other apps.
- **CPU % is a share of the whole machine** (Windows-style, max 100%), not per core like Activity Monitor.
- **Not on the Mac App Store.** Store apps must be sandboxed, and the sandbox blocks reading and ending other processes. Distribute it directly instead (Developer ID signing + notarization).
