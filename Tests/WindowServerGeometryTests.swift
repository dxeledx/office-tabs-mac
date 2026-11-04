import Foundation
import CoreGraphics

@main
struct WindowServerGeometryTests {
    private let frame = CGRect(x: 120, y: 180, width: 1000, height: 700)

    static func main() {
        let suite = WindowServerGeometryTests()
        let cases: [(String, () throws -> Void)] = [
            ("uniqueMatchingWindow", suite.uniqueMatchingWindow),
            ("movedWindowHasNoMatch", suite.movedWindowHasNoMatch),
            ("twoPointRoundingTolerance", suite.twoPointRoundingTolerance),
            ("outsideToleranceHasNoMatch", suite.outsideToleranceHasNoMatch),
            ("identicalBoundsRemainAmbiguous", suite.identicalBoundsRemainAmbiguous),
            ("preferredIDDoesNotResolveAmbiguity", suite.preferredIDDoesNotResolveAmbiguity),
            ("confirmedFocusSelectsFrontmostMatch", suite.confirmedFocusSelectsFrontmostMatch),
            ("stalePreferredIDMustPassGeometryValidation", suite.stalePreferredIDMustPassGeometryValidation),
            ("negativeDisplayCoordinatesMatch", suite.negativeDisplayCoordinatesMatch),
            ("invalidTargetGeometryHasNoMatch", suite.invalidTargetGeometryHasNoMatch),
            ("invalidCandidateGeometryHasNoMatch", suite.invalidCandidateGeometryHasNoMatch),
            ("emptyCandidatesHaveNoMatch", suite.emptyCandidatesHaveNoMatch),
            ("frontmostPermissionStillRequiresMatchingGeometry", suite.frontmostPermissionStillRequiresMatchingGeometry),
            ("onlyFocusedDocumentBindsSingleVisibleDuplicate", suite.onlyFocusedDocumentBindsSingleVisibleDuplicate),
            ("unfocusedDuplicatesDoNotClaimSingleVisibleWindow", suite.unfocusedDuplicatesDoNotClaimSingleVisibleWindow),
            ("focusedDuplicateAllocationIsOneToOne", suite.focusedDuplicateAllocationIsOneToOne),
            ("thirdOffSpaceDuplicateRemainsAmbiguous", suite.thirdOffSpaceDuplicateRemainsAmbiguous),
            ("trustedWindowIDsSurviveMovement", suite.trustedWindowIDsSurviveMovement),
            ("staleWindowOwnerDoesNotRetainBinding", suite.staleWindowOwnerDoesNotRetainBinding),
            ("duplicatePreviousClaimsNeverDuplicateBindings", suite.duplicatePreviousClaimsNeverDuplicateBindings)
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
        print("\(cases.count) WindowServer matching regression tests passed.")
    }

    private func window(_ id: CGWindowID, _ rect: CGRect) -> WindowServerWindow {
        WindowServerWindow(id: id, processID: 42, frame: rect)
    }

    func uniqueMatchingWindow() throws {
        let candidates = [window(80, frame.offsetBy(dx: 400, dy: 0)), window(31, frame)]
        try expectID(WindowServerGeometry.match(frame: frame, candidates: candidates), 31)
        try expectID(WindowServerGeometry.match(frame: frame, candidates: candidates, preferredID: 31), 31)
    }

    func movedWindowHasNoMatch() throws {
        let candidates = [window(31, frame.offsetBy(dx: 80, dy: 40))]
        try expectID(WindowServerGeometry.match(frame: frame, candidates: candidates), nil)
    }

    func twoPointRoundingTolerance() throws {
        let rounded = [
            frame.offsetBy(dx: 2, dy: -2),
            CGRect(x: frame.minX - 2, y: frame.minY + 2,
                   width: frame.width + 2, height: frame.height - 2)
        ]
        for candidate in rounded {
            try expectID(WindowServerGeometry.match(frame: frame, candidates: [window(31, candidate)]), 31)
        }
    }

    func outsideToleranceHasNoMatch() throws {
        let candidates = [
            frame.offsetBy(dx: 2.01, dy: 0),
            frame.offsetBy(dx: 0, dy: -2.01),
            CGRect(x: frame.minX, y: frame.minY, width: frame.width + 2.01, height: frame.height),
            CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - 2.01)
        ]
        for candidate in candidates {
            try expectID(WindowServerGeometry.match(frame: frame, candidates: [window(31, candidate)]), nil)
        }
    }

