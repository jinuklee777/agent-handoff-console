import Foundation

/// 이어 가기 (B 설계 C3 · C4) — 입력창 칩 메뉴의 행 동작과 한도 임박 제안 줄의 사실 모으기 · 동작.
///
/// 판정은 순수 코드(`Assist/ContinueChoice` · `Assist/ContinueSuggestion`)에 있고 여기는 그 입력을 앱의 상태에서 모으고, 판정이 낸
/// 동작을 앱의 동작(칩 바꾸기 · 인계 카드)으로 잇는다. 화면은 `UI/Composer.swift` 의 `ProviderMenu` · `UI/ContinueSuggestionBar.swift`.
/// 상태(`continueDismissals` · `continueRefreshAt`)는 `AppModel` 본체에 있다.
extension AppModel {

    // MARK: - 공통 사실

    /// 입력창 칩 (제공자 · Codex 계정) — 등록된 계정으로 맞춘 값.
    func chipAgent(for thread: ConversationThread) -> HandoffSource.Agent {
        normalizedHandoffAgent(HandoffSource.Agent(provider: thread.preferredProvider,
                                                   codexAccountID: thread.preferredProvider == .codex ? thread.codexAccountID : nil))
    }

    /// 이 대화에 메인 흐름에서 일한 실행이 있다 (`HandoffSource.workedRuns` — 받지 못한 인계 전달은 빼고). 화면에 읽어 둔 대화의
    /// 값이다 (열리지 않은 대화는 false — 판정마다 `loaded` 를 함께 본다).
    func hasWorkedRuns(threadID: String) -> Bool {
        guard let pane = threadStates[threadID] else { return false }
        return !HandoffSource.workedRuns(runs: Array(pane.runsByID.values), handoffs: pane.handoffs).isEmpty
    }

    /// 받는 쪽(에이전트 · Codex 계정) 하나의 준비 상태 — 점검표와 같은 판정(`AgentReadiness`). 칩 메뉴 · 카드의 바꾸기 · 넘기기 ·
    /// 한도 줄 · 이어 가기 제안이 같이 쓴다 (`ContinueChoice.handoffBlock` · `switchBlock` · `readinessTag`) — 입구마다 다르게 막지 않게.
    /// CLI 를 쓸 수 없다고 확인됐으면 그것이 먼저, 아니면 로그인. 확인하지 않은 것은 `.checking` 이다 — Codex 는 그 계정을 읽은 적이
    /// 없으면(목록을 아직 읽지 않음) 기본값의 "로그인 필요" 로 막지 않는다.
    func receiverReadiness(_ agent: HandoffSource.Agent) -> AgentReadiness {
        if let status = cliStatus[agent.provider], !status.isUsable {
            return pathOverride(agent.provider) != nil ? .pathInvalid : .notInstalled
        }
        switch agent.provider {
        case .claude:
            guard let login = claudeLogin else { return .checking }
            switch login.loggedIn {
            case true?: return .ready
            // API 키 · Bedrock · Vertex 로 쓰면 로그인하지 않아도 된다 — 점검표(`agentReadiness`)와 같은 판정 (hand-1).
            case false?: return claudeAlternativeAuth ? .loginUnknown : .notLoggedIn
            case nil: return .loginUnknown
            }
        case .codex:
            guard let account = accounts.account(agent.codexAccountID ?? CodexAccount.defaultID),
                  account.identityCheckedAt != nil else { return .checking }
            return codexLoginReadiness(accountID: account.id)
        case .gemini:
            // Antigravity 는 로그인을 알려 주지 않는다 (실행 파일만 본다).
            return cliStatus[.gemini] == nil ? .checking : .loginUnknown
        }
    }

    /// 그 대화에서 받는 쪽의 준비 상태 — 받는 쪽이 Claude 이고 그 대화가 API 크레딧으로 실행하면(`usesClaudeAPI`) 구독 로그인을 보지
    /// 않는다 (보내기 전 판정 `sendReadiness` 와 같은 `readinessWithAPIKey`). 대화를 아는 입구(칩 메뉴 · 카드의 바꾸기 · 넘기기 막힘 ·
    /// 한도 줄 · 이어 가기 제안 · 자동 인계)는 이것을 쓴다.
    func receiverReadiness(_ agent: HandoffSource.Agent, threadID: String?) -> AgentReadiness {
        let base = receiverReadiness(agent)
        guard receivesWithClaudeAPI(agent, threadID: threadID) else { return base }
        return Self.readinessWithAPIKey(base)
    }

    /// 그 대화에서 이 받는 쪽은 API 크레딧으로 받는 Claude 인가.
    func receivesWithClaudeAPI(_ agent: HandoffSource.Agent, threadID: String?) -> Bool {
        guard agent.provider == .claude, let threadID else { return false }
        return usesClaudeAPI(threadID: threadID)
    }

