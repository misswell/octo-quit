import AppKit
import ApplicationServices
import Darwin
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@main
struct OctoPilotApp: App {
    @StateObject private var model = OctoPilotModel()

    var body: some Scene {
        Window("OctoPilot", id: "main") {
            ContentView().environmentObject(model)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MenuBarView().environmentObject(model)
        } label: {
            Image(systemName: model.isEnforcing ? "timer" : "pause.circle")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct QuitRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var appName: String
    var bundleIdentifier: String
    var bundlePath: String?
    var inactiveHideMinutes: Int?
    var inactiveCloseMinutes: Int?
    var inactiveQuitMinutes: Int?
    var hiddenQuitMinutes: Int?
    var isEnabled = true

    var hasAction: Bool { inactiveHideMinutes != nil || inactiveCloseMinutes != nil || inactiveQuitMinutes != nil || hiddenQuitMinutes != nil }
}

private struct QuitRuntimeState {
    var lastActiveAt: Date?
    var hiddenAt: Date?
    var didHideSinceActive = false
    var didCloseSinceActive = false
}

private enum WindowCloseResult {
    case noClosableWindows
    case closed
    case failed

    var postLaunchResult: Bool? {
        switch self {
        case .noClosableWindows: nil
        case .closed: true
        case .failed: false
        }
    }
}

struct QuitterImportPreview: Identifiable {
    let id = UUID()
    let rules: [QuitRule]
    let skippedCount: Int
    let isEnforcing: Bool?
}

enum LaunchVisibilityMode: String, CaseIterable, Codable, Identifiable {
    case foreground
    case hidden
    case closeWindows

    var id: String { rawValue }
    var requiresAccessibility: Bool { self == .closeWindows }

    var titleKey: String {
        switch self {
        case .foreground: "launchModeForeground"
        case .hidden: "launchModeHidden"
        case .closeWindows: "launchModeCloseWindows"
        }
    }

    var hintKey: String {
        switch self {
        case .foreground: "launchForegroundHint"
        case .hidden: "launchHiddenHint"
        case .closeWindows: "launchCloseWindowsHint"
        }
    }
}

struct AccessibilityResetCommand {
    let bundleIdentifier: String

    var executableURL: URL { URL(fileURLWithPath: "/usr/bin/tccutil") }
    var arguments: [String] { ["reset", "Accessibility", bundleIdentifier] }

    @discardableResult
    func run() throws -> Int32 {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

struct AccessibilityRecoveryRequest {
    private static let key = "OctoPilot.requestAccessibilityAfterReset"

    static func schedule(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }

    static func consume(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: key) else { return false }
        defaults.removeObject(forKey: key)
        return true
    }
}

struct LaunchRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var appName: String
    var bundleIdentifier: String
    var bundlePath: String
    var delaySeconds: Int = 30
    var isEnabled = true
    var visibilityMode: LaunchVisibilityMode = .hidden

    init(
        id: UUID = UUID(),
        appName: String,
        bundleIdentifier: String,
        bundlePath: String,
        delaySeconds: Int = 30,
        isEnabled: Bool = true,
        visibilityMode: LaunchVisibilityMode = .hidden
    ) {
        self.id = id
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.delaySeconds = delaySeconds
        self.isEnabled = isEnabled
        self.visibilityMode = visibilityMode
    }

    private enum CodingKeys: String, CodingKey {
        case id, appName, bundleIdentifier, bundlePath, delaySeconds, isEnabled, visibilityMode, activateOnLaunch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        appName = try container.decode(String.self, forKey: .appName)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        bundlePath = try container.decode(String.self, forKey: .bundlePath)
        delaySeconds = try container.decodeIfPresent(Int.self, forKey: .delaySeconds) ?? 30
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        if let storedMode = try container.decodeIfPresent(LaunchVisibilityMode.self, forKey: .visibilityMode) {
            visibilityMode = storedMode
        } else {
            visibilityMode = try container.decodeIfPresent(Bool.self, forKey: .activateOnLaunch) == true ? .foreground : .hidden
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(appName, forKey: .appName)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(bundlePath, forKey: .bundlePath)
        try container.encode(delaySeconds, forKey: .delaySeconds)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(visibilityMode, forKey: .visibilityMode)
        try container.encode(visibilityMode == .foreground, forKey: .activateOnLaunch)
    }
}

enum LaunchRuntimeState: Equatable {
    case pending(Date)
    case launching
    case launched
    case skippedAlreadyRunning
    case cancelled
    case failed(String)
}

private actor LaunchGate {
    private let minimumStartInterval: TimeInterval
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(minimumStartInterval: TimeInterval) {
        self.minimumStartInterval = minimumStartInterval
    }

    func run(_ operation: @escaping @Sendable () async -> Void) async {
        await acquire()
        let startedAt = Date()
        await operation()

        if !Task.isCancelled {
            let remaining = minimumStartInterval - Date().timeIntervalSince(startedAt)
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
        release()
    }

    private func acquire() async {
        if !isOccupied {
            isOccupied = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isOccupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }
    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .english: Locale(identifier: "en")
        case .simplifiedChinese: Locale(identifier: "zh-Hans")
        }
    }
}

enum AppText {
    private static let chinese: [String: String] = [
        "rules": "退出", "settings": "设置", "addApp": "添加应用", "apps": "应用",
        "rulesSubtitle": "在应用闲置一段时间后自动隐藏、关闭窗口或退出。",
        "dropApp": "拖入应用以添加规则", "invalidDrop": "请拖入 macOS 应用（.app）以创建规则。",
        "duplicateRule": "已存在 \"%@\" 的规则。", "selfRule": "OctoPilot 不能管理自身。", "enforcing": "规则执行中", "paused": "规则已暂停",
        "enabledChecked": "%d 条已启用 · 检查于 %@", "noApps": "尚未添加应用",
        "noAppsDetail": "添加一个应用，在闲置后自动隐藏、关闭窗口或退出。", "addFirstApp": "添加第一个应用",
        "edit": "编辑", "editRule": "编辑规则", "deleteRule": "删除规则", "remove": "移除",
        "removeConfirmTitle": "确认移除", "removeConfirmMessage": "确定要移除“%@”吗？此操作会删除对应规则。",
        "hideAfter": "闲置 %d 分钟后隐藏", "closeAfter": "闲置 %d 分钟后关闭窗口", "quitAfter": "闲置 %d 分钟后退出", "quitHidden": "隐藏 %d 分钟后退出",
        "addRule": "添加应用规则", "editAppRule": "编辑应用规则", "ruleDetail": "选择一个应用，然后设置一个或多个自动操作。",
        "hideInactive": "闲置后隐藏", "closeInactive": "闲置后关闭窗口", "quitInactive": "闲置后退出", "quitAfterHidden": "隐藏后退出",
        "closeWindowHint": "关闭应用的可关闭窗口，但保留后台进程。Dock 图标是否消失由该应用决定。",
        "accessibilityRequired": "“关闭窗口”需要辅助功能权限。如果升级后已勾选但仍无效，可一键重置权限并退出 OctoPilot；重新打开后再允许权限。当前应用：%@",
        "openAccessibilitySettings": "打开辅助功能设置",
        "resetAccessibility": "重置权限并退出",
        "accessibilityResetFailed": "无法重置辅助功能权限：%@",
        "cancel": "取消", "save": "存储", "chooseApp": "选择应用", "chooseRunning": "选择正在运行的应用",
        "browse": "浏览…", "minute": "分钟", "minutes": "分钟", "language": "语言",
        "application": "应用", "selectedApp": "已选应用", "changeApp": "更换应用", "runningApps": "正在运行的应用",
        "browseApplications": "从磁盘选择应用", "noRunningApps": "未检测到可选的运行应用",
        "configFile": "配置文件", "configDescription": "规则和偏好保存在此本机文件中。更新或替换 OctoPilot.app 不会影响它。",
        "revealInFinder": "在访达中显示", "configSaveError": "无法保存配置文件：%@",
        "importQuitter": "导入 Quitter 配置", "importQuitterDescription": "直接从 Quitter 的本机偏好文件导入规则；已存在相同应用标识的规则会被跳过。",
        "importQuitterSuccess": "已导入 %d 条规则，跳过 %d 条重复或无效规则。", "importQuitterEmpty": "没有发现可导入的新规则。",
        "importQuitterError": "无法导入配置文件：%@", "importQuitterInvalid": "这不是受支持的 Quitter 偏好文件。",
        "importQuitterNotFound": "未找到 Quitter 配置文件：%@",
        "importQuitterConfirmTitle": "确认导入", "importQuitterConfirmMessage": "找到 %d 条可导入规则，另有 %d 条重复或无效规则将被跳过。是否导入？",
        "import": "导入",
        "languageDescription": "选择 OctoPilot 的显示语言。更改会立即生效。", "systemLanguage": "跟随系统",
        "english": "English", "simplifiedChinese": "简体中文", "checkNow": "立即检查", "startAtLogin": "登录时启动",
        "showApp": "显示 OctoPilot", "quitApp": "退出 OctoPilot", "enabledStatus": "OctoPilot：已启用",
        "disabledStatus": "OctoPilot：已停用", "disableApp": "停用 OctoPilot", "enableApp": "启用 OctoPilot",
        "loginError": "无法更新登录启动项：%@", "aboutAutomation": "自动化", "manageRules": "管理应用规则和界面偏好。",
        "quitsIn": "将在 %d 分钟后退出"
        , "launch": "启动", "launchSubtitle": "在登录后按设定延迟启动应用。", "launchApps": "启动应用",
        "addLaunchApp": "添加启动应用", "addLaunchRule": "添加启动规则", "editLaunchRule": "编辑启动规则",
        "launchRuleDetail": "选择一个应用，并设置从 OctoPilot 登录启动开始计算的延迟秒数。",
        "launchAfter": "登录后 %d 秒启动", "delaySeconds": "延迟秒数", "launchVisibility": "启动后模式",
        "launchModeForeground": "显示到前台", "launchModeHidden": "隐藏应用", "launchModeCloseWindows": "关闭窗口并保留后台（Dock-only）",
        "launchForegroundHint": "应用启动后显示到前台。",
        "launchHiddenHint": "应用启动后自动隐藏，并恢复之前的前台应用。",
        "launchCloseWindowsHint": "应用启动 10 秒后关闭可关闭窗口，但保留后台或菜单栏进程。Dock 图标是否消失由该应用决定。",
        "launchCloseFailed": "应用已启动，但无法关闭其窗口",
        "runNow": "立即执行", "cancelLaunches": "取消待启动任务", "launchEnabled": "启动计划已启用", "launchPaused": "启动计划已暂停",
        "launchIn": "%d 秒后启动", "launching": "正在启动", "launched": "已启动", "alreadyRunning": "已跳过：应用已在运行",
        "launchCancelled": "已取消", "launchFailed": "启动失败：%@", "noLaunchApps": "尚未添加启动应用",
        "noLaunchAppsDetail": "添加应用并设置登录后的启动延迟。", "addFirstLaunchApp": "添加第一个启动应用",
        "loginRequired": "启用“登录时启动”后，启动规则会在每次开机登录时自动执行。", "seconds": "秒",
        "launchDuplicate": "已存在 \"%@\" 的启动规则。", "launchPlanRunning": "%d 个任务正在等待启动",
        "launchPlanIdle": "没有待启动任务", "launchPlanDone": "本次启动计划已完成"
    ]

    static func value(_ key: String, language: AppLanguage, _ arguments: CVarArg...) -> String {
        value(key, language: language, arguments: arguments)
    }

    static func value(_ key: String, language: AppLanguage, arguments: [CVarArg]) -> String {
        let useChinese: Bool
        switch language {
        case .simplifiedChinese: useChinese = true
        case .english: useChinese = false
        case .system: useChinese = Locale.autoupdatingCurrent.language.languageCode?.identifier == "zh"
        }
        let template = useChinese ? (chinese[key] ?? key) : (english[key] ?? key)
        return arguments.isEmpty ? template : String(format: template, locale: language.locale, arguments: arguments)
    }

    private static let english: [String: String] = [
            "rules": "Exit", "settings": "Settings", "addApp": "Add app", "apps": "APPS",
            "rulesSubtitle": "Hide, close windows, or quit apps after they’ve been inactive.", "dropApp": "Drop an app to add its rule",
            "invalidDrop": "Drop a macOS application (.app) to create a rule.", "duplicateRule": "A rule for \"%@\" already exists.",
            "selfRule": "OctoPilot cannot manage itself.",
            "enforcing": "Enforcing rules", "paused": "Rules paused", "enabledChecked": "%d enabled • checked %@",
            "noApps": "No apps yet", "noAppsDetail": "Add an app to automatically hide, close its windows, or quit it after inactivity.",
            "addFirstApp": "Add your first app", "edit": "Edit", "editRule": "Edit rule", "deleteRule": "Delete rule", "remove": "Remove",
            "removeConfirmTitle": "Confirm Removal", "removeConfirmMessage": "Remove “%@”? This will delete its rule.",
            "hideAfter": "Hide after %d min inactive", "closeAfter": "Close windows after %d min inactive", "quitAfter": "Quit after %d min inactive", "quitHidden": "Quit %d min after hiding",
            "addRule": "Add app rule", "editAppRule": "Edit app rule", "ruleDetail": "Choose an application, then choose one or more automatic actions.",
            "hideInactive": "Hide after inactivity", "closeInactive": "Close windows after inactivity", "quitInactive": "Quit after inactivity", "quitAfterHidden": "Quit after being hidden",
            "closeWindowHint": "Closes the app’s closable windows while leaving its process running. Whether its Dock icon disappears is controlled by that app.",
            "accessibilityRequired": "Closing windows requires Accessibility access. If it remains unavailable after an update, reset the permission and quit OctoPilot in one step, then reopen it and grant access. Current app: %@",
            "openAccessibilitySettings": "Open Accessibility Settings",
            "resetAccessibility": "Reset Permission and Quit",
            "accessibilityResetFailed": "Couldn’t reset Accessibility access: %@",
            "cancel": "Cancel", "save": "Save", "chooseApp": "Choose an app", "chooseRunning": "Choose a running app", "browse": "Browse…",
            "application": "Application", "selectedApp": "Selected application", "changeApp": "Change app", "runningApps": "Running applications",
            "browseApplications": "Choose an app from disk", "noRunningApps": "No eligible running applications found",
            "configFile": "Configuration file", "configDescription": "Rules and preferences are stored in this local file. Updating or replacing OctoPilot.app will not affect it.",
            "revealInFinder": "Show in Finder", "configSaveError": "Couldn’t save the configuration file: %@",
            "importQuitter": "Import Quitter Configuration", "importQuitterDescription": "Import rules directly from Quitter’s local preferences file; matching app identifiers already in your rules are skipped.",
            "importQuitterSuccess": "Imported %d rules and skipped %d duplicate or invalid rules.", "importQuitterEmpty": "No new rules were found to import.",
            "importQuitterError": "Couldn’t import the configuration file: %@", "importQuitterInvalid": "This is not a supported Quitter preferences file.",
            "importQuitterNotFound": "Quitter configuration file not found: %@",
            "importQuitterConfirmTitle": "Confirm Import", "importQuitterConfirmMessage": "Found %d rules to import. %d duplicate or invalid rules will be skipped. Import them?",
            "import": "Import",
            "minute": "minute", "minutes": "minutes", "language": "Language", "languageDescription": "Choose OctoPilot’s display language. Changes apply immediately.",
            "systemLanguage": "System Language", "english": "English", "simplifiedChinese": "Simplified Chinese", "checkNow": "Check now",
            "startAtLogin": "Start at Login", "showApp": "Show OctoPilot", "quitApp": "Quit OctoPilot", "enabledStatus": "OctoPilot: Enabled",
            "disabledStatus": "OctoPilot: Disabled", "disableApp": "Disable OctoPilot", "enableApp": "Enable OctoPilot",
            "loginError": "Couldn’t update the login item: %@", "aboutAutomation": "AUTOMATION", "manageRules": "Manage app rules and interface preferences.",
            "quitsIn": "Quits in %d min",
            "launch": "Launch", "launchSubtitle": "Launch apps after their configured delay following login.", "launchApps": "LAUNCH APPS",
            "addLaunchApp": "Add launch app", "addLaunchRule": "Add launch rule", "editLaunchRule": "Edit launch rule",
            "launchRuleDetail": "Choose an app and set its delay in seconds from when OctoPilot starts at login.",
            "launchAfter": "Launch %d sec after login", "delaySeconds": "Delay in seconds", "launchVisibility": "After launch",
            "launchModeForeground": "Bring to front", "launchModeHidden": "Hide application", "launchModeCloseWindows": "Close windows, keep background (Dock-only)",
            "launchForegroundHint": "Brings the application to the foreground after launch.",
            "launchHiddenHint": "Hides the application after launch and restores the previous foreground app.",
            "launchCloseWindowsHint": "Waits 10 seconds after launch, then closes the app’s closable windows while keeping its background or menu-bar process running. Whether its Dock icon disappears is controlled by that app.",
            "launchCloseFailed": "The app launched, but its windows could not be closed",
            "runNow": "Run now", "cancelLaunches": "Cancel scheduled launches", "launchEnabled": "Launch plan enabled", "launchPaused": "Launch plan paused",
            "launchIn": "Launches in %d sec", "launching": "Launching", "launched": "Launched", "alreadyRunning": "Skipped: already running",
            "launchCancelled": "Cancelled", "launchFailed": "Launch failed: %@", "noLaunchApps": "No launch apps yet",
            "noLaunchAppsDetail": "Add an app and set its delay after login.", "addFirstLaunchApp": "Add your first launch app",
            "loginRequired": "Enable Start at Login to run launch rules automatically after each boot login.", "seconds": "seconds",
            "launchDuplicate": "A launch rule for \"%@\" already exists.", "launchPlanRunning": "%d launches are waiting",
            "launchPlanIdle": "No scheduled launches", "launchPlanDone": "This launch plan is complete"
        ]
}

@MainActor
final class OctoPilotModel: ObservableObject {
    private static let safetyCheckInterval: Duration = .seconds(300)
    private static let closeWindowsLaunchGracePeriod: Duration = .seconds(10)

    private struct StoredConfiguration: Codable {
        var version: Int
        var rules: [QuitRule]
        var isEnforcing: Bool
        var language: AppLanguage
        var launchRules: [LaunchRule]
        var isLaunchSchedulingEnabled: Bool
        var lastScheduledBootSession: String?

        init(rules: [QuitRule], isEnforcing: Bool, language: AppLanguage, launchRules: [LaunchRule], isLaunchSchedulingEnabled: Bool, lastScheduledBootSession: String?) {
            version = 4
            self.rules = rules
            self.isEnforcing = isEnforcing
            self.language = language
            self.launchRules = launchRules
            self.isLaunchSchedulingEnabled = isLaunchSchedulingEnabled
            self.lastScheduledBootSession = lastScheduledBootSession
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            rules = try container.decodeIfPresent([QuitRule].self, forKey: .rules) ?? []
            isEnforcing = try container.decodeIfPresent(Bool.self, forKey: .isEnforcing) ?? true
            language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
            launchRules = try container.decodeIfPresent([LaunchRule].self, forKey: .launchRules) ?? []
            isLaunchSchedulingEnabled = try container.decodeIfPresent(Bool.self, forKey: .isLaunchSchedulingEnabled) ?? true
            lastScheduledBootSession = try container.decodeIfPresent(String.self, forKey: .lastScheduledBootSession)
        }
    }

    @Published private(set) var rules: [QuitRule] = []
    @Published private(set) var launchRules: [LaunchRule] = []
    @Published var isEnforcing = true { didSet { enforcingChanged() } }
    @Published var isLaunchSchedulingEnabled = true { didSet { launchSchedulingChanged() } }
    @Published private(set) var lastChecked = Date()
    @Published var alertMessage: String?
    @Published private(set) var alertOffersAccessibilitySettings = false
    @Published private(set) var alertOffersAccessibilityReset = false
    @Published private(set) var launchesAtLogin = false
    @Published var language: AppLanguage = .system { didSet { saveIfReady() } }
    private var launchTasks: [UUID: Task<Void, Never>] = [:]
    private let launchGate = LaunchGate(minimumStartInterval: 3)
    @Published private(set) var launchStates: [UUID: LaunchRuntimeState] = [:]
    @Published private(set) var quitDeadlines: [UUID: Date] = [:]
    private var quitRuntimeStates: [UUID: QuitRuntimeState] = [:]
    private var quitTasks: [UUID: Task<Void, Never>] = [:]
    private var quitWakeDeadlines: [UUID: Date] = [:]
    private var safetyCheckTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lastScheduledBootSession: String?
    private var isLoading = false
    private let configurationURL: URL
    private let legacyConfigurationURL: URL
    private let rulesKey = "OctoQuit.rules.v2"
    private let enforcementKey = "OctoQuit.enforcing"
    private let languageKey = "OctoQuit.language"

    init() {
        configurationURL = Self.defaultConfigurationURL()
        legacyConfigurationURL = Self.legacyConfigurationURL()
        isLoading = true
        load()
        isLoading = false
        save()
        refreshLoginItemState()
        startObservingWorkspace()
        startSafetyChecks()
        evaluateRules()
        scheduleLaunchPlanForCurrentBootIfNeeded()
        requestAccessibilityAfterResetIfNeeded()
    }

    var enabledCount: Int { rules.filter(\.isEnabled).count }
    var enabledLaunchCount: Int { launchRules.filter(\.isEnabled).count }
    var pendingLaunchCount: Int { launchStates.values.reduce(into: 0) { if case .pending = $1 { $0 += 1 } } }
    var configurationFilePath: String { configurationURL.path }

    @discardableResult
    func requestWindowControlAccess() -> Bool {
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if !trusted { showWindowControlGuidance() }
        return trusted
    }

    private func hasWindowControlAccess() -> Bool {
        AXIsProcessTrusted()
    }

    private func showWindowControlGuidance() {
        alertOffersAccessibilitySettings = true
        alertOffersAccessibilityReset = true
        alertMessage = t("accessibilityRequired", Bundle.main.bundleURL.path)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func resetAccessibilityAndQuit() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.misswell.octopilot"
        do {
            let status = try AccessibilityResetCommand(bundleIdentifier: bundleIdentifier).run()
            guard status == 0 else {
                showAlert(t("accessibilityResetFailed", "tccutil exited with status \(status)"))
                return
            }
            AccessibilityRecoveryRequest.schedule()
            NSApp.terminate(nil)
        } catch {
            showAlert(t("accessibilityResetFailed", error.localizedDescription))
        }
    }

    private func requestAccessibilityAfterResetIfNeeded() {
        guard AccessibilityRecoveryRequest.consume() else { return }
        DispatchQueue.main.async { [weak self] in
            self?.requestWindowControlAccess()
        }
    }

    func dismissAlert() {
        alertMessage = nil
        alertOffersAccessibilitySettings = false
        alertOffersAccessibilityReset = false
    }

    func showAlert(_ message: String) {
        alertOffersAccessibilitySettings = false
        alertOffersAccessibilityReset = false
        alertMessage = message
    }

    @discardableResult
    func addRule(_ rule: QuitRule) -> Bool {
        guard !isOwnApplication(rule.bundleIdentifier) else {
            showAlert(t("selfRule"))
            return false
        }
        guard !rules.contains(where: { $0.bundleIdentifier == rule.bundleIdentifier }) else {
            showAlert(t("duplicateRule", rule.appName))
            return false
        }
        rules.append(rule)
        save()
        rebuildQuitSchedule()
        return true
    }

    func updateRule(_ rule: QuitRule) {
        guard !isOwnApplication(rule.bundleIdentifier) else {
            showAlert(t("selfRule"))
            return
        }
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        save()
        rebuildQuitSchedule()
    }

    @discardableResult
    func addLaunchRule(_ rule: LaunchRule) -> Bool {
        guard !launchRules.contains(where: { $0.bundleIdentifier == rule.bundleIdentifier }) else {
            showAlert(t("launchDuplicate", rule.appName))
            return false
        }
        launchRules.append(rule)
        save()
        return true
    }

    func updateLaunchRule(_ rule: LaunchRule) {
        guard let index = launchRules.firstIndex(where: { $0.id == rule.id }) else { return }
        cancelLaunchTask(for: rule.id, markCancelled: false)
        launchRules[index] = rule
        save()
    }

    func removeLaunchRule(_ rule: LaunchRule) {
        cancelLaunchTask(for: rule.id, markCancelled: false)
        launchRules.removeAll { $0.id == rule.id }
        launchStates[rule.id] = nil
        save()
    }

    func toggleLaunchRule(_ rule: LaunchRule) {
        guard let index = launchRules.firstIndex(where: { $0.id == rule.id }) else { return }
        launchRules[index].isEnabled.toggle()
        if !launchRules[index].isEnabled { cancelLaunchTask(for: rule.id, markCancelled: true) }
        save()
    }

    func runLaunchPlanNow() {
        guard isLaunchSchedulingEnabled else { return }
        scheduleLaunchPlan()
    }

    func cancelScheduledLaunches() {
        for id in Array(launchTasks.keys) { cancelLaunchTask(for: id, markCancelled: true) }
    }

    func remove(_ rule: QuitRule) {
        cancelQuitTask(for: rule.id)
        rules.removeAll { $0.id == rule.id }
        quitRuntimeStates[rule.id] = nil
        quitDeadlines[rule.id] = nil
        save()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        rules.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    func toggleRule(_ rule: QuitRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index].isEnabled.toggle()
        save()
        rebuildQuitSchedule()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginItemState()
        } catch {
            showAlert(t("loginError", error.localizedDescription))
            refreshLoginItemState()
        }
    }

    func refreshLoginItemState() {
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    func revealConfigurationFile() {
        save()
        NSWorkspace.shared.activateFileViewerSelecting([configurationURL])
    }

    func prepareQuitterImportFromDefaultLocation() -> QuitterImportPreview? {
        let url = Self.defaultQuitterConfigurationURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            showAlert(t("importQuitterNotFound", url.path))
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let root = propertyList as? [String: Any],
                  let sourceRules = root["rules"] as? [[String: Any]] else {
                throw ImportError.invalidFormat
            }

            let existingIdentifiers = Set(rules.map(\.bundleIdentifier))
            var imported: [QuitRule] = []
            var skipped = 0
            for sourceRule in sourceRules {
                guard let bundleIdentifier = sourceRule["bundleIdentifier"] as? String,
                      let bundlePath = sourceRule["bundlePath"] as? String,
                      !bundleIdentifier.isEmpty,
                      !isOwnApplication(bundleIdentifier),
                      !existingIdentifiers.contains(bundleIdentifier),
                      !imported.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                    skipped += 1
                    continue
                }

                let hide = minutes(fromQuitterInterval: sourceRule["inactiveHideInterval"])
                let quit = minutes(fromQuitterInterval: sourceRule["inactiveQuitInterval"])
                let hiddenQuit = minutes(fromQuitterInterval: sourceRule["quitIfHiddenInterval"])
                guard hide != nil || quit != nil || hiddenQuit != nil else {
                    skipped += 1
                    continue
                }

                imported.append(QuitRule(
                    appName: appName(forBundlePath: bundlePath),
                    bundleIdentifier: bundleIdentifier,
                    bundlePath: bundlePath,
                    inactiveHideMinutes: hide,
                    inactiveQuitMinutes: quit,
                    hiddenQuitMinutes: hiddenQuit
                ))
            }

            guard !imported.isEmpty else {
                showAlert(t("importQuitterEmpty"))
                return nil
            }
            let importedEnforcementState = (root["active"] as? NSNumber)?.boolValue
            return QuitterImportPreview(rules: imported, skippedCount: skipped, isEnforcing: importedEnforcementState)
        } catch ImportError.invalidFormat {
            showAlert(t("importQuitterInvalid"))
        } catch {
            showAlert(t("importQuitterError", error.localizedDescription))
        }
        return nil
    }

    func importQuitterConfiguration(_ preview: QuitterImportPreview) {
        rules.append(contentsOf: preview.rules)
        if let isEnforcing = preview.isEnforcing {
            isLoading = true
            self.isEnforcing = isEnforcing
            isLoading = false
        }
        save()
        showAlert(t("importQuitterSuccess", preview.rules.count, preview.skippedCount))
    }

    func evaluateRules() {
        rebuildQuitSchedule()
    }

    private func startObservingWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didWakeNotification
        ]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor in
                    self?.handleWorkspaceNotification(name: name, application: application)
                }
            }
        }
    }

    private func handleWorkspaceNotification(name: Notification.Name, application: NSRunningApplication?) {
        let now = Date()
        if name == NSWorkspace.didWakeNotification {
            rebuildQuitSchedule(now: now)
            return
        }
        guard let bundleIdentifier = application?.bundleIdentifier else { return }
        let matchingRules = rules.filter { $0.bundleIdentifier == bundleIdentifier }
        guard !matchingRules.isEmpty else { return }
        for rule in matchingRules {
            var state = quitRuntimeStates[rule.id] ?? QuitRuntimeState()
            switch name {
            case NSWorkspace.didActivateApplicationNotification:
                state.lastActiveAt = now
                state.hiddenAt = nil
                state.didHideSinceActive = false
            case NSWorkspace.didDeactivateApplicationNotification:
                state.lastActiveAt = now
            case NSWorkspace.didHideApplicationNotification:
                state.hiddenAt = now
            case NSWorkspace.didUnhideApplicationNotification:
                state.hiddenAt = nil
            case NSWorkspace.didLaunchApplicationNotification:
                state.lastActiveAt = now
            case NSWorkspace.didTerminateApplicationNotification:
                state = QuitRuntimeState()
            default:
                break
            }
            quitRuntimeStates[rule.id] = state
            if isEnforcing, rule.isEnabled, !isOwnApplication(rule.bundleIdentifier) {
                evaluateQuitRule(
                    rule,
                    app: name == NSWorkspace.didTerminateApplicationNotification ? nil : application,
                    now: now
                )
            }
        }
        if isEnforcing { lastChecked = now }
    }

    private func rebuildQuitSchedule(now: Date = Date()) {
        guard isEnforcing else {
            cancelAllQuitTasks()
            return
        }
        var runningApps = [String: NSRunningApplication]()
        for app in NSWorkspace.shared.runningApplications {
            if let identifier = app.bundleIdentifier { runningApps[identifier] = app }
        }
        let enforceableRules = rules.filter { $0.isEnabled && !isOwnApplication($0.bundleIdentifier) }
        let validRuleIDs = Set(enforceableRules.map(\.id))
        for id in Array(quitTasks.keys) where !validRuleIDs.contains(id) { cancelQuitTask(for: id) }
        for id in Array(quitDeadlines.keys) where !validRuleIDs.contains(id) { quitDeadlines[id] = nil }

        for rule in enforceableRules {
            evaluateQuitRule(rule, app: runningApps[rule.bundleIdentifier], now: now)
        }
        lastChecked = now
    }

    private func evaluateQuitRule(_ rule: QuitRule, app: NSRunningApplication?, now: Date) {
        guard let app else {
            cancelQuitTask(for: rule.id)
            quitRuntimeStates[rule.id] = nil
            quitDeadlines[rule.id] = nil
            return
        }

        var state = quitRuntimeStates[rule.id] ?? QuitRuntimeState()
        if app.isActive {
            cancelQuitTask(for: rule.id)
            state.lastActiveAt = now
            state.hiddenAt = nil
            state.didHideSinceActive = false
            state.didCloseSinceActive = false
            quitRuntimeStates[rule.id] = state
            quitDeadlines[rule.id] = nil
            return
        }
        if state.lastActiveAt == nil { state.lastActiveAt = now }
        if app.isHidden {
            if state.hiddenAt == nil { state.hiddenAt = now }
        } else {
            state.hiddenAt = nil
        }

        let hideDeadline = state.didHideSinceActive ? nil : deadline(minutes: rule.inactiveHideMinutes, since: state.lastActiveAt)
        let closeDeadline = state.didCloseSinceActive ? nil : deadline(minutes: rule.inactiveCloseMinutes, since: state.lastActiveAt)
        let initialQuitDeadline = [
            deadline(minutes: rule.inactiveQuitMinutes, since: state.lastActiveAt),
            deadline(minutes: rule.hiddenQuitMinutes, since: state.hiddenAt)
        ].compactMap { $0 }.min()

        if let initialQuitDeadline, initialQuitDeadline <= now {
            app.terminate()
            quitRuntimeStates[rule.id] = state
            quitDeadlines[rule.id] = nil
            scheduleQuitWake(for: rule.id, at: now.addingTimeInterval(60), now: now)
            return
        }

        var nextDeadlines = [Date]()
        if let closeDeadline, closeDeadline <= now {
            if closeWindows(of: app) != .failed {
                state.didCloseSinceActive = true
            } else {
                nextDeadlines.append(now.addingTimeInterval(60))
            }
        } else if let closeDeadline {
            nextDeadlines.append(closeDeadline)
        }

        if let hideDeadline, hideDeadline <= now {
            app.hide()
            state.didHideSinceActive = true
            state.hiddenAt = now
        } else if let hideDeadline {
            nextDeadlines.append(hideDeadline)
        }

        let inactiveQuitDeadline = deadline(minutes: rule.inactiveQuitMinutes, since: state.lastActiveAt)
        let hiddenQuitDeadline = deadline(minutes: rule.hiddenQuitMinutes, since: state.hiddenAt)
        let quitDeadline = [inactiveQuitDeadline, hiddenQuitDeadline].compactMap { $0 }.min()
        if let inactiveQuitDeadline { nextDeadlines.append(inactiveQuitDeadline) }
        if let hiddenQuitDeadline { nextDeadlines.append(hiddenQuitDeadline) }

        quitRuntimeStates[rule.id] = state
        if let quitDeadline { setQuitDeadline(quitDeadline, for: rule.id) }
        else { quitDeadlines[rule.id] = nil }

        guard let nextDeadline = nextDeadlines.filter({ $0 > now }).min() else {
            cancelQuitTask(for: rule.id)
            return
        }
        scheduleQuitWake(for: rule.id, at: nextDeadline, now: now)
    }

    private func closeWindows(of application: NSRunningApplication) -> WindowCloseResult {
        guard hasWindowControlAccess() else { return .failed }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        guard result == .success else {
            return result == .noValue || result == .attributeUnsupported ? .noClosableWindows : .failed
        }
        guard let windows = windowsValue as? [AXUIElement] else { return .noClosableWindows }

        var didAttemptClose = false
        var actionFailed = false
        for window in windows {
            var closeButtonValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButtonValue) == .success,
                  let closeButtonValue else { continue }
            didAttemptClose = true
            let closeButton = unsafeDowncast(closeButtonValue, to: AXUIElement.self)
            if AXUIElementPerformAction(closeButton, kAXPressAction as CFString) != .success {
                actionFailed = true
            }
        }
        if actionFailed { return .failed }
        return didAttemptClose ? .closed : .noClosableWindows
    }

    private func scheduleQuitWake(for id: UUID, at deadline: Date, now: Date) {
        if quitTasks[id] != nil, quitWakeDeadlines[id] == deadline { return }
        cancelQuitTask(for: id)
        let delay = max(0, deadline.timeIntervalSince(now))
        quitWakeDeadlines[id] = deadline
        quitTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.wakeQuitRule(id)
        }
    }

    private func startSafetyChecks() {
        guard isEnforcing, safetyCheckTask == nil else { return }
        safetyCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    // Workspace notifications and per-rule deadline tasks handle normal operation.
                    // This slower sweep only recovers from a missed system notification.
                    try await Task.sleep(for: Self.safetyCheckInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.rebuildQuitSchedule()
            }
        }
    }

    private func stopSafetyChecks() {
        safetyCheckTask?.cancel()
        safetyCheckTask = nil
    }

    private func wakeQuitRule(_ id: UUID) {
        quitTasks[id] = nil
        quitWakeDeadlines[id] = nil
        guard isEnforcing,
              let rule = rules.first(where: { $0.id == id }),
              rule.isEnabled,
              !isOwnApplication(rule.bundleIdentifier) else { return }
        let app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == rule.bundleIdentifier }
        let now = Date()
        evaluateQuitRule(rule, app: app, now: now)
        lastChecked = now
    }

    private func deadline(minutes: Int?, since date: Date?) -> Date? {
        guard let minutes, let date else { return nil }
        return date.addingTimeInterval(Double(minutes * 60))
    }

    private func isOwnApplication(_ bundleIdentifier: String) -> Bool {
        guard let ownIdentifier = Bundle.main.bundleIdentifier else { return false }
        return bundleIdentifier.caseInsensitiveCompare(ownIdentifier) == .orderedSame
    }

    private func setQuitDeadline(_ deadline: Date, for id: UUID) {
        if quitDeadlines[id] != deadline { quitDeadlines[id] = deadline }
    }

    private func cancelQuitTask(for id: UUID) {
        quitTasks[id]?.cancel()
        quitTasks[id] = nil
        quitWakeDeadlines[id] = nil
    }

    private func cancelAllQuitTasks(resetRuntime: Bool = false) {
        for id in Array(quitTasks.keys) { cancelQuitTask(for: id) }
        if !quitDeadlines.isEmpty { quitDeadlines.removeAll() }
        if resetRuntime { quitRuntimeStates.removeAll() }
    }

    private func load() {
        if let data = try? Data(contentsOf: configurationURL),
           let configuration = try? JSONDecoder().decode(StoredConfiguration.self, from: data) {
            apply(configuration)
            return
        }

        if let data = try? Data(contentsOf: legacyConfigurationURL),
           let configuration = try? JSONDecoder().decode(StoredConfiguration.self, from: data) {
            apply(configuration)
            return
        }

        // One-time migration from versions that used UserDefaults.
        let defaults = UserDefaults(suiteName: "com.octoqit.app") ?? .standard
        isEnforcing = defaults.object(forKey: enforcementKey) as? Bool ?? true
        language = AppLanguage(rawValue: defaults.string(forKey: languageKey) ?? "") ?? .system
        guard let data = defaults.data(forKey: rulesKey),
              let saved = try? JSONDecoder().decode([QuitRule].self, from: data) else { return }
        rules = saved
    }

    private func apply(_ configuration: StoredConfiguration) {
        isEnforcing = configuration.isEnforcing
        language = configuration.language
        rules = configuration.rules
        launchRules = configuration.launchRules
        isLaunchSchedulingEnabled = configuration.isLaunchSchedulingEnabled
        lastScheduledBootSession = configuration.lastScheduledBootSession
    }

    private func save() {
        let configuration = StoredConfiguration(
            rules: rules,
            isEnforcing: isEnforcing,
            language: language,
            launchRules: launchRules,
            isLaunchSchedulingEnabled: isLaunchSchedulingEnabled,
            lastScheduledBootSession: lastScheduledBootSession
        )
        do {
            let directory = configurationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: configurationURL, options: .atomic)
        } catch {
            showAlert(t("configSaveError", error.localizedDescription))
        }
    }

    private func saveIfReady() {
        guard !isLoading else { return }
        save()
    }

    private func enforcingChanged() {
        guard !isLoading else { return }
        if isEnforcing {
            startSafetyChecks()
            rebuildQuitSchedule()
        } else {
            stopSafetyChecks()
            cancelAllQuitTasks(resetRuntime: true)
        }
        save()
    }

    private func launchSchedulingChanged() {
        guard !isLoading else { return }
        if !isLaunchSchedulingEnabled { cancelScheduledLaunches() }
        save()
    }

    private func scheduleLaunchPlanForCurrentBootIfNeeded() {
        guard isLaunchSchedulingEnabled, launchesAtLogin else { return }
        let bootSession = Self.bootSessionIdentifier()
        guard lastScheduledBootSession != bootSession else { return }
        lastScheduledBootSession = bootSession
        save()
        scheduleLaunchPlan()
    }

    private func scheduleLaunchPlan() {
        cancelScheduledLaunches()
        let now = Date()
        for rule in launchRules where rule.isEnabled {
            if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == rule.bundleIdentifier }) {
                launchStates[rule.id] = .skippedAlreadyRunning
                continue
            }
            let dueDate = now.addingTimeInterval(Double(rule.delaySeconds))
            launchStates[rule.id] = .pending(dueDate)
            launchTasks[rule.id] = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(rule.delaySeconds))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.launch(ruleID: rule.id)
            }
        }
    }

    private func launch(ruleID: UUID) async {
        launchTasks[ruleID] = nil
        await launchGate.run { [weak self] in
            await self?.performLaunch(ruleID: ruleID)
        }
    }

    private func performLaunch(ruleID: UUID) async {
        guard !Task.isCancelled else {
            launchStates[ruleID] = .cancelled
            return
        }
        guard isLaunchSchedulingEnabled,
              let rule = launchRules.first(where: { $0.id == ruleID }), rule.isEnabled else {
            launchStates[ruleID] = .cancelled
            return
        }
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == rule.bundleIdentifier }) {
            launchStates[ruleID] = .skippedAlreadyRunning
            return
        }
        let url = URL(fileURLWithPath: rule.bundlePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            launchStates[ruleID] = .failed("App not found")
            return
        }
        launchStates[ruleID] = .launching
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = rule.visibilityMode == .foreground
        let previousFrontmostApplication = NSWorkspace.shared.frontmostApplication
        do {
            let launchedApplication = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            switch rule.visibilityMode {
            case .foreground:
                break
            case .hidden:
                await hideAfterLaunch(launchedApplication, restoring: previousFrontmostApplication)
            case .closeWindows:
                guard await closeWindowsAfterLaunch(launchedApplication, restoring: previousFrontmostApplication) else {
                    launchStates[ruleID] = .failed(t("launchCloseFailed"))
                    return
                }
            }
            launchStates[ruleID] = .launched
        } catch {
            launchStates[ruleID] = .failed(error.localizedDescription)
        }
    }

    private func hideAfterLaunch(_ application: NSRunningApplication, restoring previousApplication: NSRunningApplication?) async {
        _ = await retryPostLaunchAction(application, restoring: previousApplication) {
            application.hide()
        }
    }

    private func closeWindowsAfterLaunch(_ application: NSRunningApplication, restoring previousApplication: NSRunningApplication?) async -> Bool {
        do {
            try await Task.sleep(for: Self.closeWindowsLaunchGracePeriod)
        } catch {
            return false
        }
        guard !application.isTerminated else { return false }
        return await retryPostLaunchAction(application, restoring: previousApplication) {
            self.closeWindows(of: application).postLaunchResult
        }
    }

    private func retryPostLaunchAction(
        _ application: NSRunningApplication,
        restoring previousApplication: NSRunningApplication?,
        action: () -> Bool?
    ) async -> Bool {
        var completed = true
        // Some apps create or reactivate their first window after the workspace
        // launch callback returns, so retry briefly without keeping a poller alive.
        for delayMilliseconds in [0, 250, 750, 1_500] {
            if delayMilliseconds > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(delayMilliseconds))
                } catch {
                    return completed
                }
            }
            guard !application.isTerminated else { return false }
            let stoleFocus = application.isActive
            if let result = action() { completed = result }
            if stoleFocus,
               let previousApplication,
               !previousApplication.isTerminated,
               previousApplication.processIdentifier != application.processIdentifier {
                previousApplication.activate(options: [])
            }
        }
        return !application.isTerminated && completed
    }

    private func cancelLaunchTask(for id: UUID, markCancelled: Bool) {
        launchTasks[id]?.cancel()
        launchTasks[id] = nil
        if markCancelled { launchStates[id] = .cancelled }
    }

    private static func defaultConfigurationURL() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent("OctoPilot", isDirectory: true).appendingPathComponent("config.json")
    }

    private static func legacyConfigurationURL() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent("OctoQuit", isDirectory: true).appendingPathComponent("config.json")
    }

    private static func bootSessionIdentifier() -> String {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0 else {
            return "uptime-\(Int(ProcessInfo.processInfo.systemUptime))"
        }
        return "boot-\(bootTime.tv_sec)"
    }

    private static func defaultQuitterConfigurationURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/com.marcoarment.quitter.plist")
    }

    private func minutes(fromQuitterInterval value: Any?) -> Int? {
        guard let seconds = (value as? NSNumber)?.doubleValue, seconds > 0 else { return nil }
        return max(1, Int((seconds / 60).rounded()))
    }

    private func appName(forBundlePath path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let bundle = Bundle(url: url)
        return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    private enum ImportError: LocalizedError {
        case invalidFormat
    }

    func t(_ key: String, _ arguments: CVarArg...) -> String { AppText.value(key, language: language, arguments: arguments) }
    var timeString: String { lastChecked.formatted(.dateTime.hour().minute().locale(language.locale)) }
}

