import Foundation

/// `--fake-worker <シナリオ>`。`--selftest-preview-worker` が同じバイナリを worker
/// として起動し、プレビューと最終の往復、`cancel` の順序、沈黙とエラーの扱いを
/// 実 worker もモデルもなしで確かめる（設計書 9.1）。
///
/// シェル script を増やさないので、署名もバンドルも変わらない。stdout は
/// プロトコルだけを運ぶ（worker-protocol.md）。返す文字列は検査用の固定値で、
/// 音声からは作らない。
enum FakeWorker {
    enum Scenario: String, CaseIterable {
        /// `ready` を出して台本の文字列列を順に返す。要求は厳密に直列。
        case serial
        /// プレビューの応答に3秒かける。
        case slowPreview = "slow-preview"
        /// プレビューは `error`、最終は `end`。
        case previewError = "preview-error"
        /// プレビューに一切答えない。
        case previewSilent = "preview-silent"

        /// プレビュー1件の処理にかける時間。
        var previewSeconds: Double {
            switch self {
            case .serial: 0.5
            case .slowPreview: 3.0
            case .previewError: 0.05
            case .previewSilent: 0
            }
        }
    }

    static func run(scenario raw: String) -> Int32 {
        guard let scenario = Scenario(rawValue: raw) else {
            FileHandle.standardError.write(Data("fake-worker: unknown scenario \(raw)\n".utf8))
            return 2
        }
        FakeWorkerSession(scenario: scenario).run()
        return 0
    }
}

/// 要求を1件ずつ処理する偽 worker。読み取りは呼び出したスレッドで行い、
/// 要求の処理は1本の直列キューに載せる。これで「Requests run one at a time」
/// （worker-protocol.md:29）を満たす。
private final class FakeWorkerSession: @unchecked Sendable {
    private let scenario: FakeWorker.Scenario
    private let jobs = DispatchQueue(label: "\(AppConfiguration.bundleIdentifier).fake-worker")
    private let outputLock = NSLock()
    private let stateLock = NSLock()

    /// 台本。プレビューが伸びていく様子を再現する。
    private static let script = [
        "きょうは",
        "きょうは良い",
        "きょうは良い天気",
        "きょうは良い天気です",
    ]
    private static let finalText = "きょうは良い天気です。"

    private var seen: Set<String> = []
    private var running: Set<String> = []
    private var cancelled: Set<String> = []
    private var finished: Set<String> = []
    /// `serial` シナリオだけが使う。プレビューが畳まれる前に最終の
    /// `transcribe` が来たら、順序の違反として最終を `error` で返す。
    private var previewInFlight: String?
    private var scriptIndex = 0

    init(scenario: FakeWorker.Scenario) {
        self.scenario = scenario
    }

