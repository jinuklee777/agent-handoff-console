import AppKit
import SwiftUI

// MARK: - 표시 형식

enum Fmt {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 대화 머리글의 시각 — 초는 도움말에만 (`time`).
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "HH:mm"
        return f
    }()

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 HH:mm"
        return f
    }()

    // 시간 · 토큰 · 비용의 글은 화면 공용 형식 하나 (`DisplayFormat` — SwiftUI 없이 검증 하네스가 컴파일한다).

    /// "842" · "1.2천" · "26.7만" — 단위 "토큰" 은 부르는 쪽이 붙인다.
    static func tokens(_ n: Int) -> String { DisplayFormat.tokens(n) }

    /// "0.9초" · "12초" · "1분 05초" · "1시간 2분".
    static func duration(ms: Int) -> String { DisplayFormat.duration(ms: ms) }

    /// 비용 표시. 항상 "API 환산" 임을 문맥에서 밝힌다.
    static func cost(_ v: Double?) -> String { DisplayFormat.cost(v) }

    static func percent(_ v: Double?) -> String {
        guard let v else { return "정보 없음" }
        return String(format: "%.0f%%", v * 100)
    }

    static func resetText(_ date: Date?) -> String {
        guard let date else { return "초기화 시각 미확인" }
        return "초기화 " + dateTime.string(from: date)
    }

    /// 메타 줄의 걸린 시간 — `duration` 과 같은 형식 (영어 단위를 섞지 않는다).
    static func compactDuration(ms: Int) -> String { DisplayFormat.duration(ms: ms) }

    /// 초기화까지 남은 시간 ("1시간 16분" · "3일 2시간"). 지났거나 모르면 nil.
    static func remaining(until date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return nil }
        return DisplayFormat.remaining(seconds: seconds)
    }

    /// `2시간 전` 같은 상대 시각.
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "시각 미확인" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }

    /// 경로를 `~/…` 로 줄인다.
    static func abbreviatedPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - 제공자 표현

extension AgentProvider {
    /// Claude 테라코타, Codex 잉크. 색만으로 구분하지 않도록 항상 로고·이름과 함께 쓴다.
    var tint: Color {
        switch self {
        case .claude: return Theme.claude
        case .codex:  return Theme.ink
        case .gemini: return Theme.gemini
        }
    }

    var symbolName: String {
        switch self {
        case .claude: return "asterisk"
        case .codex:  return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "sparkle"
        }
    }
}

/// 제공자 + Codex 계정을 함께 보여주는 칩.
/// 계정이 하나뿐이면 계정 이름을 붙이지 않아 화면이 지저분해지지 않게 한다.
struct PartyBadge: View {
    let provider: AgentProvider
    var accountLabel: String?

    var body: some View {
        HStack(spacing: 4) {
            ProviderBadge(provider: provider)
            if let accountLabel, !accountLabel.isEmpty {
                Text(accountLabel)
                    .font(Theme.ui(.caption, .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(HandoffPacket.partyName(provider, accountLabel))
    }
}

/// 로고 + 이름. 색만으로 상태를 전달하지 않는다.
struct ProviderBadge: View {
    let provider: AgentProvider
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            BrandMark(provider: provider, size: compact ? 12 : 13)
            if !compact {
                Text(provider.displayName)
                    .font(Theme.ui(.caption, .semibold))
                    .foregroundStyle(Theme.ink)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(provider.displayName)
    }
}

struct RunStateBadge: View {
    let state: RunState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.symbolName)
                .font(.system(size: 10))
            Text(state.koreanName)
                .font(Theme.ui(.caption))
        }
        .foregroundStyle(color)
        .accessibilityLabel("실행 상태 \(state.koreanName)")
    }

    private var color: Color { state.tint }
}

extension RunState {
    /// 상태 글자색 (아이콘과 함께). 항상 상태 이름과 함께 쓴다 — 글자용 토큰만 (`amberText` · `emeraldText` · `claudeText`):
    /// 점 · 막대에 쓰는 `amber` · `emerald` · `claude` 는 흰 바탕에서 3.1~3.8:1 이라 작은 글자로 흐렸다 (copy-4).
    var tint: Color {
        switch self {
        case .completed: return Theme.emeraldText
        case .failed: return Theme.danger
        case .rateLimited, .awaitingApproval, .handoffDeliveryUnknown: return Theme.amberText
        case .running, .starting, .interrupting, .handoffSending: return Theme.claudeText
        default: return Theme.slate
        }
    }
}

// MARK: - 접을 수 있는 블록

struct CollapsibleText: View {
    let text: String
    var monospaced = true
    var collapsedByDefault = true
    var previewLines = 3

