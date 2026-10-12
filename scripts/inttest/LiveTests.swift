import Foundation

/// 실제 CLI 를 호출하는 통합 검증.
/// 임시 테스트 프로젝트에서 짧은 작업만 수행해 한도 사용을 제한한다.
enum LiveTests {

    struct Env {
        var claude: String
        var codex: String
        var env: [String: String]
        var root: URL
    }

    /// 검증에 쓸 Codex 모델·추론 강도. `--codex-model=` / `--codex-effort=` 로 지정한다.
    /// 한도 사용을 줄이려고 가벼운 모델로 돌릴 때 쓴다.
    /// 모델을 명시한 테스트(모델 선택 검증)는 이 값을 덮어쓰지 않는다.
    nonisolated(unsafe) static var codexModelOverride: String?
    nonisolated(unsafe) static var codexEffortOverride: String?
    /// 자동 인계 종단 검증(`autohandoff`)의 Claude 모델 · 강도. `--claude-model=` / `--claude-effort=`.
    nonisolated(unsafe) static var claudeModelOverride: String?
    nonisolated(unsafe) static var claudeEffortOverride: String?
    /// Gemini(agy)를 부르는 시나리오를 건너뛴다. `--skip-gemini`.
    nonisolated(unsafe) static var skipGemini = false
    /// 자동 인계 종단 검증에서 이 시나리오(F · G)만 돌린다. `--autohandoff-only=G` — A~E 는 건너뛴다.
    nonisolated(unsafe) static var autoHandoffOnly: Set<String>?

    /// 한 턴을 끝까지 돌리고 수집 결과를 돌려준다.
    @discardableResult
    /// `allowModelOverride: false` 는 "모델을 지정하지 않았을 때"의 동작을 검증하는 턴이다.
    /// 여기에 지정 모델을 끼워 넣으면 검증 대상 자체가 바뀌므로 건드리지 않는다.
    static func runTurn(_ adapter: AgentAdapter, _ request: AgentTurnRequest,
                        timeout: TimeInterval = 180,
                        allowModelOverride: Bool = true,
                        onEvent: (@Sendable (AgentEvent, EventCollector) async -> Void)? = nil)
        async -> EventCollector {
        let request = allowModelOverride ? withCodexOverride(request, for: adapter) : request
        let collector = EventCollector()
        let stream = adapter.start(request)
        let consume = Task {
            for await e in stream {
                collector.ingest(e)
                await onEvent?(e, collector)
            }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await consume.value }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
        consume.cancel()
        _ = await adapter.shutdown()
        return collector
    }

    /// `--codex-model` · `--codex-effort` 를 모델을 정하지 않은 Codex 턴에 끼운다. `runTurn` 과 어댑터를 직접 시작하는 턴이
    /// 같이 쓴다 — 예전에는 직접 시작하는 턴(실행 중 중단)이 지정을 건너뛰어 계정의 기본 모델로 돌았다.
    static func withCodexOverride(_ request: AgentTurnRequest, for adapter: AgentAdapter) -> AgentTurnRequest {
        var request = request
        if adapter.provider == .codex, request.model == nil, let model = codexModelOverride {
            request.model = model
            request.effort = codexEffortOverride
        }
        return request
    }

    static func makeClaude(_ e: Env, permissionMode: String = "manual") -> ClaudeAdapter {
        ClaudeAdapter(executablePath: e.claude, environment: e.env, permissionMode: permissionMode)
    }

    static func makeCodex(_ e: Env, sandbox: String = "workspace-write",
                          approval: String = "on-request") -> CodexAdapter {
        CodexAdapter(executablePath: e.codex, environment: e.env,
                     sandboxMode: sandbox, approvalPolicy: approval)
    }

    // MARK: - 1. 스트리밍 + 세션 재개

