import SwiftUI
import AppKit

/// 248pt 사이드바. 프로젝트는 마지막으로 쓴 순서, 2주 넘게 쉰 프로젝트는 맨 아래 "이전 프로젝트 N개" 한 줄 안에. 프로젝트 이름 아래
/// 대화가 한 줄씩(처음엔 3개, "더보기" 로 전부 · 이름을 누르면 통째로 접기), 머리의 ＋ · ⋯ 는 포인터를 올렸을 때만 — 선택된 행은
/// 옅은 채움뿐이고 브랜치 · PR 은 툴바와 인스펙터가 보인다.
/// 무엇을 그릴지(순서 · 이전 프로젝트 · 접기 · 더보기 · 검색 · 같은 이름의 프로젝트 · 대화 이름)는 `SidebarRules` 가 정한다.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool
    @State private var renameTarget: ConversationThread?
    @State private var renamedTitle = ""
    @State private var renameProjectTarget: Project?
    @State private var renamedProjectName = ""
    /// 스레드를 통째로 접은 프로젝트. 창을 닫아도 남는다 (쉼표로 이은 ID).
    @AppStorage("sidebar.collapsedProjects") private var collapsedStore = ""
    /// 맨 아래 "이전 프로젝트 N개" 묶음을 폈는가 (`SidebarRules.sections`).
    @AppStorage("sidebar.idleExpanded") private var idleExpanded = false
    /// 이전 프로젝트 가운데 대화 목록을 편 것 — 이전 프로젝트는 처음엔 이름 · 대화 수만 보인다 (쉼표로 이은 ID).
    @AppStorage("sidebar.openedIdleProjects") private var openedIdleStore = ""
    @State private var hovered: String?
    /// 포인터가 올라간 프로젝트 머리 — 그 머리에만 ＋ · ⋯ 를 보인다 (평소엔 이름이 그 자리까지 쓴다).
    @State private var hoveredProject: String?
    /// 삭제를 확인할 대화 (독립 작업 폴더가 있는 대화만 묻는다 — 그 폴더도 지운다).
    @State private var deleteTarget: ConversationThread?
    /// "독립 작업 폴더로 옮기기" 를 확인할 대화 — 무엇이 따라오지 않는지 먼저 보인다 (chg-6).
    @State private var moveTarget: ConversationThread?
    @State private var removeProjectTarget: Project?
    /// 프로젝트 설정 시트 (프로젝트 메뉴 > "프로젝트 설정…").
    @State private var settingsProject: Project?
    /// 가운데 칸 (대화 · 에이전트 기록) — 창 상태 값이라 `ContentView` 와 같은 키를 직접 바꾼다. 기록을 보다가 대화를 고르면 대화로.
    @AppStorage(WindowStateKey.pane) private var pane: WindowPane = .conversation

    private var collapsedProjects: Set<String> {
        Set(collapsedStore.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    private var openedIdleProjects: Set<String> {
        Set(openedIdleStore.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    /// 이 프로젝트의 대화 목록이 접혀 있는가 (검색은 따로 본다). 이전 프로젝트는 펴 둔 것만 펴져 있다.
    private func isCollapsed(_ id: String, idle: Bool) -> Bool {
        idle ? !openedIdleProjects.contains(id) : collapsedProjects.contains(id)
    }

    private func toggleCollapsed(_ id: String, idle: Bool) {
        if idle {
            var set = openedIdleProjects
            if set.contains(id) { set.remove(id) } else { set.insert(id) }
            openedIdleStore = set.sorted().joined(separator: ",")
        } else {
            var set = collapsedProjects
            if set.contains(id) { set.remove(id) } else { set.insert(id) }
            collapsedStore = set.sorted().joined(separator: ",")
        }
    }

    private var searchText: String { model.sidebarSearchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 그릴 프로젝트의 순서와 묶음 — 최근 순, 오래 쉰 것은 "이전 프로젝트" (`SidebarRules.sections`). 검색 중이면 맞는 대화가 있는
    /// 프로젝트만, 묶지 않고.
    private var sections: SidebarRules.Sections {
        let projects = model.projects.filter { searchText.isEmpty || hasMatches($0) }
        return SidebarRules.sections(projects, threadsByProject: model.threadsByProject, now: Date(),
                                     searching: !searchText.isEmpty, pinned: isPinned)
    }

    /// 목록에 실제로 그리는 활성 대화 (`SidebarRules.visible`) — 접힌 프로젝트는 하나도 없고, "더보기" 뒤여도 선택 · 실행 중 ·
    /// 답을 기다리는 · 분할 화면의 칸에 열린 대화는 보인다 (상태가 숨지 않게).
    private func visibleActive(_ active: [ConversationThread], projectID: String, idle: Bool) -> [ConversationThread] {
        SidebarRules.visible(active, searching: !searchText.isEmpty, collapsed: isCollapsed(projectID, idle: idle),
                             expanded: model.sidebarExpandedProjects.contains(projectID), pinned: isPinned)
    }

    /// 더보기에 숨지 않는 대화 (접힌 프로젝트에서는 이것도 숨는다).
    private func isPinned(_ thread: ConversationThread) -> Bool {
        thread.id == model.selectedThreadID || model.paneThreadIDs.contains(thread.id) || !activity(thread).isIdle
    }

    // MARK: 행 상태

    private typealias RowActivity = SidebarRowActivity

    private func activity(_ thread: ConversationThread) -> RowActivity {
        let input = model.paneStatusInput(for: thread)
        let status = PaneStatus.make(input)
        // 카운트다운(자동 인계 · 다른 계정에서 이어 가기)은 답을 꼭 받아야 하는 것은 아니지만, 취소할 수 있게 같은 모양으로 보인다.
        if let status, status.needsResponse || input.countingDown { return .attention(status) }
        guard input.runState?.isActive == true else { return .idle }
        let provider = model.runner.session(threadID: thread.id)?.activeProvider ?? thread.preferredProvider
        return .running(provider: provider, status: status)
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            SearchField(placeholder: SidebarRules.searchPlaceholder, text: $model.sidebarSearchText,
                        shortcut: MenuShortcut.threadSearch.symbol, plain: true, focus: $searchFocused)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)

            // 현황 ↔ 대화 (보기 메뉴 ⌃⌘0 · 툴바 ⋯ 와 같다). 답을 기다리는 수는 황색 점과, 실행 수는 회색으로.
            OverviewSidebarRow(selected: WindowPane.shown(stored: pane, reviewing: model.diffWideActive) == .overview) {
                if model.diffWideActive { model.closeDiff() }
                pane = WindowPane.togglingOverview(shown: WindowPane.shown(stored: pane, reviewing: model.diffWideActive))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let sections = self.sections
                    ForEach(Array(sections.recent.enumerated()), id: \.element.id) { index, project in
                        projectSection(project, isFirst: index == 0, idle: false)
                    }
                    if !sections.idle.isEmpty {
                        idleGroupRow(count: sections.idle.count)
                        if idleExpanded {
                            ForEach(sections.idle) { project in projectSection(project, isFirst: false, idle: true) }
                        }
                    }
                    if !searchText.isEmpty && sections.recent.isEmpty && !model.projects.isEmpty {
                        Text(SidebarRules.noMatchText)
                            .font(Theme.ui(.caption))
                            .foregroundStyle(Theme.slate2)
                            .padding(.horizontal, 6)
                            .padding(.top, 14)
                    }
                    // 첫 실행 점검표가 보이면 그 ③ "작업할 폴더" 가 같은 일을 말한다 — 두 번 말하지 않는다.
                    if model.projects.isEmpty && !model.showsFirstRun {
                        Text("프로젝트 폴더를 열면 대화를 시작할 수 있습니다.")
                            .font(Theme.ui(.caption))
                            .foregroundStyle(Theme.slate2)
                            .padding(.horizontal, 6)
                            .padding(.top, 14)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { moveSelection(by: 1) }
            .onKeyPress(.upArrow) { moveSelection(by: -1) }
            // 목록에 키보드 포커스가 있을 때 ⌫ · ⌦ — 선택된 대화를 지운다 (확인 창은 그대로 뜬다).
            .onDeleteCommand {
                if let thread = model.selectedThread, !thread.isInternal { requestDelete(thread) }
            }

            footer
        }
        .background(Theme.panel)
        // ⌥⌘F — 숨어 있던 사이드바는 나타나면서, 보이던 사이드바는 곧바로 검색칸으로. 새로 만든 대화의 접힌 프로젝트도 같은 식으로 편다.
        .onAppear {
            takeSearchFocusIfRequested()
            revealCreatedConversations()
        }
        .onChange(of: model.sidebarSearchFocusRequestedAt) { _, requested in
            if requested != nil { takeSearchFocusIfRequested() }
        }
        .onChange(of: model.sidebarRevealProjectIDs) { _, ids in
            if !ids.isEmpty { revealCreatedConversations() }
        }
        .alert("대화 이름 변경", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })) {
            TextField("이름", text: $renamedTitle)
            Button("취소", role: .cancel) { renameTarget = nil }
            Button("저장") {
                guard var thread = renameTarget else { return }
                let value = renamedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { thread.title = value }
                renameTarget = nil
                Task { await model.updateThread(thread) }
            }
        } message: {
            Text("목록에서 알아보기 쉬운 이름을 붙이세요.")
        }
        .alert("프로젝트 이름 변경", isPresented: Binding(
            get: { renameProjectTarget != nil },
            set: { if !$0 { renameProjectTarget = nil } })) {
            TextField("이름", text: $renamedProjectName)
            Button("취소", role: .cancel) { renameProjectTarget = nil }
            Button("저장") {
                guard let project = renameProjectTarget else { return }
                let name = renamedProjectName
                renameProjectTarget = nil
                Task { await model.renameProject(project, to: name) }
            }
        } message: {
            Text("사이드바 · 칸 머리에 보이는 이름입니다. 폴더 이름은 바뀌지 않습니다 — 비워 두면 폴더 이름으로 돌아갑니다.")
        }
        .confirmationDialog(deleteTarget?.worktree != nil ? "대화와 독립 작업 폴더를 지울까요?" : "대화를 지울까요?",
                            isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible, presenting: deleteTarget) { thread in
            Button(thread.worktree != nil ? "대화와 독립 작업 폴더 삭제" : "대화 삭제", role: .destructive) {
                deleteTarget = nil
                Task { await model.deleteThread(thread) }
            }
            Button("취소", role: .cancel) { deleteTarget = nil }
        } message: { thread in
            Text(deleteMessage(thread))
        }
        .confirmationDialog("이 대화를 독립 작업 폴더로 옮길까요?", isPresented: Binding(
            get: { moveTarget != nil },
            set: { if !$0 { moveTarget = nil } }), titleVisibility: .visible, presenting: moveTarget) { thread in
            Button("독립 작업 폴더로 옮기기") {
                moveTarget = nil
                Task { await model.createWorktree(threadID: thread.id) }
            }
            Button("취소", role: .cancel) { moveTarget = nil }
        } message: { thread in
            Text(model.worktreeMoveNotice(for: thread).joined(separator: "\n"))
        }
        .confirmationDialog("프로젝트를 앱에서 뺄까요?", isPresented: Binding(
            get: { removeProjectTarget != nil },
            set: { if !$0 { removeProjectTarget = nil } }), titleVisibility: .visible, presenting: removeProjectTarget) { project in
            Button("프로젝트 제거", role: .destructive) {
                removeProjectTarget = nil
                Task { await model.removeProject(project) }
            }
            Button("취소", role: .cancel) { removeProjectTarget = nil }
        } message: { project in
            Text(removeProjectMessage(project))
        }
        .sheet(item: $settingsProject) { project in
            ProjectSettingsSheet(project: project).environment(model)
        }
        .task {
            #if DEBUG
            // 화면 확인용 (AHC_OFFLINE=1): `-preview.projectSettings YES` — 선택된 대화의 프로젝트 설정 시트를 연다.
            if AppModel.offlinePreview, UserDefaults.standard.bool(forKey: "preview.projectSettings") {
                for _ in 0..<30 where model.projects.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
                let id = model.selectedThread?.projectID
                settingsProject = model.projects.first { $0.id == id } ?? model.projects.first
            }
            #endif
        }
    }

    /// ⌥⌘F 요청이 있으면 검색칸으로 (사이드바가 막 나타났으면 칸이 놓인 다음 차례에).
    private func takeSearchFocusIfRequested() {
        guard model.consumeSidebarSearchFocus() else { return }
        DispatchQueue.main.async { searchFocused = true }
    }

    /// 검색 중일 때 이 프로젝트에 맞는 대화가 있는가 (없으면 그 프로젝트 머리를 그리지 않는다).
    private func hasMatches(_ project: Project) -> Bool {
        (model.threadsByProject[project.id] ?? []).contains { SidebarRules.matches($0, query: searchText) }
    }

    /// 대화를 지우기 전: 실행 · 자동 작업이 돌면 까닭만 알리고(그 실행을 멈추는 단추와 함께), 작업 폴더가 있으면 상태를 먼저 읽어
    /// 사라질 것을 확인 창에 보인다.
    private func requestDelete(_ thread: ConversationThread) {
        if let block = model.deletionBlockBanner(threadIDs: [thread.id], prefix: "지우지 않았습니다") {
            model.banner = block
            return
        }
        Task {
            if thread.worktree != nil { await model.refreshWorktreeStatus(threadID: thread.id) }
            deleteTarget = thread
        }
    }

    /// 옮기기 확인 창을 열기 전에 프로젝트 폴더의 상태를 다시 읽는다 (확인 창의 "커밋하지 않은 변경 n개" 가 지금 것이게).
    private func requestMove(_ thread: ConversationThread) {
        Task {
            if let path = model.mainProject(for: thread)?.path { await model.workspace(forPath: path)?.refreshGit() }
            moveTarget = thread
        }
    }

    private func requestRemove(_ project: Project) {
        let threadIDs = (model.threadsByProject[project.id] ?? []).map(\.id)
            + model.internalThreadsByID.values.filter { $0.projectID == project.id }.map(\.id)
        if let block = model.deletionBlockBanner(threadIDs: threadIDs, prefix: "프로젝트를 빼지 않았습니다") {
            model.banner = block
            return
        }
        removeProjectTarget = project
    }

    private func deleteMessage(_ thread: ConversationThread) -> String {
        let record = "이 대화의 메시지 · 실행 · 인계 기록을 앱에서 지웁니다. 되돌릴 수 없습니다."
        guard let worktree = thread.worktree else {
            return record + "\n프로젝트 폴더의 파일은 그대로입니다."
        }
        var lines = [record, "이 대화의 독립 작업 폴더(\(worktree.path))를 지웁니다. 프로젝트 폴더의 파일은 그대로입니다."]
        if let status = model.worktreeStatuses[thread.id] {
            if let uncommitted = status.uncommitted, uncommitted > 0 {
                lines.append("커밋하지 않은 변경 \(uncommitted)개가 사라집니다.")
            }
            if let ahead = status.ahead, ahead > 0 {
                lines.append("합치지 않은 커밋 \(ahead)개는 브랜치 \(worktree.branch) 에 남깁니다.")
            } else {
                lines.append("브랜치(\(worktree.branch))는 합쳐졌으면 함께 지웁니다.")
            }
            if let stranded = status.strandedCommits, stranded > 0 {
                lines.append("브랜치에 없는 커밋 \(stranded)개(detached HEAD)는 새 브랜치 \(worktree.branch)-saved 에 남깁니다.")
            }
        } else {
            lines.append("독립 작업 폴더의 상태를 읽지 못했습니다 — 커밋하지 않은 변경이 있으면 지우지 않고 그대로 둡니다.")
        }
        return lines.joined(separator: "\n")
    }

    private func removeProjectMessage(_ project: Project) -> String {
        let count = model.threadsByProject[project.id]?.count ?? 0
        guard count > 0 else { return "목록에서만 뺍니다. 폴더의 파일은 그대로입니다 — \(project.path)" }
        return "대화 \(count)개와 그 기록(메시지 · 실행 · 인계)을 앱에서 지웁니다. 되돌릴 수 없습니다.\n"
            + "폴더의 파일은 그대로입니다 — \(project.path)\n"
            + "독립 작업 폴더는 커밋하지 않은 변경이 없는 것만 지웁니다."
    }

    // MARK: 프로젝트

    /// 프로젝트 하나 — 머리와 대화 목록. `idle` 이면 "이전 프로젝트" 안의 것 (처음엔 접혀 이름 · 대화 수만).
    @ViewBuilder
    private func projectSection(_ project: Project, isFirst: Bool, idle: Bool) -> some View {
        let threads = model.threadsByProject[project.id] ?? []
        let active = threads.filter { !$0.archived && SidebarRules.matches($0, query: searchText) }
        let archived = threads.filter { $0.archived && SidebarRules.matches($0, query: searchText) }
        let collapsed = isCollapsed(project.id, idle: idle) && searchText.isEmpty
        let shown = visibleActive(active, projectID: project.id, idle: idle)
        let name = model.projectDisplayName(project)
        let headerHovered = hoveredProject == project.id

        HStack(spacing: 2) {
            // 이름을 누르면 대화를 통째로 접고 편다 (접으면 모두 숨는다 — 수는 머리에). 검색 중에는 접지 않는다.
            Button {
                toggleCollapsed(project.id, idle: idle)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.control)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                    Text(name)
                        .font(Theme.ui(.callout, .semibold))
                        .foregroundStyle(idle ? Theme.slate : Theme.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // 접혀 숨은 대화 수.
                    if collapsed && active.count > shown.count {
                        Text("\(active.count - shown.count)")
                            .font(Theme.ui(.caption))
                            .foregroundStyle(Theme.slate2)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(project.path + (collapsed ? "\n눌러서 대화 목록 펴기" : "\n눌러서 대화 목록 접기 (선택 · 실행 중인 대화는 남습니다)"))
            .accessibilityLabel(name)
            .accessibilityValue(collapsed ? "접힘" : "펼침")
            .accessibilityHint(collapsed ? "대화 목록을 폅니다" : "대화 목록을 접습니다")
            .accessibilityAction(named: "새 대화") { startNewConversation(in: project) }
            Spacer(minLength: 0)
        }
        .frame(height: 21)
        // ＋ · ⋯ 는 포인터를 올린 머리에만 — 평소엔 이름이 그 자리까지 쓴다. 같은 메뉴는 오른쪽 클릭으로도 (키보드 · VoiceOver 는
        // 머리의 "새 대화" 동작과 메뉴).
        .overlay(alignment: .trailing) {
            if headerHovered {
                HStack(spacing: 2) {
                    IconButton(systemName: "plus", size: 11, color: Theme.control,
                               help: "\(name) 에 새 대화 (\(MenuShortcut.newThread.symbol))") {
                        startNewConversation(in: project)
                    }
                    Menu {
                        projectMenuItems(project)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.control)
                            .frame(width: 21, height: 21)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("프로젝트 메뉴")
                    .accessibilityLabel("\(name) 프로젝트 메뉴")
                }
                .padding(.leading, 6)
                .background(Theme.panel)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hoveredProject = inside ? project.id : (hoveredProject == project.id ? nil : hoveredProject)
        }
        .contextMenu { projectMenuItems(project) }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .padding(.top, idle ? 3 : (isFirst ? 8 : 14))
        .padding(.bottom, 3)

        ForEach(shown) { thread in threadRow(thread) }

        if !collapsed, searchText.isEmpty, shown.count < active.count {
            let hidden = active.count - shown.count
            moreRow(title: "더보기 \(hidden)개", expanded: false) { model.sidebarExpandedProjects.insert(project.id) }
        } else if !collapsed, searchText.isEmpty, model.sidebarExpandedProjects.contains(project.id),
                  active.count > SidebarRules.visibleLimit {
            moreRow(title: "접기", expanded: true) { model.sidebarExpandedProjects.remove(project.id) }
        }

        if active.isEmpty && searchText.isEmpty && !collapsed {
            Text("＋ 로 대화를 추가하세요")
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate2)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        }

        if !archived.isEmpty && !collapsed {
            let expanded = model.sidebarExpandedArchives.contains(project.id) || !searchText.isEmpty
            Button {
                if model.sidebarExpandedArchives.contains(project.id) {
                    model.sidebarExpandedArchives.remove(project.id)
                } else {
                    model.sidebarExpandedArchives.insert(project.id)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.control)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                    Text("보관됨 \(archived.count)")
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate2)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(archived) { thread in threadRow(thread) }
            }
        }
    }

    /// 프로젝트 메뉴의 항목 — 머리의 ⋯ 와 오른쪽 클릭이 같이 쓴다.
    @ViewBuilder
    private func projectMenuItems(_ project: Project) -> some View {
        Button("새 대화") { startNewConversation(in: project) }
        // 저장소가 아니거나 첫 커밋이 없으면 만들 수 없다 — 까닭을 항목에 붙여 끈다 (메뉴 항목은 도움말이 뜨지 않는다, chg-14).
        let worktreeBlock = AppModel.repositoryCreationShortBlock(model.workspace(forPath: project.path)?.git)
        Button("독립 작업 폴더에서 새 대화" + (worktreeBlock.map { " — \($0)" } ?? "")) {
            Task { await model.addThreadWithWorktree(projectID: project.id) }
        }
        .disabled(worktreeBlock != nil)
        .help("이 대화만의 git worktree 를 만들어 거기서 일합니다 — 같은 프로젝트의 다른 대화와 파일이 섞이지 않습니다.")
        Button("Finder 에서 열기") { NSWorkspace.shared.open(project.url) }
        Button("터미널에서 열기") { TerminalLauncher.open(project.url) }
        Divider()
        Button("이름 변경…") {
            renamedProjectName = project.name
            renameProjectTarget = project
        }
        Button("프로젝트 설정…") { settingsProject = project }
            .help("Antigravity 허용 · 인계 문서의 Gemini 전송 · 독립 작업 폴더 준비 명령")
        Divider()
        Button("프로젝트 제거", role: .destructive) { requestRemove(project) }
    }

    /// 맨 아래 "이전 프로젝트 N개" — 오래 쉰 프로젝트의 묶음 (`SidebarRules.sections`). 누르면 그 프로젝트들의 머리(이름 · 대화 수)를
    /// 펴고 접는다.
    private func idleGroupRow(count: Int) -> some View {
        Button {
            idleExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.control)
                    .rotationEffect(.degrees(idleExpanded ? 0 : -90))
                Text(SidebarRules.idleGroupTitle(count: count))
                    .font(Theme.ui(.callout, .semibold))
                    .foregroundStyle(Theme.slate)
                Spacer(minLength: 4)
                Text(SidebarRules.idleNote)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate2)
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 14)
        .help(SidebarRules.idleHelp)
        .accessibilityLabel(SidebarRules.idleGroupTitle(count: count))
        .accessibilityValue(idleExpanded ? "펼침" : "접힘")
        .accessibilityHint(idleExpanded ? "이전 프로젝트를 접습니다" : "이전 프로젝트를 폅니다")
    }

    /// "더보기 N개" · "접기" 행 — 보관됨 행과 같은 생김새.
    /// "⌄ 더보기 N개" · "⌃ 접기" — 앱의 다른 펼치기 줄(긴 출력의 "전체 보기" · "접기")과 같은 꺾쇠.
    private func moreRow(title: String, expanded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.control)
                    .frame(width: 12)
                Text(title)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate2)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 대화 행

    /// 한 줄: 로고(실행 중이면 로고를 감싼 도는 링 · 답을 기다리면 황색 점) · 제목 · (기다리는 것). 선택은 옅은 채움뿐 —
    /// 카드 · 테두리 · 그림자를 두지 않는다. 포인터를 올리면 오른쪽에 ⋯ (오른쪽 클릭과 같은 메뉴), 두 번 누르면 이름 변경.
    /// 줄의 모양은 `SidebarThreadRowLabel` (한 식이 커지면 컴파일러가 타입을 정하지 못했다).
    private func threadRow(_ thread: ConversationThread) -> some View {
        let selected: Bool = thread.id == model.selectedThreadID
        let openElsewhere: Bool = !selected && model.paneThreadIDs.contains(thread.id)
        let activity: RowActivity = activity(thread)
        let isHovered: Bool = hovered == thread.id
        let label = SidebarThreadRowLabel(thread: thread, selected: selected, openElsewhere: openElsewhere, hovered: isHovered,
                                          activity: activity, countdown: countdown(thread.id))
        return Button { open(thread) } label: { label }
            .buttonStyle(.plain)
            // 잘린 긴 제목도 읽을 수 있게.
            .help(SidebarRules.displayTitle(thread))
            // 두 번 누르면 이름 변경 (위에 겹친 ⋯ 단추는 빼고).
            .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename(thread) })
            .overlay(alignment: .trailing) { rowMenuButton(thread, visible: isHovered) }
            .onHover { inside in hovered = inside ? thread.id : (hovered == thread.id ? nil : hovered) }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel(rowAccessibilityLabel(thread, openElsewhere: openElsewhere, activity: activity))
            .accessibilityAction(named: "이름 변경") { beginRename(thread) }
            .accessibilityAction(named: "삭제") { requestDelete(thread) }
            .contextMenu { threadMenuItems(thread) }
    }

    private func open(_ thread: ConversationThread) {
        if pane == .scoreboard || pane == .overview { pane = .conversation }
        Task { await model.selectThread(thread.id) }
    }

    /// 그 대화에서 도는 카운트다운 — 자동 인계(인계 카드) 또는 다른 계정에서 같은 세션을 이어 가기 (`codexSwitchCountdowns`).
    private func countdown(_ threadID: String) -> SidebarRowCountdown? {
        if case .countingDown(let deadline, _)? = model.handoffCards[threadID]?.phase { return .handoff(deadline) }
        if let countdown = model.codexSwitchCountdowns[threadID] { return .codexSwitch(countdown.deadline) }
        return nil
    }

    /// 포인터를 올린 행의 ⋯ (오른쪽 클릭과 같은 메뉴).
    @ViewBuilder
    private func rowMenuButton(_ thread: ConversationThread, visible: Bool) -> some View {
        if visible {
            Menu { threadMenuItems(thread) } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.control)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.trailing, 4)
            .help("대화 메뉴 — 이름 변경 · 보관 · 삭제 · 새 칸에서 열기")
            .accessibilityLabel("\(SidebarRules.displayTitle(thread)) 대화 메뉴")
        }
    }

    private func rowAccessibilityLabel(_ thread: ConversationThread, openElsewhere: Bool, activity: RowActivity) -> String {
        var parts: [String] = [SidebarRules.displayTitle(thread), thread.preferredProvider.displayName]
        if thread.worktree != nil { parts.append("독립 작업 폴더") }
        if openElsewhere { parts.append(SidebarRules.openElsewhereLabel) }
        if let text = activityText(activity) { parts.append(text) }
        return parts.joined(separator: ", ")
    }

    /// 행의 오른쪽 클릭 메뉴와 ⋯ 메뉴의 항목.
    @ViewBuilder
    private func threadMenuItems(_ thread: ConversationThread) -> some View {
        Button(model.panes.newPaneMenuTitle(for: thread.id)) {
            if pane == .scoreboard || pane == .overview { pane = .conversation }
            Task { await model.openInNewPane(thread.id) }
        }
        .disabled(model.panes.newPaneBlock(for: thread.id) != nil)
        Divider()
        Button("이름 변경…") { beginRename(thread) }
        Button(thread.archived ? "보관 해제" : "보관") {
            var updated = thread
            updated.archived.toggle()
            Task { await model.updateThread(updated) }
        }
        Divider()
        if let worktree = thread.worktree {
            Button("독립 작업 폴더를 Finder 에서 열기") { NSWorkspace.shared.open(URL(fileURLWithPath: worktree.path)) }
            Button("독립 작업 폴더를 터미널에서 열기") { TerminalLauncher.open(URL(fileURLWithPath: worktree.path)) }
        } else {
            // 옮기기 전에 무엇이 따라오지 않는지(커밋 안 한 변경 · .env · node_modules) 확인 창으로 보인다 (chg-6).
            Button("독립 작업 폴더로 옮기기…") { requestMove(thread) }
                .disabled(model.worktreeCreationBlock(thread) != nil)
        }
        Divider()
        Button("대화 삭제…", role: .destructive) { requestDelete(thread) }
    }

    private func beginRename(_ thread: ConversationThread) {
        renamedTitle = SidebarRules.displayTitle(thread)
        renameTarget = thread
    }

    private func activityText(_ activity: RowActivity) -> String? {
        switch activity {
        case .attention(let status): return status.text
        case .running(_, let status): return status?.text ?? "실행 중"
        case .idle: return nil
        }
    }

    // MARK: 하단

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                chooseProjectFolder()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.slate2)
                        .frame(width: 12)
                    Text("프로젝트 폴더")
                        .font(Theme.ui(.callout))
                        .foregroundStyle(Theme.slate)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("에이전트가 작업할 프로젝트 폴더를 등록합니다 (\(MenuShortcut.openProjectFolder.symbol))")
            .accessibilityLabel("프로젝트 폴더 열기")

            // 에이전트 기록 ↔ 대화 (보기 메뉴 ⇧⌘B · 툴바 ⋯ 와 같다). 기록을 보는 중이면 잉크색.
            let shown = WindowPane.shown(stored: pane, reviewing: model.diffWideActive)
            Button {
                if model.diffWideActive { model.closeDiff() }
                pane = WindowPane.togglingScoreboard(shown: shown)
            } label: {
                Image(systemName: "chart.bar")
                    .font(.system(size: 11.5))
                    .foregroundStyle(shown == .scoreboard ? Theme.ink : Theme.slate2)
                    .frame(width: 21, height: 21)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(WindowPane.scoreboardToggleTitle(shown: shown) + " (\(MenuShortcut.scoreboard.symbol))"
                  + (shown == .scoreboard ? "" : " — 에이전트마다 실행 · 사용량 · 평가를 모아 봅니다"))
            .accessibilityLabel(WindowPane.scoreboardToggleTitle(shown: shown))

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate2)
                    .frame(width: 21, height: 21)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("설정 (⌘,)")
            .accessibilityLabel("설정")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
    }

    // MARK: 동작

    /// 새 대화 (＋ · 프로젝트 메뉴) — 기록이 없는 빈 "새 대화" 가 있으면 그것을 연다 (`AppModel.startNewConversation`).
    /// 접혀 있었으면 앱 모델의 알림으로 편다 (`revealCreatedConversations`).
    private func startNewConversation(in project: Project) {
        Task { await model.startNewConversation(projectID: project.id) }
    }

    /// 사람이 방금 대화를 새로 만든 프로젝트를 편다 — 어느 길로 만들었든(⌘N · ＋ · 프로젝트 메뉴 · 빈 칸 · 독립 작업 폴더 · 폴더 열기)
    /// 앱 모델이 알린다 (`AppModel.sidebarRevealProjectIDs`). 사이드바가 숨어 있던 동안 만든 것은 나타날 때 받는다.
    private func revealCreatedConversations() {
        for id in model.takeSidebarReveals() { expand(id) }
    }

    /// 접힌 프로젝트를 편다 — 거기서 새 대화를 만들면 목록에 보이게 (접힌 프로젝트는 대화를 하나도 그리지 않는다).
    private func expand(_ id: String) {
        if collapsedProjects.contains(id) {
            collapsedStore = collapsedProjects.subtracting([id]).sorted().joined(separator: ",")
        }
        if !openedIdleProjects.contains(id) {
            openedIdleStore = openedIdleProjects.union([id]).sorted().joined(separator: ",")
        }
    }

    /// 보이는 순서대로 위·아래 대화로 이동한다 (최근 순 · 접힌 "이전 프로젝트" 는 건너뛴다 — 그리는 순서와 같게).
    private func moveSelection(by offset: Int) -> KeyPress.Result {
        let sections = self.sections
        let drawn = sections.recent.map { ($0, false) } + (idleExpanded ? sections.idle.map { ($0, true) } : [])
        let visible = drawn.flatMap { entry -> [ConversationThread] in
            let (project, idle) = entry
            let threads = model.threadsByProject[project.id] ?? []
            var out = visibleActive(threads.filter { !$0.archived && SidebarRules.matches($0, query: searchText) },
                                    projectID: project.id, idle: idle)
            if (model.sidebarExpandedArchives.contains(project.id) || !searchText.isEmpty)
                && !(isCollapsed(project.id, idle: idle) && searchText.isEmpty) {
                out += threads.filter { $0.archived && SidebarRules.matches($0, query: searchText) }
            }
            return out
        }
        guard !visible.isEmpty else { return .ignored }
        let current = visible.firstIndex { $0.id == model.selectedThreadID } ?? (offset > 0 ? -1 : visible.count)
        let next = min(max(current + offset, 0), visible.count - 1)
        guard visible[next].id != model.selectedThreadID else { return .handled }
        if pane == .scoreboard || pane == .overview { pane = .conversation }
        Task { await model.selectThread(visible[next].id) }
        return .handled
    }

    /// 폴더 고르기는 파일 메뉴 · 점검표와 같은 도우미 (`ProjectFolderPicker` — 같은 폴더면 그 프로젝트, 새 폴더면 첫 대화까지).
    private func chooseProjectFolder() {
        Task { await ProjectFolderPicker.chooseAndOpen(model: model) }
    }
}

