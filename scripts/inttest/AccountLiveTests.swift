import Foundation

/// 등록된 두 Codex 계정 사이의 실제 왕복 검증 — 계정A 에서 시작한 대화의 Codex 세션을 계정B 가 인계 없이 그대로 이어 가고(`CodexRunHome`)
/// 다시 계정A 로 돌아온다. 사용량은 실행한 계정에 갈린다.
///
/// 앱의 DB 를 건드리지 않기 위해 임시 저장소를 쓰고, 계정 홈만 실제 것을 찾아 쓴다.
/// 로그인된 홈이 둘 미만이면 건너뛴다 (없는 것을 통과로 만들지 않는다).
enum AccountLiveTests {

    /// 로그인된 Codex 홈을 찾는다: CLI 기본 홈 + `~/.codex-accounts/*`.
    static func discoverHomes() -> [(home: String, identity: CodexAccountInspector.Identity)] {
        var homes = [CodexAccountInspector.defaultHomePath()]
        let accountsRoot = (NSHomeDirectory() as NSString).appendingPathComponent(".codex-accounts")
        let children = (try? FileManager.default.contentsOfDirectory(atPath: accountsRoot)) ?? []
        for child in children.sorted() {
            homes.append((accountsRoot as NSString).appendingPathComponent(child))
        }
        return homes.compactMap { home in
            let identity = CodexAccountInspector.inspect(home: home)
            guard identity.status == .loggedIn else { return nil }
            return (home, identity)
        }
    }

