import Foundation

// MARK: - 제공자

/// 앱이 연동하는 CLI 에이전트 종류.
enum AgentProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    /// Antigravity CLI(`agy`) 로 실행하는 Gemini. 보조 요약과 같은 CLI 를 쓴다.
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Antigravity"
        }
    }

    /// 색만으로 상태를 전달하지 않기 위해 항상 이름/기호와 함께 사용한다.
    var shortSymbol: String {
        switch self {
        case .claude: return "C"
        case .codex: return "X"
        case .gemini: return "G"
        }
    }

    /// 인계 기본 대상. 제공자가 셋이라 "반대편"이 하나로 정해지지 않으므로,
    /// 메뉴·단축키의 **기본값**일 뿐이다. 실제 대상은 사용자가 고르거나
    /// 자동 인계가 우선순위와 한도로 고른다 (`AutomaticHandoffTargets`).
    var other: AgentProvider {
        switch self {
        case .claude: return .codex
        case .codex: return .claude
        case .gemini: return .claude
        }
    }

    /// 승인을 앱이 받아 사람에게 물을 수 있는 제공자인지.
    /// Antigravity 는 헤드리스에서 승인을 물을 방법이 없어 자동 승인으로만 동작한다.
    var routesApprovalsToApp: Bool { self != .gemini }

    /// 파일을 바꾸지 못하는 턴(`AgentTurnRequest.readOnly`)을 **보장**할 수 있는 제공자인지.
    /// Claude 는 쓰기 도구를 빼고, Codex 는 읽기 전용 샌드박스로 돈다 (둘 다 실측).
    /// Antigravity 는 헤드리스에서 자동 승인으로만 돌고 `--sandbox` · `--mode plan` 으로도 편집 도구가 파일을 쓴다.
    var supportsReadOnlyTurns: Bool { self != .gemini }
}

// MARK: - Codex 계정

/// 실행 주체. Claude 는 계정 구분이 없고, Codex 는 계정(`CODEX_HOME`)별로 갈린다.
/// 모델 목록 캐시와 한도 스냅샷을 이 단위로 보관한다.
struct AgentScope: Hashable, Codable, Sendable {
    var provider: AgentProvider
    /// Codex 계정 ID. Claude 이면 빈 문자열.
    var accountID: String

    static let claude = AgentScope(provider: .claude, accountID: "")
    static let gemini = AgentScope(provider: .gemini, accountID: "")
    static func codex(_ accountID: String) -> AgentScope {
        AgentScope(provider: .codex, accountID: accountID)
    }
}

/// `auth.json` 에서 읽은 로그인 상태.
///
/// 앱은 이 파일을 **읽기만** 한다. 토큰을 복사·저장·전송하지 않는다.
enum CodexAuthStatus: String, Codable, Sendable {
    case loggedIn        // auth.json 이 있고 토큰이 들어 있다
    case notLoggedIn     // auth.json 이 없다
    case unreadable      // 파일은 있으나 형식을 해석하지 못했다

    var koreanName: String {
        switch self {
        case .loggedIn: return "로그인됨"
        case .notLoggedIn: return "로그인 필요"
        case .unreadable: return "확인 불가"
        }
    }
}

/// Codex 계정 하나. 계정의 실체는 `CODEX_HOME` 디렉터리다.
///
/// 같은 Mac 에서 계정을 번갈아 쓰려면 홈을 나눠야 한다. 홈에는 인증(`auth.json`)과 세션 기록(`sessions/` · SQLite)이 함께 있다.
/// 대화의 Codex 세션은 처음 만든 계정의 홈(기록 폴더 — `AgentSession.recordHome`)에 남고, 다른 계정으로 보내면 그 실행만 인증을
/// 그 계정 것으로 바꿔 **같은 세션을 이어 간다** (`CodexRunHome` — 인계하지 않는다).
struct CodexAccount: Identifiable, Hashable, Codable, Sendable {
    /// CLI 기본 홈(`$CODEX_HOME` 또는 `~/.codex`)을 가리키는 계정의 고정 ID.
    /// 마이그레이션이 기존 기록을 이 ID 로 연결하므로 값을 바꾸면 안 된다.
    static let defaultID = "codex-default"

    var id: String = UUID().uuidString
    /// 사용자가 붙이는 이름. 이메일을 못 읽어도 계정을 구분할 수 있게 한다.
    var label: String
    /// `CODEX_HOME` 으로 넘길 절대 경로.
    var homePath: String
    var sortOrder: Int = 0
    var createdAt: Date = Date()

    // 아래는 캐시한 값이다. 토큰 자체는 보관하지 않는다. 로그인 여부 · `authMode` 는 auth.json 에서, 이메일 · 플랜은 한도를 읽을 때의
    // `account/read` 에서 (`CodexAccountService.applyAccountRead`), 계정 ID 는 둘 다에서.
    var authStatus: CodexAuthStatus = .notLoggedIn
    var email: String?
    var planType: String?
    var chatgptAccountID: String?
    /// chatgpt | apikey. CLI 가 쓰는 값을 그대로 둔다.
    var authMode: String?
    /// 더 쓰지 않는다 — 예전에 id_token 을 풀어 적던 만료 시각 (열은 옛 DB 와 맞추려고 남긴다, 늘 nil).
    var tokenExpiresAt: Date?
    var identityCheckedAt: Date?
    /// 식별에 실패한 이유. 실패를 "로그인 안 됨"으로 뭉뚱그리지 않는다.
    var identityNote: String?

    var isDefaultHome: Bool { id == CodexAccount.defaultID }

    /// 화면에 쓰는 짧은 설명. 이메일을 못 읽으면 추측하지 않는다.
    var identityText: String {
        if let email { return email }
        switch authStatus {
        // 이메일은 한도를 읽을 때 CLI 에게 묻는다 (`account/read`) — 아직이거나 받지 못했다. 로그인 여부는 옆의 상태가 말한다
        // ("로그인됨" 으로 적으면 계정 줄에 같은 말이 두 번 보였다). API 키 로그인은 이메일이 없다.
        case .loggedIn: return authMode == "apikey" ? "API 키 로그인" : "이메일 확인 전"
        case .notLoggedIn: return "로그인 필요"
        case .unreadable: return "확인 불가"
        }
    }

    var scope: AgentScope { .codex(id) }
}

/// 실행에 넘기는 계정 참조. RunCoordinator 가 계정 저장소를 몰라도 되도록 값만 전달한다.
struct CodexAccountRef: Hashable, Sendable {
    var id: String
    var label: String
    var homePath: String

    init(id: String, label: String, homePath: String) {
        self.id = id
        self.label = label
        self.homePath = homePath
    }

    init(_ account: CodexAccount) {
        self.init(id: account.id, label: account.label, homePath: account.homePath)
    }
}

// MARK: - 실행 상태

/// 실행 수명주기. 단순 boolean 조합 대신 명시적 상태 전이로 관리한다.
enum RunState: String, Codable, Sendable, CaseIterable {
    case idle                    // 대기
    case starting                // 시작 중
    case running                 // 실행 중
    case awaitingApproval        // 사용자 입력·승인 대기
    case interrupting            // 중단 중
    case completed               // 완료
    case cancelled               // 사용자 취소
    case failed                  // 오류
    case rateLimited             // 사용 한도 도달
    case handoffDrafting         // 인계 초안 검토
    case handoffSending          // 인계 전송 중
    case handoffDeliveryUnknown  // 전달 여부 미확인

    var koreanName: String {
        switch self {
        case .idle: return "대기"
        case .starting: return "시작 중"
        case .running: return "실행 중"
        case .awaitingApproval: return "승인 대기"
        case .interrupting: return "중단 중"
        case .completed: return "완료"
        case .cancelled: return "사용자 취소"
        case .failed: return "오류"
        case .rateLimited: return "사용 한도 도달"
        case .handoffDrafting: return "인계 초안 검토"
        case .handoffSending: return "인계 전송 중"
        case .handoffDeliveryUnknown: return "전달 여부 미확인"
        }
    }

