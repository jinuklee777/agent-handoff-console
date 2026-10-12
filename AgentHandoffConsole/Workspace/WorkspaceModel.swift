import Foundation
import Observation

/// 선택된 스레드의 작업 폴더 상태 (Git · PR). 사이드바 · 상태 막대 · 인스펙터가 함께 쓴다.
///
/// 자동 폴링하지 않는다. 폴더가 바뀔 때, 실행이 파일을 바꿀 때(실행 중 — 모아서 1.5초에 한 번, `AppModel.scheduleLiveGitRefresh`)와
/// 끝날 때, 창이 다시 활성화될 때, 변경사항 · 파일 탭이 나타날 때(오래됐을 때만), 사용자가 새로고침할 때만 읽는다.
/// PR 은 네트워크를 쓰므로 PR 탭 · 변경사항 탭을 열 때(이 프로젝트 · 브랜치의 결과가 캐시에 없을 때 한 번)와
/// 사용자가 다시 조회할 때만 묻는다. 결과는 프로젝트 · 브랜치별로 캐시하고 조회 시각을 함께 둔다 ("n분 전 조회").
/// 이 모델은 **읽기 전용**이다. 스테이지·커밋·푸시·브랜치 전환은 하지 않는다.
@MainActor
@Observable
final class WorkspaceModel {
    private(set) var projectPath: String?
    private(set) var git: GitWorkspaceStatus?
    private(set) var isRefreshingGit = false
    private(set) var pullRequest: PullRequestState = .idle

    private var prCache: [String: PullRequestState] = [:]
    /// 지금 도는 PR 조회의 대상 (프로젝트 · 브랜치). 그 사이 브랜치가 바뀌면 그 조회는 버린다.
    private var prLoadingKey: String?
    /// gh 로 PR 을 마지막으로 조회한 시각 (프로젝트 · 브랜치 → 시각). 메모리에만 둔다.
    private var prCheckedAt: [String: Date] = [:]
    /// 앱이 프로젝트 폴더에서 fetch · pull 에 성공한 시각 (폴더 경로 → 시각). 메모리에만 둔다.
    private var remoteCheckedAt: [String: Date] = [:]
    private var inFlightURL: URL?
    private var rerunRequested = false
    private var gitGeneration = 0
    private var prGeneration = 0
    private let environment: CLIEnvironment

    /// 변경사항 탭 · 크게 보기에서 연 파일의 diff (마지막으로 다 읽은 것). 한 번에 한 파일만 들고 있는다.
    /// git 상태를 다시 읽어 요청이 바뀌어도 새 결과가 올 때까지 이것을 그대로 보여준다 (깜빡이지 않게).
    private(set) var fileDiffDocument: FileDiffDocument?
    /// 지금 읽는 diff 요청. 없으면 nil.
    private(set) var fileDiffLoading: FileDiffRequest?
    private var fileDiffGeneration = 0
    /// 목록 행 캐시 (status 를 읽은 시각 · 폴더가 같으면 다시 합치고 정렬하지 않는다).
    @ObservationIgnored private var rowsCache: (readAt: Date?, path: String?, rows: [ChangesState.Row])?

    init(environment: CLIEnvironment) {
        self.environment = environment
    }

    var projectURL: URL? { projectPath.map { URL(fileURLWithPath: $0) } }

    /// 인스펙터에서 PR 번호를 보여줄 수 있을 때만 값이 있다 (조회한 적이 없으면 nil).
    var pullRequestNumber: Int? { pullRequest.info?.number }

    /// 지금 프로젝트 · 브랜치의 PR 을 gh 로 마지막으로 조회한 시각. 조회한 적이 없으면 nil.
    var pullRequestCheckedAt: Date? { prCheckedAt[prKey] }

    /// 마지막으로 원격을 확인한 시각 = max(앱이 이 폴더에서 성공한 fetch · pull, `FETCH_HEAD` 수정 시각).
    /// `git.fetchedAt` 은 status 를 읽은 시각이라 쓰지 않는다. 둘 다 없으면 nil ("원격 확인 기록 없음").
    var lastFetchAt: Date? {
        ChangesState.latest(projectPath.flatMap { remoteCheckedAt[$0] }, git?.fetchHeadModifiedAt)
    }

