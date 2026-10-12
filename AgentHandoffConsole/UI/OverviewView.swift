import SwiftUI

/// 에이전트 현황 — 가운데 칸 "현황" (보기 메뉴 · 툴바 ⋯ ⌃⌘0 · 사이드바 맨 위 행 · 응답 필요 칩 · 메뉴바). 시안 A(목록형).
/// 지금 도는 실행 · 답을 기다리는 인계 카드 · 자동 작업을 한 화면에: 머리(한 문장 · 정렬) · 수 · "응답 필요"(승인은 여기서 허용 · 거절,
/// 되돌릴 수 없는 명령은 대화에서) · "일하는 중"(지금 하는 일 · 열기 · 중단) · 사용 한도(계정마다 실행 수) · 최근 끝난 실행.
/// 판정 · 글은 `Overview`(App/Overview.swift), 사실은 `AppModel+Overview`. 행을 누르면 그 대화로 (가운데 칸이 대화로 바뀐다).
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(WindowStateKey.pane) private var pane: WindowPane = .conversation
    @AppStorage("overview.sort") private var sortRaw = Overview.Sort.status.rawValue
    @State private var finished: [Overview.FinishedRun] = []
    @State private var lastEnded: Date?
    @State private var width: CGFloat = 900
    @FocusState private var listFocused: Bool

    private var sort: Overview.Sort { Overview.Sort(rawValue: sortRaw) ?? .status }
    private var compact: Bool { Double(width) < Overview.compactWidth }

    /// 도는 실행이 바뀌면(시작 · 끝) 상자를 읽고 끝난 실행을 다시 읽는다. 대화 목록이 바뀌어도 (앱을 켜자마자 현황이 보이면
    /// 대화 목록보다 먼저 읽어 제목을 찾지 못한다).
    private var runSignature: String {
        model.activeSessions.compactMap(\.activeRun?.id).sorted().joined(separator: ",") + "|\(model.allThreads().count)"
    }

    var body: some View {
        // 기다린 시간("2분째") · "n분 전" 이 흐르게 30초마다 다시 그린다. 초 단위 시계는 레이어가 센다 (`ElapsedText` · `CountdownText`).
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task { await model.setOverviewVisible(true) }
        .onDisappear { Task { await model.setOverviewVisible(false) } }
        .task(id: runSignature) {
            await model.loadOverviewThreads()
            await reloadFinished()
        }
    }

    private func content(now: Date) -> some View {
        let items = model.overviewItems(now: now)
        let counts = Overview.counts(items)
        let groups = Overview.groups(items, sort: sort)
        let flat = groups.flatMap(\.items).map(\.threadID)
        return ScrollView {
            VStack(alignment: .leading, spacing: compact ? 18 : 28) {
                header(counts)
                if items.isEmpty {
                    emptyState
                } else {
                    if compact { compactSummary(counts) } else { tiles(counts) }
                    ForEach(groups) { group in section(group, now: now) }
                }
                if !compact { limitsSection }
                recentSection
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(.horizontal, compact ? 14 : 32)
            .padding(.top, 12)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1, in: flat) }
        .onKeyPress(.upArrow) { move(-1, in: flat) }
        .onKeyPress(.return) {
            guard let id = model.overviewSelection, flat.contains(id) else { return .ignored }
            Task { await model.openFromOverview(threadID: id) }
            return .handled
        }
        .onChange(of: flat, initial: true) { _, ids in
            if let id = model.overviewSelection, ids.contains(id) { return }
            model.overviewSelection = ids.first
        }
    }

    private func move(_ step: Int, in ids: [String]) -> KeyPress.Result {
        guard !ids.isEmpty else { return .ignored }
        let index = model.overviewSelection.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
        model.overviewSelection = ids[max(0, min(ids.count - 1, index + step))]
        return .handled
    }

    private func reloadFinished() async {
        let result = await model.overviewFinishedRuns()
        finished = result.today
        lastEnded = result.lastEnded
    }

    // MARK: 머리 · 수

    private func header(_ counts: Overview.Counts) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DiffBackChip(label: WindowPane.overviewToggleTitle(shown: .overview),
                         help: "현황을 닫고 대화로 (\(MenuShortcut.overview.symbol))") {
                pane = WindowPane.togglingOverview(shown: .overview)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 16) {
                    titleBlock(counts)
                    Spacer(minLength: 12)
                    sortPicker
                }
                VStack(alignment: .leading, spacing: 10) {
                    titleBlock(counts)
                    sortPicker
                }
            }
        }
    }

    private func titleBlock(_ counts: Overview.Counts) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(WindowPane.overviewTitle)
                .font(Theme.ui(.title, .semibold))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(Overview.headline(counts))
                .font(Theme.ui(.body))
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sortPicker: some View {
        Picker("정렬", selection: $sortRaw) {
            ForEach(Overview.Sort.allCases, id: \.rawValue) { sort in
                Text(sort.title).tag(sort.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("상태순은 답을 기다리는 것부터, 프로젝트순은 프로젝트마다 묶습니다")
    }

    private func tiles(_ counts: Overview.Counts) -> some View {
        HStack(spacing: 0) {
            // 카운트다운(자동 인계 · 다른 계정에서 이어 가기)은 답을 기다리는 수에 넣지 않고 뒤에 따로.
            tile(label: "응답 필요", value: "\(counts.waiting)", sub: Overview.countdownNote(counts).map { "· " + $0 },
                 dot: counts.waiting > 0 ? Theme.amber : nil)
            Divider()
            tile(label: "일하는 중", value: "\(counts.working)", sub: nil, dot: nil)
            Divider()
            tile(label: "백그라운드 대기", value: "\(counts.background)",
                 sub: counts.backgroundTasks > 0 ? "· 하위 작업 \(counts.backgroundTasks)" : nil, dot: nil)
            Divider()
            let today = Overview.todayText(finished)
            let first = today.split(separator: " ", maxSplits: 1).map(String.init)
            tile(label: "오늘 끝난 실행", value: first.first ?? "0", sub: first.count > 1 ? first[1] : nil, dot: nil)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hair))
    }

    private func tile(label: String, value: String, sub: String?, dot: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(label).font(Theme.ui(.callout)).foregroundStyle(Theme.slate)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(Theme.digits(.title, .semibold)).foregroundStyle(Theme.ink)
                if let sub {
                    Text(sub).font(Theme.ui(.callout)).foregroundStyle(Theme.slate2).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func compactSummary(_ counts: Overview.Counts) -> some View {
        HStack(spacing: 10) {
            Text("실행 \(counts.running)").font(Theme.digits(.callout)).foregroundStyle(Theme.slate2)
            if counts.waiting > 0 {
                HStack(spacing: 5) {
                    Circle().fill(Theme.amber).frame(width: 7, height: 7)
                    Text("응답 \(counts.waiting)").font(Theme.digits(.callout, .semibold)).foregroundStyle(Theme.amberText)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 구역

    @ViewBuilder
    private func section(_ group: Overview.Group, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(group.title)
                    .font(Theme.ui(.body, .semibold))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                if let note = group.note {
                    Text("· " + note).font(Theme.ui(.callout)).foregroundStyle(Theme.slate2)
                }
                Spacer(minLength: 8)
                if group.role == .needsResponse, !compact {
                    Text("↑ ↓ 고르기 · ↵ 대화 열기 · \(MenuShortcut.approvalAllow.symbol) 허용")
                        .font(Theme.mono(.caption))
                        .foregroundStyle(Theme.slate2)
                }
            }
            let needs = group.items.filter(\.kind.needsResponse)
            let working = group.items.filter { !$0.kind.needsResponse }
            ForEach(needs) { item in
                OverviewResponseRow(item: item, now: now, compact: compact,
                                    selected: model.overviewSelection == item.threadID)
            }
            if !working.isEmpty {
                if compact {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(working) { item in
                            OverviewCompactWorkRow(item: item, selected: model.overviewSelection == item.threadID)
                        }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 12, alignment: .top)],
                              alignment: .leading, spacing: 12) {
                        ForEach(working) { item in
                            OverviewWorkCard(item: item, selected: model.overviewSelection == item.threadID)
                        }
                    }
                }
            }
        }
    }

    // MARK: 사용 한도

    private var limitsSection: some View {
        let entries = model.limitEntries
        // Antigravity 의 한도 줄이 있으면(허용한 프로젝트가 있다 — 그 줄이 실행 수도 센다) 따로 세지 않는다.
        let agyRunning = entries.contains { $0.snapshot.provider == .gemini } ? 0
            : model.activeSessions.filter { $0.activeProvider == .gemini }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("사용 한도").font(Theme.ui(.body, .semibold)).foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("· 계정마다 지금 쓰는 실행 수와 함께").font(Theme.ui(.callout)).foregroundStyle(Theme.slate2)
                Spacer(minLength: 8)
                Button {
                    Task { await model.limits.refreshAll(force: true) }
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                        .font(Theme.ui(.callout))
                }
                .buttonStyle(ChipButtonStyle(radius: 6))
                .help("사용 한도를 다시 읽습니다 (\(MenuShortcut.refreshLimits.symbol))")
            }
            if entries.isEmpty && agyRunning == 0 {
                Text("사용 한도를 알려 줄 에이전트가 없습니다.").font(Theme.ui(.callout)).foregroundStyle(Theme.slate2)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12, alignment: .top)],
                          alignment: .leading, spacing: 12) {
                    ForEach(entries) { entry in
                        limitCard {
                            LimitSection(snapshot: entry.snapshot, showRawOnFailure: false, accountLabel: entry.accountLabel)
                            Text(Overview.runningText(runningCount(entry.snapshot)))
                                .font(Theme.digits(.caption))
                                .foregroundStyle(Theme.slate2)
                        }
                    }
                    if agyRunning > 0 {
                        limitCard {
                            ProviderBadge(provider: .gemini)
                            Text(Overview.noLimitsText).font(Theme.ui(.caption)).foregroundStyle(Theme.slate2)
                            Text(Overview.runningText(agyRunning)).font(Theme.digits(.caption)).foregroundStyle(Theme.slate2)
                        }
                    }
                }
            }
        }
    }

    private func limitCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hair))
    }

    private func runningCount(_ snapshot: LimitSnapshot) -> Int {
        model.activeSessions.filter { session in
            guard session.activeProvider == snapshot.provider else { return false }
            return snapshot.provider != .codex || session.activeAccount?.id == snapshot.accountID
        }.count
    }

    // MARK: 최근 끝난 실행

    private var recentSection: some View {
        let rows = Overview.recent(finished)
        let checks = finished.filter(\.needsCheck).count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("최근 끝난 실행").font(Theme.ui(.body, .semibold)).foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                if checks > 0 {
                    Text("· 확인 필요 \(checks)").font(Theme.ui(.callout)).foregroundStyle(Theme.amberText)
                }
                Spacer(minLength: 8)
                Button {
                    if model.diffWideActive { model.closeDiff() }
                    pane = .scoreboard
                } label: {
                    Text("에이전트 기록 열기 \(MenuShortcut.scoreboard.symbol)").font(Theme.ui(.callout))
                }
                .buttonStyle(ChipButtonStyle(radius: 6))
            }
            if rows.isEmpty {
                Text("오늘 끝난 실행이 없습니다.").font(Theme.ui(.callout)).foregroundStyle(Theme.slate2)
            } else if compact {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows) { run in
                        Button { Task { await model.openFromOverview(threadID: run.threadID) } } label: {
                            HStack(spacing: 8) {
                                Text(Overview.clock(run.endedAt)).font(Theme.digits(.caption)).foregroundStyle(Theme.slate2)
                                Text(run.title).font(Theme.ui(.callout)).foregroundStyle(Theme.ink2).lineLimit(1)
                                Spacer(minLength: 6)
                                resultText(run)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                recentTable(rows)
            }
        }
    }

    private func recentTable(_ rows: [Overview.FinishedRun]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                ForEach(["끝난 시각", "대화", "프로젝트", "결과", "걸린 시간", "새 토큰", "API 환산"], id: \.self) { title in
                    Text(title).font(Theme.ui(.caption, .medium)).foregroundStyle(Theme.slate2)
                }
            }
            .padding(.bottom, 6)
            ForEach(rows) { run in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text(Overview.clock(run.endedAt)).font(Theme.digits(.callout)).foregroundStyle(Theme.slate2)
                    Button { Task { await model.openFromOverview(threadID: run.threadID) } } label: {
                        HStack(spacing: 6) {
                            BrandMark(provider: run.provider, size: 11)
                            Text(run.title).font(Theme.ui(.callout)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("이 대화로 갑니다")
                    Text(run.project).font(Theme.ui(.callout)).foregroundStyle(Theme.slate).lineLimit(1)
                    resultText(run)
                    Text(run.durationMs.map { DisplayFormat.duration(ms: $0) } ?? "—")
                        .font(Theme.digits(.callout)).foregroundStyle(Theme.slate)
                    Text(run.newTokens.map(DisplayFormat.tokens) ?? "—").font(Theme.digits(.callout)).foregroundStyle(Theme.slate)
                    Text(run.cost.map { DisplayFormat.cost($0) } ?? "—").font(Theme.digits(.callout)).foregroundStyle(Theme.slate)
                }
                .padding(.vertical, 7)
            }
        }
    }

    private func resultText(_ run: Overview.FinishedRun) -> some View {
        let warn = run.needsCheck || run.state == .failed || run.state == .rateLimited || run.state == .handoffDeliveryUnknown
        return Text(Overview.resultText(run))
            .font(Theme.ui(.callout, warn ? .semibold : .regular))
            .foregroundStyle(warn ? Theme.amberText : (run.state == .completed ? Theme.emeraldText : Theme.slate))
            .lineLimit(1)
    }

    // MARK: 빈 상태

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.slate3)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(Overview.emptyTitle).font(Theme.ui(.body, .semibold)).foregroundStyle(Theme.ink)
                Text(Overview.emptyLine(lastEnded: lastEnded, today: finished))
                    .font(Theme.digits(.callout)).foregroundStyle(Theme.slate)
            }
            HStack(spacing: 8) {
                Button {
                    if let projectID = model.selectedProjectID ?? model.projects.first?.id {
                        Task { await model.startNewConversation(projectID: projectID) }
                    } else {
                        Task { await ProjectFolderPicker.openFromMenu(model: model) }
                    }
                } label: {
                    Text("새 대화 \(MenuShortcut.newThread.symbol)")
                }
                .buttonStyle(InkButtonStyle())
                Button(WindowPane.scoreboardTitle) {
                    pane = .scoreboard
                }
                .buttonStyle(ChipButtonStyle(radius: 6))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hair))
    }
}

