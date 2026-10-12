import SwiftUI
import AppKit

/// 설정 > 에이전트: 에이전트마다 카드 하나 (Claude Code · Codex · Antigravity).
/// 카드 머리의 상태는 첫 실행 점검표와 같은 판정(`AppModel.firstRunFacts`)이다. 쓸 수 없으면(설치 안 됨 · 지정한 경로 오류) 다음에 할 일
/// 하나와 실행 파일 칸만 보이고, 승인 · 추론 강도 같은 설정은 쓸 수 있게 된 뒤에 나타난다. 카드의 ↻ 와 실행 파일 경로는 그 에이전트만
/// 다시 확인하고(`AppModel.recheckAgent`), 그동안 그 카드만 "확인 중" 이다. 모두 다시 확인하는 단추는 맨 위에.
struct AgentSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let facts = model.firstRunFacts
        Form {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    Text(SettingsText.agentsIntro)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("모두 다시 확인") { Task { await model.recheckAllAgents() } }
                        .disabled(model.recheckingAgents.count == AgentProvider.allCases.count)
                        .help("로그인 셸의 PATH 부터 다시 읽고 세 에이전트를 모두 확인합니다")
                }
            }
            ClaudeAgentSection(agent: facts.claude)
            CodexAgentSection(agent: facts.codex)
            AntigravityAgentSection(agent: facts.antigravity)
            NewThreadApprovalSection()
            ShellAuthSection()
        }
        .formStyle(.grouped)
        // Antigravity 의 모델 목록(`agy models` — Google 과 통신)은 여기서 읽지 않는다 — 이 탭은 쓰지 않는다 (set-20).
        .task { await model.refreshAgentFacts() }
    }
}

// MARK: - 새 대화의 승인

/// 새로 만드는 대화를 자동 승인으로 시작할지 (기본 꺼짐). 켤 때 한 번 확인한다 — 입력창 승인 칩의 확인과 같은 말
/// (`ApprovalPolicyText.newThreadAutoApprovalConfirmation`). 끄는 것은 묻지 않는다.
private struct NewThreadApprovalSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        Section {
            SettingsToggleRow(title: SettingsText.newThreadAutoApprovalTitle, subtitle: SettingsText.newThreadAutoApprovalNote,
                              isOn: Binding(get: { model.newThreadsAutoApprove }, set: { on in
                                  if on {
                                      confirming = true
                                  } else {
                                      confirming = false
                                      model.newThreadsAutoApprove = false
                                  }
                              }))
            if confirming && !model.newThreadsAutoApprove {
                SettingsWarning(title: SettingsText.newThreadAutoApprovalConfirmTitle,
                                text: ApprovalPolicyText.newThreadAutoApprovalConfirmation) {
                    HStack(spacing: 8) {
                        Spacer()
                        Button("취소") { confirming = false }
                        Button("켜기") {
                            confirming = false
                            model.newThreadsAutoApprove = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.amberFill)
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            Text("승인")
        }
    }
}

// MARK: - 셸의 API 키

/// 셸(`~/.zshrc`)의 API 키 · 토큰을 에이전트에게 넘길지 (onb-19 — 기본 꺼짐). 지금 셸에 무엇이 있는지와 넘어가는지를 한 줄로.
private struct ShellAuthSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            SettingsToggleRow(title: SettingsText.shellAuthTitle, subtitle: SettingsText.shellAuthNote,
                              isOn: $model.forwardShellAuth)
            SettingsFooter(SettingsText.shellAuthStatus(found: model.shellAuthVariables, forwarding: model.forwardShellAuth))
        }
    }
}

// MARK: - 카드 머리 · 다음에 할 일

/// 카드 머리: 로고 · 이름 · 버전 등 · 상태 · 다시 확인. ↻ 는 이 에이전트만 다시 확인한다 (로그인 셸 PATH 부터 — 방금 설치했을 수 있다).
private struct AgentCardHeader: View {
    @Environment(AppModel.self) private var model
    let provider: AgentProvider
    let name: String
    var optional = false
    let meta: String
    let readiness: AgentReadiness

