import Foundation

// MARK: - 모델

/// 변경 파일 하나. 경로는 **저장소 루트 기준**이다.
struct GitFileChange: Hashable, Sendable, Identifiable {
    enum Area: String, Sendable { case staged, unstaged, untracked, conflicted }

    var id: String { "\(area.rawValue):\(path)" }
    var path: String
    /// 이름 변경 전 경로.
    var originalPath: String?
    /// `M` `A` `D` `R` `C` `T` `U` `??`
    var code: String
    var area: Area
    /// 새 파일(untracked)의 줄 수 (직접 센 값). 크거나 이진 파일이면 nil (0 으로 채우지 않는다).
    /// 추적 파일의 줄 수는 `GitWorkspaceStatus.headLineCounts` (마지막 커밋 대비 파일 전체) 에 있다.
    var added: Int?
    var removed: Int?

    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }
}

/// 줄 수. 이진 파일이거나 읽지 못하면 nil (0 으로 채우지 않는다).
struct GitLineCount: Hashable, Sendable {
    var added: Int?
    var removed: Int?
}

/// 커밋 한 개 요약 (`git log -1`).
struct GitCommitSummary: Hashable, Sendable {
    var hash: String
    var shortHash: String
    var subject: String
    /// 커밋 시각 (committer date). 읽지 못하면 nil.
    var date: Date?
}

struct GitBranchInfo: Hashable, Sendable, Identifiable {
    var id: String { name }
    var name: String
    var shortHash: String
    var isCurrent: Bool
    var upstream: String?
    var ahead: Int?
    var behind: Int?
    /// 추적 중인 원격 브랜치가 사라졌다.
    var upstreamGone = false
    /// 마지막 커밋의 상대 시각 (`%(committerdate:relative)`). git 이 준 글자 그대로라 git 에 따라 영어
    /// ("25 minutes ago")이거나 한국어("25분 전")다. 해석하지 않는 불투명한 값이다. 읽지 못하면 nil.
    var committerDate: String?
    /// 마지막 커밋 시각 (`%(committerdate:unix)`). 화면은 이것으로 앱의 상대 시각("25분 전")을 쓴다. 못 읽으면 nil.
    var committedAt: Date?
}

/// 원격 브랜치 하나 (`refs/remotes/<원격>/<이름>`). 원격 HEAD(`origin/HEAD`) 는 담지 않는다.
struct GitRemoteBranch: Hashable, Sendable, Identifiable {
    var id: String { fullName }
    /// `origin/feature/login`
    var fullName: String
    /// `origin`
    var remote: String
    /// 원격 안의 브랜치 이름 (`feature/login`).
    var name: String
    var shortHash: String?
    /// 마지막 커밋의 상대 시각 (git 이 준 글자 그대로). 읽지 못하면 nil.
    var committerDate: String?
    /// 마지막 커밋 시각 (`%(committerdate:unix)`). 못 읽으면 nil.
    var committedAt: Date?
}

/// 커밋 목록의 한 줄 (`git log --format=%h%x00%s%x00%an%x00%ar%x00%ct`).
struct GitLogEntry: Hashable, Sendable, Identifiable {
    var id: String { shortHash }
    var shortHash: String
    var subject: String
    var author: String
    /// git 이 준 상대 시각 그대로 ("25 minutes ago" · "25분 전"). 해석하지 않는 불투명한 글자다.
    /// 앱이 쓰는 git(`GitInspector.findGit`, 보통 /usr/bin/git)은 로케일과 관계없이 영어로 쓴다 (2026-09-13 실측).
    var relativeDate: String
    /// 커밋 시각 (`%ct`). 화면은 이것으로 앱의 상대 시각("25분 전")을 쓰고, 없으면 `relativeDate` 를 그대로 쓴다.
    var committedAt: Date? = nil

    /// 작성자 머리글자 (이름 첫 글자, 로마자는 대문자). 이름이 비어 있으면 빈 문자열.
    var authorInitial: String {
        guard let first = author.trimmingCharacters(in: .whitespaces).first else { return "" }
        return String(first).uppercased()
    }
}

/// 인스펙터·사이드바·상태 막대가 함께 쓰는 작업 폴더 상태. **읽기 전용**으로만 만든다.
struct GitWorkspaceStatus: Hashable, Sendable {
    var isRepository = false
    /// `git rev-parse --show-toplevel`.
    var rootPath: String?
    /// 프로젝트 폴더가 저장소 루트의 하위 폴더일 때 그 상대 경로 (루트면 빈 문자열).
    var projectPrefix = ""
    /// nil 이면 브랜치가 아닌 커밋을 가리키는 상태(detached).
    var branch: String?
    var detachedHash: String?
    var upstream: String?
    var ahead: Int?
    var behind: Int?
    var upstreamGone = false
    var staged: [GitFileChange] = []
    var unstaged: [GitFileChange] = []
    var untracked: [GitFileChange] = []
    var conflicted: [GitFileChange] = []
    /// 로컬 브랜치 (마지막 커밋이 최근인 순).
    var localBranches: [GitBranchInfo] = []
    /// 원격 브랜치 (마지막 커밋이 최근인 순, 원격 HEAD 제외).
    var remoteBranches: [GitRemoteBranch] = []
    /// `remoteBranches` 를 읽었는지. 못 읽었으면 "원격에 그 브랜치가 없다" 고 말하지 않는다.
    var remoteBranchesRead = false
    /// `git log HEAD..@{u}` — 원격에서 온 커밋 (최근 것부터, 최대 `GitWorkspace.commitListLimit` 개).
    /// 뒤처져 있을 때만 읽는다. 읽지 않았거나 실패하면 nil (전체 개수는 `behind`).
    var incomingCommits: [GitLogEntry]?
    /// `git log @{u}..HEAD` — 이 브랜치에만 있는 커밋. 앞서 있을 때만 읽는다 (전체 개수는 `ahead`).
    var outgoingCommits: [GitLogEntry]?
    /// 병합 진행 중이면 MERGE_HEAD 가 가리키는 커밋 (`git rev-parse -q --verify MERGE_HEAD`). 아니면 nil.
    var mergeHead: String?
    /// MERGE_MSG 에서 주석 줄을 뺀 커밋 메시지 초안 (`GitWorkspace.mergeMessageDraft`). 병합 중이 아니거나
    /// 읽지 못했거나 비어 있으면 nil.
    var mergeMessage: String?
    /// rebase 진행 중 (`rebase-merge` 폴더, 또는 `git am` 이 아닌 `rebase-apply` 폴더가 있다). HEAD 가 브랜치가
    /// 아닐 때만 살펴본다 (rebase 는 진행 중 HEAD 를 떼어 둔다). 이때 커밋 · 브랜치 만들기는 터미널의 몫이다.
    var isRebasing = false
    /// `git remote` — 설정된 원격 이름. nil 이면 읽지 못했다 ("원격 없음" 과 구분한다).
    var remotes: [String]?
    /// 다른 worktree 가 쓰는 로컬 브랜치 (브랜치 → 그 worktree 의 경로, `git worktree list --porcelain`). 이 폴더의 것은 뺀다.
    /// git 은 다른 worktree 가 쓰는 브랜치로 전환하지 않는다 — 브랜치 메뉴가 그 행을 잠근다 (chg-16). 못 읽으면 비어 있다.
    var worktreeBranches: [String: String] = [:]
    /// 첫 커밋 전이라 HEAD 가 없다 (`## No commits yet on main`).
    var noCommitsYet = false
    /// `git diff HEAD --numstat` — 경로별로 **마지막 커밋 대비 파일 전체**의 줄 수 (저장소 루트 기준 경로).
    /// 새 파일(untracked)은 여기 없다 (`GitFileChange.added`).
    var headLineCounts: [String: GitLineCount] = [:]
    /// HEAD 커밋. 첫 커밋 전이거나 읽지 못하면 nil.
    var lastCommit: GitCommitSummary?
    /// `FETCH_HEAD` 파일의 수정 시각 = 이 저장소에서 마지막으로 fetch 한 시각 (터미널에서 한 것 포함).
    /// 비어 있는 FETCH_HEAD 는 쓰지 않는다 — 원격에 닿지 못한 fetch 도 파일을 비우며 시각을 바꾼다.
    var fetchHeadModifiedAt: Date?
    var error: String?
    /// status 를 읽은 시각 (원격을 확인한 시각이 아니다 — 그것은 `fetchHeadModifiedAt`).
    var fetchedAt: Date?

