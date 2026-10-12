import Foundation

// 오케스트레이션 저장 (스키마 v7). 기존 `Store` 와 같은 DB · 같은 인스턴스를 쓴다.
//
// 규칙:
// - 상태가 바뀌는 쓰기는 `applyOrchestration` 하나로 한다. 상태 변경과 전이 기록(orchestration_transition)이
//   한 트랜잭션이고, 허용되지 않는 전이는 저장하지 않고 던진다. 저장에 실패하면 다음 CLI 를 시작하지 않는다.
// - 시도는 CLI 로 보내기 **전에** 저장한다. `(task_id, attempt_number)` 와 `dispatch_token` 이 유일해서
//   같은 시도를 두 번 만들 수 없다. 프로세스 실행은 트랜잭션에 묶을 수 없으므로 exactly-once 는 아니다.
// - 앱을 다시 켠 뒤의 복구는 화면 상태가 아니라 여기서 읽은 스냅샷으로 한다.

enum OrchestrationStoreError: LocalizedError, Equatable {
    case illegalTransition(entity: String, id: String, from: String, to: String)
    case notFound(entity: String, id: String)

    var errorDescription: String? {
        switch self {
        case .illegalTransition(let entity, let id, let from, let to):
            return "허용되지 않는 상태 전이라 저장하지 않았습니다: \(entity) \(id) \(from) → \(to)"
        case .notFound(let entity, let id):
            return "찾지 못했습니다: \(entity) \(id)"
        }
    }
}

/// 한 번에 원자적으로 저장할 변경. 같은 원인(`cause`)으로 함께 바뀌는 것들을 묶는다
/// (예: 시도 실패 + 하위 작업 보완 예정 + 검증 기록).
struct OrchestrationChanges: Sendable {
    var cause: String
    var job: OrchestrationJob?
    var tasks: [OrchestrationTask] = []
    var newAttempts: [OrchestrationAttempt] = []
    var attempts: [OrchestrationAttempt] = []
    var verifications: [VerificationRecord] = []
    var routingDecisions: [RoutingDecisionRecord] = []
}

struct OrchestrationTransitionRecord: Equatable, Sendable {
    var sequence: Int
    var entity: String
    var entityID: String
    var from: String?
    var to: String
    var cause: String
}

extension Store {

    // MARK: - 만들기

    /// 전체 작업을 만든다 (계획 전). 상태는 호출자가 정한 그대로 저장한다.
    func insertOrchestrationJob(_ job: OrchestrationJob) async throws {
        try await db.transaction([
            Self.insertJobStatement(job),
            Self.transitionStatement(jobID: job.id, entity: "job", id: job.id, table: nil,
                                     to: job.state.rawValue, cause: "작업 생성"),
        ])
    }

    /// 계획 한 버전을 들인다: 계획 · 하위 작업 · 의존 관계 저장, 이전 버전의 끝나지 않은 작업 대체,
    /// 전체 작업의 계획 버전 · 세대 갱신을 한 트랜잭션으로 한다. 첫 계획과 재계획이 같은 길을 쓴다.
    func installOrchestrationPlan(job: OrchestrationJob, plan: OrchestrationPlan, tasks: [OrchestrationTask],
                                  plannerRunID: String?, supersededTaskIDs: [String] = [],
                                  cause: String) async throws {
        try await checkJobTransition(job)
        var statements: [(String, [SQLValue])] = []
        let planJSON = Self.json(plan)
        statements.append(("""
            INSERT INTO orchestration_plan(job_id, version, planner_run_id, schema_version, plan_json, source_hash, created_at)
            VALUES(?,?,?,?,?,?,?);
            """, [.text(job.id), .int(Int64(job.activePlanVersion)), .optText(plannerRunID),
                  .int(Int64(PlanSchema.version)), .text(planJSON), .text(Self.hash(planJSON)), .date(Date())]))
        for id in supersededTaskIDs {
            statements.append(Self.transitionStatement(jobID: job.id, entity: "task", id: id, table: "orchestration_task",
                                                       to: TaskState.superseded.rawValue, cause: cause))
            statements.append(("UPDATE orchestration_task SET state = ? WHERE id = ? AND job_id = ?;",
                               [.text(TaskState.superseded.rawValue), .text(id), .text(job.id)]))
        }
        let idByPlanID = Dictionary(tasks.map { ($0.planTaskID, $0.id) }, uniquingKeysWith: { first, _ in first })
        for task in tasks {
            statements.append(Self.insertTaskStatement(task))
            statements.append(Self.transitionStatement(jobID: job.id, entity: "task", id: task.id, table: nil,
                                                       to: task.state.rawValue, cause: cause))
        }
        for task in tasks {
            for dependency in task.dependsOn {
                guard let target = idByPlanID[dependency] else { continue }
                statements.append(("INSERT INTO orchestration_dependency(task_id, depends_on_task_id) VALUES(?,?);",
                                   [.text(task.id), .text(target)]))
            }
        }
        statements.append(Self.transitionStatement(jobID: job.id, entity: "job", id: job.id, table: "orchestration_job",
                                                   to: job.state.rawValue, cause: cause))
        statements.append(Self.updateJobStatement(job))
        try await db.transaction(statements)
    }

