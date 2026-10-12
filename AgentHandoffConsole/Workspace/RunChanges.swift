import Foundation

// 실행 한 번이 바꾼 파일 (4단계 "실행별 변경 파일과 검토 진입").
//
// 실행 **시작 직전**과 **종료 직후**에 작업 폴더의 변경 상태를 찍어 두고, 둘의 차이로 "이번 실행에서 바뀐 파일" 을 구한다.
// 스냅샷 = 경로별 { 대표 코드, 마지막 커밋 대비 줄 수, 파일 크기 · 수정 시각 } (`GitWorkspace.status` 를 그대로 쓴다 —
// 경로 · 코드 · 줄 수는 변경사항 탭 행과 같은 규칙 `ChangesState.rows`). 결과는 스키마를 바꾸지 않고 그 실행의
// `.systemNotice` 이벤트(payload `type = runFileChanges`)로 남기고, 대화의 턴 바닥글 위 카드가 그 이벤트를 읽는다.
//
// 정직성 규칙:
// - 줄 수는 **실행 전에 깨끗했던 파일**에서만 합산한다 (그때는 마지막 커밋 대비 줄 수가 곧 이번 실행의 변경이다).
//   실행 전에 이미 바뀌어 있던 파일은 numstat 차이만으로 이번 실행이 바꾼 줄 수를 알 수 없어 합산하지 않고 개수를 밝힌다.
// - 줄 수를 모르는 파일(이진 · 큰 새 파일 · 첫 커밋 전 등)도 합산하지 않고 개수를 밝힌다. 합산할 파일이 없으면 nil ("—").
//   0 을 지어내지 않는다.
// - 실행 중 HEAD 가 바뀌면(커밋 · 브랜치 전환 · 받기 등 — 무엇이 옮겼는지는 앱이 모른다) 커밋된 변경은 작업 트리 차이에
//   보이지 않고 줄 수의 기준도 달라진다 → 줄 수를 합산하지 않고 그 사실을 남긴다. 어느 한쪽의 HEAD 를 읽지 못했으면
//   바뀌었다고 하지 않고 "HEAD 미확인" 으로 줄 수만 뺀다.
// - 에이전트 프로세스의 종료를 확인하지 못했으면 종료 스냅샷 뒤의 변경이 빠졌을 수 있다고 밝힌다.
// - 스냅샷을 못 찍으면(저장소 아님 · 조회 실패 · 시간 초과) 비교하지 않았다고 남기고, 화면은 실행 기록의 편집
//   ("관찰된 편집 n건")으로 대신한다 — 줄 수는 쓰지 않는다.
//
// SwiftUI 에 의존하지 않아 검증 하네스(`inttest offline` "실행 전후 비교 판정")에서 그대로 확인한다.

// MARK: - 스냅샷

/// 실행 전후에 찍는 작업 폴더 스냅샷. 경로는 **저장소 루트 기준** (변경사항 탭 행과 같다).
/// 경로 집합 = staged ∪ unstaged ∪ untracked ∪ conflicted (마지막 커밋과 같은 파일은 담지 않는다).
struct RunFileSnapshot: Hashable, Sendable {
    struct Entry: Hashable, Sendable {
        /// 대표 코드 한 글자 (`ChangesState.representativeCode` — 행 합치기와 같은 규칙).
        var code: String
        /// 마지막 커밋 대비 줄 수 (새 파일은 직접 센 값). 모르면 nil.
        var added: Int?
        var removed: Int?
        /// 파일 크기 · 수정 시각 (FileManager). 파일이 없거나(삭제) 읽지 못하면 nil.
        var size: Int?
        var modifiedAt: Date?

        init(code: String, added: Int? = nil, removed: Int? = nil, size: Int? = nil, modifiedAt: Date? = nil) {
            self.code = code
            self.added = added
            self.removed = removed
            self.size = size
            self.modifiedAt = modifiedAt
        }

        /// 줄 수를 둘 다 안다.
        var measured: Bool { added != nil && removed != nil }
    }

    var entries: [String: Entry]
    /// HEAD 커밋 해시. 첫 커밋 전이거나 못 읽으면 nil (둘은 `headKnown` 으로 가른다).
    var head: String?
    /// HEAD 를 확인했는지 — 첫 커밋 전(HEAD 없음)이거나 `git log -1` 을 읽었으면 true. 읽지 못했으면 false 이고,
    /// 그때는 HEAD 가 바뀌었는지 판단하지 않는다 (지어내지 않는다).
    var headKnown = true

