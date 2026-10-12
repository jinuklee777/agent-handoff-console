import Foundation

// MARK: - 에이전트 현황 (가운데 칸 "현황" — App/Overview.swift · App/AppModel+Overview.swift)

@MainActor
enum OverviewTests {

    static func run(_ t: TestKit) async {
        await rules(t)
        await answers(t)
        await finished(t)
        await app(t)
    }

    private static func item(_ id: String, _ kind: Overview.Kind, since: TimeInterval, project: String = "p",
                             running: Bool = true) -> Overview.Item {
        var item = Overview.Item(threadID: id, title: id, project: project, provider: .claude, kind: kind,
                                 since: Date(timeIntervalSince1970: since))
        item.running = running
        return item
    }

    // MARK: 순서 · 구역 · 머리 (순수)

    static func rules(_ t: TestKit) async {
        await t.group("현황: 순서 · 구역 · 머리")
        let deadline = Date(timeIntervalSince1970: 500)
        let items = [
            item("work-new", .working, since: 300),
            item("approval-new", .approval, since: 200),
            item("countdown", .handoffCountdown(deadline: deadline), since: 50, running: false),
            item("bg", .background(2), since: 100, project: "q"),
            item("question-old", .question, since: 100, project: "q"),
            item("work-old", .working, since: 10, project: "q"),
            item("review", .handoffReview("인계 검토 필요"), since: 150, running: false),
        ]
        await t.equal("상태순: 답을 기다리는 것은 오래 기다린 순 → 카운트다운 → 오래 일한 순 → 백그라운드 대기",
                      Overview.ordered(items).map(\.threadID),
                      ["question-old", "review", "approval-new", "countdown", "work-old", "work-new", "bg"])
        let groups = Overview.groups(items, sort: .status)
        await t.equal("상태순 구역은 둘", groups.map(\.role), [.needsResponse, .working])
        await t.equal("응답 필요의 수는 카운트다운을 세지 않고, 카운트다운은 머리 뒤에", [groups[0].title, groups[0].note ?? ""],
                      ["응답 필요 3", "자동 인계 대기 1"])
        await t.equal("일하는 중은 백그라운드 대기를 포함해 센다", [groups[1].title, groups[1].note ?? ""],
                      ["일하는 중 3", "백그라운드 대기 1 포함"])
        let byProject = Overview.groups(items, sort: .project)
        await t.equal("프로젝트순: 답을 기다리는 행이 먼저 나온 프로젝트 먼저", byProject.map(\.title), ["q", "p"])
        await t.equal("프로젝트 머리 뒤의 수", byProject.map { $0.note ?? "" }, ["응답 필요 1 · 실행 3", "응답 필요 2 · 실행 2"])
        let onlyCountdown = Overview.groups([item("c", .handoffCountdown(deadline: deadline), since: 0, running: false)], sort: .status)
        await t.check("카운트다운만 있으면 \"응답 필요 0\" 이라 하지 않는다",
                      onlyCountdown.first?.title == "자동 인계 대기 1" && onlyCountdown.first?.note == nil)
        await t.check("빈 구역은 그리지 않는다", Overview.groups([item("w", .working, since: 0)], sort: .status).map(\.role) == [.working])

        let counts = Overview.counts(items)
        await t.equal("수: 답을 기다림 · 카운트다운 · 실행 · 일하는 중 · 백그라운드 · 남은 하위 작업",
                      [counts.waiting, counts.countdowns, counts.running, counts.working, counts.background, counts.backgroundTasks],
                      [3, 1, 5, 2, 1, 2])
        await t.equal("머리 문장 — 답과 카운트다운이 함께", Overview.headline(counts),
                      "에이전트 5개가 실행 중입니다. 3개가 답을 기다리고, 1개는 곧 자동으로 인계합니다.")
        await t.equal("머리 문장 — 답만", Overview.headline(Overview.Counts(waiting: 1, running: 2)),
                      "에이전트 2개가 실행 중입니다. 1개가 답을 기다립니다.")
        await t.equal("머리 문장 — 일만", Overview.headline(Overview.Counts(running: 1, working: 1)), "에이전트 1개가 실행 중입니다.")
        await t.equal("머리 문장 — 실행은 없고 인계 검토만", Overview.headline(Overview.Counts(waiting: 1)),
                      "실행 중인 에이전트는 없습니다. 1개가 답을 기다립니다.")
        await t.equal("머리 문장 — 아무것도 없음", Overview.headline(Overview.Counts()), Overview.emptyTitle)

        let badge = Overview.sidebarBadge(counts)
        await t.check("사이드바 행: 답을 기다리는 수와 실행 수", badge.waiting == 3 && badge.running == 5)
        let none = Overview.sidebarBadge(Overview.Counts())
        await t.check("아무것도 없으면 수 없이 이름만", none.waiting == nil && none.running == nil)
        await t.equal("기다린 시간", [0, 59, 125, 3_720].map { Overview.waitedText(since: Date(timeIntervalSince1970: 0),
                                                                               now: Date(timeIntervalSince1970: TimeInterval($0))) },
                      ["방금", "방금", "2분째", "1시간 2분째"])
        await t.equal("지금 하는 일을 글과 대상으로", [AppModel.splitActivity("명령 실행 중 · make test").1 ?? "", AppModel.splitActivity("생각하는 중").0],
                      ["make test", "생각하는 중"])

        await t.check("가운데 칸 현황: 저장값 · 옛 이름 · 여닫기",
                      WindowPane(rawValue: "overview") == .overview && WindowPane(rawValue: "현황") == .overview
                        && WindowPane.togglingOverview(shown: .overview) == .conversation
                        && WindowPane.togglingOverview(shown: .scoreboard) == .overview
                        && WindowPane.restored(.overview) == .overview)
        await t.check("⌃⌘0 은 앱 메뉴에 있고 단축키 시트의 보기 묶음에 있다",
                      MenuShortcut.appMenu.contains { $0.title == MenuShortcut.overview.title }
                        && MenuShortcut.helpSections.first { $0.title == "보기" }?.items.contains { $0.title == MenuShortcut.overview.title } == true)

        await codexSwitchRules(t)
    }

