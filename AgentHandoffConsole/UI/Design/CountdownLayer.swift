import AppKit
import SwiftUI

// 자동 인계 카운트다운처럼 1초마다 바뀌는 표시 — SwiftUI 그래프 밖에서 바꾼다 (`SpinningLayer` 와 같은 까닭).
//
// `TimelineView(.periodic(by: 1))` 는 틱마다 창 전체의 SwiftUI 갱신(NSHostingView.layout → AttributeGraph)을 일으켜,
// 카운트다운 카드가 보이는 동안 유휴 CPU 가 한 칸 약 6% · 네 칸 약 10% 였다 (2026-10-02 측정 — 틱을 내는 뷰의 크기와 무관).
// 여기서는 CATextLayer 의 글만 바꾸고 링의 호는 Core Animation 이 줄인다 (한 칸 0.4~0.7% · 네 칸 0.7~1.6%).
// 틱은 마감 시각에 맞춘다 — 같은 마감을 보는 표시(카드의 링 · 사이드바 배지 · 입력창 위 한 줄)가 같은 순간에 같은 수를 보인다.
// 주의: 마감에서 끝나는 사용자 `TimelineSchedule` 로 바꾸지 말 것 — 항목이 비거나 지난 날짜 하나만 남는 순간부터 CPU 가 50% 가까이 돌았다.

/// 남은 초를 글로 보이는 한 줄 (잘리면 끝을 줄인다). 크기는 처음 남은 초의 글 크기로 고정된다 (숫자는 고정폭).
/// 접근성 이름은 부르는 쪽이 고정 글로 단다 — 초마다 읽지 않는다.
struct CountdownText: NSViewRepresentable {
    let deadline: Date
    var step: TypeScale = .caption
    var weight: NSFont.Weight = .semibold
    var color: Color
    let text: (Int) -> String

    func makeNSView(context: Context) -> CountdownLayerView { CountdownLayerView() }

    func updateNSView(_ view: CountdownLayerView, context: Context) {
        view.configure(deadline: deadline, text: text,
                       style: CountdownLayerView.Style(step: step, weight: weight, color: color, ring: nil))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CountdownLayerView, context: Context) -> CGSize? {
        let size = CountdownLayerView.textSize(text(CountdownLayerView.remaining(deadline)), step: step, weight: weight)
        guard let width = proposal.width, width < size.width else { return size }
        return CGSize(width: max(0, width), height: size.height)
    }
}

/// 시작부터 지난 시간을 1초마다 보이는 한 줄 (실행 중 경과 · 하위 작업 시계 · 기다린 시간). `CountdownText` 와 같은 까닭으로
/// SwiftUI 그래프 밖에서 바꾼다 — `TimelineView(.periodic(by: 1))` 는 실행이 도는 동안 대화 하나에 약 4% 였다 (2026-10-02 측정).
/// 틀의 폭은 지금부터 한 시간 뒤까지의 가장 넓은 글이 들어가게 미리 잡는다 (`DisplayFormat.elapsedWidthSamples` — "59분 59초" 가
/// "1시간 0분" 보다 넓다) — 자릿수가 늘 때마다(9 → 10초) SwiftUI 에 다시 묻게 하면 배치가 멈추지 않고 돌았다(유휴 CPU 90%,
/// 같은 날 실측). 잘리면 끝을 줄인다. 접근성 이름은 부르는 쪽이 단다.
struct ElapsedText: NSViewRepresentable {
    let since: Date
    var step: TypeScale = .caption
    var weight: NSFont.Weight = .regular
    var mono = true
    var color: Color = Theme.slate2
    let text: (Int) -> String

    func makeNSView(context: Context) -> CountdownLayerView { CountdownLayerView() }

    func updateNSView(_ view: CountdownLayerView, context: Context) {
        view.configure(clock: .elapsed(since: since), text: text,
                       style: CountdownLayerView.Style(step: step, weight: weight, color: color, ring: nil, mono: mono))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CountdownLayerView, context: Context) -> CGSize? {
        let now = CountdownLayerView.elapsed(since: since)
        let sizes = DisplayFormat.elapsedWidthSamples(from: now).map {
            CountdownLayerView.textSize(text($0), step: step, weight: weight, mono: mono)
        }
        let size = CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.first?.height ?? 0)
        guard let proposed = proposal.width, proposed < size.width else { return size }
        return CGSize(width: max(0, proposed), height: size.height)
    }
}

