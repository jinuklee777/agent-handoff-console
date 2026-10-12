import Foundation

// MARK: - 대화 제목: 첫 메시지 제목 · 요약 제목

/// 대화 제목의 순수 판정(`ThreadTitle`)과 앱 흐름(`AppModel.summarizeTitleIfNeeded`). 앱 흐름은 실제 `RunCoordinator` · SQLite 를
/// 거치고 CLI 만 가짜(`ScriptedAgentAdapter`), 요약은 `threadTitleSummarizerOverride` 로 바꿔 끼운다 — 실제 CLI 를 부르지 않는다.
@MainActor
enum ThreadTitleTests {

    static func run(_ t: TestKit) async {
        await pure(t)
        do { try await appFlow(t) } catch {
            await t.group("앱 흐름: 대화 제목 자동 요약")
            await t.check("시나리오 실행 중 예외", false, "\(error)")
        }
    }

    static func pure(_ t: TestKit) async {
        await t.group("대화 제목: 첫 메시지 제목 · 요약 다듬기 (순수)")
        await t.equal("첫 줄 · 머리 기호를 뗀다", ThreadTitle.fromMessage("## 로그인 버그\n자세한 설명"), "로그인 버그")
        await t.equal("태그로 감싼 덧붙은 맥락은 통째로 건너뛴다",
                      ThreadTitle.fromMessage("<recommended_plugins>\nHere is a list\n- a\n</recommended_plugins>\n사이드바 정리해줘"),
                      "사이드바 정리해줘")
        await t.equal("닫는 태그가 없으면 그 줄만 건너뛴다", ThreadTitle.fromMessage("<note>\n사이드바 정리해줘"), "사이드바 정리해줘")
        await t.equal("태그 줄 · 빈 줄 뒤의 첫 글",
                      ThreadTitle.fromMessage("\n<context>\n\n  사이드바 정리해줘  "), "사이드바 정리해줘")
        await t.check("태그 판정: 여는 · 닫는 태그만", ThreadTitle.isTagLine("<recommended_plugins>") && ThreadTitle.isTagLine("</x>")
                        && !ThreadTitle.isTagLine("<b>굵게</b> 해줘") && !ThreadTitle.isTagLine("<>"))
        let long = String(repeating: "가", count: 50)
        await t.equal("34자에서 자른다", ThreadTitle.fromMessage(long), String(repeating: "가", count: 34) + "…")
        await t.equal("쓸 줄이 없으면 새 대화", ThreadTitle.fromMessage("<a>\n\n"), "새 대화")
        await t.check("앱이 붙인 제목인지 (이미지만 보낸 대화 포함)",
                      ThreadTitle.isAutomatic("로그인 버그", firstMessage: "# 로그인 버그\n더")
                        && ThreadTitle.isAutomatic("이미지", firstMessage: "")
                        && !ThreadTitle.isAutomatic("내가 붙인 이름", firstMessage: "로그인 버그"))

        await t.equal("답 다듬기: 따옴표 · 머리 · 끝 마침표", ThreadTitle.cleaned("Title: \"사이드바 정리.\"\n설명"), "사이드바 정리")
        await t.equal("답 다듬기: 빈 줄 뒤 첫 줄 · 꺾쇠 따옴표", ThreadTitle.cleaned("\n「Claude 와 GPT 비교」"), "Claude 와 GPT 비교")
        await t.check("지시를 따르지 않은 답은 버린다 (비었거나 40자 넘음)",
                      ThreadTitle.cleaned("  \n ") == nil && ThreadTitle.cleaned(String(repeating: "a", count: 41)) == nil)
        await t.equal("Claude 의 json 결과", ThreadTitle.title(fromOutput: #"{"type":"result","is_error":false,"result":"Claude vs GPT 비교"}"#,
                                                         provider: .claude), "Claude vs GPT 비교")
        await t.check("Claude 의 오류 결과 · json 아님은 버린다",
                      ThreadTitle.title(fromOutput: #"{"is_error":true,"result":"Not logged in"}"#, provider: .claude) == nil
                        && ThreadTitle.title(fromOutput: "Error: boom", provider: .claude) == nil)
        await t.equal("Codex 는 stdout 의 답", ThreadTitle.title(fromOutput: "앱 대화창 디자인 비교\n", provider: .codex), "앱 대화창 디자인 비교")

        await t.equal("Codex 는 가장 작은 계열(luna)의 최신", ThreadTitle.codexModel(from: ["gpt-6.1-sol", "gpt-5.6-luna", "gpt-6-luna", "gpt-6-astra"]),
                      "gpt-6-luna")
        await t.equal("luna 가 없으면 CLI 기본", ThreadTitle.codexModel(from: ["gpt-6-sol", "gpt-6-astra"]), nil)

        let secret = "sk-ant-api03-" + String(repeating: "A", count: 40)
        let input = ThreadTitle.input(firstMessage: "키는 ANTHROPIC_API_KEY=\(secret) 야\n" + String(repeating: "나", count: 2_000),
                                      firstAnswer: "  답입니다  ")
        await t.check("요약 입력: 비밀값을 가리고 첫 메시지를 자른다", !input.contains(secret)
                        && input.count < ThreadTitle.messageLimit + ThreadTitle.answerLimit + 200, "\(input.count)자")
        await t.check("요약 입력: 첫 답을 표시로 감싼다", input.contains("<agent answer (beginning)>\n답입니다\n"))
        await t.check("요약 입력: 첫 답이 없으면 메시지만", !ThreadTitle.input(firstMessage: "a", firstAnswer: nil).contains("agent answer"))

        // API 키로 실행하는 대화의 제목은 같은 키로 묻는다 — 구독 로그인으로 보내지 않는다.
        let base = ["PATH": "/usr/bin", "ANTHROPIC_AUTH_TOKEN": "구독-토큰"]
        let plain = ThreadTitle.Request(provider: .claude, input: "x", codexModel: nil)
        var viaAPI = plain
        viaAPI.viaClaudeAPI = true
        await t.equal("구독 대화: 환경 그대로", ThreadTitle.environment(base, for: plain, apiKey: "sk-ant-api03-k"), base)
        let keyed = ThreadTitle.environment(base, for: viaAPI, apiKey: "sk-ant-api03-k")
        await t.check("API 대화: 키를 넣고 앞 순위 자격을 뺀다 (대화 실행과 같은 환경)",
                      keyed?["ANTHROPIC_API_KEY"] == "sk-ant-api03-k" && keyed?["ANTHROPIC_AUTH_TOKEN"] == nil
                        && keyed == ClaudeAPIKey.environment(base, apiKey: "sk-ant-api03-k"))
        await t.check("API 대화인데 키가 없으면 묻지 않는다 (구독으로 보내지 않음)",
                      ThreadTitle.environment(base, for: viaAPI, apiKey: nil) == nil)
        var codexAPI = viaAPI
        codexAPI.provider = .codex
        await t.equal("Codex 는 Claude 키와 무관", ThreadTitle.environment(base, for: codexAPI, apiKey: nil), base)
    }

    /// 첫 턴이 끝나면 요약 제목으로 바뀐다 · 두 번째 턴은 묻지 않는다 · 묻는 사이 사람이 바꾼 이름은 그대로 · 실패하면 첫 메시지 제목 ·
    /// 설정을 끄면 묻지 않는다 · Codex 는 그 계정의 luna 로 · 이미 쓰던 대화는 묻지 않는다.
    static func appFlow(_ t: TestKit) async throws {
        await t.group("앱 흐름: 대화 제목 자동 요약")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-titles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
        try await store.bootstrap()
        let project = Project(name: "p", path: folder.path)
        try await store.upsertProject(project)

        func thread(_ title: String, _ provider: AgentProvider = .claude) async throws -> ConversationThread {
            var thread = ConversationThread(projectID: project.id, title: title)
            thread.preferredProvider = provider
            thread.claudeSelection = ModelSelection(model: "opus", effort: "high")
            thread.codexSelection = ModelSelection(model: "gpt-6-astra", effort: "low")
            try await store.upsertThread(thread)
            return thread
        }
        let fresh = try await thread("새 대화")
        let renamedLater = try await thread("새 대화")
        let failing = try await thread("새 대화")
        let switchedOff = try await thread("새 대화")
        let codex = try await thread("새 대화", .codex)
        var old = try await thread("오래된 대화")
        old.title = "이미 쓰던 대화"
        try await store.upsertThread(old)

        let model = AppModel(store: store)
        let done = AgentTurnResult(state: .completed, terminalReason: "completed", sessionID: "s")
        model.runner.adapterFactory = { provider in
            ScriptedAgentAdapter(provider: provider) { _ in
                [.emit(.sessionEstablished(sessionID: "s", model: "fake", cliVersion: nil)),
                 .emit(.assistantMessage("첫 답입니다")), .finish(done)]
            }
        }
        let claudeList = [AgentModelOption(provider: .claude, identifier: "opus", displayName: "Opus", supportedEfforts: ModelCatalog.claudeEfforts,
                                           isDefault: true, isDiscovered: true)]
        let codexList = ["gpt-6-astra", "gpt-6-luna", "gpt-5.6-luna"].map {
            AgentModelOption(provider: .codex, identifier: $0, displayName: $0, supportedEfforts: ["low", "medium"],
                             isDefault: $0 == "gpt-6-astra", isDiscovered: true)
        }
        model.modelCatalogFetchOverride = { scope in
            var snapshot = ModelCatalogSnapshot(provider: scope.provider, accountID: scope.accountID)
            snapshot.fetchedAt = Date()
            snapshot.options = scope.provider == .claude ? claudeList : codexList
            snapshot.discovered = true
            return snapshot
        }
        await model.reloadProjects()
        await model.refreshModelCatalog(.claude)
        await model.refreshModelCatalog(.codex(CodexAccount.defaultID))

        final class Box: @unchecked Sendable {
            var requests: [String: ThreadTitle.Request] = [:]
            var answers: [String: String?] = [:]
            var delays: [String: UInt64] = [:]
        }
        let box = Box()
        // 요약 입력의 첫 메시지로 어느 대화인지 안다.
        func key(_ request: ThreadTitle.Request) -> String {
            request.input.components(separatedBy: "\n").dropFirst().first ?? ""
        }
        model.threadTitleSummarizerOverride = { request in
            let k = await MainActor.run { () -> String in
                let k = key(request)
                box.requests[k] = request
                return k
            }
            let delay = await MainActor.run { box.delays[k] ?? 0 }
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            return await MainActor.run { box.answers[k] ?? "요약 제목" }
        }
        func title(_ id: String) -> String? { model.allThreads().first { $0.id == id }?.title }
        func settle(_ condition: @MainActor () -> Bool) async {
            for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        func sendAndWait(_ prompt: String, _ thread: ConversationThread) async -> Bool {
            let sent = await model.send(prompt, provider: thread.preferredProvider, threadID: thread.id)
            await settle { model.runner.session(threadID: thread.id) == nil && !model.isSending(threadID: thread.id) }
            return sent
        }

        // 1) 첫 턴이 끝나면 요약 제목으로.
        box.answers["사이드바가 지저분해 보이는데 비교해줘"] = "사이드바 비교"
        let sent = await sendAndWait("사이드바가 지저분해 보이는데 비교해줘\n자세히", fresh)
        await settle { title(fresh.id) == "사이드바 비교" }
        let request = box.requests["사이드바가 지저분해 보이는데 비교해줘"]
        await t.check("첫 턴이 끝나면 요약 제목으로 바뀐다", sent && title(fresh.id) == "사이드바 비교", "\(String(describing: title(fresh.id)))")
        await t.check("그 대화의 에이전트에게 첫 메시지 · 첫 답을 보낸다",
                      request?.provider == .claude && request?.codexModel == nil && request?.input.contains("첫 답입니다") == true)
        box.requests = [:]
        _ = await sendAndWait("두 번째 부탁", fresh)
        try? await Task.sleep(nanoseconds: 200_000_000)
        await t.check("두 번째 턴은 묻지 않는다", box.requests.isEmpty && title(fresh.id) == "사이드바 비교")

        // 2) 묻는 사이 사람이 이름을 바꾸면 그 이름이 남는다.
        box.answers["이름 바꿀 대화"] = "요약이 덮으면 안 됨"
        box.delays["이름 바꿀 대화"] = 400_000_000
        _ = await sendAndWait("이름 바꿀 대화", renamedLater)
        await settle { box.requests["이름 바꿀 대화"] != nil }
        if var current = model.allThreads().first(where: { $0.id == renamedLater.id }) {
            current.title = "내가 붙인 이름"
            await model.updateThread(current)
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        await t.equal("묻는 사이 사람이 바꾼 이름은 그대로", title(renamedLater.id), "내가 붙인 이름")

        // 3) 요약이 실패하면 첫 메시지 제목.
        box.answers["실패할 대화"] = .some(nil)
        _ = await sendAndWait("실패할 대화", failing)
        await settle { box.requests["실패할 대화"] != nil }
        try? await Task.sleep(nanoseconds: 200_000_000)
        await t.equal("요약이 실패하면 첫 메시지 제목", title(failing.id), "실패할 대화")

        // 4) 설정을 끄면 묻지 않는다.
        model.autoThreadTitles = false
        _ = await sendAndWait("끈 대화", switchedOff)
        try? await Task.sleep(nanoseconds: 200_000_000)
        await t.check("설정을 끄면 묻지 않는다", box.requests["끈 대화"] == nil && title(switchedOff.id) == "끈 대화")
        model.autoThreadTitles = true

        // 5) Codex 는 그 계정의 가장 작은 계열(luna)의 최신으로.
        box.answers["코덱스 대화"] = "코덱스 요약"
        _ = await sendAndWait("코덱스 대화", codex)
        await settle { title(codex.id) == "코덱스 요약" }
        await t.check("Codex 는 그 계정의 luna 최신으로 묻는다",
                      box.requests["코덱스 대화"]?.provider == .codex && box.requests["코덱스 대화"]?.codexModel == "gpt-6-luna"
                        && title(codex.id) == "코덱스 요약", "\(String(describing: box.requests["코덱스 대화"]))")

        // 6) 이름이 붙어 있던(이미 쓰던) 대화는 묻지 않는다.
        _ = await sendAndWait("오래된 대화에 보낸 글", old)
        try? await Task.sleep(nanoseconds: 200_000_000)
        await t.check("이미 이름이 있는 대화는 묻지 않는다",
                      box.requests["오래된 대화에 보낸 글"] == nil && title(old.id) == "이미 쓰던 대화")

        // 7) API 크레딧으로 실행하는 대화는 제목도 API 키 길로 묻는다 (구독 대화는 아니다).
        ClaudeAPIKey.storage = ClaudeAPIKeyMemoryStorage()
        defer { ClaudeAPIKey.storage = ClaudeAPIKeyMemoryStorage() }
        let apiThread = try await thread("새 대화")
        await model.reloadProjects()
        _ = model.saveClaudeAPIKey("sk-ant-api03-titl0000WXYZ")
        model.setClaudeAPI(true, threadID: apiThread.id)
        box.answers["API 대화의 첫 부탁"] = "API 요약"
        _ = await sendAndWait("API 대화의 첫 부탁", apiThread)
        await settle { title(apiThread.id) == "API 요약" }
        await t.check("API 크레딧 대화의 제목은 API 키 길로 묻는다",
                      box.requests["API 대화의 첫 부탁"]?.viaClaudeAPI == true && title(apiThread.id) == "API 요약",
                      "\(String(describing: box.requests["API 대화의 첫 부탁"]))")
        await t.check("구독 대화(Claude)의 제목은 구독 길 그대로",
                      box.requests["실패할 대화"]?.provider == .claude && box.requests["실패할 대화"]?.viaClaudeAPI == false)
    }
}
