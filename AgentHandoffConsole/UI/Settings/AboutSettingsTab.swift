import SwiftUI
import AppKit

/// 앱 버전 — 정보 탭 · 문제를 알릴 때 붙일 줄.
enum AppVersion {
    static var short: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var build: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }

    static var display: String {
        build.map { "버전 \(short) (빌드 \($0))" } ?? "버전 \(short)"
    }

    /// 버전 복사 · CLI 확인 기록 복사의 첫 줄.
    static var report: String {
        "Agent Handoff Console \(short)" + (build.map { " (\($0))" } ?? "")
            + " · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}

/// 공개 저장소 주소 — 바뀌면 여기 한 곳만 고친다.
/// nil 이면 정보 탭에 저장소 · 문제 알리기 링크를 두지 않는다.
enum AppLinks {
    static let repository: URL? = URL(string: "https://github.com/jinuklee777/agent-handoff-console")
    static var issues: URL? { repository?.appendingPathComponent("issues") }
}

/// 설정 > 정보: 버전 · 소개 · 오픈소스 고지 · 이 Mac 밖으로 나가는 것 · 무관 고지.
struct AboutSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var showingNotices = false
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Agent Handoff Console").font(Theme.ui(.title, .semibold))
                        HStack(spacing: 10) {
                            Text(AppVersion.display)
                                .font(Theme.ui(.caption))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Button(copied ? "복사함" : "버전 복사") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(AppVersion.report, forType: .string)
                                copied = true
                            }
                            .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption, .medium)))
                            .help("앱 · macOS 버전을 복사합니다 (문제를 알릴 때)")
                        }
                        Text("Claude Code · Codex · Antigravity 를 한 창에서 쓰고, 사용 한도에 닿으면 하던 일을 다른 에이전트에게 이어 맡깁니다.")
                            .font(Theme.ui(.callout))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 16) {
                            if let repository = AppLinks.repository {
                                Link("GitHub 저장소", destination: repository)
                            }
                            if let issues = AppLinks.issues {
                                Link("문제 알리기", destination: issues)
                            }
                            Button("오픈소스 고지…") { showingNotices = true }
                                .buttonStyle(.link)
                        }
                        .font(Theme.ui(.callout))
                        .padding(.top, 2)
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                privacyRow(systemImage: "desktopcomputer", title: "대화 기록 · 설정",
                           detail: "이 Mac 에만 저장합니다. 앱에는 서버가 없고, 사용 통계도 보내지 않습니다.",
                           status: "나가지 않음")
                privacyRow(systemImage: "cpu", title: "에이전트에게 보낸 메시지",
                           detail: SettingsText.privacyCLINote,
                           status: "CLI 가 보냄")
                privacyRow(systemImage: "arrow.left.arrow.right", title: "인계 문서",
                           detail: "넘기면 앱이 정리한 문서(바꾼 파일 · 실행한 명령 · 대화 발췌, 비밀값은 최선 노력으로 가림)가 받는 에이전트의 CLI 를 거쳐 "
                               + "그 회사 서버로 갑니다. 자동으로 넘기기를 켜면 사람이 확인하지 않아도 갑니다. 설정 > 인계.",
                           status: model.automaticHandoffEnabled ? "자동으로 넘김" : "넘길 때만")
                privacyRow(systemImage: "arrow.triangle.pull", title: "Git · GitHub",
                           detail: "변경사항 탭에서 원격 상태 확인 · 받기 · 업로드를 하거나 Pull Request 를 볼 때 git · gh 가 저장소 서버와 주고받습니다.",
                           status: "쓸 때만")
                privacyRow(systemImage: "doc.text", title: "인계 문서를 Gemini 로 다듬기",
                           detail: "켜면 인계 재료를 비밀값을 가린 뒤 Google 로 보냅니다. 설정 > 인계.",
                           status: model.geminiSummaryEnabled ? "켜짐" : "꺼짐")
            } header: {
                Text("이 Mac 밖으로 나가는 것")
            } footer: {
                SettingsFooter("Anthropic · OpenAI · Google 과 관계없는 개인 프로젝트입니다. Claude · Claude Code · Codex · Gemini · Antigravity 는 "
                               + "각 회사의 상표입니다. 각 CLI 는 그 회사의 약관을 따릅니다.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingNotices) { ThirdPartyNoticesSheet() }
    }

    private func privacyRow(systemImage: String, title: String, detail: String, status: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(Theme.slate)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.well))
                .accessibilityHidden(true)
            SettingsLabel(title: title, subtitle: detail)
            Spacer(minLength: 8)
            Text(status)
                .font(Theme.ui(.caption, .medium))
                .foregroundStyle(status == "켜짐" ? Theme.ink : Theme.slate)
                .fixedSize()
        }
    }
}

/// 앱에 들어 있는 다른 사람의 코드와 그 라이선스 — 번들의 라이선스 파일을 그대로 보인다.
private struct ThirdPartyNoticesSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Notice: Identifiable {
        var id: String { name }
        let name: String
        let use: String
        let url: URL?
        let licenseFile: String
    }

    private static let notices = [
        Notice(name: "SwiftTerm", use: "앱 안의 터미널 (인스펙터 > 터미널)",
               url: URL(string: "https://github.com/migueldeicaza/SwiftTerm"), licenseFile: "LICENSE-SwiftTerm"),
        Notice(name: "thinking-orbs", use: "실행 중 상태 줄의 점 구",
               url: URL(string: "https://github.com/Jakubantalik/Libraries.dev"), licenseFile: "LICENSE-thinking-orbs"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("오픈소스 고지").font(Theme.ui(.body, .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Self.notices) { notice in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(notice.name).fontWeight(.semibold)
                                Text(notice.use).font(Theme.ui(.caption)).foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                if let url = notice.url { Link("저장소", destination: url).font(Theme.ui(.caption)) }
                            }
                            Text(Self.licenseText(notice.licenseFile))
                                .font(Theme.mono(.caption))
                                .foregroundStyle(Theme.ink2)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            HStack {
                Spacer()
                Button("완료") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 520)
    }

    private static func licenseText(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "라이선스 파일을 찾지 못했습니다 (\(name).txt)."
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
