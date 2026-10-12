import Foundation

// MARK: - 입력창 "/" 목록

/// 입력창 "/" 목록: 순수 판정(`SlashCommands`) · 가짜 CLI 로 목록 받기(`SlashCommandCatalog`) · 앱 흐름(받아 두기 · Codex 스킬 입력 ·
/// Claude "/명령" 앞에 안내를 붙이지 않기). 실제 CLI 를 부르지 않는다.
@MainActor
enum SlashCommandTests {

    static func run(_ t: TestKit) async {
        await pure(t)
        await codexInput(t)
        await fakeCLI(t)
        await adapterCapture(t)
        do { try await appFlow(t) } catch {
            await t.group("앱 흐름: \"/\" 목록")
            await t.check("시나리오 실행 중 예외", false, "\(error)")
        }
    }

    // MARK: 순수

    static func pure(_ t: TestKit) async {
        await t.group("\"/\" 목록: 해석 · 찾기 · 넣기 (순수)")
        let claude = SlashCommands.parseClaude(["commands": [
            ["name": "code-review", "description": "Review the diff\n  for bugs", "argumentHint": " [target] ", "builtin": true],
            ["name": "clear", "description": "새 세션"],
            ["name": "model", "description": "모델"],
            ["name": "color", "description": "터미널 전용"],
            ["name": "__remote-workflow", "description": "내부"],
            ["name": "claude.ai Notion:make-page (MCP)", "description": "빈칸이 든 이름"],
            ["name": "usage", "description": "Show usage", "aliases": ["cost", "stats"]],
            ["name": "anthropic-skills:pdf", "description": "PDF", "builtin": false],
            ["name": "code-review", "description": "겹친 이름"],
        ]])
        await t.equal("Claude: 숨길 것 · 칠 수 없는 이름 · 겹친 이름을 빼고 CLI 의 순서",
                      claude.map(\.name), ["code-review", "usage", "anthropic-skills:pdf"])
        await t.check("Claude: 설명은 한 줄 · 인수 안내는 다듬는다",
                      claude.first?.description == "Review the diff for bugs" && claude.first?.argumentHint == "[target]",
                      "\(String(describing: claude.first))")
        await t.equal("Claude: 다른 이름", claude.first { $0.name == "usage" }?.aliases, ["cost", "stats"])

        let codex = SlashCommands.parseCodexSkills(["data": [
            ["cwd": "/p", "skills": [
                ["name": "pdf:pdf", "description": "긴 설명", "interface": ["shortDescription": "PDF 읽기"],
                 "path": "/s/pdf/SKILL.md", "scope": "user", "enabled": true],
                ["name": "off", "description": "꺼 둔 스킬", "path": "/s/off/SKILL.md", "scope": "user", "enabled": false],
                ["name": "mine", "description": "저장소\n스킬", "path": "/s/mine/SKILL.md", "scope": "repo", "enabled": true],
                ["name": "nopath", "description": "경로 없음", "scope": "user", "enabled": true],
            ]],
            ["cwd": "/q", "skills": [["name": "mine", "description": "다른 폴더의 같은 이름", "path": "/x", "enabled": true]]],
        ]])
        await t.equal("Codex: 켠 스킬만 · 경로가 있는 것만 · 겹친 이름은 처음 것", codex.map(\.name), ["pdf:pdf", "mine"])
        await t.check("Codex: 짧은 설명이 먼저 · 경로를 남긴다",
                      codex.first?.description == "PDF 읽기" && codex.first?.path == "/s/pdf/SKILL.md"
                        && codex.last?.description == "저장소 스킬")

        await t.equal("찾을 말: 맨 앞 \"/\" 뒤 (빈 말 포함)",
                      [SlashCommands.query(in: "/", provider: .claude), SlashCommands.query(in: "/co", provider: .claude)],
                      ["", "co"])
        await t.check("인수를 치기 시작하면 · 줄을 바꾸면 · 경로면 · 맨 앞이 아니면 닫는다",
                      SlashCommands.query(in: "/code-review x", provider: .claude) == nil
                        && SlashCommands.query(in: "/co\n", provider: .claude) == nil
                        && SlashCommands.query(in: "/Users/me", provider: .claude) == nil
                        && SlashCommands.query(in: "보세요 /co", provider: .claude) == nil)
        await t.check("Codex 는 \"$\" 로도 · Claude 는 \"/\" 만 · Antigravity 는 없다",
                      SlashCommands.query(in: "$pd", provider: .codex) == "pd"
                        && SlashCommands.query(in: "/pd", provider: .codex) == "pd"
                        && SlashCommands.query(in: "$pd", provider: .claude) == nil
                        && SlashCommands.query(in: "/boost", provider: .gemini) == nil)

        let list = [SlashCommand(name: "simplify", description: ""),
                    SlashCommand(name: "anthropic-skills:pdf", description: ""),
                    SlashCommand(name: "usage", description: "", aliases: ["cost"]),
                    SlashCommand(name: "security-review", description: ""),
                    SlashCommand(name: "review", description: "")]
        await t.equal("빈 말이면 전부 (CLI 의 순서)", SlashCommands.matches(list, query: "").count, list.count)
        await t.equal("이름 앞 → \":\" 뒤 앞 → 다른 이름 앞 → 이름 속 (대소문자 무시)",
                      SlashCommands.matches(list, query: "RE").map(\.name), ["review", "security-review"])
        await t.equal("플러그인 스킬은 \":\" 뒤로도", SlashCommands.matches(list, query: "pd").map(\.name), ["anthropic-skills:pdf"])
        await t.equal("다른 이름으로도", SlashCommands.matches(list, query: "co").map(\.name), ["usage"])
        await t.check("맞는 것이 없으면 빈 목록", SlashCommands.matches(list, query: "zzz").isEmpty)

        let pdf = SlashCommand(name: "pdf:pdf", description: "", path: "/s/pdf/SKILL.md")
        await t.equal("넣는 글: Claude \"/이름 \" · Codex \"$이름 \"",
                      [SlashCommands.inserted(list[0], provider: .claude), SlashCommands.inserted(pdf, provider: .codex)],
                      ["/simplify ", "$pdf:pdf "])
        await t.check("Claude 명령으로 보는 글: 맨 앞 \"/이름\" (경로 · 빈 이름 · 맨 앞이 아님은 아니다)",
                      SlashCommands.isClaudeInvocation("/code-review 이 브랜치")
                        && SlashCommands.isClaudeInvocation("/anthropic-skills:pdf")
                        && !SlashCommands.isClaudeInvocation("/Users/me/a.txt 를 봐")
                        && !SlashCommands.isClaudeInvocation("/ 혼자")
                        && !SlashCommands.isClaudeInvocation("보세요 /code-review"))

        await t.equal("\"$\" 표시: 이름 글자까지 · 앞이 이름 글자면 아니다",
                      SlashCommands.dollarTokens(in: "$pdf:pdf 로 a$b 를, ($mine) 그리고 $ 혼자"), ["pdf:pdf", "mine"])
        let skills = [pdf, SlashCommand(name: "mine", description: "", path: "/s/mine/SKILL.md"),
                      SlashCommand(name: "nopath", description: "")]
        await t.equal("글 속 스킬: 목록에 있는 것만 · 나온 순서 · 한 번씩 · 문장 끝 마침표를 뗀다",
                      SlashCommands.codexMentions(in: "$mine 다음 $pdf:pdf. 또 $mine, $nope $nopath", skills: skills),
                      [SkillMention(name: "mine", path: "/s/mine/SKILL.md"), SkillMention(name: "pdf:pdf", path: "/s/pdf/SKILL.md")])
        await t.check("\"$\" 가 없으면 스킬을 찾지 않는다", !SlashCommands.mayMentionCodexSkill("가격은 5$ 입니다")
                        && SlashCommands.mayMentionCodexSkill("$pdf 로"))
    }

