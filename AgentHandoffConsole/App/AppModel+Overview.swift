import Foundation

/// 에이전트 현황(가운데 칸 "현황", ⌃⌘0)의 앱 쪽 — 사실 모으기와 동작 잇기. 판정 · 글은 순수 `App/Overview.swift`, 화면은
/// `UI/OverviewView.swift`.
///
/// - 행: 도는 실행(쓰기 실행 · 자동 작업의 검토 레인) · 사람을 기다리는 인계 카드(검토 · 카운트다운) · 다른 Codex 계정에서 같은 세션을
///   이어 가려는 카운트다운(`codexSwitchCountdowns` — 인계 카드의 카운트다운과 같은 자리) · 사람을 기다리는 자동 작업.
///   한 대화에 한 행, 무엇을 기다리는지는 칸 머리와 같은 사실(`paneStatusInput`)로 고른다.
/// - 지금 하는 일 한 줄은 그 대화의 기록이 있어야 한다 — 현황이 보이는 동안 실행 중인 대화의 상자를 들고 있는다
///   (`overviewVisible` → `openThreadIDs`, 처음 보일 때 `loadOverviewThreads` 가 읽는다). 칸에 열지 않은 대화도 실시간 기록이 그 상자로 간다.
/// - 현황에서의 허용 · 거절 · 답은 대화의 카드와 같은 길(`runner.respond`)이다. 허용할 수 있는 요청은 `Overview.approvalChoice` 가 정한다.
extension AppModel {
    // MARK: 행

