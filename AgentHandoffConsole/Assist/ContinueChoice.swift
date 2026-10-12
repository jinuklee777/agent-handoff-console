import Foundation

// 입력창의 에이전트 칩 = 이어 가기 (B 설계 C3) — 순수 판정. 칩 메뉴의 행을 눌렀을 때 무엇을 하는지, 행이 말할 글,
// "맥락 없이 바꾸기" 행이 사실대로 말할 부제. 화면 · 실행기 · 저장을 모른다. 사실을 모으는 곳은 `AppModel.continueChoiceInput`,
// 동작은 `AppModel.performContinueChoice`(판정 → `Effect` → 앱의 동작), 화면은 `UI/Composer.swift` 의 `ProviderMenu`.

struct ContinueChoiceInput: Sendable {
    var chip: HandoffSource.Agent
    /// 이 대화에서 마지막으로 일한 에이전트 (`HandoffSource.resolve`). 카드가 있으면 그 카드의 보내는 쪽.
    var source: HandoffSource.Agent
    /// 메인 흐름에서 일한 실행이 있다 (`HandoffSource.workedRuns` — 받지 못한 인계 전달은 빼고).
    var hasWorkedRuns: Bool
    /// 대화 상자를 다 읽었다 (`ThreadPaneModel.loaded`) — 읽기 전에는 기록이 없어 보여 칩만 바뀔 수 있다.
    var loaded: Bool
    /// 이 대화에 실행이 돈다 (시작 중 포함).
    var busy: Bool
    /// 인계 카드가 있다 (준비 · 전달 중 포함). 있으면 그 받는 쪽.
    var cardTarget: HandoffSource.Agent?
    var hasCard: Bool
    /// 인계를 준비하거나 보내는(전달 중인) 동안 — 카드를 거두거나 받는 쪽을 바꿀 수 없다.
    var cardLocked: Bool = false
    /// 카드가 전달 여부 미확인이다 — 닫기만 할 수 있다 (받는 쪽을 바꿔 다시 보내지 않는다).
    var cardUnknown: Bool = false
    /// 카드를 Gemini 로 다시 정리하는 중 — 받는 쪽을 바꾸지 않는다 (카드의 "바꾸기" 와 같다).
    var cardSummarizing: Bool = false
    /// 이 대화에서 인계를 할 수 있다 — 내부 대화도, 끝나지 않은 자동 작업의 부모도 아니다.
    var handoffAllowed: Bool
    /// 이 대화에서 이어 갈 수 있는 세션이 있는 에이전트 · 계정 (`HandoffSource.Agent.key`).
    var resumableKeys: Set<String> = []
    /// 칩도 바꿀 수 없는 에이전트 (열쇠 → 이유) — Antigravity 를 허용하지 않은 프로젝트 · CLI 설치 안 됨 · 실행 불가.
    var switchBlocks: [String: ContinueChoice.Unavailable] = [:]
    /// 인계를 받을 수 없는 에이전트 (열쇠 → 이유) — 로그인 안 됨이 확인됐다. 칩은 바꿀 수 있다.
    var handoffBlocks: [String: ContinueChoice.Unavailable] = [:]
    /// 막지 않고 붙이는 꼬리표 (열쇠 → 짧은 글) — 로그인 "모름" ("로그인 미확인"). 행 오른쪽에 쓴다.
    var tags: [String: String] = [:]
}

enum ContinueChoice {
    /// 칩 메뉴의 에이전트 행 하나를 누르면.
    enum Action: Equatable, Sendable {
        /// 기록이 없거나 인계할 수 없는 대화 — 지금처럼 칩만 바꾼다.
        case switchChip
        /// 지금 칩 그대로 (아무것도 하지 않는다 — "자동" 을 골랐던 대화면 자동만 푼다).
        case current
        /// 보내는 쪽으로 칩만 되돌린다 (보내는 쪽에게는 넘길 것이 없다).
        case revertChip
        /// 이 에이전트에게 이어 맡기기 — 규칙 초안 카드를 만든다.
        case continueWith
        /// 같은 Codex 의 다른 계정 — 인계하지 않고 칩(계정)만 바꾼다. 다음 메시지부터 그 계정이 대화의 Codex 세션을 그대로 이어 간다
        /// (`CodexAccountSwitch`).
        case switchAccount
        /// 카드가 이미 이 에이전트에게 간다 — 그 카드로 간다.
        case showCard
        /// 카드의 받는 쪽을 이 에이전트로 바꾼다 (덧붙인 말을 옮겨 다시 만든다).
        case replaceCardTarget
        /// 보내는 쪽을 골랐다 — 카드를 취소한다 (카드의 [취소] 와 같다 · 미확인 카드는 [닫기]).
        case cancelCard
        /// 지금은 못 한다.
        case disabled(Block)
    }

