import AppKit
import SwiftUI

// 파일 diff 화면 (목업 Diff.dc.html · DiffWide.dc.html). 판정 · 행 만들기는 `Workspace/FileDiff.swift`(비 UI, 오프라인 검증),
// 조회는 `GitWorkspace.fileDiff` · `WorkspaceModel.loadFileDiff`. 이 파일은 그리기와 명령 호출만 한다.
//
// - 좁은 패널(`DiffPanel`): 변경사항 탭에서 파일 행을 누르면 목록 대신 diff. 통합 diff · 긴 줄 줄바꿈.
// - 크게 보기(`DiffReviewView`): 가운데 칸(`WindowPane.review`)을 diff 로. 오른쪽 인스펙터는 목록으로 남는다.
// - 성능: diff 한 줄 = 한 행(`DiffRows`, 긴 줄은 조각). 본문은 AppKit 표(`DiffTableView`)가 보이는 행만 그리고, 높이는
//   백그라운드에서 미리 잰다 (SwiftUI 지연 스택은 빠른 스크롤에서 끊겼다 — DiffTableView.swift 머리 주석의 실측).
//   파싱 · 강조 · 포함 판정도 백그라운드다.
// - 키(esc · ⌥↑ · ⌥↓ · space)는 diff 의 키 받는 뷰(`DiffKeyCatcher`)가 첫 응답자일 때만 받는다 — 텍스트 입력에 포커스가
//   있으면 키는 그쪽으로 간다. 에이전트 실행 중에도 열람은 되고 "커밋에 포함" 만 잠근다.

// MARK: - 치수

/// 좁은 패널 · 크게 보기의 글자 · 칸 크기 (목업 boards_git.py `dline` · boards_more.py `split_row`).
struct DiffMetrics: Equatable {
    /// 거터 칸 하나의 폭 (오른쪽 여백 포함).
    var gutter: CGFloat
    var gutterPadding: CGFloat
    var numberSize: CGFloat
    var codeSize: CGFloat
    /// 한 줄 높이 (줄바꿈된 줄의 줄 간격도 이것에 맞춘다).
    var lineHeight: CGFloat
    var signWidth: CGFloat

    /// 좁은 패널: 번호 · 본문 caption(11.5) · 줄 19 · 부호 14. 거터 폭은 번호 글꼴의 숫자 폭에서 잰다.
    static func narrow(maxLineNumber: Int) -> DiffMetrics {
        let number = TypeScale.caption.size
        return DiffMetrics(gutter: gutterWidth(maxLineNumber, numberSize: number, minimum: 28, padding: 6), gutterPadding: 6,
                           numberSize: number, codeSize: TypeScale.caption.size, lineHeight: 19, signWidth: 14)
    }

    /// 크게 보기: 번호 caption(11.5) · 본문 callout(12.5) · 줄 20 · 부호 16.
    static func wide(maxLineNumber: Int) -> DiffMetrics {
        let number = TypeScale.caption.size
        return DiffMetrics(gutter: gutterWidth(maxLineNumber, numberSize: number, minimum: 38, padding: 8), gutterPadding: 8,
                           numberSize: number, codeSize: TypeScale.callout.size, lineHeight: 20, signWidth: 16)
    }

    private static func gutterWidth(_ maxLine: Int, numberSize: CGFloat, minimum: CGFloat, padding: CGFloat) -> CGFloat {
        let digits = max(3, String(max(maxLine, 1)).count)
        let digit = ("0" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: numberSize, weight: .regular)]).width
        return max(minimum, (CGFloat(digits) * digit + padding + 4).rounded(.up))
    }
}

// MARK: - 파일 한 개의 맥락 (좁은 패널 · 크게 보기가 함께 쓴다)

/// diff 머리 · 파일 정보 · "커밋에 포함" 에 필요한 값. 호스트(변경사항 탭 · 크게 보기)가 목록 행과 잠금에서 만든다.
struct DiffFileContext {
    var row: ChangesState.Row
    var request: FileDiffRequest
    var position: ChangesState.DiffPosition
    var order: [String]
    /// 이 스레드에서 이 파일을 편집한 에이전트 (실행 기록에 남은 것만).
    var providers: [AgentProvider]
    var lock: ChangesState.Lock?
    /// 병합 · rebase 중 — 이미 포함된 파일을 커밋에서 빼지 않는다 (`ChangesState.toggleOperation(for:merging:)`).
    var integrating: Bool
    /// 다른 git 명령 실행 중 (잠깐 — 누를 수 없게만 한다).
    var busy: Bool
    /// 이 폴더의 실행이 메인 턴을 마치고 기다리는 백그라운드 작업 수 (잠금 이유에 덧붙인다 — 변경사항 탭과 같은 말).
    var backgroundTasks = 0

    var toggleOperation: GitWrite.Operation? { ChangesState.toggleOperation(for: row, merging: integrating) }
    var holdsIncluded: Bool { toggleOperation == nil && row.isCheckable }
    var locked: Bool { ChangesState.blocksCheckbox(lock) }
    var toggleDisabled: Bool { toggleUnavailable || busy }
    /// 잠깐이 아닌 이유로 누를 수 없다 (에이전트 잠금 · 충돌 · 병합 중 포함 유지) — 칩 글자를 흐리게.
    var toggleUnavailable: Bool { locked || !row.isCheckable || holdsIncluded }

