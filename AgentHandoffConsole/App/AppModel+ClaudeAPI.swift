import Foundation

/// Claude 를 API 키로 실행하기 (Max · Team 플랜의 월 API 크레딧) — 앱 쪽. 키 · 환경 · 오류 글의 판정은 `Agents/ClaudeAPIKey.swift`.
///
/// 대화마다 모델 칩 팝오버의 "API 크레딧으로 실행" 으로 켜고(`claudeAPIThreadIDs` — 설정 `claude_api_threads`), 키는 설정 > 에이전트 >
/// Claude Code 에서 넣는다(키체인, 화면에는 `claudeAPIKeyHint`). 실행은 시작할 때 `RunCoordinator.claudeAPIThreadIDs` 를 보고 그
/// 실행의 자식 환경에만 키를 넣는다 (`RunSession.makeAdapter`). 끈 대화 · 키가 없을 때는 지금까지처럼 구독 로그인으로 보낸다.
extension AppModel {
    /// 이 대화의 Claude 를 API 키로 보낸다 — 켜 두었고 키가 저장돼 있을 때.
    func usesClaudeAPI(threadID: String) -> Bool {
        claudeAPIKeyHint != nil && claudeAPIThreadIDs.contains(threadID)
    }

    func setClaudeAPI(_ on: Bool, threadID: String) {
        if on { claudeAPIThreadIDs.insert(threadID) } else { claudeAPIThreadIDs.remove(threadID) }
    }

    /// 키를 키체인에 넣는다. 넣지 못한 까닭 (넣었으면 nil).
    func saveClaudeAPIKey(_ raw: String) -> String? {
        if let problem = ClaudeAPIKey.problem(in: raw) { return problem }
        guard ClaudeAPIKey.save(raw) else { return "키체인에 저장하지 못했습니다. 다시 시도하세요." }
        claudeAPIKeyHint = ClaudeAPIKey.masked(raw)
        return nil
    }

    /// 키를 키체인에서 지운다. 켜 둔 대화의 표시는 남지만 키를 다시 넣을 때까지 구독으로 보낸다.
    func deleteClaudeAPIKey() {
        ClaudeAPIKey.delete()
        claudeAPIKeyHint = nil
    }

    /// 실행이 볼 대화 — 키가 없으면 비운다 (켜 둔 표시는 남는다).
    func syncClaudeAPIRunner() {
        runner.claudeAPIThreadIDs = claudeAPIKeyHint == nil ? [] : claudeAPIThreadIDs
    }

    /// API 키로 보낼 때의 준비 상태 — 로그인을 보지 않는다 (로그인 안 됨 · 모름 → 준비됨). 설치 · 실행 파일 · 확인 중은 그대로.
    nonisolated static func readinessWithAPIKey(_ base: AgentReadiness) -> AgentReadiness {
        switch base {
        case .notLoggedIn, .loginUnknown: return .ready
        default: return base
        }
    }

    // MARK: - API 크레딧으로 계속 (구독 한도에 닿은 대화를 같은 세션으로)

    /// 이 대화에 [API 크레딧으로 계속] 을 보일까 (`ClaudeAPIContinue.offer`) — 한도 줄 · 인계 카드 · 제안 줄이 같은 판정을 쓴다.
    /// `provider` 는 한도에 닿은(닿아 가는) 쪽. 자동 작업이 가진 대화(내부 대화 · 끝나지 않은 자동 작업의 부모)는 보이지 않는다.
    func claudeAPIContinueOffer(threadID: String, provider: AgentProvider) -> ClaudeAPIContinue.Offer {
        let allowed = paneThread(threadID).map { handoffOwnershipBlock($0) == nil } ?? false
        return ClaudeAPIContinue.offer(provider: provider, threadUsesAPI: usesClaudeAPI(threadID: threadID),
                                       hasKey: claudeAPIKeyHint != nil, allowed: allowed)
    }

    /// [API 크레딧으로 계속] (한도 줄 · 인계 카드): 인계 카드(자동 카운트다운 · 준비 중 포함)가 있으면 거두고, 이 대화의 "API 크레딧으로
    /// 실행" 을 켜고, 같은 Claude 세션에 이어 가기 메시지를 보낸다 — 인계가 아니다 (세션 재개는 `RunSession.send` 의 대화 × Claude 칸).
    /// 한도로 멈춘 대기열은 이 실행이 정상으로 끝나면 이어서 간다 (`ClaudeAPIContinue.clearsQueuePause`). 실행이 시작되면 true.
    @discardableResult
    func continueWithClaudeAPI(threadID: String) async -> Bool {
        guard claudeAPIContinueOffer(threadID: threadID, provider: .claude) == .available,
              !runner.isBusy(threadID: threadID), !isStartingRun(threadID: threadID), !isSending(threadID: threadID),
              deliveringHandoffs[threadID] == nil else { return false }
        let pause = queuePauseReasons[threadID]
        if hasHandoffActivity(threadID: threadID) {
            // 보내는 중인 카드는 거두지 못한다 (`cancelHandoff` 가 거절하고 카드에 까닭을 적는다).
            guard cancelHandoff(threadID: threadID, origin: .card) else { return false }
        }
        setClaudeAPI(true, threadID: threadID)
        if ClaudeAPIContinue.clearsQueuePause(before: pause) { queuePauseReasons[threadID] = nil }
        threadStates[threadID]?.requestScrollToBottom()
        return await send(ClaudeAPIContinue.prompt, provider: .claude, threadID: threadID)
    }

    /// [API 크레딧으로 계속] (한도 임박 제안 줄): 대화가 멈추지 않았으므로 켜기만 하고 입력창 위에 알린다 — 다음 메시지부터 API 크레딧.
    func switchToClaudeAPI(threadID: String) {
        guard claudeAPIContinueOffer(threadID: threadID, provider: .claude) == .available else { return }
        setClaudeAPI(true, threadID: threadID)
        banner = BannerMessage(text: ClaudeAPIContinue.switchedNote, isError: false, threadID: threadID)
    }

    /// 오류 줄 아래의 할 일 — API 크레딧이 떨어짐 · 키가 맞지 않음 (`ClaudeAPIKey.errorNote`). Claude 의 오류만.
    func claudeAPIErrorNote(for event: ThreadEvent) -> String? {
        var provider: AgentProvider? = event.provider
        if provider == nil, let runID = event.runID { provider = threadStates[event.threadID]?.runsByID[runID]?.provider }
        guard provider == .claude else { return nil }
        return ClaudeAPIKey.errorNote(for: event.text)
    }

    #if DEBUG
    /// 화면 확인용 (`-preview.claudeAPIKey YES`, AHC_OFFLINE=1 전용): 키가 저장된 것처럼 — 키는 메모리 저장소에만 두고 키체인을 건드리지 않는다.
    func previewClaudeAPIKey() {
        guard Self.offlinePreview else { return }
        ClaudeAPIKey.storage = ClaudeAPIKeyMemoryStorage("sk-ant-api03-preview0000")
        claudeAPIKeyHint = ClaudeAPIKey.masked("sk-ant-api03-preview0000")
    }
    #endif
}
