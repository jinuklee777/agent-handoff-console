import Foundation

// MARK: - 분할 화면의 칸 머리 · 툴바 "응답 필요"

@MainActor
enum PaneStatusTests {

    static func run(_ t: TestKit) async {
        await rules(t)
        await badgeRows(t)
        await sidebarRules(t)
        await menuBarAndQuit(t)
        await app(t)
        await paneApp(t)
    }

    // MARK: 사이드바 · 빈 칸 (순수)

    /// `SidebarRules` · `EmptyPaneText` — 접기 · 더보기가 숨기지 않는 대화, 검색, 같은 이름의 프로젝트, 빈 대화 다시 쓰기, 빈 칸의 말.
    static func sidebarRules(_ t: TestKit) async {
        await t.group("사이드바: 접기 · 더보기 · 검색 · 프로젝트 이름")
        let ids = ["a", "b", "c", "d", "e"]
        func visible(searching: Bool = false, collapsed: Bool = false, expanded: Bool = false, pinned: Set<String> = []) -> [String] {
            SidebarRules.visible(ids, searching: searching, collapsed: collapsed, expanded: expanded, pinned: { pinned.contains($0) })
        }
        await t.equal("처음엔 3개 + 그 뒤의 꼭 보일 대화(선택 · 실행 중 · 답을 기다림 · 칸에 열림)", visible(pinned: ["e"]), ["a", "b", "c", "e"])
        await t.equal("접으면 모두 숨는다 — 선택 · 실행 중 · 답을 기다리는 대화도 (사용자 결정)", visible(collapsed: true, pinned: ["b", "e"]), [])
        await t.equal("접고 꼭 보일 대화가 없어도 비운다", visible(collapsed: true), [])
        await t.equal("더보기로 폈으면 전부", visible(expanded: true), ids)
        await t.equal("검색 중이면 (맞는 것) 전부 — 접기 · 더보기를 무시", visible(searching: true, collapsed: true), ids)

        var named = ConversationThread(projectID: "p", title: "로그인 오류 문구")
        named.goal = "결제 화면 정리"
        await t.check("검색: 제목 · 목표 · 대소문자 무시 · 앞뒤 공백 무시",
                      SidebarRules.matches(named, query: " 로그인 ") && SidebarRules.matches(named, query: "결제")
                        && !SidebarRules.matches(named, query: "없는 말") && SidebarRules.matches(named, query: "   "))
        await t.check("검색칸 자리 글은 찾는 범위를 말한다", SidebarRules.searchPlaceholder.contains("제목")
                        && SidebarRules.noMatchText.contains("맞는 대화가 없습니다"))

        let a = Project(name: "app", path: "/Users/me/work/a/app"), b = Project(name: "app", path: "/Users/me/work/b/app")
        let deep1 = Project(name: "svc", path: "/x/one/api/svc"), deep2 = Project(name: "svc", path: "/y/two/api/svc")
        let solo = Project(name: "solo", path: "/z/solo")
        let names = SidebarRules.displayNames([a, b, deep1, deep2, solo])
        await t.equal("같은 이름이면 위 폴더를 덧붙인다 · 하나뿐이면 그대로",
                      [names[a.id], names[b.id], names[solo.id]], ["app — a", "app — b", "solo"])
        await t.equal("위 폴더도 같으면 더 올라간다", [names[deep1.id], names[deep2.id]], ["svc — one/api", "svc — two/api"])

        var blank = ConversationThread(projectID: "p", title: "새 대화")
        blank.updatedAt = Date(timeIntervalSince1970: 200)
        var older = ConversationThread(projectID: "p", title: "새 스레드")
        older.updatedAt = Date(timeIntervalSince1970: 100)
        var withGoal = ConversationThread(projectID: "p", title: "새 대화")
        withGoal.goal = "목표"
        var archived = ConversationThread(projectID: "p", title: "새 대화")
        archived.archived = true
        await t.equal("다시 쓸 빈 대화 후보: 자리 표시 제목 · 목표 없음 · 보관 아님 · 최근 것 먼저",
                      SidebarRules.blankCandidates([older, named, withGoal, archived, blank]).map(\.id), [blank.id, older.id])
        await t.equal("옛 자리 표시 제목은 지금 말로 보인다 · 붙인 이름은 그대로",
                      [SidebarRules.displayTitle(older), SidebarRules.displayTitle(named)], ["새 대화", "로그인 오류 문구"])

        await t.group("사이드바: 최근 순 · 이전 프로젝트")
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        func day(_ ago: Double) -> Date { now.addingTimeInterval(-ago * 86_400) }
        func project(_ name: String, created: Double = 200) -> Project {
            var p = Project(name: name, path: "/w/\(name)")
            p.createdAt = day(created)
            return p
        }
        func thread(_ project: Project, _ ago: Double) -> ConversationThread {
            var t = ConversationThread(projectID: project.id, title: project.name)
            t.updatedAt = day(ago)
            return t
        }
        let first = project("first"), busy = project("busy"), fresh = project("fresh", created: 1), recent = project("recent"),
            old = project("old"), older2 = project("older")
        var threads: [String: [ConversationThread]] = [
            first.id: [thread(first, 40)], busy.id: [thread(busy, 60)], recent.id: [thread(recent, 2), thread(recent, 30)],
            old.id: [thread(old, 20)], older2.id: [thread(older2, 90)],
        ]
        let running = threads[busy.id]![0].id
        let ordered = SidebarRules.sections([first, busy, fresh, recent, old, older2], threadsByProject: threads, now: now,
                                            searching: false, pinned: { $0.id == running })
        await t.equal("마지막으로 쓴 순서 · 대화가 없으면 연 때 · 2주 넘게 쉰 것은 이전 프로젝트로",
                      ordered.recent.map(\.name) + ["|"] + ordered.idle.map(\.name), ["fresh", "recent", "busy", "|", "old", "first", "older"])
        await t.check("실행 중이거나 답을 기다리는 대화가 있으면 오래돼도 위에", ordered.recent.contains(busy))
        let searching = SidebarRules.sections([first, old, recent], threadsByProject: threads, now: now, searching: true, pinned: { _ in false })
        await t.equal("검색 중이면 묶지 않는다 (최근 순 전부)", searching.recent.map(\.name), ["recent", "old", "first"])
        threads[recent.id] = [thread(recent, 30)]
        let allIdle = SidebarRules.sections([first, old, recent], threadsByProject: threads, now: now, searching: false, pinned: { _ in false })
        await t.equal("모두 오래 쉬었으면 가장 최근 하나는 위에 둔다", allIdle.recent.map(\.name) + ["|"] + allIdle.idle.map(\.name),
                      ["old", "|", "recent", "first"])
        await t.equal("이전 프로젝트 줄의 글", SidebarRules.idleGroupTitle(count: 26), "이전 프로젝트 26개")

        await t.group("빈 칸의 말 (사이드바 · 프로젝트에 맞춘다)")
        let noProject = EmptyPaneText.make(split: false, focused: true, sidebarVisible: true, hasProjects: false)
        await t.check("프로젝트가 없으면 폴더 열기", noProject.actions == [.openFolder] && noProject.detail.contains("⌘O"))
        let single = EmptyPaneText.make(split: false, focused: true, sidebarVisible: true, hasProjects: true)
        await t.check("프로젝트가 있으면 폴더를 또 열라고 하지 않고 새 대화를 권한다",
                      single.title == "대화를 고르세요" && !single.detail.contains("폴더") && single.actions == [.newConversation])
        let hidden = EmptyPaneText.make(split: true, focused: false, sidebarVisible: false, hasProjects: true)
        await t.check("사이드바가 숨어 있으면 '왼쪽에서' 대신 사이드바를 열라고 · 사이드바 보기 단추",
                      !hidden.detail.contains("왼쪽") && hidden.detail.contains("사이드바를 열고")
                        && hidden.actions == [.newConversation, .showSidebar])
        let focusedEmpty = EmptyPaneText.make(split: true, focused: true, sidebarVisible: true, hasProjects: true)
        await t.equal("포커스 빈 칸은 '이 칸을 누른 뒤' 를 빼고", focusedEmpty.detail, "사이드바에서 대화를 고르면 이 칸에 열립니다.")

        await t.group("칸 머리 · 사이드바의 도움말은 분할과 무관한 말")
        var approval = PaneStatusInput()
        approval.pendingApprovals = 1
        approval.runState = .running
        var question = PaneStatusInput()
        question.pendingQuestions = 1
        question.runState = .running
        let helps = [PaneStatus.make(approval)?.help, PaneStatus.make(question)?.help, PaneStatus.handoffHelp].compactMap { $0 }
        await t.check("'칸을 눌러' · '칸 아래' 를 쓰지 않는다 (분할하지 않은 화면의 사이드바 행에도 붙는다)",
                      helps.count == 3 && helps.allSatisfy { !$0.contains("칸") }, helps.joined(separator: " / "))
    }

