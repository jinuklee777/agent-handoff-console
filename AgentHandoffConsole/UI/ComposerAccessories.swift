import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 입력창의 곁 부품: 승인 방식 칩, 실행 중에 걸어 둔 메시지(대기열), 붙인 이미지 줄, 이미지 썸네일, 붙여넣기 판별.

// MARK: - 승인 방식

/// 조작 줄의 승인 칩: 이 제공자가 실제로 묻는 방식(`ApprovalPolicyText.policy` — 설정 > 에이전트의 승인) /
/// "자동 승인". 대화마다 따로이고, 실행 도중에 바꿔도 다음 요청부터 곧바로 맞는다
/// (켜면 떠 있던 승인 카드도 허용된다 — `AppModel.setAutoApproval`). 자동 승인은 앱이 허용하고 결정 행에 "자동 허용"을 남긴다.
/// 켤 때는 팝오버 안에서 한 번 더 확인받는다 (경고창은 닫히는 팝오버와 겹친다).
struct ApprovalModeChip: View {
    @Environment(AppModel.self) private var model
    let threadID: String
    let provider: AgentProvider
    var density: ComposerDensity = .full
    @State private var presented = false
    @State private var confirmingAuto = false

    private var auto: Bool { model.isAutoApproving(threadID: threadID) }
    private var policy: ApprovalPolicyText {
        ApprovalPolicyText.policy(provider: provider, claudePermissionMode: model.claudePermissionMode,
                                  codexApprovalPolicy: model.codexApprovalPolicy,
                                  codexSandboxMode: model.codexSandboxMode)
    }
    private var shown: ApprovalPolicyText { auto ? .autoApproval : policy }

    var body: some View {
        let shown = shown
        let tint = shown.caution ? Theme.amber : Theme.slate
        Button { presented.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: shown.systemImage)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(tint)
                if density != .minimal {
                    Text(shown.title)
                        .foregroundStyle(shown.caution ? Theme.amberText : Theme.slate)
                        .lineLimit(1)
                }
                Text("▾").font(.system(size: 8)).foregroundStyle(Theme.slate2)
            }
        }
        .buttonStyle(GhostChipStyle(pressed: presented))
        .fixedSize()
        .help(shown.detail)
        .accessibilityLabel("승인 방식: \(shown.title)")
        .popover(isPresented: $presented, arrowEdge: .top) {
            let policy = policy
            VStack(alignment: .leading, spacing: 2) {
                row(title: policy.title, detail: policy.detail,
                    systemImage: policy.systemImage, selected: !auto) { choose(false) }
                row(title: ApprovalPolicyText.autoApproval.title, detail: ApprovalPolicyText.autoApproval.detail,
                    systemImage: ApprovalPolicyText.autoApproval.systemImage, selected: auto) {
                    if auto { presented = false } else { confirmingAuto = true }
                }
                if confirmingAuto && !auto {
                    autoConfirmation
                } else {
                    Text("이 대화에만 적용됩니다 · 실행 중에 바꿔도 다음 요청부터 맞습니다. 위 방식은 설정 > 에이전트의 승인을 따릅니다.")
                        .font(Theme.ui(.caption))
                        .foregroundStyle(Theme.slate)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                }
            }
            .padding(6)
            .frame(width: 300)
            .background(Theme.paper)
        }
        .onChange(of: presented) { _, open in if !open { confirmingAuto = false } }
    }

    /// 자동 승인을 켜기 전의 확인 — 무엇이 묻지 않고 실행되는지.
    private var autoConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ApprovalPolicyText.autoApprovalConfirmation(provider: provider))
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("켜기") { choose(true) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.amberFill)
                Button("취소") { confirmingAuto = false }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.approvalWell, in: RoundedRectangle(cornerRadius: 6))
        .padding(.top, 4)
    }

    private func choose(_ on: Bool) {
        presented = false
        confirmingAuto = false
        Task { await model.setAutoApproval(on, threadID: threadID) }
    }

    private func row(title: String, detail: String, systemImage: String, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 15)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.ui(.callout, selected ? .semibold : .medium)).foregroundStyle(Theme.ink)
                    Text(detail).font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background { if selected { RoundedRectangle(cornerRadius: 6).fill(Theme.well) } }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 대기열

/// 입력창 맨 위: 실행 중에 걸어 둔 메시지들. 지금 실행이 정상으로 끝나면 위에서부터 하나씩 간다.
/// 멈췄으면(실행이 실패 · 중단으로 끝남 · 앱을 다시 켬) 이유와 "이어서 보내기"를 보인다. 메인 턴을 마치고 백그라운드 작업을 기다리는
/// 실행이면 그 까닭과 "멈추고 보내기"(chat-22). 막 뺀 메시지는 몇 초 동안 되돌릴 수 있다 (chat-28).
struct ComposerQueueList: View {
    @Environment(AppModel.self) private var model
    let threadID: String
    /// 고치려는 메시지 — 입력창에 쓰던 글이 있으면 이어 붙이기 전에 묻는다.
    @State private var confirmingEdit: QueuedMessage?

