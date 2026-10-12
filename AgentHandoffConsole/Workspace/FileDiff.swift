import Foundation

// 파일 diff (변경사항 탭 · 크게 보기) 의 **순수 해석**. git 을 부르지 않고 화면도 그리지 않는다
// (조회는 `GitWorkspace.fileDiff`, 그리기는 UI/Inspector/DiffViews.swift).
// 통합 diff 파서 · 줄 안 단어 강조 · hunk 포함 상태(on / 일부 / off) · 펼치기 구간 · 나란히 짝맞추기 · 화면 행을 만든다.
// 오프라인 검증(`WorkspaceTests` "파일 diff 해석" · "파일 diff 조회")에서 그대로 확인한다.
//
// 원칙: 모르는 수를 쓰지 않는다 — 파일 끝 뒤 줄 수를 모르면 "파일 끝까지 펼치기" 처럼 수 없이,
// 포함 상태는 git diff --cached 와 대조한 근사치임을 화면이 밝힌다.

// MARK: - 모델

/// 통합 diff 의 한 줄.
struct DiffLine: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case context, added, removed
        /// `\ No newline at end of file`. git 에 따라 번역될 수 있어 `\` 로 시작하는 줄 전체를 표식으로 본다.
        case marker
    }

    var kind: Kind
    var oldNumber: Int?
    var newNumber: Int?
    /// 앞의 부호(` ` `+` `-` `\`)를 뗀 본문. 줄 끝 CR 은 뗀다.
    var text: String
    /// 줄 안 단어 강조 범위 (`Character` 단위 오프셋). 짝이 없거나 너무 다르면 비어 있다.
    var highlights: [Range<Int>] = []
    /// 짝이 된 반대쪽 줄 (같은 hunk 의 `lines` 번호, `WordDiff.annotate`). 나란히 보기가 짝을 같은 행에 놓는다.
    var partner: Int?
}

/// `@@ -a,b +c,d @@ 구역` 하나.
struct DiffHunk: Hashable, Sendable {
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    /// 두 번째 `@@` 뒤에 git 이 붙인 함수 · 구역 이름. 없으면 nil.
    var section: String?
    var lines: [DiffLine] = []
    /// 표시 상한 때문에 이 hunk 의 뒷부분을 담지 않았다.
    var truncated = false

    /// 이 hunk 가 차지하는 옛 쪽 첫 줄 번호 (옛 줄이 없는 hunk 는 끼워 넣는 자리 = 시작 줄 다음).
    var firstOldLine: Int { oldCount == 0 ? oldStart + 1 : oldStart }
    /// 이 hunk 다음에 오는 옛 · 새 쪽 줄 번호.
    var nextOldLine: Int { oldCount == 0 ? oldStart + 1 : oldStart + oldCount }
    var nextNewLine: Int { newCount == 0 ? newStart + 1 : newStart + newCount }

    var addedCount: Int { lines.reduce(0) { $0 + ($1.kind == .added ? 1 : 0) } }
    var removedCount: Int { lines.reduce(0) { $0 + ($1.kind == .removed ? 1 : 0) } }
}

/// diff 안의 파일 하나 (`diff --git …` 부터 다음 `diff --git` 전까지).
struct FileDiff: Hashable, Sendable {
    /// 옛 쪽 경로 (`--- a/…`, 새 파일이면 nil).
    var oldPath: String?
    /// 새 쪽 경로 (`+++ b/…`, 지운 파일이면 nil).
    var newPath: String?
    var isNewFile = false
    var isDeleted = false
    var isRename = false
    var isCopy = false
    /// `similarity index 80%` 의 80. 없으면 nil.
    var similarity: Int?
    var oldMode: String?
    var newMode: String?
    var isBinary = false
    /// `index <옛>..<새>` 의 blob 이름 (`--full-index` 면 전체). 없으면 nil.
    var oldBlob: String?
    var newBlob: String?
    var hunks: [DiffHunk] = []
    /// 알아보지 못한 머리 줄 (번역된 "Binary files … differ" · "* Unmerged path …" 등) — 원문 그대로.
    var otherHeaderLines: [String] = []

    var addedCount: Int { hunks.reduce(0) { $0 + $1.addedCount } }
    var removedCount: Int { hunks.reduce(0) { $0 + $1.removedCount } }
    /// 이 diff 에 나오는 가장 큰 줄 번호 (거터 폭).
    var maxLineNumber: Int {
        hunks.reduce(0) { max($0, $1.oldStart + $1.oldCount, $1.newStart + $1.newCount) }
    }
}

// MARK: - 통합 diff 파서

enum UnifiedDiff {
    struct Parse: Sendable {
        var files: [FileDiff]
        /// 파일에 속하지 않은 줄 (`git diff --cached` 의 "* Unmerged path …" 등). 원문 그대로.
        var strayLines: [String]
        /// hunk 본문 줄 수 (전체).
        var totalBodyLines: Int
        /// 담은 본문 줄 수 (상한까지). 전체보다 적으면 잘렸다.
        var shownBodyLines: Int
        var truncated: Bool { shownBodyLines < totalBodyLines }
    }

