import Foundation
import CoreGraphics

@main
struct CursorDragModelTests {
    private let frame = CGRect(x: 200, y: 180, width: 1000, height: 700)
    private let cursor = CGPoint(x: 600, y: 200)

    static func main() {
        let suite = CursorDragModelTests()
        let cases: [(String, () throws -> Void)] = [
            ("titlebarStartsUnconfirmedModel", suite.titlebarStartsUnconfirmedModel),
            ("bodySelectionsNeverStartPrediction", suite.bodySelectionsNeverStartPrediction),
            ("resizeEdgesDoNotStartPrediction", suite.resizeEdgesDoNotStartPrediction),
            ("noMovementDoesNotConfirm", suite.noMovementDoesNotConfirm),
            ("cursorMovementAloneDoesNotConfirm", suite.cursorMovementAloneDoesNotConfirm),
            ("tinyRoundingJitterDoesNotConfirm", suite.tinyRoundingJitterDoesNotConfirm),
            ("trustedTitlebarPaintsBeforeAnyWindowSample", suite.trustedTitlebarPaintsBeforeAnyWindowSample),
            ("untrustedCursorAdvancesRemainUnconfirmed", suite.untrustedCursorAdvancesRemainUnconfirmed),
            ("trustedTrackingPreservesRegionAndInvalidationGuards", suite.trustedTrackingPreservesRegionAndInvalidationGuards),
            ("actualTranslationEnablesPrediction", suite.actualTranslationEnablesPrediction),
            ("displayFramesContinueWithoutNewWindowSamples", suite.displayFramesContinueWithoutNewWindowSamples),
            ("lateValidationDoesNotRollBackPrediction", suite.lateValidationDoesNotRollBackPrediction),
            ("outAndBackCorridorKeepsOriginalAnchor", suite.outAndBackCorridorKeepsOriginalAnchor),
            ("invalidCursorCorridorPermanentlyInvalidatesPrediction", suite.invalidCursorCorridorPermanentlyInvalidatesPrediction),
            ("resizePermanentlyInvalidatesPrediction", suite.resizePermanentlyInvalidatesPrediction),
            ("incompatibleWindowTranslationInvalidatesPrediction", suite.incompatibleWindowTranslationInvalidatesPrediction),
            ("negativeCoordinatesPreserveCursorDelta", suite.negativeCoordinatesPreserveCursorDelta),
            ("invalidGeometryAndCursorAreRejected", suite.invalidGeometryAndCursorAreRejected)
        ]
        var failures: [String] = []
        for (name, test) in cases {
            do {
                try test()
                print("PASS \(name)")
            } catch {
                failures.append("FAIL \(name): \(error)")
            }
        }
        guard failures.isEmpty else {
            FileHandle.standardError.write(Data((failures.joined(separator: "\n") + "\n").utf8))
            exit(1)
        }
        print("\(cases.count) cursor drag prediction regression tests passed.")
    }

    private func makeModel(frame rect: CGRect? = nil, cursor point: CGPoint? = nil,
                           allowsImmediateTracking: Bool = false) throws -> CursorDragModel {
        guard let model = CursorDragModel(frame: rect ?? frame, cursor: point ?? cursor,
                                          allowsImmediateTracking: allowsImmediateTracking) else {
            throw RegressionFailure(description: "Valid titlebar fixture was rejected")
        }
        return model
    }

    private func confirmedModel() throws -> CursorDragModel {
        var model = try makeModel()
        model.observe(frame: frame.offsetBy(dx: 20, dy: 10),
                      requestCursor: cursor.offsetBy(dx: 16, dy: 8),
                      currentCursor: cursor.offsetBy(dx: 24, dy: 12))
        try require(model.isValid && model.isConfirmed)
        return model
    }

    func titlebarStartsUnconfirmedModel() throws {
        let model = try makeModel()
        try require(model.isValid && !model.isConfirmed)
        try expectFrame(model.predictedFrame(cursor: cursor.offsetBy(dx: 50, dy: 30)), nil)
    }

