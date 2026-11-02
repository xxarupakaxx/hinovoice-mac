import AppKit
import AVFoundation
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
        case "--selftest-session":
            return session()
        case "--selftest-target":
            return pasteTarget()
        case "--selftest-shutdown":
            return shutdownGate()
        case "--selftest-clipboard":
            return clipboard()
        case "--selftest-audio":
            return audio(arguments)
        case "--selftest-downmix":
            return downmix()
        case "--selftest-worker":
            return blocking { await worker(arguments) }
        default:
            print("使い方: HinoVoice --selftest-keys | --selftest-session | --selftest-target"
                + " | --selftest-shutdown | --selftest-clipboard"
                + " | --selftest-audio <in.wav> <out.wav> | --selftest-downmix"
                + " | --selftest-worker <in.wav>")
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

        // 修飾キーを先に離す場合。⌃⌥Space の Control と Option を離してから
        // Space を離すと、keyUp の修飾状態は空になる。役割で照合すると `.other`
        // になって keyUp が漏れ、開始キーの捕捉状態も残る（レビュー MUST 4）。
        var released = TapState(swallowsConfirmKeys: false, acceptsStartKey: true)
        check(
            KeyPolicy.decide(start(true), state: &released) == KeyDecision(swallow: true, event: .start),
            "⌃⌥Space を飲み込んで開始する"
        )
        released.acceptsStartKey = false // 録音中へ遷移した
        check(
            KeyPolicy.decide(
                KeyInput(keyCode: 49, flags: [], isKeyDown: false, isRepeat: false),
                state: &released
            ) == KeyDecision(swallow: true, event: nil),
            "Control と Option を先に離しても Space の keyUp を飲み込む"
        )
        released.acceptsStartKey = true // 待機中へ戻った
        check(
            KeyPolicy.decide(start(true), state: &released) == KeyDecision(swallow: true, event: .start),
            "捕捉状態が残らないので次の ⌃⌥Space も開始できる"
        )

        // Option だけを離した途中の状態でも同じこと。
        var partly = TapState(swallowsConfirmKeys: false, acceptsStartKey: true)
        _ = KeyPolicy.decide(start(true), state: &partly)
        check(
            KeyPolicy.decide(
                KeyInput(keyCode: 49, flags: [.maskControl], isKeyDown: false, isRepeat: false),
                state: &partly
            ) == KeyDecision(swallow: true, event: nil),
            "Option だけ離した状態の Space の keyUp も飲み込む"
        )

        // Return とテンキーの Enter は別の物理キーである。片方の keyUp で
        // もう片方の捕捉状態を消してはいけない（レビュー MUST 4）。
        var both = TapState(swallowsConfirmKeys: true, acceptsStartKey: false)
        check(
            KeyPolicy.decide(enter(true), state: &both) == KeyDecision(swallow: true, event: .confirm),
            "Return を飲み込んで確定する"
        )
        check(
            KeyPolicy.decide(numpadEnter(false), state: &both) == passthrough,
            "飲み込んでいないテンキー Enter の keyUp は通す"
        )
        check(
            KeyPolicy.decide(enter(false), state: &both) == KeyDecision(swallow: true, event: nil),
            "Return の keyUp はそのあとでも飲み込む"
        )
        check(
            KeyPolicy.decide(numpadEnter(true), state: &both) == KeyDecision(swallow: true, event: .confirm),
            "テンキー Enter は Return とは別に捕捉する"
        )
        check(
            KeyPolicy.decide(
                KeyInput(keyCode: 76, flags: [.maskShift], isKeyDown: false, isRepeat: false),
                state: &both
            ) == KeyDecision(swallow: true, event: nil),
            "Shift を押しながら離したテンキー Enter の keyUp も飲み込む"
        )

        print(failures == 0 ? "キーの判定: 全件 ok" : "キーの判定: \(failures) 件 FAIL")
        return failures == 0 ? 0 : 1
    }

    // MARK: Esc と認識完了の競合

    /// 取り消しは `await` の前に世代を進める。再開地点で照合すれば、取り消した
    /// あとに届いた結果は貼られず、古い処理の後始末は新しいセッションに触れない
    /// （レビュー MUST 2）。
    private static func session() -> Int32 {
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print(passed ? "  ok   \(label)" : "  FAIL \(label)")
            if !passed { failures += 1 }
        }

        var generation = SessionGeneration()
        let first = generation.begin()
        check(generation.isCurrent(first), "始めた世代は有効")

        // Esc。worker へ cancel を送る前に無効化する。
        generation.invalidate()
        check(!generation.isCurrent(first), "取り消したあと、録音中の世代は無効")

        // 競合していた end がここで届く。貼り付けへ進んではいけない。
        check(!generation.isCurrent(first), "取り消しのあとに届いた結果は貼らない")

        // 取り消し直後に次の録音を始める。
        let second = generation.begin()
        check(generation.isCurrent(second), "次の録音の世代は有効")
        check(!generation.isCurrent(first), "古い世代は新しい録音と一致しない")

        // 遅れてきた古い処理の後始末が、新しいセッションを消さないこと。
        check(first != second, "世代は再利用しない")
        generation.invalidate()
        check(!generation.isCurrent(second), "新しい録音も取り消せる")
        let third = generation.begin()
        check(third != first && third != second, "世代は常に新しい値になる")

        print(failures == 0 ? "セッションの世代: 全件 ok" : "セッションの世代: \(failures) 件 FAIL")
        return failures == 0 ? 0 : 1
    }

    // MARK: 貼り付け先の照合

    /// 入力先を確かめられないときは貼らない（レビュー MUST 5）。AXUIElement は
    /// 他のアプリの状態なので作れないが、規則は識別子の等価判定だけで決まる。
    /// ここでは `Int` を識別子の代わりに渡して、同じ関数を検査する。
    private static func pasteTarget() -> Int32 {
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print(passed ? "  ok   \(label)" : "  FAIL \(label)")
            if !passed { failures += 1 }
        }
        /// 録音開始時（element / window）と貼り付け時（other...）の組を渡す。
        func matches(
            pid: pid_t = 100,
            element: Int? = nil,
            window: Int? = nil,
            otherPID: pid_t = 100,
            otherElement: Int? = nil,
            otherWindow: Int? = nil
        ) -> Bool {
            PasteTargetPolicy.matches(
                pid: pid,
                element: element,
                window: window,
                otherPID: otherPID,
                otherElement: otherElement,
                otherWindow: otherWindow
            )
        }

        check(
            !matches(element: 1, otherPID: 200, otherElement: 1),
            "別のアプリへ移ったら貼らない"
        )
        check(matches(element: 1, otherElement: 1), "同じフォーカス要素なら貼る")
        check(
            !matches(element: 1, otherElement: 2),
            "同じアプリでも別の入力欄へ移ったら貼らない"
        )
        // 片側だけ読めた場合。プロセスの一致だけを根拠にすると、同じアプリの
        // 別ウィンドウ・別入力欄へ文字を入れてしまう。
        check(
            !matches(element: 1, otherElement: nil, otherWindow: 9),
            "開始時に読めた要素が貼り付け時に読めなければ貼らない"
        )
        check(
            !matches(element: nil, window: 9, otherElement: 2),
            "開始時に読めなかった要素が貼り付け時に読めても貼らない"
        )
        // フォーカス要素をまったく出さないアプリ。ウィンドウで照合する。
        check(
            matches(element: nil, window: 9, otherElement: nil, otherWindow: 9),
            "要素を読めないアプリは同じウィンドウなら貼る"
        )
        check(
            !matches(element: nil, window: 9, otherElement: nil, otherWindow: 8),
            "要素を読めないアプリで別のウィンドウへ移ったら貼らない"
        )
        check(
            !matches(element: nil, window: nil, otherElement: nil, otherWindow: nil),
            "要素もウィンドウも読めなければ貼らない"
        )
        check(
            !matches(element: nil, window: 9, otherElement: nil, otherWindow: nil),
            "ウィンドウが片側しか読めなければ貼らない"
        )
        check(
            !matches(element: nil, window: 9, otherPID: 200, otherElement: nil, otherWindow: 9),
            "ウィンドウが同じに見えてもプロセスが違えば貼らない"
        )

        print(failures == 0 ? "貼り付け先の照合: 全件 ok" : "貼り付け先の照合: \(failures) 件 FAIL")
        return failures == 0 ? 0 : 1
    }

    // MARK: 終了処理の順番

    /// 終了は同期で確定させてから待つ（レビュー MUST 7）。印を立てる前に待つか
    /// どうかを決めると、そのあとに始まった貼り付けを取りこぼす。
    private static func shutdownGate() -> Int32 {
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print(passed ? "  ok   \(label)" : "  FAIL \(label)")
            if !passed { failures += 1 }
        }

        var gate = ShutdownGate()
        check(gate.allowsStart, "終了前は録音を始められる")
        check(!gate.waitsForPaste, "貼り付けていなければ worker をすぐ止められる")
        check(gate.beginPaste(), "終了前は貼り付けを予約できる")
        check(gate.waitsForPaste, "予約したら終了処理は復元を待つ")

        gate.beginShutdown()
        check(!gate.allowsStart, "終了が始まったら録音を始められない")
        check(gate.waitsForPaste, "終了の開始時に進んでいる貼り付けは待つ")
        check(!gate.beginPaste(), "終了が始まったら新しい貼り付けを予約できない")
        check(gate.waitsForPaste, "断った予約で待ちの対象は増えない")
        gate.endPaste()
        check(!gate.waitsForPaste, "復元が終われば待たない")
        check(!gate.allowsStart, "終了の印は戻らない")
        check(!gate.beginPaste(), "復元のあとも新しい貼り付けは始まらない")

        // 文字起こし中に終了した場合。worker を止める前に印を立てるので、
        // あとから届いた結果で貼り付けが始まることはない。
        var transcribing = ShutdownGate()
        transcribing.beginShutdown()
        check(!transcribing.waitsForPaste, "予約がなければ待たずに worker を止める")
        check(!transcribing.beginPaste(), "終了後に届いた結果は貼り付けへ進めない")
        check(!transcribing.waitsForPaste, "断ったので復元待ちも発生しない")

        print(failures == 0 ? "終了処理の順番: 全件 ok" : "終了処理の順番: \(failures) 件 FAIL")
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

        // 保存から消去までの間に外部のコピーが入る場合。消すとユーザーが意図して
        // コピーした内容を失うので、消す前に照合して中止する（レビュー SHOULD 11）。
        pasteboard.clearContents()
        pasteboard.setString("SELFTEST-BEFORE-CLEAR", forType: .string)
        let third = ClipboardSnapshot.capture(from: pasteboard)
        check(third.isCurrent(on: pasteboard), "保存した直後は消去してよい")
        pasteboard.clearContents()
        pasteboard.setString("EXTERNAL-COPY-WHILE-SAVING", forType: .string)
        check(!third.isCurrent(on: pasteboard), "保存のあとに変わっていれば消去しない")
        check(
            pasteboard.string(forType: .string) == "EXTERNAL-COPY-WHILE-SAVING",
            "中止したので新しい内容が残っている"
        )

        _ = entry.restore(to: pasteboard, ifChangeCountIs: pasteboard.changeCount)
        print(failures == 0 ? "クリップボード: 全件 ok" : "クリップボード: \(failures) 件 FAIL")
        return failures == 0 ? 0 : 1
    }

    // MARK: ステレオのミックスダウン

    /// 片側のチャンネルにだけ信号がある 48kHz ステレオ入力を変換する。
    /// `downmix` が無効だとチャンネルの配置替えになり、無音側を取る並びでは
    /// 音声が丸ごと落ちる（レビュー MUST 6）。
    private static func downmix() -> Int32 {
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print(passed ? "  ok   \(label)" : "  FAIL \(label)")
            if !passed { failures += 1 }
        }

        let sampleRate = 48000.0
        let frames = AVAudioFrameCount(sampleRate / 2) // 0.5 秒
        guard let stereo = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            print("  FAIL 48kHz ステレオの形式を作れない")
            return 1
        }

        for loud in 0 ... 1 {
            guard let input = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: frames),
                  let channels = input.floatChannelData
            else {
                print("  FAIL 入力バッファを作れない")
                return 1
            }
            input.frameLength = frames
            for frame in 0 ..< Int(frames) {
                let phase = 2.0 * Double.pi * 440.0 * Double(frame) / sampleRate
                channels[loud][frame] = Float(sin(phase) * 0.5)
                channels[1 - loud][frame] = 0
            }

            let side = loud == 0 ? "左" : "右"
            do {
                let resampler = try AudioResampler(inputFormat: stereo)
                var pcm = resampler.convert(input)
                pcm.append(resampler.flush())
                check(pcm.count > 0, "\(side)だけに信号がある入力を変換できる")
                let peak = peakAmplitude(of: pcm)
                print("  \(side)チャンネルのみ: \(pcm.count) バイト, 最大振幅 \(String(format: "%.3f", peak))")
                check(peak > 0.05, "\(side)だけの信号がミックスダウンで残る")
            } catch {
                print("  FAIL \(side)チャンネルの変換に失敗: \(error)")
                failures += 1
            }
        }

        print(failures == 0 ? "ミックスダウン: 全件 ok" : "ミックスダウン: \(failures) 件 FAIL")
        return failures == 0 ? 0 : 1
    }

    /// 16bit リトルエンディアンのモノラル PCM の最大振幅（0〜1）。
    private static func peakAmplitude(of pcm: Data) -> Double {
        var peak = 0
        var offset = pcm.startIndex
        while offset + 1 < pcm.endIndex {
            let low = UInt16(pcm[offset])
            let high = UInt16(pcm[offset + 1]) << 8
            let sample = Int(Int16(bitPattern: high | low))
            peak = max(peak, abs(sample))
            offset += 2
        }
        return Double(peak) / Double(Int16.max)
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
            // 本文は出さない。長さと成否だけで往復が成立したことは分かる（設計書 14）。
            print("  transcribe: \(String(format: "%.2f", elapsed)) 秒, stop=\(transcript.stop)")
            print("  text: \(transcript.text.count) 文字")
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