    /// 현황의 행 (정렬 전 — 구역 · 순서는 `Overview.groups`).
    func overviewItems(now: Date = Date()) -> [Overview.Item] {
        var ids: [String] = activeSessions.compactMap(\.activeThreadID)
        ids += handoffCards.filter { $0.value.attention != .draft }.keys.sorted()
        ids += codexSwitchCountdowns.keys.sorted()
        ids += orchestration.snapshotsByThread.keys.sorted()
        var seen = Set<String>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted, let thread = paneThread(id) else { return nil }
            return overviewItem(thread, now: now)
        }
    }

    /// 현황이 보는 대화 — 상자를 들고 있을 것 (실행 중 · 인계 카드 · 자동 작업).
    var overviewThreadIDs: Set<String> {
        Set(activeSessions.compactMap(\.activeThreadID))
    }

    private func overviewItem(_ thread: ConversationThread, now: Date) -> Overview.Item? {
        let session = runner.session(threadID: thread.id) ?? reviewLanes.coordinator.session(threadID: thread.id)
        let live = session.flatMap { $0.isBusy ? $0 : nil }
        let input = paneStatusInput(for: thread)
        let status = PaneStatus.make(input)
        let card = handoffCards[thread.id]

        let kind: Overview.Kind
        let since: Date
        if let live, let approval = live.pendingApprovals.first(where: { !$0.isQuestion }) {
            kind = .approval
            since = approval.createdAt
        } else if let live, let asked = live.pendingApprovals.first(where: \.isQuestion) {
            kind = .question
            since = asked.createdAt
        } else if let live, let question = live.pendingQuestions.first {
            kind = .question
            since = question.createdAt
        } else if input.handoffReview, let card {
            kind = .handoffReview(status?.text ?? "인계 검토")
            since = card.draft.handoff.createdAt
        } else if input.orchestration != nil, let status, status.needsResponse {
            kind = .orchestration(status.text)
            since = orchestrationSnapshot(for: thread)?.job.updatedAt ?? thread.updatedAt
        } else if let card, case .countingDown(let deadline, _) = card.phase {
            kind = .handoffCountdown(deadline: deadline)
            since = card.draft.handoff.createdAt
        } else if let countdown = codexSwitchCountdowns[thread.id] {
            // 칸 머리와 같은 자리 — 자동 인계 카운트다운 다음 (둘이 함께 걸리지는 않는다).
            kind = .codexSwitch(deadline: countdown.deadline)
            since = countdown.deadline.addingTimeInterval(-TimeInterval(countdown.delay))
        } else if let live, live.isWaitingOnBackground {
            kind = .background(live.unfinishedSubAgentCount)
            since = live.waitingSince ?? live.activeRun?.startedAt ?? now
        } else if let live {
            kind = .working
            since = live.activeRun?.startedAt ?? now
        } else {
            return nil
        }

        let folder = folderProject(for: thread)
        let project = mainProject(for: thread) ?? folder
        var item = Overview.Item(threadID: thread.id, title: thread.title,
                                 project: project.map(projectDisplayName) ?? "프로젝트 없음",
                                 branch: thread.worktree?.branch ?? workspace(forPath: folder?.path)?.git?.branch,
                                 inWorktree: thread.worktree != nil,
                                 provider: live?.activeProvider ?? thread.preferredProvider, kind: kind, since: since,
                                 automatic: thread.isInternal)
        item.running = live != nil
        guard let live else { return item }

        if !kind.needsResponse {
            let pane = threadStates[thread.id]
            let questionOnly = live.pendingApprovals.isEmpty && !live.pendingQuestions.isEmpty
            let (activity, work) = RunActivity.read(state: live.state, runID: live.activeRun?.id,
                                            waitingOnBackground: live.isWaitingOnBackground,
                                            backgroundCount: live.unfinishedSubAgentCount,
                                            events: pane?.mainEvents ?? [], streaming: pane?.streamingMainEvent,
                                            projectPath: folder?.path, questionOnly: questionOnly,
                                            summary: live.progressSummary)
            let (head, detail) = Self.splitActivity(activity.text)
            item.activity = head
            item.activityDetail = detail
            item.work = work
        }
        item.meta = overviewMeta(thread, session: live)
        if input.sharesFolder, let path = live.activeProjectPath,
           let other = writeSessions(inProjectPath: path).first(where: { $0 !== live })?.activeThreadID,
           let otherTitle = paneThread(other)?.title {
            item.note = "같은 폴더에서 「\(otherTitle)」도 실행 중 — 실행 전후 비교는 하지 않습니다"
        }
        if case .background = kind {
            item.subtasks = live.subAgents.filter { !$0.isInternalStep }.map { info in
                Overview.Subtask(title: info.title, status: Self.subtaskStatus(info, now: now), finished: info.status.isFinished)
            }
        }
        return item
    }

    /// "명령 실행 중 · make test" → ("명령 실행 중", "make test"). 대상이 없으면 그대로.
    static func splitActivity(_ text: String) -> (String, String?) {
        guard let range = text.range(of: " · ") else { return (text, nil) }
        let detail = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (String(text[..<range.lowerBound]), detail.isEmpty ? nil : detail)
    }

    private static func subtaskStatus(_ info: SubAgentInfo, now: Date) -> String {
        switch info.status {
        case .completed: return "완료"
        case .stopped: return "멈춤"
        case .failed: return "실패"
        case .running:
            if info.kind == .shell { return "백그라운드 명령" }
            return DisplayFormat.elapsed(seconds: max(0, Int(now.timeIntervalSince(info.startedAt))))
        }
    }

    /// 행의 메타 조각 — 모델 · 강도, 여러 Codex 계정이면 계정 이름, API 크레딧으로 실행하면 그 사실, 남은 하위 작업.
    private func overviewMeta(_ thread: ConversationThread, session: RunSession) -> [String] {
        var parts: [String] = []
        let provider = session.activeProvider ?? thread.preferredProvider
        if let text = selectionText(for: thread, provider: provider, accountID: session.activeAccount?.id) {
            parts.append(text)
        }
        if provider == .codex, accounts.hasMultiple, let label = session.activeAccount?.label { parts.append(label + " 계정") }
        if provider == .claude, session.usesClaudeAPI { parts.append("API 크레딧") }
        let subAgents = session.subAgents.filter { !$0.isInternalStep }
        if !subAgents.isEmpty {
            let done = subAgents.filter(\.status.isFinished).count
            parts.append("하위 \(subAgents.count)" + (done > 0 ? " · \(done) 완료" : ""))
        }
        return parts
    }

    var overviewCounts: Overview.Counts { Overview.counts(overviewItems()) }

    /// 메뉴의 승인 허용 · 거절이 갈 대화 — 현황이 보이면 현황에서 고른 행, 아니면 포커스 칸의 대화.
    var approvalShortcutThreadID: String? { overviewVisible ? overviewSelection : selectedThreadID }

    // MARK: 상자 들고 있기

    /// 현황이 보인다 · 사라졌다. 보이는 동안 실행 중인 대화의 상자를 들고 있고(`openThreadIDs`), 사라지면 거둔다.
    func setOverviewVisible(_ visible: Bool) async {
        guard overviewVisible != visible else { return }
        overviewVisible = visible
        if visible { await loadOverviewThreads() } else { pruneThreadStates() }
    }

    /// 실행 중인 대화 가운데 상자가 없거나 읽지 않은 것을 읽는다 (현황이 보이는 동안 새 실행이 시작될 때도 — 화면이 부른다).
    func loadOverviewThreads() async {
        guard overviewVisible else { return }
        for id in overviewThreadIDs where threadStates[id]?.loaded != true {
            await reloadThreadData(threadID: id, create: true)
        }
    }

    // MARK: 동작

    /// 행을 눌렀다 — 그 대화로 (가운데 칸이 대화로 바뀐다). 인계 카드가 있으면 그 카드로.
    func openFromOverview(threadID: String) async {
        await selectThread(threadID)
        if handoffCards[threadID] != nil { await revealHandoffCard(threadID: threadID) }
    }

    /// 그 대화의 실행을 멈춘다 (⌘. 와 같은 길 — 백그라운드 작업까지). 검토 레인의 실행이면 그 실행만.
    func stopFromOverview(threadID: String) async {
        if runner.session(threadID: threadID) != nil {
            await runner.interrupt(threadID: threadID)
        } else if reviewLanes.coordinator.session(threadID: threadID) != nil {
            await reviewLanes.coordinator.interrupt(threadID: threadID)
        }
    }

    /// 현황에서 승인 요청에 답한다. 지금도 그 실행의 대기 중인 요청이고, 현황에서 답할 수 있는 결정일 때만 보낸다 — 늦은 클릭 ·
    /// 대화에서 이미 답한 요청 · 되돌릴 수 없는 명령의 허용은 보내지 않는다 (false).
    @discardableResult
    func respondFromOverview(threadID: String, approvalID: String, decision: ApprovalDecision) async -> Bool {
        guard let session = runner.session(threadID: threadID),
              let request = session.pendingApprovals.first(where: { $0.id == approvalID }) else { return false }
        let folder = paneThread(threadID).flatMap { folderProject(for: $0)?.path }
        let choice = Overview.approvalChoice(kind: request.kind,
                                             presentation: ApprovalPresentation.make(request, projectPath: folder),
                                             isQuestion: request.isQuestion)
        switch decision {
        case .allow: guard choice.allowsHere else { return false }
        case .deny: guard choice.deniesHere else { return false }
        default: return false
        }
        await runner.respond(approval: request, decision: decision)
        return true
    }

    /// 현황에서 질문에 답한다 (고를 답이 있는 한 항목 질문만 — `Overview.questionOptions`). 답할 수 없으면 false.
    @discardableResult
    func answerFromOverview(threadID: String, questionID: String, option: String) async -> Bool {
        guard let session = runner.session(threadID: threadID),
              let question = session.pendingQuestions.first(where: { $0.id == questionID }),
              let options = Overview.questionOptions(question), options.contains(option),
              let item = question.items.first else { return false }
        await runner.respond(question: question, answers: [item.id: option])
        return true
    }

    /// 카운트다운을 멈추고 그 카드로 간다 ("멈추고 검토").
    func reviewCountdownFromOverview(threadID: String) async {
        pauseCountdown(threadID: threadID)
        await openFromOverview(threadID: threadID)
    }

    // 다른 계정에서 이어 가기 카운트다운의 [취소] · [지금 이어 가기] 는 입력창 위 줄과 같은 길이다 — `cancelCodexSwitchCountdown` ·
    // `continueCodexSwitchNow` (`AppModel+CodexSwitch`). 취소한 뒤에는 한도 줄 · 입력창의 에이전트 칩에서 사람이 고른다.

    // MARK: 끝난 실행

    /// 오늘 끝난 실행과 마지막으로 끝난 실행의 시각 — 현황의 "최근 끝난 실행" 표 · 오늘 칸 · 빈 상태의 한 줄.
    func overviewFinishedRuns(now: Date = Date(), calendar: Calendar = .current) async -> (today: [Overview.FinishedRun], lastEnded: Date?) {
        let start = calendar.startOfDay(for: now)
        let runs = (try? await store.finishedRuns(since: start)) ?? []
        let usage = (try? await store.usage(since: start.addingTimeInterval(-86_400))) ?? []
        let usageByRun = Dictionary(usage.map { ($0.runID, $0) }, uniquingKeysWith: { _, new in new })
        let unseen = Set(unseenRunProblems.map(\.threadID))
        var latestPerThread: [String: Date] = [:]
        for run in runs { if let ended = run.endedAt { latestPerThread[run.threadID] = max(latestPerThread[run.threadID] ?? ended, ended) } }
        let rows: [Overview.FinishedRun] = runs.compactMap { run in
            guard let ended = run.endedAt else { return nil }
            let thread = paneThread(run.threadID)
            let project = thread.flatMap { mainProject(for: $0) ?? folderProject(for: $0) }
            let record = usageByRun[run.id]
            let check = unseen.contains(run.threadID) && latestPerThread[run.threadID] == ended
                && unseenRunProblems.contains { $0.threadID == run.threadID && $0.state == run.state }
            return Overview.FinishedRun(runID: run.id, threadID: run.threadID, title: thread?.title ?? "지운 대화",
                                        project: project.map(projectDisplayName) ?? "—", provider: run.provider,
                                        state: run.state, endedAt: ended, durationMs: run.durationMs,
                                        newTokens: record?.newTokens, cost: record?.costUSD, needsCheck: check)
        }
        if let last = rows.map(\.endedAt).max() { return (rows, last) }
        let last = (try? await store.lastFinishedRun())?.endedAt
        return (rows, last)
    }
}
