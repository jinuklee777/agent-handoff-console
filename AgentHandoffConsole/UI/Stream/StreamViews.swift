import AppKit
import SwiftUI

// 대화 스트림의 행들. 면을 나누지 않고 왼쪽 1–2px 규칙선과 여백으로 종류를 구분한다.
// 색 채움은 사용자의 판단이 필요한 승인과 오류에만 쓴다.

extension StreamRow {
    /// 앞 행과의 간격. 턴 사이는 22pt, 같은 턴 안은 좁게.
    func topSpacing(after previous: StreamRow?) -> CGFloat {
        guard let previous else { return 0 }
        switch self {
        case .user, .relay, .agentHeader:
            return Theme.Metric.turnGap
        case .agentMessage:
            if case .agentHeader = previous { return 9 }
            return 14
        case .execution:
            if case .agentHeader = previous { return 9 }
            return 12
        case .runChanges:
            if case .agentHeader = previous { return 9 }
            return 12
        case .turnFooter:
            return 10
        case .alert:
            if case .agentHeader = previous { return 9 }
            return 14
        case .notice:
            return 12
        }
    }
}

struct StreamRowView: View {
    let row: StreamRow
    /// 대화 안 찾기의 지금 결과면 찾을 말 — 접힌 실행 기록이면 블록과 맞은 단계를 펼쳐 맞은 글을 보인다 (conv-4).
    var findQuery: String? = nil

    var body: some View {
        switch row {
        case .user(let event):
            UserMessageRow(event: event)
        case .agentHeader(let header):
            AgentHeaderRow(header: header)
        case .agentMessage(let event):
            StreamingAgentMessage(event: event)
                .padding(.leading, Theme.Metric.agentIndent)
        case .execution(_, let entries):
            ExecutionBlockView(entries: entries, foldable: true, findQuery: findQuery)
        case .runChanges(let changes):
            RunChangesCard(row: changes)
        case .turnFooter(let runID, let filesUnchanged):
            TurnFooterRow(runID: runID, filesUnchanged: filesUnchanged)
        case .relay(let relay):
            RelayLine(relay: relay)
        case .alert(let event):
            AlertRow(event: event)
        case .notice(let event):
            NoticeRow(event: event)
        }
    }
}

// MARK: - 흐르는 응답

/// 에이전트 응답 본문. 흐르는 중인 응답은 받은 조각을 고른 속도로 풀고(`StreamReveal`) 새 글자는 서서히 보인다
/// (`MarkdownReveal` — 텍스트 뷰가 그릴 때만 한다) — 받은 대로 그리면 CLI 가 몰아 보낸 조각이 와르르 붙었다 멈췄다 해 딱딱했다
/// (2026-10-06). 커서는 두지 않는다 — 글이 흐르는 것과 대화 끝의 상태 줄이 진행을 말한다.
struct StreamingAgentMessage: View {
    let event: ThreadEvent
    /// 처음 그릴 때 정한다: 막 시작한 응답이면 처음부터 풀고, 이미 흐르던 응답(대화를 다시 열었다)이면 지금까지의 글을 곧바로.
    @State private var fromBeginning: Bool

    init(event: ThreadEvent) {
        self.event = event
        _fromBeginning = State(initialValue: event.isStreaming
                               && StreamReveal.startsFromBeginning(createdAt: event.createdAt))
    }

    var body: some View {
        MarkdownMessage(text: event.text, color: Theme.ink2, reveal: event.isStreaming ? .streaming : .finished,
                        revealsFromBeginning: fromBeginning)
    }
}

// MARK: - 사용자 · 에이전트 머리글

/// 사용자 메시지는 옅은 면의 말풍선 하나 — 이름 · 프롬프트 기호 없이 면으로만 에이전트 응답과 구분한다. 시각은 도움말에.
/// 글은 친 그대로(평문) 그린다 — 코드 울타리(```)만 상자로. Markdown 으로 그리면 붙여 넣은 오류의 `__init__` 이 굵은 "init",
/// `# ` 로 시작하는 줄이 제목이 되고, 복사하면 바뀐 글이 나왔다 (첫 사용자 시험 chat-10). 복사는 원문 그대로다.
struct UserMessageRow: View {
    let event: ThreadEvent

    var body: some View {
        let images = event.imageAttachments
        VStack(alignment: .leading, spacing: 8) {
            // 붙인 이미지 — 누르면 기본 앱으로 연다.
            if !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(images) { ImageThumbnail(attachment: $0, side: 88) }
                    }
                }
                .scrollIndicators(.never)
            }
            if !event.text.isEmpty {
                MarkdownMessage(text: event.text, color: Theme.ink, help: Fmt.dateTime.string(from: event.createdAt),
                                plain: true)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.well))
        .help(Fmt.dateTime.string(from: event.createdAt))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("사용자, \(Fmt.time.string(from: event.createdAt)): \(event.text)"
                            + (images.isEmpty ? "" : " · 이미지 \(images.count)장"))
    }
}

struct AgentHeaderRow: View {
    @Environment(AppModel.self) private var model
    /// 이 행이 놓인 칸의 대화 상태 (분할 화면의 칸마다 다르다).
    @Environment(ThreadPaneModel.self) private var pane
    let header: AgentTurnHeader

    private var run: Run? { pane.runsByID[header.runID] }
    private var usage: UsageRecord? { pane.usageByRun[header.runID] }
    /// 이 턴을 지금 돌리는 세션 (실행 슬롯 또는 검토 레인). 끝난 턴이면 nil.
    private var live: RunSession? { model.liveSession(runID: header.runID) }
    private var isLive: Bool { live != nil }

    var body: some View {
        // 로고 · 이름 · (계정) · 모델 (도는 턴이면 · 강도 · 상태) · 시각 — 한 줄, 글꼴 두 가지(이름 12.5 · 나머지 11).
        // 쓴 시간 · 토큰 · 비용은 턴 끝의 바닥글 한 줄에 (`TurnFooterRow`).
        HStack(spacing: 8) {
            BrandMark(provider: header.provider, size: 13)
                .frame(width: Theme.Metric.agentIndent - 8, alignment: .leading)
            Text(header.provider.displayName)
                .font(Theme.ui(.callout, .medium))
                .foregroundStyle(Theme.ink)
            if let label = accountLabel {
                Text(label)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
            }
            meta
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(Fmt.clock.string(from: header.time))
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate2)
                .help(Fmt.dateTime.string(from: header.time))
        }
        // 여러 턴을 한 번에 복사하면 누가 말했는지 남게 (메타 · 시각은 빼고 이름만).
        .streamSelectable(header.provider.displayName + (accountLabel.map { " · \($0)" } ?? ""), kind: .label)
    }

    private var accountID: String? {
        guard header.provider == .codex else { return nil }
        return run?.codexAccountID ?? live?.activeAccount?.id
    }

    private var accountLabel: String? {
        guard header.provider == .codex, model.accounts.hasMultiple else { return nil }
        return accountID.map { model.accounts.accountOrDefault($0).label }
    }

    /// 모델 ID → 목록의 이름 ("gpt-5.6-sol" → "GPT-5.6 Sol", "claude-opus-5-5" → "Opus 5.5"). 모르면 ID 그대로.
    private func modelName(_ id: String) -> String {
        let scope = AgentScope(provider: header.provider,
                               accountID: header.provider == .codex ? (accountID ?? CodexAccount.defaultID) : "")
        return ModelCatalog.runModelName(id, catalog: model.options(for: scope))
    }

    @ViewBuilder
    private var meta: some View {
        HStack(spacing: 0) {
            if isLive {
                let selection = live?.activeSelection
                if let id = run?.model ?? selection?.model {
                    Text(modelName(id)).help(id)
                } else {
                    Text("모델 확인 중")
                }
                // 넘긴 강도 그대로 — Antigravity ULTRA 는 "ULTRA · High + /boost".
                if let effort = EffortScale.runMeta(effort: selection?.effort, boost: live?.activeBoost ?? false) {
                    Text(" · \(effort.text)")
                        .foregroundStyle(effort.tier == .ultra ? Theme.ultraText
                                         : (effort.tier == .max ? Theme.flameText : Theme.slate))
                }
                Text(" · ")
                if let live, live.isWaitingOnBackground, live.state == .running {
                    // 에이전트의 답은 끝났고 남은 백그라운드 작업을 기다린다. 시계는 두지 않는다 — 기다린 시간은 대화 끝의 상태 줄
                    // 하나가 센다 (같은 기다림에 시계 둘이 서로 다른 값을 보이던 것). 중단 중 · 하위의 승인 대기는 그 상태 글이 우선이다.
                    Text(SubAgentDigest.waitingText(count: live.unfinishedSubAgentCount))
                } else {
                    Text(liveStateText).foregroundStyle(live?.state == .awaitingApproval ? Theme.amberText : Theme.slate)
                }
            } else {
                if let id = usage?.model ?? run?.model {
                    Text(modelName(id)).help(id)
                } else {
                    Text("모델 미확인")
                }
                stateSuffix
            }
        }
        .font(Theme.ui(.caption))
        .foregroundStyle(Theme.slate)
    }

    @ViewBuilder
    private var stateSuffix: some View {
        if let run, run.state != .completed {
            Text(" · ")
            Text(run.state.isTerminal || !run.state.isActive ? run.state.koreanName : "종료 미확인")
                .foregroundStyle(run.state == .cancelled ? Theme.slate : run.state.tint)
        }
    }

    private var liveStateText: String {
        guard let live else { return "" }
        switch live.state {
        case .running, .starting: return "실행 중"
        // 실행 상태는 승인과 같지만 기다리는 것이 질문뿐이면 "질문" 이라고 쓴다 (칸 머리 · 사이드바와 같은 말).
        case .awaitingApproval where live.pendingApprovals.isEmpty && !live.pendingQuestions.isEmpty: return "질문 대기"
        default: return live.state.koreanName
        }
    }
}

// MARK: - 실행 기록

