import SwiftUI
import AppKit

/// 첫 실행 점검표. ① 에이전트 ② 알림 ③ 작업할 폴더.
/// 프로젝트가 없을 때 가운데 칸 전체(`page`), 도움말 > 시작 점검… 에서는 시트(`sheet`).
/// 판정은 `FirstRunChecklist`(순수), 사실은 `AppModel+Setup`. ①②는 안내일 뿐 ③을 막지 않는다.
/// 앱은 설치 · 로그인을 대신 실행하지 않는다 — 공식 안내를 열고 명령을 복사만 한다.
struct FirstRunView: View {
    enum Mode { case page, sheet }

    /// 시트 높이의 상한 — 보이는 메인 창의 툴바 아래 높이(`contentLayoutRect`)에서 여백을 뺀 값, 720 을 넘지 않는다.
    static func sheetMaxHeight() -> CGFloat {
        guard let window = MainWindowID.candidates().first(where: { $0.isVisible }) else { return 720 }
        return min(720, max(360, window.contentLayoutRect.height - 16))
    }

    let mode: Mode
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    /// 방금 복사한 명령 (그 줄의 단추가 "복사함" 이 된다).
    @State private var copied: String?
    /// 보이는 높이 — 낮은 창(900×560)에서는 위 여백을 줄여 ③ "작업할 폴더" 의 단추가 첫 화면에 들게 한다 (①②는 막지 않는다).
    @State private var visibleHeight: CGFloat = 800
    /// 폴더를 여는 중 — 첫 대화의 에이전트를 고르려고 확인 중인 에이전트를 잠깐 기다릴 수 있다 (`AppModel.waitForAgentFacts`).
    @State private var openingFolder = false
    /// "로그인 필요" 를 지켜보는 간격 (초) — 앱 안의 터미널에서 로그인해도 바뀌게 (`AppModel.refreshPendingLogins`, onb-11).
    private static let loginWatchInterval: UInt64 = 5

    private var short: Bool { visibleHeight < 700 }

