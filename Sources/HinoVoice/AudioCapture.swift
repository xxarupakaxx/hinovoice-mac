import AVFoundation
import Foundation

enum AudioFailure: Error, Sendable {
    case noInputDevice
    case unsupportedFormat
    case engineFailed(String)

    var userMessage: String {
        switch self {
        case .noInputDevice: return "マイクが見つかりません"
        case .unsupportedFormat: return "マイクの形式を 16kHz へ変換できません"
        case let .engineFailed(detail): return "録音を開始できません: \(detail)"
        }
    }
}

/// マイクの形式（内蔵なら 48kHz Float32）から worker へ送る形式へ変換する。
/// ミックスダウンとリサンプルは AVAudioConverter に任せる（設計書 11）。
final class AudioResampler {
    /// モノラルの出力。`channels: 1` を指定した `AVAudioFormat` は
    /// kAudioChannelLayoutTag_Mono のレイアウトを持つので、変換器は
    /// ミックスダウン先のチャンネル配置を判断できる。
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: AppConfiguration.workerSampleRate,
        channels: 1,
        interleaved: true
    )!

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat

    init(inputFormat: AVAudioFormat) throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: Self.outputFormat)
        else {
            throw AudioFailure.unsupportedFormat
        }
        // 既定の `downmix` は NO で、チャンネルを混ぜずに配置し直す。2ch の機器で
        // 片側だけに音声が入る場合、その音声を落とすことになるので混ぜる側にする。
        converter.downmix = true
        self.converter = converter
        self.inputFormat = inputFormat
    }

    func convert(_ input: AVAudioPCMBuffer) -> Data {
        guard input.frameLength > 0 else { return Data() }
        let ratio = Self.outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else {
            return Data()
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error {
            Log.audio.error("resample failed")
            return Data()
        }
        return Self.littleEndianBytes(of: output)
    }

    /// 変換器に残ったサンプルを吐き出す。捨てると発話の最後が落ちる（設計書 11）。
    func flush() -> Data {
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: 8192) else {
            return Data()
        }
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        return Self.littleEndianBytes(of: output)
    }

    /// プロトコルの `pcm` は 16bit リトルエンディアンのモノラル（worker-protocol.md）。
    /// Apple Silicon はリトルエンディアンだが、暗黙に頼らず明示して書く。
    static func littleEndianBytes(of buffer: AVAudioPCMBuffer) -> Data {
        guard let channel = buffer.int16ChannelData else { return Data() }
        let count = Int(buffer.frameLength)
        var data = Data(capacity: count * 2)
        let samples = channel[0]
        for index in 0 ..< count {
            withUnsafeBytes(of: samples[index].littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func buffer(from pcm: Data) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames),
              let channel = buffer.int16ChannelData
        else { return nil }
        buffer.frameLength = frames
        for index in 0 ..< Int(frames) {
            let low = Int16(pcm[pcm.startIndex + index * 2])
            let high = Int16(bitPattern: UInt16(pcm[pcm.startIndex + index * 2 + 1]) << 8)
            channel[0][index] = high | low
        }
        return buffer
    }

    /// WAVE ファイルを 16kHz モノラル 16bit へ変換する。`--selftest-*` で使う。
    static func convertFile(at url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let resampler = try AudioResampler(inputFormat: file.processingFormat)
        var pcm = Data()
        let frames: AVAudioFrameCount = 4096
        // 末尾を超えて読むとエラーになるので、残りのフレーム数で区切る。
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(min(Int64(frames), file.length - file.framePosition))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: remaining) else {
                throw AudioFailure.unsupportedFormat
            }
            try file.read(into: buffer, frameCount: remaining)
            if buffer.frameLength == 0 { break }
            pcm.append(resampler.convert(buffer))
        }
        pcm.append(resampler.flush())
        return pcm
    }

    static func writeWave(pcm: Data, to url: URL) throws {
        guard let buffer = buffer(from: pcm) else { throw AudioFailure.unsupportedFormat }
        try? FileManager.default.removeItem(at: url)
        // commonFormat を指定しないと processingFormat が Float32 になり、
        // Int16 のバッファを書けない。
        let file = try AVAudioFile(
            forWriting: url,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        try file.write(from: buffer)
    }
}

