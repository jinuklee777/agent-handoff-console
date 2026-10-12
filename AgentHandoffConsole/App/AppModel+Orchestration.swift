import Foundation

// 자동 작업(오케스트레이션)과 앱의 연결.
// 코디네이터는 판단과 순서를 맡고, 여기서는 앱의 실행 경로 · 가용성 · 작업 폴더 상태 · 화면 갱신을 내준다.
// 완료 통지의 전달과 자동 인계와의 소유권 구분은 `AppModel.runCoordinator(_:didFinish:…)` 에 있다.

extension AppModel: OrchestrationHost {

    // MARK: - OrchestrationHost

    /// 자동 작업의 쓰기 실행(계획 · 하위 작업)을 지금 이 폴더에서 시작할 수 없다: 그 폴더에서 다른 실행이 파일을 바꾸고 있거나,
    /// 시작하는 중이거나, 앱의 git 쓰기가 돌거나, 검토단이 그 폴더를 읽고 있다. **폴더 단위다** — 다른 폴더의 수동 실행은 막지 않는다.
    /// 자동 작업 자신의 실행은 여전히 한 번에 하나다 (스케줄러가 한 번에 하나만 보낸다).
    func isRunSlotBusy(project: Project) -> Bool {
        !writeSessions(inProjectPath: project.path).isEmpty || isStartingRun(projectPath: project.path)
            || (runningGitOperation != nil && runningGitProjectPath == project.path)
            || worktreeActivity(threadID: nil, path: project.path) != nil
            || isReviewing(inProjectPath: project.path)
    }

    func canLaunchReview(project: Project) -> Bool {
        writeSessions(inProjectPath: project.path).isEmpty && !isStartingRun(projectPath: project.path)
            && !(runningGitOperation != nil && runningGitProjectPath == project.path)
            && worktreeActivity(threadID: nil, path: project.path) == nil && reviewLanes.hasFreeLane
    }

    /// 검토 턴은 검토 레인으로 간다 (읽기 전용 · 동시에 여럿). 실행 전후 비교가 없다 — 파일을 바꾸지 못한다.
    func orchestrationLaunchReview(prompt: String, thread: ConversationThread, project: Project, provider: AgentProvider,
                                   outputSchema: String) async throws -> Run {
        guard canLaunchReview(project: project) else { throw RunCoordinator.StartError.busy }
        return try await reviewLanes.send(prompt: prompt, thread: thread, project: project, provider: provider,
                                          account: accounts.ref(thread.codexAccountID),
                                          turn: AgentTurnOptions(readOnly: true, outputSchema: outputSchema))
    }

    func orchestrationLaunch(prompt: String, thread: ConversationThread, project: Project, provider: AgentProvider,
                             codexAccountID: String?, turn: AgentTurnOptions) async throws -> Run {
        try await launchOrchestrationTurn(prompt: prompt, thread: thread, project: project, provider: provider, turn: turn)
    }

    /// 실행 ID 로 그 세션을 찾아 멈춘다 — 쓰기 슬롯이든 검토 레인이든. "가장 최근 실행" 이 아니다: 다른 칸의 수동 실행이나
    /// 일시 정지한 다른 작업의 검토가 함께 돌고 있을 수 있다.
    func orchestrationInterrupt(runIDs: [String]) async {
        for runID in runIDs {
            if let session = runner.session(runID: runID) {
                await session.interrupt()
            } else {
                await reviewLanes.coordinator.session(runID: runID)?.interrupt()
            }
        }
    }

    func orchestrationProject(for job: OrchestrationJob) async -> Project? {
        let id = job.projectID
        var found = projects.first { $0.id == id }
        if found == nil { found = try? await store.projects().first { $0.id == id } }
        guard let project = found else { return nil }
        // 부모 대화가 독립 작업 폴더에서 일하면 자동 작업도 그 폴더에서 (계획 · 하위 작업 · 검토 · 검증 명령 모두).
        var parent = allThreads().first { $0.id == job.parentThreadID }
        if parent == nil { parent = (try? await store.thread(id: job.parentThreadID)) ?? nil }
        return parent.map { folderProject(for: $0, in: project) } ?? project
    }

    /// 자동 인계가 대상을 고를 때와 같은 기준을 쓴다 (`AutomaticHandoffGate.targetProblems`):
    /// CLI 사용 가능 · 로그인 확인 · 한도 여유 **확인**. 확인하지 못한 한도는 여유로 치지 않는다 (설정으로만 허용).
    func orchestrationUnavailableReason(for profile: ExecutionProfile, project: Project) async -> String? {
        if profile.provider == .gemini, !antigravityAllowed(projectID: project.id) {
            return "이 프로젝트에서 Antigravity 를 허용하지 않았습니다."
        }
        let accountID = profile.provider == .codex ? (profile.codexAccountID ?? CodexAccount.defaultID) : ""
        let authenticated: Bool
        switch profile.provider {
        case .claude:
            if let cached = orchestrationClaudeLogin, Date().timeIntervalSince(cached.at) < 120 {
                authenticated = cached.value
            } else {
                authenticated = await claudeLoginCheck() == true   // 확인하지 못한 것은 로그인된 것으로 치지 않는다
                orchestrationClaudeLogin = (authenticated, Date())
            }
        case .codex: authenticated = accounts.accountOrDefault(accountID).authStatus == .loggedIn
        case .gemini: authenticated = true   // agy 는 로그인 상태를 따로 알려 주지 않는다. 실행 결과로 드러난다.
        }
        let scope = AgentScope(provider: profile.provider, accountID: accountID)
        var problems = AutomaticHandoffGate.targetProblems(cliUsable: cliStatus[profile.provider]?.isUsable ?? false,
                                                           authenticated: authenticated, limit: limits.snapshot(scope))
        if orchestrationSettings.allowUnknownLimits || profile.provider == .gemini {
            problems.removeAll { $0.contains("확인할 수 없습니다") }   // Antigravity 의 한도는 모델 묶음마다라 계정 전체 여유로 읽지 않는다
        }
        return problems.isEmpty ? nil : problems.joined(separator: " ")
    }

