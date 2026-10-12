import AppKit
import SwiftUI

/// 한 칸의 대화 스트림. 흰 종이 위 740pt 본문 단 + 아래에 놓인 채움 상자 입력창.
/// 분할 화면에서는 칸마다 하나씩 놓인다 — "선택된 대화"가 아니라 **받은 대화**(`thread` · `pane`)를 그린다.
struct ThreadView: View {
    @Environment(AppModel.self) private var model
    let thread: ConversationThread
    /// 이 대화의 화면 상태 (이벤트 · 실행 · 인계 …). 행 뷰들은 환경에서 읽는다.
    let pane: ThreadPaneModel
    /// 포커스 칸인지. 앱 전체의 안내(일회성 알림 · 종료 미확인 프로세스)와 ⌘↵ 는 포커스 칸에만 둔다.
    var isFocused = true
    @State private var showThreadSettings = false
    @State private var composerHeight: CGFloat = 150
    /// 대화 열의 가로 자리 (칸 기준). 스크롤 막대가 늘 보이는 설정이면 스크롤 칸이 막대만큼 좁아 열이 왼쪽으로 옮겨 가므로,
    /// 위에 겹친 입력창 덩어리를 이 자리에 맞춘다 (카드 · 말풍선의 오른쪽 끝과 입력창의 오른쪽 끝이 같게).
    @State private var columnBounds = ColumnBounds()

    struct ColumnBounds: Equatable {
        var minX: CGFloat = 0
        var width: CGFloat = 0
    }
    /// 사용자가 위로 올려 읽는 중이면 새 출력이 와도 끌어내리지 않는다 (판정은 `StreamFollow`).
    @State private var followBottom = true
    /// 지금 맨 아래에 붙어 있다.
    @State private var atBottom = true
    /// 사람이 스크롤하는 중 (휠 · 트랙패드 · 스크롤 막대) — 그동안의 위로 움직임만 따라가기를 멈추고, 그동안은 끌어내리지 않는다.
    @State private var userScrolling = false
    @State private var rowsCache = StreamRowsCache()
    /// 대화 안 찾기 (⌘F — `ThreadFindModifier`).
    @State private var find = ThreadFindState()
    /// 한 번에 그리는 최근 행 수 · 맨 위 버튼이 더 불러오는 수 (분할에 따라 — `PaneLayout.streamRowPage`).
    let rowPage: Int
    /// 그리는 최근 행 수. 더 오래된 행은 맨 위 버튼으로 불러온다.
    @State private var rowLimit: Int

    init(thread: ConversationThread, pane: ThreadPaneModel, isFocused: Bool = true,
         rowPage: Int = PaneLayout.single.streamRowPage) {
        self.thread = thread
        self.pane = pane
        self.isFocused = isFocused
        self.rowPage = rowPage
        _rowLimit = State(initialValue: rowPage)
    }

    /// 입력창 뒤로 대화를 흐리게 덮는 높이.
    private var fadeHeight: CGFloat { min(180, composerHeight + 40) }

    /// 이 대화가 일하는 폴더의 프로젝트 (독립 작업 폴더면 경로가 그 폴더).
    private var project: Project? { model.folderProject(for: thread) }

    var body: some View {
        Group {
            if isFresh(thread) {
                freshStart(thread)
            } else {
                ZStack(alignment: .bottom) {
                    stream(thread)
                    LinearGradient(stops: [.init(color: Theme.paper.opacity(0), location: 0),
                                           .init(color: Theme.paper, location: 0.44)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: fadeHeight)
                        .allowsHitTesting(false)
                    // 간격은 위 줄들이 스스로 갖는다 (아래 8) — 제안 자리처럼 비어 있을 때 높이 0 인 자리가 간격을 만들지 않게.
                    VStack(spacing: 0) {
                        if thread.isInternal {
                            // 내부 대화는 기록을 보는 곳이다. 메시지를 보내지 않는다.
                            ComposerNoticeLine(threadID: thread.id)
                            InternalThreadBar(thread: thread)
                        } else {
                            if let job = model.orchestrationSnapshot(for: thread), !job.job.state.isTerminal {
                                OrchestrationCard(snapshot: job)
                                    .padding(.bottom, 8)
                            }
                            // 자동 인계 카드가 생겼는데 위로 올려 읽는 중이라 따라가지 않았다 — 한 줄로 알리고, 누르면 카드로.
                            if !followBottom, let card = model.handoffCards[thread.id], card.automatic, card.attention != .draft {
                                HandoffPeekLine(card: card) { pane.requestScrollToBottom() }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.bottom, 8)
                            }
                            // 자동 인계가 같은 Codex 의 다른 계정을 골랐다 — 카운트다운 뒤 그 계정으로 같은 세션을 이어 간다 (인계 카드 대신).
                            if let countdown = model.codexSwitchCountdowns[thread.id] {
                                CodexSwitchCountdownLine(thread: thread, countdown: countdown)
                            }
                            // 이 대화의 일회성 안내(보내기 실패 · 첨부 오류) — 보낸 자리 바로 위에 (chat-2). 비어 있으면 높이 0.
                            ComposerNoticeLine(threadID: thread.id)
                            // 한도 임박 이어 가기 제안 (C4) — 포커스 칸에서만.
                            if isFocused {
                                ContinueSuggestionSlot(thread: thread, compact: rowPage <= PaneLayout.fourGrid.streamRowPage)
                            }
                            ComposerView(thread: thread, isFocusedPane: isFocused)
                        }
                    }
                        .modifier(ColumnAligned(bounds: columnBounds))
                        .padding(.bottom, 16)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
                }
                .coordinateSpace(.named(Self.columnSpace))
            }
        }
        .background(Theme.paper)
        .environment(pane)
        // 메시지의 상대 경로 링크는 이 대화가 일하는 폴더 기준 (`LinkOpener`).
        .environment(\.messageLinkBase, project?.path)
        // 다른 대화로 바뀌면 최근 행부터 다시 보여준다 — 부르는 쪽이 `.id(thread.id)` 로 이 뷰를 새로 만든다 (`PaneGrid`).
        .sheet(isPresented: $showThreadSettings) { ThreadSettingsSheet(thread: thread) }
    }

    // MARK: 시작 화면

    /// 아직 아무 기록도 없는 스레드 — 실행 · 이벤트 · 인계가 없고 지금 이 스레드에서 도는 실행도 없다.
    /// 내부 대화는 비어 있어도 시작 화면으로 보내지 않는다 — 시작 화면의 입력창이 아래 `thread.isInternal`
    /// 가드를 비켜 가기 때문이다. 내부 대화는 언제나 스트림 배치의 `InternalThreadBar` 로 간다.
    /// 앱이 독립 작업 폴더를 만들며 남긴 기록(명령 · 안내 — `Worktrees.isHousekeeping`)만 있으면 아직 빈 대화로 본다 — 시작 화면에서
    /// 폴더를 골랐다고 시작 화면이 사라지지 않고, 폴더 고르기도 그대로 남는다 (chg-15).
    private func isFresh(_ thread: ConversationThread) -> Bool {
        !thread.isInternal
            && pane.mainEvents.allSatisfy(Worktrees.isHousekeeping) && pane.runsByID.isEmpty && pane.handoffs.isEmpty
            && model.runner.session(threadID: thread.id) == nil && !model.hasHandoffActivity(threadID: thread.id)
    }

