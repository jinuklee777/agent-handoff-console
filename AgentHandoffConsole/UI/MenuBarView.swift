import SwiftUI
import AppKit

/// 메뉴바 아이콘 상태. 색만이 아니라 기호로도 구분한다. 판정은 순수 `MenuBarStatus` (App/AttentionBadge.swift).
enum MenuBarIndicator {
    case idle, running, needsResponse, problem

    @MainActor
    static func from(model: AppModel) -> MenuBarIndicator {
        // 여러 대화의 실행이 함께 돌 수 있다. 어느 하나라도 사람을 기다리면 그것을 먼저 알린다.
        // Dock 배지와 같은 목록 — 승인 · 질문에 더해 자동 작업 · 인계 검토 · 자동 인계 카운트다운 · 다른 계정에서 이어 가기 카운트다운도
        // 사람을 기다린다.
        switch MenuBarStatus.state(attention: model.dockAttentionThreadIDs.count, running: model.activeSessions.count,
                                   problems: problems(model: model)) {
        case .idle: return .idle
        case .running: return .running
        case .needsResponse: return .needsResponse
        case .problem: return .problem
        }
    }

    /// "확인 필요" 의 까닭들 — 사람이 아직 보지 않은 오류 · 한도로 끝난 실행(그 대화를 열면 빠진다 — `AppModel.unseenRunProblems`),
    /// 한도에 닿은 계정 · 로그인 문제, 종료 미확인 프로세스. 예전에는 마지막으로 끝난 실행의 상태(`runner.state`)를 보아 대화를 열어 봐도
    /// 다음 실행이 끝날 때까지 느낌표가 남았고, 무엇을 확인할지 말하지 않았다.
    @MainActor
    static func problems(model: AppModel) -> [MenuBarProblem] {
        var capped: [String] = []
        var authProblems: [String] = []
        // 계정이 여럿이면 어느 하나라도 막혔을 때 알린다 (그 계정만 못 쓰는 것이므로 판단은 사용자 몫).
        for snapshot in model.limits.allSnapshots where snapshot.status == .subscriptionCap || snapshot.status == .authProblem {
            let name: String
            if snapshot.provider == .codex, model.accounts.hasMultiple,
               let account = model.accounts.accounts.first(where: { $0.id == snapshot.accountID }) {
                name = "\(snapshot.provider.displayName) · \(account.label)"
            } else {
                name = snapshot.provider.displayName
            }
            if snapshot.status == .subscriptionCap { capped.append(name) } else { authProblems.append(name) }
        }
        return MenuBarStatus.problems(unseenRuns: model.unseenRunProblems, cappedAccounts: capped,
                                      authProblemAccounts: authProblems,
                                      unterminated: model.runner.unterminatedProcesses.count)
    }

    var symbolName: String {
        switch self {
        case .idle: return "arrow.left.arrow.right.circle"
        case .running: return "arrow.left.arrow.right.circle.fill"
        case .needsResponse: return "hand.raised.circle.fill"
        case .problem: return "exclamationmark.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .idle: return "대기"
        case .running: return "실행 중"
        // 승인 · 질문만이 아니다 (자동 인계 · 다른 계정에서 이어 가기 카운트다운 · 인계 검토 · 자동 작업 대기) — 툴바 칩과 같은 말.
        case .needsResponse: return "응답 필요"
        case .problem: return "확인 필요"
        }
    }
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let indicator = MenuBarIndicator.from(model: model)
        Image(systemName: indicator.symbolName)
            .accessibilityLabel("Agent Handoff Console — \(indicator.label)")
            .help("Agent Handoff Console — \(indicator.label)")
    }
}