    // MARK: Codex 입력

    static func codexInput(_ t: TestKit) async {
        await t.group("\"/\" 목록: Codex turn/start 의 스킬 입력")
        let request = AgentTurnRequest(runID: "r", prompt: "$pdf 로 읽어", workingDirectory: URL(fileURLWithPath: "/tmp/p"),
                                       skills: [SkillMention(name: "pdf", path: "/s/pdf/SKILL.md")])
        let input = CodexAdapter.turnParams(for: request, threadID: "th")["input"] as? [[String: Any]] ?? []
        await t.check("글은 그대로 두고 스킬 입력을 덧붙인다",
                      input.count == 2 && input[0]["type"] as? String == "text" && input[0]["text"] as? String == "$pdf 로 읽어"
                        && input[1]["type"] as? String == "skill" && input[1]["name"] as? String == "pdf"
                        && input[1]["path"] as? String == "/s/pdf/SKILL.md", "\(input)")
        let plain = CodexAdapter.turnParams(for: AgentTurnRequest(runID: "r", prompt: "hi",
                                                                  workingDirectory: URL(fileURLWithPath: "/tmp/p")),
                                            threadID: "th")["input"] as? [[String: Any]] ?? []
        await t.equal("스킬이 없으면 글 하나", plain.count, 1)
    }