enum MainSection { case exit, launch, settings }

struct ContentView: View {
    @EnvironmentObject private var model: OctoPilotModel
    @State private var showingAdd = false
    @State private var editingRule: QuitRule?
    @State private var showingLaunchAdd = false
    @State private var editingLaunchRule: LaunchRule?
    @State private var isDropTarget = false
    @State private var section: MainSection = .exit

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: $section)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if section == .exit {
                    header
                    if model.rules.isEmpty { EmptyRulesView(addRule: { showingAdd = true }) }
                    else { rulesList }
                } else if section == .launch {
                    LaunchRulesView(showingAdd: $showingLaunchAdd, editingRule: $editingLaunchRule)
                } else {
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(isPresented: $showingAdd) { RuleEditor(rule: nil).environmentObject(model) }
        .sheet(item: $editingRule) { rule in RuleEditor(rule: rule).environmentObject(model) }
        .sheet(isPresented: $showingLaunchAdd) { LaunchRuleEditor(rule: nil).environmentObject(model) }
        .sheet(item: $editingLaunchRule) { rule in LaunchRuleEditor(rule: rule).environmentObject(model) }
        .alert("OctoPilot", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.dismissAlert() } })) {
            if model.alertOffersAccessibilityReset {
                Button(model.t("resetAccessibility"), role: .destructive) {
                    model.resetAccessibilityAndQuit()
                }
            }
            if model.alertOffersAccessibilitySettings {
                Button(model.t("openAccessibilitySettings")) {
                    model.openAccessibilitySettings()
                    model.dismissAlert()
                }
            }
            Button("OK", role: .cancel) { model.dismissAlert() }
        } message: { Text(model.alertMessage ?? "") }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget, perform: acceptDrop)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(12)
                    .overlay(Text(model.t("dropApp")).font(.headline).padding(16).background(.regularMaterial, in: Capsule()))
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.t("rules")).font(.system(size: 30, weight: .bold))
                Text(model.t("rulesSubtitle")).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showingAdd = true } label: { Label(model.t("addApp"), systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 28)
    }

    private var rulesList: some View {
        List {
            Section(model.t("apps")) {
                ForEach(model.rules) { rule in
                    RuleRow(
                        rule: rule,
                        edit: { editingRule = rule },
                        toggle: { model.toggleRule(rule) },
                        remove: { model.remove(rule) }
                    )
                        .contextMenu {
                            Button(model.t("editRule")) { editingRule = rule }
                            Divider()
                            Button(model.t("deleteRule"), role: .destructive) { model.remove(rule) }
                        }
                }
                .onMove(perform: model.move)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else { url = item as? URL }
            guard let url else { return }
            Task { @MainActor in addApp(at: url) }
        }
        return true
    }

    private func addApp(at url: URL) {
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else {
            model.showAlert(model.t("invalidDrop"))
            return
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        model.addRule(QuitRule(appName: name, bundleIdentifier: identifier, bundlePath: url.path, inactiveQuitMinutes: 10))
    }
}

struct Sidebar: View {
    @EnvironmentObject private var model: OctoPilotModel
    @Binding var section: MainSection
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "timer").font(.title2.bold()).foregroundStyle(.blue)
                Text("OctoPilot").font(.headline)
            }
            .padding(.horizontal, 22).padding(.top, 30).padding(.bottom, 34)
            Button { section = .exit } label: {
                Label(model.t("rules"), systemImage: "list.bullet.rectangle")
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(section == .exit ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            Button { section = .launch } label: {
                Label(model.t("launch"), systemImage: "play.circle")
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(section == .launch ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            Button { section = .settings } label: {
                Label(model.t("settings"), systemImage: "gearshape")
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(section == .settings ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            Spacer()
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Circle().fill(model.isEnforcing ? .green : .orange).frame(width: 8, height: 8)
                    Text(model.isEnforcing ? model.t("enforcing") : model.t("paused")).font(.subheadline.weight(.medium))
                    Spacer()
                    Toggle("", isOn: $model.isEnforcing).labelsHidden().controlSize(.mini)
                }
                Text(model.t("enabledChecked", model.enabledCount, model.timeString))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(15).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12)).padding(16)
        }
        .frame(width: 230).background(Color(nsColor: .controlBackgroundColor))
    }
}

