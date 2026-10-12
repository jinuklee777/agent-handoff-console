import Foundation

/// Claude 를 API 키로 실행하기 (Max · Team 플랜의 월 API 크레딧 — `ClaudeAPIKey` · `AppModel+ClaudeAPI`).
/// 사용자의 키체인은 건드리지 않는다 — 처음에 키 저장소를 메모리로 바꾼다.
enum ClaudeAPITests {

    static func run(_ t: TestKit) async {
        ClaudeAPIKey.storage = ClaudeAPIKeyMemoryStorage()
        await pure(t)
        await storage(t)
        await appModel(t)
        await runEnvironment(t)
        await continuePure(t)
        await continueApp(t)
        await apiReceivers(t)
        ClaudeAPIKey.storage = ClaudeAPIKeyMemoryStorage()
    }

    // MARK: 순수 판정

    private static func pure(_ t: TestKit) async {
        await t.group("Claude API 키: 판정 · 환경 · 오류 글")
        let key = "sk-ant-api03-abcdEFGH1234"
        await t.equal("붙여 넣은 줄바꿈 · 빈칸을 뗀다", ClaudeAPIKey.normalized("  \(key)\n"), key)
        await t.check("Console 키는 받는다", ClaudeAPIKey.problem(in: key) == nil)
        await t.check("빈 키", ClaudeAPIKey.problem(in: "  ") != nil)
        await t.check("가운데 빈칸", ClaudeAPIKey.problem(in: "sk-ant-api03 abcd")?.contains("빈칸") == true)
        await t.check("구독 토큰(setup-token)은 따로 말한다", ClaudeAPIKey.problem(in: "sk-ant-oat01-xyz")?.contains("setup-token") == true)
        await t.check("관리자 키는 받지 않는다", ClaudeAPIKey.problem(in: "sk-ant-admin01-xyz")?.contains("관리자") == true)
        await t.check("다른 회사의 키는 받지 않는다", ClaudeAPIKey.problem(in: "sk-proj-abcd")?.contains("sk-ant-") == true)
        await t.equal("화면에는 끝 네 글자만", ClaudeAPIKey.masked(key), "sk-ant-…1234")

        let base = ["PATH": "/usr/bin", "ANTHROPIC_AUTH_TOKEN": "gateway", "CLAUDE_CODE_USE_BEDROCK": "1",
                    "ANTHROPIC_BASE_URL": "https://proxy.example"]
        let env = ClaudeAPIKey.environment(base, apiKey: key)
        await t.equal("키를 ANTHROPIC_API_KEY 로 넣는다", env["ANTHROPIC_API_KEY"], key)
        await t.check("키보다 먼저 쓰이는 자격(토큰 · 클라우드 제공자)은 뺀다",
                      env["ANTHROPIC_AUTH_TOKEN"] == nil && env["CLAUDE_CODE_USE_BEDROCK"] == nil)
        await t.check("나머지(PATH · 프록시 주소)는 그대로", env["PATH"] == "/usr/bin" && env["ANTHROPIC_BASE_URL"] == "https://proxy.example")
        await t.equal("키가 없으면 환경을 바꾸지 않는다 (구독 로그인)", ClaudeAPIKey.environment(base, apiKey: nil), base)

        let apiText = "Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."
        let cliText = "Credit balance too low · Add funds: https://platform.claude.com/settings/billing"
        await t.check("크레딧 소진 글 (API · Claude Code 둘 다)", ClaudeAPIKey.isCreditExhausted(apiText) && ClaudeAPIKey.isCreditExhausted(cliText))
        await t.check("맞지 않는 키 글", ClaudeAPIKey.isInvalidKey("authentication_error: invalid x-api-key")
                        && ClaudeAPIKey.isInvalidKey("Invalid API key · Fix external API key"))
        await t.check("상관없는 글에는 할 일이 없다", ClaudeAPIKey.errorNote(for: "Error: Not logged in") == nil)
        await t.check("소진이면 구독으로 넘어가지 않는다는 것과 토글 끄기", ClaudeAPIKey.errorNote(for: cliText)?.contains("구독으로 넘어가지 않") == true
                        && ClaudeAPIKey.errorNote(for: cliText)?.contains(ClaudeAPIKey.toggleTitle) == true)
        // CLI 가 모델 없이 낸 짧은 글은 성공 형식이어도 실패다 — 성공으로 보면 대기열이 이어서 보낸다.
        await t.equal("성공 형식의 크레딧 소진 글 → 실패", ClaudeAdapter.cliFailureInSuccess(cliText, outputTokens: 0), .unknownCause)
        await t.equal("성공 형식의 맞지 않는 키 글 → 인증 문제", ClaudeAdapter.cliFailureInSuccess("Invalid API key · Fix external API key", outputTokens: 0),
                      .authProblem)
        await t.check("모델이 크레딧을 이야기한 답(출력 토큰 있음)은 실패가 아니다", ClaudeAdapter.cliFailureInSuccess(cliText, outputTokens: 12) == nil)
        await t.equal("API 키로 보내면 로그인을 보지 않는다", [AgentReadiness.notLoggedIn, .loginUnknown, .ready].map(AppModel.readinessWithAPIKey),
                      [.ready, .ready, .ready])
        await t.equal("설치 · 실행 파일 · 확인 중은 그대로", [AgentReadiness.notInstalled, .pathInvalid, .checking].map(AppModel.readinessWithAPIKey),
                      [.notInstalled, .pathInvalid, .checking])
    }

