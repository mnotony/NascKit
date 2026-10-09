import Foundation

/// A value shared between a test and the closures it hands out.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func update(_ f: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; f(&value) }
}

struct TimedOut: Error {}

/// Run `body`, failing with `TimedOut` if it takes longer than `limit` — so a missing deadline in the
/// code under test fails the test instead of hanging it.
func within<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let done = Box(false)
        let finish: @Sendable (Result<T, Error>) -> Void = { result in
            var first = false
            done.update { if !$0 { $0 = true; first = true } }
            if first { cont.resume(with: result) }
        }
        Task {
            do { finish(.success(try await body())) } catch { finish(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: limit)
            finish(.failure(TimedOut()))
        }
    }
}
