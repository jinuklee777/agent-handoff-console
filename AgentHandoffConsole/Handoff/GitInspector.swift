import Foundation

/// 작업 폴더의 현재 상태를 읽는다. Git 저장소가 아닌 폴더도 지원한다.
enum GitInspector {

    /// 앱이 실행하는 Git은 저장소에 설정된 파일 감시 프로그램을 실행하지 않는다.
    /// 읽기 전용 status도 fsmonitor 훅을 실행할 수 있다. 명령행 설정으로 전역 · 저장소 설정을 덮는다.
    /// 사용자가 직접 요청한 commit 등의 일반 훅은 그대로 둔다.
    /// 앱이 스스로 읽는 status · diff 는 여기에 더해 `readEnvironment` (filter · diff 드라이버 · 색인 쓰기) 와
    /// `submoduleReadArguments` · `readDiffArguments` 를 쓴다.
    static func commandArguments(_ arguments: [String]) -> [String] {
        ["-c", "core.fsmonitor=false"] + arguments
    }

    // MARK: 읽기 전용 git 의 드라이버 차단

    /// 앱이 스스로 돌리는 읽기 전용 status · diff 는 하위 모듈(submodule) 안에서 git 을 다시 띄우지 않는다 — 그 git 은 하위 모듈의
    /// 설정 · `.gitattributes` · 드라이버를 읽어 실행한다 (`readEnvironment` 는 이 저장소의 설정만 본다, 2026-10 실측).
    /// 그래서 하위 모듈은 가리키는 커밋이 바뀌었을 때만 바뀐 것으로 나온다 — 하위 모듈 안의 커밋하지 않은 변경은 목록에 없다.
    /// 명령행 값이라 저장소의 `submodule.<이름>.ignore` 보다 앞선다.
    static let submoduleReadArguments: [String] = ["--ignore-submodules=dirty"]

    /// 앱이 스스로 읽는 diff 의 공통 인수: 외부 diff(`diff.external` · `diff.<드라이버>.command`) · textconv 를 부르지 않고,
    /// 하위 모듈은 커밋 한 줄로 (`diff.submodule=diff` 면 하위 모듈 안에서 diff 를 다시 띄워 그 저장소의 textconv 를 부른다), 색 없이.
    static let readDiffArguments: [String] = ["--no-ext-diff", "--no-textconv", "--no-color", "--submodule=short"]
        + submoduleReadArguments

    /// `.gitattributes` 의 `filter=` · `diff=` 가 고르는 드라이버 중 프로그램을 부르는 키와, git-lfs 가 clean · smudge 때 부르는
    /// 확장(`lfs.extension.<이름>.clean · smudge` — git-lfs 는 저장소의 `.git/config` 에 적힌 것도 읽는다).
    static let driverKeyPattern =
        #"^((filter|diff)\..+\.(clean|smudge|process|textconv|command)|lfs\.extension\..+\.(clean|smudge))$"#

    /// 믿는 설정 범위 — 사용자의 시스템 · 전역 설정과 앱 · 사용자 환경이 넘긴 값(`command`). 저장소 쪽(local · worktree)은 믿지 않는다.
    static let trustedConfigScopes: Set<String> = ["system", "global", "command"]

    /// 드라이버 목록을 읽지 못해 읽기를 그만뒀을 때의 오류.
    static let driverCheckFailedMessage = "저장소의 git 설정(filter · diff 드라이버)을 확인하지 못해 읽지 않았습니다. 다시 읽어 주세요."

