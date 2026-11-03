import AppKit

/// 整条标签栏沿用前台 Office 应用的主题色，当前文档通过独立的明度与文字色突出。
private struct TabBarPalette {
    let outer: NSColor
    let border: NSColor
    let inactive: NSColor
    let hover: NSColor
    let active: NSColor
    let activeBorder: NSColor
    let text: NSColor
    let secondary: NSColor
    let activeText: NSColor
    let activeSecondary: NSColor

    static func resolve(_ appearance: NSAppearance, app: OfficeApp? = nil) -> TabBarPalette {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard let app else {
            if dark {
                return TabBarPalette(outer: color(0x23272F), border: color(0x4D586A),
                                     inactive: color(0x2C323D), hover: color(0x363F4D),
                                     active: color(0x414B5B), activeBorder: color(0x4D586A),
                                     text: color(0xF3F5F7), secondary: color(0xB5BFCD),
                                     activeText: color(0xF3F5F7), activeSecondary: color(0xB5BFCD))
            }
            return TabBarPalette(outer: color(0xECEEF1), border: color(0xD8DDE5),
                                 inactive: color(0xE2E5EA), hover: color(0xD9DFE8),
                                 active: color(0xFFFFFF), activeBorder: color(0xD6DCE6),
                                 text: color(0x252B36), secondary: color(0x657080),
                                 activeText: color(0x252B36), activeSecondary: color(0x657080))
        }
        let base: NSColor
        let deep: NSColor
        let title: NSColor
        switch app {
        case .word:
            base = color(0x185ABD); deep = color(0x123C7C); title = color(0x103D85)
        case .excel:
            base = color(0x107C41); deep = color(0x0D4C2B); title = color(0x0B5B2F)
        case .powerpoint:
            base = color(0xB7472A); deep = color(0x6C2D20); title = color(0x8F321D)
        }
        let outer = dark ? deep : base
        return TabBarPalette(outer: outer,
                             border: NSColor.white.withAlphaComponent(dark ? 0.18 : 0.22),
                             inactive: mix(outer, with: .white, fraction: 0.12),
                             hover: mix(outer, with: .white, fraction: 0.22),
                             active: dark ? mix(outer, with: .white, fraction: 0.24) : color(0xF8FAFF),
                             activeBorder: NSColor.white.withAlphaComponent(dark ? 0.22 : 0.75),
                             text: NSColor.white.withAlphaComponent(0.94),
                             secondary: NSColor.white.withAlphaComponent(0.82),
                             activeText: dark ? color(0xF3F5F7) : title,
                             activeSecondary: dark ? NSColor.white.withAlphaComponent(0.82) : title.withAlphaComponent(0.72))
    }

    private static func mix(_ base: NSColor, with other: NSColor, fraction: CGFloat) -> NSColor {
        base.blended(withFraction: fraction, of: other) ?? base
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// 轻量的原生标签栏；所有操作都交给窗口控制层，视图只维护展示顺序。
final class TabBarView: NSView {
    static let preferredHeight: CGFloat = 44
    static let minimumWidth: CGFloat = 380

    private(set) var documents: [OfficeDocument] = []
    private(set) var activeDocumentID: String?
    private(set) var filter: OfficeApp?
    private var themeApp: OfficeApp?
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onReorder: (([String]) -> Void)?
    var onFilter: ((OfficeApp?) -> Void)?
    var onSettings: (() -> Void)?
    var onOpen: (() -> Void)?

    private let filterButton = BarActionButton()
    private let openButton = BarActionButton()
    private let listButton = BarActionButton()
    private let settingsButton = BarActionButton()
    private let scrollView = HorizontalTabScrollView()
    private let canvas = TabCanvasView()
    private let emptyLabel = NSTextField(labelWithString: "等待打开 Office 文档")
    private var tabViews: [DocumentTabView] = []
    private var displaySignature = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Office 文档标签栏")

        scrollView.documentView = canvas
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.contentView.drawsBackground = false
        addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = TabBarPalette.resolve(effectiveAppearance).secondary
        emptyLabel.lineBreakMode = .byTruncatingTail
        canvas.addSubview(emptyLabel)

        configure(filterButton, symbol: "square.stack.3d.up", help: "选择要显示的 Office 应用") { [weak self] in
            self?.showFilterMenu()
        }
        filterButton.imagePosition = .imageLeading
        filterButton.font = .systemFont(ofSize: 11, weight: .semibold)
        configure(openButton, symbol: "plus", help: "打开 Office 文档") { [weak self] in self?.onOpen?() }
        configure(listButton, symbol: "chevron.down", help: "查看文档列表") { [weak self] in self?.showDocumentMenu() }
        configure(settingsButton, symbol: "ellipsis", help: "标签栏设置") { [weak self] in self?.onSettings?() }
        for control in [filterButton, openButton, listButton, settingsButton] { addSubview(control) }
        updateAppearance()
        update(documents: [], activeID: nil, filter: nil)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let palette = TabBarPalette.resolve(effectiveAppearance, app: themeApp)
        layer?.backgroundColor = palette.outer.cgColor
        layer?.borderColor = palette.border.cgColor
        layer?.borderWidth = 0.5
        emptyLabel.textColor = palette.secondary
        for button in [filterButton, openButton, listButton, settingsButton] {
            button.themeApp = themeApp
            button.refreshAppearance()
        }
        needsDisplay = true
    }

    private func configure(_ button: BarActionButton, symbol: String, help: String, action: @escaping () -> Void) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.imagePosition = .imageOnly
        button.refreshAppearance()
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.perform = action
    }

