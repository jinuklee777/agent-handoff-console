import Foundation

/// 변경사항 탭 머리줄 브랜치 ▾ 팝오버(목업 BranchMenu · BranchSearch)의 **순수 판정**. git 을 부르지 않고 화면도
/// 그리지 않는다. 섹션 구성 · 찾기 일치 · 새 브랜치 행 · 잠금 이유 · ↑↓ 강조 이동을 오프라인 검증("브랜치 메뉴 판정")에서
/// 그대로 확인한다. 화면(`BranchMenuView`)은 이 결과를 그리기만 한다.
///
/// 원칙:
/// - 쓰는 명령은 `GitWrite` 의 기존 두 개뿐이다 — 전환 `git switch <이름>`, 만들기 `git switch -c <이름>`.
///   원격에만 있는 브랜치는 원격 접두어를 뗀 이름으로 `git switch` 한다. 그 이름이 원격 하나에만 있으면 git 이
///   그 원격 브랜치를 추적하는 로컬 브랜치를 만들어 전환한다 (git 기본 동작 `--guess`, 새 명령이 아니다).
///   같은 짧은 이름이 여러 원격에 있으면 그 행들은 잠근다 — git 은 보통 거부하지만(`matched multiple remote tracking
///   branches`) `checkout.defaultRemote` 가 있으면 그 원격을 추적해, 누른 행과 다른 원격 브랜치를 따라갈 수 있다
///   (2026-09-13 Apple Git 2.50 실측). 터미널의 `git switch --track <원격>/<이름>` 을 안내한다.
/// - 앱은 브랜치마다 어느 에이전트가 작업했는지 기록하지 않는다. 에이전트 표시는 현재 브랜치 행에만 (이 스레드의 에이전트).
/// - 병합 · rebase 중이면 git 이 전환 · 만들기를 거부하고, 충돌 파일만 남아 있으면(`stash pop` 충돌 등) 다른 브랜치로의
///   전환만 거부한다 — 새 브랜치 만들기(`switch -c`)는 git 이 허용한다 (2026-09-13 Apple Git 2.50 · Homebrew git 2.42 실측:
///   "cannot switch branch while merging" · "… while rebasing" · "you need to resolve your current index first").
///   그래서 git 이 거부하는 행만 미리 잠그고 이유를 적는다.
/// - 목록은 섹션마다 `listLimit`(찾기 결과는 `matchLimit`)개까지만 그린다. 원격 브랜치가 수천 개여도 팝오버가 가볍게
///   열리게 — 나머지는 개수만 적고 찾기로 좁히게 한다.
enum BranchMenu {

    // MARK: - 행

    /// 찾는 글자와 일치한 부분 (표시 이름 기준, 대소문자 무시 첫 일치).
    struct Highlight: Equatable, Sendable {
        var before: String
        var match: String
        var after: String
    }

