import Foundation

// MARK: - 글자 4단계: UI 소스에 숫자 글자 크기가 다시 들어오지 않았는지

/// 글자는 `TypeScale` 넷(11.5 · 12.5 · 14 · 20) 중 하나다 (`Theme.ui` · `mono` · `digits`).
/// 컴파일러는 `.font(.caption)`(SwiftUI 의 10pt) · `.font(.system(size: 10))` · `NSFont.systemFont(ofSize: 10)` 을 막지 못하므로
/// UI 소스를 훑어 막는다. SF Symbol 아이콘 크기(`Image(systemName:)` 에 붙은 `.system(size:)`)는 글자가 아니라서 세지 않는다.
enum TypeScaleLintTests {

    /// 일부러 남긴 곳 — 파일 이름 + 그 줄에 든 글. 늘리기 전에 TypeScale 로 될 수 없는지 먼저 본다.
    static let allowed: [(file: String, contains: String)] = [
        ("UI/ScoreboardView.swift", "size: 34"),                 // 전적 화면의 큰 수 — 그 화면의 제목 구실
        ("UI/Inspector/ShellTerminal.swift", "ofSize: 12"),      // SwiftTerm 사용자 셸 — 터미널 글꼴
        ("UI/Stream/MarkdownText.swift", "ofSize: 1)"),          // 표 · 코드 상자 앞뒤의 1pt 자리 글자
        ("UI/ModelPicker.swift", "Text(\"▾\")"),                 // 펼침 표시 글리프 — 장식
        ("UI/ComposerAccessories.swift", "Text(\"▾\")"),
        ("UI/Composer.swift", "Text(\"▾\")"),
    ]

    struct Hit: CustomStringConvertible {
        let file: String, line: Int, text: String
        var description: String { "\(file):\(line)  \(text)" }
    }

    /// `base` 아래 파일의 상대 경로. 열거한 URL 은 실제 경로(`/private/tmp/…`)로 오고 `ProbeLogs.repoRoot()` 는 `/tmp/…` 로 줄인다 —
    /// 둘 다 `standardizedFileURL` 로 맞춰 뗀다 (예전에는 `/tmp` 아래 클론에서 예외 목록과 맞지 않아 거짓 실패가 났다).
    static func relativePath(_ url: URL, under base: URL) -> String {
        url.standardizedFileURL.path.replacingOccurrences(of: base.standardizedFileURL.path + "/", with: "")
    }