    /// `git diff` 출력 → 파일들. `lineLimit` 을 넘는 본문 줄은 담지 않고 수만 센다 (큰 diff 는 앞부분만 보인다).
    /// hunk 머리의 줄 수를 세어 끝을 알아낸다 — 본문 줄이 `diff --git` 같은 글자로 시작해도 부호가 붙어 있어 헷갈리지 않는다.
    static func parse(_ text: String, lineLimit: Int = .max) -> Parse {
        var files: [FileDiff] = []
        var stray: [String] = []
        var current: FileDiff?
        var hunk: DiffHunk?
        var oldLine = 0, newLine = 0
        var oldLeft = 0, newLeft = 0
        var total = 0, shown = 0
        var stopped = false

        func finishHunk() {
            if let h = hunk, !stopped || !h.lines.isEmpty || h.truncated {
                current?.hunks.append(h)
            }
            hunk = nil
        }
        func finishFile() {
            finishHunk()
            if let file = current { files.append(file) }
            current = nil
        }
        func body(_ kind: DiffLine.Kind, _ text: Substring) {
            total += 1
            guard !stopped, shown < lineLimit else {
                if !stopped { stopped = true; hunk?.truncated = true }
                return
            }
            var line = DiffLine(kind: kind, text: String(text))
            switch kind {
            case .context:
                line.oldNumber = oldLine
                line.newNumber = newLine
                oldLine += 1
                newLine += 1
            case .removed:
                line.oldNumber = oldLine
                oldLine += 1
            case .added:
                line.newNumber = newLine
                newLine += 1
            case .marker:
                break
            }
            hunk?.lines.append(line)
            shown += 1
        }

        // "\r\n" 은 한 글자(Character)라 두 모양을 모두 줄 끝으로 본다.
        let rawLines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        for (index, raw) in rawLines.enumerated() {
            var line = raw
            if line.last == "\r" { line = line.dropLast() }
            let inHunk = hunk != nil && (oldLeft > 0 || newLeft > 0)
            if inHunk {
                switch line.first {
                case " ":
                    oldLeft -= 1; newLeft -= 1
                    body(.context, line.dropFirst())
                    continue
                case "-":
                    oldLeft -= 1
                    body(.removed, line.dropFirst())
                    continue
                case "+":
                    newLeft -= 1
                    body(.added, line.dropFirst())
                    continue
                case "\\":
                    body(.marker, line.dropFirst())
                    continue
                case nil:
                    // 공백 부호를 지운 도구가 있다 — 빈 문맥 줄로 받는다. 마지막 빈 조각(출력 끝 줄바꿈)은 넘긴다.
                    if index == rawLines.count - 1 { continue }
                    oldLeft -= 1; newLeft -= 1
                    body(.context, line)
                    continue
                default:
                    // 줄 수가 모자란 채 끝났다 — 이 줄은 머리로 읽는다.
                    finishHunk()
                }
            } else if hunk != nil, line.first == "\\" {
                // 줄 수를 다 채운 뒤의 "\ No newline" 도 그 hunk 의 표식이다.
                body(.marker, line.dropFirst())
                continue
            }

            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                finishFile()
                var file = FileDiff()
                if line.hasPrefix("diff --git "), let paths = gitHeaderPaths(line.dropFirst("diff --git ".count)) {
                    file.oldPath = paths.old
                    file.newPath = paths.new
                }
                current = file
                continue
            }
            if line.hasPrefix("@@ "), current != nil, let h = parseHunkHeader(line) {
                finishHunk()
                hunk = DiffHunk(oldStart: h.oldStart, oldCount: h.oldCount, newStart: h.newStart,
                                newCount: h.newCount, section: h.section)
                oldLine = h.oldStart
                newLine = h.newStart
                oldLeft = h.oldCount
                newLeft = h.newCount
                continue
            }
            finishHunk()
            guard current != nil else {
                if !line.isEmpty { stray.append(String(line)) }
                continue
            }
            if line.isEmpty { continue }
            header(line, into: &current!)
        }
        finishFile()
        return Parse(files: files, strayLines: stray, totalBodyLines: total, shownBodyLines: shown)
    }

    /// 확장 머리 줄 하나 (`index` · `new file mode` · `rename from` · `--- a/…` …).
    private static func header(_ line: Substring, into file: inout FileDiff) {
        func value(_ prefix: String) -> String? {
            line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
        }
        if let path = value("--- ") {
            file.oldPath = diffPath(path, prefix: "a/")
        } else if let path = value("+++ ") {
            file.newPath = diffPath(path, prefix: "b/")
        } else if let mode = value("new file mode ") {
            file.isNewFile = true
            file.newMode = mode
        } else if let mode = value("deleted file mode ") {
            file.isDeleted = true
            file.oldMode = mode
        } else if let mode = value("old mode ") {
            file.oldMode = mode
        } else if let mode = value("new mode ") {
            file.newMode = mode
        } else if let path = value("rename from ") {
            file.isRename = true
            file.oldPath = unquote(path)
        } else if let path = value("rename to ") {
            file.isRename = true
            file.newPath = unquote(path)
        } else if let path = value("copy from ") {
            file.isCopy = true
            file.oldPath = unquote(path)
        } else if let path = value("copy to ") {
            file.isCopy = true
            file.newPath = unquote(path)
        } else if let percent = value("similarity index ") ?? value("dissimilarity index ") {
            file.similarity = Int(percent.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
        } else if let rest = value("index ") {
            // `index <옛>..<새>[ 모드]`
            let blobs = rest.split(separator: " ").first ?? ""
            let parts = blobs.components(separatedBy: "..")
            if parts.count == 2 {
                file.oldBlob = parts[0].isEmpty ? nil : parts[0]
                file.newBlob = parts[1].isEmpty ? nil : parts[1]
                // 합친 diff(`index a,b..c`)는 옛 쪽이 여럿이다 — 한 blob 으로 쓰지 않는다.
                if file.oldBlob?.contains(",") == true { file.oldBlob = nil }
            }
            if let mode = rest.split(separator: " ").dropFirst().first, file.newMode == nil, file.oldMode == nil {
                file.oldMode = String(mode)
                file.newMode = String(mode)
            }
        } else if line.hasPrefix("GIT binary patch") || line.hasPrefix("Binary files ") {
            file.isBinary = true
        } else {
            file.otherHeaderLines.append(String(line))
        }
    }

    /// `@@ -a[,b] +c[,d] @@[ 구역]`. 줄 수를 생략하면 1 이다.
    static func parseHunkHeader(_ line: Substring) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int,
                                                        section: String?)? {
        guard line.hasPrefix("@@ -") else { return nil }
        let rest = line.dropFirst(4)
        guard let close = rest.range(of: " @@") else { return nil }
        let parts = rest[..<close.lowerBound].split(separator: " ")
        guard parts.count == 2, parts[1].hasPrefix("+") else { return nil }
        func range(_ text: Substring) -> (Int, Int)? {
            let numbers = text.split(separator: ",", omittingEmptySubsequences: false)
            guard numbers.count <= 2, let start = Int(numbers[0]), start >= 0 else { return nil }
            let count = numbers.count == 2 ? Int(numbers[1]) : 1
            guard let count, count >= 0 else { return nil }
            return (start, count)
        }
        guard let old = range(parts[0]), let new = range(parts[1].dropFirst()) else { return nil }
        let section = rest[close.upperBound...].trimmingCharacters(in: .whitespaces)
        return (old.0, old.1, new.0, new.1, section.isEmpty ? nil : section)
    }

    /// `--- a/경로` · `+++ b/경로` · `/dev/null`. 공백이 든 경로 뒤의 탭(git 이 붙인다)은 뗀다.
    static func diffPath(_ raw: String, prefix: String) -> String? {
        var text = raw
        while text.hasSuffix("\t") { text.removeLast() }
        if text == "/dev/null" { return nil }
        text = unquote(text)
        return text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }

    /// `diff --git a/P b/P` 에서 두 경로. 따옴표로 싼 경로와, 이름이 같은 두 반쪽(공백이 든 경로)을 읽는다.
    /// 알 수 없으면 nil (그때는 `---`/`+++` · `rename` 줄이 경로를 준다).
    static func gitHeaderPaths(_ rest: Substring) -> (old: String, new: String)? {
        let text = String(rest)
        if text.hasPrefix("\"") {
            // "a/…" "b/…" 또는 "a/…" b/…
            guard let (first, remainder) = quotedPrefix(text) else { return nil }
            let second = remainder.trimmingCharacters(in: .whitespaces)
            let new = second.hasPrefix("\"") ? quotedPrefix(second)?.0 : second
            guard let new else { return nil }
            return (strip(first, "a/"), strip(new, "b/"))
        }
        // 같은 경로 두 번: "a/X b/X" → 길이 = 2X + 5
        let count = text.count
        if count >= 5, (count - 5) % 2 == 0 {
            let half = (count - 5) / 2
            let old = String(text.prefix(half + 2))
            let new = String(text.suffix(half + 2))
            if old.hasPrefix("a/"), new.hasPrefix("b/"), old.dropFirst(2) == new.dropFirst(2) {
                return (String(old.dropFirst(2)), String(new.dropFirst(2)))
            }
        }
        let parts = text.split(separator: " ")
        if parts.count == 2, parts[0].hasPrefix("a/"), parts[1].hasPrefix("b/") {
            return (String(parts[0].dropFirst(2)), String(parts[1].dropFirst(2)))
        }
        return nil
    }

    private static func strip(_ text: String, _ prefix: String) -> String {
        text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }

    /// 맨 앞의 따옴표 경로 하나와 나머지.
    private static func quotedPrefix(_ text: String) -> (String, String)? {
        var escaped = false
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let c = text[index]
            if escaped {
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                let quoted = String(text[...index])
                return (unquote(quoted), String(text[text.index(after: index)...]))
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// git 의 C 형식 따옴표 경로를 푼다 (`"a/\t\303\251"`). 따옴표가 없으면 그대로.
    static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        var bytes: [UInt8] = []
        let chars = Array(text.dropFirst().dropLast().utf8)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == UInt8(ascii: "\\"), i + 1 < chars.count else {
                bytes.append(c); i += 1; continue
            }
            let next = chars[i + 1]
            switch next {
            case UInt8(ascii: "n"): bytes.append(0x0A); i += 2
            case UInt8(ascii: "t"): bytes.append(0x09); i += 2
            case UInt8(ascii: "r"): bytes.append(0x0D); i += 2
            case UInt8(ascii: "a"): bytes.append(0x07); i += 2
            case UInt8(ascii: "b"): bytes.append(0x08); i += 2
            case UInt8(ascii: "f"): bytes.append(0x0C); i += 2
            case UInt8(ascii: "v"): bytes.append(0x0B); i += 2
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = 0, j = i + 1
                while j < chars.count, j < i + 4, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(chars[j]) {
                    value = value * 8 + Int(chars[j] - UInt8(ascii: "0"))
                    j += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
                i = j
            default:
                bytes.append(next); i += 2
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - 줄 안 단어 강조

/// 인접한 − 묶음과 + 묶음을 짝지어, 각 쌍에서 공통 앞 · 뒤 **토큰**을 뺀 가운데 범위를 강조한다.
/// 토큰 = 낱말(글자 · 숫자 · `_`) 한 덩어리, 공백 한 덩어리, 그 밖의 글자 하나 — 글자 단위로 자르면
/// `APIClient`/`AuthTransport` 처럼 끝 글자가 같을 때 낱말이 쪼개져 보인다.
/// 공통 부분이 거의 없으면(공백을 뺀 글자의 20% 미만) 강조하지 않는다 — 줄 전체가 바뀐 것은 줄 바탕색이 이미 말한다.
enum WordDiff {
    /// 이보다 긴 줄은 비교하지 않는다 (강조 없음).
    static let maxLineLength = 2_000
    /// 강조할 만큼 비슷한지 (공통 글자 / 짧은 쪽 글자, 공백 제외).
    static let highlightRatio = 0.2
    /// 수가 다른 묶음에서 짝으로 삼을 만큼 비슷한지.
    static let pairRatio = 0.3
    /// 수가 다른 묶음을 비교할 최대 쌍 수 (넘으면 순서대로 짝짓는다).
    static let maxComparisons = 10_000

    struct Comparison: Equatable, Sendable {
        var old: Range<Int>
        var new: Range<Int>
        /// 공통 글자 / 짧은 쪽 글자 (공백 제외).
        var ratio: Double
    }

    /// 토큰 범위 (`Character` 오프셋).
    static func tokens(_ chars: [Character]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            var j = i + 1
            if isWord(c) {
                while j < chars.count, isWord(chars[j]) { j += 1 }
            } else if c.isWhitespace {
                while j < chars.count, chars[j].isWhitespace { j += 1 }
            }
            out.append(i..<j)
            i = j
        }
        return out
    }

    private static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    /// 두 줄의 가운데(바뀐) 범위와 비슷한 정도. 같은 줄 · 긴 줄 · 공백만 있는 줄 · 공통 글자가 없으면 nil.
    static func compare(_ old: String, _ new: String) -> Comparison? {
        let a = Array(old), b = Array(new)
        guard a.count <= maxLineLength, b.count <= maxLineLength, a != b else { return nil }
        let ta = tokens(a), tb = tokens(b)
        func same(_ x: Range<Int>, _ y: Range<Int>) -> Bool { a[x].elementsEqual(b[y]) }
        var prefix = 0
        while prefix < ta.count, prefix < tb.count, same(ta[prefix], tb[prefix]) { prefix += 1 }
        var suffix = 0
        while suffix < ta.count - prefix, suffix < tb.count - prefix,
              same(ta[ta.count - 1 - suffix], tb[tb.count - 1 - suffix]) { suffix += 1 }
        func nonSpace(_ chars: ArraySlice<Character>) -> Int { chars.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) } }
        let oldStart = prefix < ta.count ? ta[prefix].lowerBound : a.count
        let oldEnd = suffix > 0 ? ta[ta.count - suffix].lowerBound : a.count
        let newStart = prefix < tb.count ? tb[prefix].lowerBound : b.count
        let newEnd = suffix > 0 ? tb[tb.count - suffix].lowerBound : b.count
        let common = nonSpace(a[0..<oldStart]) + nonSpace(a[max(oldStart, oldEnd)..<a.count])
        let shorter = min(nonSpace(a[...]), nonSpace(b[...]))
        guard common > 0, shorter > 0 else { return nil }
        return Comparison(old: oldStart..<max(oldStart, oldEnd), new: newStart..<max(newStart, newEnd),
                          ratio: Double(common) / Double(shorter))
    }

    /// 강조 범위 (한 쌍). 너무 다르면 nil. 한쪽 가운데가 비면 그쪽은 강조하지 않는다 (줄에 끼워 넣기만 한 경우).
    /// 가운데가 공백뿐인 쪽도 강조하지 않는다 — 들여쓰기만 바뀐 줄에 빈칸 덩어리를 칠하지 않게 (양쪽 다 그러면 nil).
    static func changedRanges(old: String, new: String) -> (old: Range<Int>?, new: Range<Int>?)? {
        guard let c = compare(old, new), c.ratio >= highlightRatio else { return nil }
        func visible(_ range: Range<Int>, in text: String) -> Range<Int>? {
            guard !range.isEmpty else { return nil }
            let chars = Array(text)
            return chars[range].allSatisfy(\.isWhitespace) ? nil : range
        }
        let oldRange = visible(c.old, in: old), newRange = visible(c.new, in: new)
        guard oldRange != nil || newRange != nil else { return nil }
        return (oldRange, newRange)
    }

    /// − 묶음과 + 묶음의 짝 (각 묶음 안 번호). 수가 같으면 순서대로, 다르면 순서를 지키며 비슷한 줄끼리
    /// (− 줄마다 아직 짝이 없는 뒤쪽 + 줄 중 가장 비슷한 것, `pairRatio` 이상). 비교할 쌍이 너무 많으면 순서대로 짧은 쪽 수만큼.
    static func pairs(removed: [String], added: [String]) -> [(Int, Int)] {
        let k = removed.count, m = added.count
        guard k > 0, m > 0 else { return [] }
        if k == m || k * m > maxComparisons {
            return (0..<min(k, m)).map { ($0, $0) }
        }
        var out: [(Int, Int)] = []
        var from = 0
        for i in 0..<k {
            guard from < m else { break }
            var best: (index: Int, ratio: Double)?
            for j in from..<m {
                if let c = compare(removed[i], added[j]), c.ratio >= pairRatio, c.ratio > (best?.ratio ?? 0) {
                    best = (j, c.ratio)
                }
            }
            if let best {
                out.append((i, best.index))
                from = best.index + 1
            }
        }
        return out
    }

    /// hunk 줄들의 −/+ 묶음마다 짝(`partner`)과 강조를 채운다 (표식 줄은 묶음 사이에 끼어 있어도 건너뛴다).
    /// 짝은 강조가 없어도 적는다 — 나란히 보기가 강조한 두 줄을 같은 행에 놓도록 같은 짝을 쓴다 (`DiffSplit.pairs`).
    static func annotate(_ lines: inout [DiffLine]) {
        var i = 0
        while i < lines.count {
            guard lines[i].kind == .removed else { i += 1; continue }
            var removed: [Int] = []
            var j = i
            while j < lines.count, lines[j].kind == .removed || lines[j].kind == .marker {
                if lines[j].kind == .removed { removed.append(j) }
                j += 1
            }
            var added: [Int] = []
            while j < lines.count, lines[j].kind == .added || lines[j].kind == .marker {
                if lines[j].kind == .added { added.append(j) }
                j += 1
            }
            if !added.isEmpty {
                for (r, a) in pairs(removed: removed.map { lines[$0].text }, added: added.map { lines[$0].text }) {
                    lines[removed[r]].partner = added[a]
                    lines[added[a]].partner = removed[r]
                    guard let ranges = changedRanges(old: lines[removed[r]].text, new: lines[added[a]].text) else {
                        continue
                    }
                    lines[removed[r]].highlights = ranges.old.map { [$0] } ?? []
                    lines[added[a]].highlights = ranges.new.map { [$0] } ?? []
                }
            }
            i = j
        }
    }
}

// MARK: - hunk 포함 상태

/// hunk 하나가 이번 커밋에 들어가는지. 줄 단위 부분 스테이지가 있어 근사치다 (화면 도움말이 밝힌다).
enum HunkInclusion: String, Hashable, Sendable {
    case on, partial, off
}

enum DiffInclusion {
    struct Result: Equatable, Sendable {
        /// 작업 트리 diff(`git diff HEAD`)의 hunk 마다.
        var states: [HunkInclusion]
        /// 인덱스에는 있지만 지금 파일 diff 에 대응하는 줄이 없는 변경 수 (스테이지한 뒤 파일에서 되돌린 줄 등).
        /// 커밋에는 들어간다.
        var stagedOnly: Int

        var onCount: Int { states.filter { $0 == .on }.count }
        var partialCount: Int { states.filter { $0 == .partial }.count }
    }

    /// 두 diff 모두 옛 쪽(HEAD) 줄 번호 기준이다. 작업 트리 hunk 마다 옛 줄 범위가 겹치는 캐시 hunk 의 −/+ 줄과 비교해
    /// 지운 줄은 옛 줄 번호로, 더한 줄은 글자로(같은 글자가 여럿이면 개수만큼) 찾는다. 전부 있으면 on, 하나도 없으면 off, 그 밖은 일부.
    /// 새 파일(추적 안 됨)은 캐시가 비어 전부 off, 스테이지만 된 파일은 두 diff 가 같아 전부 on.
    static func states(head: [DiffHunk], cached: [DiffHunk]) -> Result {
        struct Staged {
            var range: ClosedRange<Int>
            var removed: Set<Int>
            var added: [String: Int]
        }
        var staged = cached.map { hunk -> Staged in
            var removed = Set<Int>()
            var added: [String: Int] = [:]
            for line in hunk.lines {
                switch line.kind {
                case .removed: if let n = line.oldNumber { removed.insert(n) }
                case .added: added[line.text, default: 0] += 1
                case .context, .marker: break
                }
            }
            return Staged(range: oldRange(hunk), removed: removed, added: added)
        }
        let states = head.map { hunk -> HunkInclusion in
            let range = oldRange(hunk)
            let overlapping = staged.indices.filter { staged[$0].range.overlaps(range) }
            var total = 0, found = 0
            for line in hunk.lines {
                switch line.kind {
                case .removed:
                    total += 1
                    if let n = line.oldNumber, let i = overlapping.first(where: { staged[$0].removed.contains(n) }) {
                        staged[i].removed.remove(n)
                        found += 1
                    }
                case .added:
                    total += 1
                    if let i = overlapping.first(where: { (staged[$0].added[line.text] ?? 0) > 0 }) {
                        staged[i].added[line.text]! -= 1
                        found += 1
                    }
                case .context, .marker:
                    break
                }
            }
            if found == total { return .on }
            return found == 0 ? .off : .partial
        }
        let left = staged.reduce(0) { $0 + $1.removed.count + $1.added.values.reduce(0, +) }
        return Result(states: states, stagedOnly: left)
    }

    /// 옛 쪽 줄 범위 (닫힌 구간). 옛 줄이 없는 hunk 는 끼워 넣는 자리 양옆을 쓴다.
    static func oldRange(_ hunk: DiffHunk) -> ClosedRange<Int> {
        hunk.oldCount == 0 ? hunk.oldStart...(hunk.oldStart + 1) : hunk.oldStart...(hunk.oldStart + hunk.oldCount - 1)
    }

    /// "변경 2곳 중 1곳만 이번 커밋에 들어갑니다." (크게 보기의 일부 포함 안내). 근사치임은 화면 도움말이 밝힌다.
    static func summary(_ result: Result) -> String {
        let n = result.states.count
        let on = result.onCount, partial = result.partialCount
        var text: String
        if n == 0 {
            text = "보여줄 변경 줄이 없습니다."
        } else if on == n {
            text = "변경 \(n)곳이 모두 이번 커밋에 들어갑니다."
        } else if on == 0 && partial == 0 {
            text = "변경 \(n)곳 모두 이번 커밋에 들어가지 않습니다."
        } else if partial == 0 {
            text = "변경 \(n)곳 중 \(on)곳만 이번 커밋에 들어갑니다."
        } else if on == 0 {
            text = "변경 \(n)곳 중 \(partial)곳은 일부만 이번 커밋에 들어갑니다."
        } else {
            text = "변경 \(n)곳 중 \(on)곳이 이번 커밋에 들어가고 \(partial)곳은 일부만 들어갑니다."
        }
        if result.stagedOnly > 0 {
            text += " 지금 파일에는 없지만 커밋에 포함해 둔 변경 \(result.stagedOnly)줄도 함께 커밋됩니다."
        }
        return text
    }

    static let approximationHelp = "줄 단위로 일부만 커밋에 넣어 둔 파일이라 근사치입니다 — git diff --cached 와 대조해 옛 줄 번호가 같은 지운 줄, "
        + "글자가 같은 더한 줄을 찾았습니다."
}

// MARK: - 펼치기 구간

/// hunk 사이(파일 처음 · 끝 포함)의 변경 없는 줄 구간.
struct DiffGap: Hashable, Sendable {
    /// 이 구간 바로 뒤의 hunk 번호. hunk 수와 같으면 파일 끝 구간이다.
    var beforeHunk: Int
    /// 옛 쪽 첫 줄 번호.
    var oldStart: Int
    /// 새 쪽 첫 줄 번호 (변경 없는 구간이라 옛 줄 + 일정한 차이).
    var newStart: Int
    /// 줄 수. 파일 끝 구간에서 옛 파일의 줄 수를 모르면 nil ("파일 끝까지 펼치기" — 수를 쓰지 않는다).
    var count: Int?
}

enum DiffGaps {
    /// `oldLineCount` = 옛 파일(HEAD)의 줄 수 (읽었으면). `endKnown` = diff 만으로 파일 끝에 닿았음을 안다
    /// (새 파일 · 지운 파일 · 끝에 "\ No newline" 표식). 둘 다 아니면 파일 끝 구간을 수 없이 둔다.
    static func compute(_ hunks: [DiffHunk], oldLineCount: Int?, endKnown: Bool) -> [DiffGap] {
        guard !hunks.isEmpty else { return [] }
        var out: [DiffGap] = []
        var nextOld = 1, nextNew = 1
        for (i, hunk) in hunks.enumerated() {
            let count = hunk.firstOldLine - nextOld
            if count > 0 { out.append(DiffGap(beforeHunk: i, oldStart: nextOld, newStart: nextNew, count: count)) }
            nextOld = hunk.nextOldLine
            nextNew = hunk.nextNewLine
        }
        if let total = oldLineCount {
            let count = total - nextOld + 1
            if count > 0 {
                out.append(DiffGap(beforeHunk: hunks.count, oldStart: nextOld, newStart: nextNew, count: count))
            }
        } else if !endKnown {
            out.append(DiffGap(beforeHunk: hunks.count, oldStart: nextOld, newStart: nextNew, count: nil))
        }
        return out
    }

    /// diff 만으로 파일 끝에 닿았음을 아는지.
    static func endKnown(_ file: FileDiff) -> Bool {
        if file.isNewFile || file.isDeleted { return true }
        return file.hunks.last?.lines.last?.kind == .marker
    }

    /// 구간의 줄 (옛 파일에서). 옛 파일을 못 읽었거나 범위를 벗어나면 nil.
    static func lines(of gap: DiffGap, oldLines: [String]?) -> [String]? {
        guard let oldLines else { return nil }
        let start = gap.oldStart - 1
        let end = gap.count.map { start + $0 } ?? oldLines.count
        guard start >= 0, start <= end, end <= oldLines.count else { return nil }
        return Array(oldLines[start..<end])
    }

    /// `git cat-file blob` 출력 → 줄 (마지막 줄바꿈 뒤 빈 조각은 줄이 아니다).
    static func splitLines(_ text: String) -> [String] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { $0.last == "\r" ? String($0.dropLast()) : String($0) }
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}

// MARK: - 나란히 짝맞추기

/// 나란히 보기의 한 행 (hunk 줄 번호). nil 쪽은 빈 칸(빗금).
struct SplitPair: Hashable, Sendable {
    var left: Int?
    var right: Int?
}

enum DiffSplit {
    /// 문맥 줄은 양쪽 같은 행, 변경 묶음은 −k 개와 +m 개를 나란히 (모자란 쪽은 빈 칸).
    /// 짝(`DiffLine.partner`, 줄 안 강조와 같은 짝)이 있으면 짝끼리 같은 행에 놓고, 짝 사이의 짝 없는 줄은 순서대로 나란히 둔다
    /// — 강조한 − 줄 옆에 엉뚱한 + 줄이 오지 않게. 짝이 순서대로면(수가 같은 묶음) max(k, m) 행, 아니면 그보다 많을 수 있다.
    /// 짝을 모르면(짝을 채우지 않은 줄) 순서대로 max(k, m) 행.
    /// "\ No newline" 표식은 그 줄이 속한 쪽에 따로 한 행 (문맥 줄 뒤면 양쪽).
    static func pairs(_ lines: [DiffLine]) -> [SplitPair] {
        var out: [SplitPair] = []
        var i = 0
        while i < lines.count {
            switch lines[i].kind {
            case .context:
                out.append(SplitPair(left: i, right: i))
                i += 1
            case .marker:
                let previous = i > 0 ? lines[i - 1].kind : .context
                out.append(SplitPair(left: previous == .added ? nil : i, right: previous == .removed ? nil : i))
                i += 1
            case .removed, .added:
                var removed: [Int] = [], added: [Int] = []
                var leftMarkers: [Int] = [], rightMarkers: [Int] = []
                while i < lines.count, lines[i].kind == .removed || (lines[i].kind == .marker && added.isEmpty
                                                                      && !removed.isEmpty) {
                    if lines[i].kind == .removed { removed.append(i) } else { leftMarkers.append(i) }
                    i += 1
                }
                while i < lines.count, lines[i].kind == .added || (lines[i].kind == .marker && !added.isEmpty) {
                    if lines[i].kind == .added { added.append(i) } else { rightMarkers.append(i) }
                    i += 1
                }
                out += blockPairs(removed: removed, added: added, lines: lines)
                for m in leftMarkers { out.append(SplitPair(left: m, right: nil)) }
                for m in rightMarkers { out.append(SplitPair(left: nil, right: m)) }
            }
        }
        return out
    }

    /// − 묶음과 + 묶음(줄 번호)의 행. 짝이 있으면 짝끼리 한 행, 짝 사이는 순서대로.
    private static func blockPairs(removed: [Int], added: [Int], lines: [DiffLine]) -> [SplitPair] {
        var addedPosition: [Int: Int] = [:]
        for (position, index) in added.enumerated() { addedPosition[index] = position }
        // (− 묶음 안 번호, + 묶음 안 번호). 짝은 순서를 지킨다 (`WordDiff.pairs`) — 어긋난 것은 버린다.
        var matched: [(Int, Int)] = []
        for (r, index) in removed.enumerated() {
            guard let partner = lines[index].partner, let a = addedPosition[partner] else { continue }
            if let last = matched.last, a <= last.1 { continue }
            matched.append((r, a))
        }
        var out: [SplitPair] = []
        func sideBySide(_ left: ArraySlice<Int>, _ right: ArraySlice<Int>) {
            for k in 0..<max(left.count, right.count) {
                out.append(SplitPair(left: k < left.count ? left[left.startIndex + k] : nil,
                                     right: k < right.count ? right[right.startIndex + k] : nil))
            }
        }
        var r = 0, a = 0
        for (mr, ma) in matched {
            sideBySide(removed[r..<mr], added[a..<ma])
            out.append(SplitPair(left: removed[mr], right: added[ma]))
            r = mr + 1
            a = ma + 1
        }
        sideBySide(removed[r...], added[a...])
        return out
    }
}

// MARK: - 화면 행

/// 한 칸 (통합 보기의 한 줄 · 나란히 보기의 한쪽).
struct DiffCell: Hashable, Sendable {
    var kind: DiffLine.Kind
    var oldNumber: Int?
    var newNumber: Int?
    /// 탭을 4칸 공백으로 편 표시 글자 (긴 줄은 한 조각).
    var text: String
    /// `text` 기준 강조 범위.
    var highlights: [Range<Int>] = []
    /// 충돌 표시 줄 (`<<<<<<<` · `=======` · `>>>>>>>` · `|||||||`) — 충돌 파일에서만.
    var conflictMarker = false
    /// 긴 줄을 나눈 뒤쪽 조각 (번호 · 부호를 쓰지 않는다).
    var continuation = false
}

struct DiffRow: Identifiable, Hashable, Sendable {
    enum ID: Hashable, Sendable {
        case hunk(Int)
        case line(hunk: Int, index: Int, chunk: Int)
        case split(hunk: Int, row: Int, chunk: Int)
        case gap(Int)
        case gapLine(gap: Int, index: Int, chunk: Int)
        case end
    }

    enum Content: Hashable, Sendable {
        /// "줄 14–22 · final class AuthViewModel" · 포함 상태 (일부 포함 파일일 때만 — `FileDiffDocument.showsHunkInclusion`).
        case hunk(label: String, inclusion: HunkInclusion?)
        case unified(DiffCell)
        case split(left: DiffCell?, right: DiffCell?)
        /// 변경 없는 줄 구간. `expandable` 이 false 면 옛 파일을 읽지 못해 펼칠 수 없다.
        case fold(gap: Int, label: String, expandable: Bool)
        /// 파일 끝 · 잘림 안내.
        case end(String)
    }

    var id: ID
    var content: Content
}

enum DiffRows {
    enum Mode: String, Hashable, Sendable {
        case unified, split
    }

    /// 한 행에 담는 최대 글자 수. 넘는 줄은 여러 행으로 나눈다 — 한 행이 수천 pt 가 되면 지연 스택이 높이를
    /// 추정하지 못해 멈춘다 (줄 하나를 한 행에 다 담던 때의 결함). 좁은 패널에서 한 조각은 줄바꿈해도 몇 줄 안 된다.
    static let chunkLength = 400
    static let tabWidth = 4

    struct Input: Sendable {
        var file: FileDiff
        var gaps: [DiffGap] = []
        /// 펼친 구간 (`gaps` 의 번호).
        var expanded: Set<Int> = []
        var oldLines: [String]?
        /// hunk 마다의 포함 상태. hunk 머리에 적는 것은 일부 포함 파일일 때만 (`showInclusion`).
        var inclusion: [HunkInclusion]?
        var showInclusion = false
        var conflicted = false
        var truncated = false
        var totalLines = 0
        var shownLines = 0
    }

    static func build(_ input: Input, mode: Mode) -> [DiffRow] {
        var rows: [DiffRow] = []
        // 잘린 diff 의 hunk 는 마지막(잘린) hunk 까지만 있다 (`UnifiedDiff.parse`). 그 뒤 구간은 알 수 없어 두지 않는다.
        let hunks = input.file.hunks
        rows.reserveCapacity(hunks.reduce(0) { $0 + $1.lines.count } + hunks.count * 2 + 2)
        var gapsByHunk: [Int: (Int, DiffGap)] = [:]
        for (index, gap) in input.gaps.enumerated() { gapsByHunk[gap.beforeHunk] = (index, gap) }

        func appendGap(_ index: Int, _ gap: DiffGap) {
            let expandable = gap.count != 0 && DiffGaps.lines(of: gap, oldLines: input.oldLines) != nil
            if input.expanded.contains(index), let lines = DiffGaps.lines(of: gap, oldLines: input.oldLines) {
                for (k, text) in lines.enumerated() {
                    let base = DiffCell(kind: .context, oldNumber: gap.oldStart + k, newNumber: gap.newStart + k,
                                        text: text)
                    for (c, cell) in cells(base).enumerated() {
                        let id = DiffRow.ID.gapLine(gap: index, index: k, chunk: c)
                        rows.append(DiffRow(id: id, content: mode == .split ? .split(left: cell.side(.left),
                                                                                       right: cell.side(.right))
                                                                            : .unified(cell)))
                    }
                }
                return
            }
            rows.append(DiffRow(id: .gap(index), content: .fold(gap: index, label: foldLabel(gap, expandable: expandable),
                                                                 expandable: expandable)))
        }

        for (h, hunk) in hunks.enumerated() {
            if let (index, gap) = gapsByHunk[h] { appendGap(index, gap) }
            let state = input.showInclusion ? input.inclusion.flatMap { h < $0.count ? $0[h] : nil } : nil
            rows.append(DiffRow(id: .hunk(h), content: .hunk(label: DiffText.hunkLabel(hunk), inclusion: state)))
            switch mode {
            case .unified:
                for (i, line) in hunk.lines.enumerated() {
                    for (c, cell) in cells(cell(line, conflicted: input.conflicted)).enumerated() {
                        rows.append(DiffRow(id: .line(hunk: h, index: i, chunk: c), content: .unified(cell)))
                    }
                }
            case .split:
                for (r, pair) in DiffSplit.pairs(hunk.lines).enumerated() {
                    let left = pair.left.map { cells(splitCell(hunk.lines[$0], side: .left, conflicted: input.conflicted)) }
                    let right = pair.right.map { cells(splitCell(hunk.lines[$0], side: .right,
                                                                 conflicted: input.conflicted)) }
                    let count = max(left?.count ?? 0, right?.count ?? 0)
                    for c in 0..<count {
                        // 긴 줄의 이어지는 조각에서 짝 쪽이 짧으면 빈 칸이 아니라 비워 둔 이어짐 칸이다 (빗금은 짝이 없는 줄에만).
                        func piece(_ list: [DiffCell]?) -> DiffCell? {
                            guard let list else { return nil }
                            if c < list.count { return list[c] }
                            var blank = list[0]
                            blank.text = ""
                            blank.highlights = []
                            blank.continuation = true
                            return blank
                        }
                        rows.append(DiffRow(id: .split(hunk: h, row: r, chunk: c),
                                            content: .split(left: piece(left), right: piece(right))))
                    }
                }
            }
        }
        if input.truncated {
            rows.append(DiffRow(id: .end, content: .end(DiffText.truncatedNote(shown: input.shownLines,
                                                                               total: input.totalLines))))
            return rows
        }
        if let (index, gap) = gapsByHunk[hunks.count] {
            appendGap(index, gap)
            if !input.expanded.contains(index) || DiffGaps.lines(of: gap, oldLines: input.oldLines) == nil {
                return rows
            }
        }
        if !hunks.isEmpty {
            rows.append(DiffRow(id: .end, content: .end("파일 끝 · 변경 \(hunks.count)곳")))
        }
        return rows
    }

    private static func foldLabel(_ gap: DiffGap, expandable: Bool) -> String {
        guard let count = gap.count else {
            return expandable ? "파일 끝까지 펼치기" : "파일 끝까지 · 줄 수 미확인"
        }
        return expandable ? "변경 없는 줄 \(count)개 펼치기" : "변경 없는 줄 \(count)개"
    }

    private static func cell(_ line: DiffLine, conflicted: Bool) -> DiffCell {
        DiffCell(kind: line.kind, oldNumber: line.oldNumber, newNumber: line.newNumber,
                 text: line.kind == .marker ? DiffText.markerText : line.text, highlights: line.highlights,
                 conflictMarker: conflicted && line.kind == .added && DiffText.isConflictMarker(line.text))
    }

    enum Side { case left, right }

    private static func splitCell(_ line: DiffLine, side: Side, conflicted: Bool) -> DiffCell {
        var c = cell(line, conflicted: conflicted)
        // 나란히 보기는 칸마다 번호 하나 (왼쪽 = 마지막 커밋, 오른쪽 = 지금 파일).
        if side == .left { c.newNumber = nil } else { c.oldNumber = nil }
        return c
    }

    /// 탭을 펴고 긴 줄을 조각으로 나눈다 (강조 범위도 함께 옮긴다).
    static func cells(_ base: DiffCell) -> [DiffCell] {
        let (text, highlights) = DiffText.expandTabs(base.text, highlights: base.highlights, width: tabWidth)
        guard text.count > chunkLength else {
            var cell = base
            cell.text = text
            cell.highlights = highlights
            return [cell]
        }
        let chars = Array(text)
        var out: [DiffCell] = []
        var start = 0
        while start < chars.count {
            let end = min(start + chunkLength, chars.count)
            var cell = base
            cell.text = String(chars[start..<end])
            cell.highlights = highlights.compactMap { r in
                let lo = max(r.lowerBound, start), hi = min(r.upperBound, end)
                return lo < hi ? (lo - start)..<(hi - start) : nil
            }
            if start > 0 {
                cell.continuation = true
                cell.oldNumber = nil
                cell.newNumber = nil
            }
            out.append(cell)
            start = end
        }
        return out
    }
}

private extension DiffCell {
    /// 펼친 문맥 줄을 나란히 보기의 한쪽 칸으로.
    func side(_ side: DiffRows.Side) -> DiffCell {
        var c = self
        if side == .left { c.newNumber = nil } else { c.oldNumber = nil }
        return c
    }
}

// MARK: - 코드 줄바꿈

/// 고정폭 글꼴로 그리는 ASCII 한 줄의 줄바꿈 (좁은 패널 · 나란히 보기). 칸 수 안의 마지막 공백 뒤에서 끊고(이어진 공백은 앞 줄 끝에
/// 매단다), 공백이 없으면 칸 수에서 자른다. CoreText 의 유니코드 줄바꿈 규칙은 공백 뒤라도 `.` 앞에서 끊지 않아(UAX #14 LB13)
/// `state = .signedOut(…)` 이 "state" 한 단어만 남기고 넘어간다 — 코드에는 이 단순한 규칙이 읽기 쉽다. 그리기도 같은 끊는 자리를 쓴다.
/// 한글 · 이모지처럼 ASCII 가 아닌 줄은 화면이 CoreText 로 나눈다.
/// 줄 앞 들여쓰기 안에서는 끊지 않는다 — 공백만 있는 첫 줄(번호만 붙은 빈 줄)과 0칸에서 시작하는 이어짐은 코드를 빈 줄 +
/// 내어쓴 줄로 잘못 읽히게 한다. 들여쓰기 뒤에 공백이 없으면 칸에서 자른다.
enum DiffWrap {
    static func asciiLines(_ bytes: [UInt8], columns: Int) -> [Range<Int>] {
        let n = bytes.count
        guard n > 0 else { return [0..<0] }
        let width = max(1, columns)
        let space: UInt8 = 0x20
        /// lo..<hi 에 공백이 아닌 글자가 있는지 (그 자리의 공백은 들여쓰기가 아니다).
        func hasText(_ lo: Int, _ hi: Int) -> Bool { bytes[lo..<hi].contains { $0 != space } }
        var out: [Range<Int>] = []
        var start = 0
        while start < n {
            if n - start <= width {
                out.append(start..<n)
                break
            }
            var end = start + width
            if bytes[end] == space {
                // 칸 끝이 공백이면 거기서 끊고, 이어진 공백은 이 줄 끝에 매단다. 칸 전체가 들여쓰기면 칸에서 자른다
                // (칸보다 깊은 들여쓰기 — 남은 들여쓰기는 다음 줄로).
                if hasText(start, end) {
                    while end < n, bytes[end] == space { end += 1 }
                }
                out.append(start..<end)
                start = end
                continue
            }
            var k = end - 1
            while k > start, bytes[k] != space { k -= 1 }
            if bytes[k] == space, hasText(start, k) {
                out.append(start..<(k + 1))
                start = k + 1
            } else {
                out.append(start..<end)
                start = end
            }
        }
        return out
    }
}

// MARK: - 문구 · 글자

enum DiffText {
    /// "\ No newline at end of file" 표식 줄에 쓰는 말 (git 의 원문은 번역될 수 있어 쓰지 않는다).
    static let markerText = "파일 끝에 줄바꿈 문자가 없습니다"

    /// "줄 14–22 · final class AuthViewModel" — 새 쪽 범위 + git 이 준 함수 문맥 (없으면 범위만).
    /// 새 쪽 줄이 없는 hunk(파일 전체 삭제 등)는 옛 쪽 범위로 "옛 줄 1–3".
    static func hunkLabel(_ hunk: DiffHunk) -> String {
        let range: String
        if hunk.newCount > 0 {
            let end = hunk.newStart + hunk.newCount - 1
            range = end == hunk.newStart ? "줄 \(hunk.newStart)" : "줄 \(hunk.newStart)–\(end)"
        } else if hunk.oldCount > 0 {
            let end = hunk.oldStart + hunk.oldCount - 1
            range = end == hunk.oldStart ? "옛 줄 \(hunk.oldStart)" : "옛 줄 \(hunk.oldStart)–\(end)"
        } else {
            range = "빈 파일"
        }
        guard let section = hunk.section, !section.isEmpty else { return range }
        return range + " · " + section
    }

    static func truncatedNote(shown: Int, total: Int) -> String {
        "diff 가 길어 앞의 \(shown.formatted())줄만 보여줍니다 · 전체 \(total.formatted())줄 · 나머지는 터미널의 git diff 로"
    }

    static func isConflictMarker(_ text: String) -> Bool {
        text.hasPrefix("<<<<<<<") || text.hasPrefix(">>>>>>>") || text.hasPrefix("|||||||") || text == "======="
            || text.hasPrefix("======= ")
    }

    /// 탭을 `width` 칸 단위 공백으로 편다. 강조 범위(`Character` 오프셋)도 편 글자 기준으로 옮긴다.
    static func expandTabs(_ text: String, highlights: [Range<Int>], width: Int) -> (String, [Range<Int>]) {
        guard text.utf8.contains(9) else { return (text, highlights) }
        var out = ""
        var map: [Int] = []   // 원래 글자 i → 편 글자 오프셋
        var column = 0
        for c in text {
            map.append(column)
            if c == "\t" {
                let spaces = width - column % width
                out.append(String(repeating: " ", count: spaces))
                column += spaces
            } else {
                out.append(c)
                column += 1
            }
        }
        map.append(column)
        let moved = highlights.compactMap { r -> Range<Int>? in
            guard r.lowerBound >= 0, r.upperBound < map.count else { return nil }
            return map[r.lowerBound]..<map[r.upperBound]
        }
        return (out, moved)
    }
}

// MARK: - 조회 요청 · 결과

/// 파일 하나의 diff 조회 요청 (`GitWorkspace.fileDiff`). 목록 행 · git 상태로 만든다.
struct FileDiffRequest: Hashable, Sendable {
    /// 저장소 루트 기준.
    var path: String
    /// 이름 변경 전 경로 (함께 넘겨 git 이 이름 변경으로 짝짓게 한다).
    var originalPath: String?
    /// git 이 추적하지 않는 새 파일 (`git diff --no-index /dev/null <경로>`).
    var untracked: Bool
    var conflicted: Bool
    /// 목록 체크 상태 — on 이면 hunk 전부 on, off 면 전부 off, 일부면 `git diff --cached` 와 대조한다.
    var inclusion: ChangesState.Inclusion
    /// 첫 커밋 전 (HEAD 가 없다).
    var noCommitsYet: Bool
    /// 마지막 커밋 대비 줄 수 합 (numstat). 모르면 nil. 너무 크면 diff 를 부르지 않는다.
    var changedLines: Int?
    /// 이 요청을 만든 git 상태를 읽은 시각 — 상태를 다시 읽으면 diff 도 다시 읽는다 (자동 폴링은 없다).
    var statusReadAt: Date?

    static func make(for row: ChangesState.Row, status: GitWorkspaceStatus) -> FileDiffRequest {
        let changed: Int? = (row.added == nil && row.removed == nil) ? nil : (row.added ?? 0) + (row.removed ?? 0)
        return FileDiffRequest(path: row.path, originalPath: row.originalPath, untracked: row.isUntracked,
                               conflicted: row.inclusion == .conflict, inclusion: row.inclusion,
                               noCommitsYet: status.noCommitsYet, changedLines: changed,
                               statusReadAt: status.fetchedAt)
    }
}

/// 조회 결과. 파싱 · 단어 강조 · 포함 상태 · 옛 파일 줄까지 백그라운드에서 만든 뒤 화면에 넘긴다.
struct FileDiffDocument: Sendable {
    enum Body: Equatable, Sendable {
        case diff
        case binary
        /// 보여줄 줄이 없다 (이름만 바뀜 · 권한만 바뀜 · 빈 새 파일 · 그 사이 되돌림 …). 사실 한 줄.
        case noLines(String)
        /// 내용 비교를 하지 않았다 (너무 큼 · 폴더). 이유 한 줄.
        case skipped(String)
        case failed(String)
    }

    /// 결과 한 번마다 새 값 (화면이 행을 다시 만들지 판단한다).
    var id = UUID()
    var request: FileDiffRequest
    var body: Body = .failed("읽지 않았습니다")
    var file: FileDiff?
    /// hunk 마다의 포함 상태. 충돌 · 이진 · 잘린 일부 포함 diff 면 nil.
    var inclusion: DiffInclusion.Result?
    /// 포함 상태를 확인하지 못한 이유 (캐시 diff 조회 실패). 없으면 nil.
    var inclusionNote: String?
    /// 캐시 쪽(스테이지)에서만 보이는 파일 단위 변경 ("이름 변경" · "권한 변경").
    var stagedFileChanges: [String] = []
    /// 옛 파일(HEAD) 줄. 펼치기에 쓴다. 못 읽었거나 너무 크면 nil (펼칠 수 없다).
    var oldLines: [String]?
    var gaps: [DiffGap] = []
    var totalLines = 0
    var shownLines = 0
    /// 실행한 조회 명령 (도움말).
    var command = ""
    /// 사실 안내 (첫 커밋 전 · 이름 변경으로 짝짓지 못함 등).
    var notes: [String] = []

    /// 충돌 파일에서 diff 에 보인 충돌 표시 줄 수 (`<<<<<<<` · `=======` · `>>>>>>>` · `|||||||`). 충돌 파일이 아니면 0.
    var conflictMarkerLines = 0

    var truncated: Bool { shownLines < totalLines }
    var hunkCount: Int { file?.hunks.count ?? 0 }
    /// hunk 머리에 포함 상태를 적는지 — 일부 포함 파일(`git diff --cached` 와 대조한 파일)이고 판정이 있을 때만.
    /// 전부 포함 · 전부 빼기인 파일은 적지 않는다 (목업 — 모든 hunk 가 같은 말이라 목록 체크가 이미 말한다).
    /// 일부 포함 파일은 hunk 마다 상태가 같아도 적는다 (한 hunk 만 줄 단위로 스테이지된 파일의 "일부" 를 보이게).
    var showsHunkInclusion: Bool { request.inclusion == .mixed && inclusion != nil }
}

enum FileDiffLimits {
    /// 화면에 담는 diff 본문 줄 수. 넘으면 앞부분만 보이고 잘렸다고 밝힌다.
    static let displayLines = 20_000
    /// 마지막 커밋 대비 줄 수(numstat)가 이보다 많으면 diff 를 부르지 않는다.
    static let skipLines = 200_000
    /// 이보다 큰 파일은 diff 를 부르지 않는다.
    static let fileBytes = 16 * 1024 * 1024
    /// 펼치기용으로 읽는 옛 파일의 최대 크기.
    static let oldBlobBytes = 8 * 1024 * 1024

    static func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

enum FileDiffBuild {
    /// 파싱한 diff 에서 요청한 파일 하나를 고르고 (이름 변경을 git 이 짝짓지 못하면 새 경로 쪽), 줄 안 강조를 채운다.
    /// 경로가 맞는 파일만 고른다 — 다른 파일의 diff 를 이 파일 이름으로 보이지 않게 (없으면 nil = 차이 없음).
    static func pick(_ parse: UnifiedDiff.Parse, path: String, originalPath: String?) -> (FileDiff?, [String]) {
        var notes: [String] = []
        let match = parse.files.first { $0.newPath == path }
            ?? parse.files.first { $0.oldPath == path && $0.newPath == nil }
        if let originalPath, match?.isRename != true,
           parse.files.contains(where: { $0.oldPath == originalPath && $0.isDeleted }) {
            notes.append("원래 파일(\(originalPath))과 내용이 많이 달라 git 이 이름 변경으로 짝짓지 않았습니다 — 새 파일로 보여줍니다.")
        }
        guard var file = match else { return (nil, notes) }
        for index in file.hunks.indices {
            WordDiff.annotate(&file.hunks[index].lines)
        }
        return (file, notes)
    }

    /// hunk 가 없는 diff 를 한 줄 사실로 (이진 · 이름만 · 권한만 · 빈 새 파일 · 차이 없음).
    static func noLinesReason(_ file: FileDiff?) -> FileDiffDocument.Body {
        guard let file else {
            return .noLines("마지막 커밋과 지금 파일 사이에 차이가 없습니다 — 그 사이 되돌렸을 수 있습니다.")
        }
        if file.isBinary || (!file.otherHeaderLines.isEmpty && file.hunks.isEmpty) { return .binary }
        if file.isRename, file.similarity == 100 { return .noLines("내용은 같고 이름만 바뀌었습니다.") }
        if let old = file.oldMode, let new = file.newMode, old != new {
            return .noLines("내용은 같고 파일 권한만 바뀌었습니다 (\(old) → \(new)).")
        }
        if file.isNewFile { return .noLines("빈 새 파일입니다.") }
        if file.isDeleted { return .noLines("빈 파일을 지웠습니다.") }
        return .noLines("마지막 커밋과 지금 파일 사이에 차이가 없습니다 — 그 사이 되돌렸을 수 있습니다.")
    }

    /// diff 에 보인 충돌 표시 줄 수 (작업 트리 쪽 = 더한 줄). 표시를 지우고 저장했으면 0 — 화면이 "표시가 남았다" 고 말하는 근거.
    static func conflictMarkerLines(_ file: FileDiff) -> Int {
        file.hunks.reduce(0) { sum, hunk in
            sum + hunk.lines.reduce(0) { $0 + ($1.kind == .added && DiffText.isConflictMarker($1.text) ? 1 : 0) }
        }
    }

    /// 캐시 diff 에만 있는 파일 단위 변경.
    static func stagedFileChanges(_ cached: FileDiff?) -> [String] {
        guard let cached else { return [] }
        var out: [String] = []
        if cached.isRename { out.append("이름 변경") }
        if let old = cached.oldMode, let new = cached.newMode, old != new { out.append("권한 변경") }
        return out
    }
}
