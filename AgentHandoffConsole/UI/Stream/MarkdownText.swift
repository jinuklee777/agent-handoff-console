import AppKit
import QuartzCore

// 대화 메시지(Markdown)를 NSTextView 하나에 그린다. 제목 · 문단 · 목록 · 코드 블록 · 표 · 구분선이 한 텍스트라
// 끌어 선택 · ⌘A · ⌘C 가 블록 경계를 넘는다 (SwiftUI Text 의 선택은 Text 하나 안에 갇혀 블록마다 따로만 복사됐다).
// 코드 상자와 표는 TextKit 1 의 텍스트 블록(NSTextBlock · NSTextTable)이다 — TextKit 2 에는 표가 없다.
// 해석(`MarkdownBlock`) · 글자 짓기(`MarkdownDocument`) · 복사 글(`MarkdownCopy`)은 화면 없이 검증한다 (MarkdownTests).
// SwiftUI 쪽 입구와 Theme 색은 Markdown.swift 의 `MarkdownMessage`.

// MARK: - 해석

struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(Int, String)
        case paragraph(String)
        case code(String?, String)
        case table([[String]])
        case rule
        /// 친 그대로의 글 (사용자 메시지 — `parsePlain`). 줄 안 서식 · 제목 · 목록 · 표를 해석하지 않는다.
        case plain(String)
    }

    let id: Int
    let kind: Kind

    /// 사람이 친 글 (사용자 메시지): 코드 울타리(``` · ~~~)만 코드 상자로, 나머지는 친 그대로의 글 덩어리로 — 줄 안 서식 · 제목 ·
    /// 목록 · 표 · `<br>` 을 해석하지 않는다. 붙여 넣은 오류의 `__init__` · `# ` 줄 · `*` 가 그대로 보인다 (첫 사용자 시험 chat-10).
    /// 덩어리 앞뒤의 빈 줄만 뺀다 (덩어리 사이 간격이 대신한다). 원문은 텍스트 뷰가 따로 가진다 — 통째로 복사하면 원문 그대로.
    static func parsePlain(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var text: [String] = []
        func flushText() {
            let isBlank: (String) -> Bool = { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            if let first = text.firstIndex(where: { !isBlank($0) }), let last = text.lastIndex(where: { !isBlank($0) }) {
                blocks.append(MarkdownBlock(id: blocks.count, kind: .plain(text[first...last].joined(separator: "\n"))))
            }
            text = []
        }
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard let fence = fence(in: trimmed) else {
                text.append(lines[index])
                index += 1
                continue
            }
            flushText()
            let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
            index += 1
            var code: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                code.append(lines[index])
                index += 1
            }
            if index < lines.count { index += 1 }
            blocks.append(MarkdownBlock(id: blocks.count, kind: .code(language.isEmpty ? nil : language,
                                                                     code.joined(separator: "\n"))))
        }
        flushText()
        return blocks
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var index = 0

        func append(_ kind: Kind) {
            blocks.append(MarkdownBlock(id: blocks.count, kind: kind))
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = fence(in: trimmed) {
                let language = String(trimmed.dropFirst(fence.count))
                    .trimmingCharacters(in: .whitespaces)
                index += 1
                var code: [String] = []
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                append(.code(language.isEmpty ? nil : language, code.joined(separator: "\n")))
                continue
            }

            if let heading = heading(in: trimmed) {
                append(.heading(heading.level, heading.text))
                index += 1
                continue
            }

            if isRule(trimmed) {
                append(.rule)
                index += 1
                continue
            }

            if index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                var rows = [splitTableRow(line)]
                index += 2 // 구분선은 표시하지 않는다.
                while index < lines.count {
                    let candidate = lines[index]
                    guard !candidate.trimmingCharacters(in: .whitespaces).isEmpty,
                          containsTableDivider(candidate) else { break }
                    rows.append(splitTableRow(candidate))
                    index += 1
                }
                append(.table(rows))
                continue
            }

            var paragraph = [line]
            index += 1
            while index < lines.count {
                let candidate = lines[index]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                if candidateTrimmed.isEmpty { break }
                if fence(in: candidateTrimmed) != nil || heading(in: candidateTrimmed) != nil
                    || isRule(candidateTrimmed)
                    || (index + 1 < lines.count && isTableSeparator(lines[index + 1])) {
                    break
                }
                paragraph.append(candidate)
                index += 1
            }
            append(.paragraph(paragraph.joined(separator: "\n")))
        }
        return blocks
    }

    private static func fence(in line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let remainder = line.dropFirst(hashes)
        guard remainder.first == " " else { return nil }
        return (hashes, String(remainder.dropFirst()))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = splitTableRow(line)
        guard cells.count > 1 else { return false }
        return cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: .whitespaces)
            let dashes = value.filter { $0 == "-" }.count
            return dashes >= 3 && value.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func containsTableDivider(_ line: String) -> Bool {
        var escaped = false
        for character in line {
            if character == "|" && !escaped { return true }
            if character == "\\" && !escaped { escaped = true } else { escaped = false }
        }
        return false
    }

    /// `\|` 는 셀 구분자가 아니라 실제 파이프 문자로 되돌린다.
    private static func splitTableRow(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.first == "|" { value.removeFirst() }
        if value.last == "|" { value.removeLast() }

        var cells: [String] = []
        var current = ""
        let characters = Array(value)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count,
               characters[index + 1] == "|" {
                current.append("|")
                index += 1
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
}

// MARK: - 모양

/// 메시지 본문의 색. 모두 동적 색이라 그릴 때 밝은 · 어두운 보기에 맞춰 풀린다.
struct MarkdownStyle {
    /// 문단 글자 (에이전트 ink2 · 사용자 ink).
    var text: NSColor
    /// 제목 · 표 머리 행.
    var heading: NSColor
    var link: NSColor
    var inlineCodeText: NSColor
    var inlineCodeBackground: NSColor
    var codeText: NSColor
    var codeBackground: NSColor
    var codeHeader: NSColor
    var codeBorder: NSColor
    /// 코드 상자 머리의 언어 이름 · "복사" 글자.
    var codeLabel: NSColor
    /// "복사됨".
    var codeCopied: NSColor
    var tableText: NSColor
    var tableHeaderRule: NSColor
    var tableRule: NSColor
    var rule: NSColor
}

/// 크기 · 간격. 글자는 4단계(`TypeScale`)를 따른다: 본문 14 · 줄간 1.62 · 코드 · 표 12.5 · 코드 상자 이름 11.5 · 큰 제목 20.
enum MarkdownMetrics {
    static let bodySize: CGFloat = TypeScale.body.size
    static let blockSpacing: CGFloat = 10
    /// 큰 제목(#, ##) 위에 더하는 여백.
    static let headingExtraTop: CGFloat = 4
    static let codeSize: CGFloat = TypeScale.callout.size
    static let codeLineSpacing: CGFloat = 5
    static let codeInset = NSSize(width: 12, height: 9)
    static let codeRadius: CGFloat = 7
    static let codeLabelFont = NSFont.monospacedSystemFont(ofSize: TypeScale.caption.size, weight: .semibold)
    static let codeButtonFont = NSFont.monospacedSystemFont(ofSize: TypeScale.caption.size, weight: .regular)
    /// 언어 이름 띠 (글자 한 줄 + 위아래 5).
    static let codeHeaderHeight: CGFloat = ceil(codeLabelFont.ascender - codeLabelFont.descender + codeLabelFont.leading) + 10
    static let tableSize: CGFloat = TypeScale.callout.size
    static let cellInset = NSSize(width: 10, height: 6)
    /// 표 열 너비(안쪽 여백 포함) — 가장 긴 줄에 맞추되 이 범위 안. 합이 본문보다 넓으면 표가 비율대로 줄인다.
    static let columnWidth: ClosedRange<CGFloat> = 120...340

    /// 줄간 1.62 — 줄 사이를 글자 크기 × 0.41 만큼 띄운다 (SwiftUI `lineSpacing` 과 같은 뜻).
    static func lineSpacing(_ size: CGFloat) -> CGFloat { size * 0.41 }

    /// `#` 는 title(20), 나머지 제목은 본문 크기 · semibold (굵기와 위 여백으로 가른다).
    static func headingSize(_ level: Int) -> CGFloat {
        level == 1 ? TypeScale.title.size : TypeScale.body.size
    }

    /// 줄 안 코드: 본문 · 제목 안은 callout, 그보다 작은 글(표) 안은 caption — SF Mono 는 같은 크기의 SF Pro 보다 넓다.
    static func inlineCodeSize(around size: CGFloat) -> CGFloat {
        size >= TypeScale.body.size ? TypeScale.callout.size : TypeScale.caption.size
    }
}

extension NSAttributedString.Key {
    /// 복사에서 빼는 글자 — 구분선 · 빈 코드 · 빈 칸의 자리 글자.
    static let markdownSkipOnCopy = NSAttributedString.Key("AHCMarkdownSkipOnCopy")
    /// 블록 사이 줄바꿈. 화면 간격은 문단 간격이 맡고, 복사하면 빈 줄 하나("\n\n")가 된다.
    static let markdownBlockBreak = NSAttributedString.Key("AHCMarkdownBlockBreak")
    /// 표에서 같은 행의 다음 칸으로 넘어가는 줄바꿈. 복사하면 탭 — 문서 · 스프레드시트에 표로 붙는다.
    static let markdownCellBreak = NSAttributedString.Key("AHCMarkdownCellBreak")
}

// MARK: - 글자 짓기

/// Markdown 원문 하나를 그릴 글자와, 복사 단추를 얹을 코드 블록 자리.
struct MarkdownDocument {
    struct CodeBlock {
        let box: MarkdownCodeBox
        /// 상자의 글자 범위 (끝 줄바꿈 포함).
        var range: NSRange
        let code: String
    }

    let text: NSAttributedString
    let codeBlocks: [CodeBlock]
    /// 첫 블록이 큰 제목이면 위에 더하는 여백. TextKit 은 맨 첫 문단의 문단 앞 간격을 쓰지 않는다.
    let topInset: CGFloat

    /// - Parameters:
    ///   - plain: 사람이 친 글 — 코드 울타리만 상자로, 나머지는 친 그대로 (`MarkdownBlock.parsePlain`).
    ///   - linkBase: 상대 경로 링크를 풀 폴더 (대화의 프로젝트 폴더). 열 수 없는 링크는 링크로 그리지 않는다 (`LinkOpener.renderable`).
    ///   - fileExists: 파일 링크를 그릴지 볼 때 — 시험이 바꾼다.
    init(source: String, style: MarkdownStyle, plain: Bool = false, linkBase: String? = nil,
         fileExists: @escaping (String) -> Bool = LinkOpener.fileExists) {
        let blocks = plain ? MarkdownBlock.parsePlain(source) : MarkdownBlock.parse(source)
        let builder = MarkdownBuilder(style: style, linkBase: linkBase, fileExists: fileExists)
        for (index, block) in blocks.enumerated() {
            builder.append(block, first: index == 0, last: index == blocks.count - 1)
        }
        text = builder.out
        codeBlocks = builder.codeBlocks
        if case .heading(let level, _)? = blocks.first?.kind, level <= 2 {
            topInset = MarkdownMetrics.headingExtraTop
        } else {
            topInset = 0
        }
    }
}

/// 블록을 차례로 이어 붙인다. 블록 사이 줄바꿈은 앞 블록의 마지막 문단에 속한다 (그 문단 모양 · 텍스트 블록을 그대로 쓴다).
///
/// TextKit 1 은 줄바꿈으로 끝나는 줄 아래에 줄 간격을 붙이고 글 전체의 마지막 줄에는 붙이지 않는다. 그래서 블록 사이 간격은
/// "10 − 앞 블록 마지막 줄의 간격", 코드 상자 · 표 칸의 아래 여백은 뒤에 줄바꿈이 올 때만 줄 간격만큼 줄인다.
private final class MarkdownBuilder {
    let style: MarkdownStyle
    let out = NSMutableAttributedString()
    private(set) var codeBlocks: [MarkdownDocument.CodeBlock] = []
    /// 지금 블록의 마지막 문단을 끝낼 줄바꿈의 속성.
    private var terminator: [NSAttributedString.Key: Any] = [:]
    /// 앞 블록의 마지막 줄 아래에 이미 붙은 줄 간격 (문단 · 제목). 상자 · 표 · 구분선은 0.
    private var trailingSpacing: CGFloat = 0

    private static let listMarker = try! NSRegularExpression(pattern: #"^[ \t]*(?:[-*+•]|\d{1,3}[.)])[ \t]+"#)
    /// 상대 경로 링크를 풀 폴더 (없으면 상대 경로는 링크로 그리지 않는다).
    private let linkBase: String?
    private let fileExists: (String) -> Bool

    init(style: MarkdownStyle, linkBase: String? = nil, fileExists: @escaping (String) -> Bool = LinkOpener.fileExists) {
        self.style = style
        self.linkBase = linkBase
        self.fileExists = fileExists
    }

    /// 줄 나눔은 SwiftUI Text 와 같은 표준 규칙 — 한글을 음절 중간이 아니라 어절 · 짧은 조각 밀어내기로 나눈다.
    static func paragraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakStrategy = .standard
        return style
    }

    func append(_ block: MarkdownBlock, first: Bool, last: Bool) {
        if !first { appendBreak() }
        let gap = first ? 0 : MarkdownMetrics.blockSpacing - trailingSpacing
        switch block.kind {
        case .heading(let level, let value):
            let size = MarkdownMetrics.headingSize(level)
            let extra = !first && level <= 2 ? MarkdownMetrics.headingExtraTop : 0
            appendLines(inline(value, size: size, weight: .semibold, color: style.heading),
                        size: size, weight: .semibold, spacingBefore: gap + extra, listIndent: false)
        case .paragraph(let value):
            let size = MarkdownMetrics.bodySize
            appendLines(inline(value, size: size, weight: .regular, color: style.text),
                        size: size, weight: .regular, spacingBefore: gap, listIndent: true)
        case .plain(let value):
            let size = MarkdownMetrics.bodySize
            appendLines(NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: size),
                                                                       .foregroundColor: style.text]),
                        size: size, weight: .regular, spacingBefore: gap, listIndent: true)
        case .code(let language, let code):
            appendCode(language: language, code: code, gap: gap, last: last)
        case .table(let rows):
            appendTable(rows, gap: gap, last: last)
        case .rule:
            appendRule(gap: gap)
        }
    }

    private func appendBreak() {
        // 코드 상자를 끝내는 줄바꿈도 상자 범위에 넣는다 — 배치 관리자는 상자 전체 범위로만 자리를 알려 준다 (`boundsRect`).
        if let last = codeBlocks.indices.last, NSMaxRange(codeBlocks[last].range) == out.length {
            codeBlocks[last].range.length += 1
        }
        var attributes = terminator
        attributes[.markdownBlockBreak] = true
        out.append(NSAttributedString(string: "\n", attributes: attributes))
    }

    /// 제목 · 문단. 원문의 줄바꿈은 그대로 줄바꿈(TextKit 문단)이라, 문단 앞 간격은 첫 줄에만 준다.
    /// 목록 줄("- ", "1. ")은 넘친 줄을 머리 너비만큼 들여 쓴다.
    private func appendLines(_ content: NSAttributedString, size: CGFloat, weight: NSFont.Weight,
                             spacingBefore: CGFloat, listIndent: Bool) {
        let start = out.length
        out.append(content)
        let text = out.string
        let string = text as NSString
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let lineSpacing = MarkdownMetrics.lineSpacing(size)
        var paragraph = MarkdownBuilder.paragraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacingBefore = spacingBefore
        var location = start
        while location < out.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            paragraph = MarkdownBuilder.paragraphStyle()
            paragraph.lineSpacing = lineSpacing
            paragraph.paragraphSpacingBefore = location == start ? spacingBefore : 0
            if listIndent, let marker = Self.listMarker.firstMatch(in: text, range: range) {
                paragraph.headIndent = ceil(out.attributedSubstring(from: marker.range).size().width)
            }
            out.addAttribute(.paragraphStyle, value: paragraph, range: range)
            location = NSMaxRange(range)
        }
        terminator = [.font: font, .foregroundColor: style.text, .paragraphStyle: paragraph]
        trailingSpacing = lineSpacing
    }

    private func appendCode(language: String?, code: String, gap: CGFloat, last: Bool) {
        let inset = MarkdownMetrics.codeInset
        let box = MarkdownCodeBox(label: (language?.isEmpty == false ? language! : "code").uppercased(),
                                  style: style)
        box.setValue(100, type: .percentageValueType, for: .width)
        box.setWidth(gap, type: .absoluteValueType, for: .margin, edge: .minY)
        box.setWidth(inset.width, type: .absoluteValueType, for: .padding, edge: .minX)
        box.setWidth(inset.width, type: .absoluteValueType, for: .padding, edge: .maxX)
        box.setWidth(MarkdownMetrics.codeHeaderHeight + inset.height, type: .absoluteValueType, for: .padding,
                     edge: .minY)
        box.setWidth(last ? inset.height : inset.height - MarkdownMetrics.codeLineSpacing,
                     type: .absoluteValueType, for: .padding, edge: .maxY)

        let font = NSFont.monospacedSystemFont(ofSize: MarkdownMetrics.codeSize, weight: .regular)
        let paragraph = MarkdownBuilder.paragraphStyle()
        paragraph.textBlocks = [box]
        paragraph.lineSpacing = MarkdownMetrics.codeLineSpacing
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 4 * (" " as NSString).size(withAttributes: [.font: font]).width
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: style.codeText, .paragraphStyle: paragraph,
        ]
        let start = out.length
        if code.isEmpty {
            // 글자가 하나도 없으면 상자가 생기지 않는다.
            var placeholder = attributes
            placeholder[.markdownSkipOnCopy] = true
            out.append(NSAttributedString(string: "\u{200B}", attributes: placeholder))
        } else {
            out.append(NSAttributedString(string: code, attributes: attributes))
        }
        codeBlocks.append(.init(box: box, range: NSRange(location: start, length: out.length - start), code: code))
        terminator = attributes
        trailingSpacing = 0
    }

    private func appendTable(_ rows: [[String]], gap: CGFloat, last: Bool) {
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return }
        let size = MarkdownMetrics.tableSize
        let lineSpacing = MarkdownMetrics.lineSpacing(size)
        let inset = MarkdownMetrics.cellInset

        // 칸 안 줄바꿈(<br>)은 줄 구분자(U+2028)로 — 칸 하나가 한 문단으로 남아야 표가 흩어지지 않는다.
        let cells: [[NSAttributedString]] = rows.enumerated().map { rowIndex, row in
            (0..<columns).map { column in
                let header = rowIndex == 0
                let content = NSMutableAttributedString(attributedString: inline(
                    column < row.count ? row[column] : "", size: size, weight: header ? .semibold : .regular,
                    color: header ? style.heading : style.tableText))
                content.mutableString.replaceOccurrences(of: "\n", with: "\u{2028}", options: [],
                                                         range: NSRange(location: 0, length: content.length))
                return content
            }
        }
        let widths: [CGFloat] = (0..<columns).map { column in
            let longest = cells.map { widestLine($0[column]) }.max() ?? 0
            let width = min(MarkdownMetrics.columnWidth.upperBound,
                            max(MarkdownMetrics.columnWidth.lowerBound, ceil(longest) + 24))
            return width - 2 * inset.width
        }

        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setWidth(gap, type: .absoluteValueType, for: .margin, edge: .minY)

        for (rowIndex, row) in cells.enumerated() {
            let header = rowIndex == 0
            let font = NSFont.systemFont(ofSize: size, weight: header ? .semibold : .regular)
            for (column, content) in row.enumerated() {
                let lastCell = rowIndex == cells.count - 1 && column == columns - 1
                let cell = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                            startingColumn: column, columnSpan: 1)
                cell.setValue(widths[column], type: .absoluteValueType, for: .width)
                cell.setWidth(inset.width, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(inset.width, type: .absoluteValueType, for: .padding, edge: .maxX)
                cell.setWidth(inset.height, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(lastCell && last ? inset.height : inset.height - lineSpacing,
                              type: .absoluteValueType, for: .padding, edge: .maxY)
                cell.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                cell.setBorderColor(header ? style.tableHeaderRule : style.tableRule, for: .maxY)
                let paragraph = MarkdownBuilder.paragraphStyle()
                paragraph.textBlocks = [cell]
                paragraph.lineSpacing = lineSpacing
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]

                let text = NSMutableAttributedString(attributedString: content)
                if text.length == 0 {
                    text.append(NSAttributedString(string: "\u{200B}", attributes: [.font: font, .markdownSkipOnCopy: true]))
                }
                text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
                out.append(text)
                if lastCell {
                    // 마지막 칸은 다음 블록 앞의 줄바꿈이 끝낸다.
                    terminator = attributes
                } else {
                    var end = attributes
                    if column < columns - 1 { end[.markdownCellBreak] = true }
                    out.append(NSAttributedString(string: "\n", attributes: end))
                }
            }
        }
        trailingSpacing = 0
    }

    /// 윗변만 그린 1pt 높이 블록. 예전 모양(간격 10 · 위아래 2 · 선 1)과 같은 높이.
    private func appendRule(gap: CGFloat) {
        let block = NSTextBlock()
        block.setValue(100, type: .percentageValueType, for: .width)
        block.setWidth(gap + 2, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
        block.setBorderColor(style.rule, for: .minY)
        block.setWidth(1, type: .absoluteValueType, for: .margin, edge: .maxY)
        let paragraph = MarkdownBuilder.paragraphStyle()
        paragraph.textBlocks = [block]
        paragraph.minimumLineHeight = 1
        paragraph.maximumLineHeight = 1
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 1), .paragraphStyle: paragraph, .markdownSkipOnCopy: true,
        ]
        out.append(NSAttributedString(string: " ", attributes: attributes))
        terminator = attributes
        trailingSpacing = 0
    }

    /// 줄 안 서식: 굵게 · 기울임 · 취소선 · `코드` · 링크. `<br>` 은 줄바꿈으로.
    private func inline(_ source: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        let normalized = source.replacingOccurrences(
            of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        let parsed = (try? AttributedString(markdown: normalized, options: options)) ?? AttributedString(normalized)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            let bold = intent.contains(.stronglyEmphasized)
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            var font: NSFont
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: MarkdownMetrics.inlineCodeSize(around: size), weight: bold ? .bold : .regular)
                attributes[.backgroundColor] = style.inlineCodeBackground
                attributes[.foregroundColor] = style.inlineCodeText
            } else {
                font = .systemFont(ofSize: size, weight: bold ? .bold : weight)
            }
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            // 열 수 없는 링크(풀 수 없는 상대 경로 · 없는 파일)는 링크로 그리지 않는다 — 손가락 커서가 뜨는데 눌러도 아무 일이
            // 없었다. 파일 링크는 푼 file:// 주소를 단다 (누르면 Finder 에서 보인다 — 실행하지 않는다).
            if let link = run.link, let target = LinkOpener.renderable(link, baseDirectory: linkBase, fileExists: fileExists) {
                attributes[.link] = target
                attributes[.foregroundColor] = style.link
            }
            attributes[.font] = font
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }

    private func widestLine(_ text: NSAttributedString) -> CGFloat {
        let string = text.string as NSString
        var widest: CGFloat = 0
        var start = 0
        for index in 0...string.length where index == string.length || string.character(at: index) == 0x2028 {
            let line = text.attributedSubstring(from: NSRange(location: start, length: index - start))
            widest = max(widest, line.size().width)
            start = index + 1
        }
        return widest
    }
}

