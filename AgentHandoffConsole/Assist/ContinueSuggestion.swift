import Foundation

// 한도 임박 "이어 가기" 제안 줄 (B 설계 C4) — 순수 판정. 화면 · 실행기 · 저장을 모른다.
// 의미는 어디서나 **사용률**이다 (남은 양이 아니다). 모르는 것은 제안하지 않는다.

/// 한도 창의 길이 종류. 24시간보다 짧으면 짧은 창(5시간 · 현재 세션), 아니면 긴 창(7일 · 이번 주). 길이를 모르면 긴 창으로 본다
/// (긴 창의 문턱이 더 높아 조용한 쪽으로 틀린다).
enum LimitSpan: String, Hashable, Sendable {
    case short, long

    static func of(_ window: LimitWindow) -> LimitSpan {
        guard let minutes = window.spanMinutes else { return .long }
        return minutes < 24 * 60 ? .short : .long
    }

    /// 이 길이의 창에서 제안을 시작하는 사용률.
    var threshold: Double { self == .short ? 0.75 : 0.90 }
}

/// 받는 쪽 후보 하나 — 자동 인계 대상 순서(`AutomaticHandoffTargets`)대로 넘긴다.
struct ContinueSuggestionTarget: Sendable {
    var agent: HandoffSource.Agent
    var title: String
    var cliUsable: Bool
    /// 로그인이 확인됐다 (Claude 는 30분 안에 확인한 것).
    var authenticated: Bool
    var limit: LimitSnapshot
    /// 로그인 사실이 오래됐다 (확인한 지 30분이 넘었거나 아직 확인하지 않았다) — 모름. 건너뛰지 않고 다시 확인할 곳으로 알린다
    /// (사람이 정한 순서를 지킨다). 확인된 "로그인 안 됨" · 방금 확인한 "모름" 은 오래된 것이 아니다 (건너뛴다).
    var loginStale: Bool = false
    /// 한도가 오래됐을 때 앱이 스스로 새로 읽어도 되나 — Claude 는 설정 "앱 시작 시 Claude 한도 조회" 를 따른다 (`claude -p /usage`
    /// 가 훅 · MCP 까지 도는 세션이라). 읽지 못하는 대상의 오래된 한도는 기다리지 않고 건너뛴다 (영영 다음 순서를 막지 않게).
    var limitRefreshable: Bool = true
    /// 로그인 "모름" — 확인 명령이 답하지 못했거나 파일이 아닌 자격 저장소다 (점검표의 `AgentReadiness.loginUnknown`). 막지 않는다:
    /// 로그인된 것처럼 고르되 고른 결과에 그 사실을 붙인다 (카드의 받는 쪽 줄이 "로그인 확인 안 됨" 이라 말하고 사람이 넘긴다).
    var loginUnknown: Bool = false
    /// 받을 수 없다고 **확인됐다** — CLI 설치 안 됨 · 실행 불가 · 로그인 안 됨. 한도 줄의 대비책도 고르지 않는다.
    var knownUnusable: Bool = false
    /// 이 대화의 API 크레딧으로 받는 Claude 다 (그 대화가 "API 크레딧으로 실행" — `AppModel.usesClaudeAPI`): 구독 로그인 · 구독 한도를
    /// 보지 않는다 (`AutomaticHandoffGate.targetProblems(usesAPICredit:)`). 크레딧 잔액은 읽을 수 없어 여유가 있는 것으로 본다.
    var apiCredit: Bool = false
}

/// 제안 줄을 숨기는 사실 (`AppModel.continueSuggestionHiddenReason`) — 앞에서부터 본다.
enum ContinueSuggestionHidden: Equatable, Sendable {
    /// 자동 작업의 내부 대화.
    case internalThread
    /// 끝나지 않은 자동 작업의 부모 대화.
    case orchestration
    /// 입력창에서 "자동" 을 골랐다.
    case autoSelected
    /// 실행이 돈다 (시작 중 포함).
    case running
    /// 인계 카드가 있다 (준비 · 전달 중 · 버린 준비의 "다시 만들기" 포함).
    case handoff
    /// 포커스 칸의 대화가 아니다.
    case notFocused
    /// 마지막 메인 이벤트가 한도 안내다 — 그 줄이 인계를 권한다.
    case limitNotice
}

