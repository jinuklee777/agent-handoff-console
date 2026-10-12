import CoreGraphics

/// 대화 스트림이 맨 아래를 따라갈지의 **순수 판정** (SwiftUI 없이 — 검증 하네스가 컴파일한다).
///
/// 사람이 위로 한 번이라도 올리면 그 자리에서 따라가기를 멈추고, 맨 아래까지 다시 내리면 다시 따라간다.
/// 예전에는 스크롤이 멈출 때만 "맨 아래 120pt 안" 이면 다시 따라가게 했다 — 휠 한 칸(40pt)씩 올리면 매번 그 안이라,
/// 응답이 흐르는 동안 위로 올려도 곧바로 끌려 내려왔다.
/// 멈추는 신호는 사람의 것만이다: 휠 · 트랙패드로 위로 굴린 이벤트(`StreamScrollIntent` — 화면이 움직이기 전에)와, 사람이 스크롤하는
/// 동안(SwiftUI 의 스크롤 단계가 interacting 등 — 스크롤 막대)의 위로 움직임. 앱이 내리는 스크롤 · 글이 늘어 밀린 자리도 위로 튈 수
/// 있어(애니메이션이 늘기 전 자리에서 시작했다), 그것까지 보면 응답이 흐르는 첫 초에 따라가기가 꺼져 사람이 직접 내려야 했다.
/// 스크롤 단계만으로도 모자랐다 — 앱의 스크롤이 처리되는 중에 휠이 오면 단계가 자리 변화보다 먼저 끝났다
/// (2026-10-06 실측 — 미리보기 `-preview.action stream` · `-preview.wheel`).
enum StreamFollow {
    /// 스크롤 뷰의 세로 자리 (`ScrollGeometry` 에서 — `ThreadView`).
    struct Spot: Equatable {
        var offset: CGFloat
        var contentHeight: CGFloat
        var containerHeight: CGFloat

        /// 맨 아래까지 남은 거리. 내용이 칸보다 짧으면 0 이하.
        var distanceFromBottom: CGFloat { contentHeight - (offset + containerHeight) }
    }

    /// 이만큼 안이면 맨 아래로 본다. 휠의 가장 느린 한 칸(0.1줄 = 4pt)보다 작아야 한 칸만 올려도 멈춘다.
    static let bottomTolerance: CGFloat = 2

    /// 자리가 바뀌었을 때 따라가기를 어떻게 할지 — nil 이면 그대로 둔다.
    /// - 맨 아래면 따라간다 (끝까지 내렸다 · 트랙패드가 튕겨 맨 아래로 돌아왔다 · 내용이 줄어 맨 아래에 닿았다).
    /// - 사람이 스크롤하는 중에 위로 움직였으면 멈춘다. 내용이 줄거나(접기) 칸이 커져서 밀려 올라간 것은 빼다.
    /// - 그 밖(아래 글이 늘었다 · 아래로 내리는 중 · 앱이 움직였다)은 그대로.
    static func follow(from old: Spot, to new: Spot, userScrolling: Bool) -> Bool? {
        if new.distanceFromBottom <= bottomTolerance { return true }
        guard userScrolling else { return nil }
        let movedUp = new.offset < old.offset - 0.5
            && new.contentHeight >= old.contentHeight - 0.5
            && new.containerHeight <= old.containerHeight + 0.5
        return movedUp ? false : nil
    }

    /// 따라가는 중인데 맨 아래에서 밀려났으면(글 · 행 · 카드가 늘었다 · 칸이 줄었다) 다시 내린다. 사람이 스크롤하는 동안은 손대지 않는다.
    static func needsPin(following: Bool, userScrolling: Bool, at spot: Spot) -> Bool {
        following && !userScrolling && spot.distanceFromBottom > bottomTolerance
    }
}
