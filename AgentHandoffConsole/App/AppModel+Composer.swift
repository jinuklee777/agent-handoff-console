import Foundation

/// 입력창 쪽 동작: 승인 방식(자동 승인), 실행 중에 걸어 둔 메시지(대기열)와 인계 카드가 있는 동안의 보류(C2), 붙인 이미지.
/// 저장 속성(`autoApprovalThreadIDs` · `messageQueues` · `queuePauseReasons` · `queueHolds` · `composerAttachments`)은 `AppModel` 본체에 있다.
extension AppModel {

    // MARK: - 자동 승인

    func isAutoApproving(threadID: String) -> Bool { autoApprovalThreadIDs.contains(threadID) }

    /// 대화의 승인 방식을 바꾼다. 실행 도중에도 곧바로 맞는다 — 실행은 요청마다 이 값을 보고(`RunSession.shouldAutoApprove`),
    /// 켜는 순간 떠 있던 승인 카드도 허용한다.
    func setAutoApproval(_ on: Bool, threadID: String) async {
        if on { autoApprovalThreadIDs.insert(threadID) } else { autoApprovalThreadIDs.remove(threadID) }
        if on, let session = runner.session(threadID: threadID) { await session.approvePendingAutomatically() }
    }

    /// 입력창의 에이전트를 다른 에이전트(제공자)로 바꿨다 ("맥락 없이 바꾸기" · 기록 없는 대화의 에이전트 고르기) — 자동 승인을 끄고
    /// 대화에 한 줄 남긴다. 인계로 받는 에이전트가 바뀔 때와 같은 규칙이다 (다른 회사 에이전트가 모든 승인을 받은 채 돌지 않게, chat-18).
    /// 같은 제공자의 다른 계정은 그대로 둔다.
    func turnOffAutoApprovalForAgentChange(threadID: String, from: AgentProvider, to: AgentProvider) async {
        guard from != to, isAutoApproving(threadID: threadID) else { return }
        await setAutoApproval(false, threadID: threadID)
        let notice = ThreadEvent(threadID: threadID, kind: .systemNotice, provider: nil, title: "자동 승인을 껐습니다",
                                 text: "에이전트를 바꿨습니다 (\(from.displayName) → \(to.displayName)). "
                                    + "다시 켜려면 입력창의 승인 방식에서 고르세요.")
        if let saved = try? await store.appendEvent(notice) { runCoordinator(runner, didUpsert: saved) }
    }

    // MARK: - 대기열

    func queuedMessages(threadID: String) -> [QueuedMessage] { messageQueues[threadID] ?? [] }

    /// 실행 중에 보낸 메시지를 건다. 그 대화의 실행이 정상으로 끝나면 차례로 보낸다. 인계 카드가 있으면(보류) 인계가 확인된 뒤
    /// 받는 쪽에게 간다 — 사람이 입력창에서 다음 일을 걸었으니 카운트다운은 멈춘다. 입력창에서 보낸 메시지가 아직 시작되지 않았으면
    /// (`sendingThreads`) 그 실행 뒤에 간다 — 그 보내기가 실패하면 대기열은 멈춘다.
    func enqueueMessage(_ text: String, images: [ImageAttachment], threadID: String) {
        messageQueues[threadID, default: []].append(QueuedMessage(text: text, images: images))
        replyConfirmations[threadID] = nil
        threadStates[threadID]?.requestScrollToBottom()
        pauseCountdown(threadID: threadID)
        // 거는 사이 실행이 끝났다면 기다릴 실행이 없다 — 곧바로 보낸다.
        if !runner.isBusy(threadID: threadID), !isStartingRun(threadID: threadID), !isSending(threadID: threadID),
           queuePauseReasons[threadID] == nil, queueHolds[threadID] == nil {
            Task { await dispatchQueue(threadID: threadID) }
        }
    }

