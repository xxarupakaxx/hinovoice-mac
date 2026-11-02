import CoreGraphics
import Foundation
import os

/// 状態機械へ伝えるキーのイベント。
enum HotkeyEvent: Sendable, Equatable {
    case start
    case confirm
    case cancel
}

/// コールバックが同期的に読む分だけを持つ値（設計書 10.2）。
struct TapState: Sendable, Equatable {
    /// 録音中・文字起こし中・貼り付け中は Enter と Esc を飲み込む（設計書 9）。
    var swallowsConfirmKeys = false
    /// 待機中と停止中だけ開始キーを受ける。
    var acceptsStartKey = true
    /// keyDown を飲み込んだ物理キーのキーコード。対応する keyUp も飲み込んで、
    /// アプリに片側だけ届かないようにする（OpenHinoVoice src/hook.rs:31-57 と
    /// 同じ役割）。役割ではなくキーコードで持つので、⌃⌥Space のあと Control を
    /// 先に離して Space の役割が変わっても keyUp を取りこぼさず、Return と
    /// テンキーの Enter も互いに干渉しない。
    var capturedKeyCodes: Set<Int64> = []
}

/// コールバックが見るキー入力。CGEvent から取り出した値だけにして、
/// 判定を純粋関数に保つ（`--selftest-keys` で検証する）。
struct KeyInput: Sendable, Equatable {
    var keyCode: Int64
    var flags: CGEventFlags
    var isKeyDown: Bool
    var isRepeat: Bool
}

struct KeyDecision: Sendable, Equatable {
    var swallow: Bool
    var event: HotkeyEvent?
}

enum KeyPolicy {
    enum Role: Equatable {
        case start
        case confirm
        case cancel
        case other
    }

    static func role(of input: KeyInput) -> Role {
        if input.keyCode == AppConfiguration.startKeyCode,
           input.flags.intersection(AppConfiguration.modifierMask) == AppConfiguration.startKeyModifiers {
            return .start
        }
        if AppConfiguration.confirmKeyCodes.contains(input.keyCode) { return .confirm }
        if input.keyCode == AppConfiguration.cancelKeyCode { return .cancel }
        return .other
    }

    /// 飲み込むかどうかと、状態機械へ送るイベントを決める。副作用はない。
    static func decide(_ input: KeyInput, state: inout TapState) -> KeyDecision {
        // keyUp は現在の修飾キーの状態ではなく、押下を飲み込んだキーコードで
        // 照合する。役割で照合すると、⌃⌥Space のあと Control や Option を先に
        // 離した Space が `.other` になり、keyUp だけがアプリへ漏れる。
        guard input.isKeyDown else {
            let swallow = state.capturedKeyCodes.contains(input.keyCode)
            state.capturedKeyCodes.remove(input.keyCode)
            return KeyDecision(swallow: swallow, event: nil)
        }

        if state.capturedKeyCodes.contains(input.keyCode) {
            // 押しっぱなしの繰り返しで二度目の遷移を起こさない
            // （OpenHinoVoice src/hook.rs:33-36）。
            return KeyDecision(swallow: true, event: nil)
        }

        let active: Bool
        let event: HotkeyEvent
        switch role(of: input) {
        case .start:
            active = state.acceptsStartKey
            event = .start
        case .confirm:
            active = state.swallowsConfirmKeys
            event = .confirm
        case .cancel:
            active = state.swallowsConfirmKeys
            event = .cancel
        case .other:
            return KeyDecision(swallow: false, event: nil)
        }

        guard active, !input.isRepeat else {
            return KeyDecision(swallow: false, event: nil)
        }
        state.capturedKeyCodes.insert(input.keyCode)
        return KeyDecision(swallow: true, event: event)
    }
}

/// CGEventTap 一本で、開始キーの検出と Enter / Esc の横取りの両方を行う（設計書 10.1）。
final class KeyboardMonitor: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: TapState())
    private let onEvent: @Sendable (HotkeyEvent) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(onEvent: @escaping @Sendable (HotkeyEvent) -> Void) {
        self.onEvent = onEvent
    }

    /// タップの作成に失敗したら、アクセシビリティと入力監視の両方を案内する（設計書 7.1）。
    func install() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // 破棄できるアクティブなタップ
            eventsOfInterest: mask,
            callback: keyboardTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.hotkey.error("tapCreate returned nil")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        Log.hotkey.notice("event tap installed")
        return true
    }

    func update(swallowsConfirmKeys: Bool, acceptsStartKey: Bool) {
        state.withLock { current in
            current.swallowsConfirmKeys = swallowsConfirmKeys
            current.acceptsStartKey = acceptsStartKey
        }
    }

    /// コールバックからのみ呼ぶ。重い処理は入れない（設計書 10.2）。
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 無効化されたままだと Enter が漏れ始める。必ず戻す（設計書 10.2）。
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Log.hotkey.error("event tap re-enabled after disable")
            }
            return nil
        case .keyDown, .keyUp:
            break
        default:
            return Unmanaged.passUnretained(event)
        }

        // 自分が送った Cmd+V は素通しする（設計書 10.3）。
        if event.getIntegerValueField(.eventSourceUserData) == AppConfiguration.eventMagic {
            return Unmanaged.passUnretained(event)
        }

        let input = KeyInput(
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags,
            isKeyDown: type == .keyDown,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
        let decision = state.withLock { current in
            KeyPolicy.decide(input, state: &current)
        }
        if let event = decision.event {
            onEvent(event)
        }
        return decision.swallow ? nil : Unmanaged.passUnretained(event)
    }
}

private func keyboardTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
