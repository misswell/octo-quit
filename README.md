# OctoPilot

[简体中文](README.zh-CN.md)

A native macOS menu-bar app that helps you manage distracting apps automatically. Each app can have independent rules to:

- hide after a period of inactivity;
- close its closable windows after inactivity while leaving its process running;
- quit after a period of inactivity;
- quit after it has been hidden for a period of time.

It can also launch selected apps after a per-app delay following login. Each launch rule can bring the app to the foreground, hide it, or wait through a 10-second startup grace period before closing its windows while keeping its background process alive. Launch rules use seconds, show a live countdown, skip apps that are already running, and run automatically only when OctoPilot is configured to start at login.

Rules, launch plans, and preferences persist in `~/Library/Application Support/OctoPilot/config.json`. This file is independent from the app bundle, so updating or replacing `OctoPilot.app` preserves your configuration. On first launch, OctoPilot automatically migrates compatible configuration from the previous version without modifying the original file. You can also see and reveal the exact path in Settings.

You can pick a running app or browse for an `.app` bundle, reorder rules, pause enforcement globally, and choose Start at Login from the menu-bar menu.

## Build the app

```sh
./Scripts/build-app.sh
open OctoPilot.app
```

The built app is `OctoPilot.app` in the project root. The Close Windows action requires Accessibility access in System Settings, and selecting that mode immediately triggers the system permission prompt. Whether a target app removes its Dock icon after its windows close is controlled by that app.

Local and GitHub Release builds currently use ad-hoc signing, so each update can have a new code identity and macOS may require Accessibility access to be granted again. Preserving that grant reliably across upgrades requires distributing every version with the same Developer ID signing identity.

If OctoPilot remains untrusted after an update even though it is enabled in the Accessibility list, toggling the switch may leave the old signing record in place. The permission alert offers **Reset Permission and Quit**, which runs `tccutil reset Accessibility com.misswell.octopilot` for you and exits OctoPilot. Reopen the app and grant access again. Runtime rules check access silently and do not repeatedly request it in the background.

## GitHub Actions

The macOS workflow builds, packages, verifies, and uploads the app on pushes to `main` and pull requests. Each commit after the latest version tag automatically increments the patch version: commits after `v1.0.0` build as `1.0.1`, `1.0.2`, and so on. A new tag becomes the next version baseline. Pushing a version tag such as `v1.1.0` also creates a GitHub Release with a zipped `OctoPilot.app` archive.
