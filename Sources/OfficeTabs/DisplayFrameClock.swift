import AppKit
import CoreVideo
import QuartzCore

/// 在目标屏幕的刷新节奏上更新浮栏；启动、停止和 tick 均由主线程管理。
final class DisplayFrameClock {
    private var tick: (() -> Void)?
    private var driver: AnyObject?
    private var invalidateDriver: (() -> Void)?
    private var displayID: CGDirectDisplayID?
    private var screenIdentity: ObjectIdentifier?
    private var target: DisplayFrameTarget?

    var isRunning: Bool { driver != nil }

    func start(on screen: NSScreen, tick: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        let nextDisplayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let nextIdentity = ObjectIdentifier(screen)
        let sameDisplay = nextDisplayID.map { $0 == displayID } ?? (nextIdentity == screenIdentity)
        self.tick = tick
        if isRunning, sameDisplay { return }
        stopDriver()
        displayID = nextDisplayID
        screenIdentity = nextIdentity

        let maximumFPS = screen.maximumFramesPerSecond > 0 ? screen.maximumFramesPerSecond : 60
        if #available(macOS 14.0, *) {
            let target = DisplayFrameTarget(owner: self)
            let link = screen.displayLink(target: target, selector: #selector(DisplayFrameTarget.frame(_:)))
            let rate = Float(maximumFPS)
            // 拖动期间采用当前屏幕的最高刷新节奏，避免把 120 Hz 屏幕固定限制在 60 Hz。
            link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
            self.target = target
            driver = link
            invalidateDriver = { link.invalidate() }
            link.add(to: .main, forMode: .common)
        } else if let legacy = LegacyDisplayFrameDriver(displayID: nextDisplayID ?? CGMainDisplayID(), tick: { [weak self] in self?.fire() }) {
            driver = legacy
            invalidateDriver = { legacy.stop() }
        } else {
            // 旧系统在显示链路创建失败时仍能跟随窗口，频率继续使用屏幕报告的刷新率。
            let timer = Timer(timeInterval: 1.0 / Double(maximumFPS), repeats: true) { [weak self] _ in self?.fire() }
            driver = timer
            invalidateDriver = { timer.invalidate() }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        stopDriver()
        tick = nil
        displayID = nil
        screenIdentity = nil
    }

    fileprivate func fire() {
        guard isRunning else { return }
        tick?()
    }

    private func stopDriver() {
        invalidateDriver?()
        invalidateDriver = nil
        driver = nil
        target = nil
    }

    deinit { invalidateDriver?() }
}

/// CADisplayLink 会持有目标对象，代理只弱引用时钟，停止前后都不会形成引用环。
private final class DisplayFrameTarget: NSObject {
    weak var owner: DisplayFrameClock?

    init(owner: DisplayFrameClock) { self.owner = owner }

    @objc func frame(_ sender: AnyObject) { owner?.fire() }
}

/// CoreVideo 的回调来自显示线程，只向主线程保留一个待处理帧，慢帧直接合并。
private final class DisplayFrameDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var pending = false
    private var tick: (() -> Void)?

    init(tick: @escaping () -> Void) { self.tick = tick }

    func enqueue() {
        lock.lock()
        guard active, !pending else { lock.unlock(); return }
        pending = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pending = false
            let callback = self.active ? self.tick : nil
            self.lock.unlock()
            callback?()
        }
    }

    func invalidate() {
        lock.lock()
        active = false
        tick = nil
        lock.unlock()
    }
}

@available(macOS, introduced: 10.4, obsoleted: 14.0)
private final class LegacyDisplayFrameDriver {
    private var link: CVDisplayLink?
    private let delivery: DisplayFrameDelivery

    init?(displayID: CGDirectDisplayID, tick: @escaping () -> Void) {
        delivery = DisplayFrameDelivery(tick: tick)
        var created: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(displayID, &created) == kCVReturnSuccess, let created else { return nil }
        let delivery = self.delivery
        let callbackResult = CVDisplayLinkSetOutputHandler(created) { [weak delivery] _, _, _, _, _ in
            delivery?.enqueue()
            return kCVReturnSuccess
        }
        guard callbackResult == kCVReturnSuccess, CVDisplayLinkStart(created) == kCVReturnSuccess else {
            delivery.invalidate()
            return nil
        }
        link = created
    }

    func stop() {
        delivery.invalidate()
        if let link {
            CVDisplayLinkStop(link)
            self.link = nil
        }
    }

    deinit { stop() }
}
