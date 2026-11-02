# HinoVoice for Mac

いま文字を打っている場所から手を離さずに、キーを1回押して話し、Enter を押すと、その場に
文字が入る。ウィンドウを切り替えることも、結果をコピーして貼り直すことも、クリップボードの
中身が消えることもない。

文字起こしは [speech.cpp](https://github.com/nyosegawa/speech.cpp) の `speech worker` に
[Haas-ja-v1.0](https://huggingface.co/third-intelligence/Haas-ja-v1.0) を常駐させて行う。
音声はこの Mac の中だけで処理し、外部には送らない。

## 元になったアプリ

Windows 専用の [OpenHinoVoice](https://github.com/iiinno/OpenHinoVoice)（作者: iiinno、MIT）を
参考にした **Mac 版** である。**同じ作者のものではなく、公式の移植でもない。** 状態の分け方と
クリップボードを戻すタイミングの判断を参考にしているが、キーイベントの横取りと貼り付けは
macOS の API（CGEventTap、CGEventPost、NSPasteboard）で書き直してある。
出所の詳細は [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) にある。

## 使い方

1. メニューバーのアイコンが「待機中」になっていることを確かめる。
2. 文字を入れたい入力欄にカーソルを置く。
3. **⌃⌥Space（Control + Option + Space）** を押す。アイコンが録音中に変わる。
4. 話す。
5. **Enter** を押す。1秒ほどで入力欄に文字が入る。
6. やめるときは **Esc** を押す。何も貼られない。

録音中・文字起こし中・貼り付け中の Enter と Esc は、他のアプリに渡さない。Slack の投稿欄で
使っても、話し終わりの Enter でメッセージが送信されることはない。待機中の Enter と Esc は
そのまま通る。

録音は60秒で自動的に止まり、そのまま文字起こしへ進む。モデルは1回の発話を想定しているので、
長く話すと精度が落ちる。

録音開始キーを ⌃⌥Space にした理由（F8 を使わない理由を含む）は設計の判断として決めてある。
変えたいときは `Sources/HinoVoice/AppConfiguration.swift` の `startKeyCode` と
`startKeyModifiers` の2行を変える。

## 必要なもの

- Apple Silicon の Mac、macOS 14 以降
- `speech`（speech.cpp 0.10.0 以降、`speech worker` の protocol 4）。
  `~/.local/bin/speech`、`/opt/homebrew/bin/speech`、`/usr/local/bin/speech` の順に探す。
- Xcode のコマンドラインツール（Swift 6）と Apple Development 証明書1件

初回は `speech` がモデル（約 656MB）を取得する。先に `~/.local/bin/speech worker haas-ja-v1.0`
を手で起動して `ready` が出ることを確かめておくと、切り分けが楽になる。

## 許可

| 許可 | 何に使うか | 出るタイミング |
|---|---|---|
| マイク | 録音 | 最初に ⌃⌥Space を押したとき |
| アクセシビリティ | キーの横取りと Cmd+V の送出 | 起動時（メニューの項目からも開ける） |
| 入力監視 | 環境によって追加で必要になることがある | タップを作れなかったとき |

アクセシビリティを許可したあとはアプリを再起動する。タップを作れなかった場合は、メニューに
「アクセシビリティを許可する」と「入力監視の設定を開く」が出る。

### 許可が外れたとき

署名の同一性（designated requirement）を Team ID で固定しているので、再ビルドしても許可は
維持される**設計**である。ただし再ビルドしたあとに許可が残っていることは、まだ実機で
確かめていない。外れた場合は、システム設定の「プライバシーとセキュリティ」から
「アクセシビリティ」を開き、HinoVoice の項目を**削除**して、アプリを再起動してから許可し直す。
古い項目が残っていると、追加しても効かないことがある。

## ビルドとインストール

```sh
make install   # build → bundle → sign → ~/Applications/HinoVoice.app へ
make verify    # 署名と DR を表示し、Team ID で固定されていることを確認する
make selftest  # 人の操作を必要としない確認
```

`make selftest` はキー判定、セッションの世代、クリップボードの保存と復元、16kHz 変換、
ステレオのミックスダウン、worker との往復を確認する。文字起こしの本文は出さない。

Apple Development 証明書が複数ある環境では、どれで署名するかを指定する。

```sh
make install SIGN_ID='<証明書の名前>'
```

`make verify` は `codesign --verify --strict` と、埋め込まれた designated requirement が
期待する文字列と一致することを確認する。一致しなければ失敗する。

Hardened Runtime、App Sandbox、`get-task-allow` はいずれも使っていない。公証はしていないので、
他人に配る用途には向かない。デバッグはログで行う。

```sh
log stream --predicate 'subsystem == "com.xxarupakaxx.hinovoice-mac"' --level debug
```

文字起こしの本文、クリップボードの内容、音声データ、マイクのデバイス名はログに出さない。
worker の stderr の中身もログへ渡さない（記録するのは長さだけである）。そのため、worker が
出すエラーの文面を見たいときは `speech worker` を端末から直接動かす。

## 分かっている制約

- **クリップボードの完全な復元はできない場合がある。** ファイルプロミス（Finder でファイルを
  コピーした直後など、「あとで要求されたら渡す」形の内容）は複製できないので、復元は複製できた
  分だけになる。テキストや画像を入れている通常の場合は戻る。
- 貼り付けを待つ時間は 400 ミリ秒の固定値である。Electron のアプリでクリップボードの読み取りが
  遅く、古い内容が貼られる場合は `AppConfiguration.clipboardRestoreDelaySeconds` を伸ばす。
- クリップボードを見ている区間は2つある。保存してから自分のテキストを置くまでの間に他の
  アプリかユーザーがコピーしていた場合は、その内容を消さないために貼り付け自体を中止する。
  自分のテキストを置いてから復元するまでの間に書き換えられた場合は、復元しない。
  どちらも「貼り付け直前の変更」ではなく、この2つの区間の変更を見ている。
- 入力先は、最前面のアプリとアクセシビリティから取れるフォーカス要素で照合する。録音開始時と
  貼り付け時で変わっていた場合は、別の場所へ文字を入れないために貼り付けを中止する。照合は
  修飾キーを待ったあとと Cmd+V を送る直前にも行う。そのとき文字起こしの結果は残らないので、
  もう一度話す必要がある。フォーカス要素を取れないアプリでは、アプリ単位の照合に落ちる。
- **フォーカス要素での照合は実機で未確認である。** 同じ入力欄でも問い合わせごとに別の要素を
  返すアプリがあると、変わっていないのに貼り付けを中止する可能性がある。そうなった場合は
  `TextInserter.swift` の `PasteTarget.matches` を、プロセスの一致だけを見る形へ戻す。
- AI による整形、設定画面、履歴、録音中の画面表示は入っていない。
- 公証していないので、他人に配る用途には向かない。他の Mac での動作は確認していない。

## ライセンス

MIT。[LICENSE](LICENSE) を参照。第三者のソフトウェアとモデルについては
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) を参照。