    /// 검토 담당에게 줄 작업 폴더의 변경. Claude 검토 턴은 셸을 쓸 수 없어 git 을 직접 볼 수 없다.
    /// 저장소가 정한 filter · diff 드라이버를 끄고 색인을 쓰지 않고 읽는다 (`GitInspector.readEnvironment`).
    func orchestrationWorkspaceEvidence(project: Project) async -> (text: String, fingerprint: String?) {
        let childEnv = await environment.childEnvironment()
        guard let git = GitInspector.findGit(environment: childEnv) else { return ("(git 을 찾지 못했습니다)", nil) }
        guard let env = await GitInspector.readEnvironment(git: git, at: project.url, environment: childEnv) else {
            return ("(저장소의 git 설정을 확인하지 못해 작업 폴더의 변경을 읽지 않았습니다)", nil)
        }
        func run(_ arguments: [String]) async -> String {
            let result = await CLIEnvironment.captureOutput(executable: git, arguments: GitInspector.commandArguments(arguments), environment: env,
                                                            workingDirectory: project.url, timeout: 20)
            if case .success(let output) = result { return output }
            return ""
        }
        let status = await run(["status", "--porcelain=v1", "--untracked-files=all"] + GitInspector.submoduleReadArguments)
        guard !status.isEmpty else {
            let head = await run(["rev-parse", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            return ("(작업 폴더에 변경이 없습니다)", head.isEmpty ? nil : head + ":clean")
        }
        // 색인을 새로 쓰지 않아 시각만 바뀐 이진 파일도 --stat 에 나온다 — status 에 없는 그 줄은 뺀다.
        let stat = GitInspector.statWithoutStatDirtyBinaries(
            await run(["diff", "HEAD", "--stat"] + GitInspector.readDiffArguments), status: status)
        let diff = await run(["diff", "HEAD", "--unified=2"] + GitInspector.readDiffArguments)
        let head = await run(["rev-parse", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in (status + diff).utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let text = "git status:\n\(status)\ngit diff --stat:\n\(stat)\ngit diff:\n\(OrchestrationPrompts.clip(diff, 12_000))"
        return (text, "\(head):\(String(hash, radix: 16))")
    }

    func orchestrationDidAppend(event: ThreadEvent) {
        threadStates[event.threadID]?.upsert(event)
    }

    func orchestrationDidChange(jobID: String) {
        // 새 내부 대화가 생겼을 수 있다. 작업 카드에서 열 수 있게 알아 둔다.
        Task {
            for thread in (try? await store.orchestrationThreads(jobID: jobID)) ?? [] {
                internalThreadsByID[thread.id] = thread
            }
        }
    }

    // MARK: - 화면이 부르는 것

    /// 지금 고른(포커스) 대화의 자동 작업 (가장 최근 것).
    var selectedOrchestration: OrchestrationSnapshot? { selectedThread.flatMap(orchestrationSnapshot(for:)) }

    /// 그 대화의 자동 작업 (가장 최근 것). 내부 대화에는 카드를 띄우지 않는다.
    func orchestrationSnapshot(for thread: ConversationThread) -> OrchestrationSnapshot? {
        thread.orchestrationJobID == nil ? orchestration.snapshotsByThread[thread.id] : nil
    }

    func saveOrchestrationSettings(_ settings: OrchestrationSettings) {
        orchestrationSettings = settings
        Task { await orchestration.save(settings) }
    }

    /// 입력창의 "자동"으로 보낸 요청.
    @discardableResult
    func startOrchestration(request: String, threadID: String? = nil) async -> Bool {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = threadID.flatMap { id in allThreads().first { $0.id == id } } ?? selectedThread
        guard !text.isEmpty, let thread = target, !thread.isInternal,
              let project = folderProject(for: thread) else { return false }
        // 인계 카드(준비 · 전달 중 포함)가 있는 대화는 자동 작업을 시작하지 않는다 — 다음 일은 인계 뒤 받는 쪽에게 간다.
        guard !hasHandoffActivity(threadID: thread.id), queueHolds[thread.id] == nil else {
            banner = BannerMessage(text: "인계 카드가 있어 자동 작업을 시작하지 않았습니다.", isError: true, threadID: thread.id)
            return false
        }
        do {
            try await orchestration.start(request: text, parentThread: thread, project: project)
            return true
        } catch {
            banner = BannerMessage(text: error.localizedDescription, isError: true)
            return false
        }
    }

    /// 작업 카드의 단추들. 실패는 배너로 알린다.
    func orchestrationAction(_ action: @escaping (OrchestrationCoordinator) async throws -> Void) {
        Task {
            do { try await action(orchestration) } catch {
                banner = BannerMessage(text: error.localizedDescription, isError: true)
            }
        }
    }
}