    static func run(_ t: TestKit) async {
        await t.group("글자 4단계: UI 소스 검사")
        guard case .success(let root) = ProbeLogs.repoRoot() else {
            await t.check("저장소 뿌리를 찾는다", false, "AHC_REPO_ROOT 를 주거나 저장소 뿌리에서 실행한다")
            return
        }
        let ui = root.appendingPathComponent("AgentHandoffConsole/UI")
        let files = (FileManager.default.enumerator(at: ui, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "swift" }
        await t.check("UI 소스를 읽었다", files.count > 20, "\(files.count)개")

        var semantic: [Hit] = [], textSystem: [Hit] = [], appKit: [Hit] = []
        for url in files {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = "UI/" + relativePath(url, under: ui)
            let found = scan(source, file: relative)
            semantic += found.semantic
            textSystem += found.textSystem
            appKit += found.appKit
        }
        await t.check("SwiftUI 의 의미 글꼴(.caption · .body · .headline …)을 쓰지 않는다 — TypeScale 과 이름이 같아 10pt 가 들어온다",
                      semantic.isEmpty, semantic.map(\.description).joined(separator: "\n"))
        await t.check("글자에 .system(size:) 숫자를 주지 않는다 (아이콘은 괜찮다)",
                      textSystem.isEmpty, textSystem.map(\.description).joined(separator: "\n"))
        await t.check("AppKit 글꼴에 숫자 크기(ofSize: 10)를 주지 않는다",
                      appKit.isEmpty, appKit.map(\.description).joined(separator: "\n"))

        // 이어 붙인 문자열(`Text("…" + "…")`)은 String 이라 Markdown 을 풀지 않는다 — 백틱 · ** 가 그대로 찍힌다.
        var markdownHits: [Hit] = []
        for url in files {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = "UI/" + relativePath(url, under: ui)
            markdownHits += concatenatedMarkdown(source, file: relative)
        }
        await t.check("Markdown(백틱 · **)이 든 글을 이어 붙여 Text 에 주지 않는다 — LocalizedStringKey 로 감싼다",
                      markdownHits.isEmpty, markdownHits.map(\.description).joined(separator: "\n"))
        await t.equal("견본: 이어 붙인 Markdown 글을 잡고, 감싼 것 · 한 줄 리터럴은 둔다",
                      concatenatedMarkdown("Text(\"a `b` \"\n + \"c\")\nText(LocalizedStringKey(\"a `b`\" + \"c\"))\nText(\"a `b`\")",
                                           file: "견본.swift").count, 1)

        // 검사 자체가 잡는지 — 위반 견본.
        let sample = """
            Text("a").font(.caption)
            Text("b")
                .font(.system(size: 10))
            Image(systemName: "x")
                .font(.system(size: 10))
            let f = NSFont.systemFont(ofSize: 10.5)
            let g = NSFont.systemFont(ofSize: MarkdownMetrics.bodySize)
            """
        let probe = scan(sample, file: "견본.swift")
        await t.equal("견본: 의미 글꼴 · 글자의 숫자 크기 · AppKit 숫자 크기를 하나씩 잡고, 아이콘 · 이름 붙은 크기는 두고",
                      [probe.semantic.count, probe.textSystem.count, probe.appKit.count], [1, 1, 1])

        await iconControlLabels(t, ui: ui, files: files)
        await particleSpacing(t, root: root)
    }

    /// 아이콘만 있는 단추 · 메뉴의 VoiceOver 이름 (txt-19) — `IconControlLint`.
    static func iconControlLabels(_ t: TestKit, ui: URL, files: [URL]) async {
        await t.group("아이콘만 있는 단추 · 메뉴: VoiceOver 이름")
        var hits: [IconControlLint.Hit] = []
        var controls = 0
        for url in files {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let found = IconControlLint.scan(source, file: "UI/" + relativePath(url, under: ui))
            hits += found.hits
            controls += found.controls
        }
        await t.check("아이콘만 있는 Button · Menu 를 찾았다 (검사가 비어 통과하지 않게)", controls > 20, "\(controls)개")
        await t.check("글자 없이 아이콘만 있는 Button · Menu 에 .accessibilityLabel 이 있다 (.help 는 이름이 아니다)",
                      hits.isEmpty, hits.map(\.description).joined(separator: "\n"))
        let sample = """
            Button { go() } label: { Image(systemName: "xmark") }
                .help("닫기")
            Button { go() } label: { Image(systemName: "xmark") }
                .accessibilityLabel("닫기")
            Menu { Button("a") {} } label: { Image(systemName: "ellipsis") }
            Button("글") { go() }
            Button { go() } label: { HStack { Image(systemName: "x"); Text("글 (괄호 \\(a(b)))") } }
            Button(action: go) { Image(systemName: "stop") }
                .buttonStyle(.plain)
                .accessibilityLabel("멈추기")
            Button(action: go) {
                Image(systemName: "stop") // Text( 는 주석이라 세지 않는다
            }
            let s = #"Button { } label: { Image( }"#
            """
        await t.equal("견본: 도움말만 · 이름 없는 메뉴 · 주석의 Text 를 잡고, 이름 · 글이 있는 것 · 문자열 속은 둔다",
                      IconControlLint.scan(sample, file: "견본.swift").hits.map(\.line), [1, 5, 11])
    }

    /// 화면 글의 조사 띄어쓰기 (txt-12) — `ParticleSpacingLint`. 앱 소스 전부(옮겨 온 ThinkingOrbs 는 뺀다).
    static func particleSpacing(_ t: TestKit, root: URL) async {
        await t.group("화면 글: 영어 이름 뒤 조사는 띄어 쓴다")
        let app = root.appendingPathComponent("AgentHandoffConsole")
        let files = (FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "swift" && !$0.path.contains("/ThinkingOrbs/") }
        var hits: [ParticleSpacingLint.Hit] = []
        for url in files {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            hits += ParticleSpacingLint.scan(source, file: relativePath(url, under: app))
        }
        await t.check("앱 소스를 읽었다", files.count > 100, "\(files.count)개")
        await t.check("문자열에서 영어 낱말 바로 뒤에 조사를 붙이지 않는다 (\"GitHub 에서\" · \"Codex 가\")",
                      hits.isEmpty, hits.map(\.description).joined(separator: "\n"))
        let sample = """
            Text("GitHub에서 열기")
            Text("GitHub 에서 열기")
            Text("줄\\n가나다")
            Text("Codex가 편집함") // "Mac에" 는 주석
            // Text("Claude가")
            """
        await t.equal("견본: 붙여 쓴 조사만 잡고, 띄어 쓴 것 · 이스케이프 뒤 · 주석은 둔다",
                      ParticleSpacingLint.scan(sample, file: "견본.swift").map(\.text), ["GitHub에서", "Codex가"])

        // 용어 (H18 · txt-15): 화면 글은 "대화" · "에이전트 기록" · "사용 한도". 옛 저장값을 읽는 줄만 남긴다.
        var old: [ParticleSpacingLint.Hit] = []
        for url in files {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            old += ParticleSpacingLint.oldTerms(source, file: relativePath(url, under: app))
        }
        await t.check("화면 글에 옛 용어(스레드 · 전적 · 사용 제한)를 쓰지 않는다 — 옛 저장값 읽기만 예외",
                      old.isEmpty, old.map(\.description).joined(separator: "\n"))
        await t.equal("견본: 옛 용어를 잡고, 주석 · 예외 줄은 둔다",
                      ParticleSpacingLint.oldTerms("Text(\"새 스레드\")\n// \"전적\"\nText(\"사용 제한\")", file: "견본.swift").map(\.line),
                      [1, 3])
    }

    static func scan(_ source: String, file: String) -> (semantic: [Hit], textSystem: [Hit], appKit: [Hit]) {
        let lines = source.components(separatedBy: "\n")
        var semantic: [Hit] = [], textSystem: [Hit] = [], appKit: [Hit] = []
        let semanticPattern = #"\.font\(\.(caption2?|callout|body|title[23]?|largeTitle|headline|subheadline|footnote)\b"#
        let appKitPattern = #"ofSize:\s*[0-9]"#
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
            if isAllowed(file: file, line: line) { continue }
            let hit = Hit(file: file, line: index + 1, text: trimmed)
            if line.range(of: semanticPattern, options: .regularExpression) != nil { semantic.append(hit) }
            if line.range(of: appKitPattern, options: .regularExpression) != nil { appKit.append(hit) }
            if line.contains(".system(size:"), !file.hasSuffix("Design/Theme.swift"),
               chainHead(lines, at: index).range(of: #"\bText\(|\bLabel\(|TextField\(|TextEditor\("#,
                                                options: .regularExpression) != nil {
                textSystem.append(hit)
            }
        }
        return (semantic, textSystem, appKit)
    }

