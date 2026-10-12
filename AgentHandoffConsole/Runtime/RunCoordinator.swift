import Foundation
import Observation

@MainActor
protocol RunCoordinatorDelegate: AnyObject {
    func runCoordinator(_ c: RunCoordinator, didUpsert event: ThreadEvent)
    func runCoordinator(_ c: RunCoordinator, didChangeState state: RunState, run: Run?)
    func runCoordinator(_ c: RunCoordinator, didReceive limits: LimitSnapshot)
    func runCoordinator(_ c: RunCoordinator, didFinish run: Run,
                        result: AgentTurnResult, usage: UsageRecord?)
    /// 앱 종료로 끝낸 실행 (`RunSession.shutdownForQuit`). `didFinish` 는 오지 않는다 — 다음 일을 시작하지 않게.
    /// 사용자가 종료를 취소해 앱이 계속 돌면, 받는 쪽이 이 실행의 뒷정리(실행 전후 비교 · 자동 작업의 기록)를 한다.
    func runCoordinator(_ c: RunCoordinator, didQuit run: Run)
    func runCoordinator(_ c: RunCoordinator, needsAttention title: String, body: String,
                        threadID: String, kind: AttentionKind)
}

extension RunCoordinatorDelegate {
    func runCoordinator(_ c: RunCoordinator, didQuit run: Run) {}
}

/// 사용자 주의가 필요한 사건. 알림 구현과 분리해 두어 Runtime 이 UI 에 의존하지 않는다.
enum AttentionKind: Sendable {
    case runFinished
    case approvalNeeded
    case limitReached
}

/// 에이전트 실행들을 묶는다: 턴마다 `RunSession` 을 하나 만들어 시작하고, 끝나면 뺀다.
///
/// - **한 대화에는 실행 하나.** 같은 대화에 두 턴이 겹치면 기록 순서와 CLI 세션 재개가 꼬인다. 다른 대화의 실행은 함께 돈다.
/// - 동시 실행 수는 `maxConcurrentRuns` 로 묶을 수 있다. **앱의 `AppModel.runner` 는 묶지 않는다(nil)** — 대화마다 하나라는 규칙만
///   남고, 같은 폴더의 겹침 · git 잠금은 `AppModel` 이 폴더 단위로 본다. 상한을 쓰는 것은 검토 레인(`ReadOnlyRunPool`, 레인 수)뿐이다.
/// - `state` · `activeRun` · `pendingApprovals` 같은 단수 속성은 **가장 최근에 시작한 활성 실행**의 값이다 (화면이 아직 실행 하나를
///   그린다). 실행별 값은 `session(threadID:)` · `session(runID:)` 로 읽는다.
@MainActor
@Observable
final class RunCoordinator {

    // MARK: - 실행 시작

    enum StartError: LocalizedError {
        /// 이 대화에 이미 실행이 있거나, 동시 실행 상한(`maxConcurrentRuns`)에 닿았다.
        case busy
        case cliUnavailable(String)
        /// 읽기 전용 턴을 보장할 수 없는 제공자다 (`AgentProvider.supportsReadOnlyTurns`). 프로세스를 띄우지 않는다.
        case readOnlyUnsupported(AgentProvider)
        /// 검토 레인은 읽기 전용 턴만 받는다 — 지켜보는 사람이 없는 실행이 파일을 바꾸면 안 된다.
        case unattendedNeedsReadOnly
        /// agy 가 거부할 조합이거나 넘길 강도를 정할 근거가 없다 (`AntigravityAdapter.plan`). 프로세스를 띄우지 않는다.
        case antigravityBlocked(AntigravityAdapter.TurnBlock)
        /// Codex 계열 선택(`gpt-*-sol`)을 풀 모델이 지금 목록에 없다 (목록을 못 읽음 · 그 계열이 사라짐). 프로세스를 띄우지 않는다.
        case modelUnresolved(String)
        /// "API 크레딧으로 실행" 을 켠 대화인데 키체인에서 Claude API 키를 읽지 못했다 (지웠거나 키체인 허락을 거절함). 프로세스를 띄우지 않는다.
        case claudeAPIKeyMissing

