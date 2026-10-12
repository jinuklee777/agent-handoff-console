import Foundation
import Darwin

/// 대화별 독립 작업 폴더 (git worktree) 의 git 명령과 판정. 앱 상태(잠금 · 대화 · 화면)는 모른다 — 그것은 `AppModel+Worktree`.
///
/// 한 대화 = 한 worktree = 한 브랜치(`ahc/<대화 앞 8자>`). 프로젝트 저장소의 지금 HEAD 에서 가지를 친다 — 프로젝트 폴더의 커밋하지
/// 않은 변경은 따라가지 않는다. 끝나면 프로젝트 폴더의 지금 브랜치로 합치고(`merge`) 정리한다(`remove`).
/// 합치기는 **먼저 독립 작업 폴더에서** 프로젝트 폴더의 브랜치를 받아 충돌을 거기서 풀게 하고(`catchUp`), 그 뒤 프로젝트 폴더에서는
/// 충돌 없이 합친다 — 사용자가 보고 있는 프로젝트 폴더를 충돌 상태로 남기지 않는다. 프로젝트 폴더가 병합 · rebase 중이거나 그 폴더의
/// 커밋하지 않은 변경과 겹치면 아무것도 하지 않고 멈춘다 (사람이 풀던 충돌을 지우지 않게 — `merge`).
enum Worktrees {
    // MARK: 위치 · 이름