struct EmptyRulesView: View {
    @EnvironmentObject private var model: OctoPilotModel
    let addRule: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "moon.zzz").font(.system(size: 46)).foregroundStyle(.blue)
            Text(model.t("noApps")).font(.title2.bold())
            Text(model.t("noAppsDetail")).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(model.t("addFirstApp"), action: addRule).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 70)
    }
}

struct RuleRow: View {
    @EnvironmentObject private var model: OctoPilotModel
    @State private var showingRemoveConfirmation = false
    let rule: QuitRule
    let edit: () -> Void
    let toggle: () -> Void
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            AppIcon(path: rule.bundlePath)
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.appName).font(.body.weight(.semibold))
                Text(ruleSummary(rule)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let deadline = model.quitDeadlines[rule.id] {
                QuitCountdownBadge(deadline: deadline)
            }
            Button(model.t("edit"), action: edit).buttonStyle(.borderless)
            Button { showingRemoveConfirmation = true } label: {
                Image(systemName: "trash")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help(model.t("remove"))
            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { _ in toggle() })).labelsHidden()
        }
        .padding(.vertical, 5)
        .alert(model.t("removeConfirmTitle"), isPresented: $showingRemoveConfirmation) {
            Button(model.t("remove"), role: .destructive, action: remove)
            Button(model.t("cancel"), role: .cancel) {}
        } message: {
            Text(model.t("removeConfirmMessage", rule.appName))
        }
    }

    private func ruleSummary(_ rule: QuitRule) -> String {
        var items: [String] = []
        if let m = rule.inactiveHideMinutes { items.append(model.t("hideAfter", m)) }
        if let m = rule.inactiveCloseMinutes { items.append(model.t("closeAfter", m)) }
        if let m = rule.inactiveQuitMinutes { items.append(model.t("quitAfter", m)) }
        if let m = rule.hiddenQuitMinutes { items.append(model.t("quitHidden", m)) }
        return items.joined(separator: " • ")
    }
}