    /// 앱이 스스로 돌리는 읽기 전용 git (변경사항 탭 · 실행 전후 비교 · 인계 · 독립 작업 폴더 · 자동 작업 검토)의 환경.
    /// 읽기 전용 status · diff 도 작업 트리 파일을 색인과 견줄 때 저장소가 정한 clean · process 필터를 실행하고, diff 는 textconv 도
    /// 실행한다 (`readDiffArguments` 가 끈다, 2026-10 실측 — Apple git 2.50 · Homebrew git 2.55). 압축을 푼 폴더나 에이전트가 쓴
    /// `.git/config` 가 사람의 승인 없이 프로그램을 돌리게 된다 (fsmonitor 와 같은 길).
    /// - 저장소 쪽 설정이 정한 드라이버는 명령을 빈 값으로 덮어 끈다 (`driverOverrides` — 빈 명령은 git 이 부르지 않는다).
    ///   사용자의 전역 · 시스템 설정이 정한 드라이버(git-lfs 등)와 같은 명령을 저장소가 다시 적은 것은 그대로 둔다 — 끄면 그 파일을
    ///   바뀐 것으로 잘못 읽는다 (색인의 내용은 필터를 거친 것이다). 저장소 쪽 설정이 git-lfs 확장을 적었으면 git-lfs 를 부르는
    ///   전역 필터도 끈다 — 그 필터를 거쳐 git-lfs 가 저장소가 고른 명령을 돌린다.
    /// - 색인을 쓰지 않는다 (`GIT_OPTIONAL_LOCKS=0` — 색인을 새로 쓰면 저장소의 `post-index-change` 훅이 돈다). `git diff` 는 이것과
    ///   상관없이 시각만 바뀐 파일의 색인을 새로 써서(`diff.autoRefreshIndex`) 꺼 둔다 (`readConfig` — 2026-10 실측, Apple git 2.50 ·
    ///   Homebrew git 2.55). 끄면 색인은 그대로지만 시각만 바뀐 파일이 diff 의 일부 출력에 남는다 — patch 에서는 빠지고,
    ///   `--numstat` · `--stat` 에는 이진 파일만(`-\t-` · "Bin 6 -> 6 bytes"), `--name-only` · `--raw` 에는 모두 나온다. 그런 출력은
    ///   status 의 목록과 함께 읽는다 (`statWithoutStatDirtyBinaries`).
    /// - 덮는 값은 환경으로 넘긴다 (`overriding` — git 2.31+). 그 전 git 은 그 환경을 말없이 버리므로 옛 꼴(`legacyOverriding`)로 넘긴다
    ///   (`gitVersion` — 실행 파일마다 한 번 읽는다).
    /// 드라이버 목록 · git 버전을 읽지 못하면 nil — 그때는 읽지 않는다. 조회 한 번마다 새로 읽는다 (그 조회 도중에 바뀐 설정까지 막지는 못한다).
    static func readEnvironment(git: String, at directory: URL, environment: [String: String]) async -> [String: String]? {
        let readOnly = GitWorkspace.readOnlyEnvironment(environment)
        // 설정을 읽기만 한다 (아무것도 실행하지 않는다). 맞는 키가 없으면 종료 코드 1 · 빈 출력이다.
        let listing = await CLIEnvironment.captureProcess(
            executable: git, arguments: commandArguments(["config", "--show-scope", "--null", "--get-regexp", driverKeyPattern]),
            environment: readOnly, workingDirectory: directory, timeout: 15)
        guard listing.succeeded || (listing.note == nil && listing.exitStatus == 1 && listing.stdout.isEmpty) else { return nil }
        guard let version = await gitVersion(git, environment: readOnly) else { return nil }
        let overrides = readConfig + driverOverrides(listing.stdout)
        return readsConfigEnvironment(version) ? overriding(readOnly, with: overrides) : legacyOverriding(readOnly, with: overrides)
    }

    /// 앱이 스스로 읽을 때 늘 덮는 설정 — 시각만 바뀐 파일을 `git diff` 가 색인에 새로 쓰지 않게 (색인 훅 · 잠금).
    static let readConfig: [(key: String, value: String)] = [(key: "diff.autoRefreshIndex", value: "false")]

