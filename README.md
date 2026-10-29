# MacTrans

MacTrans は、macOS 専用の準リアルタイム翻訳アプリです。メニューバーに常駐し、マイクまたはシステム音声を `whisper.cpp` でローカル文字起こししてから、LM Studio の OpenAI 互換 API へ翻訳を依頼します。原文と翻訳文は画面右下のオーバーレイに並べて表示されます。

## 主な機能

- メニューバー常駐アプリとして起動
- マイク音声を `AVAudioEngine` で録音
- システム音声を `ScreenCaptureKit` で直接取得（追加の仮想オーディオデバイスは不要）
- `whisper.cpp` をアプリ内ブリッジ経由で呼び出してローカル文字起こし
- LM Studio の OpenAI 互換 Chat Completions API で翻訳
- 原文と翻訳文を右下のフローティングオーバーレイに表示
- オーバーレイから録音開始/停止、オートスクロール切り替え
- セッション中の原文/翻訳文を一時ファイルへ保存
- `Save Transcript...` でテキストファイルとして書き出し
- LM Studio API token は Keychain に保存
- Gemini TTS で翻訳結果を順番に読み上げ（任意）

## 必要環境

- macOS 14+
- Xcode Command Line Tools
- Keychainに登録済みのApple Development署名証明書（録音権限をビルド間で保持するため）
- ビルド済みの `whisper.cpp`（ストリーミングVAD APIに対応した v1.8.6 で検証）
- `whisper.cpp` 用の GGML モデルファイル
- LM Studio のローカルサーバー

現在の `Package.swift` は、リポジトリの兄弟ディレクトリにある `../whisper.cpp` を前提にリンクしています。

- `../whisper.cpp/include/whisper.h`
- `../whisper.cpp/build/src/libwhisper.dylib`
- `../whisper.cpp/build/ggml/src/*.dylib`

別の場所に `whisper.cpp` を置く場合は、`WHISPER_CPP_DIR` に絶対パスを指定してください。Swift Package と実行スクリプトの両方に反映されます。

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

ビルド時には同梱dylib・リソース・アプリ本体をApple Development証明書で署名し、署名検証後に `dist/MacTrans.app` を更新します。証明書が1つだけなら自動選択します。複数ある場合や別の署名証明書を使う場合は `MACTRANS_SIGNING_IDENTITY` に証明書名またはSHA-1を指定してください。証明書が見つからない場合は停止し、アドホック署名への切り替えは行いません。

