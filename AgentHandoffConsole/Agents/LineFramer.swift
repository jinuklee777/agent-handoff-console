import Foundation

/// 바이트 청크를 줄 단위로 재조립한다.
///
/// 파이프에서 오는 청크는 JSON 한 줄 경계와 일치하지 않는다.
/// 한 청크에 여러 줄이 들어오거나, 한 줄이 여러 청크에 걸쳐 올 수 있다.
/// 이 타입은 그 두 경우를 모두 처리한다.
struct LineFramer {
    private var buffer = Data()
    /// 한 줄이 비정상적으로 길어질 때의 방어선 (기본 32MB).
    private let maxLineBytes: Int
    private(set) var droppedOverlongLines = 0

    init(maxLineBytes: Int = 32 * 1024 * 1024) {
        self.maxLineBytes = maxLineBytes
    }

    /// 새 청크를 넣고, 완성된 줄들을 반환한다.
    mutating func append(_ chunk: Data) -> [String] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)
        var lines: [String] = []

        while let idx = buffer.firstIndex(of: 0x0A) {  // '\n'
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            lines.append(decode(lineData))
        }

        if buffer.count > maxLineBytes {
            droppedOverlongLines += 1
            buffer.removeAll(keepingCapacity: false)
        }
        return lines
    }

    /// 스트림 종료 시 남은 부분(개행 없이 끝난 마지막 줄)을 꺼낸다.
    mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        let s = decode(buffer)
        buffer.removeAll(keepingCapacity: false)
        return s
    }

    /// **빈 줄도 줄로 돌려준다.** 사람이 읽는 출력(명령 결과·커밋 메시지·파일 내용)에서
    /// 문단 구분이 사라지면 안 된다. NDJSON 을 읽는 어댑터는 JSON 이 아닌 줄을 이미 무시한다.
    private func decode(_ data: Data) -> String {
        // \r\n 방어
        var d = data
        if d.last == 0x0D { d = d.dropLast() }
        guard !d.isEmpty else { return "" }
        if let s = String(data: d, encoding: .utf8) { return s }
        // 잘린 UTF-8 이 섞여도 줄 자체를 버리지 않는다.
        return String(decoding: d, as: UTF8.self)
    }
}
