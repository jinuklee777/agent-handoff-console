import Foundation
import Observation

// 스케줄러의 결정을 실제로 실행하는 루프: 계획 턴 → 배정 → 실행 → 검증 → 다음 결정.
// 판단은 순수 코드(`OrchestrationScheduler` · `OrchestrationFailurePolicy` · `RoutingPolicy` · `VerificationJudge`)가 하고
// 여기서는 그 결정을 실행하고, 결과를 저장하고, 다시 묻는다. 저장에 실패하면 다음 CLI 를 시작하지 않는다.
//
// 실행 슬롯은 앱에 하나다. 계획 · 실행 턴과 사용자의 수동 실행이 그 하나를 나눠 쓴다.
// 슬롯이 차 있으면 기다렸다가 `runSlotBecameIdle` 에서 이어 간다.
// 검토 턴은 읽기 전용이라 검토 레인에서 동시에 여럿이 돈다 (검토단 — `ReviewPanel`). 구현은 한 번에 하나, 검증만 여럿이다.

/// 코디네이터가 앱에 부탁하는 일. 앱에서는 `AppModel`, 검증에서는 가짜가 맡는다.
@MainActor
protocol OrchestrationHost: AnyObject {
    /// 이 프로젝트 폴더에서 쓰기 실행을 지금 시작할 수 없다 (다른 실행 · git 쓰기 · 검토가 그 폴더를 쓰고 있다).
    func isRunSlotBusy(project: Project) -> Bool
    /// 한 턴을 시작한다. 슬롯이 차 있으면 `RunCoordinator.StartError.busy` 를 던진다.
    func orchestrationLaunch(prompt: String, thread: ConversationThread, project: Project,
                             provider: AgentProvider, codexAccountID: String?,
                             turn: AgentTurnOptions) async throws -> Run
    /// 검토 턴을 시작할 수 있다: 쓰기 실행이 돌고 있지 않고 검토 레인에 빈 자리가 있다.
    func canLaunchReview(project: Project) -> Bool
    /// 읽기 전용 검토 턴을 검토 레인에서 시작한다. 자리가 없으면 `RunCoordinator.StartError.busy` 를 던진다.
    func orchestrationLaunchReview(prompt: String, thread: ConversationThread, project: Project,
                                   provider: AgentProvider, outputSchema: String) async throws -> Run
    /// 이 실행들(자동 작업 하나의 계획 · 실행 · 검토 — 쓰기 슬롯과 검토 레인)만 멈춘다. 다른 대화의 수동 실행 · 다른 작업의 검토는 건드리지 않는다.
    func orchestrationInterrupt(runIDs: [String]) async
    /// 지금 이 프로필을 쓸 수 없는 이유. nil 이면 쓸 수 있다. 확인하지 못한 것도 이유를 돌려준다 (후보에서 뺀다).
    func orchestrationUnavailableReason(for profile: ExecutionProfile, project: Project) async -> String?
    /// 검토 담당에게 줄 작업 폴더의 변경(git)과, 검증 기록에 남길 작업 폴더 지문.
    func orchestrationWorkspaceEvidence(project: Project) async -> (text: String, fingerprint: String?)
    /// 그 작업이 일하는 폴더의 프로젝트 — 부모 대화에 독립 작업 폴더(worktree)가 있으면 그 폴더다 (id 는 프로젝트의 것).
    func orchestrationProject(for job: OrchestrationJob) async -> Project?
    func orchestrationDidChange(jobID: String)
    func orchestrationDidAppend(event: ThreadEvent)
}

protocol VerificationCommandRunning: Sendable {
    func run(command: String, in directory: URL) async -> CommandResult
}

/// 사람이 해 줘야 하는 일. 저장하지 않고 상태에서 다시 계산한다 (앱을 다시 켜도 같다).
enum OrchestrationAttention: Equatable, Sendable {
    case clarification(questions: [String])
    case planApproval
    case deliveryUnknown(attemptIDs: [String])
    case blocked(tasks: [OrchestrationTask])
    case finalVerificationFailed
    case budgetExhausted
    case planningFailed
}

enum OrchestrationError: LocalizedError {
    case disabled, anotherJobActive, notFound, invalidState(String)

    var errorDescription: String? {
        switch self {
        case .disabled: return "자동 작업이 꺼져 있습니다. 설정 > 고급 > 실험 기능에서 켠 뒤 다시 시도하세요."
        case .anotherJobActive: return "진행 중인 자동 작업이 있습니다. 끝나거나 중단한 뒤 다시 시작하세요."
        case .notFound: return "자동 작업을 찾지 못했습니다."
        case .invalidState(let m): return m
        }
    }
}

@MainActor
@Observable
final class OrchestrationCoordinator {

    private enum Flight {
        case planning(jobID: String)
        case executing(jobID: String, attemptID: String)
        case reviewing(jobID: String, attemptID: String, panel: String)
        case finalReview(jobID: String, panel: String)

        var jobID: String {
            switch self {
            case .planning(let id), .finalReview(let id, _): return id
            case .executing(let id, _), .reviewing(let id, _, _): return id
            }
        }
        var attemptID: String? {
            switch self {
            case .executing(_, let id), .reviewing(_, let id, _): return id
            default: return nil
            }
        }
    }

    /// 한 번의 검증을 맡은 검토단. 검토자마다 실행이 하나씩이고, 모두 끝나야 판정한다 (`VerificationJudge` — 한 명이라도 실패면 실패).
    private struct ReviewPanel {
        let jobID: String
        /// nil 이면 최종 통합 검증.
        let attemptID: String?
        let command: CommandResult?
        /// 검토자 이름, 보낸 순서. 기록은 이 순서로 남긴다 (끝난 순서가 아니라).
        var order: [String] = []
        /// 아직 도는 실행 ID → 검토자 이름.
        var pending: [String: String] = [:]
        var reviews: [PanelReview] = []
        /// 검토자를 보내는 중이다. 먼저 보낸 검토가 그 사이 끝나도 판정하지 않는다.
        var launching = true
    }

    private static func panelKey(jobID: String, attemptID: String?) -> String {
        attemptID.map { "attempt:" + $0 } ?? "final:" + jobID
    }

    /// 화면이 읽는 값. 부모 대화 ID → 그 대화의 가장 최근 전체 작업.
    private(set) var snapshotsByThread: [String: OrchestrationSnapshot] = [:]
    private(set) var plansByJob: [String: OrchestrationPlan] = [:]
    /// 지금 검토하고 있는 사람들 (화면용). 시도 ID → 검토자 이름. 최종 통합 검증은 `"final:" + 작업 ID`.
    private(set) var activeReviewers: [String: [String]] = [:]

    @ObservationIgnored weak var host: OrchestrationHost?
    @ObservationIgnored private let store: Store
    @ObservationIgnored private let commandRunner: VerificationCommandRunning
    /// 네트워크 재시도를 기다리는 시간의 배율. 검증에서는 0 으로 둔다.
    @ObservationIgnored var backoffScale = 1.0

    @ObservationIgnored private var flights: [String: Flight] = [:]
    @ObservationIgnored private var panels: [String: ReviewPanel] = [:]
    @ObservationIgnored private var waitingForSlot: Set<String> = []
    @ObservationIgnored private var pendingPlanning: [String: String] = [:]
    @ObservationIgnored private var planCorrections: [String: Int] = [:]
    @ObservationIgnored private var answers: [String: [String]] = [:]
    @ObservationIgnored private var commandCache: [String: CommandResult] = [:]
    /// 검증 명령을 돌리는 중인 시도 · 최종 검증 중인 작업. 그동안 다른 tick 이 같은 검증을 또 시작하지 않게 한다.
    @ObservationIgnored private var verifyingAttempts: Set<String> = []
    @ObservationIgnored private var finalVerifying: Set<String> = []
    @ObservationIgnored private var ticking: Set<String> = []
    @ObservationIgnored private var tickAgain: Set<String> = []

    init(store: Store, commandRunner: VerificationCommandRunning) {
        self.store = store
        self.commandRunner = commandRunner
    }

    // MARK: - 설정

    func currentSettings() async -> OrchestrationSettings {
        guard let text = try? await store.setting(OrchestrationSettings.storageKey),
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(OrchestrationSettings.self, from: data) else {
            return OrchestrationSettings()
        }
        return decoded
    }

    func save(_ settings: OrchestrationSettings) async {
        guard let data = try? JSONEncoder().encode(settings), let text = String(data: data, encoding: .utf8) else { return }
        try? await store.setSetting(OrchestrationSettings.storageKey, text)
    }

    // MARK: - 바깥에서 부르는 것

