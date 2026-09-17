import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var status: StatusBarController?
    private var manager: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = DeskKitBrand.icon
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        status = StatusBarController(model: .shared)
        status?.showManager = { [weak self] in self?.showManager() }
        if !UserDefaults.standard.bool(forKey: "hasLaunched") || CommandLine.arguments.contains("--show-manager") {
            UserDefaults.standard.set(true, forKey: "hasLaunched"); showManager()
        }
    }
    private func installMainMenu() {
        let mainMenu = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title); item.submenu = menu; mainMenu.addItem(item)
            return menu
        }
        let appMenu = submenu("DeskKit")
        let manage = appMenu.addItem(withTitle: "组件管理…", action: #selector(showManager), keyEquivalent: ",")
        manage.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 DeskKit", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 DeskKit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editMenu = submenu("编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        let save = editMenu.addItem(withTitle: "保存", action: #selector(saveEditor), keyEquivalent: "s")
        save.target = self
        editMenu.addItem(.separator())
        for (title, action, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editMenu.addItem(.separator())
        for (title, action, key, modifiers) in [
            ("查找…", NSTextFinder.Action.showFindInterface, "f", NSEvent.ModifierFlags.command),
            ("查找下一个", .nextMatch, "g", .command),
            ("查找上一个", .previousMatch, "g", [.command, .shift])
        ] {
            let item = editMenu.addItem(withTitle: title, action: #selector(findInEditor(_:)), keyEquivalent: key)
            item.target = self; item.tag = action.rawValue; item.keyEquivalentModifierMask = modifiers
        }
        let windowMenu = submenu("窗口")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.mainMenu = mainMenu; NSApp.windowsMenu = windowMenu
    }
    @objc func showManager() {
        if manager == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1010, height: 730), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "DeskKit"; window.titlebarAppearsTransparent = true; window.minSize = NSSize(width: 820, height: 610)
            window.delegate = self
            window.contentView = NSHostingView(rootView: ManagerView(model: .shared))
            window.isReleasedWhenClosed = false; window.center(); window.setFrameAutosaveName("DeskKitManager")
            manager = window
        }
        manager?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let id = components.queryItems?.first(where: { $0.name == "component" })?.value { _ = AppModel.shared.selectPlugin(id) }
        showManager()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showManager(); return true }
    @objc private func saveEditor() { AppModel.shared.saveEdits() }
    private var activeCodeEditor: NSTextView? {
        guard let manager, manager.isKeyWindow, manager.attachedSheet == nil,
              NSApp.modalWindow == nil, let content = manager.contentView else { return nil }
        func find(in view: NSView) -> NSTextView? {
            guard !view.isHiddenOrHasHiddenAncestor else { return nil }
            if let scroll = view as? CodeScrollView { return scroll.documentView as? NSTextView }
            for child in view.subviews {
                if let editor = find(in: child) { return editor }
            }
            return nil
        }
        return find(in: content)
    }
    @objc private func findInEditor(_ sender: NSMenuItem) {
        guard let editor = activeCodeEditor else { return }
        // Search the visible script/configuration even when a toolbar button has focus.
        if sender.tag == NSTextFinder.Action.showFindInterface.rawValue {
            editor.window?.makeFirstResponder(editor)
        }
        editor.performTextFinderAction(sender)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(saveEditor) { return AppModel.shared.editSession != nil }
        if menuItem.action == #selector(findInEditor(_:)) { return activeCodeEditor != nil }
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        AppModel.shared.resolvePendingEdits("关闭窗口前")
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppModel.shared.resolvePendingEdits("退出应用前") ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { AppModel.shared.shutdown() }
}

@MainActor enum DeskKitBrand {
    // Read the bundled artwork directly so in-app branding does not depend on icon caches.
    static let icon: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) { return image }
        return NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }()

    static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.icon = icon
        return alert
    }
}