    // MARK: 가짜 CLI

    static func fakeCLI(_ t: TestKit) async {
        await t.group("\"/\" 목록: 가짜 CLI 로 받기 (Claude initialize · Codex skills/list)")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-slash-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("project")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // 받은 요청의 request_id 를 그대로 돌려주고, 설명에 작업 폴더를 적는다. stdin 이 닫힐 때까지 남는다 (앱이 닫아 끝내는지).
            let claude = try script(root, "claude", """
                read -r line
                id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]+)".*/\\1/')
                printf '%s\\n' '{"type":"system","subtype":"hook_started"}'
                printf '{"type":"control_response","response":{"subtype":"success","request_id":"other","response":{"commands":[]}}}\\n'
                printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"commands":[{"name":"code-review","description":"cwd=%s","argumentHint":"[target]"},{"name":"clear","description":"x"}]}}}\\n' "$id" "$(pwd -P)"
                cat > /dev/null
                """)
            let started = Date()
            let list = await SlashCommandCatalog.fetchClaude(path: claude.path, environment: ["PATH": "/usr/bin:/bin"],
                                                             workingDirectory: folder, timeout: 10)
            // 임시 폴더는 /var → /private/var 링크라 끝부분으로 본다.
            let place = "/" + root.lastPathComponent + "/project"
            await t.check("Claude: 우리 요청의 응답만 · 숨길 것을 빼고 · 그 폴더에서 띄운다",
                          list.commands.map(\.name) == ["code-review"]
                            && list.commands.first?.description.hasSuffix(place) == true && list.message == nil,
                          "\(list.commands) · \(String(describing: list.message))")
            await t.check("Claude: 받은 뒤 stdin 을 닫아 곧 끝낸다 (시간 제한을 기다리지 않는다)",
                          Date().timeIntervalSince(started) < 5, "\(Date().timeIntervalSince(started))초")

            let silent = try script(root, "silent", "cat > /dev/null")
            let timedOut = await SlashCommandCatalog.fetchClaude(path: silent.path, environment: ["PATH": "/usr/bin:/bin"],
                                                                 workingDirectory: folder, timeout: 0.5)
            await t.check("응답이 없으면 빈 목록과 까닭", timedOut.commands.isEmpty && timedOut.message != nil && timedOut.fetchedAt != nil)

            let codex = try script(root, "codex", """
                while read -r line; do
                  case "$line" in
                    *'"skills/list"'*) printf '{"id":2,"result":{"data":[{"cwd":"x","skills":[{"name":"pdf","description":"PDF","path":"/s/pdf/SKILL.md","scope":"user","enabled":true},{"name":"off","description":"d","path":"/s/off/SKILL.md","scope":"user","enabled":false}]}]}}\\n';;
                    *'"initialize"'*) printf '{"id":1,"result":{}}\\n';;
                  esac
                done
                """)
            let skills = await SlashCommandCatalog.fetchCodex(path: codex.path, environment: ["PATH": "/usr/bin:/bin"],
                                                              workingDirectory: folder, timeout: 10)
            await t.check("Codex: skills/list 의 켠 스킬", skills.commands.map(\.name) == ["pdf"]
                            && skills.commands.first?.path == "/s/pdf/SKILL.md", "\(skills.commands) · \(String(describing: skills.message))")
        } catch {
            await t.check("가짜 CLI 준비", false, "\(error)")
        }
    }

    /// 실행마다 어댑터가 보내는 `initialize` 의 응답으로도 목록을 낸다 — 따로 띄우지 않는다.
    static func adapterCapture(_ t: TestKit) async {
        await t.group("\"/\" 목록: Claude 실행의 초기화 응답으로 받기 (가짜 CLI)")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-slash-run-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let claude = try script(root, "claude", """
                read -r line
                id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]+)".*/\\1/')
                printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"commands":[{"name":"code-review","description":"리뷰"},{"name":"clear","description":"x"}]}}}\\n' "$id"
                read -r user
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"s","model":"claude-sonnet-5"}'
                printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"s","duration_ms":10,"usage":{"input_tokens":1,"output_tokens":1}}'
                cat > /dev/null
                """)
            let adapter = ClaudeAdapter(executablePath: claude.path, environment: ["PATH": "/usr/bin:/bin"])
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if !Task.isCancelled { _ = await adapter.shutdown() }
            }
            var lists: [[SlashCommand]] = []
            var finished = false
            for await event in adapter.start(AgentTurnRequest(runID: "r", prompt: "hi", workingDirectory: root)) {
                if case .slashCommands(let commands) = event { lists.append(commands) }
                if case .finished = event { finished = true }
            }
            watchdog.cancel()
            await t.check("초기화 응답의 목록을 한 번 낸다 (숨길 것은 뺀다) · 실행은 그대로 끝난다",
                          lists.map { $0.map(\.name) } == [["code-review"]] && finished, "\(lists) · \(finished)")
        } catch {
            await t.check("가짜 CLI 준비", false, "\(error)")
        }
    }

    private static func script(_ root: URL, _ name: String, _ body: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: 앱 흐름

    static func appFlow(_ t: TestKit) async throws {
        await t.group("앱 흐름: \"/\" 목록 받아 두기 · Codex 스킬 · Claude 명령 앞의 안내")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-slash-app-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
        try await store.bootstrap()
        let project = Project(name: "p", path: folder.path)
        try await store.upsertProject(project)
        var thread = ConversationThread(projectID: project.id, title: "대화")
        thread.claudeSelection = ModelSelection(model: "sonnet", effort: "high")
        try await store.upsertThread(thread)
        try await store.replaceModelOptions(
            [AgentModelOption(provider: .claude, identifier: "sonnet", displayName: "Sonnet 5",
                              supportedEfforts: ModelCatalog.claudeEfforts, isDefault: true, isDiscovered: true)], scope: .claude)

        let model = AppModel(store: store)
        final class Box { var fetches: [SlashCommandKey] = []; var fail = false; var adapters: [ScriptedAgentAdapter] = [] }
        let box = Box()
        model.slashCommandFetchOverride = { key in
            box.fetches.append(key)
            if box.fail { return SlashCommandList(fetchedAt: Date(), message: "목록을 받지 못했습니다: 꺼짐") }
            return SlashCommandList(commands: key.provider == .codex
                                        ? [SlashCommand(name: "pdf", description: "PDF", path: "/s/pdf/SKILL.md")]
                                        : [SlashCommand(name: "code-review", description: "리뷰")],
                                    fetchedAt: Date())
        }
        let done = AgentTurnResult(state: .completed, terminalReason: "completed", sessionID: "s")
        let fromRun = [SlashCommand(name: "from-run", description: "실행이 알려 준 스킬")]
        model.runner.adapterFactory = { provider in
            let adapter = ScriptedAgentAdapter(provider: provider) { _ in
                [.emit(.slashCommands(fromRun)),
                 .emit(.sessionEstablished(sessionID: "s", model: "fake", cliVersion: nil)), .finish(done)]
            }
            box.adapters.append(adapter)
            return adapter
        }
        await model.reloadProjects()
        guard let loaded = model.allThreads().first(where: { $0.id == thread.id }) else {
            await t.check("대화를 읽었다", false)
            return
        }
        thread = loaded

        await t.check("Antigravity 는 목록이 없다", model.slashCommandKey(thread: thread, provider: .gemini) == nil)
        guard let key = model.slashCommandKey(thread: thread, provider: .claude),
              let codexKey = model.slashCommandKey(thread: thread, provider: .codex) else {
            await t.check("키를 만든다", false)
            return
        }
        await t.check("키: 에이전트 · 대화의 폴더 (Codex 는 그 계정)",
                      key.folder == folder.path && key.accountID.isEmpty && codexKey.accountID == thread.codexAccountID)
        await model.refreshSlashCommandsIfStale(key)
        await model.refreshSlashCommandsIfStale(key)
        await t.check("한 번 받으면 오래되기 전에는 다시 받지 않는다",
                      box.fetches == [key] && model.slashCommandLists[key]?.commands.map(\.name) == ["code-review"])
        await model.refreshSlashCommandsIfStale(key, now: Date().addingTimeInterval(SlashCommands.staleAfter + 1))
        await t.equal("오래되면 다시 받는다", box.fetches.count, 2)
        box.fail = true
        await model.refreshSlashCommands(key)
        await t.check("받지 못하면 지난 목록을 남기고 까닭을 적는다",
                      model.slashCommandLists[key]?.commands.map(\.name) == ["code-review"]
                        && model.slashCommandLists[key]?.message?.contains("꺼짐") == true
                        && model.loadingSlashCommands.isEmpty)
        box.fail = false

        let mentions = await model.codexSkillMentions(in: "$pdf 로 읽고 $nope", thread: thread)
        await t.check("Codex: 받아 둔 목록이 없으면 먼저 받아 글 속 스킬을 찾는다",
                      mentions == [SkillMention(name: "pdf", path: "/s/pdf/SKILL.md")] && box.fetches.last == codexKey,
                      "\(mentions)")
        let before = box.fetches.count
        let none = await model.codexSkillMentions(in: "그냥 글", thread: thread)
        await t.check("\"$\" 가 없으면 목록을 받지 않는다", none.isEmpty && box.fetches.count == before)

        // Claude: 맨 앞 "/명령" 이면 작업 폴더 안내를 붙이지 않고 다음 턴으로 미룬다.
        let noteKey = AppModel.folderMoveKey(thread.id, .claude)
        model.folderMoveNotes[noteKey] = "[앱 안내] 폴더가 바뀌었습니다"
        func waitIdle() async {
            for _ in 0..<500 where model.runner.session(threadID: thread.id) != nil || model.isStartingRun(threadID: thread.id) {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let sentCommand = await model.send("/code-review 이 브랜치", provider: .claude, threadID: thread.id)
        await waitIdle()
        let first = box.adapters.flatMap(\.requests).last
        await t.check("실행의 초기화 응답에 온 목록이 그 폴더의 목록이 된다 (따로 받지 않는다)",
                      model.slashCommandLists[key]?.commands == fromRun && model.slashCommandLists[key]?.message == nil,
                      "\(String(describing: model.slashCommandLists[key]))")
        await t.check("\"/명령\" 은 글 그대로 보내고 안내는 남겨 둔다",
                      sentCommand && first?.prompt == "/code-review 이 브랜치" && model.folderMoveNotes[noteKey] != nil,
                      "\(String(describing: first?.prompt))")
        let sentPlain = await model.send("이어서 해줘", provider: .claude, threadID: thread.id)
        await waitIdle()
        let second = box.adapters.flatMap(\.requests).last
        await t.check("다음 보통 메시지에 안내를 붙이고 지운다",
                      sentPlain && second?.prompt.hasPrefix("[앱 안내] 폴더가 바뀌었습니다") == true
                        && second?.prompt.hasSuffix("이어서 해줘") == true && model.folderMoveNotes[noteKey] == nil,
                      "\(String(describing: second?.prompt))")

        // 저장 · 되살리기: 앱을 다시 켜도 첫 "/" 에서 바로 보인다.
        var saved: String?
        for _ in 0..<100 {
            saved = try? await store.setting("slash_commands")
            if saved?.contains("from-run") == true { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let reopened = AppModel(store: store)
        reopened.restoreSlashCommands(saved ?? "")
        await t.check("저장한 목록을 다시 켠 앱이 되살린다 (받은 때 포함)",
                      reopened.slashCommandLists[key]?.commands == fromRun && reopened.slashCommandLists[key]?.fetchedAt != nil
                        && reopened.slashCommandLists[codexKey]?.commands.map(\.name) == ["pdf"],
                      String(describing: saved?.prefix(200)))
        await store.db.close()
    }
}
