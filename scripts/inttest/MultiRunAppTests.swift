import Foundation

// MARK: - 앱: 여러 대화의 동시 실행

/// `AppModel` 이 여러 실행을 함께 다루는지: 대화별 화면 상태, 같은 폴더의 겹침 표시, 폴더 · 대화 단위의 잠금.
/// 실제 `RunCoordinator` · SQLite 를 거치고 CLI 만 가짜(`ScriptedAgentAdapter`)다.
@MainActor
enum MultiRunAppTests {

    /// 칸 배치 규칙 (순수) — `PaneArrangement`.
    static func paneRules(_ t: TestKit) async {
        await t.group("분할 화면: 칸 배치 규칙")
        var panes = PaneArrangement()
        await t.check("처음은 한 칸 · 빈 칸", panes.layout == .single && panes.threadIDs == [nil] && panes.focused == 0)
        panes = panes.opening("a")
        await t.equal("사이드바에서 누르면 포커스 칸에 열린다", panes.threadIDs, ["a"])
        panes = panes.opening("b")
        await t.equal("한 칸이면 대화가 바뀐다", panes.threadIDs, ["b"])
        panes = panes.openingInNewPane("c")
        await t.check("새 칸에서 열기: 빈 칸이 없으면 분할을 키워 새 칸에 · 포커스도 그 칸",
                      panes.layout == .twoColumns && panes.threadIDs == ["b", "c"] && panes.focused == 1)
        panes = panes.opening("b")
        await t.check("이미 열린 대화를 누르면 그 칸으로 포커스만", panes.threadIDs == ["b", "c"] && panes.focused == 0)
        panes = panes.openingInNewPane("d")
        await t.check("두 칸이 차 있으면 네 칸으로", panes.layout == .fourGrid && panes.threadIDs == ["b", "c", "d", nil] && panes.focused == 2)
        panes = panes.openingInNewPane("e")
        await t.check("빈 칸이 있으면 거기에", panes.threadIDs == ["b", "c", "d", "e"] && panes.focused == 3)
        let full = panes.openingInNewPane("f")
        await t.check("네 칸이 다 찼으면 새 칸에서 열기는 아무것도 바꾸지 않는다 (보던 칸을 말없이 바꾸지 않음)", full == panes)
        await t.check("새 칸에서 열기를 끄는 까닭: 다 참 · 이미 열림 · 할 수 있음",
                      panes.newPaneBlock(for: "f") == .full && panes.newPaneBlock(for: "c") == .alreadyOpen
                        && PaneArrangement().opening("a").newPaneBlock(for: "b") == nil)
        await t.equal("메뉴 글에 끈 까닭",
                      [panes.newPaneMenuTitle(for: "f"), panes.newPaneMenuTitle(for: "c"),
                       PaneArrangement().opening("a").newPaneMenuTitle(for: "b")],
                      ["새 칸에서 열기 (빈 칸 없음 — 칸의 × 로 비우세요)", "새 칸에서 열기 (이미 칸에 열려 있음)", "새 칸에서 열기"])
        await t.check("같은 대화를 또 새 칸에 열지 않는다", panes.openingInNewPane("c").threadIDs == panes.threadIDs
                        && panes.openingInNewPane("c").focused == 1)
        let shrunk = panes.resized(to: .twoColumns)
        await t.check("줄이면 앞에서부터 남기되 포커스 대화는 남긴다", shrunk.threadIDs == ["b", "e"] && shrunk.focused == 1
                        && shrunk.focusedThreadID == "e", "\(shrunk.threadIDs) \(shrunk.focused)")
        await t.check("한 칸으로 줄이면 포커스 대화만", panes.resized(to: .single).threadIDs == ["e"])
        let sparse = PaneArrangement(layout: .fourGrid, threadIDs: [nil, "x", nil, "y"], focused: 3, existing: ["x", "y"])
        await t.check("줄일 때 빈 칸은 버린다", sparse.resized(to: .twoColumns).threadIDs == ["x", "y"] && sparse.resized(to: .twoColumns).focused == 1)
        let grown = PaneArrangement().opening("a").resized(to: .fourGrid)
        await t.check("키우면 뒤에 빈 칸이 붙고 포커스는 첫 빈 칸으로 (사이드바에서 고른 대화가 보던 칸을 바꾸지 않게)",
                      grown.threadIDs == ["a", nil, nil, nil] && grown.focused == 1, "\(grown.threadIDs) \(grown.focused)")
        await t.equal("분할 직후 고른 대화는 빈 칸에", grown.opening("z").threadIDs, ["a", "z", nil, nil])
        let closed = panes.closing(pane: 1)
        await t.check("칸 비우기: 그 칸만 빈다 · 다른 칸을 비우면 포커스는 그대로", closed.threadIDs == ["b", nil, "d", "e"] && closed.focused == 3)
        let closedFocused = panes.closing(pane: 3)
        await t.check("포커스 칸을 비우면 대화가 열린 가까운 앞 칸이 포커스", closedFocused.threadIDs == ["b", "c", "d", nil]
                        && closedFocused.focused == 2 && closedFocused.focusedThreadID == "d")
        let closedFirst = panes.focusing(0).closing(pane: 0)
        await t.check("앞 칸이 없으면 뒤 칸으로", closedFirst.focused == 1 && closedFirst.focusedThreadID == "c")
        let lonely = PaneArrangement().opening("a").resized(to: .twoColumns).focusing(0).closing(pane: 0)
        await t.check("다른 칸이 모두 비었으면 그 자리에", lonely.threadIDs == [nil, nil] && lonely.focused == 0)
        await t.check("지워진 대화는 칸에서 빠진다", panes.removing("d").threadIDs == ["b", "c", nil, "e"])

        // 줄였다 늘리면 앞의 배치가 돌아온다 (⌃⌘1 → ⌃⌘4).
        let single = panes.resized(to: .single)
        await t.check("한 칸으로 줄이면 네 칸 배치를 기억한다", single.threadIDs == ["e"] && single.remembered == ["b", "c", "d", "e"]
                        && single.rememberedFocus == 3)
        let back = single.resized(to: .fourGrid)
        await t.check("다시 늘리면 그 배치 · 포커스 대화의 칸", back.threadIDs == ["b", "c", "d", "e"] && back.focused == 3
                        && back.remembered.isEmpty, "\(back.threadIDs) \(back.focused)")
        let swapped = panes.focusing(1).resized(to: .single).opening("x").resized(to: .fourGrid)
        await t.check("줄인 칸에서 바꿔 연 대화는 원래 포커스 자리로", swapped.threadIDs == ["b", "x", "d", "e"] && swapped.focused == 1,
                      "\(swapped.threadIDs) \(swapped.focused)")
        let twoStep = panes.focusing(0).resized(to: .twoColumns).resized(to: .single)
        await t.check("두 번 줄여도 가장 큰 배치를 기억한다", twoStep.remembered == ["b", "c", "d", "e"]
                        && twoStep.resized(to: .fourGrid).threadIDs == ["b", "c", "d", "e"])
        let middle = single.resized(to: .twoColumns)
        await t.check("중간 크기로 늘리면 앞 칸들 + 보던 대화 · 더 큰 배치는 계속 기억", middle.threadIDs == ["b", "e"]
                        && middle.remembered == ["b", "c", "d", "e"], "\(middle.threadIDs) \(middle.remembered)")
        await t.check("지운 대화는 기억에서도 빠진다", single.removing("c").remembered == ["b", nil, "d", "e"])
        let restoredMemory = PaneArrangement(layout: .single, threadIDs: ["e"], focused: 0, existing: ["b", "d", "e"],
                                             remembered: ["b", "gone", "d", "e"], rememberedFocus: 3)
        await t.check("되살릴 때 기억도 거른다 (없어진 대화는 빈 칸)", restoredMemory.remembered == ["b", nil, "d", "e"]
                        && restoredMemory.rememberedFocus == 3)
        // 오래된 기억 · 사람이 × 로 비운 대화는 되살리지 않는다 (chr-3).
        let later = Date().addingTimeInterval(PaneArrangement.rememberLifetime + 60)
        let stale = single.resized(to: .twoColumns, now: later)
        await t.check("기억한 지 오래되면 늘려도 빈 칸 · 포커스는 빈 칸", stale.threadIDs == ["e", nil] && stale.focused == 1
                        && stale.remembered.isEmpty, "\(stale.threadIDs) \(stale.remembered)")
        await t.check("시각이 없는 옛 기억은 되살리지 않는다",
                      restoredMemoryForGrow().resized(to: .fourGrid).threadIDs == ["e", nil, nil, nil])
        let closedThenShrunk = panes.closing(pane: 1).resized(to: .single)
        await t.check("× 로 비운 대화는 기억에 남지 않는다", !closedThenShrunk.remembered.contains("c"), "\(closedThenShrunk.remembered)")
        let closedAfterShrink = single.resized(to: .twoColumns).closing(pane: 0)
        await t.check("줄인 뒤 × 로 비운 대화도 기억에서 빠진다", !closedAfterShrink.remembered.contains("b"),
                      "\(closedAfterShrink.remembered)")
        let newPaneFromSingle = single.openingInNewPane("y")
        await t.check("새 칸에서 열기는 기억을 되살리지 않고 한 칸만 늘린다", newPaneFromSingle.threadIDs == ["e", "y"]
                        && newPaneFromSingle.focused == 1, "\(newPaneFromSingle.threadIDs)")
        let restored = PaneArrangement(layout: .twoColumns, threadIDs: ["gone", "b", "b", "z"], focused: 9, existing: ["b", "z"])
        await t.check("되살릴 때: 없어진 대화는 빈 칸 · 칸 수는 분할에 맞춤 · 포커스는 칸 수 안으로",
                      restored.threadIDs == [nil, "b"] && restored.focused == 1, "\(restored.threadIDs) \(restored.focused)")
        let duplicated = PaneArrangement(layout: .fourGrid, threadIDs: ["b", "b"], focused: 0, existing: ["b"])
        await t.check("같은 대화가 두 칸에 있으면 앞의 것만 (입력창 · 실행은 대화에 하나)", duplicated.threadIDs == ["b", nil, nil, nil])
        await t.equal("칸 수", PaneLayout.allCases.map(\.paneCount), [1, 2, 4])
    }

