import Foundation

// 첫 실행 점검표의 순수 판정.
// 사실(`FirstRunFacts`) → 단계(①에이전트 ②알림 ③작업할 폴더) · 다음 할 일 · 첫 대화의 에이전트.
// SwiftUI · AppKit 을 모른다 — 검증 하네스(`FirstRunTests`)가 그대로 컴파일한다. 사실을 모으는 곳은 `AppModel+Setup.swift`,
// 화면은 `UI/FirstRunView.swift`. 화면 글은 여기 두지 않는다 (판정은 열거형으로).

/// 에이전트 CLI 하나의 준비 상태. 모르는 것을 "없음" 으로 뭉개지 않는다.
enum AgentReadiness: String, Equatable, Sendable, CaseIterable {
    /// 설치됐고 로그인이 확인됐다.
    case ready
    /// 설치됐지만 로그인을 확인하지 못했다 (확인 명령 실패 · 파일 아닌 자격 저장소 · 읽지 못한 auth.json). 통과로 센다.
    case loginUnknown
    /// 설치됐고 로그인이 안 돼 있다고 확인됐다.
    case notLoggedIn
    /// 실행 파일을 찾지 못했다.
    case notInstalled
    /// 실행할 수 없다: 설정 > 에이전트(실행 파일)에서 지정한 경로를 실행할 수 없거나 — 앱은 다른 곳으로 넘어가지 않으므로
    /// (`CLIEnvironment.resolveExecutable`) 설치해도 그대로다 —, 찾은 실행 파일이 돌지 않는다(`--version` 실패 — `Agent.runError`).
    /// 설치 안내가 아니라 경로를 지정 · 고치라고 안내한다.
    case pathInvalid
    /// 아직 확인하지 않았다 (확인 중).
    case checking

    /// ① 단계를 통과시키는가 — 로그인을 모르는 것도 통과 (황색 안내).
    var passes: Bool { self == .ready || self == .loginUnknown }
}

/// 알림 권한 (`UNAuthorizationStatus` 를 앱 쪽 말로). 아직 읽지 않았으면 `checking`, 읽었는데 모르는 값이거나 읽지 못했으면 `unknown`.
enum NotificationPermission: String, Equatable, Sendable {
    case notDetermined, denied, authorized, unknown, checking
}

/// Git 이 쓰는 Command Line Tools — `xcode-select -p` 로만 본다 (`/usr/bin/git` 을 실행하면 설치 창이 뜬다).
enum GitToolsPresence: String, Equatable, Sendable {
    case present, missing, unknown
}

/// 로그인 확인 한 번의 결과. `loggedIn` 이 nil 이면 확인하지 못한 것이다.
struct LoginCheck: Equatable, Sendable {
    var loggedIn: Bool?
    var checkedAt: Date
}

/// 셸 설정(PATH · 환경 변수)을 어디까지 읽었나 (`CLIEnvironment.shellEnvironment`). 대화형 셸(`~/.zshrc`)을 읽지 못했으면 거기 둔
/// API 키 · 프록시 · nvm 의 PATH 가 CLI 에 넘어가지 않는다 — 점검표가 그 사실을 말한다.
enum ShellRead: String, Equatable, Sendable {
    case unknown, interactive, loginOnly, failed
}

/// 점검표가 보는 사실 전부.
struct FirstRunFacts: Equatable, Sendable {
    struct Agent: Equatable, Sendable {
        var readiness: AgentReadiness = .checking
        var version: String?
        var path: String?
        /// Codex: 로그인이 확인된(또는 모르는) 계정 — 첫 대화를 그 계정으로 연다.
        var accountID: String?
        /// 찾은 실행 파일이 돌지 않은 까닭 (`--version` 의 오류 — "env: node: No such file or directory" 등). 그때 준비 상태는 `pathInvalid`.
        var runError: String?
    }

