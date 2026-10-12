import SwiftUI
import AppKit

@main
struct AgentHandoffConsoleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage(WindowStateKey.inspectorVisible) private var inspectorVisible = WindowStateKey.inspectorVisibleByDefault
    @AppStorage(WindowStateKey.inspectorTab) private var inspectorTab: InspectorTab = .files
    /// 가운데 칸 (대화 · 에이전트 기록). 크게 보기는 `model.diffWideActive` 가 정한다 (`WindowPane.shown`).
    @AppStorage(WindowStateKey.pane) private var windowPane: WindowPane = .conversation

    var body: some Scene {
        // 메인 창은 하나만 존재한다.
        // `WindowGroup` 은 상태 복원과 겹쳐 창이 중복 생성될 수 있어 단일 `Window` 씬을 쓴다.
        // 닫았다가 `openWindow(id:)` 로 같은 창을 다시 열 수 있다.
        Window("Agent Handoff Console", id: MainWindowID.value) {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1500, height: 920)
        .commands {
            // 단축키는 `MenuShortcut` 표 한 곳에서 정한다 (검증 하네스가 겹침을 확인한다 — "메뉴 단축키").
            CommandGroup(replacing: .newItem) {
                // 새 대화는 선택된 프로젝트에 (기록 없는 빈 "새 대화" 가 있으면 그것을 연다 — `startNewConversation`).
                // 프로젝트가 없으면 폴더 고르기로 — 첫 대화는 폴더를 열면 생긴다 (눌러도 아무 일 없던 것).
                Button(MenuShortcut.newThread.title) {
                    if let projectID = model.selectedProjectID ?? model.projects.first?.id {
                        AppDelegate.showMainWindow()
                        Task { await model.startNewConversation(projectID: projectID) }
                    } else {
                        Task { await ProjectFolderPicker.openFromMenu(model: model) }
                    }
                }
                .menuShortcut(.newThread)
                // 변경사항 탭의 브랜치 메뉴를 새 이름 입력 상태로 연다. ⌘N 은 새 대화라 ⇧⌘N 을 쓴다.
                // 탭이 아직 없을 수 있어 알림 대신 모델에 요청을 남기고, 탭이 나타나면 메뉴를 연다 (⌘⇧F 와 같은 방식).
                // 요청은 몇 초 안에만 받는다 (창이 닫혀 있을 때 누른 것이 나중에 저절로 열리지 않게).
                Button(MenuShortcut.newBranch.title) {
                    inspectorTab = .changes
                    inspectorVisible = true
                    model.requestNewBranch()
                }
                .menuShortcut(.newBranch)
                .disabled(model.workspace.git?.isRepository != true)
                Divider()
                // 창이 없으면 먼저 연다 (폴더 고르기를 시트로 붙일 곳).
                Button(MenuShortcut.openProjectFolder.title) {
                    Task { await ProjectFolderPicker.openFromMenu(model: model) }
                }
                .menuShortcut(.openProjectFolder)
                Button("Claude Code · Codex 기록 가져오기…") { model.showImportSheet = true }
            }
            // 찾기: ⌘F 는 포커스 칸의 대화 안 찾기(찾기 막대 — `ThreadFind`), ⌘G · ⇧⌘G 는 다음 · 이전, ⌥⌘F 는 사이드바의 대화 목록 검색.
            // SwiftUI 의 기본 편집 메뉴에는 찾기 · 맞춤법 · 대치 · 말하기 항목이 없다 (`TextEditingCommands` 를 넣을 때만 생긴다 —
            // 2026-10-04 시험 앱으로 확인). 그래서 이 묶음을 바꿔도 잃는 항목이 없다. 그 명령들을 넣으면 자체 ⌘F · ⌘G 가 대화 안 찾기와
            // 겹치고, 코드 입력칸에서 일부러 끈 대치(스마트 따옴표 · `PlainTextInput`)를 다시 켜는 메뉴가 생긴다.
            CommandGroup(replacing: .textEditing) {
                Button(MenuShortcut.findInConversation.title) { AppDelegate.showMainWindow(); model.requestFind(.open) }
                    .menuShortcut(.findInConversation)
                    .disabled(!findAvailable)
                Button(MenuShortcut.findNext.title) { AppDelegate.showMainWindow(); model.requestFind(.next) }
                    .menuShortcut(.findNext)
                    .disabled(!findAvailable)
                Button(MenuShortcut.findPrevious.title) { AppDelegate.showMainWindow(); model.requestFind(.previous) }
                    .menuShortcut(.findPrevious)
                    .disabled(!findAvailable)
                Divider()
                Button(MenuShortcut.threadSearch.title) {
                    AppDelegate.showMainWindow()
                    model.requestSidebarSearch()
                }
                .menuShortcut(.threadSearch)
                .disabled(model.projects.isEmpty)
                // 변경사항 탭의 파일 목록 찾기. ⌘F 는 대화 안 찾기, ⌘P 는 파일 탭이라 ⌘⇧F 를 쓴다.
                // 탭이 아직 없을 수 있어 알림 대신 모델에 요청을 남기고, 탭이 나타나면 칸에 포커스한다.
                Button(MenuShortcut.changesSearch.title) {
                    inspectorTab = .changes
                    inspectorVisible = true
                    model.changesSearchFocusRequested = true
                }
                .menuShortcut(.changesSearch)
            }
            // 인쇄할 문서가 없으므로 ⌘P 는 파일 찾기로 쓴다.
            CommandGroup(replacing: .printItem) {
                Button(MenuShortcut.fileSearch.title) {
                    inspectorTab = .files
                    inspectorVisible = true
                    NotificationCenter.default.post(name: .handoffConsoleFocusFileSearch, object: nil)
                }
                .menuShortcut(.fileSearch)
            }
            // 사이드바는 앱이 직접 그린다 (NavigationSplitView 가 아니다) — 시스템의 사이드바 항목 대신 앱의 상태를 바꾼다.
            CommandGroup(replacing: .sidebar) {
                Button(model.sidebarVisible ? "사이드바 숨기기" : "사이드바 보기") {
                    model.sidebarVisible.toggle()
                }
                .menuShortcut(.toggleSidebar)
            }
            CommandGroup(after: .sidebar) {
                Button(inspectorVisible ? "인스펙터 숨기기" : "인스펙터 보기") {
                    inspectorVisible.toggle()
                }
                .menuShortcut(.toggleInspector)
                ForEach(InspectorTab.allCases) { tab in
                    Button(tab.title) {
                        inspectorTab = tab
                        inspectorVisible = true
                    }
                    .menuShortcut(.inspectorTab(tab))
                }
                Divider()
                // 분할 화면 (툴바 ⋯ 와 같은 동작 — 고르면 대화 화면으로). ⌃⌘ + 칸 수.
                Menu("분할 화면") {
                    ForEach(PaneLayout.allCases) { layout in
                        Button(layout.title) {
                            if model.diffWideActive { model.closeDiff() }
                            windowPane = .conversation
                            Task { await model.setPaneLayout(layout) }
                        }
                        .menuShortcut(.paneLayout(layout))
                        .disabled(layout == model.panes.layout && windowPane == .conversation && !model.diffWideActive)
                    }
                }
                // 현황 ↔ 대화 · 에이전트 기록 ↔ 대화 (툴바 ⋯ · 사이드바의 행 · 단추와 같다).
                let shown = WindowPane.shown(stored: windowPane, reviewing: model.diffWideActive)
                Button(WindowPane.overviewToggleTitle(shown: shown)) {
                    if model.diffWideActive { model.closeDiff() }
                    windowPane = WindowPane.togglingOverview(shown: shown)
                }
                .menuShortcut(.overview)
                Button(WindowPane.scoreboardToggleTitle(shown: shown)) {
                    if model.diffWideActive { model.closeDiff() }
                    windowPane = WindowPane.togglingScoreboard(shown: shown)
                }
                .menuShortcut(.scoreboard)
                Divider()
            }
            // 포커스 대화에 하는 동작 (보기 메뉴에 섞여 있던 것). 새 대화는 파일 메뉴에 둔다 (macOS 관례).
            CommandMenu("대화") {
                Button(MenuShortcut.interrupt.title) {
                    Task { await model.interrupt() }
                }
                .menuShortcut(.interrupt)
                .disabled(!model.canInterrupt)
                // 포커스 칸의 맨 앞 승인 카드 — 카드가 받아 단추와 같은 막음을 거친다 (`ApprovalShortcut`).
                // 현황이 보이면 현황에서 고른 행의 대화 (`AppModel.approvalShortcutThreadID`).
                let decisions: RunSession? = model.approvalShortcutThreadID.flatMap { model.runner.session(threadID: $0) }
                let hasApproval: Bool = decisions?.pendingApprovals.isEmpty == false
                let hasQuestion: Bool = decisions?.pendingQuestions.isEmpty == false
                Button(hasApproval || !hasQuestion ? MenuShortcut.approvalAllow.title : "질문에 응답 보내기") {
                    ApprovalShortcut.post(.allow, threadID: model.approvalShortcutThreadID)
                }
                .menuShortcut(.approvalAllow)
                .disabled(!hasApproval && !hasQuestion)
                Button(MenuShortcut.approvalDeny.title) {
                    ApprovalShortcut.post(.deny, threadID: model.approvalShortcutThreadID)
                }
                .menuShortcut(.approvalDeny)
                .disabled(!hasApproval)
                // 카드가 있으면 그 카드로 간다 (`prepareHandoff`), 없으면 기본 대상으로 카드를 만든다.
                Button(MenuShortcut.handoff.title) {
                    guard let t = model.selectedThread else { return }
                    let target = model.defaultHandoffTarget(for: t)
                    Task { await model.prepareHandoff(to: target.provider, toAccountID: target.codexAccountID) }
                }
                .menuShortcut(.handoff)
                .disabled(!handoffMenuEnabled)
                Divider()
                Button(MenuShortcut.refreshLimits.title) {
                    Task { await model.limits.refreshAll(force: true) }
                }
                .menuShortcut(.refreshLimits)
            }
            // 도움말: 이 앱 소개(인계가 무엇인지) · 키보드 단축키(`MenuShortcut` 표에서) · 시작 점검표. 기본 항목("… 도움말")은 도움말
            // 문서(Help Book)가 없어 누르면 "도움말을 사용할 수 없음" 만 떴다 — 그 자리를 이 앱 소개(⌘?)로 바꾼다. 도움말 메뉴의
            // 검색칸(Spotlight for Help)은 AppKit 이 `NSApp.helpMenu` 에 붙이므로 그대로 남는다 (이 묶음을 바꿔도 helpMenu 는 그 메뉴다
            // — 2026-10-04 시험 앱으로 확인).
            CommandGroup(replacing: .help) {
                Button(MenuShortcut.appGuide.title) {
                    AppDelegate.showMainWindow()
                    model.showAppGuide = true
                }
                .menuShortcut(.appGuide)
                Button(MenuShortcut.keyboardShortcutsTitle) {
                    AppDelegate.showMainWindow()
                    model.showKeyboardShortcuts = true
                }
                Divider()
                // 첫 실행 점검표를 시트로 (프로젝트가 있는 사람도). 프로젝트가 없으면 가운데 칸이 이미 점검표다 — 그쪽으로.
                Button("시작 점검…") {
                    AppDelegate.showMainWindow()
                    if model.showsFirstRun {
                        if model.diffWideActive { model.closeDiff() }
                        windowPane = .conversation
                    } else {
                        model.showFirstRunSheet = true
                    }
                }
                // 공개 저장소 주소가 정해졌을 때만 (`AppLinks.repository`).
                if let repository = AppLinks.repository {
                    Divider()
                    Button("저장소 열기") { NSWorkspace.shared.open(repository) }
                    if let issues = AppLinks.issues {
                        Button("문제 알리기…") { NSWorkspace.shared.open(issues) }
                    }
                }
            }
            #if DEBUG
            CommandMenu("디버그") {
                // 설정 > 인계에서 자동 인계를 켠 뒤 쓴다. 꺼져 있으면 흉내만 기록되고 아무것도 보내지 않는다.
                Button("한도 도달 흉내 (자동 인계 시험)") {
                    Task { await model.simulateLimitReached() }
                }
                .disabled(model.selectedThread == nil || model.isSelectedThreadBusy)
            }
            #endif
        }

        MenuBarExtra {
            MenuBarPopover().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model)
        }
    }

    /// ⌘F · ⌘G — 포커스 칸에 기록이 있는 대화가 열려 있을 때 (에이전트 기록 · 크게 보기에서 누르면 대화로 돌아가 찾는다).
    /// 아직 아무 기록이 없는 대화(시작 화면)에는 찾을 것이 없다.
    /// 대화 안 찾기를 쓸 수 있다. diff 크게 보기 중에는 끈다 — 찾기 막대를 열려고 diff 를 닫고 대화로 바꿨다 (conv-10).
    /// 설정 창이 앞에 있으면 메인 창을 앞으로 가져온 뒤 막대를 연다 (`AppDelegate.showMainWindow`).
    private var findAvailable: Bool {
        model.selectedThread != nil && !model.showsFirstRun && !model.events.isEmpty && !model.diffWideActive
    }

    /// ⇧⌘H — 포커스 대화에 카드가 있으면 늘(그 카드로 간다), 없으면 실행 중이 아니고 인계할 수 있는 대화일 때
    /// (내부 대화 · 끝나지 않은 자동 작업 · 기록 없는 대화는 끈다).
    private var handoffMenuEnabled: Bool {
        guard let thread = model.selectedThread else { return false }
        if model.hasHandoffActivity(threadID: thread.id) { return true }
        return !model.isSelectedThreadBusy && model.handoffEntryBlock(for: thread) == nil
    }
}

