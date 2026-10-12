import AppKit
import SwiftUI

/// 변경사항 탭 맨 위의 한 칸 — 포커스 대화가 독립 작업 폴더(git worktree)에서 일할 때: 브랜치 · 프로젝트 폴더 브랜치와의 차이 ·
/// 합치기 · 맞추기(프로젝트 폴더 브랜치의 새 커밋 받기) · 정리. 명령과 잠금은 `AppModel+Worktree`, git 은 `Worktrees`.
/// 아래의 변경사항 목록 · 커밋 · 병합 중 안내는 **독립 작업 폴더**의 것이다 (인스펙터가 대화의 폴더를 따라간다).
struct WorktreePanel: View {
    let thread: ConversationThread
    let worktree: ThreadWorktree
    @Environment(AppModel.self) private var model
    @State private var mergeOpen = false
    @State private var cleanupOpen = false
    @State private var commitMessage = ""
    @State private var deleteBranch = true

    private var status: Worktrees.Status? { model.worktreeStatuses[thread.id] }
    private var mainBranch: String { status?.mainBranch ?? worktree.baseBranch ?? "프로젝트 폴더의 브랜치" }
    /// 이 대화의 독립 작업 폴더 명령 (git 명령 · 준비 명령).
    private var running: WorktreeOperation.Kind? { model.worktreeActivity(threadID: thread.id) }
    /// 프로젝트 폴더가 병합 · rebase 중이면 그 까닭 — 그동안 합치지 않는다 (chg-1).
    private var projectBusy: String? {
        status?.projectOperation.map { "프로젝트 폴더가 \($0.koreanName) 중이라 합칠 수 없습니다 — 그 작업을 마치거나 멈춘 뒤 합치세요." }
    }
    private var block: String? { model.worktreeWriteBlock(threadID: thread.id, paths: [worktree.path]) }
    /// 합치기는 프로젝트 폴더에도 쓴다.
    private var mergeBlock: String? {
        model.worktreeWriteBlock(threadID: thread.id,
                                 paths: [worktree.path] + (model.mainProject(for: thread).map { [$0.path] } ?? []))
    }

