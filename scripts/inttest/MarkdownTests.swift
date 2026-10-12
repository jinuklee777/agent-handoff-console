import AppKit
import QuartzCore

/// 대화 메시지 선택 · 복사 (`UI/Stream/MarkdownText.swift`). 블록(제목 · 문단 · 목록 · 코드 · 표 · 구분선)이 텍스트 하나라
/// 한 번에 고르고 복사한다. 복사 글은 화면에 보이는 글 그대로 — 블록 사이 빈 줄, 표는 칸마다 탭, 자리 글자는 뺀다.
/// 코드 상자의 복사 단추는 상자 띠 안에 놓인다.
enum MarkdownTests {
    @MainActor
    static func run(_ t: TestKit) async {
        await copyText(t)
        await terminalLinks(t)
        await textView(t)
        await streamDecisions(t)
        await streamDrag(t)
        await typing(t)
    }

    /// 메시지를 눌러 고른 뒤 바로 친 글자는 그 칸의 입력창으로 간다 (chat-19). 입력창은 스트림 위에 겹쳐 놓인, 스트림 스크롤 뷰의
    /// 자손이 아닌 편집 칸 — 스트림 안의 편집 칸(인계 카드의 덧붙일 말) · 다른 칸의 입력창은 아니다.
    @MainActor
    static func typing(_ t: TestKit) async {
        await t.group("메시지에서 친 글자 → 입력창")
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags = [], code: UInt16 = 0) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        }
        let typing: [Bool] = [key("a"), key("ㅎ"), key("é", .option), key(" ")].map { $0.map(StreamTyping.isTyping) ?? false }
        await t.equal("글자 · 한글 · ⌥ 글자 · 빈칸은 타자", typing, [true, true, true, true])
        let notTyping: [Bool] = [key("c", .command), key("a", .control), key("\r", code: 36), key("\u{1b}", code: 53),
                                 key("\t", code: 48), key("\u{F700}", .function, code: 126)]
            .map { $0.map(StreamTyping.isTyping) ?? true }
        await t.equal("⌘ · ⌃ · ↵ · esc · ⇥ · 방향 키는 메시지가 받는다", notTyping, [false, false, false, false, false, false])

        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 600, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        window.contentView = root
        // 스트림 (위 칸 전체) — 안에 메시지와 인계 카드의 메모 칸.
        let stream = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        stream.documentView = document
        root.addSubview(stream)
        let message = MarkdownTextView()
        message.render(source: "고를 메시지", style: style)
        message.frame = NSRect(x: 20, y: 20, width: 560, height: message.height(forWidth: 560))
        document.addSubview(message)
        let memo = NSTextView(frame: NSRect(x: 20, y: 200, width: 560, height: 40))
        document.addSubview(memo)
        // 입력창 — 스트림 위에 겹쳐 놓인 형제.
        let composer = NSTextView(frame: NSRect(x: 20, y: 20, width: 560, height: 60))
        root.addSubview(composer)
        // 다른 칸의 입력창 — 스트림 자리 밖.
        let other = NSTextView(frame: NSRect(x: 700, y: 20, width: 200, height: 60))
        root.addSubview(other)
        await t.check("이 칸의 입력창을 찾는다 (스트림 안의 메모 칸 · 다른 칸의 입력창은 아니다)",
                      StreamTyping.composer(near: message) === composer)
        window.makeFirstResponder(message)
        // 다시 보내는 키는 앱 이벤트 대기열 대신 여기로 (검증 실행 파일에서 대기열을 돌리지 않는다).
        var posted: [NSEvent] = []
        let realPost = StreamTyping.post
        StreamTyping.post = { posted.append($0) }
        if let event = key("x") { message.keyDown(with: event) }
        StreamTyping.post = realPost
        await t.check("친 글자를 받을 입력창이 첫 응답자가 된다", window.firstResponder === composer)
        await t.equal("그 키는 입력창에게 다시 보낸다 (입력기가 처음부터 받도록)", posted.map { $0.characters ?? "" }, ["x"])
        composer.removeFromSuperview()
        await t.check("입력창이 없으면(내부 대화 · 인스펙터) 찾지 않는다", StreamTyping.composer(near: message) == nil)
    }

    private static let sample = """
        ## 요약

        커밋 목록을 정리했습니다. **머지 커밋**은 접고, 날짜는 `RelativeDateTimeFormatter`로 바꿨습니다.

        바뀐 점:
        - `ChangesPane.swift` — 목록 행 구성
        - `ChangesState.swift` — 접기 판정

        ```swift
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        ```

        | 파일 | 변경 |
        |---|---|
        | ChangesPane.swift | +42 −8 |
        | ChangesState.swift | +17<br>새 판정 |

        ---

        ### 확인 방법

        [README](https://example.com) 를 보세요.
        """

    private static let style = MarkdownStyle(
        text: .textColor, heading: .textColor, link: .linkColor, inlineCodeText: .textColor,
        inlineCodeBackground: .quaternaryLabelColor, codeText: .textColor, codeBackground: .textBackgroundColor,
        codeHeader: .windowBackgroundColor, codeBorder: .separatorColor, codeLabel: .secondaryLabelColor,
        codeCopied: .systemGreen, tableText: .textColor, tableHeaderRule: .separatorColor,
        tableRule: .separatorColor, rule: .separatorColor)

    private static func copyAll(_ document: MarkdownDocument) -> String {
        MarkdownCopy.plainText(document.text, range: NSRange(location: 0, length: document.text.length))
    }

    // MARK: 터미널 링크

    /// 터미널 탭의 ⌘클릭 링크(OSC 8)도 메시지 링크와 같은 규칙 — 보이는 글이 `https://…` 여도 가리키는 곳으로 판정한다 (2026-10-12).
    /// 상대 경로는 풀지 않는다 (셸이 `cd` 했을 수 있다).
    @MainActor
    static func terminalLinks(_ t: TestKit) async {
        await t.group("터미널 링크 열기 (LinkOpener)")
        let files: Set<String> = ["/tmp/run.command", "/Users/me/my notes.txt", "/Users/me/Tools.app"]
        func decided(_ link: String) -> String {
            guard let url = LinkOpener.terminalURL(link) else { return "주소 아님" }
            switch LinkOpener.action(for: url, baseDirectory: nil, fileExists: { files.contains($0) }) {
            case .reveal(let file): return file.path
            case .open: return "열기"
            case .confirm: return "확인"
            case .ignore: return "무시"
            }
        }
        await t.equal("웹 주소는 바로 연다 (앞뒤 빈칸은 뗀다)",
                      [decided("https://example.com/docs"), decided(" http://localhost:3000/ ")], ["열기", "열기"])
        await t.equal("file:// 스크립트 · 앱은 실행하지 않고 Finder 에서 (호스트 이름이 붙어도)",
                      [decided("file:///tmp/run.command"), decided("file://build-host.local/tmp/run.command"),
                       decided("file:///Users/me/Tools.app")],
                      ["/tmp/run.command", "/tmp/run.command", "/Users/me/Tools.app"])
        await t.equal("빈칸이 든 경로 · % 로 적은 경로도 파일로",
                      [decided("file:///Users/me/my notes.txt"), decided("file:///Users/me/my%20notes.txt")],
                      ["/Users/me/my notes.txt", "/Users/me/my notes.txt"])
        await t.equal("그 밖의 스킴은 주소를 보이고 확인받는다",
                      [decided("x-custom-scheme://run?cmd=1"), decided("vscode://file/tmp/a.swift")], ["확인", "확인"])
        await t.equal("상대 경로 · 없는 파일은 열지 않는다",
                      [decided("run.command"), decided("src/a.swift:42"), decided("file:///tmp/gone.command")],
                      ["무시", "무시", "무시"])
        await t.equal("빈 링크는 주소가 아니다", decided("   "), "주소 아님")
    }

    // MARK: 복사 글

    @MainActor
    static func copyText(_ t: TestKit) async {
        await t.group("메시지 링크 열기 (LinkOpener)")
        await t.equal("웹 주소는 바로 연다", LinkOpener.action(for: URL(string: "https://example.com/a")!), .open)
        await t.equal("메일 주소도 바로", LinkOpener.action(for: URL(string: "mailto:a@example.com")!), .open)
        // 파일 링크: 있는 파일만 (그릴 때 · 누를 때 확인한다) — 시험은 "있다" 를 정해 넣는다.
        let files: Set<String> = ["/tmp/run.command", "/Users/me/a.swift", "/p/src/a.swift", "/p/README.md"]
        func revealed(_ link: String, base: String? = nil) -> String {
            guard let url = URL(string: link) else { return "주소 아님" }
            switch LinkOpener.action(for: url, baseDirectory: base, fileExists: { files.contains($0) }) {
            case .reveal(let file): return file.path
            case .open: return "열기"
            case .confirm: return "확인"
            case .ignore: return "무시"
            }
        }
        await t.equal("파일 주소는 실행하지 않고 Finder 에서 보인다", revealed("file:///tmp/run.command"), "/tmp/run.command")
        await t.equal("스킴 없는 절대 경로도 파일로", revealed("/Users/me/a.swift"), "/Users/me/a.swift")
        await t.equal("상대 경로는 기준 폴더가 없으면 열지 않는다", revealed("src/a.swift"), "무시")
        await t.equal("상대 경로는 대화의 프로젝트 폴더 기준", revealed("src/a.swift", base: "/p"), "/p/src/a.swift")
        await t.equal("줄 번호(:42 · :42:7 · #L42)는 떼고 연다",
                      [revealed("src/a.swift:42", base: "/p"), revealed("/Users/me/a.swift:42:7"), revealed("src/a.swift#L42", base: "/p"),
                       revealed("./src/../src/a.swift", base: "/p")],
                      ["/p/src/a.swift", "/Users/me/a.swift", "/p/src/a.swift", "/p/src/a.swift"])
        await t.equal("이름:줄 꼴(주소 규칙으로는 스킴처럼 보인다)도 파일", revealed("README.md:10", base: "/p"), "/p/README.md")
        await t.equal("없는 파일 · 조각만 있는 링크는 열지 않는다",
                      [revealed("src/gone.swift", base: "/p"), revealed("#section", base: "/p")], ["무시", "무시"])
        await t.equal("그 밖의 스킴은 주소를 보이고 확인받는다", revealed("vscode://file/a"), "확인")
        // 그릴 때: 열 수 없는 링크는 링크로 그리지 않는다 (손가락 커서가 뜨는데 눌러도 아무 일이 없었다 — chat-11).
        func linkTargets(_ source: String, base: String?) -> [String] {
            let document = MarkdownDocument(source: source, style: style, linkBase: base, fileExists: { files.contains($0) })
            var out: [String] = []
            document.text.enumerateAttribute(.link, in: NSRange(location: 0, length: document.text.length)) { value, _, _ in
                if let url = value as? URL { out.append(url.isFileURL ? url.path : url.absoluteString) }
            }
            return out
        }
        let linked = "[a](src/a.swift:42) · [없음](src/gone.swift) · [웹](https://example.com)"
        await t.equal("그릴 때: 푼 파일 · 웹 주소만 링크", linkTargets(linked, base: "/p"), ["/p/src/a.swift", "https://example.com"])
        await t.equal("그릴 때: 기준 폴더가 없으면 상대 경로는 링크가 아니다", linkTargets(linked, base: nil), ["https://example.com"])

        // 사람이 친 글 (사용자 메시지): Markdown 으로 해석하지 않고 친 그대로 — 코드 울타리만 상자 (chat-10).
        await t.group("사용자 메시지: 친 그대로")
        let traceback = "File \"a.py\", line 3, in __init__\n# 의존성 설치\n* 별표 줄 **굵게 아님** <br> 그대로\n\n\n|a|b|\n|---|---|"
        let plain = MarkdownDocument(source: traceback, style: style, plain: true)
        await t.equal("서식 · 제목 · 목록 · 표 · <br> 을 해석하지 않는다 (복사 = 원문)", copyAll(plain), traceback)
        let headingFont = plain.text.attribute(.font, at: (plain.text.string as NSString).range(of: "# 의존성").location,
                                               effectiveRange: nil) as? NSFont
        await t.equal("'# ' 줄도 본문 크기", headingFont?.pointSize, MarkdownMetrics.bodySize)
        let fenced = "앞 문단\n```swift\nlet a = 1\n```\n\n뒤 __init__"
        let fencedDoc = MarkdownDocument(source: fenced, style: style, plain: true)
        await t.equal("코드 울타리만 상자로", fencedDoc.codeBlocks.map(\.code), ["let a = 1"])
        await t.equal("보이는 글 (상자 사이 빈 줄)", copyAll(fencedDoc), "앞 문단\n\nlet a = 1\n\n뒤 __init__")
        let plainView = MarkdownTextView()
        plainView.render(source: fenced, style: style, plain: true)
        plainView.selectAll(nil)
        let board = NSPasteboard.withUniqueName()
        _ = plainView.writeSelection(to: board, types: plainView.writablePasteboardTypes)
        await t.equal("통째로 복사하면 원문 그대로 (울타리까지)", board.string(forType: .string) ?? "", fenced)
        board.releaseGlobally()
        await t.equal("일부만 고르면 보이는 글", plainView.copyText([NSRange(location: 0, length: 2)]), "앞 ")

        await t.group("메시지 복사 글")
        let document = MarkdownDocument(source: sample, style: style)
        await t.equal("전체 — 블록 사이 빈 줄 · 서식 기호 없음 · 표는 탭 · 구분선 뺌", copyAll(document), """
            요약

            커밋 목록을 정리했습니다. 머지 커밋은 접고, 날짜는 RelativeDateTimeFormatter로 바꿨습니다.

            바뀐 점:
            - ChangesPane.swift — 목록 행 구성
            - ChangesState.swift — 접기 판정

            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short

            파일\t변경
            ChangesPane.swift\t+42 −8
            ChangesState.swift\t+17 새 판정

            확인 방법

            README 를 보세요.
            """)

        let string = document.text.string as NSString
        let from = string.range(of: "날짜는").location
        let to = NSMaxRange(string.range(of: "let formatter"))
        await t.equal("문단 가운데 → 코드 가운데 (블록 경계를 넘는다)",
                      MarkdownCopy.plainText(document.text, range: NSRange(location: from, length: to - from)), """
            날짜는 RelativeDateTimeFormatter로 바꿨습니다.

            바뀐 점:
            - ChangesPane.swift — 목록 행 구성
            - ChangesState.swift — 접기 판정

            let formatter
            """)
        let heading = string.range(of: "요약")
        await t.equal("블록 끝 줄바꿈까지 고르면 빈 줄을 붙이지 않는다",
                      MarkdownCopy.plainText(document.text,
                                             range: NSRange(location: heading.location, length: heading.length + 1)),
                      "요약")

        let empty = MarkdownDocument(source: "앞\n\n```\n```\n\n| a | b |\n|---|---|\n|  | 2 |\n\n뒤", style: style)
        await t.equal("빈 코드 블록 · 빈 칸은 자리만 지킨다", copyAll(empty), "앞\n\na\tb\n\t2\n\n뒤")
    }

    // MARK: 텍스트 뷰

    @MainActor
    static func textView(_ t: TestKit) async {
        await t.group("메시지 텍스트 뷰")
        let view = MarkdownTextView()
        // 흐르는 응답 — 받은 글을 고른 속도로 풀고(`StreamReveal.Schedule`) 끝나면 마저 보인다 (`render(… reveal:)`).
        // 가림막(Core Animation)은 창에 있을 때만 짓는다 — 여기서는 일정만 본다. 동작 줄이기는 시험이 정한다
        // (시스템 설정을 따르면 동작 줄이기를 켠 Mac · CI 러너에서 일정이 없다).
        MarkdownTextView.reduceMotionOverride = false
        defer { MarkdownTextView.reduceMotionOverride = nil }
        let stream = MarkdownTextView()
        stream.render(source: "첫 조각입니다", style: style, reveal: .streaming, revealsFromBeginning: true)
        let start = CACurrentMediaTime()
        await t.equal("막 시작한 응답은 처음부터 푼다", stream.revealedLength(at: start), 0)
        let early = stream.revealedLength(at: start + 0.1) ?? -1
        await t.check("0.1초 뒤에는 일부만 보인다", early > 0 && early < 7, "\(early)")
        await t.equal("일정이 끝나면 받은 글이 다 보인다", stream.revealedLength(at: start + 5), 7)
        stream.render(source: "첫 조각입니다. 둘째 조각이 왔습니다", style: style, reveal: .streaming)
        let resumed = stream.revealedLength(at: CACurrentMediaTime()) ?? -1
        await t.check("새 조각이 와도 보이던 데서 이어 푼다 (처음부터 다시 · 한꺼번에가 아니다)", resumed >= 0 && resumed < 10,
                      "\(resumed)")
        stream.setReveal(.finished)
        await t.equal("받기를 마치면 남은 글을 빨리 마저 보인다", stream.revealedLength(at: CACurrentMediaTime() + 1), 20)
        let reopened = MarkdownTextView()
        reopened.render(source: "이미 흐르던 응답", style: style, reveal: .streaming, revealsFromBeginning: false)
        await t.equal("이미 흐르던 응답은 지금까지의 글을 곧바로", reopened.revealedLength(), 9)
        reopened.render(source: "이미 흐르던 응답의 뒷부분", style: style, reveal: .streaming)
        await t.equal("그 뒤로 온 글은 푼다", reopened.revealedLength(), 9)
        let done = MarkdownTextView()
        done.render(source: "끝난 응답", style: style, reveal: .finished, revealsFromBeginning: true)
        await t.equal("처음부터 끝나 있던 응답은 곧바로 다", done.revealedLength(), nil)
        MarkdownTextView.reduceMotionOverride = true
        let calm = MarkdownTextView()
        calm.render(source: "동작 줄이기", style: style, reveal: .streaming, revealsFromBeginning: true)
        await t.equal("동작 줄이기면 막 시작한 응답도 풀지 않고 곧바로 다", calm.revealedLength(), nil)
        MarkdownTextView.reduceMotionOverride = false

        view.render(source: sample, style: style)
        let height = view.height(forWidth: 600)
        await t.check("높이를 잰다", height > 200, "\(height)")
        await t.check("좁으면 더 높다", view.height(forWidth: 300) > height)
        view.setFrameSize(NSSize(width: 600, height: height))

        // 상자 자리를 못 찾으면 단추가 (0, 0) 왼쪽 바깥으로 빠진다 (상자 범위에 끝 줄바꿈이 빠졌을 때).
        let buttons = view.subviews.compactMap { $0 as? MarkdownCodeCopyButton }
        let frame = buttons.first?.frame ?? .zero
        await t.equal("코드 상자마다 복사 단추", buttons.count, 1)
        await t.check("복사 단추는 코드 상자 띠 오른쪽 끝", frame.maxX > 560 && frame.maxX <= 600 && frame.minY > 80,
                      "\(frame)")

        // ⌘A → ⌘C 와 같은 길 (writeSelection).
        view.selectAll(nil)
        let pasteboard = NSPasteboard.withUniqueName()
        let written = view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes)
        await t.check("⌘A 는 메시지 전체", view.selectedRange().length == view.textStorage?.length)
        await t.check("선택을 붙여 넣기 판에 쓴다", written)
        await t.equal("⌘C 글 = 복사 글", pasteboard.string(forType: .string) ?? "",
                      copyAll(MarkdownDocument(source: sample, style: style)))
        pasteboard.releaseGlobally()

        let click = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1)
        let items = click.flatMap { view.menu(for: $0) }?.items ?? []
        let actions = items.compactMap { $0.action.map(NSStringFromSelector) }
        let describe = items.map { $0.isSeparatorItem ? "|" : $0.title }.joined(separator: ", ")
        await t.check("오른쪽 클릭: 복사 다음에 메시지 전체 복사 (Markdown)",
                      actions.firstIndex(of: "copy:").map { actions.indices.contains($0 + 1) && actions[$0 + 1] == "copyMessage:" }
                        == true, describe)
        await t.check("오른쪽 클릭: 편집 항목 · 맞춤법 · 대치 메뉴 없음 · 구분선 겹침 없음",
                      !actions.contains("cut:") && !actions.contains("paste:") && !actions.contains("pasteAsPlainText:")
                        && !items.contains { $0.submenu?.items.contains { $0.action == #selector(NSText.showGuessPanel(_:)) } == true }
                        && items.first?.isSeparatorItem != true && items.last?.isSeparatorItem != true
                        && !zip(items, items.dropFirst()).contains { $0.isSeparatorItem && $1.isSeparatorItem },
                      describe)
    }
}

