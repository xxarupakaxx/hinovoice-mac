import CoreGraphics

/// プレビューをどこに固定するか。上から順に段を下げる（設計書 6.2）。
enum PreviewAnchorTier: String, Equatable {
    /// キャレットの矩形。
    case caret
    /// フォーカス中のウィンドウ。
    case window
    /// メニューバーの項目。
    case menubar
}

/// プレビューを出す基準。矩形は AppKit の座標（左下原点、Y 上向き）である。
struct PreviewAnchor: Equatable {
    var rect: CGRect
    var tier: PreviewAnchorTier
    /// 矩形の下に出すか、上に出すか。キャレットとメニューバー項目は下に出し、
    /// フォーカスウィンドウは左下の内側に置くので上に出す（設計書 6.2）。
    var prefersBelow: Bool
}

/// 画面1枚ぶんの矩形。`NSScreen` を作れない検査から同じ計算を確かめるため、
/// 値だけで受ける（設計書 6.3）。
struct ScreenBox: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
}

/// 座標変換と画面への寄せ。`NSScreen` にも AX にも触らない純粋関数だけを置き、
/// `--selftest-preview-place` で検証する（設計書 6.3）。
enum PreviewPlacement {
    /// AX から取れた矩形を使えるか。幅も高さも 0、または原点が (0,0) なら
    /// 「取れなかった」として次の段へ落ちる（設計書 6.2）。
    ///
    /// キャレットの矩形は幅 0 で高さだけを持つことがあるので、両方が 0 の
    /// ときだけ捨てる。
    static func isUsable(axRect: CGRect) -> Bool {
        if axRect.width == 0, axRect.height == 0 { return false }
        if axRect.origin == .zero { return false }
        return true
    }

    /// AX は左上原点で Y 下向き、AppKit は左下原点で Y 上向きである。基準は
    /// 原点 (0,0) を持つメニューバーのある画面（`NSScreen.screens.first`）。
    /// `NSScreen.main` はキーウィンドウのある画面を指すので使わない。この
    /// パネルはキーウィンドウにならない（設計書 6.3）。
    static func appKitRect(axRect: CGRect, primaryFrame: CGRect) -> CGRect {
        CGRect(
            x: axRect.origin.x,
            y: primaryFrame.height - (axRect.origin.y + axRect.height),
            width: axRect.width,
            height: axRect.height
        )
    }

    /// 矩形の左下を含む画面。幅 0 の矩形でも選べるように、点で判定する
    /// （`CGRect.intersects` は空の矩形に対して常に false を返す）。
    /// どの画面にも入らなければ nil。
    static func screen(containing rect: CGRect, in screens: [ScreenBox]) -> ScreenBox? {
        let point = CGPoint(x: rect.minX, y: rect.minY)
        return screens.first { $0.frame.contains(point) }
    }

    /// パネルの幅（設計書 3.3）。画面に収まらない幅は要求しない。
    static func width(maximum: CGFloat, visibleFrame: CGRect, inset: CGFloat) -> CGFloat {
        max(1, min(maximum, visibleFrame.width - inset))
    }

    /// 基準の矩形から `gap` だけ離して置き、画面の見える範囲へ寄せる。
    /// 望んだ側に入らなければ反対側へ出す（設計書 6.3）。
    static func frame(anchor: PreviewAnchor, size: CGSize, screen: ScreenBox, gap: CGFloat) -> CGRect {
        let visible = screen.visibleFrame
        let x = max(min(anchor.rect.minX, visible.maxX - size.width), visible.minX)

        let below = anchor.rect.minY - gap - size.height
        let above = anchor.rect.maxY + gap
        var y = anchor.prefersBelow ? below : above
        if y < visible.minY || y + size.height > visible.maxY {
            y = anchor.prefersBelow ? above : below
        }
        y = max(min(y, visible.maxY - size.height), visible.minY)

        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