    var changeCount: Int {
        Set((staged + unstaged + untracked + conflicted).map(\.path)).count
    }

    /// 병합 진행 중 (MERGE_HEAD 가 있다). 충돌이 모두 풀려도 커밋하기 전까지는 병합 중이다.
    var isMerging: Bool { mergeHead != nil }

    /// 파일 트리에 붙일 대표 상태 (저장소 루트 기준 경로 → 코드).
    /// 스테이지 여부와 관계없이 한 글자로 요약한다. 충돌 > 작업 트리 > 인덱스 순으로 우선한다.
    var codeByPath: [String: String] {
        var out: [String: String] = [:]
        for change in staged { out[change.path] = change.code }
        for change in unstaged { out[change.path] = change.code }
        for change in untracked { out[change.path] = change.code }
        for change in conflicted { out[change.path] = change.code }
        return out
    }

    /// 표시용 이름 (`main`, `HEAD a41c9e2`).
    var headLabel: String? {
        if let branch { return branch }
        if let detachedHash { return "HEAD \(detachedHash)" }
        return nil
    }
}

// MARK: - 읽기

/// Git 상태 조회. 모든 명령은 읽기 전용이며 `--no-optional-locks` 로 인덱스 잠금을 잡지 않는다
/// (에이전트가 같은 저장소에서 git 을 쓰는 중이어도 방해하지 않는다).
/// status · 파일 diff 는 저장소가 정한 filter · diff 드라이버를 끈 환경(`GitInspector.readEnvironment`)으로 읽는다.
enum GitWorkspace {

