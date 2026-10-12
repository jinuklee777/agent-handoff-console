import Foundation

// MARK: - 첫 실행 점검표

@MainActor
enum FirstRunTests {

    static func run(_ t: TestKit) async {
        await steps(t)
        await recheck(t)
        await codexJudge(t)
        await folders(t)
        await loginPath(t)
        await gitShim(t)
        await app(t)
        await deferredClaude(t)
        await settingsAgents(t)
        await pathField(t)
        await settingsNotes(t)
        await latePathCheck(t)
        await offlineGuards(t)
        await firstAgentWait(t)
        await waitsForFacts(t)
        await runFailure(t)
        await loginTrouble(t)
        await notificationGate(t)
        await notificationApp(t)
    }

    /// 설정 > 에이전트의 실행 파일 칸 (set-n1): 사람이 고친 글만 옮기고, 밖에서 바뀐 경로([자동으로 찾기로 되돌리기])를 칸에 남은 옛 글로
    /// 다시 덮지 않는다 (macOS 는 ↵ 뒤에도 칸이 포커스를 갖고, 단추를 눌러도 포커스가 옮지 않는다).
    static func pathField(_ t: TestKit) async {
        await t.group("설정 > 에이전트: 실행 파일 칸 — 되돌린 뒤 칸의 옛 글로 다시 저장하지 않는다")
        var field = ExecutablePathField(path: "")
        field.draft = "/틀린/claude"
        await t.equal("↵ — 고친 글을 저장할 경로로", field.commit(current: ""), "/틀린/claude")
        await t.check("↵ 뒤 (칸은 포커스를 가진 채) 고친 것이 없다", !field.isEdited)
        field.pathChanged(to: "")   // [자동으로 찾기로 되돌리기]
        await t.equal("되돌리면 칸도 비운다 (칸의 포커스와 상관없이)", field.draft, "")
        await t.check("그 뒤 칸을 떠나거나 창을 닫아도 틀린 경로를 다시 저장하지 않는다",
                      field.commit(current: "") == nil && field.draft == "" && field.synced == "")
        // 되돌리기도 다시 확인을 시작한다 — 같은 화면 갱신에서 편집 끝(다시 확인 시작)이 칸이 되돌리기를 받기 전에 불려도 밖의 값이 이긴다.
        var racing = ExecutablePathField(path: "/틀린/claude")
        racing.draft = "/고치던/claude"
        await t.check("되돌리기를 받기 전에 편집 끝이 와도 고치던 글을 저장하지 않는다 — 칸은 되돌린 값",
                      racing.commit(current: "") == nil && racing.draft == "" && racing.synced == "")
        var typed = ExecutablePathField(path: "")
        typed.draft = "  ~/bin/claude  "
        await t.equal("↵ 없이 ↻ (다시 확인이 시작됨) — 고친 글을 먼저 옮긴다 (앞뒤 공백 · ~)",
                      typed.commit(current: ""), NSHomeDirectory() + "/bin/claude")
        var spaces = ExecutablePathField(path: "/usr/local/bin/claude")
        spaces.draft = " /usr/local/bin/claude "
        await t.check("공백만 덧붙였으면 고친 것이 아니다 — 칸을 저장된 값으로",
                      spaces.commit(current: "/usr/local/bin/claude") == nil && spaces.draft == "/usr/local/bin/claude")
    }

    /// 설정의 설명이 실제 동작을 말한다 — 알림(set-n10: 앱이 앞에 있고 그 대화가 보이면 알리지 않는다) · 기본 추론 강도(set-n2: 이미 쓴
    /// 대화는 바꿔도 그대로).
    static func settingsNotes(_ t: TestKit) async {
        await t.group("설정의 설명: 알림 · 기본 추론 강도")
        let onScreen = NotificationGate.decide(enabled: true, authorized: true, canAsk: false, appActive: true, threadOnScreen: true)
        await t.check("알림: 앱이 앞에 있고 그 대화가 보이면 알리지 않는다고 말한다 (판정과 같은 규칙)",
                      SettingsText.notificationsNote.contains("보이면 알리지 않습니다") && onScreen == .skip(.onScreen),
                      SettingsText.notificationsNote)
        for provider in [AgentProvider.claude, .codex] {
            let note: String = SettingsText.defaultEffortNote(provider: provider)
            await t.check("기본 추론 강도(\(provider.displayName)): 이미 쓴 대화는 그대로 · '처음 쓸 때만' 이라 하지 않는다",
                          note.contains("이미 쓴 대화는 이 값을 바꿔도 그대로") && !note.contains("처음 쓸 때만"), note)
        }
        await t.check("Codex 의 설명만 '모델 기본값' 을 말한다",
                      SettingsText.defaultEffortNote(provider: .codex).contains("모델 기본값")
                        && !SettingsText.defaultEffortNote(provider: .claude).contains("모델 기본값"))
    }

    /// 실행 파일 경로를 바꾸는 사이 늦게 끝난 옛 경로의 확인 (set-n7): 그 결과는 화면(`cliStatus`) · 캐시에 쓰지 않는다 — 바꾼 경로의
    /// 확인이 뒤에 쓴다. 옛 경로는 `--version` 에 1초 걸리는 가짜 codex, 새 경로는 곧바로 답하는 가짜 codex.
    static func latePathCheck(_ t: TestKit) async {
        await t.group("설정 > 에이전트: 경로를 바꾼 뒤 늦게 끝난 옛 확인이 새 결과를 덮지 않는다")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-late-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let slow = root.appendingPathComponent("slow-codex")
            let fast = root.appendingPathComponent("fast-codex")
            try "#!/bin/sh\nsleep 1\necho slow-1.0\n".write(to: slow, atomically: true, encoding: .utf8)
            try "#!/bin/sh\necho fast-2.0\n".write(to: fast, atomically: true, encoding: .utf8)
            for url in [slow, fast] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
            let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
            try await store.bootstrap()
            let model = AppModel(store: store)
            model.codexPathOverride = slow.path
            await model.pathChangeTasks[.codex]?.value
            // 옛 경로의 확인이 도는 중에(--version 1초) 경로를 바꾼다.
            let refresh = Task { await model.refreshAgentFacts(force: true, only: [.codex]) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            model.codexPathOverride = fast.path
            await model.pathChangeTasks[.codex]?.value
            await refresh.value
            await t.check("늦게 끝난 옛 경로의 결과는 화면에 쓰지 않는다",
                          model.cliStatus[.codex]?.resolvedPath != slow.path, "\(String(describing: model.cliStatus[.codex]))")
            let cached = await model.environment.checkStatus(.codex)
            await t.check("캐시에도 넣지 않는다 — 다음 확인은 새 경로",
                          cached.resolvedPath == fast.path && cached.version == "fast-2.0", "\(cached)")
            await model.refreshAgentFacts(force: true, only: [.codex])
            await t.check("새 경로의 확인은 쓴다", model.cliStatus[.codex]?.resolvedPath == fast.path
                            && model.cliStatus[.codex]?.version == "fast-2.0")
            await model.store.db.close()
        } catch {
            await t.check("늦은 확인 시험 준비", false, "\(error)")
        }
    }

