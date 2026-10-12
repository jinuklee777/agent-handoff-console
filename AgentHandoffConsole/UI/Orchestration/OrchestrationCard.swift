import SwiftUI

/// 부모 대화의 입력창 위에 놓이는 자동 작업 카드: 목표 · 진행 · 하위 작업 · 사람이 해 줄 일.
/// 판단은 여기서 하지 않는다 — 코디네이터의 스냅샷과 `attention` 을 그대로 그린다.
/// 끝난 작업(완료 · 실패 · 중단)에는 카드를 띄우지 않는다. 기록은 대화의 "자동 작업" 줄에 남아 있다.
struct OrchestrationCard: View {
    @Environment(AppModel.self) private var model
    let snapshot: OrchestrationSnapshot

    @State private var expanded = true
    @State private var answer = ""

    private var job: OrchestrationJob { snapshot.job }
    private var tasks: [OrchestrationTask] { snapshot.activeTasks }
    private var attention: OrchestrationAttention? { model.orchestration.attention(for: snapshot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                if !tasks.isEmpty {
                    Rectangle().fill(Theme.hair).frame(height: 1)
                    VStack(spacing: 0) { ForEach(tasks) { taskRow($0) } }
                        .padding(.vertical, 4)
                }
                if !supportThreads.isEmpty {
                    Rectangle().fill(Theme.hair).frame(height: 1)
                    supportRow
                }
                if let attention {
                    Rectangle().fill(Theme.hair).frame(height: 1)
                    attentionView(attention).padding(10)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hair, lineWidth: 1))
    }

    // MARK: 머리줄