// MARK: - 행의 머리

/// 행 머리: 일하는 중이면 제공자 색의 도는 링 + 로고, 아니면 로고만 · 제목(누르면 그 대화) · "프로젝트 — 브랜치".
/// 사람 차례인 행(승인 · 질문 · 검토 — 응답 필요)은 실행이 살아 있어도 링을 돌리지 않는다 — 움직임은 "에이전트가 일하는 중", 멈춘 황색 점은
/// "사람 차례" (차분한 화면 — 카드마다 움직이는 것이 하나를 넘지 않게).
private struct OverviewRowTitle: View {
    @Environment(AppModel.self) private var model
    let item: Overview.Item
    var stacked = false

    var body: some View {
        HStack(spacing: 10) {
            OverviewMark(provider: item.provider, running: item.running, spins: item.running && !item.kind.needsResponse)
            Group {
                if stacked {
                    VStack(alignment: .leading, spacing: 1) {
                        titleButton
                        place
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        titleButton
                        place
                    }
                }
            }
        }
    }

    private var titleButton: some View {
        Button { Task { await model.openFromOverview(threadID: item.threadID) } } label: {
            Text(item.title)
                .font(Theme.ui(.body, .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .buttonStyle(.plain)
        .help("이 대화로 갑니다")
    }

    private var place: some View {
        var text = item.project
        if let branch = item.branch { text += " — " + branch }
        if item.inWorktree { text += " · 독립 작업 폴더" }
        if item.automatic { text += " · 자동 작업" }
        return Text(text)
            .font(Theme.ui(.callout))
            .foregroundStyle(Theme.slate2)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// 일하는 중이면 로고를 제공자 색의 도는 링이 감싼다 (사이드바 행과 같은 모양). 링은 레이어로 돈다 (`SpinningLayer` — SwiftUI 의
/// 반복 애니메이션은 화면 밖에서도 매 프레임 창을 다시 계산했다). 동작 줄이기면 돌지 않는 링.
private struct OverviewMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let provider: AgentProvider
    /// 실행이 살아 있다 (접근성 이름).
    let running: Bool
    /// 링을 그린다 — 일하는 중일 때만 (사람 차례인 행은 실행이 살아 있어도 로고만).
    var spins: Bool

    var body: some View {
        ZStack {
            if spins && reduceMotion {
                Circle().trim(from: 0, to: 0.75)
                    .stroke(Theme.brand(provider), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 20, height: 20)
            } else if spins {
                SpinningLayer(content: .ring(color: Theme.brand(provider), lineWidth: 1.5, trim: 0.75), period: 1)
                    .frame(width: 20, height: 20)
            }
            BrandMark(provider: provider, size: spins ? 11 : 14)
        }
        .frame(width: 20, height: 20)
        .accessibilityElement()
        .accessibilityLabel(provider.displayName + (running ? " 실행 중" : ""))
    }
}

// MARK: - 응답 필요 행

/// 답을 기다리는 행 하나 — 승인 · 질문 · 인계 검토 · 자동 작업 · 자동 인계 카운트다운 · 다른 계정에서 이어 가기 카운트다운.
private struct OverviewResponseRow: View {
    @Environment(AppModel.self) private var model
    let item: Overview.Item
    let now: Date
    let compact: Bool
    let selected: Bool

    var body: some View {
        let risky = riskyApproval
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                OverviewRowTitle(item: item, stacked: compact)
                Spacer(minLength: 8)
                status
            }
            bodyContent
                .padding(.leading, compact ? 0 : 30)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.approvalWell, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(risky ? Theme.danger : Theme.approvalBorder, lineWidth: risky ? 1.5 : 1))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.accentColor, lineWidth: 2).padding(-2).opacity(selected ? 1 : 0))
        .contentShape(Rectangle())
        .onTapGesture { model.overviewSelection = item.threadID }
    }

