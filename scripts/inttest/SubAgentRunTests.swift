import Foundation

// MARK: - 하위 에이전트 · 백그라운드 작업: 실행기와 소비자

/// 실행기(`RunSession` · `RunCoordinator`)가 하위 작업 · 대기(`turnSettled`) · 후속 턴을 어떻게 다루는지를
/// 가짜 어댑터로 CLI 없이 돌려 본다. 하위 이벤트를 메인 말로 읽으면 안 되는 곳(자동 작업 · 인계 · Gemini 입력 ·
/// Codex 기록 가져오기)의 거르기도 본다.
@MainActor
enum SubAgentRunTests {

    static func run(_ t: TestKit) async {
        do {
            let stage = try await Stage()
            defer { stage.removeDatabase() }
            try await waitAndFollowUp(t, stage)
            try await childEventsKeepMainStream(t, stage)
            try await childDrivenMainEventsKeepMainStream(t, stage)
            try await settleClosesMainStream(t, stage)
            try await interruptWhileWaiting(t, stage)
            try await waitFlag(t, stage)
            try await stopOne(t, stage)
            try await statusRows(t, stage)
            try await quitStopsSubAgents(t, stage)
            try await quitUnterminatedHandoff(t, stage)
            try await quitClosesStreaming(t, stage)
            try await handoffSettledThenAuthFailure(t, stage)
            try await interruptDuringFinish(t, stage)
            try await finishedChildDropsPending(t, stage)
        } catch {
            await t.group("하위 에이전트: 실행기")
            await t.check("시나리오 실행 중 예외", false, "\(error)")
        }
        do {
            try await orchestrationIgnoresChildMessages(t)
        } catch {
            await t.group("하위 에이전트: 자동 작업")
            await t.check("시나리오 실행 중 예외", false, "\(error)")
        }
        await handoffAndGemini(t)
        await geminiDialogBudget(t)
        await codexImportSkipsSubAgents(t)
    }

    // MARK: 무대

    /// 대리자 호출을 빠짐없이 순서대로 적는다 (같은 행을 몇 번 덮어썼는지 세려고 — `CoordinatorProbe` 는 ID 로 합친다).
    @MainActor
    final class Probe: RunCoordinatorDelegate {
        var upserts: [ThreadEvent] = []
        var states: [RunState] = []
        var finished: [(Run, AgentTurnResult, UsageRecord?)] = []
        var quit: [Run] = []
        var attentions: [(String, AttentionKind)] = []

        func runCoordinator(_ c: RunCoordinator, didUpsert event: ThreadEvent) { upserts.append(event) }
        func runCoordinator(_ c: RunCoordinator, didChangeState state: RunState, run: Run?) { states.append(state) }
        func runCoordinator(_ c: RunCoordinator, didReceive limits: LimitSnapshot) {}
        func runCoordinator(_ c: RunCoordinator, didFinish run: Run, result: AgentTurnResult, usage: UsageRecord?) {
            finished.append((run, result, usage))
        }
        func runCoordinator(_ c: RunCoordinator, didQuit run: Run) { quit.append(run) }
        func runCoordinator(_ c: RunCoordinator, needsAttention title: String, body: String,
                            threadID: String, kind: AttentionKind) {
            attentions.append((title, kind))
        }

        func writes(of id: String) -> [ThreadEvent] { upserts.filter { $0.id == id } }
    }

    @MainActor
    final class Stage {
        let store: Store
        let project: Project
        let coordinator: RunCoordinator
        private(set) var probe = Probe()
        private let dbURL: URL

        init() async throws {
            dbURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-subagent-\(UUID().uuidString).sqlite3")
            store = Store(databaseURL: dbURL)
            try await store.bootstrap()
            project = Project(name: "하위", path: NSTemporaryDirectory())
            try await store.upsertProject(project)
            coordinator = RunCoordinator(store: store, environment: CLIEnvironment())
            coordinator.delegate = probe
        }

