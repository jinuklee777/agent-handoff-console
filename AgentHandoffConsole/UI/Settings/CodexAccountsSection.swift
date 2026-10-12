import SwiftUI
import AppKit

/// 설정 > 에이전트 > Codex 카드의 계정 줄들. 계정 하나 = `CODEX_HOME` 폴더 하나다. 실행할 때 그 값을 자식 프로세스에만 넘겨
/// 계정을 가르고, 앱은 각 폴더의 `auth.json` 을 **읽기만** 한다 — 로그인은 사람이 터미널에서 한다 (토큰을 만지지 않으려고).
/// 줄마다 로그인 상태 · 한도, 로그인이 안 됐으면 그 폴더에 로그인하는 명령. 이름 바꾸기 · 다시 확인 · 등록 해제는 줄의 메뉴에.
/// 추가 · 등록 해제의 결과는 이 칸 아래에 보인다 (`notice`) — 메인 창의 배너로 보내면 설정 창에 가려 보이지 않았다 (set-2).
struct CodexAccountRows: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var renaming: CodexAccount?
    @State private var renameText = ""
    @State private var removing: CodexAccount?
    @State private var removalThreadCount = 0
    @State private var notice: AppModel.CodexAccountNotice?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("계정").fontWeight(.semibold)
                SettingsHelpButton(text: "계정 하나는 CODEX_HOME 폴더 하나입니다. 앱은 각 폴더의 auth.json 으로 로그인 여부만 보고, 토큰을 풀거나 복사 · "
                                       + "저장 · 전송하지 않습니다. 이메일 · 플랜은 한도를 읽을 때 Codex 에게 묻습니다. ~/.codex 를 비롯한 어떤 폴더의 파일도 옮기거나 고쳐 쓰지 않습니다. 대화의 계정을 바꾸면 "
                                       + "세션 기록도 그 폴더를 따라가므로 이전 대화가 이어지지 않습니다 — 맥락은 인계로 넘기세요.",
                                   subject: "Codex 계정")
            }
            Text("계정마다 따로 로그인합니다. 대화마다 입력창의 에이전트 선택에서 계정을 고릅니다.")
                .font(Theme.ui(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)

        ForEach(model.accounts.accounts) { account in
            CodexAccountRow(account: account,
                            rename: {
                                renameText = account.label
                                renaming = account
                            },
                            remove: {
                                Task {
                                    removalThreadCount = await model.accounts.threadCount(using: account.id)
                                    removing = account
                                }
                            })
        }

        if let notice {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(notice.isError ? Theme.amber : Theme.emerald)
                    .padding(.top, 1)
                Text(notice.text)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 6)
                IconButton(systemName: "xmark", size: 9, color: Theme.control, help: "안내 닫기") { self.notice = nil }
            }
            .padding(.vertical, 2)
        }

        Button {
            adding = true
        } label: {
            Label("계정 추가…", systemImage: "plus")
        }
        .sheet(isPresented: $adding) {
            CodexAccountAddSheet(added: { notice = $0 }).environment(model)
        }
        .alert("계정 이름 바꾸기", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("계정 이름", text: $renameText)
            Button("취소", role: .cancel) { renaming = nil }
            Button("저장") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                // 빈 이름은 받지 않는다 (계정을 구분할 수 없게 된다).
                if let account = renaming, !trimmed.isEmpty, trimmed != account.label {
                    Task { await model.accounts.rename(account.id, to: trimmed) }
                }
                renaming = nil
            }
        } message: {
            Text("입력창의 에이전트 선택 · 툴바의 한도에 보이는 이름입니다.")
        }
        .alert("계정 등록을 해제할까요?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { account in
            Button("취소", role: .cancel) { removing = nil }
            Button("등록 해제", role: .destructive) {
                Task { notice = await model.removeCodexAccount(account.id) }
                removing = nil
            }
        } message: { _ in
            Text(removalMessage)
        }
    }

    private var removalMessage: String {
        var text = "앱의 계정 목록에서만 지웁니다. 폴더와 그 안의 로그인 상태 · 세션 기록은 그대로 둡니다."
        if removalThreadCount > 0 {
            text += "\n\n이 계정을 쓰는 대화 \(removalThreadCount)개는 기본 계정으로 되돌아갑니다. "
                + "그 대화에서 다시 보내면 기본 계정으로 같은 세션을 이어 갑니다 (세션 기록은 이 폴더에 그대로 있습니다)."
        }
        return text
    }
}

/// 계정 한 줄.
private struct CodexAccountRow: View {
    @Environment(AppModel.self) private var model
    let account: CodexAccount
    let rename: () -> Void
    let remove: () -> Void