    private var session: RunSession? { model.runner.session(threadID: item.threadID) }

    private var approval: ApprovalRequest? {
        guard item.kind == .approval else { return nil }
        return session?.pendingApprovals.first { !$0.isQuestion }
    }

    private var riskyApproval: Bool {
        guard let approval else { return false }
        let folder = model.paneThread(item.threadID).flatMap { model.folderProject(for: $0)?.path }
        return ApprovalPresentation.make(approval, projectPath: folder).risk != nil
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 6) {
            if !item.kind.isCountdown {
                Circle().fill(Theme.amber).frame(width: 7, height: 7)
            }
            Text(Overview.statusText(item.kind))
                .font(Theme.ui(.callout, .semibold))
                .foregroundStyle(Theme.amberText)
                .lineLimit(1)
            if !item.kind.isCountdown {
                Text("· " + Overview.waitedText(since: item.since, now: now))
                    .font(Theme.digits(.callout))
                    .foregroundStyle(Theme.slate2)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch item.kind {
        case .approval:
            if let approval {
                OverviewApprovalBody(threadID: item.threadID, request: approval, selected: selected)
            } else {
                openOnly("대화 열기")
            }
        case .question:
            OverviewQuestionBody(threadID: item.threadID, selected: selected)
        case .handoffCountdown(let deadline):
            OverviewCountdownBody(threadID: item.threadID, deadline: deadline)
        case .codexSwitch(let deadline):
            OverviewCodexSwitchBody(threadID: item.threadID, deadline: deadline)
        case .handoffReview:
            openOnly("인계 카드 열기")
        case .orchestration:
            openOnly("대화 열기")
        case .working, .background:
            EmptyView()
        }
    }

    private func openOnly(_ title: String) -> some View {
        HStack {
            Spacer(minLength: 0)
            Button(title) { Task { await model.openFromOverview(threadID: item.threadID) } }
                .buttonStyle(InkButtonStyle())
        }
    }
}

/// 승인 요청의 미리보기와 결정 단추. 막 나타난 요청은 잠깐 단추를 받지 않고, 한 번 누르면 요청이 빠질 때까지 잠근다 (`ApprovalCardGate` —
/// 대화의 카드와 같다). 메뉴의 ⌥⌘↵ · ⌥⌘⌫ 는 현황에서 고른 행이 받는다 (`AppModel.approvalShortcutThreadID`).
private struct OverviewApprovalBody: View {
    @Environment(AppModel.self) private var model
    let threadID: String
    let request: ApprovalRequest
    let selected: Bool
    @State private var shownAt: Date?
    @State private var responding = false