        func removeDatabase() { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + s) } }

        /// 시나리오마다 새 대화와 새 기록기.
        func begin(_ title: String, adapter: ScriptedAgentAdapter) async throws -> ConversationThread {
            probe = Probe()
            coordinator.delegate = probe
            coordinator.adapterFactory = { _ in adapter }
            let thread = ConversationThread(projectID: project.id, title: title)
            try await store.upsertThread(thread)
            return thread
        }

        /// 조건이 될 때까지 기다린다 (최대 5초).
        func settle(_ condition: @MainActor () -> Bool) async {
            for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        }

        func events(_ thread: ConversationThread) async throws -> [ThreadEvent] { try await store.events(threadID: thread.id) }
    }

    static func established(_ session: String = "s-sub") -> ScriptedAgentAdapter.Step {
        .emit(.sessionEstablished(sessionID: session, model: "fake-model", cliVersion: nil))
    }

    static func completed(_ text: String? = nil, usage: TurnUsage? = nil) -> AgentTurnResult {
        AgentTurnResult(state: .completed, terminalReason: "completed", model: "fake-model", sessionID: "s-sub",
                        resultText: text, usage: usage)
    }

    // MARK: 1 · 3) 대기 → 하위 이벤트 → 후속 턴 → 끝: 실행 하나 · 사용량 하나 · 완료 한 번

    private static func waitAndFollowUp(_ t: TestKit, _ stage: Stage) async throws {
        await t.group("하위 에이전트: 대기와 후속 턴")
        let agent = SubAgentInfo(id: "toolu-agent", taskID: "task-1", kind: .agent, title: "메시지 고치기",
                                 detail: "general-purpose", isBackground: true)
        var done = agent
        done.status = .completed
        done.endedAt = Date()
        done.summary = "고쳤습니다"
        var usage = TurnUsage()
        usage.inputTokens = 100
        usage.outputTokens = 20
        usage.model = "fake-model"
        let fake = ScriptedAgentAdapter(provider: .claude, steps: [
            established(),
            .emit(.toolStarted(id: agent.id, name: "Agent", detail: #"{"description":"메시지 고치기"}"#)),
            .emit(.subAgent(agent)),
            .emit(.assistantMessage("백그라운드로 띄웠습니다.")),
            .emit(.turnSettled(remaining: 1)),
            .waitSignal("settled"),
            .emit(.subAgentEvent(agentID: agent.id, event: .toolStarted(id: "toolu-child-read", name: "Read", detail: "{}"))),
            .emit(.subAgentEvent(agentID: agent.id, event: .assistantMessage("CHILD-ANSWER"))),
            .emit(.subAgent(done)),
            .emit(.followUpTurnStarted),
            .waitSignal("followUp"),
            .emit(.assistantMessage("하위 작업이 끝나 결과를 확인했습니다.")),
            .finish(completed("하위 작업이 끝나 결과를 확인했습니다.", usage: usage)),
        ])
        let thread = try await stage.begin("대기", adapter: fake)
        let c = stage.coordinator
        let run = try await c.send(prompt: "백그라운드로 고쳐줘", thread: thread, project: stage.project, provider: .claude)
        let session = c.session(threadID: thread.id)
        await stage.settle { session?.isWaitingOnBackground == true }

        await t.check("메인 턴이 끝나면 기다린다", session?.isWaitingOnBackground == true && session?.waitingSince != nil)
        await t.equal("기다리는 동안 상태는 실행 중", session?.state, .running)
        await t.check("기다리는 동안 완료 통지 · 알림 없음", stage.probe.finished.isEmpty && stage.probe.attentions.isEmpty)
        await t.equal("기다리는 실행 목록", c.activeSessions.filter(\.isWaitingOnBackground).compactMap { $0.activeRun?.id }, [run.id])
        await t.equal("사람이 지켜보는 쓰기 턴은 기다리라고 요청한다", fake.requests.first?.waitForBackground, true)
        await t.equal("하위 작업 표", session?.subAgents.map(\.id), [agent.id])
        let settledMain = try await stage.events(thread).filter { $0.kind == .agentMessage && $0.isMainStream }
        await t.check("메인 응답은 확정되어 저장", settledMain.map(\.text) == ["백그라운드로 띄웠습니다."]
                        && settledMain.allSatisfy { !$0.isStreaming })

        // 3) 기다리는 동안 같은 대화 보내기는 거절한다 (실행 중이다).
        do {
            try await c.send(prompt: "끼어들기", thread: thread, project: stage.project, provider: .claude)
            await t.check("기다리는 중 같은 대화 보내기 거절", false)
        } catch RunCoordinator.StartError.busy {
            await t.check("기다리는 중 같은 대화 보내기 거절", true)
        }
        await t.equal("거절한 턴은 실행 기록을 남기지 않는다", try await stage.store.runs(threadID: thread.id).count, 1)

        fake.signal("settled")
        await stage.settle { session?.isWaitingOnBackground == false }
        await t.check("후속 턴이 열리면 대기를 푼다", session?.isWaitingOnBackground == false && session?.waitingSince == nil
                        && session?.state == .running && stage.probe.finished.isEmpty)
        await t.equal("끝난 하위 작업 상태", session?.subAgents.first?.status, .completed)

        fake.signal("followUp")
        await stage.settle { !c.isBusy(threadID: thread.id) && stage.probe.finished.count == 1 }
        await t.equal("완료 통지는 한 번", stage.probe.finished.count, 1)
        await t.equal("상태 전이 (기다림은 상태가 아니다)", stage.probe.states.map(\.rawValue), ["starting", "running", "completed"])
        await t.equal("완료 알림 한 번", stage.probe.attentions.map(\.0), ["실행 완료"])
        await t.equal("실행 하나", try await stage.store.runs(threadID: thread.id).count, 1)
        await t.equal("실행은 완료", try await stage.store.run(id: run.id)?.state, .completed)
        let usages = try await stage.store.usage(threadID: thread.id).filter { $0.runID == run.id }
        await t.equal("사용량 행 하나 (마지막 결과의 값)", usages.map(\.outputTokens), [20])
        await t.equal("결과 글은 마지막 메인 답", stage.probe.finished.first?.1.resultText, "하위 작업이 끝나 결과를 확인했습니다.")

        let events = try await stage.events(thread)
        await t.equal("메인 응답 두 개 (띄움 · 후속)", events.filter { $0.kind == .agentMessage && $0.isMainStream }.map(\.text),
                      ["백그라운드로 띄웠습니다.", "하위 작업이 끝나 결과를 확인했습니다."])
        let children = events.filter { $0.parentAgentID == agent.id }
        await t.equal("하위 이벤트는 부모 표시로 저장", children.map(\.kind), [.toolRequest, .agentMessage])
        await t.check("하위의 답은 메인 흐름이 아니다", children.allSatisfy { !$0.isMainStream }
                        && !events.contains { $0.isMainStream && $0.text == "CHILD-ANSWER" })
        let row = events.first { $0.id == ThreadEvent.subAgentEventID(runID: run.id, agentID: agent.id) }
        await t.check("하위 작업 상태 행: 완료 · 요약", row?.kind == .subAgent && row?.subAgentInfo?.status == .completed
                        && row?.text == "고쳤습니다" && row?.title == "메시지 고치기" && row?.isMainStream == false,
                      "\(String(describing: row))")
        await t.check("끝나면 하위 표 · 대기 상태를 비운다", session?.subAgents.isEmpty == true
                        && session?.isWaitingOnBackground == false && session?.subAgentLiveText.isEmpty == true)
        await t.check("끝난 뒤 어댑터 종료", fake.wasShutDown)
    }

    // MARK: 2) 하위 이벤트는 메인 스트리밍을 끊거나 덮지 않는다

    private static func childEventsKeepMainStream(_ t: TestKit, _ stage: Stage) async throws {
        await t.group("하위 에이전트: 메인 흐름과 분리")
        let child = "thread-child"
        func sub(_ event: AgentEvent) -> ScriptedAgentAdapter.Step { .emit(.subAgentEvent(agentID: child, event: event)) }
        let fake = ScriptedAgentAdapter(provider: .codex, steps: [
            established(),
            .emit(.assistantDelta("메인 앞부분 ")),
            sub(.assistantDelta("하위가 ")),
            sub(.assistantDelta("쓰는 중")),
            .waitSignal("live"),
            sub(.assistantMessage("하위가 쓴 글")),
            sub(.reasoning("하위 추론")),
            sub(.toolStarted(id: "child-tool", name: "web_search", detail: "{}")),
            sub(.toolFinished(id: "child-tool", name: "web_search", output: "결과", isError: false)),
            sub(.commandExecution(id: "exec-child", command: "swift build", cwd: "/tmp/p", output: "ok", exitCode: 0, status: "completed")),
            sub(.fileChange(id: "fc-child", paths: ["Sources/a.swift"], diff: "+x", status: "completed")),
            sub(.failure(AgentErrorInfo(message: "하위 오류", classification: .unknownCause, raw: #"{"code":1}"#))),
            sub(.notice("하위 안내")),
            .waitSignal("children"),
            .emit(.assistantDelta("메인 뒷부분")),
            .emit(.assistantMessage("메인 앞부분 메인 뒷부분")),
            .finish(completed("메인 앞부분 메인 뒷부분")),
        ])
        let thread = try await stage.begin("분리", adapter: fake)
        let c = stage.coordinator
        _ = try await c.send(prompt: "하위와 함께", thread: thread, project: stage.project, provider: .codex)
        let session = c.session(threadID: thread.id)
        await stage.settle { session?.subAgentLiveText[child] == "하위가 쓰는 중" }
        await t.equal("하위의 흐르는 글은 메모리에만", session?.subAgentLiveText[child], "하위가 쓰는 중")
        await t.check("하위의 흐르는 글은 저장하지 않는다",
                      !(try await stage.events(thread)).contains { $0.parentAgentID != nil })

        fake.signal("live")
        await stage.settle { stage.probe.upserts.contains { $0.kind == .systemNotice && $0.parentAgentID == child } }
        await t.check("하위 메시지가 끝나면 흐르는 글을 비운다", session?.subAgentLiveText[child] == nil)
        let mainIDs = Set(stage.probe.upserts.filter { $0.kind == .agentMessage && $0.isMainStream }.map(\.id))
        await t.equal("메인 응답 행은 하나", mainIDs.count, 1)
        await t.equal("하위 이벤트 사이에도 메인 응답은 흐르는 중",
                      stage.probe.upserts.last { $0.kind == .agentMessage && $0.isMainStream }?.isStreaming, true)
        await t.check("하위 오류는 실행의 오류가 아니다", session?.lastErrorMessage == nil && session?.state == .running)

        fake.signal("children")
        await stage.settle { !c.isBusy(threadID: thread.id) && !stage.probe.finished.isEmpty }
        let events = try await stage.events(thread)
        let main = events.filter { $0.kind == .agentMessage && $0.isMainStream }
        await t.equal("메인 응답은 한 행, 글 전체", main.map(\.text), ["메인 앞부분 메인 뒷부분"])
        await t.check("메인 응답 확정", main.allSatisfy { !$0.isStreaming })
        let children = events.filter { $0.parentAgentID == child }
        await t.equal("하위 이벤트 종류 (흐르는 조각은 빠진다)", children.map(\.kind),
                      [.agentMessage, .agentReasoning, .toolRequest, .toolResult, .commandExecution, .fileChange, .error, .systemNotice])
        await t.equal("하위 메시지는 새 행", children.first?.text, "하위가 쓴 글")
        let command = children.first { $0.kind == .commandExecution }?.payloadJSON.flatMap(JSONUtil.object)
        await t.check("명령 payload: 기존 키 + 부모 표시", command?["status"] as? String == "completed"
                        && JSONUtil.int(command?["exitCode"]) == 0 && command?["cwd"] as? String == "/tmp/p"
                        && command?[ThreadEvent.parentKey] as? String == child, "\(String(describing: command))")
        let file = children.first { $0.kind == .fileChange }?.payloadJSON.flatMap(JSONUtil.object)
        await t.check("파일 변경 payload: 상태 + 부모 표시", file?["status"] as? String == "completed"
                        && file?[ThreadEvent.parentKey] as? String == child)
        await t.equal("명령 · 도구의 toolUseID 유지", children.filter { $0.kind == .commandExecution || $0.kind == .toolRequest }.map(\.toolUseID),
                      ["child-tool", "exec-child"])
        let failure = children.first { $0.kind == .error }?.payloadJSON.flatMap(JSONUtil.object)
        await t.check("하위 오류 원문은 raw 에", failure?["raw"] as? String == #"{"code":1}"#
                        && failure?[ThreadEvent.parentKey] as? String == child, "\(String(describing: failure))")
        await t.equal("하위 오류가 있어도 실행은 완료", stage.probe.finished.first?.1.state, .completed)
        await t.check("하위 오류는 실행의 오류 문구가 아니다", session?.lastErrorMessage == nil && c.lastErrorMessage == nil)
    }

    // MARK: 2-1) 하위가 일으킨 메인 경로 이벤트(앵커 행의 끝 · 하위의 승인)도 메인 스트리밍을 닫지 않는다

    private static func childDrivenMainEventsKeepMainStream(_ t: TestKit, _ stage: Stage) async throws {
        await t.group("하위 에이전트: 하위가 일으킨 메인 이벤트")
        let done = SubAgentInfo(id: "thread-kid-a", kind: .agent, title: "kid_a", detail: "/root/kid_a", isBackground: false)
        let asking = SubAgentInfo(id: "thread-kid-b", kind: .agent, title: "kid_b", detail: "/root/kid_b", isBackground: false)
        let approval = ApprovalRequest(id: "ap-kid", runID: "", provider: .codex, kind: .command, toolName: "exec",
                                       title: "kid_b: rm -rf build", detail: "rm -rf build", toolUseID: "exec-kid",
                                       agentID: asking.id)
        let fake = ScriptedAgentAdapter(provider: .codex, steps: [
            established(),
            .emit(.subAgent(done)),
            .emit(.subAgent(asking)),
            .emit(.assistantDelta("메인 앞부분 ")),
            // Codex: 하위 턴이 끝나면 그 하위의 앵커 행을 끝낸다 — 메인 글 도중에도 온다.
            .emit(.toolFinished(id: done.id, name: "subAgent", output: "하위 답", isError: false)),
            .emit(.approvalRequested(approval)),
            .waitApproval(id: approval.id),
            .waitSignal("resolved"),
            .emit(.assistantDelta("메인 뒷부분")),
            .emit(.assistantMessage("메인 앞부분 메인 뒷부분")),
            .finish(completed("메인 앞부분 메인 뒷부분")),
        ])
        let thread = try await stage.begin("하위가 일으킨 메인 이벤트", adapter: fake)
        let c = stage.coordinator
        _ = try await c.send(prompt: "하위 둘", thread: thread, project: stage.project, provider: .codex)
        let session = c.session(threadID: thread.id)
        await stage.settle { session?.pendingApprovals.isEmpty == false }
        func mainRows() -> [ThreadEvent] { stage.probe.upserts.filter { $0.kind == .agentMessage && $0.isMainStream } }
        await t.equal("하위의 끝 · 승인 요청 뒤에도 메인 응답 행은 하나", Set(mainRows().map(\.id)).count, 1)
        await t.equal("하위의 끝 · 승인 요청 뒤에도 메인 응답은 흐르는 중", mainRows().last?.isStreaming, true)
        await t.equal("하위의 승인을 기다린다", session?.state, .awaitingApproval)

        if let pending = session?.pendingApprovals.first { await c.respond(approval: pending, decision: .allow) }
        await stage.settle { stage.probe.upserts.contains { $0.kind == .approvalDecision } }
        await t.equal("승인 결정 뒤에도 메인 응답은 흐르는 중", mainRows().last?.isStreaming, true)
        await t.equal("승인 결정 뒤에도 메인 응답 행은 하나", Set(mainRows().map(\.id)).count, 1)

        fake.signal("resolved")
        await stage.settle { !c.isBusy(threadID: thread.id) && !stage.probe.finished.isEmpty }
        let events = try await stage.events(thread)
        let main = events.filter { $0.kind == .agentMessage && $0.isMainStream }
        await t.equal("메인 응답은 한 행, 글 전체 (앞부분이 겹쳐 남지 않는다)", main.map(\.text), ["메인 앞부분 메인 뒷부분"])
        await t.check("메인 응답 확정", main.allSatisfy { !$0.isStreaming })
        await t.check("하위 앵커 행의 끝은 저장된다",
                      events.contains { $0.kind == .toolResult && $0.toolUseID == done.id && $0.text == "하위 답" })
        await t.check("하위의 승인 요청 · 결정은 저장된다",
                      events.contains { $0.kind == .approvalRequest && $0.toolUseID == "exec-kid" }
                        && events.contains { $0.kind == .approvalDecision })
        await t.equal("실행은 완료", stage.probe.finished.first?.1.state, .completed)
    }

    // MARK: 2-2) 메인 턴의 끝(`turnSettled`)은 흐르던 메인 응답을 닫는다 — 후속 턴의 답은 새 행

    private static func settleClosesMainStream(_ t: TestKit, _ stage: Stage) async throws {
        await t.group("하위 에이전트: 대기는 메인 응답을 닫는다")
        let agent = SubAgentInfo(id: "toolu-agent-open", taskID: "task-open", kind: .agent, title: "열린 글", isBackground: true)
        var done = agent
        done.status = .completed
        done.endedAt = Date()
        let fake = ScriptedAgentAdapter(provider: .claude, steps: [
            established(),
            .emit(.subAgent(agent)),
            // 확정 메시지 없이 흐르던 글에서 메인 턴이 끝난다.
            .emit(.assistantDelta("백그라운드로 띄웠")),
            .emit(.turnSettled(remaining: 1)),
            .waitSignal("followUp"),
            .emit(.subAgent(done)),
            .emit(.followUpTurnStarted),
            .emit(.assistantMessage("후속 답")),
            .finish(completed("후속 답")),
        ])
        let thread = try await stage.begin("대기가 닫는 글", adapter: fake)
        let c = stage.coordinator
        _ = try await c.send(prompt: "띄워줘", thread: thread, project: stage.project, provider: .claude)
        let session = c.session(threadID: thread.id)
        await stage.settle { session?.isWaitingOnBackground == true }
        let waiting = try await stage.events(thread).filter { $0.kind == .agentMessage && $0.isMainStream }
        await t.check("기다리는 동안 흐르던 메인 응답은 확정되어 저장",
                      waiting.map(\.text) == ["백그라운드로 띄웠"] && waiting.allSatisfy { !$0.isStreaming },
                      "\(waiting.map { ($0.text, $0.isStreaming) })")

        fake.signal("followUp")
        await stage.settle { !c.isBusy(threadID: thread.id) && !stage.probe.finished.isEmpty }
        let main = try await stage.events(thread).filter { $0.kind == .agentMessage && $0.isMainStream }
        await t.equal("후속 턴의 답은 새 행 (앞 응답을 덮지 않는다)", main.map(\.text), ["백그라운드로 띄웠", "후속 답"])
        await t.equal("두 행은 다른 행", Set(main.map(\.id)).count, 2)
    }

    // MARK: 4) 기다리는 중 중단 → 취소

    private static func interruptWhileWaiting(_ t: TestKit, _ stage: Stage) async throws {
        await t.group("하위 에이전트: 기다리는 중 중단")
        let shell = SubAgentInfo(id: "toolu-bash", taskID: "task-bash", kind: .shell, title: "sleep 60", isBackground: true)
        let fake = ScriptedAgentAdapter(provider: .claude, steps: [
            established(),
            .emit(.subAgent(shell)),
            .emit(.assistantMessage("셸을 띄웠습니다.")),
            .emit(.turnSettled(remaining: 1)),
            .waitSignal("never"),
            .emit(.assistantMessage("오지 않는 후속")),
            .finish(completed()),
        ])
        let thread = try await stage.begin("중단", adapter: fake)
        let c = stage.coordinator
        let run = try await c.send(prompt: "셸 띄워줘", thread: thread, project: stage.project, provider: .claude)
        let session = c.session(threadID: thread.id)
        await stage.settle { session?.isWaitingOnBackground == true }
        await c.interrupt(threadID: thread.id)
        await stage.settle { !c.isBusy(threadID: thread.id) && !stage.probe.finished.isEmpty }

        await t.equal("기다리던 실행은 취소로 끝난다", try await stage.store.run(id: run.id)?.state, .cancelled)
        await t.check("중단 중을 거쳤다", stage.probe.states.contains(.interrupting))
        await t.equal("완료 통지 한 번 (취소)", stage.probe.finished.map(\.1.state), [.cancelled])
        await t.equal("중단 알림", stage.probe.attentions.map(\.0), ["실행 중단됨"])
        let events = try await stage.events(thread)
        await t.check("후속 응답은 오지 않았다", !events.contains { $0.text == "오지 않는 후속" })
        let row = events.first { $0.id == ThreadEvent.subAgentEventID(runID: run.id, agentID: shell.id) }?.subAgentInfo
        await t.check("남은 작업은 실행과 함께 멈춤으로 적힌다", row?.status == .stopped && row?.endedAt != nil,
                      "\(String(describing: row))")
    }

    // MARK: 5) 기다리기는 사람이 지켜보는 쓰기 턴만

    private static func waitFlag(_ t: TestKit, _ stage: Stage) async throws {
        await t.group("하위 에이전트: 기다리기 요청")
        let schema = TurnOptionsTests.schema
        func request(_ turn: AgentTurnOptions, unattended: Bool = false) async throws -> AgentTurnRequest? {
            let fake = ScriptedAgentAdapter.replying("응답")
            let thread = try await stage.begin("기다리기 \(turn.readOnly) \(turn.outputSchema != nil) \(unattended)", adapter: fake)
            let c = stage.coordinator
            c.unattended = unattended
            defer { c.unattended = false }
            try await c.send(prompt: "해줘", thread: thread, project: stage.project, provider: .claude, turn: turn)
            await stage.settle { !c.isBusy(threadID: thread.id) && !stage.probe.finished.isEmpty }
            return fake.requests.first
        }
        await t.equal("쓰기 턴: 기다린다", try await request(AgentTurnOptions())?.waitForBackground, true)
        await t.equal("읽기 전용 턴: 기다리지 않는다", try await request(AgentTurnOptions(readOnly: true))?.waitForBackground, false)
        await t.equal("구조화 응답 턴: 기다리지 않는다",
                      try await request(AgentTurnOptions(outputSchema: schema))?.waitForBackground, false)
        await t.equal("무인(검토 레인) 턴: 기다리지 않는다",
                      try await request(AgentTurnOptions(readOnly: true, outputSchema: schema), unattended: true)?.waitForBackground, false)
    }

    // MARK: 6) 작업 하나 멈추기

    private static func stopOne(_ t: TestKit, _ stage: Stage) async throws {
        await t.group("하위 에이전트: 작업 하나 멈추기")
        let agent = SubAgentInfo(id: "toolu-stop", taskID: "task-stop", kind: .agent, title: "오래 걸리는 하위", isBackground: true)
        var stopped = agent
        stopped.status = .stopped
        stopped.endedAt = Date()
        let fake = ScriptedAgentAdapter(provider: .claude, steps: [
            established(),
            .emit(.subAgent(agent)),
            .waitSignal("stopped"),
            .emit(.subAgent(stopped)),
            .emit(.assistantMessage("멈춘 것을 확인했습니다.")),
            .finish(completed()),
        ])
        let thread = try await stage.begin("멈추기", adapter: fake)
        let c = stage.coordinator
        let run = try await c.send(prompt: "하위 띄워", thread: thread, project: stage.project, provider: .claude)
        let session = c.session(threadID: thread.id)
        await stage.settle { session?.subAgents.first?.canStop == true }
        await t.check("멈출 수 있는 작업", session?.subAgents.first?.canStop == true)
        let byThread = await c.stopSubAgent(threadID: thread.id, agentID: agent.id)
        let byRun = await c.stopSubAgent(runID: run.id, agentID: agent.id)
        await t.check("대화 · 실행 ID 로 어댑터까지 간다", byThread && byRun)
        await t.equal("어댑터가 받은 멈추기", fake.stoppedSubAgents, [agent.id, agent.id])
        await t.check("실행 전체는 계속된다", session?.state == .running && stage.probe.finished.isEmpty)
        fake.stopSubAgentAccepts = false
        let refused = await c.stopSubAgent(runID: run.id, agentID: agent.id)
        await t.check("제공자가 못 보내면 false", !refused)
        let noThread = await c.stopSubAgent(threadID: "없는 대화", agentID: agent.id)
        let noRun = await c.stopSubAgent(runID: "없는 실행", agentID: agent.id)
        await t.check("없는 대화 · 실행은 false", !noThread && !noRun)

        fake.signal("stopped")
        await stage.settle { !c.isBusy(threadID: thread.id) && !stage.probe.finished.isEmpty }
        await t.equal("멈춘 작업은 멈춤으로 기록", try await stage.events(thread)
            .first { $0.id == ThreadEvent.subAgentEventID(runID: run.id, agentID: agent.id) }?.subAgentInfo?.status, .stopped)
        let after = fake.stoppedSubAgents.count
        let late = await c.stopSubAgent(runID: run.id, agentID: agent.id)
        await t.check("끝난 실행에는 보내지 않는다", !late && fake.stoppedSubAgents.count == after)
        await t.equal("실행은 완료", try await stage.store.run(id: run.id)?.state, .completed)
    }

    // MARK: 7) 상태 행: 진행만 바뀐 것은 쓰지 않는다

    private static func statusRows(_ t: TestKit, _ stage: Stage) async throws {
        await t.group("하위 에이전트: 상태 행 저장")
        let first = SubAgentInfo(id: "toolu-wf", taskID: "task-wf", kind: .workflow, title: "검토 워크플로",
                                 detail: "review", isBackground: true, progress: "1단계")
        var second = first
        second.progress = "2단계"
        second.totalTokens = 1_200
        second.toolUses = 3
        second.lastToolName = "Read"
        var third = second
        third.progress = "3단계"
        var done = third
        done.status = .completed
        done.endedAt = Date()
        done.summary = "끝났습니다"
        let fake = ScriptedAgentAdapter(provider: .claude, steps: [
            established(),
            .emit(.assistantDelta("메인 글")),
            .emit(.subAgent(first)),
            .emit(.subAgent(second)),
            .emit(.subAgent(third)),
            .waitSignal("progress"),
            .emit(.subAgent(done)),
            .waitSignal("done"),
            .finish(completed()),
        ])
        let thread = try await stage.begin("상태 행", adapter: fake)
        let c = stage.coordinator
        let run = try await c.send(prompt: "워크플로", thread: thread, project: stage.project, provider: .claude)
        let rowID = ThreadEvent.subAgentEventID(runID: run.id, agentID: first.id)
        let session = c.session(threadID: thread.id)
        await stage.settle { session?.subAgents.first?.progress == "3단계" }

        await t.equal("진행은 관찰 속성에", session?.subAgents.first?.progress, "3단계")
        await t.equal("진행의 토큰 · 도구 수", session?.subAgents.first.map { "\($0.totalTokens ?? 0)/\($0.toolUses ?? 0)" }, "1200/3")
        await t.equal("처음 한 번만 쓴다 (진행만 바뀐 것은 쓰지 않는다)", stage.probe.writes(of: rowID).count, 1)
        let stored = try await stage.events(thread).first { $0.id == rowID }
        await t.equal("저장된 행의 진행은 처음 값", stored?.subAgentInfo?.progress, "1단계")
        await t.check("상태 행은 메인 스트리밍을 닫지 않는다",
                      stage.probe.upserts.last { $0.kind == .agentMessage }?.isStreaming == true)

        fake.signal("progress")
        await stage.settle { stage.probe.writes(of: rowID).count == 2 }
        let writes = stage.probe.writes(of: rowID)
        await t.equal("상태가 바뀌면 덮어쓴다", writes.count, 2)
        await t.check("같은 행 · 같은 순번", writes.count == 2 && writes[0].seq == writes[1].seq && writes[0].seq > 0)
        let rows = try await stage.events(thread).filter { $0.kind == .subAgent }
        await t.equal("행은 하나", rows.map(\.id), [rowID])
        await t.check("덮어쓴 행: 완료 · 요약", rows.first?.subAgentInfo?.status == .completed && rows.first?.text == "끝났습니다"
                        && rows.first?.title == "검토 워크플로")

        fake.signal("done")
        await stage.settle { !c.isBusy(threadID: thread.id) && !stage.probe.finished.isEmpty }
        await t.equal("끝난 작업은 실행이 끝날 때 다시 쓰지 않는다", stage.probe.writes(of: rowID).count, 2)
    }

    // MARK: 8) 앱 종료: 남은 하위 작업은 멈춤으로 적고 대기를 푼다

    private static func quitStopsSubAgents(_ t: TestKit, _ stage: Stage) async throws {
        await t.group("하위 에이전트: 앱 종료")
        let agent = SubAgentInfo(id: "toolu-quit", taskID: "task-quit", kind: .agent, title: "끝나지 않는 하위", isBackground: true)
        let finished = SubAgentInfo(id: "toolu-quit-done", taskID: "task-quit-done", kind: .shell, title: "끝난 셸", isBackground: true)
        var finishedDone = finished
        finishedDone.status = .completed
        finishedDone.endedAt = Date()
        let fake = ScriptedAgentAdapter(provider: .claude, steps: [
            established(),
            .emit(.subAgent(agent)),
            .emit(.subAgent(finished)),
            .emit(.assistantMessage("띄웠습니다.")),
            .emit(.subAgent(finishedDone)),
            .emit(.turnSettled(remaining: 1)),
            .waitSignal("never"),
            .finish(completed()),
        ])
        // 완료 통지를 보내지 않는 길이다 — 다른 시나리오의 관리자 · 기록기와 섞이지 않게 따로 둔다.
        let probe = Probe()
        let c = RunCoordinator(store: stage.store, environment: CLIEnvironment())
        c.delegate = probe
        c.adapterFactory = { _ in fake }
        let thread = ConversationThread(projectID: stage.project.id, title: "앱 종료")
        try await stage.store.upsertThread(thread)
        let run = try await c.send(prompt: "띄우고 기다려", thread: thread, project: stage.project, provider: .claude)
        let session = c.session(threadID: thread.id)
        await stage.settle { session?.isWaitingOnBackground == true && session?.subAgents.last?.status == .completed }
        // 끝난 메인 턴의 사용량 — 결과(`finished`)는 기다리는 동안 오지 않는다.
        var usage = TurnUsage()
        usage.inputTokens = 300
        usage.outputTokens = 40
        usage.model = "fake-model"
        fake.lastKnownUsage = usage

        let cleaned = await c.shutdownForQuit()
        await t.check("종료를 확인했다", cleaned && fake.wasShutDown)
        let stored = try await stage.store.run(id: run.id)
        await t.check("실행은 앱 종료로 취소", stored?.state == .cancelled && stored?.terminalReason == "app_quit",
                      "\(String(describing: stored?.state)) \(String(describing: stored?.terminalReason))")
        let rows = try await stage.store.events(threadID: thread.id).filter { $0.kind == .subAgent }
        let open = rows.first { $0.id == ThreadEvent.subAgentEventID(runID: run.id, agentID: agent.id) }?.subAgentInfo
        await t.check("도는 중이던 하위는 멈춤으로 저장", open?.status == .stopped && open?.endedAt != nil
                        && open?.canStop == false, "\(String(describing: open))")
        let closed = rows.first { $0.id == ThreadEvent.subAgentEventID(runID: run.id, agentID: finished.id) }?.subAgentInfo
        await t.equal("이미 끝난 하위는 그대로", closed?.status, .completed)
        await t.check("대기 · 하위 표를 비운다", session?.isWaitingOnBackground == false && session?.waitingSince == nil
                        && session?.subAgents.isEmpty == true && session?.subAgentLiveText.isEmpty == true)

        // 결과 없이 끊겨도 쓴 만큼은 남는다 (확정 아님).
        let usages = try await stage.store.usage(threadID: thread.id).filter { $0.runID == run.id }
        await t.check("끊긴 실행의 사용량 행 (확정 아님)", usages.map(\.outputTokens) == [40] && usages.first?.inputTokens == 300
                        && usages.first?.confirmed == false, "\(usages)")

        // 사용자가 종료를 취소해도(두 번째 경고) 세션은 끝났다 — 대화는 쉬고, 다시 보낼 수 있다.
        await t.check("종료 뒤 대화는 실행 중이 아니다", !c.isBusy(threadID: thread.id) && c.session(threadID: thread.id) == nil
                        && c.activeSessions.isEmpty && !c.isBusy)
        await t.check("세션은 끝난 상태 · 승인 대기 없음", session?.state == .cancelled && session?.activeRun == nil
                        && session?.pendingApprovals.isEmpty == true && session?.pendingQuestions.isEmpty == true)
        await t.check("완료 통지는 보내지 않는다 (다음 일을 시작하지 않게)", probe.finished.isEmpty)
        await t.check("앱 종료로 끝났다는 것만 알린다 (종료가 취소되면 대리자가 뒷정리)",
                      probe.quit.map(\.id) == [run.id] && probe.quit.first?.terminalReason == "app_quit")
        await t.equal("끝난 상태는 알린다", probe.states.last, .cancelled)
        await t.check("종료를 확인했으면 막는 것이 없다", c.unterminatedProcesses.isEmpty)
        c.adapterFactory = { _ in ScriptedAgentAdapter.replying("다시 왔습니다") }
        let again = try await c.send(prompt: "다시", thread: thread, project: stage.project, provider: .claude)
        await stage.settle { !c.isBusy(threadID: thread.id) }
        await t.equal("같은 대화로 다시 보낼 수 있다", try await stage.store.run(id: again.id)?.state, .completed)
    }

    // MARK: 8-1) 앱 종료: 종료를 확인하지 못함 · 인계 전달 중
    //
    // 기다리던 인계 전송 실행이 종료로 끊기면 인계는 "전송 중"에 머물지 않고 판정된다. 종료 미확인은 관리자에 남아 인계 전달 · git 쓰기를 막는다.

    private static func quitUnterminatedHandoff(_ t: TestKit, _ stage: Stage) async throws {
        await t.group("하위 에이전트: 앱 종료 — 종료 미확인 · 인계")
        let agent = SubAgentInfo(id: "toolu-quit-handoff", taskID: "task-qh", kind: .agent, title: "인계 뒤 하위", isBackground: true)
        let fake = ScriptedAgentAdapter(provider: .claude, steps: [
            established(),
            .emit(.subAgent(agent)),
            .emit(.assistantMessage("인계를 받았습니다. 하위에게 맡깁니다.")),
            .emit(.turnSettled(remaining: 1)),
            .waitSignal("never"),
            .finish(completed()),
        ])
        fake.shutdownSucceeds = false
        let probe = Probe()
        let c = RunCoordinator(store: stage.store, environment: CLIEnvironment())
        c.delegate = probe
        c.adapterFactory = { _ in fake }
        let thread = ConversationThread(projectID: stage.project.id, title: "앱 종료 · 인계")
        try await stage.store.upsertThread(thread)
        let handoff = Handoff(threadID: thread.id, fromProvider: .codex, toProvider: .claude, baseSeq: 0,
                              draftJSON: "{}", finalText: "인계 문서")
        try await stage.store.insertHandoff(handoff)
        let run = try await c.deliver(handoff: handoff, thread: thread, project: stage.project)
        let session = c.session(threadID: thread.id)
        await stage.settle { session?.isWaitingOnBackground == true }

        let cleaned = await c.shutdownForQuit()
        await t.check("종료를 확인하지 못하면 false", !cleaned)
        let stored = try await stage.store.run(id: run.id)
        await t.check("실행은 전달 여부 미확인 · 종료 미확인으로", stored?.state == .handoffDeliveryUnknown
                        && stored?.terminalReason == "app_quit_unterminated" && stored?.childProcessNote != nil,
                      "\(String(describing: stored?.state)) \(String(describing: stored?.terminalReason))")
        let delivered = try await stage.store.handoffs(threadID: thread.id).first { $0.id == handoff.id }
        await t.check("인계는 전송 중에 머물지 않는다 (응답을 봤으니 수신)", delivered?.deliveryState == .delivered
                        && delivered?.note?.contains("응답 중 종료됨") == true,
                      "\(String(describing: delivered?.deliveryState)) \(delivered?.note ?? "")")
        await t.check("인계 전달 상태 행", try await stage.events(thread).contains { $0.kind == .handoffReceived })
        await t.equal("종료 미확인 프로세스는 관리자에 남는다", c.unterminatedProcesses.count, 1)
        await t.check("세션은 끝났다 (쉬는 대화)", !c.isBusy(threadID: thread.id) && c.session(threadID: thread.id) == nil
                        && session?.state == .handoffDeliveryUnknown)
        do {
            let next = Handoff(threadID: thread.id, fromProvider: .claude, toProvider: .claude, baseSeq: 0,
                               draftJSON: "{}", finalText: "다음 인계")
            try await stage.store.insertHandoff(next)
            try await c.deliver(handoff: next, thread: thread, project: stage.project)
            await t.check("종료 미확인이면 다음 인계를 시작하지 않는다", false)
        } catch RunCoordinator.StartError.cliUnavailable {
            await t.check("종료 미확인이면 다음 인계를 시작하지 않는다", true)
        }
    }

    // MARK: 8-2) 앱 종료: 흐르던 메인 응답은 지금까지의 글로 확정한다

    private static func quitClosesStreaming(_ t: TestKit, _ stage: Stage) async throws {
        await t.group("하위 에이전트: 앱 종료 — 흐르던 응답")
        let fake = ScriptedAgentAdapter(provider: .claude, steps: [
            established(),
            .emit(.assistantDelta("쓰는 중이던 ")),
            .emit(.assistantDelta("글")),
            .waitSignal("never"),
            .finish(completed()),
        ])
        let probe = Probe()
        let c = RunCoordinator(store: stage.store, environment: CLIEnvironment())
        c.delegate = probe
        c.adapterFactory = { _ in fake }
        let thread = ConversationThread(projectID: stage.project.id, title: "앱 종료 · 흐르던 응답")
        try await stage.store.upsertThread(thread)
        let run = try await c.send(prompt: "길게 써줘", thread: thread, project: stage.project, provider: .claude)
        await stage.settle { probe.upserts.last { $0.kind == .agentMessage }?.text == "쓰는 중이던 글" }

        let cleaned = await c.shutdownForQuit()
        await t.check("종료를 확인했다", cleaned)
        let main = try await stage.events(thread).filter { $0.kind == .agentMessage && $0.isMainStream }
        await t.check("흐르던 메인 응답은 지금까지의 글로 확정되어 저장 (쓰는 중으로 남지 않는다)",
                      main.map(\.text) == ["쓰는 중이던 글"] && main.allSatisfy { !$0.isStreaming },
                      "\(main.map { ($0.text, $0.isStreaming) })")
        await t.equal("화면에도 확정으로 알린다", probe.upserts.last { $0.kind == .agentMessage }?.isStreaming, false)
        await t.check("완료 통지 없이 앱 종료로 끝났다는 것만", probe.quit.map(\.id) == [run.id] && probe.finished.isEmpty)
    }

    // MARK: 8-3) 인계: 메인 턴을 마친 뒤 후속 턴이 인증 오류로 죽어도 전달은 확인된 것이다
    //
    // 인증 실패를 "받지 못함" 으로 보는 규칙은 메인 턴 전의 것이다. 메인 턴이 완료로 끝났으면 대상은 인계를 읽고 답했다 —
    // 실패로 두면 같은 인계를 다시 보낼 수 있게 된다.

    private static func handoffSettledThenAuthFailure(_ t: TestKit, _ stage: Stage) async throws {
        await t.group("하위 에이전트: 인계 — 후속 턴의 인증 오류")
        let agent = SubAgentInfo(id: "toolu-handoff-auth", taskID: "task-ha", kind: .agent, title: "인계 뒤 하위", isBackground: true)
        var done = agent
        done.status = .completed
        done.endedAt = Date()
        let authFailure = AgentTurnResult(state: .failed, terminalReason: "exit_1", isError: true,
                                          errorMessage: "Failed to authenticate: OAuth session expired",
                                          sessionID: "s-sub", limitStatus: .authProblem)
        let fake = ScriptedAgentAdapter(provider: .claude, steps: [
            established(),
            .emit(.subAgent(agent)),
            .emit(.assistantMessage("인계를 받았습니다. 하위에게 맡깁니다.")),
            .emit(.turnSettled(remaining: 1)),
            .waitSignal("followUp"),
            .emit(.subAgent(done)),
            .emit(.followUpTurnStarted),
            .finish(authFailure),
        ])
        let thread = try await stage.begin("인계 · 후속 턴 인증 오류", adapter: fake)
        let c = stage.coordinator
        let handoff = Handoff(threadID: thread.id, fromProvider: .codex, toProvider: .claude, baseSeq: 7,
                              draftJSON: "{}", finalText: "인계 문서")
        try await stage.store.insertHandoff(handoff)
        _ = try await c.deliver(handoff: handoff, thread: thread, project: stage.project)
        let session = c.session(threadID: thread.id)
        await stage.settle { session?.isWaitingOnBackground == true }
        fake.signal("followUp")
        await stage.settle { !c.isBusy(threadID: thread.id) && !stage.probe.finished.isEmpty }

        await t.equal("실행은 후속 턴의 인증 오류로 실패", stage.probe.finished.first?.1.limitStatus, .authProblem)
        let stored = try await stage.store.handoffs(threadID: thread.id).first { $0.id == handoff.id }
        await t.check("메인 턴을 마쳤으면 인계는 전달됨 (인증 실패로 두지 않는다)",
                      stored?.deliveryState == .delivered && stored?.note?.contains("응답 중 종료됨(수신은 확인됨)") == true,
                      "\(String(describing: stored?.deliveryState)) \(stored?.note ?? "")")
        await t.check("같은 인계를 다시 보낼 수 없다", stored.map { !c.canSend(handoff: $0) } ?? false)
        let agentSession = try await stage.store.session(threadID: thread.id, provider: .claude, accountID: "")
        await t.equal("전달 지점 기록 (이 세션은 baseSeq 까지 받았다)", agentSession?.lastDeliveredSeq, 7)

        // 메인 턴을 마치기 전의 인증 오류는 지금처럼 받지 못한 것 (다시 보낼 수 있다).
        let early = ScriptedAgentAdapter(provider: .claude, steps: [
            established(),
            .emit(.assistantMessage("Failed to authenticate: OAuth session expired")),
            .finish(authFailure),
        ])
        let earlyThread = try await stage.begin("인계 · 첫 턴 인증 오류", adapter: early)
        let earlyHandoff = Handoff(threadID: earlyThread.id, fromProvider: .codex, toProvider: .claude, baseSeq: 3,
                                   draftJSON: "{}", finalText: "인계 문서")
        try await stage.store.insertHandoff(earlyHandoff)
        _ = try await c.deliver(handoff: earlyHandoff, thread: earlyThread, project: stage.project)
        await stage.settle { !c.isBusy(threadID: earlyThread.id) && !stage.probe.finished.isEmpty }
        let failed = try await stage.store.handoffs(threadID: earlyThread.id).first { $0.id == earlyHandoff.id }
        await t.equal("메인 턴 전의 인증 오류는 전달 실패 (다시 보낼 수 있다)", failed?.deliveryState, .failed)
    }

    // MARK: 9) 끝내는 도중의 중단은 저장한 끝 상태를 덮지 않는다

    private static func interruptDuringFinish(_ t: TestKit, _ stage: Stage) async throws {
        await t.group("하위 에이전트: 끝내는 도중의 중단")
        let fake = ScriptedAgentAdapter(provider: .claude, steps: [
            established(),
            .emit(.subAgent(SubAgentInfo(id: "toolu-late", taskID: "task-late", kind: .agent, title: "늦은 하위", isBackground: true))),
            .emit(.assistantMessage("끝났습니다.")),
            .finish(completed("끝났습니다.")),
        ])
        // 실행 행을 완료로 쓴 뒤 프로세스 종료를 기다리는 사이에 중단 · 하위 멈추기가 온다.
        fake.shutdownWaitsFor = "shutdown"
        let thread = try await stage.begin("끝내는 도중", adapter: fake)
        let c = stage.coordinator
        let run = try await c.send(prompt: "해줘", thread: thread, project: stage.project, provider: .claude)
        await stage.settle { fake.wasShutDown }
        await t.check("끝내는 중 (프로세스 종료를 기다린다)", fake.wasShutDown && c.isBusy(threadID: thread.id))
        await t.equal("실행 행은 이미 완료", try await stage.store.run(id: run.id)?.state, .completed)

        await c.interrupt(threadID: thread.id)
        await c.interrupt()
        let stopped = await c.stopSubAgent(threadID: thread.id, agentID: "toolu-late")
        await t.equal("끝내는 중의 중단은 실행 행을 덮지 않는다", try await stage.store.run(id: run.id)?.state, .completed)
        await t.check("중단 중으로 가지 않는다", !stage.probe.states.contains(.interrupting))
        await t.check("끝내는 중의 하위 멈추기는 보내지 않는다", !stopped && fake.stoppedSubAgents.isEmpty)
        // 앱 종료도 이때 오면 끝나기를 기다린다 — 같은 실행 행을 "앱 종료"로 다시 쓰지 않는다.
        let session = c.session(threadID: thread.id)
        let quit = Task { await session?.shutdownForQuit() }
        try? await Task.sleep(nanoseconds: 50_000_000)

        fake.signal("shutdown")
        let quitCleaned = await quit.value
        await t.equal("끝내는 도중의 앱 종료는 끝나기를 기다려 정리됨으로 답한다", quitCleaned, true)
        await stage.settle { !c.isBusy(threadID: thread.id) && !stage.probe.finished.isEmpty }
        await t.equal("완료 통지는 완료", stage.probe.finished.map(\.1.state), [.completed])
        let stored = try await stage.store.run(id: run.id)
        await t.check("실행은 완료로 남는다 (앱 종료가 덮지 않는다)", stored?.state == .completed && stored?.terminalReason == "completed",
                      "\(String(describing: stored?.state)) \(stored?.terminalReason ?? "")")
        await t.equal("완료 알림", stage.probe.attentions.map(\.0), ["실행 완료"])
        await t.check("취소 안내는 없다", !(try await stage.events(thread)).contains { $0.title == "사용자 취소" })
    }

    // MARK: 10) 끝난 하위가 청한 승인 · 질문은 걷는다

    private static func finishedChildDropsPending(_ t: TestKit, _ stage: Stage) async throws {
        await t.group("하위 에이전트: 끝난 하위의 승인 · 질문")
        let kidA = SubAgentInfo(id: "thread-kid-drop-a", kind: .agent, title: "kid_a", isBackground: false)
        let kidB = SubAgentInfo(id: "thread-kid-drop-b", kind: .agent, title: "kid_b", isBackground: false)
        var doneA = kidA
        doneA.status = .completed
        doneA.endedAt = Date()
        var failedB = kidB
        failedB.status = .failed
        failedB.endedAt = Date()
        func approval(_ id: String, agent: String?) -> ApprovalRequest {
            ApprovalRequest(id: id, runID: "", provider: .codex, kind: .command, toolName: "exec",
                            title: "\(agent ?? "메인"): ls", detail: "ls", toolUseID: "exec-\(id)", agentID: agent)
        }
        let question = UserQuestion(id: "q-kid-a", runID: "", provider: .codex,
                                    items: [.init(id: "i", header: "확인", question: "어느 쪽?", options: ["가", "나"],
                                                  allowsOther: false, isSecret: false)],
                                    agentID: kidA.id)
        let main = approval("ap-main", agent: nil)
        let fake = ScriptedAgentAdapter(provider: .codex, steps: [
            established(),
            .emit(.subAgent(kidA)),
            .emit(.approvalRequested(approval("ap-kid-a", agent: kidA.id))),
            .emit(.questionAsked(question)),
            .waitSignal("a"),
            .emit(.subAgent(doneA)),
            .waitSignal("b"),
            .emit(.subAgent(kidB)),
            .emit(.approvalRequested(main)),
            .emit(.approvalRequested(approval("ap-kid-b", agent: kidB.id))),
            .waitSignal("c"),
            .emit(.subAgent(failedB)),
            .waitApproval(id: main.id),
            .emit(.assistantMessage("끝났습니다.")),
            .finish(completed("끝났습니다.")),
        ])
        let thread = try await stage.begin("끝난 하위의 요청", adapter: fake)
        let c = stage.coordinator
        _ = try await c.send(prompt: "하위 둘", thread: thread, project: stage.project, provider: .codex)
        let session = c.session(threadID: thread.id)
        await stage.settle { session?.pendingQuestions.isEmpty == false && session?.pendingApprovals.isEmpty == false }
        await t.equal("하위의 승인 · 질문을 기다린다", session?.state, .awaitingApproval)

        fake.signal("a")
        await stage.settle { session?.state == .running }
        await t.check("끝난 하위의 승인 · 질문을 걷는다", session?.pendingApprovals.isEmpty == true
                        && session?.pendingQuestions.isEmpty == true)
        await t.equal("남은 것이 없으면 실행 중으로", session?.state, .running)
        let decisions = try await stage.events(thread).filter { $0.kind == .approvalDecision }
        await t.equal("걷은 승인은 결정 행으로 닫는다", decisions.map(\.text), ["하위 작업이 끝나 취소됨"])

        fake.signal("b")
        await stage.settle { session?.pendingApprovals.count == 2 }
        fake.signal("c")
        await stage.settle { session?.pendingApprovals.count == 1 }
        await t.equal("다른 하위 · 메인의 요청은 남는다", session?.pendingApprovals.map(\.id), [main.id])
        await t.equal("메인 승인이 남았으니 계속 기다린다", session?.state, .awaitingApproval)

        if let pending = session?.pendingApprovals.first { await c.respond(approval: pending, decision: .allow) }
        await stage.settle { !c.isBusy(threadID: thread.id) && !stage.probe.finished.isEmpty }
        await t.equal("실행은 완료", stage.probe.finished.first?.1.state, .completed)
        let texts = try await stage.events(thread).filter { $0.kind == .approvalDecision }.map(\.text)
        await t.equal("결정 행: 걷은 둘 + 사람이 한 하나", texts.filter { $0 == "하위 작업이 끝나 취소됨" }.count, 2)
        await t.equal("결정 행은 셋", texts.count, 3)
    }

    // MARK: 자동 작업: 실행자의 마지막 말은 메인 응답

    private static func orchestrationIgnoresChildMessages(_ t: TestKit) async throws {
        await t.group("하위 에이전트: 자동 작업의 결과 요약")
        let stage = try await OrchestrationCoordinatorTests.Stage()
        stage.brain.queue(plan: OrchestrationCoordinatorTests.plan([OrchestrationCoordinatorTests.task("a")]))
        stage.brain.onExecute { _ in .say("a 를 만들었습니다") }
        // 실행 턴: 메인 답 뒤에 하위 에이전트의 답이 온다 (백그라운드 하위가 늦게 끝난 경우와 같다).
        let brain = stage.brain
        stage.runner.adapterFactory = { provider in
            ScriptedAgentAdapter(provider: provider) { request in
                var steps = brain.steps(for: request, provider: provider)
                if !FakeBrain.isPlanning(request.prompt) && !FakeBrain.isReview(request.prompt) {
                    steps.insert(.emit(.subAgentEvent(agentID: "toolu-child", event: .assistantMessage("CHILD-ANSWER"))),
                                 at: steps.count - 1)
                }
                return steps
            }
        }
        let job = try await stage.start()
        let end = await stage.settled(job)
        await t.equal("전체 작업 완료", end?.job.state, .completed)
        let summary = end?.attempts.first { $0.kind == .first }?.resultSummary ?? ""
        await t.check("결과 요약은 메인 답", summary.hasPrefix("a 를 만들었습니다") && !summary.contains("CHILD-ANSWER"), summary)
        await t.check("검토 담당에게도 메인 답을 넘긴다", stage.reviews.first.map {
            $0.prompt.contains("a 를 만들었습니다") && !$0.prompt.contains("CHILD-ANSWER") } ?? false)
    }

    // MARK: 인계 · Gemini 입력: 하위의 대화는 메인 대화가 아니다

    private static func handoffAndGemini(_ t: TestKit) async {
        await t.group("하위 에이전트: 인계 · Gemini 거르기")
        let parent = ThreadEvent.payload(nil, taggingParent: "toolu-agent")
        let info = SubAgentInfo(id: "toolu-agent", kind: .agent, title: "하위", isBackground: true)
        let events = [
            ThreadEvent(threadID: "t", runID: "r", seq: 1, kind: .userMessage, text: "기능을 만들어줘"),
            ThreadEvent(threadID: "t", runID: "r", seq: 2, kind: .agentMessage, provider: .claude, text: "MAIN-ANSWER 하위에게 맡겼습니다"),
            ThreadEvent(id: ThreadEvent.subAgentEventID(runID: "r", agentID: info.id), threadID: "t", runID: "r", seq: 3,
                        kind: .subAgent, provider: .claude, title: info.title, text: "", payloadJSON: info.jsonString),
            ThreadEvent(threadID: "t", runID: "r", seq: 4, kind: .agentMessage, provider: .claude, text: "CHILD-ANSWER", payloadJSON: parent),
            ThreadEvent(threadID: "t", runID: "r", seq: 5, kind: .userMessage, text: "CHILD-PROMPT 파일을 고쳐라", payloadJSON: parent),
            ThreadEvent(threadID: "t", runID: "r", seq: 6, kind: .fileChange, provider: .claude, title: "Sources/a.swift",
                        text: "Sources/a.swift", payloadJSON: ThreadEvent.payload(#"{"status":"completed"}"#, taggingParent: "toolu-agent")),
            ThreadEvent(threadID: "t", runID: "r", seq: 7, kind: .commandExecution, provider: .claude, title: "swift test",
                        text: "swift test", payloadJSON: ThreadEvent.payload(#"{"status":"completed","exitCode":0}"#, taggingParent: "toolu-agent")),
        ]
        let project = Project(id: "p", name: "프로젝트", path: "/tmp/project")
        let thread = ConversationThread(id: "t", projectID: "p", title: "제목", goal: "목표")
        let packet = HandoffPacketBuilder.build(.init(
            thread: thread, project: project, fromProvider: .claude, toProvider: .codex,
            events: events, runs: [], lastConfirmedPacket: nil, git: GitSnapshot(), baseSeq: 7))
        await t.check("결정: 메인 사용자 지시만", packet.decisions.contains { $0.contains("기능을 만들어줘") }
                        && !packet.decisions.contains { $0.contains("CHILD-PROMPT") }, "\(packet.decisions)")
        await t.check("다음 행동: 하위 프롬프트를 처리 안 된 지시로 보지 않는다",
                      !packet.nextActions.contains { $0.contains("CHILD-PROMPT") }, "\(packet.nextActions)")
        await t.check("발췌: 메인 대화만", packet.transcriptExcerpt.contains("MAIN-ANSWER")
                        && !packet.transcriptExcerpt.contains("CHILD-ANSWER") && !packet.transcriptExcerpt.contains("CHILD-PROMPT"),
                      packet.transcriptExcerpt)
        await t.check("하위의 파일 변경 사실은 둔다", packet.completed.contains { $0.contains("Sources/a.swift") }, "\(packet.completed)")
        await t.check("하위의 테스트 실행 사실은 둔다", packet.testsRun.contains { $0.contains("swift test") && $0.contains("종료 코드 0") },
                      "\(packet.testsRun)")

        let input = GeminiAssistInputBuilder.build(thread: thread, project: project, events: events, runs: [],
                                                   previousPacket: nil, rulePacket: packet, git: GitSnapshot())
        await t.check("Gemini: 메인 대화는 대화 줄", input.contains("[2] agentMessage") && input.contains("[1] userMessage"))
        await t.check("Gemini: 하위의 대화는 대화 줄이 아니다", !input.contains("[4] agentMessage") && !input.contains("[5] userMessage")
                        && input.contains("[4] subAgent.agentMessage") && input.contains("[5] subAgent.userMessage"))
        await t.check("Gemini: 하위의 파일 변경은 일의 기록으로", input.contains("[6] subAgent.fileChange"))

        let summary = GeminiAssistSummary(
            progress: [], nextActions: [GeminiEvidenceItem(text: "메인 근거", evidence: [2]),
                                        GeminiEvidenceItem(text: "하위 답 근거", evidence: [4]),
                                        GeminiEvidenceItem(text: "하위 프롬프트 근거", evidence: [5])],
            decisions: [], failedAttempts: [], cautions: [], unverified: [])
        let validated = GeminiAssistValidator.validate(summary, events: events)
        await t.equal("Gemini 검증: 다음 행동의 근거는 메인 대화만", validated.summary.nextActions.map(\.text), ["메인 근거"])
    }

    // MARK: Gemini 입력: 하위의 메시지는 대화 예산을 쓰지 않는다

    /// 예산이 차는 입력. 메인 응답 7개(각 4,000자 — 한 줄에 약 12KB)가 대화 몫(예산의 60%)을 거의 채우고,
    /// 그보다 새 하위 답(같은 크기)과 큰 명령 출력 10개가 뒤따른다. 하위 답이 대화로 셈해지면 가장 오래된 메인
    /// 응답이 밀려나고, 일의 기록이면 한 줄 요약으로 남는다 (명령 출력이 남는 공간을 먼저 쓴다).
    private static func geminiDialogBudget(_ t: TestKit) async {
        await t.group("하위 에이전트: Gemini 대화 예산")
        let parent = ThreadEvent.payload(nil, taggingParent: "toolu-agent")
        func long(_ head: String, _ count: Int) -> String { head + String(repeating: "가", count: count - head.count) }
        var events = [ThreadEvent(threadID: "t", runID: "r", seq: 1, kind: .userMessage, text: "기능을 만들어줘")]
        for i in 1...7 {
            events.append(ThreadEvent(threadID: "t", runID: "r", seq: Int64(1 + i), kind: .agentMessage, provider: .claude,
                                      title: "Claude", text: long("MAIN-\(i) ", 4_000)))
        }
        events.append(ThreadEvent(threadID: "t", runID: "r", seq: 9, kind: .agentMessage, provider: .claude,
                                  title: "Claude", text: long("CHILD-ANSWER\n", 4_000), payloadJSON: parent))
        for i in 0..<10 {
            events.append(ThreadEvent(threadID: "t", runID: "r", seq: Int64(10 + i), kind: .commandExecution, provider: .claude,
                                      title: "swift build \(i)", text: long("swift build \(i)\n", 3_200),
                                      payloadJSON: #"{"status":"completed","exitCode":1}"#))
        }
        let project = Project(id: "p", name: "프로젝트", path: "/tmp/project")
        let thread = ConversationThread(id: "t", projectID: "p", title: "제목", goal: "목표")
        let packet = HandoffPacketBuilder.build(.init(
            thread: thread, project: project, fromProvider: .claude, toProvider: .codex,
            events: events, runs: [], lastConfirmedPacket: nil, git: GitSnapshot(), baseSeq: 19))
        let input = GeminiAssistInputBuilder.build(thread: thread, project: project, events: events, runs: [],
                                                   previousPacket: nil, rulePacket: packet, git: GitSnapshot())
        await t.check("가장 오래된 메인 응답도 들어간다 (하위 답이 대화 몫을 쓰지 않는다)",
                      input.contains("[2] agentMessage · Claude: MAIN-1 "))
        await t.check("메인 응답은 모두 원문", (1...7).allSatisfy { input.contains("MAIN-\($0) 가가가") })
        await t.check("하위 답은 본문 첫 줄의 한 줄 요약",
                      input.contains("[9] subAgent.agentMessage · Claude: CHILD-ANSWER (출력 생략)"))
        await t.check("하위 답의 원문은 빠진다", !input.contains("CHILD-ANSWER\n가"))
    }

    // MARK: Codex 기록 가져오기: 하위 에이전트 스레드는 건너뛴다

    private static func codexImportSkipsSubAgents(_ t: TestKit) async {
        await t.group("하위 에이전트: Codex 기록 가져오기")
        let meta = #"{"timestamp":"2026-09-22T07:24:14.000Z","type":"session_meta","payload":{"id":"ID","timestamp":"2026-09-22T07:24:14.000Z","cwd":"/Users/me/demo-project","cli_version":"0.160.0"EXTRA}}"#
        let user = #"{"timestamp":"2026-09-22T07:24:15.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"um1","content":[{"type":"text","text":"광고 영상 만들어줘"}]}}}"#
        let copied = #"{"timestamp":"2026-09-22T07:24:16.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"광고 영상 만들어줘"}]}}"#
        func rollout(_ id: String, _ extra: String, lines: [String]) -> String {
            ([meta.replacingOccurrences(of: "ID", with: id).replacingOccurrences(of: "EXTRA", with: extra)] + lines)
                .joined(separator: "\n")
        }
        let files: [(String, String)] = [
            ("main", rollout("main-1", #","thread_source":"user","source":"vscode""#, lines: [user])),
            ("child", rollout("child-1", #","thread_source":"subagent","source":{"subagent":{"thread_spawn":{"parent_thread_id":"main-1","depth":1}}},"parent_thread_id":"main-1","agent_path":"/root/fix_messages""#, lines: [copied, copied])),
            ("guardian", rollout("guardian-1", #","thread_source":"guardian_review","source":{"subagent":"review"},"parent_thread_id":"main-1""#, lines: [copied])),
            ("parentOnly", rollout("parent-only-1", #","parent_thread_id":"main-1""#, lines: [copied])),
        ]
        func summary(_ text: String) -> ImportedSessionSummary? {
            CodexTranscript.summary(of: Data(text.utf8), fileURL: URL(fileURLWithPath: "/tmp/rollout.jsonl"))
        }
        await t.check("메인 스레드 기록은 읽는다", summary(files[0].1)?.cliSessionID == "main-1")
        await t.check("하위 스레드 기록은 건너뛴다 (thread_source · source.subagent · parent_thread_id)",
                      files.dropFirst().allSatisfy { summary($0.1) == nil })

        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-codex-sub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let day = root.appendingPathComponent("2026/09/22")
        do {
            try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
            for (name, text) in files {
                try text.write(to: day.appendingPathComponent("rollout-\(name).jsonl"), atomically: true, encoding: .utf8)
            }
        } catch {
            await t.check("고정 기록 쓰기", false, "\(error)")
            return
        }
        let folders = SessionImportScanner.scan(claudeRoot: root.appendingPathComponent("없음"), codexRoot: root, home: "/Users/me")
        await t.equal("스캔: 메인 세션만 목록에", folders.flatMap(\.sessions).map(\.cliSessionID), ["main-1"])
    }
}