以前のビルドは実行ファイルのアドホック署名をそのまま使っていたため、更新ごとにmacOSが照合する署名要件が変わっていました。証明書署名への切り替え後、録音権限がオンなのに許可を求められる場合は、一度MacTransを終了し、「画面収録とシステムオーディオ録音」のMacTransをオフ→オンにしてから `dist/MacTrans.app` を開き直してください。改善しない場合は古いMacTransの項目を削除し、現在のアプリを追加して許可します。これは署名の切り替え時の再登録で、ビルドごとの操作ではありません。権限の保持には今後も同じ開発チームとBundle IDを使います。[Appleの説明](https://developer.apple.com/forums/thread/819406)

オン／オフでも古い署名の照合情報が残る場合は、MacTransを終了して `tccutil reset ScreenCapture dev.local.MacTrans` を実行し、現在のアプリを開き直してmacOS画面で許可し直します。このコマンドはMacTransの画面収録許可だけをリセットし、自動で許可を付与するものではありません。通常のビルドでは実行しません。

## 初期設定

メニューバーの MacTrans アイコンから `Settings...` を開きます。

### Audio Input

- `Microphone`: 従来どおりマイク音声を取得します。初期値です。
- `System Audio`: ブラウザや会議アプリなど、他のアプリが再生する音声を直接取得します。マイク音声は含みません。

メニューバーの `Audio Input` からも選択できます。録音を停止し、末尾の文字起こしが完了してから切り替えてください。選択した入力元は次回起動時も保持されます。同時ミックスやアプリ単位の選択には対応していません。

`System Audio` の初回開始時にはmacOSの録音権限が必要です。「システム設定 → プライバシーとセキュリティ → 画面収録とシステムオーディオ録音」でMacTransを許可してください（macOSのバージョンにより「画面収録」などの表示になります）。macOSに再起動を求められた場合はMacTransを起動し直してください。システム音声の取得にはマイク権限は使いません。

macOS 14対応のためディスプレイを指定したScreenCaptureKitストリームを使いますが、アプリが受け取るのは音声バッファだけで、画面映像の保存は行いません。接続されたディスプレイが必要です。MacTrans自身の再生音声は除外し、他のアプリの通知音などは入力に含まれます。保護されたコンテンツなど、macOSや再生アプリがキャプチャを制限する音声は取得できない場合があります。

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

### Gemini Text-to-Speech

Settings の `Gemini Text-to-Speech` で設定します。

- `API key`: CLIで使っているGemini APIキー。macOS Keychainに保存します。以前の画面で入力したキーはそのまま引き継ぎます。
- `Model`: 初期値はCLIと同じ `gemini-3.8-flash-tts`。自由入力です。
- `Voice ID / name`: 保存済みの `voice_...` ID、または `Kore` などの音声名。以前に入力した音声IDを引き継ぎます。空欄はエラーになります。
- `Test text` / `Test Speech`: 任意の短い文章でAPI接続と再生を確認します。自動読み上げがオフでも使えます。
- `Speak translations`: オンにした後に確定した発話の翻訳結果を自動で読み上げます。初期値はオフです。

言語は翻訳テキストから判定されるため、TTS用の言語コード指定はありません。翻訳先を変更してもモデルと音声は自動変更しません。モデル・音声・言語の対応は利用者が選び、アプリでは組み合わせを制限しません。

翻訳テキストをGemini APIへ送信し、APIの利用料金が発生する場合があります。音声ファイルはメモリ上で再生し、ディスクには保存しません。接続先は [Gemini TTSのInteractions API](https://ai.google.dev/gemini-api/docs/speech-generation) (`https://generativelanguage.googleapis.com/v1beta/interactions`) に固定しています。CLIと同じリクエスト形式で `store: false`、`stream: false`、WAV出力を指定します。Cloud Text-to-Speechの `text:synthesize` APIとは異なります。

メニューバーで自動読み上げのオン／オフを切り替えられます。`Stop Speech`、またはオーバーレイのスピーカー停止アイコンで、再生と待機中の読み上げを止めます。その時点で翻訳処理中だった文章も読み上げません。自動読み上げがオンなら、それ以降に確定する新しい発話から再開します。`Clear Transcript` でも読み上げを停止します。録音の停止時は末尾の翻訳・読み上げを続けます。

読み上げは翻訳処理と別のキューで順番に実行します。再生中にも次の最大2件を先読み生成し、APIの応答順が前後しても翻訳順に再生します。先読み枠は生成中と生成済みを合わせて2件、同時APIリクエストも最大2件です。長い翻訳はアプリ側でUTF-8の5,000バイトごとに分割し、その分割単位で先読みします。この値はGemini APIの上限を表すものではありません。

翻訳の待機キューは再生中を含め最大20件まで保持し、上限を超えた新しい翻訳は読み上げを省略してメニューバーと設定画面に通知します。先読みのAPIエラーは現在の文章を読み終えてから、その項目の順番で通知し、残りをクリアします。再生エラー時もキューをクリアします。翻訳表示は続けます。停止時には先読みリクエストもキャンセルしますが、送信済みの生成処理や利用料金まで取り消せるとは限りません。

設定の `Speech timings (last 20 chunks)` に直近20件の計測値を表示します。停止しても履歴は残り、アプリ終了時に消えます。

- `Generation`: API呼び出し開始から音声データ取得・デコード完了まで。
- `Ready wait`: 生成完了から再生処理を呼び出すまで。先読みで用意できた音声が前の再生を待った時間で、大きくても文章間の無音が長いという意味ではありません。
- `Total wait`: 翻訳を読み上げキューに追加してから再生処理を呼び出すまで。生成開始前のキュー待ちも含みます。
- `Gap`: 前の再生処理が終了してから次の再生処理を呼び出すまで。次の翻訳が届くまでの時間も含み、初回・停止直後の最初の再生は `—` です。生成音声の先頭・末尾に含まれる無音や、オーディオデバイスの出力遅延は計測対象外です。

同じ計測値と生成開始前のキュー待ち時間をmacOSのログ（subsystem: `dev.local.MacTrans`、category: `Speech`）にも記録します。テキスト・音声・APIキーはログへ記録しません。アプリを再ビルドせずにログだけ見るには、以下を実行します。

```bash
log stream --level info --style compact --predicate 'subsystem == "dev.local.MacTrans" AND category == "Speech"'
```

System Audio入力ではMacTrans自身の再生音声をキャプチャ対象から除外します。Microphone入力ではスピーカーからの読み上げをマイクが拾うため、ヘッドホンを使ってください。

### Chunking

文字起こし結果をどのタイミングで翻訳へ送るかを調整します。

- `Fast`: 約0.45秒の無音で発話を区切り、発話中は2回の認識の一致を確認
- `Balanced`: 標準設定。約0.7秒の無音と、2回の認識の一致を確認
- `Stable`: 約1秒の無音と、3回の認識の一致を確認。翻訳は遅め

無音の長さに加えて、認識と翻訳の処理時間がかかります。途中結果は書き換わりますが、確定済みの音声に対応する文章を再表示・再翻訳しません。

追加調整:

- `Stable phrase delay`: 話し続けている場合に、十分な長さの安定した部分を確定するまでの音声上の時間。以前の `Timeout` の保存値を引き継ぎます。時間切れだけで不安定な末尾を確定しません。
- `Max characters`: 安定した部分が長くなったとき、単語の境界で区切る目安

発話検出には同梱の Silero VAD v6.2.0（約864 KiB）を使います。設定済みのWhisperモデルは変更せず、録音中のネットワークダウンロードもありません。

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
- システム音声は48 kHz・ステレオで要求し、実際のサンプルレートを保ったままモノラル化して、マイクと共通の文字起こし処理へ渡します。
- 翻訳リクエストは順序が崩れないように直列化しています。
- `reasoning_effort: "none"` と `reasoning_tokens: 0` を送れるため、LM Studio 側の thinking を抑制できます。
- 音声は状態を保持する `AVAudioConverter` で16 kHzへ変換し、Silero VADを512サンプル（32 ms）単位で処理します。発話開始前の200 msも保持します。
- Whisperの単語タイムスタンプをセッション内のサンプル位置に変換し、確定済みの音声範囲を管理します。実際に後の時刻に話した同じ文は残します。
- 発話中は約1.5秒分の新しい音声ごとに再認識し、複数回一致した先頭部分を文末・長いフレーズの単語境界で確定します。VADによる発話終了と録音停止では、末尾も認識して確定します。
- 長い発話では確定済みの音声だけをバッファから外します。24秒に達した場合は認識済みの単語境界で進め、最後の約800 msを次回へ残します。この上限処理では通常より確定を優先します。
- 録音バッファは1つのストリームで順番に処理し、停止時にはキューと変換器に残った音声も処理します。処理待ちが256バッファを超える場合は、音声を黙って捨てずにエラーを表示して停止します。
- non-speech token抑制も有効にしています。

## 既知の注意点

- 現在検出されている `whisper.cpp` の dylib は macOS 26 ターゲットでビルドされています。アプリの最小対応は macOS 14 なので、古い macOS へ配布する場合は `whisper.cpp` を macOS 14 deployment target でビルドし直してください。
- VADとWhisperのタイムスタンプは推定です。小さい声、BGM、長い文中の間などによる誤認識・不自然な区切りを完全には防げません。
- 発話が短すぎる場合やVADが発話として検出できない場合は表示されないことがあります。発話判定の最小長は約160 msです。

## テスト

```bash
swift test
```

確定部分の再表示、認識の修正、タイムスタンプの揺れ、実際の繰り返し発話、無音、短い間、長い発話、44.1/48 kHzからの連続変換、システム音声のステレオ/モノラル変換を検証します。自動テストはmacOSの録音権限や実際の他アプリの再生音声の取得を検証するものではありません。

TTSのテストではHTTPレスポンスと再生処理を差し替え、リクエスト形式、UTF-8の分割、エラー処理、再生順序、停止後の遅延レスポンス破棄、キュー上限を確認します。実APIの認証・課金・音声の聞こえ方は `Test Speech` で別途確認します。保存済みのMacTrans設定を使って実APIから再生可能なWAVを取得するテストは `MACTRANS_TEST_GEMINI_TTS=1 swift test --filter GeminiTTSIntegrationTests` で実行できます（短いテスト文1件を送信し、通常のAPI利用料金が適用されます）。

現在のモデルを使った録音済み英語音声のテストも実行できます。マイクやLM Studioは使いません。`jfk.wav` を2回入力し、それぞれが一度ずつ確定することと停止時の末尾処理を確認します。

```bash
MACTRANS_TEST_MODEL=/path/to/ggml-large-v3-turbo.bin \
MACTRANS_TEST_AUDIO=/path/to/whisper.cpp/samples/jfk.wav \
swift test --filter WhisperIntegrationTests
```

## ライセンス

このリポジトリのコードは MIT License です。`whisper.cpp` は同梱しておらず、別途ローカルでビルド済みのものへリンクします。`whisper.cpp` 本体も MIT License です。

同梱のSilero VADモデルはMIT Licenseです。配布元・SHA-256・著作権表示は `Sources/MacTrans/Resources/` に含めています。