// MARK: - 복사

/// 고른 범위를 붙여 넣기 좋은 평문으로: 블록 사이는 빈 줄, 표는 칸마다 탭 · 행마다 줄바꿈,
/// 커서 · 구분선 · 빈 칸의 자리 글자는 뺀다. 서식 기호(`**`, `#`)는 붙이지 않는다 — 화면에 보이는 글 그대로.
enum MarkdownCopy {
    static func plainText(_ text: NSAttributedString, ranges: [NSRange]) -> String {
        ranges.filter { $0.length > 0 }.map { plainText(text, range: $0) }.joined(separator: "\n")
    }

    static func plainText(_ text: NSAttributedString, range: NSRange) -> String {
        let string = text.string as NSString
        var pieces: [(text: String, isBreak: Bool)] = []
        text.enumerateAttributes(in: range) { attributes, run, _ in
            if attributes[.markdownSkipOnCopy] != nil { return }
            if attributes[.markdownBlockBreak] != nil {
                // 자리 글자만 있던 블록(구분선 등)을 빼면 빈 줄이 겹친다 — 하나만.
                if pieces.last?.isBreak != true { pieces.append(("\n\n", true)) }
            } else if attributes[.markdownCellBreak] != nil {
                pieces.append(("\t", false))
            } else {
                // 표 칸 안 줄바꿈(U+2028)은 칸이 흩어지지 않게 공백으로.
                pieces.append((string.substring(with: run).replacingOccurrences(of: "\u{2028}", with: " "), false))
            }
        }
        // 고른 범위가 블록 경계에서 시작하거나 끝나면 그 빈 줄은 뺀다.
        while pieces.first?.isBreak == true { pieces.removeFirst() }
        while pieces.last?.isBreak == true { pieces.removeLast() }
        return pieces.map(\.text).joined()
    }
}

