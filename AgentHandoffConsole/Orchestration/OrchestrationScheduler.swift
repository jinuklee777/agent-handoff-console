import Foundation

// 다음에 무엇을 할지, 실패 뒤에 무엇을 할지 정하는 순수 판정. 실행 · 저장은 하지 않는다.
// 한 번에 하나만 실행한다 (앱의 실행 슬롯이 하나다).

/// 스케줄러의 결정. 코디네이터는 이것을 실행하고, 결과를 저장한 뒤 다시 묻는다.
enum SchedulerDecision: Equatable, Sendable {
    /// 할 일이 없다.
    case idle(IdleReason)
    /// 자동으로 진행하지 않고 사람을 기다린다.
    case needsUser(UserNeed)
    /// 이 프로세스에 주인이 없는 활성 시도 (앱이 꺼졌다 켜졌다). 전달 여부 미확인으로 돌리고 사람을 기다린다.
    case recover(attemptIDs: [String])
    /// 실행은 끝났는데 검증 기록이 없다. 검증을 다시 한다.
    case verify(attemptID: String)
    /// 선행 작업이 통과하지 못해 시작할 수 없는 작업. 사유와 함께 취소한다.
    case markUnreachable(taskIDs: [String])
    case dispatch(DispatchPlan)
    case runFinalVerification
    case complete
    case fail(FailReason)

    enum IdleReason: Equatable, Sendable {
        case jobNotRunning(JobState)
        case waitingForAttempt(String)
    }

    enum UserNeed: Equatable, Sendable {
        case deliveryUnknown(attemptIDs: [String])
        case blocked(taskIDs: [String])
        case finalVerificationFailed
        case budgetExhausted
    }

    enum FailReason: Equatable, Sendable {
        case requiredTaskFailed(taskID: String)
    }
}

struct DispatchPlan: Equatable, Sendable {
    var taskID: String
    var attemptNumber: Int
    var kind: AttemptKind
    /// 보완이면 다시 쓸 프로필.
    var reuseProfileID: String?
    /// 담당을 바꿀 때 고르면 안 되는 프로필 (이미 써 본 것). A → B → A 순환을 막는다.
    var excludedProfileIDs: [String]
}

enum OrchestrationScheduler {

