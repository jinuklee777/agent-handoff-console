import AppKit
import SwiftUI

/// 변경사항 탭 (예전 브랜치 탭). 바뀐 파일 검토 → 커밋 → 업로드 순서로 읽힌다.
///
/// 위: 지금 위치 (프로젝트 · 브랜치 · 원격 · PR) / 가운데: 바뀐 파일 (체크 = 스테이지) /
/// 바닥 고정: 커밋 독 + 동기화 행. 한 화면에 잉크색 주 버튼은 하나 (`ChangesState.primary`).
/// 판정은 모두 `ChangesState`(비 UI, 오프라인 검증) 에 있고 이 파일은 그리기와 명령 호출만 한다.
///
/// 안전 규칙 (`GitWrite` · `AppModel.runGit`):
/// - 에이전트 실행 중이거나 종료가 확인되지 않은 프로세스가 있으면 쓰기(체크 · 커밋 · 업로드 · 전환 · fetch)를
///   잠근다. 목록은 그대로 볼 수 있다.
/// - 밖으로 나가는 push · pull 은 확인을 받는다. `--force` 는 없다.
/// - `reset --hard` · `clean` · 브랜치 삭제 같은 되돌리기 어려운 명령은 앱이 하지 않는다.
/// - git 을 주기적으로 읽지 않는다. 상대 시각 글자만 분 단위로 다시 그린다.
struct ChangesPane: View {
    @Environment(AppModel.self) private var model
    /// 포커스 대화에서 지금 도는 실행 (편집 중 표시의 색).
    private var focusedSession: RunSession? { model.selectedThreadID.flatMap { model.runner.session(threadID: $0) } }
    /// 다른 탭으로 옮길 때 (PR 상세 보기).
    var openTab: (InspectorTab) -> Void = { _ in }

    @State private var touched: [String: Set<AgentProvider>] = [:]
    @State private var editingNow: Set<String> = []
    @State private var selectedPath: String?
    @State private var pendingPath: String?
    @State private var query = ""
    /// ⌘⇧F 로 연 찾기 칸 (파일이 적어 원래는 숨어 있을 때).
    @State private var searchRequested = false
    @FocusState private var searchFocused: Bool
    @FocusState private var commitFocused: Bool
    /// 머리줄 브랜치 ▾ 팝오버 (목록 · 새 이름 입력). nil 이면 닫힘.
    @State private var branchMenu: BranchMenuRequest?
    /// 확인 창이 열린 동안 프로젝트나 브랜치가 바뀌었다 — 커밋 독 위에 한 번 안내한다 ("확인" 으로 닫음).
    @State private var targetChange: ChangesState.TargetChange?
    /// 업로드 · 받기 성공 표시가 끝날 때 한 번 올린다 (화면만 다시 그린다 — git 을 부르지 않는다).
    @State private var successTick = 0
    /// 업로드 · 게시 확인 팝오버.
    @State private var confirmingPush: GitWrite.Operation?
    /// 받기 확인 팝오버.
    @State private var confirmingPull = false
    /// 실패 안내의 "다시 시도" 확인 팝오버 (업로드 · 받기는 다시 확인을 거친다).
    @State private var confirmingRetry = false
    @State private var showingOutput = false
    @State private var showingFailureOutput = false
    @State private var showingMergeHowTo = false
    @State private var showingAbortHelp = false
    /// 충돌 파일을 "해결됨으로 표시" 하는 팝오버 (chg-11).
    @State private var showingResolve = false
    /// "이 폴더에서 git 시작하기" 확인 (chg-23).
    @State private var confirmingInit = false
    /// 목록 아래로 더 있는지 (바닥을 흐리게 해 독 아래로 이어진다는 것을 보인다).
    @State private var listHasMoreBelow = false
    /// "변경사항 검토" 칩으로 연 실행의 파일 (저장소 루트 기준). 목록 위로 올린다. nil 이면 평소 목록.
    /// 요청 · 폴더가 바뀔 때만 계산한다 (비교하지 못한 실행은 그 실행의 기록에서 편집 파일을 뽑는다).
    @State private var raisedPaths: Set<String>?

    private static let listTopID = "changes-list-top"

    /// 브랜치 메뉴를 여는 요청 (열 때마다 새 id — 새 이름 입력 상태로 다시 열어도 새 창으로 뜬다).
    struct BranchMenuRequest: Identifiable {
        let id = UUID()
        var mode: BranchMenu.Mode
        var query = ""
    }

