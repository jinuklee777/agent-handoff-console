import Foundation

// MARK: - 오케스트레이션: 계획 검사 · 상태 전이 · 스케줄러 · 저장

/// 순수 판정과 저장 계층만 검증한다. CLI · 네트워크를 쓰지 않는다.
enum OrchestrationTests {

    static func run(_ t: TestKit) async {
        await planValidation(t)
        await transitions(t)
        await scheduling(t)
        await failurePolicy(t)
        await simulatedJobs(t)
        await storage(t)
    }

    // MARK: 표본

    static func task(_ id: String, dependsOn: [String] = [], optional: Bool = false) -> PlannedTask {
        PlannedTask(id: id, title: "작업 \(id)", specification: "\(id) 를 한다", kind: .implement, difficulty: 2,
                    dependsOn: dependsOn, acceptance: ["\(id) 가 동작한다"], verification: "inttest offline",
                    paths: ["Sources/\(id).swift"], optional: optional)
    }

    static func plan(_ tasks: [PlannedTask]) -> OrchestrationPlan {
        OrchestrationPlan(goal: "기능을 만든다", assumptions: [], openQuestions: [],
                          needsDecomposition: tasks.count > 1, infoSufficient: true, tasks: tasks,
                          finalAcceptance: ["전체 테스트 통과"])
    }

    static func snapshot(_ plan: OrchestrationPlan, state: JobState = .running) -> OrchestrationSnapshot {
        var job = OrchestrationJob(projectID: "p", parentThreadID: "t", request: "요청")
        job.state = state
        job.activePlanVersion = 1
        return OrchestrationSnapshot(job: job, tasks: OrchestrationTask.make(from: plan, jobID: job.id, planVersion: 1),
                                     attempts: [])
    }

    // MARK: 계획 검사

