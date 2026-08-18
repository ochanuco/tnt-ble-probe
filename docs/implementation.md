# bc768-probe 実装ガイド

[BC-768 macOS BLE 検証仕様書](BC-768_macOS_BLE_検証仕様書.md) の Phase 1〜2 を実装したもの。

## 構成

Swift Package（macOS 13+ / Swift 6 ツールチェーン、言語モードは v5）。

```
Package.swift
scripts/make-app.sh               GUI を .app バンドルへ組み立てる
Sources/BC768Protocol/            CoreBluetooth に依存しないプロトコル層
  Protocol.swift                  メッセージ / フラグメント / チェックサム / 再構成
  DateTime.swift                  日時エンコード
  TLV.swift                       TLV パーサ（タグごとの固定長テーブル）
  Measurement.swift               測定値のラベル付け・検算・レコードの妥当性判定
  MeasurementRecord.swift         JSON 出力用の表現
  Hex.swift                       hex 変換
Sources/BC768BLE/                 CoreBluetooth を使うセッション層（CLI と GUI が共有）
  Session.swift                   scan / connect / discover / subscribe / handshake
  Discovery.swift                 UUID を知らない状態からの探索と構成判定
  ConfigWriter.swift              設定ファイルの書き出し
  Events.swift                    イベント（ログ・進捗・測定結果・完了）
  Configuration.swift             UUID とセッション設定
  Config.swift                    環境変数 / .env の読み込み
  Handshake.swift                 ハンドシェイクの手順定義
  CharacteristicProperties.swift  Property の人間可読化
  Errors.swift                    エラー整形
Sources/BC768App/                 SwiftUI の GUI
  BC768AppMain.swift              エントリポイント
  ContentView.swift               ボタン・表・ログ
  SetupView.swift                 探す → 調べる → 登録
  SessionController.swift         セッションの実行と状態
  DiscoveryController.swift       端末の探索と設定の保存
  MeasurementStore.swift          JSON Lines への蓄積と CSV 書き出し
  Info.plist                      NSBluetoothAlwaysUsageDescription
Sources/BC768Probe/
  main.swift                      CLI entrypoint・シグナル処理・run loop
  CLI.swift                       引数パースと usage
  CLI.swift                       引数パース（再掲）
  Decode.swift                    decode コマンド（オフライン解釈）
  JSONOutput.swift                JSON の標準出力・ファイル追記
  Log.swift                       行指向ロガー
  Info.plist                      NSBluetoothAlwaysUsageDescription
Tests/BC768ProtocolTests/         プロトコル層のユニットテスト
```

プロトコル層は CoreBluetooth に依存しない独立ターゲットにしてあるので、そのままテストできる。
将来 Go へ移植する際もこの層の仕様（`docs/protocol.md`）だけを写せばよい。

BLE のセッション層（`BC768BLE`）はログ出力も終了処理も持たず、イベントを流すだけにしてある。
CLI はそれをログと JSON へ、GUI は画面の状態へ変換する。

## GUI

```bash
./scripts/make-app.sh          # .build/BC-768.app を作る
open .build/BC-768.app
```

| ボタン | 動作 |
| --- | --- |
| 設定 | 探す → 調べる → 登録（`discover --save` 相当）|
| 入力 | `measure` 相当。本体の「入力モード」を押して乗ると結果が入る |
| 確認 | `sync` 相当。測定せず、保持されているデータを取り込む |
| 送信 | 蓄積した記録を CSV で書き出す（スプレッドシート向け） |

### GUI での UUID 設定

GUI は Finder から起動するとカレントディレクトリが `/` になるため、リポジトリの `./.env` を読めない。
**`~/.config/bc768-probe/env` に置く必要がある。**

```bash
mkdir -p ~/.config/bc768-probe
cp .env ~/.config/bc768-probe/env
chmod 600 ~/.config/bc768-probe/env
```

設定が見つからない場合、GUI は起動時に案内を出し、測定系のボタンを押せないようにする。
そこから「BC-768 を登録する」で設定画面を開ける。UUID は自動で割り出すので、
入力が要るのはクライアント識別子だけ。

取り込んだ記録は `~/Library/Application Support/bc768-probe/records.jsonl` に貯まる。
CLI の `--out` と同じ JSON Lines なので、同じファイルを指せば両方から扱える。
測定日時が同じレコードは二重に保存しない。日時のないレコード（接続外測定や引き取り済み）は
表に「日時なし」と出して区別する。

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

