import AppKit
import Foundation
import os

/// 人の操作を必要としない確認。マイクの許可もアクセシビリティの許可も使わない。
/// `make selftest` から呼ぶ（設計書 19 の 3 と 5 を、実機確認の前に片付ける）。
enum SelfTest {
    @MainActor
    static func run(mode: String, arguments: [String]) -> Int32 {
        switch mode {
        case "--selftest-keys":
            return keys()
        case "--selftest-clipboard":
            return clipboard()
        case "--selftest-audio":
            return audio(arguments)
        case "--selftest-worker":
            return blocking { await worker(arguments) }
        default:
            print("使い方: HinoVoice --selftest-keys | --selftest-clipboard"
                + " | --selftest-audio <in.wav> <out.wav> | --selftest-worker <in.wav>")
            return 2
        }
    }

    // MARK: キーの飲み込み判定

    private static func keys() -> Int32 {
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print(passed ? "  ok   \(label)" : "  FAIL \(label)")
            if !passed { failures += 1 }
        }
        func start(_ down: Bool, repeated: Bool = false) -> KeyInput {
            KeyInput(keyCode: 49, flags: [.maskControl, .maskAlternate], isKeyDown: down, isRepeat: repeated)
        }
        func enter(_ down: Bool, repeated: Bool = false) -> KeyInput {
            KeyInput(keyCode: 36, flags: [], isKeyDown: down, isRepeat: repeated)
        }
        func numpadEnter(_ down: Bool) -> KeyInput {
            KeyInput(keyCode: 76, flags: [], isKeyDown: down, isRepeat: false)
        }
        func escape(_ down: Bool) -> KeyInput {
            KeyInput(keyCode: 53, flags: [], isKeyDown: down, isRepeat: false)
        }
        let passthrough = KeyDecision(swallow: false, event: nil)

        var idle = TapState(swallowsConfirmKeys: false, acceptsStartKey: true)
        check(KeyPolicy.decide(enter(true), state: &idle) == passthrough, "待機中の Enter は通す")
        check(KeyPolicy.decide(enter(false), state: &idle) == passthrough, "待機中の Enter の keyUp も通す")
        check(KeyPolicy.decide(escape(true), state: &idle) == passthrough, "待機中の Esc は通す")
        check(
            KeyPolicy.decide(start(true), state: &idle) == KeyDecision(swallow: true, event: .start),
            "待機中の ⌃⌥Space は飲み込んで開始する"
        )
        check(
            KeyPolicy.decide(start(false), state: &idle) == KeyDecision(swallow: true, event: nil),
            "飲み込んだ開始キーの keyUp も飲み込む"
        )
        check(
            KeyPolicy.decide(
                KeyInput(keyCode: 49, flags: [.maskCommand, .maskAlternate], isKeyDown: true, isRepeat: false),
                state: &idle
            ) == passthrough,
            "⌘⌥Space は開始キーではない"
        )
        check(
            KeyPolicy.decide(
                KeyInput(keyCode: 0, flags: [], isKeyDown: true, isRepeat: false),
                state: &idle
            ) == passthrough,
            "関係のないキーは通す"
        )

        var recording = TapState(swallowsConfirmKeys: true, acceptsStartKey: false)
        check(
            KeyPolicy.decide(enter(true), state: &recording) == KeyDecision(swallow: true, event: .confirm),
            "録音中の Enter は飲み込んで確定する"
        )
        check(
            KeyPolicy.decide(enter(true, repeated: true), state: &recording) == KeyDecision(swallow: true, event: nil),
            "押しっぱなしの繰り返しで二度目の確定は起きない"
        )
        check(
            KeyPolicy.decide(enter(false), state: &recording) == KeyDecision(swallow: true, event: nil),
            "確定した Enter の keyUp も飲み込む"
        )
        check(
            KeyPolicy.decide(numpadEnter(true), state: &recording) == KeyDecision(swallow: true, event: .confirm),
            "テンキーの Enter も確定する"
        )
        _ = KeyPolicy.decide(numpadEnter(false), state: &recording)
        check(
            KeyPolicy.decide(escape(true), state: &recording) == KeyDecision(swallow: true, event: .cancel),
            "録音中の Esc は飲み込んで取り消す"
        )
        check(
            KeyPolicy.decide(start(true), state: &recording) == passthrough,
            "録音中の開始キーは何もしない"
        )

        var transcribing = TapState(swallowsConfirmKeys: true, acceptsStartKey: false)
        check(
            KeyPolicy.decide(enter(true), state: &transcribing) == KeyDecision(swallow: true, event: .confirm),
            "文字起こし中の Enter も飲み込む"
        )
        var unavailable = TapState(swallowsConfirmKeys: false, acceptsStartKey: true)
        check(KeyPolicy.decide(enter(true), state: &unavailable) == passthrough, "停止中の Enter は通す")

        // 状態が変わっても、押下と離すの片側だけがアプリへ届かないこと
        // （OpenHinoVoice src/hook.rs:31-57）。
        var flipping = TapState(swallowsConfirmKeys: true, acceptsStartKey: false)
        _ = KeyPolicy.decide(enter(true), state: &flipping)
        flipping.swallowsConfirmKeys = false
        check(
            KeyPolicy.decide(enter(false), state: &flipping) == KeyDecision(swallow: true, event: nil),
            "録音中に飲み込んだ Enter は、待機中へ戻ってから離しても飲み込む"
        )
        var late = TapState(swallowsConfirmKeys: false, acceptsStartKey: true)
        _ = KeyPolicy.decide(enter(true), state: &late)
        late.swallowsConfirmKeys = true
        check(
            KeyPolicy.decide(enter(false), state: &late) == passthrough,
            "待機中に通した Enter は、録音中になってから離しても通す"
        )

