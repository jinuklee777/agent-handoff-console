import Foundation

// 계획 에이전트가 돌려주는 작업 계획: 형식, 넘겨줄 JSON 스키마, 앱의 검사.
// 순수 코드다 — CLI · 저장 · 화면을 모른다.

// MARK: - 계획

/// 작업의 주된 성격. 배정 정책이 모델 프로필과 맞출 때 쓴다.
enum TaskKind: String, Codable, CaseIterable, Sendable {
    case explain, implement, debug, review, research, other

    /// 스키마 설명과 계획 프롬프트에 그대로 쓰는 정의.
    var definition: String {
        switch self {
        case .explain: return "코드 · 개념 · 동작을 설명한다. 파일을 바꾸지 않는다"
        case .implement: return "새로 만들거나 기존 동작을 의도적으로 바꾼다"
        case .debug: return "잘못된 동작의 원인을 찾아 고친다"
        case .review: return "이미 있는 코드나 변경을 검토해 문제를 지적한다"
        case .research: return "저장소 밖 정보나 여러 선택지를 조사 · 비교한다"
        case .other: return "위 어느 것에도 맞지 않는다"
        }
    }
}

/// 계획 안의 하위 작업 하나. `id` 는 계획 안에서만 유일한 이름이다 (저장되는 작업의 ID 와 다르다).
struct PlannedTask: Codable, Equatable, Sendable {
    var id: String
    var title: String
    /// 목적 · 입력 · 산출물. 이 작업만 받은 에이전트가 시작할 수 있을 만큼 적는다.
    var specification: String
    var kind: TaskKind
    /// 1(한 파일 몇 줄) ~ 5(설계 결정 · 동시성 · 데이터 이전).
    var difficulty: Int
    /// 먼저 검증을 통과해야 하는 작업의 `id`.
    var dependsOn: [String]
    /// 완료 조건. 실행 전에 정해지며 실행 모델이 사후에 낮출 수 없다.
    var acceptance: [String]
    /// 완료 조건을 어떻게 확인할지.
    var verification: String
    /// 고칠 것으로 예상하는 경로 (프로젝트 기준 상대 경로). 모르면 빈 배열.
    var paths: [String]
    /// 선택 작업. 실패하거나 건너뛰어도 전체 완료를 막지 않는다.
    var optional: Bool
}

struct OrchestrationPlan: Codable, Equatable, Sendable {
    var goal: String
    var assumptions: [String]
    /// 답을 받아야 시작할 수 있는 질문. `infoSufficient` 가 false 면 하나 이상 있어야 한다.
    var openQuestions: [String]
    /// 서로 의존하는 여러 단계로 나눠야 끝낼 수 있는 요청인가. false 면 작업은 하나다.
    var needsDecomposition: Bool
    /// 되묻지 않고 시작할 수 있는가.
    var infoSufficient: Bool
    var tasks: [PlannedTask]
    /// 전체 목표의 최종 통합 검증 조건.
    var finalAcceptance: [String]
}

// MARK: - 스키마

/// 계획 턴에 `AgentTurnOptions.outputSchema` 로 넘기는 JSON 스키마.
/// Codex 의 구조화 응답은 모든 속성이 `required` 이고 `additionalProperties` 가 false 여야 하므로,
/// 없을 수 있는 값은 빈 배열로 받는다.
enum PlanSchema {
    /// 스키마가 바뀌면 올린다. 저장된 계획이 어느 형식인지 구분한다.
    static let version = 1

    static let jsonString: String = JSONUtil.string(object())

