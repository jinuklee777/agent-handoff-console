import SwiftUI

// 변경사항 탭의 작은 부품. 판정은 `ChangesState`(비 UI) 가 하고 여기서는 그리기만 한다.

// MARK: - 체크박스

/// 14pt 포함 체크박스 (목업 lib.py `checkbox`). 켜짐 = 잉크 + 흰 체크, 일부 = 잉크 + 흰 가로선,
/// 꺼짐 = 흰 바탕 + slate2 테두리. 잠겼을 때는 40%.
struct IncludeCheckbox: View {
    let state: ChangesState.Inclusion
    var dimmed = false

    var body: some View {
        ZStack {
            switch state {
            case .on, .mixed:
                RoundedRectangle(cornerRadius: 4).fill(Theme.ink)
                if state == .on {
                    CheckMark()
                        .stroke(Theme.onInk, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .frame(width: 10, height: 10)
                } else {
                    Capsule().fill(Theme.onInk).frame(width: 6.4, height: 1.6)
                }
            case .off, .conflict:
                RoundedRectangle(cornerRadius: 4).fill(Theme.card)
                RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.slate2, lineWidth: 1)
            }
        }
        .frame(width: 14, height: 14)
        .opacity(dimmed ? 0.4 : 1)
        .accessibilityHidden(true)
    }

    /// 10×10 격자의 체크 표시.
    private struct CheckMark: Shape {
        func path(in rect: CGRect) -> Path {
            let s = rect.width / 10
            var p = Path()
            p.move(to: CGPoint(x: 2.2 * s, y: 5.2 * s))
            p.addLine(to: CGPoint(x: 4.1 * s, y: 7.1 * s))
            p.addLine(to: CGPoint(x: 7.9 * s, y: 3.1 * s))
            return p
        }
    }
}

extension ChangesState.Inclusion {
    /// 접근성 값.
    var spokenValue: String {
        switch self {
        case .on: return "커밋에 포함"
        case .mixed: return "일부 포함됨"
        case .off: return "포함 안 됨"
        case .conflict: return "충돌 · 선택할 수 없음"
        }
    }
}

// MARK: - 파일 행

