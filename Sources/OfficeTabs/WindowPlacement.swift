import Foundation
import CoreGraphics

/// 只负责几何约束；坐标已经由辅助功能的左上原点转换为 AppKit 的左下原点。
enum WindowPlacement {
    static let height: CGFloat = 44
    static let gap: CGFloat = 5
    static let reservedHeight: CGFloat = height + gap

    enum Result: Equatable {
        case above(CGRect)
        case needsSpace
        case unavailable
    }

    static func attached(to document: CGRect, visible: CGRect, isFullScreen: Bool) -> Result {
        guard !isFullScreen, valid(document), valid(visible),
              document.width > 100, document.height > 100,
              document.maxX > visible.minX, document.minX < visible.maxX else { return .unavailable }
        let width = min(max(380, document.width), visible.width)
        let x = min(max(document.minX, visible.minX), visible.maxX - width)
        let y = document.maxY + gap
        let frame = CGRect(x: x, y: y, width: width, height: height)
        // 空间不足时交给异步预留流程，绝不把标签栏向下裁剪进 Office 标题栏。
        guard frame.minY >= visible.minY, frame.maxY <= visible.maxY + 0.01 else { return .needsSpace }
        return .above(frame)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.width > 0 && rect.height > 0 &&
            [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
    }
}
