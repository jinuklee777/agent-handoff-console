import CoreGraphics

/// 글자 4단계 (B 방향, 2026-10-01). 화면의 글자는 이 넷 중 하나다 — 흐린 10~11pt 글자를 두지 않는다.
/// SF Symbol 아이콘 크기는 여기에 들지 않는다. 쓰는 곳은 `Theme.ui(_:_:)` · `Theme.mono(_:_:)` · `Theme.digits(_:_:)`.
/// SwiftUI 에 의존하지 않아 검증 하네스(Markdown 높이)도 같은 값을 쓴다. 숫자 크기가 다시 들어오지 않게
/// `inttest offline` 의 "글자 4단계" 검사가 UI 소스를 훑는다 (`scripts/inttest/TypeScaleLintTests.swift`).
enum TypeScale: CaseIterable, Sendable {
    /// 11.5 — 메타 · 라벨 · 안내 · 배지 · 수 · 시각 · 바닥글. SF Mono 로는 줄 안의 명령 · 경로 · 해시.
    case caption
    /// 12.5 — 조작(칩 · 단추) · 목록 행 · 칸 머리 · 보조 본문. SF Mono 로는 코드 본문(Markdown 코드 · 넓은 diff · 승인 명령).
    case callout
    /// 14 — 대화 본문 · 입력창 · 머리글(semibold).
    case body
    /// 20 — 화면 제목.
    case title

    var size: CGFloat {
        switch self {
        case .caption: return 11.5
        case .callout: return 12.5
        case .body: return 14
        case .title: return 20
        }
    }
}