    /// 이 실행이 오케스트레이션의 것인지. 기존 자동 인계가 같은 실행을 또 처리하지 않게 한다.
    func owns(runID: String) -> Bool { flights[runID] != nil }

    /// 새 전체 작업을 시작한다: 사용자 요청을 부모 대화에 한 번 기록하고 계획 턴을 보낸다.
    @discardableResult
    func start(request: String, parentThread: ConversationThread, project: Project) async throws -> OrchestrationJob {
        let settings = await currentSettings()
        guard settings.enabled else { throw OrchestrationError.disabled }
        let busyStates: Set<JobState> = [.planning, .ready, .running, .cancelling]
        if try await store.unfinishedOrchestrationJobs().contains(where: { busyStates.contains($0.state) }) {
            throw OrchestrationError.anotherJobActive
        }

        // 자동 작업에 준 요청이라는 표시 — 인계 초안이 이것을 "아직 처리되지 않은 사용자 지시" 로 넘기지 않게.
        let userEvent = try await store.appendEvent(ThreadEvent(threadID: parentThread.id, runID: nil, kind: .userMessage,
                                                                provider: nil, title: "사용자", text: request,
                                                                payloadJSON: JSONUtil.line([ThreadEvent.orchestrationRequestKey: true])))
        host?.orchestrationDidAppend(event: userEvent)

        var job = OrchestrationJob(projectID: project.id, parentThreadID: parentThread.id, request: request)
        job.userRequestEventID = userEvent.id
        job.state = .planning
        job.budget = settings.budget
        job.policyVersion = RoutingPolicy.version
        try await store.insertOrchestrationJob(job)
        await refresh(job.id)
        await note(job, "자동 작업을 시작합니다. 먼저 계획을 세웁니다.")

        await launchPlanning(jobID: job.id, prompt: OrchestrationPrompts.planning(request: request, projectName: project.name))
        return job
    }

    /// 계획을 보고 시작을 눌렀다.
    func approvePlan(jobID: String) async throws {
        var job = try await requireJob(jobID)
        guard job.state == .ready else { throw OrchestrationError.invalidState("시작할 수 있는 상태가 아닙니다.") }
        try await ensureNoOtherActive(than: jobID)
        job.state = .running
        try await apply(OrchestrationChanges(cause: "사용자가 계획을 승인", job: job), jobID)
        await tick(jobID)
    }

    /// 질문에 답했다 (또는 요구를 바꿨다). 답을 넣어 다시 계획한다. 이전 계획의 대기 작업은 실행하지 않는다.
    func answer(jobID: String, text: String) async throws {
        let job = try await requireJob(jobID)
        guard [.awaitingUser, .ready, .running].contains(job.state) else {
            throw OrchestrationError.invalidState("지금은 답을 받을 수 없습니다.")
        }
        // 돌고 있는 실행은 이전 계획의 것이다. 멈추고, 도착하는 결과는 세대가 달라 버려진다.
        if !flightsEmpty(for: jobID) { await host?.orchestrationInterrupt(runIDs: flightRunIDs(for: jobID)) }
        answers[jobID, default: []].append(text)
        let event = try await store.appendEvent(ThreadEvent(threadID: job.parentThreadID, runID: nil, kind: .userMessage,
                                                            provider: nil, title: "사용자", text: text,
                                                            payloadJSON: JSONUtil.line([ThreadEvent.orchestrationRequestKey: true])))
        host?.orchestrationDidAppend(event: event)
        try await replan(job, cause: "사용자 답변으로 다시 계획", countsAsReplan: false)
    }

    func pause(jobID: String) async throws {
        var job = try await requireJob(jobID)
        guard job.state.canTransition(to: .paused) else { return }
        job.state = .paused
        try await apply(OrchestrationChanges(cause: "사용자가 일시 정지", job: job), jobID)
        await note(job, "일시 정지했습니다. 돌고 있던 실행은 끝까지 가고, 새 작업은 시작하지 않습니다.")
    }

    /// 일시 정지 · 사용자 확인 대기에서 이어 간다. 막힌 작업은 다시 시도할 수 있게 푼다.
    func resume(jobID: String) async throws {
        var job = try await requireJob(jobID)
        guard [.paused, .awaitingUser].contains(job.state) else { return }
        try await ensureNoOtherActive(than: jobID)
        guard let snapshot = try await store.orchestrationSnapshot(jobID: jobID) else { throw OrchestrationError.notFound }
        guard job.activePlanVersion > 0 else {
            throw OrchestrationError.invalidState("아직 계획이 없습니다. 요청을 더 알려 주거나 다시 계획하세요.")
        }
        var unblocked: [OrchestrationTask] = []
        for var task in snapshot.activeTasks where task.state == .blocked {
            task.state = snapshot.attempts(for: task.id).isEmpty ? .ready : .retryPending
            task.blockedReason = nil
            unblocked.append(task)
        }
        job.state = .running
        if job.finalVerification == .failed { job.finalVerification = .notStarted }
        try await apply(OrchestrationChanges(cause: "사용자가 계속", job: job, tasks: unblocked), jobID)
        await tick(jobID)
    }

    /// 전달 여부를 모르는 시도를 사람이 정리한다.
    func resolveDeliveryUnknown(jobID: String, attemptID: String, finished: Bool) async throws {
        guard let snapshot = try await store.orchestrationSnapshot(jobID: jobID),
              var attempt = snapshot.attempts.first(where: { $0.id == attemptID }), attempt.state == .deliveryUnknown,
              var task = snapshot.tasks.first(where: { $0.id == attempt.taskID }) else { throw OrchestrationError.notFound }
        var job = snapshot.job
        if finished {
            attempt.state = .verifying
            if task.state == .running { task.state = .verifying }
        } else {
            attempt.state = .failed
            attempt.failureClass = .deliveryUnknown
            attempt.endedAt = Date()
            task.state = .retryPending
        }
        if job.state.canTransition(to: .running) { job.state = .running }
        try await apply(OrchestrationChanges(cause: finished ? "사용자 확인: 실행은 끝났다" : "사용자 확인: 다시 시도",
                                             job: job, tasks: [task], attempts: [attempt]), jobID)
        await tick(jobID)
    }

    /// 검증할 수 없거나 판정이 갈린 작업을 사람이 통과로 인정한다. 사람이 인정했다는 기록을 남긴다.
    func acceptTask(jobID: String, taskID: String) async throws {
        guard let snapshot = try await store.orchestrationSnapshot(jobID: jobID),
              var task = snapshot.tasks.first(where: { $0.id == taskID }), task.state == .blocked else {
            throw OrchestrationError.notFound
        }
        task.state = .succeeded
        task.blockedReason = nil
        var job = snapshot.job
        if job.state.canTransition(to: .running) { job.state = .running }
        let record = VerificationRecord(jobID: jobID, taskID: taskID, attemptID: snapshot.attempts(for: taskID).last?.id,
                                        verifierVersion: VerificationJudge.version, criterion: "사용자 확인", outcome: .pass,
                                        evidenceJSON: JSONUtil.string(["basis": "user"]), workspaceFingerprint: nil)
        try await apply(OrchestrationChanges(cause: "사용자가 통과로 인정", job: job, tasks: [task], verifications: [record]), jobID)
        await tick(jobID)
    }

    /// 통합 검증이 실패했거나 검증할 수 없을 때 사람이 완료로 인정한다.
    func acceptFinal(jobID: String) async throws {
        var job = try await requireJob(jobID)
        job.finalVerification = .passed
        if job.state.canTransition(to: .running) { job.state = .running }
        let record = VerificationRecord(jobID: jobID, taskID: nil, attemptID: nil, verifierVersion: VerificationJudge.version,
                                        criterion: "최종 통합 검증 — 사용자 확인", outcome: .pass,
                                        evidenceJSON: JSONUtil.string(["basis": "user"]), workspaceFingerprint: nil)
        try await apply(OrchestrationChanges(cause: "사용자가 완료로 인정", job: job, verifications: [record]), jobID)
        await tick(jobID)
    }

    func extendBudget(jobID: String) async throws {
        var job = try await requireJob(jobID)
        job.budget.maxTotalAttempts += 10
        if job.state.canTransition(to: .running) { job.state = .running }
        try await apply(OrchestrationChanges(cause: "사용자가 시도 예산을 늘림", job: job), jobID)
        await tick(jobID)
    }