    /// 설정 > 에이전트 (G6): 카드마다의 다시 확인 · 실행 파일 경로 글 · 버전 글 · Codex 계정 추가/해제 결과 · 새로 로그인한 계정의 모델 목록 ·
    /// Antigravity 의 네트워크 조회(`agy models`)는 쓸 때만. CLI 는 오프라인 하네스의 없는 경로 · 가짜 agy 만 쓴다.
    static func settingsAgents(_ t: TestKit) async {
        await t.group("설정 > 에이전트: 다시 확인 · 경로 · 계정 · 네트워크 조회")
        // set-23: 버전은 짧게 — 카드 머리에 이름이 이미 있다.
        await t.equal("Claude 버전 원문 → v숫자", AgentVersionText.short("2.1.283 (Claude Code)"), "v2.1.283")
        await t.equal("Codex 버전 원문 → v숫자", AgentVersionText.short("codex-cli 0.157.1"), "v0.157.1")
        await t.equal("꼬리표가 붙은 버전", AgentVersionText.short("agy 1.2.2-beta.1"), "v1.2.2-beta.1")
        await t.equal("모르는 형식은 그대로", AgentVersionText.short("nightly"), "nightly")
        await t.check("버전이 없으면 nil", AgentVersionText.short(nil) == nil)
        await t.check("빈 버전도 nil", AgentVersionText.short("  ") == nil)

        // set-1: 다시 확인하는 동안은 옛 결과를 새 경로와 섞어 보이지 않는다.
        let usable = CLIStatus(provider: .claude, resolvedPath: NSHomeDirectory() + "/bin/claude", version: "2.1", executable: true)
        await t.equal("확인 중이면 '확인 중' (옛 경로를 '직접 지정' 으로 붙이지 않는다)",
                      ExecutablePathText.summary(status: usable, override: "/new/claude", checking: true), "확인 중")
        await t.equal("자동으로 찾은 경로", ExecutablePathText.summary(status: usable, override: "", checking: false), "~/bin/claude · 자동으로 찾음")
        await t.equal("지정한 경로를 실행할 수 없음",
                      ExecutablePathText.summary(status: CLIStatus(provider: .claude), override: "/x", checking: false), "실행할 수 없음")
        await t.equal("확인 전", ExecutablePathText.summary(status: nil, override: "", checking: false), "확인 전")
        await t.equal("자동으로 찾았지만 돌지 않는 파일도 '실행할 수 없음' (찾지 못함이 아니다)",
                      ExecutablePathText.summary(status: CLIStatus(provider: .claude, resolvedPath: "/x/claude", executable: false),
                                                 override: "", checking: false), "실행할 수 없음")
        await t.equal("어디서도 찾지 못함", ExecutablePathText.summary(status: CLIStatus(provider: .claude), override: "", checking: false), "찾지 못함")
        await t.equal("경로 칸의 ~ · 앞뒤 공백", ExecutablePathText.normalized("  ~/bin/claude \n"), NSHomeDirectory() + "/bin/claude")
        await t.equal("빈 칸은 자동으로 찾기", ExecutablePathText.normalized("   "), "")

        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-settings-agents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
            try await store.bootstrap()
            let model = AppModel(store: store)
            await model.accounts.load()
            model.limits.setCodexAccounts(model.accounts.refs)

            // set-16: 다시 확인의 "확인 중" 은 그 제공자만 · 겹친 확인은 마지막 것이 끝날 때 빠진다.
            let first = model.beginAgentRecheck([.codex])
            let second = model.beginAgentRecheck([.codex])
            model.endAgentRecheck([.codex], serial: first)
            await t.check("앞의 확인이 먼저 끝나도 뒤의 확인이 돌면 그대로 확인 중", model.recheckingAgents == [.codex])
            model.endAgentRecheck([.codex], serial: second)
            await t.check("마지막 확인이 끝나면 빠진다", model.recheckingAgents.isEmpty)
            await model.recheckAgent(.gemini)
            await t.check("한 제공자 다시 확인: 끝나면 확인 중이 아니고 그 제공자의 사실이 있다 (오프라인 하네스 — 찾지 못함)",
                          model.recheckingAgents.isEmpty && model.cliStatus[.gemini]?.isUsable == false)
            // 부트스트랩 전(이 하네스)의 경로 바꿈은 확인 중으로 두지 않는다 — 앱에서는 그 제공자만 다시 확인한다.
            model.codexPathOverride = "/없는/codex"
            await t.check("부트스트랩 전 경로 바꿈은 확인 중이 아니다", model.recheckingAgents.isEmpty)
            model.codexPathOverride = ""

            // set-2: 계정 추가 · 해제의 결과는 돌려준다 (설정 창이 그 자리에 보인다) — 메인 창 배너로 보내지 않는다.
            let home = root.appendingPathComponent("codex-new")
            let added = await model.addCodexAccount(homePath: home.path, label: "시험")
            await t.check("새 폴더 계정: 결과는 성공 · 로그인 안내 · 배너는 그대로",
                          !added.isError && added.text.contains("아직 로그인하지 않았습니다") && model.banner == nil, added.text)
            let mode = (try? FileManager.default.attributesOfItem(atPath: home.path)[.posixPermissions]) as? NSNumber
            await t.equal("없는 폴더는 앱이 만든다 (권한 700)", mode?.intValue, 0o700)
            let duplicate = await model.addCodexAccount(homePath: home.path + "/", label: "또")
            await t.check("이미 등록된 폴더는 실패 결과 (시트가 닫히지 않고 그 아래에 보인다)",
                          duplicate.isError && duplicate.text.contains("이미 등록된") && model.banner == nil, duplicate.text)

            // set-9: 막 로그인된 계정 · 목록이 빈 계정은 모델 목록을 읽는다.
            guard let account = model.accounts.accounts.first(where: { $0.label == "시험" }) else {
                return await t.check("추가한 계정", false)
            }
            model.cliStatus[.codex] = CLIStatus(provider: .codex, resolvedPath: "/bin/echo", executable: true)
            await t.check("로그인 전에는 모델 목록을 읽지 않는다", !model.codexAccountNeedsModels(account.id, before: .notLoggedIn))
            try #"{"tokens":{"access_token":"x"}}"#.write(to: home.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
            await model.accounts.refreshIdentity(account.id)
            await t.check("막 로그인됐으면 읽는다", model.codexAccountNeedsModels(account.id, before: .notLoggedIn))
            await t.check("로그인돼 있고 목록이 비었으면 읽는다", model.codexAccountNeedsModels(account.id, before: .ready))
            var catalog = ModelCatalogSnapshot(provider: .codex, accountID: account.id)
            catalog.options = ModelCatalog.parseCodexModels([["id": "gpt-6-sol", "displayName": "GPT-6 Sol"]])
            model.modelCatalogs[account.scope] = catalog
            await t.check("목록이 있으면 다시 읽지 않는다", !model.codexAccountNeedsModels(account.id, before: .ready))
            model.cliStatus[.codex] = CLIStatus(provider: .codex)
            await t.check("Codex CLI 를 쓸 수 없으면 읽지 않는다", !model.codexAccountNeedsModels(account.id, before: .notLoggedIn))
            model.cliStatus[.codex] = nil

            let removed = await model.removeCodexAccount(account.id)
            let removedText: String = removed.text
            await t.check("등록 해제의 결과도 돌려준다 · 배너는 그대로", !removed.isError && model.banner == nil, removedText)
            await t.check("등록 해제 글: 해제했다 · 폴더는 그대로", removedText.contains("등록을 해제했습니다") && removedText.contains("폴더"), removedText)
            await t.check("등록 해제 글에 '스레드' 를 쓰지 않는다", !removedText.contains("스레드"), removedText)

            // set-20: Antigravity 모델 목록(`agy models` — Google 과 통신)은 허용한 프로젝트가 있을 때만 시작할 때 읽는다.
            await t.check("허용한 프로젝트가 없으면 Antigravity 목록을 읽지 않는다",
                          !model.catalogScopesToRefresh(skippingClaude: false).contains(.gemini))
            await t.check("새 사용자(미룸)는 Claude 목록도 건너뛴다",
                          !model.catalogScopesToRefresh(skippingClaude: true).contains(.claude))
            model.setAntigravityAllowed(true, projectID: "p")
            await t.check("허용하면 목록이 없을 때 읽는다", model.catalogScopesToRefresh(skippingClaude: false).contains(.gemini))
            var gemini = ModelCatalog.parseGeminiModelResponse("gemini-3.8-flash-high\tGemini 3.8 Flash (High)",
                                                               into: ModelCatalogSnapshot(provider: .gemini))
            gemini.fetchedAt = Date()
            model.modelCatalogs[.gemini] = gemini
            await t.check("하루 안에 읽은 목록은 다시 읽지 않는다", !model.catalogScopesToRefresh(skippingClaude: false).contains(.gemini))
            model.setAntigravityAllowed(false, projectID: "p")

            // set-20: Gemini 로 다듬기를 고르지 않았으면 `agy models` 를 부르지 않는다 (경로 · 버전만).
            let bin = root.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let log = root.appendingPathComponent("agy.log")
            let agy = bin.appendingPathComponent("agy")
            let script = """
            #!/bin/sh
            echo "$1" >> '\(log.path)'
            case "$1" in
              --version) echo "1.2.2-stub"; exit 0 ;;
              models) echo "gemini-3.8-flash-high"; exit 0 ;;
            esac
            exit 1
            """
            try script.write(to: agy, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agy.path)
            model.geminiPathOverride = agy.path
            for _ in 0..<100 where model.geminiCLIPath == nil || model.isRefreshingGemini {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let calls = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            await t.check("경로를 바꾸면 버전만 확인 · 목록(agy models)은 부르지 않는다",
                          model.geminiCLIPath == agy.path && !calls.contains("models") && model.geminiModels.isEmpty, calls)
            model.geminiSummaryEnabled = true
            await model.refreshGeminiStatus()
            let after: String = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            await t.check("Gemini 로 다듬기를 고르면 목록을 읽는다 (agy models)", after.contains("models"), after)
            let models: [String] = model.geminiModels
            await t.equal("요약 모델 목록", models, ["gemini-3.8-flash-high"])
            await t.equal("요약 모델 기본값", model.geminiModel, "gemini-3.8-flash-high")
            model.geminiPathOverride = ""

            // set-17: 독립 작업 폴더를 만드는 곳은 설정 > 고급에서 바꾼다 (새로 만드는 것부터) — 환경 변수가 있으면 그것이 먼저.
            let chosenBefore = Worktrees.userBaseDirectory
            defer { Worktrees.userBaseDirectory = chosenBefore }
            model.worktreesDirectoryOverride = "~/wt-elsewhere"
            await t.equal("설정의 위치를 쓴다 (~ 를 푼다)", Worktrees.baseDirectory(environment: [:]).path, NSHomeDirectory() + "/wt-elsewhere")
            await t.equal("환경 변수 AHC_WORKTREES_DIR 가 먼저",
                          Worktrees.baseDirectory(environment: ["AHC_WORKTREES_DIR": "/tmp/wt"]).path, "/tmp/wt")
            model.worktreesDirectoryOverride = ""
            await t.check("비우면 기본 위치", Worktrees.baseDirectory(environment: [:]).path.hasSuffix("/.agent-handoff-console/worktrees"))
            await store.db.close()
        } catch {
            await t.check("설정 > 에이전트 시험 중 예외", false, "\(error)")
        }
    }