// MARK: - 대화 스트림 선택

/// 메시지마다 텍스트 뷰가 따로라도, 메시지 사이에 명령 · 도구 기록이 끼어도 한 번의 끌기 · ⌘A 로 고르고 순서대로 복사한다
/// (`UI/Stream/StreamSelection.swift`). 메시지는 글자 단위, 사이의 SwiftUI 행은 행 단위.
extension MarkdownTests {
    @MainActor
    static func streamDecisions(_ t: TestKit) async {
        await t.group("대화 스트림 선택 판정")
        let lengths = [10, 1, 10]
        await t.equal("한 메시지 안", StreamSelection.ranges(from: (0, 3), to: (0, 7), lengths: lengths),
                      [0: NSRange(location: 3, length: 4)])
        await t.equal("거꾸로 끌어도 같다 · 사이 행은 통째로",
                      StreamSelection.ranges(from: (2, 4), to: (0, 6), lengths: lengths),
                      [0: NSRange(location: 6, length: 4), 1: NSRange(location: 0, length: 1),
                       2: NSRange(location: 0, length: 4)])
        await t.equal("메시지 끝에서 시작하면 그 메시지는 빼고 다음부터",
                      StreamSelection.ranges(from: (0, 10), to: (2, 2), lengths: lengths),
                      [1: NSRange(location: 0, length: 1), 2: NSRange(location: 0, length: 2)])

        // 창 좌표(위가 큰 y): 메시지 300…400, 명령 행 200…280, 메시지 50…150.
        let frames = [NSRect(x: 20, y: 300, width: 400, height: 100), NSRect(x: 20, y: 200, width: 400, height: 80),
                      NSRect(x: 20, y: 50, width: 400, height: 100)]
        func position(_ point: NSPoint, anchor: Int = 0) -> [Int] {
            StreamSelection.position(of: point, frames: frames, lengths: lengths, atoms: [false, true, false],
                                     anchorOrder: anchor, index: { _ in 5 }).map { [$0.order, $0.index] } ?? []
        }
        await t.equal("메시지 안 → 그 글자", position(NSPoint(x: 100, y: 100)), [2, 5])
        await t.equal("메시지 사이 틈 → 위 메시지 끝", position(NSPoint(x: 100, y: 290)), [0, 10])
        await t.equal("명령 행 (기준점 뒤) → 행을 넣는 끝", position(NSPoint(x: 100, y: 240)), [1, 1])
        await t.equal("명령 행 (기준점 앞) → 행의 처음", position(NSPoint(x: 100, y: 240), anchor: 2), [1, 0])
        await t.equal("맨 위보다 위 → 처음", position(NSPoint(x: 100, y: 500)), [0, 0])
        await t.equal("맨 아래보다 아래 → 마지막 끝", position(NSPoint(x: 100, y: 10)), [2, 10])
        await t.equal("같은 높이의 여백 → 그 메시지", position(NSPoint(x: 600, y: 100)), [2, 5])

        await t.equal("잇기: 이름은 바로 아래 · 메시지는 빈 줄 · 실행 줄끼리는 줄바꿈",
                      StreamSelection.joined([(.label, "Claude"), (.block, "요약"), (.line, "$ git status"),
                                              (.line, "· Read a.swift"), (.block, "끝")]),
                      "Claude\n요약\n\n$ git status\n· Read a.swift\n\n끝")
        await t.check("한 메시지 안은 텍스트 뷰가 스스로 복사 · 행이 섞이거나 둘 이상이면 스트림 복사",
                      !StreamSelection.spans([0: NSRange(location: 0, length: 3)], atoms: [false, true])
                        && StreamSelection.spans([1: NSRange(location: 0, length: 1)], atoms: [false, true])
                        && StreamSelection.spans([0: NSRange(location: 0, length: 1), 2: NSRange(location: 0, length: 1)],
                                                 atoms: [false, true, false]))
    }

