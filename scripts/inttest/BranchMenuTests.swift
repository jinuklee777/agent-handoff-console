import Foundation

// MARK: - 변경사항 탭 3단계 (브랜치 메뉴 · 동기화 변형 · PR 행 · 메뉴 단축키)

extension WorkspaceTests {
    /// 브랜치 메뉴의 순수 판정 (`BranchMenu`): 섹션 구성 · 원격 접두어 떼기 · 찾기 일치와 강조 · 새 브랜치 행 ·
    /// 이름 검사 · 잠금 이유 · ↑↓ 강조 이동 · 실행 명령.
    static func branchMenuDecisions(_ t: TestKit) async {
        await t.group("브랜치 메뉴 판정")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func unix(_ secondsAgo: Int) -> String { "\(1_800_000_000 - secondsAgo)" }
        let day = 86_400

        // 목업 BranchMenu 와 같은 모양의 저장소 (목업 순서를 흉내 내지 않고 git 이 준 순서 그대로).
        var s = GitWorkspaceStatus()
        GitWorkspace.parseStatus("## feature/login...origin/feature/login [ahead 2]\0M  Moa/Auth/AuthViewModel.swift\0"
                                 + "MM Moa/Login/LoginView.swift\0A  Moa/Auth/AuthTransport.swift\0"
                                 + " D Moa/Auth/LegacyTokenStore.swift\0", into: &s)
        s.isRepository = true
        s.remotes = ["origin"]
        s.localBranches = GitWorkspace.parseBranches(   // for-each-ref --sort=-committerdate (최근 것부터)
            "feature/login\u{0}c6bac5a\u{0}*\u{0}origin/feature/login\u{0}[ahead 2]\u{0}\u{0}\(unix(600))\n"
                + "main\u{0}7057838\u{0} \u{0}origin/main\u{0}\u{0}\u{0}\(unix(2 * day))\n"
                + "fix/payment-retry\u{0}aaa1111\u{0} \u{0}origin/fix/payment-retry\u{0}[ahead 1]\u{0}\u{0}\(unix(3 * day))\n"
                + "feature/login-sso\u{0}bbb2222\u{0} \u{0}\u{0}\u{0}\u{0}\(unix(4 * day))\n")
        s.remoteBranches = GitWorkspace.parseRemoteBranches(
            "refs/remotes/origin/HEAD\u{0}abc\u{0}\u{0}\n"
                + "refs/remotes/origin/feature/login\u{0}c0ffee0\u{0}\u{0}\(unix(700))\n"
                + "refs/remotes/origin/feature/sso-callback\u{0}ccc3333\u{0}\u{0}\(unix(day))\n"
                + "refs/remotes/origin/main\u{0}7057838\u{0}\u{0}\(unix(2 * day))\n"
                + "refs/remotes/origin/fix/payment-retry\u{0}ddd\u{0}\u{0}\(unix(3 * day))\n"
                + "refs/remotes/origin/release/2.4\u{0}eee\u{0}\u{0}\(unix(5 * day))\n", remotes: ["origin"])
        s.remoteBranchesRead = true
        await t.equal("변경 파일 수 (옮겨질 파일)", s.changeCount, 4)

        let browse = BranchMenu.content(status: s, query: "", block: nil)
        await t.equal("섹션: 현재 · 최근 · 원격에만", browse.sections.map(\.title),
                      ["현재 브랜치", "최근 브랜치", "원격에만 있는 브랜치"])
        await t.equal("현재 브랜치 행 (체크 · 원격과의 차이)", browse.sections[safe: 0]?.items.map {
            "\($0.kind == .current) \($0.name) \(BranchMenu.meta($0, now: now))" } ?? [], ["true feature/login ↑2"])
        await t.equal("최근 브랜치 = 현재를 뺀 로컬 브랜치, git 이 준 최근 커밋 순",
                      browse.sections[safe: 1]?.items.map(\.name) ?? [], ["main", "fix/payment-retry", "feature/login-sso"])
        await t.equal("최근 브랜치 메타 (↑n · 상대 시각)",
                      browse.sections[safe: 1]?.items.map { BranchMenu.meta($0, now: now) } ?? [],
                      ["2일 전", "↑1 · 3일 전", "4일 전"])
        await t.equal("원격에만 있는 브랜치 = 추적 중 · 같은 이름 로컬을 뺀 원격 브랜치 (접두어를 뗀 이름)",
                      browse.sections[safe: 2]?.items.map(\.name) ?? [], ["feature/sso-callback", "release/2.4"])
        await t.equal("원격이 하나면 섹션 오른쪽에 그 이름", browse.sections[safe: 2]?.trailing, "origin")
        await t.check("원격 행은 전체 이름과 원격을 기억",
                      browse.sections[safe: 2]?.items.first.map {
                          $0.fullName == "origin/feature/sso-callback" && $0.kind == .remoteOnly(remote: "origin") } == true)
        await t.equal("고를 수 있는 행 (현재 브랜치 제외)", browse.selectableIDs,
                      ["local:main", "local:fix/payment-retry", "local:feature/login-sso",
                       "remote:origin/feature/sso-callback", "remote:origin/release/2.4"])
        await t.equal("처음 강조는 최근 브랜치 첫 행 (목업: main · ↵ 전환)", BranchMenu.defaultHighlight(browse), "local:main")
        let release = browse.sections[safe: 2]?.items.last
        await t.equal("원격에만 있는 브랜치 전환: 접두어를 뗀 이름으로 git switch",
                      release.flatMap(BranchMenu.operation(for:)), .switchBranch("release/2.4"))
        await t.equal("로컬 브랜치 전환", browse.sections[safe: 1]?.items.first.flatMap(BranchMenu.operation(for:)),
                      .switchBranch("main"))
        await t.check("현재 브랜치는 실행할 명령이 없음",
                      browse.sections[safe: 0]?.items.first.map { BranchMenu.operation(for: $0) == nil && !$0.isSelectable }
                          == true)
        await t.check("찾지 않을 때는 새 브랜치 행 없음 · 강조 없음 · 원격 목록 읽음",
                      browse.create == nil && browse.sections.allSatisfy { $0.items.allSatisfy { $0.highlight == nil } }
                      && !browse.remoteListUnknown && !browse.awaitingName)

        // 찾기 — 목업 BranchSearch ("sso")
        let search = BranchMenu.content(status: s, query: "sso", block: nil)
        await t.check("찾는 이름이 없으면 맨 위가 새 브랜치 행 (고를 수 있음)",
                      search.create.map { $0.name == "sso" && $0.kind == .create && $0.isSelectable } == true)
        await t.equal("새 브랜치 행 둘째 줄", BranchMenu.createDetail(from: s.headLabel, changeCount: s.changeCount),
                      "feature/login 에서 시작 · 변경 파일 4개 함께 이동")
        await t.equal("일치하는 브랜치: 로컬 먼저 · 원격 (각각 최근 순)", search.sections.map(\.title), ["일치하는 브랜치"])
        await t.equal("일치하는 브랜치 목록", search.sections.first?.items.map(\.id) ?? [],
                      ["local:feature/login-sso", "remote:origin/feature/sso-callback"])
        await t.equal("일치 수", search.sections.first?.trailing, "2")
        await t.equal("일치 부분 강조 (앞 · 일치 · 뒤)", search.sections.first?.items.map {
            $0.highlight.map { "\($0.before)[\($0.match)]\($0.after)" } ?? "-" } ?? [],
                      ["feature/login-[sso]", "feature/[sso]-callback"])
        await t.equal("찾는 중 처음 강조는 새 브랜치 행 (↵ 만들고 전환)", BranchMenu.defaultHighlight(search), "create")
        await t.equal("↵ 글자", BranchMenu.returnLabel(search.create), "만들고 전환")
        await t.equal("새 브랜치 명령", search.create.flatMap(BranchMenu.operation(for:)), .createBranch("sso"))
        let upper = BranchMenu.content(status: s, query: "  SSO ", block: nil)
        await t.check("대소문자 무시 일치 · 강조는 원래 글자 · 앞뒤 공백은 뺌",
                      upper.sections.first?.items.first?.highlight?.match == "sso" && upper.create?.name == "SSO")
        let exactLocal = BranchMenu.content(status: s, query: "main", block: nil)
        await t.check("로컬 브랜치와 정확히 같으면 새 브랜치 행 없음 · 그 행을 강조",
                      exactLocal.create == nil && BranchMenu.defaultHighlight(exactLocal) == "local:main")
        let exactRemote = BranchMenu.content(status: s, query: "release/2.4", block: nil)
        await t.check("원격에만 있는 브랜치의 짧은 이름과 같아도 새 브랜치 행 없음",
                      exactRemote.create == nil && BranchMenu.defaultHighlight(exactRemote) == "remote:origin/release/2.4")
        let exactCurrent = BranchMenu.content(status: s, query: "feature/login", block: nil)
        await t.check("지금 브랜치 이름을 그대로 치면 ↵ 로 다른 브랜치로 가지 않음 (강조 없음)",
                      exactCurrent.create == nil && BranchMenu.defaultHighlight(exactCurrent) == nil
                      && exactCurrent.sections.first?.items.map(\.id) == ["current", "local:feature/login-sso"],
                      "\(exactCurrent.sections.first?.items.map(\.id) ?? [])")
        let byFull = BranchMenu.content(status: s, query: "origin/release", block: nil)
        await t.check("원격 전체 이름으로 찾아도 일치 · 표시 이름에 걸친 부분을 강조",
                      byFull.sections.first?.items.map(\.id) == ["remote:origin/release/2.4"]
                      && byFull.sections.first?.items.first?.highlight
                          == BranchMenu.Highlight(before: "", match: "release", after: "/2.4"))
        await t.check("원격 이름에만 걸친 일치는 강조 없음 (일치는 함)",
                      BranchMenu.content(status: s, query: "origin/", block: nil).sections.first?.items
                          .filter { $0.fullName != nil }.allSatisfy { $0.highlight == nil } == true
                      && BranchMenu.highlight(name: "x", inFullName: "origin/x", query: "gin/") == nil
                      && BranchMenu.highlight(name: "rel/x", inFullName: "o/rel/x", query: "O/R")
                          == BranchMenu.Highlight(before: "", match: "r", after: "el/x"))
        let sameAsRemote = BranchMenu.content(status: s, query: "origin/main", block: nil)
        await t.check("원격 브랜치 전체 이름과 같은 새 이름은 막고 이유 (git 이 헷갈림)",
                      sameAsRemote.create.map { !$0.isSelectable && $0.disabledReason?.contains("origin/main") == true } == true
                      && BranchMenu.defaultHighlight(sameAsRemote) == nil)
        let spaced = BranchMenu.content(status: s, query: "login fix", block: nil)
        await t.equal("쓸 수 없는 이름은 새 브랜치 행을 막고 이유",
                      spaced.create?.disabledReason, "브랜치 이름으로 쓸 수 없습니다 — 공백을 쓸 수 없습니다.")
        await t.check("막힌 새 브랜치 행은 명령 없음", spaced.create.flatMap(BranchMenu.operation(for:)) == nil)
        await t.equal("찾는 결과가 없어도 새 브랜치 행만",
                      BranchMenu.content(status: s, query: "hotfix/crash", block: nil).selectableIDs, ["create"])
        // 대소문자만 다른 이름 — macOS 기본 파일 시스템에서는 같은 브랜치 파일이 된다 (git 이 두 이름을 섞음)
        let caseOnly = BranchMenu.content(status: s, query: "Main", block: nil)
        await t.check("대소문자만 다른 로컬 브랜치가 있으면 새 브랜치 행을 막고 이유 · 강조는 그 브랜치",
                      caseOnly.create.map { !$0.isSelectable
                          && $0.disabledReason == "대소문자만 다른 브랜치(main)가 있습니다. macOS 기본 파일 시스템에서는 같은 이름으로 다뤄집니다." }
                          == true
                      && BranchMenu.defaultHighlight(caseOnly) == "local:main",
                      "\(caseOnly.create?.disabledReason ?? "-") \(BranchMenu.defaultHighlight(caseOnly) ?? "-")")
        await t.check("원격에만 있는 브랜치 · 지금 브랜치와 대소문자만 달라도 막음 (지금 브랜치면 강조 없음)",
                      BranchMenu.content(status: s, query: "Release/2.4", block: nil).create?.isSelectable == false
                      && BranchMenu.defaultHighlight(BranchMenu.content(status: s, query: "Release/2.4", block: nil))
                          == "remote:origin/release/2.4"
                      && BranchMenu.content(status: s, query: "Feature/Login", block: nil).create?.isSelectable == false
                      && BranchMenu.defaultHighlight(BranchMenu.content(status: s, query: "Feature/Login", block: nil)) == nil)
        await t.check("대소문자 검사는 이름 검사 뒤 · 같은 이름(대소문자까지)은 행 자체가 없음",
                      BranchMenu.nameProblem("Main", existing: ["main"]) != nil
                      && BranchMenu.nameProblem("main2", existing: ["main"]) == nil
                      && BranchMenu.nameProblem("a b", existing: ["A B"]) == "브랜치 이름으로 쓸 수 없습니다 — 공백을 쓸 수 없습니다.")

        // 이름 검사: 쓸 수 있는지는 GitWrite.validateBranchName 과 같다
        let names = ["feat/코드-1_a.b", "-x", "a b", "a..b", "a//b", "x.lock", "@", "a~1", "feat:x", "/a", "a/", "a@{1}",
                     "a*", "a?b", "a[1]", "a\\b", String(repeating: "a", count: 201)]
        var agreement: [String] = []
        for name in names {
            let valid = (try? GitWrite.validateBranchName(name)) != nil
            if valid != (BranchMenu.nameProblem(name) == nil) { agreement.append(name) }
        }
        await t.check("이름 검사 결과는 명령을 만들 때의 검사(GitWrite)와 같음", agreement.isEmpty, "\(agreement)")
        await t.equal("규칙별 이유", ["-x", "x.lock", "a..b", "a~1", "a/"].map { BranchMenu.nameProblem($0) ?? "-" },
                      ["브랜치 이름으로 쓸 수 없습니다 — - 로 시작할 수 없습니다.",
                       "브랜치 이름으로 쓸 수 없습니다 — .lock 으로 끝날 수 없습니다.",
                       "브랜치 이름으로 쓸 수 없습니다 — .. 을 쓸 수 없습니다.",
                       "브랜치 이름으로 쓸 수 없습니다 — ~ ^ : ? * [ \\ 는 쓸 수 없습니다.",
                       "브랜치 이름으로 쓸 수 없습니다 — / 로 시작하거나 끝날 수 없습니다."])

        // 잠금: 에이전트 실행 중 · 병합 · rebase · 충돌 — 목록은 보이고 전환 · 만들기만 막는다
        let agent = BranchMenu.block(lock: .agentRunning(.claude, here: true), merging: true, rebasing: false, conflicts: 1)
        await t.equal("잠금이 먼저 (병합보다)", agent, .locked(.agentRunning(.claude, here: true)))
        await t.equal("잠금 이유 문구", agent.map(BranchMenu.blockText), "Claude 실행이 끝나면 전환할 수 있습니다.")
        let locked = BranchMenu.content(status: s, query: "", block: agent)
        await t.check("잠기면 목록은 그대로 · 전환 행은 모두 막힘 · 강조 없음",
                      locked.sections.map(\.title) == browse.sections.map(\.title) && locked.selectableIDs.isEmpty
                      && BranchMenu.defaultHighlight(locked) == nil
                      && locked.sections[1].items.allSatisfy { $0.disabledReason == "Claude 실행이 끝나면 전환할 수 있습니다." })
        let lockedSearch = BranchMenu.content(status: s, query: "sso", block: agent)
        await t.check("잠기면 새 브랜치 행도 막힘 (이름 검사보다 잠금 이유)",
                      lockedSearch.create?.disabledReason == "Claude 실행이 끝나면 전환할 수 있습니다.")
        await t.check("잠금 없음 · rebase · 병합 · 충돌 순서",
                      BranchMenu.block(lock: nil, merging: false, rebasing: false, conflicts: 0) == nil
                      && BranchMenu.block(lock: nil, merging: true, rebasing: true, conflicts: 2) == .rebasing
                      && BranchMenu.block(lock: nil, merging: true, rebasing: false, conflicts: 2) == .merging
                      && BranchMenu.block(lock: nil, merging: false, rebasing: false, conflicts: 2) == .conflicts(2))
        await t.equal("병합 · rebase · 충돌 이유 (git 이 거부하는 사실)",
                      [BranchMenu.Block.merging, .rebasing, .conflicts(2)].map(BranchMenu.blockText),
                      ["병합이 진행 중이라 git 이 브랜치를 바꾸지 않습니다. 병합을 마무리하거나 멈춘 뒤 전환하세요.",
                       "rebase 가 진행 중이라 git 이 브랜치를 바꾸지 않습니다. 터미널에서 rebase 를 마친 뒤 전환하세요.",
                       "충돌 파일 2개가 남아 있어 git 이 다른 브랜치로 전환하지 않습니다. 충돌을 해결한 뒤 전환하세요. "
                           + "새 브랜치는 만들 수 있습니다 (충돌 파일도 함께 옮겨집니다)."])
        // 충돌 파일만 남은 상태(stash pop 충돌 등, 병합 아님): git 은 다른 브랜치로의 전환만 거부하고 만들기는 허용한다
        let conflictOnly = BranchMenu.content(status: s, query: "rescue", block: .conflicts(1))
        await t.check("충돌만 남으면 전환 행은 막고 새 브랜치 행은 열어 둠 (git 이 허용하는 만큼만)",
                      conflictOnly.create?.isSelectable == true && BranchMenu.defaultHighlight(conflictOnly) == "create"
                      && BranchMenu.content(status: s, query: "", block: .conflicts(1)).selectableIDs.isEmpty
                      && !BranchMenu.Block.conflicts(1).blocksCreate && BranchMenu.Block.merging.blocksCreate
                      && BranchMenu.Block.rebasing.blocksCreate
                      && BranchMenu.Block.locked(.gitRunning).blocksCreate)
        await t.check("병합 중에는 새 브랜치 행도 막음",
                      BranchMenu.content(status: s, query: "rescue", block: .merging).create?.isSelectable == false)
        await t.equal("다른 폴더의 에이전트 · 미종료 프로세스 · git 실행 중 · 스레드 없음",
                      [ChangesState.Lock.agentRunning(.codex, here: false), .unterminatedProcesses, .gitRunning, .noThread]
                        .map { BranchMenu.blockText(.locked($0)) },
                      ["Codex 가 다른 폴더에서 실행 중입니다. 끝나면 전환할 수 있습니다.",
                       "종료가 확인되지 않은 프로세스가 있어 전환할 수 없습니다.",
                       "git 명령을 실행하는 중입니다. 끝나면 전환할 수 있습니다.",
                       "대화를 선택해야 실행 기록을 남길 수 있어 지금은 전환할 수 없습니다."])

        // 독립 작업 폴더의 대화 (chg-16): 그 대화의 브랜치에서만 일한다 — 전환 · 만들기를 모두 막고 까닭을 적는다.
        let inWorktree = BranchMenu.block(lock: .agentRunning(.claude, here: true), merging: false, rebasing: false,
                                          conflicts: 0, worktreeBranch: "ahc/1234abcd")
        await t.equal("독립 작업 폴더가 잠금보다 먼저", inWorktree, .worktreeConversation(branch: "ahc/1234abcd"))
        let worktreeBrowse = BranchMenu.content(status: s, query: "", block: inWorktree)
        let worktreeSearch = BranchMenu.content(status: s, query: "rescue", block: inWorktree)
        let worktreeReason: String = inWorktree.map { (block: BranchMenu.Block) -> String in BranchMenu.blockText(block) } ?? ""
        await t.check("독립 작업 폴더: 전환 · 새 브랜치 모두 막음", worktreeBrowse.selectableIDs.isEmpty
                        && worktreeSearch.create?.isSelectable == false)
        await t.check("독립 작업 폴더: 합치는 곳을 알림 · 옮길 파일 안내 없음", worktreeReason.contains("ahc/1234abcd")
                        && BranchMenu.carryNote(changeCount: 3, block: inWorktree) == nil)
        // 다른 worktree 가 쓰는 브랜치 행은 잠근다 — git 이 전환하지 않는다.
        var withWorktree = s
        withWorktree.worktreeBranches = ["feature/login-sso": "/wt/app/abcd1234"]
        let worktreeLocked = BranchMenu.content(status: withWorktree, query: "", block: nil)
        let developRow = worktreeLocked.sections.flatMap(\.items).first { $0.name == "feature/login-sso" }
        await t.check("다른 worktree 가 쓰는 로컬 브랜치 행은 잠금 · 까닭에 그 폴더",
                      developRow?.disabledReason?.contains("/wt/app/abcd1234") == true && developRow?.isSelectable == false,
                      developRow?.disabledReason ?? "행 없음")

        // 새 이름 입력 상태 (새 브랜치 만들기… · ⌘⇧N)
        let creating = BranchMenu.content(status: s, query: "", mode: .create, block: nil)
        await t.check("새 이름 입력: 치기 전에는 목록 대신 안내", creating.awaitingName && creating.sections.isEmpty
                      && creating.create == nil && BranchMenu.defaultHighlight(creating) == nil)
        await t.check("새 이름 입력: 치면 찾기와 같음",
                      BranchMenu.content(status: s, query: "sso", mode: .create, block: nil) == search)
        await t.equal("새 이름 입력 안내: 병합 · rebase 중이면 옮길 것을 말하지 않음 (에이전트 잠금 · 충돌만이면 그대로)",
                      [nil, .locked(.agentRunning(.claude, here: true)), .conflicts(1), .merging, .rebasing]
                        .map { BranchMenu.awaitingDetail(from: "feature/login", changeCount: 4, block: $0) },
                      ["feature/login 에서 시작 · 변경 파일 4개 함께 이동", "feature/login 에서 시작 · 변경 파일 4개 함께 이동",
                       "feature/login 에서 시작 · 변경 파일 4개 함께 이동", "feature/login 에서 시작", "feature/login 에서 시작"])
        await t.check("새 이름 입력: 치기 전 · 잠긴 동안에는 ↵ 가 할 일이 없음 (키 안내에 ↵ 없음)",
                      BranchMenu.returnLabel(creating.item(id: BranchMenu.defaultHighlight(creating))) == nil
                      && BranchMenu.returnLabel(lockedSearch.item(id: "create")) == nil
                      && creating.selectableIDs.isEmpty)

        // ↑↓ 강조 이동 — 막힌 행은 목록에 없으므로 건너뛴다. 끝에서는 멈춘다.
        let ids = ["a", "b", "c"]
        await t.equal("↓ · ↑ · 끝에서 멈춤 · 모르는 강조",
                      [BranchMenu.moveHighlight(nil, by: 1, in: ids), BranchMenu.moveHighlight(nil, by: -1, in: ids),
                       BranchMenu.moveHighlight("a", by: 1, in: ids), BranchMenu.moveHighlight("c", by: 1, in: ids),
                       BranchMenu.moveHighlight("a", by: -1, in: ids), BranchMenu.moveHighlight("z", by: 1, in: ids),
                       BranchMenu.moveHighlight("a", by: 1, in: [])],
                      ["a", "c", "b", "c", "a", "a", nil])
        let blockedRow = BranchMenu.content(status: s, query: "login", block: nil)
        await t.check("↓ 는 막힌 행(지금 브랜치)을 건너뜀",
                      BranchMenu.moveHighlight("create", by: 1, in: blockedRow.selectableIDs) == "local:feature/login-sso",
                      "\(blockedRow.selectableIDs)")
        await t.check("목록이 바뀌면 강조 유지 · 없어졌으면 기본값",
                      BranchMenu.reconcileHighlight("local:fix/payment-retry", in: browse) == "local:fix/payment-retry"
                      && BranchMenu.reconcileHighlight("local:gone", in: browse) == "local:main"
                      && BranchMenu.reconcileHighlight(nil, in: locked) == nil)
        // 전환이 도는 동안(git 실행 중 잠금) 막힌 행도 강조를 지키고, 실패해 풀리면 같은 행 — ↵ 가 찾던 글자로 새 브랜치를 만들지 않게
        let typed = BranchMenu.content(status: s, query: "log", block: nil)
        let running = BranchMenu.content(status: s, query: "log", block: .locked(.gitRunning))
        let duringRun = BranchMenu.reconcileHighlight("local:feature/login-sso", in: running)
        let afterRun = BranchMenu.reconcileHighlight(duringRun, in: typed)
        await t.check("잠금 → 풀림: 강조는 누른 행 그대로 (기본값 '새 브랜치' 로 튀지 않음)",
                      BranchMenu.defaultHighlight(typed) == "create" && duringRun == "local:feature/login-sso"
                      && afterRun == "local:feature/login-sso"
                      && BranchMenu.returnLabel(running.item(id: duringRun)) == nil
                      && BranchMenu.returnLabel(typed.item(id: afterRun)) == "전환",
                      "\(duringRun ?? "-") → \(afterRun ?? "-")")

        // 떼어진 HEAD · 여러 원격 · 원격 목록을 못 읽음
        var detached = s
        detached.branch = nil
        detached.detachedHash = "a41c9e2"
        let detachedMenu = BranchMenu.content(status: detached, query: "", block: nil)
        await t.check("떼어진 HEAD: 현재 자리에 HEAD a41c9e2 (실행할 것 없음) · 로컬 브랜치는 모두 최근 목록에",
                      detachedMenu.sections.first?.items.first.map { $0.kind == .detached && $0.name == "HEAD a41c9e2" } == true
                      && detachedMenu.sections[safe: 1]?.items.count == 4)
        await t.equal("떼어진 HEAD 에서 새 브랜치", BranchMenu.createDetail(from: detached.headLabel, changeCount: 0),
                      "HEAD a41c9e2 에서 시작")
        var twoRemotes = s
        twoRemotes.remotes = ["origin", "team"]
        twoRemotes.remoteBranches += GitWorkspace.parseRemoteBranches("refs/remotes/team/hotfix\u{0}fff\u{0}\u{0}\(unix(600))\n",
                                                                      remotes: ["origin", "team"])
        let twoMenu = BranchMenu.content(status: twoRemotes, query: "", block: nil)
        await t.check("원격이 둘이면 섹션 오른쪽 이름 없음 · 행마다 원격",
                      twoMenu.sections.last?.trailing == nil && twoMenu.multipleRemotes
                      && twoMenu.sections.last?.items.last?.kind == .remoteOnly(remote: "team"))
        await t.equal("행 오른쪽 원격 표시: 여러 원격이면 행마다 · 한 원격이면 섹션 제목에만 · 찾는 중이면 태그",
                      [BranchMenu.remoteLabel(twoMenu.sections.last!.items.last!, searching: false, multipleRemotes: true),
                       BranchMenu.remoteLabel(twoMenu.sections.last!.items.first!, searching: false, multipleRemotes: true),
                       BranchMenu.remoteLabel(browse.sections[2].items[0], searching: false, multipleRemotes: false),
                       BranchMenu.remoteLabel(browse.sections[2].items[0], searching: true, multipleRemotes: false),
                       BranchMenu.remoteLabel(twoMenu.sections.last!.items.last!, searching: true, multipleRemotes: true),
                       BranchMenu.remoteLabel(browse.sections[1].items[0], searching: true, multipleRemotes: true)],
                      ["team", "origin", nil, "원격", "원격 · team", nil])
        // 같은 짧은 이름이 두 원격에: git 은 거부하거나(checkout.defaultRemote 가 있으면) 그 원격을 따라간다 → 행을 잠금
        var sameName = twoRemotes
        sameName.remoteBranches += GitWorkspace.parseRemoteBranches("refs/remotes/team/release/2.4\u{0}f0f\u{0}\u{0}\(unix(900))\n",
                                                                    remotes: ["origin", "team"])
        let sameMenu = BranchMenu.content(status: sameName, query: "release", block: nil)
        let sameRows = sameMenu.sections.first?.items.filter { $0.name == "release/2.4" } ?? []
        await t.check("같은 이름이 여러 원격에 있으면 그 행들은 막고 이유 (터미널의 --track 안내) · 새 브랜치 행 없음",
                      sameRows.count == 2 && sameRows.allSatisfy { !$0.isSelectable && BranchMenu.operation(for: $0) == nil }
                      && sameRows.first?.disabledReason == "같은 이름(release/2.4)의 브랜치가 origin · team 에 있어 앱에서 전환하지 않습니다 "
                          + "(git 이 거부하거나 설정에 따라 다른 원격을 따라갑니다). "
                          + "터미널에서 골라 전환하세요: git switch --track origin/release/2.4"
                      && BranchMenu.content(status: sameName, query: "release/2.4", block: nil).create == nil
                      && BranchMenu.content(status: sameName, query: "", block: nil).item(id: "remote:team/hotfix")?.isSelectable
                          == true,
                      "\(sameRows.map { $0.disabledReason ?? "-" })")
        await t.check("잠금 이유가 먼저 (에이전트 실행 중)",
                      BranchMenu.content(status: sameName, query: "release", block: agent).sections.first?.items
                          .first { $0.name == "release/2.4" }?.disabledReason == "Claude 실행이 끝나면 전환할 수 있습니다.")

        // 원격 브랜치가 아주 많아도 섹션마다 일부만 그린다 (팝오버가 가볍게 열리게) — 나머지는 개수만
        var many = s
        many.remoteBranches = GitWorkspace.parseRemoteBranches((0..<3000).map {
            "refs/remotes/origin/bulk/b\($0)\u{0}h\u{0}\u{0}\(unix($0 * 60))\n" }.joined()
            + "refs/remotes/origin/bulk\u{0}h\u{0}\u{0}\(unix(400 * day))\n", remotes: ["origin"])
        let manyMenu = BranchMenu.content(status: many, query: "", block: nil)
        let manyRemote = manyMenu.sections.first { $0.kind == .remoteOnly }
        await t.check("목록: 원격에만 있는 브랜치 50개 (최근 순) + '2951개 더 · 찾기로 좁히세요'",
                      manyRemote?.items.count == BranchMenu.listLimit && manyRemote?.items.first?.name == "bulk/b0"
                      && manyRemote?.hidden == 2951 && manyRemote?.moreText == "2951개 더 · 찾기로 좁히세요"
                      && manyMenu.sections.first { $0.kind == .recent }?.moreText == nil,
                      "\(manyRemote?.items.count ?? -1) \(manyRemote?.moreText ?? "-")")
        let manySearch = BranchMenu.content(status: many, query: "b1", block: nil)
        await t.check("찾기: 100개까지 · 일치 수는 전부 · 나머지는 '더 입력해 좁히세요'",
                      manySearch.sections.first?.items.count == BranchMenu.matchLimit
                      && manySearch.sections.first?.trailing == "1111"
                      && manySearch.sections.first?.moreText == "1011개 더 · 이름을 더 입력해 좁히세요",
                      "\(manySearch.sections.first?.trailing ?? "-") \(manySearch.sections.first?.moreText ?? "-")")
        let exactFar = BranchMenu.content(status: many, query: "bulk", block: nil)
        await t.check("정확히 같은 행은 100개 밖이어도 남기고 강조 (↵ 가 그 행)",
                      exactFar.sections.first?.items.count == BranchMenu.matchLimit
                      && exactFar.sections.first?.items.contains { $0.id == "remote:origin/bulk" } == true
                      && BranchMenu.defaultHighlight(exactFar) == "remote:origin/bulk" && exactFar.create == nil)
        let fewMatches = BranchMenu.content(status: many, query: "BULK/B299", block: nil)
        await t.check("짧은 결과는 자르지 않음 · 대소문자만 다른 이름은 그 행을 강조",
                      fewMatches.sections.first?.items.count == 11 && fewMatches.sections.first?.hidden == 0
                      && BranchMenu.defaultHighlight(fewMatches) == "remote:origin/bulk/b299"
                      && fewMatches.create?.isSelectable == false)
        var unread = s
        unread.remoteBranches = []
        unread.remoteBranchesRead = false
        await t.check("원격 브랜치 목록을 못 읽었으면 '없다' 가 아니라 미확인 (원격이 없는 저장소는 아님)",
                      BranchMenu.content(status: unread, query: "", block: nil).remoteListUnknown
                      && { var none = unread; none.remotes = []; return !BranchMenu.content(status: none, query: "", block: nil)
                          .remoteListUnknown }())

        // 바닥 안내
        await t.equal("옮겨질 변경 안내 (git switch 의 실제 동작)", BranchMenu.carryNote(changeCount: 4),
                      "변경 파일 4개는 전환한 브랜치로 함께 옮겨집니다. 겹치는 파일이 있으면 전환하지 않고 알려드립니다.")
        await t.check("변경 파일이 없으면 그 줄을 숨김", BranchMenu.carryNote(changeCount: 0) == nil)
        await t.check("병합 · rebase · 충돌로 git 이 전환을 거부하는 동안에는 옮겨질 변경 안내를 숨김 (에이전트 잠금은 그대로)",
                      BranchMenu.carryNote(changeCount: 3, block: .merging) == nil
                      && BranchMenu.carryNote(changeCount: 3, block: .rebasing) == nil
                      && BranchMenu.carryNote(changeCount: 3, block: .conflicts(1)) == nil
                      && BranchMenu.carryNote(changeCount: 3, block: .locked(.agentRunning(.claude, here: true))) != nil)
        // 독립 작업 폴더의 합치기 · 정리는 앱이 한다 — 그것과 어긋나지 않게 범위를 밝힌다 (txt-5).
        await t.equal("앱이 하지 않는 일 (독립 작업 폴더의 합치기 · 정리는 예외)", BranchMenu.notByApp,
                      "다른 브랜치 합치기 · 되돌리기 · 강제 업로드 · 브랜치 삭제는 앱이 하지 않습니다 "
                        + "(독립 작업 폴더의 합치기 · 정리만 앱이 합니다). 터미널에서 직접 하세요.")
        await t.check("↵ 글자: 전환 · 강조 없음이면 없음",
                      BranchMenu.returnLabel(browse.item(id: "local:main")) == "전환" && BranchMenu.returnLabel(nil) == nil)
        await t.check("원격에만 있는 브랜치 도움말은 git 이 하는 일 (추적 브랜치를 만듦)",
                      release.map { BranchMenu.help($0).contains("git switch release/2.4")
                          && BranchMenu.help($0).contains("원격 브랜치(origin/release/2.4)를 추적") } == true)
    }

