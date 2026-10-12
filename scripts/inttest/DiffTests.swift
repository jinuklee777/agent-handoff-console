import Foundation

/// 5단계 — 파일 diff: 통합 diff 파서 · 줄 안 강조 · hunk 포함 판정 · 펼치기 구간 · 나란히 짝맞추기 · 화면 행 ·
/// 이전/다음 파일 · 크게 보기 복원 · diff 키, 그리고 임시 저장소의 실제 git diff 로 조회 전체.
extension WorkspaceTests {
    static func diffDecisions(_ t: TestKit) async {
        await diffParsing(t)
        await diffWordHighlight(t)
        await diffInclusion(t)
        await diffGapsAndRows(t)
        await diffNavigation(t)
    }

    // MARK: 파서

    static func diffParsing(_ t: TestKit) async {
        await t.group("파일 diff 해석")

        // 줄 수 생략 = 1, 여러 hunk, 구역 이름
        let two = UnifiedDiff.parse("""
            diff --git a/Moa/Login/LoginView.swift b/Moa/Login/LoginView.swift
            index 0265eb757204b5a93e3264b16337429b4c2498ae..ced238c1233962bf99a0ca51e7336ae7dfa05fba 100644
            --- a/Moa/Login/LoginView.swift
            +++ b/Moa/Login/LoginView.swift
            @@ -7,7 +7,7 @@ struct LoginView: View {

                 var body: some View {
                     VStack(spacing: 16) {
            -            TextField("이메일", text: $email)
            +            EmailField(text: $email)
                             .textFieldStyle(.roundedBorder)
                         SecureField("비밀번호", text: $password)
                             .textContentType(.password)
            @@ -15,7 +15,9 @@ struct LoginView: View {
                     .padding()
                     .navigationTitle("로그인")
                     .task {
            -            await viewModel.refresh()
            +            if viewModel.state == .idle {
            +                await viewModel.refresh()
            +            }
                     }
                 }
             }

            """)
        let login = two.files.first
        await t.equal("파일 하나 · hunk 둘", [two.files.count, login?.hunks.count ?? 0], [1, 2])
        await t.equal("경로 · blob (전체 이름)", [login?.oldPath ?? "", login?.newPath ?? "", login?.oldBlob ?? ""],
                      ["Moa/Login/LoginView.swift", "Moa/Login/LoginView.swift", "0265eb757204b5a93e3264b16337429b4c2498ae"])
        let h0 = login?.hunks.first
        await t.equal("hunk 머리 (옛 7,7 → 새 7,7 · 구역)", [h0?.oldStart ?? 0, h0?.oldCount ?? 0, h0?.newStart ?? 0,
                                                       h0?.newCount ?? 0], [7, 7, 7, 7])
        await t.equal("구역 이름", h0?.section, "struct LoginView: View {")
        await t.check("빈 문맥 줄(공백 한 칸)도 문맥 · 옛/새 번호 7",
                      h0?.lines.first?.kind == .context && h0?.lines.first?.text == ""
                      && h0?.lines.first?.oldNumber == 7 && h0?.lines.first?.newNumber == 7)
        let removed = h0?.lines.first { $0.kind == .removed }
        let added = h0?.lines.first { $0.kind == .added }
        await t.check("지운 줄은 옛 번호만 · 더한 줄은 새 번호만 (10 · 10)",
                      removed?.oldNumber == 10 && removed?.newNumber == nil && added?.newNumber == 10 && added?.oldNumber == nil)
        let h1 = login?.hunks.last
        await t.equal("두 번째 hunk 끝 줄의 새 번호 (15+9−1)", h1?.lines.last?.newNumber, 23)
        await t.equal("더한 줄 · 지운 줄 수", [login?.addedCount ?? 0, login?.removedCount ?? 0], [4, 2])
        await t.equal("줄 수 생략 = 1 (@@ -3 +3 @@)", UnifiedDiff.parseHunkHeader("@@ -3 +3 @@").map { [$0.0, $0.1, $0.2, $0.3] },
                      [3, 1, 3, 1])
        await t.equal("새 파일 hunk (@@ -0,0 +1,3 @@)",
                      UnifiedDiff.parseHunkHeader("@@ -0,0 +1,3 @@").map { [$0.0, $0.1, $0.2, $0.3] }, [0, 0, 1, 3])
        await t.check("망가진 hunk 머리는 nil", UnifiedDiff.parseHunkHeader("@@ -a,b +1 @@") == nil
                      && UnifiedDiff.parseHunkHeader("@@ -1,2 @@") == nil)

        // 새 파일 · 탭 · 유니코드 · CRLF · "\ No newline" (번역된 것 포함)
        let new = UnifiedDiff.parse("diff --git a/새 파일.swift b/새 파일.swift\r\nnew file mode 100644\r\n"
                                    + "index 0000000..9ed2006\r\n--- /dev/null\r\n+++ b/새 파일.swift\t\r\n"
                                    + "@@ -0,0 +1,3 @@\r\n+\tlet 이름 = \"값\"\r\n+👍🏽 emoji\r\n+끝\r\n"
                                    + "\\ 파일 끝에 줄바꿈 문자가 없음\r\n")
        let nf = new.files.first
        await t.check("새 파일 머리 · 옛 경로 없음 · 공백 경로 뒤 탭 뗌",
                      nf?.isNewFile == true && nf?.oldPath == nil && nf?.newPath == "새 파일.swift", "\(String(describing: nf))")
        await t.equal("CRLF 를 뗀 본문 · 탭 · 유니코드 그대로", nf?.hunks.first?.lines.map(\.text),
                      ["\tlet 이름 = \"값\"", "👍🏽 emoji", "끝", " 파일 끝에 줄바꿈 문자가 없음"])
        await t.equal("번호 1·2·3 · 표식은 번호 없음", nf?.hunks.first?.lines.map { $0.newNumber ?? -1 }, [1, 2, 3, -1])
        await t.check("\\ 줄은 표식 (번역돼도)", nf?.hunks.first?.lines.last?.kind == .marker)
        await t.check("표식이 있으면 파일 끝을 안다", nf.map(DiffGaps.endKnown) == true)

        // 빈 diff
        let empty = UnifiedDiff.parse("")
        await t.check("빈 diff → 파일 없음 · 줄 0", empty.files.isEmpty && empty.totalBodyLines == 0 && !empty.truncated)
        await t.equal("빈 diff 의 사유", FileDiffBuild.noLinesReason(nil),
                      .noLines("마지막 커밋과 지금 파일 사이에 차이가 없습니다 — 그 사이 되돌렸을 수 있습니다."))

        // 머리 줄: 이름 변경 · 권한 · 삭제 · 이진 (영어 · 번역) · GIT binary patch · 캐시의 충돌 표시
        let rename = UnifiedDiff.parse("diff --git a/old.txt b/new.txt\nsimilarity index 100%\nrename from old.txt\n"
                                       + "rename to new.txt\n")
        await t.equal("이름만 바뀜 (100%)", FileDiffBuild.noLinesReason(rename.files.first), .noLines("내용은 같고 이름만 바뀌었습니다."))
        await t.check("이름 변경 경로", rename.files.first?.oldPath == "old.txt" && rename.files.first?.newPath == "new.txt")
        let mode = UnifiedDiff.parse("diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n")
        await t.equal("권한만 바뀜", FileDiffBuild.noLinesReason(mode.files.first),
                      .noLines("내용은 같고 파일 권한만 바뀌었습니다 (100644 → 100755)."))
        let binary = UnifiedDiff.parse("diff --git a/bin.dat b/bin.dat\nindex 88768ef..f68ed80 100644\n"
                                       + "Binary files a/bin.dat and b/bin.dat differ\n")
        let binaryKo = UnifiedDiff.parse("diff --git a/bin.dat b/bin.dat\nindex 88768ef..f68ed80 100644\n"
                                         + "바이너리 파일 a/bin.dat 및 b/bin.dat 다름\n")
        let patch = UnifiedDiff.parse("diff --git a/x.png b/x.png\nindex 1..2 100644\nGIT binary patch\nliteral 3\n")
        await t.check("이진 파일: 영어 · 번역된 문구 · GIT binary patch 모두 이진",
                      FileDiffBuild.noLinesReason(binary.files.first) == .binary
                      && FileDiffBuild.noLinesReason(binaryKo.files.first) == .binary
                      && FileDiffBuild.noLinesReason(patch.files.first) == .binary)
        let unmerged = UnifiedDiff.parse("* Unmerged path Moa/Auth/AuthViewModel.swift\n")
        await t.check("캐시 diff 의 충돌 표시 줄은 파일이 아니다", unmerged.files.isEmpty && unmerged.strayLines.count == 1)
        let emptyNew = UnifiedDiff.parse("diff --git a/e.txt b/e.txt\nnew file mode 100644\nindex 0000000..e69de29\n")
        await t.equal("빈 새 파일", FileDiffBuild.noLinesReason(emptyNew.files.first), .noLines("빈 새 파일입니다."))

        // 따옴표 경로 (C 형식 · 8진수 UTF-8)
        await t.equal("따옴표 경로 풀기", UnifiedDiff.unquote("\"a/\\355\\225\\234 \\\"q\\\"\\t.txt\""), "a/한 \"q\"\t.txt")
        await t.equal("diff --git 줄의 공백 경로", UnifiedDiff.gitHeaderPaths("a/my file.txt b/my file.txt").map { [$0.old, $0.new] },
                      ["my file.txt", "my file.txt"])

        // 본문이 머리처럼 보여도 hunk 줄 수로 끝을 안다
        let tricky = UnifiedDiff.parse("diff --git a/d.txt b/d.txt\n--- a/d.txt\n+++ b/d.txt\n@@ -1,2 +1,2 @@\n"
                                       + " diff --git a/x b/x\n-@@ -1 +1 @@\n+@@ -9 +9 @@\n")
        await t.check("문맥 ' diff --git' · '-@@' 는 본문 (새 파일 · 새 hunk 아님)",
                      tricky.files.count == 1 && tricky.files[0].hunks.count == 1 && tricky.files[0].hunks[0].lines.count == 3)

        // 상한: 앞부분만 담고 전체 수는 센다
        let long = "diff --git a/l.txt b/l.txt\n--- a/l.txt\n+++ b/l.txt\n@@ -1,6 +1,6 @@\n"
            + (1...6).map { "-o\($0)\n+n\($0)\n" }.joined() + "@@ -20,1 +20,1 @@\n-x\n+y\n"
        let cut = UnifiedDiff.parse(long, lineLimit: 5)
        await t.check("상한 5줄: 담은 5 · 전체 14 · 잘림 표시 · 뒤 hunk 는 담지 않음",
                      cut.shownBodyLines == 5 && cut.totalBodyLines == 14 && cut.truncated
                      && cut.files.first?.hunks.count == 1 && cut.files.first?.hunks.first?.truncated == true,
                      "\(cut.shownBodyLines)/\(cut.totalBodyLines) hunks \(cut.files.first?.hunks.count ?? -1)")

        // 이름 변경을 git 이 짝짓지 못하면 (지운 파일 + 새 파일) 새 경로를 고르고 그 사실을 적는다
        let split = UnifiedDiff.parse("diff --git a/a.txt b/a.txt\ndeleted file mode 100644\n--- a/a.txt\n+++ /dev/null\n"
                                      + "@@ -1 +0,0 @@\n-a\ndiff --git a/b.txt b/b.txt\nnew file mode 100644\n--- /dev/null\n"
                                      + "+++ b/b.txt\n@@ -0,0 +1 @@\n+b\n")
        let picked = FileDiffBuild.pick(split, path: "b.txt", originalPath: "a.txt")
        await t.check("짝짓지 못한 이름 변경: 새 경로 · 안내 한 줄", picked.0?.newPath == "b.txt" && picked.1.count == 1)
        let other = UnifiedDiff.parse("diff --git a/memo.txt b/memo.txt\n--- a/memo.txt\n+++ b/memo.txt\n@@ -1 +1 @@\n-a\n+b\n")
        await t.check("경로가 다른 파일 하나뿐이면 고르지 않음 (다른 파일의 diff 를 이 이름으로 보이지 않게)",
                      FileDiffBuild.pick(other, path: ":memo.txt", originalPath: nil).0 == nil)
    }

