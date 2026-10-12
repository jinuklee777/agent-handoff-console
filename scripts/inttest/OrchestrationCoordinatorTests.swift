import Foundation

// MARK: - 오케스트레이션 코디네이터: 가짜 어댑터로 계획부터 통합 검증까지

/// 계획 · 실행 · 검토 턴에 답하는 가짜 두뇌. 실제 `RunCoordinator` 와 실제 SQLite 를 거치고 CLI 만 가짜다.
final class FakeBrain: @unchecked Sendable {
    enum Execution {
        case say(String)
        /// 잠깐 일한 뒤 답한다.
        case slow(String, milliseconds: Int)
        case fail(state: RunState, limit: LimitStatus?, message: String)
        case hang
    }

    /// 검토단 시나리오의 검토 답. 어느 제공자의 검토자인지에 따라 달리 답할 수 있다.
    enum ReviewReply {
        case verdict([String], problem: String = "none", delayMs: Int = 0)
        case unreadable
        case hang
    }

    private let lock = NSLock()
    private var panelReviewer: (@Sendable (String, AgentProvider) -> ReviewReply)?
    private var queuedPlans: [String] = []
    private var seen: [AgentTurnRequest] = []
    private var executor: @Sendable (AgentTurnRequest) -> Execution = { _ in .say("작업을 마쳤습니다.") }
    /// 프롬프트 → 조건별 결과(pass · fail · inconclusive)와 problem. nil 이면 해석할 수 없는 응답.
    private var reviewer: @Sendable (String) -> (outcomes: [String], problem: String)? = { prompt in
        (Array(repeating: "pass", count: FakeBrain.criteriaCount(in: prompt)), "none")
    }

    func queue(plan: OrchestrationPlan) { queue(planJSON: String(data: try! JSONEncoder().encode(plan), encoding: .utf8)!) }
    func queue(planJSON: String) { lock.lock(); queuedPlans.append(planJSON); lock.unlock() }
    func onExecute(_ body: @escaping @Sendable (AgentTurnRequest) -> Execution) { lock.lock(); executor = body; lock.unlock() }
    func onReview(_ body: @escaping @Sendable (String) -> (outcomes: [String], problem: String)?) { lock.lock(); reviewer = body; lock.unlock() }
    func onPanelReview(_ body: @escaping @Sendable (String, AgentProvider) -> ReviewReply) { lock.lock(); panelReviewer = body; lock.unlock() }
    var requests: [AgentTurnRequest] { lock.lock(); defer { lock.unlock() }; return seen }

