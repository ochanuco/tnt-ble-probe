# 検証ログ

UUID の実値と Peripheral 識別子は記載しない（論理名 / `<masked>` で表記する）。

## 2026-08-19 初回検証

### 環境

| 項目 | 値 |
| --- | --- |
| macOS | 26.6.1 (25G76) |
| Swift | 6.3.3 / Xcode 26.6 |
| 対象 | TANITA BC-768 |
| コマンド | `bc768-probe scan` / `bc768-probe probe --debug --wait 45` |

BC-768 側の「設定/通信」ボタン長押しは**未実施**（本体は広告を出している状態だった）。

### scan

Service UUID フィルタあり / なしのどちらでも BC-768 を検出できた。

```text
[SCAN]
name=BC-768
id=<masked>
rssi=-70
services=<SERVICE_UUID>
manufacturerData=nil
serviceData=nil
connectable=1
matchesServiceUUID=true
```

- 広告に `SERVICE_UUID` が含まれるため、名前に依存せず Service UUID で識別できる。
- Manufacturer Data / Service Data は広告されない。
- 広告される名前は `BC-768` の後に空白が付く。名前一致で判定してはいけない根拠のひとつ。

### probe — Phase 1

| 項目 | 結果 |
| --- | --- |
| Connect | 成功（約 0.7 秒） |
| Service Discovery | Service は 1 件のみ。`SERVICE_UUID` に一致 |
| Characteristic Discovery | 5 件すべて発見（`VERIFY: configured=5 found=5 missing=nil propertyMismatch=nil`） |

実測した Property は設定と一致した。

| 論理名 | Properties | Descriptors |
| --- | --- | --- |
| `WRITE_CHAR_1` | `writeWithoutResponse` | なし |
| `WRITE_CHAR_2` | `writeWithoutResponse` | なし |
| `NOTIFY_CHAR_1` | `notify` | `2902` (CCCD) |
| `NOTIFY_CHAR_2` | `notify` | `2902` (CCCD) |
| `NOTIFY_CHAR_3` | `notify` | `2902` (CCCD) |

`read` 可能な Characteristic は 1 つも存在しない。標準の Device Information Service 等も公開されていない。
したがって「read によって Pairing を誘発する」経路は BC-768 には存在しない。

**Phase 1 は達成。**

### probe — Phase 2（Case B: Notify 購読）

```text
[NOTIFY_STATE] logical=NOTIFY_CHAR_1 enabled=true error=nil
[NOTIFY_STATE] logical=NOTIFY_CHAR_2 enabled=true error=nil
[NOTIFY_STATE] logical=NOTIFY_CHAR_3 enabled=true error=nil
```

- CCCD への書き込みは 3 件ともエラーなしで成功した。**認証・暗号化は要求されなかった。**
- macOS の Pairing UI は表示されなかった。
- Notify は 1 件も受信しなかった。
- 購読の約 11 秒後、Peripheral 側から切断された。

```text
[DISCONNECTED]
error=The connection has timed out unexpectedly. (domain=CBErrorDomain code=6)
```

**Phase 2 は未達。**

### 考察

- BC-768 の Notify Characteristic には Security Requirement が設定されていない。CCCD 書き込みが素通りするため、
  **Notify 購読だけでは macOS 側の Pairing は誘発されない**（仕様書 Case B は否定された）。
- GATT に read 可能な属性がないため、read 経由での誘発も不可能。
- 残る誘発経路は `WRITE_CHAR_1` / `WRITE_CHAR_2` への Write（Case C）だが、正しい payload が確定するまで
  実行しない。推測データは送らない。
- そもそも BC-768 が BLE Legacy Pairing を要求しない可能性もある。その場合「Pairing 待機状態の終了」は
  BLE の Bonding ではなく、独自プロトコルのハンドシェイク（Write → Notify）の完了を指していることになる。

### 次に試すこと

1. BC-768 の「設定/通信」ボタンを約 3 秒長押しして Pairing 待機状態にしたうえで `probe` を再実行し、
   接続維持時間と切断理由が変わるかを見る。
2. 同条件で `probe --no-subscribe`（Case A）を実行し、Connect のみで本体側の待機状態が終了するかを比較する。
3. `--wait` を長めに取り、11 秒での切断が Peripheral 側のアイドルタイムアウトかどうかを確認する。
4. Android の HCI ログから測定開始 Write の payload が確定したら Case C を検討する（Phase 4）。