    /// 시각 없이 저장된 옛 기억 (`pane_memory` 에 `at` 이 없던 때).
    private static func restoredMemoryForGrow() -> PaneArrangement {
        PaneArrangement(layout: .single, threadIDs: ["e"], focused: 0, existing: ["b", "c", "d", "e"],
                        remembered: ["b", "c", "d", "e"], rememberedFocus: 3)
    }

    static func run(_ t: TestKit) async {
        await paneRules(t)
        await t.group("앱: 여러 대화의 동시 실행")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-multirun-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let fm = FileManager.default
            let folderA = root.appendingPathComponent("a"), folderB = root.appendingPathComponent("b")
            for folder in [folderA, folderB] {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.invalid"], ["config", "user.name", "t"],
                                  ["commit", "-q", "--allow-empty", "-m", "base"]] {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                    process.arguments = arguments
                    process.currentDirectoryURL = folder
                    try process.run()
                    process.waitUntilExit()
                }
            }
            let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
            try await store.bootstrap()
            let projectA = Project(name: "a", path: folderA.path), projectB = Project(name: "b", path: folderB.path, sortOrder: 1)
            try await store.upsertProject(projectA)
            try await store.upsertProject(projectB)
            func thread(_ title: String, _ project: Project) async throws -> ConversationThread {
                var thread = ConversationThread(projectID: project.id, title: title)
                thread.claudeSelection = ModelSelection(model: "sonnet", effort: "high")   // 모델 목록 조회(CLI)를 타지 않게
                try await store.upsertThread(thread)
                return thread
            }
            let first = try await thread("첫째", projectA), second = try await thread("둘째", projectA)
            let elsewhere = try await thread("다른 폴더", projectB)