// MARK: - 코드 상자

/// 코드 블록 상자: 둥근 바탕 · 테두리 · 언어 이름 띠. 복사 단추는 `MarkdownTextView` 가 띠 오른쪽에 얹는다.
final class MarkdownCodeBox: NSTextBlock {
    private(set) var label = ""
    private var background = NSColor.clear
    private var header = NSColor.clear
    private var border = NSColor.clear
    private var labelColor = NSColor.clear

    convenience init(label: String, style: MarkdownStyle) {
        self.init()
        self.label = label
        background = style.codeBackground
        header = style.codeHeader
        border = style.codeBorder
        labelColor = style.codeLabel
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone)
        if let box = copy as? MarkdownCodeBox {
            box.label = label
            box.background = background
            box.header = header
            box.border = border
            box.labelColor = labelColor
        }
        return copy
    }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        // frameRect 는 바깥 여백까지 포함한다 — 위 여백은 앞 블록과의 간격이다.
        let top = width(for: .margin, edge: .minY)
        let frame = NSRect(x: frameRect.minX, y: frameRect.minY + top, width: frameRect.width,
                           height: frameRect.height - top - width(for: .margin, edge: .maxY))
        let radius = MarkdownMetrics.codeRadius
        let shape = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        background.setFill()
        shape.fill()

        let strip = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: MarkdownMetrics.codeHeaderHeight)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        header.setFill()
        strip.fill()
        border.setFill()
        NSRect(x: strip.minX, y: strip.maxY - 1, width: strip.width, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()

        let title = NSAttributedString(string: label, attributes: [
            .font: MarkdownMetrics.codeLabelFont, .foregroundColor: labelColor, .kern: 0.6,
        ])
        title.draw(at: NSPoint(x: strip.minX + 10, y: strip.minY + (strip.height - title.size().height) / 2))

        border.setStroke()
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: radius - 0.5, yRadius: radius - 0.5)
        outline.lineWidth = 1
        outline.stroke()
    }
}