    var body: some View {
        let checklist = model.firstRunChecklist
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.bottom, short ? 14 : 30)
                    step(.agents, checklist: checklist) { agentsStep(checklist.facts) }
                    step(.notifications, checklist: checklist) { notificationsStep(checklist.facts) }
                    step(.folder, checklist: checklist, last: true) { folderStep(checklist) }
                    if mode == .page {
                        footer
                            .padding(.top, 26)
                    }
                }
                .frame(maxWidth: 600, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, mode == .page ? (short ? 14 : 64) : (short ? 20 : 30))
                .padding(.bottom, mode == .page ? 32 : 20)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { visibleHeight = $0 }
            // 시트는 "다시 확인 · 닫기" 를 스크롤 밖 아래에 둔다 (내용이 길어도 보이게).
            if mode == .sheet {
                Rectangle().fill(Theme.hair).frame(height: 1)
                footer
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
            }
        }
        .background(Theme.paper)
        // 아직 쓸 수 있는 에이전트가 없고 "로그인 필요" 가 있으면, 앱이 앞에 있는 동안 로그인만 가볍게 다시 본다 (onb-11).
        .task(id: checklist.watchesLogins) {
            guard checklist.watchesLogins else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.loginWatchInterval * 1_000_000_000)
                guard !Task.isCancelled else { return }
                if NSApp.isActive { await model.refreshPendingLogins() }
            }
        }
    }

    // MARK: 머리

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mode == .page ? "시작하기 전에" : "시작 점검")
                .font(Theme.ui(.title, .semibold))
                .foregroundStyle(Theme.ink)
            // 이 앱이 하는 일 (onb-6) — 처음 연 사람이 "이어 맡기기 · 인계" 를 처음 만나기 전에.
            Text("한 대화를 Claude Code 와 Codex 가 이어 맡습니다. 한도에 닿으면 지금까지의 맥락을 인계 문서로 정리해 넘기고, 넘기기 전에는 아무것도 실행되지 않습니다.")
                .font(Theme.ui(.callout))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text("먼저 에이전트 CLI 와 알림을 확인하고 프로젝트 폴더를 엽니다. 설치와 로그인은 터미널에서 직접 하고, 앱은 명령을 복사만 합니다.")
                .font(Theme.ui(.callout))
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 단계 틀

    private func step<Content: View>(_ step: FirstRunStep, checklist: FirstRunChecklist, last: Bool = false,
                                     @ViewBuilder content: () -> Content) -> some View {
        let state = checklist.state(step)
        let isNext = checklist.next == step
        return HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                StepMark(number: step.rawValue, state: state, isNext: isNext)
                if !last {
                    Rectangle().fill(Theme.hair).frame(width: 1).frame(maxHeight: .infinity).padding(.top, 6)
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(step))
                        .font(Theme.ui(.body, .semibold))
                        .foregroundStyle(state == .done || state == .doneWithNote ? Theme.ink2 : Theme.ink)
                    Text(subtitle(step))
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 단계의 상태는 번호 동그라미(`StepMark` — 숨김)에만 그려진다 — VoiceOver 에는 머리 하나로 읽힌다 (onb-14).
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(step.rawValue)단계 \(title(step))")
                .accessibilityValue(stateDescription(state, isNext: isNext))
                .accessibilityHint(subtitle(step))
                .accessibilityAddTraits(.isHeader)
                content()
            }
            .padding(.bottom, last ? 0 : (short ? 14 : 28))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func title(_ step: FirstRunStep) -> String {
        switch step {
        case .agents: return "에이전트"
        case .notifications: return "알림"
        case .folder: return "작업할 폴더"
        }
    }

    private func subtitle(_ step: FirstRunStep) -> String {
        switch step {
        case .agents: return "Claude Code · Codex 중 하나면 시작할 수 있습니다."
        case .notifications: return "승인이 필요하거나 실행이 끝나면 알립니다 — 그 대화를 보고 있을 때는 알리지 않습니다. 꺼 두어도 앱은 그대로 씁니다."
        case .folder: return "에이전트가 일할 폴더를 고르면 첫 대화가 열립니다. 위 단계가 끝나지 않아도 열 수 있습니다."
        }
    }

    /// VoiceOver 가 읽는 단계의 상태 (화면에서는 번호 동그라미).
    private func stateDescription(_ state: FirstRunStepState, isNext: Bool) -> String {
        switch state {
        case .done: return "완료"
        case .doneWithNote: return "완료 — 확인할 것이 있습니다"
        case .checking: return "확인 중"
        case .todo: return isNext ? "할 일 — 다음 단계" : "할 일"
        }
    }

    // MARK: ① 에이전트

    private func agentsStep(_ facts: FirstRunFacts) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([AgentProvider.claude, .codex, .gemini], id: \.self) { provider in
                if provider != .claude { Rectangle().fill(Theme.hairSoft).frame(height: 1) }
                agentRow(provider, facts.agent(provider), facts: facts)
                    .padding(.vertical, 11)
            }
            if let shellText = shellNote(facts.shell) {
                note(shellText)
                    .padding(.top, 4)
                    .leadingRule(Theme.slate3, width: 2, gap: 11)
            }
            if let authText = SettingsText.withheldAuthNote(facts.withheldAuth) {
                HStack(alignment: .top, spacing: 10) {
                    note(authText)
                    Spacer(minLength: 6)
                    Button("설정 열기") {
                        SettingsTab.select(.agents)
                        openSettings()
                    }
                    .buttonStyle(ChipButtonStyle(height: 25, horizontalPadding: 10))
                    .fixedSize()
                    .accessibilityLabel("설정 열기: 셸의 API 키")
                }
                .padding(.top, 4)
                .leadingRule(Theme.slate3, width: 2, gap: 11)
            }
        }
    }

    /// 셸 설정을 읽지 못했으면 그 사실 (onb-2 · onb-3) — 거기 둔 PATH · 프록시가 CLI 에 넘어가지 않는다.
    private func shellNote(_ shell: ShellRead) -> String? {
        switch shell {
        case .interactive, .unknown:
            return nil
        case .loginOnly:
            return "대화형 셸 설정(~/.zshrc)을 시간 안에 읽지 못해 로그인 셸 설정(~/.zprofile)만 썼습니다. ~/.zshrc 의 PATH · 프록시는 CLI 에 넘어가지 않습니다 — 셸 설정을 고친 뒤 [다시 확인] 을 누르세요."
        case .failed:
            return "셸 설정을 읽지 못해 일반 설치 위치에서만 CLI 를 찾습니다. ~/.zshrc · ~/.zprofile 의 PATH · 프록시는 CLI 에 넘어가지 않습니다 — 셸 설정을 고친 뒤 [다시 확인] 을 누르세요."
        }
    }

    private func agentName(_ provider: AgentProvider) -> String {
        switch provider {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        case .gemini: return "Antigravity"
        }
    }

    private func agentRow(_ provider: AgentProvider, _ agent: FirstRunFacts.Agent, facts: FirstRunFacts) -> some View {
        let optional = provider == .gemini
        return HStack(alignment: .top, spacing: 11) {
            BrandMark(provider: provider, size: 15)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(agentName(provider))
                        .font(Theme.ui(.callout, .semibold))
                        .foregroundStyle(Theme.ink)
                    if optional {
                        Text("선택")
                            .font(Theme.ui(.caption))
                            .foregroundStyle(Theme.slate2)
                    }
                    Spacer(minLength: 8)
                    statusLabel(provider, agent)
                }
                if agent.version != nil || agent.path != nil {
                    HStack(spacing: 6) {
                        if let version = agent.version {
                            Text(version)
                                .font(Theme.mono(.caption))
                                .foregroundStyle(Theme.slate)
                                .lineLimit(1)
                        }
                        if agent.version != nil, agent.path != nil {
                            Text("·").font(Theme.ui(.caption)).foregroundStyle(Theme.slate3)
                        }
                        if let path = agent.path {
                            Text(path)
                                .font(Theme.mono(.caption))
                                .foregroundStyle(Theme.slate2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(path)
                        }
                    }
                }
                agentAction(provider, agent, facts: facts)
            }
        }
    }

    @ViewBuilder
    private func statusLabel(_ provider: AgentProvider, _ agent: FirstRunFacts.Agent) -> some View {
        switch agent.readiness {
        case .ready:
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                Text("로그인됨").font(Theme.ui(.caption)).foregroundStyle(Theme.ink2)
            }
        case .loginUnknown:
            if provider == .gemini {
                Text("설치됨").font(Theme.ui(.caption)).foregroundStyle(Theme.ink2)
            } else {
                HStack(spacing: 5) {
                    Circle().fill(Theme.amber).frame(width: 6, height: 6)
                    Text("로그인을 확인하지 못했습니다").font(Theme.ui(.caption)).foregroundStyle(Theme.ink2)
                }
            }
        case .notLoggedIn:
            Text("로그인 필요").font(Theme.ui(.caption, .medium)).foregroundStyle(Theme.ink)
        case .notInstalled:
            Text("설치되지 않음").font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
        case .pathInvalid:
            // 찾았지만 돌지 않으면 "실행할 수 없음", 설정에서 지정한 경로가 안 되면 "지정한 경로 오류".
            if agent.runError != nil {
                Text("실행할 수 없음").font(Theme.ui(.caption, .medium)).foregroundStyle(Theme.ink)
            } else {
                Text("지정한 경로 오류").font(Theme.ui(.caption, .medium)).foregroundStyle(Theme.ink)
            }
        case .checking:
            HStack(spacing: 5) {
                InkSpinner(color: Theme.slate)
                Text("확인 중").font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
            }
        }
    }

    @ViewBuilder
    private func agentAction(_ provider: AgentProvider, _ agent: FirstRunFacts.Agent, facts: FirstRunFacts) -> some View {
        switch (provider, agent.readiness) {
        case (.gemini, .notInstalled):
            note("가벼운 작업을 Antigravity 에게 맡길 때만 필요합니다.")
        case (_, .pathInvalid):
            if let runError = agent.runError {
                // 찾았지만 돌지 않는다 (`#!/usr/bin/env node` 인데 node 를 못 찾음 등, onb-2) — CLI 가 남긴 말을 그대로 보인다.
                VStack(alignment: .leading, spacing: 7) {
                    Text(runError)
                        .font(Theme.mono(.caption))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .center, spacing: 10) {
                        note("찾은 실행 파일이 돌지 않습니다. node 같은 런타임을 nvm · mise 로 설치했다면 터미널에서 which \(binaryName(provider)) 로 위치를 확인해 설정 > 에이전트의 실행 파일에 지정하세요.")
                        Spacer(minLength: 6)
                        pathSettingsButton(provider, title: "경로 지정…")
                    }
                }
            } else {
                // 앱은 지정한 경로가 안 되면 다른 곳을 찾지 않는다 — 설치해도 그대로라 설치 안내를 보이지 않는다.
                HStack(alignment: .center, spacing: 10) {
                    note("설정 > 에이전트에서 지정한 경로를 실행할 수 없습니다. 경로를 고치거나 비워 두면 자동으로 찾습니다.")
                    Spacer(minLength: 6)
                    pathSettingsButton(provider, title: "설정 열기")
                }
            }
        case (.gemini, _), (_, .ready), (_, .checking):
            EmptyView()
        case (_, .notInstalled):
            VStack(alignment: .leading, spacing: 7) {
                note("공식 안내대로 설치한 뒤 이 화면으로 돌아오면 다시 확인합니다. 아래 명령에는 Node.js(npm)가 있어야 합니다 — 없으면 설치 안내의 다른 방법을 따르세요.")
                HStack(spacing: 8) {
                    if let url = AgentSetupGuide.docsURL(provider) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 5) {
                                Text("설치 안내 열기")
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                        }
                        .buttonStyle(ChipButtonStyle(height: 25, horizontalPadding: 10))
                        .help(url.absoluteString)
                        .accessibilityLabel("설치 안내 열기: \(agentName(provider))")
                    }
                    if let command = AgentSetupGuide.installCommand(provider) {
                        commandWell(command)
                    }
                }
                // 이미 설치했는데 못 찾았다 (nvm · mise 등 앱이 모르는 곳) — 점검표에서 바로 경로를 지정하러 간다 (onb-2).
                HStack(alignment: .center, spacing: 10) {
                    note("이미 설치했는데 찾지 못했다면 실행 파일의 위치를 지정하세요.")
                    Spacer(minLength: 6)
                    pathSettingsButton(provider, title: "경로 지정…")
                }
            }
        case (_, .notLoggedIn):
            VStack(alignment: .leading, spacing: 7) {
                note("터미널에서 로그인한 뒤 이 화면으로 돌아오면 다시 확인합니다.")
                commandWell(loginCommand(provider, accountID: agent.accountID))
            }
        case (_, .loginUnknown):
            VStack(alignment: .leading, spacing: 7) {
                note(loginUnknownNote(provider, facts: facts))
                commandWell(loginCommand(provider, accountID: agent.accountID))
            }
        }
    }

    /// 로그인을 확인하지 못한 까닭과 할 일 — 행동 기준으로 (onb-16).
    private func loginUnknownNote(_ provider: AgentProvider, facts: FirstRunFacts) -> String {
        switch provider {
        case .codex:
            return "Codex 가 로그인 정보를 키체인 등 파일이 아닌 곳에 두면 앱이 확인할 수 없습니다. 터미널에서 codex 가 동작하면 그대로 쓰면 됩니다."
        default:
            if facts.claudeAlternativeAuth {
                return "API 키 · Bedrock · Vertex 설정이 환경 변수에 있습니다 — 그것으로 쓰면 로그인하지 않아도 됩니다. 이 확인은 claude 로그인만 봅니다."
            }
            return "로그인 상태를 확인하지 못했습니다. 터미널에서 claude 가 동작하면 그대로 쓰면 됩니다."
        }
    }

    private func binaryName(_ provider: AgentProvider) -> String {
        switch provider {
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "agy"
        }
    }

    /// 설정 > 에이전트(실행 파일)로 간다.
    private func pathSettingsButton(_ provider: AgentProvider, title: String) -> some View {
        Button(title) {
            SettingsTab.select(.agents)
            openSettings()
        }
        .buttonStyle(ChipButtonStyle(height: 25, horizontalPadding: 10))
        .fixedSize()
        .accessibilityLabel("\(title.replacingOccurrences(of: "…", with: "")): \(agentName(provider)) 실행 파일")
    }

    private func loginCommand(_ provider: AgentProvider, accountID: String?) -> String {
        switch provider {
        case .codex:
            // 앱이 읽는 홈에 로그인되게 — 그 홈을 붙인 명령 (`CodexAccountInspector.loginCommand`).
            let account = model.accounts.accountOrDefault(accountID ?? CodexAccount.defaultID)
            return CodexAccountInspector.loginCommand(home: account.homePath)
        default:
            return AgentSetupGuide.claudeLoginCommand
        }
    }

    // MARK: ② 알림

    private func notificationsStep(_ facts: FirstRunFacts) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            notificationState(facts)
            // 이번 실행에서 권한을 물은 일 · 요청 실패를 사실대로 (H15 — "답한 적 없는데 꺼짐" 인지 "요청 실패" 인지 가르게).
            if let request = model.notifications.requestNote {
                note(request)
            } else if let error = model.notifications.lastError {
                note(error)
            }
        }
    }

    @ViewBuilder
    private func notificationState(_ facts: FirstRunFacts) -> some View {
        switch facts.notifications {
        case .authorized:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                    Text("알림을 받습니다").font(Theme.ui(.caption)).foregroundStyle(Theme.ink2)
                }
                if facts.badgesEnabled == false {
                    HStack(alignment: .center, spacing: 10) {
                        note("Dock 배지가 꺼져 있습니다. 시스템 설정 > 알림에서 배지를 켜면 기다리는 대화 수가 Dock 아이콘에 보입니다.")
                        Spacer(minLength: 6)
                        settingsButton
                    }
                    .leadingRule(Theme.slate3, width: 2, gap: 11)
                }
            }
        case .notDetermined:
            HStack(spacing: 10) {
                note("아직 권한을 묻지 않았습니다. 지금 묻지 않으면, 앱이 뒤에 있을 때 처음 알릴 일이 생긴 순간 macOS 가 묻습니다.")
                Spacer(minLength: 6)
                Button("알림 허용") { Task { await model.requestNotificationPermission() } }
                    .buttonStyle(ChipButtonStyle(height: 25, horizontalPadding: 10))
            }
        case .denied:
            HStack(spacing: 10) {
                note("알림이 꺼져 있습니다. 승인이 필요해도 앱을 보고 있지 않으면 알 수 없습니다.")
                Spacer(minLength: 6)
                settingsButton
            }
        case .unknown:
            HStack(spacing: 10) {
                note("알림 설정을 읽지 못했습니다. 시스템 설정 > 알림에서 볼 수 있습니다.")
                Spacer(minLength: 6)
                settingsButton
            }
        case .checking:
            // 아직 읽기 전 (시작 직후) — 실패로 쓰지 않는다.
            note("알림 설정을 확인하는 중입니다.")
        }
    }

    private var settingsButton: some View {
        Button("시스템 설정 열기") {
            if let url = AppModel.notificationSettingsURL() { NSWorkspace.shared.open(url) }
        }
        .buttonStyle(ChipButtonStyle(height: 25, horizontalPadding: 10))
        .fixedSize()
    }

    // MARK: ③ 작업할 폴더

    private func folderStep(_ checklist: FirstRunChecklist) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if checklist.facts.git == .missing {
                VStack(alignment: .leading, spacing: 7) {
                    note("Command Line Tools 가 없습니다. 변경사항 탭 · 브랜치 · 독립 작업 폴더는 Git 이 있어야 씁니다. 설치하기 전에는 앱이 Git 을 부르지 않지만, 에이전트가 git 을 쓰면 macOS 가 설치 창을 띄울 수 있습니다.")
                    commandWell(AgentSetupGuide.gitToolsInstallCommand)
                }
                .leadingRule(Theme.slate3, width: 2, gap: 11)
            }
            if checklist.facts.projectCount > 0 {
                Text("프로젝트 \(checklist.facts.projectCount)개가 등록돼 있습니다.")
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.ink2)
            }
            HStack(spacing: 8) {
                Button {
                    Task {
                        // 첫 대화의 에이전트를 고르려고 확인 중인 에이전트를 몇 초 기다릴 수 있다 (`AppModel.waitForAgentFacts`).
                        openingFolder = true
                        defer { openingFolder = false }
                        if await ProjectFolderPicker.chooseAndOpen(model: model), mode == .sheet {
                            model.showFirstRunSheet = false
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if openingFolder { InkSpinner(color: Theme.paper) }
                        Text("프로젝트 폴더 열기…")
                    }
                }
                .buttonStyle(InkButtonStyle(height: 28))
                .disabled(!checklist.canOpenFolder || openingFolder)
                Button("기록 가져오기…") {
                    if mode == .sheet {
                        // 시트를 닫은 뒤 가져오기 시트를 연다 (`ContentView` 의 onDismiss).
                        model.importAfterFirstRunSheet = true
                        model.showFirstRunSheet = false
                    } else {
                        model.showImportSheet = true
                    }
                }
                .buttonStyle(ChipButtonStyle(height: 28, horizontalPadding: 11))
                .help("Claude Code · Codex 에서 쓰던 세션 기록을 이 앱의 프로젝트 · 대화로 가져옵니다")
            }
        }
    }

    // MARK: 아래

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.firstRunError {
                Text(error)
                    .font(Theme.ui(.callout))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .leadingRule(Theme.danger, width: 2, gap: 11)
            }
            // 대화가 없어 배너가 그려질 칸이 없다 — 점검표가 보인다.
            if let banner = model.banner {
                HStack(alignment: .top, spacing: 10) {
                    Text(banner.text)
                        .font(Theme.ui(.callout))
                        .foregroundStyle(banner.isError ? Theme.ink : Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    if let title = banner.actionTitle, let action = banner.action {
                        Button(title, action: action)
                            .buttonStyle(ChipButtonStyle(height: 25, horizontalPadding: 10))
                    }
                    Button("닫기") { model.banner = nil }
                        .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
                        .accessibilityLabel("안내 닫기")
                }
                .leadingRule(banner.isError ? Theme.danger : Theme.slate3, width: 2, gap: 11)
            }
            HStack(spacing: 10) {
                Button {
                    Task { await model.recheckFirstRunFacts() }
                } label: {
                    HStack(spacing: 5) {
                        if model.isRefreshingAgentFacts {
                            InkSpinner(color: Theme.slate)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .medium))
                        }
                        Text("다시 확인")
                    }
                }
                .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
                .disabled(model.isRefreshingAgentFacts)
                .help("로그인 셸의 PATH 부터 다시 읽고 CLI · 로그인 · 알림 · Git 을 다시 확인합니다")
                Spacer()
                if mode == .sheet {
                    Button("닫기") { model.showFirstRunSheet = false }
                        .buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 12))
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    // MARK: 부품

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(.caption))
            .foregroundStyle(Theme.slate)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 복사할 명령 한 줄 — 앱은 실행하지 않는다.
    private func commandWell(_ command: String) -> some View {
        HStack(spacing: 8) {
            Text(command)
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(command)
            Button(copied == command ? "복사함" : "복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = command
            }
            .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption, .medium)))
            .fixedSize()
            .accessibilityLabel("명령 복사: \(command)")
        }
        .padding(.horizontal, 9)
        .frame(height: 25)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.well))
    }
}