struct ContinueSuggestionInput: Sendable {
    /// 입력창 칩.
    var chip: HandoffSource.Agent
    /// 이 대화에서 마지막으로 일한 에이전트 (`HandoffSource.resolve`) — 인계의 보내는 쪽.
    var source: HandoffSource.Agent
    /// 메인 흐름의 실행이 있다 (없으면 넘길 맥락이 없다 — 칩만 바꾸면 된다).
    var hasWorkedRuns: Bool
    /// 줄을 숨길 사실이 있다 (`ContinueSuggestionHidden`): 내부 대화 · 끝나지 않은 자동 작업 · "자동" 선택 · 실행 중 ·
    /// 인계 카드/준비/전달 중 · 포커스 칸이 아님 · 마지막 메인 이벤트가 한도 안내(그때는 한도 줄이 인계를 권한다).
    var hidden: Bool
    var sourceLimit: LimitSnapshot?
    var targets: [ContinueSuggestionTarget]
    var dismissals: [ContinueSuggestion.DismissKey: ContinueSuggestion.Dismissal] = [:]
    var now: Date
    /// 보내는 쪽 Claude 를 이 대화는 API 크레딧으로 실행한다 — 구독 사용률은 이 대화와 무관하다 (제안하지 않는다).
    var sourceUsesAPI: Bool = false
    /// [API 크레딧으로 계속] 을 권할 수 있다 (`ClaudeAPIContinue.offer` 가 `.available`) — 이어 맡길 대상이 없어도 제안을 낸다
    /// (Claude 만 쓰는 Max 사용자).
    var apiCreditAvailable: Bool = false
}

struct ContinueSuggestion: Equatable, Sendable {
    /// 확인한 지 이보다 오래된 한도는 쓰지 않는다 (보내는 쪽 · 받는 쪽 모두).
    static let freshness: TimeInterval = 30 * 60
    /// "나중에" 뒤 다시 보일 때까지.
    static let dismissalLifetime: TimeInterval = 5 * 60 * 60
    /// "나중에" 를 누른 뒤에도 이 사용률을 넘어서면 다시 보인다.
    static let higherBand = 0.90

    /// "나중에" 는 계정(scope)과 창 길이 종류로 기억한다 — 창 이름은 출처마다 달라("현재 세션" ↔ "5시간") 열쇠가 될 수 없다.
    struct DismissKey: Hashable, Sendable {
        var scope: AgentScope
        var span: LimitSpan
    }

    struct Dismissal: Equatable, Sendable {
        var utilization: Double
        var at: Date
        var resetsAt: Date?
    }

    var source: HandoffSource.Agent
    var sourceScope: AgentScope
    var window: LimitWindow
    var span: LimitSpan
    var utilization: Double
    /// 이어 맡길 대상 — 없으면(nil) [API 크레딧으로 계속] 만 권한다 (`offersAPICredit`).
    var target: HandoffSource.Agent?
    var targetTitle: String
    /// 받는 쪽의 로그인이 "모름" 이다 — 권하되 그 사실을 함께 말한다.
    var targetLoginUnknown = false
    /// [API 크레딧으로 계속] 도 권한다 (`ClaudeAPIContinue` — 같은 Claude 세션, 인계가 아니다).
    var offersAPICredit = false
    var key: DismissKey { DismissKey(scope: sourceScope, span: span) }