    var body: some View {
        let queue = model.queuedMessages(threadID: threadID)
        let removed = model.removedQueuedMessages[threadID]
        if !queue.isEmpty || removed != nil {
            // 인계 카드가 있으면 보류 — 인계가 확인되면 받는 쪽에게 간다 ("이어서 보내기" 는 숨긴다).
            let hold = model.queueHolds[threadID]
            let paused = hold == nil ? model.queuePauseReasons[threadID] : nil
            let session = model.runner.session(threadID: threadID)
            let busy = model.runner.isBusy(threadID: threadID) || model.isStartingRun(threadID: threadID)
                || model.isSending(threadID: threadID)
            // 메인 턴은 끝났는데 백그라운드 작업(서버 · 하위 에이전트)이 남아 실행이 끝나지 않았다 — 끝나야 보낸다.
            let waitingCount = session.flatMap { $0.isWaitingOnBackground && $0.state != .interrupting ? $0.unfinishedSubAgentCount : nil }
            VStack(alignment: .leading, spacing: 0) {
                if !queue.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: hold != nil ? "arrow.left.arrow.right" : (paused == nil ? "clock" : "pause.circle"))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(paused == nil ? Theme.slate : Theme.amber)
                        let header = hold.map { holdHeader($0) } ?? paused ?? waitingCount.map { waitingHeader($0) }
                            ?? (busy ? "대기열 · 지금 실행이 끝나면 차례로 보냅니다" : "대기열")
                        // 멈춤 이유는 문장 끝에 누가 받는지 적는다 — 좁은 칸(두 칸 · 네 칸)에서도 잘리지 않게 두 줄까지, 전문은 도움말로.
                        Text(header)
                            .font(Theme.ui(.caption))
                            .foregroundStyle(paused == nil ? Theme.slate : Theme.amberText)
                            .lineLimit(paused == nil && waitingCount == nil ? 1 : 2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: paused != nil || waitingCount != nil)
                            .help(header)
                        Spacer(minLength: 6)
                        if paused != nil {
                            Button(busy ? "이어서 보내기 (실행이 끝나면)" : "이어서 보내기") {
                                if busy { model.queuePauseReasons[threadID] = nil } else {
                                    Task { await model.resumeQueue(threadID: threadID) }
                                }
                            }
                            .buttonStyle(TextButtonStyle(color: Theme.ink, font: Theme.ui(.caption, .medium)))
                        } else if hold == nil, waitingCount != nil {
                            Button("멈추고 보내기") { Task { await model.stopAndSendQueue(threadID: threadID) } }
                                .buttonStyle(TextButtonStyle(color: Theme.ink, font: Theme.ui(.caption, .medium)))
                                .fixedSize()
                                .help("지금 실행을 멈추고 걸어 둔 메시지를 보냅니다. 남은 백그라운드 작업(서버 · 하위 에이전트)도 함께 멈춥니다.")
                        }
                    }
                    .padding(.bottom, 5)
                    ForEach(Array(queue.enumerated()), id: \.element.id) { index, message in
                        row(index: index, message: message)
                    }
                }
                if let removed { undoRow(removed) }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .alert("입력창에 쓰던 글이 있습니다", isPresented: Binding(get: { confirmingEdit != nil },
                                                               set: { if !$0 { confirmingEdit = nil } }),
                   presenting: confirmingEdit) { message in
                Button("뒤에 이어 붙이기") { model.editQueuedMessage(message.id, threadID: threadID) }
                Button("취소", role: .cancel) {}
            } message: { _ in
                Text("걸어 둔 메시지를 쓰던 글 뒤에 이어 붙여 한 메시지로 고칩니다.")
            }
        }
    }

    /// 백그라운드 작업을 기다리는 실행 뒤의 대기열 머리.
    private func waitingHeader(_ count: Int) -> String {
        count > 0 ? "백그라운드 작업 \(count)개가 끝나야 보냅니다 · 멈추면 바로 보냅니다"
                  : "백그라운드 작업이 끝나야 보냅니다 · 멈추면 바로 보냅니다"
    }

    /// 막 뺀 메시지의 되돌리기 줄 — 몇 초 뒤 사라진다.
    private func undoRow(_ removed: RemovedQueuedMessage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.slate2)
            Text("대기열에서 뺐습니다 · " + (removed.message.text.isEmpty ? "(이미지만)"
                                                : ExecutionParser.firstLine(removed.message.text, max: 80)))
                .font(Theme.ui(.caption))
                .foregroundStyle(Theme.slate)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Button("되돌리기") { model.undoQueueRemoval(threadID: threadID) }
                .buttonStyle(TextButtonStyle(color: Theme.ink, font: Theme.ui(.caption, .medium)))
                .fixedSize()
        }
        .frame(height: 24)
        .task(id: removed.message.id) {
            try? await Task.sleep(for: .seconds(QueueRules.undoWindow))
            if !Task.isCancelled { model.expireQueueRemoval(threadID: threadID, messageID: removed.message.id) }
        }
    }

    /// 보류 중의 머리 — 전달 여부 미확인 카드면 받는 쪽에게 간다고 약속하지 않는다. 넘긴 뒤 받는 쪽이 일하는 중이면 그 사실을.
    private func holdHeader(_ hold: QueueHold) -> String {
        if model.isHandoffDeliveryUnknown(threadID: threadID) { return HandoffCardText.unknownQueueHeader }
        let target = model.handoffPartyName(hold.target)
        return model.deliveringHandoffs[threadID] != nil ? HandoffCardText.deliveringQueueHeader(target: target)
                                                         : HandoffCardText.queueHeader(target: target)
    }

    private func row(index: Int, message: QueuedMessage) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(Theme.mono(.caption, .semibold))
                .foregroundStyle(Theme.slate)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Theme.hair))
            if !message.images.isEmpty {
                Label("\(message.images.count)", systemImage: "photo")
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
                    .labelStyle(.titleAndIcon)
            }
            Text(message.text.isEmpty ? "(이미지만)" : ExecutionParser.firstLine(message.text, max: 200))
                .font(Theme.ui(.callout))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            IconButton(systemName: "pencil", size: 10.5, color: Theme.slate2, help: "입력창으로 되돌려 고치기") {
                // 쓰던 글이 있으면 말없이 이어 붙이지 않고 묻는다 (chat-28).
                if model.composerDraft(for: threadID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    model.editQueuedMessage(message.id, threadID: threadID)
                } else {
                    confirmingEdit = message
                }
            }
            .accessibilityLabel("\(index + 1)번 메시지 고치기")
            // 고치기와 떼어 둔다 — 고치려다 빼지 않게. 빼도 몇 초 동안 되돌릴 수 있다.
            IconButton(systemName: "xmark", size: 9.5, color: Theme.slate2, help: "대기열에서 빼기 (몇 초 동안 되돌릴 수 있습니다)") {
                model.removeQueuedMessage(message.id, threadID: threadID)
            }
            .accessibilityLabel("\(index + 1)번 메시지 빼기")
            .padding(.leading, 6)
        }
        .frame(height: 24)
        .help(message.text)
    }
}

