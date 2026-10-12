import Foundation

// 대화 제목 자동 요약 — 판정 · 글 · CLI 호출은 `Assist/ThreadTitle.swift`, 여기는 언제 묻고 어디에 넣는지.
extension AppModel {
    /// 첫 턴이 끝난 대화의 제목을 짧게 요약해 바꾼다. 묻는 때는 그 대화의 **첫 정상 완료 실행**이 끝났을 때 한 번 —
    /// 가져온 대화 · 이미 쓰던 대화(완료 실행이 앞에 있다)는 건드리지 않는다. 제목이 아직 앱이 첫 메시지로 붙인 그대로일 때만
    /// (사람이 바꾼 이름은 그대로), 설정(`autoThreadTitles`)이 켜져 있을 때만, Claude · Codex 만. 묻는 곳은 그 실행의 제공자 ·
    /// 계정 — 대화가 이미 간 곳이다. 실패 · 시간 초과면 첫 메시지 제목을 그대로 둔다.
    /// 화면 확인용 실행 · 가짜 어댑터로 도는 실행은 `threadTitleSummarizerOverride` 가 없으면 CLI 를 부르지 않는다.
    func summarizeTitleIfNeeded(after run: Run) async {
        guard autoThreadTitles, run.provider != .gemini, !run.isHandoffDelivery,
              !titleSummaryThreadIDs.contains(run.threadID),
              let summarizer = titleSummarizer(for: run),
              let thread = paneThread(run.threadID), !thread.isInternal else { return }
        // 이 대화의 첫 정상 완료 실행인가 (인계 전달 실행은 세지 않는다).
        guard let runs = try? await store.runs(threadID: run.threadID),
              runs.filter({ $0.state == .completed && !$0.isHandoffDelivery }).map(\.id) == [run.id],
              let events = try? await store.events(threadID: run.threadID, limit: 400),
              let first = events.first(where: { $0.kind == .userMessage && $0.isMainStream }),
              ThreadTitle.isAutomatic(thread.title, firstMessage: first.text) else { return }
        titleSummaryThreadIDs.insert(run.threadID)
        let answer = events.first { $0.kind == .agentMessage && $0.isMainStream && $0.runID == run.id }?.text
        let codexModel: String? = run.provider == .codex
            ? ThreadTitle.codexModel(from: options(for: AgentScope(provider: .codex, accountID: run.codexAccountID ?? ""))
                .map(\.identifier))
            : nil
        let request = ThreadTitle.Request(provider: run.provider,
                                          input: ThreadTitle.input(firstMessage: first.text, firstAnswer: answer),
                                          codexModel: codexModel,
                                          viaClaudeAPI: run.provider == .claude && usesClaudeAPI(threadID: run.threadID))
        guard let title = await summarizer(request) else { return }
        // 묻는 사이 사람이 이름을 바꿨거나 대화가 지워졌으면 그대로 둔다.
        guard var current = paneThread(run.threadID), ThreadTitle.isAutomatic(current.title, firstMessage: first.text),
              current.title != title else { return }
        current.title = title
        await updateThread(current)
    }

    /// 제목을 물을 함수 — 바꿔 끼운 것이 있으면 그것, 아니면 그 실행의 CLI (화면 확인용 실행 · 가짜 어댑터면 nil).
    private func titleSummarizer(for run: Run) -> (@Sendable (ThreadTitle.Request) async -> String?)? {
        if let threadTitleSummarizerOverride { return threadTitleSummarizerOverride }
        guard !Self.offlinePreview, runner.adapterFactory == nil else { return nil }
        let environment = self.environment
        let codexHome: String? = run.provider == .codex ? accounts.accountOrDefault(run.codexAccountID ?? "").homePath : nil
        return { request in
            guard let path = await environment.resolveExecutable(request.provider) else { return nil }
            let base = await environment.childEnvironment(codexHome: codexHome)
            // API 키로 실행하는 대화는 제목도 그 키로 (대화 실행과 같은 길 — `RunSession.makeAdapter`).
            guard let env = ThreadTitle.environment(base, for: request,
                                                    apiKey: request.viaClaudeAPI ? ClaudeAPIKey.load() : nil) else { return nil }
            return await ThreadTitle.summarize(request, executable: path, environment: env)
        }
    }
}
