import UIKit

#if !DEBUG
/// Release builds keep the call sites and drop the meter.
@MainActor
enum FrameMeter {
    static func mark(_ event: String) {}
}
#else

/// Debug only: prints, once a second while frames are late, the frame rate and the slowest frame as
/// the main thread sees them. Read with `devicectl device process launch --console`.
@MainActor
final class FrameMeter: NSObject {

    static let shared = FrameMeter()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0
    private var frames = 0
    private var worst: CFTimeInterval = 0
    private var late = 0

    /// Names what starts now, so a late frame in the report can be tied to it.
    static func mark(_ event: String) {
        shared.flush()
        shared.lastMark = event
        print(String(format: "FRAMEMETER %.2f mark %@", CACurrentMediaTime(), event))
        // Piped to devicectl, stdout is block-buffered; lines must arrive as they happen.
        fflush(stdout)
    }

    private var iterationStart: CFTimeInterval = 0
    private var lastMark = "-"

    func start() {
        guard link == nil else { return }
        // Times every pass of the main run loop; one over 40 ms names the mark before it.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, activity in
            let now = CACurrentMediaTime()
            MainActor.assumeIsolated {
                let meter = FrameMeter.shared
                if activity == .afterWaiting {
                    meter.iterationStart = now
                } else if meter.iterationStart > 0, now - meter.iterationStart > 0.04 {
                    print(String(format: "FRAMEMETER %.2f STALL %.0fms after: %@", now, (now - meter.iterationStart) * 1000, meter.lastMark))
                    fflush(stdout)
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FrameMeter.mark("keyboard will show") }
        }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        print("FRAMEMETER start maxFPS=\(UIScreen.main.maximumFramesPerSecond)")
        fflush(stdout)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if last > 0 {
            let delta = now - last
            let expected = link.targetTimestamp - link.timestamp
            worst = max(worst, delta)
            if delta > expected * 1.5 { late += 1 }
        } else {
            windowStart = now
        }
        last = now
        frames += 1
        if now - windowStart >= 1 { flush() }
    }

    /// Reports the frames since the last report, then starts counting afresh.
    private func flush() {
        if late > 0 {
            print(String(format: "FRAMEMETER %.2f fps=%d worst=%.1fms late=%d", CACurrentMediaTime(), frames, worst * 1000, late))
            fflush(stdout)
        }
        windowStart = last
        frames = 0
        worst = 0
        late = 0
    }
}
#endif