    // MARK: - 상태 변경

    /// 변경 묶음을 원자적으로 저장한다. 허용되지 않는 전이가 하나라도 있으면 아무것도 저장하지 않는다.
    func applyOrchestration(_ changes: OrchestrationChanges, jobID: String) async throws {
        if let job = changes.job { try await checkJobTransition(job) }
        for task in changes.tasks {
            guard let current = try await orchestrationTaskState(id: task.id) else {
                throw OrchestrationStoreError.notFound(entity: "task", id: task.id)
            }
            guard current == task.state || current.canTransition(to: task.state) else {
                throw OrchestrationStoreError.illegalTransition(entity: "task", id: task.id,
                                                                from: current.rawValue, to: task.state.rawValue)
            }
        }
        for attempt in changes.attempts {
            guard let current = try await orchestrationAttemptState(id: attempt.id) else {
                throw OrchestrationStoreError.notFound(entity: "attempt", id: attempt.id)
            }
            guard current == attempt.state || current.canTransition(to: attempt.state) else {
                throw OrchestrationStoreError.illegalTransition(entity: "attempt", id: attempt.id,
                                                                from: current.rawValue, to: attempt.state.rawValue)
            }
        }

        var statements: [(String, [SQLValue])] = []
        // 전이 기록은 상태를 바꾸기 전에 쓴다 — 이전 상태를 같은 트랜잭션 안에서 읽어 넣는다.
        for attempt in changes.newAttempts {
            statements.append(Self.insertAttemptStatement(attempt))
            statements.append(Self.transitionStatement(jobID: jobID, entity: "attempt", id: attempt.id, table: nil,
                                                       to: attempt.state.rawValue, cause: changes.cause))
        }
        for attempt in changes.attempts {
            statements.append(Self.transitionStatement(jobID: jobID, entity: "attempt", id: attempt.id,
                                                       table: "orchestration_attempt",
                                                       to: attempt.state.rawValue, cause: changes.cause))
            statements.append(("""
                UPDATE orchestration_attempt SET state = ?, run_id = ?, routing_decision_id = ?, failure_class = ?,
                       failure_fingerprint = ?, result_summary = ?, ended_at = ? WHERE id = ?;
                """, [.text(attempt.state.rawValue), .optText(attempt.runID), .optText(attempt.routingDecisionID),
                      .optText(attempt.failureClass?.rawValue), .optText(attempt.failureFingerprint),
                      .optText(attempt.resultSummary), .date(attempt.endedAt), .text(attempt.id)]))
        }
        for task in changes.tasks {
            statements.append(Self.transitionStatement(jobID: jobID, entity: "task", id: task.id,
                                                       table: "orchestration_task",
                                                       to: task.state.rawValue, cause: changes.cause))
            statements.append(("UPDATE orchestration_task SET state = ?, child_thread_id = ?, blocked_reason = ? WHERE id = ?;",
                               [.text(task.state.rawValue), .optText(task.childThreadID),
                                .optText(task.blockedReason), .text(task.id)]))
        }
        for record in changes.verifications { statements.append(Self.insertVerificationStatement(record)) }
        for record in changes.routingDecisions { statements.append(Self.insertRoutingStatement(record)) }
        if let job = changes.job {
            statements.append(Self.transitionStatement(jobID: jobID, entity: "job", id: job.id, table: "orchestration_job",
                                                       to: job.state.rawValue, cause: changes.cause))
            statements.append(Self.updateJobStatement(job))
        }
        guard !statements.isEmpty else { return }
        try await db.transaction(statements)
    }