    var claude = Agent()
    var codex = Agent()
    /// 선택 — 단계 판정에 넣지 않는다.
    var antigravity = Agent()
    var notifications: NotificationPermission = .unknown
    /// 알림 설정의 "앱 아이콘 배지". nil 이면 모름 (Dock 배지는 이것을 따른다 — A2 실측).
    var badgesEnabled: Bool?
    var git: GitToolsPresence = .unknown
    var projectCount = 0
    /// 셸 설정을 어디까지 읽었나 — 판정에 넣지 않는다 (안내만).
    var shell: ShellRead = .unknown
    /// Claude 가 로그인 대신 쓸 수 있는 인증(API 키 · Bedrock · Vertex)이 자식 환경에 있다 — 그러면 "로그인 안 됨" 이 확인돼도 로그인 모름으로
    /// 센다 (`claude auth status` 는 로그인만 본다 — onb-3). 판정은 `AppModel.agentReadiness`, 안내는 화면.
    var claudeAlternativeAuth = false
    /// 셸에 있지만 에이전트에게 넘기지 않는 인증 변수의 이름 (설정 > 에이전트의 "셸의 API 키 넘기기" 가 꺼져 있다 — onb-19).
    /// 판정에 넣지 않는다 — 점검표 ① · Claude 로그인 안내가 그 사실을 말한다 (`FirstRunText.withheldAuthNote`).
    var withheldAuth: [String] = []

    func agent(_ provider: AgentProvider) -> Agent {
        switch provider {
        case .claude: return claude
        case .codex: return codex
        case .gemini: return antigravity
        }
    }

    /// 다시 확인할 만한 에이전트 — 설치됐는데 로그인이 안 돼 있다고 확인된 것(사람이 터미널에서 로그인하고 돌아올 수 있다), 또는
    /// ①이 아직 끝나지 않았을 때의 설치 안 됨 · 경로 오류 · 확인 중. ①이 끝났으면(하나만 쓰는 사람) 남은 쪽의 "설치 안 됨" 은
    /// 끝나지 않은 사실로 세지 않는다 — 세면 앱이 앞에 올 때마다 전체 확인이 영영 돈다. 로그인 모름은 통과라 세지 않는다.
    var unsettledAgents: [AgentProvider] {
        let agentsPass = [FirstRunStepState.done, .doneWithNote].contains(FirstRunChecklist(self).state(.agents))
        return FirstRunChecklist.requiredAgents.filter { provider in
            switch agent(provider).readiness {
            case .ready, .loginUnknown: return false
            case .notLoggedIn: return true
            case .notInstalled, .pathInvalid, .checking: return !agentsPass
            }
        }
    }

    /// 모름 · 부정인 사실이 있는가 — 앱이 다시 앞에 올 때 다시 확인할지 (`FirstRunRecheck`).
    var hasUnsettledFact: Bool {
        !unsettledAgents.isEmpty || notifications != .authorized || badgesEnabled == false || git != .present
    }
}

/// 단계 하나의 상태.
enum FirstRunStepState: Equatable, Sendable {
    /// 끝났다.
    case done
    /// 통과했지만 볼 것이 있다 (로그인 모름 · 배지 꺼짐).
    case doneWithNote
    /// 사람이 할 일이 있다 — 안내일 뿐, 다음 단계를 막지 않는다.
    case todo
    /// 아직 확인 중이다.
    case checking
}

enum FirstRunStep: Int, CaseIterable, Sendable {
    case agents = 1, notifications, folder
}

/// 사실 → 단계. ①②는 안내일 뿐 ③을 막지 않는다.
struct FirstRunChecklist: Equatable, Sendable {
    let facts: FirstRunFacts

    init(_ facts: FirstRunFacts) { self.facts = facts }

    /// 판정에 넣는 에이전트 (Antigravity 는 선택이라 뺀다).
    static let requiredAgents: [AgentProvider] = [.claude, .codex]

    func state(_ step: FirstRunStep) -> FirstRunStepState {
        switch step {
        case .agents:
            let agents = Self.requiredAgents.map { facts.agent($0).readiness }
            if agents.contains(.ready) { return agents.contains(.loginUnknown) ? .doneWithNote : .done }
            if agents.contains(.loginUnknown) { return .doneWithNote }
            if agents.contains(.checking) { return .checking }
            return .todo
        case .notifications:
            switch facts.notifications {
            case .authorized: return facts.badgesEnabled == false ? .doneWithNote : .done
            // 읽지 못했으면 할 일로 둔다 (시스템 설정에서 볼 수 있다). 아직 읽기 전만 확인 중.
            case .notDetermined, .denied, .unknown: return .todo
            case .checking: return .checking
            }
        case .folder:
            return facts.projectCount > 0 ? .done : .todo
        }
    }

    /// ③(작업할 폴더)을 열 수 있는가 — 언제나. ①②가 끝나지 않아도 막지 않는다 (상수지만 시험이 이 규칙을 붙든다).
    var canOpenFolder: Bool { true }