/// 변경 파일 한 줄 (26pt). 행을 누르면 그 파일의 diff 를 연다 (`onSelect` — 좁은 패널, 크게 보기 중이면 가운데 파일이 바뀐다).
/// 체크박스와 나머지(diff 열기)는 따로 누르는 단추다 — 키보드(Tab · space) · VoiceOver 로도 diff 를 열 수 있다 (H23 · txt-20).
struct ChangeFileRow: View {
    let row: ChangesState.Row
    let providers: [AgentProvider]
    let editingNow: Bool
    /// "지금 편집 중" 점의 색 (실행 중인 에이전트).
    var editingTint: Color = Theme.claude
    let selected: Bool
    /// git 쓰기가 잠겼다 (에이전트 실행 중 등). 체크박스를 40% 로 그리고 누를 수 없다.
    let locked: Bool
    /// 다른 git 명령을 실행하는 중. 누를 수 없지만 흐리게 그리지는 않는다 (체크할 때마다 목록이 깜빡이지 않게).
    let busy: Bool
    /// 이 행의 스테이지 명령을 실행하는 중.
    let pending: Bool
    let lockReason: String?
    /// 병합 · rebase 중이라 커밋에서 뺄 수 없는 포함된 행 (`ChangesState.toggleOperation(for:merging:)` 이 nil).
    /// 체크 표시는 그대로 두고 누를 수 없게 한다.
    var holdsIncluded = false
    let onToggle: () -> Void
    let onSelect: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                IncludeCheckbox(state: row.inclusion, dimmed: locked || pending || !row.isCheckable || holdsIncluded)
                    .frame(width: 14, height: 24)
                    .contentShape(Rectangle().inset(by: -3))
            }
            .buttonStyle(.plain)
            .disabled(locked || busy || pending || !row.isCheckable || holdsIncluded)
            .help(checkboxHelp)
            .accessibilityLabel("\(row.fileName) 커밋에 포함")
            .accessibilityValue(row.inclusion.spokenValue)

            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Text(row.code)
                        .font(Theme.mono(.caption, .bold))
                        .foregroundStyle(GitCode.color(row.code))
                        .frame(width: 12, alignment: .leading)
                        .help(codeHelp)
                    // 긴 이름은 가운데를 줄여 폴더 칸이 밀려나지 않게 한다 (전체 경로는 도움말).
                    CappedWidth(max: 210) {
                        Text(row.fileName)
                            .font(Theme.ui(.callout, selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .layoutPriority(1)
                    if row.inclusion == .mixed {
                        PartialTag()
                    } else if row.inclusion == .conflict {
                        ConflictTag()
                    }
                    Text(row.directory)
                        .font(Theme.mono(.caption))
                        .foregroundStyle(Theme.slate2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if editingNow {
                        RunningDot(color: editingTint)
                            .help("이번 실행에서 편집됨")
                    }
                    ForEach(providers) { provider in
                        BrandMark(provider: provider, size: 11)
                            .help("이 대화에서 \(provider.displayName) 가 편집함")
                    }
                    LineCountLabel(added: row.added, removed: row.removed, zeroHelp: zeroHelp)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(row.fileName) diff 보기")
            .accessibilityValue(accessibilityStatus)
            .accessibilityHint(row.directory.isEmpty ? "저장소 맨 위 폴더" : row.directory)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 6).fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hair))
            } else if hovered {
                RoundedRectangle(cornerRadius: 6).fill(Theme.well.opacity(0.7))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onSelect)
        .help(pathHelp)
    }

    private var pathHelp: String {
        row.originalPath.map { "\($0) → \(row.path)" } ?? row.path
    }

    /// VoiceOver 가 읽는 행의 상태: 바뀐 종류 · 커밋 포함 여부 · 줄 수 (모르면 쓰지 않는다).
    private var accessibilityStatus: String {
        var parts = [row.codeNote ?? GitCode.name(row.code), row.inclusion.spokenValue]
        if let added = row.added, let removed = row.removed { parts.append("추가 \(added)줄 · 삭제 \(removed)줄") }
        if editingNow { parts.append("이번 실행에서 편집됨") }
        return parts.joined(separator: ", ")
    }

    private var codeHelp: String {
        row.codeNote ?? GitCode.name(row.code)
    }

    /// 줄 변화가 0 일 때의 도움말. 행에서 아는 사실만 붙인다 (원인을 짐작하지 않는다).
    private var zeroHelp: String {
        if row.isUntracked { return "줄 변화 없음 · 빈 새 파일" }
        if row.code == "R" { return "줄 변화 없음 · 이름만 바뀜" }
        return "줄 변화 없음"
    }

    private var checkboxHelp: String {
        if !row.isCheckable { return "충돌 — 위 안내의 [해결됨으로 표시] 로 알리면 커밋에 포함됩니다" }
        if locked, let lockReason { return lockReason }
        if holdsIncluded {
            return "병합 · rebase 중에는 커밋에서 뺄 수 없습니다 — 빼면 합쳐진 변경이 기록에서 빠집니다."
        }
        switch row.inclusion {
        case .on: return "커밋에서 빼기 (git restore --staged)"
        case .mixed: return "일부만 포함됨 — 체크하면 파일 전체를 포함합니다 (git add)"
        case .off, .conflict: return "커밋에 포함 (git add)"
        }
    }
}

/// "충돌" 태그 (danger 규칙선 캡슐). 충돌 행은 체크할 수 없다.
struct ConflictTag: View {
    var body: some View {
        Text("충돌")
            .font(Theme.ui(.caption))
            .foregroundStyle(Theme.danger)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.dangerRule))
            .fixedSize()
            .help("병합 충돌 — 파일 안의 충돌 표시를 정리하고 위 안내의 [해결됨으로 표시] 로 알려야 커밋할 수 있습니다 (git add).")
    }
}

