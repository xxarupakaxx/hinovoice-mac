import AppKit
import Foundation

@main
struct HinoVoiceApp {
    @MainActor
    static func main() {
        // worker が先に死んだときのパイプへの書き込みでプロセスが落ちないようにする。
        signal(SIGPIPE, SIG_IGN)

        let arguments = Array(CommandLine.arguments.dropFirst())
        if let mode = arguments.first, mode.hasPrefix("--selftest") {
            exit(SelfTest.run(mode: mode, arguments: Array(arguments.dropFirst())))
        }
        // `--selftest-preview-worker` が自分自身を worker として起動する隠しモード
        // （設計書 9.1）。シェル script を増やさないので署名もバンドルも変わらない。
        if arguments.first == "--fake-worker" {
            exit(FakeWorker.run(scenario: arguments.count > 1 ? arguments[1] : ""))
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // Dock にも ⌘Tab にも出さない（設計書 7.2）。
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = RecordingCoordinator()
    private var menu: MenuBarController?

    func applicationDidFinishLaunching(_: Notification) {
        let menu = MenuBarController(coordinator: coordinator)
        self.menu = menu
        coordinator.onPresentation = { presentation in
            menu.apply(presentation)
        }
        coordinator.menuBarFrame = { [weak menu] in menu?.statusItemFrame }
        coordinator.start()
        Log.app.notice("launched")
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await coordinator.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
