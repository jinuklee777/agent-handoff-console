import Foundation

/// 리디자인에서 새로 생긴 순수 로직 검증: 스트림 묶기, Git/PR 출력 해석, 읽기 전용 Git 조회.
/// 네트워크를 쓰지 않는다. 실제 git 조회는 임시 폴더에 만든 저장소로만 한다.
enum WorkspaceTests {
    static func run(_ t: TestKit) async {
        await gitParsing(t)
        await pullRequestParsing(t)
        await executionParsing(t)
        await streamGrouping(t)
        await unfinishedCalls(t)
        await liveGitStatus(t)
        await changesDecisions(t)
        await changesLiveQuery(t)
        await stage2Parsing(t)
        await stage2Decisions(t)
        await failureClassification(t)
        await stage2LiveQuery(t)
        await branchMenuDecisions(t)
        await syncVariantDecisions(t)
        await branchMenuLiveRepository(t)
        await syncVariantsThroughAppModel(t)
        await runChangesDecisions(t)
        await deadlineDecisions(t)
        await runChangesThroughAppModel(t)
        await liveRefreshDuringRun(t)
        await diffDecisions(t)
        await diffLiveRepository(t)
        await filePreview(t)
        await fileOpenRule(t)
    }

    // MARK: Git 출력 해석

    static func gitParsing(_ t: TestKit) async {
        await t.group("작업 폴더 Git 해석")

        var s = GitWorkspaceStatus()
        GitWorkspace.parseStatus(
            "## feat/x...origin/feat/x [ahead 2, behind 1]\0A  new.swift\0 M mod.swift\0MM both.swift\0"
                + "R  renamed.swift\0old.swift\0?? scratch.txt\0UU conflict.swift\0", into: &s)
        await t.equal("브랜치", s.branch, "feat/x")
        await t.equal("추적 브랜치", s.upstream, "origin/feat/x")
        await t.equal("앞섬", s.ahead, 2)
        await t.equal("뒤처짐", s.behind, 1)
        await t.equal("스테이지 목록", s.staged.map { "\($0.code) \($0.path)" },
                      ["A new.swift", "M both.swift", "R renamed.swift"])
        await t.equal("이름 변경 원래 경로", s.staged.last?.originalPath, "old.swift")
        await t.equal("작업 트리 목록", s.unstaged.map { "\($0.code) \($0.path)" }, ["M mod.swift", "M both.swift"])
        await t.equal("새 파일", s.untracked.map(\.path), ["scratch.txt"])
        await t.equal("충돌", s.conflicted.map(\.path), ["conflict.swift"])
        await t.equal("변경 파일 수 (중복 제외)", s.changeCount, 6)

        // 다른 worktree 가 쓰는 브랜치 (chg-16) — 이 폴더의 것은 빼고, 떼어진 HEAD 는 브랜치가 없다.
        let worktreeList = "worktree /repo/app\nHEAD aaa\nbranch refs/heads/main\n\nworktree /wt/app/1234abcd\nHEAD bbb\n"
            + "branch refs/heads/ahc/1234abcd\n\nworktree /wt/app/detached\nHEAD ccc\ndetached\n\n"
        await t.equal("worktree 목록: 다른 worktree 의 브랜치만",
                      GitWorkspace.parseWorktreeBranches(worktreeList, excluding: "/repo/app"),
                      ["ahc/1234abcd": "/wt/app/1234abcd"])
        await t.equal("독립 작업 폴더에서 보면 프로젝트 폴더의 main 이 다른 worktree 의 것",
                      GitWorkspace.parseWorktreeBranches(worktreeList, excluding: "/wt/app/1234abcd"), ["main": "/repo/app"])
        await t.check("git 이 없다는 오류를 가린다 (설치 안내로 잇는다, chg-23)",
                      GitWorkspace.isGitMissing(GitWorkspace.gitMissingMessage) && !GitWorkspace.isGitMissing("git status 실패"))

        var detached = GitWorkspaceStatus()
        GitWorkspace.parseBranchHeader("HEAD (no branch)", into: &detached)
        await t.check("detached HEAD 는 브랜치 없음", detached.branch == nil)
        var fresh = GitWorkspaceStatus()
        GitWorkspace.parseBranchHeader("No commits yet on main", into: &fresh)
        await t.equal("첫 커밋 전 브랜치", fresh.branch, "main")
        var gone = GitWorkspaceStatus()
        GitWorkspace.parseBranchHeader("main...origin/main [gone]", into: &gone)
        await t.check("원격 브랜치 사라짐은 앞섬/뒤처짐을 모름으로", gone.upstreamGone && gone.ahead == nil && gone.behind == nil)
        var noUpstream = GitWorkspaceStatus()
        GitWorkspace.parseBranchHeader("topic", into: &noUpstream)
        await t.check("추적 없음은 앞섬 값을 만들지 않음", noUpstream.upstream == nil && noUpstream.ahead == nil)

        let numstat = GitWorkspace.parseNumstat("12\t0\tnew.swift\0-\t-\timage.png\u{0}3\t1\t\0old.swift\0renamed.swift\0")
        await t.check("numstat 일반", numstat["new.swift"].map { $0.0 == 12 && $0.1 == 0 } ?? false)
        await t.check("numstat 이진 파일은 nil (0 으로 채우지 않음)",
                      numstat["image.png"].map { $0.0 == nil && $0.1 == nil } ?? false)
        await t.check("numstat 이름 변경은 새 경로", numstat["renamed.swift"].map { $0.0 == 3 && $0.1 == 1 } ?? false)

        let branches = GitWorkspace.parseBranches("main\0abc1234\0*\0origin/main\0[ahead 1]\ntopic\0def5678\0 \0\0\n")
        await t.equal("브랜치 수", branches.count, 2)
        await t.check("현재 브랜치 표시", branches.first?.isCurrent == true && branches.first?.ahead == 1)
        await t.check("추적 없는 브랜치", branches.last?.upstream == nil && branches.last?.isCurrent == false)
        await t.equal("하위 폴더 프로젝트 경로", GitWorkspace.relativePrefix(project: "/r/app/ios", root: "/r/app"), "ios")
        await t.equal("루트 프로젝트 경로", GitWorkspace.relativePrefix(project: "/r/app", root: "/r/app"), "")
    }

    // MARK: PR 해석

    static func pullRequestParsing(_ t: TestKit) async {
        await t.group("GitHub PR 해석")
        let json = """
        {"number":128,"title":"전송 계층 분리","state":"OPEN","isDraft":false,
         "url":"https://github.com/o/r/pull/128","headRefName":"feat/x","baseRefName":"main",
         "additions":186,"deletions":41,"changedFiles":7,"createdAt":"2026-09-10T02:00:00Z",
         "reviewDecision":"CHANGES_REQUESTED",
         "statusCheckRollup":[
           {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS",
            "startedAt":"2026-09-10T02:00:00Z","completedAt":"2026-09-10T02:02:14Z","workflowName":"CI"},
           {"__typename":"CheckRun","name":"unit-tests","status":"IN_PROGRESS","conclusion":""},
           {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"CANCELLED"},
           {"__typename":"StatusContext","context":"ci/legacy","state":"PENDING"}],
         "latestReviews":[{"author":{"login":"minji"},"state":"CHANGES_REQUESTED","body":"refresh() 경로",
                           "submittedAt":"2026-09-10T03:00:00Z"}]}
        """
        let info = GitHubCLI.parseView(json)
        await t.equal("PR 번호", info?.number, 128)
        await t.equal("체크 수", info?.checks.count, 4)
        await t.equal("체크 결과", info?.checks.map { "\($0.outcome)" }, ["pass", "pending", "fail", "pending"])
        await t.check("체크 소요 시간", info?.checks.first?.duration.map { Int($0) == 134 } ?? false)
        await t.equal("리뷰 작성자", info?.reviews.first?.author, "minji")
        await t.check("잘못된 JSON 은 nil", GitHubCLI.parseView("not json") == nil)
        let list = GitHubCLI.parseList("[{\"number\":126,\"title\":\"a\",\"state\":\"MERGED\",\"isDraft\":false,"
                                       + "\"headRefName\":\"b\"}]")
        await t.equal("다른 PR 목록", list.map(\.number), [126])
    }

    // MARK: 실행 기록 항목

    static func executionParsing(_ t: TestKit) async {
        await t.group("실행 기록 항목")
        await t.equal("셸 래퍼 벗기기", ExecutionParser.displayCommand("/bin/zsh -lc 'swift test'"), "swift test")
        await t.equal("작은따옴표 이스케이프 복원",
                      ExecutionParser.displayCommand("bash -lc 'echo '\\''hi'\\'''"), "echo 'hi'")
        await t.equal("모르는 형태는 그대로", ExecutionParser.displayCommand("git status"), "git status")
        let stats = ExecutionParser.diffStats("--- a/x\n+++ b/x\n@@ -1 +1,2 @@\n-old\n+new\n+more\n")
        await t.check("diff 줄 수", stats.map { $0.added == 2 && $0.removed == 1 } ?? false)
        await t.check("diff 표식이 없으면 세지 않음", ExecutionParser.diffStats("plain text\n+not a diff") == nil)
        await t.equal("추론 조각 이어 붙이기", ExecutionParser.mergeReasoning("The user", " wants"), "The user wants")
        await t.equal("추론 전체 본문으로 교체",
                      ExecutionParser.mergeReasoning("The user wants", "The user wants a fix."), "The user wants a fix.")

        let thread = "t1", run = "r1"
        var events: [ThreadEvent] = []
        func add(_ kind: EventKind, _ provider: AgentProvider, title: String = "", text: String,
                 payload: [String: Any]? = nil, tool: String? = nil) {
            events.append(ThreadEvent(threadID: thread, runID: run, seq: Int64(events.count + 1), kind: kind,
                                      provider: provider, title: title, text: text,
                                      payloadJSON: payload.flatMap { JSONUtil.line($0) }, toolUseID: tool))
        }
        // Codex: 시작 → 완료 두 이벤트, 파일 변경
        add(.commandExecution, .codex, text: "/bin/zsh -lc 'make'", payload: ["status": "inProgress"], tool: "c1")
        add(.commandExecution, .codex, text: "/bin/zsh -lc 'make'\n\n--- 출력 ---\nok",
            payload: ["status": "completed", "exitCode": 0], tool: "c1")
        add(.fileChange, .codex, text: "/p/src/a.swift\n\n--- a\n+++ b\n@@\n+x\n", payload: ["status": "completed"],
            tool: "f1")
        // Claude: Bash 요청 + 오류 결과, Edit 요청
        add(.toolRequest, .claude, title: "Bash", text: #"{"command":"swift test"}"#, tool: "b1")
        add(.toolResult, .claude, title: "도구 결과 — 오류", text: "exit 1", tool: "b1")
        add(.toolRequest, .claude, title: "Edit",
            text: #"{"file_path":"/p/src/b.swift","old_string":"a\nb","new_string":"c"}"#, tool: "e1")
        add(.agentReasoning, .claude, text: "생각 ")
        add(.agentReasoning, .claude, text: "중")

        let entries = ExecutionParser.entries(from: events, projectPath: "/p")
        await t.equal("항목 수 (시작/완료·요청/결과 합침)", entries.count, 5)
        if case .command(let info)? = entries.first?.kind {
            await t.check("Codex 명령은 완료 값으로", info.exitCode == 0 && !info.running && info.output == "ok"
                          && info.command == "make")
        } else {
            await t.check("Codex 명령 항목", false)
        }
        if case .fileEdit(let info)? = entries[safe: 1]?.kind {
            await t.check("파일 변경 경로는 프로젝트 기준", info.paths == ["src/a.swift"] && info.added == 1)
        } else {
            await t.check("파일 변경 항목", false)
        }
        if case .command(let info)? = entries[safe: 2]?.kind {
            await t.check("Claude Bash 오류는 종료 코드 없이 오류로", info.reportedError && info.exitCode == nil
                          && info.failed && !info.running)
        } else {
            await t.check("Claude Bash 항목", false)
        }
        if case .fileEdit(let info)? = entries[safe: 3]?.kind {
            await t.check("Edit 줄 수 (관찰값)", info.added == 1 && info.removed == 2 && info.running)
        } else {
            await t.check("Edit 항목", false)
        }
        if case .reasoning(let text)? = entries[safe: 4]?.kind {
            await t.equal("추론 조각은 하나로", text, "생각 중")
        } else {
            await t.check("추론 항목", false)
        }
        let touched = ExecutionParser.touchedFiles(in: events, projectPath: "/p")
        await t.check("에이전트별 편집 파일", touched["src/a.swift"] == [.codex] && touched["src/b.swift"] == [.claude])
    }

    // MARK: 스트림 행

    static func streamGrouping(_ t: TestKit) async {
        await t.group("스트림 묶기")
        let thread = "t"
        var r1 = Run(threadID: thread, sessionID: "s", provider: .claude, requestText: "q", state: .completed)
        r1.id = "r1"
        var r2 = Run(threadID: thread, sessionID: "s2", provider: .codex, requestText: "h", state: .running,
                     isHandoffDelivery: true)
        r2.id = "r2"
        var h = Handoff(threadID: thread, fromProvider: .claude, toProvider: .codex, baseSeq: 3, draftJSON: "{}",
                        finalText: "문서")
        h.deliveryState = .delivered
        var seq: Int64 = 0
        func e(_ kind: EventKind, _ provider: AgentProvider?, run: String?, text: String = "x",
               payload: [String: Any]? = nil) -> ThreadEvent {
            seq += 1
            return ThreadEvent(threadID: thread, runID: run, seq: seq, kind: kind, provider: provider, text: text,
                               payloadJSON: payload.flatMap { JSONUtil.line($0) })
        }
        let events = [
            e(.userMessage, nil, run: "r1"),
            e(.agentReasoning, .claude, run: "r1"),
            e(.agentMessage, .claude, run: "r1"),
            e(.commandExecution, .claude, run: "r1", payload: ["status": "completed", "exitCode": 0]),
            e(.handoffSent, .claude, run: nil, payload: ["localToken": h.localToken]),
            e(.agentMessage, .codex, run: "r2"),
            e(.handoffReceived, .codex, run: "r2", payload: ["localToken": h.localToken, "state": "delivered"]),
        ]
        let rows = StreamBuilder.rows(events: events, runs: ["r1": r1, "r2": r2], handoffs: [h], projectPath: nil)
        let kinds = rows.map { row -> String in
            switch row {
            case .user: return "user"
            case .agentHeader: return "header"
            case .agentMessage: return "message"
            case .execution: return "exec"
            case .runChanges: return "changes"
            case .turnFooter: return "footer"
            case .relay: return "relay"
            case .alert: return "alert"
            case .notice: return "notice"
            }
        }
        await t.equal("행 순서", kinds, ["user", "header", "exec", "message", "exec", "footer", "relay",
                                         "header", "message"])
        if case .relay(let relay)? = rows.first(where: { if case .relay = $0 { return true } else { return false } }) {
            await t.check("릴레이는 인계 기록과 짝지음", relay.handoff?.id == h.id && relay.number == 1
                          && relay.received != nil)
        } else {
            await t.check("릴레이 행", false)
        }
        await t.check("실행 중인 턴에는 바닥글을 붙이지 않음", !rows.contains(.turnFooter(runID: "r2")))
        await t.equal("행 식별자 중복 없음", Set(rows.map(\.id)).count, rows.count)
    }

    /// 끝난 실행에 결과 없이 남은 호출은 "실행 중"(도는 링)이 아니라 "결과 미확인" (2026-09-29 — 옛 가져오기가 이미지 결과 뒤의
    /// CLI 안내 줄을 사람의 메시지로 넣어 Read 의 결과가 다음 턴으로 갈라졌고, 링이 영영 돌며 분할 화면 전체를 매 프레임 다시 그렸다).
    static func unfinishedCalls(_ t: TestKit) async {
        await t.group("스트림 묶기: 결과 없이 끝난 호출")
        var seq: Int64 = 0
        func e(_ kind: EventKind, run: String, title: String = "", text: String = "x", tool: String? = nil,
               payload: [String: Any]? = nil) -> ThreadEvent {
            seq += 1
            return ThreadEvent(threadID: "t", runID: run, seq: seq, kind: kind, provider: .claude, title: title, text: text,
                               payloadJSON: payload.flatMap { JSONUtil.line($0) }, toolUseID: tool)
        }
        let events = [
            e(.userMessage, run: "r1", text: "캡처 봐 줘"),
            e(.toolRequest, run: "r1", title: "Read", text: #"{"file_path":"/p/a.png"}"#, tool: "read"),
            e(.toolRequest, run: "r1", title: "Bash", text: #"{"command":"make"}"#, tool: "bash"),
            e(.toolRequest, run: "r1", title: "Edit", text: #"{"file_path":"/p/b.swift","old_string":"a","new_string":"b"}"#,
              tool: "edit"),
            e(.commandExecution, run: "r1", text: "sleep 5", tool: "cmd", payload: ["status": "inProgress"]),
            e(.userMessage, run: "r2", text: "[Image: original 2544x1046, displayed at 2000x822.]"),
            e(.toolResult, run: "r2", title: "Read", text: "", tool: "read"),
        ]
        func firstBlock(_ state: RunState) -> [ExecutionEntry] {
            let runs = ["r1": makeRun("r1", state), "r2": makeRun("r2", .completed)]
            for row in StreamBuilder.rows(events: events, runs: runs, handoffs: [], projectPath: "/p") {
                if case .execution(_, let entries) = row { return entries }
            }
            return []
        }
        func states(_ entries: [ExecutionEntry]) -> [String] {
            entries.map { entry in
                switch entry.kind {
                case .tool(let i): return i.running ? "running" : (i.unfinished ? "unfinished" : "done")
                case .command(let i): return i.running ? "running" : (i.unfinished ? "unfinished" : "done")
                case .fileEdit(let i): return i.running ? "running" : (i.unfinished ? "unfinished" : "done")
                default: return "other"
                }
            }
        }
        await t.equal("끝난 실행: 도구 · Bash · 편집 · Codex 명령 모두 결과 미확인", states(firstBlock(.completed)),
                      ["unfinished", "unfinished", "unfinished", "unfinished"])
        await t.equal("멈춘 실행도 같다", states(firstBlock(.cancelled)), ["unfinished", "unfinished", "unfinished", "unfinished"])
        await t.equal("도는 실행은 그대로 실행 중", states(firstBlock(.running)), ["running", "running", "running", "running"])
    }

    static func makeRun(_ id: String, _ state: RunState) -> Run {
        var run = Run(threadID: "t", sessionID: "s", provider: .claude, requestText: "q", state: state)
        run.id = id
        return run
    }

    // MARK: 실제 git (임시 저장소, 읽기 전용 조회)

    static func liveGitStatus(_ t: TestKit) async {
        await t.group("작업 폴더 Git 조회")
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ahc-git-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        guard let git = GitInspector.findGit(environment: env) else {
            await t.check("git 실행 파일", false, "찾지 못함")
            return
        }
        func sh(_ args: [String]) async {
            _ = await CLIEnvironment.captureOutput(
                executable: git, arguments: ["-c", "user.name=t", "-c", "user.email=t@example.com",
                                             "-c", "commit.gpgsign=false"] + args,
                environment: env, workingDirectory: dir, timeout: 20)
        }
        await sh(["init", "-q", "-b", "main"])
        try? "a\nb\n".write(to: dir.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        await sh(["add", "tracked.txt"])
        await sh(["commit", "-q", "-m", "init"])
        try? "a\nB\nc\n".write(to: dir.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try? "n1\nn2\nn3\n".write(to: dir.appendingPathComponent("staged.txt"), atomically: true, encoding: .utf8)
        await sh(["add", "staged.txt"])
        try? "u\n".write(to: dir.appendingPathComponent("새 파일.txt"), atomically: true, encoding: .utf8)

        let indexBefore = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(".git/index").path))?[
            .modificationDate] as? Date
        let status = await GitWorkspace.status(at: dir, environment: env)
        let indexAfter = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(".git/index").path))?[
            .modificationDate] as? Date

        await t.check("저장소 인식", status.isRepository)
        await t.equal("브랜치", status.branch, "main")
        await t.check("스테이지 + 줄 수 (마지막 커밋 대비)",
                      status.staged.first?.path == "staged.txt" && status.headLineCounts["staged.txt"]?.added == 3,
                      "\(status.staged) \(status.headLineCounts)")
        await t.check("작업 트리 + 줄 수 (마지막 커밋 대비)",
                      status.unstaged.first?.path == "tracked.txt"
                          && status.headLineCounts["tracked.txt"] == GitLineCount(added: 2, removed: 1),
                      "\(status.unstaged) \(status.headLineCounts)")
        await t.equal("한글 파일 이름 (quotepath 끔)", status.untracked.map(\.path), ["새 파일.txt"])
        await t.check("새 파일 줄 수는 직접 셈", status.untracked.first?.added == 1)
        await t.equal("로컬 브랜치", status.localBranches.map(\.name), ["main"])
        await t.check("조회가 인덱스를 고쳐 쓰지 않음 (--no-optional-locks)", indexBefore == indexAfter)

        let handoffGit = await GitInspector.snapshot(at: dir, environment: env)
        await t.check("인계용 git diff 수집",
                      handoffGit.diffExcerpt?.contains("tracked.txt") == true
                      && handoffGit.diffExcerpt?.contains("staged.txt") == true)
        await t.check("인계용 git diff 길이 제한",
                      (handoffGit.diffExcerpt?.count ?? 0) <= HandoffPacketBuilder.diffCharLimit)

        let files = await GitWorkspace.listFiles(at: dir, environment: env)
        await t.equal("파일 목록 (.gitignore 기준)", Set(files), ["tracked.txt", "staged.txt", "새 파일.txt"])
        switch await GitWorkspace.grep("B", at: dir, environment: env) {
        case .success(let matches):
            await t.check("내용 검색", matches.contains { $0.path == "tracked.txt" && $0.line == 2 }, "\(matches)")
        case .failure(let error):
            await t.check("내용 검색", false, error.message)
        }
        if case .success(let none) = await GitWorkspace.grep("zzz-없음", at: dir, environment: env) {
            await t.check("일치 없음은 빈 결과 (오류 아님)", none.isEmpty)
        } else {
            await t.check("일치 없음은 빈 결과 (오류 아님)", false)
        }
        let plain = fm.temporaryDirectory.appendingPathComponent("ahc-plain-\(UUID().uuidString)")
        try? fm.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: plain) }
        let notRepo = await GitWorkspace.status(at: plain, environment: env)
        await t.check("Git 이 아닌 폴더", !notRepo.isRepository && notRepo.error == nil)
    }
}