    // MARK: 저장소

    private static func storage(_ t: TestKit) async {
        await t.group("Claude API 키: 저장 · 읽기 · 지우기 (메모리 저장소)")
        let memory = ClaudeAPIKeyMemoryStorage()
        ClaudeAPIKey.storage = memory
        await t.check("처음엔 없다", ClaudeAPIKey.load() == nil)
        await t.check("모양이 틀린 키는 저장하지 않는다", !ClaudeAPIKey.save("sk-proj-1") && memory.value == nil)
        await t.check("저장 (다듬어서)", ClaudeAPIKey.save(" sk-ant-api03-zzzz9999 \n") && memory.value == "sk-ant-api03-zzzz9999")
        let before = memory.loads
        _ = ClaudeAPIKey.load(); _ = ClaudeAPIKey.load()
        await t.equal("한 번 읽은 키는 다시 읽지 않는다 (키체인 허락을 거듭 묻지 않게)", memory.loads, before)
        await t.equal("읽기", ClaudeAPIKey.load(), "sk-ant-api03-zzzz9999")
        ClaudeAPIKey.delete()
        await t.check("지우면 없다", ClaudeAPIKey.load() == nil && memory.value == nil)
        memory.failsToSave = true
        await t.check("저장소가 거절하면 false", !ClaudeAPIKey.save("sk-ant-api03-yyyy"))
        ClaudeAPIKey.storage = ClaudeAPIKeyMemoryStorage()
    }

    // MARK: 앱 모델