    /// 스냅샷을 찍는 시간 상한 (초). 넘으면 기다리지 않고 "시간 초과" 로 비교를 포기한다 — 보내기가 git 때문에
    /// 몇십 초씩 멈추지 않게 (평소 0.2–0.5초, iCloud · 네트워크 폴더에서는 git 이 멈출 수 있다).
    static let captureLimit: TimeInterval = 6

    /// 파일 크기 · 수정 시각을 읽는 함수 (저장소 루트 기준 경로 → 값). 검증에서는 바꿔 끼운다.
    typealias Attributes = (String) -> (size: Int?, modifiedAt: Date?)

    /// 읽은 git 상태 → 스냅샷. 저장소가 아니거나 상태를 읽지 못했으면 찍지 않는다 (이유와 함께).
    static func read(_ status: GitWorkspaceStatus, attributes: Attributes) -> RunSnapshotRead {
        // "저장소가 아님" 은 git 이 그렇게 말했을 때만이다 (`GitWorkspace.status`). 그 밖의 실패는 읽기 실패.
        if status.error != nil { return .unavailable(.readFailed) }
        guard status.isRepository else { return .unavailable(.notRepository) }
        var entries: [String: Entry] = [:]
        for row in ChangesState.rows(from: status) {
            let file = attributes(row.path)
            entries[row.path] = Entry(code: row.code, added: row.added, removed: row.removed,
                                      size: file.size, modifiedAt: file.modifiedAt)
        }
        // `lastCommit` 이 없는데 첫 커밋 전도 아니면 `git log -1` 을 읽지 못한 것이다 (그 실패는 `error` 에 남지 않는다).
        return .taken(RunFileSnapshot(entries: entries, head: status.lastCommit?.hash,
                                      headKnown: status.noCommitsYet || status.lastCommit != nil))
    }

    /// 폴더를 실제로 읽어 스냅샷을 찍는다 (읽기 전용 — `GitWorkspace.status` 와 파일 속성뿐). `limit` 초 안에 읽지
    /// 못하면 `.timedOut` (읽던 git 명령은 취소하지 않고 제 시간 제한까지 뒤에서 끝난다 — 결과는 버린다).
    /// 읽은 상태도 함께 돌려준다 (실행 종료 뒤 작업 폴더 상태를 한 번 더 읽지 않고 그대로 쓰도록). 시간 초과면 nil.
    static func capture(at directory: URL, environment: [String: String],
                        limit: TimeInterval = captureLimit) async -> (read: RunSnapshotRead, status: GitWorkspaceStatus?) {
        let status = await Deadline.run(seconds: limit) {
            await GitWorkspace.status(at: directory, environment: environment)
        }
        guard let status else { return (.unavailable(.timedOut), nil) }
        let root = status.rootPath ?? directory.path
        return (read(status, attributes: fileAttributes(root: root)), status)
    }

    /// 저장소 루트 아래 파일의 크기 · 수정 시각. 링크는 따라가지 않는다 (git 도 링크 자체를 추적한다).
    static func fileAttributes(root: String) -> Attributes {
        let base = URL(fileURLWithPath: root)
        return { path in
            guard let attributes = try? FileManager.default.attributesOfItem(
                atPath: base.appendingPathComponent(path).path) else { return (nil, nil) }
            return ((attributes[.size] as? NSNumber)?.intValue, attributes[.modificationDate] as? Date)
        }
    }

    /// 두 스냅샷에서 이 경로가 달라졌는지. 새로 생기거나 사라졌거나, 코드 · 크기 · 수정 시각 중 하나라도 다르면 바뀐 것.
    /// 줄 수는 양쪽 다 알 때만 비교한다 (한쪽 조회만 실패했을 때 내용이 그대로인 파일을 바뀌었다고 하지 않는다).
    /// `sameBase` 가 false 면(HEAD 가 바뀌었거나 확인하지 못함) 줄 수를 비교하지 않는다 — 기준 커밋이 달라 손대지 않은
    /// 파일의 줄 수도 달라 보인다.
    static func changed(_ before: Entry?, _ after: Entry?, sameBase: Bool = true) -> Bool {
        guard let before, let after else { return before != nil || after != nil }
        if before.code != after.code || before.size != after.size || before.modifiedAt != after.modifiedAt {
            return true
        }
        if sameBase && before.measured && after.measured {
            return before.added != after.added || before.removed != after.removed
        }
        return false
    }
}