    /// 받는 쪽 Claude 의 로그인 사실 (카드 · 자동 인계 · 다시 확인). `claude auth status` 가 "로그인 안 됨" 이어도 자식 환경에 로그인 대신
    /// 쓸 인증(API 키 · Bedrock · Vertex)이 있으면 모름(nil)으로 — "로그인 안 됨" 으로 막지 않는다 (hand-1). 자동 인계는 여전히 확인된
    /// 로그인만 통과한다.
    func claudeReceiverLoginFact() async -> Bool? {
        let loggedIn = await claudeLoginCheck()
        if loggedIn == false && claudeAlternativeAuth { return nil }
        return loggedIn
    }

    /// 보내려는 에이전트의 CLI 를 쓸 수 없다 — 할 일(설치 · 경로 고치기)과 시작 점검으로 가는 단추 (chat-21).
    func cliUnavailableBanner(_ provider: AgentProvider, threadID: String) -> BannerMessage {
        let text: String
        if pathOverride(provider) != nil {
            text = "설정 > 에이전트에서 지정한 \(provider.displayName) 실행 파일을 실행할 수 없어 보내지 않았습니다 — 경로를 고치세요."
        } else if provider == .gemini {
            text = "Antigravity CLI(agy)를 찾지 못해 보내지 않았습니다 — 설정 > 에이전트에서 확인하세요."
        } else {
            text = "\(provider.displayName) CLI 를 찾지 못해 보내지 않았습니다 — 설치한 뒤 다시 보내세요 (설치 안내는 시작 점검)."
        }
        return BannerMessage(text: text, isError: true, actionTitle: "시작 점검 열기",
                             action: { [weak self] in self?.showFirstRunSheet = true }, threadID: threadID)
    }

    /// 이 대화에서 그 에이전트에게 이어 맡길 수 없는 까닭 — 허용하지 않은 Antigravity · 설치 안 됨 · 실행 불가 · 로그인 안 됨.
    /// 칩 메뉴의 행과 카드의 "바꾸기 ▾" 가 같은 판정을 쓴다. 맡길 수 있으면 nil.
    func handoffTargetBlock(_ agent: HandoffSource.Agent, thread: ConversationThread) -> ContinueChoice.Unavailable? {
        // 보내는 쪽(카드가 있으면 그 카드의 것)과 같은 Codex 의 다른 계정 — 인계하지 않고 계정만 바꾼다 (`CodexAccountSwitch`).
        let source = handoffCards[thread.id]?.draft.source ?? handoffSource(for: thread)
        if CodexAccountSwitch.isSwitch(from: normalizedHandoffAgent(source), to: normalizedHandoffAgent(agent)) {
            return CodexAccountSwitch.notHandoff
        }
        let readiness = receiverReadiness(agent, threadID: thread.id)
        if let block = ContinueChoice.switchBlock(readiness, provider: agent.provider) { return block }
        if agent.provider == .gemini, !antigravityAllowed(projectID: thread.projectID) { return ContinueChoice.antigravityNotAllowed }
        return ContinueChoice.handoffBlock(readiness, provider: agent.provider)
    }

    /// 막지 않고 붙이는 꼬리표 ("로그인 미확인").
    func handoffTargetTag(_ agent: HandoffSource.Agent, threadID: String) -> String? {
        ContinueChoice.readinessTag(receiverReadiness(agent, threadID: threadID), provider: agent.provider)
    }

    /// 칩 메뉴에 놓는 에이전트 — Claude · Codex(계정마다, 목록을 읽기 전이면 기본 계정 하나) · Antigravity.
    var continueMenuAgents: [HandoffSource.Agent] {
        var agents = [HandoffSource.Agent(provider: .claude, codexAccountID: nil)]
        if accounts.accounts.isEmpty {
            agents.append(normalizedHandoffAgent(HandoffSource.Agent(provider: .codex, codexAccountID: CodexAccount.defaultID)))
        } else {
            agents += accounts.accounts.map { HandoffSource.Agent(provider: .codex, codexAccountID: $0.id) }
        }
        agents.append(HandoffSource.Agent(provider: .gemini, codexAccountID: nil))
        return agents
    }

    // MARK: - C3 칩 = 이어 가기