    var body: some View {
        // 점검표와 같은 판정 — config.toml 의 자격 저장소가 파일이 아니면 auth.json 이 없어도 "로그인 안 됨" 이 아니라 모름이다.
        let readiness = model.codexLoginReadiness(accountID: account.id)
        let loggedIn = readiness == .ready
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.control)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(account.label).fontWeight(.semibold).lineLimit(1)
                        if account.isDefaultHome { SettingsTag(text: "CLI 기본") }
                    }
                    Text(subtitle(loggedIn: loggedIn))
                        .font(Theme.ui(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if readiness != .notLoggedIn {
                    AccountLimitBars(snapshot: model.limits.codex(account.id))
                }
                HStack(spacing: 4) {
                    Image(systemName: loggedIn ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(loggedIn ? Theme.emerald : Theme.amber)
                    Text(statusText(readiness))
                        .font(Theme.ui(.caption, .medium))
                        .foregroundStyle(Theme.ink2)
                }
                .fixedSize()
                Menu {
                    Button("이름 바꾸기…", action: rename)
                    Button("다시 확인") {
                        Task { await model.recheckCodexAccount(account.id) }
                    }
                    Button("Finder 에서 폴더 보기") {
                        SettingsActions.reveal(URL(fileURLWithPath: (account.homePath as NSString).expandingTildeInPath))
                    }
                    if !account.isDefaultHome {
                        Divider()
                        Button("등록 해제…", role: .destructive, action: remove)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("\(account.label) 계정 메뉴")
            }

            if let note = account.identityNote {
                Text(note)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 28)
            }

            if !loggedIn {
                VStack(alignment: .leading, spacing: 7) {
                    Text(readiness == .notLoggedIn
                         ? "터미널에서 이 명령으로 이 폴더에 로그인한 뒤 [다시 확인]을 누르세요. 앱은 로그인을 대신하지 않습니다."
                         : "이 폴더는 로그인을 파일에 두지 않거나 읽지 못했습니다. 로그인돼 있으면 그대로 써도 됩니다. 아니면 이 명령으로 로그인하세요.")
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        CopyableCommand(command: CodexAccountInspector.loginCommand(home: account.homePath))
                        Button("다시 확인") {
                            Task { await model.recheckCodexAccount(account.id) }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.approvalWell))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.approvalBorder))
                .padding(.leading, 28)
            }
        }
        .padding(.vertical, 3)
    }

    private func statusText(_ readiness: AgentReadiness) -> String {
        switch readiness {
        case .ready: return "로그인됨"
        case .notLoggedIn: return "로그인 필요"
        default: return account.authStatus == .unreadable ? "확인 불가" : "로그인 미확인"
        }
    }

    private func subtitle(loggedIn: Bool) -> String {
        guard loggedIn else { return SettingsActions.abbreviated(account.homePath) }
        var parts = [account.identityText]
        if let plan = account.planType { parts.append("플랜 \(plan)") }
        return parts.joined(separator: " · ")
    }
}

/// 계정 줄 오른쪽의 짧은 한도 막대 (계정 전체의 창만 — 모델 하나에 걸린 한도는 뺀다). 값이 없으면 짧은 상태 —
/// 아직 읽지 않은 것과 읽지 못한 것을 가른다 (`LimitsPresentation`, 까닭은 도움말).
private struct AccountLimitBars: View {
    @Environment(AppModel.self) private var model
    let snapshot: LimitSnapshot

    var body: some View {
        let windows = snapshot.windows.filter { $0.model == nil }.prefix(2)
        if windows.isEmpty {
            let state = LimitsPresentation.state(snapshot, context: model.limitContext(for: snapshot.scope))
            Text(LimitsPresentation.shortStatus(state) ?? "한도 정보 없음")
                .font(Theme.ui(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(LimitsPresentation.note(state) ?? "")
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(Array(windows)) { window in
                    HStack(spacing: 6) {
                        Text(window.label)
                            .font(Theme.ui(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        LimitMeter(fraction: window.utilization, width: 40)
                        Text(Fmt.percent(window.utilization))
                            .font(Theme.digits(.caption))
                            .foregroundStyle(Theme.ink2)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
            .help(windows.map { "\($0.label) \(Fmt.percent($0.utilization))" }.joined(separator: " · "))
        }
    }
}

/// 계정 추가 시트 — 폴더(CODEX_HOME)와 이름. [추가]는 등록이 끝날 때까지 기다린다 — 실패하면 시트를 닫지 않고 그 아래에 까닭을
/// 보이고, 성공하면 닫고 결과를 계정 칸 아래에 넘긴다 (`added`, set-2).
private struct CodexAccountAddSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let added: (AppModel.CodexAccountNotice) -> Void
    @State private var homePath = ""
    @State private var label = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Codex 계정 추가").font(Theme.ui(.body, .semibold))
            // 앱은 없는 폴더만 만든다 (권한 700). 이미 있는 폴더의 권한은 바꾸지 않는다 (`CodexAccountService.add`, set-13).
            Text(SettingsText.codexAccountAddNote)
                .font(Theme.ui(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("폴더").gridColumnAlignment(.trailing)
                    HStack(spacing: 8) {
                        TextField("폴더 경로", text: $homePath)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.mono(.caption))
                            .autocorrectionDisabled()
                            .accessibilityLabel("Codex 계정 폴더 경로")
                        Button("찾기…") {
                            if let chosen = SettingsActions.choose(directories: true,
                                                                   message: "이 계정의 Codex 계정 폴더(CODEX_HOME)를 고르세요.") {
                                homePath = chosen
                            }
                        }
                    }
                }
                GridRow {
                    Text("이름")
                    TextField("예: 업무용", text: $label)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .accessibilityLabel("계정 이름")
                }
            }
            if let error {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.amber)
                        .padding(.top, 1)
                    Text(error)
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            HStack {
                if saving {
                    InkSpinner(color: Theme.slate)
                    Text("등록하는 중…").font(Theme.ui(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("추가") { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(homePath.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if homePath.isEmpty { homePath = CodexAccountService.suggestedHomePath(existing: model.accounts.accounts) }
        }
        // 고친 칸에는 지난 실패가 맞지 않는다.
        .onChange(of: homePath) { error = nil }
    }

    private func add() async {
        saving = true
        error = nil
        let notice = await model.addCodexAccount(homePath: homePath.trimmingCharacters(in: .whitespacesAndNewlines), label: label)
        saving = false
        if notice.isError {
            error = notice.text
        } else {
            added(notice)
            dismiss()
        }
    }
}
