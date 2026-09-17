import WidgetKit
import SwiftUI
import AppIntents
import OSLog

struct ComponentEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "组件")
    static var defaultQuery = ComponentQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
struct ComponentQuery: EntityStringQuery {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DeskKit.widgets", category: "ComponentSelection")
    func entities(for identifiers: [String]) async throws -> [ComponentEntity] {
        let available = try items()
        return identifiers.compactMap { id in available.first { $0.id == id } }
    }
    func suggestedEntities() async throws -> [ComponentEntity] { try items() }
    func entities(matching string: String) async throws -> [ComponentEntity] {
        let available = try items()
        let search = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? available : available.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search)
        }
    }
    func defaultResult() async -> ComponentEntity? {
        let available = (try? items()) ?? []
        return available.first(where: { $0.id == "codex-quota" }) ?? available.first
    }
    private func items() throws -> [ComponentEntity] {
        do {
            let items = try SharedStore().catalogForSelection().map { ComponentEntity(id: $0.id, name: $0.name) }
            Self.logger.info("Loaded \(items.count, privacy: .public) widget choices")
            return items
        } catch {
            Self.logger.error("Unable to load widget choices: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }
}
struct ComponentOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [ComponentEntity] { try await ComponentQuery().suggestedEntities() }
    func defaultResult() async -> ComponentEntity? { await ComponentQuery().defaultResult() }
}
struct ComponentConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "选择组件"
    static var description = IntentDescription("选择在 DeskKit 中启用的桌面组件。")
    @Parameter(title: "组件", optionsProvider: ComponentOptionsProvider()) var component: ComponentEntity?
    static var parameterSummary: some ParameterSummary { Summary { \.$component } }
}
struct ComponentEntry: TimelineEntry {
    var date: Date
    var snapshot: ComponentSnapshot?
    var componentID: String?
    var preview = false
    var unavailable = false
}
struct ComponentProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ComponentEntry { ComponentEntry(date: Date(), snapshot: nil, componentID: nil, preview: true) }
    func snapshot(for configuration: ComponentConfiguration, in context: Context) async -> ComponentEntry { entry(configuration, preview: context.isPreview) }
    func timeline(for configuration: ComponentConfiguration, in context: Context) async -> Timeline<ComponentEntry> {
        Timeline(entries: [entry(configuration, preview: false)], policy: .after(Date().addingTimeInterval(15 * 60)))
    }
    private func entry(_ configuration: ComponentConfiguration, preview: Bool) -> ComponentEntry {
        let store = try? SharedStore()
        let catalog = store?.catalog() ?? []
        let id = configuration.component?.id ?? catalog.first(where: { $0.id == "codex-quota" })?.id ?? catalog.first?.id
        let active = catalog.contains { $0.id == id }
        return ComponentEntry(date: Date(), snapshot: active ? id.flatMap { store?.read($0) } : nil, componentID: id, preview: preview, unavailable: id != nil && !active)
    }
}
struct DeskKitWidgetView: View {
    let entry: ComponentEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let snapshot = entry.snapshot {
                if let node = node(snapshot) { ComponentView(node: node, nativeWidget: true).frame(maxHeight: .infinity, alignment: .topLeading) }
                HStack(spacing: 3) {
                    if snapshot.isStale { Image(systemName: "exclamationmark.circle"); Text("缓存") }
                    else { Text("更新") }
                    if snapshot.fetchedAt > Date(timeIntervalSince1970: 0) { Text(snapshot.fetchedAt, style: .time) }
                    Spacer(minLength: 0)
                }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Image(systemName: "square.grid.2x2.fill").font(.title2).foregroundStyle(.teal).widgetAccentable()
                Spacer()
                Text(entry.unavailable ? "组件不可用" : "DeskKit").font(.title3.weight(.semibold))
                Text(entry.preview ? "把重要的事\n放在眼前" : entry.unavailable ? "请重新选择组件\n或移除此卡片" : "打开 DeskKit\n启用一个桌面组件").font(.caption).foregroundStyle(.secondary)
            }
        }
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        .widgetURL(URL(string: "deskkit://open?component=\(entry.componentID ?? "codex-quota")"))
    }
    private func node(_ snapshot: ComponentSnapshot) -> LayoutNode? {
        switch family {
        case .systemLarge: return snapshot.presentation.large ?? snapshot.presentation.medium ?? snapshot.presentation.widget
        case .systemMedium: return snapshot.presentation.medium ?? snapshot.presentation.widget
        default: return snapshot.presentation.widget
        }
    }
}
@main struct DeskKitWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: DeskKitIdentity.widgetKind, intent: ComponentConfiguration.self, provider: ComponentProvider()) { DeskKitWidgetView(entry: $0) }
            .configurationDisplayName("自定义组件")
            .description("选择你在 DeskKit 中创建的额度、行情或其他自定义卡片。")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