/// 행 앞자리의 모양 — 실행 중이면 로고를 도는 링이 감싸고(제공자 색 + 로고 모양), 황색 점(+ 오른쪽 짧은 글)이면 사람의 답을 기다린다.
/// 판정 · 문구는 칸 머리 · 툴바 "응답 필요" 와 같은 `PaneStatus` 다.
fileprivate enum SidebarRowActivity {
    case idle
    case running(provider: AgentProvider, status: PaneStatus?)
    case attention(PaneStatus)

    var isIdle: Bool { if case .idle = self { return true } else { return false } }
}

/// 행 오른쪽에서 초를 세는 카운트다운 — 모양은 같고(황색 캡슐 · 레이어 시계) 글만 다르다.
fileprivate enum SidebarRowCountdown {
    /// 자동 인계 (인계 카드의 카운트다운) — "⇄ 9초".
    case handoff(Date)
    /// 다른 계정에서 같은 세션을 이어 가기 (인계가 아니다 — `CodexAccountSwitch`) — "계정 9초".
    case codexSwitch(Date)
}

/// 사이드바 대화 행의 모양 (단추의 label). 무엇을 보일지는 `SidebarView.threadRow` 가 정해 넘긴다.
private struct SidebarThreadRowLabel: View {
    let thread: ConversationThread
    let selected: Bool
    /// 분할 화면의 다른 칸에 열려 있다.
    let openElsewhere: Bool
    let hovered: Bool
    let activity: SidebarRowActivity
    /// 도는 카운트다운 (돌 때만).
    let countdown: SidebarRowCountdown?

