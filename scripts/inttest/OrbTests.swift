import AppKit
import SwiftUI

/// 점 구: 레이어 칠하기(`OrbCanvas` — 앱의 실행 중 상태 줄이 쓰는 것)가 옮겨 온 원본 `ThinkingOrb`(SwiftUI Canvas)와 같은
/// 그림인지 — 같은 엔진 시각을 둘 다 40 × 40 픽셀(20pt · 2배율)로 그려 비교한다. 레이어 · 비트맵의 좌표는 아래가 y = 0 이라
/// 뒤집기를 빠뜨리면 비대칭인 장면에서 차가 커진다 — 위아래를 뒤집은 그림과의 차도 함께 본다.
/// `AHC_ORB_DUMP=<폴더>` 면 두 그림을 PNG 로 남긴다 (눈으로 견줄 때).
enum OrbTests {
    struct Case {
        let name: String
        /// 원본과의 평균 차 (RGBA 바이트, 0~255).
        let diff: Double
        /// 위아래를 뒤집은 우리 그림과 원본의 평균 차.
        let flipped: Double
    }

    static let side = 40

    static func run(_ t: TestKit) async {
        await t.group("점 구: 레이어 칠하기 = 원본 Canvas")
        let cases = await MainActor.run { compareAll() }
        await t.check("원본 렌더(ImageRenderer)를 얻는다", !cases.isEmpty)
        for c in cases {
            let detail = String(format: "평균 차 %.2f · 뒤집으면 %.2f", c.diff, c.flipped)
            // 남는 차는 점 가장자리의 안티앨리어싱(SwiftUI 렌더러 대 CoreGraphics)뿐이다 — 2026-10-03 에 0.3~2.8, 차 그림은
            // 점마다 얇은 테두리. 원본 저장소도 자기 SwiftUI 판과 웹판 사이에 최대 4.9 를 둔다. 뒤집거나 점 · 선이 빠지면 7 을 넘는다.
            // 비대칭인 장면이면 뒤집은 그림보다 확실히 가까워야 한다.
            await t.check(c.name, c.diff < 3.5 && (c.flipped < 1 || c.diff < c.flipped / 3), detail)
        }
    }

    @MainActor
    static func compareAll() -> [Case] {
        let dump = ProcessInfo.processInfo.environment["AHC_ORB_DUMP"].map { URL(fileURLWithPath: $0) }
        if let dump { try? FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true) }
        var out: [Case] = []
        for state in OrbState.allCases {
            for (time, dark) in [(0.6, false), (3.7, false), (11.3, true)] {
                guard let image = reference(state, t: time, dark: dark) else { return [] }
                let ref = pixels(of: image)
                let ours = painted(state, t: time, dark: dark)
                let name = "\(state.rawValue) t=\(time)\(dark ? " · 어두운 화면" : "")"
                out.append(Case(name: name, diff: meanDiff(ref, ours), flipped: meanDiff(ref, flippedRows(ours))))
                if let dump {
                    let stem = "\(state.rawValue)-\(time)\(dark ? "-dark" : "")"
                    writePNG(ref, to: dump.appendingPathComponent("\(stem)-original.png"))
                    writePNG(ours, to: dump.appendingPathComponent("\(stem)-layer.png"))
                }
            }
        }
        return out
    }

    /// 원본: 옮겨 온 SwiftUI 뷰를 그 시각에 멈춰 `ImageRenderer` 로 (원본 저장소의 스냅샷 도구와 같은 방법).
    @MainActor
    static func reference(_ state: OrbState, t: Double, dark: Bool) -> CGImage? {
        let view = ThinkingOrb(state: state, size: .px20, theme: dark ? .dark : .light)
            .orbFrozenTime(t)
            .frame(width: OrbSize.px20.value, height: OrbSize.px20.value)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = false
        return renderer.cgImage
    }

    /// 앱: 상태 줄의 레이어와 같은 길 (`OrbCanvas.render` — 2배율 화면처럼 40 픽셀 비트맵에 칠해 낸 그림, 여기서는 sRGB).
    static func painted(_ state: OrbState, t: Double, dark: Bool) -> [UInt8] {
        let canvas = OrbCanvas(pixels: side, space: OrbCanvas.sRGB)
        guard let image = canvas.render(orbFrame(state: state, size: .px20, t: t), side: OrbSize.px20.value,
                                        dark: dark) else { return [] }
        return pixels(of: image)
    }

    static func bitmap() -> CGContext {
        CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    static func pixels(of image: CGImage) -> [UInt8] {
        let ctx = bitmap()
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return bytes(ctx)
    }

    static func bytes(_ ctx: CGContext) -> [UInt8] {
        guard let data = ctx.data else { return [] }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: side * side * 4))
    }

    static func flippedRows(_ pixels: [UInt8]) -> [UInt8] {
        let row = side * 4
        var out: [UInt8] = []
        out.reserveCapacity(pixels.count)
        for y in stride(from: side - 1, through: 0, by: -1) { out += pixels[(y * row)..<((y + 1) * row)] }
        return out
    }

    static func meanDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var sum = 0
        for i in a.indices { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count)
    }

    static func writePNG(_ pixels: [UInt8], to url: URL) {
        var copy = pixels
        let png: Data? = copy.withUnsafeMutableBytes { raw in
            guard let image = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                        bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage() else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
        try? png?.write(to: url)
    }
}