    private static func planValidation(_ t: TestKit) async {
        await t.group("오케스트레이션: 계획 검사")
        let good = plan([task("a"), task("b", dependsOn: ["a"]), task("c", dependsOn: ["a", "b"])])
        await t.equal("올바른 계획은 문제 없음", PlanValidator.validate(good), [])
        await t.equal("실행 순서", PlanValidator.executionOrder(good.tasks), ["a", "b", "c"])
        await t.equal("뒤에 적힌 선행 작업도 순서를 지킨다",
                      PlanValidator.executionOrder([task("x", dependsOn: ["y"]), task("y")]), ["y", "x"])

        func issues(_ p: OrchestrationPlan) -> [PlanIssue] { PlanValidator.validate(p) }
        await t.check("순환", issues(plan([task("a", dependsOn: ["b"]), task("b", dependsOn: ["a"])]))
            .contains(.dependencyCycle(["a", "b"])))
        await t.check("순환이면 실행 순서 없음",
                      PlanValidator.executionOrder([task("a", dependsOn: ["b"]), task("b", dependsOn: ["a"])]) == nil)
        await t.check("자기 의존", issues(plan([task("a", dependsOn: ["a"]), task("b")])).contains(.selfDependency(task: "a")))
        await t.check("없는 의존", issues(plan([task("a", dependsOn: ["zz"]), task("b")]))
            .contains(.unknownDependency(task: "a", dependency: "zz")))
        await t.check("겹치는 id", issues(plan([task("a"), task("a")])).contains(.duplicateTaskID("a")))
        await t.check("작업 수 상한", issues(plan((1...9).map { task("t\($0)") })).contains(.tooManyTasks(count: 9, max: 8)))
        await t.check("작업 없음", issues(plan([])) == [.noTasks])

        var noAcceptance = task("a"); noAcceptance.acceptance = ["  "]
        await t.check("완료 조건 누락", issues(plan([noAcceptance])).contains(.missingAcceptance(task: "a")))
        var noVerification = task("a"); noVerification.verification = ""
        await t.check("검증 방법 누락", issues(plan([noVerification])).contains(.missingVerification(task: "a")))
        var hard = task("a"); hard.difficulty = 9
        await t.check("난이도 범위", issues(plan([hard])).contains(.difficultyOutOfRange(task: "a", value: 9)))
        for path in ["/etc/passwd", "~/x", "../secret", "a/../../b"] {
            var escaping = task("a"); escaping.paths = [path]
            await t.check("경로 이탈: \(path)", issues(plan([escaping])).contains(.pathEscapesProject(task: "a", path: path)))
        }
        var inside = task("a"); inside.paths = ["a/../b.swift", "./c.swift", ""]
        await t.check("프로젝트 안의 경로는 허용", issues(plan([inside])).isEmpty)

        var single = plan([task("a"), task("b")]); single.needsDecomposition = false
        await t.check("분해 불필요인데 여러 작업", issues(single).contains(.decomposedWithoutNeed(count: 2)))
        var unclear = plan([task("a")]); unclear.infoSufficient = false
        await t.check("정보 부족인데 질문 없음", issues(unclear).contains(.insufficientInfoWithoutQuestions))
        unclear.openQuestions = ["어느 화면인가요?"]
        await t.check("정보 부족 + 질문은 계획으로는 유효", issues(unclear).isEmpty)
        var noFinal = plan([task("a")]); noFinal.finalAcceptance = []
        await t.check("최종 통합 검증 조건 누락", issues(noFinal).contains(.missingFinalAcceptance))
        await t.check("필수 작업이 선택 작업에 의존",
                      issues(plan([task("a", optional: true), task("b", dependsOn: ["a"])]))
                        .contains(.requiredDependsOnOptional(task: "b", dependency: "a")))

        // 해석: 스키마를 지켰다고 믿지 않는다.
        let encoded = String(data: try! JSONEncoder().encode(good), encoding: .utf8)!
        if case .success(let decoded) = PlanValidator.accept(encoded) {
            await t.check("JSON 왕복", decoded == good)
        } else {
            await t.check("JSON 왕복", false)
        }
        for (name, json) in [("빈 응답", ""), ("JSON 아님", "계획입니다: {"), ("필드 누락", #"{"goal":"x"}"#),
                             ("모르는 kind", encoded.replacingOccurrences(of: "\"implement\"", with: "\"dance\""))] {
            if case .failure(let rejection) = PlanValidator.accept(json), case .invalidJSON = rejection.issues.first {
                await t.check("해석 거부: \(name)", true, rejection.issues.first?.message ?? "")
            } else {
                await t.check("해석 거부: \(name)", false)
            }
        }
        if case .failure(let rejection) = PlanValidator.accept(
            String(data: try! JSONEncoder().encode(plan([task("a", dependsOn: ["b"]), task("a")])), encoding: .utf8)!) {
            await t.check("문제를 한 번에 모두 돌려준다 (보정 요청용)", rejection.issues.count >= 2
                            && rejection.feedback.contains("겹칩니다") && rejection.feedback.contains("없는 작업"))
        } else {
            await t.check("문제를 한 번에 모두 돌려준다 (보정 요청용)", false)
        }

        // 스키마: Codex 구조화 응답의 요구 (모든 속성 required, additionalProperties false).
        let schema = PlanSchema.object()
        let properties = schema["properties"] as? [String: Any] ?? [:]
        await t.equal("스키마: 최상위 속성이 모두 required",
                      Set(schema["required"] as? [String] ?? []), Set(properties.keys))
        let item = (properties["tasks"] as? [String: Any])?["items"] as? [String: Any] ?? [:]
        await t.equal("스키마: 작업 속성이 모두 required",
                      Set(item["required"] as? [String] ?? []), Set((item["properties"] as? [String: Any] ?? [:]).keys))
        await t.check("스키마: 추가 속성 금지", schema["additionalProperties"] as? Bool == false
                        && item["additionalProperties"] as? Bool == false)
        await t.check("스키마: JSON 글로 넘길 수 있다", CodexAdapter.schemaObject(PlanSchema.jsonString) != nil)
        let mirror = Set(Mirror(reflecting: task("a")).children.compactMap(\.label))
        await t.equal("스키마의 작업 속성 = PlannedTask 의 필드", Set((item["properties"] as? [String: Any] ?? [:]).keys), mirror)
    }

    // MARK: 전이 표

    private static func transitions(_ t: TestKit) async {
        await t.group("오케스트레이션: 상태 전이")
        await t.check("끝난 전체 작업은 움직이지 않는다", JobState.allCases.filter(\.isTerminal).allSatisfy { from in
            JobState.allCases.allSatisfy { !from.canTransition(to: $0) }
        })
        await t.check("끝난 하위 작업은 움직이지 않는다", TaskState.allCases.filter(\.isTerminal).allSatisfy { from in
            TaskState.allCases.allSatisfy { !from.canTransition(to: $0) }
        })
        await t.check("끝난 시도는 움직이지 않는다", AttemptState.allCases.filter(\.isTerminal).allSatisfy { from in
            AttemptState.allCases.allSatisfy { !from.canTransition(to: $0) }
        })
        await t.check("실행이 끝나도 검증 전에는 통과가 아니다", !TaskState.running.canTransition(to: .succeeded)
                        && TaskState.verifying.canTransition(to: .succeeded))
        await t.check("시도도 검증을 거쳐야 성공", !AttemptState.running.canTransition(to: .succeeded))
        await t.check("중단 중에는 중단됨으로만", JobState.allCases.filter { JobState.cancelling.canTransition(to: $0) } == [.cancelled])
        await t.check("전달 여부 미확인은 자동으로 다시 돌지 않는다", !AttemptState.deliveryUnknown.canTransition(to: .dispatching)
                        && !AttemptState.deliveryUnknown.canTransition(to: .running))
        await t.check("막힘은 실패와 다르다 (다시 시작할 수 있다)", TaskState.blocked.canTransition(to: .ready))
        await t.check("모든 상태가 끝에 닿을 수 있다", TaskState.allCases.allSatisfy { start in
            var seen: Set<TaskState> = [start], frontier = [start]
            while let s = frontier.popLast() {
                for n in TaskState.allCases where s.canTransition(to: n) && seen.insert(n).inserted { frontier.append(n) }
            }
            return seen.contains { $0.isTerminal }
        })
        await t.check("능력 실패로 세는 것은 검증 실패뿐",
                      FailureClass.allCases.filter(\.countsAgainstModel) == [.verificationFailed])
    }

    // MARK: 스케줄러

    private static func attempt(_ task: OrchestrationTask, _ number: Int, _ state: AttemptState,
                                profile: String = "A", failure: FailureClass? = nil, fingerprint: String? = nil,
                                generation: Int = 0) -> OrchestrationAttempt {
        OrchestrationAttempt(taskID: task.id, jobID: task.jobID, number: number, kind: .first, profileID: profile,
                             generation: generation, state: state, failureClass: failure, failureFingerprint: fingerprint)
    }

    private static func scheduling(_ t: TestKit) async {
        await t.group("오케스트레이션: 스케줄러")
        var s = snapshot(plan([task("a"), task("b", dependsOn: ["a"]), task("c", optional: true)]))
        let (a, b, c) = (s.tasks[0], s.tasks[1], s.tasks[2])

        func dispatched(_ d: SchedulerDecision) -> DispatchPlan? { if case .dispatch(let p) = d { return p } else { return nil } }

        await t.equal("실행 중이 아니면 아무것도 하지 않는다",
                      OrchestrationScheduler.next(snapshot(plan([task("a")]), state: .paused)), .idle(.jobNotRunning(.paused)))
        await t.equal("계획 순서의 첫 작업부터", dispatched(OrchestrationScheduler.next(s))?.taskID, a.id)
        await t.equal("첫 시도는 1번", dispatched(OrchestrationScheduler.next(s))?.attemptNumber, 1)

        // 돌리는 중: 새로 보내지 않는다 (실행 슬롯 하나 · 이중 전송 방지).
        let running = attempt(a, 1, .running)
        s.attempts = [running]; s.tasks[0].state = .running
        await t.equal("활성 시도가 있으면 기다린다", OrchestrationScheduler.next(s, inFlight: [running.id]),
                      .idle(.waitingForAttempt(running.id)))
        // 앱을 다시 켠 직후: 이 프로세스에 주인이 없는 활성 시도.
        await t.equal("주인 없는 활성 시도는 복구 대상 (다시 보내지 않는다)", OrchestrationScheduler.next(s),
                      .recover(attemptIDs: [running.id]))
        s.attempts[0].state = .verifying; s.tasks[0].state = .verifying
        await t.equal("검증 기록 없이 남은 시도는 다시 검증", OrchestrationScheduler.next(s), .verify(attemptID: running.id))
        s.attempts[0].state = .deliveryUnknown
        await t.equal("전달 여부 미확인이면 사람을 기다린다", OrchestrationScheduler.next(s),
                      .needsUser(.deliveryUnknown(attemptIDs: [running.id])))

        // a 통과 → b 가 열린다. 선행 작업이 통과하기 전에는 열리지 않는다.
        s.attempts[0].state = .succeeded; s.tasks[0].state = .succeeded
        await t.equal("선행 작업이 통과하면 다음 작업", dispatched(OrchestrationScheduler.next(s))?.taskID, b.id)
        s.tasks[0].state = .verifying
        s.attempts[0].state = .verifying
        await t.check("선행 작업이 검증 중이면 뒤 작업을 시작하지 않는다",
                      dispatched(OrchestrationScheduler.next(s, inFlight: [running.id])) == nil)
        s.tasks[0].state = .succeeded; s.attempts[0].state = .succeeded

        // 보완 · 담당 변경.
        let failedB = attempt(b, 1, .failed, profile: "A", failure: .verificationFailed)
        s.attempts.append(failedB); s.tasks[1].state = .retryPending
        var p = dispatched(OrchestrationScheduler.next(s))
        await t.equal("보완: 같은 프로필 · 다음 번호", "\(p?.kind.rawValue ?? "")/\(p?.reuseProfileID ?? "")/\(p?.attemptNumber ?? 0)", "retry/A/2")
        s.attempts.append(attempt(b, 2, .failed, profile: "A", failure: .verificationFailed)); s.tasks[1].state = .escalationPending
        p = dispatched(OrchestrationScheduler.next(s))
        await t.equal("담당 변경: 써 본 프로필은 후보에서 뺀다", "\(p?.kind.rawValue ?? "")/\(p?.excludedProfileIDs ?? [])", "escalation/[\"A\"]")
        s.attempts.append(attempt(b, 3, .failed, profile: "B", failure: .limitReached))
        p = dispatched(OrchestrationScheduler.next(s))
        await t.equal("한도 때문의 전환은 능력 승격과 따로 센다", "\(p?.kind.rawValue ?? "")/\(p?.excludedProfileIDs ?? [])",
                      "availabilitySwitch/[\"A\", \"B\"]")
        await t.check("하던 작업을 먼저 끝낸다 (선택 작업 c 보다 b)", p?.taskID == b.id)

        // 필수 작업 실패 → 전체 실패. 선택 작업 실패는 막지 않는다.
        s.tasks[1].state = .failed
        await t.equal("필수 작업이 실패하면 전체 실패", OrchestrationScheduler.next(s), .fail(.requiredTaskFailed(taskID: b.id)))
        s.tasks[1].state = .succeeded; s.tasks[2].state = .failed
        await t.equal("선택 작업 실패는 완료를 막지 않는다 → 최종 통합 검증", OrchestrationScheduler.next(s), .runFinalVerification)
        s.job.finalVerification = .failed
        await t.equal("통합 검증이 실패하면 완료로 표시하지 않는다", OrchestrationScheduler.next(s), .needsUser(.finalVerificationFailed))
        s.job.finalVerification = .passed
        await t.equal("통합 검증까지 통과해야 완료", OrchestrationScheduler.next(s), .complete)
        _ = c

        // 막힘 · 도달 불가 · 예산.
        var blocked = snapshot(plan([task("a"), task("b", dependsOn: ["a"])]))
        blocked.tasks[0].state = .blocked
        await t.equal("막힌 작업이 있으면 사람을 기다린다", OrchestrationScheduler.next(blocked), .needsUser(.blocked(taskIDs: [blocked.tasks[0].id])))
        var unreachable = snapshot(plan([task("a", optional: true), task("b", dependsOn: ["a"], optional: true), task("c")]))
        unreachable.tasks[0].state = .failed
        await t.equal("선행 선택 작업이 실패하면 뒤의 선택 작업은 취소 대상",
                      OrchestrationScheduler.next(unreachable), .markUnreachable(taskIDs: [unreachable.tasks[1].id]))
        var broke = snapshot(plan([task("a")]))
        broke.job.budget.maxTotalAttempts = 1
        broke.attempts = [attempt(broke.tasks[0], 1, .failed, failure: .verificationFailed)]
        broke.tasks[0].state = .retryPending
        await t.equal("전체 시도 예산을 넘으면 멈춘다", OrchestrationScheduler.next(broke), .needsUser(.budgetExhausted))
        var routing = snapshot(plan([task("a")])); routing.tasks[0].state = .routing
        await t.check("담당을 정하다 멈춘 작업은 다시 시작할 수 있다 (보낸 것이 없다)",
                      dispatched(OrchestrationScheduler.next(routing))?.taskID == routing.tasks[0].id)

        // 늦게 온 결과 · 재계획.
        var late = snapshot(plan([task("a")]))
        let sent = attempt(late.tasks[0], 1, .running, generation: 0)
        late.attempts = [sent]; late.tasks[0].state = .running
        await t.check("같은 세대의 결과는 받는다", OrchestrationScheduler.accepts(resultFor: sent, in: late))
        late.job.generation = 1
        await t.check("중단 · 재계획 뒤에 온 결과는 버린다", !OrchestrationScheduler.accepts(resultFor: sent, in: late))
        late.job.generation = 0; late.tasks[0].state = .superseded
        await t.check("대체된 작업의 결과는 버린다", !OrchestrationScheduler.accepts(resultFor: sent, in: late))
        var replanned = snapshot(plan([task("a"), task("b", dependsOn: ["a"])]))
        replanned.tasks[0].state = .succeeded
        await t.equal("재계획: 끝나지 않은 이전 작업만 대체한다",
                      OrchestrationScheduler.supersededByReplan(replanned, newPlanVersion: 2), [replanned.tasks[1].id])
        replanned.job.activePlanVersion = 2
        replanned.tasks += OrchestrationTask.make(from: plan([task("n")]), jobID: replanned.job.id, planVersion: 2)
        await t.equal("이전 계획의 대기 작업은 실행하지 않는다",
                      dispatched(OrchestrationScheduler.next(replanned))?.taskID, replanned.tasks[2].id)
    }

    // MARK: 실패 정책

    private static func failurePolicy(_ t: TestKit) async {
        await t.group("오케스트레이션: 실패 뒤의 행동")
        let s = snapshot(plan([task("a")]))
        let task = s.tasks[0]
        var job = s.job
        func failed(_ n: Int, _ profile: String, _ f: FailureClass, _ print: String? = nil) -> OrchestrationAttempt {
            attempt(task, n, .failed, profile: profile, failure: f, fingerprint: print)
        }
        func decide(_ f: FailureClass, _ attempts: [OrchestrationAttempt], next: Bool = true) -> FailureDecision {
            OrchestrationFailurePolicy.decide(after: f, attempts: attempts, job: job, nextProfileAvailable: next)
        }

        await t.equal("첫 검증 실패 → 같은 프로필로 보완", decide(.verificationFailed, [failed(1, "A", .verificationFailed)]), .retrySameProfile)
        let twice = [failed(1, "A", .verificationFailed), failed(2, "A", .verificationFailed)]
        await t.equal("보완도 실패 → 담당 변경", decide(.verificationFailed, twice), .escalate)
        await t.equal("바꿀 담당이 없으면 작업 실패", decide(.verificationFailed, twice, next: false), .failTask)
        await t.equal("작업당 3회에서 멈춘다", decide(.verificationFailed, twice + [failed(3, "B", .verificationFailed)]), .failTask)
        await t.equal("써 본 프로필 (A → B → A 차단의 근거)",
                      OrchestrationFailurePolicy.visitedProfiles(twice + [failed(3, "B", .verificationFailed)]), ["A", "B"])

        job.budget.maxSameProfileRetries = 3; job.budget.maxAttemptsPerTask = 5
        await t.equal("같은 오류가 그대로 반복되면 보완을 그만두고 담당 변경",
                      decide(.verificationFailed, [failed(1, "A", .verificationFailed, "E1"), failed(2, "A", .verificationFailed, "E1")]), .escalate)
        await t.equal("오류가 달라졌으면 진전으로 보고 보완 계속",
                      decide(.verificationFailed, [failed(1, "A", .verificationFailed, "E1"), failed(2, "A", .verificationFailed, "E2")]), .retrySameProfile)
        job.budget = OrchestrationBudget()

        await t.equal("인증 · 도구 부재 → 능력 승격 없이 사람에게", decide(.environment, [failed(1, "A", .environment)]), .askUser)
        await t.equal("요구가 모호 → 질문", decide(.ambiguousRequirement, [failed(1, "A", .ambiguousRequirement)]), .askUser)
        await t.equal("한도 → 쓸 수 있는 다른 프로필로", decide(.limitReached, [failed(1, "A", .limitReached)]), .switchForAvailability)
        await t.equal("한도인데 대안이 없으면 사람에게", decide(.limitReached, [failed(1, "A", .limitReached)], next: false), .askUser)
        await t.equal("일시 네트워크 오류 → 기다렸다 재시도", decide(.transientNetwork, [failed(1, "A", .transientNetwork)]), .retryAfterBackoff(seconds: 5))
        await t.equal("백오프는 늘어난다", decide(.transientNetwork, [failed(1, "A", .transientNetwork), failed(2, "A", .transientNetwork)]),
                      .retryAfterBackoff(seconds: 10))
        await t.equal("네트워크 재시도도 끝이 있다",
                      decide(.transientNetwork, (1...3).map { failed($0, "A", .transientNetwork) }), .askUser)
        await t.equal("계획 결함 → 재계획", decide(.planDefect, [failed(1, "A", .planDefect)]), .replan)
        job.replanCount = 1
        await t.equal("재계획은 한 번", decide(.planDefect, [failed(1, "A", .planDefect)]), .askUser)
        await t.equal("전달 여부 미확인 → 자동 진행 정지", decide(.deliveryUnknown, [failed(1, "A", .deliveryUnknown)]), .stopForRecovery)
        await t.equal("사용자 취소는 실패가 아니다", decide(.userCancelled, [failed(1, "A", .userCancelled)]), .cancel)
        await t.equal("상한들이 번갈아 걸려도 작업당 총 시도에서 멈춘다",
                      decide(.limitReached, (1...6).map { failed($0, "P\($0)", .limitReached) }), .askUser)

        await t.equal("결정 → 작업 상태", [FailureDecision.retrySameProfile, .escalate, .switchForAvailability, .askUser,
                                       .stopForRecovery, .cancel, .failTask, .replan]
            .map { OrchestrationFailurePolicy.taskState(for: $0)?.rawValue ?? "nil" },
                      ["retryPending", "escalationPending", "escalationPending", "blocked", "blocked", "cancelled", "failed", "nil"])
    }

    // MARK: 시뮬레이션 (스케줄러 + 실패 정책을 끝까지 돌린다)

    /// 시도마다 정해 둔 결과로 전체 작업을 끝까지 돌리는 아주 작은 구동기. 실행 · 검증 자리에 표를 넣은 것이다.
    private static func simulate(_ start: OrchestrationSnapshot, profiles: [String],
                                 outcome: (OrchestrationTask, OrchestrationAttempt) -> FailureClass?,
                                 finalPasses: Bool = true) -> (OrchestrationSnapshot, [String]) {
        var s = start
        var log: [String] = []
        for _ in 0..<60 {
            switch OrchestrationScheduler.next(s) {
            case .dispatch(let plan):
                guard let index = s.tasks.firstIndex(where: { $0.id == plan.taskID }) else { return (s, log) }
                let profile = plan.reuseProfileID ?? profiles.first { !plan.excludedProfileIDs.contains($0) } ?? "없음"
                var attempt = OrchestrationAttempt(taskID: plan.taskID, jobID: s.job.id, number: plan.attemptNumber,
                                                   kind: plan.kind, profileID: profile, generation: s.job.generation)
                let failure = outcome(s.tasks[index], attempt)
                attempt.state = failure == nil ? .succeeded : .failed
                attempt.failureClass = failure
                s.attempts.append(attempt)
                log.append("\(s.tasks[index].planTaskID)#\(plan.attemptNumber)@\(profile):\(failure?.rawValue ?? "pass")")
                if let failure {
                    let tried = OrchestrationFailurePolicy.visitedProfiles(s.attempts(for: plan.taskID))
                    let decision = OrchestrationFailurePolicy.decide(
                        after: failure, attempts: s.attempts(for: plan.taskID), job: s.job,
                        nextProfileAvailable: profiles.contains { !tried.contains($0) })
                    s.tasks[index].state = OrchestrationFailurePolicy.taskState(for: decision) ?? .blocked
                } else {
                    s.tasks[index].state = .succeeded
                }
            case .markUnreachable(let ids):
                for id in ids { if let i = s.tasks.firstIndex(where: { $0.id == id }) { s.tasks[i].state = .cancelled } }
                log.append("unreachable")
            case .runFinalVerification:
                s.job.finalVerification = finalPasses ? .passed : .failed
                log.append("final:\(finalPasses ? "pass" : "fail")")
            case .complete: s.job.state = .completed; log.append("완료"); return (s, log)
            case .fail: s.job.state = .failed; log.append("실패"); return (s, log)
            case .needsUser(let need): s.job.state = .awaitingUser; log.append("사용자:\(need)"); return (s, log)
            default: return (s, log)
            }
        }
        log.append("끝나지 않음")
        return (s, log)
    }

    private static func simulatedJobs(_ t: TestKit) async {
        await t.group("오케스트레이션: 대표 시나리오")
        let chain = plan([task("analyze"), task("fix", dependsOn: ["analyze"]), task("test", dependsOn: ["fix"])])

        var (end, log) = simulate(snapshot(plan([task("a")])), profiles: ["A", "B"]) { _, _ in nil }
        await t.equal("1) 단일 작업 → 검증 통과 → 통합 검증 → 완료", log, ["a#1@A:pass", "final:pass", "완료"])

        (end, log) = simulate(snapshot(chain), profiles: ["A", "B"]) { _, _ in nil }
        await t.equal("2) 의존 계획은 순서대로", log, ["analyze#1@A:pass", "fix#1@A:pass", "test#1@A:pass", "final:pass", "완료"])

        (end, log) = simulate(snapshot(plan([task("a")])), profiles: ["A", "B"]) { _, attempt in
            attempt.profileID == "A" ? .verificationFailed : nil
        }
        await t.equal("3) 검증 실패 → 보완 실패 → 상위 프로필 → 통과",
                      log, ["a#1@A:verificationFailed", "a#2@A:verificationFailed", "a#3@B:pass", "final:pass", "완료"])
        await t.equal("3) 시도 종류 기록", end.attempts.map(\.kind.rawValue), ["first", "retry", "escalation"])

        (end, log) = simulate(snapshot(plan([task("a")])), profiles: ["A", "B"]) { _, _ in .environment }
        await t.check("4) 인증 실패 → 능력 승격 없이 사용자 대기", log.count == 2 && log[0] == "a#1@A:environment"
                        && end.job.state == .awaitingUser && end.attempts.count == 1)

        (end, log) = simulate(snapshot(chain), profiles: ["A", "B"], outcome: { _, _ in nil }, finalPasses: false)
        await t.check("6) 통합 검증 실패 → 완료로 표시하지 않는다", end.job.state == .awaitingUser && !log.contains("완료"))

        (end, log) = simulate(snapshot(plan([task("a")])), profiles: ["A", "B"]) { _, _ in .verificationFailed }
        await t.equal("끝없이 돌지 않는다: 3회에서 작업 실패 → 전체 실패",
                      log, ["a#1@A:verificationFailed", "a#2@A:verificationFailed", "a#3@B:verificationFailed", "실패"])
        await t.check("A → B → A 로 돌아가지 않는다", end.attempts.map(\.profileID) == ["A", "A", "B"])

        (end, log) = simulate(snapshot(plan([task("a"), task("nice", optional: true)])), profiles: ["A"]) { task, _ in
            task.optional ? .verificationFailed : nil
        }
        await t.check("선택 작업이 실패해도 전체는 완료", end.job.state == .completed, "\(log)")

        // 5) 작업 중 앱 종료 → 재시작 뒤 중복 실행 없이 복구 대기.
        var crashed = snapshot(chain)
        crashed.tasks[0].state = .running
        crashed.attempts = [attempt(crashed.tasks[0], 1, .running)]
        let decision = OrchestrationScheduler.next(crashed)   // 다시 켠 직후: inFlight 가 비어 있다
        await t.equal("5) 재시작 직후: 다시 보내지 않고 복구 대상으로", decision, .recover(attemptIDs: [crashed.attempts[0].id]))
        crashed.attempts[0].state = .deliveryUnknown
        await t.check("5) 복구 표시 뒤에는 사람을 기다린다 (자동 재전송 없음)",
                      OrchestrationScheduler.next(crashed) == .needsUser(.deliveryUnknown(attemptIDs: [crashed.attempts[0].id])))
    }

    // MARK: 저장

    private static func storage(_ t: TestKit) async {
        await t.group("오케스트레이션: 저장 (v7)")
        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ahc-orch-\(UUID().uuidString).sqlite3")
        defer { for x in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + x) } }
        let store = Store(databaseURL: dbURL)
        do {
            // v6 DB 에 자료가 있는 상태에서 v7 로 올린다.
            try await store.db.open()
            try await Migrations.migrate(store.db, steps: Migrations.all.filter { $0.version <= 6 })
            // v6 의 모양으로 직접 넣는다 (지금의 upsertThread 는 뒤 버전의 컬럼을 쓴다).
            let project = Project(name: "오케스트레이션", path: "/tmp/orch")
            let thread = ConversationThread(projectID: project.id, title: "부모 대화")
            try await store.db.run("INSERT INTO project(id, name, path, created_at) VALUES(?,?,?,1);",
                                   [.text(project.id), .text(project.name), .text(project.path)])
            try await store.db.run("INSERT INTO thread(id, project_id, title, created_at, updated_at) VALUES(?,?,?,1,1);",
                                   [.text(thread.id), .text(project.id), .text(thread.title)])
            try await store.bootstrap()
            await t.equal("v6 → 최신", try await store.db.userVersion(), Migrations.all.last?.version ?? 0)
            await t.equal("기존 스레드 보존", try await store.threads(projectID: project.id).count, 1)

            // 작업 생성 → 계획 들이기.
            var job = OrchestrationJob(projectID: project.id, parentThreadID: thread.id, request: "기능을 만들어줘")
            job.state = .planning
            try await store.insertOrchestrationJob(job)
            let first = plan([task("a"), task("b", dependsOn: ["a"]), task("c", dependsOn: ["a", "b"])])
            job.state = .ready; job.activePlanVersion = 1
            let tasks = OrchestrationTask.make(from: first, jobID: job.id, planVersion: 1)
            try await store.installOrchestrationPlan(job: job, plan: first, tasks: tasks, plannerRunID: nil, cause: "첫 계획")
            guard var s = try await store.orchestrationSnapshot(jobID: job.id) else {
                await t.check("스냅샷 읽기", false); return
            }
            await t.equal("스냅샷: 작업 · 계획 버전", "\(s.job.state.rawValue)/\(s.job.activePlanVersion)/\(s.tasks.count)", "ready/1/3")
            await t.equal("스냅샷: 의존 관계 복원", s.tasks.map(\.dependsOn), [[], ["a"], ["a", "b"]])
            await t.check("스냅샷: 작업 내용 왕복", s.tasks == tasks)
            await t.check("계획 원문 보존", try await store.orchestrationPlan(jobID: job.id, version: 1) == first)

            // 시도는 보내기 전에 저장한다. 같은 번호 · 같은 표식은 두 번 만들 수 없다.
            job.state = .running
            var running = s.tasks[0]; running.state = .ready
            try await store.applyOrchestration(OrchestrationChanges(cause: "시작", job: job, tasks: [running]), jobID: job.id)
            running.state = .routing
            var attempt = OrchestrationAttempt(taskID: running.id, jobID: job.id, number: 1, kind: .first, profileID: "A", generation: 0)
            attempt.state = .dispatching
            try await store.applyOrchestration(OrchestrationChanges(cause: "배정", tasks: [running], newAttempts: [attempt]), jobID: job.id)
            var duplicate = OrchestrationAttempt(taskID: running.id, jobID: job.id, number: 1, kind: .first, profileID: "A", generation: 0)
            var rejected = false
            do { try await store.applyOrchestration(OrchestrationChanges(cause: "중복", newAttempts: [duplicate]), jobID: job.id) }
            catch { rejected = true }
            await t.check("같은 (작업, 시도 번호)는 두 번 저장되지 않는다", rejected)
            duplicate.number = 2; duplicate.dispatchToken = attempt.dispatchToken
            rejected = false
            do { try await store.applyOrchestration(OrchestrationChanges(cause: "중복", newAttempts: [duplicate]), jobID: job.id) }
            catch { rejected = true }
            await t.check("같은 전송 표식은 두 번 저장되지 않는다", rejected)

            // 허용되지 않는 전이는 묶음 전체를 저장하지 않는다.
            var illegal = running; illegal.state = .succeeded   // routing → succeeded 는 없다
            var alsoChanged = attempt; alsoChanged.state = .running
            var message = ""
            do {
                try await store.applyOrchestration(OrchestrationChanges(cause: "건너뛰기", tasks: [illegal], attempts: [alsoChanged]),
                                                   jobID: job.id)
            } catch { message = error.localizedDescription }
            await t.check("허용되지 않는 전이 거부", message.contains("허용되지 않는"), message)
            s = try await store.orchestrationSnapshot(jobID: job.id) ?? s
            await t.equal("거부된 묶음은 하나도 저장되지 않는다", "\(s.tasks[0].state.rawValue)/\(s.attempts[0].state.rawValue)", "routing/dispatching")

            // 실행 연결 → 주인 찾기 → 검증 → 통과를 한 묶음씩.
            let session = try await store.ensureSession(threadID: thread.id, provider: .claude, accountID: "")
            let run = Run(threadID: thread.id, sessionID: session.id, provider: .claude, requestText: "a", state: .running)
            try await store.insertRun(run)
            attempt.state = .running; attempt.runID = run.id; running.state = .running
            try await store.applyOrchestration(OrchestrationChanges(cause: "실행 시작", tasks: [running], attempts: [attempt]), jobID: job.id)
            let owner = try await store.orchestrationAttempt(runID: run.id)
            await t.equal("실행 ID 로 시도를 찾는다 (화면 선택과 무관)", owner?.id, attempt.id)
            attempt.state = .verifying; running.state = .verifying
            try await store.applyOrchestration(OrchestrationChanges(cause: "실행 종료", tasks: [running], attempts: [attempt]), jobID: job.id)
            attempt.state = .succeeded; attempt.endedAt = Date(); running.state = .succeeded
            let verification = VerificationRecord(jobID: job.id, taskID: running.id, attemptID: attempt.id, verifierVersion: "v1",
                                                  criterion: "a 가 동작한다", outcome: .pass,
                                                  evidenceJSON: #"{"command":"inttest offline","exitCode":0}"#,
                                                  workspaceFingerprint: "abc123")
            let routing = RoutingDecisionRecord(jobID: job.id, taskID: running.id, featureSource: .planner, featureVersion: "1",
                                                inputHash: "h", inputSummary: "작업 a", featuresJSON: #"{"kind":"implement"}"#,
                                                candidatesJSON: #"[{"profile":"A"},{"profile":"B","excluded":"한도 미확인"}]"#,
                                                selectedProfile: "A", reasonCodesJSON: #"["kindMatch"]"#, policyVersion: "static-1")
            try await store.applyOrchestration(OrchestrationChanges(cause: "검증 통과", tasks: [running], attempts: [attempt],
                                                                    verifications: [verification], routingDecisions: [routing]),
                                               jobID: job.id)
            await t.equal("검증 기록 저장", try await store.verificationRecords(jobID: job.id).map(\.outcome), [.pass])
            await t.equal("배정 근거 저장 (후보와 제외 이유 포함)", try await store.routingDecisions(jobID: job.id).first?.candidatesJSON,
                          routing.candidatesJSON)

            // 전이 기록: 빠짐없이, 순서대로, 상태가 실제로 바뀔 때만.
            let transitions = try await store.orchestrationTransitions(jobID: job.id)
            await t.equal("전이 기록의 순번은 1부터 빈틈없이", transitions.map(\.sequence), Array(1...transitions.count))
            await t.equal("하위 작업 a 의 전이", transitions.filter { $0.entityID == running.id }.map { "\($0.from ?? "-")→\($0.to)" },
                          ["-→pending", "pending→ready", "ready→routing", "routing→running", "running→verifying", "verifying→succeeded"])
            await t.equal("시도의 전이", transitions.filter { $0.entityID == attempt.id }.map { "\($0.from ?? "-")→\($0.to)" },
                          ["-→dispatching", "dispatching→running", "running→verifying", "verifying→succeeded"])
            await t.equal("전체 작업의 전이", transitions.filter { $0.entity == "job" }.map { "\($0.from ?? "-")→\($0.to)" },
                          ["-→planning", "planning→ready", "ready→running"])
            try await store.applyOrchestration(OrchestrationChanges(cause: "변화 없음", tasks: [running]), jobID: job.id)
            await t.equal("상태가 그대로면 전이를 남기지 않는다",
                          try await store.orchestrationTransitions(jobID: job.id).count, transitions.count)

            // 저장한 것만으로 스케줄러가 이어 간다.
            s = try await store.orchestrationSnapshot(jobID: job.id) ?? s
            if case .dispatch(let next) = OrchestrationScheduler.next(s) {
                await t.equal("DB 스냅샷으로 다음 작업 결정", next.taskID, s.tasks[1].id)
            } else {
                await t.check("DB 스냅샷으로 다음 작업 결정", false)
            }

            // 재계획: 끝나지 않은 이전 작업을 대체하고 새 버전을 들인다. 통과한 작업은 남는다.
            let second = plan([task("b2"), task("c2", dependsOn: ["b2"])])
            job.state = .running; job.activePlanVersion = 2; job.generation = 1; job.replanCount = 1
            let superseded = OrchestrationScheduler.supersededByReplan(s, newPlanVersion: 2)
            try await store.installOrchestrationPlan(job: job, plan: second,
                                                     tasks: OrchestrationTask.make(from: second, jobID: job.id, planVersion: 2),
                                                     plannerRunID: nil, supersededTaskIDs: superseded, cause: "요구 변경")
            s = try await store.orchestrationSnapshot(jobID: job.id) ?? s
            await t.equal("재계획 뒤 상태", s.tasks.map { "\($0.planTaskID):\($0.state.rawValue)" },
                          ["a:succeeded", "b:superseded", "c:superseded", "b2:pending", "c2:pending"])
            await t.equal("세대 · 재계획 횟수 저장", "\(s.job.generation)/\(s.job.replanCount)", "1/1")
            if case .dispatch(let next) = OrchestrationScheduler.next(s) {
                await t.equal("8) 요구 변경 뒤에는 새 계획의 작업만 실행", s.tasks.first { $0.id == next.taskID }?.planTaskID, "b2")
            } else {
                await t.check("8) 요구 변경 뒤에는 새 계획의 작업만 실행", false)
            }

            // 복구의 출발점과 삭제.
            await t.equal("끝나지 않은 전체 작업 조회", try await store.unfinishedOrchestrationJobs().map(\.id), [job.id])
            try await store.db.run("DELETE FROM run WHERE id = ?;", [.text(run.id)])
            await t.check("실행 기록이 지워지면 시도의 run_id 만 비운다",
                          try await store.orchestrationSnapshot(jobID: job.id)?.attempts.first?.runID == nil)
            try await store.deleteThread(id: thread.id)
            await t.check("부모 대화를 지우면 전체 작업도 지워진다", try await store.orchestrationJob(id: job.id) == nil)
            var leftovers = 0
            for table in ["orchestration_plan", "orchestration_task", "orchestration_dependency", "orchestration_attempt",
                          "orchestration_transition", "verification_result", "routing_decision"] {
                leftovers += try await store.db.query("SELECT COUNT(*) AS c FROM \(table);").first?.intValue("c") ?? 0
            }
            await t.equal("하위 기록이 남지 않는다", leftovers, 0)
            await t.check("외래 키 위반 없음", try await store.db.query("PRAGMA foreign_key_check;").isEmpty)
        } catch {
            await t.check("저장 검증 중 예외", false, "\(error)")
        }
    }
}