    /// - Parameter inFlight: 이 프로세스가 지금 실제로 돌리고 있는 시도. 앱을 다시 켠 직후에는 비어 있다.
    static func next(_ snapshot: OrchestrationSnapshot, inFlight: Set<String> = []) -> SchedulerDecision {
        let job = snapshot.job
        guard job.state == .running else { return .idle(.jobNotRunning(job.state)) }

        let tasks = snapshot.activeTasks
        let taskIDs = Set(tasks.map(\.id))
        let attempts = snapshot.attempts.filter { taskIDs.contains($0.taskID) }

        // 전달 여부를 모르는 시도가 있으면 아무것도 새로 보내지 않는다.
        let unknown = attempts.filter { $0.state == .deliveryUnknown }.map(\.id)
        if !unknown.isEmpty { return .needsUser(.deliveryUnknown(attemptIDs: unknown)) }

        let active = attempts.filter { $0.state.isActive }
        if let owned = active.first(where: { inFlight.contains($0.id) }) { return .idle(.waitingForAttempt(owned.id)) }
        let orphaned = active.filter { $0.state != .verifying }.map(\.id)
        if !orphaned.isEmpty { return .recover(attemptIDs: orphaned) }
        if let unverified = active.first { return .verify(attemptID: unverified.id) }

        // 선행 작업이 끝났는데 통과하지 못했으면 뒤 작업은 시작할 수 없다.
        let byPlanID = Dictionary(tasks.map { ($0.planTaskID, $0) }, uniquingKeysWith: { first, _ in first })
        let unreachable = tasks.filter { task in
            !task.state.isTerminal && task.dependsOn.contains { dependency in
                guard let target = byPlanID[dependency] else { return false }
                return target.state.isTerminal && target.state != .succeeded
            }
        }
        // 필수 작업이 그렇게 막혔다면 전체가 끝난 것이다 (아래에서 실패로 판정). 선택 작업만 취소한다.
        let skippable = unreachable.filter(\.optional).map(\.id)
        if !skippable.isEmpty { return .markUnreachable(taskIDs: skippable) }

        if let failed = tasks.first(where: { !$0.optional && $0.state.isTerminal && $0.state != .succeeded }) {
            return .fail(.requiredTaskFailed(taskID: failed.id))
        }

        let candidates = tasks.filter { !$0.state.isTerminal && $0.state != .blocked }
        // 하던 작업을 먼저 끝낸다. 그다음 계획 순서대로 시작할 수 있는 첫 작업.
        let resumable = candidates.first { $0.state == .retryPending || $0.state == .escalationPending }
        // routing 인데 활성 시도가 없으면 아무것도 보내지 않은 것이다 (시도는 보내기 전에 저장한다). 다시 시작해도 된다.
        let startable = candidates.first { task in
            [.pending, .ready, .routing].contains(task.state)
                && task.dependsOn.allSatisfy { byPlanID[$0]?.state == .succeeded }
        }
        if let task = resumable ?? startable {
            if attempts.count >= job.budget.maxTotalAttempts { return .needsUser(.budgetExhausted) }
            let previous = snapshot.attempts(for: task.id)
            let kind: AttemptKind
            switch task.state {
            case .retryPending: kind = .retry
            case .escalationPending:
                kind = previous.last?.failureClass == .limitReached ? .availabilitySwitch : .escalation
            default: kind = .first
            }
            return .dispatch(DispatchPlan(
                taskID: task.id, attemptNumber: (previous.last?.number ?? 0) + 1, kind: kind,
                reuseProfileID: kind == .retry ? previous.last?.profileID : nil,
                excludedProfileIDs: kind == .retry ? [] : OrchestrationFailurePolicy.visitedProfiles(previous)))
        }

        let blocked = tasks.filter { $0.state == .blocked }.map(\.id)
        if !blocked.isEmpty { return .needsUser(.blocked(taskIDs: blocked)) }

        let requiredDone = tasks.filter { !$0.optional }.allSatisfy { $0.state == .succeeded }
        let optionalSettled = tasks.filter(\.optional).allSatisfy { $0.state.isTerminal }
        if requiredDone && optionalSettled {
            switch job.finalVerification {
            case .notStarted: return .runFinalVerification
            case .passed: return .complete
            // 하위 작업이 모두 통과해도 통합 검증이 실패하면 완료로 표시하지 않는다.
            case .failed: return .needsUser(.finalVerificationFailed)
            }
        }
        // 남은 작업이 있는데 시작할 수 있는 것이 없다 (선행 작업이 막혀 있다).
        return .needsUser(.blocked(taskIDs: candidates.map(\.id)))
    }

    /// 늦게 도착한 결과를 받아들일지. 중단 · 재계획 뒤에 온 결과가 취소한 계획을 되살리지 못하게 한다.
    static func accepts(resultFor attempt: OrchestrationAttempt, in snapshot: OrchestrationSnapshot) -> Bool {
        guard attempt.generation == snapshot.job.generation, !snapshot.job.state.isTerminal,
              let current = snapshot.attempts.first(where: { $0.id == attempt.id }), !current.state.isTerminal,
              let task = snapshot.tasks.first(where: { $0.id == attempt.taskID }) else { return false }
        return task.planVersion == snapshot.job.activePlanVersion && !task.state.isTerminal
    }

    /// 재계획할 때 대체할 작업: 이전 계획 버전의 끝나지 않은 작업. 통과한 작업은 그대로 둔다.
    static func supersededByReplan(_ snapshot: OrchestrationSnapshot, newPlanVersion: Int) -> [String] {
        snapshot.tasks.filter { $0.planVersion < newPlanVersion && !$0.state.isTerminal }.map(\.id)
    }
}

