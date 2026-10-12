import Foundation

// MARK: - 실측: 공개 전 결함 수정 (`inttest releasefix`)

/// 2026-10-09 공개 전 결함 수정 가운데 아래 셋을 실제 CLI 로 잰다. **실제 claude · codex CLI 를 부르고 구독 한도를 쓴다**
/// (Claude `haiku`, Codex `gpt-5.6-luna` low — astra 는 쓰지 않는다). `live` · `all` 에는 넣지 않았다.
///   ③ 앱이 CLI 를 끌 때(오류 · 한도로 끝난 실행 · 중단이 응답하지 않을 때와 같은 길 — 어댑터의 `shutdown`) 백그라운드 명령이 남는가.
///      같은 장면에서 예전 동작(직접 띄운 PID 만 — `ManagedProcess.cleansDescendants = false`)과 지금 동작(자손까지)을 견준다.
///   ① 독립 작업 폴더에서 이어 쓴 Claude 대화가 정리 뒤에도 이어지는가 — 실제 앱 모델로 (한 턴 → 독립 작업 폴더 → 그 폴더에서 한 턴 →
///      정리 → 두 턴의 내용을 묻는다). 정리 뒤 프로젝트 폴더 칸에 옛 사본을 되돌려 놓은 대화(예전 동작)와 견준다.
///   ⑦ API 크레딧 대화의 제목 요약이 키 길로 가는가 — 키체인에 진짜 키가 없으면 가짜 키로: CLI 가 그 키를 쓰는지(`apiKeySource`),
///      구독 대화는 구독 길 그대로인지.
@MainActor
enum ReleaseFixLiveTests {
    static let claudeModel = "haiku"
    static let codexModel = "gpt-5.6-luna"
    static let codexEffort = "low"

    static func run(_ t: TestKit) async {
        print("""
        공개 전 결함 수정 — 실제 CLI 실측
          실제 claude · codex CLI 를 부르고 구독 한도를 씁니다. 모델: Claude \(claudeModel), Codex \(codexModel)(\(codexEffort)). astra 는 쓰지 않습니다.
          ③ 백그라운드 명령을 남긴 채 앱이 CLI 를 끈다 — 예전 동작 · 지금 동작 (Claude · Codex)
          ① 독립 작업 폴더 → 정리 → 이어 묻기 (실제 앱 모델 · Claude) — 지금 동작 · 예전 동작
          ⑦ 제목 요약의 자격 (Claude)

        """)
        let cli = await TestEnv.resolveCLI()
        await orphans(t, cli)
        await worktreeResume(t, cli)
        await titleRoute(t, cli)
    }

    /// ③ 만 (`inttest orphans`).
    static func runOrphans(_ t: TestKit) async {
        await orphans(t, await TestEnv.resolveCLI())
    }

    // MARK: ③ 남는 백그라운드 명령

    final class Box: @unchecked Sendable {
        var settled = false
        var model: String?
        var finished: AgentTurnResult?
    }

    private static func orphans(_ t: TestKit, _ cli: (claude: String?, codex: String?, env: [String: String])) async {
        await t.group("실측 ③: 앱이 CLI 를 끌 때 남는 백그라운드 명령 — 예전(직접 띄운 PID 만) · 지금(자손까지)")
        let folder: URL
        do { folder = try TestEnv.makeTempProject("releasefix-orphans") } catch {
            await t.check("임시 폴더", false, "\(error)")
            return
        }
        defer { TestEnv.cleanup(folder) }
        if let claude = cli.claude {
            for (old, hung, marker) in [(true, false, "sleep 6101"), (false, false, "sleep 6102"),
                                        (true, true, "sleep 6105"), (false, true, "sleep 6106")] {
                let adapter = ClaudeAdapter(executablePath: claude, environment: cli.env, permissionMode: "acceptEdits")
                let prompt = "Use the Bash tool with run_in_background set to true to run exactly: \(marker). "
                    + "Do not wait for it and do not check on it. Then reply with the single word: started"
                await orphanCase(t, label: "Claude", old: old, hung: hung, marker: marker, adapter: adapter,
                                 request: AgentTurnRequest(runID: UUID().uuidString, prompt: prompt, workingDirectory: folder,
                                                           model: claudeModel, waitForBackground: true))
            }
        } else {
            await t.check("claude CLI 실행 파일 탐색", false, "없음 — 건너뜀")
        }
        if let codex = cli.codex {
            for (old, hung, marker) in [(true, false, "sleep 6103"), (false, false, "sleep 6104"),
                                        (true, true, "sleep 6107"), (false, true, "sleep 6108")] {
                let adapter = CodexAdapter(executablePath: codex, environment: cli.env)
                let prompt = "This is a protocol test of background terminals. Start the shell command `\(marker) && echo done > marker.txt` "
                    + "with your command tool using a short yield time (about 1 second), so that it keeps running as a background terminal "
                    + "session. Do not wait for it, do not poll it, and do not use nohup, & or disown. Then immediately end your turn by "
                    + "replying exactly: started."
                await orphanCase(t, label: "Codex", old: old, hung: hung, marker: marker, adapter: adapter,
                                 request: AgentTurnRequest(runID: UUID().uuidString, prompt: prompt, workingDirectory: folder,
                                                           model: codexModel, effort: codexEffort, waitForBackground: true))
            }
        } else {
            await t.check("codex CLI 실행 파일 탐색", false, "없음 — 건너뜀")
        }
    }