    /// 빈 스레드는 스트림 대신 가운데에 물음과 입력창을 둔다 (첫 메시지를 보내면 스트림 배치로 바뀐다).
    /// 목표 머리줄은 두지 않는다 — 스레드 설정은 첫 메시지 뒤에도 늦지 않다. 입력창 아래에 프로젝트 · 브랜치 띠를 붙여
    /// 어느 폴더의 대화인지 보이고, 안내문(보내기 실패 · 이전 실행 정리)은 그 아래에 둔다.
    private func freshStart(_ thread: ConversationThread) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 0) {
                Text("어떤 작업을 할까요?")
                    .font(Theme.ui(.title, .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.bottom, 8)
                // 이 앱이 하는 일 한 줄 (onb-6) — "이어 맡기기 · 인계" 를 처음 만나기 전에.
                Text("한 대화를 Claude Code 와 Codex 가 이어 맡습니다. 입력창의 에이전트에서 다른 에이전트에게 이어 맡기면 인계 문서를 먼저 보여 주고, 넘기기 전에는 아무것도 실행되지 않습니다.")
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 20)
                // 이 대화의 안내(보내기 실패 등)는 입력창 바로 위 — 스트림 배치와 같은 자리.
                ComposerNoticeLine(threadID: thread.id)
                ComposerView(thread: thread, isFocusedPane: isFocused)
                projectStrip(choosesFolder: true)
                notices
                    .padding(.top, 26)
            }
            .frame(maxWidth: Theme.Metric.column)
            .padding(.horizontal, 28)
            Spacer(minLength: 24)
            // 가운데보다 조금 위에 놓는다.
            Color.clear.frame(height: 72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 입력창 아래 한 줄 — 폴더 이름과 브랜치. 배경은 두지 않는다 (입력창이 채움 상자라 같은 색 띠는 상자가 늘어진 것처럼 보인다).
    /// 도움말에 전체 경로.
    /// `choosesFolder` 면(시작 화면) 오른쪽에 작업 폴더 고르기 — 프로젝트 폴더 / 독립 작업 폴더(git worktree).
    private func projectStrip(choosesFolder: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: thread.worktree == nil ? "folder" : "arrow.triangle.branch")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.slate2)
            Text(project?.name ?? "프로젝트 없음")
                .font(Theme.ui(.callout, .medium))
                .foregroundStyle(Theme.slate)
                .lineLimit(1)
            if let branch = model.workspace(forPath: project?.path)?.git?.headLabel, !branch.isEmpty {
                Circle().fill(Theme.slate3).frame(width: 3, height: 3)
                Text(branch)
                    .font(Theme.mono(.caption))
                    .foregroundStyle(Theme.slate2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if choosesFolder { folderPicker }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .help(project?.path ?? "")
    }

    /// 시작 화면의 작업 폴더 고르기. 저장소가 아니면 숨긴다 (worktree 를 만들 수 없다).
    @ViewBuilder
    private var folderPicker: some View {
        let isRepository = model.workspace(forPath: project?.path)?.git?.isRepository == true
        let busy = model.worktreeActivity(threadID: thread.id) != nil
        if isRepository || thread.worktree != nil {
            Menu {
                Button {
                    guard thread.worktree != nil else { return }
                    Task { await model.removeWorktree(threadID: thread.id, force: false, branch: .deleteIfMerged) }
                } label: {
                    Label("프로젝트 폴더에서", systemImage: thread.worktree == nil ? "checkmark" : "folder")
                }
                Button {
                    guard thread.worktree == nil else { return }
                    Task { await model.createWorktree(threadID: thread.id) }
                } label: {
                    Label("독립 작업 폴더에서 (git worktree)", systemImage: thread.worktree != nil ? "checkmark" : "arrow.triangle.branch")
                }
                .disabled(thread.worktree == nil && model.worktreeCreationBlock(thread) != nil)
            } label: {
                HStack(spacing: 4) {
                    if busy { InkSpinner(color: Theme.slate) }
                    Text(thread.worktree == nil ? "프로젝트 폴더" : "독립 작업 폴더")
                        .font(Theme.ui(.caption))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(Theme.slate)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(GhostChipStyle(height: 22, horizontalPadding: 6))
            .fixedSize()
            .disabled(busy)
            .help("이 대화가 일할 폴더. 독립 작업 폴더는 이 대화만의 git worktree 라 같은 프로젝트의 다른 대화와 파일이 섞이지 않고, "
                  + "끝나면 변경사항 탭에서 프로젝트 폴더의 브랜치로 합칩니다.")
        }
    }

    // MARK: 스트림

    private func stream(_ thread: ConversationThread) -> some View {
        // 메인 흐름만 행으로 묶는다. 하위 에이전트의 일은 그 하위를 띄운 행의 카드(요약)로만 보이고, 흐름은 인스펙터 "에이전트" 탭에.
        let allRows = rowsCache.rows(events: pane.mainEvents, runs: pane.runsByID, handoffs: pane.handoffs,
                                     projectPath: project?.path, streaming: pane.streamingMainEvent,
                                     subAgents: SubAgentStreamInput(infos: pane.subAgentInfos, runIDs: pane.subAgentRunIDs,
                                                                    events: pane.subAgentEvents,
                                                                    revision: pane.subAgentRevision,
                                                                    liveRunIDs: liveSubAgentRunIDs))
        let hiddenCount = max(0, allRows.count - rowLimit)
        let rows = Array(allRows.dropFirst(hiddenCount))
        // 자동 인계 카드가 생기면 따라가는 중일 때만 내려간다 (아래 `onChange`). 사람이 연 카드는 모델이 맨 아래로 보낸다.
        let automaticCardID: String? = model.handoffCards[thread.id].flatMap { $0.automatic ? $0.id : nil }
        let compactCard = rowPage <= PaneLayout.fourGrid.streamRowPage
        return ScrollViewReader { proxy in
            ScrollView {
                // LazyVStack 을 쓰지 않는다. 펼친 실행 결과처럼 수천 pt 짜리 행이 섞이면 위로 스크롤할 때
                // 지연 스택의 추정 높이가 크게 흔들려 레이아웃이 수렴하지 않고 앱이 멈춘다.
                // 대신 최근 행만 그려 긴 스레드에서도 그리는 비용을 묶어 둔다.
                VStack(alignment: .leading, spacing: 0) {
                    GoalHeader(thread: thread, turns: pane.runsByID.count) { showThreadSettings = true }
                        .padding(.bottom, Theme.Metric.turnGap)

                    notices

                    // 빈 스레드에는 안내문을 두지 않는다 — 입력창의 플레이스홀더가 할 일을 말한다.
                    if hiddenCount > 0 {
                        Button("⌃ 이전 기록 더 보기 · \(hiddenCount)개 항목") {
                            showOlderRows(proxy, keeping: rows.first?.id)
                        }
                        .buttonStyle(TextButtonStyle(color: Theme.slate2, font: Theme.mono(.caption)))
                        .padding(.bottom, Theme.Metric.turnGap)
                    }

                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        StreamRowView(row: row, findQuery: find.visible && row.id == find.currentRowID ? find.query : nil)
                            .modifier(FindHighlight(active: find.visible && row.id == find.currentRowID))
                            .padding(.top, row.topSpacing(after: index > 0 ? rows[index - 1] : nil))
                            .id(row.id)
                    }

                    pending

                    // 인계 카드 — 스트림 끝, 바닥 여백 앞 (준비 중 · 버린 준비 포함).
                    HandoffCardSlot(thread: thread, compact: compactCard)

                    Color.clear.frame(height: composerHeight + 44).id("bottom")
                }
                .frame(maxWidth: Theme.Metric.column, alignment: .leading)
                // 사람이 휠 · 트랙패드로 위로 굴린 순간 — 화면이 움직이기 전에 따라가기를 멈춘다 (`StreamScrollIntent`).
                .background(StreamScrollIntent { if followBottom { followBottom = false } })
                // 가로 자리만 잰다 (세로 위치는 스크롤마다 바뀌므로 넣지 않는다 — 값이 같으면 다시 그리지 않는다).
                .onGeometryChange(for: ColumnBounds.self) { geometry in
                    let frame = geometry.frame(in: .named(Self.columnSpace))
                    return ColumnBounds(minX: frame.minX.rounded(), width: frame.width.rounded())
                } action: { columnBounds = $0 }
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity)
                .padding(.top, 26)
            }
            .defaultScrollAnchor(.bottom)
            // 스크롤 막대는 흐림 · 입력창 위에서 끝난다 — 맨 아래로 내리면 막대의 손잡이가 흐림 밑에 묻혀 보이지 않았다.
            .contentMargins(.bottom, max(fadeHeight, composerHeight + 16), for: .scrollIndicators)
            // 사람이 위로 올리면 그 자리에서 따라가기를 멈추고, 맨 아래까지 내리면 다시 따라간다. 따라가는 중에 글이 늘어 밀려나면
            // 배치가 끝난 뒤 맨 아래로 다시 붙인다 (`StreamFollow`). 자리는 스크롤마다 바뀌지만 상태는 값이 바뀔 때만 쓴다.
            .onScrollGeometryChange(for: StreamFollow.Spot.self) { geometry in
                // 대화는 투명한 툴바 밑까지 스크롤된다 — `containerSize` 는 그 위 여백(`contentInsets.top`, 52pt)을 빼고 잰 높이라
                // 더해야 맨 아래에서 거리가 0 이다 (2026-10-06 실측: 맨 아래인데 52 로 읽혀 끝까지 내려도 다시 따라가지 않았다).
                StreamFollow.Spot(offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
                                  containerHeight: geometry.containerSize.height + geometry.contentInsets.top)
            } action: { old, new in
                let bottom = new.distanceFromBottom <= StreamFollow.bottomTolerance
                if atBottom != bottom { atBottom = bottom }
                if let follow = StreamFollow.follow(from: old, to: new, userScrolling: userScrolling),
                   followBottom != follow { followBottom = follow }
                // 이때는 배치가 끝난 자리라 바로 내려도 새 글의 끝으로 간다.
                if StreamFollow.needsPin(following: followBottom, userScrolling: userScrolling, at: new) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            // 사람이 스크롤하는 동안(휠 · 트랙패드 · 스크롤 막대 — interacting 등)은 끌어내리지 않는다. 휠이 아닌 스크롤 막대로 올린 것도
            // 이때의 움직임으로 센다 (`StreamFollow.follow`). 앱의 `scrollTo` 는 이 단계를 만들지 않는다 (2026-10-06 실측).
            .onScrollPhaseChange { _, newPhase in
                let user = [ScrollPhase.tracking, .interacting, .decelerating].contains(newPhase)
                if userScrolling != user { userScrolling = user }
            }
            // 메인 흐름 기준 — 하위 에이전트가 일할 때마다(메인과 무관한 조각) 끌어내리지 않는다.
            .onChange(of: pane.mainEvents.count) { oldCount, _ in
                // 스레드 기록이 처음 채워질 때는 항상 맨 아래에서 시작한다.
                if oldCount == 0 { jumpToBottom(proxy) } else { scrollIfFollowing(proxy) }
            }
            // 흐르는 응답의 길이 — 하위의 승인 · 앵커 결과가 그 뒤에 붙어도 따라간다 (마지막 이벤트가 아닐 수 있다).
            .onChange(of: (pane.streamingMainEvent ?? pane.mainEvents.last)?.text.count) { scrollIfFollowing(proxy) }
            // 따라가는 중이면 다시 내린다 (`BottomSettleKey` — 뒤따라 스크롤을 일으키는 변화가 없는 마지막 내용들).
            .onChange(of: BottomSettleKey(decisions: pendingDecisionCount, automaticCardID: automaticCardID,
                                          composerHeight: composerHeight)) { settleIfFollowing(proxy) }
            .onChange(of: pane.mainEvents.first?.id) { jumpToBottom(proxy) }
            // 보냈다 (↵ · 보내기 원 · 대기열에 넣음): 위로 올려 읽던 중이어도 끝으로 가서 따라간다.
            .onChange(of: pane.scrollToBottomRequest) { jumpToBottom(proxy) }
            // 위로 올려 읽는 중에 새 행이 붙으면 창을 늘려, 읽던 행이 위에서 빠지지 않게 한다.
            .onChange(of: allRows.count) { oldCount, newCount in
                if !followBottom, oldCount > 0, newCount > oldCount { rowLimit += newCount - oldCount }
            }
            // 분할을 바꿔 이 칸이 남았다: 맨 아래를 보고 있으면 새 분할의 행 수로, 위로 올려 읽는 중이면 줄이지 않는다.
            .onChange(of: rowPage) { _, page in
                rowLimit = followBottom ? page : max(rowLimit, page)
            }
            // 대화 안 찾기 — 막대 · 메뉴 명령 · 결과로 옮겨 가기 (UI/ThreadFindBar.swift).
            .modifier(ThreadFindModifier(threadID: thread.id, state: $find, rows: allRows, rowLimit: $rowLimit,
                                         followBottom: $followBottom, proxy: proxy))
        }
    }

    /// 이전 행을 더 그린다. 새 행이 위에 붙어도 읽던 행이 그 자리에 남도록 이전 첫 행을 위에 맞춘다.
    /// 같은 턴에서 바로 `scrollTo` 하면 새 행이 배치되기 전 위치로 가므로(실측), 다음 런루프로 미룬다.
    private func showOlderRows(_ proxy: ScrollViewProxy, keeping anchorID: String?) {
        rowLimit += rowPage
        guard let anchorID else { return }
        DispatchQueue.main.async { proxy.scrollTo(anchorID, anchor: .top) }
    }

    /// 이 대화에 떠 있는 승인 · 질문 수 (카드가 붙을 때 끝으로 따라가기용).
    private var pendingDecisionCount: Int {
        guard let session = model.runner.session(threadID: thread.id) else { return 0 }
        return session.pendingApprovals.count + session.pendingQuestions.count
    }

    private func scrollIfFollowing(_ proxy: ScrollViewProxy) {
        guard followBottom, !atBottom else { return }
        pinToBottom(proxy)
    }

    /// 맨 아래로 붙인다 — 배치가 끝난 다음 차례에, 애니메이션 없이. 같은 차례의 `scrollTo` 는 새 글이 배치되기 전 자리로 가고,
    /// 애니메이션은 늘기 전 자리에서 시작해 한 줄 위로 튀었다가 내려왔다 (2026-10-06 실측).
    private func pinToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            guard followBottom, !userScrolling else { return }
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    /// 따라가는 중이면 끝으로 가고, 새 행이 배치된 뒤 한 번 더 내린다 (같은 턴의 `scrollTo` 는 배치 전 위치로 간다 — 실측).
    /// 흐르는 글처럼 자주 바뀌는 곳에는 쓰지 않는다 (바뀔 때마다 작업이 생긴다).
    static let columnSpace = "threadColumn"

    /// 입력창 덩어리를 대화 열과 같은 가로 자리에 둔다. 열을 아직 재지 않았으면 열과 같은 규칙(가운데 · 최대 폭 · 좌우 28).
    private struct ColumnAligned: ViewModifier {
        let bounds: ColumnBounds

        func body(content: Content) -> some View {
            if bounds.width > 0 {
                content
                    .frame(width: bounds.width)
                    .padding(.leading, bounds.minX)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                content
                    .frame(maxWidth: Theme.Metric.column)
                    .padding(.horizontal, 28)
            }
        }
    }

    /// 바뀌면 따라가는 중일 때 맨 아래로 다시 내리는 것들:
    /// - 승인 · 질문 카드 수 — 실행이 멈춘 뒤 붙는 마지막 내용이라 뒤따라 스크롤을 다시 일으키는 변화가 없다. 카드가 배치된 뒤
    ///   한 번 더 내려야 화면 밖(카드 없는 옛 바닥)에 남지 않는다.
    /// - 자동 인계 카드 — 따라가는 중일 때만 (위로 올려 읽는 중이면 입력창 위의 한 줄이 알린다).
    /// - 입력창 덩어리의 높이 (늦게 끼어든 이어 가기 제안 줄 · 대기열 행 · 첨부 줄) — 바닥 여백이 함께 자라므로, 내리지 않으면 마지막
    ///   답이 입력창 덩어리 뒤에 가려진다.
    private struct BottomSettleKey: Equatable {
        var decisions: Int
        var automaticCardID: String?
        var composerHeight: CGFloat
    }

    private func settleIfFollowing(_ proxy: ScrollViewProxy) {
        guard followBottom else { return }
        scrollIfFollowing(proxy)
        Task {
            for delay in [60, 180] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard followBottom, !userScrolling else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// 기록이 막 채워진 직후에는 레이아웃이 끝나지 않았을 수 있어, 잠시 뒤 한 번 더 내려 실제 끝에 맞춘다.
    private func jumpToBottom(_ proxy: ScrollViewProxy) {
        followBottom = true
        proxy.scrollTo("bottom", anchor: .bottom)
        Task {
            for delay in [60, 180] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard followBottom, !userScrolling else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// 종료 미확인 프로세스 경고 — 포커스 칸의 대화 맨 위. 이 대화의 알림은 입력창 바로 위에(`ComposerNoticeLine`), 대화와 무관한
    /// 알림은 창의 가운데 칸 맨 위에(`ComposerNoticeLine(windowWide:)` — `ContentView`) 따로 그린다.
    /// (인계 카운트다운 · 검토는 대화 끝의 인계 카드가 말한다 — `HandoffCardSlot`.)
    @ViewBuilder
    private var notices: some View {
        if isFocused, !model.unterminatedProcessNotes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    // 이 잠금이 막는 것 전부 — 인계 · git 쓰기 (chg-17). 보내기는 막지 않는다 (`RunCoordinator.send` 는 보지 않는다).
                    Text("종료가 확인되지 않은 프로세스가 있습니다 — 인계 · git 쓰기를 막아 두었습니다")
                        .font(Theme.ui(.callout, .semibold)).foregroundStyle(Theme.ink)
                    Spacer()
                    Button("확인함") { model.acknowledgeUnterminatedProcesses() }
                        .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
                        .help("아래 프로세스가 끝났거나 직접 정리했으면 누르세요. 잠금이 풀립니다.")
                }
                ForEach(model.unterminatedProcessNotes, id: \.self) { note in
                    Text(note).font(Theme.mono(.caption)).foregroundStyle(Theme.slate)
                }
            }
            .leadingRule(Theme.amber, width: 2, gap: 13)
            .padding(.bottom, Theme.Metric.turnGap)
        }
    }

    /// 지금 사용자의 판단을 기다리는 승인·질문. 스트림 끝에 둔다.
    @ViewBuilder
    private var pending: some View {
        // 이 대화의 실행이 기다리는 것만 (다른 대화의 승인은 그 대화에 뜬다).
        let session = model.runner.session(threadID: thread.id)
        let approvals = session?.pendingApprovals ?? []
        let questions = session?.pendingQuestions ?? []
        // 도는 동안 무엇을 하는지 (생각 중 · 답변 작성 중 · 명령 실행 중 …) · 경과.
        RunStatusLine(threadID: thread.id, projectPath: project?.path)
        // 하위 에이전트가 청한 것은 그 하위의 이름을 붙인다. 메뉴의 승인 명령(⌥⌘↵ · ⌥⌘⌫)은 **포커스 칸의** 맨 앞 카드가 받는다 —
        // 승인 카드가 있으면 그 첫 카드, 없으면 첫 질문. 단축키 안내도 그 카드에만 — 다른 칸의 카드에 안내가 뜨면 사람이 읽던 카드가
        // 아니라 포커스 칸의 카드가 허용됐다 (vis-2). 카드의 정체는 실행 ID 까지 (Codex 의 요청 ID 는 실행마다 0 부터다).
        ForEach(approvals) { request in
            PendingApprovalView(request: request, agentName: subAgentName(request.agentID, session: session),
                                projectPath: project?.path, threadID: thread.id,
                                isFirst: isFocused && request.id == approvals.first?.id)
                .id("\(request.runID)|\(request.id)")
                .padding(.top, Theme.Metric.turnGap)
        }
        ForEach(questions) { question in
            PendingQuestionView(question: question, agentName: subAgentName(question.agentID, session: session),
                                threadID: thread.id, isFirst: isFocused && approvals.isEmpty && question.id == questions.first?.id)
                .id("\(question.runID)|\(question.id)")
                .padding(.top, Theme.Metric.turnGap)
        }
    }

    /// 하위 작업을 띄운 실행 중 지금 세션이 도는 것. 여기에 없는(끝나지 않은 상태로 DB 에 남은) 실행의 `running` 하위는
    /// "결과 미확인" 으로 보인다 — 충돌 · 강제 종료 뒤 사람이 "정리" 를 누르기 전에도.
    private var liveSubAgentRunIDs: Set<String> {
        var out = Set<String>()
        for runID in Set(pane.subAgentRunIDs.values) where pane.runsByID[runID]?.state.isTerminal != true {
            if model.liveSession(runID: runID) != nil { out.insert(runID) }
        }
        return out
    }

    /// 하위 작업의 이름 — 살아 있는 실행의 값, 없으면 저장된 상태 행의 값.
    private func subAgentName(_ id: String?, session: RunSession?) -> String? {
        guard let id else { return nil }
        return session?.subAgents.first { $0.id == id }?.title ?? pane.subAgentInfos[id]?.title
    }
}

// 행 캐시(`StreamRowsCache`)는 순수 코드라 `UI/Stream/StreamModel.swift` 에 있다 (검증 하네스가 컴파일한다).

// MARK: - 입력창 위의 안내

/// 이 대화의 일회성 안내(보내기 실패 · 첨부 오류 · 대기열에 걸기 전 확인) — 입력창 바로 위 한 덩어리 (chat-2). 보낸 자리에서 보인다:
/// 대화 맨 위에 두면 기록이 있는 대화에서는 ↵ 가 아무 일도 하지 않은 것처럼 보였다 (보내면 맨 아래로 내려가므로).
/// 동작 단추는 안내가 정한다 — 여는 곳(시작 점검 · 설정 > 에이전트)이면 이 화면이 연다 (설정 창은 화면만 열 수 있다).
/// 안내가 없으면 아무것도 그리지 않는다 (높이 0 — 간격은 이 줄이 스스로 갖는다).
///
/// `windowWide` 는 창의 가운데 칸 맨 위에 놓는 같은 모양의 줄이다 (`ContentView`): 대화와 무관한 알림, 그리고 어느 칸에도 열려 있지
/// 않은 대화의 알림. 예전에는 포커스 칸 스크롤의 맨 위에 그려 긴 대화를 아래에서 보고 있으면 보이지 않았고, 빈 칸 · 에이전트
/// 기록 화면에서는 그릴 곳이 없었다 (chr-4).
struct ComposerNoticeLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let threadID: String?
    var windowWide = false

    init(threadID: String) {
        self.threadID = threadID
    }

    init(windowWide: Bool) {
        self.threadID = nil
        self.windowWide = windowWide
    }

    private func shows(_ banner: AppModel.BannerMessage) -> Bool {
        guard windowWide else { return banner.threadID == threadID }
        guard let id = banner.threadID else { return true }
        return !model.panes.threadIDs.contains(id)
    }

    var body: some View {
        if let banner = model.banner, shows(banner) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: banner.isError ? "exclamationmark.circle.fill" : "info.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(banner.isError ? Theme.danger : Theme.slate2)
                    .padding(.top, 1)
                Text(banner.text)
                    .font(Theme.ui(.callout))
                    .foregroundStyle(banner.isError ? Theme.ink : Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let title = banner.actionTitle, banner.opens != nil || banner.action != nil {
                    Button(title) { perform(banner) }
                        .buttonStyle(ChipButtonStyle(height: 25, horizontalPadding: 10))
                        .fixedSize()
                }
                Button("닫기") { if model.banner?.id == banner.id { model.banner = nil } }
                    .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(banner.isError ? Theme.danger.opacity(0.35) : Theme.hair))
            .padding(.bottom, 8)
            .accessibilityElement(children: .contain)
        }
    }

    private func perform(_ banner: AppModel.BannerMessage) {
        switch banner.opens {
        case .firstRunCheck?:
            model.showFirstRunSheet = true
        case .agentSettings?:
            SettingsTab.select(.agents)
            openSettings()
        case .handoffSettings?:
            SettingsTab.select(.handoff)
            openSettings()
        case nil:
            banner.action?()
        }
        if model.banner?.id == banner.id { model.banner = nil }
    }
}

