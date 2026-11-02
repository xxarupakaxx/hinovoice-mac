import Foundation

/// 再認識ラウンドの間隔、バックプレッシャー、連続失敗の打ち切り（設計書 4.1、8.2）。
///
/// 1 ラウンドの費用は蓄積長に比例し、ラウンド数は録音長に比例するので、総費用は
/// 録音長の2乗で伸びる。間隔を蓄積長で伸ばすのはこの伸びを折るためである
/// （設計書 7）。`--selftest-preview-schedule` で検証する。
struct PreviewSchedule: Equatable {
    /// 直近で連続している失敗の数。成功で 0 へ戻る。
    private(set) var consecutiveFailures = 0
    /// この録音で失敗した回数の合計。ログ用（設計書 8.1）。
    private(set) var failureCount = 0
    /// この録音で始めたラウンドの数。
    private(set) var roundCount = 0
    /// 連続失敗、または Enter / Esc で止めた。
    private(set) var isStopped = false
    /// 終端を待っているラウンドがある。
    private(set) var isRunning = false
    private(set) var minimumInterval: Double?
    private(set) var maximumInterval: Double?

    /// 蓄積秒数に応じた間隔。前回のラウンドが終わってから数える（設計書 4.1）。
    static func interval(accumulatedSeconds: Double) -> Double {
        let raw = accumulatedSeconds / AppConfiguration.previewIntervalDivisor
        return min(
            max(raw, AppConfiguration.previewMinIntervalSeconds),
            AppConfiguration.previewMaxIntervalSeconds
        )
    }

    /// 待つことにした間隔を覚える。録音ごとのログに最小と最大を出す（設計書 8.1）。
    mutating func noteInterval(_ seconds: Double) {
        minimumInterval = min(minimumInterval ?? seconds, seconds)
        maximumInterval = max(maximumInterval ?? seconds, seconds)
    }

    /// ラウンドを始めてよいか。
    ///
    /// 走っているラウンドがある間は始めない。間隔だけで制御すると、蓄積 60 秒で
    /// 往復が 1 秒を超えたときに要求が積み上がり、worker の直列キューの後ろで
    /// 最終の `transcribe` が待つ（設計書 4.1）。録音中以外では作らない。
    mutating func beginRound(isRecording: Bool) -> Bool {
        guard !isStopped, !isRunning, isRecording else { return false }
        isRunning = true
        roundCount += 1
        return true
    }

    /// ラウンドの終わり。3 回連続で失敗したらこの録音のプレビューを止める（設計書 8.2）。
    mutating func finishRound(success: Bool) {
        isRunning = false
        guard !success else {
            consecutiveFailures = 0
            return
        }
        consecutiveFailures += 1
        failureCount += 1
        if consecutiveFailures >= AppConfiguration.maxConsecutivePreviewFailures {
            isStopped = true
        }
    }

    /// Enter と Esc から呼ぶ。以降は新しいラウンドを作らない。
    mutating func stop() {
        isStopped = true
    }
}
