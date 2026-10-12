import SwiftUI

/// 툴바 오른쪽의 한도 표시. 제공자(계정)마다 로고 + 작은 막대 + "16%" — 누르면 자세한 보기(`LimitsPopover`).
/// 값이 없는 제공자는 로고를 흐리게 두고 "—" 를 적는다 (0% 로 채우지 않는다). 값이 하나도 없으면 앞에 "한도" 를 적는다.
/// 이 Mac 에서 CLI 를 찾지 못한 제공자는 칩 · 팝오버에서 뺀다 — 모두 없으면 칩도 없다 (`AppModel.limitEntries`).
/// 창 이름(5시간 등) · 확인 시각은 도움말과 접근성 글에 (`LimitsPresentation`). 옛 창 아래 상태 막대(2026-09-18 까지)를 대신한다.
struct LimitsChip: View {
    @Environment(AppModel.self) private var model
    @State private var presented = false
    /// 칩이 쓸 수 있는 폭 — 인스펙터를 열면 툴바 오른쪽 항목이 인스펙터 위 칸에 모이는데, Claude + Codex 계정 둘이면 칩 묶음이
    /// 인스펙터 경계선을 넘었다. 주면 그 폭에 들어가는 단계를 고른다 (막대를 빼고 → 계정 이름도 뺀다 — 이름 · 창은 도움말과 팝오버에).
    /// nil 이면 다 보인다.
    var budget: CGFloat?
    /// 단계마다 잰 너비 (보이지 않는 사본을 칩 뒤에 깔아 잰다). 칩은 고른 단계의 제 너비만 쓴다 — 폭을 정해 주면(`frame(width:)`)
    /// 툴바 항목이 인스펙터 칸을 밀어 인스펙터가 최소 폭보다 좁아졌다 (2026-10-09 미리보기).
    @State private var stageWidths: [Density: CGFloat] = [:]

    /// 좁을 때의 단계 — 앞에서부터 들어가는 것을 고른다.
    private enum Density: CaseIterable { case full, noMeters, bare }

    var body: some View {
        let entries = model.limitEntries
        if !entries.isEmpty {
            Button { presented.toggle() } label: {
                row(entries, density: density)
            }
            .buttonStyle(GhostChipStyle(height: 24, horizontalPadding: Self.padding, pressed: presented))
            .background(alignment: .trailing) { measurers(entries) }
            .help(LimitsPresentation.chipHelp(entries))
            .accessibilityLabel(LimitsPresentation.accessibility(entries))
            .popover(isPresented: $presented, arrowEdge: .bottom) { LimitsPopover() }
        }
    }

    private static let padding: CGFloat = 6

    /// 들어가는 첫 단계. 폭을 모르거나(인스펙터를 닫음) 아직 재지 않았으면 다 보인다.
    private var density: Density {
        guard let budget, !stageWidths.isEmpty else { return .full }
        for stage in [Density.full, .noMeters] {
            if let width = stageWidths[stage], width + Self.padding * 2 <= budget { return stage }
        }
        return .bare
    }

    /// 단계마다의 너비를 재는 보이지 않는 사본 — 배치에 끼지 않는다 (배경).
    private func measurers(_ entries: [LimitsPresentation.Entry]) -> some View {
        ZStack(alignment: .trailing) {
            ForEach(Density.allCases, id: \.self) { stage in
                row(entries, density: stage)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stageWidths[stage] = $0 }
            }
        }
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func row(_ entries: [LimitsPresentation.Entry], density: Density) -> some View {
        HStack(spacing: density == .full ? 10 : 8) {
            if LimitsPresentation.needsCaption(entries) {
                Text("한도").font(Theme.ui(.caption)).foregroundStyle(Theme.slate2)
            }
            ForEach(entries) { group($0, density: density) }
        }
        .fixedSize()
    }

    /// 사용률을 아는 구간 하나만 막대 · 퍼센트로 — 다 찬 계정 전체 창이 있으면 그것, 아니면 첫 구간(대개 짧은 창) (`chipWindow`).
    /// 한도에 닿았으면 값이 있어도 경고 기호를 함께 그린다 (chr-6). 나머지 구간은 팝오버에.
    @ViewBuilder
    private func group(_ entry: LimitsPresentation.Entry, density: Density) -> some View {
        HStack(spacing: 5) {
            BrandMark(provider: entry.snapshot.provider, size: 11, opacity: entry.state.hasValue ? 1 : 0.45)
            if density != .bare, let label = entry.accountLabel {
                Text(label).font(Theme.ui(.caption)).lineLimit(1)
            }
            switch entry.state {
            case .value(let window):
                if LimitsPresentation.chipWarns(entry.state, snapshot: entry.snapshot) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.amber)
                }
                if density == .full {
                    LimitMeter(fraction: window.utilization, width: 28)
                }
                if let value = window.utilization {
                    Text(LimitsPresentation.percent(value))
                        .font(Theme.mono(.caption, value >= 0.7 ? .semibold : .regular))
                        .foregroundStyle(LimitMeter.textColor(for: value))
                }
            case .problem:
                // 로그인 필요 · 한도 도달 · 조회 실패 같은 상태는 숨기지 않는다.
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.amber)
            case .pending, .unavailable:
                Text(LimitsPresentation.chipText(entry.state) ?? "—")
                    .font(Theme.mono(.caption))
                    .foregroundStyle(Theme.slate2)
            }
        }
        .fixedSize()
    }
}

/// 한도 칩을 누르면 여는 자세한 보기. 메뉴바와 같은 LimitsService 를 쓴다.
struct LimitsPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(model.limitEntries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider() }
                LimitSection(snapshot: entry.snapshot, accountLabel: entry.accountLabel)
                if entry.snapshot.provider == .codex, let account = model.accounts.account(entry.snapshot.accountID),
                   account.authStatus != .loggedIn {
                    Text("\(account.label): \(account.authStatus.koreanName)"
                         + (account.identityNote.map { " — \($0)" } ?? ""))
                        .font(Theme.ui(.caption)).foregroundStyle(Theme.amberText)
                }
            }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Button {
                    Task { await model.limits.refreshAll(force: true) }
                } label: { Label("새로고침", systemImage: "arrow.clockwise") }
                .disabled(!model.limits.isRefreshing.isEmpty)
                .help("한도 새로고침 (⇧⌘R)")
                Spacer()
                Text(LimitsPresentation.refreshRule)
                    .font(Theme.ui(.caption)).foregroundStyle(Theme.slate)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}