    /// 칩 메뉴의 판정 입력. `resumableKeys` 는 팝오버를 열 때 읽은 값 (`resumableAgentKeys`).
    func continueChoiceInput(for thread: ConversationThread, resumableKeys: Set<String> = []) -> ContinueChoiceInput {
        let stage = handoffStage(threadID: thread.id)
        let card = handoffCards[thread.id]
        // 카드가 있으면 그 카드의 두 쪽 — 화면의 실행 목록으로 다시 정하지 않는다 (자동 인계는 한도에 걸린 실행의 에이전트를 보낸다).
        let cardTarget = card?.draft.target ?? deliveringHandoffs[thread.id]?.target ?? queueHolds[thread.id]?.target
        let source = card?.draft.source ?? deliveringHandoffs[thread.id]?.source ?? handoffSource(for: thread)
        // 준비 중(바꾸기 · 다시 만들기로 옛 카드를 둔 채 다시 만드는 중 포함) · 보내는 중 · 전달 중에는 카드를 거두거나 바꾸지 않는다.
        let locked = handoffPreparations[thread.id] != nil || deliveringHandoffs[thread.id] != nil || card?.isSending == true
        // 쓸 수 없는 에이전트 — 점검표와 같은 판정(`receiverReadiness`): 설치 안 됨 · 실행 불가는 바꾸기도 막고(먼저 — 허용하지 않은
        // Antigravity 라도 설치가 먼저다), 로그인 안 됨은 이어 맡기기만, 로그인 "모름" 은 꼬리표만.
        var switchBlocks: [String: ContinueChoice.Unavailable] = [:]
        var handoffBlocks: [String: ContinueChoice.Unavailable] = [:]
        var tags: [String: String] = [:]
        for agent in continueMenuAgents {
            let readiness = receiverReadiness(agent, threadID: thread.id)
            if let block = ContinueChoice.switchBlock(readiness, provider: agent.provider) {
                switchBlocks[agent.key] = block
            } else if agent.provider == .gemini, !antigravityAllowed(projectID: thread.projectID) {
                switchBlocks[agent.key] = ContinueChoice.antigravityNotAllowed
            }
            if let block = ContinueChoice.handoffBlock(readiness, provider: agent.provider) { handoffBlocks[agent.key] = block }
            if let tag = ContinueChoice.readinessTag(readiness, provider: agent.provider) { tags[agent.key] = tag }
        }
        return ContinueChoiceInput(
            chip: chipAgent(for: thread), source: normalizedHandoffAgent(source),
            hasWorkedRuns: hasWorkedRuns(threadID: thread.id), loaded: threadStates[thread.id]?.loaded ?? false,
            busy: runner.isBusy(threadID: thread.id) || isStartingRun(threadID: thread.id),
            cardTarget: cardTarget.map(normalizedHandoffAgent), hasCard: stage != nil, cardLocked: locked,
            cardUnknown: card?.phase == .unknown, cardSummarizing: card?.summarizing ?? false,
            handoffAllowed: handoffOwnershipBlock(thread) == nil, resumableKeys: resumableKeys,
            switchBlocks: switchBlocks, handoffBlocks: handoffBlocks, tags: tags)
    }

    /// 이 대화에서 이어 갈 CLI 세션이 있는 에이전트 · 계정 (`HandoffSource.Agent.key`). 보낼 때와 같은 칸(대화 × 제공자 — Codex 는
    /// 계정과 상관없이 대화의 세션 하나)을 본다 (`RunSession.send`). Codex 계정은 그 세션의 기록 폴더가 자기 홈이 아니면 인증을 파일에
    /// 둘 때만 이어 간다 (`CodexRunHome.usesFileCredentials`). 칩 메뉴를 열 때 한 번 읽는다 — "맥락 없이 바꾸기" 행의 부제가 쓴다.
    func resumableAgentKeys(threadID: String, agents: [HandoffSource.Agent]) async -> Set<String> {
        var keys: Set<String> = []
        var sessions: [AgentProvider: AgentSession?] = [:]
        for agent in agents {
            if sessions[agent.provider] == nil {
                sessions[agent.provider] = .some(try? await store.session(threadID: threadID, provider: agent.provider))
            }
            // 보낼 때와 같은 기준 — `RunSession.send` 는 `resumable` 일 때만 세션 ID 로 재개한다 (시작 준비에서 실패한 실행은
            // 세션 ID 를 남긴 채 `resumable` 을 끈다).
            guard let session = sessions[agent.provider] ?? nil, session.resumable,
                  let id = session.cliSessionID, !id.isEmpty else { continue }
            if agent.provider == .codex, let record = session.recordHome {
                let home = accounts.accountOrDefault(agent.codexAccountID ?? CodexAccount.defaultID).homePath
                guard CodexRunHome.sameHome(record, home) || CodexRunHome.usesFileCredentials(accountHome: home) else { continue }
            }
            keys.insert(agent.key)
        }
        return keys
    }

    /// 칩 메뉴의 행 하나를 눌렀다 — 판정(`ContinueChoice.Action`)을 앱의 동작으로 (`ContinueChoice.effect`).
    func performContinueChoice(_ action: ContinueChoice.Action, agent: HandoffSource.Agent, threadID: String) async {
        switch ContinueChoice.effect(of: action, agent: agent) {
        case .none:
            // "자동" 을 골랐던 대화에서 지금 칩 행을 누르면 자동만 푼다 (다음 메시지는 그 에이전트에게).
            if action == .current { orchestrationAutoThreadIDs.remove(threadID) }
        case .chooseAgent(let agent):
            orchestrationAutoThreadIDs.remove(threadID)
            await chooseAgent(agent.provider, accountID: agent.provider == .codex ? agent.codexAccountID : nil, threadID: threadID)
        case .prepareHandoff(let target):
            await prepareHandoff(to: target.provider, toAccountID: target.provider == .codex ? target.codexAccountID : nil,
                                 threadID: threadID, origin: .chip)
        case .revealCard:
            await revealHandoffCard(threadID: threadID)
        case .replaceCardTarget(let target):
            await replaceHandoffTarget(threadID: threadID, to: target.provider,
                                       toAccountID: target.provider == .codex ? target.codexAccountID : nil)
        case .cancelCard:
            cancelHandoff(threadID: threadID, origin: .card)
        }
    }

