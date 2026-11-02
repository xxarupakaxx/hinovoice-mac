import Foundation

/// speech worker の protocol 4（JSON Lines）のうち、このアプリが使う部分だけを扱う。
/// 受信側は未知の member を無視できるが、解釈できない行は worker の欠陥として
/// 失敗させる（設計書 12.3、worker-protocol.md「stdout carries the protocol and nothing else」）。
enum WorkerProtocol {
    struct Incoming: Decodable {
        let type: String
        let id: String?
        let protocolVersion: Int?
        let version: String?
        let model: Model?
        let text: String?
        let stop: String?
        let done: Double?
        let error: WorkerErrorBody?

        enum CodingKeys: String, CodingKey {
            case type
            case id
            case protocolVersion = "protocol"
            case version
            case model
            case text
            case stop
            case done
            case error
        }
    }

    struct Model: Decodable {
        let name: String?
        let task: String?
        let languages: [String]?
        let sampleRate: Int?
        let license: String?

        enum CodingKeys: String, CodingKey {
            case name
            case task
            case languages
            case sampleRate = "sample_rate"
            case license
        }
    }

    struct WorkerErrorBody: Decodable {
        let code: String?
        let option: String?
        let message: String?
    }

    /// 1つの認識リクエストの終端メッセージ（end / error / cancelled）。
    enum Terminal: Sendable {
        case end(text: String, stop: String)
        case failed(code: String, message: String)
        case cancelled
    }

    static func decode(line: Data) throws -> Incoming {
        do {
            return try JSONDecoder().decode(Incoming.self, from: line)
        } catch {
            throw WorkerFailure.protocolViolation("stdout の行を JSON として解釈できません")
        }
    }

    // MARK: 送信

    /// chunk は base64 が本体なので、文字列を直接組む。`id` は UUID 由来で
    /// エスケープの必要な文字を含まない。
    static func chunkLine(id: String, seq: Int, pcm: Data) -> Data {
        let encoded = pcm.base64EncodedString()
        return line(#"{"type":"chunk","id":"\#(id)","seq":\#(seq),"pcm":"\#(encoded)"}"#)
    }

    static func transcribeLine(id: String, sampleRate: Int, language: String) -> Data {
        line(#"{"type":"transcribe","id":"\#(id)","sample_rate":\#(sampleRate),"language":"\#(language)"}"#)
    }

    static func cancelLine(id: String) -> Data {
        line(#"{"type":"cancel","id":"\#(id)"}"#)
    }

    private static func line(_ json: String) -> Data {
        Data((json + "\n").utf8)
    }
}

enum WorkerFailure: Error, Sendable {
    case executableNotFound([String])
    case spawnFailed(String)
    case protocolViolation(String)
    case workerError(code: String, message: String)
    case timeout(String)
    case terminated
    case cancelled
    case notRunning

    /// メニューに出す1行。原因の切り分けに必要な情報だけを入れる。
    var userMessage: String {
        switch self {
        case let .executableNotFound(paths):
            return "speech が見つかりません（探した場所: \(paths.joined(separator: ", "))）"
        case let .spawnFailed(detail):
            return "speech を起動できません: \(detail)"
        case let .protocolViolation(detail):
            return "speech の応答が不正です: \(detail)"
        case let .workerError(code, message):
            return "speech がエラーを返しました（\(code)）: \(message)"
        case let .timeout(phase):
            return "speech が応答しません（\(phase)）"
        case .terminated:
            return "speech が終了しました"
        case .cancelled:
            return "取り消しました"
        case .notRunning:
            return "speech が起動していません"
        }
    }

    /// ログに出す短い識別子。本文は含めない。
    var code: String {
        switch self {
        case .executableNotFound: return "not_found"
        case .spawnFailed: return "spawn_failed"
        case .protocolViolation: return "protocol_violation"
        case let .workerError(code, _): return "worker_\(code)"
        case let .timeout(phase): return "timeout_\(phase)"
        case .terminated: return "terminated"
        case .cancelled: return "cancelled"
        case .notRunning: return "not_running"
        }
    }
}
