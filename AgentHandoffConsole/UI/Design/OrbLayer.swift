import AppKit
import SwiftUI

// 점 구(thinking-orbs)를 SwiftUI 그래프 밖에서 그린다 — `SpinningLayer` · `CountdownText` 와 같은 까닭.
//
// 옮겨 온 `ThinkingOrb`(`ThinkingOrbs/`)는 `TimelineView(.animation)` + `Canvas` 라 프레임마다 창 전체의 SwiftUI 갱신
// (NSHostingView.layout)을 일으켰다 — 실행 중 상태 줄 하나에 앱 CPU 37%, 네 칸 57% (링은 0.5% · 9.8%, 2026-10-03 측정.
// 프로파일에서 점 계산 자체는 무시할 만했다). 여기서는 SwiftUI 에 알리지 않고, 다음 0.5초 동안의 장면들을 미리 칠해
// 레이어의 내용 애니메이션(낱장을 넘기는 키프레임) 하나로 창 서버에 넘긴다 — 창 서버가 제시간에 넘기고 앱은 0.5초에 한 번 깬다.
// 같은 날 거쳐 온 것: 화면 주기마다 한 장씩 칠해 넘기면 한 칸 5.9% (최적화 빌드) — 절반 가까이가 프레임마다의 커밋 · 창 서버로
// 보내는 메시지였다. 레이어의 `draw(in:)` 은 CA 가 그리기를 기록했다 다시 래스터화했고, CoreGraphics 로 점마다 경로를 채우면
// 그것만으로 프레임 시간의 절반, sRGB 그림은 CA 가 프레임마다 화면 색 공간으로 바꿨다 (`OrbCanvas` 가 피한다).
// 점의 위치 · 크기 · 잉크는 원본 엔진 그대로, 칠하는 규칙(`OrbCanvas`)은 원본 Canvas 와 같다 — 시험이 같은 길로 칠해 원본
// 렌더와 픽셀로 비교한다 (`scripts/inttest/OrbTests.swift`).

/// 점 구 하나. 크기는 `size` 의 한 변 (부르는 쪽이 그 크기의 틀을 준다).
struct OrbLayer: NSViewRepresentable {
    let state: OrbState
    var size: OrbSize = .px20
    /// 멈춘 한 장면만 그린다 (동작 줄이기 · 멈추는 중) — 원본이 동작 줄이기에서 보이는 것과 같은 순간.
    var paused = false
    var dark = false
    /// 이 엔진 시각에 멈춘다 (화면 확인용). 원본의 `orbFrozenTime` 과 같은 뜻 — 속도를 곱하지 않은 시각.
    var frozenTime: Double? = nil

    func makeNSView(context: Context) -> OrbLayerView { OrbLayerView() }

    func updateNSView(_ view: OrbLayerView, context: Context) {
        view.configure(.init(state: state, size: size, paused: paused, dark: dark, frozenTime: frozenTime))
    }

    static func dismantleNSView(_ view: OrbLayerView, coordinator: ()) { view.stopClock() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: OrbLayerView, context: Context) -> CGSize? {
        CGSize(width: size.value, height: size.value)
    }
}

/// `OrbLayer` 의 AppKit 쪽. 레이어를 직접 가진다 (layer-hosting) — 내용(그림)이 바뀌는 층 하나.
/// 움직이는 동안 `chunk` 마다 깨어 앞으로 `lookahead` 까지 비어 있는 구간을 칠해 넘긴다 (`scheduleAhead`). 시계가 늦어도 넘겨 둔
/// 만큼은 끊기지 않고, 그보다 늦으면 마지막 장면에 머물렀다가 지금부터 다시 잇는다. 창에 없거나 · 창이 가려졌거나 · 숨겨졌거나 ·
/// 멈춘 장면이면 시계를 끄고 한 장면만 둔다. 스크롤로 화면 밖이면 칠하지 않는다 (다시 보이면 다음 틱에 잇는다).
final class OrbLayerView: NSView {
    struct Config: Equatable {
        var state: OrbState
        var size: OrbSize
        var paused: Bool
        var dark: Bool
        var frozenTime: Double?
    }

    /// 한 번에 넘기는 구간 · 미리 채워 두는 길이 (초).
    static let chunk: CFTimeInterval = 0.5
    static let lookahead: CFTimeInterval = 1.0

