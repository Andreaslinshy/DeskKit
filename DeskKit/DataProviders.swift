import Foundation

enum DataProviders {
    private static let httpSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    static func fetch(_ source: DataSourceSpec, package: URL) async throws -> [String: Any] {
        switch source.kind {
        case "static": return source.value?.mapValues(\.foundation) ?? [:]
        case "codex": return try await codex(path: source.executable ?? "")
        case "http":
            guard let string = source.url, let url = URL(string: string) else { throw DeskKitError.message("HTTP 地址无效。") }
            var request = URLRequest(url: url); request.timeoutInterval = 15; request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("DeskKit/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await httpSession.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw DeskKitError.message("数据源返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)。")
            }
            guard data.count <= 1_048_576 else { throw DeskKitError.message("数据源超过 1 MB。") }
            return try decode(data, format: source.format)
        case "command":
            guard let executable = source.executable else { throw DeskKitError.message("未设置命令路径。") }
            let result = try await CommandJob.run(executable: URL(fileURLWithPath: executable), arguments: source.arguments ?? [], directory: package)
            guard result.status == 0 else { throw DeskKitError.message("命令退出码 \(result.status)：\(result.errors.prefix(300))") }
            return try decode(result.data, format: source.format)
        default: throw DeskKitError.message("不支持的数据源：\(source.kind)")
        }
    }
    static func decode(_ data: Data, format: String?) throws -> [String: Any] {
        if format == "text" {
            let fallbackEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: fallbackEncoding)
            guard let text else { throw DeskKitError.message("无法解码数据源文字。") }
            return ["text": text]
        }
        let value = try JSONSerialization.jsonObject(with: data)
        if let object = value as? [String: Any] { return object }
        return ["value": value]
    }
    static func resolveCodex(_ override: String) -> String? {
        let candidates = [override, "/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func normalizeWindow(_ window: [String: Any]?) -> [String: Any]? {
        guard let window else { return nil }
        guard let used = window["usedPercent"] as? NSNumber, CFGetTypeID(used) != CFBooleanGetTypeID(), used.doubleValue.isFinite else {
            return ["remainingPercent": NSNull(), "usedPercent": NSNull(), "windowDurationMins": window["windowDurationMins"] ?? NSNull(), "resetsAt": window["resetsAt"] ?? NSNull()]
        }
        let bounded = min(100, max(0, used.doubleValue))
        return ["usedPercent": bounded, "remainingPercent": 100 - bounded,
                "windowDurationMins": window["windowDurationMins"] ?? NSNull(), "resetsAt": window["resetsAt"] ?? NSNull()]
    }
    private static func codex(path: String) async throws -> [String: Any] {
        guard let binary = resolveCodex(path) else { throw DeskKitError.message("未找到 Codex，请在该组件的配置中填写 source.executable。") }
        let messages: [[String: Any]] = [
            ["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "deskkit", "title": "DeskKit", "version": "1.0.0"]]],
            ["method": "initialized", "params": [:]],
            ["id": 2, "method": "account/rateLimits/read"]
        ]
        var input = Data()
        for message in messages { input.append(try JSONSerialization.data(withJSONObject: message)); input.append(10) }
        let output = try await CommandJob.run(executable: URL(fileURLWithPath: binary), arguments: ["app-server", "--listen", "stdio://"], input: input, timeout: 18, responseID: 2)
        guard let response = try JSONSerialization.jsonObject(with: output.data) as? [String: Any] else { throw DeskKitError.message("Codex 返回无效数据。") }
        if let error = response["error"] as? [String: Any] { throw DeskKitError.message(error["message"] as? String ?? "Codex 额度查询失败。") }
        let result = response["result"] as? [String: Any] ?? [:]
        let buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        guard let snapshot = buckets["codex"] ?? result["rateLimits"] as? [String: Any] ?? buckets.sorted(by: { $0.key < $1.key }).first?.value else {
            throw DeskKitError.message("没有可用额度，请先在 Codex 中登录 ChatGPT 账号。")
        }
        return ["primary": normalizeWindow(snapshot["primary"] as? [String: Any]) as Any? ?? NSNull(),
                "secondary": normalizeWindow(snapshot["secondary"] as? [String: Any]) as Any? ?? NSNull(),
                "planType": snapshot["planType"] ?? NSNull()]
    }
}