/// 로그인 문제로 끝난 실행의 오류 줄 아래에 붙이는 안내 (onb-7): 무엇이 문제인지 · 터미널의 로그인 명령 [복사] · [시작 점검 열기].
/// 판정 · 글은 `LoginTroubleGuide`(순수), 입구는 `AppModel.loginTroubleGuide(for:)`. 오류 줄(`AlertRow`)이 이렇게 붙인다:
/// `if let guide = model.loginTroubleGuide(for: event) { LoginTroubleNote(guide: guide) }`.
struct LoginTroubleNote: View {
    let guide: LoginTroubleGuide
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(guide.text)
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let command = guide.loginCommand {
                    HStack(spacing: 8) {
                        Text(command)
                            .font(Theme.mono(.caption))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(command)
                        Button(copied ? "복사함" : "복사") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            copied = true
                        }
                        .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption, .medium)))
                        .fixedSize()
                        .accessibilityLabel("로그인 명령 복사: \(command)")
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 25)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.well))
                }
                Button(LoginTroubleGuide.startCheckTitle) { model.openStartCheck() }
                    .buttonStyle(ChipButtonStyle(height: 25, horizontalPadding: 10))
                    .fixedSize()
            }
        }
    }
}

/// 단계 번호 동그라미: 끝남 → 체크, 다음 할 일 → 잉크 테두리, 확인 중 → 도는 링, 나머지 → 옅은 테두리.
private struct StepMark: View {
    let number: Int
    let state: FirstRunStepState
    let isNext: Bool