    // MARK: 줄 안 강조

    static func diffWordHighlight(_ t: TestKit) async {
        await t.group("줄 안 단어 강조")
        func mid(_ old: String, _ new: String) -> [String]? {
            guard let r = WordDiff.changedRanges(old: old, new: new) else { return nil }
            let a = Array(old), b = Array(new)
            return [r.old.map { String(a[$0]) } ?? "", r.new.map { String(b[$0]) } ?? ""]
        }
        await t.equal("낱말 단위 (끝 글자 t 가 같아도 쪼개지 않음)",
                      mid("    private let api: APIClient", "    private let transport: AuthTransport"),
                      ["api: APIClient", "transport: AuthTransport"])
        await t.equal("괄호 안 가운데",
                      mid("    init(api: APIClient = .shared) {", "    init(transport: AuthTransport = URLSessionTransport()) {"),
                      ["api: APIClient = .shared", "transport: AuthTransport = URLSessionTransport()"])
        await t.equal("self. 뒤", mid("        self.api = api", "        self.transport = transport"),
                      ["api = api", "transport = transport"])
        await t.check("공통이 들여쓰기뿐이면 강조하지 않음",
                      mid("        guard let token = try? await api.refreshToken() else {",
                          "        // 동시에 불려도 갱신 요청은 한 번만 보낸다") == nil)
        await t.check("같은 줄 · 공백만 있는 줄은 강조 없음", mid("a b", "a b") == nil && mid("   ", "  ") == nil)
        await t.equal("끼워 넣기만: 옛 쪽 강조 없음", mid("foo()", "foo(bar)"), ["", "bar"])
        await t.check("들여쓰기만 바뀐 줄은 강조 없음 (빈칸 덩어리를 칠하지 않음)",
                      mid("            await viewModel.refresh()", "                await viewModel.refresh()") == nil)
        await t.equal("공백만 바뀐 쪽은 그쪽만 빼고 강조", mid("a b", "a.b"), ["", "."])
        await t.equal("한글 낱말", mid("let 이름 = 1", "let 별명 = 1"), ["이름", "별명"])
        await t.check("너무 긴 줄은 비교하지 않음",
                      mid(String(repeating: "a", count: 2_001), String(repeating: "a", count: 2_000) + "b") == nil)

        // 짝: 수가 같으면 순서대로, 다르면 비슷한 줄 (목업의 84 ↔ 93)
        await t.check("수가 같으면 순서대로", WordDiff.pairs(removed: ["a", "b"], added: ["c", "d"]).map { [$0.0, $0.1] } == [[0, 0], [1, 1]])
        let removed = ["        guard let token = try? await api.refreshToken() else {"]
        let added = ["        // 동시에 불려도 갱신 요청은 한 번만 보낸다", "        if let refreshTask {",
                     "            _ = try? await refreshTask.value", "            return", "        }",
                     "        let task = Task { try await transport.refresh() }", "        refreshTask = task",
                     "        defer { refreshTask = nil }", "        guard let token = try? await task.value else {"]
        let pairs = WordDiff.pairs(removed: removed, added: added)
        await t.check("수가 다르면 비슷한 줄끼리 (−1 ↔ +9번째)", pairs.map { [$0.0, $0.1] } == [[0, 8]],
                      "\(pairs.map { [$0.0, $0.1] })")
        let oneToTwo = WordDiff.pairs(removed: ["    private let api: APIClient"],
                                      added: ["    private let transport: AuthTransport",
                                              "    private var refreshTask: Task<Token, Error>?"])
        await t.check("−1 / +2: 가장 비슷한 줄과 짝 (목업 줄 16)", oneToTwo.map { [$0.0, $0.1] } == [[0, 0]],
                      "\(oneToTwo.map { [$0.0, $0.1] })")
        let clear = WordDiff.pairs(removed: ["        api.clearSession()"],
                                   added: ["        refreshTask?.cancel()", "        transport.clearSession()"])
        await t.check("−1 / +2: 뒤쪽 줄이 더 비슷하면 그 줄 (목업 줄 132)", clear.map { [$0.0, $0.1] } == [[0, 1]])
        var lines = [DiffLine(kind: .removed, oldNumber: 84, text: removed[0])]
            + added.enumerated().map { DiffLine(kind: .added, newNumber: 85 + $0.offset, text: $0.element) }
        WordDiff.annotate(&lines)
        let a = Array(lines[0].text), b = Array(lines[9].text)
        await t.check("묶음 강조: api.refreshToken() ↔ task.value, 나머지 줄은 강조 없음",
                      lines[0].highlights.map { String(a[$0]) } == ["api.refreshToken()"]
                      && lines[9].highlights.map { String(b[$0]) } == ["task.value"]
                      && lines[1..<9].allSatisfy { $0.highlights.isEmpty })
        var marked = [DiffLine(kind: .removed, oldNumber: 3, text: "value = 1"),
                      DiffLine(kind: .marker, text: "x"),
                      DiffLine(kind: .added, newNumber: 3, text: "value = 2")]
        WordDiff.annotate(&marked)
        await t.check("묶음 사이의 표식은 건너뜀", marked[0].highlights == [8..<9] && marked[2].highlights == [8..<9])
        await t.check("짝을 적는다 (−1 ↔ +9번째, 나란히 보기가 같은 행에 놓는다)",
                      lines[0].partner == 9 && lines[9].partner == 0 && lines[1..<9].allSatisfy { $0.partner == nil })
    }

