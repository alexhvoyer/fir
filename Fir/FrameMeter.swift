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

#if DEBUG
import Darwin

/// Debug only: prints once a second this process's CPU use and the phone's thermal state, to tell Fir's
/// own work apart from WebKit's processes. Read with `devicectl device process launch --console`.
enum CPUMeter {
    static func start() {
        Task.detached(priority: .utility) {
            while true {
                let state = ["nominal", "fair", "serious", "critical"][ProcessInfo.processInfo.thermalState.rawValue]
                print(String(format: "CPUMETER %.0f cpu=%.1f%% thermal=%@", Date.now.timeIntervalSince1970, usage(), state))
                fflush(stdout)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Sum of every thread's share of a core, as `top` shows it.
    private static func usage() -> Double {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return -1 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var size = mach_msg_type_number_t(THREAD_INFO_MAX)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &size) }
            }
            if result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        return total
    }
}
#endif
