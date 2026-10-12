import Foundation

/// CLI 를 호출하지 않는 반복 가능한 테스트.
/// 비식별화한 fixture 로 오류 판정과 사용량 집계를 검증한다.
enum OfflineTests {

    static func run(_ t: TestKit) async {
        // 절마다 따로 둔 함수다 — 비동기 함수 하나에 await 가 수백 개면 LLVM 의 코루틴 나누기가 메모리를 수십 GB 쓴다
        // (2026-10-05 실측: 한 함수였을 때 이 파일의 컴파일러 하나가 23초 만에 7GB, 그대로 두면 20GB · 스왑).
        await streamFraming(t)
        await stateTransitions(t)
        await claudeResults(t)
        await codexUsage(t)
        await limitParsing(t)
        await limitChipText(t)
        await gitStatusParsing(t)
        await costCalculation(t)
        await errorClassification(t)
        await storageLayer(t)
        await attachmentRemovalRules(t)
        await attachmentCleanupApp(t)
        await notificationRedaction(t)
        await handoffPacket(t)
        await modelCatalogParsing(t)
        await handoffDeliveryState(t)
        await codexAccounts(t)
        await codexAccountRead(t)
        await codexAccountReadWithLimits(t)
        await perAccountSessions(t)
        await packetCompatibility(t)
        await shellEnvironment(t)
        await shellAuthForwarding(t)
        await pathHelpers(t)
    }