    /// 다른 계정에서 같은 세션을 이어 가기 카운트다운 — 자동 인계 카운트다운과 같은 구역 · 같은 순서, 글은 인계라 하지 않는다.
    static func codexSwitchRules(_ t: TestKit) async {
        await t.group("현황: 다른 계정에서 이어 가기 카운트다운")
        let switchKind = Overview.Kind.codexSwitch(deadline: Date(timeIntervalSince1970: 400))
        let mixed = [
            item("work", .working, since: 10),
            item("handoff", .handoffCountdown(deadline: Date(timeIntervalSince1970: 600)), since: 5, running: false),
            item("switch", switchKind, since: 50, running: false),
            item("approval", .approval, since: 300),
        ]
        await t.check("응답 필요 구역에 두되 사람이 답해야 끝나는 것은 아니다 (카운트다운)",
                      switchKind.needsResponse && !switchKind.waitsOnPerson && switchKind.isCountdown
                        && switchKind.countdownDeadline == Date(timeIntervalSince1970: 400))
        await t.equal("순서: 답을 기다리는 것 → 카운트다운들(종류와 상관없이 마감이 이른 것 먼저) → 일하는 중",
                      Overview.ordered(mixed).map(\.threadID), ["approval", "switch", "handoff", "work"])
        let groups = Overview.groups(mixed, sort: .status)
        await t.equal("자동 인계 카운트다운과 같은 구역 · 머리 뒤에 종류마다 수",
                      [groups.first?.title ?? "", groups.first?.note ?? "", "\(groups.first?.items.count ?? 0)"],
                      ["응답 필요 1", "자동 인계 대기 1 · 다른 계정에서 이어 가기 대기 1", "3"])
        let only = Overview.groups([item("s", switchKind, since: 0, running: false)], sort: .status)
        await t.check("이것만 있으면 그 이름으로 — \"응답 필요 0\" · \"자동 인계\" 라 하지 않는다",
                      only.first?.title == "다른 계정에서 이어 가기 대기 1" && only.first?.note == nil, only.first?.title ?? "nil")
        let counts = Overview.counts(mixed)
        await t.equal("수: 따로 센다 — 답을 기다림에도, 자동 인계 카운트다운에도 넣지 않는다",
                      [counts.waiting, counts.countdowns, counts.codexSwitches, counts.running], [1, 1, 1, 2])
        await t.equal("수 칸 · 구역 머리 뒤의 셈", Overview.countdownNote(counts) ?? "",
                      "자동 인계 대기 1 · 다른 계정에서 이어 가기 대기 1")
        await t.check("카운트다운이 없으면 셈도 없다", Overview.countdownNote(Overview.Counts(waiting: 2, running: 2)) == nil)
        await t.equal("머리 문장 — 세 마디", Overview.headline(counts),
                      "에이전트 2개가 실행 중입니다. 1개가 답을 기다리고, 1개는 곧 자동으로 인계하고, "
                        + "1개는 곧 다른 계정에서 같은 세션을 이어 갑니다.")
        await t.equal("머리 문장 — 이것만", Overview.headline(Overview.Counts(codexSwitches: 1)),
                      "실행 중인 에이전트는 없습니다. 1개는 곧 다른 계정에서 같은 세션을 이어 갑니다.")
        await t.equal("행의 상태 글", Overview.statusText(switchKind), CodexAccountSwitch.waitingText)
        await t.check("사이드바 맨 위 현황 행의 수에는 넣지 않는다 (자동 인계 카운트다운과 같다)",
                      Overview.sidebarBadge(Overview.Counts(codexSwitches: 1)).waiting == nil)
        let byProject = Overview.groups(mixed, sort: .project)
        await t.equal("프로젝트순 머리 뒤의 수 — 답을 기다리는 것만 센다", byProject.map { $0.note ?? "" }, ["응답 필요 1 · 실행 2"])
    }

