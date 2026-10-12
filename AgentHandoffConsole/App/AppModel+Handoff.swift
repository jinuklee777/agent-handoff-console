import Foundation

/// 인계 (B 설계 C1) — 대화마다의 인계 카드: 준비 · 자동 인계의 게이트 · 카운트다운 · 사람의 넘기기 · 전달 · 전달 뒤.
///
/// 상태(`handoffCards` · `handoffPreparations` · `deliveringHandoffs` · `queueHolds`)는 `AppModel` 본체에 있고, 카드의 값 · 막힘 판정 ·
/// 글은 `HandoffCard.swift`(순수)에 있다. 여기는 그 상태를 바꾸는 동작이다. 대기열 보류(C2)의 걸기 · 풀기는 `AppModel+Composer`.
///
/// - **보내기는 동기 점유로 시작한다** (`beginSend` — 첫 await 전에 카드를 "보내는 중" 으로, 타이머를 끈다). 그 뒤 DB 점유
///   (`Store.claimHandoffForSending`, `RunSession.deliver`)가 한 번 더 막는다.
/// - **칩(대화의 에이전트 · 계정)은 전달이 확인될 때 옮긴다** (`resolveDelivery`). 실패면 같은 행을 다시 보낼 수 있는 카드로,
///   미확인이면 보낼 수 없는 카드로 되살린다.
/// - 카드는 메모리다. 넘기기 전에는 DB 에 행이 없다 (취소한 초안이 남지 않는다).
extension AppModel {

    // MARK: - 조회

    /// 이 대화의 인계가 어디쯤인가 (준비 · 카드 · 전달 중). 없으면 nil. 이어 가기(칩 · 제안)와 진입점이 묻는다.
    func handoffStage(threadID: String) -> HandoffStage? {
        if deliveringHandoffs[threadID] != nil { return .delivering }
        if handoffCards[threadID] != nil { return .card }
        if handoffPreparations[threadID] != nil { return .preparing }
        return nil
    }

    /// 카드가 있다 — 준비 중 · 전달 중 포함 (C2 보류 · ⌘↵ · 진입점 막기가 같은 기준을 쓴다).
    func hasHandoffActivity(threadID: String) -> Bool { handoffStage(threadID: threadID) != nil }

    func isPreparingHandoff(threadID: String?) -> Bool {
        threadID.map { handoffPreparations[$0] != nil } ?? false
    }

    /// 이 대화의 인계 보내는 쪽 (`HandoffSource.resolve` — 마지막으로 일한 에이전트 · 계정). 화면용이라 열린 대화의
    /// 메모리 실행 목록을 쓴다 (열리지 않은 대화는 칩의 선택값). 실제 초안은 저장된 실행으로 다시 정한다.
    func handoffSource(for thread: ConversationThread) -> HandoffSource.Agent {
        let pane = threadStates[thread.id]
        return normalizedHandoffAgent(HandoffSource.resolve(runs: pane.map { Array($0.runsByID.values) } ?? [],
                                                            handoffs: pane?.handoffs ?? [], thread: thread))
    }

    /// ⇧⌘H · 메뉴처럼 대상을 고르지 않은 인계의 받는 쪽 — 칩이 보내는 쪽과 다르면 칩, 같으면 반대편. 반대편이 Codex 면 이 대화의
    /// Codex 계정이다 (계정을 주지 않은 Codex 대상을 준비가 그렇게 푼다 — `prepareCard`). ⇧⌘H · 메뉴바의 받는 쪽.
    /// 칩 메뉴는 ⇧⌘H 를 카드로 가기 행에만 붙인다 — 카드가 없을 때의 이어 맡기기 행은 origin `.chip`(규칙 초안만)이라 ⇧⌘H(`.manual`,
    /// Gemini 정리 가능)와 동작이 다르다.
    func defaultHandoffTarget(for thread: ConversationThread) -> HandoffSource.Agent {
        let target = HandoffSource.defaultTarget(source: handoffSource(for: thread), chip: chipAgent(for: thread))
        return normalizedHandoffAgent(HandoffSource.Agent(
            provider: target.provider, codexAccountID: target.provider == .codex ? (target.codexAccountID ?? thread.codexAccountID) : nil))
    }

    /// Codex 계정 ID 를 등록된 계정으로 맞춘다 (없는 ID · 기본값 표기 차이로 같은 계정을 다르게 보지 않게).
    func normalizedHandoffAgent(_ agent: HandoffSource.Agent) -> HandoffSource.Agent {
        guard agent.provider == .codex else { return HandoffSource.Agent(provider: agent.provider, codexAccountID: nil) }
        return HandoffSource.Agent(provider: .codex,
                                   codexAccountID: accounts.accountOrDefault(agent.codexAccountID ?? CodexAccount.defaultID).id)
    }

    /// 등록된 Codex 계정인가. 기본 계정은 늘 있다 (계정 목록을 아직 읽지 않았어도 — `CodexAccountService.defaultAccount`).
    func isRegisteredCodexAccount(_ id: String) -> Bool {
        accounts.account(id) != nil || (id == CodexAccount.defaultID && accounts.accounts.isEmpty)
    }

    /// 이 대화의 카드가 전달 여부 미확인 카드다 — 보류는 남지만 이 카드로는 인계가 끝나지 않는다 (입력창 · 대기열 머리가 그 사실을 적는다).
    func isHandoffDeliveryUnknown(threadID: String) -> Bool {
        handoffCards[threadID]?.phase == .unknown
    }

    /// 이 대화에서 인계를 시작할 수 없는 이유 — 진입점(⇧⌘H · 메뉴바 · 입력창 · 한도 줄)이 숨기거나 끈다. 시작할 수 있으면 nil.
    /// 내부 대화 · 끝나지 않은 자동 작업의 부모 · 기록(메인 흐름에서 일한 실행 — `hasWorkedRuns`)이 없는 대화 (화면에 읽어 둔
    /// 실행으로 — 실제 판정은 준비가 저장소로 다시 한다).
    func handoffEntryBlock(for thread: ConversationThread) -> String? {
        if let block = handoffOwnershipBlock(thread) { return block }
        if let pane = threadStates[thread.id], pane.loaded, !hasWorkedRuns(threadID: thread.id) {
            return Self.noHistoryHandoffText
        }
        return nil
    }

    static let noHistoryHandoffText = "기록이 없는 대화는 인계하지 않습니다 — 입력창에서 받을 에이전트만 바꾸면 됩니다"

    /// 자동 작업이 가진 대화 — 인계하지 않는다 (내부 대화 · 끝나지 않은 자동 작업의 부모). 입력창 칩 메뉴는 이 이유를 머리에 적는다.
    func handoffOwnershipBlock(_ thread: ConversationThread) -> String? {
        if thread.isInternal { return "자동 작업의 내부 대화는 인계하지 않습니다" }
        if orchestration.snapshotsByThread[thread.id].map({ !$0.job.state.isTerminal }) == true {
            return "자동 작업이 끝난 뒤에 인계할 수 있습니다"
        }
        return nil
    }

    /// 카드를 그 대화의 칸에서 보인다: 화면에 열려 있지 않으면 연다(포커스 칸에), 열려 있으면 그 칸을 맨 아래로.
    /// `focusMemo` 면 덧붙일 말 칸에 키보드 포커스를 준다 (⇧⌘H · 메뉴바 — 키보드만으로 확인하고 넘기게, hnd-18).
    func revealHandoffCard(threadID: String, focusMemo: Bool = false) async {
        if !panes.threadIDs.contains(threadID) && selectedThreadID != threadID { await selectThread(threadID) }
        threadStates[threadID]?.requestScrollToBottom()
        if focusMemo { requestHandoffMemoFocus(threadID: threadID) }
    }

    /// 카드의 덧붙일 말 칸에 포커스를 달라고 한다 (카드가 받는다 — `HandoffCardView`). 접힌 카드(좁은 칸)는 펼친다 — 칸이 펼친 뒤에만 있다.
    /// 포커스가 그 칸에 들어가면 카운트다운이 멈추고 ⌘↵ 는 카드의 것이 된다 (한 번 = 확인, 한 번 더 = 넘기기).
    func requestHandoffMemoFocus(threadID: String) {
        guard var card = handoffCards[threadID], !card.isSending, card.phase != .unknown else { return }
        card.expanded = true
        card.memoFocusPending = true
        handoffCards[threadID] = card
    }

    /// 카드가 포커스 요청을 받았다.
    func consumeHandoffMemoFocus(threadID: String) {
        guard var card = handoffCards[threadID], card.memoFocusPending else { return }
        card.memoFocusPending = false
        handoffCards[threadID] = card
    }

    /// 카드 안의 ⌘↵ (hnd-18) — 키보드만으로 확인하고 넘긴다: 확인 전이면 "내용을 확인했습니다" 를 체크하고(넘기지 않는다), 확인했으면
    /// 넘긴다. 카운트다운 · 낡은 카드 · 미확인 카드 · 막힘이 있으면 아무것도 하지 않는다 (꺼진 [넘기기] 와 같다). 무엇을 했는지 돌려준다.
    enum HandoffReturnKeyResult: Equatable { case none, confirmed, sent }

    @discardableResult
    func handoffReturnKey(threadID: String) async -> HandoffReturnKeyResult {
        guard let card = handoffCards[threadID], card.showsConfirm(folded: false), !card.summarizing else { return .none }
        if !card.confirmed {
            setHandoffConfirmed(true, threadID: threadID)
            return .confirmed
        }
        guard handoffSendBlock(threadID: threadID) == nil else { return .none }
        return await sendHandoff(threadID: threadID) ? .sent : .none
    }

    // MARK: - 진입점

    /// 인계 카드를 연다 — ⇧⌘H · 메뉴바 · 입력창 칩의 이어 맡기기(`.chip`) · 한도 줄 · 이어 가기 제안(`.suggestion`). 카드(준비 ·
    /// 전달 중 포함)가 이미 있으면 다시 만들지 않고 그 카드로 간다 (받는 쪽을 바꾸는 것은 카드의 "바꾸기" · 칩 메뉴의 다른 행뿐이다).
    /// 칩 · 제안은 앱이 정리한 문서만 만든다 (`Origin.draftsWithGemini`). `threadID` 를 주지 않으면 포커스 대화.
    /// ⇧⌘H · 메뉴바(origin `.manual`)는 카드의 덧붙일 말 칸에 포커스를 준다 — 키보드만으로 확인하고 넘길 수 있게.
    func prepareHandoff(to target: AgentProvider, toAccountID: String? = nil, threadID: String? = nil,
                        origin: HandoffCard.Origin = .manual) async {
        guard let threadID = threadID ?? selectedThreadID else {
            banner = BannerMessage(text: "프로젝트와 대화를 먼저 선택하세요.", isError: true)
            return
        }
        let focusMemo = origin == .manual
        if let stage = handoffStage(threadID: threadID) {
            if stage == .preparing && handoffCards[threadID] == nil {
                banner = BannerMessage(text: "이 대화의 인계 초안을 만드는 중입니다.", isError: false, threadID: threadID)
            }
            await revealHandoffCard(threadID: threadID, focusMemo: focusMemo)
            return
        }
        let placed = await prepareCard(threadID: threadID, target: target, toAccountID: toAccountID, origin: origin,
                                       automatic: false, useGemini: origin.draftsWithGemini)
        if placed, focusMemo { requestHandoffMemoFocus(threadID: threadID) }
    }

    /// 카드의 "바꾸기 ▾" — 받는 쪽을 바꿔 초안을 다시 만든다. 새 초안이 놓일 때까지 옛 카드를 두고, 덧붙인 말을 옮긴다.
    /// 옛 카운트다운은 먼저 검토로 돌린다.
    func replaceHandoffTarget(threadID: String, to target: AgentProvider, toAccountID: String?) async {
        // 전달 여부 미확인 카드는 받는 쪽을 바꿔 다시 만들지 않는다 — 닫기만 (자동 재전송하지 않는다와 같은 위험). 카드 화면은 "바꾸기" 를
        // 숨기고 칩 메뉴는 셋째 행을 끄지만, 입구가 무엇이든 여기서 막는다.
        guard let card = handoffCards[threadID], !card.isSending, card.phase != .unknown,
              handoffPreparations[threadID] == nil else { return }
        pauseCountdown(threadID: threadID)
        await prepareCard(threadID: threadID, target: target, toAccountID: toAccountID, origin: card.origin, automatic: false,
                          useGemini: card.draft.geminiRequested, replacing: handoffCards[threadID] ?? card)
    }

    /// "다시 만들기" — 같은 받는 쪽으로 초안을 다시 만든다 (낡은 카드 · 버린 준비).
    func remakeHandoff(threadID: String) async {
        if let card = handoffCards[threadID] {
            await replaceHandoffTarget(threadID: threadID, to: card.targetProvider,
                                       toAccountID: card.targetProvider == .codex ? card.draft.handoff.toAccountID : nil)
        } else if let outdated = handoffOutdated[threadID] {
            handoffOutdated[threadID] = nil
            await prepareCard(threadID: threadID, target: outdated.target.provider, toAccountID: outdated.target.codexAccountID,
                              origin: outdated.origin, automatic: false, useGemini: outdated.origin.draftsWithGemini)
        }
    }

    /// 버린 준비의 안내를 닫는다.
    func dismissOutdatedHandoff(threadID: String) {
        handoffOutdated[threadID] = nil
    }