        var errorDescription: String? {
            switch self {
            case .busy: return "이 대화에서 이미 에이전트가 실행 중입니다. 끝나기를 기다리거나 중단한 뒤 다시 보내세요."
            case .cliUnavailable(let m): return m
            case .readOnlyUnsupported(let provider):
                return "\(provider.displayName) 는 읽기 전용 실행을 보장할 수 없어 보내지 않았습니다."
            case .unattendedNeedsReadOnly: return "검토 레인은 읽기 전용 실행만 받습니다."
            case .antigravityBlocked(let block): return "Antigravity 로 보내지 않았습니다 — " + block.message
            case .modelUnresolved(let selection):
                let family = ModelCatalog.familyOfSelection(selection) ?? selection
                return "Codex 모델 목록에서 \(family) 계열 모델을 찾지 못해 보내지 않았습니다. 모델 목록을 새로고침하거나 다른 모델을 고르세요."
            case .claudeAPIKeyMissing:
                return "키체인에서 Claude API 키를 읽지 못해 보내지 않았습니다. 설정 > 에이전트 > Claude Code 에서 키를 다시 넣거나, "
                    + "모델 칩에서 ‘API 크레딧으로 실행’ 을 끄면 구독으로 보냅니다."
            }
        }
    }

    private struct Entry {
        let threadID: String
        let session: RunSession
    }

    /// 시작 순. 시작을 준비하는 중(CLI 확인 · 기록 저장)인 것도 들어 있다 — 그 사이 같은 대화의 두 번째 보내기를 받지 않는다.
    private var entries: [Entry] = []
    /// 앱이 시작한 프로세스 중 종료가 확인되지 않은 것들 (어느 실행의 것이든).
    private(set) var unterminatedProcesses: [String] = []
    /// 활성 실행이 없을 때 단수 속성이 돌려주는 값: 마지막으로 끝난 실행의 상태와 오류 문구.
    private var lastState: RunState = .idle
    private var lastError: String?

    @ObservationIgnored weak var delegate: RunCoordinatorDelegate?
    @ObservationIgnored private let store: Store
    @ObservationIgnored private let environment: CLIEnvironment
    @ObservationIgnored private var priceEntries: [PriceEntry] = []

    /// 설정값. 실행을 시작할 때 그 세션에 넣어 준다.
    var claudePermissionMode = "manual"
    var codexSandboxMode = "workspace-write"
    var codexApprovalPolicy = "on-request"
    /// Claude · Codex 의 기본 추론 강도 — 설정 > 에이전트에서 사람이 고른 것만 (없으면 모델 기본값 — `EffortScale.resolvedDefault`).
    var defaultEfforts: [AgentProvider: String] = [:]
    /// Antigravity 턴을 샌드박스로 실행할지. 켜면 셸 명령이 파일을 쓰지 못한다 (실측).
    var antigravitySandbox = true
    /// 사람이 지켜보지 않는 실행 (검토 레인 — `ReadOnlyRunPool`). 읽기 전용 턴만 받고, 승인 요청은 거절하고, 질문이 오면 중단한다.
    var unattended = false
    /// 함께 돌 수 있는 실행 수. nil 이면 묶지 않는다 (대화마다 하나라는 규칙만 남는다).
    var maxConcurrentRuns: Int?
    /// 승인을 묻지 않고 허용하는 대화 (입력창의 승인 칩). 실행은 승인 요청이 올 때마다 이 값을 본다 (`RunSession.shouldAutoApprove`).
    var autoApprovalThreadIDs: Set<String> = []
    /// Claude 를 API 키로 실행하는 대화 (모델 칩의 "API 크레딧으로 실행", 키가 저장돼 있을 때만 — `AppModel.claudeAPIThreadIDs`).
    /// 실행을 시작할 때 그 세션에 넣는다 (`RunSession.usesClaudeAPI`).
    var claudeAPIThreadIDs: Set<String> = []
    /// 실행의 CLI 가 알려 준 명령 · 스킬 (Claude 초기화 응답) — 앱이 입력창 "/" 목록으로 받아 둔다 (`AppModel.receiveSlashCommands`).
    var slashCommandsHandler: (@MainActor (SlashCommandKey, [SlashCommand]) -> Void)?

    /// 어댑터를 만드는 곳. nil 이거나 nil 을 돌려주면 설치된 CLI 로 실제 어댑터를 만든다.
    /// 검증은 여기에 가짜 어댑터를 넣어 CLI · 네트워크 없이 실행 흐름(기록 · 상태 전이 · 승인 · 중단)을 돌린다.
    @ObservationIgnored var adapterFactory: ((AgentProvider) -> AgentAdapter?)?

    init(store: Store, environment: CLIEnvironment) {
        self.store = store
        self.environment = environment
    }

    func loadPrices() async {
        priceEntries = (try? await store.priceEntries()) ?? []
    }

    // MARK: - 실행 조회

