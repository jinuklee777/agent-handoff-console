import SwiftUI

/// 인스펙터 "에이전트" 탭: 포커스 대화의 실행이 띄운 하위 에이전트 · 워크플로 · 백그라운드 명령.
///
/// - 위: 하위 작업 목록 — 세로로 한 줄씩 (지금 도는 실행의 것 먼저, 그다음 저장된 것 — 최근 실행 먼저, 한 실행 안에서는
///   시작 순). 하위가 띄운 작업은 그 하위 아래에 들여 놓고, 실행이 둘 이상이면 실행마다 머리를 둔다. 길면 이 칸만 스크롤한다.
///   하위가 앞에서 돌린 셸은 넣지 않는다 (`SubAgentInfo.isInternalStep` — 그 하위의 흐름에 명령 행으로 있다).
/// - 고른 하위: 이름 · 상태 · 경과 · 토큰 · 부모 제공자, 멈추기(작업 하나 멈추기를 CLI 가 제공할 때만),
///   흐름(응답 · 명령 · 파일 변경), Codex 하위의 흐르는 글, 끝났으면 최종 답과 받은 쪽 ("메인에게 전달됨" —
///   하위가 띄운 작업이면 그 하위).
/// - 아래: 읽기 전용 안내 — 하위 에이전트에게는 보낼 수 없다.
///
/// 하위의 흐름은 부모 대화의 이벤트 중 부모 표시가 붙은 것(`ThreadPaneModel.subAgentEvents`)이다. 하위는 대화가 아니라
/// 분할 칸으로 열지 않는다. 어느 하위를 볼지는 `AppModel.subAgentFocus`(대화별) — 대화 스트림의 카드가 고른다.
struct AgentsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // 포커스 대화의 상자는 언제나 있다 (`AppModel.openThreadIDs`). 다른 대화의 상자는 들지 않는다.
        if let threadID = model.selectedThreadID, let pane = model.threadStates[threadID] {
            AgentsPaneContent(threadID: threadID, pane: pane)
                .id(threadID)
        } else {
            QuietEmptyState(systemImage: InspectorTab.agents.symbol, title: "대화를 고르세요",
                            detail: "고른 대화의 실행이 띄운 하위 에이전트를 여기서 봅니다.")
                .padding(.top, 30)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Theme.paper)
        }
    }
}

private struct AgentsPaneContent: View {
    @Environment(AppModel.self) private var model
    let threadID: String
    let pane: ThreadPaneModel
    /// 고른 하위의 흐름 (응답 · 실행 기록). 하위 이벤트가 늘 때만 다시 묶는다.
    @State private var rows: [StreamRow] = []
    /// 백그라운드 명령을 띄운 메인의 명령 행 (고른 것이 명령일 때). 메인 흐름을 훑는 일이라 본문이 아니라 `.task` 에서 —
    /// 메인 글이 자랄 때마다 이 탭을 다시 그리지 않게.
    @State private var anchorEntries: [ExecutionEntry] = []

    /// 이 대화에서 지금 도는 실행 (없으면 nil). 끝나면 하위 목록은 저장된 것만 남는다.
    private var session: RunSession? { model.runner.session(threadID: threadID) }

    /// 하위를 띄운 실행 중 지금 세션이 도는 것. 여기에 없는(DB 에 끝나지 않은 상태로 남은) 실행의 `running` 하위는 끝나지 않음.
    private var liveRunIDs: Set<String> {
        var out = Set<String>()
        for runID in Set(pane.subAgentRunIDs.values) where pane.runsByID[runID]?.state.isTerminal != true {
            if model.liveSession(runID: runID) != nil { out.insert(runID) }
        }
        if let live = session?.activeRun?.id { out.insert(live) }
        return out
    }

    /// 대화의 프로젝트 폴더 (경로를 줄여 보이는 데). 흐름을 묶는 `.task` 안에서만 부른다 — 본문에서 대화 목록을 훑지 않게.
    private func projectPath() -> String? {
        let thread = model.allThreads().first { $0.id == threadID } ?? model.internalThreadsByID[threadID]
        return thread.flatMap { model.folderProject(for: $0)?.path }
    }

