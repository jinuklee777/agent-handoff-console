import Foundation

// 화면의 시간 · 토큰 글은 이 한 형식이다 — 턴 바닥글 · 실행 중 상태 줄의 경과 · 하위 작업 카드 · 에이전트 탭 · 변경사항 탭의
// 실행 중 줄 · 툴바 도움말 · 인계 줄이 같이 쓴다. SwiftUI 없이 (검증 하네스가 컴파일한다). `Fmt.tokens` · `Fmt.compactDuration`
// · `Fmt.duration` 은 이것을 부른다. 새 화면 글도 여기의 함수를 쓴다 — 비슷한 형식을 따로 만들지 않는다.
//
// 시간은 한국어 단위 하나: "0.9초" · "12초" · "1분 05초" · "1시간 2분". 영어 단위(ms · s · m)를 섞지 않는다.
// 토큰은 수만: "842" · "1.2천" · "26.7만" · "1.3억" — "토큰" 은 부르는 쪽이 붙인다 ("새 토큰 1.2만", "약 598 토큰").

enum DisplayFormat {
    /// 걸린 시간 (밀리초): 10초 안은 소수 한 자리 ("0.9초" · "9.9초"), 그 위는 `elapsed` 와 같다 ("12초" · "1분 05초").
    /// 소수는 내린다 — 9.96초가 "10.0초" 로 보이고 바로 다음이 "10초" 가 되지 않게. 0.1초보다 짧으면 "0.1초", 0 은 "0초".
    static func duration(ms: Int) -> String {
        let ms = max(0, ms)
        if ms == 0 { return "0초" }
        if ms < 10_000 {
            let tenths = max(1, ms / 100)
            return "\(tenths / 10).\(tenths % 10)초"
        }
        return elapsed(seconds: ms / 1000)
    }

    /// 지난 시간 (초): "0초" · "59초" · "1분 05초" · "59분 59초" · "1시간 0분". 1초마다 세는 시계(`ElapsedText`)도 이것.
    static func elapsed(seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)초" }
        if s < 3600 { return String(format: "%d분 %02d초", s / 60, s % 60) }
        return "\(s / 3600)시간 \(s % 3600 / 60)분"
    }

    /// 1초마다 바뀌는 시계가 미리 잡을 폭의 표본 (초) — 지금부터 한 시간 뒤까지 가장 넓은 글. 지금 값과 한 시간 뒤 값만 재면
    /// "59분 59초" 가 "1시간 0분" 보다 넓어 10분 · 1시간 사이에 글이 잘렸다 (`ElapsedText.sizeThatFits`).
    static func elapsedWidthSamples(from now: Int) -> [Int] {
        let now = max(0, now)
        return [now, max(now, 3_599), now + 3_600]
    }

    /// 남은 시간 (초): "1분" (1분보다 짧아도) · "45분" · "1시간 16분" · "3일 2시간".
    static func remaining(seconds: Int) -> String {
        let minutes = max(1, seconds / 60)
        if minutes < 60 { return "\(minutes)분" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)시간 \(minutes % 60)분" }
        return "\(hours / 24)일 \(hours % 24)시간"
    }

    /// API 환산 비용: "$0.12" · 1센트보다 작으면 "$0.0042" · "$0.00". 모르면 "금액 미확인". 늘 "API 환산" 임을 문맥에서 밝힌다
    /// (구독의 실제 청구액이 아니다).
    static func cost(_ value: Double?) -> String {
        guard let value else { return "금액 미확인" }
        if value == 0 { return "$0.00" }
        if value < 0.01 { return String(format: "$%.4f", value) }
        return String(format: "$%.2f", value)
    }

    /// 펼친 내역의 정확한 수: "1,234".
    static func exactTokens(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "ko_KR")
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// 토큰 수 (단위 "토큰" 은 붙이지 않는다): 1천 아래는 그대로, 1만 아래는 천, 1억 아래는 만, 그 위는 억 — 소수 한 자리(내림,
    /// .0 은 뺀다). "1.2천" · "1만" · "26.7만" · "123.4만" · "1.3억".
    static func tokens(_ n: Int) -> String {
        let n = max(0, n)
        func scaled(_ unit: Int, _ name: String) -> String {
            let tenths: Int = n / (unit / 10)
            let whole: Int = tenths / 10, fraction: Int = tenths % 10
            if fraction == 0 { return "\(whole)\(name)" }
            return "\(whole).\(fraction)\(name)"
        }
        if n < 1_000 { return "\(n)" }
        if n < 10_000 { return scaled(1_000, "천") }
        if n < 100_000_000 { return scaled(10_000, "만") }
        return scaled(100_000_000, "억")
    }
}

extension UsageRecord {
    /// 이번 턴에 새로 처리한 토큰 — 입력(캐시 제외) + 출력. 캐시에서 다시 읽은 토큰 · 캐시에 쓴 토큰은 뺀다 (턴 바닥글 한 줄).
    /// Claude Code 는 시스템 프롬프트 · 도구 정의를 도구를 부를 때마다 캐시에서 다시 읽어, 그것까지 센 `totalTokens` 는 짧은 턴도
    /// 수십만이 됐다.
    var newTokens: Int { inputTokens + outputTokens }
}
