import Foundation

struct AutomaticHandoffGateInput: Sendable {
    var hasUnterminatedProcess: Bool
    var hasPendingDecision: Bool
    /// Gemini 정리를 기다리는 동안 사용자가 다른 실행을 시작했을 수 있다.
    var hasActiveRun: Bool = false
    /// 초안 기준점(baseSeq) 이후 사용자 메시지가 있으면 초안이 이미 낡았다.
    var userActedAfterDraft: Bool = false
    var hasUnknownPreviousDelivery: Bool
    var targetCLIUsable: Bool
    var targetAuthenticated: Bool
    var targetLimit: LimitSnapshot
    /// 받는 쪽이 이 대화의 API 크레딧으로 받는 Claude 다 (`targetProblems(usesAPICredit:)`).
    var targetUsesAPICredit: Bool = false
    var nextActions: [String]
    var geminiWasRequested: Bool
    /// Gemini 정리가 검증 경고 없이 끝났거나, 정리하지 못해 앱이 정리한 문서로 대신했다 (그 문서는 Gemini 를 쓰지 않는 사람이
    /// 자동으로 넘기는 것과 같다 — 막지 않는다). 막는 것은 정리했는데 검증 경고가 있는 경우뿐이다.
    var geminiSucceededWithoutWarnings: Bool
}

enum AutomaticHandoffGate {
    // 막는 까닭 — 카드의 검토 줄이 그대로 보인다. 받는 쪽은 카드 · 입력창과 같은 말 "받는 쪽" 으로 부른다.
    static let reasonUnterminated = "이전 프로세스 종료가 확인되지 않았습니다."
    static let reasonPendingDecision = "승인 또는 질문 응답이 남아 있습니다."
    static let reasonActiveRun = "다른 실행이 진행 중입니다."
    static let reasonUserActed = "초안을 만든 뒤 새 사용자 입력이 있습니다."
    static let reasonUnknownDelivery = "직전 인계의 전달 여부가 미확인입니다."
    static let reasonCLI = "받는 쪽 CLI 를 실행할 수 없습니다."
    static let reasonLogin = "받는 쪽 계정의 로그인이 확인되지 않았습니다."
    static let reasonCapped = "받는 쪽도 사용 한도에 도달했습니다."
    static let reasonLimitUnknown = "받는 쪽 한도 여유를 확인할 수 없습니다."
    static let reasonNoNextAction = "확인된 다음 행동이 없습니다."
    static let reasonGeminiWarnings = "Gemini 정리에 검증 경고가 있습니다."

