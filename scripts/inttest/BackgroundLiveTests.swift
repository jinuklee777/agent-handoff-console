import Foundation

// MARK: - 하위 에이전트 · 백그라운드 작업 · 실제 CLI (`inttest background`)

/// "메인 턴이 끝나도 남은 하위 작업을 같은 실행으로 기다린다"를 실제 CLI 로 확인한다.
///
/// **실제 claude · codex CLI 를 부르고 구독 한도를 쓴다.** `offline` · `live` · `all` 에는 들어 있지 않다 — `inttest background` 로만 돈다.
/// 앱과 같은 길이다: 실제 `RunCoordinator` → `RunSession` → 실제 `ClaudeAdapter` · `CodexAdapter` (어댑터를 주입하지 않는다),
/// 임시 SQLite · 임시 폴더. 승인 요청은 허용한다 (임시 폴더에서만 쓴다).
/// 모델은 가장 싼 것으로 고정한다: Claude `haiku`, Codex `gpt-5.6-luna`(low). `--codex-model` · `--codex-effort` 는 따르지 않는다.
/// **Codex 의 astra 는 쓰지 않는다** — 보내기 전에 스레드 선택을, 세션이 잡히면 CLI 가 알려 준 모델을 확인하고, astra 면 곧바로 멈춘다.
/// 하위 에이전트에게도 모델 · 강도를 따로 정하지 말라고 한다 (메인 것을 물려받는다 — 실측 c3).
///
///   A. Claude · 백그라운드 Agent 하나 → 대기(`turnSettled`) → CLI 가 연 후속 턴(`followUpTurnStarted`) → 후속 답으로 완료.
///      실행 하나 · 끝난 하위 행 · 사용량 하나.
///   B. Claude · 기다리는 중 중단 → 곧 취소로 끝나고, 하위는 멈춤, claude 프로세스 · 하위의 셸이 남지 않는다.
///   C. Codex · 메인이 기다리는 하위 → 하위의 `turn/completed` 가 아니라 메인의 마지막 답 뒤에 끝난다.
///   D. Codex · 메인이 기다리지 않는 하위 → 기다렸다가 하위의 답을 메인 기록에 넣고(`thread/inject_items`) 완료.
///      재개한 다음 턴(도구 금지, 답이 든 파일은 지운 뒤)이 그 답을 안다 (실측 c17r).
///
/// 대기는 대리자에 오지 않는다 — 실행기의 화면용 상태(`RunSession.isWaitingOnBackground`)를 50ms 마다 읽어 잡는다
/// (`turnSettled` 에서 켜진다). 후속 턴은 그 상태가 꺼지는 것으로 가르지 않는다: 실행이 끝날 때도 `RunSession.finish` 가
/// 첫 줄에서 끄므로 완료 통지 전에 꺼진다. 대기를 본 뒤 대리자에 새로 온 메인 응답 행(부모 표시 없음)을 후속 턴으로 잡는다 —
/// 기다리는 동안 메인은 말하지 않는다.
@MainActor
enum BackgroundLiveTests {
    static let claudeModel = "haiku"
    static let codexModel = "gpt-5.6-luna"
    static let codexEffort = "low"
    /// 중단 시험(B)의 하위가 돌리는 명령. 끝난 뒤 이 명령이 남았는지 찾는다.
    static let sleeper = "sleep 57"
    /// 기다리기 시작하고 이만큼 지나 멈춘다 (B) — 하위가 명령을 띄울 틈.
    static let interruptAfterWaiting: TimeInterval = 4
    /// 기다리는 중 멈춘 실행이 이 안에 끝나야 "곧" 이다 (어댑터의 강제 정리는 8초 뒤).
    static let interruptDeadline: TimeInterval = 12