struct QuitCountdownBadge: View {
    @EnvironmentObject private var model: OctoPilotModel
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let remaining = max(0, Int(ceil(deadline.timeIntervalSince(context.date) / 60)))
            Text(model.t("quitsIn", remaining))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .monospacedDigit()
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.orange.opacity(0.12), in: Capsule())
        }
    }
}

@MainActor
private final class AppIconCache {
    static let shared = AppIconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: key)
        return image
    }
}

struct AppIcon: View {
    var path: String?
    var body: some View {
        Group {
            if let path {
                Image(nsImage: AppIconCache.shared.icon(for: path)).resizable().interpolation(.high)
            } else { Image(systemName: "app.fill").resizable().scaledToFit().padding(9).foregroundStyle(.blue) }
        }
        .frame(width: 40, height: 40).background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
    }
}

struct RuleEditor: View {
    @EnvironmentObject private var model: OctoPilotModel
    @Environment(\.dismiss) private var dismiss
    private let original: QuitRule?
    @State private var appName = ""
    @State private var bundleIdentifier = ""
    @State private var bundlePath: String?
    @State private var hideEnabled = false
    @State private var hideMinutes = 10
    @State private var closeEnabled = false
    @State private var closeMinutes = 10
    @State private var inactiveQuitEnabled = true
    @State private var inactiveQuitMinutes = 10
    @State private var hiddenQuitEnabled = false
    @State private var hiddenQuitMinutes = 10
    @State private var runningApps: [NSRunningApplication] = []

