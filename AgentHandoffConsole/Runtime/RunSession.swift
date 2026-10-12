import Foundation

/// 에이전트 실행 하나: 수명주기(상태 전이) · 이벤트 저장과 스트리밍 · 승인/질문 왕복 · 중단 · 사용량 기록 · 인계 전달 판정.
/// 한 번 쓰고 버린다 — `RunCoordinator` 가 턴마다 하나 만들어 시작하고, 끝나면 목록에서 뺀다.
/// 여러 실행을 묶는 일(스레드당 하나 · 동시 실행 상한 · 실행 ID 로 승인 찾기 · 대리자)은 `RunCoordinator` 에 있다.
@MainActor
@Observable
final class RunSession {
    typealias StartError = RunCoordinator.StartError

    /// 세션이 알리는 곳. `RunCoordinator` 가 받아 자기 대리자에게 넘긴다 (호출 모양은 `RunCoordinatorDelegate` 와 같다).
    @MainActor
    final class Relay {
        /// 약하게 잡는다 — 관리자가 실행보다 먼저 사라지면(시험 환경이 도는 실행을 두고 끝날 때) 통지를 버린다.
        /// `unowned` 였을 때 그 순간 "already destroyed" 로 시험 실행 파일이 죽었다 (2026-10-05). 앱의 관리자는 앱과 같이 산다.
        weak var owner: RunCoordinator?
        init(owner: RunCoordinator) { self.owner = owner }
        func runCoordinator(_ s: RunSession, didUpsert event: ThreadEvent) {
            guard let owner else { return }
            owner.delegate?.runCoordinator(owner, didUpsert: event)
        }
        func runCoordinator(_ s: RunSession, didChangeState state: RunState, run: Run?) {
            guard let owner else { return }
            owner.delegate?.runCoordinator(owner, didChangeState: state, run: run)
        }
        func runCoordinator(_ s: RunSession, didReceive limits: LimitSnapshot) {
            guard let owner else { return }
            owner.delegate?.runCoordinator(owner, didReceive: limits)
        }
        func runCoordinator(_ s: RunSession, didFinish run: Run, result: AgentTurnResult, usage: UsageRecord?) {
            guard let owner else { return }
            owner.sessionWillReport(s)
            owner.delegate?.runCoordinator(owner, didFinish: run, result: result, usage: usage)
        }
        /// 앱 종료로 끝냈다. 완료 통지는 보내지 않는다 (다음 일을 시작하지 않게) — 관리자는 끝난 상태와 종료 미확인 프로세스를
        /// 받아 두고, 대리자에게는 끝났다는 것만 알린다 (종료가 취소되면 대리자가 뒷정리한다).
        func runCoordinator(_ s: RunSession, didQuit run: Run) {
            guard let owner else { return }
            owner.sessionWillReport(s)
            owner.delegate?.runCoordinator(owner, didQuit: run)
        }
        func runCoordinator(_ s: RunSession, needsAttention title: String, body: String, threadID: String, kind: AttentionKind) {
            guard let owner else { return }
            owner.delegate?.runCoordinator(owner, needsAttention: title, body: body, threadID: threadID, kind: kind)
        }
    }

    struct ActiveContext {
        var run: Run
        var thread: ConversationThread
        var project: Project
        var adapter: AgentAdapter
        var session: AgentSession
        /// 이 실행이 쓰는 Codex 계정. Claude 실행은 nil.
        var account: CodexAccountRef?
        var handoffID: String?
        /// 이 실행에서 실제 응답/도구 활동을 관찰했는지 (인계 전달 판정에 쓴다).
        var sawAgentActivity = false
        /// 메인 턴이 한 번 완료로 끝났다 (`turnSettled` · `followUpTurnStarted`). 대상이 인계를 읽고 답까지 마쳤다 —
        /// 그 뒤의 후속 턴이 어떻게 끝나든 전달은 확인된 것이다 (인계 전달 판정).
        var mainTurnCompleted = false
        var pid: Int32?
        /// Codex: 이 실행의 세션 기록이 있는(새 세션이면 생길) 폴더 — 세션이 정해지면 `AgentSession.recordHome` 으로 남긴다.
        var codexRecordHome: String?
        /// Codex: 대화의 세션을 다른 계정의 인증으로 이어 가는 실행의 `CODEX_HOME` (`CodexRunHome`). 끝나면 지운다.
        var codexRunHome: CodexRunHome.Prepared?

        /// 화면과 기록에 쓰는 이름. Codex 는 계정까지 밝힌다.
        var partyName: String {
            HandoffPacket.partyName(run.provider, account?.label)
        }
    }

    private(set) var state: RunState = .idle
    private(set) var activeRun: Run?
    private(set) var activeThreadID: String?
    private(set) var activeProvider: AgentProvider?
    /// 지금 실행 중인 Codex 계정. Claude 실행이면 nil.
    private(set) var activeAccount: CodexAccountRef?
    /// 지금 실행에 넘긴 모델·추론 강도. 실행 뒤 스레드 선택을 바꿔도 이 값은 그대로다.
    private(set) var activeSelection: ModelSelection?
    /// 지금 실행이 Antigravity ULTRA 인지 (프롬프트 앞 `/boost`). 강도는 `activeSelection.effort` 에 따로 있다.
    private(set) var activeBoost = false
    private(set) var pendingApprovals: [ApprovalRequest] = []
    private(set) var pendingQuestions: [UserQuestion] = []
    /// 앱이 시작한 프로세스 중 종료가 확인되지 않은 것들.
    private(set) var unterminatedProcesses: [String] = []
    private(set) var lastErrorMessage: String?
    /// 이 실행이 이미 대화에 남긴 메인 실패 (`.failure` 이벤트) — 실행 끝의 오류 줄이 같은 것을 한 번 더 남기지 않게 (`finish`).
    /// Codex 는 한도에서 `error` 알림과 실패한 `turn/completed` 를 둘 다 보내 같은 한도가 두 줄이었다.
    private var recordedFailures: [(message: String, classification: LimitStatus)] = []

    /// 이 실행이 띄운 하위 에이전트 · 워크플로 · 백그라운드 작업 (시작 순). 진행(토큰 · 도구 수 · 마지막 도구)은
    /// 여기서만 본다 — 저장은 상태가 바뀔 때만 (`SubAgentInfo.differsForStorage`).
    private(set) var subAgents: [SubAgentInfo] = [] {
        didSet {
            // 진행만 바뀐 갱신(초당 여러 번)에는 바꾸지 않는다 — 이 수만 읽는 곳(잠금 안내 · 탭 배지)이 따라 그려지지 않게.
            // 하위가 앞에서 돌린 셸(`isInternalStep`)은 그 하위의 한 걸음이라 세지 않는다.
            let count = subAgents.filter { !$0.status.isFinished && !$0.isInternalStep }.count
            if count != unfinishedSubAgentCount { unfinishedSubAgentCount = count }
            let background = subAgents.filter { !$0.status.isFinished && $0.isBackground }.count
            if background != unfinishedBackgroundCount { unfinishedBackgroundCount = background }
        }
    }
    /// 이 실행이 띄운 하위 작업 중 아직 끝나지 않은 것의 수 ("하위 N개 기다리는 중" · "백그라운드 작업 N개").
    /// 상태가 바뀔 때만 바뀐다.
    private(set) var unfinishedSubAgentCount = 0
    /// 그중 백그라운드 작업(메인 턴이 끝나도 남는 것)의 수. 중단 원이 "백그라운드 작업까지" 라고 할지 정한다 —
    /// 메인 턴 중의 포그라운드 하위 에이전트는 백그라운드가 아니다.
    private(set) var unfinishedBackgroundCount = 0
    /// 메인 턴은 끝났고 남은 백그라운드 작업을 기다린다 (`turnSettled` → … → `finished`).
    /// 상태는 `.running` 그대로다 — 같은 대화 보내기 · git 쓰기 · 인계 잠금이 유지된다.
    private(set) var isWaitingOnBackground = false
    /// 기다리기 시작한 때 (경과 표시). 기다리지 않으면 nil.
    private(set) var waitingSince: Date?
    /// 하위 에이전트의 흐르는 글 (하위 id → 글). 메모리만 — 그 하위의 메시지가 끝나면 비운다.
    private(set) var subAgentLiveText: [String: String] = [:]
    /// CLI 가 정리한 "지금 하는 일" 한 줄 (Claude `task_summary`). 메모리만 — 메인 턴이 끝나면(기다림 · 후속 턴) 비운다.
    /// 실행 중 상태 줄이 "생각하는 중" 대신 보인다 (`RunActivity.read(summary:)`).
    private(set) var progressSummary: String?

    @ObservationIgnored var delegate: Relay?
    /// 실행이 끝나 정리까지 마쳤다 (`finish` · `shutdownForQuit` 의 맨 끝). 관리자가 목록에서 뺀다.
    @ObservationIgnored var onEnded: (() -> Void)?

