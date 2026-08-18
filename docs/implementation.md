# bc768-probe 実装ガイド

[BC-768 macOS BLE 検証仕様書](BC-768_macOS_BLE_検証仕様書.md) の Phase 1〜2 を実装したもの。

## 構成

Swift Package（macOS 13+ / Swift 6 ツールチェーン、言語モードは v5）。

```
Package.swift
Sources/BC768Protocol/            CoreBluetooth に依存しないプロトコル層
  Protocol.swift                  メッセージ / フラグメント / チェックサム / 再構成
  Hex.swift                       hex 変換
Sources/BC768Probe/
  main.swift                      CLI entrypoint・シグナル処理・run loop
  CLI.swift                       引数パースと usage
  Config.swift                    UUID とハンドシェイク値の外部設定（環境変数 / .env）
  BC768Client.swift               CoreBluetooth delegate（scan / connect / discover / subscribe / handshake）
  Handshake.swift                 ハンドシェイクの手順定義
  CharacteristicProperties.swift  Property の人間可読化
  Log.swift                       行指向ロガー
  Info.plist                      NSBluetoothAlwaysUsageDescription
Tests/BC768ProtocolTests/         プロトコル層のユニットテスト
```

プロトコル層は CoreBluetooth に依存しない独立ターゲットにしてあるので、そのままテストできる。
将来 Go へ移植する際もこの層の仕様（`docs/protocol.md`）だけを写せばよい。

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

`handshake` はさらに以下を必要とする（Android HCI キャプチャ由来の値）。

| 環境変数 | 用途 |
| --- | --- |
| `BC768_CLIENT_ID` | `0x0003` で送るクライアント識別子（36 文字の UUID 文字列）。必須 |
| `BC768_CMD_0010_PAYLOAD` | `0x0010` の payload を固定したいときだけ設定する。省略時は現在時刻から生成 |

`scan` は `SERVICE_UUID` のみ、`probe` は 6 つすべてを必須とする。不足時はどの論理 UUID が足りないかと
探索したファイルパスを表示して終了コード 2 で終わる。

形式は 16bit / 32bit / 128bit のいずれも受け付ける（`CBUUID(string:)` は不正値で例外を投げるため事前検証している）。

ATT Handle はハードコードせず、Characteristic は必ず UUID 経由で取得する。

## CLI

| コマンド | 内容 |
| --- | --- |
| `scan` | 広告情報を表示するだけ。接続しない |
| `probe` | scan → connect → discover services → discover characteristics → subscribe → wait |
| `handshake` | probe に続けて、HCI ログで確認済みのハンドシェイクを送る |
| `measure` | handshake に続けて測定を開始し、結果を受け取る |

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
| `--write-char <sel>` | auto | handshake の送信先（`auto` / `write1` / `write2`） |
| `--response-timeout <sec>` | 3 | handshake の応答待ちタイムアウト |
| `--notify-char <sel>` | all | 購読する Notify（`all` / `notify1` / `notify2` / `notify3`） |
| `--handshake-delay <sec>` | 0 | 購読完了から handshake 開始までの待ち |

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

## handshake

`docs/protocol.md` で特定した手順を順に送る。各ステップは応答コマンドを待ってから次へ進む。

```text
identify     0x0003 <client id>   → 0x8003
session      0x0010 <日時>        → 0x8010     現在時刻から生成する
device-info  0x0020 00            → 0x8020
read-data    0x1000 00            → 0x9000
finish       0x0001 00            → 0x8001
```

`measure` はさらに以下を挟む（`--steps` で個別に指定もできる）。

```text
measure      0x2010 00            → 0xA010     応答待ち 120 秒。この間に体組成計へ乗る
complete     0x3000 00            → 0xB000
result       0x3010 01            → 0xB010     測定結果
```

- 送信は Write Without Response。フラグメントは Android と同じ 20 バイト固定で、15ms 間隔で送る。
  MTU が広がっても広げない（BC-768 が大きいフラグメントを受け付けるか未検証のため）。
- 応答は Notify を再構成して解釈し、チェックサムを検証する。
- `--write-char auto`（既定）では `WRITE_CHAR_1` に送り、最初のステップで応答がなければ
  `WRITE_CHAR_2` へ切り替えて 1 度だけ再試行する。HCI ログから handle と UUID の対応が取れないため。
- `0x1002`（データ書き込み / 設定）は BC-768 の状態を変える可能性があるため**送らない**。
- `0x0010` は日時設定コマンドなので、固定値ではなく実行時の現在時刻から組み立てる
  （`docs/protocol.md` の日時エンコードを参照）。

## 安全性

- `scan` / `probe` の既定動作は Scan / Connect / Discover / Subscribe / Log まで。Write は行わない。
- `handshake` が送るのは Android HCI キャプチャで観測済みの payload のみ。
  空データ・ランダム・推測した payload は送らない。
- `--read-all` は副作用のない read のみ。

## 終了処理

`SIGINT` / `SIGTERM` を `DispatchSource` で受け、接続中であれば Notify 解除 → `cancelPeripheralConnection` →
scan 停止を行い、コールバックを待ってから終了する。

## 終了コード

| コード | 意味 |
| --- | --- |
| 0 | 正常終了（Ctrl+C、`--wait` 経過、scan で 1 件以上発見） |
| 1 | 実行時の失敗（Bluetooth 不可、対象未発見、接続失敗、異常切断） |
| 2 | 引数エラー / UUID 設定不足 |