    init(rule: QuitRule?) {
        original = rule
        _appName = State(initialValue: rule?.appName ?? "")
        _bundleIdentifier = State(initialValue: rule?.bundleIdentifier ?? "")
        _bundlePath = State(initialValue: rule?.bundlePath)
        _hideEnabled = State(initialValue: rule?.inactiveHideMinutes != nil)
        _hideMinutes = State(initialValue: rule?.inactiveHideMinutes ?? 10)
        _closeEnabled = State(initialValue: rule?.inactiveCloseMinutes != nil)
        _closeMinutes = State(initialValue: rule?.inactiveCloseMinutes ?? 10)
        _inactiveQuitEnabled = State(initialValue: rule?.inactiveQuitMinutes != nil || rule == nil)
        _inactiveQuitMinutes = State(initialValue: rule?.inactiveQuitMinutes ?? 10)
        _hiddenQuitEnabled = State(initialValue: rule?.hiddenQuitMinutes != nil)
        _hiddenQuitMinutes = State(initialValue: rule?.hiddenQuitMinutes ?? 10)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(original == nil ? model.t("addRule") : model.t("editAppRule")).font(.title2.bold())
            Text(model.t("ruleDetail")).foregroundStyle(.secondary)
            appPicker
            Divider()
            ActionSetting(title: model.t("hideInactive"), enabled: $hideEnabled, minutes: $hideMinutes)
            ActionSetting(title: model.t("closeInactive"), enabled: $closeEnabled, minutes: $closeMinutes)
            Text(model.t("closeWindowHint")).font(.caption).foregroundStyle(.secondary)
            ActionSetting(title: model.t("quitInactive"), enabled: $inactiveQuitEnabled, minutes: $inactiveQuitMinutes)
            ActionSetting(title: model.t("quitAfterHidden"), enabled: $hiddenQuitEnabled, minutes: $hiddenQuitMinutes)
            Spacer()
            HStack { Spacer(); Button(model.t("cancel")) { dismiss() }; Button(original == nil ? model.t("addApp") : model.t("save")) { save() }.buttonStyle(.borderedProminent).disabled(bundleIdentifier.isEmpty || !(hideEnabled || closeEnabled || inactiveQuitEnabled || hiddenQuitEnabled)) }
        }
        .padding(28).frame(width: 520, height: 625)
        .onAppear { runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") } }
        .onChange(of: closeEnabled) { _, enabled in
            if enabled { model.requestWindowControlAccess() }
        }
    }