    static func status(at directory: URL, environment: [String: String]) async -> GitWorkspaceStatus {
        var result = GitWorkspaceStatus()
        result.fetchedAt = Date()
        guard let git = GitInspector.findGit(environment: environment) else {
            result.error = gitMissingMessage
            return result
        }
        let readOnly = readOnlyEnvironment(environment)

        // "저장소가 아님" 은 git 이 그렇게 말했을 때만이다. 시간 초과 · 소유자 검사(safe.directory) · 설정 오류처럼
        // 다른 이유로 실패하면 저장소가 아니라고 단정하지 않고 오류로 남긴다 (화면은 "Git 상태를 읽지 못했습니다").
        // 메시지를 가려내려고 이 조회만 영어로 받는다 (git 은 macOS 언어 설정을 따라 한국어로 말한다).
        let top: String
        switch await run(git, ["rev-parse", "--show-toplevel"], env: englishMessages(readOnly), in: directory) {
        case .success(let out) where !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            top = out
        case .success:
            result.error = "git rev-parse 가 저장소 경로를 돌려주지 않았습니다. 다시 읽어 주세요."
            return result
        case .failure(let message):
            if !isNotRepositoryMessage(message) {
                result.error = "Git 저장소인지 확인하지 못했습니다: "
                    + message.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return result
        }
        result.isRepository = true
        let root = top.trimmingCharacters(in: .whitespacesAndNewlines)
        result.rootPath = root
        result.projectPrefix = relativePrefix(project: directory.standardizedFileURL.path,
                                              root: URL(fileURLWithPath: root).standardizedFileURL.path)
        // 저장소가 정한 filter · diff 드라이버를 끈 환경 — 이 조회의 git 은 모두 이것으로 (status 도 clean 필터를 부른다).
        // 드라이버를 확인하지 못하면 읽지 않는다 (실행 전후 비교는 "읽지 못함" 으로 둔다).
        guard let env = await GitInspector.readEnvironment(git: git, at: directory, environment: readOnly) else {
            result.error = GitInspector.driverCheckFailedMessage
            return result
        }

        switch await run(git, ["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all"]
                            + GitInspector.submoduleReadArguments,
                         env: env, in: directory, timeout: 30) {
        case .success(let output) where !output.contains("## "):
            // `--branch` 는 항상 `## …` 머리줄을 쓴다. 없으면 출력을 못 받은 것이라 "변경 없음" 으로 읽지 않는다.
            result.error = "git status 출력을 읽지 못했습니다. 다시 읽어 주세요."
        case .success(let output):
            parseStatus(output, into: &result)
        case .failure(let message):
            result.error = "git status 실패: \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
        }

        if result.branch == nil,
           case .success(let hash) = await run(git, ["rev-parse", "--short", "HEAD"], env: env, in: directory) {
            let h = hash.trimmingCharacters(in: .whitespacesAndNewlines)
            result.detachedHash = h.isEmpty ? nil : h
        }

        // 짧은 명령들이라 차례로 돌린다. 한꺼번에 띄우면 앱 시작 직후처럼 바쁠 때 출력 수집이 늦어
        // 실패로 떨어지는 경우가 있었다 (실측). 줄 수를 못 읽으면 0 이 아니라 "—" 로 둔다.
        // 줄 수는 `git diff HEAD` 한 번으로 읽는다 (아래). 인덱스 기준 staged · unstaged 줄 수는 화면이 쓰지 않아
        // 체크할 때마다 전체 diff 를 두 번 더 돌리지 않는다.
        // 원격 이름은 원격 브랜치 이름을 원격 · 브랜치로 나눌 때 쓰므로 먼저 읽는다.
        if case .success(let out) = await run(git, ["remote"], env: env, in: directory) {
            result.remotes = parseRemotes(out)
        }
        // 브랜치는 마지막 커밋이 최근인 순. 상대 시각은 git 이 준 글자 그대로 두고, 화면용으로 시각(unix)도 받는다.
        if case .success(let out) = await run(git, ["for-each-ref", "--sort=-committerdate",
                                                    "--format=%(refname:short)%00%(objectname:short)%00%(HEAD)%00%(upstream:short)%00%(upstream:track)%00%(committerdate:relative)%00%(committerdate:unix)",
                                                    "refs/heads"], env: env, in: directory) {
            result.localBranches = parseBranches(out)
        }
        // 다른 worktree 가 쓰는 브랜치 (독립 작업 폴더 대화의 `ahc/…` 등) — 그 브랜치로는 전환할 수 없다.
        if result.localBranches.count > 1,
           case .success(let out) = await run(git, ["worktree", "list", "--porcelain"], env: env, in: directory) {
            result.worktreeBranches = parseWorktreeBranches(out, excluding: root)
        }
        if case .success(let out) = await run(git, ["for-each-ref", "--sort=-committerdate",
                                                    "--format=%(refname)%00%(objectname:short)%00%(committerdate:relative)%00%(committerdate:unix)",
                                                    "refs/remotes"], env: env, in: directory) {
            result.remoteBranches = parseRemoteBranches(out, remotes: result.remotes)
            result.remoteBranchesRead = true
        }
        // 커밋 목록: 추적 브랜치가 있고 앞섬 · 뒤처짐이 있을 때만 읽는다 (upstream 이 없거나 사라졌으면 읽지 않는다).
        if result.upstream != nil, !result.upstreamGone, !result.noCommitsYet {
            if let behind = result.behind, behind > 0,
               case .success(let out) = await run(git, logArguments(range: "HEAD..@{u}"), env: env, in: directory) {
                result.incomingCommits = parseLog(out)
            }
            if let ahead = result.ahead, ahead > 0,
               case .success(let out) = await run(git, logArguments(range: "@{u}..HEAD"), env: env, in: directory) {
                result.outgoingCommits = parseLog(out)
            }
        }
        // 병합 진행 중인지 (MERGE_HEAD). 있으면 MERGE_MSG 를 커밋 초안으로 쓸 수 있게 읽어 둔다.
        if case .success(let out) = await run(git, ["rev-parse", "-q", "--verify", "MERGE_HEAD"],
                                              env: env, in: directory) {
            let hash = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hash.isEmpty {
                result.mergeHead = hash
                result.mergeMessage = await readMergeMessage(git, env: env, in: directory)
            }
        }
        // rebase 진행 중인지. rebase 는 HEAD 를 떼어 두므로 브랜치가 아닐 때만 묻는다 (평소에는 명령을 더 돌리지 않는다).
        if result.branch == nil, !result.noCommitsYet,
           case .success(let out) = await run(git, ["rev-parse", "--path-format=absolute",
                                                    "--git-path", "rebase-merge", "--git-path", "rebase-apply"],
                                              env: env, in: directory) {
            result.isRebasing = rebaseInProgress(out, relativeTo: directory)
        }
        // 변경사항 탭의 줄 수는 마지막 커밋 대비 파일 전체다. 첫 커밋 전에는 HEAD 가 없어 비워 둔다 ("—").
        if !result.noCommitsYet,
           !(result.staged.isEmpty && result.unstaged.isEmpty && result.conflicted.isEmpty),
           case .success(let out) = await runRetrying(git, ["diff", "HEAD", "--numstat", "-z"] + GitInspector.readDiffArguments,
                                                      env: env, in: directory) {
            result.headLineCounts = parseNumstat(out).mapValues { GitLineCount(added: $0.0, removed: $0.1) }
        }
        if !result.noCommitsYet,
           case .success(let out) = await run(git, ["log", "-1", "--no-show-signature",
                                                    "--format=%H%x00%h%x00%s%x00%ct"],
                                              env: env, in: directory) {
            result.lastCommit = parseLastCommit(out)
        }
        // FETCH_HEAD 는 작업 트리(worktree)마다 따로 있다. 이 작업 트리의 것과 공통 폴더의 것 중 늦은 쪽.
        // 절대 경로로 받는다 (심볼릭 링크로 연 하위 폴더에서 `..` 를 글자로 합치면 다른 파일을 가리킨다).
        if case .success(let out) = await run(git, ["rev-parse", "--path-format=absolute",
                                                    "--git-path", "FETCH_HEAD", "--git-common-dir"],
                                              env: env, in: directory) {
            result.fetchHeadModifiedAt = fetchHeadCandidates(out, relativeTo: directory)
                .compactMap(nonEmptyModificationDate)
                .max()
        }
        countUntrackedLines(&result.untracked, root: URL(fileURLWithPath: root))
        return result
    }

    /// git 실행 파일을 찾지 못했을 때의 상태 오류 (Command Line Tools 가 없는 Mac). 화면은 이것으로 설치 안내를 고른다.
    static let gitMissingMessage = "git 실행 파일을 찾지 못했습니다."

    static func isGitMissing(_ error: String) -> Bool { error == gitMissingMessage }

    /// 사용자의 `push.default` 설정 (없으면 nil = git 기본값 simple). 업로드 확인 창이 열릴 때 한 번 읽는다.
    static func pushDefault(at directory: URL, environment: [String: String]) async -> String? {
        guard let git = GitInspector.findGit(environment: environment),
              case .success(let out) = await run(git, ["config", "--get", "push.default"],
                                                 env: readOnlyEnvironment(environment), in: directory)
        else { return nil }
        let value = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// 맨 `git push` 가 확인 창에 적은 "<브랜치> → <upstream>" 한 곳으로만 가는 설정인지.
    /// `current` 는 같은 이름 브랜치로, `matching` 은 이름이 같은 모든 브랜치를 올린다.
    static func pushGoesToUpstreamOnly(_ pushDefault: String?) -> Bool {
        guard let value = pushDefault?.lowercased() else { return true }
        return ["simple", "upstream", "tracking"].contains(value)
    }

    /// HEAD 커밋 한 개 (커밋 직후 앱이 만든 커밋을 확인할 때). 첫 커밋 전이거나 실패하면 nil.
    static func headCommit(at directory: URL, environment: [String: String]) async -> GitCommitSummary? {
        guard let git = GitInspector.findGit(environment: environment),
              case .success(let out) = await run(git, ["log", "-1", "--no-show-signature",
                                                       "--format=%H%x00%h%x00%s%x00%ct"],
                                                 env: readOnlyEnvironment(environment), in: directory)
        else { return nil }
        return parseLastCommit(out)
    }

    // MARK: 파일 diff (변경사항 탭 · 크게 보기)

    /// 파일 diff 조회의 공통 인수. 사용자 설정이 출력 모양을 흔들지 않게 한다 — 색 · 외부 diff 도구 · 변환 필터 · 하위 모듈 안의 diff 를
    /// 끄고 (`diff.external` · textconv 가 사용자 명령을 부르지 않게 — `GitInspector.readDiffArguments`), 접두어를 a/ · b/ 로 고정하고
    /// (`diff.noprefix` · `diff.mnemonicPrefix`), 문맥 3줄 · 전체 blob 이름(펼치기에서 옛 파일을 정확히 읽는다) · 이름 변경 찾기를 켠다.
    static let fileDiffArguments: [String] = GitInspector.readDiffArguments
        + ["--full-index", "-M", "--src-prefix=a/", "--dst-prefix=b/", "-U3"]

    /// 파일 하나의 diff 를 읽고 화면에 넘길 문서를 만든다 (**읽기 전용**, 파싱 · 강조 · 포함 상태 · 옛 파일 줄까지 이 작업 안에서).
    /// - 추적 파일(수정 · 삭제 · 이름 변경 · 스테이지된 새 파일): `git diff HEAD -- <경로> [<원래 경로>]` (작업 트리 vs 마지막 커밋).
    /// - 추적 안 된 새 파일: `git diff --no-index -- /dev/null <경로>` (차이가 있으면 종료 코드 1 — 출력이 있으면 성공으로 받는다).
    /// - 첫 커밋 전: HEAD 가 없어 마지막 커밋과 비교할 수 없다 — 지금 파일 전체를 새 내용으로 (`--no-index`) 보이고 그렇게 밝힌다.
    /// - hunk 포함 상태: 목록이 일부 포함(mixed)일 때만 `git diff --cached` 와 대조한다 (on 이면 전부 on, off 면 전부 off).
    /// - 펼치기: diff 의 `index` 줄에 적힌 옛 blob 을 `git cat-file blob` 으로 읽는다 (그 diff 와 같은 내용 — `git show HEAD:<경로>`
    ///   를 따로 읽으면 그 사이 HEAD 가 바뀌었을 때 어긋난다). 새 쪽은 diff 가 같다고 말한 구간이라 옛 쪽 줄을 그대로 쓴다.
    static func fileDiff(_ request: FileDiffRequest, root: URL, environment: [String: String]) async -> FileDiffDocument {
        var doc = FileDiffDocument(request: request)
        guard let git = GitInspector.findGit(environment: environment) else {
            doc.body = .failed("git 실행 파일을 찾지 못했습니다.")
            return doc
        }
        let fm = FileManager.default
        let fileURL = root.appendingPathComponent(request.path)
        // 링크를 따라가지 않고 그 항목 자체의 종류를 본다 (폴더를 가리키는 링크 · 끊긴 링크도 git 은 링크 대상 글자로 비교한다).
        let attributes = try? fm.attributesOfItem(atPath: fileURL.path)
        let exists = attributes != nil
        if (attributes?[.type] as? FileAttributeType) == .typeDirectory {
            doc.body = .skipped("폴더라 내용 비교를 보여줄 수 없습니다 (다른 Git 저장소일 수 있습니다).")
            return doc
        }
        if let size = attributes?[.size] as? Int, size > FileDiffLimits.fileBytes {
            doc.body = .skipped("파일이 커서(\(FileDiffLimits.byteText(size))) 내용 비교를 보여주지 않습니다. 터미널의 git diff 로 보세요.")
            return doc
        }
        if let lines = request.changedLines, lines > FileDiffLimits.skipLines {
            doc.body = .skipped("바뀐 줄이 \(lines.formatted())줄이라 내용 비교를 보여주지 않습니다. 터미널의 git diff 로 보세요.")
            return doc
        }

        let noIndex = request.untracked || request.noCommitsYet
        let arguments: [String]
        if noIndex {
            guard exists else {
                doc.body = .noLines(request.noCommitsYet
                                    ? "첫 커밋 전이고 지금 파일이 없어 보여줄 내용이 없습니다."
                                    : "파일이 없습니다 — 그 사이 지워졌을 수 있습니다. 목록을 다시 읽어 보세요.")
                return doc
            }
            // `--no-index` 는 링크를 따라가 대상 파일(폴더면 실패)을 비교한다 — git 이 기록할 내용(가리키는 경로)과 다르다.
            // 그래서 비교하지 않고 사실만 적는다.
            if (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink {
                let target = (try? fm.destinationOfSymbolicLink(atPath: fileURL.path)).map { "→ \($0)" } ?? "대상을 읽지 못함"
                doc.body = .skipped("심볼릭 링크입니다 (\(target)) — git 은 링크가 가리키는 경로를 내용으로 기록합니다.")
                return doc
            }
            arguments = ["diff", "--no-index"] + fileDiffArguments + ["--", "/dev/null", request.path]
            if request.noCommitsYet && !request.untracked {
                doc.notes.append("첫 커밋 전이라 비교할 마지막 커밋이 없습니다 — 지금 파일 전체를 새 내용으로 보여줍니다.")
            }
        } else {
            arguments = ["diff", "HEAD"] + fileDiffArguments
                + ["--", request.path] + (request.originalPath.map { [$0] } ?? [])
        }
        doc.command = "git " + arguments.joined(separator: " ")
        // 저장소가 정한 filter · diff 드라이버를 끈 환경 (`GitInspector.readEnvironment` — diff 는 작업 트리 파일에 clean 필터를 부른다).
        guard let env = await GitInspector.readEnvironment(git: git, at: root, environment: readOnlyEnvironment(environment)) else {
            doc.body = .failed(GitInspector.driverCheckFailedMessage)
            return doc
        }
        // 경로는 pathspec 이 아니라 글자 그대로 (`:memo.txt` · `a[1].txt` 를 다른 파일로 읽지 않게 — 쓰기 명령과 같은 규칙).
        var pathEnv = env
        pathEnv["GIT_LITERAL_PATHSPECS"] = "1"
        let output: String
        switch await run(git, arguments, env: noIndex ? env : pathEnv, in: root, timeout: 30) {
        case .success(let out):
            output = out
        case .failure(let message):
            doc.body = .failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
            return doc
        }
        let parse = UnifiedDiff.parse(output, lineLimit: FileDiffLimits.displayLines)
        let (picked, notes) = FileDiffBuild.pick(parse, path: request.path, originalPath: request.originalPath)
        doc.notes += notes
        doc.file = picked
        doc.totalLines = parse.totalBodyLines
        doc.shownLines = parse.shownBodyLines
        guard let file = picked, !file.hunks.isEmpty, !file.isBinary else {
            doc.body = FileDiffBuild.noLinesReason(picked)
            return doc
        }
        doc.body = .diff
        if request.conflicted { doc.conflictMarkerLines = FileDiffBuild.conflictMarkerLines(file) }

        // hunk 포함 상태 — 충돌 파일은 체크할 수 없어 적지 않는다.
        switch request.inclusion {
        case .conflict:
            break
        case .on:
            doc.inclusion = DiffInclusion.Result(states: file.hunks.map { _ in .on }, stagedOnly: 0)
        case .off:
            doc.inclusion = DiffInclusion.Result(states: file.hunks.map { _ in .off }, stagedOnly: 0)
        case .mixed where parse.truncated:
            // 잘린 diff 는 hunk 수 · 뒤쪽 스테이지를 모른다 — "변경 n곳 중 m곳" 이나 "지금 파일에 없는 스테이지 변경" 을
            // 사실처럼 적지 않는다 (보이지 않은 hunk 의 스테이지된 줄이 그렇게 셈해진다).
            doc.inclusionNote = "diff 가 길어 잘렸으므로 부분마다의 포함 상태를 적지 않았습니다 — 파일은 일부만 포함된 상태입니다."
        case .mixed:
            let cachedArguments = ["diff", "--cached"] + fileDiffArguments
                + ["--", request.path] + (request.originalPath.map { [$0] } ?? [])
            if case .success(let out) = await run(git, cachedArguments, env: pathEnv, in: root, timeout: 30) {
                let cached = FileDiffBuild.pick(UnifiedDiff.parse(out), path: request.path,
                                                originalPath: request.originalPath).0
                doc.inclusion = DiffInclusion.states(head: file.hunks, cached: cached?.hunks ?? [])
                doc.stagedFileChanges = FileDiffBuild.stagedFileChanges(cached)
            } else {
                doc.inclusionNote = "커밋에 포함한 내용(git diff --cached)을 읽지 못해 부분마다의 포함 상태를 적지 않았습니다."
            }
        }

        // 펼치기용 옛 파일 줄 (새 파일 · 지운 파일은 hunk 가 파일 전체라 필요 없다).
        if !file.isNewFile, !file.isDeleted, let blob = file.oldBlob,
           blob.contains(where: { $0 != "0" }),
           case .success(let sizeText) = await run(git, ["cat-file", "-s", blob], env: env, in: root),
           let size = Int(sizeText.trimmingCharacters(in: .whitespacesAndNewlines)),
           size <= FileDiffLimits.oldBlobBytes,
           case .success(let text) = await run(git, ["cat-file", "blob", blob], env: env, in: root, timeout: 30) {
            doc.oldLines = DiffGaps.splitLines(text)
        }
        doc.gaps = DiffGaps.compute(file.hunks, oldLineCount: doc.oldLines?.count,
                                    endKnown: DiffGaps.endKnown(file))
        return doc
    }

    /// 원격 주소 (`git remote get-url [--push] <이름>`). 로그인 실패 문구에서 GitHub 인지 가릴 때만 쓴다.
    /// 올리는 명령은 `--push` 로 (`remote.<이름>.pushurl` 이 있으면 git 은 그 주소로 올린다). 못 읽으면 nil.
    static func remoteURL(named name: String, push: Bool = false, at directory: URL,
                          environment: [String: String]) async -> String? {
        guard let git = GitInspector.findGit(environment: environment),
              case .success(let out) = await run(git, ["remote", "get-url"] + (push ? ["--push"] : []) + ["--", name],
                                                 env: readOnlyEnvironment(environment), in: directory)
        else { return nil }
        let url = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    /// 맨 `git push` 가 올리는 원격을 바꾸는 설정: `branch.<브랜치>.pushRemote`, 없으면 `remote.pushDefault`.
    /// 둘 다 없으면 nil (그때는 추적 브랜치의 원격으로 올린다). 업로드가 실패했을 때만 읽는다.
    static func pushRemote(branch: String, at directory: URL, environment: [String: String]) async -> String? {
        guard let git = GitInspector.findGit(environment: environment) else { return nil }
        let env = readOnlyEnvironment(environment)
        for key in ["branch.\(branch).pushRemote", "remote.pushDefault"] {
            if case .success(let out) = await run(git, ["config", "--get", key], env: env, in: directory) {
                let value = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// `rev-parse --path-format=absolute --git-path rebase-merge --git-path rebase-apply` 출력 → rebase 진행 중인지.
    /// `rebase-apply` 는 `git am` 도 쓰는데, 그때는 안에 `applying` 파일이 있다 (git 의 wt-status 와 같은 판단).
    static func rebaseInProgress(_ output: String, relativeTo directory: URL) -> Bool {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("--") }
        guard lines.count >= 2 else { return false }
        let fm = FileManager.default
        func isDirectory(_ path: String) -> Bool {
            var dir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
        }
        let merge = resolveGitPath(lines[0], relativeTo: directory)
        let apply = resolveGitPath(lines[1], relativeTo: directory)
        if isDirectory(merge) { return true }
        return isDirectory(apply) && !fm.fileExists(atPath: (apply as NSString).appendingPathComponent("applying"))
    }

    /// 커밋 목록은 최대 이만큼만 읽는다. 더 있으면 화면이 "외 n개" 로 잘렸음을 밝힌다 (전체 수는 앞섬 · 뒤처짐).
    static let commitListLimit = 50

    /// 커밋 목록 조회 인수. 사용자 설정(`log.showSignature` · 색)이 출력 형식을 흔들지 않게 끈다.
    /// `%ar` 뒤에 커밋 시각(`%ct`)을 덧붙인다 — 앱의 git 은 `%ar` 을 영어로 쓰므로 화면의 상대 시각은 이것으로 만든다.
    static func logArguments(range: String) -> [String] {
        ["log", "--no-show-signature", "--no-color", "--format=%h%x00%s%x00%an%x00%ar%x00%ct",
         "-n", "\(commitListLimit)", range, "--"]
    }

    /// unix 초 글자 → 시각. 비었거나 숫자가 아니면 nil.
    static func unixDate(_ text: String) -> Date? {
        TimeInterval(text.trimmingCharacters(in: .whitespaces)).map { Date(timeIntervalSince1970: $0) }
    }

    /// 파일 이름 검색용 목록. Git 이면 `.gitignore` 를 따르고, 아니면 폴더를 직접 훑는다.
    /// 반환 경로는 **프로젝트 폴더 기준**이다.
    static func listFiles(at directory: URL, environment: [String: String],
                          limit: Int = 20_000) async -> [String] {
        if let git = GitInspector.findGit(environment: environment),
           case .success(let out) = await run(git, ["ls-files", "--cached", "--others",
                                                    "--exclude-standard", "-z", "--", "."],
                                              env: readOnlyEnvironment(environment),
                                              in: directory, timeout: 30) {
            // ls-files 는 현재 폴더 기준 경로를 준다.
            var seen = Set<String>()
            var files: [String] = []
            for item in splitNul(out) where seen.insert(item).inserted {
                files.append(item)
                if files.count >= limit { break }
            }
            if !files.isEmpty { return files }
        }
        return FileTree.enumerateFiles(at: directory, limit: limit)
    }

    struct ContentMatch: Hashable, Identifiable, Sendable {
        var id: String { "\(path):\(line)" }
        var path: String
        var line: Int
        var text: String
    }

    /// 내용 검색. Git 저장소에서만 지원한다 (`git grep`, 추적 파일 + 무시되지 않은 새 파일).
    static func grep(_ query: String, at directory: URL, environment: [String: String],
                     maxResults: Int = 200) async -> Result<[ContentMatch], GrepError> {
        guard let git = GitInspector.findGit(environment: environment) else { return .failure(.noGit) }
        let output = await run(git, ["grep", "--untracked", "-n", "-I", "-i", "-F",
                                     "--max-count=5", "-e", query, "--", "."],
                               env: readOnlyEnvironment(environment), in: directory, timeout: 20)
        switch output {
        case .success(let text):
            var matches: [ContentMatch] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                // path:line:text — 경로에 ':' 가 있을 수 있어 앞에서부터 숫자 칸을 찾는다.
                let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, let number = Int(parts[1]) else { continue }
                matches.append(ContentMatch(path: String(parts[0]), line: number,
                                            text: String(parts[2]).trimmingCharacters(in: .whitespaces)))
                if matches.count >= maxResults { break }
            }
            return .success(matches)
        case .failure(let message):
            // 일치 항목이 없으면 git grep 은 종료 코드 1 과 빈 출력을 낸다.
            if message.hasPrefix("종료 코드 1") { return .success([]) }
            if message.contains("not a git repository") { return .failure(.notRepository) }
            return .failure(.other(message.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    enum GrepError: Error, Equatable {
        case noGit, notRepository, other(String)

        var message: String {
            switch self {
            case .noGit: return "git 실행 파일을 찾지 못했습니다."
            case .notRepository: return "Git 저장소가 아니면 내용 검색을 지원하지 않습니다."
            case .other(let m): return m
            }
        }
    }

    // MARK: 해석 (검증 가능하도록 분리)

    /// `git status --porcelain=v1 -z --branch` 해석.
    static func parseStatus(_ output: String, into result: inout GitWorkspaceStatus) {
        let tokens = splitNul(output)
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if token.hasPrefix("## ") {
                parseBranchHeader(String(token.dropFirst(3)), into: &result)
                continue
            }
            let chars = Array(token)
            guard chars.count > 3 else { continue }
            let x = chars[0], y = chars[1]
            let path = String(chars[3...])
            var original: String?
            // 이름 변경·복사는 다음 토큰이 원래 경로다.
            if x == "R" || x == "C" || y == "R" || y == "C", index < tokens.count {
                original = tokens[index]
                index += 1
            }
            if x == "?" && y == "?" {
                result.untracked.append(GitFileChange(path: path, code: "??", area: .untracked))
                continue
            }
            if x == "!" { continue }
            let conflict = x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D")
            if conflict {
                result.conflicted.append(GitFileChange(path: path, originalPath: original, code: "U",
                                                       area: .conflicted))
                continue
            }
            if x != " " {
                result.staged.append(GitFileChange(path: path, originalPath: original, code: String(x),
                                                   area: .staged))
            }
            if y != " " {
                result.unstaged.append(GitFileChange(path: path, originalPath: original, code: String(y),
                                                     area: .unstaged))
            }
        }
    }

    /// `## main...origin/main [ahead 1, behind 2]` 형태.
    static func parseBranchHeader(_ header: String, into result: inout GitWorkspaceStatus) {
        var text = header
        if text.hasPrefix("HEAD (no branch)") {
            result.branch = nil
            return
        }
        // 첫 커밋 전에도 추적 정보가 붙을 수 있다 (빈 원격을 clone: `No commits yet on main...origin/main [gone]`).
        for prefix in ["No commits yet on ", "Initial commit on "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            result.noCommitsYet = true
            break
        }
        var track = ""
        if let open = text.range(of: " [") {
            track = String(text[open.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "]"))
            text = String(text[..<open.lowerBound])
        }
        if let dots = text.range(of: "...") {
            result.branch = String(text[..<dots.lowerBound])
            result.upstream = String(text[dots.upperBound...])
            result.ahead = 0
            result.behind = 0
        } else {
            result.branch = text
        }
        let parsed = parseTrack(track)
        if parsed.gone { result.upstreamGone = true; result.ahead = nil; result.behind = nil }
        if let a = parsed.ahead { result.ahead = a }
        if let b = parsed.behind { result.behind = b }
    }

    /// `ahead 1, behind 2` · `[ahead 1]` · `gone`.
    static func parseTrack(_ raw: String) -> (ahead: Int?, behind: Int?, gone: Bool) {
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if text == "gone" { return (nil, nil, true) }
        var ahead: Int?, behind: Int?
        for part in text.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count == 2, let n = Int(words[1]) else { continue }
            if words[0] == "ahead" { ahead = n }
            if words[0] == "behind" { behind = n }
        }
        return (ahead, behind, false)
    }

    /// `git diff --numstat -z`: `추가\t삭제\t경로\0`, 이름 변경은 `추가\t삭제\t\0원래\0새경로\0`.
    static func parseNumstat(_ output: String) -> [String: (Int?, Int?)] {
        let tokens = splitNul(output)
        var out: [String: (Int?, Int?)] = [:]
        var index = 0
        while index < tokens.count {
            let parts = tokens[index].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            index += 1
            guard parts.count >= 2 else { continue }
            let added = Int(parts[0])      // 이진 파일은 "-" → nil
            let removed = Int(parts[1])
            var path = parts.count == 3 ? String(parts[2]) : ""
            if path.isEmpty, index + 1 < tokens.count {
                path = tokens[index + 1]
                index += 2
            }
            if !path.isEmpty { out[path] = (added, removed) }
        }
        return out
    }

    /// `git worktree list --porcelain` → 브랜치 → 그 worktree 경로. `excluding`(이 폴더의 worktree 뿌리)의 것은 뺀다.
    /// 항목은 빈 줄로 나뉘고 `worktree <경로>` · `branch refs/heads/<이름>` 줄을 쓴다 (떼어진 HEAD · bare 는 branch 줄이 없다).
    static func parseWorktreeBranches(_ output: String, excluding root: String) -> [String: String] {
        var out: [String: String] = [:]
        var path: String?
        // 같은 폴더를 /var · /private/var 처럼 다르게 쓸 수 있어 심볼릭 링크를 풀어 견준다.
        let own = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/"), let current = path,
                      URL(fileURLWithPath: current).resolvingSymlinksInPath().path != own {
                out[String(line.dropFirst("branch refs/heads/".count))] = current
            } else if line.isEmpty {
                path = nil
            }
        }
        return out
    }

    /// `for-each-ref --format=이름%00해시%00HEAD%00upstream%00track[%00상대 시각%00unix 시각] refs/heads` 해석.
    static func parseBranches(_ output: String) -> [GitBranchInfo] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, !f[0].isEmpty else { return nil }
            let track = parseTrack(f[4])
            let date = f.count > 5 ? f[5].trimmingCharacters(in: .whitespaces) : ""
            return GitBranchInfo(name: f[0], shortHash: f[1], isCurrent: f[2] == "*",
                                 upstream: f[3].isEmpty ? nil : f[3],
                                 ahead: track.ahead, behind: track.behind, upstreamGone: track.gone,
                                 committerDate: date.isEmpty ? nil : date,
                                 committedAt: f.count > 6 ? unixDate(f[6]) : nil)
        }
    }

    /// `for-each-ref --format=%(refname)%00%(objectname:short)%00%(committerdate:relative)%00%(committerdate:unix)
    /// refs/remotes` 해석.
    /// 원격 HEAD(`refs/remotes/origin/HEAD`) 는 브랜치가 아니라 뺀다. 짧은 이름은 `refs/remotes/` 를 떼어 만든다
    /// (`%(refname:short)` 는 같은 이름의 로컬 브랜치가 있으면 `remotes/origin/x` 처럼 달라진다).
    static func parseRemoteBranches(_ output: String, remotes: [String]?) -> [GitRemoteBranch] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard let ref = f.first, ref.hasPrefix("refs/remotes/"), !ref.hasSuffix("/HEAD") else { return nil }
            let full = String(ref.dropFirst("refs/remotes/".count))
            guard let split = splitRemoteRef(full, remotes: remotes) else { return nil }
            let hash = f.count > 1 ? f[1] : ""
            let date = f.count > 2 ? f[2].trimmingCharacters(in: .whitespaces) : ""
            return GitRemoteBranch(fullName: full, remote: split.remote, name: split.name,
                                   shortHash: hash.isEmpty ? nil : hash, committerDate: date.isEmpty ? nil : date,
                                   committedAt: f.count > 3 ? unixDate(f[3]) : nil)
        }
    }

    /// `origin/feature/x` → (origin, feature/x). 원격 이름에도 `/` 가 들어갈 수 있어, 알려진 원격 이름 중
    /// 가장 긴 것을 앞에서 찾는다. 원격 목록을 모르면 첫 `/` 에서 나눈다.
    static func splitRemoteRef(_ full: String, remotes: [String]?) -> (remote: String, name: String)? {
        if let remotes {
            let match = remotes.filter { !$0.isEmpty && full.hasPrefix($0 + "/") }.max { $0.count < $1.count }
            if let match {
                let name = String(full.dropFirst(match.count + 1))
                return name.isEmpty ? nil : (match, name)
            }
        }
        guard let slash = full.firstIndex(of: "/") else { return nil }
        let remote = String(full[..<slash])
        let name = String(full[full.index(after: slash)...])
        return remote.isEmpty || name.isEmpty ? nil : (remote, name)
    }

    /// `git log --format=%h%x00%s%x00%an%x00%ar[%x00%ct]` 해석 (한 줄에 커밋 하나, 최근 것부터).
    /// 상대 시각(`%ar`) 은 git 이 준 글자 그대로 둔다 (git 에 따라 영어 · 한국어). `%ct` 가 있으면 시각도 담는다.
    static func parseLog(_ output: String) -> [GitLogEntry] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4 else { return nil }
            let hash = f[0].trimmingCharacters(in: .whitespaces)
            guard !hash.isEmpty else { return nil }
            return GitLogEntry(shortHash: hash, subject: f[1], author: f[2],
                               relativeDate: f[3].trimmingCharacters(in: .whitespaces),
                               committedAt: f.count > 4 ? unixDate(f[4]) : nil)
        }
    }