    /// "커밋에 포함" 도움말 (목록 체크박스와 같은 말).
    var toggleHelp: String {
        if !row.isCheckable { return "충돌을 해결해야 선택할 수 있습니다" }
        if locked, let lock { return ChangesState.lockText(lock, action: "선택할", backgroundTasks: backgroundTasks) }
        if holdsIncluded { return "병합 · rebase 중에는 커밋에서 뺄 수 없습니다 — 빼면 합쳐진 변경이 기록에서 빠집니다." }
        switch row.inclusion {
        case .on: return "커밋에서 빼기 (git restore --staged) · space"
        case .mixed: return "일부만 포함됨 — 체크하면 파일 전체를 포함합니다 (git add) · space"
        case .off, .conflict: return "커밋에 포함 (git add) · space"
        }
    }

    var statusName: String {
        if row.isUntracked { return "새 파일" }
        return GitCode.name(row.code)
    }
}

// MARK: - 좁은 패널

/// 변경사항 탭 안의 파일 diff (목업 Diff): 머리줄 ‹ 변경사항 · 이전/다음 · 크게 보기 / 파일 정보 + 커밋에 포함 / 통합 diff / 키 안내.
struct DiffPanel: View {
    @Environment(AppModel.self) private var model
    let context: DiffFileContext
    let onToggle: () -> Void
    let onBack: () -> Void

    @State private var keyToken = 0
    @State private var keysActive = false

    var body: some View {
        VStack(spacing: 0) {
            header
            fileInfo
            DiffNotices(context: context, wide: false)
            DiffDocumentView(request: context.request, row: context.row, mode: .unified, wide: false,
                             onInteract: focusKeys)
            DiffKeyHints(active: keysActive)
        }
        .background {
            DiffKeyCatcher(token: keyToken, onCommand: handle) { active in
                if keysActive != active { keysActive = active }
            }
        }
        .onAppear { if model.takeDiffKeyFocus() { keyToken += 1 } }
        .onChange(of: model.diffKeyFocusRequest) { _, _ in if model.takeDiffKeyFocus() { keyToken += 1 } }
    }

    private func focusKeys() { keyToken += 1 }

    private func handle(_ command: DiffKeyCommand) {
        switch command {
        case .back: onBack()
        case .previousFile: model.stepDiff(-1, order: context.order)
        case .nextFile: model.stepDiff(1, order: context.order)
        case .toggleInclusion: if !context.toggleDisabled { onToggle() }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            DiffBackChip(label: "변경사항", help: "목록으로 (esc)", action: onBack)
            Spacer(minLength: 6)
            DiffStepper(position: context.position, compact: true) { delta in
                model.stepDiff(delta, order: context.order)
            }
            VRule(height: 14)
            Button {
                model.setDiffWide(true)
            } label: {
                HStack(spacing: 5) {
                    // 목업 `expand` 아이콘과 같은 방향 (↙↗).
                    Image(systemName: "arrow.down.left.and.arrow.up.right").font(.system(size: 9.5, weight: .semibold))
                    Text("크게 보기")
                }
            }
            .buttonStyle(ChipButtonStyle(height: 24, horizontalPadding: 8))
            .help("가운데 칸에서 크게 봅니다 · 나란히 비교할 수 있습니다")
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 38)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
    }

    private var fileInfo: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    DiffCodeLetter(row: context.row)
                    Text(context.row.fileName)
                        .font(Theme.paneHeader)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(context.row.originalPath.map { "\($0) → \(context.row.path)" } ?? context.row.path)
                }
                DiffFileMetaLine(context: context)
                    .padding(.leading, 19)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            DiffIncludeChip(context: context, onToggle: onToggle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
    }
}

// MARK: - 크게 보기

