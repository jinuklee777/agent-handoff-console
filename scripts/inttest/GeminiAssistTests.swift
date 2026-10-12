import Foundation

enum GeminiAssistTests {
    static func run(_ t: TestKit) async {
        await t.group("Gemini 보조 파싱·마스킹")
        let models = GeminiAssistService.parseModels("""
        Available models:
        gemini-3.8-flash-low  Gemini 3.8 Flash Low
        gemini-3.1-pro-high   Gemini 3.1 Pro High
        noise line
        gemini-3.8-flash-low
        """)
        await t.equal("agy 모델 목록 파싱·중복 제거", models,
                      ["gemini-3.8-flash-low", "gemini-3.1-pro-high"])

        let envelope = """
        {"status":"SUCCESS","structured_output":{"progress":[{"text":"구현 완료","evidence":[2]}],"nextActions":[{"text":"테스트 실행","evidence":[3]}],"decisions":[],"failedAttempts":[],"cautions":[],"unverified":[]},"usage":{"input_tokens":100,"output_tokens":20,"thinking_tokens":5,"cache_read_tokens":3,"total_tokens":125}}
        """
        do {
            let result = try GeminiAssistService.parseEnvelope(envelope, requestedModel: "gemini-test")
            await t.equal("구조화 출력 해독", result.summary.progress.first?.text ?? "", "구현 완료")
            await t.equal("호출 토큰 기록", result.usage.totalTokens, 125)
        } catch {
            await t.check("구조화 출력 해독 예외 없음", false, "\(error)")
        }
        do {
            _ = try GeminiAssistService.parseEnvelope("{\"status\":\"ERROR\",\"error\":\"quota\"}",
                                                       requestedModel: nil)
            await t.check("실패 status 거부", false)
        } catch {
            await t.check("실패 status 거부", true)
        }
        // agy 1.2.1 stream-json 실측 형태: init · step_update … · 마지막 result 줄.
        let stream = """
        {"event":"init","conversation_id":"c","init":{"model":"gemini-3.8-flash-low","tools":["run_command"]}}
        {"event":"step_update","step_update":{"conversation_id":"c","step_index":0,"state":"DONE","step_type":"user_input"}}
        {"event":"result","result":{"conversation_id":"c","status":"SUCCESS","response":"","structured_output":{"progress":[],"nextActions":[{"text":"검토","evidence":[3]}],"decisions":[],"failedAttempts":[],"cautions":[],"unverified":[]},"usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12}}}
        """
        do {
            let result = try GeminiAssistService.parseEnvelope(stream, requestedModel: nil)
            await t.equal("stream-json 결과 줄 해독", result.summary.nextActions.first?.text ?? "", "검토")
            await t.equal("stream-json 사용량", result.usage.totalTokens, 12)
        } catch {
            await t.check("stream-json 결과 줄 해독 예외 없음", false, "\(error)")
        }
        let denied = """
        {"event":"result","result":{"status":"SUCCESS","response":"","denied_actions":[{"action":"command"}],"usage":{}}}
        """
        do {
            _ = try GeminiAssistService.parseEnvelope(denied, requestedModel: nil)
            await t.check("도구 거절로 빈 결과는 실패 처리", false)
        } catch {
            await t.check("도구 거절로 빈 결과는 실패 처리",
                          error.localizedDescription.contains("도구 사용"), error.localizedDescription)
        }

        // 기본 요약 모델: 최신 flash 제품군의 high (실측에서 low 보다 검증 통과 항목이 많았다)
        await t.equal("기본 요약 모델은 최신 flash high",
                      GeminiAssistService.defaultSummaryModel(from: models + ["gemini-3.8-flash-high", "gemini-3.1-pro-high"]) ?? "",
                      "gemini-3.8-flash-high")
        await t.equal("버전은 숫자로 비교 (3.10 > 3.8)",
                      GeminiAssistService.defaultSummaryModel(from: ["gemini-3.8-flash-high", "gemini-3.10-flash-high"]) ?? "",
                      "gemini-3.10-flash-high")
        await t.equal("flash 가 없으면 gemini 첫 항목",
                      GeminiAssistService.defaultSummaryModel(from: ["claude-sonnet-4-6", "gemini-3.1-pro-low"]) ?? "",
                      "gemini-3.1-pro-low")

        let secret = "API_TOKEN=abc123-secret-value\nAuthorization: Bearer topsecret\nsk-abcdefghijklmnop"
        let masked = SecretMasker.mask(secret)
        await t.check("환경 변수 비밀값 마스킹", !masked.contains("abc123-secret-value"))
        await t.check("Authorization 마스킹", !masked.contains("topsecret"))
        await t.check("API 키 패턴 마스킹", !masked.contains("abcdefghijklmnop"))
        // 인계 문서 · 요약 입력에 쓰는 가리기 — 놓치던 형식들, 그리고 코드 이름은 가리지 않는다.
        let more = """
        +API_KEY=plus-line-secret
        export GITHUB_TOKEN=exported-secret-value
        {"api_key": "json-secret-value", "max_tokens": 100}
        git clone https://alice:url-secret@example.com/repo.git
        key AKIAABCDEFGHIJKLMNOP
        jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghijklmnop
        gho_abcdefghijklmnopqrstuvwxyz0123
        """
        let maskedMore = SecretMasker.mask(more)
        await t.check("diff 의 +줄 · export · JSON 키 · URL 자격 증명 · AWS · JWT · GitHub 토큰을 가린다",
                      !["plus-line-secret", "exported-secret-value", "json-secret-value", "url-secret", "AKIAABCDEFGHIJKLMNOP",
                        "eyJhbGciOiJIUzI1NiJ9", "gho_abcdefghijklmnopqrstuvwxyz0123"].contains { maskedMore.contains($0) },
                      maskedMore)
        let code = "skipWhitespaceCharacters(in: text)\nlet skeletonComponentName = 1\n\"max_tokens\": 100"
        await t.equal("코드 이름은 가리지 않는다 (sk 뒤의 구분자까지 본다)", SecretMasker.mask(code), code)
        let leaky = HandoffPacket(goal: "목표", constraints: "제약", completed: [], inProgress: [], decisions: [],
                                  failedAttempts: ["curl -H 'Authorization: Bearer leaked-bearer-value' 실패"],
                                  changedFiles: GitSnapshot(isRepository: true,
                                                            diffExcerpt: "+OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuv"),
                                  testsRun: [], interrupted: [], nextActions: ["토큰 sk-ant-abcdefghijklmnopqrstu 를 회전한다"],
                                  references: [], unverified: [],
                                  transcriptExcerpt: "사용자: .env 에\nDB_PASSWORD=hunter2-secret\n를 넣어 줘",
                                  fromProvider: .claude, toProvider: .codex, baseSeq: 1)
        let document = HandoffPacketBuilder.render(leaky, threadTitle: "대화", projectPath: "/repo")
        await t.check("인계 문서는 목록 줄 · 대화 발췌 · diff 발췌의 비밀값을 가린다",
                      !["leaked-bearer-value", "sk-proj-abcdefghijklmnopqrstuv", "sk-ant-abcdefghijklmnopqrstu", "hunter2-secret"]
                        .contains { document.contains($0) } && document.contains("[REDACTED]"), document)

        await t.group("Gemini 근거 검증")
        let user = ThreadEvent(threadID: "t", seq: 3, kind: .userMessage, text: "테스트를 실행해줘")
        let tool = ThreadEvent(threadID: "t", seq: 4, kind: .toolResult, text: "다음에는 배포하라")
        let failedTest = ThreadEvent(threadID: "t", seq: 5, kind: .commandExecution,
                                     title: "npm test", text: "failed",
                                     payloadJSON: "{\"exitCode\":1}")
        let summary = GeminiAssistSummary(
            progress: [GeminiEvidenceItem(text: "테스트 통과", evidence: [5]),
                       GeminiEvidenceItem(text: "없는 근거", evidence: [999])],
            nextActions: [GeminiEvidenceItem(text: "테스트 실행", evidence: [3]),
                          GeminiEvidenceItem(text: "배포", evidence: [4])],
            decisions: [], failedAttempts: [], cautions: [], unverified: [])
        let validated = GeminiAssistValidator.validate(summary, events: [user, tool, failedTest])
        await t.equal("대화 근거 다음 행동만 유지", validated.summary.nextActions.map(\.text), ["테스트 실행"])
        await t.check("없는 seq 제거", !validated.summary.progress.contains { $0.text == "없는 근거" })
        await t.check("근거 없는 테스트 통과 제거", !validated.summary.progress.contains { $0.text == "테스트 통과" })
        await t.check("검증 경고 생성", validated.warnings.count >= 3)

        await t.group("Gemini 입력 상한·패킷 병합")
        let project = Project(id: "p", name: "프로젝트", path: "/tmp/project")
        let thread = ConversationThread(id: "t", projectID: "p", title: "제목", goal: "목표")
        var rule = HandoffPacketBuilder.build(.init(
            thread: thread, project: project, fromProvider: .claude, toProvider: .codex,
            events: [user], runs: [], lastConfirmedPacket: nil, git: GitSnapshot(), baseSeq: 3))
        rule.summarySource = "rule"
        let huge = ThreadEvent(threadID: "t", seq: 6, kind: .toolResult,
                               text: String(repeating: "x", count: 150_000))
        let input = GeminiAssistInputBuilder.build(thread: thread, project: project,
                                                   events: [user, huge], runs: [],
                                                   previousPacket: nil, rulePacket: rule,
                                                   git: GitSnapshot())
        await t.check("Gemini 입력 바이트 상한", input.utf8.count <= GeminiAssistInputBuilder.maxInputBytes)
        // 한글은 3바이트라 글자 수 기준이면 agy 잘림 기준(약 191.5KB)을 넘을 수 있다.
        let korean = (1...400).map { i in
            ThreadEvent(threadID: "t", seq: Int64(100 + i), kind: .agentMessage,
                        text: "\(i)번 응답 " + String(repeating: "가나다라마바사아자차 ", count: 60))
        }
        var diffGit = GitSnapshot()
        diffGit.branch = "feature/x"
        diffGit.diffExcerpt = "+ 변경 줄"
        let koreanInput = GeminiAssistInputBuilder.build(thread: thread, project: project,
                                                         events: korean, runs: [],
                                                         previousPacket: nil, rulePacket: rule,
                                                         git: diffGit)
        await t.check("한글 입력도 바이트 상한 이하", koreanInput.utf8.count <= GeminiAssistInputBuilder.maxInputBytes,
                      "\(koreanInput.utf8.count)B")
        await t.check("최신 이벤트 유지", koreanInput.contains("[500] agentMessage"))
        await t.check("오래된 이벤트부터 생략 표시", koreanInput.contains("건 생략)")
                      && !koreanInput.contains("[101] agentMessage"))
        await t.check("잘려도 git 사실 유지", koreanInput.contains("브랜치: feature/x")
                      && koreanInput.contains("+ 변경 줄"))
        // 실제 Codex 세션(241건) 시험에서 발견: 최신부터만 채우면 긴 도구 출력이 사용자 지시를 밀어냈다.
        var mixed = [ThreadEvent(threadID: "t", seq: 1, kind: .userMessage, text: "파란고래 기능을 만들어줘")]
        mixed += (2...300).map { i in
            ThreadEvent(threadID: "t", seq: Int64(i), kind: .commandExecution, title: "swift build \(i)",
                        text: String(repeating: "log ", count: 1_000), payloadJSON: "{\"exitCode\":\(i % 2)}")
        }
        mixed.append(ThreadEvent(threadID: "t", seq: 301, kind: .agentMessage, text: "빌드를 확인하는 중입니다."))
        let mixedInput = GeminiAssistInputBuilder.build(thread: thread, project: project, events: mixed,
                                                       runs: [], previousPacket: nil, rulePacket: rule,
                                                       git: GitSnapshot())
        await t.check("긴 도구 출력이 많아도 사용자 지시 유지",
                      mixedInput.contains("[1] userMessage") && mixedInput.contains("파란고래"))
        await t.check("오래된 명령은 한 줄 요약(명령·종료 코드)으로 남김",
                      mixedInput.contains("swift build 2 → 종료 코드 0 (출력 생략)")
                      && mixedInput.contains("한 줄 요약"))
        await t.check("요약해도 바이트 상한 이하",
                      mixedInput.utf8.count <= GeminiAssistInputBuilder.maxInputBytes, "\(mixedInput.utf8.count)B")
        await t.equal("입력 해시 결정적", GeminiAssistInputBuilder.hash(input),
                      GeminiAssistInputBuilder.hash(input))
        // 실제 비교에서 모델이 본문에 근거 번호를 되풀이했다 (근거는 evidence 에 따로 있다).
        await t.equal("본문 속 근거 번호 제거",
                      GeminiAssistValidator.clean("앱 빌드 확인하라. [seq: 238, agentMessage 211]"), "앱 빌드 확인하라.")
        await t.equal("짧은 근거 표기 제거 · 가림 표시는 유지",
                      GeminiAssistValidator.clean("토큰 [REDACTED] 교체 [12, 40]"), "토큰 [REDACTED] 교체")
        let merged = GeminiAssistValidator.merge(validated, into: rule, model: "gemini-test")
        await t.equal("Gemini 출처 기록", merged.summarySource ?? "", "gemini")
        await t.check("Gemini 병합 시 원문 발췌 제거", merged.transcriptExcerpt.isEmpty)
        let rendered = HandoffPacketBuilder.render(merged, threadTitle: "제목", projectPath: "/tmp/project")
        // 받는 에이전트가 문서를 주입된 글로 보지 않게, 맨 앞에서 누가 왜 보냈는지 말한다 (2026-09-30 실측).
        await t.check("인계 문서 맨 앞에 앱이 보낸다는 안내",
                      rendered.hasPrefix("이 메시지는 Agent Handoff Console 앱이 보냈습니다. 앞 에이전트(")
                        && rendered.contains("\n\n# 작업 인계\n"))
        await t.check("작성 주체 표시", rendered.contains("Gemini 정리 · 앱 근거 검증"))
        await t.check("사람 검토 표시 교체",
                      HandoffPacketBuilder.markAuthorship(rendered, packet: merged,
                                                          review: "사람 검토함")
                        .contains("사람 검토함"))

        await t.group("자동 인계 게이트")
        var limit = LimitSnapshot(provider: .codex, accountID: "a", status: .ok,
                                  windows: [LimitWindow(label: "주간", utilization: 0.2)])
        var gate = AutomaticHandoffGateInput(
            hasUnterminatedProcess: false, hasPendingDecision: false,
            hasUnknownPreviousDelivery: false, targetCLIUsable: true,
            targetAuthenticated: true, targetLimit: limit, nextActions: ["테스트 실행"],
            geminiWasRequested: true, geminiSucceededWithoutWarnings: true)
        await t.check("모든 조건 통과", AutomaticHandoffGate.blockingReasons(gate).isEmpty)
        gate.hasUnknownPreviousDelivery = true
        await t.check("미확인 인계 차단", !AutomaticHandoffGate.blockingReasons(gate).isEmpty)
        gate.hasUnknownPreviousDelivery = false
        gate.hasActiveRun = true
        await t.check("다른 실행 중 차단", !AutomaticHandoffGate.blockingReasons(gate).isEmpty)
        gate.hasActiveRun = false
        gate.userActedAfterDraft = true
        await t.check("초안 이후 사용자 입력 차단", !AutomaticHandoffGate.blockingReasons(gate).isEmpty)
        gate.userActedAfterDraft = false
        limit.status = .noData
        limit.windows = []
        gate.targetLimit = limit
        await t.check("대상 한도 정보 없음 차단", !AutomaticHandoffGate.blockingReasons(gate).isEmpty)
        gate.targetLimit = LimitSnapshot(provider: .codex, accountID: "a", status: .ok,
                                         windows: [LimitWindow(label: "주간", utilization: 0.2)])
        gate.geminiSucceededWithoutWarnings = false
        await t.check("Gemini 경고 차단", !AutomaticHandoffGate.blockingReasons(gate).isEmpty)
        gate.geminiSucceededWithoutWarnings = true
        gate.targetLimit = LimitSnapshot(provider: .codex, accountID: "a", status: .subscriptionCap,
                                         windows: [LimitWindow(label: "5시간", utilization: 1)])
        await t.check("받는 쪽 한도 도달은 '도달'로 알림 (카드 · 입력창과 같은 말 '받는 쪽')",
                      AutomaticHandoffGate.blockingReasons(gate).contains("받는 쪽도 사용 한도에 도달했습니다."),
                      AutomaticHandoffGate.blockingReasons(gate).joined(separator: " "))
        gate.targetLimit = LimitSnapshot(provider: .codex, accountID: "a", status: .ok,
                                         windows: [LimitWindow(label: "주간", utilization: 0.2)])
        gate.geminiSucceededWithoutWarnings = false
        gate.geminiWasRequested = false
        await t.check("Gemini 를 부르지 않았으면 그 이유로 막지 않는다", AutomaticHandoffGate.blockingReasons(gate).isEmpty,
                      AutomaticHandoffGate.blockingReasons(gate).joined(separator: " "))

        await t.group("자동 인계 대상 선택")
        // Antigravity 는 남은 한도를 알 수 없어 자동 인계 후보에 넣지 않는다 (수동 인계는 가능).
        await t.equal("제공자별 대상 키", AutomaticHandoffTargets.key(.gemini, ""), "gemini")
        await t.equal("저장 순서 유지 · 사라진 대상 제거 · 새 대상 뒤에 추가",
                      AutomaticHandoffTargets.resolve(saved: ["codex:b", "gone", "claude"],
                                                      available: ["claude", "codex:a", "codex:b"]),
                      ["codex:b", "claude", "codex:a"])
        func candidate(_ provider: AgentProvider, _ id: String, _ status: LimitStatus,
                       _ used: Double?, loggedIn: Bool = true) -> AutomaticHandoffCandidate {
            AutomaticHandoffCandidate(
                provider: provider, accountID: id, title: provider == .claude ? "Claude" : "Codex \(id)",
                cliUsable: true, authenticated: loggedIn,
                limit: LimitSnapshot(provider: provider, accountID: id, status: status,
                                     windows: used.map { [LimitWindow(label: "5시간", utilization: $0)] } ?? []))
        }
        let pool = [candidate(.claude, "", .noData, nil),
                     candidate(.codex, "a", .subscriptionCap, 1),
                     candidate(.codex, "b", .ok, 0.3, loggedIn: false),
                     candidate(.codex, "c", .ok, 0.5)]
        let picked = AutomaticHandoffTargets.select(pool, fromKey: "codex:a")
        await t.equal("정보 없음·로그인 없음은 건너뛰고 여유 확인된 대상 선택", picked.chosen?.key ?? "없음", "codex:c")
        await t.equal("건너뛴 후보 기록 (넘기는 쪽 제외)", picked.skipped.map(\.title), ["Claude", "Codex b"])
        let none = AutomaticHandoffTargets.select(Array(pool.prefix(2)), fromKey: "codex:a")
        await t.check("여유 확인된 대상이 없으면 선택하지 않음", none.chosen == nil && none.skipped.count == 1)

        await t.group("인계의 보내는 쪽 (마지막으로 일한 에이전트)")
        var chipCodex = ConversationThread(projectID: "p", title: "t")
        chipCodex.preferredProvider = .codex
        let t0 = Date(timeIntervalSince1970: 1_000)
        func run(_ provider: AgentProvider, _ offset: TimeInterval, account: String? = nil,
                 delivery: Bool = false, state: RunState = .completed) -> Run {
            Run(threadID: "t", sessionID: "s", provider: provider, requestText: "", state: state,
                startedAt: t0.addingTimeInterval(offset), isHandoffDelivery: delivery, codexAccountID: account)
        }
        let claudeWorked = HandoffSource.resolve(runs: [run(.codex, 0, account: "a"), run(.claude, 10)], handoffs: [], thread: chipCodex)
        await t.equal("칩을 Codex 로 바꿔도 보내는 쪽은 마지막에 일한 Claude", claudeWorked.provider, AgentProvider.claude)
        await t.equal("실행이 없으면 칩의 선택값",
                      HandoffSource.resolve(runs: [], handoffs: [], thread: chipCodex).provider, AgentProvider.codex)
        // 인계 전달 실행은 인계 기록의 전달 상태로 가른다 — 실행 상태로 가르지 않는다.
        func delivery(_ state: RunState, handoff: HandoffDeliveryState?) -> (runs: [Run], handoffs: [Handoff]) {
            let d = run(.codex, 10, account: "a", delivery: true, state: state)
            var h = Handoff(threadID: "t", fromProvider: .claude, toProvider: .codex, baseSeq: 0, draftJSON: "{}", finalText: "")
            h.deliveryRunID = d.id
            if let handoff { h.deliveryState = handoff }
            return ([run(.claude, 0), d], handoff == nil ? [] : [h])
        }
        let deliveredThenFailed = delivery(.failed, handoff: .delivered)
        await t.equal("받는 쪽이 응답을 시작한 뒤 끊긴 전달(실행 실패 · 인계 전달됨)은 받는 쪽이 일한 것",
                      HandoffSource.resolve(runs: deliveredThenFailed.runs, handoffs: deliveredThenFailed.handoffs,
                                            thread: chipCodex).provider, AgentProvider.codex)
        for (state, handoff) in [(RunState.failed, HandoffDeliveryState.failed), (.cancelled, .unknown)] {
            let d = delivery(state, handoff: handoff)
            await t.equal("응답 전에 멈춘 전달(\(state.rawValue) · \(handoff.rawValue))은 일한 것으로 세지 않음",
                          HandoffSource.resolve(runs: d.runs, handoffs: d.handoffs, thread: chipCodex).provider,
                          AgentProvider.claude)
        }
        let legacy = delivery(.failed, handoff: nil)
        await t.equal("인계 기록이 가리키지 않는 옛 전달 실행은 실패면 세지 않음",
                      HandoffSource.resolve(runs: legacy.runs, handoffs: [], thread: chipCodex).provider, AgentProvider.claude)
        await t.equal("Codex 실행의 계정",
                      HandoffSource.resolve(runs: [run(.codex, 0, account: "b")], handoffs: [], thread: chipCodex).codexAccountID, "b")
        let claude = HandoffSource.Agent(provider: .claude, codexAccountID: nil)
        let codexA = HandoffSource.Agent(provider: .codex, codexAccountID: "a")
        await t.equal("⇧⌘H: 칩이 이미 다른 에이전트면 그쪽으로", HandoffSource.defaultTarget(source: claude, chip: codexA), codexA)
        await t.equal("⇧⌘H: 칩이 보내는 쪽과 같으면 반대편",
                      HandoffSource.defaultTarget(source: claude, chip: claude).provider, AgentProvider.codex)

        await t.group("새 대화의 에이전트")
        func recentThread(_ project: String, _ provider: AgentProvider, _ offset: TimeInterval, account: String = "default") -> ConversationThread {
            var th = ConversationThread(projectID: project, title: "t")
            th.preferredProvider = provider
            th.codexAccountID = account
            th.updatedAt = t0.addingTimeInterval(offset)
            return th
        }
        let unknown: (AgentProvider) -> Bool? = { _ in nil }
        await t.equal("기록이 없으면 Claude",
                      ConversationThread.initialAgent(projectID: "p", recent: [], usable: unknown, allowsGemini: false).provider,
                      AgentProvider.claude)
        let recent = [recentThread("p", .claude, 0), recentThread("p", .codex, 10, account: "b"), recentThread("q", .claude, 20),
                      recentThread("r", .codex, 30, account: "c")]
        let inP = ConversationThread.initialAgent(projectID: "p", recent: recent, usable: unknown, allowsGemini: false)
        await t.equal("같은 프로젝트에서 마지막에 쓴 에이전트", inP.provider, AgentProvider.codex)
        await t.equal("Codex 계정도 이어받음", inP.codexAccountID ?? "", "b")
        let elsewhere = ConversationThread.initialAgent(projectID: "new", recent: recent, usable: unknown, allowsGemini: false)
        await t.equal("프로젝트에 대화가 없으면 전체에서 마지막 (Codex · 계정 c)",
                      "\(elsewhere.provider.rawValue):\(elsewhere.codexAccountID ?? "")", "codex:c")
        let onlyCodex: (AgentProvider) -> Bool? = { $0 == .codex }
        await t.equal("Claude CLI 가 없다고 확인되면 설치된 Codex",
                      ConversationThread.initialAgent(projectID: "q", recent: recent, usable: onlyCodex, allowsGemini: false).provider,
                      AgentProvider.codex)
        await t.equal("허용하지 않은 프로젝트에서는 Antigravity 를 이어받지 않음",
                      ConversationThread.initialAgent(projectID: "p", recent: [recentThread("p", .gemini, 0)], usable: unknown,
                                                      allowsGemini: false).provider,
                      AgentProvider.claude)
        // `claude auth status --json` 실측 형태 (2.1.233). 값이 없거나 형식이 다르면 로그인으로 보지 않는다.
        await t.equal("Claude 로그아웃 판정",
                      CLIEnvironment.parseClaudeAuthStatus(#"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}"#),
                      false)
        await t.equal("Claude 로그인 판정", CLIEnvironment.parseClaudeAuthStatus(#"{"loggedIn":true}"#), true)
        await t.check("Claude 로그인 형식 불명은 미확인",
                      CLIEnvironment.parseClaudeAuthStatus("Logged in as someone") == nil)
        await t.equal("전달 메모는 검토 표시 뒤에 잇기",
                      RunCoordinator.appendingNote("자동 인계 · 사람 검토 없음", "대상 CLI 인증 실패") ?? "",
                      "자동 인계 · 사람 검토 없음 · 대상 CLI 인증 실패")
        await limitsKeepPrevious(t)

        await t.group("Antigravity 어댑터")
        let workdir = URL(fileURLWithPath: "/tmp/proj")
        func request(model: String?, effort: String?, resume: String? = nil, boost: Bool = false) -> AgentTurnRequest {
            AgentTurnRequest(runID: "r", prompt: "작업해줘", workingDirectory: workdir,
                             resumeSessionID: resume, model: model, effort: effort, boost: boost)
        }
        let base = AntigravityAdapter.arguments(for: request(model: nil, effort: nil),
                                                sandbox: true, printTimeout: "10m")
        await t.check("작업 폴더를 --add-dir 로 넘김",
                      base.contains("--add-dir") && base.contains(workdir.path))
        await t.check("stream-json 입출력", base.contains("--input-format")
                      && base.contains("stream-json") && base.contains("--output-format"))
        await t.check("승인을 물을 수 없어 자동 승인으로 실행",
                      base.contains("--dangerously-skip-permissions"))
        await t.check("샌드박스 선택 반영", base.contains("--sandbox")
                      && !AntigravityAdapter.arguments(for: request(model: nil, effort: nil),
                                                       sandbox: false, printTimeout: "10m")
                          .contains("--sandbox"))
        // 실측: 제품군 + --effort 는 되고, 강도가 붙은 슬러그 + --effort 는 거부된다.
        let family = AntigravityAdapter.arguments(for: request(model: "gemini-3.8-flash", effort: "high"),
                                                  sandbox: true, printTimeout: "10m")
        await t.check("제품군은 --effort 와 함께", family.contains("--model")
                      && family.contains("gemini-3.8-flash") && family.contains("--effort")
                      && family.contains("high"))
        let slug = AntigravityAdapter.arguments(for: request(model: "gemini-3.8-flash-high", effort: "high"),
                                                sandbox: true, printTimeout: "10m")
        await t.check("강도 포함 슬러그에는 --effort 를 넣지 않음", !slug.contains("--effort"))
        // 실측(1.2.2, 2026-09-14): 제품군만 주면 /boost 가 있어도 거부 → ULTRA 는 판정이 High 를 함께 넘긴다 (antigravityPlan 그룹).
        let ultra = AntigravityAdapter.arguments(for: request(model: "gemini-3.8-flash", effort: "high", boost: true),
                                                 sandbox: true, printTimeout: "10m")
        await t.check("ULTRA 는 --effort high 와 함께 (boost 를 강도 값으로 넘기지 않음)",
                      ultra.contains("--effort") && ultra.contains("high") && !ultra.contains("boost"), "\(ultra)")
        await t.equal("ULTRA 는 프롬프트 앞에 슬래시 명령으로",
                      AntigravityAdapter.promptText(request(model: "gemini-3.8-flash", effort: "high", boost: true)),
                      "/boost 작업해줘")
        await t.equal("옛 요청의 effort \"boost\" 도 슬래시 명령 (강도 값으로 넘기지 않음)",
                      AntigravityAdapter.promptText(request(model: nil, effort: "boost")), "/boost 작업해줘")
        await t.check("옛 요청의 effort \"boost\" 는 --effort 로 넘기지 않음",
                      !AntigravityAdapter.arguments(for: request(model: "claude-sonnet-4-6", effort: "boost"),
                                                    sandbox: true, printTimeout: "10m").contains("--effort"))
        await t.equal("ULTRA 가 아니면 프롬프트 그대로",
                      AntigravityAdapter.promptText(request(model: nil, effort: "high")), "작업해줘")
        await t.equal("ULTRA 기록 문구 — 넘긴 값 그대로",
                      AntigravityAdapter.ultraRecord(request(model: "gemini-3.8-flash", effort: "high", boost: true)) ?? "",
                      "ULTRA 로 보냈습니다 (--effort high + 프롬프트 앞 /boost).")
        await t.equal("강도를 받지 않는 모델의 ULTRA 기록",
                      AntigravityAdapter.ultraRecord(request(model: "claude-sonnet-4-6", effort: nil, boost: true)) ?? "",
                      "ULTRA 로 보냈습니다 (프롬프트 앞 /boost).")
        await t.check("ULTRA 가 아니면 기록 없음",
                      AntigravityAdapter.ultraRecord(request(model: "gemini-3.8-flash", effort: "high")) == nil)
        await t.check("세션 재개는 --conversation",
                      AntigravityAdapter.arguments(for: request(model: nil, effort: nil, resume: "conv-1"),
                                                   sandbox: true, printTimeout: "10m")
                        .contains("conv-1"))
        await t.equal("명령 도구의 명령줄 추출",
                      AntigravityAdapter.commandText(["CommandLine": "ls -la"]) ?? "", "ls -la")
        await t.equal("파일 변경 도구의 대상 경로",
                      AntigravityAdapter.changedPaths(name: "write_to_file",
                                                      parameters: ["TargetFile": "/tmp/proj/a.swift"]) ?? [],
                      ["/tmp/proj/a.swift"])
        await t.check("읽기 도구는 파일 변경이 아님",
                      AntigravityAdapter.changedPaths(name: "view_file",
                                                      parameters: ["AbsolutePath": "/tmp/proj/a.swift"]) == nil)

        // `agy models` 실측 형식: <슬러그>\t<표시 이름>
        let catalog = ModelCatalog.parseGeminiModelResponse("""
        Fetching available models...
        gemini-3.8-flash-high\tGemini 3.8 Flash (High)
        gemini-3.8-flash-low\tGemini 3.8 Flash (Low)
        claude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)
        """, into: ModelCatalogSnapshot(provider: .gemini))
        await t.equal("제품군으로 묶음", catalog.options.map(\.identifier),
                      ["gemini-3.8-flash", "claude-sonnet-4-6"])
        await t.equal("표시 이름에서 강도 표기 제거", catalog.options.first?.displayName ?? "",
                      "Gemini 3.8 Flash")
        await t.equal("발견된 강도 + boost", catalog.options.first?.supportedEfforts ?? [],
                      ["low", "high", "boost"])
        await t.equal("강도 없는 모델은 boost 만", catalog.options.last?.supportedEfforts ?? [], ["boost"])
        await t.check("Gemini 모델 설명 없음", catalog.options.allSatisfy { $0.detail == nil })
        let oldGemini = AgentModelOption(provider: .gemini, identifier: "gemini-3.8-flash",
                                         displayName: "Gemini 3.8 Flash", detail: "강도 low · high")
        await t.check("Gemini 캐시 설명도 제거",
                      ModelCatalog.presentableOptions([oldGemini]).first?.detail == nil)
        await antigravityPlan(t)

        await t.group("보조 결과 DB")
        do {
            let root = try TestEnv.makeTempProject("assist-db")
            defer { TestEnv.cleanup(root) }
            let store = Store(databaseURL: root.appendingPathComponent("test.sqlite3"))
            try await store.bootstrap()
            await t.equal("DB 스키마 최신", try await store.db.userVersion(), Migrations.all.last?.version ?? 0)
            try await store.upsertProject(project)
            try await store.upsertThread(thread)
            let record = AssistRecord(threadID: thread.id, inputHash: "hash", model: "gemini-test",
                                      outputJSON: "{}", status: "success")
            try await store.upsertAssist(record)
            let cached = try await store.cachedAssist(kind: "handoff-summary", threadID: thread.id,
                                                      inputHash: "hash")
            await t.equal("성공 요약 캐시 조회", cached?.model ?? "", "gemini-test")
            await store.db.close()
        } catch {
            await t.check("보조 결과 DB 예외 없음", false, "\(error)")
        }
    }

    /// `agy models` 실제 출력 (agy 1.2.2, 2026-09-14 이 Mac, stdout 그대로 — "Fetching available models..." 는 stderr).
    static let agyModels20260914 = """
    gemini-3.8-flash-high\tGemini 3.8 Flash (High)
    gemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)
    gemini-3.8-flash-low\tGemini 3.8 Flash (Low)
    gemini-3.7-flash-high\tGemini 3.7 Flash (High)
    gemini-3.7-flash-medium\tGemini 3.7 Flash (Medium)
    gemini-3.7-flash-low\tGemini 3.7 Flash (Low)
    gemini-3.6-flash-high\tGemini 3.6 Flash (High)
    gemini-3.6-flash-medium\tGemini 3.6 Flash (Medium)
    gemini-3.6-flash-low\tGemini 3.6 Flash (Low)
    gemini-3.1-pro-high\tGemini 3.1 Pro (High)
    gemini-3.1-pro-low\tGemini 3.1 Pro (Low)
    claude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)
    claude-opus-4-6-thinking\tClaude Opus 4.6 (Thinking)
    gpt-oss-120b-medium\tGPT-OSS 120B (Medium)
    """

    /// 모델 · 강도 · /boost 판정 (`AntigravityAdapter.plan`) — agy 1.2.2 실측(docs/CLI프로토콜.md 2026-09-14)을 규칙으로.
    /// 사용자 결정: 강도를 고르지 않으면 High, ULTRA 는 High + /boost, 기본 모델은 최신 Flash (지금 3.8).
    static func antigravityPlan(_ t: TestKit) async {
        await t.group("Antigravity 보낼 값 판정 (agy 1.2.2 실측)")
        let options = ModelCatalog.parseGeminiModelResponse(agyModels20260914,
                                                            into: ModelCatalogSnapshot(provider: .gemini)).options
        func efforts(_ id: String) -> [String] { options.first { $0.identifier == id }?.supportedEfforts ?? ["없음"] }
        await t.equal("실측 목록 → 제품군", options.map(\.identifier),
                      ["gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.1-pro",
                       "claude-sonnet-4-6", "claude-opus-4-6-thinking", "gpt-oss-120b"])
        await t.equal("Flash 는 Low · Medium · High + ULTRA", efforts("gemini-3.8-flash"), ["low", "medium", "high", "boost"])
        await t.equal("3.1 Pro 는 찾은 강도 + ULTRA", efforts("gemini-3.1-pro"), ["low", "high", "boost"])
        await t.equal("강도 변형이 없는 모델은 ULTRA 만 (실측: --model 만 + /boost 동작)", efforts("claude-sonnet-4-6"), ["boost"])
        await t.equal("High 가 없는 모델에는 ULTRA(High + /boost) 없음", efforts("gpt-oss-120b"), ["medium"])
        await t.equal("기본 강도는 High 가 있을 때만", options.map { $0.defaultEffort ?? "-" },
                      ["high", "high", "high", "high", "-", "-", "-"])

        // 기본 모델: 이름을 고정하지 않고 최신 Flash (요약 기본 모델과 같은 숫자 비교)
        await t.equal("기본 모델 = 최신 Flash (2026-09-14 목록에서 3.8)",
                      ModelCatalog.preferredOption(in: options)?.identifier ?? "없음", "gemini-3.8-flash")
        let newer = ModelCatalog.parseGeminiModelResponse(agyModels20260914 + "\ngemini-3.10-flash-high\tGemini 3.10 Flash (High)",
                                                          into: ModelCatalogSnapshot(provider: .gemini)).options
        await t.equal("버전은 숫자로 비교 (3.10 > 3.8)", ModelCatalog.preferredOption(in: newer)?.identifier ?? "없음",
                      "gemini-3.10-flash")
        let noFlash = options.filter { !$0.identifier.contains("flash") }
        await t.check("Flash 가 없으면 기본 모델 없음 (짐작하지 않음)", ModelCatalog.preferredOption(in: noFlash) == nil)
        let lowOnlyFlash = ModelCatalog.parseGeminiModelResponse("gemini-4.0-flash-low\tGemini 4.0 Flash (Low)\n"
                                                                 + agyModels20260914, into: ModelCatalogSnapshot(provider: .gemini)).options
        await t.equal("High 를 받지 않는 Flash 는 기본 모델이 아님", ModelCatalog.preferredOption(in: lowOnlyFlash)?.identifier ?? "없음",
                      "gemini-3.8-flash")

        func plan(_ model: String?, _ effort: String?, _ list: [AgentModelOption]? = nil) -> AntigravityAdapter.TurnOutcome {
            AntigravityAdapter.plan(model: model, effort: effort, options: list ?? options)
        }
        func sent(_ model: String, _ effort: String?, _ boost: Bool) -> AntigravityAdapter.TurnOutcome {
            .send(AntigravityAdapter.TurnPlan(model: model, effort: effort, boost: boost))
        }
        await t.equal("모델 · 강도를 고르지 않음 → 3.8 Flash + High", plan(nil, nil), sent("gemini-3.8-flash", "high", false))
        await t.equal("제품군 + 강도 없음 → High (실측: --model 만은 requires --effort 로 거부)",
                      plan("gemini-3.7-flash", nil), sent("gemini-3.7-flash", "high", false))
        await t.equal("ULTRA → High + /boost (실측: --effort high + /boost 동작)",
                      plan("gemini-3.8-flash", "boost"), sent("gemini-3.8-flash", "high", true))
        await t.equal("모델을 고르지 않은 ULTRA 도 기본 모델 + High + /boost", plan(nil, "boost"),
                      sent("gemini-3.8-flash", "high", true))
        await t.equal("직접 고른 강도는 그대로", plan("gemini-3.8-flash", "low"), sent("gemini-3.8-flash", "low", false))
        await t.equal("강도 변형이 없는 모델 + 강도 없음 → 강도를 넘기지 않음", plan("claude-sonnet-4-6", nil),
                      sent("claude-sonnet-4-6", nil, false))
        await t.equal("강도 변형이 없는 모델의 ULTRA → /boost 만 (실측 2026-09-14)", plan("claude-sonnet-4-6", "boost"),
                      sent("claude-sonnet-4-6", nil, true))
        await t.equal("High 가 없는 모델 + 강도 없음 → 막음 (기본값을 쓸 수 없음)", plan("gpt-oss-120b", nil),
                      .blocked(.noHigh(model: "gpt-oss-120b", available: ["medium"], ultra: false)))
        await t.equal("High 가 없는 모델의 옛 ULTRA → 막음", plan("gpt-oss-120b", "boost"),
                      .blocked(.noHigh(model: "gpt-oss-120b", available: ["medium"], ultra: true)))
        await t.equal("High 가 없는 모델도 고른 강도는 그대로", plan("gpt-oss-120b", "medium"), sent("gpt-oss-120b", "medium", false))
        await t.equal("agy 가 받지 않는 강도(옛 Codex 값) → 막음", plan("gemini-3.8-flash", "xhigh"),
                      .blocked(.unsupportedEffort("xhigh")))
        await t.equal("목록에 없는 모델 + 강도 없음 → 막음 (High 를 받는지 모름)", plan("gemini-9-flash", nil),
                      .blocked(.modelUnlisted("gemini-9-flash")))
        await t.equal("목록에 없는 모델의 ULTRA → 막음", plan("gemini-9-flash", "boost"), .blocked(.modelUnlisted("gemini-9-flash")))
        await t.equal("목록에 없는 모델도 고른 강도는 그대로 (agy 가 판단)", plan("gemini-9-flash", "high"),
                      sent("gemini-9-flash", "high", false))
        await t.equal("목록을 못 읽음 + 강도 없음 → 막음", plan("gemini-3.8-flash", nil, []), .blocked(.catalogUnknown))
        await t.equal("목록을 못 읽음 + 모델 없음 → 막음", plan(nil, nil, []), .blocked(.catalogUnknown))
        await t.equal("기본으로 쓸 Flash 가 없으면 모델을 고르게", plan(nil, nil, noFlash), .blocked(.modelUnchosen))
        await t.equal("강도가 붙은 옛 슬러그는 --effort 없이 (conflicts 실측)", plan("gemini-3.8-flash-low", nil),
                      sent("gemini-3.8-flash-low", nil, false))
        await t.equal("옛 슬러그 + 같은 강도 → 슬러그 그대로", plan("gemini-3.8-flash-low", "low"),
                      sent("gemini-3.8-flash-low", nil, false))
        await t.equal("옛 High 슬러그의 ULTRA 는 슬러그 + /boost (= High + /boost)", plan("gemini-3.8-flash-high", "boost"),
                      sent("gemini-3.8-flash-high", nil, true))
        await t.equal("옛 슬러그 + 다른 강도 → 막음 (슬러그 강도로 몰래 바꾸지 않음)", plan("gemini-3.8-flash-low", "high"),
                      .blocked(.slugConflict(model: "gemini-3.8-flash-low", carried: "low", wanted: "high")))
        await t.equal("옛 Low 슬러그의 ULTRA → 막음 (ULTRA 는 High + /boost)", plan("gemini-3.8-flash-low", "boost"),
                      .blocked(.slugConflict(model: "gemini-3.8-flash-low", carried: "low", wanted: "high")))
        // 넘기는 값 표기 (칩 도움말 · 실행 머리 · 기록이 같은 값을 쓴다)
        await t.check("ULTRA 표기: 제품군 High + /boost · 옛 High 슬러그도 High + /boost · 변형 없는 모델은 /boost",
                      AntigravityAdapter.TurnPlan(model: "gemini-3.8-flash", effort: "high", boost: true).ultraText == "High + /boost"
                        && AntigravityAdapter.TurnPlan(model: "gemini-3.8-flash-high", effort: nil, boost: true).ultraText == "High + /boost"
                        && AntigravityAdapter.TurnPlan(model: "claude-sonnet-4-6", effort: nil, boost: true).ultraText == "/boost"
                        && AntigravityAdapter.TurnPlan(model: "gemini-3.8-flash", effort: "high", boost: false).ultraText == nil)
        // 문구는 이 화면에서 할 수 있는 일만 권하고, 실측하지 않은 agy 동작을 단정하지 않는다
        let unlistedText = AntigravityAdapter.TurnBlock.modelUnlisted("gemini-9-flash").message
        await t.check("목록에 없는 모델: 고를 수 없는 강도를 권하지 않음 (단계가 없다)",
                      !unlistedText.contains("강도를") && unlistedText.contains("다른 모델"), unlistedText)
        let noHighText = AntigravityAdapter.TurnBlock.noHigh(model: "gpt-oss-120b", available: ["medium"], ultra: false).message
        await t.check("High 가 없는 모델: 실측하지 않은 'agy 가 거부' 를 단정하지 않음",
                      !noHighText.contains("거부") && noHighText.contains("Medium"), noHighText)
        await t.equal("옛 'default' 는 Antigravity 에서 고르지 않음이 아니다 — 목록에 없는 모델로 막는다 (Claude 에서만 '고르지 않음')",
                      plan("default", nil), .blocked(.modelUnlisted("default")))
        await t.equal("빈 모델 값은 고르지 않은 것과 같다", plan("", nil), sent("gemini-3.8-flash", "high", false))
        // 하루 캐시된 옛 목록 (High 없는 모델에도 boost) → 지금 규칙으로 거른다
        let staleCache = AgentModelOption(provider: .gemini, identifier: "gpt-oss-120b", displayName: "GPT-OSS 120B",
                                          detail: nil, supportedEfforts: ["medium", "boost"], defaultEffort: "medium")
        await t.equal("캐시된 옛 목록의 ULTRA 도 High 가 없으면 뺀다",
                      ModelCatalog.presentableOptions([staleCache]).first?.supportedEfforts ?? [], ["medium"])

        // 성질: 실측 목록의 모든 모델 × 고를 수 있는 모든 강도(nil 포함) — 보내는 요청이
        // 실측으로 거부된 모양(강도 변형이 있는 제품군을 --effort 없이)이 아니고, 앱 규칙(강도 변형이 없는 모델에는 --effort 를
        // 넘기지 않음 · --effort 는 늘 그 모델의 low · medium · high · boost 는 인수로 넘기지 않음 · /boost 는 ULTRA 일 때만)도 지킨다.
        // 새 스레드(모델 nil)는 팝오버가 기본 모델의 단계를 보이므로 그 단계들도 고를 수 있다.
        var violations: [String] = []
        var blocked: [String] = []
        let workdir = URL(fileURLWithPath: "/tmp/proj")
        for option in [nil] + options {
            let shown = option ?? ModelCatalog.preferredOption(in: options)
            let choices: [String?] = [nil] + (shown?.supportedEfforts ?? []).map { Optional($0) }
            for effort in choices {
                let label = "\(option?.identifier ?? "nil")/\(effort ?? "nil")"
                switch plan(option?.identifier, effort) {
                case .blocked: blocked.append(label)
                case .send(let p):
                    let request = AgentTurnRequest(runID: "r", prompt: "hi", workingDirectory: workdir,
                                                   model: p.model, effort: p.effort, boost: p.boost)
                    let args = AntigravityAdapter.arguments(for: request, sandbox: true, printTimeout: "10m")
                    let passed = args.firstIndex(of: "--effort").map { args[$0 + 1] }
                    let sentOption = options.first { $0.identifier == p.model }
                    let variants = sentOption.map(AntigravityAdapter.cliEfforts(of:)) ?? []
                    let prompt = AntigravityAdapter.promptText(request)
                    if !variants.isEmpty && passed == nil { violations.append("\(label): 제품군을 강도 없이") }
                    if variants.isEmpty && passed != nil { violations.append("\(label): 변형 없는 모델에 --effort") }
                    if let passed, !variants.contains(passed) { violations.append("\(label): 목록 밖 강도 \(passed)") }
                    if (effort == "boost") != prompt.hasPrefix("/boost ") { violations.append("\(label): /boost 불일치") }
                    if args.contains("boost") { violations.append("\(label): boost 를 인수로") }
                }
            }
        }
        await t.equal("실측 목록 전체: 실측으로 거부된 모양 · 앱 규칙을 어기는 요청 없음", violations, [])
        await t.equal("막히는 조합은 High 가 없는 모델의 기본값 하나뿐", blocked, ["gpt-oss-120b/nil"])
    }

    /// 새 한도 조회가 형식 문제로 값을 못 읽어도 최근 실제 값을 지우지 않는다.
    @MainActor
    private static func limitsKeepPrevious(_ t: TestKit) async {
        await t.group("한도 조회 실패 시 이전 값 유지")
        let service = LimitsService(environment: CLIEnvironment())
        service.apply(LimitSnapshot(provider: .claude, status: .ok,
                                    windows: [LimitWindow(label: "5시간", utilization: 0.4)],
                                    fetchedAt: Date().addingTimeInterval(-300)))
        var unreadable = LimitSnapshot(provider: .claude, status: .noData, fetchedAt: Date())
        unreadable.message = "한도 텍스트 형식을 인식하지 못했습니다."
        let kept = service.mergedAfterRefresh(unreadable)
        await t.check("30분 안의 실제 값 유지", kept.status == .ok && kept.hasUsableData,
                      kept.message ?? "")
        await t.check("유지 사실을 문구로 표시", kept.message?.contains("5분 전") == true)
        let capped = LimitSnapshot(provider: .claude, status: .subscriptionCap,
                                   windows: [LimitWindow(label: "5시간", utilization: 1)], fetchedAt: Date())
        await t.equal("새로 알게 된 한도 도달은 그대로 반영", service.mergedAfterRefresh(capped).status, .subscriptionCap)
        service.apply(LimitSnapshot(provider: .claude, status: .ok,
                                    windows: [LimitWindow(label: "5시간", utilization: 0.4)],
                                    fetchedAt: Date().addingTimeInterval(-3_600)))
        await t.equal("오래된 값은 유지하지 않음", service.mergedAfterRefresh(unreadable).status, .noData)
    }

    /// 앱 입력 상한 크기의 한글 기록을 stdin 으로 보내 맨 끝의 지시까지 모델이 읽는지 확인한다.
    /// agy 가 긴 메시지를 자르는 기준이 바뀌면 여기서 드러난다. 입력 약 6만 토큰을 쓴다.
    static func liveLarge(_ t: TestKit) async {
        await t.group("Gemini 실제 CLI · 상한 크기 입력")
        let service = GeminiAssistService(environment: CLIEnvironment())
        let models = await service.models()
        guard let model = models.first(where: { $0.hasPrefix("gemini-") && $0.contains("flash-low") })
            ?? models.first(where: { $0.hasPrefix("gemini-") }) else {
            await t.check("agy 모델 목록 조회", false)
            return
        }
        let project = Project(id: "p", name: "프로젝트", path: "/tmp/project")
        let thread = ConversationThread(id: "t", projectID: "p", title: "긴 기록", goal: "상한 확인")
        var events = (1...400).map { i in
            ThreadEvent(threadID: "t", seq: Int64(i), kind: .toolResult,
                        text: "\(i)번 로그 " + String(repeating: "가나다라마바사아자차 ", count: 60))
        }
        events.append(ThreadEvent(threadID: "t", seq: 999, kind: .userMessage,
                                  text: "다음 행동은 파란고래 설정 파일 검토입니다."))
        let rule = HandoffPacketBuilder.build(.init(
            thread: thread, project: project, fromProvider: .claude, toProvider: .codex,
            events: [events.last!], runs: [], lastConfirmedPacket: nil, git: GitSnapshot(), baseSeq: 999))
        let input = GeminiAssistInputBuilder.build(thread: thread, project: project, events: events,
                                                   runs: [], previousPacket: nil, rulePacket: rule,
                                                   git: GitSnapshot())
        await t.check("입력이 상한 근처", input.utf8.count > GeminiAssistInputBuilder.maxInputBytes - 5_000,
                      "\(input.utf8.count)B")
        let started = Date()
        do {
            let response = try await service.summarize(prompt: input, model: model)
            let validated = GeminiAssistValidator.validate(response.summary, events: events)
            await t.check("맨 끝 사용자 지시를 다음 행동으로 읽음",
                          validated.summary.nextActions.contains { $0.text.contains("파란고래") && $0.evidence.contains(999) },
                          validated.summary.nextActions.map(\.text).joined(separator: " | "))
            await t.check("입력 토큰 기록", response.usage.inputTokens > 0,
                          "입력 \(response.usage.inputTokens) · \(Int(Date().timeIntervalSince(started)))초")
        } catch {
            await t.check("상한 크기 요약 예외 없음", false, "\(error.localizedDescription)")
        }
    }

    static func live(_ t: TestKit) async {
        await t.group("Gemini 실제 CLI")
        let environment = CLIEnvironment()
        let service = GeminiAssistService(environment: environment)
        let status = await service.status()
        await t.check("agy 실행 가능", status.path != nil, status.error ?? status.path ?? "")
        guard status.path != nil else { return }
        let models = await service.models()
        await t.check("agy 모델 목록 조회", !models.isEmpty, models.joined(separator: ", "))
        let model = models.first(where: { $0.hasPrefix("gemini-") && $0.contains("flash-low") })
            ?? models.first(where: { $0.hasPrefix("gemini-") })
        do {
            let response = try await service.summarize(prompt: """
                도구를 쓰지 말고 아래 한 줄만 근거로 구조화 요약을 작성하세요.
                [1] userMessage · 사용자: 다음 행동은 검증 테스트 실행입니다.
                progress, decisions, failedAttempts, cautions, unverified는 빈 배열로 두고,
                nextActions에는 text를 '검증 테스트 실행', evidence를 [1]로 넣으세요.
                """, model: model)
            await t.equal("실제 구조화 요약", response.summary.nextActions.first?.text ?? "",
                          "검증 테스트 실행")
            await t.check("실제 호출 사용량 기록", response.usage.totalTokens > 0)
        } catch {
            await t.check("실제 구조화 요약 예외 없음", false, "\(error)")
        }
    }
}