    func cancel(jobID: String) async throws {
        var job = try await requireJob(jobID)
        guard !job.state.isTerminal else { return }
        if job.state == .draft {
            job.state = .cancelled
            try await apply(OrchestrationChanges(cause: "사용자가 중단", job: job), jobID)
            return
        }
        guard job.state.canTransition(to: .cancelling) else { return }
        job.state = .cancelling
        job.generation += 1   // 이 뒤에 도착하는 결과는 버린다
        try await apply(OrchestrationChanges(cause: "사용자가 중단", job: job), jobID)
        waitingForSlot.remove(jobID)
        pendingPlanning[jobID] = nil
        if !flightsEmpty(for: jobID) {
            await host?.orchestrationInterrupt(runIDs: flightRunIDs(for: jobID))   // 끝났다는 통지가 오면 `finishCancel`
        } else {
            try await finishCancel(jobID)
        }
    }

    /// 실행 슬롯이 비었다. 기다리던 일을 이어 간다.
    func runSlotBecameIdle() async {
        for jobID in waitingForSlot {
            waitingForSlot.remove(jobID)
            if let prompt = pendingPlanning.removeValue(forKey: jobID) {
                await launchPlanning(jobID: jobID, prompt: prompt)
            } else {
                await tick(jobID)
            }
        }
    }

    /// 앱을 켰을 때. 끝나지 않은 작업을 자동으로 이어 돌리지 않는다 — 주인 없는 시도는 전달 여부 미확인으로 돌리고,
    /// 나머지는 일시 정지해 사람이 이어 가게 한다.
    func recoverAfterLaunch() async {
        guard let jobs = try? await store.unfinishedOrchestrationJobs() else { return }
        for var job in jobs {
            do {
                switch job.state {
                case .planning:
                    job.state = .awaitingUser
                    try await apply(OrchestrationChanges(cause: "앱이 다시 시작됨: 계획 중이던 턴의 결과를 알 수 없음", job: job), job.id)
                case .cancelling:
                    try await finishCancel(job.id)
                case .running:
                    guard let snapshot = try await store.orchestrationSnapshot(jobID: job.id) else { continue }
                    if case .recover(let ids) = OrchestrationScheduler.next(snapshot, inFlight: []) {
                        try await markDeliveryUnknown(ids, snapshot: snapshot, cause: "앱이 다시 시작됨: 실행 결과를 알 수 없음")
                    } else {
                        job.state = .paused
                        try await apply(OrchestrationChanges(cause: "앱이 다시 시작됨", job: job), job.id)
                    }
                default:
                    await refresh(job.id)
                }
            } catch {
                await refresh(job.id)
            }
        }
    }

    /// 화면용: 이 대화의 전체 작업이 사람에게 바라는 것.
    func attention(for snapshot: OrchestrationSnapshot) -> OrchestrationAttention? {
        let job = snapshot.job
        if job.state == .ready { return .planApproval }
        guard job.state == .awaitingUser else { return nil }
        guard job.activePlanVersion > 0 else {
            return flightsEmpty(for: job.id) && planCorrections[job.id] != nil ? .planningFailed : .clarification(questions: [])
        }
        if let plan = plansByJob[job.id], !plan.infoSufficient { return .clarification(questions: plan.openQuestions) }
        var probe = snapshot
        probe.job.state = .running
        switch OrchestrationScheduler.next(probe, inFlight: []) {
        case .needsUser(.deliveryUnknown(let ids)), .recover(let ids): return .deliveryUnknown(attemptIDs: ids)
        case .needsUser(.blocked(let ids)): return .blocked(tasks: snapshot.tasks.filter { ids.contains($0.id) })
        case .needsUser(.finalVerificationFailed): return .finalVerificationFailed
        case .needsUser(.budgetExhausted): return .budgetExhausted
        default: return .blocked(tasks: snapshot.activeTasks.filter { $0.state == .blocked })
        }
    }

    /// 화면용: 열려 있는 대화의 작업을 DB 에서 다시 읽는다.
    func load(parentThreadID: String) async {
        guard let job = try? await store.orchestrationJobs(parentThreadID: parentThreadID).first else {
            snapshotsByThread[parentThreadID] = nil
            return
        }
        await refresh(job.id)
    }

    // MARK: - 실행이 끝났다

    /// `RunCoordinator` 의 완료 통지를 앱이 그대로 넘긴다. 우리 것이 아니면 아무것도 하지 않는다.
    func runDidFinish(run: Run, result: AgentTurnResult) async {
        guard let flight = flights.removeValue(forKey: run.id) else { return }
        do {
            switch flight {
            case .planning(let jobID): try await planningFinished(jobID: jobID, run: run, result: result)
            case .executing(let jobID, let attemptID): try await executionFinished(jobID: jobID, attemptID: attemptID, run: run, result: result)
            case .reviewing(let jobID, _, let panel), .finalReview(let jobID, let panel):
                try await reviewFinished(jobID: jobID, panelKey: panel, run: run, result: result)
            }
        } catch {
            await fail(jobID: flight.jobID, error: error)
        }
    }

    /// 앱 종료로 끝난 실행 — 사람이 종료를 취소해 앱은 계속 돈다. 완료 통지가 오지 않았으므로 여기서 기록을 치운다.
    /// **새 일을 시작하지 않는다**: 중단 중이던 작업은 중단을 마치고, 나머지는 사람에게 넘긴다 (끊긴 실행을 보고 이어 가게).
    /// 실행은 종료를 확인했으면 취소(사용자 중단과 같게 — 작업을 막고 묻는다), 못 했으면 전달 여부 미확인이다
    /// (`RunOutcomeClassifier` · `OrchestrationFailurePolicy` — 자동으로 다시 보내지 않는다). 검토는 판정하지 않고 치우고
    /// 일시 정지한다 — 계속하면 검증부터 다시 한다. 우리 것이 아니면 아무것도 하지 않는다.
    func runEndedByQuit(run: Run) async {
        guard let flight = flights.removeValue(forKey: run.id) else { return }
        let jobID = flight.jobID
        do {
            switch flight {
            case .reviewing(_, _, let key), .finalReview(_, let key):
                if let panel = panels.removeValue(forKey: key) { activeReviewers[panel.attemptID ?? key] = nil }
            default: break
            }
            var job = try await requireJob(jobID)
            if job.state == .cancelling { return try await finishCancel(jobID) }
            switch flight {
            case .planning:
                guard job.state == .planning else { return }
                planCorrections[jobID] = planCorrections[jobID] ?? 0
                try await needUser(job, cause: "앱 종료로 계획 턴이 끊김",
                                   message: "앱 종료로 계획 턴이 끊겼습니다. 다시 계획하거나 중단하세요.")
            case .executing(_, let attemptID):
                try await executionEndedByQuit(jobID: jobID, attemptID: attemptID, run: run)
            case .reviewing, .finalReview:
                guard job.state.canTransition(to: .paused) else { return }
                job.state = .paused
                try await apply(OrchestrationChanges(cause: "앱 종료로 검토가 끊김", job: job), jobID)
                await note(job, "앱 종료로 검토가 끊겨 일시 정지했습니다. 계속하면 검증부터 다시 합니다.")
            }
        } catch {
            await fail(jobID: jobID, error: error)
        }
    }

    private func executionEndedByQuit(jobID: String, attemptID: String, run: Run) async throws {
        guard let snapshot = try await store.orchestrationSnapshot(jobID: jobID),
              var attempt = snapshot.attempts.first(where: { $0.id == attemptID }),
              var task = snapshot.tasks.first(where: { $0.id == attempt.taskID }) else { return }
        guard OrchestrationScheduler.accepts(resultFor: attempt, in: snapshot) else {
            // 재계획 뒤의 실행이었다 (결과는 어차피 버린다).
            if !attempt.state.isTerminal, attempt.state.canTransition(to: .cancelled) {
                attempt.state = .cancelled
                attempt.endedAt = Date()
                try await apply(OrchestrationChanges(cause: "앱 종료로 끝난 지난 실행", attempts: [attempt]), jobID)
            }
            return
        }
        var job = snapshot.job
        // 일시 정지한 작업은 그대로 둔다 (계속하면 스케줄러가 사람에게 묻는다).
        if job.state != .awaitingUser && job.state.canTransition(to: .awaitingUser) { job.state = .awaitingUser }
        let result = AgentTurnResult(state: run.state, terminalReason: run.terminalReason)
        if RunOutcomeClassifier.failure(of: result) == .deliveryUnknown {
            // 프로세스 종료를 확인하지 못했다 — 아직 파일을 바꾸고 있을 수 있다. 사람이 확인하기 전에는 다시 보내지 않는다.
            attempt.state = .deliveryUnknown
            try await apply(OrchestrationChanges(cause: "앱 종료: 실행의 종료를 확인하지 못함", job: job, attempts: [attempt]), jobID)
            await note(job, "앱 종료로 '\(task.title)' 실행이 끊겼고 프로세스 종료를 확인하지 못했습니다. 자동으로 다시 보내지 않습니다 — "
                       + "이 대화의 폴더를 확인한 뒤 어떻게 할지 정해 주세요.")
            return
        }
        // 종료를 확인했다: 사람이 이 실행만 멈춘 것과 같다 — 능력 실패가 아니고 전체를 실패로 만들지 않는다.
        attempt.state = .cancelled
        attempt.failureClass = .userCancelled
        attempt.endedAt = Date()
        task.state = .blocked
        task.blockedReason = "앱 종료로 실행을 중단했습니다."
        try await apply(OrchestrationChanges(cause: "앱 종료로 실행이 끊김", job: job, tasks: [task], attempts: [attempt]), jobID)
        await note(job, "앱 종료로 '\(task.title)' 실행을 중단했습니다. 이어서 하거나 전체를 중단할 수 있습니다.")
    }

