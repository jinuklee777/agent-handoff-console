import SwiftUI

// MARK: - 라벨 · 키 힌트

/// 섹션 라벨 (caption · medium, 대문자 아님).
struct SectionLabel: View {
    let text: String
    var color: Color = Theme.slate2

    init(_ text: String, color: Color = Theme.slate2) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text).sectionLabelStyle(color)
    }
}

/// `⌘F` 같은 단축키 표시.
struct KeyHint: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.mono(.caption))
            .foregroundStyle(Theme.slate2)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hair))
            .accessibilityHidden(true)
    }
}

/// 가운데 점 구분자.
struct MetaDot: View {
    var body: some View {
        Text("·").font(Theme.ui(.caption)).foregroundStyle(Theme.slate3)
    }
}

/// 세로 규칙선 (상태 막대 구분).
struct VRule: View {
    var height: CGFloat = 12
    var body: some View {
        Rectangle().fill(Theme.hair).frame(width: 1, height: height)
    }
}

// MARK: - 세그먼트

/// 회색 바탕 위 흰 알약이 선택을 표시하는 세그먼트 (대화/전적, 기간, 이름/내용).
struct PillSegmented<Value: Hashable, Label: View>: View {
    let options: [Value]
    @Binding var selection: Value
    var stretch = false
    var background: Color = Theme.wellSoft
    @ViewBuilder let label: (Value, Bool) -> Label

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { value in
                let selected = value == selection
                Button {
                    selection = value
                } label: {
                    label(value, selected)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 3)
                        .frame(maxWidth: stretch ? .infinity : nil)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Theme.card)
                                    .shadow(color: Theme.shadow.opacity(0.07), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(background, in: RoundedRectangle(cornerRadius: 7))
    }
}

/// 세그먼트 안의 글자. 선택되면 잉크색·600.
struct PillText: View {
    let text: String
    let selected: Bool

    var body: some View {
        Text(text)
            .font(Theme.ui(.caption, selected ? .semibold : .regular))
            .foregroundStyle(selected ? Theme.ink : Theme.slate)
            .lineLimit(1)
    }
}

// MARK: - 버튼

/// 흰 바탕 + 규칙선 26pt 칩 버튼 (글자 caption).
struct ChipButtonStyle: ButtonStyle {
    var height: CGFloat = 26
    var horizontalPadding: CGFloat = 11
    var radius: CGFloat = 7
    /// 이 칩이 연 팝오버가 떠 있는 동안 눌린 모양(well)으로 둔다 (목업 `chip(pressed=True)`).
    var pressed = false

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, height: height,
                 horizontalPadding: horizontalPadding, radius: radius, pressed: pressed)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        let height: CGFloat
        let horizontalPadding: CGFloat
        let radius: CGFloat
        let pressed: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, horizontalPadding)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: radius)
                    .fill(configuration.isPressed || pressed ? Theme.well : Theme.card))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.hair))
                .contentShape(RoundedRectangle(cornerRadius: radius))
                .opacity(isEnabled ? 1 : 0.45)
        }
    }
}

/// 글자만 있는 선택기 (입력창의 제공자 · 모델 칩). 테두리 없이 포인터를 올리거나 열려 있을 때만 바탕이 생긴다.
/// 채움 상자(`Theme.well`) 위에 놓이므로 바탕은 그보다 한 단계 짙은 규칙선 색을 쓴다.
struct GhostChipStyle: ButtonStyle {
    var height: CGFloat = 24
    var horizontalPadding: CGFloat = 7
    /// 이 칩이 연 팝오버 · 메뉴가 떠 있는 동안 눌린 모양으로 둔다.
    var pressed = false

    func makeBody(configuration: Configuration) -> some View {
        GhostBody(configuration: configuration, height: height, horizontalPadding: horizontalPadding, pressed: pressed)
    }

    private struct GhostBody: View {
        let configuration: Configuration
        let height: CGFloat
        let horizontalPadding: CGFloat
        let pressed: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let active = hovering || pressed || configuration.isPressed
            configuration.label
                .font(Theme.ui(.callout))
                .foregroundStyle(active ? Theme.ink2 : Theme.slate)
                .padding(.horizontal, horizontalPadding)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? Theme.hair : .clear))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

/// 잉크 바탕 주 버튼 (허용, 보내기, 커밋).
struct InkButtonStyle: ButtonStyle {
    var height: CGFloat = 26
    var fill: Color = Theme.ink

    func makeBody(configuration: Configuration) -> some View {
        InkBody(configuration: configuration, height: height, fill: fill)
    }