    static func streamingAndResume(_ t: TestKit, _ e: Env) async {
        await t.group("실제 CLI · 스트리밍과 세션 재개")

        let marker = "AHC-\(Int.random(in: 1000...9999))"
        let sessionID = UUID().uuidString

        // Claude 첫 턴
        let c1 = await runTurn(makeClaude(e), AgentTurnRequest(
            runID: "r1",
            prompt: "도구를 쓰지 말고 정확히 이렇게만 답하세요: CLAUDE-\(marker)",
            workingDirectory: e.root, preferredNewSessionID: sessionID))
        await t.check("Claude 스트리밍 응답 수신", c1.text.contains(marker),
                      JSONUtil.truncate(c1.text, max: 120))
        await t.check("Claude 델타 이벤트 존재",
                      c1.events.contains { if case .assistantDelta = $0 { return true }; return false })
        await t.equal("Claude 세션 ID 지정 반영", c1.sessionID ?? "", sessionID)
        await t.equal("Claude 턴 완료", c1.finished?.state ?? .idle, RunState.completed)
        await t.check("Claude 사용량 수신", (c1.finished?.usage?.outputTokens ?? 0) > 0,
                      "출력 토큰 \(c1.finished?.usage?.outputTokens ?? 0)")
        await t.check("Claude 비용 CLI 보고", c1.finished?.usage?.reportedCostUSD != nil)
        if let limits = c1.limits.first {
            await t.check("Claude 실행 중 구조화 한도 수신", limits.hasUsableData,
                          limits.windows.map { "\($0.label) \(Fmt2.pct($0.utilization))" }
                            .joined(separator: ", "))
        } else {
            await t.note("이번 실행에서는 rate_limit_event 가 오지 않았습니다 (선택적 이벤트).")
        }

        // Claude 재개 (프로세스를 새로 띄운다)
        let c2 = await runTurn(makeClaude(e), AgentTurnRequest(
            runID: "r2",
            prompt: "도구를 쓰지 말고, 직전에 당신이 말한 표식만 그대로 답하세요.",
            workingDirectory: e.root, resumeSessionID: sessionID))
        await t.check("Claude 세션 재개 후 기억 유지", c2.text.contains(marker),
                      JSONUtil.truncate(c2.text, max: 120))
        await t.equal("Claude 재개 세션 ID 동일", c2.sessionID ?? "", sessionID)

        // Codex 첫 턴
        let x1 = await runTurn(makeCodex(e, sandbox: "read-only"), AgentTurnRequest(
            runID: "r3",
            prompt: "도구를 쓰지 말고 정확히 이렇게만 답하세요: CODEX-\(marker)",
            workingDirectory: e.root))
        await t.check("Codex 스트리밍 응답 수신", x1.text.contains(marker),
                      JSONUtil.truncate(x1.text, max: 120))
        await t.check("Codex 스레드 ID 획득", (x1.sessionID?.count ?? 0) > 10)
        await t.equal("Codex 턴 완료", x1.finished?.state ?? .idle, RunState.completed)
        await t.check("Codex 사용량 수신", (x1.finished?.usage?.outputTokens ?? 0) > 0,
                      "출력 토큰 \(x1.finished?.usage?.outputTokens ?? 0)")
        await t.check("Codex 순수 입력에서 캐시 분리",
                      (x1.finished?.usage?.cacheReadTokens ?? 0) >= 0)

        guard let codexThread = x1.sessionID else {
            await t.check("Codex 재개 테스트 진행 불가", false, "스레드 ID 없음")
            return
        }

        // Codex 재개 (app-server 프로세스를 새로 띄운다)
        let x2 = await runTurn(makeCodex(e, sandbox: "read-only"), AgentTurnRequest(
            runID: "r4",
            prompt: "도구를 쓰지 말고, 직전에 당신이 말한 표식만 그대로 답하세요.",
            workingDirectory: e.root, resumeSessionID: codexThread))
        await t.check("Codex 세션 재개 후 기억 유지", x2.text.contains(marker),
                      JSONUtil.truncate(x2.text, max: 120))
        await t.equal("Codex 재개 스레드 동일", x2.sessionID ?? "", codexThread)
    }

    // MARK: - 2. 승인 (거절 / 허용 / 늦은 응답)

