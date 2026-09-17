import AppKit
import SwiftUI
import WidgetKit
import ServiceManagement

struct PluginRecord: Identifiable {
    let manifest: PluginManifest
    let directory: URL
    let script: String
    let revision: Int
    var id: String { manifest.id }
}

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var records: [PluginRecord] = []
    @Published var snapshots: [String: ComponentSnapshot] = [:]
    @Published var preferences: [String: PluginPreferences] = [:]
    @Published var loading: Set<String> = []
    @Published var notice: String?
    @Published var invalidPlugins: [String] = []
    @Published var selectedID: String? = "codex-quota"
    @Published var detailTab = "脚本"
    @Published var editSession: ComponentEditSession?
    @Published var editorError: String?
    var resolvingEdits = false
    @Published var editorPreview: EditorPreviewState?
    let previewEngine = ScriptEngine()
    var previewInputs: [String: PreviewInput] = [:]
    var previewToken: UUID?
    var previewAwaitingRevision: Int?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    let pluginDirectory: URL
    let supportDirectory: URL
    private(set) var store: SharedStore?
    private let engine = ScriptEngine()
    private var systemSamplers: [String: SystemSampler] = [:]
    private var systemReadings: [String: SystemReading] = [:]
    private var timer: Timer?
    private var tickNumber = 0
    private var sleeping = false
    private var refreshTokens: [String: UUID] = [:]
    private var deletedPluginIDs = Set(UserDefaults.standard.stringArray(forKey: "deletedPluginIDs") ?? [])
    private var lastAttempt: [String: Date] = [:]
    private var lastWidgetReload: [String: Date] = [:]
    private var lastDiskWrite: [String: Date] = [:]
    private var latestSystem: SystemReading { systemReadings["system-monitor"] ?? systemReadings.values.first ?? SystemReading() }
    private var workspaceObservers: [NSObjectProtocol] = []

    private init() {
        supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DeskKit", isDirectory: true)
        pluginDirectory = supportDirectory.appendingPathComponent("Plugins", isDirectory: true)
        if let data = UserDefaults.standard.data(forKey: "pluginPreferences"), let value = try? JSONDecoder().decode([String: PluginPreferences].self, from: data) { preferences = value }
        do {
            try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
            try installBundledPlugins()
            try migrateSourceOptions()
        } catch { notice = error.localizedDescription }
        // Menu bar components and editing remain available if widget signing is not configured.
        do { store = try SharedStore() }
        catch { notice = "桌面小组件共享容器不可用，请检查本机构建的 App Group 和签名。菜单栏与编辑器仍可使用。" }
        for id in Array(preferences.keys) {
            guard var value = preferences[id] else { continue }
            if !value.enabled { value.menuBar = false; value.widget = false }
            value.enabled = value.menuBar || value.widget; preferences[id] = value
        }
        savePreferences()
        loadPlugins()
        for record in records { if let snapshot = store?.read(record.id) { snapshots[record.id] = snapshot } }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.sleeping = true } })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in
            self?.systemSamplers.values.forEach { $0.reset() }; self?.systemReadings.removeAll()
            self?.sleeping = false; self?.lastAttempt.removeAll(); self?.tick()
        } })
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        tick()
    }
    func preference(for record: PluginRecord) -> PluginPreferences {
        preferences[record.id] ?? PluginPreferences(enabled: false, menuBar: false, widget: false, refreshSeconds: record.manifest.refreshSeconds)
    }
    func updatePreference(_ id: String, change: (inout PluginPreferences) -> Void) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        var value = preference(for: record); change(&value)
        value.enabled = value.menuBar || value.widget
        value.refreshSeconds = max(record.manifest.source.kind == "codex" ? 30 : 1, value.refreshSeconds)
        preferences[id] = value; savePreferences(); publishCatalog()
        lastAttempt[id] = nil; refresh(id, force: true)
        WidgetCenter.shared.reloadTimelines(ofKind: DeskKitIdentity.widgetKind)
    }
    private func savePreferences() {
        if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: "pluginPreferences") }
    }
    private func installBundledPlugins() throws {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("Plugins"),
              let directories = try? FileManager.default.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil) else { return }
        for directory in directories where directory.pathExtension == "deskkit" {
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: directory.appendingPathComponent("widget.json")))
            guard !deletedPluginIDs.contains(manifest.id) else { continue }
            let destination = pluginDirectory.appendingPathComponent(directory.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: directory, to: destination)
                if preferences[manifest.id] == nil {
                    preferences[manifest.id] = PluginPreferences(enabled: manifest.defaultEnabled && (manifest.menuBar || manifest.widget), menuBar: manifest.defaultEnabled && manifest.menuBar, widget: manifest.defaultEnabled && manifest.widget, refreshSeconds: manifest.refreshSeconds)
                }
            }
        }
        savePreferences()
    }
    private func migrateSourceOptions() throws {
        let defaults = UserDefaults.standard
        let legacyCodexPath = defaults.string(forKey: "codexPath") ?? ""
        let legacyInterface = defaults.string(forKey: "interface") ?? ""
        let directories = try FileManager.default.contentsOfDirectory(at: pluginDirectory, includingPropertiesForKeys: nil)
        for directory in directories where directory.pathExtension == "deskkit" {
            let url = directory.appendingPathComponent("widget.json")
            guard let data = try? Data(contentsOf: url),
                  var manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  var source = manifest["source"] as? [String: Any] else { continue }
            let field: String, value: String
            switch source["kind"] as? String {
            case "codex": field = "executable"; value = legacyCodexPath
            case "system": field = "interface"; value = legacyInterface
            default: continue
            }
            guard source[field] == nil else { continue }
            source[field] = value; manifest["source"] = source
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        }
        defaults.removeObject(forKey: "codexPath")
        defaults.removeObject(forKey: "interface")
    }
    func loadPlugins() {
        guard let directories = try? FileManager.default.contentsOfDirectory(at: pluginDirectory, includingPropertiesForKeys: nil) else { return }
        var next: [PluginRecord] = [], failures: [String] = [], seen: Set<String> = []
        for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(100) where directory.pathExtension == "deskkit" {
            do {
                let manifestData = try Data(contentsOf: directory.appendingPathComponent("widget.json"))
                guard manifestData.count <= 65_536 else { throw DeskKitError.message("配置文件超过 64 KB。") }
                let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData); try manifest.validate()
                guard seen.insert(manifest.id).inserted else { throw DeskKitError.message("组件 id 重复。") }
                let scriptURL = directory.appendingPathComponent(manifest.script).resolvingSymlinksInPath()
                guard scriptURL.path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else { throw DeskKitError.message("布局脚本必须位于组件包内。") }
                let scriptData = try Data(contentsOf: scriptURL)
                guard scriptData.count <= 262_144, let script = String(data: scriptData, encoding: .utf8) else { throw DeskKitError.message("脚本必须为 UTF-8，且小于 256 KB。") }
                let revision = manifestData.hashValue ^ scriptData.hashValue
                next.append(PluginRecord(manifest: manifest, directory: directory, script: script, revision: revision))
                if let old = records.first(where: { $0.id == manifest.id }), old.revision != revision { lastAttempt[manifest.id] = nil }
            } catch { failures.append("\(directory.lastPathComponent)：\(error.localizedDescription)") }
        }
        next.sort { ($0.id == "system-monitor" ? "0" : $0.id) < ($1.id == "system-monitor" ? "0" : $1.id) }
        if next.map({ "\($0.id):\($0.revision)" }) != records.map({ "\($0.id):\($0.revision)" }) {
            records = next; publishCatalog()
            if !records.contains(where: { $0.id == selectedID }) && (editSession == nil || editSession?.record.id != selectedID) { selectedID = records.first?.id }
        }
        if failures != invalidPlugins { invalidPlugins = failures }
    }
    private func publishCatalog() {
        let items = records.filter { preference(for: $0).enabled && preference(for: $0).widget }
            .map { ComponentCatalogItem(id: $0.id, name: $0.manifest.name, symbol: $0.manifest.symbol) }
        do { try store?.saveCatalog(items) } catch { notice = "无法写入小组件目录：\(error.localizedDescription)" }
    }
    private func tick() {
        guard !sleeping else { return }; tickNumber += 1
        if tickNumber % 2 == 0 { loadPlugins() }
        let systemRecords = records.filter { $0.manifest.source.kind == "system" && preference(for: $0).enabled }
        let systemIDs = Set(systemRecords.map(\.id))
        systemSamplers = systemSamplers.filter { systemIDs.contains($0.key) }
        systemReadings = systemReadings.filter { systemIDs.contains($0.key) }
        for record in systemRecords {
            let sampler = systemSamplers[record.id] ?? SystemSampler()
            let interface = record.manifest.source.interface?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if sampler.preferredInterface != interface { sampler.preferredInterface = interface; sampler.reset() }
            systemSamplers[record.id] = sampler
            systemReadings[record.id] = sampler.sample()
        }
        for record in records {
            let preference = preference(for: record)
            if preference.enabled && Date().timeIntervalSince(lastAttempt[record.id] ?? .distantPast) >= preference.refreshSeconds { refresh(record.id) }
        }
        if tickNumber % 10 == 0 { writeDiagnostics() }
    }
    func refresh(_ id: String, force: Bool = false) {
        guard let record = records.first(where: { $0.id == id }), preference(for: record).enabled, !loading.contains(id) else { return }
        let token = UUID()
        refreshTokens[id] = token
        loading.insert(id); lastAttempt[id] = Date()
        let system = (systemReadings[id] ?? SystemReading()).json
        Task { [weak self] in
            guard let self else { return }
            defer {
                if refreshTokens[id] == token { refreshTokens[id] = nil; loading.remove(id) }
            }
            guard isCurrentRefresh(record, token: token) else { return }
            do {
                let data = record.manifest.source.kind == "system" ? system : try await DataProviders.fetch(record.manifest.source, package: record.directory)
                guard isCurrentRefresh(record, token: token) else { return }
                rememberPreviewInput(data, record: record, fetchedAt: Date())
                let presentation = try await engine.render(script: record.script, data: data)
                guard isCurrentRefresh(record, token: token) else { return }
                let now = Date()
                let snapshot = ComponentSnapshot(id: id, name: record.manifest.name, symbol: record.manifest.symbol,
                                                 fetchedAt: now, attemptedAt: now, staleAfter: max(180, preference(for: record).refreshSeconds * 3), error: nil, presentation: presentation)
                snapshots[id] = snapshot
                captureLivePreview(snapshot, record: record)
                persist(snapshot, record: record, force: force)
            } catch {
                guard isCurrentRefresh(record, token: token) else { return }
                var snapshot = snapshots[id] ?? ComponentSnapshot(id: id, name: record.manifest.name, symbol: record.manifest.symbol,
                    fetchedAt: .distantPast, attemptedAt: Date(), staleAfter: 180, error: nil,
                    presentation: PluginPresentation(menuBar: "—", panel: .message("暂时没有数据"), widget: .message("暂时没有数据")))
                snapshot.error = error.localizedDescription; snapshot.attemptedAt = Date(); snapshots[id] = snapshot
                persist(snapshot, record: record, force: force)
            }
        }
    }
    private func isCurrentRefresh(_ record: PluginRecord, token: UUID) -> Bool {
        refreshTokens[record.id] == token && preference(for: record).enabled && records.contains {
            $0.id == record.id && $0.revision == record.revision && $0.directory == record.directory
        }
    }
    private func persist(_ snapshot: ComponentSnapshot, record: PluginRecord, force: Bool) {
        guard preference(for: record).widget else { return }
        let now = Date()
        if force || now.timeIntervalSince(lastDiskWrite[record.id] ?? .distantPast) >= 30 {
            var cached = snapshot
            // Error details can contain paths, URLs, or command output. Keep them in the app's memory.
            if cached.error != nil { cached.error = "数据更新失败，请在 DeskKit 中查看详情。" }
            do { try store?.save(cached); lastDiskWrite[record.id] = now } catch { notice = error.localizedDescription }
        }
        if force || now.timeIntervalSince(lastWidgetReload[record.id] ?? .distantPast) >= 60 {
            WidgetCenter.shared.reloadTimelines(ofKind: DeskKitIdentity.widgetKind); lastWidgetReload[record.id] = now
        }
    }
    func refreshAll() { systemSamplers.values.forEach { $0.refreshDisk() }; for record in records { refresh(record.id, force: true) } }
    func setLaunchAtLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch { notice = "登录启动设置失败：\(error.localizedDescription)" }
    }
    func saveScript(_ text: String, record: PluginRecord) throws {
        guard text.utf8.count <= 262_144 else { throw DeskKitError.message("脚本超过 256 KB。") }
        try text.write(to: record.directory.appendingPathComponent(record.manifest.script), atomically: true, encoding: .utf8)
        loadPlugins(); refresh(record.id, force: true)
    }
    func saveManifest(_ text: String, record: PluginRecord) throws {
        let data = Data(text.utf8); let manifest = try JSONDecoder().decode(PluginManifest.self, from: data); try manifest.validate()
        guard manifest.id == record.id else { throw DeskKitError.message("已安装组件的 id 不能修改，请新建组件。") }
        try data.write(to: record.directory.appendingPathComponent("widget.json"), options: .atomic)
        if var p = preferences[record.id] { p.refreshSeconds = manifest.refreshSeconds; preferences[record.id] = p; savePreferences() }
        loadPlugins(); refresh(record.id, force: true)
    }
    func deletePlugin(_ record: PluginRecord) {
        if editSession?.record.id == record.id && !resolvePendingEdits("删除组件前") { return }
        guard let current = records.first(where: { $0.id == record.id && $0.directory == record.directory }) else { return }
        let directory = current.directory.standardizedFileURL
        guard directory.pathExtension == "deskkit",
              directory.deletingLastPathComponent().resolvingSymlinksInPath() == pluginDirectory.resolvingSymlinksInPath() else {
            notice = "只能删除组件文件夹中的组件。"; return
        }
        do {
            try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
        } catch {
            notice = "无法将组件移到废纸篓：\(error.localizedDescription)"; return
        }
        let id = current.id
        deletedPluginIDs.insert(id)
        UserDefaults.standard.set(deletedPluginIDs.sorted(), forKey: "deletedPluginIDs")
        // Invalidate pending success and error callbacks, including after a same-id reimport.
        refreshTokens[id] = nil; loading.remove(id)
        preferences[id] = nil; snapshots[id] = nil; previewInputs[id] = nil
        if editorPreview?.componentID == id { resetDraftPreview(); editorPreview = nil; previewAwaitingRevision = nil }
        systemSamplers[id] = nil; systemReadings[id] = nil
        lastAttempt[id] = nil; lastDiskWrite[id] = nil; lastWidgetReload[id] = nil
        savePreferences(); loadPlugins()
        do { try store?.removeSnapshot(id) }
        catch { notice = "组件已移到废纸篓，但缓存清理失败：\(error.localizedDescription)" }
        WidgetCenter.shared.reloadTimelines(ofKind: DeskKitIdentity.widgetKind)
    }
    func createPlugin() {
        guard resolvePendingEdits("创建组件前") else { return }
        detailTab = "脚本"
        do {
            let id = "custom-" + UUID().uuidString.prefix(8).lowercased()
            let directory = pluginDirectory.appendingPathComponent(id + ".deskkit", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let manifest = PluginManifest(id: id, name: "我的组件", description: "编辑脚本，创建自己的桌面卡片和菜单栏。", symbol: "sparkles", version: 1, refreshSeconds: 60,
                source: DataSourceSpec(kind: "static", value: ["title": .string("你好，DeskKit"), "message": .string("从这里开始创造。")]), script: "render.js", defaultEnabled: false, menuBar: false, widget: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: directory.appendingPathComponent("widget.json"))
            let script = """
            function render(data, context) {
              const card = { type: 'column', spacing: 10, children: [
                { type: 'symbol', symbol: 'sparkles', size: 24, color: 'accent' },
                { type: 'text', text: data.title, size: 21, weight: 'semibold' },
                { type: 'text', text: data.message, size: 12, color: 'secondary' }
              ] };
              return { menuBar: '✦', panel: card, widget: card };
            }
            """
            try script.write(to: directory.appendingPathComponent("render.js"), atomically: true, encoding: .utf8)
            preferences[id] = PluginPreferences(enabled: true, menuBar: false, widget: true, refreshSeconds: 60)
            savePreferences(); loadPlugins(); selectedID = id; refresh(id, force: true)
        } catch { notice = error.localizedDescription }
    }
    func importPlugin() {
        guard resolvePendingEdits("导入组件前") else { return }
        detailTab = "脚本"
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "导入组件"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: source.appendingPathComponent("widget.json"))); try manifest.validate()
            guard !records.contains(where: { $0.id == manifest.id }) else { throw DeskKitError.message("同名 id 的组件已经存在。") }
            let destination = pluginDirectory.appendingPathComponent(manifest.id + ".deskkit")
            try FileManager.default.copyItem(at: source, to: destination)
            deletedPluginIDs.remove(manifest.id)
            UserDefaults.standard.set(deletedPluginIDs.sorted(), forKey: "deletedPluginIDs")
            preferences[manifest.id] = PluginPreferences(enabled: false, menuBar: false, widget: false, refreshSeconds: manifest.refreshSeconds)
            savePreferences(); loadPlugins(); selectedID = manifest.id
        } catch { notice = error.localizedDescription }
    }
    func shutdown() { timer?.invalidate(); engine.shutdown(); previewEngine.shutdown() }
    private func writeDiagnostics() {
        // Counts only: no paths, component names/IDs, hardware readings, or raw errors.
        let summary: [String: Any] = ["version": 2, "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "componentCount": records.count,
            "enabledCount": records.filter { preference(for: $0).enabled }.count,
            "pendingCount": loading.count,
            "errorCount": snapshots.values.filter { $0.error != nil }.count,
            "invalidCount": invalidPlugins.count]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: supportDirectory.appendingPathComponent("diagnostics.json"), options: .atomic)
        }
    }
}