    private struct InkBody: View {
        let configuration: Configuration
        let height: CGFloat
        let fill: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Theme.ui(.caption, .semibold))
                .foregroundStyle(Theme.onInk)
                .padding(.horizontal, 13)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 6).fill(fill))
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.35)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// 테두리 없는 글자 버튼 (거절 후 중단, 모두 올리기).
struct TextButtonStyle: ButtonStyle {
    var color: Color = Theme.slate
    var font: Font = Theme.ui(.caption)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(color)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// 아이콘 하나짜리 버튼 (새로고침, 더보기).
struct IconButton: View {
    let systemName: String
    var size: CGFloat = 12
    var color: Color = Theme.slate2
    var help: String
    var spinning = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // 도는 동안은 같은 기호를 Core Animation 이 돌린다 (`SpinningLayer`). 자리는 그대로 두어 옆 글자가 밀리지 않는다.
            Image(systemName: systemName)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(color)
                .opacity(spinning ? 0 : 1)
                .frame(width: size + 10, height: size + 10)
                .overlay {
                    if spinning {
                        SpinningLayer(content: .symbol(name: systemName, size: size, color: color), period: 0.9)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - 계측

/// 한도 막대 (44×4). 값을 모르면 채우지 않는다.
struct LimitMeter: View {
    let fraction: Double?
    var width: CGFloat = 44
    /// 채움 색을 정해 둔다 (없으면 사용률에 따라 — `color(for:)`). 이어 가기 제안 줄은 주의 정도의 앰버로 둔다.
    var tint: Color?

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.hair)
            if let fraction {
                Capsule()
                    .fill(tint ?? Self.color(for: fraction))
                    .frame(width: max(2, width * min(max(fraction, 0), 1)))
            }
        }
        .frame(width: width, height: 4)
        .accessibilityHidden(true)
    }

    /// 90% 이상 오류색, 70% 이상 앰버, 그 외 잉크.
    static func color(for fraction: Double) -> Color {
        fraction >= 0.9 ? Theme.danger : (fraction >= 0.7 ? Theme.amber : Theme.ink2)
    }

    /// 막대 옆 사용률 글자의 색 — 같은 구간, 앰버는 글자용(`amberText`).
    static func textColor(for fraction: Double) -> Color {
        fraction >= 0.9 ? Theme.danger : (fraction >= 0.7 ? Theme.amberText : Theme.ink2)
    }
}

/// diff 막대 5칸. 추가·삭제 비율을 칸 수로 보여준다 (GitHub 방식).
struct DiffBars: View {
    let added: Int
    let removed: Int

    var body: some View {
        let total = added + removed
        let blocks = min(5, total)
        let green = total == 0 ? 0 : Int((Double(added) / Double(total) * Double(blocks)).rounded())
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < green ? Theme.emerald : (i < blocks ? Theme.danger : Theme.hair))
                    .frame(width: 5, height: 9)
            }
        }
        .accessibilityHidden(true)
    }
}

/// 실행 표시 점 (Claude 테라코타 + 헤일로).
struct RunningDot: View {
    var color: Color = Theme.claude
    var halo: CGFloat = 3

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .background(Circle().fill(color.opacity(0.17)).frame(width: 6 + halo * 2, height: 6 + halo * 2))
            .accessibilityHidden(true)
    }
}

/// 진행 중 표시 (앰버 링).
struct PendingRing: View {
    var color: Color = Theme.amber

    var body: some View {
        SpinningLayer(content: .ring(color: color, lineWidth: 1.5, trim: 0.75), period: 1)
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }
}

// MARK: - 회전 표시

/// 도는 표시(`PendingRing` · `InkSpinner` · `IconButton` 의 새로고침)는 Core Animation 레이어가 돌린다.
///
/// SwiftUI 의 반복 애니메이션(`repeatForever`)은 매 프레임 창 전체의 화면 그래프를 다시 계산한다. 링이 화면 밖(지연 없이
/// 그려 둔 옛 행)에 있어도 그렇고, 분할 화면이면 네 칸 전체가 그 비용이다 — 가만히 있는 네 칸이 CPU 76~100% 를 썼다
/// (2026-09-29 실측). 또 켜자마자 끈 반복 애니메이션이 멈추지 않고 남았다 (Git 을 13ms 에 읽는 파일 탭 새로고침 아이콘).
/// 레이어 애니메이션은 창 서버가 돌려 앱의 메인 스레드를 쓰지 않고, 끄면(뷰를 빼면) 레이어째 사라진다.
struct SpinningLayer: NSViewRepresentable {
    enum Content: Equatable {
        /// `Circle().trim(from: 0, to: trim).stroke(…)` 와 같은 모양 (둥근 끝).
        case ring(color: Color, lineWidth: CGFloat, trim: CGFloat)
        /// SF Symbol 하나 (`Image(systemName:).font(.system(size:))` 와 같은 크기).
        case symbol(name: String, size: CGFloat, color: Color)
    }

