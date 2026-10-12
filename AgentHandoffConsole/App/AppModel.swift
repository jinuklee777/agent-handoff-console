import Foundation
import SwiftUI
import UserNotifications

/// 앱 전역 상태. 메인 창, 메뉴바, 설정창이 이 인스턴스 하나를 공유한다.
@MainActor
@Observable
final class AppModel: RunCoordinatorDelegate {

    // MARK: 저장 계층 / 서비스
    let store: Store
    let environment = CLIEnvironment()
    let limits: LimitsService
    let notifications = NotificationService()
    let runner: RunCoordinator
    /// 자동 작업의 검토단이 동시에 검토할 때 쓰는 읽기 전용 실행 레인. 도는 동안 쓰기 실행 · 앱의 git 쓰기를 막는다
    /// (`isReviewing`) — 검토가 움직이는 폴더를 읽지 않게. 화면의 실행 상태 · 승인 · 중단은 여전히 `runner` 하나를 본다.
    let reviewLanes: ReadOnlyRunPool
    let geminiAssist: GeminiAssistService
    /// Codex 계정(= CODEX_HOME) 목록. 계정 전환은 이 목록을 통해서만 일어난다.
    let accounts: CodexAccountService
    /// 작업 폴더의 Git · PR 상태 (읽기 전용), 폴더마다 하나. 화면에 열린 대화의 폴더 것만 들고 있다 (`pruneThreadStates`).
    /// 폴더마다 따로 두는 이유: 분할 화면의 칸들이 서로 다른 폴더일 수 있고, 포커스를 옮길 때마다 다시 읽지 않는다.
    private(set) var workspaces: [String: WorkspaceModel] = [:]
    /// 폴더가 없을 때(프로젝트 없음)의 빈 상태.
    @ObservationIgnored private let detachedWorkspace: WorkspaceModel
    /// **포커스 대화**의 폴더 것. 인스펙터(터미널 · 파일 · PR · 변경사항)는 하나이고 포커스 칸을 따라간다.
    var workspace: WorkspaceModel { selectedProject.flatMap { workspaces[$0.path] } ?? detachedWorkspace }
    /// 그 폴더의 상태. 화면에 열려 있지 않은 폴더면 nil.
    func workspace(forPath path: String?) -> WorkspaceModel? { path.flatMap { workspaces[$0] } }

    /// 그 폴더의 상태를 들고 있게 한다 (없으면 만들고 읽기 시작한다).
    @discardableResult
    private func ensureWorkspace(path: String?) -> WorkspaceModel {
        guard let path else { return detachedWorkspace }
        if let existing = workspaces[path] { return existing }
        let created = WorkspaceModel(environment: environment)
        workspaces[path] = created
        workspaceLoads[path] = Task { await created.setProject(path: path) }
        return created
    }
    @ObservationIgnored private var workspaceLoads: [String: Task<Void, Never>] = [:]

    /// 그 폴더의 상태를 들고, 첫 읽기가 끝날 때까지 기다린다 (검증 · 화면 확인용 입구. 화면은 기다리지 않는다).
    @discardableResult
    func openWorkspace(path: String) async -> WorkspaceModel {
        let workspace = ensureWorkspace(path: path)
        await workspaceLoads[path]?.value
        return workspace
    }

    /// 화면에 열린 폴더의 git 상태를 모두 다시 읽는다 (앱이 활성화될 때 — 앱 밖에서 파일을 바꿨을 수 있다).
    func refreshOpenWorkspaces() async {
        for workspace in workspaces.values { await workspace.refreshGit() }
    }
    /// 자동 작업(오케스트레이션). 설정에서 켜야 동작한다. 앱 쪽 연결은 `AppModel+Orchestration.swift`.
    let orchestration: OrchestrationCoordinator
    /// 오케스트레이션이 만든 내부 대화 (계획 · 검토 · 하위 작업). 사이드바에는 나오지 않고 작업 카드에서 연다.
    var internalThreadsByID: [String: ConversationThread] = [:]
    /// Claude 로그인 확인은 CLI 를 부르므로 배정마다 다시 하지 않는다.
    @ObservationIgnored var orchestrationClaudeLogin: (value: Bool, at: Date)?
    /// 자동 작업 설정 (설정 화면과 입력창이 읽는다). 저장은 `saveOrchestrationSettings`.
    var orchestrationSettings = OrchestrationSettings()
    /// 입력창에서 "자동"을 고른 대화. 다음 메시지는 에이전트 하나가 아니라 자동 작업으로 간다.
    var orchestrationAutoThreadIDs: Set<String> = []

    // MARK: 상태
    private(set) var bootstrapped = false
    var bootstrapError: String?

    var projects: [Project] = []
    var threadsByProject: [String: [ConversationThread]] = [:]
    var selectedProjectID: String?
    var selectedThreadID: String?

    /// 입력 초안은 스레드 ID별로 분리한다. 화면은 이 값을 즉시 사용하고 Store 에도 자동 저장한다.
    private(set) var composerDrafts: [String: String] = [:]
    private var composerDraftRevisions: [String: Int64] = [:]

    /// 대화별 화면 상태 (이벤트 · 실행 · 사용량 · 인계 · 평가). 화면에 열려 있는 대화의 것만 들고 있다 (`pruneThreadStates`).
    /// 실시간 이벤트는 그 대화의 상자로 간다 — 지금 보고 있지 않은 칸의 출력도 버리지 않는다.
    private(set) var threadStates: [String: ThreadPaneModel] = [:]

    /// 그 대화의 상태 상자. 없으면 만든다 (읽기는 `reloadThreadData(threadID:)`).
    func paneModel(for threadID: String) -> ThreadPaneModel {
        if let state = threadStates[threadID] { return state }
        let state = ThreadPaneModel(threadID: threadID)
        threadStates[threadID] = state
        return state
    }

    /// 화면에 열려 있는 대화: 분할 화면의 칸들 + 선택된(포커스) 대화 + (현황이 보이는 동안) 실행 중인 대화 — 현황의 "지금 하는 일" 한 줄이
    /// 그 대화의 기록을 읽는다 (`AppModel+Overview`).
    var openThreadIDs: Set<String> {
        Set(paneThreadIDs.compactMap { $0 } + [selectedThreadID].compactMap { $0 })
            .union(overviewVisible ? overviewThreadIDs : [])
    }

    /// 닫힌 대화의 상자를 버린다. 다시 열면 저장소에서 읽는다 (실행 중이어도 기록은 저장소에 있다).
    func pruneThreadStates() {
        let open = openThreadIDs
        for id in threadStates.keys where !open.contains(id) { threadStates[id] = nil }
        let paths = Set(open.compactMap { id in
            (allThreads().first { $0.id == id } ?? internalThreadsByID[id]).flatMap { folderProject(for: $0)?.path }
        } + [selectedProject?.path].compactMap { $0 })
        for path in workspaces.keys where !paths.contains(path) {
            workspaces[path] = nil
            workspaceLoads[path] = nil
        }
    }

    private var focusedState: ThreadPaneModel? { selectedThreadID.flatMap { threadStates[$0] } }

    // 아래 여섯은 **포커스 대화**의 값이다 (칸이 하나일 때의 "선택된 대화"). 칸마다의 값은 `paneModel(for:)` 로 읽는다.
    var events: [ThreadEvent] { focusedState?.events ?? [] }
    var usageByRun: [String: UsageRecord] { focusedState?.usageByRun ?? [:] }
    var runsByID: [String: Run] { focusedState?.runsByID ?? [:] }
    var handoffs: [Handoff] { focusedState?.handoffs ?? [] }
    var ratingsByRun: [String: Rating] { focusedState?.ratingsByRun ?? [:] }
    var ratingsByHandoff: [String: Rating] { focusedState?.ratingsByHandoff ?? [:] }

    /// 분할 화면의 칸 배치: 분할 · 칸마다의 대화 · 포커스 칸. 규칙은 `PaneArrangement` (App/WindowState.swift).
    /// **포커스 칸의 대화가 `selectedThreadID`** 다 — 인스펙터 · 툴바 · 메뉴는 그 대화를 따라간다.
    private(set) var panes = PaneArrangement()
    /// 칸에 열린 대화 (칸 순서, 빈 칸은 nil).
    var paneThreadIDs: [String?] { panes.threadIDs }
    /// 왼쪽 사이드바를 보이는가 (메모리 — 앱을 다시 열면 보인다). 툴바 버튼 · 보기 메뉴(⌃⌘S)가 바꾸고,
    /// 창이 좁으면 `ContentView.fitPanels` 가 접었다 편다.
    var sidebarVisible = true
    /// 사이드바의 대화 목록 검색어와 "더보기" · "보관됨" 을 편 프로젝트 — 사이드바를 숨겨도(뷰가 사라져도) 남는다 (메모리).
    var sidebarSearchText = ""
    var sidebarExpandedProjects: Set<String> = []
    var sidebarExpandedArchives: Set<String> = []
    /// 사이드바 검색칸에 포커스를 달라는 요청의 시각 (⌥⌘F). 숨어 있던 사이드바는 나타날 때 가져간다 — 2초 안의 요청만
    /// (창이 닫혀 있을 때 누른 것이 나중에 저절로 포커스를 가져가지 않게).
    private(set) var sidebarSearchFocusRequestedAt: Date?
    /// 가운데 칸을 대화로 돌려 달라는 요청 — 대화를 고르거나 새로 만들었다 (에이전트 기록 · 크게 보기 중이어도 그 대화가 보이게).
    /// 가운데 칸은 창 상태 값이라 `ContentView` 가 번호가 바뀔 때 바꾼다.
    private(set) var conversationRevealRequest = 0
    /// 가운데 칸을 현황으로 열어 달라는 요청 — 메뉴바 "현황 열기" · 응답 필요 칩의 "현황에서 모두 보기" (`ContentView` 가 받는다).
    private(set) var overviewRevealRequest = 0
    /// 가운데 칸이 현황이다 (`OverviewView` 가 켜고 끈다 — `setOverviewVisible`). 그동안 실행 중인 대화의 상자를 들고 있는다.
    var overviewVisible = false
    /// 현황에서 고른 행의 대화 (↑ ↓) — 그동안 메뉴의 승인 허용 · 거절(⌥⌘↵ · ⌥⌘⌫)이 그 행에 간다 (`approvalShortcutThreadID`).
    var overviewSelection: String?
    /// 대화 안 찾기 요청 (⌘F · ⌘G · ⇧⌘G) — 포커스 칸의 대화(`ThreadView`)가 번호가 바뀔 때 받는다.
    private(set) var findCommand: ThreadFind.Command?
    /// 도움말 메뉴의 시트 — 키보드 단축키 · 이 앱 소개.
    var showKeyboardShortcuts = false
    var showAppGuide = false
    /// 메뉴바의 "확인 필요" — 사람이 아직 보지 않은, 오류 · 한도 · 전달 미확인으로 끝난 실행 (대화마다 마지막 것 하나).
    /// 그 대화를 열면(포커스) 빠진다 (`syncPanes`). 메모리.
    var unseenRunProblems: [MenuBarStatus.UnseenRun] = []

    /// 가운데 칸을 현황으로 (메뉴바 · 응답 필요 칩). 크게 보기 중이면 `ContentView` 가 닫는다.
    func requestOverview() { overviewRevealRequest += 1 }

    /// ⌥⌘F — 사이드바를 보이고 검색칸으로.
    func requestSidebarSearch() {
        sidebarVisible = true
        sidebarSearchFocusRequestedAt = Date()
    }

    /// 사이드바가 검색칸 포커스 요청을 가져간다. 받을 요청이 있으면 true.
    func consumeSidebarSearchFocus() -> Bool {
        guard let at = sidebarSearchFocusRequestedAt else { return false }
        sidebarSearchFocusRequestedAt = nil
        return Date().timeIntervalSince(at) < 2
    }

    /// 포커스 칸의 대화 안 찾기 (편집 메뉴). 열린 대화가 없으면 아무것도 하지 않는다. 가운데가 에이전트 기록 · 크게 보기면 대화로.
    func requestFind(_ action: ThreadFind.Command.Action) {
        guard let id = selectedThreadID else { return }
        conversationRevealRequest += 1
        findSerial += 1
        findCommand = ThreadFind.Command(threadID: id, action: action, serial: findSerial, requestedAt: Date())
    }

    /// 칸이 찾기 요청을 받았다 — 그 요청을 지운다 (다시 나타날 때 또 받지 않게).
    func consumeFindCommand(serial: Int) {
        if findCommand?.serial == serial { findCommand = nil }
    }

    @ObservationIgnored private var findSerial = 0

    var cliStatus: [AgentProvider: CLIStatus] = [:]

    // MARK: 첫 실행 점검표의 사실 (모으는 곳은 `AppModel+Setup.swift`, 판정은 `FirstRunChecklist`)
    /// 프로젝트 목록을 한 번이라도 읽는 데 성공했는가. 읽기 전 · 실패면 점검표를 세우지 않는다 (빈 목록과 실패를 섞지 않는다).
    private(set) var projectsLoaded = false
    /// Claude 로그인 확인 (`claude auth status --json`) 과 그 시각. 화면에 보일 때는 나이를 함께 — **자동 인계 판정은 이 값을 쓰지
    /// 않고** 스스로 새로 확인한다 (`claudeLoginCheck`).
    var claudeLogin: LoginCheck?
    /// Codex 계정 홈마다 `config.toml` 이 파일 아닌 자격 저장소를 쓰는가 (계정 ID → 여부). auth.json 이 없어도 로그인돼 있을 수 있다.
    var codexNonFileStores: [String: Bool] = [:]
    /// Git 의 Command Line Tools (`xcode-select -p`). 없다고 확인되면 `/usr/bin/git`(설치 창을 띄우는 shim)을 부르지 않는다
    /// (`GitInspector.systemGitShimUnavailable`) — 폴더를 열자마자 작업 폴더의 git 읽기가 설치 창을 띄우지 않게.
    var gitTools: GitToolsPresence = .unknown {
        didSet { GitInspector.systemGitShimUnavailable = gitTools == .missing }
    }
    /// 에이전트 사실을 확인하는 중 (점검표의 "다시 확인" 이 돈다).
    var isRefreshingAgentFacts = false
    /// 설정 > 에이전트에서 다시 확인하는 제공자 (카드의 ↻ · 실행 파일 경로를 바꾼 뒤 · "모두 다시 확인") — 그 카드만 "확인 중" 이고
    /// ↻ 가 돈다 (`AppModel+Setup` 의 `recheckAgent`). 마지막에 시작한 확인이 끝날 때 빠진다 (`agentRecheckOwners`).
    var recheckingAgents: Set<AgentProvider> = []
    @ObservationIgnored var agentRecheckOwners: [AgentProvider: Int] = [:]
    @ObservationIgnored var agentRecheckSerial = 0
    /// 실행 파일 경로를 바꾼 뒤의 적용 · 다시 확인 (제공자마다 하나 — 또 바뀌면 앞의 것을 버린다). 이미 돌던 확인은 멈추지 않지만 그 결과는
    /// 옛 경로의 것이라 화면에 쓰지 않는다 (`CLIEnvironment.isCurrent` — `refreshAgentFacts`, set-n7).
    @ObservationIgnored var pathChangeTasks: [AgentProvider: Task<Void, Never>] = [:]
    /// 셸 설정(`~/.zshrc` 의 PATH · API 키 · 프록시)을 어디까지 읽었나 — 점검표가 읽지 못했을 때 그 사실을 말한다 (`refreshAgentFacts`).
    var shellRead: ShellRead = .unknown
    /// Claude 가 로그인 대신 쓸 인증(API 키 · Bedrock · Vertex)이 자식 환경에 있다 (`refreshAgentFacts` — `CLIEnvironment.claudeAlternativeAuth`).
    var claudeAlternativeAuth = false
    /// 셸 · 물려받은 환경에 값이 있는 인증 변수의 이름 (`CLIEnvironment.shellAuthVariables` — 넘기는지와 상관없이, 값은 두지 않는다).
    /// `forwardShellAuth` 가 꺼져 있으면 이 변수들은 에이전트에게 가지 않는다 — 점검표 · 설정이 그 사실을 말한다 (onb-19).
    var shellAuthVariables: [String] = []
    /// 점검표 자체의 오류 줄 (폴더를 열지 못함 등). 배너(`banner`)와 따로 — 점검표에는 배너를 그릴 대화가 없다.
    var firstRunError: String?
    /// 도움말 > 시작 점검… 의 시트. "기록 가져오기" 를 누르면 시트를 닫은 뒤 가져오기 시트를 연다 (`importAfterFirstRunSheet`).
    /// 열 때 지난 오류 줄을 지운다 (맥락 없이 옛 오류가 보이지 않게).
    var showFirstRunSheet = false {
        didSet { if showFirstRunSheet && !oldValue { firstRunError = nil } }
    }
    var importAfterFirstRunSheet = false
    /// 입력창에 포커스를 한 번 명시적으로 요청한다 (첫 폴더를 열고 만든 대화). 그 대화의 입력창이 번호가 바뀔 때 가져간다.
    /// 요청 시각을 함께 둔다 — 늦게(`composerFocusLifetime` 뒤) 그려진 입력창은 가져가지 않고 버린다 (나중의 배치가 사용자가
    /// 쓰던 칸에서 포커스를 빼앗지 않게).
    private(set) var composerFocusRequest: (threadID: String, serial: Int, requestedAt: Date)?
    static let composerFocusLifetime: TimeInterval = 2
    func requestComposerFocus(threadID: String) {
        composerFocusSerial += 1
        composerFocusRequest = (threadID, composerFocusSerial, Date())
    }
    /// 입력창이 요청을 받아 포커스를 가져갔다 — 그 요청을 지운다.
    func consumeComposerFocus(serial: Int) {
        if composerFocusRequest?.serial == serial { composerFocusRequest = nil }
    }
    @ObservationIgnored private var composerFocusSerial = 0
    /// 사람이 방금 대화를 새로 만든 프로젝트 — 사이드바가 그 프로젝트를 접어 두었으면 편다 (`SidebarView` 가 받아 비운다,
    /// `takeSidebarReveals`). 접힌 프로젝트는 대화를 하나도 그리지 않아 방금 만든 대화가 목록에 없었다. 새 대화를 만드는 길만 넣는다
    /// (`addThread` — ⌘N · ＋ · 프로젝트 메뉴 · 빈 칸 · 독립 작업 폴더 · 폴더 열기의 첫 대화, ⌘N 이 빈 대화를 다시 여는 길).
    /// 현황 · 알림 · 응답 필요 칩으로 고른 대화는 넣지 않는다 — 사람이 접어 둔 프로젝트는 그대로 숨긴다.
    private(set) var sidebarRevealProjectIDs: Set<String> = []
    /// 사이드바가 펼 프로젝트를 받아 간다 — 받은 뒤 비운다 (사이드바가 다시 나타나도 그 뒤에 다시 접은 프로젝트를 펴지 않게).
    func takeSidebarReveals() -> Set<String> {
        let ids = sidebarRevealProjectIDs
        if !ids.isEmpty { sidebarRevealProjectIDs = [] }
        return ids
    }
    /// 프로젝트가 없어 시작 때 미룬 Claude 조회 (`claude -p` 세션 — 모델 목록 · /usage). 첫 프로젝트가 생긴 뒤 한 번 한다.
    /// 그동안 사람이 누른 한도 새로고침(한도 칩 · 메뉴바 · 보기 메뉴)도 Claude 는 건너뛴다 (`LimitsService.claudeDeferred`, onb-9).
    @ObservationIgnored var deferredClaudeStartup = false {
        didSet { limits.claudeDeferred = deferredClaudeStartup }
    }
    /// 시험용: 있으면 Claude 조회(모델 목록 · /usage)를 띄우지 않고 이것을 부른다 (인수: 한도를 강제로 읽는가). 앱은 두지 않는다.
    @ObservationIgnored var claudeQueriesOverride: ((Bool) -> Void)?
    /// 앱이 다시 앞에 올 때의 다시 확인 시각 (15초에 한 번 — `FirstRunRecheck`).
    @ObservationIgnored var lastFactsRecheck: Date?
    #if DEBUG
    /// 화면 확인용 사실 (`-preview.firstRun`, AHC_OFFLINE=1). 있으면 실제 확인 대신 이것을 보인다.
    var previewFirstRunFacts: FirstRunFacts?
    #endif
    var geminiCLIPath: String?
    var geminiCLIVersion: String?
    var geminiCLIError: String?
    var geminiModels: [String] = []
    var isRefreshingGemini = false
    @ObservationIgnored private var geminiRefreshPending = false

    /// 실행 범위(제공자 + Codex 계정)별 모델 목록.
    /// CLI 에서 조회한 값만 쓰고, 실패하면 대체 목록임을 표시한다.
    /// 계정마다 쓸 수 있는 모델이 다를 수 있어 한 계정의 목록을 다른 계정에 쓰지 않는다.
    var modelCatalogs: [AgentScope: ModelCatalogSnapshot] = [:]
    var refreshingModels: Set<AgentScope> = []
    /// 도는 목록 조회 (범위 → 작업). 같은 범위를 부르면 새로 띄우지 않고 그 조회를 기다린다 (`refreshModelCatalog` — 한도 조회와 같은 방식).
    @ObservationIgnored var modelCatalogRefreshes: [AgentScope: (token: UUID, task: Task<Void, Never>)] = [:]
    /// 범위마다 목록을 받았을 때의 CLI 버전 (설정 `model_catalog_version|<제공자>|<계정>`). 버전이 바뀌면 시작할 때 다시 받는다.
    @ObservationIgnored var modelCatalogVersions: [AgentScope: String] = [:]
    /// Claude 별칭의 이름과 그 이름을 받은 CLI 버전 (설정 `claude_model_names`). 버전이 그대로면 다시 묻지 않는다 — 별칭마다
    /// `claude -p` 를 하나씩(넷) 띄우고, 설정해 둔 훅 · MCP 서버도 함께 뜬다 (set-8 · onb-9).
    @ObservationIgnored var claudeModelNames: ClaudeModelNames?
    /// 뒤에서 도는 Claude 별칭 이름 조회 (목록을 먼저 보인 뒤).
    @ObservationIgnored var claudeNamesTask: Task<Void, Never>?
    /// 시험용: 있으면 CLI 대신 이 함수로 목록을 받는다 (실행 파일 확인 · `claude -p` 없이). 앱은 두지 않는다.
    @ObservationIgnored var modelCatalogFetchOverride: ((AgentScope) async -> ModelCatalogSnapshot)?

    /// 입력창 "/" 목록 (에이전트 · Codex 계정 · 폴더 → CLI 가 알려 준 명령 · 스킬). 메모리 — 동작은 `AppModel+SlashCommands`.
    var slashCommandLists: [SlashCommandKey: SlashCommandList] = [:]
    var loadingSlashCommands: Set<SlashCommandKey> = []
    /// 도는 목록 조회 — 같은 키를 부르면 새로 띄우지 않고 기다린다.
    @ObservationIgnored var slashCommandRefreshes: [SlashCommandKey: Task<Void, Never>] = [:]
    /// 시험 · 화면 확인용: 있으면 CLI 대신 이 함수로 목록을 받는다. 앱은 두지 않는다.
    @ObservationIgnored var slashCommandFetchOverride: ((SlashCommandKey) async -> SlashCommandList)?

    /// Claude 별칭 이름의 저장 형식.
    struct ClaudeModelNames: Codable, Equatable {
        var version: String
        var names: [String: String]
    }

    /// Claude Code · Codex 기록 가져오기 시트 (`ImportSheet`).
    var showImportSheet = false

    // 인계 (B 설계 C1 · C2) — 동작은 `AppModel+Handoff` · 보류는 `AppModel+Composer`, 값은 `App/HandoffCard.swift`.
    /// 대화마다의 인계 카드 (대화 ID → 카드). 여러 대화가 함께 카드를 가진다 — 두 대화가 함께 한도에 닿으면 둘 다 넘어간다
    /// (사용자 결정 2026-09-30: 줄 세우지 않고 동시에). 카드는 메모리다 (넘기기 전에는 DB 에 행이 없다).
    var handoffCards: [String: HandoffCard] = [:]
    /// 카드를 준비하는 대화 (대화 ID → 토큰, Gemini 정리는 수십 초 걸린다). 준비가 끝나면 토큰이 그대로일 때만 카드를 놓는다 —
    /// 그 사이 취소 · 삭제 · 다른 준비가 있었으면 늦게 끝난 결과를 버린다. 준비 중도 "카드가 있음" 으로 센다.
    var handoffPreparations: [String: UUID] = [:]
    /// 전달 실행이 도는 인계 (대화 ID → 전달). 카드는 사라지고 스트림의 인계 줄이 이어받는다 — 전달 상태가 정해지면
    /// 칩을 옮기거나(전달됨) 카드를 되살린다(실패 · 미확인) (`resolveDelivery`).
    var deliveringHandoffs: [String: DeliveringHandoff] = [:]
    /// 준비가 끝나기 전에 실행이 시작돼 버린 초안 (대화 ID → 안내). 카드 자리에 "다시 만들기" 를 둔다.
    var handoffOutdated: [String: OutdatedHandoff] = [:]
    /// 자동 인계 카운트다운의 타이머 (대화 ID → 작업). 사본을 잡지 않는다 — 울릴 때 카드를 id 로 찾는다.
    @ObservationIgnored var automaticHandoffTasks: [String: Task<Void, Never>] = [:]
    /// 앱 종료를 묻는 중 · 종료하는 중 — 인계를 새로 보내지 않고 카운트다운을 걸지 않는다 (`suspendHandoffsForQuit`).
    /// 종료 확인창이 떠 있는 동안에도 메인 액터 작업은 돌아, 타이머가 전달 CLI 를 띄우면 그 실행은 정리되지 않은 채 남았다.
    @ObservationIgnored var handoffsSuspendedForQuit = false
    /// 자동 인계가 다른 Codex 계정을 골랐을 때의 카운트다운 (대화 ID → 카운트다운). 인계 카드 대신 — 울리면 그 계정으로 바꾸고 같은
    /// 세션에 이어 가기 메시지를 보낸다 (`AppModel+CodexSwitch`). 메모리다.
    var codexSwitchCountdowns: [String: CodexAccountSwitch.Countdown] = [:]
    /// 그 카운트다운의 타이머 (대화 ID → 작업). 울릴 때 카운트다운을 id 로 찾는다.
    @ObservationIgnored var codexSwitchTasks: [String: Task<Void, Never>] = [:]
    /// 대화마다 인계 준비를 시작한 횟수 (`prepareCard`). 자동 인계가 한도 · 로그인 조회를 기다리는 사이 사람이 카드를 열었는지
    /// (넘겼든 취소했든) 가른다 — 그러면 그 결정이 이긴다 (`startAutomaticHandoff`).
    @ObservationIgnored var handoffPreparationSerials: [String: Int] = [:]
    /// 인계 준비 중(카드가 놓이기 전)에 사람이 손댄 대화 — 입력창에서 메시지를 걸었거나 받는 쪽 모델 · 강도를 바꿨다.
    /// 그 준비가 놓는 자동 카드는 카운트다운 대신 사람 확인 길로 (`pauseCountdown` 이 표시하고 `prepareCard` 가 본다).
    @ObservationIgnored var handoffTouchedDuringPreparation: Set<String> = []
    /// 키보드 포커스가 들어간 인계 카드의 대화 (덧붙일 말 · 문서 편집). ⌘↵ 의 주인을 가른다 (`ChangesState.returnKeyOwner`).
    var handoffCardFocusThreadID: String?
    /// 자동 인계 대상인 Claude 의 로그인 확인. 기본은 `claude auth status`.
    /// 검증 하네스가 로그인 상태와 무관한 흐름(취소·검토 등)을 볼 때 바꿔 끼운다.
    @ObservationIgnored var claudeLoginCheck: () async -> Bool? = { nil }

    // 이어 가기 (B 설계 C3 · C4) — 동작은 `AppModel+Continue`, 판정은 `Assist/ContinueChoice` · `ContinueSuggestion`.
    /// 한도 임박 제안 줄의 "나중에" (보내는 쪽 계정 · 창 길이 → 미룬 때의 사용률 · 시각 · 그 창의 초기화 시각). 대화가 아니라
    /// 계정 단위다 — 같은 계정의 다른 대화에도 다시 묻지 않는다. 메모리라 앱을 다시 켜면 비어 있다.
    var continueDismissals: [ContinueSuggestion.DismissKey: ContinueSuggestion.Dismissal] = [:]
    /// 제안이 대상의 한도를 새로 읽게 한 때 (scope → 시각). 화면이 다시 그려질 때마다 부르지 않게 `continueRefreshInterval` 에 한 번.
    @ObservationIgnored var continueRefreshAt: [AgentScope: Date] = [:]
    /// 이어 가기가 오래된 로그인 사실을 다시 확인하게 한 때 (scope → 시각) — 같은 간격으로 한 번.
    @ObservationIgnored var continueLoginRefreshAt: [AgentScope: Date] = [:]

