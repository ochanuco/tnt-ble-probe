# BC-768 macOS BLE Pairing 検証仕様書

## 1. 目的

TANITA BC-768 と macOS 間で、Swift / CoreBluetooth
を使用して以下を検証する。

-   BC-768 を BLE Peripheral として検出できること
-   GATT 接続できること
-   BC-768 の Pairing / Bonding を macOS 側で成立させられること
-   Pairing 後に GATT Service / Characteristic を列挙できること
-   TANITA 独自 Characteristic の Notify 購読・Write が可能であること
-   将来的に Go CLI へ移植可能な通信シーケンスを特定すること

本検証では、体組成値の完全なデコード実装は目的としない。

## 2. 対象

-   TANITA BC-768
-   macOS
-   Bluetooth Low Energy
-   Swift
-   CoreBluetooth

## 3. UUIDの扱い

Service UUID / Characteristic UUID は本仕様書には記載しない。

Claude には仕様書とは別にユーザーから提供する。実装では UUID
をソースコードへ直接埋め込まず、設定として分離できる構造にする。

必要な UUID の役割は以下。

-   BC-768 独自 Service UUID
-   Write Without Response 用 Characteristic × 2
-   Notify 用 Characteristic × 3

以降、以下の論理名で記述する。

-   `SERVICE_UUID`
-   `WRITE_CHAR_1`
-   `WRITE_CHAR_2`
-   `NOTIFY_CHAR_1`
-   `NOTIFY_CHAR_2`
-   `NOTIFY_CHAR_3`

ATT Handle はハードコードしない。必ず UUID から Characteristic
を取得すること。

## 4. 前提

BC-768 の「設定/通信」ボタンを約3秒長押しし、Pairing 待機状態にする。

LightBlue では以下まで確認済み。

``` text
BLE Scan
↓
BC-768を発見
↓
Connect
↓
Connected
```

ただし、この状態では BC-768 本体は Pairing 待機状態のままであり、単純な
GATT Connect だけでは Pairing / Bonding は完了しない。

## 5. 検証方針

CoreBluetooth を直接使用する。

macOS では BLE Pairing を明示的に開始する公開 API
に依存せず、以下の流れで Pairing が誘発されるか確認する。

``` text
Connect
↓
Service Discovery
↓
Characteristic Discovery
↓
Notify / Read / Write 等のアクセス
↓
Peripheral 側の Security Requirement
↓
macOS Bluetooth Stack による Pairing
```

未知の payload を送信して Pairing を無理に誘発しないこと。

## 6. プログラム形式

最小構成の macOS CLI アプリケーションとする。GUI は不要。

CLI 名の例:

``` text
bc768-probe
```

Xcode Project または Swift Package とする。特別な理由がなければ Swift
Package を優先する。

過剰な抽象化は避ける。

概ね以下程度の構成でよい。

``` text
CLI entrypoint
BC768Client
CoreBluetooth delegate
configuration
```

## 7. UUID設定

UUID は外部から与えられるようにする。

開発・検証用途なので複雑な設定基盤は不要だが、少なくともソースコードの公開部分へ実値を直接記述しなくて済むようにする。

候補:

1.  環境変数
2.  `.env` 相当のローカル設定
3.  Git 管理対象外の設定ファイル

秘密管理システム等の過剰な仕組みは導入しない。

設定不足時は、どの論理 UUID が不足しているか明示して終了する。

## 8. Scan

`CBCentralManager` を使用する。

Bluetooth が利用可能になったら scan を開始する。

最初は `SERVICE_UUID` を指定して scan する。

検出できない場合に備え、Service filter なしの scan モードも用意する。

Peripheral 発見時に以下をログ出力する。

``` text
Peripheral UUID
Name
RSSI
Advertisement Data
Service UUIDs
Manufacturer Data
```

例:

``` text
[SCAN]
name=<peripheral name>
id=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
rssi=-48
services=[...]
```

Peripheral 名だけに依存して接続先を決定しないこと。Service UUID
を優先して識別する。

## 9. Connect

対象 Peripheral 発見後、scan を停止して接続する。

``` swift
centralManager.connect(peripheral)
```

接続イベントをすべてログ出力する。

``` text
CONNECTING
CONNECTED
FAILED
DISCONNECTED
```

Error 発生時は最低限以下を出力する。

``` text
localizedDescription
NSError domain
NSError code
```

## 10. Service Discovery

接続後に Service Discovery を実行する。

初回検証では UUID を限定せず全 Service を取得し、全 Service UUID
をログ出力する。

`SERVICE_UUID` と一致する Service に対して Characteristic Discovery
を行う。

## 11. Characteristic Discovery

全 Characteristic について以下をログ出力する。

``` text
UUID
Properties
isNotifying
Descriptors
```

Property は最低限以下を人間が読める形式で表示する。

``` text
read
write
writeWithoutResponse
notify
indicate
authenticatedSignedWrites
extendedProperties
```

設定された各 Characteristic UUID が実際の Property
と一致しているか検証する。

## 12. Notify購読

以下をすべて Notify 購読する。

``` text
NOTIFY_CHAR_1
NOTIFY_CHAR_2
NOTIFY_CHAR_3
```

`setNotifyValue(true, for:)` を使用する。

購読要求時と状態変更時をログ出力する。

``` text
[SUBSCRIBE]
uuid=<UUID>
requested=true

[NOTIFY_STATE]
uuid=<UUID>
enabled=true
error=nil
```

