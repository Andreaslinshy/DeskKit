import Foundation

enum DeskKitIdentity {
    static let widgetKind = "DeskKitComponent"
    static var appGroup: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "DeskKitAppGroup") as? String ?? ""
        // An unset build variable must never fall back to someone else's shared container.
        return value.isEmpty || value.hasPrefix(".") || value.contains("$(") ? "" : value
    }
}

struct DataSourceSpec: Codable {
    var kind: String
    var url: String?
    var executable: String?
    var interface: String?
    var arguments: [String]?
    var format: String?
    var value: [String: JSONValue]?
}

enum JSONValue: Codable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var foundation: Any {
        switch self {
        case .string(let v): return v
        case .number(let v): return v
        case .bool(let v): return v
        case .object(let v): return v.mapValues(\.foundation)
        case .array(let v): return v.map(\.foundation)
        case .null: return NSNull()
        }
    }
}

struct PluginManifest: Codable, Identifiable {
    var id: String
    var name: String
    var description: String
    var symbol: String
    var version: Int
    var refreshSeconds: Double
    var source: DataSourceSpec
    var script: String
    var defaultEnabled: Bool
    var menuBar: Bool
    var widget: Bool

    func validate() throws {
        guard version == 1, !name.isEmpty, name.count <= 80,
              id.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._-]{0,100}$", options: .regularExpression) != nil,
              refreshSeconds.isFinite, refreshSeconds >= 1,
              ["system", "codex", "http", "command", "static"].contains(source.kind),
              !script.hasPrefix("/"), !script.split(separator: "/").contains("..") else {
            throw DeskKitError.message("组件配置无效：检查 id、version、刷新间隔和脚本路径。")
        }
        if source.kind == "http" {
            guard let text = source.url, let url = URL(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw DeskKitError.message("HTTP 数据源需要有效的 http/https URL。")
            }
        }
        if source.kind == "codex", let executable = source.executable, !executable.isEmpty, !executable.hasPrefix("/") {
            throw DeskKitError.message("Codex 数据源的 executable 需留空或填写绝对路径。")
        }
        if source.kind == "command", source.executable?.hasPrefix("/") != true {
            throw DeskKitError.message("命令数据源的 executable 必须是绝对路径。")
        }
    }
}

struct LayoutNode: Codable {
    var type: String
    var text: String?
    var value: Double?
    var max: Double?
    var label: String?
    var symbol: String?
    var color: String?
    var size: Double?
    var weight: String?
    var spacing: Double?
    var children: [LayoutNode]?
    var values: [Double]?
    var url: String?
    var alignment: String?

    static func message(_ text: String, size: Double = 13) -> LayoutNode {
        LayoutNode(type: "text", text: text, size: size)
    }
    func validate(depth: Int = 0, count: inout Int) throws {
        count += 1
        guard depth <= 12, count <= 256,
              ["column", "row", "text", "metric", "progress", "symbol", "divider", "spacer", "chart", "link"].contains(type),
              (text?.utf8.count ?? 0) <= 8000,
              (values?.count ?? 0) <= 120,
              [value, max, size, spacing].compactMap({ $0 }).allSatisfy(\.isFinite),
              values?.allSatisfy(\.isFinite) != false else {
            throw DeskKitError.message("布局超出限制或包含不支持的控件。")
        }
        for child in children ?? [] { try child.validate(depth: depth + 1, count: &count) }
    }
}

struct MenuBarRow: Codable {
    var left: String
    var right: String
}

struct PluginPresentation: Codable {
    var menuBar: String?
    var menuBarLines: [String]?
    var menuBarRows: [MenuBarRow]?
    var menuBarWidth: Double?
    var panel: LayoutNode?
    var widget: LayoutNode?
    var medium: LayoutNode?
    var large: LayoutNode?
    func validate() throws {
        guard (menuBar?.count ?? 0) <= 80, (menuBarLines?.count ?? 0) <= 2,
              menuBarLines?.allSatisfy({ $0.count <= 40 }) != false,
              (menuBarRows?.count ?? 0) <= 2,
              menuBarRows?.allSatisfy({ $0.left.count <= 40 && $0.right.count <= 20 }) != false,
              menuBarWidth.map({ $0.isFinite && (48...180).contains($0) }) != false else {
            throw DeskKitError.message("菜单栏文字过长。")
        }
        var count = 0
        for node in [panel, widget, medium, large].compactMap({ $0 }) { try node.validate(count: &count) }
    }
}

struct ComponentSnapshot: Codable, Identifiable {
    var id: String
    var name: String
    var symbol: String
    var fetchedAt: Date
    var attemptedAt: Date
    var staleAfter: Double
    var error: String?
    var presentation: PluginPresentation
    var isStale: Bool { error != nil || Date().timeIntervalSince(fetchedAt) > staleAfter }
}

struct ComponentCatalogItem: Codable, Identifiable {
    var id: String
    var name: String
    var symbol: String
}

struct PluginPreferences: Codable {
    var enabled: Bool
    var menuBar: Bool
    var widget: Bool
    var refreshSeconds: Double
}

enum DeskKitError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

final class SharedStore {
    let directory: URL
    init(directory: URL? = nil) throws {
        if let directory { self.directory = directory }
        else if !DeskKitIdentity.appGroup.isEmpty,
                let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DeskKitIdentity.appGroup) {
            self.directory = url.appendingPathComponent("DeskKit", isDirectory: true)
        } else { throw DeskKitError.message("无法访问小组件共享容器，请检查 App Group 和签名。") }
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }
    func save(_ snapshot: ComponentSnapshot) throws { try write(snapshot, to: "snapshot-\(snapshot.id).json") }
    func read(_ id: String) -> ComponentSnapshot? {
        guard safeID(id) else { return nil }
        return read(ComponentSnapshot.self, from: "snapshot-\(id).json")
    }
    func removeSnapshot(_ id: String) throws {
        guard safeID(id) else { throw DeskKitError.message("无效的组件 id。") }
        let url = directory.appendingPathComponent("snapshot-\(id).json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    func saveCatalog(_ items: [ComponentCatalogItem]) throws { try write(items, to: "catalog.json") }
    func catalog() -> [ComponentCatalogItem] { (try? catalogForSelection()) ?? [] }
    func catalogForSelection() throws -> [ComponentCatalogItem] {
        // Configuration queries must surface read/decode failures instead of silently offering no choices.
        let data = try Data(contentsOf: directory.appendingPathComponent("catalog.json"))
        return try JSONDecoder().decode([ComponentCatalogItem].self, from: data)
    }
    private func safeID(_ id: String) -> Bool { id.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._-]{0,100}$", options: .regularExpression) != nil }
    private func write<T: Encodable>(_ object: T, to name: String) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(object).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    private func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