    /// 보내고, 백그라운드 명령을 남긴 채 기다리는 상태(`turnSettled`)가 되면 어댑터의 `shutdown` 으로 끈다 — 실행이 오류 · 한도로 끝날 때
    /// `RunSession.finish` 가 부르는 것과 같은 길. 끈 뒤 그 명령(과 그것을 돌리는 셸)이 남았는지 본다.
    /// `hung` 이면 끄기 전에 CLI 를 멈춰 둔다(SIGSTOP) — SIGTERM 에 응답하지 못해 `shutdown` 이 3초 뒤 SIGKILL 로 가는 장면.
    private static func orphanCase(_ t: TestKit, label: String, old: Bool, hung: Bool = false, marker: String, adapter: AgentAdapter,
                                   request: AgentTurnRequest) async {
        let way = (old ? "예전 동작(직접 띄운 PID 만)" : "지금 동작(자손까지)") + (hung ? " · CLI 가 응답 없음(SIGKILL 까지)" : "")
        let box = Box()
        let stream = adapter.start(request)
        let consumer = Task { @MainActor in
            for await event in stream {
                switch event {
                case .turnSettled: box.settled = true
                case .sessionEstablished(_, let model, _): if let model { box.model = model }
                case .approvalRequested(let approval): await adapter.respond(approvalID: approval.id, decision: .allow)
                case .finished(let result): box.finished = result
                default: break
                }
            }
        }
        defer { consumer.cancel() }
        var related: [BackgroundLiveTests.Proc] = []
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            if let model = box.model, model.lowercased().contains("astra") {
                await t.check("\(label) · \(way): 모델", false, "astra 로 잡혀 멈춤 (\(model))")
                _ = await adapter.shutdown()
                return
            }
            related = await processes(containing: marker)
            if box.settled && related.contains(where: { $0.command.hasPrefix(marker) }) { break }
            if box.finished != nil { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        guard box.settled, related.contains(where: { $0.command.hasPrefix(marker) }), box.finished == nil else {
            await t.check("\(label) · \(way): 백그라운드 명령을 남긴 채 기다리는 상태가 됐다", false,
                          "대기 \(box.settled) · `\(marker)` \(related.count)개 · 끝 \(box.finished.map { $0.state.rawValue } ?? "없음") · "
                            + "모델 \(box.model ?? "미확인")")
            _ = await adapter.shutdown()
            for p in await processes(containing: marker) { kill(p.pid, SIGKILL) }
            return
        }
        await t.note("\(label) · \(way): 기다리는 중 — 모델 \(box.model ?? "미확인") · `\(marker)` 관련 프로세스 \(related.count)개: "
                     + related.map { "\($0.pid) \($0.command.prefix(50))" }.joined(separator: " | "))
        if hung {
            // 표식 명령의 조상 가운데 이 검증 프로세스가 직접 띄운 것 = CLI.
            let table = await BackgroundLiveTests.processes()
            var pid = related.first(where: { $0.command.hasPrefix(marker) })?.pid ?? 0
            while let row = table.first(where: { $0.pid == pid }), row.ppid != getpid(), row.ppid > 1 { pid = row.ppid }
            guard pid > 1, table.first(where: { $0.pid == pid })?.ppid == getpid() else {
                await t.check("\(label) · \(way): CLI 프로세스 찾기", false, "못 찾음")
                _ = await adapter.shutdown()
                for p in await processes(containing: marker) { kill(p.pid, SIGKILL) }
                return
            }
            kill(pid, SIGSTOP)
        }
        ManagedProcess.cleansDescendants = !old
        let started = Date()
        let ok = await adapter.shutdown()
        ManagedProcess.cleansDescendants = true
        let took = Date().timeIntervalSince(started)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let left = await processes(containing: marker)
        let leftText = left.map { "\($0.pid)(부모 \($0.ppid)) \($0.command.prefix(50))" }.joined(separator: " | ")
        if old {
            await t.note("\(label) · \(way): 끈 뒤 남은 `\(marker)` 관련 프로세스 \(left.count)개"
                         + (left.isEmpty ? " — CLI 가 스스로 정리했다" : ": \(leftText)") + String(format: " (끄기 %.1f초)", took))
        } else {
            await t.check("\(label) · \(way): 끈 뒤 `\(marker)` 와 그 셸이 남지 않는다", left.isEmpty, leftText)
            await t.check("\(label) · \(way): 끄기 결과가 '모두 끝남'", ok, String(format: "%.1f초", took))
        }
        for p in left { kill(p.pid, SIGKILL) }   // 뒷정리
        for _ in 0..<100 where box.finished == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    /// 명령에 `text` 가 든 프로세스 (`ps` — 이 검증 프로세스의 자손이 아니어도. 끈 뒤 launchd 로 넘어간 것도 찾는다).
    private static func processes(containing text: String) async -> [BackgroundLiveTests.Proc] {
        await BackgroundLiveTests.processes().filter { $0.command.contains(text) && !$0.command.hasPrefix("/bin/ps") }
    }

    // MARK: ① 독립 작업 폴더 → 정리 → 이어 묻기

    private static func worktreeResume(_ t: TestKit, _ cli: (claude: String?, codex: String?, env: [String: String])) async {
        await t.group("실측 ①: 독립 작업 폴더에서 이어 쓴 Claude 대화가 정리 뒤에도 이어진다 (실제 앱 모델)")
        guard cli.claude != nil else {
            await t.check("claude CLI 실행 파일 탐색", false, "없음 — 건너뜀")
            return
        }
        let root: URL
        do { root = try TestEnv.makeTempProject("releasefix-worktree") } catch {
            await t.check("임시 폴더", false, "\(error)")
            return
        }
        let folder = root.appendingPathComponent("project", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? "# 실측용 임시 프로젝트\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.invalid"], ["config", "user.name", "t"],
                          ["add", "-A"], ["commit", "-q", "-m", "base"]] {
            _ = await CLIEnvironment.captureOutput(executable: "/usr/bin/git", arguments: arguments, environment: cli.env,
                                                   workingDirectory: folder, timeout: 20)
        }
        setenv("AHC_WORKTREES_DIR", root.appendingPathComponent("worktrees").path, 1)
        // 실제 ~/.claude/projects 에 생긴 이 실측의 칸(프로젝트 폴더 · 독립 작업 폴더)은 끝에 지운다.
        var sessionDirs: Set<URL> = []
        defer {
            unsetenv("AHC_WORKTREES_DIR")
            for dir in sessionDirs { try? FileManager.default.removeItem(at: dir) }
            TestEnv.cleanup(root)
        }
        let projects = ClaudeSessionFiles.projectsDirectory()
        func sessionDir(_ path: String) -> URL? { ClaudeSessionFiles.folderKey(for: path).map { projects.appendingPathComponent($0) } }
        if let dir = sessionDir(folder.path) { sessionDirs.insert(dir) }

        let store = Store(databaseURL: root.appendingPathComponent("handoff.sqlite3"))
        do { try await store.bootstrap() } catch {
            await t.check("저장 계층", false, "\(error)")
            return
        }
        let model = AppModel(store: store)
        await model.bootstrap()
        guard model.bootstrapError == nil else {
            await t.check("앱 모델 부트스트랩", false, model.bootstrapError ?? "")
            return
        }
        model.claudePermissionMode = "acceptEdits"
        model.automaticHandoffEnabled = false
        model.autoThreadTitles = false
        let project = await model.addProject(name: "releasefix", path: folder.path)
        let approver = Task { @MainActor in
            while !Task.isCancelled {
                for session in model.runner.activeSessions {
                    for request in session.pendingApprovals { await model.runner.respond(approval: request, decision: .allow) }
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        defer { approver.cancel() }

        func send(_ text: String, _ thread: ConversationThread) async -> (sent: Bool, run: Run?, answer: String) {
            let sent = await model.send(text, provider: .claude, threadID: thread.id)
            let deadline = Date().addingTimeInterval(240)
            while Date() < deadline {
                if model.runner.session(threadID: thread.id) == nil && !model.isSending(threadID: thread.id)
                    && !model.isFinishingRunChanges { break }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            let run = (try? await store.runs(threadID: thread.id))?.max { $0.startedAt < $1.startedAt }
            let answer = ((try? await store.events(threadID: thread.id)) ?? [])
                .filter { $0.runID == run?.id && $0.kind == .agentMessage && $0.isMainStream }.map(\.text).joined(separator: " ")
            return (sent, run, answer)
        }

        for oldCopy in [false, true] {
            let label = oldCopy ? "예전 동작(정리 뒤 프로젝트 폴더 칸에 옛 사본 그대로)" : "지금 동작"
            var thread = ConversationThread(projectID: project.id, title: label)
            thread.preferredProvider = .claude
            thread.claudeSelection = ModelSelection(model: claudeModel, effort: nil)
            try? await store.upsertThread(thread)
            await model.reloadProjects()
            let first = "PELICAN-\(Int.random(in: 1000...9999))"
            let second = "WALRUS-\(Int.random(in: 1000...9999))"

            let a = await send("Remember this codeword for later: \(first). Do not use any tools. Reply with exactly: OK", thread)
            let sessionID = (try? await store.session(threadID: thread.id, provider: .claude, accountID: ""))?.cliSessionID
            guard a.run?.state == .completed, let sessionID else {
                await t.check("\(label): 첫 턴 (프로젝트 폴더)", false, "\(a.run?.state.rawValue ?? "없음") \(a.run?.errorMessage ?? "")")
                continue
            }
            guard await model.createWorktree(threadID: thread.id),
                  let worktree = model.allThreads().first(where: { $0.id == thread.id })?.worktree else {
                await t.check("\(label): 독립 작업 폴더 만들기", false, model.banner?.text ?? "")
                continue
            }
            if let dir = sessionDir(worktree.path) { sessionDirs.insert(dir) }
            let b = await send("Remember a second codeword for later: \(second). Do not use any tools. Reply with exactly: OK", thread)
            let sessionAfter = (try? await store.session(threadID: thread.id, provider: .claude, accountID: ""))?.cliSessionID
            await t.check("\(label): 독립 작업 폴더에서 같은 세션을 이어 갔다", b.run?.state == .completed && sessionAfter == sessionID,
                          "\(b.run?.state.rawValue ?? "없음") · 세션 \(sessionID.prefix(8)) → \(sessionAfter?.prefix(8) ?? "nil")")
            let projectCopy = sessionDir(folder.path)?.appendingPathComponent(sessionID + ".jsonl")
            let before = projectCopy.flatMap { try? Data(contentsOf: $0) }
            guard await model.removeWorktree(threadID: thread.id, force: false, branch: .deleteIfMerged) else {
                await t.check("\(label): 정리", false, model.banner?.text ?? "")
                continue
            }
            let afterCopy = projectCopy.flatMap { try? Data(contentsOf: $0) }
            if oldCopy, let projectCopy, let before {
                try? before.write(to: projectCopy)   // 예전 copy: 대상이 이미 있으면 그대로 두었다
            } else if !oldCopy {
                await t.check("\(label): 정리 뒤 프로젝트 폴더 칸의 기록이 독립 작업 폴더의 것으로 바뀌었다",
                              (afterCopy?.count ?? 0) > (before?.count ?? 0)
                                && String(decoding: afterCopy ?? Data(), as: UTF8.self).contains(second),
                              "\(before?.count ?? 0) → \(afterCopy?.count ?? 0) 바이트")
            }
            let c = await send("What were the two codewords I asked you to remember in this conversation? "
                               + "Do not use any tools. Reply with only the codewords, separated by a space.", thread)
            let knowsBoth = c.answer.contains(first) && c.answer.contains(second)
            if oldCopy {
                await t.note("\(label): 정리 뒤 답 — \(c.answer.prefix(120)) (\(second) 를 " + (c.answer.contains(second) ? "안다)" : "모른다 — 빠졌다)"))
            } else {
                await t.check("\(label): 정리 뒤에도 두 턴의 내용을 안다 (\(first) · \(second))", c.run?.state == .completed && knowsBoth,
                              "\(c.run?.state.rawValue ?? "없음") · \(c.answer.prefix(120))")
            }
        }
    }

    // MARK: ⑦ 제목 요약의 자격

    private static func titleRoute(_ t: TestKit, _ cli: (claude: String?, codex: String?, env: [String: String])) async {
        await t.group("실측 ⑦: API 크레딧 대화의 제목 요약은 API 키로 · 구독 대화는 구독으로")
        guard let claude = cli.claude else {
            await t.check("claude CLI 실행 파일 탐색", false, "없음 — 건너뜀")
            return
        }
        var request = ThreadTitle.Request(provider: .claude,
                                          input: ThreadTitle.input(firstMessage: "로그인 화면의 버튼 색이 다크 모드에서 안 보여요. 고쳐 주세요.",
                                                                   firstAnswer: nil),
                                          codexModel: nil)
        let plainEnv = ThreadTitle.environment(cli.env, for: request, apiKey: nil) ?? cli.env
        let plainSource = await apiKeySource(claude, env: plainEnv)
        let plain = await ThreadTitle.summarize(request, executable: claude, environment: plainEnv)
        await t.check("구독 대화: 구독 로그인으로 제목을 받는다 (apiKeySource none)", plain != nil && plainSource.source == "none",
                      "제목 \(plain ?? "nil") · apiKeySource \(plainSource.source ?? "미확인")")

        request.viaClaudeAPI = true
        let realKey = ClaudeAPIKey.load()
        let key = realKey ?? ("sk-ant-api03-" + String(repeating: "x", count: 20) + "FAKE" + String(UUID().uuidString.prefix(8)))
        await t.note(realKey == nil ? "키체인에 API 키가 없어 가짜 키로 잽니다 — 성공하면 구독으로 샌 것이다" : "키체인의 API 키로 잽니다")
        guard let keyedEnv = ThreadTitle.environment(cli.env, for: request, apiKey: key) else {
            await t.check("API 대화의 환경", false, "nil")
            return
        }
        let keyedSource = await apiKeySource(claude, env: keyedEnv)
        let keyed = await ThreadTitle.summarize(request, executable: claude, environment: keyedEnv)
        await t.check("API 대화: CLI 가 쓴 자격이 ANTHROPIC_API_KEY", keyedSource.source == "ANTHROPIC_API_KEY",
                      "apiKeySource \(keyedSource.source ?? "미확인") · 결과 \(keyedSource.result.prefix(120))")
        if realKey == nil {
            await t.check("API 대화(가짜 키): 제목을 받지 못한다 — 구독으로 새지 않았다", keyed == nil, keyed ?? "nil")
        } else {
            await t.check("API 대화(진짜 키): 제목을 받는다", keyed != nil, keyed ?? "nil")
        }
        let noKey = ThreadTitle.environment(cli.env, for: request, apiKey: nil)
        await t.check("API 대화인데 키가 없으면 CLI 를 부르지 않는다", noKey == nil)
    }

    /// 그 환경으로 `claude -p` 를 한 번 돌려 CLI 가 밝힌 자격 출처(init 의 `apiKeySource`)와 결과 글. 도구 · MCP · 세션 기록 없이.
    private static func apiKeySource(_ claude: String, env: [String: String]) async -> (source: String?, result: String) {
        let outcome = await CLIEnvironment.captureOutput(
            executable: claude,
            arguments: ["-p", "--model", claudeModel, "--no-session-persistence", "--tools", "", "--strict-mcp-config",
                        "--output-format", "stream-json", "--verbose", "--settings", #"{"alwaysThinkingEnabled":false}"#],
            environment: env, workingDirectory: CLIEnvironment.neutralWorkingDirectory(), stdinLines: ["Reply with exactly: ok"],
            timeout: 60)
        let text: String
        switch outcome {
        case .success(let output): text = output
        case .failure(let message): text = message
        }
        var source: String?
        var result = ""
        for line in text.split(separator: "\n") {
            guard let object = JSONUtil.object(String(line)) else { continue }
            if object["type"] as? String == "system", object["subtype"] as? String == "init" {
                source = object["apiKeySource"] as? String
            }
            if object["type"] as? String == "result" { result = (object["result"] as? String) ?? "" }
        }
        return (source, result)
    }
}
