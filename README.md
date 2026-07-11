# OctoQuit

A native macOS menu-bar app inspired by Quitter. Each app can have independent rules to:

- hide after a period of inactivity;
- quit after a period of inactivity;
- quit after it has been hidden for a period of time.

Rules and preferences persist in `~/Library/Application Support/OctoQuit/config.json`. This file is independent from the app bundle, so updating or replacing `OctoQuit.app` preserves your configuration. You can also see and reveal the exact path in Settings.

You can pick a running app or browse for an `.app` bundle, reorder rules, pause enforcement globally, and choose Start at Login from the menu-bar menu.

## Build the app

```sh
./Scripts/build-app.sh
open OctoQuit.app
```

The built app is `OctoQuit.app` in the project root. macOS may prompt for permission before it can hide or terminate other apps.