// MARK: - 목표 머리줄

private struct GoalHeader: View {
    let thread: ConversationThread
    let turns: Int
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if thread.goal.isEmpty {
                    // 목표가 없으면 문장 대신 작은 글자 버튼 하나. 설명은 도움말에.
                    Button("목표 추가", action: onEdit)
                        .buttonStyle(TextButtonStyle(color: Theme.slate2, font: Theme.ui(.caption)))
                        .help("이 대화의 목표 · 고정 메모 — 적어 두면 인계 문서에 늘 들어갑니다")
                } else {
                    SectionLabel("목표")
                    Text(thread.goal)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(thread.goal + (thread.pinnedNotes.isEmpty ? "" : "\n\n고정 메모: \(thread.pinnedNotes)"))
                }
                Spacer(minLength: 8)
                if turns > 0 {
                    Text("턴 \(turns)").font(Theme.meta).foregroundStyle(Theme.slate2)
                }
                IconButton(systemName: "slider.horizontal.3", size: 11.5, color: Theme.slate2,
                           help: "목표 · 고정 메모 편집", action: onEdit)
            }
            Rectangle().fill(Theme.hairSoft).frame(height: 1)
        }
    }
}

// MARK: - 승인 · 질문

/// 대화 끝의 한 줄: 도는 실행이 지금 무엇을 하는지(`RunActivity`) · 이 실행의 경과 · 중단 단축키.
/// 이 대화에 실행이 없으면 아무것도 그리지 않는다. 도는 표시는 하는 일마다 모양이 다른 점 구(`RunOrb`)이고 그 칸만 매 프레임
/// 다시 그린다. 경과는 레이어 시계 (`ElapsedText`).
private struct RunStatusLine: View {
    @Environment(AppModel.self) private var model
    @Environment(ThreadPaneModel.self) private var pane
    let threadID: String
    let projectPath: String?