    static func object() -> [String: Any] {
        func strings(_ description: String) -> [String: Any] {
            ["type": "array", "items": ["type": "string"], "description": description]
        }
        let task: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["id", "title", "specification", "kind", "difficulty", "dependsOn",
                         "acceptance", "verification", "paths", "optional"],
            "properties": [
                "id": ["type": "string", "description": "계획 안에서 유일한 짧은 이름. 예: t1"],
                "title": ["type": "string"],
                "specification": ["type": "string",
                                  "description": "목적 · 입력 · 산출물. 이 작업만 받은 에이전트가 시작할 수 있게 쓴다"],
                "kind": ["type": "string", "enum": TaskKind.allCases.map(\.rawValue),
                         "description": TaskKind.allCases.map { "\($0.rawValue): \($0.definition)" }.joined(separator: " / ")],
                "difficulty": ["type": "integer", "minimum": 1, "maximum": 5,
                               "description": "1 한 파일 몇 줄 / 2 한두 파일 국소 변경 / 3 여러 파일 또는 구조 이해 / 4 여러 계층을 함께 바꾸거나 원인 불명 추적 / 5 설계 결정 · 동시성 · 데이터 이전 · 외부 프로토콜"],
                "dependsOn": strings("먼저 끝나야 하는 작업의 id. 없으면 빈 배열"),
                "acceptance": strings("완료 조건. 하나 이상"),
                "verification": ["type": "string", "description": "완료 조건을 확인하는 방법 (명령 · 확인할 파일 · 검토 기준)"],
                "paths": strings("고칠 것으로 예상하는 프로젝트 기준 상대 경로. 모르면 빈 배열"),
                "optional": ["type": "boolean", "description": "실패해도 전체 완료를 막지 않는 선택 작업이면 true"],
            ],
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["goal", "assumptions", "openQuestions", "needsDecomposition", "infoSufficient",
                         "tasks", "finalAcceptance"],
            "properties": [
                "goal": ["type": "string"],
                "assumptions": strings("요청에 없어서 가정한 것"),
                "openQuestions": strings("답을 받아야 시작할 수 있는 질문. infoSufficient 가 false 면 하나 이상"),
                "needsDecomposition": ["type": "boolean",
                                       "description": "앞 단계 결과가 있어야 다음 단계를 할 수 있는 여러 단계인가. 단순한 요청은 false 이고 작업은 하나다"],
                "infoSufficient": ["type": "boolean", "description": "되묻지 않고 시작할 수 있는가"],
                "tasks": ["type": "array", "items": task],
                "finalAcceptance": strings("전체 목표의 최종 통합 검증 조건. 하나 이상"),
            ],
        ]
    }
}

// MARK: - 검사

struct PlanLimits: Equatable, Sendable {
    var maxTasks = 8
}

/// 계획을 받아들일 수 없는 이유. 하나라도 있으면 그 계획으로 실행하지 않는다.
enum PlanIssue: Error, Equatable, Sendable {
    case invalidJSON(String)
    case emptyGoal
    case noTasks
    case tooManyTasks(count: Int, max: Int)
    case emptyTaskID(index: Int)
    case duplicateTaskID(String)
    case emptyTitle(task: String)
    case emptySpecification(task: String)
    case difficultyOutOfRange(task: String, value: Int)
    case missingAcceptance(task: String)
    case missingVerification(task: String)
    case selfDependency(task: String)
    case unknownDependency(task: String, dependency: String)
    case dependencyCycle([String])
    /// 절대 경로, `~`, 프로젝트 밖으로 나가는 `..`.
    case pathEscapesProject(task: String, path: String)
    case missingFinalAcceptance
    /// 정보가 부족하다면서 무엇이 부족한지 묻지 않았다.
    case insufficientInfoWithoutQuestions
    /// 분해가 필요 없다면서 여러 작업으로 나눴다.
    case decomposedWithoutNeed(count: Int)
    /// 필수 작업이 선택 작업의 결과에 기댄다 — 선택 작업이 빠지면 영영 시작하지 못한다.
    case requiredDependsOnOptional(task: String, dependency: String)

