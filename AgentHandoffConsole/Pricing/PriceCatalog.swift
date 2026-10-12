import Foundation

/// API 환산 비용 계산용 가격표.
///
/// 중요:
/// - 여기 값은 "실제 청구액"이 아니라 **같은 모델을 API로 호출했을 때의 환산 비용**이다.
///   Claude Code·Codex·Antigravity 구독으로 실행한 작업의 실제 청구액과는 다를 수 있다.
/// - Claude는 CLI가 `modelUsage[model].costUSD`를 직접 반환하면 그 값을 우선 사용한다.
/// - Antigravity가 노출하는 Claude 모델도 해당 Anthropic API 단가로 환산한다.
/// - Gemini 컨텍스트 캐시의 시간당 저장료는 토큰 사용량만으로 계산할 수 없어 포함하지 않는다.
enum PriceCatalog {

    static let version = "public-api-2026-09-28"
    static let effectiveDate = "2026-09-28"

    private static let anthropicSource = "Anthropic 공식 API 가격표"
    private static let openAISource = "OpenAI 공식 API 모델 가격표"
    private static let googleSource = "Google Gemini Developer API Standard 가격표 (2026-12-31까지)"
    private static let antigravityClaudeSource = "Antigravity 제공 Claude 모델의 Anthropic API 환산 단가"

    /// 캐시 읽기는 기본 입력의 0.1배, 쓰기(5분)는 1.25배다. 읽기 배율이 다른 모델은 `cacheRead` 로 준다
    /// (Fable 5.1 은 0.025배, Opus 5.5 는 0.05배 — Anthropic 가격표 2026-09-28).
    private static func anthropic(_ model: String, provider: AgentProvider = .claude,
                                  input: Double, output: Double, cacheRead: Double? = nil,
                                  source: String = anthropicSource) -> PriceEntry {
        price(provider, model, input: input, output: output,
              cacheRead: cacheRead ?? input * 0.1, cacheWrite: input * 1.25, source: source)
    }

    private static func openAI(_ model: String, input: Double, output: Double,
                               cacheRead: Double, cacheWrite: Double) -> PriceEntry {
        price(.codex, model, input: input, output: output,
              cacheRead: cacheRead, cacheWrite: cacheWrite, source: openAISource)
    }

    private static func gemini(_ model: String, input: Double, output: Double,
                               cacheRead: Double) -> PriceEntry {
        // 별도 캐시 쓰기 토큰 단가는 공개되지 않는다. 입력 처리 단가로 보수적으로 환산한다.
        price(.gemini, model, input: input, output: output,
              cacheRead: cacheRead, cacheWrite: input, source: googleSource)
    }

    private static func price(_ provider: AgentProvider, _ model: String,
                              input: Double, output: Double,
                              cacheRead: Double, cacheWrite: Double,
                              source: String) -> PriceEntry {
        PriceEntry(id: "\(version)|\(provider.rawValue)|\(model)", provider: provider, model: model,
                   inputPerMTok: input, outputPerMTok: output,
                   cacheReadPerMTok: cacheRead, cacheWritePerMTok: cacheWrite,
                   source: source, effectiveDate: effectiveDate, catalogVersion: version)
    }

