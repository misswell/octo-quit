import Foundation
import Testing
@testable import OctoPilot

struct LaunchRuleCodingTests {
    @Test func accessibilityResetUsesCurrentBundleIdentifier() {
        let command = AccessibilityResetCommand(bundleIdentifier: "com.misswell.octopilot")

        #expect(command.executableURL == URL(fileURLWithPath: "/usr/bin/tccutil"))
        #expect(command.arguments == ["reset", "Accessibility", "com.misswell.octopilot"])
    }

    @Test func accessibilityRecoveryRequestIsConsumedOnlyOnce() throws {
        let suiteName = "OctoPilotTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AccessibilityRecoveryRequest.schedule(in: defaults)

        #expect(AccessibilityRecoveryRequest.consume(from: defaults))
        #expect(!AccessibilityRecoveryRequest.consume(from: defaults))
    }

    @Test func onlyCloseWindowsModeRequiresAccessibility() {
        #expect(!LaunchVisibilityMode.foreground.requiresAccessibility)
        #expect(!LaunchVisibilityMode.hidden.requiresAccessibility)
        #expect(LaunchVisibilityMode.closeWindows.requiresAccessibility)
    }

    @Test func migratesLegacyForegroundMode() throws {
        let rule = try decodeLegacy(activateOnLaunch: true)
        #expect(rule.visibilityMode == .foreground)
    }

    @Test func migratesLegacyHiddenMode() throws {
        let rule = try decodeLegacy(activateOnLaunch: false)
        #expect(rule.visibilityMode == .hidden)
    }

    @Test func roundTripsCloseWindowsMode() throws {
        let rule = LaunchRule(
            appName: "Example",
            bundleIdentifier: "com.example.app",
            bundlePath: "/Applications/Example.app",
            visibilityMode: .closeWindows
        )

        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(LaunchRule.self, from: data)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(decoded.visibilityMode == .closeWindows)
        #expect(object["visibilityMode"] as? String == "closeWindows")
        #expect(object["activateOnLaunch"] as? Bool == false)
    }

    private func decodeLegacy(activateOnLaunch: Bool) throws -> LaunchRule {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "appName": "Example",
          "bundleIdentifier": "com.example.app",
          "bundlePath": "/Applications/Example.app",
          "delaySeconds": 30,
          "isEnabled": true,
          "activateOnLaunch": \(activateOnLaunch)
        }
        """
        return try JSONDecoder().decode(LaunchRule.self, from: Data(json.utf8))
    }
}
