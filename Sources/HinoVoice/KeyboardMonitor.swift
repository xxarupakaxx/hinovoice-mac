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
    /// keyDown を飲み込んだキー。対応する keyUp も飲み込んで、アプリに片側だけ
    /// 届かないようにする（OpenHinoVoice src/hook.rs:31-57 と同じ役割）。
    var captured: CapturedKeys = []
}

struct CapturedKeys: OptionSet, Sendable {
    let rawValue: UInt8
    static let start = CapturedKeys(rawValue: 1 << 0)
    static let confirm = CapturedKeys(rawValue: 1 << 1)
    static let cancel = CapturedKeys(rawValue: 1 << 2)
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
        let key: CapturedKeys
        let active: Bool
        let event: HotkeyEvent
        switch role(of: input) {
        case .start:
            key = .start
            active = state.acceptsStartKey
            event = .start
        case .confirm:
            key = .confirm
            active = state.swallowsConfirmKeys
            event = .confirm
        case .cancel:
            key = .cancel
            active = state.swallowsConfirmKeys
            event = .cancel
        case .other:
            return KeyDecision(swallow: false, event: nil)
        }

        guard input.isKeyDown else {
            // 押下を飲み込んだキーは、離したときも飲み込む。
            let swallow = state.captured.contains(key)
            state.captured.remove(key)
            return KeyDecision(swallow: swallow, event: nil)
        }

        if input.isRepeat || state.captured.contains(key) {
            // 押しっぱなしの繰り返しで二度目の遷移を起こさない
            // （OpenHinoVoice src/hook.rs:33-36）。
            return KeyDecision(swallow: state.captured.contains(key), event: nil)
        }

        guard active else {
            return KeyDecision(swallow: false, event: nil)
        }
        state.captured.insert(key)
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
