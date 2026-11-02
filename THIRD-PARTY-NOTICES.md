# 第三者のソフトウェアとモデルについて

HinoVoice for Mac（`hinovoice-mac`）自体のライセンスは [LICENSE](LICENSE)（MIT）である。
このファイルは、参考にした実装と、実行時に必要な依存の出所をまとめたものである。

ライセンスの確認日はいずれも 2026-11-02 である。確認した URL をそれぞれに書いた。

## 1. OpenHinoVoice（設計と操作体系の参考元）

- 名前: OpenHinoVoice
- URL: <https://github.com/iiinno/OpenHinoVoice>
- 著作権者: iiinno
- ライセンス: MIT License（確認した commit: `f253e30f2fc23447bd976c744129303a33828418`、2026-11-01）
- このアプリとの関係: Windows 専用の Rust 実装である。状態の切り分け方と、クリップボードを
  戻すまでのタイミングに関する判断を参考にした。Windows API に依存する部分（低レベル
  キーボードフック、`SendInput`、OLE クリップボード）は移植ではなく macOS の作法で
  書き直しているため、コードの複製は含まない。それでも出所を明示するために全文を載せる。

```
MIT License

Copyright (c) 2026 iiinno

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 2. 実行時の依存: speech.cpp

- 名前: speech.cpp（`speech` 実行ファイルと `libspeech.dylib`）
- URL: <https://github.com/nyosegawa/speech.cpp>
- ライセンス: MIT License、Copyright (c) 2026 Sakasegawa
  （確認元: <https://raw.githubusercontent.com/nyosegawa/speech.cpp/main/LICENSE> と
  <https://api.github.com/repos/nyosegawa/speech.cpp>、いずれも 2026-11-02 に確認）
- このアプリで使っている版: 0.10.0（`speech worker` の protocol 4）
- 同梱していない。利用者が別途インストールした `~/.local/bin/speech` を子プロセスとして
  起動する。配布物に含まれないので、ライセンス全文を添付する義務は生じない。
- speech.cpp 自身の表示（README の License 節、2026-11-02 に確認）: 本体は MIT で、
  モデルの重みはそれぞれの作者のものである。このアプリが使う Haas-ja-v1.0 については次節に書く。
- speech.cpp は ggml を vendor している。同梱して配布する設計に変えるなら、ggml とその
  依存の表示を確認する必要がある。

## 3. 実行時の依存: 文字起こしモデル Haas-ja-v1.0

- モデル名: Haas-ja-v1.0（organization: third-intelligence、architecture: fastconformer、616M、
  `sample_rate` 16000、対応言語 `ja`）
- ライセンス: Apache License 2.0
- 元の配布元: <https://huggingface.co/third-intelligence/Haas-ja-v1.0>
  - revision: `660728d39019e5e065046154beca44ac9a66a540`
    （`speech worker` の `ready` が報告した値と、Hugging Face API が返す現在の `sha` が一致した）
  - `cardData.license` は `apache-2.0`（<https://huggingface.co/api/models/third-intelligence/Haas-ja-v1.0>、
    2026-11-02 に確認）
- GGUF 変換版（実際に取得されるのはこちら）: <https://huggingface.co/sakasegawa/Haas-ja-v1.0-GGUF>
  - `cardData.license` は `apache-2.0`、`base_model` は `third-intelligence/Haas-ja-v1.0`
    （<https://huggingface.co/api/models/sakasegawa/Haas-ja-v1.0-GGUF>、2026-11-02 に確認）
  - このアプリが使うのは `Haas-616M-ja-v1.0-Q8_0.gguf`（worker が `weight_type` を `Q8_0` と報告した）
- 同梱していない。`speech` が初回に取得する。
- Apache-2.0 は、配布物に NOTICE ファイルが含まれている場合その内容を伝えることを求める。
  2026-11-02 時点でどちらのリポジトリにも NOTICE ファイルは無い（ファイル一覧で確認）。
  モデルを同梱する設計に変えるなら、両方の配布元を改めて確認する必要がある。