    /// 판단하지 못한 대상 — 새로 읽을 곳 (`AppModel.refreshStaleContinueTargets`).
    struct Stale: Equatable, Hashable, Sendable {
        /// 한도가 오래된 대상 — 강제 아닌 한도 새로 읽기.
        var limits: [AgentScope] = []
        /// 로그인 사실이 오래된 대상 — 로그인만 다시 확인 (Claude 의 `claude auth status`).
        var logins: [AgentScope] = []
        var isEmpty: Bool { limits.isEmpty && logins.isEmpty }
    }

    struct Evaluation: Equatable, Sendable {
        var suggestion: ContinueSuggestion?
        /// 보내는 쪽은 제안 조건을 채웠는데 받는 쪽의 한도 · 로그인이 오래돼 판단할 수 없는 후보 — 새로 읽기를 부를 곳.
        var stale = Stale()
    }

    /// 대상 하나를 순서대로 볼 때의 상태.
    enum TargetState: Equatable, Sendable {
        /// 대상이 아니다 (Antigravity · CLI 없음 · 로그인 안 됨 · 방금 확인한 모름 · 앱이 읽지 않는 오래된 한도).
        case skip
        /// 판단하지 못했다 — 이것부터 새로 읽는다 (뒤 대상으로 건너뛰지 않는다).
        case stale(Stale)
        /// 사실이 30분 안의 것이다 — 한도 여유는 부른 쪽이 본다.
        case known
    }

    static func state(of target: ContinueSuggestionTarget, now: Date) -> TargetState {
        // Antigravity 는 이어 받는 대상이 아니다 — 한도는 읽지만(`agy -p /usage`) v0.1 은 보이기만 한다 (사용자 결정 2026-10-09,
        // 자동 인계 순서와 같다). 새로 읽을 곳도 아니다.
        guard target.agent.provider != .gemini, target.cliUsable else { return .skip }
        // API 크레딧으로 받는 Claude 는 구독 로그인 · 구독 한도를 보지 않는다 — 새로 읽을 것이 없다.
        if target.apiCredit { return .known }
        // 로그인 "모름" 은 확인된 것처럼 본다 (점검표의 황색 통과) — "로그인 안 됨" 이 확인된 대상만 건너뛴다.
        guard target.authenticated || target.loginUnknown || target.loginStale else { return .skip }
        let limitStale = !isFresh(target.limit, now: now)
        if limitStale && !target.limitRefreshable { return .skip }
        guard limitStale || target.loginStale else { return .known }
        let scope = scope(of: target.agent)
        return .stale(Stale(limits: limitStale ? [scope] : [], logins: target.loginStale ? [scope] : []))
    }

    static func scope(of agent: HandoffSource.Agent) -> AgentScope {
        switch agent.provider {
        case .claude: return .claude
        case .gemini: return .gemini
        case .codex: return .codex(agent.codexAccountID ?? "")
        }
    }

    static func isFresh(_ snapshot: LimitSnapshot, now: Date) -> Bool {
        guard let fetchedAt = snapshot.fetchedAt else { return false }
        return now.timeIntervalSince(fetchedAt) <= freshness
    }

    /// 계정 전체 창 중 사용률을 아는 것의 최댓값 (모델 하나의 한도는 빼고). 모르면 nil.
    static func accountWidePeak(_ snapshot: LimitSnapshot, now: Date) -> Double? {
        snapshot.windows
            .filter { $0.model == nil && ($0.resetsAt.map { $0 > now } ?? true) }
            .compactMap(\.utilization).max()
    }

    /// 대상이 받을 수 있고 보내는 쪽보다 여유가 있다 — CLI · 로그인 · 한도(구독 한도에 닿지 않음) + 계정 전체 사용률이 제안 문턱
    /// 아래이고 보내는 쪽보다 낮다. API 크레딧으로 받는 Claude 는 CLI 만.
    static func hasRoom(_ target: ContinueSuggestionTarget, sourcePeak: Double, now: Date) -> Bool {
        let problems = AutomaticHandoffGate.targetProblems(cliUsable: target.cliUsable,
                                                           authenticated: target.authenticated || target.loginUnknown,
                                                           limit: target.limit, usesAPICredit: target.apiCredit)
        guard problems.isEmpty else { return false }
        if target.apiCredit { return true }
        guard let peak = accountWidePeak(target.limit, now: now) else { return false }
        return peak < LimitSpan.short.threshold && peak < sourcePeak
    }