    /// 프로세스가 아직 살아 있을 수 있는 상태.
    var isActive: Bool {
        switch self {
        case .starting, .running, .awaitingApproval, .interrupting, .handoffSending:
            return true
        default:
            return false
        }
    }

    /// 더 이상 진행되지 않는 상태.
    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed, .rateLimited, .handoffDeliveryUnknown:
            return true
        default:
            return false
        }
    }

    var symbolName: String {
        switch self {
        case .idle: return "circle"
        case .starting: return "circle.dotted"
        case .running: return "play.circle.fill"
        case .awaitingApproval: return "hand.raised.circle.fill"
        case .interrupting: return "stop.circle"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .rateLimited: return "gauge.with.dots.needle.bottom.0percent"
        case .handoffDrafting: return "square.and.pencil.circle"
        case .handoffSending: return "paperplane.circle"
        case .handoffDeliveryUnknown: return "questionmark.circle"
        }
    }

    /// 허용된 상태 전이만 통과시킨다. 시작 중 들어온 중단 요청을 유실하지 않도록
    /// starting -> interrupting 을 명시적으로 허용한다.
    func canTransition(to next: RunState) -> Bool {
        if self == next { return true }
        switch self {
        case .idle:
            return next == .starting || next == .failed || next == .cancelled
        case .starting:
            return [.running, .awaitingApproval, .interrupting, .failed,
                    .cancelled, .rateLimited, .completed].contains(next)
        case .running:
            return [.awaitingApproval, .interrupting, .completed, .failed,
                    .cancelled, .rateLimited].contains(next)
        case .awaitingApproval:
            return [.running, .interrupting, .completed, .failed,
                    .cancelled, .rateLimited].contains(next)
        case .interrupting:
            return [.cancelled, .completed, .failed, .rateLimited].contains(next)
        case .handoffDrafting:
            return [.handoffSending, .idle, .cancelled].contains(next)
        case .handoffSending:
            return [.completed, .failed, .handoffDeliveryUnknown, .cancelled].contains(next)
        case .completed, .cancelled, .failed, .rateLimited, .handoffDeliveryUnknown:
            return next == .idle || next == .starting
        }
    }
}

// MARK: - 모델 선택

/// CLI 가 실제로 보고한 모델 하나.
/// 이름을 앱이 추측하지 않고, 설치된 CLI 에서 조회한 값만 쓴다.
struct AgentModelOption: Identifiable, Hashable, Codable, Sendable {
    var id: String { "\(provider.rawValue)|\(identifier)" }
    var provider: AgentProvider
    /// CLI 에 그대로 넘기는 값 (Codex: `gpt-6-astra`, Claude: `opus` 같은 별칭 또는 전체 ID).
    var identifier: String
    var displayName: String
    var detail: String?
    /// 이 모델이 지원하는 추론 강도. 비어 있으면 강도 선택을 제공하지 않는다.
    var supportedEfforts: [String] = []
    var defaultEffort: String?
    var isDefault: Bool = false
    /// CLI 에서 조회한 값인지, 조회 실패로 쓰는 대체 목록인지.
    var isDiscovered: Bool = true
}

/// 스레드에 저장하는 모델 선택. 비어 있으면 CLI 기본값을 그대로 쓴다.
struct ModelSelection: Hashable, Codable, Sendable {
    /// nil = CLI 기본값 사용 (앱이 `--model` 을 넘기지 않는다).
    /// Codex 의 `gpt-*-sol` 은 계열 선택 — 보낼 때 그 계열의 최신 ID 로 푼다 (`ModelCatalog.resolveModel`).
    var model: String?
    var effort: String?

    var isDefault: Bool { model == nil && effort == nil }

    func label(catalog: [AgentModelOption]) -> String {
        guard let model else { return "기본값" }
        let name = ModelCatalog.option(for: model, in: catalog)?.displayName
            ?? ModelCatalog.unresolvedFamilyName(model, listEmpty: catalog.isEmpty) ?? model
        guard let effort else { return name }
        return "\(name) · \(effort)"
    }
}

/// 제공자별 모델 목록과 조회 상태.
struct ModelCatalogSnapshot: Hashable, Codable, Sendable {
    var provider: AgentProvider
    /// Codex 계정 ID. 계정마다 사용 가능한 모델이 다를 수 있어 목록을 따로 캐시한다.
    var accountID: String = ""
    var options: [AgentModelOption] = []
    var fetchedAt: Date?
    /// 조회 실패 사유. 목록이 대체값일 때 사용자에게 보여준다.
    var message: String?
    var discovered: Bool = false

    var scope: AgentScope { AgentScope(provider: provider, accountID: accountID) }
}

// MARK: - 저장 엔터티

struct Project: Identifiable, Hashable, Codable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var path: String
    var createdAt: Date = Date()
    var sortOrder: Int = 0

    var url: URL { URL(fileURLWithPath: path) }
}

/// 대화 하나만의 작업 폴더 — 프로젝트 저장소에서 가지를 쳐 만든 git worktree (`Workspace/Worktrees.swift`).
/// 같은 프로젝트의 여러 대화가 서로의 편집을 덮지 않고 동시에 일한다. 끝나면 본 폴더의 브랜치로 합치고 정리한다.
struct ThreadWorktree: Codable, Hashable, Sendable {
    /// 작업 폴더의 절대 경로 (`~/.agent-handoff-console/worktrees/<저장소>/<대화>`).
    var path: String
    /// 이 폴더의 브랜치 (`ahc/<대화 앞 8자>`).
    var branch: String
    /// 가지를 친 본 폴더의 브랜치 (합칠 곳의 기본값). 본 폴더가 브랜치 없이(detached) 있었으면 nil.
    var baseBranch: String?
    /// 가지를 친 커밋 — 이 대화가 한 일의 비교 기준.
    var baseCommit: String
}

struct ConversationThread: Identifiable, Hashable, Codable, Sendable {
    var id: String = UUID().uuidString
    var projectID: String
    var title: String
    /// 인계 초안의 "현재 목표" 기본 재료. 추가 모델 호출 없이 사용된다.
    var goal: String = ""
    /// 고정 메모: 제약/변경 금지 사항. 인계 초안에 항상 포함된다.
    var pinnedNotes: String = ""
    var preferredProvider: AgentProvider = .claude
    /// 이 대화의 Codex 를 실행할 계정 (로그인 · 한도 · 모델 목록). 세션은 계정이 바뀌어도 대화의 것 하나다 (`AgentSession.recordHome`).
    var codexAccountID: String = CodexAccount.defaultID
    /// 제공자별 모델 선택. 비어 있으면 CLI 기본값.
    var claudeSelection = ModelSelection()
    var codexSelection = ModelSelection()
    var geminiSelection = ModelSelection()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var archived: Bool = false
    /// 오케스트레이션이 만든 내부 대화면 그 전체 작업의 ID. 사이드바 · 검색 · 가져오기에는 나오지 않고
    /// 부모 대화의 작업 상세에서 연다. 보통 대화는 nil.
    var orchestrationJobID: String?
    /// 내부 대화의 역할: planner · reviewer · task.
    var orchestrationRole: String?
    /// 이 대화만의 작업 폴더 (git worktree). 있으면 에이전트 · Git · 인스펙터가 프로젝트 폴더 대신 이 폴더에서 일한다
    /// (`AppModel.folderProject(for:)`). nil 이면 프로젝트 폴더.
    var worktree: ThreadWorktree?

    var isInternal: Bool { orchestrationJobID != nil }

    func selection(for provider: AgentProvider) -> ModelSelection {
        switch provider {
        case .claude: return claudeSelection
        case .codex: return codexSelection
        case .gemini: return geminiSelection
        }
    }