    // MARK: - 계획

    private func launchPlanning(jobID: String, prompt: String) async {
        do {
            let job = try await requireJob(jobID)
            guard job.state == .planning, let host, let project = await host.orchestrationProject(for: job) else { return }
            let settings = await currentSettings()
            guard let planner = RoutingPolicy.planner(settings: settings,
                                                      unavailable: await unavailable(settings.profiles, project: project)) else {
                try await needUser(job, cause: "계획 담당으로 쓸 수 있는 프로필이 없음",
                                   message: "계획을 맡길 수 있는 프로필이 없습니다. 설정의 프로필과 CLI 상태를 확인하세요.")
                return
            }
            guard !host.isRunSlotBusy(project: project) else {
                pendingPlanning[jobID] = prompt
                waitingForSlot.insert(jobID)
                return
            }
            let thread = try await internalThread(job: job, role: "planner", title: "계획 — " + OrchestrationPrompts.clip(job.request, 40),
                                                  profile: planner, existing: nil)
            let run = try await host.orchestrationLaunch(prompt: prompt, thread: thread, project: project, provider: planner.provider,
                                                         codexAccountID: planner.codexAccountID,
                                                         turn: AgentTurnOptions(readOnly: true, outputSchema: PlanSchema.jsonString))
            flights[run.id] = .planning(jobID: jobID)
        } catch RunCoordinator.StartError.busy {
            pendingPlanning[jobID] = prompt
            waitingForSlot.insert(jobID)
        } catch {
            await fail(jobID: jobID, error: error)
        }
    }

    private func planningFinished(jobID: String, run: Run, result: AgentTurnResult) async throws {
        let job = try await requireJob(jobID)
        if job.state == .cancelling { return try await finishCancel(jobID) }
        guard job.state == .planning else { return }
        guard result.state == .completed else {
            try await needUser(job, cause: "계획 턴이 끝까지 가지 못함: \(result.state.koreanName)",
                               message: "계획을 세우지 못했습니다 (\(result.errorMessage ?? result.state.koreanName)). 다시 계획하거나 중단하세요.")
            planCorrections[jobID] = planCorrections[jobID] ?? 0
            return
        }
        switch PlanValidator.accept(result.structuredOutput) {
        case .success(let plan):
            try await install(plan, job: job, plannerRunID: run.id, settings: await currentSettings(), cause: "계획 수립")
        case .failure(let rejection):
            let used = planCorrections[jobID] ?? 0
            planCorrections[jobID] = used + 1
            if used < 1 {
                // 계획 보정 1회: 거절 사유를 같은 세션에 돌려준다.
                await launchPlanning(jobID: jobID, prompt: rejection.feedback)
            } else {
                try await needUser(job, cause: "계획을 받아들일 수 없음",
                                   message: "계획을 받아들일 수 없습니다:\n" + rejection.issues.map { "· " + $0.message }.joined(separator: "\n"))
            }
        }
    }

    private func install(_ plan: OrchestrationPlan, job: OrchestrationJob, plannerRunID: String?,
                         settings: OrchestrationSettings, cause: String) async throws {
        var job = job
        guard let snapshot = try await store.orchestrationSnapshot(jobID: job.id) else { throw OrchestrationError.notFound }
        job.activePlanVersion += 1
        job.finalVerification = .notStarted
        let tasks = OrchestrationTask.make(from: plan, jobID: job.id, planVersion: job.activePlanVersion)
        let askFirst = !plan.infoSufficient
        let autoStart = !askFirst && !settings.requiresPlanApproval
        job.state = askFirst ? .awaitingUser : .ready
        try await store.installOrchestrationPlan(
            job: job, plan: plan, tasks: tasks, plannerRunID: plannerRunID,
            supersededTaskIDs: OrchestrationScheduler.supersededByReplan(snapshot, newPlanVersion: job.activePlanVersion),
            cause: cause)
        planCorrections[job.id] = nil
        await refresh(job.id)
        if askFirst {
            await note(job, "시작하기 전에 확인이 필요합니다:\n" + plan.openQuestions.map { "· " + $0 }.joined(separator: "\n"))
        } else {
            await note(job, "계획을 세웠습니다 — 작업 \(plan.tasks.count)개:\n"
                       + plan.tasks.enumerated().map { "\($0 + 1). \($1.title)" }.joined(separator: "\n"))
        }
        if autoStart {
            job.state = .running
            try await apply(OrchestrationChanges(cause: "계획 승인 없이 시작 (설정)", job: job), job.id)
            await tick(job.id)
        }
    }

    private func replan(_ job: OrchestrationJob, cause: String, countsAsReplan: Bool, defect: String? = nil) async throws {
        var job = job
        guard job.state.canTransition(to: .planning) else {
            throw OrchestrationError.invalidState("지금은 다시 계획할 수 없습니다.")
        }
        try await ensureNoOtherActive(than: job.id)
        job.state = .planning
        job.generation += 1
        if countsAsReplan { job.replanCount += 1 }
        try await apply(OrchestrationChanges(cause: cause, job: job), job.id)
        guard let project = await host?.orchestrationProject(for: job) else { return }
        var prompt = OrchestrationPrompts.planning(request: job.request, projectName: project.name, answers: answers[job.id] ?? [])
        if let defect { prompt += "\n\n앞선 계획은 실행 중 다음 문제로 막혔습니다. 이 점을 고친 계획을 주세요:\n" + defect }
        await note(job, "다시 계획합니다.")
        await launchPlanning(jobID: job.id, prompt: prompt)
    }

    /// 사용자가 "다시 계획"을 눌렀다.
    func replan(jobID: String) async throws {
        try await replan(try await requireJob(jobID), cause: "사용자가 다시 계획", countsAsReplan: false)
    }

    // MARK: - 루프

    private func tick(_ jobID: String) async {
        guard ticking.insert(jobID).inserted else { tickAgain.insert(jobID); return }
        defer {
            ticking.remove(jobID)
            if tickAgain.remove(jobID) != nil { Task { await self.tick(jobID) } }
        }
        do {
            for _ in 0..<40 {
                guard let snapshot = try await store.orchestrationSnapshot(jobID: jobID) else { return }
                if finalVerifying.contains(jobID) || panels[Self.panelKey(jobID: jobID, attemptID: nil)] != nil { return }
                let owned = Set(flights.values.filter { $0.jobID == jobID }.compactMap(\.attemptID)).union(verifyingAttempts)
                switch OrchestrationScheduler.next(snapshot, inFlight: owned) {
                case .idle:
                    return
                case .needsUser(let need):
                    try await needUser(snapshot.job, cause: "사용자 확인 필요: \(need)", message: message(for: need, snapshot))
                    return
                case .recover(let ids):
                    try await markDeliveryUnknown(ids, snapshot: snapshot, cause: "주인 없는 실행: 결과를 알 수 없음")
                    return
                case .verify(let attemptID):
                    try await startVerification(jobID: jobID, attemptID: attemptID)
                    return
                case .markUnreachable(let ids):
                    let tasks = snapshot.tasks.filter { ids.contains($0.id) }.map { task -> OrchestrationTask in
                        var t = task; t.state = .cancelled; t.blockedReason = "선행 작업이 통과하지 못함"; return t
                    }
                    try await apply(OrchestrationChanges(cause: "선행 작업이 통과하지 못해 시작할 수 없는 선택 작업", tasks: tasks), jobID)
                case .dispatch(let plan):
                    if try await dispatch(plan, snapshot: snapshot) == false { return }
                case .runFinalVerification:
                    try await startFinalVerification(snapshot)
                    return
                case .complete:
                    var job = snapshot.job
                    job.state = .completed
                    try await apply(OrchestrationChanges(cause: "모든 필수 작업과 최종 통합 검증 통과", job: job), jobID)
                    await note(job, "완료했습니다. 모든 필수 작업과 최종 통합 검증을 통과했습니다.")
                    return
                case .fail(.requiredTaskFailed(let taskID)):
                    var job = snapshot.job
                    job.state = .failed
                    try await apply(OrchestrationChanges(cause: "필수 작업 실패", job: job), jobID)
                    let title = snapshot.tasks.first { $0.id == taskID }?.title ?? taskID
                    await note(job, "필수 작업이 끝내 통과하지 못해 전체 작업을 실패로 마칩니다: '\(title)'. 바뀐 파일은 이 대화의 폴더에 그대로 남아 있습니다.")
                    return
                }
            }
        } catch {
            await fail(jobID: jobID, error: error)
        }
    }