    @MainActor
    static func run(_ t: TestKit, _ e: LiveTests.Env) async {
        await t.group("실제 CLI · 두 계정 왕복")

        let found = discoverHomes()
        guard found.count >= 2 else {
            await t.check("로그인된 Codex 계정 2개 확인", false,
                          "찾은 계정 \(found.count)개 — 두 번째 계정 로그인이 필요합니다")
            return
        }
        let a = found[0]
        let b = found[1]
        let accountA = CodexAccountRef(id: CodexAccount.defaultID, label: "계정A",
                                       homePath: a.home)
        let accountB = CodexAccountRef(id: "account-b", label: "계정B", homePath: b.home)
        // 1) 한도가 계정별로 따로 읽힌다 (같은 값이면 같은 계정을 본 것이다). 누구 계정인지는 같은 app-server 의 account/read 로.
        let cliEnv = CLIEnvironment()
        let envA = await cliEnv.childEnvironment(codexHome: a.home)
        let envB = await cliEnv.childEnvironment(codexHome: b.home)
        let fetchedA = await LimitsFetcher.fetchCodexWithAccount(path: e.codex, environment: envA,
                                                                 accountID: accountA.id)
        let fetchedB = await LimitsFetcher.fetchCodexWithAccount(path: e.codex, environment: envB,
                                                                 accountID: accountB.id)
        let limitsA = fetchedA.limits
        let limitsB = fetchedB.limits
        await t.check("서로 다른 계정 확인",
                      a.identity.chatgptAccountID != b.identity.chatgptAccountID,
                      "A=\(masked(fetchedA.account, a.identity)) / B=\(masked(fetchedB.account, b.identity))")
        await t.check("account/read 의 계정 ID 가 auth.json 과 같다",
                      fetchedA.account?.chatgptAccountID == a.identity.chatgptAccountID
                        && fetchedB.account?.chatgptAccountID == b.identity.chatgptAccountID)
        await t.check("계정A 한도 조회", limitsA.hasUsableData, describe(limitsA))
        await t.check("계정B 한도 조회", limitsB.hasUsableData, describe(limitsB))
        await t.check("두 계정의 한도가 각각 따로 읽힘",
                      describe(limitsA) != describe(limitsB),
                      "A: \(describe(limitsA)) / B: \(describe(limitsB))")

        // 2) 앱과 같은 경로(RunCoordinator)로 계정A 에서 한 턴 실행한다.
        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ahc-acctlive-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let store = Store(databaseURL: dbURL)
        do { try await store.bootstrap() } catch {
            await t.check("저장 계층 준비", false, "\(error)")
            return
        }
        let coordinator = RunCoordinator(store: store, environment: cliEnv)
        coordinator.codexApprovalPolicy = "never"
        coordinator.codexSandboxMode = "workspace-write"
        await coordinator.loadPrices()
        let probe = CoordinatorProbe(coordinator: coordinator)
        coordinator.delegate = probe

        let project = Project(name: "acct", path: e.root.path)
        try? await store.upsertProject(project)
        var thread = ConversationThread(projectID: project.id, title: "계정 전환 검증")
        thread.goal = "account_state.json 을 계정별로 갱신"
        thread.pinnedNotes = "marker 값은 바꾸지 말 것"
        thread.codexAccountID = accountA.id
        if let model = LiveTests.codexModelOverride {
            thread.codexSelection = ModelSelection(model: model,
                                                   effort: LiveTests.codexEffortOverride)
        }
        try? await store.upsertThread(thread)

        let statePath = e.root.appendingPathComponent("account_state.json")
        try? FileManager.default.removeItem(at: statePath)
        let marker = "ACCT-\(Int.random(in: 1000...9999))"
        // 대화에만 알려 주는 표식 — 파일에 쓰지 않는다. 계정B 가 이것을 맞히면 같은 세션의 맥락을 이어 받은 것이다.
        let secret = "WORD-\(Int.random(in: 1000...9999))"

        do {
            _ = try await coordinator.send(
                prompt: "\(statePath.path) 파일을 정확히 이 내용으로 만드세요: "
                    + "{\"marker\":\"\(marker)\",\"stage\":\"a\",\"count\":1} "
                    + "그리고 시험용 표식 \(secret) 를 기억해 두세요 (파일에는 쓰지 마세요). 끝나면 DONE 이라고만 답하세요.",
                thread: thread, project: project, provider: .codex, account: accountA)
        } catch {
            await t.check("계정A 실행 시작", false, "\(error)")
            await store.db.close()
            return
        }
        let settledA = await probe.waitUntilIdle(timeout: 300)
        await t.check("계정A 실행 종료", settledA, coordinator.state.koreanName)
        await t.check("계정A 가 파일 생성",
                      FileManager.default.fileExists(atPath: statePath.path))

        let runsA = (try? await store.runs(threadID: thread.id)) ?? []
        await t.equal("실행에 계정A 기록", runsA.first?.codexAccountID ?? "", accountA.id)
        let sessionA = try? await store.session(threadID: thread.id, provider: .codex)
        await t.check("대화의 Codex 세션 저장", (sessionA?.cliSessionID?.count ?? 0) > 10,
                      sessionA?.cliSessionID ?? "없음")
        await t.check("세션의 기록 폴더 = 계정A 의 홈",
                      sessionA?.recordHome.map { CodexRunHome.sameHome($0, a.home) } == true, sessionA?.recordHome ?? "없음")

        // 3) 계정A → 계정B: 인계하지 않고 계정만 바꿔 같은 세션을 이어 간다 (`CodexRunHome`).
        do {
            _ = try await coordinator.send(
                prompt: "\(statePath.path) 의 count 를 2, stage 를 b 로 바꾸고, note 필드에 앞서 알려 준 시험용 표식을 넣으세요 "
                    + "(파일을 읽지 말고 기억으로). marker 는 그대로 두세요. 끝나면 DONE 이라고만 답하세요.",
                thread: thread, project: project, provider: .codex, account: accountB)
        } catch {
            await t.check("계정B 로 이어 가기 시작", false, "\(error)")
            await store.db.close()
            return
        }
        let settledB = await probe.waitUntilIdle(timeout: 300)
        await t.check("계정B 실행 종료", settledB, coordinator.state.koreanName)
        let afterB = (try? String(contentsOf: statePath, encoding: .utf8)) ?? ""
        await t.check("계정B 가 같은 세션의 맥락으로 파일 수정 (count 2 · 대화에만 있던 표식)",
                      (afterB.contains("\"count\":2") || afterB.contains("\"count\": 2")) && afterB.contains(secret),
                      JSONUtil.truncate(afterB, max: 200))
        await t.check("marker 보존", afterB.contains(marker))
        let runB = ((try? await store.runs(threadID: thread.id)) ?? []).max { $0.startedAt < $1.startedAt }
        await t.equal("이어 간 실행에 계정B 기록", runB?.codexAccountID ?? "", accountB.id)
        let sessionB = try? await store.session(threadID: thread.id, provider: .codex)
        await t.equal("세션 ID 가 그대로 (같은 세션)", sessionB?.cliSessionID ?? "", sessionA?.cliSessionID ?? "")
        await t.check("기록 폴더도 그대로 계정A 의 홈",
                      sessionB?.recordHome.map { CodexRunHome.sameHome($0, a.home) } == true, sessionB?.recordHome ?? "없음")
        await t.check("인계 기록 없음", ((try? await store.handoffs(threadID: thread.id)) ?? []).isEmpty)
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: CodexRunHome.baseDirectory.path)) ?? []
        await t.check("실행 폴더는 실행이 끝나면 지운다",
                      !leftover.contains { $0.hasPrefix("\(getpid())-\(runB?.id ?? "")") }, leftover.joined(separator: ", "))
        let sessionID = sessionA?.cliSessionID ?? "-"
        let inB = FileManager.default.enumerator(atPath: (b.home as NSString).appendingPathComponent("sessions"))?
            .compactMap { $0 as? String }.contains { $0.contains(sessionID) } ?? false
        await t.check("세션 기록은 계정B 의 홈에 생기지 않는다 (기록 폴더는 계정A)", !inB)

        // 4) 계정B → 계정A: 다시 같은 세션.
        do {
            _ = try await coordinator.send(
                prompt: "\(statePath.path) 의 count 를 3, stage 를 c 로 바꾸세요. 나머지는 그대로 두세요. 끝나면 DONE 이라고만 답하세요.",
                thread: thread, project: project, provider: .codex, account: accountA)
        } catch {
            await t.check("계정A 로 되돌아가기 시작", false, "\(error)")
            await store.db.close()
            return
        }
        let settledBack = await probe.waitUntilIdle(timeout: 300)
        await t.check("계정A 실행 종료 (되돌아감)", settledBack, coordinator.state.koreanName)
        let afterBack = (try? String(contentsOf: statePath, encoding: .utf8)) ?? ""
        await t.check("계정A 가 이어서 수정 (count 3 · 표식 · marker 보존)",
                      (afterBack.contains("\"count\":3") || afterBack.contains("\"count\": 3"))
                        && afterBack.contains(secret) && afterBack.contains(marker),
                      JSONUtil.truncate(afterBack, max: 200))
        let sessionBack = try? await store.session(threadID: thread.id, provider: .codex)
        await t.equal("세 실행 모두 같은 세션", sessionBack?.cliSessionID ?? "", sessionA?.cliSessionID ?? "")
        await t.equal("스레드의 세션 수 (대화의 칸 하나)", ((try? await store.sessions(threadID: thread.id)) ?? []).count, 1)

        // 6) 사용량이 계정별로 갈린다
        let usage = (try? await store.usage(threadID: thread.id)) ?? []
        let runByID = Dictionary(uniqueKeysWithValues:
            ((try? await store.runs(threadID: thread.id)) ?? []).map { ($0.id, $0) })
        let usageA = usage.filter { runByID[$0.runID]?.codexAccountID == accountA.id }
        let usageB = usage.filter { runByID[$0.runID]?.codexAccountID == accountB.id }
        await t.check("계정A 사용량 기록", !usageA.isEmpty,
                      "\(usageA.reduce(0) { $0 + $1.totalTokens }) 토큰")
        await t.check("계정B 사용량 기록", !usageB.isEmpty,
                      "\(usageB.reduce(0) { $0 + $1.totalTokens }) 토큰")
        await t.check("사용한 모델 기록", usage.allSatisfy { $0.model != nil },
                      usage.compactMap { $0.model }.joined(separator: ", "))

        await store.db.close()
    }

    /// 이메일 전체를 로그에 남기지 않는다.
    private static func masked(_ read: CodexAccountInspector.AccountRead?, _ identity: CodexAccountInspector.Identity) -> String {
        guard let email = read?.email, let at = email.firstIndex(of: "@") else {
            return identity.chatgptAccountID.map { String($0.prefix(8)) + "…" } ?? "식별 불가"
        }
        return String(email.prefix(2)) + "***" + String(email[at...])
    }

    private static func describe(_ snapshot: LimitSnapshot) -> String {
        guard snapshot.hasUsableData else {
            return snapshot.status.koreanName + " / " + (snapshot.message ?? "")
        }
        return snapshot.windows
            .map { "\($0.label) \($0.utilization.map { String(format: "%.0f%%", $0 * 100) } ?? "정보 없음")" }
            .joined(separator: ", ")
    }
}