    private let store: Store
    private let environment: CLIEnvironment
    private var context: ActiveContext?
    private var consumeTask: Task<Void, Never>?
    /// 실행을 끝내는 중이다 (`finish` · `shutdownForQuit` 의 첫 줄에서 켠다. 한 번 쓰는 세션이라 끄지 않는다).
    /// 그 뒤의 중단 · 하위 멈추기 · 상태 전이는 받지 않는다 — 이미 저장한 끝 상태(완료 · 취소)를 늦은 요청이 덮지 않게.
    @ObservationIgnored private var finishing = false
    /// 끝내는 중인 실행이 끝나기를 기다리는 곳 (앱 종료가 `finish` 도중에 왔을 때).
    @ObservationIgnored private var endWaiters: [CheckedContinuation<Void, Never>] = []
    /// 누가 이 실행을 멈추라고 했다 (`interrupt()` — ⌘. · 중단 단추 · 메뉴바 · 자동 작업의 멈춤). 앱은 이렇게 끝난 실행을 알리지 않는다
    /// (`AppModel.runCoordinator(_:needsAttention:…)`, nav-6).
    @ObservationIgnored private(set) var interruptRequested = false
    private var streamingEvent: ThreadEvent?
    private var streamingBuffer = ""
    /// 하위 작업마다 저장한 `.subAgent` 행 (하위 id → 행). 덮어쓸 때 처음 받은 순번 · 시각을 그대로 쓴다.
    @ObservationIgnored private var subAgentRows: [String: ThreadEvent] = [:]
    /// 하위가 끝나 앱이 닫은 승인 요청 ID. 어댑터가 뒤늦게 그 결정을 알려도 다시 적지 않는다.
    @ObservationIgnored private var droppedApprovalIDs: Set<String> = []
    /// 이 실행이 어댑터에 보낸 결정 (요청 ID → 결정). 어댑터가 알려 오는 결정(`approvalResolved`)은 글뿐이라,
    /// 결정 행의 구조화된 내용(`ApprovalDecisionInfo` — 결정 · 거절 사유)은 이것으로 적는다. 어댑터에 보내기 **전에** 넣는다 —
    /// 어댑터가 결정을 알리는 이벤트가 응답이 돌아오기 전에 처리될 수 있다.
    @ObservationIgnored private var respondedDecisions: [String: ApprovalDecision] = [:]
    /// 질문 행 (질문 ID → 저장한 행). 답하면 그 행에 답을 적는다.
    @ObservationIgnored private var questionRows: [String: ThreadEvent] = [:]
    /// 답을 보낸 질문 ID. 어댑터가 알려 오는 "응답 전송"(Codex) 은 승인 결정 행으로 적지 않는다 — 답은 질문 행에 있다.
    @ObservationIgnored private var answeredQuestionIDs: Set<String> = []
    @ObservationIgnored var priceEntries: [PriceEntry] = []

    /// 설정값.
    var claudePermissionMode = "manual"
    var codexSandboxMode = "workspace-write"
    var codexApprovalPolicy = "on-request"
    /// Claude · Codex 의 기본 추론 강도 — 설정 > 에이전트에서 사람이 고른 것만 (없으면 모델 기본값). 스레드가 강도를 고르지 않았으면(nil)
    /// `EffortScale.resolvedDefault` 의 차례로 푼다.
    var defaultEfforts: [AgentProvider: String] = [:]
    /// Antigravity 턴을 샌드박스로 실행할지. 켜면 셸 명령이 파일을 쓰지 못한다 (실측).
    var antigravitySandbox = true

    /// 사람이 지켜보지 않는 실행 (검토 레인 — `ReadOnlyRunPool`). 화면이 이 실행의 승인 · 질문을 보여 주지 않으므로
    /// 기다리지 않는다: 승인 요청은 거절하고, 질문이 오면 턴을 중단한다. 읽기 전용 턴만 받는다.
    var unattended = false
    /// 이 대화가 "자동 승인"인지 — 승인 요청이 올 때마다 묻는다 (실행 도중에 켜고 꺼도 다음 요청부터 맞는다).
    /// 켜져 있으면 카드를 띄우지 않고 곧바로 허용하고, 결정 행에 "자동 허용"으로 남긴다. 관리자가 넣는다.
    @ObservationIgnored var shouldAutoApprove: @MainActor () -> Bool = { false }
    /// CLI 가 알려 준 명령 · 스킬 (`AgentEvent.slashCommands`) — 이 실행의 에이전트 · 계정 · 폴더의 입력창 "/" 목록으로.
    @ObservationIgnored var onSlashCommands: @MainActor (SlashCommandKey, [SlashCommand]) -> Void = { _, _ in }
    /// 앱이 자동으로 허용하고 결정 행("자동 허용")까지 남긴 요청. 어댑터가 뒤늦게 결정을 알려 오면 행을 다시 적지 않는다.
    @ObservationIgnored private var autoApproved: Set<String> = []

    /// 어댑터를 만드는 곳. nil 이거나 nil 을 돌려주면 설치된 CLI 로 실제 어댑터를 만든다.
    /// 검증은 여기에 가짜 어댑터를 넣어 CLI · 네트워크 없이 실행 흐름(기록 · 상태 전이 · 승인 · 중단)을 돌린다.
    /// 어댑터를 돌려주면 CLI 설치 확인과 자식 환경 구성도 건너뛴다.
    var adapterFactory: ((AgentProvider) -> AgentAdapter?)?
    /// 이 대화는 Claude 를 API 키로 실행한다 (모델 칩의 "API 크레딧으로 실행" — `RunCoordinator.claudeAPIThreadIDs`). 켜져 있으면 Claude
    /// 실행의 자식 환경에 키체인의 키를 넣는다 (`ClaudeAPIKey.environment`) — Max · Team 의 월 API 크레딧에서 빠진다.
    var usesClaudeAPI = false

    init(store: Store, environment: CLIEnvironment) {
        self.store = store
        self.environment = environment
    }

    func loadPrices() async {
        priceEntries = (try? await store.priceEntries()) ?? []
    }

    var isBusy: Bool { state.isActive }
    /// 이 실행이 도는 프로젝트 폴더. 폴더 단위 잠금(git 쓰기 · 실행 전후 비교의 겹침)이 본다.
    var activeProjectPath: String? { context?.project.path }

    // MARK: - 상태 전이

    private func transition(to next: RunState, reason: String? = nil) {
        // 끝내는 중이면 받지 않는다 — 끝 상태는 `finish` · `shutdownForQuit` 가 정한다.
        guard !finishing else { return }
        guard state.canTransition(to: next) else {
            // 허용되지 않는 전이는 무시하되 기록으로 남긴다.
            lastErrorMessage = "상태 전이 거부: \(state.koreanName) → \(next.koreanName)"
            return
        }
        state = next
        // 이미 끝 상태로 저장한 실행 행은 덮지 않는다.
        if var run = context?.run, !run.state.isTerminal {
            run.state = next
            if let reason { run.terminalReason = reason }
            context?.run = run
            activeRun = run
            Task { try? await store.updateRun(run) }
        }
        delegate?.runCoordinator(self, didChangeState: next, run: context?.run)
    }

    // MARK: - 실행 시작

    /// Antigravity 턴에 넘길 모델 · 강도 · `/boost` — 스레드 선택 + 앱이 저장해 둔 `agy models` 목록.
    /// 막히면 아무것도 기록하지 않고 던진다 (입력창 · 인계가 모두 이 판정을 거친다).
    private func antigravityPlan(for thread: ConversationThread) async throws -> AntigravityAdapter.TurnPlan {
        let selection = thread.selection(for: .gemini)
        let options = (try? await store.modelOptions(scope: thread.scope(for: .gemini))) ?? []
        switch AntigravityAdapter.plan(model: selection.model, effort: selection.effort, options: options) {
        case .send(let plan): return plan
        case .blocked(let block): throw StartError.antigravityBlocked(block)
        }
    }