    func run() {
        let model = #"{"name":"fake","task":"recognition","languages":["ja"],"sample_rate":16000}"#
        write(#"{"type":"ready","protocol":4,"version":"fake-worker","defaults":{},"model":\#(model)}"#)

        var buffer = Data()
        let input = FileHandle.standardInput
        while true {
            let data = input.availableData
            if data.isEmpty { break }
            buffer.append(data)
            while let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex ..< index])
                buffer.removeSubrange(buffer.startIndex ... index)
                handle(line: line)
            }
        }
        // stdin が閉じたら手元の要求に答えてから 0 で終わる（worker-protocol.md）。
        jobs.sync {}
    }

    // MARK: 受信

    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String,
              let id = object["id"] as? String
        else { return }

        switch type {
        case "chunk":
            note(id)
        case "transcribe":
            note(id)
            if Self.isPreview(id) {
                startPreview(id)
            } else {
                startFinal(id)
            }
        case "cancel":
            cancel(id)
        default:
            // 知らない type は無視する。
            return
        }
    }

    private static func isPreview(_ id: String) -> Bool {
        id.hasPrefix("p-")
    }

    private func note(_ id: String) {
        stateLock.lock()
        seen.insert(id)
        if scenario == .serial, Self.isPreview(id), !finished.contains(id) {
            previewInFlight = id
        }
        stateLock.unlock()
    }

    private func startPreview(_ id: String) {
        guard scenario != .previewSilent else {
            // 答えない。直列キューにも載せないので、最終は待たされない。
            return
        }
        perform(
            id: id,
            seconds: scenario.previewSeconds,
            errorCode: scenario == .previewError ? "audio" : nil,
            text: nextScript()
        )
    }

    private func startFinal(_ id: String) {
        stateLock.lock()
        let violation = scenario == .serial && previewInFlight != nil
        if violation { finished.insert(id) }
        stateLock.unlock()

        guard !violation else {
            // プレビューを畳む前に最終の `transcribe` が来た。設計書 5.3 の順序が
            // 崩れていれば、ここで最終が落ちる。
            send(error: id, code: "preview_not_cancelled")
            return
        }
        perform(id: id, seconds: 0.05, errorCode: nil, text: Self.finalText)
    }

    private func cancel(_ id: String) {
        stateLock.lock()
        if previewInFlight == id { previewInFlight = nil }
        guard !finished.contains(id), seen.contains(id) else {
            // 終端済み、または知らない id への `cancel` は無視する
            // （worker-protocol.md:79）。
            stateLock.unlock()
            return
        }
        cancelled.insert(id)
        // 走り出していない要求はその場で `cancelled` にする（設計書 5.2）。
        let answerNow = !running.contains(id)
        if answerNow { finished.insert(id) }
        stateLock.unlock()

        if answerNow { send(cancelled: id) }
    }

    // MARK: 処理

    private func perform(id: String, seconds: Double, errorCode: String?, text: String) {
        jobs.async { [self] in
            stateLock.lock()
            let skip = finished.contains(id)
            if !skip { running.insert(id) }
            stateLock.unlock()
            guard !skip else { return }

            // 走行中の `cancel` は、仕事を切れる次の地点で効く。実 worker の
            // 0.31〜0.44 秒（設計書 5.2）に合わせて 0.3 秒待ってから返す。
            var waited = 0.0
            while waited < seconds {
                if isCancelled(id) {
                    Thread.sleep(forTimeInterval: 0.3)
                    complete(id) { send(cancelled: id) }
                    return
                }
                Thread.sleep(forTimeInterval: 0.02)
                waited += 0.02
            }
            if isCancelled(id) {
                Thread.sleep(forTimeInterval: 0.3)
                complete(id) { send(cancelled: id) }
                return
            }
            if let errorCode {
                complete(id) { send(error: id, code: errorCode) }
            } else {
                complete(id) { send(end: id, text: text) }
            }
        }
    }

    private func isCancelled(_ id: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled.contains(id)
    }

    private func complete(_ id: String, _ body: () -> Void) {
        stateLock.lock()
        let already = finished.contains(id)
        finished.insert(id)
        running.remove(id)
        if previewInFlight == id { previewInFlight = nil }
        stateLock.unlock()
        // 1つの要求には終端メッセージを1つだけ出す（worker-protocol.md:102）。
        guard !already else { return }
        body()
    }

    private func nextScript() -> String {
        stateLock.lock()
        defer { stateLock.unlock() }
        let text = Self.script[min(scriptIndex, Self.script.count - 1)]
        scriptIndex += 1
        return text
    }

    // MARK: 送信

    private func send(end id: String, text: String) {
        write(#"{"type":"end","id":"\#(id)","text":\#(Self.quoted(text)),"stop":"complete"}"#)
    }

    private func send(error id: String, code: String) {
        write(#"{"type":"error","id":"\#(id)","error":{"code":"\#(code)","option":null,"message":"fake worker"}}"#)
    }

    private func send(cancelled id: String) {
        write(#"{"type":"cancelled","id":"\#(id)"}"#)
    }

    private func write(_ json: String) {
        outputLock.lock()
        defer { outputLock.unlock() }
        FileHandle.standardOutput.write(Data((json + "\n").utf8))
    }

    /// JSON の文字列リテラルへ直す。台本は固定値だが、エスケープは標準に任せる。
    private static func quoted(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8),
              array.count >= 2
        else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }
}