    var body: some View {
        let checking = model.recheckingAgents.contains(provider)
        HStack(spacing: 12) {
            BrandMark(provider: provider, size: 19)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(name).font(Theme.ui(.body, .semibold))
                    if optional {
                        Text("선택 사항").font(Theme.ui(.caption)).foregroundStyle(.secondary)
                    }
                }
                Text(meta)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            AgentStatusPill(readiness: checking ? .checking : readiness, optional: optional)
            IconButton(systemName: "arrow.clockwise", size: 12, color: Theme.control, help: "\(name) 다시 확인",
                       spinning: checking) {
                Task { await model.recheckAgent(provider, rereadLoginPath: true) }
            }
            .disabled(checking)
        }
        .padding(.vertical, 2)
    }
}

/// 준비되지 않은 에이전트의 다음에 할 일 (첫 실행 점검표와 같은 안내 — 앱은 설치 · 로그인을 대신하지 않고 명령을 복사만 한다).
private struct AgentNextStep: View {
    @Environment(AppModel.self) private var model
    let provider: AgentProvider
    let readiness: AgentReadiness
    var loginCommand: String?
    let resetPath: () -> Void

    var body: some View {
        // 다시 확인하는 동안은 옛 결과로 할 일을 말하지 않는다 — 맞는 실행 파일을 고른 순간 "실행할 수 없습니다" 가 뜨던 것 (set-1).
        switch model.recheckingAgents.contains(provider) ? .checking : readiness {
        case .notInstalled:
            VStack(alignment: .leading, spacing: 8) {
                // Antigravity CLI(agy)는 인계 문서를 Gemini 로 다듬을 때도 쓴다 — 설정 > 인계가 이 카드로 보낸다 (set-14).
                note(provider == .gemini ? SettingsText.antigravityMissingNote : Self.installNote)
                HStack(spacing: 8) {
                    if let url = AgentSetupGuide.docsURL(provider) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 4) {
                                Text(provider == .gemini ? "Antigravity 안내 열기" : "설치 안내 열기")
                                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                            }
                        }
                        .help(url.absoluteString)
                    }
                    if let command = AgentSetupGuide.installCommand(provider) {
                        CopyableCommand(command: command)
                    }
                }
            }
        case .pathInvalid where model.pathOverride(provider) != nil:
            HStack(spacing: 10) {
                note("직접 지정한 실행 파일을 실행할 수 없습니다. 자동으로 찾게 되돌리거나 아래 ‘실행 파일’에서 다른 파일을 고르세요.")
                Spacer(minLength: 6)
                Button("자동으로 찾기로 되돌리기", action: resetPath)
            }
        case .pathInvalid:
            // 지정하지 않았는데 실행할 수 없다 — 자동으로 찾은 파일이 돌지 않는다 (예: node 를 찾지 못함). CLI 의 오류 글을 그대로 보이고
            // 위치를 지정하게 한다 (점검표와 같은 안내).
            VStack(alignment: .leading, spacing: 6) {
                note(Self.brokenNote(provider))
                if let error = model.cliStatus[provider]?.error {
                    Text(error)
                        .font(Theme.mono(.caption))
                        .foregroundStyle(Theme.ink2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .notLoggedIn:
            VStack(alignment: .leading, spacing: 8) {
                note("터미널에서 이 명령으로 로그인한 뒤 위의 ↻ 를 누르세요. 앱은 로그인을 대신하지 않습니다.")
                if let loginCommand { CopyableCommand(command: loginCommand) }
            }
        case .loginUnknown where provider != .gemini:
            VStack(alignment: .leading, spacing: 8) {
                note("로그인 상태를 확인하지 못했습니다. 로그인돼 있으면 그대로 써도 됩니다.")
                if let loginCommand { CopyableCommand(command: loginCommand) }
            }
        default:
            EmptyView()
        }
    }

    private static let installNote: String =
        "설치하면 여기서 바로 쓸 수 있습니다. 설치한 뒤 위의 ↻ 를 누르세요. 이미 설치했다면 아래 ‘실행 파일’에서 위치를 지정합니다."

    private static func brokenNote(_ provider: AgentProvider) -> String {
        let binary: String
        switch provider {
        case .claude: binary = "claude"
        case .codex: binary = "codex"
        case .gemini: binary = "agy"
        }
        return "찾은 실행 파일이 돌지 않습니다. node 같은 런타임을 nvm · mise 로 설치했다면 터미널에서 which \(binary) 로 위치를 확인해 "
            + "아래 ‘실행 파일’에 지정하세요."
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(.caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 실행 파일 위치 (펼침). 비워 두면 로그인 셸의 PATH 에서 찾는다. 앱은 사용자의 셸 설정을 고치지 않는다.
/// 칸에 치는 동안은 저장 · 확인하지 않는다 — 편집이 끝날 때(↵ · 칸을 떠남 · [찾기…] · 탭을 닫음 · ↻ 등 다시 확인이 시작됨) 사람이 칸의
/// 글을 고쳤을 때만 한 번 바꾸고, 앱이 그 에이전트만 다시 확인한다 (`AppModel.pathOverrideChanged` → `recheckAgent`). 그동안 카드는
/// "확인 중" 이다 (set-1). 밖에서 바뀐 경로([자동으로 찾기로 되돌리기])는 칸이 늘 따라간다 — 칸의 옛 글로 다시 덮지 않는다
/// (`ExecutablePathField`, set-n1).
private struct ExecutablePathDisclosure: View {
    @Environment(AppModel.self) private var model
    let provider: AgentProvider
    @Binding var path: String
    var note: String?
    @State private var expanded = false
    /// 칸의 글과 마지막으로 맞춘 경로 — 편집이 끝날 때 고친 글만 `path` 로 옮긴다.
    @State private var field = ExecutablePathField()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let status = model.cliStatus[provider]
        let checking = model.recheckingAgents.contains(provider)
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    TextField("자동으로 찾기 (비워 두기)", text: $field.draft)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.mono(.caption))
                        .autocorrectionDisabled()
                        .focused($fieldFocused)
                        .onSubmit(commit)
                        .accessibilityLabel("\(provider.displayName) 실행 파일 경로")
                    Button("찾기…") {
                        if let chosen = SettingsActions.choose(directories: false, message: "CLI 실행 파일을 고르세요.") {
                            field.draft = chosen
                            commit()
                        }
                    }
                }
                Text(ExecutablePathText.statusLine(status, checking: checking))
                    .font(Theme.mono(.caption))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Finder 에서 연 앱은 터미널과 PATH 가 다를 수 있습니다. 자동으로 찾지 못할 때만 지정하세요.")
                    .font(Theme.ui(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                Text("실행 파일")
                Spacer(minLength: 8)
                Text(ExecutablePathText.summary(status: status, override: path, checking: checking))
                    .font(Theme.mono(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .onAppear {
            field = ExecutablePathField(path: path)
            // 지정한 경로가 실행되지 않으면 고칠 칸을 펴 둔다.
            if model.firstRunFacts.agent(provider).readiness == .pathInvalid { expanded = true }
        }
        // 다른 곳에서 바꾼 값([자동으로 찾기로 되돌리기] 등) — 칸의 포커스와 상관없이 칸도 따라간다 (set-n1: 포커스가 남은 칸이 따라가지
        // 않아, 칸을 떠나거나 창을 닫으면 틀린 경로가 다시 저장됐다).
        .onChange(of: path) { _, value in field.pathChanged(to: value) }
        .onChange(of: fieldFocused) { _, focused in if !focused { commit() } }
        // 다시 확인(↻ · 모두 다시 확인)이 시작되면 칸에 고치다 만 경로를 먼저 옮긴다 — ↵ 없이 ↻ 를 누르면 옛 경로를 확인했다.
        // 옮긴 경로의 확인이 뒤에 다시 돈다 (늦게 끝난 옛 경로의 결과는 앱이 버린다 — `CLIEnvironment.isCurrent`).
        .onChange(of: checking) { _, now in if now { commit() } }
        .onDisappear(perform: commit)
    }

    /// 편집이 끝났다 — 사람이 칸의 글을 고쳤을 때만(앞뒤 공백을 떼고 `~` 를 푼 값으로) 바꾼다. 바뀐 값은 모델이 저장하고 다시 확인한다.
    /// 밖에서 바뀐 경로를 칸이 아직 받지 못했으면 그 값이 이긴다 (`ExecutablePathField.commit(current:)`).
    private func commit() {
        guard let value = field.commit(current: path), value != path else { return }
        path = value
    }
}

// MARK: - 승인 · 기본 추론 강도

/// "승인" 줄의 머리 — 제목과 물음.
private struct ApprovalHeading: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("승인").fontWeight(.semibold)
            Text("일을 맡길 때 얼마나 물어볼까요?")
                .font(Theme.ui(.caption))
                .foregroundStyle(.secondary)
        }
    }
}

/// 고른 승인 방식의 설명 한 줄 — 입력창 칩과 같은 문구(`ApprovalPolicyText`). 경고색은 묻지 않고 넓게 실행할 때.
private struct ApprovalPolicyNote: View {
    let policy: ApprovalPolicyText
    var isStandard = false
    /// 선택지 넷(셋)에 없는 조합 — CLI 값으로 직접 고른 것.
    var custom = false

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: policy.caution ? "exclamationmark.triangle.fill" : policy.systemImage)
                .font(.system(size: 11))
                .foregroundStyle(policy.caution ? Theme.amber : Theme.slate)
                .frame(width: 14)
                .padding(.top, 1)
            (Text(custom ? "직접 설정 — \(policy.title). \(policy.detail)" : policy.detail)
                + Text(isStandard ? "  · 기본값" : "").foregroundStyle(Theme.slate))
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Claude 의 승인: 세그먼트는 확인한 방식 둘(승인 묻기 · 편집은 자동). "계획만" 은 앱에서 확인하지 않은 방식이라 "자세히" 안에
/// 실험으로 둔다 — 안전해 보여 맨 앞에서 고르기 쉬웠는데, 계획 뒤 실행으로 넘어가는지 모르고 모든 대화에 적용된다 (set-7).
private struct ClaudeApprovalRow: View {
    @Environment(AppModel.self) private var model
    @State private var experimentalExpanded = false

    var body: some View {
        let preset = ClaudeApprovalPreset.matching(model.claudePermissionMode)
        let policy = ApprovalPolicyText.policy(provider: .claude, claudePermissionMode: model.claudePermissionMode,
                                               codexApprovalPolicy: model.codexApprovalPolicy,
                                               codexSandboxMode: model.codexSandboxMode)
        VStack(alignment: .leading, spacing: 9) {
            ApprovalHeading()
            Picker("Claude 승인 방식", selection: Binding<ClaudeApprovalPreset?>(get: { () -> ClaudeApprovalPreset? in
                // "계획만"(실험)이면 세그먼트는 아무것도 고르지 않은 채로 둔다 — 그 스위치는 "자세히" 안에.
                guard let preset, !preset.isExperimental else { return nil }
                return preset
            }, set: { (chosen: ClaudeApprovalPreset?) in
                if let chosen { model.claudePermissionMode = chosen.rawValue }
            })) {
                ForEach(ClaudeApprovalPreset.mainChoices) { Text($0.title).tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ApprovalPolicyNote(policy: policy, isStandard: preset == .standard, custom: preset == nil)
            DisclosureGroup(isExpanded: $experimentalExpanded) {
                SettingsToggleRow(title: ClaudeApprovalPreset.plan.title, subtitle: ClaudeApprovalPreset.planNote, tag: "실험",
                                  isOn: Binding<Bool>(get: { () -> Bool in preset == .plan }, set: { (on: Bool) in
                                      let next: ClaudeApprovalPreset = on ? .plan : .standard
                                      model.claudePermissionMode = next.rawValue
                                  }))
                    .padding(.top, 6)
            } label: {
                Text("자세히 — 확인하지 않은 방식").font(Theme.ui(.caption))
            }
        }
        .padding(.vertical, 4)
        .onAppear { if preset == .plan { experimentalExpanded = true } }
    }
}

/// Codex 의 승인: 쉬운 말 선택지 넷 + "자세히" 의 CLI 값(샌드박스 · 승인 정책). 전체 접근으로 넓힐 때는 한 번 더 확인받는다 —
/// 확인 글은 고르려는 조합의 실제 정책대로 쓰고(`CodexApprovalPreset.confirmationText`), 확인을 기다리는 동안 바꾼 값은 그 확인에
/// 합친다 (set-11 — 예전에는 승인 정책을 바꾸면 확인하지 않은 요청이 말없이 사라졌다).
private struct CodexApprovalRow: View {
    @Environment(AppModel.self) private var model
    @State private var pending: Pending?
    @State private var rawExpanded = false

    private struct Pending: Equatable {
        var sandbox: String
        var approval: String
    }

    var body: some View {
        let sandbox: String = model.codexSandboxMode, approval: String = model.codexApprovalPolicy
        // 확인을 기다리는 동안은 고르려는 값을 보인다 (세그먼트 · 자세히 모두).
        let shownSandbox: String = pending?.sandbox ?? sandbox
        let shownApproval: String = pending?.approval ?? approval
        let preset: CodexApprovalPreset? = CodexApprovalPreset.matching(sandbox: shownSandbox, approvalPolicy: shownApproval)
        let policy = ApprovalPolicyText.policy(provider: .codex, claudePermissionMode: model.claudePermissionMode,
                                               codexApprovalPolicy: approval, codexSandboxMode: sandbox)
        VStack(alignment: .leading, spacing: 9) {
            ApprovalHeading()
            Picker("Codex 승인 방식", selection: Binding(get: { preset }, set: { chosen in
                guard let chosen else { return }
                request(sandbox: chosen.sandbox, approval: chosen.approvalPolicy)
            })) {
                ForEach(CodexApprovalPreset.allCases) { Text($0.title).tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let pending {
                SettingsWarning(title: "Codex 에게 전체 접근을 줄까요?",
                                text: CodexApprovalPreset.confirmationText(sandbox: pending.sandbox, approvalPolicy: pending.approval),
                                tone: Theme.danger) {
                    HStack(spacing: 8) {
                        Spacer()
                        Button("취소") { self.pending = nil }
                        Button("전체 접근 켜기") { apply(pending) }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.danger)
                    }
                    .controlSize(.small)
                }
            } else {
                ApprovalPolicyNote(policy: policy, isStandard: preset == .standard, custom: preset == nil)
            }
            DisclosureGroup(isExpanded: $rawExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("샌드박스", selection: Binding<String>(get: { shownSandbox }, set: { (value: String) in
                        let pendingApproval: String = pending?.approval ?? approval
                        request(sandbox: value, approval: pendingApproval)
                    })) {
                        Text("workspace-write — 대화의 폴더에 쓰기").tag("workspace-write")
                        Text("read-only — 읽기만").tag("read-only")
                        Text("danger-full-access — 전체 접근").tag("danger-full-access")
                    }
                    Picker("승인 정책", selection: Binding<String>(get: { shownApproval }, set: { (value: String) in
                        let pendingSandbox: String = pending?.sandbox ?? sandbox
                        request(sandbox: pendingSandbox, approval: value)
                    })) {
                        Text("on-request — Codex 가 필요하다고 볼 때 묻기").tag("on-request")
                        Text("untrusted — 안전한 명령 말고는 묻기").tag("untrusted")
                        Text("never — 묻지 않기").tag("never")
                    }
                    Text(SettingsText.codexRawApprovalNote)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            } label: {
                Text("자세히 — CLI 값으로 고르기").font(Theme.ui(.caption))
            }
        }
        .padding(.vertical, 4)
    }

    private func request(sandbox: String, approval: String) {
        if CodexApprovalPreset.needsConfirmation(fromSandbox: model.codexSandboxMode, toSandbox: sandbox) {
            pending = Pending(sandbox: sandbox, approval: approval)
        } else {
            apply(Pending(sandbox: sandbox, approval: approval))
        }
    }

    private func apply(_ change: Pending) {
        pending = nil
        model.codexSandboxMode = change.sandbox
        model.codexApprovalPolicy = change.approval
    }
}

/// 기본 추론 강도 — 새로 정하는 대화가 쓴다 (`AppModel.defaultEfforts`, 마지막에 쓴 대화를 이어받지 않을 때). 이미 쓴 대화는 바꿔도
/// 그대로다 (`AppModel.setDefaultEffort`, set-n2). `modelDefault` 면 맨 앞에 "모델 기본값" 선택지 — 고르지 않은 상태(저장값 없음)이고,
/// Codex 는 계정의 config.toml → 그 모델의 기본 강도로 정한다.
private struct DefaultEffortRow: View {
    @Environment(AppModel.self) private var model
    let provider: AgentProvider
    let efforts: [String]
    var modelDefault = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("기본 추론 강도").fontWeight(.semibold)
            Picker("\(provider.displayName) 기본 추론 강도", selection: Binding(
                get: { modelDefault ? (model.userDefaultEffort(for: provider) ?? "") : model.defaultEffort(for: provider) },
                set: { model.setDefaultEffort($0, for: provider) })) {
                if modelDefault { Text("모델 기본값").tag("") }
                ForEach(efforts, id: \.self) { Text(EffortScale.name(of: $0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(SettingsText.defaultEffortNote(provider: provider))
                .font(Theme.ui(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Claude Code

private struct ClaudeAgentSection: View {
    @Environment(AppModel.self) private var model
    let agent: FirstRunFacts.Agent

    var body: some View {
        @Bindable var model = model
        let usable = agent.readiness != .notInstalled && agent.readiness != .pathInvalid
        Section {
            AgentCardHeader(provider: .claude, name: "Claude Code", meta: meta, readiness: agent.readiness)
            if agent.readiness != .ready, agent.readiness != .checking {
                AgentNextStep(provider: .claude, readiness: agent.readiness,
                              loginCommand: AgentSetupGuide.claudeLoginCommand,
                              resetPath: { model.claudePathOverride = "" })
            }
            if usable {
                ClaudeApprovalRow()
                DefaultEffortRow(provider: .claude, efforts: ModelCatalog.claudeDefaultChoices)
                SettingsToggleRow(title: "앱을 열 때 사용 한도 확인",
                                  subtitle: "끄면 Claude 와 대화하기 전까지 한도가 ‘확인 전’으로 보입니다. 툴바의 한도에서 언제든 새로고침할 수 있습니다.",
                                  help: "확인할 때 Claude Code 가 잠깐 실행되며(claude -p /usage), 설정해 둔 훅 · MCP 서버도 함께 뜹니다. "
                                    + "그때 나오는 macOS 권한 요청은 이 앱이 아니라 Claude CLI 쪽에서 온 것이고, 거절해도 한도 확인 말고는 "
                                    + "영향이 없습니다. 끄면 이어 가기 제안 · 한도 안내도 Claude 한도를 스스로 읽지 않아, 확인된 값이 없는 동안 "
                                    + "Claude 를 받는 쪽에서 건너뜁니다. Codex 한도 확인은 세션을 띄우지 않아 늘 합니다.",
                                  isOn: $model.startupFetchClaudeLimits)
                ClaudeAPIKeyRow()
            }
            ExecutablePathDisclosure(provider: .claude, path: $model.claudePathOverride)
        }
    }

    /// 버전만 짧게 ("v2.1.283") — 이름은 머리에, 로그인은 알약에 있다 (예전 "2.1.283 (Claude Code) · 로그인됨" 은 둘 다 겹쳤다, set-23).
    private var meta: String {
        AgentCardMeta.text(agent: agent, binary: "claude", checking: model.recheckingAgents.contains(.claude))
    }
}

/// Claude API 키 — Max · Team 플랜의 월 API 크레딧 (`AppModel+ClaudeAPI` · `ClaudeAPIKey`). 키는 키체인에만, 화면에는 끝 네 글자만.
/// 넣은 뒤로는 모델 칩 팝오버의 "API 크레딧으로 실행" 을 대화마다 켤 수 있다.
private struct ClaudeAPIKeyRow: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var problem: String?
    @State private var confirmingDelete = false

    var body: some View {
        SettingsRow(title: SettingsText.claudeAPIKeyTitle, subtitle: SettingsText.claudeAPIKeyNote,
                    help: SettingsText.claudeAPIKeyHelp) {
            if let hint = model.claudeAPIKeyHint {
                HStack(spacing: 8) {
                    Text(hint)
                        .font(Theme.mono(.caption))
                        .foregroundStyle(Theme.ink2)
                        .accessibilityLabel("저장된 키, 끝 네 글자 \(String(hint.suffix(4)))")
                    Button("지우기…") { confirmingDelete = true }
                }
            } else {
                HStack(spacing: 6) {
                    SecureField("sk-ant-…", text: $draft)
                        .frame(width: 180)
                        .onSubmit(save)
                    Button("저장", action: save)
                        .disabled(ClaudeAPIKey.normalized(draft).isEmpty)
                }
            }
        }
        .confirmationDialog(SettingsText.claudeAPIKeyDeleteConfirm, isPresented: $confirmingDelete) {
            Button("지우기", role: .destructive) { model.deleteClaudeAPIKey(); problem = nil }
            Button("취소", role: .cancel) {}
        }
        if let problem {
            Text(problem)
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.amberText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        problem = model.saveClaudeAPIKey(draft)
        if problem == nil { draft = "" }
    }
}

/// 카드 머리 아래 줄 — 버전(짧게)과 그 에이전트만의 사실 하나. 이름 · 상태는 머리와 알약이 말한다.
private enum AgentCardMeta {
    static func text(agent: FirstRunFacts.Agent, binary: String, extra: String? = nil, checking: Bool) -> String {
        switch checking ? .checking : agent.readiness {
        case .checking: return "확인 중"
        case .notInstalled: return "이 Mac 에서 \(binary) 를 찾지 못했습니다"
        case .pathInvalid: return "실행 파일을 실행할 수 없습니다"
        default:
            var text: String = AgentVersionText.short(agent.version) ?? "버전 미확인"
            if let extra { text += " · " + extra }
            return text
        }
    }
}

// MARK: - Codex

private struct CodexAgentSection: View {
    @Environment(AppModel.self) private var model
    let agent: FirstRunFacts.Agent

    var body: some View {
        @Bindable var model = model
        let usable = agent.readiness != .notInstalled && agent.readiness != .pathInvalid
        Section {
            AgentCardHeader(provider: .codex, name: "Codex", meta: meta, readiness: agent.readiness)
            // 로그인 안내는 계정 줄마다 있다 (계정마다 따로 로그인한다) — 머리 아래에는 설치 · 경로만.
            if agent.readiness == .notInstalled || agent.readiness == .pathInvalid {
                AgentNextStep(provider: .codex, readiness: agent.readiness,
                              resetPath: { model.codexPathOverride = "" })
            }
            if usable {
                CodexApprovalRow()
                DefaultEffortRow(provider: .codex, efforts: EffortScale.codexDefaultChoices, modelDefault: true)
                CodexAccountRows()
            }
            ExecutablePathDisclosure(provider: .codex, path: $model.codexPathOverride)
        }
    }

    private var meta: String {
        AgentCardMeta.text(agent: agent, binary: "codex", extra: "계정 \(model.accounts.accounts.count)개",
                           checking: model.recheckingAgents.contains(.codex))
    }
}

// MARK: - Antigravity

private struct AntigravityAgentSection: View {
    @Environment(AppModel.self) private var model
    let agent: FirstRunFacts.Agent
    @State private var confirming: Project?

    var body: some View {
        @Bindable var model = model
        let installed = agent.readiness != .notInstalled && agent.readiness != .pathInvalid
        Section {
            AgentCardHeader(provider: .gemini, name: "Antigravity", optional: true, meta: meta, readiness: agent.readiness)
            if !installed {
                AgentNextStep(provider: .gemini, readiness: agent.readiness,
                              resetPath: { model.geminiPathOverride = "" })
            }
            if installed {
                SettingsWarning(text: "승인을 묻지 않습니다. 허용한 프로젝트에서는 Antigravity 가 파일을 고치고 명령을 바로 실행합니다. "
                                    + "Claude · Codex 의 승인 설정은 그대로입니다.")
                allowedProjects
                SettingsToggleRow(title: "셸 명령은 파일을 쓰지 못하게",
                                  subtitle: "샌드박스에서 실행해 파일은 편집 도구로만 바뀝니다. 빌드처럼 파일을 만드는 명령이 필요하면 끄세요.",
                                  isOn: $model.antigravitySandboxEnabled)
            }
            ExecutablePathDisclosure(provider: .gemini, path: $model.geminiPathOverride,
                                     note: "인계 문서를 Gemini 로 다듬을 때(설정 > 인계)도 이 파일(Antigravity CLI)로 Gemini 를 부릅니다.")
        } footer: {
            SettingsFooter("바꾼 설정은 다음에 보내는 메시지부터 적용됩니다.")
        }
    }

    private var meta: String {
        let count: Int = model.projects.filter { model.antigravityAllowed(projectID: $0.id) }.count
        let extra: String = count == 0 ? "허용한 프로젝트 없음" : "프로젝트 \(count)곳에서 허용"
        return AgentCardMeta.text(agent: agent, binary: "agy", extra: extra, checking: model.recheckingAgents.contains(.gemini))
    }

    private var allowedProjects: some View {
        let allowed = model.projects.filter { model.antigravityAllowed(projectID: $0.id) }
        let others = model.projects.filter { !model.antigravityAllowed(projectID: $0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            SettingsLabel(title: "쓸 수 있는 프로젝트",
                          subtitle: allowed.isEmpty
                              ? "아직 없습니다. 처음에는 모든 프로젝트에서 꺼져 있습니다."
                              : "여기나 프로젝트 설정(사이드바의 프로젝트 메뉴)에서 바꿀 수 있습니다.")
            ForEach(allowed) { project in
                HStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.slate)
                    Text(project.name).lineLimit(1)
                    Spacer(minLength: 8)
                    Button("허용 취소") { model.setAntigravityAllowed(false, projectID: project.id) }
                        .controlSize(.small)
                }
                .padding(.leading, 2)
            }
            Menu("프로젝트 허용…") {
                ForEach(others) { project in
                    Button(project.name) { confirming = project }
                }
            }
            .fixedSize()
            .disabled(others.isEmpty)
        }
        .padding(.vertical, 2)
        .alert("이 프로젝트에서 Antigravity 를 쓸까요?", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { project in
            Button("허용") { model.setAntigravityAllowed(true, projectID: project.id) }
            Button("취소", role: .cancel) {}
        } message: { project in
            Text("Antigravity 는 승인을 묻지 않습니다. \(project.name) 안의 파일을 고치고 명령을 바로 실행합니다.")
        }
    }
}