    var body: some View {
        let folder = model.paneThread(threadID).flatMap { model.folderProject(for: $0)?.path }
        let shown = ApprovalPresentation.make(request, projectPath: folder)
        let choice = Overview.approvalChoice(kind: request.kind, presentation: shown, isQuestion: request.isQuestion)
        let preview = Overview.approvalPreview(shown, subject: request.provider.displayName)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 12) {
                details(preview, choice: choice, risk: shown.risk)
                buttons(choice)
            }
            VStack(alignment: .leading, spacing: 10) {
                details(preview, choice: choice, risk: shown.risk)
                HStack { Spacer(minLength: 0); buttons(choice) }
            }
        }
        .onAppear { shownAt = Date() }
        .onChange(of: request.id) { _, _ in
            shownAt = Date()
            responding = false
        }
        .onReceive(NotificationCenter.default.publisher(for: ApprovalShortcut.notification)) { note in
            guard selected, let action = ApprovalShortcut.action(note, threadID: threadID) else { return }
            switch action {
            case .allow: if choice.allowsHere { decide(.allow) }
            case .deny: if choice.deniesHere { decide(.deny("")) }
            }
        }
    }

    private func details(_ preview: (line: String, code: String?), choice: Overview.ApprovalChoice,
                         risk: CommandRisk?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(preview.line)
                .font(Theme.ui(.callout))
                .foregroundStyle(Theme.ink2)
                .lineLimit(2)
            if let code = preview.code {
                // 여기서 허용할 수 있으면 대상을 자르지 않는다 — 허용하는 것을 다 보인다 (긴 명령은 `approvalChoice` 가 대화로 미룬다).
                Text(code)
                    .font(Theme.mono(.callout))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(choice.allowsHere ? nil : 2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.codeBorder))
            }
            if let reason = choice.reason {
                Text(reason)
                    .font(Theme.ui(.caption, risk == nil ? .regular : .semibold))
                    .foregroundStyle(risk == nil ? Theme.slate : Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func buttons(_ choice: Overview.ApprovalChoice) -> some View {
        HStack(spacing: 6) {
            if choice.deniesHere {
                Button("거절") { decide(.deny("")) }
                    .buttonStyle(ChipButtonStyle(radius: 6))
                    .disabled(responding)
                    .help("거절합니다 — 사유를 적으려면 대화에서 답하세요" + (selected ? " (\(MenuShortcut.approvalDeny.symbol))" : ""))
            }
            if choice.allowsHere {
                Button("허용") { decide(.allow) }
                    .buttonStyle(InkButtonStyle())
                    .disabled(responding)
                    .help("이 요청을 허용합니다" + (selected ? " (\(MenuShortcut.approvalAllow.symbol))" : ""))
            } else {
                Button("대화에서 답하기") { Task { await model.openFromOverview(threadID: threadID) } }
                    .buttonStyle(InkButtonStyle())
            }
            Button { Task { await model.openFromOverview(threadID: threadID) } } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.control)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("대화를 열어 카드 전체를 봅니다")
            .accessibilityLabel("대화 열기")
        }
        .fixedSize()
    }

    private func decide(_ decision: ApprovalDecision) {
        guard ApprovalCardGate.accepts(shownAt: shownAt, now: Date(), responding: responding) else { return }
        responding = true
        let id = request.id
        Task { await model.respondFromOverview(threadID: threadID, approvalID: id, decision: decision) }
    }
}

