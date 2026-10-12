import Foundation

// MARK: - 대화별 독립 작업 폴더 (git worktree)

/// 실제 git 으로 임시 저장소에서: 만들기 → 에이전트가 그 폴더에서 돈다 → 합치기(본 브랜치를 먼저 받음) → 정리,
/// 충돌은 작업 폴더에서 멈추고 프로젝트 폴더를 건드리지 않는다, 프로젝트가 저장소의 하위 폴더일 때.
@MainActor
enum WorktreeTests {
    static func run(_ t: TestKit) async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ahc-worktree-\(UUID().uuidString.prefix(8))")
        setenv("AHC_WORKTREES_DIR", root.appendingPathComponent("worktrees").path, 1)
        // 세션 기록 복사가 사용자의 ~/.claude 를 건드리지 않게.
        setenv("CLAUDE_CONFIG_DIR", root.appendingPathComponent("claude-config").path, 1)
        defer {
            unsetenv("AHC_WORKTREES_DIR")
            unsetenv("CLAUDE_CONFIG_DIR")
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try await appFlow(t, root: root)
            try await conflictAndSubfolder(t, root: root)
            try await deleteKeepsUnknownChanges(t, root: root)
            try await projectBusyKeepsHumanMerge(t, root: root)
            try await overlapStopsBeforeCommit(t, root: root)
            try await creationAndSetup(t, root: root)
            try await offBranchAndDetached(t, root: root)
        } catch {
            await t.check("독립 작업 폴더 시험 준비", false, "\(error)")
        }
        await sessionFiles(t, root: root)
        await pureDecisions(t)
    }

    /// chg-1: 프로젝트 폴더에서 사람이 풀던 병합 위에 합치지 않는다 — 손으로 푼 파일 · MERGE_HEAD · 스테이지가 그대로 남는다.
    private static func projectBusyKeepsHumanMerge(_ t: TestKit, root: URL) async throws {
        await t.group("독립 작업 폴더: 프로젝트 폴더가 병합 중이면 합치지 않는다 (사람이 푼 충돌을 지우지 않음)")
        let repo = try makeRepo(root.appendingPathComponent("busy"))
        let env = ProcessInfo.processInfo.environment
        guard let gitPath = GitInspector.findGit(environment: env) else {
            await t.check("git", false)
            return
        }
        let (created, _) = await Worktrees.create(project: repo, threadID: "B05Y0001-xxxx", git: gitPath, environment: env)
        guard case .success(let worktree) = created else {
            await t.check("만들기", false, "\(created)")
            return
        }
        // 독립 작업 폴더에서 한 일 (합칠 커밋).
        let folder = URL(fileURLWithPath: worktree.path)
        try "w\n".write(to: folder.appendingPathComponent("w.txt"), atomically: true, encoding: .utf8)
        try git(["add", "w.txt"], in: folder)
        try git(["commit", "-qm", "w"], in: folder)
        // 프로젝트 폴더: 사람이 터미널에서 병합하다 충돌 → 손으로 풀고 git add, 아직 커밋하지 않음.
        try git(["switch", "-q", "-c", "other"], in: repo)
        try "otherside\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-qam", "other"], in: repo)
        try git(["switch", "-q", "main"], in: repo)
        try "mainside\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-qam", "main"], in: repo)
        _ = try? git(["merge", "other"], in: repo)   // 충돌로 실패한다 (MERGE_HEAD 가 남는다)
        try "RESOLVED BY USER\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "a.txt"], in: repo)
        let status = await Worktrees.status(worktree, project: repo, git: gitPath, environment: env)
        await t.equal("상태: 프로젝트 폴더가 병합 중", status.projectOperation, .merge)
        let (result, steps) = await Worktrees.merge(worktree, project: repo, commitMessage: "커밋할 것 없음",
                                                    git: gitPath, environment: env)
        let text = try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8)
        let staged = try git(["diff", "--cached", "--name-only"], in: repo)
        let mergeHead = try? git(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: repo)
        await t.check("합치지 않고 멈춘다 · 명령을 하나도 돌리지 않는다", result == .failed(.projectBusy(.merge)) && steps.isEmpty,
                      "\(result) / \(steps.map(\.command))")
        await t.check("사람이 푼 내용 · 스테이지 · 진행 중인 병합이 그대로", text == "RESOLVED BY USER\n"
                        && staged.contains("a.txt") && mergeHead != nil, text + staged)
        await t.check("알림 문구: 병합 중 · 아무것도 바꾸지 않음",
                      Worktrees.Failure.projectBusy(.merge).message.contains("병합 중")
                        && Worktrees.Failure.projectBusy(.merge).message.contains("아무것도 바꾸지 않았습니다"))
        // 사람이 병합을 마치면 합칠 수 있다.
        try git(["commit", "-q", "--no-edit"], in: repo)
        let (after, _) = await Worktrees.merge(worktree, project: repo, commitMessage: nil, git: gitPath, environment: env)
        await t.equal("병합을 마친 뒤에는 합쳐진다", after, .merged(into: "main"))
    }

    /// 독립 작업 폴더가 이 대화의 브랜치가 아닌 곳을 보면 합치지 않는다 (예전: 커밋은 그쪽에 남고 merge 는 "Already up to date" 로
    /// 성공해 "합쳤습니다"), 합친 것이 없는 merge 는 성공이 아니다, 떼어진 HEAD 의 커밋은 정리 전에 브랜치로 남긴다 (예전: dangling).
    private static func offBranchAndDetached(_ t: TestKit, root: URL) async throws {
        await t.group("독립 작업 폴더: 다른 브랜치 · 떼어진 HEAD 에서 합치기 · 정리")
        let repo = try makeRepo(root.appendingPathComponent("offbranch"))
        let env = ProcessInfo.processInfo.environment
        guard let gitPath = GitInspector.findGit(environment: env) else { return }
        let (created, _) = await Worktrees.create(project: repo, threadID: "0FFB0001-zzzz", git: gitPath, environment: env)
        guard case .success(let worktree) = created else {
            await t.check("만들기", false, "\(created)")
            return
        }
        let folder = URL(fileURLWithPath: worktree.path)

        // 합칠 것이 없는 merge 는 성공으로 알리지 않는다.
        let (nothing, _) = await Worktrees.merge(worktree, project: repo, commitMessage: nil, git: gitPath, environment: env)
        await t.equal("합칠 커밋이 없으면 '합쳤습니다' 가 아니다", nothing, .failed(.nothingMerged(into: "main")))

        // 1) 다른 브랜치 — 커밋하지 않고 멈춘다.
        try git(["switch", "-q", "-c", "feature"], in: folder)
        try "feature\n".write(to: folder.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let (onFeature, featureSteps) = await Worktrees.merge(worktree, project: repo, commitMessage: "f 추가", git: gitPath,
                                                              environment: env)
        let pending = try git(["status", "--porcelain"], in: folder)
        await t.check("다른 브랜치면 합치지 않고 명령도 돌리지 않는다",
                      onFeature == .failed(.worktreeOffBranch(current: "feature", expected: worktree.branch)) && featureSteps.isEmpty,
                      "\(onFeature) / \(featureSteps.map(\.command))")
        await t.check("변경은 커밋되지 않고 그대로", pending.contains("f.txt"), pending)
        await t.check("알림: 지금 브랜치 · 돌아오는 명령 · 아무것도 바꾸지 않음",
                      Worktrees.Failure.worktreeOffBranch(current: "feature", expected: worktree.branch).message
                        .contains("git switch \(worktree.branch)")
                        && Worktrees.Failure.worktreeOffBranch(current: "feature", expected: worktree.branch).message
                        .contains("아무것도 바꾸지 않았습니다"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("f.txt"))
        try git(["switch", "-q", worktree.branch], in: folder)

        // 2) 떼어진 HEAD — 합치지 않고, 상태가 브랜치에 없는 커밋 수를 말한다.
        try "on branch\n".write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try git(["add", "b.txt"], in: folder)
        try git(["commit", "-qm", "b"], in: folder)
        try git(["checkout", "-q", "--detach"], in: folder)
        try "detached\n".write(to: folder.appendingPathComponent("d.txt"), atomically: true, encoding: .utf8)
        try git(["add", "d.txt"], in: folder)
        try git(["commit", "-qm", "d"], in: folder)
        let detachedHead = try git(["rev-parse", "HEAD"], in: folder).trimmingCharacters(in: .whitespacesAndNewlines)
        let (detached, detachedSteps) = await Worktrees.merge(worktree, project: repo, commitMessage: nil, git: gitPath,
                                                              environment: env)
        await t.check("떼어진 HEAD 면 합치지 않는다",
                      detached == .failed(.worktreeOffBranch(current: nil, expected: worktree.branch)) && detachedSteps.isEmpty,
                      "\(detached)")
        let status = await Worktrees.status(worktree, project: repo, git: gitPath, environment: env)
        await t.check("상태: 떼어진 HEAD · 브랜치에 없는 커밋 1개 · 이 대화의 브랜치가 아님",
                      status.folderDetached && status.strandedCommits == 1 && status.offBranch(worktree.branch)
                        && status.ahead == 1, "\(status)")
        let note = WorktreeFacts.branchMismatch(status, worktreeBranch: worktree.branch) ?? ""
        await t.check("안내: detached · 지키는 법 · 정리가 남긴다는 사실", note.contains("detached") && note.contains("1개")
                        && note.contains("git branch"), note)

        // 3) 정리: 지우기 전에 떼어진 HEAD 의 커밋을 새 브랜치로 남긴다 (이 대화의 브랜치는 지워도).
        let (removed, removeSteps) = await Worktrees.remove(worktree, project: repo, force: false, branch: .delete, git: gitPath,
                                                            environment: env)
        let saved = (try? removed.get())?.savedBranch
        let savedHead = saved.flatMap { try? git(["rev-parse", $0], in: repo) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        await t.check("떼어진 HEAD 의 커밋을 \(worktree.branch)-saved 로 남기고 정리한다",
                      saved == worktree.branch + "-saved" && savedHead == detachedHead
                        && !FileManager.default.fileExists(atPath: worktree.path)
                        && removeSteps.contains { $0.command.hasPrefix("git branch \(worktree.branch)-saved") },
                      "\(removed) / \(removeSteps.map(\.command))")
        await t.check("이 대화의 브랜치는 지시대로 지웠다", (try? git(["rev-parse", "-q", "--verify", worktree.branch], in: repo)) == nil)
    }

    /// chg-13: 프로젝트 폴더의 커밋하지 않은 변경과 겹치면 커밋 · 맞추기 전에 멈춘다 — 확인 창의 "아무것도 바꾸지 않습니다" 가 사실이 되게.
    private static func overlapStopsBeforeCommit(_ t: TestKit, root: URL) async throws {
        await t.group("독립 작업 폴더: 프로젝트 폴더의 변경과 겹치면 시작 전에 멈춘다")
        let repo = try makeRepo(root.appendingPathComponent("overlap"))
        let env = ProcessInfo.processInfo.environment
        guard let gitPath = GitInspector.findGit(environment: env) else { return }
        let (created, _) = await Worktrees.create(project: repo, threadID: "0E1A0001-yyyy", git: gitPath, environment: env)
        guard case .success(let worktree) = created else {
            await t.check("만들기", false, "\(created)")
            return
        }
        let folder = URL(fileURLWithPath: worktree.path)
        try "worktree\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)   // 커밋 안 함
        try "project\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)      // 커밋 안 함
        let (result, steps) = await Worktrees.merge(worktree, project: repo, commitMessage: "a 고침", git: gitPath,
                                                    environment: env)
        let pending = try git(["status", "--porcelain"], in: folder)
        let commits = try git(["rev-list", "--count", "main.." + worktree.branch], in: repo)
        await t.check("겹치는 파일을 이름으로 알리고 멈춘다", result == .failed(.projectChangesOverlap(["a.txt"])) && steps.isEmpty,
                      "\(result)")
        await t.check("독립 작업 폴더는 그대로 (커밋하지 않음)", pending.contains("a.txt")
                        && commits.trimmingCharacters(in: .whitespacesAndNewlines) == "0", pending + commits)
        // 겹치지 않는 변경은 막지 않는다.
        try git(["checkout", "--", "a.txt"], in: repo)
        try "elsewhere\n".write(to: repo.appendingPathComponent("z.txt"), atomically: true, encoding: .utf8)
        let (ok, okSteps) = await Worktrees.merge(worktree, project: repo, commitMessage: "a 고침", git: gitPath, environment: env)
        await t.check("겹치지 않으면 커밋하고 합친다", ok == .merged(into: "main")
                        && Worktrees.committedInWorktree(okSteps, worktree: worktree), "\(ok)")
        // 합치기가 실패한 알림: 그 전에 커밋해 두었으면 그 사실을 붙인다.
        let failedAfterCommit = AppModel.mergeFailureText(
            .git(command: "git merge --no-edit x", output: "error: Your local changes to the following files would be overwritten by merge:\n\tb.txt\nAborting"),
            steps: okSteps.filter { $0.command.hasPrefix("git commit") || $0.command.hasPrefix("git add") },
            worktree: worktree)
        await t.check("실패 알림: 겹치는 파일 이름 · 커밋해 두었다는 사실", failedAfterCommit.contains("b.txt")
                        && failedAfterCommit.contains("커밋해") && !failedAfterCommit.contains("아무것도"), failedAfterCommit)
    }

    /// chg-14 · chg-15 · chg-9 · chg-16 · chg-22: 저장소가 아니면 대화를 만들지 않는다, 만든 기록은 시작 화면을 지우지 않는다,
    /// 준비 명령은 그 대화 · 그 폴더만 막는다, 터미널에서 바꾼 브랜치를 알린다, 충돌 풀기 부탁은 쓰던 글을 덮지 않는다.
    private static func creationAndSetup(_ t: TestKit, root: URL) async throws {
        await t.group("독립 작업 폴더: 만들기 전 확인 · 시작 화면 · 준비 명령 잠금 · 브랜치 · 부탁 글")
        let repo = try makeRepo(root.appendingPathComponent("setup"))
        let plain = root.appendingPathComponent("plain-folder")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let other = try makeRepo(root.appendingPathComponent("setup-other"))
        let store = Store(databaseURL: root.appendingPathComponent("setup.sqlite3"))
        try await store.bootstrap()
        let model = AppModel(store: store)
        let project = await model.addProject(name: "setup", path: repo.path)
        let plainProject = await model.addProject(name: "plain", path: plain.path)
        let otherProject = await model.addProject(name: "other", path: other.path)
        let otherThread = await model.addThread(projectID: otherProject.id, title: "다른 프로젝트")
        await t.equal("새 대화를 만들면 사이드바에 그 프로젝트를 펴라고 알린다", model.takeSidebarReveals(), [otherProject.id])

        let before = model.allThreads().count
        let refused = await model.addThreadWithWorktree(projectID: plainProject.id)
        await t.check("저장소가 아닌 폴더: 대화를 만들지 않고 까닭을 알린다 (chg-14)",
                      refused == nil && model.allThreads().count == before
                        && model.banner?.text.contains("git 저장소가 아닌") == true, model.banner?.text ?? "")
        await t.check("만들지 않았으면 사이드바에 펴라고 알리지 않는다", model.sidebarRevealProjectIDs.isEmpty)
        await model.openWorkspace(path: plain.path)
        await t.check("읽어 둔 상태로 메뉴 항목을 끈다", AppModel.repositoryCreationShortBlock(model.workspace(forPath: plain.path)?.git) == "git 저장소가 아님")

        // 준비 명령이 도는 동안 (chg-9): 그 대화 · 그 폴더만 막고, 다른 프로젝트는 막지 않는다. 폴더는 이미 바뀌어 있다.
        model.worktreeSetupCommands[project.id] = "sleep 1.5"
        let creating = Task { await model.addThreadWithWorktree(projectID: project.id) }
        var setupThreadID: String?
        // 준비 명령의 잠금은 만들기 잠금이 풀리기 전에 걸린다 (ws-1 — 틈이 없게). 만들기 잠금이 풀리고 준비 명령만 도는 때를 본다.
        for _ in 0..<500 {
            if let id = model.worktreeSetups.keys.first, model.worktreeOperation == nil { setupThreadID = id; break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if let id = setupThreadID, let thread = model.allThreads().first(where: { $0.id == id }), let worktree = thread.worktree {
            await t.check("준비 명령 동안: 대화는 이미 독립 작업 폴더를 본다", model.projectPath(ofThread: id) == worktree.path)
            await t.equal("준비 명령 동안: 그 폴더는 막힌다", model.worktreeActivity(threadID: id, path: worktree.path)?.kind, .setup)
            await t.check("준비 명령 동안: 다른 프로젝트 · 프로젝트 폴더는 막지 않는다",
                          model.worktreeActivity(threadID: otherThread.id, path: other.path) == nil
                            && model.worktreeActivity(threadID: otherThread.id, path: repo.path) == nil
                            && model.worktreeOperation == nil)
        } else {
            await t.check("준비 명령이 돈다", false, model.banner?.text ?? "")
        }
        let created = await creating.value
        await t.check("준비 명령이 끝나면 잠금이 풀린다", model.worktreeSetups.isEmpty && created != nil)
        await t.equal("독립 작업 폴더에서 새 대화도 사이드바에 그 프로젝트를 펴라고 알린다", model.takeSidebarReveals(), [project.id])
        guard let thread = created.flatMap({ c in model.allThreads().first { $0.id == c.id } }), let worktree = thread.worktree else {
            await t.check("만들기", false, model.banner?.text ?? "")
            return
        }
        let events = try await store.events(threadID: thread.id)
        await t.check("만들며 남긴 기록(명령 · 안내 · 준비 명령)은 앱의 정리 기록이라 시작 화면을 지우지 않는다 (chg-15)",
                      !events.isEmpty && events.allSatisfy(Worktrees.isHousekeeping), events.map(\.title).joined(separator: " | "))

        // 터미널에서 독립 작업 폴더의 브랜치를 바꿨다 (chg-16).
        let folder = URL(fileURLWithPath: worktree.path)
        try git(["switch", "-q", "-c", "side"], in: folder)
        await model.refreshWorktreeStatus(threadID: thread.id)
        let status = model.worktreeStatuses[thread.id]
        await t.check("상태: 독립 작업 폴더가 지금 보는 브랜치", status?.folderBranch == "side")
        await t.check("안내: 이 대화의 브랜치가 아님", WorktreeFacts.branchMismatch(status, worktreeBranch: worktree.branch)?
                        .contains("side") == true)
        try git(["switch", "-q", worktree.branch], in: folder)
        await model.refreshWorktreeStatus(threadID: thread.id)
        await t.check("돌아오면 안내 없음", WorktreeFacts.branchMismatch(model.worktreeStatuses[thread.id],
                                                                     worktreeBranch: worktree.branch) == nil)

        // 충돌 풀기 부탁은 쓰던 글을 덮지 않는다 (chg-22).
        model.updateComposerDraft("다음 지시", for: thread.id)
        model.askAgentToResolveConflicts(threadID: thread.id, mainBranch: "main")
        let draft = model.composerDraft(for: thread.id)
        await t.check("부탁 글은 쓰던 글 뒤에 붙고 입력창에 포커스를 청한다", draft.hasPrefix("다음 지시\n\n")
                        && draft.contains("충돌") && model.composerFocusRequest?.threadID == thread.id, draft)
        model.askAgentToResolveConflicts(threadID: thread.id, mainBranch: "main")
        await t.equal("두 번 눌러도 한 번만", model.composerDraft(for: thread.id), draft)
        await store.db.close()
    }

    /// 순수 판정: porcelain 경로 · 옮기기 확인 문구 · 정리 기록 표시.
    private static func pureDecisions(_ t: TestKit) async {
        await t.group("독립 작업 폴더: 순수 판정")
        // 위치가 저장소 안에 독립 작업 폴더를 만들게 되면 받지 않는다 (ws-2).
        await t.check("저장소들을 모아 둔 폴더를 위치로 고르면 저장소 안에 생긴다",
                      Worktrees.placesInside(base: URL(fileURLWithPath: "/tmp/dev"), repositoryRoot: "/tmp/dev/myapp"))
        await t.check("프로젝트 폴더 안도 그렇다",
                      Worktrees.placesInside(base: URL(fileURLWithPath: "/tmp/dev/myapp/wt"), repositoryRoot: "/tmp/dev/myapp"))
        await t.check("저장소 밖은 괜찮다",
                      !Worktrees.placesInside(base: URL(fileURLWithPath: "/tmp/worktrees"), repositoryRoot: "/tmp/dev/myapp")
                        && !Worktrees.placesInside(base: URL(fileURLWithPath: "/tmp/dev"), repositoryRoot: "/tmp/dev/myapp-2/sub"))
        await t.equal("설정에서 고른 위치가 어느 프로젝트와 부딪치는지",
                      Worktrees.locationConflict("/tmp/dev", projectPaths: ["/tmp/other", "/tmp/dev/myapp"]), "/tmp/dev/myapp")
        await t.equal("porcelain 경로 (이름 바꾸기는 두 경로)",
                      Worktrees.porcelainPaths("R  new.txt\0old.txt\0 M a.txt\0?? dir/b.txt\0"),
                      ["new.txt", "old.txt", "a.txt", "dir/b.txt"])
        let notice = Worktrees.moveNotice(uncommitted: 5, touchedByThread: 2, hasSetupCommand: false)
        await t.check("옮기기 확인: 커밋 안 한 변경 수 · 이 대화가 고친 수 · 무시된 파일 · 준비 명령 (chg-6)",
                      notice.contains { $0.contains("5개") && $0.contains("이 대화가 고친 2개") }
                        && notice.contains { $0.contains(".env") && $0.contains("준비 명령") }, notice.joined(separator: " / "))
        await t.check("옮기기 확인: 변경 수를 모르면 수 없이 · 준비 명령이 있으면 실행한다고",
                      Worktrees.moveNotice(uncommitted: nil, touchedByThread: 0, hasSetupCommand: true)
                        .contains { $0.contains("실행합니다") }
                        && !Worktrees.moveNotice(uncommitted: nil, touchedByThread: 0, hasSetupCommand: true)
                            .contains { $0.contains("개") })
        await t.check("옮기기 확인: 깨끗하면 변경 줄 없음",
                      Worktrees.moveNotice(uncommitted: 0, touchedByThread: 0, hasSetupCommand: false).count == 2)
        let marked = ThreadEvent(threadID: "t", kind: .systemNotice, provider: nil, title: "독립 작업 폴더", text: "",
                                 payloadJSON: JSONUtil.line([Worktrees.housekeepingKey: true]))
        let plain = ThreadEvent(threadID: "t", kind: .systemNotice, provider: nil, title: "안내", text: "")
        await t.check("정리 기록 표시를 가린다", Worktrees.isHousekeeping(marked) && !Worktrees.isHousekeeping(plain))
        await t.equal("쓰던 글이 없으면 부탁만", AppModel.appendingRequest("부탁", to: "  \n"), "부탁")
        await t.equal("쓰던 글 뒤에 빈 줄 하나", AppModel.appendingRequest("부탁", to: "글\n"), "글\n\n부탁")
        await t.check("이름 · 프로젝트 폴더 · 독립 작업 폴더 말 (chg-7 · txt-6)",
                      Worktrees.Failure.missingFolder("/x").message.hasPrefix("독립 작업 폴더")
                        && Worktrees.Failure.detachedMain.message.contains("프로젝트 폴더에서 브랜치를 고르세요")
                        && !Worktrees.Failure.detachedMain.message.contains("본 폴더"))
    }

    private static func appFlow(_ t: TestKit, root: URL) async throws {
        await t.group("독립 작업 폴더: 만들기 → 그 폴더에서 실행 → 합치기 → 정리")
        let repo = try makeRepo(root.appendingPathComponent("app"))
        let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
        try await store.bootstrap()
        let project = Project(name: "app", path: repo.path)
        try await store.upsertProject(project)
        var thread = ConversationThread(projectID: project.id, title: "b 추가")
        thread.claudeSelection = ModelSelection(model: "sonnet", effort: "high")
        try await store.upsertThread(thread)

        let model = AppModel(store: store)
        final class Requests { var list: [AgentTurnRequest] = [] }
        let requests = Requests()
        model.runner.adapterFactory = { provider in
            ScriptedAgentAdapter(provider: provider) { request in
                requests.list.append(request)
                try? "new\n".write(to: request.workingDirectory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
                return [.emit(.sessionEstablished(sessionID: "s", model: "fake", cliVersion: nil)),
                        .emit(.assistantMessage("ok")),
                        .finish(AgentTurnResult(state: .completed, terminalReason: "completed", sessionID: "s"))]
            }
        }
        await model.reloadProjects()
        await model.selectThread(thread.id)
        func idle() async {
            for _ in 0..<500 where model.runner.session(threadID: thread.id) != nil || model.isStartingRun(threadID: thread.id) {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        let created = await model.createWorktree(threadID: thread.id)
        guard let worktree = model.allThreads().first(where: { $0.id == thread.id })?.worktree else {
            await t.check("만들기", false, model.banner?.text ?? "")
            return
        }
        let saved = try await store.thread(id: thread.id)
        await t.check("만들기: 대화에 저장 · 폴더와 브랜치가 생긴다", created
                        && FileManager.default.fileExists(atPath: worktree.path) && worktree.branch.hasPrefix("ahc/")
                        && worktree.baseBranch == "main" && saved?.worktree == worktree)
        await t.equal("대화의 폴더 = 작업 폴더 (인스펙터 · 보내기가 본다)", model.projectPath(ofThread: thread.id), worktree.path)

        _ = await model.send("b 를 만들어", provider: .claude, threadID: thread.id)
        await idle()
        await t.equal("에이전트는 작업 폴더에서 돈다", requests.list.last?.workingDirectory.path, worktree.path)
        await t.check("프로젝트 폴더는 그대로", !FileManager.default.fileExists(atPath: repo.appendingPathComponent("b.txt").path))

        // 그 사이 본 브랜치가 움직였다 (겹치지 않는 파일).
        try "c\n".write(to: repo.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try git(["add", "c.txt"], in: repo)
        try git(["commit", "-qm", "c"], in: repo)
        await model.refreshWorktreeStatus(threadID: thread.id)
        let before = model.worktreeStatuses[thread.id]
        await t.check("상태: 커밋 안 한 변경 1 · 본 브랜치에 새 커밋 1", before?.uncommitted == 1 && before?.behind == 1
                        && before?.ahead == 0 && before?.mainBranch == "main", String(describing: before))

        let merged = await model.mergeWorktree(threadID: thread.id, commitMessage: "b 추가")
        let mainLog = try git(["log", "--format=%s", "main"], in: repo)
        await t.check("합치기: 커밋하고 본 브랜치를 먼저 받은 뒤 main 에 들어간다", merged
                        && FileManager.default.fileExists(atPath: repo.appendingPathComponent("b.txt").path)
                        && mainLog.contains("b 추가") && (try? git(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: repo)) == nil,
                      model.banner?.text ?? mainLog)
        await model.refreshWorktreeStatus(threadID: thread.id)
        await t.check("합친 뒤: 합칠 것 없음", model.worktreeStatuses[thread.id]?.fullyMerged == true)

        let removed = await model.removeWorktree(threadID: thread.id, force: false, branch: .deleteIfMerged)
        let branches = try git(["branch", "--format=%(refname:short)"], in: repo)
        let afterRemoval = try await store.thread(id: thread.id)
        await t.check("정리: 폴더 · 브랜치를 지우고 대화는 프로젝트 폴더로", removed
                        && !FileManager.default.fileExists(atPath: worktree.path) && !branches.contains(worktree.branch)
                        && model.projectPath(ofThread: thread.id) == repo.path
                        && afterRemoval != nil && afterRemoval?.worktree == nil, model.banner?.text ?? branches)

        // 이어지는 CLI 세션이 있던 대화: 다음 턴에만 폴더가 바뀌었다는 안내가 붙는다 (기록의 사용자 글에는 없다).
        _ = await model.send("계속", provider: .claude, threadID: thread.id)
        await idle()
        let userTexts = try await store.events(threadID: thread.id).filter { $0.kind == .userMessage }.map(\.text)
        await t.check("폴더를 옮긴 뒤 첫 턴에 안내를 붙인다 · 기록에는 사용자 글만",
                      requests.list.last?.prompt.hasPrefix("[앱 안내]") == true && requests.list.last?.prompt.hasSuffix("계속") == true
                        && userTexts.last == "계속" && model.folderMoveNotes.isEmpty, requests.list.last?.prompt ?? "")
    }

    /// 작업 폴더가 있는 대화 지우기: 상태를 모르면 강제하지 않는다 — 커밋하지 않은 변경이 있으면 폴더 · 대화를 남긴다.
    /// 확인 창이 사라질 변경 수를 보였을 때(상태를 읽음)만 버린다.
    private static func deleteKeepsUnknownChanges(_ t: TestKit, root: URL) async throws {
        await t.group("독립 작업 폴더: 대화를 지울 때 커밋하지 않은 변경")
        let repo = try makeRepo(root.appendingPathComponent("delete"))
        let store = Store(databaseURL: root.appendingPathComponent("delete.sqlite3"))
        try await store.bootstrap()
        let project = Project(name: "delete", path: repo.path)
        try await store.upsertProject(project)
        var thread = ConversationThread(projectID: project.id, title: "지울 대화")
        thread.claudeSelection = ModelSelection(model: "sonnet", effort: "high")
        try await store.upsertThread(thread)
        let model = AppModel(store: store)
        await model.reloadProjects()
        guard await model.createWorktree(threadID: thread.id),
              let withFolder = model.allThreads().first(where: { $0.id == thread.id }), let worktree = withFolder.worktree else {
            await t.check("만들기", false, model.banner?.text ?? "")
            return
        }
        try "작업 중\n".write(to: URL(fileURLWithPath: worktree.path).appendingPathComponent("draft.txt"),
                             atomically: true, encoding: .utf8)
        model.worktreeStatuses[thread.id] = nil
        await model.deleteThread(withFolder)
        let kept = try await store.thread(id: thread.id)
        await t.check("상태를 모르면 강제하지 않는다 — 변경이 있는 폴더와 대화가 남는다",
                      FileManager.default.fileExists(atPath: worktree.path) && kept != nil, model.banner?.text ?? "알림 없음")
        await model.refreshWorktreeStatus(threadID: thread.id)
        await t.equal("상태를 읽으면 사라질 변경 수가 보인다", model.worktreeStatuses[thread.id]?.uncommitted, 1)
        await model.deleteThread(withFolder)
        let gone = try await store.thread(id: thread.id)
        await t.check("확인 창이 변경 수를 보인 뒤에는 지운다", !FileManager.default.fileExists(atPath: worktree.path) && gone == nil,
                      model.banner?.text ?? "")
    }

    private static func conflictAndSubfolder(_ t: TestKit, root: URL) async throws {
        await t.group("독립 작업 폴더: 충돌은 작업 폴더에서 · 하위 폴더 프로젝트")
        let repo = try makeRepo(root.appendingPathComponent("conflict"))
        let env = ProcessInfo.processInfo.environment
        guard let gitPath = GitInspector.findGit(environment: env) else {
            await t.check("git", false)
            return
        }
        let (created, _) = await Worktrees.create(project: repo, threadID: "C0FFEE11-aaaa", git: gitPath, environment: env)
        guard case .success(let worktree) = created else {
            await t.check("만들기", false, "\(created)")
            return
        }
        let folder = URL(fileURLWithPath: worktree.path)
        try "worktree\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-qam", "w"], in: folder)
        try "main\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-qam", "m"], in: repo)
        let (result, _) = await Worktrees.merge(worktree, project: repo, commitMessage: nil, git: gitPath, environment: env)
        let mainText = try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8)
        await t.check("충돌: 작업 폴더에서 멈추고 프로젝트 폴더는 그대로", result == .conflictInWorktree(files: ["a.txt"])
                        && mainText == "main\n" && (try? git(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: repo)) == nil,
                      "\(result)")
        let status = await Worktrees.status(worktree, project: repo, git: gitPath, environment: env)
        await t.check("충돌 중인 작업 폴더는 병합 중으로 보인다", status.midOperation)
        let (removed, _) = await Worktrees.remove(worktree, project: repo, force: true, branch: .delete, git: gitPath, environment: env)
        await t.check("버리고 정리", (try? removed.get()) == Worktrees.Removal(branchKept: false, savedBranch: nil)
                        && !FileManager.default.fileExists(atPath: worktree.path))

        // 프로젝트가 저장소의 하위 폴더: 작업 폴더도 worktree 안의 같은 하위 폴더.
        let sub = repo.appendingPathComponent("pkg")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "x\n".write(to: sub.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["commit", "-qm", "pkg"], in: repo)
        let (inSub, _) = await Worktrees.create(project: sub, threadID: "5AB00000", git: gitPath, environment: env)
        guard case .success(let subTree) = inSub else {
            await t.check("하위 폴더 만들기", false, "\(inSub)")
            return
        }
        await t.check("하위 폴더 프로젝트: 작업 폴더는 worktree/pkg", subTree.path.hasSuffix("/pkg")
                        && FileManager.default.fileExists(atPath: subTree.path + "/x.txt"), subTree.path)
        let (subRemoved, _) = await Worktrees.remove(subTree, project: sub, force: false, branch: .deleteIfMerged,
                                                     git: gitPath, environment: env)
        let subRoot = URL(fileURLWithPath: subTree.path).deletingLastPathComponent().path
        await t.check("하위 폴더 프로젝트 정리: worktree 뿌리째", (try? subRemoved.get()) != nil
                        && !FileManager.default.fileExists(atPath: subRoot), subRoot)
    }

    private static func sessionFiles(_ t: TestKit, root: URL) async {
        await t.group("독립 작업 폴더: Claude 세션 기록을 새 폴더의 칸으로")
        let projects = root.appendingPathComponent("claude-projects")
        let old = projects.appendingPathComponent("-old")
        try? FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try? "{}\n".write(to: old.appendingPathComponent("abc.jsonl"), atomically: true, encoding: .utf8)
        let target = root.appendingPathComponent("new.folder_1")
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let copied = ClaudeSessionFiles.copy(sessionID: "abc", toFolder: target.path, projects: projects)
        let key = ClaudeSessionFiles.folderKey(for: target.path) ?? ""
        await t.check("영숫자가 아닌 글자는 - 인 칸에 복사한다", copied && key.hasSuffix("-new-folder-1")
                        && FileManager.default.fileExists(atPath: projects.appendingPathComponent(key + "/abc.jsonl").path), key)

        // 독립 작업 폴더에서 이어 쓴 기록이 정리 때 프로젝트 폴더로 돌아온다 — 프로젝트 폴더 칸의 옛 사본을 바꾼다.
        // (예전: 대상이 이미 있으면 그대로 두어, 다음 --resume 이 옛 사본으로 성공하고 그 폴더에서 한 대화가 조용히 빠졌다.)
        let fm = FileManager.default
        let from = root.appendingPathComponent("worktree-from")
        let to = root.appendingPathComponent("project-to")
        try? fm.createDirectory(at: from, withIntermediateDirectories: true)
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        let fromKey = ClaudeSessionFiles.folderKey(for: from.path) ?? ""
        let toKey = ClaudeSessionFiles.folderKey(for: to.path) ?? ""
        func write(_ text: String, _ dir: String, age: TimeInterval) {
            let url = projects.appendingPathComponent(dir).appendingPathComponent("s2.jsonl")
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        func read(_ dir: String) -> String? {
            try? String(contentsOf: projects.appendingPathComponent(dir).appendingPathComponent("s2.jsonl"), encoding: .utf8)
        }
        write("옮기기 전\n", toKey, age: 3600)
        write("옮기기 전\n작업 폴더에서 이어 씀\n", fromKey, age: 60)
        write("다른 칸\n", "-somewhere-else", age: 0)
        try? fm.removeItem(at: from)   // 정리로 작업 폴더가 먼저 지워진 뒤에 부른다 — 지운 폴더의 칸 이름도 같아야 한다
        let back = ClaudeSessionFiles.copy(sessionID: "s2", fromFolder: from.path, toFolder: to.path, projects: projects)
        await t.check("떠난 폴더의 더 새 기록으로 옛 사본을 바꾼다 (다른 칸이 아니라)",
                      back && read(toKey) == "옮기기 전\n작업 폴더에서 이어 씀\n", read(toKey) ?? "없음")
        let leftovers = (try? fm.contentsOfDirectory(atPath: projects.appendingPathComponent(toKey).path)) ?? []
        await t.check("임시 파일을 남기지 않는다", leftovers == ["s2.jsonl"], leftovers.joined(separator: ", "))
        // 대상이 더 새것이면(옮긴 뒤 거기서 따로 이어 썼다) 덮지 않는다.
        write("프로젝트 폴더에서 더 이어 씀\n", toKey, age: 0)
        write("작업 폴더의 옛 기록\n", fromKey, age: 600)
        _ = ClaudeSessionFiles.copy(sessionID: "s2", fromFolder: from.path, toFolder: to.path, projects: projects)
        await t.equal("대상이 더 새것이면 그대로", read(toKey), "프로젝트 폴더에서 더 이어 씀\n")
        // 떠난 폴더를 모르면 예전처럼 — 이미 있으면 그대로.
        write("옛 사본\n", toKey, age: 3600)
        _ = ClaudeSessionFiles.copy(sessionID: "s2", toFolder: to.path, projects: projects)
        await t.equal("떠난 폴더를 모르면 있는 사본을 그대로", read(toKey), "옛 사본\n")
    }

    // MARK: git

    private static func makeRepo(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: url)
        try git(["config", "user.name", "inttest"], in: url)
        try git(["config", "user.email", "inttest@example.invalid"], in: url)
        try "a\n".write(to: url.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: url)
        try git(["commit", "-qm", "a"], in: url)
        return url
    }

    struct GitError: Error, CustomStringConvertible { var description: String }

    @discardableResult
    private static func git(_ args: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitError(description: "git \(args.joined(separator: " "))") }
        return String(decoding: data, as: UTF8.self)
    }
}
