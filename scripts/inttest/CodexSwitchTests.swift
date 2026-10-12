import Darwin
import Foundation

/// Codex 계정끼리 바꾸기 — 대화의 Codex 세션 하나를 다른 계정의 인증으로 이어 간다 (인계가 아니다).
/// `CodexRunHome`(실행 폴더) · `RunSession.send`(어디서 띄울지 · 재개 실패 시 새 세션으로 넘어가지 않기) · `AppModel+CodexSwitch`(칩 ·
/// 한도 줄 · 제안 · 자동 카운트다운). CLI 를 쓰지 않는다 — 가짜 `codex`(app-server 흉내 sh) · 가짜 어댑터. 계정 폴더는 모두 임시 폴더다
/// (실제 `~/.codex` 를 건드리지 않는다).
@MainActor
enum CodexSwitchTests {

    static func run(_ t: TestKit) async {
        let base = CodexRunHome.baseDirectory
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ahc-codexswitch-\(UUID().uuidString)")
        CodexRunHome.baseDirectory = root.appendingPathComponent("runs", isDirectory: true)
        defer {
            CodexRunHome.baseDirectory = base
            try? FileManager.default.removeItem(at: root)
        }
        await runHome(t, root: root.appendingPathComponent("home"))
        await placement(t, root: root.appendingPathComponent("placement"))
        await t.group("Codex 계정 바꾸기: 앱 (칩 · 한도 줄 · 제안 · 자동 카운트다운)")
        do { try await appFlows(t) } catch { await t.check("앱 시나리오 실행 중 예외", false, "\(error)") }
    }

    // MARK: 실행 폴더