    private var appPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t("application")).font(.headline)
            HStack(spacing: 12) {
                AppIcon(path: bundlePath)
                    .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(appName.isEmpty ? model.t("chooseApp") : appName).font(.body.weight(.medium)).lineLimit(1)
                    Text(bundleIdentifier.isEmpty ? model.t("selectedApp") : bundleIdentifier)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Menu {
                    if runningApps.isEmpty {
                        Text(model.t("noRunningApps"))
                    } else {
                        Section(model.t("runningApps")) {
                            ForEach(runningApps, id: \.processIdentifier) { app in
                                Button(app.localizedName ?? app.bundleIdentifier ?? "Unknown") {
                                    selectRunningApp(app.bundleIdentifier ?? "")
                                }
                            }
                        }
                    }
                    Divider()
                    Button(model.t("browseApplications"), action: browseForApp)
                } label: {
                    Label(appName.isEmpty ? model.t("chooseApp") : model.t("changeApp"), systemImage: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        }
    }

    private func selectRunningApp(_ identifier: String) {
        guard let app = runningApps.first(where: { $0.bundleIdentifier == identifier }) else { return }
        appName = app.localizedName ?? identifier
        bundleIdentifier = identifier
        bundlePath = app.bundleURL?.path
    }

    private func browseForApp() {
        let panel = NSOpenPanel()
        panel.title = model.t("chooseApp")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return }
        appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        bundleIdentifier = identifier
        bundlePath = url.path
    }

    private func save() {
        let rule = QuitRule(
            id: original?.id ?? UUID(), appName: appName, bundleIdentifier: bundleIdentifier, bundlePath: bundlePath,
            inactiveHideMinutes: hideEnabled ? hideMinutes : nil,
            inactiveCloseMinutes: closeEnabled ? closeMinutes : nil,
            inactiveQuitMinutes: inactiveQuitEnabled ? inactiveQuitMinutes : nil,
            hiddenQuitMinutes: hiddenQuitEnabled ? hiddenQuitMinutes : nil,
            isEnabled: original?.isEnabled ?? true
        )
        if original == nil {
            if model.addRule(rule) { dismiss() }
        } else {
            model.updateRule(rule)
            dismiss()
        }
    }
}