    static func run(_ t: TestKit) async {
        await t.group("백그라운드 작업 · 준비")
        print("""
        하위 에이전트 · 백그라운드 작업 — 실제 CLI 확인
          실제 claude · codex CLI 를 부르고 구독 한도를 씁니다. 모델: Claude \(claudeModel), Codex \(codexModel)(\(codexEffort)). astra 는 쓰지 않습니다.
          임시 폴더 · 임시 DB 에서 실제 RunCoordinator → RunSession → ClaudeAdapter · CodexAdapter 로 보냅니다. 승인 요청은 허용합니다.
          A. Claude: 백그라운드 Agent 하나 → 대기 → CLI 가 연 후속 턴 → 후속 답으로 완료 (실행 하나 · 하위 행 · 사용량)
          B. Claude: 기다리는 중 중단 → 곧 취소, 하위 멈춤, claude 프로세스 · 하위의 `\(sleeper)` 가 남지 않음
          C. Codex: 메인이 기다리는 하위 → 메인의 마지막 답 뒤에 끝남 (하위의 turn/completed 에서 끝나지 않음)
          D. Codex: 메인이 기다리지 않는 하위 → 하위의 답을 메인 기록에 넣고 완료 → 재개한 다음 턴(도구 금지)이 그 답을 앎

        """)
        if LiveTests.codexModelOverride != nil || LiveTests.codexEffortOverride != nil {
            await t.note("--codex-model · --codex-effort 는 이 모드에서 쓰지 않습니다 (\(codexModel) · \(codexEffort) 고정)")
        }
        let cli = await TestEnv.resolveCLI()
        let stage: Stage
        do { stage = try await Stage() } catch {
            await t.check("임시 프로젝트 · 저장 계층 준비", false, "\(error)")
            return
        }
        print("임시 테스트 프로젝트: \(stage.folder.path)\n")

        if cli.claude != nil {
            await claudeFollowUp(t, stage)
            await claudeInterrupt(t, stage)
        } else {
            await t.check("claude CLI 실행 파일 탐색 (A · B)", false, "없음 — 건너뜀")
        }
        if cli.codex != nil {
            await codexWaited(t, stage)
            await codexNotWaited(t, stage)
        } else {
            await t.check("codex CLI 실행 파일 탐색 (C · D)", false, "없음 — 건너뜀")
        }
        await modelsUsed(t, stage)
        print("\n임시 프로젝트 유지: \(stage.root.path)")
    }

    // MARK: 무대

    /// 완료 통지와, 실행기 상태를 읽어 적은 흐름 (대기 → 후속 턴 → 끝).
    @MainActor
    final class Probe: RunCoordinatorDelegate {
        enum Mark: Equatable, CustomStringConvertible {
            case settled(remaining: Int)
            case followUp
            case finished(RunState)

            var description: String {
                switch self {
                case .settled(let n): return "대기(하위 \(n))"
                case .followUp: return "후속 턴"
                case .finished(let s): return "끝(\(s.rawValue))"
                }
            }
        }

        var marks: [Mark] = []
        var finishedAt: [String: Date] = [:]
        /// 대기를 봤고, 후속 턴의 첫 메인 응답 행을 기다린다.
        private var awaitingFollowUp = false
        /// 지금까지 본 메인 응답 행 (같은 행을 다시 받아도 새 행으로 세지 않게).
        private var mainMessageIDs: Set<String> = []

        /// 실행기가 기다리기 시작했다 (`isWaitingOnBackground` 가 켜짐).
        func noteSettled(remaining: Int) {
            marks.append(.settled(remaining: remaining))
            awaitingFollowUp = true
        }

        func runCoordinator(_ c: RunCoordinator, didUpsert event: ThreadEvent) {
            guard event.kind == .agentMessage, event.isMainStream, mainMessageIDs.insert(event.id).inserted else { return }
            // 대기 뒤에 새로 생긴 메인 응답 행 = CLI 가 연 후속 턴의 답.
            if awaitingFollowUp {
                awaitingFollowUp = false
                marks.append(.followUp)
            }
        }
        func runCoordinator(_ c: RunCoordinator, didChangeState state: RunState, run: Run?) {}
        func runCoordinator(_ c: RunCoordinator, didReceive limits: LimitSnapshot) {}
        func runCoordinator(_ c: RunCoordinator, didFinish run: Run, result: AgentTurnResult, usage: UsageRecord?) {
            finishedAt[run.id] = Date()
            marks.append(.finished(run.state))
        }
        func runCoordinator(_ c: RunCoordinator, needsAttention title: String, body: String,
                            threadID: String, kind: AttentionKind) {}
    }

    /// 한 실행의 결과 (DB 에서 다시 읽은 것).
    struct Outcome {
        var runID: String?
        var run: Run?
        /// 이 실행의 이벤트 (순번 순).
        var events: [ThreadEvent] = []
        var usage: UsageRecord?
        var marks: [Probe.Mark] = []
        var finishedAt: Date?
        /// 보내지 못했거나 도중에 멈춘 까닭.
        var problem = ""

        var finished: Bool { finishedAt != nil }
        /// 메인(하위 표시 없음)의 에이전트 메시지.
        var mainMessages: [ThreadEvent] { events.filter { $0.kind == .agentMessage && $0.parentAgentID == nil } }
        var subAgents: [SubAgentInfo] { events.filter { $0.kind == .subAgent }.compactMap(\.subAgentInfo) }
        var flow: String { marks.map(\.description).joined(separator: " → ") }
    }

