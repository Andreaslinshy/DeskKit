import AppKit
import SwiftUI
import Combine

@MainActor final class StatusBarController: NSObject {
    private let model: AppModel
    private var items: [String: NSStatusItem] = [:]
    private var popovers: [String: NSPopover] = [:]
    private var subscription: AnyCancellable?
    private var dismissalSubscriptions = Set<AnyCancellable>()
    var showManager: (() -> Void)?

    init(model: AppModel) {
        self.model = model; super.init()
        subscription = Publishers.CombineLatest3(model.$snapshots, model.$records, model.$preferences)
            .receive(on: RunLoop.main).sink { [weak self] _, _, _ in self?.update() }
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard !NSApp.isActive else { return }
                self?.closePopovers()
            }.store(in: &dismissalSubscriptions)
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
            .receive(on: RunLoop.main).sink { [weak self] notification in
                guard let self, let window = notification.object as? NSWindow, !window.isKeyWindow else { return }
                for popover in self.popovers.values where popover.isShown && popover.contentViewController?.view.window === window {
                    popover.performClose(nil)
                }
            }.store(in: &dismissalSubscriptions)
        update()
    }
    private func update() {
        let visible = model.records.filter { model.preference(for: $0).enabled && model.preference(for: $0).menuBar }
        let ids = Set(visible.map(\.id))
        for id in Array(items.keys) where !ids.contains(id) && id != "_manager" { remove(id) }
        if visible.isEmpty { ensureManager() } else { remove("_manager") }
        for record in visible {
            let item: NSStatusItem
            if let existing = items[record.id] { item = existing }
            else {
                item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                items[record.id] = item
                item.button?.target = self; item.button?.action = #selector(clicked(_:))
                item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
                item.button?.identifier = NSUserInterfaceItemIdentifier(record.id)
            }
            guard let button = item.button else { continue }
            let presentation = model.snapshots[record.id]?.presentation
            if let rows = presentation?.menuBarRows, !rows.isEmpty {
                let width = CGFloat(presentation?.menuBarWidth ?? 72)
                item.length = width; button.title = ""
                button.image = Self.alignedMenuImage(rows: rows, width: width - 12)
            } else if let lines = presentation?.menuBarLines, !lines.isEmpty {
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor.black]
                let textWidth = ceil(lines.prefix(2).map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0)
                // Keep typical network rates stable, while allowing longer script output to fit.
                let imageWidth = max(48, textWidth)
                let textX = floor((imageWidth - textWidth) / 2)
                item.length = imageWidth + 12; button.title = ""
                let image = NSImage(size: NSSize(width: imageWidth, height: 22), flipped: false) { _ in
                    for (index, line) in lines.prefix(2).enumerated() {
                        (line as NSString).draw(at: NSPoint(x: textX, y: index == 0 ? 11 : 0), withAttributes: attributes)
                    }
                    return true
                }
                image.isTemplate = true; button.image = image
            } else {
                button.image = nil
                button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                button.title = presentation?.menuBar ?? (record.id == "system-monitor" ? "↓ —  ↑ —" : "◌")
                item.length = min(180, max(28, button.intrinsicContentSize.width + 8))
            }
            button.toolTip = "\(record.manifest.name) · 点击查看详情，右键打开组件管理"
            button.setAccessibilityLabel(record.manifest.name)
        }
    }
    private static func alignedMenuImage(rows: [MenuBarRow], width: CGFloat) -> NSImage {
        // Reserve independent columns: value changes must never move the unit's right edge.
        let gap: CGFloat = 4
        let unitWidth = width * 0.38
        let valueWidth = width - unitWidth - gap
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            func draw(_ text: String, x: CGFloat, y: CGFloat, available: CGFloat, rightAligned: Bool) {
                let baseFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
                let measured = (text as NSString).size(withAttributes: [.font: baseFont]).width
                // Fit unusually long values inside their column without resizing the menu item.
                let font = baseFont.withSize(9 * min(1, available / max(1, measured)))
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
                let textWidth = (text as NSString).size(withAttributes: attributes).width
                let origin = NSPoint(x: rightAligned ? x + available - textWidth : x, y: y)
                (text as NSString).draw(at: origin, withAttributes: attributes)
            }
            for (index, row) in rows.prefix(2).enumerated() {
                let y: CGFloat = index == 0 ? 11 : 0
                draw(row.left, x: 0, y: y, available: valueWidth, rightAligned: false)
                draw(row.right, x: width - unitWidth, y: y, available: unitWidth, rightAligned: true)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
    private func remove(_ id: String) {
        popovers.removeValue(forKey: id)?.close()
        if let item = items.removeValue(forKey: id) { NSStatusBar.system.removeStatusItem(item) }
    }
    private func ensureManager() {
        guard items["_manager"] == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 28)
        if let icon = DeskKitBrand.icon.copy() as? NSImage {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = false
            item.button?.image = icon
        }
        item.button?.setAccessibilityLabel("DeskKit")
        item.button?.target = self; item.button?.action = #selector(openManager)
        items["_manager"] = item
    }
    private func closePopovers() {
        for popover in popovers.values where popover.isShown { popover.performClose(nil) }
    }
    @objc private func openManager() { closePopovers(); showManager?() }
    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if NSApp.currentEvent?.type == .rightMouseUp { if model.selectPlugin(id) { openManager() }; return }
        if let popover = popovers[id], popover.isShown { popover.performClose(nil); return }
        closePopovers()
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NSHostingController(rootView: StatusPanel(model: model, id: id, manage: { [weak self, weak popover] in
            popover?.close()
            guard let self, self.model.selectPlugin(id) else { return }
            self.showManager?()
        }, sizeDidChange: { [weak self, weak popover, weak sender] size in
            // SwiftUI reports the natural height; apply changes outside its layout pass.
            DispatchQueue.main.async {
                guard let self, let popover, let sender,
                      self.popovers[id] === popover, popover.isShown else { return }
                self.resize(popover, to: size, anchoredTo: sender)
            }
        }))
        // Own the size explicitly: hosting constraints must not resize the window from
        // its bottom edge after AppKit has already positioned the popover.
        controller.sizingOptions = []
        let size = controller.sizeThatFits(in: NSSize(width: 316, height: 10_000))
        controller.view.setFrameSize(size)
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 316, height: ceil(size.height))
        popovers[id] = popover
        // A menu bar click need not activate an accessory app; give the panel focus explicitly.
        NSApp.activate(ignoringOtherApps: true)
        show(popover, anchoredTo: sender)
        popover.contentViewController?.view.window?.makeKey()
    }
    private func show(_ popover: NSPopover, anchoredTo button: NSStatusBarButton) {
        // Extend only the lower edge so the chevron clears even a two-line menu label.
        // Resolve "below" in the button's coordinate system, including flipped views.
        var anchor = button.bounds
        let clearance: CGFloat = 12
        anchor.size.height += clearance
        if !button.isFlipped { anchor.origin.y -= clearance }
        popover.show(relativeTo: anchor, of: button, preferredEdge: button.isFlipped ? .maxY : .minY)
    }
    private func resize(_ popover: NSPopover, to naturalSize: NSSize, anchoredTo button: NSStatusBarButton) {
        guard naturalSize.height.isFinite, naturalSize.height > 0 else { return }
        let size = NSSize(width: 316, height: ceil(naturalSize.height))
        guard popover.contentSize != size else { return }
        let animated = popover.animates
        popover.animates = false
        popover.contentSize = size
        // Re-anchor after live data adds/removes rows instead of keeping the old bottom edge.
        show(popover, anchoredTo: button)
        popover.animates = animated
    }
}

struct StatusPanel: View {
    @ObservedObject var model: AppModel
    let id: String
    let manage: () -> Void
    var sizeDidChange: ((CGSize) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: record?.manifest.symbol ?? "square.grid.2x2").foregroundStyle(.teal)
                Text(record?.manifest.name ?? "DeskKit").font(.headline)
                Spacer()
                Button { model.refresh(id, force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("刷新数据").disabled(model.loading.contains(id))
            }
            if let node = snapshot?.presentation.panel ?? snapshot?.presentation.widget { ComponentView(node: node) }
            else { ProgressView().frame(maxWidth: .infinity, minHeight: 100) }
            if let error = snapshot?.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
            if id != "system-monitor", let snapshot, snapshot.fetchedAt > Date(timeIntervalSince1970: 0) {
                HStack { Text(snapshot.isStale ? "缓存数据" : "已更新"); Text(snapshot.fetchedAt, style: .time) }.font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("组件管理…", action: manage).buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }.font(.caption)
        }.padding(20).frame(width: 316)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { sizeDidChange?($0) }
    }
    private var snapshot: ComponentSnapshot? { model.snapshots[id] }
    private var record: PluginRecord? { model.records.first { $0.id == id } }
}