    private static func facts(claude: AgentReadiness = .ready, codex: AgentReadiness = .ready,
                              antigravity: AgentReadiness = .notInstalled,
                              notifications: NotificationPermission = .authorized, badges: Bool? = true,
                              git: GitToolsPresence = .present, projects: Int = 0) -> FirstRunFacts {
        var facts = FirstRunFacts()
        facts.claude.readiness = claude
        facts.codex.readiness = codex
        facts.codex.accountID = "acct"
        facts.antigravity.readiness = antigravity
        facts.notifications = notifications
        facts.badgesEnabled = badges
        facts.git = git
        facts.projectCount = projects
        return facts
    }

    /// 사실 조합 → 단계 · 다음 할 일 · 첫 대화의 에이전트.
    static func steps(_ t: TestKit) async {
        await t.group("점검표: 사실 → 단계")
        let ready = FirstRunChecklist(facts())
        await t.equal("모두 준비 · 프로젝트 없음: ①② 끝 · ③ 할 일 · 다음은 폴더",
                      [ready.state(.agents), ready.state(.notifications), ready.state(.folder)], [.done, .done, .todo])
        await t.equal("다음 할 일 = 작업할 폴더", ready.next, .folder)
        await t.check("첫 대화는 로그인된 Claude", ready.readyAgent.map { $0.provider == .claude && $0.codexAccountID == nil } == true)

        let none = FirstRunChecklist(facts(claude: .notLoggedIn, codex: .notInstalled))
        await t.equal("Claude 미로그인 · Codex 미설치: ① 할 일 · 다음은 에이전트", [none.state(.agents)], [.todo])
        await t.equal("다음 할 일 = 에이전트", none.next, .agents)
        await t.check("①이 끝나지 않아도 ③(폴더 열기)은 막지 않는다", none.canOpenFolder && none.state(.folder) == .todo)
        await t.check("준비된 에이전트가 없으면 readyAgent 는 nil (그때는 initialAgent)", none.readyAgent == nil)
        await t.check("새 폴더: 대화가 없으면(첫 실행) readyAgent, 있으면 nil (initialAgent 가 정한다)",
                      ready.agentForNewFolder(hasConversations: false)?.provider == .claude
                        && ready.agentForNewFolder(hasConversations: true) == nil)

        let unknown = FirstRunChecklist(facts(claude: .loginUnknown, codex: .notInstalled))
        await t.equal("로그인 모름은 통과 (황색 안내)", unknown.state(.agents), .doneWithNote)
        await t.check("로그인 모름도 첫 대화의 에이전트가 된다", unknown.readyAgent?.provider == .claude)
        await t.check("다음 할 일은 에이전트가 아니다", unknown.next == .folder)

        let codexOnly = FirstRunChecklist(facts(claude: .notInstalled, codex: .ready))
        await t.check("Codex 만: 그 계정으로", codexOnly.readyAgent.map { $0.provider == .codex && $0.codexAccountID == "acct" } == true)
        let mixed = FirstRunChecklist(facts(claude: .loginUnknown, codex: .ready))
        await t.check("확인된 Codex 가 로그인 모르는 Claude 보다 먼저", mixed.readyAgent?.provider == .codex)
        await t.equal("확인된 것과 모르는 것이 섞이면 통과 + 안내", mixed.state(.agents), .doneWithNote)

        let checking = FirstRunChecklist(facts(claude: .checking, codex: .checking))
        await t.equal("확인 중", checking.state(.agents), .checking)
        await t.check("확인 중은 할 일로 강조하지 않는다", checking.next == .folder)
        let onlyAgy = FirstRunChecklist(facts(claude: .notInstalled, codex: .notInstalled, antigravity: .loginUnknown))
        await t.check("Antigravity 는 선택 — ①을 통과시키지 않고 첫 대화도 아니다",
                      onlyAgy.state(.agents) == .todo && onlyAgy.readyAgent == nil)
        let badPath = FirstRunChecklist(facts(claude: .pathInvalid, codex: .notInstalled))
        await t.check("설정의 경로 오류는 할 일 (설치 안 됨과 따로) · 첫 대화가 아니다",
                      badPath.state(.agents) == .todo && badPath.next == .agents && badPath.readyAgent == nil)

        await t.equal("알림: 묻지 않음 · 거부 · 읽지 못함 · 읽기 전 · 배지 꺼짐",
                      [FirstRunChecklist(facts(notifications: .notDetermined)).state(.notifications),
                       FirstRunChecklist(facts(notifications: .denied)).state(.notifications),
                       FirstRunChecklist(facts(notifications: .unknown)).state(.notifications),
                       FirstRunChecklist(facts(notifications: .checking)).state(.notifications),
                       FirstRunChecklist(facts(badges: false)).state(.notifications)],
                      [.todo, .todo, .todo, .checking, .doneWithNote])
        await t.check("알림 서비스는 처음 읽기 전에 '확인 중' (읽지 못함이 아니다)", NotificationService().permission == .checking)
        let withProject = FirstRunChecklist(facts(notifications: .denied, projects: 2))
        await t.equal("프로젝트가 있으면 ③ 끝 · 알림이 남았으면 다음은 알림", [withProject.state(.folder)], [.done])
        await t.equal("다음 할 일 = 알림 (폴더 뒤)", withProject.next, .notifications)
        await t.check("모두 끝나면 다음 할 일 없음", FirstRunChecklist(facts(projects: 1)).next == nil)

        await t.check("로그인이 아님 · 모름 · 설치 안 됨 · 경로 오류 → 확인됨이면 다시 읽는다",
                      [AgentReadiness.notLoggedIn, .loginUnknown, .notInstalled, .pathInvalid]
                        .allSatisfy { FirstRunChecklist.becameReady(from: $0, to: .ready) })
        await t.check("처음 확인(확인 중 → 확인됨) · 그대로 · 나빠짐은 세지 않는다",
                      !FirstRunChecklist.becameReady(from: .checking, to: .ready)
                        && !FirstRunChecklist.becameReady(from: .ready, to: .ready)
                        && !FirstRunChecklist.becameReady(from: .ready, to: .notLoggedIn))

        #if DEBUG
        await t.check("미리보기 사실: 경로 오류 · 알림 읽기 전",
                      FirstRunFacts.preview("codex=badpath,notify=checking").codex.readiness == .pathInvalid
                        && FirstRunFacts.preview("notify=checking").notifications == .checking)
        let preview = FirstRunFacts.preview("claude=nologin,codex=missing,notify=denied,badge=off,git=no,agy=unknown")
        await t.check("미리보기 사실 해석",
                      preview.claude.readiness == .notLoggedIn && preview.codex.readiness == .notInstalled
                        && preview.codex.path == nil && preview.notifications == .denied && preview.badgesEnabled == false
                        && preview.git == .missing && preview.antigravity.readiness == .loginUnknown
                        && preview.antigravity.path != nil)
        await t.check("미리보기 기본은 준비된 사실", FirstRunFacts.preview(nil).claude.readiness == .ready
                        && FirstRunFacts.preview("").notifications == .authorized)
        #endif
        await t.check("알림 설정 URL 은 이 앱의 항목",
                      AppModel.notificationSettingsURL(bundleID: "a.b")?.absoluteString
                        == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=a.b")
        await t.check("파일 메뉴 \"프로젝트 폴더 열기… ⌘O\" 는 단축키 표에 있다 (겹침 검사 대상)",
                      MenuShortcut.openProjectFolder.symbol == "⌘O" && MenuShortcut.appMenu.contains(.openProjectFolder)
                        && MenuShortcut.conflicts(MenuShortcut.appMenu + MenuShortcut.system + MenuShortcut.inView).isEmpty)
    }

    /// 앱이 다시 앞에 올 때의 다시 확인 (`FirstRunRecheck`).
    static func recheck(_ t: TestKit) async {
        await t.group("점검표: 앱이 다시 앞에 올 때")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let settled = facts(projects: 1)
        await t.check("모두 확인됨 · 점검표가 안 보이면 하지 않는다",
                      FirstRunRecheck.providers(facts: settled, checklistVisible: false, lastRun: nil, now: now) == nil)
        await t.equal("점검표가 보이면 한다 (준비된 제공자는 강제하지 않는다)",
                      FirstRunRecheck.providers(facts: settled, checklistVisible: true, lastRun: nil, now: now), [])
        let missing = facts(claude: .notLoggedIn, codex: .ready, projects: 1)
        await t.equal("모르는 · 부정인 사실이 있으면 준비 안 된 제공자만",
                      FirstRunRecheck.providers(facts: missing, checklistVisible: false, lastRun: nil, now: now), [.claude])
        // 로그인 문제가 아닌 끝나지 않은 사실(설정 경로 오류 · 설치 안 됨)은 15초에 한 번.
        let unsettled = facts(claude: .pathInvalid, codex: .notInstalled, projects: 1)
        await t.check("15초 안에는 다시 하지 않는다 (로그인 필요가 없을 때)",
                      FirstRunRecheck.providers(facts: unsettled, checklistVisible: true, lastRun: now.addingTimeInterval(-10), now: now) == nil
                        && FirstRunRecheck.providers(facts: unsettled, checklistVisible: true, lastRun: now.addingTimeInterval(-16), now: now) != nil)
        // onb-11: "로그인 필요" 는 15초를 기다리지 않는다 (3초에 한 번, 그 제공자만) — 터미널에서 로그인하고 곧 돌아와도 바뀌게.
        await t.equal("15초 안이라도 로그인 필요인 제공자만 다시 본다",
                      FirstRunRecheck.providers(facts: missing, checklistVisible: true, lastRun: now.addingTimeInterval(-10), now: now), [.claude])
        await t.check("3초 안에는 로그인도 다시 보지 않는다",
                      FirstRunRecheck.providers(facts: missing, checklistVisible: true, lastRun: now.addingTimeInterval(-2), now: now) == nil)
        await t.equal("알림 거부만 남았으면 에이전트는 두고 (빈 집합)",
                      FirstRunRecheck.providers(facts: facts(notifications: .denied, projects: 1), checklistVisible: false,
                                                lastRun: nil, now: now), [])
        // 하나만 쓰는 사람: ①이 끝났으면 남은 쪽의 "설치 안 됨" 은 끝나지 않은 사실이 아니다 (활성화마다 전체 확인이 돌지 않게).
        let claudeOnly = facts(claude: .ready, codex: .notInstalled, projects: 1)
        await t.check("Claude 만 쓰는 사람(Codex 설치 안 됨 · 나머지 준비)은 다시 확인하지 않는다",
                      !claudeOnly.hasUnsettledFact
                        && FirstRunRecheck.providers(facts: claudeOnly, checklistVisible: false, lastRun: nil, now: now) == nil)
        await t.check("Codex 만 쓰는 사람(Claude 경로 오류도 ①이 끝났으면)도 마찬가지",
                      !facts(claude: .notInstalled, codex: .ready, projects: 1).hasUnsettledFact)
        await t.check("로그인 모름은 통과 — 그것만으로 다시 확인하지 않는다",
                      !facts(claude: .loginUnknown, codex: .notInstalled, projects: 1).hasUnsettledFact)
        await t.equal("①이 끝나지 않았으면 설치 안 됨 · 경로 오류도 다시 본다",
                      FirstRunRecheck.providers(facts: facts(claude: .pathInvalid, codex: .notInstalled, projects: 1),
                                                checklistVisible: false, lastRun: nil, now: now), [.claude, .codex])
        await t.equal("점검표가 보이면 준비되지 않은 제공자 모두",
                      FirstRunRecheck.providers(facts: claudeOnly, checklistVisible: true, lastRun: nil, now: now), [.codex])
        await t.equal("알림을 끈 Claude 만 쓰는 사람: 알림 · Git 만 (에이전트는 강제하지 않는다)",
                      FirstRunRecheck.providers(facts: facts(claude: .ready, codex: .notInstalled, notifications: .denied, projects: 1),
                                                checklistVisible: false, lastRun: nil, now: now), [])
    }

    /// Codex 로그인 판정 — auth.json 없음 → 미로그인, 단 파일 아닌 자격 저장소면 모름.
    static func codexJudge(_ t: TestKit) async {
        await t.group("점검표: Codex 자격 저장소")
        await t.check("keyring · auto · ephemeral 은 파일이 아니다",
                      ["keyring", "auto", "ephemeral"].allSatisfy {
                          CodexLoginJudge.usesNonFileStore(configToml: "model = \"x\"\ncli_auth_credentials_store = \"\($0)\"\n")
                      })
        await t.check("file · 없음 · 설정 파일 없음은 파일",
                      !CodexLoginJudge.usesNonFileStore(configToml: "cli_auth_credentials_store = \"file\"")
                        && !CodexLoginJudge.usesNonFileStore(configToml: "model = \"x\"")
                        && !CodexLoginJudge.usesNonFileStore(configToml: nil))
        await t.check("표 안의 같은 이름 · 주석은 최상위 설정이 아니다",
                      !CodexLoginJudge.usesNonFileStore(configToml: "[profiles.a]\ncli_auth_credentials_store = \"keyring\"")
                        && !CodexLoginJudge.usesNonFileStore(configToml: "# cli_auth_credentials_store = \"keyring\""))
        await t.check("줄 끝 주석 · 작은따옴표", CodexLoginJudge.usesNonFileStore(configToml: "cli_auth_credentials_store = 'keyring' # 맥 키체인"))
        let multiline = "model = \"x\"\ndeveloper_instructions = \"\"\"\n[중요] 한국어로 답한다\n[링크](https://example.com)\n\"\"\"\n"
            + "cli_auth_credentials_store = \"keyring\"\n[profiles.a]\nmodel = \"y\"\n"
        await t.check("여러 줄 문자열 안의 '[' 줄은 표 머리가 아니다 (뒤의 최상위 설정을 읽는다)",
                      CodexLoginJudge.usesNonFileStore(configToml: multiline))
        let literal = "notes = '''\n[a]\n'''\ncli_auth_credentials_store = \"auto\"\n"
        await t.check("작은따옴표 여러 줄 문자열도", CodexLoginJudge.usesNonFileStore(configToml: literal))
        await t.check("한 줄 안에서 열고 닫은 세 따옴표는 여러 줄이 아니다",
                      !CodexLoginJudge.usesNonFileStore(configToml: "a = \"\"\"x\"\"\"\n[t]\ncli_auth_credentials_store = \"keyring\"\n"))
        await t.equal("auth.json 상태 × 저장소 → 준비 상태",
                      [CodexLoginJudge.readiness(status: .loggedIn, nonFileStore: false),
                       CodexLoginJudge.readiness(status: .notLoggedIn, nonFileStore: false),
                       CodexLoginJudge.readiness(status: .notLoggedIn, nonFileStore: true),
                       CodexLoginJudge.readiness(status: .unreadable, nonFileStore: false)],
                      [.ready, .notLoggedIn, .loginUnknown, .loginUnknown])
        let combined = CodexLoginJudge.combined([("default", .notLoggedIn), ("work", .ready), ("x", .loginUnknown)])
        await t.check("계정 여럿: 로그인된 계정이 먼저", combined.readiness == .ready && combined.accountID == "work")
        await t.check("모두 미로그인이면 첫 계정(기본)", CodexLoginJudge.combined([("default", .notLoggedIn), ("w", .notLoggedIn)]).accountID == "default")
    }

    /// 같은 폴더 · 넓은 폴더.
    static func folders(_ t: TestKit) async {
        await t.group("점검표: 작업할 폴더")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-firstrun-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        let link = root.appendingPathComponent("link")
        try? FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        await t.check("심볼릭 링크 · 끝 / · 표준화한 경로는 같은 폴더",
                      FolderChoice.samePath(link.path, real.path) && FolderChoice.samePath(real.path + "/", real.path)
                        && FolderChoice.samePath(real.path + "/./", real.path))
        await t.check("/var 와 /private/var 는 같은 폴더", FolderChoice.samePath("/var/tmp", "/private/var/tmp"))
        await t.check("다른 폴더는 다르다", !FolderChoice.samePath(real.path, root.path))
        await t.equal("넓은 폴더 경고: / · 홈 · ~", [FolderChoice.risk("/"), FolderChoice.risk(NSHomeDirectory()), FolderChoice.risk("~")],
                      [.root, .home, .home])
        await t.check("프로젝트 폴더는 경고하지 않는다", FolderChoice.risk(real.path) == nil
                        && FolderChoice.risk(NSHomeDirectory() + "/Documents") == nil)
    }

    actor ProbeCounter {
        private(set) var count = 0
        func next() -> Int { count += 1; return count }
    }

    /// 로그인 셸 PATH: 한 번에 하나 · 세대.
    static func loginPath(_ t: TestKit) async {
        await t.group("점검표: 로그인 셸 PATH (한 번에 하나 · 세대)")
        let env = CLIEnvironment()
        let counter = ProbeCounter()
        await env.setLoginPathProber {
            let n = await counter.next()
            try? await Task.sleep(nanoseconds: 200_000_000)
            return "/probe/\(n)"
        }
        async let a = env.loginShellPath()
        async let b = env.loginShellPath()
        async let c = env.loginShellPath()
        let results = await [a, b, c]
        await t.equal("동시에 부른 셋이 조회 하나를 함께 기다린다", results, ["/probe/1", "/probe/1", "/probe/1"])
        await t.equal("조회는 한 번", await counter.count, 1)
        _ = await env.loginShellPath()
        await t.equal("캐시가 있으면 다시 묻지 않는다", await counter.count, 1)

        await env.invalidateLoginPath()
        let waiting = Task { await env.loginShellPath() }
        // 둘째 조회가 시작될 때까지 기다린다 (시간에 기대지 않는다 — 부하가 커도 흔들리지 않게). 조회는 200ms 를 잔다.
        for _ in 0..<500 where await counter.count < 2 { try? await Task.sleep(nanoseconds: 2_000_000) }
        await env.invalidateLoginPath()                  // 사람이 "다시 확인" — 세대를 올린다
        let afterInvalidate = await waiting.value
        await t.equal("기다리던 쪽은 옛 세대의 결과를 버리고 새 세대의 결과를 받는다", afterInvalidate, "/probe/3")
        await t.equal("새 세대의 결과가 캐시에 남는다", await env.loginShellPath(), "/probe/3")
        await t.equal("조회 수 (첫 · 버린 것 · 새 것)", await counter.count, 3)

        await env.setLoginPathProber { nil }
        await t.check("실패는 nil", await env.loginShellPath() == nil)
    }

    /// 앱: 읽기 성공 뒤에만 점검표 · 폴더를 열면 첫 대화가 readyAgent 로 · 같은 폴더는 같은 프로젝트.
    static func app(_ t: TestKit) async {
        await t.group("점검표: 앱에서 폴더 열기")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-firstrun-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
            try await store.bootstrap()
            let model = AppModel(store: store)
            await t.check("읽기 전에는 점검표를 세우지 않는다", !model.showsFirstRun && !model.projectsLoaded)
            await model.reloadProjects()
            await t.check("읽기 성공 · 프로젝트 없음 → 점검표", model.projectsLoaded && model.showsFirstRun)
            model.bootstrapError = "저장소 오류"
            await t.check("저장소 오류 화면이 먼저", !model.showsFirstRun)
            model.bootstrapError = nil

            // Claude 는 설치 안 됨, Codex 는 임시 홈 계정에 로그인됨 → 첫 대화는 Codex 그 계정.
            model.cliStatus[.claude] = CLIStatus(provider: .claude)
            model.cliStatus[.codex] = CLIStatus(provider: .codex, resolvedPath: "/bin/echo", executable: true)
            let home = root.appendingPathComponent("codex-home")
            let account = try await model.accounts.add(homePath: home.path, label: "시험")
            try #"{"tokens":{"access_token":"x"}}"#.write(to: home.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
            await model.accounts.refreshIdentity(account.id)
            await t.check("사실: Claude 설치 안 됨 · Codex 그 계정 준비",
                          model.firstRunFacts.claude.readiness == .notInstalled && model.firstRunFacts.codex.readiness == .ready
                            && model.firstRunChecklist.readyAgent?.codexAccountID == account.id)

            let folder = root.appendingPathComponent("work")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let opened = await model.openProjectFolder(path: folder.path)
            let thread = model.allThreads().first
            await t.check("폴더를 열면 프로젝트 · 첫 대화(readyAgent)", opened != nil && model.projects.count == 1
                            && thread?.preferredProvider == .codex && thread?.codexAccountID == account.id
                            && model.selectedThreadID == thread?.id, "\(String(describing: thread))")
            await t.check("입력창 포커스를 한 번 요청한다", model.composerFocusRequest?.threadID == thread?.id)
            await t.check("프로젝트가 생기면 점검표는 내린다", !model.showsFirstRun)
            let openedReveals = model.takeSidebarReveals()
            await t.check("폴더 열기의 첫 대화도 사이드바에 그 프로젝트를 펴라고 알린다", opened != nil && openedReveals == [opened?.id ?? ""],
                          "\(openedReveals)")

            let link = root.appendingPathComponent("work-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
            let again = await model.openProjectFolder(path: link.path + "/")
            await t.check("같은 폴더(심볼릭 링크 · 끝 /)는 같은 프로젝트를 고른다 — 새로 만들지 않는다",
                          again?.id == opened?.id && model.projects.count == 1 && model.allThreads().count == 1
                            && model.banner != nil)
            await t.check("이미 있는 프로젝트를 다시 열어 고르기만 하면 펴라고 알리지 않는다 (새 대화를 만들지 않았다)",
                          model.sidebarRevealProjectIDs.isEmpty)
            let direct = await model.addProject(name: "dup", path: folder.path)
            await t.check("addProject 도 같은 폴더면 그 프로젝트", direct.id == opened?.id && model.projects.count == 1)

            model.banner = nil
            let missing = await model.openProjectFolder(path: root.appendingPathComponent("없음").path)
            await t.check("점검표가 안 보일 때(사이드바 · ⌘O) 없는 폴더는 배너의 오류로",
                          missing == nil && model.firstRunError == nil && model.banner?.isError == true)
            model.banner = nil
            model.showFirstRunSheet = true
            _ = await model.openProjectFolder(path: root.appendingPathComponent("없음").path)
            await t.check("시작 점검 시트가 떠 있으면 점검표의 오류 줄에", model.firstRunError != nil && model.banner == nil)
            model.showFirstRunSheet = false
            model.showFirstRunSheet = true
            await t.check("시트를 다시 열면 지난 오류 줄은 지운다", model.firstRunError == nil)
            model.showFirstRunSheet = false

            // Claude 로그인 모름 + Codex 없음 → Claude.
            model.cliStatus[.claude] = CLIStatus(provider: .claude, resolvedPath: "/bin/echo", executable: true)
            model.claudeLogin = LoginCheck(loggedIn: nil, checkedAt: Date())
            model.cliStatus[.codex] = CLIStatus(provider: .codex)
            await t.check("Claude 로그인 모름은 황색 통과 · 첫 대화의 에이전트",
                          model.firstRunFacts.claude.readiness == .loginUnknown && model.firstRunChecklist.readyAgent?.provider == .claude)
            let second = root.appendingPathComponent("second")
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            await model.openProjectFolder(path: second.path)
            await t.check("두 번째 폴더의 첫 대화는 Claude (마지막 Codex 가 이 Mac 에서 쓸 수 없다 — initialAgent)",
                          model.selectedThread?.preferredProvider == .claude && model.projects.count == 2)

            // 기존 사용자: Claude · Codex 둘 다 로그인, 최근 대화는 Codex 의 기본이 아닌 계정 → 새 폴더도 그 Codex 계정.
            model.claudeLogin = LoginCheck(loggedIn: true, checkedAt: Date())
            model.cliStatus[.codex] = CLIStatus(provider: .codex, resolvedPath: "/bin/echo", executable: true)
            if var latest = model.selectedThread {
                latest.preferredProvider = .codex
                latest.codexAccountID = account.id
                await model.updateThread(latest)
            }
            await t.check("사실: 둘 다 로그인 → readyAgent 는 Claude",
                          model.firstRunChecklist.readyAgent?.provider == .claude)
            let third = root.appendingPathComponent("third")
            try FileManager.default.createDirectory(at: third, withIntermediateDirectories: true)
            await model.openProjectFolder(path: third.path)
            await t.check("기존 Codex 대화가 있고 Claude · Codex 둘 다 로그인 → 새 폴더는 Codex 그 계정 (initialAgent)",
                          model.selectedThread?.preferredProvider == .codex && model.selectedThread?.codexAccountID == account.id
                            && model.projects.count == 3, "\(String(describing: model.selectedThread))")

            // 설정의 경로가 실행되지 않으면 "설치 안 됨" 이 아니라 경로 오류.
            model.claudePathOverride = root.appendingPathComponent("없는-claude").path
            model.cliStatus[.claude] = CLIStatus(provider: .claude)
            await t.check("설정 경로를 실행할 수 없으면 경로 오류 · 그 경로를 보인다",
                          model.firstRunFacts.claude.readiness == .pathInvalid
                            && model.firstRunFacts.claude.path == model.claudePathOverride)
            model.claudePathOverride = ""
            await t.check("경로를 비우면 설치 안 됨", model.firstRunFacts.claude.readiness == .notInstalled)

            await model.store.db.close()
            await model.reloadProjects()
            await t.check("목록 읽기에 실패하면 지난 목록을 둔다 (빈 목록으로 바꾸지 않는다)",
                          model.projects.count == 3 && !model.showsFirstRun)
        } catch {
            await t.check("점검표 앱 시험 중 예외", false, "\(error)")
        }
    }

    /// Command Line Tools 가 없다고 확인되면 `/usr/bin/git`(설치 창을 띄우는 shim)을 고르지 않는다.
    static func gitShim(_ t: TestKit) async {
        await t.group("점검표: Command Line Tools 없음 → git shim 을 부르지 않는다")
        let before = GitInspector.systemGitShimUnavailable
        defer { GitInspector.systemGitShimUnavailable = before }
        let env = ["PATH": "/usr/bin:/bin:/usr/bin/"]
        GitInspector.systemGitShimUnavailable = true
        let skipped = GitInspector.findGit(environment: env)
        await t.check("CLT 없음: 후보 · PATH 어디서도 /usr/bin/git 을 고르지 않는다", skipped != GitInspector.systemGitShim,
                      skipped ?? "nil")
        GitInspector.systemGitShimUnavailable = false
        if FileManager.default.isExecutableFile(atPath: GitInspector.systemGitShim) {
            await t.equal("CLT 를 모르거나 있으면 예전대로 /usr/bin/git", GitInspector.findGit(environment: env), GitInspector.systemGitShim)
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-firstrun-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: Store(databaseURL: root.appendingPathComponent("db.sqlite3")))
        model.gitTools = .missing
        let whenMissing = GitInspector.systemGitShimUnavailable
        model.gitTools = .present
        await t.check("AppModel.gitTools 가 따라 켜고 끈다", whenMissing && !GitInspector.systemGitShimUnavailable)
    }

    final class CallLog {
        var claudeQueries: [Bool] = []
    }

    /// 한도를 읽은 범위 (메인 액터에서만 쓴다).
    final class ScopeLog {
        var scopes: [AgentScope] = []
    }

    /// 새 사용자는 Claude 조회(`claude -p` — 모델 목록 · /usage)를 첫 프로젝트 뒤로 미룬다. 폴더 열기 · 기록 가져오기 모두에서 한 번.
    static func deferredClaude(_ t: TestKit) async {
        await t.group("점검표: 미룬 Claude 조회")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-firstrun-defer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
            try await store.bootstrap()
            let model = AppModel(store: store)
            let log = CallLog()
            model.claudeQueriesOverride = { log.claudeQueries.append($0) }
            await model.reloadProjects()
            model.deferredClaudeStartup = true   // 부트스트랩이 프로젝트 없음에서 정하는 값

            model.runDeferredClaudeStartup()
            model.refreshProviderAfterLogin(.claude)
            await t.check("프로젝트가 없으면 미룬다 (로그인이 막 확인돼도)", log.claudeQueries.isEmpty && model.deferredClaudeStartup)

            // 기록 가져오기: 가져오기가 프로젝트를 저장하고 목록을 다시 읽는다.
            try await store.upsertProject(Project(name: "imported", path: root.path, sortOrder: 0))
            _ = await model.importSessions(folders: [])
            await t.check("기록 가져오기로 첫 프로젝트가 생기면 미룬 조회를 한 번 한다",
                          log.claudeQueries == [false] && !model.deferredClaudeStartup, "\(log.claudeQueries)")

            let folder = root.appendingPathComponent("work")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            await model.openProjectFolder(path: folder.path)
            await t.check("그 뒤의 폴더 열기는 다시 하지 않는다", log.claudeQueries.count == 1)

            model.refreshProviderAfterLogin(.claude)
            await t.check("프로젝트가 있으면 로그인이 확인된 순간 한도를 강제로 읽는다", log.claudeQueries == [false, true])

            // 폴더 열기 경로: 새 모델 · 빈 DB.
            let store2 = Store(databaseURL: root.appendingPathComponent("db2.sqlite3"))
            try await store2.bootstrap()
            let fresh = AppModel(store: store2)
            let log2 = CallLog()
            fresh.claudeQueriesOverride = { log2.claudeQueries.append($0) }
            await fresh.reloadProjects()
            fresh.deferredClaudeStartup = true
            await fresh.openProjectFolder(path: folder.path)
            await t.check("폴더를 열어 첫 프로젝트가 생기면 한 번", log2.claudeQueries == [false] && !fresh.deferredClaudeStartup)

            // onb-9: 미루는 동안 사람이 누른 한도 새로고침(한도 칩 · 메뉴)도 Claude(`claude -p /usage`)는 건너뛴다.
            let store3 = Store(databaseURL: root.appendingPathComponent("db3.sqlite3"))
            try await store3.bootstrap()
            let early = AppModel(store: store3)
            let fetched = ScopeLog()
            let previous = LimitsService.fetchOverride
            LimitsService.fetchOverride = { scope in
                fetched.scopes.append(scope)
                return await previous?(scope) ?? TestEnv.offlineLimitSnapshot(scope)
            }
            early.deferredClaudeStartup = true
            await early.limits.refreshAll(force: true)
            let whileDeferred = fetched.scopes.contains { $0.provider == .claude }
            early.deferredClaudeStartup = false
            await early.limits.refreshAll(force: true)
            let afterwards = fetched.scopes.contains { $0.provider == .claude }
            LimitsService.fetchOverride = previous
            await t.check("미루는 동안의 한도 새로고침은 Claude 를 건너뛰고, 미룸이 끝나면 다시 읽는다", !whileDeferred && afterwards,
                          "\(fetched.scopes)")
            await store.db.close()
            await store2.db.close()
            await store3.db.close()
        } catch {
            await t.check("미룬 Claude 조회 시험 중 예외", false, "\(error)")
        }
    }