/// 카운트다운 링 — 가운데 남은 초, 호는 남은 시간만큼 줄어든다. 동작 줄이기면 멈춘 링 + 수.
struct CountdownRingLayer: NSViewRepresentable {
    let deadline: Date
    let delay: Int
    let reduceMotion: Bool
    var diameter: CGFloat = 38

    func makeNSView(context: Context) -> CountdownLayerView { CountdownLayerView() }

    func updateNSView(_ view: CountdownLayerView, context: Context) {
        view.configure(deadline: deadline, text: { "\($0)" },
                       style: CountdownLayerView.Style(step: .body, weight: .semibold, color: Theme.amber,
                                                       ring: .init(track: Theme.approvalBorder, lineWidth: 3, delay: delay,
                                                                   animated: !reduceMotion),
                                                       textColor: Theme.amberText))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CountdownLayerView, context: Context) -> CGSize? {
        CGSize(width: diameter, height: diameter)
    }
}

/// `CountdownText` · `CountdownRingLayer` 의 AppKit 쪽. 레이어를 직접 가진다 (layer-hosting).
final class CountdownLayerView: NSView {
    struct Ring: Equatable {
        var track: Color
        var lineWidth: CGFloat
        var delay: Int
        var animated: Bool
    }

    struct Style: Equatable {
        var step: TypeScale
        var weight: NSFont.Weight
        var color: Color
        var ring: Ring?
        /// SF Mono (명령 · 시계처럼 글자 그대로) — 아니면 SF Pro 고정폭 숫자.
        var mono = false
        /// 글자 색이 `color` 와 다를 때 (링: 호는 `Theme.amber`, 가운데 수는 글자용 `Theme.amberText`).
        var textColor: Color? = nil
    }

    /// 무엇을 세나: 마감까지 남은 초(아래로, 0 에서 멈춘다) · 시작부터 지난 초(위로, 창에 있는 동안 계속).
    enum Clock: Equatable {
        case countdown(Date)
        case elapsed(since: Date)
    }

    private let textLayer = CATextLayer()
    private let trackLayer = CAShapeLayer()
    private let arcLayer = CAShapeLayer()
    private var timer: Timer?
    private var clock: Clock?
    private var text: (Int) -> String = { "\($0)" }
    private var style: Style?
    private static let arcAnimationKey = "countdown"

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        textLayer.truncationMode = .end
        textLayer.isWrapped = false
        for shape in [trackLayer, arcLayer] {
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        layer?.addSublayer(textLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 누르기 · 포인터는 뒤의 SwiftUI (버튼) 가 받는다.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 마감까지 남은 초 (올림, 0 이상).
    static func remaining(_ deadline: Date, now: Date = Date()) -> Int {
        max(0, Int(ceil(deadline.timeIntervalSince(now))))
    }

    /// 시작부터 지난 초 (내림, 0 이상).
    static func elapsed(since start: Date, now: Date = Date()) -> Int {
        max(0, Int(floor(now.timeIntervalSince(start))))
    }

    static func seconds(_ clock: Clock, now: Date = Date()) -> Int {
        switch clock {
        case .countdown(let deadline): return remaining(deadline, now: now)
        case .elapsed(let start): return elapsed(since: start, now: now)
        }
    }

    static func font(step: TypeScale, weight: NSFont.Weight, mono: Bool = false) -> NSFont {
        mono ? NSFont.monospacedSystemFont(ofSize: step.size, weight: weight)
             : NSFont.monospacedDigitSystemFont(ofSize: step.size, weight: weight)
    }

    static func textSize(_ string: String, step: TypeScale, weight: NSFont.Weight, mono: Bool = false) -> CGSize {
        let size = NSAttributedString(string: string, attributes: [.font: font(step: step, weight: weight, mono: mono)]).size()
        return CGSize(width: ceil(size.width) + 1, height: ceil(size.height))
    }

    func configure(deadline: Date, text: @escaping (Int) -> String, style: Style) {
        configure(clock: .countdown(deadline), text: text, style: style)
    }

    func configure(clock: Clock, text: @escaping (Int) -> String, style: Style) {
        self.text = text
        let changed = clock != self.clock || style != self.style
        if clock != self.clock { stop() }
        self.clock = clock
        self.style = style
        if changed {
            applyStyle()
            restartArc()
        }
        tick()
        schedule()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeLayers()
        CATransaction.commit()
        restartArc()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
        tick()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyStyle()
        tick()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stop()
        } else {
            applyStyle()
            restartArc()
            tick()
            schedule()
        }
    }

    // MARK: 시계

    /// 다음 틱을 마감에 맞춰 건다 — 남은 초(올림)가 바뀌는 순간마다. 이미 걸려 있으면 그대로 둔다.
    private func schedule() {
        guard timer == nil, window != nil, let clock else { return }
        let next: Date
        switch clock {
        case .countdown(let deadline):
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return }
            // 남은 시간이 정수 초로 떨어지는 다음 순간 (조금 늦게 깨워 올림이 확실히 바뀐 뒤에 읽는다).
            next = deadline.addingTimeInterval(-(ceil(left) - 1) + 0.01)
        case .elapsed(let start):
            // 지난 시간이 다음 정수 초가 되는 순간.
            next = start.addingTimeInterval(floor(max(0, -start.timeIntervalSinceNow)) + 1 + 0.01)
        }
        let timer = Timer(fire: next, interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let clock, let style else { return }
        let seconds = Self.seconds(clock)
        let value = text(seconds)
        let string = NSAttributedString(string: value, attributes: [
            .font: Self.font(step: style.step, weight: style.weight, mono: style.mono),
            .foregroundColor: resolved(style.textColor ?? style.color),
        ])
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.string = string
        CATransaction.commit()
        if case .countdown = clock, seconds == 0 { stop() }
    }

    // MARK: 모양

    private func resolved(_ color: Color) -> NSColor {
        var out = NSColor(color)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            out = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        }
        return out
    }