            let model = AppModel(store: store)
            model.runner.adapterFactory = { provider in
                ScriptedAgentAdapter(provider: provider) { request in
                    [.emit(.sessionEstablished(sessionID: "s-" + request.prompt, model: "fake-model", cliVersion: nil)),
                     .emit(.assistantDelta(request.prompt + " 에 답하는 중")), .waitInterrupt]
                }
            }
            await model.reloadProjects()
            func settle(_ condition: @MainActor () -> Bool) async {
                for _ in 0..<400 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
            }

            await model.selectThread(first.id)
            let sentFirst = await model.send("첫 요청", provider: .claude)
            await settle { model.runner.isBusy(threadID: first.id) }
            await model.selectThread(second.id)
            let sentSecond = await model.send("둘째 요청", provider: .claude)
            await settle { model.runner.isBusy(threadID: second.id) }
            await t.check("다른 대화로 옮겨 또 보내면 둘 다 돈다", sentFirst && sentSecond && model.runner.activeSessions.count == 2,
                          model.banner?.text ?? "")
            let again = await model.send("끼어들기", provider: .claude)
            await t.check("같은 대화에 또 보내면 받지 않는다", !again && model.banner?.text.contains("이 대화에서 에이전트가 실행 중") == true)
            await t.check("보내기 잠금은 자기 대화만 본다", !model.isStartingRun(threadID: first.id) && !model.isStartingRun(threadID: second.id))