/// 코드 상자 띠의 "복사" 글자 단추. 누르면 1.2초 동안 "복사됨".
final class MarkdownCodeCopyButton: NSButton {
    private let code: String
    private let normalColor: NSColor
    private let copiedColor: NSColor

    init(code: String, style: MarkdownStyle) {
        self.code = code
        normalColor = style.codeLabel
        copiedColor = style.codeCopied
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        refusesFirstResponder = true
        toolTip = "코드 복사"
        setAccessibilityLabel("코드 복사")
        target = self
        action = #selector(copyCode)
        showTitle(copied: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func copyCode() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        showTitle(copied: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.showTitle(copied: false)
        }
    }

    private func showTitle(copied: Bool) {
        attributedTitle = NSAttributedString(string: copied ? "복사됨" : "복사", attributes: [
            .font: MarkdownMetrics.codeButtonFont, .foregroundColor: copied ? copiedColor : normalColor,
        ])
        // 글자 폭이 바뀌니 띠 오른쪽 끝에 다시 맞춘다.
        superview?.needsLayout = true
    }
}

// MARK: - 텍스트 뷰

/// 메시지 하나를 그리는 선택 전용 텍스트 뷰 (TextKit 1). 높이는 SwiftUI 가 준 폭에서 잰다 (`height(forWidth:)`).
/// ⌘C · 끌어 놓기는 `MarkdownCopy` 의 평문을, 오른쪽 클릭의 "메시지 전체 복사" 는 Markdown 원문을 쓴다.
/// 사람이 친 글(`plain`)을 통째로 고르면 원문 그대로 복사한다 (코드 울타리까지).
final class MarkdownTextView: NSTextView {
    /// 그리고 있는 Markdown 원문.
    private(set) var source = ""
    /// 사람이 친 글을 친 그대로 그린다 (사용자 메시지 — `MarkdownBlock.parsePlain`).
    private(set) var plain = false
    /// 상대 경로 링크를 풀 폴더 (대화의 프로젝트 폴더). 누를 때도 같은 기준으로 연다.
    private(set) var linkBase: String?
    // init(frame:textContainer:) 로 만든 텍스트 뷰는 저장소를 소유하지 않는다 — 여기서 붙잡는다.
    private let storage: NSTextStorage
    private var document: MarkdownDocument?
    private var copyButtons: [MarkdownCodeCopyButton] = []
    /// 폭별로 잰 높이 (내용이 바뀌면 비운다).
    private var heights: [CGFloat: CGFloat] = [:]
    /// 흐르는 응답 (`render(… reveal:)`): 받은 글을 푸는 일정 (그린 글의 UTF-16 — `StreamReveal.Schedule`). nil 이면 다 보인다.
    /// 글은 다 그려 두고 레이어의 가림막(`revealMask`)이 일정대로 열린다 — 애니메이션은 Core Animation 이 돌려 메인 스레드가 바빠도
    /// 글이 고르게 흐른다. 높이는 받은 글을 따른다 (SwiftUI 는 받은 조각이 올 때만 다시 배치한다).
    private var revealSchedule: StreamReveal.Schedule?
    private var reveal: MarkdownReveal = .instant
    /// 가림막을 다시 지어야 한다 (글 · 일정 · 크기가 바뀌었다) — `layout` 에서.
    private var revealMaskStale = false
    /// 다 받은 응답이 다 보인 뒤 가림막을 걷는다.
    private var revealEndTimer: Timer?

