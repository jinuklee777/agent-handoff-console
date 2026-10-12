import Foundation

// MARK: - 턴 옵션(읽기 전용 · 출력 스키마)과 어댑터 주입

/// 세 어댑터가 턴 옵션을 CLI 인자 · 매개변수로 어떻게 옮기는지(순수 함수)와,
/// 가짜 어댑터를 주입한 `RunCoordinator` 의 실행 흐름을 검증한다. CLI · 네트워크를 쓰지 않는다.
@MainActor
enum TurnOptionsTests {

    static let schema = #"{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"],"additionalProperties":false}"#

    static func run(_ t: TestKit) async {
        await claudeArguments(t)
        await codexParameters(t)
        await antigravityArguments(t)
        await structuredResults(t)
        await coordinatorWithFakeAdapter(t)
        await codexFamilySelection(t)
        await approvalRecords(t)
        await questionRecords(t)
    }

    /// 질문 도구(Claude `AskUserQuestion`)의 기록 (2차 시험 conv-1 · conv-6): 자동 승인이어도 카드로 남고(켜는 순간의 자동 허용도
    /// 건너뛴다), 적은 답은 결정 행에 "답함" · 답으로 — 거절 · 사유가 아니다. 기록을 다시 읽으면 도구 행은 "답함".
    private static func questionRecords(_ t: TestKit) async {
        await t.group("승인 결정 기록: 질문에 적은 답 · 자동 승인은 질문을 대신 답하지 않는다")
        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ahc-question-\(UUID().uuidString).sqlite3")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + s) } }
        let store = Store(databaseURL: dbURL)
        do {
            try await store.bootstrap()
            let project = Project(name: "가짜", path: NSTemporaryDirectory())
            try await store.upsertProject(project)
            let thread = ConversationThread(projectID: project.id, title: "질문 기록")
            try await store.upsertThread(thread)
            let coordinator = RunCoordinator(store: store, environment: CLIEnvironment())
            let probe = CoordinatorProbe(coordinator: coordinator)
            coordinator.delegate = probe
            coordinator.autoApprovalThreadIDs = [thread.id]
            let input = #"{"questions":[{"question":"어느 방식으로 할까요?"}]}"#
            let question = ApprovalRequest(id: "ask-1", runID: "", provider: .claude, kind: .tool, toolName: AskedQuestion.claudeToolName,
                                           title: "AskUserQuestion", detail: input, toolUseID: "toolu-ask", input: input)
            let fake = ScriptedAgentAdapter(provider: .claude, steps: [
                .emit(.sessionEstablished(sessionID: "s", model: "fake", cliVersion: nil)),
                .emit(.toolStarted(id: "toolu-ask", name: AskedQuestion.claudeToolName, detail: input)),
                .emit(.approvalRequested(question)),
                .waitApproval(id: "ask-1"),
                .emit(.toolFinished(id: "toolu-ask", name: AskedQuestion.claudeToolName, output: "B 방식으로", isError: true)),
                .finish(AgentTurnResult(state: .completed, terminalReason: "completed", sessionID: "s")),
            ])
            coordinator.adapterFactory = { _ in fake }
            try await coordinator.send(prompt: "정리해 줘", thread: thread, project: project, provider: .claude)
            for _ in 0..<500 where coordinator.session(threadID: thread.id)?.pendingApprovals.isEmpty != false {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            let session = coordinator.session(threadID: thread.id)
            await t.equal("자동 승인이어도 질문은 카드로 남는다", session?.pendingApprovals.map(\.id), ["ask-1"])
            await session?.approvePendingAutomatically()
            await t.equal("켜는 순간의 자동 허용도 질문은 건너뛴다", session?.pendingApprovals.map(\.id), ["ask-1"])
            if let pending = session?.pendingApprovals.first {
                await coordinator.respond(approval: pending, decision: .answer("B 방식으로"))
            }
            await t.check("끝까지 돈다", await probe.waitUntilIdle(timeout: 10))
            await t.equal("어댑터에는 답으로 간다", fake.decisions["ask-1"], .answer("B 방식으로"))
            let events = try await store.events(threadID: thread.id)
            let row = events.first { $0.kind == .approvalDecision }
            let info = row?.approvalDecisionInfo
            await t.check("결정 행: 답함 · 답 (거절 · 사유가 아니다)",
                          row?.text == "답함" && info?.decision == .answered && info?.answer == "B 방식으로" && info?.reason == nil
                            && info?.toolName == AskedQuestion.claudeToolName, row?.payloadJSON ?? "nil")
            let mark: ApprovalMark? = ExecutionParser.entries(from: events.filter { StreamBuilder.isExecutionLog($0) }, projectPath: nil)
                .compactMap { entry -> ApprovalMark? in
                    if case .tool(let info) = entry.kind { return info.approval } else { return nil }
                }.first
            await t.equal("기록을 다시 읽으면 도구 행은 답함", mark, .answered("B 방식으로"))
        } catch {
            await t.check("질문 기록 시나리오 예외", false, "\(error)")
        }
    }

    // MARK: 승인 결정 기록 (도구 행과 잇는 약속)

    /// 결정 행의 약속 (공통 규칙 "승인 결정 기록의 약속"): `toolUseID` = 요청의 것, `payloadJSON` 의 `ahc.approval` 에 결정 · 사유 ·
    /// 요청 제목 · 도구 · 종류 · 요청 ID. 두 번째 결정(두 번 누름)은 보내지도 적지도 않는다. 질문의 답은 질문 행에 (비밀은 가린다) —
    /// 어댑터가 알려 오는 "응답 전송" 은 결정 행이 아니다.
    private static func approvalRecords(_ t: TestKit) async {
        await t.group("승인 결정 기록: 도구 행과 잇는 약속")
        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ahc-approval-\(UUID().uuidString).sqlite3")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + s) } }
        let store = Store(databaseURL: dbURL)
        do {
            try await store.bootstrap()
            let project = Project(name: "가짜", path: NSTemporaryDirectory())
            try await store.upsertProject(project)
            let thread = ConversationThread(projectID: project.id, title: "승인 기록")
            try await store.upsertThread(thread)
            let coordinator = RunCoordinator(store: store, environment: CLIEnvironment())
            let probe = CoordinatorProbe(coordinator: coordinator)
            coordinator.delegate = probe

            let approval = ApprovalRequest(id: "ap-9", runID: "", provider: .claude, kind: .tool, toolName: "Bash",
                                           title: "rm -rf build", detail: "rm -rf build", toolUseID: "toolu-1")
            let question = UserQuestion(id: "q-1", runID: "", provider: .codex, items: [
                .init(id: "scope", header: "범위", question: "어디까지?", options: ["a", "b"], allowsOther: false, isSecret: false),
                .init(id: "key", header: "", question: "키는?", options: [], allowsOther: false, isSecret: true),
            ])
            let fake = ScriptedAgentAdapter(provider: .claude, steps: [
                .emit(.sessionEstablished(sessionID: "s", model: "fake", cliVersion: nil)),
                .emit(.toolStarted(id: "toolu-1", name: "Bash", detail: #"{"command":"rm -rf build"}"#)),
                .emit(.approvalRequested(approval)),
                .waitApproval(id: "ap-9"),
                .emit(.toolFinished(id: "toolu-1", name: "Bash", output: "남겨 두세요", isError: true)),
                .emit(.questionAsked(question)),
                .waitSignal("answered"),
                .emit(.approvalResolved(id: "q-1", decision: "응답 전송")),
                .finish(AgentTurnResult(state: .completed, terminalReason: "completed", sessionID: "s")),
            ])
            coordinator.adapterFactory = { _ in fake }
            probe.onApproval = { request, c in
                Task { @MainActor in
                    await c.respond(approval: request, decision: .deny("남겨 두세요"))
                    // 두 번 누름 · 늦은 단축키 — 첫 결정만 간다.
                    await c.respond(approval: request, decision: .allow)
                }
            }
            try await coordinator.send(prompt: "지워", thread: thread, project: project, provider: .claude)
            for _ in 0..<500 where coordinator.session(threadID: thread.id)?.pendingQuestions.isEmpty != false {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            if let asked = coordinator.session(threadID: thread.id)?.pendingQuestions.first {
                await coordinator.respond(question: asked, answers: ["scope": "b", "key": "secret-123"])
            }
            fake.signal("answered")
            await t.check("끝까지 돈다", await probe.waitUntilIdle(timeout: 10))
            probe.onApproval = nil

            let events = try await store.events(threadID: thread.id)
            let decisions = events.filter { $0.kind == .approvalDecision }
            await t.equal("결정 행은 하나 (질문의 응답 전송은 결정 행이 아니다)", decisions.count, 1)
            await t.equal("첫 결정만 어댑터에 간다 (두 번째는 무시)", fake.decisions["ap-9"], .deny("남겨 두세요"))
            let row = decisions.first
            await t.check("결정 행: 제목 · 글 · 도구 호출 ID", row?.title == "승인 결정" && row?.text == "거절" && row?.toolUseID == "toolu-1",
                          "\(String(describing: row))")
            let info = row?.approvalDecisionInfo
            await t.check("결정 행의 구조화된 내용: 결정 · 사유 · 요청",
                          info?.decision == .deny && info?.reason == "남겨 두세요" && info?.requestTitle == "rm -rf build"
                            && info?.toolName == "Bash" && info?.approvalKind == "tool" && info?.requestID == "ap-9",
                          row?.payloadJSON ?? "nil")
            await t.equal("요청 행에 요청 ID", events.first { $0.kind == .approvalRequest }?.approvalRequestID, "ap-9")
            let asked = events.first { $0.kind == .userQuestion }
            await t.check("질문 행에 답 (비밀은 가린다)",
                          asked?.text == "범위: 어디까지?\n→ b\n키는?\n→ (가린 답)" && asked?.isAnsweredQuestion == true
                            && asked?.text.contains("secret") == false, asked?.text ?? "nil")
            let entries = ExecutionParser.entries(from: events.filter { StreamBuilder.isExecutionLog($0) }, projectPath: nil)
            let mark: ApprovalMark? = entries.compactMap { entry -> ApprovalMark? in
                if case .tool(let info) = entry.kind { return info.approval }
                if case .command(let info) = entry.kind { return info.approval }
                return nil
            }.first
            await t.equal("기록을 다시 읽으면 도구 행은 거절함 · 사유 (오류가 아니다)", mark, .denied(reason: "남겨 두세요"))
        } catch {
            await t.check("승인 결정 기록 시나리오 예외", false, "\(error)")
        }
    }

    // MARK: Codex 계열 선택 (`gpt-*-sol`)은 보낼 때 푼다

    private static func codexFamilySelection(_ t: TestKit) async {
        await t.group("Codex 계열 선택: 보낼 때 지금 목록의 최신으로")
        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ahc-family-\(UUID().uuidString).sqlite3")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + s) } }
        let store = Store(databaseURL: dbURL)
        do {
            try await store.bootstrap()
            let project = Project(name: "계열", path: NSTemporaryDirectory())
            try await store.upsertProject(project)
            var thread = ConversationThread(projectID: project.id, title: "Sol 따라가기")
            thread.codexSelection = ModelSelection(model: "gpt-*-sol", effort: "high")
            try await store.upsertThread(thread)
            func efforts(_ values: [String]) -> [[String: Any]] { values.map { ["reasoningEffort": $0] } }
            let listed = ModelCatalog.parseCodexModels([
                ["id": "gpt-5.6-sol", "supportedReasoningEfforts": efforts(["low", "high"])],
                ["id": "gpt-6-sol", "supportedReasoningEfforts": efforts(["low", "medium", "high"])],
                ["id": "gpt-6-luna", "supportedReasoningEfforts": efforts(["low", "medium"])],
            ])
            try await store.replaceModelOptions(listed, scope: thread.scope(for: .codex))

            let coordinator = RunCoordinator(store: store, environment: CLIEnvironment())
            let probe = CoordinatorProbe(coordinator: coordinator)
            coordinator.delegate = probe
            var fake = ScriptedAgentAdapter.replying("sol", provider: .codex)
            coordinator.adapterFactory = { [fake] _ in fake }
            try await coordinator.send(prompt: "하나", thread: thread, project: project, provider: .codex)
            _ = await probe.waitUntilIdle(timeout: 10)
            await t.equal("계열 선택은 목록의 최신 ID 로 넘긴다", fake.requests.first?.model, "gpt-6-sol")
            await t.equal("강도는 그 모델의 단계에서", fake.requests.first?.effort, "high")

            // 새 버전이 목록에 나오면 같은 선택이 그것으로 간다 (선택은 그대로).
            try await store.replaceModelOptions(listed + ModelCatalog.parseCodexModels([
                ["id": "gpt-6.1-sol", "supportedReasoningEfforts": efforts(["low", "high"])]]), scope: thread.scope(for: .codex))
            fake = ScriptedAgentAdapter.replying("sol 6.1", provider: .codex)
            coordinator.adapterFactory = { [fake] _ in fake }
            try await coordinator.send(prompt: "둘", thread: thread, project: project, provider: .codex)
            _ = await probe.waitUntilIdle(timeout: 10)
            await t.equal("새 버전이 나오면 따라간다", fake.requests.first?.model, "gpt-6.1-sol")

            // 그 계열이 목록에 없으면 흔적 없이 거절한다.
            var astra = ConversationThread(projectID: project.id, title: "Astra 따라가기")
            astra.codexSelection = ModelSelection(model: "gpt-*-astra")
            try await store.upsertThread(astra)
            var rejected = ""
            do {
                try await coordinator.send(prompt: "셋", thread: astra, project: project, provider: .codex)
            } catch { rejected = error.localizedDescription }
            await t.check("목록에 없는 계열은 이유와 함께 거절", rejected.contains("astra 계열"), rejected)
            await t.equal("거절한 실행은 기록하지 않는다", try await store.runs(threadID: astra.id).count, 0)
        } catch {
            await t.check("Codex 계열 선택 시험 준비", false, "\(error)")
        }
    }

    private static func request(readOnly: Bool = false, outputSchema: String? = nil,
                                resume: String? = nil) -> AgentTurnRequest {
        AgentTurnRequest(runID: "run-1", prompt: "계획을 세워줘", workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                         resumeSessionID: resume, preferredNewSessionID: resume == nil ? "new-session" : nil,
                         model: "some-model", effort: "low", readOnly: readOnly, outputSchema: outputSchema)
    }

    // MARK: 인자 · 매개변수

    private static func claudeArguments(_ t: TestKit) async {
        await t.group("턴 옵션: Claude 인자")
        let plain = ClaudeAdapter.arguments(for: request(), permissionMode: "manual")
        await t.check("옵션이 없으면 쓰기 도구를 빼지 않는다", !plain.contains("--disallowedTools") && !plain.contains("--json-schema"))
        await t.check("기존 인자 유지",
                      plain.contains("--permission-prompt-tool") && plain.contains("--session-id") && plain.contains("--effort"))

        let args = ClaudeAdapter.arguments(for: request(readOnly: true, outputSchema: schema), permissionMode: "manual")
        let tail = Array(args.suffix(ClaudeAdapter.writeTools.count + 1))
        await t.equal("읽기 전용: 쓰기 도구를 빼고, 가변 인자라 맨 끝에 둔다", tail, ["--disallowedTools"] + ClaudeAdapter.writeTools)
        await t.check("쓰기 도구에 Write · Edit · Bash 포함",
                      Set(["Write", "Edit", "NotebookEdit", "Bash"]).isSubset(of: Set(ClaudeAdapter.writeTools)))
        await t.check("plan 모드로 바꾸지 않는다", args.contains("manual") && !args.contains("plan"))
        if let i = args.firstIndex(of: "--json-schema") {
            await t.equal("출력 스키마 전달", args[i + 1], schema)
        } else {
            await t.check("출력 스키마 전달", false)
        }
        let resumed = ClaudeAdapter.arguments(for: request(readOnly: true, resume: "abc"), permissionMode: "manual")
        await t.check("재개 턴에도 읽기 전용 적용", resumed.contains("--resume") && resumed.contains("--disallowedTools"))
    }

    private static func codexParameters(_ t: TestKit) async {
        await t.group("턴 옵션: Codex 매개변수")
        let normal = CodexAdapter.threadParams(for: request(), sandboxMode: "workspace-write",
                                               approvalPolicy: "on-request", resume: nil)
        await t.equal("기본: 설정의 샌드박스", normal["sandbox"] as? String, "workspace-write")
        await t.equal("기본: 설정의 승인 정책", normal["approvalPolicy"] as? String, "on-request")
        await t.check("새 스레드에는 threadId 가 없다", normal["threadId"] == nil && normal["excludeTurns"] == nil)
        let instructed = CodexAdapter.threadParams(for: request(), sandboxMode: "workspace-write", approvalPolicy: "on-request",
                                                   resume: "thread-9", developerInstructions: CodexAdapter.toolUseInstruction)
        await t.equal("도구를 쓰라는 개발자 지시 (시작 · 재개 모두)", instructed["developerInstructions"] as? String,
                      CodexAdapter.toolUseInstruction)
        await t.check("사용자가 config.toml 에 둔 developer_instructions 는 덮지 않는다",
                      CodexAdapter.configDefinesDeveloperInstructions("model = \"x\"\n  developer_instructions = \"\"\"\nmine\n\"\"\"\n")
                        && !CodexAdapter.configDefinesDeveloperInstructions("model = \"x\"\n# developer_instructions 는 없음\n")
                        && !CodexAdapter.configDefinesDeveloperInstructions(""))

        let readOnly = CodexAdapter.threadParams(for: request(readOnly: true, resume: "thread-9"),
                                                 sandboxMode: "workspace-write", approvalPolicy: "on-request",
                                                 resume: "thread-9")
        await t.equal("읽기 전용: 스레드를 read-only 로 연다", readOnly["sandbox"] as? String, "read-only")
        await t.equal("읽기 전용: 승인을 묻지 않는다 (사람이 밖으로 내보낼 수 없게)", readOnly["approvalPolicy"] as? String, "never")
        await t.equal("재개: threadId", readOnly["threadId"] as? String, "thread-9")
        await t.equal("재개: 지난 턴 제외", readOnly["excludeTurns"] as? Bool, true)

        // 읽기 전용 턴 뒤 같은 스레드를 쓰기 턴으로 재개하면 설정의 샌드박스를 다시 넘긴다 (읽기 전용이 새지 않는 근거).
        let after = CodexAdapter.threadParams(for: request(resume: "thread-9"), sandboxMode: "workspace-write",
                                              approvalPolicy: "on-request", resume: "thread-9")
        await t.equal("읽기 전용 뒤의 쓰기 턴: 샌드박스 복귀", after["sandbox"] as? String, "workspace-write")

        let turn = CodexAdapter.turnParams(for: request(readOnly: true, outputSchema: schema), threadID: "thread-9")
        await t.equal("턴: 읽기 전용 샌드박스 정책", (turn["sandboxPolicy"] as? [String: Any])?["type"] as? String, "readOnly")
        await t.equal("턴: 승인 없음", turn["approvalPolicy"] as? String, "never")
        await t.equal("턴: 출력 스키마는 객체로", ((turn["outputSchema"] as? [String: Any])?["required"] as? [String]) ?? [], ["ok"])
        await t.equal("턴: 모델 · 강도 유지", "\(turn["model"] as? String ?? "")/\(turn["effort"] as? String ?? "")", "some-model/low")

        let plainTurn = CodexAdapter.turnParams(for: request(), threadID: "thread-9")
        await t.check("옵션이 없으면 턴에 정책을 넣지 않는다",
                      plainTurn["sandboxPolicy"] == nil && plainTurn["approvalPolicy"] == nil && plainTurn["outputSchema"] == nil)
        await t.check("JSON 객체가 아닌 스키마는 넘기지 않는다",
                      CodexAdapter.schemaObject("[1,2]") == nil && CodexAdapter.schemaObject("{oops") == nil
                        && CodexAdapter.schemaObject(nil) == nil)
    }

    private static func antigravityArguments(_ t: TestKit) async {
        await t.group("턴 옵션: Antigravity 인자")
        let args = AntigravityAdapter.arguments(for: request(outputSchema: schema), sandbox: true, printTimeout: "0")
        if let i = args.firstIndex(of: "--json-schema") {
            await t.equal("출력 스키마 전달", args[i + 1], schema)
        } else {
            await t.check("출력 스키마 전달", false)
        }
        await t.check("옵션이 없으면 스키마 인자 없음",
                      !AntigravityAdapter.arguments(for: request(), sandbox: true, printTimeout: "0").contains("--json-schema"))
        await t.check("읽기 전용을 보장하지 못하는 제공자로 표시", !AgentProvider.gemini.supportsReadOnlyTurns
                        && AgentProvider.claude.supportsReadOnlyTurns && AgentProvider.codex.supportsReadOnlyTurns)

        // 코디네이터를 거치지 않고 어댑터에 직접 와도 프로세스를 띄우지 않고 끝낸다.
        let adapter = AntigravityAdapter(executablePath: "/nonexistent/agy", environment: [:], cliVersion: nil)
        var result: AgentTurnResult?
        for await event in adapter.start(request(readOnly: true)) {
            if case .finished(let r) = event { result = r }
        }
        await t.equal("읽기 전용 요청은 실행하지 않고 실패로 끝낸다", result?.terminalReason, "read_only_unsupported")
        await t.check("프로세스를 띄우지 않았다", adapter.currentPID == nil)
    }

    private static func structuredResults(_ t: TestKit) async {
        await t.group("턴 옵션: 구조화 응답")
        let obj: [String: Any] = ["type": "result", "subtype": "success", "is_error": false, "session_id": "s",
                                  "result": #"{"ok":true}"#, "structured_output": ["ok": true]]
        let parsed = ClaudeAdapter.interpretResult(obj, userCancelled: false, fallbackModel: nil, startedAt: Date()).result
        await t.equal("Claude: structured_output 를 JSON 글로", parsed.structuredOutput, #"{"ok":true}"#)
        var plain = obj
        plain.removeValue(forKey: "structured_output")
        let noSchema = ClaudeAdapter.interpretResult(plain, userCancelled: false, fallbackModel: nil, startedAt: Date()).result
        await t.check("Claude: 스키마를 주지 않은 턴은 nil", noSchema.structuredOutput == nil)
    }

    // MARK: 가짜 어댑터로 도는 RunCoordinator

    private static func coordinatorWithFakeAdapter(_ t: TestKit) async {
        await t.group("어댑터 주입: 가짜 어댑터로 실행 흐름")
        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ahc-fake-\(UUID().uuidString).sqlite3")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + s) } }
        let store = Store(databaseURL: dbURL)
        do {
            try await store.bootstrap()
            let project = Project(name: "가짜", path: NSTemporaryDirectory())
            try await store.upsertProject(project)
            let thread = ConversationThread(projectID: project.id, title: "가짜 실행")
            try await store.upsertThread(thread)
            let other = ConversationThread(projectID: project.id, title: "다른 스레드")
            try await store.upsertThread(other)

            // 주입된 어댑터는 CLI 설치 확인을 건너뛴다.
            let coordinator = RunCoordinator(store: store, environment: CLIEnvironment())
            coordinator.maxConcurrentRuns = 1   // 앱의 실행 슬롯과 같게. 여러 실행은 아래 `multipleRuns` 가 본다.
            let probe = CoordinatorProbe(coordinator: coordinator)
            coordinator.delegate = probe

            // 1) 한 번의 응답. 턴 옵션이 어댑터까지 가고 구조화 응답이 끝까지 온다.
            var fake = ScriptedAgentAdapter.replying(#"{"ok":true}"#, provider: .claude,
                                                     structuredOutput: #"{"ok":true}"#)
            coordinator.adapterFactory = { [fake] provider in provider == .claude ? fake : nil }
            let run = try await coordinator.send(prompt: "계획을 세워줘", thread: thread, project: project,
                                                 provider: .claude,
                                                 turn: AgentTurnOptions(readOnly: true, outputSchema: schema))
            await t.check("가짜 어댑터로 유휴 복귀", await probe.waitUntilIdle(timeout: 10))
            await t.equal("요청이 어댑터에 한 번 도착", fake.requests.count, 1)
            await t.equal("읽기 전용이 요청에 실림", fake.requests.first?.readOnly, true)
            await t.equal("출력 스키마가 요청에 실림", fake.requests.first?.outputSchema, schema)
            await t.equal("완료 통지의 실행 ID", probe.finished.first?.0.id, run.id)
            await t.equal("완료 통지의 스레드 ID (선택된 화면과 무관하게 주인을 찾는 근거)", probe.finished.first?.0.threadID, thread.id)
            await t.equal("구조화 응답이 완료 통지까지", probe.finished.first?.1.structuredOutput, #"{"ok":true}"#)
            await t.equal("상태 전이", probe.states.map(\.rawValue), ["starting", "running", "completed"])
            let saved = try await store.run(id: run.id)
            await t.equal("실행 기록 저장: 완료", saved?.state, .completed)
            let kinds = try await store.events(threadID: thread.id).map(\.kind)
            await t.check("이벤트 저장: 사용자 메시지와 에이전트 메시지", kinds.contains(.userMessage) && kinds.contains(.agentMessage))
            let session = try await store.session(threadID: thread.id, provider: .claude, accountID: "")
            await t.equal("세션 ID 저장 (다음 턴이 재개할 값)", session?.cliSessionID, "fake-session")
            await t.check("끝난 뒤 어댑터 종료", fake.wasShutDown)

            // 2) 다음 턴은 저장된 세션을 재개한다. 옵션을 주지 않으면 쓰기 턴이다.
            fake = ScriptedAgentAdapter.replying("둘째 응답")
            coordinator.adapterFactory = { [fake] _ in fake }
            try await coordinator.send(prompt: "이어서", thread: thread, project: project, provider: .claude)
            _ = await probe.waitUntilIdle(timeout: 10)
            await t.equal("둘째 턴: 세션 재개", fake.requests.first?.resumeSessionID, "fake-session")
            await t.equal("둘째 턴: 읽기 전용 아님", fake.requests.first?.readOnly, false)

            // 3) 읽기 전용을 보장 못 하는 제공자는 흔적 없이 거절한다.
            let before = try await store.runs(threadID: other.id).count
            var rejected = ""
            do {
                try await coordinator.send(prompt: "계획", thread: other, project: project, provider: .gemini,
                                           turn: AgentTurnOptions(readOnly: true))
            } catch { rejected = error.localizedDescription }
            await t.check("Antigravity 읽기 전용 턴 거절", rejected.contains("읽기 전용"), rejected)
            await t.equal("거절한 턴은 실행 기록을 남기지 않는다", try await store.runs(threadID: other.id).count, before)
            await t.check("거절 뒤에도 유휴", !coordinator.isBusy)

            // 4) 승인 왕복과 실행 중 중복 전송 거절.
            let approval = ApprovalRequest(id: "ap-1", runID: "", provider: .codex, kind: .command,
                                           toolName: "shell", title: "명령 실행", detail: "swift build")
            let gated = ScriptedAgentAdapter(provider: .codex, steps: [
                .emit(.sessionEstablished(sessionID: "fake-codex", model: "fake-model", cliVersion: nil)),
                .emit(.approvalRequested(approval)),
                .waitApproval(id: "ap-1"),
                .emit(.assistantMessage("승인받고 끝냈습니다")),
                .finish(AgentTurnResult(state: .completed, terminalReason: "completed", sessionID: "fake-codex")),
            ])
            coordinator.adapterFactory = { _ in gated }
            var busyRejected = false
            probe.onApproval = { request, c in
                Task { @MainActor in
                    do { try await c.send(prompt: "끼어들기", thread: other, project: project, provider: .claude) }
                    catch { busyRejected = true }
                    await c.respond(approval: request, decision: .allow)
                }
            }
            try await coordinator.send(prompt: "빌드해줘", thread: thread, project: project, provider: .codex)
            await t.check("승인 뒤 유휴 복귀", await probe.waitUntilIdle(timeout: 10))
            probe.onApproval = nil
            await t.check("승인 대기 상태를 거쳤다", probe.states.contains(.awaitingApproval))
            await t.check("승인 대기 중의 다른 전송은 거절 (실행 슬롯 하나)", busyRejected)
            await t.equal("승인 응답이 어댑터에 도착", gated.decisions["ap-1"], .allow)
            await t.equal("다른 스레드에는 실행이 생기지 않았다", try await store.runs(threadID: other.id).count, before)

            // 5) 중단.
            let hanging = ScriptedAgentAdapter(provider: .claude, steps: [
                .emit(.sessionEstablished(sessionID: "fake-session", model: "fake-model", cliVersion: nil)),
                .emit(.assistantDelta("생각 중")),
                .waitInterrupt,
            ])
            coordinator.adapterFactory = { _ in hanging }
            let hung = try await coordinator.send(prompt: "오래 걸리는 일", thread: thread, project: project, provider: .claude)
            try? await Task.sleep(nanoseconds: 100_000_000)
            await coordinator.interrupt()
            await t.check("중단 뒤 유휴 복귀", await probe.waitUntilIdle(timeout: 10))
            await t.equal("중단한 실행은 취소로 기록", try await store.run(id: hung.id)?.state, .cancelled)

            // 6) 한도 도달은 능력 실패와 구분되어 올라온다 (자동 인계 · 오케스트레이션이 보는 신호).
            let capped = ScriptedAgentAdapter(provider: .claude, steps: [
                .emit(.sessionEstablished(sessionID: "fake-session", model: "fake-model", cliVersion: nil)),
                .finish(AgentTurnResult(state: .rateLimited, terminalReason: "limit", isError: true,
                                        errorMessage: "usage limit", sessionID: "fake-session",
                                        limitStatus: .subscriptionCap)),
            ])
            coordinator.adapterFactory = { _ in capped }
            let limited = try await coordinator.send(prompt: "한도", thread: thread, project: project, provider: .claude)
            _ = await probe.waitUntilIdle(timeout: 10)
            await t.equal("한도 도달 상태로 기록", try await store.run(id: limited.id)?.state, .rateLimited)
            await t.check("한도 도달 알림", probe.attentions.contains { $0.1 == .limitReached })
            await t.equal("끝난 뒤 단수 상태는 마지막 실행의 것", coordinator.state, .rateLimited)
            try await multipleRuns(t, store: store, project: project)
        } catch {
            await t.check("가짜 어댑터 실행 중 예외", false, "\(error)")
        }
    }

    /// 여러 실행: 대화마다 하나, 다른 대화는 함께 돈다.
    private static func multipleRuns(_ t: TestKit, store: Store, project: Project) async throws {
        await t.group("실행기: 여러 실행 (대화마다 하나)")
        var threads: [ConversationThread] = []
        for index in 0..<3 {
            let thread = ConversationThread(projectID: project.id, title: "동시 \(index)")
            try await store.upsertThread(thread)
            threads.append(thread)
        }
        let coordinator = RunCoordinator(store: store, environment: CLIEnvironment())
        let probe = CoordinatorProbe(coordinator: coordinator)
        coordinator.delegate = probe
        let approval = ApprovalRequest(id: "ap-multi", runID: "", provider: .codex, kind: .command,
                                       toolName: "shell", title: "명령 실행", detail: "swift build")
        let adapters = AdapterLog()
        coordinator.adapterFactory = { provider in
            let adapter = ScriptedAgentAdapter(provider: provider) { request in
                let established = ScriptedAgentAdapter.Step.emit(.sessionEstablished(sessionID: "s-" + request.prompt, model: "fake-model", cliVersion: nil))
                if request.prompt == "승인" {
                    return [established, .emit(.approvalRequested(approval)), .waitApproval(id: approval.id),
                            .finish(AgentTurnResult(state: .completed, terminalReason: "completed", sessionID: "s-승인"))]
                }
                return [established, .emit(.assistantDelta("일하는 중")), .waitInterrupt]
            }
            adapters.add(adapter)
            return adapter
        }
        func settle(_ condition: @MainActor () -> Bool) async {
            for _ in 0..<300 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        }

        let first = try await coordinator.send(prompt: "오래", thread: threads[0], project: project, provider: .claude)
        let second = try await coordinator.send(prompt: "승인", thread: threads[1], project: project, provider: .codex)
        await settle { coordinator.session(threadID: threads[1].id)?.pendingApprovals.isEmpty == false }
        await t.equal("다른 대화의 두 실행이 함께 돈다", coordinator.activeSessions.compactMap { $0.activeRun?.id }, [first.id, second.id])
        await t.check("대화별로 실행 중인지 안다", coordinator.isBusy(threadID: threads[0].id) && coordinator.isBusy(threadID: threads[1].id)
                        && !coordinator.isBusy(threadID: threads[2].id))
        await t.equal("실행별 상태", [coordinator.session(runID: first.id)?.state, coordinator.session(runID: second.id)?.state],
                      [.running, .awaitingApproval])
        await t.check("단수 속성은 가장 최근에 시작한 활성 실행", coordinator.activeThreadID == threads[1].id
                        && coordinator.state == .awaitingApproval && coordinator.pendingApprovals.count == 1)
        await t.check("승인 대기는 그 실행에만", coordinator.session(threadID: threads[0].id)?.pendingApprovals.isEmpty == true)
        do {
            try await coordinator.send(prompt: "끼어들기", thread: threads[0], project: project, provider: .claude)
            await t.check("같은 대화의 두 번째 실행은 거절", false)
        } catch RunCoordinator.StartError.busy { await t.check("같은 대화의 두 번째 실행은 거절", true) }
        await t.equal("거절한 턴은 기록을 남기지 않는다", try await store.runs(threadID: threads[0].id).count, 1)

        // 승인 응답은 실행 ID 로 그 세션을 찾아 간다.
        if let request = coordinator.session(threadID: threads[1].id)?.pendingApprovals.first {
            await coordinator.respond(approval: request, decision: .allow)
        }
        await settle { !coordinator.isBusy(threadID: threads[1].id) }
        await t.equal("승인받은 실행만 끝났다", try await store.run(id: second.id)?.state, .completed)
        await t.check("끝난 실행은 목록에서 빠진다", coordinator.session(threadID: threads[1].id) == nil
                        && coordinator.activeSessions.count == 1)
        await t.check("단수 속성은 남은 실행으로 돌아간다", coordinator.activeThreadID == threads[0].id && coordinator.state == .running)
        await t.equal("완료 통지는 끝난 실행의 것", probe.finished.map(\.0.id), [second.id])

        // 대화별 중단.
        let third = try await coordinator.send(prompt: "또 오래", thread: threads[2], project: project, provider: .claude)
        await coordinator.interrupt(threadID: threads[0].id)
        await settle { !coordinator.isBusy(threadID: threads[0].id) }
        await t.check("그 대화의 실행만 멈춘다", try await store.run(id: first.id)?.state == .cancelled
                        && coordinator.isBusy(threadID: threads[2].id))

        // 동시 실행 상한.
        coordinator.maxConcurrentRuns = 1
        do {
            try await coordinator.send(prompt: "상한", thread: threads[0], project: project, provider: .claude)
            await t.check("상한에 닿으면 다른 대화도 거절", false)
        } catch RunCoordinator.StartError.busy { await t.check("상한에 닿으면 다른 대화도 거절", true) }
        coordinator.maxConcurrentRuns = nil

        // 같은 대화로 거의 동시에 온 두 보내기: 시작 준비(CLI 확인 · 기록 저장)를 기다리는 사이에도 하나만 받는다.
        let raced = threads[1]
        @MainActor @Sendable func attempt(_ prompt: String) async -> Bool {
            do { try await coordinator.send(prompt: prompt, thread: raced, project: project, provider: .claude); return true }
            catch { return false }
        }
        async let a = attempt("경쟁 1")
        async let b = attempt("경쟁 2")
        let started = await [a, b].filter { $0 }
        await t.equal("같은 대화로 동시에 보내도 하나만 시작", started.count, 1)
        await t.equal("실행 기록도 하나만 늘었다", try await store.runs(threadID: threads[1].id).count, 2)

        // 앱 종료: 도는 실행을 모두 거둔다.
        await t.equal("종료 전 활성 실행 둘", coordinator.activeSessions.count, 2)
        let cleaned = await coordinator.shutdownForQuit()
        await t.check("앱 종료 때 모든 실행의 어댑터를 닫는다", cleaned && adapters.all.filter { $0.requests.first?.prompt != "승인" }.allSatisfy(\.wasShutDown))
        await t.equal("종료로 끊긴 실행은 취소로 기록", try await store.run(id: third.id)?.state, .cancelled)
    }
}
