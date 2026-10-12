import Foundation

/// 변경사항 탭(인스펙터)이 쓰는 **순수 판정**. git 을 부르지 않고 화면도 그리지 않는다.
/// 입력은 `GitWorkspaceStatus` 와 앱 상태 값뿐이라 오프라인 검증(`WorkspaceTests` "변경사항 탭 판정")에서
/// 그대로 확인한다. 화면(`ChangesPane`)은 이 결과를 그리기만 한다.
///
/// 원칙: 모르는 값은 만들지 않는다 — 줄 수를 모르면 nil("—"), 앞섬/뒤처짐을 모르면 숫자를 쓰지 않는다.
enum ChangesState {

    // MARK: - 파일 행

    /// 커밋에 들어가는지. 체크박스 = 스테이지.
    enum Inclusion: String, Sendable {
        /// 변경이 모두 인덱스에 있다 → 커밋하면 파일 전체가 들어간다.
        case on
        /// 인덱스와 작업 트리 양쪽에 변경이 있다 → 일부만 들어간다 ("일부 포함됨").
        case mixed
        /// 작업 트리에만 있다 (새 파일 포함).
        case off
        /// 병합 충돌. 체크할 수 없다.
        case conflict
    }

    /// 경로 하나 = 행 하나 (staged · unstaged · untracked · conflicted 를 합친다).
    struct Row: Identifiable, Hashable, Sendable {
        var id: String { path }
        /// 저장소 루트 기준.
        var path: String
        /// 이름 변경 전 경로.
        var originalPath: String?
        /// 마지막 커밋 대비 파일 전체를 나타내는 한 글자 (M A D R C T U).
        var code: String
        var inclusion: Inclusion
        /// git 이 아직 추적하지 않는 새 파일 (코드는 A 로 보인다).
        var isUntracked = false
        /// 코드 한 글자로는 드러나지 않는 사실 (코드 도움말). 없으면 nil.
        var codeNote: String?
        /// 마지막 커밋 대비 줄 수. 모르면 nil (화면 "—").
        var added: Int?
        var removed: Int?

        var fileName: String { (path as NSString).lastPathComponent }
        var directory: String { (path as NSString).deletingLastPathComponent }
        var isCheckable: Bool { inclusion != .conflict }
        var isIncluded: Bool { inclusion == .on || inclusion == .mixed }
    }

    /// 툴바의 "변경 N +a −d" — 인스펙터를 닫아 두었을 때 (`ContentView` 의 `ChangesPill`).
    struct Summary: Equatable, Sendable {
        /// 바뀐 파일 수 (변경사항 탭의 행 수).
        var files: Int
        var added: Int
        var removed: Int
        /// 줄 수를 모르는 파일 수 (바이너리 등). 합은 아는 파일만이다.
        var unknownLines: Int
        var conflicts: Int
    }

    /// 저장소가 아니거나 상태를 읽지 못했거나 바뀐 파일이 없으면 nil. 줄 수는 변경사항 탭의 행과 같은 값(마지막 커밋 대비,
    /// 새 파일은 직접 센 값)을 더한다.
    static func summary(of status: GitWorkspaceStatus?) -> Summary? {
        guard let status, status.isRepository, status.error == nil else { return nil }
        let rows = rows(from: status)
        guard !rows.isEmpty else { return nil }
        var summary = Summary(files: rows.count, added: 0, removed: 0, unknownLines: 0, conflicts: 0)
        for row in rows {
            if let added = row.added, let removed = row.removed {
                summary.added += added
                summary.removed += removed
            } else {
                summary.unknownLines += 1
            }
            if row.inclusion == .conflict { summary.conflicts += 1 }
        }
        return summary
    }

    /// 경로별로 한 행. 충돌 먼저, 그다음 경로 순 (숫자는 자연 순서). 목업 순서를 흉내 내지 않는다.
    static func rows(from status: GitWorkspaceStatus) -> [Row] {
        var staged: [String: GitFileChange] = [:]
        for change in status.staged { staged[change.path] = change }
        var unstaged: [String: GitFileChange] = [:]
        for change in status.unstaged { unstaged[change.path] = change }
        var untracked: [String: GitFileChange] = [:]
        for change in status.untracked { untracked[change.path] = change }
        var conflicted: [String: GitFileChange] = [:]
        for change in status.conflicted { conflicted[change.path] = change }

        let paths = Set(staged.keys).union(unstaged.keys).union(untracked.keys).union(conflicted.keys)
        var out: [Row] = []
        out.reserveCapacity(paths.count)
        for path in paths {
            let head = status.headLineCounts[path]
            if let change = conflicted[path] {
                out.append(Row(path: path, originalPath: change.originalPath, code: "U", inclusion: .conflict,
                               added: head?.added, removed: head?.removed))
                continue
            }
            let s = staged[path], u = unstaged[path], n = untracked[path]
            // `git rm --cached` (추적 중지): 인덱스에서는 지웠고 파일은 디스크에 새 파일로 남았다.
            // 커밋하면 저장소에서 빠진다 → 그 삭제가 이미 포함된 상태(on). 체크를 끄면 추적이 되돌아온다.
            // 전체 선택이 `git add` 로 추적 중지를 몰래 되돌리지 않도록 일부 포함(mixed)으로 두지 않는다.
            let untracks = s?.code == "D" && u == nil && n != nil
            let inclusion: Inclusion
            if untracks {
                inclusion = .on
            } else if s != nil && (u != nil || n != nil) {
                inclusion = .mixed
            } else if s != nil {
                inclusion = .on
            } else {
                inclusion = .off
            }
            // 줄 수: 추적 파일은 `git diff HEAD` (파일 전체), 새 파일은 직접 센 값. 둘 다 없으면 모름.
            var lines = head
            if lines == nil, s == nil, u == nil, let n {
                lines = GitLineCount(added: n.added, removed: n.removed)
            }
            let isUntracked = s == nil && u == nil && n != nil
            var note: String?
            if untracks {
                note = "추적 중지 — 커밋하면 저장소에서 빠집니다. 디스크의 파일은 그대로 남습니다."
            } else if s?.code == "A" && u?.code == "D" {
                note = "새 파일로 추가해 두었지만 디스크에서는 지워졌습니다."
            } else if isUntracked {
                note = "새 파일 · git 이 아직 추적하지 않음"
            }
            out.append(Row(path: path, originalPath: s?.originalPath ?? u?.originalPath,
                           code: representativeCode(staged: s?.code, unstaged: u?.code, untracked: n != nil),
                           inclusion: inclusion, isUntracked: isUntracked, codeNote: note,
                           added: lines?.added, removed: lines?.removed))
        }
        return out.sorted { a, b in
            let ac = a.inclusion == .conflict, bc = b.inclusion == .conflict
            if ac != bc { return ac }
            let order = a.path.localizedStandardCompare(b.path)
            return order == .orderedSame ? a.path < b.path : order == .orderedAscending
        }
    }

    /// 마지막 커밋과 비교한 파일 전체의 상태 한 글자.
    /// `AM` → A, `MM` → M, `RM` → R, ` D`/`D ` → D, `MD` → D, 새 파일(`??`) → A.
    /// `D ` + 같은 경로 새 파일(`git rm --cached`) → D (커밋이 하는 일: 저장소에서 뺀다),
    /// `AD` → A (마지막 커밋에 없던 파일이라 "지움" 이 아니다 — 인덱스에 추가된 채 디스크에서만 지워졌다).
    static func representativeCode(staged: String?, unstaged: String?, untracked: Bool) -> String {
        if unstaged == "D" {
            // 작업 트리에서 지워졌으면 지금 파일이 없다. 단 마지막 커밋에도 없던 새 파일이면 지운 것이 아니다.
            return staged == "A" ? "A" : "D"
        }
        if let staged {
            return staged
        }
        if let unstaged { return unstaged }
        return untracked ? "A" : "M"
    }

    // MARK: 체크 → 실행할 명령

    /// 행 체크박스를 눌렀을 때. 꺼짐·일부 → 파일 전체 스테이지, 켜짐 → 스테이지 해제.
    /// 이름 변경은 원래 경로도 함께 되돌려야 인덱스가 마지막 커밋 상태로 돌아간다.
    ///
    /// `merging`(MERGE_HEAD 가 있음)이면 스테이지 해제를 하지 않는다 — 병합 중 인덱스에 있는 것은 합쳐진 결과라,
    /// 빼고 커밋하면 병합 커밋이 그 파일의 합쳐진 변경 없이 기록되는데도 git 은 상대 브랜치를 합친 것으로 본다.
    static func toggleOperation(for row: Row, merging: Bool = false) -> GitWrite.Operation? {
        switch row.inclusion {
        case .conflict: return nil
        case .off, .mixed: return .stage([row.path])
        case .on: return merging ? nil : .unstage([row.path] + (row.originalPath.map { [$0] } ?? []))
        }
    }

