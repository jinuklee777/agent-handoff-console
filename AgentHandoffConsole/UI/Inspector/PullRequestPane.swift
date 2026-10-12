import AppKit
import SwiftUI

/// Pull Request 탭. `gh` CLI 로 **읽기만** 한다. 탭을 열거나 새로고침할 때만 조회한다 (네트워크).
/// 리뷰 코멘트 인계 · 코멘트 · 머지 같은 쓰기 동작은 아직 없다.
struct PullRequestPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader {
                Text("Pull Request").font(Theme.ui(.callout, .semibold)).foregroundStyle(Theme.ink)
                Text(sourceNote).font(Theme.mono(.caption)).foregroundStyle(Theme.slate2).lineLimit(1)
            } trailing: {
                IconButton(systemName: "arrow.clockwise", size: 11.5, help: "gh 로 다시 조회",
                           spinning: model.workspace.pullRequest == .loading) {
                    Task { await model.workspace.refreshPullRequest() }
                }
                .disabled(model.workspace.pullRequest == .loading)
            }
            ScrollView { content }
        }
        .task(id: "\(model.workspace.projectPath ?? "")|\(model.workspace.git?.headLabel ?? "")") {
            // 탭을 여는 것 자체가 사용자의 조회 요청이다. 이미 조회한 브랜치는 캐시를 쓴다.
            if model.workspace.pullRequest == .idle, model.workspace.git != nil {
                await model.workspace.refreshPullRequest()
            }
        }
    }

    private var sourceNote: String {
        switch model.workspace.pullRequest {
        case .loaded, .none: return "gh · 읽기 전용"
        case .loading: return "gh · 조회 중"
        case .unavailable: return "gh · 사용 불가"
        case .failed: return "gh · 실패"
        case .idle: return "gh"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.workspace.pullRequest {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("gh 로 이 브랜치의 PR 을 찾는 중…").font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
            }
            .padding(20)
        case .unavailable(let message):
            QuietEmptyState(systemImage: "arrow.triangle.pull", title: "PR 을 읽을 수 없습니다", detail: message)
                .padding(.top, 30)
        case .failed(let message):
            QuietEmptyState(systemImage: "exclamationmark.triangle", title: "조회에 실패했습니다", detail: message)
                .padding(.top, 30)
        case .none(let branch, let others):
            VStack(alignment: .leading, spacing: 0) {
                QuietEmptyState(systemImage: "arrow.triangle.pull", title: "이 브랜치의 PR 이 없습니다",
                                detail: "\(branch.isEmpty ? "현재 브랜치" : branch) 에서 연 PR 을 찾지 못했습니다. "
                                    + "PR 만들기는 아직 앱에서 하지 않습니다.")
                    .padding(.top, 20)
                otherList(others)
            }
        case .loaded(let info, let others):
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 20) {
                    summary(info)
                    checks(info)
                    reviews(info)
                    actions(info)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 16)
                otherList(others)
            }
        }
    }

    // MARK: 요약

    private func summary(_ info: PullRequestInfo) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(verbatim: "#\(info.number)").font(Theme.mono(.caption)).foregroundStyle(Theme.slate)
                statePill(info)
                Spacer()
                Text(Fmt.relative(info.createdAt)).font(Theme.mono(.caption)).foregroundStyle(Theme.slate2)
            }
            Text(info.title)
                .font(Theme.ui(.body, .semibold))
                .foregroundStyle(Theme.ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text(info.headRefName).lineLimit(1).truncationMode(.middle)
                Text("→").foregroundStyle(Theme.slate3)
                Text(info.baseRefName).lineLimit(1)
                if info.additions != nil || info.deletions != nil {
                    Text("·").foregroundStyle(Theme.slate3)
                    if let a = info.additions { Text("+\(a)").foregroundStyle(Theme.emeraldText) }
                    if let d = info.deletions { Text("−\(d)").foregroundStyle(Theme.danger) }
                }
                if let files = info.changedFiles {
                    Text("·").foregroundStyle(Theme.slate3)
                    Text("\(files) files")
                }
            }
            .font(Theme.mono(.caption))
            .foregroundStyle(Theme.slate)
        }
    }

    @ViewBuilder
    private func statePill(_ info: PullRequestInfo) -> some View {
        let (label, color, well, border): (String, Color, Color, Color) = {
            if info.isDraft { return ("Draft", Theme.slate, Theme.wellSoft, Theme.hair) }
            switch info.state {
            case "OPEN": return ("Open", Theme.emerald, Theme.emeraldWell, Theme.emeraldBorder)
            case "MERGED": return ("Merged", Theme.ink2, Theme.wellSoft, Theme.hair)
            case "CLOSED": return ("Closed", Theme.danger, Theme.wellSoft, Theme.hair)
            default: return (info.state.capitalized, Theme.slate, Theme.wellSoft, Theme.hair)
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.pull").font(.system(size: 9, weight: .semibold))
            Text(label).font(Theme.ui(.caption, .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 19)
        .background(well, in: Capsule())
        .overlay(Capsule().strokeBorder(border))
    }

    // MARK: 체크

    @ViewBuilder
    private func checks(_ info: PullRequestInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionLabel("체크")
                if !info.checks.isEmpty {
                    Text("\(info.checks.filter { $0.outcome == .pass }.count) / \(info.checks.count)")
                        .font(Theme.mono(.caption)).foregroundStyle(Theme.slate2)
                }
            }
            if info.checks.isEmpty {
                Text("보고된 체크가 없습니다.").font(Theme.ui(.caption)).foregroundStyle(Theme.slate2)
                    .leadingRule(Theme.hair, gap: 12)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(info.checks) { check in checkRow(check) }
                }
                .leadingRule(Theme.hair, gap: 12)
            }
        }
    }

    private func checkRow(_ check: PullRequestInfo.Check) -> some View {
        HStack(spacing: 8) {
            Group {
                switch check.outcome {
                case .pass: Text("✔").foregroundStyle(Theme.emeraldText)
                case .fail: Text("✕").foregroundStyle(Theme.danger)
                case .pending: PendingRing()
                case .skipped, .neutral: Text("–").foregroundStyle(Theme.slate2)
                }
            }
            .font(Theme.mono(.caption, .bold))
            .frame(width: 12)
            Text(check.name).font(Theme.ui(.callout)).foregroundStyle(Theme.ink2).lineLimit(1)
            if let detail = check.detail, detail != check.name {
                Text(detail).font(Theme.mono(.caption)).foregroundStyle(Theme.slate2).lineLimit(1)
            }
            Spacer(minLength: 4)
            switch check.outcome {
            case .pending:
                Text("진행 중").font(Theme.mono(.caption)).foregroundStyle(Theme.amberText)
            case .fail:
                Text("실패").font(Theme.mono(.caption)).foregroundStyle(Theme.danger)
            default:
                if let duration = check.duration {
                    Text(Fmt.compactDuration(ms: Int(duration * 1000)))
                        .font(Theme.mono(.caption)).foregroundStyle(Theme.slate2)
                }
            }
        }
    }

    // MARK: 리뷰

    @ViewBuilder
    private func reviews(_ info: PullRequestInfo) -> some View {
        let changes = info.reviews.filter { $0.state == "CHANGES_REQUESTED" }.count
        let approvals = info.reviews.filter { $0.state == "APPROVED" }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionLabel("리뷰")
                if changes > 0 {
                    Text("변경 요청 \(changes)").font(Theme.mono(.caption)).foregroundStyle(Theme.amberText)
                }
                if approvals > 0 {
                    Text("승인 \(approvals)").font(Theme.mono(.caption)).foregroundStyle(Theme.emeraldText)
                }
                if changes == 0 && approvals == 0, info.reviewDecision == "REVIEW_REQUIRED" {
                    Text("리뷰 필요").font(Theme.mono(.caption)).foregroundStyle(Theme.slate2)
                }
            }
            if info.reviews.isEmpty {
                Text("아직 리뷰가 없습니다.").font(Theme.ui(.caption)).foregroundStyle(Theme.slate2)
                    .leadingRule(Theme.hair, gap: 12)
            }
            ForEach(info.reviews) { review in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(String(review.author.prefix(1)).uppercased())
                            .font(Theme.ui(.caption, .bold))
                            .foregroundStyle(Theme.slate)
                            .frame(width: 18, height: 18)
                            .background(Theme.hair, in: Circle())
                        Text(review.author).font(Theme.ui(.callout, .semibold)).foregroundStyle(Theme.ink)
                        Text(reviewStateName(review.state)).font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
                        Spacer()
                        Text(Fmt.relative(review.submittedAt)).font(Theme.mono(.caption)).foregroundStyle(Theme.slate2)
                    }
                    if !review.body.isEmpty {
                        Text(review.body)
                            .font(Theme.ui(.callout))
                            .foregroundStyle(Theme.ink2)
                            .lineSpacing(3)
                            .lineLimit(5)
                            .textSelection(.enabled)
                    }
                }
                .leadingRule(reviewRule(review.state), width: review.state == "COMMENTED" ? 1 : 2, gap: 12)
            }
        }
    }

    private func reviewStateName(_ state: String) -> String {
        switch state {
        case "APPROVED": return "승인"
        case "CHANGES_REQUESTED": return "변경 요청"
        case "COMMENTED": return "코멘트"
        case "DISMISSED": return "철회됨"
        default: return state.lowercased()
        }
    }

    private func reviewRule(_ state: String) -> Color {
        switch state {
        case "APPROVED": return Theme.emerald
        case "CHANGES_REQUESTED": return Theme.amber
        default: return Theme.hair
        }
    }

    // MARK: 동작

    private func actions(_ info: PullRequestInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NotYetNote(title: "리뷰 코멘트 인계 · 머지는 아직 없습니다",
                       detail: "지금은 PR 을 읽기만 합니다 — 리뷰 코멘트에 답하거나 머지하려면 GitHub 에서 하세요.")
            if let url = URL(string: info.url), !info.url.isEmpty {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text("GitHub 에서 열기 ↗").frame(maxWidth: .infinity)
                }
                .buttonStyle(ChipButtonStyle(height: 28))
            }
        }
    }

    @ViewBuilder
    private func otherList(_ others: [PullRequestSummary]) -> some View {
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("이 저장소의 다른 PR")
                ForEach(others.prefix(5)) { pr in
                    HStack(spacing: 8) {
                        Text(verbatim: "#\(pr.number)").font(Theme.mono(.caption)).foregroundStyle(Theme.slate2)
                            .frame(width: 40, alignment: .leading)
                        Text(pr.title).font(Theme.ui(.caption)).foregroundStyle(Theme.ink2).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(pr.isDraft ? "draft" : pr.state.lowercased())
                            .font(Theme.mono(.caption)).foregroundStyle(Theme.slate2)
                    }
                }
            }
            .padding(.top, 10)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hair).frame(height: 1) }
        }
    }
}