/// 가운데 칸의 diff (목업 DiffWide): 머리줄 48pt · 일부 포함 안내 · 나란히 열 머리 · 본문. 오른쪽 인스펙터는 목록으로 남고,
/// 목록에서 다른 파일을 누르면 이 파일이 바뀐다. "‹ 대화로 돌아가기" · esc 로 대화로, "패널로 줄이기" 로 좁은 패널로.
struct DiffReviewView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(WindowStateKey.diffWideMode) private var mode: DiffRows.Mode = .split
    @AppStorage(WindowStateKey.inspectorTab) private var inspectorTab: InspectorTab = .files
    @AppStorage(WindowStateKey.inspectorVisible) private var showInspector = WindowStateKey.inspectorVisibleByDefault
    @State private var keyToken = 0
    /// 이 스레드에서 이 파일을 편집한 에이전트 (`DiffProvidersTracker` 가 채운다 — 이 화면은 이벤트를 읽지 않는다).
    @State private var providers: [AgentProvider] = []
    /// diff 표의 세로 스크롤 막대가 차지하는 폭 (막대가 늘 보이는 설정). 나란히 열 머리의 가운데 선을 본문 선과 맞춘다.
    @State private var scrollerInset: CGFloat = 0

    var body: some View {
        Group {
            if let context {
                content(context)
            } else {
                emptyState
            }
        }
        .background(Theme.paper)
        .background {
            DiffKeyCatcher(token: keyToken, onCommand: handle) { _ in }
        }
        .background {
            DiffProvidersTracker(path: model.activeDiffPath,
                                 root: model.workspace.git?.rootPath ?? model.workspace.projectPath,
                                 providers: $providers)
        }
        .onAppear {
            if model.takeDiffKeyFocus() { keyToken += 1 }
            reconcile()
        }
        .onChange(of: model.diffKeyFocusRequest) { _, _ in if model.takeDiffKeyFocus() { keyToken += 1 } }
        // 인스펙터가 다른 탭이어도 git 상태를 다시 읽으면 보던 파일이 남았는지 본다 (변경사항 탭과 같은 판단).
        .onChange(of: model.workspace.git?.fetchedAt) { _, _ in reconcile() }
    }

    private func reconcile() {
        guard let git = model.workspace.git else { return }
        model.reconcileDiffFocus(rows: model.workspace.changeRows(),
                                 statusReadable: git.isRepository && git.error == nil)
    }

    /// 보여줄 파일이 없을 때 (상태를 못 읽음 · 목록에서 사라짐). 돌아가는 칩과 esc 는 그대로 둔다.
    private var emptyState: some View {
        VStack(spacing: 0) {
            HStack {
                DiffBackChip(label: "대화로 돌아가기", help: "크게 보기를 닫고 대화로 (esc)") { model.closeDiff() }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
            if let error = model.workspace.git?.error {
                // 변경사항 탭과 같은 사실 — 파일은 골랐지만 git 상태를 읽지 못해 목록 행을 모른다.
                QuietEmptyState(systemImage: "exclamationmark.triangle", title: "Git 상태를 읽지 못했습니다", detail: error)
                    .frame(maxHeight: .infinity)
            } else if model.workspace.git == nil {
                QuietEmptyState(systemImage: "hourglass", title: "Git 상태를 읽는 중…")
                    .frame(maxHeight: .infinity)
            } else {
                QuietEmptyState(systemImage: "doc.text.magnifyingglass", title: "보여줄 파일이 없습니다",
                                detail: "변경사항 탭 목록에서 파일을 고르세요.")
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private var context: DiffFileContext? {
        guard let path = model.activeDiffPath, let git = model.workspace.git, git.isRepository, git.error == nil else {
            return nil
        }
        let rows = model.workspace.changeRows()
        guard let row = rows.first(where: { $0.path == path }) else { return nil }
        let order = ChangesState.diffOrder(listOrder: model.changesListOrder, rows: rows,
                                           listIsCurrent: listVisible && model.changesListOrderIsCurrent(statusReadAt: git.fetchedAt))
        return DiffFileContext(row: row, request: FileDiffRequest.make(for: row, status: git),
                               position: ChangesState.diffPosition(of: path, in: order), order: order,
                               providers: providers, lock: model.gitWriteLock,
                               integrating: git.isMerging || git.isRebasing,
                               busy: model.runningGitOperation != nil,
                               backgroundTasks: model.backgroundTaskCount(inProjectPath: model.selectedProject?.path ?? ""))
    }

    /// 오른쪽 인스펙터에 변경사항 탭 목록이 보인다 (그 목록의 체크박스가 이 파일의 포함 상태를 보인다).
    private var listVisible: Bool { showInspector && inspectorTab == .changes }

    /// space(포함 전환)를 받을지. 이 화면에 포함 상태가 보일 때만 — 일부 포함 파일은 안내 줄의 토글, 그 밖은 오른쪽 목록의 체크박스.
    /// 둘 다 없으면(인스펙터를 숨겼거나 다른 탭) 큰 diff 를 읽다 누른 space 가 보이지 않는 곳에서 stage 를 바꾸지 않게 받지 않는다.
    private func inclusionVisible(_ context: DiffFileContext) -> Bool {
        context.row.inclusion == .mixed || listVisible
    }

    private func handle(_ command: DiffKeyCommand) {
        // esc 는 보여줄 파일이 없어도 (상태를 못 읽었어도) 대화로 돌아간다.
        if command == .back {
            model.closeDiff()
            return
        }
        guard let context else { return }
        switch command {
        case .back: break
        case .previousFile: model.stepDiff(-1, order: context.order)
        case .nextFile: model.stepDiff(1, order: context.order)
        case .toggleInclusion:
            if !context.toggleDisabled, inclusionVisible(context) { toggle(context) }
        }
    }

    private func toggle(_ context: DiffFileContext) {
        guard let operation = context.toggleOperation else { return }
        Task { await model.runGit(operation) }
    }

    @ViewBuilder
    private func content(_ context: DiffFileContext) -> some View {
        VStack(spacing: 0) {
            head(context)
            if context.row.inclusion == .mixed {
                partialBar(context)
            }
            DiffNotices(context: context, wide: true)
            if mode == .split {
                columnHead
            }
            DiffDocumentView(request: context.request, row: context.row, mode: mode, wide: true,
                             onInteract: { keyToken += 1 },
                             onScrollerInset: { inset in if abs(inset - scrollerInset) > 0.5 { scrollerInset = inset } })
        }
    }

    private func head(_ context: DiffFileContext) -> some View {
        HStack(spacing: 12) {
            DiffBackChip(label: "대화로 돌아가기", help: "크게 보기를 닫고 대화로 (esc)") { model.closeDiff() }
            VRule(height: 18)
            // 머리줄에는 포함 토글을 두지 않는다 (목업 · 일부 포함이면 아래 안내 줄에). 포함은 목록 체크박스 · space 로.
            // 좁으면 파일 정보가 먼저 줄고(폴더 → 에이전트 → 상태) 이름은 남는다.
            HStack(spacing: 7) {
                DiffCodeLetter(row: context.row)
                Text(context.row.fileName)
                    .font(Theme.ui(.body, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                    .help(context.row.originalPath.map { "\($0) → \(context.row.path)" } ?? context.row.path)
                DiffFileMetaLine(context: context)
            }
            .layoutPriority(1)   // 남는 폭은 빈칸보다 파일 정보가 먼저 쓴다.
            Spacer(minLength: 8)
            PillSegmented(options: [DiffRows.Mode.unified, .split], selection: $mode) { value, selected in
                PillText(text: value == .unified ? "통합" : "나란히", selected: selected)
            }
            .fixedSize()
            .help("통합 · 나란히 (마지막 커밋 | 지금 파일)")
            VRule(height: 18)
            DiffStepper(position: context.position, compact: false) { delta in
                model.stepDiff(delta, order: context.order)
            }
            VRule(height: 18)
            Button {
                // 좁은 패널은 오른쪽 변경사항 탭 안에 있다 — 인스펙터를 그 탭으로 연 뒤 줄인다 (diff 가 화면에서 사라지지 않게).
                inspectorTab = .changes
                showInspector = true
                model.setDiffWide(false)
            } label: {
                HStack(spacing: 5) {
                    // 목업 `collapse` 아이콘과 같은 방향 (↗↙ 안쪽).
                    Image(systemName: "arrow.up.right.and.arrow.down.left").font(.system(size: 9.5, weight: .semibold))
                    Text("패널로 줄이기")
                }
            }
            .buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 9))
            .fixedSize()
            .help("오른쪽 변경사항 탭 안에서 봅니다")
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Theme.paper)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
    }

    /// 일부 포함 파일 안내 (목업 `partial`): 포함 토글 · "변경 n곳 중 m곳만 이번 커밋에 들어갑니다" · 부분 선택은 다른 도구에서.
    /// 안내 문장이 먼저 폭을 갖고(한 줄), 오른쪽 말은 남는 폭에 맞춰 짧아지거나 빠진다.
    private func partialBar(_ context: DiffFileContext) -> some View {
        let document = model.workspace.fileDiffDocument
        let result = document?.request.path == context.row.path ? document?.inclusion : nil
        let summary: String = {
            guard let result else { return "커밋에 포함한 부분과 포함하지 않은 부분이 섞여 있습니다." }
            return DiffInclusion.summary(result)
        }()
        let fileChanges = document?.request.path == context.row.path ? document?.stagedFileChanges ?? [] : []
        return HStack(spacing: 12) {
            DiffIncludeChip(context: context) { toggle(context) }
            Text(summary + (fileChanges.isEmpty ? "" : " 커밋에 이미 포함됨: \(fileChanges.joined(separator: " · ")).")
                 + " 체크하면 파일 전체가 포함됩니다.")
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate)
                .lineLimit(2)
                .layoutPriority(1)
                .help(DiffInclusion.approximationHelp)
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                Text("부분 선택은 터미널이나 다른 Git 도구에서 할 수 있습니다")
                Text("부분 선택은 다른 도구에서")
                EmptyView()
            }
            .font(Theme.ui(.caption))
            .foregroundStyle(Theme.slate2)
            .lineLimit(1)
            .help("앱은 줄 단위로 나눠 커밋에 넣지 않습니다 — 터미널의 git add -p 같은 도구로 합니다")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 40)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
    }

    /// 나란히 보기의 열 머리. 본문과 같은 폭으로 반을 나눈다 — 세로 스크롤 막대가 폭을 차지하면 그만큼 오른쪽을 비운다.
    private var columnHead: some View {
        let gutter = DiffMetrics.wide(maxLineNumber: 0).gutter
        return HStack(spacing: 0) {
            SectionLabel("마지막 커밋").padding(.leading, gutter + 16).frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Theme.codeBorder).frame(width: 1)
            SectionLabel("지금 파일").padding(.leading, gutter + 16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, scrollerInset)
        .frame(height: 26)
        .background(Theme.codeHeader)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.codeBorder).frame(height: 1) }
    }
}

