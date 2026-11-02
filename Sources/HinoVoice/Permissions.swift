import AppKit
import ApplicationServices
import AVFoundation

enum Permissions {
    /// 起動時ではなく、最初に録音を始めるときに呼ぶ（設計書 7.1）。
    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// システムのプロンプトを出す。アクセシビリティには usage description のキーがない。
    static func promptAccessibility() {
        // `kAXTrustedCheckOptionPrompt` は可変のグローバルとして import されるため
        // Swift 6 では参照できない。同じ値の文字列を直接使う。
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// CGEventTap の作成に失敗したときは入力監視も案内する（設計書 7.1、18）。
    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
