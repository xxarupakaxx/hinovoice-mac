import AppKit
import Foundation
import os

/// メニューバーに出す内容。状態を1箇所に集めて渡す（設計書 15）。
struct MenuPresentation: Equatable {
    var symbolName: String
    var statusText: String
    var showsRetry: Bool
    var showsAccessibilityHelp: Bool
}

/// 1回の録音の世代。Esc と認識完了は競合しうるので、取り消しは `invalidate()`
/// で世代を進め、`await` の再開地点ごとに `isCurrent(_:)` で照合する。これを
/// 怠ると、取り消したあとに届いた結果を貼り付け、古い処理の後始末が新しい
/// セッションを消す（設計書 9）。`--selftest-session` で検証する。
struct SessionGeneration: Equatable {
    private var value = 0

    /// いま有効な世代。進行中のセッションを引き継ぐ側が読む。
    var current: Int { value }

    /// 新しいセッションを始め、その世代を返す。
    mutating func begin() -> Int {
        value += 1
        return value
    }

    /// 取り消し。進行中のどの世代とも一致しなくなる。
    mutating func invalidate() {
        value += 1
    }

    func isCurrent(_ session: Int) -> Bool {
        value == session
    }
}

/// 終了処理と、開始・貼り付けの可否（レビュー MUST 7）。`shutdown()` は最初に
/// 同期で `beginShutdown()` を呼び、新しい開始と新しい貼り付けを断ってから、
/// 進行中の貼り付けがクリップボードを戻すのを待つ。順番を逆にすると、待つか
/// どうかを決めたあとに始まった貼り付けを取りこぼし、元のクリップボードが
/// 戻らない。純粋な状態なので `--selftest-shutdown` で検証する。
struct ShutdownGate: Equatable {
    /// 終了処理が始まっているか。一度立つと戻らない。
    private(set) var isShuttingDown = false
    /// 貼り付けを予約してから復元が終わるまで。
    private(set) var isPasting = false

    /// 新しい録音と worker の再起動を始めてよいか。
    var allowsStart: Bool { !isShuttingDown }

    /// 終了処理が貼り付けの復元を待つ必要があるか。
    var waitsForPaste: Bool { isPasting }

    /// 終了の開始。これ以降は開始も貼り付けも受け付けない。
    mutating func beginShutdown() {
        isShuttingDown = true
    }

    /// 貼り付けを予約する。終了処理が始まっていれば予約できない。
    mutating func beginPaste() -> Bool {
        guard !isShuttingDown else { return false }
        isPasting = true
        return true
    }

    /// クリップボードの復元まで終わった。
    mutating func endPaste() {
        isPasting = false
    }
}

/// 状態遷移を行うのはこの型だけ（設計書 9）。
@MainActor
final class RecordingCoordinator {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case pasting
        case unavailable(String)

        /// 録音中・文字起こし中・貼り付け中は Enter と Esc を飲み込む。
        var swallowsConfirmKeys: Bool {
            switch self {
            case .recording, .transcribing, .pasting: true
            case .idle, .unavailable: false
            }
        }

        /// 停止中も開始キーは受ける（理由をメニューに出すため）。
        var acceptsStartKey: Bool {
            switch self {
            case .idle, .unavailable: true
            case .recording, .transcribing, .pasting: false
            }
        }