    // MARK: - 읽기

    func orchestrationJob(id: String) async throws -> OrchestrationJob? {
        try await db.query("SELECT * FROM orchestration_job WHERE id = ?;", [.text(id)]).first.map(Self.jobRow)
    }

    func orchestrationJobs(parentThreadID: String) async throws -> [OrchestrationJob] {
        try await db.query("SELECT * FROM orchestration_job WHERE parent_thread_id = ? ORDER BY created_at DESC;",
                           [.text(parentThreadID)]).map(Self.jobRow)
    }

    /// 끝나지 않은 전체 작업. 앱을 다시 켰을 때 복구 검사의 출발점이다.
    func unfinishedOrchestrationJobs() async throws -> [OrchestrationJob] {
        let terminal = JobState.allCases.filter(\.isTerminal).map { "'\($0.rawValue)'" }.joined(separator: ",")
        return try await db.query(
            "SELECT * FROM orchestration_job WHERE state NOT IN (\(terminal)) ORDER BY created_at;")
            .map(Self.jobRow)
    }

    func orchestrationPlan(jobID: String, version: Int) async throws -> OrchestrationPlan? {
        let row = try await db.query("SELECT plan_json FROM orchestration_plan WHERE job_id = ? AND version = ?;",
                                     [.text(jobID), .int(Int64(version))]).first
        guard let data = row?.text("plan_json")?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OrchestrationPlan.self, from: data)
    }

    /// 스케줄러가 보는 한 시점의 전체 상태.
    func orchestrationSnapshot(jobID: String) async throws -> OrchestrationSnapshot? {
        guard let job = try await orchestrationJob(id: jobID) else { return nil }
        let dependencyRows = try await db.query("""
            SELECT d.task_id AS task_id, t.plan_task_id AS plan_task_id
            FROM orchestration_dependency d
            JOIN orchestration_task t ON t.id = d.depends_on_task_id
            WHERE t.job_id = ? ORDER BY t.ordinal;
            """, [.text(jobID)])
        var dependencies: [String: [String]] = [:]
        for row in dependencyRows { dependencies[row.textValue("task_id"), default: []].append(row.textValue("plan_task_id")) }
        let tasks = try await db.query(
            "SELECT * FROM orchestration_task WHERE job_id = ? ORDER BY plan_version, ordinal;", [.text(jobID)])
            .map { Self.taskRow($0, dependsOn: dependencies[$0.textValue("id")] ?? []) }
        let attempts = try await db.query(
            "SELECT * FROM orchestration_attempt WHERE job_id = ? ORDER BY created_at, attempt_number;", [.text(jobID)])
            .map(Self.attemptRow)
        return OrchestrationSnapshot(job: job, tasks: tasks, attempts: attempts)
    }

    /// 실행(run)이 끝났을 때 그 주인을 찾는다: runID → 시도 → 하위 작업 → 전체 작업. 화면에서 고른 대화와 무관하다.
    func orchestrationAttempt(runID: String) async throws -> OrchestrationAttempt? {
        try await db.query("SELECT * FROM orchestration_attempt WHERE run_id = ?;", [.text(runID)])
            .first.map(Self.attemptRow)
    }

    /// 전체 작업의 내부 대화 (계획 · 검토 · 하위 작업). 사이드바에는 나오지 않는다.
    func orchestrationThreads(jobID: String) async throws -> [ConversationThread] {
        try await allThreads().filter { $0.orchestrationJobID == jobID }
    }

    /// 성과 지표용: 모든 전체 작업의 시도와 검증 기록.
    func allOrchestrationAttempts() async throws -> [OrchestrationAttempt] {
        try await db.query("SELECT * FROM orchestration_attempt ORDER BY created_at;").map(Self.attemptRow)
    }

    func allVerificationRecords() async throws -> [VerificationRecord] {
        var all: [VerificationRecord] = []
        for row in try await db.query("SELECT DISTINCT job_id FROM verification_result;") {
            all += try await verificationRecords(jobID: row.textValue("job_id"))
        }
        return all
    }

    func orchestrationTransitions(jobID: String) async throws -> [OrchestrationTransitionRecord] {
        try await db.query("SELECT * FROM orchestration_transition WHERE job_id = ? ORDER BY sequence;", [.text(jobID)])
            .map { OrchestrationTransitionRecord(sequence: $0.intValue("sequence"), entity: $0.textValue("entity"),
                                                 entityID: $0.textValue("entity_id"), from: $0.text("from_state"),
                                                 to: $0.textValue("to_state"), cause: $0.textValue("cause")) }
    }

    func verificationRecords(jobID: String) async throws -> [VerificationRecord] {
        try await db.query("SELECT * FROM verification_result WHERE job_id = ? ORDER BY created_at;", [.text(jobID)])
            .map { VerificationRecord(id: $0.textValue("id"), jobID: $0.textValue("job_id"), taskID: $0.text("task_id"),
                                      attemptID: $0.text("attempt_id"), verifierVersion: $0.textValue("verifier_version"),
                                      criterion: $0.textValue("criterion"),
                                      outcome: VerificationOutcome(rawValue: $0.textValue("outcome")) ?? .inconclusive,
                                      evidenceJSON: $0.textValue("evidence_json"),
                                      workspaceFingerprint: $0.text("workspace_fingerprint"),
                                      createdAt: $0.dateValue("created_at")) }
    }

    func routingDecisions(jobID: String) async throws -> [RoutingDecisionRecord] {
        try await db.query("SELECT * FROM routing_decision WHERE job_id = ? ORDER BY created_at;", [.text(jobID)])
            .map { RoutingDecisionRecord(id: $0.textValue("id"), jobID: $0.textValue("job_id"), taskID: $0.text("task_id"),
                                         featureSource: FeatureSource(rawValue: $0.textValue("feature_source")) ?? .staticRules,
                                         featureVersion: $0.textValue("feature_version"), inputHash: $0.textValue("input_hash"),
                                         inputSummary: $0.textValue("input_summary"), featuresJSON: $0.textValue("features_json"),
                                         candidatesJSON: $0.textValue("candidates_json"), selectedProfile: $0.text("selected_profile"),
                                         reasonCodesJSON: $0.textValue("reason_codes_json"),
                                         policyVersion: $0.textValue("policy_version"),
                                         latencyMs: $0.int("latency_ms").map(Int.init), usageJSON: $0.text("usage_json"),
                                         createdAt: $0.dateValue("created_at")) }
    }

    // MARK: - 전이 검사

    private func checkJobTransition(_ job: OrchestrationJob) async throws {
        guard let row = try await db.query("SELECT state FROM orchestration_job WHERE id = ?;", [.text(job.id)]).first,
              let current = JobState(rawValue: row.textValue("state")) else {
            throw OrchestrationStoreError.notFound(entity: "job", id: job.id)
        }
        guard current == job.state || current.canTransition(to: job.state) else {
            throw OrchestrationStoreError.illegalTransition(entity: "job", id: job.id,
                                                            from: current.rawValue, to: job.state.rawValue)
        }
    }

    private func orchestrationTaskState(id: String) async throws -> TaskState? {
        try await db.query("SELECT state FROM orchestration_task WHERE id = ?;", [.text(id)])
            .first.flatMap { TaskState(rawValue: $0.textValue("state")) }
    }

    private func orchestrationAttemptState(id: String) async throws -> AttemptState? {
        try await db.query("SELECT state FROM orchestration_attempt WHERE id = ?;", [.text(id)])
            .first.flatMap { AttemptState(rawValue: $0.textValue("state")) }
    }

    // MARK: - 문장

    /// 전이 기록 한 줄. `table` 이 있으면 이전 상태를 그 테이블에서 읽고, **상태가 실제로 바뀔 때만** 남긴다.
    /// 반드시 같은 트랜잭션에서 상태를 바꾸는 UPDATE 보다 먼저 실행한다.
    private static func transitionStatement(jobID: String, entity: String, id: String, table: String?,
                                            to: String, cause: String) -> (String, [SQLValue]) {
        let sequence = "COALESCE((SELECT MAX(sequence) FROM orchestration_transition WHERE job_id = ?), 0) + 1"
        guard let table else {
            return ("""
                INSERT INTO orchestration_transition(job_id, entity, entity_id, from_state, to_state, cause, sequence, created_at)
                VALUES(?, ?, ?, NULL, ?, ?, \(sequence), ?);
                """, [.text(jobID), .text(entity), .text(id), .text(to), .text(cause), .text(jobID), .date(Date())])
        }
        return ("""
            INSERT INTO orchestration_transition(job_id, entity, entity_id, from_state, to_state, cause, sequence, created_at)
            SELECT ?, ?, ?, state, ?, ?, \(sequence), ? FROM \(table) WHERE id = ? AND state <> ?;
            """, [.text(jobID), .text(entity), .text(id), .text(to), .text(cause), .text(jobID), .date(Date()),
                  .text(id), .text(to)])
    }

    private static func insertJobStatement(_ j: OrchestrationJob) -> (String, [SQLValue]) {
        ("""
        INSERT INTO orchestration_job(id, project_id, parent_thread_id, user_request_event_id, request, state,
            active_plan_version, generation, replan_count, final_verification, budget_json, policy_version,
            created_at, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [.text(j.id), .text(j.projectID), .text(j.parentThreadID), .optText(j.userRequestEventID),
              .text(j.request), .text(j.state.rawValue), .int(Int64(j.activePlanVersion)), .int(Int64(j.generation)),
              .int(Int64(j.replanCount)), .text(j.finalVerification.rawValue), .text(json(j.budget)),
              .text(j.policyVersion), .date(j.createdAt), .date(j.updatedAt)])
    }

    private static func updateJobStatement(_ j: OrchestrationJob) -> (String, [SQLValue]) {
        ("""
        UPDATE orchestration_job SET state = ?, active_plan_version = ?, generation = ?, replan_count = ?,
               final_verification = ?, budget_json = ?, policy_version = ?, user_request_event_id = ?, updated_at = ?
        WHERE id = ?;
        """, [.text(j.state.rawValue), .int(Int64(j.activePlanVersion)), .int(Int64(j.generation)),
              .int(Int64(j.replanCount)), .text(j.finalVerification.rawValue), .text(json(j.budget)),
              .text(j.policyVersion), .optText(j.userRequestEventID), .date(Date()), .text(j.id)])
    }

    private static func insertTaskStatement(_ t: OrchestrationTask) -> (String, [SQLValue]) {
        ("""
        INSERT INTO orchestration_task(id, job_id, plan_version, plan_task_id, ordinal, title, specification, kind,
            difficulty, acceptance_json, verification, paths_json, optional, state, child_thread_id, blocked_reason)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [.text(t.id), .text(t.jobID), .int(Int64(t.planVersion)), .text(t.planTaskID), .int(Int64(t.ordinal)),
              .text(t.title), .text(t.specification), .text(t.kind.rawValue), .int(Int64(t.difficulty)),
              .text(json(t.acceptance)), .text(t.verification), .text(json(t.paths)), .bool(t.optional),
              .text(t.state.rawValue), .optText(t.childThreadID), .optText(t.blockedReason)])
    }

    private static func insertAttemptStatement(_ a: OrchestrationAttempt) -> (String, [SQLValue]) {
        ("""
        INSERT INTO orchestration_attempt(id, task_id, job_id, attempt_number, kind, profile_id, routing_decision_id,
            run_id, dispatch_token, generation, state, failure_class, failure_fingerprint, result_summary,
            created_at, ended_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [.text(a.id), .text(a.taskID), .text(a.jobID), .int(Int64(a.number)), .text(a.kind.rawValue),
              .text(a.profileID), .optText(a.routingDecisionID), .optText(a.runID), .text(a.dispatchToken),
              .int(Int64(a.generation)), .text(a.state.rawValue), .optText(a.failureClass?.rawValue),
              .optText(a.failureFingerprint), .optText(a.resultSummary), .date(a.createdAt), .date(a.endedAt)])
    }

    private static func insertVerificationStatement(_ v: VerificationRecord) -> (String, [SQLValue]) {
        ("""
        INSERT INTO verification_result(id, job_id, task_id, attempt_id, verifier_version, criterion, outcome,
            evidence_json, workspace_fingerprint, created_at) VALUES(?,?,?,?,?,?,?,?,?,?);
        """, [.text(v.id), .text(v.jobID), .optText(v.taskID), .optText(v.attemptID), .text(v.verifierVersion),
              .text(v.criterion), .text(v.outcome.rawValue), .text(v.evidenceJSON),
              .optText(v.workspaceFingerprint), .date(v.createdAt)])
    }

    private static func insertRoutingStatement(_ r: RoutingDecisionRecord) -> (String, [SQLValue]) {
        ("""
        INSERT INTO routing_decision(id, job_id, task_id, feature_source, feature_version, input_hash, input_summary,
            features_json, candidates_json, selected_profile, reason_codes_json, policy_version, latency_ms,
            usage_json, created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [.text(r.id), .text(r.jobID), .optText(r.taskID), .text(r.featureSource.rawValue), .text(r.featureVersion),
              .text(r.inputHash), .text(r.inputSummary), .text(r.featuresJSON), .text(r.candidatesJSON),
              .optText(r.selectedProfile), .text(r.reasonCodesJSON), .text(r.policyVersion),
              .optInt(r.latencyMs), .optText(r.usageJSON), .date(r.createdAt)])
    }

    // MARK: - 행 매핑

    private static func jobRow(_ r: SQLRow) -> OrchestrationJob {
        OrchestrationJob(id: r.textValue("id"), projectID: r.textValue("project_id"),
                         parentThreadID: r.textValue("parent_thread_id"),
                         userRequestEventID: r.text("user_request_event_id"), request: r.textValue("request"),
                         state: JobState(rawValue: r.textValue("state")) ?? .failed,
                         activePlanVersion: r.intValue("active_plan_version"), generation: r.intValue("generation"),
                         replanCount: r.intValue("replan_count"),
                         finalVerification: FinalVerificationState(rawValue: r.textValue("final_verification")) ?? .notStarted,
                         budget: decode(OrchestrationBudget.self, r.text("budget_json")) ?? OrchestrationBudget(),
                         policyVersion: r.textValue("policy_version"),
                         createdAt: r.dateValue("created_at"), updatedAt: r.dateValue("updated_at"))
    }

    private static func taskRow(_ r: SQLRow, dependsOn: [String]) -> OrchestrationTask {
        OrchestrationTask(id: r.textValue("id"), jobID: r.textValue("job_id"), planVersion: r.intValue("plan_version"),
                          planTaskID: r.textValue("plan_task_id"), ordinal: r.intValue("ordinal"),
                          title: r.textValue("title"), specification: r.textValue("specification"),
                          kind: TaskKind(rawValue: r.textValue("kind")) ?? .other, difficulty: r.intValue("difficulty"),
                          dependsOn: dependsOn, acceptance: decode([String].self, r.text("acceptance_json")) ?? [],
                          verification: r.textValue("verification"), paths: decode([String].self, r.text("paths_json")) ?? [],
                          optional: r.bool("optional"), state: TaskState(rawValue: r.textValue("state")) ?? .blocked,
                          childThreadID: r.text("child_thread_id"), blockedReason: r.text("blocked_reason"))
    }

    private static func attemptRow(_ r: SQLRow) -> OrchestrationAttempt {
        OrchestrationAttempt(id: r.textValue("id"), taskID: r.textValue("task_id"), jobID: r.textValue("job_id"),
                             number: r.intValue("attempt_number"), kind: AttemptKind(rawValue: r.textValue("kind")) ?? .first,
                             profileID: r.textValue("profile_id"), routingDecisionID: r.text("routing_decision_id"),
                             runID: r.text("run_id"), dispatchToken: r.textValue("dispatch_token"),
                             generation: r.intValue("generation"),
                             // 모르는 값은 끝난 것으로 읽지 않는다. 사람이 확인해야 하는 상태로 둔다.
                             state: AttemptState(rawValue: r.textValue("state")) ?? .deliveryUnknown,
                             failureClass: r.text("failure_class").flatMap(FailureClass.init(rawValue:)),
                             failureFingerprint: r.text("failure_fingerprint"),
                             resultSummary: r.text("result_summary"),
                             createdAt: r.dateValue("created_at"), endedAt: r.date("ended_at"))
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ text: String?) -> T? {
        text?.data(using: .utf8).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    /// 같은 계획인지 알아보는 지문. 보안 용도가 아니다.
    private static func hash(_ text: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
