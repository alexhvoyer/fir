#if DEBUG
import UIKit

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

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        print("FRAMEMETER start maxFPS=\(UIScreen.main.maximumFramesPerSecond)")
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
        if now - windowStart >= 1 {
            if late > 0 {
                print(String(format: "FRAMEMETER fps=%d worst=%.1fms late=%d", frames, worst * 1000, late))
            }
            windowStart = now
            frames = 0
            worst = 0
            late = 0
        }
    }
}
#endif