/// 크게 보기가 이 스레드의 이벤트를 읽는 작은 뷰 (`ChangesPane` 의 `TouchedTracker` 와 같은 까닭 — 스트리밍 델타마다
/// 크게 보기 전체를 다시 계산하지 않게). 이벤트 수 · 파일 · 스레드가 바뀔 때만 다시 센다.
private struct DiffProvidersTracker: View {
    @Environment(AppModel.self) private var model
    let path: String?
    let root: String?
    @Binding var providers: [AgentProvider]

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: key) { recompute() }
    }

    private var key: String {
        "\(model.selectedThreadID ?? "")|\(model.events.count)|\(path ?? "")|\(root ?? "")"
    }

    private func recompute() {
        guard let path else {
            if !providers.isEmpty { providers = [] }
            return
        }
        let touched = ExecutionParser.touchedFiles(in: model.events, projectPath: root)[path] ?? []
        let now = AgentProvider.allCases.filter { touched.contains($0) }
        if now != providers { providers = now }
    }
}

// MARK: - 본문 (조회 · 상태 · 행)

/// 파일 diff 본문. 요청이 바뀌면 (파일 · git 상태) 백그라운드에서 다시 읽고, 같은 파일이면 새 결과가 올 때까지 앞 결과를 보인다.
struct DiffDocumentView: View {
    @Environment(AppModel.self) private var model
    let request: FileDiffRequest
    let row: ChangesState.Row
    let mode: DiffRows.Mode
    let wide: Bool
    /// diff 를 누르면 키 받는 뷰를 첫 응답자로.
    let onInteract: () -> Void
    /// 표의 세로 스크롤 막대 폭이 바뀔 때 (크게 보기의 나란히 열 머리를 본문과 맞춘다).
    var onScrollerInset: (CGFloat) -> Void = { _ in }