    // MARK: - C4 한도 임박 제안

    /// 제안이 대상의 한도를 새로 읽게 하는 최소 간격 — 화면은 60초마다 다시 판정한다.
    static let continueRefreshInterval: TimeInterval = 5 * 60

    /// 포커스 대화의 입력창 위 제안 줄 — 보일 제안과, 판단하지 못한(한도가 오래된) 대상.
    func continueSuggestion(for thread: ConversationThread, now: Date = Date()) -> ContinueSuggestion.Evaluation {
        ContinueSuggestion.evaluate(continueSuggestionInput(for: thread, now: now))
    }

    /// 제안의 판정 입력: 칩 · 보내는 쪽 · 기록 · 숨김 사실 · 보내는 쪽 한도 · 이어 갈 대상(`continueTargets`) · "나중에" · 지금.
    /// 보내는 쪽이 Claude 이면 API 크레딧 사실도 — 이 대화가 이미 API 로 실행하면 구독 사용률은 무관하고(`sourceUsesAPI`), 키가 있으면
    /// [API 크레딧으로 계속] 을 함께 권한다 (`claudeAPIContinueOffer`).
    func continueSuggestionInput(for thread: ConversationThread, now: Date = Date()) -> ContinueSuggestionInput {
        let source = handoffSource(for: thread)
        let claudeSource = source.provider == .claude
        return ContinueSuggestionInput(chip: chipAgent(for: thread), source: source,
                                       hasWorkedRuns: hasWorkedRuns(threadID: thread.id),
                                       hidden: continueSuggestionHiddenReason(thread) != nil,
                                       sourceLimit: limits.snapshot(ContinueSuggestion.scope(of: source)),
                                       targets: continueTargets(now: now, threadID: thread.id), dismissals: continueDismissals, now: now,
                                       sourceUsesAPI: claudeSource && usesClaudeAPI(threadID: thread.id),
                                       apiCreditAvailable: claudeSource
                                           && claudeAPIContinueOffer(threadID: thread.id, provider: .claude) == .available)
    }

    /// 이어 갈 대상(자동 인계와 같은 순서 `automaticHandoffTargets`)과 그 사실 — CLI · 로그인(오래됐는지) · 한도(앱이 새로 읽어도
    /// 되는지). 제안 줄과 한도 줄이 같이 쓴다. `order` 를 주면 그 대상들의 사실 (한도 줄이 "받지 않음" 으로 둔 대상을 볼 때).
    /// `threadID` 의 대화가 API 크레딧으로 실행하면 받는 쪽 Claude 는 구독 로그인 · 한도를 보지 않는다 (`apiCredit`).
    func continueTargets(now: Date = Date(), order: [AutomaticHandoffTarget]? = nil, threadID: String? = nil) -> [ContinueSuggestionTarget] {
        (order ?? automaticHandoffTargets).map { target -> ContinueSuggestionTarget in
            let agent = normalizedHandoffAgent(HandoffSource.Agent(
                provider: target.provider, codexAccountID: target.provider == .codex ? target.accountID : nil))
            // 로그인 "모름" · 받을 수 없음은 칩 메뉴 · 카드와 같은 판정 (`receiverReadiness`).
            let readiness = receiverReadiness(agent, threadID: threadID)
            let apiCredit = receivesWithClaudeAPI(agent, threadID: threadID)
            return ContinueSuggestionTarget(agent: agent, title: handoffPartyName(agent),
                                            cliUsable: cliStatus[target.provider]?.isUsable ?? false,
                                            authenticated: apiCredit || continueTargetAuthenticated(agent, now: now),
                                            limit: limits.snapshot(target.scope),
                                            loginStale: !apiCredit && continueTargetLoginStale(agent, now: now),
                                            limitRefreshable: continueLimitRefreshable(target.scope),
                                            loginUnknown: readiness == .loginUnknown,
                                            knownUnusable: ContinueChoice.handoffBlock(readiness, provider: agent.provider) != nil,
                                            apiCredit: apiCredit)
        }
    }

    /// 대상의 로그인이 **확인됐는가** — Claude 는 점검표가 둔 로그인 사실(`claudeLogin`)이 확인됨이고 30분 안의 것일 때만
    /// (모르는 것을 확인으로 보지 않는다 — 오래되면 `continueTargetLoginStale` 로 다시 확인한다. 자동 인계는 이 값을 쓰지 않고
    /// 스스로 새로 확인한다), Codex 는 그 계정의 auth.json. Antigravity 는 로그인을 알려 주지 않는다 (제안의 대상이 아니다).
    func continueTargetAuthenticated(_ agent: HandoffSource.Agent, now: Date = Date()) -> Bool {
        switch agent.provider {
        case .claude:
            guard let login = claudeLogin, login.loggedIn == true else { return false }
            return now.timeIntervalSince(login.checkedAt) <= ContinueSuggestion.freshness
        case .codex:
            return accounts.account(agent.codexAccountID ?? CodexAccount.defaultID)?.authStatus == .loggedIn
        case .gemini:
            return false
        }
    }