/// 도구·명령·파일 편집 — 규칙선 블록. 하위 작업을 띄운 행들이 이어지면 카드 하나(`SubAgentCard`)로 묶는다.
/// 대화 스트림(`foldable`)에서는 세 단계다 (`ExecutionFold`): 접힌 한 줄("명령 7개 실행 · 오류 1개 ›") → 누르면 단계마다 한 줄
/// (`ExecutionStepRow` — 작업 설명) → 단계 줄을 누르면 그 단계의 원문 · 출력 · 종료 코드. 하위 작업 카드 · 답하지 않은 질문은 접혀도
/// 보이고, 접힌 줄 끝의 개수(오류 · 멈춤 …)를 누르면 그 단계만 펼친다. 도는 실행의 블록도 접혀 있다 — 지금 하는 일은 대화 끝의
/// 상태 줄이 말하고, 도구가 붙거나 끝나도 블록이 접혔다 펴지지 않는다. 인스펙터의 하위 흐름(`foldable` 아님)은 자세히를 그대로 그린다.
struct ExecutionBlockView: View {
    let entries: [ExecutionEntry]
    /// 왼쪽 들여쓰기 (대화 스트림은 에이전트 머리글 아래로 맞춘다. 인스펙터는 좁아 줄인다).
    var indent: CGFloat
    var foldable: Bool
    /// 대화 안 찾기의 지금 결과면 찾을 말 — 블록과 맞은 단계를 펼친다 (그 뒤로는 펼친 채 — 사람이 다시 접을 수 있다).
    var findQuery: String?
    /// 블록을 펼쳤다 (단계 줄이 보인다).
    @State private var expanded: Bool
    /// 접힌 줄 끝의 개수(오류 · 멈춤 …)를 눌러 그 단계만 펼쳤다.
    @State private var showingIssues: Bool
    /// 자세히를 펼친 단계.
    @State private var openSteps: Set<String>

    init(entries: [ExecutionEntry], indent: CGFloat = Theme.Metric.agentIndent, foldable: Bool = false,
         findQuery: String? = nil) {
        self.entries = entries
        self.indent = indent
        self.foldable = foldable
        self.findQuery = findQuery
        let preview = Self.previewFold
        var open = findQuery.map { ThreadFind.matchingEntryIDs($0, in: entries) } ?? []
        switch preview {
        case "issues": open.formUnion(ExecutionFold.plan(entries).issueIDs)
        case "steps": open.formUnion(entries.map(\.id))
        default: break
        }
        _expanded = State(initialValue: findQuery != nil || preview == "expanded" || preview == "steps")
        _showingIssues = State(initialValue: preview == "issues")
        _openSteps = State(initialValue: open)
    }

    /// 화면 확인용 처음 상태 (`-preview.execFold expanded|steps|issues`, Debug 빌드 · `AHC_OFFLINE=1` 일 때만).
    private static var previewFold: String? {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["AHC_OFFLINE"] == "1" else { return nil }
        return UserDefaults.standard.string(forKey: "preview.execFold")
        #else
        return nil
        #endif
    }

    var body: some View {
        if foldable {
            let plan = ExecutionFold.plan(entries)
            let shown = plan.visible(entries, expanded: expanded, showingIssues: showingIssues)
            VStack(alignment: .leading, spacing: 8) {
                if let summary = plan.summary {
                    ExecutionSummaryLine(summary: summary, expanded: expanded,
                                         toggle: { expanded.toggle() },
                                         toggleIssues: {
                                             // 펼친 채로 누르면 그 단계만 남긴다. 그 단계는 자세히까지 펼친다 — 오류를 보려고 눌렀다.
                                             if expanded || !showingIssues {
                                                 expanded = false
                                                 showingIssues = true
                                                 openSteps.formUnion(plan.issueIDs)
                                             } else {
                                                 showingIssues = false
                                             }
                                         })
                }
                if !shown.isEmpty { steps(shown) }
            }
            .padding(.leading, indent)
            .onChange(of: findQuery) { _, query in
                guard let query else { return }
                expanded = true
                openSteps.formUnion(ThreadFind.matchingEntryIDs(query, in: entries))
            }
        } else {
            detailBlock
                .padding(.leading, indent)
        }
    }

    /// 펼친 블록 · 접혀도 보이는 것: 단계마다 한 줄. 하위 작업 카드 · 답하지 않은 질문은 단계 줄이 아니라 그대로 그린다.
    private func steps(_ shown: [ExecutionEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ExecutionSegment.group(shown)) { segment in
                switch segment {
                case .entry(let entry):
                    if ExecutionFold.isPinned(entry) {
                        ExecutionEntryView(entry: entry)
                    } else {
                        ExecutionStepRow(entry: entry, open: openSteps.contains(entry.id)) {
                            if openSteps.contains(entry.id) { openSteps.remove(entry.id) } else { openSteps.insert(entry.id) }
                        }
                    }
                case .subAgents(_, let entries):
                    SubAgentCard(entries: entries)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .leadingRule(Theme.hair, width: 1, gap: 15)
    }

    /// 접지 않는 곳(인스펙터의 하위 흐름)의 블록 — 단계마다 자세히.
    private var detailBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(ExecutionSegment.group(entries)) { segment in
                switch segment {
                case .entry(let entry):
                    ExecutionEntryView(entry: entry)
                case .subAgents(_, let entries):
                    SubAgentCard(entries: entries)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .leadingRule(Theme.hair, width: 1, gap: 15)
    }
}

/// 접힌 실행 기록의 한 줄 — "명령 7개 실행 · 파일 3개 읽음 · 오류 1개 ›". 수 · 꺾쇠를 누르면 단계 줄을 펼치고 접는다. 끝의 개수(오류 ·
/// 멈춤 · 결과 미확인 · 승인 대기)는 따로 누르는 단추로, 그 단계만 펼친다. 명령 원문 · 종료 코드는 두지 않는다 (단계를 펼쳐야 보인다).
/// 좁으면 수가 줄어들고 개수는 줄이지 않는다 — 상태를 놓치지 않게.
private struct ExecutionSummaryLine: View {
    let summary: ExecutionFold.Summary
    let expanded: Bool
    let toggle: () -> Void
    let toggleIssues: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button(action: toggle) {
                Text(summary.text)
                    .font(Theme.ui(.callout))
                    .foregroundStyle(Theme.slate)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "실행 기록 접기" : "실행 기록 펼치기 — 단계마다 한 줄, 단계를 누르면 원문 · 출력 · 종료 코드")
            .accessibilityLabel("실행 기록: " + summary.text)
            .accessibilityValue(expanded ? "펼침" : "접힘")

            if let issueText = summary.issueText {
                Text("·")
                    .font(Theme.ui(.callout))
                    .foregroundStyle(Theme.slate3)
                    .fixedSize()
                Button(action: toggleIssues) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        ForEach(Array(summary.issues.enumerated()), id: \.offset) { index, item in
                            if index > 0 { Text(" · ").foregroundStyle(Theme.slate3) }
                            Text(item.text).foregroundStyle(Self.color(item.issue))
                        }
                    }
                    .font(Theme.ui(.callout, .medium))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .layoutPriority(2)
                .help("이 단계만 펼치기 — 성공한 명령은 접어 둔 채")
                .accessibilityLabel(issueText)
                .accessibilityHint("이 단계만 펼칩니다")
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Theme.control)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
                .accessibilityHidden(true)
            // 줄의 남은 자리도 누르면 펼친다.
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 1)
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
                .accessibilityHidden(true)
        }
        .streamSelectable(summary.plainText)
    }

    static func color(_ issue: ExecutionFold.Issue) -> Color {
        switch issue {
        case .awaiting: return Theme.amberText
        case .error: return Theme.danger
        case .stopped: return Theme.slate
        case .unfinished: return Theme.slate2
        }
    }
}

/// 펼친 실행 기록의 단계 한 줄 — "Run test suite  오류 ›" (`ExecutionFold.step`). 누르면 그 단계의 원문 · 출력 · 종료 코드 · diff
/// (`ExecutionEntryView` 의 자세히).
private struct ExecutionStepRow: View {
    let entry: ExecutionEntry
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        let step = ExecutionFold.step(entry)
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // 설명은 보통 글자, 설명 없는 명령의 원문은 흐린 고정폭 — 원문 줄이 설명 줄보다 무겁게 보이지 않게.
                    Text(step.title)
                        .font(step.monospaced ? Theme.mono(.caption) : Theme.ui(.callout))
                        .foregroundStyle(step.monospaced ? Theme.slate : Theme.ink2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let status = step.status { StepStatusLabel(status: status) }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.control)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "접기" : "펼치기 — 원문 · 출력 · 종료 코드")
            .accessibilityLabel(step.title + (step.status.map { ", " + $0.text } ?? ""))
            .accessibilityValue(open ? "펼침" : "접힘")
            .streamSelectable(step.title + (step.status.map { "  " + $0.text } ?? ""))
            if open {
                ExecutionEntryView(entry: entry, detail: true)
                    .padding(.leading, 12)
                    .padding(.bottom, 4)
            }
        }
    }
}

/// 단계 줄 끝의 상태 — 도는 것은 링, 문제는 글자 (끝났고 문제가 없으면 아무것도 없다).
private struct StepStatusLabel: View {
    let status: ExecutionFold.StepStatus

    var body: some View {
        if status == .running {
            PendingRing(color: Theme.slate2)
        } else {
            Text(status.text)
                .font(Theme.ui(.caption, status == .error || status == .awaiting ? .semibold : .regular))
                .foregroundStyle(color)
                .fixedSize()
        }
    }

    private var color: Color {
        switch status {
        case .error: return Theme.danger
        case .awaiting: return Theme.amberText
        case .unfinished, .withdrawn: return Theme.slate2
        default: return Theme.slate
        }
    }
}

// MARK: - 하위 에이전트 카드

/// 메인 흐름에서 하위 작업(하위 에이전트 · 워크플로 · 백그라운드 명령)을 띄운 자리의 카드. 머리("하위 에이전트 N" ·
/// "k 완료 · m 진행 중") + 작업마다 한 줄(상태 점 · 이름 · 경로/종류 · 지금 하는 일 · 도구 수 · 경과 · 상태).
/// 살아 있는 실행이면 진행을 그 세션(`RunSession.subAgents` · `subAgentLiveText`)에서 읽는다 — 저장은 상태가 바뀔 때만이라서.
/// 한 줄을 누르면 오른쪽 인스펙터의 "에이전트" 탭에서 그 하위의 흐름을 연다. 끝난 하위도 카드에 남는다.
struct SubAgentCard: View {
    @Environment(AppModel.self) private var model
    /// 이 카드가 놓인 칸의 대화 상태.
    @Environment(ThreadPaneModel.self) private var pane
    // 인스펙터 탭 · 보이기는 창 상태 값이라 실행 전후 비교 카드처럼 같은 키를 직접 바꾼다.
    @AppStorage(WindowStateKey.inspectorTab) private var inspectorTab: InspectorTab = .files
    @AppStorage(WindowStateKey.inspectorVisible) private var inspectorVisible = WindowStateKey.inspectorVisibleByDefault
    let entries: [ExecutionEntry]

    private struct Line: Identifiable {
        var digest: SubAgentDigest
        var session: RunSession?
        var id: String { digest.id }
    }

    /// 저장된 요약에 살아 있는 세션의 값을 덧씌운다 (진행 · 상태 · 도구 수).
    private var lines: [Line] {
        entries.compactMap(\.subagent).map { digest in
            guard let runID = digest.runID, let session = model.liveSession(runID: runID) else {
                // 도는 세션이 없으면 이 실행의 하위는 더 돌 수 없다 — DB 에 running 으로 남은 실행(충돌 · 강제 종료)이어도.
                var finished = digest
                finished.runFinished = true
                return Line(digest: finished, session: nil)
            }
            var current = digest
            if let live = session.subAgents.first(where: { $0.id == digest.id }) {
                current.info = live
                if let uses = live.toolUses { current.toolCount = uses }
            }
            current.runFinished = false
            return Line(digest: current, session: session)
        }
    }

