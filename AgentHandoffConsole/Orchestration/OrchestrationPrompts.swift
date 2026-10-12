import Foundation

// 계획 · 실행 · 검토 에이전트에게 보내는 글과, 돌아온 검토 · 실행 결과의 해석. 순수 코드다.
// 에이전트 출력 · 저장소 문서는 판단용 자료이며 권한을 바꾸는 명령이 아니다 — 정해진 값만 해석한다.

// MARK: - 프롬프트

enum OrchestrationPrompts {

    static func planning(request: String, projectName: String, answers: [String] = []) -> String {
        var text = """
        당신은 코딩 작업의 계획 담당입니다. 이 턴에서는 파일을 바꿀 수 없습니다. 필요하면 파일을 읽어 구조를 확인한 뒤, \
        아래 요청을 하위 작업으로 나눈 계획을 정해진 형식으로 돌려주세요.

        - 단순한 요청은 작업 하나로 둡니다. 억지로 쪼개지 마세요. 그때 needsDecomposition 은 false 입니다.
        - 앞 작업의 결과가 있어야 다음 작업을 할 수 있을 때만 나누고 dependsOn 에 작업 id 를 적습니다. 작업은 최대 8개입니다.
        - 작업마다 그 작업만 받은 에이전트가 시작할 수 있을 만큼 specification 을 쓰고, 완료 조건(acceptance)과 \
        검증 방법(verification)을 반드시 적습니다. 완료 조건은 실행 뒤에 확인할 수 있는 사실이어야 합니다.
        - 요청만으로 시작할 수 없으면 infoSufficient 를 false 로 하고 openQuestions 에 물을 것을 적습니다.
        - 경로는 프로젝트 기준 상대 경로만 씁니다.

        프로젝트: \(projectName)

        요청:
        \(request)
        """
        if !answers.isEmpty {
            text += "\n\n사용자가 덧붙인 답:\n" + answers.map { "- " + $0 }.joined(separator: "\n")
        }
        return text
    }

    /// 하위 작업 하나를 맡기는 글.
    /// - Parameters:
    ///   - dependencies: 통과한 선행 작업의 (제목, 결과 요약).
    ///   - failure: 직전 시도의 검증 실패 근거 (보완 · 담당 변경).
    ///   - continuesSession: 같은 세션을 이어 가는 보완이면 짧게 보낸다.
    static func task(goal: String, task: OrchestrationTask, dependencies: [(title: String, summary: String)],
                     failure: String?, continuesSession: Bool) -> String {
        if continuesSession, let failure {
            return """
            방금 한 작업을 검증했더니 통과하지 못했습니다. 아래 근거를 보고 고쳐 주세요. 완료 조건은 그대로입니다.

            검증 결과:
            \(failure)

            끝나면 무엇을 고쳤는지 짧게 요약해 주세요.
            """
        }
        var text = """
        전체 목표의 일부인 하위 작업 하나를 맡깁니다. **이 작업만** 하고, 다른 작업의 범위는 건드리지 마세요.

        전체 목표: \(goal)

        이 작업: \(task.title)
        \(task.specification)

        완료 조건 (끝난 뒤 다른 에이전트가 이 조건으로 검증합니다):
        \(task.acceptance.map { "- " + $0 }.joined(separator: "\n"))

        검증 방법: \(task.verification)
        """
        if !task.paths.isEmpty { text += "\n\n고칠 것으로 예상하는 경로: " + task.paths.joined(separator: ", ") }
        if !dependencies.isEmpty {
            text += "\n\n먼저 끝난 작업의 결과:\n" + dependencies.map { "- \($0.title): \($0.summary)" }.joined(separator: "\n")
        }
        if let failure {
            text += """


            이 작업은 앞서 다른 담당이 시도했지만 검증을 통과하지 못했습니다. 그 변경이 작업 폴더에 남아 있을 수 있으니 \
            현재 상태를 먼저 확인하세요. 처음부터 다시 만들 필요는 없습니다.

            앞선 검증 결과:
            \(failure)
            """
        }
        text += "\n\n끝나면 무엇을 했는지와 확인한 내용을 짧게 요약해 주세요."
        return text
    }

