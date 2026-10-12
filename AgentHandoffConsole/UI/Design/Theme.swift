import AppKit
import SwiftUI

/// 디자인 토큰. 디자인 시안의 토큰 값을 그대로 옮겼다.
///
/// 라이트 값이 원본이다. 다크 값은 원본에 없어서 같은 역할(종이·잉크·규칙선)이 유지되도록 맞춘 대응값이다.
/// 원본과 다른 것: `slate2`(대비를 올렸다)와 `control` · `amberText` · `amberFill` · `emeraldText` · `claudeText`(원본에 없다) — 모두 읽히지
/// 않던 보조 글자 · 아이콘 · 주의 글자 · 주의 단추 · 성공 글자 · 실행 상태 글자 때문이다.
/// 검정은 Claude 앱의 회색 단계(`--cds-gray-*`)로 옮겼다 (2026-10-09, 사용자가 골랐다): 글자 `ink` · `ink2` 는 밝은 화면 #0B0B0B(900) ·
/// #20201F(800), 어두운 화면 #F0EFEC(50) · #E1E0D9(100). 어두운 화면의 바탕은 종이 #151515(850) · 패널 #111111(870 — 종이보다
/// 어둡다) · 카드 #20201F(800), 그 옆의 면(코드 상자 · 입력창 바탕 · 옅은 바탕 · 터미널 프롬프트 줄 · diff 빗금)은 원래의 밝기 순서대로
/// 840 ~ 800. 회색 글자 · 선과 밝은 화면의 바탕은 그대로다.
/// 불꽃색은 MAX, 보라색은 ULTRA 전용이다.
enum Theme {

    // MARK: 색 — 원본 토큰

    static let paper = dynamic(0xFFFFFF, dark: 0x151515)
    static let panel = dynamic(0xFAFAFA, dark: 0x111111)
    static let hair = dynamic(0xE2E8F0, dark: 0x2A313B)
    static let hairSoft = dynamic(0xEFF2F6, dark: 0x20262E)
    static let ink = dynamic(0x0B0B0B, dark: 0xF0EFEC)
    static let ink2 = dynamic(0x20201F, dark: 0xE1E0D9)
    static let slate = dynamic(0x64748B, dark: 0x9AA6B6)
    /// 보조 글자 (시각 · 메타 · 결과 줄 수). 흰 바탕 4.7:1 · 패널 4.5:1 · 입력창 바탕(`well`) 4.5:1 — 11.5pt 글자의 AA.
    /// 원본 #94A3B8(2.6:1)은 10–11pt 글자로 읽히지 않았고, 그다음 값 #6B7A90 도 입력창 바탕에서 4:1 이 안 됐다.
    /// 어두운 화면은 #8591A2 — 카드 5.1:1 · `well` 5.2:1 · 종이 5.7:1 · 패널 5.9:1 (예전 #7B8798 은 그때의 카드 4.5 · `well` 4.4 로 AA 에
/// 못 미쳤다, copy-4).
    static let slate2 = dynamic(0x627187, dark: 0x8591A2)
    /// 장식 전용 (구분점 · 빈 상태의 큰 아이콘). 글자나 누르는 아이콘에 쓰지 않는다 — 흰 바탕 1.5:1.
    static let slate3 = dynamic(0xCBD5E1, dark: 0x4A5563)
    /// 글자 없는 조작 아이콘 (펼침 화살표 · 지우기 · 닫기 · 평가). 누를 수 있는 것은 바탕과 3:1 이상 (흰 바탕 3.6:1 · 어두운 화면 카드 3.4:1 ·
/// 종이 3.9:1).
    static let control = dynamic(0x7A889C, dark: 0x687485)
    /// Claude 마크 · 실행 표시. 테라코타는 다크에서도 바꾸지 않는다. 글자에는 쓰지 않는다 (흰 바탕 3.1:1) — 글자는 `claudeText`.
    static let claude = Color(hex: 0xD97757)
    /// 실행 상태 글자 ("실행 중" · "인계 전송 중" — `RunState.tint`). 같은 색조의 진한 테라코타: 흰 바탕 5.5:1 · `well` 5.0:1 —
    /// 11.5pt 글자의 AA. 어두운 화면은 `claudeDeep` 의 어두운 값(#E38B6E, 카드 6.4:1). 로고 · 점 · 링은 `claude` 그대로 (copy-4).
    static let claudeText = dynamic(0xAF4928, dark: 0xE38B6E)
    /// Antigravity(Gemini). Claude 테라코타·Codex 잉크와 구분되는 파랑.
    static let gemini = dynamic(0x2D6CDF, dark: 0x6FA3FF)
    static let claudeDeep = dynamic(0xC25E3E, dark: 0xE38B6E)

