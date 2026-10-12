import CoreGraphics
import Foundation

// 사용법: popwin <pid>  — 그 프로세스의 창 가운데 가장 큰 일반 창(주 창)이 아닌 것 중 가장 큰 창(팝오버) 번호. 없으면 0.
guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else {
    print(0); exit(1)
}
let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
var windows: [(id: Int, area: Double, layer: Int)] = []
for window in list {
    guard (window[kCGWindowOwnerPID as String] as? Int32) == pid else { continue }
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let area = (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
    windows.append((window[kCGWindowNumber as String] as? Int ?? 0, area, window[kCGWindowLayer as String] as? Int ?? 0))
}
let main = windows.filter { $0.layer == 0 }.max { $0.area < $1.area }
let others = windows.filter { $0.id != main?.id && $0.area > 120 * 60 }.sorted { $0.area > $1.area }
if CommandLine.arguments.count > 2 {
    for w in windows { FileHandle.standardError.write("\(w.id) layer \(w.layer) area \(Int(w.area))\n".data(using: .utf8)!) }
}
print(others.first?.id ?? 0)