コマンドは必須。省略すると usage を表示して終了コード 2 で終わる（既定のコマンドは設けていない）。

| コマンド | 内容 |
| --- | --- |
| `scan` | 広告情報を表示するだけ。接続しない |
| `probe` | scan → connect → discover services → discover characteristics → subscribe → wait |
| `handshake` | probe に続けて、HCI ログで確認済みのハンドシェイクを送る |
| `measure` | handshake に続けて測定を開始し、結果を受け取る |
| `sync` | 測定は開始せず、保持されているデータの有無を確認して取得する |
| `decode` | 受信済みの hex を TLV として解釈する（BLE を使わない） |
| `discover` | UUID 設定なしで端末を探し、GATT の構成から UUID を割り出す |

| オプション | 既定 | 内容 |
| --- | --- | --- |
| `--debug` | off | DEBUG ログ。SERVICE_UUID 以外の Service の Characteristic も探索する |
| `--config <path>` | - | 設定ファイルの明示指定 |
| `--no-filter` | off | Service UUID フィルタなしで scan する |
| `--timeout <sec>` | 20 | scan タイムアウト。0 で無制限 |
| `--no-subscribe` | off | Notify 購読を行わない（Pairing 検証 Case A） |
| `--read-all` | off | readable な Characteristic を read する（Write はしない） |
| `--id <uuid>` | - | scan を省略して既知の Peripheral 識別子へ直接接続 |
| `--wait <sec>` | 未指定 | 接続後の待機秒数。`0` で Ctrl+C まで待機し続ける。未指定なら `probe` は Ctrl+C まで待機し、`handshake` / `measure` / `sync` は手順が完走した時点で終了する |
| `--write-char <sel>` | auto | handshake の送信先（`auto` / `write1` / `write2`） |
| `--response-timeout <sec>` | 3 | handshake の応答待ちタイムアウト |
| `--notify-char <sel>` | all | 購読する Notify（`all` / `notify1` / `notify2` / `notify3`） |
| `--handshake-delay <sec>` | 0 | 購読完了から handshake 開始までの待ち |
| `--json` | off | 測定結果を JSON で標準出力へ出す（ログは標準エラーへ回る） |
| `--pretty` | off | JSON を整形して出す |
| `--out <path>` | - | JSON を 1 行ずつ追記する（JSON Lines） |
| `--only-new` | off | 新規の測定結果のときだけ JSON を出す |

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

`sync` は `measure` から `0x2010` だけを外したもの。その場で測らず、BC-768 が保持している
データを引き取る用途で、**Health Planet の HOME 画面を開いたときの動作に相当する**
（Android のキャプチャでも同じ手順が走っていた）。`0xB000` の payload をログに解釈して出し、データが無ければその旨を表示する。
`0x3010` はデータが無くても前回値を返すため、日時がゼロのレコードには `ERROR` を出して警告する
（`docs/protocol.md` の「データの保持と取得」を参照）。

- 送信は Write Without Response。フラグメントは Android と同じ 20 バイト固定で、15ms 間隔で送る。
  MTU が広がっても広げない（BC-768 が大きいフラグメントを受け付けるか未検証のため）。
- 応答は Notify を再構成して解釈し、チェックサムを検証する。
- `--write-char auto`（既定）では `WRITE_CHAR_1` に送り、最初のステップで応答がなければ
  `WRITE_CHAR_2` へ切り替えて 1 度だけ再試行する。HCI ログから handle と UUID の対応が取れないため。
- `0x1002`（データ書き込み / 設定）は BC-768 の状態を変える可能性があるため**送らない**。
- `0x0010` は日時設定コマンドなので、固定値ではなく実行時の現在時刻から組み立てる
  （`docs/protocol.md` の日時エンコードを参照）。

## UUID の自動検出

`discover` は設定を読まずに動く。Service UUID を知らないのでフィルタなしで scan し、
接続して全 Service / Characteristic を列挙する。

```bash
bc768-probe discover                    # 見つかった端末を一覧するだけ
bc768-probe discover --name TNT         # 名前で絞って接続し、構成を調べる
bc768-probe discover --name TNT --save  # 結果を ~/.config/bc768-probe/env へ書き出す
```

`--name` で絞らない限り接続しない（知らない機器へ勝手に繋がないため）。