/// 질문 — 고를 답이 있는 한 항목 질문은 여기서 고르고, 나머지는 대화에서 답한다.
private struct OverviewQuestionBody: View {
    @Environment(AppModel.self) private var model
    let threadID: String
    let selected: Bool
    @State private var responding = false

    var body: some View {
        let session = model.runner.session(threadID: threadID)
        let question = session?.pendingQuestions.first
        let asked = session?.pendingApprovals.first(where: \.isQuestion)
        VStack(alignment: .leading, spacing: 8) {
            if let question {
                Text(question.promptText)
                    .font(Theme.ui(.callout))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if let options = Overview.questionOptions(question) {
                        ForEach(options, id: \.self) { option in
                            Button(option) {
                                responding = true
                                Task { await model.answerFromOverview(threadID: threadID, questionID: question.id, option: option) }
                            }
                            .buttonStyle(ChipButtonStyle(radius: 6))
                            .disabled(responding)
                        }
                        Button("직접 입력…") { Task { await model.openFromOverview(threadID: threadID) } }
                            .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.callout)))
                    }
                    Spacer(minLength: 0)
                    Button("대화 열기") { Task { await model.openFromOverview(threadID: threadID) } }
                        .buttonStyle(InkButtonStyle())
                }
            } else {
                if let asked {
                    Text(ApprovalPresentation.make(asked, projectPath: nil).summary ?? asked.title)
                        .font(Theme.ui(.callout))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(3)
                }
                HStack {
                    Spacer(minLength: 0)
                    Button("대화에서 답하기") { Task { await model.openFromOverview(threadID: threadID) } }
                        .buttonStyle(InkButtonStyle())
                }
            }
        }
    }
}

