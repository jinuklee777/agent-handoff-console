import Foundation

// MARK: - 한도 줄: 풀림의 근거 · Codex 오류 메시지 · 같은 한도는 한 줄

/// 사용자가 앱을 쓰다 찾은 결함(2026-10-09): Codex 가 아직 막혀 있는데 한도 줄에 "한도 풀림" 이 떴고(98% 에서도 한도 오류를 낸다 —
/// 다 찬 창이 안 보인다는 것만으로 풀림이라 했다), 오류 글에 params JSON 이 통째로 보였고, 같은 한도가 두 줄로 남았다.
@MainActor
enum LimitLineTests {
    static func run(_ t: TestKit) async {
        await release(t)
        await codexError(t)
        await oneLine(t)
    }

    private static func window(_ label: String, _ utilization: Double, resetsIn: TimeInterval?, span: Int?, now: Date) -> LimitWindow {
        LimitWindow(label: label, utilization: utilization, resetsAt: resetsIn.map { now.addingTimeInterval($0) }, spanMinutes: span)
    }

    private static func snapshot(_ windows: [LimitWindow], fetchedAt: Date) -> LimitSnapshot {
        var s = LimitSnapshot(provider: .codex, accountID: "a")
        s.status = .ok
        s.fetchedAt = fetchedAt
        s.windows = windows
        return s
    }

    /// 풀림은 근거가 있을 때만 — 창이 한도 시각 뒤에 다시 시작했고 다른 거의 찬 창이 없을 때, 또는 그 뒤 같은 계정의 실행이 성공했을 때.
    private static func release(_ t: TestKit) async {
        await t.group("한도 줄: 풀림은 근거가 있을 때만")
        let now = Date()
        let limitAt = now.addingTimeInterval(-600)   // 10분 전에 한도에 닿았다
        // 98% 에서 막혔다 — 5시간 창은 2시간 전에 시작해 3시간 뒤에 풀린다 (다시 시작하지 않았다).
        let stillBlocked = snapshot([window("5시간", 0.98, resetsIn: 3 * 3600, span: 300, now: now),
                                     window("7일", 0.40, resetsIn: 5 * 86400, span: 10080, now: now)], fetchedAt: now)
        await t.check("98% 인 창이 다시 시작하지 않았으면 풀림이 아니다 (다 찬 창이 안 보여도)",
                      !HandoffCardText.released(stillBlocked, since: limitAt))
        // 5시간 창이 2분 전에 새로 시작했다 (초기화 시각 = 지금 + 4시간 58분) — 주간 창은 40%.
        let restarted = snapshot([window("5시간", 0.02, resetsIn: 5 * 3600 - 120, span: 300, now: now),
                                  window("7일", 0.40, resetsIn: 5 * 86400, span: 10080, now: now)], fetchedAt: now)
        await t.check("한도 시각 뒤에 다시 시작한 창이 있고 다른 창은 여유 → 풀림",
                      HandoffCardText.released(restarted, since: limitAt))
        let weeklyFull = snapshot([window("5시간", 0.02, resetsIn: 5 * 3600 - 120, span: 300, now: now),
                                   window("7일", 0.97, resetsIn: 3 * 86400, span: 10080, now: now)], fetchedAt: now)
        await t.check("5시간 창이 새로 시작해도 주간 창이 거의 찼으면 풀림이 아니다",
                      !HandoffCardText.released(weeklyFull, since: limitAt))
        let noSpan = snapshot([LimitWindow(label: "5시간", utilization: 0.2)], fetchedAt: now)
        await t.check("창의 길이 · 초기화 시각을 모르면 근거가 없다 (예전에는 풀림이라 했다)",
                      !HandoffCardText.released(noSpan, since: limitAt))
        let passed = snapshot([window("5시간", 0.98, resetsIn: -60, span: nil, now: now)], fetchedAt: now)
        await t.check("적힌 초기화 시각이 한도 뒤에 이미 지났으면 풀림 (창 길이를 몰라도)", HandoffCardText.released(passed, since: limitAt))
        await t.check("한도 전에 지난 초기화 시각은 근거가 아니다",
                      !HandoffCardText.released(passed, since: now.addingTimeInterval(-30)))
        await t.check("한도 전에 읽은 스냅샷은 근거가 아니다", !HandoffCardText.released(restarted, since: now.addingTimeInterval(60)))
        await t.check("그 뒤 같은 계정의 실행이 성공했으면 풀림", HandoffCardText.released(stillBlocked, since: limitAt, laterSuccess: true))
        await t.equal("근거가 없으면 한도 줄은 예전 규칙 (초기화 시각 미확인 · 원문 참고)",
                      HandoffCardText.resetPhrase(HandoffCardText.resetPhrase(current: nil, fixed: nil, releasedSince: false),
                                                  rawText: "You've hit your usage limit. Try again at 3:05 PM."),
                      HandoffCardText.resetInSourceText)
    }

