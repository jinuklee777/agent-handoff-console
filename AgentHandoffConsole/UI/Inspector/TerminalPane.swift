import SwiftUI

/// 터미널 탭.
///
/// - **에이전트 실행**: 이 대화에서 에이전트가 실행한 명령(과 앱이 대신 실행한 git 명령 — "앱" 표시)을 터미널처럼 보여준다. 읽기 전용.
/// - **셸**: 대화가 일하는 폴더(프로젝트 폴더 또는 독립 작업 폴더)에서 도는 사용자 셸 (SwiftTerm · PTY). 폴더마다 하나이고 탭을
///   옮겨도 살아 있다. 앱은 이 셸의 입력·출력을 저장하지 않는다.
struct TerminalPane: View {
    @Environment(AppModel.self) private var model

    enum Sub: String { case agent, shell }
    @State private var sub: Sub = TerminalPane.initialSub
    /// "새로 시작" 을 누르면 뷰를 새로 만들기 위한 값.
    @State private var shellGeneration = 0

    /// 화면 확인용: `-preview.terminal shell` 로 셸 하위 탭을 열고 시작한다 (Debug · AHC_OFFLINE=1).
    private static var initialSub: Sub {
        #if DEBUG
        if AppModel.offlinePreview,
           UserDefaults.standard.string(forKey: "preview.terminal") == "shell" { return .shell }
        #endif
        return .agent
    }

    var body: some View {
        VStack(spacing: 0) {
            tabs
            switch sub {
            case .agent: AgentCommandLog()
            case .shell: shell
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            subTab(.shell) {
                Image(systemName: "terminal").font(.system(size: 11))
                // 실제로 띄우는 셸의 이름 ($SHELL — `ShellTerminalStore.view`), 폴더는 지금 셸이 도는 폴더의 이름 (chg-20).
                Text(Self.shellName).font(Theme.mono(.caption, .semibold))
                Text(model.workspace.projectURL?.lastPathComponent ?? "").font(Theme.mono(.caption)).foregroundStyle(Theme.slate2)
                    .lineLimit(1)
                    .help(model.workspace.projectPath.map(Fmt.abbreviatedPath) ?? "")
            }
            subTab(.agent) {
                HStack(spacing: -3) {
                    BrandMark(provider: .claude, size: 11)
                    BrandMark(provider: .codex, size: 11)
                }
                Text("에이전트 실행").font(Theme.mono(.caption))
                Text("읽기 전용")
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate2)
                    .padding(.horizontal, 5)
                    .frame(height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hair))
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hair).frame(height: 1) }
    }

    /// 셸 하위 탭의 이름 — 사용자의 로그인 셸 ($SHELL 의 마지막 이름, 없으면 zsh).
    static var shellName: String {
        (ProcessInfo.processInfo.environment["SHELL"].map { ($0 as NSString).lastPathComponent }).flatMap { $0.isEmpty ? nil : $0 } ?? "zsh"
    }

    private func subTab<Label: View>(_ value: Sub, @ViewBuilder label: () -> Label) -> some View {
        let selected = sub == value
        return Button {
            sub = value
        } label: {
            HStack(spacing: 6) { label() }
                .foregroundStyle(selected ? Theme.ink : Theme.slate)
                .padding(.horizontal, 9)
                .frame(height: 25)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6).fill(Theme.card)
                            .shadow(color: Theme.shadow.opacity(0.05), radius: 1, y: 1)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hair))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 앱 안에서 도는 사용자 셸 (SwiftTerm · PTY).
    ///
    /// 세션은 프로젝트 폴더마다 하나이고 탭을 옮겨도 살아 있다.
    /// **앱은 이 터미널의 입력·출력을 저장하거나 에이전트에게 보내지 않는다.**
    @ViewBuilder
    private var shell: some View {
        if let root = model.workspace.projectURL {
            VStack(spacing: 0) {
                ShellTerminalView(directory: root.path, environment: shellEnvironment)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 8) {
                    Text("이 셸의 내용은 앱이 저장하지 않습니다")
                        .font(Theme.ui(.caption)).foregroundStyle(Theme.slate2)
                    Spacer()
                    Button("새로 시작") {
                        ShellTerminalStore.shared.close(root.path)
                        shellGeneration += 1
                    }
                    .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
                    Button("macOS 터미널로 열기") { TerminalLauncher.open(root) }
                        .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.card)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
            }
            .id("\(root.path)|\(shellGeneration)")
            .background(Theme.paper)
        } else {
            QuietEmptyState(systemImage: "terminal", title: "프로젝트를 선택하세요",
                            detail: "대화가 일하는 폴더(프로젝트 폴더 또는 독립 작업 폴더)에서 셸을 엽니다.")
                .padding(.top, 30)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Theme.paper)
        }
    }

    /// 셸에 넘길 환경. CLI 탐색과 같은 PATH 를 쓰되, 셸은 대화형이라 TERM 은 셸 뷰에서 다시 정한다.
    /// 앱을 에이전트 세션이 띄웠으면 그 세션의 변수는 빼고 (`CLIEnvironment.inheritable` — 이 셸에서 돌린 `claude` 가 그 세션의 일부로 기록되지 않게).
    private var shellEnvironment: [String: String] {
        CLIEnvironment.inheritedEnvironment
    }
}

