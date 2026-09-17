import AppKit
import SwiftUI

enum EditorDocument: String {
    case script = "脚本", configuration = "配置"
    func url(for record: PluginRecord) -> URL {
        record.directory.appendingPathComponent(self == .script ? record.manifest.script : "widget.json")
    }
}

struct ComponentEditSession {
    let id = UUID()
    let record: PluginRecord
    let document: EditorDocument
    let url: URL
    let original: String
    var text: String
    var isModified: Bool { text != original }
}

@MainActor extension AppModel {
    var selectedRecord: PluginRecord? {
        records.first { $0.id == selectedID } ?? (editSession?.record.id == selectedID ? editSession?.record : nil)
    }
    func editorText(for record: PluginRecord, document: EditorDocument) -> String {
        if let session = editSession, session.record.id == record.id, session.document == document { return session.text }
        return document == .script ? record.script : (try? String(contentsOf: document.url(for: record), encoding: .utf8)) ?? ""
    }
    func isEditing(_ record: PluginRecord, document: EditorDocument) -> Bool {
        editSession?.record.id == record.id && editSession?.document == document
    }
    func beginEditing(_ record: PluginRecord, document: EditorDocument) {
        guard resolvePendingEdits("开始编辑其他文件前") else { return }
        resetDraftPreview()
        do {
            let url = document.url(for: record)
            let text = try String(contentsOf: url, encoding: .utf8)
            editSession = ComponentEditSession(record: record, document: document, url: url, original: text, text: text)
            editorError = nil
        } catch { editorError = error.localizedDescription }
    }
    func updateEditorText(_ text: String) {
        guard var session = editSession else { return }
        session.text = text; editSession = session; editorError = nil
    }
    func saveEditing() throws {
        guard let session = editSession else { return }
        guard let record = records.first(where: { $0.id == session.record.id && $0.directory == session.record.directory }),
              session.document.url(for: record) == session.url else {
            throw DeskKitError.message("组件或文件位置已改变。请先复制需要保留的内容，再重新打开组件。")
        }
        let current = try String(contentsOf: session.url, encoding: .utf8)
        guard current == session.original || current == session.text else {
            throw DeskKitError.message("文件已被外部修改，未覆盖外部内容。请复制当前修改，重新打开文件后合并。")
        }
        if session.isModified {
            if session.document == .script { try saveScript(session.text, record: record) }
            else { try saveManifest(session.text, record: record) }
        }
        finishSavedPreview(session)
        editSession = nil; editorError = nil
    }
    func saveEdits() {
        do { try saveEditing() } catch { editorError = error.localizedDescription }
    }
    func cancelEditing() {
        guard let session = editSession, !resolvingEdits else { return }
        resolvingEdits = true
        defer { resolvingEdits = false }
        let alert = DeskKitBrand.makeAlert()
        alert.messageText = "放弃本次修改？"
        alert.informativeText = "将退出对“\(session.record.manifest.name)”的\(session.document.rawValue)编辑，尚未保存的修改不会保留。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续编辑").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "放弃修改")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        resetDraftPreview()
        editSession = nil; editorError = nil
    }
    @discardableResult func resolvePendingEdits(_ reason: String) -> Bool {
        guard let session = editSession else { return true }
        guard session.isModified else { resetDraftPreview(); editSession = nil; editorError = nil; return true }
        guard !resolvingEdits else { return false }
        resolvingEdits = true
        defer { resolvingEdits = false }
        let alert = DeskKitBrand.makeAlert()
        alert.messageText = "保存对“\(session.record.manifest.name)”的修改？"
        alert.informativeText = "\(reason)，请选择是否保存尚未保存的\(session.document.rawValue)。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do { try saveEditing(); return true }
            catch {
                editorError = error.localizedDescription
                let failure = DeskKitBrand.makeAlert(); failure.messageText = "未能保存修改"
                failure.informativeText = error.localizedDescription; failure.runModal()
                return false
            }
        case .alertSecondButtonReturn:
            resetDraftPreview(); editSession = nil; editorError = nil; return true
        default: return false
        }
    }
    @discardableResult func selectPlugin(_ id: String?) -> Bool {
        guard id != selectedID else { return true }
        guard resolvePendingEdits("切换组件前") else { objectWillChange.send(); return false }
        resetDraftPreview(); editorPreview = nil; previewAwaitingRevision = nil
        selectedID = id; detailTab = "脚本"; editorError = nil; return true
    }
    func selectDetailTab(_ tab: String) {
        guard EditorDocument(rawValue: tab) != nil, tab != detailTab else { return }
        guard resolvePendingEdits("切换视图前") else { objectWillChange.send(); return }
        detailTab = tab; editorError = nil
    }
    func changeSymbol(_ symbol: String, record: PluginRecord) -> Bool {
        guard symbol != record.manifest.symbol else { return true }
        guard NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
              resolvePendingEdits("更改图标前") else { return false }
        do {
            let url = record.directory.appendingPathComponent("widget.json")
            let data = try Data(contentsOf: url)
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DeskKitError.message("组件配置格式无效。")
            }
            object["symbol"] = symbol
            let changed = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try saveManifest(String(decoding: changed, as: UTF8.self), record: record)
            return true
        } catch { notice = error.localizedDescription; return false }
    }
}