    private var header: some View {
        HStack(spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.slate2)
                    .frame(width: 14, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "자동 작업 접기" : "자동 작업 펼치기")

            Text(job.state.koreanName)
                .font(Theme.ui(.caption, .semibold))
                .foregroundStyle(stateTextColor)
                .padding(.horizontal, 6).frame(height: 18)
                .background(Capsule().fill(stateColor.opacity(0.12)))
            Text(model.orchestration.plansByJob[job.id]?.goal ?? job.request)
                .font(Theme.ui(.callout, .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 6)
            if !tasks.isEmpty {
                Text("\(tasks.filter { $0.state == .succeeded }.count)/\(tasks.count) · 시도 \(snapshot.attempts.count)")
                    .font(Theme.ui(.caption))
                    .foregroundStyle(Theme.slate)
                    .fixedSize()
            }
            if job.state == .running || job.state == .planning {
                textButton("일시 정지", enabled: job.state == .running) { coordinator in try await coordinator.pause(jobID: job.id) }
            } else if job.state == .paused {
                textButton("재개") { coordinator in try await coordinator.resume(jobID: job.id) }
            }
            textButton("중단", color: Theme.danger) { coordinator in try await coordinator.cancel(jobID: job.id) }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private var stateColor: Color {
        switch job.state {
        case .awaitingUser, .ready: return Theme.amber
        case .failed, .cancelled, .cancelling: return Theme.danger
        case .completed: return Theme.emerald
        default: return Theme.slate
        }
    }

    /// 상태 이름표의 글자 — 앰버 · 초록은 글자용 `amberText` · `emeraldText` (12% 바탕 위에서도 4.5:1 이상). 바탕은 `stateColor`.
    private var stateTextColor: Color {
        switch job.state {
        case .awaitingUser, .ready: return Theme.amberText
        case .completed: return Theme.emeraldText
        default: return stateColor
        }
    }

    // MARK: 계획 · 검토 대화

    /// 하위 작업이 아닌 내부 대화 (계획 담당 · 검토 담당들). 작업 줄에서는 열 수 없어 따로 둔다.
    private var supportThreads: [ConversationThread] {
        model.internalThreadsByID.values
            .filter { $0.orchestrationJobID == job.id && $0.orchestrationRole != "task" }
            .sorted { ($0.orchestrationRole ?? "", $0.preferredProvider.rawValue) < ($1.orchestrationRole ?? "", $1.preferredProvider.rawValue) }
    }

    /// 계획 · 검토 대화를 여는 줄. 지금 돌고 있는 대화에는 점이 붙는다 — 검토단이면 둘이 함께 켜진다.
    private var supportRow: some View {
        HStack(spacing: 12) {
            ForEach(supportThreads) { thread in
                Button { Task { await model.selectThread(thread.id) } } label: {
                    HStack(spacing: 5) {
                        if model.isThreadRunning(thread.id) {
                            Circle().fill(Theme.emerald).frame(width: 6, height: 6)
                        }
                        Text(thread.orchestrationRole == "planner" ? "계획 기록" : "검토 기록 · \(thread.preferredProvider.displayName)")
                            .font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.isThreadRunning(thread.id) ? "지금 돌고 있습니다. 눌러서 진행을 봅니다." : "이 대화의 실행 기록 열기")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
    }

    // MARK: 하위 작업

    private func taskRow(_ task: OrchestrationTask) -> some View {
        let attempts = snapshot.attempts(for: task.id)
        let profile = attempts.last.flatMap { last in model.orchestrationSettings.profiles.first { $0.id == last.profileID }?.name }
        return Button {
            if let id = task.childThreadID { Task { await model.selectThread(id) } }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(for: task.state))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(color(for: task.state))
                    .frame(width: 14)
                Text(task.title)
                    .font(Theme.ui(.callout))
                    .foregroundStyle(task.state.isTerminal && task.state != .succeeded ? Theme.slate : Theme.ink)
                    .lineLimit(1)
                if task.optional {
                    Text("선택").font(Theme.ui(.caption)).foregroundStyle(Theme.slate2)
                }
                Spacer(minLength: 6)
                if task.state == .verifying, let reviewers = attempts.last.flatMap({ model.orchestration.activeReviewers[$0.id] }),
                   !reviewers.isEmpty {
                    // 검증 중에는 누가 검토하는지 (검토단이면 둘이 동시에).
                    Text("검토: " + reviewers.joined(separator: " · "))
                        .font(Theme.ui(.caption)).foregroundStyle(Theme.slate2).lineLimit(1)
                } else if let profile {
                    Text(attempts.count > 1 ? "\(profile) · \(attempts.count)번째" : profile)
                        .font(Theme.ui(.caption)).foregroundStyle(Theme.slate2).lineLimit(1)
                }
                Text(stateText(task, attempt: attempts.last))
                    .font(Theme.ui(.caption)).foregroundStyle(textColor(for: task.state)).fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(task.childThreadID == nil)
        .help(task.childThreadID == nil ? task.specification : "이 작업의 실행 기록 열기\n\n" + task.specification)
    }

    /// 작업 줄의 상태 글. 실행 중인 작업의 실행이 메인 턴을 마치고 백그라운드 작업을 기다리면 그렇게 (답은 끝난 것처럼 보여도
    /// 실행은 돌고 있다 — 검증은 기다림이 끝난 뒤다).
    private func stateText(_ task: OrchestrationTask, attempt: OrchestrationAttempt?) -> String {
        guard task.state == .running, let runID = attempt?.runID, let session = model.runner.session(runID: runID),
              session.isWaitingOnBackground else { return task.state.koreanName }
        return SubAgentDigest.waitingTaskText(count: session.unfinishedSubAgentCount)
    }

    private func icon(for state: TaskState) -> String {
        switch state {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled, .superseded: return "minus.circle"
        case .blocked: return "exclamationmark.triangle.fill"
        case .running, .routing: return "circle.dotted"
        case .verifying: return "checklist"
        case .retryPending, .escalationPending: return "arrow.triangle.2.circlepath"
        case .pending, .ready: return "circle"
        }
    }

    /// 작업 줄의 상태 글자 — 앰버 · 초록은 글자용 `amberText` · `emeraldText` (아이콘은 `color(for:)`).
    private func textColor(for state: TaskState) -> Color {
        switch state {
        case .blocked, .retryPending, .escalationPending: return Theme.amberText
        case .succeeded: return Theme.emeraldText
        default: return color(for: state)
        }
    }

    private func color(for state: TaskState) -> Color {
        switch state {
        case .succeeded: return Theme.emerald
        case .failed: return Theme.danger
        case .blocked, .retryPending, .escalationPending: return Theme.amber
        case .running, .routing, .verifying: return Theme.ink
        default: return Theme.slate2
        }
    }

    // MARK: 사람이 해 줄 일

    @ViewBuilder
    private func attentionView(_ attention: OrchestrationAttention) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch attention {
            case .planApproval:
                message("계획을 확인하고 시작하세요. 작업마다 담당 모델을 고르고, 끝날 때마다 완료 조건으로 검증합니다.")
                HStack(spacing: 6) {
                    primaryButton("시작") { c in try await c.approvePlan(jobID: job.id) }
                    textButton("다시 계획") { c in try await c.replan(jobID: job.id) }
                }
            case .clarification(let questions):
                message(questions.isEmpty ? "요청만으로는 시작하기 어렵습니다. 무엇을 어떻게 바꾸길 원하는지 알려 주세요."
                                          : questions.map { "· " + $0 }.joined(separator: "\n"))
                HStack(spacing: 6) {
                    TextField("답을 적어 주세요", text: $answer, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Theme.ui(.callout))
                        .lineLimit(1...4)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.well))
                        .onSubmit(sendAnswer)
                    primaryButton("답하기", enabled: !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { _ in sendAnswer() }
                }
            case .deliveryUnknown(let attemptIDs):
                message("실행 결과를 확인할 수 없는 작업이 있습니다 (앱이 꺼졌거나 프로세스 종료를 확인하지 못했습니다). "
                        + "자동으로 다시 보내지 않습니다. 이 대화의 폴더를 확인한 뒤 골라 주세요.")
                HStack(spacing: 6) {
                    primaryButton("끝난 것으로 보고 검증") { c in
                        for id in attemptIDs { try await c.resolveDeliveryUnknown(jobID: job.id, attemptID: id, finished: true) }
                    }
                    textButton("다시 시도") { c in
                        for id in attemptIDs { try await c.resolveDeliveryUnknown(jobID: job.id, attemptID: id, finished: false) }
                    }
                }
            case .blocked(let blocked):
                ForEach(blocked) { task in
                    VStack(alignment: .leading, spacing: 4) {
                        message("\(task.title) — \(task.blockedReason ?? "선행 작업을 기다리고 있습니다.")")
                        // 일은 끝났는데 검증을 못 한 경우에만 사람이 통과로 인정할 수 있다 (환경 문제로 멈춘 작업은 끝난 것이 아니다).
                        if task.blockedReason?.hasPrefix("검증") == true {
                            textButton("직접 확인했고 통과로 인정") { c in try await c.acceptTask(jobID: job.id, taskID: task.id) }
                        }
                    }
                }
                HStack(spacing: 6) {
                    primaryButton("문제를 고쳤으니 계속") { c in try await c.resume(jobID: job.id) }
                    textButton("다시 계획") { c in try await c.replan(jobID: job.id) }
                }
            case .finalVerificationFailed:
                message("하위 작업은 모두 통과했지만 최종 통합 검증을 통과하지 못했습니다. 완료로 표시하지 않았습니다.")
                HStack(spacing: 6) {
                    primaryButton("다시 검증") { c in try await c.resume(jobID: job.id) }
                    textButton("직접 확인했고 완료로 인정") { c in try await c.acceptFinal(jobID: job.id) }
                    textButton("다시 계획") { c in try await c.replan(jobID: job.id) }
                }
            case .budgetExhausted:
                message("시도 예산(\(job.budget.maxTotalAttempts)회)을 다 썼습니다.")
                primaryButton("10회 더 허용하고 계속") { c in try await c.extendBudget(jobID: job.id) }
            case .planningFailed:
                message("계획을 세우지 못했습니다. 대화의 기록에서 이유를 확인할 수 있습니다.")
                primaryButton("다시 계획") { c in try await c.replan(jobID: job.id) }
            }
        }
    }

    private func sendAnswer() {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        answer = ""
        model.orchestrationAction { coordinator in try await coordinator.answer(jobID: job.id, text: text) }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(.callout))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func primaryButton(_ title: String, enabled: Bool = true,
                               _ action: @escaping (OrchestrationCoordinator) async throws -> Void) -> some View {
        Button { model.orchestrationAction(action) } label: {
            Text(title)
                .font(Theme.ui(.callout, .semibold))
                .foregroundStyle(Theme.onInk)
                .padding(.horizontal, 10).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink))
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func textButton(_ title: String, color: Color = Theme.slate, enabled: Bool = true,
                            _ action: @escaping (OrchestrationCoordinator) async throws -> Void) -> some View {
        Button { model.orchestrationAction(action) } label: {
            Text(title).font(Theme.ui(.callout, .medium)).foregroundStyle(color)
        }
        .buttonStyle(GhostChipStyle())
        .disabled(!enabled)
    }
}

/// 내부 대화(계획 · 검토 · 하위 작업)를 열었을 때 입력창 자리에 놓이는 줄. 여기서는 메시지를 보내지 않는다 —
/// 세션과 시도 기록이 코디네이터의 것이라, 사람이 끼어들면 검증 · 복구의 근거가 흐려진다.
struct InternalThreadBar: View {
    @Environment(AppModel.self) private var model
    let thread: ConversationThread

    private var parentID: String? {
        model.orchestration.snapshotsByThread.values.first { $0.job.id == thread.orchestrationJobID }?.job.parentThreadID
    }

    private var roleName: String {
        switch thread.orchestrationRole {
        case "planner": return "계획"
        case "reviewer": return "검토"
        default: return "하위 작업"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(Theme.slate)
            Text("자동 작업의 내부 대화 (\(roleName)) — 기록을 보는 곳입니다.")
                .font(Theme.ui(.callout)).foregroundStyle(Theme.slate)
            Spacer()
            if let parentID {
                Button { Task { await model.selectThread(parentID) } } label: {
                    Text("부모 대화로").font(Theme.ui(.callout, .medium)).foregroundStyle(Theme.ink)
                }
                .buttonStyle(GhostChipStyle())
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: Theme.Metric.capsuleRadius).fill(Theme.well))
    }
}
