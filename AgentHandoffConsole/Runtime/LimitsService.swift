import Foundation

/// Claude / Codex 한도 상태를 한 곳에서 관리한다.
/// 메인 창과 메뉴바가 같은 상태를 공유하며, 각각 별도 조회 루프를 만들지 않는다.
///
/// Codex 한도는 **계정마다 따로**다. 계정을 번갈아 쓰는 것이 이 앱의 목적이므로
/// 등록된 계정 전부의 한도를 나란히 들고 있는다.
@MainActor
@Observable
final class LimitsService {
    private(set) var claude = LimitSnapshot(provider: .claude)
    /// Antigravity — `agy -p /usage` 로 읽는다 (`LimitsFetcher.fetchAntigravity`). 창은 모델 묶음(Gemini · Claude · GPT)마다 따로다.
    /// 읽지 않았으면 "정보 없음"(0% 로 보이지 않게).
    private(set) var gemini = LimitSnapshot(provider: .gemini)
    /// 계정 ID → 한도. 조회하지 않은 계정은 항목이 없다 (0% 가 아니라 "정보 없음").
    private(set) var codexByAccount: [String: LimitSnapshot] = [:]
    private(set) var isRefreshing: Set<AgentScope> = []

    /// 등록된 Codex 계정. `CODEX_HOME` 을 알아야 계정별 조회를 할 수 있다.
    private(set) var codexAccounts: [CodexAccountRef] = []

    private let environment: CLIEnvironment
    private var lastFetch: [AgentScope: Date] = [:]

    /// 검증 하네스용: 실제 CLI(`claude -p /usage` · Codex rate limit) 대신 이 함수로 한도를 읽는다. 앱은 넣지 않는다.
    /// 오프라인 시험이 앱 모델을 돌리면 실행이 끝날 때마다 한도를 새로 읽는다 — 넣지 않으면 실제 계정의 한도에 따라
    /// 결과가 달라졌다 (2026-10-01: 실제 Claude 가 한도에 닿은 동안 자동 작업 시험 18개가 "대상도 한도" 로 실패).
    static var fetchOverride: (@MainActor (AgentScope) async -> LimitSnapshot)?
    /// Codex 한도를 읽을 때 같은 app-server 에 물은 계정(`account/read` — 이메일 · 플랜)을 받는 곳. 앱은 계정 목록에 넣는다
    /// (`CodexAccountService.applyAccountRead`). 받지 못한 조회에서는 부르지 않는다.
    var codexAccountRead: (@MainActor (String, CodexAccountInspector.AccountRead) async -> Void)?
    /// 과도한 폴링을 하지 않는다. 최소 간격.
    private let minInterval: TimeInterval = 60

    init(environment: CLIEnvironment) {
        self.environment = environment
    }

    /// 계정 목록이 바뀌면 알려준다. 사라진 계정의 스냅샷은 버린다.
    func setCodexAccounts(_ refs: [CodexAccountRef]) {
        codexAccounts = refs
        let live = Set(refs.map { $0.id })
        codexByAccount = codexByAccount.filter { live.contains($0.key) }
        lastFetch = lastFetch.filter { $0.key.provider == .claude || live.contains($0.key.accountID) }
    }

    func account(_ id: String) -> CodexAccountRef? {
        codexAccounts.first { $0.id == id }
    }

    /// 조회한 적이 없으면 빈 스냅샷을 돌려준다 (status = .noData).
    func codex(_ accountID: String) -> LimitSnapshot {
        codexByAccount[accountID]
            ?? LimitSnapshot(provider: .codex, accountID: accountID)
    }

    func snapshot(_ scope: AgentScope) -> LimitSnapshot {
        switch scope.provider {
        case .claude: return claude
        case .gemini: return gemini
        case .codex: return codex(scope.accountID)
        }
    }

    /// 화면에 나란히 보여줄 스냅샷 전부 (Claude + 등록된 Codex 계정 순서대로 + 읽어도 되면 Antigravity).
    var allSnapshots: [LimitSnapshot] {
        [claude] + codexAccounts.map { codex($0.id) } + (antigravityEnabled ? [gemini] : [])
    }

    /// 실행 중 수신한 구조화 한도 정보를 반영한다 (가장 신선한 출처).
    func apply(_ snapshot: LimitSnapshot) {
        guard snapshot.hasUsableData || snapshot.status != .noData else { return }
        store(snapshot)
        lastFetch[snapshot.scope] = snapshot.fetchedAt ?? Date()
    }

    /// 첫 프로젝트가 생길 때까지 Claude 조회(`claude -p /usage` — 세션 · 훅 · MCP 가 뜬다)를 미뤘다 (`AppModel.deferredClaudeStartup` 이
    /// 맞춘다). 그동안 `refreshAll`(한도 칩 · 메뉴바 · 보기 메뉴의 새로고침)은 Claude 를 건너뛴다 — 폴더를 고르기도 전에 권한 창이
    /// 뜨지 않게 (onb-9). 화면은 "첫 프로젝트를 연 뒤에 확인합니다" 로 보인다.
    var claudeDeferred = false

    /// Antigravity 한도를 읽어도 되는가 — Antigravity 를 허용한 프로젝트가 있을 때만 (`AppModel.antigravityAllowedProjectIDs` 가 맞춘다).
    /// `agy -p /usage` 도 Google 과 통신하므로 `agy models` 와 같은 원칙(set-20)이다: 쓰지 않는 사람에게는 부르지 않는다.
    /// 꺼져 있으면 `refresh(.gemini)` 는 아무것도 하지 않고, 칩 · 팝오버 · 메뉴바에도 Antigravity 줄이 없다.
    var antigravityEnabled = false