    // MARK: 포함 상태

    static func diffInclusion(_ t: TestKit) async {
        await t.group("hunk 포함 상태 (on · 일부 · off)")
        func hunks(_ text: String) -> [DiffHunk] {
            UnifiedDiff.parse("diff --git a/f b/f\n--- a/f\n+++ b/f\n" + text).files.first?.hunks ?? []
        }
        let head = hunks("@@ -7,3 +7,3 @@\n a\n-b\n+B\n c\n@@ -15,3 +15,5 @@\n x\n-y\n+if\n+  y\n+end\n z\n")
        let firstOnly = hunks("@@ -7,3 +7,3 @@\n a\n-b\n+B\n c\n")
        await t.equal("스테이지만 된 파일 (두 diff 같음) → 전부 on", DiffInclusion.states(head: head, cached: head).states,
                      [.on, .on])
        await t.equal("새 파일 · 스테이지 없음 → 전부 off", DiffInclusion.states(head: head, cached: []).states, [.off, .off])
        let login = DiffInclusion.states(head: head, cached: firstOnly)
        await t.equal("첫 hunk 만 스테이지 → on · off", login.states, [.on, .off])
        await t.equal("일부 포함 안내", DiffInclusion.summary(login), "변경 2곳 중 1곳만 이번 커밋에 들어갑니다.")
        func doc(_ inclusion: ChangesState.Inclusion, _ result: DiffInclusion.Result?) -> FileDiffDocument {
            var d = FileDiffDocument(request: FileDiffRequest(path: "f", untracked: false, conflicted: false, inclusion: inclusion,
                                                              noCommitsYet: false))
            d.inclusion = result
            return d
        }
        await t.equal("hunk 머리에 적기: 일부 포함 파일만 (hunk 가 모두 같은 '일부' 여도) · 전부 포함 · 전부 빼기 · 판정 없음은 적지 않음",
                      [doc(.mixed, login).showsHunkInclusion, doc(.mixed, .init(states: [.partial], stagedOnly: 0)).showsHunkInclusion,
                       doc(.on, .init(states: [.on, .on], stagedOnly: 0)).showsHunkInclusion,
                       doc(.off, .init(states: [.off], stagedOnly: 0)).showsHunkInclusion, doc(.mixed, nil).showsHunkInclusion],
                      [true, true, false, false, false])

        // 줄 단위: HEAD a b → 인덱스 A b → 작업 트리 A B. 작업 트리 hunk 는 −a −b +A +B, 캐시는 −a +A → 일부.
        let wt = hunks("@@ -1,2 +1,2 @@\n-a\n-b\n+A\n+B\n")
        let idx = hunks("@@ -1,2 +1,2 @@\n-a\n+A\n b\n")
        await t.equal("줄 단위 부분 스테이지 → 일부", DiffInclusion.states(head: wt, cached: idx).states, [.partial])
        // 스테이지한 뒤 작업 트리에서 되돌린 변경은 지금 diff 에 없다 → 그래도 커밋에 들어간다고 밝힌다.
        let revertedInWorktree = DiffInclusion.states(head: hunks("@@ -20,1 +20,1 @@\n-p\n+q\n"),
                                                      cached: hunks("@@ -1,1 +1,1 @@\n-a\n+b\n"))
        await t.check("지금 파일에 없는 스테이지 변경 수 · 안내",
                      revertedInWorktree.states == [.off] && revertedInWorktree.stagedOnly == 2
                      && DiffInclusion.summary(revertedInWorktree).contains("커밋에 포함해 둔 변경 2줄도 함께 커밋됩니다"),
                      DiffInclusion.summary(revertedInWorktree))
        // 새 파일을 스테이지한 뒤 더 고침 (AM): 옛 줄이 없는 hunk 끼리 겹친다.
        let am = DiffInclusion.states(head: hunks("@@ -0,0 +1,3 @@\n+l1\n+l2\n+l3\n"), cached: hunks("@@ -0,0 +1,2 @@\n+l1\n+l2\n"))
        await t.equal("새 파일 스테이지 후 한 줄 더 → 일부", am.states, [.partial])
        // 같은 글자라도 겹치지 않는 hunk 의 줄로 채우지 않는다.
        let far = DiffInclusion.states(head: hunks("@@ -1,1 +1,2 @@\n x\n+}\n"), cached: hunks("@@ -50,1 +50,2 @@\n y\n+}\n"))
        await t.equal("멀리 떨어진 같은 글자는 다른 변경", far.states, [.off])
        await t.equal("안내: 모두 · 없음 · 일부만 · 섞임",
                      [DiffInclusion.summary(.init(states: [.on, .on], stagedOnly: 0)),
                       DiffInclusion.summary(.init(states: [.off], stagedOnly: 0)),
                       DiffInclusion.summary(.init(states: [.partial, .off], stagedOnly: 0)),
                       DiffInclusion.summary(.init(states: [.on, .partial, .off], stagedOnly: 0))],
                      ["변경 2곳이 모두 이번 커밋에 들어갑니다.", "변경 1곳 모두 이번 커밋에 들어가지 않습니다.",
                       "변경 2곳 중 1곳은 일부만 이번 커밋에 들어갑니다.",
                       "변경 3곳 중 1곳이 이번 커밋에 들어가고 1곳은 일부만 들어갑니다."])
        await t.check("근사치 도움말", DiffInclusion.approximationHelp.contains("근사치"))
    }

    // MARK: 펼치기 · 나란히 · 화면 행

