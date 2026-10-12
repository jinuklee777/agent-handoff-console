import SwiftUI

/// 에이전트 로고.
///
/// Claude 스파크와 OpenAI 매듭은 원본 SVG 벡터(아래 `claudeData` · `openAIData`)를 그대로 그린다
/// (테라코타 · 잉크색 템플릿 렌더링). Antigravity 별은 4색 그라데이션이라 벡터로 옮기지 않고
/// 원본 이미지를 에셋(`AntigravityMark`)으로 쓴다.
/// 12pt 아래로 줄이면 매듭의 틈이 뭉개지므로 목록 태그에서도 10pt 이상만 쓴다.
struct BrandMark: View {
    let provider: AgentProvider
    var size: CGFloat = 14
    var opacity: Double = 1

    var body: some View {
        Group {
            if provider == .gemini {
                Image("AntigravityMark")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                BrandShape(provider: provider)
                    .fill(color, style: FillStyle(eoFill: false))
            }
        }
        .frame(width: size, height: size)
        .opacity(opacity)
        .accessibilityLabel(provider.displayName)
    }

    private var color: Color { Theme.brand(provider) }
}

struct BrandShape: Shape {
    let provider: AgentProvider

    func path(in rect: CGRect) -> Path {
        // Antigravity 는 이미지 에셋을 쓰므로 여기로 오지 않는다.
        let source = provider == .claude ? BrandPaths.claude : BrandPaths.openAI
        let box = source.viewBox
        let scale = min(rect.width / box.width, rect.height / box.height)
        let dx = rect.midX - (box.minX + box.width / 2) * scale
        let dy = rect.midY - (box.minY + box.height / 2) * scale
        return source.path.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy))
    }
}

private enum BrandPaths {
    struct Source {
        let path: Path
        let viewBox: CGRect
    }

    static let claude = Source(path: SVGPath.parse(claudeData),
                               viewBox: CGRect(x: 4, y: 4, width: 240, height: 240))
    static let openAI = Source(path: SVGPath.parse(openAIData),
                               viewBox: CGRect(x: 0, y: 0, width: 240, height: 240))


    // Claude 스파크 — 원본 SVG 그대로
    static let claudeData = """
    M52.4285 162.873L98.7844 136.879L99.5485 134.602L98.7844 133.334H96.4921L88.7237 132.862L62.2346 132.153\
    L39.3113 131.207L17.0249 130.026L11.4214 128.844L6.2 121.873L6.7094 118.447L11.4214 115.257L18.171 115.847\
    L33.0711 116.911L55.485 118.447L71.6586 119.392L95.728 121.873H99.5485L100.058 120.337L98.7844 119.392\
    L97.7656 118.447L74.5877 102.732L49.4995 86.1905L36.3823 76.62L29.3779 71.7757L25.8121 67.2858L24.2839 57.3608\
    L30.6515 50.2716L39.3113 50.8623L41.4763 51.4531L50.2636 58.1879L68.9842 72.7209L93.4357 90.6804L97.0015 93.6343\
    L98.4374 92.6652L98.6571 91.9801L97.0015 89.2625L83.757 65.2772L69.621 40.8192L63.2534 30.6579L61.5978 24.632\
    C60.9565 22.1032 60.579 20.0111 60.579 17.4246L67.8381 7.49965L71.9133 6.19995L81.7193 7.49965L85.7946 11.0443\
    L91.9074 24.9865L101.714 46.8451L116.996 76.62L121.453 85.4816L123.873 93.6343L124.764 96.1155H126.292V94.6976\
    L127.566 77.9197L129.858 57.3608L132.15 30.8942L132.915 23.4505L136.608 14.4708L143.994 9.62643L149.725 12.344\
    L154.437 19.0788L153.8 23.4505L150.998 41.6463L145.522 70.1215L141.957 89.2625H143.994L146.414 86.7813\
    L156.093 74.0206L172.266 53.698L179.398 45.6635L187.803 36.802L193.152 32.5484H203.34L210.726 43.6549\
    L207.415 55.1159L196.972 68.3492L188.312 79.5739L175.896 96.2095L168.191 109.585L168.882 110.689L170.738 110.53\
    L198.755 104.504L213.91 101.787L231.994 98.7149L240.144 102.496L241.036 106.395L237.852 114.311L218.495 119.037\
    L195.826 123.645L162.07 131.592L161.696 131.893L162.137 132.547L177.36 133.925L183.855 134.279H199.774\
    L229.447 136.524L237.215 141.605L241.8 147.867L241.036 152.711L229.065 158.737L213.019 154.956L175.45 145.977\
    L162.587 142.787H160.805V143.85L171.502 154.366L191.242 172.089L215.82 195.011L217.094 200.682L213.91 205.172\
    L210.599 204.699L188.949 188.394L180.544 181.069L161.696 165.118H160.422V166.772L164.752 173.152L187.803 207.771\
    L188.949 218.405L187.294 221.832L181.308 223.959L174.813 222.777L161.187 203.754L147.305 182.486L136.098 163.345\
    L134.745 164.2L128.075 235.42L125.019 239.082L117.887 241.8L111.902 237.31L108.718 229.984L111.902 215.452\
    L115.722 196.547L118.779 181.541L121.58 162.873L123.291 156.636L123.14 156.219L121.773 156.449L107.699 175.752\
    L86.304 204.699L69.3663 222.777L65.291 224.431L58.2867 220.768L58.9235 214.27L62.8713 208.48L86.304 178.705\
    L100.44 160.155L109.551 149.507L109.462 147.967L108.959 147.924L46.6977 188.512L35.6182 189.93L30.7788 185.44\
    L31.4156 178.115L33.7079 175.752L52.4285 162.873Z
    """