    /// 동기화 자리 변형 (진행 중 · 성공 뒤 복귀 · 대상이 바뀜) · PR 행 · 메뉴 단축키의 순수 판정.
    static func syncVariantDecisions(_ t: TestKit) async {
        await t.group("동기화 변형 · PR 행 판정")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let push = GitWrite.Operation.push(branch: "feature/login", setUpstream: false)
        let publish = GitWrite.Operation.push(branch: "feature/sso", setUpstream: true)

        // 진행 중
        let pushing = ChangesState.syncProgress(push, ahead: 2, upstream: "origin/feature/login", remoteName: "origin")
        await t.equal("업로드 중: 제목", pushing?.title, "커밋 2개를 올리는 중…")
        await t.equal("업로드 중: 대상 · 잠금 사실", pushing?.detail,
                      "→ origin/feature/login · 끝날 때까지 다른 Git 동작은 잠시 막아 둡니다.")
        await t.equal("업로드 중: 버튼", pushing?.buttonLabel, "업로드 중…")
        await t.equal("앞섬 수를 모르면 개수를 쓰지 않음",
                      ChangesState.syncProgress(push, ahead: nil, upstream: "origin/x", remoteName: nil)?.title, "업로드하는 중…")
        await t.check("브랜치 업로드 · 받기 · 원격 확인도 같은 형식",
                      ChangesState.syncProgress(publish, ahead: nil, upstream: nil, remoteName: "origin")
                          == ChangesState.SyncProgress(title: "브랜치를 업로드하는 중…", target: "→ origin/feature/sso",
                                                       buttonLabel: "업로드 중…")
                      && ChangesState.syncProgress(.pull, ahead: 0, upstream: "origin/main", remoteName: "origin")
                          == ChangesState.SyncProgress(title: "원격 변경을 받는 중…", target: "← origin/main", buttonLabel: "받는 중…")
                      && ChangesState.syncProgress(.fetch, ahead: 0, upstream: "origin/main", remoteName: "origin")?.detail
                          == "origin · 파일은 바뀌지 않습니다 · 끝날 때까지 다른 Git 동작은 잠시 막아 둡니다.")
        await t.check("한 줄 모양은 대상만 부제로 · 막아 둔다는 사실은 따로 (고정폭 한 줄에서 잘리지 않게)",
                      pushing?.target == "→ origin/feature/login"
                      && ChangesState.SyncProgress.blockingNote == "끝날 때까지 다른 Git 동작은 잠시 막아 둡니다.")
        await t.check("로컬 명령은 동기화 자리에 진행 표시 없음",
                      ChangesState.syncProgress(.commit(message: "m"), ahead: 1, upstream: "o/x", remoteName: "o") == nil
                      && ChangesState.syncProgress(.switchBranch("x"), ahead: 1, upstream: "o/x", remoteName: "o") == nil)

        // 성공 → 몇 초 뒤 평상 상태
        let done = now.addingTimeInterval(-1)
        let inSync = ChangesState.Sync.inSync(upstream: "origin/feature/login")
        await t.equal("업로드 완료 · PR 을 알 때",
                      ChangesState.syncSuccess(push, pushedCount: 2, after: inSync, pullRequest: 128, finishedAt: done, now: now),
                      ChangesState.SyncSuccess(done: "업로드 완료", title: "origin/feature/login 에 모두 반영됐습니다",
                                               sub: "PR #128에 커밋 2개가 반영됐습니다 · 방금"))
        await t.equal("업로드 완료 · PR 을 모를 때는 커밋 수만",
                      ChangesState.syncSuccess(push, pushedCount: 2, after: inSync, pullRequest: nil, finishedAt: done, now: now)?.sub,
                      "커밋 2개를 올렸습니다 · 방금")
        await t.check("개수를 모르면 쓰지 않음",
                      ChangesState.syncSuccess(push, pushedCount: nil, after: inSync, pullRequest: nil, finishedAt: done,
                                               now: now)?.sub == "방금"
                      && ChangesState.syncSuccess(push, pushedCount: nil, after: inSync, pullRequest: 7, finishedAt: done,
                                                  now: now)?.sub == "PR #7에 반영됐습니다 · 방금")
        await t.check("원격과 같지 않으면 '최신입니다' 라고 쓰지 않음",
                      ChangesState.syncSuccess(push, pushedCount: 2, after: .unknown(upstream: "origin/x"), pullRequest: nil,
                                               finishedAt: done, now: now)?.title == nil)
        await t.check("4초 안에는 보이고 4초가 지나면 평상 상태로 (시계가 어긋나 미래면 보임)",
                      ChangesState.syncSuccess(push, pushedCount: 2, after: inSync, pullRequest: nil,
                                               finishedAt: now.addingTimeInterval(-3.9), now: now) != nil
                      && ChangesState.syncSuccess(push, pushedCount: 2, after: inSync, pullRequest: nil,
                                                  finishedAt: now.addingTimeInterval(-4), now: now) == nil
                      && ChangesState.syncSuccess(push, pushedCount: 2, after: inSync, pullRequest: nil,
                                                  finishedAt: now.addingTimeInterval(30), now: now) != nil)
        await t.equal("성공 표시 시간", ChangesState.successDisplaySeconds, 4)
        await t.equal("받기 완료 (받은 개수는 쓰지 않음)",
                      ChangesState.syncSuccess(.pull, pushedCount: nil, after: .inSync(upstream: "origin/main"), pullRequest: nil,
                                               finishedAt: done, now: now),
                      ChangesState.SyncSuccess(done: "받기 완료", title: "원격과 같습니다", sub: "← origin/main · 방금"))
        await t.equal("브랜치 업로드 완료",
                      ChangesState.syncSuccess(publish, pushedCount: nil, after: .inSync(upstream: "origin/feature/sso"),
                                               pullRequest: nil, finishedAt: done, now: now),
                      ChangesState.SyncSuccess(done: "브랜치 업로드 완료", title: "origin/feature/sso 에 올렸습니다",
                                               sub: "이후 업로드는 이 브랜치로 갑니다 · 방금"))
        await t.check("원격 확인 · 로컬 명령은 성공 표시 없음 (요약의 '방금 확인' 이 바뀐다)",
                      ChangesState.syncSuccess(.fetch, pushedCount: nil, after: inSync, pullRequest: nil, finishedAt: done,
                                               now: now) == nil
                      && ChangesState.syncSuccess(.commit(message: "m"), pushedCount: nil, after: inSync, pullRequest: nil,
                                                  finishedAt: done, now: now) == nil)

        // "PR #n에 반영됐습니다" 는 최근(10분 안)에 조회한 PR 일 때만 — 오래된 캐시면 그 사이 병합 · 닫힘을 모른다
        await t.check("성공 문구의 PR: 10분 안에 조회했을 때만 · 조회 시각을 모르면 쓰지 않음",
                      ChangesState.freshPullRequest(128, checkedAt: now.addingTimeInterval(-60), now: now) == 128
                      && ChangesState.freshPullRequest(128, checkedAt: now.addingTimeInterval(-600), now: now) == nil
                      && ChangesState.freshPullRequest(128, checkedAt: nil, now: now) == nil
                      && ChangesState.freshPullRequest(nil, checkedAt: now, now: now) == nil)

        // PR 에 반영: OPEN 이고 head 가 지금 브랜치 · 추적 브랜치 이름과 같을 때만
        let pr = PullRequestInfo(number: 128, title: "t", state: "OPEN", isDraft: false, url: "", headRefName: "feature/login",
                                 baseRefName: "main", additions: nil, deletions: nil, changedFiles: nil, createdAt: nil,
                                 reviewDecision: nil, checks: [], reviews: [])
        await t.check("PR 반영: 지금 브랜치가 PR head 가 아니면 쓰지 않음",
                      ChangesState.pullRequestReceivingPush(pr, branch: "feature/other", upstream: "origin/feature/login") == nil
                      && ChangesState.pullRequestReceivingPush(pr, branch: nil, upstream: "origin/feature/login") == nil)

        // 대상이 바뀌었을 때
        var change = ChangesState.TargetChange(fromProjectPath: "/p/moa-ios", fromProject: "moa-ios", fromBranch: "main",
                                               toProjectPath: "/p/moa-ios", toProject: "moa-ios", toBranch: "feature/login",
                                               closed: .upload, hasDraft: true)
        await t.equal("브랜치가 바뀜 (목업 문구 + 닫은 확인 창)", ChangesState.targetChangeNotice(change),
                      ChangesState.TargetChangeNotice(title: "브랜치가 바뀌었습니다", from: "main", to: "feature/login",
                                                      rest: "열려 있던 업로드 확인 창을 닫았습니다. 쓰던 메시지는 그대로 두었습니다. "
                                                          + "이제 feature/login 에 커밋됩니다."))
        change.hasDraft = false
        await t.equal("쓰던 메시지가 없으면 그 말을 하지 않음", ChangesState.targetChangeNotice(change).rest,
                      "열려 있던 업로드 확인 창을 닫았습니다. 이제 feature/login 에 커밋됩니다.")
        change.toBranch = "HEAD a41c9e2"
        change.toDetached = true
        await t.equal("브랜치가 아닌 커밋으로 바뀜", ChangesState.targetChangeNotice(change).rest,
                      "열려 있던 업로드 확인 창을 닫았습니다. 지금은 브랜치가 아닌 커밋을 보고 있습니다.")
        let project = ChangesState.TargetChange(fromProjectPath: "/p/moa-ios", fromProject: "moa-ios", fromBranch: "feature/login",
                                                toProjectPath: "/p/moa-web", toProject: "moa-web", toBranch: "main",
                                                closed: .pull, hasDraft: true)
        await t.equal("프로젝트가 바뀜 (초안은 폴더마다 따로 — chg-8)", ChangesState.targetChangeNotice(project),
                      ChangesState.TargetChangeNotice(title: "프로젝트가 바뀌었습니다", from: "moa-ios", to: "moa-web",
                                                      rest: "열려 있던 받기 확인 창을 닫았습니다. 커밋 메시지는 폴더마다 따로 둡니다. "
                                                          + "이제 moa-web 의 main 에 커밋됩니다."))
        var loading = project
        loading.toBranch = nil
        await t.check("새 폴더를 읽는 중이면 기다렸다가 브랜치를 채움 · 다른 곳으로 또 바뀌면 지움",
                      ChangesState.targetNoticeUpdate(loading, nowPath: "/p/moa-web", nowBranch: nil, nowDetached: false) == .keep
                      && ChangesState.targetNoticeUpdate(loading, nowPath: "/p/moa-web", nowBranch: "main", nowDetached: false)
                          == .fill(branch: "main", detached: false)
                      && ChangesState.targetNoticeUpdate(project, nowPath: "/p/moa-web", nowBranch: "main", nowDetached: false)
                          == .keep
                      && ChangesState.targetNoticeUpdate(project, nowPath: "/p/moa-web", nowBranch: "dev", nowDetached: false)
                          == .clear
                      && ChangesState.targetNoticeUpdate(project, nowPath: "/p/other", nowBranch: "main", nowDetached: false)
                          == .clear)
        await t.equal("브랜치만 바뀌어도 대상 안내 (프로젝트 그대로)", ChangesState.targetChangeNotice(loading).rest,
                      "열려 있던 받기 확인 창을 닫았습니다. 커밋 메시지는 폴더마다 따로 둡니다. 이제 moa-web 에 커밋됩니다.")

        // PR 행 — 검사 수 · 변경 요청 수 · 상태 알약 · 한 줄 문구 · 조회 조건
        let json = """
        {"number":128,"title":"AuthViewModel: 전송 계층 프로토콜 분리","state":"OPEN","isDraft":false,
         "url":"https://github.com/o/r/pull/128","headRefName":"feature/login","baseRefName":"main",
         "statusCheckRollup":[
           {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"},
           {"__typename":"CheckRun","name":"unit-tests","status":"IN_PROGRESS","conclusion":""},
           {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
           {"__typename":"CheckRun","name":"docs","status":"COMPLETED","conclusion":"SKIPPED"}],
         "latestReviews":[{"author":{"login":"minji"},"state":"CHANGES_REQUESTED","body":""},
                          {"author":{"login":"sora"},"state":"APPROVED","body":""}]}
        """
        let info = GitHubCLI.parseView(json)
        let summary = ChangesState.checksSummary(info?.checks ?? [])
        await t.equal("검사 요약 (건너뜀은 전체에서 뺌)", summary,
                      ChangesState.ChecksSummary(passed: 2, total: 3, failed: 0, pending: 1, neutral: 0, skipped: 1))
        await t.equal("검사 문구 (목업 '검사 2/3 통과')", ChangesState.checksText(summary), "검사 2/3 통과")
        await t.equal("리뷰 변경 요청 수 (CHANGES_REQUESTED 만)", ChangesState.changesRequestedCount(info?.reviews ?? []), 1)
        func check(_ outcome: PullRequestInfo.Check.Outcome) -> PullRequestInfo.Check {
            PullRequestInfo.Check(id: UUID().uuidString, name: "c", detail: nil, outcome: outcome, duration: nil)
        }
        await t.equal("검사 문구: 없음 · 모두 건너뜀 · 실패 · 중립",
                      [[], [check(.skipped), check(.skipped)], [check(.pass), check(.fail)], [check(.pass), check(.neutral)]]
                        .map { ChangesState.checksText(ChangesState.checksSummary($0)) },
                      ["검사 없음", "검사 2개 모두 건너뜀", "검사 1/2 통과", "검사 1/2 통과"])
        await t.check("실패 · 중립 수를 따로 셈",
                      ChangesState.checksSummary([check(.pass), check(.fail), check(.neutral)]).failed == 1
                      && ChangesState.checksSummary([check(.pass), check(.fail), check(.neutral)]).neutral == 1)
        await t.equal("리뷰가 없으면 0 (행에서 숨김)", ChangesState.changesRequestedCount([]), 0)
        await t.equal("검사 도움말: 행에 따로 적지 않는 수 (진행 중 · 중립 · 건너뜀) + 정의",
                      ChangesState.checksHelp(ChangesState.checksSummary([check(.pass), check(.pending), check(.neutral),
                                                                          check(.skipped)])),
                      "진행 중 1 · 중립 1 · 건너뜀 1\n" + ChangesState.checksDefinition)
        await t.equal("검사 도움말: 따로 셀 것이 없으면 정의만",
                      ChangesState.checksHelp(ChangesState.checksSummary([check(.pass)])), ChangesState.checksDefinition)
        await t.equal("상태 알약은 gh 값 그대로",
                      [("OPEN", false), ("OPEN", true), ("MERGED", false), ("CLOSED", false), ("QUEUED", false)]
                        .map { ChangesState.pullRequestPill(state: $0.0, isDraft: $0.1).label },
                      ["Open", "Draft", "Merged", "Closed", "Queued"])
        let checked = now.addingTimeInterval(-180)
        await t.equal("조회 시각 문구", ChangesState.checkedText(checked, now: now), "3분 전 조회")
        await t.check("PR 행: 조회 전 숨김 · 조회 중 · 불러옴",
                      ChangesState.pullRequestLine(.idle, checkedAt: nil, now: now) == .hidden
                      && ChangesState.pullRequestLine(.loading, checkedAt: nil, now: now) == .loading
                      && info.map { ChangesState.pullRequestLine(.loaded($0, others: []), checkedAt: checked, now: now)
                          == .loaded($0) } == true)
        await t.equal("PR 행: PR 없음 · n분 전 조회",
                      ChangesState.pullRequestLine(.none(branch: "feature/login", others: []), checkedAt: checked, now: now),
                      .message("이 브랜치의 PR 없음", checked: "3분 전 조회",
                               help: "gh 가 feature/login 에서 연 PR 을 찾지 못했습니다. ··· 에서 다시 조회"))
        await t.equal("PR 행: 조회 실패 (원문은 도움말)",
                      ChangesState.pullRequestLine(.failed("HTTP 502"), checkedAt: checked, now: now),
                      .message("PR 조회 실패 — ··· 에서 다시 조회", checked: "3분 전 조회", help: "HTTP 502"))
        await t.equal("PR 행: gh 없음 · 로그인 필요 · GitHub 아님은 그 사실",
                      ChangesState.pullRequestLine(.unavailable("gh 로그인이 필요합니다."), checkedAt: nil, now: now),
                      .message("PR 을 읽을 수 없음 · gh 로그인이 필요합니다.", checked: nil, help: "gh 로그인이 필요합니다."))
        var repo = GitWorkspaceStatus()
        GitWorkspace.parseStatus("## feature/login...origin/feature/login\0", into: &repo)
        repo.isRepository = true
        repo.remotes = ["origin"]
        var noRemote = repo
        noRemote.remotes = []
        var remotesUnknown = repo
        remotesUnknown.remotes = nil
        var detachedRepo = repo
        detachedRepo.branch = nil
        var failedRead = repo
        failedRead.error = "git status 실패"
        // git 을 다시 읽은 뒤: 조회 중에 브랜치가 바뀌면 그 조회를 버리고 새 브랜치는 조회 전(idle) — 탭이 한 번 묻는다
        let loadedPR = info.map { PullRequestState.loaded($0, others: []) } ?? .idle
        let same = ChangesState.pullRequestAfterRefresh(current: .loading, loadingKey: "p|feature/login", key: "p|feature/login",
                                                        cached: loadedPR)
        let moved = ChangesState.pullRequestAfterRefresh(current: .loading, loadingKey: "p|feature/login", key: "p|main",
                                                         cached: nil)
        let movedCached = ChangesState.pullRequestAfterRefresh(current: .loading, loadingKey: "p|feature/login",
                                                               key: "p|main", cached: loadedPR)
        let idleMoved = ChangesState.pullRequestAfterRefresh(current: loadedPR, loadingKey: nil, key: "p|main", cached: nil)
        await t.check("조회 중 · 같은 브랜치: 결과를 기다림 (옛 캐시로 덮지 않음)", same.state == .loading && !same.invalidatesQuery)
        await t.check("조회 중 · 브랜치가 바뀜: 조회를 버리고 idle → 새 브랜치를 한 번 물을 수 있음 (조회 중에 멈추지 않음)",
                      moved.state == .idle && moved.invalidatesQuery
                      && ChangesState.pullRequestQueryNeeded(moved.state, status: repo))
        await t.check("조회 중 · 바뀐 브랜치에 캐시가 있으면 캐시", movedCached.state == loadedPR && movedCached.invalidatesQuery)
        await t.check("결과가 있는데 브랜치가 바뀌고 캐시가 없으면 idle (옛 브랜치의 PR 을 남기지 않음)",
                      idleMoved.state == .idle && !idleMoved.invalidatesQuery)

        await t.check("탭을 열 때 조회: 캐시에 없을 때(idle)만 · 브랜치 · 원격이 있을 때만",
                      ChangesState.pullRequestQueryNeeded(.idle, status: repo)
                      && ChangesState.pullRequestQueryNeeded(.idle, status: remotesUnknown)
                      && !ChangesState.pullRequestQueryNeeded(.none(branch: "x", others: []), status: repo)
                      && !ChangesState.pullRequestQueryNeeded(.failed("x"), status: repo)
                      && !ChangesState.pullRequestQueryNeeded(.loading, status: repo)
                      && !ChangesState.pullRequestQueryNeeded(.idle, status: noRemote)
                      && !ChangesState.pullRequestQueryNeeded(.idle, status: detachedRepo)
                      && !ChangesState.pullRequestQueryNeeded(.idle, status: failedRead)
                      && !ChangesState.pullRequestQueryNeeded(.idle, status: nil)
                      && !ChangesState.pullRequestQueryNeeded(.idle, status: GitWorkspaceStatus()))

        // 메뉴 단축키 — ⌘⇧N 이 다른 단축키와 겹치지 않는다
        await t.group("메뉴 단축키")
        let everything = MenuShortcut.appMenu + MenuShortcut.system + MenuShortcut.inView
        await t.equal("앱 메뉴 · 기본 메뉴 · 화면 안 단축키 중 겹치는 것 없음",
                      MenuShortcut.conflicts(everything).map { $0.map(\.title) }, [])
        await t.equal("새 브랜치 만들기 = ⇧⌘N", MenuShortcut.newBranch.symbol, "⇧⌘N")
        await t.check("⇧⌘N 과 ⌘N(새 대화)은 다른 단축키 · 대소문자는 같은 키",
                      !MenuShortcut.newBranch.collides(with: MenuShortcut.newThread)
                      && MenuShortcut.newBranch.collides(with: MenuShortcut(title: "x", key: "N", modifiers: [.shift, .command])))
        await t.equal("⌘⇧N 은 앱 메뉴에 하나", MenuShortcut.appMenu.filter { $0.collides(with: .newBranch) }.count, 1)
        await t.equal("표기: 기존 단축키", [MenuShortcut.changesSearch, .fileSearch, .toggleInspector, .handoff].map(\.symbol),
                      ["⇧⌘F", "⌘P", "⌥⌘0", "⇧⌘H"])
        await t.check("사이드바 보기/숨기기 ⌃⌘S 는 앱이 건다 (사이드바를 직접 그린다) — 시스템 표에는 없다",
                      MenuShortcut.toggleSidebar.symbol == "⌃⌘S" && MenuShortcut.appMenu.contains(.toggleSidebar)
                        && !MenuShortcut.system.contains { $0.collides(with: .toggleSidebar) })
        await t.equal("인스펙터 탭 단축키 ⌥⌘1–5", InspectorTab.allCases.map { MenuShortcut.inspectorTab($0).symbol },
                      ["⌥⌘1", "⌥⌘2", "⌥⌘3", "⌥⌘4", "⌥⌘5"])
        await t.equal("분할 화면 ⌃⌘ + 칸 수 · 전적 ⇧⌘B",
                      PaneLayout.allCases.map { MenuShortcut.paneLayout($0).symbol } + [MenuShortcut.scoreboard.symbol],
                      ["⌃⌘1", "⌃⌘2", "⌃⌘4", "⇧⌘B"])
        await t.check("분할 · 전적 단축키도 앱 메뉴 표에 있다 (겹침 검사 대상)",
                      MenuShortcut.appMenu.contains(.scoreboard) && MenuShortcut.appMenu.contains(.paneLayout(.fourGrid)))
        await t.equal("승인 카드 허용 · 거절 = ⌥⌘↵ · ⌥⌘⌫ (입력창의 ⌘↵ · 글 칸의 ⌘⌫ 와 다르다)",
                      [MenuShortcut.approvalAllow.symbol, MenuShortcut.approvalDeny.symbol], ["⌥⌘↵", "⌥⌘⌫"])
        await t.check("승인 단축키는 앱 메뉴 표에 있고 보내기(⌘↵)와 겹치지 않는다",
                      MenuShortcut.appMenu.contains(.approvalAllow) && MenuShortcut.appMenu.contains(.approvalDeny)
                        && !MenuShortcut.inView.contains { $0.collides(with: .approvalAllow) })
        await t.check("겹침 검사가 실제로 겹침을 찾음 (⌘F 를 한 번 더 걸면)",
                      MenuShortcut.conflicts(everything + [MenuShortcut(title: "중복", key: "f", modifiers: [.command])]).count == 1)
        // ⌘F 는 포커스 칸의 대화 안 찾기, 대화 목록 검색은 ⌥⌘F 로 옮겼다. 다음 · 이전은 macOS 의 찾기와 같은 ⌘G · ⇧⌘G.
        await t.equal("찾기 단축키: 대화 안 ⌘F · 다음 ⌘G · 이전 ⇧⌘G · 대화 목록 ⌥⌘F · 변경 파일 ⇧⌘F",
                      [MenuShortcut.findInConversation, .findNext, .findPrevious, .threadSearch, .changesSearch].map(\.symbol),
                      ["⌘F", "⌘G", "⇧⌘G", "⌥⌘F", "⇧⌘F"])
        await t.equal("메뉴 이름: 새 대화 · 대화에서 찾기 · 대화 목록 검색 · 이 앱 소개 (⌘?)",
                      [MenuShortcut.newThread.title, MenuShortcut.findInConversation.title, MenuShortcut.threadSearch.title,
                       MenuShortcut.appGuide.title + " " + MenuShortcut.appGuide.symbol],
                      ["새 대화", "대화에서 찾기…", "대화 목록 검색", "이 앱 소개 ⌘?"])
        await t.check("찾기 · 도움말 단축키도 앱 메뉴 표에 있다 (겹침 검사 대상)",
                      [MenuShortcut.findInConversation, .findNext, .findPrevious, .threadSearch, .appGuide]
                        .allSatisfy(MenuShortcut.appMenu.contains))
        // 도움말 > 키보드 단축키 시트는 이 표에서 만든다 — 메뉴가 거는 단축키는 시트에 꼭 한 번씩, 화면 안 단축키도 모두.
        let listed = MenuShortcut.helpSections.flatMap(\.items)
        let missingOrDuplicated = MenuShortcut.appMenu.filter { shortcut in listed.filter { $0 == shortcut }.count != 1 }
        await t.equal("단축키 시트: 앱 메뉴의 단축키가 모두 한 번씩", missingOrDuplicated.map(\.title), [])
        await t.check("단축키 시트: 화면 안 단축키 · 찾기 막대의 키도 있다",
                      (MenuShortcut.inView + MenuShortcut.findBar).allSatisfy(listed.contains))
        await t.check("단축키 시트의 묶음 이름은 겹치지 않는다 (목록의 id)",
                      Set(MenuShortcut.helpSections.map(\.title)).count == MenuShortcut.helpSections.count)

        // 창 패널 접기 — 창이 좁으면 한쪽 보조 패널을 접고, 공간이 돌아오면 다시 편다 (`ContentView.fitPanels`)
        await t.group("창 패널 접기")
        await t.equal("세 칸이 들어가는 창 너비 = 사이드바 200 + 선 1 + 본문 460 + 인스펙터 400 (사이드바를 직접 그린 뒤, 1061)",
                      PanelFit.requiredWidth(sidebar: true, inspector: true), 1061)
        await t.equal("사이드바만 661 · 인스펙터만 860 · 본문만 460",
                      [PanelFit.requiredWidth(sidebar: true, inspector: false), PanelFit.requiredWidth(sidebar: false, inspector: true),
                       PanelFit.requiredWidth(sidebar: false, inspector: false)], [661, 860, 460])
        await t.equal("사이드바 상한 = 창 − 본문 − 인스펙터 최소 − 선: 1512 → 651 (앱은 360 에서 자른다) · 1061 → 200 · 1000 → 139 (호출 쪽이 최소로 막음)",
                      [PanelFit.sidebarLimit(windowWidth: 1512, inspector: true), PanelFit.sidebarLimit(windowWidth: 1061, inspector: true),
                       PanelFit.sidebarLimit(windowWidth: 1000, inspector: true)], [651, 200, 139])
        await t.equal("인스펙터가 없으면 그만큼 사이드바가 넓어질 수 있음: 창 1000 → 539",
                      PanelFit.sidebarLimit(windowWidth: 1000, inspector: false), 539)
        await t.equal("인스펙터 상한 = 창 − 본문 − 사이드바 칸(실제): 1440 · 칸 249 → 731 (앱은 560 에서 자른다), 1300 → 591, 1100 · 칸 240 → 400",
                      [PanelFit.inspectorLimit(windowWidth: 1440, sidebarColumnWidth: 249, sidebarVisible: true),
                       PanelFit.inspectorLimit(windowWidth: 1300, sidebarColumnWidth: 249, sidebarVisible: true),
                       PanelFit.inspectorLimit(windowWidth: 1100, sidebarColumnWidth: 240, sidebarVisible: true)], [731, 591, 400])
        await t.equal("칸 너비를 모르면 최소 칸(201)으로 · 사이드바가 접혀 있으면 0 으로: 창 1512 → 851 · 1000 → 540",
                      [PanelFit.inspectorLimit(windowWidth: 1512, sidebarColumnWidth: nil, sidebarVisible: true),
                       PanelFit.inspectorLimit(windowWidth: 1000, sidebarColumnWidth: 300, sidebarVisible: false)], [851, 540])
        await t.check("두 상한을 함께 써도 창을 넘지 않는다: 사이드바를 상한까지 넓히면 인스펙터 상한이 최소가 된다 (1100 창)",
                      PanelFit.sidebarLimit(windowWidth: 1100, inspector: true) + 1 + 460
                        + PanelFit.inspectorLimit(windowWidth: 1100, sidebarColumnWidth: PanelFit.sidebarLimit(windowWidth: 1100, inspector: true) + 1,
                                                  sidebarVisible: true) == 1100)
        await t.equal("툴바 제목 여백: 항목이 x 120 에 놓이고 사이드바 칸이 249 면 145 (제목이 본문 칸 + 16 에서 시작)",
                      PanelFit.toolbarTitleLead(sidebarVisible: true, sidebarColumnWidth: 249, itemX: 120), 145)
        await t.equal("사이드바가 접혔거나 아직 안 쟀으면 최소 여백 8 · 계산이 음수여도 8",
                      [PanelFit.toolbarTitleLead(sidebarVisible: false, sidebarColumnWidth: 249, itemX: 120),
                       PanelFit.toolbarTitleLead(sidebarVisible: true, sidebarColumnWidth: 249, itemX: nil),
                       PanelFit.toolbarTitleLead(sidebarVisible: true, sidebarColumnWidth: 100, itemX: 200)], [8, 8, 8])
        await t.equal("창 1000 · 둘 다 보임 → 마지막으로 연 쪽(인스펙터)을 남기고 사이드바를 접음",
                      PanelFit.adjustment(windowWidth: 1000, sidebar: true, inspector: true, autoHidden: nil, lastOpened: .inspector),
                      .hide(.sidebar))
        await t.equal("마지막으로 연 쪽이 사이드바면 인스펙터를 접음",
                      PanelFit.adjustment(windowWidth: 1000, sidebar: true, inspector: true, autoHidden: nil, lastOpened: .sidebar),
                      .hide(.inspector))
        await t.equal("1200 은 이제 그대로 — 예전 NavigationSplitView 는 본문 칸이 사이드바 폭을 두 번 요구해 1276 이 필요했다",
                      PanelFit.adjustment(windowWidth: 1200, sidebar: true, inspector: true, autoHidden: nil, lastOpened: .inspector),
                      nil as PanelFit.Change?)
        await t.equal("1061 부터는 그대로 (1060 은 접음)",
                      [PanelFit.adjustment(windowWidth: 1061, sidebar: true, inspector: true, autoHidden: nil, lastOpened: .inspector),
                       PanelFit.adjustment(windowWidth: 1060, sidebar: true, inspector: true, autoHidden: nil, lastOpened: .inspector)],
                      [nil, .hide(.sidebar)])
        await t.equal("2026-09-14 결함의 재현: 창(1000) 대신 넘친 뷰 폭(1296)으로 재면 '공간이 있다'고 보고 접지 않음 — 그래서 창 폭으로 잰다",
                      [PanelFit.adjustment(windowWidth: 1296, sidebar: true, inspector: true, autoHidden: nil, lastOpened: .inspector),
                       PanelFit.adjustment(windowWidth: 1000, sidebar: true, inspector: true, autoHidden: nil, lastOpened: .inspector)],
                      [nil, .hide(.sidebar)])
        await t.equal("창 폭을 모르면(0) 아무것도 하지 않음",
                      PanelFit.adjustment(windowWidth: 0, sidebar: true, inspector: true, autoHidden: nil, lastOpened: .inspector),
                      nil as PanelFit.Change?)
        await t.equal("보이는 패널이 하나뿐이면 창이 좁아도 접지 않음 (사용자가 닫은 쪽은 건드리지 않음)",
                      [PanelFit.adjustment(windowWidth: 700, sidebar: false, inspector: true, autoHidden: nil, lastOpened: .inspector),
                       PanelFit.adjustment(windowWidth: 700, sidebar: true, inspector: false, autoHidden: nil, lastOpened: .sidebar)],
                      [nil, nil])
        await t.equal("앱이 접은 사이드바는 창이 1061 이 될 때 다시 폄 (1060 은 아직)",
                      [PanelFit.adjustment(windowWidth: 1060, sidebar: false, inspector: true, autoHidden: .sidebar, lastOpened: .inspector),
                       PanelFit.adjustment(windowWidth: 1061, sidebar: false, inspector: true, autoHidden: .sidebar, lastOpened: .inspector)],
                      [nil, .show(.sidebar)])
        await t.equal("앱이 접은 사이드바는 사용자가 인스펙터를 닫으면 좁은 창(1000 ≥ 661)에서도 바로 돌아옴",
                      PanelFit.adjustment(windowWidth: 1000, sidebar: false, inspector: false, autoHidden: .sidebar, lastOpened: .inspector),
                      .show(.sidebar))
        await t.equal("앱이 접은 인스펙터도 같은 규칙 (1061 에서 복귀 · 사이드바를 닫으면 860 부터)",
                      [PanelFit.adjustment(windowWidth: 1061, sidebar: true, inspector: false, autoHidden: .inspector, lastOpened: .sidebar),
                       PanelFit.adjustment(windowWidth: 1000, sidebar: true, inspector: false, autoHidden: .inspector, lastOpened: .sidebar),
                       PanelFit.adjustment(windowWidth: 860, sidebar: false, inspector: false, autoHidden: .inspector, lastOpened: .sidebar)],
                      [.show(.inspector), nil, .show(.inspector)])
    }

