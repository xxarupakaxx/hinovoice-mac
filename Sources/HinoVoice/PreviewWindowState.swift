import Foundation

/// プレビューウィンドウを出しているかどうか（設計書 6.4、9.2）。
///
/// 一度隠したら、そのセッションでは開き直さない。Enter と Esc は最初の `await`
/// より前に隠すので（設計書 5.3）、そのあとに遅れて届いたプレビュー結果で
/// 開き直すと、貼り付け先の照合が走る時点でパネルが画面に戻ってしまう。
/// `--selftest-preview-window` で検証する。
struct PreviewWindowState: Equatable {
    private(set) var isVisible = false
    /// 隠したあとの印。`reset()` だけが戻す。
    private(set) var isSealed = false
    private(set) var text = ""

    /// 表示を求める。パネルへ渡すべきなら true。
    ///
    /// 録音中以外では出さない。空文字列でも出さない。方式Aでは連続2回で一致した
    /// 先頭部分だけを出すので、最初のラウンドの結果は空である（設計書 3.1）。
    mutating func show(_ next: String, isRecording: Bool) -> Bool {
        guard !isSealed, isRecording, !next.isEmpty else { return false }
        isVisible = true
        text = next
        return true
    }

    /// Enter / Esc / `.retrying` / `unavailable` / 終了で呼ぶ。画面から消すべきなら true。
    mutating func hide() -> Bool {
        isSealed = true
        guard isVisible else { return false }
        isVisible = false
        return true
    }

    /// 新しい録音。
    mutating func reset() {
        isVisible = false
        isSealed = false
        text = ""
    }
}