    /// 다음에 할 일 — 화면이 그 단계를 강조한다. 에이전트 → 작업할 폴더 → 알림 (알림은 안내라 폴더 뒤). 다 끝났으면 nil.
    var next: FirstRunStep? {
        if state(.agents) == .todo { return .agents }
        if state(.folder) == .todo { return .folder }
        if state(.notifications) == .todo { return .notifications }
        return nil
    }

    /// 첫 대화의 에이전트: 로그인이 확인된 것(Claude → Codex) → 로그인을 모르는 것 → 없으면 nil (그때는 `initialAgent`).
    var readyAgent: (provider: AgentProvider, codexAccountID: String?)? {
        for wanted in [AgentReadiness.ready, .loginUnknown] {
            for provider in Self.requiredAgents where facts.agent(provider).readiness == wanted {
                return (provider, provider == .codex ? facts.codex.accountID : nil)
            }
        }
        return nil
    }

    /// 새 폴더의 첫 대화를 무엇으로 열지: 아직 대화가 하나도 없을 때(첫 실행)만 `readyAgent`. 대화가 있으면 nil — 마지막에 쓴
    /// 에이전트 · 계정을 잇는 `ConversationThread.initialAgent` 가 정한다 (Codex 만 쓰는 사람이 새 폴더마다 Claude 로 열리지 않게).
    func agentForNewFolder(hasConversations: Bool) -> (provider: AgentProvider, codexAccountID: String?)? {
        hasConversations ? nil : readyAgent
    }

    /// 아직 확인 중인 에이전트가 첫 대화의 에이전트(`readyAgent`)를 바꿀 수 있는가 — 첫 폴더를 열 때 잠깐 기다릴지 (onb-5).
    /// 시작 직후에는 모두 "확인 중" 이라 `readyAgent` 가 nil 이고, 그대로 열면 첫 대화가 늘 Claude 였다 (Codex 만 쓰는 사람도).
    /// 확인 중인 에이전트가 확인돼도 지금 고른 것보다 앞서지 못하면(로그인된 Claude 를 이미 골랐다) 기다리지 않는다.
    var readyAgentMayChange: Bool {
        let checking: [AgentProvider] = Self.requiredAgents.filter { facts.agent($0).readiness == .checking }
        guard !checking.isEmpty else { return false }
        guard let current = readyAgent else { return true }
        let currentRank: Int = Self.rank(current.provider, facts.agent(current.provider).readiness)
        return checking.contains { Self.rank($0, .ready) < currentRank }
    }

    /// `readyAgent` 의 순서: 로그인 확인됨(Claude → Codex) → 로그인 모름(Claude → Codex). 작을수록 앞이다.
    private static func rank(_ provider: AgentProvider, _ readiness: AgentReadiness) -> Int {
        let count: Int = requiredAgents.count
        let tier: Int = readiness == .ready ? 0 : count
        let order: Int = requiredAgents.firstIndex(of: provider) ?? count
        return tier + order
    }

    /// 점검표가 보이는 동안 로그인만 가볍게 다시 볼까 (onb-11) — ①이 아직 끝나지 않았고 "로그인 필요" 가 확인된 에이전트가 있을 때.
    /// 앱 안의 터미널에서 로그인하면 앱이 앞에 있어 활성화 확인이 돌지 않는다. ①이 끝났으면(하나만 쓰는 사람) 돌리지 않는다.
    var watchesLogins: Bool {
        state(.agents) == .todo && Self.requiredAgents.contains { facts.agent($0).readiness == .notLoggedIn }
    }

    /// 로그인이 모름 · 아님 · 설치 안 됨 · 경로 오류 → 확인됨으로 바뀌었는가 — 그 제공자의 모델 목록 · 한도를 한 번 새로 읽는다.
    /// 처음 확인(`checking` → `ready`)은 세지 않는다 (시작할 때 이미 읽는다).
    static func becameReady(from old: AgentReadiness, to new: AgentReadiness) -> Bool {
        new == .ready && [.loginUnknown, .notLoggedIn, .notInstalled, .pathInvalid].contains(old)
    }
}

/// 앱이 다시 앞에 올 때의 다시 확인: 점검표가 보이거나 어떤 사실이 모름 · 부정일 때만, 15초에 한 번, 준비되지 않은 제공자만 강제.
/// 단 "로그인 필요" 로 확인된 제공자는 15초를 기다리지 않는다 (3초에 한 번) — 로그인 확인은 가볍고(`claude auth status` · auth.json),
/// 복사한 명령이 맞는지 보러 잠깐 앱에 왔다가 터미널에서 로그인을 마치고 곧 돌아오면 "로그인 필요" 가 그대로 남았다 (onb-11).
enum FirstRunRecheck {
    static let throttle: TimeInterval = 15
    static let loginThrottle: TimeInterval = 3