/// 자동 인계 카운트다운 — 남은 초 · 받는 쪽 · [멈추고 검토] · [지금 넘기기]. 초는 레이어가 센다 (`CountdownText`).
private struct OverviewCountdownBody: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let threadID: String
    let deadline: Date
    @State private var sending = false

    var body: some View {
        let card = model.handoffCards[threadID]
        let target = card.map { model.handoffPartyName($0.draft.target, label: $0.draft.packet.toAccountLabel) } ?? "받는 쪽"
        let source = card.map { model.handoffPartyName($0.draft.source, label: $0.draft.packet.fromAccountLabel) } ?? "보내는 쪽"
        let delay: Int = {
            if case .countingDown(_, let delay)? = card?.phase { return delay }
            return 30
        }()
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                CountdownRingLayer(deadline: deadline, delay: delay, reduceMotion: reduceMotion, diameter: 30)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                lines(source: source, target: target)
                Spacer(minLength: 8)
                buttons
            }
            VStack(alignment: .leading, spacing: 10) {
                lines(source: source, target: target)
                HStack { Spacer(minLength: 0); buttons }
            }
        }
    }

    private func lines(source: String, target: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(source) 의 사용 한도에 닿았습니다.").font(Theme.ui(.callout)).foregroundStyle(Theme.ink2)
            CountdownText(deadline: deadline, step: .callout, color: Theme.amberText) { seconds in
                HandoffCardText.countdown(seconds: seconds, target: target)
            }
            .accessibilityLabel("자동 인계 대기")
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            Button("멈추고 검토") { Task { await model.reviewCountdownFromOverview(threadID: threadID) } }
                .buttonStyle(ChipButtonStyle(radius: 6))
                .help("카운트다운을 멈추고 인계 카드를 엽니다")
            Button("지금 넘기기") {
                sending = true
                Task { _ = await model.sendHandoffNow(threadID: threadID) }
            }
            .buttonStyle(InkButtonStyle())
            .disabled(sending)
            .help("기다리지 않고 지금 넘깁니다")
        }
        .fixedSize()
    }
}