    /// 대상의 로그인 사실이 오래됐는가 — Claude 의 `claudeLogin` 을 확인한 지 30분이 넘었거나 아직 확인하지 않았다. 앱 활성화의
    /// 다시 확인은 끝난 사실(로그인됨)을 다시 보지 않으므로, 이어 가기가 스스로 다시 확인한다 (`refreshStaleContinueTargets`).
    /// 방금 확인한 "모름" · "로그인 안 됨" 은 오래된 것이 아니다 — 그 대상을 건너뛴다 (실패하는 확인이 다음 순서를 영영 막지 않게).
    func continueTargetLoginStale(_ agent: HandoffSource.Agent, now: Date = Date()) -> Bool {
        guard agent.provider == .claude else { return false }
        guard let login = claudeLogin else { return true }
        return now.timeIntervalSince(login.checkedAt) > ContinueSuggestion.freshness
    }

    /// 이어 가기가 이 scope 의 한도를 스스로 새로 읽어도 되나 — Claude 는 설정 "앱 시작 시 Claude 한도 조회" 를 따른다
    /// (`claude -p /usage` 는 훅 · MCP 까지 도는 세션이라 시스템 권한 요청이 앱 이름으로 뜰 수 있다). 끄면 Claude 한도는
    /// 사람의 새로고침이나 Claude 실행이 채운 값만 쓴다. Codex 한도 조회는 스레드를 만들지 않아 늘 읽는다.
    func continueLimitRefreshable(_ scope: AgentScope) -> Bool {
        scope.provider != .claude || startupFetchClaudeLimits
    }

    /// 제안 줄을 숨기는 사실 — 없으면 nil. 순서대로 본다 (`ContinueSuggestionHidden`).
    func continueSuggestionHiddenReason(_ thread: ConversationThread) -> ContinueSuggestionHidden? {
        if thread.isInternal { return .internalThread }
        if let snapshot = orchestration.snapshotsByThread[thread.id], !snapshot.job.state.isTerminal { return .orchestration }
        if orchestrationSettings.enabled && orchestrationAutoThreadIDs.contains(thread.id) { return .autoSelected }
        if runner.isBusy(threadID: thread.id) || isStartingRun(threadID: thread.id) { return .running }
        if hasHandoffActivity(threadID: thread.id) || handoffOutdated[thread.id] != nil { return .handoff }
        if thread.id != selectedThreadID { return .notFocused }
        if lastMainEventIsLimitNotice(threadID: thread.id) { return .limitNotice }
        return nil
    }

    /// 대화의 마지막 메인 이벤트가 한도 안내인가 — 앱의 안내(실행 전후 비교 등 `.systemNotice`)는 건너뛰고 본다. 그때는 대화 끝의
    /// 한도 줄이 인계를 권한다 (제안 줄이 같은 말을 또 하지 않게).
    func lastMainEventIsLimitNotice(threadID: String) -> Bool {
        activeLimitNoticeID(threadID: threadID) != nil
    }

    /// 지금도 한도에 닿아 있는 한도 안내 — 앱의 안내를 건너뛴 메인 흐름의 마지막 이벤트가 한도 안내면 그 ID. 한도 줄(`AlertRow`)은
    /// 이 줄에만 인계 단추를 달고, 제안 줄은 이것이 있으면 숨는다 — 같은 판정이라 둘 중 하나만 인계를 권한다.
    func activeLimitNoticeID(threadID: String) -> String? {
        guard let pane = threadStates[threadID],
              let last = pane.mainEvents.last(where: { $0.kind != .systemNotice }),
              last.isLimitNotice(run: last.runID.flatMap { pane.runsByID[$0] }) else { return nil }
        return last.id
    }

    /// 이 대화의 마지막 한도 안내의 원문(CLI 문구) — 카드 머리가 초기화 시각을 "미확인" 이라 하기 전에 본다 (`HandoffCardText.resetPhrase`).
    func limitNoticeText(threadID: String) -> String? {
        guard let pane = threadStates[threadID] else { return nil }
        return pane.mainEvents.last { $0.isLimitNotice(run: $0.runID.flatMap { pane.runsByID[$0] }) }?.text
    }