    func refreshAll(force: Bool = false) async {
        let includesClaude = !claudeDeferred
        let includesAntigravity = antigravityEnabled
        await withTaskGroup(of: Void.self) { group in
            if includesClaude { group.addTask { [weak self] in await self?.refresh(.claude, force: force) } }
            for account in codexAccounts {
                group.addTask { [weak self] in await self?.refresh(.codex(account.id), force: force) }
            }
            if includesAntigravity { group.addTask { [weak self] in await self?.refresh(.gemini, force: force) } }
        }
    }

    /// 등록된 Codex 계정 전부의 한도를 갱신한다. 계정 전환 판단에 쓰는 값이라 함께 본다.
    func refreshAllCodex(force: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for account in codexAccounts {
                group.addTask { [weak self] in await self?.refresh(.codex(account.id), force: force) }
            }
        }
    }

    func refresh(_ scope: AgentScope, force: Bool = false) async {
        if scope.provider == .gemini, !antigravityEnabled { return }
        if !force, let last = lastFetch[scope], Date().timeIntervalSince(last) < minInterval {
            return
        }
        // 같은 범위를 조회하는 중이면 새로 부르지 않고 그 결과를 기다린다 — 두 대화가 함께 한도에 닿아 자동 인계 둘이 동시에
        // 강제 조회할 때, 뒤의 것이 옛 값으로 대상을 고르거나 게이트를 통과하지 않게.
        if let running = inFlight[scope] {
            await running.value
            return
        }
        let task = Task { await self.fetch(scope) }
        inFlight[scope] = task
        await task.value
        inFlight[scope] = nil
    }

    private var inFlight: [AgentScope: Task<Void, Never>] = [:]

    private func fetch(_ scope: AgentScope) async {
        guard !isRefreshing.contains(scope) else { return }

        // Codex 는 어느 홈을 볼지 알아야 조회할 수 있다.
        var codexAccount: CodexAccountRef?
        if scope.provider == .codex {
            guard let found = account(scope.accountID) else {
                var snap = LimitSnapshot(provider: .codex, accountID: scope.accountID)
                snap.status = .noData
                snap.fetchedAt = Date()
                snap.message = "등록되지 않은 Codex 계정입니다."
                store(snap)
                return
            }
            codexAccount = found
        }

        if let override = Self.fetchOverride {
            store(await override(scope))
            lastFetch[scope] = Date()
            return
        }

        isRefreshing.insert(scope)
        defer { isRefreshing.remove(scope) }

        let status = await environment.checkStatus(scope.provider)
        guard let path = status.resolvedPath else {
            var snap = LimitSnapshot(provider: scope.provider, accountID: scope.accountID)
            snap.status = .noData
            snap.fetchedAt = Date()
            snap.message = status.error ?? "CLI 경로를 찾지 못했습니다."
            store(snap)
            lastFetch[scope] = Date()
            return
        }

        let snapshot: LimitSnapshot
        switch scope.provider {
        case .claude:
            let env = await environment.childEnvironment()
            snapshot = await LimitsFetcher.fetchClaude(path: path, environment: env)
        case .codex:
            let env = await environment.childEnvironment(codexHome: codexAccount?.homePath)
            let fetched = await LimitsFetcher.fetchCodexWithAccount(path: path, environment: env,
                                                                    accountID: scope.accountID)
            snapshot = fetched.limits
            if let account = fetched.account { await codexAccountRead?(scope.accountID, account) }
        case .gemini:
            // `agy -p /usage --output-format json` (모델을 부르지 않는다). 읽기만 한다 — Antigravity 는 아직 자동 인계 ·
            // 이어 가기 대상이 아니다 (사용자 결정 2026-10-09: v0.1 은 보이기만).
            let env = await environment.childEnvironment()
            snapshot = await LimitsFetcher.fetchAntigravity(path: path, environment: env)
        }
        store(mergedAfterRefresh(snapshot))
        lastFetch[scope] = Date()
    }

    /// 새 조회가 값을 읽지 못했을 때, 최근에 받은 실제 값을 "정보 없음"으로 덮지 않는 기간.
    static let keepPreviousFor: TimeInterval = 30 * 60

    /// 조회 결과를 저장할 값으로 바꾼다.
    ///
    /// 실측(2026-09-12, Claude Code 2.1.233): 헤드리스 `/usage` 가 구독 한도 대신 세션 비용만 돌려줘
    /// 형식을 인식하지 못한다. 이때 실행 중 스트림으로 받은 실제 한도까지 지우면 화면과
    /// 자동 인계 대상 선택이 늘 "정보 없음"이 된다. 그래서 **읽지 못한 경우에만**,
    /// 30분 안에 받은 실제 값을 유지하고 그 사실을 문구로 남긴다.
    /// 한도 도달·인증 문제처럼 새로 알게 된 사실은 그대로 반영한다.
    func mergedAfterRefresh(_ fresh: LimitSnapshot) -> LimitSnapshot {
        guard fresh.status == .noData, !fresh.hasUsableData else { return fresh }
        let previous = snapshot(fresh.scope)
        guard previous.hasUsableData, let at = previous.fetchedAt,
              Date().timeIntervalSince(at) < Self.keepPreviousFor else { return fresh }
        var kept = previous
        let minutes = max(0, Int(Date().timeIntervalSince(at) / 60))
        kept.message = "새 조회에서 한도를 읽지 못해 \(minutes)분 전에 받은 값을 표시합니다."
        return kept
    }

    private func store(_ snapshot: LimitSnapshot) {
        switch snapshot.provider {
        case .claude: claude = snapshot
        case .codex: codexByAccount[snapshot.accountID] = snapshot
        case .gemini: gemini = snapshot
        }
    }
}
