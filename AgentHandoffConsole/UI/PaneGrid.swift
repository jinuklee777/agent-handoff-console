import SwiftUI

/// 가운데 칸의 대화 영역. 분할(`PaneLayout`)에 따라 한 칸 · 두 칸(좌우) · 네 칸(2 × 2)으로 나누고 칸마다 대화를 하나씩 연다.
/// 실행은 대화마다 따로 돈다. 인스펙터 · 툴바 · 메뉴는 **포커스 칸**의 대화를 따라간다 — 칸을 누르면 포커스가 옮겨 간다.
/// 칸 배치의 규칙은 `PaneArrangement` (App/WindowState.swift), 상태는 `AppModel.panes`.
struct PaneGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let arrangement = model.panes
        let columns = arrangement.layout.columns
        let rows = arrangement.layout.paneCount / columns
        let threads = arrangement.threadIDs.map { id in id.flatMap { model.paneThread($0) } }
        // 칸들의 프로젝트가 둘 이상일 때만 칸 머리에 프로젝트를 적는다.
        let showsProject = PaneHeaderDensity.showsProject(paneProjectIDs: threads.map { $0?.projectID })
        // 칸은 남는 너비를 똑같이 나눠 갖는다. 본문 칸의 최소 너비(`PanelFit`)는 그대로 둔다 — 좁은 창에서는 칸이 좁아지고
        // 입력창이 밀도 단계로 줄어든다 (창 폭 제약을 칸 수에 묶으면 macOS 26 의 제약 갱신 크래시를 다시 부른다).
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { row in
                if row > 0 { Rectangle().fill(Theme.hair).frame(height: 1) }
                HStack(spacing: 0) {
                    ForEach(0..<columns, id: \.self) { column in
                        if column > 0 { Rectangle().fill(Theme.hair).frame(width: 1) }
                        let index = row * columns + column
                        pane(index, thread: threads[index], arrangement: arrangement, showsProject: showsProject)
                    }
                }
            }
        }
        .background(Theme.paper)
    }

    @ViewBuilder
    private func pane(_ index: Int, thread: ConversationThread?, arrangement: PaneArrangement,
                      showsProject: Bool) -> some View {
        let split = arrangement.layout != .single
        let focused = index == arrangement.focused
        VStack(spacing: 0) {
            // 분할했을 때만 — 한 칸일 때는 툴바 제목 · 부제가 같은 일을 한다. 머리는 칸 비우기(×)를 빼고 스스로 포커스를 받는다.
            if split {
                PaneHeader(index: index, thread: thread, focused: focused, showsProject: showsProject)
            }
            PaneFill {
                if let thread, let state = model.threadStates[thread.id] {
                    ThreadView(thread: thread, pane: state, isFocused: focused,
                               rowPage: arrangement.layout.streamRowPage)
                        // 다른 대화로 바뀌면 스크롤 · 행 수 · 입력 상태를 새로 시작한다.
                        .id(thread.id)
                } else if arrangement.threadIDs[index] != nil {
                    // 대화 기록을 읽는 중 (칸을 막 열었다).
                    Color.clear
                } else {
                    EmptyPaneView(text: EmptyPaneText.make(split: split, focused: focused, sidebarVisible: model.sidebarVisible,
                                                           hasProjects: !model.projects.isEmpty),
                                  index: index)
                }
            }
            .contentShape(Rectangle())
            // 칸 어디를 눌러도 포커스가 온다 (안쪽 버튼 · 글 선택은 그대로 받는다). 머리의 × 에는 걸지 않는다 — 함께 불리면 비운 칸이
            // 포커스를 가져가 작업하던 대화의 포커스가 풀렸다.
            .simultaneousGesture(TapGesture().onEnded { Task { await model.focusPane(index) } })
        }
    }
}

/// 빈 칸의 안내와 단추 (`EmptyPaneText` — 사이드바가 보이는지 · 프로젝트가 있는지에 맞춘 말).
private struct EmptyPaneView: View {
    @Environment(AppModel.self) private var model
    let text: EmptyPaneText
    let index: Int

    var body: some View {
        VStack(spacing: 4) {
            QuietEmptyState(systemImage: "bubble.left.and.text.bubble.right", title: text.title, detail: text.detail)
            HStack(spacing: 8) {
                ForEach(text.actions, id: \.self) { action in
                    Button(EmptyPaneText.title(action)) { perform(action) }
                        .buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 11))
                }
            }
        }
    }

    private func perform(_ action: EmptyPaneText.Action) {
        switch action {
        case .newConversation:
            // 이 칸에 연다 — 포커스를 먼저 이 칸으로.
            Task {
                await model.focusPane(index)
                guard let projectID = model.selectedProjectID ?? model.projects.first?.id else { return }
                await model.startNewConversation(projectID: projectID)
            }
        case .showSidebar:
            Task { await model.focusPane(index) }
            model.sidebarVisible = true
        case .openFolder:
            Task { await ProjectFolderPicker.chooseAndOpen(model: model) }
        }
    }
}