    /// `Text(` 바로 뒤에 문자열 리터럴 둘 이상을 `+` 로 이은 식이 있고 그 안에 백틱 · ** 가 있으면 잡는다.
    static func concatenatedMarkdown(_ source: String, file: String) -> [Hit] {
        let literal = #""(?:[^"\\\n]|\\.)*""#
        let pattern = #"(?<![A-Za-z])Text\("# + "(" + literal + #"(?:\s*\+\s*"# + literal + ")+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let body = ns.substring(with: match.range(at: 1))
            guard body.contains("`") || body.contains("**") else { return nil }
            let line = ns.substring(to: match.range.location).components(separatedBy: "\n").count
            return Hit(file: file, line: line, text: String(body.prefix(60)))
        }
    }

    /// `.font(...)` 가 붙은 수식어 사슬의 첫 줄 — `.` 으로 시작하지 않는 가장 가까운 윗줄 (같은 줄이면 그 줄).
    static func chainHead(_ lines: [String], at index: Int) -> String {
        var i = index
        while i > 0, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(".") { i -= 1 }
        // 같은 줄에 사슬의 머리가 있으면 그 줄의 `.font` 앞부분만 본다 (`Image(...).font(...)`).
        let head = lines[i]
        if i == index, let range = head.range(of: ".font(") { return String(head[..<range.lowerBound]) }
        return head
    }

    static func isAllowed(file: String, line: String) -> Bool {
        allowed.contains { file == $0.file && line.contains($0.contains) }
    }
}