// MARK: - 변경사항 탭

extension WorkspaceTests {
    /// 변경사항 탭의 순수 판정 (`ChangesState`): 행 합치기 · 포함 3상태 · 체크 → 명령 · 전체 선택/해제 ·
    /// 동기화 상태 · 주 버튼 · 잠금/커밋 불가 이유 · ⌘↵ 배타 · 문구 도우미 · 옛 탭 값.
    static func changesDecisions(_ t: TestKit) async {
        await t.group("변경사항 탭 판정")

        // 행 합치기 — 경로당 한 행, 대표 코드는 마지막 커밋 대비 파일 전체.
        var s = GitWorkspaceStatus()
        GitWorkspace.parseStatus(
            "## feature/login...origin/feature/login [ahead 2]\0A  Moa/Auth/AuthTransport.swift\0"
                + "M  Moa/Auth/AuthViewModel.swift\0 D Moa/Auth/LegacyTokenStore.swift\0MM Moa/Login/LoginView.swift\0"
                + "AM new/Added.swift\0R  new/Renamed.swift\0old/Renamed.swift\0?? scratch.txt\0UU conflict.swift\0",
            into: &s)
        s.headLineCounts = ["Moa/Auth/AuthViewModel.swift": GitLineCount(added: 4, removed: 2),
                            "Moa/Auth/LegacyTokenStore.swift": GitLineCount(added: 0, removed: 3),
                            "Moa/Login/LoginView.swift": GitLineCount(added: 4, removed: 2),
                            "Moa/Auth/AuthTransport.swift": GitLineCount(added: 4, removed: 0)]
        s.untracked[0].added = 5
        s.untracked[0].removed = 0
        let rows = ChangesState.rows(from: s)
        await t.equal("경로당 한 행 · 충돌 먼저 · 경로 순", rows.map(\.path),
                      ["conflict.swift", "Moa/Auth/AuthTransport.swift", "Moa/Auth/AuthViewModel.swift",
                       "Moa/Auth/LegacyTokenStore.swift", "Moa/Login/LoginView.swift", "new/Added.swift",
                       "new/Renamed.swift", "scratch.txt"])
        await t.equal("대표 코드 (AM→A, MM→M, ' D'→D, R, 새 파일→A)", rows.map(\.code),
                      ["U", "A", "M", "D", "M", "A", "R", "A"])
        await t.equal("포함 상태", rows.map(\.inclusion.rawValue),
                      ["conflict", "on", "on", "off", "mixed", "mixed", "on", "off"])
        await t.equal("이름 변경은 원래 경로를 기억", rows.first { $0.path == "new/Renamed.swift" }?.originalPath,
                      "old/Renamed.swift")
        let login = rows.first { $0.path == "Moa/Login/LoginView.swift" }
        await t.check("줄 수는 마지막 커밋 대비 파일 전체 (git diff HEAD)",
                      login?.added == 4 && login?.removed == 2)
        await t.check("줄 수를 모르면 nil (0 으로 채우지 않음)",
                      rows.first { $0.path == "new/Added.swift" }.map { $0.added == nil && $0.removed == nil } ?? false)
        let scratch = rows.first { $0.path == "scratch.txt" }
        await t.check("새 파일은 직접 센 줄 수 · 추적 안 됨 표시", scratch?.added == 5 && scratch?.isUntracked == true)
        await t.check("충돌 행은 체크할 수 없음", rows.first?.isCheckable == false)

        // 툴바의 "변경 N +a −d" (인스펙터를 닫았을 때) — 행과 같은 판정, 줄 수는 아는 행만 더한다.
        var repo = s
        repo.isRepository = true
        await t.equal("변경 요약: 파일 8 · +17 −7 · 줄 수 모름 3 (충돌 · AM · 이름 변경) · 충돌 1",
                      ChangesState.summary(of: repo),
                      ChangesState.Summary(files: 8, added: 17, removed: 7, unknownLines: 3, conflicts: 1))
        var clean = GitWorkspaceStatus()
        clean.isRepository = true
        GitWorkspace.parseStatus("## main\0", into: &clean)
        var unreadable = repo
        unreadable.error = "fatal: not a git repository"
        await t.check("변경 요약은 바뀐 파일이 없거나 · 저장소가 아니거나 · 상태를 못 읽으면 없음",
                      ChangesState.summary(of: clean) == nil && ChangesState.summary(of: s) == nil
                      && ChangesState.summary(of: unreadable) == nil && ChangesState.summary(of: nil) == nil)

        await t.equal("대표 코드: MD → D", ChangesState.representativeCode(staged: "M", unstaged: "D", untracked: false), "D")
        await t.equal("대표 코드: 'D ' → D", ChangesState.representativeCode(staged: "D", unstaged: nil, untracked: false), "D")
        await t.equal("대표 코드: 인덱스 삭제 + 같은 경로 새 파일(git rm --cached) → D (커밋이 하는 일)",
                      ChangesState.representativeCode(staged: "D", unstaged: nil, untracked: true), "D")
        await t.equal("대표 코드: AD → A (마지막 커밋에 없던 파일은 '지움' 이 아님)",
                      ChangesState.representativeCode(staged: "A", unstaged: "D", untracked: false), "A")
        var untrack = GitWorkspaceStatus()
        GitWorkspace.parseStatus("## main\0D  secrets.env\0?? secrets.env\0AD n.txt\0", into: &untrack)
        untrack.headLineCounts = ["secrets.env": GitLineCount(added: 0, removed: 2)]
        let untrackRows = ChangesState.rows(from: untrack)
        let secrets = untrackRows.first { $0.path == "secrets.env" }
        await t.check("추적 중지(D + 같은 경로 새 파일): D · 포함됨 · 사실 도움말",
                      secrets?.code == "D" && secrets?.inclusion == .on && secrets?.isUntracked == false
                      && secrets?.codeNote?.contains("추적 중지") == true && secrets?.removed == 2,
                      "\(String(describing: secrets))")
        await t.check("추적 중지는 전체 선택이 git add 로 되돌리지 않음 · 끄면 추적 복원(unstage)",
                      ChangesState.selectAllOperation(untrackRows.filter { $0.path == "secrets.env" }) == nil
                      && secrets.map { ChangesState.toggleOperation(for: $0) == .unstage(["secrets.env"]) } == true)
        let addedThenDeleted = untrackRows.first { $0.path == "n.txt" }
        await t.check("AD: A · 일부 포함 · 줄 수 모름 · 디스크에서 지워짐 도움말",
                      addedThenDeleted?.code == "A" && addedThenDeleted?.inclusion == .mixed
                      && addedThenDeleted?.added == nil && addedThenDeleted?.codeNote?.contains("지워졌") == true,
                      "\(String(describing: addedThenDeleted))")

        // 체크 → 실행할 명령
        func row(_ path: String) -> ChangesState.Row { rows.first { $0.path == path }! }
        await t.check("꺼짐을 체크하면 stage",
                      ChangesState.toggleOperation(for: row("Moa/Auth/LegacyTokenStore.swift"))
                          == .stage(["Moa/Auth/LegacyTokenStore.swift"]))
        await t.check("일부 포함을 체크하면 파일 전체 stage",
                      ChangesState.toggleOperation(for: row("Moa/Login/LoginView.swift"))
                          == .stage(["Moa/Login/LoginView.swift"]))
        await t.check("켜짐을 끄면 unstage",
                      ChangesState.toggleOperation(for: row("Moa/Auth/AuthViewModel.swift"))
                          == .unstage(["Moa/Auth/AuthViewModel.swift"]))
        await t.check("이름 변경을 끄면 원래 경로도 함께 unstage",
                      ChangesState.toggleOperation(for: row("new/Renamed.swift"))
                          == .unstage(["new/Renamed.swift", "old/Renamed.swift"]))
        await t.check("충돌 행은 명령 없음", ChangesState.toggleOperation(for: row("conflict.swift")) == nil)

        // 전체 선택 · 해제
        await t.check("전체 선택 = 포함 안 된 변경(작업 트리 · 새 파일) 모두 stage, 충돌 제외",
                      ChangesState.selectAllOperation(rows)
                          == .stage(["Moa/Auth/LegacyTokenStore.swift", "Moa/Login/LoginView.swift",
                                     "new/Added.swift", "scratch.txt"]))
        await t.check("선택 해제 = 스테이지된 것 모두 unstage (이름 변경 원래 경로 포함)",
                      ChangesState.deselectAllOperation(rows)
                          == .unstage(["Moa/Auth/AuthTransport.swift", "Moa/Auth/AuthViewModel.swift",
                                       "Moa/Login/LoginView.swift", "new/Added.swift", "new/Renamed.swift",
                                       "old/Renamed.swift"]))
        let offOnly = rows.filter { $0.inclusion == .off }
        await t.check("할 것이 없으면 명령 없음",
                      ChangesState.deselectAllOperation(offOnly) == nil && ChangesState.selectAllOperation([]) == nil)

        // 머리 체크박스 3상태 · 포함 수
        let main = rows.filter { ["Moa/Auth/AuthTransport.swift", "Moa/Auth/AuthViewModel.swift",
                                  "Moa/Auth/LegacyTokenStore.swift", "Moa/Login/LoginView.swift"].contains($0.path) }
        await t.equal("머리 체크박스: 일부만 포함 → mixed", ChangesState.headerState(main), .mixed)
        await t.equal("\"4개 중 3개 포함\" (일부 포함도 포함으로 셈)", ChangesState.includedCount(main), 3)
        await t.equal("머리 체크박스: 모두 켜짐 → on",
                      ChangesState.headerState(rows.filter { $0.inclusion == .on }), .on)
        await t.equal("머리 체크박스: 포함 없음 → off", ChangesState.headerState(offOnly), .off)
        await t.equal("머리 체크박스: 일부 포함뿐 → mixed",
                      ChangesState.headerState(rows.filter { $0.inclusion == .mixed }), .mixed)
        await t.equal("머리 체크박스: 충돌뿐 → off (체크할 행 없음)",
                      ChangesState.headerState(rows.filter { $0.inclusion == .conflict }), .off)
        let onPlusConflict = rows.filter { $0.inclusion == .on || $0.inclusion == .conflict }
        await t.equal("머리 체크박스: 나머지가 모두 켜져도 충돌이 있으면 mixed ('n개 중 m개 포함' 과 같은 말)",
                      ChangesState.headerState(onPlusConflict), .mixed)
        await t.check("머리 체크박스 누름: 넣을 것이 충돌뿐이면 빼기로 (누른 것이 헛돌지 않게)",
                      ChangesState.headerToggleOperation(onPlusConflict)
                          == ChangesState.deselectAllOperation(onPlusConflict)
                      && ChangesState.headerToggleOperation(main) == ChangesState.selectAllOperation(main)
                      && ChangesState.headerToggleOperation(rows.filter { $0.inclusion == .on })
                          == ChangesState.deselectAllOperation(rows.filter { $0.inclusion == .on }))

        // 찾기 (이름 · 경로 부분 일치)
        await t.equal("찾기: 대소문자 무시 이름 일치", ChangesState.filter(rows, query: "loginview").map(\.path),
                      ["Moa/Login/LoginView.swift"])
        await t.equal("찾기: 경로 일치", ChangesState.filter(rows, query: "Auth/").count, 3)
        await t.equal("찾기: 빈 칸은 전부", ChangesState.filter(rows, query: "  ").count, rows.count)

        // 동기화 상태
        func sync(upstream: String? = "origin/x", ahead: Int? = 0, behind: Int? = 0, gone: Bool = false,
                  remotes: [String]? = ["origin"], branch: String? = "x", fresh: Bool = false,
                  remoteBranches: [String]? = []) -> ChangesState.Sync {
            var st = GitWorkspaceStatus()
            st.branch = branch
            st.upstream = upstream
            st.ahead = upstream == nil ? nil : ahead
            st.behind = upstream == nil ? nil : behind
            st.upstreamGone = gone
            st.remotes = remotes
            st.noCommitsYet = fresh
            st.remoteBranches = GitWorkspace.parseRemoteBranches(
                (remoteBranches ?? []).map { "refs/remotes/\($0)\0abc1234\0방금" }.joined(separator: "\n"),
                remotes: remotes)
            st.remoteBranchesRead = remoteBranches != nil
            return ChangesState.sync(st)
        }
        await t.equal("원격과 같음", sync(), .inSync(upstream: "origin/x"))
        await t.equal("업로드 대기", sync(ahead: 2), .ahead(upstream: "origin/x", count: 2))
        await t.equal("원격 변경 도착", sync(behind: 3), .behind(upstream: "origin/x", count: 3))
        await t.equal("기록 분기", sync(ahead: 2, behind: 3), .diverged(upstream: "origin/x", ahead: 2, behind: 3))
        await t.equal("추적 브랜치가 원격에 없음 · 같은 이름 origin 브랜치 → 게시로 다시 만들 수 있음",
                      sync(ahead: nil, behind: nil, gone: true), .upstreamGone(upstream: "origin/x", republish: true))
        await t.equal("추적 브랜치가 원격에 없음 · 다른 이름이면 게시를 제안하지 않음 (다른 곳에 만들게 됨)",
                      sync(upstream: "origin/old", ahead: nil, behind: nil, gone: true),
                      .upstreamGone(upstream: "origin/old", republish: false))
        await t.equal("빈 저장소 clone 직후 (첫 커밋 전 + gone) → 올릴 것 없음",
                      sync(ahead: nil, behind: nil, gone: true, fresh: true),
                      .upstreamGone(upstream: "origin/x", republish: false))
        await t.equal("첫 커밋 전 + 추적 설정 → 앞섬/뒤처짐 모름", sync(fresh: true), .unknown(upstream: "origin/x"))
        await t.equal("앞섬/뒤처짐 모름 → 숫자 없음", sync(ahead: nil, behind: nil), .unknown(upstream: "origin/x"))
        await t.equal("upstream 없음 · origin 에 같은 이름 없음 → 새로 게시",
                      sync(upstream: nil, remoteBranches: ["origin/main"]), .noUpstream(.available(onRemote: false)))
        await t.equal("upstream 없음 · origin/x 이미 있음 → '원격에 없다' 고 하지 않음",
                      sync(upstream: nil, remoteBranches: ["origin/main", "origin/x"]),
                      .noUpstream(.available(onRemote: true)))
        await t.equal("upstream 없음 · 원격 브랜치 목록을 못 읽음 → 있는지 모름",
                      sync(upstream: nil, remoteBranches: nil), .noUpstream(.available(onRemote: nil)))
        await t.equal("upstream 없음 · origin 아닌 원격만 → 앱에서 게시 안 함",
                      sync(upstream: nil, remotes: ["fork"]), .noUpstream(.noOrigin))
        await t.equal("첫 커밋 전 → 게시할 것 없음", sync(upstream: nil, fresh: true), .noUpstream(.noCommits))
        await t.equal("원격 저장소 없음", sync(upstream: nil, remotes: []), .noRemote)
        await t.equal("git remote 를 못 읽음 → '원격 없음' 이라 하지 않음",
                      sync(upstream: nil, remotes: nil), .noUpstream(.remotesUnknown))
        await t.equal("detached", sync(upstream: nil, branch: nil), .detached)
        await t.check("게시 버튼을 둘 수 있는 상태",
                      ChangesState.canPublish(.noUpstream(.available(onRemote: true)))
                      && ChangesState.canPublish(.upstreamGone(upstream: "origin/x", republish: true))
                      && !ChangesState.canPublish(.upstreamGone(upstream: "origin/x", republish: false))
                      && !ChangesState.canPublish(.noUpstream(.remotesUnknown))
                      && !ChangesState.canPublish(.noRemote))

        // 요약 항목 — "원격과 같음" 은 변경이 없을 때만
        await t.equal("요약: 변경 없음 + 같음", ChangesState.remoteSummary(.inSync(upstream: "o/x"), hasChanges: false), .same)
        await t.check("요약: 변경이 있으면 '원격과 같음' 을 쓰지 않음",
                      ChangesState.remoteSummary(.inSync(upstream: "o/x"), hasChanges: true) == nil)
        await t.equal("요약: 업로드할 커밋", ChangesState.remoteSummary(.ahead(upstream: "o/x", count: 2), hasChanges: true),
                      .toUpload(2))
        await t.check("요약: 모르면 쓰지 않음", ChangesState.remoteSummary(.unknown(upstream: "o/x"), hasChanges: false) == nil)
        await t.check("요약: '원격에 없는 브랜치' 는 origin 에 같은 이름이 없을 때만",
                      ChangesState.remoteSummary(.noUpstream(.available(onRemote: false)), hasChanges: true) == .notOnRemote
                      && ChangesState.remoteSummary(.noUpstream(.available(onRemote: true)), hasChanges: true) == .notTracking
                      && ChangesState.remoteSummary(.noUpstream(.available(onRemote: nil)), hasChanges: true) == .notTracking)

        // 주 버튼 — 한 화면에 잉크 하나. 체크한 파일이 있으면 커밋, 없으면 업로드 · 게시.
        let ahead = ChangesState.Sync.ahead(upstream: "origin/x", count: 2)
        await t.equal("체크한 파일 + 업로드 대기 → 커밋이 주 버튼 (업로드는 흰 칩)",
                      ChangesState.primary(includedCount: 3, sync: ahead), .commit)
        await t.equal("체크한 파일 없음 + 업로드 대기 → 업로드가 주 버튼 (커밋 완료 화면)",
                      ChangesState.primary(includedCount: 0, sync: ahead), .upload)
        await t.equal("체크한 파일 없음 + upstream 없음 → 브랜치 게시",
                      ChangesState.primary(includedCount: 0, sync: .noUpstream(.available(onRemote: false))), .publish)
        await t.equal("체크한 파일 없음 + 추적 브랜치가 원격에 없음(같은 이름) → 브랜치 게시",
                      ChangesState.primary(includedCount: 0, sync: .upstreamGone(upstream: "origin/x", republish: true)),
                      .publish)
        await t.equal("origin 이 없으면 게시를 주 버튼으로 두지 않음",
                      ChangesState.primary(includedCount: 0, sync: .noUpstream(.noOrigin)), .none)
        await t.equal("원격과 같음 + 할 일 없음 → 주 버튼 없음",
                      ChangesState.primary(includedCount: 0, sync: .inSync(upstream: "origin/x")), .none)
        // 1단계에서는 원격 변경 도착을 주 버튼으로 두지 않았다 (.none). 2단계: 받기가 주 버튼.
        await t.equal("원격 변경 도착 · 체크한 파일 없음 → 받기가 주 버튼",
                      ChangesState.primary(includedCount: 0, sync: .behind(upstream: "origin/x", count: 1)), .pull)
        // 독립 작업 폴더의 대화 브랜치(ahc/…)는 올리지 않고 위 칸에서 합친다 — 브랜치 업로드를 주 버튼으로 권하지 않는다 (chg-2 · cap-3).
        await t.equal("독립 작업 폴더의 대화 브랜치: 브랜치 업로드를 주 버튼으로 두지 않음",
                      ChangesState.primary(includedCount: 0, sync: .noUpstream(.available(onRemote: false)), internalBranch: true),
                      .none)
        await t.equal("독립 작업 폴더라도 체크한 파일이 있으면 커밋이 주 버튼",
                      ChangesState.primary(includedCount: 1, sync: .noUpstream(.available(onRemote: false)), internalBranch: true),
                      .commit)
        await t.check("대화 브랜치: 요약 · 메타 줄이 '원격에 없음' 을 거듭 말하지 않는다 (cap-3)",
                      ChangesState.remoteSummary(.noUpstream(.available(onRemote: false)), hasChanges: false, internalBranch: true) == nil
                        && ChangesState.metaLine(.noUpstream(.available(onRemote: false)), lastFetchAt: nil, internalBranch: true)
                            == "이 대화의 브랜치 · 원격에 올리지 않음"
                        && ChangesState.remoteSummary(.ahead(upstream: "origin/ahc/1", count: 1), hasChanges: false,
                                                      internalBranch: true) == .toUpload(1))
        await t.check("대화 브랜치인지: 그 대화의 독립 작업 폴더에서 그 브랜치를 볼 때만",
                      ChangesState.isInternalBranch("ahc/1234abcd", worktreeBranch: "ahc/1234abcd")
                        && !ChangesState.isInternalBranch("feature/x", worktreeBranch: "ahc/1234abcd")
                        && !ChangesState.isInternalBranch("ahc/1234abcd", worktreeBranch: nil))

        // 잠금: 다른 프로젝트의 원격 명령 · 독립 작업 폴더 명령은 까닭을 보인다 (chg-9 · chg-10).
        let elsewhere = ChangesState.lock(agentRunning: false, agent: nil, agentHere: true, hasUnterminated: false,
                                          gitRunning: true, hasThread: true,
                                          gitElsewhere: ("moa-web", GitWrite.Operation.push(branch: "m", setUpstream: false).progressText))
        await t.equal("다른 프로젝트의 업로드 → 보이는 잠금", elsewhere, .gitRunningElsewhere(project: "moa-web", progress: "업로드하는 중입니다"))
        let elsewhereText: String = elsewhere.map { (lock: ChangesState.Lock) -> String in
            ChangesState.lockText(lock, action: "선택할")
        } ?? ""
        await t.check("다른 프로젝트의 업로드: 체크박스를 흐리게", ChangesState.blocksCheckbox(elsewhere)
                        && ChangesState.visibleLock(elsewhere) == elsewhere)
        await t.equal("다른 프로젝트의 업로드: 까닭", elsewhereText, "다른 프로젝트(moa-web)에서 업로드하는 중입니다. 끝나면 선택할 수 있습니다.")
        let setup = ChangesState.lock(agentRunning: false, agent: nil, agentHere: true, hasUnterminated: false,
                                      gitRunning: false, hasThread: true, worktreeCommand: "준비하는")
        let setupText: String = setup.map { (lock: ChangesState.Lock) -> String in
            ChangesState.lockText(lock, action: "커밋할")
        } ?? ""
        await t.check("독립 작업 폴더 명령 → 보이는 잠금", setup == .worktreeCommand("준비하는") && ChangesState.blocksCheckbox(setup))
        await t.equal("독립 작업 폴더 명령 → 까닭", setupText, "독립 작업 폴더를 준비하는 중입니다. 끝나면 커밋할 수 있습니다.")
        await t.check("같은 프로젝트의 짧은 git 명령은 여전히 숨김",
                      ChangesState.visibleLock(ChangesState.lock(agentRunning: false, agent: nil, agentHere: true,
                                                                 hasUnterminated: false, gitRunning: true, hasThread: true)) == nil)
        // 백그라운드 작업만 남은 실행 — 스스로 끝나지 않을 수 있다는 것과 출구 (chg-12).
        await t.check("백그라운드 작업 출구 문구: 있을 때만 · ⌘.",
                      ChangesState.backgroundExitNote(backgroundTasks: 0) == nil
                        && ChangesState.backgroundExitNote(backgroundTasks: 2)?.contains("⌘.") == true)

        // 실행 중 다시 읽기 (H8): 에이전트의 파일 변경 · 끝난 명령 · 파일을 바꿀 수 있는 도구 결과만.
        func event(_ kind: EventKind, title: String = "", run: String? = "r", provider: AgentProvider? = .claude,
                   payload: [String: Any]? = nil) -> ThreadEvent {
            ThreadEvent(threadID: "t", runID: run, kind: kind, provider: provider, title: title, text: "",
                        payloadJSON: payload.flatMap(JSONUtil.line))
        }
        await t.check("다시 읽기: 파일 변경 · 편집 도구 결과 · 끝난 명령",
                      ChangesState.refreshesGitDuringRun(event(.fileChange))
                        && ChangesState.refreshesGitDuringRun(event(.toolResult, title: "Edit"))
                        && ChangesState.refreshesGitDuringRun(event(.toolResult, title: "Bash — 오류"))
                        && ChangesState.refreshesGitDuringRun(event(.commandExecution, payload: ["status": "completed"])))
        await t.check("다시 읽지 않음: 읽기만 하는 도구 · 도는 명령 · 메시지 · 앱이 남긴 기록",
                      !ChangesState.refreshesGitDuringRun(event(.toolResult, title: "Read"))
                        && !ChangesState.refreshesGitDuringRun(event(.commandExecution, payload: ["status": "inProgress"]))
                        && !ChangesState.refreshesGitDuringRun(event(.agentMessage))
                        && !ChangesState.refreshesGitDuringRun(event(.commandExecution, run: nil, provider: nil,
                                                                     payload: ["status": "completed"])))

        // 충돌 표시 (chg-11): 줄 맨 앞의 <<<<<<< · >>>>>>> 만. 이진 · 못 읽음은 모름.
        let conflicted = "a\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> other\n".data(using: .utf8)
        let resolved = "a\nmine\ntheirs\n# ======= 제목 밑줄은 괜찮다\n=======\n".data(using: .utf8)
        await t.check("충돌 표시: 남음 · 없음 · 모름",
                      ChangesState.conflictMarkers(in: conflicted) == .present
                        && ChangesState.conflictMarkers(in: resolved) == .absent
                        && ChangesState.conflictMarkers(in: Data([0, 1, 2])) == .unknown
                        && ChangesState.conflictMarkers(in: nil) == .unknown)
        await t.equal("해결됨 표시는 표시가 없는 파일만 (git add)",
                      ChangesState.markResolvedOperation(["a.txt", "b.txt", "c.bin"],
                                                         markers: ["a.txt": .absent, "b.txt": .present, "c.bin": .unknown]),
                      .stage(["a.txt"]))
        await t.check("표시가 다 남았으면 명령 없음",
                      ChangesState.markResolvedOperation(["b.txt"], markers: ["b.txt": .present]) == nil)

        // 파일 탭에서 열기 (chg-5): 실행될 수 있는 파일은 Finder 에서 보인다.
        func opens(_ name: String, executable: Bool = false, app: String? = nil) -> Bool {
            FileOpenRule.action(FileOpenRule.Facts(name: name, targetName: name, executable: executable, defaultApp: app)) == .open
        }
        await t.check("열기: 문서는 기본 앱으로", opens("README.md") && opens("main.swift") && opens("run.sh")
                        && opens("photo.PNG", app: "Preview.app"))
        await t.check("열기: 실행될 수 있는 것은 Finder 에서",
                      !opens("setup.command") && !opens("Tool.app") && !opens("lib.jar") && !opens("install.pkg")
                        && !opens("build", executable: true) && !opens("run.sh", executable: true)
                        && !opens("script.py", app: "Python Launcher.app"))

        // 잠금 · 커밋 불가 이유 우선순위
        await t.check("잠금 우선순위: 에이전트 > 종료 미확인 > git 실행 중 > 스레드 없음",
                      ChangesState.lock(agentRunning: true, agent: .claude, agentHere: true, hasUnterminated: true,
                                        gitRunning: true, hasThread: false) == .agentRunning(.claude, here: true)
                      && ChangesState.lock(agentRunning: false, agent: nil, agentHere: false, hasUnterminated: true,
                                           gitRunning: true, hasThread: false) == .unterminatedProcesses
                      && ChangesState.lock(agentRunning: false, agent: nil, agentHere: false, hasUnterminated: false,
                                           gitRunning: true, hasThread: false) == .gitRunning
                      && ChangesState.lock(agentRunning: false, agent: nil, agentHere: false, hasUnterminated: false,
                                           gitRunning: false, hasThread: false) == .noThread)
        await t.check("다른 폴더에서 실행 중이어도 잠금 (사실대로 다른 폴더로 표시)",
                      ChangesState.lock(agentRunning: true, agent: .codex, agentHere: false, hasUnterminated: false,
                                        gitRunning: false, hasThread: true) == .agentRunning(.codex, here: false))
        await t.check("잠금 없음", ChangesState.lock(agentRunning: false, agent: nil, agentHere: false,
                                                  hasUnterminated: false, gitRunning: false, hasThread: true) == nil)
        await t.check("git 명령 실행 중은 화면에 잠금으로 드러내지 않음 (체크마다 독이 깜빡이지 않게)",
                      ChangesState.visibleLock(.gitRunning) == nil
                      && ChangesState.visibleLock(.unterminatedProcesses) == .unterminatedProcesses
                      && ChangesState.visibleLock(.agentRunning(.codex, here: false)) == .agentRunning(.codex, here: false)
                      && ChangesState.commitBlock(lock: ChangesState.visibleLock(.gitRunning), conflictCount: 0,
                                                  includedCount: 1, message: "m") == nil)
        let lock = ChangesState.Lock.agentRunning(.claude, here: true)
        await t.equal("커밋 불가: 잠금이 충돌보다 먼저",
                      ChangesState.commitBlock(lock: lock, conflictCount: 2, includedCount: 0, message: ""), .locked(lock))
        await t.equal("커밋 불가: 충돌이 선택 없음보다 먼저",
                      ChangesState.commitBlock(lock: nil, conflictCount: 2, includedCount: 0, message: ""), .conflicts(2))
        await t.equal("커밋 불가: 선택 없음이 메시지 없음보다 먼저",
                      ChangesState.commitBlock(lock: nil, conflictCount: 0, includedCount: 0, message: ""), .noSelection)
        await t.equal("커밋 불가: 공백 메시지",
                      ChangesState.commitBlock(lock: nil, conflictCount: 0, includedCount: 2, message: " \n"), .noMessage)
        await t.check("커밋 가능",
                      ChangesState.commitBlock(lock: nil, conflictCount: 0, includedCount: 2, message: "제목") == nil)

        // ⌘↵ — 입력창 · 커밋 · 인계 카드가 동시에 갖지 않는다 (B 설계 C1).
        var owners: [String] = []
        for commit in [false, true] {
            for cardFocused in [false, true] {
                owners.append("\(ChangesState.returnKeyOwner(commitFieldFocused: commit, cardFieldFocused: cardFocused))")
            }
        }
        await t.equal("⌘↵ 주인 (커밋 칸 × 카드 안 포커스)", owners, ["composer", "handoff", "commit", "commit"])
        await t.check("커밋 칸 포커스 중에는 입력창 · 카드가 ⌘↵ 를 갖지 않음",
                      ChangesState.returnKeyOwner(commitFieldFocused: true, cardFieldFocused: true) == .commit)
        await t.equal("입력창 포커스 → 입력창 (카드 안에 포커스가 있을 때만 카드)",
                      ChangesState.returnKeyOwner(commitFieldFocused: false, cardFieldFocused: false), .composer)
        // 카드를 아직 넘길 수 없어도(체크 전 · 카운트다운) 카드 안에 포커스가 있으면 카드가 갖는다 — [넘기기] 는 꺼진 채라
        // 아무것도 하지 않는다. 입력창에 주면 보이지 않는 입력창의 초안이 대기열에 걸렸다.
        var countdown = HandoffCard(draft: HandoffDraft(handoff: Handoff(threadID: "t", fromProvider: .claude, toProvider: .codex,
                                                                         baseSeq: 0, draftJSON: "{}", finalText: "x"),
                                                        packet: HandoffCardTests.packet(), text: "x", threadTitle: "t"),
                                    origin: .manual, automatic: true)
        countdown.phase = .countingDown(deadline: Date().addingTimeInterval(10), delay: 10)
        await t.check("카드 안 포커스 + 넘길 수 없는 카드(카운트다운) → 카드 (입력창으로 새지 않는다) · 단추는 꺼져 있다",
                      ChangesState.returnKeyOwner(commitFieldFocused: false, cardFieldFocused: true) == .handoff
                        && !countdown.sendableByHuman)

        // 문구 도우미
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await t.equal("상대 시각", [30, 180, 7_200, 3 * 86_400, -30].map {
            ChangesState.relativeTime(now.addingTimeInterval(TimeInterval(-$0)), now: now)
        }, ["방금", "3분 전", "2시간 전", "3일 전", "방금"])
        await t.equal("메타 줄: <upstream> 기준 · n분 전 확인",
                      ChangesState.metaLine(ahead, lastFetchAt: now.addingTimeInterval(-180), now: now),
                      "origin/x 기준 · 3분 전 확인")
        await t.equal("메타 줄: fetch 기록 없음", ChangesState.metaLine(ahead, lastFetchAt: nil, now: now),
                      "origin/x 기준 · 원격 확인 기록 없음")
        await t.equal("메타 줄: upstream 없으면 그 사실을 그대로",
                      ChangesState.metaLine(.noUpstream(.available(onRemote: false)), lastFetchAt: nil, now: now),
                      "추적하는 원격 브랜치 없음 · 원격 확인 기록 없음")
        await t.equal("메타 줄: 추적 브랜치가 원격에 없음 (원인을 쓰지 않음)",
                      ChangesState.metaLine(.upstreamGone(upstream: "origin/main", republish: true),
                                            lastFetchAt: nil, now: now),
                      "origin/main 원격에 없음 · 원격 확인 기록 없음")
        // 원격이 없다는 설명은 바닥 동기화 자리 한 곳에 — 요약 · 메타 줄은 짧게 (H19).
        await t.equal("메타 줄: 원격 없음은 짧게", ChangesState.metaLine(.noRemote, lastFetchAt: nil, now: now), "로컬 저장소")
        await t.check("요약: 원격 없음은 쓰지 않음 (바닥 한 곳에서 설명)",
                      ChangesState.remoteSummary(.noRemote, hasChanges: false) == nil
                        && ChangesState.remoteSummary(.noRemote, hasChanges: true) == nil)
        // 에이전트가 도는 동안의 안내는 메타 줄에 붙이지 않는다 — 브랜치 이름이 먼저 잘리지 않게 (cap-23).
        await t.equal("메타 줄: 원격 브랜치 이름이 앞(lead) · 안내 문구를 붙이지 않음",
                      ChangesState.metaParts(ahead, lastFetchAt: now.addingTimeInterval(-180), now: now).lead, "origin/x")
        let earlier = now.addingTimeInterval(-600)
        await t.check("마지막 fetch = 둘 중 늦은 시각",
                      ChangesState.latest(earlier, now) == now && ChangesState.latest(nil, earlier) == earlier
                      && ChangesState.latest(nil, nil) == nil)
        await t.equal("커밋 실패 이유: git 의 error 줄",
                      ChangesState.commitFailureSummary("error: gpg failed to sign the data\nfatal: failed to write commit object"),
                      "error: gpg failed to sign the data")
        // 2단계: 커밋 실패 이유도 `GitFailure` 한 곳에서 분류한다 (문구는 2단계 판단 표를 따름).
        await t.equal("커밋 실패 이유: 스테이지된 변경 없음",
                      ChangesState.commitFailureSummary("On branch main\nnothing to commit, working tree clean"),
                      "커밋할 변경이 없습니다. 이미 커밋됐거나 선택이 바뀌었을 수 있습니다.")
        await t.equal("커밋 실패 이유: 한국어 git (macOS 언어 설정) 의 '커밋할 사항 없음'",
                      ChangesState.commitFailureSummary("현재 브랜치 main\n커밋할 사항 없음, 작업 폴더 깨끗함"),
                      "커밋할 변경이 없습니다. 이미 커밋됐거나 선택이 바뀌었을 수 있습니다.")
        await t.equal("커밋 실패 이유: 훅 출력은 마지막 줄을 원문 그대로 (원인을 지어내지 않음)",
                      ChangesState.commitFailureSummary("Running checks...\nlint: 경고 2개\n"), "lint: 경고 2개")
        await t.equal("커밋 실패 이유: 출력 없음", ChangesState.commitFailureSummary(" \n"),
                      "git 이 실패로 끝났습니다. 출력이 없습니다.")
        let head = GitCommitSummary(hash: "abc", shortHash: "abc", subject: "s", date: nil)
        await t.check("커밋 완료는 앱이 만든 커밋이 HEAD 인 동안만",
                      ChangesState.isJustCommitted(appCommitHash: "abc", head: head)
                      && !ChangesState.isJustCommitted(appCommitHash: "old", head: head)
                      && !ChangesState.isJustCommitted(appCommitHash: nil, head: head))

        // PR 은 캐시에 열린 PR 이 있고 head 가 같을 때만
        let pr = PullRequestInfo(number: 128, title: "t", state: "OPEN", isDraft: false, url: "", headRefName: "feature/login",
                                 baseRefName: "main", additions: nil, deletions: nil, changedFiles: nil, createdAt: nil,
                                 reviewDecision: nil, checks: [], reviews: [])
        var closed = pr
        closed.state = "MERGED"
        await t.check("업로드가 반영될 PR",
                      ChangesState.pullRequestReceivingPush(pr, branch: "feature/login", upstream: "origin/feature/login") == 128
                      && ChangesState.pullRequestReceivingPush(pr, branch: "feature/login", upstream: "origin/other") == nil
                      && ChangesState.pullRequestReceivingPush(closed, branch: "feature/login", upstream: "origin/feature/login") == nil
                      && ChangesState.pullRequestReceivingPush(nil, branch: "feature/login", upstream: "origin/feature/login") == nil
                      && ChangesState.pullRequestReceivingPush(pr, branch: "feature/login", upstream: nil) == nil)

        // 새 조회 해석
        await t.check("git log -1 해석",
                      GitWorkspace.parseLastCommit("0123abcd\u{0}0123abc\u{0}로그인 정리\u{0}1800000000\n")
                          == GitCommitSummary(hash: "0123abcd", shortHash: "0123abc", subject: "로그인 정리",
                                              date: Date(timeIntervalSince1970: 1_800_000_000)))
        await t.check("git log 빈 출력은 nil", GitWorkspace.parseLastCommit("") == nil)
        await t.equal("git remote 해석", GitWorkspace.parseRemotes("origin\nfork\n\n"), ["origin", "fork"])
        await t.equal("--git-path 상대 경로는 실행 폴더 기준",
                      GitWorkspace.resolveGitPath("../.git/FETCH_HEAD\n", relativeTo: URL(fileURLWithPath: "/r/app/ios")),
                      "/r/app/.git/FETCH_HEAD")
        await t.equal("FETCH_HEAD 후보: 이 작업 트리 + 공통 폴더",
                      GitWorkspace.fetchHeadCandidates("/r/.git/worktrees/wt/FETCH_HEAD\n/r/.git\n",
                                                       relativeTo: URL(fileURLWithPath: "/w")),
                      ["/r/.git/worktrees/wt/FETCH_HEAD", "/r/.git/FETCH_HEAD"])
        await t.equal("FETCH_HEAD 후보: 주 작업 트리는 하나", GitWorkspace.fetchHeadCandidates(
            "/r/.git/FETCH_HEAD\n/r/.git\n", relativeTo: URL(fileURLWithPath: "/r")), ["/r/.git/FETCH_HEAD"])
        var fresh = GitWorkspaceStatus()
        GitWorkspace.parseBranchHeader("No commits yet on main", into: &fresh)
        await t.check("첫 커밋 전 표시", fresh.noCommitsYet && fresh.branch == "main" && fresh.upstream == nil)
        var emptyClone = GitWorkspaceStatus()
        GitWorkspace.parseBranchHeader("No commits yet on main...origin/main [gone]", into: &emptyClone)
        await t.check("빈 저장소 clone 머리줄: 브랜치 이름에 추적 정보가 섞이지 않음",
                      emptyClone.branch == "main" && emptyClone.upstream == "origin/main" && emptyClone.upstreamGone
                      && emptyClone.noCommitsYet, "\(emptyClone)")
        var afterFirst = GitWorkspaceStatus()
        GitWorkspace.parseBranchHeader("main...origin/main [gone]", into: &afterFirst)
        afterFirst.remotes = ["origin"]
        await t.equal("빈 저장소 clone 후 첫 커밋 → 게시로 origin/main 을 만들 수 있음",
                      ChangesState.sync(afterFirst), .upstreamGone(upstream: "origin/main", republish: true))
        await t.check("'저장소 아님' 은 git 이 그렇게 말할 때만 (영어 · 한국어)",
                      GitWorkspace.isNotRepositoryMessage("fatal: not a git repository (or any of the parent directories): .git")
                      && GitWorkspace.isNotRepositoryMessage("fatal: (현재 폴더 또는 상위 폴더 중 일부가) 깃 저장소가 아닙니다: .git")
                      && !GitWorkspace.isNotRepositoryMessage("fatal: detected dubious ownership in repository at '/x'")
                      && !GitWorkspace.isNotRepositoryMessage("시간 초과(15초)"))
        await t.check("push.default: 기본값 · simple · upstream 만 확인 창의 대상 한 곳으로",
                      GitWorkspace.pushGoesToUpstreamOnly(nil) && GitWorkspace.pushGoesToUpstreamOnly("simple")
                      && GitWorkspace.pushGoesToUpstreamOnly("upstream")
                      && !GitWorkspace.pushGoesToUpstreamOnly("current") && !GitWorkspace.pushGoesToUpstreamOnly("matching"))

        // 인스펙터 탭 — 옛 값 "branch" 는 변경사항으로
        await t.equal("옛 탭 값 'branch' → 변경사항", InspectorTab(rawValue: "branch"), .changes)
        await t.equal("변경사항 탭 값", InspectorTab.changes.rawValue, "changes")
        await t.check("변경사항 탭 제목 · ⌘⌥4 유지",
                      InspectorTab.changes.title == "변경사항" && InspectorTab.changes.shortcut == "4"
                      && InspectorTab.allCases.map(\.rawValue) == ["terminal", "files", "pullRequest", "changes", "agents"])
        await t.check("에이전트 탭: 제목 · ⌘⌥5 · 저장값 'agents' 로 되살림",
                      InspectorTab.agents.title == "에이전트" && InspectorTab.agents.shortcut == "5"
                      && InspectorTab(rawValue: "agents") == .agents)
        await t.check("모르는 탭 값은 nil (기본 탭으로)", InspectorTab(rawValue: "branches") == nil)
    }

