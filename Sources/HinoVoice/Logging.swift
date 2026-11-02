import OSLog

/// 出さないもの: 文字起こしの本文、クリップボードの内容、音声データ、
/// マイクのデバイス名（設計書 14）。数値と状態名だけを public で出す。
enum Log {
    static let app = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "app")
    static let hotkey = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "hotkey")
    static let audio = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "audio")
    static let worker = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "worker")
    static let paste = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "paste")
    static let state = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "state")
}
