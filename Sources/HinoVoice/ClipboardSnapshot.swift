import AppKit

/// クリップボードの内容をデータとして複製して持つ。元のクリップボードが
/// 書き換わると `NSPasteboardItem` は無効になるので、参照ではなく複製を持つ（設計書 13.1）。
struct ClipboardSnapshot {
    private let items: [NSPasteboardItem]
    /// 保存した時点の changeCount。
    let changeCount: Int
    let savedTypeCount: Int
    /// 複製できなかった type の数。内容は残さない（設計書 13.3）。
    let unreadableTypeCount: Int

    static func capture(from pasteboard: NSPasteboard = .general) -> ClipboardSnapshot {
        let changeCount = pasteboard.changeCount
        var copies: [NSPasteboardItem] = []
        var saved = 0
        var unreadable = 0
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            var copiedAny = false
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                    saved += 1
                    copiedAny = true
                } else {
                    // ファイルプロミスのように「あとで要求されたら渡す」内容は複製できない。
                    unreadable += 1
                }
            }
            if copiedAny { copies.append(copy) }
        }
        return ClipboardSnapshot(
            items: copies,
            changeCount: changeCount,
            savedTypeCount: saved,
            unreadableTypeCount: unreadable
        )
    }

    /// 保存した時点から誰も書き換えていないか。複数の type を読む間に外部の
    /// コピーが入ることがあるので、消去の直前にこれを見る（設計書 13.1）。
    func isCurrent(on pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.changeCount == changeCount
    }

    /// 自分が書いた値から変わっていなければ復元する。変わっていれば、ユーザーが
    /// 意図してコピーした新しい内容を消さないために復元しない（設計書 13.1）。
    @discardableResult
    func restore(to pasteboard: NSPasteboard = .general, ifChangeCountIs expected: Int) -> Bool {
        guard pasteboard.changeCount == expected else { return false }
        pasteboard.clearContents()
        guard !items.isEmpty else { return true }
        return pasteboard.writeObjects(items)
    }
}