    /// MERGE_MSG → 커밋 메시지 초안. 주석 줄(`#` 로 시작 — git 이 편집기용으로 넣은 `# Conflicts:` 목록 등)을 빼고
    /// 줄 끝 공백 · 겹친 빈 줄 · 앞뒤 빈 줄을 정리한다. 비면 nil.
    ///
    /// 앱은 메시지를 `git commit -F -` 로 넘기는데, 편집기를 거치지 않은 메시지는 기본 정리 방식(whitespace)이라
    /// git 이 주석 줄을 지우지 않는다. 그대로 넘기면 "# Conflicts:" 가 커밋 메시지에 남는다.
    /// `commentPrefix` 는 사용자의 `core.commentChar` (기본 `#`).
    static func mergeMessageDraft(_ raw: String, commentPrefix: String = "#") -> String? {
        let prefix = commentPrefix.isEmpty ? "#" : commentPrefix
        var lines: [String] = []
        for rawLine in raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            // git 은 줄 맨 앞의 주석 문자만 주석으로 본다 (들여쓴 # 는 본문이다).
            if rawLine.hasPrefix(prefix) { continue }
            var line = rawLine
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    /// `git config --get-regexp ^core\.comment(char|string)$` 출력 → 주석 문자. 없거나 `auto` 면 `#`
    /// (auto 여도 git 은 MERGE_MSG 를 `#` 으로 쓴다).
    static func commentPrefix(fromConfig output: String) -> String {
        let values = output.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            return parts.count == 2 ? String(parts[1]) : nil
        }
        guard let value = values.last, !value.isEmpty, value.lowercased() != "auto" else { return "#" }
        return value
    }