    /// 승인 · 질문 카드가 떠 있는 동안 입력창에 쓴 답 같은 글(y · 1 …)은 걸기 전에 한 번 확인한다 — 걸어 두면 실행이 끝난 뒤 새 지시로
    /// 간다 (chat-4). 확인을 받아야 하면 그 대화의 안내(입력창 위)에 적고 true — 같은 글로 ↵ 를 한 번 더 누르면 건다.
    func needsReplyConfirmation(_ text: String, threadID: String, now: Date = Date()) -> Bool {
        guard let session = runner.session(threadID: threadID),
              !session.pendingApprovals.isEmpty || !session.pendingQuestions.isEmpty,
              QueueRules.looksLikeDecisionReply(text) else { return false }
        if let asked = replyConfirmations[threadID], asked.text == text,
           now.timeIntervalSince(asked.at) <= QueueRules.replyConfirmWindow {
            replyConfirmations[threadID] = nil
            if banner?.threadID == threadID { banner = nil }
            return false
        }
        replyConfirmations[threadID] = (text, now)
        let card = session.pendingQuestions.isEmpty ? "승인 카드" : "질문 카드"
        banner = BannerMessage(text: "아직 걸지 않았습니다: ‘\(text)’. \(card)에 답하려면 대화 끝의 \(card) 단추를 누르세요. "
                                   + "이 글을 실행이 끝난 뒤 보낼 메시지로 걸려면 ↵ 를 한 번 더 누르세요.",
                               isError: false, threadID: threadID)
        return true
    }

    /// 대기열에서 뺀다 — 몇 초 동안 되돌릴 수 있다 (`undoQueueRemoval`).
    func removeQueuedMessage(_ id: String, threadID: String) {
        guard let index = messageQueues[threadID]?.firstIndex(where: { $0.id == id }),
              let message = messageQueues[threadID]?[index] else { return }
        let pause = queuePauseReasons[threadID]
        dropQueuedMessage(id, threadID: threadID)
        removedQueuedMessages[threadID] = RemovedQueuedMessage(message: message, index: index, pauseReason: pause)
    }

    /// 막 뺀 메시지를 제자리에 되돌린다 (멈춰 있었으면 멈춘 채로).
    func undoQueueRemoval(threadID: String) {
        guard let removed = removedQueuedMessages.removeValue(forKey: threadID) else { return }
        var queue = messageQueues[threadID] ?? []
        queue.insert(removed.message, at: min(removed.index, queue.count))
        messageQueues[threadID] = queue
        if queuePauseReasons[threadID] == nil, let reason = removed.pauseReason { queuePauseReasons[threadID] = reason }
        // 그 사이 실행이 끝나 기다릴 실행이 없다 — 저절로 보내지 않고 멈춘 채로 두어 [이어서 보내기] 를 보인다 (conv-5: 단추 없이
        // 다음 실행이 끝날 때까지 남았다). 되돌리기가 에이전트를 새로 돌리지 않게.
        if queuePauseReasons[threadID] == nil, queueHolds[threadID] == nil, !runner.isBusy(threadID: threadID),
           !isStartingRun(threadID: threadID), !isSending(threadID: threadID) {
            queuePauseReasons[threadID] = QueueRules.restoredAfterRunPause
        }
    }

    /// 되돌릴 시간이 지났다 (그 사이 다른 것을 뺐으면 그것은 두고).
    func expireQueueRemoval(threadID: String, messageID: String) {
        if removedQueuedMessages[threadID]?.message.id == messageID { removedQueuedMessages[threadID] = nil }
    }

    private func dropQueuedMessage(_ id: String, threadID: String) {
        var queue = messageQueues[threadID] ?? []
        queue.removeAll { $0.id == id }
        messageQueues[threadID] = queue.isEmpty ? nil : queue
        if queue.isEmpty { queuePauseReasons[threadID] = nil }
    }

    /// 걸어 둔 메시지를 입력창으로 되돌린다 (고쳐서 다시 보내게). 입력창에 글이 있으면 그 뒤에 잇는다 — 묻는 것은 화면이 먼저 한다
    /// (`ComposerQueueList`). 붙인 이미지가 한 메시지의 상한을 넘으면 되돌리지 않고 안내한다. 되돌렸으면 true.
    @discardableResult
    func editQueuedMessage(_ id: String, threadID: String) -> Bool {
        guard let message = messageQueues[threadID]?.first(where: { $0.id == id }) else { return false }
        if QueueRules.editExceedsImageLimit(current: attachments(threadID: threadID).count, adding: message.images.count,
                                            limit: Self.maxAttachments) {
            banner = BannerMessage(text: "입력창에 붙인 이미지와 합치면 \(Self.maxAttachments)장을 넘어 되돌리지 않았습니다. "
                                       + "입력창의 이미지를 줄인 뒤 다시 고치세요.", isError: false, threadID: threadID)
            return false
        }
        dropQueuedMessage(id, threadID: threadID)
        let draft = composerDraft(for: threadID)
        updateComposerDraft(draft.isEmpty ? message.text : draft + "\n" + message.text, for: threadID)
        composerAttachments[threadID, default: []].append(contentsOf: message.images)
        return true
    }

