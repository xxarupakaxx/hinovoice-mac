import Foundation

/// 標準入力への書き込みを専用の直列キューで行う。actor やオーディオスレッドを
/// ブロックしないため、書き込みはすべてここを通す（設計書 12.6）。
final class PipeWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "\(AppConfiguration.bundleIdentifier).worker-write")
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    func close() {
        queue.async {
            try? self.handle.close()
        }
    }

    func write(_ data: Data, timeout: Double) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.enqueue(data) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw WorkerFailure.timeout("write")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func enqueue(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.handle.write(contentsOf: data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: WorkerFailure.spawnFailed(error.localizedDescription))
                }
            }
        }
    }
}
