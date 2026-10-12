import SwiftUI

// MARK: - 강도 이름

/// 칩 · 강도 목록의 강도 이름 (목업 boards_composer.py `effort_label()`).
/// 단계 글자색, MAX · ULTRA 는 번개 · 반짝임 글리프 + 굵은 글자. `shimmer` 는 칩의 MAX 불꽃 글자 (기존 `ShimmerText`) — 평소에는
/// 멈춘 그림이고, 막 골랐을 때(`animateShimmer`)만 잠깐 흐른다. 흐르는 동안은 매 프레임 다시 그리므로 늘 켜 두지 않는다 (chat-9).
struct EffortLabelView: View {
    let label: EffortScale.Label
    /// 칩 · 팝오버의 강도 목록은 callout.
    var step: TypeScale
    var shimmer = false
    /// 입력창의 글자만 있는 칩 안에서는 단계 색 · 굵기를 쓰지 않고 칩 글자색을 따른다 (MAX · ULTRA 는 그대로).
    var muted = false
    /// 불꽃 글자를 흐르게 한다 (MAX 를 막 골랐을 때 — 입력창이 몇 초만 켠다).
    var animateShimmer = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var size: CGFloat { step.size }

    var body: some View {
        HStack(spacing: 3) {
            if label.glyph != .none {
                // 목업 icon() 의 크기는 16 격자 SVG 상자라 그림은 그보다 작다 (번개 82% · 반짝임 69%).
                // SF Symbol 은 글꼴 크기만큼 그려지므로 비율로 줄여 번개는 대문자 높이, 반짝임은 그 약 0.8 에 맞춘다.
                Image(systemName: label.glyph == .bolt ? "bolt.fill" : "sparkle")
                    .font(.system(size: size * (label.glyph == .bolt ? 0.65 : 0.58), weight: .semibold))
                    .foregroundStyle(label.glyph == .bolt ? Theme.flameGlyph : Theme.ultraGlyph)
            }
            name
        }
        .fixedSize()
    }

    @ViewBuilder
    private var name: some View {
        let special = label.glyph != .none
        if special && shimmer && label.tier == .max {
            ShimmerText(text: label.text,
                        colors: [Theme.flame, Theme.flameAmber, Theme.flamePale, Theme.flameAmber, Theme.flame],
                        animate: animateShimmer && !reduceMotion)
                .font(Theme.ui(step, .bold))
                .tracking(size * 0.05)
        } else if muted && !special {
            Text(label.text).font(Theme.ui(step))
        } else {
            Text(label.text)
                .font(Theme.ui(step, special ? .bold : .semibold))
                .tracking(special ? size * 0.05 : (size >= 16 ? -size * 0.01 : 0))
                .foregroundStyle(label.tier.map(Theme.effortText) ?? Theme.slate)
        }
    }
}