    /// 화면 확인용 실행(`AHC_OFFLINE=1`)은 실제 CLI · 알림 권한 · Git 을 건드리지 않는다. 그 값은 실행할 때 정해지므로 이 실행
    /// 파일을 `AHC_OFFLINE=1` 로 다시 띄워(`inttest firstrunoffline` → `offlineProbe`) 결과 한 줄을 본다.
    static func offlineGuards(_ t: TestKit) async {
        await t.group("점검표: 화면 확인용 실행의 가드")
        guard let executable = Bundle.main.executableURL else {
            await t.check("검증 실행 파일 경로", false)
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["firstrunoffline"]
        var environment = ProcessInfo.processInfo.environment
        environment["AHC_OFFLINE"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            let ended: Int32 = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)
            let line = output.split(separator: "\n").last { $0.hasPrefix("FIRSTRUN-OFFLINE ") }.map(String.init) ?? output
            await t.equal("AHC_OFFLINE=1: 사실 모으기 · 다시 확인 · 알림 허용 · 활성화 확인 · 미룬 Claude 조회가 아무것도 부르지 않는다",
                          line, "FIRSTRUN-OFFLINE offline=true cli=0 login=nil git=unknown notify=checking loginChecks=0 claudeQueries=0")
            await t.equal("하위 프로세스는 정상 종료", ended, 0)
        } catch {
            await t.check("오프라인 가드 하위 프로세스 실행", false, "\(error)")
        }
    }