    /// 다시 확인할 제공자 (강제). nil 이면 이번에는 하지 않는다. 빈 집합이면 에이전트는 두고 알림 · Git 만 다시 읽는다.
    /// 점검표가 보이면 준비되지 않은 제공자 모두, 아니면 끝나지 않은 에이전트(`FirstRunFacts.unsettledAgents`)만.
    /// 15초 안이면 "로그인 필요" 인 제공자만 (없으면 nil).
    static func providers(facts: FirstRunFacts, checklistVisible: Bool, lastRun: Date?, now: Date) -> Set<AgentProvider>? {
        guard checklistVisible || facts.hasUnsettledFact else { return nil }
        if let lastRun {
            let elapsed = now.timeIntervalSince(lastRun)
            if elapsed < loginThrottle { return nil }
            if elapsed < throttle {
                let logins = FirstRunChecklist.requiredAgents.filter { facts.agent($0).readiness == .notLoggedIn }
                return logins.isEmpty ? nil : Set(logins)
            }
        }
        if checklistVisible {
            return Set(FirstRunChecklist.requiredAgents.filter { facts.agent($0).readiness != .ready })
        }
        return Set(facts.unsettledAgents)
    }
}

/// Codex 로그인 판정 — `auth.json` 이 없으면 미로그인, 단 그 홈의 `config.toml` 이 파일 아닌 자격 저장소를 쓰면 모름.
enum CodexLoginJudge {
    /// `config.toml` 의 최상위 `cli_auth_credentials_store` (codex-cli 0.157.1 의 값: file · keyring · auto · ephemeral — 실행 파일의
    /// 문자열에서 확인, 2026-10-01). 파일이 아닌 저장소면 auth.json 이 없어도 로그인돼 있을 수 있다.
    /// 여러 줄 문자열(`"""` · `'''`) 안의 줄은 건너뛴다 — 그 안의 `[중요] …` 같은 줄을 표 머리로 보지 않게.
    static func usesNonFileStore(configToml: String?) -> Bool {
        guard let configToml else { return false }
        var openDelimiter: String?
        for raw in configToml.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let rawLine = String(raw)
            if let delimiter = openDelimiter {
                // 여러 줄 문자열 안 — 닫는 따옴표가 나올 때까지 본문이다.
                if rawLine.contains(delimiter) { openDelimiter = nil }
                continue
            }
            if let delimiter = Self.opensMultilineString(rawLine) {
                openDelimiter = delimiter
                continue
            }
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }   // 표가 시작되면 최상위가 끝난다
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard key == "cli_auth_credentials_store" else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return !value.isEmpty && value != "file"
        }
        return false
    }

    /// 이 줄의 값이 여러 줄 문자열을 열고 닫지 않았으면 그 따옴표(`"""` · `'''`). 한 줄 안에서 열고 닫으면 nil.
    private static func opensMultilineString(_ line: String) -> String? {
        for delimiter in ["\"\"\"", "'''"] {
            let count = line.components(separatedBy: delimiter).count - 1
            if count % 2 == 1 { return delimiter }
        }
        return nil
    }

    static func readiness(status: CodexAuthStatus, configToml: String?) -> AgentReadiness {
        readiness(status: status, nonFileStore: usesNonFileStore(configToml: configToml))
    }

    static func readiness(status: CodexAuthStatus, nonFileStore: Bool) -> AgentReadiness {
        switch status {
        case .loggedIn: return .ready
        case .unreadable: return .loginUnknown
        case .notLoggedIn: return nonFileStore ? .loginUnknown : .notLoggedIn
        }
    }

    /// 계정 여럿의 판정을 하나로: 로그인된 계정이 있으면 그것, 모르는 계정이 있으면 그것, 아니면 첫 계정(기본)의 것.
    static func combined(_ accounts: [(id: String, readiness: AgentReadiness)]) -> (readiness: AgentReadiness, accountID: String?) {
        for wanted in [AgentReadiness.ready, .loginUnknown] {
            if let hit = accounts.first(where: { $0.readiness == wanted }) { return (wanted, hit.id) }
        }
        return (accounts.first?.readiness ?? .notLoggedIn, accounts.first?.id)
    }
}