    var body: some View {
        let lines = self.lines
        let digests = lines.map(\.digest)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol(digests))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.slate)
                    .frame(width: 14)
                Text(SubAgentDigest.groupTitle(digests))
                    .font(Theme.ui(.callout, .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 6)
                Text(SubAgentDigest.countsText(digests) + Self.tokensSuffix(digests))
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
                    .lineLimit(1)
                    .fixedSize()
                    .help(TokenShare.help)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            Rectangle().fill(Theme.hair).frame(height: 1)
            VStack(spacing: 0) {
                ForEach(lines) { line in row(line) }
            }
            .padding(.vertical, 3)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hair, lineWidth: 1))
        .streamSelectable(copyText(lines), kind: .block)
    }

    /// 머리의 처리 토큰 합: " · 처리 1.8만" (아는 하위가 없으면 빈 글).
    static func tokensSuffix(_ digests: [SubAgentDigest]) -> String {
        let total = digests.compactMap(\.info.totalTokens).reduce(0, +)
        return total > 0 ? " · 처리 \(DisplayFormat.tokens(total))" : ""
    }

    private func symbol(_ digests: [SubAgentDigest]) -> String {
        switch Set(digests.map(\.info.kind)) {
        case [.shell]: return "terminal"
        case [.workflow]: return "flowchart"
        default: return InspectorTab.agents.symbol
        }
    }

    /// 한 줄: 상태 점 · 이름 · 경로/종류 · 지금 하는 일 · 도구 수 · 경과 · 상태. 좁으면 지금 하는 일 → 경로/종류 → 도구 수 →
    /// 경과 순으로 뺀다 (글자 조각으로 줄여 남기지 않는다). 이름만 줄임표로 줄어든다 — 칸이 좁아도 줄이 칸을 밀어 넓히지 않게.
    private func row(_ line: Line) -> some View {
        let digest = line.digest
        let finished = !digest.isRunning
        let activity = activity(line)
        // 이름 옆: 모델 · 종류 (`general-purpose` 처럼 줄마다 같은 종류는 뺀다).
        let detail = SubAgentList.subtitle(digest.info)
        return Button { open(digest) } label: {
            HStack(spacing: 8) {
                SubAgentStatusMark(digest: digest)
                    .frame(width: 14)
                ViewThatFits(in: .horizontal) {
                    rowContent(digest, detail: detail, activity: activity, meta: .full)
                    rowContent(digest, detail: detail, activity: nil, meta: .full)
                    rowContent(digest, detail: nil, activity: nil, meta: .full)
                    rowContent(digest, detail: nil, activity: nil, meta: .clock)
                    rowContent(digest, detail: nil, activity: nil, meta: .status)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText(digest, activity: activity, finished: finished))
        .accessibilityLabel("\(SubAgentDigest.kindName(digest.info.kind)) \(digest.info.title), \(digest.statusText)")
    }

    private func helpText(_ digest: SubAgentDigest, activity: String?, finished: Bool) -> String {
        var lines: [String] = [digest.info.title]
        if let activity { lines.append(activity) }
        if let tokens = digest.info.totalTokens, tokens > 0 {
            lines.append("처리 토큰 \(DisplayFormat.exactTokens(tokens)) (캐시 포함)"
                         + (digest.info.newTokens.map { " · 새 토큰 \(DisplayFormat.exactTokens($0))" } ?? ""))
        }
        if digest.isUnfinished { lines.append(SubAgentDigest.unfinishedHelp) }
        let action = finished ? "기록 보기" : "흐름 보기"
        lines.append("\(SubAgentDigest.kindName(digest.info.kind)) · \(digest.statusText) — 눌러서 오른쪽 에이전트 탭에서 \(action)")
        return lines.joined(separator: "\n")
    }

    private enum MetaLevel { case full, clock, status }

    /// 한 줄의 이름부터 끝까지. `ViewThatFits` 가 이상적 너비로 들어가는 첫 판을 고른다 — 지금 하는 일은 이상적 너비를
    /// 60pt 로 재서(실제로는 남는 너비를 다 쓴다) 그만큼 남을 때만 보인다.
    private func rowContent(_ digest: SubAgentDigest, detail: String?, activity: String?, meta level: MetaLevel) -> some View {
        HStack(spacing: 8) {
            WidthCap(max: 240) {
                Text(digest.info.title)
                    .font(Theme.ui(.callout, .medium))
                    .foregroundStyle(digest.effectiveStatus == .stopped || digest.effectiveStatus == .failed
                                     ? Theme.slate : Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(2)
            if let detail {
                WidthCap(max: 160) {
                    Text(detail)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(1)
            }
            if let activity {
                Text(activity)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, idealWidth: 60, maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
            meta(digest, level: level)
                .fixedSize()
                .layoutPriority(3)
        }
    }

    /// 지금 하는 일 — 도는 중이면 흐르는 글 첫 줄 · 진행 설명 · 마지막 도구, 끝났으면 요약 첫 줄. 없으면 하위 흐름의 마지막 일.
    /// Markdown 표식은 걷어 낸다 (본문처럼 그리지 않는 한 줄이라 `` ` `` · `**` 가 글자로 보인다).
    private func activity(_ line: Line) -> String? {
        let digest = line.digest
        if digest.isRunning {
            if let live = SubAgentDigest.firstPlainLine(line.session?.subAgentLiveText[digest.id]) { return live }
            if let progress = SubAgentDigest.firstPlainLine(digest.info.progress), progress != digest.info.title { return progress }
            if let tool = digest.info.lastToolName, !tool.isEmpty { return tool }
            return digest.lastLine
        }
        return SubAgentDigest.firstPlainLine(digest.info.summary) ?? digest.lastLine
    }

    /// 처리 토큰 · 도구 수 · 경과 · 상태. 상태 칸은 가장 긴 상태 글("결과 미확인") 너비로 오른쪽에 맞춰, 줄마다 열이 맞는다.
    /// 처리 토큰은 경과까지만 남는 좁은 줄에도 남긴다 — 누가 얼마나 썼는지가 카드에서 견줄 첫 값이다.
    @ViewBuilder
    private func meta(_ digest: SubAgentDigest, level: MetaLevel) -> some View {
        HStack(spacing: 0) {
            if level != .status {
                Group {
                    if let tokens = digest.info.totalTokens, tokens > 0 {
                        Text("\(DisplayFormat.tokens(tokens)) · ").foregroundColor(Theme.ink2)
                    }
                    if level == .full, digest.toolCount > 0 { Text("도구 \(digest.toolCount) · ") }
                    if digest.isRunning {
                        ElapsedText(since: digest.info.startedAt) { DisplayFormat.elapsed(seconds: $0) }
                    } else if let ended = digest.info.endedAt {
                        Text(DisplayFormat.elapsed(seconds: Int(ended.timeIntervalSince(digest.info.startedAt))))
                    } else {
                        Text("—")
                    }
                }
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.slate2)
            }
            ZStack(alignment: .trailing) {
                Text(SubAgentDigest.statusText(.running, unfinished: true)).hidden()
                Text(digest.statusText)
                    .foregroundStyle(SubAgentStatusMark.color(digest))
            }
            .font(Theme.ui(.caption))
            .padding(.leading, 8)
        }
    }

    private func open(_ digest: SubAgentDigest) {
        inspectorTab = .agents
        inspectorVisible = true
        // 인스펙터는 포커스 칸을 따라간다 — 이 칸으로 포커스를 옮긴 뒤 그 하위를 고른다.
        let threadID = pane.threadID
        Task {
            await model.selectThread(threadID)
            model.focusSubAgent(threadID: threadID, agentID: digest.id)
        }
    }

    /// 스트림 선택의 복사 글: 머리 한 줄 + 작업마다 이름 · 상태.
    private func copyText(_ lines: [Line]) -> String {
        let digests = lines.map(\.digest)
        return ([SubAgentDigest.groupTitle(digests) + " · " + SubAgentDigest.countsText(digests) + Self.tokensSuffix(digests)]
                + digests.map { "· \($0.info.title) — \($0.statusText)"
                    + ($0.info.totalTokens.map { " · 처리 \(DisplayFormat.tokens($0))" } ?? "") }).joined(separator: "\n")
    }
}

/// 안의 뷰를 제 너비까지만, 많아야 `max` 까지 준다. `.frame(maxWidth:)` 와 달리 남는 너비를 차지하지 않고,
/// `.fixedSize()` 와 달리 좁으면 줄어든다 (줄임표) — 줄이 칸을 밀어 넓히지 않게.
struct WidthCap: Layout {
    var max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(ProposedViewSize(width: Swift.min(proposal.width ?? max, max), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// 하위 작업의 상태 표시: 도는 중은 잉크 링, 완료 에메랄드 점, 멈춤 회색 점, 실패 빨간 점, 결과 미확인은 빈 원.
struct SubAgentStatusMark: View {
    let digest: SubAgentDigest

    var body: some View {
        if digest.isRunning {
            PendingRing(color: Theme.ink)
        } else if digest.isUnfinished {
            Circle().strokeBorder(Theme.slate2, lineWidth: 1.2).frame(width: 7, height: 7)
        } else {
            Circle().fill(Self.color(digest)).frame(width: 6, height: 6)
        }
    }

    static func color(_ digest: SubAgentDigest) -> Color {
        switch digest.effectiveStatus {
        case .running: return Theme.ink
        case .completed: return Theme.emerald
        case .failed: return Theme.danger
        case .stopped: return Theme.slate
        }
    }
}

private struct ExecutionEntryView: View {
    let entry: ExecutionEntry
    /// 단계 줄(`ExecutionStepRow`) 아래의 자세히 — 단계 줄이 이미 말한 것(작업 설명 · "추론")은 빼고, 결과 · diff · 생각은 펼친 채로.
    var detail = false

    var body: some View {
        switch entry.kind {
        case .command(let info):
            CommandEntryRow(info: info, detail: detail)
        case .fileEdit(let info):
            FileEditRow(info: info, detail: detail)
        case .tool(let info):
            ToolEntryRow(info: info, detail: detail)
        case .reasoning(let text):
            ReasoningRow(text: text, detail: detail)
        case .approval(let title, _):
            // 한 줄만 — 무엇을 하려는지는 바로 위 도구 · 명령 행에 있고, 기다리는 동안은 아래 승인 카드가 풀어 보인다.
            HStack(spacing: 8) {
                Text("⏸ 승인 요청").font(Theme.mono(.caption, .bold)).foregroundStyle(Theme.amberText)
                Text(title).font(Theme.ui(.caption)).foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.middle)
            }
            .streamSelectable("⏸ 승인 요청 \(title)")
        case .decision(let text):
            Text("↳ 결정 · \(text)")
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.slate)
                .lineLimit(2)
                .streamSelectable("↳ 결정 · \(text)")
        case .question(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("? 질문").font(Theme.mono(.caption, .bold)).foregroundStyle(Theme.ink)
                Text(text).font(Theme.ui(.caption)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .streamSelectable("? 질문 \(text)")
        case .note(let title, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(Theme.mono(.caption, .semibold)).foregroundStyle(Theme.slate)
                Text(text).font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .streamSelectable("\(title) \(text)")
        }
    }
}

/// 끝난 실행에 결과 없이 남은 호출 (`ExecutionParser.settlingUnfinished`).
private struct UnfinishedResultLabel: View {
    var body: some View {
        Text("결과 미확인").font(Theme.mono(.caption)).foregroundStyle(Theme.slate2)
            .help("실행은 끝났지만 이 호출의 결과를 받지 못했습니다")
    }
}

/// 승인 요청과 이어진 호출의 상태 (`ApprovalMark`) — 승인 대기는 "실행 중" 이 아니고, 사람이 거절한 것은 오류가 아니다 (회색).
private struct ApprovalMarkLabel: View {
    let mark: ApprovalMark

    var body: some View {
        switch mark {
        case .awaiting:
            Text("⏸ 승인 대기").font(Theme.mono(.caption, .semibold)).foregroundStyle(Theme.amberText)
                .help("아직 실행하지 않았습니다 — 대화 끝의 승인 카드에서 허용하면 실행합니다")
        case .denied:
            Text("⊘ 거절함").font(Theme.mono(.caption, .semibold)).foregroundStyle(Theme.slate)
                .help("승인 요청을 거절해 실행하지 않았습니다")
        case .withdrawn:
            Text("실행 안 됨").font(Theme.mono(.caption)).foregroundStyle(Theme.slate2)
                .help("승인 없이 요청이 닫혀 실행하지 않았습니다")
        case .answered:
            Text("↩ 답함").font(Theme.mono(.caption, .semibold)).foregroundStyle(Theme.slate)
                .help("질문에 적은 답을 보냈습니다 — 거절이 아닙니다")
        }
    }

}

/// 거절 사유 · 질문에 보낸 답 한 줄 (사람이 적은 글이 있을 때만).
private struct DeniedReasonLine: View {
    let mark: ApprovalMark?

    var body: some View {
        if let line {
            Text(line)
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate)
                .lineLimit(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var line: String? {
        switch mark {
        case .denied(let reason?): return "사유: \(reason)"
        case .answered(let answer?): return "답: \(answer)"
        default: return nil
        }
    }
}

private struct CommandEntryRow: View {
    let info: CommandInfo
    /// 단계 줄 아래의 자세히 — 작업 설명은 단계 줄에 있으니 빼고, 결과는 펼친 채로 시작한다.
    let detail: Bool
    @State private var expanded: Bool

    init(info: CommandInfo, detail: Bool = false) {
        self.info = info
        self.detail = detail
        _expanded = State(initialValue: detail)
    }

    private var lines: [Substring] {
        (info.output ?? "").split(separator: "\n", omittingEmptySubsequences: false)
    }

    private var nonEmptyLines: [Substring] { lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }

    /// 보이는 결과 줄 — 펼쳤으면 끝 400줄, 실행 중 · 실패면 빈 줄을 뺀 끝 두 줄. 없으면 nil.
    /// 승인과 이어진 호출(승인 대기 · 거절함 · 거둠)은 실행되지 않았다 — 거절 사유가 결과처럼 보이지 않게 결과 줄을 두지 않는다.
    private var visibleOutput: ArraySlice<Substring>? {
        guard info.approval == nil, !nonEmptyLines.isEmpty && (expanded || info.running || info.failed) else { return nil }
        return expanded ? lines.suffix(400) : ArraySlice(nonEmptyLines.suffix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("$").font(Theme.mono(.caption, .bold)).foregroundStyle(promptColor)
                // CLI 가 준 작업 설명이 있으면 앞에 — 원문은 그 뒤에 흐리게 (좁으면 원문이 먼저 줄어든다).
                if !detail, let label = info.label {
                    Text(label)
                        .font(Theme.ui(.caption, .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                }
                Text(info.command)
                    .font(Theme.mono(.caption))
                    .foregroundStyle(info.label == nil || detail ? Theme.ink2 : Theme.slate)
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .help(info.rawCommand)
                Spacer(minLength: 8)
                status
            }

            DeniedReasonLine(mark: info.approval)

            if let preview = visibleOutput {
                Text(preview.joined(separator: "\n"))
                    .font(Theme.mono(.caption))
                    .lineSpacing(4)
                    .foregroundStyle(info.failed && !expanded ? Theme.ink2 : Theme.slate)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if info.approval == nil, !nonEmptyLines.isEmpty || info.failed {
                HStack(spacing: 8) {
                    if !nonEmptyLines.isEmpty {
                        Button(expanded ? "⌃ 결과 접기" : "⌄ \(nonEmptyLines.count)줄 결과") {
                            expanded.toggle()
                        }
                        .buttonStyle(TextButtonStyle(color: Theme.slate2, font: Theme.mono(.caption)))
                    }
                    if info.failed, let output = info.output {
                        Text("·").font(Theme.mono(.caption)).foregroundStyle(Theme.slate3)
                        Button("원문 복사") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(info.rawCommand + "\n\n" + output, forType: .string)
                        }
                        .buttonStyle(TextButtonStyle(color: Theme.slate2, font: Theme.mono(.caption)))
                    }
                }
                .padding(.top, 1)
            }
        }
        .streamSelectable(copyText)
    }

    /// 스트림 선택의 복사 글 — 명령 · (승인과 이어졌으면 그 상태) · 보이는 결과 줄.
    private var copyText: String {
        var text = "$ \(info.command)"
        if let approval = info.approval { text += "  " + approval.copyText }
        if let preview = visibleOutput { text += "\n" + preview.joined(separator: "\n") }
        return text
    }

    private var promptColor: Color {
        if info.approval != nil || info.running || info.stopped || info.unfinished { return Theme.slate2 }
        if info.failed { return Theme.danger }
        if info.exitCode == 0 { return Theme.emeraldText }
        return Theme.slate2
    }

    @ViewBuilder
    private var status: some View {
        if let approval = info.approval {
            ApprovalMarkLabel(mark: approval)
        } else if info.running {
            HStack(spacing: 5) {
                PendingRing(color: Theme.slate2)
                Text("실행 중").font(Theme.mono(.caption)).foregroundStyle(Theme.slate2)
            }
        } else if info.unfinished {
            UnfinishedResultLabel()
        } else if info.stopped {
            // 중단 · 취소로 끝났다 (종료 코드 없음) — 완료로 보이지 않게.
            Text("■ 멈춤").font(Theme.mono(.caption, .semibold)).foregroundStyle(Theme.slate)
                .help("명령이 끝나기 전에 멈췄습니다 (실행 중단과 함께)")
        } else if let code = info.exitCode {
            Text(code == 0 ? "✔ 종료 0" : "✕ 종료 \(code)")
                .font(Theme.mono(.caption, .semibold))
                .foregroundStyle(code == 0 ? Theme.emeraldText : Theme.danger)
        } else if info.reportedError {
            Text("✕ 오류").font(Theme.mono(.caption, .semibold)).foregroundStyle(Theme.danger)
        } else {
            Text("✔ 완료").font(Theme.mono(.caption, .semibold)).foregroundStyle(Theme.emeraldText)
                .help("도구 호출 완료 · 종료 코드는 제공되지 않음")
        }
    }
}

private struct FileEditRow: View {
    let info: FileEditInfo
    @State private var expanded: Bool

    /// `detail` — 단계 줄 아래의 자세히: diff 를 펼친 채로 시작한다.
    init(info: FileEditInfo, detail: Bool = false) {
        self.info = info
        _expanded = State(initialValue: detail)
    }

    private var diffLines: [Substring] {
        (info.diff ?? "").split(separator: "\n", omittingEmptySubsequences: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text("±").font(Theme.mono(.caption)).foregroundStyle(Theme.slate3)
                Text(info.paths.first ?? "파일")
                    .font(Theme.mono(.caption))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(info.paths.joined(separator: "\n"))
                if info.paths.count > 1 {
                    Text("외 \(info.paths.count - 1)개").font(Theme.mono(.caption)).foregroundStyle(Theme.slate2)
                }
                // 승인과 이어진 편집(승인 대기 · 거절함 · 거둠)은 아직 · 끝내 적용되지 않았다 — 줄 수는 흐리게, 막대 없이.
                let applied = info.approval == nil
                if let added = info.added {
                    Text("+\(added)").font(Theme.mono(.caption, .semibold)).foregroundStyle(applied ? Theme.emeraldText : Theme.slate2)
                }
                if let removed = info.removed {
                    Text("−\(removed)").font(Theme.mono(.caption, .semibold)).foregroundStyle(applied ? Theme.danger : Theme.slate2)
                }
                if applied, info.added != nil || info.removed != nil {
                    DiffBars(added: info.added ?? 0, removed: info.removed ?? 0)
                }
                if info.approval == .awaiting, info.added != nil || info.removed != nil {
                    Text("예정").font(Theme.mono(.caption)).foregroundStyle(Theme.slate2)
                        .help("허용하면 바뀔 줄 수 — 바꾸기 전 · 뒤를 줄 단위로 견준 수입니다")
                }
                if let approval = info.approval {
                    ApprovalMarkLabel(mark: approval)
                } else {
                    if info.running { PendingRing(color: Theme.slate2) }
                    if info.unfinished { UnfinishedResultLabel() }
                    if info.reportedError {
                        Text("✕ 적용 안 됨").font(Theme.mono(.caption, .semibold)).foregroundStyle(Theme.danger)
                    }
                }
                Spacer(minLength: 6)
                if diffLines.count > 1 {
                    Button(expanded ? "⌃ 접기" : "⌄ \(diffLines.count)줄") { expanded.toggle() }
                        .buttonStyle(TextButtonStyle(color: Theme.slate2, font: Theme.mono(.caption)))
                }
            }
            if expanded, diffLines.count > 1 {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diffLines.prefix(400).enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : String(line))
                            .font(Theme.mono(.caption))
                            .foregroundStyle(color(for: line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(for: line))
                    }
                }
                .textSelection(.enabled)
                .padding(.vertical, 4)
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.codeBorder))
            }
            DeniedReasonLine(mark: info.approval)
        }
        .streamSelectable(copyText)
    }

    /// 스트림 선택의 복사 글 — 보이는 그대로: 경로 · 외 n개 · 줄 수 · (승인과 이어졌으면 그 상태), 펼쳤으면 diff.
    private var copyText: String {
        var text = "± " + (info.paths.first ?? "파일")
        if info.paths.count > 1 { text += " 외 \(info.paths.count - 1)개" }
        if let approval = info.approval { text += "  " + approval.copyText }
        if let added = info.added { text += " +\(added)" }
        if let removed = info.removed { text += " −\(removed)" }
        if expanded, diffLines.count > 1 { text += "\n" + diffLines.prefix(400).joined(separator: "\n") }
        return text
    }

    private func color(for line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") { return Theme.slate2 }
        if line.hasPrefix("+") { return Theme.emeraldText }
        if line.hasPrefix("-") { return Theme.danger }
        return Theme.slate
    }

    private func background(for line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return Theme.emerald.opacity(0.07) }
        if line.hasPrefix("-") { return Theme.danger.opacity(0.06) }
        return .clear
    }
}

private struct ToolEntryRow: View {
    let info: ToolInfo
    @State private var expanded: Bool

    /// `detail` — 단계 줄 아래의 자세히: 결과를 펼친 채로 시작한다.
    init(info: ToolInfo, detail: Bool = false) {
        self.info = info
        _expanded = State(initialValue: detail)
    }

    private var outputLines: Int {
        info.output.map { ExecutionParser.lineCount($0) } ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("·").font(Theme.mono(.caption, .bold)).foregroundStyle(Theme.slate3)
                Text(info.name).font(Theme.mono(.caption)).foregroundStyle(Theme.slate)
                Text(info.summary)
                    .font(Theme.mono(.caption))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if let approval = info.approval {
                    ApprovalMarkLabel(mark: approval)
                } else if info.running {
                    PendingRing(color: Theme.slate2)
                } else if info.unfinished {
                    UnfinishedResultLabel()
                } else if info.reportedError {
                    Text("✕ 오류").font(Theme.mono(.caption, .semibold)).foregroundStyle(Theme.danger)
                }
                // 승인과 이어진 호출의 결과는 결과가 아니다 (거절 사유는 아래 한 줄).
                if info.approval == nil, outputLines > 0 {
                    Button(expanded ? "⌃ 접기" : "⌄ \(outputLines)줄") { expanded.toggle() }
                        .buttonStyle(TextButtonStyle(color: Theme.slate2, font: Theme.mono(.caption)))
                }
            }
            DeniedReasonLine(mark: info.approval)
            if expanded, info.approval == nil, let output = info.output {
                ExpandableMono(text: output, previewLines: 40)
            }
        }
        .streamSelectable(copyText)
    }

    private var copyText: String {
        var text = "· \(info.name) \(info.summary)"
        if let approval = info.approval { text += "  " + approval.copyText }
        if expanded, info.approval == nil, let output = info.output { text += "\n" + output }
        return text
    }
}

private struct ReasoningRow: View {
    let text: String
    /// 단계 줄 아래의 자세히 — "∴ 추론" 머리는 단계 줄에 있으니 빼고, 글은 다 보인다.
    let detail: Bool
    @State private var expanded: Bool

    init(text: String, detail: Bool = false) {
        self.text = text
        self.detail = detail
        _expanded = State(initialValue: detail)
    }

    /// 보일 글 — Codex 추론 요약의 머리 줄은 `**` 를 떼고 (`ExecutionFold.reasoningDisplayText`).
    private var shown: String {
        ExecutionFold.reasoningDisplayText(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !detail {
                Text("∴ 추론").font(Theme.mono(.caption)).tracking(0.8).foregroundStyle(Theme.slate2)
            }
            Text(shown)
                .font(Theme.ui(.callout).italic())
                .lineSpacing(3.5)
                .foregroundStyle(Theme.slate2)
                .lineLimit(expanded ? nil : 3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if text.count > 220 {
                Button(expanded ? "⌃ 접기" : "⌄ 펼치기") { expanded.toggle() }
                    .buttonStyle(TextButtonStyle(color: Theme.slate2, font: Theme.mono(.caption)))
            }
        }
        .streamSelectable("∴ 추론\n" + shown)
    }
}

/// 긴 고정폭 원문. 앞부분만 보여주고 필요할 때 펼친다.
struct ExpandableMono: View {
    let text: String
    var previewLines = 3
    var color: Color = Theme.slate
    @State private var expanded = false
    @State private var copied = false

    /// 펼쳐도 그리는 줄의 상한 — 넘으면 남은 줄 수를 밝히고 전체를 복사할 수 있게 한다 (말없이 자르지 않는다).
    static let expandedLimit = 2000

    private var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }

    var body: some View {
        let lines = lines
        VStack(alignment: .leading, spacing: 3) {
            Text((expanded ? lines.prefix(Self.expandedLimit) : lines.prefix(previewLines)).joined(separator: "\n"))
                .font(Theme.mono(.caption))
                .lineSpacing(3)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if expanded, lines.count > Self.expandedLimit {
                HStack(spacing: 8) {
                    Text("⋯ 이하 \(lines.count - Self.expandedLimit)줄 생략")
                        .font(Theme.mono(.caption))
                        .foregroundStyle(Theme.slate)
                    Button(copied ? "복사함" : "전체 복사") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copied = true
                    }
                    .buttonStyle(TextButtonStyle(color: Theme.slate2, font: Theme.mono(.caption)))
                }
            }
            if lines.count > previewLines {
                Button(expanded ? "⌃ 접기" : "⌄ \(lines.count - previewLines)줄 더") { expanded.toggle() }
                    .buttonStyle(TextButtonStyle(color: Theme.slate2, font: Theme.mono(.caption)))
            }
        }
    }
}

// MARK: - 실행 전후 비교

/// 턴 바닥글 위의 "이번 실행에서 파일 n개가 바뀌었습니다" 카드 (목업 ReviewEntry). 파일 수 · 줄 수는 실행 전후
/// 스냅샷 차이(`RunFileChanges`)로만 쓰고, 줄 수에서 뺀 것은 셋째 줄에 밝힌다. 비교하지 못한 실행은 그 실행의 기록에 남은
/// 편집 수("관찰된 편집 n건")만 적고 줄 수는 쓰지 않는다 (목업과 다르게 — 지어낸 줄 수를 쓰지 않는다).
/// "변경사항 검토" 는 흰 칩 — 입력창의 보내기(잉크)와 경쟁하지 않는다.
struct RunChangesCard: View {
    @Environment(AppModel.self) private var model
    /// 이 카드가 놓인 칸의 대화 상태.
    @Environment(ThreadPaneModel.self) private var pane
    // 인스펙터 탭 · 보이기는 창 상태 값이라 메뉴 명령처럼 같은 키를 직접 바꾼다 (ContentView 가 같은 값을 본다).
    @AppStorage(WindowStateKey.inspectorTab) private var inspectorTab: InspectorTab = .files
    @AppStorage(WindowStateKey.inspectorVisible) private var inspectorVisible = WindowStateKey.inspectorVisibleByDefault
    let row: RunChangesRow

    private var changes: RunFileChanges { row.changes }

    var body: some View {
        Group {
            if changes.compared && changes.fileCount == 0 {
                noChanges
            } else {
                card
            }
        }
        .padding(.leading, Theme.Metric.agentIndent)
    }

    /// 비교했는데 바뀐 파일이 없다 — 카드 없이 한 줄로 (보낼 때마다 빈 카드가 쌓이지 않게).
    /// HEAD 가 바뀌었거나 확인하지 못했으면 커밋된 변경이 있을 수 있어 "작업 트리에 남은 변경 없음" 으로 쓴다.
    /// 무엇으로 센 것인지("실행 전후 비교")와 주석의 긴 문장은 도움말에 — 줄에는 짧은 말만 (`RunFileChanges.cardNotes`).
    private var noChanges: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: InspectorTab.changes.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.control)
                Text(changes.noChangeHeadline)
            }
            if !changes.cardNotes.isEmpty {
                Text(changes.cardNotes.joined(separator: " · "))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(Theme.ui(.caption))
        .foregroundStyle(Theme.slate2)
        .help(basisHelp)
        .accessibilityElement(children: .combine)
    }

    private var card: some View {
        HStack(spacing: 12) {
            Image(systemName: InspectorTab.changes.symbol)
                .font(.system(size: 15))
                .foregroundStyle(Theme.slate)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                headline
                    .font(Theme.ui(.callout))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                detail
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate2)
                    .lineLimit(1)
                if let note = noteLine {
                    Text(note)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(basisHelp)
            if changes.reviewable(observedCount: row.observedPaths.count) {
                reviewChip
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .cardSurface(radius: 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var headline: some View {
        if changes.compared {
            Text("이번 실행에서 파일 ")
                + Text("\(changes.fileCount)").fontWeight(.semibold).foregroundStyle(Theme.ink)
                + Text("개가 바뀌었습니다")
        } else {
            Text("관찰된 편집 ")
                + Text("\(row.observedPaths.count)").fontWeight(.semibold).foregroundStyle(Theme.ink)
                + Text("건")
        }
    }

    /// 파일 이름 (최대 3개) · 외 n개 · 줄 수. 좁으면 파일 이름부터 줄인다 ("외 n개" · 줄 수는 남긴다).
    /// 줄 수를 모르면(합산할 파일이 없거나 HEAD 가 바뀌었거나 확인하지 못함) 적지 않는다 — 까닭은 셋째 줄, 무엇으로 센 것인지는 도움말.
    private var detail: some View {
        let paths = changes.compared ? changes.files.map(\.path) : row.observedPaths
        let summary = RunFileChanges.nameSummary(paths, total: changes.compared ? changes.fileCount : nil)
        return HStack(spacing: 0) {
            Text(summary.names.joined(separator: ", "))
                .truncationMode(.tail)
            Group {
                if summary.more > 0 { Text(" 외 \(summary.more)개") }
                if changes.compared, lineCountsKnown {
                    Text("   ")
                    lineCounts
                }
            }
            .fixedSize()
            .layoutPriority(1)
        }
    }

    /// 셋째 줄: 줄 수에서 뺀 것 · 기준이 달라진 것 · 확인하지 못한 것 (비교한 실행), 비교하지 못한 이유 (관찰된 편집) — 짧은 말로.
    /// 없으면 nil.
    private var noteLine: String? {
        guard changes.compared else {
            return "\(changes.unavailable?.koreanName ?? "이유 미확인") — 기록에 남은 편집만 셈"
                + (changes.processUnconfirmed ? " · " + RunFileChanges.processCardNote : "")
        }
        return changes.cardNotes.isEmpty ? nil : changes.cardNotes.joined(separator: " · ")
    }

    private var lineCountsKnown: Bool {
        !changes.linesSuppressed && changes.added != nil && changes.removed != nil
    }

    /// `+a −r` (둘 다 0 이면 `±0`). 모르면 그리지 않는다 (`lineCountsKnown` — 0 을 쓰지 않는다).
    @ViewBuilder
    private var lineCounts: some View {
        if let added = changes.added, let removed = changes.removed {
            if added == 0 && removed == 0 {
                Text("±0")
            } else {
                HStack(spacing: 4) {
                    if added > 0 { Text("+\(added)").foregroundStyle(Theme.emeraldText) }
                    if removed > 0 { Text("−\(removed)").foregroundStyle(Theme.danger) }
                }
            }
        }
    }

    /// 무엇으로 센 수인지 — 실행 전후 비교인지, 비교하지 못해 기록에 남은 편집만 센 것인지 — 와 주석의 긴 문장.
    private var basisHelp: String {
        guard changes.compared else {
            return "실행 전후 비교를 하지 못해(\(changes.unavailable?.koreanName ?? "이유 미확인")) 이 실행의 기록에 남은 "
                + "편집(편집 도구 · 파일 변경)의 경로만 셉니다. 줄 수는 쓰지 않습니다."
                + (changes.processUnconfirmed ? "\n" + RunFileChanges.processNote + "." : "")
        }
        var text = "실행 전후 비교: 실행 직전과 끝난 직후에 그 실행의 폴더(프로젝트 폴더 또는 독립 작업 폴더) 변경 상태(git status · "
            + "마지막 커밋 대비 줄 수 · 파일 크기와 수정 시각)를 찍어 비교했습니다. 줄 수는 실행 전에 깨끗했던 파일만, HEAD 가 "
            + "그대로임을 확인했을 때만 더합니다."
        if !changes.notes.isEmpty { text += "\n" + changes.notes.map { $0 + "." }.joined(separator: "\n") }
        return text
    }

    private var reviewChip: some View {
        Button {
            inspectorTab = .changes
            inspectorVisible = true
            // 인스펙터는 포커스 칸을 따라간다 — 이 칸으로 포커스를 옮긴 뒤 연다.
            let threadID = pane.threadID
            Task {
                await model.selectThread(threadID)
                model.requestChangesReview(threadID: threadID, changes: changes)
            }
        } label: {
            HStack(spacing: 5) {
                Text("변경사항 검토")
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 11))
        .help("오른쪽 패널을 변경사항 탭으로 열고 이 실행에서 바뀐 파일을 목록 위로 올립니다")
    }
}

// MARK: - 턴 바닥글

/// 턴 끝의 한 줄 — 걸린 시간 · 새 토큰(입력 + 출력, 캐시 제외) · API 환산 비용 (· 바뀐 파일 없음). 캐시 · 비용 출처 · 청구액이
/// 아니라는 설명은 도움말과 눌러서 펼치는 자세한 내역에 (글은 `TurnFooterText`). 펼치면 그 실행의 CLI 진단(실행 명령줄 · MCP 준비
/// · stderr — 대화에는 보이지 않는 행)도 보인다. 평가(좋았던 답 · 아쉬운 답 · 막힌 일을 풀어 준 턴)는 이 줄에 포인터를 올리거나
/// 키보드로 옮겨 왔을 때만 보인다 — 이미 매긴 평가는 늘 보인다. 모르는 값은 모른다고 쓴다.
struct TurnFooterRow: View {
    @Environment(AppModel.self) private var model
    /// 이 행이 놓인 칸의 대화 상태 (분할 화면의 칸마다 다르다).
    @Environment(ThreadPaneModel.self) private var pane
    let runID: String
    /// 실행 전후를 비교했고 바뀐 파일이 없다 (단서 없이) — 따로 카드를 두지 않고 이 줄 끝에 적는다.
    var filesUnchanged = false
    @State private var expanded = false
    @State private var hovering = false
    @FocusState private var focusedRating: RatingControl?

    private enum RatingControl: Hashable { case up, down, rescue }

    private var usage: UsageRecord? { pane.usageByRun[runID] }
    private var run: Run? { pane.runsByID[runID] }
    private var rating: Rating? { pane.ratingsByRun[runID] }
    /// 평가 단추를 다 보일 때 (포인터 · 키보드 포커스).
    private var revealsRating: Bool { hovering || focusedRating != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 11) {
                Button {
                    expanded.toggle()
                } label: {
                    line
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate2)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(TurnFooterText.help(usage, filesUnchanged: filesUnchanged))
                Spacer(minLength: 8)
                if run != nil { ratingControls }
            }
            if expanded { details }
        }
        .padding(.leading, Theme.Metric.agentIndent)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// `1분 29초 · 새 토큰 1.2만 · API 환산 $0.61` — 사용량이 없으면 걸린 시간만 (끝나지 않은 실행이면 그렇다고).
    @ViewBuilder
    private var line: some View {
        HStack(spacing: 0) {
            if let usage {
                Text(TurnFooterText.head(usage) + " · ")
                if let cost = TurnFooterText.cost(usage) {
                    Text(cost)
                } else {
                    Text("금액 미확인").foregroundStyle(Theme.amberText).fontWeight(.semibold)
                }
                if !usage.confirmed {
                    Text("  ⚠ 사용량 미확정").foregroundStyle(Theme.amberText)
                }
            } else if run?.state.isTerminal == true {
                if let ms = run?.durationMs { Text(DisplayFormat.duration(ms: ms)) }
            } else {
                Text("사용량 미확정 — 종료가 확인되지 않은 실행").foregroundStyle(Theme.amberText)
            }
            if filesUnchanged {
                Text(usage == nil && run?.durationMs == nil ? "바뀐 파일 없음" : " · 바뀐 파일 없음")
            }
        }
    }

    /// 이 실행이 띄운 하위 작업의 몫. 하위가 없으면 nil — 펼쳤을 때만 부른다.
    private func subAgentShare(_ usage: UsageRecord) -> TokenShare? {
        let infos = pane.subAgentInfos.filter { pane.subAgentRunIDs[$0.key] == runID }.map(\.value)
        guard !infos.isEmpty else { return nil }
        return TokenShare.make(runUsage: usage, infos: infos)
    }

    /// 펼친 내역: 토큰 · 캐시 · 하위의 몫 · 비용 출처 · 청구가 아니라는 말 · 종료 사유 · CLI 진단.
    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let usage {
                Text(TurnFooterText.newTokensBreakdown(usage))
                if let cache = TurnFooterText.cacheBreakdown(usage) { Text(cache) }
                if usage.reasoningTokens > 0 {
                    Text("추론 \(DisplayFormat.exactTokens(usage.reasoningTokens)) — 출력에 포함, 중복 합산 안 함")
                }
                // 하위 작업이 있던 실행 — 메인 · 하위가 처리한 몫 (처리 토큰은 캐시 포함, 하위끼리 견주는 값).
                if let shareLine = subAgentShare(usage)?.footerLine() {
                    Text(shareLine).help(TokenShare.help)
                }
                Text("비용 출처: \(usage.costSource.koreanName)"
                     + (usage.priceCatalogVersion.map { " · 가격표 \($0)" } ?? ""))
                Text(TurnFooterText.billingNote)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("사용량 기록 없음")
            }
            if filesUnchanged { Text("실행 전후 비교: 이번 실행에서 바뀐 파일 없음") }
            if let reason = run?.terminalReason { Text("종료 사유: \(reason)") }
            if let note = run?.childProcessNote { Text(note).foregroundStyle(Theme.amberText) }
            // 이 실행의 CLI 진단 — 펼쳤을 때만 훑는다 (바닥글마다 대화 전체를 훑지 않게).
            let diagnostics = pane.mainEvents.filter { $0.runID == runID && $0.isDiagnostic }
            if !diagnostics.isEmpty {
                Text("CLI 진단 \(diagnostics.count)건")
                    .padding(.top, 4)
                ExpandableMono(text: diagnostics.map(\.text).joined(separator: "\n"), previewLines: 4, color: Theme.slate2)
            }
        }
        .font(Theme.ui(.caption))
        .foregroundStyle(Theme.slate2)
        .textSelection(.enabled)
    }

    private var ratingControls: some View {
        HStack(spacing: 9) {
            ratingButton("hand.thumbsup", on: rating?.satisfaction == .up, onColor: Theme.emerald,
                         help: "좋았던 답으로 표시 — 에이전트 기록에 셉니다 (다시 누르면 바꿀 수 있음)", control: .up) {
                setSatisfaction(.up)
            }
            ratingButton("hand.thumbsdown", on: rating?.satisfaction == .down, onColor: Theme.danger,
                         help: "아쉬운 답으로 표시 — 에이전트 기록에 셉니다", control: .down) {
                setSatisfaction(.down)
            }
            // "구원" — 다른 에이전트가 막힌 일을 이 턴이 풀었다 (에이전트 전적의 "구원" 횟수 · 이번 주 구원왕).
            let rescued = rating?.rescue == true
            Button {
                guard let run else { return }
                Task { await model.toggleRescue(runID: runID, provider: run.provider) }
            } label: {
                Image(systemName: rescued ? "lifepreserver.fill" : "lifepreserver")
                    .font(.system(size: 10.5))
                    .foregroundStyle(rescued ? Theme.claude : Theme.control)
            }
            .buttonStyle(.plain)
            .focused($focusedRating, equals: .rescue)
            .opacity(rescued || revealsRating ? 1 : 0)
            .help(rescued ? "막힌 일 해결로 표시함 — 다시 누르면 지웁니다"
                          : "막힌 일 해결로 표시 — 다른 에이전트가 막힌 일을 이 턴이 풀었을 때 (에이전트 기록에 셉니다)")
            .accessibilityLabel(rescued ? "막힌 일 해결로 표시됨" : "막힌 일 해결로 표시")
        }
    }

    /// 매기지 않은 단추는 포인터를 올리거나 키보드로 옮겨 왔을 때만 보인다 (자리는 그대로 — 올려도 줄이 흔들리지 않게).
    /// 보이지 않아도 손쉬운 사용에서는 찾을 수 있다.
    private func ratingButton(_ symbol: String, on: Bool, onColor: Color, help: String, control: RatingControl,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: on ? symbol + ".fill" : symbol)
                .font(.system(size: 10.5))
                .foregroundStyle(on ? onColor : Theme.control)
        }
        .buttonStyle(.plain)
        .focused($focusedRating, equals: control)
        .opacity(on || revealsRating ? 1 : 0)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func setSatisfaction(_ value: Satisfaction) {
        guard let run else { return }
        Task { await model.setRating(runID: runID, provider: run.provider, satisfaction: value) }
    }
}