    @MainActor
    final class Stage {
        let root: URL
        let folder: URL
        let store: Store
        let project: Project
        let coordinator: RunCoordinator
        private(set) var probe = Probe()
        private(set) var threads: [ConversationThread] = []
        /// astra 로 잡혀 멈춘 실행.
        private(set) var astraRuns: [String] = []

        init() async throws {
            let root = try TestEnv.makeTempProject("background")
            let folder = root.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["alpha", "beta", "gamma"] {
                try "\(name) first line\n\(name) second\n".write(to: folder.appendingPathComponent("\(name).txt"),
                                                                atomically: true, encoding: .utf8)
            }
            let store = Store(databaseURL: root.appendingPathComponent("handoff.sqlite3"))
            try await store.bootstrap()
            let project = Project(name: "background", path: folder.path)
            try await store.upsertProject(project)
            let coordinator = RunCoordinator(store: store, environment: CLIEnvironment())
            coordinator.claudePermissionMode = "acceptEdits"
            coordinator.codexSandboxMode = "workspace-write"
            coordinator.codexApprovalPolicy = "on-request"
            await coordinator.loadPrices()
            self.root = root
            self.folder = folder
            self.store = store
            self.project = project
            self.coordinator = coordinator
            coordinator.delegate = probe
        }

        func thread(_ title: String, _ provider: AgentProvider) async throws -> ConversationThread {
            var thread = ConversationThread(projectID: project.id, title: title)
            thread.preferredProvider = provider
            thread.claudeSelection = ModelSelection(model: BackgroundLiveTests.claudeModel, effort: nil)
            thread.codexSelection = ModelSelection(model: BackgroundLiveTests.codexModel, effort: BackgroundLiveTests.codexEffort)
            try await store.upsertThread(thread)
            threads.append(thread)
            return thread
        }

        /// 추측할 수 없는 값을 파일에 적는다 (하위만 읽는다).
        func writeToken(_ name: String) throws -> String {
            let value = "TK" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
            try (value + "\n").write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            return value
        }

