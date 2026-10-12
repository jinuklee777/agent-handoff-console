import Foundation

// MARK: - 대화 스트림: 끝난 실행 기록 접기 (`ExecutionFold`)

/// 실행 기록 블록을 한 줄 요약으로 접는 규칙 — 무엇을 세고, 무엇이 접혀도 보이고, 오류만 따로 펼치는지 (SwiftUI 없이).
@MainActor
enum StreamFoldTests {

    static func run(_ t: TestKit) async {
        await folding(t)
        await approvalMarks(t)
        await answeredQuestions(t)
        await legacyAnsweredQuestions(t)
        await turnMeta(t)
        await findInConversation(t)
        await scrollFollow(t)
        await streamReveal(t)
        await cliNotices(t)
        await formats(t)
    }

    // MARK: 맨 아래 따라가기

    /// 사람이 위로 한 번이라도 올리면 멈추고 · 맨 아래까지 내리면 다시 따라간다 (`StreamFollow`). 예전에는 멈춘 자리가 맨 아래 120pt
    /// 안이면 다시 따라가 휠 한 칸(40pt)씩 올리면 끌려 내려왔고, 그다음 고친 판정은 앱이 내리는 스크롤의 튐까지 사람이 올린 것으로 읽어
    /// 응답이 흐르는 첫 초에 따라가기가 꺼졌다.
    static func scrollFollow(_ t: TestKit) async {
        await t.group("스트림: 맨 아래 따라가기")
        typealias Spot = StreamFollow.Spot
        let bottom = Spot(offset: 1600, contentHeight: 2000, containerHeight: 400)
        func moved(_ dy: CGFloat, grow: CGFloat = 0, container: CGFloat = 0, from spot: Spot = bottom) -> Spot {
            Spot(offset: spot.offset + dy, contentHeight: spot.contentHeight + grow, containerHeight: spot.containerHeight + container)
        }
        func byUser(_ old: Spot, _ new: Spot) -> Bool? { StreamFollow.follow(from: old, to: new, userScrolling: true) }
        func byApp(_ old: Spot, _ new: Spot) -> Bool? { StreamFollow.follow(from: old, to: new, userScrolling: false) }
        await t.equal("스크롤 막대로 한 칸(40pt) 올리면 멈춘다", byUser(bottom, moved(-40)), false)
        await t.equal("가장 느린 휠 한 칸(4pt)도 멈춘다", byUser(bottom, moved(-4)), false)
        await t.equal("트랙패드의 1pt 는 아직 맨 아래", byUser(bottom, moved(-1)), true)
        await t.equal("앱이 내리는 스크롤이 한 줄 위로 튀어도 멈추지 않는다 (응답이 흐를 때 따라가기가 꺼지던 결함)",
                      byApp(bottom, moved(-18)), nil)
        let up = moved(-200)
        await t.equal("올려 둔 동안 아래 글이 늘어도 그대로", byApp(up, moved(0, grow: 300, from: up)), nil)
        await t.equal("아래로 내리는 중(아직 맨 아래 아님)은 그대로", byUser(up, moved(150, from: up)), nil)
        await t.equal("맨 아래까지 내리면 다시 따라간다", byUser(up, moved(200, from: up)), true)
        await t.equal("트랙패드가 맨 아래 너머에서 튕겨 돌아와도 따라간다", byUser(moved(30), bottom), true)
        let readingUp = Spot(offset: 1000, contentHeight: 2000, containerHeight: 400)
        await t.equal("접어서 내용이 줄어 자리가 밀린 것은 사람이 올린 것이 아니다",
                      byUser(readingUp, Spot(offset: 900, contentHeight: 1800, containerHeight: 400)), nil)
        await t.equal("창이 커져 자리가 밀린 것도 아니다",
                      byUser(readingUp, Spot(offset: 950, contentHeight: 2000, containerHeight: 450)), nil)
        await t.equal("내용이 칸보다 짧으면 맨 아래",
                      byApp(bottom, Spot(offset: 0, contentHeight: 300, containerHeight: 400)), true)
        let grown = moved(0, grow: 23)
        await t.check("따라가는 중에 글이 늘어 밀려나면 다시 내린다",
                      StreamFollow.needsPin(following: true, userScrolling: false, at: grown))
        await t.check("사람이 스크롤하는 동안 · 따라가지 않을 때 · 맨 아래일 때는 내리지 않는다",
                      !StreamFollow.needsPin(following: true, userScrolling: true, at: grown)
                        && !StreamFollow.needsPin(following: false, userScrolling: false, at: grown)
                        && !StreamFollow.needsPin(following: true, userScrolling: false, at: bottom))
    }

    // MARK: 고른 속도로 풀기

    /// 흐르는 응답의 보일 글자 수 (`StreamReveal`): CLI 가 몰아 보낸 조각을 한꺼번에 보이지 않고 밀린 양에 비례한 속도로 풀며,
    /// 끝나면 남은 글을 빨리 마저 보이고, 받은 글을 넘지 않는다.
    static func streamReveal(_ t: TestKit) async {
        await t.group("스트림: 고른 속도로 풀기")
        func play(_ total: Int, from shown: Double = 0, seconds: Double, finished: Bool = false) -> Double {
            // 화면 주기(60Hz)마다.
            let frame = 1.0 / 60
            var value = shown
            var time = 0.0
            while time < seconds - 1e-9 {
                value = StreamReveal.advance(shown: value, total: total, elapsed: frame, finished: finished)
                time += frame
            }
            return value
        }
        let early = play(20, seconds: 0.1)
        await t.check("한꺼번에 온 20글자는 0.1초 뒤에 일부만 보인다", early > 1 && early < 12, "\(early)")
        await t.equal("1초 안에 다 보인다", play(20, seconds: 1), 20)
        let burst = play(400, seconds: StreamReveal.lag)
        await t.check("밀린 글이 많으면 빨리 푼다 (400글자의 절반 넘게를 lag 안에)", burst > 200 && burst < 400, "\(burst)")
        await t.equal("400글자도 2.5초 안에 다 보인다", play(400, seconds: 2.5), 400)
        await t.equal("끝나면 남은 30글자를 0.3초 안에 마저 보인다", play(30, seconds: 0.3, finished: true), 30)
        await t.check("끝나지 않았으면 그보다 느리다", play(30, seconds: 0.3) < 30)
        await t.equal("다 보였으면 그대로", StreamReveal.advance(shown: 5, total: 5, elapsed: 1, finished: false), 5)
        await t.equal("받은 글이 줄었으면 받은 글까지", StreamReveal.advance(shown: 8, total: 5, elapsed: 0.1, finished: false), 5)
        await t.equal("시간이 흐르지 않았으면 그대로", StreamReveal.advance(shown: 3, total: 10, elapsed: 0, finished: false), 3)
        await t.equal("오래 못 돌았어도(앱이 바빴다) 받은 글을 넘지 않는다",
                      StreamReveal.advance(shown: 0, total: 10, elapsed: 5, finished: false), 10)
        let now = Date()
        await t.check("막 시작한 응답은 처음부터 푼다",
                      StreamReveal.startsFromBeginning(createdAt: now.addingTimeInterval(-0.2), now: now))
        await t.check("이미 흐르던 응답(대화를 다시 열었다)은 지금까지의 글을 곧바로 보인다",
                      !StreamReveal.startsFromBeginning(createdAt: now.addingTimeInterval(-10), now: now))

        // 일정 — 텍스트 뷰가 이것으로 가림막의 키프레임을 짓는다.
        let schedule = StreamReveal.Schedule(start: 100, from: 0, total: 20, finished: false)
        await t.equal("일정은 보이던 길이에서 시작해 받은 길이로 끝난다", [schedule.values.first, schedule.values.last], [0, 20])
        await t.check("일정은 줄지 않는다", zip(schedule.values, schedule.values.dropFirst()).allSatisfy { $0 <= $1 })
        await t.check("20글자는 1초 안에 다 보인다", schedule.end - schedule.start < 1, "\(schedule.end - schedule.start)")
        await t.equal("시작 전 · 끝난 뒤", [schedule.shown(at: 99), schedule.shown(at: schedule.end + 1)], [0, 20])
        let between = schedule.shown(at: 100 + StreamReveal.Schedule.step * 1.5)
        await t.check("일정 사이는 직선으로 잇는다", between > schedule.values[1] && between < schedule.values[2], "\(between)")
        let finishing = StreamReveal.Schedule(start: 0, from: 0, total: 20, finished: true)
        await t.check("받기를 마친 일정은 더 빨리 끝난다", finishing.end < schedule.end - schedule.start)
        let huge = StreamReveal.Schedule(start: 0, from: 0, total: 1_000_000, finished: false)
        await t.check("아주 긴 일정은 상한에서 끝을 붙인다",
                      huge.values.last == 1_000_000 && huge.end <= StreamReveal.Schedule.limit + StreamReveal.Schedule.step * 2)
        await t.equal("이미 다 보였으면 일정은 한 칸", StreamReveal.Schedule(start: 0, from: 7, total: 7, finished: false).values, [7])
    }

