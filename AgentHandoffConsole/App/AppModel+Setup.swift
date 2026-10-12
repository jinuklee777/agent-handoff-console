import Foundation

// 첫 실행 점검표의 사실 모으기.
// 판정은 `FirstRunChecklist`(순수), 화면은 `UI/FirstRunView.swift`. 사실은 기존 상태에 쓴다 — CLI 상태는 `cliStatus`(새 대화의
// `initialAgent` 도 읽는다), Codex 계정은 `accounts`, 알림은 `notifications` — 출처를 하나로 둔다.
// 화면 확인용 실행(`AHC_OFFLINE`)은 실제 CLI · 알림 권한을 묻지 않고 `-preview.firstRun` 의 사실을 쓴다 (`previewFirstRunFacts`).
extension AppModel {

    // MARK: 사실 → 판정

    /// 프로젝트가 없을 때(읽기 성공 뒤) 가운데 칸 전체에 점검표를 세운다. 저장소를 열지 못했으면 그 화면이 먼저다.
    var showsFirstRun: Bool {
        projectsLoaded && projects.isEmpty && bootstrapError == nil
    }

    var firstRunFacts: FirstRunFacts {
        #if DEBUG
        if var preview = previewFirstRunFacts {
            preview.projectCount = projects.count
            return preview
        }
        #endif
        var facts = FirstRunFacts()
        for provider in AgentProvider.allCases {
            var agent = FirstRunFacts.Agent(readiness: agentReadiness(provider))
            agent.version = cliStatus[provider]?.version
            agent.path = cliStatus[provider]?.resolvedPath ?? (agent.readiness == .pathInvalid ? pathOverride(provider) : nil)
            if provider == .codex { agent.accountID = codexReadiness().accountID }
            // 찾았지만 돌지 않았다 (`--version` 실패) — 그 까닭을 그대로 보인다 (onb-2).
            if let status = cliStatus[provider], status.resolvedPath != nil, !status.executable { agent.runError = status.error }
            switch provider {
            case .claude: facts.claude = agent
            case .codex: facts.codex = agent
            case .gemini: facts.antigravity = agent
            }
        }
        facts.notifications = notifications.permission
        facts.badgesEnabled = notifications.badgesEnabled
        facts.git = gitTools
        facts.projectCount = projects.count
        facts.shell = shellRead
        facts.claudeAlternativeAuth = claudeAlternativeAuth
        facts.withheldAuth = forwardShellAuth ? [] : shellAuthVariables
        return facts
    }

    var firstRunChecklist: FirstRunChecklist { FirstRunChecklist(firstRunFacts) }