    var body: some View {
        HStack(spacing: 8) {
            leading
                .frame(width: 12)
            Text(SidebarRules.displayTitle(thread))
                .font(Theme.ui(.callout, selected ? .medium : .regular))
                .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            trailingStatus
            if openElsewhere && !hovered {
                // 분할 화면의 다른 칸에 열려 있다 — 바탕색만으로 알리지 않는다.
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.slate2)
                    .help("분할 화면의 다른 칸에 열려 있습니다")
            }
            if let worktree = thread.worktree {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.slate2)
                    .help("독립 작업 폴더 · \(worktree.branch)\n\(worktree.path)")
            }
            // 포인터를 올리면 ⋯ 단추 자리를 비운다 (단추는 위에 겹쳐 놓인다).
            if hovered { Color.clear.frame(width: 16, height: 1) }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { background }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leading: some View {
        switch activity {
        case .attention(let status):
            Circle().fill(Theme.amber).frame(width: 7, height: 7)
                .help(status.help)
        case .running(let provider, let status):
            RunningMark(provider: provider)
                .help(status?.text ?? "실행 중")
        case .idle:
            BrandMark(provider: thread.preferredProvider, size: 11, opacity: selected ? 1 : 0.6)
        }
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if case .attention(let status) = activity {
            // 카운트다운 — 수만 레이어가 1초마다 바꾼다 (SwiftUI 를 다시 그리지 않는다). 접근성 이름은 고정 (초마다 읽지 않는다).
            switch countdown {
            case .handoff(let deadline)?:
                HandoffCountdownBadge(deadline: deadline)
                    .help(status.help)
            case .codexSwitch(let deadline)?:
                CodexSwitchCountdownBadge(deadline: deadline)
                    .help(status.help)
            case nil:
                Text(status.shortText)
                    .font(Theme.ui(.caption, .semibold))
                    .foregroundStyle(Theme.amberText)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Theme.approvalWell, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.approvalBorder))
                    .help(status.help)
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        if selected {
            RoundedRectangle(cornerRadius: 6).fill(Theme.well)
        } else if openElsewhere {
            // 분할 화면의 다른 칸에 열려 있다 (포커스 칸보다 옅게 — 오른쪽 칸 표시가 함께 붙는다).
            RoundedRectangle(cornerRadius: 6).fill(Theme.well.opacity(0.5))
        } else if hovered {
            RoundedRectangle(cornerRadius: 6).fill(Theme.well.opacity(0.55))
        }
    }
}