/// 다른 계정에서 같은 세션을 이어 가기 카운트다운 — 자동 인계 카운트다운 행과 같은 모양(링 · 두 줄 · 단추 둘). 인계가 아니다: 같은 Codex
/// 세션을 다른 계정의 인증으로 이어 간다 (`CodexAccountSwitch`). 단추는 입력창 위 줄과 같은 길 — [취소] = `cancelCodexSwitchCountdown`,
/// [지금 이어 가기] = `continueCodexSwitchNow`. 초는 레이어가 센다 (`CountdownText` · `CountdownRingLayer`).
private struct OverviewCodexSwitchBody: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let threadID: String
    let deadline: Date
    @State private var continuing = false

    var body: some View {
        let countdown = model.codexSwitchCountdowns[threadID]
        let source = countdown.map { model.handoffPartyName($0.source) } ?? AgentProvider.codex.displayName
        let target = countdown.map { model.handoffPartyName($0.target) } ?? "다른 계정"
        let delay = countdown?.delay ?? 30
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                CountdownRingLayer(deadline: deadline, delay: delay, reduceMotion: reduceMotion, diameter: 30)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                lines(source: source, target: target)
                Spacer(minLength: 8)
                buttons(target: target)
            }
            VStack(alignment: .leading, spacing: 10) {
                lines(source: source, target: target)
                HStack { Spacer(minLength: 0); buttons(target: target) }
            }
        }
    }

    private func lines(source: String, target: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(CodexAccountSwitch.reachedText(source: source)).font(Theme.ui(.callout)).foregroundStyle(Theme.ink2)
            CountdownText(deadline: deadline, step: .callout, color: Theme.amberText) { seconds in
                CodexAccountSwitch.countdownText(seconds: seconds, target: target)
            }
            .accessibilityLabel(CodexAccountSwitch.waitingText)
        }
    }

    private func buttons(target: String) -> some View {
        HStack(spacing: 6) {
            Button(CodexAccountSwitch.cancelTitle) { model.cancelCodexSwitchCountdown(threadID: threadID) }
                .buttonStyle(ChipButtonStyle(radius: 6))
                .help(CodexAccountSwitch.cancelHelp)
            Button(CodexAccountSwitch.continueNowTitle) {
                continuing = true
                Task { await model.continueCodexSwitchNow(threadID: threadID) }
            }
            .buttonStyle(InkButtonStyle())
            .disabled(continuing)
            .help(CodexAccountSwitch.limitHelp(name: target))
        }
        .fixedSize()
    }
}

