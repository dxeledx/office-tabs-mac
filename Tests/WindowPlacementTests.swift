import Foundation
import CoreGraphics

@main
struct WindowPlacementTests {

    static func main() {
        let suite = WindowPlacementTests()
        let cases: [(String, () throws -> Void)] = [
            ("testTopMaximizeWaitsForSpaceInsteadOfCoveringTitleBar", suite.testTopMaximizeWaitsForSpaceInsteadOfCoveringTitleBar),
            ("testReservedHeaderExactlyFitsAboveDocument", suite.testReservedHeaderExactlyFitsAboveDocument),
            ("testEveryInsufficientTopMarginWaitsInsteadOfClampingIntoDocument", suite.testEveryInsufficientTopMarginWaitsInsteadOfClampingIntoDocument),
            ("testOrdinaryDragPreservesTheWindowTranslation", suite.testOrdinaryDragPreservesTheWindowTranslation),
            ("testActualFullscreenIsDistinctFromOrdinaryMaximize", suite.testActualFullscreenIsDistinctFromOrdinaryMaximize),
            ("testDisplayLeftOfPrimaryKeepsNegativeCoordinates", suite.testDisplayLeftOfPrimaryKeepsNegativeCoordinates),
            ("testDisplayBelowPrimaryKeepsNegativeVerticalCoordinates", suite.testDisplayBelowPrimaryKeepsNegativeVerticalCoordinates),
            ("testNarrowDisplayLimitsBarWidthToVisibleScreen", suite.testNarrowDisplayLimitsBarWidthToVisibleScreen),
            ("testWindowOutsideDisplayDoesNotProduceDetachedBar", suite.testWindowOutsideDisplayDoesNotProduceDetachedBar),
            ("testInvalidGeometryIsUnavailable", suite.testInvalidGeometryIsUnavailable),
            ("testPlacedBarsNeverIntersectDocumentAndRemainOnScreen", suite.testPlacedBarsNeverIntersectDocumentAndRemainOnScreen)
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
            let report = failures.joined(separator: "\n") + "\n"
            FileHandle.standardError.write(Data(report.utf8))
            exit(1)
        }
        print("\(cases.count) layout regression tests passed.")
    }

    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testTopMaximizeWaitsForSpaceInsteadOfCoveringTitleBar() throws {
        try expectEqual(WindowPlacement.attached(to: visible, visible: visible, isFullScreen: false), .needsSpace)
    }

    func testReservedHeaderExactlyFitsAboveDocument() throws {
        let document = CGRect(x: 0, y: 0, width: 1440, height: 851)
        try expectEqual(WindowPlacement.reservedHeight, 49)
        try expectEqual(WindowPlacement.attached(to: document, visible: visible, isFullScreen: false),
                       .above(CGRect(x: 0, y: 856, width: 1440, height: 44)))
    }

    func testEveryInsufficientTopMarginWaitsInsteadOfClampingIntoDocument() throws {
        for margin: CGFloat in [0, 1, 20, 43, 48] {
            let document = CGRect(x: 50, y: 0, width: 1000, height: visible.height - margin)
            try expectEqual(WindowPlacement.attached(to: document, visible: visible, isFullScreen: false),
                           .needsSpace, "top margin: \(margin)")
        }
    }

    func testOrdinaryDragPreservesTheWindowTranslation() throws {
        let start = CGRect(x: 100, y: 120, width: 1000, height: 650)
        let moved = start.offsetBy(dx: 40, dy: 25)
        try expectEqual(WindowPlacement.attached(to: start, visible: visible, isFullScreen: false),
                       .above(CGRect(x: 100, y: 775, width: 1000, height: 44)))
        try expectEqual(WindowPlacement.attached(to: moved, visible: visible, isFullScreen: false),
                       .above(CGRect(x: 140, y: 800, width: 1000, height: 44)))
    }

    func testActualFullscreenIsDistinctFromOrdinaryMaximize() throws {
        try expectEqual(WindowPlacement.attached(to: visible, visible: visible, isFullScreen: true), .unavailable)
        try expectEqual(WindowPlacement.attached(to: visible, visible: visible, isFullScreen: false), .needsSpace)
    }

    func testDisplayLeftOfPrimaryKeepsNegativeCoordinates() throws {
        let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let document = CGRect(x: -1800, y: 160, width: 1300, height: 780)
        try expectEqual(WindowPlacement.attached(to: document, visible: screen, isFullScreen: false),
                       .above(CGRect(x: -1800, y: 945, width: 1300, height: 44)))
    }