    // MARK: 현황에서 답하기 (순수)

    static func answers(_ t: TestKit) async {
        await t.group("현황: 여기서 답할 수 있는 요청")
        func request(_ kind: ApprovalKind, tool: String, input: [String: Any]?) -> ApprovalRequest {
            ApprovalRequest(id: "r", runID: "run", provider: kind == .tool ? .claude : .codex, kind: kind, toolName: tool,
                            title: tool, detail: tool, input: input.flatMap { JSONUtil.line($0) })
        }
        func choice(_ request: ApprovalRequest) -> Overview.ApprovalChoice {
            Overview.approvalChoice(kind: request.kind, presentation: ApprovalPresentation.make(request, projectPath: "/tmp/p"),
                                    isQuestion: request.isQuestion)
        }
        let plain = choice(request(.tool, tool: "Bash", input: ["command": "swift test --filter X"]))
        await t.check("되돌릴 수 있는 명령은 여기서 허용 · 거절", plain.allowsHere && plain.deniesHere && plain.reason == nil)
        let risky = choice(request(.tool, tool: "Bash", input: ["command": "rm -rf build"]))
        await t.check("되돌릴 수 없는 명령은 허용은 대화에서, 거절은 여기서도",
                      !risky.allowsHere && risky.deniesHere && (risky.reason ?? "").contains("되돌릴 수 없는"), risky.reason ?? "")
        let reset = choice(request(.command, tool: "명령 실행", input: ["command": "git reset --hard origin/main"]))
        await t.check("Codex 의 git reset --hard 도 대화에서", !reset.allowsHere && reset.deniesHere)
        // 행의 미리보기는 첫 줄만 보인다 — CR 뒤에 숨은 꼬리 · 여러 줄 · 숨은 글자 · 긴 명령은 허용을 대화에서, 거절은 여기서도.
        let hiddenTail = choice(request(.tool, tool: "Bash", input: ["command": "npm test\r; echo hi"]))
        await t.check("CR 뒤에 꼬리가 있는 명령은 허용을 대화에서",
                      !hiddenTail.allowsHere && hiddenTail.deniesHere && (hiddenTail.reason ?? "").contains("숨은 글자"),
                      hiddenTail.reason ?? "")
        let twoLines = choice(request(.tool, tool: "Bash", input: ["command": "make test\nmake lint"]))
        await t.check("여러 줄 명령은 허용을 대화에서", !twoLines.allowsHere && twoLines.deniesHere)
        let bidi = choice(request(.tool, tool: "Bash", input: ["command": "echo \u{202E}hs.txt"]))
        await t.check("글 순서를 바꾸는 글자가 있는 명령은 허용을 대화에서", !bidi.allowsHere && bidi.deniesHere)
        let long = choice(request(.tool, tool: "Bash",
                                  input: ["command": "echo " + String(repeating: "a", count: Overview.overviewCommandColumns)]))
        await t.check("긴 한 줄 명령은 허용을 대화에서", !long.allowsHere && long.deniesHere)
        let tab = choice(request(.tool, tool: "Bash", input: ["command": "printf 'a\tb'"]))
        await t.check("탭만 있는 한 줄 명령은 여기서 허용", tab.allowsHere && tab.reason == nil, tab.reason ?? "")
        // 파일 경로 · 대상의 줄 끊는 글자 · 방향 글자 — 한 줄 미리보기가 CR 뒤를 숨기거나 순서를 뒤집는다 (프로젝트 밖을 가리켜도).
        let write = choice(request(.tool, tool: "Write", input: ["file_path": "/tmp/p/README.md", "content": "x"]))
        await t.check("보통 경로의 파일 쓰기는 여기서 허용", write.allowsHere && write.reason == nil, write.reason ?? "")
        let crWrite = choice(request(.tool, tool: "Write", input: ["file_path": "/tmp/p/README.md\r/../../../u/.zshrc", "content": "x"]))
        await t.check("경로에 CR 이 있는 파일 쓰기는 허용을 대화에서, 거절은 여기서도",
                      !crWrite.allowsHere && crWrite.deniesHere && (crWrite.reason ?? "").contains("숨은 글자"), crWrite.reason ?? "")
        let bidiEdit = choice(request(.tool, tool: "Edit", input: ["file_path": "/tmp/p/\u{202E}txt.hs", "old_string": "a",
                                                                   "new_string": "b"]))
        await t.check("경로에 방향 글자가 있는 편집은 허용을 대화에서", !bidiEdit.allowsHere && bidiEdit.deniesHere)
        let lfRead = choice(request(.tool, tool: "Read", input: ["file_path": "/tmp/p/a.txt\n/etc/hosts"]))
        await t.check("읽을 경로에 줄바꿈이 있으면 허용을 대화에서", !lfRead.allowsHere && lfRead.deniesHere)
        let permissions = choice(request(.permissions, tool: "권한 요청", input: ["network": true]))
        await t.check("권한을 넓히는 요청은 허용을 대화에서", !permissions.allowsHere && permissions.deniesHere)
        let elicitation = choice(request(.elicitation, tool: "MCP", input: nil))
        await t.check("MCP 입력 요청은 대화에서만", !elicitation.allowsHere && !elicitation.deniesHere)
        let asked = choice(request(.tool, tool: "AskUserQuestion",
                                   input: ["questions": [["question": "어느 쪽?", "header": "", "options": [["label": "A"]]]]]))
        await t.check("에이전트의 질문(AskUserQuestion)은 대화에서만 — 허용하면 답 없이 진행된다", !asked.allowsHere && !asked.deniesHere)

        let single = UserQuestion(id: "q", runID: "run", provider: .codex,
                                  items: [UserQuestion.Item(id: "i", header: "", question: "어느 쪽?", options: ["유지", "새로"],
                                                            allowsOther: true, isSecret: false)])
        await t.equal("한 항목 · 고를 답이 있는 질문은 여기서 고른다", Overview.questionOptions(single) ?? [], ["유지", "새로"])
        var secret = single
        secret.items[0].isSecret = true
        await t.check("비밀 입력은 대화에서", Overview.questionOptions(secret) == nil)
        var two = single
        two.items.append(UserQuestion.Item(id: "j", header: "", question: "또?", options: ["예"], allowsOther: false, isSecret: false))
        await t.check("여러 항목 질문은 대화에서", Overview.questionOptions(two) == nil)

        let preview = Overview.approvalPreview(ApprovalPresentation.make(request(.tool, tool: "Bash",
                                                                                 input: ["command": "make test\nmake lint"]),
                                                                         projectPath: nil), subject: "Claude")
        await t.check("미리보기: 무엇을 하려는지 한 줄 · 명령은 첫 줄과 …",
                      preview.line.hasPrefix("Claude: ") && preview.code == "make test …", "\(preview)")
        let crPreview = Overview.approvalPreview(ApprovalPresentation.make(request(.tool, tool: "Bash",
                                                                                   input: ["command": "npm test\r; echo hi"]),
                                                                           projectPath: nil), subject: "Claude")
        await t.check("미리보기: CR 에서 끊고 표시 ␍ 와 … 를 남긴다 (\"npm test\" 한 줄로 보이지 않게)",
                      crPreview.code == "npm test␍ …", "\(crPreview)")
        let pathPreview = Overview.approvalPreview(ApprovalPresentation.make(request(.tool, tool: "Write",
                                                                                     input: ["file_path": "/p/a.md\r/../.zshrc",
                                                                                             "content": "x"]),
                                                                             projectPath: nil), subject: "Claude")
        await t.equal("미리보기: 경로의 CR 도 표시 ␍ 로 (그 뒤가 숨지 않게)", pathPreview.code, "/p/a.md␍ /../.zshrc  1줄")
        let targetPreview = Overview.approvalPreview(ApprovalPresentation.make(request(.tool, tool: "Read",
                                                                                       input: ["file_path": "/p/\u{202E}gol.txt"]),
                                                                               projectPath: nil), subject: "Claude")
        await t.equal("미리보기: 대상의 방향 글자도 표시로", targetPreview.code, "/p/⟨U+202E⟩gol.txt")
    }