    var message: String {
        switch self {
        case .invalidJSON(let m): return "계획을 해석하지 못했습니다: \(m)"
        case .emptyGoal: return "목표가 비어 있습니다."
        case .noTasks: return "작업이 없습니다."
        case .tooManyTasks(let count, let max): return "작업이 \(count)개입니다. 최대 \(max)개까지 받습니다."
        case .emptyTaskID(let index): return "\(index + 1)번째 작업에 id 가 없습니다."
        case .duplicateTaskID(let id): return "작업 id 가 겹칩니다: '\(id)'"
        case .emptyTitle(let task): return "작업 '\(task)' 에 제목이 없습니다."
        case .emptySpecification(let task): return "작업 '\(task)' 에 명세가 없습니다."
        case .difficultyOutOfRange(let task, let value): return "작업 '\(task)' 의 난이도가 1~5 밖입니다: \(value)"
        case .missingAcceptance(let task): return "작업 '\(task)' 에 완료 조건이 없습니다."
        case .missingVerification(let task): return "작업 '\(task)' 에 검증 방법이 없습니다."
        case .selfDependency(let task): return "작업이 자기 자신에 의존합니다: '\(task)'"
        case .unknownDependency(let task, let dependency): return "작업 '\(task)' 의 의존 대상이 없는 작업입니다: '\(dependency)'"
        case .dependencyCycle(let ids): return "의존 관계가 돕니다: \(ids.joined(separator: " → "))"
        case .pathEscapesProject(let task, let path): return "작업 '\(task)' 의 경로가 프로젝트를 벗어납니다: '\(path)'"
        case .missingFinalAcceptance: return "최종 통합 검증 조건이 없습니다."
        case .insufficientInfoWithoutQuestions: return "정보가 부족하다고 했지만 질문이 없습니다."
        case .decomposedWithoutNeed(let count): return "분해가 필요 없다고 했지만 작업이 \(count)개입니다."
        case .requiredDependsOnOptional(let task, let dependency):
            return "필수 작업 '\(task)' 의 의존 대상이 선택 작업입니다: '\(dependency)'"
        }
    }
}

enum PlanValidator {

    /// 구조화 응답(JSON 글)을 계획으로. CLI 가 스키마를 지켰다고 믿지 않고 다시 해석한다.
    static func decode(_ json: String?) -> Result<OrchestrationPlan, PlanIssue> {
        guard let json, let data = json.data(using: .utf8), !json.isEmpty else {
            return .failure(.invalidJSON("응답이 비어 있습니다"))
        }
        do {
            return .success(try JSONDecoder().decode(OrchestrationPlan.self, from: data))
        } catch let DecodingError.keyNotFound(key, _) {
            return .failure(.invalidJSON("필요한 값이 없습니다: '\(key.stringValue)'"))
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            return .failure(.invalidJSON("'\(context.codingPath.map(\.stringValue).joined(separator: "."))' 의 형식이 다릅니다"))
        } catch let DecodingError.dataCorrupted(context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return .failure(.invalidJSON(path.isEmpty ? "JSON 이 아닙니다" : "'\(path)' 의 값을 받아들일 수 없습니다"))
        } catch {
            return .failure(.invalidJSON(error.localizedDescription))
        }
    }

    /// 해석과 검사를 한 번에. 문제가 있으면 전부 돌려준다 (계획 에이전트에게 한 번에 고치게 하려고).
    static func accept(_ json: String?, limits: PlanLimits = PlanLimits()) -> Result<OrchestrationPlan, PlanRejection> {
        switch decode(json) {
        case .failure(let issue): return .failure(PlanRejection(issues: [issue]))
        case .success(let plan):
            let issues = validate(plan, limits: limits)
            return issues.isEmpty ? .success(plan) : .failure(PlanRejection(issues: issues))
        }
    }

