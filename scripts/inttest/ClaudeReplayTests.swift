import Foundation

/// Claude 실측 기록(`scripts/probe/claude-background/logs` t1~t8)을 `ClaudeTurnTracker` 에 그대로 넣어,
/// 메인 · 하위 구분(부모 표시), 작업 표, 실행의 끝(기다리기 · 후속 턴 · 디바운스 · 중단 · 사용량)을 확인한다. CLI 를 부르지 않는다.
///
/// 어댑터와 같은 순서로 넣는다: CLI 줄 → `handle`, `recheck` 로 부탁한 때가 지난 뒤의 첫 줄 앞 → `tick`,
/// 기록 도구의 `interrupt` → `interrupt`(앱의 중단), 출력이 닫힘(`stdout_eof`) → `processEnded`(종료 코드 없음).
/// 기록 도구가 한 stdin 닫기(t7) · 새 사용자 메시지(t8)는 앱이 하지 않는 것이라 그 뒤의 CLI 줄만 넣는다.
/// 끝의 "가짜 CLI" 묶음은 정해 둔 줄을 내는 bash 스크립트로 `ClaudeAdapter` 자체를 돌린다 (실제 claude 는 부르지 않는다).
enum ClaudeReplayTests {
    static let probe = "claude-background"
    static let base = Date(timeIntervalSince1970: 1_790_000_000)
    static let sonnet = "claude-sonnet-5"

    struct Options {
        var waitForBackground = true
        /// 기록 도구의 `interrupt` 를 앱의 중단(`requestInterrupt`)으로 본다.
        var honorInterrupt = true
        /// 이 번호의 줄까지만 넣는다. 그러면 남은 `recheck` 는 저절로 부르지 않는다 (`ticks` 로 직접 부른다).
        var through: Int?
        /// 넣기가 끝난 뒤 부를 `tick` 의 시각 (기록 시작부터의 초).
        var ticks: [Double] = []
    }

    struct Step {
        var t: Double
        /// 이 동작을 낳은 줄의 번호 (`tick` 은 그 뒤에 넣을 줄의 번호).
        var index: Int
        var action: ClaudeTurnTracker.Action
    }

    struct Replay {
        var records: [ProbeLogs.Record]
        var tracker: ClaudeTurnTracker
        var steps: [Step] = []

        var events: [(t: Double, event: AgentEvent)] {
            steps.compactMap { if case .emit(let e) = $0.action { return ($0.t, e) }; return nil }
        }
        var settles: [(t: Double, remaining: Int)] {
            steps.compactMap { if case .settle(let n) = $0.action { return ($0.t, n) }; return nil }
        }
        var rechecks: [(t: Double, after: TimeInterval)] {
            steps.compactMap { if case .recheck(let a) = $0.action { return ($0.t, a) }; return nil }
        }
        var finishes: [(t: Double, index: Int, result: AgentTurnResult)] {
            steps.compactMap { if case .finish(let r) = $0.action { return ($0.t, $0.index, r) }; return nil }
        }
        var finish: AgentTurnResult? { finishes.first?.result }
        var finishT: Double? { finishes.first?.t }
        var mainMessages: [String] {
            events.compactMap { if case .assistantMessage(let s) = $0.event { return s }; return nil }
        }
        var notices: [String] {
            events.compactMap { if case .notice(let s) = $0.event { return s }; return nil }
        }
        /// 대화에 보이지 않는 CLI 진단 (`AgentEvent.diagnostic`).
        var diagnostics: [String] {
            events.compactMap { if case .diagnostic(let s) = $0.event { return s }; return nil }
        }
        /// 사람이 할 일 (`AgentEvent.attention`).
        var attentions: [String] {
            events.compactMap { if case .attention(let s) = $0.event { return s }; return nil }
        }
        /// 실행 중 상태 줄의 진행 문구 (`task_summary` — nil 은 지움).
        var progress: [String?] {
            var out: [String?] = []
            for entry in events {
                if case .progressSummary(let line) = entry.event { out.append(line) }
            }
            return out
        }
        var followUps: [Double] {
            events.compactMap { if case .followUpTurnStarted = $0.event { return $0.t }; return nil }
        }
        var sessions: [String] {
            events.compactMap { if case .sessionEstablished(let id, _, _) = $0.event { return id }; return nil }
        }
        /// 메인 흐름의 도구 행 (id, 이름).
        var mainTools: [(id: String, name: String)] {
            events.compactMap { if case .toolStarted(let id, let name, _) = $0.event { return (id, name) }; return nil }
        }
        /// 하위 흐름으로 감싼 이벤트 (agentID, 안의 이벤트).
        var childEvents: [(agentID: String, event: AgentEvent)] {
            events.compactMap { if case .subAgentEvent(let id, let e) = $0.event { return (id, e) }; return nil }
        }
        func childMessages(_ id: String) -> [String] {
            childEvents.compactMap {
                if $0.agentID == id, case .assistantMessage(let s) = $0.event { return s }
                return nil
            }
        }
        var childMessageCount: Int {
            childEvents.filter { if case .assistantMessage = $0.event { return true }; return false }.count
        }
        func childToolStarts(_ id: String) -> [String] {
            childEvents.compactMap {
                if $0.agentID == id, case .toolStarted(let tid, _, _) = $0.event { return tid }
                return nil
            }
        }
        func childToolResults(_ id: String) -> [String] {
            childEvents.compactMap {
                if $0.agentID == id, case .toolFinished(let tid, _, _, _) = $0.event { return tid }
                return nil
            }
        }
        func childNotices(_ id: String) -> [String] {
            childEvents.compactMap {
                if $0.agentID == id, case .notice(let s) = $0.event { return s }
                return nil
            }
        }
        /// `.subAgent` 알림 (시각, 정보).
        var infos: [(t: Double, info: SubAgentInfo)] {
            events.compactMap { if case .subAgent(let i) = $0.event { return ($0.t, i) }; return nil }
        }
        func lastInfo(_ id: String) -> SubAgentInfo? { infos.last { $0.info.id == id }?.info }
        /// 그 작업의 상태가 바뀐 차례 (같은 상태가 이어지면 하나로).
        func statusSequence(_ id: String) -> [SubAgentInfo.Status] {
            infos.filter { $0.info.id == id }.map(\.info.status)
                .reduce(into: []) { if $0.last != $1 { $0.append($1) } }
        }
        /// 끝 뒤의 동작 (없어야 한다).
        var stepsAfterFinish: Int {
            guard let i = steps.firstIndex(where: { if case .finish = $0.action { return true }; return false })
            else { return 0 }
            return steps.count - i - 1
        }
    }

    static func replay(_ records: [ProbeLogs.Record], _ options: Options = Options()) -> Replay {
        var tracker = ClaudeTurnTracker(waitForBackground: options.waitForBackground, startedAt: base)
        var out = Replay(records: records, tracker: tracker)
        var pending: [Double] = []

        func record(_ actions: [ClaudeTurnTracker.Action], _ t: Double, _ index: Int) {
            for action in actions {
                if case .recheck(let after) = action { pending.append(t + after) }
                out.steps.append(Step(t: t, index: index, action: action))
            }
        }
        /// 어댑터의 `recheck` 작업: 부탁한 때가 되면 `tick`.
        func fireDue(upTo t: Double, index: Int) {
            while let next = pending.min(), next <= t {
                pending.remove(at: pending.firstIndex(of: next)!)
                record(tracker.tick(now: base.addingTimeInterval(next)), next, index)
            }
        }

        for (index, r) in records.enumerated() {
            if let through = options.through, index > through { break }
            fireDue(upTo: r.t, index: index)
            let now = base.addingTimeInterval(r.t)
            if r.driver == "action" {
                if options.honorInterrupt, r.raw["action"] as? String == "interrupt" {
                    record(tracker.interrupt(now: now), r.t, index)
                }
                continue
            }
            if r.driver == "stdout_eof" {
                record(tracker.processEnded(status: nil, now: now), r.t, index)
                continue
            }
            guard let ev = r.event else { continue }
            record(tracker.handle(ev, now: now), r.t, index)
        }
        if options.through == nil { fireDue(upTo: .infinity, index: records.count) }
        for t in options.ticks {
            record(tracker.tick(now: base.addingTimeInterval(t)), t, (options.through ?? records.count) + 1)
        }
        out.tracker = tracker
        return out
    }

    // MARK: - 기록에서 직접 센 기대값