    /// 펼친 구간 (파일 · 옛 줄 시작 · 줄 수). git 상태를 다시 읽어도 같은 구간이면 펼친 채로 둔다.
    @State private var expanded: [String: Set<DiffGapKey>] = [:]
    /// 표에 올릴 행. 문서 · 펼친 구간 · 보기 방식이 바뀌면 백그라운드에서 다시 만든다 (수천 행을 메인에서 만들지 않게).
    @State private var box: DiffRowsBox?

    var body: some View {
        let document = model.workspace.fileDiffDocument
        let loading = model.workspace.fileDiffLoading
        Group {
            if let document, document.request.path == request.path {
                content(document)
                    .overlay(alignment: .topTrailing) {
                        if loading?.path == request.path { refreshingBadge }
                    }
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("diff 를 읽는 중…").font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.codeBackground)
        .task(id: request) { await model.workspace.loadFileDiff(request) }
    }

    private var refreshingBadge: some View {
        HStack(spacing: 5) {
            InkSpinner(color: Theme.slate)
            Text("다시 읽는 중").font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hair))
        .padding(8)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func content(_ document: FileDiffDocument) -> some View {
        switch document.body {
        case .diff:
            let key = DiffRowsBox.Key(document: document.id, expanded: expanded[request.path] ?? [], mode: mode)
            Group {
                // 같은 파일이면 새 행이 올 때까지 앞 행을 그대로 보인다 (펼치기 · git 상태를 다시 읽음 — 깜빡이지 않게).
                if let box, box.path == request.path, box.mode == mode {
                    let metrics = wide ? DiffMetrics.wide(maxLineNumber: box.maxLineNumber)
                                       : DiffMetrics.narrow(maxLineNumber: box.maxLineNumber)
                    // 파일이 바뀌면 표를 새로 만든다 (맨 위부터). 같은 파일을 다시 읽으면 스크롤 자리를 그대로 둔다.
                    // 펼치기는 표가 지금 그리고 있는 행의 구간으로 (다시 읽는 중 새 문서의 구간 번호와 섞이지 않게).
                    DiffTableView(box: box, metrics: metrics, split: mode == .split, onExpand: { gap in
                        expanded[request.path, default: []].insert(DiffGapKey(gap))
                    }, onInteract: onInteract, onScrollerInset: onScrollerInset)
                    .id(request.path)
                } else {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: key) {
                guard box?.key != key else { return }
                let conflicted = request.conflicted
                let built = await Task.detached(priority: .userInitiated) {
                    DiffRowsBox.make(document: document, key: key, conflicted: conflicted)
                }.value
                guard !Task.isCancelled else { return }
                box = built
                #if DEBUG
                DiffScrollProbe.shared.mark("rowsBuilt", detail: "\(built.rows.count)행")
                #endif
            }
        case .binary:
            notice(systemImage: "doc.zipper", title: "이진 파일이라 내용 비교를 보여줄 수 없습니다",
                   detail: row.code == "D" ? "지운 이진 파일입니다." : nil, command: document.command)
        case .noLines(let text):
            notice(systemImage: "equal", title: text, detail: row.codeNote, command: document.command)
        case .skipped(let text):
            notice(systemImage: "doc.text", title: text, detail: nil, command: document.command)
        case .failed(let text):
            VStack(spacing: 8) {
                notice(systemImage: "exclamationmark.triangle", title: "diff 를 읽지 못했습니다", detail: text,
                       command: document.command)
                Button("다시 읽기") { Task { await model.workspace.loadFileDiff(request, force: true) } }
                    .buttonStyle(ChipButtonStyle(height: 26))
            }
        }
    }

    private func notice(systemImage: String, title: String, detail: String?, command: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Theme.slate3)
            Text(title)
                .font(Theme.ui(.callout, .semibold))
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .help(command)
    }
}

/// 펼친 구간을 git 상태를 다시 읽은 뒤에도 알아보는 열쇠 (구간 번호는 hunk 가 바뀌면 달라진다).
struct DiffGapKey: Hashable, Sendable {
    var oldStart: Int
    var count: Int?

