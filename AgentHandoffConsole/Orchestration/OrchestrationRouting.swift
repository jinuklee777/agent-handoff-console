import Foundation

// 실행 프로필과 배정 정책. 순수 코드다.
// 배정 정책은 작업의 유형 · 난이도 값만 본다. 그 값이 어디서 왔는지(정적 규칙 · 계획 에이전트)는 모른다.

/// 모델 · 추론 강도 · 계정을 묶은 실행 단위. "상위"는 제공자의 서열이 아니라 여기 적은 등급이다.
struct ExecutionProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var provider: AgentProvider
    /// nil 이면 CLI 기본 모델.
    var model: String?
    var effort: String?
    /// Codex 만. nil 이면 기본 계정.
    var codexAccountID: String?
    /// 1(가볍고 싸다) ~ 3(가장 강하다). 담당 변경은 등급이 높은 쪽으로 간다.
    var tier: Int
    var enabled = true
    /// 이 프로필에 맡기지 않을 작업 유형.
    var excludedKinds: [TaskKind] = []

    var label: String {
        [provider.displayName, model, effort].compactMap { $0 }.joined(separator: " · ")
    }

    init(id: String, name: String, provider: AgentProvider, model: String? = nil, effort: String? = nil,
         codexAccountID: String? = nil, tier: Int, enabled: Bool = true, excludedKinds: [TaskKind] = []) {
        self.id = id; self.name = name; self.provider = provider; self.model = model; self.effort = effort
        self.codexAccountID = codexAccountID; self.tier = tier; self.enabled = enabled; self.excludedKinds = excludedKinds
    }

    /// 저장된 설정에 나중에 생긴 칸이 없어도 읽는다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        provider = try c.decode(AgentProvider.self, forKey: .provider)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        codexAccountID = try c.decodeIfPresent(String.self, forKey: .codexAccountID)
        tier = try c.decodeIfPresent(Int.self, forKey: .tier) ?? 2
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        excludedKinds = try c.decodeIfPresent([TaskKind].self, forKey: .excludedKinds) ?? []
    }

    /// 처음 쓸 때의 제안. 설정에서 고친다. 가장 비싼 모델(Codex 의 astra 등)은 자동으로 넣지 않는다.
    /// Codex 는 두 등급 모두 Sol 이고 강도로 나눈다 (GPT-6 에는 Terra 가 없다 — Codex 도 5.6-Terra 를 6-Sol 로 옮기라고 안내한다).
    /// 모델은 계열 선택 `gpt-*-sol` — 보낼 때 그 계정 목록의 최신 Sol 로 풀려, 새 버전이 나오면 따라간다 (Claude 의 `opus` 처럼).
    static let defaults: [ExecutionProfile] = [
        ExecutionProfile(id: "claude-haiku", name: "Claude Haiku", provider: .claude, model: "haiku", tier: 1),
        ExecutionProfile(id: "claude-sonnet", name: "Claude Sonnet", provider: .claude, model: "sonnet", tier: 2),
        ExecutionProfile(id: "codex-sol-medium", name: "Codex Sol · medium", provider: .codex, model: "gpt-*-sol", effort: "medium", tier: 2),
        ExecutionProfile(id: "claude-opus", name: "Claude Opus", provider: .claude, model: "opus", tier: 3),
        ExecutionProfile(id: "codex-sol-high", name: "Codex Sol · high", provider: .codex, model: "gpt-*-sol", effort: "high", tier: 3),
    ]
}

/// 검토 에이전트를 언제 돌릴지.
enum ReviewMode: String, Codable, CaseIterable, Sendable {
    /// 작업마다 완료 조건을 검토한다.
    case always
    /// 검증 명령이 없을 때만 검토한다 (호출을 아낀다. 명령이 통과하면 완료 조건은 확인하지 않는다).
    case whenNoCommand
    /// 검토하지 않는다. 검증 명령도 없으면 "검증 불가"가 된다.
    case never

    var koreanName: String {
        switch self {
        case .always: return "항상 검토"
        case .whenNoCommand: return "검증 명령이 없을 때만"
        case .never: return "검토 안 함"
        }
    }
}

/// 검토단(서로 다른 제공자의 검토 담당 둘이 동시에 검토)을 언제 꾸릴지. 그 밖에는 검토 담당 한 명이다.
/// 검토단은 한 명이라도 실패면 실패다 (`VerificationJudge`). 검토 턴은 읽기 전용이라 동시에 돌아도 서로 부딪히지 않는다.
enum ReviewPanelMode: String, Codable, CaseIterable, Sendable {
    /// 언제나 한 명.
    case single
    /// 가장 높은 등급이 필요한 하위 작업과 최종 통합 검증에만.
    case hardAndFinal
    /// 최종 통합 검증에만.
    case finalOnly
    /// 모든 하위 작업과 최종 통합 검증.
    case always

    var koreanName: String {
        switch self {
        case .single: return "쓰지 않음 (한 명이 검토)"
        case .hardAndFinal: return "어려운 작업과 최종 검증"
        case .finalOnly: return "최종 검증만"
        case .always: return "모든 작업"
        }
    }
}

