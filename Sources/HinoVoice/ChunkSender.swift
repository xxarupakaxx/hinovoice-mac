import Foundation
import os

/// オーディオスレッドから呼ばれる送信。パイプへの書き込みを待たずに積み、
/// 1本の Task が順番に送る。`seq` は 0, 1, 2 … の順で届かなければならない
/// （worker-protocol.md「its chunk lines, seq 0, 1, 2 … in order」）ので、
/// chunk ごとに Task を作ってはいけない。
final class ChunkSender: @unchecked Sendable {
    private struct Queue {
        var items: [Data] = []
        var nextSeq = 0
        var draining = false
    }

    private let worker: SpeechWorkerClient
    private let requestID: String
    private let queue = OSAllocatedUnfairLock(initialState: Queue())

    init(worker: SpeechWorkerClient, requestID: String) {
        self.worker = worker
        self.requestID = requestID
    }

    var sentChunks: Int {
        queue.withLock { $0.nextSeq }
    }

    func send(_ pcm: Data) {
        let shouldDrain = queue.withLock { state -> Bool in
            state.items.append(pcm)
            if state.draining { return false }
            state.draining = true
            return true
        }
        guard shouldDrain else { return }
        Task { await drain() }
    }

    /// 端数の chunk を積み、`transcribe` の前に全部送り終えるまで待つ（設計書 11）。
    func finish(_ tail: Data) async {
        if !tail.isEmpty { send(tail) }
        while queue.withLock({ $0.draining }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func drain() async {
        while true {
            let next = queue.withLock { state -> (Data, Int)? in
                guard !state.items.isEmpty else {
                    state.draining = false
                    return nil
                }
                let item = state.items.removeFirst()
                let seq = state.nextSeq
                state.nextSeq += 1
                return (item, seq)
            }
            guard let (pcm, seq) = next else { return }
            do {
                try await worker.send(chunk: pcm, id: requestID, seq: seq)
            } catch {
                Log.worker.error("chunk send failed: \(SpeechWorkerClient.code(of: error), privacy: .public)")
            }
        }
    }
}
