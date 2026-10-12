import Foundation

// MARK: - 하위 에이전트 · 백그라운드 작업: 화면의 순수 부분

/// 화면이 하위 작업을 어떻게 나누고 요약하는지 (SwiftUI 없이): 대화 상태 상자의 메인 · 하위 나누기, 대화 스트림이 하위 이벤트를
/// 빼고 띄운 행에 요약을 붙이는 것, 인스펙터 "에이전트" 탭의 흐름 · 목록 · 고르기, 끝난 실행 안의 `running`, 멈춘 명령,
/// 대기 글 · 잠금 글. 마지막에 `AppModel` 이 가짜 어댑터의 대기 실행을 받아 대화 상자 · 잠금 수에 반영하는지 본다.
@MainActor
enum SubAgentUITests {

    static func run(_ t: TestKit) async {
        await paneSplit(t)
        do { try await paneReload(t) } catch {
            await t.group("하위 에이전트 화면: 다시 읽기")
            await t.check("시나리오 실행 중 예외", false, "\(error)")
        }
        await streamRows(t)
        await anchorUpdates(t)
        await flowRows(t)
        await statusAndList(t)
        await texts(t)
        await tokenShares(t)
        await rowsCache(t)
        await shellAnchor(t)
        await plainLines(t)
        await observedEdits(t)
        await ownedShell(t)
        await terminalShells(t)
        await workflowRequest(t)
        await listLayout(t)
        await assignedTask(t)
        do { try await appModel(t) } catch {
            await t.group("하위 에이전트 화면: 앱")
            await t.check("시나리오 실행 중 예외", false, "\(error)")
        }
    }

    // MARK: 도우미

    static let tag = { (agent: String) in ThreadEvent.payload(nil, taggingParent: agent) }

    static func event(_ seq: Int64, _ kind: EventKind, title: String = "", text: String = "", toolUseID: String? = nil,
                      payload: String? = nil, run: String = "r1", streaming: Bool = false) -> ThreadEvent {
        ThreadEvent(id: "e\(seq)", threadID: "t", runID: run, seq: seq, kind: kind, provider: .claude, title: title,
                    text: text, payloadJSON: payload, toolUseID: toolUseID, isStreaming: streaming)
    }

    /// 셸은 기본이 백그라운드다 — 앱이 다루는 셸 작업은 뒤에서 도는 명령이고, 앞에서 돈 셸(`isInternalStep`)은 따로 시험한다.
    static func info(_ id: String, _ status: SubAgentInfo.Status = .running, kind: SubAgentInfo.Kind = .agent,
                     title: String? = nil, toolUses: Int? = nil, summary: String? = nil, isBackground: Bool? = nil,
                     startedAt: Date = Date(timeIntervalSince1970: 1_000)) -> SubAgentInfo {
        SubAgentInfo(id: id, taskID: "task-\(id)", kind: kind, title: title ?? "하위 \(id)", detail: "Explore",
                     isBackground: isBackground ?? (kind == .shell), status: status, startedAt: startedAt,
                     endedAt: status == .running ? nil : startedAt.addingTimeInterval(65), toolUses: toolUses, summary: summary)
    }

    static func statusRow(_ seq: Int64, _ info: SubAgentInfo, run: String = "r1") -> ThreadEvent {
        ThreadEvent(id: ThreadEvent.subAgentEventID(runID: run, agentID: info.id), threadID: "t", runID: run, seq: seq,
                    kind: .subAgent, provider: .claude, title: info.title, text: info.summary ?? "",
                    payloadJSON: info.jsonString)
    }

    static func makeRun(_ id: String, _ state: RunState, startedAt: Date = Date(timeIntervalSince1970: 1_000)) -> Run {
        var run = Run(threadID: "t", sessionID: "s", provider: .claude, requestText: "요청", state: state)
        run.id = id
        run.startedAt = startedAt
        return run
    }

