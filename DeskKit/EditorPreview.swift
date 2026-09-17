import AppKit
import SwiftUI

struct PreviewInput {
    let sourceKey: Data
    let values: [String: Any]
    let fetchedAt: Date
}

struct EditorPreviewFrame {
    let presentation: PluginPresentation
    let name: String
    let symbol: String
    let fetchedAt: Date
    var document: EditorDocument?
    var draftText: String?
}

struct EditorPreviewState {
    let componentID: String
    var saved: EditorPreviewFrame?
    var draft: EditorPreviewFrame?
    var isRendering = false
    var error: String?
    var frame: EditorPreviewFrame? { draft ?? saved }
}

@MainActor extension AppModel {
    private func sourceKey(_ source: DataSourceSpec) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(source)
    }
    func rememberPreviewInput(_ values: [String: Any], record: PluginRecord, fetchedAt: Date) {
        guard let key = try? sourceKey(record.manifest.source) else { return }
        previewInputs[record.id] = PreviewInput(sourceKey: key, values: values, fetchedAt: fetchedAt)
    }
    func preparePreview(_ record: PluginRecord) {
        guard editorPreview?.componentID != record.id else { return }
        resetDraftPreview()
        previewAwaitingRevision = nil
        editorPreview = EditorPreviewState(componentID: record.id)
        if let snapshot = snapshots[record.id] { captureLivePreview(snapshot, record: record) }
    }
    func captureLivePreview(_ snapshot: ComponentSnapshot, record: PluginRecord) {
        guard var state = editorPreview, state.componentID == record.id,
              snapshot.fetchedAt > Date(timeIntervalSince1970: 0),
              state.saved == nil || previewAwaitingRevision == record.revision else { return }
        // Capture once on opening, or once after saving. Normal sampling never animates this preview.
        state.saved = EditorPreviewFrame(presentation: snapshot.presentation, name: snapshot.name,
                                         symbol: snapshot.symbol, fetchedAt: snapshot.fetchedAt)
        editorPreview = state; previewAwaitingRevision = nil
    }
    func resetDraftPreview() {
        if previewToken != nil { previewEngine.shutdown() }
        previewToken = nil
        guard var state = editorPreview else { return }
        state.draft = nil; state.error = nil; state.isRendering = false
        editorPreview = state
    }
    func finishSavedPreview(_ session: ComponentEditSession) {
        let draft = editorPreview?.componentID == session.record.id ? editorPreview?.draft : nil
        resetDraftPreview()
        guard editorPreview?.componentID == session.record.id else { return }
        if var draft, draft.document == session.document, draft.draftText == session.text {
            draft.document = nil; draft.draftText = nil
            editorPreview?.saved = draft
        }
        if session.isModified {
            previewAwaitingRevision = records.first(where: { $0.id == session.record.id })?.revision
        }
    }
    func previewEditor(_ record: PluginRecord) {
        preparePreview(record)
        guard editorPreview?.isRendering != true else { return }
        let session = editSession?.record.id == record.id ? editSession : nil
        do {
            var manifest = record.manifest
            if session?.document == .configuration, let text = session?.text {
                let bytes = Data(text.utf8)
                guard bytes.count <= 65_536 else { throw DeskKitError.message("配置文件超过 64 KB。") }
                manifest = try JSONDecoder().decode(PluginManifest.self, from: bytes)
                try manifest.validate()
                guard manifest.id == record.id else { throw DeskKitError.message("已安装组件的 id 不能修改。") }
            }
            let script: String
            if session?.document == .script, let text = session?.text { script = text }
            else {
                let url = record.directory.appendingPathComponent(manifest.script).resolvingSymlinksInPath()
                guard url.path.hasPrefix(record.directory.resolvingSymlinksInPath().path + "/") else {
                    throw DeskKitError.message("布局脚本必须位于组件包内。")
                }
                let bytes = try Data(contentsOf: url)
                guard bytes.count <= 262_144, let text = String(data: bytes, encoding: .utf8) else {
                    throw DeskKitError.message("脚本必须为 UTF-8，且小于 256 KB。")
                }
                script = text
            }
            guard script.utf8.count <= 262_144 else { throw DeskKitError.message("脚本超过 256 KB。") }
            let input: PreviewInput
            let key = try sourceKey(manifest.source)
            if manifest.source.kind == "static" {
                input = PreviewInput(sourceKey: key, values: manifest.source.value?.mapValues(\.foundation) ?? [:], fetchedAt: Date())
            } else if let cached = previewInputs[record.id], cached.sourceKey == key { input = cached }
            else {
                throw DeskKitError.message("该数据源还没有采集数据。请先保存数据源配置，并启用组件或刷新数据后再预览。")
            }
            let token = UUID(); previewToken = token
            editorPreview?.isRendering = true; editorPreview?.error = nil
            Task { [weak self] in
                guard let self else { return }
                defer {
                    if previewToken == token { previewToken = nil; editorPreview?.isRendering = false }
                }
                do {
                    // A separate worker keeps draft failures and timeouts away from the live engine.
                    let presentation = try await previewEngine.render(script: script, data: input.values)
                    guard previewToken == token, selectedID == record.id,
                          editorPreview?.componentID == record.id, editSession?.id == session?.id else { return }
                    let frame = EditorPreviewFrame(presentation: presentation, name: manifest.name, symbol: manifest.symbol,
                                                   fetchedAt: input.fetchedAt, document: session?.document, draftText: session?.text)
                    if session != nil { editorPreview?.draft = frame }
                    else { editorPreview?.saved = frame }
                } catch {
                    guard previewToken == token, selectedID == record.id, editorPreview?.componentID == record.id else { return }
                    editorPreview?.error = error.localizedDescription
                }
            }
        } catch { editorPreview?.error = error.localizedDescription }
    }
}

