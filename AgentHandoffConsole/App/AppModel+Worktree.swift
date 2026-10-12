import Foundation

/// 도는 독립 작업 폴더 명령. 그 대화와 그 명령이 쓰는 폴더들의 보내기 · git 쓰기 · 자동 작업 슬롯을 막는다.
/// git 명령(만들기 · 합치기 · 맞추기 · 정리 · 다시 만들기)은 한 번에 하나(`AppModel.worktreeOperation`), 오래 걸릴 수 있는 준비 명령은
/// 대화마다 따로(`AppModel.worktreeSetups`) — 준비 명령이 도는 동안에도 다른 폴더의 git 쓰기 · 다른 대화의 독립 작업 폴더는 그대로 쓴다.
struct WorktreeOperation: Equatable {
    enum Kind: Equatable {
        case create, merge, catchUp, remove, restore
        /// 프로젝트 설정의 준비 명령 (새 독립 작업 폴더에서, 최대 10분).
        case setup

        /// "독립 작업 폴더를 … 중입니다" 의 가운데.
        var koreanName: String {
            switch self {
            case .create: return "만드는"
            case .merge: return "합치는"
            case .catchUp: return "프로젝트 폴더의 브랜치에 맞추는"
            case .remove: return "정리하는"
            case .restore: return "다시 만드는"
            case .setup: return "준비하는"
            }
        }

        /// 칸 머리의 짧은 표시 ("… 중").
        var shortName: String {
            switch self {
            case .catchUp: return "맞추는"
            default: return koreanName
            }
        }
    }

    var threadID: String
    var kind: Kind
    /// 명령이 쓰는 폴더 (독립 작업 폴더 · 프로젝트 폴더).
    var paths: [String]

    func blocks(threadID: String?, path: String) -> Bool { self.threadID == threadID || paths.contains(path) }
}

/// 대화별 독립 작업 폴더 (git worktree). git 명령은 `Workspace/Worktrees.swift`, 여기는 잠금 · 대화 기록 · 화면 새로고침.
///
/// - 폴더: `folderProject(for:)` 가 그 대화의 프로젝트를 경로만 독립 작업 폴더로 바꿔 돌려준다 (id 는 그대로 — 프로젝트별 설정이 따라온다).
///   보내기 · 인계 · 인스펙터 · 자동 작업 · 실행 전후 비교가 이것을 쓴다.
/// - 대화의 폴더가 바뀌면(만들기 · 정리) Claude 세션 기록을 새 폴더의 칸에 복사하고(`ClaudeSessionFiles`), 이어지는 CLI 세션이 있는
///   제공자마다 다음 턴에 "폴더가 바뀌었다" 는 안내를 붙인다(`folderMoveNotes`) — 앞선 대화에 나온 옛 경로의 파일을 고치지 않게.
extension AppModel {
    // MARK: 폴더

    /// 그 대화가 일하는 폴더의 프로젝트 (독립 작업 폴더가 있으면 경로만 그 폴더).
    func folderProject(for thread: ConversationThread) -> Project? {
        guard let project = projects.first(where: { $0.id == thread.projectID }) else { return nil }
        return folderProject(for: thread, in: project)
    }

    /// 자동 작업의 내부 대화는 부모 대화의 폴더를 따른다 (계획 · 하위 작업이 그 폴더에서 돈다 — `orchestrationProject(for:)`).
    func folderProject(for thread: ConversationThread, in project: Project) -> Project {
        guard let worktree = thread.worktree ?? parentWorktree(of: thread) else { return project }
        var folder = project
        folder.path = worktree.path
        return folder
    }

    private func parentWorktree(of thread: ConversationThread) -> ThreadWorktree? {
        guard let jobID = thread.orchestrationJobID,
              let parentID = orchestration.snapshotsByThread.values.first(where: { $0.job.id == jobID })?.job.parentThreadID
        else { return nil }
        return allThreads().first { $0.id == parentID }?.worktree
    }

    /// 그 대화의 프로젝트 (프로젝트 폴더).
    func mainProject(for thread: ConversationThread) -> Project? {
        projects.first { $0.id == thread.projectID }
    }

    /// 보낼 수 없는 이유 — 독립 작업 폴더가 지워졌다. 없으면 nil.
    func worktreeProblem(_ thread: ConversationThread) -> String? {
        guard let worktree = thread.worktree, !FileManager.default.fileExists(atPath: worktree.path) else { return nil }
        return "이 대화의 독립 작업 폴더가 없습니다 (\(worktree.path)). 변경사항 탭 맨 위의 독립 작업 폴더 칸에서 "
            + "[다시 만들기] 나 [정리] 를 누르세요."
    }