/// 창 수명과 앱 종료 처리.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 창이 다시 열릴 때마다 다시 넣지만 배지 관찰은 처음 한 번만 건다.
    var model: AppModel? {
        didSet {
            guard oldValue == nil, let model else { return }
            MainActor.assumeIsolated {
                let observer = AttentionBadgeObserver(read: { model.dockAttentionThreadIDs.count }) { count in
                    NSApp.dockTile.badgeLabel = AttentionBadge.label(count)
                }
                badgeObserver = observer
                observer.start()
                // 시스템 알림: 앱이 앞에 있고 그 대화가 보이는 메인 창의 칸에 열려 있으면 내지 않는다 (`NotificationGate`).
                model.notifications.isAppActive = { NSApp.isActive }
                model.notifications.isThreadOnScreen = { [weak model] threadID in
                    guard let model, NSApp.isActive, MainWindowID.candidates().contains(where: {
                        $0.isVisible && $0.occlusionState.contains(.visible)
                    }) else { return false }
                    return model.isThreadShownInPanes(threadID)
                }
            }
        }
    }
    /// Dock 배지 — 사람을 기다리는 대화 수. 창을 닫아도 앱이 살아 있는 동안.
    private var badgeObserver: AttentionBadgeObserver?
    private var terminationInProgress = false

    /// 메인 창을 닫아도 앱은 메뉴바에 남고 작업을 계속한다.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 마우스 휠 한 칸의 거리 — AppKit 기본 10pt 를 브라우저처럼 40pt 로 (`WheelScroll`).
        MainActor.assumeIsolated { WheelScroll.install() }
        NotificationCenter.default.addObserver(
            forName: .handoffConsoleOpenMainWindow, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Self.showMainWindow() }
            }
    }

    /// Dock 아이콘이나 메뉴바에서 다시 열 수 있어야 한다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainActor.assumeIsolated {
                Self.showMainWindow()
            }
        }
        return true
    }

    /// 메인 창을 앞으로 가져오거나 다시 만든다.
    ///
    /// 주의: 창을 닫아도 `NSApp.windows` 에는 닫힌 창 객체가 남아 있을 수 있다.
    /// 그 객체를 그대로 `makeKeyAndOrderFront` 하면 아무 일도 일어나지 않으므로,
    /// **보이는 창만** 재사용하고 없으면 새로 연다.
    @MainActor
    static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let visible = mainWindowCandidates().first(where: { $0.isVisible }) {
            visible.makeKeyAndOrderFront(nil)
            return
        }
        // 창이 없으면 WindowGroup 에 새 창을 요청한다.
        // 실행 중인 CLI 프로세스는 RunCoordinator 가 단독 관리하므로 중복 실행되지 않는다.
        WindowOpener.shared.open?(MainWindowID.value)

        // openWindow 가 동작하지 않는 경우를 대비한 최후 수단:
        // 남아 있는 창 객체를 되살려 본다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard !mainWindowCandidates().contains(where: { $0.isVisible }) else { return }
            if let dormant = mainWindowCandidates().first {
                dormant.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// 메뉴바 상태 항목 · 패널 · 설정 창이 아닌, 메인 창 후보들 (`MainWindowID.candidates` — 폴더 고르기와 같은 기준).
    @MainActor
    private static func mainWindowCandidates() -> [NSWindow] {
        MainWindowID.candidates()
    }

    /// 앱 완전 종료는 창 닫기와 구분한다. 확인 창의 글은 `QuitConfirmation`, 기본 단추(Return)는 취소다.
    /// 앱이 띄운 셸(인스펙터 터미널 탭)은 **종료가 확정된 뒤에** 거둔다 — 확인 창에서 취소하면 셸과 그 안의 개발 서버가 살아 있다.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !terminationInProgress else { return .terminateNow }
        // 카운트다운(자동 인계 · 다른 계정에서 이어 가기)을 멈추기 전에 센다 — 확인 글이 멈춘 것을 말한다 (`AppModel.quitFacts`).
        let facts: QuitConfirmation.Facts = MainActor.assumeIsolated {
            model.quitFacts(busyShells: ShellTerminalStore.shared.busySessionCount())
        }
        guard let confirmation = QuitConfirmation.make(facts) else {
            finishImmediately(model)
            return .terminateNow
        }
        // 확인창을 띄우기 전에 카운트다운을 멈추고 새 인계 전달을 막는다 — 창이 떠 있는 동안에도 메인 액터 작업은 돌아, 타이머가
        // 전달 CLI 를 띄우면 그 실행은 `shutdownForQuit` 이 처음 떠 둔 목록에 없어 정리되지 않은 채 앱이 끝났다.
        // 종료를 취소하면 막은 것을 푼다 (멈춘 카드는 확인 길로 남는다).
        MainActor.assumeIsolated { model.suspendHandoffsForQuit() }
        guard MainActor.assumeIsolated({ Self.confirm(confirmation, style: .warning) }) else {
            MainActor.assumeIsolated { model.resumeHandoffsAfterCancelledQuit() }
            return .terminateCancel
        }
        // 확인창이 떠 있는 사이 실행이 생겼으면(막기 전에 점유한 전달 등) 그냥 끝내지 않고 거둔다.
        if facts.running > 0 || MainActor.assumeIsolated({ model.hasRunsToShutDownForQuit }) {
            return shutDownAndTerminate(model)
        }
        // 보내는 중이던 메시지(입력창으로) · 인계 카드의 덧붙일 말로 옮겼던 메시지(대기열로)를 저장한 뒤에 끝낸다 (chr-9 · hand-2).
        if MainActor.assumeIsolated({ model.needsSavingBeforeQuit }) {
            Task { @MainActor in
                await model.saveBeforeQuit()
                ShellTerminalStore.shared.shutdownAll()
                await model.store.db.close()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        finishImmediately(model)
        return .terminateNow
    }

    /// 확인 창을 띄운다. 첫 단추(Return)는 취소, 둘째가 되돌릴 수 없는 동작(파괴적 표시). 진행하면 true.
    @MainActor
    private static func confirm(_ confirmation: QuitConfirmation, style: NSAlert.Style) -> Bool {
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.informativeText
        alert.addButton(withTitle: confirmation.cancelTitle)
        let proceed = alert.addButton(withTitle: confirmation.confirmTitle)
        proceed.hasDestructiveAction = true
        alert.alertStyle = style
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// 거둘 실행이 없는 종료: 셸을 거두고 DB 를 닫는다.
    private func finishImmediately(_ model: AppModel) {
        MainActor.assumeIsolated {
            ShellTerminalStore.shared.shutdownAll()
            let closeTask = Task { await model.store.db.close() }
            _ = closeTask
        }
    }

    /// 도는 실행을 모두 거두고 끝낸다. 정리를 확인하지 못해 사람이 취소하면 종료를 되돌린다 (셸은 그때까지 그대로).
    private func shutDownAndTerminate(_ model: AppModel) -> NSApplication.TerminateReply {
        terminationInProgress = true
        Task { @MainActor in
            // 검토 레인의 실행도 앱이 띄운 프로세스다. 함께 거둔다.
            let runnerCleaned = await model.runner.shutdownForQuit()
            let lanesCleaned = await model.reviewLanes.shutdownForQuit()
            let cleaned = runnerCleaned && lanesCleaned
            if !cleaned, !Self.confirm(QuitConfirmation.cleanupUnconfirmed, style: .critical) {
                self.terminationInProgress = false
                model.resumeHandoffsAfterCancelledQuit()
                // 실행들은 앱 종료로 끝났다 (완료 통지 없이). 앱이 계속 도니 그 뒷정리를 한다 — 새 일은 시작하지 않는다.
                model.reconcileCancelledQuit()
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
            // 끊긴 인계 전달이 전달됨이면 칩을 받는 쪽으로 (다시 켜면 옛 에이전트로 이어지지 않게).
            await model.recordQuitDeliveriesBeforeExit()
            // 보내는 중이던 메시지는 입력창으로, 인계 카드의 덧붙일 말로 옮겼던 메시지는 대기열로 (chr-9 · hand-2).
            await model.saveBeforeQuit()
            // 종료가 확정됐다 — 앱이 띄운 셸도 거둔다 (에이전트 프로세스와 같은 원칙).
            ShellTerminalStore.shared.shutdownAll()
            await model.store.db.close()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
