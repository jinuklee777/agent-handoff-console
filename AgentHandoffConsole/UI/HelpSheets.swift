import SwiftUI

// 도움말 메뉴의 시트 둘 — 키보드 단축키(`MenuShortcut.helpSections` 에서 만든다)와 이 앱 소개(인계가 무엇인지 짧게).
// 여는 곳은 `AgentHandoffConsoleApp` 의 도움말 메뉴, 붙는 곳은 `ContentView` (`AppModel.showKeyboardShortcuts` · `showAppGuide`).

/// 도움말 > 키보드 단축키. 표는 메뉴가 거는 단축키 표(`MenuShortcut`) 그대로라 메뉴와 어긋나지 않는다.
struct KeyboardShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(MenuShortcut.keyboardShortcutsTitle)
                    .font(Theme.ui(.body, .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(MenuShortcut.helpSections) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            SectionLabel(section.title)
                                .padding(.bottom, 2)
                            ForEach(section.items, id: \.self) { shortcut in
                                HStack(spacing: 10) {
                                    Text(shortcut.title)
                                        .font(Theme.ui(.callout))
                                        .foregroundStyle(Theme.ink2)
                                    Spacer(minLength: 12)
                                    // 키 표시는 진한 글자 — `slate` 는 `well` 위에서 4.3:1 로 AA 에 못 미쳤다 (copy-4).
                                    Text(shortcut.symbol)
                                        .font(Theme.mono(.caption))
                                        .foregroundStyle(Theme.ink2)
                                        .padding(.horizontal, 6)
                                        .frame(height: 20)
                                        .background(Theme.well, in: RoundedRectangle(cornerRadius: 5))
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    Text("diff · 찾기 막대 · 추론 강도의 키는 그 자리에 키보드 포커스가 있을 때만 받습니다.")
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
            }
            Divider()
            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .frame(width: 460, height: 560)
        .background(Theme.paper)
    }
}

/// 도움말 > 이 앱 소개 (⌘?). 처음 쓰는 사람이 "인계" 가 무엇이고 어디서 시작하는지 알 수 있게 — 짧게.
struct AppGuideSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private struct Item: Identifiable {
        let title: String
        let body: String
        var id: String { title }
    }

    private let items: [Item] = [
        Item(title: "이 앱은",
             body: "Claude Code · Codex · Antigravity 같은 코딩 에이전트를 한 창에서 씁니다. 에이전트는 이 Mac 에 설치된 CLI 그대로 돌고, "
                + "대화 기록은 이 Mac 에만 저장됩니다."),
        Item(title: "인계",
             body: "한 에이전트가 하던 일을 다른 에이전트에게 넘기는 것입니다. 앱이 지금까지의 대화 · 바뀐 파일 · 다음 할 일을 인계 문서로 "
                + "정리해 대화 끝의 인계 카드에 보입니다. 내용을 확인하고 넘기면 받는 에이전트가 그 문서를 읽고 이어서 일합니다. "
                + "넘기기 전에는 아무것도 보내지 않습니다."),
        Item(title: "어디서 시작하나요",
             body: "입력창 아래의 에이전트 선택에서 \"… 에게 이어 맡기기\", 사용 한도에 닿았을 때 대화에 뜨는 줄, "
                + "또는 대화 > 인계 카드 열기 (\(MenuShortcut.handoff.symbol)). 설정 > 인계에서 한도에 닿으면 잠시 기다린 뒤 자동으로 "
                + "넘기게 할 수도 있습니다."),
        Item(title: "함께 쓰면 좋은 것",
             body: "분할 화면 (\(MenuShortcut.paneLayout(.twoColumns).symbol) · \(MenuShortcut.paneLayout(.fourGrid).symbol))으로 "
                + "여러 대화를 함께 돌리고, 오른쪽 인스펙터 (\(MenuShortcut.toggleInspector.symbol))에서 변경사항 · 파일 · 터미널을 봅니다. "
                + "대화 안에서 찾기는 \(MenuShortcut.findInConversation.symbol)."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Agent Handoff Console")
                .font(Theme.ui(.title, .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title)
                                .font(Theme.ui(.callout, .semibold))
                                .foregroundStyle(Theme.ink)
                            Text(item.body)
                                .font(Theme.ui(.callout))
                                .foregroundStyle(Theme.ink2)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            Divider()
            HStack(spacing: 10) {
                Button(MenuShortcut.keyboardShortcutsTitle) { switchTo { model.showKeyboardShortcuts = true } }
                Button("시작 점검…") {
                    switchTo {
                        // 프로젝트가 없으면 가운데 칸이 이미 점검표다.
                        if !model.showsFirstRun { model.showFirstRunSheet = true }
                    }
                }
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 520)
        .background(Theme.paper)
    }

    /// 이 시트를 닫은 뒤 다른 시트를 연다 (시트 둘을 한 번에 띄우지 않는다 — 닫히는 동안 연 시트는 뜨지 않았다).
    private func switchTo(_ open: @escaping @MainActor () -> Void) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { MainActor.assumeIsolated { open() } }
    }
}