/// 스냅샷을 찍었는지. 못 찍었으면 그 이유.
enum RunSnapshotRead: Hashable, Sendable {
    case taken(RunFileSnapshot)
    case unavailable(RunFileChanges.Unavailable)

    var snapshot: RunFileSnapshot? {
        if case .taken(let snapshot) = self { return snapshot }
        return nil
    }
}

// MARK: - 실행 한 번의 변경 (이벤트 payload)

/// 실행 한 번에서 바뀐 파일. 그 실행의 `.systemNotice` 이벤트 payload 로 남는다 (스키마 변경 없음).
struct RunFileChanges: Codable, Hashable, Sendable {
    /// payload 의 종류 키. 다른 안내(`systemNotice`)와 가르는 데 쓴다.
    static let payloadType = "runFileChanges"
    /// payload 에 적는 파일 수 상한. 넘으면 앞의 것만 적고 개수(`fileCount`)는 전부 센다
    /// (의존성 설치처럼 파일이 수만 개 생겨도 이벤트 한 줄이 커지지 않게).
    static let storedFileLimit = 500

    enum Unavailable: String, Codable, Hashable, Sendable {
        /// git 이 저장소가 아니라고 했다.
        case notRepository
        /// git 상태를 읽지 못했다 (명령 실패 · 설정 오류 등).
        case readFailed
        /// 스냅샷을 제시간(`RunFileSnapshot.captureLimit`)에 찍지 못했다.
        case timedOut
        /// 같은 폴더에서 다른 실행과 겹쳤다. 전후 차이가 어느 실행의 것인지 가를 수 없어 비교하지 않는다
        /// (화면은 이 실행의 도구 기록에 남은 편집 파일로 대신한다).
        case overlapped

        var koreanName: String {
            switch self {
            case .notRepository: return "Git 저장소가 아님"
            case .readFailed: return "Git 상태를 읽지 못함"
            case .timedOut: return "Git 상태 읽기가 \(Int(RunFileSnapshot.captureLimit))초를 넘김"
            case .overlapped: return "같은 폴더에서 다른 실행과 겹침"
            }
        }
    }

    struct File: Codable, Hashable, Sendable {
        /// 저장소 루트 기준.
        var path: String
        /// 실행 뒤의 대표 코드. 실행 뒤 변경 목록에서 사라졌으면(`cleared`) 실행 전 코드.
        var code: String
        /// 이번 실행의 줄 수 — 실행 전에 깨끗했던 파일만. 모르거나 셀 수 없으면 nil.
        var added: Int?
        var removed: Int?
        /// 실행 전부터 바뀌어 있던 파일 (이번 실행이 바꾼 줄 수는 알 수 없다).
        var preexisting: Bool
        /// 실행 뒤 변경 목록에서 사라졌다 (에이전트가 되돌렸거나 커밋했다).
        var cleared: Bool

        var fileName: String { (path as NSString).lastPathComponent }
    }

    var type = RunFileChanges.payloadType
    var runID: String
    /// 실행 전후 스냅샷을 모두 찍어 비교했는지.
    var compared: Bool
    /// 비교하지 못한 이유. 비교했으면 nil.
    var unavailable: Unavailable?
    /// 바뀐 파일 (경로 순, 최대 `storedFileLimit` 개).
    var files: [File]
    /// 바뀐 파일 전체 수 (`files` 가 잘렸어도 전부 센다).
    var fileCount: Int
    /// 합산한 줄 수 — 실행 전에 깨끗했고 줄 수를 아는 파일만. 합산할 파일이 없으면 nil (화면 "—").
    var added: Int?
    var removed: Int?
    /// 줄 수를 모르는 파일 수 (실행 전에 깨끗했지만 이진 · 큰 새 파일 · 첫 커밋 전 등으로 줄 수가 없다).
    var unmeasured: Int
    /// 실행 전부터 바뀌어 있던 파일 수 (줄 수 제외).
    var preexisting: Int
    /// 실행 중 HEAD 가 바뀌었다 (양쪽 HEAD 를 확인했고 다르다). 커밋된 변경은 여기 없고, 줄 수는 합산하지 않는다.
    var headChanged: Bool
    /// 어느 한쪽의 HEAD 를 확인하지 못했다. 바뀌었는지 모르므로 줄 수를 합산하지 않는다.
    var headUnknown = false
    /// 에이전트 프로세스의 종료를 확인하지 못했다 (`Run.childProcessNote`). 종료 스냅샷 뒤의 변경은 빠졌을 수 있다.
    var processUnconfirmed = false