    /// 행을 끈 까닭. 메뉴 전체에 걸리는 것(`isMenuWide`)은 메뉴 머리 한 줄이 한 번 말하고, 행 하나의 것은 그 행의 오른쪽 글.
    enum Block: Equatable, Sendable {
        case loading
        case locked
        case busy
        case cardUnknown
        case summarizing
        /// "맥락 없이 바꾸기" · 계정 바꾸기 — 카드(준비 · 전달 중 포함)가 있다.
        case cardOpen
        case unavailable(Unavailable)

        var message: String {
            switch self {
            case .loading: return "대화를 읽는 중입니다"
            case .locked: return "인계를 준비하거나 보내는 중입니다"
            case .busy: return "실행이 끝나면 이어 맡길 수 있습니다"
            case .cardUnknown:
                return "전달 여부를 확인하지 못한 인계 카드가 있습니다 — 이 대화에 받는 쪽의 응답이 있는지 본 뒤 카드를 닫으세요"
            case .summarizing: return "Gemini 가 초안을 다시 정리하는 중입니다 — 끝나면 받는 쪽을 바꿀 수 있습니다"
            case .cardOpen: return "인계 카드가 있는 동안은 받을 에이전트만 바꾸지 않습니다 — 카드에서 넘기거나 취소하세요"
            case .unavailable(let reason): return reason.help
            }
        }

        /// 메뉴 머리 한 줄(`menuNote`)이 말하는 까닭. 아니면 그 행(· "맥락 없이 바꾸기" 머리)의 오른쪽 글(`meta`)이 말한다.
        var isMenuWide: Bool {
            switch self {
            case .loading, .locked, .busy, .cardUnknown, .summarizing: return true
            case .cardOpen, .unavailable: return false
            }
        }

        /// 행 하나의 까닭을 그 행 오른쪽에 적는 짧은 글 (메뉴 전체의 까닭은 nil — 머리 줄이 말한다). 긴 글은 `message`(도움말 ·
        /// 손쉬운 사용 힌트).
        var meta: String? {
            switch self {
            case .cardOpen: return "인계 카드가 있음"
            case .unavailable(let reason): return reason.meta
            case .loading, .locked, .busy, .cardUnknown, .summarizing: return nil
            }
        }
    }

    /// 에이전트 하나를 쓸 수 없는 까닭 — 행 오른쪽의 짧은 글과 도움말.
    struct Unavailable: Equatable, Sendable {
        var meta: String
        var help: String
    }

    static let antigravityNotAllowed = Unavailable(
        meta: "설정에서 허용 필요",
        help: "이 프로젝트에서는 Antigravity 를 쓰지 않습니다 — 프로젝트 설정(사이드바의 프로젝트 메뉴)에서 허용합니다")

    // MARK: 받는 쪽 준비 상태 — 모든 입구가 같은 판정
    //
    // 칩 메뉴 · 카드의 "바꾸기" · 한도 줄 · 이어 가기 제안 · 카드의 [넘기기] 가 같은 사실(점검표의 `AgentReadiness` — CLI 설치 ·
    // 실행 가능 · 로그인)을 같은 규칙으로 본다. 확인된 문제만 막는다: 설치 안 됨 · 실행 불가는 이어 맡기기도 에이전트 바꾸기도
    // (보내면 실패한다), 로그인 안 됨은 이어 맡기기만 (바꿔 두고 터미널에서 로그인할 수 있다). 로그인 "모름"(파일이 아닌 자격 저장소 ·
    // 읽지 못한 auth.json · 확인 명령 실패)은 막지 않고 "로그인 미확인" 꼬리표만 — 점검표의 황색 통과와 같다. 확인 중은 아무것도 붙이지 않는다.

    /// 이어 맡기기(인계를 받기)를 막는 까닭.
    static func handoffBlock(_ readiness: AgentReadiness, provider: AgentProvider) -> Unavailable? {
        switch readiness {
        case .notInstalled, .pathInvalid: return switchBlock(readiness, provider: provider)
        case .notLoggedIn: return notLoggedIn(provider)
        case .ready, .loginUnknown, .checking: return nil
        }
    }

