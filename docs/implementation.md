# bc768-probe 実装ガイド

[BC-768 macOS BLE 検証仕様書](BC-768_macOS_BLE_検証仕様書.md) の Phase 1〜2 を実装したもの。

## 構成

Swift Package（macOS 13+ / Swift 6 ツールチェーン、言語モードは v5）。

```
Package.swift
Sources/BC768Probe/
  main.swift                      CLI entrypoint・シグナル処理・run loop
  CLI.swift                       引数パースと usage
  Config.swift                    UUID の外部設定（環境変数 / .env）
  BC768Client.swift               CoreBluetooth delegate（scan / connect / discover / subscribe）
  CharacteristicProperties.swift  Property の人間可読化
  Log.swift                       行指向ロガーと hex ユーティリティ
  Info.plist                      NSBluetoothAlwaysUsageDescription
```

CLI 名（product 名）は `bc768-probe`、モジュール名は `BC768Probe`。

CoreBluetooth 固有処理は `BC768Client` に閉じ込め、UUID・ログ・CLI から分離してある。将来 Go へ移植する際は
`BC768Client` の状態遷移（scan → connect → discover → subscribe → wait）だけを差し替えればよい。

### Info.plist の埋め込み

CLI から CoreBluetooth を使うには TCC 用の usage description が要るため、`Package.swift` の
`linkerSettings` で `-sectcreate __TEXT __info_plist Sources/BC768Probe/Info.plist` を渡して実行ファイルへ
埋め込んでいる。この指定は `unsafeFlags` のため、このパッケージを他パッケージから依存として参照することはできない
（検証用 CLI なので問題にしない）。

Bluetooth の使用許可は実行するターミナルアプリに紐づく。拒否されている場合は
`システム設定 > プライバシーとセキュリティ > Bluetooth` で許可する。CLI 側は `unauthorized` を検出して
その旨を出力して終了する。

## UUID 設定

実 UUID はソース・docs・git に一切含めない。以下の優先順で読み込む。

1. 環境変数
2. `--config <path>` で指定したファイル
3. `./.env`
4. `~/.config/bc768-probe/env`（`XDG_CONFIG_HOME` があればそちら）

| 論理名 | 環境変数 | 用途 |
| --- | --- | --- |
| `SERVICE_UUID` | `BC768_SERVICE_UUID` | BC-768 独自 Service |
| `WRITE_CHAR_1` | `BC768_WRITE_CHAR_1` | Write Without Response |
| `WRITE_CHAR_2` | `BC768_WRITE_CHAR_2` | Write Without Response |
| `NOTIFY_CHAR_1` | `BC768_NOTIFY_CHAR_1` | Notify |
| `NOTIFY_CHAR_2` | `BC768_NOTIFY_CHAR_2` | Notify |
| `NOTIFY_CHAR_3` | `BC768_NOTIFY_CHAR_3` | Notify |

`scan` は `SERVICE_UUID` のみ、`probe` は 6 つすべてを必須とする。不足時はどの論理 UUID が足りないかと
探索したファイルパスを表示して終了コード 2 で終わる。

形式は 16bit / 32bit / 128bit のいずれも受け付ける（`CBUUID(string:)` は不正値で例外を投げるため事前検証している）。

ATT Handle はハードコードせず、Characteristic は必ず UUID 経由で取得する。

## CLI

| コマンド | 内容 |
| --- | --- |
| `scan` | 広告情報を表示するだけ。接続しない |
| `probe` | scan → connect → discover services → discover characteristics → subscribe → wait |

| オプション | 既定 | 内容 |
| --- | --- | --- |
| `--debug` | off | DEBUG ログ。SERVICE_UUID 以外の Service の Characteristic も探索する |
| `--config <path>` | - | 設定ファイルの明示指定 |
| `--no-filter` | off | Service UUID フィルタなしで scan する |
| `--timeout <sec>` | 20 | scan タイムアウト。0 で無制限 |
| `--no-subscribe` | off | Notify 購読を行わない（Pairing 検証 Case A） |
| `--read-all` | off | readable な Characteristic を read する（Write はしない） |
| `--id <uuid>` | - | scan を省略して既知の Peripheral 識別子へ直接接続 |
| `--wait <sec>` | 0 | 接続後の待機秒数。0 で Ctrl+C まで待機 |

`probe` は開始時に `retrieveConnectedPeripherals(withServices:)` を確認する。Bonding 済みで macOS が既に接続を
保持している場合、広告が出ず scan で見つからないことがあるため。

接続先は名前ではなく Service UUID で識別する。`--no-filter` 指定時は、広告に Service UUID を含む Peripheral
だけを接続対象とする（含まない機体は `--id` で指定する運用）。

## ログ

`INFO` / `DEBUG` / `ERROR` の 3 レベル。既定は INFO、`--debug` で DEBUG。ERROR は stderr、他は stdout。

イベントは `[TAG]` に続けて `key=value` を 1 行ずつ出力する。すべてのイベントに `timestamp`（ミリ秒 + タイムゾーン）が付く。

| タグ | 出力タイミング |
| --- | --- |
| `CENTRAL_STATE` | CBCentralManager の状態変化 |
| `SCAN_START` / `SCAN` / `SCAN_TIMEOUT` | 探索 |
| `RETRIEVED` | 既知 / 接続済み Peripheral の取得 |
| `CONNECTING` / `CONNECTED` / `FAILED` / `DISCONNECTED` | 接続イベント |
| `SERVICES` / `SERVICE` | Service Discovery |
| `CHARACTERISTIC` / `DESCRIPTORS` | Characteristic Discovery |
| `VERIFY` | 設定 UUID の存在と Property の照合結果 |
| `SUBSCRIBE` / `NOTIFY_STATE` / `UNSUBSCRIBE` | Notify 購読 |
| `NOTIFY` / `NOTIFY_DETAIL` | 受信 payload（hex が正。DEBUG で decimal / ASCII も出す） |
| `SHUTDOWN` / `DISCONNECTING` | 終了処理 |

エラーは `localizedDescription (domain=... code=...)` の形式で残す。`DISCONNECTED` には CBError の種類に応じた
`hint` を付ける（自動リトライや自動書き込みは行わない。判断は人間が行う）。

## 安全性

- 既定動作は Scan / Connect / Discover / Subscribe / Log まで。
- `WRITE_CHAR_1` / `WRITE_CHAR_2` への Write は実装していない。空データ・ランダム・推測 payload の送信も行わない。
- `--read-all` は副作用のない read のみ。Pairing 誘発の観測用のオプトイン。

## 終了処理

`SIGINT` / `SIGTERM` を `DispatchSource` で受け、接続中であれば Notify 解除 → `cancelPeripheralConnection` →
scan 停止を行い、コールバックを待ってから終了する。

## 終了コード

| コード | 意味 |
| --- | --- |
| 0 | 正常終了（Ctrl+C、`--wait` 経過、scan で 1 件以上発見） |
| 1 | 実行時の失敗（Bluetooth 不可、対象未発見、接続失敗、異常切断） |
| 2 | 引数エラー / UUID 設定不足 |