// MARK: - 아이콘만 있는 단추 · 메뉴: VoiceOver 이름

/// 글자 없이 아이콘만 있는 `Button` · `Menu` 에는 `.accessibilityLabel` 을 단다 — 없으면 VoiceOver 가 기호 이름("ellipsis")을
/// 읽는다 (`.help` 는 마우스 도움말 · 접근성 힌트일 뿐 이름이 아니다). 라벨 안에 `Text` · `Label` 이 있으면 그 글이 이름이다.
/// 소스를 바이트로 훑는다: 문자열 · 주석을 빈칸으로 바꾼 뒤(`blanked`) 괄호 짝으로 라벨 블록과 뒤의 수식어 사슬을 찾는다.
enum IconControlLint {
    struct Hit: CustomStringConvertible {
        let file: String, line: Int, kind: String
        var description: String { "\(file):\(line)  \(kind)" }
    }

    /// 라벨 안에 이것이 있으면 글이 이름이 된다 (또는 라벨 안에서 이미 이름을 달았다).
    static let textMarkers: [String] = ["Text(", "Label(", "SettingsLabel(", "ProviderBadge(", ".accessibilityLabel("]

    /// `controls` = 아이콘만 있는 조작의 수 (이름이 있든 없든) — 검사가 아무것도 찾지 못해 통과하는 일을 막는 데 쓴다.
    static func scan(_ source: String, file: String) -> (hits: [Hit], controls: Int) {
        let b = blanked(source)
        var hits: [Hit] = []
        var controls = 0
        var i = 0
        while i < b.count {
            guard b[i] == UInt8(ascii: "B") || b[i] == UInt8(ascii: "M"), let kind = keyword(b, at: i) else {
                i += 1
                continue
            }
            let start = i
            i += kind.utf8.count
            guard let (label, end) = labelBlock(b, after: i), contains(b, label, "Image("),
                  !textMarkers.contains(where: { contains(b, label, $0) }) else { continue }
            controls += 1
            if !contains(b, modifierChain(b, after: end), ".accessibilityLabel(") {
                let line = b[..<start].reduce(1) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
                hits.append(Hit(file: file, line: line, kind: kind))
            }
        }
        return (hits, controls)
    }