    func identicalBoundsRemainAmbiguous() throws {
        try expectID(WindowServerGeometry.match(frame: frame, candidates: [window(31, frame), window(32, frame)]), nil)
    }

    func preferredIDDoesNotResolveAmbiguity() throws {
        // 两个同位置文档不能仅凭旧缓存选中，否则切换焦点后可能继续跟踪另一个文档。
        let candidates = [window(31, frame), window(32, frame)]
        try expectID(WindowServerGeometry.match(frame: frame, candidates: candidates, preferredID: 32), nil)
    }

    func confirmedFocusSelectsFrontmostMatch() throws {
        let candidates = [window(80, frame.offsetBy(dx: 200, dy: 0)), window(32, frame), window(31, frame)]
        try expectID(WindowServerGeometry.match(frame: frame, candidates: candidates,
                                                preferredID: 31, allowFrontmost: true), 32)
    }

    func stalePreferredIDMustPassGeometryValidation() throws {
        let candidates = [window(31, frame.offsetBy(dx: 200, dy: 0)), window(32, frame)]
        try expectID(WindowServerGeometry.match(frame: frame, candidates: candidates, preferredID: 31), 32)
        try expectID(WindowServerGeometry.match(frame: frame, candidates: [candidates[0]], preferredID: 31), nil)
    }

    func negativeDisplayCoordinatesMatch() throws {
        let negative = CGRect(x: -1720, y: -790, width: 1280, height: 760)
        try expectID(WindowServerGeometry.match(frame: negative, candidates: [window(31, negative)]), 31)
    }

    func invalidTargetGeometryHasNoMatch() throws {
        let invalid = [CGRect.null, .infinite, .zero,
                       CGRect(x: CGFloat.nan, y: 0, width: 1000, height: 700),
                       CGRect(x: 0, y: CGFloat.infinity, width: 1000, height: 700),
                       CGRect(x: 0, y: 0, width: 100, height: 700),
                       CGRect(x: 0, y: 0, width: 1000, height: 100)]
        for target in invalid {
            try expectID(WindowServerGeometry.match(frame: target, candidates: [window(31, frame)],
                                                    preferredID: 31, allowFrontmost: true), nil)
        }
    }

    func invalidCandidateGeometryHasNoMatch() throws {
        let target = CGRect(x: 0, y: 0, width: 101, height: 101)
        let invalid = [CGRect.null, .infinite, .zero,
                       CGRect(x: CGFloat.nan, y: 0, width: 101, height: 101),
                       CGRect(x: 0, y: 0, width: 100, height: 101),
                       CGRect(x: 0, y: 0, width: 101, height: 100)]
        for candidate in invalid {
            try expectID(WindowServerGeometry.match(frame: target, candidates: [window(31, candidate)]), nil)
        }
    }

    func emptyCandidatesHaveNoMatch() throws {
        try expectID(WindowServerGeometry.match(frame: frame, candidates: [], preferredID: 31, allowFrontmost: true), nil)
    }

    func frontmostPermissionStillRequiresMatchingGeometry() throws {
        let candidates = [window(31, frame.offsetBy(dx: 200, dy: 0)), window(32, frame.offsetBy(dx: 0, dy: 200))]
        try expectID(WindowServerGeometry.match(frame: frame, candidates: candidates,
                                                preferredID: 31, allowFrontmost: true), nil)
    }

    private func document(_ id: String, frame rect: CGRect? = nil,
                          previousWindowID: CGWindowID? = nil) -> WindowServerDocument {
        WindowServerDocument(id: id, processID: 42, frame: rect ?? frame, previousWindowID: previousWindowID)
    }

