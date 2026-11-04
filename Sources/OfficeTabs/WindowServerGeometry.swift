import CoreGraphics
import CoreFoundation
import Foundation

struct WindowServerWindow: Equatable {
    let id: CGWindowID
    let processID: pid_t
    /// WindowServer 与 AX 均以主屏左上角为原点，单位为屏幕逻辑坐标。
    let frame: CGRect
}

struct WindowServerDocument: Equatable {
    let id: String
    let processID: pid_t
    let frame: CGRect
    let previousWindowID: CGWindowID?

    init(id: String, processID: pid_t, frame: CGRect, previousWindowID: CGWindowID? = nil) {
        self.id = id
        self.processID = processID
        self.frame = frame
        self.previousWindowID = previousWindowID
    }
}

/// 只读取窗口编号、所属进程与几何信息，不请求窗口内容或录屏权限。
enum WindowServerGeometry {
    /// 返回同一 Office 进程的可见普通窗口，保留 WindowServer 的从前到后顺序。
    static func list(processID: pid_t) -> [WindowServerWindow] {
        guard processID > 0,
              let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let window = decode(row), window.processID == processID else { return nil }
            return window
        }
    }

    /// 已绑定的窗口按编号直接取回；传入进程可拒绝关闭后被其他进程复用的编号。
    static func window(windowID: CGWindowID, processID: pid_t? = nil) -> WindowServerWindow? {
        guard windowID != kCGNullWindowID else { return nil }
        // 此 API 的输入是按指针宽度存储的原始窗口编号，不是 CFNumber/NSArray 对象。
        // 显式扩展到 UInt 可避免在 64 位平台把 UInt32 的地址误读成一个完整指针槽。
        var rawID: UnsafeRawPointer? = UnsafeRawPointer(bitPattern: UInt(windowID))
        guard let ids = CFArrayCreate(kCFAllocatorDefault, &rawID, 1, nil),
              let rows = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
              let row = rows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
              let window = decode(row), processID == nil || window.processID == processID else { return nil }
        return window
    }

    static func frame(windowID: CGWindowID, processID: pid_t? = nil) -> CGRect? {
        window(windowID: windowID, processID: processID)?.frame
    }

    /// 一次为整组 AX 文档建立单射，避免不同 Space 的重叠文档共用一个可见窗口编号。
    static func bindings(documents: [WindowServerDocument], candidates: [WindowServerWindow],
                         focusedDocumentID: String?) -> [String: CGWindowID] {
        let documentCounts = Dictionary(grouping: documents, by: \.id).mapValues(\.count)
        let validDocuments = documents.filter {
            !$0.id.isEmpty && documentCounts[$0.id] == 1 && $0.processID > 0 && isDocumentSized($0.frame)
        }
        let candidateCounts = Dictionary(grouping: candidates, by: \.id).mapValues(\.count)
        let validCandidates = candidates.filter {
            candidateCounts[$0.id] == 1 && $0.id != kCGNullWindowID && $0.processID > 0 && isDocumentSized($0.frame)
        }
        let candidatesByID = Dictionary(uniqueKeysWithValues: validCandidates.map { ($0.id, $0) })
        let previousClaims = Dictionary(grouping: validDocuments.compactMap(\.previousWindowID), by: { $0 }).mapValues(\.count)
        var result: [String: CGWindowID] = [:]
        var usedIDs: Set<CGWindowID> = []

        // AX 对象身份持续存在时，已有编号无需再次匹配旧坐标；窗口此刻可能正在拖动。
        // 多个 AX 文档同时声称同一旧编号时，整组声称都不能作为可信身份沿用。
        for document in validDocuments {
            guard let previousID = document.previousWindowID, previousClaims[previousID] == 1,
                  let candidate = candidatesByID[previousID], candidate.processID == document.processID else { continue }
            result[document.id] = previousID
            usedIDs.insert(previousID)
        }

        // 先处理已经由 AX 确认的焦点文档；同位置窗口此时可利用可见窗口的前后顺序消歧。
        if let focusedDocumentID, result[focusedDocumentID] == nil,
           let focused = validDocuments.first(where: { $0.id == focusedDocumentID }) {
            let available = validCandidates.filter { !usedIDs.contains($0.id) && $0.processID == focused.processID }
            if let id = match(frame: focused.frame, candidates: available, allowFrontmost: true) {
                result[focused.id] = id
                usedIDs.insert(id)
            }
        }

        let remainingDocuments = validDocuments.filter { result[$0.id] == nil }
        let remainingCandidates = validCandidates.filter { !usedIDs.contains($0.id) }
        let matchesByDocument = Dictionary(uniqueKeysWithValues: remainingDocuments.map { document in
            (document.id, remainingCandidates.filter {
                $0.processID == document.processID && approximatelyEqual($0.frame, document.frame)
            })
        })
        let remainingClaims = Dictionary(grouping: matchesByDocument.values.flatMap { $0.map(\.id) }, by: { $0 }).mapValues(\.count)
        // 未聚焦文档必须双向唯一：它只匹配一个 CG 窗口，且该 CG 窗口也只匹配这一个 AX 文档。
        // 仅检查前半条会把另一个 Space 上恰好同位置的文档错误地绑定到当前屏幕窗口。
        for document in remainingDocuments {
            guard let matches = matchesByDocument[document.id], matches.count == 1,
                  let candidate = matches.first, remainingClaims[candidate.id] == 1,
                  usedIDs.insert(candidate.id).inserted else { continue }
            result[document.id] = candidate.id
        }
        return result
    }

    /// 在 AX 已确认窗口身份时绑定编号；绑定后拖动采样直接读取该编号，不逐帧重新匹配。
    static func match(frame: CGRect, candidates: [WindowServerWindow], preferredID: CGWindowID? = nil,
                      allowFrontmost: Bool = false) -> CGWindowID? {
        guard isDocumentSized(frame) else { return nil }
        let matches = candidates.filter {
            $0.id != kCGNullWindowID && $0.processID > 0 && isDocumentSized($0.frame) &&
                approximatelyEqual($0.frame, frame)
        }
        // 旧编号仍须通过当前几何验证，不能用缓存掩盖编号失效或相同位置的窗口歧义。
        if matches.count == 1, let preferredID, matches[0].id == preferredID { return preferredID }
        if matches.count == 1 { return matches[0].id }
        // 同尺寸同位置的多个文档只有在调用者已通过 AX 确认焦点后，才按前后顺序取首个。
        return allowFrontmost ? matches.first?.id : nil
    }

    private static func decode(_ row: [String: Any]) -> WindowServerWindow? {
        guard let id = row[kCGWindowNumber as String] as? NSNumber, id.uint32Value != kCGNullWindowID,
              let owner = row[kCGWindowOwnerPID as String] as? NSNumber, owner.int32Value > 0,
              let layer = row[kCGWindowLayer as String] as? NSNumber, layer.int32Value == 0,
              let alpha = row[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue.isFinite, alpha.doubleValue > 0,
              (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
              let bounds = row[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), isDocumentSized(frame) else { return nil }
        // 排除菜单、浮动面板和极小辅助窗口；具体文档身份仍由 AX 发现阶段确认。
        return WindowServerWindow(id: id.uint32Value, processID: owner.int32Value, frame: frame)
    }

    private static func isDocumentSized(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.width > 100 && frame.height > 100 &&
            [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
    }

    private static func approximatelyEqual(_ left: CGRect, _ right: CGRect) -> Bool {
        // AX 与 WindowServer 的小数舍入可能不同，允许少量逻辑像素偏差，不做 Retina 倍率换算。
        abs(left.minX - right.minX) <= 2 && abs(left.minY - right.minY) <= 2 &&
            abs(left.width - right.width) <= 2 && abs(left.height - right.height) <= 2
    }
}