    init() {
        storage = NSTextStorage()
        let layoutManager = MarkdownLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)

        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        allowsUndo = false
        usesFontPanel = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        enabledTextCheckingTypes = 0
        focusRingType = .none
        // 편집하지 않는 글이라 끌어 놓기를 받지 않는다 — 스트림 위로 끌어 온 것을 가로채지 않게.
        unregisterDraggedTypes()
        layoutManager.owner = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 원문 · 글자색 · 평문 여부 · 링크 기준 폴더가 바뀌었을 때만 부른다 (SwiftUI 쪽이 비교한다).
    /// - Parameters:
    ///   - reveal: 흐르는 응답이면 받은 글을 고른 속도로 풀고 새 글자를 서서히 보인다 (`StreamingAgentMessage`).
    ///   - revealsFromBeginning: 처음 그릴 때 받아 둔 글도 처음부터 푼다 (막 시작한 응답). 아니면 처음 그린 글은 곧바로 다.
    func render(source: String, style: MarkdownStyle, plain: Bool = false, linkBase: String? = nil,
                reveal: MarkdownReveal = .instant, revealsFromBeginning: Bool = false) {
        let document = MarkdownDocument(source: source, style: style, plain: plain, linkBase: linkBase)
        let previous = self.document?.text.string
        let selection = selectedRanges.map(\.rangeValue)
        self.source = source
        self.plain = plain
        self.linkBase = linkBase
        self.document = document
        storage.setAttributedString(document.text)
        // 스트리밍으로 글이 자라는 동안에도 고른 범위를 잃지 않게.
        let kept = selection.filter { $0.length > 0 && NSMaxRange($0) <= storage.length }
        setSelectedRanges(kept.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))]
                                       : kept.map { NSValue(range: $0) },
                          affinity: .downstream, stillSelecting: false)
        textContainerInset = NSSize(width: 0, height: document.topInset)
        linkTextAttributes = [.foregroundColor: style.link, .cursor: NSCursor.pointingHand]
        // 고른 글자색은 그대로 둔다 — 첫 응답자만 글자색이 바뀌면 여러 메시지에 걸친 선택이 한 덩어리로 안 보인다.
        selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        heights = [:]

        copyButtons.forEach { $0.removeFromSuperview() }
        copyButtons = document.codeBlocks.map { MarkdownCodeCopyButton(code: $0.code, style: style) }
        copyButtons.forEach { addSubview($0) }
        updateReveal(after: previous, mode: reveal, fromBeginning: revealsFromBeginning)
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    /// SwiftUI 가 제안한 폭에서의 높이 (글은 `layoutWidth` 로 내린 폭에 놓는다).
    func height(forWidth proposed: CGFloat) -> CGFloat {
        let width = Self.layoutWidth(proposed)
        if let height = heights[width] { return height }
        guard let layoutManager, let textContainer else { return 0 }
        // 배치하는 동안 텍스트 뷰가 스스로 setFrameSize 를 (같은 크기로) 부른다 — 그때 컨테이너를 뷰 폭으로 되돌리면
        // 잰 높이가 옛 폭의 것이 된다.
        measuring = true
        defer { measuring = false }
        setContainerWidth(width)
        layoutManager.ensureLayout(for: textContainer)
        let height = ceil(textContainerInset.height + layoutManager.usedRect(for: textContainer).maxY)
        heights[width] = height
        return height
    }

    /// 글이나 컨테이너 폭이 바뀌어 레이아웃 관리자가 다시 그릴 곳을 알리면, 텍스트 뷰는 기본으로 그 자리의 글자를 **그 순간 배치해**
    /// 영역을 좁힌다. 막 만든 메시지는 컨테이너가 아직 기본 폭(600)이라 곧 버릴 배치다 — 네 칸을 열 때 CPU 의 13% (2026-09-29 실측).
    /// 영역을 좁히지 않고 준 사각형을 그대로 다시 그리게 한다. 배치는 높이를 잴 때(SwiftUI 가 준 폭) · 그릴 때만 한다.
    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(invalidRect, avoidAdditionalLayout: true)
    }

    // MARK: 폭

    private var measuring = false

    /// 글을 놓는 폭: 2pt 단위로 내린다. SwiftUI 는 같은 자리를 480.75 · 481 처럼 소수점만 다른 폭으로 되묻는데, 폭이 다르면
    /// 메시지 전체를 다시 배치해야 한다. 내린 폭은 틀보다 2pt 안쪽이라 글이 잘리지 않는다 (높이도 그 폭에서 잰다).
    static func layoutWidth(_ width: CGFloat) -> CGFloat {
        width < 2 ? width : floor(width / 2) * 2
    }

    private func setContainerWidth(_ proposed: CGFloat) {
        let width = Self.layoutWidth(proposed)
        guard let textContainer, width > 0, textContainer.size.width != width else { return }
        textContainer.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }

    /// 높이를 잴 때 다른 폭으로 바꿔 둔 컨테이너를 그리기 · 배치 · 클릭 전에 실제 폭으로 되돌린다.
    private func matchContainerToFrame() {
        guard !measuring else { return }
        setContainerWidth(bounds.width)
    }

    override func setFrameSize(_ newSize: NSSize) {
        // 배치 중에 같은 크기로도 불린다 — 크기가 바뀔 때만 폭을 맞추고 단추를 옮긴다.
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed, !measuring else { return }
        matchContainerToFrame()
        placeCopyButtons()
        if revealSchedule != nil { applyRevealMask() }
    }

    override func viewWillDraw() {
        matchContainerToFrame()
        super.viewWillDraw()
    }

    /// 그리기 전에 그릴 자리의 글자를 **지금 폭으로** 배치해 둔다. 폭이 막 바뀐 메시지(`viewWillDraw` 의 `matchContainerToFrame`)는
    /// 배치가 무효인 채로 그려질 수 있는데, 그때 텍스트 뷰는 아무것도 그리지 않고 배치가 끝난 뒤의 다시 그리기를 기다린다 —
    /// 그 다시 그리기를 놓치면 자리만 있고 글자가 없는 메시지로 남았다 (README 이미지 · 미리보기 캡처에서 가끔, 2026-10-02).
    /// 배치는 보이는 자리(`dirtyRect` ∩ 틀)만 — 화면 밖 메시지를 다시 배치하지 않는다 (`setNeedsDisplay` 의 주석).
    override func draw(_ dirtyRect: NSRect) {
        matchContainerToFrame()
        if let layoutManager, let textContainer {
            let visible = dirtyRect.intersection(bounds)
            if !visible.isEmpty {
                let origin = textContainerOrigin
                layoutManager.ensureLayout(forBoundingRect: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer)
            }
        }
        super.draw(dirtyRect)
    }

    override func layout() {
        super.layout()
        placeCopyButtons()
        if revealMaskStale { applyRevealMask() }
    }

    /// 창이 키 창이 아닐 때(다른 앱 · 팝오버 · 설정 창에서 돌아온 첫 클릭) AppKit 이 묻는다. 텍스트 뷰 기본은 고른 글자 위가 아니면
    /// 거절이라, 그 클릭은 창을 앞으로 가져오는 데만 쓰이고 끌어도 아무것도 고르지 않았다 — "글 끌기가 됐다가 안 됐다가"
    /// (2026-10-06 미리보기 빌드에서 확인). 받되, 이 클릭인 것을 적어 두어 누르기만 하면 선택 · 링크를 건드리지 않게 한다.
    private var firstMouseTimestamp: TimeInterval?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        firstMouseTimestamp = event?.timestamp
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let activating = firstMouseTimestamp == event.timestamp
        firstMouseTimestamp = nil
        matchContainerToFrame()
        // 한 번 누르기는 스트림 선택이 받아 메시지 경계를 넘긴다. 두 번 · 세 번(단어 · 문단)은 이 메시지 안에서 기본 동작.
        guard event.clickCount == 1, let streamSelection else {
            streamSelection?.clear()
            super.mouseDown(with: event)
            return
        }
        streamSelection.track(from: self, mouseDown: event, activating: activating)
    }

    /// 링크를 누르면 `LinkOpener` 를 따른다 — 텍스트 뷰 기본 동작은 어떤 스킴이든 NSWorkspace 로 열어, 에이전트가 쓴
    /// `file://….command` 링크 한 번에 프로그램이 실행될 수 있었다.
    override func clicked(onLink link: Any, at charIndex: Int) {
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        guard let url else { return }
        LinkOpener.open(url, baseDirectory: linkBase, window: window)
    }

    // MARK: 입력창으로 넘기기

    /// 메시지를 눌러 고른 뒤 바로 친 글자는 이 칸의 입력창으로 보낸다 — 읽기 전용 글이라 그냥 사라졌다 (경고음, 첫 사용자 시험
    /// chat-19). ⌘ · ⌃ 를 누른 키(복사 · 전체 선택 …)와 방향 · 기능 · ↵ · ⇥ · esc 는 그대로 텍스트 뷰가 받는다.
    override func keyDown(with event: NSEvent) {
        if StreamTyping.isTyping(event), let composer = StreamTyping.composer(near: self),
           StreamTyping.forward(event, to: composer) {
            return
        }
        super.keyDown(with: event)
    }

    /// 끌지 않고 누른 곳이 링크면 연다 (`clicked(onLink:at:)` → `LinkOpener`).
    func openLink(at windowPoint: NSPoint) {
        guard let layoutManager, let textContainer else { return }
        let point = convert(windowPoint, from: nil)
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs,
              layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
                .contains(inContainer) else { return }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard let link = storage.attribute(.link, at: index, effectiveRange: nil) else { return }
        clicked(onLink: link, at: index)
    }

    private func placeCopyButtons() {
        guard let document, !copyButtons.isEmpty, bounds.width > 0,
              let layoutManager, let textContainer else { return }
        matchContainerToFrame()
        layoutManager.ensureLayout(for: textContainer)
        let origin = textContainerOrigin
        for (button, block) in zip(copyButtons, document.codeBlocks) {
            let glyphs = layoutManager.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
            let box = layoutManager.boundsRect(for: block.box, glyphRange: glyphs)
            let top = origin.y + box.minY + block.box.width(for: .margin, edge: .minY)
            let size = button.intrinsicContentSize
            button.frame = NSRect(x: origin.x + box.maxX - 10 - size.width,
                                  y: top + (MarkdownMetrics.codeHeaderHeight - size.height) / 2,
                                  width: size.width, height: size.height)
        }
    }

    // MARK: 흐르는 응답 — 고른 속도로 풀기 (Core Animation 가림막)

    /// 가림막이 열리는 앞 끝의 번짐 폭 (pt) — 글자가 툭 나타나지 않고 서서히 진해진다.
    static let revealEdge: CGFloat = 40

    /// 동작 줄이기(시스템 설정)면 풀지 않고 곧바로 다 보인다.
    static var reducesMotion: Bool {
        #if DEBUG
        if let reduceMotionOverride { return reduceMotionOverride }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    #if DEBUG
    /// 시험이 정하는 동작 줄이기 (nil 이면 시스템 설정) — GitHub 의 macOS 러너 이미지는 동작 줄이기를 켜 둔다.
    static var reduceMotionOverride: Bool?
    #endif

    /// 새로 그린 글의 풀기 일정을 짠다. 처음 그림이면 막 시작한 응답만 처음부터, 이미 흐르던 응답(대화를 다시 열었다)은 지금까지의
    /// 글을 곧바로 보이고 뒤로 오는 글만 푼다. 다시 그림이면 지금 보이는 데서부터 새로 받은 끝까지 다시 짠다. 동작 줄이기면 곧바로 다.
    private func updateReveal(after previous: String?, mode: MarkdownReveal, fromBeginning: Bool) {
        reveal = mode
        guard mode != .instant, !Self.reducesMotion else { return showAll() }
        let now = CACurrentMediaTime()
        let length = storage.length
        if previous == nil {
            guard mode == .streaming else { return showAll() }
            planReveal(from: fromBeginning ? 0 : Double(length), at: now)
        } else if let schedule = revealSchedule {
            planReveal(from: min(schedule.shown(at: now), Double(length)), at: now)
        }
    }

    /// 받기를 마쳤다 (글은 그대로) — 아직 보이지 않은 글을 빨리 마저 보인다.
    func setReveal(_ mode: MarkdownReveal) {
        guard mode != reveal else { return }
        reveal = mode
        guard mode != .instant else { return showAll() }
        guard let schedule = revealSchedule else { return }
        let now = CACurrentMediaTime()
        planReveal(from: schedule.shown(at: now), at: now)
    }

    /// 그때 보이는 길이 (시험용 — 풀지 않는 메시지는 nil).
    func revealedLength(at time: CFTimeInterval = CACurrentMediaTime()) -> Int? {
        revealSchedule.map { Int($0.shown(at: time)) }
    }

    private func planReveal(from shown: Double, at now: CFTimeInterval) {
        let schedule = StreamReveal.Schedule(start: now, from: shown, total: storage.length, finished: reveal == .finished)
        revealSchedule = schedule
        revealMaskStale = true
        needsLayout = true
        revealEndTimer?.invalidate()
        revealEndTimer = nil
        guard reveal == .finished else { return }
        // 다 받은 응답 — 다 보인 뒤 가림막을 걷는다 (늦게 걷혀도 그때 가림막은 이미 다 열려 있다).
        let timer = Timer(timeInterval: max(0, schedule.end - now) + 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showAll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealEndTimer = timer
    }

    /// 일정대로 열리는 가림막을 레이어에 씌운다: 일정이 시작할 때 이미 보이던 줄까지는 사각형 하나, 그 뒤는 줄(띠)마다 오른쪽 끝이 번진
    /// 띠 하나가 일정의 시각에 맞춰 왼쪽에서 오른쪽으로 밀려난다 (`position.x` 키프레임). 시각은 일정의 시작에 맞추므로 늦게 지어도
    /// 그 사이 지난 만큼 앞에서 이어진다. 띠 안에서 글자의 가로 자리는 줄의 처음과 끝 사이를 글자 수로 나눠 어림한다 (번짐 폭이 오차를 덮는다).
    private func applyRevealMask() {
        revealMaskStale = false
        guard let schedule = revealSchedule, window != nil, bounds.width > 0,
              let layoutManager, let textContainer else { return }
        if layer == nil { wantsLayer = true }
        guard let host = layer else { return }
        matchContainerToFrame()
        let length = storage.length
        let width = bounds.width
        let origin = textContainerOrigin
        let startChar = min(Int(schedule.from), length)

        // 띠: 줄 하나 (같은 높이에 나란한 표의 칸은 한 띠로). 위는 앞 띠의 아래 — 코드 상자 머리 같은 줄 사이 자리는 그 띠와 함께 열린다.
        struct Band { var top: CGFloat; var bottom: CGFloat; var chars: NSRange; var x0: CGFloat; var x1: CGFloat }
        var headBottom: CGFloat = bounds.height
        var bands: [Band] = []
        if startChar < length {
            layoutManager.ensureLayout(for: textContainer)
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: startChar, length: length - startChar),
                                                  actualCharacterRange: nil)
            let firstLine = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            headBottom = origin.y + firstLine.minY
            if glyphs.location > 0 {
                let previous = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location - 1, effectiveRange: nil)
                headBottom = origin.y + min(previous.maxY, firstLine.minY)
            }
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, used, _, lineGlyphs, _ in
                let chars = layoutManager.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
                let top = origin.y + rect.minY, bottom = origin.y + rect.maxY
                let x0 = origin.x + used.minX, x1 = origin.x + used.maxX
                if let last = bands.last, top < last.bottom - 0.5 {
                    bands[bands.count - 1] = Band(top: last.top, bottom: max(last.bottom, bottom),
                                                  chars: NSUnionRange(last.chars, chars),
                                                  x0: min(last.x0, x0), x1: max(last.x1, x1))
                } else {
                    bands.append(Band(top: bands.last?.bottom ?? headBottom, bottom: bottom, chars: chars, x0: x0, x1: x1))
                }
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let mask = CALayer()
        mask.frame = host.bounds
        let head = CALayer()
        head.backgroundColor = NSColor.black.cgColor
        head.frame = CGRect(x: 0, y: 0, width: width, height: max(0, headBottom))
        mask.addSublayer(head)
        let edge = Self.revealEdge
        let span = width + edge
        let count = schedule.values.count
        let keyTimes = (0..<count).map { NSNumber(value: count > 1 ? Double($0) / Double(count - 1) : 0) }
        let duration = StreamReveal.Schedule.step * Double(max(1, count - 1))
        for band in bands {
            // 띠의 오른쪽 끝(번짐의 끝) 자리: 그 줄이 시작되기 전엔 0(가려짐), 도는 동안 글자 자리 + 번짐 절반, 끝나면 다 열림.
            func rightEdge(_ shown: Double) -> CGFloat {
                let a = Double(band.chars.location), b = Double(NSMaxRange(band.chars))
                if shown <= a { return 0 }
                if shown >= b { return span }
                let fraction = CGFloat((shown - a) / max(1, b - a))
                return band.x0 + (band.x1 - band.x0) * fraction + edge / 2
            }
            let strip = CAGradientLayer()
            strip.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            strip.locations = [0, NSNumber(value: Double(width / span)), 1]
            strip.startPoint = CGPoint(x: 0, y: 0.5)
            strip.endPoint = CGPoint(x: 1, y: 0.5)
            strip.anchorPoint = CGPoint(x: 1, y: 0)
            strip.bounds = CGRect(x: 0, y: 0, width: span, height: band.bottom - band.top)
            let values = schedule.values.map(rightEdge)
            strip.position = CGPoint(x: values.last ?? span, y: band.top)
            if Set(values).count > 1 {
                let animation = CAKeyframeAnimation(keyPath: "position.x")
                animation.values = values
                animation.keyTimes = keyTimes
                animation.duration = duration
                animation.beginTime = mask.convertTime(schedule.start, from: nil)
                animation.fillMode = .both
                animation.isRemovedOnCompletion = false
                strip.add(animation, forKey: "reveal")
            }
            mask.addSublayer(strip)
        }
        host.mask = mask
        CATransaction.commit()
    }

    private func showAll() {
        revealEndTimer?.invalidate()
        revealEndTimer = nil
        revealSchedule = nil
        revealMaskStale = false
        if layer?.mask != nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.mask = nil
            CATransaction.commit()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 창을 떠나면 다 보인다 (다시 나타나면 받은 글 그대로). 창에 들어오면 가림막을 짓는다.
        if window == nil { showAll() } else if revealSchedule != nil { applyRevealMask() }
    }

    // MARK: 선택 · 복사

    /// 이 메시지가 든 대화 스트림의 선택 (스크롤 뷰 안에 있을 때만 — 없으면 텍스트 뷰 기본 동작).
    private var streamSelection: StreamSelection? { StreamSelection.domain(for: self) }

    /// 다른 메시지에서 시작한 스트림 선택이 여기까지 걸쳤으면 흐린 회색이 아니라 활성 색으로 칠한다 (`MarkdownLayoutManager`).
    var emphasizesStreamSelection: Bool { streamSelection?.emphasizes(self) ?? false }

    // Tab 으로 메시지마다 들르지 않는다 (누르면 선택할 수 있다).
    override var canBecomeKeyView: Bool { false }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        // 다른 곳을 누르면 선택을 지운다 — ⌘C 는 첫 응답자에게만 닿으니 흐린 선택이 남으면 헷갈린다.
        if let streamSelection {
            streamSelection.clear()
        } else {
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        }
        return true
    }

    /// ⌘A — 대화 전체 (스트림 밖이면 이 메시지).
    override func selectAll(_ sender: Any?) {
        guard let streamSelection else { return super.selectAll(sender) }
        streamSelection.selectAll(from: self)
    }

    override func copy(_ sender: Any?) {
        guard let text = streamSelection?.spanningCopyText() else { return super.copy(sender) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // 스트림 선택이 이 메시지 끝에서 시작해 여기 고른 글자가 없어도 복사할 수 있다.
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)), streamSelection?.hasSpanningSelection == true { return true }
        return super.validateMenuItem(menuItem)
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        let text = streamSelection?.spanningCopyText() ?? copyText(selectedRanges.map(\.rangeValue))
        return pboard.setString(text, forType: .string)
    }

    /// 고른 범위의 복사 글. 사람이 친 글을 통째로 골랐으면 원문 그대로 (코드 울타리 · 앞뒤 빈 줄까지).
    func copyText(_ ranges: [NSRange]) -> String {
        let chosen = ranges.filter { $0.length > 0 }
        if plain, chosen.count == 1, chosen[0].location == 0, chosen[0].length >= storage.length { return source }
        return MarkdownCopy.plainText(storage, ranges: chosen)
    }

    /// 읽기 전용 글에 맞지 않는 기본 메뉴 항목 — 오려 두기 · 붙이기 · 첨부 훑어보기, 서체 · 맞춤법 · 대치 · 변형 하위 메뉴.
    private static let editingActions: Set<String> = [
        "cut:", "paste:", "pasteAsPlainText:", "pasteAsRichText:", "toggleQuickLookPreviewPanel:",
        "orderFrontFontPanel:", "showGuessPanel:", "orderFrontSubstitutionsPanel:", "uppercaseWord:",
        "changeLayoutOrientation:",
    ]

    override func menu(for event: NSEvent) -> NSMenu? {
        matchContainerToFrame()
        // 고른 곳 밖을 누르면 스트림 선택을 지운다 — 그 자리 단어를 두고 다른 메시지의 선택을 복사하지 않게.
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if !NSLocationInRange(index, selectedRange()) { streamSelection?.clear() }
        let menu = super.menu(for: event) ?? NSMenu()
        func isEditing(_ item: NSMenuItem) -> Bool {
            item.action.map { Self.editingActions.contains(NSStringFromSelector($0)) } == true
                || item.submenu?.items.contains(where: isEditing) == true
        }
        for item in menu.items where isEditing(item) { menu.removeItem(item) }

        let item = NSMenuItem(title: plain ? "메시지 전체 복사" : "메시지 전체 복사 (Markdown)",
                              action: #selector(copyMessage(_:)), keyEquivalent: "")
        item.target = self
        let copyIndex = menu.items.firstIndex { $0.action == #selector(NSText.copy(_:)) }
        menu.insertItem(item, at: copyIndex.map { $0 + 1 } ?? 0)

        // 항목을 뺀 자리에 겹치거나 끝에 남은 구분선을 정리한다.
        var afterSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, afterSeparator { menu.removeItem(item) }
            afterSeparator = item.isSeparatorItem
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.numberOfItems - 1) }
        return menu
    }

    @objc private func copyMessage(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(source, forType: .string)
    }
}