    static func folderMoveKey(_ threadID: String, _ provider: AgentProvider) -> String { threadID + "|" + provider.rawValue }

    /// 그 대화 · 폴더를 막는 독립 작업 폴더 명령 (git 명령이든 준비 명령이든). 없으면 nil.
    /// 보내기 · 인계 · 앱의 git 쓰기 · 자동 작업 슬롯이 본다 — **폴더 단위**다 (다른 폴더의 준비 명령은 막지 않는다, chg-9).
    func worktreeActivity(threadID: String?, path: String) -> WorktreeOperation? {
        if let operation = worktreeOperation, operation.blocks(threadID: threadID, path: path) { return operation }
        return worktreeSetups.values.first { $0.blocks(threadID: threadID, path: path) }
    }

    /// 그 대화의 칸 머리 · 독립 작업 폴더 칸이 보일 도는 명령 (그 대화의 것만).
    func worktreeActivity(threadID: String) -> WorktreeOperation.Kind? {
        if let operation = worktreeOperation, operation.threadID == threadID { return operation.kind }
        return worktreeSetups[threadID]?.kind
    }

    /// 그 대화에서 독립 작업 폴더를 만들 수 없는 이유 (화면이 단추를 끌 때). 만들 수 있으면 nil.
    /// 읽어 둔 프로젝트 폴더의 git 상태(저장소 아님 · 첫 커밋 없음)도 본다 — 만들기 명령 자체는 git 에게 다시 묻는다.
    func worktreeCreationBlock(_ thread: ConversationThread) -> String? {
        worktreeStateBlock(thread) ?? Self.repositoryCreationBlock(workspace(forPath: mainProject(for: thread)?.path)?.git)
    }

    /// 앱 상태로 막히는 이유 (실행 · 인계 · 자동 작업 · 다른 명령). 만들기 명령이 시작 전에 본다.
    private func worktreeStateBlock(_ thread: ConversationThread) -> String? {
        if thread.isInternal { return "자동 작업의 내부 대화에는 만들 수 없습니다." }
        if thread.worktree != nil { return "이미 독립 작업 폴더에서 일합니다." }
        if runner.isBusy(threadID: thread.id) || isStartingRun(threadID: thread.id) { return "에이전트가 실행 중입니다." }
        if hasHandoffActivity(threadID: thread.id) { return Self.handoffCardWorktreeBlock }
        if orchestration.snapshotsByThread[thread.id].map({ !$0.job.state.isTerminal }) == true {
            return "자동 작업이 진행 중입니다."
        }
        if worktreeOperation != nil { return "다른 독립 작업 폴더 명령이 도는 중입니다." }
        return nil
    }

    /// 프로젝트 폴더의 git 상태를 읽어 두었으면 그것으로 — 저장소가 아니거나 첫 커밋이 없으면 만들 수 없다 (메뉴 항목을 끌 때, chg-14).
    /// 아직 읽지 않았으면 nil (누르면 만들기 전에 다시 확인한다 — `addThreadWithWorktree`).
    static func repositoryCreationBlock(_ git: GitWorkspaceStatus?) -> String? {
        guard let git, git.error == nil else { return nil }
        if !git.isRepository { return Worktrees.Failure.notRepository.message }
        if git.noCommitsYet { return Worktrees.Failure.noCommits.message }
        return nil
    }

    /// 메뉴 항목에 붙일 짧은 까닭 ("git 저장소가 아님" · "첫 커밋 없음"). 만들 수 있거나 아직 모르면 nil.
    static func repositoryCreationShortBlock(_ git: GitWorkspaceStatus?) -> String? {
        guard let git, git.error == nil else { return nil }
        if !git.isRepository { return "git 저장소가 아님" }
        if git.noCommitsYet { return "첫 커밋 없음" }
        return nil
    }

