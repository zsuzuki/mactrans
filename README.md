# MacTrans

MacTrans は、macOS 専用の準リアルタイム翻訳アプリです。メニューバーに常駐し、マイク音声を `whisper.cpp` でローカル文字起こししてから、LM Studio の OpenAI 互換 API へ翻訳を依頼します。原文と翻訳文は画面右下のオーバーレイに並べて表示されます。

## 主な機能

- メニューバー常駐アプリとして起動
- マイク音声を `AVAudioEngine` で録音
- `whisper.cpp` をアプリ内ブリッジ経由で呼び出してローカル文字起こし
- LM Studio の OpenAI 互換 Chat Completions API で翻訳
- 原文と翻訳文を右下のフローティングオーバーレイに表示
- オーバーレイから録音開始/停止、オートスクロール切り替え
- セッション中の原文/翻訳文を一時ファイルへ保存
- `Save Transcript...` でテキストファイルとして書き出し
- LM Studio API token は Keychain に保存

## 必要環境

- macOS 14+
- Xcode Command Line Tools
- ビルド済みの `whisper.cpp`
- `whisper.cpp` 用の GGML モデルファイル
- LM Studio のローカルサーバー

現在の `Package.swift` は、リポジトリの兄弟ディレクトリにある `../whisper.cpp` を前提にリンクしています。

- `../whisper.cpp/include/whisper.h`
- `../whisper.cpp/build/src/libwhisper.dylib`
- `../whisper.cpp/build/ggml/src/*.dylib`

別の場所に `whisper.cpp` を置く場合は、`Package.swift` の `unsafeFlags` を変更してください。実行スクリプト側は `WHISPER_CPP_DIR` で上書きできます。

```bash
WHISPER_CPP_DIR=/path/to/whisper.cpp ./script/build_and_run.sh
```

## 実行方法

```bash
./script/build_and_run.sh
```

確認用のモード:

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
```

`--verify` はアプリをビルドして `.app` バンドルへ配置し、プロセスが起動するところまで確認します。

## 初期設定

メニューバーの MacTrans アイコンから `Settings...` を開きます。

### Languages

- `Source language`: 文字起こし対象の言語。初期値は `English`
- `Target language`: 翻訳先の言語。初期値は `Japanese`

### LM Studio

- `Chat completions URL`: 初期値は `http://127.0.0.1:1234/v1/chat/completions`
- `Model`: 初期値は `google/gemma-4-26b-a4b-qat`
- `API token`: LM Studio 側で API token を有効にしている場合に入力
- `Thinking`: 翻訳用途では `Off` 推奨

`API token` は macOS Keychain に保存されます。以前のバージョンで `UserDefaults` に保存されていた token は、起動時に Keychain へ移行して削除されます。

### whisper.cpp

- `Model path`: `ggml-large-v3-turbo.bin` などの `whisper.cpp` モデルファイルを指定

メニューバーにも `Choose Whisper Model...` があり、設定画面を開かずにモデルを選べます。

### Chunking

文字起こし結果をどのタイミングで翻訳へ送るかを調整します。

- `Fast`: 反応優先。断片や重複は増えやすい
- `Balanced`: 標準設定。追従性と読みやすさのバランス
- `Stable`: 重複や未完フレーズを減らす。翻訳は遅め

追加調整:

- `Timeout`: 文末が出ない場合に現在の推定を確定するまでの時間
- `Max characters`: 長くなりすぎた推定を確定する文字数

## オーバーレイ操作

録音開始後、画面右下にオーバーレイが表示されます。

- 原文の下に翻訳文を表示
- 翻訳待ちの行は `...` 表示
- 右上の録音ボタンで録音開始/停止を切り替え
- 右上の下向きアイコンでオートスクロールを切り替え
- ユーザーが途中へスクロールするとオートスクロールは停止
- 最下端付近まで戻すとオートスクロールは再開

## 実装メモ

- `whisper.cpp` は C ブリッジ `WhisperBridge` 経由で呼び出します。
- 現在はマイク入力のみ対応しています。システム音声キャプチャは未対応です。
- 翻訳リクエストは順序が崩れないように直列化しています。
- `reasoning_effort: "none"` と `reasoning_tokens: 0` を送れるため、LM Studio 側の thinking を抑制できます。
- `whisper.cpp` の non-speech token 抑制は外しており、BGM 区間で `*music*` などが出る可能性があります。

## 既知の注意点

- 現在検出されている `whisper.cpp` の dylib は macOS 26 ターゲットでビルドされています。アプリの最小対応は macOS 14 なので、古い macOS へ配布する場合は `whisper.cpp` を macOS 14 deployment target でビルドし直してください。
- 準リアルタイム翻訳のため、`whisper.cpp` のローリング推定結果に由来する断片や重複が残る場合があります。
- BGM や無音区間では `so` や `Yeah` のような短い誤認識が発生することがあります。同じ短い語の連続は軽く抑制していますが、通常会話への影響を避けるため強い除去はしていません。

## ライセンス

このリポジトリのコードは MIT License です。`whisper.cpp` は同梱しておらず、別途ローカルでビルド済みのものへリンクします。`whisper.cpp` 本体も MIT License です。
