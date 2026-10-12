import Foundation
import Observation

/// 한 대화의 화면 상태: 이벤트 · 실행 · 사용량 · 인계 · 평가. 대화마다 하나다.
///
/// `AppModel` 에 "선택된 대화 하나 분"으로 있던 값이다. 대화별로 떼어 낸 이유:
/// - 선택되지 않은 대화의 실시간 출력을 버리지 않는다 — 다른 대화로 옮겼다 돌아와도, 분할 화면의 다른 칸에서도 이어진다.
/// - 분할 화면에서 한 칸의 스트리밍이 다른 칸을 다시 그리게 하지 않는다 (`@Observable` 이 대화마다 따로다).
///
/// `AppModel.threadStates` 가 들고 있다: 화면에 열린 대화와 실행이 도는 대화의 것만 (`AppModel.pruneThreadStates`).
@MainActor
@Observable
final class ThreadPaneModel {
    let threadID: String

    /// 이 대화의 이벤트 전부 (순번순) — 하위 에이전트 안의 일과 하위 상태 행도 들어 있다. 편집한 파일 · 터미널 탭 ·
    /// 인계처럼 "이 대화에서 일어난 일" 을 보는 곳이 쓴다. 대화 스트림은 `mainEvents` 를 본다.
    private(set) var events: [ThreadEvent] = []
    /// 메인 흐름의 이벤트 (`ThreadEvent.isMainStream`, 순번순) — 대화 스트림 · 행 캐시 · 스크롤 따라가기가 본다.
    /// 따로 두는 이유: 하위 에이전트의 조각이 메인 스트림을 다시 묶게 하지 않고(`@Observable` 이 속성마다 따로다),
    /// 메인의 흐르는 글이 "마지막 이벤트" 에서 밀려나 화면에서 멈추지 않게.
    private(set) var mainEvents: [ThreadEvent] = []
    /// 하위 에이전트 안에서 일어난 일 (하위 id → 순번순 이벤트). 인스펙터 "에이전트" 탭 · 카드의 요약이 본다.
    private(set) var subAgentEvents: [String: [ThreadEvent]] = [:]
    /// 하위 작업의 마지막 저장 상태 (`.subAgent` 행의 해석, 하위 id → 정보). 진행(토큰 · 도구 수)은 저장 때의 값이다 —
    /// 살아 있는 실행의 진행은 `RunSession.subAgents` 에 있다.
    private(set) var subAgentInfos: [String: SubAgentInfo] = [:]
    /// 하위 작업을 띄운 실행 (하위 id → 실행 id).
    private(set) var subAgentRunIDs: [String: String] = [:]
    /// 하위 쪽(`subAgentEvents` · `subAgentInfos` · `subAgentRunIDs`)이 바뀔 때마다 는다. 대화 스트림은 이 수로 하위 요약을
    /// 다시 만들지 정한다 — 메인 글이 자랄 때마다 대화 전체의 하위 기록을 훑지 않게.
    private(set) var subAgentRevision = 0
    /// 지금 흐르는 메인 이벤트의 ID. 흐르는 응답은 메인 흐름의 마지막이 아닐 수 있다 — 하위가 청한 승인 · 질문, 하위가 끝날
    /// 때의 앵커 결과는 메인 글을 닫지 않고 그 뒤에 저장된다 (`RunSession`). 행 캐시 · 스크롤 따라가기가 이것을 본다.
    private(set) var streamingMainID: String?

    /// 지금 흐르는 메인 이벤트 (없으면 nil). 뒤에서 찾는다 — 흐르는 응답은 끝 가까이에 있다.
    var streamingMainEvent: ThreadEvent? {
        guard let id = streamingMainID else { return nil }
        return mainEvents.last { $0.id == id }
    }
    var usageByRun: [String: UsageRecord] = [:]
    var runsByID: [String: Run] = [:]
    var handoffs: [Handoff] = []
    var ratingsByRun: [String: Rating] = [:]
    var ratingsByHandoff: [String: Rating] = [:]
    /// 저장소에서 한 번이라도 읽었다. 읽기 전에 온 실시간 이벤트는 받아 두되, 읽은 결과가 그것을 덮는다 (저장소가 기준).
    private(set) var loaded = false
    @ObservationIgnored private var reloadSerial = 0
    /// 맨 아래로 내려 달라는 요청 — 사람이 보냈거나 대기열에 넣을 때 는다. 위로 올려 읽던 중이어도 대화 칸이 끝으로 간다.
    private(set) var scrollToBottomRequest = 0

    init(threadID: String) {
        self.threadID = threadID
    }

    func requestScrollToBottom() { scrollToBottomRequest += 1 }