    /// Codex `error` 알림의 메시지는 `params.error.message` (`TurnError`), 분류는 `codexErrorInfo`. 다시 시도할 오류는 진단.
    private static func codexError(_ t: TestKit) async {
        await t.group("한도 줄: Codex error 알림의 메시지 · 분류")
        let message = "You've hit your usage limit. Upgrade to Pro or try again later."
        var tracker = CodexTurnTracker(waitForBackground: false)
        tracker.setMainThread("M")
        let actions = tracker.handle(method: "error", params: [
            "threadId": "M", "turnId": "t1", "willRetry": false,
            "error": ["message": message, "codexErrorInfo": "usageLimitExceeded", "additionalDetails": NSNull()]])
        var failure: AgentErrorInfo?
        for case .emit(.failure(let info)) in actions { failure = info }
        await t.equal("메시지는 params.error.message (params JSON 통째가 아니다)", failure?.message, message)
        await t.equal("codexErrorInfo usageLimitExceeded → 구독 한도", failure?.classification, .subscriptionCap)
        let retry = tracker.handle(method: "error", params: [
            "threadId": "M", "turnId": "t1", "willRetry": true, "error": ["message": "stream disconnected"]])
        await t.check("다시 시도할 오류는 실패가 아니라 진단", retry.count == 1 && {
            if case .emit(.diagnostic(let text)) = retry[0] { return text.contains("stream disconnected") }
            return false
        }())
        let old = tracker.handle(method: "error", params: ["threadId": "M", "message": "usage limit reached"])
        var oldFailure: AgentErrorInfo?
        for case .emit(.failure(let info)) in old { oldFailure = info }
        await t.equal("옛 꼴(params.message)도 읽는다", oldFailure?.message, "usage limit reached")
        await t.equal("codexErrorInfo 객체 꼴 → 네트워크", CodexAdapter.classification(codexErrorInfo: ["httpConnectionFailed": ["httpStatusCode": 502]]),
                      .networkError)
        let turn = CodexAdapter.interpretTurnCompleted(
            turn: ["status": "failed", "error": ["message": "limit", "codexErrorInfo": "usageLimitExceeded"]],
            usage: TurnUsage(), model: nil, threadID: "M", accumulatedText: "", userCancelled: false, sawAnyUsage: false,
            startedAt: Date())
        await t.check("실패한 turn/completed 도 codexErrorInfo 로 한도 (글에 'usage limit' 이 없어도)",
                      turn.state == .rateLimited && turn.limitStatus == .subscriptionCap)
    }

    /// 실행 중 `error` 알림(실패 이벤트)과 실행 끝의 실패가 같은 한도를 두 줄로 남기지 않는다.
    private static func oneLine(_ t: TestKit) async {
        await t.group("한도 줄: 같은 한도는 한 줄")
        let recorded: [(message: String, classification: LimitStatus)] = [("You've hit your usage limit.", .subscriptionCap)]
        await t.check("같은 글이면 이미 남겼다", RunSession.alreadyRecorded(message: " You've hit your usage limit. ", limitStatus: nil,
                                                                  recorded: recorded))
        await t.check("글이 달라도 둘 다 구독 한도면 이미 남겼다",
                      RunSession.alreadyRecorded(message: "limit", limitStatus: .subscriptionCap, recorded: recorded))
        await t.check("다른 실패는 남긴다", !RunSession.alreadyRecorded(message: "sandbox error", limitStatus: .unknownCause,
                                                                 recorded: recorded))

        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-limitline-\(UUID().uuidString).sqlite3")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + s) } }
        let store = Store(databaseURL: dbURL)
        do {
            try await store.bootstrap()
            let project = Project(name: "가짜", path: NSTemporaryDirectory())
            try await store.upsertProject(project)
            let thread = ConversationThread(projectID: project.id, title: "한도 한 줄")
            try await store.upsertThread(thread)
            let coordinator = RunCoordinator(store: store, environment: CLIEnvironment())
            let probe = CoordinatorProbe(coordinator: coordinator)
            coordinator.delegate = probe
            let message = "You've hit your usage limit."
            let fake = ScriptedAgentAdapter(provider: .codex, steps: [
                .emit(.sessionEstablished(sessionID: "s", model: "fake", cliVersion: nil)),
                .emit(.failure(AgentErrorInfo(message: message, classification: .subscriptionCap, raw: nil))),
                .finish(AgentTurnResult(state: .rateLimited, terminalReason: "failed", isError: true, errorMessage: message,
                                        sessionID: "s", limitStatus: .subscriptionCap)),
            ])
            coordinator.adapterFactory = { _ in fake }
            try await coordinator.send(prompt: "해 줘", thread: thread, project: project, provider: .codex)
            await t.check("끝까지 돈다", await probe.waitUntilIdle(timeout: 10))
            let errors = try await store.events(threadID: thread.id).filter { $0.kind == .error }
            await t.equal("한도 줄은 하나", errors.count, 1)
        } catch {
            await t.check("시나리오 실행 중 예외", false, "\(error)")
        }
    }
}
