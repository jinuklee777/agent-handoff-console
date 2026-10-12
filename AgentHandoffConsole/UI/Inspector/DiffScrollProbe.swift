#if DEBUG
import AppKit
import SwiftUI

/// 화면 확인용 성능 측정 (Debug 빌드 · `AHC_OFFLINE=1` · `-preview.scrollProbe <초>` 일 때만, Release 에는 없다).
/// 측정 방식: 앱 안에서 보내는 휠 스크롤 왕복 + 메인 스레드 감시.
///
/// - 감시: 별도 스레드가 16ms 마다 메인 큐에 빈 작업을 보내 돌아오기까지 걸린 시간을 잰다
///   (150ms 넘으면 끊김, 3초 넘으면 멈춤). 여는 순간(`-preview.action diff:…` · `review:…`)부터 잰다.
/// - 스크롤: 60Hz 로 픽셀 단위 휠 이벤트를 diff 의 스크롤 뷰에 **직접** 넘긴다 (전역 이벤트를 만들지 않아 다른 앱 · 마우스에
///   가지 않는다). 바닥에 닿으면 위로, 꼭대기면 아래로 (`-preview.scrollSpeed <pt>`, 기본 160pt/이벤트).
///   그 뒤 `-preview.scrollProbeJump <초>`(기본 10) 동안은 스크롤 막대를 끄는 것처럼 0.3초마다 무작위 위치로 뛴다.
/// - 결과: `-preview.probeOut <경로>` 에 JSON 한 줄 (없으면 표준 출력). 앱은 끄지 않는다 (capture.sh 가 찍고 끈다).
@MainActor
final class DiffScrollProbe {
    static let shared = DiffScrollProbe()

    let seconds: Double
    let jumpSeconds: Double
    let speed: Double
    let outPath: String?
    var enabled: Bool { AppModel.offlinePreview && seconds > 0 }

    private let clockOrigin = CFAbsoluteTimeGetCurrent()
    private var marks: [String: Double] = [:]
    private var details: [String: String] = [:]
    private var target = ""
    private var attached = false
    private weak var scrollView: NSScrollView?
    private var timer: Timer?
    private var direction: CGFloat = 1
    private var sign: CGFloat = -1
    private var lastY: CGFloat?
    private var stuckTicks = 0
    private var halfTrips = 0
    private var pixels: CGFloat = 0
    private var scrollStart = 0.0
    private var jumpStart = 0.0
    private var jumps = 0
    /// (시각, 위치 비율, 문서 높이) — 끊김이 어디서 났는지 맞춰 보려고.
    private var timeline: [(Double, Double, Double)] = []
    private let watchdog = MainThreadWatchdog()

    private init() {
        let defaults = UserDefaults.standard
        seconds = defaults.double(forKey: "preview.scrollProbe")
        jumpSeconds = defaults.object(forKey: "preview.scrollProbeJump") == nil
            ? 10 : defaults.double(forKey: "preview.scrollProbeJump")
        speed = defaults.object(forKey: "preview.scrollSpeed") == nil ? 160 : defaults.double(forKey: "preview.scrollSpeed")
        outPath = defaults.string(forKey: "preview.probeOut")
    }

    private func now() -> Double { CFAbsoluteTimeGetCurrent() - clockOrigin }

    /// 미리보기 동작이 diff 를 열기 직전.
    func noteOpened(_ what: String) {
        guard enabled else { return }
        target = what
        marks["opened"] = now()
        watchdog.start()
    }

    func mark(_ name: String, detail: String = "") {
        guard enabled, marks["opened"] != nil, marks[name] == nil else { return }
        marks[name] = now()
        if !detail.isEmpty { details[name] = detail }
    }

