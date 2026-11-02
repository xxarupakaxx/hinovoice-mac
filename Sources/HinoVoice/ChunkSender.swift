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
        /// 取り消したあと。積んだ分を捨て、以降は何も送らない。
        var stopped = false
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
            guard !state.stopped else { return false }
            state.items.append(pcm)
            if state.draining { return false }
            state.draining = true
            return true
        }
        guard shouldDrain else { return }
        Task { await drain() }
    }

    /// Esc で取り消したときに呼ぶ。積んだ chunk を捨て、走っている drain を
    /// 次の区切りで終わらせる。取り消したあとに送り続けないため（設計書 12.5）。
    func stop() {
        queue.withLock { state in
            state.items.removeAll()
            state.stopped = true
        }
    }

    /// 端数の chunk を積み、`transcribe` の前に全部送り終えるまで待つ（設計書 11）。
    func finish(_ tail: Data) async {
        if !tail.isEmpty { send(tail) }
        while queue.withLock({ $0.draining && !$0.stopped }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func drain() async {
        while true {
            let next = queue.withLock { state -> (Data, Int)? in
                guard !state.stopped, !state.items.isEmpty else {
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