    var body: some View {
        VStack(spacing: 0) {
            // 독립 작업 폴더에서 일하는 대화: 브랜치 · 합치기 · 정리 (파일 diff 를 보는 동안은 접는다).
            if let thread = model.selectedThread, let worktree = thread.worktree,
               !(model.workspace.git.map { $0.isRepository && narrowDiffRow($0) != nil } ?? false) {
                WorktreePanel(thread: thread, worktree: worktree)
            }
            if let git = model.workspace.git {
                if git.isRepository, let row = narrowDiffRow(git) {
                    // 파일 행을 누르면 목록 대신 그 파일의 diff (목업 Diff). 크게 보기 중에는 목록이 남는다.
                    diffPanel(git, row: row)
                } else if git.isRepository {
                    repository(git)
                } else {
                    notRepository(git)
                }
            } else {
                header(nil)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Git 상태를 읽는 중…").font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
                }
                .padding(20)
                Spacer(minLength: 0)
            }
        }
        .background {
            TouchedTracker(root: model.workspace.git?.rootPath ?? model.workspace.projectPath,
                           touched: $touched, editingNow: $editingNow)
        }
        .onChange(of: commitFocused) { _, focused in model.commitFieldFocused = focused }
        .onDisappear {
            model.commitFieldFocused = false
            // 올린 목록은 탭을 떠나면 푼다 (다시 오면 평소 순서).
            model.clearChangesReview()
            // 목록이 사라졌다 — 크게 보기의 이전 / 다음은 찾기로 걸러진 순서를 그대로 쓰지 않는다.
            model.markChangesListHidden()
        }
        .onAppear {
            // 탭이 숨은 동안 보던 파일이 목록에서 빠졌을 수 있다 (저절로 되살아나는 diff 가 없게 여기서 한 번 본다).
            reconcileDiff()
            consumeSearchRequest()
            consumeNewBranchRequest()
            // 탭을 열었다 = 이 대화의 실행 변경을 검토했다 (탭 아이콘의 점을 뗀다).
            model.markChangesReviewed(threadID: model.selectedThreadID)
            // 터미널 탭 등에서 git 을 바꾸고 돌아왔을 수 있다 — 오래된 목록이면 한 번 다시 읽는다 (chg-11).
            Task { await model.workspace.refreshGitIfStale() }
        }
        // 탭이 보이는 동안 실행이 끝나 점이 붙으면 곧바로 떼고, 스레드를 바꾸면 그 스레드의 점도 뗀다.
        .onChange(of: reviewedKey) { _, _ in model.markChangesReviewed(threadID: model.selectedThreadID) }
        // 다른 스레드로 가면 앞 스레드에서 올린 목록은 쓰지 않는다.
        .onChange(of: model.selectedThreadID) { _, thread in
            if let review = model.changesReview, review.threadID != thread { model.clearChangesReview() }
        }
        // 새 검토 요청이면 찾기 칸을 비워 그 실행의 파일이 걸러지지 않게 한다 (목록은 맨 위로 — 아래 ScrollViewReader).
        .onChange(of: model.changesReview?.id) { _, id in
            if id != nil { query = "" }
        }
        .task(id: raisedKey) { raisedPaths = computeRaisedPaths() }
        .onChange(of: model.changesSearchFocusRequested) { _, _ in consumeSearchRequest() }
        // ⌘⇧N — 탭이 막 열려 저장소를 아직 읽는 중이면 읽은 뒤에 연다.
        .onChange(of: model.newBranchRequestedAt) { _, _ in consumeNewBranchRequest() }
        .onChange(of: model.workspace.git?.isRepository) { _, _ in consumeNewBranchRequest() }
        // 프로젝트나 브랜치가 바뀌면 열려 있던 확인 창은 닫고 (다른 대상으로 올리지 않도록), 열려 있었으면 한 번 안내한다.
        .onChange(of: target) { old, new in targetChanged(from: old, to: new) }
        // 병합이 시작 · 끝날 때 MERGE_MSG 를 커밋 초안으로 (초안이 비어 있을 때만, 한 병합에 한 번).
        .task(id: mergeDraftKey) { reconcileMergeDraft() }
        // PR 은 탭을 열 때(이 프로젝트 · 브랜치의 결과가 캐시에 없을 때) 한 번만 gh 로 묻는다. 주기적으로 다시 묻지 않는다.
        .task(id: pullRequestQueryKey) { await queryPullRequestIfNeeded() }
        #if DEBUG
        .task { await openPreviewPopover() }
        #endif
        .onChange(of: model.workspace.projectPath) { _, _ in
            query = ""
            searchRequested = false
            branchMenu = nil
        }
        // 이전 / 다음 파일(⌥↑ ⌥↓)은 목록에 보이는 순서를 따른다 (올린 구역 · 찾기 결과 포함). 크게 보기도 이 순서를 쓴다.
        .task(id: orderKey) { publishListOrder() }
        // git 상태를 다시 읽으면(커밋 · 되돌림 뒤) 보던 파일이 남았는지 본다 — 빠졌으면 다음 파일로, 없으면 목록으로.
        .onChange(of: model.workspace.git?.fetchedAt) { _, _ in reconcileDiff() }
    }

    // MARK: - 파일 diff

    private func reconcileDiff() {
        guard let git = model.workspace.git else { return }
        model.reconcileDiffFocus(rows: model.workspace.changeRows(),
                                 statusReadable: git.isRepository && git.error == nil)
    }

    /// 좁은 패널에서 볼 파일. 크게 보기가 아니고, 이 폴더에서 연 파일(빠졌으면 옮겨 갈 파일)이 지금 목록에 있을 때만.
    /// 보던 파일이 빠진 직후에도 같은 diff 화면을 유지한다 (`AppModel.diffShownPath` — 목록이 한 번 비쳤다 사라지며
    /// diff 의 키 포커스를 잃지 않게).
    private func narrowDiffRow(_ git: GitWorkspaceStatus) -> ChangesState.Row? {
        guard !model.diffWide, git.error == nil, let active = model.activeDiffPath else { return nil }
        let rows = model.workspace.changeRows()
        if let row = rows.first(where: { $0.path == active }) { return row }
        guard let path = model.diffShownPath(present: Set(rows.map(\.path))) else { return nil }
        return rows.first { $0.path == path }
    }

    /// 목록에 보이는 순서 (`ChangesState.listSections` 를 그대로 펼친 것).
    private func listOrder(_ allRows: [ChangesState.Row]) -> [String] {
        let conflicts = allRows.contains { $0.inclusion == .conflict }
        return ChangesState.visibleOrder(ChangesState.listSections(ChangesState.filter(allRows, query: query),
                                                                   raised: activeRaisedPaths,
                                                                   conflictsPresent: conflicts))
    }

    private var orderKey: String {
        "\(model.workspace.projectPath ?? "")|\(model.workspace.git?.fetchedAt?.timeIntervalSince1970 ?? 0)|\(query)"
            + "|\(model.changesReview?.id.uuidString ?? "")|\(model.changesReview?.runID ?? "")|\(raisedPaths?.count ?? -1)"
    }

    private func publishListOrder() {
        guard let git = model.workspace.git, git.isRepository, git.error == nil else { return }
        model.updateChangesListOrder(listOrder(model.workspace.changeRows()), statusReadAt: git.fetchedAt)
    }

    private func diffPanel(_ git: GitWorkspaceStatus, row: ChangesState.Row) -> some View {
        let order = listOrder(model.workspace.changeRows())
        let integrating = integrating(git)
        let context = DiffFileContext(row: row, request: FileDiffRequest.make(for: row, status: git),
                                      position: ChangesState.diffPosition(of: row.path, in: order), order: order,
                                      providers: AgentProvider.allCases.filter { touched[row.path]?.contains($0) == true },
                                      lock: model.gitWriteLock, integrating: integrating,
                                      busy: model.runningGitOperation != nil, backgroundTasks: backgroundTasks)
        return DiffPanel(context: context,
                         onToggle: { toggle(row, integrating: integrating) },
                         onBack: {
                             selectedPath = row.path
                             model.closeDiff()
                         })
    }

    /// 확인 창 · 커밋이 향하는 곳 (폴더 · 브랜치).
    private struct Target: Equatable {
        var path: String?
        var project: String
        var headLabel: String?
        var detached: Bool
    }

    private var target: Target {
        let path = model.workspace.projectPath
        return Target(path: path, project: projectName(for: path), headLabel: model.workspace.git?.headLabel,
                      detached: model.workspace.git.map { $0.isRepository && $0.branch == nil } ?? false)
    }

    private func projectName(for path: String?) -> String {
        guard let path else { return "" }
        return model.projects.first { $0.path == path }?.name ?? URL(fileURLWithPath: path).lastPathComponent
    }

    /// 대상이 바뀌면 열려 있던 확인 창을 닫는다. 확인 창이 열려 있었으면 "브랜치(프로젝트)가 바뀌었습니다" 를 한 번 남기고,
    /// 안내가 떠 있는 동안 또 바뀌면 사실에 맞게 채우거나 지운다 (`ChangesState.targetNoticeUpdate`).
    private func targetChanged(from old: Target, to new: Target) {
        let closed: ChangesState.ConfirmKind? = {
            if confirmingPull { return .pull }
            if case .push(_, let setUpstream)? = confirmingPush { return setUpstream ? .publish : .upload }
            if confirmingRetry, let operation = model.lastGitOutcome?.operation {
                switch operation {
                case .pull: return .pull
                case .push(_, true): return .publish
                case .push: return .upload
                default: return nil
                }
            }
            return nil
        }()
        confirmingPush = nil
        confirmingPull = false
        confirmingRetry = false
        selectedPath = nil
        let pathChanged = old.path != new.path
        let branchChanged = !pathChanged && old.headLabel != nil && new.headLabel != nil && old.headLabel != new.headLabel
        if let closed, old.headLabel != nil, pathChanged || branchChanged {
            let draft = model.selectedProject.map { model.commitDraft(forFolder: $0.path) } ?? ""
            targetChange = ChangesState.TargetChange(
                fromProjectPath: old.path, fromProject: old.project, fromBranch: old.headLabel,
                toProjectPath: new.path, toProject: new.project, toBranch: pathChanged ? nil : new.headLabel,
                toDetached: new.detached, closed: closed,
                hasDraft: !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else if let change = targetChange {
            switch ChangesState.targetNoticeUpdate(change, nowPath: new.path, nowBranch: new.headLabel,
                                                   nowDetached: new.detached) {
            case .keep: break
            case .fill(let branch, let detached):
                targetChange?.toBranch = branch
                targetChange?.toDetached = detached
            case .clear: targetChange = nil
            }
        }
    }

    /// 이 스레드에 검토하지 않은 실행 변경이 생기거나 스레드가 바뀔 때 달라지는 값.
    private var reviewedKey: String {
        "\(model.selectedThreadID ?? "")|\(model.hasUnreviewedChanges(threadID: model.selectedThreadID))"
    }

    /// 올릴 파일을 다시 계산할 때 (요청 · 그 요청의 실행 · 대화 · 저장소 루트가 바뀔 때 — 새 실행이 끝나면 같은 요청이 그 실행으로 바뀐다, H9).
    private var raisedKey: String {
        "\(model.changesReview?.id.uuidString ?? "")|\(model.changesReview?.runID ?? "")|\(model.selectedThreadID ?? "")"
            + "|\(model.workspace.git?.rootPath ?? "")"
    }

    /// 지금 스레드의 검토 요청이 올릴 경로. 비교한 실행은 요청에 담긴 경로, 비교하지 못한 실행은 그 실행의 기록에 남은
    /// 편집 파일 (저장소 루트 기준으로 — 목록 행과 같은 기준).
    private func computeRaisedPaths() -> Set<String>? {
        guard let review = model.changesReview, review.threadID == model.selectedThreadID else { return nil }
        if let paths = review.paths { return Set(paths) }
        let root = model.workspace.git?.rootPath ?? model.workspace.projectPath
        return Set(ExecutionParser.observedEdits(in: model.events, runID: review.runID, projectPath: root))
    }

    /// 지금 쓸 올린 경로. 요청이 풀리면 계산을 기다리지 않고 곧바로 평소 목록으로.
    private var activeRaisedPaths: Set<String>? {
        guard let review = model.changesReview, review.threadID == model.selectedThreadID else { return nil }
        return raisedPaths
    }

    /// 조회 전(idle)으로 돌아간 것도 키에 넣는다 — git 을 다시 읽어 브랜치가 바뀐 뒤 PR 상태가 조회 전으로 맞춰지면
    /// 그때 한 번 묻는다. 조회 중 · 결과가 있는 동안에는 키가 그대로라 다시 묻지 않는다 (폴링 아님).
    private var pullRequestQueryKey: String {
        "\(model.workspace.projectPath ?? "")|\(model.workspace.git?.headLabel ?? "")|\(model.workspace.git == nil)"
            + "|\(model.workspace.pullRequest == .idle)"
    }

    private func queryPullRequestIfNeeded() async {
        // 화면 확인용 실행(AHC_OFFLINE=1)은 CLI 를 부르지 않는다 — gh 도 부르지 않는다 (`-preview.pullRequest` 로 넣은 값만).
        guard !AppModel.offlinePreview,
              ChangesState.pullRequestQueryNeeded(model.workspace.pullRequest, status: model.workspace.git) else { return }
        await model.workspace.refreshPullRequest()
    }

    /// PR 을 물을 수 있는 브랜치인지 (··· "PR 다시 조회").
    private var canQueryPullRequest: Bool {
        guard let git = model.workspace.git, git.isRepository, git.error == nil, git.branch != nil else { return false }
        return git.remotes?.isEmpty != true && model.workspace.pullRequest != .loading
    }

    private func consumeNewBranchRequest() {
        guard model.takeNewBranchRequest(ready: model.workspace.git?.isRepository == true) else { return }
        // 브랜치 메뉴는 머리줄 브랜치 버튼에 붙는다 — 좁은 패널 diff 가 머리줄을 가리고 있으면 목록으로 돌아간다.
        if model.narrowDiffShown { model.closeDiff() }
        // 탭이 막 나타난 경우가 있어 한 박자 뒤에 연다 (버튼이 자리를 잡은 뒤).
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            branchMenu = BranchMenuRequest(mode: .create)
        }
    }

    /// 지금 보이는 git 상태가 포커스 대화의 폴더 것일 때의 병합 상태 (초안은 폴더마다 — chg-8).
    private var mergeDraftKey: String {
        guard let project = model.selectedProject, model.workspace.projectPath == project.path,
              let git = model.workspace.git else { return "" }
        return "\(project.path)|\(git.mergeHead ?? "-")|\(git.mergeMessage?.count ?? -1)"
    }

    private func reconcileMergeDraft() {
        guard let project = model.selectedProject, model.workspace.projectPath == project.path,
              let git = model.workspace.git, git.isRepository, git.error == nil else { return }
        model.reconcileMergeDraft(folder: project.path, mergeHead: git.mergeHead, mergeMessage: git.mergeMessage)
    }

    #if DEBUG
    /// 화면 확인용 (AHC_OFFLINE=1 일 때만): `-preview.action mergeHowTo · abortHelp · pullConfirm · pushConfirm` 으로
    /// 그 팝오버를 연 채 시작한다. 팝오버를 붙인 버튼이 보이는 상태(기록 분기 · 병합 중 · 원격 변경 도착 · 업로드 대기)에서만 열린다.
    /// `branchMenu` · `branchMenu:<찾는 글자>` · `newBranch` 는 브랜치 메뉴를 (그 글자를 친 채 · 새 이름 입력 상태로) 연다.
    /// `targetChange:<브랜치>` 는 업로드 확인 창을 연 채 그 브랜치로 **실제로** 전환해 "브랜치가 바뀌었습니다" 를 본다
    /// (git 쓰기라 임시 폴더 안의 프로젝트에서만 — `-preview.action push` 와 같은 제한).
    /// `diff:<경로>` · `review:<경로>` 는 그 파일의 diff 를 좁은 패널 · 크게 보기로 연다 (`-preview.scrollProbe` 측정의 시작점).
    private func openPreviewPopover() async {
        guard AppModel.offlinePreview, let action = UserDefaults.standard.string(forKey: "preview.action") else { return }
        let name = action.split(separator: ":", maxSplits: 1).first.map(String.init) ?? action
        let argument = action.contains(":") ? String(action.drop { $0 != ":" }.dropFirst()) : ""
        guard ["mergeHowTo", "abortHelp", "pullConfirm", "pushConfirm", "branchMenu", "newBranch", "targetChange",
               "diff", "review"]
            .contains(name) else { return }
        for _ in 0..<50 where model.workspace.git == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(600))
        switch name {
        case "mergeHowTo": showingMergeHowTo = true
        case "abortHelp": showingAbortHelp = true
        case "pullConfirm": confirmingPull = true
        case "branchMenu": branchMenu = BranchMenuRequest(mode: .browse, query: argument)
        // ⌘⇧N 과 같은 길 (메뉴 명령이 모델에 남기는 요청 → 탭이 받아 연다).
        case "newBranch": model.requestNewBranch()
        case "targetChange":
            guard let branch = model.workspace.git?.branch, !argument.isEmpty,
                  let path = model.selectedProject?.path, AppModel.isTemporaryPreviewProject(path) else { return }
            confirmingPush = .push(branch: branch, setUpstream: false)
            try? await Task.sleep(for: .milliseconds(1200))
            await model.runGit(.switchBranch(argument))
        // `diff:<경로>` · `review:<경로>` — 그 파일(저장소 루트 기준)의 diff 를 좁은 패널 · 크게 보기로 연다 (행을 누른 것과 같은 길).
        case "diff", "review":
            guard !argument.isEmpty else { return }
            DiffScrollProbe.shared.noteOpened(action)
            model.openDiff(path: argument)
            if name == "review" { model.setDiffWide(true) }
        default:
            if let branch = model.workspace.git?.branch { confirmingPush = .push(branch: branch, setUpstream: false) }
        }
    }
    #endif

    private var projectName: String {
        model.selectedProject?.name ?? model.workspace.projectURL?.lastPathComponent ?? ""
    }

    // MARK: - 머리줄

    private func header(_ git: GitWorkspaceStatus?) -> some View {
        InspectorHeader {
            // 프로젝트 이름은 120pt 까지 먼저 자리를 잡고, 브랜치가 남은 폭에서 가운데를 줄인다.
            CappedWidth(max: git?.isRepository == true ? 120 : 300) {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate2)
                    Text(projectName)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .layoutPriority(2)
            .help(model.workspace.projectPath.map(Fmt.abbreviatedPath) ?? "")
            if let git, git.isRepository {
                branchButton(git)
            }
        } trailing: {
            // 목록 다시 읽기 — 앱 안 터미널에서 git add · 커밋한 뒤 (앱이 비활성화되지 않아 저절로 읽지 않는다, chg-11).
            IconButton(systemName: "arrow.clockwise", size: 11.5, help: "목록 다시 읽기",
                       spinning: model.workspace.isRefreshingGit) {
                Task { await model.workspace.refreshGit() }
            }
            if let git, git.isRepository {
                fetchButton(git)
            }
            moreMenu
        }
    }

    private func branchButton(_ git: GitWorkspaceStatus) -> some View {
        let agentLocked: Bool = {
            if case .agentRunning? = model.gitWriteLock { return true }
            return false
        }()
        return Button {
            branchMenu = branchMenu == nil ? BranchMenuRequest(mode: .browse) : nil
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.slate)
                CappedWidth(max: 210) {
                    Text(git.headLabel ?? "브랜치 미확인")
                        .font(Theme.mono(.caption, .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(Theme.slate2)
                if agentLocked {
                    Image(systemName: "lock")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.amber)
                        .help("에이전트 실행 중에는 전환할 수 없습니다")
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background {
                if branchMenu != nil {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.well)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hair))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
        .help(agentLocked ? "에이전트 실행 중에는 전환할 수 없습니다 · 브랜치 목록 보기"
              : "브랜치 전환 · 새 브랜치 (⌘⇧N)")
        .popover(item: $branchMenu, arrowEdge: .bottom) { request in
            BranchMenuView(mode: request.mode, query: request.query) { branchMenu = nil }
        }
    }

    private func fetchButton(_ git: GitWorkspaceStatus) -> some View {
        // 다른 git 명령 실행 중(잠깐)은 흐리게 바꾸지 않는다 — 그동안 누르면 runGit 이 실행하지 않는다.
        let lock = ChangesState.visibleLock(model.gitWriteLock)
        let fetching = model.runningGitOperation == .fetch
        // `git remote` 를 읽지 못했으면(nil) 원격이 없다고 단정하지 않는다.
        let noRemote = git.remotes?.isEmpty == true
        let help: String = {
            if noRemote { return "원격 저장소가 없어 확인할 것이 없습니다" }
            if let lock { return "원격 상태 확인을 할 수 없습니다 — " + lockText(lock, action: "원격을 확인할") }
            return "원격 상태 확인 — 원격에 새 커밋이 있는지 봅니다. 파일은 바뀌지 않습니다. (git fetch --prune)"
        }()
        // 실패는 바닥 동기화 자리에 이유로 남긴다 (배너 대신). 그 자리가 없으면(병합 · rebase 중, 상태를 못 읽음)
        // `runGit` 이 명령이 끝난 뒤의 상태를 보고 배너로 알린다.
        return Button {
            Task { await model.runGit(.fetch, reportsInline: true) }
        } label: {
            Group {
                if fetching {
                    InkSpinner(color: Theme.slate)
                } else {
                    Image(systemName: "arrow.clockwise.icloud")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.slate)
                }
            }
            .frame(width: 26, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(lock != nil || noRemote)
        .opacity(lock != nil || noRemote ? 0.4 : 1)
        .help(help)
        .accessibilityLabel("원격 상태 확인")
    }

    private var moreMenu: some View {
        Menu {
            Button("목록 다시 읽기") { Task { await model.workspace.refreshGit() } }
            // PR 은 탭을 열 때 한 번만 묻는다. 그 뒤로는 사용자가 원할 때만 (gh pr view · 읽기만).
            Button("PR 다시 조회") { Task { await model.workspace.refreshPullRequest() } }
                .disabled(!canQueryPullRequest)
            if let root = model.workspace.projectURL {
                Button("터미널에서 열기") { TerminalLauncher.open(root) }
                Button("Finder 에서 보기") { NSWorkspace.shared.open(root) }
            }
        } label: {
            Text("···").font(Theme.ui(.callout)).tracking(1).foregroundStyle(Theme.slate2)
                .frame(width: 22, height: 24).contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("더보기 — 목록 다시 읽기 · PR 다시 조회 · 터미널 · Finder")
        .accessibilityLabel("변경사항 더보기")
    }

    // MARK: - 저장소가 아님

    private func notRepository(_ git: GitWorkspaceStatus) -> some View {
        VStack(spacing: 0) {
            header(git)
            ScrollView {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 19, weight: .light))
                        .foregroundStyle(Theme.slate3)
                    if let error = git.error, GitWorkspace.isGitMissing(error) {
                        // git 이 없는 Mac — 첫 실행 점검표와 같은 설치 안내로 잇는다 (chg-23).
                        Text("git 이 없습니다").font(Theme.ui(.callout, .semibold)).foregroundStyle(Theme.ink2)
                        Text("Command Line Tools 를 설치하면 변경 내용 보기 · 커밋 · 업로드를 쓸 수 있습니다. "
                             + "터미널에서 아래 명령을 실행하면 macOS 설치 창이 뜹니다.")
                            .font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
                            .lineSpacing(3)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        CopyableCommand(command: AgentSetupGuide.gitToolsInstallCommand)
                            .frame(maxWidth: 260)
                            .padding(.top, 4)
                        Button("시작 점검 열기") { model.openStartCheck() }
                            .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
                            .help("설치한 뒤 시작 점검의 [다시 확인] 으로 확인합니다")
                    } else if let error = git.error {
                        // git 을 찾지 못한 경우 등 — 저장소가 아니라고 단정하지 않는다.
                        Text("Git 상태를 읽지 못했습니다").font(Theme.ui(.callout, .semibold)).foregroundStyle(Theme.ink2)
                        Text(error)
                            .font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Git 저장소가 아닙니다").font(Theme.ui(.callout, .semibold)).foregroundStyle(Theme.ink2)
                        Text("이 폴더는 변경 기록을 관리하지 않아 커밋이나 업로드를 할 수 없습니다. "
                             + "파일은 파일 탭에서 계속 볼 수 있습니다.")
                            .font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
                            .lineSpacing(3)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(spacing: 8) {
                        if git.error == nil {
                            // 이 폴더에서 바로 기록을 시작한다 (git init — 확인 뒤). 그래야 에이전트가 바꾼 것을 diff 로 볼 수 있다 (chg-23).
                            Button("이 폴더에서 git 시작하기…") { confirmingInit = true }
                                .buttonStyle(InkButtonStyle(height: 26))
                                .help("git init — 이 폴더에 .git 폴더를 만들어 변경 기록을 시작합니다. 파일은 바뀌지 않습니다.")
                                .popover(isPresented: $confirmingInit, arrowEdge: .bottom) { initConfirm }
                        }
                        if let root = model.workspace.projectURL {
                            Button { TerminalLauncher.open(root) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "terminal").font(.system(size: 10.5))
                                    Text("터미널에서 이 폴더 열기")
                                }
                            }
                            .buttonStyle(ChipButtonStyle(height: 26))
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 36)
                .padding(.top, 120)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// "이 폴더에서 git 시작하기" 확인 (chg-23).
    private var initConfirm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("이 폴더에서 git 기록을 시작할까요?")
                .font(Theme.ui(.callout, .semibold))
                .foregroundStyle(Theme.ink)
            Text("git init 으로 이 폴더에 .git 폴더를 만듭니다. 파일은 바뀌지 않고, 첫 커밋은 체크한 파일로 직접 만듭니다. "
                 + "그 뒤로는 에이전트가 바꾼 파일을 변경사항 탭에서 비교해 볼 수 있습니다.")
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("취소") { confirmingInit = false }
                    .buttonStyle(ChipButtonStyle(height: 26))
                    .keyboardShortcut(.cancelAction)
                Button("git 시작") {
                    confirmingInit = false
                    Task { await model.initializeRepository() }
                }
                .buttonStyle(InkButtonStyle(height: 26))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: - 저장소

    @ViewBuilder
    private func repository(_ git: GitWorkspaceStatus) -> some View {
        let allRows = model.workspace.changeRows()
        let rows = ChangesState.filter(allRows, query: query)
        let sync = ChangesState.sync(git)
        let included = ChangesState.includedCount(allRows)
        // 독립 작업 폴더의 대화 브랜치(ahc/…)는 원격에 올리지 않고 위 칸에서 합친다 — 업로드를 주 버튼으로 권하지 않는다 (chg-2 · cap-3).
        let primary = ChangesState.primary(includedCount: included, sync: sync,
                                           internalBranch: worktreeTarget(git) != nil)
        let lock = model.gitWriteLock
        let projectPath = model.selectedProject?.path ?? model.workspace.projectPath ?? ""
        let justCommitted = ChangesState.isJustCommitted(appCommitHash: model.appCommitHashes[projectPath],
                                                         head: git.lastCommit)

        let conflicts = allRows.reduce(0) { $0 + ($1.inclusion == .conflict ? 1 : 0) }

        header(git)
        if let error = git.error {
            // status 를 못 읽었으면 변경이 없다고도, 원격과 같다고도 쓰지 않는다.
            statusFailed(error)
        } else {
            summary(git, rows: allRows, conflicts: conflicts, sync: sync, lock: lock)
            // 조회하지 않은 상태(떼어진 HEAD · 원격 없음 · 화면 확인용 실행)면 그리지 않는다.
            if model.workspace.pullRequest != .idle {
                PullRequestRow(state: model.workspace.pullRequest, checkedAt: model.workspace.pullRequestCheckedAt) {
                    openTab(.pullRequest)
                }
            }
            if let lock { lockNote(lock) }
            if git.isRebasing {
                rebaseNote(conflicts: conflicts)
            } else if conflicts > 0 || git.isMerging {
                mergeNote(git, conflicts: conflicts)
            }
            changesBody(git, allRows: allRows, rows: rows, sync: sync, included: included, primary: primary,
                        conflicts: conflicts, justCommitted: justCommitted, lock: lock)
        }
    }

    private func statusFailed(_ error: String) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Theme.slate3)
                Text("변경 목록을 읽지 못했습니다")
                    .font(Theme.ui(.callout, .semibold))
                    .foregroundStyle(Theme.ink2)
                Text(error)
                    .font(Theme.mono(.caption))
                    .foregroundStyle(Theme.slate)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button("다시 읽기") { Task { await model.workspace.refreshGit() } }
                    .buttonStyle(ChipButtonStyle(height: 26))
                    .padding(.top, 6)
            }
            .padding(.horizontal, 28)
            .padding(.top, 56)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func changesBody(_ git: GitWorkspaceStatus, allRows: [ChangesState.Row], rows: [ChangesState.Row],
                             sync: ChangesState.Sync, included: Int, primary: ChangesState.Primary,
                             conflicts: Int, justCommitted: Bool, lock: ChangesState.Lock?) -> some View {
        let sections = ChangesState.commitSections(sync)
        let raised = activeRaisedPaths
        if allRows.isEmpty && !git.isMerging {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // 검토하러 왔는데 그 실행의 파일이 이미 목록에 없다 (그 뒤 커밋 · 되돌림) — 빈 화면만 두지 않고 밝힌다.
                    if let raised {
                        runSectionHead(count: 0, conflicts: 0, missing: raised.count)
                            .padding(.top, 2)
                    }
                    if sections.isEmpty {
                        cleanState(git)
                    } else {
                        // 원격 변경 도착 · 기록 분기: 내 변경이 없으면 커밋 목록이 이 자리의 내용이다.
                        commitSectionItems(git, sections: sections)
                        if case .behind = sync {
                            Text("커밋할 내 변경은 없습니다.")
                                .font(Theme.ui(.caption))
                                .foregroundStyle(Theme.slate)
                                .padding(.horizontal, 6)
                                .padding(.top, 10)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, sections.isEmpty ? 0 : 2)
                .padding(.bottom, 10)
            }
            // 커밋 목록이 길면 바닥을 흐리게 해 아래 동기화 자리 밑으로 이어진다는 것을 보인다 (파일 목록과 같게).
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY > 2
            } action: { _, more in
                listHasMoreBelow = more
            }
            .overlay(alignment: .bottom) {
                if listHasMoreBelow {
                    LinearGradient(colors: [Theme.panel.opacity(0), Theme.panel],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 36)
                        .allowsHitTesting(false)
                }
            }
            // 커밋 독이 없으니 "브랜치가 바뀌었습니다" 는 동기화 자리 위에.
            if let targetChange { targetChangeNote(targetChange, standalone: true) }
        } else {
            if searchVisible(allRows.count) {
                SearchField(placeholder: "\(allRows.count)개 파일에서 찾기", text: $query,
                            systemImage: "magnifyingglass", shortcut: "⌘⇧F", focus: $searchFocused)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
            }
            // 충돌이 있으면 "충돌 n" · "그 밖의 변경 n" 섹션 머리가 개수를 대신한다 (목업 StateConflict).
            if conflicts == 0 && !allRows.isEmpty {
                listHeader(rows, filtered: !query.trimmingCharacters(in: .whitespaces).isEmpty, lock: lock,
                           integrating: integrating(git))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        Color.clear.frame(height: 0).id(Self.listTopID)
                        // ("변경사항 검토" 로 연 실행의 파일) → 충돌 → 그 밖의 변경. 각 구역 안은 충돌 먼저, 경로 순
                        // (`ChangesState.rows`).
                        ForEach(ChangesState.listSections(rows, raised: raised, conflictsPresent: conflicts > 0),
                                id: \.kind) { section in
                            switch section.kind {
                            case .all:
                                EmptyView()
                            case .conflicts:
                                ListSectionHead(label: "충돌", count: section.rows.count, color: Theme.danger)
                            case .thisRun:
                                runSectionHead(count: section.rows.count,
                                               conflicts: section.rows.filter { $0.inclusion == .conflict }.count,
                                               missing: raised.map { ChangesState.raisedMissing(allRows, raised: $0) } ?? 0)
                            case .others:
                                ListSectionHead(label: "그 밖의 변경", count: section.rows.count)
                            }
                            ForEach(section.rows) { row in fileRow(row, git: git, lock: lock) }
                        }
                        if rows.isEmpty {
                            Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                                 ? "변경 파일이 없습니다" : "‘\(query)’ 와 일치하는 파일이 없습니다")
                                .font(Theme.ui(.caption)).foregroundStyle(Theme.slate2)
                                .padding(.horizontal, 6).frame(height: 26)
                        }
                        if !sections.isEmpty {
                            // 여러 행을 돌려주는 묶음이라 수식어 대신 빈 칸으로 띄운다 (수식어는 행마다 붙는다).
                            Color.clear.frame(height: 6)
                            commitSectionItems(git, sections: sections)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                // "변경사항 검토" 로 왔으면 올린 파일이 보이도록 맨 위로.
                .onChange(of: model.changesReview?.id) { _, id in
                    guard id != nil else { return }
                    proxy.scrollTo(Self.listTopID, anchor: .top)
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY > 2
            } action: { _, more in
                listHasMoreBelow = more
            }
            .overlay(alignment: .bottom) {
                if listHasMoreBelow {
                    LinearGradient(colors: [Theme.panel.opacity(0), Theme.panel],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 36)
                        .allowsHitTesting(false)
                }
            }
            commitDock(git, rows: allRows, included: included, primary: primary, lock: lock)
        }
        // 병합 · rebase 중에는 업로드 · 받기를 두지 않는다 (병합은 커밋이 마무리한 뒤, rebase 는 터미널에서 이어간 뒤).
        if !git.isMerging && !git.isRebasing {
            syncArea(git, sync: sync, primary: primary, justCommitted: justCommitted, lock: lock)
        }
    }

    /// 지금 브랜치가 이 대화의 독립 작업 폴더 브랜치(ahc/…)면 그 브랜치가 합쳐질 곳(프로젝트 폴더의 브랜치 이름). 아니면 nil.
    private func worktreeTarget(_ git: GitWorkspaceStatus) -> String? {
        guard let thread = model.selectedThread, let worktree = thread.worktree,
              ChangesState.isInternalBranch(git.branch, worktreeBranch: worktree.branch) else { return nil }
        return model.worktreeStatuses[thread.id]?.mainBranch ?? worktree.baseBranch ?? "프로젝트 폴더"
    }

    /// 병합 · rebase 가 진행 중이라 인덱스에 합쳐진 결과가 있다 (그동안 커밋에서 빼기를 하지 않는다).
    private func integrating(_ git: GitWorkspaceStatus) -> Bool {
        git.isMerging || git.isRebasing
    }

    private func fileRow(_ row: ChangesState.Row, git: GitWorkspaceStatus, lock: ChangesState.Lock?) -> some View {
        let integrating = integrating(git)
        return ChangeFileRow(row: row,
                      providers: AgentProvider.allCases.filter { touched[row.path]?.contains($0) == true },
                      editingNow: editingNow.contains(row.path),
                      editingTint: focusedSession?.activeProvider?.tint ?? Theme.claude,
                      // 크게 보기 중에는 가운데에 보이는 파일이 선택 표시다.
                      selected: (model.diffWideActive ? model.activeDiffPath : selectedPath) == row.path,
                      locked: isBlockingLock(lock),
                      busy: model.runningGitOperation != nil,
                      pending: pendingPath == row.path,
                      lockReason: lock.map { lockText($0, action: "선택할") },
                      holdsIncluded: ChangesState.toggleOperation(for: row, merging: integrating) == nil
                          && row.isCheckable,
                      onToggle: { toggle(row, integrating: integrating) },
                      onSelect: {
                          // 행을 누르면 그 파일의 diff (좁은 패널 — 크게 보기 중이면 가운데 파일이 바뀐다).
                          selectedPath = row.path
                          model.openDiff(path: row.path)
                      })
    }

    /// "변경사항 검토" 로 올린 구역의 머리 — 어느 실행인지(에이전트 · 시각)를 밝힌다 (H9). 구역의 행 수와 아래 설명의 개수를 더하면
    /// 카드의 파일 수가 된다 (`ChangesState.raisedNotes` — 그중 충돌 · 그 실행이 목록에서 뺀 파일 · 그 뒤 목록에 없는 파일 ·
    /// 경로를 기록하지 않은 파일). "원래 순서" 로 풀 수 있다 (다른 실행의 칩을 누르거나 탭을 떠나도 풀린다). 같은 대화에서 새 실행이
    /// 끝나면 구역이 그 실행의 것으로 바뀐다 (`AppModel.recordRunChanges`).
    private func runSectionHead(count: Int, conflicts: Int, missing: Int) -> some View {
        let review = model.changesReview
        let run = review.flatMap { model.runsByID[$0.runID] }
        let time = run.map { Fmt.time.string(from: $0.endedAt ?? $0.startedAt) }
        let title = ChangesState.runSectionTitle(agent: run?.provider.displayName, time: time)
        let basis = review?.paths == nil ? "실행 기록에 남은 편집 파일" : "실행 전후 비교로 찾은 파일"
        let notes = ChangesState.raisedNotes(conflicts: conflicts, missing: missing,
                                             clearedByRun: review?.clearedByRun ?? 0, unstored: review?.unstored ?? 0)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                SectionLabel(title)
                Text("\(count)")
                    .font(Theme.mono(.caption))
                    .foregroundStyle(Theme.slate2)
                Spacer(minLength: 4)
                Button("원래 순서") { model.clearChangesReview() }
                    .buttonStyle(TextButtonStyle(color: Theme.slate2, font: Theme.ui(.caption)))
                    .help("이 실행의 파일을 위로 올리지 않고 경로 순으로 봅니다")
            }
            if !notes.isEmpty {
                Text(notes.joined(separator: " · "))
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("목록에서 빠짐 = 그 실행이 스스로 되돌렸거나 커밋해, 실행이 끝났을 때 이미 변경 목록에 없던 파일. "
                          + "지금 목록에 없음 = 그 실행 뒤에 커밋 · 되돌림 등으로 지금 변경 목록에 없는 파일. "
                          + "경로를 기록하지 않은 파일은 기록 상한(\(RunFileChanges.storedFileLimit)개)을 넘은 것입니다.")
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .help("대화의 \"변경사항 검토\" 로 연 실행 — 위로 올린 것: \(basis). 같은 대화에서 새 실행이 끝나면 그 실행의 파일로 바뀝니다.")
        .accessibilityElement(children: .contain)
    }

    // MARK: 커밋 목록

    /// 원격에서 온 커밋 · 이 브랜치에만 있는 커밋 섹션. 개수는 앞섬 · 뒤처짐 수(전체)이고, 목록은 최대
    /// `GitWorkspace.commitListLimit` 개라 넘치면 "외 n개" 로 밝힌다. 목록을 못 읽었으면 그 사실을 쓴다.
    /// LazyVStack 안에 행 단위로 들어가도록 여러 뷰를 그대로 돌려준다.
    @ViewBuilder
    private func commitSectionItems(_ git: GitWorkspaceStatus, sections: [ChangesState.CommitSection]) -> some View {
        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
            switch section {
            case .outgoing(let count):
                commitSection(label: "이 브랜치에만 있는 커밋", count: count, icon: "arrow.up",
                              commits: git.outgoingCommits)
            case .incoming(let count, let diverged):
                commitSection(label: diverged ? "원격에만 있는 커밋" : "원격에서 온 커밋", count: count,
                              icon: diverged ? "arrow.down" : nil, commits: git.incomingCommits)
            }
        }
    }

    @ViewBuilder
    private func commitSection(label: String, count: Int, icon: String?, commits: [GitLogEntry]?) -> some View {
        ListSectionHead(label: label, count: count, trailingSystemImage: icon)
        if let commits {
            ForEach(commits) { entry in
                CommitLineRow(entry: entry)
            }
            if let more = ChangesState.moreCount(listed: commits.count, total: count) {
                Text("외 \(more)개 · 최근 \(commits.count)개만 보여줍니다")
                    .font(Theme.mono(.caption))
                    .foregroundStyle(Theme.slate2)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
            }
        } else {
            Text("커밋 목록을 읽지 못했습니다 · ··· 에서 다시 읽기")
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate2)
                .padding(.horizontal, 6)
                .frame(height: 24)
        }
    }

    // MARK: 충돌 · 병합 안내

    /// 충돌이 남았으면 "충돌을 해결해야 커밋할 수 있습니다", 병합 중인데 충돌이 없으면 "병합을 마무리할 수 있습니다".
    /// 목업 문구("저장하면 해결됨으로 바뀝니다")와 달리 해결됨을 따로 표시해야 한다고 적는다 — git 은 파일을 저장한 것만으로는
    /// 충돌이 풀렸다고 보지 않는다 (인덱스에 해결됨을 표시해야 한다). 그 표시(`git add`)는 [해결됨으로 표시…] 가 한다 —
    /// 충돌 표시가 남지 않은 파일만 (chg-11).
    private func mergeNote(_ git: GitWorkspaceStatus, conflicts: Int) -> some View {
        let root = model.workspace.projectURL
        return Group {
            if conflicts > 0 {
                RuleNote(systemImage: "exclamationmark.triangle", tint: Theme.amber,
                         title: "충돌을 해결해야 커밋할 수 있습니다",
                         detail: (git.isMerging ? "병합 중 충돌한 파일이 \(conflicts)개 있습니다. "
                                                : "충돌한 파일이 \(conflicts)개 있습니다. ")
                             + "파일 안의 충돌 표시(<<<<<<<)를 정리하고 저장한 뒤 [해결됨으로 표시] 로 알리세요 (git add).") {
                    resolveButton(git)
                    if let root {
                        Button { TerminalLauncher.open(root) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "terminal").font(.system(size: 10.5))
                                Text("터미널에서 열기")
                            }
                        }
                        .buttonStyle(ChipButtonStyle(height: 24, horizontalPadding: 9))
                        .help("이 폴더를 터미널에서 엽니다")
                    }
                    if git.isMerging { abortHelpButton(root) }
                }
            } else {
                RuleNote(systemImage: "checkmark", tint: Theme.emerald,
                         title: "병합을 마무리할 수 있습니다",
                         detail: "충돌 파일이 남아 있지 않습니다. 커밋하면 병합 커밋이 만들어집니다.") {
                    abortHelpButton(root)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairSoft).frame(height: 1) }
    }

    /// rebase 진행 중 (`git pull --rebase` · `git rebase` 가 멈춤). 이어가기 · 멈추기는 터미널에서 한다 —
    /// 앱의 커밋은 멈춘 커밋을 대신하는 새 커밋이 되고, 브랜치 만들기 · 전환은 git 이 거부한다.
    private func rebaseNote(conflicts: Int) -> some View {
        let root = model.workspace.projectURL
        let detail = conflicts > 0
            ? "충돌한 파일이 \(conflicts)개 있습니다. 충돌 표시(<<<<<<<)를 정리하고 저장한 뒤 [해결됨으로 표시] 로 알리고, "
                + "터미널에서 git rebase --continue 로 이어가세요."
            : "터미널에서 git rebase --continue 로 이어가거나, git rebase --abort 로 rebase 전 상태로 돌아가세요."
        return RuleNote(systemImage: "exclamationmark.triangle", tint: Theme.amber,
                        title: "rebase 가 진행 중입니다",
                        detail: detail + " 그동안 앱은 커밋 · 업로드를 하지 않습니다.") {
            if conflicts > 0, let git = model.workspace.git { resolveButton(git) }
            if let root {
                Button { TerminalLauncher.open(root) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "terminal").font(.system(size: 10.5))
                        Text("터미널에서 열기")
                    }
                }
                .buttonStyle(ChipButtonStyle(height: 24, horizontalPadding: 9))
                .help("이 폴더를 터미널에서 엽니다 (git rebase --continue · --abort 는 앱이 실행하지 않습니다)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairSoft).frame(height: 1) }
    }

    /// [해결됨으로 표시…] — 충돌 파일마다 충돌 표시가 남았는지 보이고, 남지 않은 것만 git add 로 해결됨을 표시한다 (chg-11).
    private func resolveButton(_ git: GitWorkspaceStatus) -> some View {
        let rows = model.workspace.changeRows().filter { $0.inclusion == .conflict }
        let lock = ChangesState.visibleLock(model.gitWriteLock)
        return Button("해결됨으로 표시…") { showingResolve = true }
            .buttonStyle(ChipButtonStyle(height: 24, horizontalPadding: 9))
            .disabled(rows.isEmpty || lock != nil || model.runningGitOperation != nil)
            .help(lock.map { lockText($0, action: "표시할") } ?? "충돌을 정리한 파일을 해결됨으로 표시합니다 (git add)")
            .popover(isPresented: $showingResolve, arrowEdge: .bottom) {
                ConflictResolveView(rows: rows, root: git.rootPath.map { URL(fileURLWithPath: $0) }) { paths in
                    showingResolve = false
                    Task { await model.runGit(.stage(paths)) }
                }
            }
    }

    private func abortHelpButton(_ root: URL?) -> some View {
        Button("합치기를 멈추는 방법") { showingAbortHelp = true }
            .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
            .popover(isPresented: $showingAbortHelp, arrowEdge: .bottom) {
                MergeAbortHelpView(openTerminal: root.map { url in { TerminalLauncher.open(url) } })
            }
            .help("git merge --abort — 이 병합을 멈추는 명령은 앱이 실행하지 않습니다")
    }

    // MARK: 요약

    private func summary(_ git: GitWorkspaceStatus, rows: [ChangesState.Row], conflicts: Int,
                         sync: ChangesState.Sync, lock: ChangesState.Lock?) -> some View {
        let internalBranch = worktreeTarget(git) != nil
        let parts = ChangesState.metaParts(sync, lastFetchAt: model.workspace.lastFetchAt, detachedHash: git.detachedHash,
                                           internalBranch: internalBranch)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if conflicts > 0 {
                    (Text("충돌 파일 ") + Text("\(conflicts)") + Text("개"))
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.danger)
                    MetaDot()
                }
                if rows.isEmpty {
                    Text("변경 파일 없음")
                } else {
                    Text("변경 파일 ") + Text("\(rows.count)").fontWeight(.semibold).foregroundStyle(Theme.ink) + Text("개")
                }
                if let item = ChangesState.remoteSummary(sync, hasChanges: !rows.isEmpty, internalBranch: internalBranch) {
                    MetaDot()
                    remoteSummaryView(item)
                }
            }
            .font(Theme.ui(.callout))
            .foregroundStyle(Theme.ink2)
            .lineLimit(1)
            // 상대 시각만 분 단위로 다시 그린다 (git 을 다시 읽지 않는다).
            TimelineView(.everyMinute) { context in
                let parts = ChangesState.metaParts(sync, lastFetchAt: model.workspace.lastFetchAt, now: context.date,
                                                   detachedHash: git.detachedHash, internalBranch: internalBranch)
                // 원격 브랜치 이름은 가장 늦게 줄인다 — 뒷부분("n분 전 확인")이 먼저 줄고, 이름이 넘치면 가운데를 줄인다
                // (cap-23, 전체는 도움말). 고정 폭으로 두면 400pt 인스펙터에서 칸의 최소 폭을 밀어 올린다.
                HStack(spacing: 0) {
                    if let lead = parts.lead {
                        Text(lead).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                    }
                    Text(parts.rest).lineLimit(1).truncationMode(.tail)
                }
            }
            .font(Theme.mono(.caption))
            .foregroundStyle(Theme.slate2)
            .help(parts.lead.map { $0 + parts.rest } ?? parts.rest)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairSoft).frame(height: 1) }
    }

    @ViewBuilder
    private func remoteSummaryView(_ item: ChangesState.RemoteSummary) -> some View {
        switch item {
        case .toUpload(let n):
            HStack(spacing: 4) {
                Image(systemName: "arrow.up").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.slate)
                Text("업로드할 커밋 ") + Text("\(n)").fontWeight(.semibold).foregroundStyle(Theme.ink) + Text("개")
            }
        case .incoming(let n):
            HStack(spacing: 4) {
                Image(systemName: "arrow.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.slate)
                Text("원격에 새 커밋 ") + Text("\(n)").fontWeight(.semibold).foregroundStyle(Theme.ink) + Text("개")
            }
        case .diverged:
            HStack(spacing: 4) {
                // 머리줄 브랜치 버튼(arrow.triangle.branch)과 다른 갈래 모양 (목업 `fork`).
                ForkGlyph(color: Theme.amber, size: 12, lineWidth: 1.5)
                Text("기록이 갈라짐").fontWeight(.semibold)
            }
            .foregroundStyle(Theme.amberText)
        case .same:
            Text("원격과 같음")
        case .notOnRemote:
            Text("원격에 없는 브랜치").foregroundStyle(Theme.slate)
        case .notTracking:
            Text("원격 추적 없음").foregroundStyle(Theme.slate)
        case .upstreamGone:
            Text("추적 브랜치가 원격에 없음").foregroundStyle(Theme.amberText)
        case .noRemote:
            Text("원격 저장소 없음").foregroundStyle(Theme.slate)
        case .detached:
            Text("브랜치가 아닌 커밋").foregroundStyle(Theme.slate)
        }
    }

    // MARK: 잠금 안내

    @ViewBuilder
    private func lockNote(_ lock: ChangesState.Lock) -> some View {
        switch lock {
        case .agentRunning(let provider, let here):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    if here { PendingRing(color: provider?.tint ?? Theme.claude) }
                    if let provider { BrandMark(provider: provider, size: 12) }
                    Text(here ? "\(ChangesState.agentSubject(provider)) 이 폴더에서 실행 중입니다"
                                + (backgroundTasks > 0 ? " (백그라운드 작업 \(backgroundTasks)개)" : "")
                              : "\(ChangesState.agentSubject(provider)) 다른 폴더에서 실행 중입니다")
                        .font(Theme.ui(.caption, .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let started = (model.writeSessions(inProjectPath: model.selectedProject?.path ?? "").last ?? model.reviewLanes.activeSessions.last)?.activeRun?.startedAt {
                        ElapsedText(since: started) { Self.elapsed(from: started, to: started.addingTimeInterval(Double($0))) }
                    }
                }
                // 목록은 에이전트가 파일을 바꿀 때마다 다시 읽는다 (`AppModel.scheduleLiveGitRefresh`, H8) — 그 사실대로 쓴다.
                Text(lockDetail(here: here))
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
                    .lineSpacing(2)
                    .lineLimit(3)
                // 메인 턴은 끝났고 백그라운드 작업만 남았다 — 개발 서버처럼 스스로 끝나지 않는 것이면 멈추는 길을 준다 (chg-12).
                if here, let exit = ChangesState.backgroundExitNote(backgroundTasks: backgroundTasks) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(exit)
                            .font(Theme.ui(.caption))
                            .foregroundStyle(Theme.slate)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("백그라운드 작업 멈추기") { Task { await stopWaitingRuns() } }
                            .buttonStyle(ChipButtonStyle(height: 24, horizontalPadding: 9))
                            .fixedSize()
                            .help("이 폴더에서 백그라운드 작업을 기다리는 실행을 멈춥니다 (그 대화에서 ⌘. 를 누른 것과 같습니다)")
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, 1)
            .leadingRule(Theme.amber, width: 2, gap: 11)
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairSoft).frame(height: 1) }
        case .unterminatedProcesses:
            // 어떤 프로세스인지와 푸는 길(확인함)을 이 탭에서 바로 — 대화 쪽 안내를 찾아가지 않아도 되게 (chg-17).
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "lock").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.amber)
                    Text("종료가 확인되지 않은 프로세스가 있습니다")
                        .font(Theme.ui(.caption, .semibold)).foregroundStyle(Theme.ink)
                    Spacer(minLength: 6)
                    Button("확인함") { model.acknowledgeUnterminatedProcesses() }
                        .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
                        .help("아래 프로세스가 끝났거나 직접 정리했으면 누르세요. 인계 · git 쓰기 · 새 실행의 잠금이 풀립니다.")
                }
                Text("파일 경합을 막으려고 git 쓰기(커밋에 포함 · 커밋 · 업로드 · 브랜치 전환)를 멈춰 두었습니다. "
                     + "프로세스가 끝났는지 확인한 뒤 [확인함] 을 누르세요. 목록은 지금 볼 수 있습니다.")
                    .font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
                    .lineLimit(3)
                ForEach(model.unterminatedProcessNotes.prefix(3), id: \.self) { note in
                    Text(note).font(Theme.mono(.caption)).foregroundStyle(Theme.slate2).lineLimit(1).truncationMode(.middle)
                        .help(note)
                }
            }
            .leadingRule(Theme.amber, width: 2, gap: 11)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairSoft).frame(height: 1) }
        case .gitRunningElsewhere, .worktreeCommand:
            // 다른 프로젝트의 원격 명령 · 이 폴더의 독립 작업 폴더 명령(준비 명령은 몇 분) — 체크가 왜 안 되는지 (chg-9 · chg-10).
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                InkSpinner(color: Theme.slate)
                Text(lockText(lock, action: "선택 · 커밋할"))
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .leadingRule(Theme.amber, width: 2, gap: 11)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairSoft).frame(height: 1) }
        case .gitRunning, .runSnapshot, .noThread:
            // git 명령 실행 중 · 실행 전후 스냅샷은 잠깐이라 안내를 띄우지 않는다. 대화 없음은 버튼 도움말로 알린다.
            EmptyView()
        }
    }

    /// 이 폴더에서 메인 턴을 마치고 백그라운드 작업을 기다리는 실행을 멈춘다 (⌘. 와 같은 길 — chg-12).
    private func stopWaitingRuns() async {
        let waiting = model.writeSessions(inProjectPath: model.selectedProject?.path ?? "").filter(\.isWaitingOnBackground)
        for session in waiting {
            if let threadID = session.activeThreadID { await model.runner.interrupt(threadID: threadID) }
        }
    }

    /// 목록을 흐리게 그릴 잠금 (git 명령 실행 중은 잠깐이라 흐리게 하지 않는다). diff 의 "커밋에 포함" 도 같은 기준.
    private func isBlockingLock(_ lock: ChangesState.Lock?) -> Bool {
        ChangesState.blocksCheckbox(lock)
    }

    /// 에이전트가 도는 동안의 설명 — 이 폴더면 지금 검토할 수 있다는 것, 다른 폴더면 어느 실행이 끝나야 하는지.
    private func lockDetail(here: Bool) -> String {
        if here {
            return "목록은 에이전트가 파일을 바꾸면 곧 다시 읽어, 바뀐 것을 지금 검토할 수 있습니다. "
                + "커밋 · 업로드 · 브랜치 전환은 실행이 끝나면 할 수 있습니다."
        }
        let running: String = model.activeRunProject.map { "\($0.name) 프로젝트의 실행" } ?? "다른 프로젝트의 실행"
        return running + "이 끝날 때까지 앱은 git 쓰기(커밋에 포함 · 커밋 · 업로드 · 브랜치 전환)를 하지 않습니다. 목록은 지금 볼 수 있습니다."
    }

    /// 잠금 이유 한 문장 (`ChangesState.lockText` — 브랜치 메뉴와 같은 말). `action` 은 "수 있습니다" 앞의 동사.
    /// 이 폴더의 실행이 백그라운드 작업을 기다리는 중이면 그 수를 덧붙인다.
    private func lockText(_ lock: ChangesState.Lock, action: String) -> String {
        ChangesState.lockText(lock, action: action, backgroundTasks: backgroundTasks)
    }

    /// 이 폴더에서 메인 턴을 마치고 기다리는 백그라운드 작업 수.
    private var backgroundTasks: Int { model.backgroundTaskCount(inProjectPath: model.selectedProject?.path ?? "") }

    static func elapsed(from start: Date, to now: Date) -> String {
        DisplayFormat.elapsed(seconds: Int(now.timeIntervalSince(start)))
    }

    // MARK: 변경 없음

    private func cleanState(_ git: GitWorkspaceStatus) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Theme.slate3)
            Text("커밋할 변경이 없습니다")
                .font(Theme.ui(.callout, .semibold))
                .foregroundStyle(Theme.ink2)
            Text("파일이 바뀌면 여기에 나타납니다. 에이전트가 고친 파일에는 그 에이전트 표시가 붙습니다.")
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate)
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            TimelineView(.everyMinute) { context in
                Group {
                    if let commit = git.lastCommit {
                        Text("마지막 커밋 \(commit.shortHash)"
                             + (commit.date.map { " · " + ChangesState.relativeTime($0, now: context.date) } ?? ""))
                            .help(commit.subject)
                    } else if git.noCommitsYet {
                        Text("아직 커밋이 없습니다")
                    }
                }
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.slate2)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 28)
        .padding(.top, 56)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
    }

    // MARK: 목록 머리

    private func searchVisible(_ count: Int) -> Bool {
        count > ChangesState.searchThreshold || searchRequested || !query.isEmpty
    }

    private func consumeSearchRequest() {
        guard model.changesSearchFocusRequested else { return }
        model.changesSearchFocusRequested = false
        // 찾기 칸은 목록 위에 있다 — 좁은 패널 diff 가 목록을 가리고 있으면 목록으로 돌아간다.
        if model.narrowDiffShown { model.closeDiff() }
        searchRequested = true
        // 칸이 막 나타난 경우가 있어 한 박자 뒤에 포커스한다.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            searchFocused = true
        }
    }

    /// 머리 체크박스 · 선택 해제는 **보이는 행**에 대해 동작한다. 찾는 중이면 찾은 파일만이라 이름도 그렇게 바꾼다.
    /// `integrating`(병합 · rebase 중)이면 빼기를 하지 않는다 — 머리 체크박스는 넣기만, "선택 해제" 는 두지 않는다.
    private func listHeader(_ rows: [ChangesState.Row], filtered: Bool, lock: ChangesState.Lock?,
                            integrating: Bool) -> some View {
        let state = ChangesState.headerState(rows)
        let included = ChangesState.includedCount(rows)
        let blocked = isBlockingLock(lock)
        let busy = model.runningGitOperation != nil
        let noCheckable = !rows.contains(where: \.isCheckable)
        let operation = ChangesState.headerToggleOperation(rows, merging: integrating)
        let removes: Bool = {
            if case .unstage? = operation { return true }
            return false
        }()
        let help: String = {
            if blocked { return lock.map { lockText($0, action: "선택할") } ?? "" }
            let scope = filtered ? "찾은 파일을 모두" : "모든 변경을"
            if integrating && operation == nil {
                return "병합 · rebase 중에는 커밋에서 뺄 수 없습니다 — 빼면 합쳐진 변경이 기록에서 빠집니다."
            }
            return removes ? "\(scope) 커밋에서 빼기 (git restore --staged)" : "\(scope) 커밋에 포함 (git add)"
        }()
        return HStack(spacing: 8) {
            Button {
                if let operation { Task { await model.runGit(operation) } }
            } label: {
                HStack(spacing: 8) {
                    IncludeCheckbox(state: state, dimmed: blocked || noCheckable)
                    Text(filtered ? "찾은 파일 모두 선택" : "전체 선택")
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                        .opacity(blocked ? 0.5 : 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(blocked || busy || noCheckable || operation == nil)
            .help(help)
            .accessibilityValue(state.spokenValue)
            Spacer(minLength: 6)
            if included > 0 && !integrating {
                Button("선택 해제") {
                    if let operation = ChangesState.deselectAllOperation(rows) {
                        Task { await model.runGit(operation) }
                    }
                }
                .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
                .disabled(blocked || busy)
                .opacity(blocked ? 0.5 : 1)
                .help(filtered ? "찾은 파일을 모두 커밋에서 뺍니다. 파일 내용은 그대로입니다 (git restore --staged)"
                      : "모든 파일을 커밋에서 뺍니다. 파일 내용은 그대로입니다 (git restore --staged)")
                MetaDot()
            }
            Text(filtered ? "찾은 \(rows.count)개 중 \(included)개 포함" : "\(rows.count)개 중 \(included)개 포함")
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairSoft).frame(height: 1) }
    }

    private func toggle(_ row: ChangesState.Row, integrating: Bool) {
        guard let operation = ChangesState.toggleOperation(for: row, merging: integrating) else { return }
        selectedPath = row.path
        pendingPath = row.path
        Task {
            await model.runGit(operation)
            if pendingPath == row.path { pendingPath = nil }
        }
    }

    // MARK: - 커밋 독

    /// 커밋 메시지 초안 — 폴더마다 따로 (같은 프로젝트의 독립 작업 폴더도 따로, chg-8).
    private var draft: Binding<String> {
        Binding(get: { model.selectedProject.map { model.commitDraft(forFolder: $0.path) } ?? "" },
                set: { text in
                    if let path = model.selectedProject?.path { model.setCommitDraft(text, forFolder: path) }
                })
    }

    /// 이 프로젝트에서 마지막 git 명령이 실패한 커밋이면 그 결과.
    private var commitFailure: AppModel.GitOutcomeRecord? {
        guard let record = model.lastGitOutcome, !record.outcome.succeeded,
              record.projectPath == model.selectedProject?.path,
              case .commit = record.operation else { return nil }
        return record
    }

    private func commitDock(_ git: GitWorkspaceStatus, rows: [ChangesState.Row], included: Int,
                            primary: ChangesState.Primary, lock: ChangesState.Lock?) -> some View {
        let committing: Bool = {
            if case .commit? = model.runningGitOperation { return true }
            return false
        }()
        let conflicts = rows.filter { $0.inclusion == .conflict }.count
        // 다른 git 명령(체크 한 번의 stage 등)이 도는 잠깐 동안은 누를 수 없게만 하고, 잠금 문구 · 흐린 모양으로
        // 바꾸지 않는다 (`ChangesState.visibleLock`). 체크할 때마다 독이 깜빡이지 않게.
        let otherGitRunning = model.runningGitOperation != nil && !committing
        // 업로드 · 받기 · 원격 확인은 몇 초씩 걸리고 바닥에 "끝날 때까지 막아 둡니다" 가 보인다 — 그동안은 꺼진 모양으로.
        let remoteRunning = runningSyncProgress(git) != nil
        let block = ChangesState.commitBlock(lock: committing ? nil : ChangesState.visibleLock(lock),
                                             conflictCount: conflicts,
                                             includedCount: included, message: draft.wrappedValue,
                                             merging: git.isMerging, rebasing: git.isRebasing)
        let owner = ChangesState.returnKeyOwner(commitFieldFocused: commitFocused,
                                                cardFieldFocused: model.handoffCardFocusThreadID != nil)
        return VStack(alignment: .leading, spacing: 8) {
            if let targetChange { targetChangeNote(targetChange, standalone: false) }
            HStack(spacing: 5) {
                SectionLabel("커밋")
                Spacer(minLength: 6)
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.slate2)
                CappedWidth(max: 230) {
                    Text(git.headLabel ?? "브랜치 미확인")
                        .font(Theme.mono(.caption))
                        .foregroundStyle(Theme.slate)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(git.headLabel ?? "")
            }
            messageField
            Button(action: commit) {
                if committing {
                    HStack(spacing: 7) {
                        InkSpinner()
                        Text("커밋하는 중…")
                    }
                } else {
                    HStack(spacing: 7) {
                        Text("선택한 변경 커밋")
                        // 단축키 표시는 실제로 ⌘↵ 가 이 버튼에 걸려 있을 때만 (메시지 칸 포커스).
                        // 그 밖에는 ⌘↵ 가 입력창의 보내기라, 두 곳에 같은 표시가 보이지 않게 한다.
                        if block == nil && owner == .commit {
                            Text("⌘↵").font(Theme.mono(.caption)).opacity(0.6)
                        }
                    }
                }
            }
            .buttonStyle(DockButtonStyle(busy: committing, holdsInk: otherGitRunning && !remoteRunning && block == nil))
            .disabled(block != nil || committing || otherGitRunning)
            // ⌘↵ 는 메시지 칸에 포커스가 있을 때만 커밋이 받는다. 그동안 입력창의 보내기는 단축키를 내려놓는다
            // (`ChangesState.returnKeyOwner` — 둘이 동시에 갖는 경우가 없다).
            .keyboardShortcut(owner == .commit ? KeyboardShortcut(.return, modifiers: .command) : nil)
            .help(commitBlockHelp(block)
                  + (git.isMerging ? "병합 중에는 이 커밋이 병합 커밋이 되어 병합을 마무리합니다. " : "")
                  + "체크한 파일만 커밋합니다 (git commit -F -, 메시지는 stdin). "
                  + "사용자의 git 설정(이름 · 서명 · 훅)을 그대로 따릅니다. 메시지 칸에서 ⌘↵")
            commitFoot(block: block, committing: committing, included: included, merging: git.isMerging)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
    }

    /// 커밋 단추가 꺼진 까닭 (도움말 앞머리). 켜져 있으면 빈 글.
    private func commitBlockHelp(_ block: ChangesState.CommitBlock?) -> String {
        switch block {
        case .locked(let lock)?: return lockText(lock, action: "커밋할") + " "
        case .rebasing?: return "rebase 중에는 앱에서 커밋하지 않습니다. "
        case .conflicts(let n)?: return "충돌 파일 \(n)개를 먼저 해결하세요. "
        case .noSelection?: return "커밋할 파일을 먼저 체크하세요. "
        case .noMessage?: return "커밋 메시지를 먼저 입력하세요. "
        case nil: return ""
        }
    }

    private var messageField: some View {
        // 숨긴 Text 가 높이를 정하고 편집기는 그 위에 겹친다 (52pt 에서 시작해 내용만큼, 최대 110pt).
        Text(draft.wrappedValue.isEmpty ? " " : draft.wrappedValue + " ")
            .font(Theme.ui(.callout))
            .lineSpacing(3)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
            .hidden()
            .frame(maxHeight: 94)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: draft)
                        .font(Theme.ui(.callout))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.ink)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .focused($commitFocused)
                        .plainTextInput()
                        .accessibilityLabel("커밋 메시지")
                    if draft.wrappedValue.isEmpty {
                        Text("어떤 변경을 했나요?")
                            .font(Theme.ui(.callout))
                            .foregroundStyle(Theme.slate2)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            // 입력창과 같은 채움 상자 — 테두리 없이, 포커스는 시스템 포커스 링으로만.
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
            .overlay {
                if commitFocused {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor).opacity(0.55), lineWidth: 3)
                        .padding(-2)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private func commitFoot(block: ChangesState.CommitBlock?, committing: Bool, included: Int,
                            merging: Bool) -> some View {
        if committing {
            Text(merging ? "병합 커밋을 기록하고 있습니다." : "선택한 파일 \(included)개의 변경을 기록하고 있습니다.")
                .font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
        } else if case .locked(let lock)? = block {
            // 잠금은 실패 표시보다 먼저 — 버튼이 왜 꺼져 있는지가 우선이다.
            ReasonLine(systemImage: "lock", iconColor: Theme.amber,
                       text: lockText(lock, action: "커밋할") + " 메시지는 미리 써 둘 수 있습니다.")
        } else if let failure = commitFailure {
            // 이유는 `GitFailure` 가 분류한다 (커밋할 것 없음 · 신원 미설정, 그 밖은 git 의 한 줄을 그대로).
            let explanation = failure.failure?.explanation(for: failure.operation)
                ?? GitFailure.Explanation(title: "커밋하지 못했습니다", detail: GitFailure.noOutputLine, verbatim: true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.danger)
                    Text(explanation.title).font(Theme.ui(.caption, .semibold)).foregroundStyle(Theme.ink)
                }
                Text(explanation.detail)
                    .font(explanation.verbatim ? Theme.mono(.caption) : Theme.ui(.caption))
                    .foregroundStyle(explanation.verbatim ? Theme.ink2 : Theme.slate)
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text("메시지와 선택은 그대로입니다.")
                    .font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
                Button("출력 보기") { showingOutput = true }
                    .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
                    .padding(.top, 2)
                    .popover(isPresented: $showingOutput, arrowEdge: .top) {
                        GitOutputView(command: failure.outcome.command, output: failure.outcome.output)
                    }
            }
            .leadingRule(Theme.danger, width: 2, gap: 11)
        } else if let block {
            switch block {
            case .locked(let lock):
                ReasonLine(systemImage: "lock", iconColor: Theme.amber,
                           text: lockText(lock, action: "커밋할") + " 메시지는 미리 써 둘 수 있습니다.")
            case .rebasing:
                // 앱의 커밋은 멈춘 커밋을 대신하는 새 커밋이 된다. 이어가기는 git 이 원래 메시지로 커밋한다.
                ReasonLine(systemImage: "info.circle",
                           text: "rebase 중에는 앱에서 커밋하지 않습니다. 터미널에서 git rebase --continue 로 이어가세요.")
            case .conflicts(let n):
                // 내용을 고친 뒤에도 git add 로 해결했다고 표시하기 전까지는 충돌로 남는다 (앱은 충돌 행을 스테이지하지 않는다).
                // 위의 충돌 안내가 방법을 적으므로 여기서는 버튼이 왜 꺼졌는지만.
                let message = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                ReasonLine(systemImage: "info.circle",
                           text: "충돌 파일 \(n)개를 먼저 해결하세요. "
                               + (message.isEmpty ? "해결하면 커밋할 수 있습니다." : "해결하면 이 메시지로 커밋할 수 있습니다."))
            // 단추가 왜 꺼져 있는지 짧게 늘 보인다 — 처음 쓰는 사람은 회색 단추만으로는 모른다 (chg-19).
            case .noSelection:
                ReasonLine(systemImage: "info.circle", text: "커밋할 파일을 체크하세요 — 체크한 파일만 기록됩니다.")
            case .noMessage:
                ReasonLine(systemImage: "info.circle", text: "커밋 메시지를 입력하세요 — 어떤 변경인지 한 줄이면 됩니다.")
            }
        } else if merging {
            // 병합 중(MERGE_HEAD)의 커밋은 병합 커밋이 된다 — git 의 정상 동작이다 (새 명령이 아니다).
            Text(included > 0 ? "병합 커밋을 만들어 병합을 마무리합니다. 선택한 파일 \(included)개가 함께 기록됩니다."
                              : "병합 커밋을 만들어 병합을 마무리합니다. 선택한 파일이 없어 내용 변경 없이 기록됩니다.")
                .font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
                .lineLimit(2)
        } else {
            Text("선택한 파일 \(included)개의 변경을 로컬 기록에 남깁니다.")
                .font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
        }
    }

    private func commit() {
        let message = draft.wrappedValue
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.runningGitOperation == nil else { return }
        // "이제 X 에 커밋됩니다" 안내는 커밋하면 할 일을 다 했다.
        targetChange = nil
        Task { await model.commitStaged(message: message) }
    }

    /// 확인 창이 열린 동안 대상이 바뀐 것을 한 번 알린다 (목업 SyncVariants "대상이 바뀌었을 때"): amber 규칙선 ·
    /// 브랜치(폴더) 아이콘 · "이전 → 지금 · …" · "확인" 으로 닫음. 커밋 독이 없으면(변경 없음) 동기화 자리 위에 따로.
    @ViewBuilder
    private func targetChangeNote(_ change: ChangesState.TargetChange, standalone: Bool) -> some View {
        let notice = ChangesState.targetChangeNotice(change)
        let note = VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: change.projectChanged ? "folder" : "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                    .frame(width: 13)
                Text(notice.title)
                    .font(Theme.ui(.caption, .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 6)
                Button("확인") { targetChange = nil }
                    .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
                    .help("안내를 닫습니다")
            }
            (Text(notice.from).font(Theme.mono(.caption))
             + Text(" → ")
             + Text(notice.to).font(Theme.mono(.caption, .semibold)).foregroundStyle(Theme.ink2)
             + Text(" · " + notice.rest))
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate)
                .lineSpacing(2.5)
                // 바닥에 고정된 독 안이라 높이를 글자에 맡기지 않고 줄 수로 막는다 (fixedSize 는 창 최소 높이를 밀어 올렸다 — 실측).
                .lineLimit(4)
        }
        .padding(.vertical, 1)
        .leadingRule(Theme.amber, width: 2, gap: 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        if standalone {
            note
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 10)
                .background(Theme.panel)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
        } else {
            note.padding(.bottom, 2)
        }
    }

    // MARK: - 동기화 행

    private struct SyncDisplay {
        enum Lead { case up, down, done, cloud, fork, warn, same, detachedHead, question, spinner }
        /// `publish` 의 `onRemote` = 마지막 fetch 기준으로 origin 에 같은 이름 브랜치가 있는지 (nil 은 모름).
        enum Action { case upload(Int), publish(onRemote: Bool?), pull(Int), mergeInTerminal }
        var lead: Lead
        var title: Text
        var sub: String?
        var action: Action?
        /// 주 버튼 (잉크 · 전체 폭, 아래에 설명 한 줄).
        var stacked = false
        var helper: String?
        /// 방금 만든 커밋 한 줄 (쌓인 모양에서 제목 아래).
        var commitLine: String?
        /// 원격 명령이 도는 동안 — 버튼을 누를 수 없다 (목업 "진행 중" 의 비활성 버튼).
        var actionLocked = false
    }

    /// 이 프로젝트에서 도는 원격 명령과 그 사실 문구 (목업 SyncVariants "진행 중"). 다른 프로젝트의 명령이면 nil.
    private func runningSyncProgress(_ git: GitWorkspaceStatus) -> ChangesState.SyncProgress? {
        guard let operation = model.runningGitOperation, operation.talksToRemote,
              model.runningGitProjectPath == model.selectedProject?.path else { return nil }
        let remote = GitWorkspace.remoteName(for: operation, upstream: git.upstream, remotes: git.remotes)
        return ChangesState.syncProgress(operation, ahead: git.ahead, upstream: git.upstream, remoteName: remote)
    }

    /// 평상 표시에 진행 중 문구를 덮는다. 모양(쌓임 · 한 줄)은 그대로 둬 자리가 뛰지 않게 한다.
    private func progressDisplay(_ base: SyncDisplay, _ progress: ChangesState.SyncProgress) -> SyncDisplay {
        var d = base
        d.lead = .spinner
        d.title = Text(progress.title)
        d.commitLine = nil
        d.actionLocked = true
        // 한 줄 모양의 부제는 고정폭 한 줄이라 대상만 쓰고, 막아 둔다는 사실은 그 아래 따로 (잘리지 않게).
        if d.stacked {
            d.helper = progress.detail
        } else {
            d.sub = progress.target
            d.helper = ChangesState.SyncProgress.blockingNote
        }
        return d
    }

    /// 방금 끝난 업로드 · 게시 · 받기 (이 프로젝트, 명령 뒤 상태 그대로). 몇 초 뒤에는 nil — `ChangesState.syncSuccess`.
    private func syncSuccessDisplay(_ git: GitWorkspaceStatus, sync: ChangesState.Sync) -> SyncDisplay? {
        guard let record = model.lastGitOutcome, record.outcome.succeeded, record.operation.talksToRemote,
              record.projectPath == model.selectedProject?.path,
              ChangesState.recordIsCurrent(recorded: record.context, now: git) else { return nil }
        // "PR #n에 반영됐습니다" 는 GitHub 쪽 사실이라 최근에 조회한 PR 일 때만 (오래된 캐시면 그 사이 병합 · 닫힘을 모른다).
        let pr = ChangesState.freshPullRequest(
            ChangesState.pullRequestReceivingPush(model.workspace.pullRequest.info,
                                                  branch: record.contextBefore?.branch ?? git.branch,
                                                  upstream: sync.upstream),
            checkedAt: model.workspace.pullRequestCheckedAt, now: Date())
        guard let success = ChangesState.syncSuccess(record.operation, pushedCount: record.contextBefore?.ahead,
                                                     after: sync, pullRequest: pr, finishedAt: record.finishedAt,
                                                     now: Date()) else { return nil }
        let done = Text(success.done).fontWeight(.semibold).foregroundStyle(Theme.emeraldText)
        let title = success.title.map { done + Text(" · ").foregroundStyle(Theme.slate3) + Text($0) } ?? done
        return SyncDisplay(lead: .done, title: title, sub: success.sub)
    }

    /// 성공 표시가 끝나는 시각 (그때 한 번 다시 그린다). 없으면 nil.
    private var successDeadline: Date? {
        guard let record = model.lastGitOutcome, record.outcome.succeeded, record.operation.talksToRemote,
              record.projectPath == model.selectedProject?.path else { return nil }
        return record.finishedAt.addingTimeInterval(ChangesState.successDisplaySeconds)
    }

    private func count(_ prefix: String, _ n: Int, _ suffix: String) -> Text {
        Text(prefix) + Text("\(n)").fontWeight(.semibold).foregroundStyle(Theme.ink) + Text(suffix)
    }

    private func syncDisplay(_ git: GitWorkspaceStatus, sync: ChangesState.Sync, primary: ChangesState.Primary,
                             justCommitted: Bool) -> SyncDisplay {
        let pr = ChangesState.pullRequestReceivingPush(model.workspace.pullRequest.info, branch: git.branch,
                                                       upstream: sync.upstream)
        let branch = git.branch ?? ""
        var d: SyncDisplay
        switch sync {
        case .ahead(let upstream, let n):
            if primary == .upload {
                d = SyncDisplay(lead: .up, title: count("업로드할 커밋 ", n, "개"), action: .upload(n), stacked: true,
                                helper: "추적 브랜치(\(upstream))로 올립니다." + (pr.map { " 올리면 PR #\($0)에 반영됩니다." } ?? ""))
            } else {
                d = SyncDisplay(lead: .up, title: count("업로드할 커밋 ", n, "개"),
                                sub: "→ \(upstream)" + (pr.map { " · PR #\($0)에 반영" } ?? ""), action: .upload(n))
            }
        case .inSync(let upstream):
            d = SyncDisplay(lead: .same, title: Text("원격과 같습니다"), sub: "\(upstream) · 올릴 커밋 없음")
        case .behind(let upstream, let n):
            if primary == .pull {
                // `git pull --ff-only` 는 겹치는 로컬 변경이 있으면 받지 않고 멈춘다 — 그때 이유를 이 자리에 보여준다.
                // n 은 마지막 확인 기준이다. 받을 때 git 이 원격을 다시 확인하므로 그 뒤 올라온 커밋도 함께 온다
                // — 받을 개수로 단정하지 않는다.
                d = SyncDisplay(lead: .down, title: count("원격에 새 커밋 ", n, "개"), action: .pull(n), stacked: true,
                                helper: "\(upstream) 의 커밋을 이 브랜치에 반영합니다. 받을 때 git 이 원격을 다시 확인해 "
                                    + "그 뒤 올라온 커밋도 함께 받습니다. 내 파일과 겹치면 받지 않고 알려드립니다.")
            } else {
                // 좁은 폭에서도 잘리지 않게 짧게 쓰고, 설명은 칩의 도움말에 둔다.
                d = SyncDisplay(lead: .down, title: count("원격에 새 커밋 ", n, "개"),
                                sub: "← \(upstream)", action: .pull(n))
            }
        case .diverged(_, let ahead, let behind):
            // 주 버튼일 때는 규칙선 안내와 함께 따로 그린다 (`divergedBlock`). 여기는 커밋이 주 버튼일 때의 한 줄.
            // 추적 브랜치 이름은 요약의 메타 줄에 있다 (좁은 폭에서 칩 옆에 두면 이름이 잘려 읽히지 않는다).
            d = SyncDisplay(lead: .fork, title: Text("기록이 갈라졌습니다").foregroundStyle(Theme.amberText),
                            sub: "올릴 \(ahead) · 받을 \(behind)", action: .mergeInTerminal)
        case .noUpstream(let publish):
            switch publish {
            case .available(let onRemote):
                // 원격에 같은 이름 브랜치가 (마지막 fetch 기준) 있으면 "만든다" 고 하지 않는다.
                let title: Text
                let helper: String
                let sub: String
                switch onRemote {
                case false?:
                    title = Text("이 브랜치는 아직 원격에 없습니다")
                    helper = "origin 에 브랜치(\(branch))를 만들고 커밋을 올립니다. 이후 업로드는 이 브랜치로 갑니다."
                    sub = "→ origin/\(branch) (새로 만듦)"
                case true?:
                    title = Text("추적 설정이 없습니다 · origin/\(branch) 있음")
                    helper = "origin/\(branch) 에 올리고 추적을 설정합니다. 기록이 다르면 git 이 거부합니다."
                    sub = "→ origin/\(branch) (추적 설정)"
                case nil:
                    title = Text("추적하는 원격 브랜치가 없습니다")
                    helper = "origin/\(branch) 에 올리고 추적을 설정합니다. 이후 업로드는 이 브랜치로 갑니다."
                    sub = "→ origin/\(branch) · 원격 브랜치 목록 미확인"
                }
                if let target = worktreeTarget(git) {
                    // 독립 작업 폴더의 대화 브랜치 — 보통 올리지 않고 위 칸에서 합친다. 올릴 수는 있게 흰 칩으로만 둔다 (chg-2).
                    d = SyncDisplay(lead: .cloud, title: Text("이 대화의 브랜치는 보통 올리지 않습니다"),
                                    sub: "위 칸에서 \(target) 에 합칩니다", action: .publish(onRemote: onRemote))
                } else if primary == .publish {
                    d = SyncDisplay(lead: .cloud, title: title, action: .publish(onRemote: onRemote), stacked: true,
                                    helper: helper)
                } else {
                    d = SyncDisplay(lead: .cloud, title: title, sub: sub, action: .publish(onRemote: onRemote))
                }
            case .noOrigin:
                d = SyncDisplay(lead: .cloud, title: Text("추적하는 원격 브랜치가 없습니다"),
                                sub: "origin 원격이 없어 앱에서 업로드하지 않습니다 · 터미널에서 git push -u")
            case .noCommits:
                d = SyncDisplay(lead: .cloud, title: Text("추적하는 원격 브랜치가 없습니다"),
                                sub: "첫 커밋을 만든 뒤 업로드할 수 있습니다")
            case .remotesUnknown:
                d = SyncDisplay(lead: .question, title: Text("추적하는 원격 브랜치가 없습니다"),
                                sub: "원격 목록을 읽지 못했습니다 · ··· 에서 다시 읽기")
            }
        case .noRemote:
            d = SyncDisplay(lead: .cloud, title: Text("원격 저장소가 없습니다"),
                            sub: "이 저장소는 로컬 기록만 있습니다 · 원격 추가는 터미널에서")
        case .upstreamGone(let upstream, let republish):
            // 지워졌는지 처음부터 없었는지(빈 저장소 clone) 앱은 모른다. 원인을 쓰지 않는다.
            let title = Text("추적 브랜치가 원격에 없습니다").foregroundStyle(Theme.amberText)
            if !republish {
                d = SyncDisplay(lead: .warn, title: title,
                                sub: git.noCommitsYet ? "\(upstream) · 첫 커밋을 만든 뒤 올릴 수 있습니다"
                                    : "\(upstream) · 마지막 확인 기준 · 추적 설정은 터미널에서")
            } else if primary == .publish {
                d = SyncDisplay(lead: .warn, title: title, action: .publish(onRemote: false), stacked: true,
                                helper: "origin 에 브랜치(\(branch))를 올리고 추적을 이어갑니다. (\(upstream) · 마지막 확인 기준)")
            } else {
                d = SyncDisplay(lead: .warn, title: title, sub: "→ \(upstream) (새로 만듦)",
                                action: .publish(onRemote: false))
            }
        case .unknown(let upstream):
            d = SyncDisplay(lead: .question, title: Text("원격과 비교하지 못했습니다"),
                            sub: "\(upstream) · 앞섬 · 뒤처짐 미확인")
        case .detached:
            d = SyncDisplay(lead: .detachedHead, title: Text("브랜치가 아닌 커밋을 보고 있습니다"),
                            sub: "\(git.headLabel ?? "HEAD") · 업로드하려면 브랜치를 만드세요")
        case .merging(let upstream):
            // 병합 중에는 동기화 자리를 그리지 않는다 (`changesBody`). 혹시 그려도 사실만.
            d = SyncDisplay(lead: .warn, title: Text("병합 진행 중"),
                            sub: (upstream.map { "추적 \($0) · " } ?? "") + "병합을 마무리한 뒤 올릴 수 있습니다")
        case .rebasing:
            // rebase 중에도 동기화 자리를 그리지 않는다 (`changesBody`). 혹시 그려도 사실만.
            d = SyncDisplay(lead: .warn, title: Text("rebase 진행 중"),
                            sub: "터미널에서 rebase 를 마친 뒤 올릴 수 있습니다")
        }
        // 앱이 방금 만든 커밋이 HEAD 인 동안: "✓ 커밋 완료 · …" 로 결과와 다음 행동을 잇는다.
        if justCommitted, let commit = git.lastCommit {
            let done = Text("커밋 완료").fontWeight(.semibold).foregroundStyle(Theme.emeraldText)
            d.title = done + Text("  ·  ").foregroundStyle(Theme.slate3) + d.title
            d.lead = .done
            let line = "\(commit.shortHash) \(commit.subject)"
            if d.stacked { d.commitLine = line } else { d.sub = line }
        }
        return d
    }

    /// 동기화 자리 (목업 SyncVariants): 진행 중 → 실패 → 성공(몇 초) → 기록 분기 → 평상 순으로 한 가지만.
    @ViewBuilder
    private func syncArea(_ git: GitWorkspaceStatus, sync: ChangesState.Sync, primary: ChangesState.Primary,
                          justCommitted: Bool, lock: ChangesState.Lock?) -> some View {
        let divergedPrimary: String? = {
            if case .diverged(let upstream, _, _) = sync, primary == .mergeInTerminal { return upstream }
            return nil
        }()
        // 성공 표시가 끝나면 이 값이 바뀌어 다시 그린다 (시각만 다시 본다 — git 을 부르지 않는다).
        let _ = successTick
        Group {
            if divergedPrimary == nil, let progress = runningSyncProgress(git) {
                // 업로드 · 게시 · 받기 · 원격 확인이 도는 동안: 무엇을 어디로 하는지와 다른 git 동작을 막아 둔다는 사실.
                // 기록 분기 화면(터미널에서 합치기)은 git 명령 버튼이 없어 그대로 둔다 (원격 확인은 머리줄 구름이 돈다).
                syncRow(progressDisplay(syncDisplay(git, sync: sync, primary: primary, justCommitted: justCommitted),
                                        progress), git: git, lock: lock)
            } else if let record = syncFailure(git) {
                // 업로드 · 받기 · 원격 확인이 실패했으면 그 이유와 다음 행동이 이 자리를 차지한다 (목업 SyncVariants 실패).
                syncFailureNote(record, git: git, lock: lock)
            } else if let success = syncSuccessDisplay(git, sync: sync) {
                // "업로드 완료 · origin/x 이 최신입니다" — 몇 초 뒤 평상 상태("원격과 같습니다")로 돌아간다.
                syncRow(success, git: git, lock: lock)
            } else if let upstream = divergedPrimary {
                divergedBlock(upstream: upstream)
            } else {
                syncRow(syncDisplay(git, sync: sync, primary: primary, justCommitted: justCommitted),
                        git: git, lock: lock)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
        .task(id: successDeadline) {
            guard let deadline = successDeadline else { return }
            // 표시 여부는 벽시계(`Date`)로 보므로 벽시계로 끝날 때까지 기다린다 (잠드는 시계와 조금 어긋나도 남지 않게).
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow + 0.05))
            }
            if !Task.isCancelled { successTick += 1 }
        }
    }

    @ViewBuilder
    private func syncRow(_ d: SyncDisplay, git: GitWorkspaceStatus, lock: ChangesState.Lock?) -> some View {
        if d.stacked {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    leadIcon(d.lead)
                    d.title.lineLimit(1)
                }
                .font(Theme.ui(.callout))
                .foregroundStyle(Theme.ink2)
                if let line = d.commitLine {
                    Text(line)
                        .font(Theme.mono(.caption))
                        .foregroundStyle(Theme.slate2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 19)
                }
                if let action = d.action {
                    actionButton(action, git: git, stacked: true, lock: lock, locked: d.actionLocked)
                }
                if let helper = d.helper {
                    Text(helper)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate)
                        .lineSpacing(2)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
        } else {
            // 진행 중이면 막아 둔다는 사실(`helper`)이 행 아래 한 줄로 붙는다.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            leadIcon(d.lead)
                            d.title.lineLimit(1)
                        }
                        .font(Theme.ui(.callout))
                        .foregroundStyle(Theme.ink2)
                        if let sub = d.sub {
                            Text(sub)
                                .font(Theme.mono(.caption))
                                .foregroundStyle(Theme.slate2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.leading, 18)
                                .help(sub)
                        }
                    }
                    Spacer(minLength: 6)
                    if let action = d.action {
                        actionButton(action, git: git, stacked: false, lock: lock, locked: d.actionLocked)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, d.helper == nil ? 11 : 4)
                if let helper = d.helper {
                    Text(helper)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate)
                        .lineLimit(2)
                        .padding(.leading, 32)
                        .padding(.trailing, 14)
                        .padding(.bottom, 11)
                }
            }
        }
    }

    @ViewBuilder
    private func leadIcon(_ lead: SyncDisplay.Lead) -> some View {
        Group {
            switch lead {
            case .up: Image(systemName: "arrow.up").foregroundStyle(Theme.slate)
            case .down: Image(systemName: "arrow.down").foregroundStyle(Theme.slate)
            case .done, .same: Image(systemName: "checkmark").foregroundStyle(Theme.emerald)
            case .cloud: Image(systemName: "icloud").foregroundStyle(Theme.slate)
            case .fork: ForkGlyph(color: Theme.amber, size: 12, lineWidth: 1.5)
            case .warn: Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.amber)
            case .detachedHead: Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.slate)
            case .question: Image(systemName: "questionmark.circle").foregroundStyle(Theme.slate2)
            case .spinner: InkSpinner(color: Theme.slate)
            }
        }
        .font(Theme.ui(.caption, .semibold))
        .frame(width: 12)
    }

    /// `locked` = 이 프로젝트의 원격 명령이 도는 중 (진행 중 표시) — 누를 수 없다.
    @ViewBuilder
    private func actionButton(_ action: SyncDisplay.Action, git: GitWorkspaceStatus, stacked: Bool,
                              lock: ChangesState.Lock?, locked: Bool) -> some View {
        let pushing: Bool = {
            if case .push? = model.runningGitOperation,
               model.runningGitProjectPath == model.selectedProject?.path { return true }
            return false
        }()
        // 도는 동안의 버튼 글자는 진행 문구와 같은 곳에서 (`ChangesState.syncProgress`).
        let busyLabel = runningSyncProgress(git)?.buttonLabel
        switch action {
        case .upload(let n):
            pushButton(label: pushing ? busyLabel ?? "업로드 중…" : "커밋 \(n)개 업로드",
                       operation: .push(branch: git.branch ?? "", setUpstream: false),
                       stacked: stacked, busy: pushing, locked: locked, git: git, lock: lock)
        case .publish:
            pushButton(label: pushing ? busyLabel ?? "업로드 중…" : "브랜치 업로드",
                       operation: .push(branch: git.branch ?? "", setUpstream: true),
                       stacked: stacked, busy: pushing, locked: locked, git: git, lock: lock)
        case .pull:
            pullButton(git: git, stacked: stacked, locked: locked, lock: lock)
        case .mergeInTerminal:
            HStack(spacing: 8) {
                terminalChip("터미널에서 합치기",
                             help: "이 폴더를 터미널에서 엽니다. 같은 브랜치에 서로 다른 커밋이 쌓여 있어 합친 다음 "
                                 + "업로드해야 합니다. 앱은 원격 기록과 합치거나 강제로 업로드하지 않습니다.")
                mergeHowToButton(upstream: git.upstream, font: Theme.ui(.caption))
            }
        }
    }

    /// 업로드 · 게시 버튼과 확인 팝오버. 확인 뒤에만 `runGit(.push, confirmed: true)`.
    /// 다른 git 명령이 도는 잠깐(`.gitRunning`)은 버튼 모양을 바꾸지 않는다 — 확인 창의 버튼만 그동안 막힌다.
    @ViewBuilder
    private func pushButton(label: String, operation: GitWrite.Operation, stacked: Bool, busy: Bool, locked: Bool,
                            git: GitWorkspaceStatus, lock: ChangesState.Lock?) -> some View {
        let visible = ChangesState.visibleLock(lock)
        let presented = Binding(get: { confirmingPush == operation && !busy },
                                set: { if !$0 { confirmingPush = nil } })
        let button = Button {
            confirmingPush = operation
        } label: {
            HStack(spacing: 6) {
                if busy {
                    InkSpinner(color: stacked ? Theme.slate2 : Theme.slate)
                } else if stacked {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                }
                Text(label)
            }
        }
        .disabled(visible != nil || busy || locked)
        .help(visible.map { lockText($0, action: "업로드할") } ?? "확인 뒤 git push (--force 는 쓰지 않습니다)")
        .popover(isPresented: presented, arrowEdge: .top) {
            syncConfirm(operation, git: git, lock: lock) { confirmingPush = nil }
        }
        if stacked {
            button.buttonStyle(DockButtonStyle())
        } else {
            button.buttonStyle(ChipButtonStyle(height: 26))
        }
    }

    /// 원격 변경 받기 버튼과 확인 팝오버 (README: pull 은 확인을 받는다). 확인 뒤에만 `runGit(.pull, confirmed: true)`.
    @ViewBuilder
    private func pullButton(git: GitWorkspaceStatus, stacked: Bool, locked: Bool,
                            lock: ChangesState.Lock?) -> some View {
        // 다른 git 명령이 도는 잠깐은 흐리게 바꾸지 않는다 (확인 창의 받기는 그동안 runGit 이 실행하지 않는다).
        let visible = ChangesState.visibleLock(lock)
        let pulling = model.runningGitOperation == .pull && model.runningGitProjectPath == model.selectedProject?.path
        let presented = Binding(get: { confirmingPull && !pulling }, set: { if !$0 { confirmingPull = false } })
        let button = Button {
            confirmingPull = true
        } label: {
            HStack(spacing: 6) {
                if pulling {
                    InkSpinner(color: stacked ? Theme.slate2 : Theme.slate)
                } else if stacked {
                    Image(systemName: "arrow.down").font(.system(size: 11, weight: .bold))
                }
                Text(pulling ? runningSyncProgress(git)?.buttonLabel ?? "받는 중…" : "원격 변경 받기")
            }
        }
        .disabled(visible != nil || pulling || locked)
        .help(visible.map { lockText($0, action: "받을") }
              ?? "확인 뒤 git pull --ff-only — 병합 커밋을 만들지 않습니다. 내 파일과 겹치면 받지 않습니다.")
        .popover(isPresented: presented, arrowEdge: .top) {
            syncConfirm(.pull, git: git, lock: lock) { confirmingPull = false }
        }
        if stacked {
            button.buttonStyle(DockButtonStyle())
        } else {
            button.buttonStyle(ChipButtonStyle(height: 26))
        }
    }

    /// 업로드 · 게시 · 받기 확인 창 (목업 SyncVariants "업로드 확인" 형식: 제목 · 커밋 목록 · 대상 · 취소 · 확인).
    @ViewBuilder
    private func syncConfirm(_ operation: GitWrite.Operation, git: GitWorkspaceStatus, lock: ChangesState.Lock?,
                             close: @escaping () -> Void) -> some View {
        let run = {
            close()
            Task { await model.runGit(operation, confirmed: true, reportsInline: true) }
        }
        switch operation {
        case .push(let branch, true):
            let onRemote: Bool? = {
                if case .noUpstream(.available(let onRemote)) = ChangesState.sync(git) { return onRemote }
                return false
            }()
            SyncConfirmView(title: "브랜치를 업로드할까요?", from: branch, to: "origin/\(branch)",
                            note: publishNote(branch: branch, onRemote: onRemote), confirmLabel: "업로드",
                            canConfirm: lock == nil, onConfirm: run, onCancel: close)
        case .push(let branch, false):
            let n = git.ahead ?? 0
            SyncConfirmView(title: n > 0 ? "커밋 \(n)개를 업로드할까요?" : "업로드할까요?",
                            commits: git.outgoingCommits, total: git.ahead, from: branch, to: git.upstream ?? "",
                            note: "팀원도 이 커밋을 볼 수 있게 됩니다.", confirmLabel: "업로드",
                            canConfirm: lock == nil, pushDefaultDirectory: model.selectedProject?.url,
                            onConfirm: run, onCancel: close)
        case .pull:
            // 목록 · 개수는 마지막 확인(fetch) 기준이다. `pull` 은 받기 전에 원격을 다시 확인하므로 그 뒤 올라온
            // 커밋도 함께 받는다 — 제목과 안내에 그 기준을 밝힌다 (받을 개수로 단정하지 않는다).
            let n = git.behind ?? 0
            SyncConfirmView(title: n > 0 ? "마지막 확인 기준 커밋 \(n)개를 받을까요?" : "원격 변경을 받을까요?",
                            commits: git.incomingCommits, total: git.behind,
                            from: git.upstream ?? "추적 브랜치", to: git.branch ?? "",
                            basis: "받을 때 git 이 원격을 다시 확인해, 마지막 확인 뒤 올라온 커밋도 함께 받습니다.",
                            note: "git pull --ff-only — 병합 커밋을 만들지 않습니다. 내 파일과 겹치면 받지 않습니다.",
                            confirmLabel: "받기", canConfirm: lock == nil, onConfirm: run, onCancel: close)
        default:
            EmptyView()
        }
    }

    private func publishNote(branch: String, onRemote: Bool?) -> String {
        switch onRemote {
        case false?: return "origin 에 이 브랜치를 만듭니다. 팀원도 볼 수 있게 됩니다."
        case true?: return "이미 있는 origin/\(branch) 에 올리고 추적을 설정합니다. 기록이 다르면 git 이 거부합니다."
        case nil: return "origin/\(branch) 에 올리고 추적을 설정합니다. 팀원도 볼 수 있게 됩니다."
        }
    }

    // MARK: 기록 분기

    /// 기록 분기가 화면의 주 상태일 때 (내 변경을 커밋할 것이 없을 때): 규칙선 안내 + 잉크 "터미널에서 합치기".
    /// 업로드 · 받기 버튼은 두지 않는다 — 업로드는 거절되고 `pull --ff-only` 는 반드시 실패한다.
    private func divergedBlock(upstream: String) -> some View {
        let root = model.workspace.projectURL
        return VStack(alignment: .leading, spacing: 10) {
            RuleNote(systemImage: ForkGlyph.symbolName, tint: Theme.amber,
                     title: "로컬과 원격 기록이 갈라졌습니다",
                     detail: "같은 브랜치에 서로 다른 커밋이 쌓였습니다. 이대로는 업로드도, 받기도 할 수 없습니다. "
                         + "두 기록을 합친 다음 업로드하세요. 앱은 원격 기록과 합치거나 강제로 업로드하지 않습니다.")
            HStack(spacing: 10) {
                Button {
                    if let root { TerminalLauncher.open(root) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "terminal").font(.system(size: 11, weight: .semibold))
                        Text("터미널에서 합치기")
                    }
                }
                .buttonStyle(DockButtonStyle())
                .disabled(root == nil)
                .help("이 폴더를 터미널에서 엽니다. 합치기는 터미널에서 직접 합니다 (\(upstream) 기준).")
                mergeHowToButton(upstream: upstream, font: Theme.ui(.caption))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    private func mergeHowToButton(upstream: String?, font: Font) -> some View {
        let root = model.workspace.projectURL
        return Button("합치는 방법") { showingMergeHowTo = true }
            .buttonStyle(TextButtonStyle(color: Theme.slate, font: font))
            .fixedSize()
            .popover(isPresented: $showingMergeHowTo, arrowEdge: .top) {
                MergeHowToView(upstream: upstream, openTerminal: root.map { url in { TerminalLauncher.open(url) } })
            }
            .help("터미널에서 두 기록을 합치는 방법 (앱은 원격 기록과 합치지 않습니다)")
    }

    @ViewBuilder
    private func terminalChip(_ label: String, help: String = "이 폴더를 터미널에서 엽니다") -> some View {
        if let root = model.workspace.projectURL {
            Button {
                TerminalLauncher.open(root)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "terminal").font(.system(size: 10.5))
                    Text(label)
                }
            }
            .buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 10))
            .fixedSize()
            .help(help)
        }
    }

    // MARK: 원격 명령 실패

    /// 지금 보여줄 업로드 · 받기 · 원격 확인 실패. 이 프로젝트에서, 명령 직후 다시 읽은 상태(브랜치 · HEAD ·
    /// 추적 브랜치 · 앞섬/뒤처짐 · 마지막 fetch · 병합/rebase)가 지금과 같을 때만 (`ChangesState.failureIsCurrent`).
    /// 터미널에서 로그인하고 올렸거나 fetch 로 기록 분기가 드러났으면 지난 실패라 지금 상태 화면을 보인다.
    /// 다음 git 명령을 시작하면 `runGit` 이 지운다.
    private func syncFailure(_ git: GitWorkspaceStatus) -> AppModel.GitOutcomeRecord? {
        guard let record = model.lastGitOutcome, !record.outcome.succeeded, record.operation.talksToRemote,
              record.projectPath == model.selectedProject?.path,
              ChangesState.failureIsCurrent(recorded: record.context, now: git) else { return nil }
        return record
    }

    /// 실패 안내 (목업 SyncVariants "실패" 의 danger 규칙선). 이유는 `GitFailure` 가 분류한 것만 쓰고,
    /// 분류되지 않으면 git 의 한 줄을 그대로. 기록 분기 거절은 "원격 변경 받기" 를 권하지 않는다 (받기도 실패한다).
    private func syncFailureNote(_ record: AppModel.GitOutcomeRecord, git: GitWorkspaceStatus,
                                 lock: ChangesState.Lock?) -> some View {
        let failure = record.failure ?? .unclassified(GitFailure.noOutputLine)
        let explanation = failure.explanation(for: record.operation, remoteName: record.remoteName)
        let icon: String = {
            if case .authentication = failure { return "key" }
            return "xmark"
        }()
        // "다시 시도" 는 지금 상태가 그 명령을 권할 때만 (기록 분기 · 원격과 같음에서 업로드 · 받기를 권하지 않는다).
        let retry = ChangesState.retryOffered(record.operation, sync: ChangesState.sync(git))
        return RuleNote(systemImage: icon, tint: Theme.danger, title: explanation.title,
                        detail: explanation.detail, verbatim: explanation.verbatim) {
            switch failure {
            case .diverged:
                terminalChip("터미널에서 합치기",
                             help: record.operation.isPush
                                 ? "이 폴더를 터미널에서 엽니다. 원격 변경과 합친 다음 다시 업로드하세요."
                                 : "이 폴더를 터미널에서 엽니다. 로컬과 원격의 두 기록을 합치세요.")
                failureOutputButton(record)
            case .authentication:
                terminalChip("터미널 열기", help: "터미널에서 로그인한 뒤 다시 시도하세요 (앱은 자격 증명을 다루지 않습니다)")
                if retry { retryButton(record, git: git, lock: lock) }
            default:
                if retry { retryButton(record, git: git, lock: lock) }
                failureOutputButton(record)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 12)
    }

    private func failureOutputButton(_ record: AppModel.GitOutcomeRecord) -> some View {
        Button("오류 전문") { showingFailureOutput = true }
            .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
            .fixedSize()
            .popover(isPresented: $showingFailureOutput, arrowEdge: .top) {
                GitOutputView(command: record.outcome.command, output: record.outcome.output)
            }
            .help("git 이 쓴 출력 전체 (대화 기록에도 남아 있습니다)")
    }

    /// 다시 시도. 업로드 · 받기는 다시 확인 창을 거친다 (fetch 는 확인이 필요 없는 명령이라 바로).
    private func retryButton(_ record: AppModel.GitOutcomeRecord, git: GitWorkspaceStatus,
                             lock: ChangesState.Lock?) -> some View {
        let operation = record.operation
        let visible = ChangesState.visibleLock(lock)
        let busy = model.runningGitOperation != nil
        return Button {
            if operation.needsConfirmation {
                confirmingRetry = true
            } else {
                Task { await model.runGit(operation, reportsInline: true) }
            }
        } label: {
            HStack(spacing: 5) {
                if busy && model.runningGitOperation == operation { InkSpinner(color: Theme.slate) }
                Text("다시 시도")
            }
        }
        .buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 10))
        .fixedSize()
        .disabled(visible != nil || busy)
        .help(visible.map { lockText($0, action: "다시 시도할") }
              ?? (operation.needsConfirmation ? "확인 뒤 같은 명령을 다시 실행합니다" : "같은 명령을 다시 실행합니다"))
        .popover(isPresented: $confirmingRetry, arrowEdge: .top) {
            syncConfirm(operation, git: git, lock: lock) { confirmingRetry = false }
        }
    }
}