    /// 에이전트만 바꾸는 것도 막는 까닭 — 실행 파일이 없거나 실행할 수 없다.
    static func switchBlock(_ readiness: AgentReadiness, provider: AgentProvider) -> Unavailable? {
        switch readiness {
        case .notInstalled:
            return Unavailable(meta: "설치 안 됨", help: provider == .gemini
                ? "Antigravity CLI(agy)를 찾지 못했습니다 — 설정 > 에이전트에서 확인하세요"
                : "\(provider.displayName) CLI 를 찾지 못했습니다 — 도움말 > 시작 점검… 에서 설치 안내를 보세요")
        case .pathInvalid:
            return Unavailable(meta: "실행 불가",
                               help: "설정 > 에이전트에서 지정한 \(provider.displayName) 실행 파일을 실행할 수 없습니다 — 경로를 고치세요")
        case .ready, .loginUnknown, .notLoggedIn, .checking:
            return nil
        }
    }

    /// 막지 않고 붙이는 꼬리표 — 로그인 "모름". Antigravity 는 로그인을 알려 주지 않아 늘 모름이라 붙이지 않는다.
    static func readinessTag(_ readiness: AgentReadiness, provider: AgentProvider) -> String? {
        readiness == .loginUnknown && provider != .gemini ? loginUnknownTag : nil
    }

    static let loginUnknownTag = "로그인 미확인"

    private static func notLoggedIn(_ provider: AgentProvider) -> Unavailable {
        switch provider {
        case .claude:
            return Unavailable(meta: "로그인 필요",
                               help: "Claude 에 로그인돼 있지 않습니다 — 터미널에서 로그인하세요: \(AgentSetupGuide.claudeLoginCommand)")
        case .codex, .gemini:
            return Unavailable(meta: "로그인 필요", help: "이 Codex 계정은 로그인돼 있지 않습니다 — 설정 > 에이전트의 Codex 계정에서 로그인하세요")
        }
    }

    static func action(for agent: HandoffSource.Agent, _ input: ContinueChoiceInput) -> Action {
        guard input.loaded else { return .disabled(.loading) }
        if input.cardLocked { return .disabled(.locked) }
        if input.hasCard {
            if let target = input.cardTarget, target == agent { return .showCard }
            if agent == input.source { return .cancelCard }
            // 같은 Codex 의 다른 계정은 인계의 받는 쪽이 아니다 — 카드가 있는 동안은 계정도 바꾸지 않는다.
            if CodexAccountSwitch.isSwitch(from: input.source, to: agent) { return .disabled(.cardOpen) }
            if input.cardUnknown { return .disabled(.cardUnknown) }
            if input.cardSummarizing { return .disabled(.summarizing) }
            if let reason = input.switchBlocks[agent.key] ?? input.handoffBlocks[agent.key] { return .disabled(.unavailable(reason)) }
            return .replaceCardTarget
        }
        guard input.hasWorkedRuns, input.handoffAllowed else {
            return agent == input.chip ? .current : chipSwitch(to: agent, input, as: .switchChip)
        }
        if agent == input.source { return agent == input.chip ? .current : chipSwitch(to: agent, input, as: .revertChip) }
        // 같은 Codex 의 다른 계정 — 인계하지 않고 계정만 바꾼다 (실행 중이어도 — 다음 메시지부터).
        if CodexAccountSwitch.isSwitch(from: input.source, to: agent) {
            return agent == input.chip ? .current : chipSwitch(to: agent, input, as: .switchAccount)
        }
        if input.busy { return .disabled(.busy) }
        if let reason = input.switchBlocks[agent.key] ?? input.handoffBlocks[agent.key] { return .disabled(.unavailable(reason)) }
        return .continueWith
    }

    /// 칩만 바꾸는 행 — 바꿀 수도 없는 에이전트(허용하지 않은 Antigravity · 설치 안 됨 · 실행 불가)는 막는다. 실행 중에 Codex 계정을
    /// 바꿔도 된다 — 세션은 대화의 것 하나라 다음 메시지가 바꾼 계정으로 같은 세션을 이어 간다 (예전에는 세션이 계정마다라 막았다).
    private static func chipSwitch(to agent: HandoffSource.Agent, _ input: ContinueChoiceInput, as action: Action) -> Action {
        if let reason = input.switchBlocks[agent.key] { return .disabled(.unavailable(reason)) }
        return action
    }

    /// 이 행이 이어 맡기기(인계)인가 — 기록이 있고 인계할 수 있는 대화에서 보내는 쪽도, 카드의 받는 쪽도 아닌 에이전트.
    /// 행 글("Codex 에게 이어 맡기기")과 화살표를 정한다 (지금 끈 행이어도).
    static func continues(_ agent: HandoffSource.Agent, _ input: ContinueChoiceInput) -> Bool {
        guard input.loaded, input.hasWorkedRuns, input.handoffAllowed, agent != input.source else { return false }
        if input.hasCard, let target = input.cardTarget, target == agent { return false }
        return !CodexAccountSwitch.isSwitch(from: input.source, to: agent)
    }