    init(_ gap: DiffGap) {
        oldStart = gap.oldStart
        count = gap.count
    }
}

/// 만든 행 (참조로 넘겨 비교를 싸게 — 같은 상자면 표를 다시 재지 않는다). 백그라운드에서 만든다.
final class DiffRowsBox: @unchecked Sendable {
    /// 문서 · 펼친 구간 · 보기 방식 — 같으면 다시 만들지 않는다.
    struct Key: Hashable, Sendable {
        var document: UUID
        var expanded: Set<DiffGapKey>
        var mode: DiffRows.Mode
    }

    let key: Key
    let path: String
    let rows: [DiffRow]
    /// 이 행을 만든 문서의 구간 (`DiffRow.Content.fold` 의 번호가 가리키는 것).
    let gaps: [DiffGap]
    let maxLineNumber: Int
    var mode: DiffRows.Mode { key.mode }

    init(key: Key, path: String, rows: [DiffRow], gaps: [DiffGap], maxLineNumber: Int) {
        self.key = key
        self.path = path
        self.rows = rows
        self.gaps = gaps
        self.maxLineNumber = maxLineNumber
    }

    static func make(document: FileDiffDocument, key: Key, conflicted: Bool) -> DiffRowsBox {
        guard let file = document.file else {
            return DiffRowsBox(key: key, path: document.request.path, rows: [], gaps: [], maxLineNumber: 0)
        }
        let expandedIndexes = Set(document.gaps.indices.filter { key.expanded.contains(DiffGapKey(document.gaps[$0])) })
        let input = DiffRows.Input(file: file, gaps: document.gaps, expanded: expandedIndexes,
                                   oldLines: document.oldLines, inclusion: document.inclusion?.states,
                                   showInclusion: document.showsHunkInclusion, conflicted: conflicted,
                                   truncated: document.truncated, totalLines: document.totalLines,
                                   shownLines: document.shownLines)
        let maxLine = max(file.maxLineNumber, (document.oldLines?.count ?? 0) + file.addedCount)
        return DiffRowsBox(key: key, path: document.request.path, rows: DiffRows.build(input, mode: key.mode),
                           gaps: document.gaps, maxLineNumber: maxLine)
    }
}

// MARK: - 머리 · 정보 부품

/// ‹ 칩 (목업 `back_chip`).
struct DiffBackChip: View {
    let label: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 9.5, weight: .semibold))
                Text(label)
            }
            .padding(.trailing, 2)
        }
        .buttonStyle(ChipButtonStyle(height: 24, horizontalPadding: 8))
        .fixedSize()
        .help(help)
    }
}

/// ‹ 2 / 4 › (⌥↑ ⌥↓). 지금 파일이 목록 순서에 없으면 "– / n".
struct DiffStepper: View {
    let position: ChangesState.DiffPosition
    let compact: Bool
    let step: (Int) -> Void

    /// 아이콘과 "2 / 4" 사이 (목업: 좁은 패널 머리줄 gap 6 · 크게 보기 머리줄 gap 12).
    var body: some View {
        HStack(spacing: compact ? 6 : 12) {
            icon("chevron.left", help: "이전 파일 (⌥↑)", enabled: position.previous != nil) { step(-1) }
            Text(verbatim: "\(position.index.map { String($0 + 1) } ?? "–") / \(position.count)")
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.slate)
                .fixedSize()
                .help(position.index == nil ? "이 파일은 지금 목록(찾기 결과)에 없습니다" : "목록에 보이는 순서")
            icon("chevron.right", help: "다음 파일 (⌥↓)", enabled: position.next != nil) { step(1) }
        }
    }

    private func icon(_ name: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.slate)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 상태 한 글자 (목업 `code`).
struct DiffCodeLetter: View {
    let row: ChangesState.Row

    var body: some View {
        Text(row.code)
            .font(Theme.mono(.caption, .bold))
            .foregroundStyle(GitCode.color(row.code))
            .frame(width: 12, alignment: .leading)
            .help(row.codeNote ?? GitCode.name(row.code))
    }
}

/// 폴더 · 상태 · +a −r · 에이전트 편집 (있을 때만). 줄 수를 모르면 "—".
struct DiffFileMetaLine: View {
    let context: DiffFileContext