// MARK: - 업로드 · 받기 확인

/// 업로드 · 게시 · 받기 직전 한 번 보여주는 확인 (목업 SyncVariants "업로드 확인"). 기본 버튼은 잉크색.
/// 커밋 목록은 `GitWorkspace` 가 읽은 것 (최대 50개) 중 앞의 몇 개만 보이고, 나머지는 "외 n개" 로 밝힌다.
private struct SyncConfirmView: View {
    let title: String
    /// 올라가거나 들어올 커밋. 목록을 읽지 않았으면 nil (게시처럼 개수를 모를 때 포함) — 목록 없이 보인다.
    var commits: [GitLogEntry]?
    /// 전체 커밋 수 (앞섬 · 뒤처짐). 모르면 nil.
    var total: Int?
    /// "<from> → <to>" (업로드: 브랜치 → 추적 브랜치, 받기: 추적 브랜치 → 브랜치).
    let from: String
    let to: String
    /// 목록 · 개수의 기준을 밝히는 한 줄 (받기: 마지막 확인 기준, git 이 다시 확인한다). 없으면 nil.
    var basis: String?
    let note: String
    let confirmLabel: String
    /// 다른 git 명령이 끝나야 누를 수 있다.
    var canConfirm = true
    /// 맨 `git push` (업로드) 면 그 폴더의 `push.default` 를 창이 열릴 때 한 번 읽는다. 게시 · 받기는 nil.
    var pushDefaultDirectory: URL?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(AppModel.self) private var model
    @State private var pushDefault: String?

