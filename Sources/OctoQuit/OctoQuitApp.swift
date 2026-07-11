import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@main
struct OctoQuitApp: App {
    @StateObject private var model = QuitterModel()

    var body: some Scene {
        WindowGroup("OctoQuit") {
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
    var inactiveQuitMinutes: Int?
    var hiddenQuitMinutes: Int?
    var isEnabled = true
    var lastActiveAt: Date?
    var hiddenAt: Date?
    var didHideSinceActive = false

    var hasAction: Bool { inactiveHideMinutes != nil || inactiveQuitMinutes != nil || hiddenQuitMinutes != nil }
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
        "rules": "规则", "settings": "设置", "addApp": "添加应用", "apps": "应用",
        "rulesSubtitle": "在应用闲置一段时间后自动隐藏或退出。",
        "dropApp": "拖入应用以添加规则", "invalidDrop": "请拖入 macOS 应用（.app）以创建规则。",
        "duplicateRule": "已存在 \"%@\" 的规则。", "enforcing": "规则执行中", "paused": "规则已暂停",
        "enabledChecked": "%d 条已启用 · 检查于 %@", "noApps": "尚未添加应用",
        "noAppsDetail": "添加一个应用，在闲置后自动隐藏或退出。", "addFirstApp": "添加第一个应用",
        "edit": "编辑", "editRule": "编辑规则", "deleteRule": "删除规则",
        "hideAfter": "闲置 %d 分钟后隐藏", "quitAfter": "闲置 %d 分钟后退出", "quitHidden": "隐藏 %d 分钟后退出",
        "addRule": "添加应用规则", "editAppRule": "编辑应用规则", "ruleDetail": "选择一个应用，然后设置一个或多个自动操作。",
        "hideInactive": "闲置后隐藏", "quitInactive": "闲置后退出", "quitAfterHidden": "隐藏后退出",
        "cancel": "取消", "save": "存储", "chooseApp": "选择应用", "chooseRunning": "选择正在运行的应用",
        "browse": "浏览…", "minute": "分钟", "minutes": "分钟", "language": "语言",
        "application": "应用", "selectedApp": "已选应用", "changeApp": "更换应用", "runningApps": "正在运行的应用",
        "browseApplications": "从磁盘选择应用", "noRunningApps": "未检测到可选的运行应用",
        "configFile": "配置文件", "configDescription": "规则和偏好保存在此本机文件中。更新或替换 OctoQuit.app 不会影响它。",
        "revealInFinder": "在访达中显示", "configSaveError": "无法保存配置文件：%@",
        "importQuitter": "导入 Quitter 配置", "importQuitterDescription": "直接从 Quitter 的本机偏好文件导入规则；已存在相同应用标识的规则会被跳过。",
        "importQuitterSuccess": "已导入 %d 条规则，跳过 %d 条重复或无效规则。", "importQuitterEmpty": "没有发现可导入的新规则。",
        "importQuitterError": "无法导入配置文件：%@", "importQuitterInvalid": "这不是受支持的 Quitter 偏好文件。",
        "importQuitterNotFound": "未找到 Quitter 配置文件：%@",
        "languageDescription": "选择 OctoQuit 的显示语言。更改会立即生效。", "systemLanguage": "跟随系统",
        "english": "English", "simplifiedChinese": "简体中文", "checkNow": "立即检查", "startAtLogin": "登录时启动",
        "showApp": "显示 OctoQuit", "quitApp": "退出 OctoQuit", "enabledStatus": "OctoQuit：已启用",
        "disabledStatus": "OctoQuit：已停用", "disableApp": "停用 OctoQuit", "enableApp": "启用 OctoQuit",
        "loginError": "无法更新登录启动项：%@", "aboutAutomation": "自动化", "manageRules": "管理应用规则和界面偏好。",
        "quitsIn": "将在 %d 分钟后退出"
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
        let template = useChinese ? (chinese[key] ?? key) : english(key)
        return arguments.isEmpty ? template : String(format: template, locale: language.locale, arguments: arguments)
    }

    private static func english(_ key: String) -> String {
        [
            "rules": "Rules", "settings": "Settings", "addApp": "Add app", "apps": "APPS",
            "rulesSubtitle": "Hide or quit apps after they’ve been inactive.", "dropApp": "Drop an app to add its rule",
            "invalidDrop": "Drop a macOS application (.app) to create a rule.", "duplicateRule": "A rule for \"%@\" already exists.",
            "enforcing": "Enforcing rules", "paused": "Rules paused", "enabledChecked": "%d enabled • checked %@",
            "noApps": "No apps yet", "noAppsDetail": "Add an app to automatically hide or quit it after inactivity.",
            "addFirstApp": "Add your first app", "edit": "Edit", "editRule": "Edit rule", "deleteRule": "Delete rule",
            "hideAfter": "Hide after %d min inactive", "quitAfter": "Quit after %d min inactive", "quitHidden": "Quit %d min after hiding",
            "addRule": "Add app rule", "editAppRule": "Edit app rule", "ruleDetail": "Choose an application, then choose one or more automatic actions.",
            "hideInactive": "Hide after inactivity", "quitInactive": "Quit after inactivity", "quitAfterHidden": "Quit after being hidden",
            "cancel": "Cancel", "save": "Save", "chooseApp": "Choose an app", "chooseRunning": "Choose a running app", "browse": "Browse…",
            "application": "Application", "selectedApp": "Selected application", "changeApp": "Change app", "runningApps": "Running applications",
            "browseApplications": "Choose an app from disk", "noRunningApps": "No eligible running applications found",
            "configFile": "Configuration file", "configDescription": "Rules and preferences are stored in this local file. Updating or replacing OctoQuit.app will not affect it.",
            "revealInFinder": "Show in Finder", "configSaveError": "Couldn’t save the configuration file: %@",
            "importQuitter": "Import Quitter Configuration", "importQuitterDescription": "Import rules directly from Quitter’s local preferences file; matching app identifiers already in your rules are skipped.",
            "importQuitterSuccess": "Imported %d rules and skipped %d duplicate or invalid rules.", "importQuitterEmpty": "No new rules were found to import.",
            "importQuitterError": "Couldn’t import the configuration file: %@", "importQuitterInvalid": "This is not a supported Quitter preferences file.",
            "importQuitterNotFound": "Quitter configuration file not found: %@",
            "minute": "minute", "minutes": "minutes", "language": "Language", "languageDescription": "Choose OctoQuit’s display language. Changes apply immediately.",
            "systemLanguage": "System Language", "english": "English", "simplifiedChinese": "Simplified Chinese", "checkNow": "Check now",
            "startAtLogin": "Start at Login", "showApp": "Show OctoQuit", "quitApp": "Quit OctoQuit", "enabledStatus": "OctoQuit: Enabled",
            "disabledStatus": "OctoQuit: Disabled", "disableApp": "Disable OctoQuit", "enableApp": "Enable OctoQuit",
            "loginError": "Couldn’t update the login item: %@", "aboutAutomation": "AUTOMATION", "manageRules": "Manage app rules and interface preferences.",
            "quitsIn": "Quits in %d min"
        ][key] ?? key
    }
}

@MainActor
final class QuitterModel: ObservableObject {
    private struct StoredConfiguration: Codable {
        var version: Int = 1
        var rules: [QuitRule]
        var isEnforcing: Bool
        var language: AppLanguage
    }

