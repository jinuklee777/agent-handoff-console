import Foundation

// 배정 정책을 평가하기 위한 관측 지표. 순수 코드다.
// 지금은 기록을 세어 보여 주기만 한다. 정책을 자동으로 바꾸지 않는다.

struct ProfileStats: Equatable, Identifiable, Sendable {
    var profileID: String
    var id: String { profileID }
    /// 끝난 시도 (취소 제외).
    var attempts = 0
    var passed = 0
    /// 통과 중 검증 명령(객관)이 뒷받침한 것. 나머지는 검토 의견 · 사람의 인정만으로 통과했다.
    var passedObjectively = 0
    /// 능력 실패로 세는 것 (검증 실패).
    var failedCapability = 0
    /// 분모에서 빼는 것: 환경 · 한도 · 네트워크 · 계획 결함 · 모호한 요구.
    var excluded = 0
    /// 검증 결과를 알 수 없는 것 (판정 불가 · 검증 수단 없음 · 전달 여부 미확인).
    var unverified = 0
    var firstTries = 0
    var firstTryPasses = 0

    /// 능력 실패만 분모에 넣은 통과율. 표본이 적으면 의미가 없다 — 화면은 표본 수를 함께 보인다.
    var passRate: Double? {
        let denominator = passed + failedCapability
        return denominator == 0 ? nil : Double(passed) / Double(denominator)
    }
}

enum OrchestrationMetrics {
    static func stats(attempts: [OrchestrationAttempt], verifications: [VerificationRecord]) -> [ProfileStats] {
        var objective = Set<String>()
        for record in verifications where record.outcome == .pass && record.evidenceJSON.contains("\"command\"") {
            if let id = record.attemptID { objective.insert(id) }
        }
        var byProfile: [String: ProfileStats] = [:]
        for attempt in attempts where attempt.state == .succeeded || attempt.state == .failed || attempt.state == .deliveryUnknown {
            var stats = byProfile[attempt.profileID] ?? ProfileStats(profileID: attempt.profileID)
            stats.attempts += 1
            let first = attempt.kind == .first
            if first { stats.firstTries += 1 }
            switch (attempt.state, attempt.failureClass) {
            case (.succeeded, _):
                stats.passed += 1
                if objective.contains(attempt.id) { stats.passedObjectively += 1 }
                if first { stats.firstTryPasses += 1 }
            case (.failed, .some(let failure)) where failure.countsAgainstModel:
                stats.failedCapability += 1
            case (.failed, .some(.deliveryUnknown)), (.deliveryUnknown, _), (.failed, nil):
                stats.unverified += 1
            default:
                stats.excluded += 1
            }
            byProfile[attempt.profileID] = stats
        }
        return byProfile.values.sorted { $0.attempts != $1.attempts ? $0.attempts > $1.attempts : $0.profileID < $1.profileID }
    }
}