判定は構成で行う。**Service が 1 つだけで、その配下が writeWithoutResponse × 2 と notify × 3**
という形に一致すれば BC-768 とみなし、UUID 昇順で `WRITE_CHAR_1,2` / `NOTIFY_CHAR_1,2,3` を割り当てる。
CoreBluetooth が返す順序はばらばらなので、必ず並べ替えてから割り当てる。

`--save` は既存の `BC768_CLIENT_ID` を残したまま UUID だけ書き換える。
識別子は機器に登録済みの値が必要で、自動生成できない（`docs/protocol.md` 参照）。

GUI の「設定」からも同じことができる。`BC768DiscoverySession` と `ConfigWriter` を
CLI と共有しているので、探索・構成判定・書き出しの挙動は完全に同じになる。
GUI では一覧から端末を選べるよう、接続先を識別子で指定できるようにしてある。

## デコード

`measure` で受け取った `0xB010`、および `0x9000` / `0x9002` は TLV として解釈してログへ出す。
ラベルと係数は `docs/protocol.md` の表に対応し、推定のものは「(推定)」と表示する。
raw hex も必ず併記するので、後から読み直せる。

受信ごとに次の検算を行い結果を出力する。桁を間違えていれば破れるため、解釈の妥当性を機械的に確認できる。

```text
BMI      = 体重 / 身長²
除脂肪量 = 体重 × (1 - 体脂肪率) ≒ 筋肉量 + 推定骨量
```

ログに残した hex を後から解釈し直すには `decode` を使う（BLE も UUID 設定も不要）。

```bash
bc768-probe decode --command B010 <payload hex>
bc768-probe decode <message hex>     # total_length から checksum まで含む全体
```

## JSON 出力

`0xB010`（測定結果）を受け取ると JSON を書き出せる。`--json` は標準出力、`--out` はファイルへの追記で、
両方同時に指定できる。`--json` のときはログをすべて標準エラーへ回すので、`jq` などへそのまま流せる。

```bash
bc768-probe measure --json | jq .
bc768-probe measure --out ~/health/bc768.jsonl
bc768-probe decode --command B010 --json --pretty <payload hex>
```

構造は次のとおり。**確定している項目をトップレベルに、検算できていない推定項目を `estimated` に分けている。**
`raw` に payload と TLV をそのまま入れてあるので、あとで解釈をやり直せる。

```json
{
  "measuredAt": "2026-08-19T02:15:35+09:00",
  "retrievedAt": "2026-08-19T03:30:00+09:00",
  "hasTimestamp": true,
  "sendPending": true,
  "heightCm": 174, "weightKg": 88.3, "bmi": 29.2,
  "bodyFatPercent": 24.2, "muscleMassKg": 63.5, "boneMassKg": 3.5,
  "estimated": {
    "basalMetabolismKcal": 1913, "metabolicAgeYears": 38,
    "visceralFatLevel": 13.5, "bodyWaterPercent": 48.5
  },
  "checks": [ { "label": "BMI = 体重 / 身長^2", "computed": 29.16, "received": 29.2, "passed": true } ],
  "raw": { "command": "0xB010", "header": "0x0001", "payload": "...", "fields": [ ... ] }
}
```

`measuredAt` は BC-768 が返した日時から復元する。**接続外で測定されたレコードは日時を持たないため
`null` になり、`hasTimestamp` が `false` になる**（BC-768 は時計を持たない。`docs/protocol.md` 参照）。
その場合 `retrievedAt` しか手がかりがないので、測定時刻としては使えない。

`sendPending` は直前の `0x3000` 応答が示した「タイムスタンプ付きで送信対象になるデータがあるか」。

### 新規データだけを保存する

`--only-new` を付けると、**日時があり送信対象として立っているレコードだけ**を出力する。
BC-768 は `0x3010` で引き取ると日時をクリアするため、この判定で重複も取り逃しも起きない。

```bash
bc768-probe sync --only-new --out ~/health/bc768.jsonl
```

`sync` を定期実行しても、新規の測定がなければ何も書かれない。
`0xB000` を観測していない `decode` では、日時の有無だけで判断する。

JSON が出るのは `0xB010` を受け取ったときだけなので、`scan` / `probe` で `--json` や `--out` を
指定しても何も出ない。その場合は警告を出す。

`handshake` / `measure` / `sync` は `--wait` を明示しない限り**手順が完走した時点で終了する**。
待ち続けるとパイプ先（`jq` など）が出力をフラッシュできず、JSON が画面に出てこないため。
観測のために接続を保ちたいときは `--wait 0` を渡す。

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