    // MARK: 대화 안 찾기 (⌘F)

    /// 찾기 막대의 판정 (`ThreadFind`): 화면에 보이는 글에서만 찾고 · 행 단위로 세며 · 다음 · 이전은 끝에서 돈다.
    static func findInConversation(_ t: TestKit) async {
        await t.group("대화 안 찾기: 판정")
        let events = [
            ThreadEvent(id: "u1", threadID: "t", runID: "r1", seq: 1, kind: .userMessage, provider: nil,
                        text: "LoginView.swift 의 오류 문구를 고쳐 줘"),
            ThreadEvent(id: "x1", threadID: "t", runID: "r1", seq: 2, kind: .toolRequest, provider: .claude, title: "Read",
                        text: #"{"file_path":"/p/Sources/LoginView.swift"}"#, toolUseID: "read"),
            ThreadEvent(id: "x2", threadID: "t", runID: "r1", seq: 3, kind: .toolResult, provider: .claude, title: "Read",
                        text: "1\tlet hidden = \"LoginView 출력에만 있는 글\"", toolUseID: "read"),
            ThreadEvent(id: "a1", threadID: "t", runID: "r1", seq: 4, kind: .agentMessage, provider: .claude,
                        text: "loginview.swift 를 봤습니다. LoginView 의 문구 둘을 바꿨습니다."),
            ThreadEvent(id: "a2", threadID: "t", runID: "r1", seq: 5, kind: .agentMessage, provider: .claude,
                        text: "테스트도 통과했습니다."),
        ]
        var run = Run(threadID: "t", sessionID: "s", provider: .claude, requestText: "고쳐 줘", state: .completed)
        run.id = "r1"
        let rows = StreamBuilder.rows(events: events, runs: ["r1": run], handoffs: [], projectPath: "/p")
        let matches = ThreadFind.matches("loginview", in: rows)
        let executionRow: StreamRow? = rows.first { row in
            if case .execution = row { return true }
            return false
        }
        let executionID: String = executionRow?.id ?? "?"
        await t.equal("대소문자를 가리지 않고 사용자 · 실행 기록 · 에이전트 행에서 찾는다 (스트림 순서)",
                      matches.map(\.rowID), ["u1", executionID, "a1"])
        await t.equal("한 행의 맞은 곳 수 (에이전트 행에 둘)", matches.last?.occurrences, 2)
        await t.check("접혀 보이지 않는 명령 출력 · 도구 결과는 찾지 않는다",
                      ThreadFind.matches("출력에만", in: rows).isEmpty)
        let chrome: [StreamRow] = rows.filter { row in
            switch row {
            case .agentHeader, .turnFooter: return true
            default: return false
            }
        }
        await t.check("머리줄 · 바닥글은 찾지 않는다 (모델 이름 · 토큰 수가 맞아도 볼 곳이 없다)",
                      !chrome.isEmpty && chrome.allSatisfy { ThreadFind.searchableText($0).isEmpty })
        await t.check("빈 말 · 공백은 찾지 않는다", ThreadFind.matches("  ", in: rows).isEmpty && ThreadFind.matches("", in: rows).isEmpty)
        await t.equal("앞뒤 공백은 무시한다", ThreadFind.matches(" 테스트도 ", in: rows).map(\.rowID), ["a2"])
        await t.equal("겹치지 않게 센다", ThreadFind.occurrences(of: "aa", in: "aaaa"), 2)
        await t.equal("전각 · 반각을 가리지 않는다", ThreadFind.occurrences(of: "ＡＢ", in: "ab AB"), 2)

        await t.equal("처음 보일 결과는 맨 아래(가장 최근)", ThreadFind.initialIndex(count: 3), 2)
        await t.equal("결과가 없으면 없음", ThreadFind.initialIndex(count: 0), nil as Int?)
        await t.equal("다음 · 이전 · 끝에서 돈다",
                      [ThreadFind.step(from: 0, count: 3, forward: true), ThreadFind.step(from: 2, count: 3, forward: true),
                       ThreadFind.step(from: 0, count: 3, forward: false), ThreadFind.step(from: nil, count: 3, forward: true),
                       ThreadFind.step(from: 5, count: 3, forward: false), ThreadFind.step(from: 1, count: 0, forward: true)],
                      [1, 0, 2, 2, 2, nil])
        await t.equal("보던 결과를 다시 찾는다 (새 출력이 붙어도 그 결과에 머문다)",
                      [ThreadFind.index(of: "a1", in: matches), ThreadFind.index(of: "없는 행", in: matches),
                       ThreadFind.index(of: nil, in: matches)], [2, nil, nil])
        await t.equal("막대의 수: 몇 번째/모두 · 결과 없음 · 찾을 말이 없으면 빈 글",
                      [ThreadFind.counterText(query: "loginview", current: 0, matches: matches),
                       ThreadFind.counterText(query: "loginview", current: nil, matches: matches),
                       ThreadFind.counterText(query: "없는 말", current: nil, matches: []),
                       ThreadFind.counterText(query: " ", current: nil, matches: [])],
                      ["1/3", "3/3", "결과 없음", ""])
        await t.check("수의 도움말: 항목 수와 맞은 곳 수",
                      ThreadFind.counterHelp(matches: matches).contains("항목 3개") && ThreadFind.counterHelp(matches: matches).contains("4곳"))
        let command = ThreadFind.Command(threadID: "t", action: .open, serial: 1, requestedAt: Date(timeIntervalSince1970: 100))
        await t.check("메뉴 요청은 2초 안에만 받는다 (대화 칸이 나중에 나타날 때)",
                      command.isFresh(now: Date(timeIntervalSince1970: 101)) && !command.isFresh(now: Date(timeIntervalSince1970: 103)))
    }

    // MARK: 승인과 이어진 도구 행 (H3 · cap-1 · H6 · chat-13)

    /// 승인 결정 기록(`ApprovalTrail`)으로 도구 행에 승인 대기 · 거절함 · 거둠을 붙이는지 — 거절은 오류가 아니고 접기에서 오류로
    /// 세지 않는다, 승인을 기다리는 행은 "실행 중" 이 아니다, 도는 실행의 요청 줄은 카드가 보이므로 감춘다.
    static func approvalMarks(_ t: TestKit) async {
        await t.group("스트림: 승인 대기 · 거절함 (도구 행과 결정 잇기)")
        var seq: Int64 = 0
        func event(_ kind: EventKind, title: String = "", text: String = "", tool: String? = nil, payload: String? = nil,
                   run: String = "r1", provider: AgentProvider = .claude) -> ThreadEvent {
            seq += 1
            return ThreadEvent(id: "e\(seq)", threadID: "t", runID: run, seq: seq, kind: kind, provider: provider, title: title,
                               text: text, payloadJSON: payload, toolUseID: tool)
        }
        func request(_ requestID: String, tool: String?) -> ThreadEvent {
            event(.approvalRequest, title: "도구 사용: Bash — 테스트", text: "{}", tool: tool,
                  payload: ThreadEvent.approvalRequestPayload(requestID: requestID, toolName: "Bash", approvalKind: "tool"))
        }
        func decision(_ requestID: String, _ choice: ApprovalDecisionInfo.Decision, reason: String? = nil, tool: String?,
                      text: String) -> ThreadEvent {
            event(.approvalDecision, title: "승인 결정", text: text, tool: tool,
                  payload: ThreadEvent.approvalDecisionPayload(ApprovalDecisionInfo(
                    decision: choice, reason: reason, requestTitle: "테스트", toolName: "Bash", approvalKind: "tool",
                    requestID: requestID)))
        }
        func command(_ entries: [ExecutionEntry]) -> CommandInfo? {
            for entry in entries { if case .command(let info) = entry.kind { return info } }
            return nil
        }
        let bash = event(.toolRequest, title: "Bash", text: #"{"command":"swift test --filter LoginTests"}"#, tool: "b1")

        // 1) 승인을 기다리는 중: 도구 행은 "승인 대기" (실행 중이 아니다), 요청 줄은 결정이 없다고 표시된다.
        let waiting = ExecutionParser.entries(from: [bash, request("a1", tool: "b1")], projectPath: "/p")
        await t.equal("승인을 기다리는 명령 행은 승인 대기", command(waiting)?.approval, .awaiting)
        await t.check("승인 대기 행은 오류도 완료도 아니다 · 접힌 요약에 '승인 대기' 로 센다",
                      command(waiting).map { !$0.failed } == true && ExecutionFold.issue(of: waiting[0]) == .awaiting)
        await t.check("결정이 없는 요청 줄", waiting.contains { $0.awaitingDecision })
        var live = Run(threadID: "t", sessionID: "s", provider: .claude, requestText: "x", state: .awaitingApproval)
        live.id = "r1"
        let liveRows = StreamBuilder.rows(events: [bash, request("a1", tool: "b1")], runs: ["r1": live], handoffs: [], projectPath: "/p")
        let liveEntries = liveRows.flatMap { row -> [ExecutionEntry] in
            if case .execution(_, let entries) = row { return entries } else { return [] }
        }
        await t.check("도는 실행: 승인 요청 줄은 감춘다 (카드가 같은 것을 보인다) — 명령은 기록에 한 번",
                      liveEntries.count == 1 && command(liveEntries)?.approval == .awaiting, "\(liveEntries.map(\.id))")

        // 2) 사람이 거절함: Claude 는 거절 사유를 is_error 결과로 돌려준다 — 오류가 아니라 거절함 · 사유.
        let deniedEvents = [bash, request("a1", tool: "b1"),
                            decision("a1", .deny, reason: "테스트는 내가 돌린다", tool: "b1", text: "거절"),
                            event(.toolResult, title: "Bash — 오류", text: "테스트는 내가 돌린다", tool: "b1")]
        let denied = ExecutionParser.entries(from: deniedEvents, projectPath: "/p")
        await t.equal("거절한 명령: 거절함 · 사람이 적은 사유", command(denied)?.approval, .denied(reason: "테스트는 내가 돌린다"))
        await t.check("거절한 명령은 오류가 아니다 · 결과 줄도 아니다", command(denied).map { !$0.failed && !$0.reportedError && !$0.running } == true)
        let deniedSummary = ExecutionFold.summary(denied)
        await t.check("거절은 접기에서 오류로 세지 않는다", deniedSummary.issues.isEmpty && ExecutionFold.plan(denied).issueIDs.isEmpty)
        await t.equal("접힌 요약: 거절한 명령은 한 일로 세지 않고 '거절 n번' · 그 명령의 승인 요청 · 결정은 세지 않는다",
                      deniedSummary.text, "거절 1번")
        let deniedPlan = ExecutionFold.plan(denied)
        await t.equal("펼쳐도 승인 요청 · 결정 줄은 그 명령 단계에 합친다 (명령 한 줄 · 거절함)",
                      deniedPlan.visible(denied, expanded: true, showingIssues: false).map { ExecutionFold.step($0).title + "|" + (ExecutionFold.step($0).status?.text ?? "") },
                      ["swift test --filter LoginTests|거절함"])
        let orphan = [ExecutionEntry(id: "appr:x", kind: .approval(title: "권한 요청", detail: ""), provider: .codex,
                                     createdAt: Date(), toolUseID: "없는 호출")]
        await t.equal("가리키는 도구 행이 없는 승인 요청은 남긴다", ExecutionFold.absorbedIDs(orphan), [])
        let noReason = ExecutionParser.entries(from: [bash, request("a1", tool: "b1"),
                                                      decision("a1", .deny, tool: "b1", text: "거절"),
                                                      event(.toolResult, title: "Bash — 오류", text: "사용자가 거절했습니다.", tool: "b1")],
                                               projectPath: "/p")
        await t.equal("사유 없이 거절: 앱의 기본 문구는 사유가 아니다", command(noReason)?.approval, .denied(reason: nil))

        // 3) 옛 기록 (결정 행에 구조화된 내용이 없다): 같은 실행의 바로 앞 요청과 짝짓고, 오류 결과의 글이 사유다.
        let legacy = ExecutionParser.entries(from: [
            bash, event(.approvalRequest, title: "도구 사용: Bash", text: "{}", tool: "b1"),
            event(.approvalDecision, title: "승인 결정", text: "거절"),
            event(.toolResult, title: "Bash — 오류", text: "지금은 안 됩니다", tool: "b1"),
        ], projectPath: "/p")
        await t.equal("옛 기록: 요청과 짝지어 거절함 · 결과의 글이 사유", command(legacy)?.approval, .denied(reason: "지금은 안 됩니다"))
        let legacyAllowed = ExecutionParser.entries(from: [
            bash, event(.approvalRequest, title: "도구 사용: Bash", text: "{}", tool: "b1"),
            event(.approvalDecision, title: "승인 결정", text: "허용"),
            event(.toolResult, title: "Bash", text: "ok", tool: "b1"),
        ], projectPath: "/p")
        await t.check("옛 기록: 허용한 명령은 표시 없이 끝남", command(legacyAllowed).map { $0.approval == nil && !$0.running } == true)

        // 4) 허용 · 자동 허용은 표시하지 않는다 — 실행 결과대로.
        let allowed = ExecutionParser.entries(from: [bash, request("a1", tool: "b1"),
                                                     decision("a1", .autoAllow, tool: "b1", text: "자동 허용")], projectPath: "/p")
        await t.check("허용된 명령은 결과를 기다리는 동안 실행 중", command(allowed).map { $0.approval == nil && $0.running } == true)

        // 5) CLI 가 거둔 요청 · 끝난 실행에 남은 승인 대기: 실행되지 않았다 ("결과 미확인" 이 아니다).
        let withdrawn = ExecutionParser.entries(from: [bash, request("a1", tool: "b1"),
                                                       decision("a1", .cancelled, tool: "b1", text: "취소됨 (CLI)")], projectPath: "/p")
        await t.equal("거둔 요청의 명령은 실행 안 됨", command(withdrawn)?.approval, .withdrawn)
        await t.equal("끝난 실행에 남은 승인 대기는 실행 안 됨",
                      command(ExecutionParser.settlingUnfinished(waiting))?.approval, .withdrawn)
        await t.check("실행 안 됨은 결과 미확인이 아니다 · 접기에서 끝난 일",
                      command(ExecutionParser.settlingUnfinished(waiting)).map { !$0.unfinished } == true
                        && ExecutionFold.issue(of: ExecutionParser.settlingUnfinished(waiting)[0]) == nil)

        // 6) Codex: `declined` 상태는 거절 — 사유는 결정 행에서.
        let codexDeclined = ExecutionParser.entries(from: [
            event(.commandExecution, title: "rm x", text: "rm x", tool: "c1", payload: #"{"status":"inProgress"}"#, provider: .codex),
            event(.approvalRequest, title: "명령 실행: rm x", text: "rm x", tool: "c1",
                  payload: ThreadEvent.approvalRequestPayload(requestID: "0", toolName: "명령 실행", approvalKind: "command"),
                  provider: .codex),
            event(.approvalDecision, title: "승인 결정", text: "거절", tool: "c1",
                  payload: ThreadEvent.approvalDecisionPayload(ApprovalDecisionInfo(decision: .deny, reason: "지우지 마",
                                                                                    requestID: "0")), provider: .codex),
            event(.commandExecution, title: "rm x", text: "rm x", tool: "c1", payload: #"{"status":"declined"}"#, provider: .codex),
        ], projectPath: "/p")
        await t.equal("Codex 거절: 거절함 · 결정 행의 사유", command(codexDeclined)?.approval, .denied(reason: "지우지 마"))

        // 7) 편집 요청: 승인 대기 동안 줄 수는 예정 (바뀐 줄만 센다), 거절하면 적용 안 된 것이 아니라 거절함.
        let editRequest = event(.toolRequest, title: "Edit", text: JSONUtil.line([
            "file_path": "/p/a.swift", "old_string": "a\nkeep\nb", "new_string": "a\nkeep\nc"]) ?? "{}", tool: "e1")
        let pendingEdit = ExecutionParser.entries(from: [editRequest, request("a2", tool: "e1")], projectPath: "/p")
        if case .fileEdit(let info)? = pendingEdit.first?.kind {
            await t.check("편집 행: 승인 대기 · 바뀐 줄만 (+1 −1)", info.approval == .awaiting && info.added == 1 && info.removed == 1,
                          "\(String(describing: info.approval)) \(String(describing: info.added)) \(String(describing: info.removed))")
        } else {
            await t.check("편집 요청은 편집 행", false)
        }
        let deniedEdit = ExecutionParser.entries(from: [editRequest, request("a2", tool: "e1"),
                                                        decision("a2", .deny, tool: "e1", text: "거절"),
                                                        event(.toolResult, title: "Edit — 오류", text: "x", tool: "e1")], projectPath: "/p")
        if case .fileEdit(let info)? = deniedEdit.first?.kind {
            await t.check("거절한 편집: 적용 안 됨(오류)이 아니라 거절함", info.approval == .denied(reason: nil) && !info.reportedError)
        }

        // 8) 질문: 답하면 끝난 일 (접는다), 답하지 않은 질문은 접힌 블록에서도 보인다.
        var asked = ExecutionEntry(id: "q", kind: .question("어느 쪽?"), provider: .codex, createdAt: Date())
        await t.check("답하지 않은 질문은 접혀도 보인다", ExecutionFold.isPinned(asked))
        asked.questionAnswered = true
        await t.check("답한 질문은 끝난 일 (접는다)", !ExecutionFold.isPinned(asked) && ExecutionFold.issue(of: asked) == nil)
        let answeredRow = event(.userQuestion, title: "사용자 질문", text: "범위: 어디까지?\n→ 함께",
                                payload: JSONUtil.string([ThreadEvent.questionAnsweredKey: true]))
        await t.check("답한 질문 행을 알아본다", ExecutionParser.entries(from: [answeredRow], projectPath: nil).first?.questionAnswered == true)

        // 9) 실행 중 상태 줄 · 승인 결정 이름 (chat-13): 기다리는 것이 질문뿐이면 "질문".
        let activity = RunActivity.make(state: .awaitingApproval, runID: "r1", waitingOnBackground: false, backgroundCount: 0,
                                        events: [], streaming: nil, projectPath: nil, questionOnly: true)
        await t.equal("질문만 기다리면 질문에 답을 기다리는 중", activity.text, "질문에 답을 기다리는 중")
        await t.equal("승인이 있으면 승인을 기다리는 중",
                      RunActivity.make(state: .awaitingApproval, runID: "r1", waitingOnBackground: false, backgroundCount: 0,
                                       events: [], streaming: nil, projectPath: nil).text, "승인을 기다리는 중")
        await t.equal("옛 결정 글 짐작", ["허용", "세션 동안 허용", "이번 실행 동안 허용", "거절", "거절 후 중단", "취소됨 (CLI)",
                                     "거절 (작업 멈춤)", "하위 작업이 끝나 취소됨", "자동 허용", "응답 전송"]
                        .map { ApprovalDecisionInfo.Decision.legacy($0)?.rawValue ?? "nil" },
                      ["allow", "allowForSession", "allowForSession", "deny", "denyAndCancel", "cancelled", "stopped", "cancelled",
                       "autoAllow", "nil"])
    }

    // MARK: 질문에 적은 답 (2차 시험 conv-1 · copy-1)

    /// 질문 도구(Claude `AskUserQuestion`)의 [적은 답 보내기] 는 거절이 아니라 답이다: 도구 행은 "답함 · <답>" (오류 · 거절 아님),
    /// 접힌 요약은 "답한 질문 n개" ("거절 n번" 아님), 도구 행의 요약은 입력 JSON 이 아니라 질문.
    static func answeredQuestions(_ t: TestKit) async {
        await t.group("스트림: 질문에 적은 답은 답함 (거절 아님)")
        let input = #"{"questions":[{"question":"어느 방식으로 할까요?","header":"방식","options":[{"label":"A"},{"label":"B"}],"multiSelect":false}]}"#
        let ask = ThreadEvent(id: "q1", threadID: "t", runID: "r1", seq: 1, kind: .toolRequest, provider: .claude,
                              title: AskedQuestion.claudeToolName, text: input, toolUseID: "ask-1")
        let request = ThreadEvent(id: "q2", threadID: "t", runID: "r1", seq: 2, kind: .approvalRequest, provider: .claude,
                                  title: "도구 사용: AskUserQuestion", text: input,
                                  payloadJSON: ThreadEvent.approvalRequestPayload(requestID: "c-1", toolName: AskedQuestion.claudeToolName,
                                                                                  approvalKind: "tool"),
                                  toolUseID: "ask-1")
        let answered = ThreadEvent(id: "q3", threadID: "t", runID: "r1", seq: 3, kind: .approvalDecision, provider: .claude,
                                   title: "승인 결정", text: ApprovalDecision.answer("B 방식으로").koreanName,
                                   payloadJSON: ThreadEvent.approvalDecisionPayload(ApprovalDecisionInfo(
                                    decision: .answered, requestTitle: "AskUserQuestion", toolName: AskedQuestion.claudeToolName,
                                    approvalKind: "tool", requestID: "c-1", answer: "B 방식으로")),
                                   toolUseID: "ask-1")
        let echo = ThreadEvent(id: "q4", threadID: "t", runID: "r1", seq: 4, kind: .toolResult, provider: .claude,
                               title: "AskUserQuestion — 오류", text: "B 방식으로", toolUseID: "ask-1")
        let entries = ExecutionParser.entries(from: [ask, request, answered, echo], projectPath: nil)
        let tool: ToolInfo? = entries.compactMap { entry -> ToolInfo? in
            if case .tool(let info) = entry.kind { return info } else { return nil }
        }.first
        await t.equal("도구 행: 답함 · 보낸 답", tool?.approval, .answered("B 방식으로"))
        await t.check("답한 질문은 오류도 실행 중도 아니다 (CLI 가 답을 오류 결과로 돌려줘도)",
                      tool.map { !$0.reportedError && !$0.running } == true)
        await t.equal("복사 글: 답함 · <답>", tool?.approval?.copyText, "답함 · B 방식으로")
        await t.equal("도구 행의 요약은 물은 것", tool?.summary, "어느 방식으로 할까요?")
        let summary = ExecutionFold.summary(entries)
        await t.check("접힌 요약: 답한 질문 1개 · 거절로 세지 않는다",
                      summary.text.contains("답한 질문 1개") && !summary.text.contains("거절"), summary.text)
        await t.check("답한 질문은 끝난 일 (접는다)",
                      ExecutionFold.plan(entries).pinnedIDs.isEmpty && ExecutionFold.plan(entries).issueIDs.isEmpty)
        await t.equal("결정 기록: 답함 · 답 (payload 를 오간다)", answered.approvalDecisionInfo?.answer, "B 방식으로")
        await t.check("답함은 거절 · 거둠이 아니다",
                      !ApprovalDecisionInfo.Decision.answered.isDenial && !ApprovalDecisionInfo.Decision.answered.isWithdrawal
                        && ApprovalDecisionInfo.Decision.legacy("답함") == .answered)
    }

    /// 답이 거절로 적힌 옛 기록도 답으로 읽는다: 2026-10-04 빌드(결정 행에 도구 이름 · 사유 = 답)와 그 전(표시 없음 — 요청 행의
    /// 입력 모양 · CLI 가 돌려준 결과의 글). 글 없는 거절 · [거절 후 중단] 은 그대로 거절이다.
    static func legacyAnsweredQuestions(_ t: TestKit) async {
        await t.group("스트림: 답이 거절로 적힌 옛 기록도 답으로")
        let input = #"{"questions":[{"question":"어느 쪽?","options":[{"label":"A"}]}]}"#
        func events(_ decision: ThreadEvent, echo: String) -> [ThreadEvent] {
            [ThreadEvent(id: "a", threadID: "t", runID: "r1", seq: 1, kind: .toolRequest, provider: .claude,
                         title: "AskUserQuestion", text: input, toolUseID: "ask"),
             ThreadEvent(id: "b", threadID: "t", runID: "r1", seq: 2, kind: .approvalRequest, provider: .claude,
                         title: "도구 사용: AskUserQuestion", text: input, toolUseID: "ask"),
             decision,
             ThreadEvent(id: "d", threadID: "t", runID: "r1", seq: 4, kind: .toolResult, provider: .claude,
                         title: "AskUserQuestion — 오류", text: echo, toolUseID: "ask")]
        }
        func mark(_ list: [ThreadEvent]) -> ApprovalMark? {
            ExecutionParser.entries(from: list, projectPath: nil).compactMap { entry -> ApprovalMark? in
                if case .tool(let info) = entry.kind { return info.approval } else { return nil }
            }.first
        }
        func stored(_ decision: ApprovalDecisionInfo.Decision, reason: String?) -> ThreadEvent {
            ThreadEvent(id: "c", threadID: "t", runID: "r1", seq: 3, kind: .approvalDecision, provider: .claude, title: "승인 결정",
                        text: decision == .deny ? "거절" : "거절 후 중단",
                        payloadJSON: ThreadEvent.approvalDecisionPayload(ApprovalDecisionInfo(
                            decision: decision, reason: reason, toolName: "AskUserQuestion", approvalKind: "tool", requestID: "x")),
                        toolUseID: "ask")
        }
        await t.equal("10-04 빌드: 질문 도구의 거절 + 사유 = 답", mark(events(stored(.deny, reason: "2번으로 해 줘"), echo: "2번으로 해 줘")),
                      .answered("2번으로 해 줘"))
        let bare = ThreadEvent(id: "c", threadID: "t", runID: "r1", seq: 3, kind: .approvalDecision, provider: .claude,
                               title: "승인 결정", text: "거절")
        await t.equal("표시 없는 옛 행: 요청 입력이 질문 · 결과의 글이 답", mark(events(bare, echo: "B 로 가자")), .answered("B 로 가자"))
        await t.equal("글 없이 거절한 질문은 거절함 (앱의 기본 문장은 답이 아니다)",
                      mark(events(bare, echo: "사용자가 거절했습니다.")), .denied(reason: nil))
        await t.equal("[거절 후 중단] 은 답이 아니라 거절",
                      mark(events(stored(.denyAndCancel, reason: "그만"), echo: "그만")), .denied(reason: "그만"))
        let unattended = ApprovalDecisionInfo.unattendedDenyMessage
        await t.equal("무인 실행(검토 레인)이 거절한 질문은 답이 아니다 (앱의 글)",
                      mark(events(stored(.deny, reason: unattended), echo: unattended)), .denied(reason: unattended))
        // 질문이 아닌 도구의 거절은 그대로 (사유는 결과의 글).
        let bash = [ThreadEvent(id: "a", threadID: "t", runID: "r1", seq: 1, kind: .toolRequest, provider: .claude, title: "Bash",
                                text: #"{"command":"rm -rf build"}"#, toolUseID: "b"),
                    ThreadEvent(id: "b", threadID: "t", runID: "r1", seq: 2, kind: .approvalRequest, provider: .claude,
                                title: "도구 사용: Bash", text: #"{"command":"rm -rf build"}"#, toolUseID: "b"),
                    bare,
                    ThreadEvent(id: "d", threadID: "t", runID: "r1", seq: 4, kind: .toolResult, provider: .claude,
                                title: "Bash — 오류", text: "남겨 두세요", toolUseID: "b")]
        let bashMark = ExecutionParser.entries(from: bash, projectPath: nil).compactMap { entry -> ApprovalMark? in
            if case .command(let info) = entry.kind { return info.approval } else { return nil }
        }.first
        await t.equal("질문이 아닌 도구의 옛 거절은 거절함 · 사유", bashMark, .denied(reason: "남겨 두세요"))
    }

    // MARK: CLI 진단 · 할 일 안내

    /// 진단(실행 명령줄 · app-server 시작 · MCP 준비 · 모르는 CLI 이벤트)은 대화 행이 아니다 — 저장은 하되 스트림이 뺀다.
    /// 사람이 할 일(훅 실패 · MCP 인증 필요)은 실행 기록 블록 밖의 한 줄, 같은 글은 대화에서 가장 최근 것 하나만.
    /// 표시를 달기 전의 옛 기록("안내" · "claude 실행: …")도 진단으로 본다 (첫 사용자 시험 H4).
    static func cliNotices(_ t: TestKit) async {
        await t.group("스트림: CLI 진단 · 할 일 안내")
        var seq: Int64 = 0
        func event(_ kind: EventKind, run: String?, title: String = "", text: String = "", payload: String? = nil,
                   tool: String? = nil) -> ThreadEvent {
            seq += 1
            return ThreadEvent(id: "e\(seq)", threadID: "t", runID: run, seq: seq, kind: kind,
                               provider: kind == .userMessage ? nil : .claude, title: title, text: text,
                               payloadJSON: payload, toolUseID: tool)
        }
        func diagnostic(_ run: String, _ text: String) -> ThreadEvent {
            event(.systemNotice, run: run, title: ThreadEvent.diagnosticTitle, text: text,
                  payload: ThreadEvent.noticePayload(ThreadEvent.diagnosticKey))
        }
        func attention(_ run: String, _ text: String) -> ThreadEvent {
            event(.systemNotice, run: run, title: ThreadEvent.attentionTitle, text: text,
                  payload: ThreadEvent.noticePayload(ThreadEvent.attentionKey))
        }
        let needsAuth = CLINoticeText.mcpNeedsAuth(["claude.ai Google Drive"])
        let events: [ThreadEvent] = [
            event(.userMessage, run: "r1", text: "봐 줘"),
            diagnostic("r1", "claude 실행: claude -p --session-id x"),
            attention("r1", needsAuth),
            event(.toolRequest, run: "r1", title: "Read", text: #"{"file_path":"/p/a.swift"}"#, tool: "read"),
            event(.toolResult, run: "r1", title: "Read", text: "1\tlet a = 1", tool: "read"),
            event(.systemNotice, run: "r1", title: "안내", text: "MCP 서버 상태(CLI 보고): x=connected"),
            event(.agentMessage, run: "r1", text: "봤습니다"),
            event(.userMessage, run: "r2", text: "다시"),
            diagnostic("r2", "codex app-server 시작"),
            attention("r2", needsAuth),
            event(.agentMessage, run: "r2", text: "했습니다"),
            event(.userMessage, run: "r3", text: "또"),
            diagnostic("r3", "claude 실행: …"),
        ]
        func run(_ id: String) -> Run {
            var r = Run(threadID: "t", sessionID: "s", provider: .claude, requestText: "", state: .completed)
            r.id = id
            return r
        }
        let rows = StreamBuilder.rows(events: events, runs: ["r1": run("r1"), "r2": run("r2"), "r3": run("r3")],
                                      handoffs: [], projectPath: "/p")
        let kinds: [String] = rows.map { row -> String in
            switch row {
            case .user: return "user"
            case .agentHeader(let h): return "header:\(h.runID)"
            case .agentMessage: return "message"
            case .execution(_, let entries): return "exec:\(entries.count)"
            case .turnFooter(let runID, _): return "footer:\(runID)"
            case .notice(let e): return e.isAttention ? "할 일" : "notice"
            default: return "other"
            }
        }
        await t.equal("진단은 행이 아니다 · 할 일은 블록 밖 한 줄 (가장 최근 것만) · 진단뿐인 실행도 머리글 · 바닥글", kinds,
                      ["user", "header:r1", "exec:1", "message", "footer:r1",
                       "user", "header:r2", "할 일", "message", "footer:r2",
                       "user", "header:r3", "footer:r3"])
        let notes = rows.flatMap { row -> [ExecutionEntry] in
            if case .execution(_, let entries) = row { return entries } else { return [] }
        }
        await t.check("실행 기록 블록에 안내(진단)가 섞이지 않는다 — 옛 기록의 \"안내 · MCP 서버…\" 도",
                      !notes.contains { if case .note = $0.kind { return true } else { return false } })
        await t.check("진단 판정: 표시 · 옛 기록의 글 · 사람의 안내는 아님",
                      diagnostic("r", "x").isDiagnostic
                        && event(.systemNotice, run: "r", title: "안내", text: "claude stderr: warn").isDiagnostic
                        && !event(.systemNotice, run: "r", title: "안내", text: "대화 압축(compact)이 수행되었습니다.").isDiagnostic
                        && !event(.systemNotice, run: nil, title: "안내", text: "claude 실행: x").isDiagnostic
                        && !attention("r", needsAuth).isDiagnostic && attention("r", needsAuth).isAttention)
        let child = event(.systemNotice, run: "r1", title: ThreadEvent.diagnosticTitle, text: "MCP 서버 x: ready",
                          payload: ThreadEvent.noticePayload(ThreadEvent.diagnosticKey, taggingParent: "A"))
        await t.check("하위 안의 진단은 부모 표시도 달고 하위 흐름에서도 빠진다",
                      child.parentAgentID == "A" && child.isDiagnostic
                        && StreamBuilder.subAgentRows(events: [child], projectPath: nil).isEmpty)
        await t.equal("하위 카드의 '지금 하는 일' 에 진단을 쓰지 않는다", SubAgentDigest.oneLine(child, projectPath: nil), nil)
    }

    // MARK: 시간 · 토큰 · 바닥글 · 인계 줄의 글

    /// 시간 · 토큰은 한 형식 (`DisplayFormat`) — 바닥글 · 경과 시계 · 하위 카드 · 실행 중 상태 줄이 같이 쓴다 (cap-25 · txt-27).
    /// 바닥글 한 줄은 새 토큰(캐시 제외) · 걸린 시간 · API 환산 (H17 · chat-14), 인계 줄은 한국어 표기 (H11).
    static func formats(_ t: TestKit) async {
        await t.group("스트림: 시간 · 토큰 · 바닥글 · 인계 줄")
        await t.equal("걸린 시간: 10초 안은 소수 한 자리(내림) · 그 위는 초 · 분 · 시간",
                      [0, 42, 942, 1_149, 9_960, 12_400, 65_000, 3_599_000, 3_725_000].map { DisplayFormat.duration(ms: $0) },
                      ["0초", "0.1초", "0.9초", "1.1초", "9.9초", "12초", "1분 05초", "59분 59초", "1시간 2분"])
        await t.equal("지난 시간 (1초 시계)", [0, 59, 60, 605, 3_600, 90_061].map { DisplayFormat.elapsed(seconds: $0) },
                      ["0초", "59초", "1분 00초", "10분 05초", "1시간 0분", "25시간 1분"])
        await t.equal("남은 시간", [30, 2_700, 4_560, 266_400].map { DisplayFormat.remaining(seconds: $0) },
                      ["1분", "45분", "1시간 16분", "3일 2시간"])
        await t.equal("토큰: 천 · 만 · 억 (소수 한 자리 내림, .0 은 뺀다)",
                      [842, 1_000, 1_250, 9_999, 10_000, 266_900, 1_234_567, 127_000_000].map { DisplayFormat.tokens($0) },
                      ["842", "1천", "1.2천", "9.9천", "1만", "26.6만", "123.4만", "1.2억"])
        await t.check("시계의 폭 표본은 한 시간 뒤까지 가장 넓은 글을 담는다 (\"59분 59초\")",
                      DisplayFormat.elapsedWidthSamples(from: 5).contains(3_599)
                        && DisplayFormat.elapsedWidthSamples(from: 5).contains(3_605)
                        && DisplayFormat.elapsedWidthSamples(from: 5000) == [5000, 5000, 8600])

        var usage = UsageRecord(runID: "r", threadID: "t", provider: .claude)
        usage.inputTokens = 1_009
        usage.outputTokens = 629
        usage.cacheReadTokens = 265_380
        usage.cacheWriteTokens = 1_200
        usage.durationMs = 59_700
        usage.costUSD = 0.1234
        await t.equal("새 토큰 = 입력 + 출력 (캐시 제외)", usage.newTokens, 1_638)
        await t.equal("바닥글 한 줄: 걸린 시간 · 새 토큰 · API 환산", TurnFooterText.line(usage), "59초 · 새 토큰 1.6천 · API 환산 $0.12")
        await t.equal("펼친 내역: 새 토큰의 합 · 캐시", [TurnFooterText.newTokensBreakdown(usage), TurnFooterText.cacheBreakdown(usage) ?? "-"],
                      ["새 토큰 1,638 = 입력 1,009 + 출력 629",
                       "캐시 읽기 265,380 · 캐시 쓰기 1,200 — 새 토큰에 세지 않습니다 (비용에는 들어갑니다)"])
        let help = TurnFooterText.help(usage, filesUnchanged: true)
        await t.check("도움말: 캐시는 빼고 센다 · 구독이면 청구액이 아니다 · 바뀐 파일 없음",
                      help.contains("캐시 읽기 26.5만") && help.contains("청구되는 금액이 아닙니다")
                        && help.contains("바뀐 파일 없음") && !help.contains("tok"), help)
        var unknownCost = usage
        unknownCost.costUSD = nil
        unknownCost.cacheReadTokens = 0
        unknownCost.cacheWriteTokens = 0
        await t.check("금액을 모르면 그렇게 · 캐시가 없으면 캐시 줄 없음",
                      TurnFooterText.line(unknownCost).hasSuffix("· 금액 미확인") && TurnFooterText.cacheBreakdown(unknownCost) == nil)

        await t.equal("인계 줄의 이름은 한국어", RelayText.title(number: 1), "⇄ 인계 #01")
        await t.equal("전달 실행이 도는 동안은 받는 쪽이 일하는 중",
                      RelayText.status(state: .sending, receiverWorking: true, sameProvider: false, files: 2, tokens: 598),
                      "받는 쪽 실행 중 · 파일 2개 · 약 598 토큰")
        await t.equal("전달 실행이 아직 없으면 전송 중 · 같은 제공자면 세션 안내",
                      RelayText.status(state: .sending, receiverWorking: false, sameProvider: true, files: 0, tokens: nil),
                      "전송 중 · 세션은 이어지지 않습니다")
        await t.equal("전달 확인 · 미확인",
                      [RelayText.status(state: .delivered, receiverWorking: false, sameProvider: false, files: 0, tokens: 12_345),
                       RelayText.status(state: .unknown, receiverWorking: true, sameProvider: false, files: 3, tokens: 10)],
                      ["전달 확인 · 약 1.2만 토큰", "전달 여부 미확인 — 이 대화에 받는 쪽의 응답이 있는지 보세요"])
    }

    static func folding(_ t: TestKit) async {
        await t.group("스트림: 실행 기록 접기")

        func entry(_ id: String, _ kind: ExecutionEntry.Kind, subagent: SubAgentDigest? = nil) -> ExecutionEntry {
            ExecutionEntry(id: id, kind: kind, provider: .claude, createdAt: Date(timeIntervalSince1970: 1_000), subagent: subagent)
        }
        func command(_ text: String, exit: Int? = nil, error: Bool = false, running: Bool = false,
                     stopped: Bool = false, unfinished: Bool = false, label: String? = nil) -> ExecutionEntry.Kind {
            .command(CommandInfo(command: text, rawCommand: text, output: nil, exitCode: exit, reportedError: error,
                                 running: running, cwd: nil, stopped: stopped, unfinished: unfinished, label: label))
        }
        func tool(_ name: String, _ summary: String = "", error: Bool = false, running: Bool = false,
                  unfinished: Bool = false) -> ExecutionEntry.Kind {
            .tool(ToolInfo(name: name, summary: summary, output: nil, reportedError: error, running: running,
                           unfinished: unfinished))
        }
        func edit(_ paths: [String], error: Bool = false) -> ExecutionEntry.Kind {
            .fileEdit(FileEditInfo(paths: paths, diff: nil, added: 1, removed: 0, running: false, reportedError: error))
        }
        func ids(_ entries: [ExecutionEntry]) -> [String] { entries.map(\.id) }

        let done = [entry("a", tool("Read", "Moa/A.swift")), entry("b", tool("Read", "Moa/B.swift")),
                    entry("c", tool("Read", "Moa/A.swift")), entry("d", tool("Grep", "retry  Moa")),
                    entry("e", edit(["Moa/A.swift"])), entry("f", edit(["Moa/A.swift", "Moa/C.swift"])),
                    entry("g", command("swift build", exit: 0)), entry("h", command("swift test", exit: 0)),
                    entry("i", .note(title: "안내", text: "claude 실행: …"))]
        let plan = ExecutionFold.plan(done)
        await t.check("끝난 블록은 요약 한 줄로 접혀 시작한다 — 접힌 채 보이는 항목 없음",
                      plan.summary != nil && plan.visible(done, expanded: false, showingIssues: false).isEmpty)
        await t.equal("펼치면 전부 (순서 그대로)", ids(plan.visible(done, expanded: true, showingIssues: false)), ids(done))
        await t.check("빈 블록은 요약이 없다", ExecutionFold.plan([]).summary == nil)

        let summary = ExecutionFold.summary(done)
        await t.equal("접힌 줄: 명령 n개 실행 먼저 · 읽은 파일은 경로로 센다 · 검색 · 편집한 파일", summary.text,
                      "명령 2개 실행 · 파일 2개 읽음 · 검색 1번 · 파일 2개 편집")
        await t.check("접힌 줄에 명령 원문 · 종료 코드는 없다 (단계를 펼쳐야 보인다)",
                      !summary.plainText.contains("swift") && !summary.plainText.contains("종료") && summary.issues.isEmpty,
                      summary.plainText)

        // 펼치면 단계마다 한 줄: CLI 가 준 작업 설명 (Claude Bash 의 description), 없으면 사실만.
        let described = [entry("a", tool("Read", "Package.swift")),
                         entry("b", command("git status --short", exit: 0, label: "Check working tree")),
                         entry("c", command("swift test", exit: 1, label: "Run test suite")),
                         entry("d", command("swift test --filter Auth 2>&1 | tail", running: true)),
                         entry("e", edit(["Moa/A.swift", "Moa/B.swift"])), entry("f", tool("Grep", "retry  Moa")),
                         entry("g", .reasoning("**Planning build checks**\n**Running tests**"))]
        await t.equal("단계 줄의 글",
                      described.map { ExecutionFold.step($0).title },
                      ["읽기 · Package.swift", "Check working tree", "Run test suite", "swift test --filter Auth 2>&1 | tail",
                       "편집 · Moa/A.swift 외 1개", "검색 · retry  Moa", "추론 · Running tests"])
        await t.equal("설명이 없는 명령만 고정폭 (원문 첫 줄)", described.map { ExecutionFold.step($0).monospaced },
                      [false, false, false, true, false, false, false])
        await t.equal("단계 줄 끝의 상태: 오류 · 도는 중 (끝났고 문제없으면 없음)",
                      described.map { ExecutionFold.step($0).status?.text ?? "-" }, ["-", "-", "오류", "실행 중", "-", "-", "-"])
        await t.equal("접힌 줄의 글", ExecutionFold.summary(described).plainText,
                      "명령 3개 실행 · 파일 1개 읽음 · 검색 1번 · 파일 2개 편집 · 오류 1개")

        // 오류가 섞여도 블록 전체를 펼치지 않는다 — 개수만, 누르면 그 항목만.
        let mixed = done + [entry("x1", command("swift test", exit: 1)), entry("x2", command("rm x", error: true)),
                            entry("x3", command("sleep 5", stopped: true)), entry("x4", command("sleep 9", unfinished: true)),
                            entry("x5", tool("Read", "y", error: true)), entry("x6", tool("Read", "z", unfinished: true)),
                            entry("x7", edit(["w"], error: true))]
        let mixedPlan = ExecutionFold.plan(mixed)
        await t.equal("개수: 오류 · 멈춤 · 결과 미확인 (화면 순서)", mixedPlan.summary?.issueText, "오류 4개 · 멈춤 1개 · 결과 미확인 2개")
        await t.check("오류가 있어도 접힌 채 — 성공한 항목은 보이지 않는다",
                      mixedPlan.visible(mixed, expanded: false, showingIssues: false).isEmpty)
        await t.equal("개수를 누르면 그 항목만 (순서 그대로)",
                      ids(mixedPlan.visible(mixed, expanded: false, showingIssues: true)), ["x1", "x2", "x3", "x4", "x5", "x6", "x7"])
        await t.equal("요약 글: 명령 8개 실행 · 오류 n개 꼴",
                      ExecutionFold.summary([entry("a", command("make", exit: 0)), entry("b", command("make test", exit: 2))]).plainText,
                      "명령 2개 실행 · 오류 1개")

        // 도는 실행의 블록도 같은 모양 — 도구가 붙거나 끝나도 접혔다 펴지지 않는다.
        let running = done + [entry("r", command("swift test", running: true))]
        let runningPlan = ExecutionFold.plan(running)
        await t.check("도는 명령은 봐야 할 상태가 아니다 (상태 줄이 말한다) · 접힌 채",
                      runningPlan.summary?.issues.isEmpty == true
                        && runningPlan.visible(running, expanded: false, showingIssues: false).isEmpty)
        let finishedLater = done + [entry("r", command("swift test", exit: 0))]
        await t.equal("명령이 끝나도 보이는 항목은 그대로 (흔들리지 않는다)",
                      ids(ExecutionFold.plan(finishedLater).visible(finishedLater, expanded: false, showingIssues: false)),
                      ids(runningPlan.visible(running, expanded: false, showingIssues: false)))
        let awaiting = ExecutionEntry(id: "w", kind: .command(CommandInfo(
            command: "rm -rf build", rawCommand: "rm -rf build", output: nil, exitCode: nil, reportedError: false, running: true,
            cwd: nil, approval: .awaiting)), provider: .claude, createdAt: Date(timeIntervalSince1970: 1_000))
        await t.equal("승인 대기는 개수로 (답하는 곳은 대화 끝의 승인 카드)",
                      ExecutionFold.plan(done + [awaiting]).summary?.issueText, "승인 대기 1개")

        // 접혀도 보이는 것: 하위 작업 카드 · 답하지 않은 질문.
        func digest(_ status: SubAgentInfo.Status) -> SubAgentDigest {
            let info = SubAgentInfo(id: "A", taskID: "task-A", kind: .agent, title: "조사", detail: "Explore", isBackground: false,
                                    status: status, startedAt: Date(timeIntervalSince1970: 1_000), endedAt: nil, toolUses: 3,
                                    summary: nil)
            return SubAgentDigest(info: info, runID: "r1", runFinished: status != .running, toolCount: 3, lastLine: nil)
        }
        for status in [SubAgentInfo.Status.running, .completed, .failed] {
            let block = [entry("a", tool("Agent", "조사"), subagent: digest(status)), entry("b", tool("Read", "x"))]
            let blockPlan = ExecutionFold.plan(block)
            await t.check("하위 작업 카드는 접혀도 보이고 요약에서 빠진다 (\(status))",
                          ids(blockPlan.visible(block, expanded: false, showingIssues: false)) == ["a"]
                            && blockPlan.summary?.text == "파일 1개 읽음")
        }
        let onlyAgents = [entry("a", tool("Agent", "조사"), subagent: digest(.completed))]
        await t.check("하위 작업 카드뿐인 블록은 요약 없이 그대로",
                      ExecutionFold.plan(onlyAgents).summary == nil
                        && ids(ExecutionFold.plan(onlyAgents).visible(onlyAgents, expanded: false, showingIssues: false)) == ["a"])
        let question = done + [entry("q", .question("어느 쪽으로 할까요?"))]
        await t.equal("답하지 않은 질문은 접혀도 보인다",
                      ids(ExecutionFold.plan(question).visible(question, expanded: false, showingIssues: false)), ["q"])

        // CLI 의 작업 설명: Claude Bash 의 description · Codex 추론 요약의 머리 줄.
        if case .command(let info) = ExecutionParser.requestKind(
            name: "Bash", input: #"{"command":"swift test 2>&1 | tail","description":"Run test suite"}"#, projectPath: nil) {
            await t.equal("Bash 의 description 을 작업 설명으로", info.label, "Run test suite")
        } else {
            await t.check("Bash 요청은 명령 행", false)
        }
        if case .command(let info) = ExecutionParser.requestKind(name: "Bash", input: #"{"command":"ls"}"#, projectPath: nil) {
            await t.check("설명이 없으면 nil", info.label == nil)
        }
        await t.equal("추론 요약의 머리 줄 (줄 통째로 굵은 것만)",
                      ExecutionFold.reasoningHeadings("**Planning build checks**\n**Running tests**\n본문의 **강조** 는 아니다\n**"),
                      ["Planning build checks", "Running tests"])
        await t.equal("추론 행의 머리 줄은 별표 없이 (문장 안의 강조는 그대로)",
                      ExecutionFold.reasoningDisplayText("**Planning build checks**\n본문의 **강조**"),
                      "Planning build checks\n본문의 **강조**")
        await t.equal("Codex 의 추론 단계: 추론 요약의 마지막 머리",
                      ExecutionFold.step(ExecutionEntry(id: "r", kind: .reasoning("**Inspecting project layout**\n**Verifying build**"),
                                                        provider: .codex, createdAt: Date(timeIntervalSince1970: 1_000))).title,
                      "추론 · Verifying build")

        // 도구 이름: 세 CLI 의 이름을 함께 본다.
        await t.equal("도구 종류 (Claude · Codex · Antigravity)",
                      ["Read", "view_file", "Grep", "grep_search", "WebFetch", "webSearch", "mcpToolCall", "TodoWrite"]
                        .map { "\(ExecutionFold.toolKind($0))" },
                      ["read", "read", "search", "search", "web", "web", "other", "other"])
        await t.equal("일이 없는 블록: 추론 · 안내 · 결정",
                      [ExecutionFold.summary([entry("a", .reasoning("생각"))]).text,
                       ExecutionFold.summary([entry("a", .note(title: "안내", text: "codex app-server 시작"))]).text,
                       ExecutionFold.summary([entry("a", .decision("허용"))]).text],
                      ["추론", "안내 1개", "기록 1개"])
        await t.equal("경로 없는 읽기 · 편집은 호출 수로",
                      ExecutionFold.summary([entry("a", tool("Read")), entry("b", .fileEdit(FileEditInfo(
                          paths: [], diff: nil, added: nil, removed: nil, running: false, reportedError: false)))]).text,
                      "읽기 1번 · 편집 1번")

        // 스트림에서 온 블록 그대로: 끝난 실행의 결과 없는 호출은 "결과 미확인" 으로 센다.
        let events = [
            ThreadEvent(id: "e1", threadID: "t", runID: "r1", seq: 1, kind: .userMessage, provider: nil, text: "봐 줘"),
            ThreadEvent(id: "e2", threadID: "t", runID: "r1", seq: 2, kind: .toolRequest, provider: .claude, title: "Read",
                        text: #"{"file_path":"/p/a.swift"}"#, toolUseID: "read"),
            ThreadEvent(id: "e3", threadID: "t", runID: "r1", seq: 3, kind: .toolResult, provider: .claude, title: "Read",
                        text: "1\tlet a = 1", toolUseID: "read"),
            ThreadEvent(id: "e4", threadID: "t", runID: "r1", seq: 4, kind: .agentMessage, provider: .claude, text: "봤습니다"),
            ThreadEvent(id: "e5", threadID: "t", runID: "r1", seq: 5, kind: .toolRequest, provider: .claude, title: "Bash",
                        text: #"{"command":"make","description":"Build"}"#, toolUseID: "bash"),
        ]
        var run = Run(threadID: "t", sessionID: "s", provider: .claude, requestText: "봐 줘", state: .completed)
        run.id = "r1"
        let rows = StreamBuilder.rows(events: events, runs: ["r1": run], handoffs: [], projectPath: "/p")
        let blocks = rows.compactMap { row in
            if case .execution(_, let entries) = row { return entries } else { return nil }
        }
        await t.equal("블록 둘", blocks.count, 2)
        if blocks.count == 2 {
            await t.check("결과를 받은 읽기 블록: 봐야 할 것 없음", ExecutionFold.plan(blocks[0]).summary?.issues.isEmpty == true)
            await t.equal("끝난 실행에 결과 없이 남은 명령: 결과 미확인 1개",
                          ExecutionFold.plan(blocks[1]).summary?.plainText, "명령 1개 실행 · 결과 미확인 1개")
            await t.equal("그 단계 줄: 설명 · 결과 미확인", blocks[1].first.map { ExecutionFold.step($0) },
                          ExecutionFold.Step(title: "Build", monospaced: false, status: .unfinished))
            await t.equal("대화 안 찾기: 맞은 단계 (블록과 그 단계를 펼친다) — 설명 · 원문 모두",
                          [ThreadFind.matchingEntryIDs("build", in: blocks[1]), ThreadFind.matchingEntryIDs("make", in: blocks[1]),
                           ThreadFind.matchingEntryIDs("없는 말", in: blocks[1])].map(\.count), [1, 1, 0])
        }
        await t.check("대화 안 찾기: 작업 설명도 찾는다", ThreadFind.matches("Build", in: rows).count == 1)

        // 실행 중 상태 줄: 명령은 작업 설명으로, Codex 의 생각은 추론 요약의 머리로.
        func activity(_ list: [ThreadEvent]) -> RunActivity {
            RunActivity.make(state: .running, runID: "r1", waitingOnBackground: false, backgroundCount: 0, events: list,
                             streaming: nil, projectPath: "/p")
        }
        await t.equal("도는 명령: 작업 설명", activity(Array(events.prefix(1)) + [events[4]]), .tool("명령 실행 중 · Build"))
        let thinking = ThreadEvent(id: "e6", threadID: "t", runID: "r1", seq: 6, kind: .agentReasoning, provider: .codex,
                                   text: "**Inspecting project layout**\n**Verifying build**")
        await t.equal("Codex 의 생각: 추론 요약의 마지막 머리", activity(Array(events.prefix(1)) + [thinking]), .working("Verifying build"))
        await t.equal("머리 뒤에 말했으면 지난 생각", activity(Array(events.prefix(1)) + [thinking, events[3]]), .thinking)
    }

    // MARK: 턴 머리줄 · 바닥글

    /// 머리줄의 모델 이름(목록의 이름 · Claude 전체 ID 의 이름 규칙 · 모르면 그대로)과,
    /// 단서 없이 바뀐 파일이 없는 실행은 카드 대신 바닥글 끝에 적는 것.
    static func turnMeta(_ t: TestKit) async {
        await t.group("스트림: 턴 머리줄 · 바닥글")

        await t.equal("Claude 전체 ID 의 이름",
                      ["claude-opus-5-5", "claude-sonnet-5", "claude-haiku-4-5-20251001", "claude-fable-5-1",
                       "claude-opus-5-5[1m]", "claude-sonnet-5-20260101"].map { ModelCatalog.claudeModelName($0) ?? "nil" },
                      ["Opus 5.5", "Sonnet 5", "Haiku 4.5", "Fable 5.1", "Opus 5.5 · 1M", "Sonnet 5"])
        await t.equal("모양이 다르면 이름을 짓지 않는다",
                      ["gpt-5.6-sol", "claude-instant-1", "claude-opus-5-5-extra", "claude-opus", "opus"]
                        .map { ModelCatalog.claudeModelName($0) ?? "nil" },
                      ["nil", "nil", "nil", "nil", "nil"])
        let codex = [AgentModelOption(provider: .codex, identifier: "gpt-5.6-sol", displayName: "GPT-5.6 Sol"),
                     AgentModelOption(provider: .codex, identifier: "gpt-6-sol", displayName: "GPT-6 Sol")]
        let claude = [AgentModelOption(provider: .claude, identifier: "opus", displayName: "Opus 5.5")]
        await t.equal("머리줄의 모델 이름: 목록 · 계열 선택 · 별칭 · Claude 전체 ID · 모르면 그대로",
                      [ModelCatalog.runModelName("gpt-5.6-sol", catalog: codex),
                       ModelCatalog.runModelName("gpt-*-sol", catalog: codex),
                       ModelCatalog.runModelName("opus", catalog: claude),
                       ModelCatalog.runModelName("claude-opus-5-5", catalog: claude),
                       ModelCatalog.runModelName("gpt-4.1", catalog: codex)],
                      ["GPT-5.6 Sol", "GPT-6 Sol", "Opus 5.5", "Opus 5.5", "gpt-4.1"])

        // 비교했고 단서 없이 바뀐 파일이 없으면 카드를 두지 않고 바닥글에 적는다. HEAD 가 바뀐 것처럼 단서가 있으면 카드를 남긴다.
        func changes(_ runID: String, headChanged: Bool) -> RunFileChanges {
            RunFileChanges(runID: runID, compared: true, unavailable: nil, files: [], fileCount: 0, added: nil, removed: nil,
                           unmeasured: 0, preexisting: 0, headChanged: headChanged)
        }
        var seq: Int64 = 0
        func event(_ kind: EventKind, run: String, text: String = "") -> ThreadEvent {
            seq += 1
            return ThreadEvent(id: "e\(seq)", threadID: "t", runID: run, seq: seq, kind: kind,
                               provider: kind == .userMessage ? nil : .claude, text: text)
        }
        func summary(_ c: RunFileChanges) -> ThreadEvent {
            seq += 1
            var e = c.event(threadID: "t", provider: .claude)
            e.id = "e\(seq)"
            e.seq = seq
            return e
        }
        let events = [event(.userMessage, run: "r1", text: "봐 줘"), event(.agentMessage, run: "r1", text: "봤습니다"),
                      summary(changes("r1", headChanged: false)),
                      event(.userMessage, run: "r2", text: "커밋해 줘"), event(.agentMessage, run: "r2", text: "커밋했습니다"),
                      summary(changes("r2", headChanged: true))]
        func run(_ id: String) -> Run {
            var r = Run(threadID: "t", sessionID: "s", provider: .claude, requestText: "", state: .completed)
            r.id = id
            return r
        }
        let rows = StreamBuilder.rows(events: events, runs: ["r1": run("r1"), "r2": run("r2")], handoffs: [], projectPath: "/p")
        let kinds = rows.map { row -> String in
            switch row {
            case .runChanges(let r): return "changes:\(r.runID)"
            case .turnFooter(let runID, let unchanged): return "footer:\(runID)" + (unchanged ? "·바뀐 파일 없음" : "")
            case .user: return "user"
            case .agentHeader: return "header"
            case .agentMessage: return "message"
            default: return "other"
            }
        }
        await t.equal("바뀐 파일 없음은 바닥글로 · HEAD 가 바뀐 실행은 카드가 남는다", kinds,
                      ["user", "header", "message", "footer:r1·바뀐 파일 없음",
                       "user", "header", "message", "changes:r2", "footer:r2"])
        await t.check("단서 없음 판정: 비교함 · 파일 0 · 단서 없음일 때만",
                      changes("x", headChanged: false).unchangedWithoutCaveats && !changes("x", headChanged: true).unchangedWithoutCaveats
                      && !RunFileChanges.notCompared(runID: "x", reason: .readFailed).unchangedWithoutCaveats)
    }
}
