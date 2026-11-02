import Darwin
import Foundation
import os

/// 書き込み1件の予約。`PipeWriter` の直列キューへ積んだ順に書く。
///
/// 書き始める前なら `expire()` で捨てられる。書き始めたあとは捨てられない。
/// JSON の行を途中で切ると worker の読み取りがずれるので、始めた行は最後まで
/// 書く（レビュー MUST 2）。
final class PipeWrite: @unchecked Sendable {
    private enum Phase {
        case queued
        case writing
        case done
    }

    private let lock = NSLock()
    private var phase = Phase.queued
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    /// キューの順番が来た。期限で捨てられていれば `false` を返す。呼び出し側は
    /// そのとき1バイトも書かない。
    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .queued else { return false }
        phase = .writing
        return true
    }

    /// 書き始めるまでの期限。まだ順番待ちなら捨てる。書き込み中なら何もしない。
    func expire() {
        settle(from: .queued, with: .failure(WorkerFailure.timeout("preview_send")))
    }

    /// 書き終わった、または書けなかった。
    func finish(_ result: Result<Void, Error>) {
        settle(from: .writing, with: result)
    }

    /// 結果を待つ。待たずに捨ててもよい（継続を入れていなければ結果を預かるだけ）。
    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    /// 1件の予約は1回だけ確定する。継続の再開はロックの外で行う。
    private func settle(from expected: Phase, with result: Result<Void, Error>) {
        lock.lock()
        guard phase == expected else {
            lock.unlock()
            return
        }
        phase = .done
        self.result = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}

/// 標準入力への書き込みを専用の直列キューで行う。actor やオーディオスレッドを
/// ブロックしないため、書き込みはすべてここを通す（設計書 12.6）。
///
/// 書き込み先は非ブロッキングにして、期限までを `poll` で待つ。ブロックする
/// `write` を使うと、期限のタイマーが切れても呼び出し側はその完了を待つことに
/// なり、worker の作り直しまで戻れない。
final class PipeWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "\(AppConfiguration.bundleIdentifier).worker-write")
    private let handle: FileHandle
    private let descriptor: Int32
    private let closed = OSAllocatedUnfairLock(initialState: false)

    init(handle: FileHandle) {
        self.handle = handle
        descriptor = handle.fileDescriptor
        // O_NONBLOCK は親が持つ書き込み端だけに付く。worker が持つ読み取り端は
        // 別の file description なので、worker 側の読み方は変わらない。
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    func close() {
        // 先に印を付ける。待っている書き込みは次の区切りで失敗して抜ける。
        closed.withLock { $0 = true }
        queue.async {
            try? self.handle.close()
        }
    }

    /// 期限は呼び出した時点から数える。前の書き込みが詰まっている場合、順番が
    /// 来た時点で期限を過ぎていれば即座に失敗し、呼び出し側を待たせない。
    func write(_ data: Data, timeout: Double) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.writeAll(data, deadline: deadline)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 直列キューへ積む。積んだ順に書き、1行の途中へ別の書き込みを割り込ませない。
    /// 積むところまでは同期なので、呼び出し側は他の書き込みとの順序を `await` を
    /// 挟まずに決められる（レビュー MUST 1）。
    ///
    /// 書き始めるまでの期限は呼び出し側が `PipeWrite.expire()` で掛ける。書き
    /// 始めたあとは期限で切らない。読み手が消えれば `poll` が POLLHUP を返し、
    /// `close()` でも抜けるので、待ち続けることはない（レビュー MUST 2）。
    func enqueue(_ data: Data) -> PipeWrite {
        let write = PipeWrite()
        queue.async { [self] in
            guard write.begin() else { return }
            do {
                try writeAll(data, deadline: nil)
                write.finish(.success(()))
            } catch {
                write.finish(.failure(error))
            }
        }
        return write
    }

    /// 非ブロッキングなので部分書き込みが起きる。全部書けるまで繰り返す。
    /// `deadline` が `nil` のときは、書き終わるかパイプが壊れるまで待つ。
    private func writeAll(_ data: Data, deadline: Date?) throws {
        guard !closed.withLock({ $0 }) else { throw WorkerFailure.notRunning }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                // 残りが 0 でないのに 0 を返すのはパイプでは起きない。errno も
                // 更新されていないので、進まない書き込みとして扱う。
                guard written < 0 else { throw WorkerFailure.terminated }
                let code = errno
                if code == EINTR { continue }
                guard code == EAGAIN || code == EWOULDBLOCK else {
                    throw Self.failure(for: code)
                }
                try waitWritable(until: deadline)
            }
        }
    }

    /// 書けるようになるか、期限が来るか、`close()` されるまで待つ。短く区切って
    /// 待つことで、終了処理がこのキューの後ろで止まらないようにする。
    private func waitWritable(until deadline: Date?) throws {
        while true {
            guard !closed.withLock({ $0 }) else { throw WorkerFailure.notRunning }
            var slice = Int32((AppConfiguration.writePollSliceSeconds * 1000).rounded(.up))
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw WorkerFailure.timeout("write") }
                slice = Int32((min(remaining, AppConfiguration.writePollSliceSeconds) * 1000).rounded(.up))
            }
            var target = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&target, 1, slice)
            if ready < 0 {
                if errno == EINTR { continue }
                throw Self.failure(for: errno)
            }
            if target.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                // worker が読み取り端を閉じた。
                throw WorkerFailure.terminated
            }
            if ready > 0 { return }
        }
    }

    private static func failure(for code: Int32) -> WorkerFailure {
        if code == EPIPE || code == EBADF { return .terminated }
        return .spawnFailed(String(cString: strerror(code)))
    }
}
