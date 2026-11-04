import ApplicationServices
import CoreGraphics
import Foundation

/// 在低频 AX 扫描中确认标题工具栏的空白区域，拖动命中测试只使用这些相对坐标。
enum TitlebarDragRegions {
    static func capture(window: AXUIElement, frame windowFrame: CGRect) -> [CGRect] {
        guard valid(windowFrame), windowFrame.width > 100, windowFrame.height > 100,
              let children = children(of: window) else { return [] }

        let toolbars = children.compactMap { child -> (AXUIElement, CGRect)? in
            guard string(child, kAXRoleAttribute as CFString) == kAXToolbarRole as String,
                  let rect = frame(of: child), abs(rect.minY - windowFrame.minY) <= 6,
                  rect.height > 8, rect.height <= 80 else { return nil }
            return (child, rect)
        }
        guard let toolbar = toolbars.min(by: { $0.1.height < $1.1.height }) else { return [] }
        let bottom = windowFrame.minY + min(38, toolbar.1.height - 2)
        let left = max(windowFrame.minX + 12, toolbar.1.minX)
        let right = min(windowFrame.maxX - 12, toolbar.1.maxX)
        let strip = CGRect(x: left, y: windowFrame.minY + 6, width: right - left,
                           height: bottom - windowFrame.minY - 6)
        guard valid(strip), strip.height > 0, strip.width > 0 else { return [] }

        var exclusions: [CGRect] = []
        var remainingNodes = 128
        guard inspect(toolbar.0, strip: strip, depth: 0, remainingNodes: &remainingNodes,
                      exclusions: &exclusions) else { return [] }

        // 标准窗口按钮和文件代理可能是窗口的直接属性，不一定属于工具栏子树。
        let chromeAttributes: [CFString] = [kAXCloseButtonAttribute as CFString,
                                           kAXMinimizeButtonAttribute as CFString,
                                           kAXZoomButtonAttribute as CFString,
                                           kAXFullScreenButtonAttribute as CFString,
                                           kAXToolbarButtonAttribute as CFString,
                                           kAXTitleUIElementAttribute as CFString,
                                           kAXProxyAttribute as CFString]
        for attribute in chromeAttributes {
            var raw: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(window, attribute, &raw)
            if result == .attributeUnsupported || result == .noValue { continue }
            guard result == .success else { return [] }
            guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }
            let control = raw as! AXUIElement
            if hidden(control) { continue }
            guard let rect = frame(of: control) else { return [] }
            if rect.intersects(strip) { exclusions.append(rect.insetBy(dx: -3, dy: -3)) }
        }

        var spans: [(CGFloat, CGFloat)] = [(strip.minX, strip.maxX)]
        for rect in exclusions where rect.intersects(strip) {
            spans = spans.flatMap { start, end -> [(CGFloat, CGFloat)] in
                guard rect.maxX > start, rect.minX < end else { return [(start, end)] }
                var pieces: [(CGFloat, CGFloat)] = []
                if rect.minX > start { pieces.append((start, min(end, rect.minX))) }
                if rect.maxX < end { pieces.append((max(start, rect.maxX), end)) }
                return pieces
            }
        }
        return spans.compactMap { start, end in
            guard end - start >= 6 else { return nil }
            return CGRect(x: start - windowFrame.minX, y: strip.minY - windowFrame.minY,
                          width: end - start, height: strip.height)
        }
    }

    static func contains(cursor: CGPoint, windowFrame: CGRect, regions: [CGRect]) -> Bool {
        guard cursor.x.isFinite, cursor.y.isFinite, valid(windowFrame),
              windowFrame.width > 100, windowFrame.height > 100 else { return false }
        let local = CGPoint(x: cursor.x - windowFrame.minX, y: cursor.y - windowFrame.minY)
        guard local.x >= 12, local.x <= windowFrame.width - 12,
              local.y >= 6, local.y <= 38 else { return false }
        return regions.contains { valid($0) && $0.contains(local) }
    }

    private static let controls: Set<String> = [
        "AXButton", "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXRadioButton",
        "AXTextField", "AXTextArea", "AXComboBox", "AXLink", "AXStaticText", "AXImage",
        "AXSwitch", "AXSlider", "AXDisclosureTriangle", "AXMenuItem", "AXTab"
    ]

    private static func inspect(_ element: AXUIElement, strip: CGRect, depth: Int,
                                remainingNodes: inout Int, exclusions: inout [CGRect]) -> Bool {
        guard remainingNodes > 0 else { return false }
        remainingNodes -= 1
        if hidden(element) { return true }
        guard let role = string(element, kAXRoleAttribute as CFString) else { return false }
        let rect = frame(of: element)
        if let rect, !rect.intersects(strip) { return true }
        if controls.contains(role) {
            // 控件边界未知时不能把它的位置当作空白；只放弃即时跟随，普通校准仍可使用。
            guard let rect else { return false }
            exclusions.append(rect.insetBy(dx: -3, dy: -3))
            return true
        }
        guard let nested = children(of: element) else { return false }
        guard !nested.isEmpty else { return true }
        guard depth < 4 else { return false }
        for child in nested {
            guard inspect(child, strip: strip, depth: depth + 1, remainingNodes: &remainingNodes,
                          exclusions: &exclusions) else { return false }
        }
        return true
    }

    private static func value(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &result) == .success else { return nil }
        return result
    }

    private static func string(_ element: AXUIElement, _ attribute: CFString) -> String? {
        value(element, attribute) as? String
    }

    private static func hidden(_ element: AXUIElement) -> Bool {
        (value(element, kAXHiddenAttribute as CFString) as? NSNumber)?.boolValue ?? false
    }

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        var raw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
        if result == .attributeUnsupported || result == .noValue { return [] }
        guard result == .success else { return nil }
        return raw as? [AXUIElement]
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, [kAXPositionAttribute, kAXSizeAttribute] as CFArray,
                                                    .stopOnError, &raw) == .success,
              let values = raw as? [CFTypeRef], values.count == 2,
              CFGetTypeID(values[0]) == AXValueGetTypeID(), CFGetTypeID(values[1]) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(values[0] as! AXValue, .cgPoint, &origin),
              AXValueGetValue(values[1] as! AXValue, .cgSize, &size) else { return nil }
        let rect = CGRect(origin: origin, size: size)
        return valid(rect) ? rect : nil
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.width > 0 && rect.height > 0 &&
            [rect.minX, rect.minY, rect.maxX, rect.maxY, rect.width, rect.height].allSatisfy(\.isFinite)
    }
}
