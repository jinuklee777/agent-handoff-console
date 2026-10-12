import AppKit
import SwiftUI

/// 머리줄 브랜치 ▾ 팝오버 (목업 BranchMenu · BranchSearch, 폭 332). 판정은 모두 `BranchMenu`(비 UI) 가 하고
/// 이 뷰는 그리기 · 키 입력 · 명령 호출만 한다.
///
/// - 열리면 찾기 칸에 바로 포커스. ↑↓ 강조 이동(막힌 행은 건너뜀), ↵ 강조한 행 실행, esc 닫기, 마우스를 올리면 강조.
/// - 쓰기는 `AppModel.runGit` 으로만 (전환 `git switch`, 만들기 `git switch -c`). 성공하면 닫고, 실패하면 이 창 안에
///   이유(`GitFailure` — 겹치는 파일은 그 이름)와 git 의 출력을 보인다.
/// - 에이전트 실행 중 · git 명령 실행 중 · 병합/rebase 중이면 전환 · 만들기 행을 잠그고 맨 위에 이유 한 줄. 목록은 볼 수 있다.
struct BranchMenuView: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void

    @State private var query: String
    @State private var mode: BranchMenu.Mode
    @State private var highlighted: String?
    @State private var fieldFocused = false
    @State private var focusRequest = 0
    /// 이 창을 연 시각. 이 창에서 실행한 명령의 실패만 보인다 (지난 실패를 다시 꺼내지 않는다).
    @State private var openedAt = Date()
    @State private var showingOutput = false
    @State private var visible = true
    @State private var listHeight: CGFloat = 0
    /// ↑↓ 로 강조를 옮길 때 올린다 — 목록이 그 행까지 스크롤한다 (마우스로 옮길 때는 스크롤하지 않는다).
    @State private var scrollRequest = 0

    /// 목록이 이보다 길면 목록만 스크롤한다.
    private static let maxListHeight: CGFloat = 318

    init(mode: BranchMenu.Mode, query: String = "", close: @escaping () -> Void) {
        self.close = close
        _mode = State(initialValue: mode)
        _query = State(initialValue: query)
    }

    var body: some View {
        let git = model.workspace.git ?? GitWorkspaceStatus()
        let block = currentBlock(git)
        let content = BranchMenu.content(status: git, query: query, mode: mode, block: block,
                                         backgroundTasks: backgroundTasks)
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 0) {
            topNote(block)
            searchField
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, searching || mode == .create ? 6 : 4)
            if content.awaitingName {
                awaitingNameHint(git, block: block)
            }
            if let create = content.create {
                createRow(create, git: git)
                    .padding(.horizontal, 6)
            }
            if !content.sections.isEmpty || content.remoteListUnknown {
                list(content)
            }
            if !searching && mode == .browse {
                newBranchRow(block)
            }
            footerNotes(git, block: block)
            keyHints(content)
        }
        .frame(width: 332)
        .onAppear {
            openedAt = Date()
            highlighted = BranchMenu.defaultHighlight(content)
            focusRequest += 1
        }
        .onDisappear { visible = false }
        .onChange(of: query) { _, _ in
            highlighted = BranchMenu.defaultHighlight(
                BranchMenu.content(status: model.workspace.git ?? GitWorkspaceStatus(), query: query, mode: mode,
                                   block: currentBlock(model.workspace.git ?? GitWorkspaceStatus()),
                                   backgroundTasks: backgroundTasks))
        }
        // git 상태를 다시 읽었거나 잠금이 풀리면 강조를 유지할 수 있으면 유지한다.
        .onChange(of: content.selectableIDs) { _, _ in
            highlighted = BranchMenu.reconcileHighlight(highlighted, in: content)
        }
    }

    // MARK: - 판정 입력

    private func currentBlock(_ git: GitWorkspaceStatus) -> BranchMenu.Block? {
        let conflicts = Set(git.conflicted.map(\.path)).count
        // 독립 작업 폴더의 대화는 그 대화의 브랜치에서만 일한다 — 바꾸면 합치기 칸이 바뀐 브랜치의 커밋을 보지 못한다 (chg-16).
        return BranchMenu.block(lock: model.gitWriteLock, merging: git.isMerging, rebasing: git.isRebasing,
                                conflicts: conflicts, worktreeBranch: model.selectedThread?.worktree?.branch)
    }

    /// 이 폴더의 실행이 메인 턴을 마치고 기다리는 백그라운드 작업 수 (잠금 이유에 덧붙인다 — 변경사항 탭과 같은 말).
    private var backgroundTasks: Int { model.backgroundTaskCount(inProjectPath: model.selectedProject?.path ?? "") }

    /// 이 프로젝트에서 도는 전환 · 만들기 명령.
    private var runningSwitch: GitWrite.Operation? {
        guard let operation = model.runningGitOperation,
              model.runningGitProjectPath == model.selectedProject?.path else { return nil }
        switch operation {
        case .switchBranch, .createBranch: return operation
        default: return nil
        }
    }

    /// 이 창을 연 뒤 실행한 전환 · 만들기의 실패.
    private var failure: AppModel.GitOutcomeRecord? {
        guard let record = model.lastGitOutcome, !record.outcome.succeeded,
              record.projectPath == model.selectedProject?.path, record.finishedAt >= openedAt else { return nil }
        switch record.operation {
        case .switchBranch, .createBranch: return record
        default: return nil
        }
    }

    // MARK: - 맨 위 한 줄 (진행 · 실패 · 잠금)

    @ViewBuilder
    private func topNote(_ block: BranchMenu.Block?) -> some View {
        if let running = runningSwitch {
            HStack(spacing: 7) {
                InkSpinner(color: Theme.slate)
                Text(runningText(running))
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
        } else if let failure {
            let explanation = (failure.failure ?? .unclassified(GitFailure.noOutputLine)).explanation(for: failure.operation)
            VStack(alignment: .leading, spacing: 6) {
                RuleNote(systemImage: "xmark", tint: Theme.danger, title: explanation.title,
                         detail: explanation.detail, verbatim: explanation.verbatim) {
                    Button(showingOutput ? "출력 접기" : "출력 보기") { showingOutput.toggle() }
                        .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
                        .help("git 이 쓴 출력 전체 (대화 기록에도 남아 있습니다)")
                }
                if showingOutput {
                    ScrollView {
                        Text(failure.outcome.command + "\n\n" + (failure.outcome.output.isEmpty ? "(출력 없음)" : failure.outcome.output))
                            .font(Theme.mono(.caption))
                            .foregroundStyle(Theme.slate)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 110)
                    .padding(.leading, 13)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
        } else if let block {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lock")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                Text(BranchMenu.blockText(block, backgroundTasks: backgroundTasks))
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
        }
    }

    private func runningText(_ operation: GitWrite.Operation) -> String {
        switch operation {
        case .createBranch(let name): return "새 브랜치를 만드는 중… \(name)"
        case .switchBranch(let name): return "브랜치를 전환하는 중… \(name)"
        default: return "git 명령을 실행하는 중…"
        }
    }

    // MARK: - 찾기 칸

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.slate2)
            KeyNavigableField(text: $query,
                              placeholder: mode == .create ? "새 브랜치 이름" : "브랜치 찾기 또는 새 이름",
                              isFocused: $fieldFocused, focusRequest: focusRequest,
                              onMove: move, onSubmit: submit, onCancel: close)
                .frame(height: 18)
                .accessibilityLabel(mode == .create ? "새 브랜치 이름" : "브랜치 찾기 또는 새 이름")
            if !query.isEmpty {
                Button {
                    query = ""
                    focusRequest += 1
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.control)
                }
                .buttonStyle(.plain)
                .help("찾는 글 지우기")
                .accessibilityLabel("찾는 글 지우기")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 27)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(fieldFocused ? Theme.slate2 : Theme.hair))
        .overlay {
            if fieldFocused {
                RoundedRectangle(cornerRadius: 9.5)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor).opacity(0.55), lineWidth: 3)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
        }
    }

    private func move(_ delta: Int) {
        let git = model.workspace.git ?? GitWorkspaceStatus()
        let content = BranchMenu.content(status: git, query: query, mode: mode, block: currentBlock(git),
                                         backgroundTasks: backgroundTasks)
        // 고를 행이 없으면(모두 잠김) 강조를 그대로 둔다 — 잠금이 풀리면 그 행이 다시 보인다.
        guard let next = BranchMenu.moveHighlight(highlighted, by: delta, in: content.selectableIDs) else { return }
        highlighted = next
        scrollRequest += 1
    }

    private func submit() {
        let git = model.workspace.git ?? GitWorkspaceStatus()
        let content = BranchMenu.content(status: git, query: query, mode: mode, block: currentBlock(git),
                                         backgroundTasks: backgroundTasks)
        activate(content.item(id: highlighted))
    }

    /// 행 실행. 성공하면 닫는다. 실패는 이 창 맨 위에 — 창을 이미 닫았으면 배너로 알린다 (실패가 아무 데도 안 보이지 않게).
    private func activate(_ item: BranchMenu.Item?) {
        guard let item, let operation = BranchMenu.operation(for: item), model.runningGitOperation == nil else { return }
        showingOutput = false
        Task {
            let ok = await model.runGit(operation, reportsInline: true)
            if ok {
                // 이 창이 아직 떠 있을 때만 닫는다 (esc 로 닫고 다시 연 새 창을 지난 명령이 닫지 않게).
                if visible { close() }
            } else if !visible, let record = model.lastGitOutcome, record.operation == operation {
                let explanation = (record.failure ?? .unclassified(GitFailure.noOutputLine)).explanation(for: operation)
                model.banner = AppModel.BannerMessage(text: explanation.title + " — " + explanation.detail, isError: true)
            }
        }
    }

    // MARK: - 목록

    /// 행 수는 `BranchMenu` 가 섹션마다 제한해 둔다 (`listLimit` · `matchLimit`) — 원격 브랜치가 수천 개여도 가볍게 열린다.
    private func list(_ content: BranchMenu.Content) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(content.sections, id: \.kind) { section in
                        sectionHead(section)
                        ForEach(section.items) { item in
                            row(item, searching: section.kind == .matches, multipleRemotes: content.multipleRemotes)
                                .id(item.id)
                        }
                        if let more = section.moreText {
                            Text(more)
                                .font(Theme.ui(.caption))
                                .foregroundStyle(Theme.slate2)
                                .padding(.leading, 28)
                                .padding(.vertical, 5)
                        }
                    }
                    if content.remoteListUnknown {
                        Text("원격 브랜치 목록을 읽지 못했습니다 · ··· 에서 다시 읽기")
                            .font(Theme.ui(.caption))
                            .foregroundStyle(Theme.slate2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .frame(height: min(max(listHeight, 1), Self.maxListHeight))
            // ↑↓ 로 옮긴 강조가 보이는 곳 밖이면 필요한 만큼만 스크롤한다 (anchor 없음).
            .onChange(of: scrollRequest) { _, _ in
                guard let highlighted, content.item(id: highlighted)?.kind != .create else { return }
                proxy.scrollTo(highlighted)
            }
        }
    }

    private func sectionHead(_ section: BranchMenu.Section) -> some View {
        HStack(spacing: 6) {
            SectionLabel(section.title)
            Spacer(minLength: 4)
            if let trailing = section.trailing {
                Text(trailing)
                    .font(section.kind == .matches ? Theme.mono(.caption) : Theme.ui(.caption))
                    .foregroundStyle(Theme.slate2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func row(_ item: BranchMenu.Item, searching: Bool, multipleRemotes: Bool) -> some View {
        let isHighlighted = highlighted == item.id && item.isSelectable
        let pending: Bool = {
            if case .switchBranch(let name)? = runningSwitch, name == item.name, item.kind != .current { return true }
            return false
        }()
        return Button {
            activate(item)
        } label: {
            HStack(spacing: 8) {
                Group {
                    if item.kind == .current {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.ink)
                    } else if pending {
                        InkSpinner(color: Theme.slate)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 12)
                nameText(item)
                    .font(Theme.mono(.caption, item.kind == .current ? .semibold : .regular))
                    .foregroundStyle(nameColor(item))
                    .lineLimit(1)
                    .truncationMode(truncation(item))
                    .frame(maxWidth: .infinity, alignment: .leading)
                // 앱은 브랜치별 작업 에이전트를 기록하지 않는다 — 현재 브랜치 행에만 이 대화의 에이전트.
                if item.kind == .current, let thread = model.selectedThread {
                    BrandMark(provider: thread.preferredProvider, size: 11)
                        .opacity(0.7)
                        .help("이 대화의 에이전트 (\(thread.preferredProvider.displayName)). "
                              + "앱은 브랜치마다 어느 에이전트가 작업했는지 기록하지 않습니다.")
                }
                if let label = BranchMenu.remoteLabel(item, searching: searching, multipleRemotes: multipleRemotes) {
                    if searching {
                        RemoteTag(text: label)
                    } else {
                        // 여러 원격이면 행마다 원격 이름 (한 원격이면 섹션 제목 오른쪽에 한 번).
                        Text(label)
                            .font(Theme.mono(.caption))
                            .foregroundStyle(Theme.slate2)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                if isHighlighted, let label = BranchMenu.returnLabel(item) {
                    Text("↵ \(label)")
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate)
                        .fixedSize()
                } else {
                    let meta = BranchMenu.meta(item)
                    if !meta.isEmpty {
                        Text(meta)
                            .font(Theme.mono(.caption))
                            .foregroundStyle(Theme.slate2)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.well)
                }
            }
            .contentShape(Rectangle())
            .opacity(item.disabledReason != nil ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        // 잠긴 행만 비활성으로 그린다. 현재 브랜치 행은 누를 것이 없을 뿐이라 흐리게 하지 않는다 (누르면 아무 일도 없다).
        .disabled(item.disabledReason != nil)
        .accessibilityAddTraits(item.kind == .current ? .isSelected : [])
        .onHover { inside in
            if inside, item.isSelectable { highlighted = item.id }
        }
        .help(BranchMenu.help(item))
    }

    private func nameColor(_ item: BranchMenu.Item) -> Color {
        switch item.kind {
        case .current: return Theme.ink
        case .remoteOnly: return Theme.slate
        case .detached, .local, .create: return Theme.ink2
        }
    }

    /// 긴 이름을 줄일 곳. 찾는 중이면 일치 부분이 줄임표에 가려지지 않게 — 일치가 앞쪽이면 뒤를, 뒤쪽이면 앞을 줄인다.
    private func truncation(_ item: BranchMenu.Item) -> Text.TruncationMode {
        guard let hl = item.highlight else { return .middle }
        let center = hl.before.count * 2 + hl.match.count
        return center <= item.name.count ? .tail : .head
    }

    /// 이름 (찾는 중이면 일치 부분을 굵게 · 옅은 노랑 바탕).
    private func nameText(_ item: BranchMenu.Item) -> Text {
        guard let hl = item.highlight else { return Text(item.name) }
        var match = AttributedString(hl.match)
        match[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = Theme.mono(.caption, .bold)
        match[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Theme.ink
        match[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Theme.matchHighlight
        return Text(hl.before) + Text(match) + Text(hl.after)
    }

    // MARK: - 새 브랜치

    private func createRow(_ item: BranchMenu.Item, git: GitWorkspaceStatus) -> some View {
        let isHighlighted = highlighted == item.id && item.isSelectable
        return Button {
            activate(item)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.isSelectable ? Theme.ink : Theme.slate2)
                    .frame(width: 12)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    (Text("새 브랜치 ") + Text(item.name).font(Theme.mono(.callout, .semibold)) + Text(" 만들기"))
                        .font(Theme.ui(.callout))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.disabledReason ?? BranchMenu.createDetail(from: git.headLabel, changeCount: git.changeCount))
                        .font(Theme.ui(.caption))
                        .foregroundStyle(item.disabledReason != nil ? Theme.amberText : Theme.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isHighlighted {
                    Text("↵").font(Theme.ui(.caption)).foregroundStyle(Theme.slate).padding(.top, 1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 7)
            .background {
                if isHighlighted { RoundedRectangle(cornerRadius: 6).fill(Theme.well) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isSelectable)
        .onHover { inside in
            if inside, item.isSelectable { highlighted = item.id }
        }
        .help(BranchMenu.help(item))
    }

    /// 새 이름 입력 상태에서 아직 아무것도 치지 않았을 때.
    private func awaitingNameHint(_ git: GitWorkspaceStatus, block: BranchMenu.Block?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.slate2)
                .frame(width: 12)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("만들 브랜치 이름을 입력하세요")
                    .font(Theme.ui(.callout))
                    .foregroundStyle(Theme.ink2)
                Text(BranchMenu.awaitingDetail(from: git.headLabel, changeCount: git.changeCount, block: block))
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    /// "새 브랜치 만들기… ⌘⇧N" — 누르면 찾기 칸이 새 이름 칸이 된다. 만들기가 막혀 있으면 누를 수 없다
    /// (충돌 파일만 남은 상태는 git 이 만들기를 허용하므로 누를 수 있다).
    private func newBranchRow(_ block: BranchMenu.Block?) -> some View {
        let blocked = block?.blocksCreate == true
        return VStack(spacing: 0) {
            // 팝오버 바탕(시스템 재질) 위에서는 hairSoft 가 보이지 않아 hair 로 긋는다.
            Rectangle().fill(Theme.hair).frame(height: 1)
            Button {
                mode = .create
                focusRequest += 1
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .frame(width: 12)
                    Text("새 브랜치 만들기…")
                        .font(Theme.ui(.callout))
                        .foregroundStyle(Theme.ink2)
                    Spacer(minLength: 6)
                    KeyHint("⌘⇧N")
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(blocked)
            .opacity(blocked ? 0.55 : 1)
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .help(blocked ? block.map { BranchMenu.blockText($0, backgroundTasks: backgroundTasks) } ?? ""
                  : "지금 커밋에서 새 브랜치를 만들어 전환합니다 (git switch -c)")
        }
    }

    // MARK: - 바닥

    private func footerNotes(_ git: GitWorkspaceStatus, block: BranchMenu.Block?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let carry = BranchMenu.carryNote(changeCount: git.changeCount, block: block) {
                footerLine("info.circle", carry)
            }
            footerLine("info.circle", BranchMenu.notByApp)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private func footerLine(_ systemImage: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.slate2)
                .frame(width: 11)
            Text(text)
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 하는 일이 있는 키만 적는다: ↑↓ 는 고를 행이 있을 때(모두 잠기면 없음), ↵ 는 강조한 행이 실행할 수 있을 때
    /// (새 이름을 치기 전 · 잠긴 동안에는 ↵ 가 아무 일도 하지 않는다).
    private func keyHints(_ content: BranchMenu.Content) -> some View {
        let returnLabel = BranchMenu.returnLabel(content.item(id: highlighted))
        let canMove = !content.selectableIDs.isEmpty
        return HStack(spacing: 6) {
            if canMove {
                KeyHint("↑↓")
                Text("고르기")
            }
            if let returnLabel {
                if canMove { Spacer().frame(width: 6) }
                KeyHint("↵")
                Text(returnLabel)
            }
            if canMove || returnLabel != nil { Spacer().frame(width: 6) }
            KeyHint("esc")
            Text("닫기")
            Spacer(minLength: 0)
        }
        .font(Theme.ui(.caption))
        .foregroundStyle(Theme.slate2)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 9)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
    }
}

/// "원격" 태그 (찾기 결과의 원격에만 있는 브랜치 — 여러 원격이면 "원격 · team").
private struct RemoteTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.ui(.caption))
            .foregroundStyle(Theme.slate)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hair))
            .fixedSize()
    }
}

// MARK: - 키 입력 칸

/// ↑↓ · ↵ · esc 를 목록으로 넘기는 한 줄 입력 칸 (AppKit `NSTextField`).
/// SwiftUI `TextField` 는 ↑↓ 를 칸 안의 커서 이동으로 먹어 목록 강조로 넘길 수 없어 AppKit 칸을 쓴다.
/// 한글 조합 중(marked text)에는 키를 가로채지 않는다 — ↵ 가 조합을 끝내는 입력기 동작을 그대로 둔다.
struct KeyNavigableField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Binding var isFocused: Bool
    /// 값이 바뀔 때마다 칸에 포커스를 준다 (창이 열릴 때 · "새 브랜치 만들기…" 를 눌렀을 때).
    var focusRequest: Int
    var onMove: (Int) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusReportingField()
        // 포커스는 창의 first responder 로 본다 (`controlTextDidBeginEditing` 은 첫 글자를 칠 때에야 온다).
        field.onFocusChange = { [weak coordinator = context.coordinator] focused in
            guard let coordinator, coordinator.parent.isFocused != focused else { return }
            coordinator.parent.isFocused = focused
        }
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.font = .monospacedSystemFont(ofSize: TypeScale.callout.size, weight: .regular)
        field.textColor = NSColor(Theme.ink)
        field.delegate = context.coordinator
        field.stringValue = text
        field.setAccessibilityLabel(placeholder)
        applyPlaceholder(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if !composing, field.stringValue != text { field.stringValue = text }
        if field.placeholderAttributedString?.string != placeholder { applyPlaceholder(field) }
        if context.coordinator.focusedRequest != focusRequest {
            context.coordinator.focusedRequest = focusRequest
            // 팝오버 창에 막 붙은 참이라 한 박자 뒤에 포커스한다.
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeKey()
                window.makeFirstResponder(field)
                if let editor = field.currentEditor() {
                    editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
                }
            }
        }
    }

    private func applyPlaceholder(_ field: NSTextField) {
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.font: NSFont.systemFont(ofSize: TypeScale.callout.size), .foregroundColor: NSColor(Theme.slate2)])
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeyNavigableField
        var focusedRequest = -1

        init(_ parent: KeyNavigableField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }

    /// 창의 first responder 가 이 칸(의 편집기)인지 알려 주는 칸. 포커스 테두리를 그리는 데 쓴다.
    final class FocusReportingField: NSTextField {
        var onFocusChange: ((Bool) -> Void)?
        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = window?.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
                guard let self else { return }
                let editor = self.currentEditor()
                let focused = editor != nil && window.firstResponder === editor
                DispatchQueue.main.async { self.onFocusChange?(focused) }
            }
        }
    }
}
