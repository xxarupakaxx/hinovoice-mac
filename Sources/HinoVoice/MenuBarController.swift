import AppKit

/// メニューバーの項目。アイコンは状態で変える。実機で状態を確かめる手段として
/// 最小版に必要なものである（設計書 15）。
@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let retryItem: NSMenuItem
    private let accessibilityItem: NSMenuItem
    private let inputMonitoringItem: NSMenuItem
    private weak var coordinator: RecordingCoordinator?

    init(coordinator: RecordingCoordinator) {
        self.coordinator = coordinator
        retryItem = NSMenuItem(title: "再試行", action: nil, keyEquivalent: "")
        accessibilityItem = NSMenuItem(title: "アクセシビリティを許可する", action: nil, keyEquivalent: "")
        inputMonitoringItem = NSMenuItem(title: "入力監視の設定を開く", action: nil, keyEquivalent: "")
        super.init()

        statusLine.isEnabled = false
        retryItem.target = self
        retryItem.action = #selector(retry)
        accessibilityItem.target = self
        accessibilityItem.action = #selector(openAccessibility)
        inputMonitoringItem.target = self
        inputMonitoringItem.action = #selector(openInputMonitoring)

        let notices = NSMenuItem(title: "このアプリについて", action: #selector(openNotices), keyEquivalent: "")
        notices.target = self
        let quit = NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q")
        quit.target = self

        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(retryItem)
        menu.addItem(accessibilityItem)
        menu.addItem(inputMonitoringItem)
        menu.addItem(.separator())
        menu.addItem(notices)
        menu.addItem(quit)
        statusItem.menu = menu
    }

    func apply(_ presentation: MenuPresentation) {
        if let button = statusItem.button {
            // 記号が無い環境でメニューバーの項目が見えなくならないようにする。
            let image = NSImage(systemSymbolName: presentation.symbolName, accessibilityDescription: "HinoVoice")
                ?? NSImage(systemSymbolName: "mic", accessibilityDescription: "HinoVoice")
            image?.isTemplate = true
            button.image = image
            button.title = image == nil ? "HV" : ""
        }
        statusLine.title = presentation.statusText
        retryItem.isHidden = !presentation.showsRetry
        accessibilityItem.isHidden = !presentation.showsAccessibilityHelp
        inputMonitoringItem.isHidden = !presentation.showsAccessibilityHelp
    }

    @objc private func retry() {
        coordinator?.retryWorker()
    }

    @objc private func openAccessibility() {
        Permissions.promptAccessibility()
        Permissions.openAccessibilitySettings()
        coordinator?.retryTap()
    }

    @objc private func openInputMonitoring() {
        Permissions.openInputMonitoringSettings()
        coordinator?.retryTap()
    }

    @objc private func openNotices() {
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