    var body: some View {
        ZStack {
            switch state {
            case .done, .doneWithNote:
                Circle().fill(Theme.well)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.ink2)
            case .checking:
                Circle().strokeBorder(Theme.hair, lineWidth: 1)
                InkSpinner(color: Theme.slate)
            case .todo:
                Circle().strokeBorder(isNext ? Theme.ink : Theme.slate3, lineWidth: isNext ? 1.5 : 1)
                Text("\(number)")
                    .font(Theme.digits(.caption, .semibold))
                    .foregroundStyle(isNext ? Theme.ink : Theme.slate)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

// MARK: - 프로젝트 폴더 고르기 (사이드바 · 파일 메뉴 · 점검표가 함께 쓴다)

@MainActor
enum ProjectFolderPicker {
    /// 폴더를 고르게 하고(창이 있으면 그 창의 시트로) 넓은 폴더면 한 번 묻고 연다 (`AppModel.openProjectFolder`). 열었으면 true.
    @discardableResult
    static func chooseAndOpen(model: AppModel) async -> Bool {
        guard let url = await choose(), confirmBroadFolder(url.path) else { return false }
        return await model.openProjectFolder(path: url.path) != nil
    }

    /// 파일 메뉴의 "프로젝트 폴더 열기…": 창이 없으면 먼저 연다 (시트를 붙일 곳).
    static func openFromMenu(model: AppModel) async {
        if mainWindow() == nil {
            AppDelegate.showMainWindow()
            for _ in 0..<20 where mainWindow() == nil { try? await Task.sleep(for: .milliseconds(100)) }
        }
        await chooseAndOpen(model: model)
    }

    static func choose() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "열기"
        panel.message = "에이전트가 작업할 프로젝트 폴더를 고르세요."
        if let window = mainWindow() {
            // 점검표 시트가 떠 있으면 그 위에 (시트 위의 시트).
            let host = window.attachedSheet ?? window
            return await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: host) { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// `/` · 홈 폴더 전체는 한 번 묻는다 (`FolderChoice.risk`). 계속하면 true.
    static func confirmBroadFolder(_ path: String) -> Bool {
        guard let risk = FolderChoice.risk(path) else { return true }
        let alert = NSAlert()
        alert.messageText = risk == .home ? "홈 폴더 전체를 프로젝트 폴더로 열까요?" : "디스크 전체(/)를 프로젝트 폴더로 열까요?"
        alert.informativeText = "에이전트가 이 폴더 아래의 모든 파일을 읽고 바꿀 수 있습니다. 작업할 프로젝트 폴더 하나를 고르는 것이 안전합니다."
        alert.addButton(withTitle: "취소")
        alert.addButton(withTitle: "그래도 열기")
        alert.alertStyle = .warning
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// 보이는 메인 창 (설정 창 · 메뉴바 창이 아니다 — `MainWindowID.candidates`).
    private static func mainWindow() -> NSWindow? {
        MainWindowID.candidates().first { $0.isVisible }
    }
}
