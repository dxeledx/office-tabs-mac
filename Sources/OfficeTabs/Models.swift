import AppKit
import ApplicationServices

enum OfficeApp: String, CaseIterable {
    case word, excel, powerpoint

    var bundleID: String {
        switch self {
        case .word: return "com.microsoft.Word"
        case .excel: return "com.microsoft.Excel"
        case .powerpoint: return "com.microsoft.Powerpoint"
        }
    }

    var name: String {
        switch self {
        case .word: return "Word"
        case .excel: return "Excel"
        case .powerpoint: return "PowerPoint"
        }
    }

    var letter: String {
        switch self {
        case .word: return "W"
        case .excel: return "X"
        case .powerpoint: return "P"
        }
    }

    var tint: NSColor {
        switch self {
        case .word: return NSColor(srgbRed: 0.15, green: 0.39, blue: 0.83, alpha: 1)
        case .excel: return NSColor(srgbRed: 0.08, green: 0.48, blue: 0.31, alpha: 1)
        case .powerpoint: return NSColor(srgbRed: 0.80, green: 0.28, blue: 0.17, alpha: 1)
        }
    }

    static func matching(_ bundleID: String?) -> OfficeApp? {
        allCases.first { $0.bundleID == bundleID }
    }
}

struct OfficeDocument: Identifiable {
    let id: String
    let app: OfficeApp
    let processID: pid_t
    let title: String
    let fileURL: URL?
    let isEdited: Bool
    let isMinimized: Bool
    /// 必须读取 AXFullScreen，普通贴边最大化不能通过窗口尺寸推断为全屏。
    let isFullScreen: Bool
    /// 系统辅助功能以主屏左上角为原点；面板定位时统一转换为 AppKit 坐标。
    let frame: CGRect
    /// 几何采样开始的单调时钟时间，用于拒绝较慢的完整扫描带来的过期位置。
    let geometryTimestamp: TimeInterval
    /// 确认文档身份后绑定系统窗口编号，拖动时直接读取 WindowServer 几何信息。
    let windowServerID: CGWindowID?
    let element: AXUIElement
}

struct OfficeState {
    var documents: [OfficeDocument] = []
    var frontmostBundleID: String?
    var activeDocumentID: String?
    var hasModalWindow = false
    var accessibilityGranted = false
}