    /// 확인 창에서 보이는 커밋 수. 긴 목록은 목록 탭 (변경사항 탭 커밋 섹션) 에서 본다.
    private static let shownLimit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(Theme.ui(.callout, .semibold))
                .foregroundStyle(Theme.ink)
            if let commits, !commits.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(commits.prefix(Self.shownLimit)) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.shortHash)
                                .font(Theme.mono(.caption))
                                .foregroundStyle(Theme.slate2)
                                .fixedSize()
                            Text(entry.subject)
                                .font(Theme.ui(.caption))
                                .foregroundStyle(Theme.ink2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .help("\(entry.author) · "
                              + (ChangesState.commitTime(entry.committedAt, fallback: entry.relativeDate) ?? ""))
                    }
                    let shown = min(commits.count, Self.shownLimit)
                    if let more = ChangesState.moreCount(listed: shown, total: total ?? commits.count) {
                        Text("외 \(more)개")
                            .font(Theme.mono(.caption))
                            .foregroundStyle(Theme.slate2)
                    }
                }
                .padding(.leading, 11)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.hair).frame(width: 1) }
            }
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(Theme.slate2)
                Text(from).font(Theme.mono(.caption)).foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.middle)
                Text("→").font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
                Text(to).font(Theme.mono(.caption)).foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.middle)
            }
            if let basis {
                ReasonLine(systemImage: "info.circle", text: basis)
            }
            // 맨 `git push` 는 사용자의 push.default 를 따른다. 위의 "→ 대상" 은 기본값(simple) 기준이라,
            // 다른 설정이면 그 사실을 적는다 (current · matching 은 다른 곳이나 여러 브랜치로 올린다).
            if pushDefaultDirectory != nil, !GitWorkspace.pushGoesToUpstreamOnly(pushDefault),
               let value = pushDefault {
                ReasonLine(systemImage: "exclamationmark.triangle", iconColor: Theme.amber,
                           text: "push.default = \(value) 설정을 따릅니다. 올라가는 곳이 위와 다를 수 있습니다.")
            }
            HStack(spacing: 8) {
                Text(note)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button("취소", action: onCancel)
                    .buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 12))
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: onConfirm)
                    .buttonStyle(InkButtonStyle(height: 26))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 330)
        .task {
            guard let directory = pushDefaultDirectory else { return }
            let env = await model.environment.childEnvironment()
            pushDefault = await GitWorkspace.pushDefault(at: directory, environment: env)
        }
    }
}

