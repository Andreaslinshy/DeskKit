import SwiftUI
import AppKit

struct ManagerView: View {
    @ObservedObject var model: AppModel
    @State private var deletionCandidate: PluginRecord?
    @State private var showingGuide = false
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(nsImage: DeskKitBrand.icon).resizable().scaledToFit()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DeskKit").font(.title2.weight(.semibold))
                        Text("把重要的事放在眼前").font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 24)
                List(selection: Binding(get: { model.selectedID }, set: { _ = model.selectPlugin($0) })) {
                    Section("我的组件") {
                        ForEach(model.records) { record in
                            HStack(spacing: 10) {
                                Image(systemName: record.manifest.symbol).font(.system(size: 16)).foregroundStyle(.teal).frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.manifest.name).font(.system(size: 13, weight: .medium))
                                    Text(model.preference(for: record).enabled ? surfaces(record) : "已停用").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.snapshots[record.id]?.error != nil { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.caption) }
                            }.padding(.vertical, 5).tag(record.id)
                                .contextMenu {
                                    Button(role: .destructive) { deletionCandidate = record } label: {
                                        Label("删除组件…", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }.listStyle(.sidebar)
                if !model.invalidPlugins.isEmpty {
                    Button { model.notice = model.invalidPlugins.joined(separator: "\n\n") } label: {
                        Label("\(model.invalidPlugins.count) 个组件需要修正", systemImage: "exclamationmark.triangle")
                    }.buttonStyle(.plain).font(.caption).foregroundStyle(.orange).padding(.horizontal, 16).padding(.bottom, 10)
                }
                Divider().padding(.horizontal, 16)
                Toggle("开机自启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                    .help("登录 Mac 时自动启动 DeskKit").padding(.horizontal, 16).padding(.top, 12)
                HStack {
                    Button { model.createPlugin() } label: { Label("新建", systemImage: "plus") }
                    Spacer()
                    Button { model.importPlugin() } label: { Image(systemName: "square.and.arrow.down") }.help("导入 .deskkit 组件包")
                    Button { NSWorkspace.shared.open(model.pluginDirectory) } label: { Image(systemName: "folder") }.help("打开组件文件夹")
                    Button { showingGuide = true } label: { Image(systemName: "questionmark.circle") }
                        .help("使用说明").accessibilityLabel("使用说明")
                }.buttonStyle(.borderless).padding(16)
            }.navigationSplitViewColumnWidth(min: 220, ideal: 235, max: 270)
        } detail: {
            if let record = model.selectedRecord { PluginDetailView(model: model, record: record, requestDeletion: { deletionCandidate = record }).id(record.id) }
            else { ContentUnavailableView("创建你的第一个组件", systemImage: "square.grid.2x2", description: Text("点击左下角的“新建”开始。")) }
        }
        .sheet(isPresented: $showingGuide) { UsageGuideView() }
        .confirmationDialog("删除“\(deletionCandidate?.manifest.name ?? "组件")”？",
                            isPresented: Binding(get: { deletionCandidate != nil }, set: { if !$0 { deletionCandidate = nil } }),
                            titleVisibility: .visible, presenting: deletionCandidate) { record in
            Button("移到废纸篓", role: .destructive) { model.deletePlugin(record) }
            Button("取消", role: .cancel) { }
        } message: { _ in
            Text("配置和脚本会移到废纸篓，可从中恢复。已放在桌面的卡片可以重新选择组件或手动移除。")
        }
        .alert("DeskKit", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("好") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
        .dialogIcon(Image(nsImage: DeskKitBrand.icon))
    }
    private func surfaces(_ record: PluginRecord) -> String {
        let value = model.preference(for: record)
        return [value.menuBar ? "菜单栏" : nil, value.widget ? "桌面组件" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

struct PluginDetailView: View {
    @ObservedObject var model: AppModel
    let record: PluginRecord
    let requestDeletion: () -> Void
    @State private var choosingSymbol = false
    @AppStorage("editorWrapsLines") private var wrapsLines = false
    private var tab: String { model.detailTab }
    private var preference: PluginPreferences { model.preference(for: record) }
    private var snapshot: ComponentSnapshot? { model.snapshots[record.id] }
    private var previewState: EditorPreviewState? { model.editorPreview?.componentID == record.id ? model.editorPreview : nil }
    private func toggle(_ key: WritableKeyPath<PluginPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { preference[keyPath: key] }, set: { value in model.updatePreference(record.id) { $0[keyPath: key] = value } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        title
                        Spacer(minLength: 12)
                        surfaceControls
                        Spacer(minLength: 12)
                        viewSelector
                        Spacer(minLength: 12)
                        samplingStatus
                    }.frame(height: EditorPreviewThumbnail.canvasHeight)
                    if let error = snapshot?.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption2).foregroundStyle(.orange).lineLimit(2).help(error)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                EditorPreviewThumbnail(state: previewState, preference: preference, manifest: record.manifest)
            }
            editor.layoutPriority(1)
        }.padding(24).background(Color(nsColor: .windowBackgroundColor))
            .onAppear { model.preparePreview(record) }
    }
    private var title: some View {
        HStack(spacing: 12) {
            Button { choosingSymbol = true } label: {
                Image(systemName: record.manifest.symbol).font(.system(size: 24, weight: .medium)).foregroundStyle(.teal)
                    .frame(width: 48, height: 48).background(.teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
            }.buttonStyle(.plain).help("更改组件图标")
                .popover(isPresented: $choosingSymbol, arrowEdge: .bottom) {
                    SymbolPicker(selected: record.manifest.symbol) { model.changeSymbol($0, record: record) }
                }
            VStack(alignment: .leading, spacing: 5) {
                Text(record.manifest.name).font(.system(size: 22, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                Text(record.manifest.description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var surfaceControls: some View {
        HStack(spacing: 12) {
            Toggle("菜单栏", isOn: toggle(\.menuBar)).fixedSize()
            Toggle("小组件", isOn: toggle(\.widget)).fixedSize()
            HStack(spacing: 4) {
                Button { model.refresh(record.id, force: true) } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                }.help(model.loading.contains(record.id) ? "更新中" : "刷新数据")
                    .accessibilityLabel("刷新数据").disabled(!preference.enabled || model.loading.contains(record.id))
                Button(role: .destructive, action: requestDeletion) {
                    Image(systemName: "trash").frame(width: 24, height: 24)
                }.help("删除组件…").accessibilityLabel("删除组件")
            }.buttonStyle(.borderless).font(.system(size: 14))
            Spacer(minLength: 0)
        }.toggleStyle(.checkbox).font(.system(size: 12))
    }
    private var viewSelector: some View {
        HStack(spacing: 10) {
            Text("视图").font(.system(size: 12)).fixedSize()
            Picker("视图", selection: Binding(get: { model.detailTab }, set: { model.selectDetailTab($0) })) {
                ForEach(["脚本", "配置"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 132)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var samplingStatus: some View {
        HStack(spacing: 5) {
            Circle().fill(snapshot?.isStale == false ? .green : .orange).frame(width: 5, height: 5)
            if let snapshot, snapshot.fetchedAt > Date(timeIntervalSince1970: 0) {
                Text(snapshot.isStale ? "缓存数据" : "最近更新")
                Text(snapshot.fetchedAt, style: .time)
            } else { Text("尚未取得数据") }
            Text("|").foregroundStyle(.tertiary).padding(.horizontal, 2)
            Text("采集间隔 \(Int(preference.refreshSeconds)) 秒")
        }.font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
    }
    private var editor: some View {
        let document = EditorDocument(rawValue: tab) ?? .script
        let editing = model.isEditing(record, document: document)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(document == .script ? "\(record.manifest.script) · JavaScript" : "widget.json · JSON")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                if editing { Text(model.editSession?.isModified == true ? "未保存" : "编辑中").font(.caption).foregroundStyle(.secondary).fixedSize() }
                Spacer(minLength: 4)
                Toggle("自动换行", isOn: $wrapsLines)
                    .toggleStyle(.button).tint(.teal).fixedSize()
                    .help(wrapsLines ? "关闭自动换行" : "按编辑器宽度自动换行")
                if editing { Button("取消编辑") { model.cancelEditing() }.fixedSize() }
                Button("预览") { model.previewEditor(record) }
                    .disabled(previewState?.isRendering == true).fixedSize()
                    .help("使用当前代码与已采集数据预览，不保存修改")
                Button(editing ? "保存" : "编辑") {
                    if editing { model.saveEdits() }
                    else { model.beginEditing(record, document: document) }
                }.buttonStyle(.borderedProminent).tint(.teal).fixedSize()
            }
            CodeEditor(text: Binding(get: { model.editorText(for: record, document: document) }, set: { model.updateEditorText($0) }),
                       documentID: record.id + "/" + document.rawValue, editable: editing, language: document == .script ? "JavaScript" : "JSON", wrapsLines: wrapsLines)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.08)))
                .frame(minHeight: 200, maxHeight: .infinity)
            if let error = model.editorError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }
}

private struct UsageGuideView: View {
    @Environment(\.dismiss) private var dismiss
    private let blocks = GuideBlock.load()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("使用说明").font(.headline)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(blocks.indices, id: \.self) { index in
                        content(blocks[index])
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
        }.frame(width: 680, height: 560)
            .background(Color(nsColor: .windowBackgroundColor))
    }
    private func inline(_ source: String) -> AttributedString {
        (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
    }
    @ViewBuilder private func content(_ block: GuideBlock) -> some View {
        switch block {
        case .heading(let text, let level):
            Text(inline(text)).font(.system(size: level == 1 ? 22 : 16, weight: .semibold))
                .padding(.top, level == 1 ? 0 : 10).textSelection(.enabled)
        case .paragraph(let text):
            Text(inline(text)).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
        case .bullet(let text):
            HStack(alignment: .top, spacing: 9) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(text)).lineSpacing(5).textSelection(.enabled)
            }.font(.system(size: 13))
        case .code(let text):
            ScrollView(.horizontal) {
                Text(verbatim: text).font(.system(size: 12, design: .monospaced)).lineSpacing(4)
                    .textSelection(.enabled).fixedSize().padding(14)
            }.frame(height: CGFloat(text.components(separatedBy: "\n").count) * 18 + 28)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private enum GuideBlock {
    case heading(String, Int), paragraph(String), bullet(String), code(String)

    static func load() -> [GuideBlock] {
        guard let url = Bundle.main.url(forResource: "PluginGuide", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [.paragraph("暂时无法读取使用说明，请重新打开应用后再试。")]
        }
        var blocks: [GuideBlock] = [], paragraph: [String] = [], code: [String] = []
        var inCode = false
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph.removeAll()
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode { blocks.append(.code(code.joined(separator: "\n"))); code.removeAll() }
                else { flushParagraph() }
                inCode.toggle()
            } else if inCode { code.append(line) }
            else if trimmed.isEmpty { flushParagraph() }
            else if trimmed.hasPrefix("# ") {
                flushParagraph(); blocks.append(.heading(String(trimmed.dropFirst(2)), 1))
            } else if trimmed.hasPrefix("## ") {
                flushParagraph(); blocks.append(.heading(String(trimmed.dropFirst(3)), 2))
            } else if trimmed.hasPrefix("- ") {
                flushParagraph(); blocks.append(.bullet(String(trimmed.dropFirst(2))))
            } else { paragraph.append(line) }
        }
        if inCode { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }
}