    static func diffGapsAndRows(_ t: TestKit) async {
        await t.group("펼치기 구간 · 나란히 짝맞추기 · 화면 행")
        func file(_ text: String) -> FileDiff {
            UnifiedDiff.parse("diff --git a/f b/f\n--- a/f\n+++ b/f\n" + text).files.first ?? FileDiff()
        }
        // 목업 AuthViewModel: 줄 14–22 · 83–97 · 131–… (옛 쪽 기준 구간)
        let f = file("@@ -14,8 +14,9 @@ final class AuthViewModel\n" + (0..<7).map { _ in " c\n" }.joined() + "-x\n+y\n+z\n"
                     + "@@ -83,6 +84,14 @@ func refresh() async\n c\n-a\n" + (0..<9).map { " \($0)\n".replacingOccurrences(of: " ", with: "+") }.joined()
                     + " d\n e\n f\n g\n")
        await t.equal("hunk 둘", f.hunks.count, 2)
        let gaps = DiffGaps.compute(f.hunks, oldLineCount: 140, endKnown: false)
        await t.equal("구간: 앞 1–13 · 사이 22–82 (61줄) · 끝 89–140", gaps.map { [$0.oldStart, $0.count ?? -1] },
                      [[1, 13], [22, 61], [89, 52]])
        await t.equal("사이 구간의 새 쪽 시작 = 옛 + 1", gaps[1].newStart, 23)
        await t.equal("옛 파일 줄 수를 모르면 끝 구간 수 없음",
                      DiffGaps.compute(f.hunks, oldLineCount: nil, endKnown: false).last?.count, nil as Int?)
        await t.equal("파일 끝을 알면 끝 구간 없음", DiffGaps.compute(f.hunks, oldLineCount: nil, endKnown: true).count, 2)
        await t.check("새 파일은 구간 없음",
                      DiffGaps.compute(file("@@ -0,0 +1,2 @@\n+a\n+b\n").hunks, oldLineCount: 0, endKnown: true).isEmpty)
        let oldLines = (1...140).map { "old \($0)" }
        await t.equal("구간 줄 읽기 (22–24)", DiffGaps.lines(of: gaps[1], oldLines: oldLines)?.prefix(3).map { $0 }, ["old 22", "old 23", "old 24"])
        await t.check("범위를 벗어나면 nil", DiffGaps.lines(of: DiffGap(beforeHunk: 0, oldStart: 139, newStart: 139, count: 5),
                                                     oldLines: oldLines) == nil)
        await t.equal("blob 줄 나누기 (끝 줄바꿈 있음 · 없음 · 빈 파일)",
                      [DiffGaps.splitLines("a\nb\n"), DiffGaps.splitLines("a\nb"), DiffGaps.splitLines("")], [["a", "b"], ["a", "b"], []])

        // 화면 행: 접힌 구간 → 펼치면 두 번호가 붙은 문맥 줄
        var input = DiffRows.Input(file: f, gaps: gaps, expanded: [], oldLines: oldLines)
        var rows = DiffRows.build(input, mode: .unified)
        let folds = rows.compactMap { row -> String? in if case .fold(_, let label, _) = row.content { return label }; return nil }
        await t.equal("접힌 구간 문구", folds, ["변경 없는 줄 13개 펼치기", "변경 없는 줄 61개 펼치기", "변경 없는 줄 52개 펼치기"])
        await t.check("행 id 는 모두 다르다", Set(rows.map(\.id)).count == rows.count)
        input.expanded = [1]
        rows = DiffRows.build(input, mode: .unified)
        let expandedCells = rows.compactMap { row -> DiffCell? in
            if case .gapLine(1, _, _) = row.id, case .unified(let cell) = row.content { return cell }
            return nil
        }
        await t.check("펼친 61줄: 옛 22 · 새 23 부터", expandedCells.count == 61 && expandedCells.first?.oldNumber == 22
                      && expandedCells.first?.newNumber == 23 && expandedCells.first?.text == "old 22")
        input.expanded = [2]
        rows = DiffRows.build(input, mode: .unified)
        if case .end(let text)? = rows.last?.content {
            await t.equal("끝 구간을 펼치면 파일 끝 표시", text, "파일 끝 · 변경 2곳")
        } else {
            await t.check("끝 구간을 펼치면 파일 끝 표시", false)
        }
        let unknownEnd = DiffRows.build(DiffRows.Input(file: f, gaps: DiffGaps.compute(f.hunks, oldLineCount: nil, endKnown: false)),
                                        mode: .unified)
        if case .fold(_, let label, let expandable)? = unknownEnd.last?.content {
            await t.check("옛 파일을 못 읽으면 끝 구간은 수 없이 · 펼칠 수 없음", label == "파일 끝까지 · 줄 수 미확인" && !expandable, label)
        } else {
            await t.check("옛 파일을 못 읽으면 끝 구간은 수 없이 · 펼칠 수 없음", false)
        }
        let atEnd = DiffRows.build(DiffRows.Input(file: f, gaps: DiffGaps.compute(f.hunks, oldLineCount: 88, endKnown: false),
                                                  oldLines: Array(oldLines.prefix(88))), mode: .unified)
        if case .end(let text)? = atEnd.last?.content {
            await t.equal("끝까지 바뀐 파일은 '파일 끝'", text, "파일 끝 · 변경 2곳")
        }

        // hunk 머리 문구
        await t.equal("hunk 머리 (새 쪽 범위 + 구역)", DiffText.hunkLabel(f.hunks[0]), "줄 14–22 · final class AuthViewModel")
        await t.equal("한 줄 · 구역 없음", DiffText.hunkLabel(DiffHunk(oldStart: 5, oldCount: 1, newStart: 5, newCount: 1)), "줄 5")
        await t.equal("파일 전체 삭제는 옛 줄", DiffText.hunkLabel(DiffHunk(oldStart: 1, oldCount: 3, newStart: 0, newCount: 0)),
                      "옛 줄 1–3")

        // 나란히 (목업 LOGIN_SPLIT): −2/+2 는 두 행, −1/+4 는 넷 (왼쪽 빈 칸 셋)
        let login = file("@@ -24,6 +24,6 @@\n a\n b\n-c\n-d\n+C\n+D\n e\n f\n@@ -50,5 +50,8 @@ .task\n n\n t\n-r\n+x\n+y\n+r\n+z\n e\n }\n")
        let p0 = DiffSplit.pairs(login.hunks[0].lines)
        await t.equal("문맥 · 쌍 · 문맥", p0.map { [$0.left ?? -1, $0.right ?? -1] }, [[0, 0], [1, 1], [2, 4], [3, 5], [6, 6], [7, 7]])
        let p1 = DiffSplit.pairs(login.hunks[1].lines)
        await t.equal("−1 / +4 → 네 행 · 왼쪽 빈 칸 셋", p1.filter { $0.left == nil }.count, 3)
        await t.equal("더하기만 한 묶음은 왼쪽이 빈 칸",
                      DiffSplit.pairs(file("@@ -1,1 +1,3 @@\n a\n+b\n+c\n").hunks[0].lines).map { $0.left ?? -1 }, [0, -1, -1])
        // 짝이 순서대로가 아니면 짝끼리 같은 행 (목업 LoginView 둘째 hunk: −18 은 +19 와 같은 글자) — 강조한 줄 옆에 엉뚱한 줄이 오지 않게.
        var loginPaired = UnifiedDiff.parse("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -17,3 +17,5 @@\n         .task {\n"
                                            + "-            await viewModel.refresh()\n+            if viewModel.state == .idle {\n"
                                            + "+                await viewModel.refresh()\n+            }\n         }\n")
            .files.first ?? FileDiff()
        WordDiff.annotate(&loginPaired.hunks[0].lines)
        await t.equal("짝 맞춤: 문맥 · 빈칸|+18 · −18|+19 · 빈칸|+20 · 문맥",
                      DiffSplit.pairs(loginPaired.hunks[0].lines).map { [$0.left ?? -1, $0.right ?? -1] },
                      [[0, 0], [-1, 2], [1, 3], [-1, 4], [5, 5]])
        var clearPaired = [DiffLine(kind: .removed, oldNumber: 132, text: "        api.clearSession()"),
                           DiffLine(kind: .added, newNumber: 141, text: "        refreshTask?.cancel()"),
                           DiffLine(kind: .added, newNumber: 142, text: "        transport.clearSession()")]
        WordDiff.annotate(&clearPaired)
        await t.equal("−1/+2 에서 뒤쪽 줄과 짝이면 앞쪽 + 줄은 빈칸과", DiffSplit.pairs(clearPaired).map { [$0.left ?? -1, $0.right ?? -1] },
                      [[-1, 1], [0, 2]])
        let markerPairs = DiffSplit.pairs(file("@@ -1,1 +1,1 @@\n-a\n\\ No newline at end of file\n+a\n").hunks[0].lines)
        await t.equal("지운 줄 뒤 표식은 왼쪽에만", markerPairs.map { [$0.left ?? -1, $0.right ?? -1] }, [[0, 2], [1, -1]])
        let splitRows = DiffRows.build(DiffRows.Input(file: login), mode: .split)
        let hatch = splitRows.filter { if case .split(nil, _) = $0.content { return true }; return false }.count
        await t.equal("나란히 행: 빈 칸(빗금) 3개 · id 모두 다름", [hatch, Set(splitRows.map(\.id)).count == splitRows.count ? 1 : 0], [3, 1])
        if case .split(let left?, let right?) = splitRows.first(where: { if case .split(let l?, _) = $0.content { return l.kind == .removed }; return false })?.content {
            await t.check("나란히 칸은 한쪽 번호만 (왼쪽 옛 · 오른쪽 새)", left.newNumber == nil && left.oldNumber == 26
                          && right.oldNumber == nil && right.newNumber == 26)
        }

        // 코드 줄바꿈 (고정폭 ASCII): 칸 안의 마지막 공백 뒤 · 공백이 없으면 칸에서 · 이어진 공백은 앞 줄 끝에
        func wrap(_ text: String, _ columns: Int) -> [String] {
            let bytes = Array(text.utf8)
            return DiffWrap.asciiLines(bytes, columns: columns).map { String(decoding: bytes[$0], as: UTF8.self) }
        }
        await t.equal("공백 뒤에서 끊음", wrap("abc def ghi", 5), ["abc ", "def ", "ghi"])
        await t.equal("공백 없으면 칸에서 자름", wrap("abcdefghij", 4), ["abcd", "efgh", "ij"])
        await t.equal("칸 끝의 이어진 공백은 앞 줄에", wrap("ab   cd", 2), ["ab   ", "cd"])
        await t.equal("`.` 앞에서도 공백 뒤면 끊음 (CoreText 와 다름)",
                      wrap("            state = .signedOut(reason: .expired)", 47),
                      ["            state = .signedOut(reason: ", ".expired)"])
        await t.equal("짧은 줄 · 빈 줄은 한 줄", [wrap("let a = 1", 40).count, DiffWrap.asciiLines([], columns: 10).count], [1, 1])
        let indented = "                .textFieldStyle(.roundedBorder)"
        await t.equal("들여쓰기 안에서는 끊지 않음 (공백만 남은 첫 줄 없음 · 칸에서 자름)", wrap(indented, 45),
                      ["                .textFieldStyle(.roundedBorde", "r)"])
        let deep = String(repeating: " ", count: 50) + "x = 1"
        await t.check("칸보다 깊은 들여쓰기: 칸에서 자르고 남은 들여쓰기는 다음 줄 · 이으면 원래 줄",
                      wrap(deep, 45) == [String(repeating: " ", count: 45), "     x = 1"] && wrap(deep, 45).joined() == deep,
                      "\(wrap(deep, 45))")
        await t.equal("들여쓰기 뒤의 공백에서는 그대로 끊음", wrap("    foo barbazqux", 10), ["    foo ", "barbazqux"])
        await t.check("끊은 조각을 이으면 원래 줄", wrap(String(repeating: "word ", count: 50) + "end", 13).joined()
                      == String(repeating: "word ", count: 50) + "end")

        // 긴 줄 조각 · 탭 펴기 · 충돌 표시 · 잘림
        let longText = String(repeating: "x", count: 450) + "CHANGED" + String(repeating: "y", count: 443)
        let pieces = DiffRows.cells(DiffCell(kind: .added, oldNumber: nil, newNumber: 7, text: longText, highlights: [450..<457]))
        await t.check("900자 줄 → 400자 조각 셋 · 번호는 첫 조각에만 · 강조는 두 번째 조각 50–57",
                      pieces.count == 3 && pieces[0].newNumber == 7 && pieces[1].newNumber == nil && pieces[1].continuation
                      && pieces[1].highlights == [50..<57] && pieces[0].highlights.isEmpty,
                      "\(pieces.map { $0.highlights })")
        let tabbed = DiffText.expandTabs("\tab\tc", highlights: [1..<3], width: 4)
        await t.check("탭 → 4칸 · 강조 범위도 옮김", tabbed.0 == "    ab  c" && tabbed.1 == [4..<6], "\(tabbed)")
        let conflictFile = file("@@ -1,2 +1,6 @@\n a\n+<<<<<<< HEAD\n+x\n+=======\n+y\n+>>>>>>> other\n b\n")
        let conflictCells = DiffRows.build(DiffRows.Input(file: conflictFile, conflicted: true), mode: .unified)
            .compactMap { row -> DiffCell? in if case .unified(let c) = row.content { return c }; return nil }
        await t.equal("충돌 파일의 충돌 표시 줄", conflictCells.filter(\.conflictMarker).count, 3)
        let notConflict = DiffRows.build(DiffRows.Input(file: conflictFile, conflicted: false), mode: .unified)
            .contains { if case .unified(let c) = $0.content { return c.conflictMarker }; return false }
        await t.check("충돌 파일이 아니면 표시하지 않음", !notConflict)
        let truncated = DiffRows.build(DiffRows.Input(file: f, gaps: gaps, oldLines: oldLines, truncated: true,
                                                      totalLines: 30_000, shownLines: 20_000), mode: .unified)
        if case .end(let text)? = truncated.last?.content {
            await t.check("잘린 diff: 끝에 잘림 안내 · 끝 구간 없음", text.contains("20,000줄만") && text.contains("30,000")
                          && !truncated.contains { if case .gap(2) = $0.id { return true }; return false }, text)
        }
        let states = DiffRows.build(DiffRows.Input(file: f, inclusion: [.on, .off], showInclusion: true), mode: .unified)
            .compactMap { row -> HunkInclusion? in if case .hunk(_, let s) = row.content { return s }; return nil }
        await t.equal("hunk 머리의 포함 상태", states, [.on, .off])
        let hidden = DiffRows.build(DiffRows.Input(file: f, inclusion: [.on, .on], showInclusion: false), mode: .unified)
            .compactMap { row -> HunkInclusion? in if case .hunk(_, let s) = row.content { return s }; return nil }
        await t.check("모두 같으면 머리에 적지 않음", hidden.isEmpty)
    }

