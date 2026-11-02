import Foundation

/// 録音中のプレビューに出す文字列を決める（設計書 3）。
///
/// 1秒ごとの再認識の結果は単調に伸びない。文の切れ目で語が入れ替わるので、
/// 共通接頭辞は何度も短くなる。すでに見せた文字が入れ替わると読み手は読み直す
/// ことになるので、前回に届かない回は据え置き、伸びた回だけ作り直す（設計書 3.2 の A'）。
///
/// 比較は `Character`（書記素クラスタ）単位で行う。UTF-16 単位で切ると濁点や
/// 絵文字の途中で切れる。`--selftest-prefix` で検証する。
struct PreviewText: Equatable {
    /// いま見せている文字列。表示の上限（設計書 3.3）を適用する前の全体である。
    private(set) var displayed = ""
    /// 前回のプレビュー結果。共通接頭辞の相手。
    private(set) var previous: String?

    struct Update: Equatable {
        /// 適用後に見せる文字列。
        var displayed: String
        /// 今回の結果の文字数。ログ用（設計書 8.1）。
        var resultCount: Int
        /// 前回との共通接頭辞の文字数。ログ用。
        var commonPrefixCount: Int
        /// 見せる文字列が変わったか。
        var changed: Bool
    }

    /// プレビューの結果を1つ受ける。
    ///
    /// 共通接頭辞が表示済みの長さに届かない回は、文字列も長さも変えない。
    /// 届いた回は今回の結果から作り直す。こうすると長さは後退せず、すでに
    /// 出した文字の入れ替わりも 60 回の実測で 4 回に収まる（設計書 3.2）。
    mutating func accept(preview result: String) -> Update {
        let stable = previous.map { Self.commonPrefixCount($0, result) } ?? 0
        previous = result
        let before = displayed
        if stable >= displayed.count {
            displayed = String(result.prefix(stable))
        }
        return Update(
            displayed: displayed,
            resultCount: result.count,
            commonPrefixCount: stable,
            changed: displayed != before
        )
    }

    /// 最終結果が来たら、プレビューの文字列を捨てて最終結果で置き換える（設計書 3.1）。
    ///
    /// ウィンドウは Enter の時点ですでに隠している（設計書 5.3）ので、これは
    /// 画面には出ない。プレビューが最終結果の接頭辞になっていたかを数値で
    /// 記録するために使う（設計書 8.1）。
    mutating func replace(final text: String) -> Update {
        let before = displayed
        displayed = text
        previous = text
        return Update(
            displayed: displayed,
            resultCount: text.count,
            commonPrefixCount: text.count,
            changed: displayed != before
        )
    }

    mutating func reset() {
        displayed = ""
        previous = nil
    }

    /// 共通接頭辞の文字数。`Character` 単位で数える。
    static func commonPrefixCount(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        var left = lhs.startIndex
        var right = rhs.startIndex
        while left < lhs.endIndex, right < rhs.endIndex, lhs[left] == rhs[right] {
            count += 1
            left = lhs.index(after: left)
            right = rhs.index(after: right)
        }
        return count
    }

    /// 表示の上限（設計書 3.3）。超えた分は末尾を残して先頭を落とし、先頭に
    /// `…` を付ける。新しい語が見えることが目的なので、古い側を捨てる。
    static func clamped(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        return "…" + String(text.suffix(limit))
    }
}