    /// 문자열 리터럴의 안과 주석을 빈칸으로 바꾼 바이트 (줄바꿈은 남긴다) — 괄호 · 중괄호 짝 맞추기가 글자에 속지 않게.
    /// `#"…"#` 날 문자열 · `"""` 여러 줄 문자열 · `\( … )` 끼워 넣기(안의 문자열까지)를 다룬다.
    static func blanked(_ source: String) -> [UInt8] {
        var b: [UInt8] = Array(source.utf8)
        let n = b.count
        let quote = UInt8(ascii: "\""), slash = UInt8(ascii: "/"), star = UInt8(ascii: "*"), hash = UInt8(ascii: "#")
        let backslash = UInt8(ascii: "\\"), newline = UInt8(ascii: "\n")
        let open = UInt8(ascii: "("), close = UInt8(ascii: ")"), space = UInt8(ascii: " ")
        func blank(_ from: Int, _ to: Int) {
            var k = from
            while k < min(to, n) {
                if b[k] != newline { b[k] = space }
                k += 1
            }
        }
        /// 보통 문자열의 끝 따옴표 자리 (끼워 넣기 안의 문자열도 건넌다). 따옴표 없이 줄이 끝나면 그 줄바꿈 자리.
        func endOfLiteral(_ from: Int) -> Int {
            var j = from
            while j < n, b[j] != quote, b[j] != newline {
                guard b[j] == backslash, j + 1 < n else {
                    j += 1
                    continue
                }
                guard b[j + 1] == open else {
                    j += 2
                    continue
                }
                var depth = 1
                j += 2
                while j < n, depth > 0 {
                    if b[j] == open {
                        depth += 1
                    } else if b[j] == close {
                        depth -= 1
                    } else if b[j] == quote {
                        j = endOfLiteral(j + 1)
                    }
                    j += 1
                }
            }
            return j
        }
        var i = 0
        while i < n {
            let c = b[i]
            if c == slash, i + 1 < n, b[i + 1] == slash {
                var j = i
                while j < n, b[j] != newline { j += 1 }
                blank(i, j)
                i = j
                continue
            }
            if c == slash, i + 1 < n, b[i + 1] == star {
                var j = i + 2
                while j + 1 < n, !(b[j] == star && b[j + 1] == slash) { j += 1 }
                blank(i, j + 2)
                i = j + 2
                continue
            }
            guard c == quote else {
                i += 1
                continue
            }
            var hashes = 0
            while i - hashes - 1 >= 0, b[i - hashes - 1] == hash { hashes += 1 }
            let triple = i + 2 < n && b[i + 1] == quote && b[i + 2] == quote
            if triple || hashes > 0 {
                let opener = triple ? 3 : 1
                let closer: [UInt8] = Array(repeating: quote, count: opener) + Array(repeating: hash, count: hashes)
                var j = i + opener
                while j < n, !b[j...].starts(with: closer) { j += 1 }
                blank(i + opener, j)
                i = j + closer.count
                continue
            }
            let j = endOfLiteral(i + 1)
            blank(i + 1, j)
            i = j + 1
        }
        return b
    }

    // MARK: 도우미

    private static func isIdentifier(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
    }

    /// `i` 에서 `Button` · `Menu` 낱말이 시작하면 그 낱말 (`ButtonStyle` · `.menuStyle` · `HelpMenu` 는 아니다).
    private static func keyword(_ b: [UInt8], at i: Int) -> String? {
        for word in ["Button", "Menu"] where startsWith(b, i, word) {
            if i > 0, isIdentifier(b[i - 1]) || b[i - 1] == UInt8(ascii: ".") { return nil }
            return word
        }
        return nil
    }

    /// `i` 에서 `word` 가 낱말로 시작하는가 (뒤가 식별자 글자가 아니다).
    private static func startsWith(_ b: [UInt8], _ i: Int, _ word: String) -> Bool {
        let w = Array(word.utf8)
        guard i >= 0, i + w.count <= b.count, b[i..<(i + w.count)].elementsEqual(w) else { return false }
        return i + w.count == b.count || !isIdentifier(b[i + w.count])
    }

    private static func skipSpaces(_ b: [UInt8], _ from: Int, newlines: Bool) -> Int {
        var j = from
        while j < b.count, b[j] == UInt8(ascii: " ") || b[j] == UInt8(ascii: "\t")
                || (newlines && (b[j] == UInt8(ascii: "\n") || b[j] == UInt8(ascii: "\r"))) {
            j += 1
        }
        return j
    }

    /// `b[i]` 의 여는 괄호에 짝이 되는 닫는 괄호 자리.
    private static func matching(_ b: [UInt8], _ i: Int, open: UInt8, close: UInt8) -> Int? {
        var depth = 0
        var j = i
        while j < b.count {
            if b[j] == open {
                depth += 1
            } else if b[j] == close {
                depth -= 1
                if depth == 0 { return j }
            }
            j += 1
        }
        return nil
    }