// MARK: - 붙인 이미지

/// 입력창 글 위의 붙인 이미지 줄: 썸네일 · 떼기. 가져오는 중이면 그 수만큼 자리를 둔다.
struct ComposerAttachmentStrip: View {
    @Environment(AppModel.self) private var model
    let threadID: String

    var body: some View {
        let images = model.attachments(threadID: threadID)
        let importing = model.importingAttachments[threadID] ?? 0
        if !images.isEmpty || importing > 0 {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(images) { image in
                        ImageThumbnail(attachment: image, side: 56)
                            .overlay(alignment: .topTrailing) {
                                Button { model.discardAttachment(image.id, threadID: threadID) } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 7.5, weight: .bold))
                                        .foregroundStyle(Theme.onInk)
                                        .frame(width: 16, height: 16)
                                        .background(Circle().fill(Theme.ink.opacity(0.75)))
                                }
                                .buttonStyle(.plain)
                                .help("떼기")
                                .accessibilityLabel("\(image.name) 떼기")
                                .offset(x: 5, y: -5)
                            }
                    }
                    ForEach(0..<importing, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.hair)
                            .frame(width: 56, height: 56)
                            .overlay(PendingRing(color: Theme.slate2))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 2)
            }
            .scrollIndicators(.never)
        }
    }
}

/// 이미지 썸네일 (정사각 · 가운데 채움). 파일에서 작은 크기로 읽는다 — 큰 원본을 통째로 풀지 않게. 누르면 기본 앱으로 연다.
struct ImageThumbnail: View {
    let attachment: ImageAttachment
    var side: CGFloat = 56
    @State private var image: NSImage?

    var body: some View {
        // 누르면 기본 앱으로 연다 — 단추로 알린다 (VoiceOver · 키보드, chat-27).
        Button { NSWorkspace.shared.open(attachment.url) } label: {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Theme.hair)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hair))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("\(attachment.name) · \(attachment.width)×\(attachment.height) — 누르면 엽니다")
        .accessibilityLabel("이미지 \(attachment.name) 열기")
        .task(id: attachment.path) {
            let path = attachment.path
            let pixel = Int(side * 2 * 2)
            image = await Task.detached(priority: .utility) { Self.thumbnail(path: path, pixel: pixel) }.value
        }
    }

    nonisolated static func thumbnail(path: String, pixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