/// マイクから取り込み、0.25 秒ぶんたまるごとに呼び出し側へ渡す。
/// タップのコールバックはオーディオスレッドから呼ばれるので、ここでは変換と
/// バッファへの追加だけを行い、送信は呼び出し側の別タスクに任せる（設計書 11）。
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let onChunk: @Sendable (Data) -> Void
    private let chunkBytes = Int(AppConfiguration.workerSampleRate * AppConfiguration.chunkSeconds) * 2

    /// プレビューは毎回「ここまでの音声全体」を送り直す。プロトコル上これ以外の
    /// 方法はない（設計書 4.2）ので、変換後の PCM をここに溜める。固定長で持ち、
    /// base64 文字列は毎回作り直して使い捨てる。保持すると 2.56 MB が常駐する。
    private let recordedCap = Int(
        AppConfiguration.workerSampleRate * AppConfiguration.maxRecordingSeconds
    ) * 2

    private var resampler: AudioResampler?
    private var pending = Data()
    private var recorded = Data()
    private var convertedBytes = 0

    init(onChunk: @escaping @Sendable (Data) -> Void) {
        self.onChunk = onChunk
    }

    /// 送った音声の秒数。ログ用（設計書 14）。
    var recordedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(convertedBytes) / 2 / AppConfiguration.workerSampleRate
    }

    /// ここまでの音声全体。プレビューの1ラウンドぶんの入力になる（設計書 4.2）。
    ///
    /// バッファを共有して返すと、次の `append` で Data が写しを作る。その写しは
    /// オーディオスレッドで起きるので、ここで先に取り切って `recorded` の参照を
    /// 1つに保つ。確保しておいた容量も維持される。
    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !recorded.isEmpty else { return Data() }
        return recorded.withUnsafeBytes { bytes in
            Data(bytes: bytes.baseAddress!, count: bytes.count)
        }
    }

    func start() throws {
        let input = engine.inputNode
        // 形式は環境によって変わるので固定値にしない（設計書 11）。
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioFailure.noInputDevice }

        lock.lock()
        resampler = try? AudioResampler(inputFormat: format)
        pending = Data()
        recorded = Data()
        recorded.reserveCapacity(recordedCap)
        convertedBytes = 0
        let ready = resampler != nil
        lock.unlock()
        guard ready else { throw AudioFailure.unsupportedFormat }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioFailure.engineFailed(error.localizedDescription)
        }
        Log.audio.notice("""
        capture started at \(format.sampleRate, privacy: .public) Hz \
        \(format.channelCount, privacy: .public) ch
        """)
    }

    /// 端数のサンプルと変換器に残った分を返す。これを最後の chunk として送る。
    func stop() -> Data {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        lock.lock()
        defer { lock.unlock() }
        // 変換器に残った分は、まだ `recorded` に入っていない。
        let flushed = resampler?.flush() ?? Data()
        var tail = pending
        tail.append(flushed)
        convertedBytes += flushed.count
        appendRecordedLocked(flushed)
        pending = Data()
        resampler = nil
        return tail
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let resampler else {
            lock.unlock()
            return
        }
        let converted = resampler.convert(buffer)
        pending.append(converted)
        appendRecordedLocked(converted)
        convertedBytes += converted.count
        var chunks: [Data] = []
        while pending.count >= chunkBytes {
            chunks.append(Data(pending.prefix(chunkBytes)))
            pending.removeFirst(chunkBytes)
        }
        lock.unlock()
        for chunk in chunks {
            onChunk(chunk)
        }
    }

    /// 蓄積は 60 秒ぶんで打ち切る。録音は `limitTask` が 60 秒で止めるので
    /// ここに届くのはタップの行き過ぎ分だけだが、上限を型で持たせておく。
    /// 呼び出し側が `lock` を持っていること。
    private func appendRecordedLocked(_ converted: Data) {
        guard !converted.isEmpty else { return }
        recorded.append(converted)
        if recorded.count > recordedCap {
            recorded.removeFirst(recorded.count - recordedCap)
        }
    }
}