    var body: some View {
        if let session = model.runner.session(threadID: threadID), session.isBusy {
            // 사람을 기다리는 것이 질문뿐이면 "승인" 이 아니라 "질문" 이라고 쓴다.
            let questionOnly = session.pendingApprovals.isEmpty && !session.pendingQuestions.isEmpty
            let (activity, work) = RunActivity.read(state: session.state, runID: session.activeRun?.id,
                                                    waitingOnBackground: session.isWaitingOnBackground,
                                                    backgroundCount: session.unfinishedSubAgentCount,
                                                    events: pane.mainEvents, streaming: pane.streamingMainEvent,
                                                    projectPath: projectPath, questionOnly: questionOnly,
                                                    summary: session.progressSummary)
            // 백그라운드 작업을 기다리는 동안은 기다린 시간을 센다 (글이 "…를 기다리는 중" 이다). 이 기다림의 시계는 여기 하나다 —
            // 턴 머리줄 · 칸 머리는 수만 보인다.
            let clockStart: Date? = Self.clockStart(session)
            let provider = session.activeProvider ?? .claude
            HStack(spacing: 9) {
                // 20pt 구를 머리줄 로고 칸 가운데에 — 칸(14pt)보다 커서 양옆으로 3pt 넘친다. 글은 그대로 agentIndent 에서 시작한다.
                RunOrb(work: work)
                    .frame(width: Theme.Metric.agentIndent - 9)
                Text(activity.text)
                    .font(Theme.ui(.callout))
                    .foregroundStyle(Theme.slate)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let started = clockStart {
                    // 1초 시계는 레이어로 (SwiftUI 갱신 없이 — `ElapsedText`).
                    ElapsedText(since: started) { DisplayFormat.elapsed(seconds: $0) }
                        .fixedSize()
                }
                Spacer(minLength: 8)
            }
            .padding(.top, Theme.Metric.turnGap)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(provider.displayName) \(activity.text)")
        }
    }