    /// 제안 · 한도 줄이 판단하지 못한 대상을 새로 읽는다 — 한도는 **강제 아닌** 새로 읽기, 로그인은 로그인만 다시 확인
    /// (`refreshClaudeLogin` — 세션을 띄우지 않는다). 같은 scope 는 `continueRefreshInterval` 에 한 번 (`LimitsService` 의 60초 간격과
    /// 따로, 화면이 다시 그려질 때마다 부르지 않게). 앱이 읽지 않는 Claude 한도(설정을 끔 — `continueLimitRefreshable`)는 부르지 않는다.
    /// 화면 확인용 실행은 넣어 둔 한도(`-preview.limits` 의 `fetchOverride`)가 있을 때의 한도만 — 실제 CLI 를 부르지 않는다.
    /// 새로 읽기 시작한 것을 돌려준다.
    @discardableResult
    func refreshStaleContinueTargets(_ stale: ContinueSuggestion.Stale, now: Date = Date()) -> ContinueSuggestion.Stale {
        var started = ContinueSuggestion.Stale()
        if !Self.offlinePreview || LimitsService.fetchOverride != nil {
            for scope in stale.limits where continueLimitRefreshable(scope) {
                if let last = continueRefreshAt[scope], now.timeIntervalSince(last) < Self.continueRefreshInterval { continue }
                continueRefreshAt[scope] = now
                started.limits.append(scope)
                Task { await limits.refresh(scope) }
            }
        }
        guard !Self.offlinePreview else { return started }
        for scope in stale.logins where scope.provider == .claude {
            if let last = continueLoginRefreshAt[scope], now.timeIntervalSince(last) < Self.continueRefreshInterval { continue }
            continueLoginRefreshAt[scope] = now
            started.logins.append(scope)
            Task { await refreshClaudeLogin() }
        }
        return started
    }

    /// [나중에] — 그 계정 · 창 길이의 제안을 미룬다 (더 높은 구간 · 그 창의 초기화 · 5시간 뒤에 다시 보인다).
    func dismissContinueSuggestion(_ suggestion: ContinueSuggestion, now: Date = Date()) {
        continueDismissals[suggestion.key] = suggestion.dismissal(at: now)
    }

    /// [<대상> 에게 이어 맡기기] — 앱이 정리한 문서의 카드 (origin `.suggestion` — 머리는 "Claude 5시간 사용률 81% — Codex 에게 이어 맡깁니다").
    /// 대상이 같은 Codex 의 다른 계정이면 카드 없이 계정만 바꾼다 (`switchCodexAccount`).
    /// 창 이름은 길이로 ("5시간" — 출처에 따라 "현재 세션" 으로 바뀌지 않게, `ContinueSuggestion.windowName`).
    func acceptContinueSuggestion(_ suggestion: ContinueSuggestion, threadID: String) async {
        guard let target = suggestion.target else { return }
        // 같은 Codex 의 다른 계정 — 인계하지 않고 계정만 바꾼다 (대화가 멈추지 않았으므로 보낼 것은 없다 — 다음 메시지부터).
        if suggestion.switchesCodexAccount {
            await switchCodexAccount(threadID: threadID, accountID: target.codexAccountID ?? CodexAccount.defaultID)
            return
        }
        await prepareHandoff(to: target.provider, toAccountID: target.provider == .codex ? target.codexAccountID : nil,
                             threadID: threadID,
                             origin: .suggestion(scope: suggestion.sourceScope, peak: suggestion.utilization,
                                                 windowLabel: suggestion.windowName))
    }

    // MARK: - 한도 줄의 인계 대상

    /// 한도 도달 줄이 권하는 받는 쪽.
    struct LimitHandoffTarget: Equatable {
        /// 권할 대상. nil 이면 이어 받을 에이전트가 없다 — 그 까닭은 `empty`.
        var agent: HandoffSource.Agent?
        /// 판단하지 못한 앞 순서 대상 — 새로 읽는다 (`refreshStaleContinueTargets`).
        var stale: ContinueSuggestion.Stale
        /// 받는 쪽의 CLI · 로그인 · 한도 여유가 30분 안에 확인됐다. 아니면(대비책) 한도 줄은 단정하지 않는다.
        var confirmed: Bool
        /// 고른 받는 쪽의 로그인이 "모름" 이다.
        var loginUnknown: Bool = false
        /// 권할 대상이 없는 까닭 — 설정에서 "받지 않음" 으로 뺐다 · 받는 쪽도 한도 · 쓸 수 없음 (hand-4 · set-n4). 대상이 있으면 nil.
        var empty: ContinueSuggestion.LimitLineEmpty? = nil
    }