    @MainActor
    private static func appModel(_ t: TestKit) async {
        await t.group("Claude API 키: 앱 모델 (대화별 토글 · 키 · 보내기 전 판정)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ahc-claudeapi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
        do {
            try await store.bootstrap()
            let project = Project(name: "p", path: root.path)
            try await store.upsertProject(project)
            let thread = ConversationThread(projectID: project.id, title: "API 대화")
            let other = ConversationThread(projectID: project.id, title: "구독 대화")
            try await store.upsertThread(thread)
            try await store.upsertThread(other)
            ClaudeAPIKey.storage = ClaudeAPIKeyMemoryStorage()
            let model = AppModel(store: store)

            model.setClaudeAPI(true, threadID: thread.id)
            await t.check("키가 없으면 켜 둬도 API 로 보내지 않는다", !model.usesClaudeAPI(threadID: thread.id) && model.runner.claudeAPIThreadIDs.isEmpty)
            await t.check("모양이 틀린 키는 까닭을 돌려준다", model.saveClaudeAPIKey("sk-proj-1") != nil && model.claudeAPIKeyHint == nil)
            await t.check("키를 넣으면 끝 네 글자만 남긴다", model.saveClaudeAPIKey("sk-ant-api03-key0000ABCD") == nil
                            && model.claudeAPIKeyHint == "sk-ant-…ABCD")
            await t.equal("켠 대화만 실행기에 넘긴다", model.runner.claudeAPIThreadIDs, [thread.id])
            await t.check("켠 대화만 API", model.usesClaudeAPI(threadID: thread.id) && !model.usesClaudeAPI(threadID: other.id))
            let saved = (try? await store.setting("claude_api_threads")) ?? ""
            await t.check("켠 대화는 설정에 남는다 (다시 켜도)", saved.contains(thread.id), saved)
            let hint = (try? await store.setting("claude_api_key_hint")) ?? ""
            await t.equal("설정에는 키가 아니라 모양만", hint, "sk-ant-…ABCD")
            // 구독 로그인이 안 됐다고 확인된 상태 — 구독 대화는 막히고 API 대화는 막히지 않아야 한다.
            model.cliStatus[.claude] = CLIStatus(provider: .claude, resolvedPath: "/fake/claude", executable: true)
            model.claudeLogin = LoginCheck(loggedIn: false, checkedAt: Date())
            await t.equal("보내기 전 판정: 구독 대화는 로그인 안 됨", model.sendReadiness(provider: .claude, thread: other), .notLoggedIn)
            await t.equal("보내기 전 판정: API 대화는 로그인 없이 보낸다", model.sendReadiness(provider: .claude, thread: thread), .ready)
            await t.check("API 대화는 보내기를 막지 않는다 (막히는 상태는 구독 대화뿐)",
                          !SendReadiness.blocks(model.sendReadiness(provider: .claude, thread: thread))
                            && SendReadiness.blocks(model.sendReadiness(provider: .claude, thread: other)))

            model.deleteClaudeAPIKey()
            await t.check("키를 지우면 실행기에는 넘기지 않고 켠 표시는 남는다",
                          model.runner.claudeAPIThreadIDs.isEmpty && model.claudeAPIThreadIDs.contains(thread.id)
                            && model.claudeAPIKeyHint == nil && ClaudeAPIKey.load() == nil)
            model.setClaudeAPI(false, threadID: thread.id)
            await t.check("끄면 빠진다", !model.claudeAPIThreadIDs.contains(thread.id))
            await store.db.close()
        } catch {
            await t.check("임시 DB 준비", false, "\(error)")
        }
    }

    // MARK: 실행 환경 (가짜 claude)

    /// 실제 실행기 · 실제 Claude 어댑터 · 가짜 `claude` — 켠 대화의 실행에만 키가 환경으로 들어가는가.
    @MainActor
    private static func runEnvironment(_ t: TestKit) async {
        await t.group("Claude API 키: 켠 대화의 실행에만 키를 넣는다 (가짜 claude)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ahc-claudeapi-run-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fake = root.appendingPathComponent("claude")
        let log = root.appendingPathComponent("env.log")
        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"s-1","duration_ms":10,"usage":{"input_tokens":1,"output_tokens":1}}"#
        let script = """
        #!/bin/bash
        if [ "$1" = "--version" ]; then echo "2.1.999 (Claude Code)"; exit 0; fi
        printf '%s|%s\\n' "${ANTHROPIC_API_KEY:-none}" "${ANTHROPIC_AUTH_TOKEN:-none}" >> "\(log.path)"
        printf '%s\\n' '\(result)'
        """
        do {
            try script.write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
            let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
            try await store.bootstrap()
            let project = Project(name: "p", path: root.path)
            try await store.upsertProject(project)
            let apiThread = ConversationThread(projectID: project.id, title: "API")
            let plainThread = ConversationThread(projectID: project.id, title: "구독")
            try await store.upsertThread(apiThread)
            try await store.upsertThread(plainThread)

            let environment = CLIEnvironment()
            await environment.setOverrides(.init(claudePath: fake.path))
            let runner = RunCoordinator(store: store, environment: environment)
            runner.claudeAPIThreadIDs = [apiThread.id]
            ClaudeAPIKey.storage = ClaudeAPIKeyMemoryStorage("sk-ant-api03-test0001")
            func settle(_ id: String) async {
                for _ in 0..<500 where runner.session(threadID: id) != nil { try? await Task.sleep(nanoseconds: 20_000_000) }
            }

            _ = try await runner.send(prompt: "a", thread: apiThread, project: project, provider: .claude)
            await settle(apiThread.id)
            _ = try await runner.send(prompt: "b", thread: plainThread, project: project, provider: .claude)
            await settle(plainThread.id)
            let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            await t.equal("켠 대화의 실행: 키가 들어간다 · 구독 대화의 실행: 키가 없다", lines,
                          ["sk-ant-api03-test0001|none", "none|none"])

            ClaudeAPIKey.storage = ClaudeAPIKeyMemoryStorage(nil)
            var refused = false
            do {
                _ = try await runner.send(prompt: "c", thread: apiThread, project: project, provider: .claude)
            } catch RunCoordinator.StartError.claudeAPIKeyMissing {
                refused = true
            }
            await settle(apiThread.id)
            let after = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count
            await t.check("키를 읽지 못하면 구독으로 몰래 보내지 않고 시작하지 않는다", refused && after == 2, "거절 \(refused) · 실행 \(after)")
            let runs = (try? await store.runs(threadID: apiThread.id)) ?? []
            await t.equal("시작하지 않은 실행은 기록하지 않는다", runs.count, 1)
            await store.db.close()
        } catch {
            await t.check("가짜 claude 실행", false, "\(error)")
        }
    }

    // MARK: API 크레딧으로 계속 — 순수 판정

    private static func continuePure(_ t: TestKit) async {
        await t.group("API 크레딧으로 계속: 판정 · 글 (순수)")
        typealias C = ClaudeAPIContinue
        await t.equal("Claude · 구독 · 키 있음 → 단추", C.offer(provider: .claude, threadUsesAPI: false, hasKey: true, allowed: true), .available)
        await t.equal("키 없음 → 설정으로 가는 안내", C.offer(provider: .claude, threadUsesAPI: false, hasKey: false, allowed: true), .needsKey)
        await t.equal("이미 API 로 실행하는 대화 → 없음 (API 쪽 한도에서 같은 단추를 되풀이하지 않게)",
                      C.offer(provider: .claude, threadUsesAPI: true, hasKey: true, allowed: true), .none)
        await t.equal("Codex · Antigravity 의 한도 → 없음", [C.offer(provider: .codex, threadUsesAPI: false, hasKey: true, allowed: true),
                                                         C.offer(provider: .gemini, threadUsesAPI: false, hasKey: true, allowed: true)],
                      [.none, .none])
        await t.equal("자동 작업이 가진 대화 → 없음", C.offer(provider: .claude, threadUsesAPI: false, hasKey: true, allowed: false), .none)
        await t.check("대기열: 이유가 없었거나(카드가 보류) 한도로 멈춘 것만 풀고 이어 간다",
                      C.clearsQueuePause(before: nil) && C.clearsQueuePause(before: QueueRules.pauseReason(after: .rateLimited))
                        && !C.clearsQueuePause(before: "앱을 다시 켜서 멈췄습니다")
                        && !C.clearsQueuePause(before: QueueRules.previousSendFailed))
        let handoff = "Codex 에게 정리한 인계 문서로 이어 맡길 수 있습니다."
        await t.equal("한도 줄 문장: 인계 대상이 있으면 둘 다 한 문장으로",
                      C.limitAdvice(handoff: handoff, handoffTargeted: true, offer: .available),
                      "같은 Claude 세션을 API 크레딧으로 이어 가거나, Codex 에게 정리한 인계 문서로 이어 맡길 수 있습니다.")
        await t.equal("한도 줄 문장: 인계 대상이 없으면 API 만 (이어 받을 에이전트가 없다는 까닭은 접는다)",
                      C.limitAdvice(handoff: "이어 받을 에이전트가 없습니다 — …", handoffTargeted: false, offer: .available),
                      "같은 Claude 세션을 API 크레딧으로 이어 갈 수 있습니다 (이 대화만).")
        await t.equal("한도 줄 문장: 단추가 없으면 그대로", C.limitAdvice(handoff: handoff, handoffTargeted: true, offer: .needsKey), handoff)
        await t.check("단추 도움말은 인계가 아니라고 말한다", C.limitHelp.contains("인계하지 않습니다") && C.limitHelp.contains("같은 Claude 세션"))

        await t.group("API 크레딧으로 받는 Claude: 게이트 · 자동 인계 대상 (순수)")
        var capped = LimitSnapshot(provider: .claude, accountID: "")
        capped.status = .subscriptionCap
        capped.fetchedAt = Date()
        await t.equal("구독 한도 · 로그인 안 됨이어도 API 크레딧이면 CLI 만 본다",
                      AutomaticHandoffGate.targetProblems(cliUsable: true, authenticated: false, limit: capped, usesAPICredit: true), [])
        await t.equal("CLI 가 없으면 API 크레딧이어도 막는다",
                      AutomaticHandoffGate.targetProblems(cliUsable: false, authenticated: false, limit: capped, usesAPICredit: true),
                      [AutomaticHandoffGate.reasonCLI])
        await t.equal("구독이면 그대로 막는다",
                      AutomaticHandoffGate.targetProblems(cliUsable: true, authenticated: false, limit: capped),
                      [AutomaticHandoffGate.reasonLogin, AutomaticHandoffGate.reasonCapped])
        let viaAPI = AutomaticHandoffCandidate(provider: .claude, accountID: "", title: "Claude", cliUsable: true, authenticated: true,
                                               limit: capped, usesAPICredit: true)
        let viaSub = AutomaticHandoffCandidate(provider: .claude, accountID: "", title: "Claude", cliUsable: true, authenticated: true,
                                               limit: capped)
        await t.check("자동 인계: API 크레딧으로 받는 Claude 는 구독 한도여도 고른다 · 구독이면 건너뛴다",
                      AutomaticHandoffTargets.select([viaAPI], fromKey: "codex:a").chosen?.key == "claude"
                        && AutomaticHandoffTargets.select([viaSub], fromKey: "codex:a").chosen == nil)
        var gate = AutomaticHandoffGateInput(hasUnterminatedProcess: false, hasPendingDecision: false, hasUnknownPreviousDelivery: false,
                                             targetCLIUsable: true, targetAuthenticated: true, targetLimit: capped,
                                             nextActions: ["테스트 붙이기"], geminiWasRequested: false, geminiSucceededWithoutWarnings: true)
        await t.equal("게이트: 구독 한도인 Claude 는 막는다", AutomaticHandoffGate.blockingReasons(gate), [AutomaticHandoffGate.reasonCapped])
        gate.targetUsesAPICredit = true
        await t.equal("게이트: 이 대화가 API 크레딧이면 통과", AutomaticHandoffGate.blockingReasons(gate), [])
    }

    // MARK: API 크레딧으로 계속 — 앱 모델 (가짜 어댑터)

    /// 한도 줄 · 인계 카드 · 제안 줄의 단추가 실제 `AppModel` · `RunCoordinator` · SQLite 를 거쳐 하는 일 (CLI 만 가짜).
    @MainActor
    private static func continueApp(_ t: TestKit) async {
        await t.group("API 크레딧으로 계속: 한도 줄 · 카드 · 제안 줄 (앱 모델 · 가짜 어댑터)")
        ClaudeAPIKey.storage = ClaudeAPIKeyMemoryStorage()
        do {
            let env = try await HandoffCardTests.makeEnv("apicontinue", threads: ["한도", "카드", "제안"])
            defer { env.cleanup() }
            let model = env.model
            let limitID = env.threads[0].id, cardID = env.threads[1].id, suggestID = env.threads[2].id

            // 한도에 닿은 Claude 실행 — 그 세션은 재개할 수 있다 (한도로 끝난 실행도 세션 ID 를 남긴다).
            var session = try await env.store.ensureSession(threadID: limitID, provider: .claude, accountID: "")
            session.cliSessionID = "cli-limit-1"
            session.resumable = true
            try await env.store.upsertSession(session)
            let limited = Run(threadID: limitID, sessionID: session.id, provider: .claude, requestText: "워커 테스트도 붙여 줘.",
                              state: .rateLimited, startedAt: Date().addingTimeInterval(-20), endedAt: Date().addingTimeInterval(-10),
                              terminalReason: "rate_limited")
            try await env.store.insertRun(limited)
            _ = try await env.store.appendEvent(ThreadEvent(threadID: limitID, runID: limited.id, kind: .error, provider: .claude,
                                                            title: LimitStatus.subscriptionCap.koreanName, text: "Claude usage limit reached."))
            await model.reloadThreadData(threadID: limitID)
            await t.check("한도 줄이 단추를 다는 줄이 있다", model.activeLimitNoticeID(threadID: limitID) != nil)

            await t.equal("키가 없으면 설정으로 가는 안내", model.claudeAPIContinueOffer(threadID: limitID, provider: .claude), .needsKey)
            let refused = await model.continueWithClaudeAPI(threadID: limitID)
            await t.check("키가 없으면 이어 가지 않는다 (켜지도 보내지도 않는다)",
                          !refused && !model.claudeAPIThreadIDs.contains(limitID) && env.behavior.requests.isEmpty)
            _ = model.saveClaudeAPIKey("sk-ant-api03-cont0000WXYZ")
            await t.equal("키를 넣으면 단추", model.claudeAPIContinueOffer(threadID: limitID, provider: .claude), .available)
            await t.equal("Codex 의 한도에는 없다", model.claudeAPIContinueOffer(threadID: limitID, provider: .codex), .none)

            // 1) 제안 줄 (75% — 대화는 멈추지 않았다): 이어 맡길 에이전트가 없어도 API 크레딧만 권하고, 누르면 켜기만 한다.
            var hot = LimitSnapshot(provider: .claude, accountID: "")
            hot.status = .ok
            hot.fetchedAt = Date()
            hot.windows = [LimitWindow(label: "5시간", utilization: 0.81, resetsAt: Date().addingTimeInterval(3600), spanMinutes: 300)]
            model.limits.apply(hot)
            await model.selectThread(suggestID)
            guard let suggestThread = env.current(suggestID) else { throw CocoaError(.fileNoSuchFile) }
            let shown = model.continueSuggestion(for: suggestThread).suggestion
            await t.check("제안: 받을 다른 에이전트가 없어도 API 크레딧을 권한다 (Claude 만 쓰는 사람)",
                          shown != nil && shown?.target == nil && shown?.offersAPICredit == true && shown?.actionTitle == nil, "\(String(describing: shown))")
            model.switchToClaudeAPI(threadID: suggestID)
            await t.check("제안 줄의 단추: 켜기만 하고 보내지 않는다 · 입력창 위에 알린다",
                          model.usesClaudeAPI(threadID: suggestID) && env.behavior.requests.isEmpty
                            && model.banner?.threadID == suggestID && model.banner?.text == ClaudeAPIContinue.switchedNote)
            await t.check("API 로 실행하는 대화에는 구독 사용률 제안이 없다",
                          model.continueSuggestion(for: env.current(suggestID)!).suggestion == nil)
            await t.equal("이미 API 인 대화의 단추는 없다", model.claudeAPIContinueOffer(threadID: suggestID, provider: .claude), .none)

            // 2) 한도 줄: 켜고 → 같은 세션에 이어 가기 → 한도로 멈춘 대기열이 이어서 간다.
            model.messageQueues[limitID] = [QueuedMessage(text: "그다음 일")]
            model.queuePauseReasons[limitID] = QueueRules.pauseReason(after: .rateLimited)
            let started = await model.continueWithClaudeAPI(threadID: limitID)
            await env.settle { env.behavior.requests.count >= 2 && model.runner.session(threadID: limitID) == nil }
            let requests = env.behavior.requests
            await t.check("한도 줄의 단추: 이 대화의 API 크레딧을 켜고 실행기에 넘긴다",
                          started && model.usesClaudeAPI(threadID: limitID) && model.runner.claudeAPIThreadIDs.contains(limitID))
            await t.equal("같은 Claude 세션을 재개해 이어 가기 메시지를 보낸다 (인계 문서 없음)",
                          requests.first.map { [$0.prompt, $0.resumeSessionID ?? "새 세션"] }, [ClaudeAPIContinue.prompt, "cli-limit-1"])
            await t.equal("그 실행이 끝나면 한도로 멈췄던 대기열이 이어서 간다", requests.dropFirst().first?.prompt, "그다음 일")
            await t.check("인계는 없다", await env.sentCount(limitID) == 0 && model.handoffCards[limitID] == nil)
            await t.equal("이제 API 로 실행하는 대화 — 한도 줄의 단추는 다시 없다",
                          model.claudeAPIContinueOffer(threadID: limitID, provider: .claude), .none)
            let again = await model.continueWithClaudeAPI(threadID: limitID)
            await t.check("다시 누르면 아무것도 하지 않는다", !again && env.behavior.requests.count == requests.count)

            // 3) 한도 인계 카드(자동 카운트다운도 같은 카드): 카드를 거두고 이어 간다 — 보류했던 메시지도 이어서 간다.
            await model.selectThread(cardID)
            await model.prepareHandoff(to: .codex, toAccountID: nil, threadID: cardID, origin: .limitReached(scope: .claude, resetsAt: nil))
            await t.check("한도 카드가 있다", model.handoffCards[cardID] != nil)
            model.messageQueues[cardID] = [QueuedMessage(text: "카드 뒤의 일")]
            model.holdQueue(threadID: cardID, source: HandoffSource.Agent(provider: .claude, codexAccountID: nil),
                            target: HandoffSource.Agent(provider: .codex, codexAccountID: CodexAccount.defaultID))
            let before = env.behavior.requests.count
            let fromCard = await model.continueWithClaudeAPI(threadID: cardID)
            await env.settle { env.behavior.requests.count >= before + 2 && model.runner.session(threadID: cardID) == nil }
            let cardRequests = Array(env.behavior.requests.dropFirst(before))
            await t.check("카드의 단추: 카드 · 보류를 거두고 켠다",
                          fromCard && model.handoffCards[cardID] == nil && model.queueHolds[cardID] == nil && model.usesClaudeAPI(threadID: cardID))
            await t.equal("카드 대신 같은 세션에 이어 가고, 보류했던 메시지가 뒤따른다", cardRequests.map(\.prompt),
                          [ClaudeAPIContinue.prompt, "카드 뒤의 일"])
            await t.check("넘긴 인계는 없다", await env.sentCount(cardID) == 0)
        } catch {
            await t.check("앱 모델 준비", false, "\(error)")
        }
        ClaudeAPIKey.storage = ClaudeAPIKeyMemoryStorage()
    }

    // MARK: API 크레딧으로 받는 Claude — 받는 쪽 준비 판정

    /// API 로 실행하는 대화에서는 받는 쪽 Claude 의 구독 로그인 · 구독 한도를 보지 않는다 — 칩 메뉴 · 카드의 바꾸기 · 넘기기 막힘 ·
    /// 한도 줄 · 이어 가기 대상이 같은 판정 (`receiverReadiness(_:threadID:)`).
    @MainActor
    private static func apiReceivers(_ t: TestKit) async {
        await t.group("API 크레딧으로 받는 Claude: 받는 쪽 준비 판정 (앱 모델)")
        ClaudeAPIKey.storage = ClaudeAPIKeyMemoryStorage()
        do {
            let env = try await HandoffCardTests.makeEnv("apireceiver", threads: ["API", "구독"])
            defer { env.cleanup() }
            let model = env.model
            let apiID = env.threads[0].id, plainID = env.threads[1].id
            _ = model.saveClaudeAPIKey("sk-ant-api03-recv0000ABCD")
            model.setClaudeAPI(true, threadID: apiID)
            model.cliStatus[.claude] = CLIStatus(provider: .claude, resolvedPath: "/fake/claude", executable: true)
            model.claudeLogin = LoginCheck(loggedIn: false, checkedAt: Date())
            var capped = LimitSnapshot(provider: .claude, accountID: "")
            capped.status = .subscriptionCap
            capped.fetchedAt = Date()
            model.limits.apply(capped)
            let claude = HandoffSource.Agent(provider: .claude, codexAccountID: nil)
            guard let apiThread = env.current(apiID), let plainThread = env.current(plainID) else { throw CocoaError(.fileNoSuchFile) }

            await t.equal("대화를 모르는 판정은 그대로 (구독 로그인 안 됨)", model.receiverReadiness(claude), .notLoggedIn)
            await t.equal("API 대화: 받는 쪽 Claude 는 로그인 없이 준비됨 · 구독 대화는 로그인 안 됨",
                          [model.receiverReadiness(claude, threadID: apiID), model.receiverReadiness(claude, threadID: plainID)],
                          [.ready, .notLoggedIn])
            await t.check("카드의 바꾸기 · 칩 메뉴: API 대화에서는 Claude 를 막지 않는다",
                          model.handoffTargetBlock(claude, thread: apiThread) == nil && model.handoffTargetBlock(claude, thread: plainThread) != nil)
            let apiTarget = model.continueTargets(threadID: apiID).first { $0.agent == claude }
            await t.check("이어 가기 대상: API 크레딧 · 로그인됨 · 오래된 로그인으로 보지 않는다",
                          apiTarget?.apiCredit == true && apiTarget?.authenticated == true && apiTarget?.loginStale == false)
            let codexSource = HandoffSource.Agent(provider: .codex, codexAccountID: CodexAccount.defaultID)
            let viaAPI = model.limitHandoffTarget(after: codexSource, thread: apiThread)
            let viaSub = model.limitHandoffTarget(after: codexSource, thread: plainThread)
            await t.check("한도 줄: Codex 한도 뒤 API 대화는 구독 한도인 Claude 를 확인된 받는 쪽으로 · 구독 대화는 권하지 않는다",
                          viaAPI.agent == claude && viaAPI.confirmed && viaSub.agent != claude, "\(viaAPI) / \(viaSub)")

            // 넘기기 막힘: 카드가 잰 받는 쪽 사실이 "로그인 안 됨" 이어도 API 대화의 Claude 는 막지 않는다.
            func card(_ threadID: String) -> HandoffCard {
                var card = HandoffCard(draft: HandoffDraft(handoff: Handoff(threadID: threadID, fromProvider: .codex, toProvider: .claude,
                                                                            baseSeq: 0, draftJSON: "{}", finalText: "x"),
                                                           packet: HandoffCardTests.packet(), text: "x", threadTitle: "t"),
                                       origin: .manual)
                card.receiver.authenticated = false
                return card
            }
            await t.check("넘기기 막힘: API 대화는 로그인 안 됨으로 막지 않는다 · 구독 대화는 막는다",
                          model.receiverUnavailableReason(card(apiID)) == nil && model.receiverUnavailableReason(card(plainID)) != nil)
            await t.equal("카드의 받는 쪽 사실은 'API 크레딧으로 받음'", HandoffCardText.apiCreditFact.text, "API 크레딧으로 받음")
        } catch {
            await t.check("앱 모델 준비", false, "\(error)")
        }
        ClaudeAPIKey.storage = ClaudeAPIKeyMemoryStorage()
    }
}