/// 고른 작업 폴더의 판정 — 같은 폴더인지 · 넓은 폴더 경고.
enum FolderChoice {
    enum Risk: Equatable, Sendable { case root, home }

    /// 비교용 경로: `~` 를 풀고 심볼릭 링크를 풀고 표준화, 끝 `/` 를 뗀다 (`/var/…` 와 `/private/var/…` 는 같아진다).
    static func canonicalPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var resolved = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
        while resolved.count > 1 && resolved.hasSuffix("/") { resolved.removeLast() }
        return resolved
    }

    static func samePath(_ a: String, _ b: String) -> Bool { canonicalPath(a) == canonicalPath(b) }

    /// `/` 와 홈 폴더 전체는 경고한다 (에이전트가 그 안의 모든 파일을 본다).
    static func risk(_ path: String, home: String = NSHomeDirectory()) -> Risk? {
        let canonical = canonicalPath(path)
        if canonical == "/" { return .root }
        if canonical == canonicalPath(home) { return .home }
        return nil
    }
}

/// 공식 설치 안내 · 명령. **로컬 CLI 의 `--help` · 설치된 패키지 정보로 확인한 것만** 적는다 (2026-10-01).
/// - Claude Code 2.1.283: 패키지 README 의 문서 링크 · `npm install -g @anthropic-ai/claude-code`, `claude auth --help` 의 `login`.
/// - Codex 0.157.1: 패키지 README 의 문서 링크 · `npm install -g @openai/codex`. 로그인 명령은 `CodexAccountInspector.loginCommand(home:)`
///   (`CODEX_HOME=<홈> codex login` — 앱이 읽는 홈에 로그인되게).
/// - Antigravity(`agy`): 도움말에 문서 링크가 없어 안내를 두지 않는다 (선택).
/// 앱은 설치 · 로그인을 대신 실행하지 않는다 — 복사만 한다.
enum AgentSetupGuide {
    static func docsURL(_ provider: AgentProvider) -> URL? {
        switch provider {
        case .claude: return URL(string: "https://code.claude.com/docs/en/overview")
        case .codex: return URL(string: "https://developers.openai.com/codex")
        // agy 1.2 실행 파일 안에 든 안내 주소 (설치 명령은 확인하지 못해 두지 않는다 — `installCommand`).
        case .gemini: return URL(string: "https://antigravity.google/docs")
        }
    }

    static func installCommand(_ provider: AgentProvider) -> String? {
        switch provider {
        case .claude: return "npm install -g @anthropic-ai/claude-code"
        case .codex: return "npm install -g @openai/codex"
        case .gemini: return nil
        }
    }

    static let claudeLoginCommand = "claude auth login"
    /// Command Line Tools 설치 (Git). 시스템 설치 창이 뜬다 — 사람이 터미널에서.
    static let gitToolsInstallCommand = "xcode-select --install"
}

// MARK: - 로그인 문제로 끝난 실행 (onb-7)

/// 실행이 로그인 문제(`LimitStatus.authProblem` — 오류 행의 제목 "인증 문제")로 끝났을 때 대화 안에서 줄 안내. CLI 원문
/// ("Please run /login")이 말하는 `/login` 은 이 앱의 입력창에서 할 수 없고, 점검표는 폴더를 열면 사라진다 — 터미널의 로그인 명령과
/// 시작 점검으로 가는 길을 준다. 판정 · 글은 여기(검증 하네스가 컴파일한다), 단추([로그인 명령 복사] · [시작 점검 열기] —
/// `AppModel.openStartCheck`)는 오류 줄 화면이 단다. 앱 쪽 입구는 `AppModel.loginTroubleGuide(for:)` (Codex 계정 홈을 고른다).
struct LoginTroubleGuide: Equatable, Sendable {
    var provider: AgentProvider
    /// 터미널에서 칠 로그인 명령 (점검표와 같은 명령). Antigravity 는 모른다 (nil).
    var loginCommand: String?
    /// 오류 줄 아래의 안내 문장.
    var text: String

    static let startCheckTitle = "시작 점검 열기"

    /// 오류 행이 로그인 문제인가 — 실행이 끝날 때 남긴 분류(`RunSession.finish` 가 제목에 `LimitStatus.koreanName` 을 쓴다).
    static func isLoginFailure(_ event: ThreadEvent) -> Bool {
        event.kind == .error && event.title == LimitStatus.authProblem.koreanName
    }