// MARK: - 실패 뒤의 행동

enum FailureDecision: Equatable, Sendable {
    /// 실패 근거를 주고 같은 프로필로 보완한다.
    case retrySameProfile
    /// 그 작업 유형의 승격 경로에서 다음 프로필로 넘긴다.
    case escalate
    /// 한도 때문에 쓸 수 있는 다른 프로필 · 계정으로 넘긴다. 능력 승격이 아니다.
    case switchForAvailability
    case retryAfterBackoff(seconds: Int)
    case askUser
    case replan
    /// 전달 여부를 모른다. 자동으로 진행하지 않는다.
    case stopForRecovery
    case cancel
    case failTask
}

enum OrchestrationFailurePolicy {

    /// 실패한 시도 뒤에 무엇을 할지.
    /// - Parameters:
    ///   - attempts: 그 작업의 시도 전부 (방금 실패한 것 포함, 순서대로).
    ///   - nextProfileAvailable: 아직 써 보지 않은 프로필이 승격 경로 · 가용 후보에 남아 있는가.
    static func decide(after failure: FailureClass, attempts: [OrchestrationAttempt],
                       job: OrchestrationJob, nextProfileAvailable: Bool) -> FailureDecision {
        let budget = job.budget
        switch failure {
        case .userCancelled: return .cancel
        case .deliveryUnknown: return .stopForRecovery
        case .environment, .ambiguousRequirement: return .askUser
        case .planDefect: return job.replanCount < budget.maxReplans ? .replan : .askUser
        default: break
        }
        // 서로 다른 상한이 번갈아 걸리며 끝없이 도는 것을 막는 마지막 울타리.
        if attempts.count >= budget.maxAttemptsPerTaskOfAnyKind { return .askUser }

        switch failure {
        case .transientNetwork:
            let transient = attempts.filter { $0.failureClass == .transientNetwork }.count
            guard transient <= budget.maxTransientRetries else { return .askUser }
            return .retryAfterBackoff(seconds: min(5 * (1 << max(transient - 1, 0)), 60))

        case .limitReached:
            return nextProfileAvailable ? .switchForAvailability : .askUser

        case .verificationFailed:
            let counted = attempts.filter { $0.failureClass?.countsAgainstModel == true }
            guard counted.count < budget.maxAttemptsPerTask, let last = counted.last else { return .failTask }
            let onThisProfile = counted.filter { $0.profileID == last.profileID }
            let noProgress = onThisProfile.count >= 2 && last.failureFingerprint != nil
                && onThisProfile[onThisProfile.count - 2].failureFingerprint == last.failureFingerprint
            if onThisProfile.count <= budget.maxSameProfileRetries && !noProgress { return .retrySameProfile }
            return nextProfileAvailable ? .escalate : .failTask

        default:
            return .askUser
        }
    }

    /// 이 작업에 이미 써 본 프로필 (처음 쓴 순서). 담당을 바꿀 때 후보에서 뺀다.
    static func visitedProfiles(_ attempts: [OrchestrationAttempt]) -> [String] {
        var seen = Set<String>()
        return attempts.sorted { $0.number < $1.number }.map(\.profileID).filter { seen.insert($0).inserted }
    }

    /// 결정을 하위 작업 상태로. nil 이면 작업 상태는 그대로 두고 전체 작업 쪽에서 처리한다 (재계획).
    static func taskState(for decision: FailureDecision) -> TaskState? {
        switch decision {
        case .retrySameProfile, .retryAfterBackoff: return .retryPending
        case .escalate, .switchForAvailability: return .escalationPending
        case .askUser, .stopForRecovery: return .blocked
        case .cancel: return .cancelled
        case .failTask: return .failed
        case .replan: return nil
        }
    }
}
