import Foundation

/// 6단계 — 입력창 모델 칩 "모델 | 강도" 와 팝오버 강도 목록의 판정 (`EffortScale`).
/// 단계는 카탈로그 값만, nil(앱 기본 강도)은 목록 · 키로 만들어지지 않고 보존된다.
enum ComposerTests {
    static func run(_ t: TestKit) async {
        await effortNames(t)
        await effortSteps(t)
        await effortLabels(t)
        await effortKeys(t)
        await effortList(t)
        await longContextModels(t)
        await effortCatalog(t)
        await effortCardText(t)
        await selectionOrdering(t)
        await antigravitySendBlock(t)
        await antigravityRequests(t)
        await modelDefaults(t)
        await effortDefaults(t)
        await composerRules(t)
    }

    private static let claude = ModelCatalog.claudeEfforts
    private static let astra = ["low", "medium", "high", "xhigh", "max", "ultra"]
    private static let antigravity = ["low", "medium", "high", AntigravityAdapter.boostEffort]

    // MARK: 이름 · 등급 · 설명 · 연출

    static func effortNames(_ t: TestKit) async {
        await t.group("추론 강도 이름 · 연출")
        await t.equal("단계 이름 (LEVELS)", ["low", "medium", "high", "xhigh", "max", "ultra"].map(EffortScale.name(of:)),
                      ["Low", "Medium", "High", "Extra High", "MAX", "ULTRA"])
        await t.equal("boost 는 ULTRA 로 보인다", EffortScale.name(of: "boost"), "ULTRA")
        await t.check("boost 등급은 ultra (색 · 글리프 같음)", EffortScale.tier(of: "boost") == .ultra)
        await t.equal("모르는 강도는 원문 이름", EffortScale.name(of: "minimal"), "minimal")
        await t.check("모르는 강도는 중립 등급", EffortScale.tier(of: "minimal") == .unknown)
        await t.check("MAX 글리프는 번개", EffortScale.glyph(of: "max") == .bolt)
        await t.check("ULTRA · boost 글리프는 반짝임",
                      EffortScale.glyph(of: "ultra") == .sparkle && EffortScale.glyph(of: "boost") == .sparkle)
        await t.check("그 밖은 글리프 없음", ["low", "medium", "high", "xhigh", "minimal"].allSatisfy { EffortScale.glyph(of: $0) == .none })
        await t.check("MAX · ULTRA · boost 만 특별 연출",
                      ["max", "ultra", "boost"].allSatisfy { EffortScale.isSpecial($0) }
                        && !["low", "xhigh", "minimal"].contains { EffortScale.isSpecial($0) } && !EffortScale.isSpecial(nil))
        await t.check("xhigh 를 고르면 깜빡임", EffortScale.effect(choosing: "xhigh") == .flash)
        await t.check("MAX · ULTRA · boost 를 고르면 촉각 · 효과음",
                      ["max", "ultra", "boost"].allSatisfy { EffortScale.effect(choosing: $0) == .special })
        await t.check("CLI 기본값으로 되돌릴 때 · 가벼운 단계는 연출 없음",
                      EffortScale.effect(choosing: nil) == .none && EffortScale.effect(choosing: "low") == .none
                        && EffortScale.effect(choosing: "high") == .none)
        await t.check("nil 설명은 강도를 넘기지 않는다고 적는다",
                      EffortScale.description(of: nil).contains("넘기지 않습니다"), EffortScale.description(of: nil))
        await t.check("ULTRA(boost) 설명은 넘기는 값 그대로 — High + /boost",
                      EffortScale.description(of: "boost").hasPrefix("High + /boost"), EffortScale.description(of: "boost"))
        let effortless = EffortScale.description(of: "boost", efforts: ["boost"])
        await t.check("강도를 받지 않는 모델의 ULTRA 는 /boost 만 (High 라고 하지 않음)",
                      effortless.hasPrefix("/boost") && !effortless.contains("High"), effortless)
        await t.equal("단계를 알 때도 강도를 받는 모델의 ULTRA 는 High + /boost",
                      EffortScale.description(of: "boost", efforts: antigravity), EffortScale.description(of: "boost"))
        await t.check("High 설명은 'CLI 기본' 과 비교하지 않는다", !EffortScale.description(of: "high").contains("기본"),
                      EffortScale.description(of: "high"))
        let known = ["low", "medium", "high", "xhigh", "max", "ultra"].map { EffortScale.description(of: $0) }
        await t.equal("단계마다 다른 설명", Set(known).count, known.count)
    }

    // MARK: 단계

    static func effortSteps(_ t: TestKit) async {
        await t.group("추론 강도 단계")
        await t.equal("Claude 단계 순서 그대로 (다섯 + ULTRA)", EffortScale.steps(claude).map(\.effort),
                      ["low", "medium", "high", "xhigh", "max", "ultracode"])
        await t.equal("Claude ULTRA 의 이름 · 등급", EffortScale.steps(claude).last.map { "\($0.name) \($0.tier)" } ?? "", "ULTRA ultra")
        await t.equal("Codex 모델별 단계 (카탈로그 순서)", EffortScale.steps(astra).map(\.effort), astra)
        await t.equal("Antigravity 는 boost 를 그대로 넘기고 ULTRA 로 보인다",
                      EffortScale.steps(antigravity).map(\.name), ["Low", "Medium", "High", "ULTRA"])
        await t.equal("Antigravity 단계 값 (boost 원문)", EffortScale.steps(antigravity).last?.effort ?? "", "boost")
        await t.equal("빈 값 · 겹치는 값은 한 번만", EffortScale.steps(["low", "", "low", "high"]).map(\.effort),
                      ["low", "high"])
        await t.equal("카탈로그가 준 순서를 바꾸지 않음", EffortScale.steps(["high", "low"]).map(\.effort), ["high", "low"])
        await t.check("Antigravity ULTRA(boost)만 강도 단계와 떼어 둔다",
                      EffortScale.separatesLast(EffortScale.steps(antigravity))
                        && !EffortScale.separatesLast(EffortScale.steps(astra)))
        await t.check("Claude ULTRA(ultracode = Extra High + 워크플로)도 떼어 둔다 — MAX 위의 강도가 아니다",
                      EffortScale.separatesLast(EffortScale.steps(claude))
                        && !EffortScale.separatesLast(EffortScale.steps(ModelCatalog.claudeDefaultChoices)))
        await t.check("ULTRA 하나뿐이면(강도를 받지 않는 모델) 뗄 앞 단계가 없음",
                      !EffortScale.separatesLast(EffortScale.steps([AntigravityAdapter.boostEffort])))
        await t.equal("선택한 단계 위치", EffortScale.index(of: "xhigh", in: EffortScale.steps(claude)) ?? -1, 3)
        await t.check("nil 은 어느 단계도 아님", EffortScale.index(of: nil, in: EffortScale.steps(claude)) == nil)
    }

    // MARK: 칩 · 카드 제목

    static func effortLabels(_ t: TestKit) async {
        await t.group("모델 칩 강도 칸")
        let none = EffortScale.label(selected: nil, efforts: claude)
        await t.equal("nil 은 '미선택' ('CLI 기본값' · '기본' 이라 하지 않음)", none?.text ?? "칸 없음", "미선택")
        await t.check("'미선택' 은 단계 색 없음 (slate)", none?.tier == nil && none?.glyph == EffortScale.Glyph.none)
        await t.check("강도를 받지 않는 모델 + nil = 칸 없음", EffortScale.label(selected: nil, efforts: []) == nil)
        let high = EffortScale.label(selected: "high", efforts: claude)
        await t.check("고른 단계 이름 · 등급", high?.text == "High" && high?.tier == .high && high?.offScale == false)
        let max = EffortScale.label(selected: "max", efforts: claude)
        await t.check("MAX 는 번개 + 글자", max?.text == "MAX" && max?.glyph == .bolt)
        let boost = EffortScale.label(selected: "boost", efforts: antigravity)
        await t.check("boost 칩은 반짝임 ULTRA", boost?.text == "ULTRA" && boost?.glyph == .sparkle && boost?.tier == .ultra)
        let off = EffortScale.label(selected: "ultra", efforts: claude)
        await t.check("목록에 없는 저장값도 숨기지 않고 표시 (실행에 넘어가므로)", off?.text == "ULTRA" && off?.offScale == true)
        let offEmpty = EffortScale.label(selected: "high", efforts: [])
        await t.check("목록을 못 읽었어도 저장값이 있으면 칸을 둔다", offEmpty?.text == "High" && offEmpty?.offScale == true)
        let unknown = EffortScale.label(selected: "minimal", efforts: ["minimal", "low"])
        await t.check("모르는 강도는 원문 · 중립", unknown?.text == "minimal" && unknown?.tier == .unknown
                        && unknown?.offScale == false)
        await t.equal("접근성 값: nil", EffortScale.accessibilityValue(selected: nil), "강도 미선택")
        await t.equal("접근성 값: 단계 이름", EffortScale.accessibilityValue(selected: "xhigh"), "Extra High")
        await t.equal("접근성 값: boost", EffortScale.accessibilityValue(selected: "boost"), "ULTRA")

        // Antigravity 의 nil 은 앱 기본값 High — 넘기는 값 그대로 보인다 (CLI 기본값이라고 하지 않는다).
        let shown = EffortScale.displayEffort(provider: .gemini, selected: nil, efforts: antigravity)
        await t.equal("Antigravity nil 은 High 로 보인다", shown ?? "nil", "high")
        let geminiChip = EffortScale.label(selected: shown, efforts: antigravity)
        await t.check("Antigravity nil 칩 = High (단계 색)", geminiChip?.text == "High" && geminiChip?.tier == .high
                        && geminiChip?.offScale == false)
        await t.equal("Antigravity nil 접근성 값 = High", EffortScale.accessibilityValue(selected: shown), "High")
        // Claude · Codex 의 nil 은 앱 기본 강도 (설정 > 에이전트) — 모델이 받을 때만. "CLI 기본값" 상태는 없다.
        await t.check("Claude · Codex 의 nil 은 앱 기본 강도 (기본 high)",
                      EffortScale.displayEffort(provider: .claude, selected: nil, efforts: claude) == "high"
                        && EffortScale.displayEffort(provider: .codex, selected: nil, efforts: astra) == "high")
        await t.check("설정의 기본 강도를 따른다",
                      EffortScale.displayEffort(provider: .claude, selected: nil, efforts: claude, appDefault: "xhigh") == "xhigh"
                        && EffortScale.displayEffort(provider: .codex, selected: nil, efforts: astra, appDefault: "low") == "low")
        await t.check("모델이 기본 강도를 받지 않으면 · 목록을 모르면 넘기지 않는다 (nil)",
                      EffortScale.displayEffort(provider: .codex, selected: nil, efforts: ["low", "medium"]) == nil
                        && EffortScale.displayEffort(provider: .codex, selected: nil, efforts: []) == nil
                        && EffortScale.displayEffort(provider: .claude, selected: nil, efforts: []) == nil)
        await t.check("고른 값은 기본 강도보다 우선",
                      EffortScale.displayEffort(provider: .claude, selected: "low", efforts: claude, appDefault: "max") == "low")
        await t.equal("고른 강도는 그대로 보인다", EffortScale.displayEffort(provider: .gemini, selected: "low", efforts: antigravity) ?? "nil",
                      "low")
        await t.check("High 를 받지 않는 모델 · 강도를 받지 않는 모델의 nil 은 High 로 보이지 않는다",
                      EffortScale.displayEffort(provider: .gemini, selected: nil, efforts: ["medium"]) == nil
                        && EffortScale.displayEffort(provider: .gemini, selected: nil, efforts: ["boost"]) == nil
                        && EffortScale.displayEffort(provider: .gemini, selected: nil, efforts: []) == nil)
        await t.equal("빈 문자열은 고르지 않은 것과 같다 (판정도 High 로 보낸다)",
                      EffortScale.displayEffort(provider: .gemini, selected: "", efforts: antigravity) ?? "nil", "high")
        // 고른 강도가 없을 때의 이름: Antigravity 에는 CLI 기본값이 없다
        let effortlessChip = EffortScale.label(selected: nil, efforts: [AntigravityAdapter.boostEffort], provider: .gemini)
        let noHighChip = EffortScale.label(selected: nil, efforts: ["medium"], provider: .gemini)
        await t.check("강도 변형이 없는 모델의 nil 칩 = '강도 없음' · High 가 없는 모델 = '미선택' ('기본' 이라 하지 않음)",
                      effortlessChip?.text == "강도 없음" && noHighChip?.text == "미선택" && noHighChip?.tier == nil,
                      "\(effortlessChip?.text ?? "칸 없음") · \(noHighChip?.text ?? "칸 없음")")
        await t.check("Antigravity nil 접근성 값은 'CLI 기본값' 이 아님",
                      EffortScale.accessibilityValue(selected: nil, provider: .gemini, efforts: ["medium"]) == "강도 미선택"
                        && EffortScale.accessibilityValue(selected: nil, provider: .gemini,
                                                          efforts: [AntigravityAdapter.boostEffort]) == "강도 없음"
                        && EffortScale.accessibilityValue(selected: nil, provider: .claude, efforts: claude) == "강도 미선택")
        // 보이는 기본값(High)을 다시 누르면 같은 값 — 몰래 명시 High 로 저장하지 않는다
        await t.check("보이는 기본값 High 를 누름 = 바꾸지 않음",
                      !EffortScale.changesSelection(to: "high", current: nil, displayed: "high")
                        && EffortScale.changesSelection(to: "boost", current: nil, displayed: "high")
                        && EffortScale.changesSelection(to: "medium", current: nil, displayed: "high"))
        await t.check("그 밖은 기존 규칙 (같은 값만 거른다)",
                      !EffortScale.changesSelection(to: "low", current: "low", displayed: "low")
                        && EffortScale.changesSelection(to: nil, current: "high", displayed: "high")
                        && EffortScale.changesSelection(to: "low", current: nil, displayed: nil)
                        && !EffortScale.changesSelection(to: nil, current: nil, displayed: "high"))
    }