struct MenuBarPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Agent Handoff Console").font(Theme.ui(.callout, .semibold))
                Spacer()
                Text(MenuBarIndicator.from(model: model).label)
                    .font(Theme.ui(.caption)).foregroundStyle(.secondary)
            }
            // "확인 필요" 의 까닭 — 대화의 일이면 누르면 그 대화로.
            let problems = MenuBarIndicator.problems(model: model)
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(problems) { problem in
                        if let threadID = problem.threadID {
                            Button { open(threadID) } label: {
                                Label(problem.text, systemImage: "exclamationmark.circle")
                                    .font(Theme.ui(.caption))
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.amberText)
                            .help("눌러서 그 대화 열기")
                        } else {
                            Label(problem.text, systemImage: "exclamationmark.circle")
                                .font(Theme.ui(.caption))
                                .foregroundStyle(Theme.amberText)
                                .lineLimit(2)
                        }
                    }
                }
            }

            Divider()

            // 한도 (메인 창과 같은 상태를 공유한다)
            VStack(alignment: .leading, spacing: 8) {
                // 툴바 한도 칩과 같은 줄 — 이 Mac 에서 찾지 못한 에이전트는 뺀다 (`AppModel.limitEntries`).
                // 설정 > 일반 > 메뉴바에서 숨긴 계정 · 구간은 뺀다 (`MenuBarLimits`).
                let entries = model.limitEntries
                let rows = MenuBarLimits.visible(entries, hidden: model.menuBarHiddenLimits)
                if rows.isEmpty, !entries.isEmpty {
                    Text(MenuBarLimits.allHiddenNote).font(Theme.ui(.caption)).foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    LimitSection(snapshot: row.entry.snapshot, showRawOnFailure: false, accountLabel: row.entry.accountLabel,
                                 windows: row.windows)
                }
                HStack(spacing: 12) {
                    Button {
                        Task { await model.limits.refreshAll(force: true) }
                    } label: {
                        Label("한도 새로고침", systemImage: "arrow.clockwise").font(Theme.ui(.caption))
                    }
                    .disabled(!model.limits.isRefreshing.isEmpty)
                    Spacer(minLength: 0)
                    Button {
                        openLimitSettings()
                    } label: {
                        Text(MenuBarLimits.settingsTitle(hiddenCount: MenuBarLimits.hiddenCount(entries, hidden: model.menuBarHiddenLimits)))
                            .font(Theme.ui(.caption))
                    }
                    .help("메뉴바에 보일 계정 · 구간을 고릅니다 (설정 > 일반 > 메뉴바)")
                }
                .buttonStyle(.link)
            }

            Divider()

            // 도는 실행들 (분할 화면 · 여러 대화의 동시 실행 · 자동 작업의 검토) — 실행 하나 = 에이전트 하나.
            VStack(alignment: .leading, spacing: 6) {
                let sessions = model.activeSessions
                Text(sessions.isEmpty ? "실행 중인 에이전트" : "실행 중인 에이전트 \(sessions.count)")
                    .font(Theme.ui(.caption, .semibold))
                if sessions.isEmpty {
                    Text("실행 중인 에이전트 없음").font(Theme.ui(.caption)).foregroundStyle(.secondary)
                }
                ForEach(sessions, id: \.activeRun?.id) { session in
                    if let run = session.activeRun {
                        HStack(alignment: .top, spacing: 6) {
                            // 누르면 그 대화로 (알림을 누른 것과 같은 길 — `AppModel.selectThread`).
                            Button { open(run.threadID) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        ProviderBadge(provider: run.provider, compact: true)
                                        if model.accounts.hasMultiple, let account = session.activeAccount {
                                            Text(account.label).font(Theme.ui(.caption)).lineLimit(1)
                                        }
                                        RunStateBadge(state: session.state)
                                        if !session.pendingApprovals.isEmpty || !session.pendingQuestions.isEmpty {
                                            Text(session.pendingApprovals.isEmpty ? "질문 대기" : "승인 대기")
                                                .font(Theme.ui(.caption, .semibold)).foregroundStyle(Theme.amberText).lineLimit(1)
                                        } else if session.isWaitingOnBackground && session.state != .interrupting {
                                            // 메인 턴은 끝났고 남은 하위 작업을 기다리는 중 (멈추는 중이면 그 상태가 우선).
                                            Text(SubAgentDigest.waitingMenuText(count: session.unfinishedSubAgentCount))
                                                .font(Theme.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Text(threadTitle(run.threadID))
                                        .font(Theme.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
                                    Text(JSONUtil.truncate(run.requestText, max: 90, marker: "…"))
                                        .font(Theme.ui(.caption)).foregroundStyle(.tertiary).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("눌러서 이 대화 열기")
                            .accessibilityLabel("\(threadTitle(run.threadID)) 대화 열기")
                            Spacer(minLength: 4)
                            Button {
                                Task { await session.interrupt() }
                            } label: {
                                Image(systemName: "stop.circle").font(.system(size: 13))
                            }
                            .buttonStyle(.plain)
                            .help("이 실행 중단")
                            .accessibilityLabel("\(threadTitle(run.threadID)) 실행 중단")
                        }
                    }
                }
                let approvals = sessions.reduce(0) { $0 + $1.pendingApprovals.count }
                let questions = sessions.reduce(0) { $0 + $1.pendingQuestions.count }
                // 누르면 답을 기다리는 첫 대화로 (여럿이면 위 줄에서 고른다).
                if approvals > 0, let threadID = sessions.first(where: { !$0.pendingApprovals.isEmpty })?.activeThreadID {
                    Button { open(threadID) } label: {
                        Label("승인 대기 \(approvals)건", systemImage: "hand.raised.fill")
                            .font(Theme.ui(.caption)).foregroundStyle(Theme.amberText)
                    }
                    .buttonStyle(.plain)
                    .help("눌러서 승인을 기다리는 대화 열기")
                }
                if questions > 0, let threadID = sessions.first(where: { !$0.pendingQuestions.isEmpty })?.activeThreadID {
                    Button { open(threadID) } label: {
                        Label("질문 대기 \(questions)건", systemImage: "questionmark.circle.fill")
                            .font(Theme.ui(.caption)).foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("눌러서 질문을 기다리는 대화 열기")
                }
            }

            Divider()

            // 메인 창에서 보고 있는 대화의 누적 사용량 — 팝오버에는 그 대화가 보이지 않아 제목을 붙인다 (아래 인계 카드 줄과 같다).
            VStack(alignment: .leading, spacing: 3) {
                Text(model.selectedThread.map { "누적 사용량 — \($0.title)" } ?? "누적 사용량")
                    .font(Theme.ui(.caption, .semibold))
                    .lineLimit(1)
                    .help("메인 창에서 보고 있는 대화의 누적 사용량")
                let agg = model.threadUsageAggregate
                Text("\(agg.turns)턴 · 토큰 \(Fmt.tokens(agg.totalTokens)) · "
                     + (agg.costUnknownTurns > 0 && agg.knownCostTurns > 0
                        ? "확인된 비용 \(Fmt.cost(agg.displayCostUSD))"
                        : "API 환산 \(Fmt.cost(agg.displayCostUSD))"))
                    .font(Theme.digits(.caption)).foregroundStyle(.secondary)
                if agg.costUnknownTurns > 0 || agg.unconfirmedTurns > 0 {
                    Text("금액 미확인 \(agg.costUnknownTurns)턴 · 미확정 \(agg.unconfirmedTurns)턴")
                        .font(Theme.ui(.caption)).foregroundStyle(Theme.amberText)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Button {
                    openMainWindow()
                } label: {
                    Label("메인 창 열기", systemImage: "macwindow").frame(maxWidth: .infinity, alignment: .leading)
                }
                // 메인 창의 가운데 칸을 현황으로 — 도는 실행 · 답을 기다리는 것을 한 화면에서 본다.
                Button {
                    openMainWindow()
                    model.requestOverview()
                } label: {
                    Label("현황 열기", systemImage: "waveform.path.ecg").frame(maxWidth: .infinity, alignment: .leading)
                }
                .help("메인 창에서 현황을 엽니다 (\(MenuShortcut.overview.symbol))")
                Button {
                    Task { await model.interruptAll() }
                } label: {
                    Label(model.activeSessions.count > 1 ? "모든 실행 중단" : "실행 중단", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(model.activeSessions.isEmpty)
                Button {
                    openMainWindow()
                    // 초안 확인 · 넘기기는 메인 창의 대화 끝 카드에서 한다 (카드가 있으면 그 카드로, 없으면 새로 만든다).
                    NotificationCenter.default.post(name: .handoffConsoleOpenHandoff, object: nil)
                } label: {
                    // 어느 대화의 카드인지 — 메인 창의 포커스 대화 (팝오버에는 그 대화가 보이지 않는다).
                    Label(model.selectedThread.map { "인계 카드 열기 — \($0.title)" } ?? "인계 카드 열기",
                          systemImage: "arrow.left.arrow.right")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!handoffAvailable)
                .help("메인 창에서 보고 있는 대화의 인계 카드를 엽니다")
                Divider()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("앱 종료", systemImage: "power").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .font(Theme.ui(.callout))
        }
        .padding(12)
        .frame(width: 320)
    }

    /// 포커스 대화에서 인계 카드를 열 수 있는가 — 카드가 있으면 늘, 없으면 실행 중이 아니고 인계할 수 있는 대화일 때.
    private var handoffAvailable: Bool {
        guard let thread = model.selectedThread else { return false }
        if model.hasHandoffActivity(threadID: thread.id) { return true }
        return !model.isSelectedThreadBusy && model.handoffEntryBlock(for: thread) == nil
    }

    private func threadTitle(_ id: String) -> String {
        (model.allThreads().first { $0.id == id } ?? model.internalThreadsByID[id])?.title ?? ""
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: MainWindowID.value)
    }

    /// 설정 > 일반 (메뉴바 묶음)을 연다.
    private func openLimitSettings() {
        SettingsTab.select(.general)
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    /// 메인 창을 열고 그 대화로 (칸에 열려 있으면 그 칸으로 포커스, 아니면 포커스 칸에 — 에이전트 기록 화면이면 대화로).
    private func open(_ threadID: String) {
        openMainWindow()
        Task { await model.selectThread(threadID) }
    }
}

enum MainWindowID {
    static let value = "main"

    /// 메인 창 후보 — 메뉴바 항목 · 패널 · 설정 창이 아닌 창. scene id 로 붙은 창(식별자가 `main` 으로 시작)이 앞에 온다.
    /// SwiftUI 설정 창(`com_apple_SwiftUI_Settings_window`)은 제목 막대가 있는 보통 창이라 따로 뺀다 — 메인 창을 닫고 설정만
    /// 열었을 때 ⌘O 의 폴더 고르기 · 시작 점검 시트가 설정 창에 붙지 않게.
    @MainActor
    static func candidates() -> [NSWindow] {
        let windows = NSApp.windows.filter { window in
            window.canBecomeMain
                && !window.className.contains("StatusBar")
                && !window.className.contains("MenuBarExtra")
                && !(window is NSPanel)
                && !isSettingsWindow(window)
        }
        let byID = windows.filter { $0.identifier?.rawValue.hasPrefix(value) == true }
        return byID + windows.filter { $0.identifier?.rawValue.hasPrefix(value) != true }
    }

    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        guard let id = window.identifier?.rawValue, !id.hasPrefix(value) else { return false }
        return id.localizedCaseInsensitiveContains("settings")
    }
}