    /// - Returns: 루프를 계속 돌려도 되면 true. 실행을 보냈거나 슬롯을 기다리면 false.
    private func dispatch(_ plan: DispatchPlan, snapshot: OrchestrationSnapshot) async throws -> Bool {
        let job = snapshot.job
        guard let host, let project = await host.orchestrationProject(for: job),
              var task = snapshot.tasks.first(where: { $0.id == plan.taskID }) else { throw OrchestrationError.notFound }
        guard !host.isRunSlotBusy(project: project) else { waitingForSlot.insert(job.id); return false }

        let settings = await currentSettings()
        let previous = snapshot.attempts(for: task.id)
        let lastTier = previous.last.flatMap { last in settings.profiles.first { $0.id == last.profileID }?.tier }
        let outcome = RoutingPolicy.choose(kind: task.kind, difficulty: task.difficulty, plan: plan, lastTier: lastTier,
                                           profiles: settings.profiles,
                                           unavailable: await unavailable(settings.profiles, project: project))
        let decision = RoutingDecisionRecord(
            jobID: job.id, taskID: task.id, featureSource: .planner, featureVersion: "plan-\(PlanSchema.version)",
            inputHash: "\(task.kind.rawValue):\(task.difficulty):\(plan.kind.rawValue)", inputSummary: task.title,
            featuresJSON: JSONUtil.string(["kind": task.kind.rawValue, "difficulty": task.difficulty, "attempt": plan.kind.rawValue]),
            candidatesJSON: Self.json(outcome.candidates), selectedProfile: outcome.selected?.id,
            reasonCodesJSON: Self.json(outcome.reasonCodes), policyVersion: RoutingPolicy.version)

        if task.state == .pending {   // pending → ready → routing (한 번에 한 칸)
            task.state = .ready
            try await apply(OrchestrationChanges(cause: "선행 작업 통과", tasks: [task]), job.id)
        }
        guard let profile = outcome.selected else {
            let reasons = outcome.candidates.compactMap { c in c.excluded.map { "\(c.profileID): \($0)" } }.joined(separator: " / ")
            if task.state != .routing { task.state = .routing; try await apply(OrchestrationChanges(cause: "담당 정하는 중", tasks: [task]), job.id) }
            task.state = .blocked
            task.blockedReason = "맡길 수 있는 프로필이 없습니다 — " + reasons
            try await apply(OrchestrationChanges(cause: "배정할 후보 없음", tasks: [task], routingDecisions: [decision]), job.id)
            return true
        }

        task.state = .routing
        let thread = try await internalThread(job: job, role: "task", title: task.title, profile: profile, existing: task.childThreadID)
        task.childThreadID = thread.id
        var attempt = OrchestrationAttempt(taskID: task.id, jobID: job.id, number: plan.attemptNumber, kind: plan.kind,
                                           profileID: profile.id, generation: job.generation)
        attempt.routingDecisionID = decision.id
        attempt.state = .dispatching
        // 보내기 전에 저장한다. 같은 (작업, 번호)는 두 번 만들 수 없다.
        try await apply(OrchestrationChanges(cause: "배정: \(profile.name)", tasks: [task], newAttempts: [attempt],
                                             routingDecisions: [decision]), job.id)

        let goal = plansByJob[job.id]?.goal ?? job.request
        let byPlanID = Dictionary(snapshot.activeTasks.map { ($0.planTaskID, $0) }, uniquingKeysWith: { first, _ in first })
        let dependencies: [(title: String, summary: String)] = task.dependsOn.compactMap { id in
            guard let dependency = byPlanID[id] else { return nil }
            let summary = snapshot.attempts(for: dependency.id).last { $0.state == .succeeded }?.resultSummary ?? "(요약 없음)"
            return (dependency.title, OrchestrationPrompts.clip(summary, 1_200))
        }
        let sameSession = plan.kind == .retry && previous.last?.profileID == profile.id
        let prompt = OrchestrationPrompts.task(goal: goal, task: task, dependencies: dependencies,
                                               failure: previous.last?.resultSummary.map { OrchestrationPrompts.clip($0, 4_000) },
                                               continuesSession: sameSession)
        do {
            let run = try await host.orchestrationLaunch(prompt: prompt, thread: thread, project: project,
                                                         provider: profile.provider, codexAccountID: profile.codexAccountID,
                                                         turn: AgentTurnOptions())
            flights[run.id] = .executing(jobID: job.id, attemptID: attempt.id)
            attempt.runID = run.id
            attempt.state = .running
            task.state = .running
            try await apply(OrchestrationChanges(cause: "실행 시작", tasks: [task], attempts: [attempt]), job.id)
            let position = (snapshot.activeTasks.firstIndex { $0.id == task.id } ?? 0) + 1
            await note(job, "작업 \(position)/\(snapshot.activeTasks.count) '\(task.title)' — \(profile.name)"
                       + (plan.kind == .first ? "" : " (\(Self.name(of: plan.kind)) · \(plan.attemptNumber)번째 시도)"))
            return false
        } catch RunCoordinator.StartError.busy {
            // 그 사이 슬롯을 빼앗겼다. 보낸 것이 없으니 시도를 접고 기다린다.
            attempt.state = .cancelled
            attempt.endedAt = Date()
            task.state = .ready
            try await apply(OrchestrationChanges(cause: "실행 슬롯이 차 있어 보내지 않음", tasks: [task], attempts: [attempt]), job.id)
            waitingForSlot.insert(job.id)
            return false
        } catch {
            attempt.state = .failed
            attempt.failureClass = .environment
            attempt.resultSummary = error.localizedDescription
            attempt.endedAt = Date()
            try await settle(failure: .environment, attempt: attempt, task: task, snapshot: snapshot,
                             verifications: [], reason: error.localizedDescription)
            return true
        }
    }

    // MARK: - 실행 결과

    private func executionFinished(jobID: String, attemptID: String, run: Run, result: AgentTurnResult) async throws {
        guard let snapshot = try await store.orchestrationSnapshot(jobID: jobID),
              var attempt = snapshot.attempts.first(where: { $0.id == attemptID }),
              var task = snapshot.tasks.first(where: { $0.id == attempt.taskID }) else { return }
        let job = snapshot.job

        guard OrchestrationScheduler.accepts(resultFor: attempt, in: snapshot) else {
            // 중단 · 재계획 뒤에 도착했다. 취소한 계획을 되살리지 않는다.
            if !attempt.state.isTerminal, attempt.state.canTransition(to: .cancelled) {
                attempt.state = .cancelled
                attempt.endedAt = Date()
                try await apply(OrchestrationChanges(cause: "늦게 도착한 결과를 버림", attempts: [attempt]), jobID)
            }
            if job.state == .cancelling { try await finishCancel(jobID) }
            return
        }

        let said = try await lastAgentMessage(run: run) ?? result.resultText
        guard let failure = RunOutcomeClassifier.failure(of: result) else {
            attempt.state = .verifying
            attempt.resultSummary = said
            task.state = .verifying
            try await apply(OrchestrationChanges(cause: "실행 종료 · 검증 시작", tasks: [task], attempts: [attempt]), jobID)
            try await startVerification(jobID: jobID, attemptID: attemptID)
            return
        }

        attempt.endedAt = Date()
        if failure == .userCancelled {
            // 사람이 이 실행만 멈췄다. 능력 실패가 아니다 — 전체를 실패로 만들지 않고 물어본다.
            attempt.state = .cancelled
            attempt.failureClass = .userCancelled
            task.state = .blocked
            task.blockedReason = "실행을 중단했습니다."
            var paused = job
            paused.state = .awaitingUser
            try await apply(OrchestrationChanges(cause: "사용자가 실행을 중단", job: paused, tasks: [task], attempts: [attempt]), jobID)
            await note(job, "'\(task.title)' 실행을 중단했습니다. 이어서 하거나 전체를 중단할 수 있습니다.")
            return
        }
        attempt.state = .failed
        attempt.failureClass = failure
        attempt.resultSummary = result.errorMessage ?? said
        try await settle(failure: failure, attempt: attempt, task: task, snapshot: snapshot, verifications: [],
                         reason: result.errorMessage ?? result.state.koreanName)
        await tick(jobID)
    }