    /// 전달 여부 미확인 카드의 [닫고 다시 만들기] — 사람이 이 대화에 받는 쪽의 응답이 없음을 보고 누른다 (앱은 스스로 다시 보내지
    /// 않는다). 카드를 닫고 같은 받는 쪽 · 같은 까닭으로 새 카드를 만든다 — 덧붙인 말은 옮기고, 넘기는 것은 사람의 확인으로.
    /// 새 문서는 그 미확인 인계를 "확인이 필요한 항목" 으로 적는다.
    func remakeUnknownHandoff(threadID: String) async {
        guard let card = handoffCards[threadID], card.phase == .unknown else { return }
        let target = card.draft.target
        let memo = card.userMemo
        guard cancelHandoff(threadID: threadID, origin: .card, keepMoved: true) else { return }
        guard await prepareCard(threadID: threadID, target: target.provider, toAccountID: target.codexAccountID,
                                origin: card.origin, automatic: false, useGemini: card.draft.geminiRequested),
              var fresh = handoffCards[threadID] else {
            // 새 카드를 놓지 못했다 — 옮겨 둔 메시지는 대기열로 되돌린다.
            restoreMovedMessages(card.movedMessages, threadID: threadID)
            return
        }
        fresh.userMemo = memo
        fresh.movedMessages = card.movedMessages
        handoffCards[threadID] = fresh
    }

    // MARK: - 준비

    /// 준비 하나: 토큰을 잡고(같은 대화에 둘 돌지 않게 — 늦게 끝난 준비는 토큰이 달라 버린다), 대기열을 보류하고(C2),
    /// 초안을 만들어 카드를 놓는다. 자동 인계면 게이트까지 준비 안에서 보고 카운트다운 · 검토 카드로 놓는다.
    /// `replacing` 이 있으면(바꾸기 · 다시 만들기) 그 카드는 새 카드가 놓일 때까지 남고, 실패하면 그대로 남는다.
    @discardableResult
    func prepareCard(threadID: String, target: AgentProvider, toAccountID: String?, origin: HandoffCard.Origin,
                     automatic: Bool, automaticNotes: [String] = [], source givenSource: HandoffSource.Agent? = nil,
                     useGemini: Bool = true, replacing previous: HandoffCard? = nil) async -> Bool {
        guard handoffPreparations[threadID] == nil else {
            banner = BannerMessage(text: "이 대화의 인계 초안을 만드는 중입니다.", isError: false, threadID: threadID)
            return false
        }
        // 카드가 이미 있거나 전달 중이면 새로 놓지 않는다 — 그 카드를 갈아 끼우는 것은 바꾸기 · 다시 만들기(`replacing`)뿐이다.
        // 자동 인계가 한도 · 로그인 조회를 기다리는 사이 사람이 카드를 열었으면 그 카드(받는 쪽 · 덧붙인 말 · 체크)를 덮지 않는다.
        if previous == nil, handoffCards[threadID] != nil || deliveringHandoffs[threadID] != nil {
            if !automatic { await revealHandoffCard(threadID: threadID) }
            return false
        }
        guard let listed = paneThread(threadID) else {
            banner = BannerMessage(text: "프로젝트와 대화를 먼저 선택하세요.", isError: true)
            return false
        }
        if let block = handoffOwnershipBlock(listed) {
            // 안내다 (내부 대화 · 끝나지 않은 자동 작업) — 오류 색을 쓰지 않는다.
            banner = BannerMessage(text: block + ".", isError: false, threadID: threadID)
            return false
        }
        // 받는 Codex 계정은 엄격히 — 고른 계정의 등록이 지워졌으면 기본 계정으로 떨어뜨리지 않는다.
        if target == .codex, let toAccountID, !isRegisteredCodexAccount(toAccountID) {
            banner = BannerMessage(text: "받는 Codex 계정이 등록되어 있지 않습니다. 다른 계정을 고르세요.", isError: true, threadID: threadID)
            return false
        }
        // 실행 중이면 보류를 걸지 않고 곧바로 알린다 — 그 실행 뒤에 이어 갈 대기열을 건드리지 않게 (실행이 끝나면 인계할 수 있다).
        let session = runner.session(threadID: threadID)
        if session != nil || isStartingRun(threadID: threadID) {
            // 메인 턴을 마치고 백그라운드 작업을 기다리는 중이면 그 수를 덧붙인다 — 답은 끝난 것처럼 보여도 실행은 돌고 있다.
            let note = session.map { SubAgentDigest.waitingNote(waiting: $0.isWaitingOnBackground, count: $0.unfinishedSubAgentCount) } ?? ""
            banner = BannerMessage(text: "이 대화에서 에이전트가 실행 중입니다\(note). 끝나기를 기다리거나 중단한 뒤 인계하세요.",
                                   isError: true, threadID: threadID)
            return false
        }
        // 첫 await 전에 자리를 잡는다 — 그 사이 같은 대화의 다른 진입점 · 보내기가 끼어들지 못한다.
        let token = UUID()
        handoffPreparations[threadID] = token
        handoffPreparationSerials[threadID, default: 0] += 1
        handoffTouchedDuringPreparation.remove(threadID)
        handoffOutdated[threadID] = nil
        // 다른 Codex 계정에서 이어 가려던 카운트다운은 멈춘다 — 사람이 인계 카드를 열었다 (⇧⌘H · 칩 · 한도 줄). 그대로 두면 울려도
        // 카드 · 준비가 막아 아무 말 없이 사라졌다. 계정을 바꿔 이어 가려면 한도 줄의 단추 · 칩의 계정 행이 남는다.
        cancelCodexSwitchCountdown(threadID: threadID)
        let target = normalizedHandoffAgent(HandoffSource.Agent(
            provider: target, codexAccountID: target == .codex ? (toAccountID ?? listed.codexAccountID) : nil))
        // 보류를 걸기 전의 멈춤 이유 — 준비가 실패하면 되돌린다 (한도로 멈춘 대기열은 그대로 멈춘 채로).
        let previousPause = queuePauseReasons[threadID]
        if previous == nil {
            holdQueue(threadID: threadID, source: givenSource.map(normalizedHandoffAgent) ?? handoffSource(for: listed),
                      target: target)
        }
        // 카드가 생기면 그 대화의 "자동"(자동 작업) 선택을 푼다 — 다음 메시지는 인계 뒤 받는 쪽에게 간다.
        orchestrationAutoThreadIDs.remove(threadID)

        let built = await buildHandoffCard(threadID: threadID, target: target, origin: origin, automatic: automatic,
                                           source: givenSource, useGemini: useGemini)
        // 준비하는 사이 취소 · 대화 삭제 · 다른 준비가 토큰을 바꿨으면 버린다 (그쪽이 보류를 정리했다).
        guard handoffPreparations[threadID] == token else { return false }
        guard case .success(var card) = built else {
            handoffPreparations[threadID] = nil
            let reason: String
            var notice = false
            if case .failure(let failure) = built { reason = failure.message; notice = failure.notice } else { reason = "" }
            if previous != nil, var old = handoffCards[threadID] {
                old.lastError = reason
                handoffCards[threadID] = old
            } else {
                banner = BannerMessage(text: reason, isError: !notice, threadID: threadID)
                releaseHold(threadID: threadID, .preparationFailed)
                if let previousPause { queuePauseReasons[threadID] = previousPause }
            }
            return false
        }
        // 준비하는 사이 이 대화에서 실행이 시작됐으면 이 초안은 지난 일이다 — 놓지 않고 그 자리에 알린다.
        if runner.session(threadID: threadID) != nil || isStartingRun(threadID: threadID) {
            handoffPreparations[threadID] = nil
            if previous == nil {
                handoffOutdated[threadID] = OutdatedHandoff(target: card.draft.target, origin: origin)
                releaseHold(threadID: threadID, .preparationFailed)
            }
            return false
        }
        if let previous {
            // 놓는 순간의 옛 카드 값으로 — 다시 만드는 동안(Gemini 정리면 수십 초)에도 덧붙일 말 칸에 계속 쓸 수 있다.
            let current = handoffCards[threadID].flatMap { $0.id == previous.id ? $0 : nil }
            card.userMemo = current?.userMemo ?? previous.userMemo
            card.movedMessages = current?.movedMessages ?? previous.movedMessages
            card.expanded = current?.expanded ?? previous.expanded
        }
        if card.targetProvider == .codex, !isRegisteredCodexAccount(card.draft.handoff.toAccountID) {
            card.review = .accountRemoved(card.draft.packet.toAccountLabel ?? card.draft.handoff.toAccountID)
        }
        if automatic, card.review == nil {
            let gate = await automaticGate(for: card)
            guard handoffPreparations[threadID] == token else { return false }
            card.receiver = gate.receiver
            if !gate.reasons.isEmpty {
                card.review = .automaticBlocked(gate.reasons + automaticNotes)
            }
        }
        // 준비하는 사이 사람이 입력창에서 메시지를 걸었거나 받는 쪽 모델을 바꿨다 — 사람이 손댄 자동 인계는 확인 길로 (카운트다운 없이).
        let touched = handoffTouchedDuringPreparation.remove(threadID) != nil
        if automatic, touched, card.review == nil { card.review = .pausedByHuman }
        handoffPreparations[threadID] = nil
        handoffCards[threadID] = card
        queueHolds[threadID] = QueueHold(source: card.draft.source, target: card.draft.target)
        if automatic {
            if card.review == nil {
                startAutomaticHandoffCountdown(threadID: threadID)
            } else if card.review == .pausedByHuman {
                // 사람이 이미 이 대화를 보고 있다 — 검토 알림을 띄우지 않는다.
            } else if let thread = paneThread(threadID) {
                var reason = "게이트 차단"
                if case .automaticBlocked(let reasons)? = card.review, let first = reasons.first { reason = first }
                notifications.post(category: .limitReached, title: "자동 인계에 검토가 필요합니다",
                                   body: "\(thread.title) · \(reason)", threadID: threadID, opensHandoff: true)
            }
        } else {
            // 사람이 연 카드는 맨 아래로 (그 칸이 화면에 있으면). 포커스는 빼앗지 않는다.
            threadStates[threadID]?.requestScrollToBottom()
        }
        return true
    }

    struct HandoffPreparationFailure: Error {
        var message: String
        /// 실패가 아니라 안내 (기록 없는 대화 등) — 배너를 오류(빨간 선)로 올리지 않는다.
        var notice = false
    }

