import AppKit
import Foundation

/// 1回の録音のあいだ、ここまでの音声を別 id で再認識し、安定した先頭部分だけを
/// 浮動ウィンドウへ出す（設計書 4、5、6）。
///
/// 入力欄へは一文字も書かない。書けば取り消しの責任が生まれ、段階1の貼り付け先
/// チェックとクリップボード復元の保証が崩れる（設計書 1）。プレビューは見るだけの
/// ものである。
///
/// プレビューが失敗しても最終の文字起こしは何も変えずに進む。worker を作り直す
/// 経路は通らない（設計書 8.2）。
@MainActor
final class LivePreviewSession {
    private let worker: SpeechWorkerClient
    private let capture: AudioCapture
    private let panel: PreviewPanel
    private let locator: CaretLocator
    private let target: PasteTarget?
    private let isRecording: @MainActor () -> Bool

    private var schedule = PreviewSchedule()
    private var text = PreviewText()
    private var window = PreviewWindowState()
    private var loop: Task<Void, Never>?
    private var checkedTargetStability = false

    /// 走っているプレビューの id。Enter と Esc はこれを `cancel` する（設計書 5.3）。
    private(set) var requestID: String?

    init(
        worker: SpeechWorkerClient,
        capture: AudioCapture,
        panel: PreviewPanel,
        target: PasteTarget?,
        menuBarFrame: @escaping () -> CGRect?,
        isRecording: @escaping @MainActor () -> Bool
    ) {
        self.worker = worker
        self.capture = capture
        self.panel = panel
        self.target = target
        self.isRecording = isRecording
        locator = CaretLocator(target: target, menuBarFrame: menuBarFrame)
    }

    /// ラウンドの予約を始める。
    func start() {
        window.reset()
        loop = Task { [weak self] in await self?.runRounds() }
    }

    /// 以降は新しいラウンドを作らない。`await` を1つも含まないので、呼び出し元へ
    /// 戻った時点でラウンドは増えない（設計書 5.3）。
    func stopScheduling() {
        schedule.stop()
        loop?.cancel()
        loop = nil
    }

    /// ウィンドウを隠す。`await` を1つも含まない。貼り付け先の問い合わせより前に
    /// 画面から消すことで、`PasteTarget.current()` が見る状態を段階1と同じに保つ
    /// （設計書 5.3、6.4）。
    func hide() {
        if window.hide() { panel.hide() }
    }

    /// 録音ごとに1回（設計書 8.1）。
    ///
    /// `cancelWriteMilliseconds` は、走っているプレビューへ `cancel` の行を
    /// 書き終えるまでの時間である。エンコーダの停止待ちや最終の文字起こしへの
    /// 上乗せは含まない。上乗せは同じ音声でプレビューの有無を比べて測る
    /// （レビュー SHOULD 5）。
    func logSummary(cancelWriteMilliseconds: Int) {
        guard schedule.roundCount > 0 || schedule.failureCount > 0 else { return }
        Log.state.notice("""
        preview rounds=\(self.schedule.roundCount, privacy: .public), \
        interval=\(self.schedule.minimumInterval ?? 0, privacy: .public)-\
        \(self.schedule.maximumInterval ?? 0, privacy: .public) s, \
        cancel_write_ms=\(cancelWriteMilliseconds, privacy: .public), \
        failures=\(self.schedule.failureCount, privacy: .public)
        """)
    }

    /// 最終結果との関係を数値で残す。本文は出さない（設計書 8.1）。
    /// 実音声での被覆率は実機のログで測り直す（設計書 10.4 の 3）。
    func noteFinal(_ finalText: String) {
        let shown = text.displayed
        guard !shown.isEmpty else { return }
        let update = text.replace(final: finalText)
        Log.worker.notice("""
        preview coverage shown=\(shown.count, privacy: .public), \
        final=\(update.resultCount, privacy: .public), \
        prefix=\(finalText.hasPrefix(shown), privacy: .public)
        """)
    }

    // MARK: ラウンド

    private func runRounds() async {
        while !Task.isCancelled {
            let accumulated = capture.recordedSeconds
            let interval = PreviewSchedule.interval(accumulatedSeconds: accumulated)
            schedule.noteInterval(interval)
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            guard schedule.beginRound(isRecording: isRecording()) else { return }
            await runRound()
            guard !schedule.isStopped else {
                // 3 回連続で失敗した。このセッションのプレビューは止め、
                // ウィンドウを隠す。最終は何も変えずに進む（設計書 8.2）。
                Log.worker.notice("""
                preview stopped after \(self.schedule.consecutiveFailures, privacy: .public) failures
                """)
                hide()
                return
            }
        }
    }

    private func runRound() async {
        let pcm = capture.snapshot()
        let seconds = Double(pcm.count) / 2 / AppConfiguration.workerSampleRate
        guard seconds >= AppConfiguration.previewMinimumSeconds else {
            // まだ短すぎる。失敗ではないので連続失敗を増やさない。
            schedule.finishRound(success: true)
            return
        }

        let id = await worker.newPreviewRequest()
        guard !Task.isCancelled, isRecording() else {
            await worker.cancel(id: id)
            schedule.finishRound(success: true)
            return
        }
        requestID = id

        let started = Date()
        do {
            let result = try await worker.preview(id: id, pcm: pcm)
            requestID = nil
            let elapsed = Date().timeIntervalSince(started)
            guard !Task.isCancelled else { return }
            schedule.finishRound(success: true)
            let update = text.accept(preview: result)
            present(update.displayed)
            Log.worker.debug("""
            preview \(seconds, privacy: .public) s, \
            \(Int(elapsed * 1000), privacy: .public) ms, \
            result=\(update.resultCount, privacy: .public), \
            stable=\(update.commonPrefixCount, privacy: .public), \
            shown=\(update.displayed.count, privacy: .public), \
            failures=\(self.schedule.consecutiveFailures, privacy: .public)
            """)
        } catch {
            requestID = nil
            guard !Task.isCancelled else { return }
            schedule.finishRound(success: false)
            // ウィンドウは直前の内容のまま残す。毎秒の失敗を通知欄に出すと
            // 邪魔になるので、通知は出さない（設計書 8.2）。
            Log.worker.debug("""
            preview failed: \(SpeechWorkerClient.code(of: error), privacy: .public), \
            failures=\(self.schedule.consecutiveFailures, privacy: .public)
            """)
        }
    }

    // MARK: 表示

    private func present(_ full: String) {
        guard !full.isEmpty else { return }
        let shown = PreviewText.clamped(full, limit: AppConfiguration.previewCharacterLimit)
        guard window.show(shown, isRecording: isRecording()) else { return }
        panel.show(text: shown, anchor: locator.locate())
        noteTargetStability()
    }

    /// 最初の表示の直後に1回だけ、貼り付け先が動いていないかを記録する。
    /// 実機確認の材料であり、常時の照合ではない（設計書 6.4）。
    private func noteTargetStability() {
        guard !checkedTargetStability, let target else { return }
        checkedTargetStability = true
        let stable = PasteTarget.current().map { target.matches($0) } ?? false
        Log.paste.notice("target_stable=\(stable, privacy: .public)")
    }
}