    /// 비교하지 못한 실행.
    static func notCompared(runID: String, reason: Unavailable) -> RunFileChanges {
        RunFileChanges(runID: runID, compared: false, unavailable: reason, files: [], fileCount: 0,
                       added: nil, removed: nil, unmeasured: 0, preexisting: 0, headChanged: false)
    }

    /// 실행 전후 스냅샷의 차이.
    static func compare(runID: String, before: RunFileSnapshot, after: RunFileSnapshot) -> RunFileChanges {
        let headUnknown = !(before.headKnown && after.headKnown)
        let headChanged = !headUnknown && before.head != after.head
        // 줄 수의 기준(마지막 커밋)이 그대로인지 확인했을 때만 줄 수를 쓰고 비교한다.
        let sameBase = !headUnknown && !headChanged
        var files: [File] = []
        for path in Set(before.entries.keys).union(after.entries.keys) {
            let b = before.entries[path], a = after.entries[path]
            guard RunFileSnapshot.changed(b, a, sameBase: sameBase) else { continue }
            let preexisting = b != nil
            // 줄 수는 실행 전에 깨끗했던 파일에서만, HEAD 가 그대로임을 확인했을 때만 쓴다.
            let counts = !preexisting && sameBase && (a?.measured ?? false)
            files.append(File(path: path, code: a?.code ?? b?.code ?? "M",
                              added: counts ? a?.added : nil, removed: counts ? a?.removed : nil,
                              preexisting: preexisting, cleared: a == nil))
        }
        files.sort { lhs, rhs in
            let order = lhs.path.localizedStandardCompare(rhs.path)
            return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
        }
        let fresh = files.filter { !$0.preexisting }
        let measured = fresh.filter { $0.added != nil && $0.removed != nil }
        return RunFileChanges(
            runID: runID, compared: true, unavailable: nil,
            files: Array(files.prefix(storedFileLimit)), fileCount: files.count,
            added: measured.isEmpty ? nil : measured.reduce(0) { $0 + ($1.added ?? 0) },
            removed: measured.isEmpty ? nil : measured.reduce(0) { $0 + ($1.removed ?? 0) },
            // HEAD 가 바뀌었거나 미확인이면 줄 수를 아예 세지 않으므로 "모름" 개수도 따로 세지 않는다 (HEAD 안내가 대신한다).
            unmeasured: sameBase ? fresh.count - measured.count : 0,
            preexisting: files.count - fresh.count,
            headChanged: headChanged, headUnknown: headUnknown)
    }

    /// HEAD 가 바뀌었거나 확인하지 못해 줄 수를 합산하지 않았다.
    var linesSuppressed: Bool { headChanged || headUnknown }

    /// 실행 뒤 변경 목록에서 사라진 파일 수 (에이전트가 되돌렸거나 커밋했다 — payload 에 적은 파일 중).
    var clearedCount: Int { files.filter(\.cleared).count }
    /// payload 상한(`storedFileLimit`)을 넘어 경로를 적지 않은 파일 수.
    var unstoredCount: Int { max(0, fileCount - files.count) }

    /// 시작 전 · 종료 뒤 스냅샷 → 이 실행의 변경. 둘 중 하나라도 못 찍었으면 비교하지 않는다 (종료 뒤의 이유를 먼저).
    static func summarize(runID: String, before: RunSnapshotRead, after: RunSnapshotRead) -> RunFileChanges {
        switch (before, after) {
        case (.taken(let b), .taken(let a)):
            return compare(runID: runID, before: b, after: a)
        case (_, .unavailable(let reason)), (.unavailable(let reason), _):
            return notCompared(runID: runID, reason: reason)
        }
    }

    // MARK: 이벤트

    /// 이 실행의 이벤트 (`.systemNotice`, runID = 그 실행). 본문은 사람이 읽는 요약 — Gemini 요약 입력에도 이 글이 들어간다.
    func event(threadID: String, provider: AgentProvider?) -> ThreadEvent {
        ThreadEvent(threadID: threadID, runID: runID, kind: .systemNotice, provider: provider,
                    title: "실행 전후 비교", text: summaryText, payloadJSON: payloadJSON)
    }

    var payloadJSON: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// 이 요약 이벤트인지 (다른 안내와 가른다). payload 를 해석하기 전에 싸게 거른다.
    static func mayBeSummary(_ event: ThreadEvent) -> Bool {
        event.kind == .systemNotice && event.runID != nil
            && (event.payloadJSON?.contains(payloadType) ?? false)
    }

