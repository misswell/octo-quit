# OctoPilot

[简体中文](README.zh-CN.md)

A native macOS menu-bar app that helps you manage distracting apps automatically. Each app can have independent rules to:

- hide after a period of inactivity;
- close its closable windows after inactivity while leaving its process running;
- quit after a period of inactivity;
- quit after it has been hidden for a period of time.

It can also launch selected apps after a per-app delay following login. Launch rules use seconds, show a live countdown, skip apps that are already running, and run automatically only when OctoPilot is configured to start at login.

Rules, launch plans, and preferences persist in `~/Library/Application Support/OctoPilot/config.json`. This file is independent from the app bundle, so updating or replacing `OctoPilot.app` preserves your configuration. On first launch, OctoPilot automatically migrates compatible configuration from the previous version without modifying the original file. You can also see and reveal the exact path in Settings.

You can pick a running app or browse for an `.app` bundle, reorder rules, pause enforcement globally, and choose Start at Login from the menu-bar menu.

## Build the app

```sh
./Scripts/build-app.sh
open OctoPilot.app
```

The built app is `OctoPilot.app` in the project root. The Close Windows action requires Accessibility access in System Settings. Whether a target app removes its Dock icon after its windows close is controlled by that app.

## GitHub Actions

The macOS workflow builds, packages, verifies, and uploads the app on pushes to `main` and pull requests. Each commit after the latest version tag automatically increments the patch version: commits after `v1.0.0` build as `1.0.1`, `1.0.2`, and so on. A new tag becomes the next version baseline. Pushing a version tag such as `v1.1.0` also creates a GitHub Release with a zipped `OctoPilot.app` archive.