    /// 한 턴을 실행한다.
    ///
    /// `account` 는 Codex 실행이 쓸 계정(로그인 · 모델 목록 · 기본 강도)이다. 그 값은 **이 자식 프로세스에만** 들어간다.
    /// 세션은 계정이 아니라 대화마다 하나다 — 대화의 Codex 세션이 다른 계정의 폴더에 있으면 이 실행만의 `CODEX_HOME` 을 꾸려
    /// 그 세션을 이 계정의 인증으로 이어 간다 (`codexPlacement` → `CodexRunHome`). 앱은 홈의 기존 파일을 고쳐 쓰지 않는다
    /// (기록 폴더에 빠진 기록 항목의 빈 폴더 · 빈 파일만 만든다).
    @discardableResult
    func send(prompt: String, thread: ConversationThread, project: Project,
              provider: AgentProvider, account: CodexAccountRef? = nil,
              isHandoffDelivery: Bool = false,
              handoffID: String? = nil, recordUserEvent: Bool = true,
              antigravity planned: AntigravityAdapter.TurnPlan? = nil,
              turn: AgentTurnOptions = AgentTurnOptions()) async throws -> Run {
        guard !isBusy else { throw StartError.busy }
        if unattended && !turn.readOnly { throw StartError.unattendedNeedsReadOnly }
        // 부탁만 하고 돌리지 않는다. 막히는 턴은 흔적을 남기지 않는다.
        if turn.readOnly && !provider.supportsReadOnlyTurns { throw StartError.readOnlyUnsupported(provider) }
        // 실행 기록 · CLI 확인보다 먼저 — 막히는 턴은 흔적(실행 행 · 사용자 메시지)을 남기지 않는다.
        // 인계는 `deliver` 가 이미 정한 값을 넘긴다 (한 번만 판정 — 사이에 목록이 바뀌어도 "인계 전송" 뒤에 막히지 않게).
        var antigravity: AntigravityAdapter.TurnPlan?
        if provider == .gemini {
            if let planned { antigravity = planned } else { antigravity = try await antigravityPlan(for: thread) }
        }
        // Codex 계열 선택(`gpt-*-sol`)은 CLI 에 넘기지 않는다 — 계정의 지금 목록에서 그 계열의 최신 ID 로 푼다.
        var modelOptions: [AgentModelOption]?
        var resolvedModel = thread.selection(for: provider).model
        if provider != .gemini, let family = ModelCatalog.familyOfSelection(resolvedModel) {
            let options = (try? await store.modelOptions(scope: modelScope(thread: thread, provider: provider,
                                                                          account: account))) ?? []
            guard let id = ModelCatalog.latestModel(family: family, in: options)?.identifier else {
                throw StartError.modelUnresolved(resolvedModel ?? family)
            }
            resolvedModel = id
            modelOptions = options
        }

        let codexAccount = provider == .codex ? account : nil
        let runID = UUID().uuidString
        // Codex: 대화의 세션이 어느 폴더에 있고 이 실행을 어디서 띄울지 — 다른 계정의 폴더면 이 실행만의 CODEX_HOME.
        // 막히면(인증이 파일이 아닌 계정 등) 기록을 남기기 전에 던진다.
        let placement = try await codexPlacement(threadID: thread.id, account: codexAccount, runID: runID)
        let adapter: AgentAdapter
        let cliVersion: String?
        do {
            (adapter, cliVersion) = try await makeAdapter(provider: provider, codexHome: codexAccount?.homePath,
                                                          overrides: placement?.runHome?.environment ?? [:])
        } catch {
            placement?.runHome?.remove()
            throw error
        }

        var session: AgentSession
        do {
            session = try await store.ensureSession(threadID: thread.id, provider: provider)
        } catch {
            placement?.runHome?.remove()
            throw error
        }
        session.cliVersion = cliVersion

        var run = Run(id: runID, threadID: thread.id, sessionID: session.id, provider: provider,
                      requestText: prompt, state: .starting, isHandoffDelivery: isHandoffDelivery,
                      codexAccountID: codexAccount?.id)
        do {
            try await store.insertRun(run)
        } catch {
            placement?.runHome?.remove()
            throw error
        }

        if recordUserEvent {
            let event = ThreadEvent(threadID: thread.id, runID: run.id, kind: .userMessage,
                                    provider: nil, title: "사용자", text: prompt,
                                    payloadJSON: ThreadEvent.imagesPayload(turn.images))
            let saved = try await store.appendEvent(event)
            delegate?.runCoordinator(self, didUpsert: saved)
        }

        context = ActiveContext(run: run, thread: thread, project: project,
                                adapter: adapter, session: session, account: codexAccount,
                                handoffID: handoffID, codexRecordHome: placement?.recordHome,
                                codexRunHome: placement?.runHome)
        activeRun = run
        activeThreadID = thread.id
        activeProvider = provider
        activeAccount = codexAccount
        pendingApprovals = []
        pendingQuestions = []
        lastErrorMessage = nil
        state = .idle
        transition(to: .starting)

        // 스레드에 저장된 모델 선택을 사용한다. Antigravity 는 판정이 정한 값 (기본 모델 · High · /boost).
        // Claude · Codex 의 빈 강도는 기본 강도로 — 설정의 기본 강도(사람이 고른 것) → Codex 는 계정의 config.toml → 그 모델의 기본 강도 →
        // High, 그 모델이 받는 첫 값 (화면의 모델 칩과 같은 규칙 `EffortScale.displayEffort(… defaults:)`).
        var selection = antigravity.map { ModelSelection(model: $0.model, effort: $0.effort) }
            ?? ModelSelection(model: resolvedModel, effort: thread.selection(for: provider).effort)
        if provider != .gemini {
            let options: [AgentModelOption]
            if let modelOptions { options = modelOptions }
            else { options = (try? await store.modelOptions(scope: modelScope(thread: thread, provider: provider, account: account))) ?? [] }
            let availability = EffortScale.availability(provider: provider, selectedModel: selection.model, options: options)
            let config = provider == .codex
                ? CodexConfigDefaults.read(home: codexAccount?.homePath ?? CodexAccountInspector.defaultHomePath()).effort : nil
            selection.effort = EffortScale.displayEffort(provider: provider, selected: selection.effort, availability: availability,
                                                         defaults: EffortScale.Defaults(user: defaultEfforts[provider], config: config))
        }
        // 실행 머리는 agy 가 쓰는 강도를 보인다 (강도가 붙은 옛 슬러그는 `--effort` 없이 슬러그의 강도).
        activeSelection = antigravity.map { ModelSelection(model: $0.model, effort: $0.passedEffort) } ?? selection
        activeBoost = antigravity?.boost ?? false
        // Antigravity 는 이미지를 받지 않는다 — 붙인 파일의 경로를 적어 에이전트가 파일로 열게 한다 (기록의 사용자 글은 그대로).
        var sentPrompt = prompt
        // 앱이 에이전트에게만 알릴 말 (작업 폴더가 바뀌었다 등). 기록의 사용자 글에는 넣지 않는다.
        if let preamble = turn.preamble, !preamble.isEmpty {
            sentPrompt = preamble + (sentPrompt.isEmpty ? "" : "\n\n" + sentPrompt)
        }
        if provider == .gemini, !turn.images.isEmpty {
            sentPrompt += (prompt.isEmpty ? "" : "\n\n") + "[첨부 이미지 — 파일로 열어 보세요]\n"
                + turn.images.map(\.path).joined(separator: "\n")
        }
        // 세션 기록 폴더를 찾지 못해 새 세션으로 시작한다 — 말없이 바꾸지 않고 대화에 남긴다.
        if let notice = placement?.notice {
            await upsert(ThreadEvent(threadID: thread.id, runID: run.id, kind: .systemNotice,
                                     provider: .codex, title: "Codex 세션", text: notice))
        }
        let request = AgentTurnRequest(
            runID: run.id,
            prompt: sentPrompt,
            workingDirectory: project.url,
            resumeSessionID: session.resumable && placement?.resumes != false ? session.cliSessionID : nil,
            strictResume: placement?.runHome != nil,
            preferredNewSessionID: provider == .claude ? UUID().uuidString : nil,
            model: selection.model,
            effort: selection.effort,
            routeApprovalsToApp: provider.routesApprovalsToApp,
            boost: activeBoost,
            readOnly: turn.readOnly,
            outputSchema: turn.outputSchema,
            // 백그라운드 작업을 기다리는 것은 사람이 지켜보는 쓰기 턴만. 무인(검토 레인) · 읽기 전용 · 구조화 응답
            // 턴(자동 작업의 계획 · 검토)은 지금처럼 메인 턴 끝에서 끝낸다 — 후속 턴에는 구조화 응답이 없다.
            waitForBackground: !unattended && !turn.readOnly && turn.outputSchema == nil,
            images: provider == .gemini ? [] : turn.images,
            skills: provider == .codex ? turn.skills : [])

        let stream = adapter.start(request)
        consumeTask = Task { [weak self] in
            guard let self else { return }
            for await event in stream {
                await self.handle(event)
            }
        }

        run.state = .starting
        return run
    }

    /// Codex 실행을 어디서 띄울지 (`send` 가 정한다). 다른 제공자는 nil.
    struct CodexPlacement {
        /// 이 실행의 세션 기록이 있는(새 세션이면 생길) 폴더.
        var recordHome: String
        /// 대화의 세션을 다른 계정의 인증으로 이어 가는 실행의 `CODEX_HOME`. nil 이면 실행 계정의 홈을 그대로 쓴다.
        var runHome: CodexRunHome.Prepared?
        /// 대화의 세션을 재개한다. false 면 새 세션 (기록 폴더를 찾지 못했다 — `notice`).
        var resumes = true
        /// 대화에 남길 안내.
        var notice: String?
    }

    /// 대화의 Codex 세션(`AgentSession.recordHome`)과 실행 계정의 홈을 견줘 실행을 띄울 곳을 정한다:
    /// 재개할 세션이 없거나 · 기록 폴더를 모르거나(v10 전 · 목록에 없던 계정) · 실행 계정의 홈에 있으면 그 홈을 그대로 (지금까지와 같다).
    /// 다른 폴더에 있으면 이 실행만의 `CODEX_HOME` (`CodexRunHome.prepare` — 인증은 실행 계정, 기록은 그 폴더) — 재개하지 못하면
    /// 새 세션으로 넘어가지 않는다 (`AgentTurnRequest.strictResume`). 그 폴더가 사라졌으면 이어 갈 기록이 없으므로 실행 계정의 새 세션으로
    /// 시작하고 그 사실을 대화에 남긴다. 실행 폴더를 만들 수 없으면(인증이 파일이 아닌 계정 등) 기록을 남기기 전에 던진다.
    private func codexPlacement(threadID: String, account: CodexAccountRef?, runID: String) async throws -> CodexPlacement? {
        guard let account else { return nil }
        let accountHome = (account.homePath as NSString).expandingTildeInPath
        let existing = try await store.session(threadID: threadID, provider: .codex)
        let direct = CodexPlacement(recordHome: accountHome)
        guard let existing, existing.resumable, !(existing.cliSessionID ?? "").isEmpty,
              let recordHome = existing.recordHome, !CodexRunHome.sameHome(recordHome, accountHome) else { return direct }
        let record = (recordHome as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: record) else {
            return CodexPlacement(recordHome: accountHome, resumes: false,
                                  notice: "이 대화의 Codex 세션 기록 폴더(\(record))를 찾지 못해 \(account.label) 계정의 새 세션으로 "
                                      + "시작합니다 — 이 세션은 지금까지의 대화를 모릅니다.")
        }
        // 가짜 어댑터를 넣은 실행(검증 · 화면 확인)도 실행 폴더를 만든다 — 기록 폴더 · 계정 폴더가 실제로 있을 때 (시험이 그 구성을 본다).
        do {
            let prepared = try CodexRunHome.prepare(recordHome: record, accountHome: accountHome,
                                                    accountLabel: account.label, runID: runID)
            return CodexPlacement(recordHome: record, runHome: prepared)
        } catch let failure as CodexRunHome.Failure {
            throw StartError.cliUnavailable(failure.localizedDescription)
        }
    }