    /// 폭이 모자라면 폴더 → 에이전트 편집 → 상태 순으로 뺀다 (줄 수는 끝까지 남긴다). 전체 경로는 이름의 도움말에.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(directory: true, agents: true, status: true)
            line(directory: false, agents: true, status: true)
            line(directory: false, agents: false, status: true)
            line(directory: false, agents: false, status: false)
        }
    }

    private func line(directory: Bool, agents: Bool, status: Bool) -> some View {
        HStack(spacing: 5) {
            if directory, !context.row.directory.isEmpty {
                Text(context.row.directory)
                    .font(Theme.mono(.caption))
                    .foregroundStyle(Theme.slate2)
                    .lineLimit(1)
                MetaDot()
            }
            if status {
                Text(context.statusName)
                if let original = context.row.originalPath {
                    Text("← \((original as NSString).lastPathComponent)")
                        .font(Theme.mono(.caption))
                        .lineLimit(1)
                        .help("\(original) 에서 이름이 바뀌었습니다")
                }
                MetaDot()
            }
            counts
            if agents, !context.providers.isEmpty {
                MetaDot()
                ForEach(context.providers) { provider in
                    BrandMark(provider: provider, size: 11)
                }
                Text(context.providers.map(\.displayName).joined(separator: " · ") + " 편집")
                    .lineLimit(1)
                    .help("이 대화의 실행 기록에서 이 파일을 편집했습니다")
            }
        }
        .font(Theme.ui(.caption))
        .foregroundStyle(Theme.slate)
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder
    private var counts: some View {
        let row = context.row
        if row.added == nil && row.removed == nil {
            Text("—").font(Theme.mono(.caption)).foregroundStyle(Theme.slate2)
                .help("줄 수를 알 수 없음 (이진 파일 · 첫 커밋 전 · 큰 새 파일 등)")
        } else if (row.added ?? 0) == 0 && (row.removed ?? 0) == 0 {
            Text("±0").font(Theme.mono(.caption)).foregroundStyle(Theme.slate2)
                .help("줄 변화 없음")
        } else {
            // 목록 행과 같이 0 인 쪽은 쓰지 않는다.
            HStack(spacing: 4) {
                if let added = row.added, added > 0 { Text("+\(added)").foregroundStyle(Theme.emeraldText) }
                if let removed = row.removed, removed > 0 { Text("−\(removed)").foregroundStyle(Theme.danger) }
            }
            .font(Theme.mono(.caption))
            .fixedSize()
            .help("마지막 커밋 대비 파일 전체의 줄 수")
        }
    }
}

/// "커밋에 포함" 토글 (목업 `include_toggle`, 26pt 칩 안의 3상태 체크박스). 목록 체크박스와 같은 stage / unstage.
struct DiffIncludeChip: View {
    let context: DiffFileContext
    let onToggle: () -> Void

    var body: some View {
        let state = context.row.inclusion
        Button(action: onToggle) {
            HStack(spacing: 7) {
                IncludeCheckbox(state: state, dimmed: context.toggleDisabled)
                Text(state == .mixed ? "커밋에 포함 · 일부" : "커밋에 포함")
                    .opacity(context.toggleUnavailable ? 0.55 : 1)
                if context.locked {
                    Image(systemName: "lock").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.amber)
                }
            }
        }
        .buttonStyle(IncludeChipStyle())
        .disabled(context.toggleDisabled)
        .fixedSize()
        .help(context.toggleHelp + (state == .mixed ? "\n" + DiffInclusion.approximationHelp : ""))
        .accessibilityLabel("\(context.row.fileName) 커밋에 포함")
        .accessibilityValue(state.spokenValue)
    }

    /// 칩 모양은 그대로 두고 눌림만 보인다. 누를 수 없으면(잠금 · 충돌 · 병합 중 포함 유지) 글자를 흐리게 한다 — git 명령이
    /// 잠깐 도는 동안은 흐리게 하지 않는다 (목록 체크박스와 같은 기준).
    private struct IncludeChipStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(configuration.isPressed ? Theme.well : Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hair))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
    }
}

/// diff 위의 한 줄 안내: 보던 파일이 빠져 옮김 · 잠금 이유 · 첫 커밋 전 등 조회 사실 · 포함 상태를 못 읽음.
struct DiffNotices: View {
    @Environment(AppModel.self) private var model
    let context: DiffFileContext
    let wide: Bool

    var body: some View {
        let document = model.workspace.fileDiffDocument
        let notes = document?.request.path == context.row.path
            ? (document?.notes ?? []) + (document?.inclusionNote.map { [$0] } ?? []) : []
        let lockReason: String? = context.locked
            ? context.lock.map { ChangesState.lockText($0, action: "커밋에 포함을 바꿀", backgroundTasks: context.backgroundTasks) }
            : nil
        let conflicted = context.row.inclusion == .conflict
        // 충돌 표시가 남았다고는 읽은 diff 에 그 줄이 있을 때만 말한다 (표시를 지우고 저장해도 git add 전까지는 충돌 파일이다).
        let markers = document?.request.path == context.row.path ? document?.conflictMarkerLines ?? 0 : 0
        if model.diffNotice != nil || lockReason != nil || !notes.isEmpty || conflicted {
            VStack(alignment: .leading, spacing: 4) {
                if let notice = model.diffNotice {
                    ReasonLine(systemImage: "arrow.turn.down.right", text: notice)
                }
                if conflicted {
                    // 목록의 충돌 행과 같은 말 — 파일을 저장한 것만으로는 git 이 해결됐다고 보지 않는다.
                    ReasonLine(systemImage: "exclamationmark.triangle", iconColor: Theme.amber,
                               text: (markers > 0
                                      ? "git 이 아직 충돌로 보는 파일이고, diff 에 충돌 표시(<<<<<<< ======= >>>>>>>) 줄이 "
                                          + "\(markers)개 보입니다. "
                                      : "git 이 아직 충돌로 보는 파일입니다. ")
                                   + "정리하고 저장한 뒤 터미널에서 git add 로 해결됨을 표시해야 커밋에 포함할 수 있습니다.")
                }
                if let lockReason {
                    ReasonLine(systemImage: "lock", iconColor: Theme.amber,
                               text: "diff 는 지금 볼 수 있습니다. " + lockReason)
                }
                ForEach(notes, id: \.self) { note in
                    ReasonLine(systemImage: "info.circle", text: note)
                }
            }
            .padding(.horizontal, wide ? 16 : 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairSoft).frame(height: 1) }
        }
    }
}

