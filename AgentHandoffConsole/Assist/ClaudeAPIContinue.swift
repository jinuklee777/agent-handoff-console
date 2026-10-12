import Foundation

/// 구독 한도에 닿은(닿아 가는) Claude 대화를 **같은 Claude 세션** 그대로 API 크레딧(Max · Team 플랜의 월 API 크레딧)으로 이어 가기 —
/// 순수 판정과 글. 인계가 아니다: 받는 쪽도 그 대화의 Claude 이고, 같은 CLI 세션을 재개하며, 인계 문서가 없다. 앱은 그 대화의
/// "API 크레딧으로 실행" 을 켜고(`AppModel.setClaudeAPI`) 이어 가기 메시지 하나를 보낸다 (`AppModel.continueWithClaudeAPI`).
///
/// 단추는 한도 도달 줄(`AlertRow` — 켜고 이어 가기), 한도 인계 카드(`HandoffCardView` — 카드를 거두고 이어 가기), 한도 임박 제안 줄
/// (`ContinueSuggestionBar` — 대화가 멈추지 않았으므로 켜기만)에 있다. 키가 없으면 한도 줄에만 설정으로 가는 안내를 둔다.
///
/// 자동 인계의 이어 받을 순서에는 넣지 않는다 (2026-10-08 결정): 사람이 누르지 않은 크레딧 쓰기가 되고(조직에 산 크레딧 · 자동 충전이
/// 있으면 실제 청구), CLI 로 크레딧 잔액을 읽을 수 없어 자동 인계의 "받는 쪽 여유 확인" 을 채울 수 없다. 자동 인계의 카운트다운 카드는
/// 카운트다운을 바꾸지 않고 이 단추를 함께 보인다.
enum ClaudeAPIContinue {
    enum Offer: Equatable, Sendable {
        /// 보이지 않는다.
        case none
        /// [API 크레딧으로 계속].
        case available
        /// 키가 없다 — 설정 > 에이전트 > Claude Code 로 가는 안내 (한도 줄에만 — 제안 줄 · 카드는 조르지 않는다).
        case needsKey
    }

    /// - provider: 한도에 닿은(닿아 가는) 쪽의 제공자.
    /// - threadUsesAPI: 이 대화는 이미 API 크레딧으로 실행한다 (켜 두었고 키가 있다 — `AppModel.usesClaudeAPI`). 그러면 구독 한도는
    ///   이 대화와 무관하고, 그 한도 글은 API 쪽("usage limits" — 조직의 지출 한도)일 수 있어 같은 단추를 되풀이하지 않는다.
    /// - hasKey: 키가 저장돼 있다.
    /// - allowed: 사람이 이 대화에서 이어 갈 수 있다 (자동 작업의 내부 대화 · 끝나지 않은 자동 작업의 부모가 아니다).
    static func offer(provider: AgentProvider, threadUsesAPI: Bool, hasKey: Bool, allowed: Bool) -> Offer {
        guard provider == .claude, allowed, !threadUsesAPI else { return .none }
        return hasKey ? .available : .needsKey
    }

    /// 이어 가기 전에 대기열의 멈춤 이유를 지울까 — 이어 가기 전의 이유가 없었거나(인계 카드가 보류해 두었다 — 카드를 거두면 생기는
    /// "인계를 취소했습니다" 도 이것) 한도로 멈춘 것일 때. 이어 가기 실행이 정상으로 끝나면 걸어 둔 메시지가 이어서 간다.
    /// 그 밖의 이유(앱을 다시 켬 · 앞 보내기 실패 …)는 사람이 보고 이어서 보낸다.
    static func clearsQueuePause(before reason: String?) -> Bool {
        reason == nil || reason == QueueRules.pauseReason(after: .rateLimited)
    }

    // MARK: 글

    static let title = "API 크레딧으로 계속"
    /// 이어 가기 메시지 — 같은 세션이 재개되므로 앞의 요청과 한도로 멈춘 자리를 CLI 세션이 안다.
    static let prompt = "사용 한도로 멈춘 곳부터 이어서 진행하세요."

    /// 한도 도달 줄의 단추.
    static let limitHelp = "이 대화만 ‘\(ClaudeAPIKey.toggleTitle)’ 을 켜고 같은 Claude 세션에 이어서 하라고 보냅니다 — 인계하지 않습니다. "
        + "구독 한도 대신 Claude Console 조직의 API 크레딧(Max · Team 월 크레딧)에서 빠집니다."
    /// 인계 카드의 단추.
    static let cardHelp = "이 인계를 거두고, 이 대화만 ‘\(ClaudeAPIKey.toggleTitle)’ 을 켜 같은 Claude 세션으로 이어 갑니다 — "
        + "구독 한도 대신 API 크레딧에서 빠집니다."
    /// 한도 임박 제안 줄의 단추 — 대화가 멈추지 않았으므로 켜기만 한다.
    static let switchHelp = "이 대화만 ‘\(ClaudeAPIKey.toggleTitle)’ 을 켭니다 — 다음 메시지부터 같은 Claude 세션이 구독 한도 대신 "
        + "API 크레딧(Max · Team 월 크레딧)에서 빠집니다. 끄려면 모델 칩."
    /// 제안 줄에서 켠 뒤 입력창 위의 안내.
    static let switchedNote = "이 대화의 Claude 는 이제 API 크레딧으로 실행합니다 — 끄려면 모델 칩의 ‘\(ClaudeAPIKey.toggleTitle)’."

    /// 한도 줄의 권유 문장 — 인계 권유(`handoff`)에 API 크레딧을 잇는다. `handoffTargeted` — 인계 권유가 이어 맡길 대상을 말한다
    /// (아니면 "이어 받을 에이전트가 없습니다 …" 류의 까닭이다 — API 크레딧으로 이어 갈 수 있으면 그 까닭과 그 단추는 접는다).
    static func limitAdvice(handoff: String?, handoffTargeted: Bool, offer: Offer) -> String? {
        guard offer == .available else { return handoff }
        guard handoffTargeted, let handoff else { return "같은 Claude 세션을 API 크레딧으로 이어 갈 수 있습니다 (이 대화만)." }
        return "같은 Claude 세션을 API 크레딧으로 이어 가거나, " + handoff
    }

    /// 키가 없을 때 한도 줄의 안내 — 앱은 플랜을 모른다 (Pro 는 월 API 크레딧이 없다).
    static let needsKeyText = "Max · Team 플랜이면 API 키를 넣어 같은 Claude 세션을 API 크레딧으로 이어 갈 수 있습니다."
    static let addKeyTitle = "API 키 넣기…"
    static let addKeyHelp = "설정 > 에이전트 > Claude Code 에 Claude Console 조직의 API 키를 넣습니다"
}
