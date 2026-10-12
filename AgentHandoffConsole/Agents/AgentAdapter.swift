import Foundation

// MARK: - 승인 / 질문

enum ApprovalKind: String, Sendable {
    case tool            // Claude can_use_tool
    case command         // Codex item/commandExecution/requestApproval
    case fileChange      // Codex item/fileChange/requestApproval
    case permissions     // Codex item/permissions/requestApproval
    case elicitation     // Codex mcpServer/elicitation/request

    /// 자동 승인이 사람 대신 허용해도 되는 종류인가. Codex 의 권한 요청(`item/permissions` — 권한 프로필을 넓혀 달라는 요청)과
    /// MCP 의 입력 요청은 늘 사람이 본다. Codex 의 명령 · 파일 변경 승인은 샌드박스 밖(인터넷 · 폴더 밖)으로 나가는 것이어도 허용한다
    /// — 요청에 그 표시가 없다 (사용자 결정 2026-10-09, 칩 글 `ApprovalPolicyText.autoApproval`).
    /// 요청 하나의 판정(에이전트의 질문도 뺀다)은 `ApprovalRequest.allowsAutoApproval`.
    var allowsAutoApproval: Bool { self != .permissions && self != .elicitation }

    var koreanName: String {
        switch self {
        case .tool: return "도구 사용"
        case .command: return "명령 실행"
        case .fileChange: return "파일 변경"
        case .permissions: return "권한 요청"
        case .elicitation: return "MCP 입력 요청"
        }
    }
}

struct ApprovalRequest: Identifiable, Sendable, Hashable {
    /// 어댑터 내부의 요청 ID (Claude: control request_id, Codex: JSON-RPC id).
    var id: String
    var runID: String
    var provider: AgentProvider
    var kind: ApprovalKind
    var toolName: String
    var title: String
    var detail: String
    /// 도구 실행 ID. 늦은 응답 무효화 판정에 함께 사용한다.
    var toolUseID: String?
    var createdAt: Date = Date()
    /// 하위 에이전트가 요청했으면 그 하위 에이전트의 `SubAgentInfo.id`. 메인이 요청했으면 nil.
    var agentID: String? = nil
    /// 요청의 입력 그대로 (JSON 객체 글, 자르지 않는다) — 승인 카드가 도구별로 읽기 좋게 푼다 (`ApprovalPresentation`).
    /// Claude: 도구 입력. Codex: 명령 · 작업 폴더 · 사유 · 바뀌는 파일. 모르면 nil (카드는 `detail` 을 그대로 보인다).
    var input: String? = nil

    /// 에이전트의 질문(Claude `AskUserQuestion` — `AskedQuestion`)인가. 승인 요청으로 오지만 사람의 답을 묻는다.
    var isQuestion: Bool { kind == .tool && AskedQuestion.isTool(toolName) }

    /// 자동 승인이 사람 대신 허용해도 되는 요청인가. Codex 의 권한 요청 · MCP 입력 요청 · 에이전트의 질문은 늘 사람이 본다 —
    /// 질문을 허용하면 답 없이 진행된다 (2차 시험 conv-6).
    var allowsAutoApproval: Bool { kind.allowsAutoApproval && !isQuestion }
}

enum ApprovalDecision: Sendable, Equatable {
    case allow
    /// Codex `acceptForSession` — 앱은 턴마다 app-server 를 새로 띄우므로 실제 범위는 **이번 실행**이다
    /// (명령은 같은 명령, 파일 변경은 그 파일들, 권한은 그 권한). 화면 글은 `ApprovalPresentation.sessionScopeNote`.
    case allowForSession
    case deny(String)
    /// 거절하고 턴도 즉시 중단.
    case denyAndCancel(String)
    /// 입력을 채워 허용한다 — MCP 입력 요청(`elicitation`)의 내용 (JSON 객체 글). 다른 요청에는 `allow` 와 같다.
    case submit(String)
    /// 에이전트의 질문(`ApprovalRequest.isQuestion`)에 사람이 적은 답. 고른 답을 돌려주는 길은 실측하지 않아 CLI 에는 확인된 길 —
    /// 그 도구의 거절 글 자리 — 로 보낸다 (에이전트는 그 도구의 결과로 받는다). 결정 기록은 거절이 아니라 답이다
    /// (`ApprovalDecisionInfo.Decision.answered`).
    case answer(String)