/// "일부 포함됨" 태그.
struct PartialTag: View {
    var body: some View {
        Text("일부 포함됨")
            .font(Theme.ui(.caption))
            .foregroundStyle(Theme.slate)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hair))
            .fixedSize()
            .help("이 파일은 바뀐 곳 가운데 일부만 커밋에 들어갑니다. 체크하면 파일 전체가 들어갑니다.")
    }
}

/// `+a −r`. 줄 수를 모르면 0 이 아니라 "—".
struct LineCountLabel: View {
    let added: Int?
    let removed: Int?
    var zeroHelp = "줄 변화 없음"

    var body: some View {
        HStack(spacing: 4) {
            if added == nil && removed == nil {
                Text("—").foregroundStyle(Theme.slate3)
                    .help("줄 수를 알 수 없음 (이진 파일 · 첫 커밋 전 · 큰 새 파일 등)")
            } else if (added ?? 0) == 0 && (removed ?? 0) == 0 {
                Text("±0").foregroundStyle(Theme.slate2)
                    .help(zeroHelp)
            } else {
                if let added, added > 0 { Text("+\(added)").foregroundStyle(Theme.emeraldText) }
                if let removed, removed > 0 { Text("−\(removed)").foregroundStyle(Theme.danger) }
            }
        }
        .font(Theme.mono(.caption))
        .lineLimit(1)
        .fixedSize()
        .frame(minWidth: 54, alignment: .trailing)
    }
}

// MARK: - 폭 상한

/// 내용 폭만큼만 차지하되 `max` 를 넘지 않는다 (넘으면 안의 글자가 줄어든다).
/// `frame(maxWidth:)` 는 공간이 있으면 상한까지 늘어나 머리줄에 빈 틈이 생긴다.
struct CappedWidth: Layout {
    var max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = proposal.width.map { Swift.min($0, max) } ?? max
        return child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

// MARK: - 버튼

/// 바닥 독의 전체 폭 버튼 (28pt). 켜짐 = 잉크, 꺼짐 = 옅은 바탕 + slate2 (목업 `ink_off`) —
/// 비활성 커밋 버튼이 다른 잉크 버튼과 경쟁하지 않는다. `busy` 면 비활성이어도 잉크 85%.
/// `holdsInk` 면 잠깐 누를 수 없을 뿐(다른 git 명령 실행 중) 모양은 켜짐 그대로 둔다 (깜빡이지 않게).
struct DockButtonStyle: ButtonStyle {
    var busy = false
    var holdsInk = false

    func makeBody(configuration: Configuration) -> some View {
        DockBody(configuration: configuration, busy: busy, holdsInk: holdsInk)
    }

    private struct DockBody: View {
        let configuration: Configuration
        let busy: Bool
        let holdsInk: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let inked = isEnabled || busy || holdsInk
            configuration.label
                .font(Theme.ui(.callout, .semibold))
                .foregroundStyle(inked ? Theme.onInk : Theme.slate2)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(inked ? Theme.ink : Theme.well))
                .opacity(busy ? 0.85 : (configuration.isPressed ? 0.85 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
    }
}

/// 잉크 바탕 위의 작은 회전 표시.
struct InkSpinner: View {
    var color: Color = Theme.onInk

    var body: some View {
        // 회전은 Core Animation 이 한다 (`SpinningLayer` — SwiftUI 반복 애니메이션은 매 프레임 창 전체를 다시 계산한다).
        SpinningLayer(content: .ring(color: color, lineWidth: 1.6, trim: 0.72), period: 0.9)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }
}

// MARK: - 안내 한 줄

/// 버튼 바로 아래의 이유 한 줄 (아이콘 + 글).
struct ReasonLine: View {
    let systemImage: String
    var iconColor: Color = Theme.slate2
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(iconColor)
            Text(text)
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate)
                .lineLimit(3)
        }
    }
}