// MARK: - 편집 파일 추적

/// 스레드 이벤트에서 에이전트별 편집 파일과 "지금 편집 중" 파일(실행 중인 run 의 편집)을 뽑는다.
/// 이벤트는 스트리밍 중 계속 바뀌므로 이 작은 뷰만 다시 그리고, 결과가 달라질 때만 부모 상태를 바꾼다.
/// 추측하지 않는다 — 실행 기록에 편집 도구 · 파일 변경으로 남은 경로만 쓴다.
private struct TouchedTracker: View {
    @Environment(AppModel.self) private var model
    let root: String?
    @Binding var touched: [String: Set<AgentProvider>]
    @Binding var editingNow: Set<String>

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: key) { recompute() }
    }

    /// 지금 이 스레드에서 실행 중인 run.
    private var runningRunID: String? {
        guard let id = model.selectedThreadID, let session = model.runner.session(threadID: id), session.isBusy else { return nil }
        return session.activeRun?.id
    }

    private var key: String {
        "\(model.selectedThreadID ?? "")|\(model.events.count)|\(runningRunID ?? "")|\(root ?? "")"
    }

    private func recompute() {
        let all = ExecutionParser.touchedFiles(in: model.events, projectPath: root)
        if all != touched { touched = all }
        var now: Set<String> = []
        if let runID = runningRunID {
            now = Set(ExecutionParser.touchedFiles(in: model.events.filter { $0.runID == runID },
                                                   projectPath: root).keys)
        }
        if now != editingNow { editingNow = now }
    }
}