    @Published private(set) var rules: [QuitRule] = []
    @Published var isEnforcing = true { didSet { saveIfReady() } }
    @Published private(set) var lastChecked = Date()
    @Published var alertMessage: String?
    @Published private(set) var launchesAtLogin = false
    @Published var language: AppLanguage = .system { didSet { saveIfReady() } }
    private var timer: Timer?
    private var isLoading = false
    private let configurationURL: URL
    private let rulesKey = "OctoQuit.rules.v2"
    private let enforcementKey = "OctoQuit.enforcing"
    private let languageKey = "OctoQuit.language"

    init() {
        configurationURL = Self.defaultConfigurationURL()
        isLoading = true
        load()
        isLoading = false
        save()
        refreshLoginItemState()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluateRules() }
        }
        evaluateRules()
    }

    var enabledCount: Int { rules.filter(\.isEnabled).count }
    var configurationFilePath: String { configurationURL.path }

    func remainingQuitMinutes(for rule: QuitRule) -> Int? {
        guard isEnforcing, rule.isEnabled,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == rule.bundleIdentifier }),
              !app.isActive else { return nil }

        let now = Date()
        var deadlines: [Date] = []
        if let minutes = rule.inactiveQuitMinutes, let lastActiveAt = rule.lastActiveAt {
            deadlines.append(lastActiveAt.addingTimeInterval(Double(minutes * 60)))
        }
        if app.isHidden, let minutes = rule.hiddenQuitMinutes, let hiddenAt = rule.hiddenAt {
            deadlines.append(hiddenAt.addingTimeInterval(Double(minutes * 60)))
        }
        guard let deadline = deadlines.min() else { return nil }
        return max(0, Int(ceil(deadline.timeIntervalSince(now) / 60)))
    }

    @discardableResult
    func addRule(_ rule: QuitRule) -> Bool {
        guard !rules.contains(where: { $0.bundleIdentifier == rule.bundleIdentifier }) else {
            alertMessage = t("duplicateRule", rule.appName)
            return false
        }
        rules.append(rule)
        save()
        return true
    }

    func updateRule(_ rule: QuitRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        save()
    }

    func remove(_ rule: QuitRule) {
        rules.removeAll { $0.id == rule.id }
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
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginItemState()
        } catch {
            alertMessage = t("loginError", error.localizedDescription)
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

    func importQuitterConfiguration(from url: URL) {
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
                alertMessage = t("importQuitterEmpty")
                return
            }
            rules.append(contentsOf: imported)
            if let active = root["active"] as? NSNumber {
                isLoading = true
                isEnforcing = active.boolValue
                isLoading = false
            }
            save()
            alertMessage = t("importQuitterSuccess", imported.count, skipped)
        } catch ImportError.invalidFormat {
            alertMessage = t("importQuitterInvalid")
        } catch {
            alertMessage = t("importQuitterError", error.localizedDescription)
        }
    }

    func importQuitterConfigurationFromDefaultLocation() {
        let url = Self.defaultQuitterConfigurationURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            alertMessage = t("importQuitterNotFound", url.path)
            return
        }
        importQuitterConfiguration(from: url)
    }

    func evaluateRules() {
        guard isEnforcing else { return }
        let now = Date()
        let running = NSWorkspace.shared.runningApplications
        var changed = false

        for index in rules.indices where rules[index].isEnabled {
            guard let app = running.first(where: { $0.bundleIdentifier == rules[index].bundleIdentifier }) else {
                if rules[index].lastActiveAt != nil || rules[index].hiddenAt != nil {
                    rules[index].lastActiveAt = nil
                    rules[index].hiddenAt = nil
                    rules[index].didHideSinceActive = false
                    changed = true
                }
                continue
            }

            if app.isActive {
                if rules[index].lastActiveAt != now || rules[index].hiddenAt != nil || rules[index].didHideSinceActive {
                    rules[index].lastActiveAt = now
                    rules[index].hiddenAt = nil
                    rules[index].didHideSinceActive = false
                    changed = true
                }
                continue
            }

            if rules[index].lastActiveAt == nil {
                rules[index].lastActiveAt = now
                changed = true
            }

            if app.isHidden {
                if rules[index].hiddenAt == nil {
                    rules[index].hiddenAt = now
                    changed = true
                }
                if let interval = rules[index].hiddenQuitMinutes,
                   now.timeIntervalSince(rules[index].hiddenAt ?? now) >= Double(interval * 60) {
                    app.terminate()
                    rules[index].hiddenAt = now
                    changed = true
                }
                if let interval = rules[index].inactiveQuitMinutes,
                   now.timeIntervalSince(rules[index].lastActiveAt ?? now) >= Double(interval * 60) {
                    app.terminate()
                    rules[index].lastActiveAt = now
                    changed = true
                }
                continue
            }

            let inactiveSeconds = now.timeIntervalSince(rules[index].lastActiveAt ?? now)
            if let interval = rules[index].inactiveHideMinutes,
               !rules[index].didHideSinceActive,
               inactiveSeconds >= Double(interval * 60) {
                app.hide()
                rules[index].didHideSinceActive = true
                rules[index].hiddenAt = now
                changed = true
            }
            if let interval = rules[index].inactiveQuitMinutes,
               inactiveSeconds >= Double(interval * 60) {
                app.terminate()
                rules[index].lastActiveAt = now
                changed = true
            }
        }
        lastChecked = now
        if changed { save() }
    }

    private func load() {
        if let data = try? Data(contentsOf: configurationURL),
           let configuration = try? JSONDecoder().decode(StoredConfiguration.self, from: data) {
            apply(configuration)
            return
        }

        // One-time migration from versions that used UserDefaults.
        let defaults = UserDefaults.standard
        isEnforcing = defaults.object(forKey: enforcementKey) as? Bool ?? true
        language = AppLanguage(rawValue: defaults.string(forKey: languageKey) ?? "") ?? .system
        guard let data = defaults.data(forKey: rulesKey),
              let saved = try? JSONDecoder().decode([QuitRule].self, from: data) else { return }
        rules = resetRuntimeState(saved)
    }

    private func apply(_ configuration: StoredConfiguration) {
        isEnforcing = configuration.isEnforcing
        language = configuration.language
        rules = resetRuntimeState(configuration.rules)
    }

    private func resetRuntimeState(_ saved: [QuitRule]) -> [QuitRule] {
        saved.map { rule in
            var reset = rule
            reset.lastActiveAt = nil
            reset.hiddenAt = nil
            reset.didHideSinceActive = false
            return reset
        }
    }

    private func save() {
        let configuration = StoredConfiguration(rules: rules, isEnforcing: isEnforcing, language: language)
        do {
            let directory = configurationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: configurationURL, options: .atomic)
        } catch {
            alertMessage = t("configSaveError", error.localizedDescription)
        }
    }

    private func saveIfReady() {
        guard !isLoading else { return }
        save()
    }

    private static func defaultConfigurationURL() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent("OctoQuit", isDirectory: true).appendingPathComponent("config.json")
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