    static func evaluate(_ input: ContinueSuggestionInput) -> Evaluation {
        guard !input.hidden, input.hasWorkedRuns, input.chip == input.source, !input.sourceUsesAPI,
              let limit = input.sourceLimit, limit.status == .ok, !limit.reachedAccountWideCap,
              isFresh(limit, now: input.now) else { return Evaluation() }

        // 문턱을 넘은 계정 전체 창 — 초기화가 지난 창 · "나중에" 가 아직 걸린 길이의 창은 뺀다 (5시간을 미뤄도 7일이 90% 를
        // 넘으면 그것은 보인다). 여럿이면 문턱을 가장 많이 넘은 것, 같으면 짧은 창.
        let sourceScope = scope(of: input.source)
        let crossing = limit.windows.compactMap { window -> (LimitWindow, LimitSpan, Double)? in
            guard window.model == nil, let used = window.utilization else { return nil }
            if let reset = window.resetsAt, reset <= input.now { return nil }
            let span = LimitSpan.of(window)
            guard used >= span.threshold else { return nil }
            if let dismissal = input.dismissals[DismissKey(scope: sourceScope, span: span)],
               !dismissalExpired(dismissal, used: used, now: input.now) { return nil }
            return (window, span, used)
        }
        func rank(_ item: (LimitWindow, LimitSpan, Double)) -> (Double, Int) {
            (item.2 - item.1.threshold, item.1 == .short ? 1 : 0)
        }
        guard let (window, span, used) = crossing.max(by: { rank($0) < rank($1) }) else { return Evaluation() }

        let sourcePeak = accountWidePeak(limit, now: input.now) ?? used
        var stale = Stale()
        var chosen: ContinueSuggestionTarget?
        search: for target in input.targets where target.agent != input.source {
            switch state(of: target, now: input.now) {
            case .skip: continue
            // 순서상 앞선 대상의 한도 · 로그인이 오래됐으면 뒤 대상을 권하지 않고 그것부터 새로 읽는다 (사람이 정한 순서를 지킨다).
            case .stale(let found):
                stale = found
                break search
            case .known: break
            }
            guard hasRoom(target, sourcePeak: sourcePeak, now: input.now) else { continue }
            chosen = target
            break search
        }
        // 이어 맡길 대상이 없어도(판단하지 못한 대상을 새로 읽는 동안 포함) API 크레딧으로 계속할 수 있으면 그것만 권한다.
        guard chosen != nil || input.apiCreditAvailable else { return Evaluation(suggestion: nil, stale: stale) }
        return Evaluation(suggestion: ContinueSuggestion(
            source: input.source, sourceScope: sourceScope, window: window, span: span, utilization: used,
            target: chosen?.agent, targetTitle: chosen?.title ?? "",
            targetLoginUnknown: chosen.map { !$0.authenticated && $0.loginUnknown } ?? false,
            offersAPICredit: input.apiCreditAvailable), stale: stale)
    }

    // MARK: 한도 도달 줄의 받는 쪽

    /// 한도 도달 줄(`AlertRow`)의 받는 쪽: 이어 갈 대상 순서에서 보내는 쪽을 빼고 CLI · 로그인 · 한도 여유(한도에 닿지 않음)가
    /// 30분 안에 확인된 첫 대상. 앞 순서 대상의 로그인 · 한도가 오래됐으면 뒤 대상으로 건너뛰지 않고 정하지 않은 채(`target` nil)
    /// 그것을 새로 읽을 곳으로 알린다 — 그동안은 대비책(`fallback`)을 쓴다. 제안과 달리 사용률 문턱은 보지 않는다 (보내는 쪽은 이미 다 찼다).
    struct LimitLineChoice: Equatable, Sendable {
        var target: HandoffSource.Agent?
        var stale = Stale()
        /// 고른 대상의 로그인이 "모름" 이다 (권하되 그 사실을 말한다).
        var loginUnknown = false
    }

