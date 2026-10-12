import Foundation

// MARK: - 4단계 실행별 변경 파일 (실행 전후 스냅샷 · 카드 · 검토 진입)

extension WorkspaceTests {
    /// 실행 전후 비교의 순수 판정 (`RunFileSnapshot` · `RunFileChanges`): 깨끗 → 바뀜, 이미 바뀜 → 더 바뀜(줄 수 제외),
    /// 바뀜 → 깨끗(되돌림), 새 파일, 삭제, 이진(nil), 변화 없음, HEAD 바뀜, 스냅샷 없음 · 이벤트 payload 왕복 · 문구 ·
    /// 목록 구역(`ChangesState.listSections`) · 스트림 행 · 인계 문서 · Gemini 입력.
    static func runChangesDecisions(_ t: TestKit) async {
        await t.group("실행 전후 비교 판정")
        typealias Entry = RunFileSnapshot.Entry
        let t0 = Date(timeIntervalSince1970: 1_800_000_000), t1 = t0.addingTimeInterval(5)
        func snap(_ entries: [String: Entry], head: String? = "h1") -> RunFileSnapshot {
            RunFileSnapshot(entries: entries, head: head)
        }
        func compare(_ before: [String: Entry], _ after: [String: Entry]) -> RunFileChanges {
            RunFileChanges.compare(runID: "r", before: snap(before), after: snap(after))
        }

        // 깨끗 → 바뀜: 실행 전에 없던 경로는 마지막 커밋 대비 줄 수가 곧 이번 실행의 변경이다.
        let fresh = compare([:], ["a.swift": Entry(code: "M", added: 3, removed: 1, size: 10, modifiedAt: t1)])
        await t.check("깨끗 → 바뀜: 파일 1개 · 줄 수 합산",
                      fresh.compared && fresh.fileCount == 1 && fresh.added == 3 && fresh.removed == 1
                          && fresh.preexisting == 0 && fresh.files.first?.preexisting == false,
                      "\(fresh)")

        // 이미 바뀜 → 더 바뀜: numstat 차이로는 이번 실행의 줄 수를 알 수 없다 → 합산하지 않고 개수만.
        let more = compare(["b.swift": Entry(code: "M", added: 1, removed: 0, size: 10, modifiedAt: t0)],
                           ["b.swift": Entry(code: "M", added: 4, removed: 0, size: 30, modifiedAt: t1)])
        await t.check("이미 바뀜 → 더 바뀜: 바뀐 파일이지만 줄 수 제외",
                      more.fileCount == 1 && more.preexisting == 1 && more.added == nil && more.removed == nil
                          && more.files.first?.added == nil && more.files.first?.preexisting == true,
                      "\(more)")
        await t.check("줄 수 제외를 밝힘", more.notes.contains("실행 전부터 바뀌어 있던 1개는 줄 수 제외"), "\(more.notes)")

        // 섞임: 깨끗했던 파일만 합산한다.
        let mixed = compare(["b.swift": Entry(code: "M", added: 1, removed: 0, size: 10, modifiedAt: t0)],
                            ["b.swift": Entry(code: "M", added: 9, removed: 9, size: 90, modifiedAt: t1),
                             "a.swift": Entry(code: "M", added: 2, removed: 5, size: 3, modifiedAt: t1)])
        await t.check("섞임: 실행 전 깨끗했던 파일만 합산", mixed.fileCount == 2 && mixed.added == 2 && mixed.removed == 5
                          && mixed.preexisting == 1, "\(mixed)")

        // 바뀜 → 깨끗 (에이전트가 되돌림): 사라진 경로도 바뀐 파일이다.
        let reverted = compare(["c.swift": Entry(code: "M", added: 2, removed: 2, size: 5, modifiedAt: t0)], [:])
        await t.check("바뀜 → 깨끗(되돌림)도 바뀐 파일 · 실행 전 코드 · 줄 수 없음",
                      reverted.fileCount == 1 && reverted.files.first?.cleared == true
                          && reverted.files.first?.code == "M" && reverted.added == nil && reverted.preexisting == 1,
                      "\(reverted)")
        await t.equal("되돌린 파일은 목록 위로 올릴 경로에서 뺀다", reverted.reviewPaths, [])
        await t.check("되돌리기만 한 실행은 칩 · 점 없음 (올릴 파일이 없다) · 사라진 수는 셈",
                      !reverted.reviewable(observedCount: 0) && reverted.clearedCount == 1 && reverted.unstoredCount == 0)
        let revertedAndEdited = compare(["c.swift": Entry(code: "M", added: 2, removed: 2, size: 5, modifiedAt: t0)],
                                        ["a.swift": Entry(code: "M", added: 1, removed: 0, size: 3, modifiedAt: t1)])
        await t.check("되돌림 + 편집이면 칩 · 점 · 올릴 경로는 남은 파일만",
                      revertedAndEdited.reviewable(observedCount: 0) && revertedAndEdited.reviewPaths == ["a.swift"]
                          && revertedAndEdited.clearedCount == 1)

        // 새 파일 (untracked, 직접 센 줄 수) · 삭제 (파일이 없어 크기 · 시각 nil).
        let created = compare([:], ["n.txt": Entry(code: "A", added: 4, removed: 0, size: 8, modifiedAt: t1)])
        await t.check("새 파일: 직접 센 줄 수를 합산", created.added == 4 && created.removed == 0 && created.files.first?.code == "A")
        let deleted = compare([:], ["d.txt": Entry(code: "D", added: 0, removed: 5)])
        await t.check("삭제: 지운 줄 수 · 코드 D", deleted.fileCount == 1 && deleted.added == 0 && deleted.removed == 5
                          && deleted.files.first?.code == "D", "\(deleted)")

        // 이진 (줄 수 nil): 합산하지 않고 개수를 밝힌다. 합산할 파일이 하나도 없으면 nil ("—"), 0 을 지어내지 않는다.
        let binary = compare([:], ["img.png": Entry(code: "M", size: 100, modifiedAt: t1),
                                   "a.swift": Entry(code: "M", added: 2, removed: 0, size: 3, modifiedAt: t1)])
        await t.check("이진 파일은 합산하지 않고 개수만", binary.fileCount == 2 && binary.unmeasured == 1
                          && binary.added == 2 && binary.removed == 0, "\(binary)")
        await t.check("줄 수를 모르는 이유는 단정하지 않음 (이진 · 큰 새 파일 · 첫 커밋 전 등)",
                      binary.notes.contains("줄 수를 알 수 없는 파일 1개 (이진, 큰 새 파일, 첫 커밋 전 등)"), "\(binary.notes)")
        let onlyBinary = compare([:], ["img.png": Entry(code: "M", size: 100, modifiedAt: t1)])
        await t.check("합산할 파일이 없으면 줄 수 nil (0 이 아님)",
                      onlyBinary.added == nil && onlyBinary.removed == nil && onlyBinary.unmeasured == 1)
        await t.equal("줄 수 글자: 모르면 —", RunFileChanges.lineText(added: onlyBinary.added, removed: onlyBinary.removed), "—")
        await t.equal("줄 수 글자: 0 · 0 은 ±0", RunFileChanges.lineText(added: 0, removed: 0), "±0")
        await t.equal("줄 수 글자", RunFileChanges.lineText(added: 86, removed: 79), "+86 −79")

        // 변화 없음 · 수정 시각만 바뀜 · 한쪽 줄 수만 못 읽음.
        let same = ["x.swift": Entry(code: "M", added: 1, removed: 1, size: 9, modifiedAt: t0)]
        let unchanged = compare(same, same)
        await t.check("변화 없음: 바뀐 파일 0 · 줄 수 nil · 검토할 것 없음",
                      unchanged.compared && unchanged.fileCount == 0 && unchanged.added == nil
                          && !unchanged.reviewable(observedCount: 0))
        let touched = compare(same, ["x.swift": Entry(code: "M", added: 1, removed: 1, size: 9, modifiedAt: t1)])
        await t.check("수정 시각만 바뀌어도 바뀐 파일 (이미 바뀌어 있던 파일을 다시 씀)",
                      touched.fileCount == 1 && touched.preexisting == 1)
        let unreadable = compare(same, ["x.swift": Entry(code: "M", size: 9, modifiedAt: t0)])
        await t.check("한쪽 줄 수만 못 읽었으면 (코드 · 크기 · 시각 같음) 바뀌지 않은 것으로", unreadable.fileCount == 0)

        // HEAD 바뀜 (실행 중 커밋 · 전환): 커밋된 변경은 보이지 않고 기준이 달라져 줄 수를 합산하지 않는다.
        let committed = RunFileChanges.compare(
            runID: "r", before: snap([:], head: "h1"),
            after: snap(["a.swift": Entry(code: "M", added: 3, removed: 1, size: 10, modifiedAt: t1)], head: "h2"))
        await t.check("HEAD 바뀜: 줄 수 합산 안 함 · 알림", committed.headChanged && committed.added == nil
                          && committed.files.first?.added == nil && committed.fileCount == 1
                          && committed.notes.first?.contains("HEAD") == true, "\(committed)")
        await t.check("HEAD 문구는 원인을 단정하지 않고 사실만", committed.notes.first?.hasPrefix("실행 중 HEAD 가 바뀌어") == true,
                      "\(committed.notes)")
        // 카드는 같은 사실을 짧은 말로 (사람용) — 긴 문장은 이벤트 글 · 인계 문서(받는 에이전트용)에 그대로.
        let both = RunFileChanges.compare(
            runID: "r", before: snap(["b.swift": Entry(code: "M", added: 1, removed: 0, size: 10, modifiedAt: t0)], head: "h1"),
            after: snap(["a.swift": Entry(code: "M", added: 3, removed: 1, size: 10, modifiedAt: t1),
                         "b.swift": Entry(code: "M", added: 4, removed: 0, size: 30, modifiedAt: t1)], head: "h2"))
        await t.equal("카드 주석은 짧은 말", both.cardNotes, ["커밋된 변경은 세지 않음", "줄 수는 실행 전부터 바뀐 1개 제외"])
        await t.check("이벤트 글 · 인계 줄은 긴 문장 그대로 (받는 에이전트용)",
                      both.summaryText.contains("실행 중 HEAD 가 바뀌어") && both.summaryText.contains("실행 전후 비교")
                          && both.packetLine(provider: .claude)?.contains("실행 전부터 바뀌어 있던 1개는 줄 수 제외") == true,
                      both.summaryText)
        let firstCommit = RunFileChanges.compare(runID: "r", before: snap([:], head: nil), after: snap([:], head: "h1"))
        await t.check("첫 커밋이 생긴 것도 HEAD 바뀜", firstCommit.headChanged && firstCommit.fileCount == 0)
        await t.check("바뀐 파일 없음 + HEAD 바뀜은 본문에 밝힘", firstCommit.summaryText.contains("HEAD"),
                      firstCommit.summaryText)
        await t.check("HEAD 가 바뀌고 남은 변경이 없으면 \"바뀐 파일 없음\" 이라고 하지 않음",
                      firstCommit.noChangeHeadline == "커밋하지 않은 변경 없음"
                          && firstCommit.summaryText.hasPrefix("커밋하지 않은 변경이 없습니다")
                          && unchangedHeadline(same: t0) == "이번 실행에서 바뀐 파일 없음",
                      firstCommit.summaryText)
        await t.check("HEAD 만 바뀐 실행도 인계 문서에 관찰로 한 줄",
                      firstCommit.packetLine(provider: .claude).map { $0.contains("커밋하지 않은 변경 없음")
                          && $0.contains("HEAD") } ?? false,
                      firstCommit.packetLine(provider: .claude) ?? "nil")
        // HEAD 를 한쪽이라도 읽지 못함: 바뀌었다고 하지 않고 줄 수만 뺀다 (미확인).
        let unknownHead = RunFileChanges.compare(
            runID: "r", before: snap([:], head: "h1"),
            after: RunFileSnapshot(entries: ["n.swift": Entry(code: "A", added: 2, removed: 0, size: 3, modifiedAt: t1)],
                                   head: nil, headKnown: false))
        await t.check("HEAD 미확인: 바뀜이라 하지 않음 · 줄 수 합산 안 함 · 미확인 알림",
                      !unknownHead.headChanged && unknownHead.headUnknown && unknownHead.added == nil
                          && unknownHead.fileCount == 1 && unknownHead.linesSuppressed
                          && unknownHead.notes.first == "실행 전후 HEAD 를 확인하지 못해 줄 수를 더하지 않았습니다"
                          && !unknownHead.summaryText.contains("HEAD 가 바뀌어"),
                      unknownHead.summaryText)
        let unknownEmpty = RunFileChanges.compare(runID: "r", before: RunFileSnapshot(entries: [:], head: nil, headKnown: false),
                                                  after: snap([:]))
        await t.check("HEAD 미확인 + 남은 변경 없음도 \"커밋하지 않은 변경 없음\"",
                      unknownEmpty.noChangeHeadline == "커밋하지 않은 변경 없음" && !unknownEmpty.headChanged)
        // HEAD 가 바뀌면 기준이 달라 손대지 않은 파일의 줄 수도 달라 보인다 — 코드 · 크기 · 시각이 같으면 바뀌지 않은 것.
        let rebased = RunFileChanges.compare(
            runID: "r", before: snap(["x.swift": Entry(code: "M", added: 1, removed: 1, size: 9, modifiedAt: t0)], head: "h1"),
            after: snap(["x.swift": Entry(code: "M", added: 5, removed: 0, size: 9, modifiedAt: t0)], head: "h2"))
        await t.check("HEAD 바뀜: 줄 수만 달라진 손대지 않은 파일은 바뀐 파일이 아님", rebased.fileCount == 0 && rebased.headChanged)
        await t.check("문구 안에 구분자( · )를 쓰지 않음 (문구끼리 · 로 잇는다)",
                      (committed.notes + unknownHead.notes + more.notes + binary.notes + [RunFileChanges.processNote])
                          .allSatisfy { !$0.contains(" · ") })
        // 프로세스 종료 미확인: 비교 뒤의 변경이 빠졌을 수 있다고 밝힌다.
        var unconfirmed = fresh
        unconfirmed.processUnconfirmed = true
        await t.check("프로세스 종료 미확인: 문구 · 본문 · 인계 줄에 밝힘",
                      unconfirmed.notes.contains(RunFileChanges.processNote)
                          && unconfirmed.summaryText.contains("프로세스 종료 미확인")
                          && (unconfirmed.packetLine(provider: .claude)?.contains("프로세스 종료 미확인") ?? false)
                          && RunFileChanges.decode(unconfirmed.event(threadID: "t", provider: .claude))?.processUnconfirmed == true)

        // 스냅샷 없음 (전 · 후 중 하나라도).
        let noRepo = RunFileChanges.summarize(runID: "r", before: .unavailable(.notRepository),
                                              after: .unavailable(.notRepository))
        await t.check("스냅샷 없음: 비교하지 않음 · 이유 · 줄 수 없음",
                      !noRepo.compared && noRepo.unavailable == .notRepository && noRepo.fileCount == 0
                          && noRepo.added == nil && noRepo.reviewPaths == nil)
        let afterFailed = RunFileChanges.summarize(runID: "r", before: .taken(snap([:])), after: .unavailable(.readFailed))
        let beforeFailed = RunFileChanges.summarize(runID: "r", before: .unavailable(.readFailed), after: .taken(snap([:])))
        await t.check("한쪽만 못 찍어도 비교하지 않음", !afterFailed.compared && afterFailed.unavailable == .readFailed
                          && !beforeFailed.compared && beforeFailed.unavailable == .readFailed)
        await t.check("저장소가 아니면 관찰된 편집이 있어도 칩 · 점 없음 (올릴 목록이 없다)",
                      !noRepo.reviewable(observedCount: 3))
        await t.check("상태를 못 읽었으면 관찰된 편집이 있을 때만 칩 · 점",
                      afterFailed.reviewable(observedCount: 2) && !afterFailed.reviewable(observedCount: 0))
        let timedOut = RunFileChanges.summarize(runID: "r", before: .unavailable(.timedOut), after: .taken(snap([:])))
        await t.check("시간 초과도 비교하지 않음 · 이유 · 관찰된 편집이 있으면 칩",
                      !timedOut.compared && timedOut.unavailable == .timedOut && timedOut.reviewable(observedCount: 1)
                          && timedOut.summaryText.contains("초를 넘김"), timedOut.summaryText)
        await t.check("비교했으면 바뀐 파일이 있을 때 칩 · 점", fresh.reviewable(observedCount: 0))

        // 경로 순 · 이름 요약 · 저장 상한.
        let four = compare([:], ["Moa/Auth/b.swift": Entry(code: "M", added: 1, removed: 0, size: 1, modifiedAt: t1),
                                 "Moa/Auth/a10.swift": Entry(code: "M", added: 1, removed: 0, size: 1, modifiedAt: t1),
                                 "Moa/Auth/a2.swift": Entry(code: "A", added: 1, removed: 0, size: 1, modifiedAt: t1),
                                 "z.swift": Entry(code: "D", added: 0, removed: 1)])
        await t.equal("경로 순 (숫자는 자연 순서)", four.files.map(\.path),
                      ["Moa/Auth/a2.swift", "Moa/Auth/a10.swift", "Moa/Auth/b.swift", "z.swift"])
        let names = RunFileChanges.nameSummary(four.files.map(\.path), total: four.fileCount)
        await t.check("이름은 3개까지 · 나머지는 외 n개", names.names == ["a2.swift", "a10.swift", "b.swift"] && names.more == 1,
                      "\(names)")
        var many: [String: Entry] = [:]
        for i in 0..<(RunFileChanges.storedFileLimit + 20) {
            many["f\(i).txt"] = Entry(code: "A", added: 1, removed: 0, size: 2, modifiedAt: t1)
        }
        let big = compare([:], many)
        await t.check("payload 에는 상한까지만 적고 개수 · 줄 수는 전부 셈",
                      big.files.count == RunFileChanges.storedFileLimit
                          && big.fileCount == RunFileChanges.storedFileLimit + 20
                          && big.added == RunFileChanges.storedFileLimit + 20 && big.unstoredCount == 20)

        // git 상태 → 스냅샷 (행 합치기와 같은 대표 코드 · 줄 수, 파일 속성).
        var status = GitWorkspaceStatus()
        status.isRepository = true
        GitWorkspace.parseStatus("## main\0AM new.swift\0 M mod.swift\0?? u.txt\0 D gone.swift\0", into: &status)
        status.headLineCounts = ["new.swift": GitLineCount(added: 5, removed: 0),
                                 "mod.swift": GitLineCount(added: 2, removed: 1),
                                 "gone.swift": GitLineCount(added: 0, removed: 7)]
        status.untracked[0].added = 3
        status.untracked[0].removed = 0
        status.lastCommit = GitCommitSummary(hash: "abc123", shortHash: "abc", subject: "s", date: nil)
        let read = RunFileSnapshot.read(status) { path in path == "gone.swift" ? (nil, nil) : (7, t0) }
        if case .taken(let s) = read {
            await t.check("스냅샷: 대표 코드 (AM → A) · 줄 수 · 속성",
                          s.entries["new.swift"] == Entry(code: "A", added: 5, removed: 0, size: 7, modifiedAt: t0)
                              && s.entries["mod.swift"] == Entry(code: "M", added: 2, removed: 1, size: 7, modifiedAt: t0)
                              && s.entries["u.txt"] == Entry(code: "A", added: 3, removed: 0, size: 7, modifiedAt: t0)
                              && s.entries["gone.swift"] == Entry(code: "D", added: 0, removed: 7)
                              && s.head == "abc123" && s.entries.count == 4,
                          "\(s)")
        } else {
            await t.check("스냅샷: 저장소 상태를 찍음", false, "\(read)")
        }
        await t.equal("저장소가 아니면 찍지 않음", RunFileSnapshot.read(GitWorkspaceStatus()) { _ in (nil, nil) },
                      .unavailable(.notRepository))
        var broken = GitWorkspaceStatus()
        broken.isRepository = true
        broken.error = "git status 실패"
        await t.equal("상태를 못 읽었으면 찍지 않음 (저장소 아님과 구분)", RunFileSnapshot.read(broken) { _ in (nil, nil) },
                      .unavailable(.readFailed))
        // HEAD 를 확인했는지: 마지막 커밋을 읽었거나 첫 커밋 전이면 확인한 것, 둘 다 아니면 `git log -1` 을 못 읽은 것.
        var noLog = GitWorkspaceStatus()
        noLog.isRepository = true
        var fresh0 = noLog
        fresh0.noCommitsYet = true
        await t.check("스냅샷 HEAD 확인: 커밋 읽음 · 첫 커밋 전은 확인, 못 읽음은 미확인",
                      read.snapshot?.headKnown == true
                          && RunFileSnapshot.read(fresh0) { _ in (nil, nil) }.snapshot?.headKnown == true
                          && RunFileSnapshot.read(noLog) { _ in (nil, nil) }.snapshot?.headKnown == false)

        // 이벤트 payload 왕복 · 다른 안내와 구분.
        let event = fresh.event(threadID: "t", provider: .claude)
        await t.check("이벤트: systemNotice · 그 실행 · 제목", event.kind == .systemNotice && event.runID == "r"
                          && event.title == "실행 전후 비교" && event.provider == .claude)
        await t.equal("payload 왕복", RunFileChanges.decode(event), fresh)
        let payload = JSONUtil.object(event.payloadJSON ?? "") ?? [:]
        await t.check("payload 키 (종류 · runID · files · added · removed · unmeasured · preexisting)",
                      payload["type"] as? String == RunFileChanges.payloadType && payload["runID"] as? String == "r"
                          && (payload["files"] as? [Any])?.count == 1 && JSONUtil.int(payload["added"]) == 3
                          && JSONUtil.int(payload["removed"]) == 1 && payload["unmeasured"] != nil
                          && payload["preexisting"] != nil, event.payloadJSON ?? "")
        let plainNotice = ThreadEvent(threadID: "t", runID: "r", kind: .systemNotice, title: "안내", text: "x",
                                      payloadJSON: #"{"status":"x"}"#)
        await t.check("다른 안내는 요약이 아님", RunFileChanges.decode(plainNotice) == nil
                          && !RunFileChanges.mayBeSummary(plainNotice))
        var orphan = event
        orphan.runID = nil
        await t.check("실행이 없는 안내는 요약으로 읽지 않음", RunFileChanges.decode(orphan) == nil)

        // 이벤트 본문 (Gemini 요약 입력에도 이 글이 들어간다).
        await t.check("본문: 파일 수 · 경로 · 줄 수", fresh.summaryText.contains("파일 1개가 바뀌었습니다")
                          && fresh.summaryText.contains("a.swift") && fresh.summaryText.contains("+3 −1"),
                      fresh.summaryText)
        await t.check("본문: 바뀐 파일 없음", unchanged.summaryText.contains("바뀐 파일이 없습니다"), unchanged.summaryText)
        await t.check("본문: 비교 못 함 · 이유", noRepo.summaryText.contains("하지 못했습니다")
                          && noRepo.summaryText.contains("Git 저장소가 아님"), noRepo.summaryText)
        await t.check("본문: HEAD 바뀜이면 줄 수 —", committed.summaryText.contains("줄 수 —"), committed.summaryText)

        // 목록 구역 — 충돌 → 그 실행의 파일 → 그 밖의 변경.
        func row(_ path: String, conflict: Bool = false) -> ChangesState.Row {
            ChangesState.Row(path: path, code: conflict ? "U" : "M", inclusion: conflict ? .conflict : .off)
        }
        let rows = [row("c.swift", conflict: true), row("a.swift"), row("b.swift"), row("d.swift")]
        let plain = [row("a.swift"), row("b.swift")]
        await t.equal("평소 목록은 구역 없이", ChangesState.listSections(plain, raised: nil).map(\.kind), [.all])
        await t.equal("충돌이 있으면 충돌 · 그 밖의 변경", ChangesState.listSections(rows, raised: nil).map(\.kind),
                      [.conflicts, .others])
        let raisedSections = ChangesState.listSections(rows, raised: ["b.swift", "gone.swift"])
        await t.equal("올리면 그 실행 → 충돌 → 그 밖", raisedSections.map(\.kind), [.thisRun, .conflicts, .others])
        await t.equal("그 실행의 파일", raisedSections[safe: 0]?.rows.map(\.path), ["b.swift"])
        await t.equal("그 밖의 변경은 경로 순 그대로", raisedSections[safe: 2]?.rows.map(\.path), ["a.swift", "d.swift"])
        let runConflict = ChangesState.listSections(rows, raised: ["c.swift", "a.swift"])
        await t.check("그 실행의 충돌 파일은 그 실행 구역에 (충돌 먼저) · 충돌 구역은 없음",
                      runConflict.map(\.kind) == [.thisRun, .others]
                          && runConflict.first?.rows.map(\.path) == ["c.swift", "a.swift"], "\(runConflict)")
        await t.equal("구역 설명: 행 수와 더해 카드의 파일 수가 되게",
                      ChangesState.raisedNotes(conflicts: 1, missing: 2, clearedByRun: 1, unstored: 3),
                      ["그중 충돌 1개", "1개는 그 실행이 되돌리거나 커밋해 목록에서 빠짐",
                       "2개는 그 뒤 커밋 · 되돌림으로 지금 목록에 없음", "외 3개는 경로를 기록하지 않아 올리지 못함"])
        await t.equal("구역 설명: 없으면 비움", ChangesState.raisedNotes(conflicts: 0, missing: 0, clearedByRun: 0, unstored: 0), [])
        // 구역 머리는 "이번 실행" 이 아니라 어느 실행인지 (H9).
        await t.equal("구역 머리: 에이전트 · 시각", ChangesState.runSectionTitle(agent: "Claude", time: "13:05"),
                      "Claude 13:05 실행에서 바뀐 파일")
        await t.equal("구역 머리: 실행을 모르면", ChangesState.runSectionTitle(agent: nil, time: nil), "검토하는 실행에서 바뀐 파일")
        await t.equal("지금 목록에 없는 올린 파일 수", ChangesState.raisedMissing(rows, raised: ["b.swift", "gone.swift"]), 1)
        await t.equal("그 실행의 파일이 하나도 없어도 구역은 둔다 (없음을 밝힌다)",
                      ChangesState.listSections(plain, raised: ["gone.swift"]).map(\.kind), [.thisRun, .others])
        await t.equal("찾기로 충돌 행이 빠져도 구역 머리는 그대로",
                      ChangesState.listSections(plain, raised: nil, conflictsPresent: true).map(\.kind), [.others])

        // 스트림: 요약은 실행 기록 블록에 섞이지 않고 그 실행의 바닥글 바로 위 카드로.
        var r1 = Run(threadID: "t", sessionID: "s", provider: .claude, requestText: "q", state: .completed)
        r1.id = "r1"
        var r2 = Run(threadID: "t", sessionID: "s", provider: .claude, requestText: "q2", state: .completed)
        r2.id = "r2"
        var r3 = Run(threadID: "t", sessionID: "s", provider: .codex, requestText: "q3", state: .failed)
        r3.id = "r3"
        var seq: Int64 = 0
        func e(_ kind: EventKind, _ provider: AgentProvider?, run: String, title: String = "", text: String = "x",
               payload: [String: Any]? = nil) -> ThreadEvent {
            seq += 1
            return ThreadEvent(threadID: "t", runID: run, seq: seq, kind: kind, provider: provider, title: title,
                               text: text, payloadJSON: payload.flatMap { JSONUtil.line($0) })
        }
        func summary(_ changes: RunFileChanges, run: String, provider: AgentProvider) -> ThreadEvent {
            var c = changes
            c.runID = run
            var ev = c.event(threadID: "t", provider: provider)
            seq += 1
            ev.seq = seq
            return ev
        }
        let streamEvents = [
            e(.userMessage, nil, run: "r1"),
            e(.agentMessage, .claude, run: "r1"),
            e(.commandExecution, .claude, run: "r1", payload: ["status": "completed", "exitCode": 0]),
            summary(four, run: "r1", provider: .claude),
            e(.userMessage, nil, run: "r2"),
            e(.toolRequest, .claude, run: "r2", title: "Edit",
              text: #"{"file_path":"/p/src/x.swift","old_string":"a","new_string":"b"}"#),
            e(.agentMessage, .claude, run: "r2"),
            summary(RunFileChanges.notCompared(runID: "r2", reason: .readFailed), run: "r2", provider: .claude),
            e(.userMessage, nil, run: "r3"),
            e(.error, .codex, run: "r3"),
            summary(RunFileChanges.notCompared(runID: "r3", reason: .readFailed), run: "r3", provider: .codex),
        ]
        let streamRows = StreamBuilder.rows(events: streamEvents, runs: ["r1": r1, "r2": r2, "r3": r3], handoffs: [],
                                            projectPath: "/p")
        let kinds = streamRows.map { row -> String in
            switch row {
            case .user: return "user"
            case .agentHeader: return "header"
            case .agentMessage: return "message"
            case .execution: return "exec"
            case .runChanges(let r): return "changes:\(r.runID)"
            case .turnFooter: return "footer"
            case .relay: return "relay"
            case .alert: return "alert"
            case .notice: return "notice"
            }
        }
        await t.equal("행 순서 (카드는 바닥글 바로 위)", kinds,
                      ["user", "header", "message", "exec", "changes:r1", "footer",
                       "user", "header", "exec", "message", "changes:r2", "footer",
                       "user", "header", "alert", "footer"])
        let notes = streamRows.flatMap { row -> [ExecutionEntry] in
            if case .execution(_, let entries) = row { return entries }
            return []
        }.filter { if case .note = $0.kind { return true } else { return false } }
        await t.check("요약 이벤트는 실행 기록 블록에 안내로 섞이지 않음", notes.isEmpty, "\(notes)")
        if case .runChanges(let observed)? = streamRows.first(where: { $0.id == "changes-r2" }) {
            await t.equal("비교 못 한 실행은 그 실행의 편집 기록으로 (관찰된 편집)", observed.observedPaths, ["src/x.swift"])
        } else {
            await t.check("관찰된 편집 카드", false)
        }
        await t.check("비교도 못 하고 편집 기록도 없으면 카드 없음", !streamRows.contains { $0.id == "changes-r3" })
        await t.equal("행 식별자 중복 없음", Set(streamRows.map(\.id)).count, streamRows.count)
        let lonely = StreamBuilder.rows(events: [summary(fresh, run: "r1", provider: .claude)], runs: ["r1": r1],
                                        handoffs: [], projectPath: nil)
        await t.equal("요약만 있는 실행도 머리글 · 카드 · 바닥글", lonely.map(\.id), ["header-r1", "changes-r1", "footer-r1"])

        // 인계 문서 — 비교했고 바뀐 파일이 있는 실행만 "완료한 작업" 에 관찰로. 줄 수에서 뺀 것도 함께.
        let project = Project(name: "p", path: "/p")
        let thread = ConversationThread(projectID: project.id, title: "t")
        var git = GitSnapshot()
        git.isRepository = true
        let packet = HandoffPacketBuilder.build(HandoffPacketBuilder.Input(
            thread: thread, project: project, fromProvider: .claude, toProvider: .codex,
            events: [summary(mixed, run: "r1", provider: .claude), summary(unchanged, run: "r2", provider: .claude),
                     summary(noRepo, run: "r3", provider: .claude)],
            runs: [], lastConfirmedPacket: nil, git: git, baseSeq: seq))
        let lines = packet.completed.filter { $0.contains("실행 전후 비교") }
        await t.equal("인계 문서: 비교한 실행의 바뀐 파일만 한 줄", lines.count, 1)
        await t.check("인계 문서 줄: 누구의 실행 · 파일 수 · 경로 · 관찰 · 줄 수 제외",
                      lines.first.map { $0.hasPrefix("Claude 실행에서 바뀐 파일") && $0.contains("2개")
                          && $0.contains("a.swift") && $0.contains("관찰") && $0.contains("줄 수 제외") } ?? false,
                      lines.first ?? "")
        let gemini = GeminiAssistInputBuilder.build(
            thread: thread, project: project, events: [summary(fresh, run: "r1", provider: .claude)], runs: [],
            previousPacket: nil, rulePacket: packet, git: git)
        await t.check("Gemini 입력에는 요약 본문이 사실 한 줄로", gemini.contains("이번 실행에서 파일 1개가 바뀌었습니다"))
    }

    /// 앞 스냅샷과 같은 스냅샷 (바뀐 파일 없음 · HEAD 그대로) 의 머리 문구.
    private static func unchangedHeadline(same t0: Date) -> String {
        let same = RunFileSnapshot(entries: ["x": RunFileSnapshot.Entry(code: "M", size: 1, modifiedAt: t0)], head: "h1")
        return RunFileChanges.compare(runID: "r", before: same, after: same).noChangeHeadline
    }

    /// 시간 상한: 늦은 작업은 기다리지 않고 nil, 빠른 작업은 값 그대로.
    static func deadlineDecisions(_ t: TestKit) async {
        await t.group("실행 전후 비교 · 시간 상한")
        let fast = await Deadline.run(seconds: 5) { 7 }
        let started = Date()
        let slow = await Deadline.run(seconds: 0.05) { () -> Int in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return 8
        }
        await t.check("빠른 작업은 값", fast == 7)
        await t.check("늦은 작업은 상한에서 nil (끝까지 기다리지 않음)",
                      slow == nil && Date().timeIntervalSince(started) < 1.5)
        // 제시간에 끝난 작업이 취소된 타이머에 밀려 nil(시간 초과)로 바뀌지 않는다 — 경주는 드물게 나므로 여러 번 돌린다.
        var lost = 0
        for i in 0..<20_000 {
            let value = await Deadline.run(seconds: 5) { i }
            if value != i { lost += 1 }
        }
        await t.equal("빠른 작업 20,000번 중 시간 초과로 잘못 끝난 수", lost, 0)
        await t.equal("실행 전후 스냅샷 잠금: 드러내지 않는 잠금 · 문구",
                      ChangesState.lock(agentRunning: false, agent: nil, agentHere: false, hasUnterminated: false,
                                        gitRunning: false, runSnapshot: true, hasThread: true), .runSnapshot)
        await t.check("스냅샷 잠금은 흐리게 하지 않고 버튼만 막음 · 이유 문구",
                      ChangesState.visibleLock(.runSnapshot) == nil
                          && ChangesState.lockText(.runSnapshot, action: "커밋할").hasPrefix("실행 전후 비교로"))
    }

    /// 앱 경로: 실제 임시 저장소에서 `AppModel` 의 시작 전 스냅샷 → (에이전트 대신 파일을 직접 고침) → 종료 뒤 기록.
    /// runner 가 실행을 만들 때 부르는 delegate(`didChangeState(.starting)`)로 실행을 묶는다. 에이전트 CLI 는 부르지 않는다.
    @MainActor
    static func runChangesThroughAppModel(_ t: TestKit) async {
        await t.group("실행 전후 비교 · 앱 경로")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ahc-runchanges-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        let plainDir = root.appendingPathComponent("plain")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        try? fm.createDirectory(at: plainDir, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        guard let git = GitInspector.findGit(environment: env) else {
            await t.check("git 실행 파일", false, "찾지 못함")
            return
        }
        func sh(_ args: [String]) async {
            _ = await CLIEnvironment.captureOutput(
                executable: git, arguments: ["-c", "user.name=t", "-c", "user.email=t@example.com",
                                             "-c", "commit.gpgsign=false"] + args,
                environment: env, workingDirectory: work, timeout: 30)
        }
        func write(_ name: String, _ text: String) {
            try? text.write(to: work.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        await sh(["init", "-q", "-b", "main"])
        await sh(["config", "user.name", "t"])
        await sh(["config", "user.email", "t@example.com"])
        await sh(["config", "commit.gpgsign", "false"])
        write("a.txt", "1\n2\n3\n")
        write("b.txt", "b\n")
        write("pre.txt", "p\n")
        write("keep.txt", "k\n")
        write("gone.txt", "g\n")
        try? Data([0, 1, 2, 3, 0, 9]).write(to: work.appendingPathComponent("bin.dat"))
        await sh(["add", "."])
        await sh(["commit", "-q", "-m", "기준"])
        // 실행 전에 이미 바뀌어 있던 파일 두 개 (하나는 실행이 더 고치고, 하나는 실행이 되돌린다).
        write("b.txt", "b\nB\n")
        write("pre.txt", "p\nP\n")

        let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
        guard (try? await store.bootstrap()) != nil else {
            await t.check("임시 DB 준비", false)
            return
        }
        let model = AppModel(store: store)
        let project = await model.addProject(name: "work", path: work.path)
        let thread = await model.addThread(projectID: project.id, title: "run")
        await model.openWorkspace(path: work.path)
        func summaries(_ threadID: String) async -> [RunFileChanges] {
            ((try? await store.events(threadID: threadID)) ?? []).compactMap(RunFileChanges.decode)
        }
        func makeRun(_ threadID: String) -> Run {
            Run(threadID: threadID, sessionID: "s", provider: .claude, requestText: "편집", state: .starting)
        }

        // 1) 시작 전 스냅샷 (send · deliverHandoff 가 runner 를 부르기 직전과 같은 함수) → runner 가 실행을 만든 순간 묶기.
        let token = await model.beginRunChangeTracking(threadID: thread.id, project: project)
        await t.check("시작 전 스냅샷을 찍음", token != nil)
        var run = makeRun(thread.id)
        model.runCoordinator(model.runner, didChangeState: .starting, run: run)
        // 에이전트 대신 파일을 직접 고친다.
        write("a.txt", "1\nTWO\n3\n4\n")        // 깨끗 → 바뀜 (+2 −1)
        write("new.txt", "n1\nn2\n")            // 새 파일 (+2)
        write("b.txt", "b\nB\nBB\n")            // 이미 바뀜 → 더 바뀜 (줄 수 제외)
        write("pre.txt", "p\n")                  // 이미 바뀜 → 깨끗 (되돌림)
        try? fm.removeItem(at: work.appendingPathComponent("gone.txt"))   // 삭제 (−1)
        try? Data([0, 7, 7, 7, 0, 9, 9]).write(to: work.appendingPathComponent("bin.dat"))   // 이진 (줄 수 모름)
        run.state = .completed
        run.endedAt = Date()
        await model.finishRunChangeTracking(run)

        var recorded = await summaries(thread.id)
        await t.equal("종료 시 요약 이벤트 1건", recorded.count, 1)
        let changes = recorded.first
        await t.equal("바뀐 파일 (경로 순, 손대지 않은 파일 제외)", changes?.files.map(\.path),
                      ["a.txt", "b.txt", "bin.dat", "gone.txt", "new.txt", "pre.txt"])
        await t.check("줄 수는 실행 전 깨끗했던 파일만 (a +2 −1 · new +2 · gone −1)",
                      changes?.added == 4 && changes?.removed == 2, "\(String(describing: changes))")
        await t.check("이미 바뀌어 있던 2개는 줄 수 제외 · 이진 1개는 줄 수 모름",
                      changes?.preexisting == 2 && changes?.unmeasured == 1 && changes?.headChanged == false)
        await t.check("되돌린 파일은 사라진 경로로 (실행 전 코드)",
                      changes?.files.first { $0.path == "pre.txt" }.map { $0.cleared && $0.code == "M" } ?? false)
        await t.check("삭제는 D · 지운 줄 수", changes?.files.first { $0.path == "gone.txt" }.map {
            $0.code == "D" && $0.added == 0 && $0.removed == 1 } ?? false)
        let summaryEvent = ((try? await store.events(threadID: thread.id)) ?? []).first { RunFileChanges.decode($0) != nil }
        await t.check("이벤트는 그 실행의 systemNotice (스키마 변경 없음)",
                      summaryEvent?.kind == .systemNotice && summaryEvent?.runID == run.id
                          && summaryEvent?.provider == .claude)
        await t.check("화면의 이벤트 목록에도 들어감 (선택한 스레드)",
                      model.events.contains { $0.id == summaryEvent?.id })
        await t.check("검토할 파일이 있으면 탭에 점", model.hasUnreviewedChanges(threadID: thread.id))

        await model.finishRunChangeTracking(run)
        recorded = await summaries(thread.id)
        await t.equal("같은 실행으로 다시 불러도 두 번 남기지 않음 (슬롯은 한 번 쓰면 비움)", recorded.count, 1)

        // 2) 시작하지 못한 실행: 찍어 둔 스냅샷을 버린다 → 그 뒤 끝난 실행은 추적하지 않은 실행이라 남기지 않는다.
        let failedStart = await model.beginRunChangeTracking(threadID: thread.id, project: project)
        model.discardRunChangeTracking(failedStart)
        let orphan = makeRun(thread.id)
        model.runCoordinator(model.runner, didChangeState: .starting, run: orphan)
        await model.finishRunChangeTracking(orphan)
        recorded = await summaries(thread.id)
        await t.equal("시작 실패로 버린 스냅샷은 쓰지 않음", recorded.count, 1)

        // 3) 이미 실행에 묶인 스냅샷은 늦게 온 폐기 요청(`deliver` 가 실행을 시작한 뒤 던진 경우)에도 남는다.
        let bound = await model.beginRunChangeTracking(threadID: thread.id, project: project)
        var quiet = makeRun(thread.id)
        model.runCoordinator(model.runner, didChangeState: .starting, run: quiet)
        model.discardRunChangeTracking(bound)
        quiet.state = .completed
        await model.finishRunChangeTracking(quiet)
        recorded = await summaries(thread.id)
        await t.check("묶인 실행은 기록 · 바뀐 파일 없음이면 0개로 (지어내지 않음)",
                      recorded.count == 2 && recorded.last?.runID == quiet.id && recorded.last?.compared == true
                          && recorded.last?.fileCount == 0 && recorded.last?.added == nil,
                      "\(String(describing: recorded.last))")

        // 3-1) 프로세스 종료를 확인하지 못한 실행: 그 사실을 요약에 남긴다.
        _ = await model.beginRunChangeTracking(threadID: thread.id, project: project)
        var stray = makeRun(thread.id)
        model.runCoordinator(model.runner, didChangeState: .starting, run: stray)
        stray.state = .completed
        stray.childProcessNote = "Claude 프로세스(PID 1) 종료를 확인하지 못했습니다."
        await model.finishRunChangeTracking(stray)
        let strayChanges = await summaries(thread.id).last
        await t.check("프로세스 종료 미확인 실행: 요약에 표시",
                      strayChanges?.runID == stray.id && strayChanges?.processUnconfirmed == true
                          && strayChanges?.notes.contains(RunFileChanges.processNote) == true)

        // 4) 실행 중 커밋 (HEAD 바뀜): 커밋된 새 파일은 작업 트리 차이에 없고, 줄 수는 합산하지 않는다.
        _ = await model.beginRunChangeTracking(threadID: thread.id, project: project)
        var committing = makeRun(thread.id)
        model.runCoordinator(model.runner, didChangeState: .starting, run: committing)
        write("c.txt", "c\n")
        await sh(["add", "c.txt"])
        await sh(["commit", "-q", "-m", "에이전트 커밋"])
        write("keep.txt", "k\nK\n")
        committing.state = .completed
        await model.finishRunChangeTracking(committing)
        let headChange = await summaries(thread.id).last
        await t.check("HEAD 바뀜: 알림 · 줄 수 합산 안 함 · 커밋된 파일은 목록에 없음",
                      headChange?.runID == committing.id && headChange?.headChanged == true && headChange?.added == nil
                          && headChange?.files.map(\.path) == ["keep.txt"],
                      "\(String(describing: headChange))")

        // 5) 저장소가 아닌 폴더: 비교하지 못함을 이유와 함께 남기고, 탭 점은 붙이지 않는다 (올릴 목록이 없다).
        let plainProject = await model.addProject(name: "plain", path: plainDir.path)
        let plainThread = await model.addThread(projectID: plainProject.id, title: "plain")
        try? "x\n".write(to: plainDir.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        _ = await model.beginRunChangeTracking(threadID: plainThread.id, project: plainProject)
        var plainRun = makeRun(plainThread.id)
        model.runCoordinator(model.runner, didChangeState: .starting, run: plainRun)
        plainRun.state = .completed
        await model.finishRunChangeTracking(plainRun)
        let plainSummary = await summaries(plainThread.id).first
        await t.check("저장소 아님: 비교 못 함 · 이유 · 줄 수 없음",
                      plainSummary?.compared == false && plainSummary?.unavailable == .notRepository
                          && plainSummary?.added == nil)
        await t.check("저장소 아님: 탭 점 없음", !model.hasUnreviewedChanges(threadID: plainThread.id))

        // 6) 칩 → 검토 요청 (올릴 경로 = 실행 뒤에도 남은 파일) · 점을 뗌. 다른 스레드의 점은 그대로.
        await t.check("스레드별 점: 편집한 스레드에만", model.hasUnreviewedChanges(threadID: thread.id))
        if let changes { model.requestChangesReview(threadID: thread.id, changes: changes) }
        await t.check("검토 요청 → 점이 사라짐", !model.hasUnreviewedChanges(threadID: thread.id))
        await t.equal("올릴 경로 (되돌린 pre.txt 는 빼고)", model.changesReview?.paths,
                      ["a.txt", "b.txt", "bin.dat", "gone.txt", "new.txt"])
        await t.check("검토 요청에 실행 중 목록에서 빠진 수 (pre.txt)",
                      model.changesReview?.clearedByRun == 1 && model.changesReview?.unstored == 0)
        model.clearChangesReview()
        await t.check("원래 순서로 되돌림", model.changesReview == nil)

        // 7) 실제로 남은 이벤트로 만든 스트림 · 인계 초안.
        await model.selectThread(thread.id)
        let rows = StreamBuilder.rows(events: model.events, runs: model.runsByID, handoffs: [], projectPath: work.path)
        await t.check("스트림에 그 실행의 카드", rows.contains { $0.id == "changes-\(run.id)" })
        // 인계는 기록(실행)이 있는 대화만 한다 — 위의 실행들은 저장하지 않은 합성 실행이라 하나를 저장해 둔다.
        try? await store.insertRun(Run(threadID: thread.id, sessionID: "s", provider: .claude, requestText: "편집",
                                       state: .completed, endedAt: Date()))
        await model.prepareHandoff(to: .codex)
        let completed = model.handoffCards[thread.id]?.draft.packet.completed ?? []
        await t.check("인계 초안의 완료한 작업에 실행 전후 비교 한 줄 (관찰)",
                      completed.contains { $0.contains("실행 전후 비교") && $0.contains("a.txt") },
                      completed.joined(separator: " | "))

        // 8) 같은 대화에서 새 실행이 끝나면 검토 구역이 그 실행의 것으로 바뀐다 — 앞 실행에 묶여 "0개 · 지금 목록에 없음" 이 되지 않게 (H9).
        if let changes { model.requestChangesReview(threadID: thread.id, changes: changes) }
        let reviewID = model.changesReview?.id
        _ = await model.beginRunChangeTracking(threadID: thread.id, project: project)
        var next = makeRun(thread.id)
        model.runCoordinator(model.runner, didChangeState: .starting, run: next)
        write("later.txt", "l\n")
        next.state = .completed
        await model.finishRunChangeTracking(next)
        await t.check("새 실행이 끝나면 검토 구역이 그 실행으로 (같은 요청 — 찾기 · 스크롤은 그대로)",
                      model.changesReview?.runID == next.id && model.changesReview?.id == reviewID
                        && model.changesReview?.paths == ["later.txt"], "\(String(describing: model.changesReview))")
        _ = await model.beginRunChangeTracking(threadID: thread.id, project: project)
        var idle = makeRun(thread.id)
        model.runCoordinator(model.runner, didChangeState: .starting, run: idle)
        idle.state = .completed
        await model.finishRunChangeTracking(idle)
        await t.check("검토할 것이 없는 실행이 끝나면 구역을 푼다", model.changesReview == nil)
        await store.db.close()
    }
}

extension WorkspaceTests {
    /// 실행 중 다시 읽기 (H8): 에이전트가 파일을 바꾸면 실행이 끝나기 전에도 변경 목록이 그 파일을 보인다.
    @MainActor
    static func liveRefreshDuringRun(_ t: TestKit) async {
        await t.group("실행 중 변경 목록 다시 읽기")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ahc-liverefresh-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        guard let git = GitInspector.findGit(environment: env) else { return }
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "t"], ["config", "user.email", "t@example.com"],
                     ["config", "commit.gpgsign", "false"]] {
            _ = await CLIEnvironment.captureOutput(executable: git, arguments: args, environment: env,
                                                   workingDirectory: work, timeout: 30)
        }
        try? "a\n".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = await CLIEnvironment.captureOutput(executable: git, arguments: ["add", "."], environment: env,
                                               workingDirectory: work, timeout: 30)
        _ = await CLIEnvironment.captureOutput(executable: git, arguments: ["commit", "-qm", "a"], environment: env,
                                               workingDirectory: work, timeout: 30)
        let store = Store(databaseURL: root.appendingPathComponent("db.sqlite3"))
        guard (try? await store.bootstrap()) != nil else {
            await t.check("임시 DB 준비", false)
            return
        }
        let model = AppModel(store: store)
        final class Holder: @unchecked Sendable { var adapter: ScriptedAgentAdapter? }
        let holder = Holder()
        model.runner.adapterFactory = { provider in
            let adapter = ScriptedAgentAdapter(provider: provider) { request in
                try? "new\n".write(to: request.workingDirectory.appendingPathComponent("made.txt"), atomically: true,
                                   encoding: .utf8)
                return [.emit(.sessionEstablished(sessionID: "s", model: "fake", cliVersion: nil)),
                        .emit(.fileChange(id: "f1", paths: ["made.txt"], diff: nil, status: "completed")),
                        .waitSignal("finish"),
                        .emit(.assistantMessage("ok")),
                        .finish(AgentTurnResult(state: .completed, terminalReason: "completed", sessionID: "s"))]
            }
            holder.adapter = adapter
            return adapter
        }
        let project = await model.addProject(name: "work", path: work.path)
        var thread = await model.addThread(projectID: project.id, title: "live")
        thread.claudeSelection = ModelSelection(model: "sonnet", effort: "high")
        await model.updateThread(thread)
        await model.selectThread(thread.id)
        await model.openWorkspace(path: work.path)
        await t.check("실행 전: 바뀐 파일 없음", model.workspace.git?.untracked.isEmpty == true)
        _ = await model.send("파일을 만들어", provider: .claude, threadID: thread.id)
        var seen = false
        for _ in 0..<400 {
            if model.workspace.git?.untracked.contains(where: { $0.path == "made.txt" }) == true { seen = true; break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await t.check("실행이 도는 동안 새 파일이 목록에 보인다", seen && model.runner.isBusy(threadID: thread.id),
                      "\(String(describing: model.workspace.git?.untracked.map(\.path)))")
        holder.adapter?.signal("finish")
        for _ in 0..<500 where model.runner.session(threadID: thread.id) != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await store.db.close()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