    /// 설정 > 에이전트(실행 파일)에서 지정한 경로 (없으면 nil).
    func pathOverride(_ provider: AgentProvider) -> String? {
        let value: String
        switch provider {
        case .claude: value = claudePathOverride
        case .codex: value = codexPathOverride
        case .gemini: value = geminiPathOverride
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 실제 사실에서 본 준비 상태 (화면 확인용 사실은 보지 않는다 — `firstRunFacts` 가 덮는다).
    func agentReadiness(_ provider: AgentProvider) -> AgentReadiness {
        guard let status = cliStatus[provider] else { return .checking }
        // 지정한 경로를 실행할 수 없으면 앱은 다른 곳을 찾지 않는다 — "설치 안 됨" 이 아니라 설정의 경로가 원인이다.
        // 찾은 실행 파일이 돌지 않아도(`--version` 실패 — node 를 못 찾음 등) 설치 안내가 아니라 경로를 지정 · 고칠 일이다.
        guard status.isUsable else {
            let found: Bool = status.resolvedPath != nil
            let pinned: Bool = pathOverride(provider) != nil
            return found || pinned ? AgentReadiness.pathInvalid : AgentReadiness.notInstalled
        }
        switch provider {
        case .claude:
            guard let login = claudeLogin else { return .checking }
            switch login.loggedIn {
            case true?: return .ready
            // API 키 · Bedrock · Vertex 로 쓰면 로그인하지 않아도 된다 — "로그인 필요" 라고 단정하지 않는다 (onb-3).
            case false?: return claudeAlternativeAuth ? .loginUnknown : .notLoggedIn
            case nil: return .loginUnknown
            }
        case .codex:
            return codexReadiness().readiness
        case .gemini:
            // Antigravity 는 실행 파일만 본다 (`agy models` 는 네트워크를 쓸 수 있어 부르지 않는다) — 로그인은 모른다.
            return .loginUnknown
        }
    }

    /// Codex 계정들의 로그인 (auth.json · config.toml 의 자격 저장소). 기본 계정이 먼저다 (`accounts` 의 순서).
    func codexReadiness() -> (readiness: AgentReadiness, accountID: String?) {
        let rows = accounts.accounts.map { account in
            (id: account.id, readiness: CodexLoginJudge.readiness(status: account.authStatus,
                                                                  nonFileStore: codexNonFileStores[account.id] ?? false))
        }
        return CodexLoginJudge.combined(rows)
    }

    /// Codex 계정 하나의 로그인 판정 — 점검표와 같은 규칙 (`CodexLoginJudge.readiness` — config.toml 의 자격 저장소가 파일이 아니면
    /// auth.json 이 없어도 "모름"). 인계 카드의 받는 쪽 사실 · 칩 메뉴의 막은 까닭이 이것을 쓴다.
    func codexLoginReadiness(accountID: String) -> AgentReadiness {
        let account = accounts.accountOrDefault(accountID)
        return CodexLoginJudge.readiness(status: account.authStatus, nonFileStore: codexNonFileStores[account.id] ?? false)
    }

    /// 카드에 남길 로그인 사실 — 확인됨 true · 안 됨이 확인됨 false · 모름 nil (`HandoffCardText.loginFact`).
    func codexLoginFact(accountID: String) -> Bool? {
        switch codexLoginReadiness(accountID: accountID) {
        case .ready: return true
        case .notLoggedIn: return false
        default: return nil
        }
    }

    // MARK: 사실 모으기

    /// Claude · Codex(+ Antigravity 실행 파일)를 **함께** 확인해 `cliStatus` · `claudeLogin` · Codex 계정 · Git 에 쓴다.
    /// 부트스트랩 · 설정 > 에이전트 · 점검표의 "다시 확인" · 앱이 다시 앞에 올 때가 모두 이 길이다 (두 갈래로 돌지 않게).
    /// `force` 면 캐시(CLI 상태 300초 · Claude 로그인 300초)를 무시한다. `only` 를 주면 그 제공자만 강제한다 (나머지는 캐시).
    /// 검증 기록(`cli_verification`)은 처음 확인 · 버전이나 경로가 바뀌었을 때 · 모두를 강제한 확인(설정 > 에이전트 · 점검표의 "다시 확인")에서만
    /// 남긴다 — 앱이 앞에 올 때의 확인이 같은 행을 끝없이 쌓지 않게.
    func refreshAgentFacts(force: Bool = false, only: Set<AgentProvider>? = nil) async {
        guard !Self.offlinePreview else { return }
        let before = FirstRunChecklist.requiredAgents.map { ($0, agentReadiness($0)) }
        // Codex 는 계정마다 따로 로그인한다 — 계정마다의 판정도 둔다 (아래에서 막 로그인된 계정의 목록 · 한도를 읽는다).
        var codexBefore: [String: AgentReadiness] = [:]
        for account in accounts.accounts { codexBefore[account.id] = codexLoginReadiness(accountID: account.id) }
        let previousStatus = cliStatus
        isRefreshingAgentFacts = true
        defer { isRefreshingAgentFacts = false }

        let forced = Dictionary(uniqueKeysWithValues: AgentProvider.allCases.map { ($0, force && (only?.contains($0) ?? true)) })
        let env = environment
        let forceClaude = forced[.claude] ?? false, forceCodex = forced[.codex] ?? false, forceGemini = forced[.gemini] ?? false
        async let claudeStatus = env.checkStatus(.claude, force: forceClaude)
        async let codexStatus = env.checkStatus(.codex, force: forceCodex)
        async let geminiStatus = env.checkStatus(.gemini, force: forceGemini)
        // Command Line Tools 판정은 다른 사실(로그인 셸 PATH · CLI 버전 · 로그인 — 수십 초일 수 있다)을 기다리지 않고 곧바로 넣는다 —
        // 그 사이 폴더를 열어도 `/usr/bin/git` shim 을 고르지 않게 (`GitInspector.systemGitShimUnavailable`).
        let gitRead = Task { gitTools = await Self.readGitTools() }

        // 확인하는 사이 그 제공자의 실행 파일 경로를 바꿨으면 그 결과(옛 경로의 것)는 쓰지 않는다 — 바꾼 경로의 다시 확인이 뒤에 쓴다
        // (`pathOverrideChanged` → `recheckAgent`). 예전에는 늦게 끝난 옛 확인이 새 경로의 "준비됨" 을 "찾지 못함" 으로 덮었다 (set-n7).
        let claude = await claudeStatus
        if await env.isCurrent(claude) {
            cliStatus[.claude] = claude
            if claude.isUsable {
                let fresh = claudeLogin.map { Date().timeIntervalSince($0.checkedAt) < 300 } ?? false
                if forceClaude || !fresh {
                    let loggedIn = await claudeLoginCheck()
                    // 로그인을 확인하는 사이 경로가 바뀌었으면 그 확인도 옛 경로의 것이다.
                    if await env.isCurrent(claude) { claudeLogin = LoginCheck(loggedIn: loggedIn, checkedAt: Date()) }
                }
            } else {
                claudeLogin = nil
            }
        }
        let codex = await codexStatus
        if await env.isCurrent(codex) { cliStatus[.codex] = codex }
        // Codex 로그인은 계정 홈의 파일만 읽는다 (CLI · 네트워크 없음). 계정 행을 다시 쓰므로 Codex 를 강제하지 않는 확인
        // (앱 활성화에서 Claude 만 다시 볼 때)에서는 건너뛴다.
        if !force || forceCodex {
            await accounts.refreshAllIdentities()
            limits.setCodexAccounts(accounts.refs)
        }
        var stores: [String: Bool] = [:]
        for account in accounts.accounts {
            stores[account.id] = Self.codexUsesNonFileStore(home: account.homePath)
        }
        codexNonFileStores = stores
        let gemini = await geminiStatus
        if await env.isCurrent(gemini) { cliStatus[.gemini] = gemini }
        await gitRead.value
        // 셸 설정을 어디까지 읽었나 · 로그인 대신 쓸 인증이 있나 (위의 CLI 확인이 이미 셸을 읽었다 — 캐시).
        shellRead = await Self.readShellSource(environment)
        claudeAlternativeAuth = await environment.claudeAlternativeAuth()
        shellAuthVariables = await environment.shellAuthVariables()

        let recordAll = force && only == nil
        for provider in AgentProvider.allCases {
            guard let status = cliStatus[provider], let version = status.version, status.executable else { continue }
            let old = previousStatus[provider]
            guard recordAll || old?.version != version || old?.resolvedPath != status.resolvedPath else { continue }
            try? await store.recordVerification(provider: provider, cliVersion: version, capability: "실행 파일/버전 확인",
                                                result: "성공", detail: status.resolvedPath)
        }

        // 로그인이 모름 · 아님 · 설치 안 됨 → 확인됨: 그 제공자의 모델 목록 · 한도를 한 번 새로 읽는다.
        var readCodexAccounts: Set<String> = []
        for (provider, old) in before where FirstRunChecklist.becameReady(from: old, to: agentReadiness(provider)) {
            refreshProviderAfterLogin(provider)
            if provider == .codex {
                let id: String = codexReadiness().accountID ?? CodexAccount.defaultID
                readCodexAccounts.insert(accounts.accountOrDefault(id).id)
            }
        }
        // 계정마다: 막 로그인된 Codex 계정의 한도 · 모델 목록 (위의 제공자 단위 전환은 계정 하나만 읽는다). 읽지 않으면 그 계정으로 바꿔
        // 보내거나 넘길 때 "모델을 찾지 못해 보내지 않았습니다" 로 막혔다 (set-9).
        guard cliStatus[.codex]?.isUsable == true else { return }
        for account in accounts.accounts where !readCodexAccounts.contains(account.id) {
            guard let old = codexBefore[account.id],
                  FirstRunChecklist.becameReady(from: old, to: codexLoginReadiness(accountID: account.id)) else { continue }
            let scope: AgentScope = account.scope
            Task {
                await limits.refresh(scope, force: true)
                await refreshModelCatalog(scope)
            }
        }
    }

    /// Codex 계정 홈의 `config.toml` 이 파일 아닌 자격 저장소를 쓰는가 (그러면 auth.json 이 없어도 로그인돼 있을 수 있다).
    nonisolated static func codexUsesNonFileStore(home: String) -> Bool {
        let config = (home as NSString).expandingTildeInPath + "/config.toml"
        return CodexLoginJudge.usesNonFileStore(configToml: try? String(contentsOfFile: config, encoding: .utf8))
    }

    // MARK: 설정 > 에이전트의 다시 확인 (set-1 · set-16 · set-9)

    /// 그 제공자만 강제로 다시 확인한다 — 다른 제공자는 캐시를 쓴다. `rereadLoginPath` 면 로그인 셸 PATH 부터 다시 읽는다 (카드의 ↻ —
    /// 방금 설치했을 수 있다). 도는 동안 그 카드만 "확인 중" 이고 ↻ 가 돈다 (`recheckingAgents`). 예전 ↻ 는 "Codex 다시 확인" 이라고
    /// 적혀 있었지만 세 제공자를 모두 강제로 확인했고, 세 카드의 ↻ 가 함께 돌았다.
    func recheckAgent(_ provider: AgentProvider, rereadLoginPath: Bool = false) async {
        guard !Self.offlinePreview else { return }
        let serial = beginAgentRecheck([provider])
        defer { endAgentRecheck([provider], serial: serial) }
        if rereadLoginPath { await environment.invalidateLoginPath() }
        await refreshAgentFacts(force: true, only: [provider])
        // Gemini 로 다듬기가 쓰는 경로 · 버전도 (모델 목록은 쓸 때만 — `refreshGeminiStatus`).
        if provider == .gemini { await refreshGeminiStatus(force: true) }
    }

    /// 설정 > 에이전트의 "모두 다시 확인" — 점검표의 "다시 확인" 과 같은 길(로그인 셸 PATH 부터, 모두 강제). 카드 셋이 함께 "확인 중".
    func recheckAllAgents() async {
        guard !Self.offlinePreview else { return }
        let all = Set(AgentProvider.allCases)
        let serial = beginAgentRecheck(all)
        defer { endAgentRecheck(all, serial: serial) }
        await recheckFirstRunFacts()
        await refreshGeminiStatus(force: true)
    }

    /// 다시 확인을 시작한다 — 그 제공자들을 "확인 중" 으로 두고, 이 확인을 마지막 주인으로 적는다.
    @discardableResult
    func beginAgentRecheck(_ providers: Set<AgentProvider>) -> Int {
        agentRecheckSerial += 1
        for provider in providers {
            agentRecheckOwners[provider] = agentRecheckSerial
            recheckingAgents.insert(provider)
        }
        return agentRecheckSerial
    }

    /// 다시 확인이 끝났다 — 그 뒤에 시작한 확인이 없는 제공자만 "확인 중" 에서 뺀다 (겹친 확인이 먼저 끝나도 뒤의 것이 돌고 있으면 둔다).
    func endAgentRecheck(_ providers: Set<AgentProvider>, serial: Int) {
        for provider in providers where agentRecheckOwners[provider] == serial {
            agentRecheckOwners[provider] = nil
            recheckingAgents.remove(provider)
        }
    }

    /// Codex 계정 줄의 [다시 확인]: 그 홈의 auth.json · config.toml 을 다시 읽고 한도를 새로 읽는다. 로그인이 막 확인됐거나, 로그인돼
    /// 있는데 그 계정의 모델 목록이 비어 있으면 목록도 읽는다 (set-9 — 읽지 않으면 그 계정으로 보내기 · 인계가 "모델을 찾지 못해
    /// 보내지 않았습니다" 로 막혔다).
    func recheckCodexAccount(_ id: String) async {
        guard !Self.offlinePreview, let account = accounts.account(id) else { return }
        let before = codexLoginReadiness(accountID: id)
        await accounts.refreshIdentity(id)
        codexNonFileStores[id] = Self.codexUsesNonFileStore(home: account.homePath)
        await limits.refresh(account.scope, force: true)
        if codexAccountNeedsModels(id, before: before) { await refreshModelCatalog(account.scope) }
    }

    /// 이 계정의 모델 목록을 읽어야 하는가 — 지금 로그인돼 있고(쓸 수 없다고 확인된 CLI 는 빼고), 막 로그인됐거나 목록이 비었다.
    func codexAccountNeedsModels(_ id: String, before: AgentReadiness) -> Bool {
        let now: AgentReadiness = codexLoginReadiness(accountID: id)
        guard now == .ready, cliStatus[.codex]?.isUsable != false else { return false }
        if FirstRunChecklist.becameReady(from: before, to: now) { return true }
        let scope: AgentScope = accounts.accountOrDefault(id).scope
        return modelCatalogs[scope]?.options.isEmpty ?? true
    }

    /// Claude 로그인 사실만 다시 확인한다 (`claude auth status --json` — 세션 · 훅 · MCP 를 띄우지 않는다). 이어 가기 제안 · 한도 줄이
    /// 30분이 지난 로그인 사실을 다시 읽을 때 (`refreshStaleContinueTargets`). 모델 목록 · 한도는 **로그인이 이 확인에서 막 확인됐을 때만**
    /// 한 번 다시 읽는다 (`refreshAgentFacts` 와 같은 규칙 `applyClaudeLogin` — 이 길이 사실을 먼저 바꾸면 뒤의 활성화 · "다시 확인" 은
    /// 이미 확인된 것으로 보고 다시 읽지 않아, 로그아웃 때 받은 대체 모델 목록이 다시 켤 때까지 남았다).
    func refreshClaudeLogin() async {
        guard !Self.offlinePreview, cliStatus[.claude]?.isUsable == true else { return }
        let loggedIn = await claudeLoginCheck()
        applyClaudeLogin(LoginCheck(loggedIn: loggedIn, checkedAt: Date()))
    }

    /// Claude 로그인 사실을 바꾼다 — 바꾸기 전과 뒤의 점검표 상태가 "막 확인됨"(`FirstRunChecklist.becameReady`)이면 모델 목록 · 한도를 한 번
    /// 다시 읽는다. `refreshClaudeLogin` 이 쓴다 (`refreshAgentFacts` 는 여러 제공자를 함께 바꾼 뒤 같은 판정을 한 번에 한다).
    func applyClaudeLogin(_ login: LoginCheck?) {
        let before = agentReadiness(.claude)
        claudeLogin = login
        if FirstRunChecklist.becameReady(from: before, to: agentReadiness(.claude)) { refreshProviderAfterLogin(.claude) }
    }

    /// 로그인이 막 확인된 제공자의 모델 목록 · 한도를 읽는다. 프로젝트가 아직 없으면 Claude(`claude -p` 세션)는 첫 폴더 뒤로 미룬다.
    func refreshProviderAfterLogin(_ provider: AgentProvider) {
        switch provider {
        case .claude:
            if projects.isEmpty {
                deferredClaudeStartup = true
                return
            }
            startClaudeQueries(forceLimits: true)
        case .codex:
            let scope = accounts.accountOrDefault(codexReadiness().accountID ?? CodexAccount.defaultID).scope
            Task {
                await limits.refresh(scope, force: true)
                await refreshModelCatalog(scope)
            }
        case .gemini:
            break
        }
    }

    /// 시작 때 미룬 Claude 조회(모델 목록 · /usage)를 한 번 한다 — 첫 프로젝트가 생긴 뒤 (폴더 열기 · 기록 가져오기 모두
    /// `reloadProjects` 가 부른다).
    func runDeferredClaudeStartup() {
        guard deferredClaudeStartup, !projects.isEmpty, !Self.offlinePreview else { return }
        deferredClaudeStartup = false
        startClaudeQueries(forceLimits: false)
    }

    /// Claude 의 모델 목록 · /usage 조회 (`claude -p` 세션을 띄운다). 목록은 `claude -p /model` 하나 — 별칭 이름(넷)은 그 CLI 버전에서
    /// 받아 둔 것이 없을 때만 목록을 보인 뒤 뒤에서 (`AppModel.refreshModelCatalog`). 시험은 `claudeQueriesOverride` 로 센다.
    private func startClaudeQueries(forceLimits: Bool) {
        if let claudeQueriesOverride {
            claudeQueriesOverride(forceLimits)
            return
        }
        Task {
            await refreshModelCatalog(.claude)
            if startupFetchClaudeLimits { await limits.refresh(.claude, force: forceLimits) }
        }
    }

    /// 셸 환경을 어디까지 읽었나 (`CLIEnvironment.shellEnvironment` — 캐시가 없으면 이때 읽는다).
    nonisolated static func readShellSource(_ environment: CLIEnvironment) async -> ShellRead {
        switch await environment.shellEnvironment()?.source {
        case .interactive?: return .interactive
        case .loginOnly?: return .loginOnly
        case nil: return .failed
        }
    }

    /// Git 의 Command Line Tools 가 있는가 — `xcode-select -p` 만 (`/usr/bin/git` 을 실행하면 CLT 설치 창이 뜬다).
    nonisolated static func readGitTools() async -> GitToolsPresence {
        let tool = "/usr/bin/xcode-select"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return .unknown }
        let result = await CLIEnvironment.captureProcess(executable: tool, arguments: ["-p"],
                                                         environment: ProcessInfo.processInfo.environment, timeout: 10)
        guard result.note == nil, let status = result.exitStatus else { return .unknown }
        guard status == 0 else { return .missing }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return !path.isEmpty && FileManager.default.fileExists(atPath: path) ? .present : .missing
    }

    /// 점검표의 "다시 확인": 로그인 셸 PATH 부터 다시 읽고(사람이 셸 설정을 고쳤을 수 있다) 모든 사실을 강제로 다시 확인한다.
    func recheckFirstRunFacts() async {
        firstRunError = nil
        guard !Self.offlinePreview else { return }
        lastFactsRecheck = Date()
        await environment.invalidateLoginPath()
        await refreshAgentFacts(force: true)
        await notifications.readSettings()
    }

    /// 앱이 다시 앞에 올 때: 점검표가 보이거나 어떤 사실이 모름 · 부정일 때만, 15초에 한 번(로그인 필요는 3초에 한 번), 준비되지 않은
    /// 제공자만 강제 확인 (`FirstRunRecheck`). 사람이 터미널에서 설치 · 로그인하고 돌아온 순간이다.
    func recheckFactsOnActivation() async {
        guard bootstrapped, !Self.offlinePreview else { return }
        let now = Date()
        guard let stale = FirstRunRecheck.providers(facts: firstRunFacts, checklistVisible: showsFirstRun || showFirstRunSheet,
                                                     lastRun: lastFactsRecheck, now: now) else { return }
        lastFactsRecheck = now
        if !stale.isEmpty { await refreshAgentFacts(force: true, only: stale) } else { gitTools = await Self.readGitTools() }
        await notifications.readSettings()
    }

    /// 점검표가 보이는 동안(`FirstRunChecklist.watchesLogins`) "로그인 필요" 인 제공자의 로그인만 가볍게 다시 본다 (onb-11) — 앱 안의
    /// 터미널에서 로그인하면 앱이 앞에 있어 활성화 확인이 돌지 않는다. Claude 는 `claude auth status`(세션 · 훅 · MCP 를 띄우지 않는다),
    /// Codex 는 계정 홈의 auth.json (CLI · 네트워크 없음). 막 확인되면 그 제공자의 모델 목록 · 한도를 한 번 다시 읽는다.
    func refreshPendingLogins() async {
        guard bootstrapped, !Self.offlinePreview, !isRefreshingAgentFacts else { return }
        if agentReadiness(.claude) == .notLoggedIn { await refreshClaudeLogin() }
        if agentReadiness(.codex) == .notLoggedIn {
            await accounts.refreshAllIdentities()
            limits.setCodexAccounts(accounts.refs)
            if agentReadiness(.codex) == .ready { refreshProviderAfterLogin(.codex) }
        }
    }

    /// 시작 점검을 연다 (오류 줄의 [시작 점검 열기] 등). 프로젝트가 없으면 가운데 칸이 이미 점검표다.
    func openStartCheck() {
        guard !showsFirstRun else { return }
        showFirstRunSheet = true
    }

    /// 대화의 오류 행이 로그인 문제로 끝난 실행이면 사람이 할 일 (onb-7 — 오류 줄 화면이 [로그인 명령 복사] · [시작 점검 열기] 를 단다).
    /// Codex 는 그 실행의 계정 홈에 로그인되는 명령이다.
    func loginTroubleGuide(for event: ThreadEvent) -> LoginTroubleGuide? {
        var run: Run?
        if let runID = event.runID { run = threadStates[event.threadID]?.runsByID[runID] }
        let provider: AgentProvider? = event.provider ?? run?.provider
        var home: String?
        if provider == .codex {
            let accountID: String = run?.codexAccountID ?? CodexAccount.defaultID
            home = accounts.accountOrDefault(accountID).homePath
        }
        return LoginTroubleGuide.make(event: event, provider: provider, codexHome: home)
    }

    // MARK: 알림

    /// "알림 허용" — 아직 묻지 않았을 때만 (거부했으면 시스템 설정을 연다 — 화면이 고른다).
    func requestNotificationPermission() async {
        guard !Self.offlinePreview, notifications.permission == .notDetermined else { return }
        await notifications.requestAuthorization(trigger: .button)
    }

    /// 그 대화가 메인 창의 칸에 보이는가 — 가운데 칸이 대화(전적 · 크게 보기가 아니다)이고 그 대화(내부 대화면 그 부모)가 어느 칸에
    /// 열려 있다. 앱이 앞에 있고 창이 보이는지는 앱 층이 함께 본다 (`AppDelegate` 가 `NotificationService.isThreadOnScreen` 에 넣는다).
    /// 그러면 시스템 알림을 내지 않는다 — 칸 머리 · 승인 카드 · Dock 배지가 이미 보인다 (H15 · chat-15 · nav-6).
    func isThreadShownInPanes(_ threadID: String) -> Bool {
        var shown: WindowPane = .conversation
        if let raw = UserDefaults.standard.string(forKey: WindowStateKey.pane), let pane = WindowPane(rawValue: raw) { shown = pane }
        guard shown == .conversation, !diffWideActive else { return false }
        var row: String = threadID
        if let thread = paneThread(threadID), thread.isInternal, let jobID = thread.orchestrationJobID,
           let parent = orchestration.snapshotsByThread.values.first(where: { $0.job.id == jobID })?.job.parentThreadID {
            row = parent
        }
        return panes.threadIDs.contains(row)
    }

    /// 시스템 설정 > 알림의 이 앱 항목 (macOS 13+ 의 설정 앱 확장 ID). 2026-10-01 macOS 26 에서 열리는 것을 확인했다.
    static func notificationSettingsURL(bundleID: String? = Bundle.main.bundleIdentifier) -> URL? {
        var text = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        if let bundleID, !bundleID.isEmpty { text += "?id=" + bundleID }
        return URL(string: text)
    }

    // MARK: 작업할 폴더

    /// 고른 폴더를 연다: 같은 폴더의 프로젝트가 있으면 그것(가장 최근 대화), 없으면 만들고 첫 대화를 만든다 — 대화가 하나도 없으면
    /// 점검표의 `readyAgent`, 있으면 `initialAgent`. 입력창에 포커스를 한 번 요청한다. 미룬 Claude 조회는 프로젝트가 생길 때
    /// (`reloadProjects`). 넓은 폴더(`~` · `/`) 경고는 고르는 쪽(화면)이 먼저 묻는다.
    @discardableResult
    func openProjectFolder(path: String) async -> Project? {
        firstRunError = nil
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            reportFolderError("폴더를 찾지 못했습니다: \(path)")
            return nil
        }
        let existed = projects.contains { FolderChoice.samePath($0.path, path) }
        let hasConversations = !allThreads().isEmpty
        // 첫 대화를 만들 때 아직 확인 중인 에이전트가 있으면 잠깐 기다린다 — 시작 직후에 열면 모두 "확인 중" 이라 늘 Claude 였다 (onb-5).
        if !hasConversations, !existed { await waitForAgentFacts() }
        // 대화가 하나도 없을 때(첫 실행)만 점검표가 고른 에이전트로 연다. 그 밖에는 `initialAgent` (마지막에 쓴 에이전트 · 계정).
        let firstAgent = firstRunChecklist.agentForNewFolder(hasConversations: hasConversations)
        let name = (path as NSString).lastPathComponent
        let project = await addProject(name: name.isEmpty ? path : name, path: path)
        guard projects.contains(where: { $0.id == project.id }) else {
            reportFolderError("프로젝트를 저장하지 못했습니다. 앱 데이터 폴더를 쓸 수 있는지 확인하세요.")
            return nil
        }
        if let latest = (threadsByProject[project.id] ?? []).max(by: { $0.updatedAt < $1.updatedAt }) {
            await selectThread(latest.id)
            requestComposerFocus(threadID: latest.id)
            if existed { banner = BannerMessage(text: "이미 등록된 폴더라 그 프로젝트를 열었습니다: \(project.name)", isError: false) }
        } else {
            let thread = await addThread(projectID: project.id, title: "새 대화", agent: firstAgent?.provider,
                                         codexAccountID: firstAgent?.codexAccountID)
            requestComposerFocus(threadID: thread.id)
        }
        return project
    }