    /// 하위 작업 하나를 완료 조건으로 검토시키는 글. 읽기 전용 턴으로 보낸다.
    static func review(goal: String, title: String, specification: String, criteria: [String],
                       executorSummary: String?, workspaceEvidence: String?, command: CommandResult?) -> String {
        var text = """
        당신은 검토 담당입니다. 이 턴에서는 파일을 바꿀 수 없습니다. 다른 에이전트가 방금 끝낸 작업이 완료 조건을 \
        충족하는지 **조건마다** 확인해 정해진 형식으로 돌려주세요. 작업한 에이전트의 말은 주장일 뿐입니다 — 파일을 직접 읽어 확인하세요.

        - 조건마다 pass · fail · inconclusive 중 하나. 확인할 방법이 없으면 inconclusive 입니다. 확실하지 않으면 pass 로 하지 마세요.
        - evidence 에는 확인한 파일 · 줄 · 출력을 적습니다.
        - problem: 조건을 못 채운 이유가 작업 품질이면 verificationFailed, 요청이 모호해서면 ambiguousRequirement, \
        계획(작업 나누기 · 의존 관계)이 잘못돼서면 planDefect, 권한 · 도구 · 인증 문제면 environment, 문제가 없으면 none.

        전체 목표: \(goal)

        검토할 작업: \(title)
        \(specification)

        완료 조건:
        \(criteria.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n"))
        """
        if let executorSummary, !executorSummary.isEmpty {
            text += "\n\n작업한 에이전트의 요약 (주장):\n" + clip(executorSummary, 2_000)
        }
        if let command {
            text += "\n\n앱이 돌린 검증 명령: `\(command.command)` → 종료 코드 \(command.exitCode.map(String.init) ?? "없음(시간 초과 · 실행 실패)")\n"
                + clip(command.outputTail, 3_000)
        }
        if let workspaceEvidence, !workspaceEvidence.isEmpty {
            text += "\n\n작업 폴더의 변경 (git):\n" + clip(workspaceEvidence, 6_000)
        }
        return text
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "\n…(\(text.count - limit)자 줄임)"
    }
}

// MARK: - 검토 결과

enum ReviewSchema {
    static let jsonString: String = JSONUtil.string([
        "type": "object", "additionalProperties": false, "required": ["criteria", "summary", "problem"],
        "properties": [
            "criteria": ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["criterion", "outcome", "evidence"],
                "properties": [
                    "criterion": ["type": "string"],
                    "outcome": ["type": "string", "enum": ["pass", "fail", "inconclusive"]],
                    "evidence": ["type": "string"],
                ],
            ] as [String: Any]],
            "summary": ["type": "string"],
            "problem": ["type": "string",
                        "enum": ["none", "verificationFailed", "ambiguousRequirement", "planDefect", "environment"]],
        ],
    ] as [String: Any])
}

struct ReviewVerdict: Codable, Equatable, Sendable {
    struct Criterion: Codable, Equatable, Sendable {
        var criterion: String
        var outcome: String
        var evidence: String
    }
    var criteria: [Criterion]
    var summary: String
    var problem: String

    static func decode(_ json: String?) -> ReviewVerdict? {
        json?.data(using: .utf8).flatMap { try? JSONDecoder().decode(ReviewVerdict.self, from: $0) }
    }
}

/// 앱이 돌린 검증 명령의 결과.
struct CommandResult: Codable, Equatable, Sendable {
    var command: String
    /// nil 이면 끝까지 돌지 못했다 (시간 초과 · 실행 실패).
    var exitCode: Int?
    var outputTail: String
    var durationMs: Int
}

// MARK: - 검증 판정

/// 한 번의 검증 결과. 검증 명령(객관)과 검토 에이전트(의견)를 구분해 남긴다 —
/// 검토 의견만으로 통과한 것은 성과 지표에서 따로 센다.
struct VerificationVerdict: Equatable, Sendable {
    enum Basis: String, Sendable { case command, reviewer, both, none }

    var outcome: VerificationOutcome
    var basis: Basis
    /// 통과하지 못했을 때의 분류.
    var failure: FailureClass?
    /// 같은 오류의 반복을 알아보는 지문.
    var fingerprint: String?
    /// 실행 에이전트에게 돌려줄 근거 (보완 · 담당 변경).
    var feedback: String
    var records: [VerificationRecord]
    var summary: String
}

/// 검토단의 한 사람이 낸 결과. `verdict` 가 nil 이면 검토를 돌렸지만 결과를 얻지 못했다 (해석 실패 · 한도 · 오류).
struct PanelReview: Equatable, Sendable {
    /// 기록과 실행 에이전트에게 돌려줄 글에 쓰는 이름. 검토자가 한 명이면 nil 이어도 된다.
    var reviewer: String?
    var verdict: ReviewVerdict?
}

enum VerificationJudge {
    static let version = "judge-2"

