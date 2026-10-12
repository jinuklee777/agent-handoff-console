import Foundation

// 오케스트레이션의 상태와 저장되는 단위(전체 작업 · 하위 작업 · 시도). 순수 코드다.
// `RunState` 와 별개다: `Run` 이 completed 여도 검증을 통과하기 전에는 하위 작업이 끝난 것이 아니다.

// MARK: - 전체 작업

enum JobState: String, Codable, CaseIterable, Sendable {
    case draft, planning, ready, running, awaitingUser, paused, cancelling, completed, failed, cancelled

    var koreanName: String {
        switch self {
        case .draft: return "준비"
        case .planning: return "계획 중"
        case .ready: return "시작 대기"
        case .running: return "진행 중"
        case .awaitingUser: return "사용자 확인 대기"
        case .paused: return "일시 정지"
        case .cancelling: return "중단 중"
        case .completed: return "완료"
        case .failed: return "실패"
        case .cancelled: return "중단됨"
        }
    }

    var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }

    func canTransition(to next: JobState) -> Bool {
        switch self {
        case .draft: return [.planning, .cancelled].contains(next)
        case .planning: return [.ready, .awaitingUser, .failed, .cancelling, .cancelled].contains(next)
        case .ready: return [.running, .planning, .paused, .cancelling, .cancelled].contains(next)
        case .running: return [.awaitingUser, .planning, .paused, .cancelling, .completed, .failed].contains(next)
        case .awaitingUser: return [.running, .ready, .planning, .paused, .cancelling, .cancelled, .failed].contains(next)
        case .paused: return [.running, .ready, .cancelling, .cancelled].contains(next)
        case .cancelling: return next == .cancelled
        case .completed, .failed, .cancelled: return false
        }
    }
}

/// 최종 통합 검증. 하위 작업이 모두 통과해도 이것이 통과하기 전에는 완료가 아니다.
enum FinalVerificationState: String, Codable, Sendable {
    case notStarted, passed, failed
}

/// 서로 독립적인 상한이 곱해져 끝없이 돌지 않도록 전체 시도 수도 함께 묶는다. 값은 제안이며 실측으로 조정한다.
struct OrchestrationBudget: Codable, Equatable, Sendable {
    /// 능력 실패(검증 실패)로 세는 시도의 작업당 상한.
    var maxAttemptsPerTask = 3
    var maxSameProfileRetries = 1
    var maxReplans = 1
    var maxTransientRetries = 2
    /// 실패 유형과 무관한 작업당 시도 상한 (환경 · 한도 · 네트워크 재시도까지 포함).
    var maxAttemptsPerTaskOfAnyKind = 6
    var maxTotalAttempts = 20
}

struct OrchestrationJob: Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var projectID: String
    /// 사용자가 보는 대화. 사용자 요청은 여기에 한 번만 기록한다.
    var parentThreadID: String
    var userRequestEventID: String?
    var request: String
    var state: JobState = .draft
    /// 지금 실행 기준인 계획 버전. 재계획하면 올라가고 이전 버전의 대기 작업은 superseded 가 된다.
    var activePlanVersion = 0
    /// 중단 · 재계획 때 올린다. 늦게 도착한 결과가 이 값과 다르면 버린다.
    var generation = 0
    var replanCount = 0
    var finalVerification: FinalVerificationState = .notStarted
    var budget = OrchestrationBudget()
    var policyVersion = "static-1"
    var createdAt = Date()
    var updatedAt = Date()
}

// MARK: - 하위 작업

enum TaskState: String, Codable, CaseIterable, Sendable {
    case pending, ready, routing, running, verifying, retryPending, escalationPending, blocked
    case succeeded, failed, cancelled, superseded

    var koreanName: String {
        switch self {
        case .pending: return "대기"
        case .ready: return "시작 가능"
        case .routing: return "담당 정하는 중"
        case .running: return "실행 중"
        case .verifying: return "검증 중"
        case .retryPending: return "보완 예정"
        case .escalationPending: return "담당 변경 예정"
        case .blocked: return "막힘"
        case .succeeded: return "검증 통과"
        case .failed: return "실패"
        case .cancelled: return "취소"
        case .superseded: return "계획 변경으로 대체됨"
        }
    }

