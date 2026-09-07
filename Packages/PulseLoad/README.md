# PulseLoad

Swiftで実装した、一定レートでHTTPリクエストを送信する負荷試験ツールです。目標レートと実際に開始できたレート、遅延、エラー、送信できなかった予定枠を記録します。

**SwiftPulseへの依存はありません。** 同じリポジトリ内で管理していますが、このディレクトリだけをコピーしてビルド・実行できます。Swift 6.0以降、LinuxまたはmacOS 14以降に対応します。

## 使い方

```sh
# このディレクトリで実行
swift build -c release
.build/release/pulse-load attack \
  --url http://127.0.0.1:8080/hello \
  --rate 100 --duration 10s --concurrency 128 \
  --output runs/current.json

.build/release/pulse-load report --input runs/current.json
.build/release/pulse-load compare \
  --input runs/current.json --baseline runs/baseline.json
```

SwiftPulseのリポジトリルートからは `swift run --package-path Packages/PulseLoad -c release pulse-load ...` でも実行できます。

```sh
.build/release/pulse-load attack \
  --url http://127.0.0.1:8080/echo \
  --method POST --header 'Content-Type: application/json' \
  --body request.json --rate 50 --duration 30s --timeout 3s
```

`SIGINT` / `SIGTERM` で中断すると、途中までの結果をJSONとして保存します。比較コマンドはp99遅延と送信開始レートの差を表示します。対象、Body、レート、同時実行数、時間をそろえて比較してください。

## 測定の意味

レスポンスの完了を待たずに次の送信予定時刻を決める、open-loop方式です。同時実行数の上限に達した予定枠は `droppedCapacity`、許容遅れを超えた予定枠は `droppedLate` に記録します。上限に達したタスクを無制限に保持しません。

| 集計 | 意味 |
|---|---|
| `latency` | リクエスト処理開始からレスポンス受信完了まで |
| `scheduleToCompletion` | 予定時刻から受信完了まで |
| `schedulerLag` | 予定時刻から処理開始までの遅れ |
| `achievedRPS` | 実際に開始した件数 / 送信期間 |
| `failed` | 通信エラー、Body上限超過、200〜399以外の応答 |

HTTP(S)クライアントにはFoundationのURLSessionを使用します。リダイレクトには追従しません。受信Bodyはサイズを数えて破棄します。TLSやクライアント側の接続管理も測定値に影響します。

遅延分位点は固定メモリのヒストグラムによる近似値で、1 µs以上ではバケットの量子化幅は2%以内です。平均と最大値は実測値を使用します。リクエスト明細は `--max-samples` 件までですが、集計には全完了リクエストを含めます。

## ライブラリとして使う

ローカルパッケージ参照を `.package(path: "/path/to/PulseLoad")` で追加し、`PulseLoad` productに依存します。

```swift
import PulseLoad

var configuration = LoadConfiguration(url: "http://127.0.0.1:8080/hello")
configuration.rate = 100
configuration.duration = 10
let report = try await LoadEngine.run(configuration: configuration)
print(report.summary.latency.p99)
```

SwiftPulseとの連携が必要な場合は、各リクエストに送信される `X-Pulse-Request-ID` と結果明細の `id` でStudio側のトレースに関連付けられます。負荷結果にサーバートレースを埋め込む機能はありません。

## 検証

```sh
swift test
swift build -c release
python3 scripts/integration.py
```

統合テストの対象はPythonのHTTPサーバーです。送信枠の集計、飽和時の脱落、Bodyサイズ制限、HTTPエラー、リダイレクト非追従、POST、中断、結果比較を確認します。