    static let seed: [PriceEntry] = [
        // Claude Code / Anthropic API 환산
        anthropic("claude-opus-5-5",   input: 4.00,  output: 20.00, cacheRead: 0.20),
        anthropic("claude-opus-5",     input: 5.00,  output: 25.00),
        anthropic("claude-opus-4-8",   input: 5.00,  output: 25.00),
        anthropic("claude-opus-4-7",   input: 5.00,  output: 25.00),
        anthropic("claude-opus-4-6",   input: 5.00,  output: 25.00),
        anthropic("claude-sonnet-5",   input: 2.00,  output: 10.00),
        anthropic("claude-sonnet-4-6", input: 3.00,  output: 15.00),
        anthropic("claude-haiku-4-5",  input: 1.00,  output: 5.00),
        anthropic("claude-fable-5",    input: 10.00, output: 50.00),
        anthropic("claude-fable-5-1",  input: 10.00, output: 50.00, cacheRead: 0.25),

        // Codex가 현재 노출하는 OpenAI 모델
        openAI("gpt-6-astra",   input: 10.00, output: 50.00, cacheRead: 1.00, cacheWrite: 12.50),
        openAI("gpt-6-sol",     input: 2.00,  output: 10.00, cacheRead: 0.20, cacheWrite: 2.50),
        openAI("gpt-6-luna",    input: 0.10,  output: 0.50,  cacheRead: 0.01, cacheWrite: 0.125),
        openAI("gpt-5.6-sol",   input: 4.00,  output: 20.00, cacheRead: 0.40, cacheWrite: 5.00),
        openAI("gpt-5.6-terra", input: 2.00,  output: 12.00, cacheRead: 0.20, cacheWrite: 2.50),
        openAI("gpt-5.6-luna",  input: 0.20,  output: 1.20,  cacheRead: 0.02, cacheWrite: 0.25),
        openAI("gpt-5.5",       input: 5.00,  output: 30.00, cacheRead: 0.50, cacheWrite: 6.25),

        // Antigravity의 Gemini 계열(강도 접미사를 떼어 낸 제품군 이름)
        gemini("gemini-3.8-flash", input: 0.75, output: 3.75, cacheRead: 0.075),
        gemini("gemini-3.7-flash", input: 0.75, output: 3.75, cacheRead: 0.075),
        gemini("gemini-3.6-flash", input: 0.75, output: 3.75, cacheRead: 0.075),
        gemini("gemini-3.1-pro",   input: 2.00, output: 12.00, cacheRead: 0.20),

        // Antigravity가 함께 노출하는 Claude 모델
        anthropic("claude-sonnet-4-6", provider: .gemini, input: 3.00, output: 15.00,
                  source: antigravityClaudeSource),
        anthropic("claude-opus-4-6-thinking", provider: .gemini, input: 5.00, output: 25.00,
                  source: antigravityClaudeSource),
    ]

    // MARK: 사람이 넣는 가격 (설정 > 고급 > 가격표)

    /// 사람이 넣은 가격의 가격표 버전 머리 ("user-2026-10-04"). 공개 가격보다 먼저 쓰이고(`CostCalculator.preferred`),
    /// 가격표 시드를 갈 때도 지우지 않는다 (`Store.seedPriceCatalogIfNeeded`). 고치고 지울 수 있는 것은 이 줄뿐이다.
    static let userVersionPrefix = "user-"

    /// 사람이 적은 $/M 가격을 읽는다. "1.25" 와 소수점 쉼표 "1,25"(쉼표 하나 · 마침표 없음)를 받고, 앞의 "$" 는 뗀다.
    /// 음수 · 숫자가 아닌 것은 nil — 화면은 [추가]를 끄고 까닭을 적는다 (예전에는 말없이 꺼졌다 — set-18).
    static func parsePrice(_ text: String) -> Double? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("$") { value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces) }
        guard !value.isEmpty else { return nil }
        if !value.contains("."), value.filter({ $0 == "," }).count == 1 {
            value = value.replacingOccurrences(of: ",", with: ".")
        }
        guard let number = Double(value), number.isFinite, number >= 0 else { return nil }
        return number
    }

    /// 직접 넣는 가격 칸의 문제 — 없으면 nil. 화면은 [추가]를 끄고 이 글을 보인다.
    static func userEntryProblem(model: String, input: String, output: String) -> String? {
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "모델 이름을 적으세요." }
        if parsePrice(input) == nil { return "입력 가격을 숫자로 적으세요 (예: 1.25)." }
        if parsePrice(output) == nil { return "출력 가격을 숫자로 적으세요 (예: 10)." }
        return nil
    }

    /// 사람이 넣는 가격 한 줄. 캐시 읽기는 입력 가격의 0.1배, 캐시 쓰기는 1.25배로 셈한다 (Anthropic 공개 가격표의 기본 배율 —
    /// 모델마다 다를 수 있다).
    static func userEntry(provider: AgentProvider, model: String, input: Double, output: Double,
                          today: String) -> PriceEntry {
        PriceEntry(provider: provider, model: model.trimmingCharacters(in: .whitespacesAndNewlines),
                   inputPerMTok: input, outputPerMTok: output,
                   cacheReadPerMTok: input * 0.1, cacheWritePerMTok: input * 1.25,
                   source: "사용자 직접 입력", effectiveDate: today, catalogVersion: userVersionPrefix + today)
    }

    /// 긴 컨텍스트 요청에 공식 가격표의 계층 단가를 적용한다.
    static func multipliers(provider: AgentProvider, model: String,
                            promptTokens: Int) -> (input: Double, output: Double) {
        if provider == .codex,
           ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"]
            .contains(where: { model.hasPrefix($0) }),
           promptTokens > 272_000 {
            return (2.0, 1.5)
        }
        if provider == .gemini, model.hasPrefix("gemini-3.1-pro"), promptTokens > 200_000 {
            return (2.0, 1.5)
        }
        return (1.0, 1.0)
    }
}