    var isTerminal: Bool { [.succeeded, .failed, .cancelled, .superseded].contains(self) }

    /// blocked 는 해결할 조건이 남은 상태이고 failed 와 다르다.
    func canTransition(to next: TaskState) -> Bool {
        switch self {
        case .pending: return [.ready, .blocked, .cancelled, .superseded].contains(next)
        case .ready: return [.routing, .blocked, .cancelled, .superseded].contains(next)
        case .routing: return [.running, .ready, .blocked, .cancelled].contains(next)
        case .running: return [.verifying, .retryPending, .escalationPending, .blocked, .failed, .cancelled].contains(next)
        case .verifying: return [.succeeded, .retryPending, .escalationPending, .blocked, .failed, .cancelled].contains(next)
        case .retryPending, .escalationPending: return [.routing, .blocked, .failed, .cancelled, .superseded].contains(next)
        // succeeded 는 사람이 직접 확인하고 통과로 인정할 때만 (검증 불가 · 판정 불가로 막힌 작업).
        case .blocked: return [.ready, .retryPending, .escalationPending, .succeeded, .failed, .cancelled, .superseded].contains(next)
        case .succeeded, .failed, .cancelled, .superseded: return false
        }
    }
}

struct OrchestrationTask: Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var jobID: String
    var planVersion: Int
    /// 계획 안에서의 이름 (`PlannedTask.id`). 의존 관계는 이 값으로 가리킨다.
    var planTaskID: String
    /// 계획에 적힌 순서.
    var ordinal: Int
    var title: String
    var specification: String
    var kind: TaskKind
    var difficulty: Int
    var dependsOn: [String]
    var acceptance: [String]
    var verification: String
    var paths: [String]
    var optional: Bool
    var state: TaskState = .pending
    /// 이 작업의 세션을 가진 내부 대화 (만들어진 뒤에 채운다).
    var childThreadID: String?
    var blockedReason: String?

    static func make(from plan: OrchestrationPlan, jobID: String, planVersion: Int) -> [OrchestrationTask] {
        plan.tasks.enumerated().map { index, t in
            OrchestrationTask(jobID: jobID, planVersion: planVersion, planTaskID: t.id, ordinal: index,
                              title: t.title, specification: t.specification, kind: t.kind,
                              difficulty: t.difficulty, dependsOn: t.dependsOn, acceptance: t.acceptance,
                              verification: t.verification, paths: t.paths, optional: t.optional)
        }
    }
}

// MARK: - 시도

enum AttemptState: String, Codable, CaseIterable, Sendable {
    case prepared, dispatching, running, awaitingApproval, verifying
    case succeeded, failed, cancelled, deliveryUnknown

    /// 끝나지 않은 일이 있는 상태. 앱이 꺼졌다 켜진 뒤 이 상태로 남아 있으면 복구 대상이다.
    var isActive: Bool { [.dispatching, .running, .awaitingApproval, .verifying].contains(self) }
    var isTerminal: Bool { [.succeeded, .failed, .cancelled].contains(self) }

    func canTransition(to next: AttemptState) -> Bool {
        switch self {
        case .prepared: return [.dispatching, .cancelled].contains(next)
        case .dispatching: return [.running, .failed, .cancelled, .deliveryUnknown].contains(next)
        case .running: return [.awaitingApproval, .verifying, .failed, .cancelled, .deliveryUnknown].contains(next)
        case .awaitingApproval: return [.running, .failed, .cancelled, .deliveryUnknown].contains(next)
        case .verifying: return [.succeeded, .failed, .cancelled].contains(next)
        // 전달 여부를 사람이 확인한 뒤에만 풀린다. 자동으로 다시 보내지 않는다.
        case .deliveryUnknown: return [.verifying, .failed, .cancelled].contains(next)
        case .succeeded, .failed, .cancelled: return false
        }
    }
}

/// 왜 이 시도를 했는지. Codex 계정 변경 같은 가용성 전환은 능력 승격과 따로 센다.
enum AttemptKind: String, Codable, Sendable {
    case first, retry, escalation, availabilitySwitch
}