    /// 실패한 시도를 저장하고 정책이 정한 다음 상태로 옮긴다.
    private func settle(failure: FailureClass, attempt: OrchestrationAttempt, task: OrchestrationTask,
                        snapshot: OrchestrationSnapshot, verifications: [VerificationRecord], reason: String) async throws {
        var task = task
        let job = snapshot.job
        var attempts = snapshot.attempts(for: task.id).filter { $0.id != attempt.id }
        attempts.append(attempt)
        attempts.sort { $0.number < $1.number }

        let settings = await currentSettings()
        let project = await host?.orchestrationProject(for: job)
        let unavailable = project == nil ? [:] : await unavailable(settings.profiles, project: project!)
        let probe = DispatchPlan(taskID: task.id, attemptNumber: attempt.number + 1,
                                 kind: failure == .limitReached ? .availabilitySwitch : .escalation, reuseProfileID: nil,
                                 excludedProfileIDs: OrchestrationFailurePolicy.visitedProfiles(attempts))
        let lastTier = settings.profiles.first { $0.id == attempt.profileID }?.tier
        let nextAvailable = RoutingPolicy.choose(kind: task.kind, difficulty: task.difficulty, plan: probe, lastTier: lastTier,
                                                 profiles: settings.profiles, unavailable: unavailable).selected != nil
        let decision = OrchestrationFailurePolicy.decide(after: failure, attempts: attempts, job: job,
                                                         nextProfileAvailable: nextAvailable)
        let cause = "\(Self.name(of: failure)) → \(Self.name(of: decision))"

        if decision == .replan {
            task.state = .blocked
            task.blockedReason = "계획 결함: " + OrchestrationPrompts.clip(reason, 300)
            try await apply(OrchestrationChanges(cause: cause, tasks: [task], attempts: [attempt], verifications: verifications), job.id)
            await note(job, "'\(task.title)' 에서 계획의 문제가 드러났습니다. 다시 계획합니다.")
            try await replan(try await requireJob(job.id), cause: "계획 결함으로 재계획", countsAsReplan: true, defect: reason)
            return
        }
        task.state = OrchestrationFailurePolicy.taskState(for: decision) ?? .blocked
        task.blockedReason = task.state == .blocked ? "\(Self.name(of: failure)): " + OrchestrationPrompts.clip(reason, 300) : nil
        try await apply(OrchestrationChanges(cause: cause, tasks: [task], attempts: [attempt], verifications: verifications), job.id)
        await note(job, "'\(task.title)' — \(Self.name(of: failure)). 다음: \(Self.name(of: decision)).")

        if case .retryAfterBackoff(let seconds) = decision, backoffScale > 0 {
            waitingForSlot.remove(job.id)
            let jobID = job.id
            let delay = UInt64(Double(seconds) * backoffScale * 1_000_000_000)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                await self?.tick(jobID)
            }
            throw BackoffScheduled()
        }
    }

    private struct BackoffScheduled: Error {}

    // MARK: - 검증

    private func startVerification(jobID: String, attemptID: String) async throws {
        guard let snapshot = try await store.orchestrationSnapshot(jobID: jobID),
              let attempt = snapshot.attempts.first(where: { $0.id == attemptID }),
              let task = snapshot.tasks.first(where: { $0.id == attempt.taskID }),
              let host, let project = await host.orchestrationProject(for: snapshot.job) else { return }
        let settings = await currentSettings()
        guard verifyingAttempts.insert(attemptID).inserted else { return }
        defer { verifyingAttempts.remove(attemptID) }

        var command = commandCache[attemptID]
        let changesFiles = ![TaskKind.explain, .review, .research].contains(task.kind)
        if command == nil, changesFiles, let line = settings.verificationCommands[project.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !line.isEmpty {
            command = await commandRunner.run(command: line, in: project.url)
            commandCache[attemptID] = command
        }
        // 명령이 이미 실패했으면 객관적 실패다. 검토 턴을 쓰지 않는다.
        let wantsReview = settings.reviewMode == .always || (settings.reviewMode == .whenNoCommand && command == nil)
        let reviewers = wantsReview && command.map({ $0.exitCode == 0 }) != false
            ? RoutingPolicy.reviewers(settings: settings, executorProfileID: attempt.profileID, difficulty: task.difficulty,
                                      unavailable: await unavailable(settings.profiles, project: project))
            : []
        guard !reviewers.isEmpty else {
            let evidence = await host.orchestrationWorkspaceEvidence(project: project)
            try await conclude(jobID: jobID, attemptID: attemptID, command: command, reviews: [], fingerprint: evidence.fingerprint)
            return
        }
        let key = Self.panelKey(jobID: jobID, attemptID: attemptID)
        guard panels[key] == nil else { return }   // 이미 검토단이 돌고 있다
        guard host.canLaunchReview(project: project) else { waitingForSlot.insert(jobID); return }

        let evidence = await host.orchestrationWorkspaceEvidence(project: project)
        let prompt = OrchestrationPrompts.review(goal: plansByJob[jobID]?.goal ?? snapshot.job.request, title: task.title,
                                                 specification: task.specification, criteria: task.acceptance,
                                                 executorSummary: attempt.resultSummary.map(SecretMasker.mask),
                                                 workspaceEvidence: SecretMasker.mask(evidence.text), command: command)
        switch await launchPanel(key: key, job: snapshot.job, attemptID: attemptID, command: command, reviewers: reviewers,
                                 prompt: prompt, project: project, host: host) {
        case .waiting: waitingForSlot.insert(jobID)
        case .launched(let names):
            if names.count > 1 { await note(snapshot.job, "검토단(\(names.joined(separator: " · ")))이 함께 검토합니다: '\(task.title)'") }
        case .failed(let reviews):
            // 검토를 돌리지 못했다. 판정 불가로 남긴다 (통과로 치지 않는다).
            try await conclude(jobID: jobID, attemptID: attemptID, command: command, reviews: reviews, fingerprint: evidence.fingerprint)
        }
    }

    private enum PanelLaunch {
        /// 검토 레인에 자리가 없어 아무도 보내지 못했다.
        case waiting
        case launched(reviewers: [String])
        /// 아무도 보내지 못했다 (자리 문제가 아님).
        case failed(reviews: [PanelReview])
    }

    /// 검토자마다 자기 내부 대화에서 같은 글로 검토 턴을 보낸다. 둘째부터는 자리가 없으면 보낸 사람만으로 판정한다.
    private func launchPanel(key: String, job: OrchestrationJob, attemptID: String?, command: CommandResult?,
                             reviewers: [ExecutionProfile], prompt: String, project: Project,
                             host: OrchestrationHost) async -> PanelLaunch {
        panels[key] = ReviewPanel(jobID: job.id, attemptID: attemptID, command: command)
        var launched: [String] = []
        for reviewer in reviewers {
            do {
                let thread = try await internalThread(job: job, role: "reviewer",
                                                      title: "검토 · \(reviewer.name) — " + OrchestrationPrompts.clip(job.request, 40),
                                                      profile: reviewer, existing: nil)
                let run = try await host.orchestrationLaunchReview(prompt: prompt, thread: thread, project: project,
                                                                   provider: reviewer.provider, outputSchema: ReviewSchema.jsonString)
                flights[run.id] = attemptID.map { .reviewing(jobID: job.id, attemptID: $0, panel: key) }
                    ?? .finalReview(jobID: job.id, panel: key)
                panels[key]?.pending[run.id] = reviewer.name
                panels[key]?.order.append(reviewer.name)
                launched.append(reviewer.name)
            } catch RunCoordinator.StartError.busy {
                break
            } catch {
                panels[key]?.reviews.append(PanelReview(reviewer: reviewer.name, verdict: nil))
                panels[key]?.order.append(reviewer.name)
            }
        }
        guard !launched.isEmpty else {
            let reviews = panels.removeValue(forKey: key)?.reviews ?? []
            return reviews.isEmpty ? .waiting : .failed(reviews: reviews)
        }
        panels[key]?.launching = false
        activeReviewers[attemptID ?? key] = launched
        // 보내는 사이 먼저 보낸 검토가 다 끝났을 수 있다.
        if panels[key]?.pending.isEmpty == true { try? await finishPanel(key) }
        return .launched(reviewers: launched)
    }

    /// 검토단의 한 사람이 끝났다. 모두 끝나면 판정한다.
    private func reviewFinished(jobID: String, panelKey: String, run: Run, result: AgentTurnResult) async throws {
        let job = try await requireJob(jobID)
        let name = panels[panelKey]?.pending.removeValue(forKey: run.id)
        if job.state == .cancelling {
            if panels[panelKey]?.pending.isEmpty != false {
                if let panel = panels.removeValue(forKey: panelKey) { activeReviewers[panel.attemptID ?? panelKey] = nil }
            }
            return try await finishCancel(jobID)
        }
        guard let name, panels[panelKey] != nil else { return }   // 이미 치운 검토단의 늦은 결과
        let verdict = result.state == .completed ? ReviewVerdict.decode(result.structuredOutput) : nil
        panels[panelKey]?.reviews.append(PanelReview(reviewer: name, verdict: verdict))
        if panels[panelKey]?.launching == false, panels[panelKey]?.pending.isEmpty == true { try await finishPanel(panelKey) }
    }

    private func finishPanel(_ key: String) async throws {
        guard let panel = panels.removeValue(forKey: key) else { return }
        activeReviewers[panel.attemptID ?? key] = nil
        let reviews = panel.reviews.sorted {
            (panel.order.firstIndex(of: $0.reviewer ?? "") ?? 0) < (panel.order.firstIndex(of: $1.reviewer ?? "") ?? 0)
        }
        guard let attemptID = panel.attemptID else {
            return try await concludeFinal(jobID: panel.jobID, command: panel.command, reviews: reviews)
        }
        var fingerprint: String?
        if let job = try? await requireJob(panel.jobID), let project = await host?.orchestrationProject(for: job) {
            fingerprint = await host?.orchestrationWorkspaceEvidence(project: project).fingerprint
        }
        try await conclude(jobID: panel.jobID, attemptID: attemptID, command: panel.command, reviews: reviews, fingerprint: fingerprint)
    }

    private func conclude(jobID: String, attemptID: String, command: CommandResult?, reviews: [PanelReview],
                          fingerprint: String?) async throws {
        guard let snapshot = try await store.orchestrationSnapshot(jobID: jobID),
              var attempt = snapshot.attempts.first(where: { $0.id == attemptID }), attempt.state == .verifying,
              var task = snapshot.tasks.first(where: { $0.id == attempt.taskID }) else { return }
        commandCache[attemptID] = nil
        let verdict = VerificationJudge.judge(jobID: jobID, taskID: task.id, attemptID: attemptID, criteria: task.acceptance,
                                              command: command, reviews: reviews, workspaceFingerprint: fingerprint)
        attempt.endedAt = Date()
        switch verdict.outcome {
        case .pass:
            attempt.state = .succeeded
            attempt.resultSummary = [attempt.resultSummary, "검증: " + verdict.summary].compactMap { $0 }.joined(separator: "\n")
            task.state = .succeeded
            try await apply(OrchestrationChanges(cause: "검증 통과 (\(verdict.basis.rawValue))", tasks: [task], attempts: [attempt],
                                                 verifications: verdict.records), jobID)
            await note(snapshot.job, "'\(task.title)' 검증 통과.")
        case .fail:
            attempt.state = .failed
            attempt.failureClass = verdict.failure ?? .verificationFailed
            attempt.failureFingerprint = verdict.fingerprint
            attempt.resultSummary = verdict.feedback
            do {
                try await settle(failure: attempt.failureClass!, attempt: attempt, task: task, snapshot: snapshot,
                                 verifications: verdict.records, reason: verdict.feedback)
            } catch is BackoffScheduled { return }
        case .inconclusive, .unavailable:
            // 통과로 치지 않는다. 사람이 보고 인정하거나 다시 시킨다.
            attempt.state = .failed
            attempt.resultSummary = [attempt.resultSummary, "검증: " + verdict.summary].compactMap { $0 }.joined(separator: "\n")
            task.state = .blocked
            task.blockedReason = verdict.outcome == .unavailable
                ? "검증 수단이 없습니다 (검증 명령도 검토 담당도 없음). 직접 확인해 주세요."
                : "검증 결과를 판정할 수 없습니다: " + OrchestrationPrompts.clip(verdict.summary, 300)
            try await apply(OrchestrationChanges(cause: "검증 \(verdict.outcome.rawValue)", tasks: [task], attempts: [attempt],
                                                 verifications: verdict.records), jobID)
        }
        await tick(jobID)
    }

    private func startFinalVerification(_ snapshot: OrchestrationSnapshot) async throws {
        let job = snapshot.job
        guard let host, let project = await host.orchestrationProject(for: job) else { return }
        let settings = await currentSettings()
        guard finalVerifying.insert(job.id).inserted else { return }
        defer { finalVerifying.remove(job.id) }
        var command = commandCache["final:" + job.id]
        if command == nil, let line = settings.verificationCommands[project.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
            command = await commandRunner.run(command: line, in: project.url)
            commandCache["final:" + job.id] = command
        }
        let wantsReview = settings.reviewMode != .never && command.map({ $0.exitCode == 0 }) != false
        let reviewers = wantsReview ? RoutingPolicy.reviewers(settings: settings, executorProfileID: nil, difficulty: nil,
                                                             unavailable: await unavailable(settings.profiles, project: project)) : []
        guard !reviewers.isEmpty else {
            try await concludeFinal(jobID: job.id, command: command, reviews: [])
            return
        }
        let key = Self.panelKey(jobID: job.id, attemptID: nil)
        guard panels[key] == nil else { return }
        guard host.canLaunchReview(project: project) else { waitingForSlot.insert(job.id); return }
        let plan = plansByJob[job.id]
        let done = snapshot.activeTasks.map { task in
            "- [\(task.state.koreanName)] \(task.title): "
                + OrchestrationPrompts.clip(snapshot.attempts(for: task.id).last?.resultSummary ?? "", 400)
        }.joined(separator: "\n")
        let evidence = await host.orchestrationWorkspaceEvidence(project: project)
        let prompt = OrchestrationPrompts.review(goal: plan?.goal ?? job.request, title: "전체 목표의 최종 통합 검증",
                                                 specification: "하위 작업의 결과:\n" + done,
                                                 criteria: plan?.finalAcceptance ?? ["요청한 내용이 충족되었다"],
                                                 executorSummary: nil, workspaceEvidence: SecretMasker.mask(evidence.text), command: command)
        switch await launchPanel(key: key, job: job, attemptID: nil, command: command, reviewers: reviewers,
                                 prompt: prompt, project: project, host: host) {
        case .waiting: waitingForSlot.insert(job.id)
        case .launched(let names):
            await note(job, names.count > 1
                       ? "하위 작업이 모두 끝났습니다. 검토단(\(names.joined(separator: " · ")))이 최종 통합 검증을 합니다."
                       : "하위 작업이 모두 끝났습니다. 최종 통합 검증을 합니다.")
        case .failed(let reviews):
            try await concludeFinal(jobID: job.id, command: command, reviews: reviews)
        }
    }

    private func concludeFinal(jobID: String, command: CommandResult?, reviews: [PanelReview]) async throws {
        var job = try await requireJob(jobID)
        guard job.state == .running || job.state == .paused else { return }
        commandCache["final:" + jobID] = nil
        let verdict = VerificationJudge.judge(jobID: jobID, taskID: nil, attemptID: nil,
                                              criteria: plansByJob[jobID]?.finalAcceptance ?? ["요청한 내용이 충족되었다"],
                                              command: command, reviews: reviews, workspaceFingerprint: nil)
        job.finalVerification = verdict.outcome == .pass ? .passed : .failed
        try await apply(OrchestrationChanges(cause: "최종 통합 검증 \(verdict.outcome.rawValue)", job: job,
                                             verifications: verdict.records), jobID)
        if verdict.outcome != .pass {
            await note(job, "최종 통합 검증을 통과하지 못했습니다 (\(verdict.outcome.rawValue)). 완료로 표시하지 않습니다.\n"
                       + OrchestrationPrompts.clip(verdict.feedback.isEmpty ? verdict.summary : verdict.feedback, 800))
        }
        await tick(jobID)
    }

    // MARK: - 중단 · 복구

    private func finishCancel(_ jobID: String) async throws {
        guard let snapshot = try await store.orchestrationSnapshot(jobID: jobID) else { return }
        var job = snapshot.job
        guard job.state == .cancelling else { return }
        guard flightsEmpty(for: jobID) else { return }   // 아직 도는 실행이 있다. 그 통지에서 다시 온다.
        let tasks = snapshot.tasks.filter { !$0.state.isTerminal }.map { task -> OrchestrationTask in
            var t = task; t.state = .cancelled; return t
        }
        let attempts = snapshot.attempts.filter { !$0.state.isTerminal }.map { attempt -> OrchestrationAttempt in
            var a = attempt; a.state = .cancelled; a.failureClass = .userCancelled; a.endedAt = Date(); return a
        }
        job.state = .cancelled
        try await apply(OrchestrationChanges(cause: "중단 완료", job: job, tasks: tasks, attempts: attempts), jobID)
        await note(job, "중단했습니다. 바뀐 파일은 이 대화의 폴더에 그대로 남아 있습니다.")
    }

    private func markDeliveryUnknown(_ attemptIDs: [String], snapshot: OrchestrationSnapshot, cause: String) async throws {
        var job = snapshot.job
        let attempts = snapshot.attempts.filter { attemptIDs.contains($0.id) }.map { attempt -> OrchestrationAttempt in
            var a = attempt; a.state = .deliveryUnknown; return a
        }
        job.state = .awaitingUser
        try await apply(OrchestrationChanges(cause: cause, job: job, attempts: attempts), job.id)
        await note(job, "실행 결과를 확인할 수 없는 작업이 있습니다. 자동으로 다시 보내지 않습니다 — 이 대화의 폴더를 확인한 뒤 어떻게 할지 정해 주세요.")
    }

    private func needUser(_ job: OrchestrationJob, cause: String, message: String) async throws {
        var job = job
        guard job.state != .awaitingUser else { return }
        guard job.state.canTransition(to: .awaitingUser) else { return }
        job.state = .awaitingUser
        try await apply(OrchestrationChanges(cause: cause, job: job), job.id)
        await note(job, message)
    }

    private func fail(jobID: String, error: Error) async {
        if error is BackoffScheduled { return }
        guard var job = try? await store.orchestrationJob(id: jobID) else { return }
        // 저장이나 실행에서 예상하지 못한 오류가 났다. 다음 CLI 를 시작하지 않고 사람에게 넘긴다.
        if job.state.canTransition(to: .awaitingUser) {
            job.state = .awaitingUser
            try? await store.applyOrchestration(OrchestrationChanges(cause: "오류: \(error.localizedDescription)", job: job), jobID: jobID)
        }
        await refresh(jobID)
        await note(job, "자동 작업을 멈췄습니다: \(error.localizedDescription)")
    }

    // MARK: - 도우미

    private func requireJob(_ id: String) async throws -> OrchestrationJob {
        guard let job = try await store.orchestrationJob(id: id) else { throw OrchestrationError.notFound }
        return job
    }

    private func ensureNoOtherActive(than jobID: String) async throws {
        let busy: Set<JobState> = [.planning, .running, .cancelling]
        if try await store.unfinishedOrchestrationJobs().contains(where: { $0.id != jobID && busy.contains($0.state) }) {
            throw OrchestrationError.anotherJobActive
        }
    }

    private func flightsEmpty(for jobID: String) -> Bool { !flights.values.contains { $0.jobID == jobID } }
    /// 이 작업이 돌리는 실행들의 ID (멈출 때 — "가장 최근 실행" 이 아니라 이 작업의 것만).
    private func flightRunIDs(for jobID: String) -> [String] { flights.filter { $0.value.jobID == jobID }.map(\.key) }

    private func apply(_ changes: OrchestrationChanges, _ jobID: String) async throws {
        try await store.applyOrchestration(changes, jobID: jobID)
        await refresh(jobID)
    }

    private func refresh(_ jobID: String) async {
        guard let snapshot = try? await store.orchestrationSnapshot(jobID: jobID) else { return }
        if snapshot.job.activePlanVersion > 0,
           let plan = try? await store.orchestrationPlan(jobID: jobID, version: snapshot.job.activePlanVersion) {
            plansByJob[jobID] = plan
        }
        snapshotsByThread[snapshot.job.parentThreadID] = snapshot
        host?.orchestrationDidChange(jobID: jobID)
    }

    private func unavailable(_ profiles: [ExecutionProfile], project: Project) async -> [String: String] {
        var reasons: [String: String] = [:]
        for profile in profiles where profile.enabled {
            if let reason = await host?.orchestrationUnavailableReason(for: profile, project: project) { reasons[profile.id] = reason }
        }
        return reasons
    }

    /// 계획 · 검토 · 하위 작업의 내부 대화. 프로필의 모델 · 강도 · 계정을 그 대화의 선택으로 적는다 (실행은 그 값을 쓴다).
    private func internalThread(job: OrchestrationJob, role: String, title: String, profile: ExecutionProfile,
                                existing: String?) async throws -> ConversationThread {
        let threads = try await store.orchestrationThreads(jobID: job.id)
        var thread = threads.first { $0.id == existing }
            ?? (role == "task" ? nil : threads.first {
                // 검토 담당은 제공자마다 대화가 따로다 — 검토단의 둘이 동시에 돌고, 한 대화에는 실행이 하나다.
                $0.orchestrationRole == role && (role != "reviewer" || $0.preferredProvider == profile.provider)
            })
            ?? ConversationThread(projectID: job.projectID, title: title)
        thread.orchestrationJobID = job.id
        thread.orchestrationRole = role
        thread.preferredProvider = profile.provider
        let selection = ModelSelection(model: profile.model, effort: profile.effort)
        switch profile.provider {
        case .claude: thread.claudeSelection = selection
        case .codex:
            thread.codexSelection = selection
            if let account = profile.codexAccountID { thread.codexAccountID = account }
        case .gemini: thread.geminiSelection = selection
        }
        thread.updatedAt = Date()
        try await store.upsertThread(thread)
        return thread
    }

    /// 그 실행의 마지막 **메인** 응답. 하위 에이전트의 글(부모 표시가 붙은 것)은 실행자의 말이 아니다.
    private func lastAgentMessage(run: Run) async throws -> String? {
        try await store.events(threadID: run.threadID).last {
            $0.runID == run.id && $0.kind == .agentMessage && $0.parentAgentID == nil
        }?.text
    }

    /// 진행 상황을 부모 대화에 한 줄 남긴다. 화면의 작업 카드와 별개로 읽을 수 있는 기록이다.
    private func note(_ job: OrchestrationJob, _ text: String) async {
        let event = ThreadEvent(threadID: job.parentThreadID, runID: nil, kind: .systemNotice, provider: nil,
                                title: "자동 작업", text: text,
                                payloadJSON: JSONUtil.string(["type": "orchestration", "jobID": job.id]))
        if let saved = try? await store.appendEvent(event) { host?.orchestrationDidAppend(event: saved) }
    }

    private func message(for need: SchedulerDecision.UserNeed, _ snapshot: OrchestrationSnapshot) -> String {
        switch need {
        case .deliveryUnknown: return "실행 결과를 확인할 수 없는 작업이 있습니다. 자동으로 다시 보내지 않습니다."
        case .blocked(let ids):
            let lines = snapshot.tasks.filter { ids.contains($0.id) }.map { "· \($0.title): \($0.blockedReason ?? "선행 작업을 기다림")" }
            return "진행이 막혔습니다. 확인해 주세요.\n" + lines.joined(separator: "\n")
        case .finalVerificationFailed: return "하위 작업은 모두 통과했지만 최종 통합 검증을 통과하지 못했습니다. 완료로 표시하지 않았습니다."
        case .budgetExhausted: return "시도 예산을 다 썼습니다. 예산을 늘려 계속하거나 여기서 멈출 수 있습니다."
        }
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    static func name(of kind: AttemptKind) -> String {
        switch kind {
        case .first: return "첫 시도"
        case .retry: return "보완"
        case .escalation: return "담당 변경"
        case .availabilitySwitch: return "가용한 담당으로 전환"
        }
    }

    static func name(of failure: FailureClass) -> String {
        switch failure {
        case .verificationFailed: return "검증 실패"
        case .environment: return "환경 문제 (권한 · 인증 · 도구)"
        case .limitReached: return "사용 한도 도달"
        case .transientNetwork: return "일시적 네트워크 오류"
        case .ambiguousRequirement: return "요구가 모호함"
        case .planDefect: return "계획 결함"
        case .deliveryUnknown: return "전달 여부 미확인"
        case .userCancelled: return "사용자 취소"
        }
    }

    static func name(of decision: FailureDecision) -> String {
        switch decision {
        case .retrySameProfile: return "같은 담당이 보완"
        case .escalate: return "더 강한 담당으로 변경"
        case .switchForAvailability: return "쓸 수 있는 다른 담당으로 전환"
        case .retryAfterBackoff(let s): return "\(s)초 뒤 재시도"
        case .askUser: return "사용자 확인 대기"
        case .replan: return "다시 계획"
        case .stopForRecovery: return "자동 진행 정지"
        case .cancel: return "취소"
        case .failTask: return "작업 실패"
        }
    }
}