/// 칸의 대화 영역: 받은 자리를 그대로 채운다 (`.frame(maxWidth: .infinity, maxHeight: .infinity)` 처럼 — 작은 안내는 가운데).
/// 다른 점은 크기를 물을 때 안쪽을 재지 않고 제안받은 크기로 답하는 것이다. 안쪽은 놓을 때(`placeSubviews`) 실제 크기로만 잰다.
///
/// 창의 최소 크기를 셀 때(`NSHostingView.minSize`) SwiftUI 는 칸 안의 대화를 최소 폭으로 **실제로 배치해** 본다 — 대화 영역은
/// 늘 남는 자리를 채우므로 그 답은 쓰이지 않는데, 메시지마다 그 폭으로 글자를 다시 배치했다
/// (2026-09-29 실측: 가장 큰 대화 넷을 네 칸에 열 때 CPU 의 11% → 2.5%).
private struct PaneFill: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                          proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// 분할했을 때 칸 위의 한 줄: 로고 · 대화 제목 · (칸들의 프로젝트가 다를 때) 프로젝트 · 같은 폴더 표시 · 상태 · 칸 비우기.
/// 포커스 칸은 위에 잉크 선, 사람의 답을 기다리는 칸(승인 · 질문 · 자동 작업)은 승인 카드와 같은 바탕.
/// 무엇을 적을지는 `PaneStatus`(상태) · `PaneHeaderDensity`(칸 너비) 가 정한다.
private struct PaneHeader: View {
    @Environment(AppModel.self) private var model
    let index: Int
    let thread: ConversationThread?
    let focused: Bool
    let showsProject: Bool
    @State private var width: Double = 600

    static let height: CGFloat = 30

    var body: some View {
        // "완료 · 3분 전" 의 시각이 흐르게 30초마다 다시 판정한다 (실행 상태는 관찰로 바로 바뀐다).
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let input = thread.map { model.paneStatusInput(for: $0) } ?? PaneStatusInput()
            let status = thread == nil ? nil : PaneStatus.make(input, now: context.date)
            row(input: input, status: status)
        }
        .frame(height: Self.height)
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { width = $0 }
    }

    private func row(input: PaneStatusInput, status: PaneStatus?) -> some View {
        let density = PaneHeaderDensity.forWidth(width)
        let highlighted = status?.needsResponse == true
        return HStack(spacing: 7) {
            // 머리를 누르면 이 칸이 포커스를 받는다 — 칸 비우기(×)는 뺀다 (함께 불리면 비운 칸이 포커스를 가져갔다).
            HStack(spacing: 7) {
                if let thread {
                    BrandMark(provider: thread.preferredProvider, size: 11, opacity: focused ? 1 : 0.7)
                    Text(thread.title)
                        .font(Theme.ui(.callout, focused ? .semibold : .medium))
                        .foregroundStyle(focused ? Theme.ink : Theme.ink2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(thread.title)
                    if density == .full, showsProject,
                       let project = model.projects.first(where: { $0.id == thread.projectID }) {
                        Text(model.projectDisplayName(project))
                            .font(Theme.ui(.caption))
                            .foregroundStyle(Theme.slate2)
                            .lineLimit(1)
                            .help(project.path)
                    }
                }
                Spacer(minLength: 6)
                if input.sharesFolder, density != .compact {
                    // 복사 기호(겹친 사각형)로 읽히지 않게 글로 적는다.
                    Text("같은 폴더")
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate2)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 5)
                        .frame(height: 17)
                        .overlay(Capsule().strokeBorder(Theme.hair))
                        .help("같은 폴더에서 다른 대화의 실행이 함께 돌고 있습니다 — 두 실행의 전후 비교는 \"겹침\"으로 남습니다")
                        .accessibilityLabel("같은 폴더에서 다른 대화도 실행 중")
                }
                if let status { statusLabel(status, density: density) }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { Task { await model.focusPane(index) } })
            if thread != nil { closeButton }
        }
        .padding(.leading, 12)
        .padding(.trailing, thread == nil ? 12 : 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(highlighted ? Theme.approvalWell : Theme.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(highlighted ? Theme.approvalBorder : Theme.hairSoft).frame(height: 1)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(focused ? Theme.ink : Color.clear).frame(height: 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText(status))
    }

    private func statusLabel(_ status: PaneStatus, density: PaneHeaderDensity) -> some View {
        HStack(spacing: 5) {
            switch status.tone {
            case .active:
                // 사이드바와 같은 모양 — 도는 링(실행 중인 제공자의 색). 점은 "답을 기다림" 에만 쓴다.
                PendingRing(color: Theme.brand(runningProvider))
            case .attention where status.needsResponse:
                Circle().fill(Theme.amber).frame(width: 6, height: 6)
            default:
                EmptyView()
            }
            Text(density == .compact ? status.shortText : status.text)
                .font(Theme.ui(.caption, status.needsResponse ? .semibold : .regular))
                .foregroundStyle(color(status.tone))
                .lineLimit(1)
        }
        .fixedSize()
        .layoutPriority(1)
        .help(status.help)
    }

    private var runningProvider: AgentProvider {
        guard let thread else { return .claude }
        return model.runner.session(threadID: thread.id)?.activeProvider ?? thread.preferredProvider
    }

    private func color(_ tone: PaneStatus.Tone) -> Color {
        switch tone {
        case .quiet: return Theme.slate2
        case .active: return Theme.slate
        case .attention: return Theme.amberText
        case .danger: return Theme.danger
        }
    }

    private var closeButton: some View {
        Button { Task { await model.closePane(index) } } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Theme.slate2)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("이 칸 비우기 (대화는 닫히지 않고 실행도 계속 돕니다)")
        .accessibilityLabel("칸 비우기")
    }

    private func accessibilityText(_ status: PaneStatus?) -> String {
        guard let thread else { return "칸 \(index + 1), 빈 칸" }
        return "칸 \(index + 1), \(thread.title)" + (status.map { ", \($0.text)" } ?? "") + (focused ? ", 포커스" : "")
    }
}