    static func validate(_ plan: OrchestrationPlan, limits: PlanLimits = PlanLimits()) -> [PlanIssue] {
        var issues: [PlanIssue] = []
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func meaningful(_ list: [String]) -> Bool { list.contains { !blank($0) } }

        if blank(plan.goal) { issues.append(.emptyGoal) }
        if !meaningful(plan.finalAcceptance) { issues.append(.missingFinalAcceptance) }
        if !plan.infoSufficient && !meaningful(plan.openQuestions) { issues.append(.insufficientInfoWithoutQuestions) }
        guard !plan.tasks.isEmpty else { return issues + [.noTasks] }
        if plan.tasks.count > limits.maxTasks {
            issues.append(.tooManyTasks(count: plan.tasks.count, max: limits.maxTasks))
        }
        if !plan.needsDecomposition && plan.tasks.count > 1 {
            issues.append(.decomposedWithoutNeed(count: plan.tasks.count))
        }

        var seen = Set<String>()
        for (index, task) in plan.tasks.enumerated() {
            if blank(task.id) { issues.append(.emptyTaskID(index: index)); continue }
            if !seen.insert(task.id).inserted { issues.append(.duplicateTaskID(task.id)) }
        }
        let byID = Dictionary(plan.tasks.filter { !blank($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for task in plan.tasks where !blank(task.id) {
            if blank(task.title) { issues.append(.emptyTitle(task: task.id)) }
            if blank(task.specification) { issues.append(.emptySpecification(task: task.id)) }
            if !(1...5).contains(task.difficulty) {
                issues.append(.difficultyOutOfRange(task: task.id, value: task.difficulty))
            }
            if !meaningful(task.acceptance) { issues.append(.missingAcceptance(task: task.id)) }
            if blank(task.verification) { issues.append(.missingVerification(task: task.id)) }
            for dependency in task.dependsOn {
                if dependency == task.id {
                    issues.append(.selfDependency(task: task.id))
                } else if let target = byID[dependency] {
                    if !task.optional && target.optional {
                        issues.append(.requiredDependsOnOptional(task: task.id, dependency: dependency))
                    }
                } else {
                    issues.append(.unknownDependency(task: task.id, dependency: dependency))
                }
            }
            for path in task.paths where escapesProject(path) {
                issues.append(.pathEscapesProject(task: task.id, path: path))
            }
        }

        if let cycle = cycle(in: plan.tasks) { issues.append(.dependencyCycle(cycle)) }
        return issues
    }

    /// 의존 관계를 지키는 실행 순서 (같은 단계 안에서는 계획에 적힌 순서). 순환이 있으면 nil.
    static func executionOrder(_ tasks: [PlannedTask]) -> [String]? {
        let ids = Set(tasks.map(\.id))
        var remaining = tasks
        var done = Set<String>()
        var order: [String] = []
        while !remaining.isEmpty {
            guard let index = remaining.firstIndex(where: { task in
                task.dependsOn.allSatisfy { done.contains($0) || !ids.contains($0) || $0 == task.id }
            }) else { return nil }
            let task = remaining.remove(at: index)
            done.insert(task.id)
            order.append(task.id)
        }
        return order
    }

    /// 순환에 걸린 작업들 (계획에 적힌 순서). 없으면 nil.
    private static func cycle(in tasks: [PlannedTask]) -> [String]? {
        let ids = Set(tasks.map(\.id))
        var remaining = tasks.filter { !$0.id.isEmpty }
        var done = Set<String>()
        var progressed = true
        while progressed {
            progressed = false
            remaining.removeAll { task in
                // 자기 의존 · 없는 의존은 따로 보고한다. 여기서는 순환만 본다.
                let ready = task.dependsOn.allSatisfy { done.contains($0) || !ids.contains($0) || $0 == task.id }
                if ready { done.insert(task.id); progressed = true }
                return ready
            }
        }
        return remaining.isEmpty ? nil : remaining.map(\.id)
    }

    private static func escapesProject(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { return true }
        var depth = 0
        for part in trimmed.split(separator: "/") {
            if part == ".." { depth -= 1 } else if part != "." { depth += 1 }
            if depth < 0 { return true }
        }
        return false
    }
}

/// 받아들이지 못한 계획. 계획 에이전트에게 그대로 돌려줘 한 번 고치게 한다 (계획 보정).
struct PlanRejection: Error, Equatable, Sendable {
    var issues: [PlanIssue]

    /// 계획 에이전트에게 보낼 보정 요청.
    var feedback: String {
        "계획을 받아들일 수 없습니다. 아래를 모두 고쳐 같은 형식으로 다시 주세요.\n"
            + issues.map { "- " + $0.message }.joined(separator: "\n")
    }
}