    /// 요약 이벤트의 payload. 요약 이벤트가 아니면 nil.
    static func decode(_ event: ThreadEvent) -> RunFileChanges? {
        guard mayBeSummary(event), let data = event.payloadJSON?.data(using: .utf8),
              let changes = try? JSONDecoder().decode(RunFileChanges.self, from: data),
              changes.type == payloadType else { return nil }
        return changes
    }

    // MARK: 화면 · 기록 문구

    /// 카드에 이름을 보일 파일 (최대 `limit` 개)과 나머지 수. 실행 뒤 사라진 파일도 바뀐 파일이라 함께 센다.
    static func nameSummary(_ paths: [String], total: Int? = nil, limit: Int = 3) -> (names: [String], more: Int) {
        let names = paths.prefix(limit).map { ($0 as NSString).lastPathComponent }
        return (names, max(0, (total ?? paths.count) - names.count))
    }

    /// `+a −r` (둘 다 0 이면 `±0`). 합산할 파일이 없으면 "—".
    static func lineText(added: Int?, removed: Int?) -> String {
        guard let added, let removed else { return "—" }
        if added == 0 && removed == 0 { return "±0" }
        return "+\(added) −\(removed)"
    }

    /// 줄 수에서 뺀 것 · 기준이 달라진 것 · 확인하지 못한 것을 밝히는 짧은 문구들 (카드 셋째 줄 · 기록 본문).
    /// 문구끼리는 " · " 로 잇기 때문에 한 문구 안에는 " · " 를 쓰지 않는다.
    var notes: [String] {
        var out: [String] = []
        if headChanged { out.append("실행 중 HEAD 가 바뀌어(커밋, 브랜치 전환, 받기 등) 커밋된 변경은 세지 않았습니다") }
        if headUnknown { out.append("실행 전후 HEAD 를 확인하지 못해 줄 수를 더하지 않았습니다") }
        if preexisting > 0 { out.append("실행 전부터 바뀌어 있던 \(preexisting)개는 줄 수 제외") }
        if unmeasured > 0 { out.append("줄 수를 알 수 없는 파일 \(unmeasured)개 (이진, 큰 새 파일, 첫 커밋 전 등)") }
        if processUnconfirmed { out.append(Self.processNote) }
        return out
    }

    static let processNote = "프로세스 종료 미확인이라 비교 뒤의 변경은 빠졌을 수 있습니다"

    /// 같은 사실의 카드용 짧은 말 (사람이 읽는 줄). `notes` 의 긴 문장은 저장되는 이벤트 글(`summaryText`) · 인계 문서
    /// (`packetLine` — 받는 에이전트가 읽는다)에 그대로 쓰고, 카드는 이것을 보이고 긴 문장은 도움말에 둔다.
    var cardNotes: [String] {
        var out: [String] = []
        if headChanged { out.append("커밋된 변경은 세지 않음") }
        if headUnknown { out.append("줄 수 확인 못 함") }
        if preexisting > 0 { out.append("줄 수는 실행 전부터 바뀐 \(preexisting)개 제외") }
        if unmeasured > 0 { out.append("줄 수 모르는 파일 \(unmeasured)개") }
        if processUnconfirmed { out.append(Self.processCardNote) }
        return out
    }

    static let processCardNote = "끝난 뒤의 변경은 빠졌을 수 있음"

    /// 비교했고 바뀐 파일이 없으며 밝힐 단서(`notes`)도 없다 — 대화 스트림은 카드 대신 턴 바닥글 끝에 "바뀐 파일 없음" 으로 적는다.
    var unchangedWithoutCaveats: Bool { compared && fileCount == 0 && notes.isEmpty }

    /// 바뀐 파일이 없을 때의 머리 문구. HEAD 가 바뀌었거나 확인하지 못했으면 커밋된 변경이 있을 수 있어
    /// "바뀐 파일 없음" 이라고 하지 않고 커밋하지 않은 변경(작업 트리)만 말한다.
    var noChangeHeadline: String {
        linesSuppressed ? "커밋하지 않은 변경 없음" : "이번 실행에서 바뀐 파일 없음"
    }

