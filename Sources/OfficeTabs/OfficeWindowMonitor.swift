import AppKit
import ApplicationServices
import OSLog

/// 只在串行队列读取 Office 的辅助功能树；AppKit 界面和状态回调始终留在主线程。
final class OfficeWindowMonitor {
    var onChange: ((OfficeState) -> Void)?
    var onError: ((String) -> Void)?
    var onGeometryChange: ((String, CGRect, Bool, TimeInterval) -> Void)?
    var onInteractionChange: ((Bool) -> Void)?

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
    private let geometryQueue = DispatchQueue(label: "local.officetabs.geometry", qos: .userInteractive)
    private var timer: Timer?
    private var geometryTimer: Timer?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var metadataRefreshWork: DispatchWorkItem?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var started = false
    private var scanning = false
    private var needsRefresh = false
    private var sessionID = UUID()
    private var documents: [OfficeDocument] = []
    private var activeDocumentID: String?
    private var accessibilityGranted = false
    private var interactionDown = false
    private var settleUntil: TimeInterval = 0
    private var geometryInFlight = false
    private var focusRevision: UInt64 = 0
    private var geometryFrames: [String: (frame: CGRect, timestamp: TimeInterval)] = [:]
    private var lastFocusedSample: (id: String, processID: pid_t, timestamp: TimeInterval)?
    private let geometryLogger = Logger(subsystem: "local.jason.OfficeTabs", category: "geometry")
    private var lastReservationDiagnostic: String?