/// 툴바의 "응답 필요" — 사람의 답을 기다리는 다른 대화가 있을 때만 놓인다 (`AppModel.responseNeeded`).
/// 한 곳이면 누르면 바로 그 대화로, 여럿이면 목록 팝오버에서 고른다. 가는 길은 사이드바에서 고른 것과 같다 (`selectThread` —
/// 칸에 열려 있으면 그 칸으로 포커스, 아니면 포커스 칸에 연다).
struct ResponseNeededChip: View {
    @Environment(AppModel.self) private var model
    let items: [ResponseNeeded]
    /// 대화로 가기 전에 부르는 쪽이 할 일 (에이전트 기록 화면이면 대화 화면으로).
    var beforeGo: () -> Void = {}
    @State private var presented = false

    var body: some View {
        Button {
            if items.count == 1 { go(items[0]) } else { presented.toggle() }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(Theme.amber).frame(width: 6, height: 6)
                Text(ResponseNeeded.chipTitle(items))
                    .font(Theme.ui(.caption, .semibold))
                    .foregroundStyle(Theme.amberText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Theme.approvalWell, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.approvalBorder))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(items.count == 1 ? "\(items[0].title) — \(items[0].what) · 눌러서 이동" : "답을 기다리는 대화 \(items.count)개")
        .accessibilityLabel(ResponseNeeded.chipTitle(items))
        .popover(isPresented: $presented, arrowEdge: .bottom) { list }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionLabel("답을 기다리는 대화")
                .padding(.horizontal, 8)
                .padding(.bottom, 5)
            ForEach(items) { item in
                Button { go(item) } label: {
                    HStack(spacing: 8) {
                        BrandMark(provider: item.provider, size: 11)
                        Text(item.title)
                            .font(Theme.ui(.callout, .medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 12)
                        Text(item.what)
                            .font(Theme.ui(.caption, .semibold))
                            .foregroundStyle(Theme.amberText)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.vertical, 4)
            // 현황 — 답을 기다리는 것 · 일하는 것을 한 화면에서 (⌃⌘0).
            Button {
                presented = false
                model.requestOverview()
            } label: {
                HStack(spacing: 8) {
                    Text("현황에서 모두 보기")
                        .font(Theme.ui(.callout, .medium))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 12)
                    Text(MenuShortcut.overview.symbol)
                        .font(Theme.mono(.caption))
                        .foregroundStyle(Theme.slate2)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(width: 300)
        .background(Theme.paper)
    }

    private func go(_ item: ResponseNeeded) {
        presented = false
        beforeGo()
        Task { await model.selectThread(item.threadID) }
    }
}