    static func isPlanning(_ prompt: String) -> Bool { prompt.contains("계획 담당") || prompt.hasPrefix("계획을 받아들일 수 없습니다") }
    static func isReview(_ prompt: String) -> Bool { prompt.contains("검토 담당") }
    static func criteriaCount(in prompt: String) -> Int {
        guard let range = prompt.range(of: "완료 조건:\n") else { return 1 }
        return prompt[range.upperBound...].split(separator: "\n").prefix { $0.range(of: #"^\d+\. "#, options: .regularExpression) != nil }.count
    }

    func steps(for request: AgentTurnRequest, provider: AgentProvider) -> [ScriptedAgentAdapter.Step] {
        lock.lock()
        seen.append(request)
        let plan = FakeBrain.isPlanning(request.prompt) && !queuedPlans.isEmpty ? queuedPlans.removeFirst() : nil
        let (executor, reviewer, panelReviewer) = (self.executor, self.reviewer, self.panelReviewer)
        lock.unlock()

        let session = "fake-\(provider.rawValue)"
        var steps: [ScriptedAgentAdapter.Step] = [.emit(.sessionEstablished(sessionID: session, model: request.model, cliVersion: nil))]
        func finish(_ text: String, structured: String?) {
            var result = AgentTurnResult(state: .completed, terminalReason: "completed", model: request.model,
                                         sessionID: session, resultText: text)
            result.structuredOutput = structured
            steps += [.emit(.assistantMessage(text)), .finish(result)]
        }
        if FakeBrain.isPlanning(request.prompt) {
            finish(plan ?? "{}", structured: plan ?? "{}")
        } else if FakeBrain.isReview(request.prompt), let panelReviewer {
            switch panelReviewer(request.prompt, provider) {
            case .verdict(let outcomes, let problem, let delayMs):
                if delayMs > 0 { steps.append(.delay(milliseconds: delayMs)) }
                let criteria = outcomes.enumerated().map { ["criterion": "조건 \($0 + 1)", "outcome": $1, "evidence": "\(provider.rawValue) 가 확인함"] }
                let json = JSONUtil.string(["criteria": criteria, "summary": "\(provider.rawValue) 의 검토 요약", "problem": problem])
                finish(json, structured: json)
            case .unreadable: finish("해석할 수 없는 검토", structured: "읽을 수 없음")
            case .hang: steps.append(.waitInterrupt)
            }
        } else if FakeBrain.isReview(request.prompt) {
            if let verdict = reviewer(request.prompt) {
                let criteria = verdict.outcomes.enumerated().map { ["criterion": "조건 \($0 + 1)", "outcome": $1, "evidence": "확인함"] }
                let json = JSONUtil.string(["criteria": criteria, "summary": "검토 요약", "problem": verdict.problem])
                finish(json, structured: json)
            } else {
                finish("해석할 수 없는 검토", structured: "읽을 수 없음")
            }
        } else {
            switch executor(request) {
            case .say(let text): finish(text, structured: nil)
            case .slow(let text, let milliseconds):
                steps.append(.delay(milliseconds: milliseconds))
                finish(text, structured: nil)
            case .hang: steps.append(.waitInterrupt)
            case .fail(let state, let limit, let message):
                steps.append(.finish(AgentTurnResult(state: state, terminalReason: "failed", isError: true, errorMessage: message,
                                                     model: request.model, sessionID: session, limitStatus: limit)))
            }
        }
        return steps
    }
}

struct FakeCommandRunner: VerificationCommandRunning {
    let results: CommandScript
    func run(command: String, in directory: URL) async -> CommandResult { results.next(command) }

    final class CommandScript: @unchecked Sendable {
        private let lock = NSLock()
        private var exitCodes: [Int]
        private(set) var runs = 0
        init(exitCodes: [Int]) { self.exitCodes = exitCodes }
        func next(_ command: String) -> CommandResult {
            lock.lock(); defer { lock.unlock() }
            runs += 1
            let code = exitCodes.isEmpty ? 0 : exitCodes.removeFirst()
            return CommandResult(command: command, exitCode: code,
                                 outputTail: code == 0 ? "합계 10/10 통과" : "error: 테스트 3 실패\n합계 9/10 통과", durationMs: 12)
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return runs }
    }
}

@MainActor
final class FakeOrchestrationHost: OrchestrationHost, RunCoordinatorDelegate {
    struct Launch { var threadID: String; var provider: AgentProvider; var model: String?; var turn: AgentTurnOptions; var prompt: String }

    let runner: RunCoordinator
    /// 앱의 `AppModel.reviewLanes` 와 같은 것: 검토 턴이 동시에 도는 읽기 전용 레인.
    let reviewLanes: ReadOnlyRunPool
    weak var orchestration: OrchestrationCoordinator?
    var projects: [String: Project] = [:]
    var unavailable: [String: String] = [:]
    var launches: [Launch] = []
    var appended: [ThreadEvent] = []
    var changes = 0

    init(runner: RunCoordinator, reviewLanes: ReadOnlyRunPool) {
        self.runner = runner
        self.reviewLanes = reviewLanes
    }

    func isRunSlotBusy(project: Project) -> Bool { runner.isBusy || reviewLanes.isBusy }
    func canLaunchReview(project: Project) -> Bool { !runner.isBusy && reviewLanes.hasFreeLane }
    /// 동시에 돌던 검토 실행 수의 최댓값.
    var peakConcurrentReviews = 0

    func orchestrationLaunchReview(prompt: String, thread: ConversationThread, project: Project, provider: AgentProvider,
                                   outputSchema: String) async throws -> Run {
        guard canLaunchReview(project: project) else { throw RunCoordinator.StartError.busy }
        let turn = AgentTurnOptions(readOnly: true, outputSchema: outputSchema)
        launches.append(Launch(threadID: thread.id, provider: provider, model: thread.selection(for: provider).model,
                               turn: turn, prompt: prompt))
        let run = try await reviewLanes.send(prompt: prompt, thread: thread, project: project, provider: provider,
                                             account: nil, turn: turn)
        peakConcurrentReviews = max(peakConcurrentReviews, reviewLanes.activeRuns.count)
        return run
    }

    func orchestrationLaunch(prompt: String, thread: ConversationThread, project: Project, provider: AgentProvider,
                             codexAccountID: String?, turn: AgentTurnOptions) async throws -> Run {
        launches.append(Launch(threadID: thread.id, provider: provider, model: thread.selection(for: provider).model,
                               turn: turn, prompt: prompt))
        return try await runner.send(prompt: prompt, thread: thread, project: project, provider: provider, turn: turn)
    }
    /// 멈추라고 받은 실행 ID, 받은 순.
    var interruptedRunIDs: [String] = []
    func orchestrationInterrupt(runIDs: [String]) async {
        interruptedRunIDs += runIDs
        for runID in runIDs {
            if let session = runner.session(runID: runID) {
                await session.interrupt()
            } else {
                await reviewLanes.coordinator.session(runID: runID)?.interrupt()
            }
        }
    }
    func orchestrationUnavailableReason(for profile: ExecutionProfile, project: Project) async -> String? { unavailable[profile.id] }
    /// 검토에 줄 작업 폴더의 변경. 가짜 두뇌는 읽지 않으므로 고정 글이면 되지만, **실제 CLI 로 돌릴 때는 사실이어야 한다** —
    /// 셸을 못 쓰는 검토자(Claude 읽기 전용)는 이 글을 근거로 판정한다 (2026-09-21 실측: 고정 글의 "M Sources/a.swift" 를 보고
    /// "다른 파일을 건드렸다"로 떨어뜨렸다).
    var workspaceEvidence: ((Project) -> (text: String, fingerprint: String?))?
    func orchestrationWorkspaceEvidence(project: Project) async -> (text: String, fingerprint: String?) {
        workspaceEvidence?(project) ?? (" M Sources/a.swift", "fp-1")
    }
    func orchestrationProject(for job: OrchestrationJob) async -> Project? { projects[job.projectID] }
    func orchestrationDidChange(jobID: String) { changes += 1 }
    func orchestrationDidAppend(event: ThreadEvent) { appended.append(event) }

    // 앱에서는 AppModel 이 하는 일: 완료 통지를 코디네이터에 넘기고 슬롯이 비었음을 알린다.
    /// 실제 CLI 로 돌릴 때: 승인 요청을 자동으로 허용한다 (임시 폴더에서만 쓴다).
    var autoApprove = false
    func runCoordinator(_ c: RunCoordinator, didUpsert event: ThreadEvent) {
        if autoApprove, event.kind == .approvalRequest, let request = c.pendingApprovals.last {
            Task { await c.respond(approval: request, decision: .allow) }
        }
    }
    func runCoordinator(_ c: RunCoordinator, didChangeState state: RunState, run: Run?) {}
    func runCoordinator(_ c: RunCoordinator, didReceive limits: LimitSnapshot) {}
    func runCoordinator(_ c: RunCoordinator, needsAttention title: String, body: String, threadID: String, kind: AttentionKind) {}
    func runCoordinator(_ c: RunCoordinator, didFinish run: Run, result: AgentTurnResult, usage: UsageRecord?) {
        Task { @MainActor in
            await self.orchestration?.runDidFinish(run: run, result: result)
            await self.orchestration?.runSlotBecameIdle()
        }
    }
}

@MainActor
enum OrchestrationCoordinatorTests {

    /// 한 시나리오의 무대: 임시 DB · 실제 RunCoordinator · 가짜 두뇌 · 코디네이터.
    @MainActor
    final class Stage {
        let store: Store
        let runner: RunCoordinator
        let host: FakeOrchestrationHost
        let brain = FakeBrain()
        let commands: FakeCommandRunner.CommandScript
        var coordinator: OrchestrationCoordinator
        let project: Project
        let thread: ConversationThread
        private let dbURL: URL

        init(commandExitCodes: [Int] = [], reviewLaneCount: Int = ReadOnlyRunPool.defaultLaneCount,
             configure: (inout OrchestrationSettings) -> Void = { _ in }) async throws {
            dbURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-coordinator-\(UUID().uuidString).sqlite3")
            store = Store(databaseURL: dbURL)
            try await store.bootstrap()
            try await seedCodexCatalog(store)
            project = Project(name: "무대", path: NSTemporaryDirectory())
            try await store.upsertProject(project)
            thread = ConversationThread(projectID: project.id, title: "부모 대화")
            try await store.upsertThread(thread)
            runner = RunCoordinator(store: store, environment: CLIEnvironment())
            runner.maxConcurrentRuns = 1   // 앱의 실행 슬롯과 같게 (자동 작업은 이 하나를 수동 실행과 나눠 쓴다)
            let reviewLanes = ReadOnlyRunPool(store: store, environment: CLIEnvironment(), laneCount: reviewLaneCount)
            host = FakeOrchestrationHost(runner: runner, reviewLanes: reviewLanes)
            host.projects[project.id] = project
            runner.delegate = host
            let brain = self.brain
            let factory: (AgentProvider) -> AgentAdapter? = { provider in
                ScriptedAgentAdapter(provider: provider) { request in brain.steps(for: request, provider: provider) }
            }
            runner.adapterFactory = factory
            let stageHost = host
            reviewLanes.configure { $0.delegate = stageHost; $0.adapterFactory = factory }
            commands = FakeCommandRunner.CommandScript(exitCodes: commandExitCodes)
            coordinator = OrchestrationCoordinator(store: store, commandRunner: FakeCommandRunner(results: commands))
            coordinator.host = host
            coordinator.backoffScale = 0
            host.orchestration = coordinator
            var settings = OrchestrationSettings()
            settings.enabled = true
            settings.requiresPlanApproval = false
            settings.reviewPanel = .single   // 검토단 시나리오만 켠다. 나머지는 검토 담당 한 명의 흐름을 본다.
            configure(&settings)
            await coordinator.save(settings)
        }

        deinit { for x in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + x) } }

        func start(_ request: String = "기능을 만들어줘") async throws -> OrchestrationJob {
            try await coordinator.start(request: request, parentThread: thread, project: project)
        }

        func snapshot(_ job: OrchestrationJob) async -> OrchestrationSnapshot? { try? await store.orchestrationSnapshot(jobID: job.id) }

        /// 조건이 될 때까지 기다린다. 끝내 안 되면 마지막 상태를 돌려준다.
        func wait(_ job: OrchestrationJob, timeout: TimeInterval = 8, until: (OrchestrationSnapshot) -> Bool) async -> OrchestrationSnapshot? {
            let deadline = Date().addingTimeInterval(timeout)
            var last: OrchestrationSnapshot?
            while Date() < deadline {
                last = await snapshot(job)
                if let last, until(last) { return last }
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
            return last
        }

        func settled(_ job: OrchestrationJob) async -> OrchestrationSnapshot? {
            await wait(job) {
                [.completed, .failed, .cancelled, .awaitingUser, .paused].contains($0.job.state)
                    && !self.runner.isBusy && !self.host.reviewLanes.isBusy
            }
        }

        var executions: [AgentTurnRequest] { brain.requests.filter { !FakeBrain.isPlanning($0.prompt) && !FakeBrain.isReview($0.prompt) } }
        var reviews: [AgentTurnRequest] { brain.requests.filter { FakeBrain.isReview($0.prompt) } }
        var plannings: [AgentTurnRequest] { brain.requests.filter { FakeBrain.isPlanning($0.prompt) } }
    }

    static func plan(_ tasks: [PlannedTask]) -> OrchestrationPlan { OrchestrationTests.plan(tasks) }
    static func task(_ id: String, dependsOn: [String] = [], difficulty: Int = 2, kind: TaskKind = .implement) -> PlannedTask {
        var t = OrchestrationTests.task(id, dependsOn: dependsOn)
        t.difficulty = difficulty
        t.kind = kind
        return t
    }

    static func run(_ t: TestKit) async {
        do {
            try await happyPath(t)
            try await planApprovalAndCorrection(t)
            try await retryAndEscalation(t)
            try await verificationCommand(t)
            try await environmentAndLimits(t)
            try await cancelAndSlotSharing(t)
            try await restartRecovery(t)
            try await requirementChange(t)
            try await unverifiableAndFinal(t)
            try await reviewPanel(t)
            try await reviewLanes(t)
            try await shellRunner(t)
        } catch {
            await t.group("오케스트레이션 코디네이터")
            await t.check("시나리오 실행 중 예외", false, "\(error)")
        }
    }

    // MARK: 시나리오

    private static func happyPath(_ t: TestKit) async throws {
        await t.group("코디네이터: 계획부터 통합 검증까지")
        let stage = try await Stage()
        stage.brain.queue(plan: plan([task("a"), task("b", dependsOn: ["a"])]))
        stage.brain.onExecute { request in .say(request.prompt.contains("작업 a") && !request.prompt.contains("작업 b") ? "a 를 만들었습니다" : "b 를 만들었습니다") }
        let job = try await stage.start()
        let end = await stage.settled(job)

        await t.equal("전체 작업 완료", end?.job.state, .completed)
        await t.equal("하위 작업 모두 검증 통과", end?.tasks.map(\.state), [.succeeded, .succeeded])
        await t.equal("최종 통합 검증 통과", end?.job.finalVerification, .passed)
        await t.equal("턴 수: 계획 1 · 실행 2 · 검토 2 + 최종 검토 1",
                      "\(stage.plannings.count)/\(stage.executions.count)/\(stage.reviews.count)", "1/2/3")
        await t.check("계획 · 검토 턴은 읽기 전용 + 스키마, 실행 턴은 아니다",
                      (stage.plannings + stage.reviews).allSatisfy { $0.readOnly && $0.outputSchema != nil }
                        && stage.executions.allSatisfy { !$0.readOnly && $0.outputSchema == nil })
        await t.equal("난이도 2 → 등급 1 프로필", stage.executions.first?.model, "haiku")
        await t.check("실행한 프로필과 다른 프로필이 검토", stage.reviews.first?.model != stage.executions.first?.model)
        await t.check("뒤 작업에 선행 작업의 결과를 넘긴다",
                      stage.executions.last?.prompt.contains("먼저 끝난 작업의 결과") == true
                        && stage.executions.last?.prompt.contains("a 를 만들었습니다") == true)
        await t.check("자기 작업만 하도록 범위를 준다", stage.executions.first?.prompt.contains("이 작업만") == true)

        let parentEvents = try await stage.store.events(threadID: stage.thread.id)
        await t.equal("사용자 요청은 부모 대화에 한 번만", parentEvents.filter { $0.kind == .userMessage }.count, 1)
        await t.check("부모 대화에 진행 기록", parentEvents.contains { $0.text.contains("완료했습니다") }
                        && parentEvents.contains { $0.text.contains("계획을 세웠습니다") })
        await t.check("부모 대화에는 에이전트 실행이 없다 (내부 대화에서 돈다)", try await stage.store.runs(threadID: stage.thread.id).isEmpty)
        let inner = try await stage.store.orchestrationThreads(jobID: job.id)
        await t.equal("내부 대화: 계획 1 · 검토 1 · 작업 2", inner.map { $0.orchestrationRole ?? "" }.sorted(), ["planner", "reviewer", "task", "task"])
        await t.check("내부 대화는 내부로 표시된다", inner.allSatisfy(\.isInternal) && !stage.thread.isInternal)
        await t.equal("배정 근거 2건", try await stage.store.routingDecisions(jobID: job.id).count, 2)
        let records = try await stage.store.verificationRecords(jobID: job.id)
        await t.check("검증 기록: 작업 2 + 최종", records.filter { $0.taskID != nil }.count == 2 && records.contains { $0.taskID == nil })
        await t.check("검증 기록에 작업 폴더 지문", records.first { $0.taskID != nil }?.workspaceFingerprint == "fp-1")
        await t.check("끝난 뒤에는 실행을 소유하지 않는다", end?.attempts.compactMap(\.runID).allSatisfy { !stage.coordinator.owns(runID: $0) } == true)
        await t.check("화면용 스냅샷 갱신", stage.coordinator.snapshotsByThread[stage.thread.id]?.job.state == .completed && stage.host.changes > 0)
    }

    /// 검토단: 구현은 한 번에 하나, 검증은 서로 다른 제공자의 둘이 동시에.
    private static func reviewPanel(_ t: TestKit) async throws {
        await t.group("코디네이터: 검토단 (제공자 교차 · 동시 검토)")
        // 1. 쉬운 작업은 한 명, 어려운 작업과 최종 통합 검증은 둘.
        var stage = try await Stage { $0.reviewPanel = .hardAndFinal }
        stage.brain.queue(plan: plan([task("a", difficulty: 2), task("b", dependsOn: ["a"], difficulty: 4)]))
        stage.brain.onPanelReview { prompt, _ in .verdict(Array(repeating: "pass", count: FakeBrain.criteriaCount(in: prompt)), delayMs: 80) }
        var job = try await stage.start()
        var end = await stage.settled(job)
        await t.equal("전체 작업 완료", end?.job.state, .completed)
        await t.equal("검토 턴: 쉬운 작업 1 + 어려운 작업 2 + 최종 2", stage.reviews.count, 5)
        await t.equal("실행 턴은 그대로 작업마다 하나 (구현은 한 번에 하나)", stage.executions.count, 2)
        let reviewLaunches = stage.host.launches.filter { FakeBrain.isReview($0.prompt) }
        await t.equal("어려운 작업은 서로 다른 제공자가 검토", Set(reviewLaunches[1...2].map(\.provider)), [.claude, .codex])
        await t.equal("검토단은 같은 글을 받는다 (서로의 결과를 모른다)", reviewLaunches[1].prompt, reviewLaunches[2].prompt)
        await t.equal("둘이 동시에 돌았다", stage.host.peakConcurrentReviews, 2)
        await t.check("검토 턴은 모두 읽기 전용 + 스키마", reviewLaunches.allSatisfy { $0.turn.readOnly && $0.turn.outputSchema != nil })
        var inner = try await stage.store.orchestrationThreads(jobID: job.id)
        let reviewerThreads = inner.filter { $0.orchestrationRole == "reviewer" }
        await t.equal("검토 대화는 제공자마다 하나 (한 대화에 실행 둘이 돌지 않는다)",
                      reviewerThreads.map(\.preferredProvider.rawValue).sorted(), ["claude", "codex"])
        var records = try await stage.store.verificationRecords(jobID: job.id)
        let taskB = end?.tasks.first { $0.planTaskID == "b" }?.id
        await t.check("검증 기록에 검토자별 판정", records.filter { $0.taskID == taskB }.count == 2 * (end?.tasks.last?.acceptance.count ?? 0)
                        && records.contains { $0.taskID == taskB && $0.evidenceJSON.contains("Codex Sol · medium") })
        let parentNotes = try await stage.store.events(threadID: stage.thread.id).map(\.text)
        await t.check("부모 대화에 검토단을 알린다", parentNotes.contains { $0.contains("검토단(Claude Sonnet · Codex Sol · medium)") })

        // 2. 한 명이라도 실패면 실패 → 같은 담당이 보완 → 통과.
        stage = try await Stage { $0.reviewPanel = .always }
        stage.brain.queue(plan: plan([task("a")]))
        let codexReviews = Counter()
        stage.brain.onPanelReview { prompt, provider in
            let count = FakeBrain.criteriaCount(in: prompt)
            if provider == .codex, !prompt.contains("최종 통합 검증"), codexReviews.next() == 1 {
                return .verdict(["fail"] + Array(repeating: "pass", count: max(0, count - 1)), problem: "verificationFailed")
            }
            return .verdict(Array(repeating: "pass", count: count))
        }
        job = try await stage.start()
        end = await stage.settled(job)
        await t.equal("한 명이 실패시킨 뒤 보완해 완료", end?.job.state, .completed)
        let attempts = end?.attempts ?? []
        await t.equal("시도 2번: 실패 → 통과", attempts.map(\.state), [.failed, .succeeded])
        await t.equal("검토단의 실패는 능력 실패로 센다", attempts.first?.failureClass, .verificationFailed)
        await t.check("보완 글에 어느 검토자가 짚었는지", stage.executions.last?.prompt.contains("(Codex Sol · medium)") == true)
        await t.equal("보완은 같은 담당", stage.executions.map(\.model), ["haiku", "haiku"])

        // 3. 한 검토자가 결과를 못 내도 다른 한 명의 판정으로 간다.
        stage = try await Stage { $0.reviewPanel = .always }
        stage.brain.queue(plan: plan([task("a")]))
        stage.brain.onPanelReview { prompt, provider in
            provider == .codex ? .unreadable : .verdict(Array(repeating: "pass", count: FakeBrain.criteriaCount(in: prompt)))
        }
        job = try await stage.start()
        end = await stage.settled(job)
        await t.equal("결과를 못 낸 검토자는 빼고 완료", end?.job.state, .completed)
        records = try await stage.store.verificationRecords(jobID: job.id)
        await t.check("뺀 검토자도 기록에 남는다", records.contains { $0.outcome == .inconclusive && $0.evidenceJSON.contains("판정에서 뺐습니다") })

        // 4. 다른 제공자를 쓸 수 없으면 한 명이 검토한다.
        stage = try await Stage { $0.reviewPanel = .always }
        stage.host.unavailable = ["codex-sol-medium": "한도 도달", "codex-sol-high": "한도 도달"]
        stage.brain.queue(plan: plan([task("a")]))
        job = try await stage.start()
        end = await stage.settled(job)
        await t.equal("Codex 를 못 쓰면 한 명으로 완료", "\(end?.job.state.rawValue ?? "")/\(stage.reviews.count)", "completed/2")

        // 5. 검토 레인이 하나뿐이면 보낸 사람만으로 판정한다.
        stage = try await Stage(reviewLaneCount: 1) { $0.reviewPanel = .always }
        stage.brain.queue(plan: plan([task("a")]))
        stage.brain.onPanelReview { prompt, _ in .verdict(Array(repeating: "pass", count: FakeBrain.criteriaCount(in: prompt)), delayMs: 40) }
        job = try await stage.start()
        end = await stage.settled(job)
        await t.equal("레인이 모자라도 멈추지 않는다", "\(end?.job.state.rawValue ?? "")/\(stage.host.peakConcurrentReviews)", "completed/1")

        // 6. 검토단이 도는 중에 중단: 둘 다 멈추고 중단으로 끝난다. 그 사이 쓰기 실행은 시작되지 않는다.
        stage = try await Stage { $0.reviewPanel = .always }
        stage.brain.queue(plan: plan([task("a"), task("b", dependsOn: ["a"])]))
        stage.brain.onPanelReview { _, _ in .hang }
        job = try await stage.start()
        let lanes = stage.host.reviewLanes
        _ = await stage.wait(job) { _ in lanes.activeRuns.count == 2 }
        await t.equal("검토단 둘이 돌고 있다", lanes.activeRuns.count, 2)
        await t.check("검토 중에는 쓰기 슬롯이 찬 것으로 본다 (다음 작업을 시작하지 않는다)",
                      stage.host.isRunSlotBusy(project: stage.project) && !stage.runner.isBusy && stage.executions.count == 1)
        try await stage.coordinator.cancel(jobID: job.id)
        end = await stage.settled(job)
        await t.equal("중단으로 끝난다", end?.job.state, .cancelled)
        await t.check("레인이 모두 비었다", !lanes.isBusy)
        await t.equal("다음 작업은 시작되지 않았다", stage.executions.count, 1)
        inner = try await stage.store.orchestrationThreads(jobID: job.id)
        let reviewRuns = try await inner.filter { $0.orchestrationRole == "reviewer" }.asyncFlatMap { try await stage.store.runs(threadID: $0.id) }
        await t.check("검토 실행은 중단으로 기록된다", reviewRuns.count == 2 && reviewRuns.allSatisfy { $0.state == .cancelled }, "\(reviewRuns.map(\.state))")
    }

    /// 검토 레인: 읽기 전용만, 동시에 여럿, 승인 · 질문을 기다리지 않는다.
    private static func reviewLanes(_ t: TestKit) async throws {
        await t.group("검토 레인 (ReadOnlyRunPool)")
        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-lanes-\(UUID().uuidString).sqlite3")
        defer { for x in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + x) } }
        let store = Store(databaseURL: dbURL)
        try await store.bootstrap()
        let project = Project(name: "레인", path: NSTemporaryDirectory())
        try await store.upsertProject(project)
        var threads: [ConversationThread] = []
        for index in 0..<4 {
            let thread = ConversationThread(projectID: project.id, title: "검토 \(index)")
            try await store.upsertThread(thread)
            threads.append(thread)
        }
        let pool = ReadOnlyRunPool(store: store, environment: CLIEnvironment(), laneCount: 2)
        let approval = ApprovalRequest(id: "ap-1", runID: "", provider: .claude, kind: .command, toolName: "Bash",
                                       title: "rm -rf build", detail: "", toolUseID: nil)
        let adapters = AdapterLog()
        pool.configure { lane in
            lane.adapterFactory = { provider in
                let adapter = ScriptedAgentAdapter(provider: provider) { request in
                    if request.prompt == "승인" {
                        return [.emit(.approvalRequested(approval)), .waitApproval(id: approval.id),
                                .finish(AgentTurnResult(state: .completed, terminalReason: "completed"))]
                    }
                    return [.waitInterrupt]
                }
                adapters.add(adapter)
                return adapter
            }
        }
        let readOnly = AgentTurnOptions(readOnly: true, outputSchema: nil)