    /// "독립 작업 폴더로 옮기기" 확인 창의 설명 (chg-6). 프로젝트 폴더의 상태를 읽어 두었으면 커밋하지 않은 변경 수와 그중 이 대화가 고친 수를 쓴다.
    func worktreeMoveNotice(for thread: ConversationThread) -> [String] {
        guard let project = mainProject(for: thread) else { return [] }
        let git = workspace(forPath: project.path)?.git
        let readable = git.map { $0.isRepository && $0.error == nil } ?? false
        var touched = 0
        if readable, let git, let events = threadStates[thread.id]?.events {
            // 변경 목록은 저장소 루트 기준, 편집 기록은 프로젝트 폴더 기준 — 루트 기준으로 맞춰 센다.
            let prefix = git.projectPrefix.isEmpty ? "" : git.projectPrefix + "/"
            let changed = Set(ChangesState.rows(from: git).map(\.path))
            touched = ExecutionParser.touchedFiles(in: events, projectPath: project.path).keys
                .filter { changed.contains(prefix + $0) }.count
        }
        let setup = !(worktreeSetupCommands[project.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return Worktrees.moveNotice(uncommitted: readable ? git?.changeCount : nil, touchedByThread: touched,
                                    hasSetupCommand: setup)
    }

    /// 인계 카드(준비 · 전달 중 포함)가 있는 대화의 폴더를 바꾸지 않는다 — 카드의 초안 · 지문이 지금 폴더의 것이다.
    static let handoffCardWorktreeBlock = "인계 카드를 먼저 넘기거나 취소하세요."

    // MARK: 만들기

    /// 새 대화를 독립 작업 폴더와 함께 만든다. 프로젝트 폴더가 저장소가 아니거나 첫 커밋이 없으면 대화를 만들지 않고 알린다 (chg-14).
    /// 그 뒤의 이유로 폴더를 못 만들면 대화는 프로젝트 폴더에서 일하는 보통 대화로 남고, 알림이 그 사실을 적는다.
    @discardableResult
    func addThreadWithWorktree(projectID: String) async -> ConversationThread? {
        guard let project = projects.first(where: { $0.id == projectID }) else { return nil }
        let env = await environment.childEnvironment()
        if let git = GitInspector.findGit(environment: env),
           let problem = await Worktrees.creationProblem(project: project.url, git: git, environment: env) {
            banner = BannerMessage(text: "독립 작업 폴더에서 새 대화를 만들지 않았습니다 — " + problem.message, isError: true)
            return nil
        }
        let thread = await addThread(projectID: projectID, title: "새 대화")
        await createWorktree(threadID: thread.id)
        return thread
    }

    /// 대화에 독립 작업 폴더를 만든다. 이미 기록이 있는 대화면 CLI 세션을 새 폴더로 옮기고 다음 턴에 알린다.
    /// 폴더를 만들고 대화가 그 폴더를 보게 한 **뒤** 준비 명령을 돌린다 (따로 잠근다 — 그 대화 · 그 폴더만, chg-9).
    @discardableResult
    func createWorktree(threadID: String) async -> Bool {
        guard let thread = thread(withID: threadID), let project = mainProject(for: thread) else { return false }
        if let block = worktreeStateBlock(thread) {
            banner = BannerMessage(text: "독립 작업 폴더를 만들지 않았습니다 — " + block, isError: true, threadID: threadID)
            return false
        }
        guard let (git, env) = await gitTools(threadID: threadID) else { return false }
        worktreeOperation = WorktreeOperation(threadID: threadID, kind: .create, paths: [project.path])
        let (result, steps) = await Worktrees.create(project: project.url, threadID: threadID, git: git, environment: env)
        await record(steps, threadID: threadID)
        switch result {
        case .failure(let failure):
            worktreeOperation = nil
            banner = BannerMessage(text: "독립 작업 폴더를 만들지 못했습니다: " + failure.message + " 이 대화는 프로젝트 폴더에서 일합니다.",
                                   isError: true, threadID: threadID)
            return false
        case .success(let worktree):
            await moveFolder(threadID: threadID, from: project.path, to: worktree.path,
                             note: "이 대화가 일하는 폴더가 바뀌었습니다. 이제 독립 작업 폴더 `\(worktree.path)` (git worktree, 브랜치 `\(worktree.branch)`)에서 일합니다. "
                                + "앞선 대화에 나온 `\(project.path)` 아래 파일은 고치지 말고, 같은 상대 경로의 파일을 이 폴더에서 다루세요. "
                                + "프로젝트 폴더의 커밋하지 않은 변경과 git 이 무시하는 파일(.env 등)은 이 폴더에 없습니다.")
            try? await store.setThreadWorktree(id: threadID, worktree: worktree)
            let base = worktree.baseBranch.map { "`\($0)` " } ?? ""
            await notice(threadID: threadID, title: "독립 작업 폴더",
                         text: "이 대화만의 독립 작업 폴더를 만들었습니다: \(worktree.path)\n브랜치 `\(worktree.branch)` — \(base)\(worktree.baseCommit.prefix(7)) 에서 가지를 쳤습니다. "
                            + "에이전트 · 변경사항 · 터미널이 이 폴더를 봅니다. 프로젝트 폴더의 커밋하지 않은 변경과 git 이 무시하는 파일(.env · node_modules 등)은 따라오지 않습니다.")
            // 잠금을 틈 없이 넘긴다: 준비 명령의 잠금을 먼저 걸고, 대화 목록 · 칸이 새 폴더를 안 뒤에 만들기 잠금을 푼다 — 그 사이에
            // 보내면 첫 실행이 프로젝트 폴더에서 돌거나 준비 명령과 겹쳤다 (ws-1).
            let setup = hasSetupCommand(project)
            if setup { worktreeSetups[threadID] = WorktreeOperation(threadID: threadID, kind: .setup, paths: [worktree.path]) }
            await afterFolderChange(threadID: threadID)
            worktreeOperation = nil
            if setup { await runSetupCommand(project: project, worktree: worktree, threadID: threadID) }
            return true
        }
    }

    /// 지워진 독립 작업 폴더를 같은 브랜치로 다시 만든다.
    func restoreWorktree(threadID: String) async {
        if hasHandoffActivity(threadID: threadID) {
            banner = BannerMessage(text: "독립 작업 폴더를 다시 만들지 않았습니다 — " + Self.handoffCardWorktreeBlock, isError: true,
                                   threadID: threadID)
            return
        }
        guard let thread = thread(withID: threadID), let worktree = thread.worktree,
              let project = mainProject(for: thread) else { return }
        if worktreeOperation != nil || worktreeSetups[threadID] != nil {
            banner = BannerMessage(text: "독립 작업 폴더를 다시 만들지 않았습니다 — 다른 독립 작업 폴더 명령이 도는 중입니다.",
                                   isError: true, threadID: threadID)
            return
        }
        guard let (git, env) = await gitTools(threadID: threadID) else { return }
        worktreeOperation = WorktreeOperation(threadID: threadID, kind: .restore, paths: [project.path, worktree.path])
        let (result, steps) = await Worktrees.restore(worktree, project: project.url, git: git, environment: env)
        await record(steps, threadID: threadID)
        if case .failure(let failure) = result {
            banner = BannerMessage(text: "독립 작업 폴더를 다시 만들지 못했습니다: " + failure.message, isError: true, threadID: threadID)
            await afterFolderChange(threadID: threadID)
            worktreeOperation = nil
            return
        }
        // 다시 만든 폴더에는 .env · node_modules 가 없다 — 만들 때처럼 준비 명령을 돌린다 (ws-7). 잠금은 틈 없이 넘긴다 (ws-1).
        let setup = hasSetupCommand(project)
        if setup { worktreeSetups[threadID] = WorktreeOperation(threadID: threadID, kind: .setup, paths: [worktree.path]) }
        await afterFolderChange(threadID: threadID)
        worktreeOperation = nil
        if setup { await runSetupCommand(project: project, worktree: worktree, threadID: threadID) }
    }

    // MARK: 합치기 · 따라잡기

    /// 독립 작업 폴더의 일을 프로젝트 폴더의 지금 브랜치로 합친다. `commitMessage` 가 있으면 커밋하지 않은 변경을 먼저 모두 커밋한다.
    /// 프로젝트 폴더가 병합 · rebase 중이거나 거기 커밋하지 않은 변경과 겹치면 아무것도 하지 않고 멈춘다 (`Worktrees.merge` 0 단계).
    /// 반환 = 합쳐졌는지.
    @discardableResult
    func mergeWorktree(threadID: String, commitMessage: String?) async -> Bool {
        guard let thread = thread(withID: threadID), let worktree = thread.worktree,
              let project = mainProject(for: thread) else { return false }
        if let reason = worktreeWriteBlock(threadID: threadID, paths: [worktree.path, project.path]) {
            banner = BannerMessage(text: "합치지 않았습니다 — " + reason, isError: true, threadID: threadID)
            return false
        }
        guard let (git, env) = await gitTools(threadID: threadID) else { return false }
        worktreeOperation = WorktreeOperation(threadID: threadID, kind: .merge, paths: [worktree.path, project.path])
        defer { worktreeOperation = nil }
        let (result, steps) = await Worktrees.merge(worktree, project: project.url, commitMessage: commitMessage,
                                                    git: git, environment: env)
        await record(steps, threadID: threadID)
        await refreshWorkspaces([worktree.path, project.path])
        await refreshWorktreeStatus(threadID: threadID)
        switch result {
        case .merged(let branch):
            await notice(threadID: threadID, title: "프로젝트 폴더로 합침",
                         text: "`\(worktree.branch)` 의 일을 프로젝트 폴더의 `\(branch)` 에 합쳤습니다. 독립 작업 폴더는 그대로 있습니다 — 끝났으면 정리하세요.")
            banner = BannerMessage(text: "`\(branch)` 에 합쳤습니다.", isError: false, threadID: threadID)
            return true
        case .conflictInWorktree(let files):
            await notice(threadID: threadID, title: "충돌",
                         text: "프로젝트 폴더 브랜치의 새 커밋을 독립 작업 폴더로 받다가 충돌했습니다 (\(files.count)개 파일). 독립 작업 폴더가 병합 중입니다 — "
                            + "변경사항 탭에서 풀거나 에이전트에게 풀어 달라고 한 뒤 커밋하고 다시 합치세요. 프로젝트 폴더는 건드리지 않았습니다."
                            + (files.isEmpty ? "" : "\n" + files.prefix(20).joined(separator: "\n")))
            banner = BannerMessage(text: "충돌이 있어 합치지 못했습니다. 독립 작업 폴더에서 풀고 다시 합치세요.", isError: true, threadID: threadID)
            return false
        case .failed(let failure):
            banner = BannerMessage(text: Self.mergeFailureText(failure, steps: steps, worktree: worktree), isError: true,
                                   threadID: threadID)
            return false
        }
    }

    /// 합치기 실패 알림. git 이 거절한 이유는 변경사항 탭과 같은 분류(`GitFailure`)로 — 겹치는 파일은 그 이름. 그 전에 독립 작업 폴더에
    /// 커밋하거나 프로젝트 폴더의 브랜치를 받아 두었으면 그 사실을 붙인다 (확인 창의 "아무것도 바꾸지 않습니다" 와 어긋나지 않게, chg-13).
    static func mergeFailureText(_ failure: Worktrees.Failure, steps: [Worktrees.Step], worktree: ThreadWorktree) -> String {
        var text: String
        if case .git(_, let output) = failure, GitFailure.isOverlap(output.lowercased()) {
            let files = GitFailure.overlappingFiles(output.components(separatedBy: .newlines))
            text = "합치지 못했습니다 — 프로젝트 폴더의 커밋하지 않은 변경과 겹칩니다"
                + (GitFailure.fileList(files).map { ": \($0)" } ?? "") + ". 프로젝트 폴더에서 그 변경을 커밋하거나 치운 뒤 다시 합치세요."
        } else if case .git(_, let output) = failure {
            text = "합치지 못했습니다: " + GitFailure.verbatimLine(output.components(separatedBy: .newlines))
        } else {
            text = failure.message
        }
        let committed = Worktrees.committedInWorktree(steps, worktree: worktree)
        let caughtUp = steps.contains { $0.succeeded && $0.directory == worktree.path && $0.command.hasPrefix("git merge") }
        if committed || caughtUp {
            text += " 독립 작업 폴더에는 이미 "
                + (committed && caughtUp ? "변경을 커밋하고 프로젝트 폴더 브랜치의 새 커밋을 받아" : committed ? "변경을 커밋해" : "프로젝트 폴더 브랜치의 새 커밋을 받아")
                + " 두었습니다 — 다시 합치면 이어서 합칩니다."
        }
        return text
    }

    /// 프로젝트 폴더의 지금 브랜치의 새 커밋을 독립 작업 폴더로 받아 맞춘다. 충돌하면 독립 작업 폴더가 병합 중으로 남는다.
    func catchUpWorktree(threadID: String) async {
        guard let thread = thread(withID: threadID), let worktree = thread.worktree,
              let project = mainProject(for: thread) else { return }
        if let reason = worktreeWriteBlock(threadID: threadID, paths: [worktree.path]) {
            banner = BannerMessage(text: "맞추지 않았습니다 — " + reason, isError: true, threadID: threadID)
            return
        }
        guard let (git, env) = await gitTools(threadID: threadID) else { return }
        let status = await Worktrees.status(worktree, project: project.url, git: git, environment: env)
        guard let main = status.mainBranch else {
            banner = BannerMessage(text: Worktrees.Failure.detachedMain.message, isError: true, threadID: threadID)
            return
        }
        // 이 대화의 브랜치가 아닌 곳(다른 브랜치 · 떼어진 HEAD)에 받으면 그쪽에 병합 커밋이 생긴다 — 돌아온 뒤에.
        if let note = WorktreeFacts.branchMismatch(status, worktreeBranch: worktree.branch) {
            banner = BannerMessage(text: "맞추지 않았습니다 — " + note, isError: true, threadID: threadID)
            return
        }
        guard (status.uncommitted ?? 0) == 0 else {
            banner = BannerMessage(text: "독립 작업 폴더에 커밋하지 않은 변경이 있습니다. 먼저 커밋하세요.", isError: true, threadID: threadID)
            return
        }
        worktreeOperation = WorktreeOperation(threadID: threadID, kind: .catchUp, paths: [worktree.path])
        defer { worktreeOperation = nil }
        let (result, steps) = await Worktrees.catchUp(worktree, from: main, git: git, environment: env)
        await record(steps, threadID: threadID)
        await refreshWorkspaces([worktree.path])
        await refreshWorktreeStatus(threadID: threadID)
        switch result {
        case .merged:
            banner = BannerMessage(text: "`\(main)` 의 새 커밋을 받아 맞췄습니다.", isError: false, threadID: threadID)
        case .conflictInWorktree(let files):
            await notice(threadID: threadID, title: "충돌",
                         text: "`\(main)` 의 새 커밋을 받다가 충돌했습니다 (\(files.count)개 파일). 변경사항 탭에서 풀거나 에이전트에게 부탁한 뒤 커밋하세요."
                            + (files.isEmpty ? "" : "\n" + files.prefix(20).joined(separator: "\n")))
        case .failed(let failure):
            banner = BannerMessage(text: "맞추지 못했습니다: " + failure.message, isError: true, threadID: threadID)
        }
    }

    /// "에이전트에게 충돌 풀기 부탁" — 입력창에 부탁 글을 넣는다. 쓰던 글이 있으면 덮지 않고 뒤에 붙이고, 입력창에 포커스를 준다 (chg-22).
    func askAgentToResolveConflicts(threadID: String, mainBranch: String) {
        let request = "독립 작업 폴더에서 `\(mainBranch)` 브랜치를 병합하다가 충돌이 났습니다. `git status` 로 충돌 파일을 확인하고, 양쪽 변경의 의도를 살려 충돌을 풀어 주세요. "
            + "다 풀면 `git add` 한 뒤 병합 커밋을 만들어 주세요 (`git commit --no-edit`)."
        updateComposerDraft(Self.appendingRequest(request, to: composerDraft(for: threadID)), for: threadID)
        requestComposerFocus(threadID: threadID)
    }

    /// 쓰던 글 뒤에 부탁을 붙인다 (빈 줄 하나로 나눈다). 이미 같은 부탁이 들어 있으면 그대로 둔다.
    static func appendingRequest(_ request: String, to draft: String) -> String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return request }
        if draft.contains(request) { return draft }
        return trimmed + "\n\n" + request
    }

