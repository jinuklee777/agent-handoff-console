import Foundation

/// 추론 강도 목록 · 모델 칩의 판정 (SwiftUI 비의존 — `inttest offline` 에서 검증한다).
///
/// 단계는 카탈로그가 준 값만, 준 순서대로 쓴다 (Claude 다섯 + ULTRA(ultracode), Codex 모델별, Antigravity low/medium/high + ULTRA(boost)).
/// 선택 nil 은 Claude · Codex 에서 **기본 강도**로 풀린다 (`resolvedDefault` — 설정의 기본 강도(사람이 고른 것) → Codex 는 config.toml 의
/// `model_reasoning_effort` → 그 모델의 CLI 기본 강도 → High, 그 모델이 받는 첫 값). 화면과 전송이 같은 값을 쓴다
/// (`displayEffort(provider:selected:availability:defaults:)`). 받는 값이 하나도 없을 때(목록 모름 · 강도 없는 모델)만 넘기지 않고
/// "미선택" 으로 보인다. "CLI 기본값" 이라는 상태는 화면에 없다 — 앱이 무엇을 넘기는지 사용자가 알 수 없기 때문.
/// Antigravity 의 nil 은 **기본값 High** 다 — agy 에 CLI 기본 강도가 없어(제품군을 강도 없이 주면 거부, 1.2.2 실측) 앱이 High 를
/// 넘기므로 강도 목록 · 칩도 High 로 보인다 (`displayEffort`, `AntigravityAdapter.plan`).
/// 목록 · 키는 nil 로 가지 않는다. nil 로 돌아가는 길은 Antigravity 의 "기본값으로 되돌리기" 뿐이다.
/// 이름 · 설명은 입력창 디자인 시안의 강도 단계를 옮겼다.
enum EffortScale {

    /// 앱 기본 강도 — 설정에서 고르지 않았을 때 Claude 의 기본, Codex 는 config.toml · 모델의 기본이 없을 때의 마지막 차례
    /// (`resolvedDefault`). 설정 > 에이전트에서 바꾼다 (`AppModel.defaultEfforts`).
    static let builtInDefault = "high"
    /// 설정에서 고를 수 있는 Codex 기본 강도 — 모델마다 받는 목록이 달라 합집합을 둔다. 고른 모델이 받지 않으면 다음 차례(config.toml ·
    /// 그 모델의 기본 강도)로 보낸다. 고르지 않으면(저장값 없음) "모델 기본값".
    static let codexDefaultChoices = ["low", "medium", "high", "xhigh"]

    /// 단계 색 · 글리프를 정하는 등급. boost(Antigravity `/boost`)는 화면에서 ULTRA 로 보인다.
    enum Tier: String, Sendable, CaseIterable {
        case low, medium, high, xhigh, max, ultra
        /// 카탈로그가 앱이 모르는 값을 줬을 때 — 중립색 + 원문 이름.
        case unknown
    }

    enum Glyph: Equatable, Sendable {
        case none
        /// MAX — 번개
        case bolt
        /// ULTRA — 반짝임
        case sparkle
    }

    struct Step: Equatable, Sendable {
        /// CLI 에 넘기는 값 그대로 (예 "xhigh", "boost").
        var effort: String
        var tier: Tier
        var name: String
    }

    // MARK: 등급 · 이름

    static func tier(of effort: String) -> Tier {
        switch effort {
        case "low": return .low
        case "medium": return .medium
        case "high": return .high
        case "xhigh": return .xhigh
        case "max": return .max
        case "ultra", AntigravityAdapter.boostEffort, ModelCatalog.claudeUltracode: return .ultra
        default: return .unknown
        }
    }

    /// 화면 이름. 모르는 값은 카탈로그가 준 원문 그대로.
    static func name(of effort: String) -> String {
        switch tier(of: effort) {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra High"
        case .max: return "MAX"
        case .ultra: return "ULTRA"
        case .unknown: return effort
        }
    }

    static func glyph(of effort: String) -> Glyph {
        switch tier(of: effort) {
        case .max: return .bolt
        case .ultra: return .sparkle
        default: return .none
        }
    }

    /// MAX · ULTRA(boost 포함) — 캡슐 불꽃 테두리 · 불티 · 보내기 색이 붙는 강도.
    static func isSpecial(_ effort: String?) -> Bool {
        guard let effort else { return false }
        let tier = tier(of: effort)
        return tier == .max || tier == .ultra
    }