            // 대화별 화면 상태.
            await settle { model.events.contains { $0.text.contains("둘째 요청 에 답하는 중") } }
            await t.check("보고 있는 대화의 출력", model.events.contains { $0.text.contains("둘째 요청 에 답하는 중") }
                            && !model.events.contains { $0.text.contains("첫 요청") })
            await t.check("닫힌 대화의 상자는 들고 있지 않다", model.threadStates[first.id] == nil && model.threadStates[second.id] != nil)
            await model.selectThread(first.id)
            await t.check("돌아오면 그 대화의 출력이 이어져 있다", model.events.contains { $0.text.contains("첫 요청 에 답하는 중") }
                            && model.events.allSatisfy { $0.threadID == first.id })
            await t.check("실행 기록도 그 대화의 것", model.runsByID.values.allSatisfy { $0.threadID == first.id } && model.runsByID.count == 1)

            // 폴더 단위 잠금.
            await t.check("실행 중인 폴더는 git 쓰기를 막는다", { if case .agentRunning = model.gitWriteLock { return true } else { return false } }())
            await t.check("자동 작업의 쓰기 슬롯: 그 폴더는 참 · 다른 폴더는 거짓",
                          model.isRunSlotBusy(project: projectA) && !model.isRunSlotBusy(project: projectB))
            await model.selectThread(elsewhere.id)
            await t.check("다른 폴더는 git 쓰기를 막지 않는다", model.gitWriteLock == nil, String(describing: model.gitWriteLock))
            await t.check("작업 폴더의 상태는 폴더마다 따로", model.workspace.projectPath == nil || model.workspace.projectPath == folderB.path)
            let sentElsewhere = await model.send("다른 폴더 요청", provider: .claude)
            await settle { model.runner.isBusy(threadID: elsewhere.id) }
            await t.check("다른 폴더의 대화도 함께 돈다", sentElsewhere && model.runner.activeSessions.count == 3)