    static func limitLineChoice(_ targets: [ContinueSuggestionTarget], source: HandoffSource.Agent, now: Date) -> LimitLineChoice {
        for target in targets where target.agent != source {
            switch state(of: target, now: now) {
            case .skip: continue
            case .stale(let stale): return LimitLineChoice(target: nil, stale: stale)
            case .known:
                guard AutomaticHandoffGate.targetProblems(cliUsable: target.cliUsable,
                                                          authenticated: target.authenticated || target.loginUnknown,
                                                          limit: target.limit, usesAPICredit: target.apiCredit).isEmpty else { continue }
                return LimitLineChoice(target: target.agent, loginUnknown: !target.authenticated && target.loginUnknown)
            }
        }
        return LimitLineChoice(target: nil)
    }

    /// 확인된 대상을 정하지 못했을 때(아무도 여유가 확인되지 않았거나 앞 순서를 새로 읽는 중) 한도 줄이 권해 볼 대상 — 받을 수 없다고
    /// **확인된** 것(설치 안 됨 · 실행 불가 · 로그인 안 됨 · 방금 확인한 한도 도달)은 권하지 않는다 (hnd-1). `preferred`(반대편 —
    /// 이 대화의 Codex 계정)가 받을 수 있으면 그것, 아니면 순서에서 처음으로 받을 수 있는 것. 없으면 nil — 권할 대상이 없다.
    /// 확인하지 못한 대상이므로 한도 줄은 단정하지 않고 "받는 쪽 상태 미확인" 이라 말한다.
    static func limitLineFallback(_ targets: [ContinueSuggestionTarget], source: HandoffSource.Agent,
                                  preferred: HandoffSource.Agent?, now: Date) -> HandoffSource.Agent? {
        func acceptable(_ target: ContinueSuggestionTarget) -> Bool {
            guard target.agent != source, target.agent.provider != .gemini, !target.knownUnusable else { return false }
            if target.apiCredit { return true }
            let capped = target.limit.status == .subscriptionCap || target.limit.status == .throttled || target.limit.reachedAccountWideCap
            return !(capped && isFresh(target.limit, now: now))
        }
        if let preferred, let match = targets.first(where: { $0.agent == preferred }), acceptable(match) { return preferred }
        // 대상 목록에 없는 반대편(목록을 아직 읽지 않음)은 받을 수 없다고 확인된 것이 아니다.
        if let preferred, preferred != source, !targets.contains(where: { $0.agent == preferred }) { return preferred }
        return targets.first(where: acceptable)?.agent
    }

    /// 한도 줄이 권할 받는 쪽이 하나도 없을 때의 까닭 — 문장과 단추가 따른다 (hand-4 · set-n4: 예전에는 늘 "다른 에이전트를 설치하거나
    /// 로그인하면 …" 과 [시작 점검 열기] 였다 — 설정 > 인계에서 "받지 않음" 으로 뺐거나 받는 쪽도 한도일 때 엉뚱한 곳을 가리켰다).
    enum LimitLineEmpty: Equatable, Sendable {
        /// 받을 수 있는 에이전트를 설정 > 인계의 이어 받을 순서에서 뺐다 ("받음" 을 끔) — 이름들. [인계 설정 열기] · 입력창의 에이전트
        /// 메뉴로는 직접 이어 맡길 수 있다.
        case excluded([String])
        /// 다른 에이전트도 방금 확인한 한도에 닿았다 — 이름들과 가장 이른 초기화 시각(모르면 nil). 단추 없이 기다린다.
        case capped([String], resetsAt: Date?)
        /// 다른 에이전트를 쓸 수 없다 (설치 안 됨 · 실행 불가 · 로그인 안 됨) — [시작 점검 열기].
        case unavailable
    }