    /// `git config --show-scope --null --get-regexp` 출력 → 끌 드라이버의 덮을 키 · 값 (순수).
    /// 출력은 "범위 NUL 키 LF 값 NUL" 의 반복이다 (값이 없는 키는 LF 가 없다). 드라이버 이름(가운데)에는 `.` · `=` · 빈칸이 올 수 있다.
    /// 믿지 않는 범위의 명령이 믿는 범위에 같은 키 · 같은 값으로 없으면 그 드라이버를 통째로 끈다 —
    /// filter 는 clean · smudge · process 를 비우고 required 를 끄고 (켜 둔 채 비우면 git 이 멈춘다), diff 는 textconv · command 를 비운다.
    /// 믿지 않는 범위에 git-lfs 확장(`lfs.extension.…`)이 있으면 git-lfs 를 부르는 믿는 필터(`git lfs install` 의 `filter.lfs.…`)도
    /// 같은 식으로 끈다 — 확장 키는 덮지 않는다 (빈 명령이면 git-lfs 가 실행하지 못해 status 가 멈춘다). 그 저장소의 LFS 파일은
    /// 시각만 바뀌어도 바뀐 것으로 나올 수 있다.
    static func driverOverrides(_ listing: String) -> [(key: String, value: String)] {
        let fields = listing.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var trusted: [String: Set<String>] = [:]
        var trustedItems: [(key: String, value: String)] = []
        var untrusted: [(key: String, value: String)] = []
        var index = 0
        while index + 1 < fields.count {
            let scope = fields[index]
            let parts = fields[index + 1].split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            index += 2
            guard let first = parts.first else { continue }
            let key = String(first)
            let value = parts.count > 1 ? String(parts[1]) : ""
            if trustedConfigScopes.contains(scope) {
                trusted[key, default: []].insert(value)
                trustedItems.append((key: key, value: value))
            } else {
                untrusted.append((key: key, value: value))
            }
        }
        // "filter.<이름>." · "diff.<이름>." — 처음 나온 순서대로.
        var prefixes: [String] = []
        func add(_ key: String) {
            guard let last = key.lastIndex(of: ".") else { return }
            let prefix = String(key[...last])
            if !prefixes.contains(prefix) { prefixes.append(prefix) }
        }
        var lfsExtension = false
        for item in untrusted where trusted[item.key]?.contains(item.value) != true {
            if item.key.hasPrefix("lfs.extension.") { lfsExtension = true } else { add(item.key) }
        }
        if lfsExtension {
            for item in trustedItems where item.key.hasPrefix("filter.") && runsGitLFS(item.value) { add(item.key) }
        }
        return prefixes.flatMap { prefix -> [(key: String, value: String)] in
            prefix.hasPrefix("filter.")
                ? [(key: prefix + "clean", value: ""), (key: prefix + "smudge", value: ""),
                   (key: prefix + "process", value: ""), (key: prefix + "required", value: "false")]
                : [(key: prefix + "textconv", value: ""), (key: prefix + "command", value: "")]
        }
    }

    /// 필터 명령이 git-lfs 를 부르는지 (`git-lfs filter-process` · `git lfs clean -- %f` · 경로를 붙인 `…/git-lfs`).
    static func runsGitLFS(_ command: String) -> Bool {
        command.contains("git-lfs") || command.contains("git lfs")
    }

    /// 환경으로 넘기는 설정 (`GIT_CONFIG_COUNT` · `GIT_CONFIG_KEY_n` · `GIT_CONFIG_VALUE_n`, git 2.31+) — `-c 키=값` 은 첫 `=` 에서
    /// 나누므로 이름에 `=` 가 든 드라이버를 덮지 못한다. 저장소 설정보다 앞서고, 환경에 이미 있던 항목 뒤에 붙인다 (순수).
    static func overriding(_ environment: [String: String], with overrides: [(key: String, value: String)]) -> [String: String] {
        guard !overrides.isEmpty else { return environment }
        var env = environment
        var count = max(0, Int(env["GIT_CONFIG_COUNT"] ?? "") ?? 0)
        for item in overrides {
            env["GIT_CONFIG_KEY_\(count)"] = item.key
            env["GIT_CONFIG_VALUE_\(count)"] = item.value
            count += 1
        }
        env["GIT_CONFIG_COUNT"] = String(count)
        return env
    }

    /// git 2.31 전의 꼴 — `GIT_CONFIG_PARAMETERS` 에 `'키=값'` 을 빈칸으로 잇는다 (`-c` 와 같은 길, 새 git 도 읽는다). 첫 `=` 에서
    /// 나누므로 이름에 `=` 가 든 드라이버는 덮지 못한다 — 그때는 nil (읽지 않는다). 환경에 이미 있던 값 뒤에 붙인다 (순수).
    static func legacyOverriding(_ environment: [String: String],
                                 with overrides: [(key: String, value: String)]) -> [String: String]? {
        guard !overrides.isEmpty else { return environment }
        guard !overrides.contains(where: { $0.key.contains("=") }) else { return nil }
        // git 의 sq_dequote 가 푸는 꼴: 작은따옴표 안은 그대로, 작은따옴표는 '\'' 로.
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
        let added = overrides.map { quoted($0.key + "=" + $0.value) }.joined(separator: " ")
        var env = environment
        let existing = env["GIT_CONFIG_PARAMETERS"].map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        env["GIT_CONFIG_PARAMETERS"] = existing.isEmpty ? added : existing + " " + added
        return env
    }

