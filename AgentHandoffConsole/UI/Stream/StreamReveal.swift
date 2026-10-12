import Foundation

/// 흐르는 응답을 **고른 속도로** 풀어 보일 글자 수의 순수 판정 (SwiftUI 없이 — 검증 하네스가 컴파일한다).
///
/// CLI 는 몇 글자에서 수십 글자를 몰아 보내다 쉬기를 되풀이한다. 받은 대로 그리면 글이 와르르 붙었다 멈췄다 해 딱딱하게 보였다
/// (2026-10-06 사용자 의견). 받은 글을 잠깐 모아 두고, 밀린 양에 비례한 속도로 푼다 — 밀린 글이 많으면 빨리, 적으면 천천히,
/// 그래서 보이는 글은 받은 글보다 대개 `lag` 남짓 늦다. 응답이 끝나면(또는 멈추면) 남은 글을 빨리 마저 보인다.
/// 이것을 쓰는 곳은 텍스트 뷰다 (`MarkdownTextView` 의 `render(… reveal:)` — 그린 글의 UTF-16 단위). 받은 글은 다 그려 두고,
/// 이 일정(`Schedule`)대로 줄마다 가림막이 열리는 애니메이션을 Core Animation 에 맡긴다 — 메인 스레드가 바빠도 글이 고르게 흐른다.
/// 앞선 두 구현의 실측 (2026-10-06, 최적화 빌드):
/// - 보일 글을 SwiftUI 로 초당 30번 넘겼더니 대화 전체를 다시 배치해 조각이 띄엄띄엄 올 때 CPU 가 16% → 45%.
/// - 텍스트 뷰가 화면 주기마다 직접 그렸더니 CPU 는 괜찮았지만, 실제 긴 대화(기록 1030개)에서는 조각마다의 화면 갱신이 메인 스레드를
///   수십 ms 씩 붙잡아 주기가 밀렸다 (목표 33ms 에 가운데 값 44ms · 50ms 넘음 15 ~ 21% · 가장 늦은 것 0.1 ~ 0.2초) — 글이 뚝뚝 끊겼다.
enum StreamReveal {
    /// 밀린 글을 이만큼에 걸쳐 푼다 (초). 클수록 부드럽고 늦다.
    static let lag: Double = 0.45
    /// 밀린 글이 적을 때의 가장 느린 속도 (초당 글자). 이보다 느리면 끝의 몇 글자가 늘어진다.
    static let minimumRate: Double = 24
    /// 응답이 끝난 뒤 남은 글을 푸는 시간 · 가장 느린 속도 — 끝난 답을 오래 붙잡지 않는다.
    static let finishingLag: Double = 0.12
    static let finishingMinimumRate: Double = 160

    /// `elapsed` 초가 지난 뒤 보일 글자 수 (소수 — 남은 몫을 다음 차례로 넘긴다). `total` 을 넘지 않는다.
    /// - Parameters:
    ///   - shown: 지금 보이는 글자 수 (소수).
    ///   - total: 받은 글자 수.
    ///   - finished: 응답이 끝났다 (더 오지 않는다).
    static func advance(shown: Double, total: Int, elapsed: Double, finished: Bool) -> Double {
        let total = Double(total)
        guard shown < total else { return total }
        guard elapsed > 0 else { return max(0, shown) }
        let backlog = total - max(0, shown)
        let rate = finished
            ? max(finishingMinimumRate, backlog / finishingLag)
            : max(minimumRate, backlog / lag)
        return min(total, max(0, shown) + rate * elapsed)
    }

    /// 지금 보이는 데서부터 받은 끝까지의 풀기 일정 — `step` 초마다의 보일 길이. 텍스트 뷰가 이것으로 가림막의 키프레임을 짓고,
    /// 새 조각이 오면 그때 보이는 길이(`shown(at:)`)에서 다시 짠다.
    struct Schedule: Equatable {
        /// 일정 사이의 간격 (초). Core Animation 이 그 사이를 화면 주기마다 잇는다.
        static let step: Double = 1.0 / 30
        /// 일정이 이보다 길면 끝을 붙여 마친다 (초).
        static let limit: Double = 8

        /// 시작한 때 (`CACurrentMediaTime` 과 같은 시계).
        let start: Double
        /// `step` 초마다의 보일 길이. 첫 값은 시작할 때 보이던 길이, 끝 값은 받은 길이.
        let values: [Double]

        init(start: Double, from shown: Double, total: Int, finished: Bool) {
            self.start = start
            let goal = Double(max(0, total))
            var value = min(max(0, shown), goal)
            var values = [value]
            while value < goal, Double(values.count) * Self.step < Self.limit {
                value = StreamReveal.advance(shown: value, total: total, elapsed: Self.step, finished: finished)
                values.append(value)
            }
            if value < goal { values.append(goal) }
            self.values = values
        }

        /// 시작할 때 보이던 길이.
        var from: Double { values[0] }
        /// 다 보이는 때.
        var end: Double { start + Self.step * Double(values.count - 1) }

        /// 그때 보이는 길이 (일정 사이는 직선으로 잇는다 — Core Animation 과 같다).
        func shown(at time: Double) -> Double {
            let position = (time - start) / Self.step
            guard position > 0 else { return values[0] }
            let index = Int(position)
            guard index + 1 < values.count else { return values[values.count - 1] }
            let fraction = position - Double(index)
            return values[index] + (values[index + 1] - values[index]) * fraction
        }
    }

    /// 처음 볼 때 이미 받아 둔 글을 처음부터 풀지 — 막 시작한 응답(첫 조각)만 푼다. 대화를 다시 열었을 때처럼 이미 흐르던
    /// 응답은 지금까지의 글을 곧바로 보이고 그 뒤로 오는 글만 푼다 (다시 흘려 보이지 않는다).
    static let freshWindow: TimeInterval = 1.5

    static func startsFromBeginning(createdAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(createdAt) < freshWindow
    }
}