    /// 이 명령이 말을 건 원격 이름. 게시(`push --set-upstream origin …`)는 origin, 맨 업로드는
    /// `pushRemote`(`branch.<b>.pushRemote` · `remote.pushDefault`, `GitWorkspace.pushRemote`)가 있으면 그것,
    /// 나머지는 추적 브랜치의 원격(없으면 git 기본값 origin). 원격을 쓰지 않는 명령이면 nil.
    static func remoteName(for operation: GitWrite.Operation, upstream: String?, remotes: [String]?,
                           pushRemote: String? = nil) -> String? {
        switch operation {
        case .push(_, true):
            return "origin"
        case .push:
            if let pushRemote, !pushRemote.isEmpty { return pushRemote }
            if let upstream, let split = splitRemoteRef(upstream, remotes: remotes) { return split.remote }
            return "origin"
        case .pull, .fetch:
            if let upstream, let split = splitRemoteRef(upstream, remotes: remotes) { return split.remote }
            return "origin"
        case .stage, .unstage, .commit, .createBranch, .switchBranch:
            return nil
        }
    }

    /// 원격 주소의 host (`https://github.com/o/r.git` · `git@github.com:o/r.git` · `ssh://git@github.com/o/r`).
    /// 로컬 경로면 nil. ssh 설정의 별칭(`github-work:o/r`)은 적힌 그대로 돌려준다 (실제 host 는 모른다).
    static func host(ofRemoteURL url: String) -> String? {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = text.range(of: "://") {
            var rest = Substring(text[scheme.upperBound...])
            if let end = rest.firstIndex(where: { $0 == "/" }) { rest = rest[..<end] }
            if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
            if rest.hasPrefix("[") { return nil }  // IPv6 주소는 여기서 가리지 않는다
            if let colon = rest.firstIndex(of: ":") { rest = rest[..<colon] }
            return rest.isEmpty ? nil : rest.lowercased()
        }
        // scp 형식 `[user@]host:path` — 첫 `/` 보다 앞에 `:` 가 있을 때만 (git 의 규칙). 그 밖은 로컬 경로.
        guard let colon = text.firstIndex(of: ":"),
              text.firstIndex(of: "/").map({ colon < $0 }) ?? true else { return nil }
        var host = Substring(text[..<colon])
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        return host.isEmpty ? nil : host.lowercased()
    }