    /// 앱 재시작 시 발견된, 상태가 확정되지 않은 이전 실행.
    var danglingRuns: [Run] = []

    /// 사용자에게 보여줄 일회성 알림 문구.
    var banner: BannerMessage?

    // MARK: 설정
    /// 실행 파일 경로 (설정 > 에이전트 — 화면은 편집이 끝날 때만 바꾼다). 바뀌면 `pathOverrideChanged`.
    var claudePathOverride: String = "" { didSet { pathOverrideChanged(.claude, from: oldValue, to: claudePathOverride) } }
    var codexPathOverride: String = "" { didSet { pathOverrideChanged(.codex, from: oldValue, to: codexPathOverride) } }
    /// 요약 보조(Gemini 로 다듬기)와 작업 에이전트(Antigravity)가 같은 실행 파일을 쓴다.
    var geminiPathOverride: String = "" { didSet { pathOverrideChanged(.gemini, from: oldValue, to: geminiPathOverride) } }
    /// 저장값을 읽는 중 (`loadSettings`) — 경로 · 설정을 넣을 때마다 적용 · 확인하지 않는다 (끝에 한 번 `applyOverrides`).
    @ObservationIgnored private var loadingSettings = false
    /// 코드·로그를 Google 서비스로 보내는 기능이라 명시적으로 켜기 전에는 사용하지 않는다.
    var geminiSummaryEnabled = false {
        didSet {
            persistSetting("gemini_summary_enabled", geminiSummaryEnabled ? "1" : "0")
            // 요약 모델 목록(`agy models` — Google 과 통신)은 고른 뒤에만 읽는다 (`refreshGeminiStatus`, set-20).
            if geminiSummaryEnabled, !oldValue, bootstrapped, !loadingSettings {
                Task { await refreshGeminiStatus() }
            }
        }
    }
    var geminiModel = "" { didSet { persistSetting("gemini_model", geminiModel) } }
    /// 한도 도달만으로 외부 실행이 이어지지 않도록 기본은 꺼 둔다.
    var automaticHandoffEnabled = false {
        didSet { persistSetting("automatic_handoff_enabled", automaticHandoffEnabled ? "1" : "0") }
    }
    var automaticHandoffDelay = 10 {
        didSet { persistSetting("automatic_handoff_delay", String(automaticHandoffDelay)) }
    }
    /// Antigravity 작업 에이전트를 쓸 수 있는 프로젝트.
    ///
    /// Antigravity 는 헤드리스에서 승인을 물을 방법이 없어 **모든 도구를 자동 승인**으로 실행한다
    /// (파일 수정·명령 실행 포함). 그래서 프로젝트마다 명시적으로 켜야 한다. 기본은 꺼짐.
    var antigravityAllowedProjectIDs: Set<String> = [] {
        didSet {
            let value = (try? JSONEncoder().encode(antigravityAllowedProjectIDs))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            persistSetting("antigravity_allowed_projects", value)
            // Antigravity 한도(`agy -p /usage` — Google 과 통신)는 허용한 프로젝트가 있을 때만 읽는다.
            limits.antigravityEnabled = !antigravityAllowedProjectIDs.isEmpty
        }
    }
    /// 켜면 Antigravity 턴을 샌드박스로 실행한다 (셸 명령이 파일을 쓰지 못한다).
    var antigravitySandboxEnabled = true {
        didSet {
            runner.antigravitySandbox = antigravitySandboxEnabled
            persistSetting("antigravity_sandbox", antigravitySandboxEnabled ? "1" : "0")
        }
    }
    /// 자동 인계 대상 우선순위. 값은 `AutomaticHandoffTargets.key` ("claude", "codex:<계정 ID>").
    /// 비어 있거나 일부만 있으면 기본 순서(Claude → Codex 계정 등록 순)로 채운다.
    var automaticHandoffPriority: [String] = [] {
        didSet {
            let value = (try? JSONEncoder().encode(automaticHandoffPriority))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            persistSetting("automatic_handoff_priority", value)
        }
    }
    /// 이어 받을 순서에서 "받지 않음" 으로 둔 대상 (`AutomaticHandoffTargets.key`). 자동 인계 · 이어 가기 제안 · 한도 줄이 고르지 않는다 —
    /// 입력창의 에이전트 메뉴에서 직접 이어 맡기는 것은 된다 (설정 > 인계).
    var automaticHandoffExcluded: Set<String> = [] {
        didSet {
            let value = (try? JSONEncoder().encode(automaticHandoffExcluded.sorted()))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            persistSetting("automatic_handoff_excluded", value)
        }
    }
    var geminiExcludedProjectIDs: Set<String> = [] {
        didSet {
            let value = (try? JSONEncoder().encode(geminiExcludedProjectIDs))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            persistSetting("gemini_excluded_projects", value)
        }
    }
    /// Claude · Codex 의 기본 추론 강도 — 설정 > 에이전트에서 **사람이 고른 것만** 들어 있다. 없으면 "모델 기본값":
    /// Codex 는 계정의 config.toml `model_reasoning_effort` → 그 모델의 CLI 기본 강도, Claude 는 High (`EffortScale.resolvedDefault`).
    /// 강도를 고르지 않은 대화는 화면 · 전송이 같은 차례로 푼다 (`effortDefaults` → `EffortScale.displayEffort(… defaults:)`).
    /// "CLI 기본값" 상태는 두지 않는다 — 늘 구체적인 값으로 보이고 그 값으로 보낸다. 저장은 `default_effort_<제공자>` (빈 값 = 모델 기본값).
    var defaultEfforts: [AgentProvider: String] = [:] {
        didSet {
            runner.defaultEfforts = defaultEfforts
            reviewLanes.configure { $0.defaultEfforts = defaultEfforts }
            for provider in [AgentProvider.claude, .codex] where defaultEfforts[provider] != oldValue[provider] {
                persistSetting("default_effort_\(provider.rawValue)", defaultEfforts[provider] ?? "")
            }
        }
    }

    /// 설정 화면 · 옛 호출부가 보는 기본 강도 이름 — 고르지 않았으면 앱 기본(High). Codex 의 "모델 기본값" 은 `userDefaultEffort` 가 nil.
    func defaultEffort(for provider: AgentProvider) -> String {
        defaultEfforts[provider] ?? EffortScale.builtInDefault
    }

    /// 설정에서 사람이 고른 기본 강도 (없으면 nil — 모델 기본값).
    func userDefaultEffort(for provider: AgentProvider) -> String? { defaultEfforts[provider] }

    /// 설정 > 에이전트에서 기본 추론 강도를 바꾼다 (빈 값 · nil = 모델 기본값). 기본 강도는 새로 정하는 대화(이어받을 대화가 없는 새 대화 ·
    /// 처음 쓰는 에이전트)에만 쓰인다 — 바꾸기 전에, 이미 쓴(모델을 정한) 대화 가운데 강도가 빈 것(이 수정 전에 쓴 대화)을 지금 보이는
    /// 강도로 정해 둔다. 그래야 열린 대화가 모르는 사이 새 기본 강도(MAX 등)로 보내 한도를 더 쓰지 않는다 (set-n2).
    /// 정해 둔 대화의 "마지막에 쓴 때"(`updatedAt`)는 그대로 둔다 — 새 대화가 이어받을 대화의 차례가 바뀌지 않게.
    func setDefaultEffort(_ effort: String?, for provider: AgentProvider) {
        let value = effort.flatMap { $0.isEmpty ? nil : $0 }
        guard provider != .gemini, defaultEfforts[provider] != value else { return }
        // 메모리 먼저 (화면 · 이어받기가 곧바로 본다) — 강도를 푸는 재료는 아직 옛 설정이다.
        var pinned: [(id: String, projectID: String, effort: String)] = []
        for var thread in allThreads() {
            let selection = thread.selection(for: provider)
            guard ModelDefaults.hasChosenModel(selection, provider: provider), selection.effort?.isEmpty ?? true,
                  let shown = resolvedDefaultEffort(model: selection.model, provider: provider,
                                                    scope: selectionScope(for: thread, provider: provider, accountID: nil))
            else { continue }
            thread.setSelection(ModelSelection(model: selection.model, effort: shown), for: provider)
            if let index = threadsByProject[thread.projectID]?.firstIndex(where: { $0.id == thread.id }) {
                threadsByProject[thread.projectID]?[index] = thread
            }
            pinned.append((thread.id, thread.projectID, shown))
        }
        defaultEfforts[provider] = value
        guard !pinned.isEmpty else { return }
        Task {
            for pin in pinned {
                try? await store.pinThreadEffortIfUnset(id: pin.id, provider: provider, effort: pin.effort)
            }
            for projectID in Set(pinned.map(\.projectID)) {
                await reloadThreads(projectID: projectID, after: beginThreadWrite(projectID))
            }
        }
    }

    var claudePermissionMode: String = "manual" {
        didSet { runner.claudePermissionMode = claudePermissionMode; persistSetting("claude_permission_mode", claudePermissionMode) }
    }
    var codexSandboxMode: String = "workspace-write" {
        didSet { runner.codexSandboxMode = codexSandboxMode; persistSetting("codex_sandbox", codexSandboxMode) }
    }
    var codexApprovalPolicy: String = "on-request" {
        didSet { runner.codexApprovalPolicy = codexApprovalPolicy; persistSetting("codex_approval", codexApprovalPolicy) }
    }
    /// 승인을 묻지 않고 허용하는 대화 — 입력창의 승인 칩 (`setAutoApproval`, `AppModel+Composer`). 실행은 요청마다 이 값을 본다.
    var autoApprovalThreadIDs: Set<String> = [] {
        didSet {
            runner.autoApprovalThreadIDs = autoApprovalThreadIDs
            persistSetting("auto_approval_threads", Self.jsonString(autoApprovalThreadIDs.sorted()))
        }
    }
    /// Claude 를 API 키로 실행하는 대화 — 모델 칩 팝오버의 "API 크레딧으로 실행" (`setClaudeAPI`, `AppModel+ClaudeAPI`).
    /// 실행에는 키가 저장돼 있을 때만 넘긴다 (`syncClaudeAPIRunner`).
    var claudeAPIThreadIDs: Set<String> = [] {
        didSet {
            syncClaudeAPIRunner()
            persistSetting("claude_api_threads", Self.jsonString(claudeAPIThreadIDs.sorted()))
        }
    }
    /// 저장된 Claude API 키의 모양 ("sk-ant-…a1b2") — 키가 없으면 nil. 키 자체는 키체인에만 있다 (`ClaudeAPIKey`).
    /// 앱을 켤 때 키체인을 읽지 않으려고 따로 둔다.
    var claudeAPIKeyHint: String? {
        didSet {
            syncClaudeAPIRunner()
            persistSetting("claude_api_key_hint", claudeAPIKeyHint ?? "")
        }
    }
    /// 실행 중에 보낸 메시지 (대화 → 차례). 그 대화의 실행이 정상으로 끝나면 앞에서부터 하나씩 보낸다 (`AppModel+Composer`).
    var messageQueues: [String: [QueuedMessage]] = [:] {
        didSet { persistSetting("message_queue", Self.jsonString(messageQueues)) }
    }
    /// 대기열을 멈춘 이유 (대화 → 이유). 실행이 실패 · 중단 · 한도로 끝나거나 앱을 다시 켜면 보내지 않고 멈춘다.
    var queuePauseReasons: [String: String] = [:]
    /// 인계 카드(준비 · 전달 중 포함)가 있는 대화의 대기열 보류 (대화 → 보내는 쪽 · 받는 쪽). 멈춤 이유와 따로 —
    /// 그동안 걸어 둔 메시지는 인계가 확인되면 받는 쪽에게 간다 (`AppModel+Composer`). 보류인 대화는 대기열과 함께 저장한다 —
    /// 다시 켜면 카드가 없으므로 멈춤 이유로 바꾼다 (`restoreMessageQueues`).
    var queueHolds: [String: QueueHold] = [:] {
        didSet {
            guard Set(queueHolds.keys) != Set(oldValue.keys) else { return }
            persistSetting("message_queue_holds", Self.jsonString(queueHolds.keys.sorted()))
        }
    }
    /// 입력창에 붙인 이미지 (대화 → 이미지). 파일은 앱 데이터 폴더에 복사돼 있다 (`ImageAttachments`). 글 초안처럼 남긴다 —
    /// 설정 `composer_attachments` 에 저장하고, 앱을 켤 때 파일이 남아 있는 것만 되살린다 (`restoreComposerAttachments`).
    var composerAttachments: [String: [ImageAttachment]] = [:] {
        didSet {
            guard composerAttachments != oldValue, composerAttachmentsRestored else { return }
            persistSetting("composer_attachments", Self.jsonString(composerAttachments))
        }
    }
    /// 저장된 첨부를 되살린 뒤에만 저장한다 (켜는 사이 빈 값으로 덮지 않게).
    @ObservationIgnored var composerAttachmentsRestored = false
    /// 붙인 이미지를 두는 폴더 (`ImageAttachments.directory` — DB 옆). 대화를 지우면 이 폴더 바로 아래의 파일만 지운다
    /// (`removeOrphanedAttachments`). 시험은 임시 폴더로 바꾼다.
    @ObservationIgnored var attachmentsDirectory: URL = ImageAttachments.directory
    /// 차례로 도는 첨부 지우기의 마지막 작업 (`removeOrphanedAttachments`) — 시험이 기다린다.
    @ObservationIgnored var attachmentCleanup: Task<Void, Never>?
    /// 입력창에서 보낸 메시지가 실행으로 시작되기 전의 단계 (대화 → 단계, `AppModel.send`). 입력창이 "보내는 중" 을 보이고
    /// 그동안 같은 대화의 보내기 · 대기열 보내기를 받지 않는다 — ↵ 를 한 번 더 눌러 같은 부탁이 대기열에 복제되지 않게 (chat-1).
    var sendingThreads: [String: SendStage] = [:]
    /// "보내는 중" 인 메시지의 글 · 이미지 (대화 → 보낸 것). 입력창은 ↵ 순간 비워 저장하므로, 시작되기 전에 앱을 끄면 보낸 글이 어디에도
    /// 남지 않았다 (conv-3 · chr-9) — 종료가 확정되면 입력창 초안으로 되돌려 저장한다 (`saveBeforeQuit`).
    @ObservationIgnored var sendingMessages: [String: QueuedMessage] = [:]
    func isSending(threadID: String) -> Bool { sendingThreads[threadID] != nil }
    /// 입력창이 ↵ 를 누른 순간 "보내는 중" 자리를 잡는다 — 뒤의 `send(… reserved: true)` 가 그 자리로 보낸다. 이미 보내는 중이면 false.
    func reserveSend(threadID: String) -> Bool {
        guard sendingThreads[threadID] == nil else { return false }
        sendingThreads[threadID] = .preparing
        return true
    }
    /// 대기열에서 막 뺀 메시지 (대화 → 뺀 것) — 몇 초 동안 되돌릴 수 있다 (`undoQueueRemoval`).
    var removedQueuedMessages: [String: RemovedQueuedMessage] = [:]
    /// "멈추고 보내기" 로 멈춘 실행 (대화 → 실행 ID) — 그 실행이 멈춰 끝나도 대기열을 멈추지 않고 이어 보낸다 (`stopAndSendQueue`).
    @ObservationIgnored var queueSendAfterStop: [String: String] = [:]
    /// 승인 · 질문을 기다리는 동안 답처럼 보이는 글을 걸려다 확인을 받은 때 (대화 → 글 · 시각) — 같은 글로 다시 ↵ 하면 건다.
    @ObservationIgnored var replyConfirmations: [String: (text: String, at: Date)] = [:]
    /// 이미지를 가져오는 중인 수 (대화 → 수) — 입력창이 자리를 비워 둔다.
    var importingAttachments: [String: Int] = [:]
    /// 도는 독립 작업 폴더 명령 (만들기 · 합치기 · 맞추기 · 정리 · 다시 만들기) — 그 폴더들의 보내기 · git 쓰기를 막는다 (`AppModel+Worktree`).
    var worktreeOperation: WorktreeOperation?
    /// 도는 독립 작업 폴더의 준비 명령 (대화 → 명령, 최대 10분). 그 대화 · 그 폴더만 막는다 (`worktreeActivity` — chg-9).
    var worktreeSetups: [String: WorktreeOperation] = [:]
    /// 대화별 독립 작업 폴더의 상태 (대화 → 상태). 변경사항 탭 · 대화 설정이 연다 (`refreshWorktreeStatus`).
    var worktreeStatuses: [String: Worktrees.Status] = [:]
    /// 독립 작업 폴더를 만든 뒤 그 폴더에서 돌릴 준비 명령 (프로젝트 → 명령). 프로젝트 설정에서 사람이 적은 것만 돈다.
    var worktreeSetupCommands: [String: String] = [:] {
        didSet { persistSetting("worktree_setup_commands", Self.jsonString(worktreeSetupCommands)) }
    }
    /// 작업 폴더를 옮긴 대화의 다음 턴에 에이전트에게 붙일 안내 ("대화|제공자" → 글). 보내면 지운다.
    var folderMoveNotes: [String: String] = [:] {
        didSet { persistSetting("folder_move_notes", Self.jsonString(folderMoveNotes)) }
    }
    var notificationsEnabled = true {
        didSet { notifications.enabled = notificationsEnabled; persistSetting("notifications_enabled", notificationsEnabled ? "1" : "0") }
    }
    /// 앱 시작 시 Claude 한도를 조회할지. **기본 켜짐.**
    ///
    /// `claude -p /usage` 는 전체 Claude Code 세션을 띄우므로 사용자의 훅과 MCP 서버가 함께 실행된다.
    /// 이 앱은 샌드박스가 없어 그 자식 프로세스의 시스템 권한 요청이 이 앱 이름으로 표시된다.
    /// 2026-09-09 이 Mac 에서 실측: 앱 시작 시 사진 보관함 접근 요청이 떴고,
    /// 이 옵션을 끄면 재현되지 않았다. 사용자가 그 권한 요청을 감수하기로 해서 기본은 켜 둔다.
    /// 요청을 거절해도 한도 조회를 제외한 앱 기능에는 영향이 없다.
    ///
    /// 대신 Claude 는 실행 중 `rate_limit_event` 로 구조화된 한도 정보를 보내주므로
    /// (실측 확인) 한 번이라도 대화하면 값이 채워진다. 수동 새로고침도 언제든 가능하다.
    /// 값이 없는 동안에는 0% 가 아니라 "정보 없음"으로 표시한다.
    var startupFetchClaudeLimits = true {
        didSet { persistSetting("startup_fetch_claude_limits", startupFetchClaudeLimits ? "1" : "0") }
    }
    /// 셸(`~/.zshrc`)의 API 키 · 토큰(`CLIEnvironment.authVariableNames`)을 에이전트에게 넘기는가. **기본 꺼짐** (onb-19) — `claude -p` 는
    /// 환경의 `ANTHROPIC_API_KEY` 를 구독 로그인보다 먼저 써서, 다른 일로 키를 둔 구독 사용자의 모든 실행이 API 요금으로 청구됐다.
    /// 프록시 · Bedrock · Vertex 같은 나머지 변수는 이 설정과 상관없이 넘긴다. 바꾸면 에이전트를 모두 다시 확인한다 (로그인 판정이 바뀐다).
    var forwardShellAuth = false {
        didSet {
            guard forwardShellAuth != oldValue else { return }
            persistSetting("forward_shell_auth", forwardShellAuth ? "1" : "0")
            guard !loadingSettings else { return }
            let on = forwardShellAuth
            Task { [weak self] in
                guard let self else { return }
                await self.environment.setForwardsShellAuth(on)
                if self.bootstrapped && !Self.offlinePreview { await self.recheckAllAgents() }
            }
        }
    }
    /// 첫 턴이 끝나면 그 대화의 에이전트(가장 작은 모델)에게 짧은 제목을 한 번 묻는다 (`summarizeTitleIfNeeded` · `ThreadTitle`).
    /// 기본 켬 — 구독 사용량을 조금 쓴다 (Claude Haiku 출력 10토큰 남짓 · Codex 3천 토큰 남짓).
    /// 새로 만드는 대화를 자동 승인으로 시작한다 (설정 > 에이전트 — 기본 꺼짐, 켤 때 한 번 확인). 새 대화에만 — 이미 있는 대화는
    /// 그대로다. 그 뒤의 규칙은 같다: 권한 요청 · MCP 입력 요청 · 질문은 늘 카드(`ApprovalKind.allowsAutoApproval`), 다른 회사의
    /// 에이전트로 바꾸거나 인계로 받는 에이전트가 바뀌면 끈다, Antigravity(승인을 묻지 않는다) · 자동 작업의 내부 대화는 해당 없다.
    var newThreadsAutoApprove = false {
        didSet { persistSetting("new_threads_auto_approve", newThreadsAutoApprove ? "1" : "0") }
    }

    var autoThreadTitles = true {
        didSet { persistSetting("auto_thread_titles", autoThreadTitles ? "1" : "0") }
    }
    /// 제목 요약을 바꿔 끼운다 (검증 하네스 · 화면 확인 — 실제 CLI 를 부르지 않게). nil 이면 CLI 에게 묻는다.
    var threadTitleSummarizerOverride: (@Sendable (ThreadTitle.Request) async -> String?)?
    /// 이번 실행에서 제목을 요약했거나 묻는 중인 대화 — 같은 대화에 두 번 묻지 않는다 (메모리).
    var titleSummaryThreadIDs: Set<String> = []
    /// MAX/ULTRA 추론 연출 효과음. **기본 꺼짐** — 소리는 기본값이면 금방 거슬린다.
    var ultraSoundEnabled = false {
        didSet { persistSetting("ultra_sound", ultraSoundEnabled ? "1" : "0") }
    }
    /// 메뉴바 팝오버에서 숨긴 한도 — 계정 · 구간의 키 (`MenuBarLimits`, 설정 > 일반 > 메뉴바). 숨긴 것만 둔다 — 새 계정 · 구간은 보인다.
    var menuBarHiddenLimits: Set<String> = [] {
        didSet { persistSetting("menu_bar_hidden_limits", Self.jsonString(menuBarHiddenLimits.sorted())) }
    }

    func setMenuBarLimit(_ key: String, shown: Bool) {
        if shown { menuBarHiddenLimits.remove(key) } else { menuBarHiddenLimits.insert(key) }
    }
    /// 독립 작업 폴더를 만드는 곳 (설정 > 고급). 비어 있으면 기본 위치 (`Worktrees.baseDirectory`). 새로 만드는 작업 폴더부터 쓴다 —
    /// 이미 만든 것은 대화에 경로가 남아 있어 옮기지 않는다.
    var worktreesDirectoryOverride = "" {
        didSet {
            Worktrees.userBaseDirectory = worktreesDirectoryOverride.isEmpty ? nil : worktreesDirectoryOverride
            persistSetting("worktrees_dir", worktreesDirectoryOverride)
        }
    }

    #if DEBUG
    /// 화면 확인용 실행. CLI 를 부르지 않고 저장된 기록만 보여준다 (`AHC_OFFLINE=1`, Debug 빌드 전용).
    static let offlinePreview = ProcessInfo.processInfo.environment["AHC_OFFLINE"] == "1"