enum MainSection { case rules, settings }

struct ContentView: View {
    @EnvironmentObject private var model: QuitterModel
    @State private var showingAdd = false
    @State private var editingRule: QuitRule?
    @State private var isDropTarget = false
    @State private var section: MainSection = .rules

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: $section)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if section == .rules {
                    header
                    if model.rules.isEmpty { EmptyRulesView(addRule: { showingAdd = true }) }
                    else { rulesList }
                } else {
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(isPresented: $showingAdd) { RuleEditor(rule: nil).environmentObject(model) }
        .sheet(item: $editingRule) { rule in RuleEditor(rule: rule).environmentObject(model) }
        .alert("OctoQuit", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
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
                    RuleRow(rule: rule, edit: { editingRule = rule }, toggle: { model.toggleRule(rule) })
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
            model.alertMessage = model.t("invalidDrop")
            return
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        model.addRule(QuitRule(appName: name, bundleIdentifier: identifier, bundlePath: url.path, inactiveQuitMinutes: 10))
    }
}

struct Sidebar: View {
    @EnvironmentObject private var model: QuitterModel
    @Binding var section: MainSection
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "timer").font(.title2.bold()).foregroundStyle(.blue)
                Text("OctoQuit").font(.headline)
            }
            .padding(.horizontal, 22).padding(.top, 30).padding(.bottom, 34)
            Button { section = .rules } label: {
                Label(model.t("rules"), systemImage: "list.bullet.rectangle")
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .background(section == .rules ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            Button { section = .settings } label: {
                Label(model.t("settings"), systemImage: "gearshape")
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
    @EnvironmentObject private var model: QuitterModel
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
    @EnvironmentObject private var model: QuitterModel
    let rule: QuitRule
    let edit: () -> Void
    let toggle: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            AppIcon(path: rule.bundlePath)
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.appName).font(.body.weight(.semibold))
                Text(ruleSummary(rule)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let remaining = model.remainingQuitMinutes(for: rule) {
                Text(model.t("quitsIn", remaining))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.orange.opacity(0.12), in: Capsule())
            }
            Button(model.t("edit"), action: edit).buttonStyle(.borderless)
            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { _ in toggle() })).labelsHidden()
        }
        .padding(.vertical, 5)
    }

    private func ruleSummary(_ rule: QuitRule) -> String {
        var items: [String] = []
        if let m = rule.inactiveHideMinutes { items.append(model.t("hideAfter", m)) }
        if let m = rule.inactiveQuitMinutes { items.append(model.t("quitAfter", m)) }
        if let m = rule.hiddenQuitMinutes { items.append(model.t("quitHidden", m)) }
        return items.joined(separator: " • ")
    }
}