    /// 이번 턴의 어댑터와 CLI 버전. 주입된 어댑터가 있으면 그것을 쓰고, 없으면 설치된 CLI 를 확인해 만든다.
    /// 세션 · 실행 기록보다 먼저 부른다 — CLI 를 쓸 수 없는 턴은 흔적을 남기지 않는다. `overrides` 는 자식 환경에 덧씌울 값
    /// (Codex 실행 폴더의 `CODEX_HOME` · `CODEX_SQLITE_HOME`).
    private func makeAdapter(provider: AgentProvider, codexHome: String?,
                             overrides: [String: String] = [:]) async throws -> (AgentAdapter, String?) {
        if let injected = adapterFactory?(provider) { return (injected, nil) }

        let status = await environment.checkStatus(provider)
        guard let path = status.resolvedPath, status.executable else {
            throw StartError.cliUnavailable(
                status.error ?? "\(provider.displayName) CLI 를 실행할 수 없습니다.")
        }
        var env = await environment.childEnvironment(codexHome: codexHome)
        for (name, value) in overrides { env[name] = value }
        if provider == .claude, usesClaudeAPI {
            // 키를 읽지 못했으면 구독으로 몰래 보내지 않는다 — 사람이 고른 것은 API 크레딧이다.
            guard let key = ClaudeAPIKey.load() else { throw StartError.claudeAPIKeyMissing }
            env = ClaudeAPIKey.environment(env, apiKey: key)
        }
        switch provider {
        case .claude:
            return (ClaudeAdapter(executablePath: path, environment: env,
                                  permissionMode: claudePermissionMode), status.version)
        case .codex:
            return (CodexAdapter(executablePath: path, environment: env,
                                 sandboxMode: codexSandboxMode,
                                 approvalPolicy: codexApprovalPolicy), status.version)
        case .gemini:
            // 승인을 물을 방법이 없어 자동 승인으로만 동작한다. 호출자가 프로젝트별로 허용했는지
            // 먼저 확인한다 (AppModel.send). 여기서는 샌드박스 여부만 정책으로 받는다.
            return (AntigravityAdapter(executablePath: path, environment: env,
                                       cliVersion: status.version,
                                       sandbox: antigravitySandbox), status.version)
        }
    }

    // MARK: - 이벤트 처리

    private func handle(_ event: AgentEvent) async {
        // 앱 종료가 끝내는 중이면 남은 이벤트(끊기 전에 쌓인 것)는 받지 않는다. `finish` 도중에는 소비 작업이 여기 오지 않는다.
        guard var ctx = context, !finishing else { return }

        switch event {
        case .sessionEstablished(let sessionID, let model, let cliVersion):
            ctx.session.cliSessionID = sessionID
            ctx.session.resumable = true
            ctx.session.lastError = nil
            // Codex: 세션 기록이 있는 폴더 — 다음에 다른 계정으로 보내면 이 폴더의 세션을 그 계정의 인증으로 이어 간다.
            if let home = ctx.codexRecordHome { ctx.session.recordHome = home }
            if let cliVersion { ctx.session.cliVersion = cliVersion }
            ctx.run.model = model
            ctx.pid = ctx.adapter.currentPID
            context = ctx
            activeRun = ctx.run
            try? await store.upsertSession(ctx.session)
            if state == .starting { transition(to: .running) }

        case .assistantDelta(let text):
            ctx.sawAgentActivity = true
            context = ctx
            if state == .starting { transition(to: .running) }
            await appendStreamingText(text, provider: ctx.run.provider, runID: ctx.run.id,
                                      threadID: ctx.thread.id)

        case .assistantMessage(let text):
            ctx.sawAgentActivity = true
            context = ctx
            await finalizeStreaming(with: text, provider: ctx.run.provider, runID: ctx.run.id,
                                    threadID: ctx.thread.id)

        case .reasoning(let text):
            await upsert(ThreadEvent(threadID: ctx.thread.id, runID: ctx.run.id,
                                     kind: .agentReasoning, provider: ctx.run.provider,
                                     title: "추론 요약", text: text))

        case .toolStarted(let id, let name, let detail):
            ctx.sawAgentActivity = true
            context = ctx
            await upsert(ThreadEvent(threadID: ctx.thread.id, runID: ctx.run.id,
                                     kind: .toolRequest, provider: ctx.run.provider,
                                     title: name, text: detail, toolUseID: id))

        case .toolFinished(let id, let name, let output, let isError):
            let row = ThreadEvent(threadID: ctx.thread.id, runID: ctx.run.id,
                                  kind: .toolResult, provider: ctx.run.provider,
                                  title: isError ? "\(name) — 오류" : name,
                                  text: output, toolUseID: id)
            // 하위 작업의 앵커 행을 끝내는 결과(Codex: 하위 턴이 끝날 때)는 메인 글 도중에도 온다 — 메인 스트리밍을 닫지 않는다.
            if subAgents.contains(where: { $0.id == id }) { await save(row) } else { await upsert(row) }

        case .commandExecution(let id, let command, let cwd, let output, let exitCode, let status):
            ctx.sawAgentActivity = true
            context = ctx
            var payload: [String: Any] = ["status": status]
            if let exitCode { payload["exitCode"] = exitCode }
            if let cwd { payload["cwd"] = cwd }
            var text = command
            if let output, !output.isEmpty { text += "\n\n--- 출력 ---\n" + output }
            await upsert(ThreadEvent(
                threadID: ctx.thread.id, runID: ctx.run.id, kind: .commandExecution,
                provider: ctx.run.provider,
                title: JSONUtil.truncate(command, max: 160, marker: "…"),
                text: text, payloadJSON: JSONUtil.line(payload), toolUseID: id))

        case .fileChange(let id, let paths, let diff, let status):
            ctx.sawAgentActivity = true
            context = ctx
            var text = paths.joined(separator: "\n")
            if let diff, !diff.isEmpty { text += "\n\n" + diff }
            await upsert(ThreadEvent(
                threadID: ctx.thread.id, runID: ctx.run.id, kind: .fileChange,
                provider: ctx.run.provider,
                title: paths.joined(separator: ", "), text: text,
                payloadJSON: JSONUtil.line(["status": status]), toolUseID: id))

        case .approvalRequested(let request):
            // Codex 의 권한 요청 · MCP 입력 요청 · 에이전트의 질문은 자동 승인이어도 카드로 (`ApprovalRequest.allowsAutoApproval`).
            // Codex 의 명령 · 파일 변경은 샌드박스 밖으로 나가는 것이어도 허용한다 (칩 글 `ApprovalPolicyText.autoApproval`).
            let auto = !unattended && shouldAutoApprove() && request.allowsAutoApproval
            if !auto { pendingApprovals.append(request) }
            let row = ThreadEvent(
                threadID: ctx.thread.id, runID: ctx.run.id, kind: .approvalRequest,
                provider: ctx.run.provider,
                title: "\(request.kind.koreanName): \(request.title)",
                text: request.detail,
                payloadJSON: ThreadEvent.approvalRequestPayload(requestID: request.id, toolName: request.toolName,
                                                                approvalKind: request.kind.rawValue),
                toolUseID: request.toolUseID)
            // 하위가 청한 승인은 메인 글과 무관한 때에 온다 — 메인 스트리밍을 닫지 않는다.
            if request.agentID != nil { await save(row) } else { await upsert(row) }
            if unattended {
                let decision = ApprovalDecision.deny(ApprovalDecisionInfo.unattendedDenyMessage)
                respondedDecisions[request.id] = decision
                await ctx.adapter.respond(approvalID: request.id, decision: decision)
                return
            }
            // 자동 승인: 카드 · 알림 없이 곧바로 허용하고 결정 행을 남긴다.
            if auto {
                await approveAutomatically(request, ctx: ctx)
                return
            }
            transition(to: .awaitingApproval)
            delegate?.runCoordinator(self, needsAttention: "승인이 필요합니다",
                                     body: request.title, threadID: ctx.thread.id,
                                     kind: .approvalNeeded)

        case .approvalResolved(let id, let decision):
            // 하위가 끝나 이미 닫은 요청 (`dropPending`). 결정 행을 두 번 남기지 않는다.
            if droppedApprovalIDs.remove(id) != nil { return }
            // 질문의 답을 보냈다는 알림 (Codex "응답 전송") — 답은 질문 행에 적었다 (`respond(question:answers:)`).
            if answeredQuestionIDs.remove(id) != nil { return }
            let recorded = autoApproved.remove(id) != nil
            let request = pendingApprovals.first { $0.id == id }
            let childOwned = request?.agentID != nil
            pendingApprovals.removeAll { $0.id == id }
            if pendingApprovals.isEmpty && pendingQuestions.isEmpty && state == .awaitingApproval {
                transition(to: .running)
            }
            let responded = respondedDecisions.removeValue(forKey: id)
            // 자동 허용은 허용하던 때 결정 행을 남겼다.
            guard !recorded else { return }
            // 이 실행이 보낸 결정이면 그 결정 그대로(질문에 적은 답은 거절이 아니라 답), 어댑터가 스스로 닫은 것(CLI 가 거둠 ·
            // 작업 멈춤)이면 글로 짐작한다.
            let row = decisionRow(requestID: id, request: request,
                                  decision: responded?.recorded ?? ApprovalDecisionInfo.Decision.legacy(decision) ?? .cancelled,
                                  reason: responded?.reason, answer: responded?.answer,
                                  text: responded?.koreanName ?? decision, ctx: ctx)
            if childOwned { await save(row) } else { await upsert(row) }

        case .questionAsked(let question):
            pendingQuestions.append(question)
            let body = question.promptText
            let row = ThreadEvent(
                threadID: ctx.thread.id, runID: ctx.run.id, kind: .userQuestion,
                provider: ctx.run.provider, title: "사용자 질문", text: body)
            // 하위 에이전트의 질문은 메인이 쓰는 중인 글을 닫지 않는다 (승인 요청과 같은 규칙).
            let saved: ThreadEvent?
            if question.agentID != nil { saved = await save(row) } else { saved = await upsert(row) }
            if let saved { questionRows[question.id] = saved }
            if unattended {
                pendingQuestions.removeAll { $0.id == question.id }
                await interrupt()
                return
            }
            transition(to: .awaitingApproval)
            delegate?.runCoordinator(self, needsAttention: "에이전트가 질문했습니다",
                                     body: body, threadID: ctx.thread.id,
                                     kind: .approvalNeeded)

        case .rateLimits(let snapshot):
            // 실행 중 온 한도 정보는 지금 쓰는 계정의 것이다. 다른 계정에 붙지 않게 표시해 둔다.
            var tagged = snapshot
            if snapshot.provider == .codex { tagged.accountID = ctx.account?.id ?? "" }
            delegate?.runCoordinator(self, didReceive: tagged)

        case .notice(let text):
            await upsert(ThreadEvent(threadID: ctx.thread.id, runID: ctx.run.id,
                                     kind: .systemNotice, provider: ctx.run.provider,
                                     title: "안내", text: text))

        case .diagnostic(let text):
            // 대화에 보이지 않는 행이다 — 흐르는 메인 글을 닫지 않는다 (stderr 한 줄이 응답을 둘로 가르지 않게).
            await save(ThreadEvent(threadID: ctx.thread.id, runID: ctx.run.id,
                                   kind: .systemNotice, provider: ctx.run.provider,
                                   title: ThreadEvent.diagnosticTitle, text: text,
                                   payloadJSON: ThreadEvent.noticePayload(ThreadEvent.diagnosticKey)))

        case .attention(let text):
            await upsert(ThreadEvent(threadID: ctx.thread.id, runID: ctx.run.id,
                                     kind: .systemNotice, provider: ctx.run.provider,
                                     title: ThreadEvent.attentionTitle, text: text,
                                     payloadJSON: ThreadEvent.noticePayload(ThreadEvent.attentionKey)))

        case .slashCommands(let commands):
            onSlashCommands(SlashCommandKey(provider: ctx.adapter.provider, accountID: ctx.account?.id ?? "",
                                            folder: ctx.project.path), commands)

        case .progressSummary(let line):
            // 상태 줄은 "생각하는 중" 자리에만 쓴다 — 도구 · 답변 · 승인 · 백그라운드 대기는 그 글이 앞선다 (`RunActivity.read`).
            if progressSummary != line { progressSummary = line }

        case .failure(let info):
            lastErrorMessage = info.message
            recordedFailures.append((info.message, info.classification))
            await upsert(ThreadEvent(threadID: ctx.thread.id, runID: ctx.run.id,
                                     kind: .error, provider: ctx.run.provider,
                                     title: info.classification.koreanName, text: info.message,
                                     payloadJSON: info.raw))

        case .subAgent(let info):
            await record(subAgent: info, ctx: ctx)

        case .subAgentEvent(let agentID, let inner):
            ctx.sawAgentActivity = true
            context = ctx
            await handleSubAgent(agentID: agentID, inner, ctx: ctx)

        case .turnSettled:
            // 메인 턴의 끝 — 실행의 끝이 아니다. 알림 · 완료 통지 없이 남은 작업을 기다린다 (상태는 `.running`).
            ctx.mainTurnCompleted = true
            context = ctx
            await closeStreaming()
            isWaitingOnBackground = true
            waitingSince = Date()
            progressSummary = nil

        case .followUpTurnStarted:
            // CLI 가 스스로 연 후속 턴 (같은 실행). 새 응답은 새 메시지 행으로 흐른다.
            ctx.mainTurnCompleted = true
            context = ctx
            isWaitingOnBackground = false
            waitingSince = nil
            progressSummary = nil

        case .finished(let result):
            await finish(result)
        }
    }

