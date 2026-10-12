import Foundation
import Observation

// Dock 배지 — 사람을 기다리는 대화 수 (사이드바 행 단위). AppKit 을 모른다: 배지를 그리는 일(`NSApp.dockTile`)은 앱 층의 `apply` 가 한다.

enum AttentionBadge {
    /// 후보 대화 ID 를 사이드바 행 단위로 고친다: 내부 대화(자동 작업의 계획 · 하위 작업)는 그 부모 대화로 바꾸고 겹친 것을 뺀다.
    /// 부모를 모르는 내부 대화는 뺀다 — 사이드바에 없는 대화를 세지 않는다. 처음 나온 순서를 지킨다.
    static func rows(_ ids: [String], isInternal: (String) -> Bool, parentOf: (String) -> String?) -> [String] {
        var seen = Set<String>()
        var rows: [String] = []
        for id in ids {
            let row = isInternal(id) ? parentOf(id) : id
            guard let row, seen.insert(row).inserted else { continue }
            rows.append(row)
        }
        return rows
    }

    /// 배지 글자. 0 이면 지운다.
    static func label(_ count: Int) -> String? {
        count > 0 ? String(count) : nil
    }
}

// MARK: - 메뉴바

/// 메뉴바 아이콘이 알리는 것 (`MenuBarIndicator` 가 기호 · 글로 그린다). 우선순위: 사람을 기다림 → 실행 중 → 확인 필요 → 대기.
enum MenuBarState: Equatable, Sendable {
    case idle, running, needsResponse, problem
}

/// "확인 필요" 의 까닭 한 줄 (메뉴바 팝오버 머리 아래). 대화의 일이면 누르면 그 대화로 간다.
struct MenuBarProblem: Equatable, Sendable, Identifiable {
    var text: String
    var threadID: String?
    var id: String { (threadID ?? "-") + "|" + text }
}

/// 메뉴바의 순수 판정 — 사실은 `MenuBarIndicator.from(model:)` 이 모은다.
enum MenuBarStatus {
    /// 사람이 아직 보지 않은, 오류 · 한도로 끝난 실행 (`AppModel.unseenRunProblems`). 그 대화를 열면 빠진다.
    struct UnseenRun: Equatable, Sendable {
        var threadID: String
        var title: String
        var state: RunState
    }

    static func state(attention: Int, running: Int, problems: [MenuBarProblem]) -> MenuBarState {
        if attention > 0 { return .needsResponse }
        if running > 0 { return .running }
        return problems.isEmpty ? .idle : .problem
    }

    /// "확인 필요" 의 까닭들 — 보지 않은 실행 → 한도에 닿은 계정 → 로그인 문제 → 종료 미확인 프로세스. 실행의 일은 그 대화로 갈 수 있다.
    /// `cappedAccounts` · `authProblemAccounts` 는 화면 이름 ("Claude" · "Codex · 계정2").
    static func problems(unseenRuns: [UnseenRun], cappedAccounts: [String], authProblemAccounts: [String],
                         unterminated: Int) -> [MenuBarProblem] {
        var out: [MenuBarProblem] = []
        for run in unseenRuns {
            let what: String
            switch run.state {
            case .rateLimited: what = "사용 한도에 닿아 멈췄습니다"
            case .handoffDeliveryUnknown: what = "인계가 전달됐는지 확인하지 못했습니다"
            default: what = "마지막 실행이 오류로 끝났습니다"
            }
            out.append(MenuBarProblem(text: "\(run.title) — \(what)", threadID: run.threadID))
        }
        for account in cappedAccounts {
            out.append(MenuBarProblem(text: "\(account) 사용 한도에 닿았습니다", threadID: nil))
        }
        for account in authProblemAccounts {
            out.append(MenuBarProblem(text: "\(account) 로그인을 확인하세요 (설정 > 에이전트)", threadID: nil))
        }
        if unterminated > 0 {
            out.append(MenuBarProblem(text: "종료가 확인되지 않은 프로세스 \(unterminated)개 — 대화의 안내를 보세요", threadID: nil))
        }
        return out
    }

    /// 메뉴바가 "확인 필요" 로 세는 실행 결과 (끝난 실행의 상태).
    static func isProblem(_ state: RunState) -> Bool {
        state == .failed || state == .rateLimited || state == .handoffDeliveryUnknown
    }
}

/// 수를 지켜보다 바뀔 때만 `apply` 를 부른다. `withObservationTracking` 의 `onChange` 는 값이 바뀌기 **전**(willSet)에 오므로
/// 거기서 읽지 않고, 다음 차례(`Task { @MainActor }`)에 다시 걸면서 읽는다. 시작은 한 번 — 다시 부르면 무시한다.
@MainActor
final class AttentionBadgeObserver {
    private let read: @MainActor () -> Int
    private let apply: @MainActor (Int) -> Void
    private var last: Int?
    private var started = false

    init(read: @escaping @MainActor () -> Int, apply: @escaping @MainActor (Int) -> Void) {
        self.read = read
        self.apply = apply
    }

    func start() {
        guard !started else { return }
        started = true
        observe()
    }

    private func observe() {
        let value = withObservationTracking { read() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        guard value != last else { return }
        last = value
        apply(value)
    }
}