    /// 작업 폴더들을 두는 곳. `AHC_WORKTREES_DIR` 가 있으면 그것, 사람이 설정 > 고급에서 고른 곳(`userBaseDirectory`)이 있으면 그것,
    /// `AHC_DATABASE_PATH`(화면 확인 · 시험의 임시 DB)가 있으면 그 옆 `worktrees` (사용자 홈을 어지럽히지 않게),
    /// 아니면 `~/.agent-handoff-console/worktrees`. 이미 만든 작업 폴더는 대화에 경로가 남아 있어 위치를 바꿔도 옮기지 않는다.
    /// 앱 데이터(Application Support) 밑에 두지 않는다 — 에이전트 · 터미널이 다루는 경로에 공백이 들어가지 않게.
    static func baseDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["AHC_WORKTREES_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        if let chosen = userBaseDirectory, !chosen.isEmpty {
            return URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath)
        }
        if let db = environment["AHC_DATABASE_PATH"], !db.isEmpty {
            return URL(fileURLWithPath: db).deletingLastPathComponent().appendingPathComponent("worktrees")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-handoff-console/worktrees")
    }

    /// 사람이 고른 위치 (`AppModel.worktreesDirectoryOverride` 가 넣는다 — 설정 `worktrees_dir`). nil 이면 기본 위치.
    nonisolated(unsafe) private static var chosenBase: String?
    private static let chosenBaseLock = UnfairLock()
    static var userBaseDirectory: String? {
        get { chosenBaseLock.withLock { chosenBase } }
        set { chosenBaseLock.withLock { chosenBase = newValue } }
    }

    /// 대화 ID 앞 8자 (영숫자만, 소문자).
    static func shortID(_ threadID: String) -> String {
        let alnum = threadID.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return String(alnum.prefix(8)).isEmpty ? "thread" : String(alnum.prefix(8))
    }

    static func branchName(threadID: String) -> String { "ahc/" + shortID(threadID) }

    /// 저장소 폴더 이름을 경로에 쓸 수 있게 (영숫자 · `-` · `_` · `.` 만, 나머지는 `-`).
    static func folderName(repositoryRoot: String) -> String {
        let name = URL(fileURLWithPath: repositoryRoot).lastPathComponent
        let cleaned = String(name.map { c -> Character in
            (c.isASCII && (c.isLetter || c.isNumber)) || c == "-" || c == "_" || c == "." ? c : "-"
        }).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return cleaned.isEmpty ? "repo" : cleaned
    }

    /// `base` 에 이 저장소의 독립 작업 폴더를 만들면(`<base>/<저장소 이름>/<대화>`) 그 저장소의 작업 트리 안에 생기는가 (순수 — 경로만).
    /// 저장소들을 모아 둔 폴더(~/Developer)나 프로젝트 폴더를 위치로 고르면 그렇다 — 작업 폴더가 프로젝트의 새 파일로 보이고 커밋에
    /// 섞였다 (ws-2 · set-n9).
    static func placesInside(base: URL, repositoryRoot: String) -> Bool {
        let root = canonicalPath(repositoryRoot)
        let parent = canonicalPath(base.appendingPathComponent(folderName(repositoryRoot: repositoryRoot)).path)
        return parent == root || parent.hasPrefix(root + "/")
    }

    /// 설정 > 고급에서 고른 위치가 등록된 프로젝트의 작업 트리 안에 독립 작업 폴더를 만들게 되는가 — 그러면 그 프로젝트 폴더 (없으면 nil).
    static func locationConflict(_ chosen: String, projectPaths: [String]) -> String? {
        let base = URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath)
        return projectPaths.first { placesInside(base: base, repositoryRoot: $0) }
    }

    /// 심볼릭 링크를 풀고 표준화한 경로 (없는 끝 부분은 그대로).
    static func canonicalPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 앱이 만든 작업 폴더인지 (기록 가져오기에서 뺄 때).
    static func isManaged(path: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let base = baseDirectory(environment: environment).path
        return path == base || path.hasPrefix(base + "/") || path.contains("/.agent-handoff-console/worktrees/")
    }

    // MARK: 실패

    enum Failure: Error, Equatable {
        case notRepository
        case noCommits
        case detachedMain
        case missingFolder(String)
        /// 프로젝트 폴더(합칠 곳)가 병합 · cherry-pick · revert · rebase 중이다. 아무것도 하지 않았다.
        case projectBusy(MidOperation)
        /// 합치면 바뀔 파일에 프로젝트 폴더의 커밋하지 않은 변경(새 파일 포함)이 있다 — git 이 거절할 합치기. 아무것도 하지 않았다.
        case projectChangesOverlap([String])
        /// 독립 작업 폴더를 둘 곳이 그 저장소의 작업 트리 안이다 (`placesInside`). 아무것도 만들지 않았다.
        case locationInsideRepository(location: String, repository: String)
        /// 독립 작업 폴더가 이 대화의 브랜치(`expected`)가 아닌 곳을 보고 있다 — 다른 브랜치(`current`) 또는 떼어진 HEAD(`current` nil).
        /// 합치기는 이 대화의 브랜치만 합치므로, 그대로 커밋하면 그 커밋은 합쳐지지 않는다. 아무것도 하지 않았다.
        case worktreeOffBranch(current: String?, expected: String)
        /// merge 는 성공했는데 프로젝트 폴더의 HEAD 가 그대로다 — 합친 것이 없다 ("Already up to date").
        case nothingMerged(into: String)
        case git(command: String, output: String)

        var message: String {
            switch self {
            case .notRepository: return "git 저장소가 아닌 폴더에서는 독립 작업 폴더를 만들 수 없습니다."
            case .noCommits: return "첫 커밋이 없는 저장소입니다. 커밋을 하나 만든 뒤에 독립 작업 폴더를 만들 수 있습니다."
            case .detachedMain: return "프로젝트 폴더가 브랜치가 아닌 커밋을 가리키고 있어(detached) 합칠 곳이 없습니다. 프로젝트 폴더에서 브랜치를 고르세요."
            case .missingFolder(let path): return "독립 작업 폴더가 없습니다: \(path)"
            case .projectBusy(let operation):
                return "프로젝트 폴더가 \(operation.koreanName) 중이라 합치지 않았습니다 — 아무것도 바꾸지 않았습니다. "
                    + "그 작업을 마치거나 멈춘 뒤 다시 합치세요."
            case .projectChangesOverlap(let files):
                return "프로젝트 폴더의 커밋하지 않은 변경과 겹쳐 합치지 않았습니다"
                    + (GitFailure.fileList(files).map { ": \($0)" } ?? "") + " — 아무것도 바꾸지 않았습니다. "
                    + "프로젝트 폴더에서 그 변경을 커밋하거나 치운 뒤 다시 합치세요."
            case .locationInsideRepository(let location, let repository):
                return "독립 작업 폴더를 둘 곳(\(location))에 만들면 저장소(\(repository)) 안에 생겨 프로젝트의 커밋에 섞입니다 — "
                    + "만들지 않았습니다. 설정 > 고급 > 독립 작업 폴더에서 저장소 밖의 위치를 고르세요."
            case .worktreeOffBranch(let current?, let expected):
                return "독립 작업 폴더가 지금 \(current) 브랜치에 있어 합치지 않았습니다 — 아무것도 바꾸지 않았습니다. "
                    + "합치기는 이 대화의 브랜치 \(expected) 의 커밋만 합칩니다. 터미널에서 돌아오세요: git switch \(expected)"
            case .worktreeOffBranch(nil, let expected):
                return "독립 작업 폴더가 브랜치가 아닌 커밋(detached HEAD)을 보고 있어 합치지 않았습니다 — 아무것도 바꾸지 않았습니다. "
                    + "합치기는 이 대화의 브랜치 \(expected) 의 커밋만 합칩니다. 지금 커밋을 지키려면 터미널에서 git branch <새 이름> 으로 "
                    + "브랜치를 만든 뒤 git switch \(expected) 로 돌아오세요."
            case .nothingMerged(let branch):
                return "합칠 커밋이 없어 \(branch) 에 아무것도 합치지 않았습니다."
            case .git(let command, let output):
                return command + (output.isEmpty ? "" : "\n" + JSONUtil.truncate(output, max: 600))
            }
        }
    }

    /// 저장소에서 진행 중인 git 작업 (충돌을 푸는 중일 수 있다). 그동안 그 폴더에 합치지 않는다.
    enum MidOperation: String, Sendable, Equatable {
        case merge, cherryPick, revert, rebase

        /// "프로젝트 폴더가 병합 중" 처럼 "… 중" 앞에 쓰는 이름.
        var koreanName: String {
            switch self {
            case .merge: return "병합"
            case .cherryPick: return "cherry-pick"
            case .revert: return "revert"
            case .rebase: return "rebase"
            }
        }
    }

    /// 한 단계의 git 명령과 결과 (대화에 남긴다).
    struct Step: Sendable, Equatable {
        var command: String
        var output: String
        var succeeded: Bool
        var directory: String
    }

    // MARK: 만들기

    /// 그 폴더에서 독립 작업 폴더를 만들 수 없는 이유 (저장소가 아님 · 첫 커밋 없음). 만들 수 있으면 nil.
    /// 대화를 먼저 만들기 전에 본다 — 만들지 못할 폴더에 빈 대화만 생기지 않게 (chg-14).
    static func creationProblem(project: URL, git: String, environment env: [String: String]) async -> Failure? {
        guard await value(git, ["rev-parse", "--show-toplevel"], in: project, env: env) != nil else { return .notRepository }
        guard await value(git, ["rev-parse", "--verify", "-q", "HEAD^{commit}"], in: project, env: env) != nil else {
            return .noCommits
        }
        return nil
    }

    /// 프로젝트 폴더의 저장소에서 새 worktree 를 만든다. 프로젝트가 저장소의 하위 폴더면 작업 폴더도 worktree 안의 같은 하위 폴더.
    static func create(project: URL, threadID: String, git: String, environment env: [String: String],
                       base: URL = baseDirectory()) async -> (Result<ThreadWorktree, Failure>, [Step]) {
        var steps: [Step] = []
        guard let root = await value(git, ["rev-parse", "--show-toplevel"], in: project, env: env) else {
            return (.failure(.notRepository), steps)
        }
        guard let head = await value(git, ["rev-parse", "--verify", "-q", "HEAD^{commit}"], in: project, env: env) else {
            return (.failure(.noCommits), steps)
        }
        let branchNow = await value(git, ["symbolic-ref", "--short", "-q", "HEAD"], in: project, env: env)
        let prefix = await value(git, ["rev-parse", "--show-prefix"], in: project, env: env) ?? ""

        let parent = base.appendingPathComponent(folderName(repositoryRoot: root))
        guard !placesInside(base: base, repositoryRoot: root) else {
            return (.failure(.locationInsideRepository(location: base.path, repository: root)), steps)
        }
        let id = shortID(threadID)
        var folder = parent.appendingPathComponent(id)
        var branch = branchName(threadID: threadID)
        var n = 2
        func taken() async -> Bool {
            if FileManager.default.fileExists(atPath: folder.path) { return true }
            return await value(git, ["show-ref", "--verify", "-q", "refs/heads/" + branch], in: project, env: env,
                               allowEmpty: true) != nil
        }
        while await taken() {
            folder = parent.appendingPathComponent("\(id)-\(n)")
            branch = branchName(threadID: threadID) + "-\(n)"
            n += 1
            if n > 50 { break }
        }
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let add = await run(git, ["worktree", "add", "-b", branch, folder.path, head], in: URL(fileURLWithPath: root), env: env)
        steps.append(add)
        guard add.succeeded else { return (.failure(.git(command: add.command, output: add.output)), steps) }
        let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = trimmed.isEmpty ? folder.path : folder.appendingPathComponent(trimmed).path
        return (.success(ThreadWorktree(path: path, branch: branch, baseBranch: branchNow, baseCommit: head)), steps)
    }

    /// 지워진 작업 폴더를 같은 브랜치로 다시 만든다 (사용자가 Finder 에서 지웠을 때).
    static func restore(_ worktree: ThreadWorktree, project: URL, git: String,
                        environment env: [String: String]) async -> (Result<Void, Failure>, [Step]) {
        var steps: [Step] = []
        let prune = await run(git, ["worktree", "prune"], in: project, env: env)
        steps.append(prune)
        let prefix = await value(git, ["rev-parse", "--show-prefix"], in: project, env: env) ?? ""
        let root = rootPath(of: worktree, prefix: prefix)
        let add = await run(git, ["worktree", "add", root, worktree.branch], in: project, env: env)
        steps.append(add)
        return (add.succeeded ? .success(()) : .failure(.git(command: add.command, output: add.output)), steps)
    }

    /// 작업 폴더 경로에서 프로젝트 하위 폴더(`prefix`)를 떼어 낸 worktree 의 뿌리.
    static func rootPath(of worktree: ThreadWorktree, prefix: String) -> String {
        let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, worktree.path.hasSuffix("/" + trimmed) else { return worktree.path }
        return String(worktree.path.dropLast(trimmed.count + 1))
    }

    // MARK: 상태

    /// 합치기 · 정리 화면이 보는 사실. 읽지 못한 값은 nil (짐작하지 않는다).
    struct Status: Sendable, Equatable {
        var folderExists = true
        /// 프로젝트 폴더의 지금 브랜치 (합칠 곳). detached 면 nil.
        var mainBranch: String?
        /// 이 대화의 브랜치에만 있는 커밋 수 (`mainBranch..branch`).
        var ahead: Int?
        /// 프로젝트 폴더의 브랜치에만 있는 커밋 수 (`branch..mainBranch`) — 따라잡을 것.
        var behind: Int?
        /// 독립 작업 폴더의 커밋하지 않은 변경 (추적 안 하는 파일 포함).
        var uncommitted: Int?
        /// 독립 작업 폴더에서 진행 중인 git 작업 (충돌을 푸는 중인 병합 · rebase 등). 없으면 nil.
        var folderOperation: MidOperation?
        /// 프로젝트 폴더(합칠 곳)에서 진행 중인 git 작업 — 있으면 합치지 않는다 (chg-1).
        var projectOperation: MidOperation?
        /// 독립 작업 폴더가 지금 가리키는 브랜치 (터미널에서 바꿨을 수 있다). 떼어진 HEAD 거나 읽지 못하면 nil.
        var folderBranch: String?
        /// 독립 작업 폴더가 브랜치가 아닌 커밋을 보고 있다 (detached HEAD — 터미널 · 에이전트가 `git checkout <커밋>` 했을 때).
        var folderDetached = false
        /// 떼어진 HEAD 에서만: 어느 브랜치 · 태그 · 원격에도 없는 커밋 수 — 그대로 정리하면 git 이 HEAD 기록째 지워 잃는다
        /// (`Worktrees.remove` 가 그 전에 브랜치로 남긴다).
        var strandedCommits: Int?
        /// 이 대화의 브랜치가 아직 있는지.
        var branchExists = true

        /// 독립 작업 폴더가 병합 · rebase 중이다 (충돌을 푸는 중).
        var midOperation: Bool { folderOperation != nil }

        /// 독립 작업 폴더가 이 대화의 브랜치(`branch`)가 아닌 곳을 본다 (다른 브랜치 · 떼어진 HEAD). 읽지 못했으면 false.
        func offBranch(_ branch: String) -> Bool {
            guard folderExists else { return false }
            if folderDetached { return true }
            guard let folderBranch else { return false }
            return folderBranch != branch
        }

        /// 합쳐 넣을 것이 없다 (프로젝트 폴더의 브랜치가 이미 다 가졌다).
        var fullyMerged: Bool { ahead == 0 && (uncommitted ?? 0) == 0 }
    }

    static func status(_ worktree: ThreadWorktree, project: URL, git: String,
                       environment env: [String: String]) async -> Status {
        var status = Status()
        let folder = URL(fileURLWithPath: worktree.path)
        status.folderExists = FileManager.default.fileExists(atPath: worktree.path)
        status.mainBranch = await value(git, ["symbolic-ref", "--short", "-q", "HEAD"], in: project, env: env)
        status.branchExists = await value(git, ["show-ref", "--verify", "-q", "refs/heads/" + worktree.branch],
                                          in: project, env: env, allowEmpty: true) != nil
        if let main = status.mainBranch, status.branchExists {
            status.ahead = await value(git, ["rev-list", "--count", main + ".." + worktree.branch], in: project, env: env)
                .flatMap { Int($0) }
            status.behind = await value(git, ["rev-list", "--count", worktree.branch + ".." + main], in: project, env: env)
                .flatMap { Int($0) }
        }
        status.projectOperation = await midOperation(in: project, git: git, environment: env)
        if status.folderExists {
            if let porcelain = await porcelainStatus(git, in: folder, env: env) {
                status.uncommitted = porcelainCount(porcelain)
            }
            status.folderOperation = await midOperation(in: folder, git: git, environment: env)
            status.folderBranch = await value(git, ["symbolic-ref", "--short", "-q", "HEAD"], in: folder, env: env)
            if status.folderBranch == nil, let stranded = await strandedCommitCount(in: folder, git: git, environment: env) {
                status.folderDetached = true
                status.strandedCommits = stranded
            }
        }
        return status
    }

    /// 그 폴더의 HEAD 가 떼어져(detached) 있으면 어느 브랜치 · 태그 · 원격에도 없는 커밋 수. 브랜치에 있거나 · HEAD 가 없거나 ·
    /// 읽지 못하면 nil. 정리(`git worktree remove`)는 그 폴더의 HEAD 기록까지 지우므로 이 커밋은 dangling 이 된다.
    static func strandedCommitCount(in folder: URL, git: String, environment env: [String: String]) async -> Int? {
        guard await value(git, ["symbolic-ref", "--short", "-q", "HEAD"], in: folder, env: env) == nil else { return nil }
        return await value(git, ["rev-list", "--count", "HEAD", "--not", "--branches", "--tags", "--remotes"],
                           in: folder, env: env).flatMap { Int($0) }
    }

    /// 그 폴더의 저장소(worktree 마다 따로)가 병합 · cherry-pick · revert · rebase(· `git am`) 중인지. 아니면 nil.
    /// 읽지 못한 것은 진행 중이 아닌 것으로 본다 — 합치기 직전에 다시 보고, git 도 진행 중인 작업 위에 합치지 않는다.
    /// git 이 진행 중에 두는 파일 · 폴더(`MERGE_HEAD` · `CHERRY_PICK_HEAD` · `REVERT_HEAD` · `rebase-merge` · `rebase-apply`)의 자리를
    /// 한 번에 물어 있는지만 본다 (상태를 다시 읽을 때마다 돌므로 명령 하나로).
    static func midOperation(in directory: URL, git: String, environment env: [String: String]) async -> MidOperation? {
        let markers: [(String, MidOperation)] = [("MERGE_HEAD", .merge), ("CHERRY_PICK_HEAD", .cherryPick),
                                                 ("REVERT_HEAD", .revert), ("rebase-merge", .rebase), ("rebase-apply", .rebase)]
        guard let output = await value(git, ["rev-parse", "--path-format=absolute"] + markers.flatMap { ["--git-path", $0.0] },
                                       in: directory, env: env) else { return nil }
        let paths = output.split(separator: "\n").map { GitWorkspace.resolveGitPath(String($0), relativeTo: directory) }
        guard paths.count == markers.count else { return nil }
        for (path, marker) in zip(paths, markers) where FileManager.default.fileExists(atPath: path) {
            return marker.1
        }
        return nil
    }

    /// `status --porcelain -z` 의 항목 수. 이름 바꾸기 · 복사(`R` · `C`)는 원래 이름을 다음 칸에 한 번 더 쓴다.
    static func porcelainCount(_ output: String) -> Int {
        var count = 0
        var skipNext = false
        for entry in GitWorkspace.splitNul(output) where !entry.isEmpty {
            if skipNext { skipNext = false; continue }
            count += 1
            let code = entry.prefix(2)
            if code.contains("R") || code.contains("C") { skipNext = true }
        }
        return count
    }

    /// `status --porcelain -z` 에 나온 경로 (저장소 루트 기준). 이름 바꾸기 · 복사는 원래 이름도 함께 — 둘 다 합치기가 건드린다.
    static func porcelainPaths(_ output: String) -> [String] {
        var paths: [String] = []
        var originalNext = false
        for entry in GitWorkspace.splitNul(output) where !entry.isEmpty {
            if originalNext {
                originalNext = false
                paths.append(entry)
                continue
            }
            guard entry.count > 3 else { continue }
            paths.append(String(entry.dropFirst(3)))
            let code = entry.prefix(2)
            if code.contains("R") || code.contains("C") { originalNext = true }
        }
        return paths
    }

    /// 합치기가 프로젝트 폴더에서 바꿀 파일 중 거기에 커밋하지 않은 변경(새 파일 포함)이 있는 것 — git 이 합치기를 거절하는 파일.
    /// 바꿀 파일 = 이 대화의 브랜치가 가지를 친 뒤 바꾼 파일(`main...branch`, 이름 바꾸기는 지운 파일 + 새 파일로) + (커밋하고 합칠 때)
    /// 독립 작업 폴더의 커밋하지 않은 변경. 읽지 못한 쪽은 비워 둔다 (그때는 git 이 합치기에서 거절하고, 앱은 그것을 알린다).
    static func projectOverlap(_ worktree: ThreadWorktree, project: URL, main: String, includingUncommitted: Bool,
                               git: String, environment env: [String: String]) async -> [String] {
        guard let dirty = await porcelainStatus(git, in: project, env: env) else { return [] }
        let projectDirty = Set(porcelainPaths(dirty))
        guard !projectDirty.isEmpty else { return [] }
        var incoming = Set<String>()
        let range = main + "..." + worktree.branch
        if let changed = await value(git, ["diff", "--name-only", "--no-renames", "-z"] + GitInspector.readDiffArguments + [range],
                                     in: project, env: env, allowEmpty: true) {
            incoming.formUnion(GitWorkspace.splitNul(changed).filter { !$0.isEmpty })
        }
        if includingUncommitted,
           let pending = await porcelainStatus(git, in: URL(fileURLWithPath: worktree.path), env: env) {
            incoming.formUnion(porcelainPaths(pending))
        }
        return projectDirty.intersection(incoming).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: 합치기 · 따라잡기

    enum MergeResult: Sendable, Equatable {
        /// 프로젝트 폴더의 브랜치에 들어갔다.
        case merged(into: String)
        /// 독립 작업 폴더에서 프로젝트 폴더의 브랜치를 받다가 충돌 — 독립 작업 폴더가 병합 중으로 남았다 (거기서 풀고 커밋한 뒤 다시 합친다).
        case conflictInWorktree(files: [String])
        case failed(Failure)
    }

    /// 독립 작업 폴더의 일을 프로젝트 폴더의 지금 브랜치로 합친다.
    /// 0. 프로젝트 폴더가 병합 · rebase 중이거나(`projectBusy`) 합치면 바뀔 파일에 거기 커밋하지 않은 변경이 있으면
    ///    (`projectChangesOverlap`) **아무것도 하지 않고** 멈춘다. 독립 작업 폴더가 이 대화의 브랜치가 아닌 곳을 봐도
    ///    (`worktreeOffBranch` — 다른 브랜치 · 떼어진 HEAD) 그렇다.
    /// 1. `commitMessage` 가 있으면 독립 작업 폴더의 변경을 모두 커밋한다 (`add -A` → `commit -F -`).
    /// 2. 프로젝트 폴더의 브랜치가 앞서 있으면 독립 작업 폴더에서 먼저 받는다 (`merge --no-edit <브랜치>`) — 충돌이면 여기서 멈춘다.
    /// 3. 프로젝트 폴더에서 `merge --no-edit <이 브랜치>`. 2 를 거쳤으니 보통 빨리 감기다. 그래도 실패하고 **이 merge 가** 프로젝트 폴더를
    ///    병합 중으로 만들었으면 병합 전으로 되돌린다 (`merge --abort`). 그 전부터 병합 중이었으면 사람의 병합이라 건드리지 않는다.
    ///    성공했어도 프로젝트 폴더의 HEAD 가 그대로면 합친 것이 없다 (`nothingMerged`).
    static func merge(_ worktree: ThreadWorktree, project: URL, commitMessage: String?, git: String,
                      environment env: [String: String]) async -> (MergeResult, [Step]) {
        var steps: [Step] = []
        let folder = URL(fileURLWithPath: worktree.path)
        guard FileManager.default.fileExists(atPath: worktree.path) else {
            return (.failed(.missingFolder(worktree.path)), steps)
        }
        guard let main = await value(git, ["symbolic-ref", "--short", "-q", "HEAD"], in: project, env: env) else {
            return (.failed(.detachedMain), steps)
        }
        // 0. 프로젝트 폴더에서 사람이 병합 · rebase 를 하던 중이면 그 위에 합치지 않는다 — git 이 거절하고, 거절 뒤의 정리가 사람이 풀던
        //    충돌을 지운다 (chg-1). 커밋 · 따라잡기보다 먼저 본다 — 멈출 때 아무것도 바뀌지 않게.
        if let busy = await midOperation(in: project, git: git, environment: env) {
            return (.failed(.projectBusy(busy)), steps)
        }
        // 독립 작업 폴더가 이 대화의 브랜치가 아닌 곳(터미널에서 바꾼 브랜치 · 떼어진 HEAD)을 보면 멈춘다 — 1 단계의 커밋은 지금 HEAD 에
        // 생기고 3 단계는 이 대화의 브랜치만 합치므로, 그대로 가면 커밋은 그쪽에 남고 merge 는 "Already up to date" 로 성공했다.
        let folderBranch = await value(git, ["symbolic-ref", "--short", "-q", "HEAD"], in: folder, env: env)
        if folderBranch != worktree.branch {
            return (.failed(.worktreeOffBranch(current: folderBranch, expected: worktree.branch)), steps)
        }
        let message = commitMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let overlap = await projectOverlap(worktree, project: project, main: main, includingUncommitted: !message.isEmpty,
                                           git: git, environment: env)
        if !overlap.isEmpty { return (.failed(.projectChangesOverlap(overlap)), steps) }
        let writeEnv = GitWrite.writeEnvironment(env)
        if !message.isEmpty {
            let add = await run(git, ["add", "-A"], in: folder, env: writeEnv)
            steps.append(add)
            guard add.succeeded else { return (.failed(.git(command: add.command, output: add.output)), steps) }
            let commit = await run(git, ["commit", "-F", "-"], in: folder, env: writeEnv, stdin: [message])
            steps.append(commit)
            guard commit.succeeded else { return (.failed(.git(command: commit.command, output: commit.output)), steps) }
        }
        // 2. 독립 작업 폴더에서 프로젝트 폴더의 브랜치를 먼저 받는다 (뒤처졌을 때만).
        let behind = await value(git, ["rev-list", "--count", worktree.branch + ".." + main], in: project, env: env)
            .flatMap { Int($0) } ?? 0
        if behind > 0 {
            let (result, catchSteps) = await catchUp(worktree, from: main, git: git, environment: env)
            steps += catchSteps
            switch result {
            case .merged: break
            case .conflictInWorktree, .failed: return (result, steps)
            }
        }
        // 3. 직전에 프로젝트 폴더가 병합 중이었는지 다시 본다 (1 · 2 사이에 사람이 터미널에서 시작했을 수 있다).
        let mergingBefore = await value(git, ["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: project, env: env) != nil
        let headBefore = await value(git, ["rev-parse", "HEAD"], in: project, env: env)
        let merge = await run(git, ["merge", "--no-edit", worktree.branch], in: project, env: writeEnv)
        steps.append(merge)
        if !merge.succeeded {
            // 이 merge 가 프로젝트 폴더를 병합 중으로 만들었을 때만 되돌린다 (그 사이 프로젝트 폴더의 브랜치가 움직여 충돌했을 때).
            // 그 전부터 병합 중이었으면 사람의 병합이다 — git 이 이 merge 를 거절했을 뿐이고, 되돌리면 사람이 푼 충돌이 사라진다.
            if !mergingBefore,
               await value(git, ["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: project, env: env) != nil {
                steps.append(await run(git, ["merge", "--abort"], in: project, env: writeEnv))
            }
            return (.failed(.git(command: merge.command, output: merge.output)), steps)
        }
        // merge 가 성공해도 프로젝트 폴더의 HEAD 가 그대로면 합친 것이 없다 — "합쳤습니다" 라고 알리지 않는다.
        if let headBefore, let headAfter = await value(git, ["rev-parse", "HEAD"], in: project, env: env), headAfter == headBefore {
            return (.failed(.nothingMerged(into: main)), steps)
        }
        return (.merged(into: main), steps)
    }

    /// 합치기의 단계 중 독립 작업 폴더에 커밋을 남긴 것이 있는지 (실패 안내가 "커밋해 두었습니다" 를 붙인다 — 확인 창의
    /// "아무것도 바뀌지 않습니다" 가 틀린 말이 되지 않게).
    static func committedInWorktree(_ steps: [Step], worktree: ThreadWorktree) -> Bool {
        steps.contains { $0.succeeded && $0.directory == worktree.path && $0.command.hasPrefix("git commit") }
    }

    /// 프로젝트 폴더의 브랜치(`from`)의 새 커밋을 독립 작업 폴더로 받는다. 충돌하면 독립 작업 폴더를 병합 중으로 둔다 — 변경사항 탭 · 에이전트가 푼다.
    static func catchUp(_ worktree: ThreadWorktree, from branch: String, git: String,
                        environment env: [String: String]) async -> (MergeResult, [Step]) {
        let folder = URL(fileURLWithPath: worktree.path)
        let step = await run(git, ["merge", "--no-edit", branch], in: folder, env: GitWrite.writeEnvironment(env))
        guard !step.succeeded else { return (.merged(into: worktree.branch), [step]) }
        if await value(git, ["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: folder, env: env) != nil {
            let files = await readValue(git, ["diff", "--name-only", "--diff-filter=U", "-z"] + GitInspector.readDiffArguments,
                                        in: folder, env: env, allowEmpty: true).map(GitWorkspace.splitNul) ?? []
            return (.conflictInWorktree(files: files), [step])
        }
        return (.failed(.git(command: step.command, output: step.output)), [step])
    }

    // MARK: 정리

    /// 정리할 때 브랜치를 어떻게 할지.
    enum BranchDisposal: Sendable, Equatable {
        case keep
        /// 합쳐졌으면 지운다 (`branch -d`). 합치지 않은 커밋이 있으면 남긴다 — 실패로 치지 않는다.
        case deleteIfMerged
        /// 합치지 않았어도 지운다 (`branch -D`).
        case delete
    }

    /// 정리의 결과.
    struct Removal: Sendable, Equatable {
        /// 이 대화의 브랜치를 남겼는지.
        var branchKept: Bool
        /// 떼어진 HEAD 의 커밋을 지키려고 새로 만든 브랜치 (`ahc/<id>-saved`). 그런 커밋이 없었으면 nil.
        var savedBranch: String?
    }

    /// 작업 폴더를 지우고(`worktree remove`, 폴더가 이미 없으면 `worktree prune`) 브랜치를 `branch` 대로 한다.
    /// `force` 가 아니면 커밋하지 않은 변경이 있을 때 git 이 거절한다 (그 출력을 그대로 돌려준다).
    /// 작업 폴더의 HEAD 가 떼어져 있고 어느 브랜치에도 없는 커밋이 있으면, 지우기 전에 그 HEAD 에 브랜치를 만들어 남긴다 — git 은
    /// 작업 폴더의 HEAD 기록까지 지워 그 커밋을 `git fsck` 로만 보이게 만든다. 정리 · 대화 삭제 · 프로젝트 빼기가 모두 이 길이다.
    static func remove(_ worktree: ThreadWorktree, project: URL, force: Bool, branch disposal: BranchDisposal, git: String,
                       environment env: [String: String]) async -> (Result<Removal, Failure>, [Step]) {
        var steps: [Step] = []
        let writeEnv = GitWrite.writeEnvironment(env)
        let prefix = await value(git, ["rev-parse", "--show-prefix"], in: project, env: env) ?? ""
        let root = rootPath(of: worktree, prefix: prefix)
        var savedBranch: String?
        if FileManager.default.fileExists(atPath: root),
           let stranded = await strandedCommitCount(in: URL(fileURLWithPath: root), git: git, environment: env), stranded > 0 {
            var name = worktree.branch + "-saved"
            var n = 2
            while await value(git, ["show-ref", "--verify", "-q", "refs/heads/" + name], in: project, env: env,
                              allowEmpty: true) != nil, n <= 50 {
                name = worktree.branch + "-saved-\(n)"
                n += 1
            }
            let save = await run(git, ["branch", name, "HEAD"], in: URL(fileURLWithPath: root), env: writeEnv)
            steps.append(save)
            // 남기지 못하면 지우지 않는다 — 커밋을 잃는 정리를 하지 않는다.
            guard save.succeeded else { return (.failure(.git(command: save.command, output: save.output)), steps) }
            savedBranch = name
        }
        if FileManager.default.fileExists(atPath: root) {
            let remove = await run(git, ["worktree", "remove"] + (force ? ["--force"] : []) + [root], in: project,
                                   env: writeEnv)
            steps.append(remove)
            guard remove.succeeded else { return (.failure(.git(command: remove.command, output: remove.output)), steps) }
        } else {
            steps.append(await run(git, ["worktree", "prune"], in: project, env: writeEnv))
        }
        var branchKept = false
        if await value(git, ["show-ref", "--verify", "-q", "refs/heads/" + worktree.branch], in: project, env: env,
                       allowEmpty: true) != nil {
            switch disposal {
            case .keep:
                branchKept = true
            case .deleteIfMerged, .delete:
                let branch = await run(git, ["branch", disposal == .delete ? "-D" : "-d", worktree.branch], in: project,
                                       env: writeEnv)
                steps.append(branch)
                if !branch.succeeded {
                    guard disposal == .deleteIfMerged else {
                        return (.failure(.git(command: branch.command, output: branch.output)), steps)
                    }
                    branchKept = true
                }
            }
        }
        // 저장소별 폴더가 비었으면 지운다 (다른 대화의 작업 폴더가 있으면 그대로).
        let parent = URL(fileURLWithPath: root).deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: parent)
        }
        return (.success(Removal(branchKept: branchKept, savedBranch: savedBranch)), steps)
    }

    // MARK: 대화 기록 · 안내

    /// 앱이 독립 작업 폴더를 만들고 · 준비하고 · 정리하며 대화에 남긴 기록(명령 · 안내)의 payload 표시. 첫 메시지 전에는 이것만 있어도
    /// 시작 화면을 그대로 둔다 (chg-15 — 폴더를 골랐다고 시작 화면이 사라지지 않게).
    static let housekeepingKey = "ahc.worktree"

    static func isHousekeeping(_ event: ThreadEvent) -> Bool {
        guard let json = event.payloadJSON, json.contains(housekeepingKey) else { return false }
        return JSONUtil.object(json)?[housekeepingKey] as? Bool == true
    }

    /// "독립 작업 폴더로 옮기기" 확인 창의 설명 — 무엇이 따라오지 않는지 (chg-6).
    /// `uncommitted` = 프로젝트 폴더의 커밋하지 않은 변경 수 (모르면 nil), `touchedByThread` = 그중 이 대화의 에이전트가 고친 파일 수,
    /// `hasSetupCommand` = 프로젝트 설정에 준비 명령이 있다.
    static func moveNotice(uncommitted: Int?, touchedByThread: Int, hasSetupCommand: Bool) -> [String] {
        var lines = ["프로젝트 폴더의 지금 커밋에서 이 대화만의 폴더(git worktree)를 만들고, 앞으로 이 대화의 에이전트 · 변경사항 · 터미널은 그 폴더를 봅니다."]
        switch uncommitted {
        case let n? where n > 0:
            let touched = touchedByThread > 0 ? " (이 대화가 고친 \(touchedByThread)개 포함)" : ""
            lines.append("프로젝트 폴더의 커밋하지 않은 변경 \(n)개\(touched)는 따라오지 않고 프로젝트 폴더에 남습니다 — 먼저 커밋하면 함께 갑니다.")
        case nil:
            lines.append("프로젝트 폴더의 커밋하지 않은 변경은 따라오지 않고 프로젝트 폴더에 남습니다.")
        default:
            break
        }
        lines.append("git 이 무시하는 파일(.env · node_modules 등)도 따라오지 않습니다. "
                     + (hasSetupCommand ? "만든 뒤 프로젝트 설정의 준비 명령을 실행합니다."
                                        : "필요하면 프로젝트 설정의 준비 명령에 채울 명령을 적어 두세요."))
        return lines
    }

    // MARK: git 실행

    private static func run(_ git: String, _ arguments: [String], in directory: URL, env: [String: String],
                            stdin: [String] = []) async -> Step {
        let result = await CLIEnvironment.captureProcess(executable: git, arguments: GitInspector.commandArguments(arguments), environment: env,
                                                         workingDirectory: directory, stdinLines: stdin, timeout: 120)
        return Step(command: "git " + arguments.joined(separator: " "), output: result.combinedOutput,
                    succeeded: result.succeeded, directory: directory.path)
    }

    /// 작업 트리를 견주는 읽기(status · 색인 대 작업 트리 diff) — 저장소가 정한 filter · diff 드라이버를 끄고 색인을 쓰지 않는다
    /// (`GitInspector.readEnvironment`). 드라이버를 확인하지 못하면 nil (읽지 못한 것과 같다). 합치기 · 만들기처럼 사람이 고른 git 은
    /// `run` 으로 — 사람의 필터(git-lfs 등)가 그대로 돈다.
    private static func readValue(_ git: String, _ arguments: [String], in directory: URL, env: [String: String],
                                  allowEmpty: Bool = false) async -> String? {
        guard let readEnv = await GitInspector.readEnvironment(git: git, at: directory, environment: env) else { return nil }
        return await value(git, arguments, in: directory, env: readEnv, allowEmpty: allowEmpty)
    }

    /// `status --porcelain -z` (새 파일 포함, 하위 모듈은 가리키는 커밋만 — `GitInspector.submoduleReadArguments`).
    private static func porcelainStatus(_ git: String, in directory: URL, env: [String: String]) async -> String? {
        await readValue(git, ["status", "--porcelain", "-z", "--untracked-files=all"] + GitInspector.submoduleReadArguments,
                        in: directory, env: env, allowEmpty: true)
    }

    /// 성공하면 stdout 을 다듬어 돌려준다. 실패 · 빈 출력은 nil (`allowEmpty` 면 빈 출력도 성공으로 "").
    private static func value(_ git: String, _ arguments: [String], in directory: URL, env: [String: String],
                              allowEmpty: Bool = false) async -> String? {
        let result = await CLIEnvironment.captureProcess(executable: git, arguments: GitInspector.commandArguments(arguments),
                                                         environment: GitWorkspace.readOnlyEnvironment(env),
                                                         workingDirectory: directory, timeout: 30)
        guard result.succeeded else { return nil }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return allowEmpty ? "" : nil }
        return arguments.contains("-z") ? result.stdout : text
    }
}

/// 변경사항 탭 독립 작업 폴더 칸(`WorktreePanel`)의 사실 한 줄과 안내 (순수 — 시험한다).
enum WorktreeFacts {
    struct Part: Equatable {
        var text: String
        var emphasis = false
    }

    static func parts(_ status: Worktrees.Status?, mainBranch: String) -> [Part] {
        guard let status else { return [Part(text: "상태를 읽는 중…")] }
        var parts: [Part] = []
        if let ahead = status.ahead {
            parts.append(ahead > 0 ? Part(text: "합칠 커밋 \(ahead)", emphasis: true) : Part(text: "합칠 커밋 없음"))
        }
        if let uncommitted = status.uncommitted, uncommitted > 0 {
            parts.append(Part(text: "커밋 안 한 변경 \(uncommitted)", emphasis: true))
        }
        if let behind = status.behind, behind > 0 {
            parts.append(Part(text: "\(mainBranch) 에 새 커밋 \(behind)"))
        }
        if status.fullyMerged, (status.behind ?? 0) == 0 { parts.append(Part(text: "\(mainBranch) 기준 차이 없음")) }
        if !status.branchExists { parts.append(Part(text: "브랜치 없음", emphasis: true)) }
        return parts.isEmpty ? [Part(text: "\(mainBranch) 기준으로 비교하지 못했습니다")] : parts
    }

    /// 독립 작업 폴더가 이 대화의 브랜치가 아닌 곳을 보고 있으면 그 안내 (터미널 · 에이전트가 바꿨을 때 — chg-16). 다른 브랜치면 돌아오는
    /// 명령, 떼어진 HEAD 면 브랜치에 없는 커밋을 지키는 법과 정리가 그것을 남긴다는 사실. 같거나 모르면 nil. 그동안 합치기 · 맞추기는 막힌다.
    static func branchMismatch(_ status: Worktrees.Status?, worktreeBranch: String) -> String? {
        guard let status, status.offBranch(worktreeBranch) else { return nil }
        if let current = status.folderBranch {
            return "이 폴더가 지금 \(current) 브랜치에 있습니다 — 합치기는 이 대화의 브랜치 \(worktreeBranch) 의 커밋만 합치므로 "
                + "돌아오기 전에는 합치지 않습니다. 터미널에서 돌아오세요: git switch \(worktreeBranch)"
        }
        let stranded = status.strandedCommits ?? 0
        return "이 폴더가 브랜치가 아닌 커밋(detached HEAD)을 보고 있습니다 — 합치기는 이 대화의 브랜치 \(worktreeBranch) 의 커밋만 "
            + "합치므로 돌아오기 전에는 합치지 않습니다. "
            + (stranded > 0
               ? "어느 브랜치에도 없는 커밋 \(stranded)개는 터미널에서 git branch <새 이름> 으로 지키세요 (정리하면 앱이 새 브랜치로 남깁니다)."
               : "터미널에서 돌아오세요: git switch \(worktreeBranch)")
    }
}

/// Claude Code 는 세션 기록을 작업 폴더별 칸(`~/.claude/projects/<폴더 경로의 영숫자 아닌 글자를 - 로>/<세션>.jsonl`)에 두고,
/// `--resume` 은 **지금 폴더의 칸에서만** 찾는다. 대화가 작업 폴더를 옮기면(독립 작업 폴더를 만들거나 정리할 때) 기록 파일을 새 폴더의
/// 칸에 복사해 둔다 — 그래야 이어서 말할 수 있다 (못 하면 어댑터가 새 세션으로 복구하며 알린다).
enum ClaudeSessionFiles {
    static func projectsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("projects")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// 폴더 경로 → 칸 이름. 긴 이름(200자 초과)은 CLI 가 해시를 붙여 줄이므로 알 수 없다 (nil).
    static func folderKey(for path: String) -> String? {
        let key = String(realPath(path).map { c -> Character in
            c.isASCII && (c.isLetter || c.isNumber) ? c : "-"
        })
        return key.count <= 200 ? key : nil
    }

    /// 세션 기록을 `folder` 의 칸으로 복사한다. 원본은 대화가 막 떠난 폴더(`fromFolder`)의 칸이 먼저 — 그 폴더에서 이어 쓴 기록이
    /// 가장 새것이다. 대상 칸에 이미 있어도(옮기기 전의 옛 사본) 원본이 더 새것이면 바꾼다 — 그대로 두면 다음 `--resume` 이 옛 사본으로
    /// 성공해 그 폴더에서 한 대화가 조용히 빠졌다. 대상이 더 새것이면(옮긴 뒤 거기서 따로 이어 썼다) 그대로 둔다.
    /// 떠난 폴더의 칸에 없으면 아무 칸의 것을, 대상에 이미 있으면 그대로. 원본을 못 찾거나 복사하지 못하면 false.
    @discardableResult
    static func copy(sessionID: String, fromFolder: String? = nil, toFolder folder: String,
                     projects: URL = projectsDirectory()) -> Bool {
        guard !sessionID.isEmpty, let key = folderKey(for: folder) else { return false }
        let fm = FileManager.default
        let name = sessionID + ".jsonl"
        let destination = projects.appendingPathComponent(key).appendingPathComponent(name)
        let preferred = fromFolder.flatMap(folderKey(for:)).map { projects.appendingPathComponent($0).appendingPathComponent(name) }
        let source: URL
        if let preferred, preferred.path != destination.path, fm.fileExists(atPath: preferred.path) {
            source = preferred
        } else {
            if fm.fileExists(atPath: destination.path) { return true }
            guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil),
                  let found = dirs.lazy.map({ $0.appendingPathComponent(name) }).first(where: { fm.fileExists(atPath: $0.path) })
            else { return false }
            source = found
        }
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.fileExists(atPath: destination.path) else {
                try fm.copyItem(at: source, to: destination)
                return true
            }
            if let destinationDate = modificationDate(destination), let sourceDate = modificationDate(source),
               destinationDate > sourceDate {
                return true
            }
            // 같은 칸의 임시 파일에 복사한 뒤 바꿔 넣는다 — 도중에 실패해도 옛 사본이 남는다.
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(name).ahc-\(UUID().uuidString.prefix(8))")
            try fm.copyItem(at: source, to: temporary)
            do {
                _ = try fm.replaceItemAt(destination, withItemAt: temporary)
            } catch {
                try? fm.removeItem(at: temporary)
                throw error
            }
            return true
        } catch {
            return false
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// CLI 가 보는 작업 폴더 경로 (심볼릭 링크를 푼 것 — `/tmp` → `/private/tmp`). 폴더가 이미 없으면(정리한 독립 작업 폴더) 남아 있는
    /// 가장 가까운 위 폴더까지 풀고 나머지를 붙인다 — 지운 폴더의 칸 이름도 CLI 가 기록할 때와 같게.
    private static func realPath(_ path: String) -> String {
        if let resolved = Darwin.realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        guard parent != path, !parent.isEmpty, parent != "/" else { return path }
        return URL(fileURLWithPath: realPath(parent)).appendingPathComponent(url.lastPathComponent).path
    }
}