    /// 메인 턴을 마치고 백그라운드 작업을 기다리는 실행 때문에 대기열이 나가지 않는다 — 그 실행을 멈추고(백그라운드 작업도 함께 멈춘다)
    /// 걸어 둔 메시지를 보낸다 (chat-22). 멈춘 실행은 끝 상태가 "취소" 여도 대기열을 멈추지 않는다 (`continueQueue`).
    func stopAndSendQueue(threadID: String) async {
        guard let session = runner.session(threadID: threadID), let runID = session.activeRun?.id,
              !(messageQueues[threadID]?.isEmpty ?? true) else { return }
        queueSendAfterStop[threadID] = runID
        queuePauseReasons[threadID] = nil
        await runner.interrupt(threadID: threadID)
    }

    /// 멈춘 대기열을 이어 보낸다 (실행이 없으면 곧바로 첫 메시지를). 보류 중이면(인계 카드) 보내지 않는다.
    func resumeQueue(threadID: String) async {
        guard queueHolds[threadID] == nil else { return }
        queuePauseReasons[threadID] = nil
        await dispatchQueue(threadID: threadID)
    }

    /// 대화의 실행이 끝났다 (`runCoordinator(_:didFinish:…)`): 정상으로 끝났으면 다음 메시지를 보내고, 아니면 멈춘다 —
    /// 실패 · 중단 · 한도 뒤에 걸어 둔 말을 그대로 이어 보내면 사람이 바꾸려던 흐름과 어긋날 수 있다.
    func continueQueue(after run: Run, state: RunState) async {
        let threadID = run.threadID
        // "멈추고 보내기" 로 멈춘 실행이면 끝 상태와 상관없이 이어 보낸다.
        let stoppedToSend = queueSendAfterStop[threadID] == run.id
        if stoppedToSend { queueSendAfterStop[threadID] = nil }
        // 보류 중이면(인계 카드 · 전달 실패 · 미확인) 그대로 둔다 — 멈춤 이유도 쓰지 않는다 (보류가 풀릴 때 정한다).
        guard !(messageQueues[threadID]?.isEmpty ?? true), queueHolds[threadID] == nil else { return }
        guard state == .completed || stoppedToSend else {
            queuePauseReasons[threadID] = QueueRules.pauseReason(after: state)
            return
        }
        await dispatchQueue(threadID: threadID)
    }