    /// 카드 설명 (LEVELS). nil 은 제공자 · 모델에 따라 사실이 다르므로 `nilDescription` 을 쓴다.
    ///
    /// 목업의 High "기본보다 깊게" 는 쓰지 않는다 — 기본 강도는 설정에서 바뀌므로 고정된 기준과 비교하지 않는다.
    static func description(of effort: String?) -> String {
        guard let effort else { return nilDescription(provider: .claude, efforts: []) }
        if effort == AntigravityAdapter.boostEffort { return ultraDescription(takesEffort: true) }
        if effort == ModelCatalog.claudeUltracode {
            return "Extra High + 워크플로(ultracode) · 일을 여러 에이전트에게 나눠 맡깁니다. 한도를 매우 빠르게 씁니다."
        }
        switch tier(of: effort) {
        case .low: return "빠르고 가볍게 답합니다."
        case .medium: return "속도와 깊이의 균형을 맞춥니다."
        case .high: return "Medium 보다 깊게 추론합니다. 응답이 조금 느려질 수 있습니다."
        case .xhigh: return "토큰 사용량이 눈에 띄게 늘어납니다."
        case .max: return "최대 추론 · 한도를 빠르게 소모합니다."
        case .ultra: return "최대 추론 + 자동 작업 위임."
        case .unknown: return "CLI 가 목록에 준 값입니다. 앱에는 이 강도의 설명이 없습니다."
        }
    }

    /// ULTRA(Antigravity `/boost`) 설명 — 실제로 넘기는 값. `takesEffort` 는 그 모델이 강도를 받는지 (받지 않으면 `/boost` 만).
    static func ultraDescription(takesEffort: Bool) -> String {
        takesEffort
            ? "High + /boost · 다중 에이전트 심층 추론. 토큰을 평소의 3~10배 씁니다."
            : "/boost · 이 모델은 강도를 받지 않아 /boost 만 붙입니다. 토큰을 평소의 3~10배 씁니다."
    }

    /// 지금 모델의 단계 목록을 아는 설명 — ULTRA 는 그 모델이 강도를 받는지에 따라 문구가 다르다.
    static func description(of effort: String?, efforts: [String]) -> String {
        guard effort == AntigravityAdapter.boostEffort else { return description(of: effort) }
        return ultraDescription(takesEffort: efforts.contains { ModelCatalog.antigravityEfforts.contains($0) })
    }

    // MARK: 선택하지 않은 강도 (nil)

    /// 화면이 보여 주는 강도 = 실제로 넘길 값 (`RunCoordinator.send` 도 같은 함수로 정한다).
    /// - 고른 값이 있으면 그대로.
    /// - Antigravity 의 nil 은 기본값 High (그 모델이 High 를 받을 때 — `AntigravityAdapter.plan` 과 같은 규칙).
    /// - Claude · Codex 의 nil 은 앱 기본 강도 `appDefault` — 그 모델의 강도 목록에 있을 때만. 목록이 비었으면(강도 없는 모델 ·
    ///   목록 모름) nil — 받는지 모르는 값을 넘기지 않는다. Claude 는 목록을 늘 안다 (`availability`).
    /// 빈 문자열은 고르지 않은 것과 같다 (어댑터 · 판정도 넘기지 않는다).
    static func displayEffort(provider: AgentProvider, selected: String?, efforts: [String],
                              appDefault: String = builtInDefault) -> String? {
        let selected = selected.flatMap { $0.isEmpty ? nil : $0 }
        guard selected == nil else { return selected }
        switch provider {
        case .gemini:
            return efforts.contains(AntigravityAdapter.defaultEffort) ? AntigravityAdapter.defaultEffort : nil
        case .claude, .codex:
            return efforts.contains(appDefault) ? appDefault : nil
        }
    }

    // MARK: 고르지 않은 강도의 기본값 (사용자 결정 2026-10-04)

    /// 고르지 않은 강도(nil)를 풀 재료. `user` = 설정 > 에이전트의 기본 추론 강도를 사람이 고른 값 (고르지 않았으면 nil — "모델 기본값"),
    /// `config` = Codex 계정 홈의 config.toml `model_reasoning_effort` (`CodexConfigDefaults`). 빈 값은 없는 것과 같다.
    struct Defaults: Equatable, Sendable {
        var user: String?
        var config: String?