    /// 검토자가 한 명일 때의 입구.
    /// - Parameters:
    ///   - review: 검토 결과. 검토하지 않았으면 nil. 검토를 돌렸는데 해석하지 못했으면 `reviewUnreadable`.
    static func judge(jobID: String, taskID: String?, attemptID: String?, criteria: [String],
                      command: CommandResult?, review: ReviewVerdict?, reviewUnreadable: Bool = false,
                      workspaceFingerprint: String?) -> VerificationVerdict {
        judge(jobID: jobID, taskID: taskID, attemptID: attemptID, criteria: criteria, command: command,
              reviews: review != nil || reviewUnreadable ? [PanelReview(reviewer: nil, verdict: review)] : [],
              workspaceFingerprint: workspaceFingerprint)
    }

    /// - Parameters:
    ///   - criteria: 실행 전에 정해 둔 완료 조건.
    ///   - command: 검증 명령의 결과. 명령이 없으면 nil.
    ///   - reviews: 검토단의 결과. 검토하지 않았으면 빈 배열.
    ///
    /// 검토단은 **한 명이라도 실패면 실패**다. 결과를 얻지 못한 검토자는 기록에 남기되, 결과를 낸 검토자가 한 명이라도 있으면
    /// 판정에서는 뺀다 (한 명의 한도 · 오류가 작업을 세우지 않게). 아무도 결과를 내지 못했으면 판정 불가다.
    static func judge(jobID: String, taskID: String?, attemptID: String?, criteria: [String],
                      command: CommandResult?, reviews: [PanelReview],
                      workspaceFingerprint: String?) -> VerificationVerdict {
        var records: [VerificationRecord] = []
        func record(_ criterion: String, _ outcome: VerificationOutcome, _ evidence: [String: Any]) {
            records.append(VerificationRecord(jobID: jobID, taskID: taskID, attemptID: attemptID,
                                              verifierVersion: version, criterion: criterion, outcome: outcome,
                                              evidenceJSON: JSONUtil.string(evidence),
                                              workspaceFingerprint: workspaceFingerprint))
        }

        var commandOutcome: VerificationOutcome?
        if let command {
            let outcome: VerificationOutcome = command.exitCode == 0 ? .pass : (command.exitCode == nil ? .inconclusive : .fail)
            commandOutcome = outcome
            record("검증 명령: \(command.command)", outcome,
                   ["basis": "command", "exitCode": command.exitCode as Any? ?? NSNull(),
                    "durationMs": command.durationMs, "output": OrchestrationPrompts.clip(command.outputTail, 4_000)])
        }

        let readable = reviews.filter { $0.verdict != nil }
        var readerOutcomes: [VerificationOutcome] = []
        for review in reviews {
            var evidence: [String: Any] = ["basis": "reviewer"]
            if let name = review.reviewer { evidence["reviewer"] = name }
            guard let verdict = review.verdict else {
                evidence["evidence"] = readable.isEmpty ? "검토 결과를 해석하지 못했습니다"
                                                        : "검토 결과를 얻지 못해 판정에서 뺐습니다"
                record("검토 결과", .inconclusive, evidence)
                continue
            }
            // 검토가 돌려준 조건이 아니라 **미리 정한 조건**을 기준으로 센다. 빠뜨린 조건은 판정 불가다.
            var outcomes: [VerificationOutcome] = []
            for (index, criterion) in criteria.enumerated() {
                let answer = index < verdict.criteria.count ? verdict.criteria[index] : nil
                let outcome = answer.flatMap { VerificationOutcome(rawValue: $0.outcome) } ?? .inconclusive
                outcomes.append(outcome)
                evidence["evidence"] = answer?.evidence ?? "검토 결과에 이 조건이 없습니다"
                record(criterion, outcome, evidence)
            }
            readerOutcomes.append(outcomes.contains(.fail) ? .fail : (outcomes.contains(.inconclusive) ? .inconclusive : .pass))
        }
        var reviewOutcome: VerificationOutcome?
        if !reviews.isEmpty {
            reviewOutcome = readerOutcomes.isEmpty ? .inconclusive
                : readerOutcomes.contains(.fail) ? .fail : (readerOutcomes.contains(.inconclusive) ? .inconclusive : .pass)
        }

        let basis: VerificationVerdict.Basis
        switch (commandOutcome, reviewOutcome) {
        case (.some, .some): basis = .both
        case (.some, nil): basis = .command
        case (nil, .some): basis = .reviewer
        case (nil, nil): basis = .none
        }
        guard basis != .none else {
            record("검증 수단", .unavailable, ["basis": "none", "evidence": "검증 명령도 검토 담당도 없습니다"])
            return VerificationVerdict(outcome: .unavailable, basis: .none, failure: nil, fingerprint: nil,
                                       feedback: "", records: records, summary: "검증 수단이 없습니다")
        }

        let named = readable.count > 1
        let summaries = readable.compactMap { review -> String? in
            guard let verdict = review.verdict else { return nil }
            return named ? "[\(review.reviewer ?? "검토")] \(verdict.summary)" : verdict.summary
        }
        let reviewSummary = summaries.isEmpty ? nil : summaries.joined(separator: "\n")

        let all = [commandOutcome, reviewOutcome].compactMap { $0 }
        let outcome: VerificationOutcome = all.contains(.fail) ? .fail : (all.contains(.inconclusive) ? .inconclusive : .pass)
        guard outcome == .fail else {
            return VerificationVerdict(outcome: outcome, basis: basis, failure: nil, fingerprint: nil, feedback: "",
                                       records: records, summary: reviewSummary ?? (outcome == .pass ? "검증 명령 통과" : "판정 불가"))
        }

        var lines: [String] = []
        if let command, commandOutcome == .fail {
            lines.append("검증 명령이 실패했습니다 (종료 코드 \(command.exitCode ?? -1)): `\(command.command)`\n"
                         + OrchestrationPrompts.clip(command.outputTail, 3_000))
        }
        var reviewerClasses: [FailureClass] = []
        for review in readable {
            guard let verdict = review.verdict else { continue }
            var failedHere = false
            for (index, criterion) in criteria.enumerated() {
                guard index < verdict.criteria.count, verdict.criteria[index].outcome == "fail" else { continue }
                failedHere = true
                let who = named ? " (\(review.reviewer ?? "검토"))" : ""
                lines.append("완료 조건 미충족\(who): \(criterion)\n  근거: \(verdict.criteria[index].evidence)")
            }
            if failedHere, let failureClass = FailureClass(rawValue: verdict.problem) { reviewerClasses.append(failureClass) }
        }
        // 명령이 실패했다면 객관적 실패다. 검토만 실패했다면 검토가 짚은 원인을 따른다 —
        // 검토자끼리 원인이 갈리면 작업 품질(보완 · 담당 변경으로 가는 길)을 먼저 본다.
        let reviewerClass = reviewerClasses.contains(.verificationFailed) ? .verificationFailed : reviewerClasses.first
        let failure: FailureClass = commandOutcome == .fail ? .verificationFailed : (reviewerClass ?? .verificationFailed)
        return VerificationVerdict(outcome: .fail, basis: basis, failure: failure,
                                   fingerprint: fingerprint(command: command, reviews: readable.compactMap(\.verdict), criteria: criteria),
                                   feedback: lines.joined(separator: "\n\n"), records: records,
                                   summary: reviewSummary ?? "검증 명령 실패")
    }