    /// 초당 장면 수. `-preview.orbFPS <n>` (Debug) 로 바꿔 잰다.
    static let framesPerSecond: Double = {
        #if DEBUG
        let value = UserDefaults.standard.double(forKey: "preview.orbFPS")
        if value > 0 { return value }
        #endif
        return 60
    }()

    private let dots = CALayer()
    /// 칠하는 비트맵 — 한 변 = 엔진의 한 변 × 화면 배율 (픽셀). 배율이나 화면의 색 공간이 바뀌면 새로 만든다.
    private var canvas: OrbCanvas?
    private var config: Config?
    private var preset: ResolvedPreset?
    private var timer: Timer?
    /// 이 시각(`CACurrentMediaTime`)까지의 장면을 넘겨 두었다. 0 이면 아무것도.
    private var scheduledUntil: CFTimeInterval = 0
    private var chunkIndex = 0
    private var occlusionObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        // 내용이 바뀔 때마다 기본 전환(흐려지며 바뀜)이 끼지 않게.
        dots.actions = ["contents": NSNull()]
        layer?.addSublayer(dots)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        timer?.invalidate()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    /// 누르기 · 포인터는 뒤의 SwiftUI 가 받는다.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ new: Config) {
        guard new != config else { return }
        if new.state != config?.state || new.size != config?.size { preset = resolvePreset(new.state, new.size) }
        config = new
        restart()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dots.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        restart()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.restart() }
            }
        }
        restart()
    }

    override func viewDidHide() {
        super.viewDidHide()
        restart()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        restart()
    }

    // MARK: 시계

    private var shouldAnimate: Bool {
        guard let config, !config.paused, config.frozenTime == nil, let window, !isHiddenOrHasHiddenAncestor else { return false }
        return window.occlusionState.contains(.visible)
    }

    /// 넘겨 둔 구간을 버리고 지금부터 다시 — 모양 · 화면 · 보이는지가 바뀌었을 때.
    private func restart() {
        dots.removeAllAnimations()
        scheduledUntil = 0
        guard shouldAnimate else {
            stopClock()
            paintStill()
            return
        }
        // 처음에는 한 구간만 칠하고 (모양이 자주 바뀌는 실행에서 다시 시작할 때마다 1초치를 칠하지 않게), 시계를 반 구간 뒤로
        // 다시 맞춰 첫 구간이 끝나기 전에 나머지를 채운다.
        scheduleAhead(horizon: Self.chunk)
        stopClock()
        let timer = Timer(fire: Date(timeIntervalSinceNow: Self.chunk / 2), interval: Self.chunk, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleAhead() }
        }
        timer.tolerance = Self.chunk / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopClock() {
        timer?.invalidate()
        timer = nil
    }

    /// 앞으로 `horizon` 까지 비어 있는 구간을 칠해 넘긴다. 넘겨 둔 끝이 이미 지났으면 지금부터.
    private func scheduleAhead(horizon: CFTimeInterval = OrbLayerView.lookahead) {
        guard shouldAnimate else {
            restart()
            return
        }
        guard !visibleRect.isEmpty else {
            scheduledUntil = 0
            return
        }
        let now = CACurrentMediaTime()
        if scheduledUntil < now { scheduledUntil = now }
        while scheduledUntil < now + horizon {
            guard addChunk(from: scheduledUntil) else { return }
            scheduledUntil += Self.chunk
        }
    }

    /// `start` 부터 한 구간의 장면들을 칠해 낱장을 넘기는 내용 애니메이션 하나로 붙인다.
    private func addChunk(from start: CFTimeInterval) -> Bool {
        guard let config, let preset, let canvas = currentCanvas() else { return false }
        let fps = Self.framesPerSecond
        let count = max(1, Int((Self.chunk * fps).rounded()))
        var images: [CGImage] = []
        images.reserveCapacity(count)
        for k in 0..<count {
            let t = (start + Double(k) / fps) * preset.speed
            guard let image = canvas.render(orbFrame(preset, size: config.size.value, t: t), side: config.size.value,
                                            dark: config.dark) else { return false }
            images.append(image)
        }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = images
        animation.calculationMode = .discrete
        animation.keyTimes = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
        animation.duration = Self.chunk
        animation.beginTime = dots.convertTime(start, from: nil)
        animation.isRemovedOnCompletion = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dots.contentsScale = backingScale
        // 다음 구간이 늦으면 이 구간의 마지막 장면에 머문다.
        dots.contents = images.last
        dots.add(animation, forKey: "orb\(chunkIndex)")
        CATransaction.commit()
        chunkIndex &+= 1
        return true
    }

    /// 한 장면만 — 정해 둔 시각(화면 확인), 멈춘 장면(동작 줄이기 · 멈추는 중)이면 원본의 그 순간, 아니면 지금.
    private func paintStill() {
        guard let config, let preset, let canvas = currentCanvas() else { return }
        let t = config.frozenTime
            ?? (config.paused ? OrbSpec.reducedMotionT * preset.speed : CACurrentMediaTime() * preset.speed)
        let image = canvas.render(orbFrame(preset, size: config.size.value, t: t), side: config.size.value, dark: config.dark)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dots.contentsScale = backingScale
        dots.contents = image
        CATransaction.commit()
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }

    /// 지금 화면(배율 · 색 공간)에 맞는 비트맵.
    private func currentCanvas() -> OrbCanvas? {
        guard let config else { return nil }
        let pixels = max(1, Int((config.size.value * backingScale).rounded()))
        let space = window?.colorSpace?.cgColorSpace ?? OrbCanvas.sRGB
        if canvas?.pixels != pixels || canvas?.space != space { canvas = OrbCanvas(pixels: pixels, space: space) }
        return canvas
    }
}