/// 왼쪽 규칙선 안내 (목업 lib.py `rule_note`): 2pt 규칙선 · 12pt 아이콘 + 제목(11.5/600) · 설명(11) · 동작 줄.
/// 면을 칠하지 않고 선 색으로 종류를 나눈다 (앰버 = 주의, danger = 실패).
struct RuleNote<Actions: View>: View {
    let systemImage: String
    var tint: Color = Theme.amber
    let title: String
    let detail: String
    /// 설명이 git 이 쓴 글자 그대로면 고정폭으로 (선택 · 복사 가능).
    var verbatim = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Group {
                    if systemImage == ForkGlyph.symbolName {
                        ForkGlyph(color: tint, size: 12, lineWidth: 1.5)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                }
                .frame(width: 13)
                Text(title)
                    .font(Theme.ui(.caption, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            Text(detail)
                .font(verbatim ? Theme.mono(.caption) : Theme.ui(.caption))
                .foregroundStyle(verbatim ? Theme.ink2 : Theme.slate)
                .lineSpacing(2.5)
                .lineLimit(verbatim ? 3 : 5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if Actions.self != EmptyView.self {
                HStack(spacing: 8) {
                    actions()
                }
                .padding(.top, 5)
            }
        }
        .padding(.vertical, 1)
        .leadingRule(tint, width: 2, gap: 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension RuleNote where Actions == EmptyView {
    init(systemImage: String, tint: Color = Theme.amber, title: String, detail: String, verbatim: Bool = false) {
        self.init(systemImage: systemImage, tint: tint, title: title, detail: detail, verbatim: verbatim) {
            EmptyView()
        }
    }
}

/// 기록 분기 표시 (목업 lib.py `fork`: 아래 한 점에서 위 두 점으로 갈라지는 선). 머리줄 브랜치 버튼의
/// `arrow.triangle.branch` 와 모양을 나눠, 앰버 색이 아니어도 "갈라짐" 이 브랜치와 구분되게 한다.
struct ForkGlyph: View {
    /// `RuleNote(systemImage:)` 에 넘기는 앱 전용 이름 (SF Symbol 이 아니다).
    static let symbolName = "ahc.fork"
    var color: Color
    var size: CGFloat = 12
    /// 16 격자 기준 선 굵기 (목업 `icon("fork", 12, …, 1.5)`).
    var lineWidth: CGFloat = 1.5

    var body: some View {
        ForkShape()
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth * size / 16, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// 16×16 격자 (목업 SVG 경로 그대로).
    private struct ForkShape: Shape {
        func path(in rect: CGRect) -> Path {
            let s = rect.width / 16
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
            var path = Path()
            for (x, y) in [(8.0, 12.6), (3.9, 3.4), (12.1, 3.4)] {
                path.addEllipse(in: CGRect(x: rect.minX + (x - 1.55) * s, y: rect.minY + (y - 1.55) * s,
                                           width: 3.1 * s, height: 3.1 * s))
            }
            path.move(to: p(8, 11.05))
            path.addLine(to: p(8, 9.2))
            path.addCurve(to: p(3.9, 4.95), control1: p(8, 7.8), control2: p(3.9, 7.1))
            path.move(to: p(8, 9.2))
            path.addCurve(to: p(12.1, 4.95), control1: p(8, 7.8), control2: p(12.1, 7.1))
            return path
        }
    }
}

// MARK: - 커밋 목록

/// 목록 안의 작은 섹션 머리 (목업 `section_head`): 라벨 · 개수 · (오른쪽 아이콘).
struct ListSectionHead: View {
    let label: String
    let count: Int
    var color: Color = Theme.slate2
    var trailingSystemImage: String?

    var body: some View {
        HStack(spacing: 8) {
            SectionLabel(label, color: color)
            Text("\(count)")
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.slate2)
            Spacer(minLength: 4)
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.slate2)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }
}

/// 커밋 한 줄 (목업 `commit_line`, 26pt): 작성자 머리글자 원 · 해시 · 제목 · "작성자 · 시각".
/// 시각은 git 이 준 커밋 시각을 앱의 상대 시각으로 (없으면 git 의 `%ar` 글자 그대로).
struct CommitLineRow: View {
    let entry: GitLogEntry

    var body: some View {
        let when = ChangesState.commitTime(entry.committedAt, fallback: entry.relativeDate) ?? ""
        HStack(spacing: 8) {
            Text(entry.authorInitial)
                .font(Theme.ui(.caption, .bold))
                .foregroundStyle(Theme.slate)
                .frame(width: 20, height: 20)
                .background(Theme.hair, in: Circle())
                .accessibilityHidden(true)
            Text(entry.shortHash)
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.slate2)
                .fixedSize()
            Text(entry.subject)
                .font(Theme.ui(.callout))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            // 작성자 이름은 140pt 까지만 (긴 이름이 제목을 밀어내지 않게), 시각은 그대로 둔다.
            HStack(spacing: 0) {
                if !entry.author.isEmpty {
                    CappedWidth(max: 140) {
                        Text(entry.author).lineLimit(1).truncationMode(.tail)
                    }
                    Text(" · ").fixedSize()
                }
                Text(when).lineLimit(1).fixedSize()
            }
            .font(Theme.mono(.caption))
            .foregroundStyle(Theme.slate2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .help("\(entry.shortHash) \(entry.subject)\n\(entry.author) · \(when)")
    }
}

// MARK: - 터미널에서 하는 일 (앱은 하지 않는다)

/// "합치는 방법" — 기록이 갈라졌을 때 사용자가 터미널에서 할 수 있는 방법을 사실대로 적는다.
struct MergeHowToView: View {
    /// 추적 브랜치 (`origin/feature/login`). 모르면 nil.
    let upstream: String?
    let openTerminal: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("터미널에서 합치는 방법")
                .font(Theme.ui(.callout, .semibold))
                .foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 7) {
                HowToLine(command: "git pull --rebase",
                          detail: "원격 커밋을 받아 그 위에 내 커밋을 다시 쌓습니다.")
                HowToLine(command: "git merge \(upstream ?? "<추적 브랜치>")",
                          detail: "마지막으로 확인한 원격 기록과 합치는 병합 커밋을 만듭니다.")
            }
            Text("충돌이 나면 파일을 정리하고 git add 로 해결됨을 표시한 뒤 이어서 진행합니다 — rebase 는 "
                 + "git rebase --continue, merge 는 이 탭에서 커밋하면 됩니다. 합친 다음 이 탭에서 업로드하세요.")
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("앱은 원격 기록과 합치거나 되돌리거나 강제로 업로드하지 않습니다.")
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                if let openTerminal {
                    Button(action: openTerminal) {
                        HStack(spacing: 5) {
                            Image(systemName: "terminal").font(.system(size: 10.5))
                            Text("터미널 열기")
                        }
                    }
                    .buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 10))
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 340)
    }
}

/// "합치기를 멈추는 방법" — 병합을 되돌리는 명령은 사용자가 터미널에서 한다.
struct MergeAbortHelpView: View {
    let openTerminal: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("합치기를 멈추려면")
                .font(Theme.ui(.callout, .semibold))
                .foregroundStyle(Theme.ink)
            HowToLine(command: "git merge --abort",
                      detail: "병합을 시작하기 전 상태로 돌아갑니다. 충돌을 정리하며 고친 내용도 함께 되돌아갑니다.")
            Text("병합을 시작할 때 커밋하지 않은 변경이 있었다면 git 이 그대로 되살리지 못할 수 있습니다.")
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("앱은 이 명령을 실행하지 않습니다.")
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate2)
                Spacer(minLength: 6)
                if let openTerminal {
                    Button(action: openTerminal) {
                        HStack(spacing: 5) {
                            Image(systemName: "terminal").font(.system(size: 10.5))
                            Text("터미널 열기")
                        }
                    }
                    .buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 10))
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 320)
    }
}