    /// 저장소에서 다시 읽는다. 겹쳐 부르면 마지막에 시작한 읽기만 반영한다.
    func reload(store: Store) async {
        reloadSerial += 1
        let serial = reloadSerial
        let loadedEvents = (try? await store.events(threadID: threadID)) ?? []
        let loadedHandoffs = (try? await store.handoffs(threadID: threadID)) ?? []
        let usage = (try? await store.usage(threadID: threadID)) ?? []
        let runs = (try? await store.runs(threadID: threadID)) ?? []
        let ratings = (try? await store.ratings(threadID: threadID)) ?? []
        guard serial == reloadSerial else { return }

        // 스트리밍 중인 응답은 일정 길이마다만 저장된다 — 저장소의 글이 화면의 글보다 짧다. 읽은 목록을 쓰되
        // 지금 흐르고 있는 응답은 메모리의 것을 남긴다 (다시 읽는 순간 글이 뒤로 가지 않게).
        let streaming = Dictionary(events.filter(\.isStreaming).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let known = Set(loadedEvents.map(\.id))
        let merged = loadedEvents.map { loaded in
            guard loaded.isStreaming, let live = streaming[loaded.id], live.text.count >= loaded.text.count else { return loaded }
            return live
        }
        events = (merged + streaming.values.filter { !known.contains($0.id) }).sorted { $0.seq < $1.seq }
        partition()
        handoffs = loadedHandoffs
        usageByRun = Dictionary(usage.map { ($0.runID, $0) }, uniquingKeysWith: { _, new in new })
        runsByID = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var byRun: [String: Rating] = [:], byHandoff: [String: Rating] = [:]
        for rating in ratings {
            if let runID = rating.runID { byRun[runID] = rating }
            if let handoffID = rating.handoffID { byHandoff[handoffID] = rating }
        }
        ratingsByRun = byRun
        ratingsByHandoff = byHandoff
        loaded = true
    }

    /// 실시간으로 온 이벤트. 같은 ID 면 바꾸고, 새것이면 순번 자리에 넣는다. 메인 · 하위 · 하위 상태 중 제자리에도 넣는다
    /// (한 이벤트가 어느 쪽인지는 처음 저장할 때 정해져 바뀌지 않는다 — 부모 표시는 첫 저장의 payload 에 있다).
    func upsert(_ event: ThreadEvent) {
        guard event.threadID == threadID else { return }
        Self.place(event, in: &events)
        if event.kind == .subAgent {
            guard let info = event.subAgentInfo else { return }
            subAgentInfos[info.id] = info
            if let runID = event.runID { subAgentRunIDs[info.id] = runID }
            subAgentRevision += 1
        } else if let parent = event.parentAgentID {
            var list = subAgentEvents[parent] ?? []
            Self.place(event, in: &list)
            subAgentEvents[parent] = list
            subAgentRevision += 1
        } else {
            Self.place(event, in: &mainEvents)
            if event.isStreaming {
                if streamingMainID != event.id { streamingMainID = event.id }
            } else if streamingMainID == event.id {
                streamingMainID = nil
            }
        }
    }

    /// 같은 ID 면 바꾸고, 새것이면 뒤에 붙인 뒤 순번이 거꾸로면 다시 정렬한다. 스트리밍은 마지막 행이 자라므로 뒤에서 찾는다.
    private static func place(_ event: ThreadEvent, in list: inout [ThreadEvent]) {
        if let index = list.lastIndex(where: { $0.id == event.id }) {
            list[index] = event
        } else {
            list.append(event)
            if let previous = list.dropLast().last, previous.seq > event.seq { list.sort { $0.seq < $1.seq } }
        }
    }

    /// `events` 를 메인 · 하위 · 하위 상태로 나눈다 (다시 읽을 때 한 번).
    private func partition() {
        let parts = Self.partition(events)
        mainEvents = parts.main
        subAgentEvents = parts.children
        subAgentInfos = parts.infos
        subAgentRunIDs = parts.runIDs
        subAgentRevision += 1
        streamingMainID = mainEvents.last(where: \.isStreaming)?.id
    }

    /// 순번순 이벤트를 메인 흐름 · 하위 에이전트별 흐름 · 하위 상태로 나눈다 (순수 — 검증이 쓴다).
    static func partition(_ events: [ThreadEvent]) -> (main: [ThreadEvent], children: [String: [ThreadEvent]],
                                                       infos: [String: SubAgentInfo], runIDs: [String: String]) {
        var main: [ThreadEvent] = []
        var children: [String: [ThreadEvent]] = [:]
        var infos: [String: SubAgentInfo] = [:]
        var runIDs: [String: String] = [:]
        main.reserveCapacity(events.count)
        for event in events {
            if event.kind == .subAgent {
                guard let info = event.subAgentInfo else { continue }
                infos[info.id] = info
                if let runID = event.runID { runIDs[info.id] = runID }
            } else if let parent = event.parentAgentID {
                children[parent, default: []].append(event)
            } else {
                main.append(event)
            }
        }
        return (main, children, infos, runIDs)
    }

    func record(run: Run) {
        guard run.threadID == threadID else { return }
        runsByID[run.id] = run
    }

    func record(usage: UsageRecord) {
        guard usage.threadID == threadID else { return }
        usageByRun[usage.runID] = usage
    }
}