/// 실행 중인 대화의 행 앞자리: 제공자 로고를 그 색의 도는 링이 감싼다 — 색만이 아니라 로고 모양으로도 어느 에이전트인지 보인다
/// (Codex 의 잉크색 링은 글자색과 같아 색으로는 구분이 약했다). 링은 Core Animation 레이어로 돈다 (`SpinningLayer`).
private struct RunningMark: View {
    let provider: AgentProvider

    var body: some View {
        ZStack {
            SpinningLayer(content: .ring(color: Theme.brand(provider), lineWidth: 1.5, trim: 0.75), period: 1)
                .frame(width: 14, height: 14)
            BrandMark(provider: provider, size: 7)
        }
        .frame(width: 14, height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.displayName) 실행 중")
    }
}

/// 사이드바 행의 자동 인계 카운트다운 "⇄ 9초" — 수만 SwiftUI 밖에서 바꾼다 (`CountdownText` — 틱마다 창 전체를 다시 계산하지 않게,
/// 카드의 링과 같은 순간에 같은 수). 접근성 이름은 "자동 인계 대기" 로 고정한다 — 초마다 읽지 않는다.
struct HandoffCountdownBadge: View {
    let deadline: Date

    var body: some View {
        CountdownText(deadline: deadline, color: Theme.amberText) { "⇄ \($0)초" }
            .modifier(SidebarCountdownCapsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("자동 인계 대기")
    }
}

/// 사이드바 행의 다른 계정에서 이어 가기 카운트다운 "계정 9초" — 자동 인계의 배지와 같은 모양 · 같은 레이어 시계 (입력창 위 줄의 초와
/// 같은 순간에 같은 수). 인계가 아니라서 "⇄" 를 쓰지 않는다. 접근성 이름은 고정 (`CodexAccountSwitch.waitingText`).
struct CodexSwitchCountdownBadge: View {
    let deadline: Date