    var koreanName: String {
        switch self {
        case .allow: return "허용"
        case .allowForSession: return "이번 실행 동안 허용"
        case .deny: return "거절"
        case .denyAndCancel: return "거절 후 중단"
        case .submit: return "입력 보냄"
        case .answer: return "답함"
        }
    }

    /// 결정 기록(`ApprovalDecisionInfo`)의 결정. 입력을 채운 허용도 허용이다.
    var recorded: ApprovalDecisionInfo.Decision {
        switch self {
        case .allow, .submit: return .allow
        case .allowForSession: return .allowForSession
        case .deny: return .deny
        case .denyAndCancel: return .denyAndCancel
        case .answer: return .answered
        }
    }

    /// 거절과 함께 에이전트에게 줄 사유 (비었으면 nil). 질문의 답은 사유가 아니다 (`answer`).
    var reason: String? {
        switch self {
        case .deny(let text), .denyAndCancel(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            return nil
        }
    }

    /// 질문에 보낸 답 (비었으면 nil).
    var answer: String? {
        guard case .answer(let text) = self else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "이번 실행 동안 허용"을 실제로 지키는 제공자. Codex 는 `acceptForSession` 으로 다시 묻지 않는다.
    /// Claude 는 규칙(`updatedPermissions`)을 돌려주지 않아 "허용"과 같아서 단추를 보이지 않는다 —
    /// 되살리려면 `permission_suggestions` 를 세션 범위 규칙으로 돌려주고 실제 CLI 로 확인한다.
    /// 요청 종류 · 위험한 명령까지 본 판정은 `ApprovalPresentation.offersSessionScope`.
    static func offersSessionScope(_ provider: AgentProvider) -> Bool {
        provider == .codex
    }
}

struct UserQuestion: Identifiable, Sendable, Hashable {
    struct Item: Sendable, Hashable, Identifiable {
        var id: String
        var header: String
        var question: String
        var options: [String]
        var allowsOther: Bool
        var isSecret: Bool
    }
    var id: String
    var runID: String
    var provider: AgentProvider
    var items: [Item]
    var createdAt: Date = Date()
    /// 하위 에이전트가 물었으면 그 하위 에이전트의 `SubAgentInfo.id`. 메인이 물었으면 nil.
    var agentID: String? = nil
}

// MARK: - 사용량

struct TurnUsage: Sendable, Hashable {
    /// 캐시 토큰을 제외한 순수 입력.
    var inputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var outputTokens = 0
    /// outputTokens 의 부분집합.
    var reasoningTokens = 0
    var durationMs = 0
    /// CLI 가 직접 보고한 비용 (있을 때만).
    var reportedCostUSD: Double?
    var model: String?
    /// 중단 등으로 값이 불완전하면 false.
    var confirmed = true

    static func + (lhs: TurnUsage, rhs: TurnUsage) -> TurnUsage {
        var r = lhs
        r.inputTokens += rhs.inputTokens
        r.cacheReadTokens += rhs.cacheReadTokens
        r.cacheWriteTokens += rhs.cacheWriteTokens
        r.outputTokens += rhs.outputTokens
        r.reasoningTokens += rhs.reasoningTokens
        return r
    }
}

// MARK: - 턴 결과

struct AgentTurnResult: Sendable {
    var state: RunState
    var terminalReason: String?
    var isError: Bool = false
    var errorMessage: String?
    var model: String?
    var sessionID: String?
    var resultText: String?
    /// `AgentTurnRequest.outputSchema` 를 준 턴의 마지막 응답 (JSON 글). 스키마를 주지 않았으면 nil.
    /// 스키마 검사는 CLI 가 했다고 믿지 않는다 — 받는 쪽이 다시 해석하고 검사한다.
    var structuredOutput: String?
    var usage: TurnUsage?
    /// 오류 분류. 한도/인증/네트워크를 구분한다.
    var limitStatus: LimitStatus?
}

struct AgentErrorInfo: Sendable {
    var message: String
    var classification: LimitStatus
    var raw: String?
}

// MARK: - 통합 이벤트

/// API 이벤트를 화면 모델과 분리하기 위한 중간 표현.
/// CLI 프로토콜 변경은 어댑터 안에서 흡수한다.
enum AgentEvent: Sendable {
    case sessionEstablished(sessionID: String, model: String?, cliVersion: String?)
    case assistantDelta(String)
    case assistantMessage(String)
    case reasoning(String)
    case toolStarted(id: String, name: String, detail: String)
    case toolFinished(id: String, name: String, output: String, isError: Bool)
    case commandExecution(id: String, command: String, cwd: String?, output: String?,
                          exitCode: Int?, status: String)
    case fileChange(id: String, paths: [String], diff: String?, status: String)
    case approvalRequested(ApprovalRequest)
    case approvalResolved(id: String, decision: String)
    case questionAsked(UserQuestion)
    case rateLimits(LimitSnapshot)
    /// 대화에 한 줄로 남는 실행의 안내 (백그라운드 작업을 함께 멈춤 · 대화 압축 · 세션 재개 실패 …).
    case notice(String)
    /// CLI 의 진단 글 — 실행 명령줄 · app-server 시작 · 준비된 MCP 서버 · 모르는 CLI 이벤트 · stderr · 성공한 훅의 출력.
    /// 저장은 하되 대화 스트림에는 보이지 않는다 (진단 표시 `ThreadEvent.diagnosticKey` — 턴 바닥글을 펼치면 보인다).
    case diagnostic(String)
    /// 사람이 할 일이 있는 CLI 상태 — 훅 실패 · MCP 서버 인증 필요 · 연결 실패. 대화에 짧은 한 줄로 남는다.
    /// 같은 실행에서는 이름마다 한 번만 낸다 (어댑터 · 트래커가 거른다).
    case attention(String)
    /// 지금 하는 일을 한 줄로 요약한 진행 문구 (Claude `task_summary` — CLI 가 정리한 것). nil 이면 지운다.
    /// 실행 중 상태 줄(`RunActivity`)이 쓴다 — 저장하지 않는다.
    case progressSummary(String?)
    /// CLI 가 알려 준 명령 · 스킬 (Claude 의 초기화 응답) — 입력창 "/" 목록을 새로 받아 둔다. 기록에 남기지 않는다.
    case slashCommands([SlashCommand])
    case failure(AgentErrorInfo)
    /// 하위 에이전트 · 워크플로 · 백그라운드 작업이 생기거나 바뀌었다. 같은 `id` 로 여러 번 온다 (진행은 자주).
    case subAgent(SubAgentInfo)
    /// 하위 에이전트 안에서 일어난 일. 안에는 내용 이벤트만 온다 — `assistantDelta` · `assistantMessage` ·
    /// `reasoning` · `toolStarted` · `toolFinished` · `commandExecution` · `fileChange` · `notice` · `diagnostic` · `attention` ·
    /// `failure`. 메인의 응답 · 사용량 · 결과에 섞지 않는다.
    indirect case subAgentEvent(agentID: String, event: AgentEvent)
    /// 메인 턴은 끝났고 남은 백그라운드 작업(`remaining` 개)을 기다린다. **실행은 끝나지 않았다** —
    /// 프로세스가 살아 있고 파일이 바뀔 수 있다. 실행의 끝은 여전히 `finished` 하나다.
    case turnSettled(remaining: Int)
    /// 기다리는 중 CLI 가 스스로 후속 턴을 열었다 (Claude: 백그라운드 작업이 끝나 `task-notification` 턴).
    /// 같은 실행의 연장이다 — 사용자가 보낸 것이 아니다.
    case followUpTurnStarted
    case finished(AgentTurnResult)
}

// MARK: - 턴 요청

struct AgentTurnRequest: Sendable {
    var runID: String
    var prompt: String
    var workingDirectory: URL
    /// 기존 CLI 세션 ID. nil 이면 새 세션.
    var resumeSessionID: String?
    /// 재개하지 못하면 새 세션으로 넘어가지 않고 실패로 끝낸다 (Codex — 다른 계정의 인증으로 대화의 세션을 이어 가는 실행,
    /// `CodexRunHome`). 새 세션으로 넘어가면 그 계정이 지금까지의 대화를 모른 채 시작하고, 대화의 세션 연결도 새 세션으로 바뀐다.
    var strictResume: Bool = false
    /// 새 세션일 때 앱이 지정할 세션 ID (Claude 만 지원).
    var preferredNewSessionID: String?
    var model: String?
    /// 추론 강도. nil 이면 CLI 기본값을 그대로 쓴다.
    var effort: String?
    /// 승인을 앱이 처리할지. false 면 CLI 기본 정책을 따른다.
    var routeApprovalsToApp: Bool = true
    /// Antigravity ULTRA — 프롬프트 앞에 `/boost ` 를 붙인다 (강도는 `effort` 로 따로 넘긴다).
    var boost: Bool = false
    /// 파일을 바꾸지 못하는 턴 (계획 · 검토). 프롬프트로 부탁하는 것이 아니라 CLI 가 막는다:
    /// Claude 는 쓰기 도구를 빼고, Codex 는 읽기 전용 샌드박스 + 승인 없음으로 돈다.
    /// 보장하지 못하는 제공자(`AgentProvider.supportsReadOnlyTurns`)는 턴을 시작하지 않는다.
    var readOnly: Bool = false
    /// 마지막 응답을 맞출 JSON 스키마 (JSON 글). 결과는 `AgentTurnResult.structuredOutput`.
    var outputSchema: String?
    /// 메인 턴이 끝나도 남은 백그라운드 작업(하위 에이전트 · 워크플로 · 백그라운드 셸)이 끝날 때까지
    /// 프로세스를 살려 두고 같은 실행으로 기다리는가 (`turnSettled` → … → `finished`).
    /// false 면 지금처럼 메인 턴 끝에서 끝낸다 — 남은 작업은 프로세스와 함께 멈춘다.
    /// `RunSession` 이 정한다: 사람이 지켜보는 쓰기 턴만 true (무인 · 읽기 전용 · 구조화 응답 턴은 false).
    var waitForBackground: Bool = false
    /// 사용자가 붙인 이미지. Claude 는 base64 이미지 블록, Codex 는 `localImage` 로 넘긴다.
    /// (Antigravity 는 이미지를 받지 않아 `RunSession` 이 파일 경로를 프롬프트 끝에 적는다.)
    var images: [ImageAttachment] = []
    /// 글 속 "$이름" 으로 부른 Codex 스킬 — `turn/start` 에 `{"type":"skill","name","path"}` 입력으로 덧붙인다 (Codex 만).
    var skills: [SkillMention] = []
}

/// 호출자가 턴마다 정하는 실행 조건 (`RunCoordinator.send`). 의미는 `AgentTurnRequest` 의 같은 이름 필드.
struct AgentTurnOptions: Sendable {
    var readOnly = false
    var outputSchema: String?
    var images: [ImageAttachment] = []
    var skills: [SkillMention] = []
    /// CLI 에 보내는 글 앞에 붙일 앱의 안내 (기록의 사용자 글에는 넣지 않는다) — 대화의 작업 폴더가 바뀐 뒤 첫 턴 등.
    var preamble: String?
}

// MARK: - 어댑터 프로토콜

protocol AgentAdapter: AnyObject, Sendable {
    var provider: AgentProvider { get }
    /// 실행을 시작하고 이벤트 스트림을 반환한다.
    func start(_ request: AgentTurnRequest) -> AsyncStream<AgentEvent>
    /// 승인 응답. 이미 종료된 요청이면 무시된다.
    func respond(approvalID: String, decision: ApprovalDecision) async
    /// 사용자 질문 응답.
    func respond(questionID: String, answers: [String: String]) async
    /// 중단 요청. 시작 중이어도 유실되지 않도록 어댑터가 큐에 넣는다.
    func requestInterrupt() async
    /// 프로세스 종료. 반환값이 false 면 종료를 확신할 수 없다.
    func shutdown() async -> Bool
    /// 이 어댑터가 시작한 프로세스의 PID (있으면).
    var currentPID: Int32? { get }
    /// 하위 작업 하나만 멈춘다 (`SubAgentInfo.canStop` 인 것). 보낼 수 없으면 false.
    /// 실행 전체는 계속된다 — 전부 멈추기는 `requestInterrupt`.
    func stopSubAgent(id: String) async -> Bool
    /// 결과(`finished`)가 오기 전에 실행을 끊을 때(앱 종료) 남길 사용량 — 지금까지 안 값, 확정 아님(`confirmed` false).
    /// 모르면 nil.
    var lastKnownUsage: TurnUsage? { get }
}

extension AgentAdapter {
    /// 작업 하나 멈추기를 제공하지 않는 제공자의 기본 구현.
    func stopSubAgent(id: String) async -> Bool { false }
    /// 끊긴 실행의 사용량을 알려 주지 않는 제공자의 기본 구현.
    var lastKnownUsage: TurnUsage? { nil }
}

// MARK: - JSON 유틸

enum JSONUtil {
    static func string(_ any: Any) -> String {
        guard JSONSerialization.isValidJSONObject(any),
              let d = try? JSONSerialization.data(withJSONObject: any,
                                                  options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else {
            return String(describing: any)
        }
        return s
    }

    static func prettyString(_ any: Any) -> String {
        guard JSONSerialization.isValidJSONObject(any),
              let d = try? JSONSerialization.data(withJSONObject: any,
                                                  options: [.prettyPrinted, .sortedKeys,
                                                            .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else {
            return String(describing: any)
        }
        return s
    }

    static func object(_ line: String) -> [String: Any]? {
        guard let d = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o
    }

    static func line(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let d = try? JSONSerialization.data(withJSONObject: object,
                                                  options: [.withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }

    /// JSON 숫자를 Int 로 안전하게 읽는다.
    ///
    /// `JSONSerialization` 은 NSNumber 를 돌려주므로 보통 `as? Int` 로 충분하지만,
    /// CLI 가 `2.0` 처럼 소수 형태로 보내면 `as? Int` 가 실패해 조용히 0 이 된다.
    /// 사용량이 0 으로 잘못 기록되는 것을 막기 위해 Double/NSNumber/String 도 받아들인다.
    static func int(_ any: Any?) -> Int? {
        switch any {
        case let v as Int: return v
        case let v as NSNumber: return v.intValue
        case let v as Double: return Int(v)
        case let v as String: return Int(v) ?? Double(v).map { Int($0) }
        default: return nil
        }
    }

    static func intValue(_ any: Any?, default def: Int = 0) -> Int { int(any) ?? def }

    /// JSON 숫자를 Double 로 안전하게 읽는다.
    static func double(_ any: Any?) -> Double? {
        switch any {
        case let v as Double: return v
        case let v as NSNumber: return v.doubleValue
        case let v as Int: return Double(v)
        case let v as String: return Double(v)
        default: return nil
        }
    }

    /// 길이 제한. 인계 패킷과 화면 표시에서 과도한 길이를 막는다.
    static func truncate(_ s: String, max: Int, marker: String = "\n…(생략됨)") -> String {
        guard s.count > max else { return s }
        return String(s.prefix(max)) + marker
    }
}

/// 오류 문자열을 분류한다. 확신할 수 없으면 원인 미확인으로 남긴다.
enum ErrorClassifier {
    static func classify(_ text: String?) -> LimitStatus {
        guard let raw = text?.lowercased(), !raw.isEmpty else { return .unknownCause }
        // "fable limit": Claude 의 Fable 모델 한도 오류로 추정한 문구다 (실제 오류는 아직 관찰하지 못했다).
        if raw.contains("usage limit") || raw.contains("rate limit reached")
            || raw.contains("quota") || raw.contains("limit reached")
            || raw.contains("out of credits") || raw.contains("fable limit")
            || raw.contains("한도") {
            return .subscriptionCap
        }
        if raw.contains("429") || raw.contains("too many requests")
            || raw.contains("overloaded") || raw.contains("rate_limit_error") {
            return .throttled
        }
        // "authenticat" 는 authenticate / authentication / authentication_failed 를 모두 잡는다.
        // 실측(Claude Code 2.1.233): "Failed to authenticate: OAuth session expired and could not be refreshed"
        if raw.contains("unauthorized") || raw.contains("401") || raw.contains("forbidden")
            || raw.contains("403") || raw.contains("not logged in") || raw.contains("login")
            || raw.contains("authenticat") || raw.contains("oauth") || raw.contains("credential") {
            return .authProblem
        }
        if raw.contains("network") || raw.contains("econn") || raw.contains("timeout")
            || raw.contains("dns") || raw.contains("socket") || raw.contains("enotfound")
            || raw.contains("503") || raw.contains("502") || raw.contains("500") {
            return .networkError
        }
        return .unknownCause
    }
}