    func bodySelectionsNeverStartPrediction() throws {
        for x: CGFloat in [frame.minX + 30, frame.midX, frame.maxX - 30] {
            for y: CGFloat in [frame.minY + 45, frame.midY, frame.maxY - 20] {
                // 正文里的选择和拖拽不能把标签栏当作窗口标题栏来预测移动。
                try require(CursorDragModel(frame: frame, cursor: CGPoint(x: x, y: y)) == nil)
            }
        }
    }

    func resizeEdgesDoNotStartPrediction() throws {
        let edges = [CGPoint(x: frame.minX + 4, y: frame.minY + 20),
                     CGPoint(x: frame.maxX - 4, y: frame.minY + 20),
                     CGPoint(x: frame.midX, y: frame.minY + 2)]
        for point in edges { try require(CursorDragModel(frame: frame, cursor: point) == nil) }
    }

    func noMovementDoesNotConfirm() throws {
        var model = try makeModel()
        model.observe(frame: frame, requestCursor: cursor, currentCursor: cursor)
        try require(model.isValid && !model.isConfirmed)
        try expectFrame(model.predictedFrame(cursor: cursor), nil)
    }

    func cursorMovementAloneDoesNotConfirm() throws {
        var model = try makeModel()
        model.observe(frame: frame, requestCursor: cursor, currentCursor: cursor.offsetBy(dx: 18, dy: 12))
        try require(model.isValid && !model.isConfirmed)
        try expectFrame(model.predictedFrame(cursor: cursor.offsetBy(dx: 40, dy: 30)), nil)
    }

    func tinyRoundingJitterDoesNotConfirm() throws {
        var model = try makeModel()
        model.observe(frame: frame.offsetBy(dx: 1, dy: -1), requestCursor: cursor, currentCursor: cursor)
        try require(model.isValid && !model.isConfirmed)
        try expectFrame(model.predictedFrame(cursor: cursor.offsetBy(dx: 20, dy: 20)), nil)
    }

    func trustedTitlebarPaintsBeforeAnyWindowSample() throws {
        var model = try makeModel(allowsImmediateTracking: true)
        model.advance(cursor: cursor.offsetBy(dx: 3, dy: 0))
        try require(model.isValid && !model.isConfirmed)
        try expectFrame(model.predictedFrame(cursor: cursor.offsetBy(dx: 3, dy: 0)), nil)
        // 已确认的标题栏空白区从阈值开始逐帧显示，整个序列不等待首次窗口查询。
        for tick in 0..<30 {
            let dx = CGFloat(4 + tick * 7)
            let dy = CGFloat(tick * 3)
            let current = cursor.offsetBy(dx: dx, dy: dy)
            model.advance(cursor: current)
            try require(model.isValid && model.isConfirmed)
            try expectFrame(model.predictedFrame(cursor: current), frame.offsetBy(dx: dx, dy: dy))
        }
    }

    func untrustedCursorAdvancesRemainUnconfirmed() throws {
        var model = try makeModel()
        for tick in 1...30 {
            let current = cursor.offsetBy(dx: CGFloat(tick * 12), dy: CGFloat(tick * 7))
            model.advance(cursor: current)
            try require(model.isValid && !model.isConfirmed)
            try expectFrame(model.predictedFrame(cursor: current), nil)
        }
    }