    /// 지원하는 모든 인증 변수에 같은 설정이 적용되는지, 셸 조회와 상속 환경 양쪽을 검증한다.
    private static func shellAuthForwarding(_ t: TestKit) async {
        await t.group("셸 인증 전달 설정")
        let keys = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
                    "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_CLOUD_API_KEY"]
        let credentials = Dictionary(uniqueKeysWithValues: keys.map { ($0, "fixture-" + $0) })
        var supplied = credentials
        supplied["HTTPS_PROXY"] = "http://proxy.invalid:8080"
        supplied["ANTHROPIC_BASE_URL"] = "https://endpoint.invalid"
        supplied["CLAUDE_CODE_USE_BEDROCK"] = "1"
        supplied["AWS_PROFILE"] = "example"
        let inherited = CLIEnvironment.withholdingAuth(supplied, forwards: false)
        await t.check("물려받은 인증 변수도 모두 차단", keys.allSatisfy { inherited[$0] == nil })
        await t.equal("켜면 물려받은 환경 보존", CLIEnvironment.withholdingAuth(supplied, forwards: true), supplied)
        let shellValues = supplied
        let environment = CLIEnvironment()
        await environment.setShellEnvironmentProber {
            CLIEnvironment.ShellEnvironment(all: shellValues, source: .interactive)
        }
        let detected = await environment.shellAuthVariables()
        await t.check("설정 안내도 모든 인증 변수 발견", Set(keys).isSubset(of: Set(detected)))
        let blocked = await environment.childEnvironment()
        await t.check("기본값은 모든 셸 인증 변수 차단", keys.allSatisfy { blocked[$0] == nil })
        await t.check("프록시 · 엔드포인트 · 클라우드 프로필은 보존",
                      blocked["HTTPS_PROXY"] == supplied["HTTPS_PROXY"] && blocked["ANTHROPIC_BASE_URL"] == supplied["ANTHROPIC_BASE_URL"]
                      && blocked["CLAUDE_CODE_USE_BEDROCK"] == "1" && blocked["AWS_PROFILE"] == "example")
        await environment.setForwardsShellAuth(true)
        let allowed = await environment.childEnvironment()
        await t.check("켜면 모든 셸 인증 변수 전달", keys.allSatisfy { allowed[$0] == credentials[$0] })
        await environment.setForwardsShellAuth(false)
        let disabledAgain = await environment.childEnvironment()
        await t.check("다시 끄면 캐시된 인증도 차단", keys.allSatisfy { disabledAgain[$0] == nil })
    }

    // MARK: 스트림 프레이밍

    private static func streamFraming(_ t: TestKit) async {
        await t.group("스트림 프레이밍")
        do {
            var framer = LineFramer()
            // 한 청크에 여러 줄
            let a = framer.append(Data("{\"a\":1}\n{\"b\":2}\n".utf8))
            await t.equal("한 청크의 여러 줄 분리", a.count, 2)

            // 한 줄이 여러 청크에 걸침
            var f2 = LineFramer()
            _ = f2.append(Data("{\"long\":\"AAA".utf8))
            let mid = f2.append(Data("BBB\"}".utf8))
            await t.check("경계 없는 청크는 줄을 만들지 않음", mid.isEmpty)
            let done = f2.append(Data("\n".utf8))
            await t.equal("이어진 줄이 하나로 완성됨", done.first ?? "", "{\"long\":\"AAABBB\"}")

            // \r\n 처리
            var f3 = LineFramer()
            let crlf = f3.append(Data("hello\r\n".utf8))
            await t.equal("CRLF 처리", crlf.first ?? "", "hello")

            // 빈 줄도 줄이다. 사람이 읽는 출력에서 문단이 사라지면 안 된다 (커밋 메시지·명령 출력).
            var blankFramer = LineFramer()
            await t.equal("빈 줄 보존", blankFramer.append(Data("제목\n\n본문\n".utf8)),
                          ["제목", "", "본문"])

            // 개행 없이 끝난 마지막 줄
            var f4 = LineFramer()
            _ = f4.append(Data("tail-without-newline".utf8))
            await t.equal("flush 로 마지막 줄 회수", f4.flush() ?? "", "tail-without-newline")

            // UTF-8 멀티바이트가 청크 경계에서 쪼개짐
            var f5 = LineFramer()
            let korean = Array("한글".utf8)
            _ = f5.append(Data(korean[0..<4]))
            let rest = f5.append(Data(korean[4...] + Array("\n".utf8)))
            await t.equal("UTF-8 경계 분할 복원", rest.first ?? "", "한글")
        }
    }

    // MARK: 상태 전이

    private static func stateTransitions(_ t: TestKit) async {
        await t.group("실행 상태 전이")
        await t.check("시작 중 → 중단 중 허용 (중단 요청 유실 방지)",
                      RunState.starting.canTransition(to: .interrupting))
        await t.check("중단 중 → 사용자 취소 허용",
                      RunState.interrupting.canTransition(to: .cancelled))
        await t.check("완료 → 실행 중 금지",
                      !RunState.completed.canTransition(to: .running))
        await t.check("대기 → 실행 중 금지 (시작 중 경유 필요)",
                      !RunState.idle.canTransition(to: .running))
        await t.check("인계 전송 중 → 전달 여부 미확인 허용",
                      RunState.handoffSending.canTransition(to: .handoffDeliveryUnknown))
        await t.check("사용자 취소는 종료 상태", RunState.cancelled.isTerminal)
        await t.check("승인 대기는 활성 상태", RunState.awaitingApproval.isActive)
    }

    // MARK: Claude result 판정 (실측 fixture 기반)

    private static func claudeResults(_ t: TestKit) async {
        await t.group("Claude 결과 판정")
        do {
            // 1) 정상 완료 + modelUsage
            let success: [String: Any] = [
                "type": "result", "subtype": "success", "is_error": false,
                "terminal_reason": "completed", "result": "ACK HANDOFF-4827",
                "duration_ms": 1489, "session_id": "48274827-4827-4827-8827-482748274827",
                "modelUsage": ["claude-opus-5": [
                    "inputTokens": 2, "outputTokens": 14, "cacheReadInputTokens": 0,
                    "cacheCreationInputTokens": 3450, "thinkingTokens": 0,
                    "costUSD": 0.03486,
                ] as [String: Any]],
                "permission_denials": [],
            ]
            let r1 = ClaudeAdapter.interpretResult(success, userCancelled: false,
                                                   fallbackModel: nil, startedAt: Date())
            await t.equal("정상 완료 상태", r1.result.state, RunState.completed)
            await t.equal("모델 인식", r1.result.model ?? "", "claude-opus-5")
            await t.equal("입력 토큰(캐시 제외)", r1.result.usage?.inputTokens ?? -1, 2)
            await t.equal("캐시 생성 토큰", r1.result.usage?.cacheWriteTokens ?? -1, 3450)
            await t.equal("CLI 보고 비용", r1.result.usage?.reportedCostUSD ?? 0, 0.03486)
            await t.check("정상 완료는 사용량 확정", r1.result.usage?.confirmed == true)

            // 2) 사용자 중단: is_error=true 이지만 모델 실패가 아니다
            let aborted: [String: Any] = [
                "type": "result", "subtype": "error_during_execution", "is_error": true,
                "terminal_reason": "aborted_streaming", "num_turns": 2,
                "usage": ["input_tokens": 0, "output_tokens": 0,
                          "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0],
            ]
            let r2 = ClaudeAdapter.interpretResult(aborted, userCancelled: false,
                                                   fallbackModel: "claude-opus-5",
                                                   startedAt: Date())
            await t.equal("중단은 사용자 취소로 집계", r2.result.state, RunState.cancelled)
            await t.check("중단은 오류로 표시하지 않음", !r2.result.isError)
            await t.check("중단 사용량 0 은 미확정 처리", r2.result.usage?.confirmed == false)

            // 3) subtype=success 인데 인증 실패
            let authFail: [String: Any] = [
                "type": "result", "subtype": "success", "is_error": false,
                "terminal_reason": "completed",
                "result": "Error: Not logged in. Please run `claude` to authenticate.",
            ]
            let r3 = ClaudeAdapter.interpretResult(authFail, userCancelled: false,
                                                   fallbackModel: nil, startedAt: Date())
            await t.equal("subtype=success 라도 인증 실패는 오류", r3.result.state, RunState.failed)
            await t.equal("인증 문제로 분류", r3.result.limitStatus ?? .ok, LimitStatus.authProblem)

            // 3-2) OAuth 만료 (2.1.233 실측 결과 줄). "authentication" 이 아니라 "authenticate" 로 온다.
            let oauthExpired: [String: Any] = [
                "type": "result", "subtype": "success", "is_error": true,
                "terminal_reason": "api_error", "num_turns": 1,
                "result": "Failed to authenticate: OAuth session expired and could not be refreshed",
            ]
            let r3b = ClaudeAdapter.interpretResult(oauthExpired, userCancelled: false,
                                                    fallbackModel: nil, startedAt: Date())
            await t.equal("OAuth 만료는 오류", r3b.result.state, RunState.failed)
            await t.equal("OAuth 만료는 인증 문제로 분류", r3b.result.limitStatus ?? .ok, LimitStatus.authProblem)

            // 3-3) 모델이 쓴 성공 답이 로그인 · 401 · 한도 · error 를 이야기해도 실패가 아니다
            //      (로그인 화면 · 오류 처리 작업의 흔한 답. 실패로 보면 대기열이 멈추고 자동 인계가 시작된다)
            // 실측 result 줄의 모양: 턴별 `usage` + 프로세스 누적 `modelUsage` (usage 가 없는 옛 모양도 본다).
            let modelUsage: [String: Any] = ["claude-opus-5-5": [
                "inputTokens": 40, "outputTokens": 507, "costUSD": 0.03,
            ] as [String: Any]]
            let turnUsage: [String: Any] = ["input_tokens": 12, "output_tokens": 180]
            for text in ["LoginView.swift 의 error 문구를 같은 말투로 고쳤습니다.",
                         "AuthViewModel 에서 401 응답을 받으면 error 를 보여 주도록 바꿨습니다.",
                         "API 요청 한도를 넘으면 error 배너를 띄우도록 했습니다.",
                         "Error: Not logged in 문구를 로그인 화면의 안내로 바꿨습니다."] {
                for withTurnUsage in [true, false] {
                    var ok: [String: Any] = [
                        "type": "result", "subtype": "success", "is_error": false,
                        "terminal_reason": "completed", "result": text, "modelUsage": modelUsage,
                    ]
                    if withTurnUsage { ok["usage"] = turnUsage }
                    let r = ClaudeAdapter.interpretResult(ok, userCancelled: false,
                                                          fallbackModel: nil, startedAt: Date())
                    let shape = withTurnUsage ? "턴 usage" : "modelUsage 만"
                    await t.equal("모델이 쓴 답은 완료(\(shape)): \(text.prefix(24))…", r.result.state, RunState.completed)
                    await t.check("모델이 쓴 답에 한도 · 인증 표시 없음(\(shape))", r.result.limitStatus == nil)
                }
            }

            // 3-4) 모델을 부르지 않은 CLI 문구는 "error" 가 없어도 실패로 본다
            let invalidKey: [String: Any] = [
                "type": "result", "subtype": "success", "is_error": false,
                "terminal_reason": "completed", "result": "Invalid API key · Please run /login",
            ]
            let r3d = ClaudeAdapter.interpretResult(invalidKey, userCancelled: false,
                                                    fallbackModel: nil, startedAt: Date())
            await t.equal("출력 없는 로그인 안내는 오류", r3d.result.state, RunState.failed)
            // 후속 턴: modelUsage 는 프로세스 누적(앞 턴의 출력이 있다)이지만 이 턴의 usage 는 출력 0 — 턴별 값으로 본다
            var followUp = invalidKey
            followUp["modelUsage"] = modelUsage
            followUp["usage"] = ["input_tokens": 0, "output_tokens": 0]
            let r3f = ClaudeAdapter.interpretResult(followUp, userCancelled: false,
                                                    fallbackModel: nil, startedAt: Date())
            await t.equal("후속 턴의 로그인 안내도 오류 (누적 출력에 속지 않음)", r3f.result.state, RunState.failed)
            let cappedSuccess: [String: Any] = [
                "type": "result", "subtype": "success", "is_error": false,
                "terminal_reason": "completed", "result": "Claude AI usage limit reached|1790740800",
            ]
            let r3e = ClaudeAdapter.interpretResult(cappedSuccess, userCancelled: false,
                                                    fallbackModel: nil, startedAt: Date())
            await t.equal("출력 없는 한도 문구는 사용 제한", r3e.result.state, RunState.rateLimited)

            // 4) 승인 거절 기록 (파일 미생성)
            let denied: [String: Any] = [
                "type": "result", "subtype": "success", "is_error": false,
                "terminal_reason": "completed",
                "result": "Permission denied — the Write was declined, so the file was not created.",
                "permission_denials": [["tool_name": "Write",
                                        "tool_use_id": "toolu_01Fixture000000000000900"]],
            ]
            let r4 = ClaudeAdapter.interpretResult(denied, userCancelled: false,
                                                   fallbackModel: nil, startedAt: Date())
            await t.equal("승인 거절 후 정상 종료", r4.result.state, RunState.completed)
            await t.check("거절 도구가 안내로 기록됨",
                          r4.notices.contains { $0.contains("Write") })

            // 5) 구독 한도 도달
            let capped: [String: Any] = [
                "type": "result", "subtype": "error_during_execution", "is_error": true,
                "result": "Claude usage limit reached. Your limit will reset at 5pm.",
            ]
            let r5 = ClaudeAdapter.interpretResult(capped, userCancelled: false,
                                                   fallbackModel: nil, startedAt: Date())
            await t.equal("한도 도달은 사용 제한 상태", r5.result.state, RunState.rateLimited)

            // 6) 토큰 값이 소수(2.0)로 와도 0 으로 떨어지지 않아야 한다
            let floatUsage: [String: Any] = [
                "type": "result", "subtype": "success", "is_error": false,
                "modelUsage": ["claude-opus-5": [
                    "inputTokens": 2.0, "outputTokens": 14.0,
                    "cacheCreationInputTokens": 3450.0, "costUSD": 0.03486,
                ] as [String: Any]],
            ]
            let rf = ClaudeAdapter.interpretResult(floatUsage, userCancelled: false,
                                                   fallbackModel: nil, startedAt: Date())
            await t.equal("소수 형태 토큰도 정확히 읽음", rf.result.usage?.inputTokens ?? -1, 2)
            await t.equal("소수 형태 캐시 토큰도 정확히 읽음",
                          rf.result.usage?.cacheWriteTokens ?? -1, 3450)

            // 7) 사용자가 중단을 요청한 경우 (userCancelled 플래그)
            let r6 = ClaudeAdapter.interpretResult(success, userCancelled: true,
                                                   fallbackModel: nil, startedAt: Date())
            await t.equal("사용자 취소 플래그 우선", r6.result.state, RunState.cancelled)
        }
    }

    // MARK: Codex 사용량 누적 (실측 fixture 값)

    private static func codexUsage(_ t: TestKit) async {
        await t.group("Codex 사용량 집계")
        do {
            func usageEvent(total: Int, last: [String: Int]) -> [String: Any] {
                ["tokenUsage": ["total": ["totalTokens": total], "last": last]]
            }
            var acc = CodexUsageAccumulator()
            // 실측: total 21314 → 44986 → 68854 → 92824, last 합계 = 71510 (2번째 턴)
            acc.apply(usageEvent(total: 21314, last: ["totalTokens": 21314, "inputTokens": 21305,
                                                      "cachedInputTokens": 18304,
                                                      "cacheWriteInputTokens": 0,
                                                      "outputTokens": 9,
                                                      "reasoningOutputTokens": 0]))
            await t.equal("순수 입력 = 입력 − 캐시", acc.usage.inputTokens, 21305 - 18304)
            await t.equal("캐시 읽기 분리", acc.usage.cacheReadTokens, 18304)
            await t.equal("출력", acc.usage.outputTokens, 9)

            // 동일 이벤트 재수신 → 중복 합산 금지
            acc.apply(usageEvent(total: 21314, last: ["totalTokens": 21314, "inputTokens": 21305,
                                                      "cachedInputTokens": 18304,
                                                      "outputTokens": 9]))
            await t.equal("중복 이벤트는 합산하지 않음", acc.usage.outputTokens, 9)

            var acc2 = CodexUsageAccumulator()
            for (total, last) in [(44986, 23672), (68854, 23868), (92824, 23970)] {
                acc2.apply(usageEvent(total: total,
                                      last: ["totalTokens": last, "inputTokens": last - 10,
                                             "cachedInputTokens": 0, "outputTokens": 10]))
            }
            await t.equal("턴 내 last 합계 = total 증가분",
                          acc2.usage.inputTokens + acc2.usage.outputTokens,
                          23672 + 23868 + 23970)

            // 중단 턴: total 이 증가하지 않음 → 0 이지만 미확정
            var acc3 = CodexUsageAccumulator(lastSeenTotalTokens: 92824)
            acc3.apply(usageEvent(total: 92824, last: ["totalTokens": 23970]))
            await t.check("중단 턴은 사용량 관찰 없음", !acc3.sawAnyUsage)

            let interrupted = CodexAdapter.interpretTurnCompleted(
                turn: ["status": "interrupted", "durationMs": 3344], usage: acc3.usage,
                model: "gpt-6-astra", threadID: "tid", accumulatedText: "",
                userCancelled: true, sawAnyUsage: acc3.sawAnyUsage, startedAt: Date())
            await t.equal("Codex 중단은 사용자 취소", interrupted.state, RunState.cancelled)
            await t.check("중단 사용량은 미확정", interrupted.usage?.confirmed == false)
            await t.check("중단은 오류로 집계하지 않음", !interrupted.isError)

            let completed = CodexAdapter.interpretTurnCompleted(
                turn: ["status": "completed", "durationMs": 4417], usage: acc2.usage,
                model: "gpt-6-astra", threadID: "tid", accumulatedText: "CODEX ACK",
                userCancelled: false, sawAnyUsage: true, startedAt: Date())
            await t.equal("Codex 정상 완료", completed.state, RunState.completed)
            await t.check("정상 완료는 사용량 확정", completed.usage?.confirmed == true)

            let failed = CodexAdapter.interpretTurnCompleted(
                turn: ["status": "failed",
                       "error": ["message": "429 too many requests"]],
                usage: TurnUsage(), model: nil, threadID: "tid", accumulatedText: "",
                userCancelled: false, sawAnyUsage: false, startedAt: Date())
            await t.equal("Codex 실패는 오류 상태", failed.state, RunState.failed)
            await t.equal("일시적 요청 제한 분류", failed.limitStatus ?? .ok, LimitStatus.throttled)
        }
    }

    // MARK: 한도 파싱

    private static func limitParsing(_ t: TestKit) async {
        await t.group("한도 파싱")
        do {
            let realText = """
            You are currently using your subscription to power your Claude Code usage

            Current session: 28% used · resets Sep 9 at 5:10pm (Asia/Seoul)
            Current week (all models): 76% used · resets Sep 11 at 10am (Asia/Seoul)

            What's contributing to your limits usage?
            """
            let parsed = LimitsFetcher.parseClaudeUsageText(
                realText, into: LimitSnapshot(provider: .claude))
            await t.equal("Claude 한도 구간 2개", parsed.windows.count, 2)
            await t.equal("세션 사용률", parsed.windows.first?.utilization ?? -1, 0.28)
            await t.equal("주간 사용률", parsed.windows.last?.utilization ?? -1, 0.76)
            await t.equal("정상 상태", parsed.status, LimitStatus.ok)
            await t.check("초기화 원문 보존",
                          parsed.windows.first?.rawText?.contains("resets") ?? false)

            // Fable 모델 한도가 붙은 형식 (2026-09-22 실측 줄 형식)
            let fableRealText = """
            You are currently using your subscription to power your Claude Code usage

            Current session: 100% used · resets Sep 22 at 6:40pm (Asia/Seoul)
            Current week (all models): 56% used · resets Sep 25 at 10am (Asia/Seoul)
            Current week (Fable): 76% used · resets Sep 25 at 10am (Asia/Seoul)

            What's contributing to your limits usage?
            """
            let fableParsed = LimitsFetcher.parseClaudeUsageText(
                fableRealText, into: LimitSnapshot(provider: .claude))
            await t.equal("Claude Fable 포함 한도 구간 3개", fableParsed.windows.count, 3)
            await t.equal("세션 사용률", fableParsed.windows[0].utilization ?? -1, 1.0)
            await t.equal("주간 전체 사용률", fableParsed.windows[1].utilization ?? -1, 0.56)
            await t.equal("Fable 주간 사용률", fableParsed.windows[2].utilization ?? -1, 0.76)
            await t.equal("Fable 라벨", fableParsed.windows[2].label, "이번 주 (Fable)")
            await t.equal("Fable 구간은 모델 한도", fableParsed.windows[2].model ?? "", "Fable")
            await t.check("세션 · 주간 전체는 계정 한도",
                          fableParsed.windows[0].model == nil && fableParsed.windows[1].model == nil)
            await t.equal("세션 100% 시 한도 도달 판정", fableParsed.status, LimitStatus.subscriptionCap)

            // Fable 만 다 차면 Claude 전체는 한도 도달이 아니다 — 다른 모델은 쓸 수 있다.
            // Fable 줄이 먼저 와도 "이번 주"로 읽지 않는다.
            let fableFull = LimitsFetcher.parseClaudeUsageText("""
                Current session: 12% used · resets Sep 22 at 6:40pm (Asia/Seoul)
                Current week (Fable): 100% used · resets Sep 25 at 10am (Asia/Seoul)
                Current week (all models): 56% used · resets Sep 25 at 10am (Asia/Seoul)
                """, into: LimitSnapshot(provider: .claude))
            await t.equal("Fable 100% 만으로는 정상", fableFull.status, LimitStatus.ok)
            await t.equal("Fable 줄이 먼저여도 주간 전체는 56%",
                          fableFull.windows.first { $0.label == "이번 주" }?.utilization ?? -1, 0.56)
            await t.check("Fable 100% 만으로는 계정 한도 도달 아님", !fableFull.reachedAccountWideCap)
            await t.equal("Fable 100% 만으로는 인계 대상에서 빼지 않음",
                          AutomaticHandoffGate.targetProblems(cliUsable: true, authenticated: true,
                                                              limit: fableFull), [])
            await t.check("세션 100% 면 인계 대상에서 뺌",
                          !AutomaticHandoffGate.targetProblems(cliUsable: true, authenticated: true,
                                                               limit: fableParsed).isEmpty)

            // Fable 한도 오류 메시지 분류 (문구는 추정 — 실제 오류는 아직 관찰하지 못했다)
            await t.equal("Fable 한도 오류 분류",
                          ErrorClassifier.classify("You've reached your Fable limit."),
                          LimitStatus.subscriptionCap)

            // 형식 변경 → 0% 가 아니라 정보 없음
            let changed = LimitsFetcher.parseClaudeUsageText(
                "Usage this period: 42 of 100 credits consumed.",
                into: LimitSnapshot(provider: .claude))
            await t.equal("형식 변경 시 정보 없음", changed.status, LimitStatus.noData)
            await t.check("형식 변경 시 0% 로 표시하지 않음", changed.windows.isEmpty)
            await t.check("형식 변경 시 원문 보존", changed.rawResponse != nil)

            // subtype=success 인데 인증 실패인 /usage 응답
            let authJSON = """
            {"is_error": false, "subtype": "success",
             "result": "Error: not logged in. Run `claude` to authenticate."}
            """
            let authSnap = LimitsFetcher.parseClaudeUsageResponse(
                authJSON, into: LimitSnapshot(provider: .claude))
            await t.equal("인증 실패 분류", authSnap.status, LimitStatus.authProblem)

            // Codex 실측 fixture
            let codexRL: [String: Any] = [
                "limitId": "codex",
                "primary": ["usedPercent": 8, "windowDurationMins": 300, "resetsAt": 1788947109],
                "secondary": ["usedPercent": 49, "windowDurationMins": 10080,
                              "resetsAt": 1789447729],
                "planType": "plus", "rateLimitReachedType": NSNull(),
            ]
            let codexSnap = CodexAdapter.parseRateLimits(codexRL)
            await t.equal("Codex 구간 2개", codexSnap.windows.count, 2)
            await t.equal("Codex 1차 사용률", codexSnap.windows.first?.utilization ?? -1, 0.08)
            await t.equal("Codex 구간 라벨(5시간)", codexSnap.windows.first?.label ?? "", "5시간")
            await t.equal("Codex 구간 라벨(7일)", codexSnap.windows.last?.label ?? "", "7일")
            await t.equal("Codex 플랜", codexSnap.planType ?? "", "plus")

            let capped = CodexAdapter.parseRateLimits(["rateLimitReachedType": "primary"])
            await t.equal("한도 도달 표시", capped.status, LimitStatus.subscriptionCap)

            let empty = CodexAdapter.parseRateLimits(["something": "else"])
            await t.equal("값 없으면 정보 없음", empty.status, LimitStatus.noData)
            await t.check("값 없을 때 0% 로 표시하지 않음",
                          !empty.windows.contains { $0.utilization != nil })
        }
    }

    // MARK: 한도 칩 글 (H12 · nav-16 · cap-18 · onb-17)

    private static func limitChipText(_ t: TestKit) async {
        await t.group("한도 칩 글: 확인 전과 실패를 가른다 · % · 창 이름")
        await limitsPresentation(t)
        await limitsCapChip(t)
        await menuBarLimits(t)
    }

    /// 메뉴바에 보일 한도 (설정 > 일반 > 메뉴바): 숨긴 계정 · 구간만 빼고, 새 계정 · 구간은 보인다.
    @MainActor
    static func menuBarLimits(_ t: TestKit) async {
        await t.group("메뉴바 한도 고르기: 숨긴 계정 · 구간만 뺀다")
        typealias P = LimitsPresentation
        typealias M = MenuBarLimits
        var claudeSnapshot = LimitSnapshot(provider: .claude)
        claudeSnapshot.status = .ok
        claudeSnapshot.fetchedAt = Date()
        claudeSnapshot.windows = [LimitWindow(label: "현재 세션", utilization: 0.16, spanMinutes: 300),
                                  LimitWindow(label: "이번 주", utilization: 0.37, spanMinutes: 10080),
                                  LimitWindow(label: "이번 주 (Fable)", utilization: 0, model: "Fable", spanMinutes: 10080)]
        var codexSnapshot = LimitSnapshot(provider: .codex, accountID: "a2")
        codexSnapshot.status = .ok
        codexSnapshot.fetchedAt = Date()
        codexSnapshot.windows = [LimitWindow(label: "5시간", utilization: 0, spanMinutes: 300),
                                 LimitWindow(label: "7일", utilization: 0.22, spanMinutes: 10080)]
        let pending = LimitSnapshot(provider: .gemini)   // 아직 읽지 않음 — 구간이 없다
        let claude = P.Entry(snapshot: claudeSnapshot, name: "Claude", accountLabel: nil, state: P.state(claudeSnapshot))
        let codex = P.Entry(snapshot: codexSnapshot, name: "Codex · 계정 2", accountLabel: "계정 2", state: P.state(codexSnapshot))
        let agy = P.Entry(snapshot: pending, name: "Antigravity", accountLabel: nil, state: P.state(pending))
        let entries = [claude, codex, agy]

        await t.equal("키: 계정 · 구간", [M.entryKey(codex), M.windowKey(claude, claudeSnapshot.windows[1])],
                      ["codex|a2", "claude||이번 주"])
        let all = M.visible(entries, hidden: [])
        await t.check("숨긴 것이 없으면 전부 그대로",
                      all.map(\.id) == entries.map(\.id) && all[0].windows.count == 3 && M.hiddenCount(entries, hidden: []) == 0)

        let hidden: Set<String> = [M.windowKey(claude, claudeSnapshot.windows[2]), M.entryKey(codex)]
        let rows = M.visible(entries, hidden: hidden)
        await t.equal("숨긴 계정은 빠지고 구간이 없는 계정은 남는다", rows.map(\.id), [claude.id, agy.id])
        await t.equal("숨긴 구간만 빠진다", rows.first?.windows.map(\.label) ?? [], ["현재 세션", "이번 주"])
        await t.equal("숨긴 수 — 계정은 하나로", M.hiddenCount(entries, hidden: hidden), 2)
        await t.check("숨긴 수를 단추에 적는다", M.settingsTitle(hiddenCount: 2).contains("숨김 2개")
                      && !M.settingsTitle(hiddenCount: 0).contains("숨김"))

        let everyCodexWindow = Set(codexSnapshot.windows.map { M.windowKey(codex, $0) })
        await t.check("구간을 모두 숨긴 계정은 머리째 뺀다",
                      !M.visible(entries, hidden: everyCodexWindow).contains { $0.id == codex.id })
        await t.check("지금 없는 구간의 키는 세지 않는다 (예전 구간 이름)",
                      M.hiddenCount(entries, hidden: ["claude||5시간"]) == 0)

        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-menubar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
        try? await store.bootstrap()
        let model = AppModel(store: store)
        model.setMenuBarLimit("claude|", shown: false)
        model.setMenuBarLimit("codex|a2|7일", shown: false)
        model.setMenuBarLimit("claude|", shown: true)
        await t.equal("앱 모델: 끄고 켜면 숨긴 것만 남는다", model.menuBarHiddenLimits, ["codex|a2|7일"])
        await model.store.db.close()
    }

    /// 주간 한도가 다 찬 계정의 칩 (chr-6): 5시간 창의 낮은 수를 보통 색으로 보이지 않고, 다 찬 창 · 경고 기호 · "한도 도달 · 초기화" 를.
    static func limitsCapChip(_ t: TestKit) async {
        await t.group("한도 칩: 주간 한도가 다 찼으면 그 창을 · 경고 기호와 함께")
        typealias P = LimitsPresentation
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(5 * 3600)
        var weekly = LimitSnapshot(provider: .claude)
        weekly.status = .subscriptionCap   // /usage 해석: 계정 전체 창이 다 차면 한도 도달
        weekly.fetchedAt = now
        weekly.windows = [LimitWindow(label: "현재 세션", utilization: 0.12, resetsAt: now.addingTimeInterval(3600), spanMinutes: 300),
                          LimitWindow(label: "이번 주", utilization: 1.0, resetsAt: reset, spanMinutes: 10080)]
        let state = P.state(weekly, now: now)
        await t.equal("다 찬 계정 전체 창(이번 주)을 칩에 — 현재 세션의 12% 가 아니라", P.chipText(state), "100%")
        await t.check("한도 도달이면 값이 있어도 경고 기호", P.chipWarns(state, snapshot: weekly, now: now))
        let line = P.line(name: "Claude", state: state, fetchedAt: weekly.fetchedAt, status: weekly.status, now: now)
        await t.check("도움말: 이번 주 한도 도달 · 초기화 시각", line.hasPrefix("Claude · 이번 주 한도 도달 · ")
                        && line.contains(HandoffCardText.resetClock(reset, now: now) + " 초기화"), line)

        // 모델 하나의 한도(Fable)가 찬 것은 계정 전체 한도가 아니다 — 칩은 그대로 첫 창, 경고 없음.
        var fable = LimitSnapshot(provider: .claude)
        fable.status = .ok
        fable.fetchedAt = now
        fable.windows = [LimitWindow(label: "현재 세션", utilization: 0.12, spanMinutes: 300),
                         LimitWindow(label: "이번 주 (Fable)", utilization: 1.0, model: "Fable", spanMinutes: 10080)]
        let fableState = P.state(fable, now: now)
        await t.check("모델 하나의 한도가 찬 것은 칩을 바꾸지 않는다 (12% · 경고 없음)",
                      P.chipText(fableState) == "12%" && !P.chipWarns(fableState, snapshot: fable, now: now))
        // 초기화 시각이 지난 다 찬 창은 이미 풀렸다.
        var released = weekly
        released.windows[1].resetsAt = now.addingTimeInterval(-60)
        released.status = .ok
        await t.equal("초기화 시각이 지난 창은 다 찬 창으로 보지 않는다", P.chipText(P.state(released, now: now)), "12%")
        // 창은 덜 찼는데 CLI 가 한도 도달을 알렸다 (rate_limit_event 의 status) — 수는 그대로 · 경고 기호 · 도움말에 상태.
        var rejected = LimitSnapshot(provider: .claude)
        rejected.status = .subscriptionCap
        rejected.fetchedAt = now
        rejected.windows = [LimitWindow(label: "5시간", utilization: 0.98, spanMinutes: 300)]
        let rejectedState = P.state(rejected, now: now)
        let rejectedLine = P.line(name: "Claude", state: rejectedState, fetchedAt: nil, status: rejected.status, now: now)
        await t.check("창이 덜 차도 CLI 가 한도 도달을 알리면 경고 기호 · 도움말에 상태 이름",
                      P.chipWarns(rejectedState, snapshot: rejected, now: now) && rejectedLine.contains(LimitStatus.subscriptionCap.koreanName),
                      rejectedLine)
        var normal = rejected
        normal.status = .ok
        await t.check("한도에 닿지 않았으면 경고 기호 없음", !P.chipWarns(P.state(normal, now: now), snapshot: normal, now: now))
    }

    // MARK: Git 상태

    private static func gitStatusParsing(_ t: TestKit) async {
        await t.group("Git 상태 파싱")
        do {
            var snap = GitSnapshot()
            snap.isRepository = true
            let porcelain = """
            M  staged-only.txt
             M unstaged-only.txt
            MM both.txt
            A  added.txt
            ?? untracked.txt
            R  old.txt -> new.txt
            D  deleted.txt
            """
            GitInspector.parsePorcelain(porcelain, into: &snap, limit: 100)
            await t.check("staged 인식", snap.staged.contains { $0.contains("staged-only.txt") })
            await t.check("unstaged 인식", snap.unstaged.contains { $0.contains("unstaged-only.txt") })
            await t.check("both 는 양쪽 모두", snap.staged.contains { $0.contains("both.txt") }
                          && snap.unstaged.contains { $0.contains("both.txt") })
            await t.check("untracked 인식", snap.untracked.contains("untracked.txt"))
            await t.check("이름 변경은 새 경로 사용", snap.staged.contains { $0.contains("new.txt") })
            await t.check("삭제 인식", snap.staged.contains { $0.contains("deleted.txt") })
            await t.check("untracked 는 staged 에 넣지 않음",
                          !snap.staged.contains { $0.contains("untracked.txt") })
        }
    }

    // MARK: 비용 계산

    private static func costCalculation(_ t: TestKit) async {
        await t.group("비용 계산")
        do {
            let calc = CostCalculator(entries: PriceCatalog.seed)
            var u = UsageRecord(runID: "r", threadID: "t", provider: .claude,
                                model: "claude-opus-5",
                                inputTokens: 1_000_000, cacheReadTokens: 1_000_000,
                                cacheWriteTokens: 1_000_000, outputTokens: 1_000_000,
                                reasoningTokens: 500_000)
            let result = calc.calculate(provider: .claude, model: "claude-opus-5", usage: u)
            // 입력 5.00 + 캐시읽기 0.50 + 캐시생성 6.25 + 출력 25.00 = 36.75
            let cost = result?.0 ?? -1
            await t.check("Opus 5 환산 비용", abs(cost - 36.75) < 0.0001,
                          String(format: "%.4f", cost))
            await t.equal("가격표 버전 기록", result?.1 ?? "", PriceCatalog.version)
            await t.equal("추론 토큰은 총합에 중복 합산 안 함", u.totalTokens, 4_000_000)

            // 날짜 접미사 모델도 매칭
            let dated = calc.calculate(provider: .claude, model: "claude-opus-5-20260401", usage: u)
            await t.check("날짜 접미사 모델 접두사 매칭", dated != nil)

            let codex = calc.calculate(provider: .codex, model: "gpt-6-astra", usage: u)
            // 3M 프롬프트라 긴 컨텍스트 배수까지 적용: 입력·캐시 2배, 출력 1.5배 = 122.00
            await t.check("Astra 긴 컨텍스트 환산 비용", abs((codex?.0 ?? -1) - 122.00) < 0.0001)

            // Opus 5.5: 입력 4.00 + 캐시읽기 0.20(0.05배) + 캐시생성 5.00 + 출력 20.00 = 29.20.
            // 접두사가 같은 `claude-opus-5`($5/$25)로 새지 않는다.
            let opus55 = calc.calculate(provider: .claude, model: "claude-opus-5-5", usage: u)
            await t.check("Opus 5.5 환산 비용", abs((opus55?.0 ?? -1) - 29.20) < 0.0001,
                          String(format: "%.4f", opus55?.0 ?? -1))
            // Fable 5.1 캐시 읽기는 0.025배: 10.00 + 0.25 + 12.50 + 50.00 = 72.75.
            let fable51 = calc.calculate(provider: .claude, model: "claude-fable-5-1", usage: u)
            await t.check("Fable 5.1 환산 비용", abs((fable51?.0 ?? -1) - 72.75) < 0.0001,
                          String(format: "%.4f", fable51?.0 ?? -1))

            // GPT-6 Sol · Luna. 3M 프롬프트라 긴 컨텍스트(입력·캐시 2배, 출력 1.5배) — OpenAI 가격표의 긴 컨텍스트 단가와 같다.
            let sol = calc.calculate(provider: .codex, model: "gpt-6-sol", usage: u)
            await t.check("GPT-6 Sol 긴 컨텍스트 환산 비용", abs((sol?.0 ?? -1) - 24.40) < 0.0001,
                          String(format: "%.4f", sol?.0 ?? -1))
            let luna = calc.calculate(provider: .codex, model: "gpt-6-luna", usage: u)
            await t.check("GPT-6 Luna 긴 컨텍스트 환산 비용", abs((luna?.0 ?? -1) - 1.22) < 0.0001,
                          String(format: "%.4f", luna?.0 ?? -1))
            let shortSol = UsageRecord(runID: "s", threadID: "t", provider: .codex, model: "gpt-6-sol",
                                       inputTokens: 100_000, cacheReadTokens: 100_000, outputTokens: 100_000)
            // 0.2 + 0.02 + 1.0 (272K 이하라 배수 없음)
            await t.check("GPT-6 Sol 기본 환산 비용",
                          abs((calc.calculate(provider: .codex, model: "gpt-6-sol", usage: shortSol)?.0 ?? -1) - 1.22) < 0.0001)

            var geminiUsage = UsageRecord(runID: "g", threadID: "t", provider: .gemini,
                                          model: "gemini-3.8-flash-high",
                                          inputTokens: 1_000_000, outputTokens: 1_000_000)
            let gemini = calc.calculate(provider: .gemini, model: geminiUsage.model, usage: geminiUsage)
            await t.check("Antigravity 강도 접미사 가격 매칭",
                          abs((gemini?.0 ?? -1) - 4.50) < 0.0001)

            geminiUsage.model = "gemini-3.1-pro-high"
            geminiUsage.inputTokens = 200_001
            let longGemini = calc.calculate(provider: .gemini, model: geminiUsage.model,
                                             usage: geminiUsage)
            // 긴 컨텍스트 입력 4/M + 출력 18/M.
            await t.check("Gemini Pro 긴 컨텍스트 가격",
                          abs((longGemini?.0 ?? -1) - 18.800004) < 0.0001)

            let unknown = calc.calculate(provider: .gemini, model: "gpt-oss-120b-medium", usage: u)
            await t.check("가격 모르는 모델은 계산하지 않음 (0원 아님)", unknown == nil)

            let custom = PriceEntry(provider: .codex, model: "gpt-6-astra",
                                    inputPerMTok: 1, outputPerMTok: 1,
                                    cacheReadPerMTok: 1, cacheWritePerMTok: 1,
                                    source: "사용자 직접 입력", effectiveDate: "2026-09-12",
                                    catalogVersion: "user-2026-09-12")
            let customCalc = CostCalculator(entries: PriceCatalog.seed + [custom])
            let customUsage = UsageRecord(runID: "c", threadID: "t", provider: .codex,
                                          model: "gpt-6-astra", inputTokens: 100_000)
            await t.check("사용자 가격이 기본 가격보다 우선",
                          abs((customCalc.calculate(provider: .codex, model: "gpt-6-astra",
                                                    usage: customUsage)?.0 ?? -1) - 0.1) < 0.0001)

            u.costUSD = nil
            u.costSource = .unknown
            var known = u
            known.costUSD = 1.5
            known.costSource = .cliReported
            let agg = UsageAggregate.from([u, known])
            await t.equal("합계 비용은 확인된 것만", agg.totalCostUSD, 1.5)
            await t.equal("금액 미확인 턴 수 보고", agg.costUnknownTurns, 1)
            await t.equal("일부 미확인 시 확인된 비용만 표시", agg.displayCostUSD ?? -1, 1.5)
            await t.equal("턴 수", agg.turns, 2)
            await t.check("비용 전부 미확인이면 0원이 아니라 nil",
                          UsageAggregate.from([u]).displayCostUSD == nil)

            var unconfirmed = known
            unconfirmed.confirmed = false
            await t.equal("미확정 턴 수 보고",
                          UsageAggregate.from([unconfirmed]).unconfirmedTurns, 1)

            await t.check("인계 텍스트 토큰 추정은 별도 값",
                          CostCalculator.roughTokenEstimate(String(repeating: "가", count: 300)) > 0)

            // set-18: 직접 넣는 가격 — 소수점 쉼표 · 앞의 $ 를 받고, 못 받는 값은 [추가]를 끄는 까닭으로.
            await t.equal("가격 칸: 1.25", PriceCatalog.parsePrice("1.25"), 1.25)
            await t.equal("가격 칸: 소수점 쉼표 1,25", PriceCatalog.parsePrice(" 1,25 "), 1.25)
            await t.equal("가격 칸: 앞의 $", PriceCatalog.parsePrice("$3"), 3.0)
            let rejected: [String] = ["-1", "abc", "", "1,000,5"]
            let rejectedParsed: [Double?] = rejected.map { (text: String) -> Double? in PriceCatalog.parsePrice(text) }
            await t.check("가격 칸: 음수 · 글 · 빈 칸 · 쉼표 둘은 받지 않는다",
                          rejectedParsed.allSatisfy { (value: Double?) -> Bool in value == nil })
            await t.equal("모델 이름이 없으면 그 까닭", PriceCatalog.userEntryProblem(model: " ", input: "1", output: "2"),
                          "모델 이름을 적으세요.")
            await t.check("입력 가격이 숫자가 아니면 그 까닭",
                          PriceCatalog.userEntryProblem(model: "m", input: "1.2.3", output: "2")?.contains("입력 가격") == true)
            await t.check("모두 맞으면 문제 없음", PriceCatalog.userEntryProblem(model: "m", input: "1,5", output: "2") == nil)
            let typed: PriceEntry = PriceCatalog.userEntry(provider: .codex, model: " my-model ", input: 2, output: 8, today: "2026-10-04")
            let cacheRead: Double = 0.2, cacheWrite: Double = 2.5
            await t.equal("직접 넣은 가격: 캐시 읽기는 입력의 0.1배", typed.cacheReadPerMTok, cacheRead)
            await t.equal("직접 넣은 가격: 캐시 쓰기는 입력의 1.25배", typed.cacheWritePerMTok, cacheWrite)
            await t.equal("직접 넣은 가격: user- 버전", typed.catalogVersion, "user-2026-10-04")
            await t.equal("직접 넣은 가격: 이름 앞뒤 공백 없음", typed.model, "my-model")
            await t.check("직접 넣은 가격은 고치고 지울 수 있는 줄", typed.isUserEntered)
            await t.check("공개 가격은 직접 넣은 가격이 아니다", PriceCatalog.seed.allSatisfy { !$0.isUserEntered })
        }
    }

    // MARK: 오류 분류

    private static func errorClassification(_ t: TestKit) async {
        await t.group("오류 분류")
        await t.equal("한도", ErrorClassifier.classify("Claude usage limit reached"),
                      LimitStatus.subscriptionCap)
        await t.equal("일시 제한", ErrorClassifier.classify("429 Too Many Requests"),
                      LimitStatus.throttled)
        await t.equal("인증", ErrorClassifier.classify("401 Unauthorized"),
                      LimitStatus.authProblem)
        await t.equal("네트워크", ErrorClassifier.classify("ECONNRESET socket hang up"),
                      LimitStatus.networkError)
        await t.equal("원인 미확인", ErrorClassifier.classify("something odd happened"),
                      LimitStatus.unknownCause)
        await t.equal("빈 문자열도 미확인", ErrorClassifier.classify(nil),
                      LimitStatus.unknownCause)
    }

    // MARK: 저장 계층

    private static func storageLayer(_ t: TestKit) async {
        await t.group("저장 계층")
        do {
            let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ahc-test-\(UUID().uuidString).sqlite3")
            defer { try? FileManager.default.removeItem(at: dbURL) }
            let store = Store(databaseURL: dbURL)
            do {
                try await store.bootstrap()
                await t.check("마이그레이션 성공", true)
                await t.equal("스키마 버전", try await store.db.userVersion(),
                              Migrations.all.last?.version ?? 0)

                // 재실행해도 안전해야 한다.
                try await Migrations.migrate(store.db)
                await t.check("마이그레이션 재적용 안전", true)

                let project = Project(name: "테스트", path: "/tmp/x")
                try await store.upsertProject(project)
                var thread = ConversationThread(projectID: project.id, title: "스레드",
                                                goal: "목표", pinnedNotes: "제약")
                thread.claudeSelection = ModelSelection(model: "opus", effort: "max")
                thread.codexSelection = ModelSelection(model: "gpt-6-astra", effort: "ultra")
                thread.geminiSelection = ModelSelection(model: "gemini-3.8-flash", effort: "boost")
                try await store.upsertThread(thread)
                await t.equal("스레드 저장", (try await store.threads(projectID: project.id)).count, 1)
                let storedThread = try await store.thread(id: thread.id)
                await t.equal("Claude 선택 분리", storedThread?.claudeSelection.effort ?? "", "max")
                await t.equal("Codex 선택 분리", storedThread?.codexSelection.effort ?? "", "ultra")
                await t.equal("Antigravity 선택 분리", storedThread?.geminiSelection.effort ?? "", "boost")

                // 입력 초안은 스레드별로 분리되고 앱 재시작 후에도 남는다.
                let otherThread = ConversationThread(projectID: project.id, title: "다른 스레드")
                try await store.upsertThread(otherThread)
                try await store.setComposerDraft(threadID: thread.id, text: "첫 초안", revision: 1)
                try await store.setComposerDraft(threadID: otherThread.id, text: "둘째 초안", revision: 1)
                await t.equal("대화별 초안 분리",
                              try await store.composerDraft(threadID: thread.id)?.text ?? "", "첫 초안")
                await t.equal("다른 대화 초안 보존",
                              try await store.composerDraft(threadID: otherThread.id)?.text ?? "", "둘째 초안")
                try await store.setComposerDraft(threadID: thread.id, text: "최신 초안", revision: 3)
                try await store.setComposerDraft(threadID: thread.id, text: "뒤늦은 옛 초안", revision: 2)
                await t.equal("오래된 자동 저장이 최신 초안을 덮지 않음",
                              try await store.composerDraft(threadID: thread.id)?.text ?? "", "최신 초안")

                // 순번 단조 증가
                let e1 = try await store.appendEvent(
                    ThreadEvent(threadID: thread.id, kind: .userMessage, text: "첫 메시지"))
                let e2 = try await store.appendEvent(
                    ThreadEvent(threadID: thread.id, kind: .agentMessage, provider: .claude,
                                text: "응답"))
                await t.check("이벤트 순번 증가", e2.seq > e1.seq)
                await t.equal("최대 순번", try await store.maxSeq(threadID: thread.id), e2.seq)

                // 스트리밍 갱신은 같은 id 로 덮어쓴다
                var streaming = e2
                streaming.text = "응답 확정"
                streaming.isStreaming = false
                _ = try await store.appendEvent(streaming)
                let reloaded = try await store.events(threadID: thread.id)
                await t.equal("스트리밍 이벤트는 중복 생성 안 함", reloaded.count, 2)
                await t.equal("갱신 반영", reloaded.last?.text ?? "", "응답 확정")

                // 세션은 (스레드, 제공자) 별로 하나
                let s1 = try await store.ensureSession(threadID: thread.id, provider: .claude)
                let s2 = try await store.ensureSession(threadID: thread.id, provider: .claude)
                await t.equal("세션 재사용", s1.id, s2.id)
                let s3 = try await store.ensureSession(threadID: thread.id, provider: .codex)
                await t.check("제공자별 세션 분리", s1.id != s3.id)
                await t.equal("스레드의 세션 수", (try await store.sessions(threadID: thread.id)).count, 2)

                // 앱 재시작 복구: 활성 상태 실행을 자동 완료 처리하지 않는다
                var run = Run(threadID: thread.id, sessionID: s1.id, provider: .claude,
                              requestText: "작업", state: .running)
                try await store.insertRun(run)
                let dangling = try await store.danglingActiveRuns()
                await t.equal("재시작 시 활성 실행 보존", dangling.count, 1)
                await t.equal("자동 완료 처리하지 않음", dangling.first?.state ?? .idle,
                              RunState.running)

                run.state = .completed
                run.endedAt = Date()
                try await store.updateRun(run)
                await t.equal("종료 후 활성 실행 없음",
                              (try await store.danglingActiveRuns()).count, 0)

                // 사용량은 실행당 1건 (중복 합산 방지)
                let usage = UsageRecord(runID: run.id, threadID: thread.id, provider: .claude,
                                        model: "claude-opus-5", inputTokens: 10, outputTokens: 20)
                try await store.upsertUsage(usage)
                var again = usage
                again.id = UUID().uuidString
                again.outputTokens = 30
                try await store.upsertUsage(again)
                let usages = try await store.usage(threadID: thread.id)
                await t.equal("실행당 사용량 1건", usages.count, 1)
                await t.equal("최신 값으로 갱신", usages.first?.outputTokens ?? 0, 30)

                // 인계 중복 토큰 방지
                let handoff = Handoff(threadID: thread.id, fromProvider: .claude,
                                      toProvider: .codex, baseSeq: e2.seq,
                                      draftJSON: "{}", finalText: "본문")
                try await store.insertHandoff(handoff)
                var duplicate = handoff
                duplicate.id = UUID().uuidString
                var threw = false
                do { try await store.insertHandoff(duplicate) } catch { threw = true }
                await t.check("같은 로컬 토큰의 중복 인계 삽입 거부", threw)

                let found = try await store.handoff(localToken: handoff.localToken)
                await t.equal("로컬 토큰으로 조회", found?.id ?? "", handoff.id)

                // 평가는 나중에 수정 가능
                var rating = Rating(threadID: thread.id, runID: run.id, provider: .claude,
                                    satisfaction: .up)
                try await store.upsertRating(rating)
                rating.satisfaction = .down
                rating.rescue = true
                try await store.upsertRating(rating)
                let ratings = try await store.ratings(threadID: thread.id)
                await t.equal("평가 1건 유지", ratings.count, 1)
                await t.equal("평가 수정 반영", ratings.first?.satisfaction ?? .up, Satisfaction.down)
                await t.check("구원 표시 반영", ratings.first?.rescue == true)

                // 모델 선택 저장/복원
                var withModel = thread
                withModel.setSelection(ModelSelection(model: "gpt-6-astra", effort: "high"),
                                       for: .codex)
                withModel.setSelection(ModelSelection(model: "opus", effort: nil), for: .claude)
                try await store.upsertThread(withModel)
                let reloadedThread = try await store.thread(id: thread.id)
                await t.equal("Codex 모델 저장",
                              reloadedThread?.codexSelection.model ?? "", "gpt-6-astra")
                await t.equal("Codex 강도 저장",
                              reloadedThread?.codexSelection.effort ?? "", "high")
                await t.equal("Claude 모델 저장",
                              reloadedThread?.claudeSelection.model ?? "", "opus")
                await t.check("Claude 강도는 비어 있음",
                              reloadedThread?.claudeSelection.effort == nil)
                await t.check("제공자별 선택 분리",
                              reloadedThread?.selection(for: .codex).model == "gpt-6-astra"
                                && reloadedThread?.selection(for: .claude).model == "opus")

                // 기본값으로 되돌리기
                var cleared = withModel
                cleared.setSelection(ModelSelection(), for: .codex)
                try await store.upsertThread(cleared)
                let clearedThread = try await store.thread(id: thread.id)
                await t.check("기본값으로 되돌리면 nil 저장",
                              clearedThread?.codexSelection.isDefault == true)

                // 모델 목록 캐시
                let options = ModelCatalog.parseCodexModels([
                    ["id": "gpt-6-astra", "displayName": "GPT-6-Astra", "isDefault": true,
                     "supportedReasoningEfforts": [["reasoningEffort": "low"]]],
                ])
                let defaultScope = AgentScope.codex(CodexAccount.defaultID)
                try await store.replaceModelOptions(options, scope: defaultScope)
                let storedOptions = try await store.modelOptions(scope: defaultScope)
                await t.equal("모델 목록 저장", storedOptions.count, 1)
                await t.equal("강도 목록 복원",
                              storedOptions.first?.supportedEfforts ?? [], ["low"])
                await t.check("조회 시각 기록",
                              (try await store.modelCatalogFetchedAt(scope: defaultScope)) != nil)
                // 다른 계정의 목록과 섞이지 않아야 한다
                try await store.replaceModelOptions(options, scope: .codex("other-account"))
                await t.equal("계정별 목록 분리",
                              (try await store.modelOptions(scope: defaultScope)).count, 1)
                await t.equal("다른 계정 목록 저장",
                              (try await store.modelOptions(scope: .codex("other-account"))).count, 1)
                // 목록 교체가 이전 항목을 남기지 않아야 한다
                try await store.replaceModelOptions([], scope: defaultScope)
                await t.equal("빈 목록으로 교체",
                              (try await store.modelOptions(scope: defaultScope)).count, 0)
                await t.equal("다른 계정 목록은 그대로",
                              (try await store.modelOptions(scope: .codex("other-account"))).count, 1)

                // 가격표 시드
                let prices = try await store.priceEntries()
                await t.check("가격표 시드됨", prices.count >= PriceCatalog.seed.count)
                await t.check("가격 출처 기록", prices.allSatisfy { !$0.source.isEmpty })
                await t.check("적용 날짜 기록", prices.allSatisfy { !$0.effectiveDate.isEmpty })

                // set-18: 직접 넣은 가격은 고치고 지울 수 있다 — 공개 가격의 줄은 지우지 않는다.
                let mine = PriceCatalog.userEntry(provider: .codex, model: "typo-model", input: 1, output: 2, today: "2026-10-04")
                try await store.upsertPrice(mine)
                let fixed = PriceCatalog.userEntry(provider: .codex, model: "right-model", input: 1.5, output: 3, today: "2026-10-05")
                try await store.replaceUserPrice(id: mine.id, with: fixed)
                let afterFix: [PriceEntry] = try await store.priceEntries()
                let oldNames: [String] = afterFix.map(\.model)
                let newRow: PriceEntry? = afterFix.first { (entry: PriceEntry) -> Bool in entry.model == "right-model" }
                await t.check("고치기: 옛 이름의 줄은 없다", !oldNames.contains("typo-model"))
                await t.equal("고치기: 새 줄의 입력 가격", newRow?.inputPerMTok, 1.5)
                if let seedRow = afterFix.first(where: { !$0.isUserEntered }),
                   let fixedRow = afterFix.first(where: { $0.model == "right-model" }) {
                    try await store.deleteUserPrice(id: seedRow.id)
                    let keptSeed = try await store.priceEntries()
                    await t.check("공개 가격의 줄은 지우지 않는다", keptSeed.contains { $0.id == seedRow.id })
                    try await store.deleteUserPrice(id: fixedRow.id)
                    let removed = try await store.priceEntries()
                    await t.check("직접 넣은 줄은 지운다", !removed.contains { $0.model == "right-model" })
                } else {
                    await t.check("가격표의 공개 · 직접 넣은 줄", false)
                }

                // 앱 재시작 시 기록 복원
                await store.db.close()
                let store2 = Store(databaseURL: dbURL)
                try await store2.bootstrap()
                let restored = try await store2.events(threadID: thread.id)
                await t.equal("재시작 후 이벤트 복원", restored.count, 2)
                await t.equal("재시작 후 인계 복원",
                              (try await store2.handoffs(threadID: thread.id)).count, 1)
                let nextSeq = try await store2.nextSeq(threadID: thread.id)
                await t.check("재시작 후 순번 이어짐", nextSeq > e2.seq)
                await store2.db.close()
            } catch {
                await t.check("저장 계층 예외 없음", false, "\(error)")
            }
        }
    }

    // MARK: 붙인 이미지 · 알림의 비밀값

    /// 이미지 파일처럼 보이는 빈 파일 하나와 그 첨부 (내용은 보지 않는다 — 확장자만).
    private static func writeFakeImage(_ url: URL) throws -> ImageAttachment {
        try Data("not-a-real-png".utf8).write(to: url)
        return ImageAttachment(path: url.path, mediaType: "image/png", width: 1, height: 1, byteCount: 14,
                               name: url.lastPathComponent)
    }

    private static func jsonText<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// 지울 파일 고르기 (`ImageAttachments.removeUnreferenced`): 첨부 폴더 바로 아래에서 아무도 쓰지 않는 이미지만 —
    /// 폴더 밖 · `..` · 링크 · 하위 폴더 · 이미지가 아닌 파일은 그대로. 저장된 입력창 첨부 · 대기열은 지운 대화의 몫을 빼고 읽는다.
    static func attachmentRemovalRules(_ t: TestKit) async {
        await t.group("붙인 이미지: 지울 파일 고르기 (첨부 폴더 바로 아래 · 아무도 쓰지 않는 것만)")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-attach-rules-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("attachments")
        let outside = root.appendingPathComponent("outside")
        let manager = FileManager.default
        func exists(_ path: String) -> Bool { manager.fileExists(atPath: path) }
        do {
            try manager.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try manager.createDirectory(at: outside, withIntermediateDirectories: true)
            let only = try writeFakeImage(folder.appendingPathComponent("only.png")).path
            let shared = try writeFakeImage(folder.appendingPathComponent("shared.png")).path
            let nested = try writeFakeImage(folder.appendingPathComponent("nested/deep.png")).path
            let secret = try writeFakeImage(outside.appendingPathComponent("secret.png")).path
            let target = try writeFakeImage(outside.appendingPathComponent("target.png")).path
            let note = folder.appendingPathComponent("note.txt").path
            try Data("note".utf8).write(to: URL(fileURLWithPath: note))
            let link = folder.appendingPathComponent("link.png").path
            try manager.createSymbolicLink(atPath: link, withDestinationPath: target)
            let candidates: Set<String> = [only, shared, nested, secret, note, link,
                                           folder.path + "/../outside/secret.png",
                                           folder.appendingPathComponent("missing.png").path]
            let removed = ImageAttachments.removeUnreferenced(candidates, keeping: [folder.path + "/./shared.png"], in: folder)
            await t.check("아무도 쓰지 않는 첨부 폴더의 이미지만 지운다", removed.count == 1 && !exists(only), "\(removed)")
            await t.check("다른 곳이 쓰는 파일은 남긴다 (다른 모양의 경로로 적었어도)", exists(shared))
            await t.check("첨부 폴더 밖 · `..` 로 빠져나간 경로는 건드리지 않는다", exists(secret))
            await t.check("링크는 지우지 않고 링크가 가리키는 폴더 밖 파일도 그대로",
                          (try? manager.destinationOfSymbolicLink(atPath: link)) != nil && exists(target))
            await t.check("하위 폴더 · 이미지가 아닌 파일은 건드리지 않는다", exists(nested) && exists(note))
            await t.equal("첨부 폴더가 없으면 아무것도 지우지 않는다",
                          ImageAttachments.removeUnreferenced([shared], keeping: [], in: root.appendingPathComponent("none")), [])
        } catch {
            await t.check("시나리오 실행 중 예외", false, "\(error)")
        }

        let gone = ImageAttachment(path: "/fake/attachments/gone.png", mediaType: "image/png", width: 1, height: 1, byteCount: 1, name: "a")
        let kept = ImageAttachment(path: "/fake/attachments/kept.png", mediaType: "image/png", width: 1, height: 1, byteCount: 1, name: "b")
        let goneQueued = ImageAttachment(path: "/fake/attachments/gone-q.png", mediaType: "image/png", width: 1, height: 1,
                                         byteCount: 1, name: "c")
        let keptQueued = ImageAttachment(path: "/fake/attachments/kept-q.png", mediaType: "image/png", width: 1, height: 1,
                                         byteCount: 1, name: "d")
        let composer = jsonText(["deleted": [gone], "other": [kept]])
        let queue = jsonText(["deleted": [QueuedMessage(text: "q", images: [goneQueued])],
                              "other": [QueuedMessage(text: "q", images: [keptQueued])]])
        await t.equal("저장된 입력창 첨부 · 대기열: 지운 대화의 몫은 뺀다",
                      ImageAttachments.savedPaths(composerAttachments: composer, messageQueue: queue, excluding: ["deleted"]),
                      [kept.path, keptQueued.path] as Set<String>)
        await t.check("저장값을 읽지 못하면 nil — 무엇을 쓰는지 모르니 지우지 않는다",
                      ImageAttachments.savedPaths(composerAttachments: "{broken", messageQueue: nil, excluding: []) == nil)
        await t.equal("저장값이 없으면 빈 집합",
                      ImageAttachments.savedPaths(composerAttachments: nil, messageQueue: "", excluding: []), [] as Set<String>)
    }

    /// 대화 · 프로젝트를 지우면 그 대화만 쓰던 이미지 파일을 지운다 (`AppModel.removeOrphanedAttachments`) — 다른 대화의 메시지 ·
    /// 대기열 · 저장된 입력창 첨부가 쓰는 파일은 남기고, 첨부 폴더 밖은 건드리지 않는다. 실제 `AppModel` · SQLite 를 거친다.
    @MainActor
    static func attachmentCleanupApp(_ t: TestKit) async {
        await t.group("붙인 이미지: 대화 · 프로젝트를 지우면 그 대화만 쓰던 파일을 지운다 (앱 모델)")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-attach-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("attachments")
        let outside = root.appendingPathComponent("outside")
        func exists(_ image: ImageAttachment) -> Bool { FileManager.default.fileExists(atPath: image.path) }
        do {
            for dir in [folder, outside, root.appendingPathComponent("p1"), root.appendingPathComponent("p2")] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
            try await store.bootstrap()
            let p1 = Project(name: "p1", path: root.appendingPathComponent("p1").path)
            let p2 = Project(name: "p2", path: root.appendingPathComponent("p2").path)
            try await store.upsertProject(p1)
            try await store.upsertProject(p2)
            let deleted = ConversationThread(projectID: p1.id, title: "지울 대화")
            let other = ConversationThread(projectID: p1.id, title: "남는 대화")
            let queued = ConversationThread(projectID: p1.id, title: "대기열 대화")
            let elsewhere = ConversationThread(projectID: p2.id, title: "다른 프로젝트의 대화")
            for thread in [deleted, other, queued, elsewhere] { try await store.upsertThread(thread) }

            let only = try writeFakeImage(folder.appendingPathComponent("only.png"))
            let shared = try writeFakeImage(folder.appendingPathComponent("shared.png"))
            let inQueue = try writeFakeImage(folder.appendingPathComponent("queued.png"))
            let inSavedComposer = try writeFakeImage(folder.appendingPathComponent("saved.png"))
            let draft = try writeFakeImage(folder.appendingPathComponent("draft.png"))
            let projectOnly = try writeFakeImage(folder.appendingPathComponent("project-only.png"))
            let projectShared = try writeFakeImage(folder.appendingPathComponent("project-shared.png"))
            let outsideFile = try writeFakeImage(outside.appendingPathComponent("keep.png"))
            func message(_ thread: ConversationThread, _ images: [ImageAttachment]) async throws {
                _ = try await store.appendEvent(ThreadEvent(threadID: thread.id, kind: .userMessage, title: "사용자", text: "사진",
                                                            payloadJSON: ThreadEvent.imagesPayload(images)))
            }
            try await message(deleted, [only, shared, inQueue, inSavedComposer, outsideFile])
            try await message(other, [shared, projectShared])
            try await message(elsewhere, [projectOnly, projectShared])
            // 저장만 된 입력창 첨부 (앱을 켤 때 되살리기 전) — 다른 대화의 것.
            try await store.setSetting("composer_attachments", jsonText([queued.id: [inSavedComposer]]))

            let model = AppModel(store: store)
            model.attachmentsDirectory = folder
            await model.reloadProjects()
            model.messageQueues[queued.id] = [QueuedMessage(text: "다음", images: [inQueue])]
            model.composerAttachments[deleted.id] = [draft]
            await model.deleteThread(deleted)
            await model.attachmentCleanup?.value
            await t.check("지운 대화만 쓰던 메시지 · 입력창의 이미지는 지운다", !exists(only) && !exists(draft))
            await t.check("다른 대화의 메시지가 쓰는 파일은 남는다", exists(shared))
            await t.check("다른 대화의 대기열 · 저장된 입력창 첨부가 쓰는 파일은 남는다", exists(inQueue) && exists(inSavedComposer))
            await t.check("첨부 폴더 밖의 파일은 지운 대화만 썼어도 건드리지 않는다", exists(outsideFile))

            // 사람이 입력창의 썸네일에서 뺀 이미지 (×): 아무 데서도 쓰지 않으면 파일도 지운다 — 보낸 메시지가 쓰는 것은 남는다.
            let chip = try writeFakeImage(folder.appendingPathComponent("chip.png"))
            model.composerAttachments[other.id] = [chip, shared]
            model.discardAttachment(chip.id, threadID: other.id)
            model.discardAttachment(shared.id, threadID: other.id)
            await model.attachmentCleanup?.value
            await t.check("입력창에서 뺀 이미지는 쓰는 곳이 없으면 지우고, 보낸 메시지가 쓰면 남긴다",
                          !exists(chip) && exists(shared) && model.attachments(threadID: other.id).isEmpty)

            if let listed = model.projects.first(where: { $0.id == p2.id }) { await model.removeProject(listed) }
            await model.attachmentCleanup?.value
            await t.check("프로젝트를 빼면 그 프로젝트만 쓰던 파일을 지운다 (다른 프로젝트가 쓰는 것은 남는다)",
                          !model.projects.contains { $0.id == p2.id } && !exists(projectOnly) && exists(projectShared))
            await store.db.close()
        } catch {
            await t.check("시나리오 실행 중 예외", false, "\(error)")
        }
    }

    /// 시스템 알림의 제목 · 본문은 비밀값을 가린 뒤에 싣는다 (`NotificationGate.redacted`) — Codex 명령 승인의 본문은 명령 원문이고,
    /// 알림 센터는 지난 알림을 남긴다. 모든 알림이 지나는 `NotificationService.post` 에서 가린다.
    @MainActor
    static func notificationRedaction(_ t: TestKit) async {
        await t.group("알림: 제목 · 본문의 비밀값을 가린다")
        let fakeKey = "sk-ant-api03-" + String(repeating: "FAKE", count: 6)
        let keyBody = NotificationGate.redacted("curl https://api.example.test -d token \(fakeKey)")
        await t.check("알려진 키 모양을 가린다", !keyBody.contains("FAKEFAKE") && keyBody.contains("[REDACTED]"), keyBody)
        let exportBody = NotificationGate.redacted("export OPENAI_API_KEY=fake-openai-value-123\nnpm test")
        await t.check("export 줄의 키 값을 가리고 다음 줄은 그대로",
                      !exportBody.contains("fake-openai-value-123") && exportBody.hasSuffix("\nnpm test"), exportBody)
        let inline = NotificationGate.redacted("/bin/zsh -lc 'PGPASSWORD=fake-db-pass psql -h db.example.test'")
        await t.check("명령 가운데의 환경 변수 값을 가린다", !inline.contains("fake-db-pass") && inline.contains("psql -h db.example.test"),
                      inline)
        let bearer = NotificationGate.redacted("curl -H 'Authorization: Bearer fake-bearer-value' https://api.example.test")
        await t.check("Authorization 헤더를 가린다", !bearer.contains("fake-bearer-value"), bearer)
        await t.equal("비밀값이 없는 글은 그대로", NotificationGate.redacted("승인이 필요합니다 · npm test"), "승인이 필요합니다 · npm test")

        let service = NotificationService()
        service.post(category: .approvalNeeded, title: "승인이 필요합니다 \(fakeKey)",
                     body: "export OPENAI_API_KEY=fake-openai-value-123", threadID: nil)
        let record = service.postLog.last
        await t.check("post 가 싣는 제목 · 본문도 가린 뒤 (모든 알림이 지나는 곳)",
                      record.map { !$0.title.contains("FAKEFAKE") && !$0.body.contains("fake-openai-value-123")
                        && $0.body.contains("[REDACTED]") } == true,
                      "\(record?.title ?? "기록 없음") / \(record?.body ?? "")")
    }

    // MARK: 인계 패킷

    private static func handoffPacket(_ t: TestKit) async {
        await t.group("인계 패킷 구성")
        do {
            let project = Project(name: "p", path: "/tmp/p")
            var thread = ConversationThread(projectID: project.id, title: "제목")
            thread.goal = "인증 흐름 리팩터링"
            thread.pinnedNotes = "DB 스키마는 바꾸지 말 것"

            var events: [ThreadEvent] = []
            events.append(ThreadEvent(threadID: thread.id, seq: 1, kind: .userMessage,
                                      text: "로그인 버그를 고쳐줘"))
            events.append(ThreadEvent(threadID: thread.id, seq: 2, kind: .agentMessage,
                                      provider: .claude, text: "auth.ts 를 수정했습니다"))
            events.append(ThreadEvent(threadID: thread.id, seq: 3, kind: .fileChange,
                                      provider: .claude, title: "src/auth.ts", text: "diff"))
            events.append(ThreadEvent(threadID: thread.id, seq: 4, kind: .commandExecution,
                                      provider: .claude, title: "npm test",
                                      text: "npm test\n\n--- 출력 ---\n3 passing",
                                      payloadJSON: "{\"exitCode\":0}"))
            events.append(ThreadEvent(threadID: thread.id, seq: 5, kind: .commandExecution,
                                      provider: .claude, title: "npm run build",
                                      text: "npm run build", payloadJSON: "{\"exitCode\":1}"))
            events.append(ThreadEvent(threadID: thread.id, seq: 6, kind: .userMessage,
                                      text: "빌드 오류도 확인해줘"))

            var cancelledRun = Run(threadID: thread.id, sessionID: "s", provider: .claude,
                                   requestText: "빌드 오류 확인", state: .cancelled)
            cancelledRun.terminalReason = "aborted_streaming"

            var git = GitSnapshot()
            git.isRepository = true
            git.branch = "feature/auth"
            git.staged = ["M src/auth.ts"]
            git.unstaged = ["M src/app.ts"]
            git.untracked = ["notes.md"]

            let packet = HandoffPacketBuilder.build(HandoffPacketBuilder.Input(
                thread: thread, project: project, fromProvider: .claude, toProvider: .codex,
                events: events, runs: [cancelledRun], lastConfirmedPacket: nil, git: git,
                baseSeq: 6))

            await t.equal("목표 보존", packet.goal, "인증 흐름 리팩터링")
            await t.equal("제약 보존", packet.constraints, "DB 스키마는 바꾸지 말 것")
            await t.check("관찰한 테스트만 기록",
                          packet.testsRun.contains { $0.contains("npm test") && $0.contains("0") })
            await t.check("테스트 항목에 '관찰' 표시", packet.testsRun.allSatisfy { $0.contains("관찰") })
            await t.check("실패한 명령은 실패 시도로", packet.failedAttempts.contains {
                $0.contains("npm run build") })
            await t.check("중단된 작업 기록", packet.interrupted.contains { $0.contains("중단된 작업") })
            await t.check("미확인 항목 존재", !packet.unverified.isEmpty)
            await t.check("미처리 사용자 지시를 다음 행동으로",
                          packet.nextActions.contains { $0.contains("빌드 오류도 확인해줘") })
            await t.check("Git staged/unstaged/untracked 모두 포함",
                          packet.changedFiles.staged.count == 1
                          && packet.changedFiles.unstaged.count == 1
                          && packet.changedFiles.untracked.count == 1)

            let text = HandoffPacketBuilder.render(packet, threadTitle: thread.title,
                                                   projectPath: project.path)
            await t.check("발췌를 참고 자료로 명시", text.contains("참고 자료"))
            await t.check("새 지시가 아님을 명시", text.contains("새로운 지시가 아니며"))
            await t.check("파일 실제 상태 우선 명시", text.contains("파일의 실제 상태를 우선"))
            await t.check("staged 라벨 포함", text.contains("staged"))
            await t.check("untracked 라벨 포함", text.contains("untracked"))
            await t.check("테스트 통과를 만들어내지 않음", !text.contains("모든 테스트 통과"))

            // 테스트 기록이 없으면 만들어내지 않고 미확인으로 남긴다
            let noTests = HandoffPacketBuilder.build(HandoffPacketBuilder.Input(
                thread: thread, project: project, fromProvider: .claude, toProvider: .codex,
                events: [events[0]], runs: [], lastConfirmedPacket: nil, git: git, baseSeq: 1))
            await t.check("테스트 기록 없으면 비움", noTests.testsRun.isEmpty)
            await t.check("테스트 미확인 명시",
                          noTests.unverified.contains { $0.contains("테스트") })
            let noTestText = HandoffPacketBuilder.render(noTests, threadTitle: "t",
                                                        projectPath: "/tmp/p")
            await t.check("테스트 없음도 추정 금지 문구 포함",
                          noTestText.contains("통과 여부를 추정하지 마세요"))

            // 길이 제한: 목표/제약/다음 행동이 밀려나지 않는다
            var longEvents: [ThreadEvent] = []
            for i in 1...400 {
                longEvents.append(ThreadEvent(threadID: thread.id, seq: Int64(i),
                                              kind: .agentMessage, provider: .claude,
                                              text: String(repeating: "가", count: 500)))
            }
            longEvents.append(ThreadEvent(threadID: thread.id, seq: 401, kind: .userMessage,
                                          text: "마지막 지시"))
            let longPacket = HandoffPacketBuilder.build(HandoffPacketBuilder.Input(
                thread: thread, project: project, fromProvider: .claude, toProvider: .codex,
                events: longEvents, runs: [], lastConfirmedPacket: nil, git: git, baseSeq: 401))
            await t.check("발췌 길이 제한 적용",
                          longPacket.transcriptExcerpt.count
                            <= HandoffPacketBuilder.transcriptCharLimit + 1000)
            let longText = HandoffPacketBuilder.render(longPacket, threadTitle: "t",
                                                       projectPath: "/tmp/p")
            await t.check("길어도 목표 유지", longText.contains("인증 흐름 리팩터링"))
            await t.check("길어도 제약 유지", longText.contains("DB 스키마는 바꾸지 말 것"))
            await t.check("길어도 다음 행동 유지", longText.contains("마지막 지시"))

            // Git 저장소가 아닌 폴더
            var nonRepo = GitSnapshot()
            nonRepo.isRepository = false
            nonRepo.recentlyModified = ["a.txt", "b.txt"]
            let nonRepoPacket = HandoffPacketBuilder.build(HandoffPacketBuilder.Input(
                thread: thread, project: project, fromProvider: .claude, toProvider: .codex,
                events: events, runs: [], lastConfirmedPacket: nil, git: nonRepo, baseSeq: 6))
            let nonRepoText = HandoffPacketBuilder.render(nonRepoPacket, threadTitle: "t",
                                                          projectPath: "/tmp/p")
            await t.check("Git 아님을 명시", nonRepoText.contains("Git 저장소가 아닙니다"))
            await t.check("최근 수정 파일로 대체", nonRepoText.contains("a.txt"))
            await t.check("Git 아님이 미확인 항목에 반영",
                          nonRepoPacket.unverified.contains { $0.contains("Git 저장소가 아니라") })

            // 이전 확정 패킷 이어받기 (왕복 인계)
            let second = HandoffPacketBuilder.build(HandoffPacketBuilder.Input(
                thread: thread, project: project, fromProvider: .codex, toProvider: .claude,
                events: [events[5]], runs: [], lastConfirmedPacket: packet, git: git, baseSeq: 9))
            await t.check("이전 인계 내용 이어받음",
                          second.completed.contains { $0.hasPrefix("(이전 인계)") })
            await t.check("이전 다음 행동이 미완료로 이월",
                          second.inProgress.contains { $0.contains("이전 인계의 다음 행동") })
            await t.equal("왕복 방향 반영", second.toProvider, AgentProvider.claude)
        }
    }

    // MARK: 모델 목록

    private static func modelCatalogParsing(_ t: TestKit) async {
        await t.group("모델 목록 파싱")
        do {
            // Claude `/model --output-format json` 실측 응답
            // raw string 으로 두어 \n 이 JSON 이스케이프 그대로 들어가게 한다.
            let claudeJSON = #"""
            {"is_error": false, "subtype": "success",
             "result": "Current model: `Opus 5` (effort: high)\nUsage: /model <name>. Available: sonnet, opus, haiku, fable, best, sonnet[1m], opus[1m], fable[1m], opusplan, default, or a full model ID."}
            """#
            let snap = ModelCatalog.parseClaudeModelResponse(
                claudeJSON, into: ModelCatalogSnapshot(provider: .claude))
            await t.check("Claude 목록 조회 성공 표시", snap.discovered)
            await t.check("별칭 파싱", snap.options.contains { $0.identifier == "opus" }
                          && snap.options.contains { $0.identifier == "sonnet" }
                          && snap.options.contains { $0.identifier == "fable" })
            await t.equal("Claude 첫 모델", snap.options.first?.displayName ?? "", "Fable 5.1")
            await t.equal("Fable 설명", snap.options.first?.detail ?? "", "가장 어려운 과제를 위해")
            await t.equal("Opus 표시", snap.options.first { $0.identifier == "opus" }?.displayName ?? "", "Opus 5.5")
            await t.equal("Sonnet 표시", snap.options.first { $0.identifier == "sonnet" }?.displayName ?? "", "Sonnet 5")
            await t.equal("Haiku 표시", snap.options.first { $0.identifier == "haiku" }?.displayName ?? "", "Haiku 4.5")
            await t.check("기본 별칭 제거", !snap.options.contains { $0.identifier == "default" })
            let oldCache = [AgentModelOption(provider: .claude, identifier: "opus", displayName: "opus"),
                            AgentModelOption(provider: .claude, identifier: "default", displayName: "default")]
            let updatedCache = ModelCatalog.presentableOptions(oldCache)
            await t.equal("예전 캐시에도 버전 표시", updatedCache.first?.displayName ?? "", "Opus 5.5")
            await t.check("예전 캐시의 기본 항목 제거", !updatedCache.contains { $0.identifier == "default" })
            await t.equal("현재 모델을 기본 선택으로 인식",
                          ModelCatalog.preferredOption(in: snap.options)?.identifier ?? "", "opus")
            await t.check("괄호 별칭도 포함", snap.options.contains { $0.identifier == "opus[1m]" })
            await t.check("설명 문구는 제외", !snap.options.contains { $0.identifier.contains("full") }
                          && !snap.options.contains { $0.identifier.lowercased().hasPrefix("or") })
            await t.check("현재 모델 표시", snap.message?.contains("Opus 5") == true,
                          snap.message ?? "없음")
            await t.check("Claude 추론 강도 제공",
                          snap.options.first?.supportedEfforts.contains("xhigh") == true)
            await t.equal("현재 모델 파싱",
                          ModelCatalog.currentClaudeModel(from: "Current model: `Opus 5` (effort: high)")
                            ?? "", "Opus 5 (effort: high)")
            // Claude Code 2.1.283 실측: 강도 표시가 빠지고 `opus` 가 Opus 5.5 다.
            let claude283 = ModelCatalog.parseClaudeModelResponse(#"""
                {"is_error": false, "subtype": "success",
                 "result": "Current model: `Opus 5.5`\nUsage: /model <name>. Available: sonnet, opus, haiku, fable, best, sonnet[1m], opus[1m], fable[1m], opusplan, default, or a full model ID."}
                """#, into: ModelCatalogSnapshot(provider: .claude))
            await t.equal("2.1.283 현재 모델", claude283.message ?? "", "CLI 현재 설정: Opus 5.5")
            await t.equal("2.1.283 기본 선택", ModelCatalog.preferredOption(in: claude283.options)?.displayName ?? "",
                          "Opus 5.5")

            // 별칭마다의 이름은 CLI 에 묻는다 (`claude -p --model <별칭> /model`). 받은 이름이 코드의 이름보다 우선한다.
            await t.equal("이름 해석 (새 형식)", ModelCatalog.claudeModelName(from: "Current model: `Opus 5.5`"), "Opus 5.5")
            await t.equal("이름 해석 (옛 형식 · 강도 표시)", ModelCatalog.claudeModelName(from: "Current model: `Opus 5` (effort: high)"), "Opus 5")
            await t.equal("1M 표시는 뗀다", ModelCatalog.claudeModelName(from: "Current model: `Opus 5.5 (1M context)`"), "Opus 5.5")
            await t.check("별칭과 맞지 않는 이름은 버린다",
                          ModelCatalog.claudeModelName(from: "Current model: `Fable 5.1`", alias: "opus") == nil
                            && ModelCatalog.claudeModelName(from: "Current model: `Sonnet 6`", alias: "sonnet") == "Sonnet 6")
            let named = ModelCatalog.parseClaudeModelResponse(claudeJSON, into: ModelCatalogSnapshot(provider: .claude),
                                                              names: ["opus": "Opus 6", "sonnet": "Sonnet 5.5"])
            func shown(_ id: String, _ options: [AgentModelOption]) -> String {
                options.first { $0.identifier == id }?.displayName ?? ""
            }
            await t.equal("CLI 가 알려 준 이름", shown("opus", named.options), "Opus 6")
            await t.equal("긴 문맥 별칭은 바탕 이름 + 1M", shown("opus[1m]", named.options), "Opus 6 · 1M")
            await t.equal("이름을 못 받은 별칭은 코드의 이름", shown("haiku", named.options), "Haiku 4.5")
            await t.equal("다시 보일 때 받은 이름을 덮지 않는다", shown("opus", ModelCatalog.presentableOptions(named.options)), "Opus 6")
            await t.equal("설명은 코드의 것", named.options.first { $0.identifier == "opus" }?.detail ?? "", "복잡한 작업용")

            // 형식이 바뀌면 대체 목록을 쓰되 그 사실을 알린다
            let changed = ModelCatalog.parseClaudeModelResponse(
                #"{"result": "Models are now configured in settings."}"#,
                into: ModelCatalogSnapshot(provider: .claude))
            await t.check("형식 변경 시 조회 실패 표시", !changed.discovered)
            await t.check("형식 변경에도 목록이 비지 않음", !changed.options.isEmpty)
            await t.check("대체 목록임을 표시", changed.options.allSatisfy { !$0.isDiscovered })
            await t.check("원인 메시지 제공", changed.message != nil)
            await t.check("조회 실패 시 임의 모델을 선택하지 않음",
                          ModelCatalog.preferredOption(in: changed.options) == nil)

            // Codex model/list 실측 응답
            let codexData: [[String: Any]] = [
                ["id": "gpt-5.6-luna", "displayName": "GPT-5.6-Luna", "isDefault": false,
                 "hidden": false,
                 "supportedReasoningEfforts": [["reasoningEffort": "low"],
                                               ["reasoningEffort": "max"]]],
                ["id": "gpt-6-astra", "displayName": "GPT-6-Astra", "isDefault": true,
                 "hidden": false, "description": "Our most capable model.",
                 "defaultReasoningEffort": "low",
                 "supportedReasoningEfforts": [["reasoningEffort": "low"],
                                               ["reasoningEffort": "medium"],
                                               ["reasoningEffort": "high"],
                                               ["reasoningEffort": "xhigh"],
                                               ["reasoningEffort": "max"],
                                               ["reasoningEffort": "ultra"]]],
                ["id": "secret-model", "displayName": "Hidden", "hidden": true,
                 "supportedReasoningEfforts": []],
            ]
            let codexOptions = ModelCatalog.parseCodexModels(codexData)
            await t.equal("숨김 모델 제외", codexOptions.count, 2)
            await t.equal("첫 모델 식별자", codexOptions.first?.identifier ?? "", "gpt-6-astra")
            await t.equal("표시 이름", codexOptions.first?.displayName ?? "", "GPT-6-Astra")
            await t.equal("Astra 최신 설명", codexOptions.first?.detail ?? "",
                          "가장 어려운 복합 작업을 위한 최고 성능 모델")
            await t.check("CLI 기본 모델 표시", codexOptions.first?.isDefault == true)
            await t.equal("추론 강도 6종", codexOptions.first?.supportedEfforts.count ?? 0, 6)
            await t.equal("모델 기본 강도", codexOptions.first?.defaultEffort ?? "", "low")
            await t.equal("모델별 강도 차이", codexOptions.last?.supportedEfforts ?? [],
                          ["low", "max"])
            let ordered = ModelCatalog.parseCodexModels([
                ["id": "gpt-5.5", "description": "old"],
                ["id": "gpt-5.6-terra", "description": "old"],
                ["id": "gpt-5.6-luna", "description": "old"],
                ["id": "gpt-6-luna", "description": "old"],
                ["id": "gpt-5.6-sol", "description": "old"],
                ["id": "gpt-6-sol", "description": "old"],
                ["id": "gpt-6-astra", "description": "old"],
            ])
            await t.equal("Codex 모델 순서", ordered.map(\.identifier),
                          ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna",
                           "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"])
            await t.check("Codex 일곱 모델 설명 갱신", ordered.allSatisfy { $0.detail != "old" })
            let cached = ModelCatalog.presentableOptions([
                AgentModelOption(provider: .codex, identifier: "gpt-5.6-sol",
                                 displayName: "GPT-5.6-Sol", detail: "old")])
            await t.equal("Codex 캐시 설명도 갱신", cached.first?.detail ?? "",
                          "복잡한 코딩용 이전 세대 모델")

            // Codex 계열 선택 — 이름 규칙 `gpt-<버전>-<계열>`, 계열의 최신을 고르면 `gpt-*-<계열>` 로 저장해 새 버전을 따라간다.
            await t.check("계열 해석", ModelCatalog.codexFamily(of: "gpt-6-sol").map { $0.family == "sol" && $0.version == [6] } == true
                            && ModelCatalog.codexFamily(of: "gpt-5.6-luna").map { $0.family == "luna" && $0.version == [5, 6] } == true)
            await t.check("규칙 밖은 계열이 없다",
                          ["gpt-5.5", "codex-auto-review", "gpt-6-sol-mini", "gpt--sol", "opus"].allSatisfy { ModelCatalog.codexFamily(of: $0) == nil })
            let family = ModelCatalog.parseCodexModels([
                ["id": "gpt-9.9-sol"], ["id": "gpt-10-sol"], ["id": "gpt-6-luna"], ["id": "gpt-5.5"],
            ])
            await t.equal("버전은 숫자로 비교 (10 > 9.9)", ModelCatalog.resolveModel("gpt-*-sol", in: family), "gpt-10-sol")
            await t.equal("계열 선택이 아니면 그대로", ModelCatalog.resolveModel("gpt-9.9-sol", in: family), "gpt-9.9-sol")
            await t.check("목록에 없는 계열은 풀지 못한다", ModelCatalog.resolveModel("gpt-*-astra", in: family) == nil)
            func value(_ id: String) -> String {
                ModelCatalog.selectionValue(for: family.first { $0.identifier == id }!, in: family)
            }
            await t.equal("최신을 고르면 계열 선택", value("gpt-10-sol"), "gpt-*-sol")
            await t.equal("옛 버전을 고르면 그 ID 로 고정", value("gpt-9.9-sol"), "gpt-9.9-sol")
            await t.equal("계열이 없는 모델은 그 ID", value("gpt-5.5"), "gpt-5.5")
            await t.equal("Claude 별칭은 그대로",
                          ModelCatalog.selectionValue(for: AgentModelOption(provider: .claude, identifier: "opus", displayName: "Opus 5.5"),
                                                      in: []), "opus")
            let sol = ModelSelection(model: "gpt-*-sol", effort: "high")
            await t.equal("계열 선택의 이름은 푼 모델의 정확한 이름", sol.label(catalog: codexOptions + family), "gpt-10-sol · high")
            await t.equal("풀지 못하면 그 사실을 이름에", ModelSelection(model: "gpt-*-astra").label(catalog: family), "Astra 최신 (목록에 없음)")
            let lunaEfforts = ModelCatalog.parseCodexModels([
                ["id": "gpt-5.6-luna", "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "max"]]],
                ["id": "gpt-6-luna", "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "medium"]]],
            ])
            await t.equal("강도는 푼 모델의 단계",
                          EffortScale.availableEfforts(provider: .codex, selectedModel: "gpt-*-luna", options: lunaEfforts), ["low", "medium"])
            await t.equal("풀지 못한 계열 선택은 목록에 없는 모델",
                          EffortScale.availability(provider: .codex, selectedModel: "gpt-*-astra", options: lunaEfforts).emptyReason,
                          .modelUnlisted)

            // 선택 표현
            let none = ModelSelection()
            await t.check("빈 선택은 기본값", none.isDefault)
            await t.equal("기본값 라벨", none.label(catalog: codexOptions), "기본값")
            let chosen = ModelSelection(model: "gpt-6-astra", effort: "high")
            await t.equal("선택 라벨", chosen.label(catalog: codexOptions), "GPT-6-Astra · high")
        }
    }

    // MARK: 인계 상태

    private static func handoffDeliveryState(_ t: TestKit) async {
        await t.group("인계 전송 상태")
        do {
            let h0 = Handoff(threadID: "t", fromProvider: .claude, toProvider: .codex,
                             baseSeq: 1, draftJSON: "{}", finalText: "x")
            await t.equal("초기 상태는 초안", h0.deliveryState, HandoffDeliveryState.draft)
            var sending = h0; sending.deliveryState = .sending
            var unknown = h0; unknown.deliveryState = .unknown
            var delivered = h0; delivered.deliveryState = .delivered
            var failed = h0; failed.deliveryState = .failed
            // 재전송 가능 여부 규칙 (RunCoordinator.canSend 와 동일한 규칙)
            func canSend(_ h: Handoff) -> Bool {
                h.deliveryState == .draft || h.deliveryState == .failed
            }
            await t.check("초안은 전송 가능", canSend(h0))
            await t.check("전송 실패는 재전송 가능", canSend(failed))
            await t.check("전송 중은 재전송 금지", !canSend(sending))
            await t.check("전달 여부 미확인은 자동 재전송 금지", !canSend(unknown))
            await t.check("전달 확인된 인계는 재전송 금지", !canSend(delivered))
        }
    }

    // MARK: Codex 계정 (CODEX_HOME 분리)

    private static func codexAccounts(_ t: TestKit) async {
        await t.group("Codex 계정")
        do {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ahc-codexhome-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }

            // 1) auth.json 이 없으면 "로그인 필요" 이며 "확인 불가" 와 구분된다.
            let emptyHome = root.appendingPathComponent("empty")
            try? FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
            let empty = CodexAccountInspector.inspect(home: emptyHome.path)
            await t.equal("auth.json 없음 → 로그인 필요", empty.status, CodexAuthStatus.notLoggedIn)
            await t.check("사유를 남긴다", empty.note != nil)

            // 2) 형식이 깨진 파일은 "로그인 안 됨"이 아니라 "확인 불가".
            let brokenHome = root.appendingPathComponent("broken")
            try? FileManager.default.createDirectory(at: brokenHome, withIntermediateDirectories: true)
            try? "not json".write(to: brokenHome.appendingPathComponent("auth.json"),
                                  atomically: true, encoding: .utf8)
            let broken = CodexAccountInspector.inspect(home: brokenHome.path)
            await t.equal("깨진 auth.json → 확인 불가", broken.status, CodexAuthStatus.unreadable)

            // 3) ChatGPT 로그인. 토큰은 풀지 않는다 — 자격 정보가 있는지와 평범한 필드(`tokens.account_id`)만 본다.
            //    (실제 토큰이 아니라 같은 형식의 fixture 다. id_token 은 일부러 JWT 가 아닌 글로 둔다 — 풀려고 하지 않는지)
            let chatgptHome = root.appendingPathComponent("chatgpt")
            try? FileManager.default.createDirectory(at: chatgptHome, withIntermediateDirectories: true)
            let authJSON: [String: Any] = [
                "auth_mode": "chatgpt",
                "tokens": ["id_token": "not-a-jwt", "access_token": "a", "refresh_token": "r",
                           "account_id": "acct-2222"],
                "last_refresh": "2026-09-10T00:00:00.000Z",
            ]
            try? JSONSerialization.data(withJSONObject: authJSON)
                .write(to: chatgptHome.appendingPathComponent("auth.json"))
            let chatgpt = CodexAccountInspector.inspect(home: chatgptHome.path)
            await t.equal("ChatGPT 로그인 인식", chatgpt.status, CodexAuthStatus.loggedIn)
            await t.check("ChatGPT 로그인으로 안다", chatgpt.usesChatGPT)
            await t.equal("계정 ID 는 토큰이 아닌 필드에서", chatgpt.chatgptAccountID ?? "", "acct-2222")
            await t.check("id_token 을 풀지 않는다 (JWT 가 아니어도 경고 없음)", chatgpt.note == nil)

            // 4) API 키 로그인은 구독 한도와 청구가 다르므로 따로 알린다.
            let apiHome = root.appendingPathComponent("apikey")
            try? FileManager.default.createDirectory(at: apiHome, withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: [
                "auth_mode": "apikey", "OPENAI_API_KEY": "sk-fixture",
            ]).write(to: apiHome.appendingPathComponent("auth.json"))
            let apikey = CodexAccountInspector.inspect(home: apiHome.path)
            await t.equal("API 키 로그인 인식", apikey.status, CodexAuthStatus.loggedIn)
            await t.check("API 키는 구독 한도와 다르다고 알림",
                          apikey.note?.contains("API") == true)
            await t.check("API 키 로그인은 ChatGPT 로그인이 아니다", !apikey.usesChatGPT)

            // 5) 홈 사용 가능 여부
            await t.equal("빈 폴더는 사용 가능(로그인 필요)",
                          CodexAccountInspector.checkHome(emptyHome.path),
                          CodexAccountInspector.HomeCheck.usable(loggedIn: false))
            await t.equal("로그인된 폴더 인식",
                          CodexAccountInspector.checkHome(chatgptHome.path),
                          CodexAccountInspector.HomeCheck.usable(loggedIn: true))
            let filePath = brokenHome.appendingPathComponent("auth.json").path
            await t.equal("파일은 홈이 될 수 없음",
                          CodexAccountInspector.checkHome(filePath),
                          CodexAccountInspector.HomeCheck.notADirectory)

            // 6) 앱은 auth.json 을 읽기만 한다 (수정 시각이 바뀌지 않는다).
            let authPath = chatgptHome.appendingPathComponent("auth.json").path
            let before = (try? FileManager.default.attributesOfItem(atPath: authPath)[.modificationDate]) as? Date
            _ = CodexAccountInspector.inspect(home: chatgptHome.path)
            let after = (try? FileManager.default.attributesOfItem(atPath: authPath)[.modificationDate]) as? Date
            await t.check("auth.json 을 수정하지 않음", before == after)

            // 7) 경로 비교와 로그인 명령
            await t.check("경로 비교는 끝의 / 를 무시",
                          CodexAccountService.samePath("/tmp/a/", "/tmp/a"))
            await t.check("다른 경로는 다르다고 판정",
                          !CodexAccountService.samePath("/tmp/a", "/tmp/b"))
            await t.check("~ 를 펼쳐 비교",
                          CodexAccountService.samePath("~/.codex", NSHomeDirectory() + "/.codex"))
            await t.equal("로그인 명령에 홈이 들어간다",
                          CodexAccountInspector.loginCommand(home: "/tmp/x"),
                          "CODEX_HOME=/tmp/x codex login")
            await t.check("공백 있는 경로는 따옴표로 감싼다",
                          CodexAccountInspector.loginCommand(home: "/tmp/my home")
                            .contains("'/tmp/my home'"))
            // cap-20: CLI 의 기본 홈(~/.codex, CODEX_HOME 없음)이면 CODEX_HOME 을 붙이지 않는다.
            let defaultHome = NSHomeDirectory() + "/.codex"
            await t.equal("기본 홈의 로그인 명령은 codex login 만",
                          CodexAccountInspector.loginCommand(home: defaultHome, environment: [:]), "codex login")
            await t.equal("~ 로 적은 기본 홈도 같다 (끝의 / 무시)",
                          CodexAccountInspector.loginCommand(home: "~/.codex/", environment: [:]), "codex login")
            await t.check("셸에 CODEX_HOME 이 있으면 기본 홈이어도 붙인다 (그 셸의 다른 홈에 로그인되지 않게)",
                          CodexAccountInspector.loginCommand(home: defaultHome, environment: ["CODEX_HOME": "/tmp/other"])
                            .hasPrefix("CODEX_HOME="))
            await t.equal("기본 홈의 상태 명령도 그대로", CodexAccountInspector.statusCommand(home: defaultHome, environment: [:]),
                          "codex login status")

            // 8) 자식 환경에 CODEX_HOME 이 그 프로세스에만 들어간다.
            let cliEnv = CLIEnvironment()
            let plain = await cliEnv.childEnvironment()
            let scoped = await cliEnv.childEnvironment(codexHome: "/tmp/home-b")
            // 로그인 셸 PATH 조회는 시간 제한이 있어야 한다.
            // 제한이 없으면 셸이 응답하지 않을 때 앱 전체가 멈춘다 (2026-09-10 실측 사례).
            let started = Date()
            let fresh = CLIEnvironment()
            _ = await fresh.childEnvironment()
            let elapsed = Date().timeIntervalSince(started)
            await t.check("자식 환경 구성이 제한 시간 안에 끝남", elapsed < 15,
                          String(format: "%.1f초", elapsed))
            await t.check("셸 조회가 실패해도 일반 설치 위치는 포함",
                          (await fresh.childEnvironment())["PATH"]?.contains("/usr/bin") == true)

            await t.equal("계정 지정 시 CODEX_HOME 설정", scoped["CODEX_HOME"] ?? "", "/tmp/home-b")
            await t.check("지정하지 않으면 앱이 값을 만들지 않음",
                          plain["CODEX_HOME"] == ProcessInfo.processInfo.environment["CODEX_HOME"])
            await t.check("PATH 는 그대로 구성됨", (scoped["PATH"] ?? "").contains("/usr/bin"))
        }
    }

    // MARK: Codex 계정 — account/read (이메일 · 플랜은 CLI 에게 묻는다)

    /// 2026-10-07 실측한 `account/read` 응답의 모양 (codex-cli 0.160.1 — 이메일 · ID 는 fixture).
    private static func accountReadResult(email: String = "second@example.com", plan: String = "plus",
                                          accountID: String = "acct-2222") -> [String: Any] {
        ["account": ["type": "chatgpt", "email": email, "planType": plan],
         "requiresOpenaiAuth": true,
         "workspaceRouting": ["chatgptAccountId": accountID, "backendOrigin": "https://chatgpt.com",
                              "accountRoutingOverride": "NO_CONSTRAINT"]]
    }

    @MainActor
    private static func codexAccountRead(_ t: TestKit) async {
        await t.group("Codex 계정: account/read 해석 · 반영")
        let read = CodexAccountInspector.parseAccountRead(accountReadResult())
        await t.equal("ChatGPT 계정", read?.kind, .chatgpt)
        await t.equal("이메일", read?.email ?? "", "second@example.com")
        await t.equal("플랜", read?.planType ?? "", "plus")
        await t.equal("계정 ID 는 workspaceRouting 에서", read?.chatgptAccountID ?? "", "acct-2222")
        await t.equal("account: null → 로그인 안 됨",
                      CodexAccountInspector.parseAccountRead(["account": NSNull(), "requiresOpenaiAuth": true,
                                                              "workspaceRouting": NSNull()])?.kind, .loggedOut)
        await t.equal("API 키 계정",
                      CodexAccountInspector.parseAccountRead(["account": ["type": "apiKey"], "requiresOpenaiAuth": true])?.kind,
                      .apiKey)
        await t.check("모르는 형식은 nil (지난 값을 둔다)",
                      CodexAccountInspector.parseAccountRead(["requiresOpenaiAuth": true]) == nil)
        await t.check("빈 이메일은 없는 것으로",
                      CodexAccountInspector.parseAccountRead(accountReadResult(email: "  "))?.email == nil)

        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-acctread-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        func writeAuth(_ object: [String: Any]?) {
            let url = home.appendingPathComponent("auth.json")
            guard let object else { try? FileManager.default.removeItem(at: url); return }
            try? JSONSerialization.data(withJSONObject: object).write(to: url)
        }
        func chatgptAuth(_ accountID: String) -> [String: Any] {
            ["auth_mode": "chatgpt", "tokens": ["id_token": "x", "access_token": "a", "refresh_token": "r", "account_id": accountID]]
        }
        writeAuth(chatgptAuth("acct-2222"))
        let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
        do {
            try await store.bootstrap()
            let service = CodexAccountService(store: store)
            let added = try await service.add(homePath: home.path, label: "계정2")
            await t.check("등록 직후: 로그인됨 · 이메일은 아직 모른다",
                          added.authStatus == .loggedIn && added.email == nil, added.identityText)
            await t.equal("이메일 전의 화면 글 (로그인 여부는 옆의 상태가 말한다)", added.identityText, "이메일 확인 전")

            await service.applyAccountRead(added.id, read!)
            var now = service.account(added.id)
            await t.equal("account/read 의 이메일을 넣는다", now?.email ?? "", "second@example.com")
            await t.equal("플랜도", now?.planType ?? "", "plus")
            let saved = (try? await store.codexAccounts())?.first { $0.id == added.id }
            await t.equal("DB 에도 남는다 (오프라인으로 다시 켜도 보이게)", saved?.email ?? "", "second@example.com")

            await service.refreshIdentity(added.id)
            now = service.account(added.id)
            await t.equal("파일로 다시 봐도 지난 이메일이 남는다", now?.email ?? "", "second@example.com")
            await t.check("만료 시각은 더 적지 않는다", now?.tokenExpiresAt == nil)

            let stale = CodexAccountInspector.AccountRead(kind: .chatgpt, email: "other@example.com", planType: "pro",
                                                         chatgptAccountID: "acct-9999")
            await service.applyAccountRead(added.id, stale)
            await t.equal("다른 계정의 답(다시 로그인하기 전에 띄운 프로세스)은 쓰지 않는다",
                          service.account(added.id)?.email ?? "", "second@example.com")

            writeAuth(chatgptAuth("acct-3333"))
            await service.refreshIdentity(added.id)
            now = service.account(added.id)
            await t.check("다른 계정으로 다시 로그인하면 지난 이메일 · 플랜을 지운다",
                          now?.email == nil && now?.planType == nil && now?.chatgptAccountID == "acct-3333")
            await service.applyAccountRead(added.id, CodexAccountInspector.parseAccountRead(
                accountReadResult(email: "third@example.com", plan: "pro", accountID: "acct-3333"))!)
            await t.equal("새 계정의 답은 넣는다", service.account(added.id)?.email ?? "", "third@example.com")

            writeAuth(["auth_mode": "apikey", "OPENAI_API_KEY": "sk-fixture"])
            await service.refreshIdentity(added.id)
            await t.check("API 키 로그인으로 바뀌면 이메일 · 플랜을 지운다",
                          service.account(added.id)?.email == nil && service.account(added.id)?.planType == nil)
            await t.equal("API 키 계정의 화면 글", service.account(added.id)?.identityText ?? "", "API 키 로그인")
            await service.applyAccountRead(added.id, CodexAccountInspector.AccountRead(kind: .apiKey))
            await t.check("API 키 계정의 답은 아무것도 바꾸지 않는다", service.account(added.id)?.email == nil)

            writeAuth(nil)
            await service.refreshIdentity(added.id)
            await service.applyAccountRead(added.id, read!)
            now = service.account(added.id)
            await t.check("로그아웃하면 지우고, 그 뒤의 답으로 로그인됐다고 하지 않는다",
                          now?.authStatus == .notLoggedIn && now?.email == nil)
        } catch {
            await t.check("임시 DB 준비", false, "\(error)")
        }
        await store.db.close()
    }

    /// 가짜 `codex app-server` (sh) — initialize 와 `cases`(sh 의 case 가지, `$id` = 요청 ID)에 답하고, 받은 줄을 `requests` 에 적는다.
    private static func makeFakeCodex(in dir: URL, cases: String) -> URL? {
        let script = """
        #!/bin/sh
        dir="$(cd "$(dirname "$0")" && pwd)"
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "$dir/requests"
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          case "$line" in
            *'"method":"initialize"'*) echo '{"id":'"$id"',"result":{}}' ;;
        \(cases)
          esac
        done
        """
        let url = dir.appendingPathComponent("codex")
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
              (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)) != nil
        else { return nil }
        return url
    }

    private static func codexAccountReadWithLimits(_ t: TestKit) async {
        await t.group("Codex 계정: 한도 조회와 함께 account/read (가짜 app-server)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ahc-acctread-stub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let limits = #"'{"id":'"$id"',"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1800000000},"planType":"plus"}}}'"#
        let account = #"'{"id":'"$id"',"result":{"account":{"type":"chatgpt","email":"second@example.com","planType":"plus"},"requiresOpenaiAuth":true,"workspaceRouting":{"chatgptAccountId":"acct-2222","backendOrigin":"https://chatgpt.com","accountRoutingOverride":"NO_CONSTRAINT"}}}'"#
        let env = ["PATH": "/usr/bin:/bin"]

        // 1) 둘 다 답한다.
        let okDir = root.appendingPathComponent("ok")
        guard let ok = makeFakeCodex(in: okDir, cases: """
            *'"method":"account/read"'*) echo \(account) ;;
            *'"method":"account/rateLimits/read"'*) echo \(limits) ;;
        """) else { await t.check("가짜 app-server 준비", false); return }
        let both = await LimitsFetcher.fetchCodexWithAccount(path: ok.path, environment: env, accountID: "a2", timeout: 10)
        await t.check("한도를 읽는다", both.limits.hasUsableData && both.limits.accountID == "a2")
        await t.equal("같은 프로세스에서 계정 이메일도", both.account?.email ?? "", "second@example.com")
        let requests = (try? String(contentsOf: okDir.appendingPathComponent("requests"), encoding: .utf8)) ?? ""
        let lines = requests.split(separator: "\n").map(String.init)
        let readIndex = lines.firstIndex { $0.contains(#""method":"account/read""#) }
        let limitsIndex = lines.firstIndex { $0.contains(#""method":"account/rateLimits/read""#) }
        await t.check("계정 조회를 한도보다 먼저 보낸다", readIndex != nil && limitsIndex != nil && readIndex! < limitsIndex!)
        await t.check("토큰을 새로 받지 않게 refreshToken: false",
                      readIndex.map { lines[$0].contains(#""refreshToken":false"#) } ?? false)
        await t.equal("한도만 묻는 옛 함수도 그대로",
                      await LimitsFetcher.fetchCodex(path: ok.path, environment: env, accountID: "a2", timeout: 10).hasUsableData, true)

        // 2) 네트워크가 없을 때처럼 계정 조회만 오류 — 한도는 그대로, 계정은 nil (지난 값을 둔다).
        guard let offline = makeFakeCodex(in: root.appendingPathComponent("offline"), cases: """
            *'"method":"account/read"'*) echo '{"id":'"$id"',"error":{"code":-32603,"message":"workspace routing discovery failed"}}' ;;
            *'"method":"account/rateLimits/read"'*) echo \(limits) ;;
        """) else { await t.check("가짜 app-server 준비", false); return }
        let failed = await LimitsFetcher.fetchCodexWithAccount(path: offline.path, environment: env, accountID: "a2", timeout: 10)
        await t.check("계정 조회 오류는 한도를 막지 않는다", failed.limits.hasUsableData && failed.account == nil)
        await t.check("계정 조회 오류를 한도 오류로 적지 않는다", failed.limits.message == nil)

        // 3) 계정 조회가 답하지 않으면 한도 답 뒤 잠깐만 기다린다.
        guard let silent = makeFakeCodex(in: root.appendingPathComponent("silent"), cases: """
            *'"method":"account/rateLimits/read"'*) echo \(limits) ;;
        """) else { await t.check("가짜 app-server 준비", false); return }
        let started = Date()
        let late = await LimitsFetcher.fetchCodexWithAccount(path: silent.path, environment: env, accountID: "a2",
                                                             timeout: 20, accountGrace: 0.5)
        let elapsed = Date().timeIntervalSince(started)
        await t.check("답 없는 계정 조회가 한도를 늦추지 않는다", late.limits.hasUsableData && late.account == nil && elapsed < 5,
                      String(format: "%.1f초", elapsed))

        // 4) 아무것도 답하지 않는 app-server 앞에서도 시간 제한대로 끝난다 (예전에는 그룹이 읽기 작업을 기다려 끝나지 않았다).
        guard let mute = makeFakeCodex(in: root.appendingPathComponent("mute"), cases: "") else {
            await t.check("가짜 app-server 준비", false); return
        }
        var started2 = Date()
        let muteLimits = await LimitsFetcher.fetchCodexWithAccount(path: mute.path, environment: env, accountID: "a2", timeout: 1)
        var took = Date().timeIntervalSince(started2)
        await t.check("한도 조회: 답이 없으면 시간 제한에 끝난다", took < 6 && !muteLimits.limits.hasUsableData && muteLimits.account == nil,
                      String(format: "%.1f초", took))
        started2 = Date()
        let muteModels = await ModelCatalog.fetchCodex(path: mute.path, environment: env, accountID: "a2", timeout: 1)
        took = Date().timeIntervalSince(started2)
        await t.check("모델 목록 조회: 답이 없으면 시간 제한에 끝난다", took < 6 && !muteModels.discovered,
                      String(format: "%.1f초 · %@", took, muteModels.message ?? ""))
    }

    // MARK: 계정별 세션 분리

    private static func perAccountSessions(_ t: TestKit) async {
        await t.group("계정별 세션")
        do {
            let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ahc-acct-\(UUID().uuidString).sqlite3")
            defer { try? FileManager.default.removeItem(at: dbURL) }
            let store = Store(databaseURL: dbURL)
            do {
                try await store.bootstrap()
                let project = Project(name: "p", path: "/tmp/p")
                try await store.upsertProject(project)
                let thread = ConversationThread(projectID: project.id, title: "스레드")
                try await store.upsertThread(thread)
                await t.equal("새 스레드는 기본 계정",
                              (try await store.thread(id: thread.id))?.codexAccountID ?? "",
                              CodexAccount.defaultID)

                // 앱은 대화의 칸("")만 쓴다 — 계정이 바뀌어도 같은 세션 · 기록 폴더를 함께 저장한다 (v10). 옛 계정별 칸은 별개의 행으로 남는다.
                var shared = try await store.ensureSession(threadID: thread.id, provider: .codex)
                let legacy = try await store.ensureSession(threadID: thread.id, provider: .codex, accountID: "acct-a")
                await t.check("대화의 칸과 옛 계정 칸은 다른 행", shared.id != legacy.id && shared.accountID.isEmpty)
                shared.cliSessionID = "thread-shared"
                shared.recordHome = "/tmp/codex-a"
                try await store.upsertSession(shared)
                let reloaded = try await store.session(threadID: thread.id, provider: .codex)
                await t.equal("세션 ID · 기록 폴더를 함께 저장", [reloaded?.cliSessionID ?? "", reloaded?.recordHome ?? ""],
                              ["thread-shared", "/tmp/codex-a"])
                let again = try await store.ensureSession(threadID: thread.id, provider: .codex)
                await t.equal("다시 찾으면 같은 행", again.id, shared.id)
                await t.equal("스레드의 세션 수",
                              (try await store.sessions(threadID: thread.id)).count, 2)

                // 계정 등록/해제
                let account = CodexAccount(id: "acct-a", label: "두 번째",
                                           homePath: "/tmp/codex-a")
                try await store.upsertCodexAccount(account)
                await t.equal("계정 저장", (try await store.codexAccounts()).count, 1)
                var moved = thread
                moved.codexAccountID = "acct-a"
                try await store.upsertThread(moved)
                await t.equal("계정을 쓰는 스레드 수",
                              try await store.threadCount(usingCodexAccount: "acct-a"), 1)
                let reassigned = try await store.reassignThreads(fromCodexAccount: "acct-a",
                                                                 to: CodexAccount.defaultID)
                await t.equal("등록 해제 시 스레드 되돌림", reassigned, 1)
                try await store.deleteCodexAccount(id: "acct-a")
                await t.equal("계정 삭제", (try await store.codexAccounts()).count, 0)
                await t.check("세션 기록은 지우지 않음",
                              (try await store.sessions(threadID: thread.id)).count == 2)

                // 계정 정보가 있는 인계 저장
                let handoff = Handoff(threadID: thread.id, fromProvider: .codex, toProvider: .codex,
                                      fromAccountID: "acct-a", toAccountID: "acct-b",
                                      baseSeq: 0, draftJSON: "{}", finalText: "x")
                try await store.insertHandoff(handoff)
                let storedHandoff = (try await store.handoffs(threadID: thread.id)).first
                await t.equal("인계 출발 계정", storedHandoff?.fromAccountID ?? "", "acct-a")
                await t.equal("인계 도착 계정", storedHandoff?.toAccountID ?? "", "acct-b")

                // 실행에 계정 기록
                let run = Run(threadID: thread.id, sessionID: shared.id, provider: .codex,
                              requestText: "작업", codexAccountID: "acct-a")
                try await store.insertRun(run)
                await t.equal("실행의 계정 기록",
                              (try await store.run(id: run.id))?.codexAccountID ?? "", "acct-a")
                await store.db.close()
            } catch {
                await t.check("계정 저장 예외 없음", false, "\(error)")
            }
        }
    }

    // MARK: 인계 패킷 하위 호환

    private static func packetCompatibility(_ t: TestKit) async {
        await t.group("인계 패킷 버전")
        do {
            // v1 로 저장된 초안(계정 항목이 없음)도 그대로 읽혀야 한다.
            let v1JSON = """
            {"version":1,"goal":"목표","constraints":"제약","completed":[],"inProgress":[],
             "decisions":[],"failedAttempts":[],
             "changedFiles":{"isRepository":false,"staged":[],"unstaged":[],"untracked":[],
                             "recentlyModified":[]},
             "testsRun":[],"interrupted":[],"nextActions":[],"references":[],"unverified":[],
             "transcriptExcerpt":"","generatedAt":770000000,
             "fromProvider":"claude","toProvider":"codex","baseSeq":3}
            """
            let decoded = try? JSONDecoder().decode(HandoffPacket.self, from: Data(v1JSON.utf8))
            await t.check("v1 패킷 해독", decoded != nil)
            await t.equal("v1 버전 보존", decoded?.version ?? -1, 1)
            await t.check("v1 에는 계정 정보가 없다", decoded?.fromAccountLabel == nil)

            // 같은 제공자 안에서 계정만 바뀌는 인계는 세션이 끊긴다는 사실을 본문에 적는다.
            let thread = ConversationThread(projectID: "p", title: "스레드", goal: "목표")
            let project = Project(name: "p", path: "/tmp/p")
            let packet = HandoffPacketBuilder.build(HandoffPacketBuilder.Input(
                thread: thread, project: project, fromProvider: .codex, toProvider: .codex,
                fromAccountLabel: "계정 A", toAccountLabel: "계정 B",
                events: [], runs: [], lastConfirmedPacket: nil,
                git: GitSnapshot(), baseSeq: 0))
            await t.equal("패킷 버전", packet.version, HandoffPacket.currentVersion)
            await t.check("계정 이름 기록",
                          packet.fromAccountLabel == "계정 A" && packet.toAccountLabel == "계정 B")
            await t.check("세션 단절을 미확인 항목에 명시",
                          packet.unverified.contains { $0.contains("계정이 바뀌어") })
            let text = HandoffPacketBuilder.render(packet, threadTitle: "스레드",
                                                   projectPath: "/tmp/p")
            await t.check("본문에 계정 이름 표기", text.contains("Codex · 계정 A"))
            await t.check("본문에 세션 단절 안내", text.contains("다른 계정"))
            await t.equal("계정이 없으면 제공자 이름만",
                          HandoffPacket.partyName(.claude, nil), "Claude")
        }
    }

    // MARK: 셸 환경 읽기 (onb-2 · onb-3) — 실제 셸 대신 가짜 SHELL 스크립트

    /// 가짜 셸을 만든다 (실행 권한).
    private static func fakeShell(_ directory: URL, _ name: String, _ body: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// 그 글이 명령줄에 든 프로세스가 아직 있는가 (`pgrep -f` — `waitUntilExit` 는 하네스에서 멈춘 적이 있어 쓰지 않는다).
    private static func processRunning(_ pattern: String) async -> Bool {
        let result = await CLIEnvironment.captureProcess(executable: "/usr/bin/pgrep", arguments: ["-f", pattern],
                                                         environment: ProcessInfo.processInfo.environment, timeout: 10)
        return result.exitStatus == 0
    }

    static func shellEnvironment(_ t: TestKit) async {
        await t.group("CLI 환경: 셸 환경 읽기 (가짜 셸)")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-shellenv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // 인사말 · 프롬프트 잡음을 앞뒤로 찍고, 받은 명령을 돈다 (`$1` 은 -ilc · -lc, `$2` 가 명령).
            let noisy = try fakeShell(root, "noisy-zsh", """
                echo "Last login: Sat Oct  4 on ttys001"
                printf '%s\\n' '\u{1b}[32mtheme noise\u{1b}[0m'
                export ANTHROPIC_API_KEY='sk-shell-123'
                export HTTPS_PROXY='http://proxy.local:3128'
                export CLAUDE_CONFIG_DIR='/tmp/claude-config'
                export CODEX_HOME='/tmp/shell-codex-home'
                export RANDOM_SECRET='nope'
                export OPENAI_NOTE="$(printf 'line1\\nline2')"
                export PATH='/fake/bin:/usr/bin:/bin'
                eval "$2"
                echo "bye"
                """)
            let started = Date()
            let read = await CLIEnvironment.probeShellEnvironment(shell: noisy, timeout: 5)
            await t.equal("대화형 셸에서 읽었다", read?.source, .interactive)
            await t.equal("PATH 는 셸의 값 (잡음과 섞이지 않는다)", read?.path, "/fake/bin:/usr/bin:/bin")
            let variables: [String: String] = read?.variables ?? [:]
            await t.check("API 키 · 프록시 · Claude 설정 폴더는 넘긴다",
                          variables["ANTHROPIC_API_KEY"] == "sk-shell-123" && variables["HTTPS_PROXY"] == "http://proxy.local:3128"
                            && variables["CLAUDE_CONFIG_DIR"] == "/tmp/claude-config", "\(variables.keys.sorted())")
            await t.check("허용 목록 밖 · CODEX_HOME · PATH 는 넘기지 않는다",
                          variables["RANDOM_SECRET"] == nil && variables["CODEX_HOME"] == nil && variables["PATH"] == nil
                            && variables["HOME"] == nil)
            await t.equal("줄바꿈이 든 값도 그대로 (env -0)", variables["OPENAI_NOTE"], "line1\nline2")
            await t.check("곧 끝난다", Date().timeIntervalSince(started) < 4, String(format: "%.1f초", Date().timeIntervalSince(started)))

            // 대화형 셸이 멈추면 시간 제한 뒤 로그인 셸로 — 멈춘 셸과 그 자식은 끝낸다.
            let hangsInteractive = try fakeShell(root, "slow-rc-zsh", """
                if [ "$1" = "-ilc" ]; then sleep 29.731; fi
                export PATH='/login/bin:/usr/bin:/bin'
                eval "$2"
                """)
            let fallbackStart = Date()
            let fallback = await CLIEnvironment.probeShellEnvironment(shell: hangsInteractive, timeout: 1.5)
            let fallbackElapsed = Date().timeIntervalSince(fallbackStart)
            await t.check("대화형이 시간을 넘기면 로그인 셸로 읽는다",
                          fallback?.source == .loginOnly && fallback?.path == "/login/bin:/usr/bin:/bin", "\(String(describing: fallback))")
            await t.check("기다림은 시간 제한만큼", fallbackElapsed < 4.5, String(format: "%.1f초", fallbackElapsed))
            let leftover = await processRunning("sleep 29.731")
            await t.check("시간을 넘긴 셸의 자식(sleep)은 남지 않는다", !leftover)

            // 둘 다 멈추면 nil — 앱은 일반 설치 위치로 계속한다.
            let hangs = try fakeShell(root, "stuck-zsh", "sleep 28.917\n")
            let stuckStart = Date()
            let stuck = await CLIEnvironment.probeShellEnvironment(shell: hangs, timeout: 1)
            await t.check("셸이 답하지 않으면 nil · 두 번의 시간 제한 안에",
                          stuck == nil && Date().timeIntervalSince(stuckStart) < 4, String(format: "%.1f초", Date().timeIntervalSince(stuckStart)))
            let stuckLeftover = await processRunning("sleep 28.917")
            await t.check("멈춘 셸은 남지 않는다", !stuckLeftover)

            // 명령을 돌지 않는 셸(표식 없음) → nil.
            let ignores = try fakeShell(root, "ignoring-zsh", "echo 'just noise'\n")
            await t.check("표식이 없으면 nil", await CLIEnvironment.probeShellEnvironment(shell: ignores, timeout: 2) == nil)
            await t.check("없는 셸은 nil", await CLIEnvironment.probeShellEnvironment(shell: root.appendingPathComponent("없음").path,
                                                                                    timeout: 1) == nil)

            // 자식 환경: 셸 변수가 앱의 값보다 먼저, CODEX_HOME 은 앱이 정한 계정 홈, PATH 는 지정한 스크립트의 폴더가 맨 앞.
            let nvmBin = root.appendingPathComponent("nvm-bin")
            try FileManager.default.createDirectory(at: nvmBin, withIntermediateDirectories: true)
            let script = nvmBin.appendingPathComponent("claude")
            try "#!/usr/bin/env node\nconsole.log('x')\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let env = CLIEnvironment()
            await env.setShellEnvironmentProber {
                CLIEnvironment.ShellEnvironment(path: "/shell/bin:/usr/bin",
                                                variables: ["ANTHROPIC_API_KEY": "sk-shell", "HTTPS_PROXY": "http://p:1"],
                                                source: .interactive)
            }
            await env.setOverrides(.init(claudePath: script.path, codexPath: nil, geminiPath: nil))
            let child: [String: String] = await env.childEnvironment(codexHome: "/tmp/acct-home")
            // 인증 변수는 기본으로 넘기지 않는다 — 구독 사용자의 실행이 API 요금으로 청구되지 않게 (onb-19). 프록시는 넘긴다.
            await t.check("셸의 프록시는 자식에게 가고 API 키는 가지 않는다 (기본)",
                          child["ANTHROPIC_API_KEY"] == nil && child["HTTPS_PROXY"] == "http://p:1")
            await t.check("셸에 있는 인증 변수의 이름", await env.shellAuthVariables().contains("ANTHROPIC_API_KEY"))
            await t.check("API 키가 넘어가지 않으면 로그인 대신 쓸 인증으로 세지 않는다", await env.claudeAlternativeAuth() == false)
            await env.setForwardsShellAuth(true)
            let forwarding: [String: String] = await env.childEnvironment()
            await t.check("설정에서 켜면 셸의 API 키도 자식에게 간다", forwarding["ANTHROPIC_API_KEY"] == "sk-shell")
            await t.check("켜면 로그인 대신 쓸 인증으로 센다", await env.claudeAlternativeAuth())
            await env.setForwardsShellAuth(false)
            await t.equal("인증 변수는 빼고 연결 설정은 유지 (순수)",
                          CLIEnvironment.withholdingAuth(["OPENAI_API_KEY": "k", "ANTHROPIC_AUTH_TOKEN": "t", "ANTHROPIC_BASE_URL": "u",
                                                          "CLAUDE_CODE_USE_BEDROCK": "1"], forwards: false),
                          ["ANTHROPIC_BASE_URL": "u", "CLAUDE_CODE_USE_BEDROCK": "1"])
            await t.equal("점검표의 안내: 넘기지 않는 것이 없으면 없음", SettingsText.withheldAuthNote([]), nil)
            await t.equal("CODEX_HOME 은 앱이 정한 계정 홈", child["CODEX_HOME"], "/tmp/acct-home")
            let path: String = child["PATH"] ?? ""
            await t.check("PATH: #!/usr/bin/env 스크립트의 폴더 → 셸의 PATH 순서",
                          path.hasPrefix(nvmBin.path + ":/shell/bin:/usr/bin"), path)
            await t.check("일반 설치 위치는 뒤에 남는다", path.contains("/opt/homebrew/bin"))
            await t.equal("지정한 경로를 찾는다", await env.resolveExecutable(.claude), script.path)

            // 에이전트 세션이 앱을 띄운 것처럼: 그 세션의 변수는 셸 조회에도 자식에게도 가지 않는다 (시험 프로세스의 환경을 잠시 바꾼다).
            let markers: [String] = ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_MESSAGING_TOKEN"]
            let saved: [String: String?] = Dictionary(uniqueKeysWithValues: markers.map { ($0, ProcessInfo.processInfo.environment[$0]) })
            setenv("CLAUDECODE", "1", 1)
            setenv("CLAUDE_CODE_ENTRYPOINT", "claude-desktop", 1)
            setenv("CLAUDE_CODE_MESSAGING_TOKEN", "host-secret", 1)
            let hostRead = await CLIEnvironment.probeShellEnvironment(shell: noisy, timeout: 5)
            let hostChild: [String: String] = await env.childEnvironment()
            for (name, value) in saved {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
            await t.check("에이전트 세션의 변수는 셸 조회로 되돌아오지 않는다",
                          hostRead?.variables["CLAUDE_CODE_ENTRYPOINT"] == nil && hostRead?.variables["CLAUDE_CODE_MESSAGING_TOKEN"] == nil
                            && hostRead?.variables["HTTPS_PROXY"] == "http://proxy.local:3128",
                          "\(hostRead?.variables.keys.sorted() ?? [])")
            await t.check("에이전트 세션의 변수는 자식에게 가지 않고 셸의 값은 간다",
                          hostChild["CLAUDECODE"] == nil && hostChild["CLAUDE_CODE_ENTRYPOINT"] == nil
                            && hostChild["CLAUDE_CODE_MESSAGING_TOKEN"] == nil && hostChild["HTTPS_PROXY"] == "http://p:1"
                            && hostChild["HOME"] != nil,
                          "\(hostChild.keys.sorted())")
        } catch {
            await t.check("셸 환경 시험 중 예외", false, "\(error)")
        }

        // 표식 사이만 푼다 (순수).
        var dump = Data("noise __B__".utf8)
        dump.append(Data("A=1".utf8)); dump.append(0)
        dump.append(Data("B=x=y".utf8)); dump.append(0)
        dump.append(Data("broken".utf8)); dump.append(0)
        dump.append(Data("__E__ tail".utf8))
        await t.equal("env -0 출력 풀기 (값 안의 = · 이름 없는 항목)", CLIEnvironment.parseEnvironmentDump(dump, begin: "__B__", end: "__E__"),
                      ["A": "1", "B": "x=y"])
        await t.check("끝 표식이 없으면 nil", CLIEnvironment.parseEnvironmentDump(Data("__B__A=1".utf8), begin: "__B__", end: "__E__") == nil)

        let forwarded: [String] = ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CONFIG_DIR", "OPENAI_API_KEY",
                                   "CODEX_SANDBOX_NETWORK", "AWS_PROFILE", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "NO_PROXY", "no_proxy",
                                   "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "GOOGLE_CLOUD_PROJECT", "GEMINI_API_KEY", "CLOUD_ML_REGION"]
        let kept: [String] = ["CODEX_HOME", "PATH", "HOME", "SHELL", "TERM", "RANDOM_SECRET", "GITHUB_TOKEN", "NPM_TOKEN",
                              "DYLD_INSERT_LIBRARIES", "LD_PRELOAD"]
        await t.check("넘기는 변수 허용 목록", forwarded.allSatisfy(CLIEnvironment.isForwardedShellVariable),
                      forwarded.filter { !CLIEnvironment.isForwardedShellVariable($0) }.joined(separator: ","))
        await t.check("넘기지 않는 변수", !kept.contains(where: CLIEnvironment.isForwardedShellVariable),
                      kept.filter(CLIEnvironment.isForwardedShellVariable).joined(separator: ","))

        // 에이전트 세션이 앱을 띄웠으면 그 세션의 변수는 물려주지 않는다 (2026-10-07 — 앱이 띄운 claude 가 claude-desktop 으로 기록됐다).
        let hostSession: [String: String] = [
            "HOME": "/Users/u", "USER": "u", "SHELL": "/bin/zsh", "TMPDIR": "/tmp/u", "PATH": "/agent/bin:/usr/bin",
            "LANG": "ko_KR.UTF-8", "LC_CTYPE": "UTF-8", "SSH_AUTH_SOCK": "/tmp/ssh", "AHC_DATABASE_PATH": "/tmp/db",
            "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "claude-desktop", "CLAUDE_CODE_SESSION_ID": "s",
            "CLAUDE_CODE_MESSAGING_TOKEN": "secret", "CLAUDE_CODE_ACCOUNT_UUID": "a", "CLAUDE_PID": "1",
            "CLAUDE_AGENT_SDK_VERSION": "1", "ANTHROPIC_BASE_URL": "http://127.0.0.1:1", "MCP_CONNECTION_NONBLOCKING": "1",
            "GIT_EDITOR": "true", "AI_AGENT": "x"]
        await t.check("에이전트 세션의 표시를 알아본다", CLIEnvironment.launchedFromAgentSession(hostSession))
        await t.equal("에이전트 세션이 띄웠으면 로그인 세션의 기본 변수 · LC_* · AHC_* 만 물려준다",
                      CLIEnvironment.inheritable(hostSession).keys.sorted(),
                      ["AHC_DATABASE_PATH", "HOME", "LANG", "LC_CTYPE", "PATH", "SHELL", "SSH_AUTH_SOCK", "TMPDIR", "USER"])
        let finder: [String: String] = ["HOME": "/Users/u", "PATH": "/usr/bin:/bin", "ANTHROPIC_BASE_URL": "https://proxy",
                                        "CLAUDE_CODE_USE_BEDROCK": "1", "CODEX_SANDBOX": ""]
        await t.check("Finder 로 연 앱의 환경은 에이전트 세션이 아니다 (빈 표시는 세지 않는다)",
                      !CLIEnvironment.launchedFromAgentSession(finder))
        await t.equal("Finder 로 연 앱은 물려받은 환경 그대로 (launchctl setenv 로 둔 값 포함)",
                      CLIEnvironment.inheritable(finder), finder)
        await t.check("Codex 샌드박스 셸도 에이전트 세션이다",
                      CLIEnvironment.launchedFromAgentSession(["CODEX_SANDBOX": "seatbelt", "HOME": "/Users/u"]))

        let alternatives: [[String: String]] = [["ANTHROPIC_API_KEY": "sk"], ["ANTHROPIC_AUTH_TOKEN": "t"],
                                                ["CLAUDE_CODE_USE_BEDROCK": "1"], ["CLAUDE_CODE_USE_VERTEX": "true"]]
        let notAlternatives: [[String: String]] = [[:], ["ANTHROPIC_API_KEY": "  "], ["CLAUDE_CODE_USE_BEDROCK": "0"],
                                                   ["CLAUDE_CODE_USE_VERTEX": "false"], ["OPENAI_API_KEY": "sk"]]
        await t.equal("Claude 의 로그인 대신 쓰는 인증: API 키 · 토큰 · Bedrock · Vertex",
                      alternatives.map(CLIEnvironment.usesClaudeAlternativeAuth), [true, true, true, true])
        await t.equal("빈 값 · 0 · false · 다른 회사의 키는 아니다",
                      notAlternatives.map(CLIEnvironment.usesClaudeAlternativeAuth), [false, false, false, false, false])
    }

    // MARK: PATH 도우미 (onb-2)

    static func pathHelpers(_ t: TestKit) async {
        await t.group("CLI 환경: PATH · 버전 관리자 · 지정 경로")
        await t.equal("PATH 순서 · 겹친 폴더는 앞의 것만",
                      CLIEnvironment.composePath(pinned: ["/pin"], shell: "/a:/b:/pin", managers: ["/m"], common: ["/usr/bin", "/a"],
                                                 inherited: "/usr/bin:/c:"),
                      ["/pin", "/a", "/b", "/m", "/usr/bin", "/c"])
        await t.equal("nvm 은 가장 새 버전",
                      CLIEnvironment.newestVersionDirectory(in: ["v18.19.0", "v22.11.0", "v22.2.0", "system", "v9.0.0", ".DS_Store"]),
                      "v22.11.0")
        await t.check("버전 폴더가 없으면 nil", CLIEnvironment.newestVersionDirectory(in: ["system"]) == nil)

        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-managers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        do {
            for sub in [".nvm/versions/node/v20.1.0/bin", ".nvm/versions/node/v22.3.1/bin", ".asdf/shims", ".local/share/mise/shims"] {
                try FileManager.default.createDirectory(at: home.appendingPathComponent(sub), withIntermediateDirectories: true)
            }
            await t.equal("버전 관리자 폴더: nvm 의 새 버전 · mise · asdf (있는 것만)",
                          CLIEnvironment.versionManagerDirectories(home: home.path),
                          [home.path + "/.nvm/versions/node/v22.3.1/bin", home.path + "/.local/share/mise/shims", home.path + "/.asdf/shims"])

            func write(_ name: String, _ text: String) throws -> String {
                let url = home.appendingPathComponent(name)
                try text.write(to: url, atomically: true, encoding: .utf8)
                return url.path
            }
            let envNode = try write("a", "#!/usr/bin/env node\nx")
            let envSplit = try write("b", "#! /usr/bin/env -S node --x\n")
            let shell = try write("c", "#!/bin/sh\necho\n")
            let direct = try write("d", "#!/usr/local/bin/node\n")
            let binary = try write("e", "\u{7f}ELF")
            let missing = home.appendingPathComponent("없음").path
            let scripts: [Bool] = [envNode, envSplit].map(CLIEnvironment.usesEnvInterpreter(atPath:))
            let others: [Bool] = [shell, direct, binary, missing].map(CLIEnvironment.usesEnvInterpreter(atPath:))
            await t.equal("#!/usr/bin/env node 는 PATH 의 해석기를 찾는 스크립트", scripts, [true, true])
            await t.equal("다른 해석기 · 기계어 · 없는 파일은 아니다", others, [false, false, false, false])
        } catch {
            await t.check("PATH 도우미 시험 중 예외", false, "\(error)")
        }
        await t.equal("지정 경로의 ~ 를 푼다", CLIEnvironment.expandedOverride("~/bin/claude"), NSHomeDirectory() + "/bin/claude")
        await t.check("공백 · 빈 값", CLIEnvironment.expandedOverride("  /x  ") == "/x" && CLIEnvironment.expandedOverride("  ") == nil
                        && CLIEnvironment.expandedOverride(nil) == nil)
    }

    /// 한도 칩 · 팝오버의 글 (`LimitsPresentation`): 아직 읽지 않은 한도(첫 프로젝트 뒤로 미룸 · 설정에서 끔)를 실패로 적지 않고,
    /// 숫자에는 % 를 붙이고, 창 이름 · 확인 시각은 도움말 줄에. 설치하지 않은 에이전트는 줄에서 뺀다.
    @MainActor
    static func limitsPresentation(_ t: TestKit) async {
        typealias P = LimitsPresentation
        let never = LimitSnapshot(provider: .claude)   // 조회한 적 없음 (fetchedAt nil · 까닭 없음)
        await t.equal("조회한 적 없음 → 확인 전", P.state(never), .pending(.notYet))
        await t.equal("첫 프로젝트 뒤로 미룸", P.state(never, context: P.Context(deferredUntilProject: true)),
                      .pending(.afterFirstProject))
        await t.equal("설정에서 끈 조회가 미룸보다 먼저",
                      P.state(never, context: P.Context(deferredUntilProject: true, startupCheckOff: true)), .pending(.startupCheckOff))
        await t.equal("읽는 중", P.state(never, context: P.Context(refreshing: true)), .pending(.checking))
        let deferredNote: String = P.note(.pending(.afterFirstProject)) ?? ""
        let notYetNote: String = P.note(.pending(.notYet)) ?? ""
        await t.check("미룬 조회는 첫 프로젝트 뒤에 확인한다고 적는다", deferredNote.contains("첫 프로젝트"), deferredNote)
        await t.check("확인 전은 실패 글이 아니다 (예전: '한도 정보를 가져오지 못했습니다')", !notYetNote.contains("가져오지 못했"), notYetNote)
        await t.equal("확인 전의 상태 이름", P.statusName(.pending(.notYet), snapshot: never), "확인 전")
        await t.check("확인 전은 경고색이 아니다", !P.isWarning(.pending(.notYet), snapshot: never))

        var failed = LimitSnapshot(provider: .claude)
        failed.fetchedAt = Date()
        failed.message = "claude 실행 파일을 찾지 못했습니다."
        let failedState: P.State = P.state(failed)
        await t.equal("읽었는데 값이 없으면 실패", failedState, .unavailable(message: failed.message))
        await t.check("실패는 경고색", P.isWarning(failedState, snapshot: failed))
        await t.equal("실패의 까닭을 그대로", P.note(failedState), failed.message)

        var auth = LimitSnapshot(provider: .codex, accountID: "a")
        auth.status = .authProblem
        await t.equal("값 없이 알게 된 문제", P.state(auth), .problem(.authProblem, message: nil))
        await t.check("문제는 칩에 숫자 대신 경고 기호", P.chipText(P.state(auth)) == nil)

        var used = LimitSnapshot(provider: .claude)
        used.status = .ok
        used.fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        used.windows = [LimitWindow(label: "5시간", utilization: 0.16, spanMinutes: 300),
                        LimitWindow(label: "7일", utilization: 0.4, spanMinutes: 10080)]
        let state = P.state(used)
        await t.equal("칩 숫자에 %", P.chipText(state), "16%")
        await t.equal("확인 전 · 실패의 칩 글은 —", P.chipText(.pending(.notYet)), "—")
        let line = P.line(name: "Claude", state: state, fetchedAt: used.fetchedAt, now: used.fetchedAt ?? Date())
        await t.check("도움말 줄: 창 이름 · % · 확인 시각", line.hasPrefix("Claude · 5시간 한도 16% 사용 · ") && line.hasSuffix(" 확인"), line)

        let claude = P.Entry(snapshot: used, name: "Claude", accountLabel: nil, state: state)
        let codex = P.Entry(snapshot: auth, name: "Codex", accountLabel: nil, state: P.state(auth))
        await t.check("값이 하나라도 있으면 '한도' 글을 붙이지 않는다 · 모두 없으면 붙인다",
                      !P.needsCaption([claude, codex]) && P.needsCaption([codex]))
        await t.check("칩 도움말은 줄마다 + 눌러서 자세히 보기",
                      P.chipHelp([claude, codex]).components(separatedBy: "\n").count == 3)
        await t.check("접근성 이름은 '한도:' 로 시작", P.accessibility([claude]).hasPrefix("한도: Claude · 5시간 한도 16% 사용"))
        await t.check("팝오버 아래의 갱신 규칙은 실제 규칙 (답을 마칠 때 · 1분에 한 번)",
                      P.refreshRule.contains("답을 마칠 때마다") && P.refreshRule.contains("1분"))

        // 설치하지 않은 에이전트는 칩 · 팝오버 · 메뉴바에서 뺀다 (확인 전은 둔다).
        await t.check("CLI 를 확인하기 전은 보인다", P.shows(nil))
        await t.check("찾지 못한 CLI 는 뺀다", !P.shows(CLIStatus(provider: .codex)))
        await t.check("쓸 수 있는 CLI 는 보인다", P.shows(CLIStatus(provider: .codex, resolvedPath: "/bin/echo", executable: true)))

        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-limits-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
        try? await store.bootstrap()
        let model = AppModel(store: store)
        await model.accounts.load()
        model.limits.setCodexAccounts(model.accounts.refs)
        await t.equal("확인 전에는 Claude · Codex 기본 계정 모두", model.limitEntries.map(\.name), ["Claude", "Codex"])
        model.cliStatus[.codex] = CLIStatus(provider: .codex)
        await t.equal("Codex 를 찾지 못하면 Claude 만", model.limitEntries.map(\.name), ["Claude"])
        model.cliStatus[.claude] = CLIStatus(provider: .claude)
        await t.check("둘 다 없으면 칩이 없다", model.limitEntries.isEmpty)
        model.cliStatus[.claude] = CLIStatus(provider: .claude, resolvedPath: "/bin/echo", executable: true)
        model.deferredClaudeStartup = true
        let deferredState: P.State? = model.limitEntries.first?.state
        await t.equal("미룬 Claude 조회는 확인 전 (첫 프로젝트 뒤)", deferredState, P.State.pending(.afterFirstProject))
        model.startupFetchClaudeLimits = false
        let offState: P.State? = model.limitEntries.first?.state
        await t.equal("설정에서 끈 조회", offState, P.State.pending(.startupCheckOff))
        await t.check("Codex 의 한도에는 Claude 설정이 닿지 않는다",
                      model.limitContext(for: .codex(CodexAccount.defaultID)) == P.Context())
        await model.store.db.close()
    }
}