    /// Claude 식 대화: 메인이 Agent 둘을 띄우고, 하위 둘이 일하고, 메인이 답한다.
    static var claudeThread: [ThreadEvent] {
        [event(1, .userMessage, text: "둘로 나눠 조사해 줘"),
         event(2, .toolRequest, title: "Agent", text: #"{"description":"화면 조사","subagent_type":"Explore","prompt":"..."}"#,
               toolUseID: "A"),
         event(3, .toolRequest, title: "Agent", text: #"{"description":"저장 조사","subagent_type":"Explore","prompt":"..."}"#,
               toolUseID: "B"),
         statusRow(4, info("A")),
         statusRow(5, info("B")),
         event(6, .systemNotice, title: "안내", text: "요청: 화면을 조사해", payload: tag("A")),
         event(7, .toolRequest, title: "Read", text: #"{"file_path":"/p/UI/View.swift"}"#, toolUseID: "c1", payload: tag("A")),
         event(8, .toolResult, title: "도구 결과", text: "1\tstruct View", toolUseID: "c1", payload: tag("A")),
         event(9, .agentMessage, title: "Claude", text: "하위 B 의 답\n둘째 줄", payload: tag("B")),
         event(10, .toolResult, title: "도구 결과", text: "화면 조사 결과", toolUseID: "A"),
         event(11, .toolResult, title: "도구 결과", text: "저장 조사 결과", toolUseID: "B"),
         event(12, .agentMessage, title: "Claude", text: "메인 답")]
    }

    // MARK: 대화 상태 상자 나누기

    static func paneSplit(_ t: TestKit) async {
        await t.group("하위 에이전트 화면: 대화 상자 나누기")
        let pane = ThreadPaneModel(threadID: "t")
        for e in claudeThread { pane.upsert(e) }
        await t.equal("전부는 그대로 (편집한 파일 · 터미널 · 인계가 본다)", pane.events.count, 12)
        await t.equal("메인 흐름은 하위 이벤트 · 상태 행을 뺀다", pane.mainEvents.map(\.seq), [1, 2, 3, 10, 11, 12])
        await t.equal("하위별 흐름", pane.subAgentEvents.mapValues { $0.map(\.seq) }, ["A": [6, 7, 8], "B": [9]])
        await t.equal("하위 상태 · 띄운 실행", pane.subAgentInfos.keys.sorted(), ["A", "B"])
        await t.check("하위 상태의 실행 ID", pane.subAgentRunIDs == ["A": "r1", "B": "r1"])

        // 메인 응답이 흐르는 중 하위 이벤트가 끼어도 메인의 흐르는 글은 제자리에서 자란다.
        pane.upsert(event(13, .agentMessage, title: "Claude", text: "이어", streaming: true))
        pane.upsert(event(14, .toolRequest, title: "Grep", text: #"{"pattern":"x"}"#, toolUseID: "c2", payload: tag("A")))
        pane.upsert(event(13, .agentMessage, title: "Claude", text: "이어지는 메인 글", streaming: true))
        await t.check("흐르는 메인 글은 메인 흐름의 마지막에서 자란다",
                      pane.mainEvents.last?.id == "e13" && pane.mainEvents.last?.text == "이어지는 메인 글"
                        && pane.subAgentEvents["A"]?.last?.id == "e14")
        // 상태 행은 같은 ID 로 덮어쓴다.
        pane.upsert(statusRow(4, info("A", .completed, summary: "A 끝")))
        await t.check("상태 행 덮어쓰기는 행을 늘리지 않고 상태만 바꾼다",
                      pane.events.count == 14 && pane.subAgentInfos["A"]?.status == .completed
                        && pane.subAgentInfos["A"]?.summary == "A 끝")
        let parts = ThreadPaneModel.partition(pane.events)
        await t.check("한꺼번에 나눈 것과 하나씩 넣은 것이 같다",
                      parts.main == pane.mainEvents && parts.children == pane.subAgentEvents
                        && parts.infos == pane.subAgentInfos && parts.runIDs == pane.subAgentRunIDs)
        // 순번이 거꾸로 온 하위 이벤트는 제자리로.
        pane.upsert(event(5_0, .toolResult, title: "도구 결과", text: "늦게", toolUseID: "c3", payload: tag("B")))
        pane.upsert(event(4_9, .toolRequest, title: "Read", text: "{}", toolUseID: "c3", payload: tag("B")))
        await t.equal("하위 흐름도 순번순", pane.subAgentEvents["B"]?.map(\.seq), [9, 49, 50])
    }

    /// 저장소에서 다시 읽어도 같은 나누기 (재정렬 · 흐르는 글 보존 규칙은 그대로).
    static func paneReload(_ t: TestKit) async throws {
        await t.group("하위 에이전트 화면: 다시 읽기")
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-subui-\(UUID().uuidString).sqlite3")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let store = Store(databaseURL: url)
        try await store.bootstrap()
        let project = Project(name: "p", path: "/tmp/p")
        try await store.upsertProject(project)
        let thread = ConversationThread(id: "t", projectID: project.id, title: "t")
        try await store.upsertThread(thread)
        var r = makeRun("r1", .completed)
        r.sessionID = (try await store.ensureSession(threadID: "t", provider: .claude, accountID: "")).id
        try await store.insertRun(r)
        for e in claudeThread { _ = try await store.appendEvent(e) }
        let pane = ThreadPaneModel(threadID: "t")
        await pane.reload(store: store)
        await t.equal("다시 읽은 메인 흐름", pane.mainEvents.map(\.id), ["e1", "e2", "e3", "e10", "e11", "e12"])
        await t.equal("다시 읽은 하위 흐름", pane.subAgentEvents.mapValues { $0.map(\.id) }, ["A": ["e6", "e7", "e8"], "B": ["e9"]])
        await t.check("다시 읽은 하위 상태 · 실행", pane.subAgentInfos["A"]?.title == "하위 A" && pane.subAgentRunIDs["B"] == "r1")
    }

    // MARK: 대화 스트림

    static func streamRows(_ t: TestKit) async {
        await t.group("하위 에이전트 화면: 대화 스트림")
        let pane = ThreadPaneModel(threadID: "t")
        for e in claudeThread { pane.upsert(e) }
        let runs = ["r1": makeRun("r1", .completed)]
        let digests = StreamBuilder.subAgentDigests(infos: pane.subAgentInfos, runIDs: pane.subAgentRunIDs,
                                                    events: pane.subAgentEvents, runs: runs, projectPath: "/p")
        let rows = StreamBuilder.rows(events: pane.events, runs: runs, handoffs: [], projectPath: "/p", subAgents: digests)
        let messages = rows.compactMap { row -> String? in if case .agentMessage(let e) = row { return e.text } else { return nil } }
        await t.equal("응답 행은 메인 것만 (하위의 답은 메인 말이 아니다)", messages, ["메인 답"])
        let entries = rows.flatMap { row -> [ExecutionEntry] in if case .execution(_, let e) = row { return e } else { return [] } }
        await t.equal("실행 기록은 메인의 도구 행만 (하위의 Read · 요청 안내가 섞이지 않는다)", entries.map(\.id), ["tool:A", "tool:B"])
        await t.check("상태 행은 안내 행이 되지 않는다",
                      !rows.contains { if case .notice(let e) = $0 { return e.kind == .subAgent } else { return false } })
        await t.check("띄운 행마다 요약이 붙는다", entries.allSatisfy { $0.subagent != nil })
        await t.equal("A: 하위 흐름의 도구 수 · 마지막 일", [entries[0].subagent?.toolCount, entries[1].subagent?.toolCount], [1, 0])
        await t.equal("A 의 마지막 일은 도구 한 줄", entries[0].subagent?.lastLine, "Read UI/View.swift")
        await t.equal("B 의 마지막 일은 응답 첫 줄", entries[1].subagent?.lastLine, "하위 B 의 답")
        let segments = ExecutionSegment.group(entries)
        await t.check("이어진 하위 행은 카드 하나로", segments.count == 1
                      && { if case .subAgents(_, let e) = segments[0] { return e.count == 2 } else { return false } }())
        let mixed = ExecutionSegment.group([ExecutionEntry(id: "tool:x", kind: .reasoning("r"), createdAt: Date())] + entries
                                           + [ExecutionEntry(id: "cmd:y", kind: .reasoning("r"), createdAt: Date())])
        await t.equal("카드 앞뒤의 행은 그대로", mixed.map(\.id), ["tool:x", "agents-tool:A", "cmd:y"])
        let plain = StreamBuilder.rows(events: pane.events, runs: runs, handoffs: [], projectPath: "/p")
        await t.check("요약이 없어도 하위 이벤트는 행이 되지 않는다 (방어)",
                      plain.flatMap { row -> [ExecutionEntry] in if case .execution(_, let e) = row { return e } else { return [] } }
                        .map(\.id) == ["tool:A", "tool:B"])
        // 요약만 바뀌면 다시 묶지 않고 갈아 붙인다.
        var changed = digests
        changed["A"]?.info.status = .completed
        let patched = StreamBuilder.attaching(changed, to: rows)
        let patchedEntries = patched.flatMap { row -> [ExecutionEntry] in if case .execution(_, let e) = row { return e } else { return [] } }
        await t.check("요약 갈아 붙이기", patched.count == rows.count && patchedEntries.first?.subagent?.info.status == .completed
                        && patchedEntries.last?.subagent == digests["B"])
    }

    /// Codex: 하위가 끝날 때의 앵커 결과 · 백그라운드 명령의 완료가 메인 응답 뒤에 와도 띄운 자리에 모인다.
    static func anchorUpdates(_ t: TestKit) async {
        await t.group("하위 에이전트 화면: 늦게 온 앵커 갱신")
        let events = [
            event(1, .userMessage, text: "해 줘"),
            event(2, .toolRequest, title: "subAgent", text: #"{"agentPath":"/root/fix","agentThreadId":"T"}"#, toolUseID: "T"),
            event(3, .commandExecution, title: "sleep 5", text: "sleep 5", toolUseID: "X", payload: #"{"status":"inProgress"}"#),
            event(4, .agentMessage, title: "Codex", text: "메인 턴 끝"),
            event(5, .toolResult, title: "subAgent", text: "하위의 최종 답", toolUseID: "T"),
            event(6, .commandExecution, title: "sleep 5", text: "sleep 5\n\n--- 출력 ---\nok", toolUseID: "X",
                  payload: #"{"status":"completed","exitCode":0}"#),
        ]
        let digests = StreamBuilder.subAgentDigests(
            infos: ["T": info("T", .completed, title: "fix"), "X": info("X", .completed, kind: .shell, title: "sleep 5")],
            runIDs: ["T": "r1", "X": "r1"], events: [:], runs: ["r1": makeRun("r1", .completed)], projectPath: nil)
        let rows = StreamBuilder.rows(events: events, runs: [:], handoffs: [], projectPath: nil, subAgents: digests)
        let kinds = rows.map { row -> String in
            switch row {
            case .execution(_, let e): return "exec(" + e.map(\.id).joined(separator: ",") + ")"
            case .agentMessage: return "message"
            case .user: return "user"
            default: return "other"
            }
        }
        await t.equal("응답 뒤에 따로 생기는 행이 없다", kinds.filter { $0 != "other" }, ["user", "exec(tool:T,cmd:X)", "message"])
        let entries = rows.flatMap { row -> [ExecutionEntry] in if case .execution(_, let e) = row { return e } else { return [] } }
        await t.check("앵커는 결과를 받아 실행 중이 아니다", {
            guard case .tool(let tool) = entries[0].kind, case .command(let command) = entries[1].kind else { return false }
            return !tool.running && tool.output == "하위의 최종 답" && !command.running && command.exitCode == 0
        }())
        await t.equal("요약이 없으면 순서를 바꾸지 않는다", StreamBuilder.gatheringAnchorUpdates(events, anchors: []).map(\.seq),
                      [1, 2, 3, 4, 5, 6])
    }

    // MARK: 인스펙터 "에이전트" 탭의 목록

    /// 목록은 세로로 한 줄씩: 하위가 앞에서 돌린 셸은 빼고, 하위가 띄운 백그라운드 명령은 그 하위 아래에 들이고,
    /// 실행마다 묶는다 (2026-09-24 — 하위 다섯이 저마다 `sleep 10` 을 돌리자 칩 줄에 셸 다섯이 따로 늘어섰다).
    /// 에이전트 탭의 "맡은 일": 하위 흐름의 첫 요청 (Claude 의 "요청: …" 안내 · 사용자 메시지 꼴), 진단 · 다른 안내는 아니다.
    static func assignedTask(_ t: TestKit) async {
        await t.group("하위 에이전트 화면: 맡은 일")
        func event(_ kind: EventKind, _ text: String, diagnostic: Bool = false) -> ThreadEvent {
            ThreadEvent(threadID: "t", runID: "r", kind: kind, provider: .claude, title: "안내", text: text,
                        payloadJSON: diagnostic ? ThreadEvent.noticePayload(ThreadEvent.diagnosticKey, taggingParent: "a") : nil)
        }
        await t.equal("Claude 의 요청 안내 — 머리를 떼고", SubAgentList.assignedTask([event(.systemNotice, "요청:  README 를 읽어 줘 \n")]),
                      "README 를 읽어 줘")
        await t.equal("다른 안내 · 진단은 건너뛰고 첫 요청", SubAgentList.assignedTask([
            event(.systemNotice, "작업을 시작했습니다"), event(.systemNotice, "요청: 진단 글", diagnostic: true),
            event(.agentMessage, "읽겠습니다"), event(.userMessage, "테스트를 돌려 줘"), event(.systemNotice, "요청: 둘째")]),
                      "테스트를 돌려 줘")
        await t.equal("요청이 없으면 없다 (Codex 하위)", SubAgentList.assignedTask([event(.agentMessage, "답"), event(.systemNotice, "요청: ")]),
                      nil)
    }

    static func listLayout(_ t: TestKit) async {
        await t.group("하위 에이전트 화면: 목록")
        let t0 = Date(timeIntervalSince1970: 100)
        func shell(_ id: String, owner: String?, background: Bool, at offset: TimeInterval) -> SubAgentInfo {
            var s = info(id, .completed, kind: .shell, title: "sleep 10", isBackground: background, startedAt: t0.addingTimeInterval(offset))
            s.ownerID = owner
            return s
        }
        let stored: [String: SubAgentInfo] = [
            "A": info("A", .completed, startedAt: t0), "B": info("B", .completed, startedAt: t0.addingTimeInterval(1)),
            "fgA": shell("fgA", owner: "A", background: false, at: 5), "fgB": shell("fgB", owner: "B", background: false, at: 6),
            "bgA": shell("bgA", owner: "A", background: true, at: 7),
            "main": shell("main", owner: nil, background: true, at: 0.5),
            "old": info("old", .completed, startedAt: Date(timeIntervalSince1970: 10)),
        ]
        let runIDs = ["A": "r2", "B": "r2", "fgA": "r2", "fgB": "r2", "bgA": "r2", "main": "r2", "old": "r1"]
        let runs = ["r1": makeRun("r1", .completed, startedAt: Date(timeIntervalSince1970: 10)),
                    "r2": makeRun("r2", .completed, startedAt: t0)]
        let items = SubAgentList.items(stored: stored, runIDs: runIDs, runs: runs, live: [], liveRunID: nil)
        await t.equal("앞에서 돈 셸은 빼고, 하위가 띄운 백그라운드 명령은 그 하위 바로 아래", items.map(\.id),
                      ["A", "bgA", "main", "B", "old"])
        await t.equal("들여쓰기 깊이", items.map(\.depth), [0, 1, 0, 0, 0])
        await t.check("앞에서 돈 셸", stored["fgA"]?.isInternalStep == true && stored["bgA"]?.isInternalStep == false
                        && stored["A"]?.isInternalStep == false)
        let sections = SubAgentList.sections(items)
        await t.equal("실행마다 묶는다 (최근 실행 먼저)", sections.map { $0.items.map(\.id) }, [["A", "bgA", "main", "B"], ["old"]])
        await t.equal("묶음의 실행", sections.map(\.runID), ["r2", "r1"])
        let orphan = SubAgentList.items(stored: ["x": shell("x", owner: "gone", background: true, at: 0)], runIDs: ["x": "r2"],
                                        runs: runs, live: [], liveRunID: nil)
        await t.equal("띄운 하위가 목록에 없으면 제자리", orphan.map(\.depth), [0])
        await t.equal("고르지 않았으면 들이지 않은 줄 중 마지막 (하위가 띄운 셸이 더 늦게 시작해도)",
                      SubAgentList.resolve(selected: nil, in: items), "B")
        await t.equal("들인 줄도 고를 수 있다", SubAgentList.resolve(selected: "bgA", in: items), "bgA")

        let digests = StreamBuilder.subAgentDigests(infos: stored, runIDs: runIDs, events: [:], runs: runs, projectPath: nil)
        await t.check("앞에서 돈 셸은 카드 요약도 만들지 않는다 (그 명령 행은 보통 명령 행으로)",
                      digests["fgA"] == nil && digests["fgB"] == nil && digests["bgA"] != nil && digests["A"] != nil)

        await t.equal("종류 자리: subagent_type", SubAgentList.rowKindLabel(info("A")), "Explore")
        var claudeShell = shell("s", owner: nil, background: true, at: 0)
        claudeShell.detail = nil
        claudeShell.title = "Sleep for 10 seconds"
        await t.equal("종류 자리: Claude 셸은 종류 이름 (이름이 설명이라)", SubAgentList.rowKindLabel(claudeShell), "백그라운드 명령")
        var bare = info("n")
        bare.detail = nil
        await t.equal("종류 자리: 하위 에이전트는 비운다", SubAgentList.rowKindLabel(bare), nil)
        await t.equal("경과 자리: 경과만 (도구 수는 고른 하위의 머리에)", SubAgentList.rowFacts(info("A", toolUses: 3), elapsedSeconds: 65), "1분 05초")
        await t.equal("경과 자리: 모르면 빈 글", SubAgentList.rowFacts(info("A"), elapsedSeconds: nil), "")
    }

    // MARK: 인스펙터 "에이전트" 탭의 흐름

    static func flowRows(_ t: TestKit) async {
        await t.group("하위 에이전트 화면: 하위 흐름")
        let events = [
            event(1, .systemNotice, title: "안내", text: "요청: 화면을 조사해", payload: tag("A")),
            event(2, .toolRequest, title: "Read", text: #"{"file_path":"/p/a.swift"}"#, toolUseID: "c1", payload: tag("A")),
            event(3, .toolResult, title: "도구 결과", text: "내용", toolUseID: "c1", payload: tag("A")),
            event(4, .error, title: "도구 오류", text: "읽지 못함", payload: tag("A")),
            event(5, .userMessage, text: "하위에게 준 프롬프트", payload: tag("A")),
            event(6, .agentMessage, title: "Claude", text: "하위의 답", payload: tag("A")),
            event(7, .commandExecution, title: "ls", text: "ls", toolUseID: "c2", payload: ThreadEvent.payload(#"{"status":"interrupted"}"#, taggingParent: "A")),
        ]
        let rows = StreamBuilder.subAgentRows(events: events, projectPath: "/p")
        await t.check("응답과 실행 기록만 (머리글 · 바닥글 · 경고 · 사용자 행 없음)", rows.allSatisfy {
            switch $0 { case .execution, .agentMessage: return true; default: return false }
        })
        await t.equal("행 순서", rows.map { if case .agentMessage = $0 { return "message" } else { return "exec" } },
                      ["exec", "message", "exec"])
        guard case .execution(_, let first)? = rows.first else { await t.check("첫 행이 실행 기록", false); return }
        let notes = first.compactMap { entry -> String? in if case .note(let title, let text) = entry.kind { return "\(title)|\(text)" } else { return nil } }
        await t.equal("요청 안내 · 오류 · 받은 프롬프트는 기록 안의 한 줄", notes,
                      ["안내|요청: 화면을 조사해", "오류 · 도구 오류|읽지 못함", "요청|하위에게 준 프롬프트"])
        guard case .execution(_, let last)? = rows.last, case .command(let command)? = last.first?.kind else {
            await t.check("마지막 행이 명령", false); return
        }
        await t.check("멈춘 명령(interrupted)은 완료 · 오류가 아니라 멈춤", command.stopped && !command.failed && !command.running)
        let declined = ExecutionParser.entries(from: [event(1, .commandExecution, text: "rm x", toolUseID: "d",
                                                            payload: #"{"status":"declined"}"#)], projectPath: nil)
        // 2026-10-04: 사람이 거절한 명령은 오류가 아니라 거절함 (`ApprovalMark`) — 접기에서도 오류로 세지 않는다.
        await t.check("거절된 명령(declined)은 오류가 아니라 거절함",
                      { if case .command(let c)? = declined.first?.kind { return !c.failed && !c.stopped && c.approval == .denied(reason: nil) } else { return false } }())
    }

    // MARK: 상태 · 목록 · 고르기

    static func statusAndList(_ t: TestKit) async {
        await t.group("하위 에이전트 화면: 상태 · 목록")
        let crashed = SubAgentDigest.make(info: info("A"), runID: "r1", runFinished: true, events: [], projectPath: nil)
        await t.check("끝난 실행 안의 running 은 결과 미확인(멈춤) — 끝난 도구 행과 같은 말",
                      crashed.isUnfinished && crashed.effectiveStatus == .stopped && !crashed.isRunning && crashed.statusText == "결과 미확인")
        let live = SubAgentDigest.make(info: info("A"), runID: "r1", runFinished: false, events: [], projectPath: nil)
        await t.check("도는 실행 안의 running 은 진행 중", live.isRunning && live.statusText == "진행 중")
        let digests = StreamBuilder.subAgentDigests(infos: ["A": info("A")], runIDs: ["A": "r1"], events: [:],
                                                    runs: ["r1": makeRun("r1", .failed)], projectPath: nil)
        await t.check("요약은 띄운 실행의 상태로 판정한다", digests["A"]?.isUnfinished == true)
        let counted = SubAgentDigest.make(info: info("A", toolUses: 7), runID: nil, runFinished: false,
                                          events: [event(1, .toolRequest, title: "Read", text: "{}", toolUseID: "c", payload: tag("A"))],
                                          projectPath: nil)
        await t.equal("CLI 가 센 도구 수가 있으면 그것", counted.toolCount, 7)

        let older = Date(timeIntervalSince1970: 100), newer = Date(timeIntervalSince1970: 200)
        let stored = ["old1": info("old1", .completed, startedAt: older), "old2": info("old2", .completed, startedAt: older.addingTimeInterval(5)),
                      "cur1": info("cur1", .completed, startedAt: newer)]
        let runIDs = ["old1": "r1", "old2": "r1", "cur1": "r2"]
        let runs = ["r1": makeRun("r1", .completed, startedAt: older), "r2": makeRun("r2", .running, startedAt: newer)]
        let liveInfos = [info("cur1", .completed, startedAt: newer), info("cur2", .running, startedAt: newer.addingTimeInterval(3))]
        let items = SubAgentList.items(stored: stored, runIDs: runIDs, runs: runs, live: liveInfos, liveRunID: "r2")
        await t.equal("지금 실행 먼저 · 실행 안에서는 시작 순", items.map(\.id), ["cur1", "cur2", "old1", "old2"])
        await t.check("살아 있는 값이 우선", items.first { $0.id == "cur1" }?.isLive == true && items.first { $0.id == "old1" }?.isLive == false)
        await t.equal("고른 것이 없으면 도는 하위", SubAgentList.resolve(selected: nil, in: items), "cur2")
        await t.equal("고른 것이 있으면 그것", SubAgentList.resolve(selected: "old1", in: items), "old1")
        await t.equal("고른 것이 사라졌으면 도는 하위", SubAgentList.resolve(selected: "gone", in: items), "cur2")
        let finished = SubAgentList.items(stored: stored, runIDs: runIDs, runs: ["r1": makeRun("r1", .completed, startedAt: older),
                                                                              "r2": makeRun("r2", .completed, startedAt: newer)],
                                          live: [], liveRunID: nil)
        await t.equal("도는 것이 없으면 가장 최근 실행의 마지막 하위", SubAgentList.resolve(selected: nil, in: finished), "cur1")
        await t.equal("끝난 실행만이면 최근 실행 먼저", finished.map(\.id), ["cur1", "old1", "old2"])
        await t.equal("빈 목록", SubAgentList.resolve(selected: "x", in: []), nil)
        let unfinished = SubAgentList.items(stored: ["z": info("z")], runIDs: ["z": "r1"], runs: ["r1": makeRun("r1", .completed)],
                                            live: [], liveRunID: nil)
        await t.check("목록에서도 끝난 실행 안의 running 은 도는 것이 아니다",
                      unfinished.first?.isRunning == false && unfinished.first?.statusText == "결과 미확인")

        // 충돌 · 강제 종료: DB 의 실행은 running 그대로지만 도는 세션이 없다 ("정리" 를 누르기 전).
        let crashedRuns = ["r1": makeRun("r1", .running, startedAt: older), "r2": makeRun("r2", .completed, startedAt: newer)]
        let stale = SubAgentList.items(stored: ["z": info("z", startedAt: older), "y": info("y", .completed, startedAt: newer)],
                                       runIDs: ["z": "r1", "y": "r2"], runs: crashedRuns, live: [], liveRunID: nil, liveRunIDs: [])
        await t.check("도는 세션이 없는 실행의 running 은 끝나지 않음 (목록)",
                      stale.first { $0.id == "z" }?.isRunning == false && stale.first { $0.id == "z" }?.statusText == "결과 미확인")
        await t.equal("끝나지 않은 옛 하위를 '도는 하위' 로 고르지 않는다", SubAgentList.resolve(selected: nil, in: stale), "y")
        let alive = SubAgentList.items(stored: ["z": info("z")], runIDs: ["z": "r1"], runs: crashedRuns, live: [], liveRunID: nil,
                                       liveRunIDs: ["r1"])
        await t.check("도는 세션이 있으면 진행 중", alive.first?.isRunning == true)
        let staleDigests = StreamBuilder.subAgentDigests(infos: ["z": info("z")], runIDs: ["z": "r1"], events: [:], runs: crashedRuns,
                                                         projectPath: nil, liveRunIDs: [])
        await t.check("도는 세션이 없는 실행의 running 은 끝나지 않음 (카드 요약)",
                      staleDigests["z"]?.isUnfinished == true && staleDigests["z"]?.isRunning == false)
        await t.check("살아 있는 실행 목록을 모르면(nil) 실행 상태만 본다",
                      !SubAgentDigest.runFinished("r1", runs: crashedRuns, liveRunIDs: nil)
                        && SubAgentDigest.runFinished("r2", runs: crashedRuns, liveRunIDs: nil)
                        && SubAgentDigest.runFinished("r1", runs: crashedRuns, liveRunIDs: ["r2"]))
    }

    // MARK: 누가 얼마나 처리했나

    /// 처리 토큰(캐시 포함)의 몫 · 모델 이름 · 줄의 보조 글 · 저장 규칙 (2026-10-06 — 에이전트 탭에서 누가 얼마나 썼는지 보이게).
    static func tokenShares(_ t: TestKit) async {
        await t.group("하위 에이전트 화면: 처리 토큰의 몫")
        var a = info("a", .completed), b = info("b", .completed), step = info("s", kind: .shell, isBackground: false)
        a.totalTokens = 30_000
        b.totalTokens = 10_000
        step.totalTokens = 999
        let usage = UsageRecord(runID: "r1", threadID: "t", provider: .claude, inputTokens: 1_000, cacheReadTokens: 80_000,
                                cacheWriteTokens: 15_000, outputTokens: 4_000)
        let share = TokenShare.make(runUsage: usage, infos: [a, b, step, info("unknown")])
        await t.equal("실행 전체 = 사용량 기록의 처리 토큰", share.runTotal, 100_000)
        await t.equal("하위는 아는 것만 · 앞에서 돈 셸은 뺀다", share.byAgent, ["a": 30_000, "b": 10_000])
        await t.equal("메인 = 전체 − 하위", share.main, 60_000)
        await t.equal("몫", [share.fraction(share.main), share.fraction(a.totalTokens)], [0.6, 0.3])
        await t.equal("머리 글", share.headline(), "처리 10만 · 메인 60% · 하위 40%")
        await t.equal("바닥글 한 줄", share.footerLine(), "처리 토큰 10만 — 메인 6만 (60%) · 하위 2개 4만 (40%)")
        let live = TokenShare.make(runUsage: nil, infos: [a])
        await t.check("도는 실행(전체 모름)은 메인 · 비율을 모른다", live.main == nil && live.fraction(30_000) == nil)
        await t.equal("도는 실행의 머리 글", live.headline(), "하위 처리 3만")
        await t.check("도는 실행의 바닥글은 메인을 모른다고", live.footerLine()?.contains("실행이 끝나면") == true)
        let over = TokenShare.make(runUsage: UsageRecord(runID: "r1", threadID: "t", provider: .claude, inputTokens: 10_000),
                                   infos: [a])
        await t.check("하위 합이 전체보다 크면 메인 0 · 분모는 하위 합", over.main == 0 && over.fraction(30_000) == 1)
        await t.equal("비율 글", [TokenShare.percentText(0.004), TokenShare.percentText(0.416), TokenShare.percentText(nil)],
                      ["<1%", "42%", "—"])
        await t.check("하위가 없으면 머리 · 바닥글 없음",
                      TokenShare.make(runUsage: nil, infos: []).headline() == nil
                        && TokenShare.make(runUsage: usage, infos: []).footerLine() == nil)

        await t.equal("모델 이름", [SubAgentList.modelLabel("claude-opus-5"), SubAgentList.modelLabel("gpt-6-sol"),
                                   SubAgentList.modelLabel("gpt-5.6-luna"), SubAgentList.modelLabel("o3"),
                                   SubAgentList.modelLabel(nil)], ["Opus 5", "GPT-6 Sol", "GPT-5.6 Luna", "o3", nil])
        var general = info("g")
        general.detail = "general-purpose"
        general.model = "claude-haiku-4-5-20251001"
        await t.equal("줄마다 같은 종류(general-purpose)는 빼고 모델만", SubAgentList.subtitle(general), "Haiku 4.5")
        var explore = info("e")
        explore.model = "claude-sonnet-5"
        await t.equal("모델 · 종류", SubAgentList.subtitle(explore), "Sonnet 5 · Explore")
        await t.equal("종류 자리: general-purpose 는 비운다", SubAgentList.rowKindLabel(general), nil)

        var codex = info("c", .completed)
        codex.totalTokens = 12_000
        codex.newTokens = 1_500
        await t.equal("새 토큰을 알면 머리 줄에 함께", SubAgentDigest.detailFacts(codex, elapsedSeconds: nil, parent: nil),
                      "하위 에이전트 · 처리 1.2만 (새 1.5천)")
        await t.equal("실행의 몫은 처리 토큰 바로 뒤에", SubAgentDigest.detailFacts(codex, elapsedSeconds: 5, parent: "Claude", share: "22%"),
                      "하위 에이전트 · 5초 · 처리 1.2만 (새 1.5천 · 실행의 22%) · 부모: Claude")

        var running = info("r")
        var progressed = running
        progressed.totalTokens = 5_000
        await t.check("도는 동안 토큰만 바뀐 것은 저장하지 않는다", !progressed.differsForStorage(from: running))
        running.status = .completed
        var late = running
        late.totalTokens = 5_000
        await t.check("끝난 뒤에 온 토큰은 저장한다 (Codex 사용량이 턴 끝 뒤에 올 때)", late.differsForStorage(from: running))
        var modeled = running
        modeled.model = "claude-sonnet-5"
        await t.check("모델이 생기면 저장한다", modeled.differsForStorage(from: running))
        await t.equal("저장 · 읽기 (모델 · 새 토큰)", SubAgentInfo(json: codex.jsonString)?.newTokens, 1_500)
        let old = #"{"id":"x","kind":"agent","title":"옛 행","isBackground":false,"status":"completed","startedAt":0,"totalTokens":7}"#
        await t.check("옛 행(모델 · 새 토큰 없음)도 읽는다",
                      SubAgentInfo(json: old).map { $0.model == nil && $0.newTokens == nil && $0.totalTokens == 7 } == true)
    }

    // MARK: 글

    static func texts(_ t: TestKit) async {
        await t.group("하위 에이전트 화면: 글")
        func digest(_ status: SubAgentInfo.Status, _ kind: SubAgentInfo.Kind = .agent, unfinished: Bool = false) -> SubAgentDigest {
            SubAgentDigest(info: info(UUID().uuidString, status, kind: kind), runID: nil, runFinished: unfinished,
                           toolCount: 0, lastLine: nil)
        }
        await t.equal("카드 머리", SubAgentDigest.groupTitle([digest(.running), digest(.completed)]), "하위 에이전트 2")
        await t.equal("종류가 섞이면 하위 작업", SubAgentDigest.groupTitle([digest(.running), digest(.running, .shell)]), "하위 작업 2")
        await t.equal("백그라운드 명령만", SubAgentDigest.groupTitle([digest(.running, .shell)]), "백그라운드 명령 1")
        await t.equal("상태별 수 (없는 상태는 뺀다)",
                      SubAgentDigest.countsText([digest(.running), digest(.completed), digest(.completed), digest(.running, unfinished: true)]),
                      "2 완료 · 1 진행 중 · 1 결과 미확인")
        // 기다림의 이름은 어디서나 "백그라운드 작업" — 머리줄 · 칸 머리는 수만 (시계는 대화 끝의 상태 줄 하나).
        await t.equal("기다리는 글 — 시계 없이", SubAgentDigest.waitingText(count: 2), "백그라운드 작업 2개 기다리는 중")
        await t.equal("남은 수를 모를 때", SubAgentDigest.waitingText(count: 0), "백그라운드 작업 기다리는 중")
        await t.equal("짧은 글", [SubAgentDigest.waitingShortText(count: 2), SubAgentDigest.waitingShortText(count: 0)],
                      ["백그라운드 2", "대기"])
        await t.check("기다림의 도움말에 안쪽 구조의 말(메인 턴)이 없다", !SubAgentDigest.waitingHelp.contains("메인"))
        await t.equal("한 시간 넘는 경과 — 공용 형식", SubAgentDigest.clock(seconds: 3_725), "1시간 2분")
        await t.equal("입력창 대기 안내", SubAgentDigest.waitingKeyHint(count: 2), "백그라운드 2 · ⌘. 중단")
        await t.equal("남은 작업이 0 인 틈에는 수를 빼고", SubAgentDigest.waitingKeyHint(count: 0), "백그라운드 · ⌘. 중단")
        await t.equal("메뉴바 대기 글", SubAgentDigest.waitingMenuText(count: 3), "백그라운드 작업 3개")
        await t.equal("메뉴바 대기 글 (0)", SubAgentDigest.waitingMenuText(count: 0), "백그라운드 기다리는 중")
        var shell = info("s", kind: .shell, title: "sleep 60")
        shell.isBackground = true
        await t.equal("백그라운드 명령의 머리 줄은 '백그라운드' 를 겹치지 않는다",
                      SubAgentDigest.detailFacts(shell, elapsedSeconds: 5, parent: "Claude"), "백그라운드 명령 · 5초 · 부모: Claude")
        var agent = info("a", toolUses: 48)
        agent.isBackground = true
        agent.totalTokens = 1_270_000
        await t.equal("하위 에이전트의 머리 줄", SubAgentDigest.detailFacts(agent, elapsedSeconds: 3_999, parent: nil,
                                                                  formatTokens: { "\($0 / 1000)k" }),
                      "하위 에이전트 · 백그라운드 · 1시간 6분 · 처리 1270k · 도구 48")
        await t.equal("머리 줄의 토큰은 기본으로 공용 형식", SubAgentDigest.detailFacts(agent, elapsedSeconds: nil, parent: nil),
                      "하위 에이전트 · 백그라운드 · 처리 127만 · 도구 48")
        await t.equal("승인 제목에 하위 이름을 붙인다 (Claude)", SubAgentDigest.labeled("Bash: rm -rf build", agentName: "정리"),
                      "정리: Bash: rm -rf build")
        await t.equal("이미 붙어 있으면 다시 붙이지 않는다 (Codex)", SubAgentDigest.labeled("fix: ls", agentName: "fix"), "fix: ls")
        await t.equal("이름이 없으면 그대로", SubAgentDigest.labeled("ls", agentName: nil), "ls")
        let lock = ChangesState.Lock.agentRunning(.claude, here: true)
        await t.equal("잠금 글에 백그라운드 작업 수", ChangesState.lockText(lock, action: "커밋할", backgroundTasks: 2),
                      "Claude 실행이 끝나면 커밋할 수 있습니다 (백그라운드 작업 2개).")
        await t.check("없거나 다른 잠금이면 그대로",
                      ChangesState.lockText(lock, action: "커밋할", backgroundTasks: 0) == ChangesState.lockText(lock, action: "커밋할")
                        && ChangesState.lockText(.agentRunning(.codex, here: false), action: "받을", backgroundTasks: 3)
                          == ChangesState.lockText(.agentRunning(.codex, here: false), action: "받을")
                        && ChangesState.lockText(.gitRunning, action: "받을", backgroundTasks: 3) == ChangesState.lockText(.gitRunning, action: "받을"))
        // 브랜치 메뉴도 변경사항 탭과 같은 말 (백그라운드 작업 수).
        let branchBlock = BranchMenu.Block.locked(lock)
        await t.equal("브랜치 메뉴 잠금 글에 백그라운드 작업 수", BranchMenu.blockText(branchBlock, backgroundTasks: 2),
                      "Claude 실행이 끝나면 전환할 수 있습니다 (백그라운드 작업 2개).")
        await t.equal("수를 주지 않으면 그대로", BranchMenu.blockText(branchBlock), "Claude 실행이 끝나면 전환할 수 있습니다.")
        var status = GitWorkspaceStatus()
        status.isRepository = true
        status.branch = "main"
        status.localBranches = [GitBranchInfo(name: "main", shortHash: "a", isCurrent: true),
                                GitBranchInfo(name: "feature", shortHash: "b", isCurrent: false)]
        let menu = BranchMenu.content(status: status, query: "", block: branchBlock, backgroundTasks: 1)
        await t.equal("브랜치 행의 막힌 이유에도", menu.item(id: "local:feature")?.disabledReason,
                      "Claude 실행이 끝나면 전환할 수 있습니다 (백그라운드 작업 1개).")

        // 중단 원: 백그라운드 작업이 남았는지, 메인 턴 중의 포그라운드 하위뿐인지.
        await t.equal("기다리는 중이면 백그라운드 작업까지",
                      SubAgentDigest.stopButtonText(waiting: true, background: 0, unfinished: 0).help, "백그라운드 작업까지 모두 멈춥니다 (⌘.)")
        await t.equal("메인 턴 중이어도 백그라운드 작업이 있으면 백그라운드 작업까지",
                      SubAgentDigest.stopButtonText(waiting: false, background: 1, unfinished: 2).label, "백그라운드 작업까지 모두 중단")
        await t.equal("포그라운드 하위 에이전트만 있으면 하위 에이전트까지",
                      SubAgentDigest.stopButtonText(waiting: false, background: 0, unfinished: 2).help, "하위 에이전트까지 모두 멈춥니다 (⌘.)")
        await t.equal("하위 작업이 없으면 평소 글",
                      SubAgentDigest.stopButtonText(waiting: false, background: 0, unfinished: 0).help, "실행 중단 (⌘.)")

        // 인계가 막힌 이유 · 자동 작업 카드의 기다리는 글.
        await t.equal("인계 막힘: 기다리는 중이면 백그라운드 작업 수", SubAgentDigest.handoffBusyText(waiting: true, count: 2),
                      "실행이 끝나면 인계할 수 있습니다 (백그라운드 작업 2개).")
        await t.equal("인계 막힘: 메인 턴 중이면 수 없이", SubAgentDigest.handoffBusyText(waiting: false, count: 2),
                      "실행이 끝나면 인계할 수 있습니다.")
        await t.equal("남은 작업이 0 인 틈", SubAgentDigest.waitingNote(waiting: true, count: 0), " (백그라운드 작업을 기다리는 중)")
        await t.equal("자동 작업 카드의 하위 작업 상태", SubAgentDigest.waitingTaskText(count: 3), "백그라운드 작업 3개 기다리는 중")
        await t.equal("자동 작업 카드 (0)", SubAgentDigest.waitingTaskText(count: 0), "백그라운드 기다리는 중")

        // 끝난 작업의 결과를 받은 쪽.
        var ownedShell = info("S", .completed, kind: .shell, title: "빌드")
        ownedShell.ownerID = "A"
        await t.equal("대화의 에이전트가 띄운 작업은 그 에이전트에게 ('메인' 이라 하지 않는다)",
                      SubAgentList.deliveredText(info("A", .completed), ownerTitle: nil), "이 대화의 에이전트에게 전달됨")
        await t.equal("하위가 띄운 작업은 그 하위에게", SubAgentList.deliveredText(ownedShell, ownerTitle: "화면 조사"), "화면 조사 에게 전달됨")
        await t.equal("띄운 하위의 이름을 모르면", SubAgentList.deliveredText(ownedShell, ownerTitle: nil), "하위 에이전트에게 전달됨")
    }

    // MARK: 대화 스트림의 행 캐시

    /// 흐르는 메인 응답 뒤에 (메인 글을 닫지 않고) 하위가 청한 승인 · 하위 앵커 결과가 붙어도 응답이 멈추지 않는다.
    /// 하위만 바뀌면 행을 다시 묶지 않고 요약만 갈아 붙인다.
    static func rowsCache(_ t: TestKit) async {
        await t.group("하위 에이전트 화면: 행 캐시")
        let pane = ThreadPaneModel(threadID: "t")
        let cache = StreamRowsCache()
        let runs = ["r1": makeRun("r1", .running)]
        func rows() -> [StreamRow] {
            cache.rows(events: pane.mainEvents, runs: runs, handoffs: [], projectPath: "/p", streaming: pane.streamingMainEvent,
                       subAgents: SubAgentStreamInput(infos: pane.subAgentInfos, runIDs: pane.subAgentRunIDs,
                                                      events: pane.subAgentEvents, revision: pane.subAgentRevision,
                                                      liveRunIDs: ["r1"]))
        }
        func message(_ rows: [StreamRow]) -> ThreadEvent? {
            rows.lazy.compactMap { row -> ThreadEvent? in if case .agentMessage(let e) = row { return e } else { return nil } }.last
        }
        pane.upsert(event(1, .userMessage, text: "해 줘"))
        pane.upsert(event(2, .toolRequest, title: "Agent", text: #"{"description":"조사"}"#, toolUseID: "A"))
        pane.upsert(statusRow(3, info("A")))
        pane.upsert(event(4, .agentMessage, title: "Claude", text: "Hel", streaming: true))
        await t.equal("흐르는 메인 응답", message(rows())?.text, "Hel")
        // 하위가 청한 승인 · 하위 앵커 결과: 메인 글을 닫지 않고 그 뒤에 저장된다.
        pane.upsert(event(5, .approvalRequest, title: "조사: Bash", text: "ls"))
        await t.equal("흐르는 응답은 메인 흐름의 마지막이 아니다", pane.mainEvents.last?.id, "e5")
        await t.equal("흐르는 메인 이벤트를 따로 안다", pane.streamingMainEvent?.id, "e4")
        _ = rows()
        pane.upsert(event(4, .agentMessage, title: "Claude", text: "Hello wor", streaming: true))
        let growing = message(rows())
        await t.check("뒤에 행이 붙어도 흐르는 응답이 자란다", growing?.text == "Hello wor" && growing?.isStreaming == true,
                      growing?.text ?? "nil")
        pane.upsert(event(6, .toolResult, title: "subAgent", text: "하위의 최종 답", toolUseID: "A"))
        pane.upsert(event(4, .agentMessage, title: "Claude", text: "Hello world, final.", streaming: false))
        let final = message(rows())
        await t.check("끝난 응답은 끝난 글로 (깜박이는 커서 없음)",
                      final?.text == "Hello world, final." && final?.isStreaming == false && pane.streamingMainEvent == nil,
                      "\(final?.text ?? "nil") streaming=\(final?.isStreaming ?? true)")
        let fresh = StreamBuilder.rows(events: pane.mainEvents, runs: runs, handoffs: [], projectPath: "/p",
                                       subAgents: StreamBuilder.subAgentDigests(infos: pane.subAgentInfos,
                                                                                runIDs: pane.subAgentRunIDs,
                                                                                events: pane.subAgentEvents, runs: runs,
                                                                                projectPath: "/p", liveRunIDs: ["r1"]))
        await t.check("캐시의 행 = 새로 묶은 행", rows() == fresh)

        // 하위만 바뀌면(상태 · 하위 흐름) 수정 번호가 늘고, 캐시는 요약만 갈아 붙인다.
        let before = pane.subAgentRevision
        pane.upsert(event(7, .toolRequest, title: "Read", text: #"{"file_path":"/p/a.swift"}"#, toolUseID: "c1", payload: tag("A")))
        pane.upsert(statusRow(3, info("A", .completed, summary: "`a.swift` 를 봤습니다")))
        await t.check("하위 쪽이 바뀌면 수정 번호가 는다", pane.subAgentRevision == before + 2)
        pane.upsert(event(8, .agentMessage, title: "Claude", text: "다음", streaming: true))
        let beforeMain = pane.subAgentRevision
        pane.upsert(event(8, .agentMessage, title: "Claude", text: "다음 글", streaming: true))
        await t.equal("메인 글이 자라도 수정 번호는 그대로", pane.subAgentRevision, beforeMain)
        let patched = rows()
        let card = patched.flatMap { row -> [ExecutionEntry] in if case .execution(_, let e) = row { return e } else { return [] } }
            .first { $0.subagent != nil }?.subagent
        await t.check("요약이 새 상태 · 도구 수로", card?.info.status == .completed && card?.toolCount == 1
                        && card?.lastLine == "Read a.swift")
        await t.equal("흐르는 새 응답도 그대로 자란다", message(patched)?.text, "다음 글")
    }

    // MARK: 백그라운드 명령의 앵커 행

    static func shellAnchor(_ t: TestKit) async {
        await t.group("하위 에이전트 화면: 백그라운드 명령 행")
        // Claude: 앵커 결과는 "뒤에서 시작함" 확인뿐이다 — 행만 보면 완료.
        let claude = ExecutionParser.entries(from: [
            event(1, .toolRequest, title: "Bash", text: #"{"command":"swift test","run_in_background":true}"#, toolUseID: "S"),
            event(2, .toolResult, title: "도구 결과", text: "Command running in background with ID: bash_1", toolUseID: "S"),
        ], projectPath: nil)
        func command(_ entries: [ExecutionEntry]) -> CommandInfo? {
            if case .command(let c)? = entries.first?.kind { return c } else { return nil }
        }
        var shell = info("S", kind: .shell, title: "swift test")
        func state(_ status: SubAgentInfo.Status, runFinished: Bool = false) -> CommandInfo? {
            shell.status = status
            let digest = SubAgentDigest(info: shell, runID: "r1", runFinished: runFinished, toolCount: 0, lastLine: nil)
            return command(digest.applyingStatus(to: claude))
        }
        await t.check("행만 보면 (고치기 전) 완료로 보인다", command(claude)?.running == false && command(claude)?.stopped == false)
        await t.check("도는 명령은 실행 중", state(.running)?.running == true && state(.running)?.stopped == false)
        let unfinished = state(.running, runFinished: true)
        await t.check("끝나지 않은 채 실행이 끝났으면 멈춤 (완료가 아니다)",
                      unfinished?.running == false && unfinished?.stopped == true && unfinished?.exitCode == nil)
        await t.check("멈춘 작업은 멈춤", state(.stopped)?.stopped == true)
        await t.check("실패한 작업은 오류", state(.failed)?.failed == true && state(.failed)?.running == false)
        await t.check("끝난 작업은 완료 (출력은 그대로)", state(.completed)?.running == false && state(.completed)?.stopped == false
                        && state(.completed)?.failed == false && state(.completed)?.output?.contains("bash_1") == true)
        // Codex: 앵커는 명령 행 — 끝났으면 종료 코드를 둔다.
        let codex = ExecutionParser.entries(from: [event(1, .commandExecution, text: "sleep 5\n\n--- 출력 ---\nok", toolUseID: "X",
                                                         payload: #"{"status":"completed","exitCode":0}"#)], projectPath: nil)
        shell.status = .completed
        let done = command(SubAgentDigest(info: shell, runID: "r1", runFinished: true, toolCount: 0, lastLine: nil)
            .applyingStatus(to: codex))
        await t.check("Codex 의 끝난 명령은 종료 코드를 그대로", done?.exitCode == 0 && !(done?.running ?? true))
        let codexRunning = ExecutionParser.entries(from: [event(1, .commandExecution, text: "sleep 5", toolUseID: "X",
                                                                payload: #"{"status":"inProgress"}"#)], projectPath: nil)
        shell.status = .running
        let crashed = command(SubAgentDigest(info: shell, runID: "r1", runFinished: true, toolCount: 0, lastLine: nil)
            .applyingStatus(to: codexRunning))
        await t.check("Codex 의 끝나지 않은 명령도 '실행 중' 이 아니라 멈춤", crashed?.running == false && crashed?.stopped == true)
    }

    // MARK: 카드 한 줄의 Markdown

    static func plainLines(_ t: TestKit) async {
        await t.group("하위 에이전트 화면: 한 줄 글")
        await t.equal("코드 표식", SubAgentDigest.plainMarkdown("`LoginView.swift` 의 오류 문구 세 곳을 고쳤습니다"),
                      "LoginView.swift 의 오류 문구 세 곳을 고쳤습니다")
        await t.equal("굵게 · 목록", SubAgentDigest.plainMarkdown("- **두 곳**에서 씁니다"), "두 곳에서 씁니다")
        await t.equal("제목", SubAgentDigest.plainMarkdown("## 결과 요약"), "결과 요약")
        await t.equal("번호 목록 · 링크", SubAgentDigest.plainMarkdown("1. [LoginView](Moa/Login/LoginView.swift) 42행"),
                      "LoginView 42행")
        await t.equal("그림 · 인용", SubAgentDigest.plainMarkdown("> ![화면](a.png) 확인"), "화면 확인")
        await t.equal("밑줄 하나는 파일 이름이라 둔다", SubAgentDigest.plainMarkdown("fix_messages 완료"), "fix_messages 완료")
        await t.equal("해시태그 · 소수는 표식이 아니다", SubAgentDigest.plainMarkdown("#42 는 1.5 배"), "#42 는 1.5 배")
        await t.equal("첫 줄 — 빈 줄 · 코드 울타리를 건너뛴다",
                      SubAgentDigest.firstPlainLine("\n```swift\nlet x = 1\n```"), "let x = 1")
        await t.equal("없으면 nil", SubAgentDigest.firstPlainLine("  \n```\n"), nil)
        let last = SubAgentDigest.make(info: info("A"), runID: nil, runFinished: false,
                                       events: [event(1, .agentMessage, title: "Claude", text: "두 곳에서 씁니다 — `a.swift` 42행",
                                                      payload: tag("A"))], projectPath: nil)
        await t.equal("하위의 마지막 일 한 줄도 표식 없이", last.lastLine, "두 곳에서 씁니다 — a.swift 42행")
    }

    // MARK: 관찰된 편집 — 하위의 편집도 센다

    /// 실행 전후 비교를 못 한 실행의 카드("관찰된 편집 n건")는 하위 에이전트 안의 Edit · Write · fileChange 도 센다 —
    /// 변경사항 탭의 점 · 올릴 파일(`ExecutionParser.observedEdits` 에 대화의 이벤트 전부)과 같은 수.
    static func observedEdits(_ t: TestKit) async {
        await t.group("하위 에이전트 화면: 관찰된 편집")
        var summary = RunFileChanges.notCompared(runID: "r1", reason: .readFailed).event(threadID: "t", provider: .claude)
        summary.id = "e9"
        summary.seq = 9
        let pane = ThreadPaneModel(threadID: "t")
        for e in [
            event(1, .userMessage, text: "고쳐 줘"),
            event(2, .toolRequest, title: "Agent", text: #"{"description":"화면 고치기"}"#, toolUseID: "A"),
            statusRow(3, info("A", .completed)),
            event(4, .toolRequest, title: "Edit", text: #"{"file_path":"/p/sub/a.swift","old_string":"x","new_string":"y"}"#,
                  toolUseID: "c1", payload: tag("A")),
            event(5, .fileChange, title: "파일 변경", text: "/p/sub/b.swift\n\n@@ -1 +1 @@\n-x\n+y", toolUseID: "c2",
                  payload: ThreadEvent.payload(#"{"status":"completed"}"#, taggingParent: "A")),
            event(6, .toolRequest, title: "Write", text: #"{"file_path":"/p/main.swift","content":"z"}"#, toolUseID: "c3"),
            event(7, .agentMessage, title: "Claude", text: "고쳤습니다"),
            // 다른 실행의 하위 편집은 세지 않는다.
            event(8, .toolRequest, title: "Edit", text: #"{"file_path":"/p/other.swift","old_string":"x","new_string":"y"}"#,
                  toolUseID: "c4", payload: tag("A"), run: "r0"),
            summary,
        ] { pane.upsert(e) }
        let runs = ["r1": makeRun("r1", .completed)]
        let expected = ["main.swift", "sub/a.swift", "sub/b.swift"]
        func observed(_ rows: [StreamRow]) -> [String]? {
            rows.lazy.compactMap { row -> [String]? in if case .runChanges(let r) = row { return r.observedPaths } else { return nil } }.first
        }
        let digests = StreamBuilder.subAgentDigests(infos: pane.subAgentInfos, runIDs: pane.subAgentRunIDs,
                                                    events: pane.subAgentEvents, runs: runs, projectPath: "/p")
        let rows = StreamBuilder.rows(events: pane.mainEvents, runs: runs, handoffs: [], projectPath: "/p", subAgents: digests,
                                      subAgentEvents: pane.subAgentEvents)
        await t.equal("카드는 하위의 Edit · fileChange 도 센다", observed(rows), expected)
        await t.equal("하위 흐름을 주지 않으면 (고치기 전처럼) 메인 편집만",
                      observed(StreamBuilder.rows(events: pane.mainEvents, runs: runs, handoffs: [], projectPath: "/p",
                                                  subAgents: digests)), ["main.swift"])
        await t.equal("이벤트 전부를 주어도 같다", observed(StreamBuilder.rows(events: pane.events, runs: runs, handoffs: [],
                                                                           projectPath: "/p", subAgents: digests)), expected)
        await t.equal("변경사항 탭의 점 · 올릴 파일과 같은 수 (대화의 이벤트 전부)",
                      ExecutionParser.observedEdits(in: pane.events, runID: "r1", projectPath: "/p"), expected)
        await t.equal("다른 실행의 편집은 그 실행의 것", ExecutionParser.observedEdits(in: pane.events, runID: "r0", projectPath: "/p"),
                      ["other.swift"])

        // 행 캐시: 비교하지 못한 실행의 하위 흐름이 자라면 (메인은 그대로여도) 다시 묶는다.
        let cache = StreamRowsCache()
        func cached() -> [StreamRow] {
            cache.rows(events: pane.mainEvents, runs: runs, handoffs: [], projectPath: "/p", streaming: pane.streamingMainEvent,
                       subAgents: SubAgentStreamInput(infos: pane.subAgentInfos, runIDs: pane.subAgentRunIDs,
                                                      events: pane.subAgentEvents, revision: pane.subAgentRevision,
                                                      liveRunIDs: []))
        }
        await t.equal("캐시도 하위의 편집을 센다", observed(cached()), expected)
        pane.upsert(event(10, .toolRequest, title: "Write", text: #"{"file_path":"/p/sub/c.swift","content":"z"}"#,
                          toolUseID: "c5", payload: tag("A")))
        await t.equal("비교하지 못한 실행의 하위 흐름이 자라면 캐시가 다시 묶는다", observed(cached()), expected + ["sub/c.swift"])
    }

    // MARK: 하위가 띄운 백그라운드 명령

    /// Claude 의 하위가 띄운 셸(`owned_by_subagent`)은 Bash 요청이 메인이 아니라 그 하위의 흐름에 있다.
    static func ownedShell(_ t: TestKit) async {
        await t.group("하위 에이전트 화면: 하위가 띄운 백그라운드 명령")
        let pane = ThreadPaneModel(threadID: "t")
        var shell = info("S", kind: .shell, title: "테스트 돌리기")
        shell.ownerID = "A"
        shell.isBackground = true
        for e in [
            event(1, .userMessage, text: "해 줘"),
            event(2, .toolRequest, title: "Agent", text: #"{"description":"테스트"}"#, toolUseID: "A"),
            statusRow(3, info("A")),
            event(4, .toolRequest, title: "Bash",
                  text: #"{"command":"swift test","description":"테스트 돌리기","run_in_background":true}"#,
                  toolUseID: "S", payload: tag("A")),
            statusRow(5, shell),
            event(6, .toolResult, title: "도구 결과", text: "Command running in background with ID: bash_1", toolUseID: "S",
                  payload: tag("A")),
        ] { pane.upsert(e) }
        await t.check("메인 흐름에서만 찾으면 (고치기 전) 앵커가 없다",
                      SubAgentList.shellAnchorEvents(id: "S", ownerID: nil, main: pane.mainEvents, flows: pane.subAgentEvents).isEmpty)
        let anchor = SubAgentList.shellAnchorEvents(id: "S", ownerID: "A", main: pane.mainEvents, flows: pane.subAgentEvents)
        await t.equal("띄운 하위의 흐름에서 앵커를 찾는다", anchor.map(\.id), ["e4", "e6"])
        let entries = SubAgentDigest(info: shell, runID: "r1", runFinished: false, toolCount: 0, lastLine: nil)
            .applyingStatus(to: ExecutionParser.entries(from: anchor, projectPath: "/p"))
        await t.check("앵커 행은 도는 명령", {
            if case .command(let c)? = entries.first?.kind { return c.command == "swift test" && c.running } else { return false }
        }())
        await t.equal("Claude 셸의 제목은 설명이라 $ 를 붙이지 않는다", SubAgentList.shellFallbackText(shell, provider: .claude),
                      "테스트 돌리기")
        await t.equal("Codex 셸의 제목은 명령", SubAgentList.shellFallbackText(info("X", kind: .shell, title: "sleep 5"),
                                                                      provider: .codex), "$ sleep 5")
    }

    // MARK: 터미널 탭의 백그라운드 명령

    static func terminalShells(_ t: TestKit) async {
        await t.group("하위 에이전트 화면: 터미널 탭의 백그라운드 명령")
        let events = [
            event(1, .toolRequest, title: "Bash", text: #"{"command":"swift test","run_in_background":true}"#, toolUseID: "S",
                  payload: tag("A")),
            event(2, .toolResult, title: "도구 결과", text: "Command running in background with ID: bash_1", toolUseID: "S",
                  payload: tag("A")),
            event(3, .toolRequest, title: "Bash", text: #"{"command":"ls"}"#, toolUseID: "L"),
            event(4, .toolResult, title: "도구 결과", text: "a.swift", toolUseID: "L"),
        ]
        let entries = ExecutionParser.entries(from: events, projectPath: nil)
            .filter { if case .command = $0.kind { return true } else { return false } }
        func command(_ entries: [ExecutionEntry], _ id: String) -> CommandInfo? {
            guard case .command(let c)? = entries.first(where: { $0.id == "tool:\(id)" })?.kind else { return nil }
            return c
        }
        await t.check("행만 보면 (고치기 전) 도는 명령도 끝난 것 ('종료 코드 미확인')",
                      command(entries, "S")?.running == false && command(entries, "S")?.exitCode == nil)
        var shell = info("S", kind: .shell, title: "swift test")
        shell.isBackground = true
        let runs = ["r1": makeRun("r1", .running)]
        let running = TerminalCommands.applyingShellStatus(to: entries, stored: ["S": shell], runIDs: ["S": "r1"], runs: runs,
                                                           live: [], liveRunIDs: ["r1"])
        await t.check("저장된 작업이 도는 중이면 실행 중", command(running, "S")?.running == true)
        await t.equal("다른 명령은 그대로", command(running, "L"), command(entries, "L"))
        var done = shell
        done.status = .completed
        let live = TerminalCommands.applyingShellStatus(to: entries, stored: ["S": shell], runIDs: ["S": "r1"], runs: runs,
                                                        live: [done], liveRunIDs: ["r1"])
        await t.check("살아 있는 값이 우선 (끝남)", command(live, "S")?.running == false && command(live, "S")?.stopped == false)
        let crashed = TerminalCommands.applyingShellStatus(to: entries, stored: ["S": shell], runIDs: ["S": "r1"], runs: runs,
                                                           live: [], liveRunIDs: [])
        await t.check("도는 세션이 없는 실행의 running 은 멈춤", command(crashed, "S")?.stopped == true
                        && command(crashed, "S")?.running == false)
        let agent = TerminalCommands.applyingShellStatus(to: entries, stored: ["S": info("S")], runIDs: ["S": "r1"], runs: runs,
                                                         live: [], liveRunIDs: ["r1"])
        await t.equal("셸이 아닌 작업의 상태는 입히지 않는다", agent, entries)
    }

    // MARK: 워크플로 요청 행

    static func workflowRequest(_ t: TestKit) async {
        await t.group("하위 에이전트 화면: 워크플로 요청 행")
        func summary(_ name: String, _ input: String) -> String? {
            if case .tool(let info) = ExecutionParser.requestKind(name: name, input: input, projectPath: nil) { return info.summary }
            return nil
        }
        let script = "export const meta = {\n  name: 'summarize-first-lines',\n  description: 'Each agent reads one file',\n}\n"
            + "const files = ['a.txt']\nreturn files\n"
        let pretty = JSONUtil.prettyString(["script": script])
        await t.equal("스크립트의 meta 이름 (첫 줄은 코드다)", summary("Workflow", pretty), "워크플로 · summarize-first-lines")
        // 어댑터처럼 4000자에서 자른 입력 — JSON 으로 읽히지 않는다.
        let long = JSONUtil.truncate(JSONUtil.prettyString(["script": script + String(repeating: "// 채움\n", count: 800)]), max: 4000)
        await t.check("잘린 입력은 JSON 이 아니다", JSONUtil.object(long) == nil)
        await t.equal("잘린 입력에서도 meta 이름", summary("Workflow", long), "워크플로 · summarize-first-lines")
        await t.equal("설명 필드가 있으면 그것", summary("Workflow", #"{"description":"세 파일 요약","script":"return 1"}"#),
                      "워크플로 · 세 파일 요약")
        await t.equal("이름을 모르면 워크플로", summary("Workflow", JSONUtil.prettyString(["script": "return 1"])), "워크플로")

        let cut = JSONUtil.truncate(JSONUtil.prettyString(["query": "찾을 글\n둘째 줄", "zz": String(repeating: "x", count: 200)]),
                                    max: 60)
        await t.check("다른 도구의 잘린 입력", JSONUtil.object(cut) == nil)
        await t.equal("잘린 입력이면 첫 문자열 값의 첫 줄 ('{' 가 아니다)", summary("mcp__docs__search", cut), "찾을 글")
        await t.equal("문자열 값이 없으면 이름만 (빈 요약 — '{' 가 아니다)",
                      summary("mcp__docs__count", JSONUtil.prettyString(["n": 3])), "")
        await t.equal("글이 아닌 입력은 그 첫 줄", summary("Other", "plain input\nmore"), "plain input")
    }

    // MARK: 앱: 기다리는 실행을 대화 상자 · 잠금 수에 반영

    static func appModel(_ t: TestKit) async throws {
        await t.group("하위 에이전트 화면: 앱")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-subui-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
        try await store.bootstrap()
        let project = Project(name: "work", path: folder.path)
        try await store.upsertProject(project)
        var thread = ConversationThread(projectID: project.id, title: "하위")
        thread.claudeSelection = ModelSelection(model: "sonnet", effort: "high")   // 모델 목록 조회(CLI)를 타지 않게
        try await store.upsertThread(thread)

        var done = info("toolu-A", .completed, title: "화면 조사", summary: "A 의 최종 답")
        done.startedAt = Date()
        let fake = ScriptedAgentAdapter(provider: .claude, steps: [
            .emit(.sessionEstablished(sessionID: "s-ui", model: "fake-model", cliVersion: nil)),
            .emit(.toolStarted(id: "toolu-A", name: "Agent", detail: #"{"description":"화면 조사","subagent_type":"Explore"}"#)),
            .emit(.subAgent(SubAgentInfo(id: "toolu-A", taskID: "task-1", kind: .agent, title: "화면 조사", detail: "Explore",
                                         isBackground: true, startedAt: done.startedAt))),
            .emit(.subAgentEvent(agentID: "toolu-A", event: .toolStarted(id: "toolu-R", name: "Read",
                                                                            detail: #"{"file_path":"/x/a.swift"}"#))),
            // 하위가 앞에서 돌린 셸 — CLI 가 작업으로 알려도 하위 수 · 백그라운드 수에 넣지 않는다.
            .emit(.subAgent(SubAgentInfo(id: "toolu-S", taskID: "b1", kind: .shell, title: "sleep 10", ownerID: "toolu-A",
                                         isBackground: false, startedAt: done.startedAt))),
            .emit(.assistantMessage("메인 답")),
            .emit(.turnSettled(remaining: 1)),
            .waitSignal("done"),
            .emit(.subAgent(done)),
            .finish(AgentTurnResult(state: .completed, terminalReason: "completed", sessionID: "s-ui", resultText: "메인 답")),
        ])
        let model = AppModel(store: store)
        model.runner.adapterFactory = { _ in fake }
        await model.reloadProjects()
        await model.selectThread(thread.id)
        func settle(_ condition: @MainActor () -> Bool) async {
            for _ in 0..<400 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        let sent = await model.send("둘로 나눠 조사해", provider: .claude)
        await settle { model.runner.session(threadID: thread.id)?.isWaitingOnBackground == true }
        let session = model.runner.session(threadID: thread.id)
        await t.check("보내면 기다리는 실행이 된다", sent && session?.isWaitingOnBackground == true, model.banner?.text ?? "")
        await t.equal("끝나지 않은 하위 수 (하위가 앞에서 돌린 셸은 세지 않는다)", session?.unfinishedSubAgentCount, 1)
        await t.equal("그중 백그라운드 작업 수 (중단 원의 글)", session?.unfinishedBackgroundCount, 1)
        await model.prepareHandoff(to: .codex, threadID: thread.id)
        await t.equal("기다리는 중의 인계는 막히고 백그라운드 작업 수를 알린다", model.banner?.text,
                      "이 대화에서 에이전트가 실행 중입니다 (백그라운드 작업 1개). 끝나기를 기다리거나 중단한 뒤 인계하세요.")
        // 카드가 없으니 이유는 그 대화의 배너로 (그 칸에 뜬다) — 보류를 걸지 않는다 (실행 뒤의 대기열을 건드리지 않게).
        await t.check("바쁨 오류는 그 대화의 자리 · 카드 · 보류 없음",
                      model.banner?.threadID == thread.id && model.handoffCards[thread.id] == nil
                        && model.queueHolds[thread.id] == nil && model.handoffPreparations[thread.id] == nil)
        await t.equal("이 폴더의 백그라운드 작업 수 (잠금 안내)", model.backgroundTaskCount(inProjectPath: folder.path), 1)
        await t.equal("다른 폴더는 0", model.backgroundTaskCount(inProjectPath: "/elsewhere"), 0)
        let pane = model.threadStates[thread.id]
        await settle { pane?.subAgentEvents["toolu-A"]?.isEmpty == false }
        await t.check("실시간 이벤트도 메인 · 하위로 나뉜다",
                      pane?.mainEvents.contains { $0.title == "Read" } == false && pane?.subAgentEvents["toolu-A"]?.count == 1
                        && pane?.subAgentInfos["toolu-A"]?.status == .running
                        && pane?.mainEvents.contains { $0.kind == .agentMessage && $0.text == "메인 답" } == true)
        model.focusSubAgent(threadID: thread.id, agentID: "toolu-A")
        await t.equal("에이전트 탭이 볼 하위는 대화별로", model.subAgentFocus[thread.id], "toolu-A")

        fake.signal("done")
        await settle { !model.runner.isBusy(threadID: thread.id) && model.threadStates[thread.id]?.subAgentInfos["toolu-A"]?.status == .completed }
        await t.check("끝나면 저장된 상태가 완료 · 기다리는 작업 없음",
                      model.threadStates[thread.id]?.subAgentInfos["toolu-A"]?.status == .completed
                        && model.backgroundTaskCount(inProjectPath: folder.path) == 0)
    }
}
