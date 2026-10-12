import SwiftUI
import AppKit

// 설정 창 · 프로젝트 설정 시트의 공통 부품: 줄(제목 · 설명 · 조작) · 도움말 단추 · 꼬리표 · 꼬리말 · 고르기 줄 ·
// 에이전트 상태 알약 · 복사할 명령 칸. 제목은 Form 의 기본 글꼴, 설명은 `Theme.ui(.caption)` 의 보조색이다.

/// 제목(+ 꼬리표 · 도움말)과 그 아래 설명 한두 줄.
struct SettingsLabel: View {
    let title: String
    var subtitle: String?
    var help: String?
    var tag: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                if let tag { SettingsTag(text: tag) }
                if let help { SettingsHelpButton(text: help, subject: title) }
            }
            if let subtitle {
                Text(subtitle)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 설정 한 줄: 왼쪽에 제목 · 설명, 오른쪽에 조작.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var help: String?
    var tag: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            SettingsLabel(title: title, subtitle: subtitle, help: help, tag: tag)
            Spacer(minLength: 8)
            control()
        }
    }
}

/// 경로 한 줄: 제목 아래에 경로(고정폭), 오른쪽에 "Finder 에서 보기".
struct SettingsPathRow: View {
    let title: String
    let url: URL

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(SettingsActions.abbreviated(url.path))
                    .font(Theme.mono(.caption))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Finder 에서 보기") { SettingsActions.reveal(url) }
        }
    }
}

/// 스위치 줄.
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String?
    var help: String?
    var tag: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, help: help, tag: tag) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// 둘 이상 가운데 하나를 고르는 줄 (제목 + 설명). 고른 줄만 아래에 세부를 편다 — 세부는 부르는 쪽이 그린다.
struct SettingsChoiceRow: View {
    let title: String
    var subtitle: String?
    var tag: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Color.accentColor : Theme.control)
                    .padding(.top, 1)
                SettingsLabel(title: title, subtitle: subtitle, tag: tag)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// 제목 옆 (?) — 누르면 긴 설명을 띄운다 (포인터를 올려도 보인다). 화면에는 한 줄만 두고 나머지는 여기에.
struct SettingsHelpButton: View {
    let text: String
    var subject = ""
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel(subject.isEmpty ? "도움말" : "도움말: \(subject)")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 320, alignment: .leading)
                .padding(12)
        }
    }
}

/// 작은 꼬리표 ("기본" · "실험" · "CLI 기본").
struct SettingsTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.ui(.caption, .semibold))
            .foregroundStyle(text == "실험" ? Theme.ultraText : Theme.ink2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(text == "실험" ? Theme.ultraWell : Theme.well))
    }
}

/// 묶음 아래의 설명 (Form 의 꼬리말).
struct SettingsFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.ui(.caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 경고 · 확인 칸 (앰버 바탕). 조작은 부르는 쪽이 아래에 둔다.
struct SettingsWarning<Actions: View>: View {
    let title: String?
    let text: String
    var tone: Color = Theme.amber
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(tone)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    if let title {
                        Text(title).font(Theme.ui(.callout, .semibold)).foregroundStyle(Theme.ink)
                    }
                    Text(text)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            actions()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.approvalWell))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.approvalBorder))
    }
}

extension SettingsWarning where Actions == EmptyView {
    init(title: String? = nil, text: String, tone: Color = Theme.amber) {
        self.init(title: title, text: text, tone: tone) { EmptyView() }
    }
}

/// 에이전트 카드 머리의 상태 — 판정은 첫 실행 점검표와 같다 (`AgentReadiness`). 색만으로 말하지 않게 늘 글과 함께.
struct AgentStatusPill: View {
    let readiness: AgentReadiness
    /// Antigravity — 로그인을 확인하지 않으므로 "로그인 미확인" 대신 "설치됨".
    var optional = false

    var body: some View {
        HStack(spacing: 5) {
            if readiness == .checking {
                InkSpinner(color: Theme.slate)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(text)
                .font(Theme.ui(.caption, .semibold))
                .foregroundStyle(Theme.ink2)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(Theme.well))
        .accessibilityElement(children: .combine)
    }

    var text: String {
        switch readiness {
        case .ready: return "준비됨"
        case .loginUnknown: return optional ? "설치됨" : "로그인 미확인"
        case .notLoggedIn: return "로그인 필요"
        case .notInstalled: return "설치 안 됨"
        case .pathInvalid: return "실행할 수 없음"
        case .checking: return "확인 중"
        }
    }

    private var color: Color {
        switch readiness {
        case .ready: return Theme.emerald
        case .loginUnknown: return optional ? Theme.emerald : Theme.amber
        case .notLoggedIn: return Theme.amber
        case .notInstalled, .checking: return Theme.slate2
        case .pathInvalid: return Theme.danger
        }
    }
}

/// 복사할 명령 한 줄 — 앱은 실행하지 않는다.
struct CopyableCommand: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(command)
            Spacer(minLength: 4)
            Button(copied ? "복사함" : "복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption, .medium)))
            .fixedSize()
            .accessibilityLabel("명령 복사: \(command)")
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.well))
        .onChange(of: command) { copied = false }
    }
}

/// 설정의 작은 동작들.
@MainActor
enum SettingsActions {
    /// Finder 에서 보인다 — 파일이면 그 파일을 고른 채, 없으면 있는 가장 가까운 상위 폴더를.
    static func reveal(_ url: URL) {
        var target = url
        while !FileManager.default.fileExists(atPath: target.path), target.pathComponents.count > 1 {
            target = target.deletingLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// 시스템 설정 > 일반 > 로그인 항목.
    static func openLoginItems() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 실행 파일 · 폴더 고르기 (설정 창의 시트가 아니라 앱 모달 — 설정 창은 작아서).
    static func choose(directories: Bool, message: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.canCreateDirectories = directories
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = message
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