    /// 권할 받는 쪽이 없는 까닭 (`limitLineFallback` 이 nil 일 때 부른다): 앞에서부터 — "받지 않음" 으로 뺀 대상 가운데 받을 수 있는 것이
    /// 있다(설치 · 실행 · 로그인이 막혔다고 확인되지 않았고 방금 한도에 닿지도 않음) → 다른 대상이 방금 확인한 한도에 닿았다 → 쓸 수 없다.
    /// `excluded` 는 이어 받을 순서에서 "받지 않음" 으로 둔 대상들 (`targets` 와 같은 사실). Antigravity 는 대상이 아니다.
    static func limitLineEmpty(_ targets: [ContinueSuggestionTarget], excluded: [ContinueSuggestionTarget],
                               source: HandoffSource.Agent, now: Date) -> LimitLineEmpty {
        func considered(_ target: ContinueSuggestionTarget) -> Bool {
            target.agent != source && target.agent.provider != .gemini && !target.knownUnusable
        }
        func capped(_ target: ContinueSuggestionTarget) -> Bool {
            guard !target.apiCredit else { return false }
            let limit = target.limit
            return (limit.status == .subscriptionCap || limit.status == .throttled || limit.reachedAccountWideCap) && isFresh(limit, now: now)
        }
        let usableExcluded = excluded.filter { considered($0) && !capped($0) }
        if !usableExcluded.isEmpty { return .excluded(usableExcluded.map(\.title)) }
        let cappedTargets = (targets + excluded).filter { considered($0) && capped($0) }
        if !cappedTargets.isEmpty {
            let resets = cappedTargets.compactMap { $0.limit.capResetsAt(now: now) }
            return .capped(cappedTargets.map(\.title), resetsAt: resets.min())
        }
        return .unavailable
    }

    /// 받는 쪽이 없을 때 한도 줄의 문장 — 이름을 끼워 넣는 조사는 받침과 무관한 꼴("에게" · "도").
    static func limitLineEmptyText(_ empty: LimitLineEmpty, now: Date = Date()) -> String {
        switch empty {
        case .excluded(let names):
            return "이어 받을 에이전트가 없습니다 — \(names.joined(separator: ", ")) 에게는 설정 > 인계에서 이어 맡기지 않게 해 두었습니다. "
                + "입력창의 에이전트 메뉴로는 직접 이어 맡길 수 있습니다."
        case .capped(let names, let resetsAt):
            let reset = resetsAt.map { " (\(HandoffCardText.resetClock($0, now: now)) 초기화)" } ?? " (초기화 시각 미확인)"
            return "이어 받을 에이전트가 없습니다 — \(names.joined(separator: ", ")) 도 사용 한도에 닿았습니다" + reset + "."
        case .unavailable:
            return "이어 받을 에이전트가 없습니다 — 다른 에이전트를 설치하거나 로그인하면 이어 맡길 수 있습니다."
        }
    }

    /// "나중에" 가 끝났나: 더 높은 구간을 넘었거나, 그 창이 초기화됐거나(미룰 때의 초기화 시각이 지났다), 오래 지났다.
    /// 지금 창의 `resetsAt` 과 비교하지 않는다 — Codex 는 같은 창의 초기화 시각을 1초씩 다르게 보낸다 (실측 c3 · c11).
    static func dismissalExpired(_ dismissal: Dismissal, used: Double, now: Date) -> Bool {
        if dismissal.utilization < higherBand && used >= higherBand { return true }
        if let reset = dismissal.resetsAt, now >= reset { return true }
        return now.timeIntervalSince(dismissal.at) >= dismissalLifetime
    }

    // MARK: 화면 글 — 문장 하나 = 형식 하나, 조사는 이름에 따라 바뀌지 않게

    var percentText: String { "\(Int((utilization * 100).rounded()))%" }