/// 실패의 종류. 다음 행동과, 모델 성과에 반영할지를 가른다.
enum FailureClass: String, Codable, CaseIterable, Sendable {
    /// 빌드 · 테스트 실패, 완료 조건 미충족.
    case verificationFailed
    /// 접근 권한 · 인증 · 도구 부재.
    case environment
    case limitReached
    case transientNetwork
    case ambiguousRequirement
    /// 계획 누락 · 의존 관계 오류.
    case planDefect
    case deliveryUnknown
    case userCancelled

    /// 모델의 능력 실패로 세는가. 나머지는 성공 · 실패 분모에서 뺀다.
    var countsAgainstModel: Bool { self == .verificationFailed }
}

struct OrchestrationAttempt: Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var taskID: String
    var jobID: String
    /// 작업 안에서 1부터. `(taskID, number)` 는 유일하다.
    var number: Int
    var kind: AttemptKind
    /// 모델 · 추론 강도 · 계정을 묶은 실행 프로필의 이름.
    var profileID: String
    var routingDecisionID: String?
    var runID: String?
    /// CLI 로 보내기 전에 저장하는 표식. 같은 시도를 두 번 보내지 않기 위한 것이며 exactly-once 를 보장하지는 않는다.
    var dispatchToken: String = UUID().uuidString
    /// 만들 때의 `OrchestrationJob.generation`.
    var generation: Int
    var state: AttemptState = .prepared
    var failureClass: FailureClass?
    /// 같은 오류의 무진전 반복을 알아보는 지문 (실패한 검증 · 오류 줄의 요약).
    var failureFingerprint: String?
    /// 실행 에이전트의 마지막 말과 검증 요약. 통과하면 뒤 작업에 선행 결과로, 실패하면 다음 시도에 근거로 넘긴다.
    var resultSummary: String?
    var createdAt = Date()
    var endedAt: Date?
}

/// 스케줄러가 보는 한 시점의 전체 상태. 화면 선택과 무관하게 DB 에서 만든다.
struct OrchestrationSnapshot: Equatable, Sendable {
    var job: OrchestrationJob
    var tasks: [OrchestrationTask]
    var attempts: [OrchestrationAttempt]

    /// 지금 계획 버전의 작업 (계획 순서).
    var activeTasks: [OrchestrationTask] {
        tasks.filter { $0.planVersion == job.activePlanVersion }.sorted { $0.ordinal < $1.ordinal }
    }

    func attempts(for taskID: String) -> [OrchestrationAttempt] {
        attempts.filter { $0.taskID == taskID }.sorted { $0.number < $1.number }
    }
}

// MARK: - 검증 · 배정 기록

/// 검증 결과. inconclusive(판정 불가)와 unavailable(검증 수단 없음)은 통과가 아니다.
enum VerificationOutcome: String, Codable, Sendable {
    case pass, fail, inconclusive, unavailable
}

struct VerificationRecord: Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var jobID: String
    /// nil 이면 전체 목표의 최종 통합 검증.
    var taskID: String?
    var attemptID: String?
    var verifierVersion: String
    /// 확인한 완료 조건.
    var criterion: String
    var outcome: VerificationOutcome
    /// 명령 · 종료 코드 · 관련 출력 · 산출물 경로 (JSON 글).
    var evidenceJSON: String
    /// 검증한 시점의 Git 상태 또는 파일 해시.
    var workspaceFingerprint: String?
    var createdAt = Date()
}

/// 작업 분류가 어디서 왔는가. 배정 정책은 값만 보고 출처를 모른다 — 출처를 바꿔 비교할 수 있게 기록만 한다.
/// 모르는 값(옛 기록의 "jev" — 없앤 문지기)은 저장소가 `staticRules` 로 읽는다.
enum FeatureSource: String, Codable, Sendable {
    case staticRules, planner
}

/// 배정 한 번의 근거. "왜 다른 모델을 쓰지 않았는가"를 설명할 수 있도록 후보 전체와 제외 이유를 남긴다.
struct RoutingDecisionRecord: Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var jobID: String
    var taskID: String?
    var featureSource: FeatureSource
    var featureVersion: String
    var inputHash: String
    /// 마스킹한 입력 요약. 원문과 키는 저장하지 않는다.
    var inputSummary: String
    var featuresJSON: String
    var candidatesJSON: String
    var selectedProfile: String?
    var reasonCodesJSON: String
    var policyVersion: String
    var latencyMs: Int?
    var usageJSON: String?
    var createdAt = Date()
}