    private static func block(_ b: [UInt8], _ i: Int) -> Int? {
        guard i < b.count, b[i] == UInt8(ascii: "{") else { return nil }
        return matching(b, i, open: UInt8(ascii: "{"), close: UInt8(ascii: "}"))
    }

    private static func contains(_ b: [UInt8], _ range: Range<Int>, _ marker: String) -> Bool {
        let m = Array(marker.utf8)
        guard !m.isEmpty, range.count >= m.count else { return false }
        var j = range.lowerBound
        while j + m.count <= range.upperBound {
            if b[j] == m[0], b[j..<(j + m.count)].elementsEqual(m) { return true }
            j += 1
        }
        return false
    }

    /// `label` 뒤 `:` 다음의 `{` 자리.
    private static func braceAfterColon(_ b: [UInt8], _ from: Int) -> Int? {
        var k = skipSpaces(b, from, newlines: true)
        guard k < b.count, b[k] == UInt8(ascii: ":") else { return nil }
        k = skipSpaces(b, k + 1, newlines: true)
        return k < b.count && b[k] == UInt8(ascii: "{") ? k : nil
    }

    /// `} label: { … }` — 동작 블록 뒤의 라벨 블록과 그 끝.
    private static func trailingLabel(_ b: [UInt8], after end: Int) -> (Range<Int>, Int)? {
        let k = skipSpaces(b, end + 1, newlines: true)
        guard startsWith(b, k, "label"), let brace = braceAfterColon(b, k + 5), let close = block(b, brace) else { return nil }
        return ((brace + 1)..<close, close)
    }

    /// `Button`/`Menu` 다음의 라벨 블록과 구문의 끝 — `{ 동작 } label: { 라벨 }` · `(action: …) { 라벨 }` ·
    /// `(action: …, label: { 라벨 })` · `(role: …) { 동작 } label: { 라벨 }`. 제목을 받는 꼴(`Button("…")`)이면 nil.
    private static func labelBlock(_ b: [UInt8], after start: Int) -> (Range<Int>, Int)? {
        let j = skipSpaces(b, start, newlines: false)
        guard j < b.count else { return nil }
        if b[j] == UInt8(ascii: "{") {
            guard let end = block(b, j) else { return nil }
            return trailingLabel(b, after: end)
        }
        guard b[j] == UInt8(ascii: "("),
              let close = matching(b, j, open: UInt8(ascii: "("), close: UInt8(ascii: ")")) else { return nil }
        let inner = skipSpaces(b, j + 1, newlines: true)
        guard inner == close || startsWith(b, inner, "action") || startsWith(b, inner, "role") else { return nil }
        var k = j + 1
        while k < close {
            if startsWith(b, k, "label"), k == 0 || !isIdentifier(b[k - 1]), let brace = braceAfterColon(b, k + 5),
               brace < close, let end = block(b, brace) {
                return ((brace + 1)..<end, close)
            }
            k += 1
        }
        let after = skipSpaces(b, close + 1, newlines: true)
        guard let end = block(b, after) else { return nil }
        return trailingLabel(b, after: end) ?? ((after + 1)..<end, end)
    }

    /// 구문 뒤 수식어 사슬(`.help(…)` · `.accessibilityLabel(…)` · `.popover(…) { … }` …)의 범위.
    private static func modifierChain(_ b: [UInt8], after end: Int) -> Range<Int> {
        let start = end + 1
        var j = start
        while true {
            let k = skipSpaces(b, j, newlines: true)
            guard k + 1 < b.count, b[k] == UInt8(ascii: "."), isIdentifier(b[k + 1]) else { break }
            var m = k + 1
            while m < b.count, isIdentifier(b[m]) { m += 1 }
            while true {
                let n = skipSpaces(b, m, newlines: false)
                if n < b.count, b[n] == UInt8(ascii: "("),
                   let close = matching(b, n, open: UInt8(ascii: "("), close: UInt8(ascii: ")")) {
                    m = close + 1
                } else if let close = block(b, n) {
                    m = close + 1
                } else {
                    break
                }
            }
            j = m
        }
        return start..<max(start, j)
    }
}