/// 메시지는 스트림 선택의 글자 단위 참여자다 (`StreamSelection`).
extension MarkdownTextView: StreamSelectable {
    var streamLength: Int { storage.length }
    var isStreamAtom: Bool { false }
    var streamCopyKind: StreamCopyKind { .block }

    func streamIndex(at windowPoint: NSPoint) -> Int {
        matchContainerToFrame()
        return characterIndexForInsertion(at: convert(windowPoint, from: nil))
    }

    func showStreamSelection(_ range: NSRange?) {
        let target = range ?? NSRange(location: min(selectedRange().location, storage.length), length: 0)
        if selectedRange() != target { setSelectedRange(target) }
    }

    func streamCopyText(_ range: NSRange) -> String {
        copyText([range])
    }
}

/// 첫 응답자가 아닌 텍스트 뷰는 선택을 흐린 회색으로 칠한다. 다른 메시지에서 시작한 스트림 선택이 걸친 메시지는
/// 활성 색으로 바꿔 칠해 한 번의 선택으로 보이게 한다 (칠할 색은 부르기 전에 정해져 있어 직접 정한다).
private final class MarkdownLayoutManager: NSLayoutManager {
    weak var owner: MarkdownTextView?

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard color.type == .catalog, color.colorNameComponent.hasPrefix("unemphasizedSelected"),
              owner?.emphasizesStreamSelection == true else {
            return super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange,
                                                 color: color)
        }
        NSColor.selectedTextBackgroundColor.setFill()
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange,
                                      color: .selectedTextBackgroundColor)
    }
}

