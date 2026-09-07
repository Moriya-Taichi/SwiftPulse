# SwiftPulse

SwiftNIOに依存しないSwiftの非同期HTTPサーバー、定レート負荷テストCLI、並列性を調べる専用Web UIです。

`pulse serve`でサーバーを起動し、`pulse attack`で負荷をかけ、`pulse studio`で結果とサーバーの実行区間を照合できます。負荷テストCLIは、SwiftPulse以外のHTTP/HTTPSサーバーにも使えます。

**初期実装です。** ノンブロッキングI/O、同時実行数と記録量の上限、負荷生成側の飽和の記録を備えています。既存フレームワークより高速であることを保証するものではありません。

## 必要環境

- Swift 6.0以降
- LinuxまたはmacOS 15以降
- Studioの表示には最近のブラウザ
- npmパッケージ・外部Swiftパッケージへの依存はありません

## はじめる

```sh
git clone https://github.com/Moriya-Taichi/SwiftPulse.git
cd SwiftPulse
swift build -c release

# ターミナル1：計測用サーバー
.build/release/pulse serve --port 8080 --workers 4

# ターミナル2：専用UI
.build/release/pulse studio --port 9090
```

[http://127.0.0.1:9090](http://127.0.0.1:9090)を開き、レート・期間・同時実行上限を指定して「テスト開始」を押してください。UIから停止でき、結果は`runs/`にJSONで保存されます。

Studioを使わず、CLIだけでも実行できます。

```sh
.build/release/pulse attack \
  --url 'http://127.0.0.1:8080/work?delay=20&fanout=2&iterations=10000' \
  --rate 100 --duration 10s --concurrency 128 --timeout 5s \
  --trace-url http://127.0.0.1:8080/__pulse/trace \
  --output runs/example.json

.build/release/pulse report --input runs/example.json
```

Studioの「読み込む」でこのJSONを開けます。「比較」で別の結果を読み込むとP99の差分が表示されます。

## 負荷テストCLI

レスポンスの完了と独立して、一定間隔で発行枠を作るopen-loop方式です。処理が遅くなっても、黙ってレートを下げたり、無制限にTaskを積んだりしません。

| オプション | 既定値 | 内容 |
|---|---:|---|
| `--url` | `http://127.0.0.1:8080/` | HTTP/HTTPSターゲット |
| `--rate` | 100 | 毎秒の発行枠数 |
| `--duration` | 10s | 発行期間。数値、`ms`、`s`、`m` |
| `--concurrency` | 128 | 発行中のリクエスト数の上限 |
| `--timeout` | 5s | リクエストのタイムアウト |
| `--method` | GET | HTTPメソッド |
| `--header` | なし | `Name: value`。繰り返し指定可能 |
| `--body` | なし | リクエストBodyを読み込むファイル |
| `--max-lag-ms` | 100 | 発行枠を捨てるスケジューラ遅延の閾値。単位はms |
| `--max-samples` | 20000 | 個別リクエストを保存する上限 |
| `--max-response-bytes` | 16777216 | 1レスポンスの受信量上限 |
| `--trace-url` | なし | 実行後に取得するSwiftPulseのトレースURL |
| `--output` | `runs/<id>.json` | 集計・サンプル・トレースの出力先 |

レスポンスBodyは集計用にバイト数だけ数え、蓄積しません。リダイレクトは追跡せず、返されたステータスを記録します。200〜399を成功、それ以外と通信エラーを失敗に数えます。

上限による未発行（`droppedCapacity`）と、スケジューラの遅れによる未発行（`droppedLate`）は別々に記録します。終了後は発行済みリクエストの完了を待ちます。Ctrl-Cではキャンセルし、途中結果を保存します。

### 指標の意味

- **レイテンシ**：リクエストTaskが発行を開始してから、Bodyの受信完了またはエラーまで。URLSession内部の接続待ち・DNS・TLSも含みます。ネットワーク上の送信開始時刻ではありません。
- **スケジューラ遅延**：予定した発行時刻からリクエストTaskの開始まで。
- **予定時刻→完了**：スケジューラ遅延を含む時間。
- **実発行レート**：開始したリクエスト数÷発行期間。完了レートとは異なります。
- 分位点は全完了リクエストを固定容量の対数ヒストグラムで集計します。1μs以上で上側境界による最大約2%の量子化誤差があります。最大値と平均は実測値です。
- 個別サンプルは保存上限までの先着完了分です。ランダムサンプルではありません。集計はサンプル上限に影響されません。
- **未発行分はレイテンシ分布に含まれません。** 未発行がある結果を、目標レートを達成した結果として比較しないでください。ヒストグラムのcoordinated omission補正を自動的に行う実装ではありません。

## 専用UI

- 実行・停止、最近20件の履歴、JSONの読み込み・出力
- 予定発行数・開始数・完了数と最大レイテンシの時系列
- サーバーのワーカー別ジョブ区間、リクエスト別Handler・送信区間
- タイムラインの拡大・移動、リクエストを選択した絞り込み
- ステータス・通信エラー・遅延の内訳、別実行とのP99比較

負荷生成はブラウザではなく`pulse studio`のSwiftプロセスで行います。負荷生成側とサーバーを別ホストで動かす場合、`pulse attack`を負荷生成ホストで実行し、そのJSONをStudioへ取り込めます。`X-Pulse-Request-ID`で照合するため、別ホスト間の時刻同期を前提にしません。

### 並列性の読み方

`WorkerPool`は複数の直列DispatchQueueでジョブを実行します。`RequestExecutor`がrequest IDを持ち、Swiftの公開`TaskExecutor` APIで管理下のジョブを記録します。レーンは論理ワーカーであり、固定されたOSスレッドではありません。各区間には実行したOS thread IDも付けています。

**executorのジョブ区間は実行開始から戻るまでの経過時間であり、CPU稼働率ではありません。** OSのプリエンプションや、ユーザーコードによるブロッキングを含み得ます。Handlerとソケット操作の区間には`await`中の待ち時間も含みます。独自executorを持つactor、外部ライブラリの内部Task、OSのスケジューリングは捕捉しません。

トレースは有効時のみ固定上限まで記録し、それ以降は欠落件数を数えます。長時間の計測には`--trace-capacity`を調整してください。`--trace-capacity 0`で記録を無効にできます。`/__pulse/trace`はChrome Trace Event形式の`traceEvents`を含み、Perfettoでも読み込めます。

## ライブラリとして使う

```swift
import PulseCore

let server = try HTTPServer(port: 8080, workers: 4) { request in
    switch request.path {
    case "/health": return .text("OK")
    default: return .text("Not found", status: 404)
    }
}
try await server.run()
```

`AsyncSocket`は非ブロッキングソケットをDispatchSourceとchecked continuationで接続します。同時に1つのread（またはaccept）と1つのwriteを許可し、writeは実際に送信バッファへ渡せるまで待機します。操作のキャンセルは接続全体を閉じます。ファイルディスクリプタは両方のDispatchSourceのキャンセル完了後に解放します。

サーバーは接続数、ヘッダー、Body、読み書きの待機時間に上限を設けています。`stop()`は新規acceptを停止し、接続処理を待ちます。実行Taskのキャンセルは接続処理もキャンセルします。キャンセルに協調しないユーザーコードを強制中断する機能はありません。

## 現在の範囲

| 実装済み | 未実装 |
|---|---|
| IPv4の非同期TCP、HTTP/1.1、keep-alive、Content-Length | IPv6のサーバーバインド、サーバーTLS、HTTP/2・HTTP/3・WebSocket |
| Body上限、曖昧なフレーミングの拒否、部分受信・部分送信 | chunked request、Expect: 100-continue、汎用BodyストリーミングAPI |
| 定レート負荷、HTTPSクライアント、レスポンスBody破棄 | ランプレート、分散エージェント、Vegetaのバイナリ形式との互換 |
| 専用UI、管理下executorのトレース | OSのCPUスケジューラトレース、全Swift Taskの自動捕捉 |

HTTP実装は意図的に狭い範囲を厳密に扱います。重複ヘッダー、Transfer-Encoding、Expect、不正なContent-Lengthは拒否し、曖昧な接続を再利用しません。リクエストBodyは上限内で蓄積し、レスポンスは64 KiBずつ送信します。ゼロコピー実装ではありません。

## 検証

```sh
swift test
node --test Tests/StudioTests/*.test.mjs
swift build -c release
python3 scripts/integration.py --binary .build/release/pulse
```

SwiftテストはHTTPフレーミング、部分I/O、キャンセル、ヒストグラム、負荷生成の飽和を確認します。統合テストはCLI、サーバー、Studio API、結果の整合性を確認します。UIの操作テストは`node scripts/browser-test.mjs`で実行できます（PlaywrightとChromiumが必要）。

設計上の判断と測定方法は[docs/design.md](docs/design.md)、この実装の検証結果は[docs/validation.md](docs/validation.md)を参照してください。