    /// 이 스레드에서 제공자가 실행되는 범위. 모델 목록과 한도를 이 키로 찾는다.
    func scope(for provider: AgentProvider) -> AgentScope {
        switch provider {
        case .claude: return .claude
        case .codex: return .codex(codexAccountID)
        case .gemini: return .gemini
        }
    }

    /// 실행 · 인계를 보낸 뒤 스레드에 남기는 칸 — `Store.recordThreadSend` 와 같은 규칙 (메모리에 먼저 적용해, 저장 · 다시 읽기
    /// 사이에 도는 다른 행 전체 저장이 이 칸들을 옛 값으로 되돌리지 않게):
    /// 보낸 에이전트(`onlyIfProviderWas` 가 있으면 지금 값이 그것일 때만 — 시작하는 동안 사용자가 누른 에이전트 토글을 지킨다),
    /// 자리표시 제목일 때만 제목, 그 제공자의 모델이 비어 있을(nil · "default") 때만 채움, 준 계정만. 강도는 건드리지 않는다.
    /// 자리 표시 제목 — 첫 메시지로 제목을 채우고, 커밋 메시지 미리 채우기에서 뺀다. 판정은 여기 한 곳에서 한다:
    /// 문구를 번역하거나 바꿔도 옛 대화의 제목(저장된 한국어)을 계속 알아보도록, 새 자리 표시 문구는 이 집합에 더한다.
    static let placeholderTitles: Set<String> = ["새 스레드", "새 대화"]
    var hasPlaceholderTitle: Bool { Self.placeholderTitles.contains(title) }

    /// 새 대화의 에이전트 · Codex 계정. 같은 프로젝트에서 마지막에 쓴 대화의 것 → 없으면 다른 프로젝트에서 마지막에 쓴 것 →
    /// Claude. 그 에이전트의 CLI 가 이 Mac 에서 쓸 수 없다고 **확인됐으면** 쓸 수 있는 첫 에이전트(Claude → Codex)로 바꾼다
    /// (`usable` 이 nil = 아직 확인 전이면 그대로). Codex 만 쓰는 사람이 대화마다 에이전트를 바꾸지 않게 한다.
    /// Antigravity 는 승인 없이 실행되므로 이 프로젝트에서 허용했을 때만 이어받는다.
    static func initialAgent(projectID: String, recent: [ConversationThread],
                             usable: (AgentProvider) -> Bool?, allowsGemini: Bool)
        -> (provider: AgentProvider, codexAccountID: String?) {
        let ordered = recent.sorted { $0.updatedAt > $1.updatedAt }
        let last = ordered.first { $0.projectID == projectID } ?? ordered.first
        var provider = last?.preferredProvider ?? .claude
        if provider == .gemini, !allowsGemini { provider = .claude }
        if usable(provider) == false,
           let installed = [AgentProvider.claude, .codex].first(where: { usable($0) == true }) {
            provider = installed
        }
        let account = provider == .codex && last?.preferredProvider == .codex ? last?.codexAccountID : nil
        return (provider, account)
    }

    mutating func recordSend(provider: AgentProvider, onlyIfProviderWas expected: AgentProvider?,
                             placeholderTitle: String?, filledModel: String?, codexAccountID: String?) {
        if expected == nil || preferredProvider == expected { preferredProvider = provider }
        if let placeholderTitle, hasPlaceholderTitle { title = placeholderTitle }
        if let filledModel {
            var selection = self.selection(for: provider)
            if selection.model == nil || selection.model == "default" {
                selection.model = filledModel
                setSelection(selection, for: provider)
            }
        }
        if let codexAccountID { self.codexAccountID = codexAccountID }
    }

    mutating func setSelection(_ selection: ModelSelection, for provider: AgentProvider) {
        switch provider {
        case .claude: claudeSelection = selection
        case .codex: codexSelection = selection
        case .gemini: geminiSelection = selection
        }
    }
}

/// 앱 대화 하나에 제공자별로 하나씩 연결되는 외부 CLI 세션 (계정 칸 `accountID` 는 "").
///
/// Codex 도 계정마다가 아니라 대화마다 하나다 (스키마 v10): 세션 기록은 그 세션을 만든 계정의 `CODEX_HOME`(`recordHome`)에 있고,
/// 다른 계정으로 보내면 그 실행만 그 계정의 인증으로 같은 세션을 재개한다 (`CodexRunHome`). v10 전에는 (대화, 제공자, Codex 계정)
/// 칸마다 따로였다 — 그 옛 칸(`accountID` = 계정 ID)은 옛 빌드 · 기록 가져오기의 중복 확인을 위해 남는다.
struct AgentSession: Identifiable, Hashable, Codable, Sendable {
    var id: String = UUID().uuidString
    var threadID: String
    var provider: AgentProvider
    /// 언제나 "". v10 전의 Codex 칸만 그 계정 ID 를 가진다 (앱은 더 읽지 않는다).
    var accountID: String = ""
    /// Claude: --session-id / --resume 로 쓰는 UUID. Codex: app-server threadId.
    var cliSessionID: String?
    var cliVersion: String?
    /// 이 세션에 앱 대화의 어느 지점(Event.seq)까지 전달했는지.
    var lastDeliveredSeq: Int64 = 0
    /// 마지막으로 재개에 성공했는지. 실패하면 새 세션으로 복구한다.
    var resumable: Bool = true
    var lastError: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Codex: 이 세션의 기록이 있는 `CODEX_HOME` (기록 폴더 — 세션을 만든 계정의 홈). nil 이면 모른다 — 실행 계정의 홈으로 본다
    /// (v10 전의 기록 · 계정 목록에 없는 계정). 다른 제공자는 nil.
    var recordHome: String?
}

struct Run: Identifiable, Hashable, Codable, Sendable {
    var id: String = UUID().uuidString
    var threadID: String
    var sessionID: String
    var provider: AgentProvider
    var requestText: String
    var state: RunState = .idle
    var startedAt: Date = Date()
    var endedAt: Date?
    /// CLI가 보고한 종료 이유 원문 (claude: terminal_reason, codex: turn.status).
    var terminalReason: String?
    var model: String?
    var errorMessage: String?
    /// 실행 도중 앱이 시작한 자식 프로세스 PID 기록 (앱이 시작한 것만 다룬다).
    var childProcessNote: String?
    /// 인계 전송을 위해 만들어진 실행인지.
    var isHandoffDelivery: Bool = false
    /// 이 실행이 사용한 Codex 계정. Claude 실행은 nil.
    var codexAccountID: String?

    var durationMs: Int? {
        guard let endedAt else { return nil }
        return Int(endedAt.timeIntervalSince(startedAt) * 1000)
    }
}

enum EventKind: String, Codable, Sendable {
    case userMessage
    case agentMessage
    case agentReasoning
    case toolRequest
    case toolResult
    case fileChange
    case commandExecution
    case approvalRequest
    case approvalDecision
    case userQuestion
    case error
    case systemNotice
    case handoffSent
    case handoffReceived
    case rateLimitNotice
    /// 하위 에이전트 · 워크플로 · 백그라운드 작업 하나의 상태 (`payloadJSON` = `SubAgentInfo`).
    /// 작업마다 행 하나를 같은 ID(`ThreadEvent.subAgentEventID`)로 덮어쓴다. 대화 행이 아니다 — 화면은 카드로 그린다.
    case subAgent

    var koreanName: String {
        switch self {
        case .userMessage: return "사용자"
        case .agentMessage: return "응답"
        case .agentReasoning: return "추론 요약"
        case .toolRequest: return "도구 요청"
        case .toolResult: return "도구 결과"
        case .fileChange: return "파일 변경"
        case .commandExecution: return "명령 실행"
        case .approvalRequest: return "승인 요청"
        case .approvalDecision: return "승인 결정"
        case .userQuestion: return "사용자 질문"
        case .error: return "오류"
        case .systemNotice: return "안내"
        case .handoffSent: return "인계 전송"
        case .handoffReceived: return "인계 수신"
        case .rateLimitNotice: return "한도 정보"
        case .subAgent: return "하위 에이전트"
        }
    }
}