    /// 확인 창을 건너뛰는 화면 확인용 git 쓰기(`-preview.action push` 등)를 해도 되는 폴더인지 — 임시 폴더
    /// (`/tmp` · `/private/var/folders`) 안의 시나리오 저장소에서만. 실제 프로젝트에서 잘못 켜도 올리거나 받지 않게 한다.
    static func isTemporaryPreviewProject(_ path: String) -> Bool {
        let temporary = [NSTemporaryDirectory(), "/private/tmp/", "/tmp/", "/private/var/folders/"]
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path + "/" }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path + "/"
        return temporary.contains { resolved.hasPrefix($0) }
    }
    #else
    static let offlinePreview = false
    #endif

    struct BannerMessage: Identifiable {
        let id = UUID()
        var text: String
        var isError: Bool
        /// 닫기 옆의 동작 버튼 (없으면 닫기만).
        var actionTitle: String?
        var action: (@MainActor () -> Void)?
        /// 어느 대화의 일인지. 그 대화 칸의 **입력창 바로 위**에 보인다 (보내기 실패 · 첨부 오류 — 보낸 자리에서 보이게).
        /// nil 이면 대화와 무관한 것 — 창의 가운데 칸 맨 위에 보인다 (어느 칸에도 열리지 않은 대화의 알림도 거기).
        var threadID: String?
        /// 동작 버튼이 여는 곳 (시작 점검 · 설정 > 에이전트) — 설정 창은 화면만 열 수 있어 `action` 대신 화면이 연다.
        var opens: SendReadiness.Destination? = nil
    }

    init(store: Store) {
        self.store = store
        self.limits = LimitsService(environment: environment)
        self.accounts = CodexAccountService(store: store)
        self.detachedWorkspace = WorkspaceModel(environment: environment)
        self.runner = RunCoordinator(store: store, environment: environment)
        self.reviewLanes = ReadOnlyRunPool(store: store, environment: environment)
        self.geminiAssist = GeminiAssistService(environment: environment)
        let commandEnvironment = environment
        self.orchestration = OrchestrationCoordinator(
            store: store, commandRunner: ShellVerificationCommandRunner(environment: { await commandEnvironment.childEnvironment() }))
        self.runner.delegate = self
        self.runner.slashCommandsHandler = { [weak self] key, commands in self?.receiveSlashCommands(commands, for: key) }
        // Codex 한도를 읽을 때 CLI 가 알려 준 계정(이메일 · 플랜)을 계정 목록에 — 앱은 id_token 을 풀지 않는다.
        let codexAccounts = self.accounts
        self.limits.codexAccountRead = { id, read in await codexAccounts.applyAccountRead(id, read) }
        self.reviewLanes.configure { $0.delegate = self }
        self.orchestration.host = self
        let environment = self.environment
        self.claudeLoginCheck = { await environment.claudeLoggedIn() }
        #if DEBUG
        // `-preview.notificationThread <스레드 ID>` (AHC_OFFLINE=1): 창이 없을 때 알림을 눌러 앱이 열린 상황.
        // 이동 요청이 창(ContentView)보다 먼저 와 있는 상태를 만든다.
        if Self.offlinePreview,
           let id = UserDefaults.standard.string(forKey: "preview.notificationThread") {
            notifications.pendingThreadID = id
        }
        #endif
    }

    convenience init() {
        self.init(store: Store(databaseURL: Store.defaultDatabaseURL()))
    }

    // MARK: - 부트스트랩

    func bootstrap() async {
        do {
            try await store.bootstrap()
            // 보내는 도중 앱이 죽어 '전송 중' 으로 남은 인계는 전달 여부 미확인으로 (자동 인계가 그 위에 또 보내지 않게).
            // 대화 기록을 읽기 전에 — 다시 켠 화면에 '전송 중' 이 남지 않게.
            if !Self.offlinePreview {
                try? await store.markOrphanedHandoffsUnknown(note: "앱이 보내는 도중 종료돼 전달 여부를 확인하지 못했습니다")
            }
            await runner.loadPrices()
            await reviewLanes.loadPrices()
            await loadSettings()
            await accounts.load()
            limits.setCodexAccounts(accounts.refs)
            // Command Line Tools 가 있는지 먼저 (`xcode-select -p` 만 — 금방 끝난다). 대화 목록을 읽으면 열린 칸의 작업 폴더 git 을
            // 읽는데, 그때 CLT 가 없는 Mac 의 `/usr/bin/git` shim 을 고르면 설치 창이 뜬다 (`GitInspector.systemGitShimUnavailable`).
            if !Self.offlinePreview { gitTools = await Self.readGitTools() }
            await reloadProjects()
            // 앱을 다시 켜면 남은 대기열은 멈춘 채로 둔다 (칩 이름을 적으려고 대화 목록을 읽은 뒤에).
            await restoreMessageQueues()
            // 입력창에 붙여 둔 이미지 (파일이 남아 있는 것만 — 글 초안처럼).
            await restoreComposerAttachments()
            orchestrationSettings = await orchestration.currentSettings()
            // 끝나지 않은 자동 작업: 돌던 시도는 전달 여부 미확인으로, 나머지는 일시 정지로. 켜자마자 돌리지 않는다.
            // (화면 확인용 실행은 넣어 둔 상태를 그대로 보여 준다.)
            if !Self.offlinePreview { await orchestration.recoverAfterLaunch() }

            // 앱 재시작 시 이전 실행을 자동 완료 처리하지 않는다.
            await loadModelCatalogs()
            danglingRuns = (try? await store.danglingActiveRuns()) ?? []
            if !danglingRuns.isEmpty {
                banner = BannerMessage(
                    text: "이전에 종료가 확인되지 않은 실행이 \(danglingRuns.count)건 있습니다. "
                        + "기록은 보존했으며 자동으로 완료 처리하지 않았습니다. 정리하면 '종료 미확인' 으로 닫습니다.",
                    isError: false,
                    actionTitle: "정리",
                    action: { [weak self] in Task { await self?.closeDanglingRuns() } })
            }
            if Self.offlinePreview {
                #if DEBUG
                // 점검표의 사실은 실제 CLI · 알림 권한을 묻지 않고 인수에서 받는다 (`-preview.firstRun`, `FirstRunFacts.preview`).
                previewFirstRunFacts = FirstRunFacts.preview(UserDefaults.standard.string(forKey: "preview.firstRun"))
                #endif
                bootstrapped = true
                return
            }
            // 새 사용자(프로젝트 없음)는 시작 때 `claude -p` 세션(모델 목록 · /usage)을 띄우지 않는다 — 훅 · MCP 의 권한 창이
            // 폴더를 고르기도 전에 뜬다. 첫 프로젝트가 생긴 뒤 한 번 한다 (`runDeferredClaudeStartup`).
            deferredClaudeStartup = projects.isEmpty
            // 알림 설정은 권한을 묻지 않고 곧 읽힌다 — CLI 확인(로그인 셸 PATH · 버전 · 로그인, 몇 초)을 기다리지 않게 먼저.
            Task { await notifications.readSettings() }
            // 비정상으로 끝난 앱이 남긴 Codex 실행 폴더(링크만 든 임시 폴더 — `CodexRunHome`)를 지운다.
            Task.detached { CodexRunHome.removeStale() }
            // CLI 상태 · Claude 로그인 · Codex 계정 · Git 을 함께 확인한다 (점검표와 같은 길 — `AppModel+Setup`).
            await refreshAgentFacts()
            // 자동 인계 알림의 [취소] · [검토] · 본문 누르기 — 창이 닫혀 있어도 모델이 직접 받는다. 둘 다 카운트다운을 멈추고
            // 카드를 검토(사람이 멈춤)로 둔다 — 대기열은 계속 보류. 검토 · 본문은 창을 열고 카드로 간다 (`ContentView`).
            notifications.automaticActionHandler = { [weak self] action, threadID in
                guard let self, let threadID else { return }
                // 다른 Codex 계정에서 이어 가려는 카운트다운이면 [취소] · [검토] 모두 그것을 멈춘다 (검토는 창을 열어 대화로 간다).
                if self.codexSwitchCountdowns[threadID] != nil {
                    self.cancelCodexSwitchCountdown(threadID: threadID)
                    return
                }
                switch action {
                case .cancel: self.cancelHandoff(threadID: threadID, origin: .notification)
                case .review: self.pauseCountdown(threadID: threadID)
                }
            }
            notifications.bootstrap()
            notifications.enabled = notificationsEnabled
            bootstrapped = true
            let deferClaude = deferredClaudeStartup
            Task { await refreshModelCatalogsIfStale(skippingClaude: deferClaude) }
            // `agy models` 는 네트워크를 탈 수 있어 시작을 막지 않는다.
            Task { await refreshGeminiStatus() }
            Task {
                // Codex 한도 조회는 스레드를 만들지 않아 MCP 서버를 띄우지 않는다.
                // 계정을 번갈아 쓰려면 어느 쪽에 여유가 있는지 함께 봐야 하므로 전 계정을 조회한다.
                await limits.refreshAllCodex()
                if startupFetchClaudeLimits, !deferClaude { await limits.refresh(.claude) }
                // Antigravity 는 허용한 프로젝트가 있을 때만 (`LimitsService.antigravityEnabled`) — 화면 확인용 실행은 부르지 않는다.
                if !Self.offlinePreview { await limits.refresh(.gemini) }
            }
        } catch {
            bootstrapError = error.localizedDescription
        }
    }

    private func loadSettings() async {
        loadingSettings = true
        defer { loadingSettings = false }
        claudePathOverrideSilently(await (try? store.setting("claude_path")) ?? "")
        codexPathOverrideSilently(await (try? store.setting("codex_path")) ?? "")
        geminiPathOverride = await (try? store.setting("gemini_path")) ?? ""
        if let v = try? await store.setting("claude_permission_mode") { claudePermissionMode = v }
        for provider in [AgentProvider.claude, .codex] {
            if let v = try? await store.setting("default_effort_\(provider.rawValue)"), !v.isEmpty {
                defaultEfforts[provider] = v
            }
        }
        if let v = try? await store.setting("codex_sandbox") { codexSandboxMode = v }
        if let v = try? await store.setting("codex_approval") { codexApprovalPolicy = v }
        if let v = try? await store.setting("notifications_enabled") { notificationsEnabled = v == "1" }
        if let v = try? await store.setting("startup_fetch_claude_limits") {
            startupFetchClaudeLimits = v == "1"
        }
        if let v = try? await store.setting("ultra_sound") { ultraSoundEnabled = v == "1" }
        if let v = try? await store.setting("menu_bar_hidden_limits"), let data = v.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            menuBarHiddenLimits = Set(decoded)
        }
        if let v = try? await store.setting("auto_thread_titles") { autoThreadTitles = v == "1" }
        if let v = try? await store.setting("new_threads_auto_approve") { newThreadsAutoApprove = v == "1" }
        if let v = try? await store.setting("forward_shell_auth") { forwardShellAuth = v == "1" }
        await environment.setForwardsShellAuth(forwardShellAuth)
        if let v = try? await store.setting("worktrees_dir") { worktreesDirectoryOverride = v }
        if let v = try? await store.setting("gemini_summary_enabled") { geminiSummaryEnabled = v == "1" }
        if let v = try? await store.setting("gemini_model") { geminiModel = v }
        if let v = try? await store.setting("automatic_handoff_enabled") {
            automaticHandoffEnabled = v == "1"
        }
        if let v = try? await store.setting("automatic_handoff_delay"), let seconds = Int(v) {
            automaticHandoffDelay = [5, 10, 30].contains(seconds) ? seconds : 10
        }
        if let v = try? await store.setting("gemini_excluded_projects"),
           let data = v.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            geminiExcludedProjectIDs = decoded
        }
        if let v = try? await store.setting("antigravity_allowed_projects"),
           let data = v.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            antigravityAllowedProjectIDs = decoded
        }
        if let v = try? await store.setting("antigravity_sandbox") {
            antigravitySandboxEnabled = v == "1"
        }
        if let v = try? await store.setting("automatic_handoff_priority"),
           let data = v.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            automaticHandoffPriority = decoded
        }
        if let v = try? await store.setting("automatic_handoff_excluded"), let data = v.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            automaticHandoffExcluded = Set(decoded)
        }
        if let v = try? await store.setting("auto_approval_threads"), let data = v.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            autoApprovalThreadIDs = Set(decoded)
        }
        if let v = try? await store.setting("claude_api_key_hint"), !v.isEmpty { claudeAPIKeyHint = v }
        if let v = try? await store.setting("claude_api_threads"), let data = v.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            claudeAPIThreadIDs = Set(decoded)
        }
        if let v = try? await store.setting("worktree_setup_commands"), let data = v.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            worktreeSetupCommands = decoded
        }
        if let v = try? await store.setting("slash_commands") { restoreSlashCommands(v) }
        if let v = try? await store.setting("folder_move_notes"), let data = v.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            folderMoveNotes = decoded
        }
        if let v = try? await store.setting("selected_thread") { selectedThreadID = v }
        // 칸 배치. 없어진 대화는 `reloadProjects` 가 걸러 낸다.
        if let layout = (try? await store.setting("pane_layout")).flatMap({ $0 }).flatMap(PaneLayout.init(rawValue:)) {
            let stored = (try? await store.setting("pane_threads")).flatMap { $0 }?.data(using: .utf8)
                .flatMap { try? JSONDecoder().decode([String?].self, from: $0) } ?? []
            let focused = (try? await store.setting("pane_focused")).flatMap { $0 }.flatMap(Int.init) ?? 0
            var restored = PaneArrangement()
            restored.layout = layout
            restored.threadIDs = stored
            restored.focused = focused
            // 줄이기 전에 기억해 둔 배치 (다시 늘리면 되살린다). 없어진 대화는 `reloadProjects` 가 걸러 낸다.
            if let memory = (try? await store.setting("pane_memory")).flatMap({ $0 })?.data(using: .utf8)
                .flatMap({ try? JSONDecoder().decode(PaneMemory.self, from: $0) }) {
                restored.remembered = memory.threads
                restored.rememberedFocus = memory.focus
                restored.rememberedAt = memory.at
            }
            panes = restored
        }
        await applyOverrides()
    }

    private func claudePathOverrideSilently(_ v: String?) { claudePathOverride = v ?? "" }
    private func codexPathOverrideSilently(_ v: String?) { codexPathOverride = v ?? "" }

    private func applyOverrides() async {
        await environment.setOverrides(CLIEnvironment.Override(
            claudePath: claudePathOverride.isEmpty ? nil : claudePathOverride,
            codexPath: codexPathOverride.isEmpty ? nil : codexPathOverride,
            geminiPath: geminiPathOverride.isEmpty ? nil : geminiPathOverride))
        persistSetting("claude_path", claudePathOverride)
        persistSetting("codex_path", codexPathOverride)
        persistSetting("gemini_path", geminiPathOverride)
    }

    /// 실행 파일 경로가 바뀌었다: 환경 덮어쓰기 · 저장을 하고, 부트스트랩이 끝난 뒤라면 그 제공자만 다시 확인한다 — 그동안 그 카드는
    /// "확인 중" (set-1: 다시 확인하지 않아 옛 확인 결과와 새 경로를 섞어 판정했다 — 맞는 파일을 골라도 "실행할 수 없음",
    /// 틀린 경로에도 "준비됨"). 부트스트랩 전(검증 하네스의 모델)에는 Gemini 정리가 쓸 경로 · 버전만 다시 읽는다.
    private func pathOverrideChanged(_ provider: AgentProvider, from old: String, to new: String) {
        guard old != new, !loadingSettings else { return }
        let checking = bootstrapped && !Self.offlinePreview
        let serial: Int? = checking ? beginAgentRecheck([provider]) : nil
        pathChangeTasks[provider]?.cancel()
        pathChangeTasks[provider] = Task { [weak self] in
            guard let self else { return }
            await self.applyOverrides()
            if checking {
                if !Task.isCancelled { await self.recheckAgent(provider) }
            } else if provider == .gemini {
                await self.refreshGeminiStatus(force: true)
            }
            if let serial { self.endAgentRecheck([provider], serial: serial) }
        }
    }

    func persistSetting(_ key: String, _ value: String) {
        Task { try? await store.setSetting(key, value) }
    }

    static func jsonString<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    // MARK: - 모델 목록

    func options(for scope: AgentScope) -> [AgentModelOption] {
        modelCatalogs[scope]?.options ?? []
    }

    /// 지금 화면에 필요한 범위 전부 (Claude + Antigravity + 등록된 Codex 계정).
    var activeScopes: [AgentScope] {
        [.claude, .gemini] + accounts.accounts.map { $0.scope }
    }

    func loadModelCatalogs() async {
        for scope in activeScopes {
            let options = (try? await store.modelOptions(scope: scope)) ?? []
            guard !options.isEmpty else { continue }
            var snapshot = ModelCatalogSnapshot(provider: scope.provider,
                                                accountID: scope.accountID)
            snapshot.options = ModelCatalog.presentableOptions(options)
            snapshot.fetchedAt = try? await store.modelCatalogFetchedAt(scope: scope)
            snapshot.discovered = options.allSatisfy { $0.isDiscovered }
            modelCatalogs[scope] = snapshot
            if let version = (try? await store.setting(Self.modelCatalogVersionKey(scope))).flatMap({ $0 }), !version.isEmpty {
                modelCatalogVersions[scope] = version
            }
        }
        if let raw = (try? await store.setting("claude_model_names")).flatMap({ $0 })?.data(using: .utf8) {
            claudeModelNames = try? JSONDecoder().decode(ClaudeModelNames.self, from: raw)
        }
    }

    static func modelCatalogVersionKey(_ scope: AgentScope) -> String {
        "model_catalog_version|\(scope.provider.rawValue)|\(scope.accountID)"
    }

    /// 시작할 때 다시 받을 범위인가 (순수). Antigravity 는 네트워크를 탈 수 있어 하루 동안 둔다. Claude 는 `claude -p` 세션을 띄우므로
    /// (훅 · MCP 서버도 함께 뜬다) 받아 둔 목록이 있으면 하루 · CLI 버전이 바뀌었을 때만 — 그사이 바뀐 기본 모델은 목록의 새로고침이
    /// 받는다 (새 대화는 마지막에 쓴 모델을 이어받는다). Codex 는 `app-server` 의 `model/list` 라 시작할 때마다 받는다.
    nonisolated static func catalogNeedsRefresh(provider: AgentProvider, snapshot: ModelCatalogSnapshot?, fetchedVersion: String?,
                                                currentVersion: String?, now: Date = Date()) -> Bool {
        guard let snapshot, !snapshot.options.isEmpty else { return true }
        let stale = snapshot.fetchedAt.map { now.timeIntervalSince($0) > 86_400 } ?? true
        switch provider {
        case .codex: return true
        case .gemini: return stale
        case .claude:
            if stale || !snapshot.discovered { return true }
            guard let currentVersion, let fetchedVersion else { return false }
            return currentVersion != fetchedVersion
        }
    }

    /// 시작할 때 다시 읽는 모델 목록: Codex 는 다시 받고, Claude 는 하루가 지났거나 CLI 버전이 바뀌었을 때만(`catalogNeedsRefresh`),
    /// Antigravity 는 **허용한 프로젝트가 있을 때만** 하루에 한 번 — `agy models` 는 Google 과 통신한다 (쓰지 않는 사람의 앱 시작에
    /// 돌지 않게, set-20. 처음 허용할 때 `setAntigravityAllowed` 가 읽는다).
    /// `skippingClaude` — 새 사용자(프로젝트 없음)의 시작에서는 Claude 목록 조회(`claude -p` 세션)를 미룬다.
    func refreshModelCatalogsIfStale(skippingClaude: Bool = false) async {
        for scope in catalogScopesToRefresh(skippingClaude: skippingClaude) {
            await refreshModelCatalog(scope)
        }
    }

    /// 시작할 때 다시 읽을 모델 목록 (`refreshModelCatalogsIfStale` — 시험이 CLI 없이 본다).
    func catalogScopesToRefresh(skippingClaude: Bool, now: Date = Date()) -> [AgentScope] {
        let needs: (AgentScope) -> Bool = { scope in
            Self.catalogNeedsRefresh(provider: scope.provider, snapshot: self.modelCatalogs[scope],
                                     fetchedVersion: self.modelCatalogVersions[scope],
                                     currentVersion: self.cliStatus[scope.provider]?.version, now: now)
        }
        return activeScopes.filter { (scope: AgentScope) -> Bool in
            switch scope.provider {
            case .claude: return !skippingClaude && needs(scope)
            case .codex: return needs(scope)
            case .gemini: return !antigravityAllowedProjectIDs.isEmpty && needs(scope)
            }
        }
    }

    /// 그 범위의 모델 목록을 받는다. **같은 범위를 받는 중이면 새로 띄우지 않고 그 조회가 끝나기를 기다린다** — 첫 폴더를 연 직후의
    /// 조회와 첫 보내기가 겹쳐도 보내기가 빈 목록으로 "모델을 고르세요" 라고 하지 않는다 (onb-1). `force` (목록의 새로고침 단추)면
    /// Claude 별칭 이름도 다시 묻는다.
    func refreshModelCatalog(_ scope: AgentScope, force: Bool = false) async {
        if let running = modelCatalogRefreshes[scope] {
            await running.task.value
            return
        }
        let token = UUID()
        let task = Task { await self.fetchModelCatalog(scope, force: force) }
        modelCatalogRefreshes[scope] = (token, task)
        refreshingModels.insert(scope)
        await task.value
        if modelCatalogRefreshes[scope]?.token == token {
            modelCatalogRefreshes[scope] = nil
            refreshingModels.remove(scope)
        }
    }

    private func fetchModelCatalog(_ scope: AgentScope, force: Bool) async {
        if let override = modelCatalogFetchOverride {
            var snapshot = await override(scope)
            snapshot.options = ModelCatalog.presentableOptions(snapshot.options)
            if !snapshot.options.isEmpty { try? await store.replaceModelOptions(snapshot.options, scope: scope) }
            modelCatalogs[scope] = snapshot
            return
        }
        let status = await environment.checkStatus(scope.provider)
        guard let path = status.resolvedPath else {
            var snapshot = ModelCatalogSnapshot(provider: scope.provider,
                                                accountID: scope.accountID)
            snapshot.fetchedAt = Date()
            snapshot.message = status.error ?? "CLI 경로를 찾지 못했습니다."
            snapshot.options = scope.provider == .claude ? ModelCatalog.claudeFallback() : []
            snapshot.discovered = false
            modelCatalogs[scope] = keepingPreviousGeminiOptions(snapshot, scope: scope)
            return
        }
        let fetched: ModelCatalogSnapshot
        var claudeNamesNeeded = false
        var claudeEnvironment: [String: String] = [:]
        switch scope.provider {
        case .claude:
            // 목록(`claude -p /model` 하나)을 먼저 받아 보인다. 별칭 이름은 그 CLI 버전에서 받아 둔 것이 있으면 그것 — 없으면 목록을 보인
            // 뒤 뒤에서 묻는다 (`fetchClaudeNamesLater`). 보내기는 목록만 기다린다.
            claudeEnvironment = await environment.childEnvironment()
            let cached = force ? nil : status.version.flatMap { version in
                claudeModelNames.flatMap { $0.version == version ? $0.names : nil }
            }
            fetched = await ModelCatalog.fetchClaudeList(path: path, environment: claudeEnvironment, names: cached ?? [:])
            claudeNamesNeeded = cached == nil && fetched.discovered
        case .codex:
            let account = accounts.accountOrDefault(scope.accountID)
            let env = await environment.childEnvironment(codexHome: account.homePath)
            fetched = await ModelCatalog.fetchCodex(path: path, environment: env,
                                                     accountID: scope.accountID)
        case .gemini:
            let env = await environment.childEnvironment()
            fetched = await ModelCatalog.fetchGemini(path: path, environment: env)
        }
        var snapshot = fetched
        snapshot.options = ModelCatalog.presentableOptions(snapshot.options)
        let fetchedAny = !snapshot.options.isEmpty
        snapshot = keepingPreviousGeminiOptions(snapshot, scope: scope)
        // DB 를 먼저 바꾸고 메모리를 바꾼다 — 화면 판정(메모리)이 실행 판정(DB, RunCoordinator)보다 앞서 새 목록을 보지 않게.
        if fetchedAny {
            try? await store.replaceModelOptions(snapshot.options, scope: scope)
        }
        modelCatalogs[scope] = snapshot
        if let version = status.version, snapshot.discovered {
            modelCatalogVersions[scope] = version
            persistSetting(Self.modelCatalogVersionKey(scope), version)
            try? await store.recordVerification(
                provider: scope.provider, cliVersion: version, capability: "모델 목록 조회",
                result: "성공", detail: snapshot.options.map { $0.identifier }
                    .joined(separator: ", "))
        }
        if claudeNamesNeeded { fetchClaudeNamesLater(path: path, environment: claudeEnvironment, version: status.version) }
    }

    /// Claude 별칭의 이름을 뒤에서 묻는다 (`claude -p --model <별칭> /model` 넷 — 비용 0). 실행이 도는 동안에는 미룬다 (최대 2분) —
    /// 첫 메시지의 실행과 함께 띄우지 않게. 받은 이름은 그 CLI 버전과 함께 남겨, 버전이 그대로면 다시 묻지 않는다.
    private func fetchClaudeNamesLater(path: String, environment env: [String: String], version: String?) {
        guard claudeNamesTask == nil else { return }
        claudeNamesTask = Task {
            defer { claudeNamesTask = nil }
            for _ in 0..<120 where !(runner.activeSessions.isEmpty && !isStartingRun) {
                try? await Task.sleep(for: .seconds(1))
            }
            let names = await ModelCatalog.fetchClaudeNames(ModelCatalog.claudeNamedAliases, path: path, environment: env)
            guard !names.isEmpty else { return }
            if let version {
                claudeModelNames = ClaudeModelNames(version: version, names: names)
                persistSetting("claude_model_names", Self.jsonString(claudeModelNames))
            }
            guard var snapshot = modelCatalogs[.claude], snapshot.discovered else { return }
            snapshot.options = ModelCatalog.applyingClaudeNames(names, to: snapshot.options)
            try? await store.replaceModelOptions(snapshot.options, scope: .claude)
            modelCatalogs[.claude] = snapshot
        }
    }

    /// Antigravity 목록 조회가 실패하면 이미 받아 둔 목록을 비우지 않고 실패만 표시한다 (DB 에도 그 목록이 남아 있다).
    /// 비우면 보내기 판정(메모리 목록)과 RunCoordinator(DB 목록)가 서로 다른 목록을 보고, 쓰던 모델까지 "목록을 확인하지 못함" 으로 막힌다.
    /// 조회 시각은 이전 값을 둬서 다음 조회 기회(`refreshModelCatalogsIfStale` · 새로고침)에 다시 묻는다.
    private func keepingPreviousGeminiOptions(_ failed: ModelCatalogSnapshot, scope: AgentScope) -> ModelCatalogSnapshot {
        guard scope.provider == .gemini, failed.options.isEmpty,
              let previous = modelCatalogs[scope], !previous.options.isEmpty else { return failed }
        var kept = failed
        kept.options = previous.options
        kept.fetchedAt = previous.fetchedAt
        kept.discovered = false
        let reason = failed.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        kept.message = (reason.isEmpty ? "모델 목록 조회 실패" : reason) + " · 이전에 조회한 목록을 보여줍니다."
        return kept
    }

    /// `threadID` 를 주면 그 스레드를 바꾼다 (인계 카드의 받는 모델 칩 · 칸마다의 입력창 — 그 칸의 스레드가 지금 고른 스레드와 다를 수 있다).
    /// 없으면 지금 고른 스레드. 스레드는 **이 순간** 메모리의 값을 읽는다.
    func setModelSelection(_ selection: ModelSelection, for provider: AgentProvider, threadID: String? = nil) async {
        guard var thread = selectionTarget(threadID) else { return }
        pauseCountdownIfReceiver(provider, threadID: thread.id)
        thread.setSelection(selection, for: provider)
        await applySelectionChange(thread)
    }

    /// 인계 카드의 받는 쪽 모델을 바꿨다 (카드 · 입력창의 모델 칩) — 카운트다운을 멈춘다 (사람이 판단하는 중이다).
    /// 준비 중(카드가 놓이기 전)이면 보류의 받는 쪽으로 판단한다 — 놓이는 자동 카드가 카운트다운 없이 확인 길로 간다.
    private func pauseCountdownIfReceiver(_ provider: AgentProvider, threadID: String) {
        let receiver = handoffCards[threadID]?.targetProvider
            ?? (handoffPreparations[threadID] != nil ? queueHolds[threadID]?.target.provider : nil)
        if receiver == provider { pauseCountdown(threadID: threadID) }
    }

    private func selectionTarget(_ threadID: String?) -> ConversationThread? {
        guard let threadID else { return selectedThread }
        return allThreads().first { $0.id == threadID }
    }

    /// 강도만 바꾼다. 모델은 **이 순간** 스레드의 값 — 모델 칩 팝오버에서 모델 행을 누르고 곧바로 강도를 바꿔도, 앞의 모델 변경이
    /// 메모리에 먼저 반영돼 있으므로 덮지 않는다 (메인 액터 Task 는 만든 순서대로 첫 await 전까지 돈다). `threadID` 는 `setModelSelection` 과 같다.
    /// 모델을 아직 정하지 않았으면 칩에 보이던 모델(`effectiveSelection`)도 함께 정한다 — 모델 없이 남은 강도는 사람이 고른 것으로
    /// 보지 않는다 (`ModelDefaults.hasChosenModel`).
    func setEffort(_ effort: String?, for provider: AgentProvider, threadID: String? = nil, accountID: String? = nil) async {
        guard var thread = selectionTarget(threadID) else { return }
        pauseCountdownIfReceiver(provider, threadID: thread.id)
        var selection = thread.selection(for: provider)
        if provider != .gemini, !ModelDefaults.hasChosenModel(selection, provider: provider) {
            selection.model = effectiveSelection(for: thread, provider: provider, accountID: accountID).model
        }
        selection.effort = effort
        thread.setSelection(selection, for: provider)
        await applySelectionChange(thread)
    }

    /// 메모리의 스레드를 먼저 고친 뒤 저장한다. 저장 → 다시 읽기를 기다리는 사이 다음 선택 변경이 옛 값을 읽어 덮지 않게
    /// (모델 · 강도는 한 선택값으로 저장된다). 바꾼 시각도 메모리에 먼저 — 새 대화가 마지막에 쓴 모델을 곧바로 이어받는다.
    private func applySelectionChange(_ thread: ConversationThread) async {
        var changed = thread
        changed.updatedAt = Date()
        if let index = threadsByProject[thread.projectID]?.firstIndex(where: { $0.id == thread.id }) {
            threadsByProject[thread.projectID]?[index] = changed
        }
        await updateThread(changed)
    }

    // MARK: - 모델 · 강도 기본값 (새 대화 · 처음 쓰는 에이전트 — 사용자 결정 2026-10-04)

    /// 그 Codex 계정 홈의 config.toml 기본값 (`model` · `model_reasoning_effort`). 파일이 바뀌면 다시 읽는다.
    func codexConfigDefaults(accountID: String) -> CodexConfigDefaults {
        CodexConfigDefaults.read(home: accounts.accountOrDefault(accountID).homePath)
    }

    /// 고르지 않은 강도를 풀 재료 — 설정의 기본 강도(사람이 고른 것만) · Codex 계정의 config.toml (`EffortScale.resolvedDefault`).
    func effortDefaults(provider: AgentProvider, accountID: String?) -> EffortScale.Defaults {
        EffortScale.Defaults(user: defaultEfforts[provider],
                             config: provider == .codex
                                ? codexConfigDefaults(accountID: accountID ?? CodexAccount.defaultID).effort : nil)
    }

    /// 그 대화 · 에이전트가 쓰는 목록의 범위 — Codex 는 `accountID` 를 주면 그 계정 (인계의 받는 계정 · 입력창의 받는 쪽).
    func selectionScope(for thread: ConversationThread, provider: AgentProvider, accountID: String?) -> AgentScope {
        provider == .codex ? .codex(accountID ?? thread.codexAccountID) : thread.scope(for: provider)
    }

    /// 이어받을 선택 — 같은 프로젝트에서 그 에이전트로 마지막에 쓴 대화의 모델 · 강도 → 전체에서 마지막 (`ModelDefaults.inherited`).
    /// 받을 범위(Codex 는 계정)의 목록을 알면 거기서 풀리는 모델만, 강도는 그 모델이 받는 것만. Claude · Codex 만 — Antigravity 는
    /// 판정(`AntigravityAdapter.plan`)이 앱 기본 모델(최신 Flash · High)을 고른다. 새 대화 · 처음 쓰는 에이전트 · 인계 카드의 받는 쪽이 쓴다.
    func inheritedSelection(for thread: ConversationThread, provider: AgentProvider, accountID: String? = nil) -> ModelSelection? {
        guard provider != .gemini else { return nil }
        let options = ModelCatalog.presentableOptions(self.options(for: selectionScope(for: thread, provider: provider,
                                                                                       accountID: accountID)))
        guard var selection = ModelDefaults.inherited(provider: provider, projectID: thread.projectID, excluding: thread.id,
                                                      threads: allThreads(),
                                                      accepts: { options.isEmpty || ModelCatalog.option(for: $0, in: options) != nil })
        else { return nil }
        if let effort = selection.effort, let option = ModelCatalog.option(for: selection.model, in: options),
           !option.supportedEfforts.contains(effort) {
            selection.effort = nil
        }
        return selection
    }

    /// 그 대화가 `provider` 로 보낼 모델 · 강도 — 화면(모델 칩 · 인계 카드)과 보내기가 같은 값을 본다.
    /// 고른 모델이 있으면 대화의 선택 그대로. 없으면(앱이 만들 때 넣은 강도는 고른 것이 아니다) 이어받을 선택, 그것도 없으면
    /// 기본 모델(Codex 는 계정의 config.toml `model` → CLI 기본 — `ModelCatalog.defaultSelectionValue`). 그 강도가 비었으면 지금의
    /// 기본 강도로 푼 값(`resolvedDefaultEffort`) — 정해 둘 때(새 대화 · 처음 쓰는 에이전트 · 보내기) 이 값이 그 대화의 강도가 되고, 그 뒤
    /// 설정의 기본 강도를 바꿔도 따라가지 않는다 (set-n2). 목록을 몰라 모델 · 강도를 풀지 못하면 nil.
    func effectiveSelection(for thread: ConversationThread, provider: AgentProvider, accountID: String? = nil) -> ModelSelection {
        let stored = thread.selection(for: provider)
        guard provider != .gemini, !ModelDefaults.hasChosenModel(stored, provider: provider) else { return stored }
        let scope = selectionScope(for: thread, provider: provider, accountID: accountID)
        var selection: ModelSelection
        if let inherited = inheritedSelection(for: thread, provider: provider, accountID: accountID) {
            selection = inherited
        } else {
            let config = provider == .codex ? codexConfigDefaults(accountID: scope.accountID).model : nil
            selection = ModelSelection(model: ModelCatalog.defaultSelectionValue(in: options(for: scope), configModel: config), effort: nil)
        }
        if selection.effort?.isEmpty ?? true {
            selection.effort = resolvedDefaultEffort(model: selection.model, provider: provider, scope: scope)
        }
        return selection
    }

    /// 고르지 않은 강도를 지금 무엇으로 보내는가 — 그 모델이 받는 강도 가운데 설정의 기본 강도(사람이 고른 것) → Codex 는 계정의 config.toml →
    /// 그 모델의 기본 강도 → High (`EffortScale.displayEffort` — 모델 칩 · `RunSession.send` 와 같은 규칙). 모델이 받는 강도를 모르면 nil.
    func resolvedDefaultEffort(model: String?, provider: AgentProvider, scope: AgentScope) -> String? {
        let availability = EffortScale.availability(provider: provider, selectedModel: model,
                                                    options: ModelCatalog.presentableOptions(options(for: scope)))
        return EffortScale.displayEffort(provider: provider, selected: nil, availability: availability,
                                         defaults: effortDefaults(provider: provider, accountID: scope.accountID))
    }

    /// 아직 정하지 않은 선택을 지금 보이는 값으로 정해 둔다 — 새 대화 · 처음 쓰는 에이전트(입력창의 에이전트를 바꿈) · 보내기 · 인계 전달 직전.
    /// 모델을 정하지 않았으면 모델과 강도를(`effectiveSelection`), 모델은 정했는데 강도가 비었으면(이 수정 전에 쓴 대화 · 강도를 받지 않는
    /// 모델로 바꿨다 돌아옴) 강도만 지금의 기본 강도로. 그 뒤로는 그 대화의 선택이라 다른 대화가 바뀌어도, 설정의 기본 강도를 바꿔도 따라가지
    /// 않는다 (set-n2 — 예전에는 강도를 고르지 않은 대화가 모두 설정을 따라가, 기본 강도를 MAX 로 바꾸면 열린 대화가 모르는 사이 MAX 로
    /// 보냈다). 모델 · 강도를 풀지 못하면(목록을 모름) 그대로 둔다. 바뀐 대화(없으면 지금 값)를 돌려준다.
    @discardableResult
    func pinEffectiveSelection(threadID: String, provider: AgentProvider, accountID: String? = nil) async -> ConversationThread? {
        guard var thread = allThreads().first(where: { $0.id == threadID }) else { return nil }
        guard provider != .gemini else { return thread }
        let stored = thread.selection(for: provider)
        var pinned: ModelSelection
        if ModelDefaults.hasChosenModel(stored, provider: provider) {
            guard stored.effort?.isEmpty ?? true else { return thread }
            pinned = stored
            pinned.effort = resolvedDefaultEffort(model: stored.model, provider: provider,
                                                  scope: selectionScope(for: thread, provider: provider, accountID: accountID))
        } else {
            pinned = effectiveSelection(for: thread, provider: provider, accountID: accountID)
            guard pinned.model != nil else { return thread }
        }
        guard pinned != stored else { return thread }
        thread.setSelection(pinned, for: provider)
        await applySelectionChange(thread)
        return allThreads().first { $0.id == threadID } ?? thread
    }

    /// 화면에 보이는 강도 = 보낼 강도 (모델 칩 · 인계 카드). 고르지 않았으면 기본 강도의 차례로 푼다.
    func shownEffort(for thread: ConversationThread, provider: AgentProvider, accountID: String? = nil) -> String? {
        let selection = effectiveSelection(for: thread, provider: provider, accountID: accountID)
        let scope = selectionScope(for: thread, provider: provider, accountID: accountID)
        let availability = EffortScale.availability(provider: provider, selectedModel: selection.model,
                                                    options: ModelCatalog.presentableOptions(options(for: scope)))
        if provider == .gemini {
            return EffortScale.displayEffort(provider: .gemini, selected: selection.effort, efforts: availability.efforts)
        }
        return EffortScale.displayEffort(provider: provider, selected: selection.effort, availability: availability,
                                         defaults: effortDefaults(provider: provider, accountID: scope.accountID))
    }

    /// 받는 쪽 · 입력창의 "모델 · 강도" 글 ("GPT-6 Sol · Medium") — 인계 카드의 받는 쪽 줄이 쓴다 (`receiverModelText`).
    func selectionText(for thread: ConversationThread, provider: AgentProvider, accountID: String? = nil) -> String? {
        let scope = selectionScope(for: thread, provider: provider, accountID: accountID)
        let options = ModelCatalog.presentableOptions(self.options(for: scope))
        let selection = effectiveSelection(for: thread, provider: provider, accountID: accountID)
        let option = provider == .gemini && !ModelDefaults.hasChosenModel(selection, provider: .gemini)
            ? ModelCatalog.preferredOption(in: options) : ModelCatalog.option(for: selection.model, in: options)
        let name = option?.displayName
            ?? selection.model.flatMap { ModelCatalog.unresolvedFamilyName($0, listEmpty: options.isEmpty) ?? $0 }
        let effort = shownEffort(for: thread, provider: provider, accountID: accountID)
        switch (name, effort) {
        case let (name?, effort?): return "\(name) · \(EffortScale.name(of: effort))"
        case let (name?, nil): return name
        case let (nil, effort?): return "기본 모델 · \(EffortScale.name(of: effort))"
        case (nil, nil): return nil
        }
    }

    // MARK: - Codex 계정

    /// 이 스레드가 쓸 Codex 계정을 바꾼다. 대화의 Codex 세션은 그대로 이어진다 (`RunSession.send` → `CodexRunHome`).
    func setCodexAccount(_ accountID: String, for thread: ConversationThread) async {
        guard thread.codexAccountID != accountID else { return }
        let next = accounts.accountOrDefault(accountID)
        var updated = thread
        updated.codexAccountID = next.id
        await updateThread(updated)
        await announceCodexAccountChange(from: thread.codexAccountID, to: next.id, threadID: thread.id, announce: true)
    }

    /// 입력창 칩에서 에이전트(· Codex 계정)를 고른다. **지금의 대화 값(메모리)** 에 둘을 함께 적어 한 번 쓴다 —
    /// 옛 사본으로 제공자 · 계정을 따로 두 번 쓰면 둘째 쓰기가 첫째(제공자)를 되돌렸다.
    /// 처음 쓰는 에이전트면 그때 보이는 모델 · 강도(이어받기 → 기본 — `effectiveSelection`)로 정해 둔다. 에이전트(제공자)가 바뀌면
    /// 자동 승인을 끈다 — 인계로 받는 에이전트가 바뀔 때와 같은 규칙 (`turnOffAutoApprovalForAgentChange`).
    func chooseAgent(_ target: AgentProvider, accountID: String?, threadID: String, announce: Bool = true) async {
        // 사람이 받을 에이전트를 골랐다 — 자동으로 다른 Codex 계정에서 이어 가려던 카운트다운은 지난 일이다.
        cancelCodexSwitchCountdown(threadID: threadID)
        guard var updated = allThreads().first(where: { $0.id == threadID }) else { return }
        let previousProvider = updated.preferredProvider
        let previousAccount = updated.codexAccountID
        let nextAccount = accountID.map { accounts.accountOrDefault($0).id }
        let accountChanged = nextAccount.map { $0 != previousAccount } ?? false
        guard updated.preferredProvider != target || accountChanged else { return }
        updated.preferredProvider = target
        if let nextAccount, accountChanged { updated.codexAccountID = nextAccount }
        if target != .gemini, !ModelDefaults.hasChosenModel(updated.selection(for: target), provider: target) {
            let effective = effectiveSelection(for: updated, provider: target)
            if effective.model != nil { updated.setSelection(effective, for: target) }
        }
        await applySelectionChange(updated)
        if previousProvider != target {
            await turnOffAutoApprovalForAgentChange(threadID: threadID, from: previousProvider, to: target)
        }
        if accountChanged {
            await announceCodexAccountChange(from: previousAccount, to: updated.codexAccountID, threadID: threadID, announce: announce)
        }
    }

    /// Codex 계정을 바꾼 뒤: 같은 세션을 이어 간다고 알리고(`announce`), 그 계정의 한도 · 모델 목록을 읽는다.
    /// 세션은 대화의 것 하나라 계정이 바뀌어도 이어진다 (`RunSession.send` → `CodexRunHome`).
    private func announceCodexAccountChange(from previousID: String, to nextID: String, threadID: String, announce: Bool) async {
        let previous = accounts.accountOrDefault(previousID)
        let next = accounts.accountOrDefault(nextID)
        guard announce else {
            // 바꾸고 곧바로 이어 가는 길(`continueWithCodexAccount`) — 한도 · 목록 조회를 기다리느라 늦게 출발하지 않게 뒤에서.
            Task { [weak self] in await self?.refreshAfterCodexAccountChange(next.scope) }
            return
        }
        let session = try? await store.session(threadID: threadID, provider: .codex)
        let carries = session.map { $0.resumable && !($0.cliSessionID ?? "").isEmpty } ?? false
        banner = BannerMessage(text: CodexAccountSwitch.switchedNote(from: previous.label, to: next.label, carries: carries),
                               isError: false, threadID: threadID)
        await refreshAfterCodexAccountChange(next.scope)
    }

    /// 바꾼 Codex 계정의 한도 · (비어 있으면) 모델 목록을 읽는다.
    private func refreshAfterCodexAccountChange(_ scope: AgentScope) async {
        await limits.refresh(scope)
        if modelCatalogs[scope]?.options.isEmpty ?? true {
            await refreshModelCatalog(scope)
        }
    }

    /// Codex 계정을 등록 · 해제한 결과. 설정 창이 그 자리(추가 시트 · 계정 줄 아래)에 보인다 — 메인 창의 배너로 보내면 설정 창에
    /// 가려 보이지 않았고, 메인 창을 닫아 두면 어디에도 없었다 (set-2).
    struct CodexAccountNotice: Equatable {
        var text: String
        var isError: Bool
    }

    /// 계정 등록. 로그인은 사용자가 터미널에서 직접 한다. 로그인돼 있으면 그 계정의 한도 · 모델 목록을 읽는다 (set-9 — 그 계정으로
    /// 바꿔 보내기 전에 목록이 있게).
    @discardableResult
    func addCodexAccount(homePath: String, label: String) async -> CodexAccountNotice {
        do {
            let account = try await accounts.add(homePath: homePath, label: label)
            limits.setCodexAccounts(accounts.refs)
            codexNonFileStores[account.id] = Self.codexUsesNonFileStore(home: account.homePath)
            let loggedIn = codexLoginReadiness(accountID: account.id) == .ready
            if loggedIn {
                let scope = account.scope
                Task {
                    await limits.refresh(scope, force: true)
                    await refreshModelCatalog(scope)
                }
            }
            var text: String = "‘\(account.label)’ 계정을 등록했습니다"
            if loggedIn {
                text += " (\(account.identityText))."
            } else {
                text += ". 아직 로그인하지 않았습니다 — 그 줄의 명령을 터미널에서 실행해 로그인한 뒤 [다시 확인]을 누르세요."
            }
            return CodexAccountNotice(text: text, isError: false)
        } catch {
            return CodexAccountNotice(text: error.localizedDescription, isError: true)
        }
    }

    /// 계정 등록 해제. 홈 폴더와 로그인 상태는 그대로 둔다.
    @discardableResult
    func removeCodexAccount(_ id: String) async -> CodexAccountNotice {
        let label = accounts.account(id)?.label ?? id
        do {
            let moved = try await accounts.remove(id)
            // 그 계정을 받는 인계 카드는 검토 카드로 — 기본 계정으로 떨어뜨리지 않는다 (한도에 닿은 보내는 계정일 수 있다).
            handoffReceiverRemoved(accountID: id, label: label)
            limits.setCodexAccounts(accounts.refs)
            modelCatalogs = modelCatalogs.filter { $0.key.accountID != id }
            await reloadProjects()
            var text: String = "‘\(label)’ 계정 등록을 해제했습니다."
            if moved > 0 { text += " 이 계정을 쓰던 대화 \(moved)개는 기본 계정으로 되돌렸습니다." }
            text += " 폴더와 로그인 상태는 그대로 두었습니다."
            return CodexAccountNotice(text: text, isError: false)
        } catch {
            return CodexAccountNotice(text: error.localizedDescription, isError: true)
        }
    }

    func refreshCodexAccounts() async {
        await accounts.refreshAllIdentities()
        limits.setCodexAccounts(accounts.refs)
    }

    /// 스레드가 지금 쓰는 Codex 계정.
    func codexAccount(for thread: ConversationThread) -> CodexAccount {
        accounts.accountOrDefault(thread.codexAccountID)
    }

    /// Gemini 로 다듬기가 쓸 Antigravity CLI(agy)의 경로 · 버전과 요약 모델 목록. 목록(`agy models`)은 Google 과 통신하므로
    /// **인계 문서를 Gemini 로 다듬기로 골랐을 때만** 읽는다 — 쓰지 않는 사람의 앱 시작 · 설정 탭이 그것을 부르지 않게 (set-20).
    /// 고르는 순간 `geminiSummaryEnabled` 가 부른다.
    func refreshGeminiStatus(force: Bool = false) async {
        guard !Self.offlinePreview else { return }
        if !force, geminiCLIPath != nil, !geminiSummaryEnabled || !geminiModels.isEmpty { return }
        if isRefreshingGemini {
            // 경로 입력처럼 연달아 바뀌면 진행 중인 확인이 끝난 뒤 최신 값으로 한 번 더 확인한다.
            if force { geminiRefreshPending = true }
            return
        }
        isRefreshingGemini = true
        defer { isRefreshingGemini = false }
        repeat {
            geminiRefreshPending = false
            let override = geminiPathOverride.isEmpty ? nil : geminiPathOverride
            let status = await geminiAssist.status(pathOverride: override)
            geminiCLIPath = status.path
            geminiCLIVersion = status.version
            geminiCLIError = status.error
            guard status.path != nil else {
                geminiModels = []
                continue
            }
            guard geminiSummaryEnabled else { continue }
            geminiModels = await geminiAssist.models(pathOverride: override)
            // 목록 조회가 일시적으로 실패해도 저장된 선택은 지우지 않는다.
            if !geminiModels.isEmpty, geminiModel.isEmpty || !geminiModels.contains(geminiModel) {
                geminiModel = GeminiAssistService.defaultSummaryModel(from: geminiModels) ?? ""
            }
        } while geminiRefreshPending
    }

    /// Antigravity 작업 에이전트를 이 프로젝트에서 쓸 수 있는지 (기본 꺼짐).
    func antigravityAllowed(projectID: String) -> Bool {
        antigravityAllowedProjectIDs.contains(projectID)
    }

    func setAntigravityAllowed(_ allowed: Bool, projectID: String) {
        let first = allowed && antigravityAllowedProjectIDs.isEmpty
        if allowed { antigravityAllowedProjectIDs.insert(projectID) }
        else { antigravityAllowedProjectIDs.remove(projectID) }
        // 처음 허용한 순간 모델 목록이 없으면 읽는다 — 허용한 프로젝트가 없는 동안은 읽지 않는다 (`refreshModelCatalogsIfStale`, set-20).
        if first, bootstrapped, !Self.offlinePreview, modelCatalogs[.gemini]?.options.isEmpty ?? true {
            Task { await refreshModelCatalog(.gemini) }
        }
        // 처음 허용한 순간 한도도 한 번 읽는다 (그 전에는 읽지 않았다 — `LimitsService.antigravityEnabled`).
        if first, bootstrapped, !Self.offlinePreview {
            Task { await limits.refresh(.gemini) }
        }
    }

    /// 전역 스위치와 프로젝트별 전송 허용을 모두 통과해야 기록을 Gemini로 보낸다.
    /// 자동 정리와 시트의 "다시 정리" 버튼이 같은 기준을 쓴다.
    func geminiAllowed(projectID: String) -> Bool {
        geminiSummaryEnabled && !geminiExcludedProjectIDs.contains(projectID)
    }

    func setGeminiAllowed(_ allowed: Bool, projectID: String) {
        if allowed { geminiExcludedProjectIDs.remove(projectID) }
        else { geminiExcludedProjectIDs.insert(projectID) }
    }

    // MARK: - 프로젝트 / 스레드

    func reloadProjects() async {
        // 읽기에 실패하면 지난 목록을 둔다 — 빈 목록으로 바꾸면 점검표(프로젝트 없음)가 잘못 선다.
        guard let loaded = try? await store.projects() else { return }
        projects = loaded
        projectsLoaded = true
        // 첫 프로젝트가 생겼다(폴더 열기 · 기록 가져오기) — 시작 때 미룬 Claude 조회를 한다.
        runDeferredClaudeStartup()
        var internalThreads: [String: ConversationThread] = [:]
        for p in projects {
            let all = (try? await store.threads(projectID: p.id)) ?? []
            // 오케스트레이션의 내부 대화는 목록 · 검색에 넣지 않는다. 부모 대화의 작업 카드에서 연다.
            threadsByProject[p.id] = all.filter { !$0.isInternal }
            for thread in all where thread.isInternal { internalThreads[thread.id] = thread }
        }
        internalThreadsByID = internalThreads
        if selectedProjectID == nil { selectedProjectID = projects.first?.id }
        // 없어진 대화를 칸에서 뺀다. 포커스 칸이 비었으면 앞서 보던 대화(없으면 첫 대화)를 연다.
        let existing = Set(allThreads().map(\.id)).union(internalThreads.keys)
        let focusedBefore = panes.focusedThreadID
        panes = PaneArrangement(layout: panes.layout, threadIDs: panes.threadIDs, focused: panes.focused, existing: existing,
                                remembered: panes.remembered, rememberedFocus: panes.rememberedFocus,
                                rememberedAt: panes.rememberedAt)
        // 지워진 대화의 "확인 필요" 는 거둔다.
        unseenRunProblems.removeAll { !existing.contains($0.threadID) }
        if panes.focusedThreadID == nil {
            if let open = panes.threadIDs.firstIndex(where: { $0 != nil }) {
                // 포커스 칸의 대화가 지워졌으면 다른 칸에 열린 대화로 포커스를 옮긴다 (빈 칸을 아무 대화로 채우지 않는다).
                // 사람이 고른 빈 칸(분할한 직후 · 빈 칸을 누름)은 그대로 둔다 — 옮기면 그 칸에서 만든 새 대화가 옆 칸의 대화를
                // 덮었다 (chr-1).
                if focusedBefore != nil { panes = panes.focusing(open) }
            } else {
                let fallback = selectedThreadID.flatMap { existing.contains($0) ? $0 : nil } ?? allThreads().first?.id
                if let fallback { panes = panes.opening(fallback) }
            }
        }
        await syncPanes()
    }

    /// 그 대화가 일하는 폴더 (내부 대화 포함) — 독립 작업 폴더가 있으면 그것, 없으면 프로젝트 폴더.
    func projectPath(ofThread threadID: String) -> String? {
        guard let thread = allThreads().first(where: { $0.id == threadID }) ?? internalThreadsByID[threadID] else { return nil }
        return folderProject(for: thread)?.path
    }

    func allThreads() -> [ConversationThread] {
        projects.flatMap { threadsByProject[$0.id] ?? [] }
    }

    var selectedThread: ConversationThread? {
        guard let id = selectedThreadID else { return nil }
        return allThreads().first { $0.id == id } ?? internalThreadsByID[id]
    }

    /// 포커스 대화가 일하는 폴더의 프로젝트 (독립 작업 폴더면 경로만 그 폴더 — `folderProject(for:)`). 인스펙터 · git 쓰기가 이것을 본다.
    var selectedProject: Project? {
        guard let thread = selectedThread else {
            return projects.first { $0.id == selectedProjectID }
        }
        return folderProject(for: thread)
    }

    /// 프로젝트를 등록한다. 같은 폴더(심볼릭 링크를 풀고 표준화한 경로 — `FolderChoice.samePath`)의 프로젝트가 이미 있으면
    /// 새로 만들지 않고 그것을 고른다. 경로는 받은 그대로 저장한다.
    @discardableResult
    func addProject(name: String, path: String) async -> Project {
        if let existing = projects.first(where: { FolderChoice.samePath($0.path, path) }) {
            selectedProjectID = existing.id
            return existing
        }
        let p = Project(name: name, path: path, sortOrder: projects.count)
        try? await store.upsertProject(p)
        await reloadProjects()
        selectedProjectID = p.id
        return p
    }

    /// 선택한 폴더의 CLI 세션 기록을 프로젝트 · 스레드로 옮긴다 (`SessionImportService`). 끝나면 목록을 다시 읽는다.
    func importSessions(folders: [ImportFolder],
                        progress: @Sendable (String) async -> Void = { _ in }) async -> SessionImportResult {
        let result = await SessionImportService.run(folders: folders, store: store, existingProjects: projects, progress: progress)
        await reloadProjects()
        return result
    }

    /// 프로젝트의 화면 이름 — 이름이 같은 프로젝트가 있으면 위 폴더를 덧붙인다 (`SidebarRules.displayNames`). 독립 작업 폴더의
    /// 대화도 같은 프로젝트(id) 이므로 같은 이름이다.
    func projectDisplayName(_ project: Project) -> String {
        projectDisplayNames[project.id] ?? project.name
    }

    var projectDisplayNames: [String: String] { SidebarRules.displayNames(projects) }

    /// 프로젝트 이름을 바꾼다 (사이드바의 프로젝트 메뉴 > 이름 변경). 빈 이름이면 폴더 이름으로 되돌린다. 폴더는 그대로다.
    func renameProject(_ project: Project, to name: String) async {
        var renamed = project
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = (project.path as NSString).lastPathComponent
        renamed.name = trimmed.isEmpty ? (folderName.isEmpty ? project.path : folderName) : trimmed
        guard renamed.name != project.name else { return }
        try? await store.upsertProject(renamed)
        await reloadProjects()
    }

    func removeProject(_ project: Project) async {
        let threadIDs = (threadsByProject[project.id] ?? []).map(\.id)
            + internalThreadsByID.values.filter { $0.projectID == project.id }.map(\.id)
        if let block = deletionBlockBanner(threadIDs: threadIDs, prefix: "프로젝트를 빼지 않았습니다") {
            banner = block
            return
        }
        // 이 폴더에서 돌던 셸도 함께 정리한다.
        #if canImport(SwiftTerm)
        ShellTerminalStore.shared.close(project.path)
        #endif
        // 대화들의 독립 작업 폴더: 커밋하지 않은 변경이 없는 것만 지운다 (합치지 않은 브랜치는 남긴다). 남긴 폴더는 알린다.
        var kept: [String] = []
        for thread in (threadsByProject[project.id] ?? []) + internalThreadsByID.values.filter({ $0.projectID == project.id }) {
            guard let worktree = thread.worktree else { continue }
            if !(await removeWorktree(threadID: thread.id, force: false, branch: .deleteIfMerged, keepThread: false)) {
                kept.append(worktree.path)
            }
        }
        if !kept.isEmpty {
            banner = BannerMessage(text: "커밋하지 않은 변경이 있는 독립 작업 폴더는 지우지 않았습니다:\n" + kept.joined(separator: "\n"),
                                   isError: false)
        }
        let removedThreadIDs = ((threadsByProject[project.id] ?? []) + internalThreadsByID.values.filter({ $0.projectID == project.id }))
            .map(\.id)
        // 이 프로젝트의 대화들이 쓰던 붙인 이미지 — 대화를 지울 때처럼 모아 두고, 뺀 뒤 아무 데서도 쓰지 않는 파일만 뒤에서 지운다.
        var images = pendingAttachmentPaths(threadIDs: removedThreadIDs)
        for id in removedThreadIDs { forgetHandoff(threadID: id) }
        // 입력창에 붙여 둔 이미지 · 막 뺀 대기열 메시지도 치운다 (대화 하나를 지울 때처럼).
        let removed = Set(removedThreadIDs)
        composerAttachments = composerAttachments.filter { !removed.contains($0.key) }
        removedQueuedMessages = removedQueuedMessages.filter { !removed.contains($0.key) }
        removeDeliveredNotifications(threadIDs: removed)
        images.formUnion((try? await store.imageAttachmentPaths(projectID: project.id)) ?? [])
        if (try? await store.deleteProject(id: project.id)) != nil {
            removeOrphanedAttachments(images, deletedThreadIDs: removed)
        }
        threadsByProject.removeValue(forKey: project.id)
        await reloadProjects()
    }

    /// `agent` 를 주면 그 에이전트(· Codex 계정)로 연다 (첫 폴더의 첫 대화 — 점검표의 `readyAgent`). 없으면 `initialAgent`.
    @discardableResult
    func addThread(projectID: String, title: String, agent: AgentProvider? = nil,
                   codexAccountID: String? = nil) async -> ConversationThread {
        var t = ConversationThread(projectID: projectID, title: title)
        if let agent {
            t.preferredProvider = agent
            if agent == .codex, let codexAccountID { t.codexAccountID = codexAccountID }
        } else {
            // 에이전트는 마지막에 쓴 것을 이어받고, 이 Mac 에 없는 CLI 면 설치된 것으로 (`ConversationThread.initialAgent`).
            let initial = ConversationThread.initialAgent(
                projectID: projectID, recent: allThreads(),
                usable: { [cliStatus] in cliStatus[$0]?.isUsable }, allowsGemini: antigravityAllowed(projectID: projectID))
            t.preferredProvider = initial.provider
            if let account = initial.codexAccountID { t.codexAccountID = account }
        }
        // 처음 쓰는 에이전트의 모델 · 강도: 같은 프로젝트에서 그 에이전트로 마지막에 쓴 대화의 것 → 전체에서 마지막 → 기본
        // (Codex 는 계정의 config.toml → CLI 기본, 강도는 설정의 기본 강도 — 고르지 않았으면 모델 기본값). 칩 · 인계 카드 · 보내기가
        // 같은 값을 본다. 다른 에이전트는 처음 쓸 때(입력창의 에이전트를 바꿈 · 인계 · 보내기) 그때의 값으로 정한다. 모델을 풀지 못하면
        // (목록을 아직 모름) 비워 둔다 — 보낼 때 정한다.
        if t.preferredProvider != .gemini {
            let effective = effectiveSelection(for: t, provider: t.preferredProvider)
            if effective.model != nil { t.setSelection(effective, for: t.preferredProvider) }
        }
        try? await store.upsertThread(t)
        // 설정 "새 대화는 자동 승인으로 시작" — 사람이 만드는 새 대화(이 길)에만. Antigravity 는 승인을 묻지 않아 해당 없다.
        if newThreadsAutoApprove, t.preferredProvider != .gemini { autoApprovalThreadIDs.insert(t.id) }
        await reloadProjects()
        await selectThread(t.id)
        // 사람이 새 대화를 만들었다 (사이드바 + · 파일 > 새 대화 · 독립 작업 폴더에서 새 대화 · 폴더 열기) — 입력창이 포커스를
        // 가져간다. 커밋 메시지 칸 · 터미널에 포커스가 남아 있어도 (명시적인 요청은 지금 응답자를 따지지 않는다 — H25).
        // 접어 둔 프로젝트면 사이드바가 편다 — 방금 만든 대화가 목록에 보이게.
        requestComposerFocus(threadID: t.id)
        sidebarRevealProjectIDs.insert(projectID)
        return t
    }

    /// 새 대화 (⌘N · 사이드바 ＋ · 프로젝트 메뉴의 "새 대화" · 빈 칸의 단추). 그 프로젝트에 아직 아무 기록이 없는 빈 "새 대화" 가 있으면 새로 만들지
    /// 않고 그 대화를 연다 — ＋ 를 누를 때마다 빈 대화가 쌓여 진짜 대화를 "더보기" 뒤로 밀지 않게 (`SidebarRules.blankCandidates`).
    /// 빈 대화 = 자리 표시 제목 · 이벤트 · 실행 · 인계 카드 · 도는 실행 · 적어 둔 글 · 붙인 이미지 · 보내는 중이 없고, 다른 칸에 열려 있지
    /// 않음. 열고 나면 입력창에 포커스를 준다.
    @discardableResult
    func startNewConversation(projectID: String) async -> ConversationThread {
        for candidate in SidebarRules.blankCandidates(threadsByProject[projectID] ?? []) {
            // 다른 칸에 열린 빈 대화는 다시 쓰지 않는다 — 포커스만 그 칸으로 옮겨 가고 지금 칸(빈 칸)에는 아무것도 열리지 않았다
            // (vis-1 · chr-2). 포커스 칸의 것 · 칸 밖의 것만.
            if let pane = panes.threadIDs.firstIndex(where: { $0 == candidate.id }), pane != panes.focused { continue }
            // 적어 둔 글 · 붙인 이미지가 있거나 보내는 중이면 사람이 쓰는 대화다 — 다시 열지 않고 새로 만든다 (chr-2).
            guard !isSending(threadID: candidate.id), (composerAttachments[candidate.id] ?? []).isEmpty else { continue }
            var draft: String = composerDrafts[candidate.id] ?? ""
            if composerDrafts[candidate.id] == nil { draft = (try? await store.composerDraft(threadID: candidate.id))?.text ?? "" }
            guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard runner.session(threadID: candidate.id) == nil, !isStartingRun(threadID: candidate.id),
                  !hasHandoffActivity(threadID: candidate.id),
                  (try? await store.events(threadID: candidate.id, limit: 1))?.isEmpty == true,
                  (try? await store.runs(threadID: candidate.id))?.isEmpty == true else { continue }
            await selectThread(candidate.id)
            requestComposerFocus(threadID: candidate.id)
            sidebarRevealProjectIDs.insert(projectID)
            return candidate
        }
        let thread = await addThread(projectID: projectID, title: "새 대화")
        requestComposerFocus(threadID: thread.id)
        return thread
    }

    func updateThread(_ thread: ConversationThread) async {
        var t = thread
        t.updatedAt = Date()
        let serial = beginThreadWrite(t.projectID)
        try? await store.upsertThread(t)
        await reloadThreads(projectID: t.projectID, after: serial)
    }

    /// 실행 · 인계를 보낸 뒤 — 행 전체가 아니라 보낸 쪽이 바꾼 칸만 저장하고 다시 읽는다 (`Store.recordThreadSend`).
    /// 메모리에 같은 규칙을 먼저 적용한다 — 저장 · 다시 읽기 사이에 모델 칩 · 계정 칩의 행 전체 저장이 돌면 메모리 값을 싣고 가므로.
    func recordThreadSend(_ thread: ConversationThread, provider: AgentProvider, onlyIfProviderWas: AgentProvider?,
                          placeholderTitle: String?, filledModel: String?, codexAccountID: String?) async {
        if let index = threadsByProject[thread.projectID]?.firstIndex(where: { $0.id == thread.id }) {
            threadsByProject[thread.projectID]?[index].recordSend(
                provider: provider, onlyIfProviderWas: onlyIfProviderWas, placeholderTitle: placeholderTitle,
                filledModel: filledModel, codexAccountID: codexAccountID)
        }
        let serial = beginThreadWrite(thread.projectID)
        try? await store.recordThreadSend(id: thread.id, provider: provider, onlyIfProviderWas: onlyIfProviderWas,
                                          placeholderTitle: placeholderTitle, filledModel: filledModel,
                                          codexAccountID: codexAccountID)
        await reloadThreads(projectID: thread.projectID, after: serial)
    }

    /// 프로젝트마다 스레드 쓰기 번호. 쓰기 뒤 다시 읽은 목록은 그 뒤에 시작한 쓰기가 없을 때만 메모리에 넣는다 — 늦게 끝난 앞 쓰기의
    /// 다시 읽기가 뒤 쓰기의 메모리 선반영(모델 칩)을 잠깐 옛 값으로 되돌리지 않게. 마지막 쓰기의 다시 읽기가 앞 쓰기를 모두 담는다
    /// (Store 는 actor 라 부른 순서대로 처리하고, 쓰기는 첫 await 에서 저장을 부른다).
    private var threadWriteSerial: [String: Int] = [:]

    private func beginThreadWrite(_ projectID: String) -> Int {
        let serial = (threadWriteSerial[projectID] ?? 0) + 1
        threadWriteSerial[projectID] = serial
        return serial
    }

    private func reloadThreads(projectID: String, after serial: Int) async {
        let reloaded = (try? await store.threads(projectID: projectID)) ?? []
        guard threadWriteSerial[projectID] == serial else { return }
        threadsByProject[projectID] = reloaded
    }

    /// 대화를 지울 수 없는 이유 — 에이전트 실행이나 자동 작업이 도는 대화는 지우지 않는다 (CLI 는 계속 파일을 고치는데 기록만
    /// 사라진다). 지울 수 있으면 nil. 사이드바가 확인 창 전에 보고, `deleteThread` · `removeProject` 가 한 번 더 본다.
    func deletionBlock(threadIDs: [String]) -> String? {
        deletionBlocker(threadIDs: threadIDs)?.reason
    }

    /// 지우기를 막는 대화와 그 까닭. 도는 실행이면 그 대화를 멈출 수 있다 (`runningThread`) — ⌘. 는 포커스 대화만 멈추므로
    /// 안내가 "⌘." 를 가리키면 다른 칸 · 칸에 없는 대화의 실행은 멈추지 못했다.
    struct DeletionBlocker {
        var threadID: String
        var reason: String
        /// 에이전트 실행이 돈다 (멈출 수 있다). 거짓이면 자동 작업이 진행 중이다 (작업 카드에서 멈춘다).
        var running: Bool
    }

    func deletionBlocker(threadIDs: [String]) -> DeletionBlocker? {
        for id in threadIDs {
            let title = paneThread(id).map { "\"\($0.title)\"" } ?? "대화"
            if isThreadRunning(id) || isStartingRun(threadID: id) {
                return DeletionBlocker(threadID: id, reason: "\(title) 에서 에이전트가 실행 중입니다. 멈춘 뒤에 지우세요.", running: true)
            }
            if orchestration.snapshotsByThread[id].map({ !$0.job.state.isTerminal }) == true {
                return DeletionBlocker(threadID: id, reason: "\(title) 의 자동 작업이 진행 중입니다. 작업 카드에서 멈춘 뒤에 지우세요.",
                                       running: false)
            }
        }
        return nil
    }

    /// 지우지 않은 까닭의 배너 — 그 대화의 실행을 멈추는 단추(또는 그 대화로 가는 단추)를 단다. 배너는 그 대화가 칸에 열려 있으면
    /// 그 칸에, 아니면 포커스 칸에 보인다 (칸에 없는 대화의 배너는 어디에도 그려지지 않았다).
    func deletionBlockBanner(threadIDs: [String], prefix: String) -> BannerMessage? {
        guard let blocker = deletionBlocker(threadIDs: threadIDs) else { return nil }
        let id = blocker.threadID
        let shownIn = panes.threadIDs.contains(id) ? id : nil
        if blocker.running {
            return BannerMessage(text: "\(prefix) — \(blocker.reason)", isError: true, actionTitle: "그 실행 멈추기",
                                 action: { [weak self] in
                                     guard let self else { return }
                                     Task {
                                         await self.runner.interrupt(threadID: id)
                                         await self.reviewLanes.coordinator.interrupt(threadID: id)
                                     }
                                 },
                                 threadID: shownIn)
        }
        return BannerMessage(text: "\(prefix) — \(blocker.reason)", isError: true, actionTitle: "그 대화 열기",
                             action: { [weak self] in Task { await self?.selectThread(id) } },
                             threadID: shownIn)
    }

    func deleteThread(_ thread: ConversationThread) async {
        if let block = deletionBlockBanner(threadIDs: [thread.id], prefix: "지우지 않았습니다") {
            banner = block
            return
        }
        // 독립 작업 폴더도 지운다 (확인은 사이드바가 상태를 읽은 뒤에 받았다). 합치지 않은 커밋이 있는 브랜치는 남긴다.
        // 커밋하지 않은 변경은 확인 창이 사라질 수를 보였을 때만 버린다 — 상태를 모르면 강제하지 않아, 변경이 있는 폴더는
        // git 이 지우지 않는다.
        if thread.worktree != nil {
            let force = (worktreeStatuses[thread.id]?.uncommitted ?? 0) > 0
            guard await removeWorktree(threadID: thread.id, force: force, branch: .deleteIfMerged, keepThread: false) else {
                return
            }
        }
        // 이 대화가 쓰던 붙인 이미지 — 입력창 · 대기열의 것은 치우기 전에, 메시지의 것은 지우기 전에 모아 두고, 지운 뒤 아무
        // 데서도 쓰지 않는 파일만 뒤에서 지운다 (`removeOrphanedAttachments`).
        var images = pendingAttachmentPaths(threadIDs: [thread.id])
        for provider in AgentProvider.allCases { folderMoveNotes[Self.folderMoveKey(thread.id, provider)] = nil }
        // 인계 카드 · 준비 · 전달 · 보류 · 걸어 둔 대기열(저장된 것까지)도 함께 지운다.
        forgetHandoff(threadID: thread.id)
        composerDrafts.removeValue(forKey: thread.id)
        composerDraftRevisions.removeValue(forKey: thread.id)
        composerAttachments[thread.id] = nil
        removedQueuedMessages[thread.id] = nil
        unreviewedRunIDs.removeValue(forKey: thread.id)
        unseenRunProblems.removeAll { $0.threadID == thread.id }
        panes = panes.removing(thread.id)
        removeDeliveredNotifications(threadIDs: [thread.id])
        images.formUnion((try? await store.imageAttachmentPaths(threadIDs: [thread.id])) ?? [])
        if (try? await store.deleteThread(id: thread.id)) != nil {
            removeOrphanedAttachments(images, deletedThreadIDs: [thread.id])
        }
        await reloadProjects()
    }

    /// 지운 대화의 지난 알림을 알림 센터에서 걷는다 — 누르면 갈 대화가 없다. 알림의 userInfo `threadID` 는 `NotificationService` 가
    /// 넣는다. 번들이 없는 실행(검증 하네스) · 화면 확인용 실행은 알림 센터를 부르지 않는다.
    private func removeDeliveredNotifications(threadIDs: Set<String>) {
        guard !threadIDs.isEmpty, Bundle.main.bundleIdentifier != nil, !Self.offlinePreview else { return }
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let stale = delivered.filter { ($0.request.content.userInfo["threadID"] as? String).map(threadIDs.contains) == true }
                .map(\.request.identifier)
            if !stale.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    /// 대화를 연다 (사이드바 · 알림 · 작업 카드 · 메뉴바). 이미 어느 칸에 열려 있으면 그 칸으로 포커스만 옮기고, 아니면 포커스 칸의
    /// 대화를 바꾼다 (`PaneArrangement.opening`). 가운데가 에이전트 기록 · 크게 보기면 대화로 돌린다 (`conversationRevealRequest`).
    /// 없는 대화(지운 대화의 지난 알림 등)는 열지 않고 알린다 — 칸이 "읽는 중" 인 채 비어 남지 않게.
    func selectThread(_ id: String) async {
        if paneThread(id) == nil {
            // 막 만든 대화를 목록이 아직 모를 수 있다 — 한 번 다시 읽고 본다.
            await reloadProjects()
            guard paneThread(id) != nil else {
                banner = BannerMessage(text: "이 대화는 지워져 열 수 없습니다.", isError: false)
                return
            }
        }
        conversationRevealRequest += 1
        panes = panes.opening(id)
        await syncPanes()
    }

    /// 빈 칸(없으면 분할을 한 단계 키워 새 칸)에 연다. 네 칸이 다 찼으면 아무것도 바꾸지 않는다 (사이드바 메뉴가 그 항목을 끈다).
    func openInNewPane(_ id: String) async {
        guard paneThread(id) != nil else { return }
        conversationRevealRequest += 1
        panes = panes.openingInNewPane(id)
        await syncPanes()
    }

    /// 칸을 눌렀다: 그 칸이 포커스를 갖는다. 인스펙터 · 툴바 · 메뉴가 그 칸의 대화를 따라간다.
    func focusPane(_ index: Int) async {
        guard index != panes.focused, panes.threadIDs.indices.contains(index) else { return }
        panes = panes.focusing(index)
        await syncPanes()
    }

    func setPaneLayout(_ layout: PaneLayout) async {
        guard layout != panes.layout else { return }
        panes = panes.resized(to: layout)
        await syncPanes()
    }

    /// 칸을 비운다. 대화는 닫히지 않고 실행도 계속 돈다 (사이드바에서 다시 연다). 포커스 칸을 비웠으면 대화가 열린 다른 칸이
    /// 포커스를 갖는다 (`PaneArrangement.closing`).
    func closePane(_ index: Int) async {
        panes = panes.closing(pane: index)
        await syncPanes()
    }

    /// 분할을 줄이기 전 배치의 저장 형식 (설정 `pane_memory`).
    struct PaneMemory: Codable, Equatable {
        var threads: [String?]
        var focus: Int
        /// 기억한 때 (`PaneArrangement.rememberedAt`). 없는 옛 저장값은 되살리지 않는다.
        var at: Date?
    }

    /// 칸 배치를 화면 상태에 옮긴다: 저장 · 포커스 대화 활성화 · 나머지 칸의 준비 · 닫힌 대화의 상자 버리기.
    func syncPanes() async {
        persistSetting("pane_layout", panes.layout.rawValue)
        persistSetting("pane_focused", String(panes.focused))
        if let data = try? JSONEncoder().encode(panes.threadIDs), let text = String(data: data, encoding: .utf8) {
            persistSetting("pane_threads", text)
        }
        if let data = try? JSONEncoder().encode(PaneMemory(threads: panes.remembered, focus: panes.rememberedFocus, at: panes.rememberedAt)),
           let text = String(data: data, encoding: .utf8) {
            persistSetting("pane_memory", text)
        }
        let focusedID = panes.focusedThreadID
        selectedThreadID = focusedID
        if let focusedID { lastFocusedThreadID = focusedID }
        if let focusedID {
            // 그 대화를 열었다 — 메뉴바의 "확인 필요" 에서 뺀다.
            unseenRunProblems.removeAll { $0.threadID == focusedID }
            persistSetting("selected_thread", focusedID)
            if let thread = allThreads().first(where: { $0.id == focusedID }) ?? internalThreadsByID[focusedID] {
                selectedProjectID = thread.projectID
            }
        }
        closeDiffIfProjectChanged(to: selectedProject?.path)
        ensureWorkspace(path: selectedProject?.path)
        let arrangement = panes
        for id in panes.threadIDs.compactMap({ $0 }) { await prepareThread(id) }
        // 준비하는 사이 칸 배치가 또 바뀌었으면 그 호출이 마무리한다.
        guard arrangement == panes else { return }
        pruneThreadStates()
    }

    /// 칸에 열린 대화 하나의 준비: 입력 초안 · 폴더의 git 상태 · 대화 기록 · 자동 작업. 이미 읽은 것은 다시 읽지 않는다.
    private func prepareThread(_ id: String) async {
        if composerDrafts[id] == nil {
            let saved = try? await store.composerDraft(threadID: id)
            // 로드하는 사이 사용자가 입력했다면 메모리의 새 값을 우선한다.
            if composerDrafts[id] == nil {
                composerDrafts[id] = saved?.text ?? ""
                composerDraftRevisions[id] = saved?.revision ?? 0
            }
        }
        ensureWorkspace(path: projectPath(ofThread: id))
        if threadStates[id]?.loaded != true {
            await reloadThreadData(threadID: id, create: true)
            await orchestration.load(parentThreadID: id)
        }
    }

    func composerDraft(for threadID: String) -> String {
        composerDrafts[threadID] ?? ""
    }

    /// 입력할 때마다 메모리를 즉시 갱신하고 저장소에도 기록한다. 아주 긴 글(붙여 넣은 로그 등)은 키마다 통째로 쓰지 않고 잠시 모아
    /// 쓴다 (chat-20) — 늦게 끝난 앞 쓰기가 뒤 것을 덮지 않는 것은 revision 이 지킨다.
    func updateComposerDraft(_ text: String, for threadID: String) {
        composerDrafts[threadID] = text
        let revision = (composerDraftRevisions[threadID] ?? 0) + 1
        composerDraftRevisions[threadID] = revision
        draftSaveTasks[threadID]?.cancel()
        let store = self.store
        // `utf8.count` 는 글을 훑지 않는다 (Swift 문자열은 UTF-8 로 들고 있다).
        guard text.utf8.count > ComposerText.coalescedDraftBytes else {
            draftSaveTasks[threadID] = nil
            Task { try? await store.setComposerDraft(threadID: threadID, text: text, revision: revision) }
            return
        }
        draftSaveTasks[threadID] = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? await store.setComposerDraft(threadID: threadID, text: text, revision: revision)
        }
    }
    @ObservationIgnored private var draftSaveTasks: [String: Task<Void, Never>] = [:]

    /// 앱 종료가 확정됐다 — 메모리에만 있던 것을 저장하고 끝낸다: 보내는 중이던 메시지는 입력창 초안 · 첨부로(이미 쓴 글이 있으면 덮지
    /// 않고 뒤에 잇는다), 인계 카드의 덧붙일 말로 옮겼던 메시지는 대기열로 (`restoreMovedMessagesForQuit`). DB 를 닫기 전에 부른다.
    func saveBeforeQuit() async {
        for (threadID, message) in sendingMessages {
            let current = composerDraft(for: threadID)
            composerDrafts[threadID] = current.isEmpty ? message.text
                : (message.text.isEmpty || current == message.text ? current : message.text + "\n\n" + current)
            if !message.images.isEmpty { restoreAttachments(message.images, threadID: threadID) }
        }
        // 초안 저장은 뒤에서 도는 작업이라 끝나기 전에 앱이 끝날 수 있다 — 메모리의 초안을 지금 저장한다 (종료 직전 보내지 못하고
        // 입력창에 되돌린 글 포함).
        for (threadID, text) in composerDrafts where !text.isEmpty || draftSaveTasks[threadID] != nil {
            draftSaveTasks[threadID]?.cancel()
            let revision = (composerDraftRevisions[threadID] ?? 0) + 1
            composerDraftRevisions[threadID] = revision
            try? await store.setComposerDraft(threadID: threadID, text: text, revision: revision)
        }
        if sendingMessages.values.contains(where: { !$0.images.isEmpty }) {
            try? await store.setSetting("composer_attachments", Self.jsonString(composerAttachments))
        }
        sendingMessages = [:]
        await restoreMovedMessagesForQuit()
    }

    /// 종료 전에 저장할 것이 있다 (그러면 저장을 마칠 때까지 종료를 미룬다).
    var needsSavingBeforeQuit: Bool { !sendingMessages.isEmpty || hasMovedMessagesToRestore || !draftSaveTasks.isEmpty }

    /// 앱이 대신 돌리는 git · 독립 작업 폴더 명령 수 (종료 확인이 센다 — 끊기면 저장소가 중간 상태로 남을 수 있다).
    var appCommandCount: Int {
        (runningGitOperation == nil ? 0 : 1) + (worktreeOperation == nil ? 0 : 1) + worktreeSetups.count
    }

    /// 앱 종료 확인 창의 사실 (`QuitConfirmation`) — **확인창을 띄우기 전에**, `suspendHandoffsForQuit` 가 카운트다운을 멈추기 전에 센다
    /// (멈춘 뒤에 세면 다른 계정에서 이어 가려던 카운트다운이 사라져 확인 글이 그것을 말하지 못한다). 셸 수는 앱 층이 넣는다
    /// (`ShellTerminalStore` — 화면 쪽 저장소).
    func quitFacts(busyShells: Int) -> QuitConfirmation.Facts {
        QuitConfirmation.Facts(
            running: activeSessions.count,
            // 메인 턴을 마치고 백그라운드 작업(하위 에이전트 · 워크플로 · 백그라운드 명령)을 기다리는 실행도 도는 실행이다.
            background: activeSessions.filter(\.isWaitingOnBackground).reduce(0) { $0 + $1.unfinishedSubAgentCount },
            // 인계 카드는 메모리다 — 끄면 닫힌다 (넘기지 않은 초안은 남지 않는다). 준비 중인 것도 센다.
            cards: Set(handoffCards.keys).union(handoffPreparations.keys).count,
            countdowns: handoffCards.values.filter(\.isCountingDown).count,
            codexSwitches: codexSwitchCountdowns.count,
            busyShells: busyShells,
            sending: sendingThreads.count,
            appCommands: appCommandCount)
    }

    /// 전송을 시작한 뒤 새 입력이 생겼다면 그 새 내용은 지우지 않는다.
    func clearComposerDraft(_ sentText: String, for threadID: String) {
        guard composerDraft(for: threadID) == sentText else { return }
        updateComposerDraft("", for: threadID)
    }

    /// 앱이 켜져 있지 않은 사이 끝난(또는 앱과 함께 죽은) 실행을 닫는다. 결과를 받지 못했으므로 완료가 아니라 **실패 · 종료 미확인**으로
    /// 남긴다 — 자동으로 하지 않고 사용자가 안내문의 "정리" 를 눌렀을 때만.
    func closeDanglingRuns() async {
        for var run in danglingRuns {
            run.state = .failed
            run.endedAt = run.endedAt ?? Date()
            run.terminalReason = run.terminalReason ?? "unconfirmed_exit"
            run.errorMessage = run.errorMessage ?? "앱이 종료돼 이 실행의 종료를 확인하지 못했습니다. 다시 시작한 뒤 정리했습니다."
            try? await store.updateRun(run)
        }
        danglingRuns = []
        banner = nil
        await reloadThreadData()
    }

    func reloadThreadData() async {
        guard let id = selectedThreadID else { return }
        await reloadThreadData(threadID: id)
    }

    /// 그 대화의 상자를 저장소에서 다시 읽는다. 열려 있지 않은 대화면 아무것도 하지 않는다 (`create` 가 아니면).
    func reloadThreadData(threadID id: String, create: Bool = false) async {
        guard let state = create ? paneModel(for: id) : threadStates[id] else { return }
        await state.reload(store: store)
    }

    // MARK: - 실행

    /// 메시지 하나를 보낸다 (입력창 · 대기열). 받아들여져 실행이 시작되면 true. 보내지 못하면 그 대화의 안내(입력창 바로 위)에
    /// 까닭을 남기고 false — 그동안 걸어 둔 메시지가 있으면 기다릴 실행이 없으므로 대기열을 멈춘다.
    /// `reserved` — 입력창이 누르는 순간 `reserveSend` 로 "보내는 중" 자리를 이미 잡았다 (그 자리로 보낸다).
    @discardableResult
    func send(_ prompt: String, provider: AgentProvider, threadID: String? = nil,
              images: [ImageAttachment] = [], reserved: Bool = false) async -> Bool {
        let candidate = threadID.flatMap { id in allThreads().first { $0.id == id } }
            ?? selectedThread
        guard let thread = candidate else {
            if reserved, let threadID { sendingThreads[threadID] = nil }
            banner = BannerMessage(text: "프로젝트와 대화를 먼저 선택하세요.", isError: true)
            return false
        }
        // 같은 대화의 보내기가 아직 시작되지 않았다(모델 목록 확인 · 시작 전 스냅샷) — 두 번 보내지 않는다 (chat-1).
        guard reserved || sendingThreads[thread.id] == nil else {
            banner = BannerMessage(text: "앞서 보낸 메시지를 시작하는 중입니다. 시작한 뒤에 보내세요.", isError: false, threadID: thread.id)
            return false
        }
        sendingThreads[thread.id] = .preparing
        sendingMessages[thread.id] = QueuedMessage(text: prompt, images: images)
        // 사람이 이 대화에서 보냈다 — 자동으로 다른 Codex 계정에서 이어 가려던 카운트다운은 지난 일이다.
        cancelCodexSwitchCountdown(threadID: thread.id)
        let accepted = await sendPreparing(prompt, provider: provider, thread: thread, images: images)
        sendingThreads[thread.id] = nil
        sendingMessages[thread.id] = nil
        // 보냈으면 입력창 위에 남은 이 대화의 지난 안내(앞서 보내지 못한 까닭 등)를 거둔다 — 이제 맞지 않는다.
        if accepted, banner?.threadID == thread.id { banner = nil }
        // 보내는 사이 걸어 둔 메시지(입력창은 "보내는 중" 에 ↵ 를 대기열로 받는다)는 기다릴 실행이 없다 — 멈춰 두고 알린다.
        if !accepted, !(messageQueues[thread.id]?.isEmpty ?? true), queuePauseReasons[thread.id] == nil, queueHolds[thread.id] == nil,
           runner.session(threadID: thread.id) == nil {
            queuePauseReasons[thread.id] = QueueRules.previousSendFailed
        }
        return accepted
    }

    private func sendPreparing(_ prompt: String, provider: AgentProvider, thread start: ConversationThread,
                               images: [ImageAttachment]) async -> Bool {
        var thread = start
        guard let project = folderProject(for: thread) else {
            banner = BannerMessage(text: "프로젝트와 대화를 먼저 선택하세요.", isError: true)
            return false
        }
        if let problem = worktreeProblem(thread) {
            banner = BannerMessage(text: problem, isError: true, threadID: thread.id)
            return false
        }
        // 내부 대화는 자동 작업(오케스트레이션)이 소유한다. 사람이 보낸 턴이 섞이면 그 작업의 기록이 어긋나고
        // 하나뿐인 실행 슬롯을 코디네이터와 다툰다. 코디네이터는 `orchestrationLaunch` 로 따로 들어와 여기 걸리지 않는다.
        guard !thread.isInternal else {
            banner = BannerMessage(text: "자동 작업이 쓰는 내부 대화에는 메시지를 보낼 수 없습니다.", isError: true, threadID: thread.id)
            return false
        }
        // 인계 카드(준비 · 전달 중 포함)가 있는 대화는 보내지 않는다 — 입력창은 대기열에 걸어 인계 뒤 받는 쪽에게 보낸다 (C2).
        // 카운트다운을 조용히 끄지 않는다 (사람이 카드에서 멈추거나 취소한다).
        guard queueHolds[thread.id] == nil, !hasHandoffActivity(threadID: thread.id) else {
            banner = BannerMessage(text: "인계 카드가 있어 보내지 않았습니다 — 입력창의 ↵ 는 인계 뒤에 보낼 메시지로 걸어 둡니다.",
                                   isError: true, threadID: thread.id)
            return false
        }
        // 이미지만 붙여 보낼 수도 있다 (글 없이).
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return false }
        if provider == .gemini, !antigravityAllowed(projectID: project.id) {
            banner = BannerMessage(
                text: "이 프로젝트에서는 Antigravity 를 쓸 수 없습니다. Antigravity 턴은 승인을 묻지 않고 "
                    + "파일을 고치고 명령을 실행하므로, 프로젝트 설정(사이드바의 프로젝트 메뉴)에서 켜야 합니다.",
                isError: true, threadID: thread.id)
            return false
        }
        // 그 에이전트를 쓸 수 없다고 확인됐으면(설치 안 됨 · 지정한 경로 오류 · 로그인 안 됨) 모델을 보기 전에 맞는 안내로 (onb-4).
        if let block = await sendReadinessBlock(provider: provider, thread: thread) {
            banner = BannerMessage(text: block.text, isError: true, actionTitle: block.actionTitle, threadID: thread.id,
                                   opens: block.opens)
            return false
        }
        // 고르지 않은 모델은 보이던 값(이어받기 → 기본)으로 정해 둔다 — 화면에 보인 모델과 실행 모델이 같다. 목록을 받는 중이면
        // 그 조회를 기다린다 (첫 폴더를 연 직후 · 시작 때의 조회와 겹쳐도 "모델을 고르세요" 라고 하지 않는다 — onb-1).
        var filledModel: String?
        let scope = thread.scope(for: provider)
        if provider != .gemini, !ModelDefaults.hasChosenModel(thread.selection(for: provider), provider: provider) {
            if effectiveSelection(for: thread, provider: provider).model == nil {
                sendingThreads[thread.id] = .checkingModels
                await refreshModelCatalog(scope)
                sendingThreads[thread.id] = .preparing
            }
            if let pinned = await pinEffectiveSelection(threadID: thread.id, provider: provider),
               ModelDefaults.hasChosenModel(pinned.selection(for: provider), provider: provider) {
                thread.setSelection(pinned.selection(for: provider), for: provider)
            } else {
                banner = BannerMessage(text: modelUnresolvedText(provider: provider, scope: scope), isError: true,
                                       actionTitle: "목록 다시 확인",
                                       action: { [weak self] in Task { await self?.refreshModelCatalog(scope, force: true) } },
                                       threadID: thread.id)
                return false
            }
        }
        // 모델은 정했는데 강도를 고르지 않은 대화(이 수정 전에 쓴 대화 · 강도를 받지 않는 모델로 바꿨다 돌아옴)는 보낼 때 지금의 기본 강도로
        // 정해 둔다 — 그 뒤 설정의 기본 강도를 바꿔도 이미 쓴 대화는 따라가지 않는다 (set-n2).
        if provider != .gemini, thread.selection(for: provider).effort?.isEmpty ?? true,
           let pinned = await pinEffectiveSelection(threadID: thread.id, provider: provider) {
            thread.setSelection(pinned.selection(for: provider), for: provider)
        }
        // Antigravity: 고르지 않은 모델은 판정이 앱 기본 모델로 채운다. agy 가 거부할 조합이거나 넘길 강도를 정할 근거가 없으면 보내지
        // 않는다 (RunCoordinator 도 같은 판정으로 막는다 — 여기서 먼저 보는 것은 시작 전 스냅샷을 찍기 전에 이유를 보이려는 것).
        // 목록을 받는 중이면 기다린다 — 빈 목록으로 "못 읽음" · "모델을 고르세요" 라고 하지 않게.
        if provider == .gemini {
            if modelCatalogs[scope]?.options.isEmpty ?? true {
                sendingThreads[thread.id] = .checkingModels
                await refreshModelCatalog(scope)
                sendingThreads[thread.id] = .preparing
            }
            if let block = antigravityBlock(for: thread) {
                banner = BannerMessage(text: "Antigravity 로 보내지 않았습니다 — " + block.message, isError: true, threadID: thread.id)
                return false
            }
            if !ModelDefaults.hasChosenModel(thread.selection(for: .gemini), provider: .gemini),
               let option = ModelCatalog.preferredOption(in: options(for: scope)) {
                var selection = thread.selection(for: .gemini)
                selection.model = option.identifier
                thread.setSelection(selection, for: .gemini)
                filledModel = option.identifier
            }
        }
        // 이 대화에 이미 실행이 있으면 받지 않는다 (한 대화에는 실행 하나. 다른 대화의 실행은 함께 돈다).
        guard runner.session(threadID: thread.id) == nil else {
            banner = BannerMessage(text: "이 대화에서 에이전트가 실행 중입니다. 끝나기를 기다리거나 중단한 뒤 다시 보내세요.", isError: true, threadID: thread.id)
            return false
        }
        // 자동 작업의 검토가 이 폴더를 읽는 중이면 시작하지 않는다 — 검토는 방금 끝난 작업의 폴더를 읽고 있다.
        guard !isReviewing(inProjectPath: project.path) else {
            banner = BannerMessage(text: "자동 작업의 검토가 진행 중입니다. 끝난 뒤에 보내세요.", isError: true, threadID: thread.id)
            return false
        }
        // 앱의 git 쓰기가 이 폴더에서 도는 중이면 시작하지 않는다 (같은 폴더를 함께 쓰지 않고, 그 명령의 변경이 이 실행의
        // 시작 전 스냅샷에 반쯤 섞이지 않게).
        if let operation = runningGitOperation, runningGitProjectPath == project.path {
            banner = BannerMessage(text: "앱이 이 폴더에서 \(operation.progressText). 끝난 뒤에 보내세요.",
                                   isError: true, threadID: thread.id)
            return false
        }
        if let operation = worktreeActivity(threadID: thread.id, path: project.path) {
            banner = BannerMessage(text: "독립 작업 폴더를 \(operation.kind.koreanName) 중입니다. 끝난 뒤에 보내세요.",
                                   isError: true, threadID: thread.id)
            return false
        }
        // 시작 전 스냅샷을 찍는 동안 runner 는 아직 쉬고 있다 — 그 사이 다시 누른 보내기가 두 번째 실행을 시작하지 않게
        // 받지 않는다 (입력 초안은 그대로 남고, 첫 보내기가 받아들여지면 비워진다).
        guard !isStartingRun(threadID: thread.id) else {
            banner = BannerMessage(text: "에이전트 실행을 시작하는 중입니다. 시작한 뒤에 다시 보내세요.", isError: false, threadID: thread.id)
            return false
        }
        // 앱 종료를 묻는 중 · 종료가 확정됐다 — 새 CLI 를 띄우지 않는다 (보내던 글은 입력창에 남는다 — `saveBeforeQuit`, chr-9).
        guard !handoffsSuspendedForQuit else {
            banner = BannerMessage(text: "앱을 종료하는 중이라 보내지 않았습니다. 글은 입력창에 남겼습니다.", isError: false,
                                   threadID: thread.id)
            return false
        }
        let starting = beginStarting(threadID: thread.id, projectPath: project.path)
        defer { endStarting(starting) }
        sendingThreads[thread.id] = .starting
        // Codex: 글 속 "$이름" 이 그 폴더의 스킬이면 스킬 입력으로 함께 보낸다 (받아 둔 목록이 없으면 먼저 받는다).
        let skills = provider == .codex ? await codexSkillMentions(in: prompt, thread: thread) : []
        // Claude: 맨 앞의 "/명령" 은 CLI 가 펼친다 — 앞에 앱의 안내를 붙이면 명령이 아니게 되므로 안내는 다음 턴으로 미룬다.
        let noteKey = Self.folderMoveKey(thread.id, provider)
        let defersNote = provider == .claude && SlashCommands.isClaudeInvocation(prompt)
        // 에이전트가 뜨기 전에 작업 폴더를 찍어 둔다 (실행이 끝나면 차이로 "이번 실행에서 바뀐 파일" 을 구한다).
        let tracking = await beginRunChangeTracking(threadID: thread.id, project: project)
        do {
            _ = try await runner.send(prompt: prompt, thread: thread, project: project,
                                      provider: provider,
                                      account: accounts.ref(thread.codexAccountID),
                                      turn: AgentTurnOptions(images: images, skills: skills,
                                                             preamble: defersNote ? nil : folderMoveNotes[noteKey]))
            if !defersNote { folderMoveNotes[noteKey] = nil }
            // 시작하는 동안(스냅샷 · CLI 확인) 사용자가 모델 칩 · 계정 칩에서 바꾼 값을 처음 복사한 `thread` 로 덮지 않는다
            // ("이 대화에만 적용됩니다 · 다음 메시지부터"). 보낸 에이전트 · 자리표시 제목 · 비어 있던 모델만 남긴다.
            // 에이전트는 시작할 때 값(`thread.preferredProvider`)이 그대로일 때만 바꾼다 — 그 사이 누른 에이전트 토글을 지킨다.
            let placeholder = thread.hasPlaceholderTitle
            await recordThreadSend(thread, provider: provider, onlyIfProviderWas: thread.preferredProvider,
                                   placeholderTitle: placeholder ? ThreadTitle.fromMessage(prompt.isEmpty ? "이미지" : prompt) : nil,
                                   filledModel: filledModel, codexAccountID: nil)
            return true
        } catch {
            discardRunChangeTracking(tracking)
            banner = BannerMessage(text: error.localizedDescription, isError: true, threadID: thread.id)
            return false
        }
    }

    /// 보내기 전에 본 그 에이전트의 준비 상태로 막을 안내 (`SendReadiness`, onb-4). 쓸 수 없다는 사실이 오래됐을 수 있어(터미널에서 막
    /// 설치 · 로그인했다) 막기 전에 그 에이전트만 한 번 다시 확인한다. 확인 전 · 로그인 모름은 막지 않는다 (CLI 가 스스로 확인한다).
    /// Codex 는 그 대화의 계정으로 본다 (로그인은 계정마다 따로다). 가짜 어댑터를 넣은 실행(검증 · 화면 확인)은 CLI 를 보지 않는다.
    func sendReadinessBlock(provider: AgentProvider, thread: ConversationThread) async -> SendReadiness.Block? {
        guard !Self.offlinePreview, runner.adapterFactory == nil,
              SendReadiness.blocks(sendReadiness(provider: provider, thread: thread)) else { return nil }
        await refreshAgentFacts(force: true, only: [provider])
        let label = provider == .codex && accounts.hasMultiple ? codexAccount(for: thread).label : nil
        return SendReadiness.block(provider: provider, readiness: sendReadiness(provider: provider, thread: thread), accountLabel: label)
    }

    /// 보내기 전에 보는 그 에이전트의 준비 상태 — Codex 는 그 대화의 계정 (로그인은 계정마다 따로다). 입력창의 에이전트 표시도 이것을 본다.
    func sendReadiness(provider: AgentProvider, thread: ConversationThread) -> AgentReadiness {
        // API 키로 보내는 대화는 구독 로그인이 없어도 막지 않는다 — CLI 를 쓸 수 있는지만 본다.
        if provider == .claude, usesClaudeAPI(threadID: thread.id) { return Self.readinessWithAPIKey(agentReadiness(.claude)) }
        guard provider == .codex, cliStatus[.codex]?.isUsable == true else { return agentReadiness(provider) }
        return codexLoginReadiness(accountID: thread.codexAccountID)
    }

    /// 모델을 정하지 못해 보내지 않을 때의 안내 — 왜인지(목록을 받지 못함 · 기본 모델을 모름)와 할 일. "모델을 고르세요" 만 말하지 않는다.
    func modelUnresolvedText(provider: AgentProvider, scope: AgentScope) -> String {
        let name = provider == .claude ? "Claude Code" : provider.displayName
        guard let snapshot = modelCatalogs[scope], snapshot.discovered, !snapshot.options.isEmpty else {
            let reason = modelCatalogs[scope]?.message.map { " (\(JSONUtil.truncate($0, max: 160)))" } ?? ""
            return "\(name) 의 모델 목록을 받지 못해 보내지 않았습니다\(reason). 목록을 다시 확인하거나, 입력창의 모델에서 쓸 모델을 고른 뒤 보내세요."
        }
        return "\(name) 에서 기본 모델을 확인하지 못해 보내지 않았습니다. 입력창의 모델에서 쓸 모델을 고른 뒤 보내세요."
    }

    /// 이 스레드의 Antigravity 선택으로는 보낼 수 없는 이유 (`AntigravityAdapter.plan` + 메모리의 모델 목록). 보낼 수 있으면 nil.
    func antigravityBlock(for thread: ConversationThread) -> AntigravityAdapter.TurnBlock? {
        let selection = thread.selection(for: .gemini)
        guard case .blocked(let block) = AntigravityAdapter.plan(
            model: selection.model, effort: selection.effort,
            options: options(for: thread.scope(for: .gemini))) else { return nil }
        return block
    }

    /// 포커스 대화의 실행을 멈춘다 (메뉴 · ⌘.). 다른 대화의 실행은 그대로 돈다. 포커스 칸이 비었으면 `interruptTargetThreadID`.
    func interrupt() async {
        if let id = interruptTargetThreadID, runner.session(threadID: id) != nil { await runner.interrupt(threadID: id) }
    }

    /// 마지막으로 포커스였던 대화 (`syncPanes`) — 분할한 직후처럼 포커스 칸이 비었을 때 ⌘. 가 멈출 대화를 고른다.
    @ObservationIgnored private var lastFocusedThreadID: String?

    /// ⌘. 가 멈출 대화. 포커스 대화가 있으면 그것. 포커스 칸이 비었으면(분할한 직후) 칸에 열린 대화 가운데 — 마지막으로 보던 대화가
    /// 돌고 있으면 그것, 아니면 도는 대화가 하나뿐일 때 그것 (chr-8: 분할하면 보던 대화의 실행을 ⌘. 로 멈출 수 없었다).
    var interruptTargetThreadID: String? {
        if let id = selectedThreadID { return id }
        let shown: [String] = panes.threadIDs.compactMap { $0 }
        if let last = lastFocusedThreadID, shown.contains(last), runner.isBusy(threadID: last) { return last }
        let busy = shown.filter { runner.isBusy(threadID: $0) }
        return busy.count == 1 ? busy[0] : nil
    }

    /// ⌘. 로 멈출 실행이 있다 (메뉴가 본다).
    var canInterrupt: Bool { interruptTargetThreadID.map { runner.isBusy(threadID: $0) } ?? false }

    /// 그 대화의 실행이 띄운 하위 작업 하나만 멈춘다 (`SubAgentInfo.canStop` 인 것). 실행 전체는 계속된다.
    /// 멈추기를 보냈으면 true — 멈춘 결과는 어댑터가 `.subAgent` 로 알린다.
    @discardableResult
    func stopSubAgent(threadID: String, agentID: String) async -> Bool {
        await runner.stopSubAgent(threadID: threadID, agentID: agentID)
    }

    /// 인스펙터 "에이전트" 탭이 대화마다 보여 줄 하위 작업 (대화 id → 하위 id). 없거나 사라졌으면 탭이 고른다
    /// (가장 최근에 시작한 도는 하위, 없으면 가장 최근 것 — `SubAgentList.resolve`).
    private(set) var subAgentFocus: [String: String] = [:]

    /// 그 대화의 하위 작업 하나를 "에이전트" 탭에 띄운다 (카드의 한 줄 · 탭의 칩이 부른다).
    func focusSubAgent(threadID: String, agentID: String) {
        guard subAgentFocus[threadID] != agentID else { return }
        subAgentFocus[threadID] = agentID
    }

    /// 이 폴더에서 메인 턴을 마치고 남은 백그라운드 작업을 기다리는 실행들의 끝나지 않은 작업 수 (잠금 안내에 덧붙인다).
    func backgroundTaskCount(inProjectPath path: String) -> Int {
        writeSessions(inProjectPath: path).filter(\.isWaitingOnBackground).reduce(0) { $0 + $1.unfinishedSubAgentCount }
    }

    /// 지금 도는 실행 전부: 대화들의 실행 + 자동 작업의 검토 (메뉴바 · 종료 확인이 본다).
    var activeSessions: [RunSession] { runner.activeSessions + reviewLanes.activeSessions }

    func interruptAll() async {
        await runner.interruptAll()
        await reviewLanes.interruptAll()
    }

    /// 포커스 대화에 실행이 돌고 있다 (메뉴 · 인계 버튼의 잠금이 본다).
    var isSelectedThreadBusy: Bool { selectedThreadID.map { runner.isBusy(threadID: $0) } ?? false }

    /// 오케스트레이션의 한 턴을 앱의 실행 경로로 보낸다. 수동 보내기와 같은 잠금 · 실행 전 스냅샷을 쓴다
    /// (git 쓰기 중이거나 다른 실행을 시작하는 중이면 슬롯이 찬 것으로 본다).
    /// 모델 · 계정은 호출자가 그 대화의 선택에 이미 적어 두었다.
    func launchOrchestrationTurn(prompt: String, thread: ConversationThread, project: Project,
                                 provider: AgentProvider, turn: AgentTurnOptions) async throws -> Run {
        guard !isRunSlotBusy(project: project) else { throw RunCoordinator.StartError.busy }
        let starting = beginStarting(threadID: thread.id, projectPath: project.path)
        defer { endStarting(starting) }
        let tracking = await beginRunChangeTracking(threadID: thread.id, project: project)
        do {
            return try await runner.send(prompt: prompt, thread: thread, project: project, provider: provider,
                                         account: accounts.ref(thread.codexAccountID), turn: turn)
        } catch {
            discardRunChangeTracking(tracking)
            throw error
        }
    }

    // MARK: - 실행별 변경 파일 (실행 전후 비교)

    /// 실행 시작 직전에 찍은 작업 폴더 스냅샷. 실행마다 하나 (여러 대화의 실행이 함께 돌 수 있다).
    private struct RunChangeTracking {
        let token: UUID
        let threadID: String
        /// 실행한 프로젝트 폴더 (그 사이 다른 프로젝트를 봐도 이 폴더를 다시 찍는다).
        let projectPath: String
        /// runner 가 실행을 만들면 그 ID (`didChangeState(.starting)`). 아직 시작하지 않았으면 nil.
        var runID: String?
        let before: RunSnapshotRead
        /// 같은 폴더에서 다른 실행과 겹쳤다. 전후 차이가 누구의 것인지 가를 수 없으므로 비교하지 않는다 —
        /// **겹친 양쪽 모두** (한쪽만 표시하면 먼저 시작한 실행의 카드가 뒤 실행의 편집을 품는다).
        var overlapped = false
    }
    @ObservationIgnored private var runChangeTrackings: [UUID: RunChangeTracking] = [:]

    /// 실행을 시작하는 중인 것들 (시작 전 스냅샷 ~ runner 가 실행을 만들 때까지). 이 사이에는 runner 에 아직 실행이 없어
    /// 사람이 다시 누른 보내기를 runner 가 막지 못한다 — `send` · 사람이 누른 인계 보내기가 이것으로 한 번만 받는다.
    /// 자동 인계와 사람의 보내기가 겹칠 수 있어 하나씩 센다 (한쪽이 끝나며 다른 쪽의 막음을 풀지 않게).
    private struct StartingRun { let token: UUID; let threadID: String; let projectPath: String }
    private var startingRunList: [StartingRun] = []
    /// 어느 대화든 시작하는 중이다.
    var isStartingRun: Bool { !startingRunList.isEmpty }
    /// 그 대화의 실행을 시작하는 중이다 (입력창의 보내기 버튼 · 인계 보내기가 본다).
    func isStartingRun(threadID: String) -> Bool { startingRunList.contains { $0.threadID == threadID } }
    /// 그 폴더에서 실행을 시작하는 중이다 (git 쓰기 잠금이 본다).
    func isStartingRun(projectPath: String) -> Bool { startingRunList.contains { $0.projectPath == projectPath } }

    func beginStarting(threadID: String, projectPath: String) -> UUID {
        let token = UUID()
        startingRunList.append(StartingRun(token: token, threadID: threadID, projectPath: projectPath))
        return token
    }
    func endStarting(_ token: UUID) { startingRunList.removeAll { $0.token == token } }

    /// 실행이 끝난 직후의 스냅샷 · 기록 작업, 폴더별. **같은 폴더**의 다음 실행의 시작 전 스냅샷 · 인계 초안 · 앱의 git 쓰기는
    /// 이것이 끝난 뒤에 한다 (바로 다음 메시지를 보내도 앞 실행의 "뒤" 에 다음 실행의 편집이나 앱의 커밋이 섞이지 않게).
    @ObservationIgnored var runChangeFinishing: [String: Task<FinishedRunRead?, Never>] = [:]
    /// 실행 중 다시 읽기가 걸린 폴더 (H8 — `scheduleLiveGitRefresh`). 폴더마다 하나만 기다린다.
    @ObservationIgnored private var liveGitRefreshes: [String: Task<Void, Never>] = [:]
    /// 파일 탭이 폴더마다 기억하는 펼친 폴더 · 찾는 글자 (탭을 오가도 남는다 — chg-4). 메모리에만.
    @ObservationIgnored var filesTreeMemory: [String: FilesTreeMemory] = [:]
    /// 종료 스냅샷에서 읽은 그 폴더의 git 상태와 폴더 경로.
    typealias FinishedRunRead = (status: GitWorkspaceStatus, path: String)
    /// 종료 스냅샷이 도는 중인 폴더 (git 쓰기 잠금이 본다).
    private(set) var finishingProjectPaths: Set<String> = []
    var isFinishingRunChanges: Bool { !finishingProjectPaths.isEmpty }
    /// 앱 종료로 끝낸 실행과, 그것이 쓰기 실행(`runner`)인지 (검토 레인이면 false). 종료가 취소되면 뒷정리한다 (`reconcileCancelledQuit`).
    @ObservationIgnored private var quitRuns: [(run: Run, writer: Bool)] = []

    /// 그 폴더에서 파일을 바꿀 수 있는 실행 (runner 의 세션. 검토 레인은 읽기 전용이라 세지 않는다).
    func writeSessions(inProjectPath path: String) -> [RunSession] {
        runner.activeSessions.filter { $0.activeProjectPath == path }
    }
    /// 자동 작업의 검토단이 그 폴더를 읽고 있다.
    func isReviewing(inProjectPath path: String) -> Bool {
        reviewLanes.activeSessions.contains { $0.activeProjectPath == path }
    }

    /// 스레드별로 검토하지 않은 실행 (스레드 ID → 실행 ID, 메모리에만). 변경사항 탭 아이콘의 점이 이것을 본다.
    /// 실행이 끝나 검토할 파일이 있으면 넣고, 그 스레드에서 변경사항 탭을 열면 비운다.
    private(set) var unreviewedRunIDs: [String: Set<String>] = [:]

    /// "변경사항 검토" 칩으로 연 요청. 변경사항 탭이 그 실행의 파일을 목록 위로 올린다.
    struct ChangesReviewRequest: Equatable {
        let id: UUID
        let threadID: String
        let runID: String
        /// 올릴 경로 (저장소 루트 기준, 실행 전후 비교로 찾은 파일 중 실행 뒤에도 목록에 남은 것). nil 이면 비교하지 못한
        /// 실행이라 탭이 그 실행의 기록에 남은 편집 파일로 대신한다.
        let paths: [String]?
        /// 그 실행에서 바뀌었지만 실행 뒤 목록에서 사라진 파일 수 · 기록 상한으로 경로를 모르는 파일 수.
        /// 올린 구역의 행 수와 합쳐 카드의 파일 수가 되도록 구역 머리에 밝힌다.
        var clearedByRun = 0
        var unstored = 0
    }
    private(set) var changesReview: ChangesReviewRequest?

    /// 실행 시작 직전 스냅샷. 모든 실행 시작 경로(`send` · `deliverHandoff`)가 runner 를 부르기 직전에 부른다.
    /// 반환값은 시작하지 못했을 때 `discardRunChangeTracking` 에 넘긴다. 그 대화에 실행이 있으면 찍지 않는다 (runner 가 거절한다).
    func beginRunChangeTracking(threadID: String, project: Project) async -> UUID? {
        guard runner.session(threadID: threadID) == nil else { return nil }
        // 같은 폴더의 앞 실행의 종료 스냅샷이 아직 도는 중이면 끝나기를 기다린다.
        _ = await runChangeFinishing[project.path]?.value
        let env = await environment.childEnvironment()
        let before = await RunFileSnapshot.capture(at: project.url, environment: env).read
        // 찍는 사이 이 대화의 다른 보내기가 실행을 시작했으면 이 스냅샷은 그 실행 도중의 것일 수 있다 — 쓰지 않는다.
        guard runner.session(threadID: threadID) == nil else { return nil }
        let token = UUID()
        runChangeTrackings[token] = RunChangeTracking(token: token, threadID: threadID, projectPath: project.path,
                                                      runID: nil, before: before)
        return token
    }

    /// 실행을 시작하지 못했으면 찍어 둔 스냅샷을 버린다. 이미 실행에 묶인 것(시작한 실행의 것)은 두고.
    func discardRunChangeTracking(_ token: UUID?) {
        guard let token, let tracking = runChangeTrackings[token], tracking.runID == nil else { return }
        runChangeTrackings[token] = nil
    }

    /// runner 가 실행을 만든 순간 (프로세스를 띄우기 전) 시작 전 스냅샷을 그 실행에 묶는다. 같은 폴더에서 이미 도는 실행이
    /// 있으면 **양쪽**을 겹침으로 표시한다 — 시작하지 못한 보내기는 여기까지 오지 않으므로 남의 카드를 괜히 망치지 않는다.
    private func bindRunChangeTracking(to run: Run) {
        guard let token = runChangeTrackings.first(where: { $0.value.runID == nil && $0.value.threadID == run.threadID })?.key,
              var tracking = runChangeTrackings[token] else { return }
        tracking.runID = run.id
        let others = runChangeTrackings.filter { $0.key != token && $0.value.runID != nil && $0.value.projectPath == tracking.projectPath }
        // 추적하지 않은 실행(스냅샷을 못 찍고 시작한 것)이 같은 폴더에서 돌아도 겹친 것이다.
        let untracked = writeSessions(inProjectPath: tracking.projectPath).contains { session in
            guard let id = session.activeRun?.id, id != run.id else { return false }
            return !runChangeTrackings.values.contains { $0.runID == id }
        }
        if !others.isEmpty || untracked { tracking.overlapped = true }
        for key in others.keys { runChangeTrackings[key]?.overlapped = true }
        runChangeTrackings[token] = tracking
    }

    /// 실행이 끝난 직후: 같은 폴더를 다시 찍어 시작 전과의 차이를 그 실행의 이벤트 하나로 남긴다.
    /// 시작 전 스냅샷이 묶이지 않은 실행(추적하지 않은 실행)은 남기지 않는다. 한쪽이라도 못 찍었으면
    /// "비교하지 못함" 을 이유와 함께 남긴다 (화면은 실행 기록의 편집으로 대신한다). 같은 폴더에서 다른 실행과 겹쳤어도 그렇다.
    /// 에이전트 프로세스의 종료를 확인하지 못했으면 그 사실을 함께 남긴다 (스냅샷 뒤에도 파일이 바뀌었을 수 있다).
    /// 반환값 = 종료 스냅샷에서 읽은 그 폴더의 git 상태 (작업 폴더 상태를 곧바로 한 번 더 읽지 않도록). 없으면 nil.
    @discardableResult
    func finishRunChangeTracking(_ run: Run) async -> FinishedRunRead? {
        guard let tracking = runChangeTrackings.values.first(where: { $0.runID == run.id }) else { return nil }
        runChangeTrackings[tracking.token] = nil
        if tracking.overlapped {
            await recordRunChanges(.notCompared(runID: run.id, reason: .overlapped), run: run, projectPath: tracking.projectPath)
            return nil
        }
        let env = await environment.childEnvironment()
        let after = await RunFileSnapshot.capture(at: URL(fileURLWithPath: tracking.projectPath), environment: env)
        var changes = RunFileChanges.summarize(runID: run.id, before: tracking.before, after: after.read)
        changes.processUnconfirmed = run.childProcessNote != nil || !runner.unterminatedProcesses.isEmpty
        await recordRunChanges(changes, run: run, projectPath: tracking.projectPath)
        return after.status.map { ($0, tracking.projectPath) }
    }

    /// 그 실행의 시작 전 스냅샷을 찍은 폴더 (종료 스냅샷을 폴더별로 줄 세울 때 쓴다).
    private func trackedProjectPath(runID: String) -> String? {
        runChangeTrackings.values.first { $0.runID == runID }?.projectPath
    }

    /// 요약 이벤트를 남기고, 검토할 것이 있으면 그 스레드의 변경사항 탭에 점을 붙인다.
    private func recordRunChanges(_ changes: RunFileChanges, run: Run, projectPath: String) async {
        guard let saved = try? await store.appendEvent(changes.event(threadID: run.threadID,
                                                                     provider: run.provider)) else { return }
        runCoordinator(runner, didUpsert: saved)
        var observed = 0
        if !changes.compared {
            let events = (try? await store.events(threadID: run.threadID)) ?? []
            observed = ExecutionParser.observedEdits(in: events, runID: run.id, projectPath: projectPath).count
        }
        let reviewable = changes.reviewable(observedCount: observed)
        if reviewable {
            unreviewedRunIDs[run.threadID, default: []].insert(run.id)
        }
        // 같은 대화에서 "변경사항 검토" 로 앞선 실행을 올려 두었으면 방금 끝난 실행으로 바꾼다 — 검토할 것이 없으면 푼다 (H9).
        // 같은 요청 ID 를 둔다 — 찾기 칸 · 스크롤은 그대로 두고 구역만 새 실행의 것으로.
        if let review = changesReview, review.threadID == run.threadID, review.runID != run.id {
            changesReview = reviewable ? Self.reviewRequest(id: review.id, threadID: run.threadID, changes: changes) : nil
        }
    }

    /// 실행 하나의 "변경사항 검토" 요청 (올릴 파일 · 구역 머리의 설명 수).
    private static func reviewRequest(id: UUID, threadID: String, changes: RunFileChanges) -> ChangesReviewRequest {
        ChangesReviewRequest(id: id, threadID: threadID, runID: changes.runID, paths: changes.reviewPaths,
                             clearedByRun: changes.compared ? changes.clearedCount : 0,
                             unstored: changes.compared ? changes.unstoredCount : 0)
    }

    /// 이 스레드에 검토하지 않은 실행이 있는지 (변경사항 탭 아이콘의 점).
    func hasUnreviewedChanges(threadID: String?) -> Bool {
        guard let threadID else { return false }
        return !(unreviewedRunIDs[threadID]?.isEmpty ?? true)
    }

    /// 변경사항 탭을 열었다 — 그 스레드의 점을 뗀다.
    func markChangesReviewed(threadID: String?) {
        guard let threadID, unreviewedRunIDs[threadID] != nil else { return }
        unreviewedRunIDs[threadID] = nil
    }

    /// "변경사항 검토" 칩. 인스펙터를 변경사항 탭으로 여는 것은 화면(창 상태 `@AppStorage`)이 하고,
    /// 여기서는 올릴 파일을 남기고 그 스레드를 검토한 것으로 친다. 좁은 패널 diff 가 목록을 가리고 있으면 닫는다
    /// (올린 구역이 diff 뒤에 숨지 않게 — 크게 보기 중에는 목록이 보이므로 그대로 둔다).
    func requestChangesReview(threadID: String, changes: RunFileChanges) {
        changesReview = Self.reviewRequest(id: UUID(), threadID: threadID, changes: changes)
        markChangesReviewed(threadID: threadID)
        if narrowDiffShown { closeDiff() }
    }

    /// 올린 목록을 원래 순서로 (탭을 떠나거나 스레드 · 폴더가 바뀌거나 "원래 순서" 를 눌렀을 때).
    func clearChangesReview() {
        if changesReview != nil { changesReview = nil }
    }

    // MARK: - 파일 diff (변경사항 탭 좁은 패널 · 크게 보기)

    /// 보고 있는 파일 (저장소 루트 기준). 폴더(`workspace.projectPath`)가 다르면 없는 것으로 친다 (`activeDiffPath`).
    struct DiffFocus: Equatable {
        let projectPath: String
        var path: String
    }
    private(set) var diffFocus: DiffFocus?
    /// 크게 보기 (가운데 칸을 diff 로). 메모리에만 둔다 — 앱을 다시 열면 대화로 시작한다 (`WindowPane.restored`).
    private(set) var diffWide = false
    /// 바뀔 때마다 diff 화면이 키 받는 뷰를 첫 응답자로 삼을지 본다 (파일을 눌러 열면 곧바로 esc · ⌥↑↓ · space).
    /// 요청은 한 번만, 그리고 잠깐만 쓴다 (`takeDiffKeyFocus`) — 요청한 순간 diff 가 화면에 없었으면(인스펙터가 숨었거나
    /// 다른 탭) 버려진다. 나중에 탭을 오가다 diff 가 나타날 때 입력창 · 커밋 칸의 포커스를 빼앗지 않게 (그 뒤 space 가 stage 로 가지 않게).
    private(set) var diffKeyFocusRequest = 0
    private var diffKeyFocusRequestedAt: Date?
    /// 키 포커스 요청이 살아 있는 시간 (파일을 눌러 연 뒤 diff 가 나타나기까지 — 크게 보기 전환도 0.2초 안쪽).
    static let diffKeyFocusWindow: TimeInterval = 1.5
    /// 보던 파일이 목록에서 빠져 다른 파일로 옮겼을 때 한 번 보이는 안내. 다음 이동 · 닫기에서 지운다.
    private(set) var diffNotice: String?
    /// 변경사항 탭 목록에 마지막으로 보인 순서 (올린 구역 · 찾기 결과 포함, 저장소 루트 기준). ⌥↑ ⌥↓ 가 따른다.
    private(set) var changesListOrder: [String] = []
    /// 그 순서를 만든 폴더 · git 상태 시각. 목록이 화면에서 사라지면 nil — 그때 크게 보기는 찾기로 걸러진 순서를 그대로 쓰지 않는다
    /// (`changesListOrderIsCurrent`).
    private var changesListOrderSource: (projectPath: String?, statusReadAt: Date?)?
    /// 보던 파일이 들어 있던 마지막 목록 순서 — 그 파일이 빠졌을 때 다음 파일을 고르는 기준.
    private var diffOrderContext: [String] = []

    var activeDiffPath: String? {
        guard let focus = diffFocus, focus.projectPath == workspace.projectPath else { return nil }
        return focus.path
    }

    /// 크게 보기가 지금 보일 수 있는지 (이 폴더의 파일을 보고 있을 때만).
    var diffWideActive: Bool { diffWide && activeDiffPath != nil }

    /// 좁은 패널 diff 가 변경사항 탭 목록 자리에 있는지 (목록 · 머리줄 · 찾기 칸이 가려져 있다).
    var narrowDiffShown: Bool { !diffWide && activeDiffPath != nil }

    /// 목록 순서를 받는다 (변경사항 탭이 행 · 찾기 · 올린 구역이 바뀔 때). `statusReadAt` = 그 목록을 만든 git 상태를 읽은 시각.
    func updateChangesListOrder(_ order: [String], statusReadAt: Date? = nil) {
        if changesListOrder != order { changesListOrder = order }
        changesListOrderSource = (workspace.projectPath, statusReadAt)
        if let path = activeDiffPath, order.contains(path) { diffOrderContext = order }
    }

    /// 변경사항 탭 목록이 화면에서 사라졌다 — 마지막 순서(찾기 결과일 수 있다)는 더 이상 "지금 보이는 순서" 가 아니다.
    func markChangesListHidden() {
        changesListOrderSource = nil
    }

    /// 마지막으로 받은 목록 순서가 지금 화면에 보이는 목록 그대로인지 (같은 폴더 · 같은 git 상태에서 만들었고 목록이 보인다).
    /// 그렇지 않으면 크게 보기는 그 순서에 없는 파일을 뒤에 붙인다 (`ChangesState.diffOrder`).
    func changesListOrderIsCurrent(statusReadAt: Date?) -> Bool {
        guard let source = changesListOrderSource, statusReadAt != nil else { return false }
        return source.projectPath == workspace.projectPath && source.statusReadAt == statusReadAt
    }

    /// 파일 행을 눌렀을 때 · 크게 보기에서 목록의 다른 파일을 눌렀을 때 · 이전 / 다음 파일.
    /// 다른 폴더에서 켜 둔 크게 보기는 이어 쓰지 않는다 (그 폴더의 파일을 누르면 좁은 패널로 연다).
    func openDiff(path: String, focusKeys: Bool = true) {
        guard let project = workspace.projectPath else { return }
        if diffFocus?.projectPath != project { diffWide = false }
        diffFocus = DiffFocus(projectPath: project, path: path)
        diffNotice = nil
        if changesListOrder.contains(path) { diffOrderContext = changesListOrder }
        if focusKeys { requestDiffKeyFocus() }
    }

    func requestDiffKeyFocus(now: Date = Date()) {
        diffKeyFocusRequestedAt = now
        diffKeyFocusRequest += 1
    }

    /// diff 화면이 키 포커스 요청을 받는다 (있었고 아직 살아 있으면 true, 한 번만).
    func takeDiffKeyFocus(now: Date = Date()) -> Bool {
        guard let requestedAt = diffKeyFocusRequestedAt else { return false }
        diffKeyFocusRequestedAt = nil
        return now.timeIntervalSince(requestedAt) <= Self.diffKeyFocusWindow
    }

    /// ‹ 변경사항 (좁은 패널 esc) · ‹ 대화로 돌아가기 (크게 보기 esc) — diff 를 닫는다. 인스펙터는 목록으로 돌아간다.
    func closeDiff() {
        diffFocus = nil
        diffWide = false
        diffNotice = nil
        diffKeyFocusRequestedAt = nil
    }

    /// 크게 보기 · 패널로 줄이기. 보는 파일이 없으면 켜지 않는다. `focusKeys` 는 사용자가 diff 쪽을 누른 경우에만
    /// (인계 · 알림으로 크게 보기를 접을 때는 diff 가 키를 가져가지 않는다).
    func setDiffWide(_ wide: Bool, focusKeys: Bool = true) {
        guard activeDiffPath != nil else {
            diffWide = false
            return
        }
        diffWide = wide
        if focusKeys { requestDiffKeyFocus() }
    }

    /// 다른 폴더로 옮기면 보던 diff 를 닫는다 — 돌아왔을 때 크게 보기 · 좁은 패널이 저절로 되살아나지 않게.
    func closeDiffIfProjectChanged(to projectPath: String?) {
        if let focus = diffFocus, focus.projectPath != projectPath { closeDiff() }
    }

    /// 화면에 그릴 파일: 보던 파일이 목록에 있으면 그 파일, 빠졌으면 `reconcileDiffFocus` 가 옮길 파일 (git 상태가 먼저 그려지고
    /// 판단이 뒤따르는 한 박자 동안 diff 화면을 목록으로 바꿨다 되돌리지 않게 — 키 포커스를 잃지 않는다). 없으면 nil.
    func diffShownPath(present: Set<String>) -> String? {
        guard let path = activeDiffPath else { return nil }
        if present.contains(path) { return path }
        return ChangesState.diffReplacement(for: path, previousOrder: diffOrderContext, present: present)
    }

    /// 목록 순서로 이전(-1) · 다음(+1) 파일. 끝에서는 멈춘다.
    func stepDiff(_ delta: Int, order: [String]) {
        guard let path = activeDiffPath else { return }
        let position = ChangesState.diffPosition(of: path, in: order)
        guard let target = delta < 0 ? position.previous : position.next else { return }
        openDiff(path: target, focusKeys: false)
    }

    /// git 상태를 다시 읽은 뒤: 보던 파일이 목록에서 빠졌으면(커밋 · 되돌림 · 무시 목록 등) 빠지기 전 순서의 다음 파일로 옮기고
    /// 한 번 알린다. 남은 파일이 없으면 닫는다 (좁은 패널은 목록으로, 크게 보기는 대화로). 상태를 못 읽었으면 판단하지 않는다.
    /// 빠진 까닭은 앱이 알 수 없어 적지 않는다.
    func reconcileDiffFocus(rows: [ChangesState.Row], statusReadable: Bool) {
        guard statusReadable, let path = activeDiffPath else { return }
        let present = Set(rows.map(\.path))
        guard !present.contains(path) else { return }
        let name = (path as NSString).lastPathComponent
        if let next = ChangesState.diffReplacement(for: path, previousOrder: diffOrderContext, present: present) {
            diffFocus?.path = next
            diffNotice = "\(name) — 변경 목록에서 빠졌습니다. 다음 파일을 보여줍니다."
        } else {
            closeDiff()
        }
    }

    #if DEBUG
    /// 화면 확인용 (`-preview.action runSummary`, Debug 빌드 · `AHC_OFFLINE=1` · `AHC_DATABASE_PATH` 로 연 DB ·
    /// 임시 폴더 안의 프로젝트일 때만). 오프라인 미리보기에는 실행이 없어 카드와 탭 점을 볼 수 없으므로, 끝난 실행 하나를
    /// **그 DB 에만** 합성하고 요약은 실제 스냅샷 · 차이 함수로 만든다: 실행 전 = 빈 스냅샷(모든 경로가 실행 전에 깨끗했다고 본다,
    /// HEAD 는 지금 값), 실행 후 = 지금 폴더를 실제로 읽은 값. 저장소가 아니면 비교할 수 없어 대체 카드("관찰된 편집 n건")가
    /// 되며, 그때의 편집 기록은 폴더의 파일 몇 개로 만든 합성 기록이다. 합성이라는 사실은 대화에 그대로 적는다.
    /// 반환값 = 요약을 남긴 실행 (조건이 맞지 않으면 nil).
    func previewRecordRunChanges() async -> RunFileChanges? {
        guard Self.offlinePreview,
              !(ProcessInfo.processInfo.environment["AHC_DATABASE_PATH"] ?? "").isEmpty,
              let thread = selectedThread, let project = selectedProject,
              Self.isTemporaryPreviewProject(project.path) else { return nil }
        let provider = thread.preferredProvider
        let run = Run(threadID: thread.id, sessionID: "preview", provider: provider,
                      requestText: "화면 확인용 — 실행 전후 비교 카드", state: .completed, endedAt: Date(),
                      terminalReason: "preview",
                      codexAccountID: provider == .codex ? thread.codexAccountID : nil)
        guard (try? await store.insertRun(run)) != nil else { return nil }
        func append(_ kind: EventKind, _ from: AgentProvider?, title: String = "", _ text: String) async {
            _ = try? await store.appendEvent(ThreadEvent(threadID: thread.id, runID: run.id, kind: kind,
                                                         provider: from, title: title, text: text))
        }
        await append(.userMessage, nil, "화면 확인용 기록입니다 (-preview.action runSummary). 에이전트를 실행하지 않았습니다.")
        let env = await environment.childEnvironment()
        let after = await RunFileSnapshot.capture(at: project.url, environment: env).read
        let before: RunSnapshotRead
        switch after {
        case .taken(let snapshot):
            before = .taken(RunFileSnapshot(entries: [:], head: snapshot.head, headKnown: snapshot.headKnown))
            await append(.agentMessage, provider,
                         "아래 카드는 빈 스냅샷과 지금 폴더 상태를 앱의 실제 비교 함수로 비교한 결과입니다 (합성한 실행).")
        case .unavailable:
            before = after
            let files = FileTree.enumerateFiles(at: project.url, limit: 4)
            await append(.agentMessage, provider,
                         "아래 편집 기록은 폴더의 파일 이름으로 만든 합성 기록입니다. 이 폴더는 실행 전후 비교를 할 수 없습니다.")
            if !files.isEmpty {
                await append(.fileChange, provider, title: files.joined(separator: ", "), files.joined(separator: "\n"))
            }
        }
        let changes = RunFileChanges.summarize(runID: run.id, before: before, after: after)
        await recordRunChanges(changes, run: run, projectPath: project.path)
        await reloadThreadData()
        return changes
    }
    #endif

    // MARK: - Git 쓰기

    /// 진행 중인 git 쓰기 명령 (화면에서 버튼을 잠그는 데 쓴다).
    var runningGitOperation: GitWrite.Operation?
    /// 그 명령을 실행하는 프로젝트 폴더. 다른 프로젝트를 보는 동안 "올리는 중…" 을 그 화면에 쓰지 않도록 비교한다.
    private(set) var runningGitProjectPath: String?

    /// 마지막 git 쓰기 결과. 변경사항 탭이 커밋 · 업로드 · 받기 실패 이유와 "출력 보기" 를 화면 안에 보여줄 때 쓴다.
    struct GitOutcomeRecord {
        var operation: GitWrite.Operation
        var outcome: GitWrite.Outcome
        /// 실행한 프로젝트 폴더. 다른 프로젝트의 결과를 보여주지 않도록 비교한다.
        var projectPath: String
        var finishedAt: Date
        /// 명령이 끝난 뒤 다시 읽은 이 프로젝트의 상태 중 실패 안내가 기대는 값 (브랜치 · HEAD · 추적 브랜치 ·
        /// 앞섬/뒤처짐 · 마지막 fetch · 병합/rebase). 지금 상태와 다르면 그 실패는 지난 일이다
        /// (`ChangesState.failureIsCurrent`). 다시 읽지 못했으면 nil.
        var context: ChangesState.SyncContext? = nil
        /// 명령을 시작하기 직전의 같은 값 (업로드 성공 표시의 "커밋 n개" = 그때의 앞섬 수). 폴더를 막 바꿔 아직
        /// 읽지 않았으면 nil.
        var contextBefore: ChangesState.SyncContext? = nil
        /// 원격에 말을 건 명령(push · pull · fetch)이 실패했을 때 그 원격 이름과 주소. 로그인 실패 문구에만 쓴다.
        var remoteName: String? = nil
        var remoteURL: String? = nil
        /// 실패 분류 (`GitFailure`). 성공이면 nil. 기록을 만들 때 한 번만 분류한다 (화면이 다시 그려질 때마다
        /// 긴 훅 · 업로드 출력을 다시 훑지 않도록).
        var failure: GitFailure? = nil
    }
    private(set) var lastGitOutcome: GitOutcomeRecord?

    /// MERGE_MSG 로 커밋 초안을 채운 기록 (폴더 경로 → 병합 · 글자). 한 병합에서 한 번만 채우고,
    /// 병합이 끝났을 때 초안이 그 글자 그대로면 비우는 데 쓴다 (`ChangesState.mergeDraftAction`).
    /// 프로젝트가 아니라 폴더가 키다 — 독립 작업 폴더의 병합 메시지가 같은 프로젝트의 다른 폴더 칸에 채워지지 않게 (chg-8).
    private var mergeDraftAdoptions: [String: ChangesState.MergeDraftAdoption] = [:]

    /// 병합 중이면 MERGE_MSG 를 커밋 초안으로 (초안이 비어 있을 때만). 변경사항 탭이 병합 상태가 바뀔 때 부른다.
    func reconcileMergeDraft(folder: String, mergeHead: String?, mergeMessage: String?) {
        for _ in 0..<2 {
            let adopted = mergeDraftAdoptions[folder]
            let action = ChangesState.mergeDraftAction(draft: commitDraft(forFolder: folder), mergeHead: mergeHead,
                                                       mergeMessage: mergeMessage, adopted: adopted)
            switch action {
            case .fill(let message):
                commitDrafts[folder] = message
                if let mergeHead {
                    mergeDraftAdoptions[folder] = ChangesState.MergeDraftAdoption(mergeHead: mergeHead,
                                                                                 message: message)
                }
                return
            case .clear:
                // 지난 병합의 초안을 비운 뒤, 새 병합이 있으면 그 메시지로 채울지 한 번 더 본다.
                commitDrafts[folder] = ""
                mergeDraftAdoptions[folder] = nil
            case .none:
                // 병합이 끝났거나 바뀌었으면 기록은 더 쓸 데가 없다 (사용자가 고친 초안은 그대로 둔다).
                if let adopted, adopted.mergeHead != mergeHead { mergeDraftAdoptions[folder] = nil }
                return
            }
        }
    }

    /// 앱이 방금 만든 커밋 (프로젝트 폴더 → 커밋 해시). 그 커밋이 HEAD 인 동안 "커밋 완료" 를 보여준다.
    /// 업로드 · 받기 · 브랜치 전환에 성공하면 지운다.
    private(set) var appCommitHashes: [String: String] = [:]

    /// 커밋 메시지 초안. 폴더(경로)별로 **메모리에만** 둔다 — 탭 · 대화를 오가도 남고 앱을 끄면 사라진다.
    /// 같은 프로젝트라도 독립 작업 폴더마다 따로다 — 한 대화에서 쓴 메시지가 다른 폴더의 커밋에 들어가지 않게 (chg-8).
    private(set) var commitDrafts: [String: String] = [:]

    /// 변경사항 탭의 커밋 메시지 칸에 포커스가 있는지. ⌘↵ 를 입력창과 나눠 갖는 데 쓴다
    /// (`ChangesState.returnKeyOwner`).
    var commitFieldFocused = false

    /// ⌘⇧F — 변경사항 탭의 파일 찾기 칸에 포커스를 달라는 요청. 탭이 받으면 false 로 돌린다.
    var changesSearchFocusRequested = false

    /// ⌘⇧N — 변경사항 탭의 브랜치 메뉴를 새 이름 입력 상태로 열어 달라는 요청 (누른 시각). 탭이 받으면 nil 로 돌린다
    /// (탭이 아직 없을 수 있어 알림 대신 모델에 남긴다 — ⌘⇧F 와 같은 방식).
    private(set) var newBranchRequestedAt: Date?

    /// 요청을 받을 수 있는 시간. 창이 닫혀 있을 때 누른 요청이 한참 뒤 탭이 나타날 때 저절로 메뉴를 열지 않게 한다.
    static let newBranchRequestWindow: TimeInterval = 3

    func requestNewBranch(at date: Date = Date()) {
        newBranchRequestedAt = date
    }

    /// 탭이 요청을 받는다. `ready` = 저장소를 읽어 메뉴를 열 수 있음 (아직이면 요청을 남겨 두고 false).
    /// 받을 시간이 지났으면 버리고 false.
    func takeNewBranchRequest(ready: Bool, now: Date = Date()) -> Bool {
        guard let at = newBranchRequestedAt else { return false }
        guard now.timeIntervalSince(at) < Self.newBranchRequestWindow else {
            newBranchRequestedAt = nil
            return false
        }
        guard ready else { return false }
        newBranchRequestedAt = nil
        return true
    }

    func commitDraft(forFolder path: String) -> String {
        commitDrafts[path] ?? ""
    }

    func setCommitDraft(_ text: String, forFolder path: String) {
        commitDrafts[path] = text
    }

    /// 변경사항 탭의 "선택한 변경 커밋". 스테이지된 것(체크한 파일)을 커밋한다.
    /// 성공하면 초안을 비우되, 그 사이 새로 쓴 내용은 지우지 않는다. 실패하면 메시지와 선택을 건드리지 않고
    /// 배너 대신 화면 안에 이유를 남긴다 (`lastGitOutcome`).
    @discardableResult
    func commitStaged(message: String) async -> Bool {
        guard let folder = selectedProject?.path else { return await runGit(.commit(message: message)) }
        let committed = await runGit(.commit(message: message), reportsInline: true)
        if committed, commitDraft(forFolder: folder) == message {
            commitDrafts[folder] = ""
        }
        return committed
    }

    /// git 쓰기를 막는 이유 (`runGit` 의 가드와 같은 기준). **지금 보는 폴더**에서 에이전트가 돌고 있을 때만 막는다 —
    /// 다른 폴더의 실행은 이 폴더의 파일을 건드리지 않는다. nil 이면 쓸 수 있다.
    var gitWriteLock: ChangesState.Lock? {
        let path = selectedProject?.path ?? ""
        let writers = writeSessions(inProjectPath: path)
        let reviewers = reviewLanes.activeSessions.filter { $0.activeProjectPath == path }
        // 다른 폴더의 원격 명령(업로드 · 받기 · 원격 확인)은 몇십 초 걸릴 수 있다 — 그동안 이 폴더의 체크가 왜 안 되는지 밝힌다 (chg-10).
        var elsewhere: (project: String, progress: String)?
        if let running = runningGitOperation, running.talksToRemote, let other = runningGitProjectPath, other != path {
            elsewhere = (folderDisplayName(other), running.progressText)
        }
        return ChangesState.lock(agentRunning: !writers.isEmpty || !reviewers.isEmpty,
                                 agent: writers.last?.activeProvider ?? reviewers.last?.activeProvider,
                                 agentHere: true,
                                 hasUnterminated: !runner.unterminatedProcesses.isEmpty || !reviewLanes.unterminatedProcesses.isEmpty,
                                 gitRunning: runningGitOperation != nil,
                                 runSnapshot: isStartingRun(projectPath: path) || finishingProjectPaths.contains(path),
                                 hasThread: selectedThread != nil,
                                 gitElsewhere: elsewhere,
                                 worktreeCommand: worktreeActivity(threadID: selectedThreadID, path: path)?.kind.koreanName)
    }

    /// 폴더를 사람이 알아볼 이름으로 — 프로젝트 폴더면 프로젝트 이름, 독립 작업 폴더면 "<프로젝트> · <대화 제목>".
    func folderDisplayName(_ path: String) -> String {
        if let project = projects.first(where: { $0.path == path }) { return project.name }
        if let thread = allThreads().first(where: { $0.worktree?.path == path }),
           let project = projects.first(where: { $0.id == thread.projectID }) {
            return project.name + " · " + thread.title
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// 종료가 확인되지 않은 프로세스를 사람이 확인했다 — 대화 실행 · 자동 작업의 검토 레인 둘 다 (git 쓰기 잠금이 둘을 함께 본다, chg-17).
    func acknowledgeUnterminatedProcesses() {
        runner.acknowledgeUnterminated()
        reviewLanes.coordinator.acknowledgeUnterminated()
    }

    /// 종료가 확인되지 않은 프로세스 목록 (대화 실행 + 검토 레인).
    var unterminatedProcessNotes: [String] { runner.unterminatedProcesses + reviewLanes.unterminatedProcesses }

    /// 지금 에이전트가 실행 중인 프로젝트 (가장 최근에 시작한 실행의 것).
    var activeRunProject: Project? {
        // 검토 레인의 대화는 목록에서 빼 둔 내부 대화다.
        guard let id = runner.activeThreadID ?? reviewLanes.activeRuns.first?.threadID,
              let thread = allThreads().first(where: { $0.id == id }) ?? internalThreadsByID[id] else { return nil }
        return folderProject(for: thread)
    }

    /// 자동 작업의 검토단이 검토 레인에서 도는 중이다.
    var isReviewing: Bool { reviewLanes.isBusy }

    /// 이 실행을 지금 돌리고 있는 세션 — 실행 슬롯이든 검토 레인이든. 대화의 "실행 중" 머리글이 쓴다
    /// (검토단의 내부 대화를 열어 두면 검토가 도는 모습이 그대로 보인다). 끝난 실행이면 nil.
    func liveSession(runID: String) -> RunSession? {
        [runner.session(runID: runID), reviewLanes.coordinator.session(runID: runID)].compactMap { $0 }.first(where: \.isBusy)
    }

    /// 이 대화에서 지금 실행이 돌고 있다.
    func isThreadRunning(_ threadID: String) -> Bool {
        runner.isBusy(threadID: threadID) || reviewLanes.coordinator.isBusy(threadID: threadID)
    }

    // MARK: - 칸 머리 · 응답 필요 (판정은 `PaneStatus`)

    /// 칸에 열 수 있는 대화 — 목록의 대화, 없으면 자동 작업의 내부 대화.
    func paneThread(_ id: String) -> ConversationThread? {
        allThreads().first { $0.id == id } ?? internalThreadsByID[id]
    }

    /// 칸 머리가 볼 사실: 도는 실행(쓰기 슬롯이든 검토 레인이든)의 상태 · 승인 · 질문 · 백그라운드 대기 · 같은 폴더의 다른 실행,
    /// 마지막으로 끝난 실행(대화 상자가 있을 때 — 칸에 열린 대화), 자동 작업이 사람을 기다리는지.
    func paneStatusInput(for thread: ConversationThread) -> PaneStatusInput {
        var input = PaneStatusInput()
        let review = reviewLanes.coordinator.session(threadID: thread.id)
        if let session = runner.session(threadID: thread.id) ?? review, session.isBusy {
            input.runState = session.state
            input.reviewing = session === review
            input.pendingApprovals = session.pendingApprovals.count
            input.pendingQuestions = session.pendingQuestions.count
            input.waitingOnBackground = session.isWaitingOnBackground
            input.unfinishedSubAgents = session.unfinishedSubAgentCount
            if !input.reviewing, let path = session.activeProjectPath {
                input.sharesFolder = writeSessions(inProjectPath: path).contains { $0 !== session }
            }
        }
        if let last = threadStates[thread.id]?.runsByID.values.max(by: { $0.startedAt < $1.startedAt }) {
            input.lastRunState = last.state
            input.lastRunEndedAt = last.endedAt
        }
        if let snapshot = orchestrationSnapshot(for: thread), !snapshot.job.state.isTerminal {
            input.orchestration = orchestration.attention(for: snapshot)
        }
        // 인계 카드 — 검토 · 실패(사람이 멈춘 것 제외)는 답을 기다리고, 카운트다운은 보이되 답을 기다리지 않는다.
        if let card = handoffCards[thread.id] {
            // 보내는 중인 카드는 초안이 아니다 — 전달 실행이 시작되기 전 몇 초도 "인계 보내는 중" 으로.
            if card.isSending {
                input.handoffSending = true
            } else {
                switch card.attention {
                case .review: input.handoffReview = true
                case .countdown: input.handoffCountdown = true
                case .draft: input.handoffDraft = true
                }
            }
        } else if handoffPreparations[thread.id] != nil {
            input.handoffPreparing = true
        }
        // 다른 Codex 계정에서 같은 세션을 이어 가려는 카운트다운 — 인계 카드의 카운트다운과 같은 무게 (`CodexAccountSwitch`).
        input.codexSwitchCountdown = codexSwitchCountdowns[thread.id] != nil
        return input
    }

    /// 사람의 답을 기다리는 대화 — 툴바 "응답 필요". 실행의 승인 · 질문과, 불러 둔 자동 작업이 사람을 기다리는 부모 대화.
    /// 포커스 대화는 뺀다 (그 카드가 이미 앞에 있다). 칸에 열린 순서가 먼저.
    var responseNeeded: [ResponseNeeded] {
        var ids: [String] = runner.activeSessions.compactMap { session in
            session.pendingApprovals.isEmpty && session.pendingQuestions.isEmpty ? nil : session.activeThreadID
        }
        ids += orchestration.snapshotsByThread.keys.sorted()
        // 사람이 봐야 하는 인계 카드 (검토 · 실패 · 미확인) — 칸에 없는 대화여도 여기서 보인다.
        ids += handoffCards.filter { $0.value.attention == .review }.keys.sorted()
        var seen = Set<String>()
        let items: [ResponseNeeded] = ids.compactMap { id in
            guard seen.insert(id).inserted,
                  let thread = paneThread(id),
                  let status = PaneStatus.make(paneStatusInput(for: thread)), status.needsResponse else { return nil }
            return ResponseNeeded(threadID: id, title: thread.title, provider: thread.preferredProvider, what: status.text)
        }
        return ResponseNeeded.ordered(items, paneThreadIDs: panes.threadIDs, focusedThreadID: selectedThreadID)
    }

    /// Dock 배지가 세는 대화 — 사이드바 행 단위. 사람의 답을 기다리거나(칸 머리의 `needsResponse`) 스스로 움직일 카운트다운(자동 인계 ·
    /// 다른 계정에서 이어 가기 — `PaneStatusInput.countingDown`)이 도는 대화. 메뉴바 아이콘도 이 목록을 센다.
    /// 툴바 "응답 필요" 와 달리 포커스 대화도 센다(창이 뒤에 있어도 보이는 표시라서). 내부 대화(자동 작업)의 승인은 그 부모 대화로 센다.
    var dockAttentionThreadIDs: [String] {
        var ids: [String] = runner.activeSessions.compactMap { session in
            session.pendingApprovals.isEmpty && session.pendingQuestions.isEmpty ? nil : session.activeThreadID
        }
        ids += orchestration.snapshotsByThread.keys.sorted()
        // 인계 카드 — 검토 · 실패 · 미확인 · 카운트다운 (사람이 멈춘 카드 · 수동 카드는 세지 않는다).
        ids += handoffCards.filter { $0.value.attention != .draft }.keys.sorted()
        // 다른 Codex 계정에서 같은 세션을 이어 가려는 카운트다운 — 인계 카드의 카운트다운과 같다.
        ids += codexSwitchCountdowns.keys.sorted()
        let waiting = ids.filter { id in
            guard let thread = paneThread(id) else { return false }
            let input = paneStatusInput(for: thread)
            return PaneStatus.make(input)?.needsResponse == true || input.countingDown
        }
        return AttentionBadge.rows(
            waiting,
            isInternal: { paneThread($0)?.isInternal == true },
            parentOf: { id in
                guard let jobID = paneThread(id)?.orchestrationJobID else { return nil }
                return orchestration.snapshotsByThread.values.first { $0.job.id == jobID }?.job.parentThreadID
            })
    }

    /// 작업 폴더에 쓰는 git 명령을 실행한다.
    ///
    /// 안전 규칙(인계 게이트와 같은 기준):
    /// - 에이전트가 실행 중이거나 종료가 확인되지 않은 프로세스가 있으면 하지 않는다 (파일 경합).
    /// - 밖으로 나가는 명령(push·pull)은 호출자가 사용자에게 확인을 받은 뒤에만 통과한다.
    /// - 실행한 명령과 출력은 대화에 남겨 인계 문서까지 이어진다.
    ///
    /// `reportsInline` 이면 결과를 배너로 알리지 않는다 — 호출한 화면이 `lastGitOutcome` 으로 직접 보여준다
    /// (배너와 화면 안 표시가 겹치지 않게). 기본값은 지금처럼 배너.
    @discardableResult
    func runGit(_ operation: GitWrite.Operation, confirmed: Bool = false,
                reportsInline: Bool = false) async -> Bool {
        // 막 끝난 실행의 종료 스냅샷을 기다린다 — 그 사이의 커밋 · 받기가 에이전트의 변경(HEAD 바뀜)으로 잡히지 않게.
        guard let project = selectedProject, let thread = selectedThread else {
            banner = BannerMessage(text: "프로젝트와 대화를 먼저 선택하세요.", isError: true)
            return false
        }
        _ = await runChangeFinishing[project.path]?.value
        // 앱의 git 쓰기는 한 번에 하나다. 조용히 끝내지 않고 까닭을 알린다 (chg-9 · chg-10).
        if let running = runningGitOperation {
            let place = runningGitProjectPath == project.path ? "이 폴더" : "다른 프로젝트(\(folderDisplayName(runningGitProjectPath ?? "")))"
            banner = BannerMessage(text: "앱이 \(place)에서 \(running.progressText). 끝난 뒤에 다시 하세요.", isError: true)
            return false
        }
        if let activity = worktreeActivity(threadID: thread.id, path: project.path) {
            banner = BannerMessage(text: "독립 작업 폴더를 \(activity.kind.koreanName) 중입니다. 끝난 뒤에 다시 하세요.", isError: true)
            return false
        }
        // 실행을 시작하는 중(시작 전 스냅샷을 찍는 중)이면 쓰지 않는다 — 곧 에이전트가 같은 폴더에서 돈다.
        guard !isStartingRun(projectPath: project.path) else {
            banner = BannerMessage(
                text: "에이전트 실행을 시작하는 중입니다. 끝난 뒤에 git 명령을 실행하세요.", isError: true)
            return false
        }
        guard writeSessions(inProjectPath: project.path).isEmpty, !isReviewing(inProjectPath: project.path) else {
            banner = BannerMessage(
                text: "에이전트가 실행 중입니다. 끝난 뒤에 git 명령을 실행하세요.", isError: true)
            return false
        }
        let unterminated = runner.unterminatedProcesses + reviewLanes.unterminatedProcesses
        guard unterminated.isEmpty else {
            banner = BannerMessage(
                text: "종료가 확인되지 않은 프로세스가 있어 git 명령을 실행하지 않았습니다:\n"
                    + unterminated.joined(separator: "\n"), isError: true)
            return false
        }
        guard !operation.needsConfirmation || confirmed else {
            banner = BannerMessage(text: "\(operation.koreanName) 전에 확인이 필요합니다.", isError: true)
            return false
        }
        let env = await environment.childEnvironment()
        guard let git = GitInspector.findGit(environment: env) else {
            banner = BannerMessage(text: "git 실행 파일을 찾지 못했습니다.", isError: true)
            return false
        }
        runningGitOperation = operation
        runningGitProjectPath = project.path
        defer {
            runningGitOperation = nil
            runningGitProjectPath = nil
        }
        // 앞선 결과는 새 명령을 시작하면 지운다 (커밋 실패 표시는 그 커밋이 마지막 명령인 동안만).
        if lastGitOutcome?.projectPath == project.path { lastGitOutcome = nil }
        // 이 프로젝트의 git 상태 (폴더를 막 바꿔 아직 읽지 않았으면 nil — 원격을 짐작하지 않는다).
        let gitBefore = workspace.projectPath == project.path ? workspace.git : nil
        // stage · unstage 의 경로는 저장소 루트 기준이라 루트에서 실행한다 (프로젝트가 하위 폴더일 때).
        let repositoryRoot = workspace.projectPath == project.path
            ? workspace.git?.rootPath.map { URL(fileURLWithPath: $0) } : nil
        let directory = GitWrite.workingDirectory(for: operation, project: project.url,
                                                  repositoryRoot: repositoryRoot)
        let outcome = await GitWrite.perform(operation, git: git, at: directory, environment: env)

        // 사람이 한 일도 대화에 남긴다 (provider = nil → 앱이 실행). 체크박스(커밋에 포함 · 빼기)는 남기지 않는다 — 누를 때마다
        // 대화에 명령이 쌓이고, 무엇이 기록됐는지는 커밋이 남긴다 (chg-18). 실패는 화면 · 배너가 알린다.
        if operation.isRecordedInConversation {
            var payload: [String: Any] = ["status": outcome.succeeded ? "completed" : "failed",
                                          "source": "app", "cwd": directory.path]
            // 종료 코드는 git 이 준 값만 남긴다 (시간 초과 · 실행 실패면 없음 — 지어 넣지 않는다).
            if let exitStatus = outcome.exitStatus { payload["exitCode"] = Int(exitStatus) }
            let event = ThreadEvent(threadID: thread.id, kind: .commandExecution, provider: nil,
                                    title: outcome.command,
                                    text: outcome.command
                                        + (outcome.output.isEmpty ? "" : "\n\n--- 출력 ---\n" + outcome.output),
                                    payloadJSON: JSONUtil.line(payload))
            if let saved = try? await store.appendEvent(event) {
                runCoordinator(runner, didUpsert: saved)
            }
        }
        if outcome.succeeded {
            switch operation {
            case .fetch, .pull:
                // "n분 전 확인" 의 기준. 터미널에서 한 fetch 는 FETCH_HEAD 수정 시각으로 따로 잡는다.
                workspace.noteRemoteChecked(path: project.path)
            default:
                break
            }
        }
        await workspace.refreshGit()
        if outcome.succeeded {
            switch operation {
            case .commit:
                // 방금 만든 커밋을 HEAD 에서 직접 읽는다 (refreshGit 이 다른 조회와 겹쳐 늦을 수 있다).
                appCommitHashes[project.path] = await GitWorkspace.headCommit(at: project.url,
                                                                               environment: env)?.hash
            case .push, .pull, .switchBranch, .createBranch:
                appCommitHashes[project.path] = nil
            default:
                break
            }
        }
        // 기준 상태는 명령이 **끝난 뒤** 다시 읽은 것 (시작 전 상태는 앱 밖 터미널에서 바뀌었을 수 있다).
        let gitAfter = workspace.projectPath == project.path ? workspace.git : nil
        var record = GitOutcomeRecord(operation: operation, outcome: outcome,
                                      projectPath: project.path, finishedAt: Date(),
                                      context: gitAfter.map(ChangesState.syncContext),
                                      contextBefore: gitBefore.map(ChangesState.syncContext))
        // 원격에서 실패했으면 그 원격 주소를 읽어 둔다 (로그인 실패 문구에서 GitHub 인지 가릴 때만 쓴다. 읽기 전용).
        // 맨 업로드는 pushRemote · remote.pushDefault 가 있으면 그 원격으로 가고, 올릴 때의 주소는 pushurl 이다.
        if !outcome.succeeded, operation.talksToRemote {
            let status = gitAfter ?? gitBefore
            var pushRemote: String?
            // 맨 `git push` 는 그때의 현재 브랜치 설정을 따른다 (다시 읽은 브랜치가 있으면 그것으로).
            if case .push(let branch, false) = operation {
                let current = status?.branch ?? branch
                if !current.isEmpty {
                    pushRemote = await GitWorkspace.pushRemote(branch: current, at: project.url, environment: env)
                }
            }
            if let name = GitWorkspace.remoteName(for: operation, upstream: status?.upstream,
                                                  remotes: status?.remotes, pushRemote: pushRemote) {
                record.remoteName = name
                record.remoteURL = await GitWorkspace.remoteURL(named: name, push: operation.isPush,
                                                                at: project.url, environment: env)
            }
        }
        if !outcome.succeeded {
            record.failure = GitFailure.classify(operation, output: outcome.output, remoteURL: record.remoteURL)
        }
        lastGitOutcome = record
        if !outcome.succeeded {
            // 화면 안에 보여줄 자리가 없으면 (상태를 못 읽음 · 병합이나 rebase 중이라 동기화 자리가 없음) 배너로.
            // 그 자리가 없는데 배너까지 막으면 실패가 아무 데도 보이지 않는다.
            let inlinePlace = operation.talksToRemote
                ? ChangesState.showsSyncFailureInline(gitAfter)
                : (gitAfter.map { $0.isRepository && $0.error == nil } ?? false)
            if !reportsInline || !inlinePlace {
                banner = BannerMessage(
                    text: GitFailure.failedTitle(operation) + ": "
                        + JSONUtil.truncate(outcome.output.isEmpty ? outcome.command : outcome.output, max: 400),
                    isError: true)
            }
        } else if case .commit = operation, !reportsInline {
            banner = BannerMessage(text: "커밋했습니다.", isError: false)
        }
        return outcome.succeeded
    }

    /// 저장소가 아닌 포커스 대화의 폴더에서 git 기록을 시작한다 (변경사항 탭의 [이 폴더에서 git 시작하기] — 확인 뒤, chg-23).
    /// 그 폴더에서 에이전트가 돌거나 앱의 다른 git 명령이 돌면 하지 않는다. 첫 커밋은 하지 않는다. 명령은 대화에 남긴다.
    @discardableResult
    func initializeRepository() async -> Bool {
        guard let project = selectedProject, let thread = selectedThread else {
            banner = BannerMessage(text: "프로젝트와 대화를 먼저 선택하세요.", isError: true)
            return false
        }
        guard workspace.git.map({ !$0.isRepository && $0.error == nil }) == true else { return false }
        if runningGitOperation != nil || worktreeActivity(threadID: thread.id, path: project.path) != nil
            || !writeSessions(inProjectPath: project.path).isEmpty || isStartingRun(projectPath: project.path) {
            banner = BannerMessage(text: "이 폴더에서 에이전트 실행이나 git 명령이 도는 중이라 git 을 시작하지 않았습니다. 끝난 뒤에 다시 하세요.",
                                   isError: true, threadID: thread.id)
            return false
        }
        let env = await environment.childEnvironment()
        guard let git = GitInspector.findGit(environment: env) else {
            banner = BannerMessage(text: "git 실행 파일을 찾지 못했습니다.", isError: true, threadID: thread.id)
            return false
        }
        let outcome = await GitWrite.initRepository(git: git, at: project.url, environment: env)
        var payload: [String: Any] = ["status": outcome.succeeded ? "completed" : "failed", "source": "app", "cwd": project.path]
        if let exitStatus = outcome.exitStatus { payload["exitCode"] = Int(exitStatus) }
        let event = ThreadEvent(threadID: thread.id, kind: .commandExecution, provider: nil, title: outcome.command,
                                text: outcome.command + (outcome.output.isEmpty ? "" : "\n\n--- 출력 ---\n" + outcome.output),
                                payloadJSON: JSONUtil.line(payload))
        if let saved = try? await store.appendEvent(event) { runCoordinator(runner, didUpsert: saved) }
        await workspace.refreshGit()
        banner = outcome.succeeded
            ? BannerMessage(text: "이 폴더에서 git 기록을 시작했습니다. 커밋할 파일을 골라 첫 커밋을 만드세요.", isError: false, threadID: thread.id)
            : BannerMessage(text: "git 을 시작하지 못했습니다: " + JSONUtil.truncate(outcome.output, max: 300), isError: true,
                            threadID: thread.id)
        return outcome.succeeded
    }

    // MARK: - 평가

    // 평가는 그 실행 · 인계가 보이는 칸의 대화에 적는다 (포커스 대화가 아닐 수 있다).

    private func state(showingRun runID: String) -> ThreadPaneModel? {
        threadStates.values.first { $0.runsByID[runID] != nil } ?? focusedState
    }

    func setRating(runID: String, provider: AgentProvider, satisfaction: Satisfaction?) async {
        guard let state = state(showingRun: runID) else { return }
        var r = state.ratingsByRun[runID] ?? Rating(threadID: state.threadID, runID: runID, provider: provider)
        r.satisfaction = (r.satisfaction == satisfaction) ? nil : satisfaction
        r.updatedAt = Date()
        try? await store.upsertRating(r)
        state.ratingsByRun[runID] = r
    }

    func toggleRescue(runID: String, provider: AgentProvider) async {
        guard let state = state(showingRun: runID) else { return }
        var r = state.ratingsByRun[runID] ?? Rating(threadID: state.threadID, runID: runID, provider: provider)
        r.rescue.toggle()
        r.updatedAt = Date()
        try? await store.upsertRating(r)
        state.ratingsByRun[runID] = r
    }

    func setHandoffQuality(handoffID: String, provider: AgentProvider, quality: HandoffQuality?) async {
        guard let state = threadStates.values.first(where: { $0.handoffs.contains { $0.id == handoffID } }) ?? focusedState else { return }
        var r = state.ratingsByHandoff[handoffID]
            ?? Rating(threadID: state.threadID, handoffID: handoffID, provider: provider)
        r.handoffQuality = (r.handoffQuality == quality) ? nil : quality
        r.updatedAt = Date()
        try? await store.upsertRating(r)
        state.ratingsByHandoff[handoffID] = r
    }

    // MARK: - 집계

    var threadUsageAggregate: UsageAggregate {
        UsageAggregate.from(Array(usageByRun.values))
    }

    /// 스레드에서 사용량 기록이 없는 실행 수 (누락 표시용).
    var missingUsageTurns: Int {
        runsByID.values.filter { $0.state.isTerminal && usageByRun[$0.id] == nil }.count
    }

    // MARK: - RunCoordinatorDelegate

    func runCoordinator(_ c: RunCoordinator, didUpsert event: ThreadEvent) {
        // 그 대화가 화면에 열려 있으면 그 상자로. 열려 있지 않으면 저장소에만 있고, 열 때 읽는다.
        threadStates[event.threadID]?.upsert(event)
        // 실행이 파일을 바꾸면 그 폴더의 변경 목록을 실행 중에도 다시 읽는다 (H8 — 검토 레인은 파일을 바꾸지 않는다).
        if c === runner { scheduleLiveGitRefresh(after: event) }
    }

    /// 실행 중 다시 읽기 (H8): 에이전트가 파일을 바꾼 기록(`ChangesState.refreshesGitDuringRun`)이 오면 그 대화의 폴더를 잠시 뒤
    /// 한 번 다시 읽는다 — 그 사이 온 기록은 그 한 번에 담긴다 (폴더마다 하나). 화면에 열린 폴더만. git 조회는 잠금을 잡지 않는다
    /// (`GitWorkspace` — `--no-optional-locks`) — 에이전트가 같은 저장소에서 git 을 써도 방해하지 않는다.
    private func scheduleLiveGitRefresh(after event: ThreadEvent) {
        guard ChangesState.refreshesGitDuringRun(event), let path = projectPath(ofThread: event.threadID),
              workspaces[path] != nil, liveGitRefreshes[path] == nil else { return }
        liveGitRefreshes[path] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(ChangesState.liveRefreshDelay))
            guard let self else { return }
            self.liveGitRefreshes[path] = nil
            await self.workspace(forPath: path)?.refreshGit()
        }
    }

    func runCoordinator(_ c: RunCoordinator, didChangeState state: RunState, run: Run?) {
        if let run { threadStates[run.threadID]?.record(run: run) }
        guard c === runner else { return }   // 검토 레인의 실행은 파일을 바꾸지 않는다 — 실행 전후 비교가 없다.
        if state == .starting, let run { bindRunChangeTracking(to: run) }
    }

    func runCoordinator(_ c: RunCoordinator, didReceive snapshot: LimitSnapshot) {
        limits.apply(snapshot)
    }

    func runCoordinator(_ c: RunCoordinator, didFinish run: Run,
                        result: AgentTurnResult, usage: UsageRecord?) {
        threadStates[run.threadID]?.record(run: run)
        if let usage { threadStates[run.threadID]?.record(usage: usage) }
        guard c === runner else { return reviewLaneDidFinish(run: run, result: result) }
        noteRunOutcomeForMenuBar(run)
        // 오케스트레이션이 보낸 실행인지는 지금 확인한다 (아래 Task 가 돌 때는 이미 넘겨져 기록이 지워져 있다).
        // 그 실행의 한도 도달은 오케스트레이션이 처리한다 — 기존 자동 인계가 같은 실행을 또 처리하면 이중 전송이 된다.
        let ownedByOrchestration = orchestration.owns(runID: run.id)
        let settled = settleRunChanges(run)
        // 첫 턴이 끝난 대화의 제목을 짧게 요약한다 — 대기열 · 자동 인계와 상관없이 뒤에서 (`summarizeTitleIfNeeded`).
        if !ownedByOrchestration, !run.isHandoffDelivery, result.state == .completed {
            Task { await summarizeTitleIfNeeded(after: run) }
        }
        Task {
            await settled.value
            // 인계 전달 실행이면 전달 상태로 가른다 — 대기열을 잇기 전에 (전달됨이면 칩이 받는 쪽으로 옮겨 가고 보류가 풀린다).
            if run.isHandoffDelivery { await resolveDelivery(run: run) }
            // 적절한 실행 종료 시점에만 한도를 갱신한다 (과도한 폴링 금지).
            await limits.refresh(AgentScope(provider: run.provider,
                                            accountID: run.codexAccountID ?? ""))
            if ownedByOrchestration {
                await orchestration.runDidFinish(run: run, result: result)
            } else if result.state == .rateLimited, automaticHandoffEnabled,
                      !run.isHandoffDelivery, !hasHandoffActivity(threadID: run.threadID) {
                await startAutomaticHandoff(after: run)
            }
            // 실행 중에 걸어 둔 메시지: 정상으로 끝났으면 다음 것을 보내고, 아니면 멈춘다 (자동 작업의 실행은 대상이 아니다).
            // 실행 슬롯을 비우기 전이다 — 사람이 걸어 둔 메시지가 기다리던 자동 작업보다 먼저 간다.
            if !ownedByOrchestration { await continueQueue(after: run, state: result.state) }
            // 어떤 실행이든 끝나면 실행 슬롯이 빈다. 기다리던 자동 작업이 이어 간다.
            await orchestration.runSlotBecameIdle()
        }
    }

    /// 끝난 쓰기 실행의 폴더 쪽 뒷정리. 실행 전후 비교는 무엇보다 먼저 곧바로 줄 세운다 (프로세스가 막 끝난 폴더 그대로) —
    /// 같은 폴더의 다음 실행의 시작 전 스냅샷 · 인계 초안 · 앱의 git 쓰기는 이것을 기다린다.
    /// 돌려준 작업은 비교를 기다려 대화 기록과 작업 폴더 상태를 다시 읽는다.
    private func settleRunChanges(_ run: Run) -> Task<Void, Never> {
        let trackedPath = trackedProjectPath(runID: run.id)
        let finishing = Task { await finishRunChangeTracking(run) }
        if let trackedPath {
            runChangeFinishing[trackedPath] = finishing
            finishingProjectPaths.insert(trackedPath)
        }
        return Task {
            let finished = await finishing.value
            if let trackedPath, runChangeFinishing[trackedPath] == finishing {
                runChangeFinishing[trackedPath] = nil
                finishingProjectPaths.remove(trackedPath)
            }
            await reloadThreadData(threadID: run.threadID)
            // 에이전트가 파일을 바꿨을 수 있으니 작업 폴더 상태를 다시 읽는다. 종료 스냅샷이 방금 지금 보는 폴더를
            // 읽었으면 그 상태를 그대로 쓴다 (같은 git 조회를 곧바로 두 번 돌리지 않게).
            // 그 실행이 돈 폴더가 화면에 열려 있을 때만 (열려 있지 않으면 열 때 읽는다).
            let runPath = finished?.path ?? trackedPath ?? projectPath(ofThread: run.threadID)
            if let runWorkspace = workspace(forPath: runPath) {
                if let finished, runWorkspace.adoptGitStatus(finished.status, path: finished.path) {
                    // 종료 스냅샷의 상태를 썼다.
                } else {
                    await runWorkspace.refreshGit()
                }
            }
        }
    }

    /// 끝난 실행이 오류 · 한도 · 전달 미확인이면 메뉴바 "확인 필요" 에 그 대화를 적는다 — 그 대화를 보고 있으면(포커스) 적지 않는다.
    /// 같은 대화의 다음 실행이 끝나면 앞의 것은 지운다. 자동 작업의 내부 대화는 작업 카드가 알린다.
    private func noteRunOutcomeForMenuBar(_ run: Run) {
        unseenRunProblems.removeAll { $0.threadID == run.threadID }
        guard MenuBarStatus.isProblem(run.state), run.threadID != selectedThreadID,
              let thread = paneThread(run.threadID), !thread.isInternal else { return }
        unseenRunProblems.append(MenuBarStatus.UnseenRun(threadID: run.threadID, title: thread.title, state: run.state))
    }

    /// 검토 레인의 실행이 끝났다. 읽기 전용이라 실행 전후 비교 · git 새로고침 · 자동 인계가 없다.
    /// 결과는 자동 작업에 넘기고, 모든 레인이 비면 기다리던 쓰기 실행이 이어 간다.
    private func reviewLaneDidFinish(run: Run, result: AgentTurnResult) {
        Task {
            await reloadThreadData(threadID: run.threadID)
            await limits.refresh(AgentScope(provider: run.provider, accountID: run.codexAccountID ?? ""))
            await orchestration.runDidFinish(run: run, result: result)
            await orchestration.runSlotBecameIdle()
        }
    }

    /// 앱 종료로 끝낸 실행. 완료 통지가 오지 않으므로 적어 두었다가, 종료가 취소되면 `reconcileCancelledQuit` 이 뒷정리한다.
    /// 종료가 이어지면 앱이 끝나므로 아무것도 하지 않는다.
    func runCoordinator(_ c: RunCoordinator, didQuit run: Run) {
        quitRuns.append((run, c === runner))
    }

    /// 종료가 이어진다 (`shutDownAndTerminate` — 실행을 거둔 뒤, DB 를 닫기 전). 앱 종료로 끊긴 인계 전달 중 전달됨으로 판정된 것은
    /// 칩을 받는 쪽으로 옮기고 보류를 푼다 — 다시 켜면 다음 메시지가 인계를 받은 쪽에게 가고, 걸어 둔 메시지는 "다시 켜서 멈춤" 이다
    /// (카드가 사라졌다고 적지 않는다). 실패 · 미확인은 보류를 남긴다. 보류 표시는 여기서 기다려 쓴다 (곧 DB 를 닫는다).
    func recordQuitDeliveriesBeforeExit() async {
        for entry in quitRuns where entry.writer && entry.run.isHandoffDelivery {
            await resolveDelivery(run: entry.run)
        }
        try? await store.setSetting("message_queue_holds", Self.jsonString(queueHolds.keys.sorted()))
    }

    /// 사용자가 두 번째 경고에서 앱 종료를 취소했다. 앱 종료로 끝낸 실행들은 끝났지만 완료 통지를 받지 못했다 — 실행 전후 비교를
    /// 맺고(남겨 두면 같은 폴더의 다음 실행이 늘 "겹침"이 된다), 대화 기록을 다시 읽고, 자동 작업에 끝났다고 알린다
    /// (**새 일은 시작하지 않는다** — `OrchestrationCoordinator.runEndedByQuit`). 마지막에 실행 슬롯이 빈 것을 한 번 알린다.
    /// 실행 전후 비교는 여기서 곧바로 줄 세운다 (그 사이 같은 폴더에 보낸 실행이 기다리게). 돌려준 작업이 끝나면 뒷정리도 끝났다.
    @discardableResult
    func reconcileCancelledQuit() -> Task<Void, Never>? {
        let quit = quitRuns
        quitRuns = []
        guard !quit.isEmpty else { return nil }
        let settling = quit.map { $0.writer ? settleRunChanges($0.run) : nil }
        return Task {
            for (entry, settled) in zip(quit, settling) {
                if let settled { await settled.value } else { await reloadThreadData(threadID: entry.run.threadID) }
                // 앱 종료로 끊긴 인계 전달 — 전달됨이면 칩을 옮기되 대기열은 멈추고, 실패 · 미확인이면 카드를 되살린다.
                if entry.writer { await resolveQuitDelivery(run: entry.run) }
                await orchestration.runEndedByQuit(run: entry.run)
            }
            await orchestration.runSlotBecameIdle()
        }
    }

    func runCoordinator(_ c: RunCoordinator, needsAttention title: String, body: String,
                        threadID: String, kind: AttentionKind) {
        guard c === runner else { return }   // 검토 실행은 알리지 않는다. 결과는 작업 카드에 모인다.
        // 누가 멈춘 실행(⌘. · 중단 단추 · 메뉴바 · 자동 작업의 멈춤)은 알리지 않는다 — 멈춘 사람이 이미 안다 (nav-6).
        // 앱이 앞에 있고 그 대화가 칸에 보이면 서비스가 거른다 (`NotificationGate`).
        if kind == .runFinished, let session = runner.session(threadID: threadID),
           session.interruptRequested, session.state == .cancelled { return }
        let category: NotificationService.Category
        switch kind {
        case .runFinished: category = .runFinished
        case .approvalNeeded: category = .approvalNeeded
        case .limitReached: category = .limitReached
        }
        notifications.post(category: category, title: title, body: body, threadID: threadID)
    }
}