    /// 앱이 fetch · pull 에 성공했을 때 부른다 (`AppModel.runGit`).
    func noteRemoteChecked(path: String, at date: Date = Date()) {
        remoteCheckedAt[path] = date
    }

    func setProject(path: String?) async {
        guard path != projectPath else { return }
        projectPath = path
        git = nil
        // 앞 폴더의 조회가 늦게 끝나도 쓰지 않는다.
        prGeneration += 1
        prLoadingKey = nil
        pullRequest = .idle
        fileDiffGeneration += 1
        fileDiffDocument = nil
        fileDiffLoading = nil
        await refreshGit()
    }

    /// 변경사항 탭 목록 행 (`ChangesState.rows`). git 상태를 새로 읽었을 때만 합치고 정렬한다 — 커밋 메시지를 칠 때마다
    /// 수천 행을 다시 정렬하지 않도록. `git` 을 읽으므로 상태가 바뀌면 부른 화면도 다시 그린다.
    func changeRows() -> [ChangesState.Row] {
        guard let git else { return [] }
        if let cache = rowsCache, cache.readAt != nil, cache.readAt == git.fetchedAt, cache.path == projectPath {
            return cache.rows
        }
        let rows = ChangesState.rows(from: git)
        rowsCache = (git.fetchedAt, projectPath, rows)
        return rows
    }

    /// 파일 diff 를 읽는다 (읽기 전용 · 파싱은 백그라운드). 같은 요청을 이미 읽었거나 읽는 중이면 다시 부르지 않는다.
    /// 그 사이 폴더가 바뀌었거나 새 요청이 시작됐으면 늦게 끝난 결과를 쓰지 않는다.
    func loadFileDiff(_ request: FileDiffRequest, force: Bool = false) async {
        if !force, fileDiffDocument?.request == request {
            // 이미 읽은 파일로 돌아왔다 (A → B 를 읽는 중 → A). 읽던 B 가 끝나 A 를 덮지 않게 그 결과를 버린다.
            if fileDiffLoading != nil {
                fileDiffGeneration += 1
                fileDiffLoading = nil
            }
            return
        }
        if !force, fileDiffLoading == request { return }
        guard let git, git.isRepository, let root = git.rootPath, let path = projectPath else { return }
        fileDiffGeneration += 1
        let generation = fileDiffGeneration
        fileDiffLoading = request
        let env = await environment.childEnvironment()
        // 부른 화면이 사라져 취소돼도 끝까지 읽는다 (결과는 세대로 가린다).
        let document = await Task.detached(priority: .userInitiated) {
            await GitWorkspace.fileDiff(request, root: URL(fileURLWithPath: root), environment: env)
        }.value
        guard generation == fileDiffGeneration, path == projectPath else { return }
        fileDiffDocument = document
        fileDiffLoading = nil
    }

    func refreshGit() async {
        guard let url = projectURL else {
            git = nil
            return
        }
        // 같은 폴더를 이미 읽는 중이면 겹쳐 돌리지 않고, 끝난 뒤 한 번만 다시 읽는다.
        if inFlightURL == url {
            rerunRequested = true
            return
        }
        inFlightURL = url
        gitGeneration += 1
        let generation = gitGeneration
        isRefreshingGit = true
        let env = await environment.childEnvironment()
        let status = await GitWorkspace.status(at: url, environment: env)
        if inFlightURL == url { inFlightURL = nil }
        // 그 사이 다른 폴더로 옮겼거나 새 조회가 시작됐으면 늦게 끝난 결과를 쓰지 않는다.
        guard generation == gitGeneration, url == projectURL else { return }
        git = status
        isRefreshingGit = false
        // PR 상태는 git 을 바꾼 즉시 맞춘다 (다시 읽기 전에). 브랜치가 바뀐 채 옛 브랜치의 결과나 "조회 중" 이 남으면
        // 새 브랜치를 한 번 묻는 조건(`pullRequestQueryNeeded` — idle)이 영영 오지 않는다.
        reconcilePullRequest()
        if rerunRequested {
            rerunRequested = false
            await refreshGit()
            return
        }
    }

