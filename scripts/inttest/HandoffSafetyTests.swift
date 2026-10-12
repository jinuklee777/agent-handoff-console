import Foundation

// MARK: - 인계 전송의 안전장치 (B 설계 C0)

/// 같은 인계를 두 번 보내지 않는 마지막 문은 DB 의 원자 점유다 (화면이 들고 있던 사본의 상태가 아니라).
/// 초안 내용 쓰기는 전달 상태를 건드리지 않는다. 보내는 도중 죽은 인계는 다음 실행에서 "전달 여부 미확인" 으로.
/// 받는 Codex 계정의 모델은 그 계정의 목록으로 푼다. 칩에서 에이전트 · 계정을 함께 고르면 한 번에 쓴다.
@MainActor
enum HandoffSafetyTests {

    static func run(_ t: TestKit) async {
        await storeRules(t)
        await deliverOnce(t)
        await receiverScope(t)
        await chooseAgent(t)
    }

    private static func tempStore(_ name: String) async throws -> (Store, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-\(name)-\(UUID().uuidString).sqlite3")
        let store = Store(databaseURL: url)
        try await store.bootstrap()
        return (store, url)
    }

    private static func remove(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    static func storeRules(_ t: TestKit) async {
        await t.group("인계 안전장치: DB 점유 · 내용과 상태의 분리 · 고아 복구")
        do {
            let (store, url) = try await tempStore("handoff-claim")
            defer { remove(url) }
            let project = Project(name: "점유", path: NSTemporaryDirectory())
            try await store.upsertProject(project)
            let thread = ConversationThread(projectID: project.id, title: "점유")
            try await store.upsertThread(thread)
            var handoff = Handoff(threadID: thread.id, fromProvider: .claude, toProvider: .codex, baseSeq: 0,
                                  draftJSON: "{}", finalText: "첫 글")

            try await store.insertHandoffIfAbsent(handoff)
            try await store.insertHandoffIfAbsent(handoff)   // 두 번 넣어도 한 행
            await t.equal("넣기는 한 번만", try await store.handoffs(threadID: thread.id).count, 1)

            handoff.finalText = "고친 글"
            await t.check("초안 행에는 내용을 쓴다", try await store.updateHandoffDraftContent(handoff))
            var sending = handoff
            sending.finalText = "실제로 보낸 글"
            sending.note = "사람 검토함"
            await t.check("점유: 초안 → 전송 중", try await store.claimHandoffForSending(sending, sentAt: Date()))
            let claimed = try await store.handoffs(threadID: thread.id).first
            await t.check("점유는 보낼 내용도 같은 쓰기에 적는다", claimed?.finalText == "실제로 보낸 글" && claimed?.note == "사람 검토함",
                          claimed?.finalText ?? "")
            await t.check("점유는 한 번만 (두 번째는 거절)", !(try await store.claimHandoffForSending(handoff, sentAt: Date())))

            // 화면이 들고 있던 초안 사본으로 쓰기 — 전송 중인 행을 되돌리지 않는다.
            var stale = handoff
            stale.finalText = "늦게 고친 글"
            stale.deliveryState = .draft
            await t.check("보내는 중인 행에는 내용을 쓰지 않는다", !(try await store.updateHandoffDraftContent(stale)))
            try await store.insertHandoffIfAbsent(stale)
            let row = try await store.handoffs(threadID: thread.id).first
            await t.check("사본을 다시 넣어도 상태 · 글은 그대로", row?.deliveryState == .sending && row?.finalText == "실제로 보낸 글",
                          "\(String(describing: row?.deliveryState)) \(row?.finalText ?? "")")

            // 실패한 인계는 다시 점유할 수 있다.
            var failed = Handoff(threadID: thread.id, fromProvider: .claude, toProvider: .codex, baseSeq: 0,
                                 draftJSON: "{}", finalText: "실패")
            failed.deliveryState = .failed
            try await store.insertHandoff(failed)
            await t.check("실패 행은 다시 점유된다", try await store.claimHandoffForSending(failed, sentAt: Date()))

            // 앱을 켤 때: 살아 있는 실행 없이 '전송 중' 인 행 → 미확인 (메모를 잇는다).
            let changed = try await store.markOrphanedHandoffsUnknown(note: "앱이 보내는 도중 종료")
            let rows = try await store.handoffs(threadID: thread.id)
            await t.check("고아 '전송 중' 은 미확인으로", changed == 2 && rows.allSatisfy { $0.deliveryState == .unknown },
                          "\(changed) \(rows.map(\.deliveryState))")
            await t.check("미확인 이유를 남긴다", rows.allSatisfy { $0.note?.contains("앱이 보내는 도중 종료") == true })
        } catch {
            await t.check("인계 점유 시험 준비", false, "\(error)")
        }
    }

    static func deliverOnce(_ t: TestKit) async {
        await t.group("인계 안전장치: 같은 사본으로 두 번 넘겨도 한 번만 간다")
        do {
            let (store, url) = try await tempStore("handoff-once")
            defer { remove(url) }
            let project = Project(name: "한 번", path: NSTemporaryDirectory())
            try await store.upsertProject(project)
            var thread = ConversationThread(projectID: project.id, title: "한 번")
            thread.claudeSelection = ModelSelection(model: "sonnet", effort: "high")
            try await store.upsertThread(thread)
            let coordinator = RunCoordinator(store: store, environment: CLIEnvironment())
            let probe = CoordinatorProbe(coordinator: coordinator)
            coordinator.delegate = probe
            let fake = ScriptedAgentAdapter.replying("받았습니다")
            coordinator.adapterFactory = { _ in fake }

            // 초안 행을 미리 넣지 않는다 — 넘길 때 넣는다.
            let handoff = Handoff(threadID: thread.id, fromProvider: .codex, toProvider: .claude, baseSeq: 0,
                                  draftJSON: "{}", finalText: "인계 문서")
            _ = try await coordinator.deliver(handoff: handoff, thread: thread, project: project)
            _ = await probe.waitUntilIdle(timeout: 10)
            var second = false
            do {
                _ = try await coordinator.deliver(handoff: handoff, thread: thread, project: project)   // 같은 초안 사본
                second = true
            } catch {}
            _ = await probe.waitUntilIdle(timeout: 10)
            await t.check("둘째 넘기기는 DB 점유에서 거절", !second)
            let events = try await store.events(threadID: thread.id)
            await t.equal("인계 전송 기록은 하나", events.filter { $0.kind == .handoffSent }.count, 1)
            await t.equal("받는 쪽 실행은 하나", fake.requests.count, 1)
            let row = try await store.handoffs(threadID: thread.id).first
            await t.equal("전달 확인", row?.deliveryState, .delivered)
        } catch {
            await t.check("한 번만 넘기기 시험 준비", false, "\(error)")
        }
    }

    static func receiverScope(_ t: TestKit) async {
        await t.group("인계 안전장치: 받는 Codex 계정의 모델은 그 계정의 목록으로")
        do {
            let (store, url) = try await tempStore("handoff-scope")
            defer { remove(url) }
            let project = Project(name: "계정", path: NSTemporaryDirectory())
            try await store.upsertProject(project)
            var thread = ConversationThread(projectID: project.id, title: "계정 A 대화")
            thread.codexAccountID = "acct-a"
            thread.codexSelection = ModelSelection(model: "gpt-*-sol", effort: "high")
            try await store.upsertThread(thread)
            func efforts(_ values: [String]) -> [[String: Any]] { values.map { ["reasoningEffort": $0] } }
            try await store.replaceModelOptions(ModelCatalog.parseCodexModels([
                ["id": "gpt-6-sol", "supportedReasoningEfforts": efforts(["low", "high"])]]), scope: .codex("acct-a"))
            try await store.replaceModelOptions(ModelCatalog.parseCodexModels([
                ["id": "gpt-5.6-sol", "supportedReasoningEfforts": efforts(["low", "high"])]]), scope: .codex("acct-b"))

            let coordinator = RunCoordinator(store: store, environment: CLIEnvironment())
            let probe = CoordinatorProbe(coordinator: coordinator)
            coordinator.delegate = probe
            let fake = ScriptedAgentAdapter.replying("받았습니다", provider: .codex)
            coordinator.adapterFactory = { _ in fake }
            let handoff = Handoff(threadID: thread.id, fromProvider: .claude, toProvider: .codex,
                                  toAccountID: "acct-b", baseSeq: 0, draftJSON: "{}", finalText: "인계 문서")
            _ = try await coordinator.deliver(handoff: handoff, thread: thread, project: project,
                                              toAccount: CodexAccountRef(id: "acct-b", label: "B", homePath: NSTemporaryDirectory()))
            _ = await probe.waitUntilIdle(timeout: 10)
            await t.equal("계정 B 의 목록에서 푼다 (대화에 적힌 계정 A 가 아니라)", fake.requests.first?.model, "gpt-5.6-sol")

            // 받는 계정의 목록이 비어 계열을 풀 수 없으면: 점유 · "인계 전송" 기록 전에 멈춘다 (보낸 것처럼 남지 않게).
            var other = ConversationThread(projectID: project.id, title: "목록 없는 계정으로")
            other.codexAccountID = "acct-a"
            other.codexSelection = ModelSelection(model: "gpt-*-sol", effort: "high")
            try await store.upsertThread(other)
            let unresolved = Handoff(threadID: other.id, fromProvider: .claude, toProvider: .codex,
                                     toAccountID: "acct-c", baseSeq: 0, draftJSON: "{}", finalText: "인계 문서")
            var refused = false
            do {
                _ = try await coordinator.deliver(handoff: unresolved, thread: other, project: project,
                                                  toAccount: CodexAccountRef(id: "acct-c", label: "C", homePath: NSTemporaryDirectory()))
            } catch RunCoordinator.StartError.modelUnresolved {
                refused = true
            } catch {}
            let otherEvents = try await store.events(threadID: other.id)
            let otherRows = try await store.handoffs(threadID: other.id)
            await t.check("목록이 빈 받는 계정: 기록 없이 거절 (인계 전송 줄도 행도 없음)",
                          refused && !otherEvents.contains { $0.kind == .handoffSent } && otherRows.isEmpty,
                          "\(refused) \(otherEvents.map(\.kind)) \(otherRows.map(\.deliveryState))")
        } catch {
            await t.check("받는 계정 목록 시험 준비", false, "\(error)")
        }
    }

    static func chooseAgent(_ t: TestKit) async {
        await t.group("입력창 칩: 에이전트와 계정을 함께 고르면 한 번에 쓴다")
        do {
            let (store, url) = try await tempStore("choose-agent")
            defer { remove(url) }
            let project = Project(name: "칩", path: NSTemporaryDirectory())
            try await store.upsertProject(project)
            let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-choose-home-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            // 계정을 바꾸면 그 계정의 모델 목록 · 한도를 읽는다 — 오프라인 하네스는 실제 codex 를 찾지 않는다(CLIEnvironment.harnessFallback).
            try await store.upsertCodexAccount(CodexAccount(id: "acct-b", label: "둘째", homePath: home.path, sortOrder: 1))
            var thread = ConversationThread(projectID: project.id, title: "칩")
            thread.preferredProvider = .claude
            try await store.upsertThread(thread)
            let model = AppModel(store: store)
            await model.accounts.load()
            await model.reloadProjects()

            await model.chooseAgent(.codex, accountID: "acct-b", threadID: thread.id)
            let memory = model.allThreads().first { $0.id == thread.id }
            let stored = try await store.thread(id: thread.id)
            await t.check("메모리: 제공자 · 계정이 함께 바뀐다", memory?.preferredProvider == .codex && memory?.codexAccountID == "acct-b",
                          "\(String(describing: memory?.preferredProvider)) \(memory?.codexAccountID ?? "")")
            await t.check("저장: 제공자가 계정 쓰기에 되돌려지지 않는다", stored?.preferredProvider == .codex && stored?.codexAccountID == "acct-b",
                          "\(String(describing: stored?.preferredProvider)) \(stored?.codexAccountID ?? "")")
        } catch {
            await t.check("칩 고르기 시험 준비", false, "\(error)")
        }
    }
}
