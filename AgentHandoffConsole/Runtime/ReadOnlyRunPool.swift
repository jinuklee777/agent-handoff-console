import Foundation
import Observation

/// 검토 레인: 읽기 전용 턴만 받는 실행 자리 몇 개. 자동 작업의 검토단이 동시에 검토할 때 쓴다.
///
/// 앱의 실행 슬롯(`AppModel.runner`)과 따로 둔 `RunCoordinator` 하나다 — 파일을 바꾸는 실행과 화면(입력창 · 승인 · 중단 ·
/// git 잠금)은 `runner` 를 보고, 레인의 실행은 파일을 바꾸지 못하므로(`AgentTurnOptions.readOnly`, CLI 가 막는다) 서로 부딪히지
/// 않는다. 지켜보는 화면이 없으므로 승인 · 질문을 기다리지 않는다 (`RunCoordinator.unattended`).
/// 레인이 도는 동안 쓰기 실행과 앱의 git 쓰기를 막는 것은 부르는 쪽(`AppModel`)의 일이다 — 검토가 움직이는 폴더를 읽지 않게.
@MainActor
@Observable
final class ReadOnlyRunPool {
    nonisolated static let defaultLaneCount = 3

    /// 레인의 실행을 묶는 코디네이터. 대리자가 받는 완료 통지의 `c` 가 이것이다 (`owns`).
    let coordinator: RunCoordinator

    init(store: Store, environment: CLIEnvironment, laneCount: Int = ReadOnlyRunPool.defaultLaneCount) {
        coordinator = RunCoordinator(store: store, environment: environment)
        coordinator.unattended = true
        coordinator.maxConcurrentRuns = max(1, laneCount)
    }

    var isBusy: Bool { coordinator.isBusy }
    var hasFreeLane: Bool { coordinator.hasCapacity }
    var activeSessions: [RunSession] { coordinator.activeSessions }
    var activeRuns: [Run] { coordinator.activeSessions.compactMap(\.activeRun) }
    /// 끝났는지 확인하지 못한 레인의 프로세스.
    var unterminatedProcesses: [String] { coordinator.unterminatedProcesses }

    func owns(_ coordinator: RunCoordinator) -> Bool { self.coordinator === coordinator }

    /// 레인에 설정을 넣는다 (대리자 · 기본 강도 · 가짜 어댑터).
    func configure(_ apply: (RunCoordinator) -> Void) { apply(coordinator) }

    func loadPrices() async { await coordinator.loadPrices() }

    /// 빈 레인에서 읽기 전용 턴을 시작한다. 빈 레인이 없거나 그 대화의 실행이 이미 돌고 있으면 `RunCoordinator.StartError.busy`.
    func send(prompt: String, thread: ConversationThread, project: Project, provider: AgentProvider,
              account: CodexAccountRef?, turn: AgentTurnOptions) async throws -> Run {
        guard turn.readOnly else { throw RunCoordinator.StartError.unattendedNeedsReadOnly }
        return try await coordinator.send(prompt: prompt, thread: thread, project: project, provider: provider,
                                          account: account, turn: turn)
    }

    func interruptAll() async { await coordinator.interruptAll() }

    /// 앱 종료 시 정리. 하나라도 종료를 확인하지 못하면 false.
    func shutdownForQuit() async -> Bool { await coordinator.shutdownForQuit() }
}