/// 엔진의 한 장면을 칠하는 작은 비트맵 — 원본 `ThinkingOrb` 의 Canvas 와 같은 규칙: 선 먼저, 점은 엔진이 정한 순서
/// (먼 것 → 가까운 것), 회색은 원본처럼 8비트로 맞춘 sRGB, 겹침은 곱해진 알파의 source-over.
///
/// 점(지름 몇 픽셀)은 직접 찍는다 — 픽셀마다 4 × 4 표본으로 덮인 넓이를 센다 (넓이 비례 안티앨리어싱, CoreGraphics 처럼).
/// CoreGraphics 로 점마다 경로를 채우면 점이 100여 개인 장면 하나가 프레임 시간의 절반을 썼다 (2026-10-03 프로파일).
/// 그림은 `space`(화면의 색 공간)로 낸다 — sRGB 그림을 주면 Core Animation 이 프레임마다 화면 색 공간으로 바꿨다.
/// 회색 256 단계를 미리 그 공간의 값으로 옮겨 둔다.
final class OrbCanvas {
    let pixels: Int
    let space: CGColorSpace
    /// 곱해진 알파 RGBA (0~1), 첫 줄이 위 — 그림의 데이터 순서와 같다.
    private var accum: [Float]
    private var bytes: [UInt8]
    /// sRGB 회색 단계(0~255) → 이 색 공간의 RGB.
    private let palette: [SIMD3<Float>]

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    init(pixels: Int, space: CGColorSpace) {
        let space = space.model == .rgb ? space : Self.sRGB
        self.pixels = pixels
        self.space = space
        accum = Array(repeating: 0, count: pixels * pixels * 4)
        bytes = Array(repeating: 0, count: pixels * pixels * 4)
        palette = (0...255).map { level in
            let g = CGFloat(level) / 255
            guard let color = CGColor(colorSpace: Self.sRGB, components: [g, g, g, 1])?
                    .converted(to: space, intent: .defaultIntent, options: nil),
                  let c = color.components, c.count >= 3 else { return SIMD3(repeating: Float(g)) }
            return SIMD3(Float(c[0]), Float(c[1]), Float(c[2]))
        }
    }

