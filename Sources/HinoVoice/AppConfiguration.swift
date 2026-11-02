import CoreGraphics
import Foundation

/// 変更しそうな値をここ1箇所に集める。段階2で設定画面を足すときは、この型を
/// 読み書きできる形へ変えて UserDefaults に載せる（設計書 15）。
enum AppConfiguration {
    static let bundleIdentifier = "com.xxarupakaxx.hinovoice-mac"

    // MARK: キー

    /// 録音開始キーは Control + Option + Space（設計書 4.3）。
    /// 別のキーにするときはこの2つだけを変える。
    static let startKeyCode: Int64 = 49 // Space
    static let startKeyModifiers: CGEventFlags = [.maskControl, .maskAlternate]

    /// Return とテンキーの Enter の両方を停止キーとして受ける（設計書 4.4）。
    static let confirmKeyCodes: Set<Int64> = [36, 76]
    static let cancelKeyCode: Int64 = 53 // Esc
    static let pasteVirtualKey: CGKeyCode = 9 // V

    /// 修飾キーの比較で見る範囲。CapsLock や fn は無視する。
    static let modifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    /// 自分が送ったイベントに付ける印（設計書 10.3）。
    static let eventMagic: Int64 = 0x4849_4E4F_5649_4345

    // MARK: worker

    static let model = "haas-ja-v1.0"
    static let workerProtocolVersion = 4
    static let workerSampleRate = 16000.0
    static let language = "ja"

    static let speechSearchPaths = [
        "\(NSHomeDirectory())/.local/bin/speech",
        "/opt/homebrew/bin/speech",
        "/usr/local/bin/speech",
    ]

    // MARK: 時間

    static let chunkSeconds = 0.25
    static let maxRecordingSeconds = 60.0

    /// ready は固定時間ではなく「活動が止まってから」で判定する（設計書 12.2）。
    static let readyIdleTimeoutSeconds = 60.0
    static let transcribeIdleTimeoutSeconds = 20.0
    static let writeTimeoutSeconds = 5.0
    /// 書き込みが詰まったときに `poll` を区切る長さ。終了処理と期限へ素早く
    /// 反応するために短くする（設計書 12.6）。
    static let writePollSliceSeconds = 0.1
    static let shutdownGraceSeconds = 3.0

    static let restartBackoffSeconds: [Double] = [1, 2, 4, 8, 16]
    static let restartBackoffCapSeconds = 30.0
    static let maxConsecutiveWorkerFailures = 5

    // MARK: 貼り付け

    /// 貼り付け先がクリップボードを読む時間を待つ（設計書 13.2）。実機で調整する値。
    static let clipboardRestoreDelaySeconds = 0.4

    /// 修飾キーが離されるのを待つ上限。押されたまま Cmd+V を送ると別の
    /// ショートカットになる（OpenHinoVoice src/paste.rs:175-181 と同じ理由）。
    static let modifierReleaseWaitSeconds = 0.5
    static let modifierPollSeconds = 0.02

    /// フォーカスの問い合わせに使う属性名。`kAXFocusedUIElementAttribute` などは
    /// 可変のグローバルとして import されるため Swift 6 では参照できない。
    static let axFocusedUIElementAttribute = "AXFocusedUIElement"
    /// フォーカス要素を読めないアプリで代わりに見るウィンドウ（レビュー MUST 5）。
    static let axFocusedWindowAttribute = "AXFocusedWindow"

    /// アクセシビリティの問い合わせの待ち時間。応答しないアプリで貼り付けが
    /// 固まらないようにする。
    static let axMessagingTimeoutSeconds = 0.2

    // MARK: 録音中のライブプレビュー

    /// 間隔は `clamp(蓄積秒数 / 20, 1, 3)`（設計書 4.1）。20 秒までは毎秒、
    /// 40 秒で 2 秒、60 秒で 3 秒になる。実機で遅れが気になればこの分母を
    /// 大きくし、1 Hz 固定へ寄せる。
    static let previewIntervalDivisor = 20.0
    static let previewMinIntervalSeconds = 1.0
    static let previewMaxIntervalSeconds = 3.0

    /// プレビューが沈黙したと見なす長さ。観測した最悪の往復 1.15 秒の約3倍
    /// （設計書 8.2）。最終の 20 秒とは別の値にする。
    static let previewIdleTimeoutSeconds = 3.0
    /// これだけ連続で失敗したら、その録音のプレビューを止める（設計書 8.2）。
    static let maxConsecutivePreviewFailures = 3
    /// プレビューの送信が書き始めるまでの上限。これを過ぎた分は1バイトも書かずに
    /// 捨てる。最大 2.56MB の送信を `writeTimeoutSeconds` まで待って worker を
    /// 止める経路へ流さないための値である（レビュー MUST 2）。間隔の下限と同じ
    /// 1 秒にして、次のラウンドまでに必ず片付く形にする。
    static let previewSendBudgetSeconds = 1.0
    /// これより短い蓄積ではラウンドを作らない。
    static let previewMinimumSeconds = 0.5

    /// 表示の上限（設計書 3.3）。超えた分は先頭を落とす。
    static let previewCharacterLimit = 120
    static let previewMaxLines = 2
    static let previewMaxWidth = 420.0
    /// 画面の見える範囲から残す余白。幅は `min(420, visibleFrame.width - 32)`。
    static let previewScreenInset = 32.0
    /// 基準の矩形からの距離。
    static let previewGap = 6.0
    static let previewHorizontalPadding = 10.0
    static let previewVerticalPadding = 7.0
    static let previewCornerRadius = 8.0
    static let previewBorderWidth = 0.5
    static let previewFontSize = 13.0
    /// フォーカスウィンドウの左下の内側に置くときの差し込み（設計書 6.2 の2段目）。
    static let previewWindowInset = 12.0

    /// キャレットの矩形を取るための属性名。SDK の定数文字列は
    /// `AXAttributeConstants.h` で実値を確認している。`kAX...` のグローバルは
    /// Swift 6 から参照できないので、既存の同 70-72 と同じく文字列で置く。
    static let axSelectedTextRangeAttribute = "AXSelectedTextRange"
    static let axBoundsForRangeAttribute = "AXBoundsForRange"
    static let axPositionAttribute = "AXPosition"
    static let axSizeAttribute = "AXSize"

    /// プレビュー専用の問い合わせの待ち時間。貼り付け判定の 0.2 秒を流用すると、
    /// 応答しないアプリで毎秒 0.4 秒メインスレッドを止める。プレビューは
    /// 見栄えの話なので短く切る（設計書 6.2）。
    static let previewAXMessagingTimeoutSeconds = 0.05
    /// これだけ連続でキャレットもウィンドウも取れなければ、そのセッションは
    /// メニューバーの段に固定する（設計書 6.2）。
    static let maxConsecutiveCaretFailures = 3
}