    let content: Content
    /// 한 바퀴 도는 시간 (초).
    let period: Double

    func makeNSView(context: Context) -> SpinningLayerView { SpinningLayerView() }

    func updateNSView(_ view: SpinningLayerView, context: Context) {
        view.configure(content: content, period: period)
    }
}

/// `SpinningLayer` 의 AppKit 쪽. 레이어를 직접 가진다 (layer-hosting) — 가운데를 축으로 도는 층 하나에 링이나 기호를 그린다.
final class SpinningLayerView: NSView {
    private let spinner = CALayer()
    private let ring = CAShapeLayer()
    private var content: SpinningLayer.Content?
    private var period: Double = 1
    private static let animationKey = "spin"

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        ring.fillColor = nil
        ring.lineCap = .round
        spinner.addSublayer(ring)
        layer?.addSublayer(spinner)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 누르기 · 포인터는 뒤의 SwiftUI (버튼) 가 받는다.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(content: SpinningLayer.Content, period: Double) {
        let restart = period != self.period
        self.period = period
        if content != self.content {
            self.content = content
            applyContent()
        }
        if restart { spinner.removeAnimation(forKey: Self.animationKey) }
        startSpinning()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinner.bounds = CGRect(origin: .zero, size: bounds.size)
        spinner.position = CGPoint(x: bounds.midX, y: bounds.midY)
        ring.frame = spinner.bounds
        applyContent()
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyContent()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyContent()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startSpinning() }
    }

    /// 시계 방향으로 끝없이 돈다. 이미 돌고 있으면 그대로 둔다 (다시 그릴 때마다 처음 각도로 튀지 않게).
    private func startSpinning() {
        guard spinner.animation(forKey: Self.animationKey) == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0.0
        // 뒤집히지 않은 레이어 좌표에서는 음의 각이 시계 방향이다.
        spin.toValue = -2 * Double.pi
        spin.duration = period
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        spinner.add(spin, forKey: Self.animationKey)
    }

    /// 색은 이 뷰의 모양(라이트 · 다크)으로 풀어 넣는다 — Theme 색은 모양에 따라 바뀌는 NSColor 다.
    private func applyContent() {
        guard let content else { return }
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinner.contentsScale = scale
        ring.contentsScale = scale
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // 지금 모양으로 푼 고정 색 (레이어는 모양이 바뀌어도 스스로 다시 풀지 않는다 — `viewDidChangeEffectiveAppearance`).
            func resolved(_ color: Color) -> NSColor { NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color) }
            switch content {
            case .ring(let color, let lineWidth, let trim):
                spinner.contents = nil
                ring.isHidden = false
                ring.path = CGPath(ellipseIn: CGRect(origin: .zero, size: bounds.size), transform: nil)
                ring.lineWidth = lineWidth
                ring.strokeEnd = trim
                ring.strokeColor = resolved(color).cgColor
            case .symbol(let name, let size, let color):
                ring.isHidden = true
                let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [resolved(color)]))
                let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration)
                spinner.contentsGravity = .center
                spinner.contents = image?.layerContents(forContentsScale: scale)
            }
        }
        CATransaction.commit()
    }
}

// MARK: - 검색 필드

/// 27pt 흰 검색 필드 (대화 검색, 파일 찾기).
struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var systemImage = "magnifyingglass"
    var shortcut: String?
    /// 테두리 없는 채움 칸 (사이드바). 포커스는 채움이 조금 짙어지는 것으로만 보인다.
    var plain = false
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(Theme.slate2)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.ui(.callout))
                .foregroundStyle(Theme.ink2)
                .focused(focus)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.control)
                }
                .buttonStyle(.plain)
                .help("지우기")
                .accessibilityLabel("검색어 지우기")
            } else if let shortcut {
                KeyHint(shortcut)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: plain ? 26 : 27)
        .background(plain ? (focus.wrappedValue ? Theme.hair : Theme.well) : Theme.card,
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            if !plain {
                RoundedRectangle(cornerRadius: 7).strokeBorder(focus.wrappedValue ? Theme.slate3 : Theme.hair)
            }
        }
    }
}

// MARK: - 빈 상태

/// 인스펙터·스트림의 조용한 빈 상태. 아이콘 + 한 줄 + 설명.
struct QuietEmptyState: View {
    let systemImage: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Theme.slate3)
            Text(title)
                .font(Theme.ui(.callout, .semibold))
                .foregroundStyle(Theme.ink2)
            if let detail {
                Text(detail)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