    func update(documents: [OfficeDocument], activeID: String?, filter: OfficeApp?, themeApp: OfficeApp? = nil) {
        let activeChanged = activeDocumentID != activeID
        let filterChanged = self.filter != filter
        let selectedTheme = themeApp ?? documents.first(where: { $0.id == activeID })?.app ?? filter ?? .word
        let themeChanged = self.themeApp != selectedTheme
        self.documents = documents
        self.activeDocumentID = activeID
        self.filter = filter
        self.themeApp = selectedTheme
        filterButton.title = filter?.name ?? "全部"
        filterButton.image = NSImage(systemSymbolName: filter == nil ? "square.stack.3d.up" : "doc.text", accessibilityDescription: nil)
        filterButton.tintOverride = nil
        filterButton.refreshAppearance()
        if themeChanged { updateAppearance() }

        // AX 的轮询结果会持续到达；仅在可见信息变化时重建控件，避免滚动和悬停不断归零。
        let signature = documents.map { "\($0.id)|\($0.title)|\($0.isEdited)|\($0.isMinimized)|\($0.fileURL?.absoluteString ?? "")" }.joined(separator: "\n")
            + "#\(activeID ?? "")#\(filter?.bundleID ?? "all")#\(selectedTheme.bundleID)"
        guard signature != displaySignature else { return }
        displaySignature = signature
        let priorOffset = scrollView.contentView.bounds.origin.x
        tabViews.forEach { $0.removeFromSuperview() }
        tabViews = []
        let visible = visibleDocuments
        for document in visible {
            let tab = DocumentTabView(document: document, active: document.id == activeID, themeApp: selectedTheme)
            tab.onSelect = { [weak self] in self?.onSelect?(document.id) }
            tab.onClose = { [weak self] in self?.onClose?(document.id) }
            tab.onDragEnd = { [weak self] point in self?.reorder(document.id, at: point) }
            tab.onContextMenu = { [weak self] event in self?.showContextMenu(for: document, event: event) }
            canvas.addSubview(tab)
            tabViews.append(tab)
        }
        emptyLabel.isHidden = !visible.isEmpty
        listButton.isEnabled = !visible.isEmpty
        needsLayout = true
        layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: max(0, min(priorOffset, canvas.bounds.width - scrollView.contentSize.width)), y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if activeChanged || filterChanged, let tab = tabViews.first(where: { $0.document.id == activeID }) {
            canvas.scrollToVisible(tab.frame.insetBy(dx: -8, dy: 0))
        }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        filterButton.frame = NSRect(x: 8, y: 6, width: 88, height: h - 12)
        let rightWidth: CGFloat = 92
        scrollView.frame = NSRect(x: 102, y: 4, width: max(90, bounds.width - 102 - rightWidth), height: h - 8)
        openButton.frame = NSRect(x: bounds.width - 88, y: 7, width: 26, height: h - 14)
        listButton.frame = NSRect(x: bounds.width - 60, y: 7, width: 24, height: h - 14)
        settingsButton.frame = NSRect(x: bounds.width - 34, y: 7, width: 26, height: h - 14)

        let widths = tabViews.map { view -> CGFloat in
            let textWidth = (view.document.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
            return min(242, max(132, textWidth + 66))
        }
        let total = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * 4
        canvas.frame = NSRect(x: 0, y: 0, width: max(scrollView.contentSize.width, total), height: scrollView.contentSize.height)
        var x: CGFloat = 0
        for (index, tab) in tabViews.enumerated() {
            tab.frame = NSRect(x: x, y: 0, width: widths[index], height: canvas.bounds.height)
            x += widths[index] + 4
        }
        emptyLabel.frame = NSRect(x: 8, y: max(0, (canvas.bounds.height - 17) / 2), width: max(0, scrollView.contentSize.width - 16), height: 17)
    }

    private var visibleDocuments: [OfficeDocument] {
        documents.filter { filter == nil || $0.app == filter }
    }

    private func showFilterMenu() {
        let menu = NSMenu()
        let all = NSMenuItem(title: "全部 Office 文档", action: #selector(pickFilter(_:)), keyEquivalent: "")
        all.target = self
        all.state = filter == nil ? .on : .off
        menu.addItem(all)
        menu.addItem(.separator())
        for app in [OfficeApp.word, .excel, .powerpoint] {
            let count = documents.filter { $0.app == app }.count
            let item = NSMenuItem(title: "\(app.name)  ·  \(count)", action: #selector(pickFilter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app.bundleID
            item.state = filter == app ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: filterButton.frame.minX, y: bounds.maxY), in: self)
    }

    @objc private func pickFilter(_ item: NSMenuItem) {
        let bundleID = item.representedObject as? String
        onFilter?([OfficeApp.word, .excel, .powerpoint].first { $0.bundleID == bundleID })
    }

    private func showDocumentMenu() {
        let menu = NSMenu()
        for document in visibleDocuments {
            let item = NSMenuItem(title: "\(document.app.letter)  \(document.title)\(document.isEdited ? "  •" : "")", action: #selector(pickDocument(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = document.id
            item.state = document.id == activeDocumentID ? .on : .off
            item.toolTip = document.fileURL?.path
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: listButton.frame.minX, y: bounds.maxY), in: self)
    }

    @objc private func pickDocument(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        onSelect?(id)
    }

    private func showContextMenu(for document: OfficeDocument, event: NSEvent) {
        let menu = NSMenu()
        let select = NSMenuItem(title: "切换到此文档", action: #selector(pickDocument(_:)), keyEquivalent: "")
        select.target = self
        select.representedObject = document.id
        menu.addItem(select)
        if let url = document.fileURL, url.isFileURL {
            let reveal = NSMenuItem(title: "在访达中显示", action: #selector(revealDocument(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = url
            menu.addItem(reveal)
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: "关闭文档…", action: #selector(closeDocument(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = document.id
        menu.addItem(close)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func revealDocument(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func closeDocument(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        onClose?(id)
    }

    private func reorder(_ id: String, at windowPoint: NSPoint) {
        let point = canvas.convert(windowPoint, from: nil)
        let visibleTargets = tabViews.filter { $0.document.id != id }
        guard let before = visibleTargets.first(where: { point.x < $0.frame.midX })?.document.id ?? visibleTargets.last?.document.id else { return }
        var reordered = documents.map(\.id).filter { $0 != id }
        guard let targetIndex = reordered.firstIndex(of: before) else { return }
        let afterLast = visibleTargets.last.map { point.x >= $0.frame.midX } ?? false
        reordered.insert(id, at: afterLast ? targetIndex + 1 : targetIndex)
        onReorder?(reordered)
    }
}

/// 保持滚轮只改变标签的水平位置，触控板和普通鼠标都可以访问溢出的文档。
private final class HorizontalTabScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        guard let documentView, documentView.bounds.width > contentSize.width else { return }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 14
        let next = min(max(0, contentView.bounds.origin.x - delta * scale), max(0, documentView.bounds.width - contentSize.width))
        contentView.scroll(to: NSPoint(x: next, y: 0))
        reflectScrolledClipView(contentView)
    }
}

private final class TabCanvasView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
}

private final class BarActionButton: NSButton {
    var perform: (() -> Void)?
    var tintOverride: NSColor?
    var themeApp: OfficeApp?
    var onActiveTab = false
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 图标按钮从空标题开始，只有应用筛选按钮会显式设置可见文字。
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        target = self
        action = #selector(invoke)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { false }

    @objc private func invoke() { perform?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    func refreshAppearance() {
        let palette = TabBarPalette.resolve(effectiveAppearance, app: themeApp)
        contentTintColor = tintOverride ?? (onActiveTab ? palette.activeSecondary : palette.secondary)
        let position = imagePosition
        if !title.isEmpty {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 11), .foregroundColor: onActiveTab ? palette.activeText : palette.text
            ])
        }
        // 富文本标题可能触发系统重新安排图文位置，外观更新后保持原来的按钮布局。
        imagePosition = position
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if hovering && isEnabled {
            let palette = TabBarPalette.resolve(effectiveAppearance, app: themeApp)
            (onActiveTab ? palette.activeText.withAlphaComponent(0.08) : palette.hover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

private final class DocumentTabView: NSView {
    let document: OfficeDocument
    let active: Bool
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onDragEnd: ((NSPoint) -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    private let selectButton = DocumentSelectButton()
    private let closeButton = BarActionButton()
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    init(document: OfficeDocument, active: Bool, themeApp: OfficeApp?) {
        self.document = document
        self.active = active
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = document.fileURL?.path ?? document.title
        selectButton.document = document
        selectButton.themeApp = themeApp
        selectButton.active = active
        selectButton.state = active ? .on : .off
        selectButton.title = document.title
        selectButton.setAccessibilityLabel("切换到 \(document.title)\(document.isEdited ? "，有未保存的更改" : "")")
        selectButton.toolTip = toolTip
        selectButton.onSelect = { [weak self] in self?.onSelect?() }
        selectButton.onDragEnd = { [weak self] point in self?.onDragEnd?(point) }
        selectButton.onContextMenu = { [weak self] event in self?.onContextMenu?(event) }
        addSubview(selectButton)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭文档")
        closeButton.imagePosition = .imageOnly
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        closeButton.themeApp = themeApp
        closeButton.onActiveTab = active
        closeButton.refreshAppearance()
        closeButton.setAccessibilityLabel("关闭 \(document.title)")
        closeButton.toolTip = "关闭文档；未保存的内容由 Office 提示保存"
        closeButton.perform = { [weak self] in self?.onClose?() }
        addSubview(closeButton)
        closeButton.isHidden = !active
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        selectButton.frame = bounds
        closeButton.frame = NSRect(x: bounds.width - 25, y: (bounds.height - 22) / 2, width: 22, height: 22)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateHover() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateHover() }
    private func updateHover() {
        closeButton.isHidden = !(hovering || active)
        selectButton.hovering = hovering
        selectButton.needsDisplay = true
    }
}

/// 保留原生按钮的辅助功能语义，同时把小范围鼠标移动与真正的拖拽分开。
private final class DocumentSelectButton: NSButton {
    var document: OfficeDocument?
    var themeApp: OfficeApp?
    var active = false
    var hovering = false
    var onSelect: (() -> Void)?
    var onDragEnd: ((NSPoint) -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        // 使用原生切换按钮状态，让辅助功能同时读到当前文档的选中状态。
        setButtonType(.toggle)
        focusRingType = .none
        target = self
        action = #selector(invoke)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    @objc private func invoke() { onSelect?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let document else { return }
        let palette = TabBarPalette.resolve(effectiveAppearance, app: themeApp)
        let tabRect = bounds.insetBy(dx: 0.5, dy: 1)
        let tabPath = NSBezierPath(roundedRect: tabRect, xRadius: 8, yRadius: 8)
        (active ? palette.active : (hovering ? palette.hover : palette.inactive)).setFill()
        tabPath.fill()
        if active {
            palette.activeBorder.setStroke()
            tabPath.lineWidth = 0.5
            tabPath.stroke()
            // 细色线与白色填充共同标示当前文档，保持文档标题的视觉优先级。
            document.app.tint.setFill()
            let indicator = NSRect(x: tabRect.minX + 10, y: tabRect.maxY - 1.75,
                                   width: max(0, tabRect.width - 20), height: 1.5)
            NSBezierPath(roundedRect: indicator, xRadius: 0.75, yRadius: 0.75).fill()
        }
        let icon = NSRect(x: 10, y: (bounds.height - 20) / 2, width: 20, height: 20)
        document.app.tint.setFill()
        NSBezierPath(roundedRect: icon, xRadius: 4, yRadius: 4).fill()
        let letterStyle: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white]
        let letterSize = (document.app.letter as NSString).size(withAttributes: letterStyle)
        (document.app.letter as NSString).draw(at: NSPoint(x: icon.midX - letterSize.width / 2, y: icon.midY - letterSize.height / 2), withAttributes: letterStyle)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let style: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: active ? .medium : .regular),
            .foregroundColor: active ? (document.isMinimized ? palette.activeSecondary : palette.activeText) : (document.isMinimized ? palette.secondary : palette.text),
            .paragraphStyle: paragraph
        ]
        let label = document.title.isEmpty ? "未命名文档" : document.title
        let textHeight = (label as NSString).size(withAttributes: style).height
        (label as NSString).draw(in: NSRect(x: 37, y: (bounds.height - textHeight) / 2, width: max(0, bounds.width - 69), height: textHeight + 1), withAttributes: style)
        if document.isEdited {
            (active ? palette.activeSecondary : palette.secondary).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width - 31, y: bounds.midY - 2, width: 4, height: 4)).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onContextMenu?(event); return }
        guard let window else { return }
        let start = event.locationInWindow
        var dragged = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let distance = hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y)
            if distance > 6 { dragged = true }
            if next.type == .leftMouseUp {
                if dragged {
                    onDragEnd?(next.locationInWindow)
                } else if bounds.contains(convert(next.locationInWindow, from: nil)) {
                    onSelect?()
                }
                break
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }
}