    // MARK: 맥락 없이 바꾸기

    /// "맥락 없이 바꾸기" 묶음을 두는가 — 위 행이 이어 맡기기일 때만 (기록이 없거나 인계할 수 없는 대화는 위 행이 이미 칩만 바꾼다).
    static func showsPlainSwitch(_ input: ContinueChoiceInput) -> Bool {
        input.loaded && input.hasWorkedRuns && input.handoffAllowed
    }

    /// "맥락 없이 바꾸기" 를 펼칠 수 있나 — 카드 · 보류가 있으면 끈다 (칩을 바꾸면 카드의 받는 쪽과 어긋난다).
    static func plainSwitchEnabled(_ input: ContinueChoiceInput) -> Bool {
        input.loaded && !input.hasCard && !input.cardLocked
    }

    /// 펼쳤을 때 끈 까닭 (펼칠 수 있으면 nil).
    static func plainSwitchBlock(_ input: ContinueChoiceInput) -> Block? {
        guard !plainSwitchEnabled(input) else { return nil }
        if !input.loaded { return .loading }
        return input.cardLocked ? .locked : .cardOpen
    }

    /// "맥락 없이 바꾸기" 에 놓을 에이전트 — 지금 칩과, 위 행이 이미 칩만 되돌리는 보내는 쪽 · 계정만 바꾸는 같은 Codex 의 다른 계정은
    /// 뺀다 (같은 뜻이 두 번 나오지 않게). 바꿀 수도 없는 에이전트(허용하지 않은 Antigravity · 설치 안 됨 · 실행 불가)도 뺀다 — 위 행이
    /// 이미 까닭과 함께 끈 채 보인다 (같은 회색 행이 두 번 나오지 않게).
    static func plainSwitchAgents(_ agents: [HandoffSource.Agent], _ input: ContinueChoiceInput) -> [HandoffSource.Agent] {
        agents.filter {
            $0 != input.chip && input.switchBlocks[$0.key] == nil && action(for: $0, input) != .revertChip
                && !CodexAccountSwitch.isSwitch(from: input.source, to: $0)
        }
    }

    /// "맥락 없이 바꾸기" 행 하나를 누르면 — 칩만 바꾼다.
    static func plainSwitchAction(for agent: HandoffSource.Agent, _ input: ContinueChoiceInput) -> Action {
        if let block = plainSwitchBlock(input) { return .disabled(block) }
        return agent == input.chip ? .current : chipSwitch(to: agent, input, as: .switchChip)
    }

    /// "맥락 없이 바꾸기" 행의 부제 — 그 에이전트가 이 대화에서 무엇을 아는지 사실대로. 기록이 없는 대화면 nil.
    static func plainSwitchSubtitle(for agent: HandoffSource.Agent, name: String, _ input: ContinueChoiceInput) -> String? {
        guard input.hasWorkedRuns else { return nil }
        if input.resumableKeys.contains(agent.key) {
            // Codex 는 계정과 상관없이 대화의 세션 하나를 이어 간다 (`CodexRunHome`).
            if agent.provider == .codex {
                return "이 대화의 Codex 세션을 이어 갑니다 — 그 뒤에 다른 에이전트가 한 일은 모릅니다"
            }
            return "\(name) 의 이전 세션을 이어 갑니다 — 그 뒤에 다른 에이전트가 한 일은 모릅니다 (실패하면 새 세션)"
        }
        return "새 세션으로 시작합니다 — 지금까지의 대화를 모릅니다"
    }

    // MARK: 메뉴 머리 · 행 글

    /// 메뉴 머리 한 줄 — 모든 행에 같이 걸린 까닭 (행마다 되풀이하지 않는다). `busyNote` 는 백그라운드 작업 수 (" (백그라운드 작업 2개)").
    static func menuNote(_ input: ContinueChoiceInput, busyNote: String = "") -> String? {
        if !input.loaded { return Block.loading.message }
        if input.cardLocked { return Block.locked.message }
        if input.hasCard {
            if input.cardUnknown { return Block.cardUnknown.message }
            if input.cardSummarizing { return Block.summarizing.message }
            return nil
        }
        guard input.hasWorkedRuns, input.handoffAllowed, input.busy else { return nil }
        return "실행이 끝나면 이어 맡길 수 있습니다\(busyNote)"
    }