    /// 대기열의 첫 메시지를 보낸다. 멈췄거나 이 대화에 실행이 있으면 아무것도 하지 않는다. 보내지 못하면 되돌려 두고 멈춘다.
    func dispatchQueue(threadID: String) async {
        // 끝난 실행이 관리자 목록에서 빠지기 전일 수 있다 — 잠깐 기다린다 (보내기는 같은 대화의 실행이 남아 있으면 받지 않는다).
        for _ in 0..<40 where runner.session(threadID: threadID).map({ !$0.isBusy }) ?? false {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard queuePauseReasons[threadID] == nil, queueHolds[threadID] == nil, var queue = messageQueues[threadID], !queue.isEmpty,
              runner.session(threadID: threadID) == nil, !isStartingRun(threadID: threadID), !isSending(threadID: threadID),
              let thread = allThreads().first(where: { $0.id == threadID }) else { return }
        let next = queue.removeFirst()
        messageQueues[threadID] = queue.isEmpty ? nil : queue
        threadStates[threadID]?.requestScrollToBottom()
        let sent = await send(next.text, provider: thread.preferredProvider, threadID: threadID, images: next.images)
        if !sent {
            messageQueues[threadID, default: []].insert(next, at: 0)
            queuePauseReasons[threadID] = "보내지 못했습니다 — 입력창 위의 안내를 확인하고 다시 보내세요"
        }
    }

    // MARK: - 인계 보류 (C2)

    /// 인계 준비를 시작할 때 건다: 그 대화의 대기열은 인계가 확인될 때까지 보내지 않는다. 이미 걸어 둔 메시지(한도로 멈춘 것 포함)도
    /// 보류 아래로 옮긴다 — 멈춤 이유를 지운다 (인계가 확인되면 받는 쪽에게 이어서 간다).
    func holdQueue(threadID: String, source: HandoffSource.Agent, target: HandoffSource.Agent) {
        queueHolds[threadID] = QueueHold(source: source, target: target)
        queuePauseReasons[threadID] = nil
    }

    /// 보류를 푼다. 전달이 확인됐으면 아무것도 멈추지 않는다 (실행의 끝이 `continueQueue` 로 받는 쪽에게 보낸다).
    /// 그 밖(취소 · 미확인 카드 닫기 · 준비 실패)은 남은 메시지를 멈춤 이유와 함께 둔다 — 이어서 보내면 지금 칩에게 맥락 없이 간다.
    /// "맥락 없이" 는 지금 칩이 보내는 쪽(이 대화에서 일한 에이전트 · 계정)이 아닐 때만 붙인다 — 칩만 바꾼 뒤 연 카드를 취소하면
    /// 칩은 맥락이 없다, 보내는 쪽 그대로면 자기 세션을 이어 간다.
    func releaseHold(threadID: String, _ release: QueueHoldRelease) {
        guard let hold = queueHolds[threadID] else { return }
        queueHolds[threadID] = nil
        let chipHasContext = paneThread(threadID).map { chipAgent(for: $0) == normalizedHandoffAgent(hold.source) } ?? false
        guard !(messageQueues[threadID]?.isEmpty ?? true),
              let reason = HandoffCardText.pauseReason(release, chip: chipName(threadID: threadID),
                                                       chipHasContext: chipHasContext) else { return }
        queuePauseReasons[threadID] = reason
    }

    /// 앱을 켤 때: 남은 대기열은 멈춘 채로 둔다 — 사람이 보고 이어서 보낸다. 인계 카드 때문에 보류였던 대기열은 카드가 사라졌다고
    /// (이어서 보내면 지금 칩에게 맥락 없이 간다) 적는다. 대화 목록을 읽은 뒤에 부른다 (칩 이름).
    func restoreMessageQueues() async {
        if let v = try? await store.setting("message_queue"), let data = v.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: [QueuedMessage]].self, from: data) {
            messageQueues = decoded.filter { !$0.value.isEmpty }
        }
        let held = Set((try? await store.setting("message_queue_holds")).flatMap { $0 }?.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
        for id in messageQueues.keys {
            guard held.contains(id) else {
                queuePauseReasons[id] = "앱을 다시 켜서 멈췄습니다"
                continue
            }
            // 칩에게 이 대화에서 이어 갈 세션이 있으면 "맥락 없이" 가 아니다 (보내는 쪽 그대로면 자기 세션을 재개한다).
            var resumable = false
            if let chip = paneThread(id).map(chipAgent(for:)) {
                resumable = await resumableAgentKeys(threadID: id, agents: [chip]).contains(chip.key)
            }
            queuePauseReasons[id] = HandoffCardText.relaunchPauseReason(chip: chipName(threadID: id), chipHasContext: resumable)
        }
        // 이번 실행에는 카드가 없다 — 남은 보류 표시를 지운다.
        if !held.isEmpty, queueHolds.isEmpty { persistSetting("message_queue_holds", "[]") }
    }

    // MARK: - 붙인 이미지

    /// 한 메시지에 붙이는 이미지 수의 상한.
    static let maxAttachments = 10

    func attachments(threadID: String) -> [ImageAttachment] { composerAttachments[threadID] ?? [] }