struct OrchestrationSettings: Codable, Equatable, Sendable {
    var enabled = false
    var profiles = ExecutionProfile.defaults
    var plannerProfileID = "claude-opus"
    var reviewerProfileID = "claude-sonnet"
    var reviewMode = ReviewMode.always
    /// 검토단을 꾸리는 범위. 다른 제공자의 프로필을 쓸 수 없으면 그때는 한 명이 검토한다.
    var reviewPanel = ReviewPanelMode.hardAndFinal
    /// 계획을 보여 주고 사용자가 시작을 눌러야 실행한다.
    var requiresPlanApproval = true
    /// 프로젝트 ID → 검증 명령 (프로젝트 폴더에서 셸로 실행). 사용자가 설정에 직접 적은 것만 실행한다.
    var verificationCommands: [String: String] = [:]
    var budget = OrchestrationBudget()
    /// 한도 여유를 **확인하지 못한** 프로필도 후보로 쓴다. 기본은 끔 — 확인되지 않은 것은 여유가 있다는 뜻이 아니다.
    /// 한도 조회가 안 되는 환경에서 사람이 알고 켜는 값이다 (조용히 완화하지 않는다).
    var allowUnknownLimits = false

    static let storageKey = "orchestration.settings"

    init() {}

    /// 저장된 설정에 나중에 생긴 칸이 없어도 읽는다 (없는 칸은 기본값). 없앤 칸(옛 문지기 `jevGate`)은 읽지 않고 넘긴다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OrchestrationSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        profiles = try c.decodeIfPresent([ExecutionProfile].self, forKey: .profiles) ?? d.profiles
        plannerProfileID = try c.decodeIfPresent(String.self, forKey: .plannerProfileID) ?? d.plannerProfileID
        reviewerProfileID = try c.decodeIfPresent(String.self, forKey: .reviewerProfileID) ?? d.reviewerProfileID
        reviewMode = try c.decodeIfPresent(ReviewMode.self, forKey: .reviewMode) ?? d.reviewMode
        reviewPanel = try c.decodeIfPresent(ReviewPanelMode.self, forKey: .reviewPanel) ?? d.reviewPanel
        requiresPlanApproval = try c.decodeIfPresent(Bool.self, forKey: .requiresPlanApproval) ?? d.requiresPlanApproval
        verificationCommands = try c.decodeIfPresent([String: String].self, forKey: .verificationCommands) ?? [:]
        budget = try c.decodeIfPresent(OrchestrationBudget.self, forKey: .budget) ?? d.budget
        allowUnknownLimits = try c.decodeIfPresent(Bool.self, forKey: .allowUnknownLimits) ?? d.allowUnknownLimits
    }

    func profile(_ id: String?) -> ExecutionProfile? { profiles.first { $0.id == id && $0.enabled } }
}

// MARK: - 배정

struct RoutingCandidate: Codable, Equatable, Sendable {
    var profileID: String
    /// nil 이면 후보였다. 값이 있으면 뺀 이유.
    var excluded: String?
}

struct RoutingOutcome: Equatable, Sendable {
    var selected: ExecutionProfile?
    var candidates: [RoutingCandidate]
    var reasonCodes: [String]
}

enum RoutingPolicy {
    static let version = "static-1"

    /// 난이도에서 바라는 등급.
    static func desiredTier(difficulty: Int) -> Int {
        switch difficulty {
        case ...2: return 1
        case 3: return 2
        default: return 3
        }
    }

