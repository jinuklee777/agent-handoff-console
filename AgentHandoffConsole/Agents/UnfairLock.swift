import Foundation
import os

/// 비재귀 저수준 락.
///
/// `NSLock` 은 비동기 컨텍스트에서 사용 불가로 표시되어 있어(Swift 6 에서는 오류)
/// 어댑터/프로세스 래퍼처럼 콜백과 async 코드가 섞이는 곳에서 이 타입을 쓴다.
/// 재귀 잠금을 지원하지 않으므로, 락을 잡은 상태에서 다시 락을 잡는 코드를 만들지 않는다.
final class UnfairLock: @unchecked Sendable {
    private let pointer: UnsafeMutablePointer<os_unfair_lock>

    init() {
        pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    func lock() { os_unfair_lock_lock(pointer) }
    func unlock() { os_unfair_lock_unlock(pointer) }

    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(pointer)
        defer { os_unfair_lock_unlock(pointer) }
        return try body()
    }
}