// MARK: - 흐르는 응답

/// 메시지 글을 보이는 방식 (`MarkdownTextView.render(… reveal:)`).
enum MarkdownReveal: Equatable {
    /// 곧바로 다 보인다 (끝난 메시지 · 사용자 메시지 · 에이전트 탭).
    case instant
    /// 받는 중 — 받은 글을 고른 속도로 푼다 (`StreamReveal` — 가림막이 열리는 앞 끝은 번져 글자가 서서히 나타난다).
    case streaming
    /// 다 받았다 — 아직 보이지 않은 글을 빨리 마저 보인다. 처음 그릴 때 이미 다 받은 글은 곧바로 다.
    case finished
}

// MARK: - 링크 열기

/// 메시지 본문(에이전트가 쓴 글)의 링크를 누를 때. 웹 주소만 바로 열고, 파일은 실행하지 않고 Finder 에서 보여 주며,
/// 그 밖의 스킴은 주소를 보이고 확인받는다. 판정(`action`)은 화면 없이 시험한다 (MarkdownTests).
///
/// 파일 링크: 스킴 없는 경로(절대 · `~` · 상대)와 `file://` 주소. 끝의 줄 번호(`:42` · `:42:7` · `#L42`)는 뗀다 — 에이전트가 쓰는
/// `[a.swift](src/a.swift:42)` 꼴. 상대 경로는 대화의 프로젝트 폴더(`baseDirectory`) 기준으로 푼다. 풀 수 없거나(기준 없음)
/// 없는 파일이면 링크로 그리지 않는다 (`renderable`) — 손가락 커서가 뜨는데 눌러도 아무 일이 없었다 (첫 사용자 시험 chat-11).
enum LinkOpener {
    enum Action: Equatable {
        case open
        /// 실행하지 않고 Finder 에서 고른 채로 보인다.
        case reveal(URL)
        /// 주소를 보이고 확인받은 뒤에 연다.
        case confirm
        case ignore
    }

