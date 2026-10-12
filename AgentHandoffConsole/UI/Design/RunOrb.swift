import SwiftUI

/// 실행 중 상태 줄(`RunStatusLine`)의 도는 표시 — 하는 일(`RunActivity.Work`)마다 모양이 다른 점 구 (thinking-orbs 의 20pt 판).
///
/// 점의 모양은 옮겨 온 thinking-orbs 엔진(`ThinkingOrbs/` — ThinkingOrbsKit, MIT, 출처 · 커밋은 코드 구조 지도) 그대로이고,
/// 그리기는 SwiftUI 밖의 레이어(`OrbLayer`)가 한다 — 원본의 SwiftUI 뷰(`ThinkingOrb`)는 프레임마다 창 전체를 다시 배치했다.
/// 색은 흑백 한 가지(밝기 = 깊이)라 제공자 색을 입히지 않는다. 손쉬운 사용의 "동작 줄이기" 면 멈춘 한 장면만 그린다.
struct RunOrb: View {
    let work: RunActivity.Work
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OrbLayer(state: work.orbState, size: .px20, paused: reduceMotion || work == .stopping,
                 dark: colorScheme == .dark, frozenTime: Self.previewTime)
            .frame(width: OrbSize.px20.value, height: OrbSize.px20.value)
            .accessibilityHidden(true)
    }

    /// `-preview.orbTime <초>` (Debug) — 점 구를 그 엔진 시각에 멈춘다 (화면을 찍어 원본 렌더와 나란히 볼 때).
    private static let previewTime: Double? = {
        #if DEBUG
        guard UserDefaults.standard.object(forKey: "preview.orbTime") != nil else { return nil }
        return UserDefaults.standard.double(forKey: "preview.orbTime")
        #else
        return nil
        #endif
    }()
}

extension RunActivity.Work {
    /// 하는 일 → 점 구의 모양.
    var orbState: OrbState {
        switch self {
        case .thinking: return .solving                             // 띠가 섞였다가 맞춰진다 (원판의 고리 breathing 대신 — 2026-10-06 사용자 선택)
        case .stopping: return .breathing                           // 천천히 모양이 바뀌는 고리 — 멈추는 중은 한 장면만 그린다
        case .writing: return .connecting                           // 저절로 이어지는 별자리
        case .command, .tool: return .working                       // 기울어진 궤도를 도는 입자
        case .editing: return .shaping                              // 점 윤곽이 원 → 세모 → 네모
        case .searching: return .searching                          // 자오선이 훑는 점 지구
        case .fetching: return .composing                           // 물결치는 띠
        case .delegating, .waitingBackground: return .weaving       // 세 가닥이 구를 감아 엮인다
        case .planning: return .solving                             // 띠가 섞였다가 맞춰진다
        case .waitingOnPerson: return .listening                    // 고리를 지나는 파형 — 사람의 답을 기다린다
        }
    }
}