    // MARK: ← → · VoiceOver 증감

    static func effortKeys(_ t: TestKit) async {
        await t.group("추론 강도 키 이동")
        await t.equal("nil 에서 → 는 첫 단계", EffortScale.keyStep(from: nil, .increase, efforts: claude) ?? "없음", "low")
        await t.equal("nil 에서 ← 도 첫 단계 (부르는 쪽이 보이는 값을 넘긴다)",
                      EffortScale.keyStep(from: nil, .decrease, efforts: claude) ?? "없음", "low")
        await t.equal("→ 한 단계", EffortScale.keyStep(from: "high", .increase, efforts: claude) ?? "없음", "xhigh")
        await t.equal("← 한 단계", EffortScale.keyStep(from: "high", .decrease, efforts: claude) ?? "없음", "medium")
        await t.equal("MAX 다음은 ULTRA", EffortScale.keyStep(from: "max", .increase, efforts: claude) ?? "없음", "ultracode")
        await t.check("아래 끝(ULTRA)에서 멈춤 (같은 값을 다시 보내지 않음)",
                      EffortScale.keyStep(from: "ultracode", .increase, efforts: claude) == nil)
        await t.check("왼쪽 끝에서 멈춤 — nil 로 가지 않음",
                      EffortScale.keyStep(from: "low", .decrease, efforts: claude) == nil)
        await t.equal("목록에 없는 값에서는 첫 단계", EffortScale.keyStep(from: "ultra", .increase, efforts: claude) ?? "없음", "low")
        await t.check("단계가 없으면 움직이지 않음", EffortScale.keyStep(from: nil, .increase, efforts: []) == nil)
        await t.equal("Antigravity high → boost", EffortScale.keyStep(from: "high", .increase, efforts: antigravity) ?? "없음",
                      "boost")
        await t.equal("Codex max → ultra", EffortScale.keyStep(from: "max", .increase, efforts: astra) ?? "없음", "ultra")
        // Antigravity 는 보이는 값(nil = High)에서 움직인다 — 척도의 시작으로 뛰지 않는다.
        let geminiShown = EffortScale.displayEffort(provider: .gemini, selected: nil, efforts: antigravity)
        await t.equal("Antigravity 기본(High)에서 → 는 ULTRA",
                      EffortScale.keyStep(from: geminiShown, .increase, efforts: antigravity) ?? "없음", "boost")
        await t.equal("Antigravity 기본(High)에서 ← 는 Medium",
                      EffortScale.keyStep(from: geminiShown, .decrease, efforts: antigravity) ?? "없음", "medium")
        // 끝까지 → 를 눌러도 끝 단계에서 멈추고, 어떤 순서로 눌러도 nil 이 나오지 않는다.
        var value: String? = nil
        var visited: [String] = []
        for direction in [EffortScale.Direction.decrease, .increase, .increase, .increase, .increase, .increase, .increase,
                          .decrease, .decrease] {
            if let next = EffortScale.keyStep(from: value, direction, efforts: claude) {
                value = next
                visited.append(next)
            }
        }
        await t.equal("← → 연속 입력 경로", visited, ["low", "medium", "high", "xhigh", "max", "ultracode", "max", "xhigh"])
    }

    // MARK: 강도 목록 (팝오버 — 캔버스 시안 B)

    static func effortList(_ t: TestKit) async {
        await t.group("추론 강도 목록")
        await t.equal("행 아래 한 줄은 MAX 만 (Claude)",
                      claude.map { EffortScale.rowNote(of: $0, efforts: claude) ?? "" },
                      ["", "", "", "", "한도를 빠르게 소모합니다.", "Extra High + 워크플로 · 한도를 매우 빠르게 소모합니다."])
        await t.check("안내는 Claude ULTRA 에만 — MAX 보다 깊은 단계가 아니라고",
                      EffortScale.rowHelp(of: "ultracode")?.contains("MAX 보다 깊게 추론하는 단계가 아닙니다") == true
                        && EffortScale.rowHelp(of: "max") == nil && EffortScale.rowHelp(of: "ultra") == nil)
        await t.check("실행 머리 · 칩 도움말이 실제로 넘기는 것을 말한다",
                      EffortScale.runMeta(effort: "ultracode", boost: false)?.text == "ULTRA · Extra High + 워크플로"
                        && EffortScale.chipHelp(provider: .claude, outcome: nil, effort: "ultracode").hasSuffix("Extra High + 워크플로(ultracode)")
                        && !EffortScale.chipHelp(provider: .claude, outcome: nil, effort: "max").contains("ULTRA"))
        await t.check("ULTRA 는 연출(불티 · 소리)이 붙는 강도", EffortScale.isSpecial("ultracode"))
        await t.check("설정의 Claude 기본 강도에는 ULTRA 가 없다", !ModelCatalog.claudeDefaultChoices.contains("ultracode")
                        && ModelCatalog.claudeDefaultChoices.last == "max")
        await t.equal("워크플로를 쓸 수 있는 턴은 ultracode 그대로", ClaudeAdapter.cliEffort("ultracode", workflowsAllowed: true) ?? "없음",
                      "ultracode")
        await t.equal("읽기 전용 · 구조화 응답 턴은 같은 강도 xhigh 로", ClaudeAdapter.cliEffort("ultracode", workflowsAllowed: false) ?? "없음",
                      "xhigh")
        await t.check("다른 값 · 빈 값은 그대로 · 넘기지 않음", ClaudeAdapter.cliEffort("max", workflowsAllowed: false) == "max"
                        && ClaudeAdapter.cliEffort("", workflowsAllowed: true) == nil)
        var cached = AgentModelOption(provider: .claude, identifier: "opus", displayName: "Opus 5.5",
                                      supportedEfforts: ["low", "medium", "high", "xhigh", "max"])
        cached = ModelCatalog.presentableOptions([cached])[0]
        await t.equal("ULTRA 이전에 저장된 Claude 목록에도 지금 강도 목록", cached.supportedEfforts, claude)
        await t.check("ULTRA(Codex) 도 한 줄", EffortScale.rowNote(of: "ultra", efforts: astra) != nil)
        await t.check("Antigravity ULTRA 는 넘기는 값 (High + /boost)",
                      EffortScale.rowNote(of: AntigravityAdapter.boostEffort, efforts: antigravity)?.hasPrefix("High + /boost") == true)
        await t.check("강도를 받지 않는 Antigravity 모델의 ULTRA 는 /boost 만",
                      EffortScale.rowNote(of: AntigravityAdapter.boostEffort,
                                          efforts: [AntigravityAdapter.boostEffort])?.hasPrefix("/boost 만") == true)
        await t.check("모르는 값은 한 줄 없음", EffortScale.rowNote(of: "turbo", efforts: ["turbo"]) == nil)

        let claudeAll = EffortScale.Availability(efforts: claude, emptyReason: nil)
        await t.equal("Claude 기본 표시 = High (설정에서 고르지 않음)",
                      EffortScale.defaultMark(provider: .claude, availability: claudeAll, defaults: .init())?.effort ?? "없음",
                      "high")
        await t.equal("설정의 기본 강도를 따른다",
                      EffortScale.defaultMark(provider: .claude, availability: claudeAll,
                                              defaults: .init(user: "medium"))?.effort ?? "없음", "medium")
        let codexModel = EffortScale.Availability(efforts: ["low", "medium", "high", "xhigh"], emptyReason: nil,
                                                  modelDefault: "medium")
        let codexMark = EffortScale.defaultMark(provider: .codex, availability: codexModel, defaults: .init())
        await t.equal("Codex 는 그 모델의 기본 강도", codexMark?.effort ?? "없음", "medium")
        await t.check("기본 표시의 도움말이 출처를 말한다", codexMark?.help.hasPrefix("이 모델의 기본 강도") == true,
                      codexMark?.help ?? "")
        await t.equal("Codex config.toml 이 모델 기본보다 앞선다",
                      EffortScale.defaultMark(provider: .codex, availability: codexModel,
                                              defaults: .init(config: "xhigh"))?.effort ?? "없음", "xhigh")
        let agy = EffortScale.Availability(efforts: antigravity, emptyReason: nil)
        await t.equal("Antigravity 기본 표시 = High",
                      EffortScale.defaultMark(provider: .gemini, availability: agy, defaults: .init())?.effort ?? "없음", "high")
        let none = EffortScale.Availability(efforts: [], emptyReason: .noEfforts)
        await t.check("단계가 없으면 기본 표시 없음",
                      EffortScale.defaultMark(provider: .claude, availability: none, defaults: .init()) == nil)

        // 알림 줄 — 단계 설명은 두지 않는다 (사용자 결정 2026-10-07). 알아야 할 것만.
        await t.check("고른 단계 · 고르지 않은 단계는 알림 없음",
                      EffortScale.listNote(selected: "high", availability: claudeAll, provider: .claude, defaults: .init()) == nil
                        && EffortScale.listNote(selected: nil, availability: claudeAll, provider: .claude,
                                                defaults: .init()) == nil
                        && EffortScale.listNote(selected: nil, availability: agy, provider: .gemini, defaults: .init()) == nil)
        await t.check("목록에 없는 값은 알린다",
                      EffortScale.listNote(selected: "ultra", availability: claudeAll, provider: .claude,
                                           defaults: .init())?.contains("목록에 없는 값") == true)
        let boostOnly = EffortScale.Availability(efforts: [AntigravityAdapter.boostEffort], emptyReason: nil)
        await t.check("Antigravity 기본(High)을 받지 않는 모델 — 강도 없이 보낸다고 알린다",
                      EffortScale.listNote(selected: nil, availability: boostOnly, provider: .gemini,
                                           defaults: .init())?.contains("강도 없이 보냅니다") == true)
        await t.check("단계가 없고 고른 값도 없으면 목록 자리 문구로 충분 (알림 없음)",
                      EffortScale.listNote(selected: nil, availability: none, provider: .claude, defaults: .init()) == nil)
        await t.check("강도를 받지 않는 모델에 남은 저장값은 알린다",
                      EffortScale.listNote(selected: "high", availability: none, provider: .codex,
                                           defaults: .init())?.contains("저장된 강도가 남아") == true)
    }

    // MARK: 긴 문맥(1M) 모델 — 바탕 행 + 스위치

    static func longContextModels(_ t: TestKit) async {
        await t.group("긴 문맥(1M) 모델")
        func claudeOption(_ id: String) -> AgentModelOption {
            AgentModelOption(provider: .claude, identifier: id, displayName: id, supportedEfforts: ModelCatalog.claudeEfforts)
        }
        let options = ["fable", "opus", "sonnet", "haiku", "best", "fable[1m]", "opus[1m]", "sonnet[1m]", "opusplan"]
            .map(claudeOption)
        await t.equal("행은 바탕만 (긴 문맥 별칭은 스위치로)", ModelCatalog.baseOptions(options).map(\.identifier),
                      ["fable", "opus", "sonnet", "haiku", "best", "opusplan"])
        await t.equal("바탕의 긴 문맥 별칭", ModelCatalog.longContextVariant(of: options[1], in: options)?.identifier ?? "없음",
                      "opus[1m]")
        await t.check("긴 문맥 별칭이 없는 모델", ModelCatalog.longContextVariant(of: options[3], in: options) == nil)
        await t.equal("긴 문맥 별칭의 행은 바탕", ModelCatalog.baseOption(of: options[6], in: options).identifier, "opus")
        await t.equal("스위치 설명에 쓰는 모델", ModelCatalog.longContextBases(options).map(\.identifier),
                      ["fable", "opus", "sonnet"])
        let lone = [claudeOption("haiku"), claudeOption("opus[1m]")]
        await t.equal("바탕이 목록에 없는 긴 문맥 별칭은 그대로 한 행", ModelCatalog.baseOptions(lone).map(\.identifier),
                      ["haiku", "opus[1m]"])
        await t.equal("그 행은 자기 자신", ModelCatalog.baseOption(of: lone[1], in: lone).identifier, "opus[1m]")
        let codex = [AgentModelOption(provider: .codex, identifier: "gpt-6-sol", displayName: "GPT-6 Sol")]
        await t.check("Codex 에는 긴 문맥 스위치가 없다", ModelCatalog.longContextBases(codex).isEmpty)
    }