    /// 제공자 색 (로고 · 보내기 버튼). Codex 는 잉크색이라 다크에서 밝은 잉크가 된다.
    static func brand(_ provider: AgentProvider) -> Color {
        switch provider {
        case .claude: return claude
        case .codex: return ink
        case .gemini: return gemini
        }
    }
    /// 성공 색 — 점 · 아이콘 · 막대 · 바탕. 글자에는 쓰지 않는다 (흰 바탕 3.8:1 · `well` 3.4:1) — 글자는 `emeraldText`.
    static let emerald = dynamic(0x059669, dark: 0x34D399)
    /// 성공 글자 ("커밋 완료" · "✔ 종료 0" · "+12" · "전달 확인"). 밝은 화면: 흰 바탕 5.5:1 · 패널 5.3:1 · `well` 5.0:1 ·
    /// 더한 줄 바탕 5.2:1 · 초록 12% 를 깐 이름표 4.7:1 — 11.5pt 글자의 AA. 어두운 화면은 `emerald` 와 같은 #34D399 (카드 8.5:1) (copy-4).
    static let emeraldText = dynamic(0x047857, dark: 0x34D399)
    /// 주의 색 — 막대 · 점 · 선 · 테두리 · 바탕 · 아이콘 채움. 글자에는 쓰지 않는다 (흰 바탕 3.2:1 — 11.5pt 글자의 AA 4.5 에 못 미친다).
    static let amber = dynamic(0xD97706, dark: 0xFBBF24)
    /// 주의 글자 (초기화 시각 · "승인 대기" · "확인 필요" 이름표 · 경고 문장). 밝은 화면: 흰 바탕 5.4:1 · 패널 5.1:1 ·
    /// 승인 바탕(`approvalWell`) 5.2:1 · 입력창 바탕(`well`) 4.9:1 · 앰버 12% 를 깐 이름표 4.5:1 이상 — 11.5pt 글자의 AA.
    /// 어두운 화면은 `amber` 와 같은 #FBBF24 (종이 10.9:1 · 카드 9.8:1 · 승인 바탕 10.0:1). 막대 · 점 · 아이콘은 `amber` 그대로.
    static let amberText = dynamic(0xAD5008, dark: 0xFBBF24)
    /// 주의 단추의 바탕 (자동 승인 · Antigravity 허용의 확인 단추 — `.borderedProminent` 는 흰 글자). 흰 글자 대비 밝은 화면 5.4:1 ·
    /// 어두운 화면 5.0:1. `amber` 를 바탕으로 쓰면 흰 글자가 3.2:1(어두운 화면 #FBBF24 는 1.7:1)이라 읽기 어려웠다.
    static let amberFill = dynamic(0xAD5008, dark: 0xB45309)
    static let danger = dynamic(0xDC2626, dark: 0xF87171)

    // MARK: 색 — 보드에서 쓰인 보조 면

    /// 창 상단 바의 가운데 칸.
    static let toolbar = dynamic(0xFCFDFE, dark: 0x181817)
    /// 세그먼트 바탕, 선택된 칩.
    static let well = dynamic(0xF1F4F8, dark: 0x1E1E1D)
    /// 인라인 코드, 옅은 세그먼트 바탕.
    static let wellSoft = dynamic(0xF5F7FA, dark: 0x1C1C1B)
    /// 흰 카드 (선택 행, 입력 필드, 버튼 바탕).
    static let card = dynamic(0xFFFFFF, dark: 0x20201F)
    static let codeBackground = dynamic(0xFCFDFE, dark: 0x181817)
    static let codeHeader = dynamic(0xF8FAFC, dark: 0x1A1A19)
    static let codeBorder = dynamic(0xEDF1F5, dark: 0x252C35)
    /// 터미널 프롬프트 줄.
    static let promptBar = dynamic(0xF4F6F9, dark: 0x1C1C1B)
    static let approvalWell = dynamic(0xFDFBF7, dark: 0x231D13)
    static let approvalBorder = dynamic(0xF3E3D0, dark: 0x4B3B22)
    /// 전달 여부 미확인 인계 줄의 규칙선.
    static let amberRule = dynamic(0xF3D9C4, dark: 0x5C4128)
    static let dangerRule = dynamic(0xF5C9C9, dark: 0x5C2A2A)
    static let emeraldWell = dynamic(0xF0FAF6, dark: 0x0E2A21)
    static let emeraldBorder = dynamic(0xBFE5D6, dark: 0x1D5A45)
    /// 찾은 글자 바탕 (브랜치 메뉴 찾기, 목업 boards_git.py `#FEF3C7`).
    static let matchHighlight = dynamic(0xFEF3C7, dark: 0x4A3A12)
    /// 잉크 바탕 위의 글자.
    static let onInk = dynamic(0xFFFFFF, dark: 0x0B0B0B)