    /// 브랜치 메뉴의 명령을 실제 임시 저장소로: 원격에만 있는 브랜치 전환(추적 브랜치 생성) · 여러 원격의 같은 이름
    /// (git 거부 → 원문) · 새 브랜치에 변경이 함께 옮겨감 · 겹치는 파일 · 병합 중 거부 · 최근 순서.
    static func branchMenuLiveRepository(_ t: TestKit) async {
        await t.group("브랜치 메뉴 · 실제 저장소")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ahc-branchmenu-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        let other = root.appendingPathComponent("other")
        let origin = root.appendingPathComponent("origin.git")
        let team = root.appendingPathComponent("team.git")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        guard let git = GitInspector.findGit(environment: env) else {
            await t.check("git 실행 파일", false, "찾지 못함")
            return
        }
        @discardableResult
        func sh(_ args: [String], in dir: URL, daysAgo: Int? = nil) async -> String {
            var e = env
            if let daysAgo {
                let date = "\(Int(Date().timeIntervalSince1970) - daysAgo * 86_400) +0000"
                e["GIT_AUTHOR_DATE"] = date
                e["GIT_COMMITTER_DATE"] = date
            }
            let result = await CLIEnvironment.captureOutput(
                executable: git, arguments: ["-c", "user.name=t", "-c", "user.email=t@example.com",
                                             "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args,
                environment: e, workingDirectory: dir, timeout: 30)
            if case .success(let out) = result { return out }
            return ""
        }
        func commitFile(_ name: String, _ text: String, _ message: String, in dir: URL, daysAgo: Int) async {
            try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            await sh(["add", "--", name], in: dir)
            await sh(["commit", "-q", "-m", message], in: dir, daysAgo: daysAgo)
        }
        func perform(_ operation: GitWrite.Operation) async -> GitWrite.Outcome {
            await GitWrite.perform(operation, git: git, at: work, environment: env)
        }

        await sh(["init", "-q", "-b", "main"], in: work)
        await commitFile("a.txt", "base\n", "기준", in: work, daysAgo: 9)
        await sh(["init", "--bare", "-q", "-b", "main", origin.path], in: root)
        await sh(["init", "--bare", "-q", "-b", "main", team.path], in: root)
        await sh(["remote", "add", "origin", origin.path], in: work)
        await sh(["remote", "add", "team", team.path], in: work)
        await sh(["push", "-q", "-u", "origin", "main"], in: work)
        // 로컬 브랜치 둘 (마지막 커밋 시각이 다르다)
        await sh(["switch", "-q", "-c", "old-topic"], in: work)
        await commitFile("o.txt", "o\n", "오래된 주제", in: work, daysAgo: 7)
        await sh(["switch", "-q", "main"], in: work)
        await sh(["switch", "-q", "-c", "fix/payment-retry"], in: work)
        await commitFile("f.txt", "f\n", "결제 재시도", in: work, daysAgo: 3)
        await sh(["switch", "-q", "main"], in: work)
        // 다른 사람이 올린 브랜치: release/2.4 (origin 에만), topic (origin · team 둘 다)
        await sh(["clone", "-q", origin.path, other.path], in: root)
        await sh(["switch", "-q", "-c", "release/2.4"], in: other)
        await commitFile("r.txt", "r\n", "릴리스", in: other, daysAgo: 5)
        await sh(["push", "-q", "origin", "release/2.4"], in: other)
        await sh(["switch", "-q", "-c", "topic", "main"], in: other)
        await commitFile("t.txt", "t\n", "주제", in: other, daysAgo: 1)
        await sh(["push", "-q", "origin", "topic"], in: other)
        await sh(["push", "-q", team.path, "topic"], in: other)
        await sh(["fetch", "-q", "--all"], in: work)

        var status = await GitWorkspace.status(at: work, environment: env)
        var menu = BranchMenu.content(status: status, query: "", block: nil)
        await t.equal("최근 브랜치: 마지막 커밋 순 (실제 for-each-ref)",
                      menu.sections.first { $0.kind == .recent }?.items.map(\.name) ?? [], ["fix/payment-retry", "old-topic"])
        await t.equal("원격에만 있는 브랜치 (main 은 추적 중이라 빠짐 · 두 원격)",
                      menu.sections.first { $0.kind == .remoteOnly }?.items.map { $0.fullName ?? "" } ?? [],
                      ["origin/topic", "team/topic", "origin/release/2.4"])
        await t.check("원격이 둘이면 섹션 오른쪽 이름 없음", menu.sections.first { $0.kind == .remoteOnly }?.trailing == nil)

        // 원격에만 있는 브랜치 전환 → git 이 추적 브랜치를 만든다 (새 명령이 아니다)
        let release = menu.item(id: "remote:origin/release/2.4")
        let switched = await perform(release.flatMap(BranchMenu.operation(for:)) ?? .fetch)
        status = await GitWorkspace.status(at: work, environment: env)
        await t.check("원격에만 있는 브랜치 전환: git switch release/2.4 → 추적 브랜치를 만들어 전환",
                      switched.succeeded && switched.command == "git switch release/2.4" && status.branch == "release/2.4"
                      && status.upstream == "origin/release/2.4", switched.output)
        menu = BranchMenu.content(status: status, query: "", block: nil)
        await t.check("전환한 뒤에는 로컬 브랜치라 원격에만 있는 목록에서 빠짐",
                      menu.item(id: "remote:origin/release/2.4") == nil && menu.sections.first?.items.first?.name == "release/2.4")
        _ = await perform(.switchBranch("main"))

        // 같은 이름이 여러 원격에 있으면 메뉴가 그 행들을 잠근다. 근거: git 은 거부하고, checkout.defaultRemote 가 있으면
        // 누른 행(team)과 다른 원격(origin)을 따라간다.
        let ambiguousMenu = BranchMenu.content(status: await GitWorkspace.status(at: work, environment: env), query: "topic",
                                               block: nil)
        let ambiguousRows = ["remote:origin/topic", "remote:team/topic"].compactMap { ambiguousMenu.item(id: $0) }
        await t.check("여러 원격에 같은 이름: 두 행 모두 막고 --track 안내 (명령 없음)",
                      ambiguousRows.count == 2 && ambiguousRows.allSatisfy { BranchMenu.operation(for: $0) == nil }
                      && ambiguousRows.last?.disabledReason?.contains("git switch --track team/topic") == true)
        let ambiguous = await perform(.switchBranch("topic"))
        await t.check("근거 1: git switch topic 은 git 이 거부 (여러 원격에 일치)",
                      !ambiguous.succeeded && ambiguous.output.contains("topic"), ambiguous.output)
        let preferOrigin = await sh(["-c", "checkout.defaultRemote=origin", "switch", "topic"], in: work)
        let tracked = await sh(["rev-parse", "--abbrev-ref", "topic@{u}"], in: work)
        await t.check("근거 2: checkout.defaultRemote 가 있으면 team 행을 눌러도 origin/topic 을 따라감",
                      tracked.trimmingCharacters(in: .whitespacesAndNewlines) == "origin/topic", preferOrigin + tracked)
        _ = await perform(.switchBranch("main"))
        await sh(["branch", "-q", "-D", "topic"], in: work)

        // 새 브랜치 — 변경 파일이 함께 옮겨간다
        try? "changed\n".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? "new\n".write(to: work.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
        status = await GitWorkspace.status(at: work, environment: env)
        let before = status.changeCount
        menu = BranchMenu.content(status: status, query: "feature/new", block: nil)
        await t.equal("새 브랜치 행 둘째 줄 (실제 변경 수)", BranchMenu.createDetail(from: status.headLabel, changeCount: before),
                      "main 에서 시작 · 변경 파일 2개 함께 이동")
        let created = await perform(menu.create.flatMap(BranchMenu.operation(for:)) ?? .fetch)
        status = await GitWorkspace.status(at: work, environment: env)
        await t.check("새 브랜치를 만들고 전환 · 변경 파일이 그대로 따라옴 (git switch -c)",
                      created.succeeded && status.branch == "feature/new" && status.changeCount == before, created.output)

        // 겹치는 파일이 있으면 git 이 전환하지 않는다 → 2단계 분류 (출력에 나온 파일)
        let overlap = await perform(.switchBranch("fix/payment-retry"))
        await t.check("겹치지 않는 변경은 함께 옮겨짐", overlap.succeeded, overlap.output)
        await commitFile("a.txt", "fix side\n", "a 수정", in: work, daysAgo: 0)
        _ = await perform(.switchBranch("main"))
        try? "mine\n".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let blocked = await perform(.switchBranch("fix/payment-retry"))
        let blockedFailure = GitFailure.classify(.switchBranch("fix/payment-retry"), output: blocked.output)
        await t.equal("겹치는 파일: 전환하지 않고 파일 이름을 알림", blockedFailure, .overlappingChanges(["a.txt"]))
        await t.equal("전환 실패 문구", blockedFailure.explanation(for: .switchBranch("fix/payment-retry")).detail,
                      "겹치는 파일이 있어 전환하지 않았습니다: a.txt. 먼저 커밋하거나 치운 뒤 다시 전환하세요.")

        // 병합 중: git 이 전환 · 만들기를 거부한다 → 메뉴가 미리 잠근다
        await sh(["checkout", "-q", "--", "a.txt"], in: work)
        try? fm.removeItem(at: work.appendingPathComponent("n.txt"))
        await commitFile("a.txt", "main side\n", "main 쪽 a", in: work, daysAgo: 0)
        await sh(["merge", "fix/payment-retry"], in: work)
        status = await GitWorkspace.status(at: work, environment: env)
        let conflicts = status.conflicted.count
        let mergeBlock = BranchMenu.block(lock: nil, merging: status.isMerging, rebasing: status.isRebasing, conflicts: conflicts)
        let refused = await perform(.switchBranch("old-topic"))
        let refusedCreate = await perform(.createBranch("during-merge"))
        let still = await GitWorkspace.status(at: work, environment: env)
        await t.check("병합 중 → 메뉴가 잠금 (병합 · 충돌보다 병합 이유)",
                      status.isMerging && mergeBlock == .merging
                      && BranchMenu.content(status: status, query: "", block: mergeBlock).selectableIDs.isEmpty,
                      "\(String(describing: mergeBlock))")
        await t.check("실제로 git 도 병합 중 전환 · 만들기를 거부 (잠금의 근거)",
                      !refused.succeeded && !refusedCreate.succeeded && still.branch == "main" && still.isMerging,
                      JSONUtil.truncate(refused.output, max: 120))
        await sh(["merge", "--abort"], in: work)

        // 충돌 파일만 남은 상태 (stash pop 충돌 — 병합 아님): git 은 다른 브랜치로의 전환만 거부하고 새 브랜치는 허용한다
        try? "stashed\n".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        await sh(["stash", "-q"], in: work)
        await commitFile("a.txt", "committed\n", "a 다시 수정", in: work, daysAgo: 0)
        await sh(["stash", "pop", "-q"], in: work)
        status = await GitWorkspace.status(at: work, environment: env)
        let stashBlock = BranchMenu.block(lock: nil, merging: status.isMerging, rebasing: status.isRebasing,
                                          conflicts: Set(status.conflicted.map(\.path)).count)
        let stashMenu = BranchMenu.content(status: status, query: "rescue", block: stashBlock)
        let refusedSwitch = await perform(.switchBranch("old-topic"))
        let allowedCreate = await perform(stashMenu.create.flatMap(BranchMenu.operation(for:)) ?? .fetch)
        let afterCreate = await GitWorkspace.status(at: work, environment: env)
        await t.check("stash pop 충돌: 병합 아님 · 충돌 1 → 전환 행만 잠그고 새 브랜치 행은 열림",
                      !status.isMerging && stashBlock == .conflicts(1) && stashMenu.create?.isSelectable == true
                      && BranchMenu.content(status: status, query: "", block: stashBlock).selectableIDs.isEmpty,
                      "\(String(describing: stashBlock))")
        await t.check("실제로 git 도 전환은 거부 · 새 브랜치는 만듦 (충돌 파일도 함께 옮겨감)",
                      !refusedSwitch.succeeded && allowedCreate.succeeded && afterCreate.branch == "rescue"
                      && afterCreate.conflicted.count == 1,
                      JSONUtil.truncate(refusedSwitch.output + " / " + allowedCreate.output, max: 200))
    }

    /// 앱 경로(`AppModel.runGit`)로 업로드 — 진행 중 표시(이 프로젝트의 명령) · 명령 전후 상태 · 성공 표시와 4초 뒤 복귀 ·
    /// PR 캐시(화면 확인용 입구가 앱의 해석기로 넣은 값)와 조회 시각. 에이전트 CLI · gh 는 부르지 않는다.
    @MainActor
    static func syncVariantsThroughAppModel(_ t: TestKit) async {
        await t.group("동기화 변형 · 앱 경로")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ahc-syncvariant-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        let origin = root.appendingPathComponent("origin.git")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        guard let git = GitInspector.findGit(environment: env) else { return }
        func sh(_ args: [String], in dir: URL) async {
            _ = await CLIEnvironment.captureOutput(
                executable: git, arguments: ["-c", "user.name=t", "-c", "user.email=t@example.com",
                                             "-c", "commit.gpgsign=false"] + args,
                environment: env, workingDirectory: dir, timeout: 30)
        }
        await sh(["init", "-q", "-b", "main"], in: work)
        await sh(["config", "user.name", "t"], in: work)
        await sh(["config", "user.email", "t@example.com"], in: work)
        await sh(["config", "commit.gpgsign", "false"], in: work)
        try? "a\n".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        await sh(["add", "a.txt"], in: work)
        await sh(["commit", "-q", "-m", "기준"], in: work)
        await sh(["init", "--bare", "-q", "-b", "main", origin.path], in: root)
        await sh(["remote", "add", "origin", origin.path], in: work)
        await sh(["push", "-q", "-u", "origin", "main"], in: work)
        for i in 1...2 {
            try? "\(i)\n".write(to: work.appendingPathComponent("c\(i).txt"), atomically: true, encoding: .utf8)
            await sh(["add", "c\(i).txt"], in: work)
            await sh(["commit", "-q", "-m", "커밋 \(i)"], in: work)
        }
        // 업로드가 1초 걸리도록 (pre-push 훅) — 그동안 진행 표시가 이 프로젝트의 것인지 본다. 사용자 전역 훅과 섞이지 않게 지정.
        let hooks = work.appendingPathComponent(".git/hooks")
        try? fm.createDirectory(at: hooks, withIntermediateDirectories: true)
        await sh(["config", "core.hooksPath", hooks.path], in: work)
        let hook = hooks.appendingPathComponent("pre-push")
        try? "#!/bin/sh\nsleep 1\nexit 0\n".write(to: hook, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
        guard (try? await store.bootstrap()) != nil else {
            await t.check("임시 DB 준비", false)
            return
        }
        let model = AppModel(store: store)
        let project = await model.addProject(name: "work", path: work.path)
        _ = await model.addThread(projectID: project.id, title: "sync")
        await model.openWorkspace(path: work.path)
        await t.equal("업로드 전: 앞섬 2", model.workspace.git.map { ChangesState.sync($0) },
                      .ahead(upstream: "origin/main", count: 2))

        // PR 캐시: 화면 확인용 입구도 gh 형식 JSON 을 앱의 해석기로 읽는다 (값을 만들지 않음) · 조회 시각 · 다시 읽어도 캐시
        let prJSON = "{\"number\":42,\"title\":\"t\",\"state\":\"OPEN\",\"isDraft\":false,\"url\":\"https://github.com/o/r/pull/42\","
            + "\"headRefName\":\"main\",\"baseRefName\":\"dev\",\"statusCheckRollup\":[],\"latestReviews\":[]}"
        await t.check("조회 전 PR 은 idle · 조회 시각 없음 → 탭을 열면 조회할 상태",
                      model.workspace.pullRequest == .idle && model.workspace.pullRequestCheckedAt == nil
                      && ChangesState.pullRequestQueryNeeded(model.workspace.pullRequest, status: model.workspace.git))
        let injected = model.workspace.previewUsePullRequest(json: prJSON)
        await model.workspace.refreshGit()
        await t.check("PR 캐시 · 조회 시각 · git 을 다시 읽어도 캐시를 씀 (다시 조회하지 않음)",
                      injected && model.workspace.pullRequest.info?.number == 42 && model.workspace.pullRequestCheckedAt != nil
                      && !ChangesState.pullRequestQueryNeeded(model.workspace.pullRequest, status: model.workspace.git))
        await t.check("잘못된 JSON 은 넣지 않음", !model.workspace.previewUsePullRequest(json: "not json"))

        // ⌘⇧N 요청: 저장소를 읽을 때까지 남겨 두고, 몇 초가 지난 요청은 버린다 (창이 닫혀 있을 때 누른 것이 나중에 열리지 않게)
        let pressed = Date()
        model.requestNewBranch(at: pressed)
        let waits = !model.takeNewBranchRequest(ready: false, now: pressed.addingTimeInterval(0.5))
            && model.newBranchRequestedAt != nil
        let taken = model.takeNewBranchRequest(ready: true, now: pressed.addingTimeInterval(1))
        let once = !model.takeNewBranchRequest(ready: true, now: pressed.addingTimeInterval(1.1))
        model.requestNewBranch(at: pressed)
        let stale = !model.takeNewBranchRequest(ready: true, now: pressed.addingTimeInterval(AppModel.newBranchRequestWindow))
            && model.newBranchRequestedAt == nil
        await t.check("⌘⇧N 요청: 준비될 때까지 남김 · 한 번만 받음 · 오래된 요청은 버림", waits && taken && once && stale)

        // 진행 중: 명령이 도는 동안 이 프로젝트의 원격 명령으로 보인다
        let pushTask = Task { await model.runGit(.push(branch: "main", setUpstream: false), confirmed: true, reportsInline: true) }
        var sawProgress = false
        for _ in 0..<60 {
            if model.runningGitOperation == .push(branch: "main", setUpstream: false),
               model.runningGitProjectPath == project.path {
                sawProgress = ChangesState.syncProgress(model.runningGitOperation!, ahead: model.workspace.git?.ahead,
                                                        upstream: model.workspace.git?.upstream, remoteName: "origin")?.title
                    == "커밋 2개를 올리는 중…"
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let pushed = await pushTask.value
        await t.check("업로드 중: 이 프로젝트의 명령 · '커밋 2개를 올리는 중…'", sawProgress)
        await t.check("끝나면 진행 표시 없음", model.runningGitOperation == nil && model.runningGitProjectPath == nil)

        let record = model.lastGitOutcome
        await t.check("업로드 성공 · 명령 전 앞섬 2 · 뒤 0 · 지금 상태와 같음",
                      pushed && record?.contextBefore?.ahead == 2 && record?.context?.ahead == 0
                      && model.workspace.git.map { ChangesState.recordIsCurrent(recorded: record?.context, now: $0) } == true,
                      "\(String(describing: record?.contextBefore)) → \(String(describing: record?.context))")
        let after = model.workspace.git.map { ChangesState.sync($0) } ?? .noRemote
        let prNumber = ChangesState.pullRequestReceivingPush(model.workspace.pullRequest.info,
                                                             branch: record?.contextBefore?.branch, upstream: after.upstream)
        if let record {
            await t.equal("성공 표시 (PR 캐시 · 명령 전 앞섬 수)",
                          ChangesState.syncSuccess(record.operation, pushedCount: record.contextBefore?.ahead, after: after,
                                                   pullRequest: prNumber, finishedAt: record.finishedAt,
                                                   now: record.finishedAt.addingTimeInterval(1)),
                          ChangesState.SyncSuccess(done: "업로드 완료", title: "origin/main 에 모두 반영됐습니다",
                                                   sub: "PR #42에 커밋 2개가 반영됐습니다 · 방금"))
            await t.check("4초 뒤 평상 상태 ('원격과 같습니다' — 동기화 상태만 보고 git 을 다시 부르지 않음)",
                          ChangesState.syncSuccess(record.operation, pushedCount: 2, after: after, pullRequest: prNumber,
                                                   finishedAt: record.finishedAt,
                                                   now: record.finishedAt.addingTimeInterval(ChangesState.successDisplaySeconds))
                              == nil && after == .inSync(upstream: "origin/main"))
        } else {
            await t.check("업로드 결과 기록", false)
        }
        await store.db.close()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