    /// - Parameters:
    ///   - plan: 스케줄러가 정한 시도 (보완이면 같은 프로필, 담당 변경이면 써 본 프로필 제외).
    ///   - lastTier: 직전 시도의 등급 (담당 변경 · 가용성 전환의 기준).
    ///   - unavailable: 지금 쓸 수 없는 프로필과 이유 (CLI 없음 · 한도 · 미확인). 미확인도 후보에서 뺀다.
    static func choose(kind: TaskKind, difficulty: Int, plan: DispatchPlan, lastTier: Int?,
                       profiles: [ExecutionProfile], unavailable: [String: String]) -> RoutingOutcome {
        var candidates: [RoutingCandidate] = []
        var usable: [ExecutionProfile] = []
        for profile in profiles {
            let reason: String?
            if !profile.enabled { reason = "꺼 둔 프로필" }
            else if profile.excludedKinds.contains(kind) { reason = "\(kind.rawValue) 작업에 쓰지 않도록 설정됨" }
            else if plan.excludedProfileIDs.contains(profile.id) { reason = "이 작업에 이미 써 봄" }
            else if let why = unavailable[profile.id] { reason = why }
            else { reason = nil }
            candidates.append(RoutingCandidate(profileID: profile.id, excluded: reason))
            if reason == nil { usable.append(profile) }
        }

        func outcome(_ profile: ExecutionProfile?, _ codes: [String]) -> RoutingOutcome {
            RoutingOutcome(selected: profile, candidates: candidates, reasonCodes: profile == nil ? codes + ["noCandidate"] : codes)
        }
        /// 등급이 `tier` 이상인 것 중 가장 낮은 것, 없으면 그 아래에서 가장 높은 것. 같은 등급이면 설정에 적힌 순서.
        func nearest(atLeast tier: Int, in list: [ExecutionProfile]) -> ExecutionProfile? {
            list.filter { $0.tier >= tier }.min { $0.tier < $1.tier } ?? list.max { $0.tier < $1.tier }
        }

        switch plan.kind {
        case .retry:
            if let same = usable.first(where: { $0.id == plan.reuseProfileID }) { return outcome(same, ["retrySameProfile"]) }
            // 보완하려던 프로필을 지금 쓸 수 없다. 같은 등급 이상에서 고른다.
            return outcome(nearest(atLeast: lastTier ?? desiredTier(difficulty: difficulty), in: usable), ["retryProfileUnavailable"])
        case .first:
            return outcome(nearest(atLeast: desiredTier(difficulty: difficulty), in: usable),
                           ["difficulty\(difficulty)", "tier\(desiredTier(difficulty: difficulty))"])
        case .escalation:
            let base = lastTier ?? desiredTier(difficulty: difficulty)
            // 더 높은 등급이 먼저. 없으면 같은 등급의 다른 프로필(다른 시각). 낮은 등급으로는 내려가지 않는다.
            let higher = usable.filter { $0.tier > base }.min { $0.tier < $1.tier }
            return outcome(higher ?? usable.first { $0.tier == base }, [higher != nil ? "escalateTier" : "sameTierOtherProfile"])
        case .availabilitySwitch:
            let base = lastTier ?? desiredTier(difficulty: difficulty)
            let same = usable.first { $0.tier == base }
            return outcome(same ?? nearest(atLeast: base, in: usable), ["availabilitySwitch"])
        }
    }

    /// 검토 담당. 실행한 프로필과 다른 것을 우선한다 (자기 작업을 자기가 통과시키지 않게).
    /// 읽기 전용을 보장하지 못하는 제공자는 검토에 쓰지 않는다.
    static func reviewer(settings: OrchestrationSettings, executorProfileID: String?,
                         unavailable: [String: String]) -> ExecutionProfile? {
        let usable = settings.profiles.filter {
            $0.enabled && $0.provider.supportsReadOnlyTurns && unavailable[$0.id] == nil
        }
        if let preferred = usable.first(where: { $0.id == settings.reviewerProfileID }), preferred.id != executorProfileID {
            return preferred
        }
        let others = usable.filter { $0.id != executorProfileID }
        return others.max { $0.tier < $1.tier } ?? usable.first { $0.id == settings.reviewerProfileID } ?? usable.first
    }

    /// 검토단의 크기. 제공자 교차라 둘까지다.
    static let panelSize = 2

    /// 이 검증에 검토단을 꾸리는가. `difficulty` 가 nil 이면 최종 통합 검증이다.
    static func wantsPanel(mode: ReviewPanelMode, difficulty: Int?) -> Bool {
        switch mode {
        case .single: return false
        case .always: return true
        case .finalOnly: return difficulty == nil
        case .hardAndFinal: return difficulty.map { desiredTier(difficulty: $0) >= 3 } ?? true
        }
    }

    /// 검토 담당들. 첫 사람은 `reviewer` 와 같고, 검토단이면 **다른 제공자**에서 한 명을 더한다 — 같은 모델 계열은 같은 실수를
    /// 같이 놓치기 쉽다. 둘째는 실행한 프로필을 피하고 첫 사람과 등급이 가까운 것(같으면 높은 쪽)을 고른다.
    /// 다른 제공자에 쓸 수 있는 프로필이 없으면 한 명으로 돌아간다 (같은 제공자로 채우지 않는다).
    static func reviewers(settings: OrchestrationSettings, executorProfileID: String?, difficulty: Int?,
                          unavailable: [String: String]) -> [ExecutionProfile] {
        guard let first = reviewer(settings: settings, executorProfileID: executorProfileID, unavailable: unavailable) else { return [] }
        guard wantsPanel(mode: settings.reviewPanel, difficulty: difficulty) else { return [first] }
        let others = settings.profiles.filter {
            $0.enabled && $0.provider.supportsReadOnlyTurns && unavailable[$0.id] == nil
                && $0.provider != first.provider && $0.id != executorProfileID
        }
        let second = others.min {
            let a = abs($0.tier - first.tier), b = abs($1.tier - first.tier)
            return a != b ? a < b : $0.tier > $1.tier
        }
        return [first] + [second].compactMap { $0 }
    }

    /// 계획 담당. 설정한 프로필을 쓸 수 없으면 읽기 전용이 되는 것 중 등급이 가장 높은 것.
    static func planner(settings: OrchestrationSettings, unavailable: [String: String]) -> ExecutionProfile? {
        let usable = settings.profiles.filter {
            $0.enabled && $0.provider.supportsReadOnlyTurns && unavailable[$0.id] == nil
        }
        return usable.first { $0.id == settings.plannerProfileID } ?? usable.max { $0.tier < $1.tier }
    }
}