    /// 스크롤 뷰 안에 메시지 → 명령 행 → 메시지를 쌓고, 첫 메시지에서 누른 끌기를 창 이벤트로 흘려 보낸다.
    @MainActor
    static func streamDrag(_ t: TestKit) async {
        await t.group("대화 스트림 선택 끌기")
        _ = NSApplication.shared
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        scroll.documentView = document
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 600, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = scroll
        let first = MarkdownTextView()
        let second = MarkdownTextView()
        first.render(source: "첫 응답 문단입니다.\n\n둘째 문단.", style: style)
        second.render(source: "명령 뒤의 문단입니다.", style: style)
        let command = StreamSelectionAtomView()
        command.copyText = "$ git status"
        var y: CGFloat = 10
        for view in [first, command, second] as [NSView] {
            let height = (view as? MarkdownTextView)?.height(forWidth: 560) ?? 24
            view.frame = NSRect(x: 20, y: y, width: 560, height: height)
            document.addSubview(view)
            y += height + 12
        }

        func windowPoint(_ view: MarkdownTextView, _ text: String) -> NSPoint {
            let index = (view.string as NSString).range(of: text).location
            let layoutManager = view.layoutManager!
            let glyph = layoutManager.glyphIndexForCharacter(at: index)
            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                                  in: view.textContainer!)
                .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            return view.convert(NSPoint(x: rect.minX + 1, y: rect.midY), to: nil)
        }
        func copied() -> String {
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            _ = first.writeSelection(to: pasteboard, types: first.writablePasteboardTypes)
            return pasteboard.string(forType: .string) ?? ""
        }

