import Foundation

/// 설치된 CLI 에서 실제 모델 목록을 조회한다.
///
/// 원칙: 실행에 넘기는 모델 식별자는 CLI가 제공한 값만 쓴다.
/// Claude의 알려진 별칭에는 화면에서 읽기 쉬운 버전과 설명을 붙인다.
/// - Codex: `model/list` (app-server) — id, 표시 이름, 설명, 지원 추론 강도까지 제공한다.
/// - Claude: `claude -p /model --output-format json` — `result` 텍스트에서 별칭 목록을 읽는다.
/// 조회에 실패하면 목록을 비우지 않고 **대체 목록(isDiscovered = false)** 을 쓰되,
/// 그 사실을 사용자에게 표시한다.
enum ModelCatalog {

    /// Claude Code 의 `--effort` 선택지 — CLI 도움말의 다섯(low · medium · high · xhigh · max) + 맨 끝의 ULTRA(`ultracode`).
    /// Codex 의 ultra 와 같은 자리(맨 끝 · ULTRA)에 둔다 (사용자 결정 2026-10-07 — 두 에이전트의 강도 목록을 맞춘다).
    static let claudeEfforts = ["low", "medium", "high", "xhigh", "max", claudeUltracode]

    /// Claude 의 ULTRA. 도움말에 없는 `--effort` 별칭이다 — 강도는 Extra High(xhigh)로 두고, 그 세션에 ultracode(일을 여러
    /// 에이전트에게 나눠 맡기는 워크플로)를 켠다. MAX 보다 깊게 추론하는 단계가 아니어서 화면은 그 사실을 안내로 말한다
    /// (`EffortScale.rowNote` · `rowHelp`). 2.1.292 실측(비용 0): `claude -p --effort ultracode /model` → "(effort: xhigh)",
    /// 모르는 값(`bogus`)과 달리 경고 없이 받는다. ultracode 가 실제로 켜졌는지는 모델을 부르지 않고는 확인하지 못했다.
    static let claudeUltracode = "ultracode"

    /// 설정 > 에이전트의 Claude 기본 추론 강도 — ULTRA 는 새 대화마다 켜지면 안 되어 뺀다.
    static let claudeDefaultChoices = claudeEfforts.filter { $0 != claudeUltracode }

    /// Antigravity(`agy models`) 의 강도 값. 슬러그 접미사에서 실제로 발견된 것만 쓴다.
    static let antigravityEfforts = ["low", "medium", "high"]

    // MARK: - Antigravity (Gemini)

    /// `agy models` → `<슬러그>\t<표시 이름>` 목록.
    /// 슬러그에 강도가 붙어 있으므로(`gemini-3.8-flash-high`) **제품군 + 강도**로 나눠 보여준다.
    /// CLI 는 둘을 섞어 주면 거부하므로 어댑터가 하나만 넘긴다.
    static func fetchGemini(path: String, environment: [String: String],
                            timeout: TimeInterval = 45) async -> ModelCatalogSnapshot {
        var snapshot = ModelCatalogSnapshot(provider: .gemini)
        snapshot.fetchedAt = Date()
        let result = await CLIEnvironment.captureOutput(
            executable: path, arguments: ["models"], environment: environment, timeout: timeout)
        switch result {
        case .failure(let message):
            snapshot.options = []
            snapshot.discovered = false
            snapshot.message = "모델 목록 조회 실패: \(JSONUtil.truncate(message, max: 300))"
            return snapshot
        case .success(let raw):
            return parseGeminiModelResponse(raw, into: snapshot)
        }
    }

