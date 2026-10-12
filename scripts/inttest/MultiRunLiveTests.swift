import Foundation

/// 여러 대화의 동시 실행 · 실제 CLI 실측.
/// 앱의 실제 `AppModel` 을 임시 DB · 임시 git 저장소로 띄워, **같은 폴더에서** 두 실행을 동시에 보낸다:
///   A. Claude 둘   B. Claude + Codex   C. 같은 Codex 계정(같은 `CODEX_HOME`) 둘
/// 각 쌍은 파일을 하나씩 만들고, 이어서 **동시에 재개**해 자기가 만든 파일 이름을 답하게 한다 — 세션이 서로 섞이거나
/// 세션 파일이 동시 쓰기로 깨졌다면 재개가 실패하거나 남의 파일 이름을 답한다.
/// 모델은 싼 것으로 고정한다: Claude `haiku`, Codex `gpt-5.6-luna`(low). 실제 한도를 쓴다.
@MainActor
enum MultiRunLiveTests {
    static let claudeModel = "haiku"
    static let codexModel = "gpt-5.6-luna"

    static func run(_ t: TestKit) async {
        await t.group("여러 대화의 동시 실행 · 실제 CLI")
        let root: URL
        do { root = try TestEnv.makeTempProject("multirun") } catch {
            await t.check("임시 프로젝트 생성", false, "\(error)")
            return
        }
        let folder = root.appendingPathComponent("project", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? "# 동시 실행 실측용 임시 프로젝트\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let env = await CLIEnvironment().childEnvironment()
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.invalid"], ["config", "user.name", "t"],
                          ["add", "-A"], ["commit", "-q", "-m", "base"]] {
            _ = await CLIEnvironment.captureOutput(executable: "/usr/bin/git", arguments: arguments, environment: env,
                                                   workingDirectory: folder, timeout: 20)
        }
        print("임시 테스트 프로젝트: \(folder.path)\n")

        let store = Store(databaseURL: root.appendingPathComponent("handoff.sqlite3"))
        let model = AppModel(store: store)
        await model.bootstrap()
        await t.check("앱 모델 부트스트랩", model.bootstrapError == nil, model.bootstrapError ?? "")
        guard model.bootstrapError == nil else { return }
        model.claudePermissionMode = "acceptEdits"
        model.automaticHandoffEnabled = false
        let project = await model.addProject(name: "multirun", path: folder.path)

        func thread(_ title: String, _ provider: AgentProvider) async -> ConversationThread {
            var thread = ConversationThread(projectID: project.id, title: title)
            thread.preferredProvider = provider
            thread.claudeSelection = ModelSelection(model: claudeModel, effort: nil)
            thread.codexSelection = ModelSelection(model: codexModel, effort: "low")
            try? await store.upsertThread(thread)
            return thread
        }
        let claude1 = await thread("Claude 1", .claude), claude2 = await thread("Claude 2", .claude)
        let codex1 = await thread("Codex 1", .codex), codex2 = await thread("Codex 2", .codex)
        await model.reloadProjects()

        // 승인 요청이 오면 허용한다 (임시 폴더에서만 쓴다). 어느 실행의 것이든 그 실행에만 간다.
        var peak = 0
        let approver = Task { @MainActor in
            while !Task.isCancelled {
                peak = max(peak, model.runner.activeSessions.count)
                for session in model.runner.activeSessions {
                    for request in session.pendingApprovals { await model.runner.respond(approval: request, decision: .allow) }
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        defer { approver.cancel() }

        struct Turn { let thread: ConversationThread; let provider: AgentProvider; let prompt: String }
        /// 두 턴을 거의 동시에 보내고 둘 다 끝날 때까지 기다린다. 걸린 시간(초)과 그 사이 동시에 돌던 실행 수의 최댓값.
        func together(_ turns: [Turn], timeout: TimeInterval = 420) async -> (sent: [Bool], seconds: Double, peak: Int) {
            peak = 0
            let started = Date()
            var sent: [Bool] = []
            for turn in turns {
                sent.append(await model.send(turn.prompt, provider: turn.provider, threadID: turn.thread.id))
                if sent.last == false { await t.note("보내지 못함 (\(turn.thread.title)): \(model.banner?.text ?? "")") }
            }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let busy = turns.contains { model.runner.session(threadID: $0.thread.id) != nil } || model.isFinishingRunChanges
                if !busy { break }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            return (sent, Date().timeIntervalSince(started), peak)
        }
        func create(_ name: String, _ word: String) -> String {
            "이 폴더에 \(name) 파일을 만들고 그 안에 \(word) 라고 한 줄만 쓰세요. 다른 파일은 건드리지 마세요. 끝나면 DONE 이라고만 답하세요."
        }
        let recall = "이 대화에서 당신이 방금 만든 파일의 이름만 한 줄로 답하세요. 파일을 새로 만들거나 고치지 마세요."
        func lastRun(_ thread: ConversationThread) async -> Run? { (try? await store.runs(threadID: thread.id))?.max { $0.startedAt < $1.startedAt } }
        func lastAnswer(_ thread: ConversationThread) async -> String {
            guard let run = await lastRun(thread) else { return "" }
            return ((try? await store.events(threadID: thread.id)) ?? []).filter { $0.runID == run.id && $0.kind == .agentMessage }
                .map(\.text).joined(separator: " ")
        }
        func content(_ name: String) -> String { (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        func cliSession(_ thread: ConversationThread, _ provider: AgentProvider) async -> String? {
            (try? await store.session(threadID: thread.id, provider: provider))?.cliSessionID
        }

        /// 한 쌍의 실측: 동시에 만들기 → 동시에 재개해 자기 파일 이름 답하기.
        func pair(_ label: String, _ a: (ConversationThread, AgentProvider, String, String),
                  _ b: (ConversationThread, AgentProvider, String, String)) async {
            await t.note("── \(label)")
            let made = await together([Turn(thread: a.0, provider: a.1, prompt: create(a.2, a.3)),
                                       Turn(thread: b.0, provider: b.1, prompt: create(b.2, b.3))])
            await t.check("\(label): 둘 다 시작됐다", made.sent == [true, true])
            await t.equal("\(label): 실제로 동시에 돌았다 (동시 실행 수)", made.peak, 2)
            let runA = await lastRun(a.0), runB = await lastRun(b.0)
            await t.check("\(label): 둘 다 완료", runA?.state == .completed && runB?.state == .completed,
                          "\(runA?.state.rawValue ?? "없음") \(runA?.errorMessage ?? "") / \(runB?.state.rawValue ?? "없음") \(runB?.errorMessage ?? "")")
            await t.check("\(label): 각자의 파일이 만들어졌다", content(a.2).contains(a.3) && content(b.2).contains(b.3),
                          "\(a.2)=\(content(a.2).prefix(20)) \(b.2)=\(content(b.2).prefix(20))")
            let sessionA = await cliSession(a.0, a.1), sessionB = await cliSession(b.0, b.1)
            await t.check("\(label): CLI 세션이 따로 잡혔다", sessionA != nil && sessionB != nil && sessionA != sessionB,
                          "\(sessionA ?? "nil") / \(sessionB ?? "nil")")
            for (thread, run) in [(a.0, runA), (b.0, runB)] {
                let events = (try? await store.events(threadID: thread.id)) ?? []
                let runIDs = Set(((try? await store.runs(threadID: thread.id)) ?? []).map(\.id))
                await t.check("\(label): \(thread.title) 의 기록에 다른 실행의 이벤트가 섞이지 않았다",
                              events.allSatisfy { $0.runID.map(runIDs.contains) ?? true } && events.contains { $0.runID == run?.id && $0.kind == .agentMessage })
                let changes = events.filter { $0.runID == run?.id }.compactMap { RunFileChanges.decode($0) }.first
                await t.check("\(label): \(thread.title) 의 변경 카드는 '겹침' (같은 폴더에서 함께 돌았다)",
                              changes?.compared == false && changes?.unavailable == .overlapped, String(describing: changes?.unavailable))
                let usage = ((try? await store.usage(threadID: thread.id)) ?? []).first { $0.runID == run?.id }
                await t.note("\(thread.title): 모델 \(usage?.model ?? run?.model ?? "미확인") · 출력 \(usage?.outputTokens ?? 0) tok · \(String(format: "%.1f", Double(usage?.durationMs ?? 0) / 1000))초")
            }
            await t.note("\(label): 만들기 \(String(format: "%.1f", made.seconds))초 (둘이 함께)")

            let recalled = await together([Turn(thread: a.0, provider: a.1, prompt: recall), Turn(thread: b.0, provider: b.1, prompt: recall)])
            let answerA = await lastAnswer(a.0), answerB = await lastAnswer(b.0)
            let resumedA = await lastRun(a.0), resumedB = await lastRun(b.0)
            await t.check("\(label): 동시에 재개해도 둘 다 완료", recalled.sent == [true, true]
                            && resumedA?.state == .completed && resumedB?.state == .completed,
                          "\(resumedA?.state.rawValue ?? "") \(resumedA?.errorMessage ?? "") / \(resumedB?.state.rawValue ?? "") \(resumedB?.errorMessage ?? "")")
            await t.check("\(label): 각자 자기 세션을 이어 갔다 (자기가 만든 파일을 안다 · 남의 파일을 말하지 않는다)",
                          answerA.contains(a.2) && !answerA.contains(b.2) && answerB.contains(b.2) && !answerB.contains(a.2),
                          "\(a.0.title): \(answerA.prefix(60)) / \(b.0.title): \(answerB.prefix(60))")
            let keptA = await cliSession(a.0, a.1), keptB = await cliSession(b.0, b.1)
            await t.check("\(label): 재개한 세션 ID 가 그대로다", keptA == sessionA && keptB == sessionB)
            await t.note("\(label): 재개 \(String(format: "%.1f", recalled.seconds))초 (둘이 함께)")
        }

        await pair("A. 같은 폴더 · Claude 둘", (claude1, .claude, "alpha.txt", "ALPHA"), (claude2, .claude, "beta.txt", "BETA"))
        await pair("B. 같은 폴더 · Claude + Codex", (claude1, .claude, "gamma.txt", "GAMMA"), (codex1, .codex, "delta.txt", "DELTA"))
        await pair("C. 같은 Codex 계정 둘 (같은 CODEX_HOME)", (codex1, .codex, "epsilon.txt", "EPSILON"), (codex2, .codex, "zeta.txt", "ZETA"))

        let models = Set(((try? await store.usage(threadID: claude1.id)) ?? []).compactMap(\.model)
                         + ((try? await store.usage(threadID: claude2.id)) ?? []).compactMap(\.model)
                         + ((try? await store.usage(threadID: codex1.id)) ?? []).compactMap(\.model)
                         + ((try? await store.usage(threadID: codex2.id)) ?? []).compactMap(\.model))
        await t.check("싼 모델만 썼다 (haiku · luna)", models.allSatisfy { $0.contains("haiku") || $0.contains("luna") }, models.sorted().joined(separator: ", "))
        await t.check("끝난 뒤 남은 실행 · 종료 미확인 프로세스가 없다", model.runner.activeSessions.isEmpty && model.runner.unterminatedProcesses.isEmpty,
                      model.runner.unterminatedProcesses.joined(separator: " | "))
        print("\n임시 프로젝트 유지: \(root.path)")
    }
}