        // 마우스 끌기 한 번과 같은 순서 (`track` 의 이벤트 고리는 비동기 main 의 실행 고리를 멈춰 검증 실행 파일에서는 부르지 않는다).
        guard let selection = StreamSelection.domain(for: first) else {
            return await t.check("스크롤 뷰 안의 메시지는 스트림 선택에 든다", false)
        }
        let start = windowPoint(first, "응답")
        selection.begin(at: start, in: first)
        selection.extend(to: NSPoint(x: start.x + 30, y: start.y - 30))
        selection.extend(to: windowPoint(second, "뒤의"))
        await t.check("끌기를 시작한 메시지가 첫 응답자 (⌘C 가 닿는 곳)", window.firstResponder === first)
        await t.check("사이 명령 행 · 다음 메시지까지 골라진다",
                      command.isStreamSelected && second.selectedRange().length > 0,
                      "\(command.isStreamSelected) \(second.selectedRange())")
        await t.equal("⌘C: 메시지 → 명령 → 메시지 순서대로", copied(),
                      "응답 문단입니다.\n\n둘째 문단.\n\n$ git status\n\n명령 ")

        selection.extend(to: windowPoint(first, "둘째"))
        await t.check("다시 위로 끌면 지나온 행 · 메시지는 풀린다",
                      !command.isStreamSelected && second.selectedRange().length == 0)
        await t.equal("한 메시지 안으로 돌아오면 그 메시지만", copied(), "응답 문단입니다.")

        selection.begin(at: windowPoint(second, "문단"), in: second, extending: true)
        await t.check("⇧ 누르기: 다른 메시지까지 이어 늘린다 (첫 응답자가 바뀌어도 기준점은 그대로)",
                      window.firstResponder === second && command.isStreamSelected
                        && first.selectedRange().location == 2)
        await t.equal("⇧ 누르기 뒤 복사", copied(), "응답 문단입니다.\n\n둘째 문단.\n\n$ git status\n\n명령 뒤의 ")

        first.selectAll(nil)
        await t.equal("⌘A: 대화 전체", copied(), "첫 응답 문단입니다.\n\n둘째 문단.\n\n$ git status\n\n명령 뒤의 문단입니다.")
        window.makeFirstResponder(nil)
        await t.check("다른 곳이 첫 응답자가 되면 선택을 지운다",
                      !command.isStreamSelected && second.selectedRange().length == 0)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