    static func parseGeminiModelResponse(_ raw: String,
                                         into base: ModelCatalogSnapshot) -> ModelCatalogSnapshot {
        var snapshot = base
        var order: [String] = []
        var efforts: [String: [String]] = [:]
        var names: [String: String] = [:]

        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let slug = parts.first, !slug.isEmpty,
                  slug.range(of: "^[a-z0-9][a-z0-9._-]+$", options: .regularExpression) != nil
            else { continue }
            let display = parts.count > 1 ? parts[1] : slug
            let (family, effort) = splitEffort(slug)
            if efforts[family] == nil {
                order.append(family)
                efforts[family] = []
                // "Gemini 3.8 Flash (High)" → "Gemini 3.8 Flash"
                names[family] = display.replacingOccurrences(
                    of: #"\s*\((?i:low|medium|high)\)\s*$"#, with: "", options: .regularExpression)
            }
            if let effort, !efforts[family]!.contains(effort) { efforts[family]?.append(effort) }
        }

        snapshot.options = order.map { family in
            let found = antigravityEfforts.filter { efforts[family]?.contains($0) == true }
            return AgentModelOption(
                provider: .gemini, identifier: family, displayName: names[family] ?? family,
                detail: nil,
                // boost 는 CLI 강도가 아니라 슬래시 명령이다. 강도 목록 끝의 ULTRA(= High + /boost)로만 보여준다.
                supportedEfforts: found + (antigravityTakesUltra(found) ? [AntigravityAdapter.boostEffort] : []),
                // 앱 기본 강도 (AntigravityAdapter.defaultEffort) — High 가 없는 모델에는 기본값이 없다.
                defaultEffort: found.contains(AntigravityAdapter.defaultEffort) ? AntigravityAdapter.defaultEffort : nil)
        }
        snapshot.discovered = !snapshot.options.isEmpty
        if snapshot.options.isEmpty { snapshot.message = "모델 목록을 해석하지 못했습니다." }
        return snapshot
    }

    /// "gemini-3.8-flash-high" → ("gemini-3.8-flash", "high"). 강도가 없으면 (슬러그, nil).
    static func splitEffort(_ slug: String) -> (family: String, effort: String?) {
        for effort in antigravityEfforts where slug.hasSuffix("-" + effort) {
            return (String(slug.dropLast(effort.count + 1)), effort)
        }
        return (slug, nil)
    }

    /// ULTRA(= High + `/boost`)를 둘 수 있는 모델 — High 를 받거나(실측: 제품군 + `--effort high` + `/boost`),
    /// 강도 변형이 없는 모델(실측: `--model claude-sonnet-4-6` + `/boost`). High 없이 다른 강도만 있으면 두지 않는다.
    static func antigravityTakesUltra(_ cliEfforts: [String]) -> Bool {
        cliEfforts.isEmpty || cliEfforts.contains(AntigravityAdapter.defaultEffort)
    }

    /// Antigravity 앱 기본 모델 (사용자 결정 2026-09-14: "모델도 기본은 3.8flash"). 이름을 코드에 고정하지 않고
    /// 요약 기본 모델(`GeminiAssistService.defaultSummaryModel`)과 같은 규칙으로 목록에서 **가장 최신 Flash 제품군** 을 고른다 —
    /// 기본 강도 High 와 함께 쓰므로 High 를 받는 것만. 2026-09-14 목록에서는 `gemini-3.8-flash`.
    static func antigravityDefaultOption(in options: [AgentModelOption]) -> AgentModelOption? {
        options.filter { option in
            option.provider == .gemini && option.isDiscovered
                && option.identifier.hasPrefix("gemini-") && option.identifier.hasSuffix("-flash")
                && option.supportedEfforts.contains(AntigravityAdapter.defaultEffort)
        }
        .max { GeminiAssistService.versionKey($0.identifier).lexicographicallyPrecedes(
            GeminiAssistService.versionKey($1.identifier)) }
    }

    // MARK: - Claude

    /// 별칭 목록과 별칭마다의 이름을 함께 묻는다 (`claude -p` 다섯 — 검증 하네스의 실측용). 앱은 목록(`fetchClaudeList`)을 먼저
    /// 받아 보이고, 이름(`fetchClaudeNames`)은 CLI 버전이 바뀌었을 때만 따로 묻는다 (`AppModel.refreshModelCatalog`).
    static func fetchClaude(path: String, environment: [String: String],
                            timeout: TimeInterval = 90) async -> ModelCatalogSnapshot {
        async let named = fetchClaudeNames(claudeNamedAliases, path: path, environment: environment)
        async let listed = fetchClaudeList(path: path, environment: environment, timeout: timeout)
        let (names, snapshot) = await (named, listed)
        guard snapshot.discovered else { return snapshot }
        var updated = snapshot
        updated.options = applyingClaudeNames(names, to: snapshot.options)
        return updated
    }

    /// 별칭 목록만 묻는다 (`claude -p /model` 하나). `names` 는 받아 둔 별칭 이름 — 없는 별칭은 `claudePresentation` 의 이름.
    static func fetchClaudeList(path: String, environment: [String: String], timeout: TimeInterval = 90,
                                names: [String: String] = [:]) async -> ModelCatalogSnapshot {
        var snapshot = ModelCatalogSnapshot(provider: .claude)
        snapshot.fetchedAt = Date()
        let result = await CLIEnvironment.captureClaudePrint(path: path, command: "/model", environment: environment,
                                                             timeout: timeout)
        switch result {
        case .failure(let message):
            snapshot.options = claudeFallback()
            snapshot.discovered = false
            snapshot.message = "모델 목록 조회 실패: \(JSONUtil.truncate(message, max: 300))"
            return snapshot
        case .success(let raw):
            return parseClaudeModelResponse(raw, into: snapshot, names: names)
        }
    }