struct AppIcon: View {
    var path: String?
    var body: some View {
        Group {
            if let path, let image = NSWorkspace.shared.icon(forFile: path) as NSImage? {
                Image(nsImage: image).resizable().interpolation(.high)
            } else { Image(systemName: "app.fill").resizable().scaledToFit().padding(9).foregroundStyle(.blue) }
        }
        .frame(width: 40, height: 40).background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
    }
}

struct RuleEditor: View {
    @EnvironmentObject private var model: QuitterModel
    @Environment(\.dismiss) private var dismiss
    private let original: QuitRule?
    @State private var appName = ""
    @State private var bundleIdentifier = ""
    @State private var bundlePath: String?
    @State private var hideEnabled = false
    @State private var hideMinutes = 10
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
            ActionSetting(title: model.t("quitInactive"), enabled: $inactiveQuitEnabled, minutes: $inactiveQuitMinutes)
            ActionSetting(title: model.t("quitAfterHidden"), enabled: $hiddenQuitEnabled, minutes: $hiddenQuitMinutes)
            Spacer()
            HStack { Spacer(); Button(model.t("cancel")) { dismiss() }; Button(original == nil ? model.t("addApp") : model.t("save")) { save() }.buttonStyle(.borderedProminent).disabled(bundleIdentifier.isEmpty || !(hideEnabled || inactiveQuitEnabled || hiddenQuitEnabled)) }
        }
        .padding(28).frame(width: 520, height: 535)
        .onAppear { runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") } }
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
            inactiveQuitMinutes: inactiveQuitEnabled ? inactiveQuitMinutes : nil,
            hiddenQuitMinutes: hiddenQuitEnabled ? hiddenQuitMinutes : nil,
            isEnabled: original?.isEnabled ?? true,
            lastActiveAt: original?.lastActiveAt,
            hiddenAt: original?.hiddenAt,
            didHideSinceActive: original?.didHideSinceActive ?? false
        )
        if original == nil {
            if model.addRule(rule) { dismiss() }
        } else {
            model.updateRule(rule)
            dismiss()
        }
    }
}

struct ActionSetting: View {
    @EnvironmentObject private var model: QuitterModel
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
    @EnvironmentObject private var model: QuitterModel
    var body: some View {
        Text(model.isEnforcing ? model.t("enabledStatus") : model.t("disabledStatus"))
        Divider()
        Button(model.isEnforcing ? model.t("disableApp") : model.t("enableApp")) { model.isEnforcing.toggle() }
        Button(model.t("checkNow")) { model.evaluateRules() }
        Divider()
        Toggle(model.t("startAtLogin"), isOn: Binding(get: { model.launchesAtLogin }, set: { model.setLaunchAtLogin($0) }))
        Button(model.t("showApp")) { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first?.makeKeyAndOrderFront(nil) }
        Divider()
        Button(model.t("quitApp")) { NSApp.terminate(nil) }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: QuitterModel
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
                Button(model.t("importQuitter")) { model.importQuitterConfigurationFromDefaultLocation() }
            }
            Spacer()
        }
        .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 30)
    }

}