        init(user: String? = nil, config: String? = nil) {
            self.user = user.flatMap { $0.isEmpty ? nil : $0 }
            self.config = config.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// 푼 기본 강도가 어디서 왔는지 — 카드 설명이 출처를 말한다.
    enum DefaultSource: Equatable, Sendable {
        /// 설정 > 에이전트의 기본 추론 강도 (사람이 고른 것).
        case settings
        /// Codex 계정의 config.toml.
        case config
        /// 그 모델의 CLI 기본 강도 (`model/list` 의 `defaultReasoningEffort`).
        case model
        /// 앱 기본 (High).
        case app
    }

    /// 고르지 않은 강도를 무엇으로 보이고 보낼지 — 그 모델이 받는 강도(`efforts`) 가운데 차례대로 첫 것:
    /// 설정의 기본 강도(사람이 고른 것) → Codex 는 config.toml 의 `model_reasoning_effort` → 그 모델의 CLI 기본 강도(`modelDefault`) →
    /// 앱 기본 High → (그것도 받지 않는 모델이면) Medium → 그 모델의 첫 단계. Claude 는 config · 모델 기본이 없어 설정의 값 → High 다
    /// (지금처럼). 목록이 비었으면(강도 없는 모델 · 목록 모름) nil — 받는지 모르는 값을 넘기지 않는다. 칩에 "미선택" 이 보이는 것은
    /// 그때뿐이다. Antigravity 는 `displayEffort` 의 옛 규칙(High)을 쓴다.
    static func resolvedDefault(provider: AgentProvider, efforts: [String], modelDefault: String?,
                                defaults: Defaults) -> (effort: String, source: DefaultSource)? {
        guard provider != .gemini else {
            return efforts.contains(AntigravityAdapter.defaultEffort) ? (AntigravityAdapter.defaultEffort, .app) : nil
        }
        var candidates: [(String?, DefaultSource)] = [(defaults.user, .settings)]
        if provider == .codex { candidates += [(defaults.config, .config), (modelDefault, .model)] }
        candidates += [(builtInDefault, .app), ("medium", .app), (efforts.first, .app)]
        for (value, source) in candidates {
            if let value, !value.isEmpty, efforts.contains(value) { return (value, source) }
        }
        return nil
    }

    /// 화면이 보여 주는 강도 = 실제로 넘길 값 (모델 칩 · 인계 카드 · `RunSession.send` 가 같은 함수로 정한다).
    /// 고른 값이 있으면 그대로, 없으면 `resolvedDefault`. 빈 문자열은 고르지 않은 것과 같다.
    static func displayEffort(provider: AgentProvider, selected: String?, availability: Availability,
                              defaults: Defaults) -> String? {
        if let selected = selected.flatMap({ $0.isEmpty ? nil : $0 }) { return selected }
        return resolvedDefault(provider: provider, efforts: availability.efforts, modelDefault: availability.modelDefault,
                               defaults: defaults)?.effort
    }

    /// 푼 기본 강도의 출처 — 카드 설명의 앞머리.
    static func defaultSourceLabel(_ source: DefaultSource, provider: AgentProvider) -> String {
        switch source {
        case .settings: return "기본 강도 (설정 > 에이전트)"
        case .config: return "Codex 설정(config.toml)의 강도"
        case .model: return "이 모델의 기본 강도"
        // Claude 는 설정에서 고르지 않아도 High 가 기본 강도로 보인다 — 같은 말을 쓴다.
        case .app: return provider == .claude ? "기본 강도 (설정 > 에이전트)" : "앱 기본 강도"
        }
    }

    /// 카드 설명 줄 — `note(selected:availability:provider:appDefault:)` 와 같고, 고르지 않은 강도(nil)만 `resolvedDefault` 로 풀어
    /// 그 출처를 말한다 ("이 모델의 기본 강도 · …"). 기본으로 쓸 단계가 하나도 없을 때만 고르라고 한다.
    static func note(selected: String?, availability: Availability, provider: AgentProvider, defaults: Defaults) -> String? {
        let unchosen = selected.flatMap { $0.isEmpty ? nil : $0 } == nil
        if unchosen, provider != .gemini, !steps(availability.efforts).isEmpty {
            guard let resolved = resolvedDefault(provider: provider, efforts: availability.efforts,
                                                 modelDefault: availability.modelDefault, defaults: defaults) else {
                return "이 모델은 기본으로 쓸 강도를 받지 않습니다. 단계를 고르세요."
            }
            return defaultSourceLabel(resolved.source, provider: provider) + " · "
                + description(of: resolved.effort, efforts: availability.efforts)
        }
        return note(selected: selected, availability: availability, provider: provider,
                    appDefault: defaults.user ?? builtInDefault)
    }

    /// 가장 좁은 입력창의 강도 이름 — "Extra High" 만 줄인다.
    static func compactName(of effort: String) -> String {
        tier(of: effort) == .xhigh ? "X-High" : name(of: effort)
    }

    /// Antigravity 의 강도가 CLI 에서 온 것이 아님을 가리는 데 쓰는 목록 속 CLI 강도 (ULTRA 는 뺀다).
    private static func cliEfforts(_ efforts: [String]) -> [String] {
        efforts.filter { ModelCatalog.antigravityEfforts.contains($0) }
    }

    /// 보이는 강도가 없을 때(nil) 칩 · 카드 제목의 이름과 접근성 값 — 앱 기본 강도를 넘길 수 없을 때만 온다 (`displayEffort`).
    /// 강도를 받지 않는 모델은 "강도 없음", 그 밖은(기본 강도가 없는 모델 · 목록 모름) "미선택". "CLI 기본값" 은 쓰지 않는다.
    static func nilName(provider: AgentProvider, efforts: [String]) -> (text: String, accessibility: String) {
        guard provider == .gemini else { return ("미선택", "강도 미선택") }
        return !efforts.isEmpty && cliEfforts(efforts).isEmpty ? ("강도 없음", "강도 없음") : ("미선택", "강도 미선택")
    }

    /// nil 설명 — 앱 기본 강도를 넘길 수 없을 때 (`displayEffort` 가 nil). 넘길 수 있으면 `note` 가 그 단계 설명 + 기본 강도 표시를 쓴다.
    /// Claude · Codex: 강도 없는 모델이면 강도 없이 보낸다고, 목록에 기본 강도가 없으면 단계를 고르라고. 목록을 모르면 넘기지 않는다고.
    /// Antigravity 는 앱이 High 를 넘긴다 (agy 가 제품군을 강도 없이 거부한 실측 — 3.8 Flash) — 모델이 받는 강도(`efforts`)로 가린다.
    static func nilDescription(provider: AgentProvider, efforts: [String], appDefault: String = builtInDefault) -> String {
        guard provider == .gemini else {
            if efforts.isEmpty { return "이 모델이 받는 강도를 확인하지 못해 추론 강도를 넘기지 않습니다." }
            return "설정의 기본 강도(\(name(of: appDefault)))를 이 모델은 받지 않습니다. 단계를 고르세요."
        }
        let cli = cliEfforts(efforts)
        if cli.isEmpty { return "이 모델은 추론 강도를 받지 않습니다. 강도 없이 보냅니다." }
        if cli.contains(AntigravityAdapter.defaultEffort) {
            return "기본값 High 로 보냅니다. CLI 기본값이 아니라 앱이 넘기는 값입니다."
        }
        return AntigravityAdapter.TurnBlock.noHigh(model: "", available: cli, ultra: false).message
    }

    /// nil 로 되돌리는 버튼 이름. Claude · Codex 는 강도를 받지 않는 모델에 남은 저장값을 비울 때만 (`offersReset`).
    static func resetTitle(provider: AgentProvider) -> String {
        provider == .gemini ? "기본값으로 되돌리기" : "강도 비우기"
    }

    /// 되돌리기 버튼을 둘지. 고른 강도가 있을 때만.
    /// - Claude · Codex: 단계가 있으면 두지 않는다 — nil 은 앱 기본 강도라 목록에서 그 단계를 고르면 된다. 강도를 받지 않는 모델에
    ///   저장값이 남았을 때만 비우기 (넘기지 않게). 목록 · 모델을 몰라 단계가 비었으면 비워도 넘길 값을 못 정하므로 두지 않는다.
    /// - Antigravity: 단계가 없으면(목록을 모름 · 목록에 없는 모델) 두지 않는다: 되돌리면 넘길 강도를 정하지 못해 보내지 못하고, 단계가
    ///   없어 다시 고를 수도 없다. agy 가 받지 않는 저장값(옛 선택에 남은 xhigh · max 등)은 늘 막히므로 단계가 없어도 비울 수 있게 둔다.
    static func offersReset(provider: AgentProvider, selected: String?, availability: Availability) -> Bool {
        guard let selected, !selected.isEmpty else { return false }
        guard provider == .gemini else { return availability.emptyReason == .noEfforts }
        guard availability.efforts.isEmpty else { return true }
        return !ModelCatalog.antigravityEfforts.contains(selected) && selected != AntigravityAdapter.boostEffort
    }

    /// 되돌리기 도움말 — `nilDescription` 과 같은 사실. 버튼이 있을 때(`offersReset`)만 보인다.
    static func resetHelp(provider: AgentProvider, availability: Availability) -> String {
        guard provider == .gemini else { return "추론 강도를 넘기지 않습니다 (이 모델은 강도를 받지 않습니다)" }
        guard !availability.efforts.isEmpty else {
            return "강도를 비웁니다 — 이 모델이 받는 강도를 확인하지 못해, 비우면 보내지 않습니다"
        }
        let cli = cliEfforts(availability.efforts)
        if cli.isEmpty { return "추론 강도를 넘기지 않습니다 (이 모델은 강도를 받지 않습니다)" }
        return cli.contains(AntigravityAdapter.defaultEffort)
            ? "기본값 High 로 되돌립니다"
            : "강도를 비웁니다 — 이 모델에는 기본값 High 가 없어 보내기 전에 강도를 골라야 합니다"
    }

    /// 모델 칩 도움말 — ULTRA 는 실제로 넘기는 것을 함께 적는다: Antigravity 는 판정이 정한 값(High + /boost),
    /// Claude 는 Extra High + 워크플로(ultracode — `effort` 가 그 값일 때).
    static func chipHelp(provider: AgentProvider, outcome: AntigravityAdapter.TurnOutcome?, effort: String? = nil) -> String {
        let base = "모델 · 추론 강도 — 이 대화에만 적용됩니다"
        if provider == .claude, effort == ModelCatalog.claudeUltracode {
            return base + " · ULTRA = Extra High + 워크플로(ultracode)"
        }
        guard provider == .gemini, case .send(let plan) = outcome, let ultra = plan.ultraText else { return base }
        return base + " · ULTRA = " + ultra + (plan.passedEffort == nil ? " (강도를 받지 않는 모델)" : "")
    }

    /// 실행 중 머리의 강도 칸 — 실제로 넘긴 값 (`RunCoordinator.activeSelection` · `activeBoost`).
    /// ULTRA 는 "ULTRA · High + /boost" (강도를 받지 않는 모델은 "ULTRA · /boost"), Claude 는 "ULTRA · Extra High + 워크플로".
    static func runMeta(effort: String?, boost: Bool) -> (text: String, tier: Tier)? {
        if effort == ModelCatalog.claudeUltracode { return ("ULTRA · Extra High + 워크플로", .ultra) }
        if boost || effort == AntigravityAdapter.boostEffort {
            let passed = effort.flatMap { $0.isEmpty || $0 == AntigravityAdapter.boostEffort ? nil : name(of: $0) }
            return ("ULTRA · " + (passed.map { "\($0) + /boost" } ?? "/boost"), .ultra)
        }
        guard let effort, !effort.isEmpty else { return nil }
        // 입력창 칩과 같은 이름 ("high" → "High") — 같은 값이 두 모양으로 보이지 않게.
        return (name(of: effort), tier(of: effort))
    }

    // MARK: 단계

    /// 카탈로그 값 → 강도 목록의 단계. 순서를 지키고, 빈 값 · 겹치는 값은 한 번만.
    static func steps(_ efforts: [String]) -> [Step] {
        var seen = Set<String>()
        return efforts.compactMap { effort in
            guard !effort.isEmpty, seen.insert(effort).inserted else { return nil }
            return Step(effort: effort, tier: tier(of: effort), name: name(of: effort))
        }
    }

    static func index(of effort: String?, in steps: [Step]) -> Int? {
        guard let effort else { return nil }
        return steps.firstIndex { $0.effort == effort }
    }

    /// 단계가 비는 이유 — 카드가 사실대로 말하려면 넷을 가려야 한다.
    enum EmptyReason: Equatable, Sendable {
        /// 모델 목록을 아직 못 읽었다 (조회 전 · 실패).
        case catalogUnknown
        /// 모델을 고르지 않았고 기본 모델도 모른다 (Codex 목록에 CLI 기본이 없음 · Antigravity 목록에 High 를 받는 Flash 가 없음 —
        /// 보내기도 모델을 요구한다).
        case modelUnchosen
        /// 고른 모델이 지금 목록에 없다 (계정을 바꿨거나 목록이 바뀜) — 그 모델이 받는 강도를 모른다.
        case modelUnlisted
        /// 모델이 강도를 받지 않는다 (카탈로그가 빈 목록을 줬다).
        case noEfforts
    }

    struct Availability: Equatable, Sendable {
        var efforts: [String]
        /// efforts 가 비었을 때만 값이 있다.
        var emptyReason: EmptyReason?
        /// 그 모델의 CLI 기본 강도 (Codex `model/list` 의 `defaultReasoningEffort`). 모르면 nil — 고르지 않은 강도를 풀 때 쓴다.
        var modelDefault: String? = nil
    }

    /// 지금 모델이 받는 강도 목록:
    /// - 고른 모델이 목록에 있으면 그 모델의 값.
    /// - 고른 모델이 목록에 없으면 Claude 는 앱의 단계 목록(`claudeEfforts` — 카탈로그도 모든 Claude 모델에 같은 값을 준다 — 모델별로 확인하지는
    ///   않았다), 그 밖은 모른다 — 다른 모델(CLI 기본 모델)의 단계를 빌려 보이지 않는다.
    /// - 고르지 않았으면(nil, Claude 는 "default" 도) Claude 는 앱의 단계 목록, 그 밖은 기본 모델(Codex 는 CLI 기본 모델, Antigravity 는
    ///   앱 기본 모델)의 값 — 보내기가 그 모델로 확정한다 (`AppModel.send`: nil 과 Claude 의 "default" 만 채운다).
    /// 모델 목록을 아직 못 읽었으면(Codex · Antigravity) 빈 목록 — 단계를 지어내지 않는다.
    static func availability(provider: AgentProvider, selectedModel: String?,
                             options: [AgentModelOption]) -> Availability {
        func from(_ option: AgentModelOption) -> Availability {
            option.supportedEfforts.isEmpty ? Availability(efforts: [], emptyReason: .noEfforts)
                : Availability(efforts: option.supportedEfforts, emptyReason: nil, modelDefault: option.defaultEffort)
        }
        let chosen = selectedModel.flatMap { $0.isEmpty || (provider == .claude && $0 == "default") ? nil : $0 }
        if let chosen {
            // Codex 계열 선택(`gpt-*-sol`)은 지금 목록의 최신으로 푼다 — 그 계열이 목록에 없으면 "목록에 없는 모델".
            if let option = ModelCatalog.option(for: chosen, in: options) { return from(option) }
            if provider == .claude { return Availability(efforts: ModelCatalog.claudeEfforts, emptyReason: nil) }
            return Availability(efforts: [], emptyReason: options.isEmpty ? .catalogUnknown : .modelUnlisted)
        }
        if provider == .claude { return Availability(efforts: ModelCatalog.claudeEfforts, emptyReason: nil) }
        guard !options.isEmpty else { return Availability(efforts: [], emptyReason: .catalogUnknown) }
        guard let preferred = ModelCatalog.preferredOption(in: options) else {
            return Availability(efforts: [], emptyReason: .modelUnchosen)
        }
        return from(preferred)
    }

    static func availableEfforts(provider: AgentProvider, selectedModel: String?,
                                 options: [AgentModelOption]) -> [String] {
        availability(provider: provider, selectedModel: selectedModel, options: options).efforts
    }

    /// 단계가 없을 때 강도 목록 자리의 문구.
    static func emptyMessage(_ reason: EmptyReason) -> String {
        switch reason {
        case .catalogUnknown: return "모델 목록을 아직 확인하지 못했습니다"
        case .modelUnchosen: return "모델을 고르면 추론 강도를 고를 수 있습니다"
        case .modelUnlisted: return "고른 모델이 지금 목록에 없어 받는 강도를 확인하지 못했습니다"
        case .noEfforts: return "이 모델은 추론 강도를 받지 않습니다"
        }
    }

    /// 단계 설명을 포함한 상태 문장. nil 이면 설명 없음. 강도 목록은 이 가운데 알아야 할 것만 쓴다 (`listNote`).
    /// - 단계가 있고 저장값이 그 안: 단계 설명. nil: `nilDescription`. 목록 밖 값: 되돌리거나 다른 단계를 고르라고 —
    ///   Antigravity 에서 High 가 없는 모델이면 되돌려도(nil) 넘길 강도가 없어 막히므로 다른 단계만.
    /// - 단계가 없는데 저장값이 있음: 그 값이 지금 모델에 맞는지 **확인하지 못했다**(목록 · 모델을 모름), 모델을 고르지 않았으면
    ///   고른 뒤에 확인한다, 모델이 강도를 받지 않으면 값이 남았다고만 적는다. 고를 단계가 없으니 "다른 단계" 는 권하지 않는다.
    /// - 단계가 없고 nil: 모델이 강도를 받지 않을 때만 nil 설명, 그 밖은 목록 자리 문구로 충분하다.
    /// Antigravity 에서 보내기가 막히는 경우(`AntigravityAdapter.plan`)는 카드가 이 문장 대신 막힌 이유를 보인다.
    static func note(selected: String?, availability: Availability, provider: AgentProvider,
                     appDefault: String = builtInDefault) -> String? {
        let steps = steps(availability.efforts)
        let selected = selected.flatMap { $0.isEmpty ? nil : $0 }
        if !steps.isEmpty {
            guard let selected else {
                // Claude · Codex 의 nil 은 앱 기본 강도 — 넘길 수 있으면 그 단계 설명에 출처를 붙인다.
                if provider != .gemini,
                   let shown = displayEffort(provider: provider, selected: nil, efforts: availability.efforts,
                                             appDefault: appDefault) {
                    return "기본 강도 (설정 > 에이전트) · " + description(of: shown, efforts: availability.efforts)
                }
                return nilDescription(provider: provider, efforts: availability.efforts, appDefault: appDefault)
            }
            guard index(of: selected, in: steps) != nil else {
                let cli = cliEfforts(availability.efforts)
                let resetBlocks = provider != .gemini
                    || (!cli.isEmpty && !cli.contains(AntigravityAdapter.defaultEffort))
                return resetBlocks ? "지금 모델의 강도 목록에 없는 값입니다. 다른 단계를 고르세요."
                    : "지금 모델의 강도 목록에 없는 값입니다. 되돌리거나 다른 단계를 고르세요."
            }
            return description(of: selected, efforts: availability.efforts)
        }
        guard selected != nil else {
            return availability.emptyReason == .noEfforts
                ? nilDescription(provider: provider, efforts: [], appDefault: appDefault) : nil
        }
        if availability.emptyReason == .noEfforts {
            return "이 모델은 강도를 받지 않지만 저장된 강도가 남아 있습니다. 넘기지 않으려면 강도를 비우세요."
        }
        guard provider == .gemini else {
            return availability.emptyReason == .modelUnchosen
                ? "모델을 고르면 이 값을 그 모델이 받는지 확인합니다."
                : "이 값을 지금 모델이 받는지 확인하지 못했습니다. 모델을 바꾸면 받지 않는 값은 해제됩니다."
        }
        // Antigravity: 고른 모델이 있으면 목록을 몰라도 고른 강도를 그대로 넘긴다 (되돌리기는 두지 않는다 — `offersReset`).
        // 모델을 고르지 않았고 기본 모델도 없으면 보내지 않는다. 판정이 막는 경우(옛 슬러그의 강도 충돌 등)는 카드가 그 이유를 대신 보인다.
        return availability.emptyReason == .modelUnchosen
            ? AntigravityAdapter.TurnBlock.modelUnchosen.message
            : "이 값을 지금 모델이 받는지 확인하지 못했습니다. 고른 강도를 그대로 넘깁니다."
    }

    /// 고른 값이 지금 선택을 바꾸는지 — 같은 값은 다시 보내지 않는다 (연출이 겹치지 않게). 고른 강도가 없을 때 화면에 보이던 값
    /// (Antigravity 기본값 High)을 누른 것도 같은 값이다 — 몰래 명시 High 로 저장하지 않는다.
    static func changesSelection(to effort: String?, current: String?, displayed: String?) -> Bool {
        guard effort != current else { return false }
        return !(current == nil && effort != nil && effort == displayed)
    }

    /// 모델을 바꿀 때: 새 모델이 받는 강도면 그대로, 아니면 해제(nil = 앱 기본 강도 · Antigravity 는 High). 기존 규칙.
    static func effortAfterModelChange(current: String?, supported: [String]) -> String? {
        guard let current, supported.contains(current) else { return nil }
        return current
    }

    // MARK: 칩 · 카드 제목

    /// 칩 · 카드 제목에 쓰는 강도 표시.
    struct Label: Equatable, Sendable {
        var text: String
        /// nil = 보이는 강도 없음 (slate) — "강도 없음" · "미선택" (`nilName`).
        var tier: Tier?
        var glyph: Glyph
        /// 저장된 값이 지금 단계에 없다 — 목록이 바뀌었거나, 목록 · 모델을 몰라 단계가 비었다. 어느 쪽인지는 카드 설명(`note`)이 가린다.
        /// 칩은 숨기지 않는다 (저장값은 실행 요청에 들어간다 — 어댑터가 넘기는지는 제공자 · 모델에 따른다).
        var offScale: Bool
    }

    /// 칩의 강도 칸. 모델이 강도를 받지 않고(목록이 비고) 저장된 강도도 없으면 nil — 칸을 두지 않는다.
    /// 저장된 값이 목록에 없어도 숨기지 않는다 (실행에 그 값이 넘어가므로). 고른 강도가 없으면 제공자에 맞는 이름 (`nilName`).
    static func label(selected: String?, efforts: [String], provider: AgentProvider = .claude) -> Label? {
        let steps = steps(efforts)
        guard let selected, !selected.isEmpty else {
            return steps.isEmpty ? nil
                : Label(text: nilName(provider: provider, efforts: efforts).text, tier: nil, glyph: .none, offScale: false)
        }
        return Label(text: name(of: selected), tier: tier(of: selected), glyph: glyph(of: selected),
                     offScale: index(of: selected, in: steps) == nil)
    }

    /// 접근성 값 문구 — 단계 이름, 보이는 강도가 없으면 `nilName`.
    static func accessibilityValue(selected: String?, provider: AgentProvider = .claude, efforts: [String] = []) -> String {
        guard let selected, !selected.isEmpty else { return nilName(provider: provider, efforts: efforts).accessibility }
        return name(of: selected)
    }

    // MARK: 조작

    enum Direction: Sendable { case decrease, increase }

    /// ↑ ↓ (← →) 한 단계. 반환 nil = 움직이지 않는다 (끝에서 멈춤 · 단계 없음 — 같은 값을 다시 골라 연출이 겹치지 않게).
    /// nil · 목록에 없는 값에서는 어느 쪽이든 **첫 단계** — 척도의 시작에 올린다. nil 로는 가지 않는다.
    /// 부르는 쪽은 `displayEffort`(nil = 앱 기본 강도 · Antigravity 는 High)를 넘긴다 — 보이는 단계에서 한 단계씩 움직인다.
    static func keyStep(from selected: String?, _ direction: Direction, efforts: [String]) -> String? {
        let steps = steps(efforts)
        guard let first = steps.first else { return nil }
        guard let current = index(of: selected, in: steps) else { return first.effort }
        let next = direction == .increase ? current + 1 : current - 1
        guard steps.indices.contains(next) else { return nil }
        return steps[next].effort
    }

    /// ULTRA 가 강도 단계가 아니라 한 단계에 무엇을 더한 것이면(Antigravity boost = High + `/boost`, Claude ultracode = Extra High +
    /// 워크플로) 강도 목록에서 구분선으로 떼어 둔다. Codex 의 ultra 는 CLI 의 강도 값이라 떼지 않는다.
    static func separatesLast(_ steps: [Step]) -> Bool {
        guard steps.count > 1, let last = steps.last?.effort else { return false }
        return last == AntigravityAdapter.boostEffort || last == ModelCatalog.claudeUltracode
    }

    // MARK: 강도 목록 (모델 칩 팝오버 — 캔버스 시안 B, 사용자 결정 2026-10-07)

    /// 행 이름 아래의 한 줄 — 한도를 크게 쓰는 단계(MAX · ULTRA)만 말한다. 그 밖의 단계는 이름 · 색 · 순서로 충분해 설명을 두지 않는다.
    /// ULTRA(boost)는 실제로 넘기는 값이 모델에 따라 달라 그것을 적는다 (`ultraDescription` 과 같은 사실, 한 줄에 들게 줄였다).
    static func rowNote(of effort: String, efforts: [String]) -> String? {
        if effort == ModelCatalog.claudeUltracode { return "Extra High + 워크플로 · 한도를 매우 빠르게 소모합니다." }
        if effort == AntigravityAdapter.boostEffort {
            let takesEffort = efforts.contains { ModelCatalog.antigravityEfforts.contains($0) }
            // "3~10" 과 "배" 사이에서 줄이 꺾이지 않게 (U+2060 단어 이음).
            let cost = "토큰을 평소의 3~10\u{2060}배 씁니다."
            return (takesEffort ? "High + /boost · " : "/boost 만 붙입니다 · ") + cost
        }
        switch tier(of: effort) {
        case .max: return "한도를 빠르게 소모합니다."
        case .ultra: return "최대 추론 + 자동 작업 위임."
        default: return nil
        }
    }

    /// 행에 포인터를 올렸을 때의 안내 — 이름만으로 무엇이 일어나는지 알 수 없는 단계만. Claude 의 ULTRA(ultracode)는 MAX 보다
    /// 깊게 추론하는 단계가 아니라는 것과 그때 일어나는 일(사용자 결정 2026-10-07 — 막지 않고 안내만 한다).
    static func rowHelp(of effort: String) -> String? {
        guard effort == ModelCatalog.claudeUltracode else { return nil }
        return "Claude Code 의 ultracode 입니다. 강도는 Extra High 로 두고, 일을 여러 에이전트에게 나눠 맡기는 워크플로를 씁니다 — "
            + "MAX 보다 깊게 추론하는 단계가 아닙니다. 워크플로마다 승인을 묻고, 워크플로가 도는 동안 이 대화는 그 일이 끝나기를 "
            + "기다립니다. 계정이나 모델이 워크플로를 쓸 수 없으면 Extra High 로만 돕니다."
    }

    /// "기본" 표시를 붙일 단계와 그 도움말 — 강도를 고르지 않으면 보낼 단계(`resolvedDefault`)와 그것이 어디서 왔는지.
    /// 단계가 없거나 기본으로 쓸 단계가 없으면 nil.
    static func defaultMark(provider: AgentProvider, availability: Availability,
                            defaults: Defaults) -> (effort: String, help: String)? {
        guard let resolved = resolvedDefault(provider: provider, efforts: availability.efforts,
                                             modelDefault: availability.modelDefault, defaults: defaults) else { return nil }
        return (resolved.effort, defaultSourceLabel(resolved.source, provider: provider)
                + " — 강도를 고르지 않으면 이 단계로 보냅니다")
    }

    /// 강도 목록 아래의 알림 줄 — 단계 설명은 두지 않으므로 사람이 알아야 할 것만: 지금 단계에 없는 값 · 고르지 않았는데 기본으로
    /// 보낼 단계가 없음 · 단계가 없는데 저장된 값이 남음(`note` 의 그 문장들). 그 밖은 nil. 단계가 없고 고른 값도 없으면 목록 자리의
    /// 문구(`emptyMessage`)로 충분하다. Antigravity 에서 보내기가 막히면 화면이 이 줄 대신 막힌 이유를 보인다.
    static func listNote(selected: String?, availability: Availability, provider: AgentProvider,
                         defaults: Defaults) -> String? {
        let steps = steps(availability.efforts)
        let selected = selected.flatMap { $0.isEmpty ? nil : $0 }
        guard !steps.isEmpty else {
            guard selected != nil else { return nil }
            return note(selected: selected, availability: availability, provider: provider, defaults: defaults)
        }
        if let selected {
            return index(of: selected, in: steps) == nil
                ? note(selected: selected, availability: availability, provider: provider, defaults: defaults) : nil
        }
        guard displayEffort(provider: provider, selected: nil, availability: availability, defaults: defaults) == nil else {
            return nil
        }
        return provider == .gemini ? nilDescription(provider: provider, efforts: availability.efforts)
            : "이 모델은 기본으로 쓸 강도를 받지 않습니다. 단계를 고르세요."
    }

    /// 사용자가 강도를 골랐을 때의 연출 (입력창이 쓰던 규칙): xhigh 는 테두리 amber 깜빡임,
    /// max · ultra · boost 는 촉각 · 효과음(설정이 켜져 있을 때). 강도를 비울 때는 없다.
    enum Effect: Equatable, Sendable { case none, flash, special }

    static func effect(choosing effort: String?) -> Effect {
        guard let effort else { return .none }
        if tier(of: effort) == .xhigh { return .flash }
        return isSpecial(effort) ? .special : .none
    }
}