    // 高频采样拥有独立 AX 引用和连接超时，不能覆盖全量扫描正在使用的窗口引用。
    private var geometryApplication: (processID: pid_t, element: AXUIElement)?

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
                guard let self else { return }
                self.focusRevision &+= 1
                self.extendGeometryBurst()
                self.refresh()
            })
        }
        // Office 并非每种窗口都会发齐 AX 通知，低频补扫用于文档重命名和权限变化。
        timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            // 移动时不重复扫描全部窗口；释放鼠标后的合并扫描负责同步名称和状态。
            if !self.interactionDown { self.refresh() }
        }
        // 只观察鼠标按下/释放来启动短时采样，不监听键盘，也不在空闲时保持 60Hz 唤醒。
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] _ in
            self?.pointerInteractionEvent()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.pointerInteractionEvent()
            return event
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
        geometryTimer?.invalidate()
        geometryTimer = nil
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        metadataRefreshWork?.cancel()
        metadataRefreshWork = nil
        geometryInFlight = false
        geometryFrames.removeAll()
        lastFocusedSample = nil
        if interactionDown { onInteractionChange?(false) }
        interactionDown = false
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
            accessibilityGranted = false
            activeDocumentID = nil
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
        let scanStartedAt = ProcessInfo.processInfo.systemUptime
        scanning = true
        queue.async { [weak self] in
            guard let self = self else { return }
            let result = self.scan(running, frontmostPID: frontmostPID, frontmostBundleID: frontmostBundleID)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.scanning = false
                guard self.started, self.sessionID == currentSession else { return }
                var published = result
                self.accessibilityGranted = published.accessibilityGranted
                let currentFrontmost = NSWorkspace.shared.frontmostApplication
                if currentFrontmost?.processIdentifier != frontmostPID {
                    // AX 扫描期间可能已切到其他应用，发布时重新确认前台，避免浮条越过当前应用。
                    published.frontmostBundleID = currentFrontmost?.bundleIdentifier
                    published.activeDocumentID = nil
                    published.hasModalWindow = false
                    self.needsRefresh = true
                }
                // 低频扫描完成时，保留采样线程已读到的更新位置，防止标签栏向旧位置回跳。
                let liveIDs = Set(published.documents.map(\.id))
                self.geometryFrames = self.geometryFrames.filter { liveIDs.contains($0.key) }
                published.documents = published.documents.map { document in
                    guard let latest = self.geometryFrames[document.id], latest.timestamp >= document.geometryTimestamp else { return document }
                    return Self.replacingFrame(document, with: latest.frame, timestamp: latest.timestamp)
                }
                if let latest = self.lastFocusedSample, latest.timestamp >= scanStartedAt,
                   latest.processID == currentFrontmost?.processIdentifier, liveIDs.contains(latest.id) {
                    published.activeDocumentID = latest.id
                }
                self.documents = published.documents
                self.activeDocumentID = published.activeDocumentID
                self.onChange?(published)
                if self.needsRefresh {
                    self.needsRefresh = false
                    self.refresh()
                }
            }
        }
    }

    private func extendGeometryBurst() {
        settleUntil = max(settleUntil, ProcessInfo.processInfo.systemUptime + 0.35)
        guard geometryTimer == nil, started, accessibilityGranted,
              OfficeApp.matching(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.geometryTick() }
        RunLoop.main.add(timer, forMode: .common)
        geometryTimer = timer
    }

    private func pointerInteractionEvent() {
        guard started else { return }
        extendGeometryBurst()
        geometryTick()
    }

    private func scheduleMetadataRefresh() {
        metadataRefreshWork?.cancel()
        guard !interactionDown, NSEvent.pressedMouseButtons & 1 == 0 else {
            metadataRefreshWork = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.started else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 {
                self.scheduleMetadataRefresh()
                return
            }
            self.refresh()
        }
        metadataRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func geometryTick() {
        guard started, accessibilityGranted else {
            geometryTimer?.invalidate()
            geometryTimer = nil
            return
        }
        let mouseDown = NSEvent.pressedMouseButtons & 1 != 0
        let now = ProcessInfo.processInfo.systemUptime
        // 空闲时只读取鼠标按钮快照，不发送 AX 请求，也不反复查询所有运行中的应用。
        guard mouseDown || interactionDown || now < settleUntil else {
            geometryTimer?.invalidate()
            geometryTimer = nil
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let isOfficeFront = OfficeApp.matching(frontmost?.bundleIdentifier) != nil
        let down = mouseDown && isOfficeFront
        if down != interactionDown {
            interactionDown = down
            onInteractionChange?(down)
            if !down {
                extendGeometryBurst()
                scheduleMetadataRefresh()
            }
        }
        guard isOfficeFront else {
            geometryTimer?.invalidate()
            geometryTimer = nil
            return
        }
        guard let processID = frontmost?.processIdentifier,
              mouseDown || now < settleUntil else { return }
        requestGeometrySample(processID: processID)
    }

    private func requestGeometrySample(processID: pid_t) {
        guard !geometryInFlight else { return }
        let candidates = documents.filter { $0.processID == processID && !$0.isMinimized }
        guard !candidates.isEmpty else { return }
        let currentSession = sessionID
        let currentFocusRevision = focusRevision
        geometryInFlight = true
        geometryQueue.async { [weak self] in
            guard let self else { return }
            let application: AXUIElement
            if let cached = self.geometryApplication, cached.processID == processID {
                application = cached.element
            } else {
                application = AXUIElementCreateApplication(processID)
                AXUIElementSetMessagingTimeout(application, 0.035)
                self.geometryApplication = (processID, application)
            }
            // 焦点窗口引用只供几何线程使用，避免与全量扫描的 AX 超时设置互相干扰。
            let focused = Self.element(application, kAXFocusedWindowAttribute as CFString)
            let target = focused.flatMap { focused in candidates.first { CFEqual($0.element, focused) } }
            if let focused { AXUIElementSetMessagingTimeout(focused, 0.035) }
            let sampledAt = ProcessInfo.processInfo.systemUptime
            let sampledFrame = target == nil ? nil : focused.flatMap { Self.frame($0) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.started, self.sessionID == currentSession else { return }
                self.geometryInFlight = false
                guard self.focusRevision == currentFocusRevision,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
                      let target, self.documents.contains(where: { $0.id == target.id }),
                      let frame = sampledFrame, frame.width > 0, frame.height > 0 else { return }
                let previous = self.geometryFrames[target.id]
                let focusChanged = self.activeDocumentID != target.id
                self.geometryFrames[target.id] = (frame, sampledAt)
                self.lastFocusedSample = (target.id, processID, sampledAt)
                self.activeDocumentID = target.id
                self.documents = self.documents.map { document in
                    document.id == target.id ? Self.replacingFrame(document, with: frame, timestamp: sampledAt) : document
                }
                if previous?.frame != frame || focusChanged {
                    self.onGeometryChange?(target.id, frame, NSEvent.pressedMouseButtons & 1 != 0, sampledAt)
                }
            }
        }
    }

    private func handleNotification(_ name: CFString) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.handleNotification(name) }
            return
        }
        guard started else { return }
        if name as String == kAXWindowMovedNotification as String || name as String == kAXWindowResizedNotification as String {
            extendGeometryBurst()
            geometryTick()
            scheduleMetadataRefresh()
        } else {
            if name as String == kAXFocusedWindowChangedNotification as String || name as String == kAXMainWindowChangedNotification as String {
                focusRevision &+= 1
                extendGeometryBurst()
            }
            refresh()
        }
    }

    private static func replacingFrame(_ document: OfficeDocument, with frame: CGRect, timestamp: TimeInterval) -> OfficeDocument {
        OfficeDocument(id: document.id, app: document.app, processID: document.processID,
                       title: document.title, fileURL: document.fileURL, isEdited: document.isEdited,
                       isMinimized: document.isMinimized, isFullScreen: document.isFullScreen,
                       frame: frame, geometryTimestamp: timestamp, element: document.element)
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

    /// 布局层在释放鼠标、窗口稳定后调用；最终结果必须以 Office 返回的实际位置确认。
    func reserveTopSpace(_ id: String, height: CGFloat, completion: ((Bool) -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.reserveTopSpace(id, height: height, completion: completion) }
            return
        }
        guard let document = documents.first(where: { $0.id == id }) else {
            reportGeometryDiagnostic("missing-document"); completion?(false); return
        }
        guard AXIsProcessTrusted() else { reportGeometryDiagnostic("permission"); completion?(false); return }
        guard Self.isSafeToAdjust(processID: document.processID) else {
            reportGeometryDiagnostic("mouse-or-foreground"); completion?(false); return
        }
        let currentSession = sessionID
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let visibleFrames = NSScreen.screens.map { screen in
            CGRect(x: screen.visibleFrame.minX, y: primaryTop - screen.visibleFrame.maxY,
                   width: screen.visibleFrame.width, height: screen.visibleFrame.height)
        }
        queue.async { [weak self] in
            guard let self = self else { return }
            let finish: (Bool, CGRect?, TimeInterval) -> Void = { [weak self] success, frame, timestamp in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.started, self.sessionID == currentSession else { completion?(false); return }
                    if let frame {
                        self.geometryFrames[id] = (frame, timestamp)
                        self.documents = self.documents.map { document in
                            document.id == id ? Self.replacingFrame(document, with: frame, timestamp: timestamp) : document
                        }
                        self.onGeometryChange?(id, frame, NSEvent.pressedMouseButtons & 1 != 0, timestamp)
                    }
                    completion?(success)
                    self.extendGeometryBurst()
                    self.scheduleMetadataRefresh()
                }
            }
            guard self.isSafeToAdjust(document: document), self.canReserveSpace(on: document.element) else {
                finish(false, nil, 0); return
            }
            // 排队期间窗口可能已被移动或切换；不使用缓存位置执行写入。
            let application = AXUIElementCreateApplication(document.processID)
            AXUIElementSetMessagingTimeout(application, 0.12)
            guard let focused = Self.element(application, kAXFocusedWindowAttribute as CFString), CFEqual(focused, document.element) else {
                self.reportGeometryDiagnostic("focus-changed"); finish(false, nil, 0); return
            }
            let currentReadAt = ProcessInfo.processInfo.systemUptime
            guard let current = Self.frame(document.element) else {
                self.reportGeometryDiagnostic("frame-unreadable"); finish(false, nil, 0); return
            }
            guard let visible = visibleFrames.max(by: {
                $0.intersection(current).area < $1.intersection(current).area
            }), visible.intersects(current) else {
                self.reportGeometryDiagnostic("screen-unavailable"); finish(false, nil, 0); return
            }
            let top = max(current.minY, visible.minY + max(0, height))
            guard top > current.minY + 0.5 else {
                self.reportGeometryDiagnostic("already-reserved")
                finish(true, current, currentReadAt)
                return
            }
            let availableHeight = visible.maxY - top
            guard availableHeight >= 180 else {
                self.reportError("当前屏幕没有足够空间容纳文档和标签栏。")
                self.reportGeometryDiagnostic("insufficient-height")
                finish(false, nil, 0)
                return
            }
            var position = CGPoint(x: current.minX, y: top)
            var size = CGSize(width: current.width, height: min(current.height, availableHeight))
            guard let positionValue = AXValueCreate(.cgPoint, &position),
                  let sizeValue = AXValueCreate(.cgSize, &size) else {
                self.reportGeometryDiagnostic("invalid-geometry-value"); finish(false, nil, 0); return
            }
            guard self.isSafeToAdjust(document: document) else { finish(false, nil, 0); return }
            // 先缩小后下移，避免窗口底边越界时被系统自动移动到意外位置。
            let resizeResult: AXError = size == current.size ? .success : AXUIElementSetAttributeValue(document.element, kAXSizeAttribute as CFString, sizeValue)
            guard self.isSafeToAdjust(document: document) else { finish(false, nil, 0); return }
            let moveResult = AXUIElementSetAttributeValue(document.element, kAXPositionAttribute as CFString, positionValue)
            let verifiedAt = ProcessInfo.processInfo.systemUptime
            let verifiedFrame = Self.frame(document.element)
            let verified = verifiedFrame.map { $0.minY >= visible.minY + max(0, height) - 0.5 } ?? false
            let success = moveResult == .success && (size == current.size || resizeResult == .success) && verified
            if !success {
                self.reportError("Office 暂时无法调整这个窗口的位置或大小。")
                self.reportGeometryDiagnostic("write-or-verification-failed", status: resizeResult.rawValue, detail: moveResult.rawValue)
            } else {
                self.reportGeometryDiagnostic("reserved")
            }
            finish(success, verifiedFrame, verifiedAt)
        }
    }

    private static func isSafeToAdjust(processID: pid_t) -> Bool {
        let check = { NSEvent.pressedMouseButtons & 1 == 0 && NSWorkspace.shared.frontmostApplication?.processIdentifier == processID }
        return Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
    }

    private func isSafeToAdjust(document: OfficeDocument) -> Bool {
        let check = { self.started && Self.isSafeToAdjust(processID: document.processID) }
        let safe = Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
        guard safe else { reportGeometryDiagnostic("mouse-or-foreground"); return false }
        // Word 自己缩放时也可能重复发送焦点通知；实际窗口身份比通知版本更可靠。
        let application = AXUIElementCreateApplication(document.processID)
        AXUIElementSetMessagingTimeout(application, 0.12)
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused)
        guard result == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(focused, document.element) else {
            reportGeometryDiagnostic("focus-changed-or-unreadable", status: result.rawValue)
            return false
        }
        return true
    }

    private func canReserveSpace(on window: AXUIElement) -> Bool {
        var rawFullScreen: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &rawFullScreen)
        if result == .success {
            guard let isFullScreen = (rawFullScreen as? NSNumber)?.boolValue else {
                reportGeometryDiagnostic("fullscreen-invalid-value", status: result.rawValue)
                return false
            }
            if isFullScreen { reportGeometryDiagnostic("fullscreen"); return false }
            return true
        }
        guard result == .attributeUnsupported || result == .noValue else {
            reportGeometryDiagnostic("fullscreen-unreadable", status: result.rawValue)
            return false
        }
        // 部分 Office 窗口没有 AXFullScreen；只允许系统明确支持移动和缩放的普通窗口。
        // 填充屏幕也属于普通窗口，不能用几何尺寸把它误判为 macOS 原生全屏。
        var canMove: DarwinBoolean = false
        var canResize: DarwinBoolean = false
        let moveResult = AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &canMove)
        let resizeResult = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &canResize)
        guard moveResult == .success, resizeResult == .success, canMove.boolValue, canResize.boolValue else {
            reportGeometryDiagnostic("geometry-not-settable", status: moveResult.rawValue, detail: resizeResult.rawValue)
            return false
        }
        reportGeometryDiagnostic("fullscreen-capability-fallback", status: result.rawValue)
        return true
    }

    private func reportGeometryDiagnostic(_ reason: String, status: Int32 = 0, detail: Int32 = 0) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let signature = "\(reason):\(status):\(detail)"
            guard self.lastReservationDiagnostic != signature else { return }
            self.lastReservationDiagnostic = signature
            self.geometryLogger.notice("reserve: \(reason, privacy: .public), AX: \(status), detail: \(detail)")
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
                let isFullScreen = (Self.value(window, "AXFullScreen" as CFString) as? NSNumber)?.boolValue
                    ?? oldIdentity.flatMap { oldDocuments[$0.id]?.isFullScreen } ?? false
                let geometryTimestamp = ProcessInfo.processInfo.systemUptime
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
                                              isFullScreen: isFullScreen, frame: frame,
                                              geometryTimestamp: geometryTimestamp, element: window)
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
            let result = AXObserverCreate(pid, { _, _, notification, context in
                guard let context = context else { return }
                let monitor = Unmanaged<OfficeWindowMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.handleNotification(notification)
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
        var rawValues: CFArray?
        // 位置与大小合并为一次跨进程请求，拖动时不做标题、路径或子节点遍历。
        let attributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, .stopOnError, &rawValues) == .success,
              let values = rawValues as? [CFTypeRef], values.count == 2 else { return nil }
        let rawPosition = values[0]
        let rawSize = values[1]
        guard
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
