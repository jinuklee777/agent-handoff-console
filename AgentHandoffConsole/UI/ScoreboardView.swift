import SwiftUI

/// 에이전트 기록 화면 (코드 이름 · 저장값은 scoreboard — 예전 이름 "전적"). 객관적 실력 순위가 아니라 이 Mac 의 개인 기록이다.
/// 처음 쓰는 사람이 수의 뜻을 알 수 있게 — 수마다 무엇을 센 것인지 도움말, 평가를 어디서 매기는지 머리의 한 줄, 기록이 없으면 빈 상태 안내.
struct ScoreboardView: View {
    @Environment(AppModel.self) private var model
    @State private var runs: [Run] = []
    @State private var usage: [UsageRecord] = []
    @State private var ratings: [Rating] = []
    @State private var handoffs: [Handoff] = []
    @State private var period: Period = .all
    @State private var loading = false
    /// 처음 읽기를 마쳤는가 (읽기 전에는 빈 상태 안내를 보이지 않는다).
    @State private var loaded = false
    /// 가운데 칸 — "대화로 돌아가기" 가 바꾼다 (`ContentView` 와 같은 키).
    @AppStorage(WindowStateKey.pane) private var pane: WindowPane = .conversation

    enum Period: String, CaseIterable, Identifiable {
        case today = "오늘"
        case week = "최근 7일"
        case all = "전체"
        var id: String { rawValue }

        var cutoff: Date? {
            switch self {
            case .today: return Calendar.current.startOfDay(for: Date())
            case .week: return Date().addingTimeInterval(-7 * 86400)
            case .all: return nil
            }
        }
    }

    struct Stats {
        var runs = 0
        var completed = 0
        var cancelled = 0
        var failed = 0
        var rateLimited = 0
        var thumbsUp = 0
        var thumbsDown = 0
        var rescues = 0
        var handoffsFrom = 0
        var seamless = 0
        var needsInfo = 0
        var handoffFailed = 0
        var aggregate = UsageAggregate()
        var models: [String] = []
    }

    struct Badge: Hashable {
        let symbol: String
        let title: String
        let provider: AgentProvider
        /// 무엇을 센 배지인지 (도움말).
        let help: String
    }