    /// `provider` 는 그 실행의 에이전트 (행에 없으면 실행에서), `codexHome` 은 Codex 실행의 계정 홈.
    static func make(event: ThreadEvent, provider: AgentProvider?, codexHome: String?) -> LoginTroubleGuide? {
        guard isLoginFailure(event), let provider else { return nil }
        switch provider {
        case .claude:
            return LoginTroubleGuide(provider: provider, loginCommand: AgentSetupGuide.claudeLoginCommand, text: claudeText)
        case .codex:
            let home: String = codexHome ?? CodexAccountInspector.defaultHomePath()
            return LoginTroubleGuide(provider: provider, loginCommand: CodexAccountInspector.loginCommand(home: home), text: codexText)
        case .gemini:
            return LoginTroubleGuide(provider: provider, loginCommand: nil, text: antigravityText)
        }
    }

    static let claudeText: String = "Claude Code 에 로그인돼 있지 않거나 로그인이 만료됐습니다. CLI 가 말하는 /login 은 이 앱의 입력창에서는 할 수 없습니다 — 터미널에서 아래 명령으로 로그인한 뒤 다시 보내세요."
    static let codexText: String = "Codex 에 로그인돼 있지 않거나 로그인이 만료됐습니다. 터미널에서 아래 명령으로 로그인한 뒤 다시 보내세요 (이 대화가 쓰는 Codex 계정 폴더에 로그인됩니다)."
    static let antigravityText: String = "Antigravity 가 로그인 문제로 실행되지 않았습니다. 터미널에서 agy 가 동작하는지 확인한 뒤 다시 보내세요."
}

#if DEBUG
extension FirstRunFacts {
    /// 화면 확인용 사실 (`-preview.firstRun <사실>`, AHC_OFFLINE=1). 쉼표로 이은 `이름=값`:
    /// `claude=ready|unknown|nologin|missing|badpath|checking` · `codex=…` · `agy=…` · `notify=allowed|denied|ask|unknown|checking` ·
    /// `badge=on|off` · `git=yes|no|unknown`. 적지 않은 것은 준비된 값 (Claude · Codex 로그인됨, 알림 허용 · 배지 켬, Git 있음,
    /// Antigravity 설치 안 됨). 버전 · 경로는 화면 확인용 견본이다.
    static func preview(_ spec: String?) -> FirstRunFacts {
        var facts = FirstRunFacts()
        facts.claude = Agent(readiness: .ready, version: "2.1.283 (Claude Code)", path: "/opt/homebrew/bin/claude")
        facts.codex = Agent(readiness: .ready, version: "codex-cli 0.157.1", path: "/opt/homebrew/bin/codex", accountID: CodexAccount.defaultID)
        facts.antigravity = Agent(readiness: .notInstalled)
        facts.notifications = .authorized
        facts.badgesEnabled = true
        facts.git = .present
        func readiness(_ value: String) -> AgentReadiness? {
            ["ready": .ready, "unknown": .loginUnknown, "nologin": .notLoggedIn, "missing": .notInstalled,
             "badpath": .pathInvalid, "checking": .checking][value]
        }
        for pair in (spec ?? "").split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard parts.count == 2 else { continue }
            let (key, value) = (parts[0], parts[1])
            switch key {
            case "claude", "codex", "agy":
                guard let state = readiness(value) else { continue }
                var agent = key == "claude" ? facts.claude : key == "codex" ? facts.codex : facts.antigravity
                agent.readiness = state
                if state == .notInstalled { agent.version = nil; agent.path = nil }
                if state == .pathInvalid { agent.version = nil; agent.path = NSHomeDirectory() + "/.claude/local/\(key)" }
                if state != .notInstalled, agent.path == nil, key == "agy" {
                    agent.version = "1.2.2"
                    agent.path = NSHomeDirectory() + "/.local/bin/agy"
                }
                switch key {
                case "claude": facts.claude = agent
                case "codex": facts.codex = agent
                default: facts.antigravity = agent
                }
            case "notify":
                facts.notifications = ["allowed": .authorized, "denied": .denied, "ask": .notDetermined,
                                       "unknown": .unknown, "checking": .checking][value] ?? facts.notifications
            case "badge": facts.badgesEnabled = value == "on" ? true : value == "off" ? false : nil
            case "git": facts.git = value == "yes" ? .present : value == "no" ? .missing : .unknown
            default: continue
            }
        }
        return facts
    }
}
#endif