    // MARK: 카탈로그 → 단계 · 모델 바꿀 때

    static func effortCatalog(_ t: TestKit) async {
        await t.group("모델별 추론 강도")
        let codex = ModelCatalog.parseCodexModels([
            ["id": "gpt-5.6-luna", "displayName": "GPT-5.6-Luna", "isDefault": false,
             "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "max"]]],
            ["id": "gpt-6-astra", "displayName": "GPT-6-Astra", "isDefault": true,
             "supportedReasoningEfforts": astra.map { ["reasoningEffort": $0] }],
            ["id": "gpt-5.5", "displayName": "GPT-5.5", "isDefault": false, "supportedReasoningEfforts": []],
        ])
        await t.equal("Claude 는 목록이 없어도 CLI 도움말의 5단계",
                      EffortScale.availableEfforts(provider: .claude, selectedModel: nil, options: []), claude)
        await t.equal("Codex 고른 모델의 단계",
                      EffortScale.availableEfforts(provider: .codex, selectedModel: "gpt-5.6-luna", options: codex),
                      ["low", "max"])
        await t.equal("Codex 선택이 없으면 CLI 기본 모델의 단계",
                      EffortScale.availableEfforts(provider: .codex, selectedModel: nil, options: codex), astra)
        await t.check("강도를 받지 않는 모델은 단계 없음",
                      EffortScale.availableEfforts(provider: .codex, selectedModel: "gpt-5.5", options: codex).isEmpty)
        await t.check("Codex 목록을 못 읽었으면 단계를 지어내지 않음",
                      EffortScale.availableEfforts(provider: .codex, selectedModel: nil, options: []).isEmpty)
        var geminiBase = ModelCatalogSnapshot(provider: .gemini)
        geminiBase.fetchedAt = Date()
        let gemini = ModelCatalog.parseGeminiModelResponse(
            "gemini-3.8-flash-low\tGemini 3.8 Flash (Low)\ngemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)\n"
                + "gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n", into: geminiBase).options
        await t.equal("Antigravity 는 찾은 강도 + boost",
                      EffortScale.availableEfforts(provider: .gemini, selectedModel: "gemini-3.8-flash", options: gemini),
                      antigravity)
        await t.equal("Antigravity 모델을 고르지 않으면 앱 기본 모델(최신 Flash)의 단계 — 보내기가 그 모델로 확정한다",
                      EffortScale.availableEfforts(provider: .gemini, selectedModel: nil, options: gemini), antigravity)
        let noFlash = ModelCatalog.parseGeminiModelResponse("claude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)\n",
                                                            into: geminiBase).options
        // 단계가 비는 이유 (카드 문구가 사실대로 말하게)
        func reason(_ provider: AgentProvider, _ model: String?, _ options: [AgentModelOption]) -> EffortScale.EmptyReason? {
            EffortScale.availability(provider: provider, selectedModel: model, options: options).emptyReason
        }
        await t.check("목록을 못 읽음 → 목록 미확인", reason(.codex, nil, []) == .catalogUnknown
                        && reason(.codex, "gpt-6-astra", []) == .catalogUnknown && reason(.gemini, nil, []) == .catalogUnknown)
        await t.check("Antigravity 기본으로 쓸 Flash 가 없고 모델을 고르지 않음 → 모델 미선택 (받지 않는다고 하지 않음)",
                      reason(.gemini, nil, noFlash) == .modelUnchosen && reason(.gemini, nil, gemini) == nil)
        await t.check("고른 모델이 목록에 없음 → 목록에 없는 모델", reason(.gemini, "gemini-9-flash", gemini) == .modelUnlisted
                        && reason(.codex, "gpt-9", codex) == .modelUnlisted)
        await t.check("명시한 Codex 모델이 목록에 없으면 기본 모델의 단계를 빌리지 않음",
                      EffortScale.availableEfforts(provider: .codex, selectedModel: "gpt-9", options: codex).isEmpty)
        await t.equal("Claude 의 'default' 는 고르지 않은 것과 같다 (보내기가 채운다)",
                      EffortScale.availableEfforts(provider: .claude, selectedModel: "default", options: []), claude)
        await t.check("Codex 의 'default' 는 보내기가 채우지 않는다 — 목록에 없는 모델로 본다",
                      reason(.codex, "default", codex) == .modelUnlisted)
        await t.equal("Claude 는 목록에 없는 모델이어도 CLI 도움말의 5단계",
                      EffortScale.availableEfforts(provider: .claude, selectedModel: "claude-x-2", options: []), claude)
        await t.check("강도를 받지 않는 모델 → 받지 않음", reason(.codex, "gpt-5.5", codex) == .noEfforts)
        await t.check("단계가 있으면 이유 없음", reason(.codex, nil, codex) == nil && reason(.claude, nil, []) == nil)
        await t.equal("모델을 바꿔도 받는 강도면 유지",
                      EffortScale.effortAfterModelChange(current: "max", supported: ["low", "max"]) ?? "없음", "max")
        await t.check("받지 않는 강도는 해제 (앱 기본 강도)",
                      EffortScale.effortAfterModelChange(current: "xhigh", supported: ["low", "max"]) == nil)
        await t.check("nil 은 모델을 바꿔도 nil",
                      EffortScale.effortAfterModelChange(current: nil, supported: astra) == nil)
        await t.check("강도를 받지 않는 모델로 바꾸면 해제",
                      EffortScale.effortAfterModelChange(current: "low", supported: []) == nil)
    }

    // MARK: 카드 문구

    static func effortCardText(_ t: TestKit) async {
        await t.group("강도 카드 문구")
        let claudeSteps = EffortScale.Availability(efforts: claude, emptyReason: nil)
        let geminiSteps = EffortScale.Availability(efforts: antigravity, emptyReason: nil)
        func note(_ selected: String?, _ availability: EffortScale.Availability,
                  _ provider: AgentProvider = .claude) -> String {
            EffortScale.note(selected: selected, availability: availability, provider: provider) ?? "(없음)"
        }
        await t.equal("단계 안의 값은 그 단계 설명", note("high", claudeSteps), EffortScale.description(of: "high"))
        await t.equal("nil 은 앱 기본 강도의 설명 + 출처 (Claude)", note(nil, claudeSteps),
                      "기본 강도 (설정 > 에이전트) · " + EffortScale.description(of: "high"))
        await t.equal("nil 은 앱 기본 강도의 설명 + 출처 (Codex)", note(nil, EffortScale.Availability(efforts: astra, emptyReason: nil), .codex),
                      "기본 강도 (설정 > 에이전트) · " + EffortScale.description(of: "high"))
        await t.equal("설정을 바꾸면 그 단계 설명",
                      EffortScale.note(selected: nil, availability: claudeSteps, provider: .claude, appDefault: "max") ?? "(없음)",
                      "기본 강도 (설정 > 에이전트) · " + EffortScale.description(of: "max"))
        let codexNoDefault = note(nil, EffortScale.Availability(efforts: ["low", "medium"], emptyReason: nil), .codex)
        await t.check("모델이 기본 강도를 받지 않으면 단계를 고르라고 ('CLI' 없음)",
                      codexNoDefault.contains("High") && codexNoDefault.contains("단계를 고르세요") && !codexNoDefault.contains("CLI"),
                      codexNoDefault)
        // Antigravity: agy 에 기본 강도가 없어(1.2.2 실측) 앱 기본값 High 를 넘긴다 — 모델이 받는 강도로 문장을 가린다.
        let geminiNil = note(nil, geminiSteps, .gemini)
        await t.check("Antigravity 제품군의 nil 은 'CLI 설정을 따른다' 가 아니라 기본값 High 로 보낸다고",
                      geminiNil.contains("기본값 High") && !geminiNil.contains("CLI 설정을 따릅니다"), geminiNil)
        let geminiEffortless = note(nil, EffortScale.Availability(efforts: [AntigravityAdapter.boostEffort], emptyReason: nil), .gemini)
        await t.equal("강도 변형이 없는 모델의 nil 은 강도 없이 보낸다 (거부 기록을 잘못 적지 않음)",
                      geminiEffortless, "이 모델은 추론 강도를 받지 않습니다. 강도 없이 보냅니다.")
        let geminiNoHigh = note(nil, EffortScale.Availability(efforts: ["medium"], emptyReason: nil), .gemini)
        await t.check("High 가 없는 모델의 nil 은 막히는 이유 (실측하지 않은 agy 거부를 단정하지 않음)",
                      geminiNoHigh.contains("기본값 High 가 없어") && geminiNoHigh.contains("Medium")
                        && !geminiNoHigh.contains("거부"), geminiNoHigh)
        await t.check("Antigravity 기본값 설명은 CLI 기본값이 아니라 앱이 넘기는 값이라고",
                      geminiNil.contains("앱이 넘기는 값") && !geminiNil.contains("agy 는 이 모델을"), geminiNil)
        await t.equal("Antigravity ULTRA 설명 (강도를 받는 모델)", note("boost", geminiSteps, .gemini),
                      EffortScale.ultraDescription(takesEffort: true))
        await t.equal("Antigravity ULTRA 설명 (강도를 받지 않는 모델)",
                      note("boost", EffortScale.Availability(efforts: [AntigravityAdapter.boostEffort], emptyReason: nil), .gemini),
                      EffortScale.ultraDescription(takesEffort: false))
        await t.check("되돌리기 이름: Antigravity 는 앱 기본값, 그 밖은 CLI 기본값",
                      EffortScale.resetTitle(provider: .gemini) == "기본값으로 되돌리기"
                        && EffortScale.resetTitle(provider: .claude) == "강도 비우기"
                        && EffortScale.resetTitle(provider: .codex) == "강도 비우기")
        func steps(_ efforts: [String], _ reason: EffortScale.EmptyReason? = nil) -> EffortScale.Availability {
            EffortScale.Availability(efforts: efforts, emptyReason: reason)
        }
        await t.check("되돌리기 도움말도 같은 사실",
                      EffortScale.resetHelp(provider: .gemini, availability: steps(antigravity)).contains("High")
                        && EffortScale.resetHelp(provider: .gemini, availability: steps([AntigravityAdapter.boostEffort]))
                            .contains("받지 않습니다")
                        && EffortScale.resetHelp(provider: .gemini, availability: steps(["medium"])).contains("골라야")
                        && !EffortScale.resetHelp(provider: .claude, availability: steps(claude)).contains("CLI"))
        let unknownHelp = EffortScale.resetHelp(provider: .gemini, availability: steps([], .catalogUnknown))
        await t.check("목록을 모르면 '강도를 받지 않는다' 고 하지 않음", !unknownHelp.contains("받지 않습니다")
                        && unknownHelp.contains("확인하지 못해"), unknownHelp)
        await t.check("되돌리기 버튼: 고른 강도가 있을 때만",
                      EffortScale.offersReset(provider: .gemini, selected: "low", availability: steps(antigravity))
                        && !EffortScale.offersReset(provider: .gemini, selected: nil, availability: steps(antigravity))
                        && !EffortScale.offersReset(provider: .claude, selected: "", availability: steps(claude)))
        await t.check("Claude · Codex 는 단계가 있으면 되돌리기 없음 (nil 이 앱 기본 강도라 슬라이더로 고르면 된다)",
                      !EffortScale.offersReset(provider: .claude, selected: "low", availability: steps(claude))
                        && !EffortScale.offersReset(provider: .codex, selected: "xhigh", availability: steps(astra))
                        && !EffortScale.offersReset(provider: .codex, selected: "high", availability: steps([], .catalogUnknown)))
        await t.check("Antigravity 는 단계가 없으면(목록 · 모델 모름) 두지 않음 — 되돌린 뒤 다시 고를 수 없어 막힌다",
                      !EffortScale.offersReset(provider: .gemini, selected: "low", availability: steps([], .catalogUnknown))
                        && !EffortScale.offersReset(provider: .gemini, selected: "high", availability: steps([], .modelUnlisted)))
        await t.check("Claude · Codex 는 단계가 없어도 둔다 (넘기지 않으려면 되돌린다)",
                      EffortScale.offersReset(provider: .codex, selected: "high", availability: steps([], .noEfforts)))
        let chipBase = "모델 · 추론 강도 — 이 대화에만 적용됩니다"
        func chip(_ model: String, _ effort: String?, _ boost: Bool) -> String {
            EffortScale.chipHelp(provider: .gemini,
                                 outcome: .send(AntigravityAdapter.TurnPlan(model: model, effort: effort, boost: boost)))
        }
        await t.check("칩 도움말: ULTRA 는 판정이 넘기는 값 그대로 (High + /boost)",
                      chip("gemini-3.8-flash", "high", true) == chipBase + " · ULTRA = High + /boost"
                        && chip("gemini-3.8-flash-high", nil, true) == chipBase + " · ULTRA = High + /boost"
                        && chip("claude-sonnet-4-6", nil, true) == chipBase + " · ULTRA = /boost (강도를 받지 않는 모델)"
                        && chip("gemini-3.8-flash", "high", false) == chipBase
                        && EffortScale.chipHelp(provider: .gemini, outcome: .blocked(.catalogUnknown)) == chipBase
                        && EffortScale.chipHelp(provider: .codex, outcome: nil) == chipBase)
        // 실행 중 머리: 넘긴 값 그대로
        func meta(_ effort: String?, _ boost: Bool) -> String { EffortScale.runMeta(effort: effort, boost: boost)?.text ?? "(없음)" }
        await t.equal("실행 머리: Antigravity ULTRA", meta("high", true), "ULTRA · High + /boost")
        await t.equal("실행 머리: 강도를 받지 않는 모델의 ULTRA", meta(nil, true), "ULTRA · /boost")
        await t.equal("실행 머리: 기본값 High — 입력창 칩과 같은 이름", meta("high", false), "High")
        await t.equal("실행 머리: 칩과 같은 이름 (xhigh · max)", [meta("xhigh", false), meta("max", false)], ["Extra High", "MAX"])
        await t.check("실행 머리: Codex ULTRA · MAX 등급", EffortScale.runMeta(effort: "ultra", boost: false)?.text == "ULTRA"
                        && EffortScale.runMeta(effort: "ultra", boost: false)?.tier == .ultra
                        && EffortScale.runMeta(effort: "max", boost: false)?.tier == .max
                        && EffortScale.runMeta(effort: "high", boost: true)?.tier == .ultra)
        await t.check("실행 머리: 강도를 넘기지 않았으면 칸 없음", EffortScale.runMeta(effort: nil, boost: false) == nil)
        let unknownList = note("high", EffortScale.Availability(efforts: [], emptyReason: .catalogUnknown), .codex)
        await t.check("목록을 못 읽었는데 저장값 → '없는 값' 이라 단정하지 않고 확인하지 못했다고",
                      unknownList.contains("확인하지 못했습니다") && !unknownList.contains("없는 값") && !unknownList.contains("다른 단계"),
                      unknownList)
        // Antigravity: 고른 모델이 목록에 없어도 고른 강도는 그대로 넘긴다 — 문장과 판정을 함께 본다.
        let unlistedNote = note("high", EffortScale.Availability(efforts: [], emptyReason: .modelUnlisted), .gemini)
        let unlistedPlan = AntigravityAdapter.plan(model: "gemini-9-flash", effort: "high",
                                                   options: [AgentModelOption(provider: .gemini, identifier: "gemini-3.8-flash",
                                                                              displayName: "Gemini 3.8 Flash",
                                                                              supportedEfforts: antigravity)])
        await t.check("Antigravity 목록에 없는 모델 + 고른 강도 → 그대로 넘긴다고 (판정도 그 강도로 보냄)",
                      unlistedNote.contains("확인하지 못했습니다") && unlistedNote.contains("그대로 넘깁니다")
                        && !unlistedNote.contains("되돌리세요")
                        && unlistedPlan == .send(AntigravityAdapter.TurnPlan(model: "gemini-9-flash", effort: "high", boost: false)),
                      unlistedNote)
        let unknownGemini = note("low", EffortScale.Availability(efforts: [], emptyReason: .catalogUnknown), .gemini)
        await t.check("Antigravity 목록을 못 읽음 + 고른 모델 · 강도 → 그대로 넘긴다고 (판정도 그 강도로 보냄)",
                      unknownGemini.contains("그대로 넘깁니다")
                        && AntigravityAdapter.plan(model: "gemini-3.8-flash", effort: "low", options: [])
                            == .send(AntigravityAdapter.TurnPlan(model: "gemini-3.8-flash", effort: "low", boost: false)),
                      unknownGemini)
        let unchosen = note("high", EffortScale.Availability(efforts: [], emptyReason: .modelUnchosen), .gemini)
        await t.equal("Antigravity 기본 모델도 없고 모델을 고르지 않음 → 넘긴다고 하지 않고 판정의 이유", unchosen,
                      AntigravityAdapter.TurnBlock.modelUnchosen.message)
        await t.check("단계가 있는데 목록 밖 값 → 다른 단계를 (Claude — 되돌리기가 없다)",
                      note("ultra", claudeSteps).contains("다른 단계를 고르세요") && !note("ultra", claudeSteps).contains("되돌리"))
        // 카드가 실제로 이 문장을 보이는 값으로 본다 — 판정이 그 강도로 보낼 때(막히면 카드는 막힌 이유를 보인다).
        let pro = AgentModelOption(provider: .gemini, identifier: "gemini-3.1-pro", displayName: "Gemini 3.1 Pro",
                                   supportedEfforts: ["low", "high", AntigravityAdapter.boostEffort])
        let geminiOff = note("medium", EffortScale.Availability(efforts: pro.supportedEfforts, emptyReason: nil), .gemini)
        await t.check("Antigravity High 를 받는 모델의 목록 밖 값 → 되돌리면 기본값 High 라 되돌리기도 권함 (판정도 그 강도로 보냄)",
                      geminiOff.contains("되돌리거나 다른 단계를 고르세요")
                        && AntigravityAdapter.plan(model: "gemini-3.1-pro", effort: "medium", options: [pro])
                            == .send(AntigravityAdapter.TurnPlan(model: "gemini-3.1-pro", effort: "medium", boost: false)),
                      geminiOff)
        let oss = AgentModelOption(provider: .gemini, identifier: "gpt-oss-120b", displayName: "GPT-OSS 120B",
                                   supportedEfforts: ["medium"])
        let geminiOffNoHigh = note("low", EffortScale.Availability(efforts: oss.supportedEfforts, emptyReason: nil), .gemini)
        await t.check("Antigravity High 가 없는 모델의 목록 밖 값 → 되돌리면 막히므로 다른 단계만 (판정도 그 강도로 보냄)",
                      geminiOffNoHigh.contains("다른 단계를 고르세요") && !geminiOffNoHigh.contains("되돌리")
                        && AntigravityAdapter.plan(model: "gpt-oss-120b", effort: "low", options: [oss])
                            == .send(AntigravityAdapter.TurnPlan(model: "gpt-oss-120b", effort: "low", boost: false)),
                      geminiOffNoHigh)
        // agy 가 받지 않는 저장값(옛 Codex 값)은 카드가 막힌 이유를 보이고, 목록에 없는 모델이어도 되돌려 비울 수 있다.
        let unsupported = AntigravityAdapter.plan(model: "gpt-5.6-sol", effort: "xhigh", options: [pro])
        await t.check("옛 선택: 목록에 없는 모델 + xhigh → agy 가 받지 않는 강도로 막고 강도나 모델을 다시 고르라고",
                      unsupported == .blocked(.unsupportedEffort("xhigh"))
                        && AntigravityAdapter.TurnBlock.unsupportedEffort("xhigh").message.contains("강도나 모델을 다시 고르세요"))
        await t.check("옛 선택: 그 값은 단계가 없어도 되돌려 비울 수 있고, 비우면 모델 쪽 이유로 막힌다",
                      EffortScale.offersReset(provider: .gemini, selected: "xhigh", availability: steps([], .modelUnlisted))
                        && !EffortScale.offersReset(provider: .gemini, selected: "boost", availability: steps([], .modelUnlisted))
                        && AntigravityAdapter.plan(model: "gpt-5.6-sol", effort: nil, options: [pro])
                            == .blocked(.modelUnlisted("gpt-5.6-sol")))
        let codexUnchosen = note("high", EffortScale.Availability(efforts: [], emptyReason: .modelUnchosen), .codex)
        await t.check("Codex 모델을 고르지 않았는데 저장값 → 모델을 고른 뒤 확인한다고 ('지금 모델' 이 없다)",
                      codexUnchosen.contains("모델을 고르면") && !codexUnchosen.contains("지금 모델"), codexUnchosen)
        let noEfforts = note("high", EffortScale.Availability(efforts: [], emptyReason: .noEfforts), .codex)
        await t.check("강도를 받지 않는 모델에 저장값 → 남아 있다고 · 비우기 안내", noEfforts.contains("받지 않지만")
                        && noEfforts.contains("비우세요") && !noEfforts.contains("다른 단계"), noEfforts)
        await t.check("단계가 없고 nil 이면 설명 없음 (슬라이더 자리 문구로 충분)",
                      EffortScale.note(selected: nil, availability: EffortScale.Availability(efforts: [], emptyReason: .catalogUnknown),
                                       provider: .codex) == nil
                        && EffortScale.note(selected: nil, availability: EffortScale.Availability(efforts: [], emptyReason: .modelUnchosen),
                                            provider: .gemini) == nil)
        await t.equal("강도를 받지 않는 모델의 nil 은 넘기지 않는다는 설명",
                      note(nil, EffortScale.Availability(efforts: [], emptyReason: .noEfforts), .codex),
                      "이 모델이 받는 강도를 확인하지 못해 추론 강도를 넘기지 않습니다.")
        await t.check("슬라이더 자리 문구 넷", EffortScale.emptyMessage(.catalogUnknown).contains("확인하지 못했습니다")
                        && EffortScale.emptyMessage(.modelUnchosen).contains("모델을 고르면")
                        && EffortScale.emptyMessage(.modelUnlisted).contains("목록에 없어")
                        && EffortScale.emptyMessage(.noEfforts).contains("받지 않습니다"))
        let effortKeys = MenuShortcut.inView.filter { $0.title.hasPrefix("추론 강도") }
        // 강도 목록은 위(Low) → 아래(MAX) 라 ↑ ↓ 로 적는다 (← → 도 받는다 — 예전 슬라이더에 익은 손).
        await t.equal("화면 안 단축키 표에 강도 ↑ ↓ (표기)", effortKeys.map(\.symbol), ["↑", "↓"])
        await t.equal("앱 메뉴 · 기본 메뉴 · 화면 안 단축키 겹침 없음 (강도 키 포함)",
                      MenuShortcut.conflicts(MenuShortcut.appMenu + MenuShortcut.system + MenuShortcut.inView).count, 0)
    }

    // MARK: 저장 순서 (실제 임시 DB)

    /// 모델 행을 누르고 곧바로 강도를 바꿔도 방금 고른 모델이 남고, 실행을 보낸 뒤의 기록이 그 사이 바꾼 선택을 되돌리지 않는다.
    @MainActor
    static func selectionOrdering(_ t: TestKit) async {
        await t.group("선택 저장 순서 · 실행 뒤 기록")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ahc-composer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = Store(databaseURL: dir.appendingPathComponent("db.sqlite3"))
        guard (try? await store.bootstrap()) != nil else {
            await t.check("임시 DB 준비", false)
            return
        }
        let project = Project(name: "composer", path: dir.path)
        var thread = ConversationThread(projectID: project.id, title: "새 스레드")
        thread.claudeSelection = ModelSelection(model: nil, effort: "max")
        guard (try? await store.upsertProject(project)) != nil, (try? await store.upsertThread(thread)) != nil else {
            await t.check("임시 스레드 준비", false)
            return
        }
        func stored() async -> ConversationThread? { (try? await store.thread(id: thread.id)) ?? nil }

        // 실행을 보낸 뒤: 자리표시 제목 → 제안 제목, 비어 있던 모델 채움, 강도는 그대로
        try? await store.recordThreadSend(id: thread.id, provider: .claude, onlyIfProviderWas: .claude, placeholderTitle: "첫 요청",
                                          filledModel: "opus", codexAccountID: nil)
        let first = await stored()
        await t.check("보낸 뒤: 제목 · 비어 있던 모델만 채움, 강도 그대로",
                      first?.title == "첫 요청" && first?.claudeSelection.model == "opus" && first?.claudeSelection.effort == "max"
                        && first?.preferredProvider == .claude,
                      "\(first?.title ?? "") \(first?.claudeSelection.model ?? "nil") \(first?.claudeSelection.effort ?? "nil")")
        // 시작하는 동안 사용자가 모델 · 강도를 바꿨다 (DB 에 새 값) → 보낸 뒤 기록이 옛 값으로 되돌리지 않는다
        if var changed = first {
            changed.claudeSelection = ModelSelection(model: "sonnet", effort: "low")
            try? await store.upsertThread(changed)
        }
        try? await store.recordThreadSend(id: thread.id, provider: .claude, onlyIfProviderWas: .claude, placeholderTitle: "다른 제목",
                                          filledModel: "opus", codexAccountID: nil)
        let second = await stored()
        await t.check("시작 중에 바꾼 모델 · 강도 유지, 자리표시가 아닌 제목 유지",
                      second?.claudeSelection.model == "sonnet" && second?.claudeSelection.effort == "low" && second?.title == "첫 요청",
                      "\(second?.claudeSelection.model ?? "nil") \(second?.claudeSelection.effort ?? "nil") \(second?.title ?? "")")
        try? await store.recordThreadSend(id: thread.id, provider: .codex, onlyIfProviderWas: nil, placeholderTitle: nil,
                                          filledModel: nil, codexAccountID: nil)
        let third = await stored()
        await t.check("계정을 주지 않으면 그대로 · 보낸 에이전트는 바뀜",
                      third?.codexAccountID == CodexAccount.defaultID && third?.preferredProvider == .codex)
        try? await store.recordThreadSend(id: thread.id, provider: .codex, onlyIfProviderWas: nil, placeholderTitle: nil,
                                          filledModel: nil, codexAccountID: "acc-2")
        await t.equal("인계로 옮긴 계정", await stored()?.codexAccountID ?? "", "acc-2")
        // 시작하는 동안 사용자가 에이전트 토글을 눌렀다 (codex → gemini): 보낸 뒤 기록은 시작 때 값(codex)이 아니므로 바꾸지 않는다
        if var toggled = await stored() {
            toggled.preferredProvider = .gemini
            try? await store.upsertThread(toggled)
        }
        try? await store.recordThreadSend(id: thread.id, provider: .codex, onlyIfProviderWas: .codex, placeholderTitle: nil,
                                          filledModel: nil, codexAccountID: nil)
        await t.check("시작 중에 누른 에이전트 토글 유지", await stored()?.preferredProvider == .gemini)
        // Codex 열만 채우고 다른 열 · 강도 열은 그대로, Claude 의 'default' 는 채움 대상
        if var reset = await stored() {
            reset.codexSelection = ModelSelection(model: nil, effort: "high")
            reset.claudeSelection = ModelSelection(model: "default", effort: "low")
            try? await store.upsertThread(reset)
        }
        try? await store.recordThreadSend(id: thread.id, provider: .codex, onlyIfProviderWas: nil, placeholderTitle: nil,
                                          filledModel: "gpt-6-astra", codexAccountID: nil)
        let columns = await stored()
        await t.check("Codex 열만 채움 · 강도 열 그대로",
                      columns?.codexSelection == ModelSelection(model: "gpt-6-astra", effort: "high")
                        && columns?.claudeSelection == ModelSelection(model: "default", effort: "low"),
                      "\(String(describing: columns?.codexSelection)) \(String(describing: columns?.claudeSelection))")
        try? await store.recordThreadSend(id: thread.id, provider: .claude, onlyIfProviderWas: nil, placeholderTitle: nil,
                                          filledModel: "opus", codexAccountID: nil)
        await t.equal("Claude 의 'default' 는 채움 대상", await stored()?.claudeSelection.model ?? "", "opus")
        // 메모리 규칙(ConversationThread.recordSend)이 Store 와 같은지
        var mirror = ConversationThread(projectID: project.id, title: "새 대화")
        mirror.preferredProvider = .claude
        mirror.codexSelection = ModelSelection(model: "default", effort: "max")
        mirror.recordSend(provider: .codex, onlyIfProviderWas: .claude, placeholderTitle: "제안", filledModel: "gpt-5.5",
                          codexAccountID: nil)
        await t.check("메모리 규칙: 에이전트 · 자리표시 제목 · 'default' 채움 · 강도 그대로",
                      mirror.preferredProvider == .codex && mirror.title == "제안"
                        && mirror.codexSelection == ModelSelection(model: "gpt-5.5", effort: "max"))
        mirror.recordSend(provider: .gemini, onlyIfProviderWas: .claude, placeholderTitle: "또", filledModel: "gemini-3.8-flash",
                          codexAccountID: "acc-9")
        await t.check("메모리 규칙: 시작 때 에이전트가 아니면 유지 · 자리표시 아닌 제목 유지 · 계정은 준 값",
                      mirror.preferredProvider == .codex && mirror.title == "제안" && mirror.codexAccountID == "acc-9"
                        && mirror.geminiSelection.model == "gemini-3.8-flash")

        // 앱 모델: 모델 행 → 곧바로 강도 (두 Task 를 기다리지 않고 만든 순서대로) — 강도 쪽이 옛 모델로 덮지 않는다
        let model = AppModel(store: store)
        await model.reloadProjects()
        await model.selectThread(thread.id)
        let pickModel = Task { await model.setModelSelection(ModelSelection(model: "haiku", effort: nil), for: .claude) }
        let pickEffort = Task { await model.setEffort("xhigh", for: .claude) }
        await pickModel.value
        await pickEffort.value
        let memory = model.selectedThread?.claudeSelection
        let saved = await stored()?.claudeSelection
        await t.check("모델을 고르고 곧바로 강도: 방금 고른 모델이 남음 (메모리 · DB)",
                      memory == ModelSelection(model: "haiku", effort: "xhigh") && saved == memory,
                      "메모리 \(String(describing: memory)) · DB \(String(describing: saved))")
        let toNil = Task { await model.setEffort(nil, for: .claude) }
        await toNil.value
        await t.check("CLI 기본값으로 되돌리면 강도만 nil (모델 유지)",
                      await stored()?.claudeSelection == ModelSelection(model: "haiku", effort: nil))

        // 보낸 뒤 기록과 강도 변경이 겹쳐도 (만든 순서대로, 기다리지 않고) 둘 다 남는다 — 강도 쪽 행 전체 저장이 기록을 되돌리지 않게
        if var placeholder = await stored() {
            placeholder.title = "새 스레드"
            placeholder.codexSelection = ModelSelection()
            try? await store.upsertThread(placeholder)
            await model.reloadProjects()
        }
        let sendRecord = Task {
            await model.recordThreadSend(thread, provider: .codex, onlyIfProviderWas: nil, placeholderTitle: "보낸 요청",
                                         filledModel: "gpt-5.6-sol", codexAccountID: nil)
        }
        let effortDuring = Task { await model.setEffort("max", for: .claude) }
        await sendRecord.value
        await effortDuring.value
        let both = await stored()
        await t.check("보낸 뒤 기록(제목 · 채운 모델) + 겹친 강도 변경 둘 다 남음 (DB · 메모리)",
                      both?.title == "보낸 요청" && both?.codexSelection.model == "gpt-5.6-sol" && both?.claudeSelection.effort == "max"
                        && model.selectedThread?.title == "보낸 요청" && model.selectedThread?.claudeSelection.effort == "max",
                      "\(both?.title ?? "") \(both?.codexSelection.model ?? "nil") \(both?.claudeSelection.effort ?? "nil")")

        // 빠른 연속 변경: 늦게 끝난 앞 쓰기의 다시 읽기가 뒤 값을 되돌리지 않고, 끝나면 메모리 = DB = 마지막 값
        let sequence = ["low", "medium", "high", "xhigh", "max", "high", "low"]
        var writes: [Task<Void, Never>] = []
        for effort in sequence { writes.append(Task { await model.setEffort(effort, for: .claude) }) }
        for write in writes { await write.value }
        let finalMemory = model.selectedThread?.claudeSelection.effort
        let finalStored = await stored()?.claudeSelection.effort
        await t.check("빠른 연속 강도 변경 뒤 메모리 = DB = 마지막 값",
                      finalMemory == "low" && finalStored == "low", "\(finalMemory ?? "nil") · \(finalStored ?? "nil")")
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Antigravity 보내기 막힘 (실제 임시 DB · agy 를 부르지 않음)

    /// agy 가 거부할 조합은 입력창 보내기 · RunCoordinator · 인계 전송이 모두 **프로세스를 띄우기 전에** 막고, 흔적을 남기지 않는다.
    /// 막히는 경로는 CLI 확인(`agy --version`)보다 앞이라 이 검증은 agy 를 부르지 않는다.
    @MainActor
    static func antigravitySendBlock(_ t: TestKit) async {
        await t.group("Antigravity 보내기 막힘 (agy 호출 없음)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ahc-agy-block-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(databaseURL: dir.appendingPathComponent("db.sqlite3"))
        guard (try? await store.bootstrap()) != nil else {
            await t.check("임시 DB 준비", false)
            return
        }
        let options = ModelCatalog.parseGeminiModelResponse(GeminiAssistTests.agyModels20260914,
                                                            into: ModelCatalogSnapshot(provider: .gemini)).options
        let project = Project(name: "agy-block", path: dir.path)
        var thread = ConversationThread(projectID: project.id, title: "새 스레드")
        thread.preferredProvider = .gemini
        // High 가 없는 모델 + 강도를 고르지 않음 → 기본값(High)을 넘길 수 없다.
        thread.geminiSelection = ModelSelection(model: "gpt-oss-120b", effort: nil)
        guard (try? await store.upsertProject(project)) != nil, (try? await store.upsertThread(thread)) != nil,
              (try? await store.replaceModelOptions(options, scope: .gemini)) != nil else {
            await t.check("임시 스레드 · 모델 목록 준비", false)
            return
        }
        let model = AppModel(store: store)
        // 실행할 수 없는 경로로 막아 둔다 — 판정이 CLI 확인(`agy --version`)보다 뒤로 밀리면 "CLI 를 실행할 수 없음" 으로 실패하고,
        // 판정이 잘못 보내기로 바뀌어도 이 Mac 의 실제 agy 에 닿지 않는다.
        await model.environment.setOverrides(CLIEnvironment.Override(geminiPath: dir.appendingPathComponent("agy-absent").path))
        await model.reloadProjects()
        await model.loadModelCatalogs()
        await model.selectThread(thread.id)
        model.setAntigravityAllowed(true, projectID: project.id)

        let accepted = await model.send("안녕", provider: .gemini, threadID: thread.id)
        let bannerText = model.banner?.text ?? ""
        await t.check("입력창 보내기: 막고 이유를 배너로", !accepted && model.banner?.isError == true
                        && bannerText.contains("기본값 High 가 없어"), bannerText)
        let runsAfterSend = (try? await store.runs(threadID: thread.id)) ?? []
        let eventsAfterSend = (try? await store.events(threadID: thread.id)) ?? []
        await t.check("막힌 보내기는 실행 · 사용자 메시지를 남기지 않음", runsAfterSend.isEmpty && eventsAfterSend.isEmpty,
                      "실행 \(runsAfterSend.count) · 이벤트 \(eventsAfterSend.count)")
        await t.equal("판정은 같은 이유", model.antigravityBlock(for: thread),
                      .noHigh(model: "gpt-oss-120b", available: ["medium"], ultra: false))

        // RunCoordinator 를 직접 불러도 (인계 등 AppModel.send 를 거치지 않는 길) 같은 판정으로 막는다.
        var coordinatorError: Error?
        do {
            _ = try await model.runner.send(prompt: "안녕", thread: thread, project: project, provider: .gemini)
        } catch { coordinatorError = error }
        await t.check("RunCoordinator.send 도 CLI 를 부르기 전에 막음",
                      (coordinatorError as? RunCoordinator.StartError).map {
                          if case .antigravityBlocked(.noHigh) = $0 { return true } else { return false }
                      } ?? false, String(describing: coordinatorError))
        await t.check("RunCoordinator 가 막아도 실행 행 없음", ((try? await store.runs(threadID: thread.id)) ?? []).isEmpty)

        // 인계 전송: "전송 중" · 인계 전송 기록을 남기기 전에 막고, 인계는 다시 보낼 수 있는 초안 그대로.
        let handoff = Handoff(threadID: thread.id, fromProvider: .claude, toProvider: .gemini, baseSeq: 0,
                              draftJSON: "{}", finalText: "인계 본문")
        try? await store.insertHandoff(handoff)
        var deliverError: Error?
        do {
            _ = try await model.runner.deliver(handoff: handoff, thread: thread, project: project)
        } catch { deliverError = error }
        let storedHandoff = ((try? await store.handoffs(threadID: thread.id)) ?? []).first { $0.id == handoff.id }
        await t.check("인계 전송도 막음 — 초안 그대로 (다시 보낼 수 있음)",
                      deliverError != nil && storedHandoff?.deliveryState == .draft,
                      "\(String(describing: deliverError)) · \(storedHandoff?.deliveryState.koreanName ?? "없음")")
        await t.check("막힌 인계는 '인계 전송' 기록을 남기지 않음",
                      !((try? await store.events(threadID: thread.id)) ?? []).contains { $0.kind == .handoffSent })

        // 강도를 고르면 막히지 않는다 (판정만 — 실제 전송은 agy 를 부르므로 여기서 하지 않는다).
        var fixed = thread
        fixed.geminiSelection = ModelSelection(model: "gpt-oss-120b", effort: "medium")
        await t.check("강도를 고르면 막히지 않음", model.antigravityBlock(for: fixed) == nil)
        fixed.geminiSelection = ModelSelection(model: nil, effort: nil)
        await t.check("새 스레드(모델 · 강도 없음)는 기본 모델 + High 로 막히지 않음", model.antigravityBlock(for: fixed) == nil)
    }

    // MARK: Antigravity 요청 조립 (가짜 agy — 실제 CLI 를 부르지 않음)

    /// 실제 `AppModel.send` · `RunCoordinator.send` · 인계 전송이 agy 에 넘기는 인수 · 입력을 가짜 agy 스크립트로 받아 본다.
    /// 스크립트는 받은 인수 · stdin 을 파일로 남기고 stream-json 의 init · result 한 줄씩만 낸다 (모델 호출 없음, `models` 는 실패).
    @MainActor
    static func antigravityRequests(_ t: TestKit) async {
        await t.group("Antigravity 요청 조립 · 인계 (가짜 agy)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ahc-agy-stub-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent("bin")
        let work = dir.appendingPathComponent("work")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = bin.appendingPathComponent("agy")
        let script = """
        #!/bin/sh
        dir="$(cd "$(dirname "$0")" && pwd)"
        case "$1" in
          --version) echo "1.2.2-stub"; exit 0 ;;
          models)
            echo x >> "$dir/models-calls"
            if [ -f "$dir/slow-models" ]; then sleep 2; cat "$dir/models.txt"; exit 0; fi
            echo "stub: models 실패" >&2; exit 1 ;;
        esac
        n=$(ls "$dir" | grep -c '^argv-')
        n=$((n + 1))
        for a in "$@"; do printf '%s\\n' "$a"; done > "$dir/argv-$n.txt"
        IFS= read -r line
        printf '%s\\n' "$line" > "$dir/stdin-$n.txt"
        echo '{"event":"init","conversation_id":"stub-'$n'","init":{"model":"stub"}}'
        echo '{"event":"result","result":{"status":"SUCCESS","response":"ok","conversation_id":"stub-'$n'"}}'
        """
        let store = Store(databaseURL: dir.appendingPathComponent("db.sqlite3"))
        guard (try? script.write(to: stub, atomically: true, encoding: .utf8)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)) != nil,
              (try? GeminiAssistTests.agyModels20260914.write(to: bin.appendingPathComponent("models.txt"),
                                                              atomically: true, encoding: .utf8)) != nil,
              (try? await store.bootstrap()) != nil else {
            await t.check("가짜 agy · 임시 DB 준비", false)
            return
        }
        let options = ModelCatalog.parseGeminiModelResponse(GeminiAssistTests.agyModels20260914,
                                                            into: ModelCatalogSnapshot(provider: .gemini)).options
        let project = Project(name: "agy-stub", path: work.path)
        func thread(_ title: String, from provider: AgentProvider, _ selection: ModelSelection) -> ConversationThread {
            var thread = ConversationThread(projectID: project.id, title: title)
            thread.preferredProvider = provider
            thread.geminiSelection = selection
            return thread
        }
        let newThread = thread("새 스레드", from: .gemini, ModelSelection(model: nil, effort: nil))
        let ultraThread = thread("ULTRA", from: .gemini, ModelSelection(model: "gemini-3.8-flash", effort: "boost"))
        let handoffThread = thread("인계", from: .claude, ModelSelection(model: nil, effort: nil))
        let blockedThread = thread("막힌 인계", from: .claude, ModelSelection(model: "gpt-oss-120b", effort: nil))
        let cancelThread = thread("취소한 인계", from: .claude, ModelSelection(model: nil, effort: nil))
        let otherThread = thread("다른 스레드", from: .gemini, ModelSelection(model: "gemini-3.8-flash", effort: nil))
        guard (try? await store.upsertProject(project)) != nil,
              (try? await store.replaceModelOptions(options, scope: .gemini)) != nil else {
            await t.check("임시 프로젝트 · 모델 목록 준비", false)
            return
        }
        for thread in [newThread, ultraThread, handoffThread, blockedThread, cancelThread, otherThread] {
            try? await store.upsertThread(thread)
        }
        // 인계는 기록(실행)이 있는 대화만 한다 — 인계 시험의 대화에는 Claude 가 한 턴 일한 기록을 넣는다.
        for thread in [handoffThread, blockedThread, cancelThread] {
            try? await store.insertRun(Run(threadID: thread.id, sessionID: "s", provider: .claude, requestText: "첫 일",
                                           state: .completed, startedAt: Date().addingTimeInterval(-60), endedAt: Date()))
            _ = try? await store.appendEvent(ThreadEvent(threadID: thread.id, kind: .userMessage, title: "사용자",
                                                         text: "README 를 정리해 줘."))
        }

        let model = AppModel(store: store)
        await model.environment.setOverrides(CLIEnvironment.Override(geminiPath: stub.path))
        await model.reloadProjects()
        await model.loadModelCatalogs()
        model.setAntigravityAllowed(true, projectID: project.id)

        func waitIdle() async -> Bool {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if !model.runner.isBusy && model.runner.activeRun == nil && !model.isStartingRun { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return false
        }
        func argv(_ n: Int) -> [String] {
            ((try? String(contentsOf: bin.appendingPathComponent("argv-\(n).txt"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        func value(_ args: [String], _ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        func content(_ n: Int) -> String? {
            let line = (try? String(contentsOf: bin.appendingPathComponent("stdin-\(n).txt"), encoding: .utf8)) ?? ""
            let message = JSONUtil.object(line.trimmingCharacters(in: .whitespacesAndNewlines))?["message"] as? [String: Any]
            return message?["content"] as? String
        }
        func stored(_ id: String) async -> ConversationThread? { (try? await store.thread(id: id)) ?? nil }

        // 1) 입력창 보내기 · 새 스레드 (모델 · 강도를 고르지 않음) → 기본 모델 + High, 그 모델을 스레드에 남긴다
        await model.selectThread(newThread.id)
        let accepted = await model.send("안녕", provider: .gemini, threadID: newThread.id)
        let settled1 = await waitIdle()
        let args1 = argv(1)
        await t.check("입력창 보내기: 새 스레드 → --model gemini-3.8-flash --effort high", accepted && settled1
                        && value(args1, "--model") == "gemini-3.8-flash" && value(args1, "--effort") == "high",
                      "\(args1)")
        await t.equal("입력창 보내기: 프롬프트 그대로 (ULTRA 아님)", content(1) ?? "없음", "안녕")
        let newStored = await stored(newThread.id)
        await t.check("보낸 모델을 스레드에 남기고 강도는 기본값(nil) 그대로",
                      newStored?.geminiSelection == ModelSelection(model: "gemini-3.8-flash", effort: nil),
                      String(describing: newStored?.geminiSelection))

        // 2) RunCoordinator 직접 · ULTRA → --effort high + 프롬프트 앞 /boost, 실행 머리 · 기록 문구
        var ultraError: Error?
        do {
            _ = try await model.runner.send(prompt: "안녕", thread: ultraThread, project: project, provider: .gemini)
        } catch { ultraError = error }
        // 보낸 직후(메인 액터를 넘기기 전)의 실행 상태 — 실행 머리가 읽는 값
        let liveSelection = model.runner.activeSelection
        let liveMeta = EffortScale.runMeta(effort: liveSelection?.effort, boost: model.runner.activeBoost)?.text
        await t.check("ULTRA 실행 중 머리: ULTRA · High + /boost",
                      ultraError == nil && liveSelection == ModelSelection(model: "gemini-3.8-flash", effort: "high")
                        && liveMeta == "ULTRA · High + /boost",
                      "\(String(describing: ultraError)) · \(String(describing: liveSelection)) · \(liveMeta ?? "없음")")
        let settled2 = await waitIdle()
        let args2 = argv(2)
        await t.check("ULTRA: --model gemini-3.8-flash --effort high (boost 는 인수가 아님)", settled2
                        && value(args2, "--model") == "gemini-3.8-flash" && value(args2, "--effort") == "high"
                        && !args2.contains("boost"), "\(args2)")
        await t.equal("ULTRA: 프롬프트 앞 /boost", content(2) ?? "없음", "/boost 안녕")
        let ultraEvents = (try? await store.events(threadID: ultraThread.id)) ?? []
        await t.check("ULTRA 로 보낸 값을 대화에 남김", ultraEvents.contains {
            $0.kind == .systemNotice && $0.text.contains("ULTRA 로 보냈습니다 (--effort high + 프롬프트 앞 /boost).")
        })
        await t.check("실행이 끝나면 실행 머리 값을 비움", model.runner.activeSelection == nil && !model.runner.activeBoost)

        // 3) 인계 · Antigravity 선택이 비어 있음 → 인계도 기본 모델 + High, 전달이 확인되면 그 모델을 스레드에 남긴다
        await model.selectThread(handoffThread.id)
        await model.prepareHandoff(to: .gemini)
        if let draft = model.handoffCards[handoffThread.id]?.draft {
            await t.check("인계 카드: 보낼 수 있으면 막힘 없음", model.handoffBlockReason(threadID: handoffThread.id) == nil,
                          model.handoffBlockReason(threadID: handoffThread.id) ?? "")
            model.setHandoffConfirmed(true, threadID: handoffThread.id)
            await model.sendHandoff(threadID: handoffThread.id)
            var settled3 = await waitIdle()
            for _ in 0..<100 where model.deliveringHandoffs[handoffThread.id] != nil {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            settled3 = settled3 && model.deliveringHandoffs[handoffThread.id] == nil
            let args3 = argv(3)
            await t.check("인계 전송: --model gemini-3.8-flash --effort high", settled3
                            && value(args3, "--model") == "gemini-3.8-flash" && value(args3, "--effort") == "high",
                          "\(args3)")
            await t.check("인계 본문은 /boost 없이", !(content(3) ?? "/boost").hasPrefix("/boost"))
            let handoffStored = await stored(handoffThread.id)
            await t.equal("인계로 보낸 모델도 (전달이 확인되면) 스레드에 남김", handoffStored?.geminiSelection.model ?? "nil", "gemini-3.8-flash")
            let sentHandoff = ((try? await store.handoffs(threadID: handoffThread.id)) ?? []).first { $0.id == draft.handoff.id }
            await t.check("인계가 초안에서 벗어남 (전송함)", sentHandoff.map { $0.deliveryState != .draft } ?? false,
                          sentHandoff?.deliveryState.koreanName ?? "없음")
        } else {
            await t.check("인계 초안 만들기", false, model.banner?.text ?? "")
        }

        // 4) 인계 · 막히는 선택 → 카드에 막힘 이유, 넘기기를 눌러도 흔적 없이 (가짜 agy 도 부르지 않음) — 이유는 그 카드의 오류로
        await model.selectThread(blockedThread.id)
        await model.prepareHandoff(to: .gemini)
        if let draft = model.handoffCards[blockedThread.id]?.draft {
            let reason = model.handoffBlockReason(threadID: blockedThread.id) ?? ""
            await t.check("인계 카드: 막히는 이유를 카드 안에", reason.contains("기본값 High 가 없어"), reason)
            model.banner = nil
            model.setHandoffConfirmed(true, threadID: blockedThread.id)
            await model.sendHandoff(threadID: blockedThread.id)
            // 보낸 것이 없으니 실패 카드가 아니다 — 넘길 수 있는 카드로 돌아오고, 지금의 막힘은 카드 바닥의 막힘 줄이 말한다
            // (현재형 막힘을 실패 이유로 굳히면 막힘이 풀린 뒤에도 남는다).
            let cardBlock = model.handoffBlockReason(threadID: blockedThread.id) ?? ""
            let blockedCard = model.handoffCards[blockedThread.id]
            await t.check("인계 넘기기: 막고 이유를 그 카드에 (전역 배너가 아니라)",
                          cardBlock.contains("기본값 High 가 없어") && blockedCard?.phase == .ready && blockedCard?.lastError == nil
                            && model.banner == nil, cardBlock)
            let blockedHandoff = ((try? await store.handoffs(threadID: blockedThread.id)) ?? []).first { $0.id == draft.handoff.id }
            let blockedEvents = (try? await store.events(threadID: blockedThread.id)) ?? []
            await t.check("막힌 인계: 행 없음 · 인계 전송 기록 없음 · agy 를 부르지 않음",
                          (blockedHandoff == nil || blockedHandoff?.deliveryState == .draft)
                            && !blockedEvents.contains { $0.kind == .handoffSent }
                            && !FileManager.default.fileExists(atPath: bin.appendingPathComponent("argv-4.txt").path),
                          blockedHandoff?.deliveryState.koreanName ?? "없음")
            // 목록을 한 번도 조회하지 않았으면 적지 않고(넘기기가 조회한다), 조회했는데 못 읽었으면 카드에 적는다
            let saved = model.modelCatalogs[.gemini]
            model.modelCatalogs[.gemini] = nil
            let neverFetched = model.handoffBlockReason(threadID: blockedThread.id)
            var failed = ModelCatalogSnapshot(provider: .gemini)
            failed.discovered = false
            model.modelCatalogs[.gemini] = failed
            let fetchFailed = model.handoffBlockReason(threadID: blockedThread.id) ?? ""
            model.modelCatalogs[.gemini] = saved
            await t.check("인계 카드: 목록을 조회한 적 없으면 이유 없음 · 조회했는데 못 읽었으면 이유",
                          neverFetched == nil && fetchFailed.contains("목록을 확인하지 못해"), fetchFailed)
            model.cancelHandoff(threadID: blockedThread.id, origin: .card)
        } else {
            await t.check("막힌 인계 초안 만들기", false, model.banner?.text ?? "")
        }

        // 5) 목록 조회 실패 → 받아 둔 목록을 비우지 않는다 (DB 와 같은 목록으로 판정, 새 스레드는 계속 보낼 수 있다)
        let before = model.modelCatalogs[.gemini]
        await model.refreshModelCatalog(.gemini)
        let after = model.modelCatalogs[.gemini]
        let storedOptions = (try? await store.modelOptions(scope: .gemini)) ?? []
        await t.check("조회 실패: 이전 목록 유지 · 실패 표시", after?.options == before?.options && after?.discovered == false
                        && (after?.message ?? "").contains("이전에 조회한 목록"), after?.message ?? "")
        await t.check("조회 실패: DB 목록 · 조회 시각 그대로 (다음 기회에 다시 조회)",
                      storedOptions.map(\.identifier) == options.map(\.identifier) && after?.fetchedAt == before?.fetchedAt)
        var fresh = newThread
        fresh.geminiSelection = ModelSelection(model: nil, effort: nil)
        await t.check("조회 실패 뒤에도 새 스레드는 보낼 수 있음", model.antigravityBlock(for: fresh) == nil)

        // 6) 받는 모델 칩은 그 칩이 그리는 스레드를 바꾼다 — 지금 고른 스레드가 다른 스레드여도
        await model.selectThread(otherThread.id)
        await model.setEffort("low", for: .gemini, threadID: blockedThread.id)
        await model.setModelSelection(ModelSelection(model: "gpt-oss-120b", effort: "medium"), for: .gemini,
                                      threadID: cancelThread.id)
        let blockedAfter = await stored(blockedThread.id)
        let cancelAfter = await stored(cancelThread.id)
        let otherAfter = await stored(otherThread.id)
        await t.check("스레드를 지정한 강도 · 모델 변경은 그 스레드만 (지금 고른 스레드는 그대로)",
                      blockedAfter?.geminiSelection == ModelSelection(model: "gpt-oss-120b", effort: "low")
                        && cancelAfter?.geminiSelection == ModelSelection(model: "gpt-oss-120b", effort: "medium")
                        && otherAfter?.geminiSelection == ModelSelection(model: "gemini-3.8-flash", effort: nil)
                        && model.selectedThread?.geminiSelection == ModelSelection(model: "gemini-3.8-flash", effort: nil),
                      "\(String(describing: blockedAfter?.geminiSelection)) · \(String(describing: otherAfter?.geminiSelection))")
        // 되돌려 둔다 (아래 7 에서 새 스레드처럼 쓴다)
        await model.setModelSelection(ModelSelection(model: nil, effort: nil), for: .gemini, threadID: cancelThread.id)

        // 7) 조회가 도는 중(목록 없음)에 보내면 "못 읽음" · "모델을 고르세요" 가 아니라 그 조회를 기다렸다가 보낸다 (onb-1 — 같은
        //    범위의 조회는 하나만 돈다). 기다리는 동안 입력창은 "모델 목록을 확인하는 중" (`sendingThreads`).
        let savedCatalog = model.modelCatalogs[.gemini]
        model.modelCatalogs[.gemini] = nil
        model.banner = nil
        let slow = bin.appendingPathComponent("slow-models")
        FileManager.default.createFile(atPath: slow.path, contents: nil)
        let turnsBefore7 = ((try? FileManager.default.contentsOfDirectory(atPath: bin.path)) ?? []).filter { $0.hasPrefix("argv-") }.count
        func modelsCalls() -> Int {
            ((try? String(contentsOf: bin.appendingPathComponent("models-calls"), encoding: .utf8)) ?? "").split(separator: "\n").count
        }
        let callsBefore7 = modelsCalls()
        let refreshing = Task { await model.refreshModelCatalog(.gemini) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let sendWhileRefreshing = Task { await model.send("안녕", provider: .gemini, threadID: otherThread.id) }
        try? await Task.sleep(nanoseconds: 600_000_000)
        let stageWhileWaiting = model.sendingThreads[otherThread.id]
        let joinedRefresh = model.refreshingModels.contains(.gemini)
        let whileRefreshing = await sendWhileRefreshing.value
        await refreshing.value
        try? FileManager.default.removeItem(at: slow)
        _ = await waitIdle()
        let turnsAfter7 = ((try? FileManager.default.contentsOfDirectory(atPath: bin.path)) ?? []).filter { $0.hasPrefix("argv-") }.count
        await t.check("조회 중 보내기: 막지 않고 그 조회를 기다렸다가 보낸다 (오류 안내 없음 · 턴 하나)",
                      whileRefreshing && model.banner == nil && turnsAfter7 == turnsBefore7 + 1,
                      "\(whileRefreshing) · \(model.banner?.text ?? "배너 없음") · 턴 \(turnsBefore7)→\(turnsAfter7)")
        await t.check("기다리는 동안 입력창은 '모델 목록을 확인하는 중' · 조회는 하나만 돈다",
                      stageWhileWaiting == .checkingModels && joinedRefresh && !model.refreshingModels.contains(.gemini)
                        && modelsCalls() == callsBefore7 + 1,
                      "\(String(describing: stageWhileWaiting)) · 조회 \(modelsCalls() - callsBefore7)번")

        // 8) 인계를 넘겨 목록을 조회하는 사이(느린 agy models) — 넘기기는 보내는 중이라 취소를 받지 않고, 조회가 끝나면 보낸다
        await model.selectThread(cancelThread.id)
        model.modelCatalogs[.gemini] = savedCatalog
        await model.prepareHandoff(to: .gemini)
        if let draft = model.handoffCards[cancelThread.id]?.draft {
            model.modelCatalogs[.gemini] = nil   // 한 번도 조회하지 않은 상태 — 넘기기가 조회한다
            FileManager.default.createFile(atPath: bin.appendingPathComponent("slow-models").path, contents: nil)
            let turnsBefore = ((try? FileManager.default.contentsOfDirectory(atPath: bin.path)) ?? [])
                .filter { $0.hasPrefix("argv-") }.count
            await t.check("조회 전: 카드에 막힘 없음 (넘기기가 조회한다)", model.handoffBlockReason(threadID: cancelThread.id) == nil)
            model.setHandoffConfirmed(true, threadID: cancelThread.id)
            let sending = Task { await model.sendHandoff(threadID: cancelThread.id) }
            try? await Task.sleep(nanoseconds: 600_000_000)
            let wasSending = model.handoffCards[cancelThread.id]?.isSending == true
            let refused = !model.cancelHandoff(threadID: cancelThread.id, origin: .card)
            await sending.value
            try? FileManager.default.removeItem(at: bin.appendingPathComponent("slow-models"))
            _ = await waitIdle()
            for _ in 0..<100 where model.deliveringHandoffs[cancelThread.id] != nil {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let turnsAfter = ((try? FileManager.default.contentsOfDirectory(atPath: bin.path)) ?? [])
                .filter { $0.hasPrefix("argv-") }.count
            let sent = ((try? await store.handoffs(threadID: cancelThread.id)) ?? []).first { $0.id == draft.handoff.id }
            await t.check("조회하는 동안 카드는 보내는 중 — 취소를 받지 않는다 (되돌릴 수 없는 지점)", wasSending && refused)
            await t.check("조회가 끝나면 넘긴다 (agy 턴 하나 · 전달)", turnsAfter == turnsBefore + 1 && sent?.deliveryState == .delivered,
                          "턴 \(turnsBefore)→\(turnsAfter) · \(sent?.deliveryState.koreanName ?? "없음")")
            await t.equal("그 사이 끝난 조회의 목록은 받는다", model.modelCatalogs[.gemini]?.options.count ?? 0, options.count)
        } else {
            await t.check("넘길 인계 초안 만들기", false, model.banner?.text ?? "")
        }

        // 9) 인계는 판정을 한 번만 해 send 에 넘긴다 — 넘긴 값으로 보낸다 (그 사이 목록 · 선택이 바뀌어도)
        var planned: Error?
        do {
            _ = try await model.runner.send(prompt: "안녕", thread: otherThread, project: project, provider: .gemini,
                                            antigravity: AntigravityAdapter.TurnPlan(model: "gemini-3.7-flash",
                                                                                     effort: "low", boost: false))
        } catch { planned = error }
        let settled9 = await waitIdle()
        let turns = ((try? FileManager.default.contentsOfDirectory(atPath: bin.path)) ?? []).filter { $0.hasPrefix("argv-") }
        let args9 = argv(turns.count)
        await t.check("넘긴 판정으로 보냄 (스레드 선택 gemini-3.8-flash 가 아니라 3.7 Flash · Low)", planned == nil && settled9
                        && value(args9, "--model") == "gemini-3.7-flash" && value(args9, "--effort") == "low", "\(args9)")
    }
}

// MARK: - 모델 · 강도 기본값 · 입력창 규칙 (G3)

extension ComposerTests {

    /// 새 대화 · 처음 쓰는 에이전트의 모델 기본값: 이어받기 → Codex 는 config.toml → CLI 기본 (사용자 결정 2026-10-04).
    static func modelDefaults(_ t: TestKit) async {
        await t.group("모델 기본값: 이어받기 · config.toml · CLI 기본")
        let toml = """
        # 사용자의 Codex 설정
        model = "gpt-6.1-sol"   # 주석
        model_reasoning_effort = 'xhigh'
        notes = \"\"\"
        model = "속지 않는다"
        \"\"\"

        [profiles.fast]
        model = "gpt-6-luna"
        model_reasoning_effort = "low"
        """
        await t.equal("config.toml: 최상위 model · 강도 (주석 · 따옴표 · 여러 줄 문자열 · 표는 건너뜀)",
                      CodexConfigDefaults.parse(toml), CodexConfigDefaults(model: "gpt-6.1-sol", effort: "xhigh"))
        await t.equal("config.toml: profile 이 있으면 그 프로필의 값",
                      CodexConfigDefaults.parse("profile = \"fast\"\n" + toml), CodexConfigDefaults(model: "gpt-6-luna", effort: "low"))
        await t.equal("config.toml: 없으면 빈 값", CodexConfigDefaults.parse(nil), CodexConfigDefaults())
        await t.equal("config.toml: 표 안의 model 은 최상위가 아니다",
                      CodexConfigDefaults.parse("[mcp_servers.x]\nmodel = \"x\""), CodexConfigDefaults())

        // 이어받기
        let now = Date()
        func thread(_ id: String, project: String, uses provider: AgentProvider, codex: ModelSelection = ModelSelection(),
                    ago: TimeInterval) -> ConversationThread {
            var made = ConversationThread(projectID: project, title: id)
            made.id = id
            made.preferredProvider = provider
            made.codexSelection = codex
            made.updatedAt = now.addingTimeInterval(-ago)
            return made
        }
        var inner = thread("inner", project: "P", uses: .codex, codex: ModelSelection(model: "gpt-6-astra", effort: "ultra"), ago: 0)
        inner.orchestrationJobID = "job"
        let threads: [ConversationThread] = [
            thread("a", project: "P", uses: .codex, codex: ModelSelection(model: "gpt-6-luna", effort: "low"), ago: 60),
            thread("b", project: "Q", uses: .codex, codex: ModelSelection(model: "gpt-6-sol", effort: "high"), ago: 10),
            thread("c", project: "P", uses: .claude, codex: ModelSelection(model: "gpt-5.6-sol", effort: "medium"), ago: 5),
            thread("d", project: "P", uses: .codex, codex: ModelSelection(model: nil, effort: "high"), ago: 1),
            inner,
        ]
        func inherit(_ project: String, excluding: String? = nil, accepts: (String) -> Bool = { _ in true }) -> ModelSelection? {
            ModelDefaults.inherited(provider: .codex, projectID: project, excluding: excluding, threads: threads, accepts: accepts)
        }
        await t.equal("같은 프로젝트에서 그 에이전트를 쓰는 대화가 먼저 (모델을 정하지 않은 대화 · 내부 대화는 빼고)",
                      inherit("P"), ModelSelection(model: "gpt-6-luna", effort: "low"))
        await t.equal("같은 프로젝트에 없으면 전체에서 마지막", inherit("R"), ModelSelection(model: "gpt-6-sol", effort: "high"))
        await t.equal("받을 목록에서 풀리지 않는 모델은 건너뛴다", inherit("P", accepts: { $0 != "gpt-6-luna" }),
                      ModelSelection(model: "gpt-5.6-sol", effort: "medium"))
        await t.equal("자기 자신은 빼고", inherit("P", excluding: "a"), ModelSelection(model: "gpt-5.6-sol", effort: "medium"))
        let defaultAlias = ModelDefaults.hasChosenModel(ModelSelection(model: "default", effort: "high"), provider: .claude)
        let emptyModel = ModelDefaults.hasChosenModel(ModelSelection(model: "", effort: nil), provider: .codex)
        let chosen = ModelDefaults.hasChosenModel(ModelSelection(model: "opus", effort: nil), provider: .claude)
        await t.check("Claude 의 \"default\" · 빈 값은 정하지 않은 모델", !defaultAlias && !emptyModel && chosen)

        // 이어받을 것이 없을 때: config.toml 의 model (목록에 있으면) → CLI 기본
        func efforts(_ values: [String]) -> [[String: Any]] { values.map { ["reasoningEffort": $0] } }
        let astra: [String: Any] = ["id": "gpt-6-astra", "displayName": "GPT-6 Astra", "isDefault": true, "defaultReasoningEffort": "low",
                                    "supportedReasoningEfforts": efforts(["low", "medium", "high", "xhigh"])]
        let sol: [String: Any] = ["id": "gpt-6-sol", "displayName": "GPT-6 Sol", "defaultReasoningEffort": "medium",
                                  "supportedReasoningEfforts": efforts(["low", "medium", "high", "xhigh"])]
        let luna: [String: Any] = ["id": "gpt-6-luna", "displayName": "GPT-6 Luna", "supportedReasoningEfforts": efforts(["low", "medium"])]
        let codex = ModelCatalog.parseCodexModels([astra, sol, luna])
        await t.equal("config.toml 의 모델이 목록에 있으면 그것 (그 ID 그대로)",
                      ModelCatalog.defaultSelectionValue(in: codex, configModel: "gpt-6-sol"), "gpt-6-sol")
        await t.equal("목록에 없으면 CLI 기본 (계열 선택)", ModelCatalog.defaultSelectionValue(in: codex, configModel: "gpt-9-nova"),
                      "gpt-*-astra")
        await t.equal("config.toml 이 없으면 CLI 기본", ModelCatalog.defaultOption(in: codex, configModel: nil)?.identifier, "gpt-6-astra")
        await t.equal("Claude 목록 형식을 못 읽어도 CLI 가 알려 준 현재 별칭이면 그것",
                      ModelCatalog.preferredOption(in: ModelCatalog.claudeFallback(current: "Opus 5.5 (effort: high)"))?.identifier, "opus")
        await t.check("현재 별칭도 모르면 고르지 않는다", ModelCatalog.preferredOption(in: ModelCatalog.claudeFallback()) == nil)

        // 가장 좁은 입력창의 이름 (cap-8)
        let opus = AgentModelOption(provider: .claude, identifier: "opus[1m]", displayName: "Opus 5.5 · 1M")
        let flash = AgentModelOption(provider: .gemini, identifier: "gemini-3.8-flash", displayName: "Gemini 3.8 Flash")
        let shortNames: [String] = [codex[1], opus, flash].map(ModelCatalog.shortName(of:))
        await t.equal("짧은 이름: Codex 계열 · Claude · Antigravity", shortNames, ["Sol", "Opus", "Gemini Flash"])
    }

    /// 고르지 않은 강도: 설정의 기본 강도(사람이 고른 것) → Codex 는 config.toml → 그 모델의 기본 → High. 화면 = 전송.
    static func effortDefaults(_ t: TestKit) async {
        await t.group("강도 기본값: 설정 → config.toml → 모델 기본 → High")
        let all = ["low", "medium", "high", "xhigh"]
        func resolve(_ provider: AgentProvider, _ efforts: [String], model: String?, user: String? = nil,
                     config: String? = nil) -> String? {
            EffortScale.resolvedDefault(provider: provider, efforts: efforts, modelDefault: model,
                                        defaults: EffortScale.Defaults(user: user, config: config))?.effort
        }
        await t.equal("Codex: 설정에서 고른 강도가 먼저", resolve(.codex, all, model: "low", user: "medium", config: "xhigh"), "medium")
        await t.equal("Codex: 설정이 '모델 기본값' 이면 config.toml", resolve(.codex, all, model: "low", config: "xhigh"), "xhigh")
        await t.equal("Codex: config 도 없으면 그 모델의 기본 강도", resolve(.codex, all, model: "low"), "low")
        await t.equal("Codex: 모델의 기본도 모르면 High", resolve(.codex, all, model: nil), "high")
        await t.equal("Codex: 그 모델이 받지 않는 값은 건너뛴다", resolve(.codex, ["low", "medium"], model: "medium", user: "xhigh"),
                      "medium")
        await t.equal("Claude: config · 모델 기본은 보지 않는다 (High)",
                      resolve(.claude, ModelCatalog.claudeEfforts, model: "low", config: "low"), "high")
        await t.equal("Claude: 설정에서 고른 강도", resolve(.claude, ModelCatalog.claudeEfforts, model: nil, user: "max"), "max")
        await t.check("강도 목록이 비면(목록 모름 · 강도 없는 모델) 넘기지 않는다", resolve(.codex, [], model: "low", user: "low") == nil)
        await t.equal("High 도 받지 않는 모델이면 Medium → 첫 단계 ('미선택' 으로 남지 않게)",
                      [resolve(.codex, ["low", "medium"], model: nil), resolve(.codex, ["minimal", "low"], model: nil)],
                      ["medium", "minimal"])
        await t.equal("Antigravity 는 High (옛 규칙)", resolve(.gemini, ["low", "high"], model: nil), "high")

        let availability = EffortScale.Availability(efforts: all, emptyReason: nil, modelDefault: "low")
        await t.equal("고른 값이 있으면 그대로",
                      EffortScale.displayEffort(provider: .codex, selected: "high", availability: availability, defaults: .init()), "high")
        await t.equal("고르지 않았으면 기본의 차례",
                      EffortScale.displayEffort(provider: .codex, selected: nil, availability: availability,
                                                defaults: .init(config: "medium")), "medium")
        let astra: [String: Any] = ["id": "gpt-6-astra", "isDefault": true, "defaultReasoningEffort": "low",
                                    "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "high"]]]
        let listed = ModelCatalog.parseCodexModels([astra])
        await t.equal("목록이 그 모델의 CLI 기본 강도를 싣는다",
                      EffortScale.availability(provider: .codex, selectedModel: nil, options: listed).modelDefault, "low")
        func note(_ provider: AgentProvider, _ availability: EffortScale.Availability, _ defaults: EffortScale.Defaults) -> String {
            EffortScale.note(selected: nil, availability: availability, provider: provider, defaults: defaults) ?? "(없음)"
        }
        await t.check("카드 설명: 모델의 기본 강도에서 왔다고", note(.codex, availability, .init()).hasPrefix("이 모델의 기본 강도"),
                      note(.codex, availability, .init()))
        await t.check("카드 설명: config.toml 에서 왔다고",
                      note(.codex, availability, .init(config: "medium")).hasPrefix("Codex 설정(config.toml)"))
        await t.check("카드 설명: 설정에서 왔다고", note(.codex, availability, .init(user: "high")).hasPrefix("기본 강도 (설정 > 에이전트)"))
        let claudeSteps = EffortScale.Availability(efforts: ModelCatalog.claudeEfforts, emptyReason: nil)
        await t.check("카드 설명: Claude 의 High 도 기본 강도", note(.claude, claudeSteps, .init()).hasPrefix("기본 강도 (설정 > 에이전트)"))
        await t.equal("가장 좁은 칩의 강도: Extra High → X-High", EffortScale.compactName(of: "xhigh"), "X-High")
    }

    /// 입력창의 순수 규칙: 보내기 전 준비 상태 · 대기열 · esc · 긴 글 · 계정 이름 · 시작 때 다시 받을 목록.
    static func composerRules(_ t: TestKit) async {
        await t.group("입력창 규칙: 보내기 전 준비 · 대기열 · esc · 긴 글")
        let blocking: [AgentReadiness] = [.notInstalled, .pathInvalid, .notLoggedIn]
        let passing: [AgentReadiness] = [.checking, .loginUnknown, .ready]
        await t.check("막는 상태: 설치 안 됨 · 경로 오류 · 로그인 안 됨 (확인 중 · 로그인 모름은 보낸다)",
                      blocking.allSatisfy(SendReadiness.blocks) && !passing.contains(where: SendReadiness.blocks))
        let missing = SendReadiness.block(provider: .claude, readiness: .notInstalled)
        let missingText = missing?.text ?? ""
        await t.check("설치 안 됨: 설치하라고 · 시작 점검 (모델을 고르라고 하지 않는다)",
                      missingText.contains("찾지 못해") && !missingText.contains("모델") && missing?.opens == .firstRunCheck
                        && missing?.actionTitle == "시작 점검 열기", missingText)
        let path = SendReadiness.block(provider: .codex, readiness: .pathInvalid)
        await t.check("경로 오류: 설정의 실행 파일을 고치라고 · 설정 열기",
                      path?.opens == .agentSettings && (path?.text ?? "").contains("실행 파일"), path?.text ?? "")
        let codexLogin = SendReadiness.block(provider: .codex, readiness: .notLoggedIn, accountLabel: "둘째")
        await t.check("Codex 로그인 안 됨: 그 계정 · 설정의 계정 줄",
                      (codexLogin?.text ?? "").contains("Codex 계정 둘째") && codexLogin?.opens == .agentSettings, codexLogin?.text ?? "")
        let claudeLogin = SendReadiness.block(provider: .claude, readiness: .notLoggedIn)
        await t.check("Claude 로그인 안 됨: 터미널에서 로그인 · 시작 점검",
                      (claudeLogin?.text ?? "").contains("로그인") && claudeLogin?.opens == .firstRunCheck, claudeLogin?.text ?? "")
        let notices: [String?] = [AgentReadiness.notInstalled, .pathInvalid, .notLoggedIn, .ready, .loginUnknown, .checking]
            .map { SendReadiness.notice(provider: .codex, readiness: $0) }
        await t.check("입력창의 에이전트 표시: 쓸 수 없다고 확인된 상태만 알린다 (확인 중 · 로그인 모름은 조용히)",
                      notices.prefix(3).allSatisfy { $0 != nil } && notices.suffix(3).allSatisfy { $0 == nil }, "\(notices)")

        let states: [RunState] = [.failed, .cancelled, .rateLimited, .handoffDeliveryUnknown]
        let reasons: [String] = states.map(QueueRules.pauseReason(after:))
        await t.check("멈춤 이유: 상태마다 한 문장 (어색한 '(으)로' 없음)",
                      reasons.allSatisfy { !$0.contains("(으)") } && Set(reasons).count == states.count, "\(reasons)")
        await t.check("고치기의 이미지 상한: 붙인 것과 합쳐 넘으면 되돌리지 않는다",
                      QueueRules.editExceedsImageLimit(current: 8, adding: 3, limit: 10)
                        && !QueueRules.editExceedsImageLimit(current: 7, adding: 3, limit: 10))
        let replies = ["y", "Y", "n", "1", "2", "네", "ok"]
        let requests = ["테스트를 돌려 줘", "yes please do it", "", "12345"]
        await t.check("답처럼 보이는 글: y · n · 1 · 네 (보통 부탁은 아니다)",
                      replies.allSatisfy(QueueRules.looksLikeDecisionReply) && !requests.contains(where: QueueRules.looksLikeDecisionReply))

        let now = Date()
        await t.equal("esc: 빈 입력창 · 실행 중 · 처음 → 알린다",
                      ComposerEscape.action(textEmpty: true, running: true, armedAt: nil, now: now), .arm)
        await t.equal("esc: 2초 안에 한 번 더 → 멈춘다",
                      ComposerEscape.action(textEmpty: true, running: true, armedAt: now.addingTimeInterval(-1), now: now), .interrupt)
        await t.equal("esc: 늦으면 다시 알린다",
                      ComposerEscape.action(textEmpty: true, running: true, armedAt: now.addingTimeInterval(-5), now: now), .arm)
        let typed = ComposerEscape.action(textEmpty: false, running: true, armedAt: nil, now: now)
        let idle = ComposerEscape.action(textEmpty: true, running: false, armedAt: now, now: now)
        await t.check("esc: 글이 있거나 실행이 없으면 원래대로", typed == .ignore && idle == .ignore)

        let long = String(repeating: "로그 한 줄\n", count: 5000)
        let probe = ComposerText.heightProbe(long)
        await t.check("긴 글: 높이는 앞부분만 잰다", probe.split(separator: "\n").count <= 14 && probe.count < 300, "\(probe.count)")
        await t.equal("짧은 글은 그대로", ComposerText.heightProbe("한 줄"), "한 줄")
        await t.check("넘침: 8줄 이상 · 아주 긴 한 줄 (짧으면 아니다)",
                      ComposerText.overflows(long) && ComposerText.overflows(String(repeating: "가", count: 900))
                        && !ComposerText.overflows("두\n줄"))
        let labels: [String] = ["기본 계정", "work-2", "아주긴계정이름입니다"].map(ComposerAccountLabel.short)
        await t.equal("좁은 입력창의 계정 이름", labels, ["기본", "work-2", "아주긴계정…"])

        // 시작 때 다시 받을 목록 (set-8 · onb-9): Claude 는 `claude -p` 세션이라 하루 · CLI 버전이 바뀔 때만.
        var claude = ModelCatalogSnapshot(provider: .claude)
        claude.options = ModelCatalog.claudeFallback()
        claude.discovered = true
        claude.fetchedAt = now.addingTimeInterval(-3600)
        func needs(_ snapshot: ModelCatalogSnapshot?, _ provider: AgentProvider = .claude, fetched: String? = "2.1.283",
                   current: String? = "2.1.283") -> Bool {
            AppModel.catalogNeedsRefresh(provider: provider, snapshot: snapshot, fetchedVersion: fetched, currentVersion: current, now: now)
        }
        await t.check("Claude: 하루 안 · 같은 버전이면 다시 받지 않는다", !needs(claude))
        await t.check("Claude: CLI 버전이 바뀌면 다시", needs(claude, current: "2.1.290"))
        var stale = claude
        stale.fetchedAt = now.addingTimeInterval(-90_000)
        var fallback = claude
        fallback.discovered = false
        await t.check("Claude: 하루가 지났거나 대체 목록이거나 목록이 없으면 다시", needs(stale) && needs(fallback) && needs(nil))
        await t.check("Codex 는 시작할 때마다 (세션을 띄우지 않는 model/list) · Antigravity 는 하루 안이면 두고",
                      needs(claude, .codex) && !needs(claude, .gemini))
    }
}