struct ThreadEvent: Identifiable, Hashable, Codable, Sendable {
    var id: String = UUID().uuidString
    var threadID: String
    var runID: String?
    /// 스레드 내 단조 증가 순서. 인계 기준점(lastDeliveredSeq)으로 사용한다.
    var seq: Int64 = 0
    var kind: EventKind
    var provider: AgentProvider?
    var title: String = ""
    var text: String = ""
    /// 원본 CLI 이벤트나 구조화 정보를 담는 JSON 문자열.
    var payloadJSON: String?
    var toolUseID: String?
    var createdAt: Date = Date()
    /// 스트리밍 중 갱신되는 이벤트인지 (완료되면 false).
    var isStreaming: Bool = false

    var isCollapsibleByDefault: Bool {
        switch kind {
        case .toolResult, .commandExecution, .fileChange, .agentReasoning:
            return true
        default:
            return text.count > 1200
        }
    }
}

// MARK: - 하위 에이전트 · 백그라운드 작업

/// 한 턴이 띄운 하위 작업 하나 — Claude 의 Agent · Workflow · 백그라운드 셸, Codex 의 하위 에이전트 스레드 ·
/// 백그라운드 터미널. 어댑터가 `AgentEvent.subAgent` 로 알리고, `RunSession` 이 `.subAgent` 이벤트로 저장한다.
///
/// `id` 는 **메인 흐름에서 이 작업을 띄운 도구 행의 `toolUseID`** 와 같게 맞춘다 — 화면이 그 행에 카드를 붙인다.
/// Claude: Agent · Workflow · Bash 호출의 `tool_use_id` (자식 메시지의 `parent_tool_use_id` 와 같다).
/// Codex 하위 에이전트: 하위 스레드 ID (어댑터가 같은 ID 로 메인 흐름에 도구 행을 하나 낸다).
/// Codex 백그라운드 명령: 명령 항목 ID.
struct SubAgentInfo: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case agent, workflow, shell, other }
    enum Status: String, Codable, Sendable {
        case running, completed, stopped, failed
        var isFinished: Bool { self != .running }
    }

    var id: String
    /// 작업 하나 멈추기에 쓰는 CLI 의 작업 ID (Claude `task_id`). 멈추기를 제공하지 않으면 nil.
    var taskID: String?
    var kind: Kind
    /// 사람이 읽는 이름 — 설명 · agentPath 의 마지막 이름 · 명령.
    var title: String
    /// 보조 정보 — subagent_type · workflow_name · agentPath · 별명.
    var detail: String?
    /// 이 작업을 띄운 하위 에이전트의 `id` (하위 에이전트가 띄운 셸 등). 메인이 띄웠으면 nil.
    var ownerID: String?
    /// 메인 턴이 끝나도 남을 수 있는 작업 (백그라운드). 메인이 기다리는 하위 에이전트는 false.
    var isBackground: Bool
    var status: Status = .running
    var startedAt: Date
    var endedAt: Date?
    /// 마지막 진행 설명. 자주 바뀐다 — 화면에만 쓰고 이것만 바뀌었을 때는 저장하지 않는다.
    var progress: String?
    var lastToolName: String?
    /// 처리 토큰 — 캐시에서 다시 읽은 것까지 센 양 (Claude 작업의 `usage.total_tokens`, Codex 하위 스레드는 입력 + 캐시 + 출력).
    /// 하위끼리 · 메인과 견주는 값이다 (`TokenShare`). Claude 는 새 토큰과 캐시를 나눠 주지 않는다.
    var totalTokens: Int?
    var toolUses: Int?
    /// 끝났을 때의 요약 또는 최종 답.
    var summary: String?
    /// 이 작업을 한 모델 — CLI 가 알려 줄 때만 (Claude 는 하위 안의 메시지 `message.model`, 백그라운드 하위는 메시지가
    /// 오지 않아 모를 수 있다). 모르면 nil.
    var model: String?
    /// 새 토큰(캐시를 뺀 입력 + 출력) — 나눠 알 수 있을 때만 (Codex 하위 스레드). Claude 하위는 nil.
    var newTokens: Int?

    /// 작업 하나 멈추기를 제공하는가 (CLI 가 지원할 때만 — 지금은 Claude `stop_task`).
    var canStop: Bool { taskID != nil && status == .running }

    /// 앞에서 돈 셸 — 하위 에이전트가 끝나기를 기다리며 돌린 명령 하나. Claude 는 하위 안에서 앞에서 돈 Bash 도
    /// `local_bash` 작업으로 알린다 (2026-09-24 실측, 2.1.270: 하위 다섯이 저마다 `sleep 10`). 그 하위의 흐름에 명령 행으로
    /// 이미 있고 턴이 끝나도 남지 않으므로 목록 · 카드 · 수에서 뺀다 (저장은 한다). 뒤로 넘어가면(`background_tasks_changed`
    /// 에 오르면) 트래커가 `isBackground` 를 켜 다시 보인다.
    var isInternalStep: Bool { kind == .shell && !isBackground }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    var jsonString: String {
        (try? Self.encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    init(id: String, taskID: String? = nil, kind: Kind, title: String, detail: String? = nil,
         ownerID: String? = nil, isBackground: Bool, status: Status = .running, startedAt: Date = Date(),
         endedAt: Date? = nil, progress: String? = nil, lastToolName: String? = nil,
         totalTokens: Int? = nil, toolUses: Int? = nil, summary: String? = nil, model: String? = nil,
         newTokens: Int? = nil) {
        self.id = id; self.taskID = taskID; self.kind = kind; self.title = title; self.detail = detail
        self.ownerID = ownerID; self.isBackground = isBackground; self.status = status
        self.startedAt = startedAt; self.endedAt = endedAt; self.progress = progress
        self.lastToolName = lastToolName; self.totalTokens = totalTokens; self.toolUses = toolUses
        self.summary = summary; self.model = model; self.newTokens = newTokens
    }

    init?(json: String?) {
        guard let data = json?.data(using: .utf8),
              let v = try? Self.decoder.decode(SubAgentInfo.self, from: data) else { return nil }
        self = v
    }

    /// 저장할 가치가 있는 변화인가 — 도는 동안 진행 설명 · 토큰 · 도구 수만 바뀐 것은 저장하지 않는다 (초당 여러 번 온다).
    /// 끝난 뒤에 온 토큰은 저장한다 — Codex 는 스레드의 사용량이 턴이 끝난 뒤에 올 수 있다.
    func differsForStorage(from old: SubAgentInfo) -> Bool {
        status != old.status || title != old.title || detail != old.detail || summary != old.summary
            || endedAt != old.endedAt || isBackground != old.isBackground || ownerID != old.ownerID
            || taskID != old.taskID || kind != old.kind || model != old.model
            || (status.isFinished && (totalTokens != old.totalTokens || newTokens != old.newTokens))
    }
}

extension ThreadEvent {
    /// 하위 에이전트 안에서 일어난 이벤트에 붙이는 `payloadJSON` 의 키. 값은 그 하위 에이전트의 `SubAgentInfo.id`.
    static let parentKey = "ahc.parent"

    /// 하위 에이전트 안에서 일어난 이벤트면 그 하위 에이전트의 ID, 메인 이벤트면 nil.
    /// 메인 흐름 · 인계 · 자동 작업의 "마지막 응답" 은 이것이 nil 인 이벤트만 본다.
    var parentAgentID: String? {
        guard let json = payloadJSON, json.contains("\"\(Self.parentKey)\"") else { return nil }
        return JSONUtil.object(json)?[Self.parentKey] as? String
    }

    /// 메인 흐름의 이벤트인가 — 하위 에이전트 안의 이벤트도, 하위 에이전트 상태 행도 아니다.
    var isMainStream: Bool { kind != .subAgent && parentAgentID == nil }

    /// 사용 한도 도달 안내인가 — 한도 안내 행이거나, 한도로 끝난 실행의 오류(옛 기록은 제목 "구독 한도 도달"). 대화의 한도 줄
    /// (`AlertRow`)과 이어 가기 제안의 숨김("마지막 메인 이벤트가 한도 안내")이 같은 판정을 쓴다. `run` 은 이 이벤트의 실행.
    func isLimitNotice(run: Run?) -> Bool {
        kind == .rateLimitNotice
            || (kind == .error && (run?.state == .rateLimited || title == LimitStatus.subscriptionCap.koreanName))
    }

    /// 자동 작업이 부모 대화에 남긴 사용자 메시지(요청 · 질문의 답)에 붙이는 `payloadJSON` 의 키 (값은 true).
    /// 그 일은 자동 작업이 맡았다 — 인계 초안의 "아직 처리되지 않은 사용자 지시" 에 넣지 않는다 (`HandoffPacketBuilder`).
    static let orchestrationRequestKey = "ahc.orchestration"

    /// 자동 작업에 준 사용자 메시지인가. 표시가 붙기 전의 옛 기록은 알 수 없어 false 다.
    var isOrchestrationRequest: Bool {
        guard kind == .userMessage, let json = payloadJSON, json.contains("\"\(Self.orchestrationRequestKey)\"") else { return false }
        return JSONUtil.object(json)?[Self.orchestrationRequestKey] as? Bool == true
    }

    /// `.subAgent` 이벤트의 정보.
    var subAgentInfo: SubAgentInfo? {
        guard kind == .subAgent else { return nil }
        return SubAgentInfo(json: payloadJSON)
    }

    /// 실행 하나의 하위 작업 하나를 나타내는 `.subAgent` 행의 ID (덮어쓰기용으로 고정).
    static func subAgentEventID(runID: String, agentID: String) -> String {
        "subagent-\(runID)-\(agentID)"
    }

    /// `payloadJSON` 에 부모 표시를 더한다. 기존 JSON 객체면 키를 더하고, 객체가 아니면 `raw` 로 감싼다.
    static func payload(_ json: String?, taggingParent parent: String) -> String {
        var object: [String: Any] = [:]
        if let json, !json.isEmpty {
            if let o = JSONUtil.object(json) { object = o } else { object["raw"] = json }
        }
        return payload(object, taggingParent: parent)
    }

    /// 같은 규칙의 객체판 — 실행기가 하위 이벤트를 저장할 때 메인 경로와 같은 payload 에 부모 표시만 더한다.
    static func payload(_ object: [String: Any], taggingParent parent: String) -> String {
        var object = object
        object[parentKey] = parent
        return JSONUtil.string(object)
    }
}

// MARK: - 승인 결정 기록

/// 에이전트의 질문 도구 (순수). Claude `AskUserQuestion` 은 승인 요청(`can_use_tool`)으로 오지만 사람의 **답**을 묻는다.
/// 고른 답을 돌려주는 길(`updatedInput`)은 실측하지 않아, 사람이 적은 답은 확인된 길 — 그 도구의 거절 글 자리 — 로 보낸다
/// (`ApprovalDecision.answer`). 기록은 그것을 거절이 아니라 답으로 남기고(`ApprovalDecisionInfo.Decision.answered`), 읽는 쪽은
/// 답이 거절로 적힌 옛 행도 답으로 읽는다(`ApprovalTrail`). 자동 승인은 질문을 대신 답하지 않는다(`ApprovalRequest.allowsAutoApproval`).
enum AskedQuestion {
    static let claudeToolName = "AskUserQuestion"

    static func isTool(_ toolName: String?) -> Bool { toolName == claudeToolName }

    /// 도구 입력(`questions: [{question, header, options, multiSelect}]`)의 질문 글. 모양이 다르면 빈 배열.
    static func texts(in input: [String: Any]?) -> [String] {
        guard let questions = input?["questions"] as? [[String: Any]] else { return [] }
        return questions.compactMap { ($0["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// 승인 결정 행(`.approvalDecision`)의 구조화된 내용 — `payloadJSON` 의 `"ahc.approval"` (2026-10-04 부터, `RunSession` 이 쓴다).
/// 행의 `toolUseID` 는 그 승인 요청(`ApprovalRequest.toolUseID`)의 값, `title` 은 "승인 결정", `text` 는 사람이 읽는 결정 이름
/// (`ApprovalDecision.koreanName` · "자동 허용" · "취소됨 (CLI)" …)이다. 읽는 쪽은 이 키가 없는 옛 행도 다룬다 —
/// 글로 짐작하고(`Decision.legacy`) 같은 실행의 요청 행과 짝짓는다(`ApprovalTrail`).
struct ApprovalDecisionInfo: Hashable, Sendable {
    enum Decision: String, Hashable, Sendable, CaseIterable {
        case allow, allowForSession, deny, denyAndCancel
        /// 묻던 요청이 거둬졌다 — CLI 가 거둠 · 물은 하위 작업이 끝남.
        case cancelled
        /// 사람이 그 하위 작업을 멈춰 앱이 거절로 닫았다.
        case stopped
        /// 대화의 자동 승인이 사람 대신 허용했다.
        case autoAllow
        /// 사람이 에이전트의 질문(`AskedQuestion`)에 적은 답을 보냈다 (`answer`). 거절이 아니다 — 실행 기록은 "답함",
        /// 인계 문서는 "사용자 답: …" 이고 "다시 하지 말 것" 이 붙지 않는다. CLI 에는 그 도구의 거절 글 자리로 갔다.
        case answered

        /// 사람이(또는 무인 실행의 앱이) 거절했다 — 그 도구는 실행되지 않았다.
        var isDenial: Bool { self == .deny || self == .denyAndCancel }
        /// 결정 없이 닫혔다 — 그 도구는 실행되지 않았다.
        var isWithdrawal: Bool { self == .cancelled || self == .stopped }

        /// 키가 없는 옛 행의 글로 짐작한다. 질문의 답("응답 전송") · 모르는 글은 nil — 승인 결정으로 세지 않는다.
        static func legacy(_ text: String) -> Decision? {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == "자동 허용" { return .autoAllow }
            if text == "답함" { return .answered }
            if text.contains("세션 동안 허용") || text.contains("실행 동안 허용") { return .allowForSession }
            if text.contains("거절 후 중단") { return .denyAndCancel }
            if text.contains("작업 멈춤") { return .stopped }
            if text.contains("거절") { return .deny }
            if text.contains("취소") { return .cancelled }
            if text.contains("허용") || text == "입력 보냄" { return .allow }
            return nil
        }
    }

    var decision: Decision
    /// 거절과 함께 에이전트에게 준 사유 (사람이 적은 것 · 무인 실행의 앱 안내). 없으면 nil.
    var reason: String?
    var requestTitle: String?
    var toolName: String?
    /// `ApprovalKind.rawValue`.
    var approvalKind: String?
    /// `ApprovalRequest.id` (어댑터의 요청 ID — Codex 는 실행마다 0 부터라 같은 실행 안에서만 유일하다).
    var requestID: String?
    /// 질문에 보낸 사람의 답 (`answered`). 없으면 nil.
    var answer: String? = nil

    /// 에이전트의 질문(`AskedQuestion`)에 대한 결정인가 — 결정 행에 적힌 도구 이름으로 (옛 행은 `ApprovalTrail` 이 요청 행으로 본다).
    var isQuestion: Bool { AskedQuestion.isTool(toolName) }

    /// 질문 도구에 "거절" 로 적힌 결정을 답으로 읽는다 — 2026-10-04 빌드는 질문 카드의 [적은 답 보내기] 를 거절 사유로 보내고
    /// 거절로 적었다 (2차 시험 conv-1). 글이 없는 거절 · [거절 후 중단] 은 그대로 거절이다. `text` 는 그 답의 글 — 결정 행의 사유,
    /// 사유가 없는 옛 행이면 CLI 가 도구 결과로 돌려준 글(앱의 기본 거절 문구가 아닌 것).
    func readingQuestionDenial(as text: String?) -> ApprovalDecisionInfo {
        guard decision == .deny, let text = Self.meaningful(text) else { return self }
        var read = self
        read.decision = .answered
        read.answer = text
        read.reason = nil
        return read
    }

    /// 무인 실행(검토 레인)이 승인 요청을 기다리지 않고 거절할 때 CLI 에 보내는 글 (`RunSession`).
    static let unattendedDenyMessage = "검토 실행은 승인을 기다리지 않습니다."

    /// 앱이 스스로 넣는 거절 문장 — 사람이 글을 적지 않았을 때 CLI 에 보내는 것(`ClaudeAdapter.permissionResponse` · `stopSubAgent`)과
    /// 무인 실행의 거절. 사람이 적은 사유 · 답이 아니다 (질문 도구를 무인 실행이 거절해도 답으로 읽지 않는다).
    /// 실행 기록(`ExecutionParser`) · 인계 문서(`HandoffPacketBuilder`)가 같은 목록을 쓴다.
    static let defaultDenyMessages: Set<String> = ["사용자가 거절했습니다.", "사용자가 거절하고 중단했습니다.", "사용자가 이 작업을 멈췄습니다.",
                                                   unattendedDenyMessage]

    /// 앞뒤 공백을 뺀 글. 비었거나 앱의 기본 거절 문장이면 nil.
    static func meaningful(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              !defaultDenyMessages.contains(trimmed) else { return nil }
        return trimmed
    }
}

extension ThreadEvent {
    /// 승인 결정 행의 `payloadJSON` 키 (`ApprovalDecisionInfo`).
    static let approvalDecisionKey = "ahc.approval"
    /// 승인 요청 행(`.approvalRequest`)의 `payloadJSON` 키 — `{"requestID": …, "toolName": …, "approvalKind": …}`.
    /// 결정 행과 정확히 짝짓는 데 쓴다 (옛 행에는 없다).
    static let approvalRequestKey = "ahc.approvalRequest"
    /// 답한 질문 행(`.userQuestion`)의 `payloadJSON` 키 (값은 true). 글에는 답이 함께 적혀 있다 (비밀 답은 가린다).
    static let questionAnsweredKey = "ahc.answered"

    /// 승인 결정 행의 구조화된 내용. 키가 없는 옛 행 · 다른 종류의 행은 nil (옛 행은 `ApprovalTrail` 이 글로 짐작한다).
    var approvalDecisionInfo: ApprovalDecisionInfo? {
        guard kind == .approvalDecision, let json = payloadJSON, json.contains("\"\(Self.approvalDecisionKey)\""),
              let object = JSONUtil.object(json)?[Self.approvalDecisionKey] as? [String: Any],
              let raw = object["decision"] as? String, let decision = ApprovalDecisionInfo.Decision(rawValue: raw) else { return nil }
        func text(_ key: String) -> String? { (object[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return ApprovalDecisionInfo(decision: decision, reason: text("reason"), requestTitle: text("requestTitle"),
                                    toolName: text("toolName"), approvalKind: text("approvalKind"), requestID: text("requestID"),
                                    answer: text("answer"))
    }

    /// 승인 결정 행의 `payloadJSON`. 사유 · 답이 없으면 키를 뺀다.
    static func approvalDecisionPayload(_ info: ApprovalDecisionInfo) -> String {
        var object: [String: Any] = ["decision": info.decision.rawValue]
        if let reason = info.reason, !reason.isEmpty { object["reason"] = reason }
        if let answer = info.answer, !answer.isEmpty { object["answer"] = answer }
        object["requestTitle"] = info.requestTitle
        object["toolName"] = info.toolName
        object["approvalKind"] = info.approvalKind
        object["requestID"] = info.requestID
        return JSONUtil.string([approvalDecisionKey: object])
    }

    /// 승인 요청 행의 `payloadJSON`.
    static func approvalRequestPayload(requestID: String, toolName: String, approvalKind: String) -> String {
        JSONUtil.string([approvalRequestKey: ["requestID": requestID, "toolName": toolName, "approvalKind": approvalKind]])
    }

    /// 승인 요청 행의 요청 ID (`ApprovalRequest.id`). 옛 행은 nil.
    var approvalRequestID: String? { approvalRequestField("requestID") }

    /// 승인 요청 행이 에이전트의 질문(`AskedQuestion`)인가. 요청 행에 적힌 도구 이름을, 그 표시가 없는 옛 행은 입력의 모양
    /// (`questions[].question` — 행의 글은 요청 입력의 JSON)을 본다.
    var isQuestionRequest: Bool {
        guard kind == .approvalRequest else { return false }
        if let toolName = approvalRequestField("toolName") { return AskedQuestion.isTool(toolName) }
        return provider == .claude && !AskedQuestion.texts(in: JSONUtil.object(text)).isEmpty
    }

    private func approvalRequestField(_ key: String) -> String? {
        guard kind == .approvalRequest, let json = payloadJSON, json.contains("\"\(Self.approvalRequestKey)\"") else { return nil }
        return (JSONUtil.object(json)?[Self.approvalRequestKey] as? [String: Any])?[key] as? String
    }

    /// 답한 질문 행인가.
    var isAnsweredQuestion: Bool {
        guard kind == .userQuestion, let json = payloadJSON, json.contains("\"\(Self.questionAnsweredKey)\"") else { return false }
        return JSONUtil.object(json)?[Self.questionAnsweredKey] as? Bool == true
    }
}

/// 기록의 승인 요청 행과 결정 행을 짝짓는다 (순수). 새 행은 요청 ID · 도구 호출 ID 로, 키가 없는 옛 행은 같은 실행에서 바로 앞의
/// 아직 결정이 없는 요청과 짝짓는다. 실행 기록(`ExecutionParser`)이 도구 행에 "승인 대기" · "거절함" · "답함" 을 붙이고, 인계 문서
/// (`HandoffPacketBuilder.approvalNotes`)가 결정을 옮길 때 쓴다 — 둘이 같은 결정을 읽는다.
/// 질문 도구(`AskedQuestion`)에 거절로 적힌 결정은 글이 있으면 답으로 읽는다 (`ApprovalDecisionInfo.readingQuestionDenial`).
struct ApprovalTrail {
    struct Resolution: Hashable {
        /// 읽는 쪽이 쓸 결정 — 질문의 답이 거절로 적힌 옛 행은 `answered` 로 고쳐 읽었다.
        var info: ApprovalDecisionInfo
        /// 짝지은 요청 행의 ID. 짝이 없으면 nil.
        var requestEventID: String?
        /// 결정이 닿는 도구 호출 ID — 결정 행의 것, 없으면 짝지은 요청 행의 것.
        var toolUseID: String?
        /// 에이전트의 질문(`AskedQuestion`)에 대한 결정이다 — 결정 행의 도구 이름, 없으면 짝지은 요청 행으로 본다.
        var isQuestion = false
        /// 거절 · 답 바로 뒤의 같은 도구 호출의 오류 결과 행 — CLI 는 거절 사유 · 답을 그 도구의 오류 결과로 돌려준다.
        /// 실패가 아니다 (인계 문서의 실패 목록에서 거른다).
        var echoEventID: String?
        /// 결정 행에 구조화된 내용이 없는 옛 행.
        var isLegacy = false
    }

    /// 결정 행 ID → 결정. 질문의 답 · 모르는 글의 결정 행은 들지 않는다.
    var decisions: [String: Resolution] = [:]
    /// 결정이 없는 요청 행 ID — 승인 카드가 아직 떠 있거나, 답 없이 실행이 끝났다.
    var openRequestIDs: Set<String> = []
    /// 도구 호출 ID → 그 호출의 마지막 결정.
    var byToolUseID: [String: Resolution] = [:]
    /// 결정이 없는 요청이 기다리는 도구 호출 ID.
    var awaitingToolUseIDs: Set<String> = []

    init(_ events: [ThreadEvent]) {
        var open: [ThreadEvent] = []
        // 거절 · 답의 결과를 기다리는 도구 호출 ID → 그 결정 행 ID (첫 결과 하나만 본다).
        var echoWaiters: [String: String] = [:]
        // 도구 호출 ID → 그 호출의 마지막 결정 행 ID.
        var lastDecision: [String: String] = [:]
        for event in events {
            switch event.kind {
            case .approvalRequest:
                open.append(event)
            case .approvalDecision:
                let stored = event.approvalDecisionInfo
                guard var info = stored ?? ApprovalDecisionInfo.Decision.legacy(event.text).map({
                    ApprovalDecisionInfo(decision: $0)
                }) else { continue }
                let sameRun = open.indices.filter { open[$0].runID == event.runID }
                let index: Int?
                if let requestID = info.requestID,
                   let found = sameRun.last(where: { open[$0].approvalRequestID == requestID }) {
                    index = found
                } else if let toolUseID = event.toolUseID {
                    index = sameRun.last { open[$0].toolUseID == toolUseID }
                } else if stored == nil {
                    // 옛 행: 같은 실행에서 바로 앞의 아직 결정이 없는 요청.
                    index = sameRun.last
                } else {
                    index = nil
                }
                let request = index.map { open.remove(at: $0) }
                let isQuestion = info.isQuestion || request?.isQuestionRequest == true
                if isQuestion { info = info.readingQuestionDenial(as: info.reason) }
                let resolution = Resolution(info: info, requestEventID: request?.id,
                                            toolUseID: event.toolUseID ?? request?.toolUseID,
                                            isQuestion: isQuestion, isLegacy: stored == nil)
                decisions[event.id] = resolution
                if let toolUseID = resolution.toolUseID {
                    lastDecision[toolUseID] = event.id
                    if info.decision.isDenial || info.decision == .answered { echoWaiters[toolUseID] = event.id }
                }
            case .toolResult:
                guard let toolUseID = event.toolUseID, let decisionID = echoWaiters.removeValue(forKey: toolUseID),
                      var resolution = decisions[decisionID], event.title.hasSuffix("— 오류") else { continue }
                resolution.echoEventID = event.id
                // 사유가 없는 옛 행: 질문에 적은 답은 CLI 가 돌려준 결과의 글에만 남아 있다.
                if resolution.isQuestion, resolution.isLegacy, resolution.info.reason == nil {
                    resolution.info = resolution.info.readingQuestionDenial(as: event.text)
                }
                decisions[decisionID] = resolution
            default:
                continue
            }
        }
        byToolUseID = lastDecision.compactMapValues { decisions[$0] }
        openRequestIDs = Set(open.map(\.id))
        awaitingToolUseIDs = Set(open.compactMap(\.toolUseID))
    }
}

// MARK: - 인계

enum HandoffDeliveryState: String, Codable, Sendable {
    case draft          // 초안
    case sending        // 전송 중
    case delivered      // 대상이 수신하고 턴을 시작함
    case failed         // 전송 실패 (수신 안 됨이 확인됨)
    case unknown        // 전달 여부 미확인

    var koreanName: String {
        switch self {
        case .draft: return "초안"
        case .sending: return "전송 중"
        case .delivered: return "전달 확인"
        case .failed: return "전송 실패"
        case .unknown: return "전달 여부 미확인"
        }
    }
}

/// 인계 패킷의 구조화 표현. 앱이 판단할 수 없는 항목은 nil/미확인으로 남긴다.
struct HandoffPacket: Codable, Hashable, Sendable {
    /// v3 에서 Gemini 보조 요약의 출처와 검증 경고가 추가됐다.
    /// 새 항목은 모두 Optional 이라 이전 패킷도 그대로 읽힌다.
    static let currentVersion = 3

    var version: Int = HandoffPacket.currentVersion
    var goal: String
    var constraints: String
    var completed: [String]
    var inProgress: [String]
    var decisions: [String]
    var failedAttempts: [String]
    var changedFiles: GitSnapshot
    var testsRun: [String]
    var interrupted: [String]
    var nextActions: [String]
    var references: [String]
    /// 앱이 확인하지 못한 항목 목록. 사용자가 채우거나 미확인으로 남긴다.
    var unverified: [String]
    /// 발췌된 최근 대화 (참고 자료). 새 사용자 명령과 구분해 전달한다.
    var transcriptExcerpt: String
    var generatedAt: Date = Date()
    var fromProvider: AgentProvider
    var toProvider: AgentProvider
    /// Codex 계정 이름. 같은 Codex 안에서 계정을 넘길 때 누구에게서 누구에게인지 밝힌다.
    /// v1 패킷에는 없으므로 Optional 이다.
    var fromAccountLabel: String?
    var toAccountLabel: String?
    var baseSeq: Int64
    /// nil/"rule" 은 규칙 초안, "gemini" 는 검증을 통과한 Gemini 요약이다.
    var summarySource: String?
    var assistModel: String?
    var assistWarnings: [String]?

    /// 제공자와 계정을 함께 읽는 표시용 이름.
    static func partyName(_ provider: AgentProvider, _ accountLabel: String?) -> String {
        guard let accountLabel, !accountLabel.isEmpty else { return provider.displayName }
        return "\(provider.displayName) · \(accountLabel)"
    }
}

struct Handoff: Identifiable, Hashable, Codable, Sendable {
    var id: String = UUID().uuidString
    var threadID: String
    var fromProvider: AgentProvider
    var toProvider: AgentProvider
    /// Codex 계정 ID. Claude 쪽은 빈 문자열.
    var fromAccountID: String = ""
    var toAccountID: String = ""
    var fromSessionID: String?
    var toSessionID: String?
    /// 이 인계가 대상에게 전달한 앱 대화의 마지막 지점.
    var baseSeq: Int64
    var packetVersion: Int = HandoffPacket.currentVersion
    var draftJSON: String
    /// 사용자가 확인/수정한 최종 전송 텍스트.
    var finalText: String
    var deliveryState: HandoffDeliveryState = .draft
    /// 로컬 중복 전송 방지용 식별자. 프로토콜이 exactly-once를 보장하지는 않는다.
    var localToken: String = UUID().uuidString
    var deliveryRunID: String?
    var createdAt: Date = Date()
    var sentAt: Date?
    var note: String?
}

// MARK: - 사용량 / 비용

enum CostSource: String, Codable, Sendable {
    case cliReported     // CLI가 직접 반환한 값 (Claude modelUsage.costUSD)
    case appCalculated   // 앱이 가격표로 계산
    case unknown         // 가격 미확인

    var koreanName: String {
        switch self {
        case .cliReported: return "CLI 보고"
        case .appCalculated: return "앱 계산"
        case .unknown: return "금액 미확인"
        }
    }
}

/// 턴 단위(사용자 요청 1회 + 도구 실행 + 최종 응답) 사용량.
struct UsageRecord: Identifiable, Hashable, Codable, Sendable {
    var id: String = UUID().uuidString
    var runID: String
    var threadID: String
    var provider: AgentProvider
    var model: String?
    var inputTokens: Int = 0          // 캐시 토큰을 제외한 순수 입력
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var outputTokens: Int = 0
    /// 출력의 부분집합(추론 토큰). 합계에 중복 더하지 않는다.
    var reasoningTokens: Int = 0
    var durationMs: Int = 0
    var costUSD: Double?
    var costSource: CostSource = .unknown
    var priceCatalogVersion: String?
    /// 중단 등으로 사용량이 불완전하면 false.
    var confirmed: Bool = true
    var createdAt: Date = Date()

    /// 화면 표시용 총 토큰. 입력 + 캐시읽기 + 캐시쓰기 + 출력.
    /// reasoningTokens 는 outputTokens 의 부분집합이므로 더하지 않는다.
    var totalTokens: Int {
        inputTokens + cacheReadTokens + cacheWriteTokens + outputTokens
    }
}

// MARK: - 평가 / 전적

enum Satisfaction: String, Codable, Sendable {
    case up, down
    var koreanName: String { self == .up ? "👍 좋음" : "👎 아쉬움" }
}

enum HandoffQuality: String, Codable, Sendable {
    case seamless   // 바로 이어감
    case needsInfo  // 설명 필요
    case failed     // 실패

    var koreanName: String {
        switch self {
        case .seamless: return "바로 이어감"
        case .needsInfo: return "설명 필요"
        case .failed: return "실패"
        }
    }
}

struct Rating: Identifiable, Hashable, Codable, Sendable {
    var id: String = UUID().uuidString
    var threadID: String
    var runID: String?
    var handoffID: String?
    var provider: AgentProvider
    var satisfaction: Satisfaction?
    var handoffQuality: HandoffQuality?
    /// 사용자가 직접 부여하는 "구원" 표시.
    var rescue: Bool = false
    var note: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

// MARK: - 가격표

struct PriceEntry: Identifiable, Hashable, Codable, Sendable {
    var id: String = UUID().uuidString
    var provider: AgentProvider
    var model: String
    var inputPerMTok: Double
    var outputPerMTok: Double
    var cacheReadPerMTok: Double
    var cacheWritePerMTok: Double
    var source: String
    var effectiveDate: String   // yyyy-MM-dd
    var catalogVersion: String
}

// MARK: - 한도

enum LimitStatus: String, Codable, Sendable {
    case ok
    case noData          // 정보 없음 (조회 실패나 형식 변경 포함)
    case throttled       // 일시적 요청 제한
    case subscriptionCap // 구독 한도 도달
    case authProblem     // 인증 문제
    case networkError    // 네트워크·서비스 오류
    case unknownCause    // 원인 미확인

    var koreanName: String {
        switch self {
        case .ok: return "정상"
        case .noData: return "정보 없음"
        case .throttled: return "일시적 요청 제한"
        case .subscriptionCap: return "구독 한도 도달"
        case .authProblem: return "인증 문제"
        case .networkError: return "네트워크·서비스 오류"
        case .unknownCause: return "원인 미확인"
        }
    }
}

/// 한도 구간 하나. 값이 없으면 utilization 은 nil 이며 0%로 표시하지 않는다.
struct LimitWindow: Hashable, Codable, Sendable, Identifiable {
    var id: String { label }
    var label: String
    /// 0.0 ~ 1.0. 파싱 실패 시 nil.
    var utilization: Double?
    var resetsAt: Date?
    /// 원문 텍스트 (형식이 바뀌면 이것만 보여준다).
    var rawText: String?
    /// 한 모델에만 걸리는 한도면 그 모델 이름 (Claude 의 "Current week (Fable)" 등). nil 이면 계정 전체의 한도.
    /// 모델 한도가 차도 다른 모델은 쓸 수 있으므로 계정 전체의 한도 도달 판정(`reachedAccountWideCap`)에 넣지 않는다.
    var model: String?
    /// 창의 길이(분). 출처가 알려 줄 때만 — Codex `windowDurationMins`, Claude 는 창 이름(5시간 · 현재 세션 = 300,
    /// 7일 · 이번 주 = 10080)에서 채운다. 이어 가기 제안이 짧은 창 · 긴 창의 문턱을 가른다 (`LimitSpan`). 모르면 nil.
    var spanMinutes: Int?
}

struct LimitSnapshot: Hashable, Codable, Sendable {
    var provider: AgentProvider
    /// Codex 계정 ID. Claude 스냅샷은 빈 문자열.
    var accountID: String = ""
    var status: LimitStatus = .noData
    var windows: [LimitWindow] = []
    var planType: String?
    var fetchedAt: Date?
    var message: String?
    /// 파싱에 실패했을 때 사용자가 확인할 원문.
    var rawResponse: String?

    var hasUsableData: Bool {
        windows.contains { $0.utilization != nil }
    }

    /// 계정 전체에 걸리는 구간 중 다 찬 것이 있는지. 모델 하나의 한도(`LimitWindow.model`)는 세지 않는다.
    var reachedAccountWideCap: Bool {
        windows.contains { $0.model == nil && ($0.utilization ?? 0) >= 1 }
    }

    /// 한도가 풀리는 시각 — 다 찬 계정 전체 창(모델 한도 · 덜 찬 창은 빼고)이 풀리는 때, 여럿이면 가장 늦은 것 (그때까지 쓸 수 없다).
    /// 다 찬 창을 모르거나 그 창의 초기화 시각을 모르면 nil ("초기화 시각 미확인"). 한도 줄 · 인계 카드 머리가 같이 쓴다.
    /// 주간 한도가 찼는데 5시간 창의 이른 시각을 적으면, 몇 시간만 기다리면 된다고 오해해 넘기지 않는다.
    func capResetsAt(now: Date = Date()) -> Date? {
        let full = windows.filter { $0.model == nil && ($0.utilization ?? 0) >= 1 }
        guard !full.isEmpty else { return nil }
        let future = full.compactMap(\.resetsAt).filter { $0 > now }
        // 지난 시각은 이미 풀린 창이다. 아직 차 있다고 보이는데 시각을 모르는 창이 있으면 언제 풀릴지 모른다.
        guard full.allSatisfy({ $0.resetsAt != nil }) else { return nil }
        return future.max()
    }

    var scope: AgentScope { AgentScope(provider: provider, accountID: accountID) }
}

// MARK: - Git

struct GitSnapshot: Hashable, Codable, Sendable {
    var isRepository: Bool = false
    var branch: String?
    var staged: [String] = []
    var unstaged: [String] = []
    var untracked: [String] = []
    var aheadBehind: String?
    /// staged + unstaged diff 의 제한된 발췌. 기존 저장 자료 호환을 위해 Optional 이다.
    var diffExcerpt: String?
    /// Git 저장소가 아닐 때 최근 수정 파일 목록으로 대체한다.
    var recentlyModified: [String] = []
    var error: String?
    /// 지금 HEAD 의 커밋 해시(전체). 다음 인계가 "그 사이 새 커밋" 을 셀 기준이 된다 (`GitInspector.snapshot`).
    /// 옛 패킷에는 없어 Optional 이다.
    var head: String?
    /// 인계 구간의 새 커밋 ("87450eb 메시지", 최근 것 먼저) — 앞 인계의 HEAD 이후, 없으면 구간을 시작한 때 이후.
    /// 사람이 앱이나 터미널에서 한 커밋도 문서의 "완료한 작업" 에 들어간다. 모르면 nil.
    var commitsSinceBase: [String]?

    var isEmpty: Bool {
        staged.isEmpty && unstaged.isEmpty && untracked.isEmpty && recentlyModified.isEmpty
    }
}

// MARK: - CLI 환경

struct CLIStatus: Hashable, Codable, Sendable {
    var provider: AgentProvider
    var resolvedPath: String?
    var version: String?
    var executable: Bool = false
    var checkedAt: Date?
    var error: String?
    /// 인증 상태는 CLI가 제공하는 범위에서만 확인한다.
    /// 접근 실패와 실제 로그아웃을 구분하기 위해 nil(미확인)을 허용한다.
    var authenticated: Bool?
    var authNote: String?
    /// 확인할 때 설정(설정 > 에이전트의 실행 파일)에서 지정해 둔 경로 — nil 이면 자동으로 찾았다. 경로를 바꾼 뒤 늦게 끝난 옛 경로의
    /// 확인을 가려낸다 (`CLIEnvironment.isCurrent` — 캐시 · 화면에 쓰지 않는다, set-n7).
    var pinnedPath: String?

    var isUsable: Bool { executable && resolvedPath != nil }
}
