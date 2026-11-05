# Task Manager for Mac

A Windows-style Task Manager for macOS, written in SwiftUI.

## Features

**Processes** (grouped like Windows)
- **Apps**: every app with a Dock icon, with all of its helper processes grouped under it and their CPU, memory and disk added up. Expand an app to see its processes.
- **Background processes**: your other processes (menu bar apps, agents, command-line tools).
- **macOS processes**: system processes owned by root or other users.
- End Task / Force Quit on an app ends the whole app; on a single row, just that process.

**Details**
- Flat list of every process with PID and user, filterable and sortable.

**Performance**
- 60-second live graphs for CPU, memory and network.
- CPU model, core layout (performance + efficiency) and up time.
- Memory in use, available, wired and compressed.

**Startup Items**
- Background jobs that start at login or boot, read from `~/Library/LaunchAgents`, `/Library/LaunchAgents` and `/Library/LaunchDaemons`.
- Disable or enable your user's agents (uses `launchctl disable/enable`, takes effect at next login).
- Shortcut to System Settings › Login Items.

## Install (no Xcode needed)

1. Go to [Releases](https://github.com/seif-356/Task-manager-for-mac/releases), download the latest `TaskManager-*.zip`, and double-click it.
2. Drag **TaskManager.app** into **Applications**.
3. Open it. macOS blocks it with "Apple could not verify…" because the app isn't notarized (that costs $99/year). Click **Done**.
4. Open **System Settings › Privacy & Security**, scroll down, click **Open Anyway** next to TaskManager, and confirm.

You only need step 4 once. Requires macOS 14+, runs natively on Apple silicon and Intel.

## Publishing a new version (maintainer)

1. Test the app on your Mac.
2. Merge your changes into `main`.
3. Tag and push. GitHub builds the app, signs it ad-hoc, zips it and creates the release automatically:

```bash
git tag v0.1.0
git push origin v0.1.0
```

## Build from source

Requirements: macOS 14 or later, Xcode 16 or later.

1. Clone the repo.
2. Open `TaskManager.xcodeproj`.
3. Press ⌘R.

No Apple Developer account is needed to run it on your own Mac (it is signed to run locally).

## Known limitations

- **System processes have less detail.** macOS only lets a normal app read your own processes directly. For root/system processes, CPU and memory come from the built-in `ps` tool (memory is resident size, CPU is a short average) and disk activity isn't available.
- **App grouping uses a private macOS function** (`responsibility_get_pid_responsible_for_pid`) to find which app a helper belongs to, e.g. Safari's web content processes. If it ever disappears, grouping falls back to parent processes.
- **System daemons are read-only.** Changing them needs administrator rights.
- **Login items added through System Settings aren't listed.** macOS doesn't expose that list to other apps.
- **CPU % is a share of the whole machine** (Windows-style, max 100%), not per core like Activity Monitor.
- **Not on the Mac App Store.** Store apps must be sandboxed, and the sandbox blocks reading and ending other processes. Distribute it directly instead (Developer ID signing + notarization).