    static func blockingReasons(_ input: AutomaticHandoffGateInput) -> [String] {
        var reasons: [String] = []
        if input.hasUnterminatedProcess { reasons.append(reasonUnterminated) }
        if input.hasPendingDecision { reasons.append(reasonPendingDecision) }
        if input.hasActiveRun { reasons.append(reasonActiveRun) }
        if input.userActedAfterDraft { reasons.append(reasonUserActed) }
        if input.hasUnknownPreviousDelivery { reasons.append(reasonUnknownDelivery) }
        reasons += targetProblems(cliUsable: input.targetCLIUsable,
                                  authenticated: input.targetAuthenticated, limit: input.targetLimit,
                                  usesAPICredit: input.targetUsesAPICredit)
        let actionable = input.nextActions.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.hasPrefix("미확인")
        }
        if !actionable { reasons.append(reasonNoNextAction) }
        if input.geminiWasRequested && !input.geminiSucceededWithoutWarnings {
            reasons.append(reasonGeminiWarnings)
        }
        return reasons
    }

    /// 인계 대상 하나를 받을 수 있는 상태인지. 대상 선택과 최종 게이트가 같은 기준을 쓴다.
    /// "정보 없음"은 여유가 있다는 뜻이 아니므로 후보에서 뺀다.
    /// `usesAPICredit` — 받는 쪽이 API 크레딧으로 받는 Claude 다 (사람이 이 대화를 "API 크레딧으로 실행" 으로 골랐다): 구독 로그인 ·
    /// 구독 한도와 무관하므로 CLI 만 본다. 크레딧 잔액은 CLI 로 읽을 수 없다 — 떨어졌으면 전달 실행이 "Credit balance too low" 로
    /// 실패하고 카드가 다시 보낼 수 있게 돌아온다 (한도 도달이 아니라 자동 인계를 다시 부르지 않는다).
    static func targetProblems(cliUsable: Bool, authenticated: Bool, limit: LimitSnapshot, usesAPICredit: Bool = false) -> [String] {
        var problems: [String] = []
        if !cliUsable { problems.append(reasonCLI) }
        if usesAPICredit { return problems }
        if !authenticated { problems.append(reasonLogin) }
        switch limit.status {
        case .subscriptionCap, .throttled:
            problems.append(reasonCapped)
        case .ok where limit.hasUsableData:
            // 모델 하나의 한도(Claude 의 Fable 주간 등)는 세지 않는다 — 다른 모델로는 받을 수 있다.
            if limit.reachedAccountWideCap {
                problems.append(reasonCapped)
            }
        default:
            problems.append(reasonLimitUnknown)
        }
        return problems
    }

    /// 검토 카드가 까닭마다 붙일 다음 행동의 종류 (hnd-10).
    enum ReasonKind: Equatable, Sendable {
        /// 받는 쪽의 한도 · 로그인 · CLI 를 확인하지 못했다 — [다시 확인] 으로 새로 읽는다.
        case receiverUnchecked
        /// 받는 쪽이 한도에 닿았다 — 받는 쪽을 바꾼다.
        case receiverCapped
        /// 다음 행동이 없다 — 덧붙일 말로 할 일을 적는다.
        case noNextAction
        /// 그 밖 (실행 중 · 승인 대기 · 새 입력 · 앞 인계 미확인 · Gemini 경고 · 제외 사유).
        case other
    }

    static func kind(of reason: String) -> ReasonKind {
        switch reason {
        case reasonCLI, reasonLogin, reasonLimitUnknown: return .receiverUnchecked
        case reasonCapped: return .receiverCapped
        case reasonNoNextAction: return .noNextAction
        default: return .other
        }
    }

    /// 자동 인계가 고를 받는 쪽이 하나도 없을 때의 안내 (hand-4): 이어 받을 순서에서 "받지 않음" 으로 뺀 에이전트 가운데 쓸 수 있는 것이
    /// 있으면 그 사실과 [인계 설정 열기], 아니면 다른 에이전트의 CLI 를 찾지 못했다는 사실과 [시작 점검 열기]. 예전에는 뺀 경우에도 늘
    /// "CLI 를 찾지 못했습니다" 였다. 이름을 끼워 넣는 조사는 받침과 무관한 꼴("에게는").
    static func noTargetNotice(excludedNames: [String]) -> (text: String, actionTitle: String, opens: SendReadiness.Destination) {
        guard excludedNames.isEmpty else {
            return ("자동으로 이어 맡길 에이전트가 없습니다 — \(excludedNames.joined(separator: ", ")) 에게는 설정 > 인계에서 "
                        + "이어 맡기지 않게 해 두었습니다.", "인계 설정 열기", .handoffSettings)
        }
        return ("자동으로 이어 맡길 에이전트가 없습니다 — 다른 에이전트의 CLI 를 찾지 못했습니다.", "시작 점검 열기", .firstRunCheck)
    }

    /// 넘겨도 되는지의 판단 기준 한 줄 — 막은 까닭이 모두 "앱이 확인하지 못한 것" 이면 사람이 넘길 수 있다고 말한다.
    /// 한도에 닿은 받는 쪽이 있으면 받는 쪽을 바꾸라고 한다. 그 밖에는 nil (까닭이 스스로 말한다).
    static func judgement(_ reasons: [String]) -> String? {
        let kinds = reasons.map(kind(of:))
        guard !kinds.isEmpty else { return nil }
        if kinds.contains(.receiverCapped) { return "받는 쪽도 한도에 닿았습니다 — 받는 쪽 줄의 바꾸기 ▾ 로 다른 에이전트를 고르세요" }
        guard kinds.allSatisfy({ $0 == .receiverUnchecked || $0 == .noNextAction }) else { return nil }
        if kinds.contains(.receiverUnchecked) {
            return "넘길 수는 있습니다 — 앱이 받는 쪽 상태를 확인하지 못했을 뿐입니다. 내용을 확인하고 넘기세요"
        }
        return "넘길 수는 있습니다 — 받는 쪽이 할 일을 덧붙일 말에 적어 주세요"
    }
}

/// 자동 인계 대상 후보 하나의 현재 상태.
struct AutomaticHandoffCandidate: Sendable {
    var provider: AgentProvider
    /// Codex 계정 ID. Claude 는 "".
    var accountID: String
    var title: String
    var cliUsable: Bool
    var authenticated: Bool
    var limit: LimitSnapshot
    /// 이 대화의 API 크레딧으로 받는 Claude (`AutomaticHandoffGate.targetProblems(usesAPICredit:)`).
    var usesAPICredit: Bool = false

    var key: String { AutomaticHandoffTargets.key(provider, accountID) }
}

/// 사용자가 정한 우선순위대로 후보를 보고, 한도 여유가 **확인된** 첫 대상을 고른다.
enum AutomaticHandoffTargets {
    static func key(_ provider: AgentProvider, _ accountID: String) -> String {
        switch provider {
        case .claude: return "claude"
        case .gemini: return "gemini"
        case .codex: return "codex:\(accountID)"
        }
    }

    /// 저장된 우선순위를 현재 존재하는 대상에 맞춘다.
    /// 사라진 대상은 버리고, 새로 생긴 대상은 기본 순서(Claude → Codex 계정 등록 순)대로 뒤에 붙인다.
    static func resolve(saved: [String], available: [String]) -> [String] {
        let live = Set(available)
        var seen = Set<String>()
        let kept = saved.filter { live.contains($0) && seen.insert($0).inserted }
        return kept + available.filter { !seen.contains($0) }
    }