// MARK: - 화면 글: 영어 이름 뒤 조사는 띄어 쓴다

/// 이 앱의 글은 영어 이름 뒤 조사를 띄어 쓴다 ("Codex 에게" · "Mac 에" · "GitHub 에서"). 문자열 리터럴 안에서 영어 낱말 바로 뒤에
/// 조사가 붙은 것("GitHub에서" · "Codex가")을 잡는다. `\n` 같은 이스케이프 뒤의 한글은 세지 않는다. 주석 · 여러 줄 문자열(프롬프트)은 보지 않는다.
enum ParticleSpacingLint {
    struct Hit: CustomStringConvertible {
        let file: String, line: Int, text: String
        var description: String { "\(file):\(line)  \(text)" }
    }

    static let literal = try! NSRegularExpression(pattern: #""((?:[^"\\\n]|\\.)*)""#)
    static let attached = try! NSRegularExpression(
        pattern: #"(?<![\\A-Za-z0-9_])[A-Za-z][A-Za-z0-9_.+-]*(?:을|를|이|가|은|는|와|과|으로|로|에서|에게|에|의|도|만)(?=[\s.,)…:!?'"]|$)"#)

    static func scan(_ source: String, file: String) -> [Hit] {
        var hits: [Hit] = []
        for (index, raw) in source.components(separatedBy: "\n").enumerated() {
            let line = codePart(raw)
            guard line.contains("\"") else { continue }
            let ns = line as NSString
            for match in literal.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let body = ns.substring(with: match.range(at: 1))
                let bodyNS = body as NSString
                for found in attached.matches(in: body, range: NSRange(location: 0, length: bodyNS.length)) {
                    hits.append(Hit(file: file, line: index + 1, text: bodyNS.substring(with: found.range)))
                }
            }
        }
        return hits
    }

    /// 화면 글에 쓰지 않는 옛 용어 — "대화" · "에이전트 기록" · "사용 한도" 로 바꿨다.
    static let oldTermWords: [String] = ["스레드", "전적", "사용 제한"]
    /// 옛 저장값을 계속 읽는 줄 (파일 · 그 줄에 든 글) — 화면 글이 아니다.
    static let oldTermAllowed: [(file: String, contains: String)] = [
        ("Core/Models.swift", "placeholderTitles"),            // 옛 자리 표시 제목 "새 스레드" 도 알아본다
        ("App/WindowState.swift", "case \"scoreboard\", \"전적\""), // 옛 저장값 "전적" 을 읽는다
    ]

    /// 문자열 리터럴 안의 옛 용어. 주석은 보지 않는다.
    static func oldTerms(_ source: String, file: String) -> [Hit] {
        var hits: [Hit] = []
        for (index, raw) in source.components(separatedBy: "\n").enumerated() {
            let line = codePart(raw)
            guard line.contains("\""), !oldTermAllowed.contains(where: { file == $0.file && line.contains($0.contains) }) else { continue }
            let ns = line as NSString
            for match in literal.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let body = ns.substring(with: match.range(at: 1))
                // "전적으로"(부사)는 옛 화면 이름이 아니다.
                for word in oldTermWords where body.contains(word) && !(word == "전적" && body.contains("전적으로")) {
                    hits.append(Hit(file: file, line: index + 1, text: word))
                }
            }
        }
        return hits
    }

    /// 줄의 코드 부분 — 문자열 밖의 `//` 주석을 뗀다 (주석 줄이면 빈 글).
    static func codePart(_ line: String) -> String {
        var inString = false
        var escaped = false
        var previous: Character = " "
        var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "/", previous == "/" {
                return String(line[..<line.index(before: index)])
            }
            previous = c
            index = line.index(after: index)
        }
        return line
    }
}