    /// 시계의 시작: 백그라운드 작업을 기다리는 동안은 기다리기 시작한 때 (글이 "…를 기다리는 중" 이다), 그 밖에는 실행을 시작한 때.
    private static func clockStart(_ session: RunSession) -> Date? {
        if session.isWaitingOnBackground, let since = session.waitingSince { return since }
        return session.activeRun?.startedAt
    }
}

/// 메뉴의 승인 명령(⌥⌘↵ 허용 · ⌥⌘⌫ 거절, `MenuShortcut.approvalAllow` · `approvalDeny`)을 포커스 칸의 맨 앞 카드에 전한다.
/// 메뉴는 카드의 막음(`ApprovalCardGate`) · 사유 칸 · 입력 칸을 모르므로 카드가 받아 단추와 같은 길로 결정한다.
enum ApprovalShortcut {
    enum Action: String { case allow, deny }
    static let notification = Notification.Name("handoffConsoleApprovalShortcut")

    static func post(_ action: Action, threadID: String?) {
        guard let threadID else { return }
        NotificationCenter.default.post(name: notification, object: nil,
                                        userInfo: ["threadID": threadID, "action": action.rawValue])
    }

    /// 이 대화에 온 명령이면 그 동작.
    static func action(_ note: Notification, threadID: String) -> Action? {
        guard note.userInfo?["threadID"] as? String == threadID, let raw = note.userInfo?["action"] as? String else { return nil }
        return Action(rawValue: raw)
    }
}

