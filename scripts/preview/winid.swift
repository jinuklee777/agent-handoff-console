import CoreGraphics
import Foundation

// 사용법: winid <pid>  — 그 프로세스의 가장 큰 일반 창(layer 0) 번호를 출력한다. 없으면 0.
guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else {
    print(0); exit(1)
}
let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
var best = (id: 0, area: 0.0)
for window in list {
    guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
          (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let area = (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
    if area > best.area, area > 200 * 200 {
        best = (window[kCGWindowNumber as String] as? Int ?? 0, area)
    }
}
print(best.id)