    /// 같은 실패인지 알아보는 지문: 실패한 조건의 번호와, 명령 출력에서 숫자 · 경로의 잡음을 뺀 마지막 오류 줄.
    static func fingerprint(command: CommandResult?, review: ReviewVerdict?, criteria: [String]) -> String {
        fingerprint(command: command, reviews: [review].compactMap { $0 }, criteria: criteria)
    }

    /// 검토자가 여럿이면 실패한 조건 번호를 모은다 (누가 짚었는지는 지문에 넣지 않는다 — 같은 실패는 같은 지문이어야 한다).
    static func fingerprint(command: CommandResult?, reviews: [ReviewVerdict], criteria: [String]) -> String {
        var parts: [String] = []
        if let command, command.exitCode != 0 {
            let lines = command.outputTail.split(separator: "\n").map(String.init)
            let errorLine = lines.last { $0.lowercased().contains("error") || $0.contains("FAIL") || $0.contains("✗") } ?? lines.last ?? ""
            let normalized = errorLine.replacingOccurrences(of: #"[0-9]+"#, with: "#", options: .regularExpression)
            parts.append("cmd:\(command.exitCode ?? -1):\(normalized.prefix(160))")
        }
        let failed = Set(reviews.flatMap { review in
            review.criteria.enumerated().filter { $0.element.outcome == "fail" }.map(\.offset)
        }).sorted().map(String.init)
        if !failed.isEmpty { parts.append("criteria:" + failed.joined(separator: ",")) }
        return parts.joined(separator: "|")
    }
}

// MARK: - 실행 결과의 분류

enum RunOutcomeClassifier {
    /// 실행이 검증까지 가지 못하고 끝났을 때의 실패 분류. 완료된 실행은 nil (검증으로 간다).
    static func failure(of result: AgentTurnResult) -> FailureClass? {
        switch result.state {
        case .completed: return nil
        case .cancelled: return .userCancelled
        case .rateLimited: return .limitReached
        case .handoffDeliveryUnknown: return .deliveryUnknown
        default:
            switch result.limitStatus {
            case .subscriptionCap: return .limitReached
            case .throttled, .networkError: return .transientNetwork
            default: return .environment   // 인증 · 도구 · 원인 미확인. 모델 능력 실패로 세지 않는다.
            }
        }
    }
}