/// 이 대화에서 에이전트가 실행한 명령 (앱이 대신 실행한 git 명령도 — "앱" 표시). 프롬프트 줄 + 명령 + 출력 (터미널 흉내, 읽기 전용).
private struct AgentCommandLog: View {
    @Environment(AppModel.self) private var model
    @State private var commands: [ExecutionEntry] = []
    /// 그리는 최근 명령 수. 더 오래된 명령은 맨 위 버튼으로 불러온다.
    /// 응답 스트리밍 델타마다 이 창의 텍스트가 다시 그려져(실측) 비용이 그려 둔 명령 수에 비례한다. 40개는 과했다.
    @State private var commandLimit = AgentCommandLog.commandPage
    private static let commandPage = 20

    var body: some View {
        let hiddenCount = max(0, commands.count - commandLimit)
        ScrollViewReader { proxy in
            ScrollView {
                // 대화 스트림과 같은 이유로 LazyVStack 을 쓰지 않는다 (펼친 긴 출력이 섞이면 스크롤 중 멈춘다).
                VStack(alignment: .leading, spacing: 9) {
                    if commands.isEmpty {
                        QuietEmptyState(systemImage: "terminal",
                                        title: "실행한 명령이 없습니다",
                                        detail: "이 대화에서 에이전트가 셸 명령을 실행하면 여기에 순서대로 남습니다.")
                            .padding(.top, 20)
                    }
                    let shown = commands.suffix(commandLimit)
                    if hiddenCount > 0 {
                        Button("⌃ 이전 명령 \(hiddenCount)개 더 보기") {
                            // 새 명령이 위에 붙어도 읽던 명령이 그 자리에 남도록 이전 첫 명령을 위에 맞춘다.
                            // 배치가 끝난 다음 런루프에서 맞춰야 한다 (ThreadView.showOlderRows 참고).
                            let anchorID = shown.first?.id
                            commandLimit += Self.commandPage
                            if let anchorID {
                                DispatchQueue.main.async { proxy.scrollTo(anchorID, anchor: .top) }
                            }
                        }
                        .buttonStyle(TextButtonStyle(color: Theme.slate2, font: Theme.mono(.caption)))
                        .padding(.horizontal, 12)
                    }
                    ForEach(shown) { entry in
                        if case .command(let info) = entry.kind {
                            // 프롬프트 경로는 그 명령이 돈 폴더 (기록의 cwd). 없으면 지금 폴더 — 독립 작업 폴더로 옮기기 전의 명령이
                            // 지금 폴더에서 돈 것처럼 보이지 않게, 프로젝트 이름을 붙여 없는 경로를 만들지 않는다 (chg-20).
                            let place = Self.promptPlace(cwd: info.cwd, fallback: model.workspace.projectPath)
                            CommandBlock(info: info, provider: entry.provider, time: entry.createdAt,
                                         projectName: place.name, projectParent: place.parent)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
            .background(Theme.paper)
            // 명령 목록은 이벤트가 추가될 때 · 백그라운드 명령의 상태가 바뀔 때만 바뀐다. 응답 스트리밍 델타(마지막 이벤트
            // 본문 변화)마다 전체를 다시 파싱하면 긴 스레드에서 스트리밍 반응성이 절반으로 떨어진다.
            .task(id: commandsKey) {
                let log = model.events.filter { $0.kind == .commandExecution || $0.kind == .toolRequest
                    || $0.kind == .toolResult }
                let entries = ExecutionParser.entries(from: log, projectPath: model.workspace.projectPath)
                    .filter { if case .command = $0.kind { return true } else { return false } }
                // Claude 의 백그라운드 명령은 앵커 결과("뒤에서 시작함")만으로는 끝난 것처럼 보인다 — 작업 상태를 입힌다.
                let pane = model.selectedThreadID.flatMap { model.threadStates[$0] }
                commands = TerminalCommands.applyingShellStatus(
                    to: entries, stored: pane?.subAgentInfos ?? [:], runIDs: pane?.subAgentRunIDs ?? [:],
                    runs: pane?.runsByID ?? [:], live: session?.subAgents ?? [], liveRunIDs: liveRunIDs(pane))
                proxy.scrollTo("end", anchor: .bottom)
            }
            .onChange(of: model.selectedThreadID) { commandLimit = Self.commandPage }
        }
    }

    /// 포커스 대화에서 지금 도는 실행.
    private var session: RunSession? { model.selectedThreadID.flatMap { model.runner.session(threadID: $0) } }

    /// 다시 만들 때: 대화 · 이벤트 수 · 하위 쪽 수정 번호(저장된 작업 상태) · 도는 실행 · 그 실행의 끝나지 않은 작업 수.
    /// 살아 있는 작업 목록(`subAgents`)은 본문에서 읽지 않는다 — 진행(초당 여러 번)마다 이 탭을 다시 그리지 않게.
    private var commandsKey: String {
        let threadID = model.selectedThreadID ?? ""
        let revision = model.threadStates[threadID]?.subAgentRevision ?? 0
        return "\(threadID)|\(model.events.count)|\(revision)|\(session?.activeRun?.id ?? "")|\(session?.unfinishedSubAgentCount ?? 0)"
    }

    /// 셸을 띄운 실행 중 지금 세션이 도는 것 (여기에 없는 실행의 `running` 셸은 끝나지 않은 채 멈춘 것).
    private func liveRunIDs(_ pane: ThreadPaneModel?) -> Set<String> {
        var out = Set<String>()
        if let pane {
            for runID in Set(pane.subAgentRunIDs.values) where pane.runsByID[runID]?.state.isTerminal != true {
                if model.liveSession(runID: runID) != nil { out.insert(runID) }
            }
        }
        if let live = session?.activeRun?.id { out.insert(live) }
        return out
    }

    /// 프롬프트 줄의 "상위 경로/" + "폴더 이름". 명령의 cwd 가 있으면 그것, 없으면 지금 폴더.
    static func promptPlace(cwd: String?, fallback: String?) -> (parent: String, name: String) {
        guard let path = cwd.flatMap({ $0.isEmpty ? nil : $0 }) ?? fallback else { return ("", "") }
        let parent = Fmt.abbreviatedPath((path as NSString).deletingLastPathComponent)
        return (parent.hasSuffix("/") ? parent : parent + "/", (path as NSString).lastPathComponent)
    }
}

private struct CommandBlock: View {
    let info: CommandInfo
    let provider: AgentProvider?
    let time: Date
    let projectName: String
    let projectParent: String
    @State private var expanded = false

    private var lines: [Substring] {
        (info.output ?? "").split(separator: "\n", omittingEmptySubsequences: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let provider {
                    BrandMark(provider: provider, size: 10)
                } else {
                    // 에이전트가 아니라 앱이 (사람 대신) 실행한 명령 — 변경사항 탭의 git · 독립 작업 폴더 명령 (chg-18).
                    Text("앱")
                        .font(Theme.ui(.caption, .semibold))
                        .foregroundStyle(Theme.slate)
                        .padding(.horizontal, 4)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.hair))
                        .help("앱이 실행한 명령 (변경사항 탭의 git 동작 · 독립 작업 폴더 명령)")
                }
                Text("\(Text(projectParent).foregroundStyle(Theme.slate))\(Text(projectName).foregroundStyle(Theme.ink).fontWeight(.semibold))")
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 6)
                status
                Text("│").foregroundStyle(Theme.slate3)
                Text(Fmt.time.string(from: time)).foregroundStyle(Theme.slate2)
            }
            .padding(.horizontal, 12)
            .background(Theme.promptBar)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("❯").foregroundStyle(Theme.slate3)
                Text(info.command).foregroundStyle(Theme.ink2).textSelection(.enabled)
            }
            .padding(.horizontal, 12)

            if !lines.isEmpty {
                let shown = expanded ? lines[...] : lines.suffix(8)
                Text(shown.joined(separator: "\n"))
                    .foregroundStyle(info.failed ? Theme.ink2 : Theme.slate)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                if lines.count > 8 {
                    Button(expanded ? "⌃ 접기" : "⌄ 앞의 \(lines.count - 8)줄 더") { expanded.toggle() }
                        .buttonStyle(TextButtonStyle(color: Theme.slate2, font: Theme.mono(.caption)))
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                }
            }
        }
        .font(Theme.mono(.caption))
        .lineSpacing(2.5)
    }

    @ViewBuilder
    private var status: some View {
        if let approval = info.approval {
            // 승인과 이어진 명령 — 승인 대기는 아직 실행 전, 거절 · 거둠은 실행되지 않았다 (대화의 명령 행과 같은 말).
            Text(approval.label).foregroundStyle(approval == .awaiting ? Theme.amberText : Theme.slate)
        } else if info.running {
            Text("실행 중").foregroundStyle(Theme.amberText)
        } else if info.stopped {
            Text("멈춤").foregroundStyle(Theme.slate)
                .help("명령이 끝나기 전에 멈췄습니다 (실행 중단과 함께)")
        } else if let code = info.exitCode {
            Text("종료 \(code)").foregroundStyle(code == 0 ? Theme.emeraldText : Theme.danger)
        } else if info.reportedError {
            Text("오류").foregroundStyle(Theme.danger)
        } else {
            Text("종료 코드 미확인").foregroundStyle(Theme.slate2)
                .help("Claude 의 셸 도구는 종료 코드를 보고하지 않습니다")
        }
    }
}