/// 승인 대기 카드: "<누가>: <무엇을> 하려고 합니다" 한 줄 · (되돌릴 수 없는 명령이면 경고 줄) · 설명 · 도구별로 푼 본문 · 결정 단추.
/// 본문은 `ApprovalPresentation` 이 정한다 — 명령은 셸 상자, 편집은 바뀐 줄, 모르는 도구는 이름: 값, MCP 입력 요청은 입력 칸.
/// 앞 카드를 허용하자마자 다음 카드가 같은 자리에 뜨면 이어 누른 손이 확인하지 않은 요청을 허용할 수 있다 — 막 나타난 카드는
/// 잠깐 단추를 받지 않고(`ApprovalCardGate`), 한 번 누르면 카드가 빠질 때까지 모든 단추를 끈다. 나타날 때 짧게 떠올라 바뀐 것이 보인다.
struct PendingApprovalView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let request: ApprovalRequest
    /// 하위 에이전트가 청했으면 그 하위의 이름.
    var agentName: String? = nil
    var projectPath: String? = nil
    /// 이 카드가 놓인 대화 — 메뉴의 승인 명령(`ApprovalShortcut`)을 받을지 가른다.
    var threadID: String? = nil
    /// 포커스 칸에 놓인 이 대화의 맨 앞 승인 카드인가 — 메뉴의 승인 명령은 그 카드만 받고, 단축키 안내 · 도움말의 기호도 그 카드에만 둔다.
    var isFirst = true
    @State private var denyReason = ""
    @State private var showsReason = false
    @FocusState private var reasonFocused: Bool
    /// 나타난 때 — 막 나타난 카드는 단추를 받지 않는다 (`ApprovalCardGate`).
    @State private var shownAt: Date?
    @State private var armed = false
    /// 결정을 보냈다 — 응답이 끝나 카드가 빠질 때까지 단추를 모두 끈다 (같은 응답을 두 번 보내지 않게).
    @State private var responding = false
    @State private var appeared = false
    /// MCP 입력 요청의 칸 값 (칸 이름 → 글).
    @State private var formValues: [String: String] = [:]

    private var subject: String {
        if request.agentID != nil, let agentName { return "하위 에이전트 \(agentName)" }
        return request.provider.displayName
    }

    private var shown: ApprovalPresentation { ApprovalPresentation.make(request, projectPath: projectPath) }

    var body: some View {
        let shown = shown
        VStack(alignment: .leading, spacing: 10) {
            // 제목은 한 줄 — 좁으면 오른쪽의 "승인 대기" 를 뺀다 (카드의 바탕 · 칸 머리 · 결정 단추가 이미 보인다).
            // 그래도 넘치면(아주 좁은 칸 · 긴 하위 에이전트 이름) 이름과 할 일을 두 줄로 — 문장 가운데서 꺾지 않는다.
            // 조사는 이름에 따라 바뀌지 않는 쌍점 꼴.
            ViewThatFits(in: .horizontal) {
                titleRow(shown.action, badge: true)
                titleRow(shown.action, badge: false)
                stackedTitle(shown.action)
            }
            if let risk = shown.risk {
                riskLine(risk)
            }
            if let summary = shown.summary {
                Text(summary)
                    .font(Theme.ui(.callout))
                    .foregroundStyle(Theme.ink2)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(shown.blocks.enumerated()), id: \.offset) { _, block in
                ApprovalBlockView(block: block)
            }
            if let form = shown.form {
                ElicitationFormView(form: form, values: $formValues)
                    .disabled(responding)
            }
            if let cwd = shown.workingDirectory {
                Text("실행 위치 · \(CommandWrap.visibleLine(cwd))")
                    .font(Theme.mono(.caption))
                    .foregroundStyle(Theme.slate)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            decisions(shown)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.approvalWell, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(shown.risk == nil ? Theme.approvalBorder : Theme.danger, lineWidth: shown.risk == nil ? 1 : 1.5))
        // 등장: 짧게 떠오른다 — 같은 자리에 다음 카드가 이어 뜰 때 바뀐 것이 보이게. 동작 줄이기면 옅게 나타나기만.
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 8)
        .onAppear {
            shownAt = Date()
            if shown.revealsReason { showsReason = true }
            withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.22)) { appeared = true }
            AccessibilityNotification.Announcement("\(subject): \(shown.action) — 승인이 필요합니다").post()
        }
        .task(id: request.id) {
            try? await Task.sleep(for: .seconds(ApprovalCardGate.armDelay))
            armed = true
        }
        .onReceive(NotificationCenter.default.publisher(for: ApprovalShortcut.notification)) { note in
            guard isFirst, let threadID, let action = ApprovalShortcut.action(note, threadID: threadID) else { return }
            switch action {
            case .allow: primary(shown)
            case .deny: secondary(shown)
            }
        }
    }

    private func titleRow(_ action: String, badge: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            BrandMark(provider: request.provider, size: 13)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text("\(subject): \(action)")
                .font(Theme.ui(.body, .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 8)
            if badge {
                Text("승인 대기")
                    .font(Theme.ui(.caption, .semibold))
                    .foregroundStyle(Theme.amberText)
            }
        }
    }

    /// 한 줄에 안 들어갈 때: 첫 줄은 로고 · 이름, 둘째 줄은 할 일 (필요하면 그 안에서 접는다).
    private func stackedTitle(_ action: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                BrandMark(provider: request.provider, size: 13)
                Text(subject)
                    .font(Theme.ui(.callout, .semibold))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
            }
            Text(action)
                .font(Theme.ui(.body, .semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 되돌릴 수 없는 명령의 경고 줄 (`CommandRisk`).
    private func riskLine(_ risk: CommandRisk) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.danger)
            Text("되돌릴 수 없는 명령 — \(CommandWrap.visibleLine(risk.text))")
                .font(Theme.ui(.callout, .semibold))
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help("허용하면 되돌리기 어렵습니다. 명령과 실행 위치를 확인하세요. 이 카드에는 '이번 실행 동안 허용' 을 두지 않습니다.")
        .accessibilityElement(children: .combine)
    }

    /// 결정 단추. 단추 글은 줄이지 않는다 — 한 줄에 안 들어가면(분할 화면의 좁은 칸) 두 줄로 나눈다.
    private func decisions(_ shown: ApprovalPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    primaryButtons(shown)
                    secondaryButtons(shown)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { primaryButtons(shown) }
                    HStack(spacing: 8) { secondaryButtons(shown) }
                }
            }
            if let note = shown.sessionScopeNote {
                // "이번 실행 동안 허용" 이 무엇을 언제까지 묻지 않는지 — 도움말이 아니라 보이는 글로.
                Text("이번 실행 동안 허용: \(note)")
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsReason {
                TextField(shown.reasonPlaceholder, text: $denyReason)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(.callout))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hair))
                    .autocorrectionDisabled()
                    .focused($reasonFocused)
                    // ↵ 는 이 사유로 거절한다 — 질문 카드면 적은 답을 보낸다 (단추와 같은 막음).
                    .onSubmit { secondary(shown) }
                    .disabled(responding)
            }
            if isFirst {
                Text(shortcutHint(shown))
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate2)
                    .accessibilityLabel("단축키: 옵션 커맨드 리턴으로 \(shown.primaryTitle), 옵션 커맨드 지우기로 \(shown.denyTitle)")
            }
        }
    }

    /// 단추를 받지 않는 동안 (막 나타남 · 응답 중).
    private var buttonsLocked: Bool { !armed || responding }

    @ViewBuilder
    private func primaryButtons(_ shown: ApprovalPresentation) -> some View {
        Button(shown.primaryTitle) { primary(shown) }
            .buttonStyle(InkButtonStyle())
            .fixedSize()
            .disabled(buttonsLocked || !(shown.form?.problems(formValues).isEmpty ?? true))
            .help((shown.form == nil ? shown.primaryTitle : "입력한 값을 MCP 서버에 보냅니다") + allowSymbol)
        if shown.offersSessionScope {
            Button("이번 실행 동안 허용") { decide(.allowForSession) }
                .buttonStyle(ChipButtonStyle(radius: 6))
                .fixedSize()
                .disabled(buttonsLocked)
                .help(shown.sessionScopeNote ?? "")
        }
        Button(shown.denyTitle) { secondary(shown) }
            .buttonStyle(ChipButtonStyle(radius: 6))
            .fixedSize()
            // 질문 카드는 답을 적어야 보낸다 (빈 답은 보낼 것이 없다).
            .disabled(buttonsLocked || shown.denyDecision(denyReason) == nil)
            .help(denyHelp(shown) + (isFirst ? " (\(MenuShortcut.approvalDeny.symbol))" : ""))
    }

    /// 도움말 끝의 단축키 기호 — 메뉴의 명령을 받는 카드에만.
    private var allowSymbol: String { isFirst ? " (\(MenuShortcut.approvalAllow.symbol))" : "" }

    @ViewBuilder
    private func secondaryButtons(_ shown: ApprovalPresentation) -> some View {
        if shown.offersReason, !showsReason {
            Button("사유 적기") {
                showsReason = true
                reasonFocused = true
            }
            .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
            .fixedSize()
            .disabled(responding)
        }
        Spacer(minLength: 8)
        Button("거절 후 중단") { decide(.denyAndCancel(denyReason)) }
            .buttonStyle(TextButtonStyle(color: Theme.danger))
            .fixedSize()
            .disabled(buttonsLocked)
            .help("거절하고 이 실행을 멈춥니다")
    }

    /// 맨 앞 카드의 단축키 안내 한 줄.
    private func shortcutHint(_ shown: ApprovalPresentation) -> String {
        var hint = "\(MenuShortcut.approvalAllow.symbol) \(shown.primaryTitle) · \(MenuShortcut.approvalDeny.symbol) \(shown.denyTitle)"
        if showsReason { hint += shown.revealsReason ? " · 칸에서 ↵ 로 보내기" : " · 사유 칸에서 ↵ 로 거절" }
        return hint
    }

    private func denyHelp(_ shown: ApprovalPresentation) -> String {
        if request.kind == .elicitation { return "입력을 보내지 않습니다" }
        if shown.answersQuestion { return "칸에 적은 답을 \(request.provider.displayName) 에게 보냅니다" }
        return "거절하고 에이전트가 다른 방법을 찾게 합니다"
    }

    /// 주 단추 · ⌥⌘↵: 입력 칸이 있으면 채운 값을 보내고(다 채웠을 때만), 아니면 허용.
    private func primary(_ shown: ApprovalPresentation) {
        if let form = shown.form {
            guard let content = form.contentJSON(formValues) else { return }
            decide(.submit(content))
        } else {
            decide(.allow)
        }
    }

    /// 거절 단추 · ⌥⌘⌫ · 칸의 ↵: 거절 (사유 칸의 글과 함께). 질문 카드는 적은 답을 보낸다 — 비었으면 보내지 않고 답 칸으로.
    private func secondary(_ shown: ApprovalPresentation) {
        guard let decision = shown.denyDecision(denyReason) else {
            showsReason = true
            reasonFocused = true
            return
        }
        decide(decision)
    }

    /// 단추 · 단축키 · ↵ 의 한 길. 막 나타났거나 이미 보냈으면 받지 않는다.
    private func decide(_ decision: ApprovalDecision) {
        guard ApprovalCardGate.accepts(shownAt: shownAt, now: Date(), responding: responding) else { return }
        responding = true
        reasonFocused = false
        let request = request
        Task { await model.runner.respond(approval: request, decision: decision) }
    }
}

