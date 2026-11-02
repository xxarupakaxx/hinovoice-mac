import AppKit
import CoreGraphics

/// 録音開始時の貼り付け先。録音中にフォーカスが別のアプリへ移ったら貼らない
/// （OpenHinoVoice src/paste.rs:156-173、src/main.rs:221-230 と同じ考え方）。
struct PasteTarget: Equatable, Sendable {
    let processIdentifier: pid_t

    static func current() -> PasteTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return PasteTarget(processIdentifier: app.processIdentifier)
    }
}

@MainActor
enum TextInserter {
    enum Outcome {
        case inserted(savedTypes: Int, restored: Bool, unreadableTypes: Int)
        case emptyText
        case targetChanged
        case noTarget

        var isSuccess: Bool {
            if case .inserted = self { return true }
            return false
        }

        var userMessage: String? {
            switch self {
            case .inserted: return nil
            case .emptyText: return "聞き取れませんでした"
            case .targetChanged: return "入力先が変わったので貼り付けを中止しました"
            case .noTarget: return "入力先のアプリを特定できません"
            }
        }
    }

    /// 保存 → 置く → Cmd+V → 待つ → 復元（設計書 13.1）。
    static func insert(_ text: String, into target: PasteTarget?) async -> Outcome {
        guard !text.isEmpty else { return .emptyText }
        guard let target else { return .noTarget }
        guard let now = PasteTarget.current() else { return .noTarget }
        guard now == target else { return .targetChanged }

        await waitForModifierRelease()

        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

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