    // MARK: - 스트리밍 텍스트

    private func appendStreamingText(_ text: String, provider: AgentProvider,
                                     runID: String, threadID: String) async {
        streamingBuffer += text
        if var e = streamingEvent {
            e.text = streamingBuffer
            e.isStreaming = true
            streamingEvent = e
            publishStreaming()
            // 저장 부하를 줄이기 위해 일정 길이마다만 디스크에 쓴다.
            if streamingBuffer.count % 512 < text.count {
                _ = try? await store.appendEvent(e)
            }
        } else {
            var e = ThreadEvent(threadID: threadID, runID: runID, kind: .agentMessage,
                                provider: provider, title: provider.displayName,
                                text: streamingBuffer, isStreaming: true)
            if let saved = try? await store.appendEvent(e) { e = saved }
            streamingEvent = e
            lastStreamPublish = ProcessInfo.processInfo.systemUptime
            delegate?.runCoordinator(self, didUpsert: e)
        }
    }

    /// 흐르는 응답을 화면에 넘기는 간격 (초). 조각마다 넘기면 화면이 조각마다 대화 전체를 다시 계산했다 — 실측한 Codex 흐름(초당
    /// 조각 44개)에서 CPU 87% → 0.1초씩 모으면 36%, Claude(초당 20개) 53% → 40% (2026-10-06, 최적화 빌드). 화면은 받은 글을
    /// 어차피 고른 속도로 늦춰 풀므로(`StreamReveal`) 모아 넘겨도 흐름은 같다.
    static let streamPublishInterval: TimeInterval = 0.1
    @ObservationIgnored private var lastStreamPublish: TimeInterval = 0
    @ObservationIgnored private var streamPublishPending = false