    // MARK: 색 — 파일 diff (lib.py `--add-bg` · `--add-word` · `--del-bg` · `--del-word`, boards_git.py 거터 · 빗금)

    /// 더한 줄 바탕 · 줄 안 바뀐 글자 · 거터.
    static let addBackground = dynamic(0xF0FAF6, dark: 0x0F2A21)
    static let addWord = dynamic(0xCCEFE0, dark: 0x1D5A45)
    static let addGutter = dynamic(0xE3F5EC, dark: 0x14382A)
    /// 지운 줄 바탕 · 줄 안 바뀐 글자 · 거터.
    static let deleteBackground = dynamic(0xFEF2F2, dark: 0x2D1618)
    static let deleteWord = dynamic(0xFAD9D9, dark: 0x5C2A2A)
    static let deleteGutter = dynamic(0xFCE7E7, dark: 0x3A1C1F)
    /// 나란히 보기의 빈 칸 빗금 (바탕 · 선). 라이트 #F8FAFC / #F3F6F9.
    static let hatchBaseHex: (light: UInt32, dark: UInt32) = (0xF8FAFC, 0x181817)
    static let hatchLineHex: (light: UInt32, dark: UInt32) = (0xF3F6F9, 0x20201F)

    // MARK: 색 — MAX / ULTRA 전용

    static let flameAmber = Color(hex: 0xF59E0B)
    static let flame = Color(hex: 0xEA580C)
    static let flameLight = Color(hex: 0xFBBF24)
    static let flamePale = Color(hex: 0xFDE68A)
    static let flameText = dynamic(0xC2410C, dark: 0xFB923C)
    static let flameWell = dynamic(0xFFF3E6, dark: 0x3A2411)
    static let ultra = Color(hex: 0x7C3AED)
    static let ultraLight = Color(hex: 0xA78BFA)
    static let ultraPale = Color(hex: 0xDDD6FE)
    static let ultraText = dynamic(0x6D28D9, dark: 0xC4B5FD)
    /// ULTRA 반짝임 · MAX 번개 글리프 (칩 · 카드 제목). 다크에서 고정색은 옆 글자(ultraText · flameText)보다 가라앉아 밝힌다.
    static let ultraGlyph = dynamic(0x7C3AED, dark: 0xA78BFA)
    static let flameGlyph = dynamic(0xEA580C, dark: 0xF97316)
    static let ultraWell = dynamic(0xF5F3FF, dark: 0x2E1F47)

    // MARK: 색 — 추론 강도 단계 (boards_composer.py LEVELS)

    /// 채움은 Tailwind 600, 글자는 대비를 위해 700 (flame / flameText 짝과 같은 방식). 차가운 색일수록 가볍다.
    /// 다크 값은 원본에 없어 채움 500 · 글자 400 으로 맞췄다. MAX · ULTRA 채움은 그라데이션(flameAmber→flame ·
    /// ultraLight→ultra), 글자는 flameText · ultraText. boost 는 ULTRA 색, 모르는 값은 중립색.
    static let effortLow = dynamic(0x0D9488, dark: 0x14B8A6)
    static let effortLowText = dynamic(0x0F766E, dark: 0x2DD4BF)
    static let effortMedium = dynamic(0x0284C7, dark: 0x0EA5E9)
    static let effortMediumText = dynamic(0x0369A1, dark: 0x38BDF8)
    static let effortHigh = dynamic(0x4F46E5, dark: 0x6366F1)
    static let effortHighText = dynamic(0x4338CA, dark: 0x818CF8)
    static let effortXHigh = dynamic(0xD97706, dark: 0xF59E0B)
    static let effortXHighText = dynamic(0xB45309, dark: 0xFBBF24)