    private func applyStyle() {
        guard let style else { return }
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.contentsScale = scale
        textLayer.alignmentMode = style.ring == nil ? .left : .center
        trackLayer.isHidden = style.ring == nil
        arcLayer.isHidden = style.ring == nil
        if let ring = style.ring {
            trackLayer.contentsScale = scale
            arcLayer.contentsScale = scale
            trackLayer.lineWidth = ring.lineWidth
            arcLayer.lineWidth = ring.lineWidth
            trackLayer.strokeColor = resolved(ring.track).cgColor
            arcLayer.strokeColor = resolved(style.color).cgColor
        }
        placeLayers()
        CATransaction.commit()
    }

    private func placeLayers() {
        guard let style else { return }
        let lineHeight = Self.textSize("0", step: style.step, weight: style.weight, mono: style.mono).height
        textLayer.frame = CGRect(x: 0, y: (bounds.height - lineHeight) / 2, width: bounds.width, height: lineHeight)
        if let ring = style.ring {
            let inset = ring.lineWidth / 2
            let circle = bounds.insetBy(dx: inset, dy: inset)
            trackLayer.frame = bounds
            arcLayer.frame = bounds
            trackLayer.path = CGPath(ellipseIn: circle, transform: nil)
            // 12시에서 시작해 시계 방향으로 줄어든다 (뒤집히지 않은 레이어 좌표: 위가 +y, 시계 방향은 음의 각).
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let path = CGMutablePath()
            path.addArc(center: center, radius: circle.width / 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
            arcLayer.path = path
        }
    }

    /// 호를 지금 남은 몫에서 마감에 0 이 되도록 한 번에 건다 (Core Animation 이 줄인다 — 앱은 틱마다 그리지 않는다).
    private func restartArc() {
        guard let style, let ring = style.ring, case .countdown(let deadline)? = clock else { return }
        arcLayer.removeAnimation(forKey: Self.arcAnimationKey)
        let left = max(0, deadline.timeIntervalSinceNow)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arcLayer.strokeEnd = ring.animated ? 0 : 1
        CATransaction.commit()
        guard ring.animated, left > 0, window != nil else { return }
        let fraction = min(1, left / Double(max(ring.delay, 1)))
        let shrink = CABasicAnimation(keyPath: "strokeEnd")
        shrink.fromValue = fraction
        shrink.toValue = 0
        shrink.duration = left
        shrink.timingFunction = CAMediaTimingFunction(name: .linear)
        shrink.isRemovedOnCompletion = true
        arcLayer.add(shrink, forKey: Self.arcAnimationKey)
    }
}