    /// `git log -1 --format=%H%x00%h%x00%s%x00%ct` 해석.
    static func parseLastCommit(_ output: String) -> GitCommitSummary? {
        let line = output.trimmingCharacters(in: .newlines)
        let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 4, !f[0].isEmpty, !f[1].isEmpty else { return nil }
        let seconds = TimeInterval(f[3].trimmingCharacters(in: .whitespaces))
        return GitCommitSummary(hash: f[0], shortHash: f[1], subject: f[2],
                                date: seconds.map { Date(timeIntervalSince1970: $0) })
    }

    /// `git remote` — 한 줄에 원격 이름 하나.
    static func parseRemotes(_ output: String) -> [String] {
        output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `git rev-parse --git-path` 는 명령을 실행한 폴더 기준 상대 경로를 줄 수 있다 (`.git/FETCH_HEAD`).
    static func resolveGitPath(_ output: String, relativeTo directory: URL) -> String {
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("/") { return path }
        return directory.appendingPathComponent(path).standardizedFileURL.path
    }

    /// `rev-parse --path-format=absolute --git-path FETCH_HEAD --git-common-dir` 출력 → 살펴볼 FETCH_HEAD 경로들.
    /// 첫 줄은 이 작업 트리의 FETCH_HEAD, 둘째 줄은 공통 폴더(주 작업 트리에서 fetch 하면 여기에 쓴다).
    /// `--path-format` 을 모르는 옛 git 이 상대 경로를 주면 실행 폴더 기준으로 푼다.
    static func fetchHeadCandidates(_ output: String, relativeTo directory: URL) -> [String] {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("--") }
        guard let first = lines.first else { return [] }
        var paths = [resolveGitPath(first, relativeTo: directory)]
        if lines.count > 1 {
            let common = resolveGitPath(lines[1], relativeTo: directory)
            let shared = URL(fileURLWithPath: common).appendingPathComponent("FETCH_HEAD").path
            if !paths.contains(shared) { paths.append(shared) }
        }
        return paths
    }