    /// 변경사항 탭이 쓰는 읽기 전용 조회를 임시 저장소로 확인 (HEAD 대비 줄 수 · 마지막 커밋 · 원격 · FETCH_HEAD).
    static func changesLiveQuery(_ t: TestKit) async {
        await t.group("변경사항 탭 조회")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ahc-changes-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        let origin = root.appendingPathComponent("origin.git")
        let fresh = root.appendingPathComponent("fresh")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        try? fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        guard let git = GitInspector.findGit(environment: env) else {
            await t.check("git 실행 파일", false, "찾지 못함")
            return
        }
        func sh(_ args: [String], in dir: URL) async {
            _ = await CLIEnvironment.captureOutput(
                executable: git, arguments: ["-c", "user.name=t", "-c", "user.email=t@example.com",
                                             "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args,
                environment: env, workingDirectory: dir, timeout: 20)
        }
        func write(_ text: String, _ name: String, in dir: URL = work) {
            try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        await sh(["init", "-q", "-b", "main"], in: work)
        write("a\nb\nc\n", "both.txt")
        write("x\ny\n", "gone.txt")
        await sh(["add", "-A"], in: work)
        await sh(["commit", "-q", "-m", "기준 커밋"], in: work)
        // 원격 없음 · FETCH_HEAD 없음
        var status = await GitWorkspace.status(at: work, environment: env)
        await t.equal("원격 없음", status.remotes, [])
        await t.check("fetch 한 적 없으면 FETCH_HEAD 시각 없음", status.fetchHeadModifiedAt == nil)
        await t.equal("마지막 커밋 제목", status.lastCommit?.subject, "기준 커밋")
        await t.check("마지막 커밋 해시 · 시각", (status.lastCommit?.shortHash.count ?? 0) >= 7
                      && status.lastCommit?.date != nil)

        // 원격 연결 + fetch
        await sh(["init", "--bare", "-q", "-b", "main", origin.path], in: root)
        await sh(["remote", "add", "origin", origin.path], in: work)
        await sh(["push", "-q", "-u", "origin", "main"], in: work)
        await sh(["fetch", "-q", "origin"], in: work)

        // 스테이지 + 작업 트리 양쪽 (MM), 추가 후 수정 (AM), 삭제, 새 파일
        write("a\nB\nc\n", "both.txt")
        await sh(["add", "both.txt"], in: work)
        write("a\nB\nc\nd\n", "both.txt")
        write("n1\n", "added.txt")
        await sh(["add", "added.txt"], in: work)
        write("n1\nn2\n", "added.txt")
        try? fm.removeItem(at: work.appendingPathComponent("gone.txt"))
        write("u1\nu2\nu3\n", "new.txt")

        status = await GitWorkspace.status(at: work, environment: env)
        await t.equal("원격 이름", status.remotes, ["origin"])
        await t.check("fetch 뒤 FETCH_HEAD 수정 시각", status.fetchHeadModifiedAt != nil)
        let rows = ChangesState.rows(from: status)
        let both = rows.first { $0.path == "both.txt" }
        await t.check("MM 은 일부 포함 · 줄 수는 마지막 커밋 대비 파일 전체 (+2 −1)",
                      both?.inclusion == .mixed && both?.code == "M" && both?.added == 2 && both?.removed == 1,
                      "\(String(describing: both))")
        let added = rows.first { $0.path == "added.txt" }
        await t.check("AM 은 A · 일부 포함 · +2", added?.code == "A" && added?.inclusion == .mixed && added?.added == 2,
                      "\(String(describing: added))")
        let gone = rows.first { $0.path == "gone.txt" }
        await t.check("작업 트리 삭제는 D · 포함 안 됨 · −2",
                      gone?.code == "D" && gone?.inclusion == .off && gone?.removed == 2, "\(String(describing: gone))")
        let new = rows.first { $0.path == "new.txt" }
        await t.check("새 파일은 A · 포함 안 됨 · +3", new?.code == "A" && new?.inclusion == .off && new?.added == 3)

        // 첫 커밋 전 저장소: HEAD 가 없어 줄 수를 모름 ("—")
        await sh(["init", "-q", "-b", "main"], in: fresh)
        write("hello\n", "first.txt", in: fresh)
        await sh(["add", "first.txt"], in: fresh)
        let freshStatus = await GitWorkspace.status(at: fresh, environment: env)
        let first = ChangesState.rows(from: freshStatus).first
        await t.check("첫 커밋 전: 마지막 커밋 없음 · 줄 수 nil",
                      freshStatus.noCommitsYet && freshStatus.lastCommit == nil
                      && first?.inclusion == .on && first?.added == nil && first?.removed == nil,
                      "\(String(describing: first))")
        await t.equal("첫 커밋 전: 게시할 것 없음 (원격도 없음)", ChangesState.sync(freshStatus), .noRemote)

        // 추적 중지 (`git rm --cached`): 커밋하면 저장소에서 빠진다 → D · 포함됨
        await sh(["rm", "-q", "-f", "--cached", "both.txt"], in: work)
        let untracked = ChangesState.rows(from: await GitWorkspace.status(at: work, environment: env))
            .first { $0.path == "both.txt" }
        await t.check("git rm --cached 는 D · 포함됨 (M · 일부 포함으로 보이지 않음)",
                      untracked?.code == "D" && untracked?.inclusion == .on, "\(String(describing: untracked))")

        // 원격에 닿지 못한 fetch 는 FETCH_HEAD 를 비운다 → "방금 확인" 으로 쓰지 않는다
        await sh(["remote", "set-url", "origin", root.appendingPathComponent("없는-원격.git").path], in: work)
        await sh(["fetch", "-q", "--prune"], in: work)
        status = await GitWorkspace.status(at: work, environment: env)
        await t.check("실패한 fetch 뒤에는 FETCH_HEAD 시각을 쓰지 않음", status.fetchHeadModifiedAt == nil,
                      "\(String(describing: status.fetchHeadModifiedAt))")

        // 저장소를 읽지 못한 것(소유자 검사)은 "저장소 아님" 이 아니다
        var dubiousEnv = env
        dubiousEnv["GIT_TEST_ASSUME_DIFFERENT_OWNER"] = "1"
        // 전역 · 시스템 설정에 safe.directory = * 가 있으면 소유자 검사가 꺼진다 (GitHub 의 macOS 러너 이미지가 그렇다).
        dubiousEnv["GIT_CONFIG_GLOBAL"] = "/dev/null"
        dubiousEnv["GIT_CONFIG_NOSYSTEM"] = "1"
        let dubious = await GitWorkspace.status(at: work, environment: dubiousEnv)
        await t.check("읽지 못한 저장소는 오류로 (저장소 아님 · git init 안내로 단정하지 않음)",
                      !dubious.isRepository && dubious.error?.contains("dubious ownership") == true,
                      dubious.error ?? "오류 없음")

        // 빈 원격을 clone: 첫 커밋 전에도 추적 정보가 브랜치 이름에 섞이지 않는다
        let emptyOrigin = root.appendingPathComponent("empty.git")
        let emptyClone = root.appendingPathComponent("empty-clone")
        await sh(["init", "--bare", "-q", "-b", "main", emptyOrigin.path], in: root)
        await sh(["clone", "-q", emptyOrigin.path, emptyClone.path], in: root)
        var cloned = await GitWorkspace.status(at: emptyClone, environment: env)
        await t.check("빈 저장소 clone: 브랜치 main · 추적 origin/main 이 원격에 없음 · 올릴 것 없음",
                      cloned.branch == "main"
                      && ChangesState.sync(cloned) == .upstreamGone(upstream: "origin/main", republish: false),
                      "\(String(describing: cloned.branch)) \(ChangesState.sync(cloned))")
        write("first\n", "first.txt", in: emptyClone)
        await sh(["add", "first.txt"], in: emptyClone)
        await sh(["commit", "-q", "-m", "첫 커밋"], in: emptyClone)
        cloned = await GitWorkspace.status(at: emptyClone, environment: env)
        await t.equal("빈 저장소 clone 후 첫 커밋 → 게시 제안", ChangesState.sync(cloned),
                      .upstreamGone(upstream: "origin/main", republish: true))
    }
}

// MARK: - 변경사항 탭 2단계 (읽기 조회 · 원격 도착 / 기록 분기 / 병합 중 · 실패 분류)

extension WorkspaceTests {
    /// 새 읽기 조회의 해석: 커밋 목록 · MERGE_MSG · 브랜치 메타 · 원격 이름 · 원격 주소 host.
    static func stage2Parsing(_ t: TestKit) async {
        await t.group("커밋 목록 · 병합 · 브랜치 해석")

        let log = GitWorkspace.parseLog("e7d21c0\0토큰 만료 시 재시도 간격 조정\0minji\u{0}25분 전\n"
                                        + "b3a9f14\0로그인 버튼 비활성 조건 수정\0minji\u{0}40분 전\n"
                                        + "5c0e8aa\0AuthTransport 테스트 더블 추가\0sora\u{0}1 hour ago\n")
        await t.equal("커밋 목록 수", log.count, 3)
        await t.check("해시 · 제목 · 작성자 · 상대 시각 (한국어 로케일 글자 그대로)",
                      log.first == GitLogEntry(shortHash: "e7d21c0", subject: "토큰 만료 시 재시도 간격 조정",
                                               author: "minji", relativeDate: "25분 전"), "\(String(describing: log.first))")
        await t.equal("영어 로케일 상대 시각도 해석하지 않고 그대로", log.last?.relativeDate, "1 hour ago")
        await t.equal("작성자 머리글자 (목업의 M · S)", log.map(\.authorInitial), ["M", "M", "S"])
        await t.equal("한글 이름 머리글자",
                      GitLogEntry(shortHash: "a", subject: "s", author: "한가람", relativeDate: "").authorInitial, "한")
        await t.equal("작성자가 비면 머리글자도 비움 (지어내지 않음)",
                      GitLogEntry(shortHash: "a", subject: "s", author: " ", relativeDate: "").authorInitial, "")
        await t.check("빈 출력 · 칸이 모자란 줄 · 해시 없는 줄은 건너뜀",
                      GitWorkspace.parseLog("").isEmpty && GitWorkspace.parseLog("abc\0제목만\n\0\0\0\n").isEmpty)
        await t.equal("제목의 | · : 는 그대로", GitWorkspace.parseLog("a1\0fix: a | b\0n\0방금\n").first?.subject, "fix: a | b")
        await t.equal("조회 인수: 서명 표시 · 색 끔 · 최대 50개 · 범위 (%ar 뒤에 커밋 시각 %ct)",
                      GitWorkspace.logArguments(range: "HEAD..@{u}"),
                      ["log", "--no-show-signature", "--no-color", "--format=%h%x00%s%x00%an%x00%ar%x00%ct", "-n", "50",
                       "HEAD..@{u}", "--"])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let timed = GitWorkspace.parseLog("e7d21c0\0제목\0minji\u{0}25 minutes ago\u{0}\(1_800_000_000 - 1_500)\n")
        await t.check("커밋 시각(%ct)이 있으면 담음 (%ar 은 영어여도 그대로 보관)",
                      timed.first?.committedAt == now.addingTimeInterval(-1_500)
                      && timed.first?.relativeDate == "25 minutes ago")
        await t.equal("화면 시각: git 이 준 시각을 앱의 말로 (앱의 git 은 %ar 을 영어로 쓴다)",
                      ChangesState.commitTime(timed.first?.committedAt, fallback: timed.first?.relativeDate, now: now),
                      "25분 전")
        await t.equal("화면 시각: 시각이 없으면 git 의 글자 그대로",
                      ChangesState.commitTime(nil, fallback: "25분 전", now: now), "25분 전")
        await t.check("화면 시각: 둘 다 없으면 쓰지 않음", ChangesState.commitTime(nil, fallback: "", now: now) == nil)
        await t.equal("50개로 잘렸으면 '외 n개' (전체 수는 뒤처짐 수)", ChangesState.moreCount(listed: 50, total: 62), 12)
        await t.check("다 읽었거나 전체 수를 모르면 '외 n개' 없음",
                      ChangesState.moreCount(listed: 3, total: 3) == nil && ChangesState.moreCount(listed: 3, total: nil) == nil)

        // MERGE_MSG — `git commit -F -` 는 주석 줄을 지우지 않으므로 앱이 뺀다.
        let raw = "Merge remote-tracking branch 'origin/feature/login' into feature/login\n\n# Conflicts:\n"
            + "#\tMoa/Auth/AuthViewModel.swift\n"
        await t.equal("MERGE_MSG: '# Conflicts:' 목록을 뺀 제목만",
                      GitWorkspace.mergeMessageDraft(raw),
                      "Merge remote-tracking branch 'origin/feature/login' into feature/login")
        await t.equal("MERGE_MSG: 본문 유지 · 줄 끝 공백 · 겹친 빈 줄 정리 · 들여쓴 # 는 본문",
                      GitWorkspace.mergeMessageDraft("제목  \n\n\n본문 1\n# 주석\n  # 들여쓴 줄\n\n"),
                      "제목\n\n본문 1\n  # 들여쓴 줄")
        await t.check("MERGE_MSG: 주석뿐이면 초안 없음", GitWorkspace.mergeMessageDraft("# Conflicts:\n#\ta.txt\n\n") == nil)
        await t.equal("MERGE_MSG: CRLF", GitWorkspace.mergeMessageDraft("Merge x\r\n# c\r\n"), "Merge x")
        await t.equal("MERGE_MSG: 사용자 주석 문자(core.commentChar=;)",
                      GitWorkspace.mergeMessageDraft("Merge x\n; Conflicts:\n;\ta\n# 이건 본문\n", commentPrefix: ";"),
                      "Merge x\n# 이건 본문")
        await t.equal("core.commentChar 설정 해석", GitWorkspace.commentPrefix(fromConfig: "core.commentchar ;\n"), ";")
        await t.check("core.commentChar 가 auto 거나 없으면 # (git 은 MERGE_MSG 를 # 으로 쓴다)",
                      GitWorkspace.commentPrefix(fromConfig: "core.commentchar auto\n") == "#"
                      && GitWorkspace.commentPrefix(fromConfig: "") == "#")

        // 브랜치 메타 — 상대 시각은 git 이 준 글자 그대로.
        let local = GitWorkspace.parseBranches(
            "feature/login\0c6bac5a\0*\0origin/feature/login\0[ahead 2, behind 3]\u{0}26분 전\n"
                + "main\u{0}7057838\0 \0origin/main\0\u{0}3일 전\nfeature/sso\0aaa1111\0 \0\0\u{0}2 days ago\n")
        await t.equal("로컬 브랜치 마지막 커밋 상대 시각", local.map { $0.committerDate ?? "-" },
                      ["26분 전", "3일 전", "2 days ago"])
        await t.check("상대 시각 칸이 없던 옛 형식도 읽음 (nil)",
                      GitWorkspace.parseBranches("main\0abc\0*\0\0\n").first.map { $0.committerDate == nil } == true)
        await t.check("브랜치 마지막 커밋 시각(unix)",
                      GitWorkspace.parseBranches("main\0abc\0*\0\0\u{0}3 days ago\u{0}1800000000\n").first?.committedAt
                          == Date(timeIntervalSince1970: 1_800_000_000)
                      && GitWorkspace.parseRemoteBranches("refs/remotes/origin/x\0abc\u{0}3 days ago\u{0}1800000000\n",
                                                          remotes: ["origin"]).first?.committedAt
                          == Date(timeIntervalSince1970: 1_800_000_000))
        let remote = GitWorkspace.parseRemoteBranches(
            "refs/remotes/origin/HEAD\0abc\0방금\nrefs/remotes/origin/feature/login\u{0}160bc24\u{0}39분 전\n"
                + "refs/remotes/origin/main\u{0}7057838\u{0}3일 전\nrefs/remotes/origin/feature/sso\0bbb\u{0}1일 전\n"
                + "refs/remotes/origin/release/2.0\0ccc\u{0}5일 전\nrefs/remotes/team/a/hotfix\0ddd\u{0}1주 전\n",
            remotes: ["origin", "team/a"])
        await t.equal("원격 브랜치 (원격 HEAD 제외, 순서 그대로)", remote.map(\.fullName),
                      ["origin/feature/login", "origin/main", "origin/feature/sso", "origin/release/2.0", "team/a/hotfix"])
        await t.check("원격 · 브랜치 이름을 나눔 (원격 이름에 / 가 있어도)",
                      remote.first?.remote == "origin" && remote.first?.name == "feature/login"
                      && remote.last?.remote == "team/a" && remote.last?.name == "hotfix")
        await t.equal("원격 브랜치 상대 시각", remote.first?.committerDate, "39분 전")
        await t.equal("원격에만 있는 브랜치 = 원격 − 로컬 upstream − 같은 이름 로컬 브랜치",
                      ChangesState.remoteOnlyBranches(remote, local: local).map(\.fullName),
                      ["origin/release/2.0", "team/a/hotfix"])
        await t.check("원격 목록을 모르면 첫 / 에서 나눔",
                      GitWorkspace.splitRemoteRef("origin/a/b", remotes: nil).map { $0.remote == "origin" && $0.name == "a/b" }
                          == true)

        // 원격 이름 · 주소 host (로그인 실패 문구에서 GitHub 인지 가릴 때만)
        await t.equal("게시는 origin 으로",
                      GitWorkspace.remoteName(for: .push(branch: "x", setUpstream: true), upstream: "fork/x",
                                              remotes: ["origin", "fork"]), "origin")
        await t.equal("업로드 · 받기 · 확인은 추적 브랜치의 원격",
                      GitWorkspace.remoteName(for: .pull, upstream: "fork/feature/x", remotes: ["origin", "fork"]), "fork")
        await t.equal("추적 없음 → git 기본값 origin",
                      GitWorkspace.remoteName(for: .fetch, upstream: nil, remotes: ["origin"]), "origin")
        await t.check("원격을 쓰지 않는 명령은 원격 없음",
                      GitWorkspace.remoteName(for: .commit(message: "m"), upstream: "origin/x", remotes: ["origin"]) == nil)
        await t.equal("원격 주소 host: https · scp · ssh(포트) · 토큰@ · ssh 별칭 · 로컬 경로",
                      ["https://github.com/o/r.git", "git@github.com:o/r.git", "ssh://git@github.com:22/o/r",
                       "https://tok@GitHub.com/o/r", "github-work:o/r.git", "/tmp/o.git", "./o.git", "file:///tmp/o.git"]
                        .map { GitWorkspace.host(ofRemoteURL: $0) ?? "-" },
                      ["github.com", "github.com", "github.com", "github.com", "github-work", "-", "-", "-"])
    }

    /// 상태 판정 확장: 원격 변경 도착 · 기록 분기 · 병합 중(충돌 남음 / 모두 풀림) · 병합 메시지 초안.
    static func stage2Decisions(_ t: TestKit) async {
        await t.group("원격 도착 · 기록 분기 · 병합 판정")

        // 병합 중: git 은 병합 전 기준 ahead 1 · behind 1 을 적는다 — "기록이 갈라짐" 으로 보이면 안 된다.
        var merging = GitWorkspaceStatus()
        GitWorkspace.parseStatus("## feature/login...origin/feature/login [ahead 1, behind 1]\0"
                                 + "UU Moa/Auth/AuthViewModel.swift\0M  Moa/Login/LoginView.swift\0"
                                 + "A  MoaTests/AuthTransportMock.swift\0", into: &merging)
        merging.remotes = ["origin"]
        merging.mergeHead = "15a30c71277720b90a0ed9b33764d92587551b52"
        await t.equal("병합 중은 앞섬/뒤처짐보다 먼저 (기록 분기로 보이지 않음)", ChangesState.sync(merging),
                      .merging(upstream: "origin/feature/login"))
        var notMerging = merging
        notMerging.mergeHead = nil
        await t.equal("MERGE_HEAD 가 없으면 같은 머리줄은 기록 분기", ChangesState.sync(notMerging),
                      .diverged(upstream: "origin/feature/login", ahead: 1, behind: 1))
        let mergeSync = ChangesState.Sync.merging(upstream: "origin/feature/login")
        await t.check("병합 중: 요약에 원격 항목 없음 · 게시 없음 · 추적 브랜치는 그대로",
                      ChangesState.remoteSummary(mergeSync, hasChanges: true) == nil && !ChangesState.canPublish(mergeSync)
                      && mergeSync.upstream == "origin/feature/login")
        await t.equal("병합 중 메타 줄 (무엇을 합치는지 짐작하지 않음)",
                      ChangesState.metaLine(mergeSync, lastFetchAt: nil), "병합 진행 중 · 추적 origin/feature/login")
        await t.equal("병합 중 · 추적 없음", ChangesState.metaLine(.merging(upstream: nil), lastFetchAt: nil), "병합 진행 중")
        let rows = ChangesState.rows(from: merging)
        await t.check("충돌 행: 체크 불가 · 명령 없음 · 맨 앞",
                      rows.first?.inclusion == .conflict && rows.first?.isCheckable == false
                      && rows.first.map { ChangesState.toggleOperation(for: $0) } == .some(nil))
        await t.check("전체 선택은 충돌 행을 넣지 않음",
                      ChangesState.selectAllOperation(rows) == nil
                      && ChangesState.deselectAllOperation(rows)
                          == .unstage(["Moa/Login/LoginView.swift", "MoaTests/AuthTransportMock.swift"]))
        // 병합 중 인덱스의 것은 합쳐진 결과 — 빼고 커밋하면 병합 커밋이 그 변경 없이 기록된다 (실제로 확인한 문제).
        let staged = rows.first { $0.path == "Moa/Login/LoginView.swift" }
        await t.check("병합 중에는 포함된 행을 커밋에서 빼지 않음 (넣기는 됨)",
                      staged.map { ChangesState.toggleOperation(for: $0, merging: true) == nil } == true
                      && staged.map { ChangesState.toggleOperation(for: $0) == .unstage(["Moa/Login/LoginView.swift"]) } == true
                      && ChangesState.toggleOperation(for: ChangesState.Row(path: "x", code: "M", inclusion: .mixed),
                                                      merging: true) == .stage(["x"]))
        await t.check("병합 중 머리 체크박스는 빼기를 하지 않음 (넣을 것이 없으면 아무 명령 없음)",
                      ChangesState.headerToggleOperation(rows, merging: true) == nil
                      && ChangesState.headerToggleOperation(rows.filter { $0.inclusion == .on }, merging: true) == nil
                      && ChangesState.headerToggleOperation(rows.filter { $0.inclusion == .on }) != nil)
        await t.equal("병합 중 주 버튼은 커밋 (충돌이 남으면 비활성 모양)",
                      ChangesState.primary(includedCount: 0, sync: mergeSync), .commit)
        await t.equal("충돌이 남아 있으면 커밋 불가 (이 메시지로는 해결 뒤에)",
                      ChangesState.commitBlock(lock: nil, conflictCount: 1, includedCount: 2, message: "Merge", merging: true),
                      .conflicts(1))
        await t.check("충돌이 모두 풀린 병합은 선택이 없어도 커밋 가능 (병합 커밋이 병합을 마무리)",
                      ChangesState.commitBlock(lock: nil, conflictCount: 0, includedCount: 0, message: "Merge",
                                               merging: true) == nil)
        await t.equal("병합이 아니면 선택 없음은 그대로 막음",
                      ChangesState.commitBlock(lock: nil, conflictCount: 0, includedCount: 0, message: "m"), .noSelection)
        await t.equal("병합 중에도 메시지는 필요",
                      ChangesState.commitBlock(lock: nil, conflictCount: 0, includedCount: 2, message: " ", merging: true),
                      .noMessage)

        // 주 버튼 — 한 화면에 잉크 하나
        let diverged = ChangesState.Sync.diverged(upstream: "origin/x", ahead: 2, behind: 3)
        let behind = ChangesState.Sync.behind(upstream: "origin/x", count: 3)
        await t.equal("기록 분기 · 체크한 파일 없음 → 터미널에서 합치기 (업로드 · 받기 없음)",
                      ChangesState.primary(includedCount: 0, sync: diverged), .mergeInTerminal)
        await t.equal("기록 분기 · 체크한 파일 → 커밋 (합치기는 흰 칩)",
                      ChangesState.primary(includedCount: 2, sync: diverged), .commit)
        await t.equal("원격 변경 도착 · 체크한 파일 → 커밋 (받기는 흰 칩)",
                      ChangesState.primary(includedCount: 1, sync: behind), .commit)
        await t.equal("요약: 기록이 갈라짐", ChangesState.remoteSummary(diverged, hasChanges: false), .diverged)
        await t.equal("요약: 원격에 새 커밋 n개", ChangesState.remoteSummary(behind, hasChanges: false), .incoming(3))

        // 커밋 목록 섹션
        await t.equal("원격 변경 도착: 원격에서 온 커밋", ChangesState.commitSections(behind),
                      [.incoming(count: 3, diverged: false)])
        await t.equal("기록 분기: 이 브랜치에만 있는 커밋 · 원격에만 있는 커밋", ChangesState.commitSections(diverged),
                      [.outgoing(count: 2), .incoming(count: 3, diverged: true)])
        await t.check("그 밖에는 커밋 목록 섹션 없음",
                      ChangesState.commitSections(.ahead(upstream: "o/x", count: 2)).isEmpty
                      && ChangesState.commitSections(mergeSync).isEmpty
                      && ChangesState.commitSections(.inSync(upstream: "o/x")).isEmpty
                      && ChangesState.commitSections(.noUpstream(.available(onRemote: false))).isEmpty)

        // 병합 메시지 초안 — 초안이 비어 있을 때만, 한 병합에 한 번
        let adoption = ChangesState.MergeDraftAdoption(mergeHead: "m1", message: "Merge x")
        await t.equal("빈 초안 + 병합 시작 → MERGE_MSG 로 채움",
                      ChangesState.mergeDraftAction(draft: "", mergeHead: "m1", mergeMessage: "Merge x", adopted: nil),
                      .fill("Merge x"))
        await t.equal("사용자가 쓴 초안은 덮지 않음",
                      ChangesState.mergeDraftAction(draft: "내 메시지", mergeHead: "m1", mergeMessage: "Merge x",
                                                    adopted: nil), .none)
        await t.equal("같은 병합에서 채운 뒤 사용자가 지웠으면 다시 채우지 않음",
                      ChangesState.mergeDraftAction(draft: "", mergeHead: "m1", mergeMessage: "Merge x",
                                                    adopted: adoption), .none)
        await t.equal("병합이 끝났고 초안이 채운 글자 그대로 → 비움 (다음 커밋에 남지 않게)",
                      ChangesState.mergeDraftAction(draft: "Merge x", mergeHead: nil, mergeMessage: nil,
                                                    adopted: adoption), .clear)
        await t.equal("병합이 끝나도 사용자가 고친 초안은 그대로",
                      ChangesState.mergeDraftAction(draft: "Merge x — 정리", mergeHead: nil, mergeMessage: nil,
                                                    adopted: adoption), .none)
        await t.equal("다른 병합이 시작됐고 초안이 지난 메시지 그대로 → 먼저 비움",
                      ChangesState.mergeDraftAction(draft: "Merge x", mergeHead: "m2", mergeMessage: "Merge y",
                                                    adopted: adoption), .clear)
        await t.equal("MERGE_MSG 를 못 읽으면 채우지 않음",
                      ChangesState.mergeDraftAction(draft: "", mergeHead: "m1", mergeMessage: nil, adopted: nil), .none)
        await t.equal("병합이 아니고 기록도 없으면 할 일 없음",
                      ChangesState.mergeDraftAction(draft: "", mergeHead: nil, mergeMessage: nil, adopted: nil), .none)

        // rebase 진행 중 — HEAD 가 떼어져 있지만 "브랜치를 만드세요" 가 아니라 터미널에서 이어가기
        var rebasing = GitWorkspaceStatus()
        GitWorkspace.parseStatus("## HEAD (no branch)\0UU a.txt\0", into: &rebasing)
        rebasing.remotes = ["origin"]
        rebasing.isRebasing = true
        await t.equal("rebase 중 판정 (떼어진 HEAD 보다 먼저)", ChangesState.sync(rebasing), .rebasing)
        await t.check("rebase 중: 주 버튼 없음 (체크한 파일이 있어도) · 요약에 원격 항목 없음 · 게시 없음",
                      ChangesState.primary(includedCount: 2, sync: .rebasing) == .none
                      && ChangesState.remoteSummary(.rebasing, hasChanges: true) == nil
                      && !ChangesState.canPublish(.rebasing))
        await t.equal("rebase 중 커밋은 막음 (충돌보다 먼저)",
                      ChangesState.commitBlock(lock: nil, conflictCount: 1, includedCount: 1, message: "m", rebasing: true),
                      .rebasing)
        await t.equal("rebase 중 메타 줄", ChangesState.metaLine(.rebasing, lastFetchAt: nil, detachedHash: "abc1234"),
                      "rebase 진행 중 · HEAD abc1234 · 원격과 비교하지 않음")

        // 원격 명령 실패 표시: 명령 직후 상태와 지금이 같을 때만
        var ahead = GitWorkspaceStatus()
        GitWorkspace.parseStatus("## main...origin/main [ahead 1]\0", into: &ahead)
        ahead.lastCommit = GitCommitSummary(hash: "h1", shortHash: "h1", subject: "s", date: nil)
        ahead.fetchHeadModifiedAt = Date(timeIntervalSince1970: 1_000)
        ahead.isRepository = true
        let recorded = ChangesState.syncContext(ahead)
        await t.check("실패 직후 상태 그대로면 보여줌", ChangesState.failureIsCurrent(recorded: recorded, now: ahead))
        var pushedInTerminal = ahead
        GitWorkspace.parseStatus("## main...origin/main\0", into: &pushedInTerminal)
        await t.check("터미널에서 올려 앞섬이 사라지면 지난 실패", !ChangesState.failureIsCurrent(recorded: recorded, now: pushedInTerminal))
        var fetchedInTerminal = ahead
        fetchedInTerminal.fetchHeadModifiedAt = Date(timeIntervalSince1970: 2_000)
        await t.check("터미널에서 fetch 만 해도 (앞섬 · 뒤처짐이 그대로여도) 지난 실패",
                      !ChangesState.failureIsCurrent(recorded: recorded, now: fetchedInTerminal))
        var mergedAway = ahead
        mergedAway.mergeHead = "m"
        await t.check("병합을 시작 · 끝내면 지난 실패", !ChangesState.failureIsCurrent(recorded: recorded, now: mergedAway))
        await t.check("명령 뒤 상태를 못 읽었으면 보여주지 않음", !ChangesState.failureIsCurrent(recorded: nil, now: ahead))
        await t.check("다시 시도: 업로드는 앞설 때만 · 받기는 뒤처질 때만 · 게시는 게시할 수 있을 때만",
                      ChangesState.retryOffered(.push(branch: "main", setUpstream: false), sync: .ahead(upstream: "o/m", count: 1))
                      && !ChangesState.retryOffered(.push(branch: "main", setUpstream: false), sync: .inSync(upstream: "o/m"))
                      && !ChangesState.retryOffered(.push(branch: "main", setUpstream: false),
                                                    sync: .diverged(upstream: "o/m", ahead: 1, behind: 1))
                      && ChangesState.retryOffered(.pull, sync: .behind(upstream: "o/m", count: 2))
                      && !ChangesState.retryOffered(.pull, sync: .diverged(upstream: "o/m", ahead: 1, behind: 1))
                      && !ChangesState.retryOffered(.pull, sync: .merging(upstream: "o/m"))
                      && ChangesState.retryOffered(.push(branch: "x", setUpstream: true), sync: .noUpstream(.available(onRemote: false)))
                      && !ChangesState.retryOffered(.push(branch: "x", setUpstream: true), sync: .ahead(upstream: "o/x", count: 1))
                      && ChangesState.retryOffered(.fetch, sync: .diverged(upstream: "o/m", ahead: 1, behind: 1)))
        await t.check("동기화 자리에 실패를 보일 수 있는지: 병합 · rebase · 오류 화면 · 모름은 아님",
                      ChangesState.showsSyncFailureInline(ahead) && !ChangesState.showsSyncFailureInline(mergedAway)
                      && !ChangesState.showsSyncFailureInline(rebasing) && !ChangesState.showsSyncFailureInline(nil))
    }

    /// 실패 분류: 영어 원문 · 이 Mac(git 2.42, 한국어)에서 실측한 문장 · 분류 안 됨은 원문 그대로.
    static func failureClassification(_ t: TestKit) async {
        await t.group("Git 실패 분류")
        let push = GitWrite.Operation.push(branch: "main", setUpstream: false)
        let publish = GitWrite.Operation.push(branch: "feature/x", setUpstream: true)
        let commit = GitWrite.Operation.commit(message: "m")

        // 2026-09-13 실측 (한국어 로케일): 원격이 앞서 있는데 업로드
        let koFetchFirst = """
            To /tmp/probe/o.git
             ! [rejected]        main -> main (fetch first)
            error: 레퍼런스를 '/tmp/probe/o.git'에 푸시하는데 실패했습니다
            힌트: Updates were rejected because the remote contains work that you do not
            힌트: have locally. This is usually caused by another repository pushing to
            """
        await t.equal("업로드 거절 (실측 한국어 · fetch first) → 기록 분기", GitFailure.classify(push, output: koFetchFirst), .diverged)
        let koNonFF = " ! [rejected]        main -> main (non-fast-forward)\n"
            + "error: 레퍼런스를 '/tmp/o.git'에 푸시하는데 실패했습니다\n힌트: Updates were rejected because the tip of your current branch is behind\n"
        await t.equal("업로드 거절 (실측 · non-fast-forward) → 기록 분기", GitFailure.classify(push, output: koNonFF), .diverged)
        await t.equal("업로드 거절 (번역 파일의 [거부됨] · 정방향 진행이 아님) → 기록 분기",
                      GitFailure.classify(push, output: " ! [거부됨]        main -> main (정방향 진행이 아님)\n"), .diverged)
        await t.equal("게시 거절 (영어) → 기록 분기",
                      GitFailure.classify(publish, output: " ! [rejected]        feature/x -> feature/x (non-fast-forward)\n"
                                          + "error: failed to push some refs to 'origin'\n"), .diverged)
        let hookDeclined = " ! [remote rejected] main -> main (pre-receive hook declined)\n"
            + "error: failed to push some refs to 'origin'\n"
        await t.equal("서버가 거부(remote rejected)는 기록 분기가 아님 → ref 상태 줄 그대로",
                      GitFailure.classify(push, output: hookDeclined),
                      .unclassified("! [remote rejected] main -> main (pre-receive hook declined)"))

        // 받기 (--ff-only)
        let koDiverging = "힌트: Diverging branches can't be fast-forwarded, you need to either:\n힌트: \n힌트: \tgit merge --no-ff\n"
            + "fatal: 정방향이 불가능하므로, 중지합니다.\n"
        await t.equal("받기 · 기록 분기 (실측 한국어)", GitFailure.classify(.pull, output: koDiverging), .diverged)
        await t.equal("받기 · 기록 분기 (영어)",
                      GitFailure.classify(.pull, output: "fatal: Not possible to fast-forward, aborting.\n"), .diverged)
        let koOverlap = "error: 다음 파일의 로컬 변경 사항을 병합 때문에 덮어 쓰게 됩니다:\n\tg.txt\n"
            + "병합하기 전에 변경 사항을 커밋하거나 스태시하십시오.\n"
            + "error: 병합 때문에 추적하지 않는 다음 작업 폴더의 파일을 덮어씁니다:\n\tu.txt\n"
            + "병합하기 전에 이 파일을 옮기거나 제거하십시오.\n중지함\n업데이트 중 76d8cf3..c63729b\n"
        await t.equal("받기 · 겹치는 로컬 변경 (실측 한국어) → 파일 이름", GitFailure.classify(.pull, output: koOverlap),
                      .overlappingChanges(["g.txt", "u.txt"]))
        let enOverlap = "error: Your local changes to the following files would be overwritten by merge:\n\tMoa/a b.swift\n"
            + "Please commit your changes or stash them before you merge.\nAborting\nUpdating 76d8cf3..c63729b\n"
        await t.equal("받기 · 겹치는 로컬 변경 (영어, 공백 있는 경로)", GitFailure.classify(.pull, output: enOverlap),
                      .overlappingChanges(["Moa/a b.swift"]))
        await t.equal("전환 · 겹치는 로컬 변경 (번역 파일 문장)",
                      GitFailure.classify(.switchBranch("x"),
                                          output: "error: 다음 파일의 로컬 변경 사항을 체크아웃 때문에 덮어 쓰게 됩니다:\n\t"
                                              + "a.swift\n브랜치를 전환하기 전에 변경 사항을 커밋하거나 스태시하십시오.\n중지함\n"),
                      .overlappingChanges(["a.swift"]))

        // 로그인 필요 — 이 문장들은 번역 항목이 없어 영어로 나온다.
        await t.equal("로그인 · HTTPS 프롬프트 막힘 · GitHub 주소",
                      GitFailure.classify(push, output: "fatal: could not read Username for 'https://github.com': "
                                          + "terminal prompts disabled\n", remoteURL: "https://github.com/o/r.git"),
                      .authentication(gitHub: true))
        await t.equal("로그인 · Authentication failed · GitHub 아닌 주소",
                      GitFailure.classify(.fetch, output: "remote: Invalid username or password.\n"
                                          + "fatal: Authentication failed for 'https://git.example.com/o/r.git/'\n",
                                          remoteURL: "https://git.example.com/o/r.git"),
                      .authentication(gitHub: false))
        let koSSH = "git@github.com: Permission denied (publickey).\nfatal: 리모트 저장소에서 읽을 수 없습니다\n\n"
            + "올바른 접근 권한이 있는지, 그리고 저장소가 있는지\n확인하십시오.\n"
        await t.equal("로그인 · ssh 공개 키 거절 (실측 한국어) · 주소를 모르면 출력의 주소로",
                      GitFailure.classify(.pull, output: koSSH), .authentication(gitHub: true))
        await t.equal("로그인 · ssh 별칭 주소(github-work:)는 GitHub 로 단정하지 않음",
                      GitFailure.classify(.pull, output: koSSH, remoteURL: "github-work:o/r.git"),
                      .authentication(gitHub: false))
        await t.equal("로그인 · GitHub Enterprise 주소는 GitHub 로 쓰지 않음",
                      GitFailure.classify(push, output: "fatal: could not read Username for 'https://github.example.com': "
                                          + "terminal prompts disabled\n", remoteURL: "https://github.example.com/o/r"),
                      .authentication(gitHub: false))

        // 커밋
        await t.equal("커밋할 것 없음 (영어)", GitFailure.classify(commit, output: "On branch main\nnothing to commit, working tree clean\n"),
                      .nothingToCommit)
        await t.equal("커밋할 것 없음 (한국어 · 새 파일만 있음)",
                      GitFailure.classify(commit, output: "현재 브랜치 main\n커밋할 사항을 추가하지 않았지만 추적하지 않는 파일이 있습니다\n"),
                      .nothingToCommit)
        let koIdentity = "Author identity unknown\n\n*** 내가 누구인지 설정하십시오.\n\n다음을 실행하면,\n\n"
            + "  git config --global user.email \"you@example.com\"\n\nfatal: 메일 주소가 없고 자동 검사가 꺼져 있습니다\n"
        await t.equal("신원 미설정 (실측 한국어)", GitFailure.classify(commit, output: koIdentity), .identityUnknown)
        await t.equal("신원 미설정 (영어)",
                      GitFailure.classify(commit, output: "*** Please tell me who you are.\n\nRun\n\nfatal: unable to auto-detect "
                                          + "email address (got 'j@m.(none)')\n"), .identityUnknown)
        await t.equal("훅 출력은 분류하지 않고 마지막 줄 그대로",
                      GitFailure.classify(commit, output: "Running checks...\nlint: 경고 2개\n"), .unclassified("lint: 경고 2개"))

        // 명령 범위 — 다른 명령의 문장을 끌어오지 않는다.
        await t.equal("커밋 훅이 'Authentication failed' 를 써도 로그인 필요로 보지 않음",
                      GitFailure.classify(commit, output: "hook: Authentication failed for registry\n"),
                      .unclassified("hook: Authentication failed for registry"))
        await t.equal("업로드 출력의 'nothing to commit' 은 커밋할 것 없음이 아님",
                      GitFailure.classify(push, output: "nothing to commit\n"), .unclassified("nothing to commit"))

        // 분류 안 됨 — 원문 그대로 (힌트 줄은 고르지 않음)
        await t.equal("분류 안 됨: fatal 줄 그대로",
                      GitFailure.classify(.fetch, output: "fatal: 'upstream' does not appear to be a git repository\n"
                                          + "fatal: Could not read from remote repository.\n"),
                      .unclassified("fatal: 'upstream' does not appear to be a git repository"))
        await t.equal("분류 안 됨: 힌트가 아닌 마지막 줄", GitFailure.verbatimLine(["무언가 실패", "hint: 이렇게 해 보세요", ""]),
                      "무언가 실패")
        await t.equal("출력 없음은 그 사실", GitFailure.classify(push, output: " \n"), .unclassified(GitFailure.noOutputLine))
        await t.equal("시간 초과 안내도 그대로", GitFailure.classify(.pull, output: "시간 초과(120초)"),
                      .unclassified("시간 초과(120초)"))

        // 화면 문구 — 모르는 값을 만들지 않는다
        let divergedPush = GitFailure.diverged.explanation(for: push, remoteName: "origin")
        await t.check("업로드 거절 안내: '원격 변경 받기' 를 권하지 않고 합치기를 말함 · 개수를 지어내지 않음",
                      divergedPush.title == "업로드하지 못했습니다" && !divergedPush.detail.contains("받기")
                      && divergedPush.detail.contains("합친") && !divergedPush.detail.contains(where: \.isNumber),
                      divergedPush.detail)
        await t.equal("제목: 브랜치 업로드 · 받기 · 원격 확인 · 체크 (단추와 같은 말, txt-4)",
                      [GitFailure.failedTitle(publish), GitFailure.failedTitle(.pull), GitFailure.failedTitle(.fetch),
                       GitFailure.failedTitle(.stage(["a"])), GitFailure.failedTitle(.unstage(["a"]))],
                      ["브랜치를 업로드하지 못했습니다", "원격 변경을 받지 못했습니다", "원격 상태를 확인하지 못했습니다",
                       "커밋에 포함하지 못했습니다", "커밋에서 빼지 못했습니다"])
        // 다른 worktree 가 쓰는 브랜치로 전환 (chg-16) — git 의 영어 원문 그대로 두지 않고 까닭과 할 일을.
        let usedByWorktree = GitFailure.classify(.switchBranch("ahc/1234abcd"),
                                                 output: "fatal: 'ahc/1234abcd' is already used by worktree at '/tmp/wt/1234abcd'")
        await t.equal("다른 worktree 가 쓰는 브랜치 → 분류 · 경로", usedByWorktree, .branchInOtherWorktree("/tmp/wt/1234abcd"))
        await t.check("예전 git 의 문장도 · 안내에 정리하는 길",
                      GitFailure.classify(.switchBranch("x"), output: "fatal: 'x' is already checked out at '/a/b'")
                        == .branchInOtherWorktree("/a/b")
                        && usedByWorktree.explanation(for: .switchBranch("ahc/1234abcd")).detail.contains("정리"))
        let gitHub = GitFailure.authentication(gitHub: true).explanation(for: push, remoteName: "origin")
        await t.check("GitHub 로그인 안내: gh auth login · 원격 이름",
                      gitHub.title == "GitHub 로그인이 필요합니다" && gitHub.detail.contains("gh auth login")
                      && gitHub.detail.hasPrefix("origin 에 로그인하지 못했습니다"), gitHub.detail)
        let other = GitFailure.authentication(gitHub: false).explanation(for: push, remoteName: nil)
        await t.check("GitHub 인지 모르면 GitHub 라고 쓰지 않음",
                      other.title == "원격 저장소 로그인이 필요합니다" && !other.detail.contains("GitHub")
                      && !other.detail.contains("gh auth") && other.detail.hasPrefix("원격 저장소에 로그인하지 못했습니다"),
                      other.detail)
        await t.check("GitHub 로그인 명령은 새 줄 맨 앞 (좁은 폭에서 gh 와 auth login 이 갈리지 않게)",
                      gitHub.detail.contains("\ngh auth login "), gitHub.detail)
        await t.equal("로그인 · 주소를 모를 때 github.company.com 은 GitHub 가 아님",
                      GitFailure.classify(push, output: "fatal: Authentication failed for 'https://github.company.com/o/r.git/'\n"),
                      .authentication(gitHub: false))
        await t.equal("로그인 · 출력의 주소(insteadOf 를 거친 실제 주소)가 원격 설정보다 먼저",
                      GitFailure.classify(push, output: "fatal: Authentication failed for 'https://git.example.com/o/r.git/'\n",
                                          remoteURL: "git@github.com:o/r.git"),
                      .authentication(gitHub: false))
        await t.equal("로그인 · 출력의 주소가 github.com",
                      GitFailure.classify(.fetch, output: "fatal: Authentication failed for 'https://github.com/o/r.git/'\n"),
                      .authentication(gitHub: true))
        await t.equal("올리는 원격: remote.pushDefault · pushRemote 가 있으면 그것",
                      GitWorkspace.remoteName(for: push, upstream: "origin/main", remotes: ["origin", "fork"], pushRemote: "fork"),
                      "fork")
        await t.equal("받기 · 확인은 pushRemote 와 관계없이 추적 브랜치의 원격",
                      GitWorkspace.remoteName(for: .pull, upstream: "origin/main", remotes: ["origin", "fork"], pushRemote: "fork"),
                      "origin")
        let pullOverlap = GitFailure.overlappingChanges(["a.txt"]).explanation(for: .pull)
        await t.check("받기 · 겹치는 변경: 커밋을 권하지 않음 (커밋하면 기록이 갈라져 --ff-only 가 실패)",
                      !pullOverlap.detail.contains("커밋하거나") && !pullOverlap.detail.contains("먼저 커밋")
                      && pullOverlap.detail.hasPrefix("내 파일과 겹치는 변경이 있어 받지 않았습니다: a.txt."),
                      pullOverlap.detail)
        let many = GitFailure.overlappingChanges(["a", "b", "c", "d", "e"]).explanation(for: .pull)
        await t.check("겹치는 파일 이름은 3개 + 외 n개",
                      many.detail.contains("a, b, c 외 2개") && many.title == "원격 변경을 받지 못했습니다", many.detail)
        await t.check("파일 이름을 못 읽었으면 이름을 쓰지 않음",
                      !GitFailure.overlappingChanges([]).explanation(for: .pull).detail.contains(":"))
        let raw = GitFailure.unclassified("error: 무언가").explanation(for: .fetch)
        await t.check("분류 안 됨은 글자 그대로 (고정폭 표시)", raw.verbatim && raw.detail == "error: 무언가")
        await t.check("원격에 말을 거는 명령만 동기화 자리에 실패를 보인다",
                      push.talksToRemote && GitWrite.Operation.pull.talksToRemote && GitWrite.Operation.fetch.talksToRemote
                      && !commit.talksToRemote && !GitWrite.Operation.switchBranch("x").talksToRemote)
    }

    /// 새 읽기 조회를 실제 임시 저장소로: 원격에서 온 커밋 · 이 브랜치에만 있는 커밋 · 50개 넘게 잘림 ·
    /// 브랜치 메타 · 원격에만 있는 브랜치 · 병합 중(MERGE_HEAD · MERGE_MSG) · 충돌 해결 뒤 병합 커밋.
    static func stage2LiveQuery(_ t: TestKit) async {
        await t.group("변경사항 탭 조회 · 원격 도착 · 병합")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ahc-stage2-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        let other = root.appendingPathComponent("other")
        let origin = root.appendingPathComponent("origin.git")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        guard let git = GitInspector.findGit(environment: env) else {
            await t.check("git 실행 파일", false, "찾지 못함")
            return
        }
        @discardableResult
        func sh(_ args: [String], in dir: URL, who: String = "hana") async -> String {
            let result = await CLIEnvironment.captureOutput(
                executable: git, arguments: ["-c", "user.name=\(who)", "-c", "user.email=\(who)@example.com",
                                             "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args,
                environment: env, workingDirectory: dir, timeout: 30)
            if case .success(let out) = result { return out }
            return ""
        }
        func write(_ text: String, _ name: String, in dir: URL) {
            try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func commitFile(_ name: String, _ text: String, _ message: String, in dir: URL, who: String = "hana") async {
            write(text, name, in: dir)
            await sh(["add", "--", name], in: dir, who: who)
            await sh(["commit", "-q", "-m", message], in: dir, who: who)
        }

        await sh(["init", "-q", "-b", "main"], in: work)
        await commitFile("a.txt", "base\n", "기준", in: work)
        await sh(["init", "--bare", "-q", "-b", "main", origin.path], in: root)
        await sh(["remote", "add", "origin", origin.path], in: work)
        await sh(["push", "-q", "-u", "origin", "main"], in: work)
        await sh(["clone", "-q", origin.path, other.path], in: root)
        for (i, subject) in ["토큰 만료 시 재시도 간격 조정", "로그인 버튼 비활성 조건 수정", "AuthTransport 테스트 더블 추가"]
            .enumerated() {
            await commitFile("r\(i).txt", "\(i)\n", subject, in: other, who: "minji")
        }
        await sh(["push", "-q"], in: other)
        await sh(["fetch", "-q"], in: work)

        var status = await GitWorkspace.status(at: work, environment: env)
        await t.equal("원격 변경 도착 판정", ChangesState.sync(status), .behind(upstream: "origin/main", count: 3))
        await t.equal("원격에서 온 커밋 (최근 것부터)", status.incomingCommits?.map(\.subject),
                      ["AuthTransport 테스트 더블 추가", "로그인 버튼 비활성 조건 수정", "토큰 만료 시 재시도 간격 조정"])
        await t.check("작성자 · 머리글자 · 상대 시각 · 커밋 시각이 있음",
                      status.incomingCommits?.allSatisfy { $0.author == "minji" && $0.authorInitial == "M"
                          && !$0.relativeDate.isEmpty && $0.committedAt != nil && $0.shortHash.count >= 7 } == true)
        await t.check("앞서 있지 않으면 이 브랜치의 커밋 목록은 읽지 않음", status.outgoingCommits == nil)
        await t.equal("주 버튼: 원격 변경 받기", ChangesState.primary(includedCount: 0, sync: ChangesState.sync(status)), .pull)

        // 이 브랜치에도 커밋 → 기록 분기 (같은 파일 다른 줄 → 합치면 충돌)
        await commitFile("a.txt", "local\n", "로컬 수정", in: work)
        await commitFile("l.txt", "l\n", "로컬 추가", in: work)
        await commitFile("a.txt", "remote\n", "원격 수정", in: other, who: "minji")
        await sh(["push", "-q"], in: other)
        await sh(["fetch", "-q"], in: work)
        status = await GitWorkspace.status(at: work, environment: env)
        await t.equal("기록 분기 판정", ChangesState.sync(status), .diverged(upstream: "origin/main", ahead: 2, behind: 4))
        await t.equal("이 브랜치에만 있는 커밋", status.outgoingCommits?.map(\.subject), ["로컬 추가", "로컬 수정"])
        await t.equal("원격에만 있는 커밋 수", status.incomingCommits?.count, 4)
        await t.equal("주 버튼: 터미널에서 합치기", ChangesState.primary(includedCount: 0, sync: ChangesState.sync(status)),
                      .mergeInTerminal)

        // 브랜치 메타 · 원격에만 있는 브랜치
        await sh(["switch", "-q", "-c", "topic"], in: other)
        await commitFile("t.txt", "t\n", "주제", in: other, who: "sora")
        await sh(["push", "-q", "-u", "origin", "topic"], in: other)
        await sh(["fetch", "-q"], in: work)
        status = await GitWorkspace.status(at: work, environment: env)
        await t.check("로컬 브랜치 마지막 커밋 상대 시각 · 시각",
                      status.localBranches.first { $0.name == "main" }.map { $0.committerDate != nil && $0.committedAt != nil }
                          == true, "\(status.localBranches)")
        await t.check("원격 브랜치 모델 (이름 · 원격 · 상대 시각 · 시각)",
                      status.remoteBranches.contains { $0.fullName == "origin/topic" && $0.remote == "origin"
                          && $0.name == "topic" && $0.committerDate != nil && $0.committedAt != nil },
                      "\(status.remoteBranches)")
        await t.equal("원격에만 있는 브랜치 (main 은 추적 중이라 빠짐)",
                      ChangesState.remoteOnlyBranches(status.remoteBranches, local: status.localBranches).map(\.fullName),
                      ["origin/topic"])

        // 50개가 넘으면 50개만 읽고 전체 수는 뒤처짐 수로 안다
        await sh(["switch", "-q", "main"], in: other)
        _ = await CLIEnvironment.captureOutput(
            executable: "/bin/sh",
            arguments: ["-c", "for i in $(seq 1 52); do echo $i > m$i.txt; \"$0\" add m$i.txt; "
                        + "\"$0\" -c user.name=minji -c user.email=m@example.com -c commit.gpgsign=false commit -q -m \"묶음 $i\"; "
                        + "done; \"$0\" push -q", git],
            environment: env, workingDirectory: other, timeout: 120)
        await sh(["fetch", "-q"], in: work)
        status = await GitWorkspace.status(at: work, environment: env)
        let listed = status.incomingCommits?.count ?? 0
        await t.check("50개까지만 읽음 · '외 n개' 는 뒤처짐 수에서",
                      listed == 50 && status.behind == 56 && ChangesState.moreCount(listed: listed, total: status.behind) == 6,
                      "읽음 \(listed) · 뒤처짐 \(String(describing: status.behind))")

        // 병합 진행 중: 사용자가 터미널에서 합친다 (앱은 merge 를 하지 않는다)
        await sh(["merge", "--no-edit", "origin/main"], in: work)
        status = await GitWorkspace.status(at: work, environment: env)
        let rawMessage = (try? String(contentsOf: work.appendingPathComponent(".git/MERGE_MSG"), encoding: .utf8)) ?? ""
        await t.check("MERGE_HEAD 감지 → 병합 중 (기록 분기로 보이지 않음)",
                      status.isMerging && ChangesState.sync(status) == .merging(upstream: "origin/main"),
                      "\(String(describing: status.mergeHead)) \(ChangesState.sync(status))")
        await t.check("MERGE_MSG 원문에는 주석 줄이 있고, 초안에서는 빠짐",
                      rawMessage.contains("\n#") && status.mergeMessage?.contains("#") == false
                      && status.mergeMessage?.hasPrefix("Merge") == true,
                      "\(String(describing: status.mergeMessage))")
        let mergeRows = ChangesState.rows(from: status)
        await t.check("충돌 파일은 충돌 행 (체크 불가)",
                      mergeRows.first { $0.path == "a.txt" }.map { $0.inclusion == .conflict && !$0.isCheckable } == true,
                      "\(mergeRows.map { "\($0.code) \($0.path)" })")
        await t.check("병합 중에는 앞섬/뒤처짐 커밋 목록 대신 병합 화면 (커밋 섹션 없음)",
                      ChangesState.commitSections(ChangesState.sync(status)).isEmpty)

        // 충돌 해결: 파일을 정리하고 git add (터미널에서) → 충돌 0, 병합은 아직 진행 중
        write("merged\n", "a.txt", in: work)
        await sh(["add", "a.txt"], in: work)
        status = await GitWorkspace.status(at: work, environment: env)
        let resolved = ChangesState.rows(from: status)
        await t.check("충돌이 모두 풀려도 MERGE_HEAD 가 남아 있으면 병합 중 · 커밋 가능",
                      status.isMerging && status.conflicted.isEmpty
                      && ChangesState.commitBlock(lock: nil, conflictCount: 0,
                                                  includedCount: ChangesState.includedCount(resolved),
                                                  message: status.mergeMessage ?? "", merging: true) == nil)
        // 앱의 커밋(git commit -F -)이 병합 커밋을 완성한다 — 새 명령이 아니다.
        let committed = await GitWrite.perform(.commit(message: status.mergeMessage ?? "Merge"), git: git, at: work,
                                               environment: env)
        let parents = await sh(["log", "-1", "--format=%P"], in: work).split(separator: " ").count
        let body = await sh(["log", "-1", "--format=%B"], in: work)
        status = await GitWorkspace.status(at: work, environment: env)
        await t.check("커밋이 병합을 마무리 (부모 2개 · MERGE_HEAD 사라짐)",
                      committed.succeeded && parents == 2 && !status.isMerging, committed.output)
        await t.check("병합 커밋 메시지에 '# Conflicts' 가 남지 않음", !body.contains("#") && body.hasPrefix("Merge"), body)
        await t.equal("병합 뒤: 업로드 대기", ChangesState.sync(status), .ahead(upstream: "origin/main", count: 3))

        // 추적 브랜치가 없으면 커밋 목록을 읽지 않는다 ("원격 브랜치 없음")
        await sh(["switch", "-q", "-c", "no-upstream"], in: work)
        await commitFile("n.txt", "n\n", "추적 없는 커밋", in: work)
        status = await GitWorkspace.status(at: work, environment: env)
        await t.check("upstream 없음 → 커밋 목록 조회 안 함",
                      status.upstream == nil && status.incomingCommits == nil && status.outgoingCommits == nil)
        await t.check("브랜치 위에서는 rebase 아님", !status.isRebasing)

        // rebase 가 충돌로 멈춤 (합치는 방법의 git pull --rebase 와 같은 상태): MERGE_HEAD 는 없고 HEAD 는 떼어져 있다.
        let rb = root.appendingPathComponent("rebase")
        try? fm.createDirectory(at: rb, withIntermediateDirectories: true)
        await sh(["init", "-q", "-b", "main"], in: rb)
        await commitFile("a.txt", "base\n", "기준", in: rb)
        await sh(["switch", "-q", "-c", "topic"], in: rb)
        await commitFile("a.txt", "topic\n", "주제 수정", in: rb)
        await sh(["switch", "-q", "main"], in: rb)
        await commitFile("a.txt", "main\n", "본선 수정", in: rb)
        await sh(["switch", "-q", "topic"], in: rb)
        await sh(["rebase", "main"], in: rb)
        status = await GitWorkspace.status(at: rb, environment: env)
        await t.check("rebase 멈춤 감지 → rebase 중 (병합 아님 · 떼어진 HEAD 로 보지 않음)",
                      status.isRebasing && !status.isMerging && status.branch == nil
                      && ChangesState.sync(status) == .rebasing && status.conflicted.map(\.path) == ["a.txt"],
                      "\(ChangesState.sync(status)) \(status.isRebasing)")
        await sh(["rebase", "--abort"], in: rb)
        status = await GitWorkspace.status(at: rb, environment: env)
        await t.check("rebase 를 멈추면 다시 브랜치", !status.isRebasing && status.branch == "topic")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - 파일 탭의 미리보기

extension WorkspaceTests {
    /// 파일 탭의 미리보기 (`FilePreview`): 무엇으로 보일지 · 앞부분만 · UTF-8 글자 중간 자르기 · 실제 파일 읽기.
    static func filePreview(_ t: TestKit) async {
        await t.group("파일 탭: 미리보기")
        let code = Data("let x = 1\n".utf8)
        await t.equal("확장자로 먼저, 모르면 앞부분으로", [
            FilePreview.kind(fileName: "README.md", head: code), FilePreview.kind(fileName: "main.swift", head: code),
            FilePreview.kind(fileName: "Makefile", head: code), FilePreview.kind(fileName: "logo.PNG", head: Data([0x89, 0x50])),
            FilePreview.kind(fileName: "a.bin", head: Data([0x00, 0x01])), FilePreview.kind(fileName: "doc.pdf", head: code),
            FilePreview.kind(fileName: "empty.txt", head: Data())],
                      [.markdown, .text, .text, .image, .other, .other, .text])
        let korean = Data("가나다".utf8)
        await t.equal("UTF-8 글자 중간에서 잘린 앞부분은 그 조각을 떼고 읽는다", FilePreview.decodeUTF8Prefix(korean.prefix(7)), "가나")
        await t.check("NUL 이 있으면 글이 아니다", !FilePreview.isText(Data([0x41, 0x00, 0x42])))
        let many = (1...5000).map { "line \($0)" }.joined(separator: "\n")
        let shown = FilePreview.shownText(many, byteTruncated: false)
        await t.check("줄 수 상한 — 앞의 줄들만 · 잘렸다고 적는다",
                      shown.truncated && shown.text.split(separator: "\n").count == FilePreview.textLineLimit)

        func loadError(_ url: URL) -> FilePreview.LoadError? {
            if case .failure(let error) = FilePreview.load(url) { return error }
            return nil
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-preview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("big.log")
        try? String(repeating: "가", count: FilePreview.textByteLimit).write(to: big, atomically: true, encoding: .utf8)
        if case .success(let content) = FilePreview.load(big) {
            await t.check("큰 글 파일은 앞부분만 (바이트 상한) · 글자를 깨지 않는다",
                          content.kind == .text && content.truncated && (content.text?.utf8.count ?? .max) <= FilePreview.textByteLimit
                            && content.text?.allSatisfy { $0 == "가" } == true && content.byteSize == FilePreview.textByteLimit * 3)
        } else {
            await t.check("큰 글 파일 읽기", false)
        }
        let markdown = dir.appendingPathComponent("NOTES.md")
        try? "# 제목\n본문".write(to: markdown, atomically: true, encoding: .utf8)
        let markdownContent = try? FilePreview.load(markdown).get()
        await t.check("Markdown 은 전부 · 잘리지 않음",
                      markdownContent?.kind == .markdown && markdownContent?.text == "# 제목\n본문" && markdownContent?.truncated == false)
        await t.equal("폴더 · 없는 파일", [loadError(dir), loadError(dir.appendingPathComponent("none.txt"))], [.directory, .missing])
    }

    /// 파일 탭에서 열 때의 규칙 (`FileOpenRule`). 심볼릭 링크 · Finder 별칭은 따라간 대상으로 판정한다 — `readme.txt -> Helper.app` 이
    /// 글 파일로 보여 두 번 누르면 앱이 떴다 (2026-10-12). 실제 파일 · 링크를 임시 폴더에 만든다. 기본 앱은 묻지 않는다 (LaunchServices 없이).
    static func fileOpenRule(_ t: TestKit) async {
        await t.group("파일 탭: 열기 규칙")
        await t.equal("이름 · 실행 비트 · 기본 앱 (링크가 아닐 때)", [
            FileOpenRule.action(FileOpenRule.Facts(name: "notes.txt", targetName: "notes.txt")),
            FileOpenRule.action(FileOpenRule.Facts(name: "setup.command", targetName: "setup.command")),
            FileOpenRule.action(FileOpenRule.Facts(name: "build", targetName: "build", executable: true)),
            FileOpenRule.action(FileOpenRule.Facts(name: "build.txt", targetName: "build.txt", executable: true)),
            FileOpenRule.action(FileOpenRule.Facts(name: "a.scpt", targetName: "a.scpt", defaultApp: "Terminal.app")),
        ].map { $0 == .open }, [true, false, false, true, false])
        let linkedBuild = FileOpenRule.Facts(name: "readme.txt", targetName: "build.txt", viaLink: true, executable: true)
        await t.check("링크가 가리키는 실행 파일은 확장자와 상관없이 Finder 에서", FileOpenRule.action(linkedBuild) != .open)

        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-open-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir.appendingPathComponent("Helper.app/Contents/MacOS"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: dir.appendingPathComponent("docs"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        func write(_ name: String, _ text: String, executable: Bool = false) {
            let url = dir.appendingPathComponent(name)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            if executable { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        write("Helper.app/Contents/MacOS/Helper", "#!/bin/sh\necho helper\n", executable: true)
        write("Helper.app/Contents/Info.plist",
              "<plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>Helper</string></dict></plist>")
        write("run.command", "#!/bin/sh\necho run\n")
        write("tool", "#!/bin/sh\necho tool\n", executable: true)
        write("notes.txt", "메모\n")
        // 이름은 글 파일인데 가리키는 곳은 앱 · 스크립트 · 실행 파일 · 폴더. 이어진 링크 · 고리도.
        for (link, destination) in [("readme.txt", "Helper.app"), ("guide.md", "run.command"), ("tool.txt", "tool"),
                                    ("start.command", "notes.txt"), ("docs.txt", "docs"), ("link.txt", "notes.txt"),
                                    ("chain.txt", "link.txt"), ("loop-a", "loop-b"), ("loop-b", "loop-a")] {
            try? fm.createSymbolicLink(atPath: dir.appendingPathComponent(link).path, withDestinationPath: destination)
        }
        func decided(_ name: String) -> String {
            switch FileOpenRule.action(for: dir.appendingPathComponent(name), defaultApp: { _ in nil }) {
            case .open: return "열기"
            case .reveal: return "Finder"
            }
        }
        await t.equal("링크 → .app · .command · 실행 파일 · 폴더는 Finder 에서",
                      ["readme.txt", "guide.md", "tool.txt", "docs.txt"].map(decided), ["Finder", "Finder", "Finder", "Finder"])
        await t.equal("링크 이름이 실행 형식이면 대상이 글이어도 Finder 에서", decided("start.command"), "Finder")
        await t.equal("글 파일을 가리키는 링크 · 이어진 링크는 연다", ["link.txt", "chain.txt"].map(decided), ["열기", "열기"])
        await t.equal("고리는 따라가지 못해 Finder 에서", decided("loop-a"), "Finder")
        await t.equal("링크가 아닐 때는 그대로 (글 · .command · 실행 파일)", ["notes.txt", "run.command", "tool"].map(decided),
                      ["열기", "Finder", "Finder"])
        let app = FileOpenRule.facts(of: dir.appendingPathComponent("readme.txt"), defaultApp: { _ in nil })
        await t.check("링크의 사실은 대상의 것 (이름 · 패키지 · 폴더)",
                      app.viaLink && app.targetName == "Helper.app" && app.isPackage && app.isDirectory && !app.executable, "\(app)")
        let chain = FileOpenRule.facts(of: dir.appendingPathComponent("chain.txt"), defaultApp: { _ in nil })
        await t.check("이어진 링크는 끝까지", chain.viaLink && chain.targetName == "notes.txt" && !chain.unresolved, "\(chain)")
        if case .reveal(let reason) = FileOpenRule.action(for: dir.appendingPathComponent("readme.txt"), defaultApp: { _ in nil }) {
            await t.check("까닭에 링크가 가리키는 대상을 적는다", reason.contains("Helper.app"), reason)
        } else {
            await t.check("까닭에 링크가 가리키는 대상을 적는다", false, "열기")
        }

        // Finder 별칭도 `NSWorkspace.open` 은 따라간다 — 별칭 파일은 이름 · 실행 비트로는 글 파일이다.
        let alias = dir.appendingPathComponent("alias-notes.txt")
        do {
            let bookmark = try dir.appendingPathComponent("Helper.app")
                .bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
            try URL.writeBookmarkData(bookmark, to: alias)
            await t.equal("Finder 별칭 → .app 은 Finder 에서", decided("alias-notes.txt"), "Finder")
        } catch {
            await t.note("Finder 별칭을 만들지 못해 건너뜀: \(error.localizedDescription)")
        }
    }
}