    /// 한도 도달 줄(`AlertRow`)의 인계 대상 — 제안과 같은 사실 · 같은 나이 기준(`continueTargets` → `ContinueSuggestion.limitLineChoice`):
    /// 이어 갈 대상 순서에서 보내는 쪽을 빼고 CLI · 로그인 · 한도 여유가 30분 안에 확인된 첫 대상. 확인된 대상이 없으면(앞 순서가
    /// 오래돼 `stale` 을 새로 읽는 동안 포함) 대비책 — 반대편(Codex 면 **이 대화의 Codex 계정**, `defaultHandoffTarget` 과 같다)이나
    /// 순서의 다른 대상 중 받을 수 없다고 **확인되지 않은** 것 (`ContinueSuggestion.limitLineFallback`). 그것도 없으면 대상 없음 —
    /// 설치하지 않은 · 로그인하지 않은 에이전트를 "이어 갈 수 있다" 고 권하지 않는다 (hnd-1). 그때는 없는 까닭(`empty` — 설정에서 뺐다 ·
    /// 받는 쪽도 한도 · 쓸 수 없음)을 함께 돌려준다 (`ContinueSuggestion.limitLineEmpty`).
    func limitHandoffTarget(after source: HandoffSource.Agent, thread: ConversationThread?, now: Date = Date()) -> LimitHandoffTarget {
        let from = normalizedHandoffAgent(source)
        let targets = continueTargets(now: now, threadID: thread?.id)
        let choice = ContinueSuggestion.limitLineChoice(targets, source: from, now: now)
        if let chosen = choice.target {
            return LimitHandoffTarget(agent: chosen, stale: choice.stale, confirmed: true, loginUnknown: choice.loginUnknown)
        }
        let other = from.provider.other
        let preferred = normalizedHandoffAgent(HandoffSource.Agent(provider: other,
                                                                   codexAccountID: other == .codex ? thread?.codexAccountID : nil))
        // 설정에서 "받지 않음" 으로 둔 반대편 · 받을 수 없다고 확인된 반대편(대상 목록에 아직 없어도 — 계정 목록을 읽기 전)은 권하지 않는다.
        let preferredUsable = !automaticHandoffExcluded.contains(preferred.key)
            && ContinueChoice.handoffBlock(receiverReadiness(preferred, threadID: thread?.id), provider: preferred.provider) == nil
        let fallback = ContinueSuggestion.limitLineFallback(targets, source: from, preferred: preferredUsable ? preferred : nil, now: now)
        var result = LimitHandoffTarget(agent: fallback, stale: choice.stale, confirmed: false,
                                        loginUnknown: fallback.map { receiverReadiness($0, threadID: thread?.id) == .loginUnknown } ?? false)
        if fallback == nil {
            // 없는 까닭 — "받지 않음" 으로 뺀 대상의 사실도 함께 본다 (설치 · 로그인 안내로 엉뚱한 곳을 가리키지 않게, hand-4 · set-n4).
            let excludedOrder = automaticHandoffTargetOrder.filter { automaticHandoffExcluded.contains($0.key) }
            result.empty = ContinueSuggestion.limitLineEmpty(targets, excluded: continueTargets(now: now, order: excludedOrder,
                                                                                                    threadID: thread?.id),
                                                             source: from, now: now)
        }
        return result
    }

    // MARK: - 화면 확인

    #if DEBUG
    /// 화면 확인용 (`-preview.limits <사실>`, AHC_OFFLINE=1 전용): 한도 스냅샷 · CLI · 로그인 사실을 넣는다. 한도 새로 읽기는 넣은 값을
    /// 돌려준다(`LimitsService.fetchOverride` — 실제 `claude -p /usage` · Codex 를 부르지 않는다). 형식은 `PreviewLimitFacts`.
    func previewApplyLimitFacts(_ spec: String, now: Date = Date()) {
        guard Self.offlinePreview else { return }
        let facts = PreviewLimitFacts.parse(spec, now: now)
        let snapshots = Dictionary(facts.entries.map { ($0.snapshot.scope, $0.snapshot) }, uniquingKeysWith: { _, new in new })
        LimitsService.fetchOverride = { scope in
            snapshots[scope] ?? LimitSnapshot(provider: scope.provider, accountID: scope.accountID)
        }
        for entry in facts.entries { limits.apply(entry.snapshot) }
        // CLI: 적은 제공자는 그 값, 적지 않은 Claude · Codex 는 쓸 수 있는 것으로.
        for provider in [AgentProvider.claude, .codex] {
            let usable = facts.entries.first { $0.snapshot.provider == provider }?.cliUsable ?? true
            cliStatus[provider] = CLIStatus(provider: provider, resolvedPath: usable ? "/preview/\(provider.rawValue)" : nil,
                                            version: "preview", executable: usable, checkedAt: now)
        }
        let claudeEntry = facts.entries.first { $0.snapshot.provider == .claude }
        claudeLogin = LoginCheck(loggedIn: claudeEntry.map { $0.login } ?? true, checkedAt: now)
        for entry in facts.entries where entry.snapshot.provider == .codex {
            accounts.previewSetAuthStatus(entry.snapshot.accountID,
                                          entry.login == true ? .loggedIn : (entry.login == false ? .notLoggedIn : .unreadable))
        }
    }