    struct Item: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// 지금 브랜치 (체크 표시). 실행할 것이 없다.
            case current
            /// 브랜치가 아닌 커밋을 보고 있다 (`HEAD a41c9e2`). 실행할 것이 없다.
            case detached
            /// 로컬 브랜치 — `git switch <이름>`.
            case local
            /// 원격에만 있는 브랜치 — `git switch <접두어를 뗀 이름>`.
            case remoteOnly(remote: String)
            /// 새 브랜치 — `git switch -c <이름>`.
            case create
        }

        var kind: Kind
        /// 화면에 쓰는 이름 (원격은 접두어를 뗀 이름, 새 브랜치는 입력한 이름).
        var name: String
        /// 원격 브랜치 전체 이름 (`origin/release/2.4`). 원격 행만.
        var fullName: String?
        var ahead: Int?
        var behind: Int?
        /// 마지막 커밋 시각 (`%(committerdate:unix)`), 못 읽었으면 git 의 상대 시각 글자.
        var committedAt: Date?
        var committerDate: String?
        var highlight: Highlight?
        /// 누를 수 없는 이유. nil 이면 ↑↓ · ↵ · 누르기로 실행할 수 있다 (현재 · 떼어진 HEAD 행은 원래 실행할 것이 없다).
        var disabledReason: String?

        var id: String {
            switch kind {
            case .current, .detached: return "current"
            case .local: return "local:\(name)"
            case .remoteOnly: return "remote:\(fullName ?? name)"
            // 입력이 바뀌어도 같은 행으로 본다 (강조가 새 브랜치 행에 머문다).
            case .create: return "create"
            }
        }

        /// 실행할 수 있는 행 (전환 · 만들기이고 잠기지 않음).
        var isSelectable: Bool {
            guard disabledReason == nil else { return false }
            switch kind {
            case .local, .remoteOnly, .create: return true
            case .current, .detached: return false
            }
        }
    }

    struct Section: Equatable, Sendable {
        enum Kind: Hashable, Sendable { case current, recent, remoteOnly, matches }
        var kind: Kind
        var items: [Item]
        /// 제목 오른쪽 흐린 글자 — 원격에만 있는 브랜치가 모두 한 원격이면 그 이름, 일치하는 브랜치면 그 수(전부).
        var trailing: String?
        /// 그리지 않고 남긴 행 수 (`listLimit` · `matchLimit` 을 넘은 것).
        var hidden = 0

        /// 목록 끝의 "n개 더" 한 줄. 남긴 것이 없으면 nil.
        var moreText: String? {
            guard hidden > 0 else { return nil }
            return kind == .matches ? "\(hidden)개 더 · 이름을 더 입력해 좁히세요" : "\(hidden)개 더 · 찾기로 좁히세요"
        }

        var title: String {
            switch kind {
            case .current: return "현재 브랜치"
            case .recent: return "최근 브랜치"
            case .remoteOnly: return "원격에만 있는 브랜치"
            case .matches: return "일치하는 브랜치"
            }
        }
    }

    /// 목록(`browse`) 또는 새 이름 입력(`create`, "새 브랜치 만들기…" · ⌘⇧N).
    enum Mode: Equatable, Sendable { case browse, create }

    struct Content: Equatable, Sendable {
        /// 찾는 이름이 없을 때 맨 위의 "새 브랜치 <이름> 만들기". 없으면 nil.
        var create: Item?
        var sections: [Section]
        /// 원격 브랜치 목록을 읽지 못했다 ("원격에만 있는 브랜치" 가 없다고 말하지 않는다).
        var remoteListUnknown = false
        /// 새 이름 입력 상태에서 아직 아무것도 치지 않았다 (목록 대신 안내 한 줄).
        var awaitingName = false
        /// 찾는 이름과 **정확히 같은** 이름의 행 (지금 브랜치 포함, 없으면 대소문자만 다른 행). 처음 강조를 정할 때 쓴다.
        var exactID: String?
        /// 원격에만 있는 브랜치가 여러 원격에 걸쳐 있다 (행마다 원격 이름을 적는다).
        var multipleRemotes = false

        /// ↑↓ · ↵ 로 고를 수 있는 행 (위에서 아래 순서).
        var selectableIDs: [String] {
            allItems.filter(\.isSelectable).map(\.id)
        }

        /// 보이는 모든 행 (막힌 행 포함).
        var allIDs: [String] { allItems.map(\.id) }

        private var allItems: [Item] { (create.map { [$0] } ?? []) + sections.flatMap(\.items) }

        func item(id: String?) -> Item? {
            guard let id else { return nil }
            if create?.id == id { return create }
            return sections.lazy.flatMap(\.items).first { $0.id == id }
        }
    }

    // MARK: - 잠금

    /// 전환 · 만들기를 할 수 없는 이유. 잠금(에이전트 실행 중 등)이 먼저 — 그것이 풀려도 병합 중이면 다음 이유가 보인다.
    enum Block: Equatable, Sendable {
        /// 독립 작업 폴더에서 일하는 대화 — 그 대화의 브랜치(`ahc/…`)에서 일하고 프로젝트 폴더로 합친다. 브랜치를 바꾸면 합치기 칸이
        /// 바뀐 브랜치의 커밋을 보지 못한다 (chg-16). 전환 · 만들기를 모두 막는다.
        case worktreeConversation(branch: String)
        case locked(ChangesState.Lock)
        case merging
        case rebasing
        /// 충돌 파일만 남음 (병합 · rebase 아님). git 은 다른 브랜치로의 전환만 거부한다.
        case conflicts(Int)

        /// 새 브랜치 만들기(`git switch -c`)도 막는지. 충돌만 남은 상태에서는 git 이 만들기를 허용한다 (실측).
        var blocksCreate: Bool {
            if case .conflicts = self { return false }
            return true
        }
    }

    static func block(lock: ChangesState.Lock?, merging: Bool, rebasing: Bool, conflicts: Int,
                      worktreeBranch: String? = nil) -> Block? {
        if let worktreeBranch { return .worktreeConversation(branch: worktreeBranch) }
        if let lock { return .locked(lock) }
        if rebasing { return .rebasing }
        if merging { return .merging }
        if conflicts > 0 { return .conflicts(conflicts) }
        return nil
    }

    static func blockText(_ block: Block) -> String {
        blockText(block, backgroundTasks: 0)
    }

    /// `backgroundTasks` 는 이 폴더의 실행이 메인 턴을 마치고 기다리는 백그라운드 작업 수 (변경사항 탭과 같은 말로 덧붙인다).
    static func blockText(_ block: Block, backgroundTasks: Int) -> String {
        switch block {
        case .worktreeConversation(let branch):
            return "독립 작업 폴더에서는 브랜치를 바꾸지 않습니다 — 이 대화의 브랜치 \(branch) 에서 일하고, "
                + "변경사항 탭 위 칸에서 프로젝트 폴더로 합치세요."
        case .locked(let lock):
            return ChangesState.lockText(lock, action: "전환할", backgroundTasks: backgroundTasks)
        case .merging:
            return "병합이 진행 중이라 git 이 브랜치를 바꾸지 않습니다. 병합을 마무리하거나 멈춘 뒤 전환하세요."
        case .rebasing:
            return "rebase 가 진행 중이라 git 이 브랜치를 바꾸지 않습니다. 터미널에서 rebase 를 마친 뒤 전환하세요."
        case .conflicts(let n):
            return "충돌 파일 \(n)개가 남아 있어 git 이 다른 브랜치로 전환하지 않습니다. 충돌을 해결한 뒤 전환하세요. "
                + "새 브랜치는 만들 수 있습니다 (충돌 파일도 함께 옮겨집니다)."
        }
    }

    // MARK: - 구성

    /// 팝오버 내용. 찾는 글자가 없으면 현재 · 최근(마지막 커밋 순) · 원격에만 있는 브랜치,
    /// 있으면 새 브랜치 행(필요할 때) + 일치하는 브랜치 (로컬 먼저, 그다음 원격 — 각각 최근 순).
    static func content(status: GitWorkspaceStatus, query: String, mode: Mode = .browse, block: Block?,
                        backgroundTasks: Int = 0) -> Content {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = block.map { blockText($0, backgroundTasks: backgroundTasks) }
        let remoteOnly = ChangesState.remoteOnlyBranches(status.remoteBranches, local: status.localBranches)
        let remoteListUnknown = !status.remoteBranchesRead && status.remotes?.isEmpty != true

        var current: Item?
        if let branch = status.branch {
            let info = status.localBranches.first { $0.name == branch }
            current = Item(kind: .current, name: branch, ahead: status.ahead, behind: status.behind,
                           committedAt: info?.committedAt, committerDate: info?.committerDate)
        } else if let label = status.headLabel {
            current = Item(kind: .detached, name: label)
        }
        let locals = status.localBranches.filter { $0.name != status.branch }.map { branch in
            Item(kind: .local, name: branch.name, ahead: branch.ahead, behind: branch.behind,
                 committedAt: branch.committedAt, committerDate: branch.committerDate,
                 disabledReason: reason ?? status.worktreeBranches[branch.name].map(otherWorktreeReason))
        }
        // 같은 짧은 이름이 여러 원격에 있으면 앱이 어느 원격을 따라갈지 정할 수 없다 (위 설명).
        let remoteNamesByBranch = Dictionary(grouping: remoteOnly, by: \.name).mapValues { $0.map(\.remote) }
        let remotes = remoteOnly.map { remote in
            Item(kind: .remoteOnly(remote: remote.remote), name: remote.name, fullName: remote.fullName,
                 committedAt: remote.committedAt, committerDate: remote.committerDate,
                 disabledReason: reason ?? ambiguousRemoteReason(remote, remotes: remoteNamesByBranch[remote.name] ?? []))
        }
        let multipleRemotes = Set(remoteOnly.map(\.remote)).count > 1

        if q.isEmpty {
            if mode == .create {
                return Content(create: nil, sections: [], remoteListUnknown: remoteListUnknown, awaitingName: true,
                               multipleRemotes: multipleRemotes)
            }
            var sections: [Section] = []
            if let current { sections.append(Section(kind: .current, items: [current])) }
            if !locals.isEmpty {
                sections.append(Section(kind: .recent, items: Array(locals.prefix(listLimit)),
                                        hidden: max(locals.count - listLimit, 0)))
            }
            if !remotes.isEmpty {
                sections.append(Section(kind: .remoteOnly, items: Array(remotes.prefix(listLimit)),
                                        trailing: multipleRemotes ? nil : remoteOnly.first?.remote,
                                        hidden: max(remotes.count - listLimit, 0)))
            }
            return Content(create: nil, sections: sections, remoteListUnknown: remoteListUnknown,
                           multipleRemotes: multipleRemotes)
        }

        func matched(_ item: Item) -> Item? {
            let inName = highlight(item.name, query: q)
            guard inName != nil || item.fullName.map({ highlight($0, query: q) != nil }) == true else { return nil }
            var out = item
            out.highlight = inName ?? item.fullName.flatMap { highlight(name: item.name, inFullName: $0, query: q) }
            return out
        }
        let matches = ((current.map { [$0] } ?? []) + locals).compactMap(matched) + remotes.compactMap(matched)
        let existing = status.localBranches.map(\.name) + remoteOnly.map(\.name)
        var create: Item?
        if let name = newBranchName(query: q, local: status.localBranches, remoteOnly: remoteOnly) {
            create = Item(kind: .create, name: name,
                          disabledReason: (block?.blocksCreate == true ? reason : nil)
                              ?? nameProblem(name, remote: status.remoteBranches, existing: existing))
        }
        // 정확히 같은 이름이 먼저, 없으면 대소문자만 다른 이름 (그 행을 강조해 새 브랜치 행으로 가지 않게).
        let exact = matches.first { $0.name == q }
            ?? matches.first { $0.name.compare(q, options: .caseInsensitive) == .orderedSame }
        // 많으면 앞의 `matchLimit` 개만 그린다. 정확히 같은 행은 잘리더라도 남긴다 (↵ 가 그 행을 고른다).
        var shown = Array(matches.prefix(matchLimit))
        if let exact, !shown.contains(where: { $0.id == exact.id }) { shown[shown.count - 1] = exact }
        let sections = matches.isEmpty ? [] : [Section(kind: .matches, items: shown, trailing: "\(matches.count)",
                                                       hidden: matches.count - shown.count)]
        return Content(create: create, sections: sections, remoteListUnknown: remoteListUnknown,
                       exactID: exact?.id, multipleRemotes: multipleRemotes)
    }

    /// 섹션마다 그리는 행 수 (찾지 않을 때). 넘으면 "n개 더 · 찾기로 좁히세요".
    static let listLimit = 50
    /// 찾기 결과로 그리는 행 수.
    static let matchLimit = 100

    /// 다른 git worktree 가 쓰는 로컬 브랜치를 잠그는 이유 — git 이 그 브랜치로 전환하지 않는다 (chg-16). 앱이 대화마다 만든 독립 작업
    /// 폴더의 브랜치(`ahc/…`)가 대개 이것이다.
    static func otherWorktreeReason(_ path: String) -> String {
        "다른 git worktree(\((path as NSString).abbreviatingWithTildeInPath))가 쓰는 브랜치라 git 이 전환하지 않습니다. "
            + "앱이 만든 독립 작업 폴더의 브랜치면 그 대화의 변경사항 탭에서 합치거나 정리하세요."
    }

    /// 같은 짧은 이름이 여러 원격에 있을 때 그 행을 잠그는 이유. 하나뿐이면 nil.
    static func ambiguousRemoteReason(_ branch: GitRemoteBranch, remotes: [String]) -> String? {
        guard remotes.count > 1 else { return nil }
        return "같은 이름(\(branch.name))의 브랜치가 \(remotes.joined(separator: " · ")) 에 있어 앱에서 전환하지 않습니다 "
            + "(git 이 거부하거나 설정에 따라 다른 원격을 따라갑니다). "
            + "터미널에서 골라 전환하세요: git switch --track \(branch.fullName)"
    }

    /// 행 오른쪽 원격 표시. 찾는 중이면 "원격" 태그(여러 원격이면 "원격 · team"), 목록에서는 여러 원격일 때만 원격 이름
    /// (한 원격이면 섹션 제목 오른쪽에 한 번). 원격 행이 아니면 nil.
    static func remoteLabel(_ item: Item, searching: Bool, multipleRemotes: Bool) -> String? {
        guard case .remoteOnly(let remote) = item.kind else { return nil }
        if searching { return multipleRemotes ? "원격 · \(remote)" : "원격" }
        return multipleRemotes ? remote : nil
    }

    /// 표시 이름에서 찾는 글자와 일치한 부분 (대소문자 무시, 첫 일치). 없거나 찾는 글자가 비었으면 nil.
    static func highlight(_ name: String, query: String) -> Highlight? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let range = name.range(of: q, options: .caseInsensitive) else { return nil }
        return Highlight(before: String(name[..<range.lowerBound]), match: String(name[range]),
                         after: String(name[range.upperBound...]))
    }

    /// 원격 전체 이름(`origin/release/2.4`)으로만 일치했을 때, 그 일치가 표시 이름(`release/2.4`)에 걸친 부분.
    /// 원격 이름(`origin/`)에만 걸쳤으면 nil.
    static func highlight(name: String, inFullName fullName: String, query: String) -> Highlight? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, fullName.hasSuffix(name), let range = fullName.range(of: q, options: .caseInsensitive) else {
            return nil
        }
        let nameStart = fullName.index(fullName.endIndex, offsetBy: -name.count)
        let lower = max(range.lowerBound, nameStart)
        guard lower < range.upperBound else { return nil }
        let a = name.index(name.startIndex, offsetBy: fullName.distance(from: nameStart, to: lower))
        let b = name.index(name.startIndex, offsetBy: fullName.distance(from: nameStart, to: range.upperBound))
        return Highlight(before: String(name[..<a]), match: String(name[a..<b]), after: String(name[b...]))
    }

    /// 새 브랜치 행에 쓸 이름. 찾는 이름과 **정확히 같은** 로컬 브랜치나 원격에만 있는 브랜치(접두어를 뗀 이름)가
    /// 있으면 nil — 그 행이 일치 목록에 있다. 대소문자는 git 처럼 구분한다. 빈 글자면 nil.
    static func newBranchName(query: String, local: [GitBranchInfo], remoteOnly: [GitRemoteBranch]) -> String? {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if local.contains(where: { $0.name == name }) || remoteOnly.contains(where: { $0.name == name }) { return nil }
        return name
    }

    /// 새 브랜치 이름으로 쓸 수 없는 이유. 쓸 수 있으면 nil. 쓸 수 있는지는 `GitWrite.validateBranchName` 이
    /// 정하고(명령을 만들 때와 같은 검사), 여기서는 어느 규칙에 걸렸는지 사람 말로 옮긴다. 원격 브랜치의 전체
    /// 이름(`origin/main`)과 같으면 쓰지 않는다 — git 이 그 이름을 원격 브랜치와 헷갈린다 (ambiguous refname).
    /// 있는 브랜치(`existing`: 로컬 · 원격에만 있는 짧은 이름)와 대소문자만 다르면 쓰지 않는다 — macOS 기본 파일 시스템은
    /// 대소문자를 가리지 않아 git 이 두 이름을 같은 브랜치 파일로 다룬다 (`Main` 에 커밋하면 `main` 도 움직임 — 실측).
    static func nameProblem(_ name: String, remote: [GitRemoteBranch] = [], existing: [String] = []) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard (try? GitWrite.validateBranchName(trimmed)) != nil else {
            let rule: String
            if trimmed.isEmpty { rule = "이름이 비어 있습니다" }
            else if trimmed.count > 200 { rule = "200자까지 쓸 수 있습니다" }
            else if trimmed.range(of: #"\s"#, options: .regularExpression) != nil { rule = "공백을 쓸 수 없습니다" }
            else if trimmed.hasPrefix("-") { rule = "- 로 시작할 수 없습니다" }
            else if trimmed.hasPrefix("/") || trimmed.hasSuffix("/") { rule = "/ 로 시작하거나 끝날 수 없습니다" }
            else if trimmed.contains("//") { rule = "/ 를 겹쳐 쓸 수 없습니다" }
            else if trimmed.hasSuffix(".lock") { rule = ".lock 으로 끝날 수 없습니다" }
            else if trimmed.contains("..") { rule = ".. 을 쓸 수 없습니다" }
            else if trimmed == "@" || trimmed.contains("@{") { rule = "@ 하나나 @{ 는 쓸 수 없습니다" }
            else if trimmed.range(of: #"[~^:?*\[\\]"#, options: .regularExpression) != nil {
                rule = "~ ^ : ? * [ \\ 는 쓸 수 없습니다"
            } else { rule = "쓸 수 없는 글자가 있습니다" }
            return "브랜치 이름으로 쓸 수 없습니다 — \(rule)."
        }
        if let same = remote.first(where: { $0.fullName == trimmed }) {
            return "원격 브랜치(\(same.fullName))와 이름이 같습니다. 다른 이름을 쓰세요."
        }
        if let other = existing.first(where: { $0 != trimmed && $0.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
            return "대소문자만 다른 브랜치(\(other))가 있습니다. macOS 기본 파일 시스템에서는 같은 이름으로 다뤄집니다."
        }
        return nil
    }

    // MARK: - 강조 · 실행

    /// 처음 강조할 행. 찾는 이름과 정확히 같은 행이 있으면 그 행 — 그것이 지금 브랜치(실행할 것 없음)면 강조하지 않는다
    /// (지금 브랜치 이름을 치고 ↵ 를 눌러 다른 브랜치로 가지 않도록). 없으면 고를 수 있는 첫 행.
    static func defaultHighlight(_ content: Content) -> String? {
        let selectable = content.selectableIDs
        if let exact = content.exactID { return selectable.contains(exact) ? exact : nil }
        return selectable.first
    }

    /// ↑(-1) ↓(+1). 끝에서는 멈춘다 (한 바퀴 돌지 않는다). 강조가 없거나 목록에 없으면 ↓ 는 첫 행, ↑ 는 마지막 행.
    static func moveHighlight(_ current: String?, by delta: Int, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return delta >= 0 ? ids.first : ids.last
        }
        return ids[min(max(index + delta, 0), ids.count - 1)]
    }

    /// 목록이 바뀌었을 때 (git 상태를 다시 읽음 · 잠김 · 잠금이 풀림) 그 행이 아직 있으면 강조를 유지, 없어졌으면 기본값.
    /// 전환 명령이 도는 동안 잠깐 막힌 행도 유지한다 — 실패한 뒤 ↵ 를 다시 누르면 같은 행을 다시 실행해야 한다
    /// (기본값으로 튀면 찾던 글자로 새 브랜치를 만들 수 있다). 막힌 동안에는 강조를 그리지 않고 ↵ 도 아무 일을 하지 않는다.
    static func reconcileHighlight(_ current: String?, in content: Content) -> String? {
        if let current, content.allIDs.contains(current) { return current }
        return defaultHighlight(content)
    }

    /// 행을 실행하는 명령. 현재 · 떼어진 HEAD · 잠긴 행은 nil.
    static func operation(for item: Item) -> GitWrite.Operation? {
        guard item.isSelectable else { return nil }
        switch item.kind {
        case .local, .remoteOnly: return .switchBranch(item.name)
        case .create: return .createBranch(item.name)
        case .current, .detached: return nil
        }
    }

    // MARK: - 문구

    /// 행 오른쪽 메타: "↑1 · 3일 전", "↑2", "5일 전" (시각은 앱의 상대 시각 `ChangesState.commitTime`).
    /// 모르는 값은 쓰지 않는다. 현재 브랜치는 원격과의 차이만 (목업 "↑2").
    static func meta(_ item: Item, now: Date = Date()) -> String {
        var arrows: [String] = []
        if let ahead = item.ahead, ahead > 0 { arrows.append("↑\(ahead)") }
        if let behind = item.behind, behind > 0 { arrows.append("↓\(behind)") }
        var parts = arrows.isEmpty ? [] : [arrows.joined(separator: " ")]
        if item.kind != .current, let time = ChangesState.commitTime(item.committedAt, fallback: item.committerDate, now: now) {
            parts.append(time)
        }
        return parts.joined(separator: " · ")
    }

    /// 새 브랜치 행 둘째 줄: "feature/login 에서 시작 · 변경 파일 4개 함께 이동".
    static func createDetail(from headLabel: String?, changeCount: Int) -> String {
        let start = headLabel.map { "\($0) 에서 시작" } ?? "지금 커밋에서 시작"
        return changeCount > 0 ? "\(start) · 변경 파일 \(changeCount)개 함께 이동" : start
    }

    /// 새 이름 입력 상태에서 아직 치지 않았을 때의 둘째 줄. git 이 만들기를 거부하는 동안(병합 · rebase 중)에는 옮길 것을
    /// 말하지 않는다 (`carryNote` 와 같은 기준 — 맨 위의 이유와 어긋나지 않게).
    static func awaitingDetail(from headLabel: String?, changeCount: Int, block: Block?) -> String {
        switch block {
        case .merging?, .rebasing?, .worktreeConversation?: return createDetail(from: headLabel, changeCount: 0)
        case .locked?, .conflicts?, nil: return createDetail(from: headLabel, changeCount: changeCount)
        }
    }

    /// 바닥 안내 첫 줄 (git switch 의 실제 동작). 변경 파일이 없으면 옮길 것이 없어 nil (줄을 숨긴다).
    /// 병합 · rebase 중이거나 충돌이 남아 git 이 전환 자체를 거부하는 동안에도 nil — 맨 위의 이유와 어긋나지 않게.
    /// (에이전트 실행 중 잠금은 끝나면 풀리므로 그대로 둔다.)
    static func carryNote(changeCount: Int, block: Block? = nil) -> String? {
        switch block {
        case .merging?, .rebasing?, .conflicts?, .worktreeConversation?: return nil
        case .locked?, nil: break
        }
        guard changeCount > 0 else { return nil }
        return "변경 파일 \(changeCount)개는 전환한 브랜치로 함께 옮겨집니다. 겹치는 파일이 있으면 전환하지 않고 알려드립니다."
    }

    /// 바닥 안내 둘째 줄 — 앱이 하지 않는 일. 독립 작업 폴더의 합치기 · 정리는 앱이 한다 (변경사항 탭 위 칸) — 그것과 어긋나지 않게
    /// 범위를 밝힌다 (txt-5).
    static let notByApp = "다른 브랜치 합치기 · 되돌리기 · 강제 업로드 · 브랜치 삭제는 앱이 하지 않습니다 "
        + "(독립 작업 폴더의 합치기 · 정리만 앱이 합니다). 터미널에서 직접 하세요."

    /// 키 안내의 ↵ 뒤 글자. 강조한 행이 없으면 nil.
    static func returnLabel(_ item: Item?) -> String? {
        guard let item, item.isSelectable else { return nil }
        return item.kind == .create ? "만들고 전환" : "전환"
    }

    /// 행 도움말 (실행할 git 명령과 그 동작).
    static func help(_ item: Item) -> String {
        if let reason = item.disabledReason { return reason }
        switch item.kind {
        case .current:
            return "지금 브랜치입니다."
        case .detached:
            return "브랜치가 아닌 커밋을 보고 있습니다. 새 브랜치를 만들면 여기서 시작합니다."
        case .local:
            return "git switch \(item.name) — 변경 파일은 함께 옮겨지고, 겹치면 git 이 전환하지 않습니다."
        case .remoteOnly:
            return "git switch \(item.name) — 원격 브랜치(\(item.fullName ?? item.name))를 추적하는 로컬 브랜치를 만들어 전환합니다."
        case .create:
            return "git switch -c \(item.name) — 지금 커밋에서 새 브랜치를 만들어 전환합니다."
        }
    }
}
