import AppKit
import ApplicationServices

/// 只在串行队列读取 Office 的辅助功能树；AppKit 界面和状态回调始终留在主线程。
final class OfficeWindowMonitor {
    var onChange: ((OfficeState) -> Void)?
    var onError: ((String) -> Void)?

    private struct RunningOffice {
        let kind: OfficeApp
        let processID: pid_t
    }

    private struct Identity {
        let id: String
        let element: AXUIElement
    }

    private final class Observation {
        let observer: AXObserver
        let application: AXUIElement
        var windows: [String: AXUIElement] = [:]

        init(observer: AXObserver, application: AXUIElement) {
            self.observer = observer
            self.application = application
        }
    }

    private let queue = DispatchQueue(label: "local.officetabs.accessibility", qos: .userInitiated)
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var started = false
    private var scanning = false
    private var needsRefresh = false
    private var sessionID = UUID()
    private var documents: [OfficeDocument] = []

    // 以下缓存只由 queue 访问；AX 对象身份与标题无关，另存为同名文件仍保留各自标签。
    private var identities: [pid_t: [Identity]] = [:]
    private var previousDocuments: [pid_t: [OfficeDocument]] = [:]
    private var documentOrder: [String] = []
    private var observations: [pid_t: Observation] = [:]

    private let applicationNotifications: [CFString] = [
        kAXWindowCreatedNotification as CFString,
        kAXFocusedWindowChangedNotification as CFString,
        kAXMainWindowChangedNotification as CFString,
        kAXApplicationActivatedNotification as CFString
    ]
    private let windowNotifications: [CFString] = [
        kAXWindowMovedNotification as CFString,
        kAXWindowResizedNotification as CFString,
        kAXTitleChangedNotification as CFString,
        kAXUIElementDestroyedNotification as CFString,
        kAXWindowMiniaturizedNotification as CFString,
        kAXWindowDeminiaturizedNotification as CFString,
        kAXSheetCreatedNotification as CFString
    ]

    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.start() }
            return
        }
        guard !started else { return }
        started = true
        sessionID = UUID()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        // Office 并非每种窗口都会发齐 AX 通知，低频补扫用于文档重命名和权限变化。
        timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }
        started = false
        sessionID = UUID()
        timer?.invalidate()
        timer = nil
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceObservers.removeAll()
        queue.async { [weak self] in self?.removeAllObservations() }
    }

    func refresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return
        }
        guard started else { return }
        guard !scanning else {
            needsRefresh = true
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard AXIsProcessTrusted() else {
            documents = []
            onChange?(OfficeState(documents: [], frontmostBundleID: frontmost?.bundleIdentifier,
                                  activeDocumentID: nil, hasModalWindow: false, accessibilityGranted: false))
            return
        }
        let kinds: [OfficeApp] = [.word, .excel, .powerpoint]
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> RunningOffice? in
            guard !app.isTerminated, let kind = kinds.first(where: { $0.bundleID == app.bundleIdentifier }) else { return nil }
            return RunningOffice(kind: kind, processID: app.processIdentifier)
        }
        let frontmostBundleID = frontmost?.bundleIdentifier
        let frontmostPID = frontmost?.processIdentifier
        let currentSession = sessionID
        scanning = true
        queue.async { [weak self] in
            guard let self = self else { return }
            let result = self.scan(running, frontmostPID: frontmostPID, frontmostBundleID: frontmostBundleID)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.scanning = false
                guard self.started, self.sessionID == currentSession else { return }
                var published = result
                let currentFrontmost = NSWorkspace.shared.frontmostApplication
                if currentFrontmost?.processIdentifier != frontmostPID {
                    // AX 扫描期间可能已切到其他应用，发布时重新确认前台，避免浮条越过当前应用。
                    published.frontmostBundleID = currentFrontmost?.bundleIdentifier
                    published.activeDocumentID = nil
                    published.hasModalWindow = false
                    self.needsRefresh = true
                }
                self.documents = published.documents
                self.onChange?(published)
                if self.needsRefresh {
                    self.needsRefresh = false
                    self.refresh()
                }
            }
        }
    }

    func activate(_ id: String) {
        perform(id) { document in
            AXUIElementPerformAction(document.element, kAXRaiseAction as CFString)
        }
    }

    func close(_ id: String) {
        perform(id) { document in
            guard let button = Self.element(document.element, kAXCloseButtonAttribute as CFString) else {
                return .actionUnsupported
            }
            // 让 Office 自身处理关闭和保存确认，禁止直接终止进程或选择“不保存”。
            return AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    /// 按布局设置为标签栏预留空间；已留足空间时保持窗口布局。
    func reserveTopSpace(_ id: String, height: CGFloat) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.reserveTopSpace(id, height: height) }
            return
        }
        guard let document = documents.first(where: { $0.id == id }), AXIsProcessTrusted() else { return }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let visibleFrames = NSScreen.screens.map { screen in
            CGRect(x: screen.visibleFrame.minX, y: primaryTop - screen.visibleFrame.maxY,
                   width: screen.visibleFrame.width, height: screen.visibleFrame.height)
        }
        queue.async { [weak self] in
            guard let self = self else { return }
            if Self.bool(document.element, "AXFullScreen" as CFString) {
                self.reportError("全屏窗口由 macOS 管理，请先退出全屏，再预留顶部空间。")
                return
            }
            let current = Self.frame(document.element) ?? document.frame
            guard let visible = visibleFrames.max(by: {
                $0.intersection(current).area < $1.intersection(current).area
            }), visible.intersects(current) else { return }
            let top = max(current.minY, visible.minY + max(0, height))
            guard top > current.minY + 0.5 else { return }
            let availableHeight = visible.maxY - top
            guard availableHeight >= 180 else {
                self.reportError("当前屏幕没有足够空间容纳文档和标签栏。")
                return
            }
            var position = CGPoint(x: current.minX, y: top)
            var size = CGSize(width: current.width, height: min(current.height, availableHeight))
            guard let positionValue = AXValueCreate(.cgPoint, &position),
                  let sizeValue = AXValueCreate(.cgSize, &size) else { return }
            // 先缩小后下移，避免窗口底边越界时被系统自动移动到意外位置。
            let resizeResult = AXUIElementSetAttributeValue(document.element, kAXSizeAttribute as CFString, sizeValue)
            let moveResult = AXUIElementSetAttributeValue(document.element, kAXPositionAttribute as CFString, positionValue)
            if moveResult != .success || (size != current.size && resizeResult != .success) {
                self.reportError("Office 暂时无法调整这个窗口的位置或大小。")
            }
            self.refresh()
        }
    }

    private func perform(_ id: String, action: @escaping (OfficeDocument) -> AXError) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.perform(id, action: action) }
            return
        }
        guard AXIsProcessTrusted(), let document = documents.first(where: { $0.id == id }) else { return }
        guard let app = NSRunningApplication(processIdentifier: document.processID), !app.isTerminated else {
            refresh()
            return
        }
        app.activate(options: [])
        queue.async { [weak self] in
            guard let self = self else { return }
            AXUIElementSetMessagingTimeout(document.element, 0.4)
            if Self.bool(document.element, kAXMinimizedAttribute as CFString) {
                _ = AXUIElementSetAttributeValue(document.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            _ = AXUIElementPerformAction(document.element, kAXRaiseAction as CFString)
            let result = action(document)
            if result != .success {
                self.reportError("Office 暂时未响应，请关闭弹出的对话框后再试。")
            }
            self.refresh()
        }
    }

    private func scan(_ running: [RunningOffice], frontmostPID: pid_t?, frontmostBundleID: String?) -> OfficeState {
        let livePIDs = Set(running.map(\.processID))
        identities = identities.filter { livePIDs.contains($0.key) }
        previousDocuments = previousDocuments.filter { livePIDs.contains($0.key) }
        for pid in Array(observations.keys) where !livePIDs.contains(pid) { removeObservation(pid) }
        var allDocuments: [OfficeDocument] = []
        var activeDocumentID: String?
        var hasModalWindow = false

        for app in running {
            let application = AXUIElementCreateApplication(app.processID)
            AXUIElementSetMessagingTimeout(application, 0.2)
            var rawWindows: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows)
            guard result == .success, let windows = rawWindows as? [AXUIElement] else {
                // 短暂忙碌不等同于文档已关闭；成功读取窗口列表后才真正移除标签。
                allDocuments += previousDocuments[app.processID] ?? []
                continue
            }
            let focused = Self.element(application, kAXFocusedWindowAttribute as CFString)
            let oldIdentities = identities[app.processID] ?? []
            let oldDocuments = Dictionary(uniqueKeysWithValues: (previousDocuments[app.processID] ?? []).map { ($0.id, $0) })
            var nextIdentities: [Identity] = []
            var appDocuments: [OfficeDocument] = []

            if app.processID == frontmostPID, let focused = focused {
                hasModalWindow = Self.focusedWindowHasModal(focused)
            }
            for window in windows {
                AXUIElementSetMessagingTimeout(window, 0.2)
                // 未聚焦的工具窗口只有明确声明 AXModal 且仍可见时，才阻挡文档操作。
                if app.processID == frontmostPID, Self.isVisibleExplicitModal(window) { hasModalWindow = true }
                let oldIdentity = oldIdentities.first { CFEqual($0.element, window) }
                let info = Self.documentWindowInfo(window, app: app.kind)
                // 只有明确读到非文档类型才移除；属性超时不代表枚举到的窗口已关闭。
                guard info.isDocument != false else { continue }
                let currentFrame = info.isDocument == true ? Self.frame(window) : nil
                let document: OfficeDocument
                if let frame = currentFrame, frame.width > 0, frame.height > 0,
                   let rawTitle = info.title {
                    let id = oldIdentity?.id ?? UUID().uuidString
                    let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    document = OfficeDocument(id: id, app: app.kind, processID: app.processID,
                                              title: title.isEmpty ? (info.fileURL?.lastPathComponent ?? "未命名文档") : title,
                                              fileURL: info.fileURL, isEdited: Self.bool(window, kAXEditedAttribute as CFString),
                                              isMinimized: Self.bool(window, kAXMinimizedAttribute as CFString),
                                              frame: frame, element: window)
                } else if let identity = oldIdentity, let previous = oldDocuments[identity.id] {
                    // Office 正忙时沿用最近完整快照，保持标签身份、顺序和窗口观察器。
                    document = previous
                } else {
                    continue
                }
                nextIdentities.append(Identity(id: document.id, element: window))
                appDocuments.append(document)
                if app.processID == frontmostPID, let focused = focused, CFEqual(focused, window) {
                    activeDocumentID = document.id
                }
            }
            identities[app.processID] = nextIdentities
            previousDocuments[app.processID] = appDocuments
            allDocuments += appDocuments
            updateObservation(for: app.processID, application: application, documents: appDocuments)
        }
        let liveIDs = Set(allDocuments.map(\.id))
        documentOrder.removeAll { !liveIDs.contains($0) }
        for document in allDocuments where !documentOrder.contains(document.id) { documentOrder.append(document.id) }
        let positions = Dictionary(uniqueKeysWithValues: documentOrder.enumerated().map { ($0.element, $0.offset) })
        allDocuments.sort { (positions[$0.id] ?? 0) < (positions[$1.id] ?? 0) }
        return OfficeState(documents: allDocuments, frontmostBundleID: frontmostBundleID,
                           activeDocumentID: activeDocumentID, hasModalWindow: hasModalWindow,
                           accessibilityGranted: true)
    }

    private func updateObservation(for pid: pid_t, application: AXUIElement, documents: [OfficeDocument]) {
        if observations[pid] == nil {
            var observer: AXObserver?
            let result = AXObserverCreate(pid, { _, _, _, context in
                guard let context = context else { return }
                let monitor = Unmanaged<OfficeWindowMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.refresh()
            }, &observer)
            guard result == .success, let observer = observer else { return }
            let observation = Observation(observer: observer, application: application)
            observations[pid] = observation
            let context = Unmanaged.passUnretained(self).toOpaque()
            for name in applicationNotifications {
                _ = AXObserverAddNotification(observer, application, name, context)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        guard let observation = observations[pid] else { return }
        let liveIDs = Set(documents.map(\.id))
        for id in Array(observation.windows.keys) where !liveIDs.contains(id) {
            if let window = observation.windows.removeValue(forKey: id) {
                for name in windowNotifications { _ = AXObserverRemoveNotification(observation.observer, window, name) }
            }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for document in documents where observation.windows[document.id] == nil {
            observation.windows[document.id] = document.element
            for name in windowNotifications {
                _ = AXObserverAddNotification(observation.observer, document.element, name, context)
            }
        }
    }

    private func removeObservation(_ pid: pid_t) {
        guard let observation = observations.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .commonModes)
    }

    private func removeAllObservations() {
        for pid in Array(observations.keys) { removeObservation(pid) }
    }

    private func reportError(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }

    private static func value(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &result) == .success else { return nil }
        return result
    }

    private static func string(_ element: AXUIElement, _ attribute: CFString) -> String? {
        value(element, attribute) as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        (value(element, attribute) as? NSNumber)?.boolValue ?? false
    }

    private static func element(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let result = value(element, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let rawPosition = value(element, kAXPositionAttribute as CFString),
              let rawSize = value(element, kAXSizeAttribute as CFString),
              CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func documentURL(_ element: AXUIElement) -> URL? {
        guard let raw = string(element, kAXDocumentAttribute as CFString), !raw.isEmpty else { return nil }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        return URL(string: raw)
    }

    private struct DocumentWindowInfo {
        // nil 表示关键 AX 属性读取失败，区别于明确识别到的启动页或对话框。
        let isDocument: Bool?
        let title: String?
        let fileURL: URL?
    }

    private static func documentWindowInfo(_ element: AXUIElement, app: OfficeApp) -> DocumentWindowInfo {
        let uncertain = DocumentWindowInfo(isDocument: nil, title: nil, fileURL: nil)
        let excluded = DocumentWindowInfo(isDocument: false, title: nil, fileURL: nil)
        guard let role = string(element, kAXRoleAttribute as CFString) else { return uncertain }
        guard role == kAXWindowRole as String else { return excluded }
        var rawSubrole: CFTypeRef?
        let subroleResult = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &rawSubrole)
        if subroleResult == .success, let subrole = rawSubrole as? String {
            guard subrole == kAXStandardWindowSubrole as String else { return excluded }
        } else if subroleResult != .attributeUnsupported && subroleResult != .noValue {
            return uncertain
        }
        guard !bool(element, kAXModalAttribute as CFString) else { return excluded }
        guard let title = string(element, kAXTitleAttribute as CFString) else { return uncertain }
        let fileURL = documentURL(element)
        if fileURL != nil { return DocumentWindowInfo(isDocument: true, title: title, fileURL: fileURL) }
        // Office 启动页也声明为标准窗口，DocStage 是首页/最近文件选择器的稳定标识。
        // 已有 AXDocument 的窗口优先确认为文档，避免文件恰好与首页同名时被排除。
        if string(element, kAXIdentifierAttribute as CFString) == "DocStage" { return excluded }
        // 标题和路径只读一次，避免同一扫描中前一次成功、后一次超时覆盖已知名称。
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let launchTitles: Set<String> = ["", app.name, "Microsoft \(app.name)", "Home", "Open", "New", "Templates", "主页", "开始", "打开", "新建", "模板", "打开新的和最近使用的文件", "Open New and Recent Files"]
        return DocumentWindowInfo(isDocument: !launchTitles.contains(normalizedTitle), title: title, fileURL: nil)
    }

    private static func isVisibleExplicitModal(_ element: AXUIElement) -> Bool {
        guard bool(element, kAXModalAttribute as CFString) else { return false }
        return !bool(element, kAXMinimizedAttribute as CFString) && !bool(element, kAXHiddenAttribute as CFString)
    }

    private static func isVisibleSheet(_ element: AXUIElement) -> Bool {
        guard string(element, kAXRoleAttribute as CFString) == kAXSheetRole as String else { return false }
        return !bool(element, kAXMinimizedAttribute as CFString) && !bool(element, kAXHiddenAttribute as CFString)
    }

    private static func focusedWindowHasModal(_ element: AXUIElement) -> Bool {
        if isVisibleExplicitModal(element) || isVisibleSheet(element) { return true }
        // AXDialog 也用于非模态检查器；只有焦点文档真正附带的 sheet 才作为阻塞证据。
        if let sheets = value(element, "AXSheets" as CFString) as? [AXUIElement], sheets.contains(where: isVisibleSheet) {
            return true
        }
        // 仅检查窗口直接子项，避免为寻找保存对话框而遍历完整文档内容。
        if let children = value(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            return children.contains(where: isVisibleSheet)
        }
        return false
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isInfinite ? 0 : max(0, width) * max(0, height) }
}