    // MARK: 앱 — 칸 · 새 대화 · 지우기 안내 · 메뉴바 확인 필요

    /// `AppModel` 의 칸 동작: 분할하면 포커스가 빈 칸으로 · 포커스 칸을 비우면 다른 칸으로 · 지운 대화는 열지 않음 · 빈 새 대화를 쌓지 않음 ·
    /// 실행 중인 대화를 지우려 하면 그 실행을 멈추는 단추 · 다른 칸의 실행이 오류로 끝나면 메뉴바 "확인 필요" (그 대화를 열면 거둔다).
    static func paneApp(_ t: TestKit) async {
        await t.group("분할 화면 · 새 대화 · 메뉴바: 앱")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-paneapp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let folder = root.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.invalid"], ["config", "user.name", "t"],
                              ["commit", "-q", "--allow-empty", "-m", "base"]] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = arguments
                process.currentDirectoryURL = folder
                try process.run()
                process.waitUntilExit()
            }
            let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
            try await store.bootstrap()
            let project = Project(name: "칸", path: folder.path)
            try await store.upsertProject(project)
            func thread(_ title: String) async throws -> ConversationThread {
                var thread = ConversationThread(projectID: project.id, title: title)
                thread.claudeSelection = ModelSelection(model: "sonnet", effort: "high")   // 모델 목록 조회(CLI)를 타지 않게
                try await store.upsertThread(thread)
                return thread
            }
            let first = try await thread("첫째"), second = try await thread("둘째"), failing = try await thread("실패할 대화")

            let model = AppModel(store: store)
            model.runner.adapterFactory = { provider in
                ScriptedAgentAdapter(provider: provider) { request in
                    let opened = AgentEvent.sessionEstablished(sessionID: "s-" + request.runID, model: "fake-model", cliVersion: nil)
                    if request.prompt.hasPrefix("실패") {
                        return [.emit(opened), .finish(AgentTurnResult(state: .failed, terminalReason: "error", sessionID: "s"))]
                    }
                    return [.emit(opened), .waitInterrupt]
                }
            }
            await model.reloadProjects()
            func settle(_ condition: @MainActor () -> Bool) async {
                for _ in 0..<400 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
            }

            // 분할하면 포커스가 빈 칸으로 — 사이드바에서 고른 대화가 보던 칸을 바꾸지 않는다.
            await model.selectThread(first.id)
            let reveal = model.conversationRevealRequest
            await model.setPaneLayout(.twoColumns)
            await t.check("두 칸으로 나누면 포커스는 새 빈 칸", model.panes.focused == 1 && model.panes.threadIDs == [first.id, nil])
            await model.selectThread(second.id)
            await t.equal("그다음 고른 대화는 빈 칸에 열린다", model.panes.threadIDs, [first.id, second.id])
            await t.check("대화를 고르면 가운데 칸을 대화로 돌리라고 알린다 (에이전트 기록 · 크게 보기 중이어도)",
                          model.conversationRevealRequest > reveal)

            // 포커스 칸을 비우면 다른 칸으로.
            await model.closePane(1)
            await t.check("포커스 칸을 비우면 대화가 열린 칸이 포커스를 갖는다",
                          model.panes.focused == 0 && model.selectedThreadID == first.id, "\(model.panes.focused)")

            // 지운 대화(지난 알림 등)는 열지 않는다.
            let before = model.panes
            await model.selectThread("지워진-대화")
            await t.check("없는 대화는 열지 않고 알린다 — 칸이 '읽는 중' 인 채 비지 않게",
                          model.panes == before && model.banner?.text == "이 대화는 지워져 열 수 없습니다.")
            model.banner = nil

            // 접어 둔 프로젝트에서 새 대화를 만들면 사이드바가 그 프로젝트를 편다 — 만든 길만 알린다. 고르기만 한 대화(현황 · 알림 ·
            // 응답 필요 칩 — 모두 selectThread)는 알리지 않는다 (사람이 접어 둔 프로젝트는 그대로 숨긴다).
            _ = model.takeSidebarReveals()
            await model.selectThread(second.id)
            await t.check("대화를 고르기만 하면 사이드바에 펼 프로젝트를 알리지 않는다", model.sidebarRevealProjectIDs.isEmpty)

            // ＋ · ⌘N 을 여러 번 눌러도 빈 "새 대화" 는 하나.
            let fresh = await model.startNewConversation(projectID: project.id)
            await t.equal("새 대화를 만들면 그 프로젝트를 펴라고 알린다", model.takeSidebarReveals(), [project.id])
            await t.check("받아 간 뒤에는 비운다 — 사이드바가 다시 나타나도 그 뒤에 다시 접은 프로젝트를 펴지 않게",
                          model.sidebarRevealProjectIDs.isEmpty && model.takeSidebarReveals().isEmpty)
            let again = await model.startNewConversation(projectID: project.id)
            await t.equal("빈 새 대화를 다시 여는 ⌘N 도 그 프로젝트를 펴라고 알린다", model.takeSidebarReveals(), [project.id])
            let count = (try? await store.threads(projectID: project.id))?.count ?? 0
            await t.check("기록이 없는 빈 새 대화가 있으면 다시 쓴다", fresh.id == again.id && count == 4 && model.selectedThreadID == fresh.id,
                          "\(count)")
            _ = try await store.appendEvent(ThreadEvent(threadID: fresh.id, kind: .userMessage, provider: nil, text: "시작"))
            let third = await model.startNewConversation(projectID: project.id)
            await t.check("기록이 생긴 대화는 다시 쓰지 않는다", third.id != fresh.id)

            // 분할한 직후 빈 칸에서 새 대화: 그 칸에 열리고 옆 칸의 대화는 그대로 (chr-1 · vis-1).
            await model.setPaneLayout(.single)
            await model.selectThread(first.id)
            await model.setPaneLayout(.twoColumns)
            await t.check("줄였다 곧 늘리면 빈 칸이 포커스", model.panes.threadIDs == [first.id, nil] && model.panes.focused == 1,
                          "\(model.panes.threadIDs) \(model.panes.focused)")
            let reused = await model.startNewConversation(projectID: project.id)
            await t.check("칸 밖의 빈 새 대화는 빈 칸에 다시 쓴다 — 옆 칸은 그대로",
                          reused.id == third.id && model.panes.threadIDs == [first.id, third.id], "\(model.panes.threadIDs)")
            await model.setPaneLayout(.fourGrid)
            let created = await model.startNewConversation(projectID: project.id)
            await t.check("다른 칸에 열린 빈 새 대화는 다시 쓰지 않고 새로 만들어 빈 칸에 연다",
                          created.id != third.id && model.panes.threadIDs == [first.id, third.id, created.id, nil]
                            && model.panes.focused == 2, "\(model.panes.threadIDs) \(model.panes.focused)")
            await model.setPaneLayout(.single)

            // 실행 중인 대화를 지우려 하면 — 그 실행을 멈추는 단추 (⌘. 는 포커스 대화만 멈춘다).
            await model.selectThread(second.id)
            _ = await model.send("오래 도는 일", provider: .claude, threadID: second.id)
            await settle { model.runner.isBusy(threadID: second.id) }
            await model.selectThread(first.id)
            let banner = model.deletionBlockBanner(threadIDs: [second.id], prefix: "지우지 않았습니다")
            await t.check("지우기 거절 안내: 어느 대화인지 · 그 실행 멈추기 단추",
                          banner?.text.contains("\"둘째\"") == true && banner?.actionTitle == "그 실행 멈추기"
                            && banner?.text.contains("⌘.") == false, banner?.text ?? "nil")
            banner?.action?()
            await settle { !model.runner.isBusy(threadID: second.id) }
            await t.check("단추가 포커스가 아닌 그 대화의 실행을 멈춘다", !model.runner.isBusy(threadID: second.id))

            // 다른 칸 · 칸에 없는 대화의 실행이 오류로 끝나면 메뉴바 "확인 필요" — 그 대화를 열면 거둔다.
            _ = await model.send("실패하는 일", provider: .claude, threadID: failing.id)
            await settle { model.unseenRunProblems.contains { $0.threadID == failing.id } }
            await t.check("보지 않은 대화의 실패를 메뉴바가 적는다", model.unseenRunProblems.map(\.threadID) == [failing.id]
                            && model.unseenRunProblems.first?.state == .failed)
            await model.selectThread(failing.id)
            await t.check("그 대화를 열면 거둔다", model.unseenRunProblems.isEmpty)
        } catch {
            await t.check("칸 · 새 대화 앱 시험 준비", false, "\(error)")
        }
    }

    // MARK: 메뉴바 · 앱 종료 확인 (순수)

    static func menuBarAndQuit(_ t: TestKit) async {
        await t.group("메뉴바: 확인 필요의 까닭")
        let failed = MenuBarStatus.UnseenRun(threadID: "t1", title: "로그인 수정", state: .failed)
        let limited = MenuBarStatus.UnseenRun(threadID: "t2", title: "결제", state: .rateLimited)
        let problems = MenuBarStatus.problems(unseenRuns: [failed, limited], cappedAccounts: ["Claude"],
                                              authProblemAccounts: ["Codex · 계정2"], unterminated: 1)
        await t.equal("까닭마다 한 줄 — 대화의 일은 그 대화로 갈 수 있다",
                      problems.map(\.text),
                      ["로그인 수정 — 마지막 실행이 오류로 끝났습니다", "결제 — 사용 한도에 닿아 멈췄습니다", "Claude 사용 한도에 닿았습니다",
                       "Codex · 계정2 로그인을 확인하세요 (설정 > 에이전트)", "종료가 확인되지 않은 프로세스 1개 — 대화의 안내를 보세요"])
        await t.equal("대화의 일만 갈 곳이 있다", problems.map(\.threadID), ["t1", "t2", nil, nil, nil])
        await t.equal("우선순위: 답을 기다림 → 실행 중 → 확인 필요 → 대기",
                      [MenuBarStatus.state(attention: 1, running: 1, problems: problems),
                       MenuBarStatus.state(attention: 0, running: 2, problems: problems),
                       MenuBarStatus.state(attention: 0, running: 0, problems: problems),
                       MenuBarStatus.state(attention: 0, running: 0, problems: [])],
                      [.needsResponse, .running, .problem, .idle])
        await t.check("확인 필요로 세는 실행: 오류 · 한도 · 전달 미확인 (완료 · 사람이 멈춤은 아님)",
                      MenuBarStatus.isProblem(.failed) && MenuBarStatus.isProblem(.rateLimited)
                        && MenuBarStatus.isProblem(.handoffDeliveryUnknown)
                        && !MenuBarStatus.isProblem(.completed) && !MenuBarStatus.isProblem(.cancelled))

        await t.group("앱 종료 확인")
        await t.check("물을 것이 없으면 곧바로 끝낸다", QuitConfirmation.make(.init()) == nil)
        let running = QuitConfirmation.make(.init(running: 2, background: 3, cards: 1, countdowns: 1, busyShells: 2))
        await t.equal("실행 중: 결과 위주의 제목 · 되돌릴 수 없는 단추 이름",
                      [running?.title, running?.confirmTitle, running?.cancelTitle],
                      ["실행 중인 에이전트 2개와 백그라운드 작업 3개를 멈추고 종료할까요?", "멈추고 종료", "취소"])
        await t.check("예전의 어려운 문장('종료를 완료했다고 표시하지 않습니다')을 쓰지 않는다",
                      running.map { !$0.informativeText.contains("표시하지 않습니다") } == true)
        await t.check("인계 카드 · 걸어 둔 메시지 · 터미널의 셸까지 적는다",
                      running.map { $0.informativeText.contains("인계 카드 1개") && $0.informativeText.contains("카운트다운 1개")
                                    && $0.informativeText.contains("걸어 둔 메시지") && $0.informativeText.contains("셸 2개") } == true,
                      running?.informativeText ?? "")
        let shells = QuitConfirmation.make(.init(busyShells: 1))
        await t.check("셸에서 명령만 돌아도 묻는다 (확인 창 뒤에 셸을 끈다)",
                      shells?.title == "터미널 탭에서 명령이 돌고 있습니다. 종료할까요?"
                        && shells?.lines == ["터미널 탭의 셸에서 도는 명령도 함께 끝납니다."])
        let sending = QuitConfirmation.make(.init(sending: 1))
        await t.check("보내는 중인 메시지가 있으면 묻는다 — 입력창에 되돌린다고 말한다 (chr-9)",
                      sending?.title == "보내는 중인 메시지를 보내지 않고 종료할까요?"
                        && sending?.informativeText.contains("입력창에 되돌려") == true, sending?.title ?? "nil")
        let git = QuitConfirmation.make(.init(appCommands: 1))
        await t.check("앱의 git · 독립 작업 폴더 명령이 돌면 묻는다", git?.title == "앱이 git 명령을 실행하고 있습니다. 종료할까요?"
                        && git?.informativeText.contains("변경사항 탭") == true, git?.title ?? "nil")
        let cardsOnly = QuitConfirmation.make(.init(cards: 1))
        await t.equal("카드만 있을 때", cardsOnly?.title, "넘기지 않은 인계 카드를 버리고 종료할까요?")
        let switchOnly = QuitConfirmation.make(.init(codexSwitches: 1))
        await t.check("다른 계정에서 이어 가려던 카운트다운만 있어도 묻는다 — 멈췄다는 것 · 직접 이어 갈 곳 (인계라 하지 않는다)",
                      switchOnly?.title == "다른 계정에서 이어 가지 않고 종료할까요?" && switchOnly?.confirmTitle == "종료"
                        && switchOnly?.lines == ["자동으로 다른 계정에서 같은 세션을 이어 가려던 카운트다운을 멈췄습니다 — "
                                                 + "한도 줄이나 입력창의 에이전트 칩에서 직접 이어 갈 수 있습니다."],
                      switchOnly?.informativeText ?? "nil")
        let switchesWithRun = QuitConfirmation.make(.init(running: 1, codexSwitches: 2))
        await t.check("실행과 함께면 제목은 실행 · 줄에 멈춘 카운트다운의 수",
                      switchesWithRun?.title == "실행 중인 에이전트를 멈추고 종료할까요?"
                        && switchesWithRun?.informativeText.contains("이어 가려던 카운트다운 2개를 멈췄습니다") == true,
                      switchesWithRun?.informativeText ?? "nil")
        await t.equal("여럿만 있을 때의 제목", QuitConfirmation.make(.init(codexSwitches: 2))?.title,
                      "대화 2개를 다른 계정에서 이어 가지 않고 종료할까요?")
        let cardAndSwitch = QuitConfirmation.make(.init(cards: 1, countdowns: 1, codexSwitches: 1))
        await t.check("인계 카드와 함께면 제목은 카드 · 두 카운트다운을 따로 말한다",
                      cardAndSwitch?.title == "넘기지 않은 인계 카드를 버리고 종료할까요?"
                        && cardAndSwitch?.informativeText.contains("자동 인계 카운트다운 1개는 멈춰 두었습니다") == true
                        && cardAndSwitch?.informativeText.contains("같은 세션을 이어 가려던 카운트다운을 멈췄습니다") == true,
                      cardAndSwitch?.informativeText ?? "nil")
        await t.equal("정리를 확인하지 못했을 때의 두 번째 확인", QuitConfirmation.cleanupUnconfirmed.confirmTitle, "그래도 종료")
    }

    /// 판정 (순수) — `PaneStatus` · `PaneHeaderDensity` · `ResponseNeeded`.
    static func rules(_ t: TestKit) async {
        await t.group("칸 머리: 상태 판정")
        let now = Date(timeIntervalSince1970: 1_000_000)
        func status(_ input: PaneStatusInput) -> PaneStatus? { PaneStatus.make(input, now: now) }
        await t.check("기록 없는 대화는 상태를 두지 않는다", status(PaneStatusInput()) == nil)
        var handoffReview = PaneStatusInput()
        handoffReview.handoffReview = true
        handoffReview.lastRunState = .rateLimited
        await t.check("남긴 자동 인계 검토는 응답 필요 (한도 도달보다 먼저)",
                      status(handoffReview).map { $0.text == "인계 검토 필요" && $0.needsResponse } == true)
        var countdown = PaneStatusInput()
        countdown.handoffCountdown = true
        countdown.lastRunState = .rateLimited
        await t.check("자동 인계 카운트다운은 보이되 응답 필요는 아님",
                      status(countdown).map { $0.text == "자동 인계 대기" && !$0.needsResponse } == true)
        var codexSwitch = PaneStatusInput()
        codexSwitch.codexSwitchCountdown = true
        codexSwitch.lastRunState = .rateLimited
        await t.check("다른 계정에서 이어 가기 카운트다운: 자동 인계 카운트다운과 같은 무게 (보이되 응답 필요는 아님 · 한도 도달보다 먼저)",
                      status(codexSwitch).map { $0.text == CodexAccountSwitch.waitingText && $0.tone == .attention && !$0.needsResponse }
                        == true, status(codexSwitch)?.text ?? "nil")
        await t.check("그 글은 인계라 하지 않는다 — 같은 세션을 다른 계정에서 이어 간다",
                      status(codexSwitch).map { !$0.text.contains("인계") && !$0.shortText.contains("인계")
                                                && $0.help.contains("다른 계정에서 그대로 이어") } == true,
                      status(codexSwitch).map { "\($0.text) / \($0.shortText) / \($0.help)" } ?? "nil")
        await t.check("카운트다운 둘 다 사이드바 · Dock 이 세는 카운트다운이다",
                      countdown.countingDown && codexSwitch.countingDown && !PaneStatusInput().countingDown)
        var switchApproval = codexSwitch
        switchApproval.pendingApprovals = 1
        var switchOrchestration = codexSwitch
        switchOrchestration.orchestration = .planApproval
        var switchRunning = codexSwitch
        switchRunning.runState = .running
        await t.equal("우선순위는 자동 인계 카운트다운과 같다: 승인 · 자동 작업이 먼저, 도는 실행보다는 앞",
                      [status(switchApproval)?.text, status(switchOrchestration)?.text, status(switchRunning)?.text],
                      ["승인 대기", "계획 승인 대기", CodexAccountSwitch.waitingText])
        await t.equal("사이드바 배지 — 인계의 기호(⇄)를 쓰지 않는다", CodexAccountSwitch.badgeText(seconds: 9), "계정 9초")
        var cardSending = PaneStatusInput()
        cardSending.handoffSending = true
        cardSending.lastRunState = .rateLimited
        var deliveryRun = PaneStatusInput()
        deliveryRun.runState = .handoffSending
        await t.check("카드를 보내는 중(전달 실행 전)도 전달 실행과 같은 '인계 보내는 중' — '인계 초안' 이 아니다",
                      status(cardSending) == status(deliveryRun) && status(cardSending)?.text == "인계 보내는 중")
        var running = PaneStatusInput()
        running.runState = .running
        await t.check("도는 중", status(running).map { $0.text == "실행 중" && $0.tone == .active && !$0.needsResponse } == true)
        var approval = running
        approval.runState = .awaitingApproval
        approval.pendingApprovals = 1
        approval.pendingQuestions = 1
        await t.check("승인이 질문보다 먼저 · 답을 기다린다",
                      status(approval).map { $0.text == "승인 대기" && $0.needsResponse && $0.tone == .attention } == true)
        approval.pendingApprovals = 2
        await t.equal("승인이 여럿이면 수", status(approval)?.text, "승인 대기 2")
        await t.equal("좁은 칸의 짧은 문구", status(approval)?.shortText, "승인 2")
        var question = running
        question.pendingQuestions = 1
        await t.check("질문", status(question).map { $0.text == "질문 대기" && $0.needsResponse } == true)
        var orchestration = PaneStatusInput()
        orchestration.orchestration = .planApproval
        orchestration.lastRunState = .completed
        await t.check("자동 작업이 사람을 기다리면 끝난 실행보다 먼저 · 답을 기다린다",
                      status(orchestration).map { $0.text == "계획 승인 대기" && $0.needsResponse } == true)
        var waiting = running
        waiting.waitingOnBackground = true
        waiting.unfinishedSubAgents = 2
        await t.equal("백그라운드 대기 — 턴 머리줄과 같은 이름", status(waiting)?.text, "백그라운드 작업 2개 기다리는 중")
        await t.equal("백그라운드 대기의 짧은 글 · 도움말에 안쪽 구조의 말이 없다",
                      [status(waiting)?.shortText ?? "", (status(waiting)?.help ?? "").contains("메인") ? "메인" : "없음"],
                      ["백그라운드 2", "없음"])
        var review = running
        review.reviewing = true
        await t.equal("검토 레인", status(review)?.text, "검토 중")
        var done = PaneStatusInput()
        done.lastRunState = .completed
        done.lastRunEndedAt = now.addingTimeInterval(-180)
        await t.check("끝난 실행은 흐리게 · 언제",
                      status(done).map { $0.text == "완료 · 3분 전" && $0.tone == .quiet && !$0.needsResponse } == true,
                      status(done)?.text ?? "nil")
        done.lastRunState = .failed
        await t.equal("오류는 빨강", status(done)?.tone, .danger)
        done.lastRunState = .rateLimited
        await t.check("한도는 알리되 답을 기다리지는 않는다", status(done).map { $0.tone == .attention && !$0.needsResponse } == true)
        done.lastRunState = .handoffDeliveryUnknown
        await t.check("전달 미확인은 시각 없이", status(done)?.text == "전달 여부 미확인")
        var both = running
        both.lastRunState = .failed
        await t.equal("도는 실행이 끝난 실행보다 먼저", status(both)?.text, "실행 중")

        await t.group("칸 머리: 밀도 · 프로젝트 · 응답 필요 목록")
        await t.equal("넓은 칸", PaneHeaderDensity.forWidth(700), .full)
        await t.equal("네 칸 정도", PaneHeaderDensity.forWidth(450), .medium)
        await t.equal("좁은 칸", PaneHeaderDensity.forWidth(300), .compact)
        await t.check("칸들의 프로젝트가 같으면 적지 않는다", !PaneHeaderDensity.showsProject(paneProjectIDs: ["p", "p", nil]))
        await t.check("다르면 적는다", PaneHeaderDensity.showsProject(paneProjectIDs: ["p", "q", nil]))
        let items = [ResponseNeeded(threadID: "x", title: "칸에 없는 대화", provider: .codex, what: "질문 대기"),
                     ResponseNeeded(threadID: "b", title: "둘째 칸", provider: .claude, what: "승인 대기"),
                     ResponseNeeded(threadID: "a", title: "포커스", provider: .claude, what: "승인 대기")]
        let ordered = ResponseNeeded.ordered(items, paneThreadIDs: ["a", "b", nil], focusedThreadID: "a")
        await t.equal("포커스 대화는 빼고 칸 순서가 먼저", ordered.map(\.threadID), ["b", "x"])
        await t.equal("여럿이면 수", ResponseNeeded.chipTitle(ordered), "응답 필요 2")
        await t.equal("하나면 무엇을", ResponseNeeded.chipTitle([items[1]]), "응답 필요 · 승인 대기")
    }

    /// Dock 배지가 세는 단위 — 사이드바 행. 내부 대화는 부모로, 겹친 것은 하나로, 부모를 모르는 내부 대화는 뺀다.
    static func badgeRows(_ t: TestKit) async {
        await t.group("Dock 배지: 사이드바 행 단위")
        let parents = ["task-1": "parent", "task-2": "parent", "plan": "other-parent"]
        let rows = AttentionBadge.rows(["a", "task-1", "task-2", "parent", "orphan-task", "a", "plan"],
                                       isInternal: { $0.contains("task") || $0 == "plan" },
                                       parentOf: { parents[$0] })
        await t.equal("내부 대화 → 부모 · 겹침 제거 · 부모 모름은 뺌 · 순서 유지", rows, ["a", "parent", "other-parent"])
        await t.equal("배지 글자", [AttentionBadge.label(0), AttentionBadge.label(3)], [nil, "3"])
    }

    /// 앱: 실제 `RunCoordinator` · SQLite, CLI 만 가짜(`ScriptedAgentAdapter`). 두 칸 — 승인을 청한 실행의 칸 머리 · 응답 필요,
    /// 같은 폴더의 겹침, 포커스를 옮기면 목록에서 빠짐, 답하면 끝난 실행.
    static func app(_ t: TestKit) async {
        await t.group("칸 머리: 앱에서 승인 대기 → 응답 필요")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-panestatus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let folder = root.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.invalid"], ["config", "user.name", "t"],
                              ["commit", "-q", "--allow-empty", "-m", "base"]] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = arguments
                process.currentDirectoryURL = folder
                try process.run()
                process.waitUntilExit()
            }
            let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
            try await store.bootstrap()
            let project = Project(name: "칸", path: folder.path)
            try await store.upsertProject(project)
            func thread(_ title: String) async throws -> ConversationThread {
                var thread = ConversationThread(projectID: project.id, title: title)
                thread.claudeSelection = ModelSelection(model: "sonnet", effort: "high")   // 모델 목록 조회(CLI)를 타지 않게
                try await store.upsertThread(thread)
                return thread
            }
            let asking = try await thread("승인을 청하는 대화"), busy = try await thread("도는 대화")

            let model = AppModel(store: store)
            model.runner.adapterFactory = { provider in
                ScriptedAgentAdapter(provider: provider) { request in
                    let opened = AgentEvent.sessionEstablished(sessionID: "s-" + request.runID, model: "fake-model", cliVersion: nil)
                    guard request.prompt.hasPrefix("승인") else { return [.emit(opened), .waitInterrupt] }
                    return [.emit(opened),
                            .emit(.approvalRequested(ApprovalRequest(id: "ap-1", runID: "", provider: provider, kind: .tool,
                                                                     toolName: "Bash", title: "swift test", detail: "swift test"))),
                            .waitApproval(id: "ap-1"),
                            .finish(AgentTurnResult(state: .completed, terminalReason: "completed", sessionID: "s"))]
                }
            }
            await model.reloadProjects()
            func settle(_ condition: @MainActor () -> Bool) async {
                for _ in 0..<400 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
            }

            await model.selectThread(asking.id)
            await model.openInNewPane(busy.id)   // 두 칸: [승인을 청하는 대화, 도는 대화], 포커스는 둘째 칸
            _ = await model.send("승인이 필요한 일", provider: .claude, threadID: asking.id)
            _ = await model.send("그냥 도는 일", provider: .claude, threadID: busy.id)
            await settle { model.runner.session(threadID: asking.id)?.pendingApprovals.isEmpty == false
                            && model.runner.isBusy(threadID: busy.id) }

            let input = model.paneStatusInput(for: asking)
            let status = PaneStatus.make(input)
            await t.check("승인을 청한 칸: 승인 대기 · 답을 기다림", status?.text == "승인 대기" && status?.needsResponse == true,
                          status?.text ?? "nil")
            await t.check("같은 폴더에서 함께 돈다", input.sharesFolder && model.paneStatusInput(for: busy).sharesFolder)
            await t.equal("도는 칸", PaneStatus.make(model.paneStatusInput(for: busy))?.text, "실행 중")
            await t.equal("응답 필요: 포커스가 아닌 칸의 대화", model.responseNeeded.map(\.threadID), [asking.id])
            await t.equal("무엇을 기다리나", model.responseNeeded.first?.what, "승인 대기")
            var badges: [Int] = []
            let observer = AttentionBadgeObserver(read: { model.dockAttentionThreadIDs.count }) { badges.append($0) }
            observer.start()
            observer.start()   // 창을 다시 열어 두 번 불러도 한 번만 건다
            await t.equal("Dock 배지: 승인을 기다리는 대화 하나", badges, [1])

            await model.selectThread(asking.id)   // 이미 열린 칸 → 그 칸으로 포커스
            await t.check("포커스를 옮기면 목록에서 빠진다", model.panes.focused == 0 && model.responseNeeded.isEmpty)
            await t.equal("Dock 배지는 포커스 대화도 센다", model.dockAttentionThreadIDs, [asking.id])

            if let request = model.runner.session(threadID: asking.id)?.pendingApprovals.first {
                await model.runner.respond(approval: request, decision: .allow)
            }
            await settle { !model.runner.isBusy(threadID: asking.id)
                            && model.threadStates[asking.id]?.runsByID.values.contains { $0.state == .completed } == true }
            await t.check("답하면 끝난 실행으로", PaneStatus.make(model.paneStatusInput(for: asking))?.text.hasPrefix("완료") == true,
                          PaneStatus.make(model.paneStatusInput(for: asking))?.text ?? "nil")
            await t.check("다른 칸의 겹침 표시도 풀린다", !model.paneStatusInput(for: busy).sharesFolder)
            await settle { badges.last == 0 }
            await t.equal("Dock 배지: 답하면 지운다 (관찰을 다시 걸어 바뀐 값을 읽는다)", badges, [1, 0])

            await model.runner.interrupt(threadID: busy.id)
            await settle { !model.runner.isBusy(threadID: busy.id) }
        } catch {
            await t.check("칸 머리 앱 시험 준비", false, "\(error)")
        }
    }
}