    struct Selection: Sendable {
        var chosen: AutomaticHandoffCandidate?
        /// 건너뛴 후보와 그 이유. 고를 대상이 없을 때 사람이 판단할 근거가 된다.
        var skipped: [(title: String, reasons: [String])]
    }

    /// `candidates` 는 우선순위 순서. 넘겨주는 쪽(`fromKey`)은 후보가 아니다.
    static func select(_ candidates: [AutomaticHandoffCandidate], fromKey: String) -> Selection {
        var skipped: [(title: String, reasons: [String])] = []
        for candidate in candidates where candidate.key != fromKey {
            let problems = AutomaticHandoffGate.targetProblems(
                cliUsable: candidate.cliUsable, authenticated: candidate.authenticated,
                limit: candidate.limit, usesAPICredit: candidate.usesAPICredit)
            if problems.isEmpty { return Selection(chosen: candidate, skipped: skipped) }
            skipped.append((candidate.title, problems))
        }
        return Selection(chosen: nil, skipped: skipped)
    }
}

/// 인계의 보내는 쪽과, 사람이 대상을 고르지 않은 인계(⇧⌘H · 메뉴)의 받는 쪽.
///
/// 보내는 쪽은 이 대화에서 **마지막으로 일한** 에이전트 · 계정이다 — 입력창 칩의 선택값이 아니다. 칩 기준이면 한도에 닿은
/// 뒤 칩을 먼저 Codex 로 바꾼 사람에게 Codex → Codex 가 되어 인계가 막히고, ⇧⌘H 는 한도에 걸린 쪽으로 되돌려 보낸다.
/// 자동 인계는 원래 실행의 제공자를 기준으로 삼았다 — 수동 인계도 같은 기준으로 맞춘다.
enum HandoffSource {
    struct Agent: Hashable, Sendable {
        var provider: AgentProvider
        /// Codex 일 때의 계정. 다른 제공자는 nil.
        var codexAccountID: String?

        /// 대상 우선순위 · 이어 갈 세션의 열쇠 (`AutomaticHandoffTargets.key` — "claude", "codex:<계정 ID>").
        var key: String { AutomaticHandoffTargets.key(provider, provider == .codex ? (codexAccountID ?? "") : "") }
    }

    /// 이 대화에서 **일한** 실행 — 인계 전달 실행은 인계 기록이 **전달됨**일 때만 받는 쪽이 일한 것으로 센다. 실행 상태로
    /// 가르지 않는다: 받는 쪽이 응답을 시작한 뒤 끊긴 전달은 실행이 실패여도 전달됨이고(`RunSession.resolveHandoffDelivery`),
    /// 응답 전에 멈춘 전달은 전송 실패 · 미확인이다. 인계 기록이 가리키지 않는 전달 실행(옛 기록)은 실패가 아니면 센다.
    /// 보내는 쪽 판정과 "기록이 있는 대화" 판정(인계 · 이어 가기)이 같은 규칙을 쓴다 — 받지 못한 전달만 있는 대화는 기록이 없다.
    static func workedRuns(runs: [Run], handoffs: [Handoff]) -> [Run] {
        var deliveryStates: [String: HandoffDeliveryState] = [:]
        for handoff in handoffs { if let runID = handoff.deliveryRunID { deliveryStates[runID] = handoff.deliveryState } }
        return runs.filter { run in
            guard run.isHandoffDelivery else { return true }
            if let state = deliveryStates[run.id] { return state == .delivered }
            return run.state != .failed
        }
    }

    /// 마지막으로 일한 실행(`workedRuns`)의 에이전트. 실행이 없으면(새 대화) 칩의 선택값.
    static func resolve(runs: [Run], handoffs: [Handoff], thread: ConversationThread) -> Agent {
        let worked = workedRuns(runs: runs, handoffs: handoffs)
        if let last = worked.max(by: { $0.startedAt < $1.startedAt }) {
            return Agent(provider: last.provider,
                         codexAccountID: last.provider == .codex ? (last.codexAccountID ?? thread.codexAccountID) : nil)
        }
        return Agent(provider: thread.preferredProvider,
                     codexAccountID: thread.preferredProvider == .codex ? thread.codexAccountID : nil)
    }

    /// 대상을 고르지 않은 인계의 받는 쪽: 칩이 보내는 쪽과 다르면 칩(이미 받을 에이전트를 골랐다), 같으면 반대편.
    /// 칩이 같은 Codex 의 다른 계정이면 반대편이다 — Codex 계정끼리는 인계하지 않는다 (`CodexAccountSwitch`).
    static func defaultTarget(source: Agent, chip: Agent) -> Agent {
        if chip != source, !CodexAccountSwitch.isSwitch(from: source, to: chip) { return chip }
        return Agent(provider: source.provider.other, codexAccountID: nil)
    }
}