// MARK: - 일하는 중

/// 일하는 중인 실행의 카드 — 지금 하는 일(점 구 · 글 · 대상) · 메타 · 같은 폴더 안내 · 남은 하위 작업 · [열기] · [중단].
private struct OverviewWorkCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let item: Overview.Item
    let selected: Bool

    private var background: Bool {
        if case .background = item.kind { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                OverviewRowTitle(item: item, stacked: true)
                Spacer(minLength: 8)
                ElapsedText(since: item.since, step: .callout) { seconds in
                    (background ? "기다린 지 " : "") + DisplayFormat.elapsed(seconds: seconds)
                }
                .fixedSize()
            }
            if let activity = item.activity {
                HStack(spacing: 8) {
                    // 점 구는 멈춘 한 장면 — 하는 일의 모양은 남기되 움직이지 않는다 (움직이는 것은 머리의 링 하나).
                    // 움직이는 점 구는 하나에 CPU 1~2% 라 카드가 여럿이면 늘었다. 자세히 보는 대화의 상태 줄은 그대로 움직인다.
                    if let work = item.work {
                        OrbLayer(state: work.orbState, size: .px20, paused: true, dark: colorScheme == .dark)
                            .frame(width: OrbSize.px20.value, height: OrbSize.px20.value)
                            .accessibilityHidden(true)
                    }
                    Text(activity).font(Theme.ui(.callout)).foregroundStyle(Theme.ink2).lineLimit(1)
                    if let detail = item.activityDetail {
                        Text(detail)
                            .font(Theme.mono(.caption))
                            .foregroundStyle(Theme.slate)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.wellSoft, in: RoundedRectangle(cornerRadius: 7))
            }
            if !item.subtasks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(item.subtasks.enumerated()), id: \.offset) { _, task in
                        HStack(spacing: 6) {
                            Image(systemName: task.finished ? "checkmark" : "circle.dotted")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(task.finished ? Theme.emeraldText : Theme.slate2)
                                .accessibilityHidden(true)
                            Text(task.title).font(Theme.ui(.caption)).foregroundStyle(Theme.ink2).lineLimit(1)
                            Text("· " + task.status).font(Theme.digits(.caption)).foregroundStyle(Theme.slate2).lineLimit(1)
                        }
                    }
                }
            }
            if let note = item.note {
                Text(note).font(Theme.ui(.caption)).foregroundStyle(Theme.amberText).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if !item.meta.isEmpty {
                    Text(item.meta.joined(separator: " · "))
                        .font(Theme.digits(.caption))
                        .foregroundStyle(Theme.slate2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                Button("열기") { Task { await model.openFromOverview(threadID: item.threadID) } }
                    .buttonStyle(ChipButtonStyle(radius: 6))
                if item.running {
                    Button(background ? "백그라운드 작업까지 중단" : "중단") {
                        Task { await model.stopFromOverview(threadID: item.threadID) }
                    }
                    .buttonStyle(ChipButtonStyle(radius: 6))
                    .help(background ? "남은 백그라운드 작업까지 이 실행을 멈춥니다 (⌘. 와 같다)" : "이 실행을 멈춥니다 (⌘. 와 같다)")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hair))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.accentColor, lineWidth: 2).padding(-2).opacity(selected ? 1 : 0))
        .contentShape(Rectangle())
        .onTapGesture { model.overviewSelection = item.threadID }
    }
}

/// 좁은 칸의 일하는 중 한 줄 — 링 · 제목 · 지금 하는 일.
private struct OverviewCompactWorkRow: View {
    @Environment(AppModel.self) private var model
    let item: Overview.Item
    let selected: Bool

    var body: some View {
        Button { Task { await model.openFromOverview(threadID: item.threadID) } } label: {
            HStack(spacing: 8) {
                OverviewMark(provider: item.provider, running: item.running, spins: item.running)
                Text(item.title).font(Theme.ui(.callout)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Text(compactStatus).font(Theme.ui(.caption)).foregroundStyle(Theme.slate2).lineLimit(1)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(selected ? Theme.well : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("이 대화로 갑니다")
    }

    private var compactStatus: String {
        if case .background(let left) = item.kind { return "백그라운드 \(left)" }
        return item.activity ?? "일하는 중"
    }
}