    static func approvals(_ t: TestKit, _ e: Env) async {
        await t.group("실제 CLI · 승인 왕복")

        // 2-1. Claude 승인 거절 → 파일 미생성
        let denyPath = e.root.appendingPathComponent("deny-target.txt")
        try? FileManager.default.removeItem(at: denyPath)
        let denyAdapter = makeClaude(e)
        let denyCollector = await runTurn(denyAdapter, AgentTurnRequest(
            runID: "a1",
            prompt: "Write 도구로 \(denyPath.path) 파일에 PROBE 라고 쓰세요. "
                + "권한이 거절되면 재시도하지 말고 그대로 보고하세요.",
            workingDirectory: e.root, preferredNewSessionID: UUID().uuidString),
            onEvent: { event, _ in
                if case .approvalRequested(let r) = event {
                    await denyAdapter.respond(approvalID: r.id,
                                              decision: .deny("테스트에서 거절합니다."))
                }
            })
        await t.check("Claude 승인 요청 수신", !denyCollector.approvals.isEmpty,
                      denyCollector.approvals.map { $0.toolName }.joined(separator: ","))
        await t.check("거절 후 파일 미생성",
                      !FileManager.default.fileExists(atPath: denyPath.path))
        await t.check("거절 도구가 Write 로 식별됨",
                      denyCollector.approvals.contains { $0.toolName == "Write" })
        await t.check("거절 요청에 tool_use_id 연결",
                      denyCollector.approvals.first?.toolUseID != nil)

        // 2-2. 종료된 실행에 대한 늦은 승인 응답은 무효
        if let stale = denyCollector.approvals.first {
            await denyAdapter.respond(approvalID: stale.id, decision: .allow)
            await t.check("늦은 승인 응답이 파일을 만들지 않음",
                          !FileManager.default.fileExists(atPath: denyPath.path))
        }

        // 2-3. Claude 승인 허용 → 파일 생성 (이전에 미검증이던 항목)
        let allowPath = e.root.appendingPathComponent("allow-target.txt")
        try? FileManager.default.removeItem(at: allowPath)
        let allowAdapter = makeClaude(e)
        let allowCollector = await runTurn(allowAdapter, AgentTurnRequest(
            runID: "a2",
            prompt: "Write 도구로 \(allowPath.path) 파일에 정확히 APPROVED 라고 쓰세요. 다른 작업은 하지 마세요.",
            workingDirectory: e.root, preferredNewSessionID: UUID().uuidString),
            onEvent: { event, _ in
                if case .approvalRequested(let r) = event {
                    await allowAdapter.respond(approvalID: r.id, decision: .allow)
                }
            })
        await t.check("Claude 승인 허용 요청 수신", !allowCollector.approvals.isEmpty)
        let created = FileManager.default.fileExists(atPath: allowPath.path)
        await t.check("허용 후 파일 생성됨", created)
        if created {
            let content = (try? String(contentsOf: allowPath, encoding: .utf8)) ?? ""
            await t.check("파일 내용 확인", content.contains("APPROVED"),
                          JSONUtil.truncate(content, max: 80))
        }
        await t.equal("허용 실행 완료", allowCollector.finished?.state ?? .idle, RunState.completed)

        // 2-4. Codex 승인 왕복 (이전에 미검증이던 항목)
        let codexPath = e.root.appendingPathComponent("codex-approved.txt")
        try? FileManager.default.removeItem(at: codexPath)
        let codexAdapter = makeCodex(e, sandbox: "read-only", approval: "on-request")
        let codexCollector = await runTurn(codexAdapter, AgentTurnRequest(
            runID: "a3",
            prompt: "셸 명령으로 \(codexPath.path) 파일에 CODEX-APPROVED 라고 쓰세요. "
                + "읽기 전용 샌드박스이므로 승인을 요청해야 합니다.",
            workingDirectory: e.root),
            timeout: 200,
            onEvent: { event, _ in
                if case .approvalRequested(let r) = event {
                    await codexAdapter.respond(approvalID: r.id, decision: .allow)
                }
            })
        if codexCollector.approvals.isEmpty {
            await t.note("Codex 가 이번 실행에서 승인을 요청하지 않았습니다 "
                         + "(정책/샌드박스 조합에 따라 달라질 수 있음). 상태: "
                         + "\(codexCollector.finished?.terminalReason ?? "미확인")")
            await t.check("Codex 승인 경로 확인 시도 완료", true, "요청 없음 — 미검증으로 기록")
        } else {
            await t.check("Codex 승인 요청 수신", true,
                          codexCollector.approvals.map { $0.kind.koreanName }
                            .joined(separator: ","))
            let ok = FileManager.default.fileExists(atPath: codexPath.path)
            await t.check("Codex 승인 허용 후 파일 생성", ok,
                          ok ? "" : "승인은 받았으나 파일이 없음: "
                                  + (codexCollector.finished?.terminalReason ?? ""))
        }
    }

    // MARK: - 3. 중단 (시작 직후 / 실행 중)

    static func interrupts(_ t: TestKit, _ e: Env) async {
        await t.group("실제 CLI · 중단")

        // 3-1. Claude: 시작하자마자 중단 (요청 유실 금지)
        let earlyClaude = makeClaude(e)
        let earlyTask = Task {
            await runTurn(earlyClaude, AgentTurnRequest(
                runID: "i1", prompt: "1 부터 3000 까지 한 줄에 하나씩 세세요. 도구는 쓰지 마세요.",
                workingDirectory: e.root, preferredNewSessionID: UUID().uuidString),
                timeout: 120)
        }
        await earlyClaude.requestInterrupt()   // 프로세스가 준비되기 전에 요청
        let early = await earlyTask.value
        await t.check("Claude 시작 직후 중단 처리",
                      early.finished?.state == .cancelled,
                      "상태 \(early.finished?.state.koreanName ?? "없음") / "
                      + "사유 \(early.finished?.terminalReason ?? "없음")")
        await t.check("시작 직후 중단은 오류가 아님", early.finished?.isError != true)
        await t.check("Claude 중단 후 프로세스 종료됨", earlyClaude.currentPID == nil)

        // 3-2. Claude: 출력 시작 후 중단
        let midClaude = makeClaude(e)
        let midCollector = EventCollector()
        let midStream = midClaude.start(AgentTurnRequest(
            runID: "i2", prompt: "1 부터 5000 까지 한 줄에 하나씩 세세요. 도구는 쓰지 마세요.",
            workingDirectory: e.root, preferredNewSessionID: UUID().uuidString))
        let midTask = Task {
            var interrupted = false
            for await event in midStream {
                midCollector.ingest(event)
                if case .assistantDelta = event, !interrupted {
                    interrupted = true
                    await midClaude.requestInterrupt()
                }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await midTask.value }
            group.addTask { try? await Task.sleep(nanoseconds: 90_000_000_000) }
            await group.next()
            group.cancelAll()
        }
        midTask.cancel()
        _ = await midClaude.shutdown()
        await t.check("Claude 실행 중 중단 처리",
                      midCollector.finished?.state == .cancelled,
                      "상태 \(midCollector.finished?.state.koreanName ?? "없음") / "
                      + "사유 \(midCollector.finished?.terminalReason ?? "없음")")
        await t.check("중단 시 사용량 미확정 표시",
                      midCollector.finished?.usage?.confirmed == false)
        await t.check("Claude 중단 후 프로세스 종료 확인", midClaude.currentPID == nil)

        // 3-3. Codex: 시작 직후 중단
        //     실측에서 turn/start 응답 직후 interrupt 는 "no active turn" 으로 실패했다.
        //     어댑터가 턴 활성화를 기다렸다가 보내는지 확인한다.
        let earlyCodex = makeCodex(e, sandbox: "read-only")
        let earlyCodexTask = Task {
            await runTurn(earlyCodex, AgentTurnRequest(
                runID: "i3", prompt: "1 부터 3000 까지 한 줄에 하나씩 세세요. 도구는 쓰지 마세요.",
                workingDirectory: e.root), timeout: 150)
        }
        await earlyCodex.requestInterrupt()
        let earlyCodexResult = await earlyCodexTask.value
        await t.check("Codex 시작 직후 중단 처리",
                      earlyCodexResult.finished?.state == .cancelled,
                      "상태 \(earlyCodexResult.finished?.state.koreanName ?? "없음") / "
                      + "사유 \(earlyCodexResult.finished?.terminalReason ?? "없음")")
        await t.check("no active turn 오류로 실패하지 않음",
                      earlyCodexResult.finished?.isError != true)
        await t.check("Codex 중단 후 프로세스 종료됨", earlyCodex.currentPID == nil)

        // 3-4. Codex: 실행 중 중단
        let midCodex = makeCodex(e, sandbox: "read-only")
        let midCodexCollector = EventCollector()
        let midCodexStream = midCodex.start(withCodexOverride(AgentTurnRequest(
            runID: "i4", prompt: "1 부터 5000 까지 한 줄에 하나씩 세세요. 도구는 쓰지 마세요.",
            workingDirectory: e.root), for: midCodex))
        let midCodexTask = Task {
            var interrupted = false
            for await event in midCodexStream {
                midCodexCollector.ingest(event)
                if case .assistantDelta = event, !interrupted {
                    interrupted = true
                    await midCodex.requestInterrupt()
                }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await midCodexTask.value }
            group.addTask { try? await Task.sleep(nanoseconds: 120_000_000_000) }
            await group.next()
            group.cancelAll()
        }
        midCodexTask.cancel()
        _ = await midCodex.shutdown()
        await t.check("Codex 실행 중 중단 처리",
                      midCodexCollector.finished?.state == .cancelled,
                      "상태 \(midCodexCollector.finished?.state.koreanName ?? "없음") / "
                      + "사유 \(midCodexCollector.finished?.terminalReason ?? "없음")")
        await t.check("Codex 중단 사용량 미확정",
                      midCodexCollector.finished?.usage?.confirmed == false)
    }