    /// 파일이 있는가 (그릴 때 · 누를 때). 시험은 바꿔 넣는다.
    static let fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

    static func action(for url: URL, baseDirectory: String? = nil,
                       fileExists: (String) -> Bool = LinkOpener.fileExists) -> Action {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            return .open
        default:
            guard fileReference(url) != nil else { return .confirm }
            guard let path = filePath(of: url, baseDirectory: baseDirectory), fileExists(path) else { return .ignore }
            return .reveal(URL(fileURLWithPath: path))
        }
    }

    /// 파일을 가리키는 링크면 그 경로 글 (줄 번호를 떼기 전). 파일 링크가 아니면 nil.
    /// `a.swift:42` 는 주소 규칙으로는 스킴이 "a.swift" 다 — 점이 든 스킴 뒤가 줄 번호뿐이면 파일 이름으로 본다.
    static func fileReference(_ url: URL) -> String? {
        switch url.scheme?.lowercased() {
        case nil, "file":
            return url.path
        default:
            let text = url.absoluteString
            guard let colon = text.firstIndex(of: ":"), text[..<colon].contains("."),
                  text[text.index(after: colon)...].range(of: #"^\d+(:\d+)?(#.*)?$"#, options: .regularExpression) != nil
            else { return nil }
            return String(text[..<colon]).removingPercentEncoding
        }
    }

    /// 그릴 때 링크로 둘지 — 열 수 있으면 그 주소(파일은 푼 file:// 주소), 열 수 없으면 nil (링크로 그리지 않는다).
    static func renderable(_ url: URL, baseDirectory: String?, fileExists: (String) -> Bool = LinkOpener.fileExists) -> URL? {
        switch action(for: url, baseDirectory: baseDirectory, fileExists: fileExists) {
        case .ignore: return nil
        case .reveal(let file): return file
        case .open, .confirm: return url
        }
    }

    /// 파일 링크의 절대 경로 (줄 번호를 뗀). 파일 링크가 아니거나, 상대 경로인데 기준 폴더가 없거나, 경로가 비었으면 nil.
    static func filePath(of url: URL, baseDirectory: String?) -> String? {
        guard var path = fileReference(url) else { return nil }
        // `a.swift:42` · `a.swift:42:7` — 경로 끝의 줄 · 칸 번호. (`#L42` 는 주소의 조각이라 path 에 없다.)
        if let range = path.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) { path.removeSubrange(range) }
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
        if !path.hasPrefix("/") {
            guard url.scheme?.lowercased() != "file", let base = baseDirectory, !base.isEmpty else { return nil }
            path = (base as NSString).appendingPathComponent(path)
        }
        return (path as NSString).standardizingPath
    }

    @MainActor
    static func open(_ url: URL, baseDirectory: String? = nil, window: NSWindow?) {
        switch action(for: url, baseDirectory: baseDirectory) {
        case .open:
            NSWorkspace.shared.open(url)
        case .reveal(let file):
            NSWorkspace.shared.activateFileViewerSelecting([file])
        case .ignore:
            // 그린 뒤에 파일이 사라졌다 (그릴 때 열 수 없는 링크는 링크로 그리지 않았다).
            NSSound.beep()
        case .confirm:
            let alert = NSAlert()
            alert.messageText = "이 링크를 열까요?"
            alert.informativeText = "웹 주소가 아닌 링크입니다. 이 주소를 맡은 다른 앱이 열립니다.\n\n" + url.absoluteString
            alert.addButton(withTitle: "열기")
            alert.addButton(withTitle: "취소")
            if let window {
                alert.beginSheetModal(for: window) { response in
                    if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
                }
            } else if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: 터미널 탭의 링크

    /// 터미널 탭의 셸에서 ⌘ 누르고 누른 링크(OSC 8 하이퍼링크 — `ShellTerminalLinkGuard`)의 주소. 보이는 글과 가리키는 곳이 다를 수
    /// 있어(`https://…` 로 보이는 `file:///…/x.command`) 메시지 링크와 같은 규칙으로 연다 (2026-10-12). `file://호스트/경로` 의
    /// 호스트는 보지 않는다. 주소에 쓸 수 없는 글자(빈칸 등)는 SwiftTerm 의 기본 구현처럼 %로 바꿔 다시 읽는다. 읽을 수 없으면 nil.
    static func terminalURL(_ link: String) -> URL? {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text) { return url }
        return text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap { URL(string: $0) }
    }

    /// 터미널의 링크를 연다. 상대 경로는 풀지 않는다 — 셸이 `cd` 했을 수 있어 어느 폴더 기준인지 모른다 (`.ignore` — 소리만).
    @MainActor
    static func openTerminalLink(_ link: String, window: NSWindow?) {
        guard let url = terminalURL(link) else {
            NSSound.beep()
            return
        }
        open(url, baseDirectory: nil, window: window)
    }
}
