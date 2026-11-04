import Foundation
import CoreGraphics

/// 仅在标题栏平移得到确认后，用手势起点和当前鼠标位置计算显示帧。
/// WindowServer 的异步读数用于校验，不作为每帧绘制的等待条件。
struct CursorDragModel {
    private let anchorFrame: CGRect
    private let anchorCursor: CGPoint
    private let allowsImmediateTracking: Bool
    private(set) var isConfirmed = false
    private(set) var isValid = true

    init?(frame: CGRect, cursor: CGPoint, allowsImmediateTracking: Bool = false) {
        guard Self.valid(frame), Self.valid(cursor),
              cursor.x >= frame.minX + 12, cursor.x <= frame.maxX - 12,
              cursor.y >= frame.minY + 6, cursor.y <= frame.minY + 38 else { return nil }
        anchorFrame = frame
        anchorCursor = cursor
        self.allowsImmediateTracking = allowsImmediateTracking
    }

    mutating func advance(cursor: CGPoint) {
        guard isValid else { return }
        guard Self.valid(cursor) else { invalidate(); return }
        // 只有预先排除按钮等交互控件的标题栏空白区，才允许鼠标跨过拖动阈值后立即跟随。
        guard allowsImmediateTracking else { return }
        if hypot(cursor.x - anchorCursor.x, cursor.y - anchorCursor.y) >= 4 { isConfirmed = true }
    }

    mutating func observe(frame: CGRect, requestCursor: CGPoint, currentCursor: CGPoint) {
        guard isValid else { return }
        guard Self.valid(requestCursor), Self.valid(currentCursor) else {
            invalidate()
            return
        }
        let range = CGRect(x: min(requestCursor.x, currentCursor.x), y: min(requestCursor.y, currentCursor.y),
                           width: abs(currentCursor.x - requestCursor.x), height: abs(currentCursor.y - requestCursor.y))
        observe(frame: frame, cursorRange: range)
    }

    mutating func observe(frame: CGRect, cursorRange: CGRect) {
        guard isValid else { return }
        guard Self.valid(frame), Self.validCursorRange(cursorRange),
              abs(frame.width - anchorFrame.width) <= 1,
              abs(frame.height - anchorFrame.height) <= 1 else {
            invalidate()
            return
        }

        let firstFrame = translated(to: CGPoint(x: cursorRange.minX, y: cursorRange.minY))
        let lastFrame = translated(to: CGPoint(x: cursorRange.maxX, y: cursorRange.maxY))
        guard Self.valid(firstFrame), Self.valid(lastFrame) else {
            invalidate()
            return
        }
        // 查询期间鼠标可能移动后又返回；使用整段轨迹范围，不能只用两个端点误判中途样本。
        let tolerance: CGFloat = 24
        let xRange = (firstFrame.minX - tolerance)...(lastFrame.minX + tolerance)
        let yRange = (firstFrame.minY - tolerance)...(lastFrame.minY + tolerance)
        guard xRange.contains(frame.minX), yRange.contains(frame.minY) else {
            invalidate()
            return
        }

        let movedWindow = hypot(frame.minX - anchorFrame.minX, frame.minY - anchorFrame.minY) > 2
        let cursorDX = max(abs(cursorRange.minX - anchorCursor.x), abs(cursorRange.maxX - anchorCursor.x))
        let cursorDY = max(abs(cursorRange.minY - anchorCursor.y), abs(cursorRange.maxY - anchorCursor.y))
        let movedCursor = hypot(cursorDX, cursorDY) > 2
        if movedWindow && movedCursor { isConfirmed = true }
    }

    func predictedFrame(cursor: CGPoint) -> CGRect? {
        guard isValid, isConfirmed, Self.valid(cursor) else { return nil }
        // 始终保留手势起点；把延迟返回的系统位置重新设为锚点会再次引入顿挫。
        let frame = translated(to: cursor)
        return Self.valid(frame) ? frame : nil
    }

    private func translated(to cursor: CGPoint) -> CGRect {
        anchorFrame.offsetBy(dx: cursor.x - anchorCursor.x, dy: cursor.y - anchorCursor.y)
    }

    private mutating func invalidate() {
        isValid = false
        isConfirmed = false
    }

    private static func valid(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func validCursorRange(_ range: CGRect) -> Bool {
        !range.isNull && !range.isInfinite && range.size.width >= 0 && range.size.height >= 0 &&
            [range.origin.x, range.origin.y, range.size.width, range.size.height,
             range.minX, range.minY, range.maxX, range.maxY].allSatisfy(\.isFinite)
    }

    private static func valid(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.width > 100 && frame.height > 100 &&
            [frame.minX, frame.minY, frame.maxX, frame.maxY, frame.width, frame.height].allSatisfy(\.isFinite)
    }
}