    /// 첫 대화의 에이전트를 고르기 전에 기다릴지 (onb-5) · 점검표가 로그인을 지켜볼지 (onb-11) — 순수 판정.
    static func firstAgentWait(_ t: TestKit) async {
        await t.group("점검표: 확인 중인 에이전트 · 로그인 지켜보기")
        func mayChange(_ claude: AgentReadiness, _ codex: AgentReadiness) -> Bool {
            FirstRunChecklist(facts(claude: claude, codex: codex)).readyAgentMayChange
        }
        await t.check("모두 확인 중이면 기다린다 (그대로 열면 늘 Claude 였다)", mayChange(.checking, .checking))
        await t.check("로그인된 Claude 를 골랐으면 Codex 확인을 기다리지 않는다", !mayChange(.ready, .checking))
        await t.check("Claude 가 설치 안 됨이고 Codex 가 확인 중이면 기다린다", mayChange(.notInstalled, .checking))
        await t.check("로그인 모르는 Claude 는 확인될 Codex 가 앞설 수 있다", mayChange(.loginUnknown, .checking))
        await t.check("Codex 가 확인됐어도 Claude 가 확인 중이면 기다린다 (Claude 가 먼저)", mayChange(.checking, .ready))
        await t.check("확인 중인 것이 없으면 기다리지 않는다", !mayChange(.notInstalled, .ready) && !mayChange(.notLoggedIn, .notInstalled))

        await t.check("쓸 수 있는 에이전트가 없고 로그인 필요가 있으면 로그인을 지켜본다",
                      FirstRunChecklist(facts(claude: .notLoggedIn, codex: .notInstalled)).watchesLogins)
        await t.check("①이 끝났으면(Codex 준비) 지켜보지 않는다",
                      !FirstRunChecklist(facts(claude: .notLoggedIn, codex: .ready)).watchesLogins)
        await t.check("로그인 필요가 없으면 지켜보지 않는다",
                      !FirstRunChecklist(facts(claude: .notInstalled, codex: .notInstalled)).watchesLogins)
    }