    // MARK: 이동 · 크게 보기 · 키

    static func diffNavigation(_ t: TestKit) async {
        await t.group("diff 이동 · 크게 보기 · 키")
        func row(_ path: String, _ inclusion: ChangesState.Inclusion = .off) -> ChangesState.Row {
            ChangesState.Row(path: path, code: inclusion == .conflict ? "U" : "M", inclusion: inclusion)
        }
        let rows = [row("c.swift", .conflict), row("a.swift"), row("b.swift", .on), row("d.swift")]
        let sections = ChangesState.listSections(rows, raised: ["d.swift"], conflictsPresent: true)
        await t.equal("목록에 보이는 순서 (이번 실행 → 충돌 → 그 밖)", ChangesState.visibleOrder(sections),
                      ["d.swift", "c.swift", "a.swift", "b.swift"])
        let order = ["a", "b", "c", "d"]
        await t.equal("2 / 4 · 이전 a · 다음 c", ChangesState.diffPosition(of: "b", in: order),
                      ChangesState.DiffPosition(index: 1, count: 4, previous: "a", next: "c"))
        await t.equal("처음 · 끝에서는 멈춤", [ChangesState.diffPosition(of: "a", in: order).previous,
                                            ChangesState.diffPosition(of: "d", in: order).next], [nil, nil])
        await t.equal("목록(찾기 결과)에 없으면 – / n · 다음은 첫 파일", ChangesState.diffPosition(of: "z", in: order),
                      ChangesState.DiffPosition(index: nil, count: 4, previous: "d", next: "a"))
        await t.equal("크게 보기 순서: 마지막 목록 순서 중 남은 것 + 새 파일",
                      ChangesState.diffOrder(listOrder: ["b.swift", "gone.swift", "a.swift"], rows: rows),
                      ["b.swift", "a.swift", "c.swift", "d.swift"])
        await t.equal("목록이 보이고 지금 상태로 만든 순서면 그대로 (찾기로 걸러진 파일은 넣지 않음)",
                      ChangesState.diffOrder(listOrder: ["b.swift", "a.swift"], rows: rows, listIsCurrent: true),
                      ["b.swift", "a.swift"])
        await t.equal("빠진 파일 → 뒤의 첫 남은 파일", ChangesState.diffReplacement(for: "b", previousOrder: order, present: ["a", "d"]), "d")
        await t.equal("마지막이 빠지면 → 앞쪽", ChangesState.diffReplacement(for: "d", previousOrder: order, present: ["a", "b"]), "b")
        await t.equal("남은 파일이 없으면 nil (목록 · 대화로)",
                      ChangesState.diffReplacement(for: "a", previousOrder: order, present: []), nil as String?)
        await t.check("체크박스를 흐리게 잠그는 잠금",
                      ChangesState.blocksCheckbox(.agentRunning(.claude, here: true)) && ChangesState.blocksCheckbox(.noThread)
                      && !ChangesState.blocksCheckbox(.gitRunning) && !ChangesState.blocksCheckbox(nil))

        // 크게 보기: 되살리지 않는다 · 전적은 한 항목으로 여닫는다 (보기 메뉴 ⇧⌘B · 툴바 ⋯ · 사이드바 아래 단추)
        await t.equal("전적 여닫기: 대화 · 크게 보기 → 전적, 전적 → 대화",
                      [WindowPane.togglingScoreboard(shown: .conversation), WindowPane.togglingScoreboard(shown: .review),
                       WindowPane.togglingScoreboard(shown: .scoreboard)], [.scoreboard, .scoreboard, .conversation])
        await t.equal("에이전트 기록 여닫기의 글 (화면 이름은 '에이전트 기록', 메뉴 표와 같다)",
                      [WindowPane.scoreboardToggleTitle(shown: .conversation), WindowPane.scoreboardToggleTitle(shown: .scoreboard),
                       MenuShortcut.scoreboard.title],
                      ["에이전트 기록", "대화로 돌아가기", "에이전트 기록"])
        await t.equal("저장값 · -window.pane 이 크게 보기면 대화로", WindowPane.restored(WindowPane(rawValue: "크게 보기") ?? .scoreboard),
                      .conversation)
        await t.equal("다른 값은 그대로", WindowPane.restored(.scoreboard), .scoreboard)
        await t.equal("저장값은 식별자 · 옛 한국어 저장값도 읽음",
                      [WindowPane.conversation.rawValue, WindowPane(rawValue: "대화")?.rawValue ?? "",
                       WindowPane(rawValue: "전적")?.rawValue ?? ""],
                      ["conversation", "conversation", "scoreboard"])
        var renamed = ConversationThread(projectID: "p", title: "새 스레드")
        await t.check("자리 표시 제목 판정은 한 곳 (새 스레드 · 새 대화)", renamed.hasPlaceholderTitle
                      && ConversationThread(projectID: "p", title: "새 대화").hasPlaceholderTitle)
        renamed.title = "로그인 오류 문구"
        await t.check("바꾼 제목은 자리 표시가 아님", !renamed.hasPlaceholderTitle)
        await t.equal("이번 실행에서 연 diff 가 있을 때만 크게 보기",
                      [WindowPane.shown(stored: .scoreboard, reviewing: true), WindowPane.shown(stored: .review, reviewing: false)],
                      [.review, .conversation])

        // diff 키: 수식키가 정확히 맞을 때만 · 메뉴 단축키와 겹치지 않음
        await t.equal("esc · ⌥↑ · ⌥↓ · space",
                      [DiffKeyCommand.command(for: .escape, modifiers: []), DiffKeyCommand.command(for: .upArrow, modifiers: [.option]),
                       DiffKeyCommand.command(for: .downArrow, modifiers: [.option]), DiffKeyCommand.command(for: .space, modifiers: [])],
                      [.back, .previousFile, .nextFile, .toggleInclusion])
        await t.check("⌘↑ · ↑ · ⇧space · ⌥⇧↓ · ⌘esc · 다른 키는 받지 않음",
                      DiffKeyCommand.command(for: .upArrow, modifiers: [.command]) == nil
                      && DiffKeyCommand.command(for: .upArrow, modifiers: []) == nil
                      && DiffKeyCommand.command(for: .space, modifiers: [.shift]) == nil
                      && DiffKeyCommand.command(for: .downArrow, modifiers: [.option, .shift]) == nil
                      && DiffKeyCommand.command(for: .escape, modifiers: [.command]) == nil
                      && DiffKeyCommand.command(for: .other, modifiers: []) == nil)
        await t.equal("AppKit 글자 → 키 (화살표 U+F700 · U+F701 · esc 키 코드 53)",
                      [DiffKeyCommand.key(characters: "\u{F700}", keyCode: 126), DiffKeyCommand.key(characters: "\u{F701}", keyCode: 125),
                       DiffKeyCommand.key(characters: " ", keyCode: 49), DiffKeyCommand.key(characters: "", keyCode: 53),
                       DiffKeyCommand.key(characters: "a", keyCode: 0)],
                      [.upArrow, .downArrow, .space, .escape, .other])
        let diffKeys = MenuShortcut.inView.filter { $0.title.hasPrefix("diff") }
        await t.equal("화면 안 단축키 표에 diff 키 넷 (표기)", diffKeys.map(\.symbol), ["esc", "⌥↑", "⌥↓", "space"])
        await t.equal("앱 메뉴 · 기본 메뉴 · 화면 안 단축키 겹침 없음 (diff 키 포함)",
                      MenuShortcut.conflicts(MenuShortcut.appMenu + MenuShortcut.system + MenuShortcut.inView).count, 0)
    }

