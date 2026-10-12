import Foundation

/// git 쓰기 명령 검증. 인수 구성은 순수 함수로, 실제 동작은 임시 저장소에서 확인한다.
/// 원격은 **로컬 bare 저장소**를 origin 으로 삼아 네트워크 없이 push·pull 을 실제로 돌린다.
enum GitWriteTests {
    static func run(_ t: TestKit) async {
        await fsmonitorIsolation(t)
        await driverIsolation(t)
        await lfsExtensionIsolation(t)
        await arguments(t)
        await liveRepository(t)
        await exitCodes(t)
        await throughAppModel(t)
        await failuresThroughAppModel(t)
        await initThroughAppModel(t)
    }

    /// 읽기 전용 Git도 설정된 fsmonitor 프로그램을 실행한다. 실제 훅으로 각 앱 진입점을 검증한다.
    private static func fsmonitorIsolation(_ t: TestKit) async {
        await t.group("Git 파일 감시 프로그램 실행 차단")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ahc-fsmonitor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let repository = root.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            let marker = root.appendingPathComponent("hook-ran")
            let hook = root.appendingPathComponent("fsmonitor")
            let body = "#!/bin/sh\nprintf ran > \"$AHC_FSMONITOR_MARKER\"\nprintf 'token\\000'\n"
            try body.write(to: hook, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
            var environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1",
                               "GIT_CONFIG_GLOBAL": "/dev/null", "AHC_FSMONITOR_MARKER": marker.path,
                               "GIT_AUTHOR_NAME": "Example", "GIT_AUTHOR_EMAIL": "example@example.invalid",
                               "GIT_COMMITTER_NAME": "Example", "GIT_COMMITTER_EMAIL": "example@example.invalid"]
            let git = "/usr/bin/git"
            func raw(_ arguments: [String]) async -> CLIEnvironment.ProcessCapture {
                await CLIEnvironment.captureProcess(executable: git, arguments: arguments, environment: environment,
                                                    workingDirectory: repository, timeout: 15)
            }
            _ = await raw(["init", "-b", "main"])
            try "before\n".write(to: repository.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
            _ = await raw(["add", "sample.txt"])
            let initial = await raw(["commit", "-m", "fixture"])
            await t.check("시험용 저장소 준비", initial.succeeded, initial.combinedOutput)
            _ = await raw(["config", "core.fsmonitor", hook.path])
            _ = await raw(["status", "--porcelain"])
            await t.check("대조군: 일반 status는 훅을 실행", FileManager.default.fileExists(atPath: marker.path))
            try? FileManager.default.removeItem(at: marker)
            try "after\n".write(to: repository.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
            // 환경의 Git 설정보다도 명령행의 차단이 우선한다.
            environment["GIT_CONFIG_COUNT"] = "1"
            environment["GIT_CONFIG_KEY_0"] = "core.fsmonitor"
            environment["GIT_CONFIG_VALUE_0"] = hook.path
            let status = await GitWorkspace.status(at: repository, environment: environment)
            await t.check("변경사항 조회는 파일 변경을 읽고 훅을 실행하지 않음",
                          status.error == nil && status.unstaged.contains { $0.path == "sample.txt" }
                          && !FileManager.default.fileExists(atPath: marker.path))
            let snapshot = await GitInspector.snapshot(at: repository, environment: environment)
            await t.check("인계 스냅샷도 훅 없이 diff 읽음", snapshot.isRepository && snapshot.diffExcerpt?.contains("after") == true
                          && !FileManager.default.fileExists(atPath: marker.path))
            let stage = await GitWrite.perform(.stage(["sample.txt"]), git: git, at: repository, environment: environment)
            await t.check("스테이지도 훅을 실행하지 않음", stage.succeeded && !FileManager.default.fileExists(atPath: marker.path))
            let head = await raw(["rev-parse", "HEAD"])
            let worktree = ThreadWorktree(path: repository.path, branch: "main", baseBranch: "main",
                                         baseCommit: head.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            let worktreeStatus = await Worktrees.status(worktree, project: repository, git: git, environment: environment)
            await t.check("독립 작업 폴더 조회도 훅을 실행하지 않음", worktreeStatus.uncommitted == 1
                          && !FileManager.default.fileExists(atPath: marker.path))
            let commit = await GitWrite.perform(.commit(message: "change"), git: git, at: repository, environment: environment)
            await t.check("커밋도 파일 감시 프로그램 없이 성공", commit.succeeded && !FileManager.default.fileExists(atPath: marker.path))
        } catch {
            await t.check("파일 감시 차단 검증 준비", false, error.localizedDescription)
        }
    }

    /// 읽기 전용 status · diff 도 저장소가 정한 clean 필터 · textconv 를 실행한다 (`.gitattributes` 의 `filter=` · `diff=` — 하위 저장소
    /// 안에서도). 색인을 새로 쓰면 저장소의 `post-index-change` 훅도 돈다. 앱이 스스로 읽는 길(변경사항 · 파일 diff · 인계 스냅샷 ·
    /// 인계 지문 · 독립 작업 폴더 · 자동 작업 검토)은 그 명령을 부르지 않고, 사람이 고른 스테이지 · 커밋은 그대로 필터 · 훅을 거친다
    /// (`GitInspector.readEnvironment`).
    @MainActor
    private static func driverIsolation(_ t: TestKit) async {
        await t.group("Git 저장소 드라이버(filter · textconv) 실행 차단")
        // 순수 판정: 저장소 쪽(local · worktree) 드라이버만 끄고, 사용자 전역 설정과 같은 명령 · 환경이 넘긴 값은 둔다. 이름에 `=` · 빈칸이 있어도.
        let listing = ["global", "filter.lfs.clean\ngit-lfs clean -- %f",
                       "local", "filter.lfs.clean\ngit-lfs clean -- %f",
                       "local", "filter.a=b.process\nrun-me",
                       "worktree", "diff.Notes Driver.textconv\nrun-me",
                       "command", "filter.mine.clean\nmine"].joined(separator: "\0") + "\0"
        let overrides = GitInspector.driverOverrides(listing)
        await t.equal("저장소 쪽 드라이버만 통째로 끈다 (전역과 같은 명령 · 환경의 값은 둔다)", overrides.map { $0.key },
                      ["filter.a=b.clean", "filter.a=b.smudge", "filter.a=b.process", "filter.a=b.required",
                       "diff.Notes Driver.textconv", "diff.Notes Driver.command"])
        await t.equal("명령은 빈 값 · filter 의 required 는 false", overrides.map { $0.value }, ["", "", "", "false", "", ""])
        await t.check("드라이버가 없으면 덮지 않는다", GitInspector.driverOverrides("").isEmpty
                      && GitInspector.driverOverrides("global\0filter.lfs.clean\ngit-lfs clean -- %f\0").isEmpty)
        let appended = GitInspector.overriding(["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.fsmonitor",
                                                "GIT_CONFIG_VALUE_0": "x"], with: Array(overrides.prefix(2)))
        await t.check("환경으로 넘긴 설정 뒤에 붙인다 (`-c` 는 이름의 `=` 에서 끊긴다)",
                      appended["GIT_CONFIG_COUNT"] == "3" && appended["GIT_CONFIG_KEY_0"] == "core.fsmonitor"
                        && appended["GIT_CONFIG_KEY_1"] == "filter.a=b.clean" && appended["GIT_CONFIG_VALUE_1"] == ""
                        && appended["GIT_CONFIG_KEY_2"] == "filter.a=b.smudge", "\(appended)")

        // git-lfs 는 저장소의 `.git/config` 에 적힌 확장(`lfs.extension.<이름>.clean · smudge`)도 읽어 돌린다 — 저장소 쪽에 확장이
        // 있으면 git-lfs 를 부르는 믿는 필터도 끈다. 확장 키는 덮지 않는다 (빈 명령이면 git-lfs 가 실행하지 못해 status 가 멈춘다).
        let lfsGlobal = ["global", "filter.lfs.clean\ngit-lfs clean -- %f", "global", "filter.lfs.process\ngit-lfs filter-process",
                         "global", "filter.other.clean\nother-clean", "global", "diff.lfs.textconv\ngit-lfs-textconv"]
        let lfsLocal = GitInspector.driverOverrides((lfsGlobal + ["local", "lfs.extension.x.clean\nrun-me %f"])
            .joined(separator: "\0") + "\0")
        await t.equal("저장소 쪽 git-lfs 확장 → git-lfs 를 부르는 전역 필터를 끈다 (다른 필터 · diff 는 둔다)", lfsLocal.map { $0.key },
                      ["filter.lfs.clean", "filter.lfs.smudge", "filter.lfs.process", "filter.lfs.required"])
        await t.check("확장 키 자체는 덮지 않는다", !lfsLocal.contains { $0.key.hasPrefix("lfs.extension.") })
        await t.check("전역 확장 · 전역과 같은 저장소 확장 · 확장 없음은 git-lfs 를 그대로 둔다",
                      GitInspector.driverOverrides((lfsGlobal + ["global", "lfs.extension.x.clean\nmine %f"])
                        .joined(separator: "\0") + "\0").isEmpty
                        && GitInspector.driverOverrides((lfsGlobal + ["global", "lfs.extension.x.smudge\nmine %f",
                                                                      "local", "lfs.extension.x.smudge\nmine %f"])
                            .joined(separator: "\0") + "\0").isEmpty
                        && GitInspector.driverOverrides(lfsGlobal.joined(separator: "\0") + "\0").isEmpty)
        await t.check("git-lfs 를 부르는 명령 (경로 · git lfs 꼴)", GitInspector.runsGitLFS("/opt/homebrew/bin/git-lfs filter-process")
                        && GitInspector.runsGitLFS("git lfs clean -- %f") && !GitInspector.runsGitLFS("cat"))

        // git 2.31 전에는 환경의 설정(GIT_CONFIG_COUNT)을 말없이 버린다 — 옛 꼴(GIT_CONFIG_PARAMETERS)로 넘긴다.
        await t.check("git 버전 읽기", GitInspector.parseVersion("git version 2.50.1 (Apple Git-155)").map { [$0.major, $0.minor] } == [2, 50]
                        && GitInspector.parseVersion("git version 2.30.1\n").map { [$0.major, $0.minor] } == [2, 30]
                        && GitInspector.parseVersion("not git") == nil)
        await t.check("2.31 부터 환경의 설정을 읽는다", GitInspector.readsConfigEnvironment((major: 2, minor: 31))
                        && GitInspector.readsConfigEnvironment((major: 3, minor: 0))
                        && !GitInspector.readsConfigEnvironment((major: 2, minor: 30)))
        let legacy = GitInspector.legacyOverriding(["GIT_CONFIG_PARAMETERS": "'core.fsmonitor=false'"],
                                                   with: [(key: "filter.it's.clean", value: ""), (key: "filter.x.required", value: "false")])
        await t.equal("옛 꼴: '키=값' 을 이미 있던 값 뒤에 (작은따옴표는 '\\'')", legacy?["GIT_CONFIG_PARAMETERS"],
                      #"'core.fsmonitor=false' 'filter.it'\''s.clean=' 'filter.x.required=false'"#)
        await t.check("옛 꼴로는 이름에 = 가 든 드라이버를 덮지 못한다 — 읽지 않는다 (nil)",
                      GitInspector.legacyOverriding([:], with: Array(overrides.prefix(1))) == nil)

        // 색인을 새로 쓰지 않으면 시각만 바뀐 이진 파일도 --stat 에 나온다 — 자동 작업 검토 자료에서는 status 에 없는 그 줄을 뺀다.
        let stat = " b.bin | Bin 6 -> 6 bytes\n g.txt | 1 +\n c.png | Bin 4 -> 9 bytes\n 3 files changed, 1 insertion(+)\n"
        await t.equal("--stat: status 에 없는 · 크기가 같은 이진 줄과 합계 줄을 뺀다",
                      GitInspector.statWithoutStatDirtyBinaries(stat, status: " M g.txt\n M c.png\n"),
                      " g.txt | 1 +\n c.png | Bin 4 -> 9 bytes\n")
        await t.equal("--stat: status 에 있으면 크기가 같아도 둔다",
                      GitInspector.statWithoutStatDirtyBinaries(stat, status: " M b.bin\n M g.txt\n M c.png\n"), stat)

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ahc-gitdriver-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        do {
            let repository = root.appendingPathComponent("repo")
            let inner = repository.appendingPathComponent("inner")
            try fm.createDirectory(at: inner, withIntermediateDirectories: true)
            let marker = root.appendingPathComponent("driver-ran")
            let environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1",
                               "GIT_CONFIG_GLOBAL": "/dev/null",
                               "GIT_AUTHOR_NAME": "Example", "GIT_AUTHOR_EMAIL": "example@example.invalid",
                               "GIT_COMMITTER_NAME": "Example", "GIT_COMMITTER_EMAIL": "example@example.invalid"]
            let git = "/usr/bin/git"
            func raw(_ arguments: [String], in directory: URL? = nil) async -> CLIEnvironment.ProcessCapture {
                await CLIEnvironment.captureProcess(executable: git, arguments: arguments, environment: environment,
                                                    workingDirectory: directory ?? repository, timeout: 15)
            }
            func write(_ text: String, _ name: String, in directory: URL? = nil) throws {
                try text.write(to: (directory ?? repository).appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            // 드라이버가 실행될 때마다 표식 파일에 남기는 낱말 (clean · textconv · nested).
            func ran() -> [String] {
                ((try? String(contentsOf: marker, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            }
            // 내용은 그대로 두고 수정 시각만 바꾼다 — 색인에 적힌 시각과 다르면 git 은 내용을 (clean 필터를 거쳐) 다시 견준다.
            func touch(_ url: URL) {
                try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: url.path)
            }

            // 하위 저장소 (색인에는 gitlink — 상위 status · diff 가 그 안에서 git 을 다시 띄운다).
            _ = await raw(["init", "-q", "-b", "main"], in: inner)
            try write("inside\n", "inner.txt", in: inner)
            try write("*.txt filter=nested\n", ".gitattributes", in: inner)
            _ = await raw(["add", "-A"], in: inner)
            _ = await raw(["commit", "-q", "-m", "inner"], in: inner)
            _ = await raw(["init", "-q", "-b", "main"])
            try write("before\n", "sample.txt")
            try write("same\n", "same.txt")
            try write("*.txt filter=probe diff=probe\n", ".gitattributes")
            _ = await raw(["-c", "advice.addEmbeddedRepo=false", "add", "-A"])
            let initial = await raw(["commit", "-q", "-m", "fixture"])
            await t.check("시험용 저장소 준비 (하위 저장소 포함)", initial.succeeded, initial.combinedOutput)
            // 커밋한 뒤에 드라이버를 건다 (커밋된 내용은 필터를 거치지 않은 그대로). 실행되면 표식 파일에 낱말을 남긴다 — git 이 sh 로 돌린다.
            let quoted = "'" + marker.path + "'"
            _ = await raw(["config", "filter.probe.clean", "printf 'clean\\n' >> \(quoted); tr a-z A-Z"])
            _ = await raw(["config", "filter.probe.smudge", "cat"])
            _ = await raw(["config", "filter.probe.required", "true"])
            _ = await raw(["config", "diff.probe.textconv", "printf 'textconv\\n' >> \(quoted); cat"])
            _ = await raw(["config", "filter.nested.clean", "printf 'nested\\n' >> \(quoted); cat"], in: inner)
            // 색인을 새로 쓰면 도는 훅 — 앱의 읽기는 색인을 쓰지 않는다 (`GIT_OPTIONAL_LOCKS=0` · `diff.autoRefreshIndex=false` —
            // `git diff` 는 시각만 바뀐 파일(`same.txt`)이 있으면 잠금 설정과 상관없이 색인을 새로 쓴다).
            let hook = repository.appendingPathComponent(".git/hooks/post-index-change")
            try fm.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\nprintf 'index\\n' >> \(quoted)\n".write(to: hook, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
            try write("after\n", "sample.txt")
            touch(repository.appendingPathComponent("same.txt"))
            touch(inner.appendingPathComponent("inner.txt"))

            _ = await raw(["--no-optional-locks", "status", "--porcelain"])
            await t.check("대조군: 일반 status 는 저장소 · 하위 저장소의 clean 필터를 실행",
                          ran().contains("clean") && ran().contains("nested"), ran().joined(separator: " "))
            try? fm.removeItem(at: marker)
            _ = await raw(["--no-optional-locks", "diff", "--no-ext-diff", "--no-color"])
            await t.check("대조군: 일반 diff 는 textconv 도 실행", ran().contains("textconv"), ran().joined(separator: " "))
            try? fm.removeItem(at: marker)

            let status = await GitWorkspace.status(at: repository, environment: environment)
            await t.check("변경사항 조회: 저장소 · 하위 저장소의 드라이버를 실행하지 않음", ran().isEmpty, ran().joined(separator: " "))
            await t.check("변경사항 조회: 바뀐 파일만 · 줄 수까지 (내용이 같은 파일은 필터 없이도 그대로)",
                          status.error == nil && status.unstaged.map { $0.path } == ["sample.txt"]
                            && status.headLineCounts["sample.txt"] == GitLineCount(added: 1, removed: 1),
                          "\(status.error ?? "") \(status.unstaged.map { $0.path }) \(status.headLineCounts)")
            let request = FileDiffRequest(path: "sample.txt", untracked: false, conflicted: false, inclusion: .off,
                                          noCommitsYet: false, changedLines: 2)
            let fileDiff = await GitWorkspace.fileDiff(request, root: repository, environment: environment)
            await t.check("파일 diff: 드라이버 없이 읽음", fileDiff.body == .diff && ran().isEmpty,
                          "\(fileDiff.body) \(ran())")
            let snapshot = await GitInspector.snapshot(at: repository, environment: environment)
            await t.check("인계 스냅샷: diff 를 읽고 드라이버를 실행하지 않음",
                          snapshot.error == nil && snapshot.diffExcerpt?.contains("+after") == true && ran().isEmpty,
                          "\(snapshot.error ?? "") \(ran())")
            let head = await raw(["rev-parse", "HEAD"])
            let worktree = ThreadWorktree(path: repository.path, branch: "main", baseBranch: "main",
                                         baseCommit: head.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            let worktreeStatus = await Worktrees.status(worktree, project: repository, git: git, environment: environment)
            await t.check("독립 작업 폴더 조회: 드라이버 없이 바뀐 파일 하나", worktreeStatus.uncommitted == 1 && ran().isEmpty,
                          "\(String(describing: worktreeStatus.uncommitted)) \(ran())")

            // 옛 꼴(GIT_CONFIG_PARAMETERS — git 2.31 전에 쓰는 길)로 넘겨도 드라이버 · 색인 쓰기를 끈다 (지금 git 도 그 꼴을 읽는다).
            let listed = await raw(["config", "--show-scope", "--null", "--get-regexp", GitInspector.driverKeyPattern])
            if let legacy = GitInspector.legacyOverriding(GitWorkspace.readOnlyEnvironment(environment),
                                                          with: GitInspector.readConfig + GitInspector.driverOverrides(listed.stdout)) {
                touch(repository.appendingPathComponent("same.txt"))
                for arguments in [["status", "--porcelain"] + GitInspector.submoduleReadArguments,
                                  ["diff"] + GitInspector.readDiffArguments] {
                    _ = await CLIEnvironment.captureProcess(executable: git, arguments: GitInspector.commandArguments(arguments),
                                                            environment: legacy, workingDirectory: repository, timeout: 15)
                }
                await t.check("옛 꼴로 넘긴 덮기: status · diff 가 드라이버 · 색인 훅을 실행하지 않음", ran().isEmpty,
                              ran().joined(separator: " "))
            } else {
                await t.check("옛 꼴로 넘긴 덮기: 만들기", false, listed.stdout)
            }

            // 앱 모델의 길 — 인계 지문 · 자동 작업 검토 자료 (앱의 자식 환경으로 돈다. 표식 경로는 명령에 박혀 있다).
            let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
            if (try? await store.bootstrap()) != nil {
                let model = AppModel(store: store)
                let project = await model.addProject(name: "repo", path: repository.path)
                let thread = await model.addThread(projectID: project.id, title: "git")
                let fingerprint = await model.handoffFingerprint(thread: thread, project: project)
                await t.check("인계 지문: git 상태를 재고 드라이버를 실행하지 않음", fingerprint.gitState != nil && ran().isEmpty,
                              "\(String(describing: fingerprint.gitState)) \(ran())")
                let evidence = await model.orchestrationWorkspaceEvidence(project: project)
                await t.check("자동 작업 검토 자료: diff 를 읽고 드라이버를 실행하지 않음",
                              evidence.text.contains("+after") && ran().isEmpty, ran().joined(separator: " "))
            } else {
                await t.check("드라이버 차단 · 임시 DB 준비", false)
            }

            // 사람이 고른 쓰기는 사람의(여기서는 저장소의) 필터 · 훅을 그대로 쓴다 — 커밋된 내용이 clean 필터를 거친 것이다.
            let stage = await GitWrite.perform(.stage(["sample.txt"]), git: git, at: repository, environment: environment)
            let commit = await GitWrite.perform(.commit(message: "change"), git: git, at: repository, environment: environment)
            let blob = await raw(["cat-file", "blob", "HEAD:sample.txt"])
            await t.check("사람이 고른 스테이지 · 커밋은 clean 필터 · 색인 훅을 그대로 거친다",
                          stage.succeeded && commit.succeeded && ran().contains("clean") && ran().contains("index")
                            && blob.stdout == "AFTER\n",
                          "\(stage.output) \(commit.output) \(ran()) \(blob.stdout)")
        } catch {
            await t.check("드라이버 차단 검증 준비", false, error.localizedDescription)
        }
    }

    /// git-lfs 는 저장소의 `.git/config` 에 적힌 확장(`lfs.extension.<이름>.clean`)도 읽어 돌린다 — 사용자의 전역 lfs 필터를 거쳐 저장소가
    /// 고른 명령이 돈다. 저장소 쪽에 확장이 있으면 앱의 읽기는 git-lfs 를 부르는 전역 필터도 끈다 (`GitInspector.driverOverrides`).
    /// git-lfs 대신 같은 이름의 가짜 실행 파일(표식만 남기고 내용을 그대로 낸다)로 본다.
    private static func lfsExtensionIsolation(_ t: TestKit) async {
        await t.group("Git 저장소의 git-lfs 확장 실행 차단")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ahc-gitlfs-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        do {
            let repository = root.appendingPathComponent("repo")
            try fm.createDirectory(at: repository, withIntermediateDirectories: true)
            let marker = root.appendingPathComponent("lfs-ran")
            let quoted = "'" + marker.path + "'"
            let fakeLFS = root.appendingPathComponent("git-lfs")
            try "#!/bin/sh\nprintf 'lfs\\n' >> \(quoted)\ncat\n".write(to: fakeLFS, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeLFS.path)
            // `git lfs install` 이 전역 설정에 적는 꼴 (믿는 범위).
            let global = root.appendingPathComponent("gitconfig")
            try "[filter \"lfs\"]\n\tclean = '\(fakeLFS.path)' clean -- %f\n\tsmudge = cat\n\trequired = true\n"
                .write(to: global, atomically: true, encoding: .utf8)
            let environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1",
                               "GIT_CONFIG_GLOBAL": global.path,
                               "GIT_AUTHOR_NAME": "Example", "GIT_AUTHOR_EMAIL": "example@example.invalid",
                               "GIT_COMMITTER_NAME": "Example", "GIT_COMMITTER_EMAIL": "example@example.invalid"]
            let git = "/usr/bin/git"
            func raw(_ arguments: [String]) async -> CLIEnvironment.ProcessCapture {
                await CLIEnvironment.captureProcess(executable: git, arguments: arguments, environment: environment,
                                                    workingDirectory: repository, timeout: 15)
            }
            func ran() -> [String] {
                ((try? String(contentsOf: marker, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            }
            let data = repository.appendingPathComponent("asset.dat")
            func touch() {
                try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: data.path)
            }
            _ = await raw(["init", "-q", "-b", "main"])
            try "*.dat filter=lfs\n".write(to: repository.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
            try "payload\n".write(to: data, atomically: true, encoding: .utf8)
            _ = await raw(["add", "-A"])
            let initial = await raw(["commit", "-q", "-m", "fixture"])
            await t.check("시험용 저장소 준비 (전역 lfs 필터)", initial.succeeded, initial.combinedOutput)
            try? fm.removeItem(at: marker)

            touch()
            let trustedStatus = await GitWorkspace.status(at: repository, environment: environment)
            await t.check("대조군: 저장소 쪽 확장이 없으면 전역 lfs 필터는 그대로 돈다 (바뀐 파일 없음)",
                          trustedStatus.error == nil && trustedStatus.unstaged.isEmpty && ran().contains("lfs"),
                          "\(trustedStatus.error ?? "") \(trustedStatus.unstaged.map { $0.path }) \(ran())")
            try? fm.removeItem(at: marker)

            _ = await raw(["config", "lfs.extension.probe.clean", "printf 'ext\\n' >> \(quoted); cat"])
            _ = await raw(["config", "lfs.extension.probe.priority", "0"])
            touch()
            let status = await GitWorkspace.status(at: repository, environment: environment)
            await t.check("저장소 쪽 git-lfs 확장이 있으면 git-lfs 를 부르는 전역 필터도 끈다 (git-lfs 가 돌지 않는다)",
                          status.error == nil && ran().isEmpty, "\(status.error ?? "") \(ran())")
            let snapshot = await GitInspector.snapshot(at: repository, environment: environment)
            await t.check("인계 스냅샷도 git-lfs 를 부르지 않는다", snapshot.error == nil && ran().isEmpty,
                          "\(snapshot.error ?? "") \(ran())")
        } catch {
            await t.check("git-lfs 확장 차단 검증 준비", false, error.localizedDescription)
        }
    }

    // MARK: 종료 코드

    /// 성공 여부는 종료 코드로만 판단한다. 2026-09-13 이전에는 stdout 이 있으면 성공으로 봐서,
    /// 훅이 stdout 에 쓰고 실패하거나 "커밋할 사항 없음"(stdout, 종료 코드 1) 이어도 커밋했다고 알렸다.
    static func exitCodes(_ t: TestKit) async {
        await t.group("Git 쓰기 종료 코드")
        let env = ProcessInfo.processInfo.environment
        let captured = await CLIEnvironment.captureProcess(
            executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"], environment: env, timeout: 10)
        await t.check("종료 코드 · stdout · stderr 를 따로 받음",
                      captured.exitStatus == 3 && captured.stdout == "out\n" && captured.stderr == "err\n"
                      && !captured.succeeded, "\(captured)")
        await t.equal("기록용 출력은 stdout 다음 stderr", captured.combinedOutput, "out\nerr")
        if case .success(let out) = await CLIEnvironment.captureOutput(
            executable: "/bin/sh", arguments: ["-c", "echo out; exit 3"], environment: env, timeout: 10) {
            await t.equal("다른 호출자가 쓰는 captureOutput 동작은 그대로", out, "out\n")
        } else {
            await t.check("다른 호출자가 쓰는 captureOutput 동작은 그대로", false)
        }

        // 작업 폴더를 주지 않은 명령은 앱의 작업 폴더(`/`)가 아니라 빈 전용 폴더에서 돈다 — `/` 에서 돈 Claude CLI 가 디스크를
        // 훑어, 앱을 켤 때마다 음악 · 사진 보관함 · 다운로드 · 네트워크 볼륨 권한 창이 앱 이름으로 떴다 (2026-09-24).
        let neutral = SessionImportScanner.normalizedPath(CLIEnvironment.neutralWorkingDirectory().path)
        if case .success(let pwd) = await CLIEnvironment.captureOutput(
            executable: "/bin/pwd", arguments: ["-P"], environment: env, timeout: 10) {
            await t.equal("작업 폴더를 주지 않으면 빈 전용 폴더에서",
                          SessionImportScanner.normalizedPath(pwd.trimmingCharacters(in: .whitespacesAndNewlines)), neutral)
        } else {
            await t.check("작업 폴더를 주지 않으면 빈 전용 폴더에서", false)
        }
        // `claude -p` 보조 명령은 대화 파일을 남기지 않게 부르고, 옵션을 모르는 옛 CLI 면 빼고 다시 부른다.
        let fakeDir = FileManager.default.temporaryDirectory.appendingPathComponent("ahc-fake-claude-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: fakeDir, withIntermediateDirectories: true)
        func fake(_ name: String, _ body: String) -> String {
            let url = fakeDir.appendingPathComponent(name)
            try? ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }
        let newCLI = fake("new", #"echo "args:$*""#)
        let oldCLI = fake("old", #"case "$*" in *--no-session-persistence*) echo "error: unknown option '--no-session-persistence'" >&2; exit 1;; esac; echo "args:$*""#)
        let fresh = await CLIEnvironment.captureClaudePrint(path: newCLI, command: "/usage", environment: env, timeout: 10)
        await t.check("보조 명령은 대화 파일을 남기지 않게 부른다", {
            if case .success(let out) = fresh { return out.contains("-p /usage --output-format json --no-session-persistence") }
            return false
        }(), "\(fresh)")
        let old = await CLIEnvironment.captureClaudePrint(path: oldCLI, command: "/model", environment: env, timeout: 10)
        await t.check("옵션을 모르는 옛 CLI 면 빼고 다시 부른다", {
            if case .success(let out) = old { return out.trimmingCharacters(in: .whitespacesAndNewlines) == "args:-p /model --output-format json" }
            return false
        }(), "\(old)")
        try? FileManager.default.removeItem(at: fakeDir)
        await t.check("전용 폴더는 사용자 임시 폴더 안 (기록 가져오기가 고르지 않는다)",
                      SessionImportScanner.isRecommended(path: neutral, exists: true, isGit: false,
                                                         sessionCount: 50, home: NSHomeDirectory()) == false, neutral)

        // 손자 프로세스가 stdout 을 쥐고 있어 종료 이벤트가 늦어도, 종료 코드는 지어낸 -1 이 아니라 실제 값이다.
        let lingering = await CLIEnvironment.captureProcess(
            executable: "/bin/sh", arguments: ["-c", "sleep 3 & echo ok; exit 0"], environment: env, timeout: 10)
        await t.check("종료 이벤트가 늦어도 실제 종료 코드로 판단 (훅이 띄운 자식 등)",
                      lingering.exitStatus == 0 && lingering.succeeded, "\(lingering)")
        // 파이프를 쥔 자식이 오래 살아도 2초 유예 뒤에 돌아온다 (예전에는 그 자식이 끝날 때까지 기다렸다).
        let holdStarted = Date()
        let holding = await CLIEnvironment.captureProcess(
            executable: "/bin/sh", arguments: ["-c", "sleep 20 & echo ok; exit 0"], environment: env, timeout: 30)
        let holdElapsed = Date().timeIntervalSince(holdStarted)
        await t.check("파이프를 쥔 자식을 기다리지 않는다 (2초 유예)",
                      holdElapsed < 8 && holding.exitStatus == 0 && holding.stdout.contains("ok"),
                      String(format: "%.1f초 · %@", holdElapsed, "\(holding)"))
        // 손자가 stdout 을 쥔 채 stderr 에 많이 써도 두 파이프를 함께 비워 막히지 않는다.
        let chatty = await CLIEnvironment.captureProcess(
            executable: "/bin/sh", arguments: ["-c", "(sleep 0.5; yes x | head -c 200000 >&2) & exit 0"],
            environment: env, timeout: 10)
        await t.check("stdout 을 기다리는 동안에도 stderr 를 비움 (20만 바이트)",
                      chatty.exitStatus == 0 && chatty.stderr.count == 200_000,
                      "exit \(String(describing: chatty.exitStatus)) · stderr \(chatty.stderr.count)")

        // 짧은 명령의 출력이 종료 처리와 겹쳐 사라지지 않는지 (ManagedProcess 읽기 · 종료 경합).
        // 고치기 전에는 600번 중 1~3번 출력이 비어, git 조회가 "변경 없음" 처럼 보일 수 있었다.
        let runs = 600
        var lost = 0
        await withTaskGroup(of: Bool.self) { group in
            var launched = 0
            func launch() {
                launched += 1
                group.addTask {
                    if case .success(let out) = await CLIEnvironment.captureOutput(
                        executable: "/usr/bin/printf", arguments: ["a\\0b\\0c"], environment: env, timeout: 10) {
                        return out == "a\0b\0c\n"
                    }
                    return false
                }
            }
            for _ in 0..<16 { launch() }
            for await ok in group {
                if !ok { lost += 1 }
                if launched < runs { launch() }
            }
        }
        await t.equal("짧은 명령 \(runs)번 동시 실행 — 출력 유실 없음", lost, 0)

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ahc-gitexit-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        guard let git = GitInspector.findGit(environment: env) else {
            await t.check("git 실행 파일", false, "찾지 못함")
            return
        }
        func sh(_ args: [String]) async {
            _ = await CLIEnvironment.captureOutput(executable: git, arguments: args, environment: env,
                                                   workingDirectory: work, timeout: 20)
        }
        await sh(["init", "-q", "-b", "main"])
        await sh(["config", "user.name", "t"])
        await sh(["config", "user.email", "t@example.com"])
        await sh(["config", "commit.gpgsign", "false"])
        try? "one\n".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = await GitWrite.perform(.stage(["a.txt"]), git: git, at: work, environment: env)
        _ = await GitWrite.perform(.commit(message: "기준"), git: git, at: work, environment: env)

        let nothing = await GitWrite.perform(.commit(message: "빈 커밋"), git: git, at: work, environment: env)
        await t.check("스테이지된 것 없이 커밋 → 실패 (git 은 stdout 에 쓰고 종료 코드 1)", !nothing.succeeded,
                      JSONUtil.truncate(nothing.output, max: 120))
        await t.equal("그 이유 한 줄", ChangesState.commitFailureSummary(nothing.output),
                      "커밋할 변경이 없습니다. 이미 커밋됐거나 선택이 바뀌었을 수 있습니다.")
        await t.equal("실제 출력(로케일 그대로)의 분류: 커밋할 것 없음",
                      GitFailure.classify(.commit(message: "빈 커밋"), output: nothing.output), .nothingToCommit)

        // 사용자의 전역 hooksPath 와 섞이지 않게 이 저장소의 훅 폴더를 지정한다.
        let hooks = work.appendingPathComponent(".git/hooks")
        try? fm.createDirectory(at: hooks, withIntermediateDirectories: true)
        await sh(["config", "core.hooksPath", hooks.path])
        let hook = hooks.appendingPathComponent("pre-commit")
        try? "#!/bin/sh\necho 'lint: 경고 2개'\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try? "two\n".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = await GitWrite.perform(.stage(["a.txt"]), git: git, at: work, environment: env)
        let hooked = await GitWrite.perform(.commit(message: "훅에 막힐 커밋"), git: git, at: work, environment: env)
        await t.check("훅이 stdout 에 쓰고 실패 → 커밋 실패", !hooked.succeeded && hooked.output.contains("경고 2개"),
                      JSONUtil.truncate(hooked.output, max: 120))
        await t.equal("훅 출력은 원문 그대로 한 줄", ChangesState.commitFailureSummary(hooked.output), "lint: 경고 2개")
        let after = await GitWorkspace.status(at: work, environment: env)
        await t.check("실패해도 스테이지(선택)는 그대로", after.staged.map(\.path) == ["a.txt"])
        await t.equal("실패해도 기록은 그대로", after.lastCommit?.subject, "기준")
    }

    // MARK: 인수 구성

    static func arguments(_ t: TestKit) async {
        await t.group("Git 쓰기 명령 구성")
        func args(_ operation: GitWrite.Operation) -> [String] {
            (try? GitWrite.arguments(for: operation)) ?? ["<오류>"]
        }
        await t.equal("스테이지", args(.stage(["a.swift", "b.swift"])), ["add", "--", "a.swift", "b.swift"])
        await t.equal("스테이지 해제 (워킹 트리 보존)", args(.unstage(["a.swift"])),
                      ["restore", "--staged", "--", "a.swift"])
        await t.equal("커밋 메시지는 stdin 으로", args(.commit(message: "제목\n\n본문")), ["commit", "-F", "-"])
        await t.equal("브랜치 만들기", args(.createBranch("feat/x")), ["switch", "-c", "feat/x"])
        await t.equal("브랜치 전환", args(.switchBranch("main")), ["switch", "main"])
        await t.equal("가져오기", args(.fetch), ["fetch", "--prune"])
        await t.equal("받기는 ff-only (병합 커밋을 앱이 만들지 않음)", args(.pull), ["pull", "--ff-only"])
        await t.equal("보내기", args(.push(branch: "main", setUpstream: false)), ["push"])
        await t.equal("추적 설정과 함께 보내기", args(.push(branch: "feat/x", setUpstream: true)),
                      ["push", "--set-upstream", "origin", "feat/x"])
        await t.check("push --force 는 제공하지 않음",
                      !args(.push(branch: "main", setUpstream: true)).contains { $0.contains("force") })
        await t.check("밖으로 나가는 명령만 확인 필요",
                      GitWrite.Operation.push(branch: "main", setUpstream: false).needsConfirmation
                      && GitWrite.Operation.pull.needsConfirmation
                      && !GitWrite.Operation.commit(message: "x").needsConfirmation
                      && !GitWrite.Operation.stage(["a"]).needsConfirmation)

        func rejects(_ operation: GitWrite.Operation) -> Bool {
            (try? GitWrite.arguments(for: operation)) == nil
        }
        await t.check("빈 커밋 메시지 거부", rejects(.commit(message: "   \n")))
        await t.check("빈 대상 목록 거부", rejects(.stage([])))
        for name in ["-x", "a b", "a..b", "a//b", "x.lock", "@", "a~1", "feat:x", ""] {
            await t.check("잘못된 브랜치 이름 거부: '\(name)'", rejects(.createBranch(name)))
        }
        await t.check("정상 브랜치 이름 허용", !rejects(.createBranch("feat/코드-1_a.b")))
        // 경로가 아주 많으면 stdin 으로 (chg-18) — 줄바꿈 · 큰따옴표로 시작하는 이름만 C 문자열로 감싼다.
        await t.equal("stdin 경로: 보통 이름은 그대로", GitWrite.pathspecLine("a b/c[1].txt"), "a b/c[1].txt")
        await t.equal("stdin 경로: 줄바꿈 · 큰따옴표는 C 문자열", GitWrite.pathspecLine("\"q\\x\n.txt"), #""\"q\\x\n.txt""#)
        let addArgs: [String]? = GitWrite.pathspecFileArguments(for: .stage(["a"]))
        let restoreArgs: [String]? = GitWrite.pathspecFileArguments(for: .unstage(["a"]))
        let commitArgs: [String]? = GitWrite.pathspecFileArguments(for: .commit(message: "m"))
        await t.equal("stdin 경로 인수: 넣기", addArgs, ["add", "--pathspec-from-file=-"])
        await t.equal("stdin 경로 인수: 빼기", restoreArgs, ["restore", "--staged", "--pathspec-from-file=-"])
        await t.check("stdin 경로 인수: 경로를 받는 명령만", commitArgs == nil)
        // 화면 이름은 단추와 같은 말 하나 (txt-4).
        let named: [GitWrite.Operation] = [.stage(["a"]), .unstage(["a"]), .fetch, .pull,
                                           .push(branch: "m", setUpstream: false), .push(branch: "m", setUpstream: true)]
        let names: [String] = named.map { $0.koreanName }
        let expectedNames: [String] = ["커밋에 포함", "커밋에서 빼기", "원격 상태 확인", "원격 변경 받기", "업로드", "브랜치 업로드"]
        await t.equal("동작 이름 (단추와 같은 말)", names, expectedNames)
        await t.check("진행 문구에 괄호가 겹치지 않는다",
                      !GitWrite.Operation.fetch.progressText.contains("(") && GitWrite.Operation.fetch.progressText.hasSuffix("중입니다"))
        await t.check("쓰기 환경은 자격 증명 프롬프트를 막음",
                      GitWrite.writeEnvironment([:])["GIT_TERMINAL_PROMPT"] == "0"
                      && GitWrite.writeEnvironment([:])["GIT_EDITOR"] == "true")
        let project = URL(fileURLWithPath: "/repo/app")
        let repoRoot = URL(fileURLWithPath: "/repo")
        await t.check("경로를 받는 명령(stage · unstage)은 저장소 루트에서 (경로가 루트 기준)",
                      GitWrite.workingDirectory(for: .stage(["app/a"]), project: project, repositoryRoot: repoRoot) == repoRoot
                      && GitWrite.workingDirectory(for: .unstage(["app/a"]), project: project, repositoryRoot: repoRoot)
                          == repoRoot
                      && GitWrite.workingDirectory(for: .commit(message: "m"), project: project, repositoryRoot: repoRoot)
                          == project
                      && GitWrite.workingDirectory(for: .stage(["a"]), project: project, repositoryRoot: nil) == project)
    }

    // MARK: 임시 저장소 실제 동작

    static func liveRepository(_ t: TestKit) async {
        await t.group("Git 쓰기 실제 동작")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ahc-gitwrite-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        let origin = root.appendingPathComponent("origin.git")
        let other = root.appendingPathComponent("other")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        guard let git = GitInspector.findGit(environment: env) else {
            await t.check("git 실행 파일", false, "찾지 못함")
            return
        }
        // 준비는 앱이 쓰지 않는 명령이라 직접 실행한다 (사용자 설정에 기대지 않도록 -c 로 지정).
        @discardableResult
        func sh(_ args: [String], in directory: URL) async -> String {
            let result = await CLIEnvironment.captureOutput(
                executable: git,
                arguments: ["-c", "user.name=t", "-c", "user.email=t@example.com",
                            "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args,
                environment: env, workingDirectory: directory, timeout: 30)
            if case .success(let out) = result { return out }
            return ""
        }
        func perform(_ operation: GitWrite.Operation, in directory: URL = work) async -> GitWrite.Outcome {
            // 앱과 같은 경로로 실행하되, 커밋 신원만 이 임시 저장소에 지정해 둔다.
            await GitWrite.perform(operation, git: git, at: directory, environment: env)
        }
        await sh(["init", "-q", "-b", "main"], in: work)
        await sh(["config", "user.name", "t"], in: work)
        await sh(["config", "user.email", "t@example.com"], in: work)
        await sh(["config", "commit.gpgsign", "false"], in: work)
        try? "one\n".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? "two\n".write(to: work.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        // 스테이지 → 상태 확인
        let staged = await perform(.stage(["a.txt"]))
        var status = await GitWorkspace.status(at: work, environment: env)
        await t.check("스테이지 성공", staged.succeeded, staged.output)
        await t.equal("스테이지 목록", status.staged.map(\.path), ["a.txt"])
        await t.equal("실행한 명령을 그대로 보고", staged.command, "git add -- a.txt")

        // 스테이지 해제 (워킹 트리의 파일은 그대로 남아야 한다)
        _ = await perform(.unstage(["a.txt"]))
        status = await GitWorkspace.status(at: work, environment: env)
        // 커밋이 없는 저장소에는 HEAD 가 없어 restore 가 실패한다. 앱은 rm --cached 로 같은 일을 한다.
        await t.check("커밋 없는 저장소에서도 스테이지 해제", status.staged.isEmpty
                      && fm.fileExists(atPath: work.appendingPathComponent("a.txt").path))

        // 커밋 — 여러 줄 메시지를 stdin 으로
        _ = await perform(.stage(["a.txt", "b.txt"]))
        let message = "첫 커밋\n\n본문 줄 1\n본문 줄 2"
        let committed = await perform(.commit(message: message))
        await t.check("커밋 성공", committed.succeeded, committed.output)
        let logged = await sh(["log", "-1", "--pretty=%B"], in: work).trimmingCharacters(in: .whitespacesAndNewlines)
        await t.equal("여러 줄 메시지가 그대로 들어감", logged, message)
        status = await GitWorkspace.status(at: work, environment: env)
        await t.check("커밋 뒤 작업 트리 깨끗", status.staged.isEmpty && status.unstaged.isEmpty)

        // 빈 메시지는 실행 자체를 막는다
        let empty = await perform(.commit(message: "  "))
        await t.check("빈 메시지는 실행하지 않음", !empty.succeeded && empty.output.contains("비어"))

        // 브랜치 만들기 · 전환
        _ = await perform(.createBranch("feat/x"))
        status = await GitWorkspace.status(at: work, environment: env)
        await t.equal("새 브랜치로 전환됨", status.branch, "feat/x")
        _ = await perform(.switchBranch("main"))
        status = await GitWorkspace.status(at: work, environment: env)
        await t.equal("브랜치 전환", status.branch, "main")

        // 원격 (로컬 bare 저장소) — 네트워크 없이 push · pull 을 실제로 확인
        await sh(["init", "--bare", "-q", "-b", "main", origin.path], in: root)
        await sh(["remote", "add", "origin", origin.path], in: work)
        let pushed = await perform(.push(branch: "main", setUpstream: true))
        await t.check("추적 설정과 함께 보내기 성공", pushed.succeeded, pushed.output)
        status = await GitWorkspace.status(at: work, environment: env)
        await t.equal("추적 브랜치 생김", status.upstream, "origin/main")

        // 다른 클론에서 커밋을 올리고, 이쪽에서 받아온다
        await sh(["clone", "-q", origin.path, other.path], in: root)
        await sh(["config", "user.name", "o"], in: other)
        await sh(["config", "user.email", "o@example.com"], in: other)
        await sh(["config", "commit.gpgsign", "false"], in: other)
        try? "three\n".write(to: other.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        await sh(["add", "c.txt"], in: other)
        await sh(["commit", "-q", "-m", "다른 클론 커밋"], in: other)
        await sh(["push", "-q"], in: other)

        let fetched = await perform(.fetch)
        status = await GitWorkspace.status(at: work, environment: env)
        await t.check("가져오기 성공", fetched.succeeded, fetched.output)
        await t.equal("뒤처짐 감지", status.behind, 1)
        let pulled = await perform(.pull)
        await t.check("받기 성공", pulled.succeeded, pulled.output)
        await t.check("git 이 준 종료 코드를 그대로", pulled.exitStatus == 0)
        await t.check("받은 파일이 생김", fm.fileExists(atPath: work.appendingPathComponent("c.txt").path))

        // 갈라지면 ff-only 가 실패해야 한다 (앱이 임의로 병합하지 않는다)
        try? "local\n".write(to: work.appendingPathComponent("d.txt"), atomically: true, encoding: .utf8)
        _ = await perform(.stage(["d.txt"]))
        _ = await perform(.commit(message: "로컬 커밋"))
        try? "remote\n".write(to: other.appendingPathComponent("e.txt"), atomically: true, encoding: .utf8)
        await sh(["add", "e.txt"], in: other)
        await sh(["commit", "-q", "-m", "원격 커밋"], in: other)
        await sh(["push", "-q"], in: other)
        _ = await perform(.fetch)
        let diverged = await perform(.pull)
        await t.check("갈라진 기록은 병합하지 않고 실패", !diverged.succeeded,
                      JSONUtil.truncate(diverged.output, max: 120))
        let stillLocal = await sh(["log", "-1", "--pretty=%s"], in: work)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        await t.equal("실패해도 로컬 기록은 그대로", stillLocal, "로컬 커밋")

        // 파일 이름은 글자 그대로 — `a[1].txt` 를 고르면 `a1.txt` 는 따라오지 않는다
        try? "g\n".write(to: work.appendingPathComponent("g[1].txt"), atomically: true, encoding: .utf8)
        try? "g\n".write(to: work.appendingPathComponent("g1.txt"), atomically: true, encoding: .utf8)
        _ = await perform(.stage(["g[1].txt"]))
        status = await GitWorkspace.status(at: work, environment: env)
        await t.equal("글자 그대로 스테이지 (glob 으로 풀지 않음)", status.staged.map(\.path), ["g[1].txt"])
        _ = await perform(.unstage(["g[1].txt"]))

        // 경로가 아주 많으면(전체 선택 · 새 파일 수천 개) 인수 대신 stdin 으로 넘긴다 — 인수 길이 한도에 걸리지 않게 (chg-18).
        let bulk = work.appendingPathComponent("bulk")
        try? fm.createDirectory(at: bulk, withIntermediateDirectories: true)
        var bulkPaths: [String] = []
        for i in 0..<(GitWrite.pathspecArgumentLimit + 20) {
            let name = i == 0 ? "\"quoted.txt" : (i == 1 ? "line\nbreak.txt" : (i == 2 ? "공백 이름 [1].txt" : "f\(i).txt"))
            try? "x\n".write(to: bulk.appendingPathComponent(name), atomically: true, encoding: .utf8)
            bulkPaths.append("bulk/" + name)
        }
        let bulkStaged = await perform(.stage(bulkPaths))
        status = await GitWorkspace.status(at: work, environment: env)
        let stagedBulk = Set(status.staged.map(\.path)).intersection(bulkPaths)
        await t.check("많은 경로는 stdin 으로 스테이지 (따옴표 · 줄바꿈 · 공백 이름 포함)",
                      bulkStaged.succeeded && stagedBulk.count == bulkPaths.count
                        && bulkStaged.command.contains("--pathspec-from-file=-") && bulkStaged.command.contains("(경로 \(bulkPaths.count)개)"),
                      "\(stagedBulk.count)/\(bulkPaths.count) " + bulkStaged.output)
        let bulkUnstaged = await perform(.unstage(bulkPaths))
        status = await GitWorkspace.status(at: work, environment: env)
        await t.check("많은 경로는 stdin 으로 스테이지 해제",
                      bulkUnstaged.succeeded && Set(status.staged.map(\.path)).intersection(bulkPaths).isEmpty,
                      bulkUnstaged.output)
        try? fm.removeItem(at: bulk)

        // 하위 폴더를 프로젝트로 연 경우: status 경로는 저장소 루트 기준이라 루트에서 실행해야 한다
        let sub = work.appendingPathComponent("sub/deep")
        try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try? "s\n".write(to: sub.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        let subStatus = await GitWorkspace.status(at: work.appendingPathComponent("sub"), environment: env)
        let subPath = subStatus.untracked.map(\.path).first { $0.hasSuffix("s.txt") } ?? ""
        await t.equal("하위 폴더에서도 status 경로는 루트 기준", subPath, "sub/deep/s.txt")
        let fromRoot = await perform(.stage([subPath]),
                                     in: GitWrite.workingDirectory(for: .stage([subPath]),
                                                                   project: work.appendingPathComponent("sub"),
                                                                   repositoryRoot: subStatus.rootPath.map {
                                                                       URL(fileURLWithPath: $0) }))
        await t.check("하위 폴더 프로젝트의 체크(stage)가 실제로 스테이지됨", fromRoot.succeeded, fromRoot.output)
    }
}

extension GitWriteTests {
    /// 앱 경로(`AppModel.runGit`)로 실행했을 때 기록과 안전 가드가 동작하는지.
    /// 에이전트 CLI 는 부르지 않는다 (git 만 쓴다).
    @MainActor
    static func throughAppModel(_ t: TestKit) async {
        await t.group("Git 쓰기 · 앱 경로")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ahc-gitapp-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        guard let git = GitInspector.findGit(environment: env) else { return }
        func sh(_ args: [String]) async {
            _ = await CLIEnvironment.captureOutput(
                executable: git,
                arguments: ["-c", "user.name=t", "-c", "user.email=t@example.com",
                            "-c", "commit.gpgsign=false"] + args,
                environment: env, workingDirectory: work, timeout: 30)
        }
        await sh(["init", "-q", "-b", "main"])
        await sh(["config", "user.name", "t"])
        await sh(["config", "user.email", "t@example.com"])
        await sh(["config", "commit.gpgsign", "false"])
        try? "hello\n".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
        guard (try? await store.bootstrap()) != nil else {
            await t.check("임시 DB 준비", false)
            return
        }
        let model = AppModel(store: store)
        let project = await model.addProject(name: "work", path: work.path)
        let thread = await model.addThread(projectID: project.id, title: "git")
        await model.openWorkspace(path: work.path)

        let staged = await model.runGit(.stage(["a.txt"]))
        await t.check("스테이지 실행", staged, model.banner?.text ?? "")
        let events = (try? await store.events(threadID: thread.id)) ?? []
        // 체크박스(커밋에 포함)는 누를 때마다 대화에 쌓이므로 남기지 않는다 — 기록은 커밋이 남긴다 (chg-18).
        await t.check("체크(스테이지)는 대화에 남기지 않음", !events.contains { $0.kind == .commandExecution }
                        && !GitWrite.Operation.stage(["a.txt"]).isRecordedInConversation
                        && GitWrite.Operation.commit(message: "m").isRecordedInConversation)
        await t.check("git 상태를 다시 읽음", model.workspace.git?.staged.map(\.path) == ["a.txt"])

        // 밖으로 나가는 명령은 확인 없이는 실행하지 않는다.
        let unconfirmed = await model.runGit(.push(branch: "main", setUpstream: true))
        await t.check("확인 없는 push 거부", !unconfirmed && model.banner?.isError == true
                        && model.banner?.text == "브랜치 업로드 전에 확인이 필요합니다.",
                      model.banner?.text ?? "")
        let beforeCount = ((try? await store.events(threadID: thread.id)) ?? [])
            .filter { $0.kind == .commandExecution }.count

        // 실패한 명령도 기록하고 배너로 알린다 (없는 브랜치로 전환).
        model.banner = nil
        let failed = await model.runGit(.switchBranch("없는브랜치"))
        let after = (try? await store.events(threadID: thread.id)) ?? []
        let failedRecord = after.last { $0.kind == .commandExecution }
        await t.check("실패한 명령도 기록", !failed
                      && after.filter { $0.kind == .commandExecution }.count == beforeCount + 1)
        await t.equal("실행한 git 명령을 대화에 남김", failedRecord?.title ?? "", "git switch 없는브랜치")
        await t.check("앱이 실행했다고 표시 (에이전트 아님)", failedRecord?.provider == nil)
        await t.check("실패는 배너로 알림 · 단추와 같은 동작 이름 (txt-4)", model.banner?.isError == true
                        && model.banner?.text.hasPrefix("전환하지 못했습니다:") == true,
                      JSONUtil.truncate(model.banner?.text ?? "", max: 80))
        await t.equal("실패 종료 코드는 git 이 준 값 그대로 (1 로 지어 넣지 않음)",
                      JSONUtil.int(JSONUtil.object(after.last { $0.kind == .commandExecution }?.payloadJSON ?? "")?[
                          "exitCode"]), 128)
        await t.check("쉬고 있으면 git 쓰기 잠금 없음", model.gitWriteLock == nil)

        // 변경사항 탭의 커밋: 실패는 배너 대신 화면 안에 (lastGitOutcome), 메시지 초안과 선택은 그대로.
        let hooks = work.appendingPathComponent(".git/hooks")
        try? fm.createDirectory(at: hooks, withIntermediateDirectories: true)
        await sh(["config", "core.hooksPath", hooks.path])
        let hook = hooks.appendingPathComponent("pre-commit")
        try? "#!/bin/sh\necho '검사 실패: 경고 2개'\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        model.banner = nil
        model.setCommitDraft("첫 커밋", forFolder: project.path)
        let blocked = await model.commitStaged(message: "첫 커밋")
        await t.check("훅 실패는 커밋 실패", !blocked)
        await t.check("화면 안에 보여줄 때는 실패 배너를 띄우지 않음", model.banner == nil, model.banner?.text ?? "")
        await t.check("실패 결과를 남김 (출력 보기)",
                      model.lastGitOutcome.map {
                          !$0.outcome.succeeded && $0.outcome.output.contains("경고 2개") && $0.projectPath == project.path
                      } ?? false)
        await t.equal("실패해도 메시지 초안은 그대로", model.commitDraft(forFolder: project.path), "첫 커밋")
        await t.check("실패해도 선택(스테이지)은 그대로", model.workspace.git?.staged.map(\.path) == ["a.txt"])

        try? fm.removeItem(at: hook)
        let committed = await model.commitStaged(message: "첫 커밋")
        await t.check("커밋 성공", committed, model.lastGitOutcome?.outcome.output ?? "")
        await t.equal("성공하면 초안을 비움", model.commitDraft(forFolder: project.path), "")
        let commitRecord = ((try? await store.events(threadID: thread.id)) ?? []).last { $0.kind == .commandExecution }
        await t.check("커밋은 대화에 남김 · 앱이 실행 · 성공 종료 코드", commitRecord?.title == "git commit -F -"
                        && commitRecord?.provider == nil
                        && JSONUtil.int(JSONUtil.object(commitRecord?.payloadJSON ?? "")?["exitCode"]) == 0,
                      commitRecord?.title ?? "")
        // 커밋 초안은 폴더마다 따로 — 같은 프로젝트의 독립 작업 폴더 칸에 들어가지 않는다 (chg-8).
        model.setCommitDraft("A 의 메시지", forFolder: project.path)
        model.setCommitDraft("B 의 메시지", forFolder: project.path + "-worktree")
        await t.check("커밋 초안은 폴더마다 따로", model.commitDraft(forFolder: project.path) == "A 의 메시지"
                        && model.commitDraft(forFolder: project.path + "-worktree") == "B 의 메시지")
        model.setCommitDraft("", forFolder: project.path)
        await t.check("앱이 만든 커밋이 HEAD → 커밋 완료 표시",
                      ChangesState.isJustCommitted(appCommitHash: model.appCommitHashes[project.path],
                                                   head: model.workspace.git?.lastCommit))
        await t.check("화면 안에 보여줄 때는 성공 배너도 띄우지 않음", model.banner == nil, model.banner?.text ?? "")

        // fetch 성공 → 마지막 원격 확인 시각, 업로드 성공 → "커밋 완료" 표시를 끝낸다.
        let origin = root.appendingPathComponent("origin.git")
        await sh(["init", "--bare", "-q", "-b", "main", origin.path])
        await sh(["remote", "add", "origin", origin.path])
        await model.workspace.refreshGit()
        await t.check("fetch 전에는 원격 확인 기록 없음", model.workspace.lastFetchAt == nil)
        let fetched = await model.runGit(.fetch)
        await t.check("fetch 성공 → 마지막 원격 확인 시각", fetched && model.workspace.lastFetchAt != nil)
        let pushed = await model.runGit(.push(branch: "main", setUpstream: true), confirmed: true)
        await t.check("업로드 성공 → 커밋 완료 표시 끝", pushed && model.appCommitHashes[project.path] == nil)
        await t.check("업로드 결과(stderr)도 기록에 남김",
                      model.lastGitOutcome?.outcome.output.contains("main -> main") == true,
                      JSONUtil.truncate(model.lastGitOutcome?.outcome.output ?? "", max: 160))
        await t.equal("업로드 뒤 동기화 상태", model.workspace.git.map { ChangesState.sync($0) },
                      .inSync(upstream: "origin/main"))

        // 원격에 닿지 못한 fetch 는 "원격 확인" 시각을 앞당기지 않는다 (FETCH_HEAD 가 비워지며 시각만 바뀐다).
        let checkedBefore = model.workspace.lastFetchAt
        await sh(["remote", "set-url", "origin", root.appendingPathComponent("없는-원격.git").path])
        model.banner = nil
        let offline = await model.runGit(.fetch)
        let checkedAfter = model.workspace.lastFetchAt
        await t.check("실패한 fetch 뒤 마지막 원격 확인 시각이 앞당겨지지 않음",
                      !offline && checkedBefore != nil && checkedAfter != nil && checkedAfter! <= checkedBefore!,
                      "\(String(describing: checkedBefore)) → \(String(describing: checkedAfter))")
        await sh(["remote", "set-url", "origin", origin.path])

        // 하위 폴더를 프로젝트로 연 경우에도 체크(stage)가 된다 (경로는 저장소 루트 기준, 루트에서 실행).
        let subDir = work.appendingPathComponent("sub")
        try? fm.createDirectory(at: subDir, withIntermediateDirectories: true)
        try? "s\n".write(to: subDir.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        let subProject = await model.addProject(name: "sub", path: subDir.path)
        _ = await model.addThread(projectID: subProject.id, title: "sub")
        await model.openWorkspace(path: subDir.path)
        // 스레드를 고르면 폴더 조회가 따로 시작된다 — 그 결과를 기다린다.
        for _ in 0..<100 where model.workspace.git?.untracked.isEmpty != false {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let subRow = model.workspace.git.map { ChangesState.rows(from: $0) }?.first { $0.path == "sub/s.txt" }
        var subStaged = false
        if let operation = subRow.flatMap({ ChangesState.toggleOperation(for: $0) }) {
            subStaged = await model.runGit(operation)
        }
        await t.check("하위 폴더 프로젝트: 체크하면 스테이지됨", subStaged
                      && model.workspace.git?.staged.map(\.path) == ["sub/s.txt"],
                      "\(String(describing: subRow)) · \(model.workspace.projectPath ?? "-") · "
                          + "\(model.selectedProject?.path ?? "-") · \(String(describing: model.workspace.git?.staged)) · "
                          + "\(model.lastGitOutcome?.outcome.command ?? "-") \(model.lastGitOutcome?.outcome.output ?? "")")
        await store.db.close()
    }
}

extension GitWriteTests {
    /// 실패 분류를 앱 경로(`AppModel.runGit`)와 **실제 git 출력**으로 확인한다 (지어낸 출력을 넣지 않는다).
    /// 원격이 앞선 업로드 거절 → 기록 분기, `pull --ff-only` 실패 → 기록 분기, 겹치는 로컬 변경 → 파일 이름,
    /// 신원 미설정, 로그인 실패(ssh 전송을 저장소 설정 `core.sshCommand` 로 대신한 스크립트 — 네트워크 없음),
    /// 병합 중 MERGE_MSG 초안 → 충돌 해결 → 앱의 커밋이 병합을 마무리 → 업로드.
    @MainActor
    static func failuresThroughAppModel(_ t: TestKit) async {
        await t.group("Git 실패 분류 · 실제 저장소")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ahc-gitfail-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        let other = root.appendingPathComponent("other")
        let origin = root.appendingPathComponent("origin.git")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        guard let git = GitInspector.findGit(environment: env) else { return }
        @discardableResult
        func sh(_ args: [String], in dir: URL) async -> String {
            let result = await CLIEnvironment.captureOutput(
                executable: git,
                arguments: ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
                            "-c", "init.defaultBranch=main"] + args,
                environment: env, workingDirectory: dir, timeout: 30)
            if case .success(let out) = result { return out }
            return ""
        }
        func write(_ text: String, _ name: String, in dir: URL) {
            try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func configure(_ dir: URL) async {
            await sh(["config", "user.name", "t"], in: dir)
            await sh(["config", "user.email", "t@example.com"], in: dir)
            await sh(["config", "commit.gpgsign", "false"], in: dir)
        }

        // 준비: origin 에 기준 커밋 → 다른 클론이 같은 파일을 고쳐 올림 → 이쪽도 같은 파일을 고쳐 커밋 (fetch 전)
        await sh(["init", "-q", "-b", "main"], in: work)
        await configure(work)
        write("base\n", "a.txt", in: work)
        await sh(["add", "a.txt"], in: work)
        await sh(["commit", "-q", "-m", "기준"], in: work)
        await sh(["init", "--bare", "-q", "-b", "main", origin.path], in: root)
        await sh(["remote", "add", "origin", origin.path], in: work)
        await sh(["push", "-q", "-u", "origin", "main"], in: work)
        await sh(["clone", "-q", origin.path, other.path], in: root)
        await configure(other)
        write("remote\n", "a.txt", in: other)
        await sh(["commit", "-q", "-am", "원격 수정"], in: other)
        await sh(["push", "-q"], in: other)
        write("local\n", "a.txt", in: work)
        await sh(["commit", "-q", "-am", "로컬 수정"], in: work)

        let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
        guard (try? await store.bootstrap()) != nil else {
            await t.check("임시 DB 준비", false)
            return
        }
        let model = AppModel(store: store)
        let project = await model.addProject(name: "work", path: work.path)
        _ = await model.addThread(projectID: project.id, title: "git")
        await model.openWorkspace(path: work.path)
        await t.equal("fetch 전에는 업로드 대기로 보임 (마지막 확인 기준)", model.workspace.git.map { ChangesState.sync($0) },
                      .ahead(upstream: "origin/main", count: 1))

        // 1) 업로드 거절 — 원격에 이 브랜치에 없는 커밋이 있다
        model.banner = nil
        let pushed = await model.runGit(.push(branch: "main", setUpstream: false), confirmed: true, reportsInline: true)
        let pushRecord = model.lastGitOutcome
        await t.check("업로드 실패 (git 종료 코드)", !pushed && pushRecord?.outcome.succeeded == false)
        await t.equal("업로드 거절 → 기록 분기 (실제 출력)", pushRecord?.failure, .diverged)
        await t.check("화면 안에 보여줄 때는 배너를 띄우지 않음", model.banner == nil, model.banner?.text ?? "")
        await t.check("실패 기록: 명령 뒤 상태(브랜치 · HEAD · 앞섬) · 원격 이름 · 주소",
                      pushRecord?.context?.branch == "main"
                      && pushRecord?.context?.head == model.workspace.git?.lastCommit?.hash
                      && pushRecord?.context?.ahead == 1
                      && pushRecord?.remoteName == "origin" && pushRecord?.remoteURL == origin.path,
                      "\(String(describing: pushRecord?.context)) \(String(describing: pushRecord?.remoteURL))")
        await t.check("실패 직후에는 그 실패가 지금 상태에 맞음",
                      model.workspace.git.map { ChangesState.failureIsCurrent(recorded: pushRecord?.context, now: $0) }
                          == true)

        // 1-1) 사용자가 터미널에서 fetch → 기록 분기가 드러난다 (HEAD · 브랜치는 그대로). 지난 실패 안내가 남아
        //      기록 분기 화면을 가리거나, 그 자리에서 업로드를 다시 권하면 안 된다.
        await sh(["fetch", "-q"], in: work)
        await model.workspace.refreshGit()
        if let now = model.workspace.git {
            await t.check("터미널 fetch 뒤: 앞선 업로드 실패는 지난 일 (앞섬/뒤처짐 · FETCH_HEAD 가 바뀜)",
                          ChangesState.sync(now) == .diverged(upstream: "origin/main", ahead: 1, behind: 1)
                          && !ChangesState.failureIsCurrent(recorded: pushRecord?.context, now: now),
                          "\(ChangesState.sync(now))")
            await t.check("기록 분기에서는 업로드 · 받기를 다시 권하지 않음 (원격 확인은 권함)",
                          !ChangesState.retryOffered(.push(branch: "main", setUpstream: false), sync: ChangesState.sync(now))
                          && !ChangesState.retryOffered(.pull, sync: ChangesState.sync(now))
                          && ChangesState.retryOffered(.fetch, sync: ChangesState.sync(now)))
        } else {
            await t.check("터미널 fetch 뒤 상태 읽기", false)
        }
        let pushText = pushRecord?.failure?.explanation(for: .push(branch: "main", setUpstream: false),
                                                        remoteName: pushRecord?.remoteName)
        await t.check("안내는 '원격 변경 받기' 가 아니라 합치기 (목업과 다르게 #1)",
                      pushText?.title == "업로드하지 못했습니다" && pushText?.detail.contains("받기") == false,
                      pushText?.detail ?? "")

        // 2) 원격 상태 확인 → 기록 분기 화면의 재료 (양쪽 커밋 목록)
        let fetched = await model.runGit(.fetch, reportsInline: true)
        let divergedGit = model.workspace.git
        await t.check("fetch 뒤 기록 분기 · 양쪽 커밋 목록",
                      fetched && divergedGit.map { ChangesState.sync($0) } == .diverged(upstream: "origin/main", ahead: 1, behind: 1)
                      && divergedGit?.outgoingCommits?.map(\.subject) == ["로컬 수정"]
                      && divergedGit?.incomingCommits?.map(\.subject) == ["원격 수정"],
                      "\(String(describing: divergedGit.map { ChangesState.sync($0) }))")
        await t.check("새 명령을 시작하면 앞선 실패 표시는 지워짐", model.lastGitOutcome?.outcome.succeeded == true)

        // 3) 받기 (--ff-only) 는 기록 분기에서 반드시 실패한다
        let pulled = await model.runGit(.pull, confirmed: true, reportsInline: true)
        await t.check("받기 실패 · 기록 분기로 분류", !pulled && model.lastGitOutcome?.failure == .diverged,
                      JSONUtil.truncate(model.lastGitOutcome?.outcome.output ?? "", max: 160))
        await t.check("받기 실패 뒤에도 로컬 기록은 그대로",
                      model.workspace.git?.lastCommit?.subject == "로컬 수정")

        // 4) 사용자가 터미널에서 합친다 (앱은 merge 를 하지 않는다) → 병합 중 · 충돌
        await sh(["merge", "--no-edit", "origin/main"], in: work)
        await model.workspace.refreshGit()
        guard let merging = model.workspace.git else {
            await t.check("병합 중 상태 읽기", false)
            await store.db.close()
            return
        }
        await t.check("병합 중 · 충돌 1개",
                      merging.isMerging && merging.conflicted.map(\.path) == ["a.txt"]
                      && ChangesState.sync(merging) == .merging(upstream: "origin/main"))
        // 병합 중에는 동기화 자리가 없다 → 원격 확인이 실패하면 화면 안에 보여달라고 해도 배너로 알린다.
        await sh(["remote", "set-url", "origin", root.appendingPathComponent("없는-원격.git").path], in: work)
        model.banner = nil
        let fetchWhileMerging = await model.runGit(.fetch, reportsInline: true)
        await t.check("병합 중 원격 확인 실패 → 보여줄 자리가 없어 배너로",
                      !fetchWhileMerging && model.banner?.isError == true
                      && !ChangesState.showsSyncFailureInline(model.workspace.git),
                      model.banner?.text ?? "배너 없음")
        await sh(["remote", "set-url", "origin", origin.path], in: work)
        model.banner = nil
        model.setCommitDraft("", forFolder: project.path)
        model.reconcileMergeDraft(folder: project.path, mergeHead: merging.mergeHead, mergeMessage: merging.mergeMessage)
        let adopted = model.commitDraft(forFolder: project.path)
        await t.check("빈 초안은 MERGE_MSG 로 채움 (주석 줄 없이)",
                      !adopted.isEmpty && adopted == merging.mergeMessage && !adopted.contains("#"), adopted)
        model.setCommitDraft("", forFolder: project.path)
        model.reconcileMergeDraft(folder: project.path, mergeHead: merging.mergeHead, mergeMessage: merging.mergeMessage)
        await t.equal("같은 병합에서 사용자가 지운 초안은 다시 채우지 않음", model.commitDraft(forFolder: project.path), "")
        model.setCommitDraft(adopted, forFolder: project.path)

        // 충돌이 남은 채 커밋하면 git 이 거부한다 → 분류 안 됨: git 의 error 줄 그대로
        let early = await model.commitStaged(message: adopted)
        let earlyFailure = model.lastGitOutcome?.failure
        var earlyLine = ""
        if case .unclassified(let line)? = earlyFailure { earlyLine = line }
        await t.check("충돌이 남은 커밋은 git 이 거부 · 이유는 git 의 한 줄 그대로",
                      !early && (earlyLine.lowercased().hasPrefix("error:") || earlyLine.lowercased().hasPrefix("fatal:")),
                      earlyLine)
        await t.equal("거부돼도 초안은 그대로", model.commitDraft(forFolder: project.path), adopted)

        // 파일을 정리하고 git add (터미널) → 앱의 커밋이 병합 커밋을 완성
        write("merged\n", "a.txt", in: work)
        await sh(["add", "a.txt"], in: work)
        await model.workspace.refreshGit()
        await t.check("충돌이 모두 풀린 병합 (MERGE_HEAD 는 남음)",
                      model.workspace.git?.isMerging == true && model.workspace.git?.conflicted.isEmpty == true)
        let finished = await model.commitStaged(message: adopted)
        let parents = await sh(["log", "-1", "--format=%P"], in: work).split(separator: " ").count
        await t.check("앱의 커밋이 병합을 마무리 (부모 2개 · MERGE_HEAD 사라짐)",
                      finished && parents == 2 && model.workspace.git?.isMerging == false,
                      model.lastGitOutcome?.outcome.output ?? "")
        await t.equal("성공하면 초안을 비움", model.commitDraft(forFolder: project.path), "")
        model.reconcileMergeDraft(folder: project.path, mergeHead: nil, mergeMessage: nil)
        await t.equal("병합이 끝난 뒤 초안을 다시 채우지 않음", model.commitDraft(forFolder: project.path), "")
        let uploaded = await model.runGit(.push(branch: "main", setUpstream: false), confirmed: true, reportsInline: true)
        await t.check("합친 다음 업로드 성공 → 원격과 같음", uploaded
                      && model.workspace.git.map { ChangesState.sync($0) } == .inSync(upstream: "origin/main"))

        // 병합이 끝났을 때 앱이 채운 초안이 그대로면 비운다 (터미널에서 --abort · 커밋한 경우)
        model.reconcileMergeDraft(folder: project.path, mergeHead: "가상-병합", mergeMessage: "Merge y")
        let filled = model.commitDraft(forFolder: project.path)
        model.reconcileMergeDraft(folder: project.path, mergeHead: nil, mergeMessage: nil)
        await t.check("병합이 끝나면 채운 그대로인 초안을 비움", filled == "Merge y" && model.commitDraft(forFolder: project.path).isEmpty)

        // 5) 겹치는 로컬 변경 — 받지 않고 파일 이름을 알려준다
        await sh(["pull", "-q", "--ff-only"], in: other)
        write("remote 3\n", "a.txt", in: other)
        await sh(["commit", "-q", "-am", "원격 수정 2"], in: other)
        await sh(["push", "-q"], in: other)
        _ = await model.runGit(.fetch, reportsInline: true)
        write("내 수정\n", "a.txt", in: work)
        await model.workspace.refreshGit()
        let overlapped = await model.runGit(.pull, confirmed: true, reportsInline: true)
        await t.equal("겹치는 로컬 변경 → 파일 이름 (실제 출력)",
                      overlapped ? nil : model.lastGitOutcome?.failure, .overlappingChanges(["a.txt"]))
        let overlapText = model.lastGitOutcome?.failure?.explanation(for: .pull)
        await t.check("안내: 받지 않았다는 사실 + 출력에 나온 파일", overlapText?.detail.contains("a.txt") == true
                      && overlapText?.title == "원격 변경을 받지 못했습니다", overlapText?.detail ?? "")
        await t.equal("받지 않았으니 내 파일은 그대로",
                      (try? String(contentsOf: work.appendingPathComponent("a.txt"), encoding: .utf8)) ?? "", "내 수정\n")
        // 커밋을 권하면 안 된다 — 뒤처진 채 커밋하면 기록이 갈라져 --ff-only 받기가 반드시 실패한다 (실제로 확인).
        await t.check("겹치는 변경 안내는 커밋을 권하지 않음",
                      overlapText.map { !$0.detail.contains("커밋하거나") && !$0.detail.contains("먼저 커밋") } == true,
                      overlapText?.detail ?? "")
        await sh(["commit", "-q", "-am", "겹치는 변경을 커밋"], in: work)
        await model.workspace.refreshGit()
        let afterCommit = await model.runGit(.pull, confirmed: true, reportsInline: true)
        await t.check("(근거) 겹치는 변경을 커밋한 뒤의 받기는 기록 분기로 실패",
                      !afterCommit && model.lastGitOutcome?.failure == .diverged,
                      JSONUtil.truncate(model.lastGitOutcome?.outcome.output ?? "", max: 160))
        await sh(["reset", "-q", "--hard", "HEAD~1"], in: work)
        await model.workspace.refreshGit()

        // 6) 신원 미설정 — 사용자 전역 설정을 가리고 저장소에서 자동 추정도 끈다 (user.useConfigOnly)
        let nameless = root.appendingPathComponent("nameless")
        try? fm.createDirectory(at: nameless, withIntermediateDirectories: true)
        await sh(["init", "-q", "-b", "main"], in: nameless)
        await sh(["config", "user.useConfigOnly", "true"], in: nameless)
        write("x\n", "x.txt", in: nameless)
        var bareEnv = env
        for key in ["GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "EMAIL"] {
            bareEnv[key] = nil
        }
        bareEnv["GIT_CONFIG_GLOBAL"] = "/dev/null"
        bareEnv["GIT_CONFIG_NOSYSTEM"] = "1"
        _ = await GitWrite.perform(.stage(["x.txt"]), git: git, at: nameless, environment: bareEnv)
        let anonymous = await GitWrite.perform(.commit(message: "첫 커밋"), git: git, at: nameless, environment: bareEnv)
        await t.equal("신원 미설정 → 분류 (실제 출력)",
                      anonymous.succeeded ? nil : GitFailure.classify(.commit(message: "첫 커밋"), output: anonymous.output),
                      .identityUnknown)

        // 7) 로그인 실패 — ssh 전송을 대신하는 스크립트(core.sshCommand)가 서버의 거절 문장을 쓴다. 네트워크를 쓰지 않는다.
        //    환경에 GIT_SSH_COMMAND 가 있으면 저장소 설정보다 먼저라 실제 ssh 로 나갈 수 있어 건너뛴다.
        guard env["GIT_SSH_COMMAND"] == nil else {
            await t.note("GIT_SSH_COMMAND 가 설정되어 있어 로그인 실패 확인을 건너뜀")
            await store.db.close()
            return
        }
        // 사용자 · 시스템 git 설정(예: url.<주소>.insteadOf 로 ssh 를 https 로 바꾸는 규칙)을 가린다 — 그대로 두면
        // 이 확인이 실제 github.com 으로 나갈 수 있다. 앱이 쓰는 환경은 이 프로세스의 환경에서 온다.
        let savedGlobal = ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"]
        let savedNoSystem = ProcessInfo.processInfo.environment["GIT_CONFIG_NOSYSTEM"]
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        defer {
            if let savedGlobal { setenv("GIT_CONFIG_GLOBAL", savedGlobal, 1) } else { unsetenv("GIT_CONFIG_GLOBAL") }
            if let savedNoSystem { setenv("GIT_CONFIG_NOSYSTEM", savedNoSystem, 1) } else { unsetenv("GIT_CONFIG_NOSYSTEM") }
        }
        let fakeSSH = root.appendingPathComponent("fake-ssh.sh")
        try? "#!/bin/sh\necho \"git@github.com: Permission denied (publickey).\" >&2\nexit 255\n"
            .write(to: fakeSSH, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH.path)
        for (name, url, gitHub) in [("gh", "git@github.com:ahc-test/none.git", true),
                                    ("etc", "git@git.example.invalid:ahc-test/none.git", false)] {
            let dir = root.appendingPathComponent("auth-\(name)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            await sh(["init", "-q", "-b", "main"], in: dir)
            await sh(["remote", "add", "origin", url], in: dir)
            await sh(["config", "core.sshCommand", fakeSSH.path], in: dir)
            let authProject = await model.addProject(name: "auth-\(name)", path: dir.path)
            _ = await model.addThread(projectID: authProject.id, title: "auth")
            await model.openWorkspace(path: dir.path)
            for _ in 0..<100 where model.workspace.projectPath != dir.path || model.workspace.git?.remotes == nil {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            model.banner = nil
            let ok = await model.runGit(.fetch, reportsInline: true)
            let record = model.lastGitOutcome
            let text = record?.failure?.explanation(for: .fetch, remoteName: record?.remoteName)
            await t.check("로그인 실패 (\(gitHub ? "GitHub" : "다른 원격")) → 분류 · 원격 주소는 저장소 설정에서",
                          !ok && record?.failure == .authentication(gitHub: gitHub) && record?.remoteURL == url,
                          "\(String(describing: record?.failure)) \(String(describing: record?.remoteURL))")
            await t.check("로그인 안내 문구 (\(gitHub ? "gh auth login" : "GitHub 라고 쓰지 않음"))",
                          gitHub ? (text?.title == "GitHub 로그인이 필요합니다" && text?.detail.contains("gh auth login") == true)
                                 : (text?.title == "원격 저장소 로그인이 필요합니다" && text?.detail.contains("GitHub") == false),
                          text?.detail ?? "")
        }

        // 7-1) 올리는 원격이 다른 경우 (origin 은 github.com, remote.pushDefault = fork 는 다른 곳) — 맨 git push 는
        //      fork 로 간다. 앱이 origin 을 보고 "GitHub 로그인" 이라고 쓰면 안 된다.
        let triangle = root.appendingPathComponent("auth-triangle")
        try? fm.createDirectory(at: triangle, withIntermediateDirectories: true)
        await sh(["init", "-q", "-b", "main"], in: triangle)
        await sh(["remote", "add", "origin", "git@github.com:ahc-test/none.git"], in: triangle)
        await sh(["remote", "add", "fork", "git@git.example.invalid:ahc-test/none.git"], in: triangle)
        await sh(["config", "remote.pushDefault", "fork"], in: triangle)
        await sh(["config", "core.sshCommand", fakeSSH.path], in: triangle)
        write("t\n", "t.txt", in: triangle)
        await sh(["add", "t.txt"], in: triangle)
        await sh(["commit", "-q", "-m", "첫 커밋"], in: triangle)
        let triangleProject = await model.addProject(name: "auth-triangle", path: triangle.path)
        _ = await model.addThread(projectID: triangleProject.id, title: "auth")
        await model.openWorkspace(path: triangle.path)
        for _ in 0..<100 where model.workspace.projectPath != triangle.path || model.workspace.git?.remotes == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let pushedTriangle = await model.runGit(.push(branch: "main", setUpstream: false), confirmed: true,
                                                reportsInline: true)
        let triangleRecord = model.lastGitOutcome
        await t.check("올리는 원격(remote.pushDefault)의 주소로 가림 → GitHub 라고 쓰지 않음",
                      !pushedTriangle && triangleRecord?.remoteName == "fork"
                      && triangleRecord?.remoteURL == "git@git.example.invalid:ahc-test/none.git"
                      && triangleRecord?.failure == .authentication(gitHub: false),
                      "\(String(describing: triangleRecord?.remoteName)) \(String(describing: triangleRecord?.failure)) "
                      + JSONUtil.truncate(triangleRecord?.outcome.output ?? "", max: 160))
        await store.db.close()
    }
}

extension GitWriteTests {
    /// 저장소가 아닌 폴더에서 "이 폴더에서 git 시작하기" (chg-23): git init 만 하고 파일 · 커밋은 건드리지 않는다. 명령은 대화에 남는다.
    @MainActor
    static func initThroughAppModel(_ t: TestKit) async {
        await t.group("Git 쓰기 · 이 폴더에서 git 시작하기")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ahc-gitinit-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let work = root.appendingPathComponent("notes")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        try? "메모\n".write(to: work.appendingPathComponent("memo.txt"), atomically: true, encoding: .utf8)
        let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
        guard (try? await store.bootstrap()) != nil else {
            await t.check("임시 DB 준비", false)
            return
        }
        let model = AppModel(store: store)
        let project = await model.addProject(name: "notes", path: work.path)
        let thread = await model.addThread(projectID: project.id, title: "메모")
        await model.openWorkspace(path: work.path)
        await t.check("처음에는 저장소가 아님", model.workspace.git?.isRepository == false)
        let started = await model.initializeRepository()
        let events = (try? await store.events(threadID: thread.id)) ?? []
        await t.check("git init → 저장소 · 파일은 그대로 · 커밋 없음", started && model.workspace.git?.isRepository == true
                        && model.workspace.git?.noCommitsYet == true
                        && (try? String(contentsOf: work.appendingPathComponent("memo.txt"), encoding: .utf8)) == "메모\n",
                      model.banner?.text ?? "")
        await t.check("명령은 대화에 남는다 (앱이 실행)",
                      events.contains { $0.kind == .commandExecution && $0.title == "git init" && $0.provider == nil })
        let again = await model.initializeRepository()
        await t.check("이미 저장소면 다시 하지 않는다", !again)
        await store.db.close()
    }
}