    // MARK: 끝난 실행 (순수)

    static func finished(_ t: TestKit) async {
        await t.group("현황: 최근 끝난 실행 · 오늘")
        func run(_ id: String, _ state: RunState, at: TimeInterval, tokens: Int?, cost: Double?, check: Bool = false) -> Overview.FinishedRun {
            Overview.FinishedRun(runID: id, threadID: "t" + id, title: id, project: "p", provider: .claude, state: state,
                                 endedAt: Date(timeIntervalSince1970: at), durationMs: 1_000, newTokens: tokens, cost: cost,
                                 needsCheck: check)
        }
        let runs = [run("a", .completed, at: 10, tokens: 1_200, cost: 0.5), run("b", .failed, at: 30, tokens: nil, cost: nil, check: true),
                    run("c", .cancelled, at: 20, tokens: 800, cost: 0.25)]
        await t.equal("최근 것 먼저", Overview.recent(runs).map(\.runID), ["b", "c", "a"])
        await t.equal("결과 글 — 확인 필요 · 사용자가 멈춘 실행", runs.map(Overview.resultText), ["완료", "오류 · 확인 필요", "중단됨"])
        await t.equal("오늘 칸 — 아는 새 토큰 · 비용만 더한다", Overview.todayText(runs),
                      "3 · 새 토큰 " + DisplayFormat.tokens(2_000) + " · " + DisplayFormat.cost(0.75) + " API 환산")
        await t.equal("기록 없는 오늘", Overview.todayText([]), "0")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let noon = Date(timeIntervalSince1970: 1_791_000_000)
        await t.equal("빈 상태의 한 줄", Overview.emptyLine(lastEnded: noon, today: runs, calendar: calendar),
                      "마지막 실행 " + Overview.clock(noon, now: Date(), calendar: calendar) + " · 오늘 끝난 실행 3 · 확인 필요 1")
        await t.check("확인할 것이 없으면 그렇게", Overview.emptyLine(lastEnded: nil, today: [], calendar: calendar) == "오늘 끝난 실행 0 · 확인할 것 없음")
        await t.equal("같은 날이면 시각만", Overview.clock(noon, now: noon, calendar: calendar).count, 5)
    }