    /// 흐르는 응답을 화면에 넘긴다 — `streamPublishInterval` 에 한 번. 그 사이에 온 조각은 다음 차례에 모아서. 응답을 확정할 때
    /// (`finalizeStreaming` · `closeStreaming`)는 기다리지 않고 바로 넘기고, 남은 차례는 할 일이 없어진다.
    private func publishStreaming() {
        let now = ProcessInfo.processInfo.systemUptime
        let wait = Self.streamPublishInterval - (now - lastStreamPublish)
        guard wait > 0 else {
            lastStreamPublish = now
            if let streamingEvent { delegate?.runCoordinator(self, didUpsert: streamingEvent) }
            return
        }
        guard !streamPublishPending else { return }
        streamPublishPending = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self else { return }
            self.streamPublishPending = false
            guard let event = self.streamingEvent else { return }
            self.lastStreamPublish = ProcessInfo.processInfo.systemUptime
            self.delegate?.runCoordinator(self, didUpsert: event)
        }
    }

    private func finalizeStreaming(with text: String, provider: AgentProvider,
                                   runID: String, threadID: String) async {
        var e = streamingEvent ?? ThreadEvent(threadID: threadID, runID: runID,
                                              kind: .agentMessage, provider: provider,
                                              title: provider.displayName, text: text)
        e.text = text
        e.isStreaming = false
        if let saved = try? await store.appendEvent(e) { e = saved }
        streamingEvent = nil
        streamingBuffer = ""
        delegate?.runCoordinator(self, didUpsert: e)
    }

    /// 스트리밍 중이던 메인 응답을 지금까지의 글로 확정한다.
    private func closeStreaming() async {
        guard let s = streamingEvent else { return }
        var closed = s
        closed.isStreaming = false
        closed.text = streamingBuffer.isEmpty ? s.text : streamingBuffer
        _ = try? await store.appendEvent(closed)
        streamingEvent = nil
        streamingBuffer = ""
        delegate?.runCoordinator(self, didUpsert: closed)
    }

    /// 저장한 행(순번이 붙은 것)을 돌려준다 — 나중에 같은 행을 고쳐 쓸 곳(질문 행)이 받아 둔다.
    @discardableResult
    private func upsert(_ event: ThreadEvent) async -> ThreadEvent? {
        // 스트리밍 중이던 응답이 있으면 먼저 확정한다 (순서 보존).
        await closeStreaming()
        return await save(event)
    }

    @discardableResult
    private func save(_ event: ThreadEvent) async -> ThreadEvent? {
        guard let saved = try? await store.appendEvent(event) else { return nil }
        delegate?.runCoordinator(self, didUpsert: saved)
        return saved
    }

    /// 승인 결정 행 (`ApprovalDecisionInfo` 의 약속 — `toolUseID` 는 요청의 것, `text` 는 사람이 읽는 결정 이름).
    private func decisionRow(requestID: String, request: ApprovalRequest?, decision: ApprovalDecisionInfo.Decision,
                             reason: String?, answer: String? = nil, text: String, ctx: ActiveContext) -> ThreadEvent {
        let info = ApprovalDecisionInfo(decision: decision, reason: reason, requestTitle: request?.title,
                                        toolName: request?.toolName, approvalKind: request?.kind.rawValue,
                                        requestID: requestID, answer: answer)
        return ThreadEvent(threadID: ctx.thread.id, runID: ctx.run.id, kind: .approvalDecision,
                           provider: ctx.run.provider, title: "승인 결정", text: text,
                           payloadJSON: ThreadEvent.approvalDecisionPayload(info), toolUseID: request?.toolUseID)
    }

    // MARK: - 하위 에이전트

    /// 하위 작업 표를 갱신하고, 처음 보거나 저장할 만한 변화면 그 작업의 `.subAgent` 행을 덮어쓴다.
    /// 진행만 바뀐 것(초당 여러 번)은 저장하지 않는다 — 화면은 `subAgents` 를 본다.
    private func record(subAgent info: SubAgentInfo, ctx: ActiveContext) async {
        let old = subAgents.first { $0.id == info.id }
        if let i = subAgents.firstIndex(where: { $0.id == info.id }) { subAgents[i] = info } else { subAgents.append(info) }
        // 끝난 하위의 흐르던 글은 더 이어지지 않는다 (마지막 메시지 없이 끝나도 남기지 않는다).
        if info.status.isFinished {
            subAgentLiveText[info.id] = nil
            await dropPending(ofFinished: info.id, ctx: ctx)
        }
        if let old, !info.differsForStorage(from: old) { return }
        var row = subAgentRows[info.id] ?? ThreadEvent(
            id: ThreadEvent.subAgentEventID(runID: ctx.run.id, agentID: info.id),
            threadID: ctx.thread.id, runID: ctx.run.id, kind: .subAgent, provider: ctx.run.provider)
        row.title = info.title
        row.text = info.summary ?? ""
        row.payloadJSON = info.jsonString
        // 메인 흐름의 스트리밍을 닫지 않는다 — 대화 행이 아니다.
        guard let saved = try? await store.appendEvent(row) else { return }
        subAgentRows[info.id] = saved
        delegate?.runCoordinator(self, didUpsert: saved)
    }

    /// 끝난 하위가 청한 승인 · 질문은 더 답할 곳이 없다 (CLI 도 그 요청을 버렸다). 화면에서 걷고, 승인은 결정 행으로 닫는다.
    /// 남은 것이 없으면 승인 대기를 푼다.
    private func dropPending(ofFinished agentID: String, ctx: ActiveContext) async {
        let approvals = pendingApprovals.filter { $0.agentID == agentID }
        let hadQuestions = pendingQuestions.contains { $0.agentID == agentID }
        guard !approvals.isEmpty || hadQuestions else { return }
        for question in pendingQuestions where question.agentID == agentID { questionRows[question.id] = nil }
        pendingApprovals.removeAll { $0.agentID == agentID }
        pendingQuestions.removeAll { $0.agentID == agentID }
        droppedApprovalIDs.formUnion(approvals.map(\.id))
        if pendingApprovals.isEmpty && pendingQuestions.isEmpty && state == .awaitingApproval {
            transition(to: .running)
        }
        for request in approvals {
            // 승인 결정과 같은 행. 하위의 것이라 메인 스트리밍을 닫지 않는다.
            respondedDecisions[request.id] = nil
            await save(decisionRow(requestID: request.id, request: request, decision: .cancelled, reason: nil,
                                   text: "하위 작업이 끝나 취소됨", ctx: ctx))
        }
    }

    /// 하위 에이전트 안에서 일어난 일. 메인과 **따로** 저장한다 — 부모 표시를 붙이고, 메인의 스트리밍 슬롯을
    /// 건드리지 않는다 (메인 글을 닫거나 덮지 않는다). 하위의 실패는 실행의 오류 · 상태가 아니다.
    private func handleSubAgent(agentID: String, _ event: AgentEvent, ctx: ActiveContext) async {
        // 메인 경로와 같은 payload 에 부모 표시만 더한다 (status · exitCode · cwd 는 그대로). 규칙은 `ThreadEvent.payload` 하나.
        func tagged(_ payload: [String: Any] = [:]) -> String { ThreadEvent.payload(payload, taggingParent: agentID) }
        func child(_ kind: EventKind, title: String, text: String, payload: String? = nil,
                   toolUseID: String? = nil) -> ThreadEvent {
            ThreadEvent(threadID: ctx.thread.id, runID: ctx.run.id, kind: kind, provider: ctx.run.provider,
                        title: title, text: text, payloadJSON: payload ?? tagged(), toolUseID: toolUseID)
        }

        switch event {
        case .assistantDelta(let text):
            // 흐르는 글은 저장하지 않는다 (메시지가 끝나면 통째로 온다).
            subAgentLiveText[agentID, default: ""] += text

        case .assistantMessage(let text):
            subAgentLiveText[agentID] = nil
            await save(child(.agentMessage, title: ctx.run.provider.displayName, text: text))

        case .reasoning(let text):
            await save(child(.agentReasoning, title: "추론 요약", text: text))

        case .toolStarted(let id, let name, let detail):
            await save(child(.toolRequest, title: name, text: detail, toolUseID: id))

        case .toolFinished(let id, let name, let output, let isError):
            await save(child(.toolResult, title: isError ? "\(name) — 오류" : name, text: output, toolUseID: id))

        case .commandExecution(let id, let command, let cwd, let output, let exitCode, let status):
            var payload: [String: Any] = ["status": status]
            if let exitCode { payload["exitCode"] = exitCode }
            if let cwd { payload["cwd"] = cwd }
            var text = command
            if let output, !output.isEmpty { text += "\n\n--- 출력 ---\n" + output }
            await save(child(.commandExecution, title: JSONUtil.truncate(command, max: 160, marker: "…"),
                             text: text, payload: tagged(payload), toolUseID: id))

        case .fileChange(let id, let paths, let diff, let status):
            var text = paths.joined(separator: "\n")
            if let diff, !diff.isEmpty { text += "\n\n" + diff }
            await save(child(.fileChange, title: paths.joined(separator: ", "), text: text,
                             payload: tagged(["status": status]), toolUseID: id))

        case .notice(let text):
            await save(child(.systemNotice, title: "안내", text: text))

        case .diagnostic(let text):
            await save(child(.systemNotice, title: ThreadEvent.diagnosticTitle, text: text,
                             payload: ThreadEvent.noticePayload(ThreadEvent.diagnosticKey, taggingParent: agentID)))

        case .attention(let text):
            await save(child(.systemNotice, title: ThreadEvent.attentionTitle, text: text,
                             payload: ThreadEvent.noticePayload(ThreadEvent.attentionKey, taggingParent: agentID)))

        case .failure(let info):
            // CLI 원문은 부모 표시 옆 `raw` 에 둔다. `lastErrorMessage` · 실행 상태는 메인 것만.
            await save(child(.error, title: info.classification.koreanName, text: info.message,
                             payload: tagged(info.raw.map { ["raw": $0] } ?? [:])))

        default:
            // 계약 밖 (하위 안에는 내용 이벤트만 온다). 승인 · 질문은 메인 경로로 온다 (`ApprovalRequest.agentID`).
            break
        }
    }

    /// 하위 작업 하나만 멈춘다 (`SubAgentInfo.canStop` 인 것). 실행 전체는 계속된다 — 상태를 바꾸지 않는다.
    /// 멈춘 결과는 어댑터가 `.subAgent` 로 알린다. 보냈으면 true.
    @discardableResult
    func stopSubAgent(id: String) async -> Bool {
        guard let ctx = context, !finishing else { return false }
        return await ctx.adapter.stopSubAgent(id: id)
    }

    // MARK: - 종료

    /// 실행 끝의 오류가 실행 중에 남긴 실패와 같은가 (순수 — 시험한다). 글이 같거나(앞뒤 빈칸 무시) 둘 다 구독 한도면 같다.
    static func alreadyRecorded(message: String, limitStatus: LimitStatus?,
                                recorded: [(message: String, classification: LimitStatus)]) -> Bool {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return recorded.contains {
            $0.message.trimmingCharacters(in: .whitespacesAndNewlines) == text
                || ($0.classification == .subscriptionCap && limitStatus == .subscriptionCap)
        }
    }

    private func finish(_ result: AgentTurnResult) async {
        guard var ctx = context, !finishing else { return }
        // 첫 `await` 전에 — 정리하는 사이 온 중단 · 전이가 아래에서 저장할 끝 상태를 덮지 않게.
        finishing = true
        isWaitingOnBackground = false
        waitingSince = nil

        // 남은 스트리밍 확정.
        await closeStreaming()

        // 실행이 끝나면 남은 하위 작업도 프로세스와 함께 끝난다. 저장된 행이 "실행 중"으로 남지 않게 멈춤으로 적는다.
        let ended = Date()
        for var info in subAgents where info.status == .running {
            info.status = .stopped
            info.endedAt = ended
            await record(subAgent: info, ctx: ctx)
        }

        // 세션 정보 갱신.
        if let sid = result.sessionID {
            ctx.session.cliSessionID = sid
            ctx.session.resumable = true
            if let home = ctx.codexRecordHome { ctx.session.recordHome = home }
        }
        if result.state == .failed, result.terminalReason == "setup_failed" {
            ctx.session.resumable = false
            ctx.session.lastError = result.errorMessage
        }
        try? await store.upsertSession(ctx.session)

        ctx.run.state = result.state
        ctx.run.endedAt = Date()
        ctx.run.terminalReason = result.terminalReason
        ctx.run.model = result.model ?? ctx.run.model
        ctx.run.errorMessage = result.errorMessage
        context = ctx
        activeRun = ctx.run
        try? await store.updateRun(ctx.run)

        // 사용량 기록.
        var usageRecord: UsageRecord?
        if let u = result.usage { usageRecord = await recordUsage(u, ctx: ctx) }

        if result.state == .cancelled {
            await upsert(ThreadEvent(
                threadID: ctx.thread.id, runID: ctx.run.id, kind: .systemNotice,
                provider: ctx.run.provider, title: "사용자 취소",
                text: "사용자가 실행을 중단했습니다."))
        }

        // 오류/한도 안내 이벤트 — 실행 중에 같은 실패를 이미 남겼으면(같은 글, 또는 둘 다 구독 한도) 다시 남기지 않는다.
        if let message = result.errorMessage, !message.isEmpty,
           !Self.alreadyRecorded(message: message, limitStatus: result.limitStatus, recorded: recordedFailures) {
            await upsert(ThreadEvent(
                threadID: ctx.thread.id, runID: ctx.run.id, kind: .error,
                provider: ctx.run.provider,
                title: (result.limitStatus ?? .unknownCause).koreanName, text: message))
        }

        // 프로세스 종료 확인 (자손까지 — `ManagedProcess.shutdown`). 확인되지 않으면 기록해 두고 인계 전달 · 앱의 git 쓰기를 막는다
        // (보내기는 막지 않는다 — 변경사항 탭 · 대화 맨 위의 경고와 [확인함]).
        let terminated = await ctx.adapter.shutdown()
        if !terminated {
            let note = Self.unterminatedNote(ctx)
            unterminatedProcesses.append(note)
            ctx.run.childProcessNote = note
            try? await store.updateRun(ctx.run)
            await upsert(ThreadEvent(
                threadID: ctx.thread.id, runID: ctx.run.id, kind: .systemNotice,
                provider: ctx.run.provider, title: "프로세스 종료 미확인", text: note))
        }

        // 인계 전송 결과 판정.
        if let handoffID = ctx.handoffID {
            await resolveHandoffDelivery(handoffID: handoffID, ctx: ctx, result: result)
        }

        try? await store.touchThread(id: ctx.thread.id)

        state = result.state
        pendingApprovals = []
        pendingQuestions = []
        delegate?.runCoordinator(self, didChangeState: result.state, run: ctx.run)
        delegate?.runCoordinator(self, didFinish: ctx.run, result: result, usage: usageRecord)

        let title: String
        switch result.state {
        case .completed: title = "실행 완료"
        case .cancelled: title = "실행 중단됨"
        case .rateLimited: title = "사용 한도에 도달했습니다"
        default: title = "실행 오류"
        }
        if result.state != .completed || !ctx.run.isHandoffDelivery {
            delegate?.runCoordinator(
                self, needsAttention: title,
                body: "\(ctx.thread.title) · \(ctx.partyName)",
                threadID: ctx.thread.id,
                kind: result.state == .rateLimited ? .limitReached : .runFinished)
        }

        endSession(processEnded: terminated)
    }

    /// 사용량 한 행을 짓고 저장한다. 비용은 CLI 가 보고한 값, 없으면 가격표로 계산한다.
    private func recordUsage(_ u: TurnUsage, ctx: ActiveContext) async -> UsageRecord {
        var record = UsageRecord(runID: ctx.run.id, threadID: ctx.thread.id,
                                 provider: ctx.run.provider, model: u.model ?? ctx.run.model,
                                 inputTokens: u.inputTokens,
                                 cacheReadTokens: u.cacheReadTokens,
                                 cacheWriteTokens: u.cacheWriteTokens,
                                 outputTokens: u.outputTokens,
                                 reasoningTokens: u.reasoningTokens,
                                 durationMs: u.durationMs,
                                 confirmed: u.confirmed)
        if let reported = u.reportedCostUSD {
            record.costUSD = reported
            record.costSource = .cliReported
        } else {
            let calculator = CostCalculator(entries: priceEntries)
            if let (cost, version) = calculator.calculate(
                provider: ctx.run.provider, model: record.model, usage: record) {
                record.costUSD = cost
                record.costSource = .appCalculated
                record.priceCatalogVersion = version
            } else {
                record.costSource = .unknown   // 금액 미확인
            }
        }
        try? await store.upsertUsage(record)
        return record
    }

    private static func unterminatedNote(_ ctx: ActiveContext) -> String {
        "\(ctx.partyName) 프로세스(PID \(ctx.pid.map(String.init) ?? "미확인")) 종료를 확인하지 못했습니다."
    }

    /// 실행을 끝낸 뒤의 정리 (`finish` · `shutdownForQuit` 의 맨 끝). 끝나기를 기다리던 곳을 깨우고, 관리자가 목록에서 뺀다.
    private func endSession(processEnded: Bool) {
        // Codex 실행 폴더(`CodexRunHome`)는 프로세스가 끝난 뒤에 지운다 — 종료를 확인하지 못했으면 남겨 둔다 (다음 시작이 지운다).
        if processEnded { context?.codexRunHome?.remove() }
        context = nil
        activeRun = nil
        activeThreadID = nil
        activeProvider = nil
        activeAccount = nil
        activeSelection = nil
        activeBoost = false
        subAgents = []
        subAgentRows = [:]
        subAgentLiveText = [:]
        isWaitingOnBackground = false
        waitingSince = nil
        consumeTask = nil
        let waiters = endWaiters
        endWaiters = []
        for waiter in waiters { waiter.resume() }
        onEnded?()
    }

    // MARK: - 승인 / 질문 응답

    func respond(approval: ApprovalRequest, decision: ApprovalDecision) async {
        guard let ctx = context, ctx.run.id == approval.runID else {
            // 종료된 실행에 대한 늦은 응답은 적용하지 않는다.
            pendingApprovals.removeAll { $0.id == approval.id }
            lastErrorMessage = "이미 종료된 실행의 승인 요청이라 적용하지 않았습니다."
            return
        }
        // 이미 답했거나 이미 닫힌 요청 (두 번 누름 · 늦은 단축키) — 첫 결정만 보낸다. 두 번째 결정이 결정 행을 덮지 않게.
        guard respondedDecisions[approval.id] == nil, pendingApprovals.contains(where: { $0.id == approval.id }) else { return }
        // 결정 행에 적을 결정 · 사유 (어댑터는 글만 알려 온다). 보내기 전에 — 알림이 먼저 처리될 수 있다.
        respondedDecisions[approval.id] = decision
        await ctx.adapter.respond(approvalID: approval.id, decision: decision)
    }

    /// 대화를 "자동 승인"으로 바꾼 순간 떠 있던 승인 요청들을 허용한다 (결정 행은 "자동 허용"). 권한 요청 · MCP 입력 요청 ·
    /// 에이전트의 질문 카드는 그대로 둔다.
    func approvePendingAutomatically() async {
        guard let ctx = context, !unattended, !finishing else { return }
        for request in pendingApprovals where !autoApproved.contains(request.id) && request.allowsAutoApproval {
            await approveAutomatically(request, ctx: ctx)
        }
    }

    /// 앱이 허용한다: 결정 행 "자동 허용"을 먼저 남기고 어댑터에 허용을 보낸다 (어댑터가 알려 오는 결정은 다시 적지 않는다).
    private func approveAutomatically(_ request: ApprovalRequest, ctx: ActiveContext) async {
        autoApproved.insert(request.id)
        let row = decisionRow(requestID: request.id, request: request, decision: .autoAllow, reason: nil,
                              text: "자동 허용", ctx: ctx)
        if request.agentID != nil { await save(row) } else { await upsert(row) }
        await ctx.adapter.respond(approvalID: request.id, decision: .allow)
    }

    func respond(question: UserQuestion, answers: [String: String]) async {
        guard let ctx = context, ctx.run.id == question.runID else {
            pendingQuestions.removeAll { $0.id == question.id }
            lastErrorMessage = "이미 종료된 실행의 질문이라 응답하지 않았습니다."
            return
        }
        // 어댑터가 알려 오는 "응답 전송" 을 결정 행으로 적지 않게 — 보내기 전에 (알림이 먼저 처리될 수 있다).
        answeredQuestionIDs.insert(question.id)
        await ctx.adapter.respond(questionID: question.id, answers: answers)
        pendingQuestions.removeAll { $0.id == question.id }
        if pendingApprovals.isEmpty && pendingQuestions.isEmpty && state == .awaitingApproval {
            transition(to: .running)
        }
        // 무엇이라 답했는지 질문 행에 남긴다 (비밀 입력은 가린다). 옛 행이라 메인 스트리밍을 닫지 않는다.
        if var row = questionRows.removeValue(forKey: question.id) {
            row.text = question.recordText(answers: answers)
            row.payloadJSON = JSONUtil.string([ThreadEvent.questionAnsweredKey: true])
            await save(row)
        }
    }

    // MARK: - 중단

    func interrupt() async {
        // 끝내는 중이면 멈출 것이 없다 — 이미 정한 끝 상태를 "중단 중"으로 덮지 않는다.
        guard let ctx = context, !finishing else { return }
        interruptRequested = true
        // 시작 중이어도 요청을 유실하지 않는다 (어댑터가 큐에 넣는다).
        transition(to: .interrupting)
        await ctx.adapter.requestInterrupt()
    }

    /// 앱 종료 시 정리. 반환값이 false 면 종료 완료로 표시하지 않는다.
    /// 소비 작업을 끊으므로 `finish` 는 오지 않는다 — 실행 행 · 사용량 · 인계 전달 판정과 세션의 끝을 여기서 맺는다.
    /// 사용자가 두 번째 경고에서 종료를 취소해도 이 실행은 끝났다: 대화는 다시 보낼 수 있고, 종료 미확인이면 관리자가 인계 전달 · git 쓰기를 막는다.
    /// 실행 전후 비교 · 자동 작업의 뒷정리는 대리자가 `didQuit` 으로 받아 종료가 취소됐을 때 한다 (`AppModel.reconcileCancelledQuit`).
    func shutdownForQuit() async -> Bool {
        guard let ctx = context else { return true }
        if finishing {
            // `finish` 가 이미 끝내는 중이다 (프로세스 종료 확인도 거기서 한다). 같은 행을 두 번 쓰지 않고 끝나기를 기다린다.
            await withCheckedContinuation { endWaiters.append($0) }
            return unterminatedProcesses.isEmpty
        }
        finishing = true
        isWaitingOnBackground = false
        waitingSince = nil
        // 흐르던 메인 응답은 지금까지의 글로 확정한다 ("쓰는 중" 으로 남지 않게 — 종료가 취소되면 대화가 계속 보인다).
        await closeStreaming()
        consumeTask?.cancel()
        await ctx.adapter.requestInterrupt()
        let ok = await ctx.adapter.shutdown()
        if ok {
            // 남은 하위 작업을 멈춤으로 적는다 (다음 실행 때 "실행 중"으로 남지 않게).
            // 종료를 확인하지 못했으면 실행과 같이 그대로 둔다.
            let ended = Date()
            for var info in subAgents where info.status == .running {
                info.status = .stopped
                info.endedAt = ended
                await record(subAgent: info, ctx: ctx)
            }
        }
        // 결과가 오지 않아도 쓴 만큼은 남긴다 (기다리던 실행이면 끝난 메인 턴의 값). 확정 값이 아니다.
        if var usage = ctx.adapter.lastKnownUsage {
            usage.confirmed = false
            _ = await recordUsage(usage, ctx: ctx)
        }
        var run = ctx.run
        if ok {
            run.state = .cancelled
            run.terminalReason = "app_quit"
        } else {
            run.state = .handoffDeliveryUnknown
            run.terminalReason = "app_quit_unterminated"
            run.childProcessNote = "앱 종료 시 프로세스 종료를 확인하지 못했습니다."
            unterminatedProcesses.append(Self.unterminatedNote(ctx))
        }
        run.endedAt = Date()
        try? await store.updateRun(run)
        // 인계 전달 판정 — "전송 중" 으로 남으면 다시 보낼 수도, 미확인으로 다룰 수도 없다.
        if let handoffID = ctx.handoffID {
            await resolveHandoffDelivery(handoffID: handoffID, ctx: ctx,
                                         result: AgentTurnResult(state: run.state, terminalReason: run.terminalReason))
        }

        state = run.state
        pendingApprovals = []
        pendingQuestions = []
        delegate?.runCoordinator(self, didQuit: run)
        delegate?.runCoordinator(self, didChangeState: run.state, run: run)
        endSession(processEnded: ok)
        return ok
    }

    /// 모델 목록의 범위: Codex 는 실제로 보낼 계정의 것 — 인계는 대화에 아직 옛 계정이 적혀 있는 채 다른 계정으로 간다.
    private func modelScope(thread: ConversationThread, provider: AgentProvider, account: CodexAccountRef?) -> AgentScope {
        if provider == .codex, let account { return .codex(account.id) }
        return thread.scope(for: provider)
    }

    // MARK: - 인계 전송

    /// 이미 전송을 시작한 인계는 자동으로 재전송하지 않는다.
    func canSend(handoff: Handoff) -> Bool {
        handoff.deliveryState == .draft || handoff.deliveryState == .failed
    }

    /// 보내기 전에 DB 의 행을 점유한다(`Store.claimHandoffForSending`) — 넘겨받은 사본의 상태가 아니라 DB 의 값으로
    /// "초안 · 실패일 때만" 을 판정한다. 화면이 들고 있던 옛 사본(초안 상태)으로 두 번 불려도 한 번만 간다.
    @discardableResult
    func deliver(handoff: Handoff, thread: ConversationThread, project: Project,
                 toAccount: CodexAccountRef? = nil) async throws -> Run {
        guard canSend(handoff: handoff) else {
            throw StartError.cliUnavailable(
                "이 인계는 이미 전송을 시작했습니다(\(handoff.deliveryState.koreanName)). "
                + "중복 전송을 막기 위해 자동 재전송하지 않습니다.")
        }
        // 파일을 변경하는 기존 프로세스의 종료가 불확실하면 다음 에이전트를 시작하지 않는다.
        guard unterminatedProcesses.isEmpty else {
            throw StartError.cliUnavailable(
                "종료가 확인되지 않은 프로세스가 있어 다음 에이전트를 시작하지 않습니다:\n"
                + unterminatedProcesses.joined(separator: "\n"))
        }
        // 보낼 수 없는 Antigravity 선택이면 "전송 중" · 인계 전송 기록을 남기기 전에 멈춘다 (인계는 초안 그대로 남는다).
        let antigravity = handoff.toProvider == .gemini ? try await antigravityPlan(for: thread) : nil

        // 받는 쪽의 계열 선택(`gpt-*-sol`)을 풀 수 없으면 점유 · "인계 전송" 기록 전에 멈춘다 — 확실히 보내지 못할 인계가
        // 보낸 것처럼 기록에 남지 않게 (풀기는 `send` 가 다시 한다).
        if handoff.toProvider != .gemini, let family = ModelCatalog.familyOfSelection(thread.selection(for: handoff.toProvider).model) {
            let options = (try? await store.modelOptions(scope: modelScope(thread: thread, provider: handoff.toProvider,
                                                                          account: toAccount))) ?? []
            guard ModelCatalog.latestModel(family: family, in: options) != nil else {
                throw StartError.modelUnresolved(thread.selection(for: handoff.toProvider).model ?? family)
            }
        }

        var h = handoff
        h.sentAt = Date()
        // 초안을 만들 때는 행을 넣지 않는다 — 넘길 때 넣고(이미 있으면 그대로) DB 의 상태로 점유한다.
        try await store.insertHandoffIfAbsent(h)
        guard try await store.claimHandoffForSending(h, sentAt: h.sentAt ?? Date()) else {
            throw StartError.cliUnavailable(
                "이 인계는 이미 전송을 시작했습니다. 중복 전송을 막기 위해 자동 재전송하지 않습니다.")
        }
        h.deliveryState = .sending

        // 받는 쪽 CLI 를 띄울 수 있는지 "인계 전송" 기록보다 먼저 본다 — 시작하지 못할 인계가 보낸 것처럼 대화에 남지 않게
        // (다음 인계 문서의 "인계 수행" 으로도 들어갔다). 점유한 행은 다시 보낼 수 있는 실패로 둔다.
        if adapterFactory == nil {
            let status = await environment.checkStatus(h.toProvider)
            if status.resolvedPath == nil || !status.executable {
                let problem = status.error ?? "\(h.toProvider.displayName) CLI 를 실행할 수 없습니다."
                h.deliveryState = .failed
                h.note = Self.appendingNote(h.note, "전송 시작 실패: \(problem)")
                try? await store.updateHandoff(h)
                throw StartError.cliUnavailable(problem)
            }
        }

        let packet = (try? JSONDecoder().decode(HandoffPacket.self,
                                                from: Data(h.draftJSON.utf8)))
        let fromName = HandoffPacket.partyName(h.fromProvider, packet?.fromAccountLabel)
        let toName = HandoffPacket.partyName(h.toProvider, packet?.toAccountLabel ?? toAccount?.label)
        let event = ThreadEvent(threadID: thread.id, kind: .handoffSent,
                                provider: h.fromProvider,
                                title: "\(fromName) → \(toName) 인계 전송",
                                text: h.finalText,
                                payloadJSON: JSONUtil.line(["localToken": h.localToken,
                                                            "baseSeq": h.baseSeq,
                                                            "fromAccountID": h.fromAccountID,
                                                            "toAccountID": h.toAccountID]))
        if let saved = try? await store.appendEvent(event) {
            delegate?.runCoordinator(self, didUpsert: saved)
        }

        let run: Run
        do {
            run = try await send(prompt: h.finalText, thread: thread, project: project,
                                 provider: h.toProvider, account: toAccount,
                                 isHandoffDelivery: true,
                                 handoffID: h.id, recordUserEvent: false, antigravity: antigravity)
        } catch {
            // 시작하지 못했다 — 받는 쪽이 받지 않은 것이 확실하므로 다시 보낼 수 있게 둔다.
            h.deliveryState = .failed
            h.note = Self.appendingNote(h.note, "전송 시작 실패: \(error.localizedDescription)")
            try? await store.updateHandoff(h)
            throw error
        }
        // 여기부터는 CLI 가 돈다. 기록 쓰기가 실패해도 '전송 실패' 로 바꾸지 않는다 (받았을 수 있다 — 끝에 판정한다).
        h.deliveryRunID = run.id
        try? await store.setHandoffDeliveryRun(id: h.id, runID: run.id)
        state = .handoffSending
        return run
    }

    static func appendingNote(_ existing: String?, _ addition: String?) -> String? {
        guard let addition, !addition.isEmpty else { return existing }
        guard let existing, !existing.isEmpty else { return addition }
        return "\(existing) · \(addition)"
    }

    private func resolveHandoffDelivery(handoffID: String, ctx: ActiveContext,
                                        result: AgentTurnResult) async {
        guard let handoffs = try? await store.handoffs(threadID: ctx.thread.id),
              var h = handoffs.first(where: { $0.id == handoffID }) else { return }

        let deliveryNote: String?
        if result.limitStatus == .authProblem && !ctx.mainTurnCompleted {
            // 인증 실패는 모델이 인계를 읽기 전에 끝난다. CLI 가 오류 문구를 응답처럼 내보내도
            // (실측: Claude Code 2.1.233 "Failed to authenticate: OAuth session expired") 수신으로 보지 않는다.
            // 받지 못한 것이 확실하므로 다시 보낼 수 있는 상태로 둔다.
            h.deliveryState = .failed
            deliveryNote = "대상 CLI 인증 실패로 전달되지 않았습니다: \(result.errorMessage ?? "원인 미확인")"
        } else if ctx.mainTurnCompleted || result.state == .completed || ctx.sawAgentActivity {
            // 대상이 인계를 받고 실제로 응답을 시작했다. 메인 턴이 완료로 끝났으면 답까지 마친 것이다 — 그 뒤 후속 턴이
            // 인증 오류 등으로 죽어도 전달 실패가 아니다 (다시 보내면 같은 인계가 두 번 간다).
            h.deliveryState = .delivered
            h.toSessionID = result.sessionID ?? ctx.session.cliSessionID
            deliveryNote = result.state == .completed ? nil : "응답 중 종료됨(수신은 확인됨)"
            // 전달 지점 기록: 이 세션은 baseSeq 까지 받았다.
            var session = ctx.session
            session.lastDeliveredSeq = max(session.lastDeliveredSeq, h.baseSeq)
            try? await store.upsertSession(session)
        } else if result.terminalReason == "setup_failed" || result.terminalReason == "launch_failed"
                    || result.terminalReason == "resume_failed" {
            // 세션조차 만들지 못했다(다른 계정으로 대화의 세션을 재개하지 못함 포함) → 대상이 받지 못한 것이 확실하다.
            h.deliveryState = .failed
            deliveryNote = "대상 세션을 시작하지 못했습니다: \(result.errorMessage ?? "원인 미확인")"
        } else {
            // 받았는지 알 수 없다. 무조건 재전송하지 않는다.
            h.deliveryState = .unknown
            deliveryNote = "전달 여부를 확인하지 못했습니다(\(result.terminalReason ?? "사유 미확인")). "
                + "이 대화에 받는 쪽의 응답이 있는지 확인한 뒤 이어 가세요."
        }
        // 보내기 전에 적힌 검토 표시("사람 검토함" / "자동 인계 · 사람 검토 없음")는 지우지 않고 뒤에 잇는다.
        h.note = Self.appendingNote(h.note, deliveryNote)
        try? await store.updateHandoff(h)

        let notice = ThreadEvent(
            threadID: ctx.thread.id, runID: ctx.run.id, kind: .handoffReceived,
            provider: h.toProvider, title: "인계 전달 상태: \(h.deliveryState.koreanName)",
            text: deliveryNote ?? "대상이 인계를 수신하고 응답을 시작했습니다.",
            payloadJSON: JSONUtil.line(["localToken": h.localToken,
                                        "state": h.deliveryState.rawValue]))
        if let saved = try? await store.appendEvent(notice) {
            delegate?.runCoordinator(self, didUpsert: saved)
        }
    }

    /// 종료 미확인 프로세스 경고를 사용자가 확인했을 때.
    func acknowledgeUnterminated() {
        unterminatedProcesses.removeAll()
    }
}