    func trustedTrackingPreservesRegionAndInvalidationGuards() throws {
        let excluded = [CGPoint(x: frame.midX, y: frame.midY),
                        CGPoint(x: frame.minX + 4, y: frame.minY + 20),
                        CGPoint(x: frame.maxX - 4, y: frame.minY + 20),
                        CGPoint(x: frame.midX, y: frame.minY + 2)]
        for point in excluded {
            try require(CursorDragModel(frame: frame, cursor: point, allowsImmediateTracking: true) == nil)
        }
        var model = try makeModel(allowsImmediateTracking: true)
        model.advance(cursor: cursor.offsetBy(dx: 4, dy: 0))
        try require(model.isConfirmed)
        var resized = frame.offsetBy(dx: 20, dy: 10)
        resized.size.width += 80
        model.observe(frame: resized, requestCursor: cursor.offsetBy(dx: 20, dy: 10),
                      currentCursor: cursor.offsetBy(dx: 20, dy: 10))
        for tick in 1...30 {
            let current = cursor.offsetBy(dx: CGFloat(tick * 12), dy: CGFloat(tick * 7))
            model.advance(cursor: current)
            try require(!model.isValid && !model.isConfirmed)
            try expectFrame(model.predictedFrame(cursor: current), nil)
        }
    }

    func actualTranslationEnablesPrediction() throws {
        let model = try confirmedModel()
        try expectFrame(model.predictedFrame(cursor: cursor.offsetBy(dx: 80, dy: 35)),
                        frame.offsetBy(dx: 80, dy: 35))
    }

    func displayFramesContinueWithoutNewWindowSamples() throws {
        let model = try confirmedModel()
        // 模拟 60Hz 下连续 30 帧没有新的窗口查询结果，光标轨迹仍逐帧推进。
        var previous = frame
        for tick in 1...30 {
            let dx = CGFloat(24 + tick * 7)
            let dy = CGFloat(12 + tick * 4)
            let expected = frame.offsetBy(dx: dx, dy: dy)
            try expectFrame(model.predictedFrame(cursor: cursor.offsetBy(dx: dx, dy: dy)), expected)
            try require(expected.minX > previous.minX && expected.minY > previous.minY)
            previous = expected
        }
    }

    func lateValidationDoesNotRollBackPrediction() throws {
        var model = try confirmedModel()
        let current = cursor.offsetBy(dx: 220, dy: 110)
        let expected = frame.offsetBy(dx: 220, dy: 110)
        try expectFrame(model.predictedFrame(cursor: current), expected)
        // 查询在较早的光标位置开始，旧窗口样本落在请求到返回期间的合法轨迹内。
        model.observe(frame: frame.offsetBy(dx: 100, dy: 50),
                      requestCursor: cursor.offsetBy(dx: 80, dy: 40), currentCursor: current)
        try require(model.isValid && model.isConfirmed)
        try expectFrame(model.predictedFrame(cursor: current), expected)
        try expectFrame(model.predictedFrame(cursor: cursor.offsetBy(dx: 260, dy: 130)),
                        frame.offsetBy(dx: 260, dy: 130))
    }

    func outAndBackCorridorKeepsOriginalAnchor() throws {
        for excursion in [CGPoint(x: 120, y: 0), CGPoint(x: 0, y: 90),
                          CGPoint(x: 120, y: 90), CGPoint(x: -120, y: -80)] {
            var model = try makeModel()
            let range = CGRect(x: cursor.x + min(0, excursion.x),
                               y: cursor.y + min(0, excursion.y),
                               width: abs(excursion.x), height: abs(excursion.y))
            // 查询起止光标相同，但中途经过的轨迹包含系统样本；纯水平或垂直范围也有效。
            model.observe(frame: frame.offsetBy(dx: excursion.x / 2, dy: excursion.y / 2), cursorRange: range)
            try require(model.isValid && model.isConfirmed)
            try expectFrame(model.predictedFrame(cursor: cursor), frame)
            try expectFrame(model.predictedFrame(cursor: cursor.offsetBy(dx: 30, dy: -15)),
                            frame.offsetBy(dx: 30, dy: -15))
        }
    }