    // MARK: 정리

    /// 독립 작업 폴더를 지우고 대화를 프로젝트 폴더로 돌린다. `force` 면 커밋하지 않은 변경도 버린다. 브랜치는 `branch` 대로.
    /// `keepThread` 가 false 면(대화를 지울 때) 폴더 이동 안내 · 세션 복사 · 기록을 하지 않는다.
    @discardableResult
    func removeWorktree(threadID: String, force: Bool, branch: Worktrees.BranchDisposal,
                        keepThread: Bool = true) async -> Bool {
        guard let thread = thread(withID: threadID), let worktree = thread.worktree,
              let project = mainProject(for: thread) else { return false }
        // 대화를 지우거나 프로젝트를 빼는 정리(`keepThread == false`)는 카드도 함께 지운다 — 막지 않는다.
        if keepThread, hasHandoffActivity(threadID: threadID) {
            banner = BannerMessage(text: "정리하지 않았습니다 — " + Self.handoffCardWorktreeBlock, isError: true, threadID: threadID)
            return false
        }
        if let reason = worktreeWriteBlock(threadID: threadID, paths: [worktree.path]) {
            banner = BannerMessage(text: "정리하지 않았습니다 — " + reason, isError: true, threadID: threadID)
            return false
        }
        guard let (git, env) = await gitTools(threadID: threadID) else { return false }
        worktreeOperation = WorktreeOperation(threadID: threadID, kind: .remove, paths: [worktree.path, project.path])
        defer { worktreeOperation = nil }
        #if canImport(SwiftTerm)
        ShellTerminalStore.shared.close(worktree.path)
        #endif
        let (result, steps) = await Worktrees.remove(worktree, project: project.url, force: force,
                                                     branch: branch, git: git, environment: env)
        if keepThread { await record(steps, threadID: threadID) }
        let removal: Worktrees.Removal
        switch result {
        case .failure(let failure):
            banner = BannerMessage(text: "독립 작업 폴더를 정리하지 못했습니다: " + failure.message, isError: true, threadID: threadID)
            await refreshWorktreeStatus(threadID: threadID)
            return false
        case .success(let done):
            removal = done
        }
        let branchKept = removal.branchKept
        // 떼어진 HEAD 의 커밋을 새 브랜치로 남겼다 — 어디에 있는지 알린다 (대화를 지울 때도).
        let savedNote = removal.savedBranch.map {
            "독립 작업 폴더가 브랜치가 아닌 커밋(detached HEAD)을 보고 있어, 어느 브랜치에도 없던 커밋을 새 브랜치 `\($0)` 에 남겼습니다."
        }
        guard keepThread else {
            var lines: [String] = []
            if let savedNote { lines.append(savedNote) }
            if branchKept, branch != .keep {
                lines.append("브랜치 `\(worktree.branch)` 에 합치지 않은 커밋이 있어 브랜치는 남겼습니다.")
            }
            if !lines.isEmpty { banner = BannerMessage(text: lines.joined(separator: " "), isError: false) }
            return true
        }
        await moveFolder(threadID: threadID, from: worktree.path, to: project.path,
                         note: "이 대화가 일하는 폴더가 바뀌었습니다. 독립 작업 폴더(`\(worktree.path)`)는 정리되었고, 이제 프로젝트 폴더 `\(project.path)` 에서 일합니다. "
                            + "앞선 대화에 나온 `\(worktree.path)` 아래 경로는 더 없습니다 — 같은 상대 경로의 파일을 이 폴더에서 다루세요.")
        try? await store.setThreadWorktree(id: threadID, worktree: nil)
        worktreeStatuses[threadID] = nil
        await notice(threadID: threadID, title: "독립 작업 폴더 정리",
                     text: "독립 작업 폴더를 지웠습니다" + (branchKept ? " (브랜치는 남김 — `\(worktree.branch)`)" : " (브랜치도 지움 — `\(worktree.branch)`)")
                        + ". 이제 이 대화는 프로젝트 폴더에서 일합니다. 프로젝트 폴더의 파일은 그대로입니다."
                        + (savedNote.map { " " + $0 } ?? ""))
        await afterFolderChange(threadID: threadID)
        return true
    }