    /// 파일 · 붙여넣은 이미지 데이터를 가져와 입력창에 붙인다 (줄이고 저장하는 일은 뒤에서). 못 읽은 것은 안내한다.
    /// 파일은 **지금** 읽어 둔다 — 화면 캡처 썸네일을 끌어 놓으면 그 임시 파일은 놓자마자 지워질 수 있다.
    func attachImages(files requestedFiles: [URL] = [], data requestedData: [Data] = [], names: [String] = [],
                      threadID: String) {
        let room = max(0, Self.maxAttachments - attachments(threadID: threadID).count - (importingAttachments[threadID] ?? 0))
        let files = Array(requestedFiles.prefix(room))
        let data = Array(requestedData.prefix(room - files.count))
        let count = files.count + data.count
        if count < requestedFiles.count + requestedData.count {
            banner = BannerMessage(text: "이미지는 한 메시지에 \(Self.maxAttachments)장까지 붙일 수 있습니다.",
                                   isError: false, threadID: threadID)
        }
        guard count > 0 else { return }
        let read: [(data: Data?, name: String)] = files.map { url in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            return ((try? Data(contentsOf: url)), url.lastPathComponent)
        } + data.enumerated().map { index, bytes in (bytes, index < names.count ? names[index] : "붙여넣은 이미지") }
        importingAttachments[threadID, default: 0] += count
        let folder = attachmentsDirectory
        Task {
            let results: [Result<ImageAttachment, Error>] = await Task.detached(priority: .userInitiated) {
                read.map { item in
                    Result {
                        guard let bytes = item.data else { throw ImageAttachments.ImportError.unreadable(item.name) }
                        return try ImageAttachments.importData(bytes, name: item.name, into: folder)
                    }
                }
            }.value
            let left = (importingAttachments[threadID] ?? count) - count
            importingAttachments[threadID] = left > 0 ? left : nil
            var failure: String?
            for result in results {
                switch result {
                case .success(let image): composerAttachments[threadID, default: []].append(image)
                case .failure(let error): failure = failure ?? error.localizedDescription
                }
            }
            if let failure { banner = BannerMessage(text: failure, isError: true, threadID: threadID) }
        }
    }

    /// 입력창에서 뺀다 — 파일은 그대로 (보내기도 이 길로 입력창을 비운다 — 그 이미지는 곧 메시지가 쓴다).
    func removeAttachment(_ id: String, threadID: String) {
        var list = composerAttachments[threadID] ?? []
        list.removeAll { $0.id == id }
        composerAttachments[threadID] = list.isEmpty ? nil : list
    }

    /// 사람이 입력창의 이미지를 뺐다 (썸네일의 ×): 입력창에서 빼고, 이제 아무 데서도 쓰지 않으면 파일도 뒤에서 지운다
    /// (`removeOrphanedAttachments` — 보낸 메시지 · 대기열이 쓰는 파일은 남는다). 보내기가 입력창을 비우는 길은 `removeAttachment`.
    func discardAttachment(_ id: String, threadID: String) {
        let dropped = Set((composerAttachments[threadID] ?? []).filter { $0.id == id }.map(\.path))
        removeAttachment(id, threadID: threadID)
        removeOrphanedAttachments(dropped, deletedThreadIDs: [])
    }

    func clearAttachments(threadID: String) { composerAttachments[threadID] = nil }

    /// 입력창 글 끝에 덧붙인다 (끌어 놓은 이미지 아닌 파일의 경로 — 글 칸에 놓았을 때처럼). 앞 글과는 빈칸 하나로 띄운다.
    func appendToComposerDraft(_ text: String, threadID: String) {
        let draft = composerDraft(for: threadID)
        let separator = draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") ? "" : " "
        updateComposerDraft(draft + separator + text, for: threadID)
    }

    /// 보내지 못한 메시지의 이미지를 입력창에 되돌린다 (앞에, 이미 있는 것과 상한은 빼고).
    func restoreAttachments(_ images: [ImageAttachment], threadID: String) {
        let current = composerAttachments[threadID] ?? []
        let back = images.filter { image in !current.contains { $0.id == image.id } }
        let merged = Array((back + current).prefix(Self.maxAttachments))
        composerAttachments[threadID] = merged.isEmpty ? nil : merged
    }