        print(failures == 0 ? "キーの判定: 全件 ok" : "キーの判定: \(failures) 件 FAIL")
        return failures == 0 ? 0 : 1
    }

    // MARK: クリップボード

    private static func clipboard() -> Int32 {
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print(passed ? "  ok   \(label)" : "  FAIL \(label)")
            if !passed { failures += 1 }
        }

        let pasteboard = NSPasteboard.general
        // 実行者のクリップボードを壊さないように、最初に預かって最後に戻す。
        let entry = ClipboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("SELFTEST-ORIGINAL", forType: .string)
        let snapshot = ClipboardSnapshot.capture(from: pasteboard)
        check(snapshot.savedTypeCount >= 1, "保存した type が1つ以上ある")

        pasteboard.clearContents()
        pasteboard.setString("TRANSCRIPT", forType: .string)
        let ours = pasteboard.changeCount
        check(snapshot.restore(to: pasteboard, ifChangeCountIs: ours), "誰も上書きしていなければ復元する")
        check(pasteboard.string(forType: .string) == "SELFTEST-ORIGINAL", "元の内容が戻っている")

        let second = ClipboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("TRANSCRIPT", forType: .string)
        let expected = pasteboard.changeCount
        // 待っている間に他のアプリかユーザーがコピーした状況を作る。
        pasteboard.clearContents()
        pasteboard.setString("EXTERNAL-COPY", forType: .string)
        check(
            !second.restore(to: pasteboard, ifChangeCountIs: expected),
            "changeCount が変わっていたら復元しない"
        )
        check(pasteboard.string(forType: .string) == "EXTERNAL-COPY", "新しい内容を消さない")

        _ = entry.restore(to: pasteboard, ifChangeCountIs: pasteboard.changeCount)
        print(failures == 0 ? "クリップボード: 全件 ok" : "クリップボード: \(failures) 件 FAIL")
        return failures == 0 ? 0 : 1
    }

    // MARK: 16kHz モノラル変換

    private static func audio(_ arguments: [String]) -> Int32 {
        guard arguments.count >= 2 else {
            print("使い方: HinoVoice --selftest-audio <in.wav> <out.wav>")
            return 2
        }
        do {
            let pcm = try AudioResampler.convertFile(at: URL(fileURLWithPath: arguments[0]))
            print("  読み取りと変換: ok")
            try AudioResampler.writeWave(pcm: pcm, to: URL(fileURLWithPath: arguments[1]))
            let seconds = Double(pcm.count) / 2 / AppConfiguration.workerSampleRate
            print("  変換: \(pcm.count) バイト, \(pcm.count / 2) サンプル, \(String(format: "%.2f", seconds)) 秒")
            print("  出力: \(arguments[1])")
            return pcm.count > 0 && pcm.count % 2 == 0 ? 0 : 1
        } catch {
            print("  FAIL 変換に失敗: \(error)")
            return 1
        }
    }

    // MARK: worker との往復

    private static func worker(_ arguments: [String]) async -> Int32 {
        guard let path = arguments.first else {
            print("使い方: HinoVoice --selftest-worker <in.wav>")
            return 2
        }
        do {
            print("  speech: \(try SpeechWorkerClient.locateExecutable())")
            let pcm = try AudioResampler.convertFile(at: URL(fileURLWithPath: path))
            let seconds = Double(pcm.count) / 2 / AppConfiguration.workerSampleRate
            print("  音声: \(String(format: "%.2f", seconds)) 秒, \(pcm.count) バイト")

            let client = SpeechWorkerClient { status in
                print("  worker: \(String(describing: status))")
            }
            let launched = Date()
            try await client.startOnce()
            print("  ready: \(String(format: "%.2f", Date().timeIntervalSince(launched))) 秒")

            let id = await client.newRequest()
            let chunkBytes = Int(AppConfiguration.workerSampleRate * AppConfiguration.chunkSeconds) * 2
            var seq = 0
            var offset = pcm.startIndex
            while offset < pcm.endIndex {
                let end = min(offset + chunkBytes, pcm.endIndex)
                try await client.send(chunk: Data(pcm[offset ..< end]), id: id, seq: seq)
                seq += 1
                offset = end
            }
            print("  chunk: \(seq) 行")

            let started = Date()
            let transcript = try await client.transcribe(id: id)
            let elapsed = Date().timeIntervalSince(started)
            print("  transcribe: \(String(format: "%.2f", elapsed)) 秒, stop=\(transcript.stop)")
            print("  text: \(transcript.text)")
            await client.shutdown()
            guard !transcript.text.isEmpty else {
                print("worker との往復: FAIL（結果が空）")
                return 1
            }
            print("worker との往復: ok")
            return 0
        } catch {
            print("worker との往復: FAIL \(SpeechWorkerClient.message(of: error))")
            return 1
        }
    }

    /// 同期の `main` から1つの非同期処理を走らせる。
    private static func blocking(_ body: @escaping @Sendable () async -> Int32) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock(initialState: Int32(1))
        Task.detached {
            let code = await body()
            result.withLock { $0 = code }
            semaphore.signal()
        }
        semaphore.wait()
        return result.withLock { $0 }
    }
}