/// MCP 입력 요청의 입력 칸 (`ElicitationForm`). 값은 카드가 갖는다 — 칸 이름 → 글.
private struct ElicitationFormView: View {
    let form: ElicitationForm
    @Binding var values: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(form.fields) { field in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(field.title)
                            .font(Theme.ui(.callout, .medium))
                            .foregroundStyle(Theme.ink2)
                        if field.required {
                            Text("필수").font(Theme.ui(.caption)).foregroundStyle(Theme.slate2)
                        }
                    }
                    if let detail = field.detail {
                        Text(detail)
                            .font(Theme.ui(.caption))
                            .foregroundStyle(Theme.slate)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    input(field)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.codeBorder))
    }

    private func text(_ field: ElicitationForm.Field) -> Binding<String> {
        Binding(get: { values[field.id] ?? field.initial }, set: { values[field.id] = $0 })
    }

    @ViewBuilder
    private func input(_ field: ElicitationForm.Field) -> some View {
        switch field.kind {
        case .text, .number:
            TextField(field.kind == .text ? "값" : "수", text: text(field))
                .textFieldStyle(.plain)
                .font(Theme.ui(.callout))
                .padding(.horizontal, 9)
                .frame(height: 26)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hair))
                .autocorrectionDisabled()
                .accessibilityLabel(field.title)
        case .toggle:
            Toggle(field.title, isOn: Binding(get: { (values[field.id] ?? field.initial) == "true" },
                                              set: { values[field.id] = $0 ? "true" : "false" }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(field.title)
        case .choice(let options):
            Picker(field.title, selection: text(field)) {
                Text("고르세요").tag("")
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(field.title)
        case .multiChoice(let options):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(options, id: \.value) { option in
                    Toggle(option.label, isOn: Binding(
                        get: { picked(field).contains(option.value) },
                        set: { on in
                            var set = picked(field).filter { $0 != option.value }
                            if on { set.append(option.value) }
                            values[field.id] = set.joined(separator: "\n")
                        }))
                        .toggleStyle(.checkbox)
                        .font(Theme.ui(.callout))
                }
            }
        }
    }

    private func picked(_ field: ElicitationForm.Field) -> [String] {
        (values[field.id] ?? field.initial).split(separator: "\n").map(String.init)
    }
}

/// 승인 카드 본문의 한 덩어리 (`ApprovalPresentation.Block`).
private struct ApprovalBlockView: View {
    let block: ApprovalPresentation.Block
    @State private var expanded = false

    private static let diffPreview = 14
    private static let contentPreview = 10

    var body: some View {
        switch block {
        case .command(let command):
            CommandBox(command: command)

        case .diff(let path, let lines):
            VStack(alignment: .leading, spacing: 0) {
                pathHeader(path, meta: diffMeta(lines))
                let shown = expanded ? lines : Array(lines.prefix(Self.diffPreview))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                        diffRow(line)
                    }
                }
                .padding(.vertical, 4)
                if lines.count > Self.diffPreview { moreButton(lines.count - Self.diffPreview) }
            }
            .boxed()

        case .content(let path, let text, let lineCount):
            VStack(alignment: .leading, spacing: 0) {
                pathHeader(path, meta: "\(lineCount)줄")
                ExpandableMono(text: text, previewLines: Self.contentPreview, color: Theme.ink2)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
            }
            .boxed()

        case .target(let target):
            // 줄 끊는 글자 · 방향 글자는 표시로 (`CommandWrap.visibleLine`) — CR 뒤나 뒤집힌 순서에 경로가 숨지 않게.
            Text(CommandWrap.visibleLine(target))
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.codeBorder))

        case .fields(let fields):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array((expanded ? fields : Array(fields.prefix(8))).enumerated()), id: \.offset) { _, field in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(CommandWrap.visibleLine(field.name))
                            .font(Theme.mono(.caption))
                            .foregroundStyle(Theme.slate)
                            .frame(minWidth: 70, alignment: .leading)
                        Text(fieldValue(field.value))
                            .font(Theme.mono(.caption))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(expanded ? nil : 3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if fields.count > 8 { moreButton(fields.count - 8, unit: "개") }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.codeBorder))

        case .text(let text):
            ExpandableMono(text: text, previewLines: 8, color: Theme.ink2)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.codeBorder))
        }
    }

    /// 값은 여러 줄일 수 있다 — LF 는 그대로 두고, 다른 줄 끊는 글자 · 숨은 글자는 표시로 (`CommandWrap.visibleLines`).
    private func fieldValue(_ value: String) -> String {
        CommandWrap.visibleLines(value).joined(separator: "\n")
    }

    /// 파일 경로 한 줄 — 줄 끊는 글자 · 방향 글자는 표시로 (`CommandWrap.visibleLine` — CR 뒤에 경로가 숨거나 순서가 뒤집히지 않게).
    private func pathHeader(_ path: String, meta: String?) -> some View {
        HStack(spacing: 8) {
            Text(CommandWrap.visibleLine(path))
                .font(Theme.mono(.caption, .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if let meta { Text(meta).font(Theme.mono(.caption)).foregroundStyle(Theme.slate) }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Theme.codeHeader)
    }

    private func diffMeta(_ lines: [ApprovalPresentation.DiffLine]) -> String? {
        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        guard added + removed > 0 else { return nil }
        return "+\(added) −\(removed)"
    }

    private func diffRow(_ line: ApprovalPresentation.DiffLine) -> some View {
        let (mark, color, background): (String, Color, Color) = {
            switch line.kind {
            case .added: return ("+", Theme.emeraldText, Theme.addBackground)
            case .removed: return ("−", Theme.danger, Theme.deleteBackground)
            case .context: return (" ", Theme.slate2, .clear)
            }
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(mark).font(Theme.mono(.caption, .semibold)).foregroundStyle(color).frame(width: 9)
            Text(line.text.isEmpty ? " " : line.text)
                .font(Theme.mono(.caption))
                .foregroundStyle(line.kind == .context ? Theme.slate : Theme.ink2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 1.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private func moreButton(_ hidden: Int, unit: String = "줄") -> some View {
        Button(expanded ? "⌃ 접기" : "⌄ \(hidden)\(unit) 더") { expanded.toggle() }
            .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.mono(.caption)))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
    }
}

private extension View {
    /// 경로 머리가 있는 상자 (편집 · 새 파일).
    func boxed() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.codeBorder))
    }
}

/// 승인 카드의 명령 상자. 빈칸에서만 줄을 꺾는다 (`CommandWrap` — 좁은 칸에서 `--filter` 가 `--` 와 `filter` 로 갈라져 다른
/// 인수처럼 읽히지 않게). 꺾인 줄은 들여 써서 원문의 줄바꿈과 가른다. 줄마다 따로 고를 수 있어 통째 복사는 단추로.
/// CR · U+2028 같은 줄 끊는 글자에서도 줄을 끊고 숨은 글자는 표시(␍ · ⟨U+202E⟩)로 보인다 (`CommandWrap.visibleLines`). 줄은 자르지
/// 않는다 — 열 수를 잘못 재도 뒤를 "…" 로 감추지 않고 다음 줄로 넘긴다. 복사는 원문 그대로.
private struct CommandBox: View {
    let command: String
    @State private var width: CGFloat = 0
    @State private var expanded = false
    @State private var copied = false

