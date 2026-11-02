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
        limitTask?.cancel()
        _ = capture?.stop()
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
                Task { await cancelSession() }
            }
        }
    }

    // MARK: 遷移

    private func beginRecording() async {
        guard state.acceptsStartKey else { return }
        if case let .unavailable(reason) = state {
            show(notice: reason)
            return
        }
        guard workerStatus == .ready else {
            show(notice: statusText(for: workerStatus))
            return
        }
        guard await Permissions.requestMicrophone() else {
            show(notice: "マイクの許可がありません")
            return
        }
        guard Permissions.isAccessibilityTrusted else {
            show(notice: "アクセシビリティの許可がありません")
            Permissions.promptAccessibility()
            return
        }

        target = PasteTarget.current()
        let id = await worker.newRequest()
        requestID = id
        let sender = ChunkSender(worker: worker, requestID: id)
        self.sender = sender
        let capture = AudioCapture { chunk in
            sender.send(chunk)
        }
        do {
            try capture.start()
        } catch {
            await worker.cancel(id: id)
            requestID = nil
            self.sender = nil
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
            let transcript = try await worker.transcribe(id: id)
            let elapsed = Date().timeIntervalSince(started)
            Log.worker.notice("""
            end received in \(elapsed, privacy: .public) s, \
            stop=\(transcript.stop, privacy: .public), \
            \(transcript.text.count, privacy: .public) characters
            """)
            requestID = nil
            sender = nil
            // 段階2の AI 整形はこの1行の前に入る（設計書 15）。
            await paste(transcript.text)
        } catch {
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

    private func paste(_ text: String) async {
        transition(to: .pasting)
        let outcome = await TextInserter.insert(text, into: target)
        target = nil
        if let message = outcome.userMessage {
            show(notice: message)
        }
        transition(to: .idle)
    }

    private func cancelSession() async {
        limitTask?.cancel()
        limitTask = nil
        _ = capture?.stop()
        capture = nil
        if let id = requestID {
            await worker.cancel(id: id)
        }
        requestID = nil
        sender = nil
        target = nil
        transition(to: .idle)
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
                Task { await cancelSession() }
            }
        case .starting, .preparingModel:
            break
        }
        publish()
    }

    /// コールバックが同期的に読む値を更新する（設計書 10.2）。
    private func syncTap() {
        monitor?.update(
            swallowsConfirmKeys: state.swallowsConfirmKeys,
            acceptsStartKey: state.acceptsStartKey
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