    /// git 이 환경의 설정(`GIT_CONFIG_COUNT`)을 읽는 버전인지 — 2.31 부터.
    static func readsConfigEnvironment(_ version: (major: Int, minor: Int)) -> Bool {
        version.major > 2 || (version.major == 2 && version.minor >= 31)
    }

    /// `git version` 출력 → (주, 부) 버전 (순수) — "git version 2.50.1 (Apple Git-155)" → (2, 50). 읽지 못하면 nil.
    static func parseVersion(_ output: String) -> (major: Int, minor: Int)? {
        guard let range = output.range(of: #"git version (\d+)\.(\d+)"#, options: .regularExpression) else { return nil }
        let numbers = output[range].dropFirst("git version ".count).split(separator: ".").compactMap { Int($0) }
        return numbers.count == 2 ? (major: numbers[0], minor: numbers[1]) : nil
    }

    /// 실행 파일마다의 git 버전 — 한 번 읽어 둔다 (읽지 못하면 두지 않고 다음에 다시 읽는다).
    nonisolated(unsafe) private static var versions: [String: (major: Int, minor: Int)] = [:]
    private static let versionLock = UnfairLock()

    static func gitVersion(_ git: String, environment: [String: String]) async -> (major: Int, minor: Int)? {
        if let known = versionLock.withLock({ versions[git] }) { return known }
        guard case .success(let output) = await CLIEnvironment.captureOutput(
            executable: git, arguments: ["version"], environment: environment, timeout: 15),
              let version = parseVersion(output) else { return nil }
        versionLock.withLock { versions[git] = version }
        return version
    }

    /// `git diff --stat` 에서 시각만 바뀐 이진 파일의 줄을 뺀다 (순수) — 색인을 새로 쓰지 않으면(`readConfig`) 내용이 같은 이진 파일도
    /// " a.bin | Bin 6 -> 6 bytes" 로 나온다. 크기가 같고 status(`--porcelain`)에 없는 경로의 줄만 빼고, 뺐으면 맨 끝의 합계 줄
    /// ("N files changed, …")도 뺀다 (그 수가 맞지 않는다).
    static func statWithoutStatDirtyBinaries(_ stat: String, status: String) -> String {
        var lines = stat.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var removed = false
        lines.removeAll { line in
            let whole = NSRange(line.startIndex..., in: line)
            guard let match = binaryStatRow.firstMatch(in: line, range: whole), match.numberOfRanges == 4,
                  let pathRange = Range(match.range(at: 1), in: line),
                  let before = Range(match.range(at: 2), in: line), let after = Range(match.range(at: 3), in: line),
                  line[before] == line[after] else { return false }
            let path = String(line[pathRange])
            // 긴 경로는 앞을 "..." 로 줄인다.
            let shown = path.hasPrefix("...") ? String(path.dropFirst(3)) : path
            guard !status.contains(shown) else { return false }
            removed = true
            return true
        }
        if removed, let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[last].contains(" changed") {
            lines.remove(at: last)
        }
        return lines.joined(separator: "\n")
    }

    /// `--stat` 의 이진 파일 줄 — 경로 · 앞 크기 · 뒤 크기.
    private static let binaryStatRow = try! NSRegularExpression(pattern: #"^\s*(.+?)\s+\|\s+Bin (\d+) -> (\d+) bytes$"#)

    /// 인계 구간의 새 커밋을 셀 때 가져오는 최대 개수.
    static let commitLimit = 20

    /// `baseHead` — 앞 인계를 만든 때의 HEAD (그 뒤의 커밋을 센다), 없으면 `since` — 구간을 시작한 때 (그 뒤에 커밋된 것).
    /// 둘 다 없으면 새 커밋을 세지 않는다 (nil).
    static func snapshot(at directory: URL, environment: [String: String],
                         maxFilesPerSection: Int = 60, baseHead: String? = nil, since: Date? = nil) async -> GitSnapshot {
        var snap = GitSnapshot()

        guard let git = findGit(environment: environment) else {
            snap.error = "git 실행 파일을 찾지 못했습니다."
            snap.recentlyModified = recentlyModifiedFiles(at: directory, limit: maxFilesPerSection)
            return snap
        }

        let insideResult = await CLIEnvironment.captureOutput(
            executable: git, arguments: commandArguments(["rev-parse", "--is-inside-work-tree"]),
            environment: environment, workingDirectory: directory, timeout: 15)

        guard case .success(let inside) = insideResult,
              inside.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            snap.isRepository = false
            snap.recentlyModified = recentlyModifiedFiles(at: directory, limit: maxFilesPerSection)
            return snap
        }
        snap.isRepository = true
        // 저장소가 정한 filter · diff 드라이버를 끄고 색인을 쓰지 않는 환경 (`readEnvironment`) — 아래의 git 은 모두 이것으로.
        guard let env = await readEnvironment(git: git, at: directory, environment: environment) else {
            snap.error = driverCheckFailedMessage
            return snap
        }

        if case .success(let branch) = await CLIEnvironment.captureOutput(
            executable: git, arguments: commandArguments(["rev-parse", "--abbrev-ref", "HEAD"]),
            environment: env, workingDirectory: directory, timeout: 15) {
            let b = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            snap.branch = b.isEmpty ? nil : b
        }

        if case .success(let status) = await CLIEnvironment.captureOutput(
            executable: git, arguments: commandArguments(["status", "--porcelain=v1", "--untracked-files=all"]
                                                         + submoduleReadArguments),
            environment: env, workingDirectory: directory, timeout: 30) {
            parsePorcelain(status, into: &snap, limit: maxFilesPerSection)
        } else {
            snap.error = "git status 실행에 실패했습니다."
        }

        if case .success(let ab) = await CLIEnvironment.captureOutput(
            executable: git, arguments: commandArguments(["rev-list", "--left-right", "--count", "@{upstream}...HEAD"]),
            environment: env, workingDirectory: directory, timeout: 15) {
            let parts = ab.split(whereSeparator: { $0 == "\t" || $0 == "\n" || $0 == " " })
                .compactMap { Int($0) }
            if parts.count == 2 {
                snap.aheadBehind = "원격 대비 앞섬 \(parts[1]) / 뒤처짐 \(parts[0])"
            }
        }

        let unstagedDiff = await diff(git: git, arguments: ["diff"] + readDiffArguments,
                                      environment: env, directory: directory)
        let stagedDiff = await diff(git: git, arguments: ["diff", "--cached"] + readDiffArguments,
                                    environment: env, directory: directory)
        let combined = [stagedDiff.map { "# staged\n\($0)" },
                        unstagedDiff.map { "# unstaged\n\($0)" }]
            .compactMap { $0 }.joined(separator: "\n\n")
        if !combined.isEmpty {
            snap.diffExcerpt = JSONUtil.truncate(combined, max: HandoffPacketBuilder.diffCharLimit)
        }

        // HEAD 와 인계 구간의 새 커밋 — 사람이 변경사항 탭 · 터미널에서 한 커밋도 받는 쪽이 알게 (커밋이 없는 새 저장소면 둘 다 없다).
        if case .success(let head) = await CLIEnvironment.captureOutput(
            executable: git, arguments: commandArguments(["rev-parse", "HEAD"]),
            environment: env, workingDirectory: directory, timeout: 15) {
            // 커밋이 없는 저장소의 `rev-parse HEAD` 는 실패하면서 "HEAD" 를 stdout 에 낸다 — 해시 모양일 때만 받는다.
            let hash = head.trimmingCharacters(in: .whitespacesAndNewlines)
            if hash.count >= 7, hash.allSatisfy(\.isHexDigit) { snap.head = hash }
        }
        if snap.head != nil {
            snap.commitsSinceBase = await commits(git: git, baseHead: baseHead, since: since,
                                                  environment: env, directory: directory)
        }

        return snap
    }

    /// 앞 인계의 HEAD 이후(`base..HEAD`) 또는 구간 시작 이후(`--since`)의 커밋 — "짧은 해시 제목" 한 줄씩, 최근 것 먼저.
    /// 앞 HEAD 를 찾지 못하면(가비지 수집 · 다른 저장소) 시각으로 센다. 기준이 없으면 nil.
    /// 서명은 확인하지 않는다 (`log.showSignature` 를 켠 저장소에서 `gpg.program` 이 돌지 않게).
    private static func commits(git: String, baseHead: String?, since: Date?, environment: [String: String],
                                directory: URL) async -> [String]? {
        let format = ["log", "--no-show-signature", "--no-color", "--format=%h %s", "-n", String(commitLimit)]
        func run(_ arguments: [String]) async -> [String]? {
            guard case .success(let output) = await CLIEnvironment.captureOutput(
                executable: git, arguments: commandArguments(arguments), environment: environment,
                workingDirectory: directory, timeout: 15) else { return nil }
            return output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let baseHead, !baseHead.isEmpty, !baseHead.hasPrefix("-"),
           let listed = await run(format + ["\(baseHead)..HEAD"]) {
            return listed
        }
        guard let since else { return nil }
        // git 의 내부 날짜 형식 ("@<유닉스 초> <시간대>") — 지역 설정 · 날짜 해석과 무관하다.
        return await run(format + ["--since=@\(Int(since.timeIntervalSince1970)) +0000", "HEAD"])
    }

    private static func diff(git: String, arguments: [String], environment: [String: String],
                             directory: URL) async -> String? {
        guard case .success(let output) = await CLIEnvironment.captureOutput(
            executable: git, arguments: commandArguments(arguments), environment: environment,
            workingDirectory: directory, timeout: 30) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `git status --porcelain=v1` 을 staged / unstaged / untracked 로 나눈다.
    /// XY 에서 X 는 인덱스(staged), Y 는 작업 트리(unstaged) 상태다.
    static func parsePorcelain(_ output: String, into snap: inout GitSnapshot, limit: Int) {
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard line.count > 3 else { continue }
            let chars = Array(line)
            let x = chars[0]
            let y = chars[1]
            var path = String(chars[3...]).trimmingCharacters(in: .whitespaces)
            // 이름 변경은 "old -> new" 형태.
            if let range = path.range(of: " -> ") {
                path = String(path[range.upperBound...])
            }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            if x == "?" && y == "?" {
                if snap.untracked.count < limit { snap.untracked.append(path) }
                continue
            }
            if x != " " && x != "?" {
                if snap.staged.count < limit { snap.staged.append("\(x) \(path)") }
            }
            if y != " " && y != "?" {
                if snap.unstaged.count < limit { snap.unstaged.append("\(y) \(path)") }
            }
        }
    }

    /// `/usr/bin/git` 은 Command Line Tools 가 없으면 macOS 설치 창을 띄우는 shim 이다. 앱이 CLT 가 없다고 확인하면
    /// (`xcode-select -p` — `AppModel.gitTools`) 켜고, 그동안은 그 shim 을 고르지 않는다 (Homebrew 등 다른 git 은 그대로 쓴다).
    nonisolated(unsafe) private static var shimUnavailable = false
    private static let shimLock = UnfairLock()
    static var systemGitShimUnavailable: Bool {
        get { shimLock.withLock { shimUnavailable } }
        set { shimLock.withLock { shimUnavailable = newValue } }
    }
    static let systemGitShim = "/usr/bin/git"

    static func findGit(environment: [String: String]) -> String? {
        let skipShim = systemGitShimUnavailable
        let candidates = [systemGitShim, "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        for c in candidates where !(skipShim && c == systemGitShim) && FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        guard let path = environment["PATH"] else { return nil }
        for dir in path.split(separator: ":") {
            let c = (String(dir) as NSString).appendingPathComponent("git")
            if skipShim, (c as NSString).standardizingPath == systemGitShim { continue }
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return nil
    }

    private static let ignoredDirectories: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", ".venv", "venv",
        "__pycache__", ".next", "dist", "build", ".gradle", "Pods", ".terraform",
    ]

    /// Git 저장소가 아닐 때 최근 수정 파일로 대체한다.
    static func recentlyModifiedFiles(at directory: URL, limit: Int,
                                      within: TimeInterval = 60 * 60 * 24 * 3) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        let cutoff = Date().addingTimeInterval(-within)
        var results: [(String, Date)] = []
        var visited = 0

        for case let url as URL in enumerator {
            visited += 1
            if visited > 20000 { break }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if ignoredDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard let modified = values?.contentModificationDate, modified > cutoff else { continue }
            let relative = url.path.replacingOccurrences(
                of: directory.path + "/", with: "")
            results.append((relative, modified))
        }

        return results.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }
}