    /// 앱: 확인이 도는 동안 첫 폴더를 열면 확인을 기다려 첫 대화의 에이전트를 고른다 (onb-5). 확인이 돌지 않으면 기다리지 않는다.
    static func waitsForFacts(_ t: TestKit) async {
        await t.group("점검표: 첫 폴더는 에이전트 확인을 기다린다")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-firstrun-wait-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
            try await store.bootstrap()
            let model = AppModel(store: store)
            await model.reloadProjects()
            let home = root.appendingPathComponent("codex-home")
            let account = try await model.accounts.add(homePath: home.path, label: "시험")
            try #"{"tokens":{"access_token":"x"}}"#.write(to: home.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
            await model.accounts.refreshIdentity(account.id)

            // 시작 직후: 확인이 돌고 있고 아직 아무 사실도 없다 (모두 확인 중).
            model.isRefreshingAgentFacts = true
            let folder = root.appendingPathComponent("work")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let opening = Task { await model.openProjectFolder(path: folder.path) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            await t.check("확인 중에는 첫 대화를 아직 만들지 않는다", model.allThreads().isEmpty)
            // 확인이 끝났다: Claude 는 설치 안 됨, Codex 는 그 계정에 로그인됨.
            model.cliStatus[.claude] = CLIStatus(provider: .claude)
            model.cliStatus[.codex] = CLIStatus(provider: .codex, resolvedPath: "/bin/echo", executable: true)
            model.isRefreshingAgentFacts = false
            _ = await opening.value
            let first = model.allThreads().first
            await t.check("확인이 끝난 뒤 고른다 — Codex 만 쓰는 사람의 첫 대화는 Codex 그 계정",
                          first?.preferredProvider == .codex && first?.codexAccountID == account.id, "\(String(describing: first))")
            await store.db.close()

            // 확인이 돌지 않으면(시험 · 이미 끝남) 확인 중이어도 기다리지 않는다.
            let store2 = Store(databaseURL: root.appendingPathComponent("db2.sqlite3"))
            try await store2.bootstrap()
            let fresh = AppModel(store: store2)
            await fresh.reloadProjects()
            let started = Date()
            await fresh.openProjectFolder(path: folder.path)
            await t.check("확인이 돌지 않으면 곧바로 연다", Date().timeIntervalSince(started) < 2 && fresh.allThreads().count == 1,
                          String(format: "%.1f초", Date().timeIntervalSince(started)))
            await store2.db.close()
        } catch {
            await t.check("첫 폴더 기다리기 시험 중 예외", false, "\(error)")
        }
    }