    private static let previewLines = 10
    private static let continuationIndent: CGFloat = 14
    /// SF Mono 11.5(`Theme.mono(.caption)`) 한 글자의 폭.
    private static let charWidth: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: TypeScale.caption.size, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }()

    var body: some View {
        // 꺾인 줄의 들여쓰기만큼 덜어 센다 — 줄이 칸보다 길어 글 칸이 낱말 가운데서 다시 꺾지 않게.
        let columns = width > 0 ? Int((width - Self.continuationIndent) / Self.charWidth) : 80
        let lines = CommandWrap.lines(command, columns: columns)
        let shown = expanded ? lines : Array(lines.prefix(Self.previewLines))
        let marked = CommandWrap.hasMarkers(command)
        // 손쉬운 사용도 화면과 같은 글을 읽는다 (방향 바꾸는 글자로 순서가 뒤집혀 읽히지 않게).
        let spoken = CommandWrap.visibleLines(command).joined(separator: "\n")
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("$").font(Theme.mono(.caption, .bold)).foregroundStyle(Theme.slate2)
            VStack(alignment: .leading, spacing: 3) {
                // 꺾은 줄들은 손쉬운 사용에서 명령 하나로 읽는다 (줄마다 끊어 읽지 않게).
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(Theme.mono(.caption))
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, line.continued ? Self.continuationIndent : 0)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("명령: \(spoken)")
                if marked {
                    Text(CommandWrap.markerNote)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.amberText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 화면의 줄이 둘 이상이거나 표시로 바꾼 글자가 있으면 — 줄을 골라 복사하면 원문과 다르다.
                if lines.count > 1 || marked {
                    HStack(spacing: 10) {
                        if lines.count > Self.previewLines {
                            Button(expanded ? "⌃ 접기" : "⌄ \(lines.count - Self.previewLines)줄 더") { expanded.toggle() }
                                .buttonStyle(TextButtonStyle(color: Theme.slate2, font: Theme.mono(.caption)))
                        }
                        Button(copied ? "복사함" : "명령 복사") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            copied = true
                        }
                        .buttonStyle(TextButtonStyle(color: Theme.slate2, font: Theme.mono(.caption)))
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded(.down) } action: { width = $0 }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.codeBorder))
    }
}

/// 에이전트 질문. 잉크 2px 규칙선. 항목마다 머리말 · 질문 · 답 칸 — 선택지가 있으면 고르기(미리 고르지 않는다, "직접 입력" 을
/// 허용하면 그 칸도), 없으면 글 칸, 비밀 입력이면 가린 칸. 모든 항목에 답해야 보낸다 (`QuestionAnswers` — 빈 답 · 고르지 않은
/// 선택을 보내지 않는다). 답 칸의 ↵ · 메뉴의 ⌥⌘↵ 로도 보낸다. 승인 카드와 같이 막 나타났으면 잠깐 받지 않는다.
struct PendingQuestionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let question: UserQuestion
    /// 하위 에이전트가 물었으면 그 하위의 이름.
    var agentName: String? = nil
    /// 이 카드가 놓인 대화 — 메뉴의 ⌥⌘↵ 를 받을지 가른다 (승인 카드가 없을 때만 질문이 받는다).
    var threadID: String? = nil
    /// 포커스 칸에 놓인 이 대화의 맨 앞 질문이고 떠 있는 승인 카드가 없다.
    var isFirst = true
    /// 항목 ID → 고른 선택지 (`QuestionAnswers.otherTag` 면 직접 입력).
    @State private var choices: [String: String] = [:]
    /// 항목 ID → 적은 글 (글 칸 · 직접 입력).
    @State private var texts: [String: String] = [:]
    @State private var shownAt: Date?
    @State private var armed = false
    @State private var responding = false
    @State private var appeared = false

    private var payload: [String: String]? { QuestionAnswers.payload(question, choices: choices, texts: texts) }

    var body: some View {
        let ready = payload != nil
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                BrandMark(provider: question.provider, size: 13)
                Text(question.agentID != nil && agentName != nil
                     ? "\(question.provider.displayName) 하위 에이전트 \(agentName!) 의 질문"
                     : "\(question.provider.displayName) 의 질문")
                    .font(Theme.ui(.callout, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text("답 대기").font(Theme.ui(.caption, .semibold)).foregroundStyle(Theme.amberText)
            }
            ForEach(question.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    if !item.header.isEmpty {
                        Text(item.header)
                            .font(Theme.ui(.caption, .semibold))
                            .foregroundStyle(Theme.slate)
                    }
                    Text(item.question)
                        .font(Theme.ui(.body))
                        .lineSpacing(4)
                        .foregroundStyle(Theme.ink2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    answerInput(item)
                }
            }
            HStack(spacing: 10) {
                Button("응답 보내기") { send() }
                    .buttonStyle(InkButtonStyle())
                    .disabled(!ready || !armed || responding)
                    .help(ready ? "답을 보냅니다" : "모든 질문에 답하면 보낼 수 있습니다")
                Text(sendHint(ready: ready))
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate2)
            }
        }
        .leadingRule(Theme.ink, width: 2, gap: 15)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 8)
        .onAppear {
            shownAt = Date()
            withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.22)) { appeared = true }
            AccessibilityNotification.Announcement("\(question.provider.displayName) 의 질문: \(question.promptText)").post()
        }
        .task(id: question.id) {
            try? await Task.sleep(for: .seconds(ApprovalCardGate.armDelay))
            armed = true
        }
        .onReceive(NotificationCenter.default.publisher(for: ApprovalShortcut.notification)) { note in
            guard isFirst, let threadID, ApprovalShortcut.action(note, threadID: threadID) == .allow else { return }
            send()
        }
    }

    @ViewBuilder
    private func answerInput(_ item: UserQuestion.Item) -> some View {
        if item.options.isEmpty {
            field(item, placeholder: "답")
        } else {
            Picker(item.question, selection: Binding(get: { choices[item.id] ?? "" }, set: { choices[item.id] = $0 })) {
                Text("고르세요").tag("")
                ForEach(item.options, id: \.self) { Text($0).tag($0) }
                if item.allowsOther { Text("직접 입력…").tag(QuestionAnswers.otherTag) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(item.header.isEmpty ? item.question : "\(item.header): \(item.question)")
            .disabled(responding)
            if choices[item.id] == QuestionAnswers.otherTag {
                field(item, placeholder: "직접 입력한 답")
            }
        }
    }

    /// 글 칸 — 비밀 입력이면 가린 칸. ↵ 는 다 답했으면 보낸다.
    @ViewBuilder
    private func field(_ item: UserQuestion.Item, placeholder: String) -> some View {
        let text = Binding(get: { texts[item.id] ?? "" }, set: { texts[item.id] = $0 })
        Group {
            if item.isSecret {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
                    .autocorrectionDisabled()
            }
        }
        .textFieldStyle(.plain)
        .font(Theme.ui(.callout))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hair))
        .onSubmit { send() }
        .disabled(responding)
        .accessibilityLabel(item.header.isEmpty ? item.question : "\(item.header): \(item.question)")
        .help(item.isSecret ? "가린 입력 — 대화 기록에는 답을 남기지 않습니다" : "")
    }

    /// 보내기 단추 옆의 한 줄 — 아직 답하지 않은 질문이 있으면 그 사실, 다 답했으면 (맨 앞 카드면) 단축키.
    private func sendHint(ready: Bool) -> String {
        if !ready { return "모든 질문에 답하면 보낼 수 있습니다" }
        return isFirst ? "↵ · \(MenuShortcut.approvalAllow.symbol) 로도 보냅니다" : ""
    }

    private func send() {
        guard ApprovalCardGate.accepts(shownAt: shownAt, now: Date(), responding: responding), let payload else { return }
        responding = true
        let question = question
        Task { await model.runner.respond(question: question, answers: payload) }
    }
}

// MARK: - 스레드 설정

struct ThreadSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let thread: ConversationThread

    @State private var title = ""
    @State private var goal = ""
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("대화 설정").font(Theme.ui(.body, .semibold)).foregroundStyle(Theme.ink)
            field("제목") {
                TextField("제목", text: $title).textFieldStyle(.roundedBorder)
            }
            field("현재 목표") { editor($goal, height: 60) }
            field("고정 메모 — 제약 · 변경 금지 사항") { editor($notes, height: 90) }
            Text("여기에 적은 목표와 메모는 인계 초안에 항상 포함됩니다.")
                .font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .buttonStyle(ChipButtonStyle(height: 27))
                    .keyboardShortcut(.cancelAction)
                Button("저장") {
                    var t = thread
                    t.title = title.isEmpty ? thread.title : title
                    t.goal = goal
                    t.pinnedNotes = notes
                    Task { await model.updateThread(t); dismiss() }
                }
                .buttonStyle(InkButtonStyle(height: 27))
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Theme.paper)
        .onAppear {
            title = thread.title
            goal = thread.goal
            notes = thread.pinnedNotes
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(label)
            content()
        }
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(Theme.ui(.callout))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: height)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hair))
    }
}