        var name: String {
            switch self {
            case .idle: "idle"
            case .recording: "recording"
            case .transcribing: "transcribing"
            case .pasting: "pasting"
            case .unavailable: "unavailable"
            }
        }
    }

    private var state: State = .idle
    private var workerStatus: WorkerStatus = .starting
    private var notice: String?
    private var noticeTask: Task<Void, Never>?

    private let worker: SpeechWorkerClient
    private var monitor: KeyboardMonitor?
    private var capture: AudioCapture?
    private var sender: ChunkSender?
    private var requestID: String?
    private var target: PasteTarget?
    private var limitTask: Task<Void, Never>?
    private var tapInstalled = false

    private var generation = SessionGeneration()
    /// 開始処理が走っている間。マイクの許可待ちと `newRequest` の待ちの間も
    /// 状態は idle のままなので、これがないと開始処理が二重に入る。
    private var isStarting = false
    /// 終了処理の印と、貼り付けが進んでいるかどうか。
    private var gate = ShutdownGate()
    private var pasteWaiters: [CheckedContinuation<Void, Never>] = []

    var onPresentation: ((MenuPresentation) -> Void)?

    init() {
        let box = StatusBox()
        worker = SpeechWorkerClient { status in
            // worker の actor から MainActor へ渡す。
            Task { @MainActor in
                box.coordinator?.apply(workerStatus: status)
            }
        }
        box.coordinator = self
    }

    /// 起動時に1回呼ぶ。
    func start() {
        let monitor = KeyboardMonitor { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }
        self.monitor = monitor
        tapInstalled = monitor.install()
        if !tapInstalled {
            Log.app.error("event tap unavailable; accessibility not granted")
            Permissions.promptAccessibility()
        }
        syncTap()
        Task { await worker.start() }
        publish()
    }

    func retryWorker() {
        guard gate.allowsStart else { return }
        state = .idle
        notice = nil
        Task { await worker.retry() }
        publish()
    }

    /// タップを作れなかったあとに許可を得た場合、再起動せずに作り直せるようにする。
    func retryTap() {
        guard !tapInstalled, let monitor else { return }
        tapInstalled = monitor.install()
        syncTap()
        publish()
    }

    func shutdown() async {
        // 最初の `await` より前に、同期で終了を確定させる。印を立てて新しい開始と
        // 貼り付けを断り、世代を無効化して録音・文字起こしを畳む。こうしないと、
        // 文字起こし中に終了した場合に、`await worker.shutdown()` の中断中に届いた
        // 結果から貼り付けが始まり、クリップボードが戻らない（レビュー MUST 7）。
        gate.beginShutdown()
        _ = invalidateSession()
        // 状態が idle のままなら `transition` は何もしないので、ここで明示的に
        // タップへ伝える。終了中のキーは飲み込まずアプリへ渡す。
        syncTap()
        // 400ms の復元待ちの途中で終わらせると、元のクリップボードを戻せない。
        // すでに始まっている貼り付けが終わってから worker を止める。
        if gate.waitsForPaste {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pasteWaiters.append(continuation)
            }
        }
        await worker.shutdown()
    }

    // MARK: キーのイベント

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .start:
            Task { await beginRecording() }
        case .confirm:
            if state == .recording {
                Task { await stopAndTranscribe() }
            }
        case .cancel:
            if state == .recording || state == .transcribing {
                cancelSession()
            }
        }
    }

    // MARK: 遷移

    private func beginRecording() async {
        guard gate.allowsStart, !isStarting, state.acceptsStartKey else { return }
        if case let .unavailable(reason) = state {
            show(notice: reason)
            return
        }
        guard workerStatus == .ready else {
            show(notice: statusText(for: workerStatus))
            return
        }

        // ここから最初の await までの間に予約する。開始キーの連打でも、
        // capture・requestID・制限時間タスクを上書きさせない。
        isStarting = true
        defer { isStarting = false }
        let session = generation.begin()

        guard await Permissions.requestMicrophone() else {
            show(notice: "マイクの許可がありません")
            return
        }
        guard isCurrent(session), state.acceptsStartKey else { return }
        guard Permissions.isAccessibilityTrusted else {
            show(notice: "アクセシビリティの許可がありません")
            Permissions.promptAccessibility()
            return
        }

        let target = PasteTarget.current()
        let id = await worker.newRequest()
        guard isCurrent(session), state.acceptsStartKey, workerStatus == .ready else {
            await worker.cancel(id: id)
            return
        }

        self.target = target
        requestID = id
        let sender = ChunkSender(worker: worker, requestID: id)
        self.sender = sender
        let capture = AudioCapture { chunk in
            sender.send(chunk)
        }
        do {
            try capture.start()
        } catch {
            requestID = nil
            sender.stop()
            self.sender = nil
            self.target = nil
            await worker.cancel(id: id)
            let message = (error as? AudioFailure)?.userMessage ?? "録音を開始できません"
            Log.audio.error("capture start failed")
            show(notice: message)
            return
        }
        self.capture = capture
        transition(to: .recording)

        limitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AppConfiguration.maxRecordingSeconds))
            guard !Task.isCancelled else { return }
            await self?.stopAndTranscribe()
        }
    }

    private func stopAndTranscribe() async {
        guard state == .recording, let id = requestID, let capture else { return }
        let session = generation.current
        limitTask?.cancel()
        limitTask = nil
        let tail = capture.stop()
        let seconds = capture.recordedSeconds
        self.capture = nil
        transition(to: .transcribing)
        Log.state.notice("""
        recording stopped (\(seconds, privacy: .public) s, \
        \(self.sender?.sentChunks ?? 0, privacy: .public) chunks)
        """)

        let started = Date()
        do {
            await sender?.finish(tail)
            // Esc は await の前に世代を無効化する。再開地点ごとに照合して、
            // 取り消したあとの結果を貼らない。
            guard isCurrent(session) else { return }
            let transcript = try await worker.transcribe(id: id)
            guard isCurrent(session) else {
                Log.state.notice("transcript dropped; session already cancelled")
                return
            }
            let elapsed = Date().timeIntervalSince(started)
            Log.worker.notice("""
            end received in \(elapsed, privacy: .public) s, \
            stop=\(transcript.stop, privacy: .public), \
            \(transcript.text.count, privacy: .public) characters
            """)
            requestID = nil
            sender = nil
            // 貼り付けの予約は await を挟む前に済ませる。`paste` の中で印を
            // 付けると、その呼び出しの中断中に終了処理が通り抜けられる。
            guard beginPaste() else {
                Log.state.notice("paste refused; shutting down")
                return
            }
            // 段階2の AI 整形はこの1行の前に入る（設計書 15）。
            await paste(transcript.text, session: session)
        } catch {
            guard isCurrent(session) else { return }
            requestID = nil
            sender = nil
            let failure = error as? WorkerFailure
            if case .cancelled = failure {
                Log.state.notice("transcribe cancelled")
            } else {
                Log.worker.error("transcribe failed: \(SpeechWorkerClient.code(of: error), privacy: .public)")
                show(notice: SpeechWorkerClient.message(of: error))
            }
            transition(to: .idle)
        }
    }

    /// 貼り付けを予約する。終了処理はここからクリップボードの復元までを待つ。
    /// 終了が始まっていれば予約できない（レビュー MUST 7）。
    private func beginPaste() -> Bool {
        guard gate.beginPaste() else { return false }
        transition(to: .pasting)
        return true
    }

    private func paste(_ text: String, session: Int) async {
        let target = self.target
        self.target = nil
        let outcome = await TextInserter.insert(text, into: target)
        gate.endPaste()
        releasePasteWaiters()
        // 貼り付け中は開始も取り消しも受けないので、ここで世代が変わるのは
        // 想定外である。変わっていれば状態はすでに待機中に戻っている。
        guard isCurrent(session) else { return }
        if let message = outcome.userMessage {
            show(notice: message)
        }
        transition(to: .idle)
    }

    /// 取り消しの同期部分。`await` を1つも含まないので、呼び出し元へ戻った
    /// 時点で古いセッションの結果は貼られない。
    private func invalidateSession() -> String? {
        generation.invalidate()
        limitTask?.cancel()
        limitTask = nil
        _ = capture?.stop()
        capture = nil
        sender?.stop()
        sender = nil
        target = nil
        let id = requestID
        requestID = nil
        transition(to: .idle)
        return id
    }

    private func cancelSession() {
        guard let id = invalidateSession() else { return }
        Task { [worker] in await worker.cancel(id: id) }
    }

    private func isCurrent(_ session: Int) -> Bool {
        generation.isCurrent(session)
    }

    private func releasePasteWaiters() {
        let waiters = pasteWaiters
        pasteWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func transition(to next: State) {
        guard state != next else { return }
        Log.state.notice("state: \(self.state.name, privacy: .public) -> \(next.name, privacy: .public)")
        state = next
        syncTap()
        publish()
    }

    private func apply(workerStatus status: WorkerStatus) {
        workerStatus = status
        switch status {
        case let .unavailable(reason):
            transition(to: .unavailable(reason))
        case .ready:
            if case .unavailable = state {
                transition(to: .idle)
            }
        case let .retrying(reason):
            // 録音中に worker が落ちたら、待っても結果は来ない。キーの飲み込みを
            // 解除するために、ここで必ず待機中へ戻す（設計書 9）。
            if state == .recording || state == .transcribing {
                show(notice: reason)
                cancelSession()
            }
        case .starting, .preparingModel:
            break
        }
        publish()
    }

    /// コールバックが同期的に読む値を更新する（設計書 10.2）。終了が始まったあとは
    /// 何も飲み込まず、開始キーも受けない（レビュー MUST 7）。
    private func syncTap() {
        monitor?.update(
            swallowsConfirmKeys: gate.allowsStart && state.swallowsConfirmKeys,
            acceptsStartKey: gate.allowsStart && state.acceptsStartKey
        )
    }

    // MARK: 表示

    private func show(notice message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
            self?.publish()
        }
        publish()
    }

    private func publish() {
        onPresentation?(presentation())
    }

    private func presentation() -> MenuPresentation {
        MenuPresentation(
            symbolName: symbolName(),
            statusText: notice ?? stateText(),
            showsRetry: isUnavailable,
            showsAccessibilityHelp: !tapInstalled || !Permissions.isAccessibilityTrusted
        )
    }

    private var isUnavailable: Bool {
        if case .unavailable = state { return true }
        return false
    }

    private func symbolName() -> String {
        switch state {
        case .idle: workerStatus == .ready ? "mic" : "mic.badge.xmark"
        case .recording: "mic.fill"
        case .transcribing, .pasting: "waveform"
        case .unavailable: "exclamationmark.triangle"
        }
    }

    private func stateText() -> String {
        switch state {
        case .idle:
            if !tapInstalled { return "アクセシビリティの許可が必要です" }
            return workerStatus == .ready ? "待機中（⌃⌥Space で録音）" : statusText(for: workerStatus)
        case .recording: return "録音中（Enter で確定、Esc で取り消し）"
        case .transcribing: return "文字起こし中"
        case .pasting: return "貼り付け中"
        case let .unavailable(reason): return reason
        }
    }

    private func statusText(for status: WorkerStatus) -> String {
        switch status {
        case .starting: "speech を起動中"
        case .preparingModel: "モデルを取得中（初回は数十秒かかります）"
        case .ready: "待機中（⌃⌥Space で録音）"
        case let .retrying(reason): "再起動中: \(reason)"
        case let .unavailable(reason): reason
        }
    }
}

/// `init` の中で self を @Sendable クロージャへ渡さないための入れ物。
@MainActor
private final class StatusBox {
    weak var coordinator: RecordingCoordinator?
}