    /// 받아 온 별칭 이름을 목록에 입힌다 (긴 문맥 별칭은 바탕 이름 + " · 1M"). 이름이 없는 별칭은 그대로.
    static func applyingClaudeNames(_ names: [String: String], to options: [AgentModelOption]) -> [AgentModelOption] {
        options.map { option in
            guard option.provider == .claude, let name = claudeDisplayName(option.identifier, names: names) else { return option }
            var named = option
            named.displayName = name
            return named
        }
    }

    /// CLI 에 이름을 묻는 별칭. `best` · `opusplan` 은 모델 하나가 아니라 이름을 두지 않는다.
    static let claudeNamedAliases = ["fable", "opus", "sonnet", "haiku"]

    /// 별칭마다 지금 가리키는 모델의 이름 — `claude -p --model <별칭> /model` 은 API 를 부르지 않고(비용 0) 기본 설정도
    /// 바꾸지 않은 채 `Current model: \`Opus 5.5\`` 를 준다 (2.1.283 실측). 별칭이 CLI 업데이트로 새 모델을 가리키면 이름도
    /// 따라 바뀐다. 답하지 않거나 별칭과 맞지 않는 이름은 버린다.
    static func fetchClaudeNames(_ aliases: [String], path: String, environment: [String: String],
                                 timeout: TimeInterval = 30) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
            for alias in aliases {
                group.addTask {
                    let result = await CLIEnvironment.captureClaudePrint(path: path, command: "/model", model: alias,
                                                                         environment: environment, timeout: timeout)
                    guard case .success(let raw) = result,
                          let obj = JSONUtil.object(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                          let text = obj["result"] as? String else { return (alias, nil) }
                    return (alias, claudeModelName(from: text, alias: alias))
                }
            }
            var names: [String: String] = [:]
            for await (alias, name) in group { if let name { names[alias] = name } }
            return names
        }
    }

    /// "Current model: `Opus 5.5`" · "Current model: `Opus 5` (effort: high)" → 백틱 안의 이름. "(1M context)" 는 뗀다.
    /// `alias` 를 주면 그 별칭의 이름이 맞을 때만 (`opus` → "Opus …").
    static func claudeModelName(from text: String, alias: String? = nil) -> String? {
        guard let range = text.range(of: "Current model:", options: .caseInsensitive) else { return nil }
        let tail = text[range.upperBound...]
        guard let open = tail.firstIndex(of: "`"),
              let close = tail[tail.index(after: open)...].firstIndex(of: "`") else { return nil }
        let name = tail[tail.index(after: open)..<close]
            .replacingOccurrences(of: #"\s*\(1M context\)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if let alias, !name.lowercased().contains(alias.lowercased()) { return nil }
        return name
    }

    /// `names` 는 별칭 → CLI 가 알려 준 이름 (`fetchClaudeNames`). 없는 별칭은 `claudePresentation` 의 이름.
    static func parseClaudeModelResponse(_ raw: String, into base: ModelCatalogSnapshot,
                                         names displayNames: [String: String] = [:]) -> ModelCatalogSnapshot {
        var snapshot = base
        guard let obj = JSONUtil.object(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let text = obj["result"] as? String else {
            snapshot.options = claudeFallback()
            snapshot.discovered = false
            snapshot.message = "모델 목록 응답 형식을 해석하지 못했습니다."
            return snapshot
        }

        let current = currentClaudeModel(from: text)
        let names = availableClaudeNames(from: text)

        guard !names.isEmpty else {
            snapshot.options = claudeFallback(current: current)
            snapshot.discovered = false
            snapshot.message = "모델 목록 형식이 바뀐 것 같습니다. 원문: "
                + JSONUtil.truncate(text, max: 200)
            return snapshot
        }

        snapshot.options = claudeOptions(names, current: current, discovered: true, displayNames: displayNames)
        snapshot.discovered = true
        if let current {
            snapshot.message = "CLI 현재 설정: \(current)"
        }
        return snapshot
    }

    /// "Available: sonnet, opus, haiku, …, or a full model ID." 에서 이름만 뽑는다.
    static func availableClaudeNames(from text: String) -> [String] {
        guard let range = text.range(of: "Available:", options: .caseInsensitive) else { return [] }
        var tail = String(text[range.upperBound...])
        if let stop = tail.firstIndex(of: "\n") { tail = String(tail[..<stop]) }
        return tail
            .replacingOccurrences(of: ".", with: "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { candidate in
                guard !candidate.isEmpty else { return false }
                let lower = candidate.lowercased()
                // "or a full model ID" 같은 설명 문구는 제외한다.
                if lower.hasPrefix("or ") || lower.contains("full model") { return false }
                return !candidate.contains(" ")
            }
    }

    /// "Current model: `Opus 5` (effort: high)" 형태에서 현재 설정을 읽는다.
    static func currentClaudeModel(from text: String) -> String? {
        guard let range = text.range(of: "Current model:", options: .caseInsensitive) else {
            return nil
        }
        var tail = String(text[range.upperBound...])
        if let stop = tail.firstIndex(of: "\n") { tail = String(tail[..<stop]) }
        let cleaned = tail.replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 조회 실패 시 대체 목록. CLI 도움말에 나온 별칭만 쓴다.
    static func claudeFallback(current: String? = nil) -> [AgentModelOption] {
        claudeOptions(["fable", "opus", "sonnet", "haiku", "best", "opusplan"],
                      current: current, discovered: false)
    }

    /// 저장된 목록에도 최신 표시 방식이 적용되게 한다. 모델 ID와 지원 강도는 그대로 둔다.
    static func presentableOptions(_ options: [AgentModelOption]) -> [AgentModelOption] {
        // Codex CLI 0.157 카탈로그의 priority 순서.
        let codexOrder = ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna",
                          "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"]
        let normalized = options.filter { $0.identifier != "default" }.map { option in
            var updated = option
            switch option.provider {
            case .claude:
                let (name, detail) = claudePresentation(option.identifier)
                // CLI 가 알려 준 이름(`fetchClaudeNames`)은 그대로 둔다. 별칭 그대로 저장된 옛 캐시만 코드의 이름으로.
                if option.displayName.isEmpty || option.displayName == option.identifier { updated.displayName = name }
                updated.detail = detail
                // Claude 의 강도는 CLI 가 아니라 앱의 목록(`claudeEfforts`)이다 — ULTRA 를 더하기 전에 저장된 목록에도 지금 목록을.
                if !option.supportedEfforts.isEmpty { updated.supportedEfforts = claudeEfforts }
            case .codex:
                updated.detail = codexDescription(option.identifier) ?? option.detail
            case .gemini:
                updated.detail = nil
                // 하루 동안 캐시된 옛 목록은 High 가 없는 모델에도 boost 를 두었다 — 지금 규칙(`antigravityTakesUltra`)으로 거른다.
                let cli = option.supportedEfforts.filter { antigravityEfforts.contains($0) }
                if !antigravityTakesUltra(cli) {
                    updated.supportedEfforts.removeAll { $0 == AntigravityAdapter.boostEffort }
                }
            }
            return updated
        }
        guard options.first?.provider == .codex else { return normalized }
        return normalized.enumerated().sorted { lhs, rhs in
            let left = codexOrder.firstIndex(of: lhs.element.identifier) ?? codexOrder.count
            let right = codexOrder.firstIndex(of: rhs.element.identifier) ?? codexOrder.count
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// OpenAI 모델 문서와 현재 Codex CLI의 용도 설명을 짧게 옮긴다.
    private static func codexDescription(_ identifier: String) -> String? {
        switch identifier {
        case "gpt-6-astra": return "가장 어려운 복합 작업을 위한 최고 성능 모델"
        case "gpt-6-sol": return "코딩·일상 작업용 주력 모델"
        case "gpt-6-luna": return "쉬운 작업을 빠르고 저렴하게"
        case "gpt-5.6-sol": return "복잡한 코딩용 이전 세대 모델"
        case "gpt-5.6-terra": return "균형형 이전 세대 모델"
        case "gpt-5.6-luna": return "빠르고 경제적인 이전 세대 모델"
        case "gpt-5.5": return "코딩용 구형 모델"
        default: return nil
        }
    }

    // MARK: - Codex 계열 (새 버전 따라가기)
    //
    // Codex 에는 Claude 의 `opus` 같은 별칭이 없다 — `model/list` 는 `gpt-6-sol` 같은 구체적인 ID 만 준다 (0.157.1 실측).
    // 그래서 앱이 이름 규칙 `gpt-<버전>-<계열>` 로 계열을 알아본다. 계열의 최신 모델을 고르면 **계열 선택**(`gpt-*-sol`)으로
    // 저장해, 새 버전(`gpt-7-sol`)이 목록에 나오면 따라간다. 옛 버전을 고르면 그 ID 로 고정한다. 계열 선택은 CLI 에 넘기지 않는다 —
    // 보낼 때 · 화면에 보일 때 지금 목록으로 푼다 (`resolveModel`). 화면에는 늘 푼 모델의 정확한 이름이 보인다.

    private static let codexFamilyWildcard = "gpt-*-"

    /// `gpt-6-sol` → ("sol", [6]), `gpt-5.6-luna` → ("luna", [5, 6]). 규칙에 맞지 않으면(`gpt-5.5` 등) nil.
    static func codexFamily(of identifier: String) -> (family: String, version: [Int])? {
        let parts = identifier.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "gpt",
              parts[1].range(of: #"^[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil,
              parts[2].range(of: "^[a-z]+$", options: .regularExpression) != nil else { return nil }
        return (String(parts[2]), parts[1].split(separator: ".").compactMap { Int($0) })
    }

    /// 계열 선택의 계열 이름. `gpt-*-sol` → "sol". 계열 선택이 아니면 nil.
    static func familyOfSelection(_ model: String?) -> String? {
        guard let model, model.hasPrefix(codexFamilyWildcard) else { return nil }
        let family = String(model.dropFirst(codexFamilyWildcard.count))
        return family.range(of: "^[a-z]+$", options: .regularExpression) != nil ? family : nil
    }

    /// 목록에서 그 계열의 가장 높은 버전.
    static func latestModel(family: String, in options: [AgentModelOption]) -> AgentModelOption? {
        options.compactMap { option in codexFamily(of: option.identifier).map { (option, $0) } }
            .filter { $0.1.family == family }
            .max { $0.1.version.lexicographicallyPrecedes($1.1.version) }?.0
    }

    /// 선택 값 → CLI 에 넘길 모델 ID. 계열 선택이 아니면 그대로, 계열 선택인데 목록에 그 계열이 없으면 nil.
    static func resolveModel(_ model: String?, in options: [AgentModelOption]) -> String? {
        guard let family = familyOfSelection(model) else { return model }
        return latestModel(family: family, in: options)?.identifier
    }

    /// 이 모델이 자기 계열의 최신인가 — 고르면 새 버전을 따라간다.
    static func followsNewerVersions(_ option: AgentModelOption, in options: [AgentModelOption]) -> Bool {
        guard let family = codexFamily(of: option.identifier)?.family else { return false }
        return latestModel(family: family, in: options)?.identifier == option.identifier
    }

    /// 목록에서 모델을 골랐을 때 저장할 값 — 계열의 최신이면 계열 선택, 아니면 그 ID.
    static func selectionValue(for option: AgentModelOption, in options: [AgentModelOption]) -> String {
        guard followsNewerVersions(option, in: options), let family = codexFamily(of: option.identifier)?.family else {
            return option.identifier
        }
        return codexFamilyWildcard + family
    }

    // MARK: 긴 문맥(1M) 별칭

    /// Claude 의 긴 문맥 별칭은 바탕 별칭 뒤에 이것이 붙어 따로 온다 (`opus` · `opus[1m]`).
    static let longContextSuffix = "[1m]"

    static func isLongContext(_ option: AgentModelOption) -> Bool {
        option.identifier.hasSuffix(longContextSuffix)
    }

    /// 모델 목록이 행으로 보일 모델 — 바탕이 목록에 있는 긴 문맥 별칭은 빼고, 그 바탕 행 + "긴 문맥" 스위치로 고른다.
    /// 바탕이 목록에 없는 긴 문맥 별칭은 그대로 한 행이다. 순서는 목록 그대로.
    static func baseOptions(_ options: [AgentModelOption]) -> [AgentModelOption] {
        let identifiers = Set(options.map(\.identifier))
        return options.filter { option in
            !(isLongContext(option) && identifiers.contains(String(option.identifier.dropLast(longContextSuffix.count))))
        }
    }

    /// 바탕 모델의 긴 문맥 별칭 (목록에 있을 때만).
    static func longContextVariant(of base: AgentModelOption, in options: [AgentModelOption]) -> AgentModelOption? {
        guard !isLongContext(base) else { return nil }
        return options.first { $0.identifier == base.identifier + longContextSuffix && $0.provider == base.provider }
    }

    /// 모델 목록에서 이 모델이 속한 행 — 긴 문맥 별칭이면 그 바탕(목록에 있을 때), 아니면 그대로.
    static func baseOption(of option: AgentModelOption, in options: [AgentModelOption]) -> AgentModelOption {
        guard isLongContext(option) else { return option }
        let base = String(option.identifier.dropLast(longContextSuffix.count))
        return options.first { $0.identifier == base && $0.provider == option.provider } ?? option
    }

    /// 긴 문맥 별칭이 있는 바탕 모델들 (스위치 설명의 "Fable · Opus · Sonnet 에서" 에 쓴다). 순서는 목록 그대로.
    static func longContextBases(_ options: [AgentModelOption]) -> [AgentModelOption] {
        baseOptions(options).filter { longContextVariant(of: $0, in: options) != nil }
    }

    /// 선택 값에 맞는 목록 행 (계열 선택은 지금의 최신). 없으면 nil.
    static func option(for model: String?, in options: [AgentModelOption]) -> AgentModelOption? {
        guard let id = resolveModel(model, in: options) else { return nil }
        return options.first { $0.identifier == id }
    }

    /// 실행 · 사용량에 남은 모델 ID(또는 고른 값)를 사람이 읽는 이름으로 — 턴 머리줄. 목록에 있으면 목록의 이름
    /// ("gpt-5.6-sol" → "GPT-5.6 Sol", 별칭 "opus" → "Opus 5.5"), Claude 전체 ID 는 이름 규칙으로 ("claude-opus-5-5" → "Opus 5.5").
    /// 모르면 받은 그대로 둔다 (지어내지 않는다).
    static func runModelName(_ model: String, catalog: [AgentModelOption]) -> String {
        if let option = option(for: model, in: catalog) { return option.displayName }
        return claudeModelName(model) ?? model
    }

    /// Claude 전체 모델 ID 의 이름: `claude-<계열>-<주>[-<부>][-<날짜 8자리>][[1m]]` → "Opus 5.5" · "Haiku 4.5" ·
    /// "Sonnet 5 · 1M". 계열이 fable · opus · sonnet · haiku 가 아니거나 모양이 다르면 nil.
    static func claudeModelName(_ id: String) -> String? {
        var rest = id.lowercased()
        let longContext = rest.hasSuffix("[1m]")
        if longContext { rest = String(rest.dropLast(4)) }
        guard rest.hasPrefix("claude-") else { return nil }
        var parts = rest.dropFirst("claude-".count).split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, ["fable", "opus", "sonnet", "haiku"].contains(parts[0]),
              parts[1].count <= 2, let major = Int(parts[1]) else { return nil }
        let family = parts[0]
        parts.removeFirst(2)
        var version = String(major)
        if let minor = parts.first, minor.count <= 2, let value = Int(minor) {
            version += ".\(value)"
            parts.removeFirst()
        }
        // 남는 것은 날짜(20251001)뿐이어야 한다.
        guard parts.allSatisfy({ $0.count == 8 && Int($0) != nil }), parts.count <= 1 else { return nil }
        return family.prefix(1).uppercased() + family.dropFirst() + " " + version + (longContext ? " · 1M" : "")
    }

    /// 목록에서 풀지 못한 계열 선택을 화면에 보일 이름. `gpt-*-sol` → "Sol 최신 (목록에 없음)",
    /// 목록을 아직 못 받았으면(`listEmpty`) 없다고 단정하지 않고 "Sol 최신".
    static func unresolvedFamilyName(_ model: String?, listEmpty: Bool = false) -> String? {
        familyOfSelection(model).map {
            "\($0.prefix(1).uppercased() + $0.dropFirst()) 최신" + (listEmpty ? "" : " (목록에 없음)")
        }
    }

    /// 모델을 고르지 않은 스레드가 쓸 모델 — Claude · Codex 는 CLI 가 알려 준 현재 기본 모델,
    /// Antigravity 는 `agy models` 가 기본을 표시하지 않아(2026-09-14 실측) 앱 기본 모델 (`antigravityDefaultOption`).
    /// Claude 의 목록 형식을 읽지 못해 대체 목록을 쓸 때도, CLI 가 "Current model" 로 알려 준 별칭이 있으면 그것 (`claudeFallback(current:)`).
    static func preferredOption(in options: [AgentModelOption]) -> AgentModelOption? {
        let visible = presentableOptions(options)
        if visible.first?.provider == .gemini { return antigravityDefaultOption(in: visible) }
        if let discovered = visible.first(where: { $0.isDefault && $0.isDiscovered }) { return discovered }
        return visible.first { $0.provider == .claude && $0.isDefault }
    }

    /// 이어받을 것이 없을 때 고르지 않은 모델(nil)이 풀리는 기본 모델 — Codex 는 계정 홈의 config.toml `model` 이 목록에 있으면 그것,
    /// 아니면 CLI 기본(`preferredOption`). 사용자 결정 2026-10-04.
    static func defaultOption(in options: [AgentModelOption], configModel: String?) -> AgentModelOption? {
        let visible = presentableOptions(options)
        if let configModel, !configModel.isEmpty, let option = option(for: configModel, in: visible) { return option }
        return preferredOption(in: visible)
    }

    /// 기본 모델을 선택에 적을 값 — config.toml 의 모델은 그 ID 그대로(사람이 정해 둔 값), CLI 기본은 목록에서 고른 것과 같은 규칙
    /// (계열의 최신이면 계열 선택 — `selectionValue`). 풀지 못하면 nil.
    static func defaultSelectionValue(in options: [AgentModelOption], configModel: String?) -> String? {
        let visible = presentableOptions(options)
        if let configModel, !configModel.isEmpty, let option = option(for: configModel, in: visible) { return option.identifier }
        return preferredOption(in: visible).map { selectionValue(for: $0, in: visible) }
    }

    /// 가장 좁은 입력창의 모델 이름 — Codex 계열 모델은 계열 이름("GPT-6 Sol" → "Sol"), 그 밖은 표시 이름에서 버전 · 덧붙임을 뗀 것
    /// ("Opus 5.5 · 1M" → "Opus", "Gemini 3.8 Flash" → "Gemini Flash"). 남는 것이 없으면 표시 이름 그대로.
    static func shortName(of option: AgentModelOption) -> String {
        if option.provider == .codex, let family = codexFamily(of: option.identifier)?.family {
            return family.prefix(1).uppercased() + family.dropFirst()
        }
        let head = option.displayName.components(separatedBy: " · ").first ?? option.displayName
        let words = head.split(separator: " ").filter { $0.range(of: #"^v?[0-9][0-9.]*$"#, options: .regularExpression) == nil }
        return words.isEmpty ? option.displayName : words.joined(separator: " ")
    }

    private static func claudeOptions(_ names: [String], current: String?, discovered: Bool,
                                      displayNames: [String: String] = [:]) -> [AgentModelOption] {
        let priority = ["fable", "opus", "sonnet", "haiku"]
        let ordered = names.filter { $0 != "default" }.enumerated().sorted { lhs, rhs in
            let left = priority.firstIndex(of: lhs.element) ?? priority.count
            let right = priority.firstIndex(of: rhs.element) ?? priority.count
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
        let currentAlias = priority.first { current?.lowercased().contains($0) == true }
        return ordered.map { identifier in
            let (fallback, detail) = claudePresentation(identifier)
            return AgentModelOption(provider: .claude, identifier: identifier,
                                    displayName: claudeDisplayName(identifier, names: displayNames) ?? fallback,
                                    detail: detail,
                                    supportedEfforts: claudeEfforts,
                                    defaultEffort: nil,
                                    isDefault: identifier == currentAlias,
                                    isDiscovered: discovered)
        }
    }

    /// CLI 가 알려 준 이름 — 긴 문맥 별칭(`opus[1m]`)은 바탕 별칭의 이름 + " · 1M". 모르면 nil.
    static func claudeDisplayName(_ identifier: String, names: [String: String]) -> String? {
        if let name = names[identifier] { return name }
        guard identifier.hasSuffix("[1m]"), let base = names[String(identifier.dropLast(4))] else { return nil }
        return base + " · 1M"
    }

    /// CLI 에서 이름을 받지 못했을 때의 이름 · 설명. 설명은 늘 여기 것을 쓴다 (CLI 는 설명을 주지 않는다).
    private static func claudePresentation(_ identifier: String) -> (String, String) {
        switch identifier {
        case "fable": return ("Fable 5.1", "가장 어려운 과제를 위해")
        // Claude Code 2.1.280 부터 `opus` 별칭이 Opus 5.5 다.
        case "opus": return ("Opus 5.5", "복잡한 작업용")
        case "sonnet": return ("Sonnet 5", "일상적인 작업에 가장 효율적")
        case "haiku": return ("Haiku 4.5", "가장 빠른 답변")
        case "fable[1m]": return ("Fable 5.1 · 1M", "가장 어려운 과제 · 긴 문맥")
        case "opus[1m]": return ("Opus 5.5 · 1M", "복잡한 작업 · 긴 문맥")
        case "sonnet[1m]": return ("Sonnet 5 · 1M", "일상적인 작업 · 긴 문맥")
        case "best": return ("Best", "Claude 가 모델을 자동으로 선택")
        case "opusplan": return ("Opus Plan", "계획은 Opus, 실행은 Sonnet")
        default: return (identifier, "Claude CLI 에서 제공하는 모델")
        }
    }

    // MARK: - Codex

    /// 모델 목록도 계정별로 다를 수 있다. 어느 계정인지는 `environment` 의 `CODEX_HOME` 이 정한다.
    static func fetchCodex(path: String, environment: [String: String],
                           accountID: String = "",
                           timeout: TimeInterval = 45) async -> ModelCatalogSnapshot {
        var snapshot = ModelCatalogSnapshot(provider: .codex, accountID: accountID)
        snapshot.fetchedAt = Date()

        let proc = ManagedProcess(executable: URL(fileURLWithPath: path),
                                  arguments: ["app-server", "--stdio"],
                                  workingDirectory: nil, environment: environment)
        let stream = proc.makeStream()
        proc.launch()

        let collected = UncheckedBox<[[String: Any]]?>(nil)
        let errorBox = UncheckedBox<String?>(nil)

        let reader = Task {
            for await out in stream {
                if case .stdoutLine(let line) = out, let obj = JSONUtil.object(line) {
                    let id = JSONUtil.int(obj["id"])
                    guard id == 2 else { continue }
                    if let err = obj["error"] as? [String: Any] {
                        errorBox.value = err["message"] as? String ?? "알 수 없는 오류"
                    } else if let result = obj["result"] as? [String: Any] {
                        collected.value = result["data"] as? [[String: Any]] ?? []
                    }
                    return
                }
                if case .stderrLine(let line) = out, errorBox.value == nil,
                   !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    errorBox.value = line
                }
            }
        }

        _ = proc.writeLine(JSONUtil.line([
            "method": "initialize",
            "params": ["clientInfo": ["name": "AgentHandoffConsole", "version": "0.1.0"]],
            "id": 1,
        ]) ?? "")
        _ = proc.writeLine(JSONUtil.line(["method": "initialized", "params": [:]]) ?? "")
        _ = proc.writeLine(JSONUtil.line(["method": "model/list", "params": [:], "id": 2]) ?? "")

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await reader.value }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            await group.next()
            // 그룹은 남은 자식을 모두 기다린다 — 읽기 작업부터 멈춰야 시간 제한이 듣는다 (프로세스는 그룹 뒤에 끈다).
            reader.cancel()
            group.cancelAll()
        }
        _ = await proc.shutdown()

        if let data = collected.value {
            snapshot.options = parseCodexModels(data)
            snapshot.discovered = !snapshot.options.isEmpty
            if snapshot.options.isEmpty {
                snapshot.message = "CLI 가 모델 목록을 비어 있게 반환했습니다."
            }
            return snapshot
        }
        snapshot.options = []
        snapshot.discovered = false
        snapshot.message = errorBox.value.map { "모델 목록 조회 실패: \(JSONUtil.truncate($0, max: 300))" }
            ?? "모델 목록 응답을 받지 못했습니다."
        return snapshot
    }

    static func parseCodexModels(_ data: [[String: Any]]) -> [AgentModelOption] {
        presentableOptions(data.compactMap { m in
            // 숨김 처리된 모델은 목록에 넣지 않는다.
            if (m["hidden"] as? Bool) == true { return nil }
            guard let id = (m["id"] as? String) ?? (m["model"] as? String), !id.isEmpty else {
                return nil
            }
            let efforts = (m["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                .compactMap { $0["reasoningEffort"] as? String }
            return AgentModelOption(
                provider: .codex, identifier: id,
                displayName: (m["displayName"] as? String) ?? id,
                detail: m["description"] as? String,
                supportedEfforts: efforts,
                defaultEffort: m["defaultReasoningEffort"] as? String,
                isDefault: (m["isDefault"] as? Bool) ?? false,
                isDiscovered: true)
        })
    }
}