            // 끝내기: 대화별로 멈춘다. 같은 폴더에서 겹친 둘은 비교하지 않는다고 적고, 혼자 돈 실행은 비교한다.
            await model.runner.interrupt(threadID: first.id)
            await settle { !model.runner.isBusy(threadID: first.id) }
            await t.check("그 대화의 실행만 멈춘다", model.runner.isBusy(threadID: second.id) && model.runner.isBusy(threadID: elsewhere.id))
            await model.runner.interruptAll()
            await settle { !model.runner.isBusy && !model.isFinishingRunChanges }
            func changes(_ thread: ConversationThread) async -> RunFileChanges? {
                for _ in 0..<200 {
                    let events = (try? await store.events(threadID: thread.id)) ?? []
                    if let found = events.compactMap({ RunFileChanges.decode($0) }).first { return found }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                return nil
            }
            let a = await changes(first), b = await changes(second), c = await changes(elsewhere)
            await t.check("같은 폴더에서 겹친 두 실행은 양쪽 다 '겹침' 으로 비교하지 않는다",
                          a?.compared == false && a?.unavailable == .overlapped && b?.compared == false && b?.unavailable == .overlapped,
                          "\(String(describing: a?.unavailable)) \(String(describing: b?.unavailable))")
            await t.check("다른 폴더에서 혼자 돈 실행은 비교한다", c?.compared == true, String(describing: c?.unavailable))
            await t.equal("겹침의 이유 문구", RunFileChanges.Unavailable.overlapped.koreanName, "같은 폴더에서 다른 실행과 겹침")
            await settle { model.gitWriteLock == nil }
            await t.check("모두 끝나면 잠금이 풀린다", model.gitWriteLock == nil && !model.isRunSlotBusy(project: projectA))

            // 분할 화면: 칸마다 대화 · 포커스 칸이 선택된 대화 · 칸마다의 상태 상자.
            await t.group("분할 화면: 앱 모델")
            await model.selectThread(first.id)
            await model.openInNewPane(second.id)
            await t.check("새 칸에서 열면 두 칸 · 포커스가 그 칸으로", model.panes.layout == .twoColumns
                            && model.paneThreadIDs == [first.id, second.id] && model.selectedThreadID == second.id)
            await t.check("칸마다 상태 상자를 들고 있다", model.threadStates[first.id]?.loaded == true && model.threadStates[second.id]?.loaded == true)
            await model.focusPane(0)
            await t.check("칸을 누르면 그 칸의 대화가 포커스 (인스펙터 · 메뉴가 따라간다)", model.selectedThreadID == first.id
                            && model.events.allSatisfy { $0.threadID == first.id } && !model.events.isEmpty)
            await model.selectThread(second.id)
            await t.check("이미 열린 대화를 고르면 칸을 바꾸지 않고 포커스만", model.paneThreadIDs == [first.id, second.id] && model.panes.focused == 1)
            await model.openInNewPane(elsewhere.id)
            await t.check("다른 폴더의 대화도 칸에: 폴더마다 작업 폴더 상태", model.panes.layout == .fourGrid
                            && model.workspace(forPath: folderA.path) != nil && model.workspace(forPath: folderB.path) != nil
                            && model.workspace.projectPath.map { $0 == folderB.path } != false)
            _ = await model.send("포커스가 아닌 칸에서 보내기", provider: .claude, threadID: first.id)
            await settle { model.runner.isBusy(threadID: first.id) }
            await settle { model.threadStates[first.id]?.events.contains { $0.text.contains("포커스가 아닌 칸에서 보내기 에 답하는 중") } == true }
            await t.check("포커스가 아닌 칸의 출력도 그 칸의 상자로 온다",
                          model.threadStates[first.id]?.events.contains { $0.text.contains("포커스가 아닌 칸에서 보내기 에 답하는 중") } == true
                            && !model.events.contains { $0.threadID == first.id })
            await t.check("실행 상태는 칸마다: 그 대화만 실행 중", model.runner.isBusy(threadID: first.id) && !model.isSelectedThreadBusy)
            await model.runner.interruptAll()
            await settle { !model.runner.isBusy && !model.isFinishingRunChanges }
            await model.closePane(0)
            await t.check("칸을 비우면 그 대화의 상자를 버린다 (대화는 남는다)", model.paneThreadIDs[0] == nil && model.threadStates[first.id] == nil
                            && model.allThreads().contains { $0.id == first.id })
            await model.setPaneLayout(.single)
            await t.check("한 칸으로 줄이면 포커스 대화만 남는다", model.paneThreadIDs == [elsewhere.id] && model.selectedThreadID == elsewhere.id
                            && model.threadStates.count == 1 && model.workspaces.count == 1)
            let reopened = AppModel(store: store)
            await model.setPaneLayout(.twoColumns)
            await model.openInNewPane(second.id)
            for _ in 0..<50 { try? await Task.sleep(nanoseconds: 10_000_000) }   // 설정 저장은 뒤에서 돈다
            await reopened.bootstrap()
            await t.check("앱을 다시 열면 칸 배치가 돌아온다", reopened.panes.layout == .twoColumns
                            && reopened.paneThreadIDs == [elsewhere.id, second.id] && reopened.selectedThreadID == second.id,
                          "\(reopened.panes)")
            await model.deleteThread(second)
            await t.check("지운 대화는 칸에서 빠지고, 포커스는 대화가 열린 칸으로 간다",
                          model.paneThreadIDs == [elsewhere.id, nil] && model.selectedThreadID == elsewhere.id, "\(model.panes)")
        } catch {
            await t.check("여러 대화의 동시 실행 검증 중 예외", false, "\(error)")
        }
    }
}