    /// 상태를 다시 읽을 때: 대화 · 독립 작업 폴더의 git 상태 · 프로젝트 폴더의 git 상태(열려 있으면)가 바뀌면.
    private var refreshKey: [AnyHashable] {
        [thread.id, model.workspace(forPath: worktree.path)?.git,
         model.mainProject(for: thread).flatMap { model.workspace(forPath: $0.path)?.git }]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let status, !status.folderExists {
                missingFolder
            } else {
                facts
                actions
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.wellSoft)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairSoft).frame(height: 1) }
        .task(id: refreshKey) { await model.refreshWorktreeStatus(threadID: thread.id) }
    }

    // MARK: 머리

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.slate)
            Text("독립 작업 폴더")
                .font(Theme.ui(.callout, .semibold))
                .foregroundStyle(Theme.ink2)
            Text(worktree.branch)
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("→ \(mainBranch)")
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.slate)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let running {
                InkSpinner(color: Theme.slate)
                Text("\(running.shortName) 중")
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
            }
            Menu {
                Button("독립 작업 폴더를 Finder 에서 열기") { NSWorkspace.shared.open(URL(fileURLWithPath: worktree.path)) }
                Button("독립 작업 폴더를 터미널에서 열기") { TerminalLauncher.open(URL(fileURLWithPath: worktree.path)) }
                Button("경로 복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(worktree.path, forType: .string)
                }
                if let main = model.mainProject(for: thread) {
                    Divider()
                    Button("프로젝트 폴더를 Finder 에서 열기") { NSWorkspace.shared.open(main.url) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.slate2)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help("독립 작업 폴더 메뉴 — Finder · 터미널 · 경로 복사")
            .accessibilityLabel("독립 작업 폴더 메뉴")
        }
        .help(worktree.path + "\n\(worktree.baseBranch ?? "커밋") \(worktree.baseCommit.prefix(7)) 에서 가지를 침")
    }

    // MARK: 사실

    private var facts: some View {
        let parts = WorktreeFacts.parts(status, mainBranch: mainBranch)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 { MetaDot() }
                    Text(part.text)
                        .foregroundStyle(part.emphasis ? Theme.ink2 : Theme.slate)
                        .fontWeight(part.emphasis ? .semibold : .regular)
                }
            }
            .lineLimit(1)
            // 터미널에서 독립 작업 폴더의 브랜치를 바꿨다 — 합치기는 이 대화의 브랜치만 본다 (chg-16).
            if let note = WorktreeFacts.branchMismatch(status, worktreeBranch: worktree.branch) {
                Text(note)
                    .foregroundStyle(Theme.amberText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(Theme.ui(.caption))
    }

    // MARK: 동작

    @ViewBuilder
    private var actions: some View {
        if let operation = status?.folderOperation {
            VStack(alignment: .leading, spacing: 6) {
                Text("독립 작업 폴더가 \(operation.koreanName) 중입니다. 아래에서 충돌을 풀고 마무리한 뒤 다시 합치세요.")
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.amberText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("에이전트에게 충돌 풀기 부탁") {
                    model.askAgentToResolveConflicts(threadID: thread.id, mainBranch: mainBranch)
                }
                .buttonStyle(ChipButtonStyle(height: 24, horizontalPadding: 9))
                .disabled(model.runner.isBusy(threadID: thread.id))
                .help("입력창에 충돌을 풀어 달라는 부탁을 넣습니다 — 쓰던 글이 있으면 그 뒤에 붙입니다. 보내기 전에 고칠 수 있습니다.")
            }
        } else {
            HStack(spacing: 8) {
                Button("\(mainBranch) 에 합치기") {
                    commitMessage = thread.hasPlaceholderTitle ? "" : thread.title
                    mergeOpen = true
                }
                .buttonStyle(InkButtonStyle(height: 26))
                .disabled(mergeBlock != nil || running != nil || status?.mainBranch == nil || nothingToMerge
                          || projectBusy != nil || offBranch)
                .help(mergeHelp)
                .popover(isPresented: $mergeOpen, arrowEdge: .bottom) { mergeConfirm }
                if let behind = status?.behind, behind > 0 {
                    // "받기"(git pull)와 다른 일이라 다른 이름으로 — 프로젝트 폴더 브랜치의 새 커밋을 이 폴더에 합쳐 맞춘다 (txt-5).
                    Button("\(mainBranch) 에 맞추기 · \(behind)") { Task { await model.catchUpWorktree(threadID: thread.id) } }
                        .buttonStyle(ChipButtonStyle(height: 26, horizontalPadding: 10))
                        .disabled(block != nil || running != nil || (status?.uncommitted ?? 0) > 0 || offBranch)
                        .help(offBranch
                              ? "이 폴더가 이 대화의 브랜치(\(worktree.branch))가 아닌 곳을 보고 있습니다. 돌아온 뒤에 맞추세요."
                              : (status?.uncommitted ?? 0) > 0
                              ? "커밋하지 않은 변경이 있습니다. 먼저 커밋하세요."
                              : "프로젝트 폴더의 \(mainBranch) 에 새로 생긴 커밋 \(behind)개를 이 독립 작업 폴더로 합쳐 맞춥니다 (git merge). "
                                + "충돌하면 여기서 풉니다. 프로젝트 폴더는 바뀌지 않습니다.")
                }
                Spacer(minLength: 4)
                Button("정리…") {
                    deleteBranch = true
                    cleanupOpen = true
                }
                .buttonStyle(TextButtonStyle(color: Theme.slate, font: Theme.ui(.caption)))
                .disabled(block != nil || running != nil)
                .popover(isPresented: $cleanupOpen, arrowEdge: .bottom) { cleanupConfirm }
            }
            if let reason = projectBusy ?? block ?? mergeBlock, running == nil {
                Text(reason)
                    .font(Theme.ui(.caption))
                    .foregroundStyle(projectBusy != nil ? Theme.amberText : Theme.slate2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var nothingToMerge: Bool { status?.fullyMerged == true }

    /// 이 폴더가 이 대화의 브랜치가 아닌 곳(다른 브랜치 · 떼어진 HEAD)을 본다 — 합치기 · 맞추기를 막는다 (까닭은 사실 줄의 `branchMismatch`).
    private var offBranch: Bool { status?.offBranch(worktree.branch) == true }

    private var mergeHelp: String {
        if let block = mergeBlock { return block }
        if let projectBusy { return projectBusy }
        if status?.mainBranch == nil { return Worktrees.Failure.detachedMain.message }
        if offBranch {
            return "이 폴더가 이 대화의 브랜치(\(worktree.branch))가 아닌 곳을 보고 있어 합치지 않습니다 — 위 안내대로 돌아온 뒤에 합치세요."
        }
        if nothingToMerge { return "\(mainBranch) 에 합칠 것이 없습니다 (이미 다 들어가 있습니다)." }
        return "이 독립 작업 폴더의 커밋을 프로젝트 폴더의 \(mainBranch) 에 합칩니다."
    }

    private var mergeConfirm: some View {
        let uncommitted = status?.uncommitted ?? 0
        let ahead = status?.ahead ?? 0
        let behind = status?.behind ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(worktree.branch) → \(mainBranch)")
                .font(Theme.ui(.callout, .semibold))
                .foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 4) {
                // 합칠 곳이 처음 가지를 친 브랜치가 아니다 — 프로젝트 폴더에서 브랜치를 바꿔 두었다 (chg-13).
                if let base = worktree.baseBranch, status?.mainBranch != nil, base != mainBranch {
                    Text("처음 가지를 친 브랜치(\(base))가 아니라 지금 프로젝트 폴더의 \(mainBranch) 에 합칩니다.")
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.amberText)
                }
                if uncommitted > 0 {
                    Text("이 독립 작업 폴더의 커밋하지 않은 변경 \(uncommitted)개를 먼저 모두 커밋합니다.")
                }
                if ahead > 0 { Text("합칠 커밋 \(ahead)개" + (uncommitted > 0 ? " (+ 방금 만들 커밋)" : "")) }
                if behind > 0 {
                    Text("\(mainBranch) 의 새 커밋 \(behind)개를 먼저 이 독립 작업 폴더로 받습니다. 충돌하면 여기서 멈추고, 프로젝트 폴더는 그대로 둡니다.")
                }
                // 겹침은 커밋하기 전에 본다 — 그때는 정말 아무것도 바꾸지 않는다 (`Worktrees.merge` 0 단계).
                Text("프로젝트 폴더의 커밋하지 않은 변경과 겹치거나 프로젝트 폴더가 병합 · rebase 중이면 시작하기 전에 멈춥니다 (아무것도 바꾸지 않습니다).")
                    .foregroundStyle(Theme.slate2)
            }
            .font(Theme.ui(.caption))
            .foregroundStyle(Theme.ink2)
            .fixedSize(horizontal: false, vertical: true)
            if uncommitted > 0 {
                TextField("커밋 메시지", text: $commitMessage)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.ui(.callout))
            }
            HStack {
                Spacer()
                Button("취소") { mergeOpen = false }
                    .buttonStyle(ChipButtonStyle(height: 26))
                Button(uncommitted > 0 ? "커밋하고 합치기" : "합치기") {
                    mergeOpen = false
                    let message = uncommitted > 0 ? commitMessage : nil
                    Task { await model.mergeWorktree(threadID: thread.id, commitMessage: message) }
                }
                .buttonStyle(InkButtonStyle(height: 26))
                .keyboardShortcut(.defaultAction)
                .disabled(uncommitted > 0 && commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 330)
    }

    private var cleanupConfirm: some View {
        let uncommitted = status?.uncommitted ?? 0
        let ahead = status?.ahead ?? 0
        let losesWork = uncommitted > 0 || (deleteBranch && ahead > 0)
        return VStack(alignment: .leading, spacing: 10) {
            Text("독립 작업 폴더 정리")
                .font(Theme.ui(.callout, .semibold))
                .foregroundStyle(Theme.ink)
            Text("이 대화만의 독립 작업 폴더(\(Fmt.abbreviatedPath(worktree.path)))를 지우고 대화를 프로젝트 폴더로 돌립니다. "
                 + "대화 기록은 그대로입니다.")
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if let main = model.mainProject(for: thread) {
                // 지우는 것이 프로젝트가 아니라는 것을 경로로 한 번 더 (chg-7).
                Text("프로젝트 폴더(\(Fmt.abbreviatedPath(main.path)))의 파일은 그대로입니다.")
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $deleteBranch) {
                Text("브랜치 \(worktree.branch) 도 지우기").font(Theme.ui(.caption))
            }
            .toggleStyle(.checkbox)
            if uncommitted > 0 {
                Text("커밋하지 않은 변경 \(uncommitted)개가 사라집니다.")
                    .font(Theme.ui(.caption, .semibold))
                    .foregroundStyle(Theme.danger)
            }
            if deleteBranch, ahead > 0 {
                Text("\(mainBranch) 에 합치지 않은 커밋 \(ahead)개가 사라집니다.")
                    .font(Theme.ui(.caption, .semibold))
                    .foregroundStyle(Theme.danger)
            }
            if let stranded = status?.strandedCommits, stranded > 0 {
                // 떼어진 HEAD 의 커밋 — git 은 정리하며 잃게 두지만 앱은 지우기 전에 브랜치로 남긴다 (`Worktrees.remove`).
                Text("브랜치에 없는 커밋 \(stranded)개(detached HEAD)는 새 브랜치 \(worktree.branch)-saved 에 남깁니다.")
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.amberText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("취소") { cleanupOpen = false }
                    .buttonStyle(ChipButtonStyle(height: 26))
                Button(losesWork ? "버리고 정리" : "정리") {
                    cleanupOpen = false
                    let disposal: Worktrees.BranchDisposal = deleteBranch ? (ahead > 0 ? .delete : .deleteIfMerged) : .keep
                    Task { await model.removeWorktree(threadID: thread.id, force: uncommitted > 0, branch: disposal) }
                }
                .buttonStyle(InkButtonStyle(height: 26, fill: losesWork ? Theme.danger : Theme.ink))
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var missingFolder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("독립 작업 폴더가 없습니다 (지워졌거나 옮겨졌습니다). 같은 브랜치로 다시 만들거나, 정리하고 프로젝트 폴더로 돌아가세요.")
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.amberText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("다시 만들기") { Task { await model.restoreWorktree(threadID: thread.id) } }
                    .buttonStyle(ChipButtonStyle(height: 24, horizontalPadding: 9))
                    .disabled(running != nil || status?.branchExists == false)
                Button("정리") {
                    Task { await model.removeWorktree(threadID: thread.id, force: true, branch: .keep) }
                }
                .buttonStyle(ChipButtonStyle(height: 24, horizontalPadding: 9))
                .disabled(running != nil)
            }
        }
    }
}