    @State private var expanded = false

    private var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }

    private var isLong: Bool { lines.count > previewLines || text.count > 400 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isLong && !expanded && collapsedByDefault {
                Text(lines.prefix(previewLines).joined(separator: "\n"))
                    .font(monospaced ? Theme.mono(.caption) : Theme.ui(.callout))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Button {
                    expanded = true
                } label: {
                    Label("전체 보기 (\(lines.count)줄)", systemImage: "chevron.down")
                        .font(Theme.ui(.caption))
                }
                .buttonStyle(.link)
            } else {
                Text(text)
                    .font(monospaced ? Theme.mono(.caption) : Theme.ui(.callout))
                    .textSelection(.enabled)
                if isLong && collapsedByDefault {
                    Button {
                        expanded = false
                    } label: {
                        Label("접기", systemImage: "chevron.up").font(Theme.ui(.caption))
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }
}

/// 한도 표시 막대. 값이 없으면 0% 가 아니라 "정보 없음" 으로 표시한다.
struct LimitBar: View {
    let window: LimitWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(window.label).font(Theme.ui(.caption))
                Spacer()
                Text(Fmt.percent(window.utilization))
                    .font(Theme.digits(.caption))
                    .foregroundStyle(window.utilization == nil ? .secondary : .primary)
            }
            if let u = window.utilization {
                ProgressView(value: min(max(u, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(LimitMeter.color(for: u))
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        Text("정보 없음").font(Theme.ui(.caption)).foregroundStyle(.secondary)
                            .padding(.leading, 3)
                    }
            }
            if let raw = window.rawText, !raw.isEmpty {
                Text(raw).font(Theme.ui(.caption)).foregroundStyle(.secondary)
            } else if let r = window.resetsAt {
                Text(Fmt.resetText(r)).font(Theme.ui(.caption)).foregroundStyle(.secondary)
            }
        }
    }
}

/// 한도 팝오버 · 메뉴바의 계정 하나. 아직 읽지 않은 한도(첫 프로젝트 뒤로 미룸 · 설정에서 끔 · 읽는 중)는 실패로 적지 않는다 —
/// 글은 `LimitsPresentation` (사실은 환경의 `AppModel` 에서 — 부르는 두 곳 모두 넣어 준다).
struct LimitSection: View {
    @Environment(AppModel.self) private var model
    let snapshot: LimitSnapshot
    var showRawOnFailure = true
    /// Codex 계정 이름. 계정이 둘 이상일 때 어느 계정의 한도인지 밝힌다.
    var accountLabel: String?
    /// 그릴 구간 — 메뉴바는 숨긴 구간을 뺀 것을 넘긴다 (`MenuBarLimits`). nil 이면 전부.
    var windows: [LimitWindow]?

    var body: some View {
        let state = LimitsPresentation.state(snapshot, context: model.limitContext(for: snapshot.scope))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderBadge(provider: snapshot.provider)
                if let accountLabel, !accountLabel.isEmpty {
                    Text(accountLabel)
                        .font(Theme.ui(.caption, .medium))
                        .lineLimit(1)
                }
                Text(LimitsPresentation.statusName(state, snapshot: snapshot))
                    .font(Theme.ui(.caption))
                    .foregroundStyle(LimitsPresentation.isWarning(state, snapshot: snapshot) ? Theme.amberText : Color.secondary)
                Spacer()
                if let at = snapshot.fetchedAt {
                    Text(LimitsPresentation.checked(at))
                        .font(Theme.digits(.caption))
                        .foregroundStyle(.secondary)
                        .help("마지막 확인 " + Fmt.dateTime.string(from: at))
                }
            }
            if snapshot.windows.isEmpty {
                Text(LimitsPresentation.note(state) ?? "")
                    .font(Theme.ui(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(windows ?? snapshot.windows) { LimitBar(window: $0) }
            }
            if let plan = snapshot.planType {
                Text("플랜: \(plan)").font(Theme.ui(.caption)).foregroundStyle(.secondary)
            }
            if showRawOnFailure, snapshot.status == .noData, let raw = snapshot.rawResponse {
                DisclosureGroup("원문 확인") {
                    Text(JSONUtil.truncate(raw, max: 3000))
                        .font(Theme.mono(.caption))
                        .textSelection(.enabled)
                }
                .font(Theme.ui(.caption))
            }
        }
    }
}


// MARK: - 코드 · 명령을 쓰는 입력칸

/// 에이전트에게 보내는 글 · 커밋 메시지 · 인계 문서처럼 코드와 명령이 섞이는 입력칸에서 macOS 의 스마트 따옴표 · 대시 ·
/// 텍스트 대치 · 자동 고침을 끈다. 시스템 기본이 켜짐이라 직접 친 `--flag` 가 `—flag`, "…" 가 “…” 로 바뀌어 나간다.
/// (편집 메뉴의 대치 메뉴는 ⌘F 를 스레드 검색에 쓰느라 `.textEditing` 묶음째 바꿔 없다 — 그래서 칸마다 끈다.)
enum PlainTextInput {
    static func apply(to textView: NSTextView) {
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
    }
}

extension View {
    /// 이 `TextEditor` 의 텍스트 뷰에 `PlainTextInput` 을 적용한다 (TextEditor 에 바로 붙인다).
    /// SwiftUI 는 글이 바뀌어 다시 그릴 때 자동 고침을 도로 켜므로 `autocorrectionDisabled` 도 함께 건다.
    func plainTextInput() -> some View { autocorrectionDisabled().background(PlainTextInputProbe()) }
}

/// `TextEditor` 뒤에 깔려, 겹쳐 있는 편집용 NSTextView 를 찾아 `PlainTextInput` 을 적용한다.
private struct PlainTextInputProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ nsView: ProbeView, context: Context) { nsView.apply() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ProbeView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class ProbeView: NSView {
        private weak var textView: NSTextView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // TextEditor 의 텍스트 뷰는 같은 배치 차례에 만들어진다 — 다음 런루프에서 찾는다.
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        override func layout() {
            super.layout()
            apply()
        }

        func apply() {
            guard window != nil else { return }
            if textView == nil || textView?.window == nil { textView = find() }
            if let textView { PlainTextInput.apply(to: textView) }
        }

        /// 조상을 몇 단계 올라가며, 이 뷰와 겹쳐 있는 편집용 텍스트 뷰(필드 에디터 제외)를 찾는다.
        private func find() -> NSTextView? {
            let own = convert(bounds, to: nil)
            var ancestor = superview
            var depth = 0
            while let current = ancestor, depth < 6 {
                if let found = Self.textView(in: current, overlapping: own, excluding: self) { return found }
                ancestor = current.superview
                depth += 1
            }
            return nil
        }

        private static func textView(in view: NSView, overlapping rect: NSRect, excluding: NSView) -> NSTextView? {
            if let textView = view as? NSTextView, !textView.isFieldEditor, textView.isEditable {
                // bounds 는 스크롤로 가려진 부분까지 담은 문서 전체라 보이는 부분으로 겹침을 본다.
                return textView.convert(textView.visibleRect, to: nil).intersects(rect) ? textView : nil
            }
            for sub in view.subviews where sub !== excluding {
                if let found = textView(in: sub, overlapping: rect, excluding: excluding) { return found }
            }
            return nil
        }
    }
}