    /// 추가 모델 호출 없이 규칙 초안을 만든다 (한도로 응답할 수 없는 상태에서도). Gemini 보조를 켠 프로젝트면 정리를 붙인다.
    /// 보내는 쪽은 이 대화에서 마지막으로 일한 에이전트다 (`source` 를 주면 그것 — 자동 인계는 한도에 걸린 실행의 에이전트).
    private func buildHandoffCard(threadID: String, target: HandoffSource.Agent, origin: HandoffCard.Origin,
                                  automatic: Bool, source givenSource: HandoffSource.Agent?,
                                  useGemini: Bool) async -> Result<HandoffCard, HandoffPreparationFailure> {
        func failure(_ text: String) -> Result<HandoffCard, HandoffPreparationFailure> { .failure(.init(message: text)) }
        guard let thread = (try? await store.thread(id: threadID)) ?? paneThread(threadID),
              let project = folderProject(for: thread) else {
            return failure("프로젝트와 대화를 먼저 선택하세요.")
        }
        let runs = (try? await store.runs(threadID: thread.id)) ?? []
        let threadHandoffs = (try? await store.handoffs(threadID: thread.id)) ?? []
        // 기록 = 일한 실행 (받지 못한 인계 전달만 있으면 넘길 맥락이 없다 — 진입점의 `handoffEntryBlock` 과 같은 규칙).
        guard !HandoffSource.workedRuns(runs: runs, handoffs: threadHandoffs).isEmpty else {
            return .failure(.init(message: Self.noHistoryHandoffText + ".", notice: true))
        }
        let source = normalizedHandoffAgent(givenSource ?? HandoffSource.resolve(runs: runs, handoffs: threadHandoffs, thread: thread))
        let from = source.provider
        let fromAccount = from == .codex ? accounts.accountOrDefault(source.codexAccountID ?? thread.codexAccountID) : nil
        let toAccount: CodexAccount?
        if target.provider == .codex {
            let id = target.codexAccountID ?? CodexAccount.defaultID
            guard isRegisteredCodexAccount(id) else {
                return failure("받는 Codex 계정이 등록되어 있지 않습니다. 다른 계정을 고르세요.")
            }
            toAccount = accounts.accountOrDefault(id)
        } else {
            toAccount = nil
        }
        if target.provider == .gemini, !antigravityAllowed(projectID: project.id) {
            return failure("이 프로젝트에서는 Antigravity 로 인계할 수 없습니다. 프로젝트 설정(사이드바의 프로젝트 메뉴)에서 켜세요.")
        }
        // 같은 에이전트로는 인계하지 않는다 — Codex 의 다른 계정은 인계 대신 계정만 바꿔 같은 세션을 이어 간다 (`CodexAccountSwitch`).
        if from == target.provider {
            return failure(from == .codex ? CodexAccountSwitch.notHandoffText : "같은 에이전트로는 인계할 수 없습니다.")
        }
        // 실행 중이면 먼저 정리하도록 알린다 (막 시작하는 중도 같다). 메인 턴을 마치고 백그라운드 작업을 기다리는 중이면
        // 그 수를 덧붙인다 — 답은 끝난 것처럼 보여도 실행은 돌고 있다.
        let session = runner.session(threadID: thread.id)
        if session != nil || isStartingRun(threadID: thread.id) {
            let note = session.map { SubAgentDigest.waitingNote(waiting: $0.isWaitingOnBackground, count: $0.unfinishedSubAgentCount) } ?? ""
            return failure("이 대화에서 에이전트가 실행 중입니다\(note). 끝나기를 기다리거나 중단한 뒤 인계하세요.")
        }
        // 막 끝난 실행의 실행 전후 비교 기록을 기다린다 — 그 요약이 이 초안("완료한 작업")에 들어가고,
        // 초안의 baseSeq 뒤에 늦게 붙어 다음 인계로 넘어가지 않게.
        _ = await runChangeFinishing[project.path]?.value

        // 세션은 대화마다 제공자별 하나다 (Codex 도 계정과 상관없이 — `AgentSession.recordHome`).
        let fromSession = try? await store.session(threadID: thread.id, provider: from)
        let toSession = try? await store.session(threadID: thread.id, provider: target.provider)
        let baseSeq = (try? await store.maxSeq(threadID: thread.id)) ?? 0
        let scope = await handoffScope(runs: runs, handoffs: threadHandoffs, thread: thread)
        // 인계 구간의 새 커밋을 세는 기준 — 앞 인계의 HEAD, 없으면 구간을 시작한 때.
        let env = await environment.childEnvironment()
        let git = await GitInspector.snapshot(at: project.url, environment: env, baseHead: scope.previousPacket?.changedFiles.head,
                                              since: scope.since)
        let fingerprint = await handoffFingerprint(thread: thread, project: project, runs: runs)
        var packet = HandoffPacketBuilder.build(HandoffPacketBuilder.Input(
            thread: thread, project: project, fromProvider: from, toProvider: target.provider,
            fromAccountLabel: fromAccount?.label, toAccountLabel: toAccount?.label,
            events: scope.events, runs: scope.runs, lastConfirmedPacket: scope.previousPacket, git: git, baseSeq: baseSeq,
            handoffs: threadHandoffs))
        packet.summarySource = "rule"
        // Gemini 정리는 쓸 수 있을 때만 — agy 를 찾지 못했으면 부르지 않는다 (앱이 정리한 문서로, 자동 인계를 막지 않는다).
        var geminiRequested = useGemini && geminiAllowed(projectID: project.id)
        if geminiRequested && geminiCLIPath == nil { await refreshGeminiStatus() }
        var geminiFailure: String?
        if geminiRequested && geminiCLIPath == nil {
            geminiRequested = false
            geminiFailure = HandoffCardText.geminiNoCLI
        }
        var validationWarnings: [String] = []
        if geminiRequested {
            let outcome = await applyGeminiSummary(to: packet, thread: thread, project: project, events: scope.events,
                                                   runs: scope.runs, previousPacket: scope.previousPacket, git: git, force: false)
            if outcome.packet.summarySource == "gemini" {
                packet = outcome.packet
                validationWarnings = outcome.warnings
            } else {
                // 정리하지 못했다 — 앱이 정리한 문서 그대로 (검증 경고가 아니다: 자동 인계는 이 문서로 이어 간다).
                geminiFailure = outcome.warnings.first.map { HandoffCardText.geminiFailed($0) }
            }
        }
        let text = HandoffPacketBuilder.render(packet, threadTitle: thread.title, projectPath: project.path,
                                               inWorktree: project.path != mainProject(for: thread)?.path)
        let draftJSON = (try? JSONEncoder().encode(packet)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // 행은 넘길 때 넣는다 (`deliverHandoff`) — 취소한 초안이 DB 에 남지 않게.
        let handoff = Handoff(threadID: thread.id, fromProvider: from, toProvider: target.provider,
                              fromAccountID: fromAccount?.id ?? "", toAccountID: toAccount?.id ?? "",
                              fromSessionID: fromSession?.cliSessionID, baseSeq: baseSeq,
                              draftJSON: draftJSON, finalText: text)
        var draft = HandoffDraft(handoff: handoff, packet: packet, text: text, threadTitle: thread.title,
                                 geminiRequested: geminiRequested, validationWarnings: validationWarnings)
        draft.geminiFailure = geminiFailure
        var card = HandoffCard(draft: draft, origin: origin, automatic: automatic)
        card.fingerprint = fingerprint
        card.receiver = await receiverFacts(target: target,
                                            // 보낼 때와 같은 기준 — `RunSession.send` 는 `resumable` 일 때만 재개한다.
                                            resumable: toSession.map { $0.resumable && !($0.cliSessionID ?? "").isEmpty } ?? false)
        return .success(card)
    }

    /// 인계 구간 — 마지막 확정(전달된) 인계 이후의 이벤트 · 실행 (전체 대화를 무조건 붙이지 않는다), 앞 인계의 패킷, 구간을 시작한 때.
    struct HandoffScope {
        var events: [ThreadEvent]
        var runs: [Run]
        var previousPacket: HandoffPacket?
        /// 새 커밋을 셀 때의 시작 — 앞 인계를 만든 때, 없으면 이 대화의 첫 실행(또는 대화를 만든 때).
        var since: Date
    }

    func handoffScope(runs: [Run], handoffs: [Handoff], thread: ConversationThread) async -> HandoffScope {
        let previous = handoffs.last { $0.deliveryState == .delivered }
        let previousPacket: HandoffPacket? = previous.flatMap {
            guard let data = $0.draftJSON.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(HandoffPacket.self, from: data)
        }
        let sinceSeq = previous?.baseSeq ?? 0
        let allEvents = (try? await store.events(threadID: thread.id)) ?? []
        let scopedEvents = allEvents.filter { $0.seq > sinceSeq }
        let scopedRuns = runs.filter { $0.startedAt >= (previous?.createdAt ?? .distantPast) }
            .sorted { $0.startedAt < $1.startedAt }
        let events = scopedEvents.isEmpty ? allEvents.suffix(80).map { $0 } : scopedEvents
        let since = previous?.createdAt ?? runs.map(\.startedAt).min() ?? thread.createdAt
        return HandoffScope(events: events, runs: scopedRuns, previousPacket: previousPacket, since: since)
    }

    /// 받는 쪽 사실 (카드의 받는 쪽 줄). 자동 인계는 게이트가 새로 잰 값으로 덮는다.
    private func receiverFacts(target: HandoffSource.Agent, resumable: Bool) async -> HandoffCard.ReceiverFacts {
        var facts = HandoffCard.ReceiverFacts()
        // 이 대화에 받는 쪽 제공자의 세션이 있으면 이어 간다 — Codex 는 받는 계정이 그 세션을 만든 계정이 아니어도 (`RunSession.send`).
        facts.session = resumable ? .resumes : .fresh
        guard !Self.offlinePreview else { return facts }   // 화면 확인용 실행은 CLI 를 부르지 않는다
        facts.cliUsable = await environment.checkStatus(target.provider).isUsable
        switch target.provider {
        case .claude:
            facts.authenticated = await claudeReceiverLoginFact()
            facts.authCheckedAt = Date()
        case .codex:
            if let account = accounts.account(target.codexAccountID ?? CodexAccount.defaultID) {
                // 점검표와 같은 판정 — 파일이 아닌 자격 저장소(keyring 등)는 auth.json 이 없어도 "모름" 이다.
                facts.authenticated = codexLoginFact(accountID: account.id)
                facts.authCheckedAt = account.identityCheckedAt
            }
        case .gemini:
            // 한도는 카드의 받는 쪽 줄이 `limits` 를 직접 읽는다 — 카드를 늦추지 않게 뒤에서 새로 읽는다 (1분 안에 읽었으면 그대로).
            Task { await limits.refresh(.gemini) }
        }
        return facts
    }

    /// 초안을 만든 때의 폴더 상태: 대화의 폴더 경로 · 마지막 실행 · git HEAD + 변경 파일 목록 + 변경 내용(`git diff HEAD`) +
    /// 추적하지 않는 파일의 크기 · 수정 시각의 해시. 목록만 보면 이미 바뀐(M) 파일을 다시 고치거나 같은 폴더의 다른 대화가 고쳐도
    /// 지문이 그대로라 문서의 diff 발췌가 낡은 채 넘어갔다.
    func handoffFingerprint(thread: ConversationThread, project: Project, runs: [Run]? = nil) async -> HandoffCard.Fingerprint {
        let allRuns: [Run]
        if let runs { allRuns = runs } else { allRuns = (try? await store.runs(threadID: thread.id)) ?? [] }
        // 인계 전달 실행은 세지 않는다 — 받지 못한 전달(실패)을 다시 넘길 때 카드가 낡은 것으로 보이지 않게.
        // 전달된 인계는 카드가 이미 없다 (다음 카드는 자기 지문을 잰다).
        let lastRun = allRuns.filter { !$0.isHandoffDelivery }.max { $0.startedAt < $1.startedAt }?.id
        let childEnv = await environment.childEnvironment()
        // 저장소가 정한 filter · diff 드라이버를 끄고 색인을 쓰지 않는 환경 (`GitInspector.readEnvironment`) — 확인하지 못하면 git 상태 없이.
        guard let git = GitInspector.findGit(environment: childEnv),
              let env = await GitInspector.readEnvironment(git: git, at: project.url, environment: childEnv) else {
            return HandoffCard.Fingerprint(folderPath: project.path, lastRunID: lastRun, gitState: nil)
        }
        func run(_ arguments: [String]) async -> String? {
            if case .success(let output) = await CLIEnvironment.captureOutput(executable: git, arguments: GitInspector.commandArguments(arguments), environment: env,
                                                                               workingDirectory: project.url, timeout: 20) {
                return output
            }
            return nil
        }
        guard let status = await run(["--no-optional-locks", "status", "--porcelain=v1", "--untracked-files=all"]
                                        + GitInspector.submoduleReadArguments) else {
            return HandoffCard.Fingerprint(folderPath: project.path, lastRunID: lastRun, gitState: nil)
        }
        let head = (await run(["rev-parse", "HEAD"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ text: String) {
            for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            hash = (hash ^ 0xff) &* 0x100000001b3   // 구분자 — 조각 경계가 옮겨 가도 같은 해시가 되지 않게
        }
        mix(status)
        // 변경 내용 — 커밋이 없는 저장소는 HEAD 와 비교할 수 없어 스테이지 · 작업 트리를 따로.
        let diffBase = ["--no-optional-locks", "diff", "--binary"] + GitInspector.readDiffArguments
        if !head.isEmpty, let diff = await run(diffBase + ["HEAD"]) {
            mix(diff)
        } else {
            mix(await run(diffBase + ["--cached"]) ?? "")
            mix(await run(diffBase) ?? "")
        }
        // 추적하지 않는 파일은 diff 에 없다 — 크기와 수정 시각으로 (내용을 다 읽지 않게, 앞의 2천 개).
        if let untracked = await run(["--no-optional-locks", "ls-files", "--others", "--exclude-standard", "-z"]) {
            for path in GitWorkspace.splitNul(untracked).filter({ !$0.isEmpty }).prefix(2000) {
                let attributes = try? FileManager.default.attributesOfItem(atPath: project.url.appendingPathComponent(path).path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
                let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                mix("\(path)\u{0}\(size)\u{0}\(modified)")
            }
        }
        return HandoffCard.Fingerprint(folderPath: project.path, lastRunID: lastRun,
                                       gitState: (head.isEmpty ? "no-head" : head) + ":" + String(hash, radix: 16))
    }

    // MARK: - 자동 인계

    struct AutomaticHandoffTarget: Identifiable, Hashable {
        var id: String { key }
        var key: String
        var provider: AgentProvider
        var accountID: String
        var title: String
        var scope: AgentScope { AgentScope(provider: provider, accountID: accountID) }
    }

    /// 설정의 이어 받을 순서 (우선순위 순) — "받지 않음" 으로 둔 대상도 (그 줄에서 다시 켠다).
    var automaticHandoffTargetOrder: [AutomaticHandoffTarget] {
        var all = [AutomaticHandoffTarget(key: AutomaticHandoffTargets.key(.claude, ""),
                                          provider: .claude, accountID: "", title: "Claude")]
        for account in accounts.accounts {
            all.append(AutomaticHandoffTarget(key: AutomaticHandoffTargets.key(.codex, account.id),
                                              provider: .codex, accountID: account.id,
                                              title: "Codex · \(account.label)"))
        }
        let byKey = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return AutomaticHandoffTargets.resolve(saved: automaticHandoffPriority, available: all.map(\.key))
            .compactMap { byKey[$0] }
    }

    /// 이어 받을 대상 (우선순위 순) — 자동 인계 · 이어 가기 제안 · 한도 줄이 같이 쓴다. "받지 않음" 으로 둔 대상은 뺀다 (set-15).
    var automaticHandoffTargets: [AutomaticHandoffTarget] {
        automaticHandoffTargetOrder.filter { !automaticHandoffExcluded.contains($0.key) }
    }

    func moveAutomaticHandoffTarget(_ key: String, by offset: Int) {
        var keys = automaticHandoffTargetOrder.map(\.key)
        guard let index = keys.firstIndex(of: key) else { return }
        let destination = index + offset
        guard keys.indices.contains(destination) else { return }
        keys.swapAt(index, destination)
        automaticHandoffPriority = keys
    }

    /// 이어 받을 순서의 한 대상을 받게 · 받지 않게 한다.
    func setAutomaticHandoffTarget(_ key: String, receives: Bool) {
        if receives { automaticHandoffExcluded.remove(key) } else { automaticHandoffExcluded.insert(key) }
    }

    /// 한도에 걸린 실행 뒤, 우선순위와 **확인된** 한도 여유로 대상을 골라 자동 인계 카드를 준비한다.
    /// 고를 대상이 없어도 초안은 만든다 — 게이트가 막고 검토 카드에 후보별 제외 사유를 보인다.
    func startAutomaticHandoff(after run: Run) async {
        guard let thread = (try? await store.thread(id: run.threadID)) ?? nil else { return }
        guard !hasHandoffActivity(threadID: thread.id) else { return }
        // 아래 조회(실제 CLI — 몇 초)를 기다리는 사이 사람이 인계를 열었는지 (넘겼든 취소했든) 보려고 지금의 준비 횟수를 적어 둔다.
        let preparationSerial = handoffPreparationSerials[thread.id] ?? 0
        let fromAccountID = run.provider == .codex ? (run.codexAccountID ?? thread.codexAccountID) : ""
        let fromKey = AutomaticHandoffTargets.key(run.provider, fromAccountID)
        let targets = automaticHandoffTargets
        await limits.refreshAll(force: true)
        await accounts.refreshAllIdentities()
        var cliUsable: [AgentProvider: Bool] = [:]
        for provider in Set(targets.map(\.provider)) {
            cliUsable[provider] = await environment.checkStatus(provider, force: true).isUsable
        }
        // 이 대화가 API 크레딧으로 실행하면 받는 쪽 Claude 는 구독 로그인 · 한도를 보지 않는다 (사람이 이 대화를 API 로 골랐다).
        let claudeByAPI = usesClaudeAPI(threadID: thread.id)
        let claudeLoggedIn = !claudeByAPI && targets.contains { $0.provider == .claude } ? await claudeLoginCheck() : nil
        let candidates = targets.map { target in
            // 제외 사유의 이름은 카드 · 입력창과 같은 이름으로 (계정이 하나면 "Codex") — 설정의 우선순위 목록 제목과 다르다.
            AutomaticHandoffCandidate(
                provider: target.provider, accountID: target.accountID,
                title: automaticCandidateName(provider: target.provider, accountID: target.accountID),
                cliUsable: cliUsable[target.provider] ?? false,
                authenticated: target.provider == .claude
                    ? claudeByAPI || claudeLoggedIn == true
                    : accounts.accountOrDefault(target.accountID).authStatus == .loggedIn,
                limit: limits.snapshot(target.scope),
                usesAPICredit: target.provider == .claude && claudeByAPI)
        }
        let selection = AutomaticHandoffTargets.select(candidates, fromKey: fromKey)
        // 아무도 통과하지 못했으면 검토 카드의 받는 쪽 — CLI 를 쓸 수 없는 후보는 권하지 않는다 (설치하지 않은 에이전트를 받는 쪽으로 한
        // 카드 · "검토가 필요합니다" 알림이 한도마다 오지 않게).
        let fallback = candidates.first { $0.key != fromKey && $0.cliUsable }
        guard let target = selection.chosen ?? fallback else {
            // 고를 대상이 없다 — "받지 않음" 으로 뺀 에이전트만 남았으면 그 사실과 설정 > 인계로 ("CLI 를 찾지 못했다" 고 하지 않는다, hand-4).
            let excludedNames = automaticHandoffTargetOrder
                .filter { automaticHandoffExcluded.contains($0.key) && $0.key != fromKey && cliStatus[$0.provider]?.isUsable != false }
                .map { automaticCandidateName(provider: $0.provider, accountID: $0.accountID) }
            let notice = AutomaticHandoffGate.noTargetNotice(excludedNames: excludedNames)
            banner = BannerMessage(text: notice.text, isError: false, actionTitle: notice.actionTitle, threadID: thread.id,
                                   opens: notice.opens)
            return
        }
        // 다른 후보를 뺀 까닭 — 카드의 받는 쪽이 된 후보(아무도 통과하지 못해 고른 대비책)는 빼지 않았으니 "제외" 라 적지 않는다.
        // 그 까닭은 게이트의 이유 · 받는 쪽 줄의 사실(로그인 · 한도)이 이미 말한다.
        let notes = selection.skipped.filter { $0.title != target.title }
            .map { "\($0.title) 제외: \($0.reasons.joined(separator: " "))" }
        let scope = AgentScope(provider: run.provider, accountID: fromAccountID)
        // Antigravity 는 그 실행의 모델이 쓰는 묶음의 창으로 (`scoped` — 다른 제공자는 그대로).
        let resetsAt = limits.snapshot(scope).scoped(toAntigravityModel: run.model).capResetsAt()
        // 위의 조회를 기다리는 몇 초 사이 사람이 이 대화에서 무언가 했으면 이 자동 인계는 지난 일이다 — 사람의 결정이 이긴다:
        // 카드를 열었다(한도 줄의 인계 단추 · ⇧⌘H · 칩 메뉴 — 지금 있든, 취소했든, 이미 넘겼든), 새 실행을 보냈다.
        let laterRun = ((try? await store.runs(threadID: thread.id)) ?? [])
            .contains { $0.id != run.id && $0.startedAt > run.startedAt }
        guard !laterRun, !hasHandoffActivity(threadID: thread.id),
              (handoffPreparationSerials[thread.id] ?? 0) == preparationSerial,
              runner.session(threadID: thread.id) == nil, !isStartingRun(threadID: thread.id) else { return }
        // 고른 대상이 같은 Codex 의 다른 계정이면 인계 카드가 아니라 카운트다운 뒤 계정을 바꿔 같은 세션을 이어 간다 (`CodexAccountSwitch`).
        // 확인을 통과한 대상일 때만 — 아무도 통과하지 못해 고른 대비책이면 자동으로 이어 가지 않고 까닭을 알린다 (한도 줄의 단추가 남는다).
        let sourceAgent = HandoffSource.Agent(provider: run.provider, codexAccountID: run.provider == .codex ? fromAccountID : nil)
        let targetAgent = HandoffSource.Agent(provider: target.provider,
                                              codexAccountID: target.provider == .codex ? target.accountID : nil)
        if isCodexAccountSwitch(from: sourceAgent, to: targetAgent) {
            if selection.chosen != nil {
                startCodexSwitchCountdown(threadID: thread.id, source: sourceAgent, target: targetAgent, limitRun: run)
            } else {
                let reasons = selection.skipped.first { $0.title == target.title }?.reasons ?? []
                banner = BannerMessage(text: CodexAccountSwitch.skippedNote(target: target.title, reasons: reasons),
                                       isError: false, threadID: thread.id)
            }
            return
        }
        // 보내는 쪽은 한도에 걸린 이 실행의 에이전트 — 대상 선택(`fromKey`)과 같은 기준이다.
        await prepareCard(threadID: thread.id, target: target.provider,
                          toAccountID: target.provider == .codex ? target.accountID : nil,
                          origin: .limitReached(scope: scope, resetsAt: resetsAt), automatic: true, automaticNotes: notes,
                          source: HandoffSource.Agent(provider: run.provider,
                                                      codexAccountID: run.provider == .codex ? fromAccountID : nil))
    }

    /// 자동 인계 후보의 이름 (게이트 제외 사유 · 검토 알림) — 카드 · 입력창의 받는 쪽 이름과 같다 (`handoffPartyName`).
    func automaticCandidateName(provider: AgentProvider, accountID: String) -> String {
        handoffPartyName(HandoffSource.Agent(provider: provider, codexAccountID: provider == .codex ? accountID : nil))
    }

    /// 자동 인계의 게이트 — 새로 잰 받는 쪽 사실과 막는 이유 (`AutomaticHandoffGate`).
    private func automaticGate(for card: HandoffCard) async -> (reasons: [String], receiver: HandoffCard.ReceiverFacts) {
        let target = card.targetProvider
        let accountID = card.draft.handoff.toAccountID
        let scope = AgentScope(provider: target, accountID: target == .codex ? accountID : "")
        // 대상 선택에서 방금 조회했다. Gemini 정리가 길어져 1분이 지났을 때만 다시 조회한다.
        await limits.refresh(scope)
        let targetStatus = await environment.checkStatus(target, force: true)
        // 카드에 남길 사실(모름은 nil)과 게이트의 판정(확인된 로그인만 통과)을 나눈다 — 해석하지 못한 확인을 "로그인 안 됨" 으로 그리지 않게
        // (수동 카드의 `receiverFacts` 와 같은 사실).
        let loginFact: Bool? = target == .claude ? await claudeReceiverLoginFact() : codexLoginFact(accountID: accountID)
        // 이 대화의 API 크레딧으로 받는 Claude — 구독 로그인 · 한도를 보지 않는다.
        let byAPI = target == .claude && usesClaudeAPI(threadID: card.threadID)
        let targetAuthenticated = target == .claude ? byAPI || loginFact == true
                                                    : accounts.accountOrDefault(accountID).authStatus == .loggedIn
        let threadID = card.threadID
        let existing = (try? await store.handoffs(threadID: threadID)) ?? []
        let lastDeliveredAt = existing.last(where: { $0.deliveryState == .delivered })?.createdAt ?? .distantPast
        let hasUnknown = existing.contains {
            $0.id != card.draft.handoff.id && $0.deliveryState == .unknown && $0.createdAt > lastDeliveredAt
        }
        let newerEvents = (try? await store.events(threadID: threadID, afterSeq: card.draft.handoff.baseSeq)) ?? []
        let reasons = AutomaticHandoffGate.blockingReasons(.init(
            hasUnterminatedProcess: !runner.unterminatedProcesses.isEmpty,
            hasPendingDecision: runner.session(threadID: threadID).map { !$0.pendingApprovals.isEmpty || !$0.pendingQuestions.isEmpty } ?? false,
            hasActiveRun: runner.session(threadID: threadID) != nil,
            // 하위 에이전트에게 준 프롬프트(부모 표시가 붙은 userMessage)는 사람이 한 일이 아니다.
            userActedAfterDraft: newerEvents.contains { $0.kind == .userMessage && $0.isMainStream },
            hasUnknownPreviousDelivery: hasUnknown,
            targetCLIUsable: targetStatus.isUsable,
            targetAuthenticated: targetAuthenticated,
            targetLimit: limits.snapshot(scope), targetUsesAPICredit: byAPI, nextActions: card.draft.packet.nextActions,
            geminiWasRequested: card.draft.geminiRequested,
            // 정리하지 못해 앱이 정리한 문서로 대신했으면 막지 않는다 (Gemini 를 쓰지 않는 자동 인계와 같다). 정리본에 검증 경고가 있을 때만.
            geminiSucceededWithoutWarnings: card.draft.packet.summarySource != "gemini" || card.draft.validationWarnings.isEmpty))
        var receiver = card.receiver
        receiver.cliUsable = targetStatus.isUsable
        if target != .gemini {
            receiver.authenticated = loginFact
            receiver.authCheckedAt = Date()
        }
        return (reasons, receiver)
    }

    /// 게이트를 통과한 자동 인계의 카운트다운. 대화마다 따로 돈다 — 다른 대화의 카운트다운을 취소하지 않는다.
    /// 타이머는 카드의 사본을 잡지 않는다: 울릴 때 그 대화의 카드를 id 로 찾아 아직 카운트다운이면 보낸다.
    func startAutomaticHandoffCountdown(threadID: String) {
        guard var card = handoffCards[threadID], card.canBeginSend else { return }
        // 앱 종료를 묻는 중 · 종료하는 중에 준비가 끝난 자동 카드는 타이머 없이 확인 길로 둔다 (`suspendHandoffsForQuit`).
        guard !handoffsSuspendedForQuit else {
            card.review = .pausedByHuman
            handoffCards[threadID] = card
            return
        }
        let delay = automaticHandoffDelay
        card.phase = .countingDown(deadline: Date().addingTimeInterval(TimeInterval(delay)), delay: delay)
        card.review = nil
        card.lastError = nil
        handoffCards[threadID] = card
        let target = handoffPartyName(card.draft.target, label: card.draft.packet.toAccountLabel)
        notifications.post(category: .automaticHandoff,
                           title: HandoffCardText.countdown(seconds: delay, target: target),
                           body: "\(card.draft.threadTitle) · 앱에서 멈추거나 알림의 단추로 취소 · 검토할 수 있습니다.",
                           threadID: threadID, opensHandoff: true)
        automaticHandoffTasks[threadID]?.cancel()
        let cardID = card.id
        automaticHandoffTasks[threadID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.countdownFired(threadID: threadID, cardID: cardID)
        }
    }

    private func countdownFired(threadID: String, cardID: String) async {
        guard let card = handoffCards[threadID], card.id == cardID, card.isCountingDown else { return }
        // 이 작업 자신을 취소하지 않게 먼저 비운다 (`beginSend` 가 타이머를 끈다).
        automaticHandoffTasks[threadID] = nil
        guard beginSend(threadID: threadID, draftID: cardID) else { return }
        await deliverHandoff(threadID: threadID, cardID: cardID, humanReviewed: false)
    }

    // MARK: - 멈추기 · 취소

    /// 카운트다운을 멈춘다 (동기) — 덧붙일 말 칸에 포커스가 들어갈 때 · 문서 열어 고치기 · 바꾸기 · Gemini 재정리 ·
    /// 받는 모델 바꾸기 · 확인 체크 · 입력창에서 대기열에 걸 때 · 알림의 검토 · 취소. 멈춘 카드는 사람 확인(체크) 길로 보낸다.
    /// 카드가 아직 없고 준비 중이면 표시만 해 둔다 — 그 준비가 놓는 자동 카드는 카운트다운 없이 확인 길로 (`prepareCard`).
    func pauseCountdown(threadID: String) {
        guard var card = handoffCards[threadID] else {
            if handoffPreparations[threadID] != nil { handoffTouchedDuringPreparation.insert(threadID) }
            return
        }
        guard card.isCountingDown else { return }
        automaticHandoffTasks[threadID]?.cancel()
        automaticHandoffTasks[threadID] = nil
        card.phase = .ready
        card.review = .pausedByHuman
        handoffCards[threadID] = card
    }

    /// 앱 종료를 묻기 전에 (`applicationShouldTerminate`, 확인창보다 먼저) 부른다: 카운트다운 타이머를 모두 끄고 그 카드를 사람이
    /// 멈춘 카드로 두며, 종료가 끝나거나 취소될 때까지 인계를 새로 보내지 않는다 (`beginSend` · 전달 직전 확인).
    /// 확인창이 떠 있는 동안에도 메인 액터 작업은 돈다 — 그 사이 타이머가 울려 전달 CLI 를 띄우면, `shutdownForQuit` 이 처음에 떠 둔
    /// 목록에 없어 정리되지 않은 채 앱이 끝났다. 종료를 취소하면 `resumeHandoffsAfterCancelledQuit` (멈춘 카드는 확인 길로 남는다).
    func suspendHandoffsForQuit() {
        handoffsSuspendedForQuit = true
        for threadID in Array(handoffCards.keys) { pauseCountdown(threadID: threadID) }
        // 다른 Codex 계정에서 이어 가려던 카운트다운도 멈춘다 (종료를 취소하면 한도 줄의 단추로 사람이 고른다). 확인 글이 그 수를
        // 말하도록 앱 층은 이보다 먼저 센다 (`quitFacts` → `QuitConfirmation.Facts.codexSwitches`).
        for threadID in Array(codexSwitchCountdowns.keys) { cancelCodexSwitchCountdown(threadID: threadID) }
        for task in automaticHandoffTasks.values { task.cancel() }
        automaticHandoffTasks.removeAll()
    }

    func resumeHandoffsAfterCancelledQuit() {
        handoffsSuspendedForQuit = false
    }

    /// 종료 확인창이 닫힌 뒤 다시 센다: 거둘 실행이 있는가 (도는 · 시작 중인 실행 · 전달 중인 인계). 있으면 `shutdownForQuit` 길로.
    var hasRunsToShutDownForQuit: Bool {
        !activeSessions.isEmpty || isStartingRun || !deliveringHandoffs.isEmpty
    }

    enum HandoffCancelOrigin: Sendable {
        /// 카드의 [취소] · 미확인 카드의 [닫기].
        case card
        /// 알림의 [자동 인계 취소].
        case notification
    }

    /// 취소는 되돌릴 수 없는 지점(보내는 중) 전까지만. 카드의 취소 = 카드를 지우고 보류 중인 대기열을 이유와 함께 멈춘다
    /// (준비 중이면 준비를 버린다). 알림의 취소 = 카운트다운을 멈추고 검토 카드로 (대기열은 계속 보류). 받았으면 true.
    @discardableResult
    func cancelHandoff(threadID: String, origin: HandoffCancelOrigin, keepMoved: Bool = false) -> Bool {
        guard var card = handoffCards[threadID] else {
            // 알림은 알림 센터에 남는다 — 카드가 사라진 뒤(전달 실행이 도는 중 · 이미 넘김)에 누른 취소는 말없이 버리지 않고 알린다.
            if origin == .notification, let late = lateNotificationCancel(threadID: threadID) {
                postLateNotificationCancel(late, threadID: threadID)
                return false
            }
            // 칸에 열려 있지 않은 대화는 인계 기록이 메모리에 없다 — 저장소의 마지막 인계로 판정한다 (말없이 버리지 않게).
            if origin == .notification, handoffPreparations[threadID] == nil, threadStates[threadID] == nil {
                Task {
                    if let late = await lateNotificationCancelFromStore(threadID: threadID) {
                        postLateNotificationCancel(late, threadID: threadID)
                    }
                }
                return false
            }
            // 준비 중인 것 — 카드의 자리에서 취소했다. 늦게 끝난 준비는 토큰이 달라 버려진다.
            guard origin == .card, handoffPreparations[threadID] != nil else { return false }
            handoffPreparations[threadID] = nil
            releaseHold(threadID: threadID, .cancelled)
            return true
        }
        if card.isSending {
            switch origin {
            case .card:
                card.lastError = "이미 보내는 중입니다"
                handoffCards[threadID] = card
            case .notification:
                notifications.post(category: .limitReached, title: HandoffLateCancel.sending.title,
                                   body: "\(card.draft.threadTitle) · 인계를 되돌릴 수 없습니다.", threadID: threadID)
            }
            return false
        }
        switch origin {
        case .notification:
            pauseCountdown(threadID: threadID)
        case .card:
            automaticHandoffTasks[threadID]?.cancel()
            automaticHandoffTasks[threadID] = nil
            handoffCards[threadID] = nil
            // 다시 만드는 중이던 준비도 버린다 (늦게 끝나 취소한 카드를 되살리지 않게).
            handoffPreparations[threadID] = nil
            if handoffCardFocusThreadID == threadID { handoffCardFocusThreadID = nil }
            // 덧붙일 말로 옮겼던 메시지는 대기열로 되돌린다 — 멈춘 채로 (아래의 멈춤 이유). 다시 만들기는 새 카드로 옮긴다.
            if !keepMoved { restoreMovedMessages(card.movedMessages, threadID: threadID) }
            releaseHold(threadID: threadID, card.phase == .unknown ? .unknownClosed : .cancelled)
        }
        return true
    }

    /// 카드가 없는 대화에 온 알림의 취소가 늦었는가 — 전달 실행이 도는 중이면 `.sending`, 마지막 인계가 전달됐으면 `.delivered`.
    func lateNotificationCancel(threadID: String) -> HandoffLateCancel? {
        guard handoffCards[threadID] == nil, handoffPreparations[threadID] == nil else { return nil }
        if deliveringHandoffs[threadID] != nil { return .sending }
        if threadStates[threadID]?.handoffs.max(by: { $0.createdAt < $1.createdAt })?.deliveryState == .delivered {
            return .delivered
        }
        return nil
    }

    /// `lateNotificationCancel` 의 저장소 판정 — 칸에 열려 있지 않은 대화(`threadStates` 가 없다)의 마지막 인계 행으로.
    func lateNotificationCancelFromStore(threadID: String) async -> HandoffLateCancel? {
        if let late = lateNotificationCancel(threadID: threadID) { return late }
        guard handoffCards[threadID] == nil, handoffPreparations[threadID] == nil else { return nil }
        let rows = (try? await store.handoffs(threadID: threadID)) ?? []
        switch rows.max(by: { $0.createdAt < $1.createdAt })?.deliveryState {
        case .delivered?: return .delivered
        case .sending?: return .sending
        default: return nil
        }
    }

    private func postLateNotificationCancel(_ late: HandoffLateCancel, threadID: String) {
        notifications.post(category: .limitReached, title: late.title,
                           body: "\(paneThread(threadID)?.title ?? "") · 인계를 되돌릴 수 없습니다.", threadID: threadID)
    }

    // MARK: - 카드의 칸

    /// 입력창에 걸어 둔(보류된) 메시지 중 덧붙일 말로 옮길 수 있는 것 — 글만 있는 것 (덧붙일 말은 글뿐이다).
    func heldMessagesForMemo(threadID: String) -> [QueuedMessage] {
        guard queueHolds[threadID] != nil, !isHandoffDeliveryUnknown(threadID: threadID) else { return [] }
        return queuedMessages(threadID: threadID).filter {
            $0.images.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 걸어 둔 메시지를 카드의 덧붙일 말로 옮긴다 (hnd-6) — 다음 행동을 앱이 찾지 못했을 때 할 일을 적을 곳을 하나로. 옮긴 메시지는
    /// 인계 문서와 함께 한 번에 가고(따로 한 턴을 쓰지 않는다) 대기열에서 빠진다. 이미지가 붙은 메시지는 대기열에 남아 인계 뒤에 간다.
    func moveHeldMessagesToMemo(threadID: String) {
        let movable = heldMessagesForMemo(threadID: threadID)
        guard !movable.isEmpty, let card = handoffCards[threadID], !card.isSending, card.phase != .unknown else { return }
        pauseCountdown(threadID: threadID)
        guard var latest = handoffCards[threadID], latest.id == card.id else { return }
        let memo = latest.userMemo.trimmingCharacters(in: .whitespacesAndNewlines)
        let texts = movable.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        latest.userMemo = ([memo].filter { !$0.isEmpty } + texts).joined(separator: "\n\n")
        latest.movedMessages += movable
        handoffCards[threadID] = latest
        let moved = Set(movable.map(\.id))
        let rest = queuedMessages(threadID: threadID).filter { !moved.contains($0.id) }
        messageQueues[threadID] = rest.isEmpty ? nil : rest
    }

    /// 덧붙일 말로 옮겼던 메시지를 대기열에 되돌린다 — 걸어 둔 순서대로 (이미 대기열에 있는 것은 그대로).
    func restoreMovedMessages(_ moved: [QueuedMessage], threadID: String) {
        guard !moved.isEmpty else { return }
        let queued = queuedMessages(threadID: threadID)
        let present = Set(queued.map(\.id))
        let restored = (queued + moved.filter { !present.contains($0.id) }).sorted { $0.createdAt < $1.createdAt }
        messageQueues[threadID] = restored
    }

    /// 앱 종료: 카드는 메모리라 사라진다 — 덧붙일 말로 옮겼던 메시지를 대기열에 되돌려 저장까지 마친다 (다시 켜면 멈춘 채로 남는다).
    /// 종료 확인 뒤, DB 를 닫기 전에 부른다.
    func restoreMovedMessagesForQuit() async {
        let cards = handoffCards.values.filter { !$0.movedMessages.isEmpty }
        guard !cards.isEmpty else { return }
        for card in cards { restoreMovedMessages(card.movedMessages, threadID: card.threadID) }
        try? await store.setSetting("message_queue", Self.jsonString(messageQueues))
    }

    /// 종료 때 되돌릴 메시지가 있다 (그러면 저장을 마칠 때까지 종료를 미룬다).
    var hasMovedMessagesToRestore: Bool { handoffCards.values.contains { !$0.movedMessages.isEmpty } }

    func setHandoffMemo(_ text: String, threadID: String) {
        guard var card = handoffCards[threadID], !card.isSending, card.userMemo != text else { return }
        card.userMemo = text
        handoffCards[threadID] = card
    }

    /// "내용을 확인했습니다" — 체크하면 카운트다운이 멈춘다 (사람이 판단했다).
    func setHandoffConfirmed(_ confirmed: Bool, threadID: String) {
        pauseCountdown(threadID: threadID)
        guard var card = handoffCards[threadID], !card.isSending else { return }
        card.confirmed = confirmed
        handoffCards[threadID] = card
    }

    /// 문서 열어 고치기 · 닫기. 열면 카운트다운이 멈춘다.
    func setHandoffEditorOpen(_ open: Bool, threadID: String) {
        if open { pauseCountdown(threadID: threadID) }
        guard var card = handoffCards[threadID], !card.isSending else { return }
        card.editorOpen = open
        handoffCards[threadID] = card
    }

    /// 문서 전문 보기 (읽기만 — 카운트다운을 멈추지 않는다).
    func setHandoffDocumentShown(_ shown: Bool, threadID: String) {
        guard var card = handoffCards[threadID] else { return }
        card.documentShown = shown
        handoffCards[threadID] = card
    }

    func setHandoffEditedText(_ text: String, threadID: String) {
        guard var card = handoffCards[threadID], !card.isSending, card.draft.editedText != text else { return }
        pauseCountdown(threadID: threadID)
        card = handoffCards[threadID] ?? card
        card.draft.editedText = text
        handoffCards[threadID] = card
    }

    func setHandoffExpanded(_ expanded: Bool, threadID: String) {
        guard var card = handoffCards[threadID] else { return }
        card.expanded = expanded
        handoffCards[threadID] = card
    }

    /// 키보드 포커스가 카드 안(덧붙일 말 · 문서 편집)에 들어오고 나간다 — ⌘↵ 의 주인을 가른다 (`ChangesState.returnKeyOwner`).
    /// 덧붙일 말 칸에 포커스가 들어오면 카운트다운이 멈춘다 (글자 변경이 아니라 포커스로 — 한글 조합 중에는 변경이 오지 않는다).
    func setHandoffCardFocus(threadID: String, focused: Bool, pausesCountdown: Bool = true) {
        if focused {
            handoffCardFocusThreadID = threadID
            if pausesCountdown { pauseCountdown(threadID: threadID) }
        } else if handoffCardFocusThreadID == threadID {
            handoffCardFocusThreadID = nil
        }
    }

    // MARK: - 막힘

    /// 이 대화의 카드를 지금 보낼 수 없는 이유 (카드 안의 막힘 이유 — `deliverHandoff` 와 같은 판정). 보낼 수 있으면 nil.
    func handoffSendBlock(threadID: String) -> HandoffSendBlock? {
        guard let card = handoffCards[threadID], let thread = paneThread(threadID), let project = folderProject(for: thread) else {
            return nil
        }
        return HandoffSendBlock.first(handoffSendFacts(card: card, thread: thread, project: project))
    }

    func handoffSendFacts(card: HandoffCard, thread: ConversationThread, project: Project) -> HandoffSendFacts {
        var facts = HandoffSendFacts()
        facts.summarizing = card.summarizing
        facts.remaking = handoffPreparations[thread.id] != nil
        facts.stale = card.isStale
        let handoff = card.draft.handoff
        if handoff.toProvider == .codex {
            if !isRegisteredCodexAccount(handoff.toAccountID) { facts.receiverAccountMissing = true }
            if handoff.fromProvider == .codex && handoff.toAccountID == handoff.fromAccountID { facts.sameAccount = true }
        }
        facts.receiverUnavailable = receiverUnavailableReason(card)
        if handoff.toProvider == .gemini {
            if !antigravityAllowed(projectID: project.id) {
                facts.antigravityNotAllowed = true
            } else {
                let scope = thread.scope(for: .gemini)
                if refreshingModels.contains(scope) {
                    facts.antigravityRefreshing = true
                } else if let block = antigravityBlock(for: thread),
                          !(block == .catalogUnknown && modelCatalogs[scope] == nil) {
                    // 목록을 한 번도 조회하지 않았으면 적지 않는다 — 넘기기가 목록을 조회한 뒤 판정한다.
                    facts.antigravityBlock = block.message
                }
            }
        }
        if let session = runner.session(threadID: thread.id), session.isBusy {
            facts.runActive = true
            facts.runWaitingNote = SubAgentDigest.waitingNote(waiting: session.isWaitingOnBackground,
                                                              count: session.unfinishedSubAgentCount)
        }
        // 보내는 중인 카드는 스스로 "시작하는 중" 이다 (`deliverHandoff` 의 beginStarting) — 그것으로 막지 않는다.
        facts.starting = isStartingRun(threadID: thread.id) && !card.isSending
        facts.unterminated = !runner.unterminatedProcesses.isEmpty
        facts.reviewing = isReviewing(inProjectPath: project.path)
        if let operation = runningGitOperation, runningGitProjectPath == project.path { facts.gitOperation = operation.koreanName }
        if let operation = worktreeActivity(threadID: thread.id, path: project.path) {
            facts.worktreeOperation = operation.kind.koreanName
        }
        facts.worktreeProblem = worktreeProblem(thread)
        return facts
    }

    /// Antigravity 로 인계할 때의 막힘 문장 (옛 시트의 이유 줄과 같은 규칙). 시험 · 화면이 쓴다.
    func handoffBlockReason(threadID: String) -> String? { handoffSendBlock(threadID: threadID)?.message }

    /// 카드의 받는 쪽을 쓸 수 없다고 **확인됐으면** 그 까닭 (칩 메뉴와 같은 판정 `ContinueChoice.handoffBlock`) — CLI 설치 안 됨 ·
    /// 실행 불가 · 로그인 안 됨. 카드의 받는 쪽 사실(만들 때 · 게이트 · [다시 확인] 이 잰 값)로 본다. 로그인 "모름" 은 막지 않는다.
    /// 주입된 어댑터로 도는 시험 · 화면 확인은 CLI 를 보지 않는다 (`RunSession.deliver` 와 같다).
    /// 이 대화의 API 크레딧으로 받는 Claude 는 구독 로그인을 보지 않는다 (`receiverReadiness(_:threadID:)` 와 같다).
    func receiverUnavailableReason(_ card: HandoffCard) -> String? {
        let provider = card.targetProvider
        let readiness: AgentReadiness
        if card.receiver.cliUsable == false, runner.adapterFactory == nil {
            readiness = pathOverride(provider) != nil ? .pathInvalid : .notInstalled
        } else if card.receiver.authenticated == false, !receivesWithClaudeAPI(card.draft.target, threadID: card.threadID) {
            readiness = .notLoggedIn
        } else {
            return nil
        }
        return ContinueChoice.handoffBlock(readiness, provider: provider)?.help
    }

    /// 받는 쪽 사실을 다시 확인한다 — 검토 카드 · 막힘 줄의 [다시 확인] (hnd-10). CLI · 로그인 · 한도를 새로 읽어 카드의 받는 쪽 줄을
    /// 고치고, 게이트가 막은 이유 중 받는 쪽에 관한 것(`AutomaticHandoffGate.ReasonKind.receiverUnchecked` · `receiverCapped`)을 지금
    /// 사실로 다시 적는다. 다른 이유(실행 중 · 새 입력 …)는 그대로. 자동으로 보내지 않는다 — 사람이 확인하고 넘긴다.
    func recheckHandoffReceiver(threadID: String) async {
        guard var card = handoffCards[threadID], !card.isSending, !card.recheckingReceiver else { return }
        card.recheckingReceiver = true
        handoffCards[threadID] = card
        let target = card.draft.target
        let scope = AgentScope(provider: target.provider, accountID: target.provider == .codex ? (target.codexAccountID ?? "") : "")
        await limits.refresh(scope, force: true)
        let status = await environment.checkStatus(target.provider, force: true)
        cliStatus[target.provider] = status
        var authenticated: Bool?
        switch target.provider {
        case .claude:
            let loggedIn = await claudeLoginCheck()
            applyClaudeLogin(LoginCheck(loggedIn: loggedIn, checkedAt: Date()))
            authenticated = loggedIn == false && claudeAlternativeAuth ? nil : loggedIn
        case .codex:
            await accounts.refreshIdentity(target.codexAccountID ?? CodexAccount.defaultID)
            authenticated = codexLoginFact(accountID: target.codexAccountID ?? CodexAccount.defaultID)
        case .gemini:
            authenticated = nil
        }
        guard var latest = handoffCards[threadID], latest.id == card.id else { return }
        latest.recheckingReceiver = false
        latest.receiver.cliUsable = status.isUsable
        if target.provider != .gemini {
            latest.receiver.authenticated = authenticated
            latest.receiver.authCheckedAt = Date()
        }
        if case .automaticBlocked(let reasons)? = latest.review {
            let kept = reasons.filter {
                let kind = AutomaticHandoffGate.kind(of: $0)
                return kind != .receiverUnchecked && kind != .receiverCapped
            }
            let receiverProblems = target.provider == .gemini ? [] : AutomaticHandoffGate.targetProblems(
                cliUsable: status.isUsable, authenticated: authenticated == true, limit: limits.snapshot(scope),
                usesAPICredit: receivesWithClaudeAPI(target, threadID: threadID))
            latest.review = .automaticBlocked(receiverProblems + kept)
        }
        handoffCards[threadID] = latest
    }

    // MARK: - 보내기

    /// 보내기를 점유한다 (동기 — 모든 보내기 입구가 첫 await 전에 부른다). 카드가 있고 id 가 같고 넘길 수 있는 단계이며
    /// 재정리 중이 아닐 때만 "보내는 중" 으로 바꾸고 타이머를 끈다. 점유했으면 true.
    @discardableResult
    func beginSend(threadID: String, draftID: String) -> Bool {
        // 앱 종료를 묻는 중 · 종료하는 중에는 새로 보내지 않는다 (띄운 전달 CLI 를 거두지 못한다).
        guard !handoffsSuspendedForQuit else { return false }
        guard var card = handoffCards[threadID], card.id == draftID, card.canBeginSend else { return false }
        automaticHandoffTasks[threadID]?.cancel()
        automaticHandoffTasks[threadID] = nil
        card.phase = .sending
        card.lastError = nil
        handoffCards[threadID] = card
        return true
    }

    /// 카드의 [넘기기] — 사람이 확인했다 ("내용을 확인했습니다" 체크가 있어야 한다).
    @discardableResult
    func sendHandoff(threadID: String) async -> Bool {
        guard let card = handoffCards[threadID], card.confirmed else { return false }
        guard beginSend(threadID: threadID, draftID: card.id) else { return false }
        await deliverHandoff(threadID: threadID, cardID: card.id, humanReviewed: true)
        return true
    }

    /// 카운트다운의 [지금 넘기기] — 기다리지 않고 자동 인계로 보낸다 (기록 "자동 인계 · 사람 검토 없음", 단축키 없음).
    @discardableResult
    func sendHandoffNow(threadID: String) async -> Bool {
        guard let card = handoffCards[threadID], card.isCountingDown,
              beginSend(threadID: threadID, draftID: card.id) else { return false }
        await deliverHandoff(threadID: threadID, cardID: card.id, humanReviewed: false)
        return true
    }

    /// 점유한 카드를 보낸다. 지문 · 막힘을 다시 보고, 작성 줄 · 덧붙인 말을 넣고, 행을 넣고(넘길 때), 전달 실행을 시작한다.
    /// 시작하면 카드는 사라지고 `deliveringHandoffs` 가 이어받는다 (전달 상태는 `resolveDelivery`). 시작 전 실패는 그 카드에 `failed`.
    private func deliverHandoff(threadID: String, cardID: String, humanReviewed: Bool) async {
        func current() -> HandoffCard? {
            guard let card = handoffCards[threadID], card.id == cardID, card.isSending else { return nil }
            return card
        }
        func fail(_ reason: String) {
            guard var card = handoffCards[threadID], card.id == cardID else { return }
            card.phase = .failed(reason)
            card.lastError = reason
            if !humanReviewed { card.review = .deliveryFailed(reason) }
            handoffCards[threadID] = card
            if !humanReviewed {
                // 자동 전송이 실패하면 다시 시도하지 않고 사람에게 넘긴다 (실패 카드 — 같은 행을 다시 보낼 수 있다).
                notifications.post(category: .limitReached, title: "자동 인계를 보내지 못했습니다",
                                   body: "\(card.draft.threadTitle) · 대화 끝의 인계 카드에서 다시 넘길 수 있습니다.",
                                   threadID: threadID, opensHandoff: true)
            }
        }
        guard var card = current() else { return }
        // Antigravity: 목록이 없어 판정할 수 없으면 먼저 조회한다 (조회 중이면 기다리게 알린다 — 빈 목록으로 "못 읽음" 이라 하지 않게).
        if card.targetProvider == .gemini, let listed = paneThread(threadID), antigravityBlock(for: listed) == .catalogUnknown {
            let scope = listed.scope(for: .gemini)
            if refreshingModels.contains(scope) { return fail(HandoffSendBlock.antigravityRefreshing.message) }
            await refreshModelCatalog(scope)
            guard let latest = current() else { return }
            card = latest
        }
        guard let thread = (try? await store.thread(id: threadID)) ?? nil, let project = folderProject(for: thread) else {
            return fail("대화를 찾지 못했습니다")
        }
        // 초안 이후 폴더 · 파일 상태가 바뀌었으면 보내지 않는다 (사람이 다시 만든다).
        if let expected = card.fingerprint {
            let now = await handoffFingerprint(thread: thread, project: project)
            guard var latest = current() else { return }
            if now != expected {
                latest.phase = .ready
                latest.review = .stale(HandoffCardText.staleReason)
                handoffCards[threadID] = latest
                if !humanReviewed {
                    notifications.post(category: .limitReached, title: "자동 인계에 검토가 필요합니다",
                                       body: "\(thread.title) · " + HandoffCardText.staleReason,
                                       threadID: threadID, opensHandoff: true)
                }
                return
            }
            card = latest
        }
        // 막힘 — 카드가 보이는 것과 같은 판정. 보낸 것이 없으니 전송 실패가 아니다: 넘길 수 있는 카드로 되돌리고, 지금의 막힘은 카드
        // 바닥의 막힘 줄이 말한다 (풀리면 사라진다). 자동 전송이면 지난 일로 까닭을 남기고 사람에게 넘긴다 — 현재형 막힘 문장을 실패
        // 이유로 굳히면 막힘이 풀린 뒤에도 "…하는 중입니다" 가 남았다.
        if let block = HandoffSendBlock.first(handoffSendFacts(card: card, thread: thread, project: project)) {
            guard var latest = current() else { return }
            latest.phase = .ready
            latest.lastError = nil
            if !humanReviewed { latest.review = .automaticBlocked([block.automaticSkipReason]) }
            handoffCards[threadID] = latest
            if !humanReviewed {
                notifications.post(category: .limitReached, title: "자동 인계에 검토가 필요합니다",
                                   body: "\(thread.title) · " + block.automaticSkipReason, threadID: threadID, opensHandoff: true)
            }
            return
        }
        let review = humanReviewed ? "사람 검토함" : "자동 인계 · 사람 검토 없음"
        var handoff = card.draft.handoff
        // 작성 줄 다음에 덧붙인 말 — 앞머리(앱의 안내)는 늘 맨 앞에 남는다.
        let marked = HandoffPacketBuilder.markAuthorship(card.draft.editedText, packet: card.draft.packet, review: review)
        handoff.finalText = HandoffPacketBuilder.insertUserMemo(marked, memo: card.userMemo)
        handoff.note = review
        // Antigravity 의 고르지 않은 모델은 판정이 앱 기본 모델로 채운다 — 전달이 확인되면 대화에도 남긴다 (입력창 보내기와 같다).
        var filledModel: String?
        if handoff.toProvider == .gemini, thread.selection(for: .gemini).model == nil {
            filledModel = ModelCatalog.preferredOption(in: options(for: thread.scope(for: .gemini)))?.identifier
        }
        // 받는 Codex 계정은 엄격히 — 등록이 지워졌으면 기본 계정으로 떨어뜨리지 않는다 (막힘이 이미 봤다).
        var toAccount: CodexAccountRef?
        if handoff.toProvider == .codex {
            guard isRegisteredCodexAccount(handoff.toAccountID) else { return fail(HandoffSendBlock.receiverAccountMissing.message) }
            toAccount = CodexAccountRef(accounts.accountOrDefault(handoff.toAccountID))
            // 받는 계정의 모델 목록이 비었으면 먼저 읽는다 — 계열 선택(`gpt-*-sol`)은 받는 계정의 목록으로 풀고(`RunSession.send`),
            // 등록한 뒤 터미널에서 로그인한 계정은 앱을 다시 켜기 전까지 목록이 없다.
            let scope = AgentScope.codex(handoff.toAccountID)
            if modelCatalogs[scope]?.options.isEmpty ?? true {
                await refreshModelCatalog(scope)
                guard current() != nil else { return }
            }
        }
        // 받는 쪽의 모델 · 강도를 카드에 보이던 값(이어받기 → 기본 — `AppModel.effectiveSelection`)으로 정해 두고 그 값으로 보낸다.
        var receiving = thread
        if card.targetProvider != .gemini,
           let pinned = await pinEffectiveSelection(threadID: threadID, provider: card.targetProvider,
                                                    accountID: card.targetProvider == .codex ? handoff.toAccountID : nil) {
            receiving.setSelection(pinned.selection(for: card.targetProvider), for: card.targetProvider)
            guard current() != nil else { return }
        }
        // 받는 에이전트(제공자)가 바뀌면 자동 승인을 끈다 — 다른 회사 에이전트가 모든 승인을 받은 채 돌지 않게 (자동 인계면 사람도
        // 없다). 같은 제공자의 다른 계정은 그대로 둔다. 다시 켜는 것은 사람이 입력창의 승인 칩에서.
        if card.targetProvider != card.sourceProvider, isAutoApproving(threadID: threadID) {
            await setAutoApproval(false, threadID: threadID)
            let notice = ThreadEvent(threadID: threadID, kind: .systemNotice, provider: nil, title: "자동 승인을 껐습니다",
                                     text: "받는 에이전트가 바뀌었습니다 (\(card.sourceProvider.displayName) → "
                                        + "\(card.targetProvider.displayName)). 다시 켜려면 입력창 아래의 승인 방식에서 고르세요.")
            if let saved = try? await store.appendEvent(notice) { runCoordinator(runner, didUpsert: saved) }
            guard current() != nil else { return }
        }
        let starting = beginStarting(threadID: thread.id, projectPath: project.path)
        defer { endStarting(starting) }
        // 받는 에이전트의 실행도 시작 전에 작업 폴더를 찍어 둔다.
        let tracking = runner.unterminatedProcesses.isEmpty
            ? await beginRunChangeTracking(threadID: thread.id, project: project) : nil
        guard current() != nil else {
            discardRunChangeTracking(tracking)
            return
        }
        // 점유한 뒤 기다리는 사이 앱 종료가 시작됐으면 띄우지 않는다 (행도 넣지 않는다 — 넘기지 않은 초안은 남지 않는다).
        if handoffsSuspendedForQuit {
            discardRunChangeTracking(tracking)
            return fail(HandoffCardText.quitSuspendedReason)
        }
        // 행은 넘길 때 넣는다 (이미 있으면 그대로 — 다시 보내는 실패 행). 내용만 쓰고 전달 상태는 건드리지 않는다:
        // 보낼지는 `runner.deliver` 가 DB 의 상태로 점유해 정한다.
        try? await store.insertHandoffIfAbsent(handoff)
        _ = try? await store.updateHandoffDraftContent(handoff)
        // 행을 쓰는 사이에 시작됐을 수도 있다 — 여기서 `runner.deliver` 의 자리 잡기까지 await 가 없다.
        if handoffsSuspendedForQuit {
            discardRunChangeTracking(tracking)
            return fail(HandoffCardText.quitSuspendedReason)
        }
        // 전달 실행이 `runner.deliver` 가 돌아오기 전에 끝나도 판정할 수 있게 먼저 남긴다.
        deliveringHandoffs[threadID] = DeliveringHandoff(handoffID: handoff.id, source: card.draft.source, target: card.draft.target,
                                                         card: card, filledModel: filledModel, runID: nil)
        do {
            let run = try await runner.deliver(handoff: handoff, thread: receiving, project: project, toAccount: toAccount)
            if deliveringHandoffs[threadID]?.handoffID == handoff.id { deliveringHandoffs[threadID]?.runID = run.id }
            // 카드는 사라지고 스트림의 인계 줄이 이어받는다 (전달 상태가 정해지면 되살아날 수 있다).
            if current() != nil { handoffCards[threadID] = nil }
            if handoffCardFocusThreadID == threadID { handoffCardFocusThreadID = nil }
            threadStates[thread.id]?.handoffs = (try? await store.handoffs(threadID: thread.id)) ?? []
        } catch {
            discardRunChangeTracking(tracking)
            if deliveringHandoffs[threadID]?.handoffID == handoff.id { deliveringHandoffs[threadID] = nil }
            fail(error.localizedDescription)
            // 시작 실패도 행(전송 실패 · 받는 쪽)을 남긴다 — 칸의 인계 기록이 그것을 보이게 다시 읽는다.
            threadStates[thread.id]?.handoffs = (try? await store.handoffs(threadID: thread.id)) ?? []
        }
    }

    // MARK: - 전달 뒤

    /// 전달 실행이 끝났다 (`runCoordinator(_:didFinish:…)` — 대기열을 잇기 전에). 행을 다시 읽어 전달 상태로 가른다:
    /// 전달됨 → 칩(제공자 · 계정)을 받는 쪽으로, 보류를 풀어 대기열을 받는 쪽에게. 실패 → 같은 행을 다시 보낼 수 있는 카드.
    /// 미확인 → 보낼 수 없는 카드 (닫으면 보류가 멈춤으로).
    func resolveDelivery(run: Run) async {
        guard run.isHandoffDelivery, let delivering = deliveringHandoffs[run.threadID],
              delivering.runID == nil || delivering.runID == run.id else { return }
        let rows = (try? await store.handoffs(threadID: run.threadID)) ?? []
        guard deliveringHandoffs[run.threadID]?.handoffID == delivering.handoffID else { return }
        deliveringHandoffs[run.threadID] = nil
        threadStates[run.threadID]?.handoffs = rows
        let row = rows.first { $0.id == delivering.handoffID }
        switch row?.deliveryState {
        case .delivered? where delivering.target.provider == .codex
                && !isRegisteredCodexAccount(delivering.target.codexAccountID ?? CodexAccount.defaultID):
            // 전달하는 사이 받는 Codex 계정의 등록이 해제됐다. 칩을 지운 계정으로 옮기면 걸어 둔 메시지가 기본 계정의 (인계를 받지
            // 않은) 세션으로 맥락 없이 간다 — 칩은 그대로 두고 보류를 멈춤 이유로 푼다.
            let label = delivering.card.draft.packet.toAccountLabel ?? delivering.target.codexAccountID ?? ""
            releaseHold(threadID: run.threadID, .receiverRemoved(label))
        case .delivered?:
            if let thread = paneThread(run.threadID) {
                // 옛 복사본으로 행 전체를 덮지 않는다 (`send` 와 같은 이유) — 받는 에이전트와 옮긴 계정만 남긴다.
                await recordThreadSend(thread, provider: delivering.target.provider, onlyIfProviderWas: nil, placeholderTitle: nil,
                                       filledModel: delivering.filledModel,
                                       codexAccountID: delivering.target.provider == .codex ? delivering.target.codexAccountID : nil)
            }
            releaseHold(threadID: run.threadID, .delivered)
        case .failed?:
            var card = delivering.card
            let reason = Self.deliveryReason(row?.note) ?? "받는 쪽이 받지 못했습니다"
            card.phase = .failed(reason)
            card.review = .deliveryFailed(reason)
            card.lastError = reason
            handoffCards[run.threadID] = card
        default:
            var card = delivering.card
            card.phase = .unknown
            card.review = nil
            card.lastError = nil
            handoffCards[run.threadID] = card
        }
    }

    /// 앱 종료로 끊긴 전달 실행 (종료를 취소했다 — `reconcileCancelledQuit`). 전달됨이면 칩을 옮기되 대기열은 멈춘다
    /// (끊긴 실행 뒤에 걸어 둔 말을 그대로 보내지 않는다), 실패 · 미확인이면 카드를 되살린다.
    func resolveQuitDelivery(run: Run) async {
        guard run.isHandoffDelivery, deliveringHandoffs[run.threadID] != nil else { return }
        let delivered = ((try? await store.handoffs(threadID: run.threadID)) ?? [])
            .first { $0.id == deliveringHandoffs[run.threadID]?.handoffID }?.deliveryState == .delivered
        await resolveDelivery(run: run)
        if delivered, queueHolds[run.threadID] == nil, !(messageQueues[run.threadID]?.isEmpty ?? true) {
            // 칩은 인계를 받은 쪽으로 옮겼다 — 맥락을 가졌다.
            queuePauseReasons[run.threadID] = HandoffCardText.pauseReason(.quitDuringDelivery, chip: chipName(threadID: run.threadID),
                                                                          chipHasContext: true)
        }
    }

    /// 전달 판정이 남긴 메모에서 이번 판정의 문장 (검토 표시 · 이전 메모 뒤에 이어 붙는다).
    private static func deliveryReason(_ note: String?) -> String? {
        guard let note, !note.isEmpty else { return nil }
        return note.components(separatedBy: " · ").last { !$0.isEmpty && $0 != "사람 검토함" && $0 != "자동 인계 · 사람 검토 없음" }
    }

    // MARK: - 지우기 · 계정

    /// 지우는 대화의 인계 상태를 치운다: 카드 · 준비 토큰 · 전달 · 보류 · 걸어 둔 대기열(영속분까지) · 타이머.
    func forgetHandoff(threadID: String) {
        automaticHandoffTasks[threadID]?.cancel()
        automaticHandoffTasks[threadID] = nil
        cancelCodexSwitchCountdown(threadID: threadID)
        handoffCards[threadID] = nil
        handoffPreparations[threadID] = nil
        handoffTouchedDuringPreparation.remove(threadID)
        deliveringHandoffs[threadID] = nil
        handoffOutdated[threadID] = nil
        queueHolds[threadID] = nil
        messageQueues[threadID] = nil
        queuePauseReasons[threadID] = nil
        if handoffCardFocusThreadID == threadID { handoffCardFocusThreadID = nil }
    }

    /// 받는 Codex 계정의 등록이 해제됐다 — 그 계정을 받는 카드를 검토 카드로 (카운트다운은 멈춘다).
    func handoffReceiverRemoved(accountID: String, label: String) {
        for (threadID, card) in handoffCards where card.targetProvider == .codex && card.draft.handoff.toAccountID == accountID {
            guard !card.isSending else { continue }
            var updated = card
            if updated.isCountingDown {
                automaticHandoffTasks[threadID]?.cancel()
                automaticHandoffTasks[threadID] = nil
                updated.phase = .ready
            }
            updated.review = .accountRemoved(label)
            handoffCards[threadID] = updated
        }
    }

    // MARK: - Gemini 로 다시 정리

    /// [Gemini 로 다시 정리] 를 쓸 수 없는 까닭 — 설정에서 다듬기를 고르지 않았으면 nil (단추를 숨기기만 한다), 그 밖에는
    /// 카드에 한 줄로 보일 까닭 (agy 없음 · 프로젝트에서 끔). 쓸 수 있으면 nil.
    func geminiUnavailableNote(projectID: String) -> String? {
        guard geminiSummaryEnabled else { return nil }
        if geminiExcludedProjectIDs.contains(projectID) { return HandoffCardText.geminiProjectExcluded }
        if geminiCLIPath == nil { return HandoffCardText.geminiNoCLI }
        return nil
    }

    /// [Gemini 로 다시 정리] 를 보일까 — 다듬기를 골랐고 이 프로젝트에서 보낼 수 있고 agy 가 있다.
    func geminiResummaryAvailable(projectID: String) -> Bool {
        geminiAllowed(projectID: projectID) && geminiCLIPath != nil
    }

    /// 지금 카드의 초안을 Gemini 로 다시 정리하고 근거를 검증한다. 정리하는 동안은 보내기를 막고(`summarizing`), 끝나면
    /// **지금의 카드 값에** 패킷 · 문서 · 경고만 합친다 (덧붙인 말은 둔다). 카드가 사라졌거나 보내는 중이면 버린다.
    /// 정리하지 못하면 문서를 바꾸지 않는다 (사람이 고친 문서를 앱이 정리한 문서로 덮지 않는다 — 까닭은 카드의 오류 줄). 정리본으로
    /// 바뀌면 "내용을 확인했습니다" 를 푼다 — 사람이 확인한 것은 이 문서가 아니다 (hnd-5).
    func requestSummaryAssist(threadID: String) async {
        guard let card = handoffCards[threadID], !card.isSending, !card.summarizing,
              let thread = paneThread(threadID), let project = folderProject(for: thread) else { return }
        guard geminiAllowed(projectID: project.id) else {
            var blocked = card
            blocked.lastError = geminiSummaryEnabled
                ? "이 프로젝트는 Gemini 전송을 껐습니다. 프로젝트 설정(사이드바의 프로젝트 메뉴)에서 켤 수 있습니다."
                : "인계 문서를 Gemini 로 다듬지 않게 돼 있습니다. 설정 > 인계에서 ‘Gemini 로 다듬기’를 고르면 쓸 수 있습니다."
            handoffCards[threadID] = blocked
            return
        }
        pauseCountdown(threadID: threadID)
        guard var marked = handoffCards[threadID] else { return }
        marked.summarizing = true
        marked.lastError = nil
        handoffCards[threadID] = marked
        let draft = marked.draft
        // 보고 있는 대화가 아닐 수 있다 (자동 인계). 저장소에서 읽는다.
        let runs = (try? await store.runs(threadID: thread.id)) ?? []
        let handoffs = (try? await store.handoffs(threadID: thread.id)) ?? []
        let scope = await handoffScope(runs: runs, handoffs: handoffs, thread: thread)
        let env = await environment.childEnvironment()
        // 정리본은 지금의 git 상태로 다시 쓴다 — 지문도 지금 것으로 (git 을 읽기 전에 재야 그 사이의 변경이 낡음으로 잡힌다).
        let fingerprint = await handoffFingerprint(thread: thread, project: project, runs: runs)
        let git = await GitInspector.snapshot(at: project.url, environment: env, baseHead: scope.previousPacket?.changedFiles.head,
                                              since: scope.since)
        var rule = HandoffPacketBuilder.build(.init(
            thread: thread, project: project, fromProvider: draft.handoff.fromProvider, toProvider: draft.handoff.toProvider,
            fromAccountLabel: draft.packet.fromAccountLabel, toAccountLabel: draft.packet.toAccountLabel,
            events: scope.events, runs: scope.runs, lastConfirmedPacket: scope.previousPacket, git: git,
            baseSeq: draft.handoff.baseSeq, handoffs: handoffs))
        rule.summarySource = "rule"
        let outcome = await applyGeminiSummary(to: rule, thread: thread, project: project, events: scope.events, runs: scope.runs,
                                               previousPacket: scope.previousPacket, git: git, force: true)
        // 정리하는 사이 카드를 닫았거나(취소) 다른 초안으로 바뀌었거나 보내는 중이면 덮지 않는다.
        guard var latest = handoffCards[threadID], latest.id == draft.id, !latest.isSending else { return }
        latest.summarizing = false
        guard outcome.packet.summarySource == "gemini" else {
            // 정리하지 못했다 — 지금 문서를 그대로 둔다.
            latest.lastError = HandoffCardText.geminiFailed(outcome.warnings.first ?? "원인 미확인")
            handoffCards[threadID] = latest
            return
        }
        let text = HandoffPacketBuilder.render(outcome.packet, threadTitle: thread.title, projectPath: project.path,
                                               inWorktree: project.path != mainProject(for: thread)?.path)
        if latest.draft.editedText != text { latest.confirmed = false }
        // 문서가 지금의 git 상태로 바뀌었으니 지문도 지금 것으로. 지문이 없던 카드(되살린 실패 행)는 그대로 둔다.
        if latest.fingerprint != nil { latest.fingerprint = fingerprint }
        latest.draft.packet = outcome.packet
        latest.draft.validationWarnings = outcome.warnings
        latest.draft.geminiFailure = nil
        latest.draft.geminiRequested = true
        latest.draft.editedText = text
        latest.draft.renderedText = text
        latest.draft.handoff.draftJSON = (try? JSONEncoder().encode(outcome.packet)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        latest.draft.handoff.finalText = text
        handoffCards[threadID] = latest
        // 이미 넣은 행(다시 보내는 실패 행)이면 내용도 맞춘다 — 초안 · 실패 행에만 쓰인다.
        _ = try? await store.updateHandoffDraftContent(latest.draft.handoff)
    }

    struct GeminiPacketOutcome {
        var packet: HandoffPacket
        var warnings: [String]
    }

    func applyGeminiSummary(to rulePacket: HandoffPacket, thread: ConversationThread,
                            project: Project, events: [ThreadEvent], runs: [Run],
                            previousPacket: HandoffPacket?, git: GitSnapshot,
                            force: Bool) async -> GeminiPacketOutcome {
        if geminiModels.isEmpty { await refreshGeminiStatus(force: true) }
        let prompt = GeminiAssistInputBuilder.build(
            thread: thread, project: project, events: events, runs: runs,
            previousPacket: previousPacket, rulePacket: rulePacket, git: git)
        let hash = GeminiAssistInputBuilder.hash(prompt + "\n# model\n" + geminiModel)
        let decoder = JSONDecoder()

        if !force, let cached = try? await store.cachedAssist(
            kind: "handoff-summary", threadID: thread.id, inputHash: hash),
           let data = cached.outputJSON.data(using: .utf8),
           let summary = try? decoder.decode(GeminiAssistSummary.self, from: data) {
            let validated = GeminiAssistValidator.validate(summary, events: events)
            return GeminiPacketOutcome(
                packet: GeminiAssistValidator.merge(validated, into: rulePacket, model: cached.model),
                warnings: validated.warnings)
        }

        do {
            let response = try await geminiAssist.summarize(
                prompt: prompt, model: geminiModel.isEmpty ? nil : geminiModel,
                pathOverride: geminiPathOverride.isEmpty ? nil : geminiPathOverride)
            let validated = GeminiAssistValidator.validate(response.summary, events: events)
            let output = (try? JSONEncoder().encode(response.summary))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let usage = (try? JSONEncoder().encode(response.usage))
                .flatMap { String(data: $0, encoding: .utf8) }
            try? await store.upsertAssist(AssistRecord(
                threadID: thread.id, inputHash: hash, model: response.model,
                outputJSON: output, usageJSON: usage, status: "success",
                message: validated.warnings.isEmpty ? nil : validated.warnings.joined(separator: "\n")))
            return GeminiPacketOutcome(
                packet: GeminiAssistValidator.merge(validated, into: rulePacket, model: response.model),
                warnings: validated.warnings)
        } catch {
            let message = error.localizedDescription
            try? await store.upsertAssist(AssistRecord(
                threadID: thread.id, inputHash: hash,
                model: geminiModel.isEmpty ? nil : geminiModel,
                outputJSON: "", status: "failed", message: message))
            var fallback = rulePacket
            fallback.assistWarnings = [message]
            return GeminiPacketOutcome(packet: fallback, warnings: [message])
        }
    }

    // MARK: - 받는 쪽 표시

    /// 받는 쪽 모델 · 강도 ("GPT-5.6 Sol · High") — 받는 쪽 scope 의 목록으로 푼다 (입력창 모델 칩과 같은 값).
    func handoffReceiverModelText(threadID: String) -> String? {
        guard let card = handoffCards[threadID], let thread = paneThread(threadID) else { return nil }
        return receiverModelText(provider: card.targetProvider, accountID: card.draft.handoff.toAccountID, thread: thread)
    }

    /// 이 대화가 그 에이전트를 아직 쓰지 않았으면 이어받기 → 기본 모델 · 강도 (입력창과 같은 `AppModel.selectionText` — G3).
    func receiverModelText(provider: AgentProvider, accountID: String, thread: ConversationThread) -> String? {
        selectionText(for: thread, provider: provider, accountID: provider == .codex ? accountID : nil)
    }

    /// 카드 · 입력창이 부르는 에이전트 이름. Codex 계정은 둘 이상 등록했을 때만 붙인다 ("Codex · 둘째").
    func handoffPartyName(_ agent: HandoffSource.Agent, label: String? = nil) -> String {
        guard agent.provider == .codex, accounts.hasMultiple else { return agent.provider.displayName }
        return HandoffPacket.partyName(.codex, label ?? accounts.account(agent.codexAccountID ?? "")?.label)
    }

    /// 대화의 지금 칩 이름 — 보류를 풀 때 "맥락 없이 받을 쪽" 으로 적는다.
    func chipName(threadID: String) -> String {
        guard let thread = paneThread(threadID) else { return "지금 에이전트" }
        let label = thread.preferredProvider == .codex && accounts.hasMultiple ? codexAccount(for: thread).label : nil
        return HandoffPacket.partyName(thread.preferredProvider, label)
    }

    // MARK: - 화면 확인 · 시험

    #if DEBUG
    /// 자동 인계 시험용 (Debug 빌드 전용). 실제 한도에 닿지 않고 "한도 도달로 끝난 실행"을 흉내 낸다.
    /// CLI 출력 → 한도 도달 판정은 fixture 로 검증돼 있고, 이것은 그 뒤의 흐름
    /// (초안 → Gemini 정리 → 게이트 → 카운트다운 → 전송)을 실제 CLI 로 돌려 보기 위한 입구다.
    /// 흉내라는 사실은 대화 기록에 그대로 남긴다 (실행 행도 — 인계는 기록이 있는 대화만 한다).
    func simulateLimitReached(threadID: String? = nil) async {
        guard let id = threadID ?? selectedThreadID,
              let thread = (try? await store.thread(id: id)) ?? nil else {
            banner = BannerMessage(text: "대화를 먼저 선택하세요.", isError: true)
            return
        }
        guard !runner.isBusy(threadID: thread.id) else {
            banner = BannerMessage(text: "실행 중에는 한도 도달을 흉내 낼 수 없습니다.", isError: true, threadID: thread.id)
            return
        }
        let provider = thread.preferredProvider
        let message = "디버그: \(provider.displayName) 사용 한도 도달을 흉내 냈습니다. 실제 한도와 무관합니다."
        let run = Run(threadID: thread.id, sessionID: "", provider: provider,
                      requestText: "(한도 도달 흉내)", state: .rateLimited, endedAt: Date(),
                      terminalReason: "simulated_rate_limit", errorMessage: message,
                      codexAccountID: provider == .codex ? thread.codexAccountID : nil)
        try? await store.insertRun(run)
        let notice = ThreadEvent(threadID: thread.id, runID: run.id, kind: .systemNotice, provider: provider,
                                 title: "한도 도달 흉내 (디버그)", text: message)
        if let saved = try? await store.appendEvent(notice) {
            runCoordinator(runner, didUpsert: saved)
        }
        runCoordinator(runner, didFinish: run,
                       result: AgentTurnResult(state: .rateLimited, terminalReason: "simulated_rate_limit",
                                               isError: true, errorMessage: message,
                                               limitStatus: .subscriptionCap),
                       usage: nil)
    }

    /// 화면 확인용 (`-preview.action handoff…`, `AHC_OFFLINE=1`): 선택된 대화에 그 모양의 카드를 놓는다. 게이트 · 타이머 ·
    /// 전송은 하지 않는다 (CLI 를 부르지 않는다). `kind`: handoff(수동) · handoffCountdown · handoffReview · handoffFailed · handoffUnknown.
    func previewHandoffCard(kind: String, target: AgentProvider, queued: [String] = []) async {
        guard Self.offlinePreview, let thread = selectedThread else { return }
        let manual = kind == "handoff"
        // 초기화 시각은 실제 길(`startAutomaticHandoff`)처럼 한도 스냅샷에서 — 한도 줄과 같은 값 (미리보기는 대개 "미확인").
        let scope = thread.scope(for: thread.preferredProvider)
        let resetsAt = limits.snapshot(scope).capResetsAt()
        let origin: HandoffCard.Origin = manual ? .manual : .limitReached(scope: scope, resetsAt: resetsAt)
        guard await prepareCard(threadID: thread.id, target: target, toAccountID: nil, origin: origin, automatic: false),
              var card = handoffCards[thread.id] else { return }
        card.automatic = !manual
        card.receiver.authenticated = true
        card.receiver.authCheckedAt = Date().addingTimeInterval(-180)
        let failure = "대상 세션을 시작하지 못했습니다: Codex CLI 를 실행할 수 없습니다."
        switch kind {
        case "handoffCountdown":
            // 설정의 가장 긴 대기(30초) — 찍는 사이 0 이 되지 않게. 타이머는 걸지 않는다 (보내지 않는다).
            card.phase = .countingDown(deadline: Date().addingTimeInterval(30), delay: 30)
        case "handoffReview":
            // 실제 흐름과 같게 — 받는 쪽이 된 후보(Codex)는 "제외" 로 적지 않고 게이트의 이유만 (`startAutomaticHandoff`).
            card.review = .automaticBlocked([AutomaticHandoffGate.reasonLimitUnknown, AutomaticHandoffGate.reasonLogin])
            // 막힌 이유와 받는 쪽 줄의 사실이 같은 말을 하게 (로그인을 확인하지 못했다).
            card.receiver.authenticated = nil
            card.receiver.authCheckedAt = nil
        case "handoffFailed":
            card.phase = .failed(failure)
            card.review = .deliveryFailed(failure)
            card.lastError = failure
        case "handoffUnknown":
            card.phase = .unknown
        default:
            card.confirmed = true
        }
        if let memo = UserDefaults.standard.string(forKey: "preview.handoffMemo") { card.userMemo = memo }
        handoffCards[thread.id] = card
        // 보류된 대기열 (걸기만 한다 — 보내지 않는다).
        if !queued.isEmpty { messageQueues[thread.id, default: []] += queued.map { QueuedMessage(text: $0, images: []) } }
    }
    #endif
}