    func testDisplayBelowPrimaryKeepsNegativeVerticalCoordinates() throws {
        let screen = CGRect(x: -1600, y: -900, width: 1600, height: 860)
        let document = CGRect(x: -1520, y: -780, width: 1280, height: 660)
        try expectEqual(WindowPlacement.attached(to: document, visible: screen, isFullScreen: false),
                       .above(CGRect(x: -1520, y: -115, width: 1280, height: 44)))
    }

    func testNarrowDisplayLimitsBarWidthToVisibleScreen() throws {
        let screen = CGRect(x: 0, y: 0, width: 300, height: 900)
        let document = CGRect(x: 15, y: 30, width: 260, height: 600)
        try expectEqual(WindowPlacement.attached(to: document, visible: screen, isFullScreen: false),
                       .above(CGRect(x: 0, y: 635, width: 300, height: 44)))
    }

    func testWindowOutsideDisplayDoesNotProduceDetachedBar() throws {
        let document = CGRect(x: 1500, y: 100, width: 800, height: 600)
        try expectEqual(WindowPlacement.attached(to: document, visible: visible, isFullScreen: false), .unavailable)
    }

    func testInvalidGeometryIsUnavailable() throws {
        let validDocument = CGRect(x: 100, y: 100, width: 800, height: 600)
        let invalid: [CGRect] = [
            .null, .infinite, .zero,
            CGRect(x: CGFloat.nan, y: 0, width: 800, height: 600),
            CGRect(x: 0, y: CGFloat.infinity, width: 800, height: 600)
        ]
        for rect in invalid {
            try expectEqual(WindowPlacement.attached(to: rect, visible: visible, isFullScreen: false), .unavailable)
            try expectEqual(WindowPlacement.attached(to: validDocument, visible: rect, isFullScreen: false), .unavailable)
        }
    }

    func testPlacedBarsNeverIntersectDocumentAndRemainOnScreen() throws {
        let screens = [visible,
                       CGRect(x: -1920, y: -900, width: 1920, height: 1080),
                       CGRect(x: 1440, y: 900, width: 300, height: 760)]
        var placementsChecked = 0
        for screen in screens {
            for xOffset: CGFloat in [-180, 0, 100, screen.width - 100] {
                for yOffset: CGFloat in [-80, 0, 200, screen.height - 100] {
                    for width: CGFloat in [250, 600, 1700] {
                        for height: CGFloat in [180, 600, 880] {
                            let document = CGRect(x: screen.minX + xOffset, y: screen.minY + yOffset,
                                                  width: width, height: height)
                            guard case let .above(bar) = WindowPlacement.attached(to: document, visible: screen,
                                                                                  isFullScreen: false) else { continue }
                            // 多种显示器原点与越界窗口共同验证约束，避免只覆盖单一主屏布局。
                            try expectFalse(bar.intersects(document), "document: \(document), bar: \(bar)")
                            try expectGreaterThanOrEqual(bar.minY, document.maxY + WindowPlacement.gap)
                            try expectGreaterThanOrEqual(bar.minX, screen.minX)
                            try expectGreaterThanOrEqual(bar.minY, screen.minY)
                            try expectLessThanOrEqual(bar.maxX, screen.maxX + 0.01)
                            try expectLessThanOrEqual(bar.maxY, screen.maxY + 0.01)
                            placementsChecked += 1
                        }
                    }
                }
            }
        }
        print("  checked \(placementsChecked) non-overlapping placements")
        try expectGreaterThan(placementsChecked, 100)
    }
}


private struct RegressionFailure: Error, CustomStringConvertible {
    let description: String
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                                       file: StaticString = #fileID, line: UInt = #line) throws {
    guard actual == expected else {
        throw RegressionFailure(description: "\(file):\(line): expected \(expected), got \(actual). \(message)")
    }
}

private func expectFalse(_ actual: Bool, _ message: String = "",
                         file: StaticString = #fileID, line: UInt = #line) throws {
    guard !actual else {
        throw RegressionFailure(description: "\(file):\(line): expected false. \(message)")
    }
}

private func expectGreaterThanOrEqual<T: Comparable>(_ actual: T, _ lower: T,
                                                    file: StaticString = #fileID, line: UInt = #line) throws {
    guard actual >= lower else {
        throw RegressionFailure(description: "\(file):\(line): \(actual) is below \(lower)")
    }
}

private func expectLessThanOrEqual<T: Comparable>(_ actual: T, _ upper: T,
                                                 file: StaticString = #fileID, line: UInt = #line) throws {
    guard actual <= upper else {
        throw RegressionFailure(description: "\(file):\(line): \(actual) exceeds \(upper)")
    }
}

private func expectGreaterThan<T: Comparable>(_ actual: T, _ lower: T,
                                             file: StaticString = #fileID, line: UInt = #line) throws {
    guard actual > lower else {
        throw RegressionFailure(description: "\(file):\(line): \(actual) does not exceed \(lower)")
    }
}
