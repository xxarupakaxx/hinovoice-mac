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

    /// フォーカス要素の問い合わせに使う属性名。`kAXFocusedUIElementAttribute` は
    /// 可変のグローバルとして import されるため Swift 6 では参照できない。
    static let axFocusedUIElementAttribute = "AXFocusedUIElement"

    /// アクセシビリティの問い合わせの待ち時間。応答しないアプリで貼り付けが
    /// 固まらないようにする。
    static let axMessagingTimeoutSeconds = 0.2
}