    // MARK: 상태

    func refreshWorktreeStatus(threadID: String) async {
        guard let thread = thread(withID: threadID), let worktree = thread.worktree,
              let project = mainProject(for: thread) else {
            worktreeStatuses[threadID] = nil
            return
        }
        let env = await environment.childEnvironment()
        guard let git = GitInspector.findGit(environment: env) else { return }
        worktreeStatuses[threadID] = await Worktrees.status(worktree, project: project.url, git: git, environment: env)
    }

    /// 프로젝트 설정에 적어 둔 준비 명령을 새 독립 작업 폴더에서 돌린다 (로그인 셸 + 에이전트 CLI 와 같은 환경 — 셸의 PATH,
    /// `AHC_PROJECT_DIR` = 프로젝트 폴더).
    /// 도는 동안(최대 10분) **그 대화와 그 폴더만** 막는다 (`worktreeSetups` — 보내기 · 인계 · 그 폴더의 git 쓰기). 다른 폴더 · 다른 대화의
    /// git 쓰기와 독립 작업 폴더 명령은 그대로 쓴다 (chg-9). 실패해도 폴더는 남긴다 — 결과를 대화에 적는다.
    private func hasSetupCommand(_ project: Project) -> Bool {
        !(worktreeSetupCommands[project.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    private func runSetupCommand(project: Project, worktree: ThreadWorktree, threadID: String) async {
        defer { worktreeSetups[threadID] = nil }
        guard let command = worktreeSetupCommands[project.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return }
        worktreeSetups[threadID] = WorktreeOperation(threadID: threadID, kind: .setup, paths: [worktree.path])
        let quoted = "'" + project.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let environment = self.environment
        let result = await ShellVerificationCommandRunner(timeout: 10 * 60, environment: { await environment.childEnvironment() })
            .run(command: "export AHC_PROJECT_DIR=\(quoted); " + command, in: URL(fileURLWithPath: worktree.path))
        let succeeded = result.exitCode == 0
        var payload: [String: Any] = ["status": succeeded ? "completed" : "failed", "source": "app", "cwd": worktree.path,
                                      Worktrees.housekeepingKey: true]
        if let code = result.exitCode { payload["exitCode"] = code }
        let event = ThreadEvent(threadID: threadID, kind: .commandExecution, provider: nil, title: command,
                                text: command + (result.outputTail.isEmpty ? "" : "\n\n--- 출력 ---\n" + result.outputTail),
                                payloadJSON: JSONUtil.line(payload))
        if let saved = try? await store.appendEvent(event) { runCoordinator(runner, didUpsert: saved) }
        // 준비 명령이 파일을 만들었을 수 있다 (잠금 파일 · 설정 등) — 그 폴더를 열어 두었으면 다시 읽는다.
        await refreshWorkspaces([worktree.path])
        if !succeeded {
            // 첫 메시지 전에는 시작 화면이라 대화에 출력이 보이지 않는다 — 늘 보이는 곳을 가리킨다 (ws-4).
            banner = BannerMessage(text: "독립 작업 폴더의 준비 명령이 실패했습니다 — 출력은 인스펙터의 터미널 탭 > 에이전트 실행에 있습니다. "
                                       + "폴더는 만들어져 있습니다.",
                                   isError: true, threadID: threadID)
        }
    }

    // MARK: 도우미

    private func thread(withID id: String) -> ConversationThread? {
        allThreads().first { $0.id == id } ?? internalThreadsByID[id]
    }

    /// 그 폴더들에 쓸 수 없는 이유 (`runGit` 의 가드와 같은 기준). 쓸 수 있으면 nil.
    func worktreeWriteBlock(threadID: String, paths: [String]) -> String? {
        if runner.isBusy(threadID: threadID) || isStartingRun(threadID: threadID) { return "이 대화의 에이전트가 실행 중입니다." }
        for path in paths {
            if !writeSessions(inProjectPath: path).isEmpty || isStartingRun(projectPath: path) {
                return path == paths.first ? "이 폴더에서 에이전트가 실행 중입니다." : "프로젝트 폴더에서 에이전트가 실행 중입니다."
            }
            if isReviewing(inProjectPath: path) { return "자동 작업의 검토가 진행 중입니다." }
        }
        if orchestration.snapshotsByThread[threadID].map({ !$0.job.state.isTerminal }) == true {
            return "이 대화의 자동 작업이 진행 중입니다."
        }
        if worktreeSetups[threadID] != nil { return "독립 작업 폴더의 준비 명령이 도는 중입니다." }
        if runningGitOperation != nil || worktreeOperation != nil { return "다른 git 명령이 도는 중입니다." }
        let unterminated = runner.unterminatedProcesses + reviewLanes.unterminatedProcesses
        if !unterminated.isEmpty { return "종료가 확인되지 않은 프로세스가 있습니다." }
        return nil
    }

    private func gitTools(threadID: String) async -> (String, [String: String])? {
        let env = await environment.childEnvironment()
        guard let git = GitInspector.findGit(environment: env) else {
            banner = BannerMessage(text: "git 실행 파일을 찾지 못했습니다.", isError: true, threadID: threadID)
            return nil
        }
        return (git, env)
    }

    /// 명령마다 대화에 남긴다 (`runGit` 과 같은 모양 — 앱이 실행한 명령). 앱의 정리 기록이라는 표시를 붙인다 (`Worktrees.isHousekeeping`).
    private func record(_ steps: [Worktrees.Step], threadID: String) async {
        for step in steps {
            let payload: [String: Any] = ["status": step.succeeded ? "completed" : "failed", "source": "app", "cwd": step.directory,
                                          Worktrees.housekeepingKey: true]
            let event = ThreadEvent(threadID: threadID, kind: .commandExecution, provider: nil, title: step.command,
                                    text: step.command + (step.output.isEmpty ? "" : "\n\n--- 출력 ---\n" + step.output),
                                    payloadJSON: JSONUtil.line(payload))
            if let saved = try? await store.appendEvent(event) { runCoordinator(runner, didUpsert: saved) }
        }
    }

    private func notice(threadID: String, title: String, text: String) async {
        let event = ThreadEvent(threadID: threadID, kind: .systemNotice, provider: nil, title: title, text: text,
                                payloadJSON: JSONUtil.line([Worktrees.housekeepingKey: true]))
        if let saved = try? await store.appendEvent(event) { runCoordinator(runner, didUpsert: saved) }
    }

    /// 대화의 폴더가 바뀌었다: Claude 세션 기록을 새 폴더의 칸에 복사하고, 이어지는 세션이 있는 제공자마다 다음 턴의 안내를 건다.
    private func moveFolder(threadID: String, from: String, to: String, note: String) async {
        let sessions = (try? await store.sessions(threadID: threadID)) ?? []
        for session in sessions {
            guard let cli = session.cliSessionID, !cli.isEmpty else { continue }
            if session.provider == .claude { ClaudeSessionFiles.copy(sessionID: cli, fromFolder: from, toFolder: to) }
            folderMoveNotes[Self.folderMoveKey(threadID, session.provider)] = "[앱 안내] " + note
        }
    }

    /// 대화 목록 · 칸 · 인스펙터가 새 폴더를 보게 한다.
    private func afterFolderChange(threadID: String) async {
        await reloadProjects()
        await syncPanes()
        if let path = projectPath(ofThread: threadID) { await openWorkspace(path: path).refreshGit() }
        closeDiffIfProjectChanged(to: selectedProject?.path)
        pruneThreadStates()
        await refreshWorktreeStatus(threadID: threadID)
    }

    private func refreshWorkspaces(_ paths: [String]) async {
        for path in paths { await workspace(forPath: path)?.refreshGit() }
    }
}