    /// 화면 확인용 (`-preview.agyUsage <파일>`, AHC_OFFLINE=1 전용): `agy -p /usage --output-format json` 의 응답을 담은 파일을 앱의
    /// 해석기(`LimitsFetcher.parseAntigravityUsageResponse`)로 읽어 Antigravity 한도로 넣는다 — 허용한 프로젝트가 있는 것처럼
    /// (`LimitsService.antigravityEnabled`). 한도 새로 읽기도 이 값을 돌려준다. 실제 agy 를 부르지 않는다.
    func previewApplyAntigravityUsage(path: String, now: Date = Date()) {
        guard Self.offlinePreview, let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var base = LimitSnapshot(provider: .gemini)
        base.fetchedAt = now
        let snapshot = LimitsFetcher.parseAntigravityUsageResponse(raw, into: base)
        let previous = LimitsService.fetchOverride
        LimitsService.fetchOverride = { scope in
            if scope.provider == .gemini { return snapshot }
            return await previous?(scope) ?? LimitSnapshot(provider: scope.provider, accountID: scope.accountID)
        }
        limits.antigravityEnabled = true
        limits.apply(snapshot)
        cliStatus[.gemini] = CLIStatus(provider: .gemini, resolvedPath: "/preview/agy", version: "preview", executable: true,
                                       checkedAt: now)
    }
    #endif
}

#if DEBUG
/// 화면 확인용 한도 · CLI · 로그인 사실 (`-preview.limits`). 예: `claude=0.81@5h,fetched=now;codex=0.12`.
/// 항목은 `;` 로 나눈다. 항목 = `<claude|codex|codex:<계정 ID>>=<창>[+<창>…][,<선택>=<값>…]`.
/// 창 = `<사용률 0~1>[@<5h|7d|<n>m|<n>h|<n>d>]` (길이를 쓰지 않으면 5시간). 선택: `fetched=now|-<n>m|-<n>h|-<n>d`(확인한 때, 기본 지금) ·
/// `resets=+<n>m|+<n>h|+<n>d|none`(초기화, 기본 짧은 창 +2시간 · 긴 창 +3일 · none 은 모름) · `status=ok|cap` ·
/// `login=yes|no|unknown`(기본 yes) · `cli=yes|no`(기본 yes). `codex` 만 쓰면 기본 계정.
struct PreviewLimitFacts: Equatable {
    struct Entry: Equatable {
        var snapshot: LimitSnapshot
        var login: Bool?
        var cliUsable: Bool
    }
    var entries: [Entry] = []

    static func parse(_ spec: String, now: Date) -> PreviewLimitFacts {
        var facts = PreviewLimitFacts()
        for item in spec.split(separator: ";") {
            let parts = item.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let head = parts.first, let equal = head.firstIndex(of: "=") else { continue }
            let target = head[..<equal].split(separator: ":", maxSplits: 1).map(String.init)
            guard let provider = target.first.flatMap(AgentProvider.init(rawValue:)), provider != .gemini else { continue }
            let accountID = provider == .codex ? (target.count > 1 ? target[1] : CodexAccount.defaultID) : ""
            var options: [String: String] = [:]
            for option in parts.dropFirst() {
                let pair = option.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { options[pair[0]] = pair[1] }
            }
            var snapshot = LimitSnapshot(provider: provider, accountID: accountID)
            snapshot.status = options["status"] == "cap" ? .subscriptionCap : .ok
            snapshot.fetchedAt = offset(options["fetched"] ?? "now", from: now)
            for window in head[head.index(after: equal)...].split(separator: "+") {
                let piece = window.split(separator: "@", maxSplits: 1).map(String.init)
                guard let first = piece.first, let used = Double(first) else { continue }
                let minutes = piece.count > 1 ? spanMinutes(piece[1]) ?? 300 : 300
                let resets: Date?
                switch options["resets"] {
                case "none"?: resets = nil
                case let value?: resets = offset(value, from: now)
                case nil: resets = now.addingTimeInterval(minutes < 24 * 60 ? 2 * 3600 : 3 * 86_400)
                }
                snapshot.windows.append(LimitWindow(label: label(minutes), utilization: used, resetsAt: resets, spanMinutes: minutes))
            }
            let login: Bool?
            switch options["login"] {
            case "no"?: login = false
            case "unknown"?: login = nil
            default: login = true
            }
            facts.entries.append(Entry(snapshot: snapshot, login: login, cliUsable: options["cli"] != "no"))
        }
        return facts
    }

    /// "5h" · "7d" · "90m" → 분.
    static func spanMinutes(_ text: String) -> Int? {
        guard let unit = text.last, let value = Int(text.dropLast()), value > 0 else { return nil }
        switch unit {
        case "m": return value
        case "h": return value * 60
        case "d": return value * 1440
        default: return nil
        }
    }

    /// "now" · "-30m" · "+2h" → 시각.
    static func offset(_ text: String, from now: Date) -> Date? {
        guard text != "now" else { return now }
        guard let sign = text.first, sign == "-" || sign == "+", let minutes = spanMinutes(String(text.dropFirst())) else { return nil }
        return now.addingTimeInterval(Double(sign == "-" ? -minutes : minutes) * 60)
    }

    /// 창 이름 — 출처의 이름(Codex 1차 · 2차, Claude 5시간 · 7일)처럼.
    static func label(_ minutes: Int) -> String {
        if minutes % 1440 == 0 { return "\(minutes / 1440)일" }
        if minutes % 60 == 0 { return "\(minutes / 60)시간" }
        return "\(minutes)분"
    }
}
#endif