// MARK: - 배정 정책 · 검증 판정 · 성과 (순수)

enum OrchestrationPolicyTests {

    static func run(_ t: TestKit) async {
        await routing(t)
        await judging(t)
        await metrics(t)
    }

    private static func plan(_ kind: AttemptKind, reuse: String? = nil, excluded: [String] = []) -> DispatchPlan {
        DispatchPlan(taskID: "t", attemptNumber: 1, kind: kind, reuseProfileID: reuse, excludedProfileIDs: excluded)
    }

    private static func routing(_ t: TestKit) async {
        await t.group("오케스트레이션: 배정 정책")
        let profiles = ExecutionProfile.defaults
        func choose(_ difficulty: Int, _ p: DispatchPlan, lastTier: Int? = nil, unavailable: [String: String] = [:],
                    kind: TaskKind = .implement, from list: [ExecutionProfile]? = nil) -> RoutingOutcome {
            RoutingPolicy.choose(kind: kind, difficulty: difficulty, plan: p, lastTier: lastTier,
                                 profiles: list ?? profiles, unavailable: unavailable)
        }
        await t.equal("난이도 1~2 → 등급 1", choose(2, plan(.first)).selected?.id, "claude-haiku")
        await t.equal("난이도 3 → 등급 2", choose(3, plan(.first)).selected?.tier, 2)
        await t.equal("난이도 5 → 등급 3", choose(5, plan(.first)).selected?.tier, 3)
        await t.equal("바라는 등급이 없으면 그 아래에서 가장 높은 것",
                      choose(5, plan(.first), from: profiles.filter { $0.tier < 3 }).selected?.tier, 2)
        await t.equal("보완은 같은 프로필", choose(2, plan(.retry, reuse: "claude-haiku")).selected?.id, "claude-haiku")
        await t.equal("보완하려던 프로필을 못 쓰면 같은 등급 이상에서",
                      choose(2, plan(.retry, reuse: "claude-haiku"), lastTier: 1, unavailable: ["claude-haiku": "한도"]).selected?.tier, 2)
        await t.equal("담당 변경은 더 높은 등급으로", choose(2, plan(.escalation, excluded: ["claude-haiku"]), lastTier: 1).selected?.tier, 2)
        await t.equal("가장 높은 등급에서는 같은 등급의 다른 프로필",
                      choose(5, plan(.escalation, excluded: ["claude-opus"]), lastTier: 3).selected?.id, "codex-sol-high")
        await t.check("더 갈 곳이 없으면 고르지 않는다 (낮은 등급으로 내려가지 않는다)",
                      choose(5, plan(.escalation, excluded: ["claude-opus", "codex-sol-high"]), lastTier: 3).selected == nil)
        await t.equal("한도 전환은 같은 등급의 다른 프로필",
                      choose(3, plan(.availabilitySwitch, excluded: ["claude-sonnet"]), lastTier: 2).selected?.id, "codex-sol-medium")
        let outcome = choose(2, plan(.first), unavailable: ["claude-haiku": "한도 확인 안 됨"])
        await t.check("쓸 수 없는 프로필은 이유와 함께 후보에 남긴다",
                      outcome.selected?.id != "claude-haiku"
                        && outcome.candidates.first { $0.profileID == "claude-haiku" }?.excluded == "한도 확인 안 됨")
        await t.check("후보가 없으면 그 사실을 남긴다",
                      choose(2, plan(.first), unavailable: Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, "x") }))
                        .reasonCodes.contains("noCandidate"))
        var picky = profiles
        picky[0].excludedKinds = [.debug]
        await t.check("유형별로 맡기지 않을 프로필", choose(1, plan(.first), kind: .debug, from: picky).selected?.id != "claude-haiku")
        await t.check("기본 프로필에 가장 비싼 모델(astra)은 없다", !profiles.contains { ($0.model ?? "").lowercased().contains("astra") })

        var settings = OrchestrationSettings()
        await t.check("검토는 실행한 프로필과 다른 프로필",
                      RoutingPolicy.reviewer(settings: settings, executorProfileID: "claude-sonnet", unavailable: [:])?.id != "claude-sonnet")
        await t.equal("실행자가 다르면 설정한 검토 담당",
                      RoutingPolicy.reviewer(settings: settings, executorProfileID: "claude-haiku", unavailable: [:])?.id, "claude-sonnet")
        settings.profiles.append(ExecutionProfile(id: "agy", name: "Antigravity", provider: .gemini, tier: 3))
        settings.plannerProfileID = "agy"
        await t.check("읽기 전용을 보장 못 하는 제공자는 계획 · 검토에 쓰지 않는다",
                      RoutingPolicy.planner(settings: settings, unavailable: [:])?.provider != .gemini
                        && RoutingPolicy.reviewer(settings: settings, executorProfileID: nil, unavailable: [:])?.provider != .gemini)
        await t.check("계획 담당을 못 쓰면 가능한 것 중 가장 높은 등급",
                      RoutingPolicy.planner(settings: OrchestrationSettings(), unavailable: ["claude-opus": "x"])?.tier == 3)

        // 검토단: 서로 다른 제공자의 둘. 어려운 작업과 최종 통합 검증에만 (기본).
        let base = OrchestrationSettings()
        func panel(_ mode: ReviewPanelMode, executor: String?, difficulty: Int?, unavailable: [String: String] = [:]) -> [String] {
            var s = base
            s.reviewPanel = mode
            return RoutingPolicy.reviewers(settings: s, executorProfileID: executor, difficulty: difficulty, unavailable: unavailable).map(\.id)
        }
        await t.equal("기본은 어려운 작업과 최종 검증", base.reviewPanel, .hardAndFinal)
        await t.equal("쉬운 작업은 검토 담당 한 명", panel(.hardAndFinal, executor: "claude-haiku", difficulty: 2), ["claude-sonnet"])
        await t.equal("가장 높은 등급이 필요한 작업은 다른 제공자를 더한다 (첫 사람과 등급이 가까운 것)",
                      panel(.hardAndFinal, executor: "claude-opus", difficulty: 4), ["claude-sonnet", "codex-sol-medium"])
        await t.equal("최종 통합 검증(난이도 없음)은 검토단", panel(.hardAndFinal, executor: nil, difficulty: nil), ["claude-sonnet", "codex-sol-medium"])
        await t.equal("최종 검증만: 하위 작업은 한 명", panel(.finalOnly, executor: "claude-opus", difficulty: 5), ["claude-sonnet"])
        await t.equal("모든 작업", panel(.always, executor: "claude-haiku", difficulty: 1).count, 2)
        await t.equal("쓰지 않음", panel(.single, executor: nil, difficulty: nil), ["claude-sonnet"])
        await t.equal("둘째도 실행한 프로필은 피한다", panel(.always, executor: "codex-sol-medium", difficulty: 3), ["claude-sonnet", "codex-sol-high"])
        await t.equal("다른 제공자를 쓸 수 없으면 한 명 (같은 제공자로 채우지 않는다)",
                      panel(.always, executor: nil, difficulty: nil, unavailable: ["codex-sol-medium": "한도", "codex-sol-high": "한도"]), ["claude-sonnet"])
        await t.check("검토단의 둘은 제공자가 다르다", Set(RoutingPolicy.reviewers(settings: base, executorProfileID: nil, difficulty: nil,
                                                                          unavailable: [:]).map(\.provider)).count == 2)

        // 나중에 생긴 칸이 없는 옛 설정도 읽는다.
        let old = #"{"enabled":true,"profiles":[{"id":"p","name":"P","provider":"claude"}]}"#
        let decoded = try? JSONDecoder().decode(OrchestrationSettings.self, from: Data(old.utf8))
        await t.check("옛 설정: 없는 칸은 기본값", decoded?.enabled == true && decoded?.profiles.first?.tier == 2
                        && decoded?.reviewMode == .always && decoded?.allowUnknownLimits == false
                        && decoded?.reviewPanel == .hardAndFinal)
        // 없앤 칸(옛 문지기 `jevGate`)이 남은 설정도 읽는다 — 그 칸은 넘긴다.
        let withGate = #"{"enabled":true,"jevGate":"apply","requiresPlanApproval":false}"#
        let gateDecoded = try? JSONDecoder().decode(OrchestrationSettings.self, from: Data(withGate.utf8))
        await t.check("옛 설정: 없앤 문지기 칸은 넘기고 나머지는 읽는다",
                      gateDecoded?.enabled == true && gateDecoded?.requiresPlanApproval == false)
        await t.check("옛 기록의 출처 \"jev\" 는 알려진 값이 아니다 (저장소가 정적 규칙으로 읽는다)", FeatureSource(rawValue: "jev") == nil)
    }

    private static func judging(_ t: TestKit) async {
        await t.group("오케스트레이션: 검증 판정")
        let criteria = ["빌드가 된다", "테스트가 있다"]
        func review(_ outcomes: [String], problem: String = "none") -> ReviewVerdict {
            ReviewVerdict(criteria: outcomes.map { .init(criterion: "c", outcome: $0, evidence: "근거") }, summary: "요약", problem: problem)
        }
        func command(_ code: Int?, _ tail: String = "ok") -> CommandResult {
            CommandResult(command: "make test", exitCode: code, outputTail: tail, durationMs: 1)
        }
        func judge(_ c: CommandResult?, _ r: ReviewVerdict?, unreadable: Bool = false) -> VerificationVerdict {
            VerificationJudge.judge(jobID: "j", taskID: "t", attemptID: "a", criteria: criteria, command: c, review: r,
                                    reviewUnreadable: unreadable, workspaceFingerprint: "fp")
        }
        var v = judge(command(0), review(["pass", "pass"]))
        await t.equal("명령 통과 + 조건 모두 통과 → 통과", "\(v.outcome.rawValue)/\(v.basis.rawValue)", "pass/both")
        await t.equal("기록: 명령 1 + 조건마다 1", v.records.count, 3)
        v = judge(command(1, "error: 3 tests failed at 12:44"), review(["pass", "pass"]))
        await t.equal("명령이 실패하면 검토가 통과여도 실패 (객관이 우선)", "\(v.outcome.rawValue)/\(v.failure?.rawValue ?? "")", "fail/verificationFailed")
        await t.check("보완 근거에 명령 출력", v.feedback.contains("3 tests failed"))
        let again = judge(command(1, "error: 5 tests failed at 13:02"), nil)
        await t.equal("숫자만 다른 같은 오류는 같은 지문", v.fingerprint, again.fingerprint)
        v = judge(nil, review(["pass", "fail"], problem: "planDefect"))
        await t.equal("검토만 실패: 검토가 짚은 원인을 따른다", v.failure, .planDefect)
        await t.check("보완 근거에 못 채운 조건", v.feedback.contains("테스트가 있다"))
        await t.equal("빠뜨린 조건은 판정 불가 (통과로 치지 않는다)", judge(nil, review(["pass"])).outcome, .inconclusive)
        await t.equal("조건 하나라도 판정 불가면 전체가 판정 불가", judge(command(0), review(["pass", "inconclusive"])).outcome, .inconclusive)
        await t.equal("해석 못 한 검토는 판정 불가", judge(nil, nil, unreadable: true).outcome, .inconclusive)
        await t.equal("끝까지 못 돈 명령은 판정 불가", judge(command(nil), nil).outcome, .inconclusive)
        await t.equal("수단이 없으면 검증 불가", judge(nil, nil).outcome, .unavailable)
        await t.equal("검토만으로 통과한 것은 그렇게 표시 (성과에서 따로 센다)", judge(nil, review(["pass", "pass"])).basis, .reviewer)

        // 검토단: 한 명이라도 실패면 실패.
        func panel(_ c: CommandResult?, _ reviews: [(String, ReviewVerdict?)]) -> VerificationVerdict {
            VerificationJudge.judge(jobID: "j", taskID: "t", attemptID: "a", criteria: criteria, command: c,
                                    reviews: reviews.map { PanelReview(reviewer: $0.0, verdict: $0.1) }, workspaceFingerprint: "fp")
        }
        v = panel(command(0), [("Claude", review(["pass", "pass"])), ("Codex", review(["pass", "pass"]))])
        await t.equal("검토단: 둘 다 통과 → 통과", v.outcome, .pass)
        await t.equal("검토단: 기록은 명령 1 + 검토자마다 조건 수", v.records.count, 5)
        await t.check("검토단: 기록에 누가 봤는지", v.records.filter { $0.evidenceJSON.contains("Codex") }.count == 2)
        await t.check("검토단: 요약에 검토자 이름", v.summary.contains("[Claude]") && v.summary.contains("[Codex]"))
        v = panel(command(0), [("Claude", review(["pass", "pass"])), ("Codex", review(["pass", "fail"]))])
        await t.equal("검토단: 한 명이라도 실패면 실패", "\(v.outcome.rawValue)/\(v.failure?.rawValue ?? "")", "fail/verificationFailed")
        await t.check("검토단: 보완 근거에 누가 무엇을 짚었는지", v.feedback.contains("(Codex)") && v.feedback.contains("테스트가 있다")
                        && !v.feedback.contains("(Claude)"))
        let one = panel(nil, [("Claude", review(["fail", "pass"])), ("Codex", review(["pass", "fail"]))])
        let other = panel(nil, [("Claude", review(["pass", "fail"])), ("Codex", review(["fail", "pass"]))])
        await t.check("검토단: 지문은 실패한 조건의 모음 (누가 짚었는지는 넣지 않는다)",
                      one.fingerprint == other.fingerprint && one.fingerprint == "criteria:0,1", one.fingerprint ?? "")
        v = panel(nil, [("Claude", review(["fail", "pass"], problem: "planDefect")), ("Codex", review(["fail", "pass"], problem: "verificationFailed"))])
        await t.equal("검토단: 원인이 갈리면 작업 품질을 먼저 본다 (보완으로 간다)", v.failure, .verificationFailed)
        v = panel(nil, [("Claude", review(["pass", "fail"], problem: "none")), ("Codex", review(["pass", "pass"], problem: "planDefect"))])
        await t.equal("검토단: 통과시킨 검토자가 적은 원인은 따르지 않는다", v.failure, .verificationFailed)
        v = panel(nil, [("Claude", review(["pass", "pass"])), ("Codex", nil)])
        await t.equal("검토단: 결과를 못 낸 검토자는 빼고 판정한다", v.outcome, .pass)
        await t.check("검토단: 뺀 검토자도 기록에 남는다",
                      v.records.contains { $0.outcome == .inconclusive && $0.evidenceJSON.contains("Codex") && $0.evidenceJSON.contains("판정에서 뺐습니다") })
        await t.equal("검토단: 아무도 결과를 못 내면 판정 불가", panel(nil, [("Claude", nil), ("Codex", nil)]).outcome, .inconclusive)
        await t.equal("검토단: 한 명의 판정 불가도 통과로 치지 않는다",
                      panel(nil, [("Claude", review(["pass", "pass"])), ("Codex", review(["pass", "inconclusive"]))]).outcome, .inconclusive)
        await t.equal("검토단: 명령 실패가 먼저", panel(command(1, "error: x"), [("Claude", review(["pass", "pass"]))]).failure, .verificationFailed)

        func result(_ state: RunState, _ limit: LimitStatus? = nil) -> AgentTurnResult {
            AgentTurnResult(state: state, terminalReason: nil, limitStatus: limit)
        }
        await t.check("실행 결과 분류", RunOutcomeClassifier.failure(of: result(.completed)) == nil
                        && RunOutcomeClassifier.failure(of: result(.rateLimited)) == .limitReached
                        && RunOutcomeClassifier.failure(of: result(.cancelled)) == .userCancelled
                        && RunOutcomeClassifier.failure(of: result(.failed, .authProblem)) == .environment
                        && RunOutcomeClassifier.failure(of: result(.failed, .networkError)) == .transientNetwork
                        && RunOutcomeClassifier.failure(of: result(.failed, .subscriptionCap)) == .limitReached)
        await t.check("원인을 모르는 실패는 능력 실패로 세지 않는다",
                      RunOutcomeClassifier.failure(of: result(.failed, .unknownCause))?.countsAgainstModel == false)
    }

    private static func metrics(_ t: TestKit) async {
        await t.group("오케스트레이션: 성과 지표")
        func attempt(_ id: String, _ profile: String, _ state: AttemptState, _ kind: AttemptKind = .first,
                     _ failure: FailureClass? = nil) -> OrchestrationAttempt {
            OrchestrationAttempt(id: id, taskID: "t", jobID: "j", number: 1, kind: kind, profileID: profile, generation: 0,
                                 state: state, failureClass: failure)
        }
        let attempts = [attempt("1", "A", .succeeded), attempt("2", "A", .failed, .first, .verificationFailed),
                        attempt("3", "A", .failed, .retry, .environment), attempt("4", "A", .failed, .retry, nil),
                        attempt("5", "A", .cancelled), attempt("6", "B", .succeeded, .escalation),
                        attempt("7", "A", .failed, .first, .limitReached), attempt("8", "A", .deliveryUnknown)]
        let records = [VerificationRecord(jobID: "j", taskID: "t", attemptID: "1", verifierVersion: "v", criterion: "명령", outcome: .pass,
                                          evidenceJSON: #"{"basis":"command"}"#, workspaceFingerprint: nil),
                       VerificationRecord(jobID: "j", taskID: "t", attemptID: "6", verifierVersion: "v", criterion: "조건", outcome: .pass,
                                          evidenceJSON: #"{"basis":"reviewer"}"#, workspaceFingerprint: nil)]
        let stats = OrchestrationMetrics.stats(attempts: attempts, verifications: records)
        let a = stats.first { $0.profileID == "A" }
        await t.equal("취소한 시도는 세지 않는다", a?.attempts, 6)
        await t.equal("통과율의 분모는 통과 + 검증 실패뿐", a?.passRate, 0.5)
        await t.equal("환경 · 한도는 분모에서 뺀다", a?.excluded, 2)
        await t.equal("판정 불가 · 전달 여부 미확인은 미확인으로", a?.unverified, 2)
        await t.equal("첫 시도 통과 (취소만 빼고 센다: 1 · 2 · 7 · 8번)", "\(a?.firstTryPasses ?? 0)/\(a?.firstTries ?? 0)", "1/4")
        await t.equal("명령이 뒷받침한 통과만 객관적 통과", "\(a?.passedObjectively ?? 0)/\(stats.first { $0.profileID == "B" }?.passedObjectively ?? -1)", "1/0")
        await t.check("표본이 없으면 통과율 없음 (0% 로 보이지 않는다)", ProfileStats(profileID: "X").passRate == nil)
    }
}
