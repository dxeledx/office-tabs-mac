import AppKit
import ApplicationServices
import UniformTypeIdentifiers
import OSLog

/// 点击标签时保持 Office 的键盘焦点，避免把光标从文档编辑区域夺走。
final class TabPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = OfficeWindowMonitor()
    private let defaults = UserDefaults.standard
    private var state = OfficeState()
    private var panel: TabPanel!
    private var bar: TabBarView!
    private var statusItem: NSStatusItem!
    private var setupWindow: NSWindow?
    private var setupStatus: NSTextField?
    private var permissionTimer: Timer?
    private var orderedIDs: [String] = []
    private var lastActiveID: String?
    private var lastLayoutRequest: [String: Date] = [:]
    private var errorMessage: String?
    private var foregroundObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var visibilityReason = ""
    private let logger = Logger(subsystem: "local.jason.OfficeTabs", category: "window-state")

    private var isHidden: Bool {
        get { defaults.bool(forKey: "barHidden") }
        set { defaults.set(newValue, forKey: "barHidden") }
    }
    private var reserveSpace: Bool {
        get { defaults.object(forKey: "reserveSpace") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "reserveSpace") }
    }
    private var followsWindow: Bool {
        get { defaults.object(forKey: "followsWindow") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "followsWindow") }
    }
    private var filter: OfficeApp? {
        get { defaults.string(forKey: "appFilter").flatMap(OfficeApp.init(rawValue:)) }
        set { defaults.set(newValue?.rawValue, forKey: "appFilter") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 保持单实例，防止重复启动后出现多条标签栏和互相争抢的窗口布局。
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.jason.OfficeTabs")
        if peers.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        createPanel()
        createStatusItem()
        foregroundObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                               object: nil, queue: .main) { [weak self] _ in self?.updateBar() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in self?.updateBar() }
        monitor.onChange = { [weak self] snapshot in self?.receive(snapshot) }
        monitor.onError = { [weak self] message in
            self?.errorMessage = message
            self?.statusItem.button?.toolTip = "Office Tabs：\(message)"
        }
        monitor.start()
        if !AXIsProcessTrusted() { showSetup(nil) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        monitor.stop()
        panel.orderOut(nil)
        if let foregroundObserver { NSWorkspace.shared.notificationCenter.removeObserver(foregroundObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !AXIsProcessTrusted() { showSetup(nil) }
        else { isHidden = false; updateBar() }
        return false
    }

    private func createPanel() {
        panel = TabPanel(contentRect: NSRect(x: 100, y: 100, width: 900, height: 44),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Office Tabs 文档标签栏"
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 900, height: 44))
        bar.autoresizingMask = [.width, .height]
        panel.contentView = bar
        bar.onSelect = { [weak self] id in self?.monitor.activate(id) }
        bar.onClose = { [weak self] id in self?.monitor.close(id) }
        bar.onFilter = { [weak self] app in self?.filter = app; self?.updateBar() }
        bar.onReorder = { [weak self] ids in self?.orderedIDs = ids; self?.updateBar() }
        bar.onSettings = { [weak self] in self?.showSettingsMenu() }
        bar.onOpen = { [weak self] in self?.openDocument(nil) }
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Office Tabs")
        statusItem.button?.toolTip = "Office Tabs · Office 文档标签切换"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) { fillMenu(menu) }

    private func item(_ title: String, action: Selector?, checked: Bool? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        if let checked { entry.state = checked ? .on : .off }
        return entry
    }

    private func fillMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Office Tabs", action: #selector(showAbout)))
        let count = item("已识别 \(state.documents.count) 个文档窗口", action: nil)
        menu.addItem(count)
        if let errorMessage { menu.addItem(item(errorMessage, action: nil)) }
        menu.addItem(.separator())
        menu.addItem(item(isHidden ? "显示标签栏" : "隐藏标签栏", action: #selector(toggleHidden)))
        menu.addItem(item("跟随当前文档窗口", action: #selector(toggleFollow), checked: followsWindow))
        menu.addItem(item("自动预留顶部空间", action: #selector(toggleReserve), checked: reserveSpace))
        menu.addItem(item("恢复默认位置", action: #selector(resetPosition)))
        menu.addItem(.separator())
        if !state.documents.isEmpty {
            let documents = NSMenu()
            for document in sortedDocuments() {
                let entry = item("\(document.app.letter)  \(document.title)", action: #selector(selectDocument(_:)), checked: document.id == state.activeDocumentID)
                entry.representedObject = document.id
                entry.toolTip = document.fileURL?.path
                documents.addItem(entry)
            }
            let list = item("已打开的文档", action: nil)
            list.submenu = documents
            menu.addItem(list)
        }
        menu.addItem(item("打开 Office 文档…", action: #selector(openDocument(_:))))
        menu.addItem(item("检查辅助功能权限…", action: #selector(showSetup(_:))))
        menu.addItem(item("刷新文档列表", action: #selector(refresh)))
        menu.addItem(.separator())
        let quit = item("退出 Office Tabs", action: #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func showSettingsMenu() {
        let menu = NSMenu()
        fillMenu(menu)
        menu.popUp(positioning: nil, at: NSPoint(x: max(0, bar.bounds.width - 30), y: 3), in: bar)
    }

    private func sortedDocuments() -> [OfficeDocument] {
        let rank = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
        return state.documents.sorted { rank[$0.id, default: Int.max] < rank[$1.id, default: Int.max] }
    }

    private func receive(_ snapshot: OfficeState) {
        state = snapshot
        if let active = snapshot.activeDocumentID { lastActiveID = active }
        let existing = Set(snapshot.documents.map(\.id))
        orderedIDs.removeAll { !existing.contains($0) }
        for document in snapshot.documents where !orderedIDs.contains(document.id) { orderedIDs.append(document.id) }
        lastLayoutRequest = lastLayoutRequest.filter { existing.contains($0.key) }
        if snapshot.accessibilityGranted { errorMessage = nil }
        setupStatus?.stringValue = snapshot.accessibilityGranted ? "已获得辅助功能权限，可以使用标签切换。" : "尚未授权。请在系统设置中启用 Office Tabs。"
        statusItem.button?.toolTip = snapshot.accessibilityGranted ? "Office Tabs · \(snapshot.documents.count) 个文档" : "Office Tabs · 需要辅助功能权限"
        updateBar()
    }

    private func updateBar() {
        if panel.isVisible, !followsWindow {
            defaults.set(panel.frame.minX, forKey: "manualX")
            defaults.set(panel.frame.minY, forKey: "manualY")
        }
        // AX 扫描可能在 Office 忙碌时变慢，显示前以最新前台应用再次核实可见性。
        let currentFrontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let frontOffice = OfficeApp.matching(currentFrontBundle)
        let preferredID = state.activeDocumentID ?? lastActiveID
        // 应用切换通知先于 AX 焦点回调到达；过渡期间只采用当前 Office 的文档和位置。
        let currentDocuments = state.documents.filter { $0.app == frontOffice && !$0.isMinimized }
        let currentDocument = currentDocuments.first { $0.id == preferredID } ?? currentDocuments.first
        bar.update(documents: sortedDocuments(), activeID: currentDocument?.id ?? lastActiveID,
                   filter: filter, themeApp: frontOffice)
        if !state.accessibilityGranted { hidePanel("permission"); return }
        if isHidden { hidePanel("user-hidden"); return }
        if state.hasModalWindow { hidePanel("office-dialog"); return }
        if state.documents.isEmpty { hidePanel("no-documents"); return }
        if frontOffice == nil { hidePanel("other-app"); return }
        guard let document = currentDocument else { hidePanel("no-current-document"); return }
        if followsWindow {
            guard let frame = panelFrame(for: document) else { hidePanel("invalid-frame"); return }
            panel.setFrame(frame, display: true)
        } else if !panel.isVisible {
            let savedX = defaults.object(forKey: "manualX") as? Double
            let savedY = defaults.object(forKey: "manualY") as? Double
            // 手动位置属于放置它的屏幕，切换应用后仍回到该屏幕；拔除屏幕时才回退。
            let savedRect = NSRect(x: savedX ?? -100000, y: savedY ?? -100000, width: 600, height: 44)
            let savedScreen = NSScreen.screens.max { $0.frame.intersection(savedRect).area < $1.frame.intersection(savedRect).area }
            let screen = savedScreen.flatMap { $0.frame.intersects(savedRect) ? $0 : nil } ?? NSScreen.main ?? NSScreen.screens.first
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
            let width = min(1100, visible.width - 16)
            let x = max(visible.minX, min(savedX ?? visible.midX - width / 2, visible.maxX - width))
            let y = max(visible.minY, min(savedY ?? visible.maxY - 50, visible.maxY - 44))
            panel.setFrame(NSRect(x: x, y: y, width: width, height: 44), display: true)
        }
        panel.orderFrontRegardless()
        if visibilityReason != "visible" {
            // 只记录可见性原因，不记录文档名称或路径，便于定位权限和弹窗造成的隐藏。
            logger.notice("visibility: visible, documents: \(self.state.documents.count)")
            visibilityReason = "visible"
        }
        if !followsWindow {
            defaults.set(panel.frame.minX, forKey: "manualX")
            defaults.set(panel.frame.minY, forKey: "manualY")
        }
    }

    private func hidePanel(_ reason: String) {
        if visibilityReason != reason {
            logger.notice("visibility: \(reason, privacy: .public), documents: \(self.state.documents.count)")
            visibilityReason = reason
        }
        if panel.isVisible { panel.orderOut(nil) }
    }

    private func panelFrame(for document: OfficeDocument) -> NSRect? {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = NSRect(x: document.frame.minX, y: primaryTop - document.frame.maxY,
                           width: document.frame.width, height: document.frame.height)
        guard frame.width > 100, frame.height > 100 else { return nil }
        let screen = NSScreen.screens.max { a, b in
            a.frame.intersection(frame).area < b.frame.intersection(frame).area
        } ?? NSScreen.main
        guard let screen else { return nil }
        let visible = screen.visibleFrame
        let height: CGFloat = 44
        let width = max(380, min(frame.width, visible.width))
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let isFullScreen = abs(frame.minY - screen.frame.minY) < 3 && abs(frame.height - screen.frame.height) < 3
        if isFullScreen {
            // 全屏窗口交由系统管理几何信息，标签栏作为辅助面板展示，绝不改写其大小。
            return NSRect(x: x, y: visible.maxY - height - 4, width: width, height: height)
        }
        let desiredTop = frame.maxY + height + 5
        if desiredTop > visible.maxY + 1, reserveSpace {
            let last = lastLayoutRequest[document.id] ?? .distantPast
            if Date().timeIntervalSince(last) > 2 {
                lastLayoutRequest[document.id] = Date()
                monitor.reserveTopSpace(document.id, height: height + 5)
            }
            // AX 调整可能被 Office 拒绝；失败后保留可用的顶部浮栏，不持续隐藏。
            return NSRect(x: x, y: visible.maxY - height, width: width, height: height)
        }
        return NSRect(x: x, y: min(frame.maxY + 5, visible.maxY - height), width: width, height: height)
    }

    @objc private func toggleHidden() { isHidden.toggle(); updateBar() }
    @objc private func toggleFollow() { followsWindow.toggle(); updateBar() }
    @objc private func toggleReserve() { reserveSpace.toggle(); updateBar() }
    @objc private func resetPosition() {
        followsWindow = true
        defaults.removeObject(forKey: "manualX")
        defaults.removeObject(forKey: "manualY")
        updateBar()
    }
    @objc private func refresh() { monitor.refresh() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func selectDocument(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { monitor.activate(id) }
    }

    @objc private func openDocument(_ sender: Any?) {
        let picker = NSOpenPanel()
        picker.title = "打开 Office 文档"
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        picker.allowedContentTypes = ["doc", "docx", "docm", "rtf", "xls", "xlsx", "xlsm", "csv", "ppt", "pptx", "pptm"].compactMap { UTType(filenameExtension: $0) }
        // 只把选择的路径交给对应 Office 应用，文档内容始终由 Office 读取和保存。
        picker.begin { [weak self] response in
            guard response == .OK else { return }
            for url in picker.urls {
                let ext = url.pathExtension.lowercased()
                let app: OfficeApp = ["xls", "xlsx", "xlsm", "csv"].contains(ext) ? .excel : (["ppt", "pptx", "pptm"].contains(ext) ? .powerpoint : .word)
                if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
                    NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                            configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                }
            }
            self?.monitor.refresh()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Office Tabs 0.1.0"
        alert.informativeText = "为 Word、Excel 和 PowerPoint 提供文档标签切换。\n\n本机运行 · Swift / AppKit · MIT 许可\n通过 macOS 辅助功能读取窗口标题、路径和状态。"
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func showSetup(_ sender: Any?) {
        if let setupWindow { setupWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 330),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "欢迎使用 Office Tabs"
        window.isReleasedWhenClosed = false
        window.center()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 330))
        let title = NSTextField(labelWithString: "让 Office 文档，一点即达。")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        title.frame = NSRect(x: 32, y: 258, width: 460, height: 36)
        content.addSubview(title)
        let text = NSTextField(wrappingLabelWithString: "Office Tabs 会把已打开的 Word、Excel 和 PowerPoint 窗口列为顶部标签。\n\n首次使用，请打开「系统设置 → 隐私与安全性 → 辅助功能」，添加并启用 Office Tabs，以便切换和关闭文档窗口。")
        text.font = .systemFont(ofSize: 14)
        text.textColor = .secondaryLabelColor
        text.frame = NSRect(x: 32, y: 119, width: 456, height: 122)
        content.addSubview(text)
        let status = NSTextField(wrappingLabelWithString: AXIsProcessTrusted() ? "已获得辅助功能权限，可以使用标签切换。" : "尚未授权。请在系统设置中启用 Office Tabs。")
        status.font = .systemFont(ofSize: 12)
        status.frame = NSRect(x: 32, y: 76, width: 456, height: 32)
        content.addSubview(status)
        setupStatus = status
        let open = NSButton(title: "打开辅助功能设置", target: self, action: #selector(openAccessibility))
        open.bezelStyle = .rounded
        open.frame = NSRect(x: 28, y: 25, width: 190, height: 34)
        content.addSubview(open)
        let done = NSButton(title: "开始使用", target: self, action: #selector(finishSetup))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: 370, y: 25, width: 120, height: 34)
        content.addSubview(done)
        window.contentView = content
        setupWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.monitor.refresh() }
    }

    @objc private func openAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    @objc private func finishSetup() {
        guard AXIsProcessTrusted() else { openAccessibility(); return }
        setupWindow?.close()
        permissionTimer?.invalidate()
        permissionTimer = nil
        isHidden = false
        monitor.refresh()
        if let document = state.documents.first { monitor.activate(document.id) }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : max(0, width) * max(0, height) }
}