    /// 전체 선택: 포함되지 않은 변경(작업 트리 · 새 파일)을 모두 스테이지. 할 것이 없으면 nil.
    static func selectAllOperation(_ rows: [Row]) -> GitWrite.Operation? {
        let paths = rows.filter { $0.inclusion == .off || $0.inclusion == .mixed }.map(\.path)
        return paths.isEmpty ? nil : .stage(paths)
    }

    /// 선택 해제: 스테이지된 것을 모두 되돌린다 (작업 트리의 파일은 그대로). 할 것이 없으면 nil.
    static func deselectAllOperation(_ rows: [Row]) -> GitWrite.Operation? {
        var seen = Set<String>()
        var paths: [String] = []
        for row in rows where row.isIncluded {
            for path in [row.path] + (row.originalPath.map { [$0] } ?? []) where seen.insert(path).inserted {
                paths.append(path)
            }
        }
        return paths.isEmpty ? nil : .unstage(paths)
    }

    /// 머리 체크박스: 모두 켜짐 → on, 하나도 포함 안 됨 → off, 그 밖 mixed. 체크할 행이 없으면 off.
    /// 충돌 행은 포함되지 않은 행으로 센다 — 옆의 "n개 중 m개 포함" 과 같은 말을 한다.
    static func headerState(_ rows: [Row]) -> Inclusion {
        if !rows.contains(where: \.isCheckable) { return .off }
        if rows.allSatisfy({ $0.inclusion == .on }) { return .on }
        if !rows.contains(where: \.isIncluded) { return .off }
        return .mixed
    }

    /// 머리 체크박스를 눌렀을 때. 켜짐 → 모두 빼기, 그 밖 → 포함 안 된 것을 모두 넣기.
    /// 넣을 것이 없으면 (나머지가 충돌뿐) 빼기로 — 누른 것이 아무 일도 하지 않게 두지 않는다.
    /// 병합 중에는 빼기를 하지 않는다 (`toggleOperation(for:merging:)` 과 같은 이유) — 넣을 것이 없으면 nil.
    static func headerToggleOperation(_ rows: [Row], merging: Bool = false) -> GitWrite.Operation? {
        if merging { return selectAllOperation(rows) }
        if headerState(rows) == .on { return deselectAllOperation(rows) }
        return selectAllOperation(rows) ?? deselectAllOperation(rows)
    }

    /// "n개 중 m개 포함" 의 m. 일부 포함도 포함으로 센다.
    static func includedCount(_ rows: [Row]) -> Int {
        rows.reduce(0) { $0 + ($1.isIncluded ? 1 : 0) }
    }