    /// 끝낸 줄까지 기록에 있는 글 블록 수 (메인, 하위).
    static func textBlockCounts(_ r: Replay) -> (main: Int, child: Int) {
        let upTo = min(r.finishes.first?.index ?? (r.records.count - 1), r.records.count - 1)
        var main = 0, child = 0
        for rec in r.records[0...upTo] {
            guard let ev = rec.event, ev["type"] as? String == "assistant",
                  let content = (ev["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            let texts = content.filter { $0["type"] as? String == "text" && !(($0["text"] as? String) ?? "").isEmpty }
            if ev["parent_tool_use_id"] is String { child += texts.count } else { main += texts.count }
        }
        return (main, child)
    }

    /// 그 번호의 `result` 줄.
    static func resultLine(_ r: Replay, _ index: Int) -> [String: Any]? {
        guard r.records.indices.contains(index), let ev = r.records[index].event,
              ev["type"] as? String == "result" else { return nil }
        return ev
    }

    static func near(_ a: Double?, _ b: Double, _ eps: Double = 1e-9) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= eps
    }

    /// 기다린 실행의 걸린 시간 = 실행 시작부터 (밀리초, 부동소수 오차 1).
    static func durationNear(_ result: AgentTurnResult?, seconds: Double) -> Bool {
        guard let ms = result?.usage?.durationMs else { return false }
        return abs(ms - Int((seconds * 1000).rounded())) <= 1
    }

    static let names = ["t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8"]

    // MARK: - 시험

    static func run(_ t: TestKit) async {
        await t.group("Claude 재생: 기록")
        var logs: [String: [ProbeLogs.Record]] = [:]
        for name in names {
            if let records = await ProbeLogs.require(t, probe: probe, name: name) { logs[name] = records }
        }
        await t.equal("실측 기록 \(names.count)개를 읽음", logs.count, names.count)
        let run: (String, Options) -> Replay? = { name, options in logs[name].map { replay($0, options) } }

        await foreground(t, run)
        await background(t, run)
        await workflow(t, run)
        await readOnly(t, run)
        await stopTask(t, run)
        await interrupts(t, run)
        await processEnd(t, run)
        await userMessageWhileWaiting(t, run)
        await everyLog(t, run)
        await notWaiting(t, run)
        await representativeModel(t, logs["t1"])
        await errorWhileWaiting(t, logs["t5"], logs["t6"], logs["t2"])
        await housekeeping(t, logs["t2"])
        await absorbedMidTurn(t, logs["t2"])
        await followUpTurnDeath(t, logs["t7"])
        await usageAfterResult(t, run)
        await earlyTick(t, logs["t2"])
        await unknownTaskEvents(t, logs["t2"])
        await staleNotificationOnResume(t)
        await fakeCLI(t)
    }

    // MARK: t1 — 포그라운드 Agent 둘

    private static func foreground(_ t: TestKit, _ run: (String, Options) -> Replay?) async {
        await t.group("Claude 재생: 포그라운드 (t1)")
        guard let r = run("t1", Options()) else { return }
        let explore = "toolu_01Fixture000000000000113", reader = "toolu_01Fixture000000000000103"
        await t.check("t1 기다림 · 후속 턴 없음", r.settles.isEmpty && r.followUps.isEmpty)
        await t.equal("t1 끝은 한 번", r.finishes.count, 1)
        await t.equal("t1 result(9.25)에서 끝", r.finishT, 9.25)
        await t.equal("t1 메인 응답은 메인 것 하나", r.mainMessages, ["count=3, first=alpha first line"])
        await t.equal("t1 메인 흐름의 도구 행 = Agent 둘 (카드를 붙일 행)",
                      r.mainTools.map { $0.id }, [explore, reader])
        await t.equal("t1 하위의 모델은 하위 안의 메시지에서 (에이전트 탭 · 카드)",
                      [r.lastInfo(explore)?.model, r.lastInfo(reader)?.model], ["claude-sonnet-5", "claude-sonnet-5"])
        await t.equal("t1 하위의 처리 토큰 = 작업 알림의 total_tokens",
                      [r.lastInfo(explore)?.totalTokens, r.lastInfo(reader)?.totalTokens], [17_844, 23_073])
        await t.equal("t1 Explore 안의 호출은 Explore 로", r.childToolStarts(explore),
                      ["toolu_01Fixture000000000000123"])
        await t.equal("t1 Explore 안의 결과도 Explore 로", r.childToolResults(explore),
                      ["toolu_01Fixture000000000000123"])
        await t.equal("t1 read alpha 안의 호출은 read alpha 로", r.childToolStarts(reader),
                      ["toolu_01Fixture000000000000099"])
        await t.check("t1 하위에게 준 요청이 하위 흐름의 첫 줄",
                      r.childNotices(explore).first?.hasPrefix("요청: Use the Glob tool") == true
                        && r.childNotices(reader).first?.hasPrefix("요청: Use the Read tool") == true)
        await t.check("t1 포그라운드가 되풀이한 요청(user 글)은 한 번만",
                      r.childNotices(explore).filter { $0.hasPrefix("요청:") }.count == 1
                        && r.childNotices(reader).filter { $0.hasPrefix("요청:") }.count == 1,
                      "\(r.childNotices(explore)) \(r.childNotices(reader))")
        await t.check("t1 메인 흐름에 하위의 호출이 없음",
                      !r.mainTools.contains { $0.id == "toolu_01Fixture000000000000123" })
        let info = r.lastInfo(explore)
        await t.check("t1 Explore 정보: agent · 포그라운드 · 완료 · 요약 = 답 · task_id",
                      info?.kind == .agent && info?.isBackground == false && info?.status == .completed
                        && info?.summary == "3" && info?.taskID == "a09d3708501e91f83"
                        && info?.title == "count txt files" && info?.detail == "Explore" && info?.ownerID == nil,
                      String(describing: info))
        await t.check("t1 Explore 사용량 = 알림의 usage (17844 · 1)",
                      info?.totalTokens == 17844 && info?.toolUses == 1)
        await t.equal("t1 read alpha 요약", r.lastInfo(reader)?.summary, "alpha first line")
        await t.check("t1 끝난 작업은 멈출 수 없음", info?.canStop == false)
        await t.equal("t1 결과 상태", r.finish?.state, RunState.completed)
        await t.equal("t1 대표 모델 = sonnet (Haiku 아님)", r.finish?.model, sonnet)
        await t.equal("t1 사용량 모델 = sonnet", r.finish?.usage?.model, sonnet)
        await t.check("t1 비용 = result 의 누적 (0.2758825)", near(r.finish?.usage?.reportedCostUSD, 0.2758825))
        await t.equal("t1 기다리지 않은 실행의 걸린 시간 = CLI duration_ms", r.finish?.usage?.durationMs, 8080)
        await t.equal("t1 세션 수립 한 번", r.sessions, ["00000074-0000-4000-8000-000000000000"])
        await t.equal("t1 결과 글", r.finish?.resultText, "count=3, first=alpha first line")

        // 승인 요청이 하위의 호출이면 그 하위로 (can_use_tool 은 호출의 assistant 줄 뒤에 온다).
        let mid = replay(r.records, Options(through: 14))
        let owner = mid.tracker.subAgentOwner(toolUseID: "toolu_01Fixture000000000000123")
        await t.check("t1 하위 안의 호출의 승인 주인 = Explore (이름 = 설명)",
                      owner?.id == explore && owner?.name == "count txt files", String(describing: owner))
        await t.check("t1 메인의 호출은 주인 없음", mid.tracker.subAgentOwner(toolUseID: explore) == nil)
        await t.equal("t1 도는 포그라운드 작업은 멈출 수 있음 (task_id)",
                      mid.tracker.stoppableTaskID(forAgent: explore), "a09d3708501e91f83")
    }

    // MARK: t2 — 백그라운드 Agent 하나

    private static func background(_ t: TestKit, _ run: (String, Options) -> Replay?) async {
        await t.group("Claude 재생: 백그라운드 (t2)")
        guard let r = run("t2", Options()) else { return }
        let agent = "toolu_01Fixture000000000000118"
        let answer = "First lines:\n- beta.txt: \"beta first line\"\n- gamma.txt: \"gamma first line\""
        await t.check("t2 첫 result(5.82)에서 기다림 (남은 1)",
                      r.settles.count == 1 && r.settles.first?.t == 5.82 && r.settles.first?.remaining == 1,
                      "\(r.settles)")
        await t.equal("t2 두 번째 init(10.52)이 후속 턴", r.followUps, [10.52])
        await t.equal("t2 끝은 한 번", r.finishes.count, 1)
        await t.equal("t2 두 번째 result(12.4)에서 끝", r.finishT, 12.4)
        await t.equal("t2 빈 목록(10.45)에서 디바운스, 알림에서 후속 턴 안전장치",
                      r.rechecks.map(\.after), [ClaudeTurnTracker.emptyListDebounce, ClaudeTurnTracker.followUpGrace])
        await t.check("t2 비용 = 두 번째 result (0.222933, 합치지 않음)",
                      near(r.finish?.usage?.reportedCostUSD, 0.222933)
                        && !near(r.finish?.usage?.reportedCostUSD, 0.1473686 + 0.222933),
                      String(describing: r.finish?.usage?.reportedCostUSD))
        await t.check("t2 비용 = 기록의 마지막 total_cost_usd",
                      near(r.finish?.usage?.reportedCostUSD, JSONUtil.double(resultLine(r, 28)?["total_cost_usd"]) ?? -1))
        let usage = r.finish?.usage
        await t.check("t2 토큰 = 두 번째 result 의 modelUsage 합 (입력 1009 · 출력 629 · 캐시 105380/56810)",
                      usage?.inputTokens == 1009 && usage?.outputTokens == 629
                        && usage?.cacheReadTokens == 105380 && usage?.cacheWriteTokens == 56810,
                      String(describing: usage))
        await t.check("t2 걸린 시간 = 실행 시작부터 (12.4초)", durationNear(r.finish, seconds: 12.4),
                      String(describing: usage?.durationMs))
        await t.equal("t2 대표 모델", r.finish?.model, sonnet)
        await t.equal("t2 결과 글 = 마지막 메인 답", r.finish?.resultText, "bg-done: " + answer)
        await t.equal("t2 메인 응답", r.mainMessages, ["launched", "bg-done: " + answer])
        await t.equal("t2 하위의 답은 하위 흐름에만", r.childMessages(agent), [answer])
        await t.equal("t2 백그라운드 하위의 요청 = task_started.prompt (하위 흐름의 첫 줄, user 되풀이가 없다)",
                      r.childNotices(agent),
                      ["요청: Use the Read tool to read beta.txt, then read gamma.txt, then reply with both first lines."])
        await t.equal("t2 에이전트 탭의 '맡은 일' = 그 요청 (안내 머리를 뗀 글)",
                      SubAgentList.assignedTask(r.childNotices(agent).map {
                          ThreadEvent(threadID: "t", runID: "r", kind: .systemNotice, provider: .claude, title: "안내", text: $0)
                      }),
                      "Use the Read tool to read beta.txt, then read gamma.txt, then reply with both first lines.")
        await t.check("t2 요청 줄이 하위 흐름의 맨 앞",
                      { if case .notice(let s)? = r.childEvents.first(where: { $0.agentID == agent })?.event {
                            return s.hasPrefix("요청:") }; return false }())
        await t.equal("t2 하위의 Read 둘", r.childToolStarts(agent),
                      ["toolu_01Fixture000000000000106", "toolu_01Fixture000000000000104"])
        await t.equal("t2 세션 수립 한 번 (후속 init 은 다시 적지 않음)", r.sessions.count, 1)
        await t.check("t2 MCP 안내 없음 (첫 init 에 서버 없음 · 후속 init 의 5개는 알리지 않음)",
                      !r.notices.contains { $0.hasPrefix("MCP") } && !r.diagnostics.contains { $0.hasPrefix("MCP") }
                        && r.attentions.isEmpty)
        let info = r.lastInfo(agent)
        await t.check("t2 하위 정보: 백그라운드 · 완료 · 요약 · 사용량 21785/2",
                      info?.isBackground == true && info?.status == .completed && info?.summary == answer
                        && info?.totalTokens == 21785 && info?.toolUses == 2 && info?.detail == "general-purpose",
                      String(describing: info))
        await t.check("t2 진행 = 마지막 task_progress", info?.progress == "Reading gamma.txt" && info?.lastToolName == "Read")
        await t.equal("t2 상태 차례", r.statusSequence(agent), [.running, .completed])
        await t.equal("t2 끝 뒤 동작 없음", r.stepsAfterFinish, 0)

        // 후속 턴 안전장치: 알림(10.45) 뒤 init 이 오지 않으면 15초 뒤 마지막 결과로.
        if let s = run("t2", Options(through: 25, ticks: [11.95, 25.35, 25.45])) {
            await t.equal("t2 후속 턴이 없으면 15초(25.45)에 끝 — 1.5초 디바운스로는 끝내지 않음", s.finishT, 25.45)
            await t.check("t2 안전장치의 끝 = 첫 result (0.1473686) + 안내",
                          near(s.finish?.usage?.reportedCostUSD, 0.1473686) && s.finish?.state == .completed
                            && s.notices.contains { $0.contains("후속 턴") })
            await t.equal("t2 안전장치의 끝: 첫 result 뒤에 하위가 일했다 → 사용량 미확정",
                          s.finish?.usage?.confirmed, false)
        }
        // 알림이 오기 전(목록만 빔)이면 디바운스 1.5초.
        if let s = run("t2", Options(through: 24, ticks: [11.9, 11.95])) {
            await t.equal("t2 빈 목록 디바운스: 1.4초엔 그대로, 1.5초(11.95)에 끝", s.finishT, 11.95)
        }
        // 기다리는 중 남은 작업이 없으면 중단은 곧바로 취소.
        var quiet = replay(r.records, Options(through: 23)).tracker
        let actions = quiet.interrupt(now: base.addingTimeInterval(10.5))
        let cancelled = actions.compactMap { if case .finish(let x) = $0 { return x }; return nil }.first
        await t.check("t2 목록이 빈 채 기다리는 중 중단 → 곧바로 취소 (background_interrupted · 미확정)",
                      cancelled?.state == .cancelled && cancelled?.terminalReason == "background_interrupted"
                        && cancelled?.usage?.confirmed == false && near(cancelled?.usage?.reportedCostUSD, 0.1473686))
    }

    // MARK: t3 — 워크플로

    private static func workflow(_ t: TestKit, _ run: (String, Options) -> Replay?) async {
        await t.group("Claude 재생: 워크플로 (t3)")
        guard let r = run("t3", Options()) else { return }
        let wf = "toolu_01Fixture000000000000097"
        await t.check("t3 첫 result(13.26)에서 기다림",
                      r.settles.count == 1 && r.settles.first?.t == 13.26 && r.settles.first?.remaining == 1)
        await t.equal("t3 후속 턴 17.24", r.followUps, [17.24])
        await t.equal("t3 두 번째 result(19.81)에서 끝", r.finishT, 19.81)
        await t.check("t3 워크플로는 진행만 — 하위 흐름 이벤트 없음", r.childEvents.isEmpty)
        let info = r.lastInfo(wf)
        await t.check("t3 워크플로 정보: workflow · 이름 · 백그라운드(표시 없이 목록으로) · 완료",
                      info?.kind == .workflow && info?.detail == "summarize-first-lines"
                        && info?.isBackground == true && info?.status == .completed && info?.taskID == "wh8c1ywjr",
                      String(describing: info))
        await t.check("t3 진행: 마지막 도구 · 사용량 63077/7",
                      info?.lastToolName == "read:gamma.txt" && info?.totalTokens == 63077 && info?.toolUses == 7,
                      String(describing: info))
        await t.check("t3 진행 알림이 여러 번 (task_progress 마다)", r.infos.filter { $0.info.id == wf }.count >= 10)
        await t.check("t3 비용 = 마지막 result (0.2917058)", near(r.finish?.usage?.reportedCostUSD, 0.2917058))
        await t.check("t3 결과 글 = 마지막 메인 답", r.finish?.resultText?.hasPrefix("3개 에이전트가") == true)
        let mid = replay(r.records, Options(through: 19))
        await t.check("t3 Workflow 승인은 메인의 것", mid.tracker.subAgentOwner(toolUseID: wf) == nil)
        await t.equal("t3 도는 워크플로는 멈출 수 있음", mid.tracker.stoppableTaskID(forAgent: wf), "wh8c1ywjr")
    }

    // MARK: t4 — 읽기 전용

    private static func readOnly(_ t: TestKit, _ run: (String, Options) -> Replay?) async {
        await t.group("Claude 재생: 읽기 전용 (t4)")
        // 읽기 전용 턴은 기다리지 않는다 (`RunSession` 이 waitForBackground = false 로 보낸다).
        guard let r = run("t4", Options(waitForBackground: false)) else { return }
        let agent = "toolu_01Fixture000000000000117"
        await t.equal("t4 result(23.0)에서 끝", r.finishT, 23.0)
        await t.check("t4 남은 작업 없음 → 멈춤 안내 없음", !r.notices.contains { $0.contains("백그라운드 작업") })
        await t.equal("t4 하위의 ToolSearch 셋", r.childToolStarts(agent),
                      ["toolu_01Fixture000000000000124", "toolu_01Fixture000000000000121",
                       "toolu_01Fixture000000000000119"])
        await t.check("t4 하위에게 준 요청", r.childNotices(agent).first?.hasPrefix("요청: Create a file named probe.txt") == true)
        await t.equal("t4 메인 응답 하나", r.mainMessages.count, 1)
        await t.check("t4 비용 (0.29720759999999996)", near(r.finish?.usage?.reportedCostUSD, 0.29720759999999996))

        let logged = r.records.first { $0.driver == "start" }?.raw["args"] as? [String] ?? []
        let disallowed = logged.firstIndex(of: "--disallowedTools").map { Array(logged[($0 + 1)...]) } ?? []
        await t.check("t4 실측에 쓴 쓰기 도구 넷은 앱의 목록 안", !disallowed.isEmpty
                        && Set(disallowed).isSubset(of: Set(ClaudeAdapter.writeTools)), "\(disallowed)")
        await t.check("t4 앱은 Workflow 도 뺀다 (t3: 넷을 빼도 남아 승인을 묻는다)",
                      ClaudeAdapter.writeTools.contains("Workflow"))
        let request = AgentTurnRequest(runID: "r", prompt: "p", workingDirectory: URL(fileURLWithPath: "/tmp"),
                                       readOnly: true)
        let args = ClaudeAdapter.arguments(for: request, permissionMode: "manual")
        await t.equal("t4 가변 인자 --disallowedTools 는 맨 끝",
                      Array(args.suffix(ClaudeAdapter.writeTools.count + 1)), ["--disallowedTools"] + ClaudeAdapter.writeTools)
    }

    // MARK: t5 — 대기 중 stop_task

    private static func stopTask(_ t: TestKit, _ run: (String, Options) -> Replay?) async {
        await t.group("Claude 재생: 작업 멈추기 (t5)")
        guard let r = run("t5", Options()) else { return }
        let agent = "toolu_01Fixture000000000000112", shell = "toolu_01Fixture000000000000114"
        await t.equal("t5 기다림 둘 (4.77 · 11.49)", r.settles.map(\.t), [4.77, 11.49])
        await t.equal("t5 후속 턴 둘 (9.77 · 29.48)", r.followUps, [9.77, 29.48])
        await t.equal("t5 끝은 한 번", r.finishes.count, 1)
        await t.equal("t5 stop_task 뒤 목록이 잠깐 빔(13.12) — 끝내지 않고 31.27 에서 끝", r.finishT, 31.27)
        await t.check("t5 빈 목록(13.12)에서 디바운스를 부탁했다",
                      r.rechecks.contains { $0.t == 13.12 && $0.after == ClaudeTurnTracker.emptyListDebounce })
        await t.check("t5 비용 = 마지막 result (0.19206399999999998)",
                      near(r.finish?.usage?.reportedCostUSD, 0.19206399999999998))
        await t.check("t5 결과 글", r.finish?.resultText?.hasPrefix("bg-done: The agent reports") == true)
        let shellInfo = r.lastInfo(shell)
        await t.check("t5 하위가 띄운 셸: shell · 백그라운드 · 주인 = sleeper · 멈춤",
                      shellInfo?.kind == .shell && shellInfo?.isBackground == true && shellInfo?.ownerID == agent
                        && shellInfo?.status == .stopped && shellInfo?.taskID == "byw33s2bw",
                      String(describing: shellInfo))
        await t.equal("t5 sleeper 는 끝났다 다시 깨어 끝남 (같은 행)", r.statusSequence(agent),
                      [.running, .completed, .running, .completed])
        await t.equal("t5 하위의 글 둘은 하위 흐름에", r.childMessages(agent).count, 2)
        await t.check("t5 다시 깨어난 task_started 의 prompt(<task-notification>)는 요청이 아님",
                      r.childNotices(agent).filter { $0.hasPrefix("요청:") }.count == 1
                        && !r.childNotices(agent).contains { $0.contains("task-notification") },
                      "\(r.childNotices(agent))")
        // 첫 init: 커넥터 A · B · E · D = pending, C = needs-auth (기록의 커넥터 이름은 가렸다). 상태 목록은 진단(대화에 보이지 않는다),
        // 인증이 필요한 서버만 사람이 할 일로 한 줄 — 둘 다 첫 init 에서만 (후속 init 둘은 알리지 않는다).
        await t.equal("t5 MCP 상태 목록은 첫 init 에서만 · 진단", r.diagnostics.filter { $0.hasPrefix("MCP") },
                      ["MCP 서버 상태(CLI 보고): claude.ai Connector A=pending, claude.ai Connector B=pending, claude.ai Connector E=pending, "
                       + "claude.ai Connector C=needs-auth, claude.ai Connector D=pending"])
        await t.equal("t5 인증이 필요한 서버만 할 일 한 줄", r.attentions,
                      [CLINoticeText.mcpNeedsAuth(["claude.ai Connector C"])])
        await t.check("t5 MCP 는 대화의 안내(notice)로 내지 않는다", !r.notices.contains { $0.hasPrefix("MCP") })
        await t.equal("t5 세션 수립 한 번 (init 셋)", r.sessions.count, 1)

        // 기록 도구가 stop_task 를 보낸 때: 앱이 셸 행의 id 로 보낼 task_id 가 기록과 같다.
        let sent = r.records.first { ($0.sent?["request"] as? [String: Any])?["subtype"] as? String == "stop_task" }
        let sentTaskID = (sent?.sent?["request"] as? [String: Any])?["task_id"] as? String
        let atStop = replay(r.records, Options(through: 30)).tracker
        await t.equal("t5 셸 행 id → stop_task 의 task_id (기록과 같음)",
                      atStop.stoppableTaskID(forAgent: shell), sentTaskID)
        await t.check("t5 그때 끝나 있던 sleeper 는 멈출 수 없음", atStop.stoppableTaskID(forAgent: agent) == nil)
        let owner = atStop.subAgentOwner(toolUseID: shell)
        await t.check("t5 셸 호출의 승인 주인 = sleeper", owner?.id == agent && owner?.name == "sleeper")

        // 디바운스 판정 (시계를 직접): 빈 목록(13.12)이 그대로면 1.5초에 끝, 그 전엔 그대로.
        if let s = run("t5", Options(through: 35, ticks: [14.12, 14.61, 14.62])) {
            await t.equal("t5 빈 목록이 그대로면 1.5초(14.62)에 끝 — 1.0 · 1.49초엔 그대로", s.finishT, 14.62)
            await t.check("t5 그 끝 = 두 번째 result (0.1492373) · 완료",
                          near(s.finish?.usage?.reportedCostUSD, 0.1492373) && s.finish?.state == .completed)
        }
        // 다시 찬 뒤(13.13)엔 부탁한 때가 와도 끝내지 않는다.
        if let s = run("t5", Options(through: 37, ticks: [14.62, 20])) {
            await t.check("t5 목록이 다시 차면 디바운스가 끝내지 않음", s.finishes.isEmpty)
        }
    }

    // MARK: t6 — 대기 중 interrupt

    private static func interrupts(_ t: TestKit, _ run: (String, Options) -> Replay?) async {
        await t.group("Claude 재생: 중단 (t6)")
        guard let r = run("t6", Options()) else { return }
        let agent = "toolu_01Fixture000000000000101", shell = "toolu_01Fixture000000000000098"
        await t.equal("t6 첫 result(8.31)에서 기다림", r.settles.map(\.t), [8.31])
        await t.check("t6 중단(16.65) 때 남은 작업 둘을 알림",
                      r.notices.contains("백그라운드 작업 2개를 함께 멈춥니다."))
        await t.equal("t6 끝은 한 번", r.finishes.count, 1)
        await t.equal("t6 목록이 비면(16.66) 곧바로 끝 — result 없음", r.finishT, 16.66)
        await t.equal("t6 상태 = 취소", r.finish?.state, RunState.cancelled)
        await t.equal("t6 terminalReason", r.finish?.terminalReason, "background_interrupted")
        await t.check("t6 오류 아님 · 사용량 미확정 · 알고 있는 비용(0.0867598)",
                      r.finish?.isError == false && r.finish?.usage?.confirmed == false
                        && near(r.finish?.usage?.reportedCostUSD, 0.0867598))
        await t.check("t6 걸린 시간 = 실행 시작부터 (16.66초)", durationNear(r.finish, seconds: 16.66))
        await t.check("t6 하위 · 셸 모두 멈춤",
                      r.lastInfo(agent)?.status == .stopped && r.lastInfo(shell)?.status == .stopped)
        await t.check("t6 셸은 알림 전에 끝나 실행과 함께 멈춤으로 닫힘", r.lastInfo(shell)?.endedAt != nil)
        await t.equal("t6 끝 뒤 동작 없음", r.stepsAfterFinish, 0)
        await t.equal("t6 하위 안의 중단 표시는 요청이 아니라 \"중단됨\"", r.childNotices(agent),
                      ["요청: Run the Bash command: sleep 40 (in the foreground, not in background). Then reply with: slept.",
                       "중단됨"])

        // 메인 턴이 도는 중의 중단은 트래커가 끝내지 않는다 — 그 턴의 result 가 취소로 끝낸다.
        var active = replay(r.records, Options(through: 8)).tracker
        let during = active.interrupt(now: base.addingTimeInterval(7))
        await t.check("t6 메인 턴 중 중단은 빈 배열 (어댑터가 interrupt 를 보낸다)",
                      during.isEmpty && !active.isFinished && active.userCancelled)
    }

    // MARK: t7 — 기다리는 중 프로세스가 끝남

    private static func processEnd(_ t: TestKit, _ run: (String, Options) -> Replay?) async {
        await t.group("Claude 재생: 도중 종료 (t7)")
        guard let r = run("t7", Options()) else { return }
        let agent = "toolu_01Fixture000000000000108", shell = "toolu_01Fixture000000000000111"
        await t.equal("t7 기다림 둘 (6.89 · 16.06 — 후속 result 뒤에도 하위의 셸이 남음)",
                      r.settles.map(\.t), [6.89, 16.06])
        await t.equal("t7 후속 턴 13.73", r.followUps, [13.73])
        await t.equal("t7 출력이 닫힘(21.76) → 마지막 결과로 끝", r.finishT, 21.76)
        await t.check("t7 실패로 만들지 않음 (완료 · 안내)",
                      r.finish?.state == .completed && r.notices.contains { $0.contains("종료되었습니다") })
        await t.equal("t7 마지막 결과 뒤의 사용량은 모른다 → 미확정", r.finish?.usage?.confirmed, false)
        await t.check("t7 비용 = 마지막 result (0.15711010000000003)",
                      near(r.finish?.usage?.reportedCostUSD, 0.15711010000000003))
        await t.check("t7 하위가 띄운 셸: 주인 = sleeper · 멈춤",
                      r.lastInfo(shell)?.ownerID == agent && r.lastInfo(shell)?.status == .stopped)
        await t.equal("t7 sleeper 완료", r.lastInfo(agent)?.status, SubAgentInfo.Status.completed)
    }

    // MARK: t8 — 기다리는 중 새 메시지 (앱은 보내지 않지만, CLI 의 줄은 그대로 넣는다)

    private static func userMessageWhileWaiting(_ t: TestKit, _ run: (String, Options) -> Replay?) async {
        await t.group("Claude 재생: 여러 후속 턴 (t8)")
        guard let r = run("t8", Options()) else { return }
        let agent = "toolu_01Fixture000000000000109"
        await t.equal("t8 기다림 셋", r.settles.map(\.t), [6.56, 12.09, 15.96])
        await t.equal("t8 후속 턴 셋", r.followUps, [10.76, 14.65, 50.67])
        await t.equal("t8 끝은 한 번", r.finishes.count, 1)
        await t.equal("t8 목록이 잠깐 빔(49.41) — 끝내지 않고 51.95 에서 끝", r.finishT, 51.95)
        await t.check("t8 비용 = 마지막 result (0.16638680000000003)",
                      near(r.finish?.usage?.reportedCostUSD, 0.16638680000000003))
        await t.equal("t8 결과 글", r.finish?.resultText, "bg-done: slept.")
        await t.equal("t8 메인 응답 넷", r.mainMessages.count, 4)
        await t.equal("t8 하위의 마지막 답은 하위 흐름에", r.childMessages(agent).last, "slept.")
        await t.equal("t8 세션 수립 한 번 (init 넷)", r.sessions.count, 1)
    }

    // MARK: 모든 기록

    private static func everyLog(_ t: TestKit, _ run: (String, Options) -> Replay?) async {
        await t.group("Claude 재생: 공통")
        for name in names {
            // t4 는 읽기 전용 실행 — 기다리지 않는다.
            guard let r = run(name, Options(waitForBackground: name != "t4")) else { continue }
            let counts = textBlockCounts(r)
            await t.check("\(name) 메인 글 \(counts.main) · 하위 글 \(counts.child) 가 섞이지 않음",
                          r.mainMessages.count == counts.main && r.childMessageCount == counts.child,
                          "메인 \(r.mainMessages.count) · 하위 \(r.childMessageCount)")
            await t.check("\(name) 끝은 정확히 한 번 · 끝 뒤 동작 없음", r.finishes.count == 1 && r.stepsAfterFinish == 0)
            await t.equal("\(name) 대표 모델 = sonnet", r.finish?.model, sonnet)
            await t.check("\(name) 끝날 때 도는 작업 없음",
                          r.tracker.subAgents.allSatisfy { $0.status != .running })
            await t.check("\(name) 실측의 task_* 는 모두 아는 이벤트 (모름 진단 없음)",
                          !r.diagnostics.contains { $0.hasPrefix("알 수 없는 작업 이벤트") }
                            && !r.notices.contains { $0.hasPrefix("알 수 없는 작업 이벤트") }, "\(r.diagnostics)")
        }
    }

    // MARK: 기다리지 않는 실행

    private static func notWaiting(_ t: TestKit, _ run: (String, Options) -> Replay?) async {
        await t.group("Claude 재생: 기다리지 않음")
        let firstResult: [String: (t: Double, remaining: Int)] = [
            "t1": (9.25, 0), "t2": (5.82, 1), "t3": (13.26, 1), "t4": (23.0, 0),
            "t5": (4.77, 1), "t6": (8.31, 1), "t7": (6.89, 1), "t8": (6.56, 1),
        ]
        for name in names {
            guard let r = run(name, Options(waitForBackground: false)), let expected = firstResult[name] else { continue }
            await t.check("\(name) 첫 result(\(expected.t))에서 끝 · 기다림 없음",
                          r.finishT == expected.t && r.settles.isEmpty && r.finishes.count == 1)
            let notice = "백그라운드 작업 \(expected.remaining)개가 실행과 함께 멈췄습니다"
            await t.check("\(name) 남은 작업 \(expected.remaining)개 안내",
                          expected.remaining == 0 ? !r.notices.contains { $0.contains("실행과 함께 멈췄습니다") }
                                                  : r.notices.contains(notice))
            await t.check("\(name) 남은 작업은 멈춤으로 닫힘", r.tracker.subAgents.allSatisfy { $0.status != .running })
        }
        if let r = run("t2", Options(waitForBackground: false)) {
            await t.check("t2 기다리지 않으면 첫 result 의 비용 · CLI 걸린 시간",
                          near(r.finish?.usage?.reportedCostUSD, 0.1473686) && r.finish?.usage?.durationMs == 4647)
            // 끝 전에 온 것은 task_started 의 요청 줄 하나뿐이다.
            await t.check("t2 기다리지 않으면 백그라운드 하위는 실행과 함께 멈춤 (끝 뒤의 하위 줄은 버림)",
                          r.childEvents.count == 1 && r.childNotices("toolu_01Fixture000000000000118").count == 1 && r.lastInfo("toolu_01Fixture000000000000118")?.status == .stopped)
        }
        if let r = run("t1", Options(waitForBackground: false)) {
            await t.check("t1 기다리지 않아도 하위의 호출은 하위 흐름으로",
                          r.childToolStarts("toolu_01Fixture000000000000113") == ["toolu_01Fixture000000000000123"])
        }
    }

    // MARK: 오류 · 한도 결과 · 중단의 다른 끝

    /// 후속 턴의 result 가 오류 · 한도면 남은 작업이 있어도 바로 끝낸다 (자동 인계가 돈다). 중단의 다른 끝(출력이 닫힘 ·
    /// 8초 감시) · 재개 복구로 새로 만든 트래커에 넘긴 중단도 본다.
    private static func errorWhileWaiting(_ t: TestKit, _ t5: [ProbeLogs.Record]?, _ t6: [ProbeLogs.Record]?,
                                          _ t2: [ProbeLogs.Record]?) async {
        await t.group("Claude 재생: 기다리는 중의 오류 · 중단")
        if var records = t5, var ev = records[29].event, ev["type"] as? String == "result" {
            // t5 의 두 번째 result(11.49, 셸 하나가 남음)를 한도 오류로 바꾼다.
            ev["is_error"] = true
            ev["result"] = "Claude AI usage limit reached"
            records[29].event = ev
            let r = replay(records)
            await t.equal("한도 result(11.49)에서 바로 끝 — 남은 셸을 기다리지 않음", r.finishT, 11.49)
            await t.equal("기다림은 첫 result(4.77) 하나", r.settles.map(\.t), [4.77])
            await t.equal("상태 = 한도 도달", r.finish?.state, RunState.rateLimited)
            await t.check("비용 = 그 result 의 누적 (0.1492373)", near(r.finish?.usage?.reportedCostUSD, 0.1492373))
            await t.check("남은 작업 안내", r.notices.contains("백그라운드 작업 1개가 실행과 함께 멈췄습니다"))
            await t.equal("남은 셸은 멈춤으로 닫힘", r.lastInfo("toolu_01Fixture000000000000114")?.status,
                          SubAgentInfo.Status.stopped)
            await t.equal("끝 뒤 동작 없음", r.stepsAfterFinish, 0)
        } else {
            await t.check("t5 의 29번 줄이 result", false)
        }
        if let records = t6 {
            // 중단 뒤 목록이 비기 전에 출력이 닫혔다 → 취소.
            var tracker = replay(records, Options(through: 22)).tracker
            let first = tracker.interrupt(now: base.addingTimeInterval(16.65))
            let ended = tracker.processEnded(status: nil, now: base.addingTimeInterval(17))
            let result = ended.compactMap { if case .finish(let x) = $0 { return x }; return nil }.first
            await t.check("t6 중단 뒤 목록이 남은 채 출력이 닫힘 → 취소 (background_interrupted · 미확정)",
                          !first.contains { if case .finish = $0 { return true }; return false }
                            && result?.state == .cancelled && result?.terminalReason == "background_interrupted"
                            && result?.usage?.confirmed == false && near(result?.usage?.reportedCostUSD, 0.0867598),
                          String(describing: result))
        }
        if let records = t2 {
            // 8초 감시가 프로세스를 정리했다 → 첫 result 의 사용량으로 취소.
            var tracker = replay(records, Options(through: 23)).tracker
            let actions = tracker.cancel(reason: "interrupt_timeout_killed", now: base.addingTimeInterval(20))
            let result = actions.compactMap { if case .finish(let x) = $0 { return x }; return nil }.first
            await t.check("t2 8초 감시의 정리 → 취소 · 첫 result 의 비용 (0.1473686) · 미확정",
                          result?.state == .cancelled && result?.terminalReason == "interrupt_timeout_killed"
                            && near(result?.usage?.reportedCostUSD, 0.1473686) && result?.usage?.confirmed == false,
                          String(describing: result))
            await t.check("끝난 뒤의 정리는 아무것도 하지 않음",
                          tracker.cancel(reason: "x").isEmpty && tracker.processEnded(status: 0).isEmpty)

            // 재개 복구: 정리하는 동안 누른 중단을 새 트래커에 넘긴다 (턴 전이라 표시만) → 그 뒤 result 는 취소.
            var fresh = ClaudeTurnTracker(waitForBackground: true, startedAt: base)
            let marked = fresh.interrupt(now: base)
            var actions2: [ClaudeTurnTracker.Action] = []
            for r in records.prefix(13) { if let ev = r.event { actions2 += fresh.handle(ev, now: base.addingTimeInterval(r.t)) } }
            let settled = actions2.contains { if case .settle = $0 { return true }; return false }
            let finished = actions2.compactMap { if case .finish(let x) = $0 { return x }; return nil }.first
            await t.check("새 트래커에 넘긴 중단: 표시만 하고, 남은 작업이 있어도 기다리지 않고 취소",
                          marked.isEmpty && !settled && finished?.state == .cancelled,
                          String(describing: finished?.state))
        }
    }

    // MARK: 이어받은 세션에 남은 작업 알림

    /// 이어받은 세션에 전 실행의 백그라운드 작업 알림이 남아 있으면 CLI 는 그 알림을 한 턴으로 먼저 처리하고 result 를 낸 뒤
    /// 우리 메시지를 처리한다 (2026-09-29 실측: 남은 알림 → init → result → init → 되돌린 우리 글 → 답 → result).
    /// 첫 result 에서 끝내 사진을 붙인 메시지가 처리되지 않고 버려졌다.
    private static func staleNotificationOnResume(_ t: TestKit) async {
        await t.group("Claude 재생: 이어받은 세션의 남은 알림")
        func result(_ text: String) -> [String: Any] {
            ["type": "result", "subtype": "success", "is_error": false, "result": text, "num_turns": 1, "session_id": sid,
             "duration_ms": 10, "usage": ["input_tokens": 1, "output_tokens": 1] as [String: Any]]
        }
        let replayed: [String: Any] = ["type": "user", "isReplay": true, "session_id": sid,
                                       "message": ["role": "user", "content": "Reply with exactly: HELLO"] as [String: Any]]
        let lines: [(Double, [String: Any])] = [
            (0.1, sys("task_notification", ["task_id": "old-task", "status": "stopped"])),
            (0.2, sys("init", ["model": sonnet])), (0.3, text("No response requested.")), (0.4, result("No response requested.")),
            (0.5, sys("init", ["model": sonnet])), (0.6, replayed), (0.8, text("HELLO")), (1.0, result("HELLO")),
        ]
        let r = replay(synthetic(lines))
        await t.check("남은 알림의 result 에서 끝내지 않고 우리 답의 result 에서 끝낸다",
                      r.finishes.count == 1 && r.finishes.first?.index == 7 && r.finish?.state == .completed
                        && r.finish?.resultText == "HELLO", "\(r.finishes.map(\.index)) \(String(describing: r.finish?.resultText))")
        await t.check("그 턴의 말은 우리 답이 아니라 안내 줄로",
                      r.mainMessages == ["HELLO"] && r.notices.contains { $0.contains("No response requested.") })
        // 되돌림을 모르는 CLI · 우리 턴이 끝내 열리지 않음: 기다리다 실패로 끝낸다 (다시 보내게 — 조용히 삼키지 않는다).
        let missing = replay(synthetic(Array(lines.prefix(4))))
        await t.check("우리 턴이 열리지 않으면 실패로 끝낸다", missing.finish?.state == .failed
                        && missing.finish?.terminalReason == "own_turn_missing", String(describing: missing.finish?.state))
        // 남은 알림이 없으면 지금처럼 첫 result 에서 끝낸다.
        let plain = replay(synthetic([(0.1, sys("init", ["model": sonnet])), (0.2, replayed), (0.3, text("HI")), (0.4, result("HI"))]))
        await t.check("남은 알림이 없으면 첫 result 에서", plain.finishes.first?.index == 3 && plain.finish?.resultText == "HI")
    }

    // MARK: 일이 아닌 작업 (ambient · skip_transcript)

    static func synthetic(_ lines: [(Double, [String: Any])]) -> [ProbeLogs.Record] {
        lines.map { ProbeLogs.Record(t: $0.0, event: $0.1, driver: nil, raw: ["t": $0.0, "ev": $0.1]) }
    }

    static let sid = "s-synthetic"
    static func sys(_ subtype: String, _ extra: [String: Any]) -> [String: Any] {
        extra.merging(["type": "system", "subtype": subtype, "session_id": sid]) { a, _ in a }
    }
    static func toolUse(_ id: String, _ name: String, parent: String? = nil) -> [String: Any] {
        var obj: [String: Any] = ["type": "assistant", "session_id": sid,
                                  "message": ["model": sonnet, "content": [["type": "tool_use", "id": id, "name": name,
                                                                            "input": [:] as [String: Any]]]]]
        if let parent { obj["parent_tool_use_id"] = parent }
        return obj
    }
    static func toolResult(_ id: String) -> [String: Any] {
        ["type": "user", "session_id": sid,
         "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]]]
    }
    static func text(_ s: String) -> [String: Any] {
        ["type": "assistant", "session_id": sid, "message": ["model": sonnet, "content": [["type": "text", "text": s]]]]
    }

    /// 2.1.276 스키마: `background_tasks_changed.tasks[].ambient` · `task_started` · `task_notification` 의
    /// `ambient` / `skip_transcript`. 아티팩트 감시(`monitor_ws`)는 스스로 끝나지 않는다 — 기다리면 영영 끝나지 않는다.
    private static func housekeeping(_ t: TestKit, _ t2: [ProbeLogs.Record]?) async {
        await t.group("Claude 재생: 일이 아닌 작업 (ambient)")
        guard let result = t2?.first(where: { $0.event?["type"] as? String == "result" })?.event else {
            await t.check("t2 의 result 줄", false)
            return
        }
        let ambientOnly = synthetic([
            (0.1, sys("init", ["model": sonnet])),
            (1.0, sys("task_started", ["task_id": "w1", "tool_use_id": "w1", "description": "artifact watcher",
                                       "task_type": "monitor_ws", "ambient": true, "skip_transcript": true])),
            (1.0, sys("background_tasks_changed", ["tasks": [["task_id": "w1", "task_type": "monitor_ws",
                                                              "description": "artifact watcher", "ambient": true]]])),
            (2.0, text("done")),
            (2.1, result),
        ])
        let r = replay(ambientOnly)
        await t.check("ambient 만 남은 목록 + 완료 result → 기다리지 않고 끝",
                      r.settles.isEmpty && r.finishT == 2.1 && r.finish?.state == .completed, "\(r.settles)")
        await t.check("ambient 작업은 멈춤 안내에 세지 않음", !r.notices.contains { $0.contains("실행과 함께 멈췄습니다") })
        await t.check("ambient 작업은 화면 행 · 작업 표에 없음",
                      r.infos.isEmpty && r.tracker.subAgents.isEmpty && r.tracker.stoppableTaskID(forAgent: "w1") == nil)
        let notWaiting = replay(ambientOnly, Options(waitForBackground: false))
        await t.check("기다리지 않는 실행도 ambient 작업을 멈춤 안내에 세지 않음",
                      notWaiting.finishT == 2.1 && !notWaiting.notices.contains { $0.contains("실행과 함께 멈췄습니다") })

        // 진짜 백그라운드 Agent 하나 + ambient 감시: 감시는 세지 않고, 하위가 끝나 후속 턴이 끝나면 끝.
        // skip_transcript 작업의 알림은 후속 턴을 기다리게 하지 않고, 그 작업의 글은 화면에 내지 않는다.
        let mixed = synthetic([
            (0.1, sys("init", ["model": sonnet])),
            (0.5, toolUse("A", "Agent")),
            (0.5, sys("task_started", ["task_id": "a1", "tool_use_id": "A", "description": "bg", "task_type": "local_agent",
                                       "is_backgrounded": true, "prompt": "do it"])),
            (0.6, sys("task_started", ["task_id": "f1", "tool_use_id": "F", "description": "fork", "task_type": "local_agent",
                                       "is_backgrounded": true, "skip_transcript": true, "prompt": "housekeeping"])),
            (0.6, sys("background_tasks_changed", ["tasks": [
                ["task_id": "a1", "task_type": "local_agent", "description": "bg"],
                ["task_id": "f1", "task_type": "local_agent", "description": "fork", "ambient": true],
                ["task_id": "w1", "task_type": "monitor_ws", "description": "watch", "ambient": true]]])),
            (0.7, toolUse("F-1", "Read", parent: "F")),
            (1.0, text("launched")),
            (1.1, result),
            (2.0, sys("task_notification", ["task_id": "f1", "tool_use_id": "F", "status": "completed",
                                            "skip_transcript": true, "ambient": true])),
            (3.0, sys("background_tasks_changed", ["tasks": [
                ["task_id": "w1", "task_type": "monitor_ws", "description": "watch", "ambient": true]]])),
            (3.0, sys("task_notification", ["task_id": "a1", "tool_use_id": "A", "status": "completed", "summary": "ok"])),
            (3.1, sys("init", ["model": sonnet])),
            (3.5, text("bg-done")),
            (3.6, result),
        ])
        let m = replay(mixed)
        await t.check("ambient 을 뺀 남은 작업 1개로 기다림", m.settles.count == 1 && m.settles.first?.remaining == 1,
                      "\(m.settles)")
        await t.equal("후속 턴의 result(3.6)에서 끝 — 감시가 남아도", m.finishT, 3.6)
        await t.check("skip_transcript 작업: 행 · 요청 · 하위 글 없음",
                      !m.infos.contains { $0.info.id == "F" } && !m.childEvents.contains { $0.agentID == "F" })
        await t.equal("진짜 하위의 요청 줄은 task_started.prompt", m.childNotices("A"), ["요청: do it"])
        await t.check("작업 표에는 진짜 하위만", m.tracker.subAgents.map(\.id) == ["A"])
        // skip_transcript 작업의 알림만 온 뒤(목록엔 ambient 만)는 후속 턴 안전장치가 아니라 디바운스.
        let fork = replay(mixed, Options(through: 8))
        await t.check("skip_transcript 작업의 알림은 후속 턴을 기다리게 하지 않음",
                      !fork.tracker.awaitingFollowUp && !fork.rechecks.contains { $0.after == ClaudeTurnTracker.followUpGrace })
    }

    // MARK: 턴 중에 끝난 메인 작업 (absorbed_mid_turn)

    /// 메인 턴이 도구를 부르는 사이에 메인이 띄운 백그라운드 작업이 끝나면 CLI 는 그 알림을 같은 턴에 흡수한다
    /// (`absorbed_mid_turn`) — 후속 턴이 열리지 않는다. 15초 안전장치 · "후속 턴이 열리지 않아" 안내 없이 디바운스로 끝.
    private static func absorbedMidTurn(_ t: TestKit, _ t2: [ProbeLogs.Record]?) async {
        await t.group("Claude 재생: 턴 중에 끝난 작업")
        guard let template = t2?.first(where: { $0.event?["type"] as? String == "result" })?.event else {
            await t.check("t2 의 result 줄", false)
            return
        }
        func result(_ text: String) -> [String: Any] { template.merging(["result": text]) { _, b in b } }
        var lines: [(Double, [String: Any])] = [
            (0.1, sys("init", ["model": sonnet])),
            (0.5, toolUse("A", "Agent")),
            (0.5, sys("task_started", ["task_id": "a1", "tool_use_id": "A", "description": "bg", "task_type": "local_agent",
                                       "is_backgrounded": true, "prompt": "do it"])),
            (0.5, sys("background_tasks_changed", ["tasks": [["task_id": "a1", "task_type": "local_agent", "description": "bg"]]])),
            (1.0, toolUse("B", "Bash")),
            (4.0, sys("background_tasks_changed", ["tasks": [] as [[String: Any]]])),
            (4.0, sys("task_notification", ["task_id": "a1", "tool_use_id": "A", "status": "completed", "summary": "ok"])),
            (4.1, toolResult("B")),
            (5.0, text("both done")),
            (5.1, result("both done")),
        ]
        let r = replay(synthetic(lines))
        await t.check("result(5.1)에서 남은 0 으로 잠깐 기다림 (후속 턴이 올 수 있다)",
                      r.settles.count == 1 && r.settles.first?.remaining == 0, "\(r.settles)")
        await t.equal("15초 안전장치가 아니라 1.5초 디바운스", r.rechecks.map(\.after), [ClaudeTurnTracker.emptyListDebounce])
        await t.check("디바운스(6.6)에 끝 · 완료 · \"후속 턴\" 안내 없음",
                      near(r.finishT, 6.6, 1e-6) && r.finish?.state == .completed
                        && !r.notices.contains { $0.contains("후속 턴") }, "\(String(describing: r.finishT)) \(r.notices)")
        await t.equal("결과 글", r.finish?.resultText, "both done")

        // 흡수되지 않았으면 CLI 가 곧 후속 턴을 연다 → 그 result 에서 끝.
        lines += [(5.2, sys("init", ["model": sonnet])), (5.8, text("bg-done")), (5.9, result("bg-done"))]
        let f = replay(synthetic(lines))
        await t.equal("흡수되지 않으면 후속 턴(5.2)", f.followUps, [5.2])
        await t.equal("후속 턴의 result(5.9)에서 끝", f.finishT, 5.9)
        await t.equal("결과 글 = 후속 턴의 답", f.finish?.resultText, "bg-done")
    }

    // MARK: 후속 턴 도중 프로세스가 끝남

    static func finished(_ actions: [ClaudeTurnTracker.Action]) -> AgentTurnResult? {
        actions.compactMap { if case .finish(let x) = $0 { return x }; return nil }.first
    }
    static func noticesIn(_ actions: [ClaudeTurnTracker.Action]) -> [String] {
        actions.compactMap { if case .emit(.notice(let s)) = $0 { return s }; return nil }
    }
    static func rechecksIn(_ actions: [ClaudeTurnTracker.Action]) -> [TimeInterval] {
        actions.compactMap { if case .recheck(let a) = $0 { return a }; return nil }
    }

    /// 후속 턴이 열린 뒤(그 턴의 result 전) 프로세스가 죽으면 그 턴의 답을 받지 못했다 — 완료가 아니라 실패.
    /// 기다리는 중의 종료(t7)는 지금처럼 마지막 결과로 끝내되 종료 코드를 알리고 사용량은 미확정.
    private static func followUpTurnDeath(_ t: TestKit, _ t7: [ProbeLogs.Record]?) async {
        await t.group("Claude 재생: 후속 턴 도중 종료")
        guard let records = t7 else { return }
        // 31번 줄 = 후속 init(13.73). 그 턴의 result(16.06) 전에 죽는다.
        let inTurn = replay(records, Options(through: 31))
        await t.check("t7 31번 줄에서 후속 턴 도중", inTurn.followUps == [13.73] && inTurn.tracker.turnActive
                        && !inTurn.tracker.isFinished)

        var a = inTurn.tracker
        let died = a.processEnded(status: 1, signaled: false, stderr: "warn\nError: boom\n",
                                  now: base.addingTimeInterval(14))
        let r1 = finished(died)
        await t.check("후속 턴 도중 종료(코드 1) → 실패 · exit_1 · 오류 · 미확정",
                      r1?.state == .failed && r1?.terminalReason == "exit_1" && r1?.isError == true
                        && r1?.usage?.confirmed == false, String(describing: r1))
        await t.equal("오류 글 = stderr 끝부분", r1?.errorMessage, "warn\nError: boom")
        await t.check("비용은 알고 있는 마지막 result(6.89) 의 누적",
                      near(r1?.usage?.reportedCostUSD, JSONUtil.double(resultLine(inTurn, 11)?["total_cost_usd"]) ?? -1))
        await t.check("안내: 후속 턴 도중 · 코드", noticesIn(died).contains { $0.contains("후속 턴 도중") && $0.contains("(코드 1)") },
                      "\(noticesIn(died))")
        await t.check("남은 작업은 멈춤으로 닫힘 · 끝 뒤 동작 없음",
                      a.subAgents.allSatisfy { $0.status != .running } && a.processEnded(status: 1).isEmpty
                        && a.tick(now: base.addingTimeInterval(60)).isEmpty)

        var b = inTurn.tracker
        let r2 = finished(b.processEnded(status: 9, signaled: true, stderr: "  \n", now: base.addingTimeInterval(14)))
        await t.equal("stderr 가 비면 오류 글에 코드 · 시그널", r2?.errorMessage,
                      "후속 턴 도중 claude 프로세스가 종료되었습니다 (코드 9, 시그널)")
        await t.equal("분류는 원인 미확인", r2?.limitStatus, LimitStatus.unknownCause)

        var c = inTurn.tracker
        let r3 = finished(c.processEnded(status: nil, now: base.addingTimeInterval(14)))
        await t.check("종료 코드 없이 출력만 닫힘 → stream_closed 실패",
                      r3?.state == .failed && r3?.terminalReason == "stream_closed" && r3?.isError == true,
                      String(describing: r3))

        // 후속 턴 도중 사용자가 멈췄다 → 실패가 아니라 취소.
        var d = inTurn.tracker
        let marked = d.interrupt(now: base.addingTimeInterval(14))
        let r4 = finished(d.processEnded(status: 1, now: base.addingTimeInterval(15)))
        await t.check("후속 턴 도중 중단 뒤 종료 → 취소 (background_interrupted)",
                      marked.isEmpty && r4?.state == .cancelled && r4?.terminalReason == "background_interrupted",
                      String(describing: r4))

        // 기다리는 중(후속 result 16.06 뒤, 셸 알림 21.17 뒤)의 종료: 완료 · 코드 안내 · 미확정.
        var e = replay(records, Options(through: 38)).tracker
        let waiting = e.processEnded(status: 0, signaled: false, stderr: "", now: base.addingTimeInterval(21.5))
        let r5 = finished(waiting)
        await t.check("기다리는 중 종료(코드 0) → 마지막 결과로 완료 · 미확정",
                      r5?.state == .completed && r5?.isError == false && r5?.usage?.confirmed == false,
                      String(describing: r5))
        await t.check("기다리는 중 종료 안내에 코드", noticesIn(waiting).contains { $0.contains("기다리는 중") && $0.contains("(코드 0)") },
                      "\(noticesIn(waiting))")
    }

    // MARK: 마지막 결과 뒤의 일 (사용량 확정 여부)

    /// 사용량은 마지막 `result` 의 누적이다. 그 뒤에 하위가 일하고 결과 없이 끝나면(안전장치 · 디바운스 · 종료) 미확정.
    /// 후속 턴의 result 가 오면 그 누적에 다 들어 있으므로 확정.
    private static func usageAfterResult(_ t: TestKit, _ run: (String, Options) -> Replay?) async {
        await t.group("Claude 재생: 마지막 결과 뒤의 일")
        if let r = run("t2", Options()) {
            await t.equal("t2 후속 턴의 result 로 끝 → 확정", r.finish?.usage?.confirmed, true)
        }
        // 목록이 빈 채(10.45, 알림 전) 디바운스로 끝: 첫 result(5.82) 뒤의 task_progress(7.08 · 9.39) → 미확정.
        if let r = run("t2", Options(through: 24, ticks: [11.95])) {
            await t.check("t2 디바운스의 끝: 첫 result 뒤에 하위가 진행했다 → 미확정",
                          r.finishT == 11.95 && r.finish?.usage?.confirmed == false, String(describing: r.finish?.usage))
        }
        // 첫 result(12번 줄)까지만 넣고 곧바로 목록이 빈 채 디바운스 — 결과 뒤의 일이 없다.
        if var tracker = run("t2", Options(through: 12))?.tracker {
            _ = tracker.handle(sys("background_tasks_changed", ["tasks": [] as [[String: Any]]]),
                               now: base.addingTimeInterval(6))
            let r = finished(tracker.tick(now: base.addingTimeInterval(7.5)))
            await t.equal("결과 뒤에 일이 없으면 디바운스로 끝나도 확정", r?.usage?.confirmed, true)
        }
        // t5: 두 번째 result(11.49) 뒤 셸이 멈춤(13.12) → 디바운스(14.62)로 끝나면 미확정.
        if let r = run("t5", Options(through: 35, ticks: [14.62])) {
            await t.check("t5 결과 뒤에 셸이 끝나고 디바운스로 끝 → 미확정",
                          r.finishT == 14.62 && r.finish?.usage?.confirmed == false, String(describing: r.finish?.usage))
        }
        if let r = run("t5", Options()) {
            await t.equal("t5 마지막 result 로 끝 → 확정", r.finish?.usage?.confirmed, true)
        }
    }

    // MARK: 일찍 온 다시 보기

    /// 어댑터의 잠은 벽시계와 다른 시계라 일찍 깰 수 있다 — 때가 되기 전의 `tick` 이 빈 배열이면 다시 보기가 끊겨
    /// 실행이 끝나지 않는다. 남은 만큼(0.05초 ~ 기다림) 다시 부탁하고, 시계가 뒤로 갔으면 지금부터 다시 잰다.
    private static func earlyTick(_ t: TestKit, _ t2: [ProbeLogs.Record]?) async {
        await t.group("Claude 재생: 일찍 온 다시 보기")
        guard let records = t2 else { return }
        // 25번 줄 = 알림(10.45) — 후속 턴을 기다린다 (안전장치 15초).
        var a = replay(records, Options(through: 25)).tracker
        let early = rechecksIn(a.tick(now: base.addingTimeInterval(11.95)))
        await t.check("안전장치 전의 tick → 남은 13.5초 뒤 다시", early.count == 1 && abs((early.first ?? 0) - 13.5) < 1e-6,
                      "\(early)")
        await t.equal("거의 다 된 tick → 최소 0.05초 뒤 다시", rechecksIn(a.tick(now: base.addingTimeInterval(25.44))),
                      [ClaudeTurnTracker.minRecheck])
        await t.check("때가 되면 끝", finished(a.tick(now: base.addingTimeInterval(25.45)))?.state == .completed)

        // 시계가 뒤로 갔다 (5.0 < 10.45) → 지금부터 다시 잰다: 15초 뒤(20.0)에 끝 (원래대로면 25.45).
        var b = replay(records, Options(through: 25)).tracker
        await t.equal("시계가 뒤로 가면 기다림 전체를 다시", rechecksIn(b.tick(now: base.addingTimeInterval(5))),
                      [ClaudeTurnTracker.followUpGrace])
        await t.check("다시 잰 때부터 15초(20.0)에 끝", finished(b.tick(now: base.addingTimeInterval(20)))?.state == .completed)

        // 빈 목록 디바운스(24번 줄 = 목록이 빔 10.45)도 같다.
        var c = replay(records, Options(through: 24)).tracker
        let debounce = rechecksIn(c.tick(now: base.addingTimeInterval(11)))
        await t.check("디바운스 전의 tick → 남은 0.95초 뒤 다시",
                      debounce.count == 1 && abs((debounce.first ?? 0) - 0.95) < 1e-6, "\(debounce)")
        await t.equal("시계가 뒤로 가면 디바운스 전체를 다시", rechecksIn(c.tick(now: base.addingTimeInterval(9))),
                      [ClaudeTurnTracker.emptyListDebounce])
        await t.check("디바운스는 다시 잰 때(9.0)부터: 10.4 엔 아직, 10.5 에 끝",
                      !rechecksIn(c.tick(now: base.addingTimeInterval(10.4))).isEmpty
                        && finished(c.tick(now: base.addingTimeInterval(10.5))) != nil)

        // 기다리지 않는 상태(턴 중 · 목록이 참)에서는 아무것도 부탁하지 않는다 (다시 보기는 목록이 비면 새로 부탁).
        var d = replay(records, Options(through: 12)).tracker
        await t.check("목록이 차 있으면 tick 은 빈 배열", d.tick(now: base.addingTimeInterval(8)).isEmpty)
    }

    // MARK: 모르는 task_* 이벤트

    private static func unknownTaskEvents(_ t: TestKit, _ t2: [ProbeLogs.Record]?) async {
        await t.group("Claude 재생: 모르는 작업 이벤트")
        guard let result = t2?.first(where: { $0.event?["type"] as? String == "result" })?.event else {
            await t.check("t2 의 result 줄", false)
            return
        }
        let r = replay(synthetic([
            (0.1, sys("init", ["model": sonnet])),
            (0.2, sys("task_paused", ["task_id": "a1"])),
            (0.3, sys("task_paused", ["task_id": "a1"])),
            (0.4, sys("task_resumed", ["task_id": "a1"])),
            (0.5, sys("hook_started", [:])),
            (1.0, text("done")),
            (1.1, result),
        ]))
        let unknown = r.diagnostics.filter { $0.hasPrefix("알 수 없는 작업 이벤트") }
        await t.equal("모르는 task_* 는 종류마다 한 번 진단 (대화에 보이지 않는다)", unknown,
                      ["알 수 없는 작업 이벤트: task_paused", "알 수 없는 작업 이벤트: task_resumed"])
        await t.check("대화의 안내로는 내지 않는다", !r.notices.contains { $0.hasPrefix("알 수 없는 작업 이벤트") })
        await t.check("task_ 가 아닌 모르는 system 은 지금처럼 조용히",
                      !r.notices.contains { $0.contains("hook_started") } && !r.diagnostics.contains { $0.contains("hook_started") })
        await t.check("진단만 남기고 실행은 그대로 끝", r.finishT == 1.1 && r.finish?.state == .completed)
        await cliEvents(t, result)
    }

    // MARK: task_summary · 훅 · MCP 상태 (새 CLI — 합성)

    /// Claude Code 2.1.270 번들 스키마의 `task_summary`(진행 문구 — `detail` 은 글 또는 null) · `hook_response`(`outcome`) ·
    /// init 의 `mcp_servers` 상태. 실측 기록(t1~t8)은 옛 CLI 라 이 줄들이 없다 — 스키마대로 합성한다.
    private static func cliEvents(_ t: TestKit, _ result: [String: Any]) async {
        await t.group("Claude 재생: 진행 문구 · 훅 · MCP")
        func hook(_ name: String, outcome: String?, output: String = "", stderr: String = "", exit: Int? = nil) -> [String: Any] {
            var fields: [String: Any] = ["hook_id": UUID().uuidString, "hook_name": name, "hook_event": "PostToolUse",
                                         "output": output, "stdout": "", "stderr": stderr]
            if let outcome { fields["outcome"] = outcome }
            if let exit { fields["exit_code"] = exit }
            return sys("hook_response", fields)
        }
        let servers: [[String: Any]] = [["name": "docs", "status": "connected"], ["name": "drive", "status": "needs-auth"],
                                        ["name": "repl", "status": "failed"], ["name": "drive", "status": "needs-auth"]]
        let r = replay(synthetic([
            (0.1, sys("init", ["model": sonnet, "mcp_servers": servers])),
            (0.2, sys("task_summary", ["detail": "Reading the config files\nsecond line"])),
            (0.3, hook("petbridge-hook", outcome: "error", stderr: "상태 이벤트를 전달하지 못했습니다\n자세히")),
            (0.4, hook("petbridge-hook", outcome: "error", stderr: "또 실패")),
            (0.5, hook("fmt", outcome: "success", output: "formatted 2 files")),
            (0.6, hook("quiet", outcome: "success")),
            (0.7, hook("legacy", outcome: nil, output: "boom", exit: 2)),
            (0.8, sys("task_summary", ["detail": NSNull()])),
            (1.0, text("done")),
            (1.1, result),
        ]))
        await t.equal("task_summary 는 진행 문구로 (첫 줄) · null 은 지움", r.progress, ["Reading the config files", nil])
        await t.check("task_summary 는 모르는 이벤트가 아니다",
                      !r.diagnostics.contains { $0.contains("task_summary") } && !r.notices.contains { $0.contains("task_summary") })
        await t.equal("사람이 할 일: MCP 인증 필요 · 연결 실패 (서버 이름은 한 번) · 실패한 훅 (이름마다 한 번 · 첫 줄)", r.attentions,
                      [CLINoticeText.mcpNeedsAuth(["drive"]), CLINoticeText.mcpFailed(["repl"]),
                       "훅 실패: petbridge-hook (PostToolUse) — 상태 이벤트를 전달하지 못했습니다",
                       "훅 실패: legacy (PostToolUse) — boom"])
        await t.equal("진단: MCP 상태 목록 · 같은 훅의 두 번째 실패 · 성공한 훅의 출력 (출력 없는 성공은 아무것도)", r.diagnostics,
                      ["MCP 서버 상태(CLI 보고): docs=connected, drive=needs-auth, repl=failed, drive=needs-auth",
                       "훅 petbridge-hook (PostToolUse) · error: 또 실패",
                       "훅 fmt (PostToolUse) · success: formatted 2 files"])
        await t.check("대화의 안내(notice)로는 아무것도 내지 않는다", r.notices.isEmpty, "\(r.notices)")
        await t.check("끝 판정에는 영향이 없다", r.finishT == 1.1 && r.finish?.state == .completed)
    }

    // MARK: 가짜 CLI 로 어댑터 (승인 취소 · 작업 멈추기 · 후속 턴 도중 종료 · 알고 있는 사용량)

    /// 정해 둔 줄을 내는 가짜 `claude` (bash). `lines` 는 `emit` 할 JSON 과 셸 줄을 섞어 쓴다.
    private static func writeFakeCLI(_ dir: URL, _ lines: [String]) -> String {
        let url = dir.appendingPathComponent("claude")
        let script = (["#!/bin/bash", "emit() { printf '%s\\n' \"$1\"; }"] + lines).joined(separator: "\n") + "\n"
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
    private static func emitLine(_ obj: [String: Any]) -> String { "emit '\(JSONUtil.string(obj))'" }

    static let fakeResult: [String: Any] = [
        "type": "result", "subtype": "success", "is_error": false, "result": "launched", "session_id": sid,
        "duration_ms": 100, "total_cost_usd": 0.5, "usage": ["input_tokens": 10, "output_tokens": 5],
    ]
    static func canUseTool(_ id: String, toolUseID: String) -> [String: Any] {
        ["type": "control_request", "request_id": id,
         "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "ls"], "tool_use_id": toolUseID]]
    }

    /// 어댑터를 끝까지 돌려 이벤트를 모은다. `onEvent` 는 이벤트마다 (어댑터를 부를 수 있다). 20초면 프로세스를 끈다.
    private static func drive(_ adapter: ClaudeAdapter, _ dir: URL,
                              onEvent: (AgentEvent) async -> Void = { _ in }) async -> [AgentEvent] {
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if !Task.isCancelled { _ = await adapter.shutdown() }
        }
        defer { watchdog.cancel() }
        let request = AgentTurnRequest(runID: "r", prompt: "p", workingDirectory: dir, waitForBackground: true)
        var events: [AgentEvent] = []
        for await event in adapter.start(request) {
            events.append(event)
            await onEvent(event)
        }
        return events
    }

    private static func fakeCLI(_ t: TestKit) async {
        await t.group("Claude 어댑터: 가짜 CLI")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ahc-fake-claude-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stdinLog = dir.appendingPathComponent("stdin.log").path
        let env = ["PATH": "/usr/bin:/bin"]
        func resolved(_ events: [AgentEvent]) -> [(id: String, decision: String)] {
            events.compactMap { if case .approvalResolved(let id, let d) = $0 { return (id, d) }; return nil }
        }
        func result(_ events: [AgentEvent]) -> AgentTurnResult? {
            events.compactMap { if case .finished(let r) = $0 { return r }; return nil }.last
        }
        func notices(_ events: [AgentEvent]) -> [String] {
            events.compactMap { if case .notice(let s) = $0 { return s }; return nil }
        }
        func diagnostics(_ events: [AgentEvent]) -> [String] {
            events.compactMap { if case .diagnostic(let s) = $0 { return s }; return nil }
        }
        func sent() -> String { (try? String(contentsOfFile: stdinLog, encoding: .utf8)) ?? "" }

        // 1. CLI 가 승인 요청을 거둬들임 (control_cancel_request) → 카드를 닫고, 늦은 응답은 보내지 않는다.
        let cancelCLI = writeFakeCLI(dir, [
            emitLine(sys("init", ["model": sonnet])),
            emitLine(toolUse("X", "Bash")),
            emitLine(canUseTool("req-1", toolUseID: "X")),
            emitLine(["type": "control_cancel_request", "request_id": "req-1"]),
            emitLine(["type": "control_cancel_request", "request_id": "req-unknown"]),
            "while IFS= read -r -t 1 line; do printf '%s\\n' \"$line\" >> '\(stdinLog)'; done",
            emitLine(text("done")),
            emitLine(fakeResult),
        ])
        let cancelAdapter = ClaudeAdapter(executablePath: cancelCLI, environment: env)
        let cancelEvents = await drive(cancelAdapter, dir) { event in
            if case .approvalResolved(let id, _) = event, id == "req-1" {
                await cancelAdapter.respond(approvalID: "req-1", decision: .allow)
            }
        }
        await t.check("승인 요청을 받음", cancelEvents.contains {
            if case .approvalRequested(let a) = $0 { return a.id == "req-1" && a.agentID == nil }; return false })
        await t.check("control_cancel_request → 그 카드를 닫는다 (한 번, 취소됨)",
                      resolved(cancelEvents).map(\.id) == ["req-1"] && resolved(cancelEvents).first?.decision == "취소됨 (CLI)",
                      "\(resolved(cancelEvents))")
        await t.check("거둬들인 요청에 늦게 답해도 CLI 에 보내지 않음", !sent().contains("req-1") && sent().contains("initialize"),
                      sent())
        await t.equal("실행은 그대로 끝", result(cancelEvents)?.state, RunState.completed)
        try? FileManager.default.removeItem(atPath: stdinLog)

        // 2. 기다리는 중 하위의 승인이 걸린 채 그 하위를 멈춤 → 승인은 거절로 답하고 카드를 닫고 stop_task.
        //    CLI 는 작업을 멈추고 코드 3 으로 끝난다 → 기다리는 중 종료: 마지막 결과로 완료 · 미확정.
        let stopCLI = writeFakeCLI(dir, [
            emitLine(sys("init", ["model": sonnet])),
            // 시험이 `sessionEstablished` 에서 "결과 전" 을 읽을 틈 — 줄을 한꺼번에 내면 어댑터가 결과까지 먼저 읽을 수 있다
            // (기계가 바쁠 때 드물게 떨어졌다).
            "sleep 0.5",
            emitLine(toolUse("A", "Agent")),
            emitLine(sys("task_started", ["task_id": "a1", "tool_use_id": "A", "description": "bg",
                                          "task_type": "local_agent", "is_backgrounded": true, "prompt": "do it"])),
            emitLine(sys("background_tasks_changed", ["tasks": [["task_id": "a1", "task_type": "local_agent"]]])),
            emitLine(toolUse("X", "Bash", parent: "A")),
            emitLine(canUseTool("req-A", toolUseID: "X")),
            emitLine(text("launched")),
            emitLine(fakeResult),
            "while IFS= read -r -t 10 line; do printf '%s\\n' \"$line\" >> '\(stdinLog)'; "
                + "case \"$line\" in *stop_task*) break;; esac; done",
            emitLine(sys("background_tasks_changed", ["tasks": [] as [[String: Any]]])),
            emitLine(sys("task_notification", ["task_id": "a1", "tool_use_id": "A", "status": "stopped"])),
            "exit 3",
        ])
        let stopAdapter = ClaudeAdapter(executablePath: stopCLI, environment: env)
        var noUsageBeforeResult = false
        var usageSettled: TurnUsage?
        var stopSent = false
        let stopEvents = await drive(stopAdapter, dir) { event in
            switch event {
            case .sessionEstablished: noUsageBeforeResult = stopAdapter.lastKnownUsage == nil
            case .turnSettled:
                usageSettled = stopAdapter.lastKnownUsage
                stopSent = await stopAdapter.stopSubAgent(id: "A")
            default: break
            }
        }
        await t.check("결과 전에는 알고 있는 사용량 없음", noUsageBeforeResult)
        await t.check("기다리는 중 알고 있는 사용량 = 첫 result 의 누적 · 미확정",
                      usageSettled?.inputTokens == 10 && usageSettled?.outputTokens == 5
                        && near(usageSettled?.reportedCostUSD, 0.5) && usageSettled?.confirmed == false,
                      String(describing: usageSettled))
        await t.check("하위의 승인 요청은 그 하위의 것", stopEvents.contains {
            if case .approvalRequested(let a) = $0 { return a.id == "req-A" && a.agentID == "A" }; return false })
        await t.check("하위 멈추기를 보냄", stopSent)
        await t.check("그 하위의 승인 카드를 닫음 (거절 · 작업 멈춤)",
                      resolved(stopEvents).map(\.id) == ["req-A"] && resolved(stopEvents).first?.decision == "거절 (작업 멈춤)",
                      "\(resolved(stopEvents))")
        let lines = sent().split(separator: "\n").map(String.init)
        let denyAt = lines.firstIndex { $0.contains("req-A") && $0.contains("\"deny\"") }
        let stopAt = lines.firstIndex { $0.contains("stop_task") && $0.contains("\"a1\"") }
        await t.check("CLI 에는 거절 답 → stop_task 순서로", denyAt != nil && stopAt != nil && denyAt! < stopAt!, sent())
        let stopResult = result(stopEvents)
        await t.check("기다리는 중 코드 3 으로 끝 → 마지막 결과로 완료 · 미확정",
                      stopResult?.state == .completed && stopResult?.usage?.confirmed == false
                        && near(stopResult?.usage?.reportedCostUSD, 0.5), String(describing: stopResult))
        await t.check("종료 안내에 코드", notices(stopEvents).contains { $0.contains("기다리는 중") && $0.contains("(코드 3)") },
                      "\(notices(stopEvents))")
        let stopAfterEnd = await stopAdapter.stopSubAgent(id: "A")
        await t.equal("끝나면 멈출 작업이 없다", stopAfterEnd, false)

        // 3. 후속 턴 도중 프로세스가 죽음 → 실패 (exit_7, stderr 가 오류 글).
        //    stdout · stderr 는 다른 관이라 순서를 잠으로 맞춘다 — 없으면 오류 줄이 후속 init 보다 먼저 읽혀 가끔 앞 턴의 것으로 빠진다.
        let deathCLI = writeFakeCLI(dir, [
            emitLine(sys("init", ["model": sonnet])),
            emitLine(toolUse("A", "Agent")),
            emitLine(sys("task_started", ["task_id": "a1", "tool_use_id": "A", "description": "bg",
                                          "task_type": "local_agent", "is_backgrounded": true])),
            emitLine(sys("background_tasks_changed", ["tasks": [["task_id": "a1", "task_type": "local_agent"]]])),
            emitLine(text("launched")),
            emitLine(fakeResult),
            emitLine(sys("background_tasks_changed", ["tasks": [] as [[String: Any]]])),
            emitLine(sys("task_notification", ["task_id": "a1", "tool_use_id": "A", "status": "completed", "summary": "ok"])),
            emitLine(sys("init", ["model": sonnet])),
            "sleep 0.3",
            "echo 'fatal: boom' >&2",
            "exit 7",
        ])
        let deathEvents = await drive(ClaudeAdapter(executablePath: deathCLI, environment: env), dir)
        let death = result(deathEvents)
        await t.check("후속 턴이 열렸다", deathEvents.contains { if case .followUpTurnStarted = $0 { return true }; return false })
        await t.check("후속 턴 도중 종료 → 실패 · exit_7 · stderr 가 오류 글 · 미확정",
                      death?.state == .failed && death?.terminalReason == "exit_7" && death?.isError == true
                        && death?.errorMessage == "fatal: boom" && death?.usage?.confirmed == false,
                      String(describing: death))
        await t.check("안내: 후속 턴 도중", notices(deathEvents).contains { $0.contains("후속 턴 도중") && $0.contains("(코드 7)") },
                      "\(notices(deathEvents))")

        // 4. 첫 턴 전에 나온 stderr(인증 경고)는 후속 턴의 실패 원인이 아니다 — 결과 · 후속 init 뒤의 stderr 만 본다.
        //    stdout · stderr 는 다른 관이라 순서를 잠으로 맞춘다 (앞 경고는 결과 전에, 뒤 오류는 후속 init 뒤에).
        let staleCLI = writeFakeCLI(dir, [
            "echo 'warning: OAuth token refresh retried' >&2",
            "sleep 0.3",
            emitLine(sys("init", ["model": sonnet])),
            emitLine(toolUse("A", "Agent")),
            emitLine(sys("task_started", ["task_id": "a1", "tool_use_id": "A", "description": "bg",
                                          "task_type": "local_agent", "is_backgrounded": true])),
            emitLine(sys("background_tasks_changed", ["tasks": [["task_id": "a1", "task_type": "local_agent"]]])),
            emitLine(text("launched")),
            emitLine(fakeResult),
            emitLine(sys("background_tasks_changed", ["tasks": [] as [[String: Any]]])),
            emitLine(sys("task_notification", ["task_id": "a1", "tool_use_id": "A", "status": "completed", "summary": "ok"])),
            emitLine(sys("init", ["model": sonnet])),
            "sleep 0.3",
            "echo 'fatal: boom' >&2",
            "exit 7",
        ])
        let staleEvents = await drive(ClaudeAdapter(executablePath: staleCLI, environment: env), dir)
        let stale = result(staleEvents)
        await t.check("앞 턴의 stderr 는 진단으로만 남는다 (대화에 보이지 않는다)",
                      diagnostics(staleEvents).contains { $0.contains("OAuth token refresh") }
                        && !notices(staleEvents).contains { $0.contains("OAuth token refresh") },
                      "\(diagnostics(staleEvents))")
        await t.check("실행 명령줄은 진단", diagnostics(staleEvents).contains { $0.hasPrefix("claude 실행: ") }
                        && !notices(staleEvents).contains { $0.hasPrefix("claude 실행: ") })
        await t.check("후속 턴 도중 종료의 오류 글 · 분류는 후속 턴 뒤의 stderr 로 (인증 문제로 보지 않는다)",
                      stale?.state == .failed && stale?.errorMessage == "fatal: boom" && stale?.limitStatus == .unknownCause,
                      String(describing: stale))
    }

    // MARK: 대표 모델 (Haiku 결함)

    private static func representativeModel(_ t: TestKit, _ records: [ProbeLogs.Record]?) async {
        await t.group("Claude 재생: 대표 모델")
        guard let result = records?.last(where: { $0.event?["type"] as? String == "result" })?.event,
              let usage = result["modelUsage"] as? [String: [String: Any]] else {
            await t.check("t1 result 의 modelUsage", false)
            return
        }
        await t.equal("t1 modelUsage 에 Haiku 가 낀다 (알파벳순 첫 키)",
                      usage.keys.sorted().first, "claude-haiku-4-5-20251001")
        let plain = ClaudeAdapter.interpretResult(result, userCancelled: false, fallbackModel: nil, startedAt: base)
        await t.equal("init 모델 없이도 출력 토큰이 가장 많은 키 = sonnet", plain.result.model, sonnet)
        await t.equal("init 모델이 키면 그것", ClaudeAdapter.representativeModel(usage, preferred: "claude-haiku-4-5-20251001"),
                      "claude-haiku-4-5-20251001")
        await t.equal("init 모델이 키가 아니면 출력 토큰 순", ClaudeAdapter.representativeModel(usage, preferred: "opus"), sonnet)
        await t.check("비용은 모든 모델의 합 (0.2758825)", near(plain.result.usage?.reportedCostUSD, 0.2758825))
    }
}