    var body: some View {
        CountdownText(deadline: deadline, color: Theme.amberText) { CodexAccountSwitch.badgeText(seconds: $0) }
            .modifier(SidebarCountdownCapsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(CodexAccountSwitch.waitingText)
    }
}

/// 행의 카운트다운 배지 바탕 — 답을 기다리는 행의 짧은 글과 같은 황색 캡슐.
private struct SidebarCountdownCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Theme.approvalWell, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.approvalBorder))
    }
}

/// 사용자 셸이 앱 안에 생기기 전까지, 작업 폴더를 macOS 터미널에서 연다.
enum TerminalLauncher {
    static func open(_ folder: URL) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([folder], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

/// 사이드바 맨 위 "현황" 행 — 누르면 가운데 칸이 현황 ↔ 대화. 답을 기다리는 수(황색 점)와 실행 수(회색)를 오른쪽에 (`Overview.sidebarBadge`).
private struct OverviewSidebarRow: View {
    @Environment(AppModel.self) private var model
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let counts = model.overviewCounts
        let badge = Overview.sidebarBadge(counts)
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(selected ? Theme.ink : Theme.slate2)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(WindowPane.overviewTitle)
                    .font(Theme.ui(.callout, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                Spacer(minLength: 4)
                if let waiting = badge.waiting {
                    HStack(spacing: 4) {
                        Circle().fill(Theme.amber).frame(width: 6, height: 6)
                        Text("\(waiting)").font(Theme.digits(.caption, .semibold)).foregroundStyle(Theme.amberText)
                    }
                }
                if let running = badge.running {
                    Text("실행 \(running)").font(Theme.digits(.caption)).foregroundStyle(Theme.slate2)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(selected ? Theme.well : (hovered ? Theme.wellSoft : Color.clear), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(Overview.sidebarHelp(counts) + " (\(MenuShortcut.overview.symbol))")
        .accessibilityLabel(Overview.sidebarHelp(counts))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