private enum PreviewSurface: String, CaseIterable {
    case widget = "小组件", menuBar = "菜单栏"
}
private enum PreviewFamily: String, CaseIterable {
    case large = "大", medium = "中", small = "小"
    var size: CGSize {
        switch self {
        case .large: return CGSize(width: 360, height: 376)
        case .medium: return CGSize(width: 360, height: 170)
        case .small: return CGSize(width: 170, height: 170)
        }
    }
    func node(_ presentation: PluginPresentation) -> LayoutNode? {
        switch self {
        case .large: return presentation.large ?? presentation.medium ?? presentation.widget
        case .medium: return presentation.medium ?? presentation.widget
        case .small: return presentation.widget
        }
    }
}

struct EditorPreviewThumbnail: View {
    static let canvasHeight: CGFloat = 180
    static let regionWidth: CGFloat = 284
    let state: EditorPreviewState?
    let preference: PluginPreferences
    let manifest: PluginManifest
    @State private var selectedSurface: PreviewSurface = .widget
    @State private var family: PreviewFamily = .small
    private var hasBoth: Bool { preference.widget && preference.menuBar }
    private var surface: PreviewSurface {
        if hasBoth { return selectedSurface }
        if preference.menuBar { return .menuBar }
        if preference.widget { return .widget }
        return manifest.widget ? .widget : .menuBar
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 8) {
                Text("预览").font(.caption).foregroundStyle(.secondary).frame(height: 16)
                    .help(state?.draft != nil ? "当前显示未保存草稿的预览" : "当前显示保存版本的预览")
                previewControls
            }.frame(width: 28)
            VStack(spacing: 8) {
                ZStack {
                    if let frame = state?.frame {
                        GeometryReader { geometry in
                            let size = surface == .widget ? family.size : CGSize(width: 316, height: 400)
                            let scale = min(1, min(geometry.size.width / size.width, geometry.size.height / size.height))
                            artwork(frame)
                                .frame(width: size.width, height: size.height)
                                .scaleEffect(scale)
                                .frame(width: size.width * scale, height: size.height * scale)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }.allowsHitTesting(false).accessibilityLabel("\(surface.rawValue)效果预览")
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo").font(.title2)
                            Text("点击“预览”查看效果").font(.caption)
                        }.foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if state?.isRendering == true {
                        ProgressView().controlSize(.small).padding(10).background(.regularMaterial, in: Circle())
                    }
                }.frame(height: Self.canvasHeight)
                if let error = state?.error {
                    Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading).help(error)
                }
            }.frame(maxWidth: .infinity)
        }.frame(width: Self.regionWidth)
    }
    private var previewControls: some View {
        VStack(spacing: 0) {
            Button { selectedSurface = surface == .widget ? .menuBar : .widget } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .medium)).frame(width: 28, height: 28)
                    .foregroundStyle(hasBoth ? Color.primary : Color.secondary.opacity(0.4))
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).disabled(!hasBoth)
                .help(hasBoth ? (surface == .widget ? "切换到菜单栏预览" : "切换到小组件预览") : "仅有\(surface.rawValue)预览模式")
                .accessibilityLabel("切换预览模式").accessibilityValue(surface.rawValue)
            if surface == .widget {
                ForEach(PreviewFamily.allCases, id: \.self) { option in
                    Spacer(minLength: 4)
                    Button { family = option } label: {
                        Text(option.rawValue).font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 28)
                            .foregroundStyle(family == option ? Color.teal : Color.secondary)
                            .background(family == option ? Color.teal.opacity(0.18) : Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).help("预览\(option.rawValue)号小组件")
                        .accessibilityLabel("\(option.rawValue)号小组件")
                        .accessibilityAddTraits(family == option ? .isSelected : [])
                }
            } else { Spacer(minLength: 0) }
        }.frame(width: 28, height: Self.canvasHeight - 24, alignment: .top)
    }
    @ViewBuilder private func artwork(_ frame: EditorPreviewFrame) -> some View {
        if surface == .widget {
            VStack(alignment: .leading, spacing: 7) {
                if let node = family.node(frame.presentation) {
                    ComponentView(node: node, nativeWidget: true).frame(maxHeight: .infinity, alignment: .topLeading)
                } else { Text("脚本未提供小组件布局").font(.caption).foregroundStyle(.secondary).frame(maxHeight: .infinity) }
                Text("更新 \(frame.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }.padding(16).frame(width: family.size.width, height: family.size.height, alignment: .topLeading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 23))
                .overlay(RoundedRectangle(cornerRadius: 23).stroke(.primary.opacity(0.09)))
                .clipShape(RoundedRectangle(cornerRadius: 23))
        } else {
            VStack(spacing: 8) {
                menuLabel(frame.presentation).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: frame.symbol).foregroundStyle(.teal)
                        Text(frame.name).font(.headline)
                        Spacer()
                        Image(systemName: "arrow.clockwise")
                    }
                    if let node = frame.presentation.panel ?? frame.presentation.widget { ComponentView(node: node) }
                    else { Text("脚本未提供菜单栏展开布局").font(.caption).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    Divider()
                    HStack { Text("组件管理…"); Spacer(); Text("退出") }.font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(.primary.opacity(0.09)))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
            }.frame(width: 316, height: 400)
        }
    }
    @ViewBuilder private func menuLabel(_ presentation: PluginPresentation) -> some View {
        if let rows = presentation.menuBarRows, !rows.isEmpty {
            let width = CGFloat((presentation.menuBarWidth ?? 72) - 12)
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(spacing: 4) {
                        Text(rows[index].left).frame(maxWidth: .infinity, alignment: .leading)
                        Text(rows[index].right).frame(width: width * 0.38, alignment: .trailing)
                    }.frame(height: 11)
                }
            }.font(.system(size: 9, weight: .medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5).frame(width: width)
        } else if let lines = presentation.menuBarLines, !lines.isEmpty {
            Text(lines.joined(separator: "\n")).font(.system(size: 9, weight: .medium)).monospacedDigit()
        } else { Text(presentation.menuBar ?? "—").font(.system(size: 12, weight: .medium)).monospacedDigit() }
    }
}