        do {
            _ = try await pool.send(prompt: "쓰기", thread: threads[0], project: project, provider: .claude, account: nil, turn: AgentTurnOptions())
            await t.check("읽기 전용이 아닌 턴은 받지 않는다", false)
        } catch { await t.check("읽기 전용이 아닌 턴은 받지 않는다", "\(error)".contains("unattendedNeedsReadOnly"), "\(error)") }
        await t.equal("거절한 턴은 기록을 남기지 않는다", try await store.runs(threadID: threads[0].id).count, 0)

        let first = try await pool.send(prompt: "검토 1", thread: threads[0], project: project, provider: .claude, account: nil, turn: readOnly)
        let second = try await pool.send(prompt: "검토 2", thread: threads[1], project: project, provider: .codex, account: nil, turn: readOnly)
        await t.check("두 실행이 동시에 돈다", pool.activeRuns.map(\.id).sorted() == [first.id, second.id].sorted() && !pool.hasFreeLane)
        do {
            _ = try await pool.send(prompt: "검토 3", thread: threads[2], project: project, provider: .claude, account: nil, turn: readOnly)
            await t.check("빈 레인이 없으면 busy", false)
        } catch RunCoordinator.StartError.busy { await t.check("빈 레인이 없으면 busy", true) }
        await pool.interruptAll()
        for _ in 0..<200 where pool.isBusy { try? await Task.sleep(nanoseconds: 10_000_000) }
        await t.check("모두 멈추면 레인이 빈다", !pool.isBusy && pool.hasFreeLane)

        _ = try await pool.send(prompt: "검토 4", thread: threads[2], project: project, provider: .claude, account: nil, turn: readOnly)
        do {
            _ = try await pool.send(prompt: "검토 5", thread: threads[2], project: project, provider: .codex, account: nil, turn: readOnly)
            await t.check("같은 대화에는 실행이 하나", false)
        } catch RunCoordinator.StartError.busy { await t.check("같은 대화에는 실행이 하나", true) }
        await pool.interruptAll()
        for _ in 0..<200 where pool.isBusy { try? await Task.sleep(nanoseconds: 10_000_000) }