    /// 변경사항 · 파일 탭이 나타날 때 (앱 안 터미널에서 `git add` 한 뒤 돌아오는 등): 마지막으로 읽은 지 `seconds` 가 지났고 읽는 중이
    /// 아닐 때만 다시 읽는다 (막 연 폴더를 곧바로 두 번 읽지 않게 — chg-11). 앱은 주기적으로 읽지 않는다 (폴링 아님).
    func refreshGitIfStale(olderThan seconds: TimeInterval = 2, now: Date = Date()) async {
        guard projectURL != nil, inFlightURL == nil else { return }
        if let read = git?.fetchedAt, now.timeIntervalSince(read) < seconds { return }
        await refreshGit()
    }

    /// 방금 다른 길(실행 종료 스냅샷 `RunFileSnapshot.capture`)로 이 폴더를 읽은 상태를 그대로 쓴다 — 같은 조회를
    /// 곧바로 한 번 더 돌리지 않게. 지금 보는 폴더가 아니거나 그 사이 읽기가 도는 중이면 쓰지 않고 false
    /// (그때는 `refreshGit` 으로 읽는다 — 도는 읽기가 더 새 값일 수 있다).
    func adoptGitStatus(_ status: GitWorkspaceStatus, path: String) -> Bool {
        guard path == projectPath, inFlightURL == nil else { return false }
        // 그 사이 이 폴더를 더 늦게 읽어 둔 값이 있으면 옛 값으로 덮지 않는다.
        if let current = git?.fetchedAt, let read = status.fetchedAt, current > read { return false }
        gitGeneration += 1
        git = status
        isRefreshingGit = false
        reconcilePullRequest()
        return true
    }

    private func reconcilePullRequest() {
        let next = ChangesState.pullRequestAfterRefresh(current: pullRequest, loadingKey: prLoadingKey, key: prKey,
                                                        cached: prCache[prKey])
        if next.invalidatesQuery {
            // 옛 브랜치의 조회 결과는 늦게 와도 쓰지 않는다.
            prGeneration += 1
            prLoadingKey = nil
        }
        if pullRequest != next.state { pullRequest = next.state }
    }

    func refreshPullRequest() async {
        // git 상태를 아직 읽는 중이면 조회하지 않는다 (저장소가 아니라고 단정하지 않는다).
        guard let url = projectURL, let git else { return }
        guard git.isRepository else {
            pullRequest = .unavailable("Git 저장소가 아닙니다.")
            return
        }
        prGeneration += 1
        let generation = prGeneration
        let key = prKey
        prLoadingKey = key
        pullRequest = .loading
        let env = await environment.childEnvironment()
        let branch = git.branch
        // 부른 화면(탭의 `.task`)이 사라져 취소돼도 gh 는 끝까지 기다린다. 취소된 작업에서 기다리면 출력이 잘려
        // 없던 "조회 실패" 가 캐시된다. 결과는 아래에서 세대 · 대상을 보고 버리거나 쓴다.
        let state = await Task { await GitHubCLI.pullRequest(at: url, branch: branch, environment: env) }.value
        // 새 조회가 시작됐거나 대상이 바뀌어 버린 조회다 (상태는 그쪽이 정했다).
        guard generation == prGeneration else { return }
        prLoadingKey = nil
        guard key == prKey else {
            // 다시 읽기 전에 브랜치가 바뀌었다 — 이 결과는 쓰지 않고, 지금 브랜치는 캐시 또는 조회 전 상태로 둔다.
            pullRequest = prCache[prKey] ?? .idle
            return
        }
        pullRequest = state
        prCache[key] = state
        prCheckedAt[key] = Date()
    }

    private var prKey: String {
        "\(projectPath ?? "")|\(git?.headLabel ?? "")"
    }

    #if DEBUG
    /// 화면 확인용 (`-preview.pullRequest <JSON 경로>`, AHC_OFFLINE=1): gh 가 준 형식의 JSON 을 **앱의 해석기**
    /// (`GitHubCLI.parseView`) 로 읽은 PR 을 지금 프로젝트 · 브랜치의 캐시에 넣는다. 값을 코드에서 만들지 않는다.
    func previewUsePullRequest(json: String) -> Bool {
        guard git != nil, let info = GitHubCLI.parseView(json) else { return false }
        let state = PullRequestState.loaded(info, others: [])
        prCache[prKey] = state
        prCheckedAt[prKey] = Date()
        pullRequest = state
        return true
    }
    #endif
}