    /// 파일이 있고 비어 있지 않을 때의 수정 시각. 원격에 닿지 못한 fetch 는 FETCH_HEAD 를 0 바이트로 비운다
    /// (git 2.42 실측) — 그 시각을 "원격을 확인한 시각" 으로 쓰지 않는다.
    static func nonEmptyModificationDate(_ path: String) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int, size > 0 else { return nil }
        return attributes[.modificationDate] as? Date
    }

    /// git 이 "저장소가 아니다" 라고 말한 오류인지. 영어(`LC_ALL=C`)와 한국어 메시지 둘 다 본다.
    static func isNotRepositoryMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("not a git repository")
            || lower.contains("깃 저장소가 아닙니다") || lower.contains("git 저장소가 아닙니다")
    }

    /// git 의 안내 · 오류 문장을 영어로 받는 환경 (출력 경로 등 데이터는 그대로다).
    static func englishMessages(_ environment: [String: String]) -> [String: String] {
        var env = environment
        env["LC_ALL"] = "C"
        return env
    }

    static func relativePrefix(project: String, root: String) -> String {
        guard project.hasPrefix(root) else { return "" }
        return String(project.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func splitNul(_ output: String) -> [String] {
        var text = output
        while text.hasSuffix("\n") { text.removeLast() }
        return text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: 내부

    /// 병합 중일 때 MERGE_MSG 를 읽어 커밋 초안으로 다듬는다. 경로는 작업 트리마다 다르므로 git 에게 묻는다.
    /// 사용자가 주석 문자를 바꿨으면(`core.commentChar`) 그 문자로 시작하는 줄을 뺀다.
    private static func readMergeMessage(_ git: String, env: [String: String], in directory: URL) async -> String? {
        // `--path-format` 을 모르는 옛 git 은 그 인수를 글자 그대로 한 줄 먼저 쓴다 — 마지막 경로 줄만 쓴다.
        guard case .success(let out) = await run(git, ["rev-parse", "--path-format=absolute", "--git-path", "MERGE_MSG"],
                                                 env: env, in: directory),
              let line = out.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
                .last(where: { !$0.isEmpty && !$0.hasPrefix("--") }) else { return nil }
        let path = resolveGitPath(line, relativeTo: directory)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int, size < 256 * 1024,
              let data = FileManager.default.contents(atPath: path),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        var prefix = "#"
        if case .success(let config) = await run(git, ["config", "--get-regexp", #"^core\.comment(char|string)$"#],
                                                 env: env, in: directory) {
            prefix = commentPrefix(fromConfig: config)
        }
        return mergeMessageDraft(raw, commentPrefix: prefix)
    }

    /// 새 파일은 numstat 에 없으므로 줄 수를 직접 센다. 크거나 이진이면 비워 둔다.
    private static func countUntrackedLines(_ changes: inout [GitFileChange], root: URL) {
        for i in changes.indices.prefix(300) {
            let url = root.appendingPathComponent(changes[i].path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int, size < 512 * 1024,
                  let data = try? Data(contentsOf: url) else { continue }
            if data.prefix(8192).contains(0) { continue }
            var lines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            if let last = data.last, last != 0x0A { lines += 1 }
            changes[i].added = lines
            changes[i].removed = 0
        }
    }

    static func readOnlyEnvironment(_ environment: [String: String]) -> [String: String] {
        var env = environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }

    /// 한 번 실패하면 한 번만 다시 돌린다.
    private static func runRetrying(_ git: String, _ arguments: [String], env: [String: String],
                                    in directory: URL) async -> CLIEnvironment.CaptureResult {
        let first = await run(git, arguments, env: env, in: directory, timeout: 30)
        if case .success = first { return first }
        return await run(git, arguments, env: env, in: directory, timeout: 30)
    }

    private static func run(_ git: String, _ arguments: [String], env: [String: String], in directory: URL,
                            timeout: TimeInterval = 15) async -> CLIEnvironment.CaptureResult {
        await CLIEnvironment.captureOutput(executable: git,
                                           arguments: GitInspector.commandArguments(["--no-optional-locks", "-c", "core.quotepath=false"]
                                               + arguments),
                                           environment: env, workingDirectory: directory, timeout: timeout)
    }
}