// MARK: - 인계 릴레이

/// 인계는 팝업이 아니라 스트림에 남는 한 줄. 여기서부터 누구였는지 나중에 읽을 수 있어야 한다.
struct RelayLine: View {
    @Environment(AppModel.self) private var model
    /// 이 행이 놓인 칸의 대화 상태 (분할 화면의 칸마다 다르다).
    @Environment(ThreadPaneModel.self) private var pane
    let relay: RelayRow
    @State private var expanded = false

    private var handoff: Handoff? {
        // 스레드를 연 뒤 상태가 바뀌었을 수 있어 최신 기록을 우선한다.
        guard let id = relay.handoff?.id else { return nil }
        return pane.handoffs.first { $0.id == id } ?? relay.handoff
    }

    private var packet: HandoffPacket? {
        guard let json = handoff?.draftJSON, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HandoffPacket.self, from: data)
    }

    private var state: HandoffDeliveryState? {
        if let handoff { return handoff.deliveryState }
        guard let raw = JSONUtil.object(relay.received?.payloadJSON ?? "")?["state"] as? String else { return nil }
        return HandoffDeliveryState(rawValue: raw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Rectangle().fill(ruleColor).frame(height: 1)
                    HStack(spacing: 8) {
                        Text(RelayText.title(number: relay.number))
                            .font(Theme.ui(.caption, .semibold))
                            .foregroundStyle(state == .unknown ? Theme.amberText : Theme.slate2)
                        if let from = handoff?.fromProvider ?? relay.event.provider {
                            BrandMark(provider: from, size: 12)
                            Text(partyName(from, accountID: handoff?.fromAccountID, label: packet?.fromAccountLabel))
                                .font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
                        }
                        Text("▶").font(Theme.ui(.caption)).foregroundStyle(Theme.slate3)
                        if let to = handoff?.toProvider {
                            BrandMark(provider: to, size: 12)
                            Text(partyName(to, accountID: handoff?.toAccountID, label: packet?.toAccountLabel))
                                .font(Theme.ui(.caption, .semibold)).foregroundStyle(Theme.ink2)
                        }
                        Text(statusText)
                            .font(Theme.mono(.caption))
                            .foregroundStyle(stateColor)
                            .lineLimit(1)
                    }
                    .layoutPriority(1)
                    Rectangle().fill(ruleColor).frame(height: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "접기" : "에이전트가 받은 문서 보기")
            .accessibilityLabel("인계 \(relay.number)번, \(statusText)")

            if expanded { details }
        }
        .streamSelectable(copyText, kind: .block)
    }

    /// 스트림 선택의 복사 글: 인계 줄 (펼쳤으면 받은 문서까지).
    private var copyText: String {
        var parts = [RelayText.title(number: relay.number)]
        let from = (handoff?.fromProvider ?? relay.event.provider)
            .map { partyName($0, accountID: handoff?.fromAccountID, label: packet?.fromAccountLabel) }
        let to = handoff.map { partyName($0.toProvider, accountID: $0.toAccountID, label: packet?.toAccountLabel) }
        if from != nil || to != nil { parts.append("\(from ?? "?") ▶ \(to ?? "?")") }
        parts.append(statusText)
        let line = parts.joined(separator: " · ")
        return expanded ? line + "\n" + (handoff?.finalText ?? relay.event.text) : line
    }

    private func partyName(_ provider: AgentProvider, accountID: String?, label: String?) -> String {
        guard provider == .codex else { return provider.displayName }
        let sameProvider = handoff.map { $0.fromProvider == $0.toProvider } ?? false
        guard model.accounts.hasMultiple || sameProvider else { return provider.displayName }
        let resolved = label ?? accountID.flatMap { $0.isEmpty ? nil : model.accounts.accountOrDefault($0).label }
        return HandoffPacket.partyName(provider, resolved)
    }

    /// 이 인계를 전한 실행이 아직 돈다 — 받는 쪽이 인계 문서를 받아 일하는 중 (행의 상태는 그 실행이 끝나야 정해진다).
    private var receiverWorking: Bool {
        guard let runID = handoff?.deliveryRunID else { return false }
        return model.liveSession(runID: runID) != nil || pane.runsByID[runID]?.state.isActive == true
    }

    private var statusText: String {
        var files: Int = 0
        if let changed = packet?.changedFiles {
            var all: Set<String> = Set(changed.staged)
            all.formUnion(changed.unstaged)
            all.formUnion(changed.untracked)
            files = all.count
        }
        var tokens: Int?
        if let text = handoff?.finalText, !text.isEmpty { tokens = CostCalculator.roughTokenEstimate(text) }
        var sameProvider: Bool = false
        if let handoff { sameProvider = handoff.fromProvider == handoff.toProvider }
        return RelayText.status(state: state, receiverWorking: receiverWorking, sameProvider: sameProvider,
                                files: files, tokens: tokens)
    }

    private var stateColor: Color {
        switch state {
        case .delivered: return Theme.emeraldText
        case .unknown: return Theme.amberText
        case .failed: return Theme.danger
        default: return Theme.slate2
        }
    }

    private var ruleColor: Color {
        switch state {
        case .unknown: return Theme.amberRule
        case .failed: return Theme.dangerRule
        default: return Theme.hair
        }
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let note = handoff?.note, !note.isEmpty {
                Text(note)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(state == .failed ? Theme.danger : Theme.amberText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ExpandableMono(text: handoff?.finalText ?? relay.event.text, previewLines: 14, color: Theme.slate)
            if let handoff, handoff.deliveryState == .delivered {
                HStack(spacing: 8) {
                    SectionLabel("인계 평가")
                    ForEach([HandoffQuality.seamless, .needsInfo, .failed], id: \.self) { quality in
                        let selected = pane.ratingsByHandoff[handoff.id]?.handoffQuality == quality
                        Button(quality.koreanName) {
                            Task {
                                await model.setHandoffQuality(handoffID: handoff.id, provider: handoff.fromProvider,
                                                              quality: quality)
                            }
                        }
                        .buttonStyle(ChipButtonStyle(height: 22, horizontalPadding: 9, radius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(selected ? Theme.ink : Color.clear, lineWidth: 1))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
        .leadingRule(Theme.hair, gap: 15)
        .padding(.leading, Theme.Metric.agentIndent)
    }
}

// MARK: - 오류 · 한도 · 안내

struct AlertRow: View {
    @Environment(AppModel.self) private var model
    /// 이 행이 놓인 칸의 대화 상태 (분할 화면의 칸마다 다르다).
    @Environment(ThreadPaneModel.self) private var pane
    /// 받을 에이전트를 설정에서 뺐을 때의 [인계 설정 열기].
    @Environment(\.openSettings) private var openSettings
    let event: ThreadEvent

    private var run: Run? { event.runID.flatMap { pane.runsByID[$0] } }

    /// 한도 도달 안내 — 이어 가기 제안의 숨김("마지막 메인 이벤트가 한도 안내")과 같은 판정 (`ThreadEvent.isLimitNotice`).
    private var isRateLimit: Bool { event.isLimitNotice(run: run) }

    var body: some View {
        Group {
            if isRateLimit { rateLimit } else { error }
        }
        .streamSelectable(copyText, kind: .block)
        .padding(.leading, event.runID == nil ? 0 : Theme.Metric.agentIndent)
    }

    /// 스트림 선택의 복사 글: 제목 줄 + 원문.
    private var copyText: String {
        let provider = event.provider ?? run?.provider ?? .claude
        let title = isRateLimit ? "\(provider.displayName) 사용 한도 도달"
            : "오류 " + (event.title.isEmpty ? "실행 중 오류" : event.title)
        return event.text.isEmpty ? title : title + "\n" + event.text
    }

    private var error: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Text("오류").font(Theme.mono(.caption, .bold)).tracking(0.6).foregroundStyle(Theme.danger)
                Text(event.title.isEmpty ? "실행 중 오류" : event.title)
                    .font(Theme.ui(.callout))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Fmt.time.string(from: event.createdAt)).font(Theme.meta).foregroundStyle(Theme.slate2)
            }
            ExpandableMono(text: event.text, previewLines: 6, color: Theme.ink2)
            // 로그인 문제로 끝난 실행 — 할 일 · 로그인 명령 복사 · [시작 점검 열기] (점검표와 같은 안내, `LoginTroubleGuide`).
            // API 키로 보낸 실행의 크레딧 소진 · 맞지 않는 키 — 로그인 안내 대신 그 할 일 (`ClaudeAPIKey.errorNote`).
            if let note = model.claudeAPIErrorNote(for: event) {
                Text(note)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let guide = model.loginTroubleGuide(for: event) {
                LoginTroubleNote(guide: guide)
            }
            if let usage = event.runID.flatMap({ pane.usageByRun[$0] }), !usage.confirmed {
                Text("이 턴의 사용량은 미확정으로 기록했습니다.")
                    .font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
            }
        }
        .leadingRule(Theme.danger, width: 2, gap: 15)
    }

    private var rateLimit: some View {
        let provider = event.provider ?? run?.provider ?? .claude
        // Antigravity 는 그 실행의 모델이 쓰는 묶음(Gemini · Claude · GPT)의 창만 (`scoped` — 다른 제공자는 그대로).
        let snapshot = model.limits.snapshot(AgentScope(provider: provider,
                                                        accountID: run?.codexAccountID ?? ""))
            .scoped(toAntigravityModel: run?.model)
        // 다 찬 계정 전체 창이 풀리는 시각 — 인계 카드 머리와 같은 규칙 · 같은 형식 (`HandoffCardText.resetPhrase`):
        // 한도에 닿은 뒤 풀렸다는 근거(창이 다시 시작함 · 그 뒤 같은 계정의 실행이 성공함)가 있을 때만 "한도 풀림" — `HandoffCardText.released`.
        let reset = snapshot.capResetsAt()
        // 풀림의 근거 하나: 이 줄 뒤에 같은 계정의 실행이 이 대화에서 성공했다 (`HandoffCardText.released`).
        let accountID = provider == .codex ? (run?.codexAccountID ?? "") : ""
        let laterSuccess = pane.runsByID.values.contains {
            $0.provider == provider && ($0.codexAccountID ?? "") == accountID && $0.state == .completed
                && $0.startedAt > event.createdAt
        }
        // 앱이 시각을 모르는데 CLI 문구가 초기화 시각을 말하면 "미확인" 이라 하지 않고 원문을 가리킨다 (같은 줄에서 둘이 다투지 않게).
        let resetPhrase = HandoffCardText.resetPhrase(
            HandoffCardText.resetPhrase(current: reset, fixed: nil,
                                        releasedSince: HandoffCardText.released(snapshot, since: event.createdAt, laterSuccess: laterSuccess)),
            rawText: event.text)
        // 지금도 한도에 닿아 있는 줄만 인계 단추를 단다 — 앱 안내를 건너뛴 메인 흐름의 마지막 이벤트가 이 줄일 때
        // (이어 가기 제안 줄이 숨는 것과 같은 판정 `activeLimitNoticeID` — 둘 중 하나만 인계를 권한다). 하위 에이전트의 오류는
        // 메인 흐름이 아니다. 그 뒤에 다른 에이전트가 일했거나 같은 에이전트가 다시 일한 지난 한도 줄은 단추도, 대상 · 한도 새로 읽기도 없다.
        // 인계 카드(준비 · 전달 중 포함)가 있거나 인계할 수 없는 대화(내부 대화 · 끝나지 않은 자동 작업)면 두지 않는다 — 카드가 대화 끝에 있다.
        let isActive = model.activeLimitNoticeID(threadID: event.threadID) == event.id
        let thread = model.paneThread(event.threadID)
        let hasCard = model.hasHandoffActivity(threadID: event.threadID)
        let offersHandoff = isActive && !hasCard && (thread.map { model.handoffEntryBlock(for: $0) == nil } ?? false)
        // 받는 쪽은 이어 가기 제안과 같은 선택 — 이어 갈 대상 순서에서 CLI · 로그인 · 한도 여유가 30분 안에 확인된 첫 대상, 없으면
        // 받을 수 없다고 확인되지 않은 대비책(반대편 — 이 대화의 Codex 계정). 그것도 없으면 권하지 않는다 (설치 · 로그인 안 된 에이전트를
        // 권하지 않는다). 지금의 사실로 정하므로 단추가 있는 줄에만 쓴다.
        let source = HandoffSource.Agent(provider: provider, codexAccountID: provider == .codex ? run?.codexAccountID : nil)
        let choice = offersHandoff ? model.limitHandoffTarget(after: source, thread: thread) : nil
        let target = choice?.agent
        let targetName = target.map { model.handoffPartyName($0) }
        // 같은 Claude 세션을 API 크레딧으로 이어 가기 (`ClaudeAPIContinue`) — 인계 단추와 같은 줄에만, 카드가 있으면 카드가 보인다.
        let apiOffer: ClaudeAPIContinue.Offer = isActive && !hasCard
            ? model.claudeAPIContinueOffer(threadID: event.threadID, provider: provider) : .none
        // 받는 쪽이 같은 Codex 의 다른 계정이면 인계하지 않고 계정만 바꿔 같은 세션을 이어 간다 (`CodexAccountSwitch`).
        let switchesAccount = target.map { model.isCodexAccountSwitch(from: source, to: $0) } ?? false
        let advice = ClaudeAPIContinue.limitAdvice(
            handoff: limitAdvice(choice: choice, targetName: targetName, isActive: isActive, hasCard: hasCard,
                                 switchesAccount: switchesAccount),
            handoffTargeted: target != nil, offer: apiOffer)
        let busy = model.runner.isBusy(threadID: event.threadID) || model.isSending(threadID: event.threadID)
        let resetKnown = reset != nil
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                BrandMark(provider: provider, size: 13)
                Text("\(provider.displayName) 사용 한도 도달")
                    .font(Theme.ui(.callout, .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                // 시각을 알면 고정폭 숫자 · 황색, 모르면 보통 글꼴 · 회색 (원문과 다투지 않게).
                Text(resetPhrase)
                    .font(resetKnown ? Theme.digits(.caption) : Theme.ui(.caption))
                    .foregroundStyle(resetKnown ? Theme.amberText : Theme.slate2)
            }
            // "자동으로 옮기지는 않습니다" 는 뺐다 — 자동 인계가 켜져 있으면 바로 아래 카드가 카운트다운한다 (설계 C4 의 한 줄을 C1 에서).
            if let advice {
                Text(advice)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !event.text.isEmpty {
                Text(event.text)
                    .font(Theme.mono(.caption))
                    .foregroundStyle(Theme.slate2)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            if choice != nil || apiOffer == .available {
                HStack(spacing: 8) {
                    if apiOffer == .available {
                        Button(ClaudeAPIContinue.title) {
                            Task { await model.continueWithClaudeAPI(threadID: event.threadID) }
                        }
                        .buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 12))
                        .disabled(busy)
                        .help(ClaudeAPIContinue.limitHelp)
                    }
                    if let choice {
                        handoffControl(choice: choice, target: target, targetName: targetName, provider: provider, reset: reset,
                                       busy: busy, apiOffered: apiOffer == .available, switchesAccount: switchesAccount)
                            // 앞 순서 대상의 로그인 · 한도가 오래돼 정하지 못했으면 새로 읽는다 (제안 줄과 같은 길 — 같은 대상은 5분에 한 번).
                            .task(id: choice.stale) { model.refreshStaleContinueTargets(choice.stale) }
                    }
                }
                .padding(.top, 2)
            }
            if apiOffer == .needsKey {
                // 키가 없다 — 설정 > 에이전트 > Claude Code (모델 칩의 "API 키 넣기…" 와 같은 길). 앱은 플랜을 모른다.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ClaudeAPIContinue.needsKeyText)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(ClaudeAPIContinue.addKeyTitle) {
                        SettingsTab.select(.agents)
                        openSettings()
                    }
                    .buttonStyle(.link)
                    .font(Theme.ui(.caption))
                    .help(ClaudeAPIContinue.addKeyHelp)
                }
            }
        }
        .leadingRule(Theme.amber, width: 2, gap: 15)
    }

    /// 인계 단추 — 받는 쪽이 있으면 [<받는 쪽> 에게 이어 맡기기], 없으면 그 까닭에 맞는 곳 (`ContinueSuggestion.LimitLineEmpty`).
    /// API 크레딧으로 이어 갈 수 있으면(`apiOffered`) 받는 쪽이 없는 까닭의 단추는 접는다 (권유 문장도 API 쪽만 말한다).
    /// 받는 쪽이 같은 Codex 의 다른 계정이면(`switchesAccount`) [<계정> 에서 이어 가기] — 계정을 바꾸고 같은 세션에 이어 가기 메시지를 보낸다.
    @ViewBuilder
    private func handoffControl(choice: AppModel.LimitHandoffTarget, target: HandoffSource.Agent?, targetName: String?,
                                provider: AgentProvider, reset: Date?, busy: Bool, apiOffered: Bool,
                                switchesAccount: Bool) -> some View {
        if let target, let targetName, switchesAccount {
            Button(CodexAccountSwitch.title(name: targetName)) {
                Task { await model.continueWithCodexAccount(threadID: event.threadID,
                                                            accountID: target.codexAccountID ?? CodexAccount.defaultID) }
            }
            .buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 12))
            .disabled(busy)
            .help(CodexAccountSwitch.limitHelp(name: targetName))
        } else if let target, let targetName {
            Button(ContinueChoice.continueTitle(name: targetName)) {
                let scope = AgentScope(provider: provider, accountID: run?.codexAccountID ?? "")
                Task { await model.prepareHandoff(to: target.provider, toAccountID: target.codexAccountID, threadID: event.threadID,
                                                  origin: .limitReached(scope: scope, resetsAt: reset)) }
            }
            .buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 12))
            .disabled(busy)
            .help(ContinueChoice.continueSubtitle)
        } else if apiOffered {
            // 단추는 없지만 `.task`(오래된 대상 새로 읽기)가 붙을 자리는 둔다 (EmptyView 에는 붙지 않는다).
            Color.clear.frame(width: 0, height: 0)
        } else {
            // 이어 받을 에이전트가 없다 — 그 까닭에 맞는 곳으로 (hand-4 · set-n4): 설정에서 뺐으면 설정 > 인계,
            // 쓸 수 없으면 설치 · 로그인 안내가 있는 시작 점검. 받는 쪽도 한도면 기다릴 수밖에 없어 단추가 없다.
            switch choice.empty ?? .unavailable {
            case .excluded:
                Button("인계 설정 열기") {
                    SettingsTab.select(.handoff)
                    openSettings()
                }
                .buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 12))
                .help("설정 > 인계의 이어 받을 순서에서 받을 에이전트를 고릅니다")
            case .capped:
                Color.clear.frame(width: 0, height: 0)
            case .unavailable:
                Button("시작 점검 열기") { model.showFirstRunSheet = true }
                    .buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 12))
                    .help("에이전트의 설치 · 로그인 상태와 할 일을 봅니다 (도움말 > 시작 점검…)")
            }
        }
    }

    /// 한도 줄의 권유 문장 — 받는 쪽이 확인됐으면 단정하고, 확인하지 못한 대비책이면 그 사실을 말하고, 이어 받을 에이전트가 없으면
    /// 할 일을 말한다. 카드가 있으면 카드를 가리킨다 (카드 머리가 같은 사실을 되풀이하지 않게). 지난 줄에는 없다.
    /// "맥락 그대로" 가 아니라 "정리한 인계 문서로" — 넘기는 것은 대화 전체가 아니라 앱이 정리한 문서다.
    private func limitAdvice(choice: AppModel.LimitHandoffTarget?, targetName: String?, isActive: Bool, hasCard: Bool,
                             switchesAccount: Bool) -> String? {
        guard let choice else { return isActive && hasCard ? "아래 인계 카드에서 이어 갑니다." : nil }
        // 받는 쪽이 없으면 그 까닭대로 — 설정에서 뺐다 · 받는 쪽도 한도 · 쓸 수 없음 (`ContinueSuggestion.limitLineEmpty`, hand-4).
        guard let targetName else { return ContinueSuggestion.limitLineEmptyText(choice.empty ?? .unavailable) }
        if switchesAccount {
            return CodexAccountSwitch.limitAdvice(name: targetName, confirmed: choice.confirmed, loginUnknown: choice.loginUnknown)
        }
        if !choice.confirmed {
            return "\(targetName) 에게 정리한 인계 문서로 이어 맡겨 볼 수 있습니다 (받는 쪽 상태 미확인)."
        }
        if choice.loginUnknown {
            return "\(targetName) 에게 정리한 인계 문서로 이어 맡길 수 있습니다 (로그인 미확인)."
        }
        return "\(targetName) 에게 정리한 인계 문서로 이어 맡길 수 있습니다."
    }
}

/// 안내 한 줄. CLI 상태 중 사람이 할 일(`ThreadEvent.isAttention` — 훅 실패 · MCP 인증 필요)은 제목을 황색으로.
struct NoticeRow: View {
    let event: ThreadEvent

    var body: some View {
        let attention = event.isAttention
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(attention ? "!" : "·").font(Theme.mono(.caption, .bold)).foregroundStyle(attention ? Theme.amberText : Theme.slate3)
            if !event.title.isEmpty {
                Text(event.title).font(Theme.ui(.caption, .medium)).foregroundStyle(attention ? Theme.amberText : Theme.slate)
            }
            Text(event.text)
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate2)
                .lineLimit(4)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Text(Fmt.time.string(from: event.createdAt)).font(Theme.meta).foregroundStyle(Theme.slate2)
        }
        .streamSelectable([event.title, event.text].filter { !$0.isEmpty }.joined(separator: " "), kind: .block)
        .padding(.leading, event.runID == nil ? 0 : Theme.Metric.agentIndent)
    }
}