    // OpenAI 매듭 — 원본 SVG 그대로
    static let openAIData = """
    M222.797 98.227C228.238 81.887 226.363 63.984 217.656 49.117C204.562 26.316 178.238 14.586 152.527 20.109\
    C141.09 7.223 124.656 -0.105 107.43 0C81.148 -0.059 57.832 16.859 49.746 41.863C32.863 45.324 18.293 55.891 9.766 70.867\
    C-3.426 93.609 -0.422 122.273 17.203 141.773C11.762 158.113 13.637 176.016 22.344 190.883\
    C35.438 213.684 61.762 225.414 87.473 219.891C98.902 232.777 115.344 240.105 132.57 239.992\
    C158.863 240.059 182.191 223.125 190.273 198.098C207.156 194.641 221.73 184.074 230.258 169.094\
    C243.434 146.355 240.422 117.711 222.801 98.211Z\
    M132.586 224.309C122.062 224.324 111.871 220.641 103.793 213.898C104.16 213.703 104.797 213.352 105.211 213.098\
    L153 185.496C155.445 184.109 156.945 181.508 156.93 178.695L156.93 111.324L177.129 122.984\
    C177.344 123.09 177.488 123.301 177.516 123.539L177.516 179.332C177.488 204.141 157.395 224.258 132.586 224.309Z\
    M35.953 183.039C30.684 173.934 28.785 163.262 30.594 152.902C30.945 153.113 31.566 153.496 32.012 153.75\
    L79.801 181.352C82.223 182.766 85.223 182.766 87.652 181.352L145.996 147.66L145.996 170.984\
    C146.012 171.227 145.898 171.457 145.711 171.609L97.402 199.5C75.887 211.891 48.406 204.523 35.961 183.039Z\
    M23.379 78.719C28.629 69.602 36.914 62.625 46.785 59.004C46.785 59.414 46.762 60.141 46.762 60.652L46.762 115.859\
    C46.746 118.664 48.246 121.266 50.684 122.656L109.027 156.336L88.828 168C88.629 168.137 88.371 168.156 88.148 168.059\
    L39.832 140.145C18.359 127.711 10.996 100.238 23.371 78.727Z\
    M189.324 117.336L130.98 83.648L151.176 71.992C151.379 71.859 151.637 71.836 151.859 71.934L200.176 99.824\
    C221.684 112.254 229.059 139.77 216.629 161.281C211.371 170.387 203.094 177.359 193.23 180.988L193.23 124.133\
    C193.254 121.328 191.762 118.734 189.328 117.336Z\
    M209.422 87.082C209.07 86.863 208.449 86.488 208.004 86.234L160.215 58.637C157.793 57.219 154.793 57.219 152.363 58.637\
    L94.02 92.324L94.02 69C94.004 68.762 94.117 68.527 94.305 68.379L142.613 40.508C164.129 28.094 191.641 35.484 204.047 57.008\
    C209.289 66.098 211.184 76.738 209.406 87.082Z\
    M83.039 128.656L62.836 116.992C62.617 116.887 62.477 116.676 62.445 116.438L62.445 60.645\
    C62.461 35.805 82.613 15.676 107.453 15.691C117.961 15.691 128.129 19.379 136.207 26.102\
    C135.84 26.297 135.211 26.648 134.789 26.902L87 54.504C84.555 55.891 83.055 58.484 83.07 61.297L83.039 128.641Z\
    M94.012 105L120 89.992L145.988 104.992L145.988 135L120 150L94.012 135Z
    """
}