    /// 단계 채움. 한 색이면 원소 하나, 그라데이션이면 왼쪽 → 오른쪽.
    static func effortFill(_ tier: EffortScale.Tier) -> [Color] {
        switch tier {
        case .low: return [effortLow]
        case .medium: return [effortMedium]
        case .high: return [effortHigh]
        case .xhigh: return [effortXHigh]
        case .max: return [flameAmber, flame]
        case .ultra: return [ultraLight, ultra]
        case .unknown: return [slate]
        }
    }

    /// 단계 글자 (칩 · 카드 제목).
    static func effortText(_ tier: EffortScale.Tier) -> Color {
        switch tier {
        case .low: return effortLowText
        case .medium: return effortMediumText
        case .high: return effortHighText
        case .xhigh: return effortXHighText
        case .max: return flameText
        case .ultra: return ultraText
        case .unknown: return ink2
        }
    }

    /// 그림자는 잉크색을 옅게 쓴다.
    static let shadow = Color(red: 11 / 255, green: 11 / 255, blue: 11 / 255)

    // MARK: 치수

    enum Metric {
        static let toolbar: CGFloat = 52
        static let sidebar: CGFloat = 248
        static let inspector: CGFloat = 420
        /// 대화 본문 단 (중앙 정렬).
        static let column: CGFloat = 740
        static let turnGap: CGFloat = 22
        static let chipRadius: CGFloat = 6
        static let panelRadius: CGFloat = 9
        /// 입력창 상자 (테두리 없는 채움).
        static let capsuleRadius: CGFloat = 14
        /// 에이전트 본문 들여쓰기 (로고 칸 15 + 간격 8). 사용자 메시지는 들여쓰지 않고 말풍선으로 구분한다.
        static let agentIndent: CGFloat = 23
    }

    // MARK: 글꼴

    /// 글자는 4단계(`TypeScale` — 11.5 · 12.5 · 14 · 20) 중 하나다. 크기를 숫자로 주는 API 는 두지 않는다.
    static func ui(_ step: TypeScale, _ weight: Font.Weight = .regular) -> Font {
        .system(size: step.size, weight: weight)
    }

    /// SF Mono — 글자 그대로를 보일 때만 (명령 · 경로 · 해시 · 코드 · 출력). 줄 안은 caption, 코드 본문은 callout.
    static func mono(_ step: TypeScale, _ weight: Font.Weight = .regular) -> Font {
        .system(size: step.size, weight: weight, design: .monospaced)
    }

    /// 숫자 · 시각 · 개수 — SF Pro 에 고정폭 숫자 (자리가 흔들리지 않게. 글자 모양이 주변 글과 같다).
    static func digits(_ step: TypeScale, _ weight: Font.Weight = .regular) -> Font {
        ui(step, weight).monospacedDigit()
    }

    /// 스레드 제목 · 툴바 · 카드 제목 14 / 600.
    static let barTitle = ui(.body, .semibold)
    /// 좁은 칸(인스펙터 400pt 안팎)의 머리 — 파일 이름 · 하위 에이전트 이름 12.5 / 600.
    static let paneHeader = ui(.callout, .semibold)
    /// 대화 본문 · 입력창 14 (Markdown 본문은 `MarkdownMetrics.bodySize` — 같은 값).
    static let body = ui(.body)
    /// 메타 (시각 · 턴 수) — caption, 숫자는 고정폭.
    static let meta = digits(.caption)

    // MARK: 도우미

    private static func dynamic(_ light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - 공통 수식어

extension View {
    /// 섹션 라벨 (caption · medium). 대문자 · 자간을 쓰지 않는다 (2026-09-18 — 웹 목업의 대문자 라벨을 버렸다).
    func sectionLabelStyle(_ color: Color = Theme.slate2) -> some View {
        font(Theme.ui(.caption, .medium))
            .foregroundStyle(color)
    }

    /// 흰 카드 + 규칙선 + 옅은 그림자 (선택된 사이드바 행, 인스펙터 선택 행).
    func cardSurface(radius: CGFloat = 8, shadow: Bool = true) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius)
                .fill(Theme.card)
                .shadow(color: Theme.shadow.opacity(shadow ? 0.04 : 0), radius: 1, y: 1)
        )
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.hair))
    }

    /// 왼쪽 규칙선. 면을 나누지 않고 선과 여백으로 종류를 구분한다.
    func leadingRule(_ color: Color, width: CGFloat = 1, gap: CGFloat = 15) -> some View {
        padding(.leading, gap)
            .overlay(alignment: .leading) {
                Rectangle().fill(color).frame(width: width)
            }
    }
}