Notify 購読によって macOS の Pairing UI が表示されるか確認する。

Pairing UI が表示された場合、人間が操作できるよう CLI
を終了させず待機すること。

## 13. Pairing検証

### Case A: Connectのみ

``` text
Connect
↓
待機
```

BC-768 側の Pairing 待機状態が終了するか確認する。

### Case B: Notify購読

``` text
Connect
↓
NOTIFY_CHAR_1 / 2 / 3 を購読
↓
待機
```

macOS 側で Pairing が発生するか確認する。

### Case C: Characteristicアクセス

Case A / B で Pairing が発生しない場合に検討する。

`WRITE_CHAR_1` / `WRITE_CHAR_2` への Write は、Android HCI
ログ等から正しいコマンドが確認できたものだけを使用する。

空データ、ランダムデータ、推測した payload を送信してはならない。

## 14. Raw Notification Logger

Notify を受信した場合、payload を加工せず記録する。

``` text
[NOTIFY]
timestamp=2026-08-19T00:00:00.123+09:00
uuid=<UUID>
length=18
hex=0000000e000c...
```

必要に応じて decimal bytes / ASCII 表示を追加してよいが、hex
を正とする。

Fragment の結合や体組成値の解釈はこのフェーズでは必須ではない。

## 15. Write Logger

Characteristic へ Write する機能を追加する場合、送信前に必ずログを残す。

``` text
[WRITE]
uuid=<UUID>
type=withoutResponse
length=10
hex=<payload>
```

Write 対象は UUID で指定する。ATT Handle をハードコードしない。

## 16. Androidで確認済みの事項

Health Planet と BC-768 間の Android Bluetooth HCI
キャプチャから、以下を確認済み。

-   Write Command が存在する
-   Notification により測定データが返る
-   測定開始に関連すると考えられる Write payload が存在する
-   測定結果には体重、体脂肪率、筋肉量、基礎代謝、内臓脂肪レベル、体水分率等と考えられる値が含まれる

具体的な UUID、ATT Handle、raw payload は本仕様書には記載しない。

必要になった時点で別途ユーザーから提供する。

## 17. Pairing / Bonding成功判定

以下を組み合わせて判断する。

### BC-768側

Pairing 待機状態が終了する。

### macOS側

必要に応じて Bluetooth Pairing UI が表示され、正常完了する。

### GATT通信

Pairing 前に失敗していた GATT 操作が Pairing 後に成功する。

### 再接続

一度 CLI を終了し BC-768 を再起動した後、

``` text
scan
↓
connect
```

を行い、再度 Pairing を要求されず通信できる。

これを Bonding 成立の重要な確認項目とする。

## 18. ログ

最低限以下のレベルを用意する。

``` text
INFO
DEBUG
ERROR
```

通常実行は INFO。

``` bash
bc768-probe probe
bc768-probe probe --debug
```

DEBUG では CoreBluetooth のイベントを可能な限り記録する。

BLE の送受信データは必ず hex でログに残す。

## 19. CLI

最低限以下を想定する。

### Scanのみ

``` bash
bc768-probe scan
```

BC-768候補を探索して情報を表示する。

### Pairing検証

``` bash
bc768-probe probe
```

以下を実行する。

``` text
scan
↓
connect
↓
discover services
↓
discover characteristics
↓
subscribe notifications
↓
wait
```

初期実装では単一コマンドへ簡略化してもよい。

## 20. 終了処理

Ctrl+C で安全に終了できること。

終了時は可能な範囲で以下を行う。

``` text
Notify解除
Peripheral disconnect
Central cleanup
```

## 21. 安全性

デフォルト動作は以下までとする。

``` text
Scan
Connect
Discover
Subscribe
Log
```

未知の Characteristic に Write しない。

特に `WRITE_CHAR_1` / `WRITE_CHAR_2` への Write は、正しい BC-768
プロトコルを確認するまで自動実行しない。

Pairing 検証のために推測したデータを書き込まない。

## 22. 成功条件

### Phase 1

``` text
BC-768を発見
↓
接続
↓
SERVICE_UUIDを発見
↓
設定された5つのCharacteristicを発見
```

### Phase 2

``` text
Notify enable
↓
macOS Pairing開始
↓
BC-768 Pairing待機終了
```

### Phase 3

``` text
Bonding済みBC-768へ再接続
↓
Notify受信可能
```

### Phase 4（将来）

``` text
正しい測定開始シーケンスを送信
↓
BC-768測定
↓
raw body composition payload受信
```

## 23. 今回の実装範囲

まず Phase 1〜2 のみ実装する。

### 実装対象

-   CoreBluetooth Central
-   Scan
-   Connect
-   Service Discovery
-   Characteristic Discovery
-   Notify subscribe
-   UUIDの外部設定
-   詳細ログ
-   Ctrl+C終了処理

### 実装対象外

-   BC-768測定開始コマンド
-   ユーザー情報登録
-   体組成値デコード
-   Health Planet連携
-   Go実装
-   MCP実装

## 24. 実装方針

BLE プロトコルがまだ確定していないため、過剰な抽象化を行わない。

CoreBluetooth 固有処理と BC-768 固有処理は、将来 Go
へ移植しやすい程度に分離する。

現段階ではプロトコルを推測して自動処理しない。

**観測可能性と再現性を最優先すること。**