    /// 찾은 실행 파일이 돌지 않으면(`--version` 실패 — node 를 못 찾음 등) 쓸 수 없음 · 그 까닭을 점검표에 (onb-2).
    static func runFailure(_ t: TestKit) async {
        await t.group("점검표: 찾았지만 돌지 않는 CLI")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-firstrun-runfail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let broken = root.appendingPathComponent("claude")
            try "#!/bin/sh\necho 'env: node: No such file or directory' >&2\nexit 127\n"
                .write(to: broken, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.path)
            let working = root.appendingPathComponent("codex")
            try "#!/bin/sh\necho 'codex-cli 9.9.9'\n".write(to: working, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: working.path)

            let env = CLIEnvironment()
            await env.setOverrides(.init(claudePath: broken.path, codexPath: working.path, geminiPath: nil))
            let failed = await env.checkStatus(.claude, force: true)
            await t.check("--version 이 실패하면 쓸 수 없음 (찾은 경로는 남긴다)",
                          !failed.isUsable && failed.resolvedPath == broken.path && !failed.executable, "\(failed)")
            await t.check("CLI 가 남긴 말이 오류에 그대로", failed.error?.contains("env: node: No such file or directory") == true
                            && failed.error?.contains("실행하지 못했습니다") == true, failed.error ?? "nil")
            let fine = await env.checkStatus(.codex, force: true)
            await t.check("돌면 쓸 수 있음 · 버전", fine.isUsable && fine.version == "codex-cli 9.9.9", "\(fine)")

            let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
            try await store.bootstrap()
            let model = AppModel(store: store)
            model.cliStatus[.claude] = failed
            await t.check("점검표: 경로를 지정하지 않았어도 '실행할 수 없음' (설치 안내가 아니다) · 까닭을 보인다",
                          model.firstRunFacts.claude.readiness == .pathInvalid
                            && model.firstRunFacts.claude.runError == failed.error
                            && model.firstRunFacts.claude.path == broken.path)
            model.cliStatus[.claude] = CLIStatus(provider: .claude)
            await t.check("찾지 못했으면 그대로 설치 안 됨 (까닭 없음)",
                          model.firstRunFacts.claude.readiness == .notInstalled && model.firstRunFacts.claude.runError == nil)

            // onb-3: API 키 · Bedrock · Vertex 가 환경에 있으면 "로그인 안 됨" 이 확인돼도 단정하지 않는다.
            model.cliStatus[.claude] = CLIStatus(provider: .claude, resolvedPath: "/bin/echo", executable: true)
            model.claudeLogin = LoginCheck(loggedIn: false, checkedAt: Date())
            let plain: AgentReadiness = model.agentReadiness(.claude)
            model.claudeAlternativeAuth = true
            let withKey: AgentReadiness = model.agentReadiness(.claude)
            await t.equal("로그인 안 됨 → 로그인 필요, 단 API 키 등이 있으면 로그인 모름 (황색 통과)", [plain, withKey],
                          [AgentReadiness.notLoggedIn, .loginUnknown])
            await t.check("점검표 사실에도 실린다", model.firstRunFacts.claudeAlternativeAuth)
            await store.db.close()
        } catch {
            await t.check("돌지 않는 CLI 시험 중 예외", false, "\(error)")
        }
        await t.equal("돌지 않음: 띄우지 못함 · 126 · 127 · 해석기 없음 / 돈다: 시간 초과 · 모르는 옵션",
                      [CLIEnvironment.cannotRun(exitStatus: nil, note: "exec format error", output: ""),
                       CLIEnvironment.cannotRun(exitStatus: 126, note: nil, output: ""),
                       CLIEnvironment.cannotRun(exitStatus: 127, note: nil, output: ""),
                       CLIEnvironment.cannotRun(exitStatus: 1, note: nil, output: "/usr/bin/env: bad interpreter"),
                       CLIEnvironment.cannotRun(exitStatus: nil, note: "시간 초과(20초)", output: ""),
                       CLIEnvironment.cannotRun(exitStatus: 2, note: nil, output: "error: unknown option '--version'")],
                      [true, true, true, true, false, false])
        await t.check("--version 실패 글: 앞 세 줄 · 빈 출력",
                      CLIEnvironment.runFailureMessage(binary: "claude", output: "a\n\nb\nc\nd").hasSuffix("a\nb\nc")
                        && CLIEnvironment.runFailureMessage(binary: "codex", output: "  ").hasSuffix("출력 없음"))
    }

    /// 로그인 문제로 끝난 실행의 안내 (onb-7 — 판정 · 글. 단추는 오류 줄 화면이 단다).
    static func loginTrouble(_ t: TestKit) async {
        await t.group("점검표: 로그인 문제로 끝난 실행의 안내")
        let auth = ThreadEvent(threadID: "t", runID: "r", kind: .error, provider: .claude,
                               title: LimitStatus.authProblem.koreanName, text: "Not logged in · Please run /login")
        let network = ThreadEvent(threadID: "t", runID: "r", kind: .error, provider: .claude,
                                  title: LimitStatus.networkError.koreanName, text: "ECONNRESET")
        await t.check("인증 문제 오류 행만 로그인 문제", LoginTroubleGuide.isLoginFailure(auth) && !LoginTroubleGuide.isLoginFailure(network))
        let claude = LoginTroubleGuide.make(event: auth, provider: .claude, codexHome: nil)
        await t.check("Claude: 터미널의 로그인 명령 · /login 은 앱에서 칠 수 없다고 말한다",
                      claude?.loginCommand == AgentSetupGuide.claudeLoginCommand && claude?.text.contains("/login") == true)
        let codex = LoginTroubleGuide.make(event: auth, provider: .codex, codexHome: "/tmp/acct")
        await t.equal("Codex: 그 계정 홈에 로그인되는 명령", codex?.loginCommand, "CODEX_HOME=/tmp/acct codex login")
        await t.check("Antigravity 는 명령 없이 안내만", LoginTroubleGuide.make(event: auth, provider: .gemini, codexHome: nil)?.loginCommand == nil)
        await t.check("다른 오류 · 제공자를 모름은 안내하지 않는다",
                      LoginTroubleGuide.make(event: network, provider: .claude, codexHome: nil) == nil
                        && LoginTroubleGuide.make(event: auth, provider: nil, codexHome: nil) == nil)
    }

    /// 시스템 알림을 낼지 (H15 · chat-15 · nav-6) — 순수 판정과 권한 물음의 글.
    static func notificationGate(_ t: TestKit) async {
        await t.group("알림: 낼지 · 권한을 언제 묻는지")
        func decide(enabled: Bool = true, authorized: Bool?, canAsk: Bool = true, active: Bool, onScreen: Bool) -> NotificationGate.Decision {
            NotificationGate.decide(enabled: enabled, authorized: authorized, canAsk: canAsk, appActive: active, threadOnScreen: onScreen)
        }
        await t.equal("꺼 두면 내지 않는다", decide(enabled: false, authorized: true, active: false, onScreen: false), .skip(.disabled))
        await t.equal("앱이 앞에 있고 그 대화가 칸에 보이면 내지 않는다", decide(authorized: true, active: true, onScreen: true), .skip(.onScreen))
        await t.equal("앞에 있어도 그 대화가 안 보이면 낸다", decide(authorized: true, active: true, onScreen: false), .deliver)
        await t.equal("앱이 뒤에 있으면 낸다 (칸에 열려 있어도)", decide(authorized: true, active: false, onScreen: true), .deliver)
        await t.equal("묻지 않았고 앱이 뒤에 있으면 묻고 보낸다", decide(authorized: nil, active: false, onScreen: false), .askThenDeliver)
        await t.equal("묻지 않았어도 앱이 앞에 있으면 묻지 않는다", decide(authorized: nil, active: true, onScreen: false), .skip(.notAuthorized))
        await t.equal("이번 실행에서 이미 물었으면 다시 묻지 않는다", decide(authorized: nil, canAsk: false, active: false, onScreen: false),
                      .skip(.notAuthorized))
        await t.equal("거부했으면 내지 않는다", decide(authorized: false, active: false, onScreen: false), .skip(.notAuthorized))

        let clock: (Date) -> String = { _ in "14:05" }
        typealias Request = NotificationService.PermissionRequest
        await t.check("물은 적이 없거나 허용됐으면 한 줄이 없다",
                      NotificationGate.requestNote(nil, clock: clock) == nil
                        && NotificationGate.requestNote(Request(trigger: .firstAlert, askedAt: Date(), outcome: .granted), clock: clock) == nil)
        let denied = NotificationGate.requestNote(Request(trigger: .firstAlert, askedAt: Date(), outcome: .denied), clock: clock) ?? ""
        await t.check("첫 알림 때 물었고 허용되지 않음 — 언제 · 왜 물었는지 · 꺼진 까닭",
                      denied.contains("14:05") && denied.contains("처음 알릴 일") && denied.contains("허용되지 않아"), denied)
        let failed = NotificationGate.requestNote(Request(trigger: .button, askedAt: Date(), outcome: .failed("알림 권한 요청 실패: x")),
                                                  clock: clock) ?? ""
        await t.check("요청 실패는 거부와 다르게 — 실패 글을 함께", failed.contains("요청이 실패했습니다") && failed.contains("알림 권한 요청 실패: x"),
                      failed)
        let pending = NotificationGate.requestNote(Request(trigger: .button, askedAt: Date(), outcome: .pending), clock: clock) ?? ""
        await t.check("답을 기다리는 중", pending.contains("[알림 허용]") && pending.contains("답하세요"), pending)
    }

    /// 앱: 사람이 멈춘 실행은 알리지 않는다 · 끝난 실행은 알린다 · 그 대화가 칸에 보이는가 (nav-6 · chat-15).
    static func notificationApp(_ t: TestKit) async {
        await t.group("알림: 앱에서 낼지")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-firstrun-notify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let folder = root.appendingPathComponent("p")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
            try await store.bootstrap()
            let project = Project(name: "p", path: folder.path)
            try await store.upsertProject(project)
            var thread = ConversationThread(projectID: project.id, title: "t")
            thread.claudeSelection = ModelSelection(model: "sonnet", effort: "high")
            try await store.upsertThread(thread)
            let model = AppModel(store: store)
            let done = AgentTurnResult(state: .completed, terminalReason: "completed", sessionID: "s")
            let interrupted = AgentTurnResult(state: .cancelled, terminalReason: "user_cancelled", sessionID: "s")
            let started: ScriptedAgentAdapter.Step = .emit(.sessionEstablished(sessionID: "s", model: "fake", cliVersion: nil))
            let finishing: [ScriptedAgentAdapter.Step] = [started, .emit(.assistantMessage("ok")), .finish(done)]
            let stopping: [ScriptedAgentAdapter.Step] = [started, .waitInterrupt, .finish(interrupted)]
            model.runner.adapterFactory = { provider in
                ScriptedAgentAdapter(provider: provider) { request in
                    if request.prompt.contains("멈춰") { return stopping }
                    return finishing
                }
            }
            await model.reloadProjects()
            await model.selectThread(thread.id)
            func settle(_ condition: @MainActor () -> Bool) async {
                for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
            }
            func idle() -> Bool { model.runner.session(threadID: thread.id) == nil && !model.isStartingRun(threadID: thread.id) }

            _ = await model.send("일해", provider: .claude, threadID: thread.id)
            await settle(idle)
            await t.check("끝난 실행은 알린다 (판정은 서비스가 — 시험 실행에는 알림 센터가 없다)",
                          model.notifications.postLog.contains { $0.title == "실행 완료" }, "\(model.notifications.postLog.map(\.title))")

            _ = await model.send("멈춰", provider: .claude, threadID: thread.id)
            await settle { model.runner.session(threadID: thread.id)?.state == .running }
            await model.runner.interrupt(threadID: thread.id)
            await settle(idle)
            await t.check("사람이 멈춘 실행은 알리지 않는다 ('실행 중단됨' 없음)",
                          !model.notifications.postLog.contains { $0.title == "실행 중단됨" }, "\(model.notifications.postLog.map(\.title))")

            await t.check("그 대화가 칸에 열려 있으면 보인다 · 다른 대화는 아니다",
                          model.isThreadShownInPanes(thread.id) && !model.isThreadShownInPanes("없는-대화"))
            await store.db.close()
        } catch {
            await t.check("앱 알림 시험 중 예외", false, "\(error)")
        }
    }

    /// `inttest firstrunoffline` (AHC_OFFLINE=1 로만 뜻이 있다): 오프라인 가드를 거친 결과를 한 줄로 찍는다.
    static func offlineProbe() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-firstrun-offline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
        let model = AppModel(store: store)
        await model.bootstrap()   // 화면 확인용 실행의 부트스트랩 (사실은 `-preview.firstRun` 에서 — 실제 확인을 하지 않는다)
        var loginChecks = 0
        model.claudeLoginCheck = { loginChecks += 1; return true }
        let log = CallLog()
        model.claudeQueriesOverride = { log.claudeQueries.append($0) }
        model.deferredClaudeStartup = true
        await model.refreshAgentFacts(force: true)
        await model.recheckFirstRunFacts()
        await model.requestNotificationPermission()
        await model.recheckFactsOnActivation()
        await model.addProject(name: "p", path: root.path)
        print("FIRSTRUN-OFFLINE offline=\(AppModel.offlinePreview) cli=\(model.cliStatus.count) "
              + "login=\(model.claudeLogin == nil ? "nil" : "set") git=\(model.gitTools.rawValue) "
              + "notify=\(model.notifications.permission.rawValue) loginChecks=\(loginChecks) claudeQueries=\(log.claudeQueries.count)")
        await store.db.close()
    }
}