struct LaunchRulesView: View {
    @EnvironmentObject private var model: OctoPilotModel
    @Binding var showingAdd: Bool
    @Binding var editingRule: LaunchRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.t("launch")).font(.system(size: 30, weight: .bold))
                    Text(model.t("launchSubtitle")).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingAdd = true } label: { Label(model.t("addLaunchApp"), systemImage: "plus") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 22)

            launchControls

            if model.launchRules.isEmpty {
                EmptyLaunchRulesView(addRule: { showingAdd = true })
            } else {
                List {
                    Section(model.t("launchApps")) {
                        ForEach(model.launchRules) { rule in
                            LaunchRuleRow(
                                rule: rule,
                                edit: { editingRule = rule },
                                toggle: { model.toggleLaunchRule(rule) },
                                remove: { model.removeLaunchRule(rule) }
                            )
                                .contextMenu {
                                    Button(model.t("edit")) { editingRule = rule }
                                    Divider()
                                    Button(model.t("deleteRule"), role: .destructive) { model.removeLaunchRule(rule) }
                                }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .padding(.horizontal, 22).padding(.bottom, 20)
            }
        }
    }

    private var launchControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(model.t("launchEnabled"), isOn: $model.isLaunchSchedulingEnabled).toggleStyle(.switch)
                Spacer()
                Button(model.t("cancelLaunches")) { model.cancelScheduledLaunches() }
                    .disabled(model.pendingLaunchCount == 0)
                Button(model.t("runNow")) { model.runLaunchPlanNow() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isLaunchSchedulingEnabled || model.enabledLaunchCount == 0)
            }
            Text(model.launchesAtLogin ? launchPlanMessage : model.t("loginRequired"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 36).padding(.bottom, 16)
    }

    private var launchPlanMessage: String {
        if model.pendingLaunchCount > 0 { return model.t("launchPlanRunning", model.pendingLaunchCount) }
        if model.launchRules.isEmpty { return model.t("launchPlanIdle") }
        return model.t("launchPlanDone")
    }
}

struct EmptyLaunchRulesView: View {
    @EnvironmentObject private var model: OctoPilotModel
    let addRule: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.circle").font(.system(size: 46)).foregroundStyle(.blue)
            Text(model.t("noLaunchApps")).font(.title2.bold())
            Text(model.t("noLaunchAppsDetail")).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(model.t("addFirstLaunchApp"), action: addRule).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 70)
    }
}

struct LaunchRuleRow: View {
    @EnvironmentObject private var model: OctoPilotModel
    @State private var showingRemoveConfirmation = false
    let rule: LaunchRule
    let edit: () -> Void
    let toggle: () -> Void
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            AppIcon(path: rule.bundlePath)
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.appName).font(.body.weight(.semibold))
                Text(model.t("launchAfter", rule.delaySeconds) + " • " + model.t(rule.visibilityMode.titleKey))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let state = model.launchStates[rule.id] {
                LaunchStatusBadge(state: state)
            }
            Button(model.t("edit"), action: edit).buttonStyle(.borderless)
            Button { showingRemoveConfirmation = true } label: {
                Image(systemName: "trash")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help(model.t("remove"))
            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { _ in toggle() })).labelsHidden()
        }
        .padding(.vertical, 5)
        .alert(model.t("removeConfirmTitle"), isPresented: $showingRemoveConfirmation) {
            Button(model.t("remove"), role: .destructive, action: remove)
            Button(model.t("cancel"), role: .cancel) {}
        } message: {
            Text(model.t("removeConfirmMessage", rule.appName))
        }
    }

}

struct LaunchStatusBadge: View {
    @EnvironmentObject private var model: OctoPilotModel
    let state: LaunchRuntimeState

