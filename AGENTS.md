# Repository Guidelines

Contributor guide for **OctoPilot**, a native macOS menu-bar app (Swift 6, SwiftPM, macOS 14+) that auto-manages distracting apps and adds BLE proximity lock/unlock.

## Project Structure & Module Organization

- `Sources/OctoPilot/` — single executable target: `OctoPilotApp.swift` (core) and `BLEUnlock.swift` (proximity lock/unlock).
- `Tests/OctoPilotTests/` — Swift Testing suites (`LaunchRuleCodingTests.swift`, `BLEUnlockPerformanceTests.swift`).
- `Resources/` — `Info.plist`, `OctoPilot.entitlements`, `AppIcon.icns`, icon sources.
- `Scripts/` — `build-app.sh`, `distribute-app.sh`, `version.sh`.
- `.github/workflows/build.yml` — CI.
- Runtime config lives outside the bundle at `~/Library/Application Support/OctoPilot/config.json`; bundle ID `com.misswell.octopilot`.

## Build, Test, and Development Commands

- `swift build` — compile (debug).
- `swift test` — run all tests; filter with `swift test --filter SuiteName.method`.
- `./Scripts/version.sh` — print current version (latest `v*` tag + commits since).
- `./Scripts/build-app.sh` — release build, package `OctoPilot.app`, inject version into `Info.plist`, codesign (Developer ID if `OCTOPILOT_DEVELOPER_ID` is set, otherwise ad-hoc).
- `./Scripts/distribute-app.sh` — sign with Hardened Runtime, notarize, staple, output `OctoPilot-<version>-macos.zip` (needs Apple Developer credentials).

## Coding Style & Naming Conventions

- Swift, 4-space indentation. No committed formatter or linter; match surrounding style.
- Types `UpperCamelCase`, members `lowerCamelCase`. Test methods are behavioral phrases (`closeWindowsModeUsesBehaviorBasedName`).
- Route user-facing strings through `AppText.value(_:language:)`, keeping `.simplifiedChinese` and `.english` entries in sync.

## Testing Guidelines

- Framework: **Swift Testing** (`import Testing`; `@Test`, `#expect`, `#require`). Suites are `struct`s of `@testable import OctoPilot` functions.
- Name tests as sentences describing the invariant. Use `UserDefaults(suiteName:)` with a UUID for stateful tests and clean up via `defer`.
- Run `swift test` before pushing.

## Commit & Pull Request Guidelines

- Use **Conventional Commits**: `feat:`, `fix:`, `refactor:`, `docs:` (e.g. `feat: add BLE proximity lock`). Imperative subject, ≤72 chars.
- PRs target `main`. Describe what and why, link issues, and call out Accessibility/Bluetooth behavior changes.
- CI builds, packages, and verifies the signature on every push/PR — do not merge if `build` fails.
- Version tags `v<major>.<minor>.<patch>` trigger the `dist` job and a GitHub Release.

## Security & Signing

- `OctoPilot.entitlements` enables only `com.apple.security.cs.disable-library-validation` — do not add entitlements without justification.
- The BLE unlock login password lives in **Keychain**; never log it or persist it to `config.json`.
- Accessibility and Bluetooth are required at runtime; Close Windows mode prompts for Accessibility. Ad-hoc local builds may re-prompt Accessibility each rebuild — distribute with a stable Developer ID to preserve grants.

## Project Summary

The repo-root `SUMMARY.md` is the project's Chinese development summary (features, release flow, pitfalls). Consult it for fuller context beyond this contributor guide.