    /// 돌고 있는 실행들, 시작 순.
    var activeSessions: [RunSession] { entries.map(\.session).filter(\.isBusy) }
    func session(threadID: String) -> RunSession? { entries.first { $0.threadID == threadID }?.session }
    func session(runID: String) -> RunSession? { entries.first { $0.session.activeRun?.id == runID }?.session }
    func isBusy(threadID: String) -> Bool { session(threadID: threadID)?.isBusy ?? false }
    /// 실행을 더 받을 수 있다 (동시 실행 상한 기준. 대화마다 하나라는 규칙은 `send` 가 본다).
    var hasCapacity: Bool { maxConcurrentRuns.map { entries.count < $0 } ?? true }

    // MARK: - 단수 속성 (가장 최근에 시작한 활성 실행)
    //
    // 실행이 하나뿐이던 때의 입구다. **앱의 화면은 더 쓰지 않는다** — 대화별 값은 `session(threadID:)` 로 읽는다
    // (`isBusy` "무엇이든 돌고 있나"와, 도는 실행이 없을 때 마지막으로 끝난 실행의 상태를 돌려주는 `state` 만 메뉴바가 쓴다).
    // 검증 하네스가 실행 하나를 돌릴 때의 편의로 남겨 둔다.

    private var current: RunSession? { entries.last { $0.session.isBusy }?.session }

    var isBusy: Bool { current != nil }
    var state: RunState { current?.state ?? lastState }
    var activeRun: Run? { current?.activeRun }
    var activeThreadID: String? { current?.activeThreadID }
    var activeProvider: AgentProvider? { current?.activeProvider }
    var activeAccount: CodexAccountRef? { current?.activeAccount }
    var activeSelection: ModelSelection? { current?.activeSelection }
    var activeBoost: Bool { current?.activeBoost ?? false }
    var pendingApprovals: [ApprovalRequest] { current?.pendingApprovals ?? [] }
    var pendingQuestions: [UserQuestion] { current?.pendingQuestions ?? [] }
    var lastErrorMessage: String? { current?.lastErrorMessage ?? lastError }

    // MARK: - 시작

    /// 이 대화의 자리를 잡는다. 첫 `await` 전에 부른다 — CLI 확인을 기다리는 사이 같은 대화의 두 번째 보내기가 끼어들지 못한다.
    private func reserve(threadID: String) throws -> RunSession {
        guard session(threadID: threadID) == nil, hasCapacity else { throw StartError.busy }
        let session = RunSession(store: store, environment: environment)
        session.claudePermissionMode = claudePermissionMode
        session.codexSandboxMode = codexSandboxMode
        session.codexApprovalPolicy = codexApprovalPolicy
        session.defaultEfforts = defaultEfforts
        session.antigravitySandbox = antigravitySandbox
        session.unattended = unattended
        session.shouldAutoApprove = { [weak self] in self?.autoApprovalThreadIDs.contains(threadID) ?? false }
        session.usesClaudeAPI = claudeAPIThreadIDs.contains(threadID)
        session.onSlashCommands = { [weak self] key, commands in self?.slashCommandsHandler?(key, commands) }
        session.adapterFactory = adapterFactory
        session.priceEntries = priceEntries
        session.delegate = RunSession.Relay(owner: self)
        session.onEnded = { [weak self, weak session] in
            if let session { self?.release(session) }
        }
        entries.append(Entry(threadID: threadID, session: session))
        return session
    }

    private func release(_ session: RunSession) {
        entries.removeAll { $0.session === session }
    }

    /// 세션이 완료를 알리기 직전. 끝난 실행의 상태와 종료 미확인 프로세스를 받아 둔다.
    func sessionWillReport(_ session: RunSession) {
        lastState = session.state
        lastError = session.lastErrorMessage
        unterminatedProcesses += session.unterminatedProcesses
    }

    /// 한 턴을 실행한다.
    ///
    /// `account` 는 Codex 실행이 쓸 계정(로그인)이다. 그 값은 **이 자식 프로세스에만** 들어간다.
    /// 세션은 대화마다 하나다 — 다른 계정의 폴더에 있는 대화의 세션은 이 실행만 이 계정의 인증으로 이어 간다 (`RunSession.send`).
    @discardableResult
    func send(prompt: String, thread: ConversationThread, project: Project,
              provider: AgentProvider, account: CodexAccountRef? = nil,
              isHandoffDelivery: Bool = false,
              handoffID: String? = nil, recordUserEvent: Bool = true,
              antigravity planned: AntigravityAdapter.TurnPlan? = nil,
              turn: AgentTurnOptions = AgentTurnOptions()) async throws -> Run {
        let session = try reserve(threadID: thread.id)
        do {
            return try await session.send(prompt: prompt, thread: thread, project: project, provider: provider,
                                          account: account, isHandoffDelivery: isHandoffDelivery, handoffID: handoffID,
                                          recordUserEvent: recordUserEvent, antigravity: planned, turn: turn)
        } catch {
            // 시작하지 못했으면 자리를 돌려준다. 이미 돌고 있으면(시작한 뒤의 오류) 끝날 때 스스로 빠진다.
            if !session.isBusy { release(session) }
            throw error
        }
    }

