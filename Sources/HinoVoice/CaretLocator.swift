import AppKit
import ApplicationServices
import CoreGraphics

/// プレビューを出す位置を1ラウンドに1回だけ問い合わせる（設計書 6.2）。
///
/// 段は3つで、上から順に落ちる。キャレットの矩形 → フォーカス中のウィンドウ →
/// メニューバーの項目。失敗したら直前の位置を使い回し、3 回連続で失敗したら
/// そのセッションは3段目に固定する。
///
/// `PasteTarget` は貼り付け可否の根拠なので、表示のために挙動を変えない
/// （設計書 0 の 2）。ここは録音開始時に取れた要素を読むだけの別経路である。
@MainActor
final class CaretLocator {
    private let target: PasteTarget?
    private let menuBarFrame: () -> CGRect?

    private var consecutiveFailures = 0
    private var pinnedToMenuBar = false
    private var last: PreviewAnchor?

    init(target: PasteTarget?, menuBarFrame: @escaping () -> CGRect?) {
        self.target = target
        self.menuBarFrame = menuBarFrame
    }

    /// いまプレビューを置く基準。取れなければ nil（パネル側が画面の既定位置へ置く）。
    func locate() -> PreviewAnchor? {
        if pinnedToMenuBar { return menuBarAnchor() }

        guard let target, isFrontmost(target) else {
            // 前面アプリが録音開始時と違う。他人のアプリのキャレットは追いかけない。
            // `NSWorkspace` の1回の問い合わせで済む（設計書 6.2）。
            return menuBarAnchor()
        }

        let primary = NSScreen.screens.first?.frame ?? .zero
        if let rect = caretRect(of: target) {
            return succeed(PreviewAnchor(
                rect: PreviewPlacement.appKitRect(axRect: rect, primaryFrame: primary),
                tier: .caret,
                prefersBelow: true
            ))
        }
        if let rect = focusedWindowRect(of: target.processIdentifier) {
            let converted = PreviewPlacement.appKitRect(axRect: rect, primaryFrame: primary)
            // ウィンドウは左下の内側に置く（設計書 6.2 の2段目）。
            let inset = AppConfiguration.previewWindowInset
            return succeed(PreviewAnchor(
                rect: CGRect(x: converted.minX + inset, y: converted.minY + inset, width: 0, height: 0),
                tier: .window,
                prefersBelow: false
            ))
        }

        consecutiveFailures += 1
        if consecutiveFailures >= AppConfiguration.maxConsecutiveCaretFailures {
            pinnedToMenuBar = true
            Log.app.debug("placement pinned to menubar after repeated AX failures")
            return menuBarAnchor()
        }
        // 失敗した回は直前の位置を使い回す。
        if let last { return last }
        return menuBarAnchor()
    }

    private func succeed(_ anchor: PreviewAnchor) -> PreviewAnchor {
        consecutiveFailures = 0
        last = anchor
        Log.app.debug("placement=\(anchor.tier.rawValue, privacy: .public)")
        return anchor
    }

    private func menuBarAnchor() -> PreviewAnchor? {
        guard let frame = menuBarFrame() else { return nil }
        Log.app.debug("placement=\(PreviewAnchorTier.menubar.rawValue, privacy: .public)")
        // メニューバーの項目はすでに AppKit の座標である。変換しない。
        return PreviewAnchor(rect: frame, tier: .menubar, prefersBelow: true)
    }

    private func isFrontmost(_ target: PasteTarget) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    }

    // MARK: アクセシビリティ

    /// 選択範囲を問い、その範囲の矩形を取る。範囲が空でもキャレットの矩形は
    /// 幅 0 で高さを持つので使える（設計書 6.2）。
    private func caretRect(of target: PasteTarget) -> CGRect? {
        guard AXIsProcessTrusted(), let identity = target.focusedElement else { return nil }
        let element = identity.element
        Self.setTimeout(on: element)

        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            AppConfiguration.axSelectedTextRangeAttribute as CFString,
            &range
        ) == .success, let range, CFGetTypeID(range) == AXValueGetTypeID() else { return nil }

        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            AppConfiguration.axBoundsForRangeAttribute as CFString,
            range,
            &bounds
        ) == .success, let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }

        guard let rect: CGRect = Self.value(from: bounds, type: .cgRect) else { return nil }
        return PreviewPlacement.isUsable(axRect: rect) ? rect : nil
    }

    /// フォーカス中のウィンドウの矩形。キャレットを答えないアプリ向け。
    private func focusedWindowRect(of pid: pid_t) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        Self.setTimeout(on: app)
        guard let window = Self.copyElement(
            from: app,
            attribute: AppConfiguration.axFocusedWindowAttribute
        ) else { return nil }
        Self.setTimeout(on: window)

        guard let origin: CGPoint = Self.copyValue(
            from: window,
            attribute: AppConfiguration.axPositionAttribute,
            type: .cgPoint
        ), let size: CGSize = Self.copyValue(
            from: window,
            attribute: AppConfiguration.axSizeAttribute,
            type: .cgSize
        ) else { return nil }

        let rect = CGRect(origin: origin, size: size)
        return PreviewPlacement.isUsable(axRect: rect) ? rect : nil
    }

    private static func setTimeout(on element: AXUIElement) {
        AXUIElementSetMessagingTimeout(
            element,
            Float(AppConfiguration.previewAXMessagingTimeoutSeconds)
        )
    }

    private static func copyElement(from element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // 直前に型を確認している。
        return (value as! AXUIElement)
    }

    private static func copyValue<T>(
        from element: AXUIElement,
        attribute: String,
        type: AXValueType
    ) -> T? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return self.value(from: value, type: type)
    }

    private static func value<T>(from value: CFTypeRef, type: AXValueType) -> T? {
        // 呼び出し側が AXValue であることを確認している。
        let box = value as! AXValue
        guard AXValueGetType(box) == type else { return nil }
        let result = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { result.deallocate() }
        guard AXValueGetValue(box, type, result) else { return nil }
        return result.pointee
    }
}