    /// 창 이름 — 길이를 알면 길이로("5시간" · "7일"), 모르면 출처의 이름. 같은 창이 출처에 따라 "현재 세션"(/usage) · "5시간"
    /// (rate_limit_event)으로 바뀌지 않게 — "현재 세션" 은 지금 대화의 사용량으로 읽히기도 한다.
    static func windowName(of window: LimitWindow) -> String {
        guard let minutes = window.spanMinutes, minutes > 0 else { return window.label }
        if minutes % 1440 == 0 { return "\(minutes / 1440)일" }
        if minutes % 60 == 0 { return "\(minutes / 60)시간" }
        return window.label
    }

    var windowName: String { Self.windowName(of: window) }

    /// "Claude 5시간 사용률 81% · 20:30 초기화" / "… · 초기화 시각 미확인".
    func headline(sourceName: String, resetText: String?) -> String {
        if let resetText {
            return "\(sourceName) \(windowName) 사용률 \(percentText) · \(resetText) 초기화"
        }
        return "\(sourceName) \(windowName) 사용률 \(percentText) · 초기화 시각 미확인"
    }

    /// 좁은 칸의 짧은 글 — "Claude 5시간 사용률 81%" (제안으로 연 카드의 접힌 머리와 같은 말).
    func shortHeadline(sourceName: String) -> String {
        "\(sourceName) \(windowName) 사용률 \(percentText)"
    }

    /// 가장 좁을 때 — "사용률 81%" (보내는 쪽은 옆의 로고가, 창 이름 · 초기화 시각은 도움말이 말한다). 수는 잘리지 않게.
    var usageText: String { "사용률 \(percentText)" }

    /// 이어 갈 대상이 같은 Codex 의 다른 계정이다 — 인계 카드가 아니라 계정만 바꾼다 (`CodexAccountSwitch`).
    var switchesCodexAccount: Bool { target.map { CodexAccountSwitch.isSwitch(from: source, to: $0) } ?? false }

    /// 단추 — "Codex 에게 이어 맡기기" (같은 Codex 의 다른 계정이면 "Codex · 계정 2 에서 이어 가기"). 이어 맡길 대상이 없으면(API 크레딧만
    /// 권함) nil.
    var actionTitle: String? {
        guard target != nil else { return nil }
        return switchesCodexAccount ? CodexAccountSwitch.title(name: targetTitle) : "\(targetTitle) 에게 이어 맡기기"
    }

    /// [나중에] 의 도움말 — 이 제안에서 실제로 일어날 수 있는 조건만 (`dismissalExpired`): 이미 더 높은 구간(90%)이면 그 조건이 없고,
    /// 초기화 시각을 모르면 초기화 조건이 없다. 경우마다 완결된 문장 하나.
    var laterHelp: String {
        let band = Int((Self.higherBand * 100).rounded())
        let hours = Int(Self.dismissalLifetime / 3600)
        // 한도 구간은 이름으로 ("5시간 한도" · "7일 한도") — "창" 은 앱 창과 헷갈렸다.
        let span = "이 계정의 \(windowName) 한도는"
        switch (utilization < Self.higherBand, window.resetsAt != nil) {
        case (true, true): return "\(span) 사용률이 \(band)% 를 넘거나 초기화되거나 \(hours)시간이 지나면 다시 알립니다"
        case (true, false): return "\(span) 사용률이 \(band)% 를 넘거나 \(hours)시간이 지나면 다시 알립니다"
        case (false, true): return "\(span) 초기화되거나 \(hours)시간이 지나면 다시 알립니다"
        case (false, false): return "\(span) \(hours)시간이 지나면 다시 알립니다"
        }
    }

    /// "나중에" 를 누른 기록 — 지금의 사용률 · 때 · 그 창의 초기화 시각 (그 시각이 지나면 다시 보인다).
    func dismissal(at now: Date) -> Dismissal {
        Dismissal(utilization: utilization, at: now, resetsAt: window.resetsAt)
    }
}