    func onlyFocusedDocumentBindsSingleVisibleDuplicate() throws {
        let documents = [document("other-space"), document("visible")]
        // AX 会同时列出其他 Space 的同位置文档，可见的 CG 编号只能交给已确认的焦点。
        for ordered in [documents, Array(documents.reversed())] {
            try expectBindings(WindowServerGeometry.bindings(documents: ordered, candidates: [window(31, frame)],
                                                             focusedDocumentID: "visible"), ["visible": 31])
        }
    }

    func unfocusedDuplicatesDoNotClaimSingleVisibleWindow() throws {
        let documents = [document("first"), document("second")]
        for focus: String? in [nil, "unknown-document"] {
            try expectBindings(WindowServerGeometry.bindings(documents: documents, candidates: [window(31, frame)],
                                                             focusedDocumentID: focus), [:])
        }
    }

    func focusedDuplicateAllocationIsOneToOne() throws {
        let documents = [document("back"), document("front")]
        let candidates = [window(31, frame), window(32, frame)]
        try expectBindings(WindowServerGeometry.bindings(documents: documents, candidates: candidates,
                                                         focusedDocumentID: "front"), ["front": 31, "back": 32])
    }

    func thirdOffSpaceDuplicateRemainsAmbiguous() throws {
        let documents = [document("other-space"), document("back"), document("front")]
        let candidates = [window(31, frame), window(32, frame)]
        for ordered in [documents, Array(documents.reversed())] {
            // 焦点分配后仍有两个 AX 文档竞争一个编号，不能按枚举顺序任意选择。
            try expectBindings(WindowServerGeometry.bindings(documents: ordered, candidates: candidates,
                                                             focusedDocumentID: "front"), ["front": 31])
        }
    }

    func trustedWindowIDsSurviveMovement() throws {
        let documents = [document("first", previousWindowID: 31),
                         document("second", frame: frame.offsetBy(dx: 200, dy: 0), previousWindowID: 32)]
        let candidates = [window(32, frame.offsetBy(dx: 700, dy: 300)),
                          window(31, frame.offsetBy(dx: -100, dy: -80))]
        try expectBindings(WindowServerGeometry.bindings(documents: documents, candidates: candidates,
                                                         focusedDocumentID: nil), ["first": 31, "second": 32])

        let sameBounds = [document("other-space", previousWindowID: 77), document("visible", previousWindowID: 31)]
        try expectBindings(WindowServerGeometry.bindings(documents: sameBounds, candidates: [window(31, frame)],
                                                         focusedDocumentID: nil), ["visible": 31])
    }

    func staleWindowOwnerDoesNotRetainBinding() throws {
        let documents = [document("first", previousWindowID: 31)]
        let reused = WindowServerWindow(id: 31, processID: 99, frame: frame)
        try expectBindings(WindowServerGeometry.bindings(documents: documents, candidates: [reused],
                                                         focusedDocumentID: "first"), [:])
        try expectBindings(WindowServerGeometry.bindings(documents: documents, candidates: [reused, window(32, frame)],
                                                         focusedDocumentID: "first"), ["first": 32])
    }

    func duplicatePreviousClaimsNeverDuplicateBindings() throws {
        let documents = [document("first", previousWindowID: 31), document("second", previousWindowID: 31)]
        for focus: String? in [nil, "first", "second"] {
            let expected: [String: CGWindowID] = focus.map { [$0: 31] } ?? [:]
            for ordered in [documents, Array(documents.reversed())] {
                try expectBindings(WindowServerGeometry.bindings(documents: ordered, candidates: [window(31, frame)],
                                                                 focusedDocumentID: focus), expected)
            }
        }
    }
}

private struct RegressionFailure: Error, CustomStringConvertible {
    let description: String
}

private func expectID(_ actual: CGWindowID?, _ expected: CGWindowID?,
                      file: StaticString = #fileID, line: UInt = #line) throws {
    guard actual == expected else {
        throw RegressionFailure(description: "\(file):\(line): expected \(String(describing: expected)), got \(String(describing: actual))")
    }
}

private func expectBindings(_ actual: [String: CGWindowID], _ expected: [String: CGWindowID],
                            file: StaticString = #fileID, line: UInt = #line) throws {
    guard actual == expected, Set(actual.values).count == actual.count else {
        throw RegressionFailure(description: "\(file):\(line): expected \(expected), got \(actual)")
    }
}