    /// 파일 이름 · 경로 부분 일치 (대소문자 무시).
    static func filter(_ rows: [Row], query: String) -> [Row] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return rows }
        return rows.filter { $0.path.localizedCaseInsensitiveContains(q) }
    }

    /// 목록이 이보다 길면 찾기 칸을 보인다.
    static let searchThreshold = 20

    // MARK: 목록 구역 (충돌 · 검토 중인 실행의 파일 · 그 밖)

    /// 파일 목록의 한 구역. `all` 은 머리 없이 그리는 평소 목록이다.
    struct ListSection: Equatable, Sendable {
        enum Kind: Hashable, Sendable {
            case all
            /// "변경사항 검토" 칩으로 연 실행에서 바뀐 파일 (그 실행의 충돌 파일도 여기 — 행이 충돌로 그려진다).
            /// 비어 있어도 둔다 (그 사이 커밋 · 되돌렸을 수 있다). 있으면 맨 위.
            case thisRun
            /// 병합 충돌 (체크할 수 없다). 검토 중인 실행의 파일 다음, 그 밖의 변경보다 위.
            case conflicts
            case others
        }
        var kind: Kind
        var rows: [Row]
    }

    /// 파일 목록을 구역으로 나눈다. `raised` = 위로 올릴 경로 (검토 중인 실행의 파일, 저장소 루트 기준). nil 이면 평소 목록.
    /// 그 실행의 파일 → 충돌 → 그 밖의 변경 순이고, 각 구역 안의 순서는 `rows` 그대로다 (충돌 먼저, 경로 순).
    /// `rows` 는 찾기로 걸러진 행일 수 있어, 충돌이 전체 목록에 있는지(`conflictsPresent`)는 따로 받는다 — 찾기로 충돌 행이
    /// 빠져도 "그 밖의 변경" 머리는 그대로 둔다 (충돌이 있으면 전체 선택 줄 대신 구역 머리가 개수를 보인다).
    static func listSections(_ rows: [Row], raised: Set<String>?, conflictsPresent: Bool = false) -> [ListSection] {
        var out: [ListSection] = []
        var remaining = rows
        if let raised {
            out.append(ListSection(kind: .thisRun, rows: rows.filter { raised.contains($0.path) }))
            remaining = rows.filter { !raised.contains($0.path) }
        }
        let conflicts = remaining.filter { $0.inclusion == .conflict }
        let rest = conflicts.isEmpty ? remaining : remaining.filter { $0.inclusion != .conflict }
        if raised == nil && conflicts.isEmpty && !conflictsPresent { return [ListSection(kind: .all, rows: rows)] }
        if !conflicts.isEmpty { out.append(ListSection(kind: .conflicts, rows: conflicts)) }
        if !rest.isEmpty { out.append(ListSection(kind: .others, rows: rest)) }
        return out
    }

    /// 올린 경로 중 지금 변경 목록에 없는 수 (실행 뒤 커밋했거나 되돌렸다). 찾기로 걸러진 것은 세지 않도록 전체 행과 비교한다.
    static func raisedMissing(_ allRows: [Row], raised: Set<String>) -> Int {
        let present = Set(allRows.map(\.path))
        return raised.filter { !present.contains($0) }.count
    }

    /// "이번 실행에서 바뀐 파일" 구역 머리 아래의 설명. 구역의 행 수와 이 문구의 개수를 더하면 카드의 파일 수가 되도록,
    /// 구역에 없는 그 실행의 파일을 이유별로 센다 (찾기로 걸러진 행은 사용자가 거른 것이라 따로 세지 않는다).
    /// - `conflicts`: 구역 안의 충돌 행 수 ("그중" — 구역 행 수에 이미 들어 있다).
    /// - `missing`: 올렸지만 지금 목록에 없는 파일 (실행 뒤 커밋 · 되돌림, 또는 편집 기록의 파일이 바뀌지 않았다).
    /// - `clearedByRun`: 실행 전후 비교에서 실행 뒤 목록에서 사라진 파일 (그 실행이 되돌렸거나 커밋했다).
    /// - `unstored`: 기록 상한(`RunFileChanges.storedFileLimit`)을 넘어 경로를 모르는 파일.
    static func raisedNotes(conflicts: Int, missing: Int, clearedByRun: Int, unstored: Int) -> [String] {
        var out: [String] = []
        if conflicts > 0 { out.append("그중 충돌 \(conflicts)개") }
        if clearedByRun > 0 { out.append("\(clearedByRun)개는 그 실행이 되돌리거나 커밋해 목록에서 빠짐") }
        if missing > 0 { out.append("\(missing)개는 그 뒤 커밋 · 되돌림으로 지금 목록에 없음") }
        if unstored > 0 { out.append("외 \(unstored)개는 경로를 기록하지 않아 올리지 못함") }
        return out
    }

    /// 올린 구역의 머리 — 어느 실행인지 밝힌다 ("Claude 13:05 실행에서 바뀐 파일"). 실행을 모르면 "검토하는 실행에서 바뀐 파일".
    /// "이번 실행" 이라고 쓰지 않는다 — 그 뒤에 새 실행이 끝났을 수 있다 (H9).
    static func runSectionTitle(agent: String?, time: String?) -> String {
        guard let agent, !agent.isEmpty else { return "검토하는 실행에서 바뀐 파일" }
        return "\(agent)\(time.map { " " + $0 } ?? "") 실행에서 바뀐 파일"
    }

    // MARK: 파일 diff — 이전 / 다음 파일 (⌥↑ ⌥↓)

    /// 목록에 지금 보이는 순서 (구역 순서 · 구역 안 순서 그대로, 찾기로 걸러진 행만). 이전 · 다음 파일이 따른다.
    static func visibleOrder(_ sections: [ListSection]) -> [String] {
        sections.flatMap { $0.rows.map(\.path) }
    }

    /// diff 머리줄의 "2 / 4" 와 이전 · 다음 파일.
    struct DiffPosition: Equatable, Sendable {
        /// 0 부터. 지금 파일이 목록 순서에 없으면 (찾기로 걸러짐) nil — 화면은 "– / n".
        var index: Int?
        var count: Int
        var previous: String?
        var next: String?
    }

    /// 목록 순서에서의 자리. 순서에 없으면 이전 = 마지막, 다음 = 첫 파일 (목록으로 들어가는 길).
    static func diffPosition(of path: String, in order: [String]) -> DiffPosition {
        guard let index = order.firstIndex(of: path) else {
            return DiffPosition(index: nil, count: order.count, previous: order.last, next: order.first)
        }
        return DiffPosition(index: index, count: order.count,
                            previous: index > 0 ? order[index - 1] : nil,
                            next: index + 1 < order.count ? order[index + 1] : nil)
    }

    /// 크게 보기의 순서. 목록이 지금 보이고 그 순서가 지금 git 상태로 만든 것이면(`listIsCurrent`) 그대로 — 찾기로 걸러진 파일은
    /// 넣지 않는다 (목록에 보이는 순서). 그렇지 않으면(목록이 숨었거나 상태를 다시 읽기 전 순서) 마지막 순서에서 지금도 바뀐 파일만,
    /// 그 뒤에 그 순서에 없던 파일(행 순서). 목록 순서를 모르면 행 순서 그대로.
    static func diffOrder(listOrder: [String], rows: [Row], listIsCurrent: Bool = false) -> [String] {
        let present = Set(rows.map(\.path))
        if listIsCurrent, !listOrder.isEmpty { return listOrder.filter { present.contains($0) } }
        let kept = listOrder.filter { present.contains($0) }
        let keptSet = Set(kept)
        return kept + rows.map(\.path).filter { !keptSet.contains($0) }
    }

    /// 보던 파일이 목록에서 빠졌을 때(커밋 · 되돌림) 대신 보여줄 파일: 빠지기 전 순서에서 그 뒤의 첫 남은 파일, 없으면 앞쪽.
    /// 남은 파일이 없으면 nil (목록 · 대화로 돌아간다).
    static func diffReplacement(for missing: String, previousOrder: [String], present: Set<String>) -> String? {
        guard let index = previousOrder.firstIndex(of: missing) else {
            return previousOrder.first { present.contains($0) }
        }
        if let after = previousOrder[(index + 1)...].first(where: { present.contains($0) }) { return after }
        return previousOrder[..<index].last { present.contains($0) }
    }

    /// 체크박스 · "커밋에 포함" 을 흐리게 잠그는 잠금 (git 명령 실행 중 · 실행 전후 스냅샷은 잠깐이라 흐리게 하지 않는다).
    static func blocksCheckbox(_ lock: Lock?) -> Bool {
        switch lock {
        case .agentRunning?, .unterminatedProcesses?, .noThread?, .gitRunningElsewhere?, .worktreeCommand?: return true
        case .gitRunning?, .runSnapshot?, nil: return false
        }
    }

    // MARK: - 원격과의 관계

    /// 게시(`push --set-upstream origin <브랜치>`)를 할 수 있는지.
    enum Publish: Equatable, Sendable {
        /// 게시할 수 있다. `onRemote` = 마지막 fetch 기준으로 `origin/<브랜치>` 가 이미 있는지
        /// (true 면 새로 만드는 것이 아니라 그 브랜치로 올리고 추적을 잇는다, nil 이면 원격 브랜치 목록을 못 읽음).
        case available(onRemote: Bool?)
        /// `GitWrite` 는 origin 으로만 게시한다. 다른 이름의 원격만 있으면 앱에서 하지 않는다.
        case noOrigin
        /// 첫 커밋 전이라 올릴 것이 없다.
        case noCommits
        /// `git remote` 를 읽지 못했다 (원격이 없다고 단정하지 않는다).
        case remotesUnknown
    }

    enum Sync: Equatable, Sendable {
        /// 브랜치가 아닌 커밋을 보고 있다.
        case detached
        /// 원격 저장소가 설정되지 않았다.
        case noRemote
        /// 이 브랜치가 추적하는 원격 브랜치가 설정되어 있지 않다 (원격에 그 브랜치가 없다는 뜻은 아니다).
        case noUpstream(Publish)
        /// 추적하도록 설정한 원격 브랜치가 (마지막 fetch 기준) 원격에 없다. 지워졌는지, 처음부터 없었는지는
        /// 모른다 (빈 저장소를 clone 한 직후에도 이렇다). `republish` 면 게시로 같은 이름의 origin 브랜치를 만든다.
        case upstreamGone(upstream: String, republish: Bool)
        /// 추적은 하지만 앞섬/뒤처짐을 읽지 못했다.
        case unknown(upstream: String)
        case inSync(upstream: String)
        case ahead(upstream: String, count: Int)
        case behind(upstream: String, count: Int)
        case diverged(upstream: String, ahead: Int, behind: Int)
        /// 병합 진행 중 (MERGE_HEAD 가 있다). 커밋이 병합을 마무리하기 전까지 업로드 · 받기를 두지 않는다
        /// (받기는 git 이 거부하고, 업로드는 병합 전 기록을 올린다). `upstream` 은 이 브랜치의 추적 브랜치 (없으면 nil).
        case merging(upstream: String?)
        /// rebase 진행 중 (`git pull --rebase` · `git rebase` 가 멈춘 상태). HEAD 가 떼어져 있어 브랜치가 아닌
        /// 커밋처럼 보이지만, 앱은 커밋 · 브랜치 만들기 · 업로드를 권하지 않는다 (터미널에서 `--continue` · `--abort`).
        case rebasing

        var upstream: String? {
            switch self {
            case .upstreamGone(let u, _), .unknown(let u), .inSync(let u): return u
            case .ahead(let u, _), .behind(let u, _), .diverged(let u, _, _): return u
            case .merging(let u): return u
            case .detached, .noRemote, .noUpstream, .rebasing: return nil
            }
        }
    }

    /// 앞섬/뒤처짐은 마지막 fetch 기준이다 (앱이 몰래 fetch 하지 않는다).
    static func sync(_ status: GitWorkspaceStatus) -> Sync {
        // 병합 중이면 앞섬/뒤처짐보다 그것이 먼저다 (git 은 병합 전 기준으로 ahead · behind 를 적는다).
        if status.isMerging { return .merging(upstream: status.upstream) }
        if status.isRebasing { return .rebasing }
        guard let branch = status.branch else { return .detached }
        if let upstream = status.upstream {
            if status.upstreamGone {
                // 게시(`push --set-upstream origin <브랜치>`)가 같은 곳을 다시 만들 때만 제안한다.
                return .upstreamGone(upstream: upstream,
                                     republish: !status.noCommitsYet && upstream == "origin/\(branch)")
            }
            // 첫 커밋 전에는 비교할 커밋이 없다 (git 이 앞섬/뒤처짐을 적지 않는다).
            guard !status.noCommitsYet, let ahead = status.ahead, let behind = status.behind else {
                return .unknown(upstream: upstream)
            }
            switch (ahead > 0, behind > 0) {
            case (false, false): return .inSync(upstream: upstream)
            case (true, false): return .ahead(upstream: upstream, count: ahead)
            case (false, true): return .behind(upstream: upstream, count: behind)
            case (true, true): return .diverged(upstream: upstream, ahead: ahead, behind: behind)
            }
        }
        guard let remotes = status.remotes else { return .noUpstream(.remotesUnknown) }
        if remotes.isEmpty { return .noRemote }
        if status.noCommitsYet { return .noUpstream(.noCommits) }
        guard remotes.contains("origin") else { return .noUpstream(.noOrigin) }
        let onRemote: Bool? = status.remoteBranchesRead
            ? status.remoteBranches.contains { $0.fullName == "origin/\(branch)" } : nil
        return .noUpstream(.available(onRemote: onRemote))
    }

    /// 게시 버튼을 둘 수 있는 상태인지 (upstream 없음 · 추적 브랜치가 원격에 없음).
    static func canPublish(_ sync: Sync) -> Bool {
        switch sync {
        case .noUpstream(.available), .upstreamGone(_, true): return true
        default: return false
        }
    }

    /// 요약 줄의 원격 항목. 모르면 nil (쓰지 않는다).
    enum RemoteSummary: Equatable, Sendable {
        case toUpload(Int)
        case incoming(Int)
        case diverged
        /// "원격과 같음" — 커밋할 변경도 없을 때만 쓴다 (변경이 있는데 같다고 쓰면 오해한다).
        case same
        /// 마지막 fetch 기준으로 `origin/<브랜치>` 가 없다.
        case notOnRemote
        /// 추적 설정이 없다 (원격에 그 브랜치가 있는지는 따로 — 있거나 모른다).
        case notTracking
        case upstreamGone
        case noRemote
        case detached
    }

    /// `internalBranch` = 독립 작업 폴더의 대화 브랜치(`ahc/…`) — 보통 원격에 올리지 않으므로 "원격에 없는 브랜치" 를 요약에 쓰지 않는다
    /// (바닥 동기화 자리가 한 번 말한다, cap-3).
    static func remoteSummary(_ sync: Sync, hasChanges: Bool, internalBranch: Bool = false) -> RemoteSummary? {
        if internalBranch, case .noUpstream = sync { return nil }
        switch sync {
        case .ahead(_, let n): return .toUpload(n)
        case .behind(_, let n): return .incoming(n)
        case .diverged: return .diverged
        case .inSync: return hasChanges ? nil : .same
        case .noUpstream(.available(onRemote: false)): return .notOnRemote
        case .noUpstream: return .notTracking
        case .upstreamGone: return .upstreamGone
        // 원격이 없다는 것은 바닥 동기화 자리가 한 번 설명한다 — 요약 · 메타 줄에서 거듭 말하지 않는다 (H19).
        case .noRemote: return nil
        case .detached: return .detached
        // 병합 중에는 원격 항목 대신 충돌 수를 먼저 쓴다 (화면). 앞섬 · 뒤처짐은 병합 전 기준이라 쓰지 않는다.
        // rebase 중에는 HEAD 가 떼어져 있어 원격과 비교하지 않는다.
        case .unknown, .merging, .rebasing: return nil
        }
    }

    /// 요약 아래 메타 줄: "<upstream> 기준 · n분 전 확인". upstream 이 없으면 그 사실을 그대로 쓴다.
    /// "n분 전 확인" 은 마지막 fetch 시각이다 (`WorkspaceModel.lastFetchAt`). 없으면 "원격 확인 기록 없음".
    static func metaLine(_ sync: Sync, lastFetchAt: Date?, now: Date = Date(), detachedHash: String? = nil,
                         internalBranch: Bool = false) -> String {
        let parts = metaParts(sync, lastFetchAt: lastFetchAt, now: now, detachedHash: detachedHash,
                              internalBranch: internalBranch)
        return (parts.lead ?? "") + parts.rest
    }

    /// 메타 줄을 원격 브랜치 이름(`lead`, 화면은 이것을 가장 늦게 줄인다)과 나머지로 나눈다.
    /// 에이전트가 도는 동안의 안내("목록은 …")는 이 줄이 아니라 잠금 안내 줄에 둔다 — 브랜치 이름이 먼저 잘리지 않게 (cap-23).
    static func metaParts(_ sync: Sync, lastFetchAt: Date?, now: Date = Date(),
                          detachedHash: String? = nil, internalBranch: Bool = false) -> (lead: String?, rest: String) {
        let checked = lastFetchAt.map { relativeTime($0, now: now) + " 확인" } ?? "원격 확인 기록 없음"
        var lead: String?
        var rest: String
        switch sync {
        case .inSync(let u), .ahead(let u, _), .behind(let u, _), .diverged(let u, _, _), .unknown(let u):
            lead = u
            rest = " 기준 · \(checked)"
        case .upstreamGone(let u, _):
            lead = u
            rest = " 원격에 없음 · \(checked)"
        case .noUpstream where internalBranch:
            // 독립 작업 폴더의 대화 브랜치 — 원격과 견줄 것이 없는 것이 정상이다 (cap-3).
            rest = "이 대화의 브랜치 · 원격에 올리지 않음"
        case .noUpstream(.remotesUnknown):
            rest = "추적하는 원격 브랜치 없음 · 원격 목록 미확인"
        case .noUpstream:
            rest = "추적하는 원격 브랜치 없음 · \(checked)"
        case .noRemote:
            // 설명은 바닥 동기화 자리 한 곳에 (H19).
            rest = "로컬 저장소"
        case .detached:
            rest = "HEAD \(detachedHash ?? "미확인") · 원격과 비교하지 않음"
        case .merging(let u):
            // 무엇을 합치는 중인지는 쓰지 않는다 (원격인지 다른 브랜치인지 앱이 확인하지 않았다). 사실만.
            // 옆의 이름은 이 브랜치가 추적하는 브랜치다 — "그것을 합치는 중" 으로 읽히지 않게 "추적" 을 붙인다.
            rest = "병합 진행 중" + (u.map { " · 추적 \($0)" } ?? "")
        case .rebasing:
            rest = "rebase 진행 중 · HEAD \(detachedHash ?? "미확인") · 원격과 비교하지 않음"
        }
        return (lead, rest)
    }

    /// 업로드하면 반영될 PR 번호. 캐시에 열린(OPEN) PR 이 있고, 그 head 가 **지금 브랜치**이며 추적 브랜치의
    /// 이름과도 같을 때만 (올리는 곳이 그 PR 의 브랜치일 때). 모르면 nil — "PR #n에 반영" 을 쓰지 않는다.
    static func pullRequestReceivingPush(_ info: PullRequestInfo?, branch: String?, upstream: String?) -> Int? {
        guard let info, info.state == "OPEN", let branch, info.headRefName == branch,
              let upstream, let slash = upstream.firstIndex(of: "/") else {
            return nil
        }
        return info.headRefName == String(upstream[upstream.index(after: slash)...]) ? info.number : nil
    }

    // MARK: - 주 버튼 · 잠금

    /// 한 화면에 잉크색 주 버튼은 하나.
    enum Primary: Equatable, Sendable {
        /// 선택한 변경 커밋 (업로드 · 게시 · 받기 · 합치기는 흰 칩).
        case commit
        case upload
        case publish
        /// 원격 변경 받기 (`git pull --ff-only`, 확인을 거친다).
        case pull
        /// 기록 분기 — 터미널에서 합치기 (앱은 합치지 않는다. 터미널을 열 뿐이다).
        case mergeInTerminal
        /// 할 일이 없다 (원격과 같음 등).
        case none
    }

    /// 커밋에 들어갈 변경(체크한 파일)이 있으면 커밋이 주 버튼이다. 없으면 업로드 · 게시 · 받기 · 합치기가 주 버튼.
    /// 체크한 파일이 없을 때 커밋 버튼은 잉크가 아닌 비활성 모양이라 둘이 겹치지 않는다
    /// (목업 StateCommitted: 남은 파일이 있어도 선택이 없으면 업로드가 잉크).
    /// 병합 중에는 커밋이 병합을 마무리하므로 커밋이 주 버튼이다 (충돌이 남아 있으면 비활성 모양).
    /// rebase 중에는 주 버튼이 없다 (이어가기 · 멈추기는 터미널에서).
    /// `internalBranch` = 이 폴더가 대화의 독립 작업 폴더이고 지금 브랜치가 그 대화의 브랜치(`ahc/…`)다 — 이 브랜치는 보통 원격에
    /// 올리지 않고 프로젝트 폴더로 합친다. 그래서 브랜치 업로드를 주 버튼으로 권하지 않는다 (위의 "합치기" 가 이 폴더의 주 동작, chg-2).
    static func primary(includedCount: Int, sync: Sync, internalBranch: Bool = false) -> Primary {
        if case .rebasing = sync { return .none }
        if case .merging = sync { return .commit }
        if includedCount > 0 { return .commit }
        switch sync {
        case .ahead: return .upload
        case .behind: return .pull
        case .diverged: return .mergeInTerminal
        default: return canPublish(sync) && !internalBranch ? .publish : .none
        }
    }

    /// 독립 작업 폴더의 브랜치(`ahc/…` — 앱이 대화마다 만든 것)인지. 그 대화의 독립 작업 폴더에서 지금 그 브랜치를 보고 있을 때만.
    static func isInternalBranch(_ branch: String?, worktreeBranch: String?) -> Bool {
        guard let branch, let worktreeBranch else { return false }
        return branch == worktreeBranch
    }

    /// 목록에 보일 커밋 묶음. 원격 변경 도착 → 원격에서 온 커밋, 기록 분기 → 이 브랜치에만 있는 커밋 · 원격에만 있는 커밋.
    enum CommitSection: Equatable, Sendable {
        /// `@{u}..HEAD` — 이 브랜치에만 있는 커밋 (↑).
        case outgoing(count: Int)
        /// `HEAD..@{u}` — 원격에서 온 커밋 (↓). `diverged` 면 "원격에만 있는 커밋" 이라 부른다.
        case incoming(count: Int, diverged: Bool)
    }

    static func commitSections(_ sync: Sync) -> [CommitSection] {
        switch sync {
        case .behind(_, let n): return [.incoming(count: n, diverged: false)]
        case .diverged(_, let ahead, let behind):
            return [.outgoing(count: ahead), .incoming(count: behind, diverged: true)]
        default: return []
        }
    }

    /// 목록 밖에 더 있는 커밋 수 (전체 − 읽은 수). 목록을 `GitWorkspace.commitListLimit` 개까지만 읽으므로
    /// 잘렸으면 "외 n개" 로 밝힌다. 더 없거나 전체 수를 모르면 nil.
    static func moreCount(listed: Int, total: Int?) -> Int? {
        guard let total, total > listed else { return nil }
        return total - listed
    }

    // MARK: - 원격 명령 실패 표시

    /// 원격 명령(업로드 · 받기 · 원격 확인)이 실패한 **직후** 다시 읽은 상태 중 실패 안내가 기대는 값.
    /// 지금 상태의 값이 하나라도 다르면 — 터미널에서 로그인하고 올렸거나(앞섬), fetch 로 기록 분기가 드러났거나
    /// (뒤처짐 · FETCH_HEAD), 합치거나 커밋했거나(HEAD), 브랜치 · 추적 브랜치를 바꿨거나, 병합 · rebase 를
    /// 시작 · 끝냈으면 — 그 실패는 지난 일이라 보여주지 않는다 (`failureIsCurrent`).
    struct SyncContext: Equatable, Sendable {
        var branch: String?
        var head: String?
        var upstream: String?
        var upstreamGone = false
        var ahead: Int?
        var behind: Int?
        var fetchHeadModifiedAt: Date?
        var merging = false
        var rebasing = false
    }

    static func syncContext(_ status: GitWorkspaceStatus) -> SyncContext {
        SyncContext(branch: status.headLabel, head: status.lastCommit?.hash, upstream: status.upstream,
                    upstreamGone: status.upstreamGone, ahead: status.ahead, behind: status.behind,
                    fetchHeadModifiedAt: status.fetchHeadModifiedAt, merging: status.isMerging,
                    rebasing: status.isRebasing)
    }

    /// 실패를 기록할 때의 상태(`recorded`, 모르면 nil)와 지금 상태가 같을 때만 그 실패를 보여준다.
    /// 기록할 때 상태를 읽지 못했으면 보여주지 않는다 (지금에 맞는 안내인지 모른다).
    static func failureIsCurrent(recorded: SyncContext?, now status: GitWorkspaceStatus) -> Bool {
        recordIsCurrent(recorded: recorded, now: status)
    }

    /// 명령 결과(실패 · 성공)를 적은 뒤 상태가 그대로인지. 성공 표시("업로드 완료")도 같은 기준을 쓴다 —
    /// 그 사이 터미널에서 브랜치를 바꿨거나 커밋했으면 지난 결과라 보여주지 않는다.
    static func recordIsCurrent(recorded: SyncContext?, now status: GitWorkspaceStatus) -> Bool {
        guard let recorded else { return false }
        return recorded == syncContext(status)
    }

    /// 실패 안내의 "다시 시도" 를 둘 수 있는지. 지금 상태가 그 명령을 권할 때만 — 기록 분기 · 병합 중 ·
    /// 원격과 같음에서 업로드 · 받기를 다시 권하지 않는다. 원격 확인(fetch)은 파일을 바꾸지 않아 언제나.
    static func retryOffered(_ operation: GitWrite.Operation, sync: Sync) -> Bool {
        switch operation {
        case .fetch:
            return true
        case .pull:
            if case .behind = sync { return true }
            return false
        case .push(_, true):
            return canPublish(sync)
        case .push(_, false):
            if case .ahead = sync { return true }
            return false
        case .stage, .unstage, .commit, .switchBranch, .createBranch:
            return false
        }
    }

    /// 원격 명령 실패를 변경사항 탭 바닥(동기화 자리) 안에 보여줄 수 있는지. 상태를 못 읽었거나(오류 화면)
    /// 병합 · rebase 중(동기화 자리를 그리지 않음)이면 그 자리가 없으니 배너로 알려야 한다 (`AppModel.runGit`).
    static func showsSyncFailureInline(_ status: GitWorkspaceStatus?) -> Bool {
        guard let status, status.isRepository, status.error == nil else { return false }
        return !status.isMerging && !status.isRebasing
    }

    /// git 쓰기(체크 · 커밋 · 업로드 · 게시 · fetch · 전환)를 막는 이유. `AppModel.runGit` 의 가드와 같은 기준.
    enum Lock: Equatable, Sendable {
        /// 에이전트가 실행 중. `here` 가 false 면 다른 폴더에서 실행 중이다 (앱은 한 번에 하나만 실행한다).
        case agentRunning(AgentProvider?, here: Bool)
        /// 종료가 확인되지 않은 프로세스가 있다.
        case unterminatedProcesses
        /// 다른 git 명령을 실행하는 중이다.
        case gitRunning
        /// 실행 전후 비교로 작업 폴더를 찍는 중이다 (에이전트 실행을 시작하는 중 · 막 끝난 실행의 결과를 기록하는 중).
        /// 그 사이 앱의 커밋 · 받기가 에이전트의 변경으로 잡히지 않게 막는다. 잠깐이라 `gitRunning` 처럼 드러내지 않는다.
        case runSnapshot
        /// 대화가 없어 실행 기록을 남길 곳이 없다.
        case noThread
        /// 다른 프로젝트에서 원격 명령(업로드 · 받기 · 원격 확인)이 도는 중이다. 앱의 git 쓰기는 한 번에 하나라 끝날 때까지 기다린다 —
        /// 몇 초 · 몇십 초 걸릴 수 있어 숨기지 않고 까닭을 보인다 (chg-10). `progress` = "업로드하는 중입니다" 같은 말.
        case gitRunningElsewhere(project: String, progress: String)
        /// 이 폴더에서 독립 작업 폴더 명령(합치기 · 준비 명령 …)이 도는 중이다 (`koreanName` — "합치는" · "준비하는", chg-9).
        case worktreeCommand(String)
    }

    static func lock(agentRunning: Bool, agent: AgentProvider?, agentHere: Bool, hasUnterminated: Bool,
                     gitRunning: Bool, runSnapshot: Bool = false, hasThread: Bool,
                     gitElsewhere: (project: String, progress: String)? = nil, worktreeCommand: String? = nil) -> Lock? {
        if agentRunning { return .agentRunning(agent, here: agentHere) }
        if hasUnterminated { return .unterminatedProcesses }
        if let worktreeCommand { return .worktreeCommand(worktreeCommand) }
        if let gitElsewhere { return .gitRunningElsewhere(project: gitElsewhere.project, progress: gitElsewhere.progress) }
        if gitRunning { return .gitRunning }
        if runSnapshot { return .runSnapshot }
        if !hasThread { return .noThread }
        return nil
    }

    /// 화면에 잠금으로 드러낼 것만 남긴다. 다른 git 명령 실행 중(`.gitRunning`)은 체크 한 번에도 잠깐 생기므로
    /// (실행 전후 스냅샷 `.runSnapshot` 도 보낼 때 · 실행이 끝날 때 잠깐)
    /// 버튼을 누를 수 없게만 하고, 잠금 문구 · 흐린 모양으로 바꾸지 않는다 (체크할 때마다 독이 깜빡이지 않게).
    static func visibleLock(_ lock: Lock?) -> Lock? {
        lock == .gitRunning || lock == .runSnapshot ? nil : lock
    }

    /// 잠금 이유 한 문장 + 이 폴더의 실행이 메인 턴을 마치고 기다리는 백그라운드 작업 수 (있으면).
    /// 에이전트가 이 폴더에서 도는 잠금에만 덧붙인다 — 답을 마친 것처럼 보여도 하위 작업이 파일을 바꿀 수 있어 잠겨 있다.
    static func lockText(_ lock: Lock, action: String, backgroundTasks: Int) -> String {
        let text = lockText(lock, action: action)
        guard backgroundTasks > 0, case .agentRunning(_, true) = lock, text.hasSuffix(".") else { return text }
        return String(text.dropLast()) + " (백그라운드 작업 \(backgroundTasks)개)."
    }

    /// "Claude 가" · "에이전트가" — 영어 이름 뒤 조사는 띄어 쓴다 (세 제공자 이름은 받침이 없어 "가"). 제공자를 모르면 한국어 낱말이라 붙인다.
    static func agentSubject(_ provider: AgentProvider?) -> String {
        provider.map { "\($0.displayName) 가" } ?? "에이전트가"
    }

    /// 잠금 이유 한 문장. `action` 은 "수 있습니다" 앞에 붙는 동사 ("커밋할", "받을", "전환할" …).
    /// 변경사항 탭과 브랜치 메뉴가 같은 말을 쓴다.
    static func lockText(_ lock: Lock, action: String) -> String {
        switch lock {
        case .agentRunning(let provider, let here):
            let name = provider?.displayName ?? "에이전트"
            return here
                ? "\(name) 실행이 끝나면 \(action) 수 있습니다."
                : "\(agentSubject(provider)) 다른 폴더에서 실행 중입니다. 끝나면 \(action) 수 있습니다."
        case .unterminatedProcesses:
            return "종료가 확인되지 않은 프로세스가 있어 \(action) 수 없습니다."
        case .gitRunning:
            return "git 명령을 실행하는 중입니다. 끝나면 \(action) 수 있습니다."
        case .runSnapshot:
            return "실행 전후 비교로 폴더를 읽는 중입니다. 끝나면 \(action) 수 있습니다."
        case .noThread:
            return "대화를 선택해야 실행 기록을 남길 수 있어 지금은 \(action) 수 없습니다."
        case .gitRunningElsewhere(let project, let progress):
            return "다른 프로젝트(\(project))에서 \(progress). 끝나면 \(action) 수 있습니다."
        case .worktreeCommand(let kind):
            return "독립 작업 폴더를 \(kind) 중입니다. 끝나면 \(action) 수 있습니다."
        }
    }

    /// 잠금 안내에 붙이는 출구 — 메인 턴을 마치고 백그라운드 작업만 남은 실행은 스스로 끝나지 않을 수 있다 (개발 서버 등, chg-12).
    static func backgroundExitNote(backgroundTasks: Int) -> String? {
        guard backgroundTasks > 0 else { return nil }
        return "백그라운드 작업은 스스로 끝나지 않을 수 있습니다 — ⌘. 로 멈추면 커밋할 수 있습니다."
    }

    // MARK: - 실행 중 다시 읽기 (H8)

    /// 실행 중에 변경 목록을 다시 읽을 기록인지: 에이전트 실행의 파일 변경 · 끝난 명령 · 파일을 바꿀 수 있는 도구의 결과.
    /// 앱이 남긴 기록(실행 · 제공자 없음) · 메시지 · 추론 · 읽기만 하는 도구는 아니다. 하위 에이전트 안의 편집도 같은 폴더를 바꾼다.
    static func refreshesGitDuringRun(_ event: ThreadEvent) -> Bool {
        guard event.runID != nil, event.provider != nil else { return false }
        switch event.kind {
        case .fileChange:
            return true
        case .commandExecution:
            let status = JSONUtil.object(event.payloadJSON ?? "")?["status"] as? String
            return status != "inProgress" && status != "running"
        case .toolResult:
            let name = event.title.components(separatedBy: " — ").first ?? event.title
            return !readOnlyTools.contains(name)
        default:
            return false
        }
    }

    /// 파일을 바꾸지 않는 도구 (결과가 와도 다시 읽지 않는다).
    static let readOnlyTools: Set<String> = [
        "Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch", "TodoWrite", "TodoRead", "NotebookRead", "ExitPlanMode",
        "AskUserQuestion", "BashOutput", "ListMcpResourcesTool", "ReadMcpResourceTool",
    ]

    /// 실행 중 다시 읽기의 간격 — 처음 기록 뒤 이만큼 모았다가 한 번 읽는다 (그 사이 기록은 그 한 번에 담긴다).
    static let liveRefreshDelay: TimeInterval = 1.5

    // MARK: - 충돌 표시 (chg-11)

    enum ConflictMarkers: Equatable, Sendable {
        /// 충돌 표시(<<<<<<< · ======= · >>>>>>>)가 남아 있다.
        case present
        /// 남은 표시가 없다 — 해결됨으로 표시해도 된다.
        case absent
        /// 읽지 못했다 (이진 파일 · 너무 큼 · 지워짐).
        case unknown
    }

    /// 파일 내용에 git 의 충돌 표시가 남았는지. 줄 맨 앞의 `<<<<<<< ` · `>>>>>>> ` (+ `=======` 한 줄)만 본다.
    /// 내용을 못 읽었으면(nil) · 이진이면 `unknown`.
    static func conflictMarkers(in data: Data?) -> ConflictMarkers {
        guard let data else { return .unknown }
        if data.contains(0) { return .unknown }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return .unknown }
        var sawStart = false, sawEnd = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("<<<<<<< ") || line == "<<<<<<<" { sawStart = true }
            if line.hasPrefix(">>>>>>> ") || line == ">>>>>>>" { sawEnd = true }
            if sawStart && sawEnd { return .present }
        }
        return sawStart || sawEnd ? .present : .absent
    }

    /// 충돌 파일을 "해결됨으로 표시" 할 명령 (git add). 표시가 남아 있으면 nil — 남은 표시가 커밋에 들어가지 않게.
    static func markResolvedOperation(_ paths: [String], markers: [String: ConflictMarkers]) -> GitWrite.Operation? {
        let ready = paths.filter { markers[$0] == .absent }
        return ready.isEmpty ? nil : .stage(ready)
    }

    /// 커밋 버튼을 누를 수 없는 이유. 우선순위: 잠금 > rebase 중 > 충돌 > 선택 없음 > 메시지 없음.
    enum CommitBlock: Equatable, Sendable {
        case locked(Lock)
        /// rebase 진행 중. 앱의 커밋은 멈춘 커밋을 대신하는 새 커밋이 되므로 하지 않는다 (`git rebase --continue`).
        case rebasing
        case conflicts(Int)
        case noSelection
        case noMessage
    }

    /// `merging` 이면 선택이 없어도 막지 않는다 — 병합 중(MERGE_HEAD)에는 git 이 선택한 변경이 없어도
    /// 병합 커밋을 만들어 병합을 마무리한다 (충돌을 모두 HEAD 쪽으로 정리하면 목록이 비는 경우).
    static func commitBlock(lock: Lock?, conflictCount: Int, includedCount: Int, message: String,
                            merging: Bool = false, rebasing: Bool = false) -> CommitBlock? {
        if let lock { return .locked(lock) }
        if rebasing { return .rebasing }
        if conflictCount > 0 { return .conflicts(conflictCount) }
        if includedCount == 0 && !merging { return .noSelection }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noMessage }
        return nil
    }

    // MARK: - 병합 메시지 초안

    /// 이 프로젝트에서 MERGE_MSG 로 커밋 초안을 채운 기록 (어느 병합에서 어떤 글자로).
    struct MergeDraftAdoption: Equatable, Sendable {
        var mergeHead: String
        var message: String
    }

    enum MergeDraftAction: Equatable, Sendable {
        case none
        /// 초안을 MERGE_MSG 로 채운다.
        case fill(String)
        /// 병합이 끝났는데 초안이 그때 채운 그대로다 → 비운다 (지난 병합 메시지가 다음 커밋에 남지 않게).
        case clear
    }

    /// 병합 메시지를 커밋 초안으로 쓸지. **초안이 비어 있을 때만** 채우고(사용자가 쓴 초안을 덮지 않는다),
    /// 한 병합(MERGE_HEAD)에서 한 번만 채운다 (채운 뒤 사용자가 지웠으면 다시 채우지 않는다).
    /// 병합이 끝나거나 다른 병합으로 바뀌었을 때 초안이 채운 글자 그대로면 비운다. 사용자가 고쳤으면 그대로 둔다.
    static func mergeDraftAction(draft: String, mergeHead: String?, mergeMessage: String?,
                                 adopted: MergeDraftAdoption?) -> MergeDraftAction {
        if let adopted, adopted.mergeHead != mergeHead, draft == adopted.message {
            return .clear
        }
        guard let mergeHead, let mergeMessage, !mergeMessage.isEmpty, adopted?.mergeHead != mergeHead,
              draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
        return .fill(mergeMessage)
    }

    // MARK: - 브랜치

    /// 원격에만 있는 브랜치 = 원격 브랜치 − 로컬 브랜치들의 upstream − 같은 이름의 로컬 브랜치.
    /// 같은 이름 로컬 브랜치를 빼는 것은 `git switch <이름>` 이 그때 원격이 아니라 그 로컬 브랜치로 가기 때문이다.
    /// 순서(최근 커밋 순)는 그대로 둔다.
    static func remoteOnlyBranches(_ remote: [GitRemoteBranch], local: [GitBranchInfo]) -> [GitRemoteBranch] {
        let tracked = Set(local.compactMap(\.upstream))
        let localNames = Set(local.map(\.name))
        return remote.filter { !tracked.contains($0.fullName) && !localNames.contains($0.name) }
    }

    /// ⌘↵ 를 누가 받는가 — 입력창(보내기) · 커밋 버튼 · 인계 카드의 [넘기기] 가 **동시에** 단축키를 갖지 않는다.
    enum ReturnKeyOwner: Equatable, Sendable {
        case composer, commit, handoff
    }

    /// 커밋 메시지 칸에 포커스가 있으면 커밋, 키보드 포커스가 인계 카드 안(덧붙일 말 · 문서 편집)이면 카드, 그 밖은 입력창이다.
    /// 카드를 아직 넘길 수 없어도(체크 전 · 카운트다운 · 막힘 — `HandoffCard.sendableByHuman`) 카드가 갖는다: [넘기기] 가 꺼진 채라
    /// 아무것도 하지 않는다. 입력창에 주면 포커스가 없는 입력창의 쓰다 만 초안이 대기열에 걸렸다 (커밋 칸과 같은 규칙).
    /// 카운트다운 카드의 [지금 넘기기]는 단축키가 없다.
    static func returnKeyOwner(commitFieldFocused: Bool, cardFieldFocused: Bool) -> ReturnKeyOwner {
        if commitFieldFocused { return .commit }
        if cardFieldFocused { return .handoff }
        return .composer
    }

    /// 앱이 방금 만든 커밋이 아직 HEAD 인지 ("커밋 완료" 는 그동안만 보인다).
    static func isJustCommitted(appCommitHash: String?, head: GitCommitSummary?) -> Bool {
        guard let appCommitHash, let head else { return false }
        return appCommitHash == head.hash
    }

    // MARK: - 동기화 자리 변형 (진행 중 · 성공 · 대상이 바뀜)

    /// 원격 명령이 도는 동안 동기화 자리에 쓰는 사실 문구 (목업 SyncVariants "진행 중").
    /// 개수는 명령을 시작할 때의 앞섬 수 (확인 창에서 보여준 수와 같다). 받기는 git 이 원격을 다시 확인하므로 개수를 쓰지 않는다.
    struct SyncProgress: Equatable, Sendable {
        /// "커밋 2개를 올리는 중…"
        var title: String
        /// "→ origin/feature/login" · "← origin/main" · "origin · 파일은 바뀌지 않습니다"
        var target: String
        /// 버튼 글자 ("업로드 중…"). 원격 확인(fetch)은 동기화 자리의 버튼이 따로 없어 nil — 그 자리의 버튼은 끝날 때까지 누를 수 없다.
        var buttonLabel: String?

        /// 버튼 아래 한 줄 (쌓인 모양). 한 줄 모양은 `target` 을 부제로, `blockingNote` 를 그 아래 따로 쓴다
        /// (고정폭 부제 한 줄에 다 넣으면 막아 둔다는 사실이 잘린다).
        var detail: String { target + " · " + Self.blockingNote }

        static let blockingNote = "끝날 때까지 다른 Git 동작은 잠시 막아 둡니다."
    }

    /// `remoteName` 은 원격 확인이 말을 거는 원격 (`GitWorkspace.remoteName(for: .fetch, …)`). 원격 명령이 아니면 nil.
    static func syncProgress(_ operation: GitWrite.Operation, ahead: Int?, upstream: String?,
                             remoteName: String?) -> SyncProgress? {
        switch operation {
        case .push(let branch, true):
            return SyncProgress(title: "브랜치를 업로드하는 중…", target: "→ origin/\(branch)", buttonLabel: "업로드 중…")
        case .push:
            let title = ahead.flatMap { $0 > 0 ? "커밋 \($0)개를 올리는 중…" : nil } ?? "업로드하는 중…"
            return SyncProgress(title: title, target: "→ \(upstream ?? "추적 브랜치")", buttonLabel: "업로드 중…")
        case .pull:
            return SyncProgress(title: "원격 변경을 받는 중…", target: "← \(upstream ?? "추적 브랜치")", buttonLabel: "받는 중…")
        case .fetch:
            return SyncProgress(title: "원격 상태를 확인하는 중…",
                                target: "\(remoteName ?? "원격") · 파일은 바뀌지 않습니다", buttonLabel: nil)
        case .stage, .unstage, .commit, .createBranch, .switchBranch:
            return nil
        }
    }

    /// 업로드 · 게시 · 받기가 끝난 직후 몇 초 동안 보이는 결과 (목업 SyncVariants "성공").
    struct SyncSuccess: Equatable, Sendable {
        /// "업로드 완료" (성공 글자 `emeraldText`)
        var done: String
        /// "origin/feature/login 에 모두 반영됐습니다". 지금 상태로 말할 수 없으면 nil.
        var title: String?
        /// "PR #128에 커밋 2개가 반영됐습니다 · 방금"
        var sub: String
    }

    /// 성공 표시가 남는 시간. 그 뒤에는 평상 상태("원격과 같습니다")로 돌아간다 — 화면 상태만 바뀌고 git 을 다시 부르지 않는다.
    static let successDisplaySeconds: TimeInterval = 4

    /// 성공 표시. `pushedCount` 는 명령 직전의 앞섬 수 (모르면 nil), `after` 는 명령 뒤 다시 읽은 동기화 상태,
    /// `pullRequest` 는 올린 곳이 그 PR 의 브랜치일 때의 번호 (`pullRequestReceivingPush`). 표시 시간이 지났거나
    /// 원격 확인(fetch) · 로컬 명령이면 nil. 시계가 어긋나 끝난 시각이 미래면 표시한다.
    static func syncSuccess(_ operation: GitWrite.Operation, pushedCount: Int?, after: Sync, pullRequest: Int?,
                            finishedAt: Date, now: Date) -> SyncSuccess? {
        guard now.timeIntervalSince(finishedAt) < successDisplaySeconds else { return nil }
        switch operation {
        case .push(let branch, true):
            let target = after.upstream ?? "origin/\(branch)"
            let sub = pullRequest.map { "PR #\($0)에 반영됐습니다 · 방금" } ?? "이후 업로드는 이 브랜치로 갑니다 · 방금"
            return SyncSuccess(done: "브랜치 업로드 완료", title: "\(target) 에 올렸습니다", sub: sub)
        case .push:
            var title: String?
            if case .inSync(let upstream) = after { title = "\(upstream) 에 모두 반영됐습니다" }
            let count = pushedCount.flatMap { $0 > 0 ? $0 : nil }
            let sub: String
            switch (pullRequest, count) {
            case let (pr?, n?): sub = "PR #\(pr)에 커밋 \(n)개가 반영됐습니다 · 방금"
            case let (pr?, nil): sub = "PR #\(pr)에 반영됐습니다 · 방금"
            case let (nil, n?): sub = "커밋 \(n)개를 올렸습니다 · 방금"
            case (nil, nil): sub = "방금"
            }
            return SyncSuccess(done: "업로드 완료", title: title, sub: sub)
        case .pull:
            // 몇 개를 받았는지는 쓰지 않는다 (git 이 받기 전에 원격을 다시 확인해 확인 창의 개수보다 많을 수 있다).
            if case .inSync(let upstream) = after {
                return SyncSuccess(done: "받기 완료", title: "원격과 같습니다", sub: "← \(upstream) · 방금")
            }
            return SyncSuccess(done: "받기 완료", title: nil, sub: after.upstream.map { "← \($0) · 방금" } ?? "방금")
        case .fetch, .stage, .unstage, .commit, .createBranch, .switchBranch:
            return nil
        }
    }

    /// 성공 문구에 "PR #n에 반영됐습니다" 를 쓸 만큼 최근에 조회한 PR 인지. PR 은 탭을 열 때 한 번만 묻기 때문에
    /// 캐시가 오래됐으면 그 사이 병합 · 닫힘을 모른다 — 그때는 PR 을 말하지 않고 올린 커밋 수만 쓴다.
    static let pullRequestFreshSeconds: TimeInterval = 600

    static func freshPullRequest(_ number: Int?, checkedAt: Date?, now: Date) -> Int? {
        guard let number, let checkedAt, now.timeIntervalSince(checkedAt) < pullRequestFreshSeconds else { return nil }
        return number
    }

    /// 업로드 · 게시 · 받기 확인 창 (대상이 바뀌면 닫힌다).
    enum ConfirmKind: Equatable, Sendable {
        case upload, publish, pull

        var name: String {
            switch self {
            case .upload: return "업로드"
            case .publish: return "브랜치 업로드"
            case .pull: return "받기"
            }
        }
    }

    /// 확인 창이 열린 동안 프로젝트나 브랜치가 바뀐 일 (목업 SyncVariants "대상이 바뀌었을 때").
    struct TargetChange: Equatable, Sendable {
        var fromProjectPath: String?
        var fromProject: String
        var fromBranch: String?
        var toProjectPath: String?
        var toProject: String
        /// 바뀐 뒤의 브랜치 (`headLabel`). 새 폴더를 아직 읽는 중이면 nil — 읽으면 채운다.
        var toBranch: String?
        /// 바뀐 뒤가 브랜치가 아닌 커밋(떼어진 HEAD)이다.
        var toDetached = false
        var closed: ConfirmKind
        /// 커밋 메시지 초안이 있다 (브랜치만 바뀌면 그대로 남는다).
        var hasDraft: Bool

        var projectChanged: Bool { fromProjectPath != toProjectPath }
    }

    /// 커밋 독 위에 한 번 보이는 안내. `from` → `to` 는 화면이 고정폭으로 그린다.
    struct TargetChangeNotice: Equatable, Sendable {
        var title: String
        var from: String
        var to: String
        var rest: String
    }

    static func targetChangeNotice(_ change: TargetChange) -> TargetChangeNotice {
        let closed = "열려 있던 \(change.closed.name) 확인 창을 닫았습니다."
        if change.projectChanged {
            // 커밋 메시지 초안은 폴더마다 따로 둔다 (`AppModel.commitDrafts` — 독립 작업 폴더도 따로) — 쓰던 메시지는 그 폴더에 남아 있다.
            let target: String
            if let branch = change.toBranch {
                target = change.toDetached ? "지금은 \(change.toProject) 의 브랜치가 아닌 커밋(\(branch))을 보고 있습니다."
                    : "이제 \(change.toProject) 의 \(branch) 에 커밋됩니다."
            } else {
                target = "이제 \(change.toProject) 에 커밋됩니다."
            }
            return TargetChangeNotice(title: "프로젝트가 바뀌었습니다", from: change.fromProject, to: change.toProject,
                                      rest: "\(closed) 커밋 메시지는 폴더마다 따로 둡니다. \(target)")
        }
        let to = change.toBranch ?? "브랜치 미확인"
        let draft = change.hasDraft ? " 쓰던 메시지는 그대로 두었습니다." : ""
        let target = change.toDetached ? " 지금은 브랜치가 아닌 커밋을 보고 있습니다." : " 이제 \(to) 에 커밋됩니다."
        return TargetChangeNotice(title: "브랜치가 바뀌었습니다", from: change.fromBranch ?? "브랜치 미확인", to: to,
                                  rest: closed + draft + target)
    }

    /// 안내가 떠 있는 동안 대상이 다시 바뀌었을 때. 새 폴더를 읽어 브랜치를 알게 되면 채우고(`fill`), 안내와 다른
    /// 곳으로 또 바뀌었으면 지운다(`clear` — "이제 X 에 커밋됩니다" 가 틀린 말이 된다). 그 밖에는 그대로.
    enum TargetNoticeUpdate: Equatable, Sendable {
        case keep
        case fill(branch: String, detached: Bool)
        case clear
    }

    static func targetNoticeUpdate(_ change: TargetChange, nowPath: String?, nowBranch: String?,
                                   nowDetached: Bool) -> TargetNoticeUpdate {
        guard nowPath == change.toProjectPath else { return .clear }
        guard let nowBranch else { return .keep }   // 아직 읽는 중
        guard let known = change.toBranch else { return .fill(branch: nowBranch, detached: nowDetached) }
        return known == nowBranch ? .keep : .clear
    }

    // MARK: - PR 행

    /// 검사 요약 (`PullRequestInfo.checks`). 통과 = 성공(pass) 수, 전체 = 건너뜀(skipped)을 뺀 검사 수.
    struct ChecksSummary: Equatable, Sendable {
        var passed = 0
        var total = 0
        var failed = 0
        var pending = 0
        var neutral = 0
        var skipped = 0
    }

    static func checksSummary(_ checks: [PullRequestInfo.Check]) -> ChecksSummary {
        var s = ChecksSummary()
        for check in checks {
            switch check.outcome {
            case .pass: s.passed += 1
            case .fail: s.failed += 1
            case .pending: s.pending += 1
            case .neutral: s.neutral += 1
            case .skipped: s.skipped += 1
            }
        }
        s.total = checks.count - s.skipped
        return s
    }

    /// "검사 2/3 통과" · "검사 없음" · "검사 2개 모두 건너뜀". 모르는 수를 0 으로 쓰지 않는다 (검사가 없으면 없다고).
    static func checksText(_ s: ChecksSummary) -> String {
        if s.total == 0 {
            return s.skipped > 0 ? "검사 \(s.skipped)개 모두 건너뜀" : "검사 없음"
        }
        return "검사 \(s.passed)/\(s.total) 통과"
    }

    /// 검사 수의 정의 (도움말).
    static let checksDefinition = "통과 = 성공한 검사 수, 전체 = 건너뛴(SKIPPED) 검사를 뺀 검사 수. "
        + "중립(NEUTRAL)은 전체에만 들어갑니다. 값은 마지막으로 조회한 때의 것입니다."

    /// 검사 문구의 도움말: 정의 + 행에 따로 적지 않는 수 (진행 중 · 중립 · 건너뜀 — 있을 때만).
    static func checksHelp(_ s: ChecksSummary) -> String {
        var counts: [String] = []
        if s.pending > 0 { counts.append("진행 중 \(s.pending)") }
        if s.neutral > 0 { counts.append("중립 \(s.neutral)") }
        if s.skipped > 0 { counts.append("건너뜀 \(s.skipped)") }
        return counts.isEmpty ? checksDefinition : counts.joined(separator: " · ") + "\n" + checksDefinition
    }

    /// 리뷰 변경 요청 수 — 리뷰어마다 마지막 리뷰(`latestReviews`) 중 CHANGES_REQUESTED 인 것.
    static func changesRequestedCount(_ reviews: [PullRequestInfo.Review]) -> Int {
        reviews.reduce(0) { $0 + ($1.state == "CHANGES_REQUESTED" ? 1 : 0) }
    }

    /// 상태 알약. gh 값 그대로 (OPEN · MERGED · CLOSED, 초안이면 Draft). 모르는 값은 그 글자를 그대로.
    enum PullRequestPill: Equatable, Sendable {
        case open, draft, merged, closed
        case other(String)

        var label: String {
            switch self {
            case .open: return "Open"
            case .draft: return "Draft"
            case .merged: return "Merged"
            case .closed: return "Closed"
            case .other(let raw): return raw.capitalized
            }
        }
    }

    static func pullRequestPill(state: String, isDraft: Bool) -> PullRequestPill {
        switch state {
        case "OPEN": return isDraft ? .draft : .open
        case "MERGED": return .merged
        case "CLOSED": return .closed
        default: return .other(state)
        }
    }

    /// 변경사항 탭 PR 행 한 줄. 조회하지 않은 상태면 그리지 않는다. 로딩 · 실패 · gh 없음 · PR 없음은 한 줄 사실 문구.
    enum PullRequestLine: Equatable, Sendable {
        case hidden
        case loading
        case loaded(PullRequestInfo)
        /// 한 줄 문구 · 조회 시각 · 도움말(gh 가 준 원문).
        case message(String, checked: String?, help: String?)
    }

    static func pullRequestLine(_ state: PullRequestState, checkedAt: Date?, now: Date = Date()) -> PullRequestLine {
        let checked = checkedText(checkedAt, now: now)
        switch state {
        case .idle:
            return .hidden
        case .loading:
            return .loading
        case .loaded(let info, _):
            return .loaded(info)
        case .none(let branch, _):
            return .message("이 브랜치의 PR 없음", checked: checked,
                            help: "gh 가 \(branch.isEmpty ? "이 브랜치" : branch) 에서 연 PR 을 찾지 못했습니다. ··· 에서 다시 조회")
        case .unavailable(let reason):
            return .message("PR 을 읽을 수 없음 · \(reason)", checked: checked, help: reason)
        case .failed(let reason):
            return .message("PR 조회 실패 — ··· 에서 다시 조회", checked: checked, help: reason)
        }
    }

    /// "3분 전 조회" (gh 로 마지막으로 조회한 시각). 모르면 nil.
    static func checkedText(_ date: Date?, now: Date = Date()) -> String? {
        date.map { relativeTime($0, now: now) + " 조회" }
    }

    /// git 을 다시 읽은 뒤의 PR 상태 (`WorkspaceModel.refreshGit`). `key` = 지금 프로젝트 · 브랜치, `loadingKey` = 도는
    /// 조회의 대상. 조회 중인 브랜치 그대로면 조회를 기다린다. 브랜치(프로젝트)가 바뀌었으면 도는 조회를 버리고
    /// (`invalidatesQuery`) 새 브랜치의 캐시 — 없으면 조회 전(`idle`)으로 둬 탭이 한 번 묻게 한다. "조회 중" 이 새 브랜치에
    /// 남으면 아무도 묻지 않는데 묻는 중이라고 쓰고, 다시 조회 버튼도 막힌다.
    static func pullRequestAfterRefresh(current: PullRequestState, loadingKey: String?, key: String,
                                        cached: PullRequestState?) -> (state: PullRequestState, invalidatesQuery: Bool) {
        if current == .loading {
            if loadingKey == key { return (.loading, false) }
            return (cached ?? .idle, true)
        }
        return (cached ?? .idle, false)
    }

    /// 변경사항 탭을 열 때 gh 로 PR 을 조회할지. 이 프로젝트 · 브랜치의 결과가 캐시에 없을 때(`.idle`)만 한 번 —
    /// 주기적으로 다시 묻지 않는다 (다시 조회는 ··· 메뉴). 브랜치가 아니거나(떼어진 HEAD · rebase 중) 원격이 없으면
    /// 그 브랜치의 PR 이 있을 수 없어 묻지 않는다. `git remote` 를 읽지 못했으면(nil) 원격이 없다고 단정하지 않는다.
    static func pullRequestQueryNeeded(_ state: PullRequestState, status: GitWorkspaceStatus?) -> Bool {
        guard state == .idle, let status, status.isRepository, status.error == nil, status.branch != nil,
              !status.isRebasing else { return false }
        return status.remotes?.isEmpty != true
    }

    // MARK: - 문구 도우미

    static func latest(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    /// 커밋 · 브랜치의 상대 시각. git 이 준 시각이 있으면 앱의 말(`relativeTime`)로, 없으면 git 의 글자(`%ar`)
    /// 그대로, 그것도 없으면 nil. 앱이 쓰는 git 은 `%ar` 을 영어로 쓰므로 화면 말투를 맞추려고 시각을 먼저 쓴다.
    static func commitTime(_ date: Date?, fallback: String?, now: Date = Date()) -> String? {
        if let date { return relativeTime(date, now: now) }
        guard let fallback, !fallback.isEmpty else { return nil }
        return fallback
    }

    /// "방금" · "n분 전" · "n시간 전" · "n일 전". 시계가 어긋나 미래면 "방금".
    static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "방금" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)분 전" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)시간 전" }
        return "\(hours / 24)일 전"
    }

    /// 커밋 실패 출력에서 이유 한 줄. 분류는 `GitFailure` 한 곳에서 한다 — 커밋할 것 없음 · 신원 미설정은
    /// 그 사실을, 그 밖(훅 출력 등)은 git 의 `error:`/`fatal:` 줄이나 마지막 줄을 **원문 그대로**.
    /// 원인을 짐작해 붙이지 않는다 (훅 이름 · 도구 이름을 지어내지 않는다).
    static func commitFailureSummary(_ output: String) -> String {
        GitFailure.commitSummary(output)
    }
}