    /// 수마다의 이름과 도움말 — 평가를 매기는 곳(턴 끝 줄 · 인계 줄)과 같은 말을 쓴다.
    enum Wording {
        static let rating = "좋았음 / 아쉬웠음"
        static let ratingHelp = "턴 끝 줄의 👍 · 👎 단추로 매긴 수 (줄에 포인터를 올리면 단추가 보입니다)"
        static let rescue = "막힌 일 해결"
        static let rescueHelp = "다른 에이전트가 막힌 일을 이 에이전트가 이어받아 풀었다고 사람이 표시한 턴 수 — 턴 끝 줄의 구명 튜브 단추"
        static let handoff = "넘긴 인계"
        static let handoffHelp = "이 에이전트가 다른 에이전트에게 넘긴 인계 수. 받은 쪽이 일한 뒤 대화의 인계 줄에서 "
            + "'바로 이어감 · 설명 필요 · 실패' 로 평가하면 함께 셉니다"
        static let intro = "에이전트마다 함께 한 실행 · 사용량 · 사람이 매긴 평가를 모았습니다. 턴 끝 줄에 포인터를 올리면 좋았음 · 아쉬웠음 · "
            + "막힌 일 해결을, 넘긴 인계는 인계 줄에서 평가할 수 있습니다."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                DiffBackChip(label: WindowPane.scoreboardToggleTitle(shown: .scoreboard),
                             help: "에이전트 기록을 닫고 대화로 (\(MenuShortcut.scoreboard.symbol))") {
                    pane = WindowPane.togglingScoreboard(shown: .scoreboard)
                }
                Text(WindowPane.scoreboardTitle).font(Theme.ui(.body, .semibold)).foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("이 Mac 의 기록").font(Theme.ui(.caption)).foregroundStyle(Theme.slate2)
                Spacer()
                PillSegmented(options: Period.allCases, selection: $period) { value, selected in
                    PillText(text: value.rawValue, selected: selected)
                }
                IconButton(systemName: "arrow.clockwise", size: 12, color: Theme.slate, help: "다시 읽기",
                           spinning: loading) {
                    Task { await load() }
                }
            }
            .padding(.horizontal, 28)
            .frame(height: 54)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }

            if loaded && runs.isEmpty {
                // 기록이 하나도 없으면 0 으로 가득한 표 대신 무엇이 쌓이는지 알린다.
                QuietEmptyState(systemImage: "chart.bar", title: "아직 기록이 없습니다",
                                detail: "대화에서 에이전트에게 일을 맡기면 에이전트마다 실행 · 사용량이 여기에 쌓입니다.\n"
                                    + "턴 끝 줄에 포인터를 올려 좋았음 · 아쉬웠음을 매기면 평가도 함께 모입니다.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Wording.intro)
                                .font(Theme.ui(.callout))
                                .foregroundStyle(Theme.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("어려운 작업을 맡은 쪽이 불리하게 잡히므로 객관적인 실력 순위가 아닙니다. "
                                 + "사용자 취소 · 네트워크 오류 · 승인 거절은 모델 실패로 세지 않고, "
                                 + "이 기록으로 에이전트를 자동 배정하지도 않습니다.")
                                .font(Theme.ui(.caption))
                                .lineSpacing(3.5)
                                .foregroundStyle(Theme.slate)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: 900, alignment: .leading)
                        .leadingRule(Theme.hair, gap: 13)

                        let providers = shownProviders
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                                if index > 0 { Rectangle().fill(Theme.hair).frame(width: 1) }
                                providerColumn(provider, stats: stats(for: provider))
                                    .padding(.leading, index > 0 ? 34 : 0)
                                    .padding(.trailing, index < providers.count - 1 ? 34 : 0)
                            }
                        }

                        badges
                        codexAccountBreakdown
                        modelBreakdown
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                    .padding(.bottom, 26)
                }
            }
        }
        .background(Theme.paper)
        .task { await load() }
    }

    /// 열을 둘 에이전트 — Claude · Codex 는 늘, Antigravity 는 이 기간에 실행이 있을 때만 (쓰지 않는 사람에게 0 열을 보이지 않는다).
    private var shownProviders: [AgentProvider] {
        let base: [AgentProvider] = [.claude, .codex]
        return filteredRuns.contains { $0.provider == .gemini } ? base + [.gemini] : base
    }

    // MARK: 에이전트 열

    private func providerColumn(_ provider: AgentProvider, stats: Stats) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                BrandMark(provider: provider, size: 15)
                Text(provider.displayName).font(Theme.ui(.body, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text(stats.models.prefix(2).map(modelName).joined(separator: " · "))
                    .font(Theme.ui(.caption)).foregroundStyle(Theme.slate2).lineLimit(1)
                    .help("많이 쓴 모델: " + stats.models.joined(separator: ", "))
            }
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                // 기록 화면의 큰 숫자 하나만 4단계(`TypeScale`) 밖이다 — 표의 머리 숫자라 글자가 아니라 그림처럼 쓴다.
                Text("\(stats.runs)")
                    .font(.system(size: 34, weight: .light, design: .monospaced))
                    .tracking(-0.7)
                    .foregroundStyle(Theme.ink)
                Text("번 실행").font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
            }
            .help("이 기간에 \(provider.displayName) 에게 맡긴 실행(메시지 한 번 = 실행 하나) 수")
            .accessibilityElement(children: .combine)
            outcomeBar(stats)
            VStack(alignment: .leading, spacing: 5) {
                statRow("완료", "\(stats.completed)", help: "끝까지 마친 실행")
                statRow("사용자 취소", "\(stats.cancelled)", note: "실패로 세지 않음", help: "사람이 멈춘 실행 (⌘. · 중단)")
                statRow("오류", "\(stats.failed)", help: "CLI 오류 · 인증 실패 등으로 끝난 실행")
                statRow("사용 한도 도달", "\(stats.rateLimited)", help: "에이전트의 사용 한도에 닿아 멈춘 실행")
            }
            Rectangle().fill(Theme.hairSoft).frame(height: 1)
            VStack(alignment: .leading, spacing: 5) {
                statRow("누적 토큰", stats.aggregate.turns == 0 ? "—" : Fmt.tokens(stats.aggregate.totalTokens),
                        help: "입력 · 캐시 · 출력 토큰의 합 (사용량 기록이 있는 턴만)")
                statRow(stats.aggregate.costUnknownTurns > 0 && stats.aggregate.knownCostTurns > 0
                            ? "확인된 API 환산 비용" : "API 환산 비용",
                        costValue(stats.aggregate),
                        valueColor: stats.aggregate.knownCostTurns == 0 && stats.aggregate.turns > 0
                            ? Theme.amberText : Theme.ink2,
                        help: "공개 API 가격표로 환산한 값입니다 — 구독의 실제 청구액이 아닙니다")
                if stats.aggregate.costUnknownTurns > 0 {
                    statRow("금액 미확인", "\(stats.aggregate.costUnknownTurns)턴",
                            labelColor: Theme.amberText, valueColor: Theme.amberText,
                            help: "가격표에 없는 모델 등으로 금액을 셈하지 못한 턴")
                }
                if stats.aggregate.unconfirmedTurns > 0 {
                    statRow("사용량 미확정", "\(stats.aggregate.unconfirmedTurns)턴",
                            labelColor: Theme.amberText, valueColor: Theme.amberText,
                            help: "중단 · 앱 종료로 끊겨 사용량이 완전하지 않은 턴")
                }
            }
            Rectangle().fill(Theme.hairSoft).frame(height: 1)
            VStack(alignment: .leading, spacing: 5) {
                statRow(Wording.rating, "\(stats.thumbsUp) / \(stats.thumbsDown)", help: Wording.ratingHelp)
                statRow(Wording.rescue, "\(stats.rescues)회", help: Wording.rescueHelp)
                statRow(Wording.handoff, "\(stats.handoffsFrom)건", note: handoffNote(stats), help: Wording.handoffHelp)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 완료 · 취소 · 오류 · 한도 비율 막대. 기록이 없으면 빈 막대.
    private func outcomeBar(_ stats: Stats) -> some View {
        GeometryReader { geometry in
            let parts: [(Int, Color)] = [(stats.completed, Theme.emerald), (stats.cancelled, Theme.slate3),
                                         (stats.failed, Theme.danger), (stats.rateLimited, Theme.amber)]
            let total = parts.reduce(0) { $0 + $1.0 }
            let visible = parts.filter { $0.0 > 0 }
            let spacing = CGFloat(max(visible.count - 1, 0)) * 2
            HStack(spacing: 2) {
                if total == 0 {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.hair)
                } else {
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, part in
                        RoundedRectangle(cornerRadius: 2).fill(part.1)
                            .frame(width: max(2, (geometry.size.width - spacing) * CGFloat(part.0) / CGFloat(total)))
                    }
                }
            }
        }
        .frame(height: 5)
        .help("완료(초록) · 사용자 취소(회색) · 오류(빨강) · 사용 한도 도달(주황) 의 비율")
        .accessibilityHidden(true)
    }

    private func statRow(_ label: String, _ value: String, note: String? = nil,
                         labelColor: Color = Theme.slate, valueColor: Color = Theme.ink2, help: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(Theme.ui(.caption)).foregroundStyle(labelColor)
            if let note { Text(note).font(Theme.ui(.caption)).foregroundStyle(Theme.slate2).lineLimit(1) }
            Spacer(minLength: 8)
            Text(value).font(Theme.mono(.caption)).foregroundStyle(valueColor)
        }
        .contentShape(Rectangle())
        .help(help ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityHint(help ?? "")
    }

    /// 넘긴 인계의 평가 한 줄 (넘긴 것이 없으면 없음).
    private func handoffNote(_ stats: Stats) -> String? {
        guard stats.handoffsFrom > 0 else { return nil }
        let base: String = "바로 이어감 \(stats.seamless) · 설명 필요 \(stats.needsInfo)"
        return stats.handoffFailed > 0 ? base + " · 실패 \(stats.handoffFailed)" : base
    }

    /// 0 턴이면 "—" (돈을 쓰지 않은 것과 모르는 것을 섞지 않는다), 금액을 하나도 모르면 "금액 미확인".
    private func costValue(_ aggregate: UsageAggregate) -> String {
        if aggregate.turns == 0 { return "—" }
        return aggregate.knownCostTurns > 0 ? Fmt.cost(aggregate.displayCostUSD) : "금액 미확인"
    }

    /// 사용량에 남은 모델 ID → 사람이 읽는 이름 (턴 머리줄과 같은 `ModelCatalog.runModelName` — "claude-opus-5-5" → "Opus 5.5").
    private func modelName(_ id: String) -> String {
        ModelCatalog.runModelName(id, catalog: model.modelCatalogs.values.flatMap(\.options))
    }

    // MARK: 배지 · 표

    private var badges: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SectionLabel("배지")
                Text("기록과 사람이 매긴 평가만으로 셈합니다. 추가 LLM 호출은 하지 않습니다.")
                    .font(Theme.ui(.caption)).foregroundStyle(Theme.slate2)
            }
            let earned = computeBadges()
            if earned.isEmpty {
                Text("아직 배지가 없습니다 — 오늘 완료한 실행이 3번 넘거나, 넘긴 인계에 '바로 이어감' 평가가 3번 쌓이면 생깁니다.")
                    .font(Theme.ui(.caption)).foregroundStyle(Theme.slate2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    ForEach(earned, id: \.self) { badge in
                        HStack(spacing: 6) {
                            Text("\(badge.symbol) \(badge.title)").foregroundStyle(Theme.ink2)
                            Text(badge.provider.displayName).fontWeight(.semibold).foregroundStyle(Theme.ink)
                        }
                        .font(Theme.ui(.caption))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .overlay(Capsule().strokeBorder(Theme.hair))
                        .help(badge.help)
                    }
                }
            }
        }
    }

    /// Codex 계정별 기록. 계정이 하나뿐이면 보여주지 않는다.
    @ViewBuilder
    private var codexAccountBreakdown: some View {
        if model.accounts.hasMultiple {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Codex 계정별")
                VStack(spacing: 0) {
                    ForEach(model.accounts.accounts) { account in
                        let accountRuns = filteredRuns.filter {
                            $0.provider == .codex && $0.codexAccountID == account.id
                        }
                        let runIDs = Set(accountRuns.map { $0.id })
                        let agg = UsageAggregate.from(filteredUsage.filter { runIDs.contains($0.runID) })
                        HStack(spacing: 14) {
                            Text(account.label).font(Theme.mono(.caption)).foregroundStyle(Theme.ink)
                                .frame(width: 120, alignment: .leading).lineLimit(1)
                            Text("\(accountRuns.count)번 실행").font(Theme.mono(.caption)).foregroundStyle(Theme.slate)
                                .frame(width: 80, alignment: .leading)
                            Text(agg.turns == 0 ? "—" : Fmt.tokens(agg.totalTokens)).font(Theme.mono(.caption))
                                .foregroundStyle(Theme.slate)
                                .frame(width: 90, alignment: .leading)
                            Text(costValue(agg)).font(Theme.mono(.caption))
                                .foregroundStyle(agg.costUnknownTurns > 0 ? Theme.amberText : Theme.slate)
                                .frame(width: 90, alignment: .leading)
                            Spacer()
                            Text(accountNote(account)).font(Theme.mono(.caption)).foregroundStyle(Theme.slate2)
                        }
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairSoft).frame(height: 1) }
                    }
                }
                let unattributed = filteredRuns.filter { $0.provider == .codex && $0.codexAccountID == nil }
                if !unattributed.isEmpty {
                    Text("어느 계정의 것인지 알 수 없는 예전 실행 \(unattributed.count)번")
                        .font(Theme.ui(.caption)).foregroundStyle(Theme.slate2)
                }
            }
        }
    }

    private var modelBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SectionLabel("모델별")
                // 실행 수(위 열)와 턴 수가 다를 수 있다 — 사용량을 받지 못한 실행(앱 종료 · 중단 직후 등)은 여기서 빠진다.
                Text("사용량 기록이 있는 턴만 셉니다.")
                    .font(Theme.ui(.caption)).foregroundStyle(Theme.slate2)
            }
            let byModel = Dictionary(grouping: filteredUsage) { $0.model ?? "모델 미확인" }
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    SectionLabel("모델").frame(width: 210, alignment: .leading)
                    SectionLabel("턴").frame(width: 80, alignment: .leading)
                    SectionLabel("토큰").frame(width: 90, alignment: .leading)
                    SectionLabel("API 환산").frame(width: 90, alignment: .leading)
                    SectionLabel("비고")
                    Spacer()
                }
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
                if byModel.isEmpty {
                    Text("기록 없음").font(Theme.ui(.caption)).foregroundStyle(Theme.slate2)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
                ForEach(byModel.keys.sorted(), id: \.self) { key in
                    let records = byModel[key] ?? []
                    let agg = UsageAggregate.from(records)
                    HStack(spacing: 14) {
                        Text(key == "모델 미확인" ? key : modelName(key)).font(Theme.ui(.caption)).foregroundStyle(Theme.ink2)
                            .frame(width: 210, alignment: .leading).lineLimit(1)
                            .help(key)
                        Text("\(agg.turns)").font(Theme.mono(.caption)).foregroundStyle(Theme.slate)
                            .frame(width: 80, alignment: .leading)
                        Text(Fmt.tokens(agg.totalTokens)).font(Theme.mono(.caption)).foregroundStyle(Theme.slate)
                            .frame(width: 90, alignment: .leading)
                        Text(costValue(agg)).font(Theme.mono(.caption))
                            .foregroundStyle(agg.costUnknownTurns > 0 ? Theme.amberText : Theme.slate)
                            .frame(width: 90, alignment: .leading)
                        Text(sourceNote(records, agg))
                            .font(Theme.mono(.caption))
                            .foregroundStyle(agg.costUnknownTurns > 0 ? Theme.amberText : Theme.slate2)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairSoft).frame(height: 1) }
                }
            }
        }
    }

    // MARK: 계산

    private func sourceNote(_ records: [UsageRecord], _ aggregate: UsageAggregate) -> String {
        if aggregate.costUnknownTurns > 0 { return "\(aggregate.costUnknownTurns)턴 금액 미확인" }
        let sources = Set(records.map(\.costSource))
        if sources == [.cliReported] { return "CLI 보고" }
        let versions = Set(records.compactMap(\.priceCatalogVersion)).sorted()
        return "앱 계산" + (versions.isEmpty ? "" : " · 가격표 \(versions.joined(separator: ", "))")
    }

    private func accountNote(_ account: CodexAccount) -> String {
        let utilization = model.limits.codex(account.id).windows.compactMap(\.utilization).max()
        let limit = utilization.map { "한도 \(Fmt.percent($0))" } ?? "한도 정보 없음"
        return "\(limit) · \(account.authStatus.koreanName)"
    }

    private var filteredRuns: [Run] {
        guard let cutoff = period.cutoff else { return runs }
        return runs.filter { $0.startedAt >= cutoff }
    }

    private var filteredUsage: [UsageRecord] {
        guard let cutoff = period.cutoff else { return usage }
        return usage.filter { $0.createdAt >= cutoff }
    }

    private func stats(for provider: AgentProvider) -> Stats {
        var s = Stats()
        let providerRuns = filteredRuns.filter { $0.provider == provider }
        s.runs = providerRuns.count
        for r in providerRuns {
            switch r.state {
            case .completed: s.completed += 1
            // 사용자 취소는 모델 실패로 집계하지 않는다.
            case .cancelled: s.cancelled += 1
            case .failed: s.failed += 1
            case .rateLimited: s.rateLimited += 1
            default: break
            }
        }
        let runIDs = Set(providerRuns.map { $0.id })
        let providerUsage = filteredUsage.filter { runIDs.contains($0.runID) }
        s.aggregate = UsageAggregate.from(providerUsage)
        let modelCounts = Dictionary(grouping: providerUsage.compactMap(\.model), by: { $0 }).mapValues(\.count)
        s.models = modelCounts.sorted { $0.value > $1.value }.map(\.key)

        for rating in ratings where rating.provider == provider {
            if let runID = rating.runID, !runIDs.contains(runID) { continue }
            if rating.satisfaction == .up { s.thumbsUp += 1 }
            if rating.satisfaction == .down { s.thumbsDown += 1 }
            if rating.rescue { s.rescues += 1 }
        }

        let cutoff = period.cutoff
        // 초안(만들고 보내지 않은 것)은 "넘긴 인계"가 아니다.
        let sent = handoffs.filter { h in
            h.fromProvider == provider && h.deliveryState != .draft
                && (cutoff.map { h.createdAt >= $0 } ?? true)
        }
        s.handoffsFrom = sent.count
        for h in sent {
            guard let rating = ratings.first(where: { $0.handoffID == h.id }) else { continue }
            switch rating.handoffQuality {
            case .seamless: s.seamless += 1
            case .needsInfo: s.needsInfo += 1
            case .failed: s.handoffFailed += 1
            case nil: break
            }
        }
        return s
    }

    private func computeBadges() -> [Badge] {
        var out: [Badge] = []
        let today = Calendar.current.startOfDay(for: Date())
        let todayRuns = runs.filter { $0.startedAt >= today && $0.state == .completed }
        if let top = Dictionary(grouping: todayRuns, by: { $0.provider })
            .max(by: { $0.value.count < $1.value.count })?.key,
           todayRuns.count >= 3 {
            out.append(Badge(symbol: "◈", title: "오늘 완료 최다", provider: top,
                             help: "오늘 끝까지 마친 실행이 가장 많은 에이전트 (오늘 완료 3번 이상일 때)"))
        }
        let seamless = ratings.filter { $0.handoffQuality == .seamless }
        if let top = Dictionary(grouping: seamless, by: { $0.provider })
            .max(by: { $0.value.count < $1.value.count })?.key, seamless.count >= 3 {
            out.append(Badge(symbol: "⇄", title: "바로 이어진 인계 최다", provider: top,
                             help: "넘긴 인계에 '바로 이어감' 평가를 가장 많이 받은 에이전트 (3번 이상일 때)"))
        }
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        let rescues = ratings.filter { $0.rescue && $0.updatedAt >= weekAgo }
        if let top = Dictionary(grouping: rescues, by: { $0.provider })
            .max(by: { $0.value.count < $1.value.count })?.key, rescues.count >= 2 {
            out.append(Badge(symbol: "⛑", title: "이번 주 막힌 일 해결 최다", provider: top,
                             help: "최근 7일 '막힌 일 해결' 표시를 가장 많이 받은 에이전트 (2번 이상일 때)"))
        }
        return out
    }

    private func load() async {
        loading = true
        defer {
            loading = false
            loaded = true
        }
        runs = (try? await model.store.allRuns()) ?? []
        usage = (try? await model.store.allUsage()) ?? []
        ratings = (try? await model.store.allRatings()) ?? []
        handoffs = (try? await model.store.allHandoffs()) ?? []
    }
}