/// 좁은 패널 바닥 키 안내 (목업: esc 목록으로 · ⌥↑⌥↓ 이전·다음 파일 · space 포함 전환). 키는 diff 가 키를 받을 때만 동작한다 —
/// 입력창 등 다른 곳에 포커스가 있으면 그 사실을 또렷이 적는다. 안내 묶음은 줄이지 않고(`fixedSize`) 폭이 모자라면 덧붙인 문구부터
/// 짧게 → 안내 대신 한 줄 문구로 바꾼다 (인스펙터 최소 400pt 에서도 키 이름이 잘리지 않게).
struct DiffKeyHints: View {
    let active: Bool

    private static let focusHelp = "입력창 · 커밋 메시지 등 다른 곳에 포커스가 있으면 키는 그쪽으로 갑니다"

    var body: some View {
        Group {
            if active {
                HStack(spacing: 6) {
                    hints
                    Spacer(minLength: 0)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    inactive("diff 를 누르면 키가 동작합니다")
                    inactive("diff 를 눌러 키 켜기")
                    inactiveLine
                }
                .help(Self.focusHelp)
            }
        }
        .font(Theme.ui(.caption))
        .foregroundStyle(Theme.slate2)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 30)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
    }

    /// 목업 그대로의 안내 묶음. 폭이 모자라도 글자를 줄이지 않는다.
    private var hints: some View {
        HStack(spacing: 6) {
            KeyHint("esc")
            Text("목록으로")
            Spacer().frame(width: 6)
            KeyHint("⌥↑")
            KeyHint("⌥↓")
            Text("이전·다음 파일")
            Spacer().frame(width: 6)
            KeyHint("space")
            Text("포함 전환")
        }
        .fixedSize()
    }

    /// 흐린 안내 묶음 + 오른쪽 문구 (폭이 넉넉할 때).
    private func inactive(_ note: String) -> some View {
        HStack(spacing: 6) {
            hints.opacity(0.6)
            Spacer(minLength: 4)
            Text(note).fixedSize()
        }
    }

    /// 좁을 때: 안내 대신 한 줄 — 어떤 키가 있는지와 diff 를 눌러야 동작한다는 사실만 남긴다 (키마다의 뜻은 누른 뒤 안내에).
    private var inactiveLine: some View {
        HStack(spacing: 5) {
            Text("diff 를 누르면")
            KeyHint("esc")
            KeyHint("⌥↑")
            KeyHint("⌥↓")
            KeyHint("space")
            Text("키가 동작합니다")
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 키 받는 뷰

/// diff 의 키(esc · ⌥↑ · ⌥↓ · space)를 받는 NSView. **첫 응답자일 때만** keyDown 이 온다 — 텍스트 입력(커밋 메시지 ·
/// 찾기 칸 · 입력창)이나 터미널이 첫 응답자면 키는 그쪽으로 가고 여기 오지 않는다. 시트 · 팝오버는 다른 창이라 오지 않는다.
/// 클릭은 통과시킨다 (`hitTest` → nil). 파일을 눌러 열거나 diff 를 누르면 `token` 이 바뀌어 첫 응답자가 된다.
struct DiffKeyCatcher: NSViewRepresentable {
    let token: Int
    let onCommand: (DiffKeyCommand) -> Void
    let onFocusChange: (Bool) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.token = token
        view.onCommand = onCommand
        view.onFocusChange = onFocusChange
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onCommand = onCommand
        view.onFocusChange = onFocusChange
        if view.token != token {
            view.token = token
            // 이번 배치가 끝난 뒤에 (뷰가 창에 붙은 뒤).
            DispatchQueue.main.async { [weak view] in view?.takeFocus() }
        }
    }

    final class CatcherView: NSView {
        var token = 0
        var onCommand: ((DiffKeyCommand) -> Void)?
        var onFocusChange: ((Bool) -> Void)?

        override var acceptsFirstResponder: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func takeFocus() {
            guard let window, window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }

        override func becomeFirstResponder() -> Bool {
            report(true)
            return true
        }

        override func resignFirstResponder() -> Bool {
            report(false)
            return true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { report(false) }
        }

        private func report(_ focused: Bool) {
            let callback = onFocusChange
            DispatchQueue.main.async { callback?(focused) }
        }

        override func keyDown(with event: NSEvent) {
            let key = DiffKeyCommand.key(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode)
            var modifiers: Set<MenuShortcut.Modifier> = []
            let flags = event.modifierFlags
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.control) { modifiers.insert(.control) }
            guard let command = DiffKeyCommand.command(for: key, modifiers: modifiers) else {
                super.keyDown(with: event)
                return
            }
            // 누르고 있어 반복되는 space · esc 는 한 번만 (포함 전환이 여러 번 돌지 않게). 파일 이동은 반복을 받는다.
            if event.isARepeat, command == .toggleInclusion || command == .back { return }
            onCommand?(command)
        }
    }
}
