import Foundation

enum WorkerStatus: Sendable, Equatable {
    /// 起動して ready を待っている。
    case starting
    /// ready の前に時間がかかっている。初回はモデルの取得が走る（設計書 12.2）。
    case preparingModel
    case ready
    /// 自動で再起動する途中。
    case retrying(String)
    /// 自動の再試行を止めた。メニューの「再試行」で再開する。
    case unavailable(String)
}

struct Transcript: Sendable {
    let text: String
    /// `complete` か `model_limit`（設計書 12.4）。
    let stop: String
}

/// 起動する実行ファイルの差し替え。`--selftest-preview-worker` が同じバイナリを
/// `--fake-worker <シナリオ>` で起動するためにだけ使う（設計書 9.1）。
struct WorkerLaunch: Sendable, Equatable {
    var executable: String
    var arguments: [String]
}

/// worker プロセス1つを常駐させ、JSON Lines の往復を直列化する。
actor SpeechWorkerClient {
    private struct PendingRequest {
        var continuation: CheckedContinuation<WorkerProtocol.Terminal, Error>?
        /// 継続を入れる前に終端メッセージが来た場合に預かる。
        var terminal: Result<WorkerProtocol.Terminal, Error>?
        var lastMessage: Date
    }

    private let onStatus: @Sendable (WorkerStatus) -> Void
    private let launchOverride: WorkerLaunch?

    private var process: Process?
    private var writer: PipeWriter?
    private var readerTask: Task<Void, Never>?
    private var superviseTask: Task<Void, Never>?
    private var terminationContinuation: CheckedContinuation<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    /// 継続を入れる前に ready / fatal が来た場合に預かる。
    private var readySettled: Result<Void, Error>?

    private var pending: [String: PendingRequest] = [:]
    private var lastActivity = Date()
    private var consecutiveFailures = 0
    private var isReady = false
    private var stopping = false
    /// 起動ごとに増やす世代。終了通知や標準出力のコールバックは、どのプロセスの
    /// ものか分からないまま状態を変えてはいけない。遅れて届いた旧プロセスの通知が
    /// 新しいプロセスの待機を壊さないよう、世代が現行のときだけ作用させる。
    private var launchGeneration = 0

    init(launch: WorkerLaunch? = nil, onStatus: @escaping @Sendable (WorkerStatus) -> Void) {
        launchOverride = launch
        self.onStatus = onStatus
    }

    /// 起動した回数。プレビューの失敗で worker を作り直していないことを
    /// `--selftest-preview-worker` から確かめる（設計書 8.2、9.2）。
    var launchCount: Int { launchGeneration }

    // MARK: 常駐と再起動

    func start() {
        guard superviseTask == nil else { return }
        superviseTask = Task { [weak self] in await self?.supervise() }
    }

    /// メニューの「再試行」から呼ぶ。自動の再試行を止めた状態から再開する。
    func retry() {
        consecutiveFailures = 0
        superviseTask?.cancel()
        superviseTask = Task { [weak self] in await self?.supervise() }
    }

    func shutdown() async {
        stopping = true
        superviseTask?.cancel()
        superviseTask = nil
        await terminate(graceful: true)
    }

    /// `--selftest-worker` 用。再起動の監視を付けず、1回だけ起動して ready を待つ。
    func startOnce() async throws {
        try await launch()
        isReady = true
        onStatus(.ready)
    }

    private func supervise() async {
        while !Task.isCancelled, !stopping {
            var reason = "原因不明"
            onStatus(.starting)
            do {
                try await launch()
                consecutiveFailures = 0
                isReady = true
                onStatus(.ready)
                await waitForTermination()
                reason = WorkerFailure.terminated.userMessage
                Log.worker.notice("worker terminated")
            } catch {
                reason = Self.message(of: error)
                Log.worker.error("worker start failed: \(Self.code(of: error), privacy: .public)")
            }
            isReady = false
            failAllPending(WorkerFailure.terminated)
            await terminate(graceful: false)
            if Task.isCancelled || stopping { return }

            consecutiveFailures += 1
            if consecutiveFailures >= AppConfiguration.maxConsecutiveWorkerFailures {
                Log.worker.error("worker failed \(self.consecutiveFailures, privacy: .public) times, giving up")
                onStatus(.unavailable(reason))
                return
            }
            let delay = backoffSeconds(for: consecutiveFailures)
            onStatus(.retrying(reason))
            Log.worker.notice("""
            worker restart in \(delay, privacy: .public) s \
            (failure \(self.consecutiveFailures, privacy: .public))
            """)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func backoffSeconds(for failures: Int) -> Double {
        let table = AppConfiguration.restartBackoffSeconds
        let index = max(0, failures - 1)
        return index < table.count ? table[index] : AppConfiguration.restartBackoffCapSeconds
    }

    // MARK: 起動

    /// `.app` から起動したプロセスの PATH にログインシェルの設定は入らないので、
    /// 絶対パスで順に探す（設計書 12.1）。
    static func locateExecutable() throws -> String {
        let manager = FileManager.default
        for path in AppConfiguration.speechSearchPaths where manager.isExecutableFile(atPath: path) {
            return path
        }
        throw WorkerFailure.executableNotFound(AppConfiguration.speechSearchPaths)
    }

    private func launch() async throws {
        let executable = try launchOverride?.executable ?? Self.locateExecutable()
        launchGeneration += 1
        let generation = launchGeneration
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = launchOverride?.arguments ?? ["worker", AppConfiguration.model]

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let (stdoutData, stdoutContinuation) = AsyncStream<Data>.makeStream()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                stdoutContinuation.finish()
            } else {
                stdoutContinuation.yield(data)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // stderr の中身は Logger へ渡さない。worker が何を出すかは保証されず、
            // 本文が混ざれば長さ制限や `.private` では無記録を保証できない
            // （設計書 14、レビュー MUST 8）。記録するのは長さだけである。
            Log.worker.debug("stderr \(data.count, privacy: .public) bytes")
            Task { await self?.noteActivity(generation: generation) }
        }
        process.terminationHandler = { [weak self] finished in
            Log.worker.notice("worker exit status \(finished.terminationStatus, privacy: .public)")
            Task { await self?.resumeTermination(generation: generation) }
        }

        do {
            try process.run()
        } catch {
            throw WorkerFailure.spawnFailed(error.localizedDescription)
        }

        self.process = process
        writer = PipeWriter(handle: input.fileHandleForWriting)
        readySettled = nil
        noteActivity(generation: generation)
        readerTask = Task { [weak self] in
            await self?.readLines(from: stdoutData, generation: generation)
        }
        try await waitReady()
    }

    /// ready は固定時間で待たない。モデル取得の間は stderr に出力が続くので、
    /// 出力が止まってからの経過で判定する（設計書 12.2）。
    private func waitReady() async throws {
        let watchdog = Task { [weak self] in
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                elapsed += 1
                guard let self else { return }
                if elapsed == 5 { await self.reportPreparing() }
                if await self.idleSeconds() > AppConfiguration.readyIdleTimeoutSeconds {
                    await self.finishReady(.failure(WorkerFailure.timeout("ready")))
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        if let settled = readySettled {
            readySettled = nil
            return try settled.get()
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if let settled = readySettled {
                readySettled = nil
                continuation.resume(with: settled)
            } else {
                readyContinuation = continuation
            }
        }
    }

    private func reportPreparing() {
        guard !isReady else { return }
        onStatus(.preparingModel)
    }

    private func idleSeconds() -> Double {
        Date().timeIntervalSince(lastActivity)
    }

    private func noteActivity(generation: Int) {
        guard generation == launchGeneration else { return }
        lastActivity = Date()
    }

    private func finishReady(_ result: Result<Void, Error>) {
        guard let continuation = readyContinuation else {
            if readySettled == nil { readySettled = result }
            return
        }
        readyContinuation = nil
        continuation.resume(with: result)
    }

    private func resumeTermination(generation: Int) {
        guard generation == launchGeneration else {
            // 旧プロセスの終了通知。新しいプロセスの待機は壊さない。
            Log.worker.debug("ignored termination notice from a previous worker")
            return
        }
        failAllPending(WorkerFailure.terminated)
        finishReady(.failure(WorkerFailure.terminated))
        guard let continuation = terminationContinuation else { return }
        terminationContinuation = nil
        continuation.resume()
    }

    private func waitForTermination() async {
        if process?.isRunning != true { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if process?.isRunning != true {
                continuation.resume()
            } else {
                terminationContinuation = continuation
            }
        }
    }

    private func terminate(graceful: Bool) async {
        readerTask?.cancel()
        readerTask = nil
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        // 標準入力を閉じると worker は手元のリクエストに答えて 0 で終わる（設計書 12.7）。
        writer?.close()
        writer = nil
        guard let process, process.isRunning else {
            self.process = nil
            return
        }
        if graceful {
            let deadline = Date().addingTimeInterval(AppConfiguration.shutdownGraceSeconds)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
    }

    // MARK: 標準出力

    private func readLines(from stream: AsyncStream<Data>, generation: Int) async {
        var buffer = Data()
        for await data in stream {
            noteActivity(generation: generation)
            buffer.append(data)
            while let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex ..< index])
                buffer.removeSubrange(buffer.startIndex ... index)
                handle(line: line, generation: generation)
            }
        }
        // 改行で終わらない残りは、途中で切れた行である。読み捨てるとプロトコルが
        // ずれたまま進むので、worker の欠陥として扱う（設計書 12.3）。
        if !buffer.isEmpty, !stopping {
            violate("改行で終わらない行", generation: generation)
        }
    }

    /// 解釈できない行はスキップせず、worker の欠陥として扱って再起動する
    /// （設計書 12.3、worker-protocol.md「stdout carries the protocol and nothing else」）。
    private func violate(_ detail: String, generation: Int) {
        guard generation == launchGeneration else { return }
        Log.worker.error("protocol violation on stdout, restarting worker")
        let failure = WorkerFailure.protocolViolation(detail)
        finishReady(.failure(failure))
        failAllPending(failure)
        process?.terminate()
    }

    private func handle(line: Data, generation: Int) {
        guard generation == launchGeneration else { return }
        guard !line.isEmpty else {
            violate("空の行", generation: generation)
            return
        }
        let message: WorkerProtocol.Incoming
        do {
            message = try WorkerProtocol.decode(line: line)
        } catch {
            violate("JSON オブジェクトでない行", generation: generation)
            return
        }

        switch message.type {
        case "ready":
            finishReady(validate(ready: message))
        case "fatal":
            let failure = Self.failure(from: message.error)
            Log.worker.error("worker fatal: \(failure.code, privacy: .public)")
            finishReady(.failure(failure))
        case "progress":
            // progress は走っているリクエストに付く。id のない progress は
            // どのリクエストの沈黙を測っているのか決められない。
            guard let id = message.id else {
                violate("id のない progress", generation: generation)
                return
            }
            touch(id)
        case "end":
            guard let id = message.id else {
                violate("id のない end", generation: generation)
                return
            }
            guard pending[id] != nil else {
                // 終端のあとに来た行、または呼び出し側が降りたリクエスト
                // （設計書 12.3）。必須の member は待っている分だけ確かめる。
                // `info` や `count_tokens` の end は text も stop も持たない。
                Log.worker.debug("terminal for unknown request")
                return
            }
            // このアプリが出すのは認識リクエストだけなので、その end は text と
            // stop を必ず持つ（worker-protocol.md）。欠けた値を空文字や
            // complete で補うと、失敗を成功として貼ってしまう。
            guard let text = message.text, let stop = message.stop else {
                violate("text か stop が欠けた end", generation: generation)
                return
            }
            deliver(id: id, .success(.end(text: text, stop: stop)))
        case "error":
            // id のない error は、どのリクエストにも結び付かない行への応答として
            // 文書が認めている。code は必須。
            guard let code = message.error?.code, !code.isEmpty else {
                violate("code のない error", generation: generation)
                return
            }
            let failure = Self.failure(from: message.error)
            if let id = message.id {
                deliver(id: id, .failure(failure))
            } else {
                Log.worker.error("worker error without id: \(failure.code, privacy: .public)")
            }
        case "cancelled":
            guard let id = message.id else {
                violate("id のない cancelled", generation: generation)
                return
            }
            deliver(id: id, .success(.cancelled))
        default:
            // message が増えても protocol は上がらない。知らない type は無視する。
            Log.worker.debug("ignored message type \(message.type, privacy: .public)")
        }
    }

    private func validate(ready message: WorkerProtocol.Incoming) -> Result<Void, Error> {
        guard message.protocolVersion == AppConfiguration.workerProtocolVersion else {
            let actual = message.protocolVersion.map(String.init) ?? "なし"
            return .failure(WorkerFailure.protocolViolation(
                "protocol が \(AppConfiguration.workerProtocolVersion) ではありません（\(actual)）"
            ))
        }
        guard message.model?.task == "recognition" else {
            return .failure(WorkerFailure.protocolViolation("認識モデルではありません"))
        }
        guard message.model?.languages?.contains(AppConfiguration.language) == true else {
            return .failure(WorkerFailure.protocolViolation("日本語に対応していません"))
        }
        Log.worker.notice("""
        ready protocol=\(message.protocolVersion ?? 0, privacy: .public) \
        version=\(message.version ?? "?", privacy: .public) \
        sample_rate=\(message.model?.sampleRate ?? 0, privacy: .public)
        """)
        return .success(())
    }

    // MARK: リクエスト

    /// 録音ごとに新しい id を作る（設計書 12.4）。
    func newRequest() -> String {
        let id = "r-\(UUID().uuidString)"
        pending[id] = PendingRequest(continuation: nil, terminal: nil, lastMessage: Date())
        return id
    }

    func send(chunk pcm: Data, id: String, seq: Int) async throws {
        try await write(WorkerProtocol.chunkLine(id: id, seq: seq, pcm: pcm))
    }

    /// `transcribe` を送り、終端メッセージを待つ。
    func transcribe(id: String) async throws -> Transcript {
        try await write(WorkerProtocol.transcribeLine(
            id: id,
            sampleRate: Int(AppConfiguration.workerSampleRate),
            language: AppConfiguration.language
        ))
        touch(id)
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if await self.silentSeconds(for: id) > AppConfiguration.transcribeIdleTimeoutSeconds {
                    await self.timeOut(id: id)
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        switch try await waitTerminal(id: id) {
        case let .end(text, stop):
            return Transcript(text: text, stop: stop)
        case let .failed(code, message):
            throw WorkerFailure.workerError(code: code, message: message)
        case .cancelled:
            throw WorkerFailure.cancelled
        }
    }

    // MARK: プレビュー専用の経路

    /// プレビューごとに新しい id を作る。終端した id は再利用しないので、
    /// 「id は終端前の要求の中で一意」という条件を自明に満たす（設計書 5.4）。
    ///
    /// `pending` へ登録するので、worker が落ちたときは `failAllPending` が
    /// プレビューも畳む。
    func newPreviewRequest() -> String {
        let id = "p-\(UUID().uuidString)"
        pending[id] = PendingRequest(continuation: nil, terminal: nil, lastMessage: Date())
        return id
    }

    /// プレビュー1回ぶん。「ここまでの音声全体」を1行の `chunk` で送ってから
    /// `transcribe` し、終端を待つ。0.25 秒ずつ分けるより送信が 3.6 倍速い
    /// （設計書 4.2）。
    ///
    /// 沈黙しても worker を作り直さない。既存の `timeOut(id:)` は
    /// `process?.terminate()` を呼ぶので、プレビューはその関数を通さない
    /// （設計書 8.2）。プレビューの不調が録音ごと壊してはいけない。
    func preview(id: String, pcm: Data) async throws -> String {
        do {
            try await write(WorkerProtocol.chunkLine(id: id, seq: 0, pcm: pcm))
            try await write(WorkerProtocol.transcribeLine(
                id: id,
                sampleRate: Int(AppConfiguration.workerSampleRate),
                language: AppConfiguration.language
            ))
        } catch {
            // 書けなかった id は終端を待たない。表に残すと worker の作り直しまで
            // 居座る。書き込みの失敗そのものは既存の `write` が扱う（設計書 8.2）。
            pending.removeValue(forKey: id)
            throw error
        }
        touch(id)
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                if await self.silentSeconds(for: id) > AppConfiguration.previewIdleTimeoutSeconds {
                    await self.timeOutPreview(id: id)
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        switch try await waitTerminal(id: id) {
        case let .end(text, _):
            return text
        case let .failed(code, message):
            throw WorkerFailure.workerError(code: code, message: message)
        case .cancelled:
            throw WorkerFailure.cancelled
        }
    }

    /// プレビューが沈黙した。その id へ `cancel` を送って失敗にするが、worker は
    /// 作り直さない（設計書 8.2）。
    private func timeOutPreview(id: String) async {
        Log.worker.debug("preview timed out")
        // 先に待ち側を解放する。`write` が詰まっていても次のラウンドへ進める。
        deliver(id: id, .failure(WorkerFailure.timeout("preview")))
        try? await write(WorkerProtocol.cancelLine(id: id))
    }

    /// Esc で取り消す。文書のとおり `transcribe` は送らない（設計書 12.5）。
    ///
    /// 表から先に外す。録音中の取り消しでは `waitTerminal` が呼ばれていないので、
    /// 終端を預けると誰も引き取らず `pending` に残り続ける。外したあとに届く
    /// `cancelled` や `end` は、終端のあとに来た行として無視される（設計書 12.3）。
    func cancel(id: String) async {
        if let request = pending.removeValue(forKey: id), let continuation = request.continuation {
            continuation.resume(throwing: WorkerFailure.cancelled)
        }
        try? await write(WorkerProtocol.cancelLine(id: id))
    }

    private func waitTerminal(id: String) async throws -> WorkerProtocol.Terminal {
        if let stored = pending[id]?.terminal {
            pending.removeValue(forKey: id)
            return try stored.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            guard var request = pending[id] else {
                continuation.resume(throwing: WorkerFailure.terminated)
                return
            }
            if let stored = request.terminal {
                pending.removeValue(forKey: id)
                continuation.resume(with: stored)
                return
            }
            request.continuation = continuation
            pending[id] = request
        }
    }

    private func deliver(id: String, _ result: Result<WorkerProtocol.Terminal, Error>) {
        guard var request = pending[id] else {
            // 終端のあとに来た行、または呼び出し側が降りたリクエスト。state.rs と同じく無視する。
            Log.worker.debug("terminal for unknown request")
            return
        }
        if let continuation = request.continuation {
            pending.removeValue(forKey: id)
            continuation.resume(with: result)
        } else {
            request.terminal = result
            pending[id] = request
        }
    }

    private func touch(_ id: String) {
        pending[id]?.lastMessage = Date()
    }

    private func silentSeconds(for id: String) -> Double {
        guard let request = pending[id] else { return 0 }
        return Date().timeIntervalSince(request.lastMessage)
    }

    private func timeOut(id: String) async {
        Log.worker.error("transcribe timed out, restarting worker")
        try? await write(WorkerProtocol.cancelLine(id: id))
        deliver(id: id, .failure(WorkerFailure.timeout("transcribe")))
        // 応答しない worker は作り直す（設計書 12.6）。
        process?.terminate()
    }

    private func failAllPending(_ error: Error) {
        for id in Array(pending.keys) {
            deliver(id: id, .failure(error))
        }
        pending.removeAll()
    }

    private func write(_ data: Data) async throws {
        guard let writer else { throw WorkerFailure.notRunning }
        do {
            try await writer.write(data, timeout: AppConfiguration.writeTimeoutSeconds)
        } catch {
            // パイプが詰まったら worker が読んでいない。作り直す（設計書 12.6）。
            Log.worker.error("stdin write failed, restarting worker")
            process?.terminate()
            throw error
        }
    }

    // MARK: エラーの文字列化

    private static func failure(from body: WorkerProtocol.WorkerErrorBody?) -> WorkerFailure {
        WorkerFailure.workerError(code: body?.code ?? "unknown", message: body?.message ?? "詳細なし")
    }

    static func code(of error: Error) -> String {
        (error as? WorkerFailure)?.code ?? "unknown"
    }

    static func message(of error: Error) -> String {
        (error as? WorkerFailure)?.userMessage ?? "原因不明のエラー"
    }
}