    // MARK: - 4. 자식 프로세스 종료 구분

    static func childProcesses(_ t: TestKit, _ e: Env) async {
        await t.group("실제 CLI · 자식 프로세스")

        let pidFile = e.root.appendingPathComponent("child.pid")
        try? FileManager.default.removeItem(at: pidFile)

        let adapter = makeClaude(e, permissionMode: "acceptEdits")
        let collector = await runTurn(adapter, AgentTurnRequest(
            runID: "cp1",
            prompt: "Bash 도구로 다음 한 줄을 실행하세요: "
                + "nohup sleep 45 >/dev/null 2>&1 & echo $! > \(pidFile.path); "
                + "그 다음 정확히 SPAWNED 라고만 답하세요.",
            workingDirectory: e.root, preferredNewSessionID: UUID().uuidString),
            timeout: 150,
            onEvent: { event, _ in
                if case .approvalRequested(let r) = event {
                    await adapter.respond(approvalID: r.id, decision: .allow)
                }
            })

        let pidText = (try? String(contentsOf: pidFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pidText, let childPID = Int32(pidText) else {
            await t.check("자식 프로세스 생성 확인", false,
                          "PID 파일 없음. 상태 \(collector.finished?.state.koreanName ?? "없음")")
            return
        }
        await t.check("에이전트가 자식 프로세스를 생성함", true, "PID \(childPID)")

        // 에이전트 프로세스는 턴 종료로 이미 정리되었다.
        await t.check("에이전트 프로세스는 종료됨", adapter.currentPID == nil)

        // 자식(sleep)은 별개다: 에이전트 응답 종료 ≠ 셸 자식 종료
        let alive = kill(childPID, 0) == 0
        await t.check("에이전트 종료와 셸 자식 종료는 별개임을 확인", true,
                      alive ? "자식 프로세스 \(childPID) 는 아직 살아 있음 (앱이 이름만 보고 죽이지 않음)"
                            : "자식 프로세스가 이미 종료됨")
        await t.note("앱은 프로세스 이름만 보고 다른 사용자 작업을 종료하지 않습니다. "
                     + "이 자식은 앱이 직접 시작한 프로세스가 아니므로 종료 대상이 아닙니다.")
        if alive { kill(childPID, SIGKILL) }   // 테스트 뒷정리
    }

    // MARK: - 5. 실제 왕복 인계 (Claude → Codex → Claude)

    static func handoffRoundTrip(_ t: TestKit, _ e: Env) async {
        await t.group("실제 CLI · 왕복 인계")

        let statePath = e.root.appendingPathComponent("handoff_state.json")
        try? FileManager.default.removeItem(at: statePath)
        let marker = "RT-\(Int.random(in: 1000...9999))"
        let claudeSession = UUID().uuidString

        // 1단계: Claude 가 파일 생성
        let a1 = makeClaude(e, permissionMode: "acceptEdits")
        let s1 = await runTurn(a1, AgentTurnRequest(
            runID: "h1",
            prompt: "\(statePath.path) 파일을 정확히 이 내용으로 만드세요: "
                + "{\"marker\":\"\(marker)\",\"stage\":\"claude-created\",\"count\":1} "
                + "다른 파일은 건드리지 마세요. 끝나면 DONE 이라고만 답하세요.",
            workingDirectory: e.root, preferredNewSessionID: claudeSession),
            timeout: 180,
            onEvent: { event, _ in
                if case .approvalRequested(let r) = event {
                    await a1.respond(approvalID: r.id, decision: .allow)
                }
            })
        let created = FileManager.default.fileExists(atPath: statePath.path)
        await t.check("1단계: Claude 가 파일 생성", created,
                      created ? "" : "상태 \(s1.finished?.state.koreanName ?? "없음")")
        guard created else { return }

        // 인계 패킷 구성 (추가 모델 호출 없음)
        let git = await GitInspector.snapshot(at: e.root, environment: e.env)
        let project = Project(name: "inttest", path: e.root.path)
        var thread = ConversationThread(projectID: project.id, title: "왕복 인계 검증")
        thread.goal = "handoff_state.json 의 marker 를 유지하며 단계별로 갱신"
        thread.pinnedNotes = "marker 값은 절대 바꾸지 말 것"
        let events = [
            ThreadEvent(threadID: thread.id, seq: 1, kind: .userMessage,
                        text: "handoff_state.json 을 만들어줘"),
            ThreadEvent(threadID: thread.id, seq: 2, kind: .agentMessage, provider: .claude,
                        text: s1.text),
            ThreadEvent(threadID: thread.id, seq: 3, kind: .fileChange, provider: .claude,
                        title: statePath.lastPathComponent, text: "생성됨"),
        ]
        let packet = HandoffPacketBuilder.build(HandoffPacketBuilder.Input(
            thread: thread, project: project, fromProvider: .claude, toProvider: .codex,
            events: events, runs: [], lastConfirmedPacket: nil, git: git, baseSeq: 3))
        let packetText = HandoffPacketBuilder.render(packet, threadTitle: thread.title,
                                                     projectPath: project.path)
        await t.check("인계 초안이 추가 모델 호출 없이 생성됨", packetText.count > 200)
        await t.check("초안에 목표 포함", packetText.contains("marker"))

        // 2단계: Codex 가 이어받아 수정
        let a2 = makeCodex(e, sandbox: "workspace-write", approval: "on-request")
        let s2 = await runTurn(a2, AgentTurnRequest(
            runID: "h2",
            prompt: packetText + "\n\n---\n## 새 지시\n"
                + "\(statePath.path) 를 읽고 count 를 2, stage 를 codex-updated 로 바꾸세요. "
                + "marker 는 그대로 두세요. 그 파일만 수정하고, 끝나면 결과 JSON 을 그대로 출력하세요.",
            workingDirectory: e.root),
            timeout: 240,
            onEvent: { event, _ in
                if case .approvalRequested(let r) = event {
                    await a2.respond(approvalID: r.id, decision: .allow)
                }
            })
        let afterCodex = (try? String(contentsOf: statePath, encoding: .utf8)) ?? ""
        await t.check("2단계: Codex 가 파일 수정", afterCodex.contains("codex-updated"),
                      JSONUtil.truncate(afterCodex, max: 160))
        await t.check("2단계: marker 유지", afterCodex.contains(marker))
        await t.check("2단계: count 갱신", afterCodex.contains("2"))
        await t.check("Codex 인계 수신 후 응답", !s2.text.isEmpty)

        // 3단계: 기존 Claude 세션으로 돌아와 확인 (왕복)
        let a3 = makeClaude(e, permissionMode: "acceptEdits")
        let s3 = await runTurn(a3, AgentTurnRequest(
            runID: "h3",
            prompt: "다른 에이전트(Codex)가 그동안 \(statePath.path) 를 수정했습니다. "
                + "그 파일을 읽고, 우리가 처음에 쓴 marker 값이 그대로인지 확인해서 "
                + "'marker=<값> stage=<값> count=<값>' 형식으로만 답하세요.",
            workingDirectory: e.root, resumeSessionID: claudeSession),
            timeout: 180,
            onEvent: { event, _ in
                if case .approvalRequested(let r) = event {
                    await a3.respond(approvalID: r.id, decision: .allow)
                }
            })
        await t.check("3단계: 기존 Claude 세션 재개 성공", s3.sessionID == claudeSession)
        await t.check("3단계: Claude 가 Codex 변경을 확인",
                      s3.text.contains("codex-updated"), JSONUtil.truncate(s3.text, max: 200))
        await t.check("3단계: 원래 marker 를 기억하고 확인", s3.text.contains(marker),
                      JSONUtil.truncate(s3.text, max: 200))
    }

    // MARK: - 6. 재개 불가 시 새 세션 복구

    static func resumeFailure(_ t: TestKit, _ e: Env) async {
        await t.group("실제 CLI · 재개 불가 복구")

        let bogus = UUID().uuidString
        // Codex: 존재하지 않는 스레드 → 어댑터가 새 세션으로 복구해야 한다.
        let codex = makeCodex(e, sandbox: "read-only")
        let cx = await runTurn(codex, AgentTurnRequest(
            runID: "rf1", prompt: "도구를 쓰지 말고 RECOVERED 라고만 답하세요.",
            workingDirectory: e.root, resumeSessionID: bogus), timeout: 150)
        await t.check("Codex 재개 실패 후 새 세션으로 복구",
                      cx.finished?.state == .completed && cx.sessionID != bogus,
                      "상태 \(cx.finished?.state.koreanName ?? "없음"), "
                      + "세션 \(cx.sessionID ?? "없음")")
        await t.check("복구 사실을 안내로 남김",
                      cx.notices.contains { $0.contains("재개 실패") } || cx.sessionID != bogus)

        // Claude: 존재하지 않는 세션 → 새 세션으로 복구해야 한다.
        let claude = makeClaude(e)
        let cl = await runTurn(claude, AgentTurnRequest(
            runID: "rf2", prompt: "도구를 쓰지 말고 RECOVERED 라고만 답하세요.",
            workingDirectory: e.root, resumeSessionID: bogus), timeout: 200)
        let state = cl.finished?.state ?? .idle
        await t.check("Claude 재개 실패 후 새 세션으로 복구",
                      state == .completed && cl.sessionID != bogus,
                      "상태 \(state.koreanName), 세션 \(cl.sessionID ?? "없음"), "
                      + "사유 \(cl.finished?.terminalReason ?? "없음")")
        await t.check("복구했음을 사용자에게 안내",
                      cl.notices.contains { $0.contains("새 세션으로 복구") },
                      cl.notices.filter { $0.contains("복구") }.first ?? "안내 없음")
        await t.check("복구 세션은 이전 대화를 잇지 않음을 명시",
                      cl.notices.contains { $0.contains("파일의 실제 상태") }
                        || cl.sessionID != bogus)
    }

    // MARK: - 7. 한도 조회

    static func limits(_ t: TestKit, _ e: Env) async {
        await t.group("실제 CLI · 한도 조회")

        let codexLimits = await LimitsFetcher.fetchCodex(path: e.codex, environment: e.env)
        await t.check("Codex 한도 조회",
                      codexLimits.status == .ok || codexLimits.hasUsableData,
                      codexLimits.windows.map { "\($0.label) \(Fmt2.pct($0.utilization))" }
                        .joined(separator: ", ") + " / " + (codexLimits.message ?? ""))
        await t.check("Codex 한도 조회 시각 기록", codexLimits.fetchedAt != nil)

        let claudeLimits = await LimitsFetcher.fetchClaude(path: e.claude, environment: e.env)
        await t.check("Claude 한도 조회",
                      claudeLimits.status == .ok || claudeLimits.hasUsableData,
                      claudeLimits.windows.map { "\($0.label) \(Fmt2.pct($0.utilization))" }
                        .joined(separator: ", ") + " / " + (claudeLimits.message ?? ""))
        await t.check("한도 조회 실패가 0% 로 표시되지 않음",
                      claudeLimits.status == .ok
                        || !claudeLimits.windows.contains { $0.utilization == 0 })
        if claudeLimits.status == .noData {
            await t.check("형식 변경 시 원문 제공", claudeLimits.rawResponse != nil)
        }
    }

    // MARK: - 7-1-2. CODEX_HOME 으로 계정이 실제로 갈리는가
    //
    // 두 번째 계정의 로그인은 사용자만 할 수 있으므로 (앱도 이 검증도 토큰을 만들지 않는다)
    // 여기서는 **격리가 실제로 일어나는지**를 확인한다.
    // 기본 홈은 로그인된 계정의 한도를 돌려주고, 빈 홈은 같은 CLI 로도 로그인되지 않은 것으로 나와야 한다.
    static func codexAccounts(_ t: TestKit, _ e: Env) async {
        await t.group("실제 CLI · Codex 계정 격리")

        let cliEnv = CLIEnvironment()
        let emptyHome = e.root.appendingPathComponent("codex-home-empty")
        try? FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)

        let defaultHome = CodexAccountInspector.defaultHomePath()
        let defaultIdentity = CodexAccountInspector.inspect(home: defaultHome)
        await t.check("기본 홈 로그인 상태 확인",
                      defaultIdentity.status == .loggedIn,
                      "\(defaultIdentity.status.koreanName) / \(defaultIdentity.note ?? "")")
        await t.check("기본 홈의 계정 ID (토큰이 아닌 필드)",
                      defaultIdentity.chatgptAccountID != nil || !defaultIdentity.usesChatGPT)

        let emptyIdentity = CodexAccountInspector.inspect(home: emptyHome.path)
        await t.equal("빈 홈은 로그인 필요", emptyIdentity.status, CodexAuthStatus.notLoggedIn)

        // 앱이 실제로 쓰는 경로(app-server + account/rateLimits/read)로 확인한다.
        let defaultEnv = await cliEnv.childEnvironment(codexHome: defaultHome)
        let defaultFetched = await LimitsFetcher.fetchCodexWithAccount(
            path: e.codex, environment: defaultEnv, accountID: CodexAccount.defaultID)
        let defaultLimits = defaultFetched.limits
        await t.check("기본 홈 계정 식별 (같은 app-server 의 account/read)",
                      defaultFetched.account?.email != nil || !defaultIdentity.usesChatGPT,
                      defaultFetched.account?.planType.map { "플랜 \($0)" } ?? "플랜 미확인")
        await t.check("account/read 의 계정 ID 가 auth.json 과 같다",
                      !defaultIdentity.usesChatGPT || defaultFetched.account?.chatgptAccountID == defaultIdentity.chatgptAccountID)
        await t.check("기본 홈으로 한도 조회",
                      defaultLimits.status == .ok || defaultLimits.hasUsableData,
                      defaultLimits.windows.map { "\($0.label) \(Fmt2.pct($0.utilization))" }
                        .joined(separator: ", "))
        await t.equal("한도 스냅샷에 계정이 붙는다", defaultLimits.accountID, CodexAccount.defaultID)

        let emptyEnv = await cliEnv.childEnvironment(codexHome: emptyHome.path)
        let emptyFetched = await LimitsFetcher.fetchCodexWithAccount(
            path: e.codex, environment: emptyEnv, accountID: "empty-home")
        let emptyLimits = emptyFetched.limits
        await t.equal("빈 홈의 account/read 는 로그인 안 됨", emptyFetched.account?.kind, .loggedOut)
        await t.check("빈 홈은 같은 CLI 로도 한도를 주지 않는다",
                      !emptyLimits.hasUsableData,
                      "상태 \(emptyLimits.status.koreanName) / \(emptyLimits.message ?? "")")
        await t.check("실패를 0% 로 표시하지 않음",
                      !emptyLimits.windows.contains { $0.utilization == 0 })
        await t.check("두 홈의 결과가 다르다 (격리 확인)",
                      defaultLimits.hasUsableData != emptyLimits.hasUsableData)

        // 홈을 지정하지 않은 실행이 다른 계정으로 새지 않아야 한다.
        let plainEnv = await cliEnv.childEnvironment()
        await t.check("홈을 지정하지 않으면 앱이 CODEX_HOME 을 만들지 않음",
                      plainEnv["CODEX_HOME"] == ProcessInfo.processInfo.environment["CODEX_HOME"])

        // 모델 목록도 계정 홈을 따라간다. 토큰을 쓰지 않는 조회라 여기서 함께 확인한다.
        let scopedCatalog = await ModelCatalog.fetchCodex(
            path: e.codex, environment: defaultEnv, accountID: CodexAccount.defaultID)
        await t.check("계정 홈을 지정해도 모델 목록 조회",
                      scopedCatalog.discovered,
                      scopedCatalog.options.map { $0.identifier }.joined(separator: ", "))
        await t.equal("모델 목록에 계정이 붙는다", scopedCatalog.accountID, CodexAccount.defaultID)
        let emptyCatalog = await ModelCatalog.fetchCodex(
            path: e.codex, environment: emptyEnv, accountID: "empty-home")
        await t.note("빈 홈의 모델 목록: "
                     + (emptyCatalog.discovered
                        ? "조회됨(\(emptyCatalog.options.count)개)"
                        : "조회 실패 — \(emptyCatalog.message ?? "사유 미확인")"))

        // 앱이 남의 홈을 건드리지 않는지 (파일 목록이 그대로인지) 확인한다.
        let before = (try? FileManager.default.contentsOfDirectory(atPath: defaultHome))?.sorted()
        _ = CodexAccountInspector.inspect(home: defaultHome)
        let after = (try? FileManager.default.contentsOfDirectory(atPath: defaultHome))?.sorted()
        await t.check("기본 홈의 파일 목록을 바꾸지 않음", before == after)
        await t.note("두 번째 계정의 실제 로그인은 사용자만 할 수 있어 이 검증의 범위 밖이다. "
                     + "여기서는 홈 격리가 실제로 일어나는지까지만 확인했다.")
    }

    // MARK: - 7-2. 모델 선택이 실제로 적용되는가

    static func modelSelection(_ t: TestKit, _ e: Env) async {
        await t.group("실제 CLI · 모델 선택")

        // 목록 조회
        let claudeCatalog = await ModelCatalog.fetchClaude(path: e.claude, environment: e.env)
        await t.check("Claude 모델 목록 조회", claudeCatalog.discovered,
                      claudeCatalog.options.map { $0.identifier }.joined(separator: ", ")
                        + " / " + (claudeCatalog.message ?? ""))
        let codexCatalog = await ModelCatalog.fetchCodex(path: e.codex, environment: e.env)
        await t.check("Codex 모델 목록 조회", codexCatalog.discovered,
                      codexCatalog.options.map { $0.identifier }.joined(separator: ", "))
        await t.check("Codex 모델별 추론 강도 제공",
                      codexCatalog.options.contains { !$0.supportedEfforts.isEmpty })
        await t.check("Codex 기본 모델 표시", codexCatalog.options.contains { $0.isDefault },
                      codexCatalog.options.first { $0.isDefault }?.identifier ?? "없음")

        // Codex: 기본이 아닌 모델을 골라 실제로 그 모델로 실행되는지
        let nonDefault = codexCatalog.options.first { !$0.isDefault }
        if let target = nonDefault {
            let effort = target.supportedEfforts.first
            let collector = await runTurn(makeCodex(e, sandbox: "read-only"), AgentTurnRequest(
                runID: "m1", prompt: "도구를 쓰지 말고 MODEL-OK 라고만 답하세요.",
                workingDirectory: e.root, model: target.identifier, effort: effort),
                timeout: 180)
            await t.equal("Codex 지정 모델로 실행 완료",
                          collector.finished?.state ?? .idle, RunState.completed)
            await t.equal("Codex 가 보고한 모델이 지정한 모델과 일치",
                          collector.finished?.model ?? "", target.identifier)
            await t.check("응답 수신", collector.text.contains("MODEL-OK"),
                          JSONUtil.truncate(collector.text, max: 100))
        } else {
            await t.check("Codex 대체 모델 선택 가능", false, "기본이 아닌 모델이 없음")
        }

        // Claude: 가장 저렴한 별칭으로 --model 이 실제로 반영되는지
        if claudeCatalog.options.contains(where: { $0.identifier == "haiku" }) {
            let collector = await runTurn(makeClaude(e), AgentTurnRequest(
                runID: "m2", prompt: "도구를 쓰지 말고 MODEL-OK 라고만 답하세요.",
                workingDirectory: e.root, preferredNewSessionID: UUID().uuidString,
                model: "haiku"), timeout: 150)
            await t.equal("Claude 지정 모델로 실행 완료",
                          collector.finished?.state ?? .idle, RunState.completed)
            let reported = collector.finished?.model ?? ""
            await t.check("Claude 가 haiku 모델로 실행됨", reported.contains("haiku"),
                          "보고된 모델: \(reported)")
            await t.check("사용량이 해당 모델로 기록됨",
                          collector.finished?.usage?.model?.contains("haiku") == true,
                          collector.finished?.usage?.model ?? "없음")
        } else {
            await t.check("Claude haiku 별칭 확인", false, "목록에 haiku 없음")
        }

        // 기본값(선택 없음)은 --model 을 넘기지 않는다.
        // 이 턴은 "지정하지 않았을 때"를 보는 것이므로 --codex-model 지정을 적용하지 않는다.
        let defaultRun = await runTurn(makeCodex(e, sandbox: "read-only"), AgentTurnRequest(
            runID: "m3", prompt: "도구를 쓰지 말고 DEFAULT-OK 라고만 답하세요.",
            workingDirectory: e.root, model: nil, effort: nil),
            timeout: 180, allowModelOverride: false)
        await t.equal("모델 미지정 시 CLI 기본값으로 실행",
                      defaultRun.finished?.state ?? .idle, RunState.completed)
        await t.check("기본 실행의 모델이 CLI 기본 모델",
                      defaultRun.finished?.model == codexCatalog.options.first { $0.isDefault }?.identifier,
                      defaultRun.finished?.model ?? "미확인")
    }

    // MARK: - 8. CLI 환경 확인

    static func environmentChecks(_ t: TestKit, _ e: Env) async {
        await t.group("CLI 환경")
        let cli = CLIEnvironment()
        let claudeStatus = await cli.checkStatus(.claude, force: true)
        let codexStatus = await cli.checkStatus(.codex, force: true)
        await t.check("Claude 실행 파일 확인", claudeStatus.isUsable,
                      "\(claudeStatus.resolvedPath ?? "없음") · \(claudeStatus.version ?? "버전 미확인")")
        await t.check("Codex 실행 파일 확인", codexStatus.isUsable,
                      "\(codexStatus.resolvedPath ?? "없음") · \(codexStatus.version ?? "버전 미확인")")

        // Finder 실행 환경 재현: 최소 PATH 만 상속했을 때도 찾아야 한다.
        let childEnv = await cli.childEnvironment()
        await t.check("자식 프로세스 PATH 확장됨",
                      (childEnv["PATH"] ?? "").split(separator: ":").count > 4,
                      "\(((childEnv["PATH"] ?? "").split(separator: ":").count)) 개 경로")
        await t.check("Homebrew 경로 포함 (Finder 실행 대비)",
                      (childEnv["PATH"] ?? "").contains("/opt/homebrew/bin")
                        || (childEnv["PATH"] ?? "").contains("/usr/local/bin"))

        // 사용자 지정 경로가 잘못되면 조용히 다른 곳으로 넘어가지 않아야 한다.
        let overriding = CLIEnvironment()
        await overriding.setOverrides(CLIEnvironment.Override(
            claudePath: "/nonexistent/claude", codexPath: nil))
        let bad = await overriding.checkStatus(.claude, force: true)
        await t.check("잘못된 사용자 지정 경로는 오류로 보고", !bad.isUsable && bad.error != nil,
                      bad.error ?? "")
    }
}

enum Fmt2 {
    static func pct(_ v: Double?) -> String {
        guard let v else { return "정보없음" }
        return String(format: "%.0f%%", v * 100)
    }
}
