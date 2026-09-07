# SwiftPulse

**並行処理の動きが見える、軽量なSwiftサーバーフレームワーク。**

SwiftPulseは、Swift ConcurrencyでHTTPサーバーを実装し、リクエストの重なり・ワーカーの実行区間・処理待ちを確認できるフレームワークです。SwiftNIOに依存せず、非同期APIの下でノンブロッキングソケットを使用します。Swiftパッケージの外部依存はありません。

付属の **Studio** はサーバーの観測画面です。普段のブラウザアクセスやAPI呼び出しをそのまま観測できます。

## できること

- `async throws`なハンドラーを使ったHTTP/1.1サーバーの実装
- Keep-Alive、接続数制限、読み取り・ハンドラー・送信のタイムアウト
- ワーカーで実行されたSwiftジョブと、リクエストの関連付け
- Studioでのライブ観測、一時停止、検索、タイムラインの拡大、トレースJSONの入出力
- 計測件数を制限しながら、直近の実行状況を継続的に保持

負荷試験は独立パッケージの **[PulseLoad](Packages/PulseLoad/README.md)** に分離しています。一定レートでのHTTP送信・遅延集計・結果比較を行うツールで、SwiftPulse以外のサーバーにも使えます。本体とStudioのビルドにPulseLoadは不要です。

## 試す

Swift 6.0以降。サーバーはLinuxまたはmacOS 15以降で動作します。

```sh
git clone https://github.com/Moriya-Taichi/SwiftPulse.git
cd SwiftPulse
swift build -c release

# ターミナル1: サンプルサーバー
.build/release/pulse serve --port 8080 --workers 4

# ターミナル2: 観測画面
.build/release/pulse studio --target http://127.0.0.1:8080
```

ブラウザで `http://127.0.0.1:9090` を開き、別のターミナルからサーバーへアクセスします。

```sh
curl 'http://127.0.0.1:8080/work?delay=20&fanout=4'
```

Studioにリクエストとワーカーの実行区間が表示されます。`/work` は非同期の待機と計算を行うサンプルエンドポイントです。`/health` と `POST /echo` も用意しています。

Studioは `Studio/` の静的ファイルを読み込みます。別のディレクトリから起動する場合は `--ui-dir /path/to/SwiftPulse/Studio` を指定してください。観測対象を変更するときは `--target` を変更して起動し直します。

## 自分のサーバーに組み込む

アプリケーションの `Package.swift` に追加します。

```swift
.package(url: "https://github.com/Moriya-Taichi/SwiftPulse.git", branch: "main")
```

ターゲットの依存に `.product(name: "PulseCore", package: "SwiftPulse")` を追加します。

```swift
import PulseCore

@main
struct Application {
    static func main() async throws {
        let recorder = TraceRecorder(capacity: 50_000)
        let server = try HTTPServer(port: 8080, workers: 4, trace: recorder) { request in
            switch request.path {
            case "/__pulse/trace":
                return try TraceEndpoint.response(to: request, recorder: recorder)
            case "/hello":
                return .text("Hello, Swift!\n")
            default:
                return .text("Not found", status: 404)
            }
        }
        try await server.run()
    }
}
```

このサーバーも `pulse studio --target http://127.0.0.1:8080` で観測できます。トレースの出力先は `/__pulse/trace` です。ライブラリの計測は既定で無効です。`TraceRecorder` を渡さなければ、通常のHTTPサーバーとして動作します。サンプルCLIでは `--trace-capacity 0` で無効にできます。

## 並行処理と可視化

`async` は並列実行を保証する指定ではありません。処理が中断・再開できることと、複数の処理が実際に同時実行されることを分けて扱います。

