import SwiftUI

/// 오른쪽 420pt 패널. 첫 줄은 글자 탭 다섯 개(`InspectorTabSwitcher`), 그 아래가 탭 내용.
/// 터미널 · 파일 · Pull Request · 변경사항은 선택된 대화가 일하는 폴더(프로젝트 폴더 또는 독립 작업 폴더)와 브랜치를, 에이전트는 선택된 대화의 실행이
/// 띄운 하위 작업을 기준으로 한다.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @Binding var tab: InspectorTab

    var body: some View {
        VStack(spacing: 0) {
            InspectorTabBar(tab: $tab)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairSoft).frame(height: 1) }
            Group {
                if tab == .agents {
                    // 폴더가 아니라 대화를 본다 — 폴더 확인보다 먼저.
                    AgentsPane()
                } else if model.workspace.projectURL == nil {
                    QuietEmptyState(systemImage: "folder", title: "열린 프로젝트 폴더가 없습니다",
                                    detail: "왼쪽에서 프로젝트 폴더를 열고 대화를 고르세요.")
                        .frame(maxHeight: .infinity)
                } else {
                    switch tab {
                    case .terminal: TerminalPane()
                    case .files: FilesPane()
                    case .pullRequest: PullRequestPane()
                    case .changes: ChangesPane { tab = $0 }
                    case .agents: AgentsPane()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.panel)
    }
}

/// 첫 줄의 글자 탭과 탭 이름 옆 점. 점의 근거(하위 작업의 진행은 초당 여러 번 바뀐다)를 이 뷰에서만 읽어,
/// 진행이 바뀔 때 탭 내용(변경사항 탭 등)까지 다시 그리지 않는다.
private struct InspectorTabBar: View {
    @Environment(AppModel.self) private var model
    @Binding var tab: InspectorTab

    /// 탭 이름 옆 점과 그 뜻 (도움말 · 접근성).
    private var badges: [InspectorTab: InspectorTabSwitcher.Badge] {
        var out: [InspectorTab: InspectorTabSwitcher.Badge] = [:]
        if model.hasUnreviewedChanges(threadID: model.selectedThreadID) {
            out[.changes] = .init(text: "검토하지 않은 실행 변경이 있습니다", color: Theme.claude)
        }
        let running = model.selectedThreadID.flatMap { model.runner.session(threadID: $0) }?.unfinishedSubAgentCount ?? 0
        if running > 0 {
            // 에메랄드는 이 기능에서 "완료" 다 (카드 · 칩의 점) — 도는 중은 잉크.
            out[.agents] = .init(text: "하위 작업 \(running)개 실행 중", color: Theme.ink)
        }
        return out
    }

    var body: some View {
        InspectorTabSwitcher(tab: $tab, badges: badges)
    }
}

/// 인스펙터 탭 안의 38pt 머리줄.
struct InspectorHeader<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            leading()
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 38)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
    }
}

/// 아직 앱에서 하지 않는 동작을 숨기지 않고 알린다.
struct NotYetNote: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "lock")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.slate)
                Text(title)
                    .font(Theme.ui(.caption, .semibold))
                    .foregroundStyle(Theme.ink)
            }
            Text(detail)
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
        .leadingRule(Theme.hair, width: 2, gap: 11)
    }
}
