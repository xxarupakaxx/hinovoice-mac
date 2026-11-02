import AppKit
import ApplicationServices
import CoreGraphics

/// 録音開始時の貼り付け先。録音中にフォーカスが別のアプリへ移ったら貼らない
/// （OpenHinoVoice src/paste.rs:156-173、src/main.rs:221-230 と同じ考え方）。
/// プロセスだけでは同じアプリの別ウィンドウ・別入力欄を区別できないので、
/// アクセシビリティから取れる場合はフォーカス要素も覚える。
struct PasteTarget {
    let processIdentifier: pid_t
    /// 開始時にフォーカスのあった要素。取れない環境では nil になり、判定は
    /// アプリ単位へ落ちる。
    let focusedElement: AXUIElement?

    static func current() -> PasteTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return PasteTarget(
            processIdentifier: app.processIdentifier,
            focusedElement: focusedElement()
        )
    }

    /// システム全体のフォーカス要素を取る。問い合わせは相手のアプリへの同期
    /// 通信なので、応答しないアプリで固まらないよう待ち時間を短く設定する。
    private static func focusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, Float(AppConfiguration.axMessagingTimeoutSeconds))
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            system,
            AppConfiguration.axFocusedUIElementAttribute as CFString,
            &value
        )
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // 直前に型を確認している。
        return (value as! AXUIElement)
    }

    /// 同じ貼り付け先かどうか。AXUIElement は同じ対象を指していれば CFEqual で
    /// 等しくなる。どちらかが取れていない場合はアプリの一致だけで判定する。
    func matches(_ other: PasteTarget) -> Bool {
        guard processIdentifier == other.processIdentifier else { return false }
        guard let mine = focusedElement, let theirs = other.focusedElement else { return true }
        return CFEqual(mine, theirs)
    }
}

@MainActor
enum TextInserter {
    enum Outcome {
        case inserted(savedTypes: Int, restored: Bool, unreadableTypes: Int)
        case emptyText
        case targetChanged
        case clipboardChanged
        case noTarget

        var userMessage: String? {
            switch self {
            case .inserted: return nil
            case .emptyText: return "聞き取れませんでした"
            case .targetChanged: return "入力先が変わったので貼り付けを中止しました"
            case .clipboardChanged: return "クリップボードが変わったので貼り付けを中止しました"
            case .noTarget: return "入力先のアプリを特定できません"
            }
        }
    }

    /// 保存 → 置く → Cmd+V → 待つ → 復元（設計書 13.1）。
    static func insert(_ text: String, into target: PasteTarget?) async -> Outcome {
        guard !text.isEmpty else { return .emptyText }
        guard let target else { return .noTarget }
        guard let atEntry = PasteTarget.current() else { return .noTarget }
        guard target.matches(atEntry) else { return .targetChanged }

        await waitForModifierRelease()

        // 修飾キーを待つ間に ⌘Tab やクリックで入力先が変わりうる。待ったあとに
        // 必ず見直す。ここで止めればクリップボードには触れていない。
        guard let afterWait = PasteTarget.current() else { return .noTarget }
        guard target.matches(afterWait) else { return .targetChanged }

        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSnapshot.capture(from: pasteboard)
        // 複数の type を読む間に外部のコピーが入っていたら、消さずに中止する。
        // 消してしまうと、ユーザーが意図してコピーした内容を失う。
        guard snapshot.isCurrent(on: pasteboard) else {
            Log.paste.notice("clipboard changed while saving, paste aborted")
            return .clipboardChanged
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        // 送出の直前にもう一度見る。ここで止めるときはクリップボードを戻す。
        guard let beforePost = PasteTarget.current(), target.matches(beforePost) else {
            snapshot.restore(to: pasteboard, ifChangeCountIs: ourChangeCount)
            return .targetChanged
        }

        postPasteShortcut()

        // 貼り付け先は非同期にクリップボードを読む。読んだかどうかを知る手段が
        // ないので固定の待ち時間を置く（設計書 13.2）。
        try? await Task.sleep(for: .seconds(AppConfiguration.clipboardRestoreDelaySeconds))

        let restored = snapshot.restore(to: pasteboard, ifChangeCountIs: ourChangeCount)
        Log.paste.notice("""
        clipboard saved \(snapshot.savedTypeCount, privacy: .public) types, \
        unreadable \(snapshot.unreadableTypeCount, privacy: .public), \
        pasted \(text.count, privacy: .public) characters, \
        restored=\(restored, privacy: .public)
        """)
        return .inserted(
            savedTypes: snapshot.savedTypeCount,
            restored: restored,
            unreadableTypes: snapshot.unreadableTypeCount
        )
    }

    /// 修飾キーが押されたままだと Cmd+V が別のショートカットになる
    /// （OpenHinoVoice src/paste.rs:175-181）。上限まで待って、それでも
    /// 押されていれば送る。貼らないよりは送るほうが役に立つ。
    private static func waitForModifierRelease() async {
        let deadline = Date().addingTimeInterval(AppConfiguration.modifierReleaseWaitSeconds)
        while Date() < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(AppConfiguration.modifierMask).isEmpty { return }
            try? await Task.sleep(for: .seconds(AppConfiguration.modifierPollSeconds))
        }
        Log.paste.notice("modifiers still held when pasting")
    }

    /// 物理キーの押下状態から切り離したイベントソースで Cmd+V を送る（設計書 10.4）。
    private static func postPasteShortcut() {
        guard let source = CGEventSource(stateID: .privateState) else {
            Log.paste.error("cannot create private event source")
            return
        }
        for isDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: AppConfiguration.pasteVirtualKey,
                keyDown: isDown
            ) else { continue }
            event.flags = .maskCommand
            // 自分が送ったものだと分かる印を付ける（設計書 10.3）。
            event.setIntegerValueField(.eventSourceUserData, value: AppConfiguration.eventMagic)
            event.post(tap: .cghidEventTap)
        }
    }
}