    /// 이벤트 본문 — 사실만. 경로는 저장소 루트 기준으로 최대 5개.
    var summaryText: String {
        guard compared else {
            return "실행 전후 비교를 하지 못했습니다 (\(unavailable?.koreanName ?? "이유 미확인"))."
                + (processUnconfirmed ? " " + Self.processNote + "." : "")
        }
        guard fileCount > 0 else {
            return (linesSuppressed ? "커밋하지 않은 변경이 없습니다" : "이번 실행에서 바뀐 파일이 없습니다")
                + " (실행 전후 비교)." + (notes.isEmpty ? "" : " " + notes.joined(separator: " · ") + ".")
        }
        let shown = files.prefix(5).map(\.path)
        var text = "이번 실행에서 파일 \(fileCount)개가 바뀌었습니다 (실행 전후 비교): " + shown.joined(separator: ", ")
        if fileCount > shown.count { text += " 외 \(fileCount - shown.count)개" }
        text += " · " + (linesSuppressed ? "줄 수 —" : Self.lineText(added: added, removed: removed))
        if !notes.isEmpty { text += " · " + notes.joined(separator: " · ") }
        return text
    }

    /// 인계 문서의 "완료한 작업" 한 줄 (비교했고 바뀐 파일이 있거나 HEAD 가 바뀌었을 때만). 앱이 관찰한 사실이라
    /// "(관찰)" 을 붙인다.
    func packetLine(provider: AgentProvider?) -> String? {
        guard compared, fileCount > 0 || headChanged else { return nil }
        let who = provider.map { "\($0.displayName) 실행" } ?? "실행"
        guard fileCount > 0 else {
            // 작업 트리에는 남은 게 없지만 HEAD 가 바뀌었다 — 커밋했을 수 있다는 사실을 넘긴다.
            return "\(who) 뒤 커밋하지 않은 변경 없음(실행 전후 비교, 관찰) (" + notes.joined(separator: " · ") + ")"
        }
        let shown = files.prefix(5).map(\.path)
        var text = "\(who)에서 바뀐 파일(실행 전후 비교, 관찰) \(fileCount)개: " + shown.joined(separator: ", ")
        if fileCount > shown.count { text += " 외 \(fileCount - shown.count)개" }
        if !linesSuppressed { text += " · " + Self.lineText(added: added, removed: removed) }
        if !notes.isEmpty { text += " (" + notes.joined(separator: " · ") + ")" }
        return text
    }

    /// "변경사항 검토" 칩 · 탭 점을 둘지. 비교했으면 변경사항 탭에 올릴 파일(실행 뒤에도 목록에 남은 파일)이 있을 때 —
    /// 되돌리기만 한 실행은 카드로 사실만 밝히고 칩 · 점은 두지 않는다 (열어도 올릴 파일이 없다).
    /// 비교하지 못했으면 실행 기록에 편집이 있고 변경사항 탭에 목록이 있을 때(저장소일 때)만 — 저장소가 아니면 올릴 목록이 없다.
    func reviewable(observedCount: Int) -> Bool {
        compared ? (unstoredCount > 0 || files.contains { !$0.cleared })
            : (unavailable != .notRepository && observedCount > 0)
    }

    /// 변경사항 탭에서 위로 올릴 경로 (실행 뒤에도 남아 있는 파일). 비교하지 못했으면 nil — 탭이 실행 기록의 편집으로 대신한다.
    var reviewPaths: [String]? {
        compared ? files.filter { !$0.cleared }.map(\.path) : nil
    }
}

// MARK: - 시간 상한

/// 비동기 작업을 시간 상한까지만 기다린다. 넘으면 nil 이고, 작업은 취소하지 않는다 (git 프로세스는 취소를 받지 않고
/// 제 시간 제한까지 돈다 — 결과만 버린다).
enum Deadline {
    static func run<T: Sendable>(seconds: TimeInterval,
                                 _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let gate = ResumeOnce(continuation)
            let timer = Task {
                // 취소되면(작업이 먼저 끝남) 아무것도 하지 않는다. `try?` 로 삼키면 곧바로 nil 을 넣어 제시간에 끝난
                // 작업과 경주하고, 이기면 끝난 스냅샷이 "시간 초과" 로 기록된다.
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                } catch {
                    return
                }
                gate.resume(nil)
            }
            Task {
                let value = await operation()
                // 값을 먼저 넘기고 타이머를 멈춘다 — 멈추는 사이에 타이머가 끼어들 틈을 두지 않는다.
                gate.resume(value)
                timer.cancel()
            }
        }
    }

    /// 먼저 온 결과 하나로만 이어가게 한다.
    private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?

        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

        func resume(_ value: T?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}