    /// diff 표가 행을 올린 뒤 (다음 런루프 = 첫 행이 그려진 뒤). 잠시 뒤 그 스크롤 뷰로 스크롤을 시작한다.
    func attach(scrollView: NSScrollView) {
        guard enabled, marks["opened"] != nil else { return }
        mark("firstRow")
        guard !attached else { return }
        attached = true
        self.scrollView = scrollView
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in startScrolling() }
    }

    private func startScrolling() {
        guard scrollView != nil else {
            finish(error: "스크롤 뷰를 찾지 못했습니다")
            return
        }
        scrollStart = now()
        marks["scrollStart"] = scrollStart
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let t = now()
        if t - scrollStart >= seconds {
            if jumpStart == 0 { jumpStart = t; marks["jumpStart"] = t }
            if t - jumpStart >= jumpSeconds {
                timer?.invalidate()
                finish(error: nil)
                return
            }
            // 0.3초마다 무작위 위치로 (스크롤 막대를 끄는 것처럼).
            if Int((t - jumpStart) / 0.3) >= jumps {
                jumps += 1
                let clip = scrollView.contentView
                let maxY = max(0, document.frame.height - clip.bounds.height)
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: CGFloat.random(in: 0...maxY)))
                scrollView.reflectScrolledClipView(clip)
            }
            return
        }
        let clip = scrollView.contentView
        let y = clip.bounds.origin.y
        let maxY = max(0, document.frame.height - clip.bounds.height)
        // 문서가 뒤집혀 있지 않으면 y 가 클수록 위다.
        let position = document.isFlipped ? y : maxY - y
        if direction > 0, position >= maxY - 1 {
            direction = -1
            halfTrips += 1
        } else if direction < 0, position <= 1 {
            direction = 1
            halfTrips += 1
        }
        if let lastY {
            if abs(y - lastY) < 0.5 {
                stuckTicks += 1
                // 움직이지 않으면 휠 방향 부호를 한 번 바꿔 본다 (자연 스크롤 설정과 무관하게 합성 이벤트의 방향을 맞춘다).
                if stuckTicks == 6 { sign = -sign }
            } else {
                stuckTicks = 0
                pixels += abs(y - lastY)
            }
        }
        lastY = y
        timeline.append((t, maxY > 0 ? Double(position / maxY) : 0, Double(document.frame.height)))
        let delta = Int32(sign * direction * CGFloat(speed))
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta,
                               wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cg) else { return }
        scrollView.scrollWheel(with: event)
    }

    private func finish(error: String?) {
        let opened = marks["opened"] ?? 0
        let firstRow = marks["firstRow"]
        let scrollEnd = jumpStart == 0 ? now() : jumpStart
        let open = watchdog.stats(from: opened, to: (firstRow ?? opened) + 1.0, origin: clockOrigin)
        let scroll = watchdog.stats(from: scrollStart, to: scrollEnd, origin: clockOrigin)
        let jump = watchdog.stats(from: jumpStart, to: now(), origin: clockOrigin)
        watchdog.stop()
        var result: [String: Any] = [
            "target": target,
            "openToFirstRowMs": firstRow.map { Int((($0 - opened) * 1000).rounded()) } ?? -1,
            "openToRowsBuiltMs": marks["rowsBuilt"].map { Int((($0 - opened) * 1000).rounded()) } ?? -1,
            "rows": details["rowsBuilt"] ?? "",
            "openWindow": ["hitches150": open.hitches, "maxLagMs": open.maxLagMs, "freezes3s": open.freezes],
            "scroll": ["seconds": Int(scrollEnd - scrollStart), "halfTrips": halfTrips, "pixels": Int(pixels),
                       "hitches150": scroll.hitches, "maxLagMs": scroll.maxLagMs, "freezes3s": scroll.freezes,
                       "samplesOver50ms": scroll.over50],
            "jump": ["seconds": Int(jumpStart == 0 ? 0 : now() - jumpStart), "jumps": jumps,
                     "hitches150": jump.hitches, "maxLagMs": jump.maxLagMs, "freezes3s": jump.freezes],
        ]
        // 150ms 넘은 끊김마다 그때의 스크롤 위치 (보낸 시각 바로 앞의 틱).
        result["hitchList"] = watchdog.hitches(over: 0.15, origin: clockOrigin).map { sent, lag -> [String: Any] in
            let tick = timeline.last { $0.0 <= sent }
            return ["atS": (sent * 10).rounded() / 10, "lagMs": Int((lag * 1000).rounded()),
                    "position": tick.map { ($0.1 * 1000).rounded() / 1000 } ?? -1, "docHeight": Int(tick?.2 ?? -1)]
        }
        if let error { result["error"] = error }
        let data = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data()
        let line = (String(data: data, encoding: .utf8) ?? "{}") + "\n"
        if let outPath {
            try? line.write(toFile: outPath, atomically: true, encoding: .utf8)
        } else {
            print("PROBE " + line)
        }
    }

}

/// 메인 스레드 응답 시간 감시 (별도 스레드). 16ms 마다 메인 큐에 빈 작업을 보내 돌아오기까지의 시간을 기록한다.
final class MainThreadWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    /// (보낸 시각, 걸린 시간) — 50ms 넘은 것만.
    private var samples: [(Double, Double)] = []

    struct Stats {
        var hitches = 0
        var freezes = 0
        var maxLagMs = 0
        var over50 = 0
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        running = true
        let thread = Thread { [self] in loop() }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func loop() {
        while isRunning {
            let sent = CFAbsoluteTimeGetCurrent()
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { semaphore.signal() }
            semaphore.wait()
            let lag = CFAbsoluteTimeGetCurrent() - sent
            if lag > 0.05 {
                lock.lock()
                samples.append((sent, lag))
                lock.unlock()
            }
            usleep(16_000)
        }
    }

    /// `threshold` 초를 넘은 지연 (probe 시계 기준 보낸 시각, 걸린 시간).
    func hitches(over threshold: Double, origin: Double) -> [(Double, Double)] {
        lock.lock()
        let list = samples
        lock.unlock()
        return list.filter { $0.1 > threshold }.map { ($0.0 - origin, $0.1) }
    }

    /// `from`–`to` (probe 시계, `origin` 기준 초) 사이에 시작한 응답 지연.
    func stats(from: Double, to: Double, origin: Double) -> Stats {
        lock.lock()
        let list = samples
        lock.unlock()
        var stats = Stats()
        for (sent, lag) in list {
            let t = sent - origin
            guard t >= from, t <= to else { continue }
            stats.over50 += 1
            if lag > 0.15 { stats.hitches += 1 }
            if lag >= 3 { stats.freezes += 1 }
            stats.maxLagMs = max(stats.maxLagMs, Int((lag * 1000).rounded()))
        }
        return stats
    }
}
#endif