/// 명령 한 줄 + 설명 (고정폭 명령은 선택 · 복사 가능).
private struct HowToLine: View {
    let command: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(command)
                .font(Theme.mono(.caption, .semibold))
                .foregroundStyle(Theme.ink2)
                .textSelection(.enabled)
            Text(detail)
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 11)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.hair).frame(width: 1) }
    }
}

// MARK: - PR 행

/// 변경사항 탭의 PR 한 줄 (목업 panel.py `pr_row`). 조회는 탭을 열 때 한 번 (`ChangesState.pullRequestQueryNeeded`,
/// 캐시가 없을 때만) — 여기서는 캐시된 결과를 그리기만 하고 네트워크를 쓰지 않는다. 다시 조회는 ··· 메뉴.
/// 모르는 수를 0 으로 쓰지 않는다: 검사가 없으면 "검사 없음", 로딩 · 실패 · gh 없음 · PR 없음은 한 줄 사실 문구.
/// "n분 전 조회" 는 분 단위로만 다시 그린다 (gh 를 다시 부르지 않는다).
struct PullRequestRow: View {
    let state: PullRequestState
    let checkedAt: Date?
    let onDetails: () -> Void

    var body: some View {
        TimelineView(.everyMinute) { context in
            switch ChangesState.pullRequestLine(state, checkedAt: checkedAt, now: context.date) {
            case .hidden:
                EmptyView()
            case .loading:
                oneLine(help: "gh pr view — 읽기만 합니다") {
                    InkSpinner(color: Theme.slate)
                    Text("gh 로 이 브랜치의 PR 을 찾는 중…")
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate)
                }
            case .message(let text, let checked, let help):
                oneLine(help: help) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.slate2)
                    Text(text)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    if let checked {
                        Text(checked).font(Theme.mono(.caption)).foregroundStyle(Theme.slate2).fixedSize()
                    }
                }
            case .loaded(let info):
                loaded(info, checked: ChangesState.checkedText(checkedAt, now: context.date))
            }
        }
    }

    private func oneLine<Content: View>(help: String?, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
            .help(help ?? "")
    }

    private func loaded(_ info: PullRequestInfo, checked: String?) -> some View {
        let summary = ChangesState.checksSummary(info.checks)
        let changesRequested = ChangesState.changesRequestedCount(info.reviews)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                statePill(ChangesState.pullRequestPill(state: info.state, isDraft: info.isDraft))
                // verbatim — 숫자 서식(#4,821)을 붙이지 않는다.
                Text(verbatim: "#\(info.number)").font(Theme.mono(.caption)).foregroundStyle(Theme.slate).fixedSize()
                Text(info.title)
                    .font(Theme.ui(.callout))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(info.title)
                if let checked {
                    Text(checked)
                        .font(Theme.mono(.caption))
                        .foregroundStyle(Theme.slate2)
                        .fixedSize()
                        .help("gh 로 마지막으로 조회한 시각 · 다시 조회는 ··· 메뉴")
                }
            }
            // 검사 · 실패 · 진행 중 · 변경 요청이 먼저다. 두 링크까지 한 줄에 다 들어가지 않으면 링크를 다음 줄로 내린다
            // (검사 수가 잘리지 않게).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    facts(summary, changesRequested: changesRequested)
                    Spacer(minLength: 6)
                    links(info)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) { facts(summary, changesRequested: changesRequested) }
                    HStack(spacing: 5) { links(info) }
                }
            }
            .font(Theme.ui(.caption))
            .foregroundStyle(Theme.slate)
            .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
    }

    /// 검사 요약 · 실패 수 · 진행 중 수 · 리뷰 변경 요청 수 (한 줄, 줄이지 않는다). 중립 · 건너뜀 수는 도움말에.
    @ViewBuilder
    private func facts(_ summary: ChangesState.ChecksSummary, changesRequested: Int) -> some View {
        HStack(spacing: 4) {
            checksIcon(summary)
            Text(ChangesState.checksText(summary))
        }
        .fixedSize()
        .help(ChangesState.checksHelp(summary))
        if summary.failed > 0 {
            MetaDot()
            Text("실패 \(summary.failed)").foregroundStyle(Theme.danger).fixedSize()
            // 실패가 앞 아이콘을 차지해도 아직 도는 검사가 있다는 것은 따로 보인다.
            if summary.pending > 0 {
                MetaDot()
                HStack(spacing: 4) {
                    PendingRing()
                    Text("진행 중 \(summary.pending)")
                }
                .fixedSize()
            }
        }
        if changesRequested > 0 {
            MetaDot()
            Text("리뷰 변경 요청 \(changesRequested)").foregroundStyle(Theme.amberText)
                .fixedSize()
                .help("리뷰어마다 마지막 리뷰 중 변경 요청(CHANGES_REQUESTED)인 수")
        }
    }

    @ViewBuilder
    private func links(_ info: PullRequestInfo) -> some View {
        Button("PR 상세 보기", action: onDetails)
            .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
            .fixedSize()
            .help("Pull Request 탭에서 봅니다 (다시 조회하지 않고 같은 결과를 씁니다)")
        if let url = URL(string: info.url), !info.url.isEmpty {
            MetaDot()
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                HStack(spacing: 3) {
                    Text("GitHub 에서 열기")
                    Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .semibold))
                }
            }
            .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
            .fixedSize()
            .help(info.url)
        }
    }

    /// 실패 → ✕, 진행 중 → 도는 링, 모두 통과 → ✓. 검사가 없거나 중립 · 건너뜀만 남으면 표시 없음.
    @ViewBuilder
    private func checksIcon(_ s: ChangesState.ChecksSummary) -> some View {
        if s.failed > 0 {
            Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.danger)
        } else if s.pending > 0 {
            PendingRing()
        } else if s.total > 0 && s.passed == s.total {
            Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.emerald)
        }
    }

    private func statePill(_ pill: ChangesState.PullRequestPill) -> some View {
        let (color, well, border): (Color, Color, Color) = {
            switch pill {
            case .open: return (Theme.emerald, Theme.emeraldWell, Theme.emeraldBorder)
            case .closed: return (Theme.danger, Theme.card, Theme.dangerRule)
            case .draft, .merged, .other: return (Theme.slate, Theme.wellSoft, Theme.hair)
            }
        }()
        return HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.pull").font(.system(size: 8, weight: .semibold))
            Text(pill.label).font(Theme.ui(.caption, .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .frame(height: 19)
        .background(well, in: Capsule())
        .overlay(Capsule().strokeBorder(border))
        .fixedSize()
    }
}

// MARK: - 충돌 해결됨으로 표시 (chg-11)

/// "해결됨으로 표시" 팝오버: 충돌 파일마다 충돌 표시(<<<<<<< · >>>>>>>)가 남았는지 읽어 보이고, 남지 않은 파일을 골라 해결됨으로
/// 표시한다 (`git add` — 앱의 체크박스와 같은 명령). 표시가 남은 파일은 고를 수 없다 — 파일을 정리해 저장한 뒤 다시 연다.
/// 읽지 못한 파일(이진 · 큰 파일 · 지워진 파일)은 처음에 고르지 않되 사람이 고를 수 있다 (터미널에서 한쪽을 골랐을 수 있다).
struct ConflictResolveView: View {
    let rows: [ChangesState.Row]
    /// 저장소 루트 (행의 경로가 이 기준). 모르면 표시를 읽지 않는다.
    let root: URL?
    let onMark: ([String]) -> Void

    @State private var markers: [String: ChangesState.ConflictMarkers] = [:]
    @State private var chosen: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("충돌을 해결됨으로 표시")
                .font(Theme.ui(.callout, .semibold))
                .foregroundStyle(Theme.ink)
            Text("파일 안의 충돌 표시를 정리하고 저장한 파일만 표시할 수 있습니다. 표시하면 그 파일은 커밋에 포함됩니다 (git add).")
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in fileLine(row) }
                }
            }
            .frame(maxHeight: 200)
            HStack(spacing: 8) {
                Spacer()
                Button("해결됨으로 표시" + (chosen.isEmpty ? "" : " · \(chosen.count)")) {
                    onMark(rows.map(\.path).filter { chosen.contains($0) })
                }
                .buttonStyle(InkButtonStyle(height: 26))
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 340)
        .task { await readMarkers() }
    }

    private func fileLine(_ row: ChangesState.Row) -> some View {
        let state = markers[row.path]
        let selectable = state == .absent || state == .unknown
        return HStack(spacing: 7) {
            Toggle(isOn: Binding(get: { chosen.contains(row.path) },
                                 set: { on in if on { chosen.insert(row.path) } else { chosen.remove(row.path) } })) {
                Text(row.fileName)
                    .font(Theme.ui(.callout))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .toggleStyle(.checkbox)
            .disabled(!selectable)
            .help(row.path)
            Spacer(minLength: 6)
            Group {
                switch state {
                case nil: Text("읽는 중…").foregroundStyle(Theme.slate2)
                case .present?: Text("충돌 표시 남음").foregroundStyle(Theme.amberText)
                case .absent?: Text("정리됨").foregroundStyle(Theme.emeraldText)
                case .unknown?: Text("확인하지 못함").foregroundStyle(Theme.slate2)
                }
            }
            .font(Theme.ui(.caption))
            .fixedSize()
            .help(state == .unknown ? "이진 · 큰 파일이거나 지워진 파일이라 충돌 표시를 읽지 못했습니다. 정리했으면 골라서 표시하세요." : "")
        }
        .frame(minHeight: 22)
    }

    private func readMarkers() async {
        guard let root else {
            markers = Dictionary(uniqueKeysWithValues: rows.map { ($0.path, ChangesState.ConflictMarkers.unknown) })
            return
        }
        let paths = rows.map(\.path)
        let read = await Task.detached(priority: .userInitiated) { () -> [String: ChangesState.ConflictMarkers] in
            var out: [String: ChangesState.ConflictMarkers] = [:]
            for path in paths {
                let url = root.appendingPathComponent(path)
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes?[.size] as? NSNumber)?.intValue ?? Int.max
                // 큰 파일은 읽지 않는다 (확인하지 못함).
                let data: Data? = size <= 4_000_000 ? try? Data(contentsOf: url) : nil
                out[path] = ChangesState.conflictMarkers(in: data)
            }
            return out
        }.value
        markers = read
        chosen = Set(read.filter { $0.value == .absent }.map(\.key))
    }
}

// MARK: - 출력 보기

/// git 이 낸 출력 전문 (선택 · 복사 가능). 같은 내용이 대화 기록에도 남는다.
struct GitOutputView: View {
    let command: String
    let output: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(command)
                .font(Theme.mono(.caption, .semibold))
                .foregroundStyle(Theme.ink2)
                .lineLimit(2)
                .textSelection(.enabled)
            ScrollView {
                Text(output.isEmpty ? "(출력 없음)" : output)
                    .font(Theme.mono(.caption))
                    .foregroundStyle(Theme.slate)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
            Text("같은 출력이 대화 기록에도 남아 있습니다.")
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate2)
        }
        .padding(14)
        .frame(width: 360)
    }
}