extension PriceEntry {
    /// 설정의 가격표에서 사람이 넣은 줄인가 — 고치고 지울 수 있다 (앱이 넣은 공개 가격은 그대로).
    var isUserEntered: Bool { catalogVersion.hasPrefix(PriceCatalog.userVersionPrefix) }
}

/// 사용량 → API 환산 비용.
struct CostCalculator {
    let entries: [PriceEntry]

    /// 날짜나 강도 접미사가 붙은 이름도 가장 긴 제품군 접두사로 매칭한다.
    private func entry(for provider: AgentProvider, model: String?) -> PriceEntry? {
        guard let model, !model.isEmpty else { return nil }
        let candidates = entries.filter { $0.provider == provider }
        let exact = candidates.filter { $0.model == model }
        if !exact.isEmpty { return preferred(exact) }
        let prefixes = candidates.filter { model.hasPrefix($0.model) }
        guard let longest = prefixes.map(\.model.count).max() else { return nil }
        return preferred(prefixes.filter { $0.model.count == longest })
    }

    /// 사용자가 직접 넣은 값이 기본 가격표보다 우선하고, 그 안에서는 최신 적용일을 쓴다.
    private func preferred(_ candidates: [PriceEntry]) -> PriceEntry? {
        candidates.max { lhs, rhs in
            let lhsUser = lhs.isUserEntered
            let rhsUser = rhs.isUserEntered
            if lhsUser != rhsUser { return !lhsUser && rhsUser }
            if lhs.effectiveDate != rhs.effectiveDate { return lhs.effectiveDate < rhs.effectiveDate }
            return lhs.catalogVersion < rhs.catalogVersion
        }
    }

    /// 앱이 직접 계산한 비용. 가격을 모르면 nil (= 금액 미확인).
    /// reasoningTokens는 outputTokens의 부분집합이므로 따로 더하지 않는다.
    func calculate(provider: AgentProvider, model: String?, usage: UsageRecord) -> (Double, String)? {
        guard let e = entry(for: provider, model: model) else { return nil }
        let promptTokens = usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens
        let multiplier = PriceCatalog.multipliers(
            provider: provider, model: model ?? e.model, promptTokens: promptTokens)
        let cost =
            Double(usage.inputTokens)      / 1_000_000 * e.inputPerMTok * multiplier.input +
            Double(usage.cacheReadTokens)  / 1_000_000 * e.cacheReadPerMTok * multiplier.input +
            Double(usage.cacheWriteTokens) / 1_000_000 * e.cacheWritePerMTok * multiplier.input +
            Double(usage.outputTokens)     / 1_000_000 * e.outputPerMTok * multiplier.output
        return (cost, e.catalogVersion)
    }

    /// 인계 텍스트의 토큰 추정치. 실제 청구 근거가 아니라 참고용 추정이다.
    static func roughTokenEstimate(_ text: String) -> Int {
        max(1, text.count / 3)
    }
}

/// 여러 사용량 레코드의 합계. 누락된 턴 수를 함께 보고한다.
struct UsageAggregate {
    var inputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var outputTokens = 0
    var totalCostUSD: Double = 0
    var costUnknownTurns = 0
    var unconfirmedTurns = 0
    var turns = 0

    var totalTokens: Int { inputTokens + cacheReadTokens + cacheWriteTokens + outputTokens }
    var knownCostTurns: Int { turns - costUnknownTurns }
    var displayCostUSD: Double? { knownCostTurns > 0 ? totalCostUSD : nil }

    static func from(_ records: [UsageRecord]) -> UsageAggregate {
        var agg = UsageAggregate()
        for r in records {
            agg.turns += 1
            agg.inputTokens += r.inputTokens
            agg.cacheReadTokens += r.cacheReadTokens
            agg.cacheWriteTokens += r.cacheWriteTokens
            agg.outputTokens += r.outputTokens
            if let c = r.costUSD, r.costSource != .unknown {
                agg.totalCostUSD += c
            } else {
                agg.costUnknownTurns += 1
            }
            if !r.confirmed { agg.unconfirmedTurns += 1 }
        }
        return agg
    }
}
