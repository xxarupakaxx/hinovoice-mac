import AppKit

/// 録音中のプレビューを出す浮動ウィンドウ（設計書 6.1）。
///
/// フォーカスもキーも取らず、クリックは下のアプリへ通す。これが崩れると
/// `PasteTarget.current()` が見る前面アプリとフォーカス要素が動き、貼り付けの
/// 再確認が不一致になって「貼らない」側へ倒れる（設計書 6.4）。
///
/// 中身は編集も選択もできないラベル1つだけで、first responder になる view を
/// 置かない。出すのはプレビュー本文だけで、タイトルも説明文も入れない
/// （`rules/ui-copy.md`）。
@MainActor
final class PreviewPanel {
    private let panel: NSPanel
    private let background: NSVisualEffectView
    private let label: NSTextField

    init() {
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: AppConfiguration.previewMaxWidth, height: 32),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        // 通常ウィンドウより前に出し、Space とフルスクリーンに追従させ、
        // ⌘Tab には出さない。
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // クリックを下のアプリへ通す。
        panel.ignoresMouseEvents = true
        // キーウィンドウにならない。
        panel.becomesKeyOnlyIfNeeded = true
        // 非アクティブのまま出し続ける。
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // 角丸を描くために背景を自分で持つ。
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        background = NSVisualEffectView(frame: panel.contentLayoutRect)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = AppConfiguration.previewCornerRadius
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = AppConfiguration.previewBorderWidth

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: AppConfiguration.previewFontSize)
        label.textColor = .labelColor
        label.maximumNumberOfLines = AppConfiguration.previewMaxLines
        label.lineBreakMode = .byTruncatingTail
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.refusesFirstResponder = true

        background.addSubview(label)
        panel.contentView = background
    }

    /// 位置を決めて出す。`orderFrontRegardless()` だけを使う。
    /// `makeKeyAndOrderFront` と `NSApp.activate` は呼ばない（設計書 6.1）。
    func show(text: String, anchor: PreviewAnchor?) {
        let screens = Self.screenBoxes()
        guard let screen = Self.screen(for: anchor, in: screens) else { return }
        let resolved = anchor ?? Self.defaultAnchor(on: screen)

        let width = PreviewPlacement.width(
            maximum: AppConfiguration.previewMaxWidth,
            visibleFrame: screen.visibleFrame,
            inset: AppConfiguration.previewScreenInset
        )
        label.stringValue = text
        let size = size(for: width)
        let frame = PreviewPlacement.frame(
            anchor: resolved,
            size: size,
            screen: screen,
            gap: AppConfiguration.previewGap
        )

        panel.setFrame(frame, display: true)
        background.frame = CGRect(origin: .zero, size: frame.size)
        label.frame = CGRect(
            x: AppConfiguration.previewHorizontalPadding,
            y: AppConfiguration.previewVerticalPadding,
            width: frame.width - AppConfiguration.previewHorizontalPadding * 2,
            height: frame.height - AppConfiguration.previewVerticalPadding * 2
        )
        // 層に置いた色は外観の切り替えに追従しないので、出すたびに引き直す。
        background.effectiveAppearance.performAsCurrentDrawingAppearance {
            background.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// 文字の高さに合わせる。上限は2行（設計書 3.3）。
    private func size(for width: CGFloat) -> CGSize {
        let inner = width - AppConfiguration.previewHorizontalPadding * 2
        label.preferredMaxLayoutWidth = inner
        let fitting = label.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude))
        let fontHeight = label.font.map { CGFloat($0.boundingRectForFont.height) }
        let lineHeight = ceil(fontHeight ?? CGFloat(AppConfiguration.previewFontSize))
        let capped = min(fitting.height, lineHeight * CGFloat(AppConfiguration.previewMaxLines) + 2)
        return CGSize(
            width: width,
            height: ceil(max(capped, lineHeight)) + AppConfiguration.previewVerticalPadding * 2
        )
    }

    private static func screenBoxes() -> [ScreenBox] {
        NSScreen.screens.map { ScreenBox(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }

    private static func screen(for anchor: PreviewAnchor?, in screens: [ScreenBox]) -> ScreenBox? {
        guard let anchor else { return screens.first }
        return PreviewPlacement.screen(containing: anchor.rect, in: screens) ?? screens.first
    }

    /// 基準が何も取れなかったとき。メニューバーの下の左に置く。
    private static func defaultAnchor(on screen: ScreenBox) -> PreviewAnchor {
        PreviewAnchor(
            rect: CGRect(x: screen.visibleFrame.minX + 16, y: screen.visibleFrame.maxY, width: 0, height: 0),
            tier: .menubar,
            prefersBelow: true
        )
    }
}