    // MARK: - 승인 / 질문 응답

    func respond(approval: ApprovalRequest, decision: ApprovalDecision) async {
        guard let session = session(runID: approval.runID) else {
            // 종료된 실행에 대한 늦은 응답은 적용하지 않는다.
            lastError = "이미 종료된 실행의 승인 요청이라 적용하지 않았습니다."
            return
        }
        await session.respond(approval: approval, decision: decision)
    }

    func respond(question: UserQuestion, answers: [String: String]) async {
        guard let session = session(runID: question.runID) else {
            lastError = "이미 종료된 실행의 질문이라 응답하지 않았습니다."
            return
        }
        await session.respond(question: question, answers: answers)
    }

    // MARK: - 하위 작업 멈추기

    /// 실행이 띄운 하위 작업 하나만 멈춘다. 실행 ID 로 그 세션을 찾아 간다 (승인 응답과 같은 길).
    /// 멈추기를 보냈으면 true. 끝난 실행이거나 제공자가 작업 하나 멈추기를 못 하면 false.
    @discardableResult
    func stopSubAgent(runID: String, agentID: String) async -> Bool {
        guard let session = session(runID: runID) else { return false }
        return await session.stopSubAgent(id: agentID)
    }

    @discardableResult
    func stopSubAgent(threadID: String, agentID: String) async -> Bool {
        guard let session = session(threadID: threadID) else { return false }
        return await session.stopSubAgent(id: agentID)
    }

    // MARK: - 중단

    /// 가장 최근에 시작한 활성 실행을 멈춘다 (화면이 실행 하나를 그리는 동안의 입구).
    func interrupt() async { await current?.interrupt() }
    func interrupt(threadID: String) async { await session(threadID: threadID)?.interrupt() }
    func interruptAll() async {
        for session in activeSessions { await session.interrupt() }
    }

    /// 앱 종료 시 정리. 하나라도 종료를 확인하지 못하면 false — 종료 완료로 표시하지 않는다.
    /// 세션은 정리를 마치면 목록에서 빠진다 (종료를 취소해도 끝난 실행으로 남지 않는다). 종료 미확인 프로세스는
    /// `unterminatedProcesses` 에 남아 인계 전달 · 앱의 git 쓰기를 막는다 (끝난 실행과 같은 길 — `sessionWillReport`, 보내기는 막지 않는다).
    func shutdownForQuit() async -> Bool {
        var ok = true
        // 시작할 때의 목록을 돈다 — 정리를 마친 세션은 도중에 `release` 로 빠진다.
        let sessions = entries.map(\.session)
        for session in sessions {
            let cleaned = await session.shutdownForQuit()
            if !cleaned { ok = false }
        }
        return ok
    }

    // MARK: - 인계 전송

    /// 이미 전송을 시작한 인계는 자동으로 재전송하지 않는다.
    func canSend(handoff: Handoff) -> Bool {
        handoff.deliveryState == .draft || handoff.deliveryState == .failed
    }

    @discardableResult
    func deliver(handoff: Handoff, thread: ConversationThread, project: Project,
                 toAccount: CodexAccountRef? = nil) async throws -> Run {
        // 파일을 변경하는 기존 프로세스의 종료가 불확실하면 다음 에이전트를 시작하지 않는다.
        guard unterminatedProcesses.isEmpty else {
            throw StartError.cliUnavailable(
                "종료가 확인되지 않은 프로세스가 있어 다음 에이전트를 시작하지 않습니다:\n"
                + unterminatedProcesses.joined(separator: "\n"))
        }
        let session = try reserve(threadID: thread.id)
        do {
            return try await session.deliver(handoff: handoff, thread: thread, project: project, toAccount: toAccount)
        } catch {
            // 시작하지 못했으면 자리를 돌려준다. 이미 돌고 있으면(시작한 뒤의 오류) 끝날 때 스스로 빠진다.
            if !session.isBusy { release(session) }
            throw error
        }
    }

    static func appendingNote(_ existing: String?, _ addition: String?) -> String? {
        RunSession.appendingNote(existing, addition)
    }

    /// 종료 미확인 프로세스 경고를 사용자가 확인했을 때.
    func acknowledgeUnterminated() {
        unterminatedProcesses.removeAll()
    }
}
