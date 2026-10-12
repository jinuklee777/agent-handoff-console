import Foundation

// 대화 안 찾기 (편집 > 대화에서 찾기 ⌘F · 다음 ⌘G · 이전 ⇧⌘G) — 순수 판정. SwiftUI 에 의존하지 않아 검증 하네스에서도 컴파일된다.
// 찾는 곳은 대화 스트림의 행(`StreamRow` — 메인 흐름 이벤트로 만든 것, 하위 에이전트 안의 일은 없다)에서 화면에 보이는 글이다.
// 막대는 `UI/ThreadFindBar.swift`, 맞는 행으로 스크롤 · 강조는 `ThreadView`. 사이드바의 대화 목록 검색(⌥⌘F)과는 다른 기능이다.

enum ThreadFind {
    /// 맞은 행 하나. 앞뒤로 옮겨 다니는 단위는 행이다 (스크롤 · 강조가 행 단위다).
    struct Match: Equatable, Sendable {
        var rowID: String
        /// 이 행에서 맞은 곳 수.
        var occurrences: Int
    }

    /// 메뉴(⌘F · ⌘G · ⇧⌘G) → 포커스 칸의 대화. 받은 칸이 지운다 (`AppModel.requestFind` · `consumeFindCommand`).
    /// 에이전트 기록 화면에서 누르면 대화 칸이 그 뒤에 나타나므로, 나타날 때도 받는다 — 오래된 요청(`isFresh`)만 빼고.
    struct Command: Equatable, Sendable {
        enum Action: Equatable, Sendable { case open, next, previous }
        var threadID: String
        var action: Action
        var serial: Int
        var requestedAt: Date

        func isFresh(now: Date = Date()) -> Bool { now.timeIntervalSince(requestedAt) < 2 }
    }

    /// 한 행에서 찾을 글 — 화면에 보이는 글: 사용자 · 에이전트 메시지, 안내 · 오류의 제목과 글, 실행 기록의 작업 설명 · 명령 ·
    /// 편집한 파일 · 도구 요약 · 승인 · 질문 · 안내 · 추론 요약의 머리. 명령 출력 · diff · 생각의 본문은 행 안에서 또 접혀 있어 넣지
    /// 않는다 (맞아도 화면에서 찾을 수 없다). 실행 기록 블록은 접혀 시작하지만 찾은 결과가 되면 블록과 맞은 단계를 펼친다
    /// (`matchingEntryIDs` → `ExecutionBlockView`).
    /// 머리줄 · 바닥글 · 인계 줄 · 실행 전후 비교 카드는 찾지 않는다.
    static func searchableText(_ row: StreamRow) -> [String] {
        switch row {
        case .user(let event), .agentMessage(let event):
            return [event.text]
        case .alert(let event), .notice(let event):
            return [event.title, event.text]
        case .execution(_, let entries):
            return entries.flatMap(entryText)
        case .agentHeader, .turnFooter, .relay, .runChanges:
            return []
        }
    }

    /// 실행 기록 단계 하나에서 찾을 글 — 단계 줄 · 펼친 단계에 보이는 글 (명령 출력 · diff · 생각의 본문은 빼고).
    static func entryText(_ entry: ExecutionEntry) -> [String] {
        switch entry.kind {
        case .command(let info): return [info.label, info.command].compactMap { $0 }
        case .fileEdit(let info): return info.paths
        case .tool(let info): return [info.name, info.summary]
        // 승인 요청 행은 제목 한 줄만 그린다 — 원문(JSON)에서 맞으면 행만 칠해지고 맞은 글은 볼 수 없었다 (conv-4).
        case .approval(let title, _): return [title]
        case .decision(let text), .question(let text): return [text]
        case .note(let title, let text): return [title, text]
        case .reasoning(let text): return ExecutionFold.reasoningHeadings(text)
        }
    }

    /// 실행 기록 블록에서 찾을 말이 맞은 단계 — 찾은 결과가 되면 블록과 그 단계를 펼친다 (`ExecutionBlockView`).
    static func matchingEntryIDs(_ query: String, in entries: [ExecutionEntry]) -> Set<String> {
        Set(entries.filter { entry in entryText(entry).contains { occurrences(of: query, in: $0) > 0 } }.map(\.id))
    }

    /// 찾을 말 — 앞뒤 공백을 뺀다 (빈 말은 찾지 않는다).
    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 글에서 겹치지 않게 맞은 곳 수. 대소문자 · 발음 구별 기호 · 전각/반각을 가리지 않는다.
    static func occurrences(of query: String, in text: String) -> Int {
        let query = normalized(query)
        guard !query.isEmpty, !text.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                     range: searchRange) {
            count += 1
            guard found.upperBound < text.endIndex else { break }
            searchRange = found.upperBound..<text.endIndex
        }
        return count
    }

    /// 맞은 행들 (스트림 순서 — 위에서 아래로).
    static func matches(_ query: String, in rows: [StreamRow]) -> [Match] {
        let query = normalized(query)
        guard !query.isEmpty else { return [] }
        return rows.compactMap { row in
            let count = searchableText(row).reduce(0) { $0 + occurrences(of: query, in: $1) }
            return count > 0 ? Match(rowID: row.id, occurrences: count) : nil
        }
    }

    /// 막대를 열거나 찾을 말을 바꿨을 때 처음 보일 결과 — 맨 아래(가장 최근) 것. 대화는 아래에서부터 읽고, 보던 자리가 대개 끝이다.
    static func initialIndex(count: Int) -> Int? {
        count > 0 ? count - 1 : nil
    }

    /// 다음(아래 · 최근 쪽) · 이전(위 · 오래된 쪽). 끝에서 넘어가면 반대 끝으로 돈다. 결과가 없으면 nil.
    static func step(from current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current, current >= 0, current < count else { return initialIndex(count: count) }
        return forward ? (current + 1) % count : (current - 1 + count) % count
    }

    /// 같은 결과 목록 안에서 앞서 보던 행을 다시 찾는다 (새 출력이 붙어 목록이 자라도 보던 결과에 머문다). 없으면 nil.
    static func index(of rowID: String?, in matches: [Match]) -> Int? {
        guard let rowID else { return nil }
        return matches.firstIndex { $0.rowID == rowID }
    }

    /// 막대의 수: "3/7" · "결과 없음" (찾을 말이 없으면 빈 글).
    static func counterText(query: String, current: Int?, matches: [Match]) -> String {
        guard !normalized(query).isEmpty else { return "" }
        guard !matches.isEmpty else { return "결과 없음" }
        return "\((current ?? (matches.count - 1)) + 1)/\(matches.count)"
    }

    /// 수의 도움말 — 맞은 항목 수와 맞은 곳 수.
    static func counterHelp(matches: [Match]) -> String {
        let total = matches.reduce(0) { $0 + $1.occurrences }
        return matches.isEmpty ? "이 대화의 메시지 · 실행 기록에 맞는 글이 없습니다"
            : "맞는 항목 \(matches.count)개 · 모두 \(total)곳 (명령 출력 · diff 는 찾지 않습니다)"
    }
}