    /// 이어 맡기기 행의 글 — "Codex 에게 이어 맡기기".
    static func continueTitle(name: String) -> String { "\(name) 에게 이어 맡기기" }
    /// 그 아래 작은 글.
    static let continueSubtitle = "넘기기 전에 인계 문서를 먼저 보여 줍니다"

    /// 행 아래 작은 글 — 누르면 무엇이 되는지. 칩만 바꾸는 행 · 지금 칩 · 끈 행은 nil (끈 까닭은 머리 줄 · 행 오른쪽 글이 말한다).
    static func subtitle(for action: Action, _ input: ContinueChoiceInput) -> String? {
        switch action {
        case .continueWith: return continueSubtitle
        case .switchAccount: return CodexAccountSwitch.rowSubtitle
        case .revertChip: return "마지막으로 일한 에이전트입니다 — 인계하지 않고 받을 에이전트만 되돌립니다"
        case .showCard: return "인계 카드가 이쪽으로 갑니다 — 고르면 카드로 갑니다"
        case .replaceCardTarget: return "카드의 받는 쪽을 바꿉니다 — 덧붙인 말은 옮겨 갑니다"
        case .cancelCard:
            return input.cardUnknown ? "전달 여부를 확인하지 못한 카드를 닫습니다" : "인계 카드를 취소합니다 — 넘기지 않습니다"
        case .switchChip, .current, .disabled: return nil
        }
    }

    /// 행의 도움말 — 무엇을 하는지 (끈 행이면 그 까닭).
    /// `autoSelected` 면("자동" 을 고른 대화) 지금 칩 행은 자동을 푼다 — 다음 메시지는 지금 자동 작업으로 간다.
    /// 문장마다 형식 하나 — 이름을 하나의 값으로 넣는다.
    static func help(for action: Action, name: String, autoSelected: Bool = false, cardUnknown: Bool = false) -> String {
        switch action {
        case .switchChip: return "다음 메시지를 \(name) 에게 보냅니다."
        case .current where autoSelected: return "자동 작업을 풀고 다음 메시지를 \(name) 에게 보냅니다."
        case .current: return "다음 메시지는 지금처럼 \(name) 에게 갑니다."
        case .revertChip: return "다음 메시지를 \(name) 에게 보냅니다 — 인계하지 않고 받을 에이전트만 되돌립니다."
        case .continueWith:
            return "현재 맥락을 \(name) 에게 넘길 초안을 대화 끝의 카드로 만듭니다. 내용을 확인하고 넘기기를 눌러야 전송되고, "
                + "받는 쪽은 받자마자 일을 시작합니다."
        case .switchAccount: return CodexAccountSwitch.rowHelp(name: name)
        case .showCard: return "대화 끝의 인계 카드로 갑니다."
        case .replaceCardTarget: return "카드의 받는 쪽을 \(name) 에게로 바꿔 초안을 다시 만듭니다 — 덧붙인 말은 옮겨 갑니다."
        case .cancelCard: return cardUnknown ? HandoffCardText.closeUnknownHelp : HandoffCardText.cancelHelp
        case .disabled(let block): return block.message
        }
    }

    // MARK: 판정 → 앱의 동작

    /// 행 하나를 누른 뒤 앱이 할 일 (`AppModel.performContinueChoice` 가 이것대로 부른다).
    enum Effect: Equatable, Sendable {
        /// 아무것도 하지 않는다 (지금 칩이면 "자동" 선택만 푼다).
        case none
        /// 칩(제공자 · 계정)만 바꾼다 (`AppModel.chooseAgent`).
        case chooseAgent(HandoffSource.Agent)
        /// 이어 맡기기 — 규칙 초안 카드(origin `.chip`, Gemini 없음 — `AppModel.prepareHandoff`).
        case prepareHandoff(HandoffSource.Agent)
        /// 있는 카드로 간다 (`AppModel.revealHandoffCard`).
        case revealCard
        /// 카드의 받는 쪽을 바꾼다 (`AppModel.replaceHandoffTarget`).
        case replaceCardTarget(HandoffSource.Agent)
        /// 카드를 취소한다 (`AppModel.cancelHandoff(origin: .card)`).
        case cancelCard
    }

    static func effect(of action: Action, agent: HandoffSource.Agent) -> Effect {
        switch action {
        case .switchChip, .revertChip, .switchAccount: return .chooseAgent(agent)
        case .continueWith: return .prepareHandoff(agent)
        case .showCard: return .revealCard
        case .replaceCardTarget: return .replaceCardTarget(agent)
        case .cancelCard: return .cancelCard
        case .current, .disabled: return .none
        }
    }
}