        let asked = try await pool.send(prompt: "승인", thread: threads[3], project: project, provider: .claude, account: nil, turn: readOnly)
        for _ in 0..<200 where pool.isBusy { try? await Task.sleep(nanoseconds: 10_000_000) }
        let decision = adapters.all.compactMap { $0.decisions[approval.id] }.first
        await t.check("지켜보는 사람이 없으니 승인 요청은 거절하고 이어 간다", { if case .deny = decision { return true } else { return false } }(), "\(String(describing: decision))")
        await t.equal("거절한 뒤 턴은 끝까지 간다", try await store.runs(threadID: threads[3].id).first { $0.id == asked.id }?.state, .completed)
    }

    private static func planApprovalAndCorrection(_ t: TestKit) async throws {
        await t.group("코디네이터: 계획 승인 · 계획 보정")
        var stage = try await Stage { $0.requiresPlanApproval = true }
        stage.brain.queue(plan: plan([task("a")]))
        var job = try await stage.start()
        var s = await stage.wait(job) { $0.job.state == .ready }
        await t.equal("계획을 보여 주고 멈춘다", s?.job.state, .ready)
        await t.equal("실행은 아직 없다", stage.executions.count, 0)
        await t.equal("사람에게 바라는 것: 계획 승인", s.flatMap { stage.coordinator.attention(for: $0) }, .planApproval)
        try await stage.coordinator.approvePlan(jobID: job.id)
        s = await stage.settled(job)
        await t.equal("승인 뒤 끝까지", s?.job.state, .completed)

        stage = try await Stage()
        var contradictory = plan([task("a"), task("b")]); contradictory.needsDecomposition = false
        stage.brain.queue(plan: contradictory)
        stage.brain.queue(plan: plan([task("a"), task("b")]))
        job = try await stage.start()
        s = await stage.settled(job)
        await t.equal("모순된 첫 계획 → 보정 1회 → 완료", "\(s?.job.state.rawValue ?? "")/\(stage.plannings.count)", "completed/2")
        await t.check("보정 요청에 거절 사유를 돌려준다", stage.plannings.last?.prompt.contains("분해가 필요 없다고 했지만") == true)
        await t.check("보정은 같은 세션에서", stage.plannings.last?.resumeSessionID != nil)

        stage = try await Stage()
        stage.brain.queue(plan: contradictory)
        stage.brain.queue(plan: contradictory)
        job = try await stage.start()
        s = await stage.settled(job)
        await t.equal("보정해도 안 되면 멈춘다 (보정은 한 번)", "\(s?.job.state.rawValue ?? "")/\(stage.plannings.count)", "awaitingUser/2")

        stage = try await Stage()
        var unclear = plan([task("a")]); unclear.infoSufficient = false; unclear.openQuestions = ["어느 화면인가요?"]
        stage.brain.queue(plan: unclear)
        stage.brain.queue(plan: plan([task("a")]))
        job = try await stage.start("좀 더 예쁘게 해줘")
        s = await stage.settled(job)
        await t.equal("정보가 부족하면 실행하지 않고 묻는다", "\(s?.job.state.rawValue ?? "")/\(stage.executions.count)", "awaitingUser/0")
        await t.equal("질문을 보여 준다", s.flatMap { stage.coordinator.attention(for: $0) }, .clarification(questions: ["어느 화면인가요?"]))
        try await stage.coordinator.answer(jobID: job.id, text: "설정 화면이요")
        s = await stage.settled(job)
        await t.equal("답을 받으면 다시 계획해 끝까지", s?.job.state, .completed)
        // 요청 · 답은 자동 작업이 맡았다는 표시를 단다 — 인계 초안이 "아직 처리되지 않은 사용자 지시" 로 넘기지 않게.
        let asked = ((try? await stage.store.events(threadID: stage.thread.id)) ?? []).filter { $0.kind == .userMessage }
        await t.check("자동 작업의 요청 · 답 메시지에 표시가 붙는다 (인계가 다시 시키지 않게)",
                      asked.map(\.text) == ["좀 더 예쁘게 해줘", "설정 화면이요"] && asked.allSatisfy(\.isOrchestrationRequest),
                      "\(asked.map { "\($0.text) \($0.isOrchestrationRequest)" })")
        await t.check("다시 계획할 때 답을 넣는다", stage.plannings.last?.prompt.contains("설정 화면이요") == true)
        await t.equal("질문했던 계획의 작업은 대체된다", s?.tasks.map(\.state), [.superseded, .succeeded])
    }

    private static func retryAndEscalation(_ t: TestKit) async throws {
        await t.group("코디네이터: 검증 실패 → 보완 → 담당 변경")
        let stage = try await Stage()
        stage.brain.queue(plan: plan([task("a")]))
        // 등급 1(haiku)이 한 작업은 검토에서 떨어지고, 더 높은 등급이 하면 통과한다.
        let models = ModelLog()
        stage.brain.onExecute { request in models.add(request.model ?? ""); return .say("했습니다 (\(request.model ?? ""))") }
        stage.brain.onReview { prompt in
            guard prompt.contains("검토할 작업: 작업 a") else { return (Array(repeating: "pass", count: FakeBrain.criteriaCount(in: prompt)), "none") }
            return prompt.contains("(haiku)") ? (["fail"], "verificationFailed") : (["pass"], "none")
        }
        let job = try await stage.start()
        let end = await stage.settled(job)
        await t.equal("끝내 완료", end?.job.state, .completed)
        await t.equal("시도: 첫 시도 → 보완 → 담당 변경", end?.attempts.map(\.kind.rawValue), ["first", "retry", "escalation"])
        await t.equal("프로필: 같은 것으로 보완한 뒤 더 높은 등급으로", end?.attempts.map(\.profileID), ["claude-haiku", "claude-haiku", "claude-sonnet"])
        await t.equal("시도 상태", end?.attempts.map(\.state), [.failed, .failed, .succeeded])
        await t.check("실패는 검증 실패로 분류", end?.attempts.prefix(2).allSatisfy { $0.failureClass == .verificationFailed } == true)
        let prompts = stage.executions.map(\.prompt)
        await t.check("보완은 같은 세션에 검증 근거만 짧게", prompts.count == 3 && prompts[1].contains("통과하지 못했습니다")
                        && prompts[1].contains("완료 조건 미충족") && !prompts[1].contains("전체 목표"))
        await t.check("담당 변경은 작업 명세 + 앞선 검증 결과 + 남은 변경 안내", prompts.count == 3 && prompts[2].contains("전체 목표")
                        && prompts[2].contains("앞선 검증 결과") && prompts[2].contains("작업 폴더에 남아"))
        await t.check("검토는 실행한 프로필과 다른 프로필", zip(stage.executions, stage.reviews).allSatisfy { $0.model != $1.model })

        let hopeless = try await Stage()
        hopeless.brain.queue(plan: plan([task("a")]))
        hopeless.brain.onReview { prompt in
            prompt.contains("최종") ? (["pass"], "none") : (Array(repeating: "fail", count: FakeBrain.criteriaCount(in: prompt)), "verificationFailed")
        }
        let lost = try await hopeless.start()
        let failed = await hopeless.settled(lost)
        await t.equal("끝없이 돌지 않는다: 3회에서 전체 실패", "\(failed?.job.state.rawValue ?? "")/\(failed?.attempts.count ?? 0)", "failed/3")
        await t.check("같은 프로필로 돌아가지 않는다", Set(failed?.attempts.map(\.profileID) ?? []).count == 2
                        && failed?.attempts.last?.profileID != failed?.attempts.first?.profileID)
    }

    final class ModelLog: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    }

    private static func verificationCommand(_ t: TestKit) async throws {
        await t.group("코디네이터: 검증 명령")
        let stage = try await Stage(commandExitCodes: [1, 0, 0])
        var settings = await stage.coordinator.currentSettings()
        settings.verificationCommands[stage.project.id] = "./scripts/test.sh"
        await stage.coordinator.save(settings)
        stage.brain.queue(plan: plan([task("a")]))
        let job = try await stage.start()
        let end = await stage.settled(job)
        await t.equal("명령 실패 → 보완 → 통과 → 완료", "\(end?.job.state.rawValue ?? "")/\(end?.attempts.map(\.state.rawValue) ?? [])", "completed/[\"failed\", \"succeeded\"]")
        await t.equal("명령은 시도마다 + 최종 검증에서", stage.commands.count, 3)
        await t.equal("명령이 실패하면 검토 턴을 쓰지 않는다 (객관적 실패)", stage.reviews.count, 2)   // 두 번째 시도 + 최종
        await t.check("보완 요청에 명령 출력이 들어간다", stage.executions.last?.prompt.contains("테스트 3 실패") == true)
        await t.check("같은 실패를 알아보는 지문", end?.attempts.first?.failureFingerprint?.hasPrefix("cmd:1:") == true)
        let records = try await stage.store.verificationRecords(jobID: job.id)
        await t.check("명령 결과가 검증 기록에 남는다", records.contains { $0.criterion.contains("./scripts/test.sh") && $0.outcome == .fail }
                        && records.contains { $0.criterion.contains("./scripts/test.sh") && $0.outcome == .pass })

        let explain = try await Stage(commandExitCodes: [1]) { $0.reviewMode = .whenNoCommand }
        var s2 = await explain.coordinator.currentSettings()
        s2.verificationCommands[explain.project.id] = "./scripts/test.sh"
        await explain.coordinator.save(s2)
        explain.brain.queue(plan: plan([task("a", kind: .explain)]))
        let ej = try await explain.start()
        _ = await explain.wait(ej) { $0.tasks.first?.state == .succeeded }
        await t.check("설명 · 검토 · 조사 작업에는 검증 명령을 돌리지 않는다 (파일을 바꾸지 않는다)",
                      (await explain.snapshot(ej))?.tasks.first?.state == .succeeded && explain.reviews.count >= 1)
    }

    private static func environmentAndLimits(_ t: TestKit) async throws {
        await t.group("코디네이터: 환경 문제 · 한도")
        var stage = try await Stage()
        stage.brain.queue(plan: plan([task("a")]))
        let first = Flag()
        stage.brain.onExecute { _ in first.takeOnce() ? .fail(state: .failed, limit: .authProblem, message: "로그인이 필요합니다") : .say("했습니다") }
        var job = try await stage.start()
        var s = await stage.settled(job)
        await t.equal("인증 실패 → 능력 승격 없이 사용자 대기", "\(s?.job.state.rawValue ?? "")/\(s?.tasks.first?.state.rawValue ?? "")/\(s?.attempts.count ?? 0)",
                      "awaitingUser/blocked/1")
        await t.equal("환경 문제로 분류 (모델 성과에 넣지 않는다)", s?.attempts.first?.failureClass, .environment)
        await t.check("막힌 이유를 보여 준다", s?.tasks.first?.blockedReason?.contains("로그인이 필요합니다") == true)
        if case .blocked(let tasks)? = s.flatMap({ stage.coordinator.attention(for: $0) }) {
            await t.equal("사람에게 바라는 것: 막힌 작업 확인", tasks.map(\.planTaskID), ["a"])
        } else {
            await t.check("사람에게 바라는 것: 막힌 작업 확인", false)
        }
        try await stage.coordinator.resume(jobID: job.id)
        s = await stage.settled(job)
        await t.equal("고친 뒤 계속 → 같은 담당으로 다시 → 완료", "\(s?.job.state.rawValue ?? "")/\(s?.attempts.map(\.profileID) ?? [])",
                      "completed/[\"claude-haiku\", \"claude-haiku\"]")

        stage = try await Stage()
        stage.brain.queue(plan: plan([task("a")]))
        stage.brain.onExecute { request in
            request.model == "haiku" ? .fail(state: .rateLimited, limit: .subscriptionCap, message: "usage limit") : .say("했습니다")
        }
        job = try await stage.start()
        s = await stage.settled(job)
        await t.equal("한도 → 쓸 수 있는 다른 담당으로 전환 → 완료", "\(s?.job.state.rawValue ?? "")/\(s?.attempts.map(\.kind.rawValue) ?? [])",
                      "completed/[\"first\", \"availabilitySwitch\"]")
        await t.equal("한도는 능력 실패가 아니다", s?.attempts.first?.failureClass, .limitReached)

        stage = try await Stage()
        stage.host.unavailable = Dictionary(uniqueKeysWithValues: ExecutionProfile.defaults.filter { $0.provider == .codex || $0.tier < 3 }
            .map { ($0.id, "한도 확인 안 됨") })
        stage.brain.queue(plan: plan([task("a")]))
        job = try await stage.start()
        s = await stage.settled(job)
        await t.equal("쓸 수 없는 프로필은 후보에서 빼고 남은 것으로", s?.attempts.first?.profileID, "claude-opus")
        let decision = try await stage.store.routingDecisions(jobID: job.id).first
        await t.check("뺀 이유를 배정 근거에 남긴다", decision?.candidatesJSON.contains("한도 확인 안 됨") == true)

        stage = try await Stage()
        stage.host.unavailable = Dictionary(uniqueKeysWithValues: ExecutionProfile.defaults.map { ($0.id, "CLI 없음") })
        stage.brain.queue(plan: plan([task("a")]))
        job = try await stage.start()
        s = await stage.settled(job)
        await t.equal("계획을 맡길 프로필이 없으면 시작하지 않고 알린다", "\(s?.job.state.rawValue ?? "")/\(stage.brain.requests.count)", "awaitingUser/0")
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var used = false
        func takeOnce() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
    }

    private static func cancelAndSlotSharing(_ t: TestKit) async throws {
        await t.group("코디네이터: 중단 · 실행 슬롯 공유")
        var stage = try await Stage()
        stage.brain.queue(plan: plan([task("a"), task("b", dependsOn: ["a"])]))
        stage.brain.onExecute { _ in .hang }
        var job = try await stage.start()
        var s = await stage.wait(job) { $0.attempts.first?.state == .running }
        await t.check("실행 중인 실행을 소유한다 (자동 인계가 건드리지 않게)", s?.attempts.first?.runID.map { stage.coordinator.owns(runID: $0) } == true)
        try await stage.coordinator.cancel(jobID: job.id)
        s = await stage.settled(job)
        await t.equal("중단: 실행을 멈추고 모두 취소", "\(s?.job.state.rawValue ?? "")/\(s?.tasks.map(\.state.rawValue) ?? [])/\(s?.attempts.map(\.state.rawValue) ?? [])",
                      "cancelled/[\"cancelled\", \"cancelled\"]/[\"cancelled\"]")
        await t.check("중단 뒤 슬롯이 비어 있다", !stage.runner.isBusy)
        await t.equal("중단 뒤에는 아무것도 새로 보내지 않는다", stage.executions.count, 1)
        await t.equal("중단은 그 작업의 실행만 실행 ID 로 멈춘다", stage.host.interruptedRunIDs, s?.attempts.compactMap(\.runID) ?? [])

        // 사용자가 다른 대화에서 수동 실행 중이면 끼어들지 않고 기다린다.
        stage = try await Stage()
        stage.brain.queue(plan: plan([task("a")]))
        stage.brain.onExecute { request in request.prompt.contains("수동") ? .hang : .say("했습니다") }
        let manual = ConversationThread(projectID: stage.project.id, title: "수동 대화")
        try await stage.store.upsertThread(manual)
        try await stage.runner.send(prompt: "수동 실행", thread: manual, project: stage.project, provider: .claude)
        job = try await stage.start()
        try? await Task.sleep(nanoseconds: 150_000_000)
        await t.equal("슬롯이 차 있으면 계획 턴을 보내지 않고 기다린다", stage.plannings.count, 0)
        await stage.runner.interrupt()
        s = await stage.settled(job)
        await t.equal("슬롯이 비면 이어서 끝까지", s?.job.state, .completed)

        // 사용자가 오케스트레이션의 실행 하나만 멈췄을 때: 전체 실패가 아니라 물어본다.
        stage = try await Stage()
        stage.brain.queue(plan: plan([task("a")]))
        let once = Flag()
        stage.brain.onExecute { _ in once.takeOnce() ? .hang : .say("했습니다") }
        job = try await stage.start()
        _ = await stage.wait(job) { $0.attempts.first?.state == .running }
        await stage.runner.interrupt()
        s = await stage.settled(job)
        await t.equal("실행 하나를 멈추면 전체 실패가 아니라 사용자 대기", "\(s?.job.state.rawValue ?? "")/\(s?.tasks.first?.state.rawValue ?? "")", "awaitingUser/blocked")
        try await stage.coordinator.resume(jobID: job.id)
        s = await stage.settled(job)
        await t.equal("계속하면 다시 시도해 완료", s?.job.state, .completed)

        // 일시 정지: 돌던 작업은 끝까지, 새 작업은 시작하지 않는다.
        stage = try await Stage()
        stage.brain.queue(plan: plan([task("a"), task("b", dependsOn: ["a"])]))
        stage.brain.onExecute { _ in .slow("했습니다", milliseconds: 250) }
        job = try await stage.start()
        _ = await stage.wait(job) { $0.attempts.first?.state == .running }
        try await stage.coordinator.pause(jobID: job.id)
        _ = await stage.wait(job) { $0.tasks.first?.state == .succeeded }
        try? await Task.sleep(nanoseconds: 200_000_000)   // 뒤 작업을 시작했다면 드러날 시간
        s = await stage.settled(job)
        await t.equal("일시 정지: 돌던 작업은 검증까지 끝내고, 새 작업은 시작하지 않는다",
                      "\(s?.job.state.rawValue ?? "")/\(s?.tasks.map(\.state.rawValue) ?? [])", "paused/[\"succeeded\", \"pending\"]")
        try await stage.coordinator.resume(jobID: job.id)
        s = await stage.settled(job)
        await t.equal("재개하면 끝까지", s?.job.state, .completed)

        let second = ConversationThread(projectID: stage.project.id, title: "둘째")
        try await stage.store.upsertThread(second)
        stage.brain.queue(plan: plan([task("a")]))
        stage.brain.onExecute { _ in .hang }
        let active = try await stage.coordinator.start(request: "첫째", parentThread: second, project: stage.project)
        _ = await stage.wait(active) { $0.attempts.first?.state == .running }
        var refused = false
        do { _ = try await stage.start("둘째 요청") } catch { refused = true }
        await t.check("진행 중인 자동 작업이 있으면 새로 시작하지 않는다", refused)
        try await stage.coordinator.cancel(jobID: active.id)
        _ = await stage.settled(active)
    }

    private static func restartRecovery(_ t: TestKit) async throws {
        await t.group("코디네이터: 앱 재시작 복구")
        let stage = try await Stage()
        stage.brain.queue(plan: plan([task("a"), task("b", dependsOn: ["a"])]))
        stage.brain.onExecute { _ in .hang }
        let job = try await stage.start()
        _ = await stage.wait(job) { $0.attempts.first?.state == .running }
        let sentBefore = stage.brain.requests.count

        // 앱이 꺼졌다 켜졌다: 같은 DB 위에 새 코디네이터. 돌던 프로세스는 없다.
        stage.host.orchestration = nil
        await stage.runner.interrupt()
        _ = await stage.wait(job) { _ in !stage.runner.isBusy }
        let revived = OrchestrationCoordinator(store: stage.store, commandRunner: FakeCommandRunner(results: stage.commands))
        revived.host = stage.host
        stage.host.orchestration = revived
        stage.coordinator = revived
        await revived.recoverAfterLaunch()

        var s = await stage.snapshot(job)
        await t.equal("돌던 시도는 전달 여부 미확인, 전체는 사용자 대기", "\(s?.job.state.rawValue ?? "")/\(s?.attempts.first?.state.rawValue ?? "")", "awaitingUser/deliveryUnknown")
        await t.equal("다시 보내지 않는다", stage.brain.requests.count, sentBefore)
        if case .deliveryUnknown(let ids)? = s.flatMap({ revived.attention(for: $0) }) {
            await t.equal("사람에게 바라는 것: 그 시도의 확인", ids, s?.attempts.map(\.id) ?? [])
        } else {
            await t.check("사람에게 바라는 것: 그 시도의 확인", false)
        }
        try await revived.resume(jobID: job.id)
        s = await stage.settled(job)
        await t.equal("확인 없이 계속을 눌러도 다시 보내지 않는다", "\(s?.job.state.rawValue ?? "")/\(stage.brain.requests.count)", "awaitingUser/\(sentBefore)")

        stage.brain.onExecute { _ in .say("했습니다") }
        try await revived.resolveDeliveryUnknown(jobID: job.id, attemptID: s!.attempts[0].id, finished: true)
        s = await stage.settled(job)
        await t.equal("끝난 것으로 확인 → 검증부터 이어 가 완료", "\(s?.job.state.rawValue ?? "")/\(s?.attempts.map(\.state.rawValue) ?? [])",
                      "completed/[\"succeeded\", \"succeeded\"]")

        // 돌던 시도가 없던 작업은 일시 정지로 돌아온다 (앱을 켜자마자 에이전트를 돌리지 않는다).
        let quiet = try await Stage { $0.requiresPlanApproval = true }
        quiet.brain.queue(plan: plan([task("a")]))
        let qj = try await quiet.start()
        _ = await quiet.wait(qj) { $0.job.state == .ready }
        try await quiet.coordinator.approvePlan(jobID: qj.id)
        _ = await quiet.settled(qj)
        let again = try await Stage()
        again.brain.queue(plan: plan([task("a"), task("b", dependsOn: ["a"])]))
        again.brain.onExecute { _ in .slow("했습니다", milliseconds: 250) }
        let aj = try await again.start()
        _ = await again.wait(aj) { $0.attempts.first?.state == .running }
        try await again.coordinator.pause(jobID: aj.id)
        _ = await again.wait(aj) { $0.tasks.first?.state == .succeeded }
        _ = await again.settled(aj)
        var running = try await again.store.orchestrationJob(id: aj.id)!
        running.state = .running
        try await again.store.applyOrchestration(OrchestrationChanges(cause: "시험: 실행 중에 꺼짐", job: running), jobID: aj.id)
        let sent = again.brain.requests.count
        let next = OrchestrationCoordinator(store: again.store, commandRunner: FakeCommandRunner(results: again.commands))
        next.host = again.host
        again.host.orchestration = next
        await next.recoverAfterLaunch()
        try? await Task.sleep(nanoseconds: 100_000_000)
        await t.equal("켜자마자 돌리지 않고 일시 정지로", "\((await again.snapshot(aj))?.job.state.rawValue ?? "")/\(again.brain.requests.count)", "paused/\(sent)")
    }

    private static func requirementChange(_ t: TestKit) async throws {
        await t.group("코디네이터: 중간에 요구 변경")
        let stage = try await Stage()
        stage.brain.queue(plan: plan([task("old1"), task("old2", dependsOn: ["old1"])]))
        stage.brain.queue(plan: plan([task("new1")]))
        let hold = Flag()
        stage.brain.onExecute { _ in hold.takeOnce() ? .hang : .say("했습니다") }
        let job = try await stage.start()
        let running = await stage.wait(job) { $0.attempts.first?.state == .running }
        try await stage.coordinator.answer(jobID: job.id, text: "아니, 방향을 바꿔서 new1 만 해줘")
        await t.equal("재계획은 이전 계획의 실행만 멈춘다", stage.host.interruptedRunIDs, running?.attempts.compactMap(\.runID) ?? [])
        let end = await stage.settled(job)
        await t.equal("새 계획으로 완료", end?.job.state, .completed)
        await t.equal("이전 계획의 작업은 실행하지 않는다", end?.tasks.map { "\($0.planTaskID):\($0.state.rawValue)" },
                      ["old1:superseded", "old2:superseded", "new1:succeeded"])
        await t.equal("돌던 시도의 결과는 버린다", end?.attempts.first?.state, .cancelled)
        await t.equal("세대가 올라간다", end?.job.generation, 1)
        await t.check("바뀐 요구가 다시 계획에 들어간다", stage.plannings.last?.prompt.contains("방향을 바꿔서") == true)
        await t.equal("바뀐 요구도 부모 대화에 기록", try await stage.store.events(threadID: stage.thread.id).filter { $0.kind == .userMessage }.count, 2)
    }

    private static func unverifiableAndFinal(_ t: TestKit) async throws {
        await t.group("코디네이터: 판정 불가 · 최종 통합 검증")
        var stage = try await Stage()
        stage.brain.queue(plan: plan([task("a")]))
        stage.brain.onReview { prompt in prompt.contains("최종") ? (["pass"], "none") : (["inconclusive"], "none") }
        var job = try await stage.start()
        var s = await stage.settled(job)
        await t.equal("판정 불가는 통과가 아니다 → 사람에게", "\(s?.job.state.rawValue ?? "")/\(s?.tasks.first?.state.rawValue ?? "")", "awaitingUser/blocked")
        try await stage.coordinator.acceptTask(jobID: job.id, taskID: s!.tasks[0].id)
        s = await stage.settled(job)
        await t.equal("사람이 통과로 인정하면 이어서 완료", s?.job.state, .completed)
        await t.check("사람이 인정했다는 기록", try await stage.store.verificationRecords(jobID: job.id).contains { $0.evidenceJSON.contains("\"user\"") })

        stage = try await Stage()
        stage.brain.queue(plan: plan([task("a")]))
        stage.brain.onReview { _ in nil }
        job = try await stage.start()
        s = await stage.settled(job)
        await t.equal("해석할 수 없는 검토 결과도 통과가 아니다", s?.tasks.first?.state, .blocked)

        stage = try await Stage { $0.reviewMode = .never }
        stage.brain.queue(plan: plan([task("a")]))
        job = try await stage.start()
        s = await stage.settled(job)
        await t.check("검증 수단이 없으면 통과로 치지 않는다", s?.tasks.first?.state == .blocked && s?.tasks.first?.blockedReason?.contains("검증 수단이 없습니다") == true)

        stage = try await Stage()
        stage.brain.queue(plan: plan([task("a")]))
        stage.brain.onReview { prompt in prompt.contains("최종") ? (["fail"], "verificationFailed") : (["pass"], "none") }
        job = try await stage.start()
        s = await stage.settled(job)
        await t.equal("6) 통합 검증 실패 → 완료로 표시하지 않는다", "\(s?.job.state.rawValue ?? "")/\(s?.job.finalVerification.rawValue ?? "")", "awaitingUser/failed")
        await t.equal("사람에게 바라는 것", s.flatMap { stage.coordinator.attention(for: $0) }, .finalVerificationFailed)
        try await stage.coordinator.acceptFinal(jobID: job.id)
        s = await stage.settled(job)
        await t.equal("사람이 완료로 인정", s?.job.state, .completed)
    }

    private static func shellRunner(_ t: TestKit) async throws {
        await t.group("검증 명령 실행기 (실제 셸)")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        var result = await ShellVerificationCommandRunner().run(command: "echo 빌드 중; echo 'error: 실패' >&2; exit 3", in: directory)
        await t.equal("종료 코드", result.exitCode, 3)
        await t.check("표준 출력과 오류를 함께 남긴다", result.outputTail.contains("빌드 중") && result.outputTail.contains("error: 실패"))
        result = await ShellVerificationCommandRunner().run(command: "pwd", in: directory)
        await t.check("프로젝트 폴더에서 돈다", result.exitCode == 0
                        && result.outputTail.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(directory.resolvingSymlinksInPath().lastPathComponent))
        result = await ShellVerificationCommandRunner(timeout: 0.5).run(command: "sleep 5", in: directory)
        await t.check("끝나지 않는 명령은 끊고 판정 불가로", result.exitCode == nil && result.outputTail.contains("끝나지 않아"))
        result = await ShellVerificationCommandRunner(tailLimit: 200).run(command: "yes 가나다라 | head -5000; echo 마지막줄", in: directory)
        await t.check("긴 출력은 끝부분만", result.outputTail.utf8.count <= 260 && result.outputTail.contains("마지막줄"))
    }
}