    @ViewBuilder
    var body: some View {
        switch state {
        case .pending(let deadline):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                badge(model.t("launchIn", max(0, Int(ceil(deadline.timeIntervalSince(context.date))))), color: .blue)
            }
        case .launching:
            badge(model.t("launching"), color: .orange)
        case .launched:
            badge(model.t("launched"), color: .green)
        case .skippedAlreadyRunning:
            badge(model.t("alreadyRunning"), color: .secondary)
        case .cancelled:
            badge(model.t("launchCancelled"), color: .secondary)
        case .failed(let message):
            badge(model.t("launchFailed", message), color: .red)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct LaunchRuleEditor: View {
    @EnvironmentObject private var model: OctoPilotModel
    @Environment(\.dismiss) private var dismiss
    private let original: LaunchRule?
    @State private var appName = ""
    @State private var bundleIdentifier = ""
    @State private var bundlePath = ""
    @State private var delaySeconds = 30
    @State private var visibilityMode: LaunchVisibilityMode = .hidden
    @State private var runningApps: [NSRunningApplication] = []

    init(rule: LaunchRule?) {
        original = rule
        _appName = State(initialValue: rule?.appName ?? "")
        _bundleIdentifier = State(initialValue: rule?.bundleIdentifier ?? "")
        _bundlePath = State(initialValue: rule?.bundlePath ?? "")
        _delaySeconds = State(initialValue: rule?.delaySeconds ?? 30)
        _visibilityMode = State(initialValue: rule?.visibilityMode ?? .hidden)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(original == nil ? model.t("addLaunchRule") : model.t("editLaunchRule")).font(.title2.bold())
            Text(model.t("launchRuleDetail")).foregroundStyle(.secondary)
            appPicker
            Divider()
            HStack {
                Text(model.t("delaySeconds"))
                Spacer()
                TextField(model.t("seconds"), value: $delaySeconds, format: .number)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 68)
                Stepper("", value: $delaySeconds, in: 0...86_400).labelsHidden()
                Text(model.t("seconds")).font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(model.t("launchVisibility")).font(.headline)
                Picker(model.t("launchVisibility"), selection: $visibilityMode) {
                    ForEach(LaunchVisibilityMode.allCases) { mode in
                        Text(model.t(mode.titleKey)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }
            Text(model.t(visibilityMode.hintKey))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button(model.t("cancel")) { dismiss() }
                Button(original == nil ? model.t("addLaunchApp") : model.t("save")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(bundleIdentifier.isEmpty || bundlePath.isEmpty)
            }
        }
        .padding(28).frame(width: 560, height: 500)
        .onAppear(perform: refreshRunningApps)
        .onChange(of: delaySeconds) { _, value in delaySeconds = min(max(value, 0), 86_400) }
        .onChange(of: visibilityMode) { _, mode in
            if mode.requiresAccessibility { model.requestWindowControlAccess() }
        }
    }

    private var appPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t("application")).font(.headline)
            HStack(spacing: 12) {
                AppIcon(path: bundlePath.isEmpty ? nil : bundlePath).frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(appName.isEmpty ? model.t("chooseApp") : appName).font(.body.weight(.medium)).lineLimit(1)
                    Text(bundleIdentifier.isEmpty ? model.t("selectedApp") : bundleIdentifier)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Menu {
                    if runningApps.isEmpty {
                        Text(model.t("noRunningApps"))
                    } else {
                        Section(model.t("runningApps")) {
                            ForEach(runningApps, id: \.processIdentifier) { app in
                                Button(app.localizedName ?? app.bundleIdentifier ?? "Unknown") {
                                    selectRunningApp(app)
                                }
                            }
                        }
                    }
                    Divider()
                    Button(model.t("browseApplications"), action: browseForApp)
                } label: {
                    Label(appName.isEmpty ? model.t("chooseApp") : model.t("changeApp"), systemImage: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
            }
            .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        }
    }

    private func refreshRunningApps() {
        var seenIdentifiers = Set<String>()
        runningApps = NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .regular,
                      let identifier = app.bundleIdentifier,
                      identifier != Bundle.main.bundleIdentifier,
                      app.bundleURL != nil else { return false }
                return seenIdentifiers.insert(identifier).inserted
            }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private func selectRunningApp(_ app: NSRunningApplication) {
        guard let identifier = app.bundleIdentifier, let url = app.bundleURL else { return }
        appName = app.localizedName ?? identifier
        bundleIdentifier = identifier
        bundlePath = url.path
    }

    private func browseForApp() {
        let panel = NSOpenPanel()
        panel.title = model.t("chooseApp")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return }
        appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        bundleIdentifier = identifier
        bundlePath = url.path
    }

    private func save() {
        let rule = LaunchRule(
            id: original?.id ?? UUID(),
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            bundlePath: bundlePath,
            delaySeconds: delaySeconds,
            isEnabled: original?.isEnabled ?? true,
            visibilityMode: visibilityMode
        )
        if original == nil {
            if model.addLaunchRule(rule) { dismiss() }
        } else {
            model.updateLaunchRule(rule)
            dismiss()
        }
    }
}

struct ActionSetting: View {
    @EnvironmentObject private var model: OctoPilotModel
    let title: String
    @Binding var enabled: Bool
    @Binding var minutes: Int
    var body: some View {
        HStack(spacing: 12) {
            Toggle(title, isOn: $enabled).toggleStyle(.checkbox)
            Spacer()
            HStack(spacing: 6) {
                TextField(model.t("minutes"), value: $minutes, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Stepper("", value: $minutes, in: 1...720).labelsHidden()
                Text(minutes == 1 ? model.t("minute") : model.t("minutes"))
                    .font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            }
            .disabled(!enabled)
        }
        .onChange(of: minutes) { _, newValue in minutes = min(max(newValue, 1), 720) }
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var model: OctoPilotModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.isEnforcing ? model.t("enabledStatus") : model.t("disabledStatus"))
        Divider()
        Button(model.isEnforcing ? model.t("disableApp") : model.t("enableApp")) { model.isEnforcing.toggle() }
        Button(model.t("checkNow")) { model.evaluateRules() }
        Divider()
        Button(model.t("runNow")) { model.runLaunchPlanNow() }
            .disabled(!model.isLaunchSchedulingEnabled || model.enabledLaunchCount == 0)
        Button(model.t("cancelLaunches")) { model.cancelScheduledLaunches() }
            .disabled(model.pendingLaunchCount == 0)
        Divider()
        Toggle(model.t("startAtLogin"), isOn: Binding(get: { model.launchesAtLogin }, set: { model.setLaunchAtLogin($0) }))
        Button(model.t("showApp"), action: showMainWindow)
        Divider()
        Button(model.t("quitApp")) { NSApp.terminate(nil) }
    }

    private func showMainWindow() {
        if let window = mainWindow {
            present(window)
            return
        }

        openWindow(id: "main")
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let window = mainWindow { present(window) }
        }
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.title == "OctoPilot" && $0.canBecomeMain }
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: OctoPilotModel
    @State private var quitterImportPreview: QuitterImportPreview?
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.t("settings")).font(.system(size: 30, weight: .bold))
                Text(model.t("manageRules")).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(model.t("language")).font(.headline)
                Text(model.t("languageDescription")).font(.subheadline).foregroundStyle(.secondary)
                Picker(model.t("language"), selection: $model.language) {
                    Text(model.t("systemLanguage")).tag(AppLanguage.system)
                    Text(model.t("english")).tag(AppLanguage.english)
                    Text(model.t("simplifiedChinese")).tag(AppLanguage.simplifiedChinese)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 390)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(model.t("configFile")).font(.headline)
                Text(model.t("configDescription")).font(.subheadline).foregroundStyle(.secondary)
                Text(model.configurationFilePath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button(model.t("revealInFinder")) { model.revealConfigurationFile() }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(model.t("importQuitter")).font(.headline)
                Text(model.t("importQuitterDescription")).font(.subheadline).foregroundStyle(.secondary)
                Button(model.t("importQuitter")) { quitterImportPreview = model.prepareQuitterImportFromDefaultLocation() }
            }
            Spacer()
        }
        .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 30)
        .alert(model.t("importQuitterConfirmTitle"), isPresented: Binding(get: { quitterImportPreview != nil }, set: { if !$0 { quitterImportPreview = nil } })) {
            Button(model.t("cancel"), role: .cancel) { quitterImportPreview = nil }
            Button(model.t("import")) {
                if let preview = quitterImportPreview { model.importQuitterConfiguration(preview) }
                quitterImportPreview = nil
            }
        } message: {
            if let preview = quitterImportPreview {
                Text(model.t("importQuitterConfirmMessage", preview.rules.count, preview.skippedCount))
            }
        }
    }

}