/// 로고에 필요한 만큼의 SVG path 해석기 (M/L/H/V/C/S/Q/T/Z, 절대·상대 좌표).
enum SVGPath {
    static func parse(_ data: String) -> Path {
        var path = Path()
        var scanner = Scanner(Array(data.utf8))
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var command: UInt8 = UInt8(ascii: "M")

        while let next = scanner.nextCommandOrNumber() {
            if case .command(let c) = next { command = c } else { scanner.rewindNumber() }
            let relative = command >= UInt8(ascii: "a")
            let base = relative ? current : .zero
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }

            switch command | 0x20 { // 소문자로 비교
            case UInt8(ascii: "m"):
                guard let p = point() else { return path }
                path.move(to: p)
                current = p; start = p; lastControl = nil
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                guard let p = point() else { return path }
                path.addLine(to: p)
                current = p; lastControl = nil
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: (relative ? current.x : 0) + x, y: current.y)
                path.addLine(to: current); lastControl = nil
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: (relative ? current.y : 0) + y)
                path.addLine(to: current); lastControl = nil
            case UInt8(ascii: "c"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p; lastControl = c2
            case UInt8(ascii: "s"):
                guard let c2 = point(), let p = point() else { return path }
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p; lastControl = c2
            case UInt8(ascii: "q"):
                guard let c = point(), let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                current = p; lastControl = c
            case UInt8(ascii: "t"):
                guard let p = point() else { return path }
                let c = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addQuadCurve(to: p, control: c)
                current = p; lastControl = c
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start; lastControl = nil
            default:
                return path
            }
        }
        return path
    }

    private struct Scanner {
        enum Token { case command(UInt8), number }
        let bytes: [UInt8]
        var index = 0
        private var numberStart = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSeparators() {
            while index < bytes.count,
                  bytes[index] == 0x20 || bytes[index] == 0x2C || bytes[index] == 0x0A
                    || bytes[index] == 0x09 || bytes[index] == 0x0D {
                index += 1
            }
        }

        mutating func nextCommandOrNumber() -> Token? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let b = bytes[index]
            if (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A), b != UInt8(ascii: "e"),
               b != UInt8(ascii: "E") {
                index += 1
                return .command(b)
            }
            numberStart = index
            return .number
        }

        mutating func rewindNumber() { index = numberStart }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = index
            if index < bytes.count, bytes[index] == 0x2D || bytes[index] == 0x2B { index += 1 }
            var sawDot = false
            var sawDigit = false
            while index < bytes.count {
                let b = bytes[index]
                if b >= 0x30 && b <= 0x39 {
                    sawDigit = true
                } else if b == 0x2E, !sawDot {
                    sawDot = true
                } else if (b == 0x65 || b == 0x45), sawDigit {
                    index += 1
                    if index < bytes.count, bytes[index] == 0x2D || bytes[index] == 0x2B { index += 1 }
                    continue
                } else {
                    break
                }
                index += 1
            }
            guard sawDigit, let text = String(bytes: bytes[begin..<index], encoding: .ascii),
                  let value = Double(text) else {
                index = begin
                return nil
            }
            return CGFloat(value)
        }
    }
}