// MARK: - 앱 연결 (AppModel 이 호스트)

/// 기본 Codex 프로필은 계열 선택(`gpt-*-sol`)이라 보낼 때 모델 목록으로 푼다 — 앱처럼 기본 계정의 목록을 넣어 둔다.
func seedCodexCatalog(_ store: Store) async throws {
    let efforts = ["low", "medium", "high", "xhigh", "max"].map { ["reasoningEffort": $0] }
    try await store.replaceModelOptions(ModelCatalog.parseCodexModels([
        ["id": "gpt-6-sol", "supportedReasoningEfforts": efforts],
        ["id": "gpt-5.6-sol", "supportedReasoningEfforts": efforts],
    ]), scope: .codex(CodexAccount.defaultID))
}

/// `AppModel` 을 호스트로 돌린다: 앱의 실행 경로 · 완료 통지 전달 · 자동 인계와의 소유권 구분 · 내부 대화 숨김.
@MainActor
enum OrchestrationAppTests {

    static func run(_ t: TestKit) async {
        await t.group("앱 연결: AppModel 이 호스트")
        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-orch-app-\(UUID().uuidString).sqlite3")
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-orch-app-\(UUID().uuidString)")
        defer {
            for x in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + x) }
            try? FileManager.default.removeItem(at: folder)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let store = Store(databaseURL: dbURL)
            try await store.bootstrap()
            try await seedCodexCatalog(store)
            let project = Project(name: "앱 연결", path: folder.path)
            try await store.upsertProject(project)
            let parent = ConversationThread(projectID: project.id, title: "부모 대화")
            try await store.upsertThread(parent)