    /// 첫 대화의 에이전트를 고르기 전에 기다리는 최대 시간 (초). 확인은 보통 1~3초다 — 셸이 느리면 이만큼 기다린 뒤 아는 것으로 고른다.
    nonisolated static let agentFactsWaitLimit: TimeInterval = 8

    /// 확인이 도는 동안(`isRefreshingAgentFacts`) 확인 중인 에이전트가 첫 대화의 에이전트를 바꿀 수 있으면
    /// (`FirstRunChecklist.readyAgentMayChange`) 기다린다 (최대 `agentFactsWaitLimit`). 사실은 부트스트랩 · "다시 확인" 의
    /// `refreshAgentFacts` 가 채운다 — 여기서는 확인을 새로 띄우지 않는다 (확인이 돌지 않으면 기다리지 않는다).
    func waitForAgentFacts(limit: TimeInterval = AppModel.agentFactsWaitLimit) async {
        let deadline = Date().addingTimeInterval(limit)
        while isRefreshingAgentFacts, firstRunChecklist.readyAgentMayChange, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// 폴더를 열지 못했다: 점검표(가운데 칸 · 시트)가 보이면 그 오류 줄에, 아니면 배너에 (사이드바 · ⌘O 에서 연 경우).
    private func reportFolderError(_ text: String) {
        if showsFirstRun || showFirstRunSheet {
            firstRunError = text
        } else {
            banner = BannerMessage(text: text, isError: true)
        }
    }
}