    // MARK: 앱 모델

    /// 칸에 열지 않은 대화 셋(승인 · 되돌릴 수 없는 명령의 승인 · 일하는 중)을 가짜 어댑터로 돌린다: 행 · 수, 현황이 보이는 동안 상자를 든다,
    /// 여기서 허용한 결정이 그 실행 · 그 요청으로 간다, 되돌릴 수 없는 명령의 허용은 보내지 않는다, 이미 답한 요청은 다시 보내지 않는다,
    /// 중단, 메뉴의 승인 단축키가 현황에서 고른 행으로, 끝난 실행 표.
    static func app(_ t: TestKit) async {
        await t.group("현황: 앱")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-overview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let folder = root.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
            try await store.bootstrap()
            let project = Project(name: "현황", path: folder.path)
            try await store.upsertProject(project)
            func thread(_ title: String) async throws -> ConversationThread {
                var thread = ConversationThread(projectID: project.id, title: title)
                thread.claudeSelection = ModelSelection(model: "sonnet", effort: "high")
                try await store.upsertThread(thread)
                return thread
            }
            let plain = try await thread("허용할 대화"), risky = try await thread("지우려는 대화"), working = try await thread("일하는 대화")
            let opened = try await thread("보던 대화")

            let model = AppModel(store: store)
            model.runner.adapterFactory = { provider in
                ScriptedAgentAdapter(provider: provider) { request in
                    let session = AgentEvent.sessionEstablished(sessionID: "s-" + request.runID, model: "fake-model", cliVersion: nil)
                    let done = AgentTurnResult(state: .completed, terminalReason: "completed", sessionID: "s")
                    func bash(_ id: String, _ command: String) -> [ScriptedAgentAdapter.Step] {
                        [.emit(.approvalRequested(ApprovalRequest(id: id, runID: request.runID, provider: .claude, kind: .tool,
                                                                  toolName: "Bash", title: command, detail: command,
                                                                  input: JSONUtil.line(["command": command])))),
                         .waitApproval(id: id), .finish(done)]
                    }
                    switch request.prompt {
                    case let p where p.hasPrefix("허용"): return [.emit(session)] + bash("ok-1", "swift test")
                    case let p where p.hasPrefix("지우기"): return [.emit(session)] + bash("rm-1", "rm -rf build")
                    default: return [.emit(session), .waitInterrupt]
                    }
                }
            }
            await model.reloadProjects()
            func settle(_ condition: @MainActor () -> Bool) async {
                for _ in 0..<400 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
            }
            await model.selectThread(opened.id)
            _ = await model.send("허용해 주세요", provider: .claude, threadID: plain.id)
            _ = await model.send("지우기를 부탁", provider: .claude, threadID: risky.id)
            _ = await model.send("일해 주세요", provider: .claude, threadID: working.id)
            await settle {
                model.runner.session(threadID: plain.id)?.pendingApprovals.isEmpty == false
                    && model.runner.session(threadID: risky.id)?.pendingApprovals.isEmpty == false
                    && model.runner.session(threadID: working.id)?.isBusy == true
            }
            let items = model.overviewItems()
            let kinds = Dictionary(items.map { ($0.threadID, $0.kind) }, uniquingKeysWith: { a, _ in a })
            await t.check("행: 승인 둘 · 일하는 중 하나 (칸에 열지 않은 대화도)",
                          kinds[plain.id] == .approval && kinds[risky.id] == .approval && kinds[working.id] == .working
                            && kinds[opened.id] == nil, "\(kinds)")
            let counts = model.overviewCounts
            await t.check("수: 답을 기다림 2 · 실행 3", counts.waiting == 2 && counts.running == 3, "\(counts)")

            await t.check("현황이 보이기 전에는 칸 밖 대화의 상자를 들지 않는다", model.threadStates[working.id] == nil)
            await model.setOverviewVisible(true)
            await t.check("현황이 보이면 실행 중인 대화의 상자를 읽어 둔다 (지금 하는 일 한 줄)",
                          model.threadStates[working.id]?.loaded == true && model.threadStates[plain.id]?.loaded == true)
            model.pruneThreadStates()
            await t.check("현황이 보이는 동안은 거두지 않는다", model.threadStates[working.id] != nil)
            await t.check("일하는 행에 지금 하는 일이 있다",
                          model.overviewItems().first { $0.threadID == working.id }?.activity?.isEmpty == false)

            model.overviewSelection = plain.id
            await t.equal("메뉴의 승인 단축키는 현황에서 고른 행으로", model.approvalShortcutThreadID ?? "", plain.id)

            let refused = await model.respondFromOverview(threadID: risky.id, approvalID: "rm-1", decision: .allow)
            await t.check("되돌릴 수 없는 명령은 현황에서 허용하지 않는다", !refused && model.runner.session(threadID: risky.id)?.pendingApprovals.isEmpty == false)
            let wrongRun = await model.respondFromOverview(threadID: plain.id, approvalID: "rm-1", decision: .allow)
            await t.check("다른 대화의 요청 ID 로는 보내지 않는다", !wrongRun)
            let allowed = await model.respondFromOverview(threadID: plain.id, approvalID: "ok-1", decision: .allow)
            await settle { model.runner.session(threadID: plain.id) == nil }
            await t.check("현황에서 허용 — 그 실행의 그 요청으로 가고 실행이 끝난다", allowed && model.runner.session(threadID: plain.id) == nil)
            let again = await model.respondFromOverview(threadID: plain.id, approvalID: "ok-1", decision: .allow)
            await t.check("이미 답한 요청은 다시 보내지 않는다", !again)
            let denied = await model.respondFromOverview(threadID: risky.id, approvalID: "rm-1", decision: .deny(""))
            await settle { model.runner.session(threadID: risky.id) == nil }
            await t.check("되돌릴 수 없는 명령도 거절은 현황에서", denied && model.runner.session(threadID: risky.id) == nil)

            await model.stopFromOverview(threadID: working.id)
            await settle { model.runner.session(threadID: working.id) == nil }
            await t.check("현황에서 중단 — 그 실행만", model.runner.session(threadID: working.id) == nil)
            await settle { model.overviewItems().isEmpty }
            await t.check("다 끝나면 행이 없다", model.overviewItems().isEmpty)

            let result = await model.overviewFinishedRuns()
            let states = Dictionary(result.today.map { ($0.threadID, $0.state) }, uniquingKeysWith: { a, _ in a })
            await t.check("끝난 실행 표: 셋 다 오늘, 결과대로",
                          result.today.count == 3 && states[plain.id] == .completed && states[working.id] == .cancelled
                            && result.lastEnded != nil, "\(states)")

            await model.setOverviewVisible(false)
            await t.check("현황을 닫으면 칸 밖 대화의 상자를 거둔다",
                          model.threadStates[working.id] == nil && model.threadStates[opened.id] != nil)
            await t.equal("현황을 닫으면 승인 단축키는 다시 포커스 칸의 대화로", model.approvalShortcutThreadID ?? "", opened.id)
        } catch {
            await t.check("현황 앱 시험 준비", false, "\(error)")
        }
    }
}