            let model = AppModel(store: store)
            let brain = FakeBrain()
            let factory: (AgentProvider) -> AgentAdapter? = { provider in
                ScriptedAgentAdapter(provider: provider) { request in brain.steps(for: request, provider: provider) }
            }
            model.runner.adapterFactory = factory
            model.reviewLanes.configure { $0.adapterFactory = factory }   // 검토 턴은 검토 레인으로 간다
            model.claudeLoginCheck = { true }
            model.cliStatus[.claude] = CLIStatus(provider: .claude, resolvedPath: "/usr/local/bin/claude", version: "fake", executable: true)
            model.orchestration.backoffScale = 0
            var settings = OrchestrationSettings()
            settings.enabled = true
            settings.requiresPlanApproval = false
            await model.orchestration.save(settings)
            model.orchestrationSettings = settings
            await model.reloadProjects()
            await model.selectThread(parent.id)

            func settled(_ jobID: String) async -> OrchestrationSnapshot? {
                let deadline = Date().addingTimeInterval(10)
                var last: OrchestrationSnapshot?
                while Date() < deadline {
                    last = try? await store.orchestrationSnapshot(jobID: jobID)
                    if let last, [.completed, .failed, .cancelled, .awaitingUser].contains(last.job.state), !model.runner.isBusy { return last }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                return last
            }

            // 1) 한도를 확인하지 못한 프로필은 후보가 아니다 (조용히 완화하지 않는다).
            let haiku = ExecutionProfile.defaults[0]
            let reason = await model.orchestrationUnavailableReason(for: haiku, project: project)
            await t.check("한도 여유를 확인하지 못하면 후보에서 뺀다", reason?.contains("확인할 수 없습니다") == true, reason ?? "nil")
            let codexReason = await model.orchestrationUnavailableReason(for: ExecutionProfile.defaults[2], project: project)
            await t.check("CLI 를 쓸 수 없는 제공자는 이유와 함께 뺀다", codexReason?.contains("CLI") == true, codexReason ?? "nil")
            settings.allowUnknownLimits = true
            model.saveOrchestrationSettings(settings)
            await model.orchestration.save(settings)
            await t.check("사람이 설정으로 허용하면 후보가 된다", await model.orchestrationUnavailableReason(for: haiku, project: project) == nil)

            // 2) 앱의 실행 경로로 끝까지.
            brain.queue(plan: OrchestrationCoordinatorTests.plan([OrchestrationCoordinatorTests.task("a"),
                                                                  OrchestrationCoordinatorTests.task("b", dependsOn: ["a"])]))
            await t.check("입력창의 자동 요청을 받는다", await model.startOrchestration(request: "기능을 만들어줘"))
            guard let job = try await store.orchestrationJobs(parentThreadID: parent.id).first else {
                await t.check("전체 작업 생성", false); return
            }
            var end = await settled(job.id)
            await t.equal("앱의 실행 경로로 계획부터 완료까지", end?.job.state, .completed)
            await t.check("Codex 를 쓸 수 없으니 Claude 프로필만 썼다", end?.attempts.allSatisfy { $0.profileID.hasPrefix("claude") } == true)

            // 3) 내부 대화는 목록에 없고, 작업 카드에서는 열 수 있다.
            await model.reloadProjects()
            await t.equal("사이드바에는 부모 대화만", model.threadsByProject[project.id]?.map(\.title), ["부모 대화"])
            await t.equal("내부 대화는 따로 알고 있다", model.internalThreadsByID.count, 4)
            if let inner = model.internalThreadsByID.values.first(where: { $0.orchestrationRole == "task" }) {
                await model.selectThread(inner.id)
                await t.check("내부 대화를 열 수 있다 (실행 기록이 거기 있다)", model.selectedThread?.id == inner.id && !model.events.isEmpty)
                await t.check("내부 대화에서는 자동 작업을 시작하지 않는다", await model.startOrchestration(request: "또") == false)
            } else {
                await t.check("내부 대화를 열 수 있다 (실행 기록이 거기 있다)", false)
            }
            await model.selectThread(parent.id)
            await t.check("부모 대화에 진행 기록이 보인다", model.events.contains { $0.text.contains("완료했습니다") })
            await t.check("화면용 상태", model.selectedOrchestration?.job.id == job.id)

            // 4) 오케스트레이션이 보낸 실행의 한도 도달은 기존 자동 인계가 건드리지 않는다.
            model.automaticHandoffEnabled = true
            brain.queue(plan: OrchestrationCoordinatorTests.plan([OrchestrationCoordinatorTests.task("c")]))
            brain.onExecute { _ in .fail(state: .rateLimited, limit: .subscriptionCap, message: "usage limit") }
            _ = await model.startOrchestration(request: "한도에 걸리는 요청")
            guard let limited = try await store.orchestrationJobs(parentThreadID: parent.id).first else { return }
            end = await settled(limited.id)
            try? await Task.sleep(nanoseconds: 300_000_000)
            await t.check("한도 도달은 오케스트레이션이 처리한다 (가용한 담당으로 전환 시도)",
                          end?.attempts.first?.failureClass == .limitReached && (end?.attempts.count ?? 0) >= 2)
            await t.check("기존 자동 인계는 시작되지 않는다 (이중 전송 방지)",
                          model.handoffCards.isEmpty && model.handoffPreparations.isEmpty)
            var handoffs = 0
            for thread in try await store.allThreads() { handoffs += try await store.handoffs(threadID: thread.id).count }
            await t.equal("인계 초안이 만들어지지 않았다", handoffs, 0)
            await t.check("실행 전후 비교가 내부 대화에도 돈다 (앱의 실행 경로를 탔다)", !model.isStartingRun && !model.isRunSlotBusy(project: project))

            // 5) 중단 · 재계획은 그 작업의 실행만 멈춘다 — 뒤에 시작한 다른 대화의 수동 실행은 끝까지 돈다.
            model.automaticHandoffEnabled = false
            try await ownRunsOnly(t, model: model, store: store, project: project, parent: parent, brain: brain)
        } catch {
            await t.check("앱 연결 검증 중 예외", false, "\(error)")
        }
        await quitCancelled(t)
    }

    // MARK: 앱 종료를 취소했을 때 (두 번째 경고의 "취소")

    /// 앱 종료로 끝낸 실행에는 완료 통지가 없다. 사람이 종료를 취소하면 `AppModel.reconcileCancelledQuit` 이 뒷정리한다:
    /// 실행 전후 비교를 맺어 같은 폴더의 다음 실행이 "겹침" 이 되지 않고, 자동 작업은 새 일을 시작하지 않은 채 사람에게 넘어가
    /// 중단 · 계속이 막히지 않는다 (쓰기 실행과 검토 레인 모두).
    private static func quitCancelled(_ t: TestKit) async {
        await t.group("앱 연결: 앱 종료를 취소했을 때")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-quit-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let folder = root.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.invalid"], ["config", "user.name", "t"],
                              ["commit", "-q", "--allow-empty", "-m", "base"]] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = arguments
                process.currentDirectoryURL = folder
                try process.run()
                process.waitUntilExit()
            }
            let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
            try await store.bootstrap()
            let project = Project(name: "종료 취소", path: folder.path)
            try await store.upsertProject(project)
            func thread(_ title: String) async throws -> ConversationThread {
                var thread = ConversationThread(projectID: project.id, title: title)
                thread.claudeSelection = ModelSelection(model: "sonnet", effort: "high")   // 모델 목록 조회(CLI)를 타지 않게
                try await store.upsertThread(thread)
                return thread
            }
            let cut = try await thread("끊길 대화"), next = try await thread("다음 대화"), parent = try await thread("부모 대화")

            let model = AppModel(store: store)
            let brain = FakeBrain()
            let adapters = AdapterLog()
            let factory: (AgentProvider) -> AgentAdapter? = { provider in
                let adapter = ScriptedAgentAdapter(provider: provider) { request in
                    guard request.prompt.hasPrefix("수동") else { return brain.steps(for: request, provider: provider) }
                    return [.emit(.sessionEstablished(sessionID: "manual", model: request.model, cliVersion: nil)),
                            .emit(.assistantDelta("쓰는 중이던 글")),
                            .waitInterrupt]
                }
                adapters.add(adapter)
                return adapter
            }
            model.runner.adapterFactory = factory
            model.reviewLanes.configure { $0.adapterFactory = factory }
            model.claudeLoginCheck = { true }
            model.cliStatus[.claude] = CLIStatus(provider: .claude, resolvedPath: "/usr/local/bin/claude", version: "fake", executable: true)
            model.orchestration.backoffScale = 0
            var settings = OrchestrationSettings()
            settings.enabled = true
            settings.requiresPlanApproval = false
            settings.allowUnknownLimits = true
            await model.orchestration.save(settings)
            model.orchestrationSettings = settings
            await model.reloadProjects()
            await model.selectThread(parent.id)

            func settle(_ condition: () -> Bool) async {
                for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 20_000_000) }
            }
            func wait(_ jobID: String, until: (OrchestrationSnapshot) -> Bool) async -> OrchestrationSnapshot? {
                let deadline = Date().addingTimeInterval(10)
                var last: OrchestrationSnapshot?
                while Date() < deadline {
                    last = try? await store.orchestrationSnapshot(jobID: jobID)
                    if let last, until(last) { return last }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                return last
            }
            func changes(_ thread: ConversationThread) async -> RunFileChanges? {
                for _ in 0..<200 {
                    let events = (try? await store.events(threadID: thread.id)) ?? []
                    if let found = events.compactMap({ RunFileChanges.decode($0) }).first { return found }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                return nil
            }
            /// 앱 종료의 첫 단계 (쓰기 실행 · 검토 레인을 거둔다). `unterminated` 면 프로세스 종료를 확인하지 못한 것처럼.
            func quit(unterminated: Bool) async -> Bool {
                for adapter in adapters.all { adapter.shutdownSucceeds = !unterminated }
                let runner = await model.runner.shutdownForQuit()
                let lanes = await model.reviewLanes.shutdownForQuit()
                return runner && lanes
            }
            /// 새 전체 작업 (부모 대화의 가장 최근 것).
            func startJob(_ request: String, _ tasks: [PlannedTask]) async throws -> OrchestrationJob? {
                brain.queue(plan: OrchestrationCoordinatorTests.plan(tasks))
                _ = await model.startOrchestration(request: request, threadID: parent.id)
                return try await store.orchestrationJobs(parentThreadID: parent.id).first
            }

            await t.check("앱 종료로 끝낸 실행이 없으면 할 일이 없다", model.reconcileCancelledQuit() == nil)

            // 1) 수동 실행: 종료 미확인으로 끊김 → 취소 → 같은 폴더의 다음 실행은 겹침이 아니다. 흐르던 응답은 확정된다.
            let sent = await model.send("수동 실행", provider: .claude, threadID: cut.id)
            await settle { model.runner.session(threadID: cut.id)?.state == .running }
            await t.check("수동 실행이 돈다", sent && model.runner.isBusy(threadID: cut.id))
            let cutRunID = model.runner.session(threadID: cut.id)?.activeRun?.id
            await t.check("종료를 확인하지 못했다", await quit(unterminated: true) == false)
            var cutRun: Run?
            if let cutRunID { cutRun = try await store.run(id: cutRunID) }
            await t.check("실행은 전달 여부 미확인 · 종료 미확인", cutRun?.state == .handoffDeliveryUnknown
                            && cutRun?.terminalReason == "app_quit_unterminated")
            let streamed = try await store.events(threadID: cut.id).filter { $0.kind == .agentMessage && $0.isMainStream }
            await t.check("흐르던 응답은 확정되어 저장", streamed.map(\.text) == ["쓰는 중이던 글"] && streamed.allSatisfy { !$0.isStreaming },
                          "\(streamed.map { ($0.text, $0.isStreaming) })")

            await model.reconcileCancelledQuit()?.value
            let cutChanges = await changes(cut)
            await t.check("끊긴 실행의 전후 비교를 맺는다 (종료 미확인을 함께 적는다)",
                          cutChanges?.compared == true && cutChanges?.processUnconfirmed == true,
                          String(describing: cutChanges.map { ($0.compared, $0.unavailable, $0.processUnconfirmed) }))
            await t.check("뒷정리는 한 번만", model.reconcileCancelledQuit() == nil)

            brain.onExecute { _ in .say("다음 실행 끝") }
            let sentNext = await model.send("다음 실행", provider: .claude, threadID: next.id)
            await settle { !model.runner.isBusy && !model.isFinishingRunChanges }
            let nextChanges = await changes(next)
            await t.check("같은 폴더의 다음 실행은 겹침이 아니다 (비교한다)",
                          sentNext && nextChanges?.compared == true && nextChanges?.unavailable == nil,
                          String(describing: nextChanges?.unavailable))
            model.runner.acknowledgeUnterminated()

            // 2) 자동 작업의 실행: 종료 미확인으로 끊김 → 새 일 없이 사람에게 (전달 여부 미확인) → 중단하면 중단된다.
            brain.onExecute { _ in .hang }
            guard let unknownJob = try await startJob("끊길 자동 작업", [OrchestrationCoordinatorTests.task("a")]) else {
                await t.check("전체 작업 생성", false); return
            }
            let running = await wait(unknownJob.id) { $0.attempts.first?.state == .running }
            let jobRunID = running?.attempts.first?.runID
            await t.check("자동 작업의 실행이 돈다", jobRunID.map { model.orchestration.owns(runID: $0) } == true)
            let sentBefore = brain.requests.count
            _ = await quit(unterminated: true)
            await t.check("취소하기 전에는 자동 작업이 그 실행을 아직 들고 있다",
                          jobRunID.map { model.orchestration.owns(runID: $0) } == true)
            await model.reconcileCancelledQuit()?.value
            var s = try await store.orchestrationSnapshot(jobID: unknownJob.id)
            await t.equal("종료 미확인: 시도는 전달 여부 미확인 · 전체는 사람에게",
                          "\(s?.job.state.rawValue ?? "")/\(s?.attempts.map(\.state.rawValue) ?? [])", "awaitingUser/[\"deliveryUnknown\"]")
            await t.check("실행 기록을 치웠다", jobRunID.map { !model.orchestration.owns(runID: $0) } == true)
            await t.check("새 일을 시작하지 않는다", brain.requests.count == sentBefore && !model.runner.isBusy)
            await t.equal("사람에게 바라는 것: 그 시도의 확인", s.flatMap { model.orchestration.attention(for: $0) },
                          .deliveryUnknown(attemptIDs: s?.attempts.map(\.id) ?? []))
            try await model.orchestration.cancel(jobID: unknownJob.id)
            s = await wait(unknownJob.id) { $0.job.state.isTerminal }
            await t.equal("중단하면 중단된다 (중단 중에 멈추지 않는다)", s?.job.state, .cancelled)
            model.runner.acknowledgeUnterminated()

            // 3) 자동 작업의 실행: 종료를 확인함 → 사람이 멈춘 것과 같다 (작업을 막고 묻는다) → 계속하면 끝까지.
            let once = OrchestrationCoordinatorTests.Flag()
            brain.onExecute { _ in once.takeOnce() ? .hang : .say("했습니다") }
            guard let cancelledJob = try await startJob("끊겼다 이어 갈 자동 작업", [OrchestrationCoordinatorTests.task("b")]) else {
                await t.check("전체 작업 생성", false); return
            }
            _ = await wait(cancelledJob.id) { $0.attempts.first?.state == .running }
            await t.check("종료를 확인했다", await quit(unterminated: false))
            await model.reconcileCancelledQuit()?.value
            s = try await store.orchestrationSnapshot(jobID: cancelledJob.id)
            await t.equal("종료 확인: 시도는 취소 · 작업은 막힘 · 전체는 사람에게",
                          "\(s?.job.state.rawValue ?? "")/\(s?.tasks.first?.state.rawValue ?? "")/\(s?.attempts.first?.state.rawValue ?? "")",
                          "awaitingUser/blocked/cancelled")
            await t.check("막힌 까닭은 앱 종료", s?.tasks.first?.blockedReason?.contains("앱 종료") == true, s?.tasks.first?.blockedReason ?? "")
            try await model.orchestration.resume(jobID: cancelledJob.id)
            s = await wait(cancelledJob.id) { $0.job.state.isTerminal || $0.job.state == .awaitingUser }
            await t.equal("계속하면 다시 시도해 끝까지", s?.job.state, .completed)

            // 4) 검토 레인의 실행: 끊긴 검토는 판정하지 않고 치운다 → 일시 정지 → 계속하면 검증부터 다시 해 끝까지.
            brain.onExecute { _ in .say("했습니다") }
            let reviewOnce = OrchestrationCoordinatorTests.Flag()
            brain.onPanelReview { prompt, _ in
                reviewOnce.takeOnce() ? .hang : .verdict(Array(repeating: "pass", count: FakeBrain.criteriaCount(in: prompt)))
            }
            guard let reviewJob = try await startJob("검토가 끊길 자동 작업", [OrchestrationCoordinatorTests.task("c")]) else {
                await t.check("전체 작업 생성", false); return
            }
            _ = await wait(reviewJob.id) { $0.attempts.first?.state == .verifying }
            await settle { model.reviewLanes.isBusy && !model.orchestration.activeReviewers.isEmpty }
            await t.check("검토 레인에서 검토가 돈다", model.reviewLanes.isBusy && !model.orchestration.activeReviewers.isEmpty)
            await t.check("검토 레인도 거둔다", await quit(unterminated: false))
            await model.reconcileCancelledQuit()?.value
            s = try await store.orchestrationSnapshot(jobID: reviewJob.id)
            await t.equal("끊긴 검토: 판정 없이 일시 정지 · 시도는 검증 중 그대로",
                          "\(s?.job.state.rawValue ?? "")/\(s?.attempts.first?.state.rawValue ?? "")", "paused/verifying")
            await t.check("검토단을 치웠다", model.orchestration.activeReviewers.isEmpty && !model.reviewLanes.isBusy)
            try await model.orchestration.resume(jobID: reviewJob.id)
            s = await wait(reviewJob.id) { $0.job.state.isTerminal || $0.job.state == .awaitingUser }
            await t.equal("계속하면 검증부터 다시 해 끝까지", s?.job.state, .completed)
        } catch {
            await t.check("앱 종료 취소 검증 중 예외", false, "\(error)")
        }
    }

    private static func ownRunsOnly(_ t: TestKit, model: AppModel, store: Store, project: Project,
                                    parent: ConversationThread, brain: FakeBrain) async throws {
        await t.group("앱 연결: 중단 · 재계획은 그 작업의 실행만 멈춘다")
        // 수동 실행은 검증이 신호를 줄 때까지 돈다 (가장 최근에 시작한 실행이 된다).
        let adapters = AdapterLog()
        model.runner.adapterFactory = { provider in
            let adapter = ScriptedAgentAdapter(provider: provider) { request in
                guard request.prompt.hasPrefix("수동") else { return brain.steps(for: request, provider: provider) }
                return [.emit(.sessionEstablished(sessionID: "manual", model: request.model, cliVersion: nil)),
                        .emit(.assistantMessage("수동 작업 중")),
                        .waitSignal("manual"),
                        .finish(AgentTurnResult(state: .completed, terminalReason: "completed", sessionID: "manual",
                                                resultText: "수동 끝"))]
            }
            adapters.add(adapter)
            return adapter
        }
        var manual = ConversationThread(projectID: project.id, title: "수동 대화")
        manual.claudeSelection = ModelSelection(model: "fake-model")
        try await store.upsertThread(manual)
        await model.reloadProjects()

        func wait(_ jobID: String, until: (OrchestrationSnapshot) -> Bool) async -> OrchestrationSnapshot? {
            let deadline = Date().addingTimeInterval(10)
            var last: OrchestrationSnapshot?
            while Date() < deadline {
                last = try? await store.orchestrationSnapshot(jobID: jobID)
                if let last, until(last) { return last }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return last
        }
        func settle(_ condition: () -> Bool) async {
            for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        /// 다른 대화에서 수동 실행을 시작하고, 돌기 시작하면 그 실행 ID.
        func startManual(_ prompt: String) async -> String? {
            guard await model.send(prompt, provider: .claude, threadID: manual.id) else { return nil }
            await settle { model.runner.session(threadID: manual.id)?.state == .running }
            return model.runner.session(threadID: manual.id)?.activeRun?.id
        }
        func runState(_ runID: String?) async -> RunState? {
            guard let runID else { return nil }
            return try? await store.run(id: runID)?.state
        }
        func finishManual(_ runID: String?) async -> RunState? {
            for adapter in adapters.all { adapter.signal("manual") }
            await settle { !model.runner.isBusy(threadID: manual.id) }
            return await runState(runID)
        }

        // 중단.
        brain.onExecute { _ in .hang }
        brain.queue(plan: OrchestrationCoordinatorTests.plan([OrchestrationCoordinatorTests.task("d")]))
        _ = await model.startOrchestration(request: "중단할 요청")
        guard let cancelled = try await store.orchestrationJobs(parentThreadID: parent.id).first else {
            await t.check("전체 작업 생성", false); return
        }
        let executing = await wait(cancelled.id) { $0.attempts.first?.state == .running }
        let manualRun = await startManual("수동 실행")
        await t.check("다른 대화에서 수동 실행이 돈다", manualRun != nil && model.runner.activeSessions.count == 2)
        try await model.orchestration.cancel(jobID: cancelled.id)
        let end = await wait(cancelled.id) { $0.job.state == .cancelled }
        await t.equal("작업은 취소로 끝난다", end?.job.state, .cancelled)
        let jobRun = executing?.attempts.first?.runID
        await t.equal("작업의 실행만 멈춘다", await runState(jobRun), .cancelled)
        await t.check("수동 실행은 계속 돈다", model.runner.isBusy(threadID: manual.id)
                        && model.runner.session(threadID: manual.id)?.state == .running)
        await t.equal("수동 실행은 끝까지 간다", await finishManual(manualRun), .completed)

        // 재계획 (질문에 답하거나 요구를 바꿈): 이전 계획의 실행만 멈추고, 새 계획은 수동 실행이 끝난 뒤 이어 간다.
        let hold = OrchestrationCoordinatorTests.Flag()
        brain.onExecute { _ in hold.takeOnce() ? .hang : .say("했습니다") }
        brain.queue(plan: OrchestrationCoordinatorTests.plan([OrchestrationCoordinatorTests.task("old")]))
        brain.queue(plan: OrchestrationCoordinatorTests.plan([OrchestrationCoordinatorTests.task("new")]))
        _ = await model.startOrchestration(request: "바뀔 요청")
        guard let replanned = try await store.orchestrationJobs(parentThreadID: parent.id).first,
              replanned.id != cancelled.id else {
            await t.check("두 번째 전체 작업 생성", false); return
        }
        let old = await wait(replanned.id) { $0.attempts.first?.state == .running }
        let manualRun2 = await startManual("수동 실행 2")
        await t.check("재계획 전: 수동 실행이 함께 돈다", manualRun2 != nil)
        try await model.orchestration.answer(jobID: replanned.id, text: "아니, new 만 해줘")
        let oldRun = old?.attempts.first?.runID
        await settle { !(oldRun.map { model.runner.session(runID: $0) != nil } ?? false) }
        await t.equal("이전 계획의 실행만 멈춘다", await runState(oldRun), .cancelled)
        await t.check("재계획 뒤에도 수동 실행은 돈다", model.runner.isBusy(threadID: manual.id))
        await t.equal("수동 실행은 끝까지 간다 (재계획)", await finishManual(manualRun2), .completed)
        let done = await wait(replanned.id) { [.completed, .failed, .cancelled, .awaitingUser].contains($0.job.state) }
        await t.equal("새 계획으로 완료", done?.job.state, .completed)
        await t.equal("이전 계획의 작업은 실행하지 않는다", done?.tasks.map { "\($0.planTaskID):\($0.state.rawValue)" },
                      ["old:superseded", "new:succeeded"])
    }
}

// MARK: - 실제 CLI 로 끝까지 (`inttest orchestration`)

/// 계획(Claude) → 실행 → 검토(Codex) → 최종 통합 검증을 실제 CLI 로 작은 임시 프로젝트에서 돌린다.
/// 모델은 싼 것으로 고정한다. Codex 의 astra 는 쓰지 않는다.
@MainActor
enum OrchestrationLiveTests {
    static func run(_ t: TestKit, _ e: LiveTests.Env) async {
        await t.group("오케스트레이션 · 실제 CLI")
        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-orch-live-\(UUID().uuidString).sqlite3")
        defer { for x in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + x) } }
        do {
            let store = Store(databaseURL: dbURL)
            try await store.bootstrap()
            let project = Project(name: "orchestration-live", path: e.root.path)
            try await store.upsertProject(project)
            let parent = ConversationThread(projectID: project.id, title: "자동 작업 검증")
            try await store.upsertThread(parent)

            let runner = RunCoordinator(store: store, environment: CLIEnvironment())
            runner.maxConcurrentRuns = 1
            runner.claudePermissionMode = "acceptEdits"
            runner.codexSandboxMode = "workspace-write"
            runner.codexApprovalPolicy = "on-request"
            await runner.loadPrices()
            let reviewLanes = ReadOnlyRunPool(store: store, environment: CLIEnvironment())
            await reviewLanes.loadPrices()
            let host = FakeOrchestrationHost(runner: runner, reviewLanes: reviewLanes)
            host.projects[project.id] = project
            host.autoApprove = true
            // 임시 폴더는 git 저장소가 아니다. 앱이 주는 git 변경 대신 폴더에 실제로 있는 파일을 그대로 알려 준다.
            host.workspaceEvidence = { project in
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: project.path)) ?? []).sorted()
                let lines = names.map { name -> String in
                    let size = (try? FileManager.default.attributesOfItem(atPath: project.path + "/" + name)[.size] as? Int) ?? nil
                    return "- \(name)" + (size.map { " (\($0) bytes)" } ?? "")
                }
                return ("(git 저장소가 아닙니다. 작업을 시작할 때 이 폴더는 비어 있었습니다.)\n지금 폴더에 있는 파일:\n"
                        + (lines.isEmpty ? "(없음)" : lines.joined(separator: "\n")), names.joined(separator: ","))
            }
            runner.delegate = host
            reviewLanes.configure { $0.delegate = host }
            let coordinator = OrchestrationCoordinator(store: store, commandRunner: ShellVerificationCommandRunner(timeout: 60))
            coordinator.host = host
            host.orchestration = coordinator

            var settings = OrchestrationSettings()
            settings.enabled = true
            settings.requiresPlanApproval = false
            settings.profiles = [
                ExecutionProfile(id: "claude-haiku", name: "Claude Haiku", provider: .claude, model: "haiku", tier: 1),
                ExecutionProfile(id: "codex-terra", name: "Codex Terra", provider: .codex, model: "gpt-5.6-terra", effort: "low", tier: 2),
            ]
            settings.plannerProfileID = "claude-haiku"
            settings.reviewerProfileID = "codex-terra"
            settings.verificationCommands[project.id] = "test -f greeting.txt && grep -q HELLO greeting.txt"
            await coordinator.save(settings)

            let greeting = e.root.appendingPathComponent("greeting.txt")
            try? FileManager.default.removeItem(at: greeting)
            let job = try await coordinator.start(
                request: "이 폴더에 greeting.txt 파일을 만들고 그 안에 HELLO 라고 한 줄 써 주세요. 다른 파일은 건드리지 마세요.",
                parentThread: parent, project: project)

            let deadline = Date().addingTimeInterval(900)
            var end: OrchestrationSnapshot?
            while Date() < deadline {
                end = try await store.orchestrationSnapshot(jobID: job.id)
                if let end, [.completed, .failed, .cancelled, .awaitingUser].contains(end.job.state),
                   !runner.isBusy, !reviewLanes.isBusy { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let notes = try await store.events(threadID: parent.id).filter { $0.kind == .systemNotice }.map(\.text)
            for note in notes { await t.note(note.replacingOccurrences(of: "\n", with: " / ").prefix(200).description) }
            await t.equal("전체 작업 완료", end?.job.state, .completed)
            await t.check("작업이 모두 검증을 통과", end?.activeTasks.allSatisfy { $0.state == .succeeded || $0.optional } == true,
                          end?.activeTasks.map { "\($0.title): \($0.state.rawValue) \($0.blockedReason ?? "")" }.joined(separator: " | ") ?? "")
            await t.equal("최종 통합 검증 통과", end?.job.finalVerification, .passed)
            await t.check("파일이 실제로 만들어졌다", (try? String(contentsOf: greeting, encoding: .utf8))?.contains("HELLO") == true)
            let records = try await store.verificationRecords(jobID: job.id)
            await t.check("검증 명령이 돌았고 통과했다", records.contains { $0.criterion.hasPrefix("검증 명령") && $0.outcome == .pass })
            await t.check("검토 에이전트가 조건을 판정했다", records.contains { $0.evidenceJSON.contains("reviewer") })
            // 최종 통합 검증은 검토단이다 (기본 설정): Codex 와 Claude 가 검토 레인에서 동시에 검토한다.
            let finalRecords = records.filter { $0.taskID == nil && $0.evidenceJSON.contains("reviewer") }
            await t.check("최종 통합 검증을 두 제공자가 함께 판정했다",
                          finalRecords.contains { $0.evidenceJSON.contains("Codex Terra") } && finalRecords.contains { $0.evidenceJSON.contains("Claude Haiku") },
                          finalRecords.map(\.evidenceJSON).joined(separator: " | ").prefix(300).description)
            await t.equal("검토단 둘이 실제로 동시에 돌았다", host.peakConcurrentReviews, 2)
            var models: [String] = []
            for thread in try await store.orchestrationThreads(jobID: job.id) {
                models += try await store.runs(threadID: thread.id).compactMap(\.model)
            }
            await t.check("astra 를 쓰지 않았다", !models.contains { $0.lowercased().contains("astra") }, models.joined(separator: ", "))
            await t.check("부모 대화에는 실행이 없다", try await store.runs(threadID: parent.id).isEmpty)
        } catch {
            await t.check("실제 CLI 실행 중 예외", false, "\(error)")
        }
    }
}

/// 시나리오 안에서 몇 번째 호출인지 세는 작은 도구.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

final class AdapterLog: @unchecked Sendable {
    private let lock = NSLock()
    private var adapters: [ScriptedAgentAdapter] = []
    func add(_ adapter: ScriptedAgentAdapter) { lock.lock(); adapters.append(adapter); lock.unlock() }
    var all: [ScriptedAgentAdapter] { lock.lock(); defer { lock.unlock() }; return adapters }
}

extension Array {
    func asyncFlatMap<T>(_ transform: (Element) async throws -> [T]) async rethrows -> [T] {
        var out: [T] = []
        for element in self { out += try await transform(element) }
        return out
    }
}