    // MARK: 실제 저장소

    /// 임시 저장소의 실제 git diff 로 조회 전체: 수정(두 hunk · 펼치기) · 새 파일 · 지운 파일 · 이름 변경 · 이진 · 권한 ·
    /// 일부 포함 · 충돌 · 첫 커밋 전 · 폴더 · 사용자 설정(접두어 · 외부 diff · 색) · 큰 diff 잘림 · 앱 모델의 이동과 복귀.
    @MainActor
    static func diffLiveRepository(_ t: TestKit) async {
        await t.group("파일 diff 조회 · 실제 저장소")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ahc-diff-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        let fresh = root.appendingPathComponent("fresh")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        try? fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        guard let git = GitInspector.findGit(environment: env) else {
            await t.check("git 실행 파일", false, "찾지 못함")
            return
        }
        func sh(_ args: [String], in dir: URL = work) async {
            _ = await CLIEnvironment.captureOutput(
                executable: git, arguments: ["-c", "user.name=t", "-c", "user.email=t@example.com",
                                             "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args,
                environment: env, workingDirectory: dir, timeout: 30)
        }
        func write(_ text: String, _ name: String, in dir: URL = work) {
            let url = dir.appendingPathComponent(name)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        func lines(_ range: ClosedRange<Int>, _ prefix: String = "line") -> String {
            range.map { "\(prefix) \($0)\n" }.joined()
        }
        func document(_ path: String, in dir: URL = work) async -> FileDiffDocument? {
            let status = await GitWorkspace.status(at: dir, environment: env)
            guard let row = ChangesState.rows(from: status).first(where: { $0.path == path }) else { return nil }
            return await GitWorkspace.fileDiff(FileDiffRequest.make(for: row, status: status),
                                               root: URL(fileURLWithPath: status.rootPath ?? dir.path), environment: env)
        }

        await sh(["init", "-q", "-b", "main"], in: work)
        write(lines(1...140), "Auth/AuthViewModel.swift")
        write("a\nb\nc\n", "Legacy.swift")
        write(lines(1...12, "keep"), "old name.txt")
        write("#!/bin/sh\necho hi\n", "run.sh")
        write(lines(1...20, "login"), "LoginView.swift")
        try? Data([0, 1, 2, 3, 0]).write(to: work.appendingPathComponent("bin.dat"))
        await sh(["add", "-A"])
        await sh(["commit", "-q", "-m", "기준"])
        // 사용자 설정이 출력 모양을 흔들어도 조회는 같다 (접두어 없음 · 외부 diff 도구 · 색 항상).
        await sh(["config", "diff.noprefix", "true"])
        await sh(["config", "diff.external", "false"])
        await sh(["config", "color.diff", "always"])

        // 수정: 줄 16 · 줄 85 근처 두 곳 (목업 AuthViewModel 과 같은 모양)
        var authLines = (1...140).map { "line \($0)" }
        authLines[15] = "line sixteen changed"
        authLines.insert("inserted after 84", at: 84)
        write(authLines.joined(separator: "\n") + "\n", "Auth/AuthViewModel.swift")
        let auth = await document("Auth/AuthViewModel.swift")
        await t.check("수정: 본문 · hunk 둘 · 옛 파일 140줄 읽음",
                      auth?.body == .diff && auth?.hunkCount == 2 && auth?.oldLines?.count == 140,
                      "\(String(describing: auth?.body)) hunks \(auth?.hunkCount ?? -1) old \(auth?.oldLines?.count ?? -1)")
        await t.equal("수정: 구간 (앞 12 · 사이 · 끝 52)", auth?.gaps.map { $0.count ?? -1 }, [12, 62, 53])
        await t.check("수정: 목록 체크 off → hunk 전부 off", auth?.inclusion?.states == [.off, .off])
        await t.check("수정: 사용자 설정(noprefix · external · color)에도 경로 · 줄이 그대로",
                      auth?.file?.newPath == "Auth/AuthViewModel.swift"
                      && auth?.file?.hunks.first?.lines.contains { $0.text == "line sixteen changed" } == true
                      && auth?.command.contains("--no-ext-diff") == true)
        let sixteen = auth?.file?.hunks.first?.lines.first { $0.kind == .added }
        let chars = Array(sixteen?.text ?? "")
        await t.equal("수정: 줄 안 강조 (sixteen changed)", sixteen?.highlights.map { String(chars[$0]) }, ["sixteen changed"])

        // 일부 포함: 두 곳 중 첫 곳만 스테이지
        write(lines(1...20, "login").replacingOccurrences(of: "login 3\n", with: "login three\n"), "LoginView.swift")
        await sh(["add", "LoginView.swift"])
        write(lines(1...20, "login").replacingOccurrences(of: "login 3\n", with: "login three\n")
              .replacingOccurrences(of: "login 17\n", with: "login seventeen\n"), "LoginView.swift")
        let login = await document("LoginView.swift")
        await t.check("일부 포함 (MM): hunk 둘 → on · off", login?.inclusion?.states == [.on, .off],
                      "\(String(describing: login?.inclusion))")
        await t.equal("일부 포함 안내", login.flatMap { $0.inclusion.map(DiffInclusion.summary) },
                      "변경 2곳 중 1곳만 이번 커밋에 들어갑니다.")
        await sh(["add", "LoginView.swift"])
        let staged = await document("LoginView.swift")
        await t.check("모두 스테이지 (M ) → 전부 on", staged?.inclusion?.states == [.on, .on])

        // 새 파일 (추적 안 됨) · 빈 새 파일 · 지운 파일 · 이진 · 권한 · 폴더
        write("n1\nn2\n", "New.swift")
        let new = await document("New.swift")
        await t.check("새 파일: --no-index · 새 파일 머리 · 전부 off · 구간 없음",
                      new?.body == .diff && new?.file?.isNewFile == true && new?.inclusion?.states == [.off]
                      && new?.gaps.isEmpty == true && new?.command.contains("--no-index") == true,
                      "\(String(describing: new?.body)) \(new?.command ?? "")")
        write("", "Empty.txt")
        await t.equal("빈 새 파일", await document("Empty.txt")?.body, .noLines("빈 새 파일입니다."))
        try? fm.removeItem(at: work.appendingPathComponent("Legacy.swift"))
        let gone = await document("Legacy.swift")
        await t.check("지운 파일: 삭제 머리 · 지운 줄 셋 · 구간 없음",
                      gone?.file?.isDeleted == true && gone?.file?.removedCount == 3 && gone?.gaps.isEmpty == true)
        try? Data([0, 9, 9, 9, 0]).write(to: work.appendingPathComponent("bin.dat"))
        await t.equal("이진 파일", await document("bin.dat")?.body, .binary)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: work.appendingPathComponent("run.sh").path)
        await t.equal("권한만 바뀜", await document("run.sh")?.body, .noLines("내용은 같고 파일 권한만 바뀌었습니다 (100644 → 100755)."))
        try? fm.createDirectory(at: work.appendingPathComponent("nested"), withIntermediateDirectories: true)
        await sh(["init", "-q", "-b", "main"], in: work.appendingPathComponent("nested"))
        write("x\n", "nested/inside.txt")
        let nestedStatus = await GitWorkspace.status(at: work, environment: env)
        if let nested = ChangesState.rows(from: nestedStatus).first(where: { $0.path.hasPrefix("nested") }) {
            let doc = await GitWorkspace.fileDiff(FileDiffRequest.make(for: nested, status: nestedStatus), root: work, environment: env)
            await t.check("폴더(다른 저장소)는 비교하지 않음", {
                if case .skipped(let text) = doc.body { return text.contains("폴더") }
                return false
            }(), "\(doc.body)")
        }

        // 이름 변경 (스테이지) + 더 고침 → 이름 변경으로 짝짓고, 캐시에만 있는 파일 단위 변경을 적는다
        await sh(["mv", "old name.txt", "new name.txt"])
        write(lines(1...12, "keep") + "more\n", "new name.txt")
        let renamed = await document("new name.txt")
        await t.check("이름 변경: 원래 경로와 짝 · 공백 경로 · 더한 줄은 off · 이름 변경은 스테이지됨",
                      renamed?.file?.isRename == true && renamed?.file?.oldPath == "old name.txt"
                      && renamed?.inclusion?.states == [.off] && renamed?.stagedFileChanges == ["이름 변경"],
                      "\(String(describing: renamed?.file)) \(String(describing: renamed?.inclusion))")

        // 너무 많은 줄: 조회하지 않음 (numstat 기준) · 큰 diff: 앞 20,000줄만
        var skip = FileDiffRequest(path: "New.swift", untracked: true, conflicted: false, inclusion: .off,
                                   noCommitsYet: false, changedLines: FileDiffLimits.skipLines + 1)
        let skipped = await GitWorkspace.fileDiff(skip, root: work, environment: env)
        await t.check("바뀐 줄이 상한을 넘으면 조회하지 않음", { if case .skipped = skipped.body { return true }; return false }())
        write(lines(1...(FileDiffLimits.displayLines + 500), "big"), "Big.txt")
        skip = FileDiffRequest(path: "Big.txt", untracked: true, conflicted: false, inclusion: .off, noCommitsYet: false,
                               changedLines: FileDiffLimits.displayLines + 500)
        let big = await GitWorkspace.fileDiff(skip, root: work, environment: env)
        await t.check("큰 diff: 앞 20,000줄 · 전체 20,500줄 · 잘림",
                      big.truncated && big.shownLines == FileDiffLimits.displayLines && big.totalLines == 20_500,
                      "\(big.shownLines)/\(big.totalLines)")
        // 일부 포함 파일의 diff 가 잘리면 hunk 수 · 뒤쪽 스테이지를 몰라 부분마다의 포함 상태를 적지 않는다
        write(lines(1...21_000, "orig"), "MixedBig.txt")
        await sh(["add", "MixedBig.txt"])
        await sh(["commit", "-q", "-m", "큰 파일", "--", "MixedBig.txt"])
        write(lines(1...21_000, "orig").replacingOccurrences(of: "orig 1\n", with: "first\n"), "MixedBig.txt")
        await sh(["add", "MixedBig.txt"])
        write(lines(1...21_000, "changed"), "MixedBig.txt")
        let mixedBig = await document("MixedBig.txt")
        await t.check("잘린 일부 포함 diff: 포함 상태 없음 · 그 사실 안내 · hunk 머리에 적지 않음",
                      mixedBig?.request.inclusion == .mixed && mixedBig?.truncated == true && mixedBig?.inclusion == nil
                      && mixedBig?.inclusionNote?.contains("잘렸") == true && mixedBig?.showsHunkInclusion == false,
                      "\(String(describing: mixedBig?.request.inclusion)) \(mixedBig?.truncated ?? false) \(mixedBig?.inclusionNote ?? "nil")")

        // 경로는 글자 그대로: ':memo.txt' 를 pathspec 마법(= memo.txt)으로 읽지 않는다
        write("m\n", "memo.txt")
        write("c\n", ":memo.txt")
        await sh(["add", "--", "memo.txt", ":(literal):memo.txt"])
        await sh(["commit", "-q", "-m", "메모", "--", "memo.txt", ":(literal):memo.txt"])
        write("c2\n", ":memo.txt")
        let colon = await document(":memo.txt")
        await t.check("':memo.txt' 는 그 파일의 diff (memo.txt 가 아니라)",
                      colon?.body == .diff && colon?.file?.newPath == ":memo.txt"
                      && colon?.file?.hunks.first?.lines.contains { $0.kind == .added && $0.text == "c2" } == true,
                      "\(String(describing: colon?.body)) \(colon?.file?.newPath ?? "nil")")

        // 심볼릭 링크: 폴더를 가리켜도 폴더가 아니다 — 추적 중이면 git 의 링크 diff, 새 링크는 사실 한 줄
        try? fm.createDirectory(at: work.appendingPathComponent("OtherDir"), withIntermediateDirectories: true)
        write("o\n", "OtherDir/o.txt")
        try? fm.createSymbolicLink(atPath: work.appendingPathComponent("tlink").path, withDestinationPath: "Auth")
        await sh(["add", "--", "OtherDir", "tlink"])
        await sh(["commit", "-q", "-m", "링크", "--", "OtherDir", "tlink"])
        try? fm.removeItem(at: work.appendingPathComponent("tlink"))
        try? fm.createSymbolicLink(atPath: work.appendingPathComponent("tlink").path, withDestinationPath: "OtherDir")
        let tlink = await document("tlink")
        await t.check("추적 중인 링크(폴더를 가리킴)를 바꾸면 링크 대상 글자의 diff (폴더라고 하지 않음)",
                      tlink?.body == .diff && tlink?.file?.hunks.first?.lines.contains { $0.kind == .added && $0.text == "OtherDir" } == true,
                      "\(String(describing: tlink?.body))")
        try? fm.createSymbolicLink(atPath: work.appendingPathComponent("newlink").path, withDestinationPath: "Auth")
        let newLink = await document("newlink")
        await t.check("새 링크(폴더를 가리킴): 폴더가 아니라 링크라고 · 대상", {
            if case .skipped(let text)? = newLink?.body { return text.contains("심볼릭 링크") && text.contains("→ Auth") && !text.contains("폴더라") }
            return false
        }(), "\(String(describing: newLink?.body))")

        // 충돌: 병합 충돌 파일은 diff 를 보이되 포함 상태를 적지 않는다
        let conflict = root.appendingPathComponent("conflict")
        try? fm.createDirectory(at: conflict, withIntermediateDirectories: true)
        await sh(["init", "-q", "-b", "main"], in: conflict)
        write("a\nb\nc\n", "f.txt", in: conflict)
        await sh(["add", "-A"], in: conflict)
        await sh(["commit", "-q", "-m", "base"], in: conflict)
        await sh(["switch", "-q", "-c", "other"], in: conflict)
        write("a\nOTHER\nc\n", "f.txt", in: conflict)
        await sh(["commit", "-q", "-am", "other"], in: conflict)
        await sh(["switch", "-q", "main"], in: conflict)
        write("a\nMAIN\nc\n", "f.txt", in: conflict)
        await sh(["commit", "-q", "-am", "main"], in: conflict)
        await sh(["merge", "-q", "other"], in: conflict)
        let conflicted = await document("f.txt", in: conflict)
        let markers = conflicted?.file.map {
            DiffRows.build(DiffRows.Input(file: $0, conflicted: true), mode: .unified)
                .filter { if case .unified(let c) = $0.content { return c.conflictMarker }; return false }.count
        }
        await t.check("충돌 파일: diff 는 보이고 포함 상태 없음 · 충돌 표시 줄 셋",
                      conflicted?.request.conflicted == true && conflicted?.body == .diff && conflicted?.inclusion == nil
                      && markers == 3 && conflicted?.conflictMarkerLines == 3,
                      "\(String(describing: conflicted?.body)) markers \(markers ?? -1)")
        // 표시를 지우고 저장해도 git add 전까지는 충돌 파일이다 — 그때는 "표시가 남았다" 고 말할 근거(표시 줄)가 없다.
        write("a\nMERGED\nc\n", "f.txt", in: conflict)
        let cleaned = await document("f.txt", in: conflict)
        await t.check("표시를 지운 충돌 파일: 여전히 충돌 · 표시 줄 0",
                      cleaned?.request.conflicted == true && cleaned?.conflictMarkerLines == 0,
                      "\(cleaned?.conflictMarkerLines ?? -1)")

        // 첫 커밋 전: 마지막 커밋이 없어 지금 파일 전체를 새 내용으로 · 스테이지와 대조
        await sh(["init", "-q", "-b", "main"], in: fresh)
        write("hello\n", "first.txt", in: fresh)
        await sh(["add", "first.txt"], in: fresh)
        write("hello\nworld\n", "first.txt", in: fresh)
        let first = await document("first.txt", in: fresh)
        await t.check("첫 커밋 전: 새 내용 두 줄 · 안내 · 첫 줄만 스테이지 → 일부",
                      first?.body == .diff && first?.file?.addedCount == 2 && first?.notes.first?.contains("첫 커밋 전") == true
                      && first?.inclusion?.states == [.partial],
                      "\(String(describing: first?.body)) \(first?.notes ?? []) \(String(describing: first?.inclusion))")

        // 앱 모델: 파일 열기 → 다음 파일 → 커밋으로 빠지면 다음 파일로 → 남은 파일이 없으면 닫기 · 크게 보기 · 폴더를 바꾸면 없음
        let nav = root.appendingPathComponent("nav")
        try? fm.createDirectory(at: nav, withIntermediateDirectories: true)
        await sh(["init", "-q", "-b", "main"], in: nav)
        for name in ["a.txt", "b.txt", "c.txt"] { write("x\n", name, in: nav) }
        await sh(["add", "-A"], in: nav)
        await sh(["commit", "-q", "-m", "base"], in: nav)
        for name in ["a.txt", "b.txt", "c.txt"] { write("x\ny\n", name, in: nav) }
        let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
        guard (try? await store.bootstrap()) != nil else {
            await t.check("임시 DB 준비", false)
            return
        }
        let model = AppModel(store: store)
        // 작업 폴더의 상태는 보고 있는 대화의 프로젝트 것이다 — 프로젝트와 대화를 먼저 둔다.
        let navProject = await model.addProject(name: "nav", path: nav.path)
        _ = await model.addThread(projectID: navProject.id, title: "nav")
        await model.openWorkspace(path: nav.path)
        model.updateChangesListOrder(["a.txt", "b.txt", "c.txt"])
        model.openDiff(path: "b.txt")
        await t.check("열기: 보는 파일 · 키 포커스 요청 한 번", model.activeDiffPath == "b.txt" && model.takeDiffKeyFocus()
                      && !model.takeDiffKeyFocus())
        model.stepDiff(1, order: model.changesListOrder)
        await t.equal("다음 파일 (⌥↓)", model.activeDiffPath, "c.txt")
        model.stepDiff(1, order: model.changesListOrder)
        await t.equal("끝에서는 멈춤", model.activeDiffPath, "c.txt")
        model.setDiffWide(true)
        await t.check("크게 보기 켬", model.diffWideActive)
        await sh(["commit", "-q", "-m", "c 커밋", "--", "c.txt"], in: nav)
        await model.workspace.refreshGit()
        model.reconcileDiffFocus(rows: model.workspace.changeRows(), statusReadable: true)
        await t.check("보던 파일이 커밋으로 빠지면 앞쪽 남은 파일(b) · 안내", model.activeDiffPath == "b.txt"
                      && model.diffNotice?.contains("c.txt") == true, "\(model.activeDiffPath ?? "nil") \(model.diffNotice ?? "")")
        if let bRow = model.workspace.changeRows().first(where: { $0.path == "b.txt" }), let status = model.workspace.git {
            await model.workspace.loadFileDiff(FileDiffRequest.make(for: bRow, status: status))
        }
        await t.check("모델로 읽은 diff 문서 (b.txt)", model.workspace.fileDiffDocument?.request.path == "b.txt"
                      && model.workspace.fileDiffDocument?.body == .diff && model.workspace.fileDiffLoading == nil)
        // b 를 읽어 둔 채 a 를 읽기 시작하고 끝나기 전에 b 로 돌아오면: 늦게 끝난 a 가 b 를 덮지 않는다 (화면이 "읽는 중" 에 멈추지 않게)
        if let status = model.workspace.git,
           let aRow = model.workspace.changeRows().first(where: { $0.path == "a.txt" }),
           let bRow = model.workspace.changeRows().first(where: { $0.path == "b.txt" }) {
            let loadA = Task { await model.workspace.loadFileDiff(FileDiffRequest.make(for: aRow, status: status)) }
            for _ in 0..<200 where model.workspace.fileDiffLoading == nil { await Task.yield() }
            let startedA = model.workspace.fileDiffLoading?.path == "a.txt"
            await model.workspace.loadFileDiff(FileDiffRequest.make(for: bRow, status: status))
            await loadA.value
            await t.check("b 를 읽어 둠 → a 읽는 중 → b 로 돌아옴: 늦은 a 결과는 버림 · 읽는 중 없음",
                          startedA && model.workspace.fileDiffDocument?.request.path == "b.txt"
                          && model.workspace.fileDiffLoading == nil,
                          "started \(startedA) doc \(model.workspace.fileDiffDocument?.request.path ?? "nil")")
            // 빠진 파일을 그리는 한 박자: 옮겨 갈 파일을 미리 고른다 (목록이 비쳤다 사라지지 않게)
            await t.equal("보던 파일이 빠진 직후 그릴 파일 = 옮겨 갈 파일", model.diffShownPath(present: ["a.txt"]), "a.txt")
        }
        await sh(["commit", "-q", "-am", "나머지"], in: nav)
        await model.workspace.refreshGit()
        model.reconcileDiffFocus(rows: model.workspace.changeRows(), statusReadable: true)
        await t.check("남은 파일이 없으면 닫힘 (크게 보기도)", model.activeDiffPath == nil && !model.diffWideActive)
        model.openDiff(path: "a.txt")
        model.setDiffWide(true)
        // 다른 폴더의 대화로 옮긴다 (작업 폴더의 상태는 폴더마다 따로다).
        let workProject = await model.addProject(name: "work", path: work.path)
        _ = await model.addThread(projectID: workProject.id, title: "work")
        await model.openWorkspace(path: work.path)
        await t.check("다른 폴더로 가면 보던 diff 는 없는 것으로 · 문서도 비움",
                      model.activeDiffPath == nil && model.workspace.fileDiffDocument == nil && !model.diffWideActive)
        model.openDiff(path: "New.swift")
        await t.check("다른 폴더의 파일을 열면 좁은 패널로 (앞 폴더의 크게 보기를 이어 쓰지 않음)",
                      model.activeDiffPath == "New.swift" && !model.diffWideActive && model.narrowDiffShown)
        model.closeDiffIfProjectChanged(to: nav.path)
        await t.check("스레드를 골라 폴더가 바뀌면 보던 diff 를 닫음", model.activeDiffPath == nil
                      && model.workspace.projectPath == work.path)

        // 키 포커스 요청은 잠깐만 산다 · 닫으면 버린다 (화면에 diff 가 없을 때 온 요청이 나중에 입력창의 포커스를 빼앗지 않게)
        let t0 = Date()
        model.openDiff(path: "New.swift")
        model.requestDiffKeyFocus(now: t0)
        await t.check("늦게 나타난 diff 는 옛 요청을 받지 않음", !model.takeDiffKeyFocus(now: t0.addingTimeInterval(5)))
        model.requestDiffKeyFocus(now: t0)
        model.closeDiff()
        await t.check("닫으면 요청을 버림", !model.takeDiffKeyFocus(now: t0))
        model.openDiff(path: "New.swift")
        _ = model.takeDiffKeyFocus()
        model.setDiffWide(true)
        _ = model.takeDiffKeyFocus()
        model.setDiffWide(false, focusKeys: false)
        await t.check("인계 · 알림으로 크게 보기를 접으면 키 포커스를 요청하지 않음", !model.takeDiffKeyFocus())

        // 목록 순서가 지금 보이는 목록 그대로인지 (같은 git 상태 · 목록이 보임)
        let readAt = model.workspace.git?.fetchedAt
        model.updateChangesListOrder(["New.swift"], statusReadAt: readAt)
        let current = model.changesListOrderIsCurrent(statusReadAt: readAt)
        model.markChangesListHidden()
        await t.check("목록 순서: 같은 상태면 지금 순서 · 목록이 사라지면 아님",
                      current && !model.changesListOrderIsCurrent(statusReadAt: readAt))
        model.closeDiff()
    }
}