        /// 보내고 끝날 때까지 따라간다: 승인은 허용하고, 대기 · 후속 턴을 적고, Codex 가 astra 로 잡히면 곧바로 멈춘다.
        /// 질문이 오거나 시간이 넘으면 멈추고 끝을 조금 더 기다린다. `onTick` 은 실행이 도는 동안 50ms 마다 불린다.
        func send(_ prompt: String, thread: ConversationThread, provider: AgentProvider, timeout: TimeInterval,
                  onTick: (RunSession) async -> Void = { _ in }) async -> Outcome {
            probe = Probe()
            coordinator.delegate = probe
            var outcome = Outcome()
            let run: Run
            do {
                run = try await coordinator.send(prompt: prompt, thread: thread, project: project, provider: provider)
            } catch {
                outcome.problem = "보내지 못함: \(error.localizedDescription)"
                return outcome
            }
            outcome.runID = run.id
            var waiting = false
            var answered: Set<String> = []
            var stopped = false
            var deadline = Date().addingTimeInterval(timeout)
            func stop(_ why: String) async {
                guard !stopped else { return }
                stopped = true
                outcome.problem = why
                deadline = Date().addingTimeInterval(30)
                await coordinator.interrupt(threadID: thread.id)
            }
            while probe.finishedAt[run.id] == nil {
                if Date() > deadline {
                    if stopped { outcome.problem += " · 멈춘 뒤 30초 안에 끝나지 않음"; break }
                    await stop("\(Int(timeout))초 안에 끝나지 않아 멈춤")
                }
                if let session = coordinator.session(threadID: thread.id) {
                    if provider == .codex,
                       let model = session.activeRun?.model ?? session.activeSelection?.model,
                       model.lowercased().contains("astra") {
                        if !stopped { astraRuns.append(run.id) }
                        await stop("Codex 가 astra 로 잡혀 곧바로 멈춤 (\(model))")
                    }
                    if session.isWaitingOnBackground != waiting {
                        waiting = session.isWaitingOnBackground
                        // 켜지면 대기. 꺼지는 것은 후속 턴일 수도, 실행의 끝(`finish` 의 첫 줄)일 수도 있다 —
                        // 후속 턴은 대리자가 새 메인 응답 행으로 잡는다 (`Probe.runCoordinator(_:didUpsert:)`).
                        if waiting { probe.noteSettled(remaining: session.unfinishedSubAgentCount) }
                    }
                    for request in session.pendingApprovals where !answered.contains(request.id) {
                        answered.insert(request.id)
                        await coordinator.respond(approval: request, decision: .allow)
                    }
                    if !session.pendingQuestions.isEmpty { await stop("질문이 와서 멈춤") }
                    if !stopped { await onTick(session) }
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            outcome.marks = probe.marks
            outcome.finishedAt = probe.finishedAt[run.id]
            outcome.run = (try? await store.runs(threadID: thread.id))?.first { $0.id == run.id }
            outcome.events = ((try? await store.events(threadID: thread.id)) ?? []).filter { $0.runID == run.id }
            outcome.usage = ((try? await store.usage(threadID: thread.id)) ?? []).first { $0.runID == run.id }
            return outcome
        }
    }

    // MARK: A. Claude · 대기 → 후속 턴 → 완료

    private static func claudeFollowUp(_ t: TestKit, _ stage: Stage) async {
        await t.group("백그라운드 · A. Claude 후속 턴")
        let token: String
        let thread: ConversationThread
        do {
            token = try stage.writeToken("token-a.txt")
            thread = try await stage.thread("A. 백그라운드 Agent", .claude)
        } catch {
            await t.check("A: 준비", false, "\(error)")
            return
        }
        let prompt = """
        This is a protocol test. Call the Agent tool exactly once with run_in_background set to true, subagent_type "general-purpose", \
        description "slow read", prompt "Use the Read tool to read alpha.txt, then beta.txt, then gamma.txt, then token-a.txt, one file \
        at a time. Reply with only the content of token-a.txt." Right after launching it, end your turn by replying exactly: launched. \
        Do not wait for it and do not read any files yourself. When you are later notified that it finished, reply with: bg-done: \
        followed by its result.
        """
        await t.note("A: 보냄 — 백그라운드 Agent 하나(파일 넷을 차례로 읽고 token-a.txt 의 값을 답한다), 메인은 곧바로 launched")
        let started = Date()
        let o = await stage.send(prompt, thread: thread, provider: .claude, timeout: 300)
        await t.check("A: 보내고 끝까지 갔다", o.finished && o.problem.isEmpty, o.problem)
        await t.note("A: 흐름 \(o.flow) · \(String(format: "%.1f", Date().timeIntervalSince(started)))초")
        guard o.finished else { return }

        let settled = o.marks.firstIndex { if case .settled = $0 { return true } else { return false } }
        let followUp = o.marks.firstIndex(of: .followUp)
        let finished = o.marks.firstIndex(of: .finished(.completed))
        await t.check("A: 대기(turnSettled) → 후속 턴(followUpTurnStarted) → 완료 순서",
                      settled != nil && followUp != nil && finished != nil && settled! < followUp! && followUp! < finished!, o.flow)
        let runs = (try? await stage.store.runs(threadID: thread.id)) ?? []
        await t.check("A: 후속 턴까지 실행 하나 · 완료", runs.count == 1 && o.run?.state == .completed,
                      "실행 \(runs.count)개 · \(o.run?.state.rawValue ?? "없음") \(o.run?.terminalReason ?? "")")
        let main = o.mainMessages
        await t.check("A: 마지막 메인 답은 후속 턴의 답 (bg-done · 하위가 읽은 값)",
                      main.last.map { $0.text.contains("bg-done") && $0.text.contains(token) } ?? false,
                      "값 \(token) · 답 \(main.last?.text.prefix(120) ?? "없음")")
        await t.check("A: 첫 턴의 답(launched)과 후속 답이 따로 남았다",
                      main.count >= 2 && main.dropLast().contains { $0.text.lowercased().contains("launched") },
                      main.map { String($0.text.prefix(40)) }.joined(separator: " | "))
        let agents = o.subAgents.filter { $0.kind == .agent }
        await t.check("A: 백그라운드 하위 행이 끝남(completed)으로 남았다",
                      agents.contains { $0.isBackground && $0.status == .completed },
                      agents.map { "\($0.title) \($0.status.rawValue) bg=\($0.isBackground)" }.joined(separator: " | "))
        await t.check("A: '실행 중' 으로 남은 하위 행이 없다", !o.subAgents.contains { $0.status == .running })
        let usage = ((try? await stage.store.usage(threadID: thread.id)) ?? []).filter { $0.runID == o.runID }
        await t.check("A: 사용량 하나 · 확정 · 출력 토큰 있음",
                      usage.count == 1 && usage[0].confirmed && usage[0].outputTokens > 0,
                      usage.map { "\($0.model ?? "모델 미확인") 출력 \($0.outputTokens) · 확정 \($0.confirmed)" }.joined(separator: " | "))
        if let u = o.usage {
            await t.note("A: 사용량 \(u.model ?? "모델 미확인") · 입력 \(u.inputTokens) · 캐시 읽기 \(u.cacheReadTokens) · 출력 \(u.outputTokens) · "
                         + (u.costUSD.map { String(format: "$%.4f", $0) } ?? "금액 미확인") + " (\(u.costSource.koreanName))")
        }
        await processesGone(t, stage, label: "A", name: "claude")
    }

    // MARK: B. Claude · 기다리는 중 중단

    private static func claudeInterrupt(_ t: TestKit, _ stage: Stage) async {
        await t.group("백그라운드 · B. Claude 대기 중 중단")
        let thread: ConversationThread
        do { thread = try await stage.thread("B. 대기 중 중단", .claude) } catch {
            await t.check("B: 준비", false, "\(error)")
            return
        }
        let prompt = """
        This is a protocol test. Call the Agent tool exactly once with run_in_background set to true, subagent_type "general-purpose", \
        description "sleeper", prompt "Run the Bash command: \(sleeper) (in the foreground, not in background). Then reply with: slept." \
        Right after launching it, end your turn by replying exactly: launched. Do not wait for it. When you are later notified that it \
        finished, reply with: bg-done: followed by its result.
        """
        await t.note("B: 보냄 — 백그라운드 Agent 하나(`\(sleeper)`), 기다리기 시작하고 \(Int(interruptAfterWaiting))초 뒤에 멈춘다")
        var interruptedAt: Date?
        var tree: [Proc] = []
        let o = await stage.send(prompt, thread: thread, provider: .claude, timeout: 240) { session in
            guard interruptedAt == nil, session.isWaitingOnBackground, let since = session.waitingSince,
                  Date().timeIntervalSince(since) >= interruptAfterWaiting else { return }
            tree = await descendants(named: "claude")
            interruptedAt = Date()
            await t.note("B: 기다리는 중 멈춤 — 남은 하위 \(session.unfinishedSubAgentCount)개 · claude 프로세스와 자손 \(tree.count)개")
            await stage.coordinator.interrupt(threadID: thread.id)
        }
        await t.note("B: 흐름 \(o.flow)")
        await t.check("B: 기다리는 중에 멈췄다", interruptedAt != nil && o.marks.contains { if case .settled = $0 { return true } else { return false } },
                      interruptedAt == nil ? "대기를 보지 못했거나 곧 끝났다 — \(o.problem)" : "")
        guard let interruptedAt, o.finished else {
            await t.check("B: 끝났다", o.finished, o.problem)
            return
        }
        let elapsed = o.finishedAt!.timeIntervalSince(interruptedAt)
        await t.check("B: 곧 끝났다 (\(Int(interruptDeadline))초 안)", elapsed <= interruptDeadline, String(format: "%.1f초", elapsed))
        await t.equal("B: 취소로 끝났다", o.run?.state, .cancelled)
        await t.note("B: 끝난 까닭 \(o.run?.terminalReason ?? "없음")")
        let agents = o.subAgents
        await t.check("B: 하위 행이 멈춤으로 남았다 · '실행 중' 없음",
                      agents.contains { $0.status == .stopped } && !agents.contains { $0.status == .running },
                      agents.map { "\($0.kind.rawValue) \($0.title.prefix(30)) \($0.status.rawValue)" }.joined(separator: " | "))
        if let u = o.usage {
            await t.note("B: 취소된 실행의 사용량 — 출력 \(u.outputTokens) · 확정 \(u.confirmed)")
        } else {
            await t.note("B: 취소된 실행의 사용량 기록 없음")
        }
        // 기다리는 중 본 claude 와 그 자손(하위의 셸 등)이 끝났는가. 좀비는 끝난 것으로 본다.
        let roots = tree.filter { $0.ppid == getpid() }
        var alive: [Proc] = [], sleepers: [Proc] = []
        for _ in 0..<50 {
            let table = await processes().filter { !$0.stat.hasPrefix("Z") }
            alive = tree.filter { p in table.contains { $0.pid == p.pid } }
            sleepers = table.filter { $0.command.contains(sleeper) }
            if alive.isEmpty && sleepers.isEmpty { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await t.check("B: 기다리는 중 본 claude 프로세스가 끝났다",
                      !roots.isEmpty && !alive.contains { p in roots.contains { $0.pid == p.pid } },
                      roots.isEmpty ? "기다리는 중 claude 프로세스를 찾지 못했다" : roots.map { "\($0.pid)" }.joined(separator: ","))
        await t.check("B: 하위가 띄운 `\(sleeper)` 가 남지 않았다", sleepers.isEmpty,
                      sleepers.map { "\($0.pid) \($0.command.prefix(60))" }.joined(separator: " | "))
        // 그 밖의 자손(CLI 가 띄운 MCP 서버 등)은 CLI 의 몫이라 알리기만 한다.
        let others = alive.filter { p in !roots.contains { $0.pid == p.pid } && !sleepers.contains { $0.pid == p.pid } }
        if !others.isEmpty {
            await t.note("B: claude 가 끝난 뒤 5초가 지나도 남은 자손 \(others.count)개 (뒷정리로 끝냄): "
                         + others.map { "\($0.pid) \($0.command.prefix(60))" }.joined(separator: " | "))
        }
        for p in alive + sleepers { kill(p.pid, SIGKILL) }   // 뒷정리
        await processesGone(t, stage, label: "B", name: "claude")
    }

    // MARK: C. Codex · 메인이 기다리는 하위

    private static func codexWaited(_ t: TestKit, _ stage: Stage) async {
        await t.group("백그라운드 · C. Codex 하위를 기다림")
        let token: String
        let thread: ConversationThread
        do {
            token = try stage.writeToken("token-c.txt")
            thread = try await stage.thread("C. 하위를 기다림", .codex)
        } catch {
            await t.check("C: 준비", false, "\(error)")
            return
        }
        guard await codexSelectionIsCheap(t, thread, label: "C") else { return }
        let prompt = """
        This is a protocol test of your multi-agent tools. Using your sub-agent tools, spawn exactly ONE sub-agent (do not set a model \
        or a reasoning effort for it) with this task: "Read the file token-c.txt in the current directory and reply with its content \
        only. Do not modify any files." Then wait for the sub-agent to finish, and finally reply with exactly one line: \
        child-done: <the value the sub-agent reported>. Do not read files or run commands yourself.
        """
        await t.note("C: 보냄 — 하위 하나(token-c.txt 를 읽어 답한다), 메인은 기다렸다가 child-done: <값>")
        let o = await stage.send(prompt, thread: thread, provider: .codex, timeout: 300)
        await t.check("C: 보내고 끝까지 갔다", o.finished && o.problem.isEmpty, o.problem)
        await t.note("C: 흐름 \(o.flow) · 모델 \(o.run?.model ?? "미확인")")
        guard o.finished else { return }
        await t.check("C: 완료", o.run?.state == .completed, "\(o.run?.state.rawValue ?? "없음") \(o.run?.errorMessage ?? "")")
        let agents = o.subAgents.filter { $0.kind == .agent }
        let child = agents.first { $0.status == .completed && ($0.summary ?? "").contains(token) }
        await t.check("C: 하위가 끝나 값을 답했다", child != nil,
                      agents.map { "\($0.title) \($0.status.rawValue) \(($0.summary ?? "").prefix(40))" }.joined(separator: " | "))
        let last = o.mainMessages.last
        await t.check("C: 마지막 메인 답은 하위를 기다린 뒤의 답 (child-done · 값)",
                      last.map { $0.text.contains("child-done") && $0.text.contains(token) } ?? false,
                      "값 \(token) · 답 \(last?.text.prefix(120) ?? "없음")")
        // 하위의 흐름(부모 표시) · 하위 앵커를 닫는 결과는 모두 메인의 마지막 답보다 앞이다 — 하위의 turn/completed 에서 끝나지 않았다.
        let childIDs = Set(agents.map(\.id))
        let childSeqs = o.events.filter { $0.parentAgentID != nil || ($0.kind == .toolResult && childIDs.contains($0.toolUseID ?? "")) }.map(\.seq)
        await t.check("C: 하위의 turn/completed 가 아니라 메인의 마지막 답 뒤에 끝났다",
                      !childSeqs.isEmpty && last != nil && childSeqs.max()! < last!.seq
                        && (child?.endedAt).map { end in (o.run?.endedAt).map { $0 >= end } ?? false } ?? false,
                      "하위 이벤트 \(childSeqs.count)개 · 마지막 \(childSeqs.max().map(String.init) ?? "없음") · 메인 답 \(last.map { String($0.seq) } ?? "없음")")
        await t.note("C: 메인이 기다리는 동안 앱의 대기(turnSettled)는 " + (o.marks.contains { if case .settled = $0 { return true } else { return false } } ? "있었다" : "없었다"))
        await processesGone(t, stage, label: "C", name: "codex")
    }

    // MARK: D. Codex · 메인이 기다리지 않는 하위

    private static func codexNotWaited(_ t: TestKit, _ stage: Stage) async {
        await t.group("백그라운드 · D. Codex 하위를 기다리지 않음")
        let token: String
        let thread: ConversationThread
        do {
            token = try stage.writeToken("token-d.txt")
            thread = try await stage.thread("D. 하위를 기다리지 않음", .codex)
        } catch {
            await t.check("D: 준비", false, "\(error)")
            return
        }
        guard await codexSelectionIsCheap(t, thread, label: "D") else { return }
        let prompt = """
        This is a protocol test of your multi-agent tools. Using your sub-agent tools, spawn exactly ONE sub-agent (do not set a model \
        or a reasoning effort for it) with this task: "Run the shell command `sleep 15 && cat token-d.txt` in the foreground and wait \
        for it to finish. Then reply with exactly its output and nothing else." Do NOT wait for the sub-agent and do not check on it. \
        Right after spawning it, end your turn by replying exactly: launched.
        """
        await t.note("D: 보냄 — 하위 하나(`sleep 15 && cat token-d.txt`), 메인은 기다리지 않고 곧바로 launched")
        let o = await stage.send(prompt, thread: thread, provider: .codex, timeout: 300)
        await t.check("D: 보내고 끝까지 갔다", o.finished && o.problem.isEmpty, o.problem)
        await t.note("D: 흐름 \(o.flow) · 모델 \(o.run?.model ?? "미확인")")
        guard o.finished else { return }
        await t.check("D: 메인 턴 뒤 남은 하위를 기다렸다 (turnSettled)",
                      o.marks.contains { if case .settled = $0 { return true } else { return false } }, o.flow)
        await t.check("D: 완료", o.run?.state == .completed, "\(o.run?.state.rawValue ?? "없음") \(o.run?.errorMessage ?? "")")
        let agents = o.subAgents.filter { $0.kind == .agent }
        let child = agents.first { $0.status == .completed && ($0.summary ?? "").contains(token) }
        await t.check("D: 백그라운드 하위가 끝나 값을 답했다", child?.isBackground == true,
                      agents.map { "\($0.title) \($0.status.rawValue) bg=\($0.isBackground) \(($0.summary ?? "").prefix(40))" }.joined(separator: " | "))
        await t.check("D: 실행은 하위가 끝난 뒤에 끝났다",
                      (child?.endedAt).map { end in (o.run?.endedAt).map { $0 >= end } ?? false } ?? false)
        await t.check("D: 메인의 답은 launched", o.mainMessages.last?.text.lowercased().contains("launched") == true,
                      o.mainMessages.map { String($0.text.prefix(40)) }.joined(separator: " | "))
        let injectFailures = o.events.filter { $0.kind == .systemNotice && $0.text.contains("넣지 못했습니다") }
        await t.check("D: 하위의 답을 메인 기록에 넣었다 (thread/inject_items 실패 안내 없음)", injectFailures.isEmpty,
                      injectFailures.map(\.text).joined(separator: " | "))
        await processesGone(t, stage, label: "D", name: "codex")

        // 재개한 다음 턴이 넣은 답을 아는가. 답이 든 파일은 지운다 (도구로 읽어 맞히지 못하게).
        try? FileManager.default.removeItem(at: stage.folder.appendingPathComponent("token-d.txt"))
        let ask = """
        The sub-agent you launched earlier has finished. What exact value did it report? Answer only from what is already in your \
        conversation context. Do not call any tools at all (no wait, no agent tools, no shell). If the value is not in your context, \
        reply exactly: UNKNOWN.
        """
        await t.note("D: 같은 대화로 재개해 묻는다 (도구 금지, token-d.txt 는 지웠다)")
        let before = try? await stage.store.session(threadID: thread.id, provider: .codex, accountID: "")
        let r = await stage.send(ask, thread: thread, provider: .codex, timeout: 180)
        let after = try? await stage.store.session(threadID: thread.id, provider: .codex, accountID: "")
        await t.check("D: 재개한 턴 완료", r.finished && r.run?.state == .completed,
                      "\(r.problem) \(r.run?.state.rawValue ?? "없음") \(r.run?.errorMessage ?? "")")
        await t.check("D: 같은 Codex 스레드를 이어 갔다", before?.cliSessionID != nil && before?.cliSessionID == after?.cliSessionID,
                      "\(before?.cliSessionID ?? "nil") / \(after?.cliSessionID ?? "nil")")
        await t.check("D: 다음 턴이 넣은 하위의 답을 안다", r.mainMessages.last?.text.contains(token) == true,
                      "값 \(token) · 답 \(r.mainMessages.last?.text.prefix(120) ?? "없음")")
        await processesGone(t, stage, label: "D 재개", name: "codex")
    }

    // MARK: 확인 도우미

    /// Codex 스레드 선택이 luna · low 인가 (보내기 전). astra 면 보내지 않는다.
    private static func codexSelectionIsCheap(_ t: TestKit, _ thread: ConversationThread, label: String) async -> Bool {
        let selection = thread.selection(for: .codex)
        let model = selection.model ?? ""
        let ok = model == codexModel && selection.effort == codexEffort && !model.lowercased().contains("astra")
        await t.check("\(label): 보내기 전 Codex 선택이 \(codexModel) · \(codexEffort) (astra 아님)", ok,
                      "\(selection.model ?? "모델 기본(nil)") · \(selection.effort ?? "강도 기본(nil)")")
        return ok
    }

    /// 실행이 끝난 뒤 이 검증 프로세스가 띄운 CLI 프로세스(와 그 자손)가 남지 않았는가. 종료 미확인 기록도 없어야 한다.
    private static func processesGone(_ t: TestKit, _ stage: Stage, label: String, name: String) async {
        var left: [Proc] = []
        for _ in 0..<50 {
            left = await descendants(named: name).filter { !$0.stat.hasPrefix("Z") }
            if left.isEmpty { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await t.check("\(label): 끝난 뒤 \(name) 프로세스가 남지 않았다 · 종료 미확인 없음",
                      left.isEmpty && stage.coordinator.unterminatedProcesses.isEmpty,
                      (left.map { "\($0.pid) \($0.command.prefix(60))" } + stage.coordinator.unterminatedProcesses).joined(separator: " | "))
        await t.check("\(label): 남은 실행 없음", stage.coordinator.activeSessions.isEmpty)
    }

    /// 쓴 모델: Claude 는 haiku, Codex 는 luna, astra 는 없다 (실행 행 · 사용량 모두).
    private static func modelsUsed(_ t: TestKit, _ stage: Stage) async {
        await t.group("백그라운드 작업 · 쓴 모델")
        var claude: [String] = [], codex: [String] = []
        for thread in stage.threads {
            let runs = (try? await stage.store.runs(threadID: thread.id)) ?? []
            let usage = (try? await stage.store.usage(threadID: thread.id)) ?? []
            for run in runs {
                let models = ([run.model] + usage.filter { $0.runID == run.id }.map(\.model)).compactMap { $0 }
                if run.provider == .claude { claude += models } else { codex += models }
            }
        }
        await t.check("astra 를 쓰지 않았다", !(claude + codex).contains { $0.lowercased().contains("astra") } && stage.astraRuns.isEmpty,
                      Set(claude + codex).sorted().joined(separator: ", "))
        await t.check("Claude 는 haiku 만", claude.allSatisfy { $0.lowercased().contains("haiku") }, Set(claude).sorted().joined(separator: ", "))
        await t.check("Codex 는 luna 만", codex.allSatisfy { $0.lowercased().contains("luna") }, Set(codex).sorted().joined(separator: ", "))
    }

    // MARK: 프로세스

    struct Proc {
        let pid: Int32
        let ppid: Int32
        let stat: String
        let command: String
    }

    /// 지금의 프로세스 표 (`ps`). 읽지 못하면 빈 배열.
    static func processes() async -> [Proc] {
        let result = await CLIEnvironment.captureOutput(executable: "/bin/ps", arguments: ["-Awwo", "pid=,ppid=,stat=,command="],
                                                        environment: ProcessInfo.processInfo.environment, timeout: 10)
        guard case .success(let output) = result else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " })
            guard fields.count >= 4, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { return nil }
            return Proc(pid: pid, ppid: ppid, stat: String(fields[2]), command: fields[3...].joined(separator: " "))
        }
    }

    /// 이 검증 프로세스가 띄운, 명령에 `name` 이 든 프로세스와 그 자손 전부.
    static func descendants(named name: String) async -> [Proc] {
        let table = await processes()
        let me = getpid()
        var found = table.filter { $0.ppid == me && $0.command.lowercased().contains(name) }
        var frontier = Set(found.map(\.pid))
        while !frontier.isEmpty {
            let next = table.filter { frontier.contains($0.ppid) }
            found += next
            frontier = Set(next.map(\.pid))
        }
        return found
    }
}