| Studioの表示 | 意味 |
|---|---|
| リクエスト区間 | ヘッダー・Bodyの解析完了から応答送信完了までの経過時間 |
| ハンドラー区間 | ハンドラーの経過時間。`await`による待機も含む |
| ワーカー区間 | 管理下のTaskExecutorがSwiftジョブを実行した区間 |
| ワーカー待ち時間 | ジョブを投入してから実行が始まるまでの時間 |
| 最大同時リクエスト数 | 保持している完了リクエストの区間が重なった最大数 |

ワーカーは直列DispatchQueueによる論理レーンです。OSスレッドとの固定対応はありません。実行区間にはOSによるプリエンプションが含まれます。CPU使用率、外部の実行基盤、専用Executorを持つActorの動作を網羅するプロファイラーではありません。未完了リクエストは完了区間の統計に含まれません。

通常のアクセスにもRequest IDを付与します。クライアントが `X-Pulse-Request-ID` を送った場合はその値を使用するため、関連付けには一意な値を使用してください。

## 計測の負担を抑える設計

- HTTPの増分デコーダーがヘッダーの検索位置と解析結果を保持し、Body受信中の再解析を省く
- ソケット単位で受信領域を再利用し、読み取り待ちでの領域確保・ゼロ初期化を省く
- 大きな応答は既存のバッファを保持して送信し、64 KiBごとのコピーと非同期処理の再開を減らす
- ジョブの待ち時間・スレッド番号は数値で記録し、出力時に文字列へ変換する
- 計測無効時はイベントの辞書・レーン文字列を生成しない
- 直近のイベントをリングバッファに保持し、Studioにはカーソル以降の差分だけを送る

Studioの取得は1秒間隔、1回最大5,000イベント、ブラウザ側の保持は最大20,000イベントです。取得が追いつかなかった場合は欠落数を表示します。サーバー再起動時はセッションを切り替え、以前の時刻・カーソルを引き継ぎません。

性能比較の条件と結果は [docs/performance.md](docs/performance.md)、内部設計は [docs/design.md](docs/design.md) に記載しています。

## 現在の対応範囲

HTTP/1.1、Content-LengthによるBody、IPv4のTCPリスナーに対応しています。曖昧な重複ヘッダーやTransfer-Encodingは拒否します。

サーバー側TLS、HTTP/2・3、WebSocket、chunked転送、汎用的なBodyストリーミングは未実装です。ヘッダーは最大16 KiB、リクエストBodyは最大1 MiBです。ハンドラーのタイムアウトは協調的なキャンセルのため、長い計算ではキャンセルを確認してください。

サンプルサーバーとStudioは既定でループバックにバインドします。トレースAPIとStudioには認証を実装していないため、開発時の観測用として扱います。

## 開発・検証

```sh
swift test
node --test Tests/StudioTests/*.test.mjs
swift build -c release
python3 scripts/integration.py

# 負荷試験ツールは独立してビルド・検証
swift test --package-path Packages/PulseLoad
swift build --package-path Packages/PulseLoad -c release
python3 Packages/PulseLoad/scripts/integration.py
```

CIではLinuxとmacOSで両パッケージを検証します。PulseLoadはリポジトリ外にコピーしてビルドし、本体への依存がないことも確認します。Studioは実際のHTTPアクセス、ライブ観測、検索・選択、ファイル入出力、モバイル表示をブラウザで検証します。

## 以前のCLIからの移行

| 以前 | 現在 |
|---|---|
| `pulse attack` | `pulse-load attack` |
| `pulse report` | `pulse-load report` |
| Studioでの負荷設定・試験管理 | PulseLoadのCLIで実行・比較 |
| `pulse studio --reports runs` | `pulse studio --target http://127.0.0.1:8080` |
| 負荷結果に埋め込まれたトレース | `/__pulse/trace` またはStudioから独立したトレースJSONを取得 |

負荷結果JSONの従来の集計項目は維持しています。新しい結果の `kind` は `pulseload.run` です。`--trace-url` と自動トレース取得は廃止し、計測データの取得はStudioに集約しました。以前の `swiftpulse.run` は `pulse-load report` / `compare` で読み込めます。