    var body: some View {
        let session = self.session
        let items = SubAgentList.items(stored: pane.subAgentInfos, runIDs: pane.subAgentRunIDs, runs: pane.runsByID,
                                       live: session?.subAgents ?? [], liveRunID: session?.activeRun?.id,
                                       liveRunIDs: liveRunIDs)
        let selectedID = SubAgentList.resolve(selected: model.subAgentFocus[threadID], in: items)
        let selected = items.first { $0.id == selectedID }
        VStack(spacing: 0) {
            if items.isEmpty {
                QuietEmptyState(systemImage: InspectorTab.agents.symbol, title: "하위 에이전트가 없습니다",
                                detail: "에이전트가 하위 에이전트 · 워크플로 · 백그라운드 명령을 띄우면 여기서 흐름을 봅니다.")
                    .padding(.top, 30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                list(items, selectedID: selectedID)
                if let selected {
                    detailHeader(selected, session: session)
                    flow(selected, session: session)
                    // 고른 하위의 흐름 아래에만 — 빈 탭에서는 보낼 대상이 없어 안내할 것도 없다.
                    footer
                }
            }
        }
        .background(Theme.paper)
        .environment(pane)
        // 흐름은 이벤트가 붙을 때만 다시 묶는다 (진행 · 흐르는 글은 관찰 속성에서 바로 읽는다).
        .task(id: flowKey(selected)) {
            guard let selected else { rows = []; anchorEntries = []; return }
            let path = projectPath()
            rows = StreamBuilder.subAgentRows(events: pane.subAgentEvents[selected.id] ?? [], projectPath: path,
                                              subAgents: nestedDigests(of: selected.id, projectPath: path))
            if selected.info.kind == .shell {
                // 하위가 띄운 셸이면 앵커는 그 하위의 흐름에 있다.
                let anchor = SubAgentList.shellAnchorEvents(id: selected.id, ownerID: selected.info.ownerID,
                                                            main: pane.mainEvents, flows: pane.subAgentEvents)
                anchorEntries = ExecutionParser.entries(from: anchor, projectPath: path)
            } else {
                anchorEntries = []
            }
        }
    }

    /// 흐름을 다시 묶는 키: 대화 · 고른 하위 · 그 하위의 이벤트 수 · 마지막 글 길이 · 하위 안에서 띄운 하위들의 상태,
    /// 그리고 상태 · 끝난 시각 (백그라운드 명령의 앵커 행은 명령이 끝날 때 출력을 받는다 — 그때 작업 상태도 바뀐다).
    /// 하위가 띄운 셸이면 앵커가 있는 그 하위 흐름의 이벤트 수도.
    private func flowKey(_ item: SubAgentListItem?) -> String {
        guard let item else { return threadID }
        let id = item.id
        let events = pane.subAgentEvents[id] ?? []
        let nested = pane.subAgentInfos.values.filter { $0.ownerID == id }
            .map { "\($0.id):\($0.status.rawValue)" }.sorted().joined(separator: ",")
        let ownerFlow = item.info.kind == .shell ? item.info.ownerID.map { pane.subAgentEvents[$0]?.count ?? 0 } ?? 0 : 0
        return "\(threadID)|\(id)|\(events.count)|\(events.last?.text.count ?? 0)|\(nested)"
            + "|\(item.info.status.rawValue)|\(item.info.endedAt?.timeIntervalSince1970 ?? 0)|\(ownerFlow)"
    }

    /// 이 하위가 띄운 하위들의 요약 (Codex 의 하위 안 하위 — 흐름 안의 앵커 행에 카드로 붙는다).
    private func nestedDigests(of id: String, projectPath: String?) -> [String: SubAgentDigest] {
        let owned = pane.subAgentInfos.filter { $0.value.ownerID == id }
        guard !owned.isEmpty else { return [:] }
        return StreamBuilder.subAgentDigests(infos: owned, runIDs: pane.subAgentRunIDs, events: pane.subAgentEvents,
                                             runs: pane.runsByID, projectPath: projectPath, liveRunIDs: liveRunIDs)
    }

    // MARK: 목록

    /// 목록 칸의 가장 큰 높이 — 여섯 줄 반 + 실행 머리 하나. 더 길면 이 칸만 스크롤하고, 반 줄이 걸려 보여 더 있다는 것을 알린다.
    private static let listMaxHeight: CGFloat = 6.5 * rowHeight + headerHeight + 2 * listPadding
    private static let rowHeight: CGFloat = 28
    /// 실행 머리 — 시각 · 처리 토큰과 몫 한 줄 + 몫 막대.
    private static let headerHeight: CGFloat = 40
    private static let listPadding: CGFloat = 5
    /// 오른쪽 숫자 열의 너비 — 줄마다 처리 토큰 · 몫이 같은 자리에 서게.
    private static let tokensWidth: CGFloat = 46
    private static let shareWidth: CGFloat = 34

    /// 실행 하나의 몫 (메인 · 하위가 처리한 토큰). 실행 전체는 그 실행의 사용량 기록.
    private func share(_ section: SubAgentList.Section) -> TokenShare {
        TokenShare.make(runUsage: section.runID.flatMap { pane.usageByRun[$0] }, infos: section.items.map(\.info))
    }

    private func list(_ items: [SubAgentListItem], selectedID: String?) -> some View {
        let sections = SubAgentList.sections(items)
        let shares = Dictionary(sections.map { ($0.id, share($0)) }, uniquingKeysWith: { first, _ in first })
        // 실행마다 머리(누가 얼마나 썼나)와 메인 한 줄을 둔다 — 실행이 하나여도.
        let mains = sections.filter { $0.runID != nil }.count
        // 줄 높이가 정해져 있어 내용 높이를 셀 수 있다 — 짧으면 그 높이 그대로, 길면 묶은 높이 안에서 스크롤.
        // (높이를 `frame(maxHeight:)` 로 묶으면 짧은 목록도 그 높이까지 늘어난다.)
        let height = CGFloat(items.count + mains) * Self.rowHeight + CGFloat(sections.count) * Self.headerHeight
            + 2 * Self.listPadding
        let content = VStack(alignment: .leading, spacing: 0) {
            ForEach(sections) { section in
                let share = shares[section.id] ?? TokenShare(runTotal: nil, byAgent: [:])
                runHeader(section, share: share, selectedID: selectedID)
                if section.runID != nil { mainRow(section, share: share) }
                ForEach(section.items) { item in listRow(item, selected: item.id == selectedID, share: share).id(item.id) }
            }
        }
        .padding(.vertical, Self.listPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        return Group {
            if height <= Self.listMaxHeight {
                content
            } else {
                ScrollViewReader { proxy in
                    ScrollView { content }
                        // 카드에서 고른 하위가 보이는 곳 밖에 있으면 보이는 만큼만 옮긴다.
                        .onAppear { if let selectedID { proxy.scrollTo(selectedID) } }
                        .onChange(of: selectedID) { _, id in
                            if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                        }
                }
                .frame(height: Self.listMaxHeight)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
    }

    /// 실행 머리 — 지금 도는 실행, 아니면 그 실행을 시작한 시각 (오늘이 아니면 날짜도), 오른쪽에 처리 토큰과 메인 · 하위의 몫,
    /// 아래에 누가 얼마나 썼는지의 막대 (실행 전체를 알 때만 — 도는 중이면 하위 합만 글로).
    private func runHeader(_ section: SubAgentList.Section, share: TokenShare, selectedID: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(runLabel(section))
                    .font(Theme.ui(.caption, .medium))
                    .foregroundStyle(Theme.slate2)
                Spacer(minLength: 6)
                if let headline = share.headline() {
                    Text(headline)
                        .font(Theme.digits(.caption))
                        .foregroundStyle(Theme.slate)
                        .lineLimit(1)
                }
            }
            if share.runTotal != nil, !share.byAgent.isEmpty {
                TokenShareBar(segments: barSegments(section, share: share), selectedID: selectedID)
                    .frame(height: 5)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
        .frame(height: Self.headerHeight, alignment: .bottom)
        .help(TokenShare.help)
        .accessibilityElement(children: .combine)
    }

    /// 막대의 조각 — 메인 먼저, 그다음 목록 순서의 하위. 몫을 모르는 조각은 뺀다.
    private func barSegments(_ section: SubAgentList.Section, share: TokenShare) -> [TokenShareBar.Segment] {
        let provider = runProvider(section)
        var out: [TokenShareBar.Segment] = []
        if let fraction = share.fraction(share.main), fraction > 0 {
            out.append(.init(id: "main", fraction: fraction, color: Theme.brand(provider ?? .claude), isMain: true))
        }
        for item in section.items {
            guard let fraction = share.fraction(share.byAgent[item.id]), fraction > 0 else { continue }
            out.append(.init(id: item.id, fraction: fraction,
                             color: Theme.brand(Self.provider(of: item.info, runProvider: provider)), isMain: false))
        }
        return out
    }

    private func runProvider(_ section: SubAgentList.Section) -> AgentProvider? {
        section.runID.flatMap { pane.runsByID[$0]?.provider } ?? (section.isLive ? session?.activeProvider : nil)
    }

    /// 하위가 일한 제공자 — 모델 이름으로 알면 그것(Claude 가 부른 Codex 직원 등), 아니면 띄운 실행의 제공자.
    static func provider(of info: SubAgentInfo, runProvider: AgentProvider?) -> AgentProvider {
        if let model = info.model?.lowercased() {
            if model.hasPrefix("claude") { return .claude }
            if model.hasPrefix("gpt") || model.hasPrefix("o3") || model.hasPrefix("o4") || model.hasPrefix("codex") { return .codex }
            if model.hasPrefix("gemini") { return .gemini }
        }
        return runProvider ?? .claude
    }

    /// 메인 한 줄: 실행한 에이전트 · 모델 · 처리 토큰(전체 − 하위, 추정) · 몫. 눌러서 고를 수 없다 — 메인의 흐름은 대화에 있다.
    private func mainRow(_ section: SubAgentList.Section, share: TokenShare) -> some View {
        let provider = runProvider(section) ?? .claude
        let model = section.runID.flatMap { pane.runsByID[$0]?.model }.flatMap { SubAgentList.modelLabel($0) }
        return HStack(spacing: 7) {
            BrandMark(provider: provider, size: 11)
                .frame(width: 12)
            Text("\(provider.displayName) (메인)")
                .font(Theme.ui(.callout))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
            if let model {
                Text(model)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate2)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            tokenColumns(share.main, fraction: share.fraction(share.main), emphasized: false)
            statusColumn(Text(""))
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(height: Self.rowHeight)
        .padding(.horizontal, 6)
        .help("이 실행을 한 에이전트 — " + TokenShare.help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider.displayName) 메인, 처리 토큰 \(share.main.map { DisplayFormat.tokens($0) } ?? "모름"), "
                            + "몫 \(TokenShare.percentText(share.fraction(share.main)))")
    }

    /// 오른쪽 숫자 두 열: 처리 토큰 · 몫. 모르면 "—".
    private func tokenColumns(_ tokens: Int?, fraction: Double?, emphasized: Bool) -> some View {
        HStack(spacing: 0) {
            Text(tokens.map { DisplayFormat.tokens($0) } ?? "—")
                .font(Theme.digits(.caption, emphasized ? .medium : .regular))
                .foregroundStyle(tokens == nil ? Theme.slate3 : Theme.ink2)
                .frame(width: Self.tokensWidth, alignment: .trailing)
            Text(TokenShare.percentText(fraction))
                .font(Theme.digits(.caption))
                .foregroundStyle(fraction == nil ? Theme.slate3 : Theme.slate2)
                .frame(width: Self.shareWidth, alignment: .trailing)
        }
        .fixedSize()
    }

    /// 상태 열 — 가장 긴 상태 글("결과 미확인") 너비로 오른쪽에 맞춰 줄마다 숫자 열이 같은 자리에 선다.
    private func statusColumn(_ text: Text) -> some View {
        ZStack(alignment: .trailing) {
            Text(SubAgentDigest.statusText(.running, unfinished: true)).hidden()
            text
        }
        .font(Theme.ui(.caption))
        .padding(.leading, 8)
        .fixedSize()
    }

    private func runLabel(_ section: SubAgentList.Section) -> String {
        if section.isLive { return "지금 실행" }
        guard let started = section.runStartedAt else { return "이전 실행" }
        let when = Calendar.current.isDateInToday(started) ? Fmt.clock.string(from: started) : Fmt.dateTime.string(from: started)
        return "\(when) 실행"
    }

    /// 한 줄: (들여쓰기) 상태 표시 · 이름 · 모델 · 종류 · 경과 · 처리 토큰 · 몫 · 상태. 좁으면 모델 · 종류를 빼고, 그래도 좁으면
    /// 이름을 줄인다 (경과 · 처리 토큰 · 몫 · 상태는 남는다 — 예전에는 경과를 통째로 뺐다. 고른 줄은 이름이 굵어 그 줄만 빠졌다).
    private func listRow(_ item: SubAgentListItem, selected: Bool, share: TokenShare) -> some View {
        let digest = self.digest(item)
        let depth = min(item.depth, 3)
        return Button {
            model.focusSubAgent(threadID: threadID, agentID: item.id)
        } label: {
            HStack(spacing: 7) {
                if depth > 0 {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(Theme.slate3)
                        .frame(width: 10)
                }
                SubAgentStatusMark(digest: digest)
                    .frame(width: 12)
                // 마지막 단계가 들어가지 않으면 그 단계를 받은 폭에 그린다 — 이름만 줄어든다 (나머지 열은 고정 폭).
                ViewThatFits(in: .horizontal) {
                    rowContent(item, digest: digest, selected: selected, share: share, kind: true)
                    rowContent(item, digest: digest, selected: selected, share: share, kind: false)
                }
            }
            .padding(.leading, 8 + CGFloat(max(0, depth - 1)) * 14)
            .padding(.trailing, 8)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected { RoundedRectangle(cornerRadius: 6).fill(Theme.well) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .help(rowHelp(item))
        .accessibilityLabel(rowAccessibility(item))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 줄의 도움말: 종류 · 상태 · 이름, 맡은 일(앞부분), 처리 토큰(정확한 수 — 새 토큰을 알면 함께).
    private func rowHelp(_ item: SubAgentListItem) -> String {
        var text: String = "\(SubAgentDigest.kindName(item.info.kind)) · \(item.statusText)\n\(item.info.title)"
        if let task = assignedTask(item) { text += "\n맡은 일: " + JSONUtil.truncate(task, max: 300) }
        if let tokens = item.info.totalTokens {
            text += "\n처리 토큰 \(DisplayFormat.exactTokens(tokens))"
            if let new = item.info.newTokens { text += " (새 토큰 \(DisplayFormat.exactTokens(new)))" }
        }
        return text
    }

    private func rowAccessibility(_ item: SubAgentListItem) -> String {
        var text: String = "\(SubAgentDigest.kindName(item.info.kind)) \(item.info.title), \(item.statusText)"
        if let tokens = item.info.totalTokens { text += ", 처리 토큰 \(DisplayFormat.tokens(tokens))" }
        return text
    }

    private func rowContent(_ item: SubAgentListItem, digest: SubAgentDigest, selected: Bool, share: TokenShare,
                            kind: Bool) -> some View {
        let info = item.info
        return HStack(spacing: 6) {
            Text(info.title)
                .font(Theme.ui(.callout, selected ? .medium : .regular))
                .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
            if kind, let label = SubAgentList.subtitle(info) {
                Text(label)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate2)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if item.isRunning {
                ElapsedText(since: info.startedAt) { SubAgentList.rowFacts(info, elapsedSeconds: $0) }
                    .fixedSize()
            } else {
                factsText(info, elapsed: info.endedAt.map { Int($0.timeIntervalSince(info.startedAt)) })
            }
            tokenColumns(info.totalTokens, fraction: share.fraction(info.totalTokens), emphasized: selected)
            statusColumn(Text(digest.statusText)
                .foregroundColor(item.isRunning ? Theme.ink2 : SubAgentStatusMark.color(digest)))
        }
    }

    private func factsText(_ info: SubAgentInfo, elapsed: Int?) -> some View {
        Text(SubAgentList.rowFacts(info, elapsedSeconds: elapsed))
            .font(Theme.mono(.caption))
            .foregroundStyle(Theme.slate2)
            .fixedSize()
    }

    /// 하위가 맡은 일 (`SubAgentList.assignedTask` — Claude 하위만, Codex 는 요청을 읽을 수 없다).
    private func assignedTask(_ item: SubAgentListItem) -> String? {
        SubAgentList.assignedTask(pane.subAgentEvents[item.id] ?? [])
    }

    private func digest(_ item: SubAgentListItem) -> SubAgentDigest {
        SubAgentDigest(info: item.info, runID: item.runID, runFinished: item.runFinished, toolCount: 0, lastLine: nil)
    }

    // MARK: 고른 하위의 머리

    private func detailHeader(_ item: SubAgentListItem, session: RunSession?) -> some View {
        let info = item.info
        let digest = self.digest(item)
        let parent = parentProvider(item)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                SubAgentStatusMark(digest: digest)
                    .frame(width: 12)
                Text(info.title)
                    .font(Theme.paneHeader)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let model = SubAgentList.modelLabel(info.model) {
                    Text(model)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate2)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 6)
                if item.isLive, info.canStop {
                    Button {
                        let id = info.id
                        Task { await model.stopSubAgent(threadID: threadID, agentID: id) }
                    } label: {
                        Text("멈추기").font(Theme.ui(.caption, .medium)).foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(GhostChipStyle())
                    .help("이 하위 작업만 멈춥니다 — 실행과 다른 하위 작업은 계속됩니다")
                }
            }
            // 한 덩어리의 글 — 좁으면 끝에서 한 번만 줄인다 (따로 둔 글들이 저마다 줄지 않게).
            Group {
                if item.isRunning {
                    // 상태 글은 그대로, 1초마다 바뀌는 나머지(경과 · 토큰 · 도구 · 부모)만 레이어로 (`ElapsedText`).
                    HStack(spacing: 0) {
                        Text(digest.statusText).foregroundColor(SubAgentStatusMark.color(digest))
                            .layoutPriority(1)
                        ElapsedText(since: info.startedAt, mono: false, color: Theme.slate) {
                            " · " + SubAgentDigest.detailFacts(info, elapsedSeconds: $0, parent: parent?.displayName,
                                                               formatTokens: Fmt.tokens)
                        }
                        .help(TokenShare.help)
                    }
                } else {
                    metaLine(digest, elapsed: info.endedAt.map { Int($0.timeIntervalSince(info.startedAt)) }, parent: parent,
                             share: shareText(item))
                }
            }
            .font(Theme.ui(.caption))
            .lineLimit(1)
            .truncationMode(.tail)
            .help(digest.statusText + " · " + SubAgentDigest.detailFacts(info, elapsedSeconds: nil,
                                                                         parent: parent?.displayName, formatTokens: Fmt.tokens))
            if let detail = info.detail, !detail.isEmpty, detail != info.title, detail != "general-purpose" {
                Text(detail)
                    .font(Theme.mono(.caption))
                    .foregroundStyle(Theme.slate2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(detail)
            }
            // 무엇을 맡겼는지 — 띄울 때의 요청 앞부분 두 줄 (전체는 도움말 · 아래 흐름의 첫 줄).
            if let task = assignedTask(item) {
                (Text("맡은 일  ").foregroundColor(Theme.slate) + Text(task).foregroundColor(Theme.ink2))
                    .font(Theme.ui(.caption))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(JSONUtil.truncate(task, max: 1500))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
    }

    private func metaLine(_ digest: SubAgentDigest, elapsed: Int?, parent: AgentProvider?, share: String?) -> Text {
        Text(digest.statusText).foregroundColor(SubAgentStatusMark.color(digest))
            + Text(" · " + SubAgentDigest.detailFacts(digest.info, elapsedSeconds: elapsed, parent: parent?.displayName,
                                                      formatTokens: Fmt.tokens, share: share))
                .foregroundColor(Theme.slate)
    }

    /// 고른 하위가 그 실행에서 처리한 몫 ("42%"). 실행 전체를 모르면 nil.
    private func shareText(_ item: SubAgentListItem) -> String? {
        guard let runID = item.runID else { return nil }
        let infos = pane.subAgentInfos.filter { pane.subAgentRunIDs[$0.key] == runID }.map(\.value)
        let share = TokenShare.make(runUsage: pane.usageByRun[runID], infos: infos)
        guard let fraction = share.fraction(item.info.totalTokens) else { return nil }
        return TokenShare.percentText(fraction)
    }

    // MARK: 흐름

    private func flow(_ item: SubAgentListItem, session: RunSession?) -> some View {
        let info = item.info
        let liveText = item.isLive ? session?.subAgentLiveText[info.id] : nil
        let finalAnswer = finalAnswerToShow(item)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch info.kind {
                    case .workflow:
                        // 워크플로 안의 에이전트는 CLI 가 진행만 보고한다 (메시지 · 도구 기록 없음).
                        progressLines(info)
                    case .shell:
                        shellFlow(item)
                    case .agent, .other:
                        ForEach(rows) { row in flowRow(row) }
                        if rows.isEmpty && (liveText ?? "").isEmpty && item.isRunning {
                            waitingLine(info)
                        }
                    }
                    if let liveText, !liveText.isEmpty {
                        MarkdownMessage(text: liveText, color: Theme.ink2)
                    }
                    outcome(item, finalAnswer: finalAnswer)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 짧은 흐름은 위에 붙이고(아래에 붙이면 빈 칸이 위에 남는다), 처음 열 때와 기록이 붙을 때는 끝(최근 일 · 최종 답)을 보인다.
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onChange(of: rows.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: liveText?.count) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func flowRow(_ row: StreamRow) -> some View {
        switch row {
        case .agentMessage(let event):
            MarkdownMessage(text: event.text, color: Theme.ink2)
        case .execution(_, let entries):
            // 대화 스트림처럼 접힌 한 줄로 — 누르면 단계, 단계를 누르면 자세히 (`ExecutionFold`).
            ExecutionBlockView(entries: entries, indent: 0, foldable: true)
        default:
            // 하위 흐름에는 응답과 실행 기록만 있다 (`StreamBuilder.subAgentRows`).
            EmptyView()
        }
    }

    private func waitingLine(_ info: SubAgentInfo) -> some View {
        HStack(spacing: 7) {
            PendingRing(color: Theme.slate2)
            Text(info.progress.flatMap { $0 == info.title ? nil : $0 } ?? info.lastToolName.map { "도구: \($0)" } ?? "시작했습니다. 기록을 기다리는 중")
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate)
                .lineLimit(2)
        }
    }

    /// 워크플로: 진행 설명 · 마지막 도구 · 토큰 · 도구 수만 (CLI 가 주는 것이 이것뿐이다).
    private func progressLines(_ info: SubAgentInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel("진행")
            if let progress = info.progress, !progress.isEmpty {
                Text(progress).font(Theme.ui(.callout)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            let facts = [info.lastToolName.map { "마지막 도구 \($0)" },
                         info.toolUses.map { "도구 \($0)번" },
                         info.totalTokens.map { "토큰 \(Fmt.tokens($0))" }].compactMap { $0 }
            if !facts.isEmpty {
                Text(facts.joined(separator: " · ")).font(Theme.mono(.caption)).foregroundStyle(Theme.slate)
            }
            if info.progress == nil && facts.isEmpty {
                Text("워크플로는 진행 상황만 보고합니다. 아직 받은 진행이 없습니다.")
                    .font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
            }
        }
    }

    /// 백그라운드 명령: 메인 흐름의 그 명령 행 (출력은 명령이 끝날 때 붙는다). 행의 상태는 작업의 상태를 따른다 —
    /// Claude 의 앵커 결과는 "뒤에서 시작함" 확인이라 행만 보면 도는 명령도 완료로 보인다.
    @ViewBuilder
    private func shellFlow(_ item: SubAgentListItem) -> some View {
        let info = item.info
        let entries = digest(item).applyingStatus(to: anchorEntries)
        if !entries.isEmpty {
            ExecutionBlockView(entries: entries, indent: 0, foldable: true)
        }
        ForEach(rows) { row in flowRow(row) }
        if entries.isEmpty && rows.isEmpty {
            Text(SubAgentList.shellFallbackText(info, provider: parentProvider(item)))
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.ink2)
                .textSelection(.enabled)
        }
    }

    /// 이 하위를 띄운 실행의 제공자 (살아 있는 실행이면 세션의 것).
    private func parentProvider(_ item: SubAgentListItem) -> AgentProvider? {
        item.runID.flatMap { pane.runsByID[$0]?.provider } ?? (item.isLive ? session?.activeProvider : nil)
    }

    /// 끝난 하위의 최종 답 — 흐름의 마지막 응답과 같으면 다시 보이지 않는다 (Codex 는 최종 답이 흐름에도 있다).
    private func finalAnswerToShow(_ item: SubAgentListItem) -> String? {
        guard item.info.status.isFinished, let summary = item.info.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else { return nil }
        let lastMessage = (pane.subAgentEvents[item.id] ?? []).last { $0.kind == .agentMessage }?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return lastMessage == summary ? nil : summary
    }

    @ViewBuilder
    private func outcome(_ item: SubAgentListItem, finalAnswer: String?) -> some View {
        if let finalAnswer {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(item.info.status == .failed ? "오류" : "최종 답")
                MarkdownMessage(text: finalAnswer, color: Theme.ink2)
            }
            .padding(.top, 4)
        }
        if let note = outcomeNote(item) {
            HStack(spacing: 6) {
                Image(systemName: note.symbol)
                    .font(.system(size: 10, weight: .medium))
                Text(note.text)
            }
            .font(Theme.ui(.caption))
            .foregroundStyle(note.color)
        }
    }

    private func outcomeNote(_ item: SubAgentListItem) -> (text: String, symbol: String, color: Color)? {
        if item.info.status == .running && item.runFinished {
            return ("실행이 끝날 때 이 작업의 끝을 보고받지 못했습니다", "questionmark.circle", Theme.slate)
        }
        switch item.info.status {
        case .running: return nil
        case .completed:
            // 하위가 띄운 작업의 결과는 그 하위가 받는다 (메인이 아니라).
            return (SubAgentList.deliveredText(item.info, ownerTitle: ownerTitle(item.info)), "arrow.turn.down.left", Theme.emeraldText)
        case .stopped: return ("끝나기 전에 멈췄습니다", "stop.circle", Theme.slate)
        case .failed: return ("실패했습니다", "xmark.circle", Theme.danger)
        }
    }

    /// 이 작업을 띄운 하위의 이름 (살아 있는 값 먼저). 메인이 띄웠거나 모르면 nil.
    private func ownerTitle(_ info: SubAgentInfo) -> String? {
        guard let ownerID = info.ownerID else { return nil }
        return session?.subAgents.first { $0.id == ownerID }?.title ?? pane.subAgentInfos[ownerID]?.title
    }

    // MARK: 아래 안내

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock")
                .font(.system(size: 10, weight: .medium))
            Text("읽기 전용 — 하위 에이전트에게는 보낼 수 없습니다")
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(Theme.ui(.caption))
        .foregroundStyle(Theme.slate2)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.card)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
    }
}

/// 한 실행에서 누가 얼마나 처리했는지의 가로 막대 — 메인 먼저, 그다음 하위. 조각 사이는 1pt 띄우고, 하위는 번갈아 옅게 칠해
/// 이웃 조각이 섞이지 않게 한다. 고른 하위는 진하게.
struct TokenShareBar: View {
    struct Segment: Identifiable, Hashable {
        var id: String
        var fraction: Double
        var color: Color
        var isMain: Bool
    }
    let segments: [Segment]
    var selectedID: String?

    var body: some View {
        GeometryReader { proxy in
            let gaps = CGFloat(max(0, segments.count - 1))
            let usable = max(0, proxy.size.width - gaps)
            let total = max(segments.reduce(0) { $0 + $1.fraction }, 1)
            HStack(spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    Rectangle()
                        .fill(segment.color.opacity(opacity(segment, index: index)))
                        .frame(width: max(1, usable * segment.fraction / total))
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
            .background(Theme.well)
            .clipShape(Capsule())
        }
        .accessibilityHidden(true)
    }

    private func opacity(_ segment: Segment, index: Int) -> Double {
        if segment.id == selectedID { return 1 }
        if segment.isMain { return 0.85 }
        return index % 2 == 0 ? 0.55 : 0.35
    }
}