    /// 계정 폴더 하나 — auth.json · config.toml · 스킬 · 전역 지시 · SQLite · (링크하지 않을) sessions.
    static func makeHome(_ url: URL, config: String = "model = \"gpt-5.6-luna\"\n") throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try #"{"tokens":{"access_token":"x"}}"#.write(to: url.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try config.write(to: url.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try "# 전역 지시\n".write(to: url.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        fm.createFile(atPath: url.appendingPathComponent("state_5.sqlite").path, contents: Data())
    }

    static func runHome(_ t: TestKit, root: URL) async {
        await t.group("Codex 계정 바꾸기: 실행 폴더 (CodexRunHome)")
        let fm = FileManager.default
        let record = root.appendingPathComponent("record")
        let account = root.appendingPathComponent("account")
        do {
            try makeHome(record)
            try makeHome(account)
            let prepared = try CodexRunHome.prepare(recordHome: record.path, accountHome: account.path, accountLabel: "둘째", runID: "r1")
            let home = prepared.home
            func link(_ name: String) -> String? { try? fm.destinationOfSymbolicLink(atPath: (home as NSString).appendingPathComponent(name)) }
            await t.check("실행 폴더 이름 = 앱 PID-실행 ID (다음 시작이 죽은 앱의 것만 지운다)",
                          (home as NSString).lastPathComponent == "\(getpid())-r1", home)
            await t.equal("인증 · 설정 · 스킬 · 전역 지시는 실행 계정의 것으로 링크 (사본이 아니다)",
                          [link("auth.json"), link("config.toml"), link("skills"), link("AGENTS.md")],
                          ["auth.json", "config.toml", "skills", "AGENTS.md"].map { account.appendingPathComponent($0).path })
            await t.equal("기록 항목은 기록 폴더로 링크",
                          CodexRunHome.recordEntries.map { link($0) },
                          CodexRunHome.recordEntries.map { record.appendingPathComponent($0).path })
            await t.check("기록 폴더에 없던 기록 항목은 미리 만든다 (빈 폴더 · 빈 파일)",
                          fm.fileExists(atPath: record.appendingPathComponent("archived_sessions").path)
                            && fm.fileExists(atPath: record.appendingPathComponent("thread-writer-locks").path)
                            && (try? Data(contentsOf: record.appendingPathComponent("session_index.jsonl")))?.isEmpty == true)
            await t.check("SQLite 는 링크하지 않는다 (CODEX_SQLITE_HOME 이 기록 폴더를 직접 가리킨다)",
                          !fm.fileExists(atPath: (home as NSString).appendingPathComponent("state_5.sqlite")))
            await t.equal("자식 환경", prepared.environment, ["CODEX_HOME": home, "CODEX_SQLITE_HOME": record.path])
            prepared.remove()
            await t.check("지우면 링크만 지운다 (계정 · 기록 폴더는 그대로)",
                          !fm.fileExists(atPath: home) && fm.fileExists(atPath: account.appendingPathComponent("auth.json").path)
                            && fm.fileExists(atPath: record.appendingPathComponent("sessions").path))
        } catch {
            await t.check("실행 폴더 만들기", false, "\(error)")
        }

        // 인증을 파일이 아닌 곳(키체인)에 두는 계정 · 기록 폴더가 없다.
        let keyring = root.appendingPathComponent("keyring")
        try? makeHome(keyring, config: "cli_auth_credentials_store = \"keyring\"\n")
        var refused: CodexRunHome.Failure?
        do { _ = try CodexRunHome.prepare(recordHome: record.path, accountHome: keyring.path, accountLabel: "키체인", runID: "r2") }
        catch let failure as CodexRunHome.Failure { refused = failure } catch {}
        await t.equal("인증이 파일이 아닌 계정은 다른 폴더의 세션을 이어 갈 수 없다", refused, .nonFileCredentials("키체인"))
        await t.check("인증 파일 판정", !CodexRunHome.usesFileCredentials(accountHome: keyring.path)
                        && CodexRunHome.usesFileCredentials(accountHome: account.path))
        refused = nil
        do { _ = try CodexRunHome.prepare(recordHome: root.appendingPathComponent("gone").path, accountHome: account.path,
                                          accountLabel: "둘째", runID: "r3") }
        catch let failure as CodexRunHome.Failure { refused = failure } catch {}
        await t.equal("기록 폴더가 없으면 만들지 않는다", refused, .recordHomeMissing(root.appendingPathComponent("gone").path))
        await t.check("같은 폴더 판정 — /tmp ↔ /private/tmp · 끝의 / · ~",
                      CodexRunHome.sameHome("/tmp/ahc-x", "/private/tmp/ahc-x/")
                        && CodexRunHome.sameHome("~/.codex", NSHomeDirectory() + "/.codex")
                        && !CodexRunHome.sameHome("/tmp/a", "/tmp/b"))

        // 죽은 앱이 남긴 실행 폴더만 지운다 — 링크가 가리키는 것은 그대로.
        let stale = CodexRunHome.baseDirectory.appendingPathComponent("999999-old")
        let mine = CodexRunHome.baseDirectory.appendingPathComponent("\(getpid())-live")
        try? fm.createDirectory(at: stale, withIntermediateDirectories: true)
        try? fm.createDirectory(at: mine, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: stale.appendingPathComponent("auth.json"), withDestinationURL: account.appendingPathComponent("auth.json"))
        CodexRunHome.removeStale()
        await t.check("앱을 켤 때: 끝난 앱의 실행 폴더만 지운다 (이 앱 것 · 링크 대상은 그대로)",
                      !fm.fileExists(atPath: stale.path) && fm.fileExists(atPath: mine.path)
                        && fm.fileExists(atPath: account.appendingPathComponent("auth.json").path))
        try? fm.removeItem(at: mine)
    }

    // MARK: 실행기 (가짜 codex)

    /// 가짜 `codex` — `--version` 과 app-server 의 initialize · thread/start · thread/resume · turn/start 만. 띄울 때마다 환경
    /// (`CODEX_HOME` | `CODEX_SQLITE_HOME` | auth.json 링크 대상)을 env.log 에, 재개 요청은 resume.log 에, 새 스레드는 start.log 에.
    /// threadId 가 BAD 인 재개는 오류로 답한다.
    static func makeFakeCodex(in dir: URL) throws -> URL {
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "codex-cli 0.162.0"; exit 0; fi
        dir="$(cd "$(dirname "$0")" && pwd)"
        printf '%s|%s|%s\\n' "$CODEX_HOME" "${CODEX_SQLITE_HOME:-}" "$(readlink "$CODEX_HOME/auth.json")" >> "$dir/env.log"
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          case "$line" in
            *'"method":"initialize"'*) echo '{"id":'"$id"',"result":{}}' ;;
            *'"method":"thread/start"'*)
              echo start >> "$dir/start.log"
              echo '{"id":'"$id"',"result":{"thread":{"id":"NEW"},"model":"stub"}}' ;;
            *'"method":"thread/resume"'*)
              printf '%s\\n' "$line" >> "$dir/resume.log"
              case "$line" in
                *BAD*) echo '{"id":'"$id"',"error":{"code":-32600,"message":"no rollout found for thread id BAD"}}' ;;
                *) echo '{"id":'"$id"',"result":{"thread":{"id":"S"},"model":"stub"}}' ;;
              esac ;;
            *'"method":"turn/start"'*)
              echo '{"id":'"$id"',"result":{"turn":{"id":"t1"}}}'
              tid=S
              case "$line" in *'"threadId":"NEW"'*) tid=NEW ;; esac
              echo '{"method":"turn/started","params":{"threadId":"'"$tid"'","turn":{"id":"t1"}}}'
              echo '{"method":"item/completed","params":{"threadId":"'"$tid"'","item":{"type":"agentMessage","id":"m1","text":"ok"}}}'
              echo '{"method":"turn/completed","params":{"threadId":"'"$tid"'","turn":{"id":"t1","status":"completed"}}}'
              ;;
          esac
        done
        """
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("codex")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func placement(_ t: TestKit, root: URL) async {
        await t.group("Codex 계정 바꾸기: 실행기가 대화의 세션을 다른 계정으로 이어 간다 (가짜 codex)")
        let fm = FileManager.default
        do {
            let bin = root.appendingPathComponent("bin")
            let fake = try makeFakeCodex(in: bin)
            let homeA = root.appendingPathComponent("homeA")
            let homeB = root.appendingPathComponent("homeB")
            try makeHome(homeA)
            try makeHome(homeB)
            let folder = root.appendingPathComponent("p")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
            try await store.bootstrap()
            let project = Project(name: "p", path: folder.path)
            try await store.upsertProject(project)
            var thread = ConversationThread(projectID: project.id, title: "계정 바꾸기", preferredProvider: .codex)
            thread.codexSelection = ModelSelection(model: "gpt-5.6-luna", effort: "low")
            try await store.upsertThread(thread)
            let environment = CLIEnvironment()
            await environment.setOverrides(.init(codexPath: fake.path))
            let runner = RunCoordinator(store: store, environment: environment)
            let accountA = CodexAccountRef(id: "acct-a", label: "첫째", homePath: homeA.path)
            let accountB = CodexAccountRef(id: "acct-b", label: "둘째", homePath: homeB.path)
            func settle() async {
                for _ in 0..<500 where runner.session(threadID: thread.id) != nil { try? await Task.sleep(nanoseconds: 20_000_000) }
            }
            func lines(_ name: String) -> [String] {
                ((try? String(contentsOf: bin.appendingPathComponent(name), encoding: .utf8)) ?? "")
                    .split(separator: "\n").map(String.init)
            }
            func session() async -> AgentSession? { try? await store.session(threadID: thread.id, provider: .codex) }

            // 1) 계정A — 새 세션. 계정A 의 홈 그대로 · 기록 폴더 = 계정A 의 홈.
            _ = try await runner.send(prompt: "a", thread: thread, project: project, provider: .codex, account: accountA)
            await settle()
            let first = await session()
            await t.equal("새 세션은 실행 계정의 홈에서 (실행 폴더 없음)", lines("env.log").first,
                          "\(homeA.path)||")
            await t.check("세션 · 기록 폴더 = 계정A 의 홈", first?.cliSessionID == "NEW"
                            && first?.recordHome.map { CodexRunHome.sameHome($0, homeA.path) } == true, "\(String(describing: first))")

            // 2) 계정B — 같은 세션을 이어 간다: 실행 폴더(인증은 계정B · 기록은 계정A) · 엄격한 재개.
            _ = try await runner.send(prompt: "b", thread: thread, project: project, provider: .codex, account: accountB)
            await settle()
            let env2 = lines("env.log").dropFirst().first?.split(separator: "|", omittingEmptySubsequences: false).map(String.init) ?? []
            await t.check("계정B 의 실행: CODEX_HOME = 실행 폴더 · CODEX_SQLITE_HOME = 계정A 의 홈 · auth.json 은 계정B 의 파일로 링크",
                          env2.count == 3 && env2[0].hasPrefix(CodexRunHome.baseDirectory.path)
                            && CodexRunHome.sameHome(env2[1], homeA.path) && env2[2] == homeB.appendingPathComponent("auth.json").path,
                          env2.joined(separator: " | "))
            await t.check("대화의 세션을 재개했다 (새 스레드를 만들지 않음)", lines("resume.log").last?.contains("\"NEW\"") == true
                            && lines("start.log").count == 1)
            let second = await session()
            await t.check("세션 ID · 기록 폴더는 그대로 (계정A 의 홈)", second?.cliSessionID == "S"
                            && second?.recordHome.map { CodexRunHome.sameHome($0, homeA.path) } == true, "\(String(describing: second))")
            let runs = (try? await store.runs(threadID: thread.id)) ?? []
            await t.equal("실행 기록의 계정", runs.sorted { $0.startedAt < $1.startedAt }.map { $0.codexAccountID ?? "" }, ["acct-a", "acct-b"])
            let leftover = (try? fm.contentsOfDirectory(atPath: CodexRunHome.baseDirectory.path)) ?? []
            await t.check("실행 폴더는 실행이 끝나면 지운다", !leftover.contains { $0.hasPrefix("\(getpid())-") }, leftover.joined(separator: ", "))

            // 3) 재개하지 못하면 새 세션으로 넘어가지 않는다 — 실패로 끝내고 세션 연결을 그대로 둔다.
            if var broken = await session() {
                broken.cliSessionID = "BAD"
                try await store.upsertSession(broken)
            }
            _ = try await runner.send(prompt: "c", thread: thread, project: project, provider: .codex, account: accountB)
            await settle()
            let failedRun = ((try? await store.runs(threadID: thread.id)) ?? []).max { $0.startedAt < $1.startedAt }
            let afterBad = await session()
            await t.check("다른 계정의 재개 실패 → 실패로 끝냄 · 새 스레드 없음 · 세션 연결 그대로",
                          failedRun?.state == .failed && failedRun?.terminalReason == "resume_failed"
                            && lines("start.log").count == 1 && afterBad?.cliSessionID == "BAD" && afterBad?.resumable == true,
                          "\(failedRun?.terminalReason ?? "-") · \(String(describing: afterBad))")

            // 4) 기록 폴더가 사라졌으면 이어 갈 기록이 없다 — 실행 계정의 새 세션으로 시작하고 그 사실을 대화에 남긴다.
            if var moved = await session() {
                moved.cliSessionID = "S"
                moved.recordHome = root.appendingPathComponent("gone").path
                try await store.upsertSession(moved)
            }
            _ = try await runner.send(prompt: "d", thread: thread, project: project, provider: .codex, account: accountB)
            await settle()
            let events = (try? await store.events(threadID: thread.id)) ?? []
            let gone = await session()
            await t.check("기록 폴더가 없으면: 새 세션(계정B 의 홈) · 대화에 안내",
                          lines("start.log").count == 2 && lines("env.log").last == "\(homeB.path)||"
                            && events.contains { $0.kind == .systemNotice && $0.text.contains("찾지 못해") }
                            && gone?.recordHome.map { CodexRunHome.sameHome($0, homeB.path) } == true,
                          "\(lines("env.log").last ?? "-") · \(String(describing: gone?.recordHome))")

            // 5) 인증을 파일에 두지 않는 계정으로는 다른 폴더의 세션을 이어 가지 않는다 — 기록을 남기기 전에 막는다.
            let homeK = root.appendingPathComponent("homeK")
            try makeHome(homeK, config: "cli_auth_credentials_store = \"keyring\"\n")
            let before = ((try? await store.runs(threadID: thread.id)) ?? []).count
            var refused = false
            do {
                _ = try await runner.send(prompt: "e", thread: thread, project: project, provider: .codex,
                                          account: CodexAccountRef(id: "acct-k", label: "키체인", homePath: homeK.path))
            } catch { refused = "\(error)".contains("키체인") || error.localizedDescription.contains("키체인") }
            await settle()
            let after = ((try? await store.runs(threadID: thread.id)) ?? []).count
            await t.check("인증이 키체인인 계정: 시작하지 않고 까닭 · 실행 기록 없음", refused && after == before, "거절 \(refused) · \(before)→\(after)")
            await store.db.close()
        } catch {
            await t.check("가짜 codex 실행", false, "\(error)")
        }
    }

    // MARK: 앱

    static let claude = HandoffSource.Agent(provider: .claude, codexAccountID: nil)

    static func appFlows(_ t: TestKit) async throws {
        let env = try await HandoffCardTests.makeEnv("codex-switch")
        defer { env.cleanup() }
        let id = env.threads[0].id
        let a = try await ContinueAppTests.addAccount(env, id: "acct-a", label: "첫째", sortOrder: 0)
        let b = try await ContinueAppTests.addAccount(env, id: "acct-b", label: "둘째", sortOrder: 1)
        env.model.cliStatus[.codex] = CLIStatus(provider: .codex, resolvedPath: "/fake/codex", executable: true)

        // 이 대화에서 마지막으로 일한 것은 Codex · 첫째 (칩도 그쪽).
        await env.model.chooseAgent(.codex, accountID: "acct-a", threadID: id)
        _ = await env.model.send("첫째로 일", provider: .codex, threadID: id)
        await env.settle { !env.model.runner.isBusy(threadID: id) && env.model.threadStates[id]?.runsByID.count == 2 }
        await env.model.reloadThreadData(threadID: id)
        guard let thread = env.current(id) else { return await t.check("대화", false) }
        let shared = try? await env.store.session(threadID: id, provider: .codex)
        let sharedID = shared?.cliSessionID
        await t.check("Codex 세션은 대화의 칸 하나 · 기록 폴더 = 첫째의 홈",
                      sharedID != nil && shared?.accountID == ""
                        && shared?.recordHome == env.model.accounts.account("acct-a")?.homePath, "\(String(describing: shared))")

        // 칩 메뉴: 다른 계정 = 계정 바꾸기 (인계 카드 없음).
        let input = env.model.continueChoiceInput(for: thread)
        await t.equal("보내는 쪽 = Codex · 첫째 → 둘째 행은 계정 바꾸기", ContinueChoice.action(for: b, input), .switchAccount)
        await env.model.performContinueChoice(.switchAccount, agent: b, threadID: id)
        await t.check("계정 바꾸기: 칩만 둘째로 · 카드 없음 · 같은 세션을 이어 간다고 알림",
                      env.current(id)?.codexAccountID == "acct-b" && env.model.handoffCards[id] == nil
                        && env.model.banner?.text == CodexAccountSwitch.switchedNote(from: "첫째", to: "둘째", carries: true),
                      env.model.banner?.text ?? "")
        await t.equal("⇧⌘H 의 기본 받는 쪽은 반대편 (Codex 계정끼리는 인계하지 않는다)",
                      env.model.defaultHandoffTarget(for: env.current(id)!).provider, .claude)

        // 한도 줄의 [첫째 에서 이어 가기]: 첫째로 바꾸고 같은 세션에 이어 가기 메시지.
        let sentBefore = env.behavior.requests.count
        let started = await env.model.continueWithCodexAccount(threadID: id, accountID: "acct-a")
        await env.settle { !env.model.runner.isBusy(threadID: id) }
        let request = env.behavior.requests.dropFirst(sentBefore).first
        await t.check("이어 가기: 칩 = 첫째 · 이어 가기 메시지 · 대화의 세션 재개",
                      started && env.current(id)?.codexAccountID == "acct-a" && request?.prompt == CodexAccountSwitch.prompt
                        && request?.resumeSessionID == sharedID && request?.strictResume == false,
                      "\(String(describing: request?.prompt)) · \(String(describing: request?.resumeSessionID))")

        // 둘째로 이어 가면 그 실행은 엄격한 재개 (기록은 첫째의 홈).
        let beforeB = env.behavior.requests.count
        _ = await env.model.continueWithCodexAccount(threadID: id, accountID: "acct-b")
        await env.settle { !env.model.runner.isBusy(threadID: id) }
        let requestB = env.behavior.requests.dropFirst(beforeB).first
        await t.check("다른 계정의 실행: 엄격한 재개 (새 세션으로 넘어가지 않게)",
                      requestB?.strictResume == true && requestB?.resumeSessionID == sharedID, "\(String(describing: requestB?.strictResume))")

        // 제안 줄: 대상이 같은 Codex 의 다른 계정 → 바꾸기만 (보내지 않는다).
        let sourceB = env.model.normalizedHandoffAgent(b)
        let suggestion = ContinueSuggestion(source: sourceB, sourceScope: .codex("acct-b"),
                                            window: LimitWindow(label: "5시간", utilization: 0.8, spanMinutes: 300), span: .short,
                                            utilization: 0.8, target: env.model.normalizedHandoffAgent(a), targetTitle: "Codex · 첫째")
        await t.check("제안의 단추 글 = '… 에서 이어 가기'", suggestion.switchesCodexAccount
                        && suggestion.actionTitle == CodexAccountSwitch.title(name: "Codex · 첫째"))
        let beforeSuggestion = env.behavior.requests.count
        await env.model.acceptContinueSuggestion(suggestion, threadID: id)
        await t.check("제안의 [… 에서 이어 가기]: 칩만 바꾼다 · 카드 · 실행 없음",
                      env.current(id)?.codexAccountID == "acct-a" && env.model.handoffCards[id] == nil
                        && env.behavior.requests.count == beforeSuggestion)

        // 자동 카운트다운: 사람이 칩을 바꾸면 멈춘다 · [지금 이어 가기] 는 바로 이어 간다 · 그 사이 다른 실행이 있었으면 지난 일.
        let runs = (try? await env.store.runs(threadID: id)) ?? []
        guard let limitRun = runs.max(by: { $0.startedAt < $1.startedAt }) else { return await t.check("한도 실행", false) }
        env.model.startCodexSwitchCountdown(threadID: id, source: a, target: b, limitRun: limitRun)
        await t.check("카운트다운이 걸린다", env.model.codexSwitchCountdowns[id]?.target.codexAccountID == "acct-b")
        await countdownVisibility(t, env, threadID: id)
        await env.model.chooseAgent(.claude, accountID: nil, threadID: id)
        await t.check("사람이 칩을 바꾸면 카운트다운은 멈춘다", env.model.codexSwitchCountdowns[id] == nil)
        await t.check("멈추면 칸 머리 · Dock 배지 · 현황에서도 빠진다",
                      env.current(id).map { !env.model.paneStatusInput(for: $0).codexSwitchCountdown } == true
                        && !env.model.dockAttentionThreadIDs.contains(id)
                        && !env.model.overviewItems().contains { $0.threadID == id })
        await env.model.chooseAgent(.codex, accountID: "acct-a", threadID: id)
        env.model.startCodexSwitchCountdown(threadID: id, source: a, target: b, limitRun: limitRun)
        let beforeNow = env.behavior.requests.count
        await env.model.continueCodexSwitchNow(threadID: id)
        await env.settle { !env.model.runner.isBusy(threadID: id) }
        await t.check("[지금 이어 가기]: 둘째로 바꾸고 이어 가기 메시지",
                      env.model.codexSwitchCountdowns[id] == nil && env.current(id)?.codexAccountID == "acct-b"
                        && env.behavior.requests.dropFirst(beforeNow).first?.prompt == CodexAccountSwitch.prompt)
        env.model.startCodexSwitchCountdown(threadID: id, source: b, target: a, limitRun: limitRun)
        let beforeStale = env.behavior.requests.count
        await env.model.continueCodexSwitchNow(threadID: id)
        await t.check("한도에 닿은 실행 뒤에 다른 실행이 있었으면 이어 가지 않는다 (사람이 먼저 보냈다)",
                      env.model.codexSwitchCountdowns[id] == nil && env.behavior.requests.count == beforeStale)
        env.model.startCodexSwitchCountdown(threadID: id, source: b, target: a, limitRun: limitRun)
        // 앱 층(`applicationShouldTerminate`)과 같은 차례: 사실을 센 뒤 멈추고, 그 사실로 확인 글을 만든다.
        let quitFacts = env.model.quitFacts(busyShells: 0)
        env.model.suspendHandoffsForQuit()
        await t.check("앱 종료를 물으면 카운트다운을 멈춘다", env.model.codexSwitchCountdowns[id] == nil)
        let confirmation = QuitConfirmation.make(quitFacts)
        await t.check("종료 확인: 멈추기 전에 센 카운트다운을 확인 글이 말한다 (인계 카드가 아니다)",
                      quitFacts.codexSwitches == 1 && quitFacts.cards == 0
                        && confirmation?.title == "다른 계정에서 이어 가지 않고 종료할까요?"
                        && confirmation?.informativeText.contains("같은 세션을 이어 가려던 카운트다운을 멈췄습니다") == true,
                      confirmation?.informativeText ?? "nil")
        await t.equal("멈춘 뒤에 세면 0 — 그래서 앱 층은 먼저 센다", env.model.quitFacts(busyShells: 0).codexSwitches, 0)
        env.model.resumeHandoffsAfterCancelledQuit()
        await t.check("종료를 취소해도 다시 걸지 않는다 (한도 줄 · 칩에서 사람이 고른다)", env.model.codexSwitchCountdowns[id] == nil)

        // 카운트다운 중에 사람이 인계 카드를 열면(⇧⌘H · 칩 · 한도 줄) 카운트다운은 멈춘다 — 그대로 두면 울려도 카드가 막아
        // 아무 말 없이 사라졌다.
        env.model.startCodexSwitchCountdown(threadID: id, source: b, target: a, limitRun: limitRun)
        await env.model.prepareHandoff(to: .claude, threadID: id)
        await t.check("카운트다운 중에 사람이 인계 카드를 열면 카운트다운은 멈추고 카드가 생긴다",
                      env.model.codexSwitchCountdowns[id] == nil && env.model.handoffCards[id]?.targetProvider == .claude,
                      "카운트다운 \(env.model.codexSwitchCountdowns[id] != nil) · 카드 \(String(describing: env.model.handoffCards[id]?.targetProvider))")
        _ = claude
    }

    /// 계정 바꾸기 카운트다운이 인계 카드의 자동 인계 카운트다운이 보이는 곳에 같은 무게로 보인다 — 칸 머리 · 사이드바 행(같은 판정
    /// `PaneStatusInput`) · Dock 배지 · 메뉴바(`dockAttentionThreadIDs`) · 현황 · 종료 확인의 사실. 툴바 "응답 필요" 에는 자동 인계
    /// 카운트다운처럼 넣지 않는다 (답을 기다리는 것이 아니다).
    static func countdownVisibility(_ t: TestKit, _ env: HandoffCardTests.Env, threadID id: String) async {
        guard let thread = env.current(id), let countdown = env.model.codexSwitchCountdowns[id] else {
            return await t.check("계정 바꾸기 카운트다운이 있다", false)
        }
        let input = env.model.paneStatusInput(for: thread)
        let status = PaneStatus.make(input)
        // 답을 기다리지는 않는다(needsResponse false) — 툴바 "응답 필요" · 칸 머리 강조에 넣지 않는 것도 자동 인계 카운트다운과 같다.
        // (이 대화가 포커스라 `responseNeeded` 목록으로는 가릴 수 없어 그 판정 값을 본다.)
        await t.check("칸 머리 · 사이드바 행: \"다른 계정에서 이어 가기 대기\" — 카운트다운으로 센다 · 답을 기다리지는 않는다",
                      input.codexSwitchCountdown && input.countingDown && !input.handoffCountdown
                        && status?.text == CodexAccountSwitch.waitingText && status?.needsResponse == false,
                      status?.text ?? "nil")
        await t.check("Dock 배지 · 메뉴바는 센다 (포커스 대화여도)", env.model.dockAttentionThreadIDs == [id],
                      "\(env.model.dockAttentionThreadIDs)")
        let item = env.model.overviewItems().first { $0.threadID == id }
        await t.check("현황: 응답 필요 구역의 카운트다운 행 — 마감 · 시작한 때 · Codex",
                      item?.kind == .codexSwitch(deadline: countdown.deadline) && item?.provider == .codex
                        && item?.since == countdown.deadline.addingTimeInterval(-TimeInterval(countdown.delay))
                        && item?.running == false,
                      "\(String(describing: item?.kind))")
        let counts = env.model.overviewCounts
        await t.check("현황의 수 · 머리 문장 — 인계라 하지 않는다",
                      counts.codexSwitches == 1 && counts.countdowns == 0 && counts.waiting == 0
                        && Overview.headline(counts) == "실행 중인 에이전트는 없습니다. 1개는 곧 다른 계정에서 같은 세션을 이어 갑니다.",
                      Overview.headline(counts))
        await t.equal("종료 확인의 사실이 센다", env.model.quitFacts(busyShells: 0).codexSwitches, 1)
    }
}