    /// 비우고 한 장면을 칠해 그림으로 낸다. 엔진 좌표(위가 y = 0, 한 변 `side`)를 비트맵 한 변에 맞춘다.
    func render(_ scene: OrbFrame, side: Double, dark: Bool) -> CGImage? {
        guard side > 0 else { return nil }
        let scale = Float(Double(pixels) / side)
        accum.withUnsafeMutableBufferPointer { buffer in
            buffer.update(repeating: 0)
            for line in scene.lines {
                stroke(from: SIMD2(Float(line.x1), Float(line.y1)) * scale, to: SIMD2(Float(line.x2), Float(line.y2)) * scale,
                       width: Float(line.w) * scale, color: palette[Self.level(line.white, dark: dark)],
                       alpha: Float(line.a), into: buffer)
            }
            for dot in scene.dots {
                fill(center: SIMD2(Float(dot.x), Float(dot.y)) * scale, radius: Float(dot.r) * scale,
                     color: palette[Self.level(dot.white, dark: dark)], alpha: Float(dot.a), into: buffer)
            }
        }
        for i in bytes.indices { bytes[i] = UInt8(min(255, max(0, (accum[i] * 255).rounded()))) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// 원본과 같은 8비트 회색 단계 (어두운 화면이면 밝기를 뒤집는다).
    static func level(_ white: Double, dark: Bool) -> Int {
        let w = min(1, max(0, white))
        return Int(((dark ? 1 - w : w) * 255).rounded(.toNearestOrAwayFromZero))
    }

    // MARK: 찍기

    /// 픽셀 반대각선 — 가운데가 이만큼 안쪽(바깥쪽)이면 픽셀 전체가 안(밖)이다.
    private static let halfDiagonal: Float = 0.7072

    private func fill(center c: SIMD2<Float>, radius r: Float, color: SIMD3<Float>, alpha: Float,
                      into buffer: UnsafeMutableBufferPointer<Float>) {
        guard alpha > 0, r > 0 else { return }
        let x0 = max(0, Int((c.x - r).rounded(.down))), x1 = min(pixels - 1, Int((c.x + r).rounded(.down)))
        let y0 = max(0, Int((c.y - r).rounded(.down))), y1 = min(pixels - 1, Int((c.y + r).rounded(.down)))
        guard x0 <= x1, y0 <= y1 else { return }
        let r2 = r * r
        for py in y0...y1 {
            for px in x0...x1 {
                let d = ((Float(px) + 0.5 - c.x) * (Float(px) + 0.5 - c.x)
                         + (Float(py) + 0.5 - c.y) * (Float(py) + 0.5 - c.y)).squareRoot()
                if d >= r + Self.halfDiagonal { continue }
                var coverage: Float = 1
                if d > r - Self.halfDiagonal {
                    var inside = 0
                    for sy in 0..<4 {
                        let dy = Float(py) + (Float(sy) + 0.5) / 4 - c.y
                        for sx in 0..<4 {
                            let dx = Float(px) + (Float(sx) + 0.5) / 4 - c.x
                            if dx * dx + dy * dy <= r2 { inside += 1 }
                        }
                    }
                    guard inside > 0 else { continue }
                    coverage = Float(inside) / 16
                }
                blend(px, py, color: color, alpha: alpha * coverage, into: buffer)
            }
        }
    }

    /// 끝을 자른(butt) 선 — 원본 Canvas 의 기본 선 모양.
    private func stroke(from a: SIMD2<Float>, to b: SIMD2<Float>, width: Float, color: SIMD3<Float>, alpha: Float,
                        into buffer: UnsafeMutableBufferPointer<Float>) {
        let ab = b - a
        let length2 = (ab * ab).sum()
        guard alpha > 0, width > 0, length2 > 0 else { return }
        let half = width / 2
        let x0 = max(0, Int((min(a.x, b.x) - half).rounded(.down))), x1 = min(pixels - 1, Int((max(a.x, b.x) + half).rounded(.down)))
        let y0 = max(0, Int((min(a.y, b.y) - half).rounded(.down))), y1 = min(pixels - 1, Int((max(a.y, b.y) + half).rounded(.down)))
        guard x0 <= x1, y0 <= y1 else { return }
        let normal = SIMD2(-ab.y, ab.x) / length2.squareRoot()
        for py in y0...y1 {
            for px in x0...x1 {
                var inside = 0
                for sy in 0..<4 {
                    for sx in 0..<4 {
                        let p = SIMD2(Float(px) + (Float(sx) + 0.5) / 4, Float(py) + (Float(sy) + 0.5) / 4) - a
                        let along = (p * ab).sum() / length2
                        if along >= 0, along <= 1, abs((p * normal).sum()) <= half { inside += 1 }
                    }
                }
                if inside > 0 { blend(px, py, color: color, alpha: alpha * Float(inside) / 16, into: buffer) }
            }
        }
    }

    private func blend(_ px: Int, _ py: Int, color: SIMD3<Float>, alpha: Float, into buffer: UnsafeMutableBufferPointer<Float>) {
        let i = (py * pixels + px) * 4
        let keep = 1 - alpha
        buffer[i] = color.x * alpha + buffer[i] * keep
        buffer[i + 1] = color.y * alpha + buffer[i + 1] * keep
        buffer[i + 2] = color.z * alpha + buffer[i + 2] * keep
        buffer[i + 3] = alpha + buffer[i + 3] * keep
    }
}