    /// 앱을 켤 때: 입력창에 붙여 두었던 이미지를 되살린다 — 글 초안처럼 (chat-8). 파일이 남아 있는 것만, 지금 있는 대화의 것만.
    /// 되살린 뒤부터 바뀔 때마다 저장한다 (`composerAttachments` 의 didSet).
    func restoreComposerAttachments() async {
        defer { composerAttachmentsRestored = true }
        guard let raw = (try? await store.setting("composer_attachments")).flatMap({ $0 })?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: [ImageAttachment]].self, from: raw) else { return }
        let threads = Set(allThreads().map(\.id))
        var restored: [String: [ImageAttachment]] = [:]
        for (threadID, images) in decoded where threads.contains(threadID) {
            let kept = images.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !kept.isEmpty { restored[threadID] = Array(kept.prefix(Self.maxAttachments)) }
        }
        composerAttachments = restored
        // 사라진 것을 빼고 다시 적는다 (되살리기 전이라 didSet 은 저장하지 않았다).
        if restored != decoded { persistSetting("composer_attachments", Self.jsonString(restored)) }
    }

    // MARK: - 지운 대화의 이미지 파일

    /// 지우려는 대화들의 메모리에 있는 이미지 경로: 입력창 첨부 · 대기열 · 막 뺀 대기열 메시지 · 인계 카드의 덧붙일 말로 옮긴 메시지.
    /// 그 대화의 상태를 치우기 **전에** 부른다. 메시지에 붙은 이미지는 `Store.imageAttachmentPaths` 로 따로 읽는다 (지우기 전에).
    func pendingAttachmentPaths(threadIDs: [String]) -> Set<String> {
        var paths: Set<String> = []
        for id in threadIDs {
            paths.formUnion((composerAttachments[id] ?? []).map(\.path))
            var messages: [QueuedMessage] = messageQueues[id] ?? []
            if let removed = removedQueuedMessages[id] { messages.append(removed.message) }
            messages += handoffCards[id]?.movedMessages ?? []
            for message in messages { paths.formUnion(message.images.map(\.path)) }
        }
        return paths
    }

    /// 대화를 지운 뒤(DB 에서 지워진 뒤에만 부른다) · 사람이 입력창의 이미지를 뺀 뒤(`discardAttachment`): 그 이미지 파일
    /// (`candidates`) 가운데 이제 아무 데서도 쓰지 않는 것을 뒤에서 지운다 — 최선 노력, 화면을 기다리게 하지 않는다. 쓰는지는
    /// `referencedAttachmentPaths` 로 보고, 지우는 것은 첨부 폴더(`attachmentsDirectory`) 바로 아래의 이미지 파일뿐이다
    /// (`ImageAttachments.removeUnreferenced`). 앞의 지우기가 끝난 뒤에 돈다 (`attachmentCleanup`).
    @discardableResult
    func removeOrphanedAttachments(_ candidates: Set<String>, deletedThreadIDs: Set<String>) -> Task<Void, Never>? {
        guard !candidates.isEmpty else { return nil }
        let previous = attachmentCleanup
        let folder = attachmentsDirectory
        let task = Task {
            await previous?.value
            guard let referenced = await referencedAttachmentPaths(excluding: deletedThreadIDs) else { return }
            _ = await Task.detached(priority: .utility) {
                ImageAttachments.removeUnreferenced(candidates, keeping: referenced, in: folder)
            }.value
        }
        attachmentCleanup = task
        return task
    }

    /// 지금 쓰는 이미지 경로 전부: 남은 대화의 메시지 · 저장된 입력창 첨부(설정 `composer_attachments`) · 저장된 대기열
    /// (`message_queue`) — 지운 대화(`deleted`)의 저장된 몫은 뺀다 — · 메모리의 입력창 첨부 · 대기열 · 막 뺀 대기열 메시지 ·
    /// 보내는 중인 메시지 · 인계 카드로 옮긴 메시지. 하나라도 읽지 못하면 nil — 아무것도 지우지 않는다.
    func referencedAttachmentPaths(excluding deleted: Set<String>) async -> Set<String>? {
        var paths: Set<String>
        let savedComposer: String?
        let savedQueue: String?
        do {
            paths = try await store.imageAttachmentPaths()
            savedComposer = try await store.setting("composer_attachments")
            savedQueue = try await store.setting("message_queue")
        } catch {
            return nil
        }
        guard let saved = ImageAttachments.savedPaths(composerAttachments: savedComposer, messageQueue: savedQueue,
                                                      excluding: deleted) else { return nil }
        paths.formUnion(saved)
        for images in composerAttachments.values { paths.formUnion(images.map(\.path)) }
        var messages: [QueuedMessage] = messageQueues.values.flatMap { $0 }
        messages += removedQueuedMessages.values.map(\.message)
        messages += Array(sendingMessages.values)
        messages += handoffCards.values.flatMap(\.movedMessages)
        for message in messages { paths.formUnion(message.images.map(\.path)) }
        return paths
    }
}