    func invalidCursorCorridorPermanentlyInvalidatesPrediction() throws {
        let invalid = [CGRect(x: CGFloat.nan, y: cursor.y, width: 80, height: 40),
                       CGRect(origin: cursor, size: CGSize(width: -40, height: 30)),
                       CGRect(origin: cursor, size: CGSize(width: 40, height: -30))]
        for range in invalid {
            var model = try confirmedModel()
            model.observe(frame: frame.offsetBy(dx: 20, dy: 10), cursorRange: range)
            try require(!model.isValid)
            try expectFrame(model.predictedFrame(cursor: cursor), nil)
            model.observe(frame: frame.offsetBy(dx: 20, dy: 10),
                          cursorRange: CGRect(origin: cursor, size: CGSize(width: 40, height: 20)))
            try require(!model.isValid)
            try expectFrame(model.predictedFrame(cursor: cursor.offsetBy(dx: 40, dy: 20)), nil)
        }
    }

    func resizePermanentlyInvalidatesPrediction() throws {
        var model = try confirmedModel()
        let current = cursor.offsetBy(dx: 40, dy: 20)
        var resized = frame.offsetBy(dx: 40, dy: 20)
        resized.size.width += 80
        model.observe(frame: resized, requestCursor: current, currentCursor: current)
        try require(!model.isValid)
        try expectFrame(model.predictedFrame(cursor: current), nil)
        model.observe(frame: frame.offsetBy(dx: 50, dy: 25),
                      requestCursor: cursor.offsetBy(dx: 50, dy: 25),
                      currentCursor: cursor.offsetBy(dx: 50, dy: 25))
        try require(!model.isValid)
        try expectFrame(model.predictedFrame(cursor: cursor.offsetBy(dx: 60, dy: 30)), nil)
    }

    func incompatibleWindowTranslationInvalidatesPrediction() throws {
        var model = try confirmedModel()
        model.observe(frame: frame.offsetBy(dx: 600, dy: 400),
                      requestCursor: cursor.offsetBy(dx: 50, dy: 25),
                      currentCursor: cursor.offsetBy(dx: 60, dy: 30))
        try require(!model.isValid)
        try expectFrame(model.predictedFrame(cursor: cursor.offsetBy(dx: 70, dy: 35)), nil)
    }

    func negativeCoordinatesPreserveCursorDelta() throws {
        let negativeFrame = CGRect(x: -1720, y: -850, width: 1280, height: 760)
        let negativeCursor = CGPoint(x: -1200, y: -830)
        var model = try makeModel(frame: negativeFrame, cursor: negativeCursor)
        model.observe(frame: negativeFrame.offsetBy(dx: 80, dy: -40),
                      requestCursor: negativeCursor.offsetBy(dx: 70, dy: -35),
                      currentCursor: negativeCursor.offsetBy(dx: 90, dy: -45))
        try require(model.isValid && model.isConfirmed)
        try expectFrame(model.predictedFrame(cursor: negativeCursor.offsetBy(dx: 200, dy: -100)),
                        negativeFrame.offsetBy(dx: 200, dy: -100))
    }

    func invalidGeometryAndCursorAreRejected() throws {
        for invalid in [CGRect.null, .infinite, .zero, CGRect(x: 0, y: 0, width: 100, height: 700)] {
            try require(CursorDragModel(frame: invalid, cursor: cursor) == nil)
        }
        let invalidCursor = CGPoint(x: CGFloat.nan, y: cursor.y)
        try require(CursorDragModel(frame: frame, cursor: invalidCursor) == nil)
        var model = try confirmedModel()
        try expectFrame(model.predictedFrame(cursor: invalidCursor), nil)
        model.observe(frame: .infinite, requestCursor: cursor, currentCursor: cursor)
        try require(!model.isValid)
        try expectFrame(model.predictedFrame(cursor: cursor), nil)
    }
}

private extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
}

private struct RegressionFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool,
                     file: StaticString = #fileID, line: UInt = #line) throws {
    guard condition() else { throw RegressionFailure(description: "\(file):\(line): condition failed") }
}

private func expectFrame(_ actual: CGRect?, _ expected: CGRect?,
                         file: StaticString = #fileID, line: UInt = #line) throws {
    guard actual == expected else {
        throw RegressionFailure(description: "\(file):\(line): expected \(String(describing: expected)), got \(String(describing: actual))")
    }
}
